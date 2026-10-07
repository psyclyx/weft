//! The kernel event loop (doc/contextual-workspace-architecture.md §7,
//! re-diagnosed at §4 C16): registered SOURCES — each an fd (POLLIN/POLLOUT
//! readiness) or a deadline TIMER — and one `poll()`-based wait per `step`
//! that sleeps until the nearest due timer or fd readiness. No
//! fixed-cadence sleep, no zero-timeout spin unless a source's due time
//! genuinely IS now (a pending present retry, say).
//!
//! Dependency-free by design (`std.posix`/libc only, plus an injected
//! clock) so it knows nothing about wayland, vulkan, or collab —
//! those register sources naming their own fd/callback; the scheduler's only
//! job is "wait efficiently, then tell you what's ready."
//!
//! Timer callbacks (`onDue`) are, by convention (the type doesn't enforce
//! it — nothing here inspects what a callback does), PURE QUERIES: given
//! `now`, report the next absolute instant this source needs attention, or
//! `null` to go dormant. The state MUTATION they're reporting on typically
//! happens in the caller's own per-wake handling (main()'s frame body), not
//! inside the callback — one `step()` can wake for several reasons at once
//! and the caller runs one coherent pass, exactly as the pre-scheduler code
//! did on every vsync, except now the wake times are the REAL due times
//! instead of whatever vsync happened to deliver. A timer whose callback
//! also performs the side effect (key repeat's synthesis) is equally legal;
//! the type doesn't distinguish the two styles.
//!
//! **Ordering, and the lost-wakeup class it fixes** (found by review):
//! every timer is re-queried at the very TOP of `step`, before the poll
//! deadline is computed — never from a cache left over from at the tail of
//! a PREVIOUS `step`. The caller's per-wake body runs BETWEEN two `step`
//! calls (`step(); body(); step(); body(); …`), so a body mutation that
//! arms a timer (menu `open_ns`, `blink_next_ns`, `present_pending`, a
//! headless host's `last_change_ns`) is live state by the time the very
//! next `step` asks "when do you next need attention" — querying at the
//! top is what makes that mutation visible to THIS wait, not one step (or,
//! with no fds registered to force a re-visit, potentially forever) late.
//! Querying at the bottom instead — this module's first cut — computes the
//! deadline from whatever the timers looked like BEFORE the body ran,
//! which is exactly the bug class the frame loop had before any of this
//! existed, just moved one level down.
//!
//! `newWakeFd`/`signalWakeFd`/`drainWakeFd` are the canonical helpers for a
//! source that just needs "wake me, no payload" semantics (`task.Pool`'s
//! completion signal, `Hub`'s peer-activity signal, `Collab`'s
//! outbound-session signal, a pty reader's kick) — kept here so the
//! per-OS mechanism (an eventfd on Linux, a pipe elsewhere; see `Wake`)
//! lives in exactly one place. A source registered with `onReady = null` is
//! assumed to be one of these: `step` drains it itself.
//!
//! Callbacks (`onReady`/`onDue`) MAY freely call `addFd`/`removeFd`/
//! `addTimer`/`removeTimer` on this same scheduler (main.zig's hub/conn
//! sources come and go exactly this way, from inside the per-wake body a
//! `step` leads into) — `step` snapshots what it's about to dispatch
//! before invoking any callback, so a mutation mid-dispatch can't
//! invalidate the iteration. One consequence: a SIBLING removed
//! mid-round still gets its snapshotted callback for that round — so an
//! `onReady` must not free another source's `ctx` (removal defers the
//! dispatch entry, not the memory it points at).

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const posix = std.posix;
const posix_fd = @import("posix_fd.zig");
const task = @import("task.zig");

pub const Id = enum(u32) { _ };

pub const FdInterest = struct {
    read: bool = false,
    write: bool = false,
};

const FdSource = struct {
    id: Id,
    fd: posix.fd_t,
    interest: FdInterest,
    ctx: ?*anyopaque,
    onReady: ?*const fn (ctx: ?*anyopaque, readable: bool, writable: bool) void,
    name: []const u8,
};

const TimerSource = struct {
    id: Id,
    ctx: ?*anyopaque,
    onDue: *const fn (ctx: ?*anyopaque, now_ns: u64) ?u64,
    due_ns: ?u64,
    name: []const u8,
};

pub const Scheduler = struct {
    gpa: Allocator,
    now: *const fn () u64,
    fds: std.ArrayList(FdSource) = .empty,
    timers: std.ArrayList(TimerSource) = .empty,
    next_id: u32 = 1,
    running: bool = true,
    /// Bumped once per completed `step` — the idle-wakeup instrument
    /// (doc/contextual-workspace-architecture.md §7's gate) reads this instead of counting
    /// frames, so it measures the scheduler's own wake rate directly.
    steps: u64 = 0,

    pub fn init(gpa: Allocator, now: *const fn () u64) Scheduler {
        return .{ .gpa = gpa, .now = now };
    }

    pub fn deinit(self: *Scheduler) void {
        self.fds.deinit(self.gpa);
        self.timers.deinit(self.gpa);
    }

    fn freshId(self: *Scheduler) Id {
        const id: Id = @enumFromInt(self.next_id);
        self.next_id += 1;
        return id;
    }

    /// Register an fd source. `onReady = null` marks it a plain wakeup fd
    /// (see the module doc) — `step` drains it itself instead of calling
    /// back. A real fd (wayland's display socket) wants its own `onReady`,
    /// even if that callback is a deliberate no-op (draining THAT fd is
    /// someone else's job — see `loop_sources.zig`'s `wayland fd` source).
    pub fn addFd(
        self: *Scheduler,
        fd: posix.fd_t,
        interest: FdInterest,
        ctx: ?*anyopaque,
        onReady: ?*const fn (ctx: ?*anyopaque, readable: bool, writable: bool) void,
        name: []const u8,
    ) !Id {
        const id = self.freshId();
        try self.fds.append(self.gpa, .{ .id = id, .fd = fd, .interest = interest, .ctx = ctx, .onReady = onReady, .name = name });
        return id;
    }

    pub fn removeFd(self: *Scheduler, id: Id) void {
        for (self.fds.items, 0..) |f, i| if (f.id == id) {
            _ = self.fds.swapRemove(i);
            return;
        };
    }

    /// Register a deadline source, queried immediately for its first due
    /// time so a `step` right after registering already accounts for it.
    pub fn addTimer(
        self: *Scheduler,
        ctx: ?*anyopaque,
        onDue: *const fn (ctx: ?*anyopaque, now_ns: u64) ?u64,
        name: []const u8,
    ) !Id {
        const id = self.freshId();
        const due = onDue(ctx, self.now());
        try self.timers.append(self.gpa, .{ .id = id, .ctx = ctx, .onDue = onDue, .due_ns = due, .name = name });
        return id;
    }

    pub fn removeTimer(self: *Scheduler, id: Id) void {
        for (self.timers.items, 0..) |tm, i| if (tm.id == id) {
            _ = self.timers.swapRemove(i);
            return;
        };
    }

    pub fn stop(self: *Scheduler) void {
        self.running = false;
    }

    const max_inline_fds = 32;

    /// One dispatch-ready fd source, snapshotted before any callback runs
    /// (see the module doc's callback-safety note).
    const Dispatch = struct {
        ctx: ?*anyopaque,
        onReady: ?*const fn (ctx: ?*anyopaque, readable: bool, writable: bool) void,
        fd: posix.fd_t,
        readable: bool,
        writable: bool,
    };

    /// One iteration: refresh every timer's due time FIRST (see the module
    /// doc's ordering note — this is what makes a just-armed timer visible
    /// to THIS wait), compute the poll deadline as the min of the live
    /// ones (infinite — block on fd readiness only — if none are armed),
    /// `poll()` the fds with that timeout, then dispatch whichever came
    /// back ready. Returns whether there was any reason to wake: a timer
    /// was already due when queried, an fd was ready, or the deadline was
    /// reached. False only when `step` is called with nothing registered
    /// at all (a caller bug — there is nothing to wait for, so it returns
    /// immediately rather than hanging in `poll` on an empty set with an
    /// infinite timeout).
    pub fn step(self: *Scheduler) !bool {
        const now0 = self.now();
        var min_due: ?u64 = null;
        var any = false;
        for (self.timers.items) |*tm| {
            // Compare against the PREVIOUS query's answer (whatever this
            // step found the timer at, last time it looked) before
            // overwriting it — this is "did a deadline this step waited on
            // get reached", independent of what the fresh query below
            // reports next. Catches a "fire, then go dormant" callback
            // (the one-shot test shape): the fresh query below no longer
            // reports the due time that just fired.
            const was_due = tm.due_ns != null and tm.due_ns.? <= now0;
            tm.due_ns = tm.onDue(tm.ctx, now0);
            // The fresh answer may ALSO already be due at this same
            // instant — a timer that just transitioned from dormant (or
            // "not yet") to "already due" as a pure side effect of state
            // the caller's last body pass changed (the lost-wakeup
            // regression tests' exact shape: nothing was due a moment ago,
            // querying now reports a due time already in the past). Pure
            // query callbacks that don't self-clear rely on THIS check,
            // not `was_due`, to be noticed the instant they arm.
            const now_due = tm.due_ns != null and tm.due_ns.? <= now0;
            if (was_due or now_due) any = true;
            if (tm.due_ns) |d| if (min_due == null or d < min_due.?) {
                min_due = d;
            };
        }

        if (self.fds.items.len == 0 and min_due == null) return any;

        var timeout_ms: i32 = -1;
        if (min_due) |due| {
            const now = self.now();
            const delta_ns = due -| now;
            var delta_ms = delta_ns / std.time.ns_per_ms;
            // Round a sub-millisecond remainder UP: better to wake a
            // fraction of a millisecond late than to spin back in here
            // before the deadline has actually arrived.
            if (delta_ns % std.time.ns_per_ms != 0) delta_ms += 1;
            timeout_ms = if (delta_ms > std.math.maxInt(i32)) std.math.maxInt(i32) else @intCast(delta_ms);
        }

        // A caller registering more than this is a real bug (weft's own
        // registrants top out around half a dozen) — fail loudly rather
        // than silently truncate the poll set (a truncated fd could sit
        // unpolled forever).
        std.debug.assert(self.fds.items.len <= max_inline_fds);
        const n_fds = self.fds.items.len;
        var buf: [max_inline_fds]posix.pollfd = undefined;
        for (self.fds.items[0..n_fds], 0..) |f, i| {
            var events: i16 = 0;
            if (f.interest.read) events |= posix.POLL.IN;
            if (f.interest.write) events |= posix.POLL.OUT;
            buf[i] = .{ .fd = f.fd, .events = events, .revents = 0 };
        }
        // Errors here are transient (signal races, resource pressure under
        // load) — treat as "nothing ready this time" and let the next step
        // reconsider, rather than propagating a hard failure out of the
        // kernel loop for a syscall hiccup.
        const ready = posix.poll(buf[0..n_fds], timeout_ms) catch 0;
        self.steps += 1;
        if (ready > 0) any = true;

        if (ready > 0) {
            // Snapshot BEFORE dispatching — see the module doc: a callback
            // may add/remove sources on this scheduler, which would
            // otherwise invalidate `self.fds`/indices mid-iteration.
            var to_dispatch: [max_inline_fds]Dispatch = undefined;
            var n_dispatch: usize = 0;
            var to_remove: [max_inline_fds]Id = undefined;
            var n_remove: usize = 0;

            for (self.fds.items[0..n_fds], 0..) |f, i| {
                const re = buf[i].revents;
                if (re == 0) continue;
                if ((re & (posix.POLL.ERR | posix.POLL.NVAL)) != 0) {
                    // A broken/stale fd reports ready forever with nothing
                    // to actually read — left registered it would spin the
                    // loop at full speed. Drop it; an owner that wants it
                    // back (main.zig's hub/conn reconciliation) notices its
                    // source is gone and re-registers, exactly as on a
                    // clean teardown.
                    std.log.warn("scheduler: fd source '{s}' reported POLLERR/POLLNVAL — removing it", .{f.name});
                    to_remove[n_remove] = f.id;
                    n_remove += 1;
                    continue;
                }
                to_dispatch[n_dispatch] = .{
                    .ctx = f.ctx,
                    .onReady = f.onReady,
                    .fd = f.fd,
                    .readable = (re & (posix.POLL.IN | posix.POLL.HUP)) != 0,
                    .writable = (re & posix.POLL.OUT) != 0,
                };
                n_dispatch += 1;
            }

            for (to_remove[0..n_remove]) |id| self.removeFd(id);
            for (to_dispatch[0..n_dispatch]) |d| {
                if (d.onReady) |cb| {
                    cb(d.ctx, d.readable, d.writable);
                } else {
                    drainWakeFd(d.fd);
                }
            }
        }

        return any;
    }

    /// `step` forever, running `onWake` once after each step that fired —
    /// the shape main()'s loop and headless's loop both reduce to (window
    /// sources for main; collab/pool sources and no window/present sources
    /// for headless — doc/contextual-workspace-architecture.md §7).
    pub fn run(self: *Scheduler, ctx: ?*anyopaque, onWake: *const fn (ctx: ?*anyopaque) anyerror!void) !void {
        while (self.running) {
            _ = try self.step();
            try onWake(ctx);
        }
    }
};

// ── Wakeup-fd convenience ("something happened, no payload") ──────────

/// The wake mechanism for this OS: an eventfd where there is one (a single
/// fd that is both ends, a counter that cannot fill), a pipe elsewhere.
const Wake = if (builtin.os.tag == .linux) EventFdWake else PipeWake;

/// A new wake fd: pollable for read, non-blocking, close-on-exec. It is ONE
/// fd on every OS — what a caller stores, registers with `addFd`, and hands
/// to `signalWakeFd` from another thread.
pub fn newWakeFd() !posix.fd_t {
    return Wake.new();
}

pub fn closeWakeFd(fd: posix.fd_t) void {
    Wake.close(fd);
}

/// Safe to call from any thread (that's the point — a reader/accept thread
/// signals main's scheduler this way): a nonblocking "something happened".
/// Signals coalesce — any number before a drain read as one. Best-effort; a
/// failed write here just means the next scheduled wake (a deadline
/// fallback, or the next unrelated fd activity) discovers the work instead
/// of this one — never a correctness issue, only ever a latency one.
pub fn signalWakeFd(fd: posix.fd_t) void {
    Wake.signal(fd);
}

/// Consume every signal so far: the fd is not readable again until the
/// next `signalWakeFd`.
pub fn drainWakeFd(fd: posix.fd_t) void {
    Wake.drain(fd);
}

/// Linux: an eventfd. A write adds to its counter, one read takes the whole
/// count and resets it — coalescing and drain-to-empty are the kernel's.
/// (EFD_NONBLOCK/EFD_CLOEXEC are defined as O_NONBLOCK/O_CLOEXEC.)
const EventFdWake = struct {
    const flags: u32 = @bitCast(std.c.O{ .NONBLOCK = true, .CLOEXEC = true });

    fn new() !posix.fd_t {
        const fd = std.c.eventfd(0, flags);
        if (fd < 0) return error.EventFdFailed;
        return fd;
    }

    fn close(fd: posix.fd_t) void {
        _ = std.c.close(fd);
    }

    fn signal(fd: posix.fd_t) void {
        const one: u64 = 1;
        _ = std.c.write(fd, std.mem.asBytes(&one), @sizeOf(u64));
    }

    fn drain(fd: posix.fd_t) void {
        var val: u64 = undefined;
        _ = std.c.read(fd, std.mem.asBytes(&val), @sizeOf(u64));
    }
};

/// Elsewhere (Darwin has no eventfd, and its `poll` cannot wait on a kqueue):
/// a non-blocking pipe. The read end IS the wake fd; the write end lives in
/// a process-wide table keyed by it, so callers keep holding one fd. A signal
/// writes one byte — a full pipe already reads as signalled, so EAGAIN is
/// the coalescing — and a drain reads until EAGAIN. Signal and close take the
/// table's lock around the write and the close, so a signal racing a close
/// can never write into a recycled fd number.
const PipeWake = struct {
    var lock: task.Mutex = .{};
    /// Read end → write end, for every live wake pipe.
    var write_ends: std.AutoHashMapUnmanaged(posix.fd_t, posix.fd_t) = .empty;

    fn new() !posix.fd_t {
        const fds = try posix_fd.pipe();
        lock.lock();
        defer lock.unlock();
        write_ends.put(std.heap.c_allocator, fds[0], fds[1]) catch {
            _ = std.c.close(fds[0]);
            _ = std.c.close(fds[1]);
            return error.OutOfMemory;
        };
        return fds[0];
    }

    fn close(fd: posix.fd_t) void {
        lock.lock();
        defer lock.unlock();
        if (write_ends.fetchRemove(fd)) |kv| _ = std.c.close(kv.value);
        _ = std.c.close(fd);
    }

    fn signal(fd: posix.fd_t) void {
        lock.lock();
        defer lock.unlock();
        const w = write_ends.get(fd) orelse return;
        _ = std.c.write(w, "!", 1);
    }

    fn drain(fd: posix.fd_t) void {
        var buf: [256]u8 = undefined;
        while (true) {
            const n = std.c.read(fd, &buf, buf.len);
            if (n > 0) continue;
            if (n < 0 and std.c.errno(n) == .INTR) continue;
            return; // EAGAIN: empty
        }
    }
};

// ── Tests ───────────────────────────────────────────────────────────

const t = std.testing;

var test_clock: u64 = 0;
fn testNow() u64 {
    return test_clock;
}

test "scheduler: nothing registered ⇒ step returns false without blocking" {
    var sched = Scheduler.init(t.allocator, testNow);
    defer sched.deinit();
    try t.expect(!try sched.step());
}

test "scheduler: a dormant timer alone still leaves step non-blocking" {
    const Q = struct {
        fn due(ctx: ?*anyopaque, now: u64) ?u64 {
            _ = ctx;
            _ = now;
            return null; // always dormant
        }
    };
    var sched = Scheduler.init(t.allocator, testNow);
    defer sched.deinit();
    _ = try sched.addTimer(null, Q.due, "dormant");
    try t.expect(!try sched.step());
}

test "scheduler: a due-now timer fires with a zero-latency wake" {
    const Q = struct {
        fn due(ctx: ?*anyopaque, now: u64) ?u64 {
            _ = ctx;
            return now; // always "due right now" — re-arms itself every step
        }
    };
    var sched = Scheduler.init(t.allocator, testNow);
    defer sched.deinit();
    _ = try sched.addTimer(null, Q.due, "immediate");
    try t.expect(try sched.step());
    try t.expect(try sched.step()); // still due — fires again
}

test "scheduler: a one-shot timer fires once, then goes dormant" {
    // A source that goes fully dormant (due_ns == null) is only
    // re-queried on a step that has some OTHER reason to run `poll` (an fd,
    // or another still-armed timer) — real callers always have at least one
    // fd registered (wayland's display socket, the pool's wake fd), so
    // this is the honest shape; see `step`'s doc for the "nothing at all
    // registered" early-out this test does not exercise.
    const Ctx = struct { fired: bool = false, due_ns: ?u64 = 5 };
    const Q = struct {
        fn due(ctx: ?*anyopaque, now: u64) ?u64 {
            const self: *Ctx = @ptrCast(@alignCast(ctx.?));
            const d = self.due_ns orelse return null;
            if (d > now) return d;
            self.fired = true;
            self.due_ns = null; // one-shot: dormant after firing
            return null;
        }
    };
    var sched = Scheduler.init(t.allocator, testNow);
    defer sched.deinit();
    var ctx: Ctx = .{};
    test_clock = 0;
    _ = try sched.addTimer(&ctx, Q.due, "one-shot");
    try t.expect(!ctx.fired); // not due yet (due_ns=5, now=0)

    test_clock = 10; // past due
    try t.expect(try sched.step());
    try t.expect(ctx.fired);

    // Dormant now — with nothing else registered, `step` returns false
    // rather than blocking or spinning.
    try t.expect(!try sched.step());
}

test "scheduler: an fd source wakes step() when its counterpart is written" {
    var sched = Scheduler.init(t.allocator, testNow);
    defer sched.deinit();

    const fds = try posix_fd.pipe();
    const read_fd = fds[0];
    const write_fd = fds[1];
    defer _ = std.c.close(read_fd);
    defer _ = std.c.close(write_fd);

    const Recorder = struct {
        var hit: bool = false;
        fn onReady(ctx: ?*anyopaque, readable: bool, writable: bool) void {
            _ = ctx;
            _ = writable;
            if (readable) hit = true;
        }
    };
    Recorder.hit = false;
    _ = try sched.addFd(read_fd, .{ .read = true }, null, Recorder.onReady, "test-pipe");

    // Nothing written yet: a bounded, non-hanging check — no timer is
    // armed and the pipe isn't ready, so step() would otherwise block
    // forever; skip the "not ready" assertion and go straight to proving
    // readiness wakes it (the interesting behavior here).
    _ = std.c.write(write_fd, "x", 1);
    try t.expect(try sched.step());
    try t.expect(Recorder.hit);
}

test "scheduler: a wake fd is drained by default (onReady = null)" {
    var sched = Scheduler.init(t.allocator, testNow);
    defer sched.deinit();
    const fd = try newWakeFd();
    defer closeWakeFd(fd);
    signalWakeFd(fd);
    _ = try sched.addFd(fd, .{ .read = true }, null, null, "wake");
    try t.expect(try sched.step());

    // Drained by `step` itself (no onReady given): nothing is pending, so
    // polling it directly (bypassing the scheduler, which would otherwise
    // legitimately block waiting for the NEXT signal) shows nothing.
    try t.expect(!isReadable(fd));
}

fn isReadable(fd: posix.fd_t) bool {
    var pfd = [1]posix.pollfd{.{ .fd = fd, .events = posix.POLL.IN, .revents = 0 }};
    _ = posix.poll(&pfd, 0) catch return false;
    return pfd[0].revents & posix.POLL.IN != 0;
}

test "scheduler: every wake mechanism coalesces signals and drains to empty" {
    // Both are exercised wherever they build, so the pipe Darwin runs on is
    // tested on Linux too.
    const mechanisms = if (builtin.os.tag == .linux) .{ EventFdWake, PipeWake } else .{PipeWake};
    inline for (mechanisms) |M| {
        const fd = try M.new();
        defer M.close(fd);
        try t.expect(!isReadable(fd));
        for (0..100_000) |_| M.signal(fd); // well past a pipe's buffer
        try t.expect(isReadable(fd));
        M.drain(fd);
        try t.expect(!isReadable(fd));
        M.signal(fd);
        try t.expect(isReadable(fd));
        M.drain(fd);
        try t.expect(!isReadable(fd));
    }
}

test "scheduler: removeFd/removeTimer take a source out of consideration" {
    const Q = struct {
        fn due(ctx: ?*anyopaque, now: u64) ?u64 {
            _ = ctx;
            return now;
        }
    };
    var sched = Scheduler.init(t.allocator, testNow);
    defer sched.deinit();
    const id = try sched.addTimer(null, Q.due, "removable");
    try t.expect(try sched.step());
    sched.removeTimer(id);
    try t.expect(!try sched.step());
}

test "scheduler: LOST-WAKEUP REGRESSION — a timer armed between two step() calls is honored on the VERY NEXT step" {
    // The probe shape (review finding #1): the caller's per-wake body runs
    // BETWEEN two `step()` calls and may arm a previously-dormant timer via
    // plain state mutation (menu `open_ns`, `blink_next_ns`,
    // `present_pending`, a headless host's `last_change_ns` — none of them
    // go through the scheduler to become due). A `step` that computes its
    // poll deadline from a cache left over from ITS OWN prior run (queried
    // at the tail, not the top) never sees this mutation — with no fds
    // registered to force a re-visit, `step` hits the early-out and would
    // never re-query the timer again, i.e. the arm is lost forever, not
    // just delayed.
    const Ctx = struct { armed_due: ?u64 = null };
    const Q = struct {
        fn due(ctx: ?*anyopaque, now: u64) ?u64 {
            _ = now;
            const self: *const Ctx = @ptrCast(@alignCast(ctx.?));
            return self.armed_due; // pure query — no mutation, mirrors the real sources
        }
    };
    var sched = Scheduler.init(t.allocator, testNow);
    defer sched.deinit();
    var ctx: Ctx = .{}; // dormant
    _ = try sched.addTimer(&ctx, Q.due, "probe");

    test_clock = 0;
    // Dormant, no fds: step returns immediately, not blocking.
    try t.expect(!try sched.step());

    // The "body" runs here, between two step() calls — exactly where
    // main.zig's per-wake body sits — and arms the timer for a time
    // already in the past.
    ctx.armed_due = 0;
    test_clock = 1;

    // THE VERY NEXT step() must see it. A `step` that queried its due-time
    // cache from before this mutation (the pre-fix ordering) would still
    // see `armed_due` as it was AT REGISTRATION (dormant) and return
    // false here — the lost wakeup this test guards against.
    try t.expect(try sched.step());
}

test "scheduler: LOST-WAKEUP REGRESSION — headless shape: a commit + peer-reap in ONE wake still autosaves without further traffic" {
    // Mirrors headless.zig's LoopState/wake/autosaveDue: a body that, in a
    // SINGLE call, both registers a change (arming the autosave-idle
    // deadline) and reaps the peer that was the loop's only other reason
    // to wake (an empty hub has nothing left to signal its wake-fd again).
    // Modeled directly against the scheduler (not real sockets/Hub) since
    // this is a claim about `step`'s ordering, not about collab wiring —
    // driven entirely by the injected clock, no real time elapsed.
    const autosave_window_ns: u64 = 2 * std.time.ns_per_s; // headless.zig's real constant
    const State = struct { last_change_ns: ?u64 = null };
    const Q = struct {
        fn autosaveDue(ctx: ?*anyopaque, now: u64) ?u64 {
            _ = now;
            const s: *const State = @ptrCast(@alignCast(ctx.?));
            const lc = s.last_change_ns orelse return null;
            return lc + autosave_window_ns;
        }
    };
    var sched = Scheduler.init(t.allocator, testNow);
    defer sched.deinit();
    var state: State = .{};
    _ = try sched.addTimer(&state, Q.autosaveDue, "autosave_idle");

    test_clock = 0;
    // Idle host, nothing pending, no peers: correctly does not block.
    try t.expect(!try sched.step());

    // ONE wake: commit arrives AND the peer that used to be the loop's
    // other wake reason is reaped, in the same body pass — from the
    // scheduler's point of view this is just "a dormant timer gets armed
    // by external state between two step() calls" with nothing else
    // registered to paper over a stale deadline.
    state.last_change_ns = test_clock;
    test_clock += autosave_window_ns; // "2s" later, per the injected clock

    // The VERY NEXT step must see the now-due deadline — no further
    // connection or traffic required to notice it (the actual save call
    // is headless.zig's `wake`'s job; this asserts the scheduler tells it
    // to run, which is the only part a lost-wakeup bug could break).
    try t.expect(try sched.step());
}

test {
    std.testing.refAllDecls(@This());
}
