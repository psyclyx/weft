//! Off-hot-path work. The rule "the input→commit→render path never
//! awaits and never locks" is enforced *mechanically*, not by
//! discipline: there is no blocking API to call. A `Handle` has `poll`
//! and `detach` — no wait, no join. `spawn` is lock-free (a CAS push +
//! a futex wake, which never blocks the waker). The only blocking
//! operation in this file is `Pool.deinit` (thread join at shutdown),
//! and it asserts it is not on the hot path.
//!
//! Debug builds add a second fence: the frame loop brackets itself with
//! `beginHotSection`/`endHotSection`, and every would-be blocking entry
//! point calls `assertMayBlock` — a future API that blocks without the
//! checkpoint won't survive review, one that has it won't survive a
//! Debug run on the hot path.

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const linux = std.os.linux;
const scheduler = @import("scheduler.zig");

// Parking uses the raw Linux futex (weft is Wayland/Linux-native;
// std.Thread.Futex is gone in 0.16 and the std.Io replacement would drag
// an Io instance through the ABI for two syscalls). Waking never blocks;
// waiting happens only on worker threads.
fn futexWait(word: *const std.atomic.Value(u32), expected: u32) void {
    // EAGAIN (value changed) and EINTR both mean "recheck" — the caller
    // loops on the queue regardless.
    _ = linux.futex_4arg(&word.raw, .{ .cmd = .WAIT, .private = true }, expected, null);
}

/// `max_waiters` must be ≤ maxInt(i32): the kernel takes a *signed*
/// count, and a negative one wakes exactly one waiter instead of all
/// (found the hard way — three parked workers, one wake, a hung join).
/// Futex mutex (std.Thread.Mutex left std in 0.16). Short critical
/// sections between a few threads; never on the input hot section.
pub const Mutex = struct {
    state: std.atomic.Value(u32) = .init(0),

    pub fn lock(self: *Mutex) void {
        while (self.state.swap(1, .acquire) != 0) futexWait(&self.state, 1);
    }

    pub fn unlock(self: *Mutex) void {
        self.state.store(0, .release);
        futexWake(&self.state, 1);
    }
};

fn futexWake(word: *const std.atomic.Value(u32), max_waiters: i32) void {
    _ = linux.futex_3arg(&word.raw, .{ .cmd = .WAKE, .private = true }, @intCast(max_waiters));
}

// ── Hot-section fence (Debug) ───────────────────────────────────────

threadlocal var hot_section: bool = false;

pub fn beginHotSection() void {
    hot_section = true;
}

pub fn endHotSection() void {
    hot_section = false;
}

pub fn inHotSection() bool {
    return hot_section;
}

/// Checkpoint for any operation that may block: panics in safe builds
/// when called inside a hot section.
pub fn assertMayBlock() void {
    assert(!hot_section);
}

// ── Pool ────────────────────────────────────────────────────────────

/// Type-erased task node. Concrete storage (`args`, `result`) lives in
/// the comptime-generated container around it.
const Node = struct {
    next: ?*Node = null,
    pool: *Pool,
    runFn: *const fn (*Node) void,
    destroyFn: *const fn (*Node, Allocator) void,
    /// Completion/ownership handoff: whichever of {worker finishing,
    /// holder detaching} comes second frees the node; `poll` frees on
    /// consumption.
    state: std.atomic.Value(u8) = .init(pending),

    const pending: u8 = 0;
    const done: u8 = 1;
    const detached: u8 = 2;
};

pub const Pool = struct {
    gpa: Allocator,
    threads: []std.Thread = &.{},
    /// Treiber stack of submitted nodes. Workers pop the whole stack at
    /// once (an exchange, immune to ABA) and run the batch in FIFO
    /// order; distribution is coarse but every path is lock-free.
    injector: std.atomic.Value(?*Node) = .init(null),
    /// Futex word: bumped on every state change workers care about.
    wake: std.atomic.Value(u32) = .init(0),
    shutdown: std.atomic.Value(bool) = .init(false),
    /// Optional scheduler wake-fd (doc/contextual-workspace-architecture.md
    /// §7): signaled once after any task completes, so `core/scheduler.zig`
    /// learns "a pool task finished" without polling every handle every
    /// wake. Coalesced by construction (an eventfd counter, not a per-task
    /// message) — a burst of completions between two scheduler steps
    /// collapses to one wake, which is exactly right (the caller still has
    /// to poll every handle to find out WHICH ones finished; this is only
    /// "go look").
    notify_fd: ?std.posix.fd_t = null,

    pub const Options = struct {
        /// 0 = a small editor-shaped default: enough for concurrent
        /// saves/plugins without a per-core army (whose thread stacks
        /// and allocator arenas cost real RSS).
        threads: usize = 0,
    };

    pub fn init(gpa: Allocator, opts: Options) (Allocator.Error || std.Thread.SpawnError)!*Pool {
        const self = try gpa.create(Pool);
        errdefer gpa.destroy(self);
        self.* = .{ .gpa = gpa };
        const want = if (opts.threads > 0)
            opts.threads
        else
            @min(4, @max(1, (std.Thread.getCpuCount() catch 2) -| 1));
        self.threads = try gpa.alloc(std.Thread, want);
        errdefer gpa.free(self.threads);
        var spawned: usize = 0;
        errdefer {
            self.stop();
            for (self.threads[0..spawned]) |th| th.join();
        }
        for (self.threads) |*th| {
            th.* = try std.Thread.spawn(.{}, workerMain, .{self});
            spawned += 1;
        }
        return self;
    }

    fn stop(self: *Pool) void {
        self.shutdown.store(true, .release);
        _ = self.wake.fetchAdd(1, .release);
        futexWake(&self.wake, std.math.maxInt(i32));
    }

    /// Blocks (joins workers) — shutdown only, never the hot path.
    /// Remaining queued tasks are completed on this thread first, so
    /// every non-detached handle polls to completion before teardown.
    pub fn deinit(self: *Pool) void {
        assertMayBlock();
        self.stop();
        for (self.threads) |th| th.join();
        while (self.popAll()) |batch| runBatch(batch);
        const gpa = self.gpa;
        gpa.free(self.threads);
        gpa.destroy(self);
    }

    /// Wire the pool's completion signal to a scheduler wake-fd (idempotent;
    /// pass `null` to unwire). The caller owns the fd's lifetime.
    pub fn setNotifyFd(self: *Pool, fd: ?std.posix.fd_t) void {
        self.notify_fd = fd;
    }

    /// Submit `f(args...)` to the pool. Lock-free; safe on the hot path.
    /// The returned handle is poll-only. For BOUNDED work — a save, a parse,
    /// a directory walk — that finishes and gives its worker back.
    pub fn spawn(
        self: *Pool,
        comptime f: anytype,
        args: std.meta.ArgsTuple(@TypeOf(f)),
    ) Allocator.Error!Handle(ReturnOf(f)) {
        const Container = TaskContainer(f);
        const c = try self.gpa.create(Container);
        c.* = .{ .node = .{ .pool = self, .runFn = Container.run, .destroyFn = Container.destroy }, .args = args };
        self.push(&c.node);
        return .{ .pool = self, .node = &c.node, .result = &c.result };
    }

    /// Run `f(args...)` on its OWN thread, with the same poll-only handle.
    /// For a task that blocks for as long as its SUBJECT lives — a session's
    /// reader loop, pinned on its peer's stdout until the peer exits. Such a
    /// task is not work a pool can schedule around: each one holds a worker
    /// for the whole session, so a handful of language servers, agents and
    /// REPLs would starve every save and gather behind them, and the one
    /// past the last worker would never start at all. Residency makes the
    /// number of live sessions independent of the worker count.
    pub fn spawnResident(
        self: *Pool,
        comptime f: anytype,
        args: std.meta.ArgsTuple(@TypeOf(f)),
    ) (Allocator.Error || std.Thread.SpawnError)!Handle(ReturnOf(f)) {
        const Container = TaskContainer(f);
        const c = try self.gpa.create(Container);
        errdefer self.gpa.destroy(c);
        c.* = .{ .node = .{ .pool = self, .runFn = Container.run, .destroyFn = Container.destroy }, .args = args };
        const thread = try std.Thread.spawn(.{}, runResident, .{&c.node});
        thread.detach(); // the handle, not the join, is how a caller waits
        return .{ .pool = self, .node = &c.node, .result = &c.result };
    }

    fn push(self: *Pool, node: *Node) void {
        var head = self.injector.load(.monotonic);
        while (true) {
            node.next = head;
            head = self.injector.cmpxchgWeak(head, node, .release, .monotonic) orelse break;
        }
        _ = self.wake.fetchAdd(1, .release);
        futexWake(&self.wake, 1);
    }

    /// Pop the whole stack, reversed into submission (FIFO) order.
    fn popAll(self: *Pool) ?*Node {
        var head = self.injector.swap(null, .acquire) orelse return null;
        var fifo: ?*Node = null;
        while (true) {
            const next = head.next;
            head.next = fifo;
            fifo = head;
            head = next orelse return fifo;
        }
    }

    fn runBatch(first: *Node) void {
        var cur: ?*Node = first;
        while (cur) |node| {
            cur = node.next;
            node.runFn(node);
        }
    }

    fn workerMain(self: *Pool) void {
        while (true) {
            const gen = self.wake.load(.acquire);
            if (self.popAll()) |batch| {
                runBatch(batch);
                continue;
            }
            if (self.shutdown.load(.acquire)) return;
            futexWait(&self.wake, gen);
        }
    }
};

fn ReturnOf(comptime f: anytype) type {
    return @typeInfo(@TypeOf(f)).@"fn".return_type.?;
}

fn runResident(node: *Node) void {
    node.runFn(node);
}

fn TaskContainer(comptime f: anytype) type {
    return struct {
        node: Node,
        args: std.meta.ArgsTuple(@TypeOf(f)),
        result: ReturnOf(f) = undefined,

        const Container = @This();

        fn run(node: *Node) void {
            const self: *Container = @alignCast(@fieldParentPtr("node", node));
            // Captured before the node can possibly be freed below (a
            // detached handle's second-finisher destroys it immediately).
            const pool = node.pool;
            self.result = @call(.auto, f, self.args);
            // Publish, then hand off ownership if the holder detached.
            if (node.state.cmpxchgStrong(Node.pending, Node.done, .release, .acquire)) |actual| {
                assert(actual == Node.detached);
                node.destroyFn(node, node.pool.gpa);
            }
            if (pool.notify_fd) |fd| scheduler.signalWakeFd(fd);
        }

        fn destroy(node: *Node, gpa: Allocator) void {
            const self: *Container = @alignCast(@fieldParentPtr("node", node));
            gpa.destroy(self);
        }
    };
}

/// A poll-only completion handle. There is deliberately no `wait`.
pub fn Handle(comptime T: type) type {
    return struct {
        pool: *Pool,
        node: *Node,
        result: *T,

        const Self = @This();

        /// Non-blocking: the result if the task finished (consumes the
        /// handle), null if still in flight.
        pub fn poll(self: *Self) ?T {
            if (self.node.state.load(.acquire) != Node.done) return null;
            const value = self.result.*;
            self.node.destroyFn(self.node, self.pool.gpa);
            self.* = undefined;
            return value;
        }

        /// Abandon the result; whoever finishes second frees the node.
        pub fn detach(self: *Self) void {
            if (self.node.state.cmpxchgStrong(Node.pending, Node.detached, .acq_rel, .acquire)) |actual| {
                assert(actual == Node.done);
                self.node.destroyFn(self.node, self.pool.gpa);
            }
            self.* = undefined;
        }
    };
}

// ── Tests ───────────────────────────────────────────────────────────
// The busy-wait loops here are test-harness scaffolding, not an API —
// production consumers poll once per frame.

const t = std.testing;

fn square(x: u64) u64 {
    return x * x;
}

fn mightFail(fail: bool) error{Refused}!u32 {
    return if (fail) error.Refused else 17;
}

test "pool: spawn many, poll-only completion" {
    var pool = try Pool.init(t.allocator, .{ .threads = 3 });
    defer pool.deinit();

    var handles: [64]Handle(u64) = undefined;
    for (&handles, 0..) |*h, i| h.* = try pool.spawn(square, .{i});

    var sum: u64 = 0;
    var remaining: usize = handles.len;
    var live: [64]bool = @splat(true);
    while (remaining > 0) {
        for (&handles, &live) |*h, *alive| {
            if (!alive.*) continue;
            if (h.poll()) |v| {
                sum += v;
                alive.* = false;
                remaining -= 1;
            }
        }
        std.Thread.yield() catch {};
    }
    var want: u64 = 0;
    for (0..handles.len) |i| want += @as(u64, i) * i;
    try t.expectEqual(want, sum);
}

test "pool: fallible request — the error comes back through poll" {
    var pool = try Pool.init(t.allocator, .{ .threads = 1 });
    defer pool.deinit();
    var ok = try pool.spawn(mightFail, .{false});
    var bad = try pool.spawn(mightFail, .{true});
    var got_ok: ?error{Refused}!u32 = null;
    var got_bad: ?error{Refused}!u32 = null;
    while (got_ok == null or got_bad == null) {
        if (got_ok == null) got_ok = ok.poll();
        if (got_bad == null) got_bad = bad.poll();
        std.Thread.yield() catch {};
    }
    try t.expectEqual(@as(u32, 17), try got_ok.?);
    try t.expectError(error.Refused, got_bad.?);
}

test "pool: detached tasks free themselves; queued work survives deinit" {
    var pool = try Pool.init(t.allocator, .{ .threads = 2 });
    var h1 = try pool.spawn(square, .{9});
    h1.detach();
    var h2 = try pool.spawn(square, .{7});
    h2.detach();
    // Leak checking is the assertion: t.allocator fails the test if any
    // node outlives the pool.
    pool.deinit();
}

test "hot-section fence flags" {
    try t.expect(!inHotSection());
    beginHotSection();
    try t.expect(inHotSection());
    endHotSection();
    try t.expect(!inHotSection());
    assertMayBlock();
}

/// Monotonic clock: a RAW syscall (`linux.clock_gettime` — no libc, so no
/// vDSO fast path either; this is a real syscall, not the ~free vDSO call
/// glibc's `clock_gettime` would resolve to) — chosen over `std.Io`'s clock
/// so hot-path/measurement call sites don't have to carry an `Io` instance
/// for a timestamp. Still cheap relative to anything it might be timing.
pub fn nowNs() u64 {
    var ts: linux.timespec = undefined;
    const rc = linux.clock_gettime(.MONOTONIC, &ts);
    assert(linux.errno(rc) == .SUCCESS); // CLOCK_MONOTONIC is always supported on Linux
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}
