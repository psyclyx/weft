//! e2e test file — drives the shared harness (harness.zig) as a user and
//! observes the surface + disk. The alias block pulls what these tests need from
//! the one harness module; unused aliases are harmless at container scope.

const std = @import("std");
const t = std.testing;
const h = @import("harness.zig");

const core = h.core;
const session = h.session;
const region = h.region;
const window_layout = h.window_layout;
const harness = h.gfx_harness;
const app_providers = h.app_providers;
const app_session = h.app_session;
const app_collab = h.app_collab;

const Editor = h.Editor;
const Loopback = h.Loopback;
const Project = h.Project;
const ConfigLoader = h.ConfigLoader;
const app_w = h.app_w;

const loadVim = h.loadVim;
const loadWorkspace = h.loadWorkspace;
const loadWebIde = h.loadWebIde;
const bootConfig = h.bootConfig;
const whichKeyText = h.whichKeyText;
const whichKeyShows = h.whichKeyShows;
const authorFile = h.authorFile;
const toolText = h.toolText;
const drainToolContains = h.drainToolContains;
const drainUntilOracle = h.drainUntilOracle;
const tmpPath = h.tmpPath;
const socketPair = h.socketPair;
const napUs = h.napUs;

test "workflow: vim — insert text, escape, and it lands in the buffer" {
    const gpa = t.allocator;
    var ed: Editor = undefined;
    try Editor.init(gpa, &ed);
    defer ed.deinit();
    try loadVim(&ed);

    // vim starts in normal. The natural way to type is: i, then the text, Esc.
    try t.expectEqualStrings("normal", ed.mode());
    ed.press("i", ""); // enter insert
    try t.expectEqualStrings("insert", ed.mode());
    ed.typeText("hello weft");
    ed.press("Escape", "");
    try t.expectEqualStrings("normal", ed.mode());

    const got = try ed.textAlloc();
    defer gpa.free(got);
    try t.expectEqualStrings("hello weft", got);
    ed.snapshot("vim-insert");
}

test "workflow: vim — dw deletes a word (operator + motion compose)" {
    const gpa = t.allocator;
    var ed: Editor = undefined;
    try Editor.init(gpa, &ed);
    defer ed.deinit();
    try loadVim(&ed);

    ed.press("i", "");
    ed.typeText("alpha bravo charlie");
    ed.press("Escape", "");
    // Back to the start of the line, then delete the first word with `dw`.
    ed.press("0", ""); // motion.line-start (via vim/n/*)
    ed.press("d", ""); // enter operator-pending
    ed.press("w", ""); // word motion → op.delete applies
    const got = try ed.textAlloc();
    defer gpa.free(got);
    // "alpha " is gone (the word + its trailing space, vim `dw`).
    try t.expect(std.mem.startsWith(u8, got, "bravo"));
}

test "workflow: autopair — typing an open paren inserts the matched pair" {
    const gpa = t.allocator;
    var ed: Editor = undefined;
    try Editor.init(gpa, &ed);
    defer ed.deinit();
    try loadVim(&ed);
    // The natural way: bind the pair keys (a config would). Then in insert, `(`
    // is a bound key (not plain text) → the pair is inserted, caret between.
    try ed.keymap.bind(gpa, "insert", "parenleft", "pair-paren", core.Keymap.prio_config, "test");

    ed.press("i", "");
    ed.press("parenleft", "("); // bound → pair-paren, not literal text
    const got = try ed.textAlloc();
    defer gpa.free(got);
    try t.expectEqualStrings("()", got);
}

test "workflow: vim — x deletes the char under the cursor" {
    const gpa = t.allocator;
    var ed: Editor = undefined;
    try Editor.init(gpa, &ed);
    defer ed.deinit();
    try loadVim(&ed);
    ed.press("i", "");
    ed.typeText("abc");
    ed.press("Escape", "");
    ed.press("0", ""); // to line start
    ed.press("x", ""); // delete-forward
    const got = try ed.textAlloc();
    defer gpa.free(got);
    try t.expectEqualStrings("bc", got);
}

test "workflow: vim — o opens a line below and enters insert" {
    const gpa = t.allocator;
    var ed: Editor = undefined;
    try Editor.init(gpa, &ed);
    defer ed.deinit();
    try loadVim(&ed);
    ed.press("i", "");
    ed.typeText("one");
    ed.press("Escape", "");
    ed.press("o", ""); // open below → insert
    try t.expectEqualStrings("insert", ed.mode());
    ed.typeText("two");
    ed.press("Escape", "");
    const got = try ed.textAlloc();
    defer gpa.free(got);
    try t.expectEqualStrings("one\ntwo", got);
}

test "workflow: vim — u undoes the last insert as one unit" {
    const gpa = t.allocator;
    var ed: Editor = undefined;
    try Editor.init(gpa, &ed);
    defer ed.deinit();
    try loadVim(&ed);
    ed.press("i", "");
    ed.typeText("scratch");
    ed.press("Escape", "");
    ed.press("u", ""); // undo the whole insert
    const got = try ed.textAlloc();
    defer gpa.free(got);
    try t.expectEqualStrings("", got);
}

test "workflow: vim — undo after dw undoes the dw, not the typing" {
    const gpa = t.allocator;
    var ed: Editor = undefined;
    try Editor.init(gpa, &ed);
    defer ed.deinit();
    try loadVim(&ed);
    ed.press("i", "");
    ed.typeText("foo bar baz");
    ed.press("Escape", "");
    ed.press("0", ""); // line start
    ed.press("d", "");
    ed.press("w", ""); // dw deletes "foo "
    {
        const after = try ed.textAlloc();
        defer gpa.free(after);
        try t.expectEqualStrings("bar baz", after);
    }
    // The dw is applied by the operators PLUGIN, but you initiated it — so it
    // joins YOUR undo history. Undo must restore "foo ", not undo the typing.
    ed.press("u", "");
    const undone = try ed.textAlloc();
    defer gpa.free(undone);
    try t.expectEqualStrings("foo bar baz", undone);
}

test "workflow: vim — Y yanks a line, p pastes it below" {
    const gpa = t.allocator;
    var ed: Editor = undefined;
    try Editor.init(gpa, &ed);
    defer ed.deinit();
    try loadVim(&ed);
    ed.press("i", "");
    ed.typeText("line");
    ed.press("Escape", "");
    ed.press("Y", ""); // yank-line
    ed.press("p", ""); // paste below
    const got = try ed.textAlloc();
    defer gpa.free(got);
    try t.expectEqualStrings("line\nline", got);
}

test "workflow: vim — cw changes a word then re-inserts" {
    const gpa = t.allocator;
    var ed: Editor = undefined;
    try Editor.init(gpa, &ed);
    defer ed.deinit();
    try loadVim(&ed);
    ed.press("i", "");
    ed.typeText("foo bar");
    ed.press("Escape", "");
    ed.press("0", "");
    ed.press("c", ""); // enter operator-change
    ed.press("w", ""); // word → change; lands in insert
    try t.expectEqualStrings("insert", ed.mode());
    ed.typeText("baz");
    ed.press("Escape", "");
    const got = try ed.textAlloc();
    defer gpa.free(got);
    // "foo" became "baz"; "bar" survives (cw doesn't eat the trailing space).
    try t.expect(std.mem.startsWith(u8, got, "baz"));
    try t.expect(std.mem.indexOf(u8, got, "bar") != null);
}

test "workflow: modes — opening a file detects its language on activate, without touching the head (task #19 item 4)" {
    const gpa = t.allocator;
    var ed: Editor = undefined;
    try Editor.init(gpa, &ed);
    defer ed.deinit();
    try loadWorkspace(&ed);

    // The natural way to "work on a zig file" is to open it. modes' on_activate
    // fires (harness mirrors main) and detects the language — it no longer
    // echoes it, though: `on_activate` is BACKGROUND (no per-call dispatching
    // head — see `wasm_host/commands.zig`'s classification doc) and `wl_echo`
    // is head-gated (task #19 item 4), so `src/guest/modes.zig` downgraded
    // this to `weft.log` (still observable in the process log, just not the
    // editor's echo line). What this test asserts instead is the structural
    // guarantee: opening a file never lands language text on `ed.echoText()`
    // via this path, for either extension.
    ed.runStr("open", "/tmp/weft-nonexistent-main.zig");
    try t.expect(std.mem.indexOf(u8, ed.echoText(), "zig") == null);

    ed.runStr("open", "/tmp/weft-nonexistent-app.js");
    try t.expect(std.mem.indexOf(u8, ed.echoText(), "javascript") == null);
}
