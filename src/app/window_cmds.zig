//! Window-layout commands. Core commands only RECORD intent on a
//! `WindowCtx`; the frame loop applies them (split/close/focus/move by
//! pane geometry) and keeps the focused pane == the active buffer.

const std = @import("std");
const core = @import("../core/core.zig");
const view_mod = @import("../gfx/view.zig");
const region = @import("../gfx/region.zig");
const window_layout = @import("../gfx/window_layout.zig");
const ok_echo = @import("handler.zig").ok_echo;

/// Window-layout intents; applied in the frame loop (which owns the pane
/// tree + scroll/build state). Commands only record intent — the loop
/// mutates the layout and keeps the focused pane == the active buffer.
pub const WindowCtx = struct {
    split: ?region.Axis = null, // request a split of the focused pane
    close: bool = false,
    focus_dir: ?window_layout.Dir = null,
    move_dir: ?window_layout.Dir = null,
    focus_next: bool = false, // cycle focus (legacy `focus-other`)
    click_focus: bool = false, // focus the pane at (click_x, click_y)
    click_x: f32 = 0,
    click_y: f32 = 0,
};

/// Which window operation a bound command requests (mapped to a WindowCtx
/// field in windowActionHandler). vim `:split` is a horizontal divider
/// (stacked rows); `:vsplit` a vertical one (side-by-side columns).
pub const WindowAction = enum {
    split,
    vsplit,
    close,
    focus_next,
    focus_left,
    focus_right,
    focus_up,
    focus_down,
    move_left,
    move_right,
    move_up,
    move_down,
};

/// A command → intent binding: which WindowCtx to poke and how. Held in a
/// stable array so `command.bind`'s data pointer stays valid for the run.
pub const WindowActionCtx = struct { win: *WindowCtx, action: WindowAction };

pub fn windowActionHandler(ctx: *core.command.Context, data: ?*anyopaque, args: []const core.command.Value) anyerror!core.command.Value {
    _ = args;
    const a: *WindowActionCtx = @ptrCast(@alignCast(data.?));
    switch (a.action) {
        .split => a.win.split = .horizontal, // stacked rows (vim :split)
        .vsplit => a.win.split = .vertical, // side-by-side columns (vim :vsplit)
        .close => a.win.close = true,
        .focus_next => a.win.focus_next = true,
        .focus_left => a.win.focus_dir = .left,
        .focus_right => a.win.focus_dir = .right,
        .focus_up => a.win.focus_dir = .up,
        .focus_down => a.win.focus_dir = .down,
        .move_left => a.win.move_dir = .left,
        .move_right => a.win.move_dir = .right,
        .move_up => a.win.move_dir = .up,
        .move_down => a.win.move_dir = .down,
    }
    return ok_echo(ctx, "window");
}

/// After a window op moved focus (or changed the focused pane's content),
/// make the active buffer follow the focused pane and restore that pane's
/// scroll — the invariant "focused pane == active buffer".
pub fn applyWindowFocus(win_layout: *window_layout.Layout, view: *view_mod.View, buffers: *core.Buffers, gpa: std.mem.Allocator, keymap: *core.Keymap) void {
    const fp = win_layout.focusedPane();
    if (buffers.get(fp.buffer_id) != null and buffers.active_id != fp.buffer_id)
        buffers.switchTo(gpa, fp.buffer_id, keymap) catch {};
    view.top_row = fp.top_row;
}
