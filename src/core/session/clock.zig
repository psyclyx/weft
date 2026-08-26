//! Monotonic time seam for the session subsystem: liveness windows, the
//! writer's heartbeat cadence, and chaos propagation eligibility all read
//! `now` through here instead of calling the platform clock directly.
//!
//! Production keeps the raw `task.nowNs` syscall — `Clock.real` carries a
//! null function pointer, so `nowNs` is a null test and the same direct
//! call the call sites made before. Tests hand a `Virtual` clock to
//! `Session.createOn`/`ChaosLink.startOn` and advance it by hand, so a 3s
//! degraded window or a 200ms propagation delay costs no wall time.

const std = @import("std");
const task = @import("../task.zig");

pub const Clock = struct {
    ctx: ?*anyopaque = null,
    /// Null means the platform clock; see the module doc for why.
    nowFn: ?*const fn (ctx: ?*anyopaque) u64 = null,

    pub const real: Clock = .{};

    pub fn nowNs(self: Clock) u64 {
        const now = self.nowFn orelse return task.nowNs();
        return now(self.ctx);
    }
};

/// A hand-advanced clock. Session's reader/writer threads and the chaos
/// delivery worker sample it concurrently with the test thread, so the
/// counter is atomic.
pub const Virtual = struct {
    ns: std.atomic.Value(u64) = .init(0),

    pub fn clock(self: *Virtual) Clock {
        return .{ .ctx = self, .nowFn = now };
    }

    pub fn advance(self: *Virtual, delta_ns: u64) void {
        _ = self.ns.fetchAdd(delta_ns, .release);
    }

    fn now(ctx: ?*anyopaque) u64 {
        const self: *Virtual = @ptrCast(@alignCast(ctx.?));
        return self.ns.load(.acquire);
    }
};

test "clock: the default is the platform clock; a virtual one only moves by hand" {
    const t = std.testing;
    const before = Clock.real.nowNs();
    try t.expect(Clock.real.nowNs() >= before);

    var virtual: Virtual = .{};
    const c = virtual.clock();
    try t.expectEqual(@as(u64, 0), c.nowNs());
    virtual.advance(4 * std.time.ns_per_s);
    try t.expectEqual(4 * std.time.ns_per_s, c.nowNs());
    try t.expectEqual(4 * std.time.ns_per_s, c.nowNs());
}
