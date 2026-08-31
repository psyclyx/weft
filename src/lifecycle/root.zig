//! `weft_lifecycle` — platform- and renderer-independent application-wake
//! policy.
//!
//! The module owns only sequencing and the tiny state whose meaning is defined
//! by that sequence (input damage and caret blink). A concrete host supplies
//! typed phase methods; this root cannot import app, core, gfx, a window system,
//! or a renderer because `build.zig` gives it no such dependencies.

const std = @import("std");

pub const AdvanceOptions = struct {
    frame_start: u64,
    fb: [2]u32,
    force_rebuild: bool = false,
};

pub const AdvanceResult = struct {
    had_input: bool,
    damaged: bool,
    blink_on: bool,
};

pub const Lifecycle = struct {
    input_pending: bool = false,
    blink_on: bool = true,
    blink_next_ns: u64 = 0,
    blink_period_ns: u64 = 530 * std.time.ns_per_ms,

    pub fn noteInput(self: *Lifecycle) void {
        self.input_pending = true;
    }

    /// Advance one complete application wake. `host` is structural: it must
    /// provide `prepare`, `beforeAsync`, `blinkEnabled`, `tickAsync`,
    /// `applyWindowIntents`, `observe`, `damage`, and `buildPrepared`.
    /// Renderers and prepared-frame types remain concrete and statically typed;
    /// the policy module needs neither an opaque object graph nor app imports.
    pub fn advance(self: *Lifecycle, host: anytype, renderer: anytype, opts: AdvanceOptions) !AdvanceResult {
        var active = try host.prepare();
        if (try host.beforeAsync(active)) self.noteInput();

        const had_input = self.input_pending;
        self.input_pending = false;
        var damaged = false;

        if (had_input) {
            self.blink_on = true;
            self.blink_next_ns = opts.frame_start + self.blink_period_ns;
        } else if (host.blinkEnabled() and opts.frame_start >= self.blink_next_ns) {
            self.blink_on = !self.blink_on;
            self.blink_next_ns = opts.frame_start + self.blink_period_ns;
            damaged = true;
        }

        if (try host.tickAsync(active, opts.frame_start)) damaged = true;
        if (host.applyWindowIntents()) damaged = true;
        active = try host.prepare();
        if (host.observe(active)) damaged = true;
        if (had_input or opts.force_rebuild) damaged = true;
        if (damaged) host.damage();

        try host.buildPrepared(renderer, active, .{
            .frame_start = opts.frame_start,
            .fb = opts.fb,
            .blink_on = self.blink_on,
            .force_rebuild = opts.force_rebuild,
        });
        return .{
            .had_input = had_input,
            .damaged = damaged,
            .blink_on = self.blink_on,
        };
    }
};

test "application lifecycle sequences one complete wake" {
    const Host = struct {
        calls: std.ArrayList(u8) = .empty,
        damaged: bool = false,

        const Prepared = struct { generation: u8 };
        const BuildOptions = struct {
            frame_start: u64,
            fb: [2]u32,
            blink_on: bool,
            force_rebuild: bool,
        };

        fn prepare(self: *@This()) !Prepared {
            try self.calls.append(std.testing.allocator, 'p');
            return .{ .generation = @intCast(self.calls.items.len) };
        }
        fn beforeAsync(self: *@This(), _: Prepared) !bool {
            try self.calls.append(std.testing.allocator, 'i');
            return true;
        }
        fn blinkEnabled(_: *@This()) bool {
            return true;
        }
        fn tickAsync(self: *@This(), _: Prepared, _: u64) !bool {
            try self.calls.append(std.testing.allocator, 'a');
            return true;
        }
        fn applyWindowIntents(self: *@This()) bool {
            self.calls.append(std.testing.allocator, 'w') catch unreachable;
            return true;
        }
        fn observe(self: *@This(), _: Prepared) bool {
            self.calls.append(std.testing.allocator, 'o') catch unreachable;
            return true;
        }
        fn damage(self: *@This()) void {
            self.damaged = true;
        }
        fn buildPrepared(self: *@This(), _: void, _: Prepared, _: BuildOptions) !void {
            try self.calls.append(std.testing.allocator, 'b');
        }
    };

    var host: Host = .{};
    defer host.calls.deinit(std.testing.allocator);
    var lifecycle: Lifecycle = .{};
    const result = try lifecycle.advance(&host, {}, .{ .frame_start = 10, .fb = .{ 80, 24 } });
    try std.testing.expectEqualStrings("piawpob", host.calls.items);
    try std.testing.expect(result.had_input);
    try std.testing.expect(result.damaged);
    try std.testing.expect(host.damaged);
}
