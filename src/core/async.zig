//! A frame-thread event loop over `task.Pool`: guest-driven background
//! tasks and one-shot/repeating timers whose completion sinks fire *on the
//! frame thread* during `tick`. Locus-blind and local-only (design §9) —
//! the smallest gated capability, and the delivery substrate every
//! subprocess/network primitive folds its completions through, so those
//! never touch the frame thread directly.
//!
//! Sandbox-shaped by construction: work runs off-thread and hands back an
//! owned byte buffer (bulk transfer, no host pointers), delivered to an
//! opaque sink. The CRDT-peer model makes off-thread edits sound, but v1
//! keeps *delivery* on-frame so a callback can safely touch editor state.

const std = @import("std");
const Allocator = std.mem.Allocator;

const task = @import("task.zig");

/// Opaque handle to a live task/timer, for `cancel`.
pub const Id = enum(u64) { _ };

/// A completion callback, fired on the frame thread. `result` is the task's
/// output bytes (borrowed for the call; freed after), or null when the work
/// failed or the sink belongs to a timer (which carries no payload).
pub const Sink = struct {
    ctx: ?*anyopaque = null,
    call: *const fn (ctx: ?*anyopaque, result: ?[]const u8) void,
    /// Optional teardown for `ctx`, invoked exactly once in EVERY terminal
    /// case — after delivery, on cancel, and at loop teardown — so a sink
    /// that owns heap state (a deferred edit's captured target) never leaks,
    /// whichever way its task ends. One-shot timers deinit after firing;
    /// repeating timers only on cancel/removal.
    deinit: ?*const fn (ctx: ?*anyopaque) void = null,

    fn teardown(self: Sink) void {
        if (self.deinit) |d| d(self.ctx);
    }
};

/// The guest's background work: runs on a pool thread, returns owned bytes
/// (the loop frees them after the sink sees them). An error becomes a
/// null-result sink — "the result never arrived", the one honest failure.
pub const Work = *const fn (gpa: Allocator, ctx: ?*anyopaque) anyerror![]u8;

pub const Loop = struct {
    gpa: Allocator,
    pool: *task.Pool,
    /// Injectable clock (tests drive timers deterministically).
    now: *const fn () u64,
    next_id: u64 = 1,
    tasks: std.ArrayList(Task) = .empty,
    timers: std.ArrayList(Timer) = .empty,

    const Result = anyerror![]u8;

    const Task = struct {
        id: Id,
        handle: task.Handle(Result),
        sink: Sink,
        canceled: bool = false,
    };

    const Timer = struct {
        id: Id,
        due_ns: u64,
        /// 0 = one-shot; otherwise the reschedule interval.
        interval_ns: u64,
        sink: Sink,
        canceled: bool = false,
    };

    pub fn init(gpa: Allocator, pool: *task.Pool, now: *const fn () u64) Loop {
        return .{ .gpa = gpa, .pool = pool, .now = now };
    }

    /// Shutdown: drain in-flight tasks to completion so their result bytes
    /// are freed (same spin-at-teardown contract as `Editor.deinit`; off the
    /// hot path, blocking allowed). Sinks are NOT fired during teardown.
    pub fn deinit(self: *Loop) void {
        task.assertMayBlock();
        for (self.tasks.items) |*tk| {
            while (true) {
                if (tk.handle.poll()) |res| {
                    if (res) |bytes| self.gpa.free(bytes) else |_| {}
                    break;
                }
                std.atomic.spinLoopHint();
            }
            tk.sink.teardown();
        }
        for (self.timers.items) |tm| tm.sink.teardown();
        self.tasks.deinit(self.gpa);
        self.timers.deinit(self.gpa);
    }

    /// The earliest due time among live (non-canceled) timers, or null if
    /// there are none — a pure query so a scheduler deadline source can
    /// sleep exactly until this loop's next timer needs `tick` instead of
    /// being serviced by accident on whatever cadence something else wakes
    /// the frame thread (north-star-plan §6 W2a-3).
    pub fn nextDueNs(self: *const Loop) ?u64 {
        var min: ?u64 = null;
        for (self.timers.items) |tm| {
            if (tm.canceled) continue;
            if (min == null or tm.due_ns < min.?) min = tm.due_ns;
        }
        return min;
    }

    fn fresh(self: *Loop) Id {
        const id: Id = @enumFromInt(self.next_id);
        self.next_id += 1;
        return id;
    }

    /// Run `work` off-thread; deliver its bytes to `sink` on a later `tick`.
    pub fn spawn(self: *Loop, work: Work, work_ctx: ?*anyopaque, sink: Sink) !Id {
        const handle = try self.pool.spawn(runWork, .{ self.gpa, work, work_ctx });
        const id = self.fresh();
        errdefer {
            var h = handle;
            h.detach();
        }
        try self.tasks.append(self.gpa, .{ .id = id, .handle = handle, .sink = sink });
        return id;
    }

    /// Fire `sink` after `delay_ns`, then every `interval_ns` (0 = one-shot).
    pub fn timer(self: *Loop, delay_ns: u64, interval_ns: u64, sink: Sink) !Id {
        const id = self.fresh();
        try self.timers.append(self.gpa, .{
            .id = id,
            .due_ns = self.now() + delay_ns,
            .interval_ns = interval_ns,
            .sink = sink,
        });
        return id;
    }

    /// Mark a task/timer canceled: its sink will not fire. A task already
    /// running still completes on the pool; the loop drops its result.
    pub fn cancel(self: *Loop, id: Id) void {
        for (self.timers.items) |*tm| if (tm.id == id) {
            tm.canceled = true;
            return;
        };
        for (self.tasks.items) |*tk| if (tk.id == id) {
            tk.canceled = true;
            return;
        };
    }

    /// Once per frame: deliver finished tasks and fire due timers, both on
    /// this (the frame) thread. Returns whether any sink fired (so the frame
    /// loop can repaint after an async completion). Sinks may spawn/cancel
    /// re-entrantly — each entry is removed or rescheduled BEFORE its sink
    /// runs, so the lists stay consistent and no pointer is held across a
    /// callback.
    pub fn tick(self: *Loop) bool {
        var fired = false;
        var i: usize = 0;
        while (i < self.tasks.items.len) {
            if (self.tasks.items[i].handle.poll()) |res| {
                const tk = self.tasks.items[i]; // sink+canceled copy (handle now spent)
                _ = self.tasks.swapRemove(i);
                if (tk.canceled) {
                    if (res) |bytes| self.gpa.free(bytes) else |_| {}
                } else if (res) |bytes| {
                    defer self.gpa.free(bytes);
                    tk.sink.call(tk.sink.ctx, bytes);
                    fired = true;
                } else |_| {
                    tk.sink.call(tk.sink.ctx, null);
                    fired = true;
                }
                tk.sink.teardown(); // every terminal task case frees its sink ctx
            } else i += 1;
        }

        const now = self.now();
        i = 0;
        while (i < self.timers.items.len) {
            const tm = self.timers.items[i]; // copy: nothing held across the call
            if (tm.canceled) {
                _ = self.timers.swapRemove(i);
                tm.sink.teardown();
                continue;
            }
            if (now < tm.due_ns) {
                i += 1;
                continue;
            }
            if (tm.interval_ns > 0) {
                self.timers.items[i].due_ns = now + tm.interval_ns;
                i += 1;
                tm.sink.call(tm.sink.ctx, null); // repeating: sink ctx persists
            } else {
                _ = self.timers.swapRemove(i);
                tm.sink.call(tm.sink.ctx, null);
                tm.sink.teardown(); // one-shot: done, free its ctx
            }
            fired = true;
        }
        return fired;
    }
};

fn runWork(gpa: Allocator, work: Work, ctx: ?*anyopaque) Loop.Result {
    return work(gpa, ctx);
}

// ── Tests ───────────────────────────────────────────────────────────

const t = std.testing;

fn produce(gpa: Allocator, ctx: ?*anyopaque) anyerror![]u8 {
    _ = ctx;
    return gpa.dupe(u8, "delivered");
}

const Recorder = struct {
    hits: usize = 0,
    last: [64]u8 = undefined,
    last_len: usize = 0,
    got_null: bool = false,

    fn sink(self: *Recorder) Sink {
        return .{ .ctx = self, .call = onCall };
    }
    fn onCall(ctx: ?*anyopaque, result: ?[]const u8) void {
        const self: *Recorder = @ptrCast(@alignCast(ctx.?));
        self.hits += 1;
        if (result) |bytes| {
            @memcpy(self.last[0..bytes.len], bytes);
            self.last_len = bytes.len;
        } else self.got_null = true;
    }
};

test "async: a spawned task delivers its bytes to the sink on tick" {
    var pool = try task.Pool.init(t.allocator, .{ .threads = 2 });
    defer pool.deinit();
    var loop = Loop.init(t.allocator, pool, task.nowNs);
    defer loop.deinit();

    var rec: Recorder = .{};
    _ = try loop.spawn(produce, null, rec.sink());
    var rounds: usize = 0;
    while (rec.hits == 0 and rounds < 100000) : (rounds += 1) {
        _ = loop.tick();
        std.Thread.yield() catch {};
    }
    try t.expectEqual(@as(usize, 1), rec.hits);
    try t.expectEqualStrings("delivered", rec.last[0..rec.last_len]);
}

test "async: a one-shot timer fires once; cancel suppresses it" {
    var pool = try task.Pool.init(t.allocator, .{ .threads = 1 });
    defer pool.deinit();
    var loop = Loop.init(t.allocator, pool, task.nowNs);
    defer loop.deinit();

    var fired: Recorder = .{};
    _ = try loop.timer(0, 0, fired.sink()); // due immediately
    _ = loop.tick();
    try t.expectEqual(@as(usize, 1), fired.hits);
    _ = loop.tick(); // one-shot: does not fire again
    try t.expectEqual(@as(usize, 1), fired.hits);

    var canceled: Recorder = .{};
    const id = try loop.timer(0, 0, canceled.sink());
    loop.cancel(id);
    _ = loop.tick();
    try t.expectEqual(@as(usize, 0), canceled.hits);
}

test "async: a canceled task's result is dropped, its sink never fires" {
    var pool = try task.Pool.init(t.allocator, .{ .threads = 2 });
    defer pool.deinit();
    var loop = Loop.init(t.allocator, pool, task.nowNs);
    defer loop.deinit();

    var rec: Recorder = .{};
    const id = try loop.spawn(produce, null, rec.sink());
    loop.cancel(id);
    var rounds: usize = 0;
    while (loop.tasks.items.len > 0 and rounds < 100000) : (rounds += 1) {
        _ = loop.tick();
        std.Thread.yield() catch {};
    }
    try t.expectEqual(@as(usize, 0), rec.hits); // dropped, not delivered
}

test {
    std.testing.refAllDecls(@This());
}
