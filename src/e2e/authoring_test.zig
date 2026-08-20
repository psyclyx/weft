//! e2e test file — a vim user authoring files through the REAL config: the ex
//! command line (`:w`), buffer-word completion (`C-n`), and fixing mistakes with
//! motions. Each small test drives what a person actually presses; where the
//! natural motion misbehaves, that's the SIGNAL to fix (not test around).

const std = @import("std");
const t = std.testing;
const h = @import("harness.zig");

const core = h.core;
const App = h.App;

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
