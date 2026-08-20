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
