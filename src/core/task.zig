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
    /// Set for a resident task: its registry record, marked exited before
    /// the completion below publishes (so observing `done` implies exited).
    resident: ?*Resident = null,
    /// Completion/ownership handoff: whichever of {worker finishing,
    /// holder detaching} comes second frees the node; `poll` frees on
    /// consumption.
    state: std.atomic.Value(u8) = .init(pending),

    const pending: u8 = 0;
    const done: u8 = 1;
    const detached: u8 = 2;
};

/// One resident's registry record. The pool owns it; the resident thread
/// touches only `exited`, so a record can never be freed under a running
/// thread's feet.
const Resident = struct {
    /// Static — a stuck resident is reported by this name, long after the
    /// caller's own memory may be gone.
    name: []const u8,
    stop: ?Stop,
    exited: std.atomic.Value(bool) = .init(false),
    /// The handle is gone (polled to completion or detached), so no one will
    /// ask this record anything again. Guarded by `residents_mutex`; a record
    /// is reapable only once it is BOTH released and exited, so a spawn can
    /// never free a record a live handle still reads.
    released: bool = false,
};

/// How `Pool.deinit` asks a resident to leave: close its socket, kill its
/// child, signal its wake fd — whatever unblocks the loop it is parked in.
///
/// `context` must stay valid until the resident exits. Every session in
/// this tree joins its own reader before freeing itself, and a joined
/// resident is already marked exited, so a freed session is never stopped.
pub const Stop = struct {
    context: *anyopaque,
    call: *const fn (*anyopaque) void,

    /// Type-safe constructor: `.of(session, Session.shutdownForStop)`.
    pub fn of(context: anytype, comptime f: fn (@TypeOf(context)) void) Stop {
        const Ctx = @TypeOf(context);
        const shim = struct {
            fn call(erased: *anyopaque) void {
                f(@ptrCast(@alignCast(erased)));
            }
        };
        comptime assert(@typeInfo(Ctx) == .pointer);
        return .{ .context = context, .call = shim.call };
    }
};

pub const ResidentOptions = struct {
    /// Static, for the loud report when this one will not leave.
    name: []const u8,
    stop: ?Stop = null,
};

/// How long `deinit` waits for a signalled resident before giving up on it.
const resident_join_deadline_ns = 2 * std.time.ns_per_s;

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
    /// Every resident spawned and not yet reaped. A resident outlives the
    /// tasks a worker runs, so `deinit` cannot simply join threads: it has
    /// to ASK each one to leave (`Stop`) and then find out whether it did.
    residents: std.ArrayList(*Resident) = .empty,
    residents_mutex: Mutex = .{},
    join_deadline_ns: u64 = resident_join_deadline_ns,

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

    /// Blocks (joins workers AND residents) — shutdown only, never the hot
    /// path. Remaining queued tasks are completed on this thread first, so
    /// every non-detached handle polls to completion before teardown.
    ///
    /// Residents are threads the pool does not schedule and cannot preempt:
    /// each one is parked on a peer's fd for that peer's whole life. So they
    /// are SIGNALLED (their `Stop`: kill the child, shut the socket) and then
    /// joined with a BOUND — a peer that ignores SIGKILL (an unkillable
    /// D-state read) must not buy an unbounded shutdown hang.
    ///
    /// If one will not leave, the only safe move is to LEAK the pool: the
    /// resident still holds a `*Pool` (it signals `notify_fd` on completion),
    /// so freeing it here would be the use-after-free this bound exists to
    /// avoid. Loud (`log.warn`, by name — `proc_stream.deinit`'s precedent for
    /// the same trade) because a leak that never surfaces is
    /// worse than one that does.
    pub fn deinit(self: *Pool) void {
        assertMayBlock();
        self.stop();
        for (self.threads) |th| th.join();
        while (self.popAll()) |batch| runBatch(batch);
        if (!self.joinResidents()) return; // deliberate leak — see above
        const gpa = self.gpa;
        gpa.free(self.threads);
        self.residents.deinit(gpa);
        gpa.destroy(self);
    }

    /// Signal every live resident, wait out the bound, and free the records
    /// of those that left. False = at least one is still running (named in
    /// the log), so nothing the pool owns may be freed.
    fn joinResidents(self: *Pool) bool {
        self.residents_mutex.lock();
        defer self.residents_mutex.unlock();
        for (self.residents.items) |r| {
            if (r.exited.load(.acquire)) continue;
            if (r.stop) |s| s.call(s.context);
        }
        const deadline = nowNs() + self.join_deadline_ns;
        var stuck: usize = 0;
        for (self.residents.items) |r| {
            while (!r.exited.load(.acquire)) {
                if (nowNs() >= deadline) break;
                std.atomic.spinLoopHint();
            }
            if (!r.exited.load(.acquire)) {
                stuck += 1;
                std.log.warn(
                    "task: resident '{s}' did not exit within {d}ms — its peer is ignoring shutdown; leaking the pool rather than freeing state it still touches",
                    .{ r.name, self.join_deadline_ns / std.time.ns_per_ms },
                );
            }
        }
        if (stuck > 0) return false;
        for (self.residents.items) |r| self.gpa.destroy(r);
        self.residents.clearRetainingCapacity();
        return true;
    }

    /// Test-only: shrink the resident join bound so a test can prove it is
    /// bounded without paying the production wait.
    pub fn setJoinDeadlineForTesting(self: *Pool, ns: u64) void {
        self.join_deadline_ns = ns;
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
    /// `opts` is how shutdown reaches it: a static name for the report and
    /// the signal that unblocks its loop (see `Stop`).
    pub fn spawnResident(
        self: *Pool,
        opts: ResidentOptions,
        comptime f: anytype,
        args: std.meta.ArgsTuple(@TypeOf(f)),
    ) (Allocator.Error || std.Thread.SpawnError)!Handle(ReturnOf(f)) {
        const Container = TaskContainer(f);
        const c = try self.gpa.create(Container);
        errdefer self.gpa.destroy(c);
        const record = try self.registerResident(opts);
        errdefer self.forgetResident(record);
        c.* = .{
            .node = .{ .pool = self, .runFn = Container.run, .destroyFn = Container.destroy, .resident = record },
            .args = args,
        };
        const thread = try std.Thread.spawn(.{}, runResident, .{&c.node});
        thread.detach(); // the handle, not the join, is how a caller waits
        return .{ .pool = self, .node = &c.node, .result = &c.result };
    }

    /// Records live until shutdown or the next spawn: released-and-exited
    /// ones are reaped here, so a session churn (open/close a hundred files)
    /// cannot grow the registry without bound, and only this thread ever
    /// walks the list.
    fn registerResident(self: *Pool, opts: ResidentOptions) Allocator.Error!*Resident {
        const record = try self.gpa.create(Resident);
        errdefer self.gpa.destroy(record);
        record.* = .{ .name = opts.name, .stop = opts.stop };
        self.residents_mutex.lock();
        defer self.residents_mutex.unlock();
        var i: usize = 0;
        while (i < self.residents.items.len) {
            const r = self.residents.items[i];
            if (r.released and r.exited.load(.acquire)) {
                _ = self.residents.swapRemove(i);
                self.gpa.destroy(r);
            } else i += 1;
        }
        try self.residents.append(self.gpa, record);
        return record;
    }

    /// The handle holder is done with this record: from here the next spawn
    /// may reap it, once its thread has also left.
    fn releaseResident(self: *Pool, record: *Resident) void {
        self.residents_mutex.lock();
        defer self.residents_mutex.unlock();
        record.released = true;
    }

    fn forgetResident(self: *Pool, record: *Resident) void {
        self.residents_mutex.lock();
        defer self.residents_mutex.unlock();
        for (self.residents.items, 0..) |r, i| {
            if (r != record) continue;
            _ = self.residents.swapRemove(i);
            break;
        }
        self.gpa.destroy(record);
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
            const gpa = pool.gpa;
            const record = node.resident;
            self.result = @call(.auto, f, self.args);
            // Publish, then hand off ownership if the holder detached.
            if (node.state.cmpxchgStrong(Node.pending, Node.done, .release, .acquire)) |actual| {
                assert(actual == Node.detached);
                node.destroyFn(node, gpa);
            }
            if (pool.notify_fd) |fd| scheduler.signalWakeFd(fd);
            // A resident's `exited` is its LAST WORD, after every touch of the
            // pool and of its own node: teardown joins on it and frees both
            // the moment it is true. The record itself stays the pool's, and
            // the pool cannot go while this is false.
            if (record) |r| r.exited.store(true, .release);
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
            if (self.node.resident) |r| self.pool.releaseResident(r);
            self.node.destroyFn(self.node, self.pool.gpa);
            self.* = undefined;
            return value;
        }

        /// Non-blocking: whether a RESIDENT task's thread has run its last
        /// instruction. This — not `poll` — is the join a session needs
        /// before freeing itself: it is published after the resident's final
        /// touch of anything, so teardown can no longer signal a freed
        /// subject. A pooled task has no thread of its own; completion is
        /// the same answer there.
        pub fn residentExited(self: Self) bool {
            const record = self.node.resident orelse
                return self.node.state.load(.acquire) == Node.done;
            return record.exited.load(.acquire);
        }

        /// Abandon the result; whoever finishes second frees the node.
        pub fn detach(self: *Self) void {
            if (self.node.resident) |r| self.pool.releaseResident(r);
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

/// A resident that parks until someone releases its gate — the test stand-in
/// for a reader blocked on a peer's fd.
const Parked = struct {
    gate: std.atomic.Value(bool) = .init(false),

    fn park(self: *Parked) void {
        while (!self.gate.load(.acquire)) std.atomic.spinLoopHint();
    }

    fn release(self: *Parked) void {
        self.gate.store(true, .release);
    }
};

test "pool: deinit signals residents, joins them, and reaps their records" {
    var pool = try Pool.init(t.allocator, .{ .threads = 1 });
    var parked: Parked = .{};
    var h = try pool.spawnResident(
        .{ .name = "test parked", .stop = .of(&parked, Parked.release) },
        Parked.park,
        .{&parked},
    );
    h.detach();
    // No release here: only `deinit`'s signal can end this resident. Leak
    // checking is the assertion — the registry record must be gone too.
    pool.deinit();
}

test "pool: a spawn reaps a record only once no handle can still read it" {
    var pool = try Pool.init(t.allocator, .{ .threads = 1 });
    var parked: Parked = .{};
    var h = try pool.spawnResident(.{ .name = "test exited" }, Parked.park, .{&parked});
    parked.release();
    while (!h.residentExited()) std.atomic.spinLoopHint();

    // Exited, but `h` still answers FROM the record, so a later spawn may not
    // free it — the join a session runs at its own teardown reads it.
    var live: Parked = .{};
    var live_h = try pool.spawnResident(
        .{ .name = "test live", .stop = .of(&live, Parked.release) },
        Parked.park,
        .{&live},
    );
    try t.expectEqual(@as(usize, 2), pool.residents.items.len);
    try t.expect(h.residentExited());

    _ = h.poll(); // the handle is gone; now it is reapable
    var third: Parked = .{};
    var third_h = try pool.spawnResident(
        .{ .name = "test third", .stop = .of(&third, Parked.release) },
        Parked.park,
        .{&third},
    );
    try t.expectEqual(@as(usize, 2), pool.residents.items.len);

    live_h.detach();
    third_h.detach();
    pool.deinit();
}

test "pool: a resident that ignores its signal is named, and the pool leaks instead of freeing under it" {
    // Deliberately leaked (see `Pool.deinit`), so not the checking allocator.
    const gpa = std.heap.page_allocator;
    var pool = try Pool.init(gpa, .{ .threads = 1 });
    pool.setJoinDeadlineForTesting(10 * std.time.ns_per_ms);
    var parked: Parked = .{};
    var h = try pool.spawnResident(.{ .name = "test unkillable" }, Parked.park, .{&parked});
    h.detach();
    pool.deinit(); // bounded: returns despite the resident still running
    parked.release();
    while (!pool.residents.items[0].exited.load(.acquire)) std.atomic.spinLoopHint();
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
