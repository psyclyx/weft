//! Key dispatch: one key event → keymap lookup → command. Runs inside the
//! hot section: dispatch is a table lookup plus the command itself,
//! allocation-only. Unbound printable input becomes the mode's text command
//! (itself a command); there is no editing path around the ABI. Vertical
//! motion and paging are view-computed (goal-x over rendered geometry), the
//! interactive override the core's scalar-column fallback can't do. Also the
//! menu command handlers (`menu-escape`, `which-key-now`).

const std = @import("std");
const core = @import("../core/core.zig");
const view_mod = @import("../gfx/view.zig");
const region = @import("../gfx/region.zig");
const window_layout = @import("../gfx/window_layout.zig");
const window_cmds = @import("window_cmds.zig");
const wayland = @import("../platform/wayland.zig");

/// Pointer → caret: a plain left click places the caret (and arms a drag
/// anchor); motion with the button held extends a selection from that anchor.
/// A click outside the focused pane's rect records a pane-focus intent on
/// `win_ctx` (applied later against the layout) instead. World space is
/// framebuffer pixels; the surface-space pointer scales by buffer_scale
/// (HiDPI-correct). Sets `had_input` and returns whether the view was damaged.
pub fn handlePointer(
    window: *wayland.Window,
    win_layout: *window_layout.Layout,
    view: *view_mod.View,
    editor: *core.Editor,
    win_ctx: *window_cmds.WindowCtx,
    gpa: std.mem.Allocator,
    last_frame_rect: region.Rect,
    drag_anchor: *?usize,
    drag_selecting: *bool,
    had_input: *bool,
) !bool {
    var dirty = false;
    const scale: f32 = @floatFromInt(@max(window.buffer_scale, 1));
    const px = @as(f32, @floatCast(window.mouse_x)) * scale;
    const py = @as(f32, @floatCast(window.mouse_y)) * scale;
    // Pane routing: a click outside the focused pane's rect focuses the
    // pane under the cursor (the intent is applied below, against the
    // layout); inside, the click maps directly (panes render into their
    // own rects, so the geometry map is already in absolute coords). The
    // frame rect is last render's — one-frame latency, unseen.
    const click_in_peek = win_layout.count() > 1 and !win_layout.focusedRect(last_frame_rect).contains(px, py);
    if (window.consumeMousePressed(0)) {
        if (click_in_peek) {
            win_ctx.click_focus = true;
            win_ctx.click_x = px;
            win_ctx.click_y = py;
            had_input.* = true;
            dirty = true;
        } else {
            const off = view.offsetAtPoint(px, py);
            editor.clearSelection();
            editor.placeCursor(off);
            drag_anchor.* = off;
            drag_selecting.* = false;
            had_input.* = true;
            dirty = true;
        }
    } else if (window.mouse_down[0] and !click_in_peek) {
        if (drag_anchor.*) |anchor| {
            const off = view.offsetAtPoint(px, py);
            if (off != editor.cursorOffset()) {
                if (!drag_selecting.*) {
                    // First motion: anchor the mark, then drag the caret.
                    editor.placeCursor(anchor);
                    try editor.setMark(gpa);
                    drag_selecting.* = true;
                }
                editor.placeCursor(off);
                had_input.* = true;
                dirty = true;
            }
        }
    } else {
        drag_anchor.* = null;
        drag_selecting.* = false;
    }
    return dirty;
}

/// `menu-escape` (Escape / C-g, bound in the GLOBAL layer so it works anywhere)
/// — leave the current MENU back to its recorded return target. Outside a menu
/// it is a NO-OP: Escape must never force a mode change, or it drops you into
/// the editing base (`normal`) inside a read-only projection like magit/dired —
/// the recurring "wrong mode in a tool buffer" jank. A projection's own mode is
/// its resting mode; Escape leaves it alone. (An editing mode's own Escape —
/// vim insert/visual → normal — is bound mode-locally and wins over this.)
pub fn menuEscapeHandler(ctx: *core.command.Context, data: ?*anyopaque, args: []const core.command.Value) anyerror!core.command.Value {
    _ = data;
    _ = args;
    const km = ctx.keymap;
    if (!km.isMenuMode(km.currentMode())) return .nil; // not in a menu → leave the mode be
    // In a menu: return to its recorded target, else the configured base mode
    // (vim's "normal", helix's "helix-normal", or plain "default").
    const base = if (ctx.buffers.default_mode.len > 0) ctx.buffers.default_mode else "default";
    const ret = km.menuReturn(km.currentMode()) orelse base;
    km.setMode(ctx.gpa, ret) catch {};
    return .nil;
}

/// `which-key-now` (F1) — toggle a which-key peek at the CURRENT mode's keys.
/// It does NOT force-enter a hardcoded "leader": in normal you see the top-level
/// bindings (the leader prefix among them), in a submenu you see that submenu,
/// in magit the magit keys. The shell no longer assumes the root menu is named
/// "leader"; it just reveals wherever you are.
pub fn whichKeyNowHandler(ctx: *core.command.Context, data: ?*anyopaque, args: []const core.command.Value) anyerror!core.command.Value {
    _ = args;
    _ = ctx;
    const flag: *bool = @ptrCast(@alignCast(data.?));
    flag.* = true;
    return .nil;
}

/// One view-computed vertical step. The goal-x (world px) is taken from
/// the editor (sticky across a run of up/down) or seeded from the current
/// caret's rendered x; the target offset is the nearest caret to it on
/// the adjacent row. This is the interactive replacement for the core's
/// scalar-column `moveVertical` — monospace stays exact (uniform
/// advances), proportional text tracks the visual column.
fn visualVertical(ed: *core.Editor, view: *view_mod.View, dir: i32) !void {
    const rope = ed.text();
    const cur = ed.cursorOffset();
    const gx = ed.goalX() orelse try view.xOfOffsetOnRow(rope, cur);
    ed.setGoalX(gx); // persists even at the doc edges, for the next step
    const pt = rope.offsetToPoint(cur);
    const rows = rope.lineCount();
    // Skip folded rows (shared fold-aware successor — the magit status buffer's
    // j/k bind to cursor-up/down, which land here).
    const target_row = ed.nextVisibleRow(pt.row, if (dir < 0) -1 else 1, rows) orelse return;
    const target = try view.xToOffsetOnRow(rope, target_row, gx);
    ed.moveToVisual(target, gx);
}

// ── View-aware motion commands (shell) ──────────────────────────────
// The interactive, geometry-aware override of the core's scalar-column
// cursor-up/down and paging — registered by the shell (data = the live `View`),
// so they SHADOW the core `cursor-*` by late binding and dispatch UNIFORMLY
// through the keymap. No `if (cmd_name == "cursor-up")` special-case in the hot
// loop, and paging becomes an ordinary rebindable command (bound in the global
// layer) instead of a hardcoded keysym branch.

fn viewOf(data: ?*anyopaque) *view_mod.View {
    return @ptrCast(@alignCast(data.?));
}

pub fn cursorUpHandler(ctx: *core.command.Context, data: ?*anyopaque, args: []const core.command.Value) anyerror!core.command.Value {
    _ = args;
    try visualVertical(ctx.editor(), viewOf(data), -1);
    return .nil;
}

pub fn cursorDownHandler(ctx: *core.command.Context, data: ?*anyopaque, args: []const core.command.Value) anyerror!core.command.Value {
    _ = args;
    try visualVertical(ctx.editor(), viewOf(data), 1);
    return .nil;
}

fn pageBy(ctx: *core.command.Context, view: *view_mod.View, dir: i32) !void {
    const rows = view.bodyRows();
    for (0..rows) |_| try visualVertical(ctx.editor(), view, dir);
}

pub fn scrollPageUpHandler(ctx: *core.command.Context, data: ?*anyopaque, args: []const core.command.Value) anyerror!core.command.Value {
    _ = args;
    try pageBy(ctx, viewOf(data), -1);
    return .nil;
}

pub fn scrollPageDownHandler(ctx: *core.command.Context, data: ?*anyopaque, args: []const core.command.Value) anyerror!core.command.Value {
    _ = args;
    try pageBy(ctx, viewOf(data), 1);
    return .nil;
}

pub fn dispatchKey(ctx: *core.command.Context, ev: wayland.KeyEvent) !void {
    // This whole dispatch is the synchronous handling of a user keystroke:
    // any edit made here — directly or by a helper plugin (dw/autopair) — is
    // the user's, so it joins the user's undo history (see command.edit).
    // Vertical motion + paging are ordinary commands now (view-aware, shell-
    // registered), so this is pure keymap → command — no view/geometry here.
    ctx.user_initiated = true;
    defer ctx.user_initiated = false;
    const c = wayland.c;

    var name_buf: [64]u8 = undefined;
    const n = c.xkb_keysym_get_name(ev.keysym, &name_buf, name_buf.len);
    if (n > 0) {
        var spec_buf: [80]u8 = undefined;
        const spec = core.Keymap.keyspec(&spec_buf, ev.mods.ctrl, ev.mods.alt, ev.mods.shift, name_buf[0..@intCast(n)]);
        // Mid-chord, Backspace steps BACK one key of the pending sequence (the
        // which-key hint pops a level) rather than aborting the whole chord —
        // the sequence-model replacement for the old menu-nav `menu-escape`.
        if (ctx.keymap.pending.len > 0 and std.mem.eql(u8, spec, "BackSpace")) {
            ctx.keymap.popPending(ctx.gpa) catch {};
            return;
        }
        // Feed the key through the pending SEQUENCE: a chord that could still
        // extend is held (which-key shows its completions off `keymap.pending`);
        // a completed binding runs; a lone unbound key falls to text insertion;
        // a dead-end chord resets. `SPC f f` is a chord; `SPC C-w` never fires
        // global `C-w` — a menu is a sequence, not a mode.
        switch (ctx.keymap.feed(ctx.gpa, spec) catch core.Keymap.Feed.none) {
            .pending, .none => return,
            .text => {}, // a lone unbound key — fall through to text insertion
            .run => |cmd_name| {
                // Legacy mode-menu path (still valid while configs migrate to
                // sequences): a bound key whose command NAMES a menu mode enters
                // it. A real `weft.menu` submenu resolves this way until its keys
                // become `SPC …` chords.
                if (ctx.keymap.isMenuMode(cmd_name)) {
                    ctx.keymap.enterMode(ctx.gpa, cmd_name) catch {};
                    return;
                }
                // Snapshot a menu mode so a one-shot key pops back after the
                // command runs (unless the command itself changed the mode).
                const menu_before: ?[]u8 = if (ctx.keymap.isMenuMode(ctx.keymap.currentMode()))
                    ctx.gpa.dupe(u8, ctx.keymap.currentMode()) catch null
                else
                    null;
                defer if (menu_before) |m| ctx.gpa.free(m);

                const result = core.command.run(ctx.commands, ctx, cmd_name, &.{}) catch |err| blk: {
                    std.log.warn("command {s} failed: {t}", .{ cmd_name, err });
                    break :blk core.command.Value.nil;
                };
                switch (result) {
                    .string => |s| if (s.len > 0) {
                        ctx.echo.clearRetainingCapacity();
                        ctx.echo.appendSlice(ctx.gpa, s) catch {};
                    },
                    else => {},
                }
                if (menu_before) |m| {
                    if (!ctx.keymap.isStickyMenu(m) and std.mem.eql(u8, ctx.keymap.currentMode(), m)) {
                        if (ctx.keymap.menuReturn(m)) |ret| ctx.keymap.setMode(ctx.gpa, ret) catch {};
                    }
                }
                return;
            },
        }
    }
    if (ev.mods.ctrl or ev.mods.alt) return;
    const text = ev.text();
    if (text.len > 0 and !(text.len == 1 and text[0] < 0x20)) {
        // Unbound printable input runs the mode's text command (the
        // modal posture: normal mode has none and swallows it). This IS
        // the hot typing→commit path — fence it so an accidental blocking
        // API here trips in Debug.
        const tc = ctx.keymap.textCommand() orelse return;
        core.task.beginHotSection();
        defer core.task.endHotSection();
        _ = core.command.run(ctx.commands, ctx, tc, &.{.{ .string = text }}) catch |err| {
            std.log.warn("{s} failed: {t}", .{ tc, err });
        };
    }
}
