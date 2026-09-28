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

/// Replace the transient chrome binding with `style` (a transient rebind from
/// one owner replaces its last, `Container.rebind`).
fn bindStyle(container: *core.container.Container, style: Style) !void {
    container.rebind(.{
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

/// The style the frame draws in, published as the global context key
/// `theme.chrome` — what the View ▸ Appearance ▸ Chrome Style choices check
/// themselves by (`toggle = "theme.chrome=widget"`). Called where the frame
/// resolves the style (`frame_builder.capture`), so the key says what is on
/// screen whichever tier bound it; an unchanged value moves nothing.
pub fn publishStyle(ctx: *core.command.Context, style: Style) void {
    const context = ctx.context orelse return;
    _ = context.store.setCore(.global, "theme.chrome", style.name()) catch {};
}

/// One choice per style: a command a menu row, a key or the palette runs,
/// checked while it is the style drawn.
const choices = [_]struct { style: Style, name: []const u8, label: []const u8, toggle: []const u8, summary: []const u8 }{
    .{ .style = .text, .name = "theme.chrome-text", .label = "Text", .toggle = "theme.chrome=text", .summary = "Draw the chrome as clean, cell-aligned text." },
    .{ .style = .text_icons, .name = "theme.chrome-text-icons", .label = "Text with Icons", .toggle = "theme.chrome=text-icons", .summary = "Draw the chrome as cell-aligned text with small icons." },
    .{ .style = .widget, .name = "theme.chrome-widget", .label = "Widgets", .toggle = "theme.chrome=widget", .summary = "Draw the chrome as widgets: rounded buttons, real tabs, shadowed menus." },
};

fn chooseHandler(ctx: *core.command.Context, data: ?*anyopaque, args: []const core.command.Value) anyerror!core.command.Value {
    _ = args;
    const style: *const Style = @ptrCast(@alignCast(data.?));
    try bindStyle(ctx.actions.container, style.*);
    return .nil;
}

const choice_styles = [_]Style{ .text, .text_icons, .widget };

pub fn register(gpa: std.mem.Allocator, commands: *core.command.Commands) !void {
    for (choices, 0..) |c, i| {
        std.debug.assert(choice_styles[i] == c.style);
        _ = try commands.bind(gpa, c.name, .{
            .name = c.name,
            .summary = c.summary,
            .args = &.{},
            .handler = chooseHandler,
            .data = @ptrCast(@constCast(&choice_styles[i])),
            .meta = .{ .label = c.label, .toggle = c.toggle },
        });
    }
    _ = try commands.bind(gpa, "theme.set-chrome", .{
        .name = "theme.set-chrome",
        .summary = "Switch how the editor's chrome looks, live: text, text with icons, or widgets.",
        .args = &.{.{ .name = "style", .type = .string }},
        .handler = setChromeHandler,
        .meta = .{ .label = "Set Chrome Style", .icon = "palette", .prompts = true },
    });
    _ = try commands.bind(gpa, "theme.cycle-chrome", .{
        .name = "theme.cycle-chrome",
        .summary = "Switch the editor's chrome to the next style: text, text with icons, then widgets.",
        .args = &.{},
        .handler = cycleChromeHandler,
        .meta = .{ .label = "Next Chrome Style", .icon = "palette" },
    });
}
