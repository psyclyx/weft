//! Pointer gestures: the platform-neutral half of pointer input.
//!
//! A platform feeds this reducer the raw facts its protocol reports (a button
//! went down at time t, the pointer moved, the wheel turned by so much) and
//! drains ordered `PointerEvent`s. What a gesture IS — which press makes a
//! double click, how much wheel travel is one step, that a drag is motion
//! with a button held — is decided here, once, so every platform agrees and
//! the rules are testable without a compositor.
//!
//! Buttons are numbered the way the keymap names them (`mouse-1` is the
//! primary button, `mouse-2` the middle, `mouse-3` the secondary), so the
//! number a platform reports is the number a config binds.
//!
//! Nothing here knows what a click does. `app/pointer.zig` turns events into
//! keyspecs and hit facts; the keymap and its commands decide the rest.

const std = @import("std");
const Mods = @import("root.zig").Mods;

pub const PointerEvent = struct {
    kind: Kind,
    /// 1 primary, 2 middle, 3 secondary, 4+ extra buttons; 0 for motion and
    /// wheel.
    button: u8 = 0,
    /// Press only: 1, 2 or 3 (single, double, triple). A fourth quick press
    /// starts over at 1.
    clicks: u8 = 0,
    /// Press only: a single click that came AFTER the multi-click window of
    /// the previous press of this button but within `slow_click_ms` of it —
    /// the slow second click a list control reads as "rename" (anywhere:
    /// whether it hit the same thing is the consumer's question).
    slow: bool = false,
    /// Surface-local position in logical pixels. The consumer scales to
    /// framebuffer pixels; the platform owns the scale.
    x: f64,
    y: f64,
    mods: Mods = .{},
    /// Wheel only: whole steps. Positive `dy` scrolls toward the end of the
    /// document (the wheel turned toward the user); positive `dx` to the right.
    dx: i32 = 0,
    dy: i32 = 0,
    /// Motion only: the buttons held while moving, bit `n - 1` for button
    /// `n`. Nonzero makes the motion a drag.
    held: u16 = 0,

    pub const Kind = enum { press, release, motion, wheel };
};

pub const Axis = enum { vertical, horizontal };

/// Two presses of one button this close in time and space are one gesture.
/// The values follow the common desktop defaults; logical pixels, so HiDPI
/// needs no second threshold.
pub const multi_click_ms: u32 = 400;
pub const multi_click_px: f64 = 4;
/// A second press of a button later than a double click but within this
/// is a SLOW second click (`PointerEvent.slow`). Bounded by the multi-click
/// interval below, so it can never be half of a double click, and above,
/// so two unrelated clicks a while apart are not one gesture.
pub const slow_click_ms: u32 = 3 * multi_click_ms;
/// Continuous wheel travel per step when the protocol gives no discrete
/// count (touchpads, and pre-v5 Wayland seats). Ten is the wl_pointer
/// convention for one wheel detent.
pub const wheel_units_per_step: f64 = 10;

pub const Gestures = struct {
    const queue_len = 64;

    queue: [queue_len]PointerEvent = undefined,
    q_head: usize = 0,
    q_tail: usize = 0,
    dropped: usize = 0,

    x: f64 = 0,
    y: f64 = 0,
    held: u16 = 0,
    last_press: ?Press = null,
    /// Wheel travel reported this frame, not yet a step. Continuous travel
    /// keeps its remainder across frames so slow touchpad scrolling still
    /// adds up; a discrete count replaces it for the frame it arrives in.
    wheel_travel: [2]f64 = .{ 0, 0 },
    wheel_steps: [2]?i32 = .{ null, null },

    const Press = struct { button: u8, time_ms: u32, x: f64, y: f64, clicks: u8 };

    pub fn motion(self: *Gestures, x: f64, y: f64, mods: Mods) void {
        self.x = x;
        self.y = y;
        const ev: PointerEvent = .{ .kind = .motion, .x = x, .y = y, .mods = mods, .held = self.held };
        // Consecutive motions coalesce: only where the pointer ended up
        // matters, and a fast drag must not evict a press from the queue.
        if (self.q_tail != self.q_head) {
            const last = &self.queue[(self.q_tail - 1) % queue_len];
            if (last.kind == .motion and last.held == ev.held) {
                last.* = ev;
                return;
            }
        }
        self.push(ev);
    }

    /// Where the pointer is without a motion event (surface enter).
    pub fn warp(self: *Gestures, x: f64, y: f64) void {
        self.x = x;
        self.y = y;
    }

    pub fn button(self: *Gestures, b: u8, pressed: bool, time_ms: u32, mods: Mods) void {
        if (b == 0 or b > 16) return;
        const bit = @as(u16, 1) << @intCast(b - 1);
        if (!pressed) {
            if (self.held & bit == 0) return; // a release we never saw go down
            self.held &= ~bit;
            self.push(.{ .kind = .release, .button = b, .x = self.x, .y = self.y, .mods = mods });
            return;
        }
        self.held |= bit;
        const clicks: u8 = if (self.last_press) |p| blk: {
            const same = p.button == b and
                time_ms -% p.time_ms <= multi_click_ms and
                @abs(self.x - p.x) <= multi_click_px and
                @abs(self.y - p.y) <= multi_click_px;
            break :blk if (same) p.clicks % 3 + 1 else 1;
        } else 1;
        const slow = if (self.last_press) |p|
            p.button == b and clicks == 1 and
                time_ms -% p.time_ms > multi_click_ms and time_ms -% p.time_ms <= slow_click_ms
        else
            false;
        self.last_press = .{ .button = b, .time_ms = time_ms, .x = self.x, .y = self.y, .clicks = clicks };
        self.push(.{ .kind = .press, .button = b, .clicks = clicks, .slow = slow, .x = self.x, .y = self.y, .mods = mods });
    }

    /// Continuous wheel travel in wl_pointer axis units.
    pub fn axis(self: *Gestures, which: Axis, value: f64) void {
        self.wheel_travel[@intFromEnum(which)] += value;
    }

    /// A discrete step count for this frame (a wheel detent).
    pub fn axisDiscrete(self: *Gestures, which: Axis, steps: i32) void {
        const i = @intFromEnum(which);
        self.wheel_steps[i] = (self.wheel_steps[i] orelse 0) + steps;
    }

    /// The scroll source stopped (a finger lifted): drop the partial step.
    pub fn axisStop(self: *Gestures, which: Axis) void {
        self.wheel_travel[@intFromEnum(which)] = 0;
    }

    /// End of one logical pointer frame: turn this frame's wheel travel into
    /// at most one wheel event.
    pub fn frame(self: *Gestures, mods: Mods) void {
        var steps: [2]i32 = .{ 0, 0 };
        for (0..2) |i| {
            if (self.wheel_steps[i]) |n| {
                steps[i] = n;
                self.wheel_travel[i] = 0;
            } else {
                const whole = @trunc(self.wheel_travel[i] / wheel_units_per_step);
                steps[i] = @intFromFloat(whole);
                self.wheel_travel[i] -= whole * wheel_units_per_step;
            }
            self.wheel_steps[i] = null;
        }
        if (steps[0] == 0 and steps[1] == 0) return;
        self.push(.{ .kind = .wheel, .x = self.x, .y = self.y, .mods = mods, .dy = steps[0], .dx = steps[1] });
    }

    /// The pointer left the surface. Held buttons will never report their
    /// release here, so release them now rather than leave a drag running.
    pub fn leave(self: *Gestures, mods: Mods) void {
        var b: u8 = 1;
        while (self.held != 0) : (b += 1) {
            const bit = @as(u16, 1) << @intCast(b - 1);
            if (self.held & bit != 0) self.button(b, false, 0, mods);
        }
        self.last_press = null;
        self.wheel_travel = .{ 0, 0 };
        self.wheel_steps = .{ null, null };
    }

    pub fn next(self: *Gestures) ?PointerEvent {
        if (self.q_head == self.q_tail) return null;
        const ev = self.queue[self.q_head % queue_len];
        self.q_head += 1;
        return ev;
    }

    fn push(self: *Gestures, ev: PointerEvent) void {
        if (self.q_tail - self.q_head >= queue_len) {
            self.q_head += 1; // drop oldest
            self.dropped += 1;
        }
        self.queue[self.q_tail % queue_len] = ev;
        self.q_tail += 1;
    }
};

// ── Tests ───────────────────────────────────────────────────────────

const t = std.testing;

fn drain(g: *Gestures, out: []PointerEvent) []PointerEvent {
    var n: usize = 0;
    while (g.next()) |ev| : (n += 1) out[n] = ev;
    return out[0..n];
}

test "pointer: quick presses in place count up to triple, then start over" {
    var g: Gestures = .{};
    g.warp(10, 10);
    const times = [_]u32{ 1000, 1100, 1200, 1300 };
    for (times) |ms| {
        g.button(1, true, ms, .{});
        g.button(1, false, ms + 20, .{});
    }
    var buf: [16]PointerEvent = undefined;
    const evs = drain(&g, &buf);
    try t.expectEqual(@as(usize, 8), evs.len);
    try t.expectEqual(@as(u8, 1), evs[0].clicks);
    try t.expectEqual(@as(u8, 2), evs[2].clicks);
    try t.expectEqual(@as(u8, 3), evs[4].clicks);
    try t.expectEqual(@as(u8, 1), evs[6].clicks);
    try t.expectEqual(PointerEvent.Kind.release, evs[1].kind);
}

test "pointer: a slow, distant, or different-button press is a new single click" {
    var g: Gestures = .{};
    g.warp(10, 10);
    g.button(1, true, 1000, .{});
    g.button(1, false, 1010, .{});
    g.button(1, true, 1000 + multi_click_ms + 1, .{}); // too slow
    g.button(1, false, 1500, .{});
    g.warp(10 + multi_click_px + 1, 10);
    g.button(1, true, 1510, .{}); // too far
    g.button(1, false, 1520, .{});
    g.button(3, true, 1530, .{}); // another button
    var buf: [16]PointerEvent = undefined;
    const evs = drain(&g, &buf);
    for (evs) |ev| if (ev.kind == .press) try t.expectEqual(@as(u8, 1), ev.clicks);
    try t.expectEqual(@as(u8, 3), evs[evs.len - 1].button);
}

test "pointer: a second click after the double-click window, within the slow window, is slow" {
    var g: Gestures = .{};
    g.warp(10, 10);
    g.button(1, true, 1000, .{});
    g.button(1, false, 1010, .{});
    g.button(1, true, 1000 + multi_click_ms + 100, .{}); // slow: not a double, not a new gesture
    g.button(1, false, 1000 + multi_click_ms + 110, .{});
    g.button(1, true, 1000 + multi_click_ms + 150, .{}); // a double click: never slow
    g.button(1, false, 1000 + multi_click_ms + 160, .{});
    g.button(1, true, 10_000, .{}); // long after: a fresh click
    var buf: [16]PointerEvent = undefined;
    const evs = drain(&g, &buf);
    try t.expect(!evs[0].slow);
    try t.expect(evs[2].slow);
    try t.expectEqual(@as(u8, 1), evs[2].clicks);
    try t.expect(!evs[4].slow);
    try t.expectEqual(@as(u8, 2), evs[4].clicks);
    try t.expect(!evs[6].slow);
}

test "pointer: the click window survives the 32-bit millisecond wrap" {
    var g: Gestures = .{};
    g.button(1, true, std.math.maxInt(u32) - 50, .{});
    g.button(1, false, std.math.maxInt(u32) - 40, .{});
    g.button(1, true, 100, .{});
    var buf: [4]PointerEvent = undefined;
    const evs = drain(&g, &buf);
    try t.expectEqual(@as(u8, 2), evs[2].clicks);
}

test "pointer: modifiers ride on the event they were held for" {
    var g: Gestures = .{};
    g.button(1, true, 0, .{ .shift = true });
    g.button(1, false, 5, .{});
    g.button(1, true, 1000, .{ .ctrl = true, .alt = true });
    var buf: [4]PointerEvent = undefined;
    const evs = drain(&g, &buf);
    try t.expect(evs[0].mods.shift and !evs[0].mods.ctrl);
    try t.expect(!evs[1].mods.shift);
    try t.expect(evs[2].mods.ctrl and evs[2].mods.alt and !evs[2].mods.shift);
}

test "pointer: motion coalesces, and carries the held buttons that make it a drag" {
    var g: Gestures = .{};
    g.motion(1, 1, .{});
    g.motion(2, 2, .{});
    g.button(1, true, 0, .{});
    g.motion(3, 3, .{});
    g.motion(4, 4, .{});
    g.button(1, false, 10, .{});
    var buf: [8]PointerEvent = undefined;
    const evs = drain(&g, &buf);
    try t.expectEqual(@as(usize, 4), evs.len);
    try t.expectEqual(@as(f64, 2), evs[0].x);
    try t.expectEqual(@as(u16, 0), evs[0].held);
    try t.expectEqual(@as(f64, 4), evs[2].x);
    try t.expectEqual(@as(u16, 1), evs[2].held);
    try t.expectEqual(@as(f64, 4), evs[3].x); // the release lands where the drag ended
}

test "pointer: wheel steps prefer the discrete count, and keep the continuous remainder" {
    var g: Gestures = .{};
    g.axis(.vertical, 15);
    g.axisDiscrete(.vertical, 1);
    g.frame(.{});
    g.axis(.vertical, 6); // a touchpad nudge: not a step yet
    g.frame(.{});
    g.axis(.vertical, 6); // …but it adds up
    g.axis(.horizontal, -25);
    g.frame(.{ .ctrl = true });
    g.axis(.vertical, 9);
    g.axisStop(.vertical); // finger lifted: the partial step is gone
    g.frame(.{});
    var buf: [8]PointerEvent = undefined;
    const evs = drain(&g, &buf);
    try t.expectEqual(@as(usize, 2), evs.len);
    try t.expectEqual(@as(i32, 1), evs[0].dy);
    try t.expectEqual(@as(i32, 1), evs[1].dy);
    try t.expectEqual(@as(i32, -2), evs[1].dx);
    try t.expect(evs[1].mods.ctrl);
}

test "pointer: leaving the surface releases held buttons" {
    var g: Gestures = .{};
    g.button(1, true, 0, .{});
    g.button(3, true, 1, .{});
    g.leave(.{});
    g.button(1, false, 2, .{}); // stale: already released
    var buf: [8]PointerEvent = undefined;
    const evs = drain(&g, &buf);
    try t.expectEqual(@as(usize, 4), evs.len);
    try t.expectEqual(PointerEvent.Kind.release, evs[2].kind);
    try t.expectEqual(PointerEvent.Kind.release, evs[3].kind);
    try t.expectEqual(@as(u16, 0), g.held);
}
