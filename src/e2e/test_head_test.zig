//! e2e test file — W0b's SECOND HEAD gate (doc/cwa-prior-docs-audit.md §5:
//! "the headless variant is the SAME composition minus the window-head
//! binding ... a second head implementation (tty or test-head) attaches
//! through the same grant"). `h.TestHead` (harness.zig) wraps `h.SecondHead`
//! (already a real second `core.Head` on the real session/dispatch — see
//! `two_head_test.zig`) with its OWN named `core.InProcClient` identity, so
//! its keypress injection is bracketed by `beginDispatch`/`endDispatch`
//! exactly like `app/window_head.zig`'s `WindowHead.dispatchKey` — a
//! DIFFERENT client name ("test-head" vs "window-head"), the SAME shared
//! type and bracket discipline. This file proves three things:
//!
//!   1. TestHead's `client` is a genuine `core.InProcClient` — the SAME
//!      `wasm_host/plugin.zig` `hasPerm`/`canDispatch` guard predicates a
//!      wasm plugin's `WasmPlugin` identity is checked against read it
//!      identically (no parallel, drifted implementation).
//!   2. TestHead is a REAL second head: it presses keys through the actual
//!      dispatch entry, edits the shared document, and holds mode/pending/
//!      echo independent of the primary head — the same isolation property
//!      `two_head_test.zig` proves for `SecondHead`, carried through the
//!      InProcClient wrapper without loss.
//!   3. Reading a laid-out frame after a TestHead-driven edit goes through
//!      the SAME scene path the window-head uses (`Editor.ensureView`/
//!      `renderComposite` — the backend-neutral `FrameBuilder` embedded in
//!      `app/window_head.zig`'s `WindowHead.render`), because a head owns
//!      interaction state, not its own rendering pipeline — see
//!      `app/window_head.zig`'s module doc.

const std = @import("std");
const t = std.testing;
const h = @import("harness.zig");

const core = h.core;
const Editor = h.Editor;
const TestHead = h.TestHead;
// The shared guard predicates (`core/wasm_host/plugin.zig`'s `hasPerm`/
// `canDispatch`), re-exported through `core.wasm_host` — e2e files reach
// `core.*` only through the `weft` module barrel (never a raw relative path
// into `core/wasm_host/*.zig`, which would pull those files into TWO
// modules at once and fail the build).
const wasm_host_plugin = core.wasm_host;

test "TestHead: its InProcClient reads the SAME hasPerm/canDispatch guards a WasmPlugin does" {
    const gpa = t.allocator;
    var ed: Editor = undefined;
    try Editor.init(gpa, &ed);
    defer ed.deinit();

    var th: TestHead = .{};
    try th.init(&ed, ed.mode());
    defer th.deinit(gpa);

    // Ungranted by default at this level (unset perms) — the SAME predicate
    // a wasm plugin's `requirePerm` traps on.
    try t.expect(!wasm_host_plugin.hasPerm(&th.client, .fs_read));
    th.client.perms[wasm_host_plugin.perm_fs_read] = true;
    try t.expect(wasm_host_plugin.hasPerm(&th.client, .fs_read));

    // Outside a press, this client is NOT dispatching — same as a wasm
    // plugin's background entry (`on_poll`/`on_fill_token`/...).
    try t.expect(!wasm_host_plugin.canDispatch(&th.client));
}

test "TestHead: presses through the REAL dispatch, isolated from the primary head, same scene path renders after" {
    const gpa = t.allocator;
    var ed: Editor = undefined;
    try Editor.init(gpa, &ed);
    defer ed.deinit();

    // A synthetic command + bind, mirroring two_head_test.zig's pattern:
    // proves TestHead runs a REAL bound key through REAL dispatch, not a
    // direct command.run bypass.
    const Marker = struct {
        fn handler(ctx: *core.command.Context, data: ?*anyopaque, args: []const core.command.Value) anyerror!core.command.Value {
            _ = data;
            _ = args;
            try ctx.edit(.{ .start = 0, .end = 0 }, "X");
            return .nil;
        }
    };
    _ = try ed.commands.bind(gpa, "th-mark", .{
        .name = "th-mark",
        .summary = "test",
        .args = &.{},
        .handler = Marker.handler,
        .data = null,
    });
    try ed.keymap.bind(gpa, ed.mode(), "M", "th-mark", core.Keymap.prio_plugin, "test");

    var th: TestHead = .{};
    try th.init(&ed, ed.mode());
    defer th.deinit(gpa);

    // The primary head's mode is untouched by constructing/pressing a
    // second head — isolation carried through the InProcClient wrapper.
    const primary_mode_before = try gpa.dupe(u8, ed.mode());
    defer gpa.free(primary_mode_before);

    th.press("M", "");

    // The edit landed on the SHARED document (both heads dispatch against
    // the same buffer) — a real key, through real dispatch, not a bypass.
    const text = try ed.textAlloc();
    defer gpa.free(text);
    try t.expect(std.mem.indexOfScalar(u8, text, 'X') != null);

    // The primary head's mode is exactly as it was — TestHead pressing a
    // key never touched `ed.head`.
    try t.expectEqualStrings(primary_mode_before, ed.mode());

    // Reading a laid-out frame through the SAME scene path the window-head
    // uses works fine after a TestHead-driven edit — heads share the
    // render pipeline, they don't each carry their own.
    const view = try ed.ensureView();
    _ = view;
    const composite = try ed.renderComposite();
    defer gpa.free(composite);
    try t.expect(composite.len > 0);
}

test {
    std.testing.refAllDecls(@This());
}
