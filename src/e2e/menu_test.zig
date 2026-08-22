//! e2e test file — task #19 item 2: the paired-transient mechanism
//! (`core/ctx.zig`'s `Ctx.pushTransient`/`TransientHandle`, `core/Head.zig`'s
//! `transient_stack`) wired into `dispatch.zig`'s REAL production menu-enter/
//! menu-return path. Drives a minimal synthetic keymap through the shared
//! headless harness — mirrors `two_head_test.zig`'s `initModal` (no plugin
//! needed; the point is `dispatch.zig` + `core.Head`, not any particular
//! guest config) — through the SAME shape `dispatch.zig`'s `.run` branch
//! gives any real bound command whose name IS a declared menu mode (the
//! actual production example: `src/guest/git.zig`'s
//! `weft.bindKey("magit", "c", "git-commit-dispatch")`, exercised end to end
//! by `project_test.zig`'s "write a file, init a repo, stage and commit"
//! spine test — unmodified by this migration, still green).

const std = @import("std");
const t = std.testing;
const h = @import("harness.zig");

const core = h.core;
const command = core.command;
const Editor = h.Editor;

fn noop(ctx: *command.Context, data: ?*anyopaque, args: []const command.Value) anyerror!command.Value {
    _ = ctx;
    _ = data;
    _ = args;
    return .nil;
}

/// A "normal" resting mode plus one auto-entered menu (`test-menu`, leaf
/// `x`) — the minimal shape dispatch's own menu-enter branch needs: a
/// bound key whose command name IS a declared menu mode.
fn initMenuKeymap(gpa: std.mem.Allocator, ed: *Editor) !void {
    _ = try ed.commands.bind(gpa, "test-leaf", .{ .name = "test-leaf", .summary = "test: no-op leaf", .args = &.{}, .handler = noop });
    try ed.keymap.markMenuMode(gpa, "test-menu");
    try ed.keymap.bind(gpa, "normal", "m", "test-menu", core.Keymap.prio_config, "test");
    try ed.keymap.bind(gpa, "test-menu", "x", "test-leaf", core.Keymap.prio_config, "test");
    ed.setMode("normal");
}

test "menu: enter -> leaf -> auto-pop through REAL dispatch is a paired-transient push/pop" {
    const gpa = t.allocator;
    var ed: Editor = undefined;
    try Editor.init(gpa, &ed);
    defer ed.deinit();
    try initMenuKeymap(gpa, &ed);

    try t.expect(!ed.head.hasOpenTransients());
    ed.press("m", "");
    try t.expectEqualStrings("test-menu", ed.mode());
    try t.expect(ed.head.hasOpenTransients());
    try t.expectEqual(@as(usize, 1), ed.head.transient_stack.items.len);
    try t.expectEqualStrings("test-menu", ed.head.transient_stack.items[0].mode);
    try t.expectEqualStrings("normal", ed.head.transient_stack.items[0].return_to);
    // The paired stack is ADDITIVE, not a replacement of `menu_return` —
    // `pushTransientMode` still routes through `Head.enterMode`, so the
    // legacy table (still load-bearing for guest-entered menus; see
    // ctx.zig's module doc) records this too.
    try t.expectEqualStrings("normal", ed.head.menuReturn("test-menu").?);

    ed.press("x", ""); // the leaf — non-sticky, mode unchanged -> auto-pop
    try t.expectEqualStrings("normal", ed.mode());
    try t.expect(!ed.head.hasOpenTransients());
}

test "menu: menu-escape pops through the paired mechanism" {
    const gpa = t.allocator;
    var ed: Editor = undefined;
    try Editor.init(gpa, &ed);
    defer ed.deinit();
    try initMenuKeymap(gpa, &ed);

    // menu-escape only exists as a command if bound; call the handler
    // directly (the same way the GLOBAL layer binds Escape/C-g in a real
    // config — see dispatch.zig's module doc).
    _ = try ed.commands.bind(gpa, "menu-escape", .{ .name = "menu-escape", .summary = "test", .args = &.{}, .handler = h.dispatch.menuEscapeHandler });

    ed.press("m", "");
    try t.expectEqualStrings("test-menu", ed.mode());
    try t.expect(ed.head.hasOpenTransients());

    ed.run("menu-escape");
    try t.expectEqualStrings("normal", ed.mode());
    try t.expect(!ed.head.hasOpenTransients());

    // Outside a menu, menu-escape is a no-op (never forces a mode change —
    // dispatch.zig's module doc: the "wrong mode in a tool buffer" jank).
    ed.run("menu-escape");
    try t.expectEqualStrings("normal", ed.mode());
}

test "menu: sticky re-enter is NOT a second push; a sticky leaf leaves the menu open" {
    const gpa = t.allocator;
    var ed: Editor = undefined;
    try Editor.init(gpa, &ed);
    defer ed.deinit();
    try initMenuKeymap(gpa, &ed);
    _ = try ed.commands.bind(gpa, "menu-escape", .{ .name = "menu-escape", .summary = "test", .args = &.{}, .handler = h.dispatch.menuEscapeHandler });

    try ed.keymap.markStickyMenu(gpa, "sticky-menu");
    try ed.keymap.bind(gpa, "normal", "p", "sticky-menu", core.Keymap.prio_config, "test");
    // Re-entry key, bound WITHIN the sticky menu to ITSELF — the shape a
    // config binding the same leader key inside its own menu would take.
    try ed.keymap.bind(gpa, "sticky-menu", "p", "sticky-menu", core.Keymap.prio_config, "test");
    try ed.keymap.bind(gpa, "sticky-menu", "x", "test-leaf", core.Keymap.prio_config, "test");

    ed.press("p", "");
    try t.expectEqualStrings("sticky-menu", ed.mode());
    try t.expectEqual(@as(usize, 1), ed.head.transient_stack.items.len);

    // Re-entering the SAME menu we're already in must not grow the stack.
    ed.press("p", "");
    try t.expectEqualStrings("sticky-menu", ed.mode());
    try t.expectEqual(@as(usize, 1), ed.head.transient_stack.items.len);

    // A leaf inside a STICKY menu does not auto-pop (flags accumulate).
    ed.press("x", "");
    try t.expectEqualStrings("sticky-menu", ed.mode());
    try t.expectEqual(@as(usize, 1), ed.head.transient_stack.items.len);

    // Only an explicit leave (menu-escape, here) pops it — through the SAME
    // paired mechanism as a plain menu.
    ed.run("menu-escape");
    try t.expectEqualStrings("normal", ed.mode());
    try t.expect(!ed.head.hasOpenTransients());
}

test "menu: nested auto-entered menus pop LIFO (single hop) through the paired stack" {
    const gpa = t.allocator;
    var ed: Editor = undefined;
    try Editor.init(gpa, &ed);
    defer ed.deinit();
    try initMenuKeymap(gpa, &ed);
    _ = try ed.commands.bind(gpa, "menu-escape", .{ .name = "menu-escape", .summary = "test", .args = &.{}, .handler = h.dispatch.menuEscapeHandler });

    // A menu entered FROM another dispatch-auto-entered menu — a shape no
    // REAL production config currently uses (every real markMenuMode/
    // bindKey pair audited for this migration enters from a plain editing
    // mode, never from another menu — the leader tree is SEQUENCES within
    // one mode, not nested prefix MODES; see Head.zig's own test doc), but
    // the mechanism must still behave honestly if one ever does. The
    // paired-transient stack pops LIFO, ONE hop at a time (menu-b -> menu-a
    // -> normal) — NOT `Head.enterMode`'s "chain of menus collapses to a
    // single hop to the root" behavior (see its doc), which only ever
    // applied to `menu_return` (still true for a guest-entered chain, out
    // of this pass's scope). Since no real nested case exists today, there
    // is no legacy single-key-press-jumps-to-root behavior this could
    // regress — this is a fresh, honestly-documented decision, not a
    // preserved one.
    try ed.keymap.markMenuMode(gpa, "menu-a");
    try ed.keymap.markMenuMode(gpa, "menu-b");
    try ed.keymap.bind(gpa, "normal", "a", "menu-a", core.Keymap.prio_config, "test");
    try ed.keymap.bind(gpa, "menu-a", "b", "menu-b", core.Keymap.prio_config, "test");

    ed.press("a", "");
    try t.expectEqualStrings("menu-a", ed.mode());
    try t.expectEqual(@as(usize, 1), ed.head.transient_stack.items.len);

    ed.press("b", "");
    try t.expectEqualStrings("menu-b", ed.mode());
    try t.expectEqual(@as(usize, 2), ed.head.transient_stack.items.len);
    try t.expectEqualStrings("menu-a", ed.head.transient_stack.items[0].mode);
    try t.expectEqualStrings("normal", ed.head.transient_stack.items[0].return_to);
    try t.expectEqualStrings("menu-b", ed.head.transient_stack.items[1].mode);
    try t.expectEqualStrings("menu-a", ed.head.transient_stack.items[1].return_to);

    ed.run("menu-escape"); // one hop: menu-b -> menu-a (not straight to normal)
    try t.expectEqualStrings("menu-a", ed.mode());
    try t.expectEqual(@as(usize, 1), ed.head.transient_stack.items.len);

    ed.run("menu-escape"); // menu-a -> normal
    try t.expectEqualStrings("normal", ed.mode());
    try t.expect(!ed.head.hasOpenTransients());
}

test "menu: a leaf's own buffer switch mid-menu drops the transient stack, matching legacy's plain overwrite" {
    const gpa = t.allocator;
    var ed: Editor = undefined;
    try Editor.init(gpa, &ed);
    defer ed.deinit();
    try initMenuKeymap(gpa, &ed);

    // A second buffer with its OWN resting mode, and a leaf command bound
    // INSIDE `test-menu` that switches to it directly — the same shape
    // `src/guest/git.zig`'s `git-commit-dispatch` -> `git-commit` leaf takes
    // (opens/focuses a different buffer without going through `menu-escape`
    // or an auto-pop). `Buffers.switchTo` bypasses the keymap dispatch site
    // entirely (its own doc) — legacy just overwrote `head.mode`; the
    // question this test answers is whether the NEW transient stack is left
    // dangling by that bypass (a leak) or dropped (matching legacy's own
    // "just overwrites, nothing to restore" behavior).
    const other_id = try ed.buffers.create(gpa, "*other*");
    const other = ed.buffers.get(other_id).?;
    gpa.free(other.mode);
    other.mode = try gpa.dupe(u8, "other-mode");

    const SwitchCmd = struct {
        fn run(ctx: *command.Context, data: ?*anyopaque, args: []const command.Value) anyerror!command.Value {
            _ = args;
            const id: *const core.Buffers.Id = @ptrCast(@alignCast(data.?));
            ctx.buffers.switchTo(ctx.gpa, id.*, ctx.head, ctx.keymap) catch {};
            return .nil;
        }
    };
    var target_id = other_id;
    _ = try ed.commands.bind(gpa, "test-switch-buf", .{ .name = "test-switch-buf", .summary = "test", .args = &.{}, .handler = SwitchCmd.run, .data = &target_id });
    try ed.keymap.bind(gpa, "test-menu", "b", "test-switch-buf", core.Keymap.prio_config, "test");

    ed.press("m", "");
    try t.expectEqualStrings("test-menu", ed.mode());
    try t.expect(ed.head.hasOpenTransients());

    ed.press("b", "");
    try t.expectEqualStrings("other-mode", ed.mode()); // the NEW buffer's own mode
    try t.expect(!ed.head.hasOpenTransients()); // dropped, not orphaned
}

test "menu: F3 — Ctx.capture's mode scope agrees with the open transient's top frame" {
    const gpa = t.allocator;
    var ed: Editor = undefined;
    try Editor.init(gpa, &ed);
    defer ed.deinit();
    try initMenuKeymap(gpa, &ed);

    ed.press("m", "");
    try t.expect(ed.head.hasOpenTransients());

    const c = core.ctx.Ctx.capture(ed.ctx);
    // 6 fixed scopes + 1 open transient (ctx.zig's `max_fixed_scopes`).
    try t.expectEqual(@as(usize, 7), c.scopes.len);
    // The `mode` scope (index 5, `ScopeKind.mode`) reads `Head.currentMode()`
    // directly; the trailing `transient` scope (index 6) reads the SAME
    // frame's `mode` field. F3 (resolved, task #19 item 2): these agree BY
    // CONSTRUCTION, checked by a debug assertion in `Ctx.capture` itself —
    // this test demonstrates the value-level agreement the assertion
    // guards.
    try t.expectEqualStrings("test-menu", c.scopes.get(5).facts.mode);
    try t.expectEqualStrings("test-menu", c.scopes.get(6).facts.mode);
    try t.expectEqualStrings("test-menu", c.mergedFacts().mode);
}

test "menu: fault injection — an unpaired push is caught by the interaction-boundary tripwire" {
    const gpa = t.allocator;
    var ed: Editor = undefined;
    try Editor.init(gpa, &ed);
    defer ed.deinit();
    try initMenuKeymap(gpa, &ed);

    // Push a transient the HONEST way (through the real mechanism)...
    const c = core.ctx.Ctx.capture(ed.ctx);
    _ = try c.pushTransient(ed.keymap, "test-menu");
    try t.expect(ed.head.hasOpenTransients());
    try t.expectEqualStrings("test-menu", ed.mode());

    // ...then simulate the ONE way this can still go wrong: some call site
    // that has never adopted the "drop the stack before a raw overwrite"
    // discipline `Buffers.switchTo`/`Pick.openWith` now follow stomps
    // `head.mode` directly, deliberately never popping — the exact "menu-
    // mode leaks" bug class `ctx.zig`'s "Paired transients" doc names.
    // Deliberately the RAW mechanism entry, not the door — this line IS the
    // bug being fault-injected (task #19 item 3: `Head.setModeRaw` is
    // exactly the escape hatch a reviewer should treat with suspicion
    // outside the enumerated mechanism sites).
    ed.head.setModeRaw(gpa, "normal") catch unreachable;
    try t.expect(ed.head.hasOpenTransients()); // leaked: mode moved, stack didn't

    // The NEXT real keypress crosses `dispatchSpec`'s boundary. Press
    // something that leaves the mode NON-menu at that boundary too (an
    // unbound key — "z" is bound nowhere in this synthetic keymap, so it
    // falls through to a no-op text-insert attempt and mode stays
    // "normal") — the exact condition the tripwire (task #19 item 2)
    // checks: transients open, current mode not a menu. It fires (a loud
    // log; not asserted here, the recovery is) and pops everything, rather
    // than leaving the leak to silently corrupt whatever the NEXT menu
    // push/pop does.
    ed.press("z", "");
    try t.expectEqualStrings("normal", ed.mode()); // untouched otherwise
    try t.expect(!ed.head.hasOpenTransients()); // recovered

    // Proof the recovery left things genuinely usable, not just "empty":
    // a fresh, real menu entry right after works cleanly (one frame, not
    // stacked on top of the fault-injected one).
    ed.press("m", "");
    try t.expectEqualStrings("test-menu", ed.mode());
    try t.expectEqual(@as(usize, 1), ed.head.transient_stack.items.len);
}

test "menu: F3 reconcile — a leaf's own setMode-then-resolve mid-handler sees the LIVE mode, not the stale transient" {
    // Review send-back (blocking): the F3 assert used to fire here — a
    // menu-leaf handler is free to call `weft.setMode(X)` and then, still
    // inside the SAME handler (before dispatch.zig's own post-leaf pop/
    // discard-pop runs), capture again to resolve something (an action, a
    // capability). No shipped guest composes those two ordinary public
    // APIs today, but nothing prohibits it — exactly the gap this task
    // exists to close. `Ctx.capture` must (a) never crash on the
    // divergence and (b) resolve `.mode` against the LIVE mode `X`, not
    // the stale menu name the still-open transient frame recorded.
    const gpa = t.allocator;
    var ed: Editor = undefined;
    try Editor.init(gpa, &ed);
    defer ed.deinit();
    try initMenuKeymap(gpa, &ed);

    const Result = struct { mode_buf: [64]u8 = undefined, mode_len: usize = 0 };
    var result: Result = .{};

    // Mirrors a real guest leaf: `weft.setMode("leaf-target")` then
    // `weft.run(<some action>)` — modeled here as a second `Ctx.capture` +
    // `mergedFacts` resolution, the same mechanism an action/capability
    // lookup goes through — BOTH still inside this one handler call, before
    // control returns to `dispatchSpec`'s `.run` case.
    const SetModeThenResolve = struct {
        fn run(ctx: *command.Context, data: ?*anyopaque, args: []const command.Value) anyerror!command.Value {
            _ = args;
            const res: *Result = @ptrCast(@alignCast(data.?));
            // task #19 item 3: the guest's `weft.setMode(X)` now reaches
            // `Head` through the POLICY door too (`wasm_host/keymap.zig`'s
            // `hSetMode` captures its own `Ctx`) — modeled here the same way.
            // enterMode, mirroring hSetMode's production door exactly
            // (degenerates to setMode for a non-menu target like this one).
            try ctx.capturedCtx().enterMode(ctx.keymap, "leaf-target"); // the guest's weft.setMode(X)
            const c = core.ctx.Ctx.capture(ctx); // the guest's weft.run(<action>) resolving facts
            const mode = c.mergedFacts().mode;
            res.mode_len = @min(mode.len, res.mode_buf.len);
            @memcpy(res.mode_buf[0..res.mode_len], mode[0..res.mode_len]);
            return .nil;
        }
    };
    _ = try ed.commands.bind(gpa, "test-setmode-then-resolve", .{
        .name = "test-setmode-then-resolve",
        .summary = "test",
        .args = &.{},
        .handler = SetModeThenResolve.run,
        .data = &result,
    });
    try ed.keymap.bind(gpa, "test-menu", "y", "test-setmode-then-resolve", core.Keymap.prio_config, "test");

    ed.press("m", ""); // enter test-menu -> the transient push
    try t.expect(ed.head.hasOpenTransients());
    try t.expectEqualStrings("test-menu", ed.head.transient_stack.items[ed.head.transient_stack.items.len - 1].mode);

    // The leaf: setMode("leaf-target") then capture+resolve, BOTH still
    // mid-handler. No crash reaching this line is itself part of the
    // assertion (a ReleaseSafe `std.debug.assert` divergence would have
    // aborted the whole test binary, not merely failed an `expect`).
    ed.press("y", "");

    // The resolution saw the LIVE mode ("leaf-target"), never the stale
    // transient's "test-menu" — even though, AT THE MOMENT OF CAPTURE, the
    // transient stack's top frame still recorded "test-menu" (the pop
    // hasn't run yet; dispatch.zig's post-leaf handling below still has
    // this OLD `menu_before` to reconcile).
    try t.expectEqualStrings("leaf-target", result.mode_buf[0..result.mode_len]);

    // Back at the dispatch boundary (the leaf has returned): mode diverged
    // from what the open transient named ("test-menu" != "leaf-target") —
    // dispatch.zig's "leaf moved us elsewhere" branch discard-pops the now
    // -stale frame (task #19 item 2) rather than leaking it, and does NOT
    // stomp the mode the leaf deliberately set.
    try t.expectEqualStrings("leaf-target", ed.mode());
    try t.expect(!ed.head.hasOpenTransients());
}
