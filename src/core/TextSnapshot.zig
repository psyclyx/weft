//! TextSnapshot — a text entry as a frame reads it, at one revision
//! (doc/model.md §2.7): the rope, the selections, and what the folds hide.
//!
//! The rope is `stemma.Rope.snapshot` — O(1), a refcount bump, the same
//! handle a save hands its worker — and the selections and folds are
//! resolved to offsets once, when the snapshot is taken. An `Editor` resolves
//! them through the document's live anchors every time it is asked, so a
//! renderer reading one while anything edits could draw text from one
//! version and carets from the next. Nothing here refers back to the editor
//! or the document: an edit after `of` changes the document, never the
//! snapshot, which is what lets a frame be a pure function of its input.
//!
//! What it does NOT assume: that the document is local. A revision is an
//! equality token (`Document.Revision`), the rope is a value, and the rest is
//! plain offsets — a peer's view could arrive as exactly this.

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const stemma = @import("stemma");
const Document = @import("Document.zig");
const Editor = @import("Editor.zig");

const Range = stemma.Range;
const TextSnapshot = @This();

rope: stemma.Rope,
/// The revision the snapshot was taken at: what cached answers about this
/// entry are keyed by.
revision: Document.Revision,
/// Every selection, in document order. Never empty.
selections: []const Editor.Ends,
/// Which of `selections` is the primary — the caret a single-cursor reader
/// means.
primary: usize,
/// The byte ranges folds make invisible (`Editor.rowHidden`'s spans).
hidden: []const Range,

/// Take `editor` as it is now. The selection and fold lists go in `arena`;
/// the rope is a refcounted handle the caller `release`s.
pub fn of(editor: *const Editor, arena: Allocator) Allocator.Error!TextSnapshot {
    const selections = try arena.alloc(Editor.Ends, editor.selectionCount());
    for (selections, 0..) |*s, i| s.* = editor.selectionEnds(i);
    var hidden: std.ArrayList(Range) = .empty;
    if (editor.fold_layer) |layer| {
        for (0..layer.spanCount()) |i| {
            const s = layer.resolvedSpan(i);
            if (s.face.invisible and s.end > s.start) try hidden.append(arena, .{ .start = s.start, .end = s.end });
        }
    }
    return .{
        .rope = editor.text().snapshot(),
        .revision = editor.doc.revision(),
        .selections = selections,
        .primary = editor.primary,
        .hidden = hidden.items,
    };
}

/// Drop the rope handle (`gpa` is the document's allocator: the last handle
/// to a rope version frees it).
pub fn release(self: *TextSnapshot, gpa: Allocator) void {
    self.rope.deinit(gpa);
    self.* = undefined;
}

pub fn text(self: *const TextSnapshot) *const stemma.Rope {
    return &self.rope;
}

pub fn selectionCount(self: *const TextSnapshot) usize {
    return self.selections.len;
}

/// Selection `i`'s endpoints; a caret reports `anchor == head`.
pub fn selectionEnds(self: *const TextSnapshot, i: usize) Editor.Ends {
    return self.selections[i];
}

/// Selection `i`'s text range, or null when it is a caret.
pub fn selectionRange(self: *const TextSnapshot, i: usize) ?Range {
    const e = self.selections[i];
    if (e.anchor == e.head) return null;
    return .{ .start = @min(e.anchor, e.head), .end = @max(e.anchor, e.head) };
}

/// The primary selection's head.
pub fn cursorOffset(self: *const TextSnapshot) usize {
    return self.selections[self.primary].head;
}

/// Is `row` hidden by a fold (its line start inside an invisible range)?
pub fn rowHidden(self: *const TextSnapshot, row: usize) bool {
    return self.hiderOf(row) != null;
}

fn hiderOf(self: *const TextSnapshot, row: usize) ?Range {
    if (self.hidden.len == 0) return null;
    const start = self.rope.lineRange(row).start;
    for (self.hidden) |h| if (start >= h.start and start < h.end) return h;
    return null;
}

/// Rows either side of what a pane shows that its per-byte inputs (syntax
/// paint, markdown attributes, layer snapshots) still cover.
pub const window_margin = 100;

/// The byte range a pane scrolled to `top_row` with `body_rows` rows draws
/// from: `window_margin` rows above, the rows it shows — walked past folds,
/// so a fold that hides a thousand rows cannot push the last shown row out
/// of it — then `window_margin` more, and never fewer than 200 rows below
/// the top. Every per-byte input sizes itself from this, so its cost follows
/// the viewport, not the file.
pub fn window(self: *const TextSnapshot, top_row: usize, body_rows: usize) Range {
    const rows = self.rope.lineCount();
    assert(rows > 0);
    var row = @min(top_row, rows - 1);
    var shown: usize = 0;
    while (row < rows and shown < body_rows) {
        if (self.hiderOf(row)) |h| {
            // Jump the whole fold: the first row whose start is past it.
            var next = self.rope.offsetToPoint(h.end).row;
            if (self.rope.lineRange(next).start < h.end) next += 1;
            row = @max(next, row + 1);
            continue;
        }
        shown += 1;
        row += 1;
    }
    const first = top_row -| window_margin;
    const last = @min(rows - 1, @max(top_row + 200, row + window_margin));
    return .{ .start = self.rope.lineRange(@min(first, rows - 1)).start, .end = self.rope.lineRange(last).end };
}

// ── Tests ───────────────────────────────────────────────────────────

const t = std.testing;
const layers = @import("layers.zig");
const task = @import("task.zig");

test "TextSnapshot: an edit after the snapshot moves the editor, never the snapshot" {
    const gpa = t.allocator;
    const pool = try task.Pool.init(gpa, .{ .threads = 1 });
    defer pool.deinit();
    var ed = try Editor.init(gpa, pool, "user");
    defer ed.deinit(gpa);
    try ed.insertText(gpa, "one\ntwo\nthree\n");
    try ed.setSelections(gpa, &.{ .{ .anchor = 0, .head = 3 }, .{ .anchor = 8, .head = 8 } }, 1);

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var snap = try TextSnapshot.of(&ed, arena.allocator());
    defer snap.release(gpa);

    try ed.insertText(gpa, "XX");
    try t.expect(ed.doc.revision() != snap.revision);
    try t.expectEqual(@as(usize, 14), snap.text().byteLen());
    try t.expectEqual(@as(usize, 8), snap.cursorOffset());
    try t.expectEqual(@as(usize, 2), snap.selectionCount());
    try t.expectEqual(Range{ .start = 0, .end = 3 }, snap.selectionRange(0).?);
    try t.expect(snap.selectionRange(1) == null);
}

test "TextSnapshot: folds hide rows, and the window walks past them" {
    const gpa = t.allocator;
    const pool = try task.Pool.init(gpa, .{ .threads = 1 });
    defer pool.deinit();
    var ed = try Editor.init(gpa, pool, "user");
    defer ed.deinit(gpa);
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(gpa);
    for (0..2000) |i| try body.print(gpa, "row {d}\n", .{i});
    try ed.insertText(gpa, body.items);

    var store: layers.Layers = .empty;
    defer store.deinit(gpa);
    const folds = try store.claim(gpa, &ed.doc, "folds", .local, "test");
    // Rows 2..=900 folded away.
    const from = ed.text().lineRange(2).start;
    const to = ed.text().lineRange(901).start;
    try folds.appendSpan(gpa, .{ .start = from, .end = to, .kind = 0, .message = "", .face = .{ .invisible = true } });
    ed.fold_layer = folds;

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var snap = try TextSnapshot.of(&ed, arena.allocator());
    defer snap.release(gpa);
    try t.expect(!snap.rowHidden(1));
    try t.expect(snap.rowHidden(2));
    try t.expect(snap.rowHidden(900));
    try t.expect(!snap.rowHidden(901));
    // Ten rows shown from the top end at row 908; the window covers them and
    // the margin past the row after.
    const w = snap.window(0, 10);
    try t.expectEqual(@as(usize, 0), w.start);
    try t.expectEqual(snap.text().lineRange(909 + window_margin).end, w.end);
}
