//! The three core doors of doc/configs.md §2 phase 5 and §3.3, driven the way
//! a person drives them: the system clipboard behind vim's `"+`, the jumplist
//! behind C-o/C-i, and macros behind `q`/`@`. Every key goes through the one
//! dispatch path; the clipboard is the head's in-memory one (the headless
//! platform), which is the same door a desktop head's window backs.

const std = @import("std");
const t = std.testing;
const h = @import("harness.zig");

const core = h.core;
const Editor = h.Editor;
const Project = h.Project;
const ConfigLoader = h.ConfigLoader;
const loadVim = h.loadVim;
const bootConfig = h.bootConfig;
const authorFile = h.authorFile;

fn expectText(ed: *Editor, want: []const u8) !void {
    const got = try ed.textAlloc();
    defer ed.gpa.free(got);
    try t.expectEqualStrings(want, got);
}

fn pluginNamed(ed: *Editor, name: []const u8) ?*core.wasm_abi.WasmPlugin {
    for (ed.plugins.items) |p| if (std.mem.eql(u8, p.name, name)) return p;
    return null;
}

fn cursor(ed: *Editor) usize {
    return ed.buffers.active().textEditor().?.cursorOffset();
}

/// `"+` then an operator key sequence.
fn clip(ed: *Editor, keys: []const u8) void {
    ed.press("quotedbl", "");
    ed.press("plus", "");
    ed.chord(keys);
}

// ── Clipboard ─────────────────────────────────────────────────────────

test "e2e/clipboard: vim's \"+ yanks into the head's clipboard and pastes from it" {
    const gpa = t.allocator;
    var ed: Editor = undefined;
    try Editor.init(gpa, &ed);
    defer ed.deinit();
    try ed.grant("vim", "clipboard"); // what config.js writes down
    try loadVim(&ed);
    try t.expect(core.wasm_host.hasPerm(pluginNamed(&ed, "vim").?, .clipboard));

    ed.press("i", "");
    ed.typeText("one\ntwo");
    ed.press("Escape", "");
    ed.run("vim-goto-top");

    // `"+yy` — the line, with its line break, is on the desktop clipboard.
    clip(&ed, "y y");
    try t.expectEqualStrings("one\n", ed.head.clipboard.text());

    // Foreign charwise text pastes at the caret…
    try ed.head.clipboard.set(gpa, "XY");
    clip(&ed, "p");
    try expectText(&ed, "XYone\ntwo");

    // …and foreign text ending in a line break pastes as a line above (`P`).
    try ed.head.clipboard.set(gpa, "L\n");
    clip(&ed, "P");
    try expectText(&ed, "L\nXYone\ntwo");

    // A clipboard still holding vim's own linewise yank pastes it as that
    // register (a line below), not as a fragment.
    ed.press("G", "");
    clip(&ed, "y y");
    try t.expectEqualStrings("two\n", ed.head.clipboard.text());
    clip(&ed, "p");
    try expectText(&ed, "L\nXYone\ntwo\ntwo");

    // `"*` names the same clipboard.
    ed.run("vim-goto-top");
    ed.press("quotedbl", "");
    ed.press("asterisk", "");
    ed.chord("y y");
    try t.expectEqualStrings("L\n", ed.head.clipboard.text());

    // A plain yank never touches it.
    ed.chord("j y y");
    try t.expectEqualStrings("L\n", ed.head.clipboard.text());
}

test "e2e/clipboard: without a config grant, declaring the capability confers nothing" {
    const gpa = t.allocator;
    var ed: Editor = undefined;
    try Editor.init(gpa, &ed);
    defer ed.deinit();
    try loadVim(&ed); // vim DECLARES clipboard; nobody granted it

    const vim = pluginNamed(&ed, "vim").?;
    try t.expect(!core.wasm_host.hasPerm(vim, .clipboard));
    try ed.head.clipboard.set(gpa, "secret");

    ed.press("i", "");
    ed.typeText("one");
    ed.press("Escape", "");
    // `"+yy` is refused at the door: the clipboard keeps what it had.
    clip(&ed, "y y");
    try t.expectEqualStrings("secret", ed.head.clipboard.text());
    // `"+p` cannot read it either: nothing of it lands in the buffer.
    clip(&ed, "p");
    const got = try ed.textAlloc();
    defer gpa.free(got);
    try t.expect(std.mem.indexOf(u8, got, "secret") == null);
    // The refusal cost the guest nothing else: vim still edits.
    ed.run("vim-goto-top");
    ed.press("x", "");
    try t.expect(ed.buffers.active().textEditor().?.text().byteLen() < got.len);
}

test "e2e/clipboard: a JS plugin without the grant is refused, with it reads the clipboard" {
    const gpa = t.allocator;
    var ed: Editor = undefined;
    try Editor.init(gpa, &ed);
    defer ed.deinit();
    try ed.head.clipboard.set(gpa, "desk");
    try ed.loadJs("peeker",
        \\weft.command("peek-ungranted", function () {
        \\  try { weft.echo("got:" + weft.clipboardGet()); }
        \\  catch (e) { weft.echo("refused"); }
        \\});
    );
    ed.run("peek-ungranted");
    try t.expectEqualStrings("refused", ed.echoText());

    try ed.grant("granted", "clipboard");
    try ed.loadJs("granted",
        \\weft.command("peek-granted", function () { weft.echo("got:" + weft.clipboardGet()); });
        \\weft.command("put-granted", function () { weft.clipboardSet("from js"); });
    );
    ed.run("peek-granted");
    try t.expectEqualStrings("got:desk", ed.echoText());
    ed.run("put-granted");
    try t.expectEqualStrings("from js", ed.head.clipboard.text());
}

// ── Jumplist ──────────────────────────────────────────────────────────

test "e2e/jumplist: vim's jumps go back and forward, and ride edits" {
    const gpa = t.allocator;
    var ed: Editor = undefined;
    try Editor.init(gpa, &ed);
    defer ed.deinit();
    try loadVim(&ed);

    ed.press("i", "");
    ed.typeText("l1\nl2\nl3\nl4");
    ed.press("Escape", "");
    const typed_end = cursor(&ed);
    ed.run("vim-goto-top"); // a jump: remembers the end
    ed.chord("j j"); // plain motions: not jumps
    const on_l3 = cursor(&ed);
    ed.press("G", ""); // a jump: remembers l3

    ed.run("jump-back");
    try t.expectEqual(on_l3, cursor(&ed));
    ed.run("jump-back");
    try t.expectEqual(typed_end, cursor(&ed));
    ed.run("jump-forward");
    try t.expectEqual(on_l3, cursor(&ed));

    // An edit above a remembered spot carries it along. (`gg` from l3 pushes
    // nothing new: l3 is where the list already stands.)
    ed.run("vim-goto-top");
    ed.press("O", "");
    ed.typeText("new");
    ed.press("Escape", "");
    ed.run("jump-back"); // l3, four bytes further on now
    try t.expectEqual(on_l3 + 4, cursor(&ed));
    try t.expectEqual(@as(u8, 'l'), ed.buffers.active().textEditor().?.text().byteAt(cursor(&ed)));
}

test "e2e/jumplist: moving between entries is recorded; a closed entry is skipped" {
    const gpa = t.allocator;
    var proj: Project = undefined;
    try proj.init(gpa);
    defer proj.deinit();
    var ed: Editor = undefined;
    try Editor.init(gpa, &ed);
    defer ed.deinit();
    try loadVim(&ed);

    authorFile(&ed, "a.txt", "alpha\n");
    authorFile(&ed, "b.txt", "bravo\n");
    authorFile(&ed, "c.txt", "charlie\n");
    try t.expectEqualStrings("c.txt", ed.bufferName());

    ed.run("jump-back");
    try t.expectEqualStrings("b.txt", ed.bufferName());
    ed.run("jump-back");
    try t.expectEqualStrings("a.txt", ed.bufferName());
    ed.run("jump-forward");
    try t.expectEqualStrings("b.txt", ed.bufferName());

    // Close b: the list keeps its entries, but none of them lands on it.
    ed.run("buffer-close");
    try t.expect(!std.mem.eql(u8, "b.txt", ed.bufferName()));
    for (0..4) |_| {
        ed.run("jump-back");
        try t.expect(!std.mem.eql(u8, "b.txt", ed.bufferName()));
    }
    for (0..4) |_| {
        ed.run("jump-forward");
        try t.expect(!std.mem.eql(u8, "b.txt", ed.bufferName()));
    }

    // The picker lists what is live, and accepting a row lands there.
    ed.run("jumplist-pick");
    try t.expect(ed.head.pick.active);
    for (ed.head.pick.items.items) |row| try t.expect(std.mem.indexOf(u8, row, "b.txt") == null);
    ed.press("Escape", "");
}

// ── Macros ────────────────────────────────────────────────────────────

fn vimWith(ed: *Editor, text: []const u8) void {
    ed.press("i", "");
    ed.typeText(text);
    ed.press("Escape", "");
    ed.run("vim-goto-top");
}

test "e2e/macros: q records, @ plays with a count, @@ replays, each change undoes alone" {
    const gpa = t.allocator;
    var ed: Editor = undefined;
    try Editor.init(gpa, &ed);
    defer ed.deinit();
    try loadVim(&ed);
    vimWith(&ed, "x\nx\nx\nx\nx\nx");

    // `qa A1<Esc> j q` — the closing `q` is not part of the macro.
    ed.chord("q a");
    try t.expectEqual(@as(?u8, 'a'), ed.head.macros.recording);
    ed.press("A", "");
    ed.typeText("1");
    ed.press("Escape", "");
    ed.press("j", "");
    ed.press("q", "");
    try t.expectEqual(@as(?u8, null), ed.head.macros.recording);
    const reg = ed.head.macros.regs['a'].items;
    try t.expectEqualStrings("j", reg[reg.len - 1].spec[0..reg[reg.len - 1].slen]);
    try expectText(&ed, "x1\nx\nx\nx\nx\nx");

    ed.press("at", "");
    ed.press("a", "");
    try expectText(&ed, "x1\nx1\nx\nx\nx\nx");
    ed.press("2", "");
    ed.press("at", "");
    ed.press("a", "");
    try expectText(&ed, "x1\nx1\nx1\nx1\nx\nx");
    ed.press("at", "");
    ed.press("at", ""); // `@@`
    try expectText(&ed, "x1\nx1\nx1\nx1\nx1\nx");

    // `.` after a replay repeats the macro's last change, not the macro.
    ed.run("repeat-change"); // `.` (config.js binds it; bare vim does not)
    try expectText(&ed, "x1\nx1\nx1\nx1\nx1\nx1");

    // Each replayed change is its own undo unit, as when it was typed.
    ed.press("u", "");
    try expectText(&ed, "x1\nx1\nx1\nx1\nx1\nx");
    ed.press("u", "");
    try expectText(&ed, "x1\nx1\nx1\nx1\nx\nx");
}

test "e2e/macros: a macro that plays itself stops instead of recursing" {
    const gpa = t.allocator;
    var ed: Editor = undefined;
    try Editor.init(gpa, &ed);
    defer ed.deinit();
    try loadVim(&ed);
    vimWith(&ed, "y\ny\ny");

    // `qb A2<Esc> j @b q`: while recording, `@b` finds b empty.
    ed.chord("q b");
    ed.press("A", "");
    ed.typeText("2");
    ed.press("Escape", "");
    ed.press("j", "");
    ed.press("at", "");
    ed.press("b", "");
    ed.press("q", "");
    try expectText(&ed, "y2\ny\ny");

    // Played, it edits once, reaches its own `@b`, and stops there.
    ed.press("at", "");
    ed.press("b", "");
    try expectText(&ed, "y2\ny2\ny");
    try t.expect(std.mem.indexOf(u8, ed.echoText(), "replay itself") != null);
    try t.expectEqual(@as(u8, 0), ed.head.macros.depth);
    try t.expect(!ed.head.macros.playing.isSet('b'));
}

test "e2e/macros: pointer gestures are not recorded; the recording state is a door" {
    const gpa = t.allocator;
    var ed: Editor = undefined;
    try Editor.init(gpa, &ed);
    defer ed.deinit();
    try loadVim(&ed);
    vimWith(&ed, "z");

    ed.run("macro-record-toggle"); // no register named: `@`
    try t.expectEqual(@as(?u8, '@'), ed.head.macros.recording);
    ed.press("mouse-1", "");
    ed.press("wheel-down", "");
    ed.press("x", "");
    ed.run("macro-record-toggle");
    const reg = ed.head.macros.regs['@'].items;
    try t.expectEqual(@as(usize, 1), reg.len);
    try t.expectEqualStrings("x", reg[0].spec[0..reg[0].slen]);
}

// ── Through config.js ─────────────────────────────────────────────────

test "e2e/config: config.js binds the jumplist, grants vim the clipboard, and macros run" {
    const gpa = t.allocator;
    var proj: Project = undefined;
    try proj.init(gpa);
    defer proj.deinit();
    var ed: Editor = undefined;
    try Editor.init(gpa, &ed);
    defer ed.deinit();
    var loader: ConfigLoader = .{ .ed = &ed };
    defer loader.deinit();
    const config_dir = try std.fmt.allocPrint(gpa, "{s}/config", .{proj.prev_cwd});
    defer gpa.free(config_dir);
    try bootConfig(&ed, config_dir, &loader);
    try t.expect(loader.failed.items.len == 0);

    const back = ed.keymap.resolveExactArms("normal", "C-o").?;
    try t.expectEqualStrings("jump-back", back[back.len - 1]);
    try t.expectEqualStrings("jump-forward", ed.keymap.resolveExact("normal", "C-i").?);
    try t.expectEqualStrings("jumplist-pick", ed.keymap.resolveExact("normal", "space s j").?);
    try t.expect(core.wasm_host.hasPerm(pluginNamed(&ed, "vim").?, .clipboard));

    authorFile(&ed, "notes.txt", "first\nsecond\n");
    ed.run("vim-goto-top");
    clip(&ed, "y y");
    try t.expectEqualStrings("first\n", ed.head.clipboard.text());

    // C-o / C-i across entries, through the config's own keys.
    authorFile(&ed, "other.txt", "other\n");
    ed.press("C-o", "");
    try t.expectEqualStrings("notes.txt", ed.bufferName());
    ed.press("C-i", "");
    try t.expectEqualStrings("other.txt", ed.bufferName());

    // A macro through the configured grammar.
    ed.run("vim-goto-top");
    ed.chord("q c");
    ed.press("A", "");
    ed.typeText("!");
    ed.press("Escape", "");
    ed.press("q", "");
    ed.press("at", "");
    ed.press("c", "");
    const got = try ed.textAlloc();
    defer gpa.free(got);
    try t.expect(std.mem.startsWith(u8, got, "other!!"));
}
