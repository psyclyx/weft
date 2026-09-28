//! e2e test file — undo steps are DECLARED (doc/undo.md): each shipped
//! grammar says what one step is, per mode (`mode.set-undo-step`), and
//! dispatch cuts the undo unit where it says. No motion, selection change or
//! mode change cuts anything by itself.
//!
//!   • config.js (vim): a normal-mode command is a step, and `insert`
//!     continues the step that entered it — `cw…Esc`, `o…Esc` are one `u`;
//!     `d` then `P` are two, however the caret moved;
//!   • helix.js: the same shape — a change and its insert session are one;
//!   • ide.js: a run of one command is a step — a word typed is one; a caret
//!     move ends it, so moving and typing again is a second.

const std = @import("std");
const t = std.testing;
const h = @import("harness.zig");
const chrome = @import("chrome_test.zig");
const ide = @import("ide_test.zig");

const Editor = h.Editor;
const GrammarApp = chrome.GrammarApp;
const expectText = ide.expectText;

/// Press each of `keys` as a key that commits itself (a letter in normal
/// mode is a command; in insert it types).
fn keys(ed: *Editor, seq: []const []const u8) void {
    for (seq) |k| ed.press(k, k);
}

// ── vim (config.js) ──────────────────────────────────────────────────

test "e2e/undo: config.js — cw and the typing after it are ONE step" {
    var app: GrammarApp = undefined;
    try app.init(t.allocator, "config.js", null);
    defer app.deinit();
    const ed = &app.ed;
    try app.open("u.txt", "one two\n");
    keys(ed, &.{ "c", "w" });
    ed.typeText("ONE");
    ed.press("Escape", "");
    try expectText(ed, "ONE two\n");
    ed.press("u", "u");
    try expectText(ed, "one two\n");
}

test "e2e/undo: config.js — d then P are TWO steps" {
    var app: GrammarApp = undefined;
    try app.init(t.allocator, "config.js", null);
    defer app.deinit();
    const ed = &app.ed;
    try app.open("u.txt", "one two\n");
    keys(ed, &.{ "d", "w" });
    try expectText(ed, "two\n");
    keys(ed, &.{"P"});
    try expectText(ed, "one two\n");
    ed.press("u", "u");
    try expectText(ed, "two\n");
    ed.press("u", "u");
    try expectText(ed, "one two\n");
    // `x` twice with no motion between: still two commands, two steps (`0`
    // first — a motion, which is no step at all).
    keys(ed, &.{ "0", "x", "x" });
    try expectText(ed, "e two\n");
    ed.press("u", "u");
    try expectText(ed, "ne two\n");
}

test "e2e/undo: config.js — o and the line typed after it are ONE step; the next command is its own" {
    var app: GrammarApp = undefined;
    try app.init(t.allocator, "config.js", null);
    defer app.deinit();
    const ed = &app.ed;
    try app.open("u.txt", "one\n");
    keys(ed, &.{"o"});
    ed.typeText("two");
    ed.press("Escape", "");
    try expectText(ed, "one\ntwo\n");
    // `dd` right after `Esc`: its own step, not the typing's.
    keys(ed, &.{ "d", "d" });
    try expectText(ed, "one\n");
    ed.press("u", "u");
    try expectText(ed, "one\ntwo\n");
    ed.press("u", "u");
    try expectText(ed, "one\n");
    // And redo walks forward the same two steps.
    ed.press("C-r", "");
    try expectText(ed, "one\ntwo\n");
}

// ── helix (helix.js) ─────────────────────────────────────────────────

test "e2e/undo: helix.js — o and the typing after it are ONE step; d then P are TWO" {
    var app: GrammarApp = undefined;
    try app.init(t.allocator, "helix.js", null);
    defer app.deinit();
    const ed = &app.ed;
    try app.open("u.txt", "one two\n");
    keys(ed, &.{"o"});
    ed.typeText("three");
    ed.press("Escape", "");
    try expectText(ed, "one two\nthree\n");
    ed.press("u", "u");
    try expectText(ed, "one two\n");

    // `w` selects "one ", `d` deletes it, `P` pastes it back before the caret.
    keys(ed, &.{ "g", "g" });
    keys(ed, &.{ "w", "d" });
    try expectText(ed, "two\n");
    keys(ed, &.{"P"});
    try expectText(ed, "one two\n");
    ed.press("u", "u");
    try expectText(ed, "two\n");
    ed.press("u", "u");
    try expectText(ed, "one two\n");
}

// ── ide (ide.js) ─────────────────────────────────────────────────────

test "e2e/undo: ide.js — a word typed is ONE step; moving the caret and typing again is a second" {
    var app: GrammarApp = undefined;
    try app.init(t.allocator, "ide.js", null);
    defer app.deinit();
    const ed = &app.ed;
    try app.open("u.txt", "\n");
    ed.typeText("hello");
    try expectText(ed, "hello\n");
    ed.press("C-z", "");
    try expectText(ed, "\n");
    ed.press("C-y", "");
    try expectText(ed, "hello\n");

    // A caret move ends the run: typing after it is its own step.
    ed.press("Home", "");
    ed.typeText("say ");
    try expectText(ed, "say hello\n");
    ed.press("C-z", "");
    try expectText(ed, "hello\n");
    ed.press("C-z", "");
    try expectText(ed, "\n");

    // A run of Backspaces is one step too, apart from the typing before it.
    ed.typeText("abc");
    ed.press("BackSpace", "");
    ed.press("BackSpace", "");
    try expectText(ed, "a\n");
    ed.press("C-z", "");
    try expectText(ed, "abc\n");
    ed.press("C-z", "");
    try expectText(ed, "\n");
}
