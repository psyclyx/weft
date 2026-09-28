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

// ── The undo tree (undo_tree, config/undo.js) ────────────────────────

const projection = @import("projection_test.zig");
const NodeId = h.semantic_model.scene.NodeId;

/// Where `node` of the scene shown in `pane` was drawn — its hit's centre.
fn pointAtNodeIn(ed: *Editor, pane: u32, node: NodeId) ?[2]f32 {
    const v = ed.ensureView() catch return null;
    for (v.pane_maps[0..v.pane_map_count]) |m| {
        if (m.pane != pane) continue;
        for (m.hits) |hit| if (hit.node == node)
            return .{ hit.rect.x + hit.rect.w / 2, hit.rect.y + hit.rect.h / 2 };
    }
    return null;
}

/// Step `k` of the history, as the tree draws it (`undo_tree`'s `step_base`).
fn stepNode(k: u64) NodeId {
    return @enumFromInt(2 + k);
}

fn expectEditorText(ed: *Editor, doc: *h.core.Editor, want: []const u8) !void {
    const got = try doc.text().toOwnedSlice(ed.gpa);
    defer ed.gpa.free(got);
    try t.expectEqualStrings(want, got);
}

test "e2e/undo: config.js — SPC u shows the undo tree beside the editor; a click on the other branch brings the text there" {
    const gpa = t.allocator;
    var app: GrammarApp = undefined;
    try app.init(gpa, "config.js", null);
    defer app.deinit();
    const ed = &app.ed;
    try app.open("u.txt", "one\n");
    const doc = ed.buffers.active().textEditor().?;

    // Two branches from the start: " two" typed, undone, " three" typed.
    keys(ed, &.{"A"});
    ed.typeText(" two");
    ed.press("Escape", "");
    ed.press("u", "u");
    keys(ed, &.{"A"});
    ed.typeText(" three");
    ed.press("Escape", "");
    try expectEditorText(ed, doc, "one three\n");

    ed.chord("SPC u");
    ed.applyWindow();
    const pane = try chrome.viewportPane(ed, "undo");
    const entry = try projection.paneEntry(ed, pane);
    try t.expect(std.mem.startsWith(u8, entry.designationText(), "weft://here/undo-tree/"));
    {
        const text = try ed.semanticText(entry.scene_selection.view.?);
        defer gpa.free(text);
        try t.expect(std.mem.indexOf(u8, text, "1 + two") != null);
        try t.expect(std.mem.indexOf(u8, text, "2 + three") != null);
    }
    app.proj.shot(ed, "undo-tree");

    // A click on the undone branch: " three" leaves, " two" comes back.
    const at = pointAtNodeIn(ed, pane.pane().id, stepNode(1)) orelse return error.StepNotDrawn;
    ed.click(at);
    ed.applyWindow();
    try expectEditorText(ed, doc, "one two\n");
    try t.expectEqual(@as(u32, 1), doc.history.currentNode());
    // And back: every step is a click away.
    ed.click(pointAtNodeIn(ed, pane.pane().id, stepNode(2)) orelse return error.StepNotDrawn);
    ed.applyWindow();
    try expectEditorText(ed, doc, "one three\n");

    // By keys, in the grammar's own words for a listing: back through the
    // steps in the order they were taken — the other branch, then the
    // original — and activate it: the original text.
    try t.expect(ed.head.scene_selection.head() == stepNode(2));
    ed.press("k", "k");
    try t.expect(ed.head.scene_selection.head() == stepNode(1));
    ed.press("k", "k");
    try t.expect(ed.head.scene_selection.head() == stepNode(0));
    ed.press("Return", "");
    ed.applyWindow();
    try expectEditorText(ed, doc, "one\n");
    try t.expectEqual(@as(u32, 0), doc.history.currentNode());
}
