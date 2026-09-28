//! Window text scale. The configured size is the reset point; commands change
//! the live view without changing the saved setting.
const std = @import("std");
const core = @import("weft_core");
const View = @import("weft_gfx").view.View;

pub const min_size: f32 = 8;
pub const max_size: f32 = 72;

pub fn parse(raw: []const u8) ?f32 {
    const size = std.fmt.parseFloat(f32, raw) catch return null;
    if (!std.math.isFinite(size) or size < min_size or size > max_size) return null;
    return size;
}

pub const Control = struct {
    view: *View,
    default_size: f32,

    pub fn register(self: *Control, gpa: std.mem.Allocator, commands: *core.command.Commands) !void {
        const entries = [_]core.command.Command{
            .{ .name = "font.set-size", .summary = "Set the text size in pixels, from 8 to 72.", .args = &.{.{ .name = "size", .type = .string }}, .handler = set, .data = self, .meta = .{ .label = "Set Text Size", .icon = "type", .prompts = true } },
            .{ .name = "font.increase", .summary = "Make the text one pixel larger.", .args = &.{}, .handler = increase, .data = self, .meta = .{ .label = "Zoom In", .icon = "zoom-in" } },
            .{ .name = "font.decrease", .summary = "Make the text one pixel smaller.", .args = &.{}, .handler = decrease, .data = self, .meta = .{ .label = "Zoom Out", .icon = "zoom-out" } },
            .{ .name = "font.reset", .summary = "Restore the configured text size.", .args = &.{}, .handler = reset, .data = self, .meta = .{ .label = "Reset Zoom" } },
        };
        for (entries) |entry| _ = try commands.bind(gpa, entry.name, entry);
    }

    fn control(data: ?*anyopaque) *Control {
        return @ptrCast(@alignCast(data.?));
    }

    fn set(_: *core.command.Context, data: ?*anyopaque, args: []const core.command.Value) anyerror!core.command.Value {
        const size = parse(args[0].string) orelse return error.InvalidArgument;
        control(data).view.setEm(size);
        return .nil;
    }

    fn increase(_: *core.command.Context, data: ?*anyopaque, _: []const core.command.Value) anyerror!core.command.Value {
        const v = control(data).view;
        v.setEm(@min(max_size, v.em + 1));
        return .nil;
    }

    fn decrease(_: *core.command.Context, data: ?*anyopaque, _: []const core.command.Value) anyerror!core.command.Value {
        const v = control(data).view;
        v.setEm(@max(min_size, v.em - 1));
        return .nil;
    }

    fn reset(_: *core.command.Context, data: ?*anyopaque, _: []const core.command.Value) anyerror!core.command.Value {
        const self = control(data);
        self.view.setEm(self.default_size);
        return .nil;
    }
};
