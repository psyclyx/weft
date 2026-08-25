//! e2e test file — THE TWO-HEAD GATE (north-star-plan §6 W2a GATE): drives
//! TWO independent `core.Head`s over ONE session/system (`h.SecondHead`,
//! harness.zig) through the REAL dispatch path (`dispatch.dispatchSpec` /
//! `command.run`), proving the per-head split W2a-1/W2a-2 built (mode,
//! pending chord, menu-return, pick session, echo line, dot-repeat
//! register, window-layout focus) actually holds with two heads live at
//! once — not just when there is exactly one, which every other e2e test
//! (implicitly) assumes. The window-layout test below goes further than
//! "independent values": it drives an ACTUAL structural mutation (A closes
//! a pane B is focused on) and asserts B recovers instead of reading
//! through a freed/retyped node — see `gfx/window_layout.zig`'s module doc
//! for the generation-checked handle this exercises. Both the window-focus
//! recovery assertion and the dot-repeat `synced`-gate assertion below were
//! verified by fault injection (temporarily reintroducing the bug each
//! guards against) to actually fail without the fix, not just pass by
//! accident — see the coordinator review response for that record.
//!
//! Most of this file drives core-only commands (the `default`-mode floor
//! `core.builtins` installs, plus a couple of synthetic mode-entry commands
//! as plain Zig handlers) so those assertions are about HEAD isolation at
//! the layer W2a-2 touched (dispatch.zig + core.Head), not entangled with
//! the guest-ABI gap below.
//!
//! GUEST-ABI HEAD ADDRESSING (task #14, north-star-plan §2.1/§2.7): the
//! tests at the bottom of this file close a gap this file's header used to
//! report rather than patch — `wasm_host/commands.zig`'s `wpCmdTrampoline`
//! used to run a WASM-plugin-backed command's `on_command` against the
//! PLUGIN's load-time `ctx` (set once when `loadPlugin` ran, always the
//! first/primary head), not the `ctx` that actually dispatched the call; it
//! even discarded the passed-in `ctx` (`_ = ctx;`). So a guest command (any
//! real vim/helix/emacs keybinding — `weft.setMode`/`weft.edit`/etc.) driven
//! "as" a second head silently acted on the FIRST head's `Head`. The fix
//! (`WasmPlugin.active_ctx`, `wasm_host/commands.zig`'s module doc — the
//! dispatching/background classification for every host→guest entry) routes
//! every `wasm_host/*` read/mutation through the DISPATCHING head's ctx for
//! the call's duration; the quickjs resident-plugin plane
//! (`core/quickjs.zig`'s `JsPlugin`/`Bridge`) had the identical shape of bug
//! in its own command trampoline and got the identical fix. The tests below
//! drive a REAL guest plugin (`src/guest/headtest.zig` — a minimal fixture
//! built for exactly this, see its module doc for why not `loadVim`) through
//! head B and assert head A is untouched, that a BACKGROUND entry
//! (`on_poll`) targets the system default regardless of which head last
//! dispatched, and that a `wl_run`-nested reentrant dispatch keeps the same
//! dispatching head through the nesting (save/restore, not a bare set).

const std = @import("std");
const t = std.testing;
const h = @import("harness.zig");

const core = h.core;
const command = core.command;
const Editor = h.Editor;
const SecondHead = h.SecondHead;
const window_layout = h.window_layout;

/// Run `cmd` (no args) and return its integer result, or 0 if it didn't set
/// one — a thin wrapper `Editor`/`SecondHead` don't expose (they only run
/// for side effects), used below to observe `head-poll-count` without
/// depending on a head mutation `on_poll` itself no longer makes.
fn runInt(ed: *Editor, cmd: []const u8) i64 {
    const v = command.run(ed.commands, ed.ctx, cmd, &.{}) catch return 0;
    return if (v == .integer) v.integer else 0;
}

fn noop(ctx: *command.Context, data: ?*anyopaque, args: []const command.Value) anyerror!command.Value {
    _ = ctx;
    _ = data;
    _ = args;
    return .nil;
}

fn enterInsert(ctx: *command.Context, data: ?*anyopaque, args: []const command.Value) anyerror!command.Value {
    _ = data;
    _ = args;
    // POLICY door (task #19 item 3): an ordinary bound command handler has a
    // live `ctx` — this is the shape `ctx.zig`'s module doc's worked example
    // gives, exercised here through REAL dispatch (`ed.press`).
    ctx.capturedCtx().setMode("insert") catch {};
    return .nil;
}

fn enterNormal(ctx: *command.Context, data: ?*anyopaque, args: []const command.Value) anyerror!command.Value {
    _ = data;
    _ = args;
    ctx.capturedCtx().setMode("normal") catch {};
    return .nil;
}

/// A minimal modal keymap — "normal" (resting: no text command) / "insert"
/// (self-inserts via core's `insert-text`, the same builtin the modeless
/// `default` floor uses) — built from plain core commands, no guest plugin.
/// Mirrors vim's normal/insert shape just enough to exercise dot-repeat's
/// rest-point logic (`dispatch.dotAtRest`) without touching the wasm host.
fn initModal(gpa: std.mem.Allocator, ed: *Editor) !void {
    _ = try ed.commands.bind(gpa, "enter-insert", .{ .name = "enter-insert", .summary = "test: enter insert", .args = &.{}, .handler = enterInsert });
    _ = try ed.commands.bind(gpa, "enter-normal", .{ .name = "enter-normal", .summary = "test: enter normal", .args = &.{}, .handler = enterNormal });
    try ed.keymap.bind(gpa, "normal", "i", "enter-insert", core.Keymap.prio_config, "test");
    // A bare MOTION (no edit) — "cursor-right" is a real core builtin
    // (`core.builtins`' modeless `default`-floor binding, reused here) —
    // for exercising dot-repeat's "did this dispatch actually change
    // anything" distinction without needing any guest plugin.
    try ed.keymap.bind(gpa, "normal", "l", "cursor-right", core.Keymap.prio_config, "test");
    try ed.keymap.bind(gpa, "insert", "Escape", "enter-normal", core.Keymap.prio_config, "test");
    try ed.keymap.setTextCommand(gpa, "insert", "insert-text");
    try ed.head.setModeRaw(gpa, "normal");
}

test "two heads: A mid-chord does not touch B's mode/pending, and B types in insert" {
    const gpa = t.allocator;
    var ed: Editor = undefined;
    try Editor.init(gpa, &ed);
    defer ed.deinit();
    try initModal(gpa, &ed);

    // A leader chord, bound the way a real config would (SPC f f) — the
    // point is proving CHORD isolation, not any particular command.
    _ = try ed.commands.bind(gpa, "noop", .{ .name = "noop", .summary = "test: no-op", .args = &.{}, .handler = noop });
    try ed.keymap.bind(gpa, "normal", "space f f", "noop", core.Keymap.prio_config, "test");

    var b: SecondHead = undefined;
    try b.init(&ed, "insert"); // a second head attaching mid-session, already in insert
    defer b.deinit(gpa);

    // A: press SPC then f — a chord in progress (pending == "space f"),
    // still "normal" (unresolved, hasn't run a command yet).
    ed.press("space", "");
    ed.press("f", "");
    try t.expectEqualStrings("normal", ed.mode());
    try t.expectEqualStrings("space f", ed.head.pending);

    // B is entirely untouched: still "insert", no pending chord.
    try t.expectEqualStrings("insert", b.mode());
    try t.expectEqual(@as(usize, 0), b.head.pending.len);

    // B types — this dispatch resolves through B's OWN mode's text command
    // (insert-text), not A's half-typed chord.
    b.typeText("hello");
    const text1 = try ed.textAlloc();
    defer gpa.free(text1);
    try t.expect(std.mem.indexOf(u8, text1, "hello") != null);

    // A's chord survived B's keystrokes completely untouched.
    try t.expectEqualStrings("space f", ed.head.pending);
    try t.expectEqualStrings("normal", ed.mode());

    // Finish A's chord (SPC f f → the bound "noop") — resolves the pending
    // back to empty; B is still "insert" throughout.
    ed.press("f", "");
    try t.expectEqual(@as(usize, 0), ed.head.pending.len);
    try t.expectEqualStrings("insert", b.mode());
}

test "two heads: A in a menu mode does not move B out of normal" {
    const gpa = t.allocator;
    var ed: Editor = undefined;
    try Editor.init(gpa, &ed);
    defer ed.deinit();
    try ed.head.setModeRaw(gpa, "normal");

    // A magit-style special mode: locked (no text command — typing doesn't
    // fall through to self-insert) AND reachable as a one-shot menu, the
    // same shape `dispatch.dispatchSpec` gives any bound command whose name
    // NAMES a menu mode (see its "legacy mode-menu path" comment) — the
    // same mechanism a real magit-status keybinding uses.
    try ed.keymap.markMenuMode(gpa, "tool-mode");
    try ed.keymap.markLockedMode(gpa, "tool-mode");
    try ed.keymap.bind(gpa, "normal", "g", "tool-mode", core.Keymap.prio_config, "test");

    var b: SecondHead = undefined;
    try b.init(&ed, "normal");
    defer b.deinit(gpa);

    try t.expectEqualStrings("normal", ed.mode());
    try t.expectEqualStrings("normal", b.mode());

    // A enters the tool mode through a REAL keypress.
    ed.press("g", "");
    try t.expectEqualStrings("tool-mode", ed.mode());
    try t.expect(ed.keymap.isLockedMode(ed.mode()));
    try t.expectEqualStrings("normal", ed.head.menuReturn("tool-mode").?);

    // B never moved — still plain "normal", and it never recorded a menu
    // return target for "tool-mode" (it never entered it).
    try t.expectEqualStrings("normal", b.mode());
    try t.expectEqual(@as(?[]const u8, null), b.head.menuReturn("tool-mode"));

    // B can independently enter the SAME tool mode from ITS OWN normal —
    // proving the shared TABLE (the mode itself, its bindings) is genuinely
    // shared while the CURSOR into it (current mode, return target) is not.
    b.press("g", "");
    try t.expectEqualStrings("tool-mode", b.mode());
    try t.expectEqualStrings("normal", b.head.menuReturn("tool-mode").?);
    try t.expectEqualStrings("tool-mode", ed.mode()); // A is still there, unmoved by B's entry
}

test "two heads: distinct pick sessions — opening/typing in one doesn't touch the other" {
    const gpa = t.allocator;
    var ed: Editor = undefined;
    try Editor.init(gpa, &ed);
    defer ed.deinit();

    var b: SecondHead = undefined;
    try b.init(&ed, "default");
    defer b.deinit(gpa);

    // Both open the command palette — a real, builtin pick session (core
    // builtins install it; no plugin needed) — through the real command path.
    ed.run("palette");
    b.run("palette");
    try t.expect(ed.pick.active);
    try t.expect(b.head.pick.active);
    try t.expectEqualStrings("pick", ed.mode());
    try t.expectEqualStrings("pick", b.mode());

    // Typing dispatches through each head's OWN "pick" mode text command
    // (pick-input) into each head's OWN query — not the other's.
    ed.typeText("no");
    try t.expectEqualStrings("no", ed.pick.query.items);
    try t.expectEqual(@as(usize, 0), b.head.pick.query.items.len);

    b.typeText("y");
    try t.expectEqualStrings("y", b.head.pick.query.items);
    try t.expectEqualStrings("no", ed.pick.query.items); // untouched by B's typing

    // Closing A's picker leaves B's open.
    ed.run("pick-cancel");
    try t.expect(!ed.pick.active);
    try t.expect(b.head.pick.active);
    b.run("pick-cancel");
    try t.expect(!b.head.pick.active);
}

fn countChar(text: []const u8, ch: u8) usize {
    var n: usize = 0;
    for (text) |c| n += @intFromBool(c == ch);
    return n;
}

test "two heads: distinct dot-repeat registers — B's `.` never replays A's change" {
    const gpa = t.allocator;
    var ed: Editor = undefined;
    try Editor.init(gpa, &ed);
    defer ed.deinit();
    try initModal(gpa, &ed);
    _ = try ed.commands.bind(gpa, "repeat-change", .{ .name = "repeat-change", .summary = "test: repeat", .args = &.{}, .handler = h.dispatch.repeatChangeHandler });
    try ed.keymap.bind(gpa, "normal", ".", "repeat-change", core.Keymap.prio_config, "test");

    // Seed some prior edits/commits on A BEFORE B ever attaches — the exact
    // shape the two-head gap (`DotRepeat.synced`) exists for: a head that
    // attaches to a system already mid-session, not a virgin one.
    ed.press("i", "");
    ed.typeText("seed ");
    ed.press("Escape", "");

    var b: SecondHead = undefined;
    try b.init(&ed, "normal"); // attaches AFTER A already has commits
    defer b.deinit(gpa);

    // B's FIRST action after attaching: a BARE MOTION (no edit) — "l"
    // (cursor-right), not `.`. This is the exact scenario `DotRepeat.synced`
    // exists for: WITHOUT it, B's fresh-but-unsynced bookkeeping
    // (commits=0/cursor=0 defaults) misreads the gap since B's creation —
    // during which A already committed the "seed " edit above — as an
    // in-progress change, and wrongly promotes this single "l" keypress
    // into B's register. Assert the register stays EMPTY — this is the
    // assertion that fails if the `synced` gate is removed (verified by
    // fault injection; see the coordinator review response).
    b.press("l", "");
    try t.expectEqual(@as(usize, 0), b.head.dot.reg_n);

    // A's CHANGE: insert "A" and escape — recorded as A's dot register.
    // Assertions count characters (not exact text/position) so the test
    // doesn't depend on exactly where the shared cursor lands, only on
    // WHICH head's register a `.` press draws from — the actual point here.
    ed.press("i", "");
    ed.typeText("A");
    ed.press("Escape", "");
    {
        const text = try ed.textAlloc();
        defer gpa.free(text);
        try t.expectEqual(@as(usize, 1), countChar(text, 'A'));
    }

    // B's OWN register is empty (a fresh head never recorded a change) — its
    // `.` is a no-op. Before the per-head split, this replayed A's register
    // (the shared global one), inserting a second 'A' here.
    b.press(".", "");
    {
        const text = try ed.textAlloc();
        defer gpa.free(text);
        try t.expectEqual(@as(usize, 1), countChar(text, 'A')); // unchanged by B's no-op replay
    }

    // B now makes its OWN, DIFFERENT change: insert "B" and escape. B's
    // register now holds ITS OWN sequence — must not disturb A's.
    b.press("i", "");
    b.typeText("B");
    b.press("Escape", "");
    {
        const text = try ed.textAlloc();
        defer gpa.free(text);
        try t.expectEqual(@as(usize, 1), countChar(text, 'A'));
        try t.expectEqual(@as(usize, 1), countChar(text, 'B'));
    }

    // A's `.` still repeats A's ORIGINAL change (insert "A") — untouched by
    // B recording its own change in between.
    ed.press(".", "");
    {
        const text = try ed.textAlloc();
        defer gpa.free(text);
        try t.expectEqual(@as(usize, 2), countChar(text, 'A'));
        try t.expectEqual(@as(usize, 1), countChar(text, 'B')); // B's own edit, untouched by A's replay
    }
}

test "two heads: A closing its pane does not strand B on a freed/retyped node — B recovers and keeps dispatching" {
    const gpa = t.allocator;
    var ed: Editor = undefined;
    try Editor.init(gpa, &ed);
    defer ed.deinit();

    // A vsplits: left (A's pane, kept) | right (a new sibling peek).
    ed.run("window-vsplit");
    ed.applyWindow();
    try t.expectEqual(@as(usize, 2), ed.paneCount());

    var b: SecondHead = undefined;
    try b.init(&ed, "default");
    defer b.deinit(gpa);

    // Move B's focus onto the RIGHT (sibling) pane — a real window command,
    // applied explicitly AS head B (`SecondHead.applyWindow`) — so A and B
    // now hold handles to two DIFFERENT, sibling leaves of one shared tree.
    b.run("window-focus-right");
    b.applyWindow(&ed);

    // A closes ITS OWN (left) pane. `Layout.closeFocused`'s doc: this frees
    // TWO node addresses — the closed leaf (A's) AND its sibling's node
    // shell (B's pane's OLD address; the sibling's CONTENT survives, moved
    // to the parent's address, but that specific struct does not). B never
    // touched `window-close` — this is entirely A's action.
    ed.run("window-close");
    ed.applyWindow();
    try t.expectEqual(@as(usize, 1), ed.paneCount());

    // B's focus handle is now stale (its slot was retired by A's close).
    // `headFocus` is the single validation point: it must not dereference
    // the freed address — it recovers to a valid leaf (the sole survivor)
    // and re-homes B's handle there, asserted directly here (not just
    // inferred from "nothing crashed").
    const survivor = ed.win_layout.root; // per `closeFocused`'s shape: the parent (root, in a 2-leaf tree) becomes the surviving leaf in place
    try t.expectEqual(survivor, window_layout.headFocus(ed.win_layout, &b.head));

    // And B can keep dispatching real window commands from its RECOVERED
    // focus — no invalid access, no stuck state.
    b.run("window-vsplit");
    b.applyWindow(&ed);
    try t.expectEqual(@as(usize, 2), ed.paneCount());
}

test "two heads: distinct echo lines" {
    const gpa = t.allocator;
    var ed: Editor = undefined;
    try Editor.init(gpa, &ed);
    defer ed.deinit();

    var b: SecondHead = undefined;
    try b.init(&ed, "default");
    defer b.deinit(gpa);

    ed.head.echo.clearRetainingCapacity();
    ed.head.echo.appendSlice(gpa, "from A") catch unreachable;
    b.head.echo.clearRetainingCapacity();
    b.head.echo.appendSlice(gpa, "from B") catch unreachable;

    try t.expectEqualStrings("from A", ed.echoText());
    try t.expectEqualStrings("from B", b.echoText());
}

// ── Guest-ABI head addressing (task #14) — the gap this file's header used
// to report rather than patch. `headtest` (src/guest/headtest.zig) is a REAL
// wasm plugin, driven through the REAL `on_command`/`on_poll` trampolines —
// not a synthetic stand-in for them. ──────────────────────────────────────

test "two heads: a guest-plugin (wasm) command dispatched as B mutates B's Head, not A's" {
    const gpa = t.allocator;
    var ed: Editor = undefined;
    try Editor.init(gpa, &ed);
    defer ed.deinit();
    try h.loadHeadtest(&ed);

    var b: SecondHead = undefined;
    try b.init(&ed, "default");
    defer b.deinit(gpa);

    try t.expectEqualStrings("default", ed.mode());
    try t.expectEqualStrings("default", b.mode());

    // "head-poke" (weft.setMode + weft.echo) dispatched "as" B.
    b.run("head-poke");

    // B mutated: both writes landed on B's Head.
    try t.expectEqualStrings("poked", b.mode());
    try t.expectEqualStrings("poked", b.echoText());

    // A untouched. THE FIX: before it, a guest command (any real vim/helix/
    // emacs keybinding — weft.setMode/weft.edit/etc.) dispatched "as" a
    // second head silently acted on the plugin's LOAD-TIME ctx (head A)
    // instead — `wpCmdTrampoline` discarded the dispatching `ctx` entirely.
    try t.expectEqualStrings("default", ed.mode());
    try t.expectEqual(@as(usize, 0), ed.head.echo.items.len);
}

test "two heads: a wl_run-nested guest command keeps the dispatching head through the nesting" {
    const gpa = t.allocator;
    var ed: Editor = undefined;
    try Editor.init(gpa, &ed);
    defer ed.deinit();
    try h.loadHeadtest(&ed);

    var b: SecondHead = undefined;
    try b.init(&ed, "default");
    defer b.deinit(gpa);

    // "head-relay": wl_run("head-poke") (a nested, in-guest reentrant
    // dispatch through THIS SAME plugin) then a SECOND weft.echo write AFTER
    // the nested call returns. Both the nested call's writes and the outer
    // handler's post-nesting write must land on B throughout — this is what
    // fails under a "reset active_ctx to the load-time default as soon as a
    // nested dispatch returns" bug (a bare set instead of save/restore):
    // the post-nesting echo would land back on A instead.
    b.run("head-relay");

    try t.expectEqualStrings("poked", b.mode()); // set by the NESTED head-poke
    try t.expectEqualStrings("after-relay", b.echoText()); // written AFTER the nested call returned — still B

    // A never touched, at any point in the nesting.
    try t.expectEqualStrings("default", ed.mode());
    try t.expectEqual(@as(usize, 0), ed.head.echo.items.len);
}

test "two heads: on_poll (background) can no longer force a mode or echo onto ANY head (task #19 item 4)" {
    const gpa = t.allocator;
    var ed: Editor = undefined;
    try Editor.init(gpa, &ed);
    defer ed.deinit();
    try h.loadHeadtest(&ed);

    var b: SecondHead = undefined;
    try b.init(&ed, "default");
    defer b.deinit(gpa);

    // B is "the last-dispatching head": it dispatches head-poke (so its
    // mode/echo are visibly different from A's default) and head-spawn
    // (perm proc; spawns a real subprocess so a REAL readiness-driven
    // on_poll fires off the frame-loop tick, not a synthetic direct export
    // call).
    b.run("head-poke");
    b.run("head-spawn");
    try t.expectEqualStrings("poked", b.mode());
    try t.expectEqualStrings("default", ed.mode()); // A untouched by B's dispatches

    // Drive the async loop for real until on_poll has fired at least once —
    // observed via `head-poll-count` (a command result, not a head mutation:
    // on_poll's OWN head-touching writes are exactly what this test proves
    // no longer take effect, so the loop can't key off them the way the
    // pre-item-4 version of this test did). Bounded, generous — a plain
    // `echo hi` subprocess is fast.
    var round: usize = 0;
    while (round < 200) : (round += 1) {
        ed.settle(1);
        if (runInt(&ed, "head-poll-count") != 0) break;
    }
    try t.expect(runInt(&ed, "head-poll-count") >= 1); // on_poll really did fire

    // BEFORE task #19 item 4: on_poll's `weft.setMode("polled")`/
    // `weft.echo("polled")` silently landed on A (the load-time/system-
    // default ctx) even though B was the last head to dispatch anything —
    // `wasm_host/commands.zig`'s classification doc NAMED this gap without
    // closing it (`ctx.zig`'s "BACKGROUND CODE CANNOT" doc block). NOW:
    // `wl_set_mode` traps inside `on_poll` (`requireDispatch`,
    // `wasm_host/plugin.zig`) — the guest call unwinds right there, so the
    // `weft.echo` right after it never runs either. Neither head moves.
    try t.expectEqualStrings("default", ed.mode()); // A: never touched, was "polled" before this fix
    try t.expectEqual(@as(usize, 0), ed.head.echo.items.len);
    // B, meanwhile, is untouched by the background entry either way — still
    // exactly where its own last dispatch (head-poke) left it.
    try t.expectEqualStrings("poked", b.mode());
    try t.expectEqualStrings("poked", b.echoText());
}
