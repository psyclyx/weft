//! Key dispatch: one key event → keymap lookup → command. Runs inside the
//! hot section: dispatch is a table lookup plus the command itself,
//! allocation-only. A key the grammar leaves unbound COMMITS its text only in
//! a mode that declares a commit command (itself a command); there is no
//! editing path around the ABI, and no synthesis of text from a key. Vertical
//! motion and paging are view-computed (goal-x over rendered geometry), the
//! interactive override the core's scalar-column fallback can't do. Also the
//! menu command handlers (`mode.leave-menu`, `which-key.show`).
//!
//! **Menu enter/return (task #19 item 2): paired transients, not a bare
//! `enterMode`.** A bound key whose command NAMES a declared menu mode
//! (`ctx.keymap.modeHasTag(cmd_name, "menu")`, in `dispatchSpec`'s `.run` case) is
//! the actual production shape of a menu open — real examples:
//! `src/plugins/git/root.zig`'s `weft.bindKey("git", "c", "git-commit-dispatch")`,
//! `git-branch-menu`, `git-stash-menu`, `git-log-menu`, `git-rebase-menu`,
//! `git-commit-menu`. Entering one now PUSHES a paired
//! transient (`core/ctx.zig`'s `Ctx.pushTransient`, backed by
//! `core.Head.transient_stack`) instead of a bare `Head.enterMode`; the
//! matching leaf auto-pop and `mode.leave-menu` are the POP, reconstructed from
//! the known stack depth (`ourTransientTop`/`popOurTransient` below) rather
//! than threaded through as a live handle — the stack, not a Zig scope, is
//! the durable record spanning however many keypresses the menu stays open.
//! NOT migrated to PAIRED TRANSIENTS this pass (deliberately — see
//! `ctx.zig`'s module doc): guest-initiated `weft.setMode` (every plugin's
//! OWN direct menu entry — the `weft.transient` flag menus `git.push`/
//! `git.pull`/`git.fetch` (sticky, and now generated rather than
//! hand-written), `git-reset-menu`, vim's `op-pending`/`op-inner`/`op-around`, helix's
//! `helix-op`, files's `files-confirm`) stays
//! on the legacy `Head.menu_return` table (not `Head.transient_stack`),
//! which therefore CANNOT be deleted — it is still the only record for
//! those. Task #19 item 3 (the POLICY DOOR) is a separate axis from this:
//! it changed HOW that legacy table gets written — `wasm_host/keymap.zig`'s
//! `hSetMode` now captures a `Ctx` and calls `Ctx.enterMode`, not raw
//! `Head.enterMode`/`Head.enterModeRaw` — without changing WHICH table
//! (`menu_return` vs `transient_stack`) a guest menu lands in. The leaf
//! auto-pop / `mode.leave-menu` logic below checks WHICH mechanism owns the
//! currently-open menu (`ourTransientTop`) and falls back to the legacy
//! `menuReturn` lookup when it isn't ours (also now through the door, both
//! below) — so all paths keep their exact pre-migration observable
//! behavior. See `src/e2e/menu_test.zig` for the paired-transient path
//! driven through this REAL dispatch (enter/leaf/auto-pop, `mode.leave-menu`,
//! sticky re-enter, nested LIFO, a leaf's own buffer switch mid-menu, and
//! the interaction-boundary leak tripwire below) and `project_test.zig`'s
//! spine test for the real `git.commit-dispatch` → `git.commit` (buffer
//! switch mid-menu) → an ordinary draft entry saved to commit, unmodified
//! by this migration.

const std = @import("std");
const core = @import("weft_core");
const view_mod = @import("weft_gfx").view;
const wayland = @import("weft_platform").wayland;

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

/// `mode.leave-menu` (Escape / C-g, bound in the GLOBAL layer so it works anywhere)
/// — leave the current MENU back to its recorded return target. Outside a menu
/// it is a NO-OP: Escape must never force a mode change, or it drops you into
/// the editing base (`normal`) inside a read-only projection like git/files —
/// the recurring "wrong mode in a tool buffer" jank. A projection's own mode is
/// its resting mode; Escape leaves it alone. (An editing mode's own Escape —
/// vim insert/visual → normal — is bound mode-locally and wins over this.)
pub fn menuEscapeHandler(ctx: *core.command.Context, data: ?*anyopaque, args: []const core.command.Value) anyerror!core.command.Value {
    _ = data;
    _ = args;
    const km = ctx.keymap;
    const head = ctx.head;
    const cur = head.currentMode();
    if (!km.modeHasTag(cur, "menu")) return .nil; // not in a menu → leave the mode be
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

/// `which-key.show` (F1) — toggle a which-key peek at the CURRENT mode's keys.
/// It does NOT force-enter a hardcoded "leader": in normal you see the top-level
/// bindings (the leader prefix among them), in a submenu you see that submenu,
/// in the git status view its own keys. The shell no longer assumes the root menu is named
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
/// Move the caret one VISUAL line up (`dir < 0`) or down, holding its goal
/// column over rendered geometry — what `cursor.up`/`cursor.down` do in a
/// pane (`core.pointer.Panes.vertical`), which core cannot measure.
pub fn visualVertical(ed: *core.Editor, view: *view_mod.View, dir: i32) !void {
    const rope = ed.text();
    const cur = ed.cursorOffset();
    const gx = ed.goalX() orelse try view.xOfOffsetOnRow(rope, cur);
    ed.setGoalX(gx); // persists even at the doc edges, for the next step
    const pt = rope.offsetToPoint(cur);
    const rows = rope.lineCount();
    // Skip folded rows (shared fold-aware successor — the git status buffer's
    // j/k bind to cursor.up/down, which land here).
    const target_row = ed.nextVisibleRow(pt.row, if (dir < 0) -1 else 1, rows) orelse return;
    const target = try view.xToOffsetOnRow(rope, target_row, gx);
    ed.moveToVisual(target, gx);
}

// ── Dot-repeat: record the last CHANGE as keystrokes, replay on demand ──────
//
// Composable + plugin-agnostic BY CONSTRUCTION: it records KEYS through the one
// dispatch interface, not commands, so a change made by ANY plugin (vim
// operators, autopair, comment, a structural edit) repeats out of the box. A
// "change" is whatever key sequence left the buffer edited between two RESTING
// points — a mode that commits no text and has no pending chord (each
// keymap's normal-equivalent), so this works across vim/helix/emacs without
// knowing them.
//
// The recorder's STORAGE is `ctx.head.dot` (`core.Head.DotRepeat`) — per-head,
// like mode/pending/pick/echo, so two heads pressing keys concurrently record
// into separate registers and one's `.` never replays the other's change. This
// (the decision logic: what starts/ends a recording, the replay path) stays
// app-side because it needs `command.Context` (buffers/editor/keymap), which
// `Head` must not depend on.

/// One keystroke as the recorders store it — shared by dot-repeat and macros,
/// which are two registers over the same stream.
fn keyPress(spec: []const u8, commit: core.TextCommit) core.Head.KeyPress {
    var kp: core.Head.KeyPress = .{};
    const s = @min(spec.len, kp.spec.len);
    @memcpy(kp.spec[0..s], spec[0..s]);
    kp.slen = @intCast(s);
    const tx = @min(commit.bytes.len, kp.text.len);
    @memcpy(kp.text[0..tx], commit.bytes[0..tx]);
    kp.tlen = @intCast(tx);
    return kp;
}

fn dotRecord(dot: *core.Head.DotRepeat, spec: []const u8, commit: core.TextCommit) void {
    if (dot.pending_n >= core.Head.dot_cap) return;
    dot.pending[dot.pending_n] = keyPress(spec, commit);
    dot.pending_n += 1;
}

/// Forget the in-progress dot sequence and take the current buffer state as
/// the new rest point — what a macro replay does before it re-feeds keys, so
/// the `@a` that started it does not ride along into the next change `.`
/// repeats (vim: `.` after `@a` repeats the macro's last change).
fn dotResync(ctx: *core.command.Context) void {
    const dot = &ctx.head.dot;
    dot.pending_n = 0;
    const ed = ctx.buffers.active().textEditor() orelse {
        dot.synced = false;
        return;
    };
    dot.synced = true;
    dot.buf = ctx.buffers.active_id;
    dot.commits = ed.doc.commitCount();
    dot.cursor = ed.cursorOffset();
}

/// At rest for change-recording: a mode that commits no text, with no
/// half-typed chord and not inside a menu — the point a command sequence has
/// fully resolved. Generalizes vim `normal` / helix `normal` / emacs base.
fn dotAtRest(ctx: *core.command.Context) bool {
    return ctx.head.commitCommand(ctx.keymap) == null and
        ctx.head.pending.len == 0 and
        !ctx.keymap.modeHasTag(ctx.head.currentMode(), "menu");
}

/// Run at each dispatch's end (when recording): if we're back at rest, decide
/// what the just-finished sequence was — a change (buffer edited → promote its
/// keys to the register), a pure motion (no edit → discard), or the repeat key
/// itself (suppressed). Mid-command (not at rest) it keeps accumulating.
fn dotBoundary(ctx: *core.command.Context) void {
    const dot = &ctx.head.dot;
    const bid = ctx.buffers.active_id;
    // An entry with no text has no commits or cursor to compare against, so
    // there is no change boundary to observe here. Desync, so the next text
    // entry resyncs rather than comparing across the gap.
    const ed = ctx.buffers.active().textEditor() orelse {
        dot.synced = false;
        dot.pending_n = 0;
        return;
    };
    // Buffer switch (or this head's very first dispatch ever — `synced`
    // catches it even when `bid` coincidentally equals the zero default,
    // e.g. a head attaching on buffer 0 — see `DotRepeat.synced`'s doc):
    // commit counts from before now aren't comparable — reset and resync.
    if (!dot.synced or bid != dot.buf) {
        dot.synced = true;
        dot.buf = bid;
        dot.commits = ed.doc.commitCount();
        dot.cursor = ed.cursorOffset();
        dot.pending_n = 0;
        return;
    }
    if (!dotAtRest(ctx)) return; // mid-command — keep accumulating
    const now = ed.doc.commitCount();
    const cur = ed.cursorOffset();
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
        dispatchSpec(ctx, kp.spec[0..kp.slen], .from(kp.text[0..kp.tlen])) catch {};
    }
    dot.replaying = false;
    dot.suppress = true;
}

/// Command handler for `edit.repeat` (bound to `.`): replay the last change.
pub fn repeatChangeHandler(ctx: *core.command.Context, data: ?*anyopaque, args: []const core.command.Value) anyerror!core.command.Value {
    _ = data;
    _ = args;
    replayDot(ctx);
    return .nil;
}

// ── Macros: the keystroke stream into a named register, and back ──────────
//
// The same shape as dot-repeat, one level up: a macro is every key between
// `macro.record-start` and `macro.record-stop`, and playing it re-feeds them
// through `dispatchSpec` — so it composes exactly as the typing did, whatever
// grammar or plugin the keys reached. The storage is `ctx.head.macros`
// (per-head); which keys start, stop and play is the grammar's (vim `q`/`@`,
// helix `Q`/`q`).
//
// Undo follows vim: every change a replay makes is its own unit, as it was
// when typed. Pointer gestures are not recorded, for the reason dot-repeat
// gives. A replay does not record into a macro being recorded — the `@a` key
// was recorded, which is what replays it.

fn macroRecord(ctx: *core.command.Context, spec: []const u8, commit: core.TextCommit) void {
    const m = &ctx.head.macros;
    if (m.recording == null or m.depth > 0) return;
    if (core.pointer.isPointerSpec(spec)) return;
    if (ctx.head.pending.len == 0) m.rest_mark = m.rec.items.len;
    m.rec.append(ctx.gpa, keyPress(spec, commit)) catch {};
}

fn say(ctx: *core.command.Context, comptime fmt: []const u8, args: anytype) void {
    var buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
    ctx.head.echo.say(ctx.gpa, msg) catch {};
}

/// A register argument: one printable byte. `null` when the argument is
/// absent or empty — the caller picks its default.
fn registerArg(args: []const core.command.Value, i: usize) error{TypeMismatch}!?u8 {
    if (args.len <= i) return null;
    return switch (args[i]) {
        .nil => null,
        .string => |s| if (s.len == 0) null else if (s.len == 1) s[0] else error.TypeMismatch,
        else => error.TypeMismatch,
    };
}

/// The register a toggle records into when none is named (helix's `@`).
pub const default_macro_register: u8 = '@';

fn macroStart(ctx: *core.command.Context, reg: u8) !void {
    const m = &ctx.head.macros;
    if (m.register(reg) == null) return error.InvalidRegister;
    if (m.recording != null) macroStop(ctx);
    m.rec.clearRetainingCapacity();
    m.rest_mark = 0;
    m.recording = reg;
    say(ctx, "recording @{c}", .{reg});
}

fn macroStop(ctx: *core.command.Context) void {
    const m = &ctx.head.macros;
    const reg = m.recording orelse return;
    m.recording = null;
    // The key sequence that stopped the recording is not part of it.
    if (m.key_depth > 0) m.rec.shrinkRetainingCapacity(@min(m.rest_mark, m.rec.items.len));
    const slot = m.register(reg) orelse return;
    slot.clearRetainingCapacity();
    slot.appendSlice(ctx.gpa, m.rec.items) catch {
        say(ctx, "macro @{c}: out of memory", .{reg});
        return;
    };
    m.last_recorded = reg;
    say(ctx, "recorded @{c} ({d} keys)", .{ reg, slot.items.len });
}

/// Replay register `reg` `count` times. A register already mid-replay refuses
/// (a macro reaching its own `@a`), which is the whole recursion guard: the
/// set of playing registers is finite, so mutual recursion stops too.
fn macroPlay(ctx: *core.command.Context, reg: u8, count: usize) !void {
    const m = &ctx.head.macros;
    const slot = m.register(reg) orelse return error.InvalidRegister;
    if (m.playing.isSet(reg)) {
        say(ctx, "macro @{c} would replay itself; stopped", .{reg});
        return;
    }
    if (slot.items.len == 0) {
        say(ctx, "macro @{c} is empty", .{reg});
        return;
    }
    // A copy: a key in the macro may re-record this very register.
    const keys = try ctx.gpa.dupe(core.Head.KeyPress, slot.items);
    defer ctx.gpa.free(keys);
    m.last_played = reg;
    m.playing.set(reg);
    m.depth += 1;
    defer {
        m.depth -= 1;
        m.playing.unset(reg);
    }
    dotResync(ctx);
    const user_initiated = ctx.user_initiated;
    defer ctx.user_initiated = user_initiated;
    for (0..count) |_| for (keys) |kp| {
        dispatchSpec(ctx, kp.spec[0..kp.slen], .from(kp.text[0..kp.tlen])) catch |err| {
            say(ctx, "macro @{c} stopped: {t}", .{ reg, err });
            return;
        };
    };
}

/// `macro.record-start <reg>`.
pub fn macroRecordStartHandler(ctx: *core.command.Context, data: ?*anyopaque, args: []const core.command.Value) anyerror!core.command.Value {
    _ = data;
    try macroStart(ctx, (try registerArg(args, 0)) orelse return error.ArityMismatch);
    return .nil;
}

/// `macro.record-stop`: file the recording under its register.
pub fn macroRecordStopHandler(ctx: *core.command.Context, data: ?*anyopaque, args: []const core.command.Value) anyerror!core.command.Value {
    _ = data;
    _ = args;
    macroStop(ctx);
    return .nil;
}

/// `macro.record-toggle [reg]`: stop if recording, else start into `reg`
/// (default `@`) — helix's `Q`, which needs no register prompt.
pub fn macroRecordToggleHandler(ctx: *core.command.Context, data: ?*anyopaque, args: []const core.command.Value) anyerror!core.command.Value {
    _ = data;
    if (ctx.head.macros.recording != null) {
        macroStop(ctx);
        return .nil;
    }
    try macroStart(ctx, (try registerArg(args, 0)) orelse default_macro_register);
    return .nil;
}

/// `macro.play [reg] [count]`: with no register, the last one played, else the
/// last one recorded (vim's `@@`, helix's `q`).
pub fn macroPlayHandler(ctx: *core.command.Context, data: ?*anyopaque, args: []const core.command.Value) anyerror!core.command.Value {
    _ = data;
    const m = &ctx.head.macros;
    const reg = (try registerArg(args, 0)) orelse m.last_played orelse m.last_recorded orelse {
        say(ctx, "no macro to play", .{});
        return .nil;
    };
    try macroPlay(ctx, reg, try core.jumplist.countArg(args, 1));
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
    // The PHYSICAL/COMMIT split (architecture §10.1): the keyspec above is the
    // physical key; this is the text — if any — the keystroke committed. A
    // ctrl/alt chord is physical input only, and `TextCommit.from` keeps the
    // control-byte spellings xkb hands back for Tab/Escape/Return out of the
    // commit entirely.
    const commit: core.TextCommit = if (ev.mods.ctrl or ev.mods.alt) .none else .from(ev.text());
    return dispatchSpec(ctx, spec, commit);
}

/// The general keypress interface: one keystroke as its two independent
/// halves (architecture §10.1) — the canonical keyspec `spec` (physical input,
/// which the binding grammar interprets) and `commit` (the text this keystroke
/// committed, `.none` for a key that committed nothing). A chord that could
/// still extend is held (which-key shows its completions off the head's
/// pending chord); a completed binding runs; a dead-end chord resets; a lone
/// unbound key commits its text ONLY where the mode declares that it commits
/// text, and is otherwise unhandled. This is what `dispatchKey` reduces to
/// after xkb translation, and what a headless driver calls to send a keypress
/// to the REAL app (no parallel dispatch logic).
///
/// Any edit made here — directly or by a helper plugin (dw/autopair) — is the
/// user's, so it joins the user's undo history (see command.edit).
pub fn dispatchSpec(ctx: *core.command.Context, spec: []const u8, commit: core.TextCommit) !void {
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
    defer if (ctx.head.hasOpenTransients() and !ctx.keymap.modeHasTag(ctx.head.currentMode(), "menu")) {
        std.log.warn("dispatch: {d} open transient(s) survived a dispatch that left mode '{s}' (not a menu) — an unpaired push leaked; recovering by popping all", .{ ctx.head.transient_stack.items.len, ctx.head.currentMode() });
        ctx.head.dropAllTransients(ctx.gpa);
    };

    // A bare modifier press (Shift_L, Control_R, …) is NOT a key — it's the
    // state that shapes the next real key. It must never reach `feed`, or it
    // dead-ends a pending chord: `SPC :` needs Shift to make the colon, and that
    // intervening Shift event would reset the `space` prefix, so `:` then fires
    // vim.ex instead of the palette. (Same for any leader key with a shifted or
    // uppercase continuation — `g R`, `SPC C`, …) The compositor emits these as
    // real key events; swallow them here, the one shared dispatch point.
    if (isBareModifier(spec)) return;

    // A new key: its serial, and the end of any paint that was published to
    // last only until the next key (`Layer.until_key`) — dropped BEFORE the
    // command runs, so what this key paints survives to the one after.
    ctx.head.key_serial +%= 1;
    ctx.caps.layers.expireUntilKey(ctx.gpa);

    const macros = &ctx.head.macros;
    macros.key_depth += 1;
    defer macros.key_depth -= 1;
    // A macro records every key the user dispatches — before anything else
    // sees it, so a dialog answered mid-recording replays too.
    macroRecord(ctx, spec, commit);

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
    // A pointer gesture is not recorded: replayed later it would act wherever
    // the pointer happens to be then, not where the change was made.
    const dot_recording = !ctx.head.dot.replaying;
    if (dot_recording and !core.pointer.isPointerSpec(spec)) dotRecord(&ctx.head.dot, spec, commit);
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
    }
    // Navigation belongs to the active overlay scope, whether it was opened
    // by a chord, a menu mode, or a peek. It is not a menu leaf and therefore
    // must not pop the menu after paging. Keep the full authored action chain.
    const overlay_active = if (ctx.overlay_navigation_active) |active| active.* else false;
    if (ctx.head.pending.len > 0 or ctx.keymap.modeHasTag(ctx.head.currentMode(), "menu") or overlay_active) {
        if (ctx.keymap.navBindings(spec)) |arms| {
            if (chooseArm(ctx, arms)) |arm| invokeArm(ctx, arm);
            return;
        }
    }
    // Feed the key through the pending SEQUENCE. `SPC f f` is a chord; `SPC C-w`
    // never fires global `C-w` — a menu is a sequence, not a mode.
    const binding_mode = ctx.bindingMode();
    switch (ctx.head.feedInMode(ctx.gpa, ctx.keymap, binding_mode, spec) catch core.Keymap.Feed.none) {
        .pending, .none => return,
        .unbound => {}, // nothing bound it — fall through to the commit path
        .run => |arms| {
            // ONE grammar (doc/configuration.md §5.1): a bound name that
            // parses as `std.*`/`plugin.*` REFERS to an intention and is
            // resolved against the catalog; a flat name still names a
            // command. The authored list is walked first-applicable BEFORE
            // anything runs, so a list may mix the two.
            const arm = chooseArm(ctx, arms) orelse return;
            const cmd_name = switch (arm) {
                .command => |name| name,
                .decision => "",
            };
            // A bound key whose command NAMES a menu mode enters it — the
            // PAIRED-TRANSIENT push (task #19 item 2, doc/cwa-prior-docs-audit.md §5,
            // `ctx.zig`'s `Ctx.pushTransient`): `Head.transient_stack` durably
            // records the pre-push mode as this frame's return target, so
            // leaving (the leaf auto-pop below, or `mode.leave-menu`) is the
            // MATCHING pop, not an independent `menuReturn` lookup.
            if (arm == .command and ctx.keymap.modeHasTag(cmd_name, "menu")) {
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
            const menu_before: ?[]u8 = if (ctx.keymap.modeHasTag(ctx.head.currentMode(), "menu"))
                ctx.gpa.dupe(u8, ctx.head.currentMode()) catch null
            else
                null;
            defer if (menu_before) |m| ctx.gpa.free(m);

            invokeArm(ctx, arm);
            if (menu_before) |m| {
                if (!ctx.keymap.modeHasTag(m, "sticky") and std.mem.eql(u8, ctx.head.currentMode(), m)) {
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
    if (commit.isEmpty()) return;
    // The commit reaches the editable endpoint ONLY through a mode that
    // DECLARES it commits text. A structural mode declares none, so an unbound
    // key there is simply unhandled — nothing is synthesized (§10.1). This IS
    // the hot typing→commit path — fence it so an accidental blocking API here
    // trips in Debug.
    // Rows focused under `row` take the key as type-ahead (core's, over any
    // rows — doc/chrome.md §5.2) only where no text commit claims it: the
    // one predicate, `type_ahead.rowsTakeKeys`, asked before any row moves,
    // so a picker's query, a prompt's line or snipe's character opened over
    // a focused row gets its letters.
    const jumped = core.type_ahead.feed(ctx, commit.bytes) catch |err| blk: {
        std.log.warn("type-ahead failed: {t}", .{err});
        break :blk true;
    };
    if (jumped) return;
    // A begun field edit commits too (`scene_edit.textCommit`); anywhere nothing
    // does, the key is unhandled.
    const commit_cmd = core.scene_edit.textCommit(ctx.semantic, ctx.keymap, ctx.head, ctx.head.currentMode()) orelse return;
    core.task.beginHotSection();
    defer core.task.endHotSection();
    _ = core.command.run(ctx.commands, ctx, commit_cmd, &.{.{ .string = commit.bytes }}) catch |err| {
        std.log.warn("{s} failed: {t}", .{ commit_cmd, err });
    };
}

// ── Intention dispatch (architecture §9.2, §10.2) ────────────────────
//
// A binding names intentions, not commands. The authored arm list resolves
// FIRST-APPLICABLE against the pushed-offer catalog before anything runs,
// and the winner is invoked through its endpoint token — so which code
// answers `Return` is a property of what the focused context offers, never
// of what loaded first.

/// The `catalog.Context` this keystroke resolves against. Core owns the ONE
/// derivation (`core/intent.zig`); explaining a binding and the palette's
/// offer membrane ask through the same function, so a second, drifting
/// context builder cannot exist.
pub const catalogContext = core.intent.catalogContext;

/// What one keypress will actually do: run a command by name, or invoke the
/// endpoint an intention resolved to.
const Arm = union(enum) {
    command: []const u8,
    decision: core.catalog.Decision,
};

/// All binding scopes use the same intention endpoint and command reporting.
fn invokeArm(ctx: *core.command.Context, arm: Arm) void {
    switch (arm) {
        .decision => |d| invokeDecision(ctx, d),
        .command => |name| core.command.invoke(ctx.commands, ctx, name, &.{}),
    }
}

/// Walk the authored list first-applicable (§10.2). An INTENTION arm asks
/// the catalog: an offer exists and it wins; no offer at all is
/// nonapplicable, so the walk moves on; `disabled`/`checking` is
/// relevant-but-impossible and STOPS the walk, so `[std.target.activate,
/// std.editing.insert-line-break]` cannot quietly insert a line break while
/// activation is refused. A FLAT arm asks the command registry (a menu mode
/// is applicable too).
///
/// Nothing applicable ends the keypress: an unoffered intention is
/// unavailable, not a failure. A flat trailing name still runs and reports
/// itself, so a mistyped bind stays exactly as loud as before.
fn chooseArm(ctx: *core.command.Context, arms: []const []const u8) ?Arm {
    var snap: ?*const core.catalog.Snapshot = null;
    for (arms, 0..) |name, i| {
        if (!core.catalog.isIntentionName(name)) {
            if (ctx.commands.resolve(name) != null or ctx.keymap.modeHasTag(name, "menu")) return .{ .command = name };
            continue;
        }
        const plane = ctx.intent orelse {
            std.log.debug("dispatch: '{s}' names an intention, but no catalog is wired here", .{name});
            continue;
        };
        // Built lazily, so a binding of plain command names never touches the
        // catalog.
        if (snap == null) snap = plane.snapshotFor(ctx) orelse return null;
        const id = plane.catalog.intention(name) catch |err| {
            std.log.warn("dispatch: intention '{s}' is not resolvable: {t}", .{ name, err });
            continue;
        };
        switch (snap.?.resolveOne(id)) {
            .decision => |won| {
                var d = won;
                d.arm = @intCast(i); // the authored position, for tracing
                return .{ .decision = d };
            },
            .unavailable => |u| switch (u) {
                .no_offer => {}, // nonapplicable — the next arm gets its turn
                .disabled => |d| {
                    // A refusal is a reason to SHOW (§9.3): the key said
                    // something, and the reason it did not act is the answer.
                    traceUnavailable(plane, name, u);
                    echoDisabled(ctx, plane, d);
                    return null;
                },
                .checking => {
                    traceUnavailable(plane, name, u);
                    return null;
                },
            },
            .ambiguous => |a| {
                echoAmbiguity(ctx, plane, a);
                return null;
            },
        }
    }
    // Nothing applied. A flat name is still a command that should say so.
    const last = arms[arms.len - 1];
    return if (core.catalog.isIntentionName(last)) null else .{ .command = last };
}

/// Invoke a decision through its endpoint token. The plane rechecks the
/// epoch, the table revision, and the endpoint's generation — visibility is
/// never authority.
fn invokeDecision(ctx: *core.command.Context, d: core.catalog.Decision) void {
    const plane = ctx.intent orelse return;
    plane.invoke(ctx, d) catch |err| {
        std.log.warn("dispatch: {s} refused at the door: {t}", .{ plane.catalog.intentionName(d.intention), err });
    };
}

/// The one-line trace an arm that stopped the walk leaves behind (the explain
/// UI reads the same walk through `Catalog.explain`, later).
fn traceUnavailable(plane: *const core.intent.Plane, name: []const u8, u: core.catalog.Unavailable) void {
    switch (u) {
        .no_offer => std.log.debug("dispatch: nothing offers '{s}' here", .{name}),
        .disabled => |d| std.log.debug("dispatch: {s} disabled by {s}: {s}", .{
            plane.catalog.intentionName(d.intention),
            plane.catalog.providerName(d.provider),
            d.reason.reason,
        }),
        .checking => |c| std.log.debug("dispatch: {s} still being computed by {s}", .{
            plane.catalog.intentionName(c.intention),
            plane.catalog.providerName(c.provider),
        }),
    }
}

fn echoDisabled(ctx: *core.command.Context, plane: *const core.intent.Plane, d: anytype) void {
    const why = if (d.reason.message.len > 0) d.reason.message else d.reason.reason;
    var buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "{s}: {s}", .{ plane.catalog.intentionName(d.intention), why }) catch why;
    ctx.head.echo.say(ctx.gpa, msg) catch {};
}

fn echoAmbiguity(ctx: *core.command.Context, plane: *const core.intent.Plane, a: core.catalog.Ambiguity) void {
    var buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "{s}: ambiguous — {s} and {s} offer equally", .{
        plane.catalog.intentionName(a.intention),
        a.a.owner,
        a.b.owner,
    }) catch "intention: ambiguous";
    ctx.head.echo.say(ctx.gpa, msg) catch {};
    std.log.warn("dispatch: {s}", .{msg});
}
