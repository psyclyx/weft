//! flash — the transient highlight over what an operation just touched
//! (vim-goggles: a yank, an indent, a paste, an undo).
//!
//! A flash is a SET of ranges, so one operation over several selections
//! flashes all of them at once, and it lives on its DOCUMENT as an anchored
//! `flash` layer — an edit that lands during the fade moves the highlight
//! with the text instead of leaving it over whatever slid under raw offsets.
//!
//! What core holds is the set and a generation; how long it shows is the
//! frame's business (it times the fade from the moment it sees a new
//! generation, reading `editor/flash-ms`), and whether an undo flashes at all
//! is the configuration's (`editor/flash-undo`). Core records the undo span
//! regardless because only core sees it — the grammar that pressed `u` never
//! learns which bytes came back — but in a set of its own, beside the edit
//! set rather than over it.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Document = @import("Document.zig");
const layers = @import("layers.zig");
const patch = @import("patch.zig");
const mapOffset = @import("position.zig").mapOffset;

pub const Range = Document.Range;

pub const layer_name = "flash";
const undo_layer_name = "flash-undo";
const owner = "core:flash";

/// What produced a set. The frame shows an `undo` flash only when the
/// configuration asks for one.
pub const Source = enum {
    edit,
    undo,

    fn layerName(self: Source) []const u8 {
        return switch (self) {
            .edit => layer_name,
            .undo => undo_layer_name,
        };
    }
};

/// The two sets are kept APART: an undo's set never replaces an edit's. With
/// `editor/flash-undo` off the frame never shows the undo set, and so an undo
/// pressed while a yank's flash fades cannot cut that fade short — there is no
/// shared set for it to overwrite (`showing` is where the frame chooses).
pub const Flash = struct {
    /// Bumped by every `set` of either source; zero means nothing has ever
    /// flashed. Each set records the value it was stamped with, so the newer
    /// of the two is a comparison.
    gen: u64 = 0,
    /// The source of the newest set.
    source: Source = .edit,
    sets: std.EnumArray(Source, Set) = .initFill(.{}),

    pub const Set = struct {
        /// The `gen` it was stamped with; zero for never.
        gen: u64 = 0,
        /// The document it lives on — compared, never dereferenced (a closed
        /// document's layer is dropped with it, so a stale pointer only ever
        /// finds no layer).
        doc: ?*const Document = null,
    };

    /// Replace `source`'s set with `r` on `doc` and start a new generation.
    pub fn set(self: *Flash, gpa: Allocator, ls: *layers.Layers, doc: *Document, r: Range, source: Source) !void {
        const layer = try ls.claim(gpa, doc, source.layerName(), .local, owner);
        const len = doc.text().byteLen();
        const lo = @min(r.start, r.end, len);
        try layer.publishSpans(gpa, &.{.{ .start = lo, .end = @min(@max(r.start, r.end), len), .kind = 0, .message = "" }});
        self.gen += 1;
        self.source = source;
        self.sets.set(source, .{ .gen = self.gen, .doc = doc });
    }

    /// Add `r` to the edit set — same generation, so it fades with the rest.
    /// A set on another document (or none yet) is replaced instead.
    pub fn add(self: *Flash, gpa: Allocator, ls: *layers.Layers, doc: *Document, r: Range) !void {
        const s = self.sets.get(.edit);
        if (s.gen == 0 or s.doc != doc) return self.set(gpa, ls, doc, r, .edit);
        const layer = ls.find(doc, layer_name) orelse return self.set(gpa, ls, doc, r, .edit);
        const len = doc.text().byteLen();
        try layer.appendSpan(gpa, .{ .start = @min(r.start, r.end, len), .end = @min(@max(r.start, r.end), len), .kind = 0, .message = "" });
    }

    /// The set a frame shows: the undo set when `show_undo` and it is the
    /// newer of the two, else the edit set.
    pub fn showing(self: *const Flash, show_undo: bool) Source {
        return if (show_undo and self.sets.get(.undo).gen > self.sets.get(.edit).gen) .undo else .edit;
    }

    /// The generation `source`'s set was stamped with (zero for never): what
    /// a frame times that set's fade from.
    pub fn genOf(self: *const Flash, source: Source) u64 {
        return self.sets.get(source).gen;
    }

    /// The newest set on `doc` at the current head, written into `out`.
    pub fn ranges(self: *const Flash, ls: *const layers.Layers, doc: *const Document, out: []Range) []Range {
        return self.rangesOf(self.source, ls, doc, out);
    }

    /// `source`'s set on `doc` at the current head, written into `out`;
    /// empty when that set lives on another document.
    pub fn rangesOf(self: *const Flash, source: Source, ls: *const layers.Layers, doc: *const Document, out: []Range) []Range {
        const s = self.sets.get(source);
        if (s.gen == 0 or s.doc != doc) return out[0..0];
        const layer = ls.find(doc, source.layerName()) orelse return out[0..0];
        var n: usize = 0;
        while (n < layer.spanCount() and n < out.len) : (n += 1) {
            const sp = layer.resolvedSpan(n);
            out[n] = .{ .start = sp.start, .end = sp.end };
        }
        return out[0..n];
    }

    /// How many ranges `source`'s set holds on `doc` — what a caller sizes
    /// `rangesOf`'s buffer to.
    pub fn countOf(self: *const Flash, source: Source, ls: *const layers.Layers, doc: *const Document) usize {
        const s = self.sets.get(source);
        if (s.gen == 0 or s.doc != doc) return 0;
        return (ls.find(doc, source.layerName()) orelse return 0).spanCount();
    }
};

/// The span the commits logged since `before` changed, in current-head
/// coordinates — what an undo or redo just put back. Earlier commits' spans
/// are carried through the later ones' patches, so a unit of several commits
/// reports one covering range. Null when nothing was committed; an empty
/// range (a pure deletion) is a real answer: the place the text left.
pub fn changedSince(doc: *const Document, before: usize) ?Range {
    var span: ?Range = null;
    var j = before;
    while (j < doc.commitCount()) : (j += 1) {
        const ps = doc.commitAt(j).patches;
        if (span) |*s| {
            s.start = mapOffset(ps, s.start, .left);
            s.end = @max(s.start, mapOffset(ps, s.end, .right));
        }
        for (ps, 0..) |p, k| {
            const a = patch.newOffsetOf(ps, k);
            const b = a + p.inserted;
            span = if (span) |s| .{ .start = @min(s.start, a), .end = @max(s.end, b) } else .{ .start = a, .end = b };
        }
    }
    return span;
}

// ── Tests ───────────────────────────────────────────────────────────

const t = std.testing;

test "flash: a set lives on its document and follows an edit" {
    const gpa = t.allocator;
    var doc = try Document.init(gpa, "user");
    defer doc.deinit(gpa);
    try doc.insert(gpa, 0, "alpha beta gamma\n");
    var ls: layers.Layers = .empty;
    defer ls.deinit(gpa);

    var f: Flash = .{};
    try f.set(gpa, &ls, &doc, .{ .start = 6, .end = 10 }, .edit);
    try f.add(gpa, &ls, &doc, .{ .start = 11, .end = 16 });
    try t.expectEqual(@as(u64, 1), f.gen);
    var buf: [4]Range = undefined;
    var got = f.ranges(&ls, &doc, &buf);
    try t.expectEqual(@as(usize, 2), got.len);
    try t.expectEqual(Range{ .start = 6, .end = 10 }, got[0]);

    // An edit before the set carries it along — it is anchored, not raw.
    try doc.insert(gpa, 0, ">> ");
    got = f.ranges(&ls, &doc, &buf);
    try t.expectEqual(Range{ .start = 9, .end = 13 }, got[0]);
    try t.expectEqual(Range{ .start = 14, .end = 19 }, got[1]);

    // Another document sees nothing of it.
    var other = try Document.init(gpa, "user");
    defer other.deinit(gpa);
    try t.expectEqual(@as(usize, 0), f.ranges(&ls, &other, &buf).len);

    // A new set starts a new generation.
    try f.set(gpa, &ls, &doc, .{ .start = 0, .end = 2 }, .undo);
    try t.expectEqual(@as(u64, 2), f.gen);
    try t.expectEqual(@as(usize, 1), f.ranges(&ls, &doc, &buf).len);
    try t.expectEqual(Source.undo, f.source);
}

test "flash: an undo's set sits beside the edit set — with flash-undo off it replaces nothing" {
    const gpa = t.allocator;
    var doc = try Document.init(gpa, "user");
    defer doc.deinit(gpa);
    try doc.insert(gpa, 0, "alpha beta\n");
    var ls: layers.Layers = .empty;
    defer ls.deinit(gpa);

    var f: Flash = .{};
    try f.set(gpa, &ls, &doc, .{ .start = 0, .end = 5 }, .edit); // a yank
    const yank = f.genOf(.edit);
    try f.set(gpa, &ls, &doc, .{ .start = 6, .end = 10 }, .undo); // then `u`
    var buf: [4]Range = undefined;
    // flash-undo off: the frame still shows the yank, at the yank's
    // generation, so its fade is not restarted or cut short.
    try t.expectEqual(Source.edit, f.showing(false));
    try t.expectEqual(yank, f.genOf(f.showing(false)));
    try t.expectEqual(Range{ .start = 0, .end = 5 }, f.rangesOf(.edit, &ls, &doc, &buf)[0]);
    // flash-undo on: the undo is newer, so it shows.
    try t.expectEqual(Source.undo, f.showing(true));
    try t.expectEqual(Range{ .start = 6, .end = 10 }, f.rangesOf(.undo, &ls, &doc, &buf)[0]);
    try t.expectEqual(@as(usize, 1), f.countOf(.undo, &ls, &doc));
    // A later edit flash is the newest again, either way.
    try f.set(gpa, &ls, &doc, .{ .start = 1, .end = 2 }, .edit);
    try t.expectEqual(Source.edit, f.showing(true));
}

test "flash: changedSince reports what the new commits put back" {
    const gpa = t.allocator;
    var doc = try Document.init(gpa, "user");
    defer doc.deinit(gpa);
    try doc.insert(gpa, 0, "one two three\n");
    const before = doc.commitCount();
    try t.expect(changedSince(&doc, before) == null);
    try doc.insert(gpa, 4, "and ");
    try doc.insert(gpa, 0, "> ");
    // "and " went in at 4, then "> " at 0 shifted it to 6: the union covers
    // both, in current coordinates.
    try t.expectEqual(Range{ .start = 0, .end = 10 }, changedSince(&doc, before).?);
}
