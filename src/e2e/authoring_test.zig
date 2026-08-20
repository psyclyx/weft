//! e2e test file — a vim user authoring files through the REAL config: the ex
//! command line (`:w`), buffer-word completion (`C-n`), and fixing mistakes with
//! motions. Each small test drives what a person actually presses; where the
//! natural motion misbehaves, that's the SIGNAL to fix (not test around).

const std = @import("std");
const t = std.testing;
const h = @import("harness.zig");

const core = h.core;
const App = h.App;
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
    ed.settle(60); // the formatter runs async (procFilter)

    ed.press("colon", "");
    ed.typeText("w");
    ed.press("Return", "");
    ed.waitSave();

    const disk = try core.file.readAlloc(gpa, "fmt_me.zig");
    defer gpa.free(disk);
    try t.expectEqualStrings("const x = 1;\n", disk); // zig fmt's canonical form
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

test "authoring/dired: rename a file in place — edit the name, :w, confirm the plan" {
    const gpa = t.allocator;
    var app: App = undefined;
    try app.init(gpa);
    defer app.deinit();
    const ed = &app.ed;

    // A file on disk; open the directory editor.
    authorFile(ed, "old.txt", "keep me\n");
    ed.run("dired");
    try t.expect(drainToolContains(ed, "*dired*", "old.txt"));

    // Rename IN PLACE: jump to the name (/), change the word old→new, as if it
    // were any text buffer (the editable projection).
    ed.press("/", "");
    ed.settle(10);
    ed.typeText("old");
    ed.settle(10);
    ed.press("Return", "");
    ed.press("c", "");
    ed.press("w", "");
    ed.typeText("new");
    ed.press("Escape", "");
    try t.expect(drainToolContains(ed, "*dired*", "new.txt")); // the buffer shows the new name

    // Save RECONCILES, but safely: it previews an ordered plan behind a y/n
    // confirm rather than touching the disk blind.
    ed.press("colon", "");
    ed.typeText("w");
    ed.press("Return", "");
    try t.expectEqualStrings("dired-confirm", ed.mode());
    {
        const plan = toolText(ed, "*dired-plan*") orelse return error.NoPlan;
        defer gpa.free(plan);
        try t.expect(std.mem.indexOf(u8, plan, "rename") != null);
        try t.expect(std.mem.indexOf(u8, plan, "old.txt") != null);
        try t.expect(std.mem.indexOf(u8, plan, "new.txt") != null);
    }
    ed.press("y", ""); // apply the plan

    // On disk: the file was RENAMED (not copied/deleted), content preserved.
    try t.expect(drainUntilOracle(&app.proj, ed, "ls", "new.txt"));
    const ls = try app.proj.oracle("ls");
    defer gpa.free(ls);
    try t.expectEqualStrings("new.txt", ls); // old.txt is gone
    const disk = try core.file.readAlloc(gpa, "new.txt");
    defer gpa.free(disk);
    try t.expect(std.mem.indexOf(u8, disk, "keep me") != null);
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
