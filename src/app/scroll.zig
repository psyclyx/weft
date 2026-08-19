//! Scrolling commands. They operate on the focused pane's viewport, which
//! lives in the view (core commands can't see it), so they're registered
//! by the host rather than the core. `view.top_row` is always the focused
//! pane's scroll.

const std = @import("std");
const core = @import("../core/core.zig");
const view_mod = @import("../gfx/view.zig");

/// Scrolling commands operate on the focused pane's viewport, which lives
/// in the view (core commands can't see it).
pub const ScrollCtx = struct { view: *view_mod.View, fb: *[2]u32 };

fn scrollOf(data: ?*anyopaque) *ScrollCtx {
    return @ptrCast(@alignCast(data.?));
}

fn viewportRows(sc: *ScrollCtx) usize {
    _ = sc.fb;
    return sc.view.bodyRows(); // the focused pane's body height, split-aware
}

/// Move the focused pane's viewport by `delta` rows, optionally carrying
/// the cursor with it (vim C-d/C-u/C-f/C-b move the cursor; C-e/C-y do not).
fn doScroll(ctx: *core.command.Context, sc: *ScrollCtx, delta: i64, move_cursor: bool) void {
    const ed = ctx.editor();
    const rope = ed.text();
    const last = rope.lineCount() -| 1;
    if (delta >= 0)
        sc.view.top_row = @min(sc.view.top_row + @as(usize, @intCast(delta)), last)
    else
        sc.view.top_row -|= @intCast(-delta);
    if (move_cursor) {
        const cur_row = rope.offsetToPoint(ed.cursorOffset()).row;
        const nr = if (delta >= 0)
            @min(cur_row + @as(usize, @intCast(delta)), last)
        else
            cur_row -| @as(usize, @intCast(-delta));
        ed.clearSelection();
        ed.placeCursor(rope.lineRange(nr).start);
    }
}

pub fn scrollLineDown(ctx: *core.command.Context, data: ?*anyopaque, _: []const core.command.Value) anyerror!core.command.Value {
    doScroll(ctx, scrollOf(data), 1, false);
    return .nil;
}
pub fn scrollLineUp(ctx: *core.command.Context, data: ?*anyopaque, _: []const core.command.Value) anyerror!core.command.Value {
    doScroll(ctx, scrollOf(data), -1, false);
    return .nil;
}
pub fn scrollHalfDown(ctx: *core.command.Context, data: ?*anyopaque, _: []const core.command.Value) anyerror!core.command.Value {
    const sc = scrollOf(data);
    doScroll(ctx, sc, @intCast(viewportRows(sc) / 2), true);
    return .nil;
}
pub fn scrollHalfUp(ctx: *core.command.Context, data: ?*anyopaque, _: []const core.command.Value) anyerror!core.command.Value {
    const sc = scrollOf(data);
    doScroll(ctx, sc, -@as(i64, @intCast(viewportRows(sc) / 2)), true);
    return .nil;
}
pub fn scrollPageDown(ctx: *core.command.Context, data: ?*anyopaque, _: []const core.command.Value) anyerror!core.command.Value {
    const sc = scrollOf(data);
    doScroll(ctx, sc, @intCast(viewportRows(sc) -| 2), true);
    return .nil;
}
pub fn scrollPageUp(ctx: *core.command.Context, data: ?*anyopaque, _: []const core.command.Value) anyerror!core.command.Value {
    const sc = scrollOf(data);
    doScroll(ctx, sc, -@as(i64, @intCast(viewportRows(sc) -| 2)), true);
    return .nil;
}
pub fn centerLine(ctx: *core.command.Context, data: ?*anyopaque, _: []const core.command.Value) anyerror!core.command.Value {
    const sc = scrollOf(data);
    const ed = ctx.editor();
    const cur_row = ed.text().offsetToPoint(ed.cursorOffset()).row;
    sc.view.top_row = cur_row -| (viewportRows(sc) / 2);
    return .nil;
}
