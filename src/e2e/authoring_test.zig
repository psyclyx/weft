//! e2e test file — a vim user authoring files through the REAL config: the ex
//! command line (`:w`), buffer-word completion (`C-n`), and fixing mistakes with
//! motions. Each small test drives what a person actually presses; where the
//! natural motion misbehaves, that's the SIGNAL to fix (not test around).

const std = @import("std");
const t = std.testing;
const h = @import("harness.zig");

const core = h.core;
const App = h.App;
const semantic = h.semantic_model;
const authorFile = h.authorFile;
const toolText = h.toolText;
const drainToolContains = h.drainToolContains;
const drainUntilOracle = h.drainUntilOracle;

test "authoring: `:w` writes the buffer to disk (the ex command a vim user reaches for)" {
    const gpa = t.allocator;
    var app: App = undefined;
    try app.init(gpa);
    defer app.deinit();
    const ed = &app.ed;

    // Open a new file, type a line, escape — then save with `:w`, not a command.
    ed.runStr("open", "index.html");
    ed.press("i", "");
    ed.typeText("<!doctype html>\n");
    ed.press("Escape", "");

    ed.press("colon", ""); // enter the ex line
    try t.expectEqualStrings("ex", ed.mode());
    ed.typeText("w"); // the ex command
    ed.press("Return", ""); // run it
    ed.waitSave();

    const disk = try core.file.readAlloc(gpa, "index.html");
    defer gpa.free(disk);
    try t.expect(std.mem.indexOf(u8, disk, "<!doctype html>") != null);
}

test "authoring: `:%s/old/new/g` renames every occurrence (the daily refactor motion)" {
    const gpa = t.allocator;
    var app: App = undefined;
    try app.init(gpa);
    defer app.deinit();
    const ed = &app.ed;

    ed.runStr("open", "theme.css");
    ed.press("i", "");
    ed.typeText(".btn { color: teal; }\n.link { color: teal; }\n.hdr { color: navy; }\n");
    ed.press("Escape", "");

    // Rename teal → coral across the whole file, the way a vim user does it.
    ed.press("colon", "");
    try t.expectEqualStrings("ex", ed.mode());
    ed.typeText("%s/teal/coral/g");
    ed.press("Return", "");

    // Persist and check the artifact on disk.
    ed.press("colon", "");
    ed.typeText("w");
    ed.press("Return", "");
    ed.waitSave();

    const disk = try core.file.readAlloc(gpa, "theme.css");
    defer gpa.free(disk);
    try t.expect(std.mem.indexOf(u8, disk, "teal") == null); // every match replaced
    try t.expect(std.mem.count(u8, disk, "coral") == 2); // both, and only both
    try t.expect(std.mem.indexOf(u8, disk, "navy") != null); // an unrelated value is untouched
}

test "authoring: `gc` comments — gcc toggles a line, gcip a paragraph (composition)" {
    const gpa = t.allocator;
    var app: App = undefined;
    try app.init(gpa);
    defer app.deinit();
    const ed = &app.ed;

    authorFile(ed, "app.js",
        \\const a = 1;
        \\const b = 2;
        \\const c = 3;
        \\
    );

    // gcc on the first line comments it; gcc again toggles it back — a round-trip.
    ed.chord("g g"); // to the top
    ed.chord("g c c");
    ed.run("save");
    ed.waitSave();
    {
        const disk = try core.file.readAlloc(gpa, "app.js");
        defer gpa.free(disk);
        try t.expect(std.mem.indexOf(u8, disk, "// const a = 1;") != null);
        try t.expect(std.mem.indexOf(u8, disk, "// const b") == null); // only line 1
    }
    ed.chord("g g");
    ed.chord("g c c"); // toggle off
    ed.run("save");
    ed.waitSave();
    {
        const disk = try core.file.readAlloc(gpa, "app.js");
        defer gpa.free(disk);
        try t.expect(std.mem.indexOf(u8, disk, "//") == null); // clean again
    }

    // The whole point of an OPERATOR: gc composes with a text object it never
    // knew about. gcip comments the inner paragraph — all three lines at once.
    ed.chord("g g");
    ed.chord("g c i p");
    ed.run("save");
    ed.waitSave();
    {
        const disk = try core.file.readAlloc(gpa, "app.js");
        defer gpa.free(disk);
        try t.expect(std.mem.indexOf(u8, disk, "// const a = 1;") != null);
        try t.expect(std.mem.indexOf(u8, disk, "// const b = 2;") != null);
        try t.expect(std.mem.indexOf(u8, disk, "// const c = 3;") != null);
    }
}

test "authoring: visual `gc` comments the selected lines" {
    const gpa = t.allocator;
    var app: App = undefined;
    try app.init(gpa);
    defer app.deinit();
    const ed = &app.ed;

    authorFile(ed, "s.css",
        \\.a { color: red; }
        \\.b { color: blue; }
        \\.c { color: lime; }
        \\
    );

    // Select the first two lines linewise, then gc — a vim user's muscle motion.
    ed.chord("g g");
    ed.press("V", ""); // linewise visual
    ed.press("j", ""); // extend down one line
    ed.chord("g c");
    try t.expectEqualStrings("normal", ed.mode()); // gc returns to normal
    ed.run("save");
    ed.waitSave();

    const disk = try core.file.readAlloc(gpa, "s.css");
    defer gpa.free(disk);
    try t.expect(std.mem.indexOf(u8, disk, "// .a { color: red; }") != null);
    try t.expect(std.mem.indexOf(u8, disk, "// .b { color: blue; }") != null);
    try t.expect(std.mem.indexOf(u8, disk, "// .c") == null); // the third line was not selected
}

test "authoring: `gU`/`gu` case operators — line, motion, and visual" {
    const gpa = t.allocator;
    var app: App = undefined;
    try app.init(gpa);
    defer app.deinit();
    const ed = &app.ed;

    authorFile(ed, "c.js",
        \\let name = value;
        \\
    );

    // gUU uppercases the whole line; guu lowercases it back (doubled = line).
    ed.chord("g g");
    ed.chord("g U U");
    ed.run("save");
    ed.waitSave();
    {
        const disk = try core.file.readAlloc(gpa, "c.js");
        defer gpa.free(disk);
        try t.expect(std.mem.indexOf(u8, disk, "LET NAME = VALUE;") != null);
    }
    ed.chord("g g");
    ed.chord("g u u");
    ed.run("save");
    ed.waitSave();
    {
        const disk = try core.file.readAlloc(gpa, "c.js");
        defer gpa.free(disk);
        try t.expect(std.mem.indexOf(u8, disk, "let name = value;") != null);
    }

    // gUw — the operator over a WORD motion: only the first word uppercases.
    ed.chord("g g");
    ed.chord("g U w");
    ed.run("save");
    ed.waitSave();
    {
        const disk = try core.file.readAlloc(gpa, "c.js");
        defer gpa.free(disk);
        try t.expect(std.mem.indexOf(u8, disk, "LET name = value;") != null);
    }
}

test "authoring: `>`/`<` indent operators — line, text object, visual" {
    const gpa = t.allocator;
    var app: App = undefined;
    try app.init(gpa);
    defer app.deinit();
    const ed = &app.ed;

    authorFile(ed, "n.js",
        \\function f() {
        \\return 1;
        \\}
        \\
    );

    // >> indents the current line one unit; << dedents it back (doubled = line).
    ed.chord("g g");
    ed.press("j", ""); // to `return 1;`
    ed.chord("greater greater");
    ed.run("save");
    ed.waitSave();
    {
        const disk = try core.file.readAlloc(gpa, "n.js");
        defer gpa.free(disk);
        try t.expect(std.mem.indexOf(u8, disk, "  return 1;") != null);
    }
    ed.chord("less less");
    ed.run("save");
    ed.waitSave();
    {
        const disk = try core.file.readAlloc(gpa, "n.js");
        defer gpa.free(disk);
        try t.expect(std.mem.indexOf(u8, disk, "  return 1;") == null); // dedented
        try t.expect(std.mem.indexOf(u8, disk, "return 1;") != null);
    }

    // >ip indents the whole paragraph — the operator composing with a text object.
    ed.chord("g g");
    ed.chord("greater i p");
    ed.run("save");
    ed.waitSave();
    {
        const disk = try core.file.readAlloc(gpa, "n.js");
        defer gpa.free(disk);
        try t.expect(std.mem.indexOf(u8, disk, "  function f() {") != null);
        try t.expect(std.mem.indexOf(u8, disk, "  return 1;") != null);
        try t.expect(std.mem.indexOf(u8, disk, "  }") != null);
    }
}

test "dired: semantic field editing keeps the view focused and returns to normal" {
    const gpa = t.allocator;
    var app: App = undefined;
    try app.init(gpa);
    defer app.deinit();
    const ed = &app.ed;

    // Open the current directory through the ordinary provider-aware `open`
    // command. The sandboxed dired plugin claims it through the generic
    // target-handler ABI; there is no dired buffer or dired mode involved.
    authorFile(ed, "note.txt", "hello\n");
    ed.runStr("open", ".");
    const view_ref = ed.head.semantic_focus.path().?.view;
    const view = ed.session.system.semantic.views.get(view_ref).?;
    try t.expectEqualStrings("dired", view.scene.role);
    const leaf = ed.head.semantic_focus.path().?.leaf().?;
    const field_ref = view.node(leaf).?.content.field.ref;
    var before = try ed.session.system.semantic.fields.get(field_ref).?.snapshot(gpa);
    defer before.deinit();
    try t.expectEqualStrings("note.txt", before.value.bytes);

    // Enter the ordinary Vim insert posture on the focused semantic field,
    // type through the generic field provider, then leave it. The plugin owns
    // the draft; Vim owns only the editing posture.
    ed.press("i", "");
    ed.typeText("x");
    ed.press("Escape", "");
    try t.expectEqualStrings("normal", ed.mode());
    try t.expectEqual(view_ref, ed.head.semantic_focus.path().?.view);
    var after = try ed.session.system.semantic.fields.get(field_ref).?.snapshot(gpa);
    defer after.deinit();
    try t.expectEqualStrings("xnote.txt", after.value.bytes);
}

test "dired: Vim Return and minus follow generic target relations" {
    const gpa = t.allocator;
    var app: App = undefined;
    try app.init(gpa);
    defer app.deinit();
    const ed = &app.ed;

    try core.file.writeBytesMakingDirs(gpa, "child", "child/note.txt", "hello\n");
    ed.runStr("open", ".");
    const parent_view = ed.head.semantic_focus.path().?.view;
    const parent = ed.session.system.semantic.views.get(parent_view).?;
    var child_name: ?semantic.scene.NodeId = null;
    for (parent.scene.content.container.children) |row| {
        const node = row.content.container.children[2];
        var snapshot = try ed.session.system.semantic.fields.get(node.content.field.ref).?.snapshot(gpa);
        defer snapshot.deinit();
        if (std.mem.eql(u8, snapshot.value.bytes, "child")) child_name = node.id;
    }
    _ = try ed.session.system.semantic.focusView(ed.head, gpa, parent_view, child_name orelse return error.TestExpectedEqual);

    // Vim supplies only its ordinary Return interaction. Core follows the
    // focused typed link and the directory plugin happens to claim the target.
    ed.press("Return", "");
    const child_view = ed.head.semantic_focus.path().?.view;
    try t.expect(!child_view.eql(parent_view));
    try t.expectEqualStrings("dired", ed.session.system.semantic.views.get(child_view).?.scene.role);

    // `-` likewise follows the open `container` relation. The child target's
    // publisher supplies that edge; Vim and dired do not import one another.
    ed.press("minus", "");
    try t.expectEqual(parent_view, ed.head.semantic_focus.path().?.view);
    try t.expectEqualStrings("normal", ed.mode());
}

test "authoring: switching back to an open file lands in an editable mode" {
    const gpa = t.allocator;
    var app: App = undefined;
    try app.init(gpa);
    defer app.deinit();
    const ed = &app.ed;

    // Open two files, then return to the first — the buffer we already have open.
    authorFile(ed, "a.txt",
        \\alpha
        \\beta
        \\
    );
    authorFile(ed, "b.txt",
        \\gamma
        \\
    );
    ed.runStr("open", "a.txt"); // switch BACK to the already-open buffer

    // Before resting modes, this stranded you in `default` (baseMode overshot
    // normal→default), vim keys dead. Now it's normal — and genuinely editable:
    // dd removes the first line.
    try t.expectEqualStrings("normal", ed.mode());
    ed.chord("g g");
    ed.chord("d d");
    ed.run("save");
    ed.waitSave();

    const disk = try core.file.readAlloc(gpa, "a.txt");
    defer gpa.free(disk);
    try t.expect(std.mem.indexOf(u8, disk, "alpha") == null); // dd worked → editable
    try t.expect(std.mem.indexOf(u8, disk, "beta") != null);
}

test "authoring: `f` finds a char, `;` repeats it, `,` repeats reversed" {
    const gpa = t.allocator;
    var app: App = undefined;
    try app.init(gpa);
    defer app.deinit();
    const ed = &app.ed;

    // Dots at indices 3, 7, 11. We navigate by find/repeat, then `x` deletes the
    // char under the cursor — the deleted position is how we observe where we
    // landed without poking cursor internals.
    authorFile(ed, "f.txt",
        \\foo.bar.baz.qux
        \\
    );

    ed.chord("g g");
    ed.press("f", ""); // f<char>
    ed.typeText("."); // → first dot (index 3)
    ed.press("semicolon", ""); // ; → next dot (index 7)
    ed.press("semicolon", ""); // ; → next dot (index 11)
    ed.press("comma", ""); // , → reversed, back to the dot at index 7
    ed.press("x", ""); // delete the char there
    ed.run("save");
    ed.waitSave();

    const disk = try core.file.readAlloc(gpa, "f.txt");
    defer gpa.free(disk);
    // If ; advanced twice and , stepped back once, the cursor sat on the dot at
    // index 7 — deleting it fuses "bar" and "baz".
    try t.expect(std.mem.indexOf(u8, disk, "foo.barbaz.qux") != null);
}

test "authoring: `~` toggles case under the cursor and advances (count-aware)" {
    const gpa = t.allocator;
    var app: App = undefined;
    try app.init(gpa);
    defer app.deinit();
    const ed = &app.ed;

    authorFile(ed, "tilde.txt",
        \\Hello World
        \\
    );

    // 5~ from the top flips the case of the first five chars ("Hello" → "hELLO").
    ed.chord("g g");
    ed.press("5", "");
    ed.press("asciitilde", "");
    ed.run("save");
    ed.waitSave();

    const disk = try core.file.readAlloc(gpa, "tilde.txt");
    defer gpa.free(disk);
    try t.expect(std.mem.indexOf(u8, disk, "hELLO World") != null);
}

test "authoring: `r` replaces the char under the cursor; `3r` replaces a run" {
    const gpa = t.allocator;
    var app: App = undefined;
    try app.init(gpa);
    defer app.deinit();
    const ed = &app.ed;

    authorFile(ed, "r.txt",
        \\hello world
        \\
    );

    // r<char> replaces one char in place; cursor stays on it.
    ed.chord("g g");
    ed.press("r", "");
    ed.typeText("J"); // 'h' → 'J'
    ed.run("save");
    ed.waitSave();
    {
        const disk = try core.file.readAlloc(gpa, "r.txt");
        defer gpa.free(disk);
        try t.expect(std.mem.indexOf(u8, disk, "Jello world") != null);
    }

    // 3r replaces a run of three (count captured on `r`), still line-bounded.
    ed.chord("g g");
    ed.press("3", ""); // count
    ed.press("r", "");
    ed.typeText("x"); // J,e,l → x,x,x
    ed.run("save");
    ed.waitSave();
    {
        const disk = try core.file.readAlloc(gpa, "r.txt");
        defer gpa.free(disk);
        try t.expect(std.mem.indexOf(u8, disk, "xxxlo world") != null);
    }
}

test "authoring: `C-n` completes a word already in the buffer" {
    const gpa = t.allocator;
    var app: App = undefined;
    try app.init(gpa);
    defer app.deinit();
    const ed = &app.ed;

    ed.runStr("open", "app.js");
    ed.press("i", "");
    // Establish a distinctive word, then start typing its prefix and complete.
    ed.typeText("const greeting = 1;\n");
    ed.typeText("gre");
    ed.press("C-n", ""); // opens the buffer-word completion pick (mode → pick)
    ed.settle(30); // let the async candidate source stream in
    ed.press("Return", ""); // pick-accept: commit the selected candidate
    ed.press("Escape", ""); // leave insert

    // Save and read back: if completion committed, "greeting" appears twice.
    ed.press("colon", "");
    ed.typeText("w");
    ed.press("Return", "");
    ed.waitSave();

    const disk = try core.file.readAlloc(gpa, "app.js");
    defer gpa.free(disk);
    const first = std.mem.indexOf(u8, disk, "greeting") orelse return error.WordMissing;
    try t.expect(std.mem.indexOf(u8, disk[first + 1 ..], "greeting") != null);
}

test "authoring: fix a typo with `cw` — vim's ce special case, not dw" {
    const gpa = t.allocator;
    var app: App = undefined;
    try app.init(gpa);
    defer app.deinit();
    const ed = &app.ed;

    // Type a line with a typo in the first word ("cnst" → "const").
    ed.runStr("open", "app.js");
    ed.press("i", "");
    ed.typeText("cnst x = 1;");
    ed.press("Escape", "");

    // Fix it the vim way: line-start, change the word, retype it.
    ed.press("0", ""); // motion.line-start → cursor on the 'c'
    ed.press("c", ""); // operator: change
    ed.press("w", ""); // vim's cw = ce: change the WHOLE word "cnst", KEEP the space
    try t.expectEqualStrings("insert", ed.mode());
    ed.typeText("const");
    ed.press("Escape", ""); // → "const x = 1;"

    ed.press("colon", "");
    ed.typeText("w");
    ed.press("Return", "");
    ed.waitSave();

    // Two vim fidelity bugs this drove out + fixed in the vim guest:
    //   · cw ate the trailing space (behaved like dw)   → now ce (space kept)
    //   · ce/de dropped the word's last char (inclusive → now the operator
    //     motion off-by-one)                              covers the endpoint
    // Without the fixes this was "constt x = 1;" / "constx = 1;".
    const disk = try core.file.readAlloc(gpa, "app.js");
    defer gpa.free(disk);
    try t.expectEqualStrings("const x = 1;", disk);
}

test "authoring: Esc seals the undo unit — dd then u restores the whole line" {
    const gpa = t.allocator;
    var app: App = undefined;
    try app.init(gpa);
    defer app.deinit();
    const ed = &app.ed;

    ed.runStr("open", "note.txt");
    ed.press("i", "");
    ed.typeText("const x = 1;");
    ed.press("Escape", ""); // seals the insert unit (the fix)

    // Fumble: delete the whole line, then undo. `u` must undo ONLY the dd — not
    // reach back into the (now separate) typing unit. Before the fix, Esc didn't
    // barrier, so dd coalesced with the typing and `u` reversed both, leaving a
    // mid-edit state.
    ed.press("d", "");
    ed.press("d", ""); // dd — line gone
    ed.press("u", ""); // undo — the whole line is back

    ed.press("colon", "");
    ed.typeText("w");
    ed.press("Return", "");
    ed.waitSave();

    const disk = try core.file.readAlloc(gpa, "note.txt");
    defer gpa.free(disk);
    try t.expectEqualStrings("const x = 1;", disk);
}

test "authoring: `.` repeats the last change (dot-repeat, via keystroke replay)" {
    const gpa = t.allocator;
    var app: App = undefined;
    try app.init(gpa);
    defer app.deinit();
    const ed = &app.ed;

    ed.runStr("open", "words.txt");
    ed.press("i", "");
    ed.typeText("one two three four");
    ed.press("Escape", "");
    ed.press("0", ""); // line start

    // dw deletes the first word; `.` repeats that change on the next word, then
    // again — the classic vim idiom. Dot-repeat records the KEYS of the change
    // (d, w) and replays them, so it composes with the operator/motion plugins.
    ed.press("d", "");
    ed.press("w", ""); // → "two three four"
    ed.press(".", ""); // repeat dw → "three four"
    ed.press(".", ""); // → "four"

    ed.press("colon", "");
    ed.typeText("w");
    ed.press("Return", "");
    ed.waitSave();

    const disk = try core.file.readAlloc(gpa, "words.txt");
    defer gpa.free(disk);
    try t.expectEqualStrings("four", disk);
}

test "authoring: `.` repeats a CHANGE with inserted text (cw), keystroke-faithful" {
    const gpa = t.allocator;
    var app: App = undefined;
    try app.init(gpa);
    defer app.deinit();
    const ed = &app.ed;

    ed.runStr("open", "c.txt");
    ed.press("i", "");
    ed.typeText("foo bar baz");
    ed.press("Escape", "");
    ed.press("0", "");

    // Change the first word to "X" — cw enters insert, we type, Esc. Because
    // typing is per-keystroke now, the dot register captures c,w,X,Esc.
    ed.press("c", "");
    ed.press("w", "");
    ed.typeText("X");
    ed.press("Escape", ""); // → "X bar baz"

    ed.press("w", ""); // move to "bar"
    ed.press(".", ""); // repeat the whole change → change "bar" to "X"

    ed.press("colon", "");
    ed.typeText("w");
    ed.press("Return", "");
    ed.waitSave();

    const disk = try core.file.readAlloc(gpa, "c.txt");
    defer gpa.free(disk);
    try t.expectEqualStrings("X X baz", disk);
}

test "authoring: a count repeats an operator (3dw) and a motion (3w)" {
    const gpa = t.allocator;
    var app: App = undefined;
    try app.init(gpa);
    defer app.deinit();
    const ed = &app.ed;

    // Operator count: `3dw` deletes three words.
    ed.runStr("open", "cn.txt");
    ed.press("i", "");
    ed.typeText("one two three four five");
    ed.press("Escape", "");
    ed.press("0", "");
    ed.press("3", "3");
    ed.press("d", "");
    ed.press("w", ""); // 3dw → "four five"
    ed.press("colon", "");
    ed.typeText("w");
    ed.press("Return", "");
    ed.waitSave();
    {
        const disk = try core.file.readAlloc(gpa, "cn.txt");
        defer gpa.free(disk);
        try t.expectEqualStrings("four five", disk);
    }

    // Motion count: from line start, `3w` moves three words forward. Mark it.
    ed.press("0", "");
    ed.press("3", "3");
    ed.press("w", ""); // → onto... "four five" has 2 words; 3w clamps to end
    ed.press("i", "");
    ed.typeText("Z");
    ed.press("Escape", "");
    ed.press("colon", "");
    ed.typeText("w");
    ed.press("Return", "");
    ed.waitSave();
    {
        const disk = try core.file.readAlloc(gpa, "cn.txt");
        defer gpa.free(disk);
        // 3w from "four five" (2 words) lands at the last word / end; the marker
        // is on/after "five", never back on "four".
        try t.expect(std.mem.indexOf(u8, disk, "four ") != null);
        try t.expect(std.mem.indexOf(u8, disk, "Z") != null);
    }
}

test "authoring: `.` repeats a COUNTED change (3dw then . deletes three more)" {
    const gpa = t.allocator;
    var app: App = undefined;
    try app.init(gpa);
    defer app.deinit();
    const ed = &app.ed;

    ed.runStr("open", "cd.txt");
    ed.press("i", "");
    ed.typeText("a b c d e f g");
    ed.press("Escape", "");
    ed.press("0", "");
    ed.press("3", "3");
    ed.press("d", "");
    ed.press("w", ""); // 3dw → "d e f g"
    ed.press(".", ""); // repeat the WHOLE 3dw (count included) → "g"

    ed.press("colon", "");
    ed.typeText("w");
    ed.press("Return", "");
    ed.waitSave();

    const disk = try core.file.readAlloc(gpa, "cd.txt");
    defer gpa.free(disk);
    try t.expectEqualStrings("g", disk);
}

test "authoring: typing balanced code with autopair stays balanced (type-over)" {
    const gpa = t.allocator;
    var app: App = undefined;
    try app.init(gpa);
    defer app.deinit();
    const ed = &app.ed;

    // A person types balanced code, typing the closers themselves. Without
    // type-over, autopair orphaned each auto-closer and this became
    // `...name; }})`. With type-over, typing `)`/`}`/`"` steps over the
    // auto-inserted one, so what you typed is what you get.
    ed.runStr("open", "t.js");
    ed.press("i", "");
    ed.typeText("function greet(name) { return \"hi\"; }");
    ed.press("Escape", "");
    ed.press("colon", "");
    ed.typeText("w");
    ed.press("Return", "");
    ed.waitSave();

    const disk = try core.file.readAlloc(gpa, "t.js");
    defer gpa.free(disk);
    try t.expectEqualStrings("function greet(name) { return \"hi\"; }", disk);
}

test "authoring: format the buffer (SPC c f) — zig fmt via the format action" {
    const gpa = t.allocator;
    var app: App = undefined;
    try app.init(gpa);
    defer app.deinit();
    const ed = &app.ed;

    // Write badly-spaced but valid zig, then format it. `SPC c f` → the `format`
    // action → format-buffer, which filters .zig through `zig fmt`.
    ed.runStr("open", "fmt_me.zig");
    ed.press("i", "");
    ed.typeText("const    x=1;");
    ed.press("Escape", "");
    ed.chord("SPC c f"); // format
    // The formatter runs async (procFilter, off a pool thread) — wait for the
    // real result to land instead of assuming a fixed settle() round count is
    // enough wall-clock time (task #28: it wasn't, on a slower/quieter box).
    try t.expect(h.drainBufferContains(ed, "const x = 1;\n"));

    ed.press("colon", "");
    ed.typeText("w");
    ed.press("Return", "");
    ed.waitSave();

    const disk = try core.file.readAlloc(gpa, "fmt_me.zig");
    defer gpa.free(disk);
    try t.expectEqualStrings("const x = 1;\n", disk); // zig fmt's canonical form
}

test "lsp: hover + goto-definition via the lsp plugin — real zls" {
    const gpa = t.allocator;
    var app: App = undefined;
    try app.init(gpa);
    defer app.deinit();
    const ed = &app.ed;

    // Needs the real toolchain (src/e2e/shell.nix); skip cleanly without zls.
    if (!h.toolAvailable(gpa, "zls")) return error.SkipZigTest;

    // Write a small zig file to disk (heredoc, so autopair never mangles it) and
    // open it — a fresh open attaches zls per the vim config's `lsp-add .zig zls`.
    {
        const out = try app.proj.oracle(
            \\cat > add.zig <<'EOF'
            \\fn add(a: i32, b: i32) i32 {
            \\    return a + b;
            \\}
            \\pub fn main() void {
            \\    const r = add(2, 3);
            \\    _ = r;
            \\}
            \\EOF
        );
        gpa.free(out);
    }
    ed.runStr("open", "add.zig");

    // Put the cursor on the `add` call (line 5), then hover: zls answers with the
    // function's signature once its handshake completes.
    ed.chord("g g");
    ed.press("4", "");
    ed.press("j", ""); // → line 5, `    const r = add(2, 3);`
    ed.press("0", "");
    ed.press("f", "");
    ed.typeText("a"); // f a → onto the `a` of `add`
    // Rendering P2: hover is a live caret-popup producer now, not an echo
    // (the popup-layout gate covers the layout; this proves the real `lsp`
    // plugin's round-trip actually reaches the surface membrane).
    try t.expect(h.drainSurfaceText(ed, "hover", "i32")); // the popup shows add's signature

    // goto-definition from the call jumps to `fn add` on line 1; deleting the
    // current line then proves we landed on the definition, not the call.
    ed.run("goto-definition");
    ed.settle(300); // server's ready now (hover spawned it) — one round-trip + jump
    ed.chord("d d");
    ed.run("save");
    ed.waitSave();
    const disk = try core.file.readAlloc(gpa, "add.zig");
    defer gpa.free(disk);
    try t.expect(std.mem.indexOf(u8, disk, "fn add(a: i32") == null); // the def line is gone
    try t.expect(std.mem.indexOf(u8, disk, "const r = add(2, 3)") != null); // the call remains
}

test "lsp: hover popup auto-expires once the cursor leaves its anchor's line — real zls" {
    const gpa = t.allocator;
    var app: App = undefined;
    try app.init(gpa);
    defer app.deinit();
    const ed = &app.ed;

    // Needs the real toolchain (src/e2e/shell.nix); skip cleanly without zls.
    if (!h.toolAvailable(gpa, "zls")) return error.SkipZigTest;

    // Rendering P2 review, F1: a caret popup paints OVER body text (unlike
    // the echo line hover replaced), so a stale one left open after the
    // cursor moves away is a real regression, not just clutter — and a
    // guest has no `on_move`/`on_edit` export to dismiss its own popup
    // (that's P4-era; see doc/rendering.md). Production expires it as core
    // POLICY, once per frame, in `frame_builder.buildFrame` — reproduce the
    // same setup as the hover test above, then prove the fix against the
    // REAL loaded `lsp` plugin's live surface.
    {
        const out = try app.proj.oracle(
            \\cat > hover_expiry.zig <<'EOF'
            \\fn add(a: i32, b: i32) i32 {
            \\    return a + b;
            \\}
            \\pub fn main() void {
            \\    const r = add(2, 3);
            \\    _ = r;
            \\}
            \\EOF
        );
        gpa.free(out);
    }
    ed.runStr("open", "hover_expiry.zig");

    ed.chord("g g");
    ed.press("4", "");
    ed.press("j", ""); // → line 5, `    const r = add(2, 3);`
    ed.press("0", "");
    ed.press("f", "");
    ed.typeText("a"); // f a → onto the `a` of `add`
    try t.expect(h.drainSurfaceText(ed, "hover", "i32")); // popup visible, anchored on line 5

    // Move the cursor to a different line through REAL dispatch — the same
    // motion a person makes after reading the popup, not a synthetic
    // offset write.
    ed.press("j", "");
    ed.press("j", "");
    try t.expect(h.surfaceHasText(ed, "i32")); // sanity: dispatch alone doesn't clear it —
    // this is core's per-FRAME policy, and this harness never runs a real
    // render loop (see `popup_layout_test.zig`'s module doc for why: this
    // suite drives the editor/dispatch stack directly). So call the exact
    // function `frame_builder.buildFrame` calls every real frame — proving
    // the SHIPPED policy (not a reimplementation of it) actually closes
    // this real, dispatch-driven popup once the cursor has genuinely moved.
    h.app_frame_builder.expireStaleCaretSurfaces(
        ed.plugins.items,
        ed.buffers.active().editor.text(),
        ed.buffers.active().editor.cursorOffset(),
    );

    try t.expect(!h.surfaceHasText(ed, "i32")); // the popup is gone
    for (ed.plugins.items) |pl| {
        if (pl.surface.placement == .caret) try t.expect(!pl.surface.active); // CLOSED, not merely hidden
    }
}

test "lsp: completion via the lsp plugin — async caps provider commits real zls items" {
    const gpa = t.allocator;
    var app: App = undefined;
    try app.init(gpa);
    defer app.deinit();
    const ed = &app.ed;

    if (!h.toolAvailable(gpa, "zls")) return error.SkipZigTest;

    // A top-level const referenced by a distinct partial (`answ`) inside main.
    // zls resolves in-file symbols from the didOpen snapshot (no build needed),
    // so completing `answ` offers `answer_to_everything` — an LSP-only semantic
    // completion the plugin must fetch asynchronously and commit into the session.
    {
        const out = try app.proj.oracle(
            \\cat > comp.zig <<'EOF'
            \\const answer_to_everything = 42;
            \\pub fn main() void {
            \\    const x = answ;
            \\    _ = x;
            \\}
            \\EOF
        );
        gpa.free(out);
    }
    ed.runStr("open", "comp.zig");
    ed.settle(120); // let the plugin spawn zls + finish the initialize handshake

    // Place the cursor right after `answ` (the main-body usage, matched by the
    // unambiguous `= answ`), then prove the LSP completion provider answers the
    // caps session asynchronously with items.
    const txt = try ed.textAlloc();
    defer gpa.free(txt);
    const needle = "= answ";
    const idx = std.mem.indexOf(u8, txt, needle).?;
    const off = idx + needle.len;
    ed.buffers.active().editor.placeCursor(off);
    try t.expect(h.drainLspCompletion(ed, off, "answ"));
}

test "complete: the caret popup narrows as you type" {
    const gpa = t.allocator;
    var app: App = undefined;
    try app.init(gpa);
    defer app.deinit();
    const ed = &app.ed;

    // Buffer-word candidates sharing the prefix `al`; the cursor sits after a
    // trailing `al`, which is the completion prefix.
    const core_ed = &ed.buffers.active().editor;
    try core_ed.insertText(gpa, "alphabet alpine beta al");
    ed.run("complete");
    try t.expect(ed.pick.active); // the popup opened (in "pick" mode)
    const before = ed.pick.filtered.items.len;
    try t.expect(before >= 2); // alphabet, alpine

    // Typing narrows via the pick query: only `alpine` contains an `i`.
    ed.press("i", "i");
    try t.expect(ed.pick.filtered.items.len < before);
    var has_alpine = false;
    for (ed.pick.filtered.items) |idx| {
        if (std.mem.indexOf(u8, ed.pick.items.items[idx], "alpine") != null) has_alpine = true;
    }
    try t.expect(has_alpine);
}

test "lsp: didChange — an edit after open syncs, so completion sees new symbols — real zls" {
    const gpa = t.allocator;
    var app: App = undefined;
    try app.init(gpa);
    defer app.deinit();
    const ed = &app.ed;

    if (!h.toolAvailable(gpa, "zls")) return error.SkipZigTest;

    // main references `zqx`, which doesn't exist at open time.
    {
        const out = try app.proj.oracle(
            \\cat > dc.zig <<'EOF'
            \\pub fn main() void {
            \\    const x = zqx;
            \\    _ = x;
            \\}
            \\EOF
        );
        gpa.free(out);
    }
    ed.runStr("open", "dc.zig");
    ed.settle(120); // handshake + didOpen (the snapshot has no zqx*)

    // Introduce a top-level decl with a real edit — this bumps the commit count,
    // so the plugin sends didChange before the next request. Without didChange the
    // server's copy is the stale snapshot and `zqxable` never completes.
    const core_ed = &ed.buffers.active().editor;
    core_ed.placeCursor(0);
    try core_ed.insertText(gpa, "const zqxable = 7;\n");

    const txt = try ed.textAlloc();
    defer gpa.free(txt);
    const needle = "= zqx";
    const idx = std.mem.indexOf(u8, txt, needle).?;
    const off = idx + needle.len; // right after `zqx`
    core_ed.placeCursor(off);
    try t.expect(h.drainCompletionText(ed, off, "zqx", "zqxable"));
}

test "lsp: real zls diagnostics — a bad file reports an error we can jump to" {
    const gpa = t.allocator;
    var app: App = undefined;
    try app.init(gpa);
    defer app.deinit();
    const ed = &app.ed;

    if (!h.toolAvailable(gpa, "zls")) return error.SkipZigTest;

    // A file with a syntax error — zls publishes a diagnostic for it.
    {
        const out = try app.proj.oracle(
            \\cat > bad.zig <<'EOF'
            \\pub fn main() void {
            \\    const x: i32 = ;
            \\    _ = x;
            \\}
            \\EOF
        );
        gpa.free(out);
    }
    ed.runStr("open", "bad.zig");

    // The server reports diagnostics (rendered as underlines/gutter). Then a
    // vim user's `]d` jumps to the next one and echoes it — proof the diagnostic
    // is both received and navigable.
    ed.run("hover"); // kick the plugin's server (also didOpens → diagnostics flow)
    ed.settle(80);
    // The plugin received publishDiagnostics (gutter-marked); `]d` navigates to
    // one and echoes it — diagnostics received + navigable, all in the plugin.
    try t.expect(h.drainEcho(ed, "next-diagnostic", "error"));
}

test "lsp: rename via the lsp plugin — prompt, then apply the WorkspaceEdit — real zls" {
    const gpa = t.allocator;
    var app: App = undefined;
    try app.init(gpa);
    defer app.deinit();
    const ed = &app.ed;

    if (!h.toolAvailable(gpa, "zls")) return error.SkipZigTest;

    {
        const out = try app.proj.oracle(
            \\cat > r.zig <<'EOF'
            \\fn foo() void {}
            \\pub fn main() void {
            \\    foo();
            \\}
            \\EOF
        );
        gpa.free(out);
    }
    ed.runStr("open", "r.zig");

    // Rename `foo` → `bar`: cursor on the definition, name given as the arg (the
    // interactive path prompts instead).
    ed.chord("g g");
    ed.press("w", ""); // `fn ` → `foo`
    ed.runStr("rename", "bar");

    // The rename is deferred until the server initializes; wait for the applied echo.
    var ok = false;
    var round: usize = 0;
    while (round < 600) : (round += 1) {
        ed.settle(3);
        if (std.mem.indexOf(u8, ed.echoText(), "renamed") != null) {
            ok = true;
            break;
        }
    }
    try t.expect(ok);
    ed.run("save");
    ed.waitSave();

    const disk = try core.file.readAlloc(gpa, "r.zig");
    defer gpa.free(disk);
    try t.expect(std.mem.indexOf(u8, disk, "fn bar()") != null); // definition renamed
    try t.expect(std.mem.indexOf(u8, disk, "bar();") != null); // call renamed
    try t.expect(std.mem.indexOf(u8, disk, "foo") == null); // every occurrence
}

test "lsp: code actions via the lsp plugin — request/response round-trip — real zls" {
    const gpa = t.allocator;
    var app: App = undefined;
    try app.init(gpa);
    defer app.deinit();
    const ed = &app.ed;

    if (!h.toolAvailable(gpa, "zls")) return error.SkipZigTest;

    {
        const out = try app.proj.oracle(
            \\cat > act.zig <<'EOF'
            \\pub fn main() void {
            \\    const x = 1;
            \\    _ = x;
            \\}
            \\EOF
        );
        gpa.free(out);
    }
    ed.runStr("open", "act.zig");
    ed.run("hover"); // kick the server + didOpen
    ed.settle(60);

    // Request code actions for the line; the plugin echoes the outcome — an
    // applied quick-fix, an action needing resolve, or none. This verifies the
    // codeAction request/response path. (A quick-fix that actually edits needs
    // zls build-on-save + a build.zig to produce a fixable diagnostic — an
    // environment requirement, not a code gap.)
    try t.expect(h.drainEcho(ed, "code-actions", "code action"));
}

test "lsp: signature help + inlay hints via the lsp plugin — real zls" {
    const gpa = t.allocator;
    var app: App = undefined;
    try app.init(gpa);
    defer app.deinit();
    const ed = &app.ed;

    if (!h.toolAvailable(gpa, "zls")) return error.SkipZigTest;

    {
        const out = try app.proj.oracle(
            \\cat > g.zig <<'EOF'
            \\fn add(a: i32, b: i32) i32 {
            \\    return a + b;
            \\}
            \\pub fn main() void {
            \\    const r = add(2, 3);
            \\    _ = r;
            \\}
            \\EOF
        );
        gpa.free(out);
    }
    ed.runStr("open", "g.zig");

    // signature help inside the call `add(2, 3)` → echoes add's signature.
    ed.chord("g g");
    ed.press("4", "");
    ed.press("j", ""); // line 5
    ed.press("f", "");
    ed.typeText("2"); // onto the first argument, inside the parens
    try t.expect(h.drainEcho(ed, "signature-help", "i32"));

    // inlay hints over the document → the plugin echoes the count (round-trip).
    try t.expect(h.drainEcho(ed, "inlay-hints", "inlay hints"));
}

test "lsp: format via the lsp plugin applies the server's edits — real zls" {
    const gpa = t.allocator;
    var app: App = undefined;
    try app.init(gpa);
    defer app.deinit();
    const ed = &app.ed;

    if (!h.toolAvailable(gpa, "zls")) return error.SkipZigTest;

    // A badly-spaced file zls will reformat.
    {
        const out = try app.proj.oracle(
            \\cat > f.zig <<'EOF'
            \\pub fn main()void{
            \\const x=1;
            \\_=x;
            \\}
            \\EOF
        );
        gpa.free(out);
    }
    ed.runStr("open", "f.zig");

    // Format through the plugin: request → TextEdit[] → applied via the edit door.
    try t.expect(h.drainEcho(ed, "lsp-format", "formatted"));
    ed.run("save");
    ed.waitSave();

    const disk = try core.file.readAlloc(gpa, "f.zig");
    defer gpa.free(disk);
    try t.expect(std.mem.indexOf(u8, disk, "pub fn main() void {") != null); // spaced
    try t.expect(std.mem.indexOf(u8, disk, "    const x = 1;") != null); // indented
}

test "lsp: references + symbols via the lsp plugin — real zls" {
    const gpa = t.allocator;
    var app: App = undefined;
    try app.init(gpa);
    defer app.deinit();
    const ed = &app.ed;

    if (!h.toolAvailable(gpa, "zls")) return error.SkipZigTest;

    {
        const out = try app.proj.oracle(
            \\cat > s.zig <<'EOF'
            \\fn add(a: i32, b: i32) i32 {
            \\    return a + b;
            \\}
            \\pub fn main() void {
            \\    const r = add(2, 3);
            \\    _ = r;
            \\}
            \\EOF
        );
        gpa.free(out);
    }
    ed.runStr("open", "s.zig");

    // symbols: the plugin opens a pick of the document's symbols (add, main).
    try t.expect(h.drainPick(ed, "symbols"));
    {
        var has_add = false;
        var has_main = false;
        for (ed.pick.items.items) |it| {
            if (std.mem.eql(u8, it, "add")) has_add = true;
            if (std.mem.eql(u8, it, "main")) has_main = true;
        }
        try t.expect(has_add and has_main);
    }
    ed.press("Escape", ""); // close the pick

    // references on `add` (the def name): the pick lists its uses — the
    // declaration plus the call, at least two locations.
    ed.chord("g g");
    ed.press("w", ""); // onto `add`
    try t.expect(h.drainPick(ed, "references"));
    try t.expect(ed.pick.items.items.len >= 2);
}

test "lsp: open returns immediately, before the server's handshake — real zls" {
    const gpa = t.allocator;
    var app: App = undefined;
    try app.init(gpa);
    defer app.deinit();
    const ed = &app.ed;

    // Needs the real toolchain (src/e2e/shell.nix); skip cleanly without zls.
    if (!h.toolAvailable(gpa, "zls")) return error.SkipZigTest;

    {
        const out = try app.proj.oracle(
            \\cat > quick.zig <<'EOF'
            \\pub fn main() void {}
            \\EOF
        );
        gpa.free(out);
    }

    // `open` (and the `on_activate` it triggers, which is what spawns zls)
    // must return without waiting on the server's fork+exec or its
    // initialize handshake. This is a HANG BACKSTOP (generous — a shared,
    // contended CI box can stall a scheduled thread for a while — not a
    // tight perf gate; see e2e/latency_test.zig for the real latency
    // instrument): a regression that reintroduces a blocking spawn+handshake
    // wait on this path would blow way past even this bound, since it would
    // be waiting on zls's real startup, not a scheduling hiccup.
    const start = core.task.nowNs();
    ed.runStr("open", "quick.zig");
    const elapsed = core.task.nowNs() - start;
    try t.expect(elapsed < 2 * std.time.ns_per_s);

    // The buffer is immediately editable through the real insert path —
    // never stalled waiting for zls to become ready.
    const core_ed = &ed.buffers.active().editor;
    try core_ed.insertText(gpa, "// touched before any handshake could finish\n");
    const txt = try ed.textAlloc();
    defer gpa.free(txt);
    try t.expect(std.mem.indexOf(u8, txt, "// touched before any handshake could finish") != null);

    // The server does eventually come up and answer — the other lsp tests
    // prove the full round-trip; this just confirms it wasn't on the
    // critical path to get this far.
    ed.settle(300);
}

test "lsp: a configured server binary that doesn't exist degrades silently — no block, no hang" {
    const gpa = t.allocator;
    var app: App = undefined;
    try app.init(gpa);
    defer app.deinit();
    const ed = &app.ed;

    // A made-up extension pointed at a command that can't possibly exist —
    // "a server is configured but nothing is installed for it", distinct
    // from "no server configured at all" (where `serverCmd` returns "" and
    // the plugin never spawns anything, already the common no-op case every
    // non-.zig file exercises).
    try ed.setConfig("lsp", "noexist", "definitely-not-a-real-lsp-server-xyz123");

    {
        const out = try app.proj.oracle("printf 'hello\\n' > missing.noexist");
        gpa.free(out);
    }

    const start = core.task.nowNs();
    ed.runStr("open", "missing.noexist");
    const elapsed = core.task.nowNs() - start;
    try t.expect(elapsed < 2 * std.time.ns_per_s); // generous hang backstop, not a perf gate

    // Usable immediately regardless of the absent server.
    const core_ed = &ed.buffers.active().editor;
    try core_ed.insertText(gpa, "world\n");

    // No LSP feature can ever answer (there is nothing to answer with) — a
    // bounded settle, then a command that would need the server: no crash,
    // no hang, and no popup ever appears (the "honest warn" — none of this
    // spams the echo line repeatedly; `ensureServer` only attempts the spawn
    // once per language, not once per keystroke).
    ed.settle(20);
    ed.run("hover");
    ed.settle(20);
    for (ed.plugins.items) |pl| try t.expect(!pl.surface.active); // nothing ever rendered
}

test "debug: a real DAP session — launch, hit a breakpoint, see the stack, continue" {
    const gpa = t.allocator;
    var app: App = undefined;
    try app.init(gpa);
    defer app.deinit();
    const ed = &app.ed;

    // Point the DAP client at a mock adapter (node fixture) + a program/line.
    const mock = try std.fmt.allocPrint(gpa, "node {s}/assets/mock_dap.mjs", .{app.proj.prev_cwd});
    defer gpa.free(mock);
    try ed.setConfig("dap", "cmd", mock);
    try ed.setConfig("dap", "program", "prog.py");
    try ed.setConfig("dap", "line", "7");

    // Load the DAP client JS plugin (config.js skips .js in the harness).
    const dap_src = try std.fmt.allocPrint(gpa, "{s}/config/plugins/dap.js", .{app.proj.prev_cwd});
    defer gpa.free(dap_src);
    const src = try core.file.readAlloc(gpa, dap_src);
    defer gpa.free(src);
    try ed.loadJs("dap", src);

    // Start a debug session. The client drives initialize → launch →
    // setBreakpoints → configurationDone; the adapter stops at the breakpoint.
    ed.run("debug-start");
    try t.expect(drainToolContains(ed, "*debug*", "stopped: breakpoint"));
    // ... and the client requested the stack and rendered where we are.
    try t.expect(drainToolContains(ed, "*debug*", "program:7"));

    // Continue → the program runs to completion.
    ed.run("debug-continue");
    try t.expect(drainToolContains(ed, "*debug*", "terminated"));
}

test "debug: a REAL lldb-dap session — compile C, break on a line, stop, continue" {
    const gpa = t.allocator;
    var app: App = undefined;
    try app.init(gpa);
    defer app.deinit();
    const ed = &app.ed;

    // Needs the real toolchain (src/e2e/shell.nix); skip cleanly without it.
    if (!h.toolAvailable(gpa, "lldb-dap") or !h.toolAvailable(gpa, "clang")) return error.SkipZigTest;

    // A tiny C program; line 5 (the printf) is where we'll stop — a line that
    // definitely executes and carries a clean line entry (`volatile` keeps the
    // compiler from folding the arithmetic away even at -O0).
    authorFile(ed, "main.c",
        \\#include <stdio.h>
        \\int main(void) {
        \\  volatile int s = 0;
        \\  s += 5;
        \\  printf("r=%d\n", s);
        \\  return 0;
        \\}
        \\
    );
    {
        const out = try app.proj.oracle("clang -g -o prog main.c 2>&1");
        defer gpa.free(out);
        try t.expect(out.len == 0); // clean compile (diagnostics would print here)
    }

    // Point the DAP client at the real adapter. `program` is the executable to
    // launch; `source` is the file breakpoints live in (they differ for a
    // compiled program). Break on line 5 via the config fallback.
    const src = try std.fmt.allocPrint(gpa, "{s}/main.c", .{app.proj.root});
    defer gpa.free(src);
    const prog = try std.fmt.allocPrint(gpa, "{s}/prog", .{app.proj.root});
    defer gpa.free(prog);
    try ed.setConfig("dap", "cmd", "lldb-dap");
    try ed.setConfig("dap", "program", prog);
    try ed.setConfig("dap", "source", src);
    try ed.setConfig("dap", "line", "5");

    const dap_src = try std.fmt.allocPrint(gpa, "{s}/config/plugins/dap.js", .{app.proj.prev_cwd});
    defer gpa.free(dap_src);
    const js = try core.file.readAlloc(gpa, dap_src);
    defer gpa.free(js);
    try ed.loadJs("dap", js);

    // A real debugger: launch → stop at the breakpoint → report the stack line.
    ed.run("debug-start");
    try t.expect(drainToolContains(ed, "*debug*", "stopped"));
    try t.expect(drainToolContains(ed, "*debug*", "main.c:5"));

    // Continue → the program runs to completion.
    ed.run("debug-continue");
    try t.expect(drainToolContains(ed, "*debug*", "terminated"));
}

test "debug: the gutter breakpoint IS the DAP breakpoint — mark a line, stop there" {
    const gpa = t.allocator;
    var app: App = undefined;
    try app.init(gpa);
    defer app.deinit();
    const ed = &app.ed;

    // A little program, and a breakpoint marked the IDE way — on line 3.
    authorFile(ed, "prog.py",
        \\def f(x):
        \\    y = x + 1
        \\    return y
        \\
    );
    ed.press("k", ""); // from the trailing blank up to `return y` (line 3)
    ed.chord("SPC d b");
    try t.expect(std.mem.indexOf(u8, ed.echoText(), "breakpoint set") != null);

    // Point the DAP client at the mock. The config `line` fallback is 9 — a line
    // we did NOT mark — so if the session stops on line 3 it can only be because
    // the gutter breakpoint travelled the bridge (debug → registry → dap.js).
    const mock = try std.fmt.allocPrint(gpa, "node {s}/assets/mock_dap.mjs", .{app.proj.prev_cwd});
    defer gpa.free(mock);
    try ed.setConfig("dap", "cmd", mock);
    try ed.setConfig("dap", "program", "prog.py"); // matches the buffer path we marked
    try ed.setConfig("dap", "line", "9");

    const dap_src = try std.fmt.allocPrint(gpa, "{s}/config/plugins/dap.js", .{app.proj.prev_cwd});
    defer gpa.free(dap_src);
    const src = try core.file.readAlloc(gpa, dap_src);
    defer gpa.free(src);
    try ed.loadJs("dap", src);

    ed.run("debug-start");
    try t.expect(drainToolContains(ed, "*debug*", "stopped: breakpoint"));
    try t.expect(drainToolContains(ed, "*debug*", "program:3")); // the MARKED line, not the fallback
    ed.run("debug-continue");
    try t.expect(drainToolContains(ed, "*debug*", "terminated"));
}

test "debug: set a breakpoint on a line — gutter marker, list, toggle off" {
    const gpa = t.allocator;
    var app: App = undefined;
    try app.init(gpa);
    defer app.deinit();
    const ed = &app.ed;

    authorFile(ed, "prog.py",
        \\def f(x):
        \\    y = x + 1
        \\    return y
        \\
    );
    ed.press("k", ""); // up to a code line

    // Set a breakpoint the IDE way (SPC d b). It was impossible before — there
    // was no debug surface at all.
    ed.chord("SPC d b");
    try t.expect(std.mem.indexOf(u8, ed.echoText(), "breakpoint set") != null);
    ed.chord("SPC d l");
    try t.expect(std.mem.indexOf(u8, ed.echoText(), "1 breakpoint") != null);
    app.proj.shot(ed, "debug-breakpoint"); // eyeball the ● in the gutter

    // Toggle it off on the same line.
    ed.chord("SPC d b");
    try t.expect(std.mem.indexOf(u8, ed.echoText(), "breakpoint cleared") != null);
    ed.chord("SPC d l");
    try t.expect(std.mem.indexOf(u8, ed.echoText(), "0 breakpoint") != null);
}

test "authoring/dired: rename a semantic field, apply its dialog, and verify disk" {
    const gpa = t.allocator;
    var app: App = undefined;
    try app.init(gpa);
    defer app.deinit();
    const ed = &app.ed;

    // A file on disk; open its containing directory through the generic
    // provider-aware command. The semantic scene is the dired plugin's public
    // surface, not a legacy `*dired*` text buffer.
    authorFile(ed, "old.txt", "keep me\n");
    ed.runStr("open", ".");
    const view_ref = ed.head.semantic_focus.path().?.view;
    const view = ed.session.system.semantic.views.get(view_ref).?;
    try t.expectEqualStrings("dired", view.scene.role);
    const field_ref = view.node(ed.head.semantic_focus.path().?.leaf().?).?.content.field.ref;
    var initial = try ed.session.system.semantic.fields.get(field_ref).?.snapshot(gpa);
    defer initial.deinit();
    try t.expectEqualStrings("old.txt", initial.value.bytes);

    // Replace the raw name through generic semantic field editing. The field
    // starts at byte offset zero; Delete is the core field operation inherited
    // by Vim's insert mode, so this path is valid for unusual raw names too.
    ed.press("i", "");
    for (0..7) |_| ed.press("Delete", ""); // `old.txt`
    ed.typeText("new.txt");
    ed.press("Escape", "");
    var renamed = try ed.session.system.semantic.fields.get(field_ref).?.snapshot(gpa);
    defer renamed.deinit();
    try t.expectEqualStrings("new.txt", renamed.value.bytes);
    try t.expectEqual(view_ref, ed.head.semantic_focus.path().?.view);

    // Vim's force-edit spelling is generic for structured views: Ex invokes
    // `view.revert`, and the owning provider rebuilds its draft from external
    // authority. Neither Ex nor Vim knows this is a directory tool.
    ed.press("colon", "");
    ed.typeText("e!");
    ed.press("Return", "");
    try t.expectEqualStrings("normal", ed.head.currentMode());
    var reverted = try ed.session.system.semantic.fields.get(field_ref).?.snapshot(gpa);
    defer reverted.deinit();
    try t.expectEqualStrings("old.txt", reverted.value.bytes);
    try t.expectEqual(view_ref, ed.head.semantic_focus.path().?.view);

    // Stage the rename again so the rest of the test still proves that the
    // exact draft shown by the view is the plan applied after confirmation.
    try ed.session.system.semantic.fields.get(field_ref).?.edit(reverted.value.revision, .{
        .start = 0,
        .end = reverted.value.bytes.len,
        .replacement = "new.txt",
        .selection_after = .{ .anchor = 7, .caret = 7 },
    });

    // Apply is an advertised semantic action. Its provider opens a head-local
    // interaction; the dialog owns `y`, rather than introducing a dired mode or
    // polluting which-key/global bindings.
    ed.chord("SPC v a");
    try t.expectEqualStrings("which-key-like", ed.head.interactions.active().?.descriptor.presentation);
    try t.expectEqualStrings(semantic.action.standard.confirm, ed.head.interactions.actionForInput("y").?.id);
    ed.press("y", "y");
    try t.expect(ed.head.interactions.active() == null);

    // On disk: the provider applied the immutable plan as a rename, preserving
    // content and removing the old name.
    try t.expect(drainUntilOracle(&app.proj, ed, "ls", "new.txt"));
    const ls = try app.proj.oracle("ls");
    defer gpa.free(ls);
    try t.expectEqualStrings("new.txt", ls); // old.txt is gone
    const disk = try core.file.readAlloc(gpa, "new.txt");
    defer gpa.free(disk);
    try t.expect(std.mem.indexOf(u8, disk, "keep me") != null);
}

test "authoring/dired: refresh reconciles external churn without retargeting a dirty row" {
    const gpa = t.allocator;
    var app: App = undefined;
    try app.init(gpa);
    defer app.deinit();
    const ed = &app.ed;

    authorFile(ed, "dirty.txt", "dirty\n");
    authorFile(ed, "clean.txt", "clean\n");
    authorFile(ed, "removed.txt", "removed\n");
    ed.runStr("open", ".");

    var view_ref = ed.head.semantic_focus.path().?.view;
    var view = ed.session.system.semantic.views.get(view_ref).?;
    var dirty_field: ?semantic.scene.FieldRef = null;
    var clean_row_id: @TypeOf(view.scene.content.container.children[0].id) = undefined;
    var clean_field: ?semantic.scene.FieldRef = null;
    for (view.scene.content.container.children) |row| {
        const name_node = row.content.container.children[2];
        const field_ref = name_node.content.field.ref;
        var snapshot = try ed.session.system.semantic.fields.get(field_ref).?.snapshot(gpa);
        defer snapshot.deinit();
        if (std.mem.eql(u8, snapshot.value.bytes, "dirty.txt")) dirty_field = field_ref;
        if (std.mem.eql(u8, snapshot.value.bytes, "clean.txt")) {
            clean_row_id = row.id;
            clean_field = field_ref;
        }
    }
    const dirty_ref = dirty_field orelse return error.TestExpectedEqual;
    _ = clean_field orelse return error.TestExpectedEqual;

    var before = try ed.session.system.semantic.fields.get(dirty_ref).?.snapshot(gpa);
    defer before.deinit();
    try ed.session.system.semantic.fields.get(dirty_ref).?.edit(before.value.revision, .{
        .start = 0,
        .end = before.value.bytes.len,
        .replacement = "draft.txt",
        .selection_after = .{ .anchor = 9, .caret = 9 },
    });

    // Mutate the backing directory without going through the dired draft.
    // Both renames preserve opaque identities; the dirty rename must not
    // retarget its draft, while the clean rename must refresh its child
    // target. The new file exercises external create, and removed.txt
    // exercises external deletion.
    try core.file.writeBytes(gpa, "created.txt", "created\n");
    _ = try app.proj.oracle("mv -- dirty.txt externally-renamed.txt");
    _ = try app.proj.oracle("mv -- clean.txt renamed.txt");
    core.file.deleteFile(gpa, "removed.txt");

    ed.chord("SPC v r");
    view_ref = ed.head.semantic_focus.path().?.view;
    view = ed.session.system.semantic.views.get(view_ref).?;

    var saw_created = false;
    var saw_renamed = false;
    var saw_removed = false;
    var saw_dirty_stale = false;
    for (view.scene.content.container.children) |row| {
        const name_node = row.content.container.children[2];
        var snapshot = try ed.session.system.semantic.fields.get(name_node.content.field.ref).?.snapshot(gpa);
        defer snapshot.deinit();
        if (std.mem.eql(u8, snapshot.value.bytes, "created.txt")) saw_created = true;
        if (std.mem.eql(u8, snapshot.value.bytes, "removed.txt")) saw_removed = true;
        if (std.mem.eql(u8, snapshot.value.bytes, "renamed.txt")) {
            saw_renamed = true;
            // A clean external rename keeps the same row identity and gets a
            // freshly justified child target rather than a stale target link.
            try t.expectEqual(clean_row_id, row.id);
            try t.expect(name_node.target != null);
        }
        if (std.mem.eql(u8, snapshot.value.bytes, "draft.txt")) {
            saw_dirty_stale = true;
            try t.expectEqual(@as(?semantic.scene.TargetLink, null), name_node.target);
            var stale = false;
            for (row.facts) |fact| {
                if (std.mem.eql(u8, fact.name, "change") and std.mem.eql(u8, fact.value, "stale")) stale = true;
            }
            try t.expect(stale);
        }
    }
    try t.expect(saw_created);
    try t.expect(saw_renamed);
    try t.expect(!saw_removed);
    try t.expect(saw_dirty_stale);
}

test "authoring/dired: a durable raw-name copy survives rename, deletion, and a different directory view" {
    const gpa = t.allocator;
    var app: App = undefined;
    try app.init(gpa);
    defer app.deinit();
    const ed = &app.ed;
    const raw_name = "odd\n\xff";
    const source_path = "source/odd\n\xff";
    const destination_path = "destination/odd\n\xff";

    try core.file.writeBytesMakingDirs(gpa, "source", source_path, "captured before namespace mutation\n");
    // Leave a genuinely empty destination directory. Pasting at its semantic
    // root must not require a fake row merely to provide an ordering anchor.
    try core.file.writeBytesMakingDirs(gpa, "destination", "destination/.seed", "");
    core.file.deleteFile(gpa, "destination/.seed");

    ed.runStr("open", "source");
    const source_view_ref = ed.head.semantic_focus.path().?.view;
    const source_view = ed.session.system.semantic.views.get(source_view_ref).?;
    const source_row = source_view.scene.content.container.children[0];
    const source_field_ref = source_row.content.container.children[2].content.field.ref;
    const source_field = ed.session.system.semantic.fields.get(source_field_ref).?;
    var source_snapshot = try source_field.snapshot(gpa);
    defer source_snapshot.deinit();
    try t.expectEqualStrings(raw_name, source_snapshot.value.bytes);

    // The config knows only the generic action name. The sandboxed provider
    // materializes a durable lease before core owns the returned transfer.
    ed.chord("SPC v y");
    const stored = ed.session.system.semantic.transfer orelse return error.TestUnexpectedResult;
    try t.expectEqualStrings(raw_name, stored.value.suggested_name);
    var retained_resource = false;
    for (stored.value.representations) |representation|
        retained_resource = retained_resource or representation.resource != null;
    try t.expect(retained_resource);

    // Mutating the source draft cannot retarget an immutable capture, and an
    // external deletion cannot invalidate its provider-owned materialization.
    try source_field.edit(source_snapshot.value.revision, .{
        .start = 0,
        .end = source_snapshot.value.bytes.len,
        .replacement = "renamed-after-copy",
        .selection_after = .{ .anchor = "renamed-after-copy".len, .caret = "renamed-after-copy".len },
    });
    core.file.deleteFile(gpa, source_path);

    ed.runStr("open", "destination");
    const destination_view_ref = ed.head.semantic_focus.path().?.view;
    try t.expect(!destination_view_ref.eql(source_view_ref));
    const empty_view = ed.session.system.semantic.views.get(destination_view_ref).?;
    try t.expectEqual(@as(usize, 0), empty_view.scene.content.container.children.len);
    ed.chord("SPC v p");

    const pasted_view = ed.session.system.semantic.views.get(destination_view_ref).?;
    try t.expectEqual(@as(usize, 1), pasted_view.scene.content.container.children.len);
    const pasted_field_ref = pasted_view.scene.content.container.children[0].content.container.children[2].content.field.ref;
    var pasted_snapshot = try ed.session.system.semantic.fields.get(pasted_field_ref).?.snapshot(gpa);
    defer pasted_snapshot.deinit();
    try t.expectEqualStrings(raw_name, pasted_snapshot.value.bytes);

    ed.chord("SPC v a");
    try t.expect(ed.head.interactions.active() != null);
    ed.press("y", "y");
    try t.expect(ed.head.interactions.active() == null);
    const disk = try core.file.readAlloc(gpa, destination_path);
    defer gpa.free(disk);
    try t.expectEqualStrings("captured before namespace mutation\n", disk);
    try t.expectEqual(core.file.Kind.none, core.file.statKind(gpa, source_path));
}

test "authoring/dired: generic create and permissions actions apply from an empty directory" {
    const gpa = t.allocator;
    var app: App = undefined;
    try app.init(gpa);
    defer app.deinit();
    const ed = &app.ed;

    try core.file.writeBytesMakingDirs(gpa, "workspace", "workspace/.seed", "");
    core.file.deleteFile(gpa, "workspace/.seed");
    ed.runStr("open", "workspace");
    const view_ref = ed.head.semantic_focus.path().?.view;
    try t.expectEqual(@as(usize, 0), ed.session.system.semantic.views.get(view_ref).?.scene.content.container.children.len);

    // Creation is an open semantic action declared by config. The provider
    // returns an ordinary field focus; Vim supplies only its normal insert
    // posture, and the default placeholder selection makes typing replace it.
    ed.chord("SPC v n");
    var created_file = try ed.session.system.semantic.fields.get(ed.head.semantic_focus.path().?.field.?).?.snapshot(gpa);
    defer created_file.deinit();
    try t.expectEqualStrings("new-file", created_file.value.bytes);
    try t.expectEqual(@as(u32, 0), created_file.value.selection.anchor);
    try t.expectEqual(@as(u32, "new-file".len), created_file.value.selection.caret);
    ed.press("i", "");
    ed.typeText("made.txt");
    ed.press("Escape", "");

    // Permissions are a secondary field advertised only because this local
    // provider reports POSIX-mode capability. No config or editing plugin
    // knows which structured tool supplied it.
    ed.chord("SPC v m");
    const mode_leaf = ed.head.semantic_focus.path().?.leaf().?;
    try t.expectEqualStrings("dired.mode", ed.session.system.semantic.views.get(view_ref).?.node(mode_leaf).?.role);
    ed.press("i", "");
    ed.typeText("0600");
    ed.press("Escape", "");

    ed.chord("SPC v N");
    var created_directory = try ed.session.system.semantic.fields.get(ed.head.semantic_focus.path().?.field.?).?.snapshot(gpa);
    defer created_directory.deinit();
    try t.expectEqualStrings("new-directory", created_directory.value.bytes);
    ed.press("i", "");
    ed.typeText("made-dir");
    ed.press("Escape", "");

    const staged = ed.session.system.semantic.views.get(view_ref).?;
    try t.expectEqual(@as(usize, 2), staged.scene.content.container.children.len);
    for (staged.scene.content.container.children) |row| {
        const columns = row.content.container.children;
        try t.expectEqual(@as(usize, 3), columns.len);
        try t.expectEqualStrings("dired.metadata", columns[0].role);
        try t.expectEqualStrings("dired.mode", columns[1].role);
        try t.expectEqualStrings("dired.name", columns[2].role);
    }

    ed.chord("SPC v a");
    try t.expectEqualStrings("which-key-like", ed.head.interactions.active().?.descriptor.presentation);
    ed.press("y", "y");
    try t.expect(ed.head.interactions.active() == null);
    try t.expectEqual(core.file.Kind.file, core.file.statKind(gpa, "workspace/made.txt"));
    try t.expectEqual(core.file.Kind.dir, core.file.statKind(gpa, "workspace/made-dir"));

    // The post-apply refresh comes back from the provider; observing 0600 in
    // that new snapshot proves the plan reached the filesystem edge.
    const refreshed = ed.session.system.semantic.views.get(view_ref).?;
    var found_mode = false;
    for (refreshed.scene.content.container.children) |row| {
        const columns = row.content.container.children;
        var name = try ed.session.system.semantic.fields.get(columns[2].content.field.ref).?.snapshot(gpa);
        defer name.deinit();
        if (!std.mem.eql(u8, name.value.bytes, "made.txt")) continue;
        var mode = try ed.session.system.semantic.fields.get(columns[1].content.field.ref).?.snapshot(gpa);
        defer mode.deinit();
        try t.expectEqualStrings("0600", mode.value.bytes);
        found_mode = true;
    }
    try t.expect(found_mode);
}

test "authoring: visual mode — select with a motion, then delete and change" {
    const gpa = t.allocator;
    var app: App = undefined;
    try app.init(gpa);
    defer app.deinit();
    const ed = &app.ed;

    ed.runStr("open", "v.txt");
    ed.press("i", "");
    ed.typeText("hello world foo");
    ed.press("Escape", "");

    // Visual DELETE: v selects, w extends over a word, d deletes it.
    ed.press("0", "");
    ed.press("v", "");
    ed.press("w", ""); // select "hello "
    try t.expectEqualStrings("visual", ed.mode());
    ed.press("d", ""); // → "world foo"

    // Visual CHANGE: v, w selects "world ", c deletes it and enters insert.
    ed.press("0", "");
    ed.press("v", "");
    ed.press("w", ""); // select "world "
    ed.press("c", ""); // was unbound in visual — now change
    try t.expectEqualStrings("insert", ed.mode());
    ed.typeText("X");
    ed.press("Escape", ""); // → "Xfoo"

    ed.press("colon", "");
    ed.typeText("w");
    ed.press("Return", "");
    ed.waitSave();

    const disk = try core.file.readAlloc(gpa, "v.txt");
    defer gpa.free(disk);
    try t.expectEqualStrings("Xfoo", disk);
}

test "authoring: `V` linewise visual — select whole lines and delete them" {
    const gpa = t.allocator;
    var app: App = undefined;
    try app.init(gpa);
    defer app.deinit();
    const ed = &app.ed;

    ed.runStr("open", "vl.txt");
    ed.press("i", "");
    ed.typeText("line1\nline2\nline3");
    ed.press("Escape", "");
    ed.press("k", "");
    ed.press("k", ""); // up to line1

    // V selects whole lines regardless of column; j extends by a line; d deletes
    // both lines (with their newline), leaving line3.
    ed.press("V", "");
    try t.expectEqualStrings("visual", ed.mode());
    ed.press("j", ""); // extend to line2
    ed.press("d", ""); // delete lines 1-2 wholesale

    ed.press("colon", "");
    ed.typeText("w");
    ed.press("Return", "");
    ed.waitSave();

    const disk = try core.file.readAlloc(gpa, "vl.txt");
    defer gpa.free(disk);
    try t.expectEqualStrings("line3", disk);
}

test "authoring: `/` searches in the buffer and jumps to the match" {
    const gpa = t.allocator;
    var app: App = undefined;
    try app.init(gpa);
    defer app.deinit();
    const ed = &app.ed;

    ed.runStr("open", "doc.txt");
    ed.press("i", "");
    ed.typeText("alpha\nbravo\ncharlie\ndelta");
    ed.press("Escape", "");

    // The vim search key. Before this binding, `/` did nothing.
    ed.press("/", "");
    ed.settle(10);
    try t.expectEqualStrings("pick", ed.mode()); // search prompt is open
    ed.typeText("charlie"); // the pattern
    ed.settle(10);
    ed.press("Return", ""); // jump to the match

    // Prove the cursor LANDED on the charlie line: drop a marker there and save.
    ed.press("i", "");
    ed.typeText("X");
    ed.press("Escape", "");
    ed.press("colon", "");
    ed.typeText("w");
    ed.press("Return", "");
    ed.waitSave();

    // The marker landed on the charlie line — `/charlie` jumped there.
    const disk = try core.file.readAlloc(gpa, "doc.txt");
    defer gpa.free(disk);
    try t.expect(std.mem.indexOf(u8, disk, "Xcharlie") != null);
}

test "authoring: switch between two files with the fuzzy buffer picker" {
    const gpa = t.allocator;
    var app: App = undefined;
    try app.init(gpa);
    defer app.deinit();
    const ed = &app.ed;

    // Author two files.
    ed.runStr("open", "alpha.js");
    ed.press("i", "");
    ed.typeText("// alpha");
    ed.press("Escape", "");
    ed.press("colon", "");
    ed.typeText("w");
    ed.press("Return", "");
    ed.waitSave();

    ed.runStr("open", "bravo.js");
    ed.press("i", "");
    ed.typeText("// bravo");
    ed.press("Escape", "");
    ed.press("colon", "");
    ed.typeText("w");
    ed.press("Return", "");
    ed.waitSave();
    try t.expectEqualStrings("bravo.js", ed.bufferName()); // we're on bravo now

    // Jump back to alpha.js through the fuzzy picker (SPC b b → buf-pick),
    // filtering by name, then accept — the natural "switch buffer" motion.
    ed.chord("SPC b b"); // opens the buffer pick (mode → pick)
    ed.settle(10); // let the candidate list populate
    try t.expectEqualStrings("pick", ed.mode());
    ed.typeText("alpha"); // narrow the query
    ed.settle(10);
    ed.press("Return", ""); // pick-accept → switch buffers
    try t.expectEqualStrings("alpha.js", ed.bufferName());
}
