//! e2e test file — indentation as a person meets it (src/plugins/indent):
//! the step each file uses, picked up from the file; Return landing the
//! caret where the code goes; a closer typed on its own line finding its
//! opener's column; and the escape hatches — undo takes back just the
//! adjustment, a paste is never re-indented, an indent left on a blank line
//! goes away. Driven through the real configs (vim's config.js, ide.js) and
//! the keys a person presses.

const std = @import("std");
const t = std.testing;
const h = @import("harness.zig");
const ide = @import("ide_test.zig");

const core = h.core;
const App = h.App;
const Editor = h.Editor;

/// Put `body` on disk as `name` and open it, the caret at its start.
fn openFile(ed: *Editor, name: []const u8, body: []const u8) !void {
    try core.file.writeBytes(ed.gpa, name, body);
    ed.runStr("file.open", name);
}

fn expectText(ed: *Editor, want: []const u8) !void {
    const got = try ed.textAlloc();
    defer ed.gpa.free(got);
    try t.expectEqualStrings(want, got);
}

fn caret(ed: *Editor) usize {
    return ed.buffers.active().textEditor().?.cursorOffset();
}

test "e2e/indent: Return after an opener indents a step; between a pair the closer gets its own line" {
    const gpa = t.allocator;
    var app: App = undefined;
    try app.init(gpa);
    defer app.deinit();
    const ed = &app.ed;

    // A new zig file says nothing yet, so config's `zig` step (four spaces)
    // is the one. `{` pairs (autopair), Return splits the pair.
    ed.runStr("file.open", "split.zig");
    ed.press("i", "");
    ed.typeText("fn f() {");
    try expectText(ed, "fn f() {}");
    ed.press("Return", "");
    try expectText(ed, "fn f() {\n    \n}");
    try t.expectEqual(@as(usize, "fn f() {\n    ".len), caret(ed));
    ed.typeText("return;");
    try expectText(ed, "fn f() {\n    return;\n}");

    // The next Return carries the indentation over.
    ed.press("Return", "");
    ed.typeText("x();");
    try expectText(ed, "fn f() {\n    return;\n    x();\n}");

    // Inside a call: `(` opens a step too; the closer after the caret goes
    // to the line that opened it.
    ed.typeText("\ng(");
    ed.press("Return", "");
    try expectText(ed, "fn f() {\n    return;\n    x();\n    g(\n        \n    )\n}");
}

test "e2e/indent: a closer typed first on its line goes to its opener's column (electric)" {
    const gpa = t.allocator;
    var app: App = undefined;
    try app.init(gpa);
    defer app.deinit();
    const ed = &app.ed;

    try openFile(ed, "electric.js", "if (a) {\n  b();");
    ed.press("G", "");
    ed.press("A", "");
    ed.press("Return", "");
    try expectText(ed, "if (a) {\n  b();\n  ");
    ed.typeText("}");
    try expectText(ed, "if (a) {\n  b();\n}");
    try t.expectEqual(@as(usize, "if (a) {\n  b();\n}".len), caret(ed));

    // Not first on its line: left where it was typed.
    ed.typeText(" else { c(); }");
    try expectText(ed, "if (a) {\n  b();\n} else { c(); }");

    // `electric` off: the closer stays where it was typed.
    try ed.setConfig("indent", "electric", "off");
    ed.press("Return", "");
    ed.typeText("  }");
    try expectText(ed, "if (a) {\n  b();\n} else { c(); }\n  }");
}

test "e2e/indent: the step comes from the file — a tab file's Tab is a tab, a four-space file's >> is four spaces" {
    const gpa = t.allocator;
    var app: App = undefined;
    try app.init(gpa);
    defer app.deinit();
    const ed = &app.ed;

    // A gofmt file: Return copies the tab, Tab adds one.
    try openFile(ed, "main.go", "package main\n\nfunc main() {\n\tx := 1\n}\n");
    ed.chord("g g 3 j"); // `\tx := 1`
    ed.press("A", "");
    ed.press("Return", "");
    ed.press("Tab", "\t");
    ed.typeText("y");
    try expectText(ed, "package main\n\nfunc main() {\n\tx := 1\n\t\ty\n}\n");
    ed.press("Escape", "");

    // A python file indented by four (no config for `py`): `>>` adds four.
    try openFile(ed, "four.py", "def f():\n    return 1\n");
    ed.chord("g g");
    ed.chord("greater greater");
    try expectText(ed, "    def f():\n    return 1\n");
    ed.chord("less less");
    try expectText(ed, "def f():\n    return 1\n");

    // A text file indented by two, against config's (and the built-in) four.
    try openFile(ed, "two.txt", "a\n  b\n    c\n  d\n");
    ed.chord("g g");
    ed.chord("greater greater");
    try expectText(ed, "  a\n  b\n    c\n  d\n");

    // Tab in a spaces file steps to the next stop; Backspace in the
    // indentation takes a whole step back, and past the line's own.
    ed.press("o", "");
    try expectText(ed, "  a\n  \n  b\n    c\n  d\n");
    ed.press("Tab", "\t");
    try expectText(ed, "  a\n    \n  b\n    c\n  d\n");
    ed.press("BackSpace", "");
    try expectText(ed, "  a\n  \n  b\n    c\n  d\n");
    ed.press("BackSpace", "");
    try expectText(ed, "  a\n\n  b\n    c\n  d\n");
    ed.typeText("x\t");
    try expectText(ed, "  a\nx \n  b\n    c\n  d\n");
    ed.press("Escape", "");
    ed.chord("d d");

    // `indent.set` changes the buffer's step; `>>` follows it.
    ed.runStr("indent.set", "tabs");
    ed.chord("greater greater");
    try expectText(ed, "  a\n\t  b\n    c\n  d\n");
}

test "e2e/indent: an .editorconfig outranks what the file's lines say" {
    const gpa = t.allocator;
    var app: App = undefined;
    try app.init(gpa);
    defer app.deinit();
    const ed = &app.ed;

    try core.file.writeBytes(gpa, ".editorconfig",
        \\root = true
        \\[*]
        \\indent_style = space
        \\indent_size = 4
        \\[*.mk]
        \\indent_style = tab
        \\
    );
    // Two-space lines, but the project says four.
    try openFile(ed, "conf.txt", "a\n  b\n");
    ed.chord("g g");
    ed.chord("greater greater");
    try expectText(ed, "    a\n  b\n");
    // And tabs for `*.mk`.
    try openFile(ed, "rules.mk", "all:\n    true\n");
    ed.chord("g g");
    ed.chord("greater greater");
    try expectText(ed, "\tall:\n    true\n");
}

test "e2e/indent: an indent left on a blank line goes away — Escape, or Return again" {
    const gpa = t.allocator;
    var app: App = undefined;
    try app.init(gpa);
    defer app.deinit();
    const ed = &app.ed;

    // `o` under an opener lands a step in; leaving it blank takes it back.
    try openFile(ed, "blank.js", "function f() {\n}\n");
    ed.press("o", "");
    try expectText(ed, "function f() {\n  \n}\n");
    ed.press("Escape", "");
    try expectText(ed, "function f() {\n\n}\n");
    // The whole `o…Esc` is still one undo step.
    ed.press("u", "");
    try expectText(ed, "function f() {\n}\n");

    // Return on the blank indented line leaves it empty and carries the
    // indent down to the next one.
    ed.press("o", "");
    ed.press("Return", "");
    ed.typeText("x();");
    ed.press("Escape", "");
    try expectText(ed, "function f() {\n\n  x();\n}\n");

    // With `auto` off a line break is only a line break.
    try ed.setConfig("indent", "auto", "off");
    ed.press("o", "");
    ed.typeText("y");
    ed.press("Escape", "");
    try expectText(ed, "function f() {\n\n  x();\ny\n}\n");
}

test "e2e/indent: a paste is never re-indented" {
    const gpa = t.allocator;
    var app: App = undefined;
    try app.init(gpa);
    defer app.deinit();
    const ed = &app.ed;

    // A closer at an odd column, yanked and put under the block: it lands as
    // it was — only a closer TYPED is re-indented.
    try openFile(ed, "paste.js", "    }\nif (a) {\n  b();");
    ed.press("y", "");
    ed.press("y", "");
    ed.press("G", "");
    ed.press("p", "");
    try expectText(ed, "    }\nif (a) {\n  b();\n    }");
    // Text inserted rather than typed — a paste in insert mode — neither.
    ed.chord("g g");
    ed.press("i", "");
    ed.runStr("edit.insert-text", "x {\n}\n");
    ed.press("Escape", "");
    try expectText(ed, "x {\n}\n    }\nif (a) {\n  b();\n    }");
}

test "e2e/indent: in a modeless grammar, undo right after takes back just the adjustment" {
    const gpa = t.allocator;
    var app: ide.IdeApp = undefined;
    try app.init(gpa);
    defer app.deinit();
    const ed = &app.ed;

    try ide.openFile(ed, "undo.js", "if (a) {\n  b();\n");
    ed.press("C-End", "");
    ed.press("Up", "");
    ed.press("End", "");
    ed.press("Return", "");
    try ide.expectText(ed, "if (a) {\n  b();\n  \n");
    // The indent first, then the line break.
    ed.press("C-z", "");
    try ide.expectText(ed, "if (a) {\n  b();\n\n");
    ed.press("C-z", "");
    try ide.expectText(ed, "if (a) {\n  b();\n");

    // An electric dedent, likewise: undo puts the closer back where it was
    // typed, and the next undo takes the closer.
    ed.press("Return", "");
    ed.typeText("}");
    try ide.expectText(ed, "if (a) {\n  b();\n}\n");
    ed.press("C-z", "");
    try ide.expectText(ed, "if (a) {\n  b();\n  }\n");
    ed.press("C-z", "");
    try ide.expectText(ed, "if (a) {\n  b();\n  \n");
}

test "e2e/indent: O opens a line above where the code goes — what the line before leads to" {
    const gpa = t.allocator;
    var app: App = undefined;
    try app.init(gpa);
    defer app.deinit();
    const ed = &app.ed;

    try openFile(ed, "above.js", "function f() {\n  return 1;\n}\n");
    ed.chord("g g 2 j"); // `}`
    ed.press("O", "");
    ed.typeText("y();");
    ed.press("Escape", "");
    try expectText(ed, "function f() {\n  return 1;\n  y();\n}\n");
    // Above the first line there is no line before: a bare line.
    ed.chord("g g");
    ed.press("O", "");
    ed.typeText("// top");
    ed.press("Escape", "");
    try expectText(ed, "// top\nfunction f() {\n  return 1;\n  y();\n}\n");
}
