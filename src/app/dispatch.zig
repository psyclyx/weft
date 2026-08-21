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
    const head = ctx.head;
    if (!km.isMenuMode(head.currentMode())) return .nil; // not in a menu → leave the mode be
    // In a menu: return to its recorded target, else the configured base mode
    // (vim's "normal", helix's "helix-normal", or plain "default").
    const base = if (ctx.buffers.default_mode.len > 0) ctx.buffers.default_mode else "default";
    const ret = head.menuReturn(head.currentMode()) orelse base;
    head.setMode(ctx.gpa, ret) catch {};
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

// ── Dot-repeat: record the last CHANGE as keystrokes, replay on demand ──────
//
// Composable + plugin-agnostic BY CONSTRUCTION: it records KEYS through the one
// dispatch interface, not commands, so a change made by ANY plugin (vim
// operators, autopair, comment, a structural edit) repeats out of the box. A
// "change" is whatever key sequence left the buffer edited between two RESTING
// points — a mode with no text command and no pending chord (each keymap's
// normal-equivalent), so this works across vim/helix/emacs without knowing them.
//
// W2a-2: this recorder is file-scope (process-global) state — two heads
// pressing keys concurrently would interleave into ONE dot-register. It is
// genuinely interaction state (per-head, like mode/pending/pick/echo — see
// core.Head), but it lives app-side (dispatch.zig, not core) and out of
// W2a-1's scope by the task brief ("do NOT touch dispatch.zig's globals").
// Left untouched here; W2a-2 is where this moves onto (or alongside) Head.
const KeyPress = struct {
    spec: [24]u8 = undefined,
    slen: u8 = 0,
    text: [8]u8 = undefined,
    tlen: u8 = 0,
};
const dot_cap = 256; // a change longer than this stops recording (degrade, don't clip mid-replay)
var dot_pending: [dot_cap]KeyPress = undefined;
var dot_pending_n: usize = 0;
var dot_reg: [dot_cap]KeyPress = undefined;
var dot_reg_n: usize = 0;
var dot_replaying: bool = false;
var dot_suppress: bool = false; // the repeat key itself must not become the new change
var dot_commits: usize = 0; // buffer commit count at the last rest
var dot_cursor: usize = 0; // cursor offset at the last rest (to tell a motion from a prefix)
var dot_buf: core.Buffers.Id = 0; // active buffer at the last rest (a switch resets the recorder)

fn dotRecord(spec: []const u8, text: []const u8) void {
    if (dot_pending_n >= dot_cap) return;
    var kp: KeyPress = .{};
    const s = @min(spec.len, kp.spec.len);
    @memcpy(kp.spec[0..s], spec[0..s]);
    kp.slen = @intCast(s);
    const tx = @min(text.len, kp.text.len);
    @memcpy(kp.text[0..tx], text[0..tx]);
    kp.tlen = @intCast(tx);
    dot_pending[dot_pending_n] = kp;
    dot_pending_n += 1;
}

/// At rest for change-recording: a mode that swallows typing (no text command),
/// with no half-typed chord and not inside a menu — the point a command sequence
/// has fully resolved. Generalizes vim `normal` / helix `normal` / emacs base.
fn dotAtRest(ctx: *core.command.Context) bool {
    return ctx.head.textCommand(ctx.keymap) == null and
        ctx.head.pending.len == 0 and
        !ctx.keymap.isMenuMode(ctx.head.currentMode());
}

/// Run at each dispatch's end (when recording): if we're back at rest, decide
/// what the just-finished sequence was — a change (buffer edited → promote its
/// keys to the register), a pure motion (no edit → discard), or the repeat key
/// itself (suppressed). Mid-command (not at rest) it keeps accumulating.
fn dotBoundary(ctx: *core.command.Context) void {
    const bid = ctx.buffers.active_id;
    if (bid != dot_buf) { // buffer switch: commit counts aren't comparable — reset.
        dot_buf = bid;
        dot_commits = ctx.editor().doc.commitCount();
        dot_cursor = ctx.editor().cursorOffset();
        dot_pending_n = 0;
        return;
    }
    if (!dotAtRest(ctx)) return; // mid-command — keep accumulating
    const now = ctx.editor().doc.commitCount();
    const cur = ctx.editor().cursorOffset();
    if (dot_suppress) {
        dot_suppress = false; // the repeat key itself: leave the register intact
    } else if (now != dot_commits and dot_pending_n > 0) {
        // a change completed — promote its keys to the register.
        @memcpy(dot_reg[0..dot_pending_n], dot_pending[0..dot_pending_n]);
        dot_reg_n = dot_pending_n;
    } else if (cur == dot_cursor) {
        // no edit AND the cursor didn't move: a PREFIX (a count, a half-typed
        // command) — keep it in `pending` so it rides with the change to come.
        return;
    }
    // a change, a motion (no edit but cursor moved), or a suppressed repeat: the
    // pending sequence is done — start a fresh one from here.
    dot_pending_n = 0;
    dot_commits = now;
    dot_cursor = cur;
}

/// Replay the recorded change by RE-FEEDING its keystrokes through the same
/// dispatch — so it composes exactly as the original did. The `.` keypress that
/// triggered this is then suppressed (it must not overwrite the register).
pub fn replayDot(ctx: *core.command.Context) void {
    if (dot_reg_n == 0) return;
    dot_replaying = true;
    var i: usize = 0;
    while (i < dot_reg_n) : (i += 1) {
        const kp = dot_reg[i];
        dispatchSpec(ctx, kp.spec[0..kp.slen], kp.text[0..kp.tlen]) catch {};
    }
    dot_replaying = false;
    dot_suppress = true;
}

/// Command handler for `repeat-change` (bound to `.`): replay the last change.
pub fn repeatChangeHandler(ctx: *core.command.Context, data: ?*anyopaque, args: []const core.command.Value) anyerror!core.command.Value {
    _ = data;
    _ = args;
    replayDot(ctx);
    return .nil;
}

/// Is `spec` a bare modifier keypress (its base keysym, after any modifier
/// prefixes, is itself a modifier)? Those carry no chord character.
fn isBareModifier(spec: []const u8) bool {
    var base = spec;
    while (base.len >= 2 and base[1] == '-' and (base[0] == 'C' or base[0] == 'M' or base[0] == 'S')) {
        base = base[2..];
    }
    const mods = [_][]const u8{
        "Shift_L",  "Shift_R",     "Control_L",        "Control_R",   "Alt_L",
        "Alt_R",    "Meta_L",      "Meta_R",           "Super_L",     "Super_R",
        "Hyper_L",  "Hyper_R",     "ISO_Level3_Shift", "Mode_switch", "Caps_Lock",
        "Num_Lock", "Scroll_Lock",
    };
    for (mods) |m| if (std.mem.eql(u8, base, m)) return true;
    return false;
}

pub fn dispatchKey(ctx: *core.command.Context, ev: wayland.KeyEvent) !void {
    // Translate the platform key event to a canonical keyspec (+ the printable
    // text it would insert), then hand off to the backend-independent
    // `dispatchSpec`. Splitting here means a headless driver (the e2e harness)
    // sends keypresses through the SAME dispatch the compositor path uses —
    // there is exactly one implementation of "what a keypress does".
    const c = wayland.c;
    var name_buf: [64]u8 = undefined;
    const n = c.xkb_keysym_get_name(ev.keysym, &name_buf, name_buf.len);
    if (n == 0) return;
    var spec_buf: [80]u8 = undefined;
    const spec = core.Keymap.keyspec(&spec_buf, ev.mods.ctrl, ev.mods.alt, ev.mods.shift, name_buf[0..@intCast(n)]);
    // A modified (ctrl/alt) key inserts nothing; otherwise the event's printable
    // text, unless it's a lone control char.
    const text: []const u8 = if (ev.mods.ctrl or ev.mods.alt) "" else blk: {
        const tx = ev.text();
        break :blk if (tx.len > 0 and !(tx.len == 1 and tx[0] < 0x20)) tx else "";
    };
    return dispatchSpec(ctx, spec, text);
}

/// The general keypress interface: run a canonical keyspec (`spec`) plus the
/// printable text it would insert (`text`, or "" for a non-text key) through the
/// keymap. A chord that could still extend is held (which-key shows its
/// completions off the head's pending chord); a completed binding runs; a lone unbound
/// key falls to text insertion; a dead-end chord resets. This is what
/// `dispatchKey` reduces to after xkb translation, and what a headless driver
/// calls to send a keypress to the REAL app (no parallel dispatch logic).
///
/// Any edit made here — directly or by a helper plugin (dw/autopair) — is the
/// user's, so it joins the user's undo history (see command.edit).
pub fn dispatchSpec(ctx: *core.command.Context, spec: []const u8, text: []const u8) !void {
    ctx.user_initiated = true;
    defer ctx.user_initiated = false;

    // A bare modifier press (Shift_L, Control_R, …) is NOT a key — it's the
    // state that shapes the next real key. It must never reach `feed`, or it
    // dead-ends a pending chord: `SPC :` needs Shift to make the colon, and that
    // intervening Shift event would reset the `space` prefix, so `:` then fires
    // vim-ex instead of the palette. (Same for any leader key with a shifted or
    // uppercase continuation — `g R`, `SPC C`, …) The compositor emits these as
    // real key events; swallow them here, the one shared dispatch point.
    if (isBareModifier(spec)) return;

    // Dot-repeat: record this keystroke (unless we ARE a replay), and decide at
    // the end of dispatch whether the sequence so far was a repeatable change.
    const dot_recording = !dot_replaying;
    if (dot_recording) dotRecord(spec, text);
    defer if (dot_recording) dotBoundary(ctx);

    // Mid-chord META keys act on the which-key overlay, NOT the sequence:
    //  · Backspace steps BACK one key of the pending chord (pop a level).
    //  · a NAV key (page down/up — `menu-nav` in defaults.js) pages the hint and
    //    leaves `pending` intact, so a long menu scrolls instead of the key
    //    dead-ending the chord and dismissing which-key.
    if (ctx.head.pending.len > 0) {
        if (std.mem.eql(u8, spec, "BackSpace")) {
            ctx.head.popPending(ctx.gpa) catch {};
            return;
        }
        if (ctx.keymap.navCommand(spec)) |cmd| {
            _ = core.command.run(ctx.commands, ctx, cmd, &.{}) catch |err|
                std.log.warn("which-key nav {s} failed: {t}", .{ cmd, err });
            return; // pending untouched — the hint just re-rendered
        }
    }
    // Feed the key through the pending SEQUENCE. `SPC f f` is a chord; `SPC C-w`
    // never fires global `C-w` — a menu is a sequence, not a mode.
    switch (ctx.head.feed(ctx.gpa, ctx.keymap, spec) catch core.Keymap.Feed.none) {
        .pending, .none => return,
        .text => {}, // a lone unbound key — fall through to text insertion
        .run => |cmd_name| {
            // Legacy mode-menu path (still valid while configs migrate to
            // sequences): a bound key whose command NAMES a menu mode enters it.
            if (ctx.keymap.isMenuMode(cmd_name)) {
                ctx.head.enterMode(ctx.gpa, ctx.keymap, cmd_name) catch {};
                return;
            }
            // Snapshot a menu mode so a one-shot key pops back after the command
            // runs (unless the command itself changed the mode).
            const menu_before: ?[]u8 = if (ctx.keymap.isMenuMode(ctx.head.currentMode()))
                ctx.gpa.dupe(u8, ctx.head.currentMode()) catch null
            else
                null;
            defer if (menu_before) |m| ctx.gpa.free(m);

            const result = core.command.run(ctx.commands, ctx, cmd_name, &.{}) catch |err| blk: {
                std.log.warn("command {s} failed: {t}", .{ cmd_name, err });
                break :blk core.command.Value.nil;
            };
            switch (result) {
                .string => |s| if (s.len > 0) {
                    ctx.head.echo.clearRetainingCapacity();
                    ctx.head.echo.appendSlice(ctx.gpa, s) catch {};
                },
                else => {},
            }
            if (menu_before) |m| {
                if (!ctx.keymap.isStickyMenu(m) and std.mem.eql(u8, ctx.head.currentMode(), m)) {
                    if (ctx.head.menuReturn(m)) |ret| ctx.head.setMode(ctx.gpa, ret) catch {};
                }
            }
            return;
        },
    }
    if (text.len == 0) return;
    // Unbound printable input runs the mode's text command (the modal posture:
    // normal mode has none and swallows it). This IS the hot typing→commit path —
    // fence it so an accidental blocking API here trips in Debug.
    const tc = ctx.head.textCommand(ctx.keymap) orelse return;
    core.task.beginHotSection();
    defer core.task.endHotSection();
    _ = core.command.run(ctx.commands, ctx, tc, &.{.{ .string = text }}) catch |err| {
        std.log.warn("{s} failed: {t}", .{ tc, err });
    };
}
