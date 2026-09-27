//! Live chrome-style switching (doc/chrome.md §3.2): `theme.set-chrome
//! <text|text-icons|widget>` and `theme.cycle-chrome`, the palette's toggle.
//!
//! Like `theme.set-color`, a command here is a BINDING at the transient tier, not
//! a poke at the view: it binds `theme/chrome` over whatever the config
//! said, and the view reads the slot at the top of the next frame
//! (`View.resolveChrome`). So a config's `weft.set("theme", "chrome", ...)`
//! and the interactive switch are one mechanism at two tiers, and trying a
//! style costs no restart and no config edit.

const std = @import("std");
const core = @import("weft_core");
const view_mod = @import("weft_gfx").view;

const View = view_mod.View;
const Style = view_mod.chrome.Style;

/// The owner of the one transient binding these commands keep.
const owner = "theme.set-chrome";

/// Replace the transient chrome binding with `style`. The old one goes first:
/// two bindings from one owner at one tier would tie, and the tie would not
/// go to the newer.
fn bindStyle(container: *core.container.Container, style: Style) !void {
    container.unbindOwnerExact(.other, owner);
    container.bind(.{
        .slot = View.chrome_slot,
        .provider = .{ .value = style.name() },
        .predicate = .{ .all = &.{} },
        .tier = .transient,
        .owner = owner,
    }) catch return error.InvalidArgument;
}

/// The style the slot resolves to now; `text` when nothing has bound it.
fn current(ctx: *core.command.Context) Style {
    const winner = ctx.actions.container.resolveOne(View.chrome_slot, ctx.capturedCtx().mergedFacts()) orelse return .text;
    return switch (winner.provider) {
        .value => |v| Style.parse(v) orelse .text,
        else => .text,
    };
}

pub fn setChromeHandler(ctx: *core.command.Context, data: ?*anyopaque, args: []const core.command.Value) anyerror!core.command.Value {
    _ = data;
    const style = Style.parse(args[0].string) orelse return error.InvalidArgument;
    try bindStyle(ctx.actions.container, style);
    return .nil;
}

pub fn cycleChromeHandler(ctx: *core.command.Context, data: ?*anyopaque, args: []const core.command.Value) anyerror!core.command.Value {
    _ = data;
    _ = args;
    try bindStyle(ctx.actions.container, current(ctx).next());
    return .nil;
}

pub fn register(gpa: std.mem.Allocator, commands: *core.command.Commands) !void {
    _ = try commands.bind(gpa, "theme.set-chrome", .{
        .name = "theme.set-chrome",
        .summary = "Switch how the editor's chrome looks, live: text, text with icons, or widgets.",
        .args = &.{.{ .name = "style", .type = .string }},
        .handler = setChromeHandler,
        .meta = .{ .label = "Set Chrome Style", .menu = "View/Appearance", .group = "chrome", .order = 20, .icon = "palette", .prompts = true },
    });
    _ = try commands.bind(gpa, "theme.cycle-chrome", .{
        .name = "theme.cycle-chrome",
        .summary = "Switch the editor's chrome to the next style: text, text with icons, then widgets.",
        .args = &.{},
        .handler = cycleChromeHandler,
        .meta = .{ .label = "Next Chrome Style", .menu = "View/Appearance", .group = "chrome", .order = 10, .icon = "palette" },
    });
}
