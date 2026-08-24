//! Key dispatch: one key event → keymap lookup → command. Runs inside the
//! hot section: dispatch is a table lookup plus the command itself,
//! allocation-only. Unbound printable input becomes the mode's text command
//! (itself a command); there is no editing path around the ABI. Vertical
//! motion and paging are view-computed (goal-x over rendered geometry), the
//! interactive override the core's scalar-column fallback can't do. Also the
//! menu command handlers (`menu-escape`, `which-key-now`).
//!
//! **Menu enter/return (task #19 item 2): paired transients, not a bare
//! `enterMode`.** A bound key whose command NAMES a declared menu mode
//! (`ctx.keymap.isMenuMode(cmd_name)`, in `dispatchSpec`'s `.run` case) is
//! the actual production shape of a menu open — real examples:
//! `src/guest/git.zig`'s `weft.bindKey("magit", "c", "git-commit-dispatch")`,
//! `git-branch-menu`, `git-stash-menu`, `git-log-menu`, `git-rebase-menu`,
//! `git-commit-menu`, `git-input-menu`. Entering one now PUSHES a paired
//! transient (`core/ctx.zig`'s `Ctx.pushTransient`, backed by
//! `core.Head.transient_stack`) instead of a bare `Head.enterMode`; the
//! matching leaf auto-pop and `menu-escape` are the POP, reconstructed from
//! the known stack depth (`ourTransientTop`/`popOurTransient` below) rather
//! than threaded through as a live handle — the stack, not a Zig scope, is
//! the durable record spanning however many keypresses the menu stays open.
//! NOT migrated to PAIRED TRANSIENTS this pass (deliberately — see
//! `ctx.zig`'s module doc): guest-initiated `weft.setMode` (every plugin's
//! OWN direct menu entry — `git-push-menu`/`git-pull-menu`/`git-fetch-menu`
//! (sticky), `git-reset-menu`, `git-confirm`/`git-confirm2`, vim's
//! `op-pending`/`op-to`, helix's `helix-op`, dired's `dired-confirm`) stays
//! on the legacy `Head.menu_return` table (not `Head.transient_stack`),
//! which therefore CANNOT be deleted — it is still the only record for
//! those. Task #19 item 3 (the POLICY DOOR) is a separate axis from this:
//! it changed HOW that legacy table gets written — `wasm_host/keymap.zig`'s
//! `hSetMode` now captures a `Ctx` and calls `Ctx.enterMode`, not raw
//! `Head.enterMode`/`Head.enterModeRaw` — without changing WHICH table
//! (`menu_return` vs `transient_stack`) a guest menu lands in. The leaf
//! auto-pop / `menu-escape` logic below checks WHICH mechanism owns the
//! currently-open menu (`ourTransientTop`) and falls back to the legacy
//! `menuReturn` lookup when it isn't ours (also now through the door, both
//! below) — so all paths keep their exact pre-migration observable
//! behavior. See `src/e2e/menu_test.zig` for the paired-transient path
//! driven through this REAL dispatch (enter/leaf/auto-pop, `menu-escape`,
//! sticky re-enter, nested LIFO, a leaf's own buffer switch mid-menu, and
//! the interaction-boundary leak tripwire below) and `project_test.zig`'s
//! spine test for the real `git-commit-dispatch` → `git-commit` (buffer
//! switch mid-menu) → `git-commit-menu` → `git-commit-finish` flow,
//! unmodified by this migration.

const std = @import("std");
const semantic = @import("weft_semantic");
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
    head: *core.Head,
    semantic_services: *core.semantic.Services,
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
    const scale: f32 = @floatFromInt(window.bufferScale());
    const px = @as(f32, @floatCast(window.mouse_x)) * scale;
    const py = @as(f32, @floatCast(window.mouse_y)) * scale;
    // Pane routing: a click outside the focused pane's rect focuses the
    // pane under the cursor (the intent is applied below, against the
    // layout); inside, the click maps directly (panes render into their
    // own rects, so the geometry map is already in absolute coords). The
    // frame rect is last render's — one-frame latency, unseen. `head`'s
    // focus, not the layout's own — see window_layout.zig's module doc.
    const focused = window_layout.headFocus(win_layout, head);
    const click_in_peek = win_layout.count() > 1 and !win_layout.focusedRect(focused, last_frame_rect).contains(px, py);
    if (window.consumeMousePressed(0)) {
        if (click_in_peek) {
            win_ctx.click_focus = true;
            win_ctx.click_x = px;
            win_ctx.click_y = py;
            had_input.* = true;
            dirty = true;
        } else if (view.hasSemanticInput()) {
            if (view.semanticHitAtPoint(px, py)) |hit| {
                if (semantic_services.views.get(hit.view)) |instance| {
                    var path_nodes: [130]semantic.scene.NodeId = undefined;
                    if (try instance.focusPath(hit.node, &path_nodes)) |path|
                        try head.semantic_focus.set(gpa, path);
                }
            }
            drag_anchor.* = null;
            drag_selecting.* = false;
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
    } else if (window.mouse_down[0] and !click_in_peek and !view.hasSemanticInput()) {
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

/// Whether the TOP of `ctx.head`'s transient stack is the frame our own
/// paired-transient menu machinery (below) pushed for menu mode `m` — the
/// precondition every pop site here checks before touching the stack.
/// `ctx.zig`'s F3 invariant (a debug assertion in `Ctx.capture`) is exactly
/// this: whenever the stack is non-empty its top frame's mode equals
/// `head.currentMode()`, so if `m` is still current, an open top frame
/// naming `m` can only be the one THIS FILE pushed for it (a guest-entered
/// menu — `weft.setMode`, not migrated this pass — never touches the
/// stack at all, see `ctx.zig`'s module doc).
fn ourTransientTop(ctx: *core.command.Context, m: []const u8) ?usize {
    const stack = ctx.head.transient_stack.items;
    if (stack.len == 0) return null;
    const depth = stack.len - 1;
    return if (std.mem.eql(u8, stack[depth].mode, m)) depth else null;
}

/// Pop our own transient at `depth`, restoring the mode it recorded at push
/// time — the paired-transient counterpart of the legacy
/// `head.menuReturn(m)`-then-`setMode` dance. Reconstructs a `TransientHandle`
/// from the known depth rather than threading one through from the push
/// site: `Head.transient_stack` (not a Zig stack frame) is already the
/// durable record spanning however many keypresses the menu stayed open for
/// (`ctx.zig`'s "Paired transients" doc), so there is no live handle value
/// to have carried across those separate `dispatchSpec` calls in the first
/// place — reconstructing one here to reuse `TransientHandle.deinit`'s
/// LIFO-checked, idempotent pop is the honest way to drive the SAME
/// mechanism, not a workaround of it.
fn popOurTransient(ctx: *core.command.Context, depth: usize) void {
    var handle: core.ctx.TransientHandle = .{ .host = ctx, .depth = depth };
    handle.deinit();
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
    const cur = head.currentMode();
    if (!km.isMenuMode(cur)) return .nil; // not in a menu → leave the mode be
    // Paired-transient path (task #19 item 2): if we're the one who pushed
    // this menu, leaving IS the pop — restores the exact pre-push mode,
    // whatever it was, no separate lookup needed.
    if (ourTransientTop(ctx, cur)) |depth| {
        popOurTransient(ctx, depth);
        return .nil;
    }
    // Legacy fallback: a GUEST-entered menu (`weft.setMode`'s own
    // `menu_return` bookkeeping — task #19 item 2's paired-transient stack
    // only tracks menus DISPATCH itself pushed, see this function's module
    // doc) — return to its recorded target, else the configured base mode
    // (vim's "normal", helix's "helix-normal", or plain "default"). Still on
    // the POLICY door (task #19 item 3): `menuEscapeHandler` runs with a
    // live `ctx`, so this goes through `Ctx.setMode`, not raw `Head`.
    const base = if (ctx.buffers.default_mode.len > 0) ctx.buffers.default_mode else "default";
    const ret = head.menuReturn(cur) orelse base;
    ctx.capturedCtx().setMode(ret) catch {};
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
    if (ctx.semantic) |services| if (try services.moveHeadFocus(ctx.head, ctx.gpa, .previous)) return .nil;
    try visualVertical(ctx.editor(), viewOf(data), -1);
    return .nil;
}

pub fn cursorDownHandler(ctx: *core.command.Context, data: ?*anyopaque, args: []const core.command.Value) anyerror!core.command.Value {
    _ = args;
    if (ctx.semantic) |services| if (try services.moveHeadFocus(ctx.head, ctx.gpa, .next)) return .nil;
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
// The recorder's STORAGE is `ctx.head.dot` (`core.Head.DotRepeat`) — per-head,
// like mode/pending/pick/echo, so two heads pressing keys concurrently record
// into separate registers and one's `.` never replays the other's change. This
// (the decision logic: what starts/ends a recording, the replay path) stays
// app-side because it needs `command.Context` (buffers/editor/keymap), which
// `Head` must not depend on.

fn dotRecord(dot: *core.Head.DotRepeat, spec: []const u8, text: []const u8) void {
    if (dot.pending_n >= core.Head.dot_cap) return;
    var kp: core.Head.KeyPress = .{};
    const s = @min(spec.len, kp.spec.len);
    @memcpy(kp.spec[0..s], spec[0..s]);
    kp.slen = @intCast(s);
    const tx = @min(text.len, kp.text.len);
    @memcpy(kp.text[0..tx], text[0..tx]);
    kp.tlen = @intCast(tx);
    dot.pending[dot.pending_n] = kp;
    dot.pending_n += 1;
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
    const dot = &ctx.head.dot;
    const bid = ctx.buffers.active_id;
    // Buffer switch (or this head's very first dispatch ever — `synced`
    // catches it even when `bid` coincidentally equals the zero default,
    // e.g. a head attaching on buffer 0 — see `DotRepeat.synced`'s doc):
    // commit counts from before now aren't comparable — reset and resync.
    if (!dot.synced or bid != dot.buf) {
        dot.synced = true;
        dot.buf = bid;
        dot.commits = ctx.editor().doc.commitCount();
        dot.cursor = ctx.editor().cursorOffset();
        dot.pending_n = 0;
        return;
    }
    if (!dotAtRest(ctx)) return; // mid-command — keep accumulating
    const now = ctx.editor().doc.commitCount();
    const cur = ctx.editor().cursorOffset();
    if (dot.suppress) {
        dot.suppress = false; // the repeat key itself: leave the register intact
    } else if (now != dot.commits and dot.pending_n > 0) {
        // a change completed — promote its keys to the register.
        @memcpy(dot.reg[0..dot.pending_n], dot.pending[0..dot.pending_n]);
        dot.reg_n = dot.pending_n;
    } else if (cur == dot.cursor) {
        // no edit AND the cursor didn't move: a PREFIX (a count, a half-typed
        // command) — keep it in `pending` so it rides with the change to come.
        return;
    }
    // a change, a motion (no edit but cursor moved), or a suppressed repeat: the
    // pending sequence is done — start a fresh one from here.
    dot.pending_n = 0;
    dot.commits = now;
    dot.cursor = cur;
}

/// Replay the recorded change by RE-FEEDING its keystrokes through the same
/// dispatch — so it composes exactly as the original did. The `.` keypress that
/// triggered this is then suppressed (it must not overwrite the register).
pub fn replayDot(ctx: *core.command.Context) void {
    const dot = &ctx.head.dot;
    if (dot.reg_n == 0) return;
    dot.replaying = true;
    var i: usize = 0;
    while (i < dot.reg_n) : (i += 1) {
        const kp = dot.reg[i];
        dispatchSpec(ctx, kp.spec[0..kp.slen], kp.text[0..kp.tlen]) catch {};
    }
    dot.replaying = false;
    dot.suppress = true;
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
    //
    // P3 (doc/rendering.md): goes through `Window.keysymName` — the
    // Platform's public surface — rather than importing `wayland.c` (xkb's
    // raw C API) directly, as this file used to. This file is
    // platform-NEUTRAL (shared by the real compositor path and every
    // headless/e2e keypress via `dispatchSpec`, below); it should only ever
    // need `wayland.KeyEvent`'s public shape, never wayland's C internals.
    var name_buf: [64]u8 = undefined;
    const name = wayland.Window.keysymName(&name_buf, ev.keysym);
    if (name.len == 0) return;
    var spec_buf: [80]u8 = undefined;
    const spec = core.Keymap.keyspec(&spec_buf, ev.mods.ctrl, ev.mods.alt, ev.mods.shift, name);
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
    // THE INTERACTION-BOUNDARY LEAK CHECK (task #19 item 2): every path
    // through this function that pushes a paired transient (the menu-enter
    // branch below) also pops it before returning, on every branch that
    // handling has — so by the time we're back here, at the true edge of
    // ONE dispatch, either the stack is empty or the head is sitting in
    // exactly the menu mode its top frame names (the same invariant
    // `ctx.zig`'s F3 debug-asserts on every `Ctx.capture`). If BOTH "not a
    // menu" and "transients open" are true, a push somewhere leaked past
    // its pop — the class this whole mechanism exists to make loud instead
    // of silent. This should be UNREACHABLE; it is the tripwire proving it,
    // not a normal-operation code path (see `menu_test.zig`'s fault-
    // injection test, which pushes one on purpose and confirms this fires).
    defer if (ctx.head.hasOpenTransients() and !ctx.keymap.isMenuMode(ctx.head.currentMode())) {
        std.log.warn("dispatch: {d} open transient(s) survived a dispatch that left mode '{s}' (not a menu) — an unpaired push leaked; recovering by popping all", .{ ctx.head.transient_stack.items.len, ctx.head.currentMode() });
        ctx.head.dropAllTransients(ctx.gpa);
    };

    // A bare modifier press (Shift_L, Control_R, …) is NOT a key — it's the
    // state that shapes the next real key. It must never reach `feed`, or it
    // dead-ends a pending chord: `SPC :` needs Shift to make the colon, and that
    // intervening Shift event would reset the `space` prefix, so `:` then fires
    // vim-ex instead of the palette. (Same for any leader key with a shifted or
    // uppercase continuation — `g R`, `SPC C`, …) The compositor emits these as
    // real key events; swallow them here, the one shared dispatch point.
    if (isBareModifier(spec)) return;

    // Active interactions get first refusal through their own local binding
    // table. This is a semantic action dispatch, not a temporary editor mode:
    // unbound keys continue normally, while a bound y/n/Escape never leaks to
    // the global keymap or triggers which-key merely because a dialog exists.
    if (ctx.semantic) |services| {
        if (services.invokeInteractionInput(&ctx.head.interactions, ctx.head, ctx.gpa, spec) catch |err| blk: {
            std.log.warn("interaction input '{s}' failed: {t}", .{ spec, err });
            break :blk @as(?core.semantic.Services.ActionEffect, .declined);
        }) |_| return;
    }

    // Dot-repeat: record this keystroke (unless we ARE a replay), and decide at
    // the end of dispatch whether the sequence so far was a repeatable change.
    const dot_recording = !ctx.head.dot.replaying;
    if (dot_recording) dotRecord(&ctx.head.dot, spec, text);
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
            // A bound key whose command NAMES a menu mode enters it — the
            // PAIRED-TRANSIENT push (task #19 item 2, north-star-plan §2.1/§5,
            // `ctx.zig`'s `Ctx.pushTransient`): `Head.transient_stack` durably
            // records the pre-push mode as this frame's return target, so
            // leaving (the leaf auto-pop below, or `menu-escape`) is the
            // MATCHING pop, not an independent `menuReturn` lookup.
            if (ctx.keymap.isMenuMode(cmd_name)) {
                if (std.mem.eql(u8, ctx.head.currentMode(), cmd_name)) {
                    // Re-entering the menu we're ALREADY in (the bound key
                    // fires again while it's open) is idempotent, not a
                    // fresh scope — a sticky re-enter is NOT a second push
                    // (it would grow the stack for no real nesting).
                    // `enterMode` itself already no-ops the return-target
                    // record in this case; call it directly through the
                    // POLICY door (task #19 item 3), matching the
                    // pre-migration behavior exactly.
                    ctx.capturedCtx().enterMode(ctx.keymap, cmd_name) catch {};
                    return;
                }
                const c = core.ctx.Ctx.capture(ctx);
                _ = c.pushTransient(ctx.keymap, cmd_name) catch |err| {
                    std.log.warn("dispatch: menu-enter '{s}' refused ({t}) — mode unchanged", .{ cmd_name, err });
                };
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
                    // Still the same menu after the leaf: time to auto-pop.
                    // If WE pushed it (the branch above), pop through the
                    // paired mechanism (restores the exact pre-push mode);
                    // else it's a guest-entered menu (`weft.setMode`, out of
                    // this pass's scope) — the legacy `menuReturn` lookup.
                    if (ourTransientTop(ctx, m)) |depth| {
                        popOurTransient(ctx, depth);
                    } else if (ctx.head.menuReturn(m)) |ret| {
                        // Legacy fallback (task #19 item 2's scope, unchanged)
                        // through the POLICY door (task #19 item 3).
                        ctx.capturedCtx().setMode(ret) catch {};
                    }
                } else if (!std.mem.eql(u8, ctx.head.currentMode(), m)) {
                    // The leaf itself already moved us elsewhere (a guest
                    // `weft.setMode`, or a buffer switch) — if that leaf was
                    // running INSIDE our own pushed transient for `m`, that
                    // frame is now stale: the scope ended through a
                    // different door than the pop above. Discard it WITHOUT
                    // restoring (a restore here would stomp the mode the
                    // leaf just deliberately set) — still has to come off
                    // the stack, or it leaks (task #19 item 2's tripwire,
                    // below, would otherwise be the one to catch this).
                    if (ourTransientTop(ctx, m)) |depth| {
                        ctx.head.popTransientDiscard(ctx.gpa, depth) catch |err| {
                            std.log.warn("dispatch: discard-pop of stale transient '{s}' failed ({t})", .{ m, err });
                        };
                    }
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
