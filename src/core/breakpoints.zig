//! breakpoints — a document's breakpoint set, ANCHORED.
//!
//! A breakpoint is a place in a document, not a line number. It lives as an
//! anchored span on that document's own `breakpoints` layer, so an edit ABOVE
//! it shifts it with the text like any other anchor; nothing holds a second,
//! staler copy that has to be kept in step. The layer is keyed `(document,
//! name)` and dropped with the buffer (`Layers.dropDoc`), so there is no
//! process-global registry to outlive an editor and no path key to go wrong.
//!
//! LINES ARE DERIVED, NEVER STORED. The DAP wire wants a line number; the
//! gutter provider wants a line number. Both call `lineCsv` at the moment they
//! need one, and it resolves the anchors at the current head — so a session
//! re-arms on the line the mark is on NOW, not the line it was on when the
//! mark was made.
//!
//! The layer carries no message and no placement: it is the MODEL. The visible
//! ● is a separate decoration the `debug` plugin republishes from this set —
//! rendering reads a picture, never the truth.

const std = @import("std");
const Document = @import("Document.zig");
const layers = @import("layers.zig");

pub const layer_name = "breakpoints";
const owner = "debug";

/// A document holds at most this many breakpoints — a bound, not an allocator.
pub const max = 128;

/// `doc`'s breakpoints as byte offsets at the current head, written into
/// `out`; returns how many. Unordered (the layer's insertion order).
pub fn offsets(ls: *const layers.Layers, doc: *const Document, out: []usize) usize {
    const layer = ls.find(doc, layer_name) orelse return 0;
    var n: usize = 0;
    var i: usize = 0;
    while (i < layer.spanCount() and n < out.len) : (i += 1) {
        out[n] = layer.resolvedSpan(i).start;
        n += 1;
    }
    return n;
}

pub fn count(ls: *const layers.Layers, doc: *const Document) usize {
    const layer = ls.find(doc, layer_name) orelse return 0;
    return layer.spanCount();
}

/// Replace `doc`'s breakpoints with `offs` (each anchored on publish).
pub fn set(gpa: std.mem.Allocator, ls: *layers.Layers, doc: *Document, offs: []const usize) !void {
    const layer = try ls.claim(gpa, doc, layer_name, .local, owner);
    var spans: [max]layers.SpanIn = undefined;
    const n = @min(offs.len, spans.len);
    for (offs[0..n], 0..) |o, i| spans[i] = .{ .start = o, .end = o, .kind = 0, .message = "" };
    try layer.publishSpans(gpa, spans[0..n]);
}

/// Toggle a breakpoint at `off`. Returns whether one is now SET there.
pub fn toggle(gpa: std.mem.Allocator, ls: *layers.Layers, doc: *Document, off: usize) !bool {
    var buf: [max]usize = undefined;
    var n = offsets(ls, doc, &buf);
    var cleared = false;
    var i: usize = 0;
    while (i < n) {
        if (buf[i] == off) {
            buf[i] = buf[n - 1];
            n -= 1;
            cleared = true;
        } else i += 1;
    }
    if (!cleared) {
        if (n == buf.len) return false;
        buf[n] = off;
        n += 1;
    }
    try set(gpa, ls, doc, buf[0..n]);
    return !cleared;
}

pub fn clear(gpa: std.mem.Allocator, ls: *layers.Layers, doc: *Document) void {
    set(gpa, ls, doc, &.{}) catch {};
}

/// `doc`'s breakpoint LINES (1-based, ascending) as a "l1,l2,…" CSV written
/// into `out` — derived from the anchors at the current head, at the moment
/// the caller needs a line. Empty when there are none.
pub fn lineCsv(ls: *const layers.Layers, doc: *const Document, out: []u8) []const u8 {
    var offs: [max]usize = undefined;
    const n = offsets(ls, doc, &offs);
    const rope = doc.text();
    var lines: [max]usize = undefined;
    for (offs[0..n], 0..) |o, i| lines[i] = rope.offsetToPoint(@min(o, rope.byteLen())).row + 1;
    std.mem.sort(usize, lines[0..n], {}, std.sort.asc(usize));

    var w: usize = 0;
    for (lines[0..n]) |line| {
        var num: [16]u8 = undefined;
        const s = std.fmt.bufPrint(&num, "{d}", .{line}) catch continue;
        if (w != 0) {
            if (w + 1 > out.len) break;
            out[w] = ',';
            w += 1;
        }
        if (w + s.len > out.len) break;
        @memcpy(out[w .. w + s.len], s);
        w += s.len;
    }
    return out[0..w];
}

test "breakpoints: an edit above a breakpoint moves its line, not its identity" {
    const gpa = std.testing.allocator;
    var doc = try Document.init(gpa, "peer");
    defer doc.deinit(gpa);
    try doc.insert(gpa, 0, "one\ntwo\nthree\n");

    var ls: layers.Layers = .empty;
    defer ls.deinit(gpa);

    // Mark line 3 ("three"), by its offset.
    const three = doc.text().pointToOffset(.{ .row = 2, .col = 0 });
    try std.testing.expect(try toggle(gpa, &ls, &doc, three));
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("3", lineCsv(&ls, &doc, &buf));

    // Insert a whole line ABOVE it: the DERIVED line follows the text.
    try doc.insert(gpa, 0, "zero\n");
    try std.testing.expectEqualStrings("4", lineCsv(&ls, &doc, &buf));

    // Toggling at the anchor's CURRENT offset clears it — one identity, not two.
    var offs: [max]usize = undefined;
    try std.testing.expectEqual(@as(usize, 1), offsets(&ls, &doc, &offs));
    try std.testing.expect(!try toggle(gpa, &ls, &doc, offs[0]));
    try std.testing.expectEqual(@as(usize, 0), count(&ls, &doc));
    try std.testing.expectEqualStrings("", lineCsv(&ls, &doc, &buf));
}
