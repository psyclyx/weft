//! Where each status segment goes when the row is too short (doc/chrome.md
//! §4.2) — a pure function of the segments' measures and the row's width, so
//! what a narrow pane shows is decided in ONE place, deterministically, and
//! tested without drawing anything.
//!
//! Segments sit in two clusters: `left` from the row's start, `right` ending
//! at its end. Every segment has a priority (who keeps its room longest), a
//! full form and, optionally, a compact one. When the row is too short, the
//! segments yield in order of priority, lowest first, each as little as
//! makes the row fit and no less than it must:
//!
//!   - one whose text may be cut short (`elide`) is cut to exactly what
//!     fits, ending (or starting) in `…`, when that leaves it at least
//!     `min_elided` cells — more of its text than its compact form would;
//!   - else it shrinks to its compact form, when that makes the row fit;
//!   - else it goes, and the next one yields.
//!
//! So a low-priority segment goes whole before a higher one so much as
//! shortens, and the two clusters draw from one budget: a high-priority
//! segment on the right (`Ln 12, Col 4`) outlives a low-priority one on the
//! left. Equal priorities yield later-drawn first. Widths are cells of the
//! mono grid — one per codepoint, the unit every status run is placed in —
//! so a cut is always between two codepoints, never inside one.

const std = @import("std");

pub const Side = enum { left, right };

/// Which end of a segment's text an elision removes.
pub const Elide = enum {
    /// Never cut: the segment goes whole.
    none,
    /// Keep the start (`a message th…`) — prose.
    end,
    /// Keep the end (`…view/status.zig`) — a path, whose tail names it.
    start,
};

/// One segment's measures.
pub const Item = struct {
    side: Side = .left,
    /// Higher keeps its room longer.
    priority: i32 = 0,
    /// Cells of the full form (at least one; an empty segment is not laid out).
    full: usize,
    /// Cells of the compact form; null when it has none.
    compact: ?usize = null,
    elide: Elide = .none,
};

pub const Form = enum { full, compact, elided, dropped };

/// Where one segment landed.
pub const Placed = struct {
    form: Form = .dropped,
    /// Its first cell, from the row's start.
    col: usize = 0,
    /// Cells drawn: the form's width, or the cut width (its `…` included).
    cols: usize = 0,
    /// The text drawn is the compact form's (compact, or a cut of it).
    compact: bool = false,
};

/// Cells between two neighbours in one cluster.
pub const gap = 2;
/// At least this many cells between the two clusters when both show.
pub const cluster_gap = 2;
/// The shortest an elided segment may become, `…` included: shorter says
/// nothing, and the segment goes instead.
pub const min_elided = 6;
/// Segments past this many are not laid out (drawn nowhere).
pub const max_items = 64;

/// Lay `items` out in a row of `width` cells into `out` (one per item).
pub fn layout(items: []const Item, width: usize, out: []Placed) void {
    std.debug.assert(out.len >= items.len);
    const n = @min(items.len, max_items);
    for (out[0..items.len]) |*p| p.* = .{};
    for (items[0..n], out[0..n]) |it, *p| {
        if (it.full == 0) continue;
        p.* = .{ .form = .full, .cols = it.full };
    }

    // Yield order: lowest priority first; a tie goes later-drawn first.
    var order: [max_items]u16 = undefined;
    for (0..n) |i| order[i] = @intCast(i);
    std.mem.sort(u16, order[0..n], items, struct {
        fn before(its: []const Item, a: u16, b: u16) bool {
            if (its[a].priority != its[b].priority) return its[a].priority < its[b].priority;
            return a > b;
        }
    }.before);
    const yielding = order[0..n];

    // Least important first, each as little as makes the row fit.
    for (yielding) |i| {
        const total = used(items, out, n);
        if (total <= width) break;
        if (out[i].form == .dropped) continue;
        // The cells this segment may keep for the row to fit.
        const room = out[i].cols -| (total - width);
        if (room > 0 and items[i].elide != .none and room >= min_elided) {
            out[i] = .{ .form = .elided, .cols = room };
            break;
        }
        if (items[i].compact) |c| if (c > 0 and c <= room) {
            out[i] = .{ .form = .compact, .cols = c, .compact = true };
            break;
        };
        out[i] = .{};
    }

    // Columns: the left cluster from 0, the right one ending at `width`.
    var col: usize = 0;
    for (items[0..n], out[0..n]) |it, *p| {
        if (it.side != .left or p.form == .dropped) continue;
        p.col = col;
        col += p.cols + gap;
    }
    var right: usize = 0;
    var any = false;
    for (items[0..n], out[0..n]) |it, p| {
        if (it.side != .right or p.form == .dropped) continue;
        right += p.cols + @as(usize, if (any) gap else 0);
        any = true;
    }
    col = width -| right;
    for (items[0..n], out[0..n]) |it, *p| {
        if (it.side != .right or p.form == .dropped) continue;
        p.col = col;
        col += p.cols + gap;
    }
}

/// Cells the placement in `out` needs: each cluster's segments and the gaps
/// between them, and the gap between the clusters when both show.
fn used(items: []const Item, out: []const Placed, n: usize) usize {
    var sides = [2]struct { cols: usize = 0, count: usize = 0 }{ .{}, .{} };
    for (items[0..n], out[0..n]) |it, p| {
        if (p.form == .dropped) continue;
        const s = &sides[@intFromEnum(it.side)];
        s.cols += p.cols;
        s.count += 1;
    }
    var total: usize = 0;
    for (sides) |s| if (s.count > 0) {
        total += s.cols + (s.count - 1) * gap;
    };
    if (sides[0].count > 0 and sides[1].count > 0) total += cluster_gap;
    return total;
}

pub const ellipsis = "…";

/// Cells `text` takes on the mono grid: one per codepoint.
pub fn cells(text: []const u8) usize {
    return std.unicode.utf8CountCodepoints(text) catch text.len;
}

/// `text` cut to `cols` cells, the cut end marked `…` (`cols` of at least
/// one); `text` itself when it already fits. Cut between codepoints only.
/// Borrows `buf` (a copy long enough for `text` plus `…`).
pub fn cut(buf: []u8, text: []const u8, cols: usize, end: Elide) []const u8 {
    const have = cells(text);
    if (have <= cols or end == .none or cols == 0) return text;
    const keep = cols - 1; // the `…` takes one cell
    // The byte where the kept cells end (`.end`) or begin (`.start`).
    const skip = if (end == .end) keep else have - keep;
    var it = (std.unicode.Utf8View.init(text) catch return text[0..@min(text.len, cols)]).iterator();
    var i: usize = 0;
    var at: usize = 0;
    while (i < skip) : (i += 1) at += (it.nextCodepointSlice() orelse break).len;
    const kept = if (end == .end) text[0..at] else text[at..];
    if (kept.len + ellipsis.len > buf.len) return text;
    if (end == .end) {
        @memcpy(buf[0..kept.len], kept);
        @memcpy(buf[kept.len..][0..ellipsis.len], ellipsis);
    } else {
        @memcpy(buf[0..ellipsis.len], ellipsis);
        @memcpy(buf[ellipsis.len..][0..kept.len], kept);
    }
    return buf[0 .. kept.len + ellipsis.len];
}

/// A pane's title in `cols` cells, by the same rules as a status segment. A
/// title reads `label: subject` (`designation.title`'s one formula) or is a
/// bare subject; a subject that is a path keeps its END — the leaf that names
/// it — behind `…`, and the label stays whole. When the label would leave the
/// subject less than `min_elided`, or the title is prose, it is cut at its end
/// instead. Never mid-glyph, never past `cols`. Borrows `buf`, which must
/// hold `title` plus `…`; a shorter one gets a plain codepoint-safe prefix.
pub fn fitTitle(buf: []u8, title: []const u8, cols: usize) []const u8 {
    if (cells(title) <= cols) return title;
    if (cols == 0) return title[0..0];
    if (buf.len < title.len + ellipsis.len) return prefix(title, cols);
    if (std.mem.indexOf(u8, title, ": ")) |sep| {
        const label = title[0 .. sep + 2];
        const label_cols = cells(label);
        if (label_cols + min_elided <= cols) {
            @memcpy(buf[0..label.len], label);
            const subject = cut(buf[label.len..], title[label.len..], cols - label_cols, .start);
            // Cut into `buf` right after the label — else the subject was
            // not text to cut (bytes that are not UTF-8), and neither is this.
            if (subject.ptr == buf[label.len..].ptr) return buf[0 .. label.len + subject.len];
            return prefix(title, cols);
        }
        return cut(buf, title, cols, .end);
    }
    return cut(buf, title, cols, if (std.mem.indexOfScalar(u8, title, '/') != null) .start else .end);
}

/// The first `cols` cells of `text`, cut between codepoints.
fn prefix(text: []const u8, cols: usize) []const u8 {
    var it = (std.unicode.Utf8View.init(text) catch return text[0..@min(text.len, cols)]).iterator();
    var at: usize = 0;
    for (0..cols) |_| at += (it.nextCodepointSlice() orelse break).len;
    return text[0..at];
}

// ── Tests ───────────────────────────────────────────────────────────

const t = std.testing;

fn run(items: []const Item, width: usize) [8]Placed {
    var out: [8]Placed = undefined;
    layout(items, width, out[0..items.len]);
    return out;
}

test "status_layout: everything fits — full forms, left from the start, right ending at the end" {
    const items = [_]Item{
        .{ .full = 6, .priority = 100 },
        .{ .full = 8, .priority = 50 },
        .{ .side = .right, .full = 5, .priority = 90 },
        .{ .side = .right, .full = 3, .priority = 10 },
    };
    const out = run(&items, 40);
    try t.expectEqual(Placed{ .form = .full, .col = 0, .cols = 6 }, out[0]);
    try t.expectEqual(Placed{ .form = .full, .col = 8, .cols = 8 }, out[1]);
    // The right cluster ends on the last cell: 5 + gap + 3 = 10 cells.
    try t.expectEqual(Placed{ .form = .full, .col = 30, .cols = 5 }, out[2]);
    try t.expectEqual(Placed{ .form = .full, .col = 37, .cols = 3 }, out[3]);
}

test "status_layout: short of room, the least important segment yields first — compact when that is enough" {
    const items = [_]Item{
        .{ .full = 6, .compact = 3, .priority = 100 },
        .{ .full = 12, .compact = 4, .priority = 10 },
        .{ .side = .right, .full = 12, .compact = 5, .priority = 90 },
    };
    // Full: 6 + 2 + 12 + 2 + 12 = 34. At 26, compacting the priority-10
    // segment (−8) is enough; nothing else changes.
    const out = run(&items, 26);
    try t.expectEqual(Form.full, out[0].form);
    try t.expectEqual(Placed{ .form = .compact, .col = 8, .cols = 4, .compact = true }, out[1]);
    try t.expectEqual(Placed{ .form = .full, .col = 14, .cols = 12 }, out[2]);
    // One cell less and its compact form is not enough: it goes whole, and
    // the more important segments keep their full forms.
    const short = run(&items, 25);
    try t.expectEqual(Form.dropped, short[1].form);
    try t.expectEqual(Placed{ .form = .full, .col = 0, .cols = 6 }, short[0]);
    try t.expectEqual(Placed{ .form = .full, .col = 13, .cols = 12 }, short[2]);
}

test "status_layout: a low-priority segment goes before a high-priority one shortens — across the clusters" {
    const items = [_]Item{
        .{ .full = 6, .priority = 100 }, // the mode chip
        .{ .full = 10, .compact = 3, .priority = 20 }, // a low-priority left segment
        .{ .side = .right, .full = 12, .compact = 5, .priority = 90 }, // Ln/Col
    };
    // 6 + 2 + 10 + 2 + 12 = 32. At 16 the priority-20 segment goes (its
    // compact form would still leave the row too long), then Ln/Col shrinks
    // to its compact form: 6 + 2 + 5 = 13.
    const out = run(&items, 16);
    try t.expectEqual(Form.full, out[0].form);
    try t.expectEqual(Form.dropped, out[1].form);
    try t.expectEqual(Placed{ .form = .compact, .col = 11, .cols = 5, .compact = true }, out[2]);
    // With a little more room, the low one's going is enough: 6 + 2 + 12.
    const wider = run(&items, 20);
    try t.expectEqual(Form.dropped, wider[1].form);
    try t.expectEqual(Placed{ .form = .full, .col = 8, .cols = 12 }, wider[2]);
}

test "status_layout: text too long for the room is cut to fit with an ellipsis, never below the shortest useful cut" {
    const items = [_]Item{
        .{ .full = 6, .priority = 100 },
        .{ .full = 30, .compact = 4, .priority = 50, .elide = .start },
    };
    // A cut shows more of the text than the compact form would: 12 cells.
    const out = run(&items, 20);
    try t.expectEqual(Form.full, out[0].form);
    try t.expectEqual(Placed{ .form = .elided, .col = 8, .cols = 12 }, out[1]);
    // Too little room for a useful cut, but enough for the compact form.
    const tight = run(&items, 12);
    try t.expectEqual(Placed{ .form = .compact, .col = 8, .cols = 4, .compact = true }, tight[1]);
    // Too little for either: it goes whole.
    const narrow = run(&items, 10);
    try t.expectEqual(Form.dropped, narrow[1].form);
    try t.expectEqual(Form.full, narrow[0].form);
}

test "status_layout: equal priorities yield later-drawn first, and the same input always lays out the same" {
    const items = [_]Item{
        .{ .full = 5, .priority = 30 },
        .{ .full = 5, .priority = 30 },
        .{ .side = .right, .full = 5, .priority = 30 },
    };
    // 5 + 2 + 5 + 2 + 5 = 19. At 12 one must go: the right one, drawn last.
    const a = run(&items, 12);
    const b = run(&items, 12);
    try t.expectEqualSlices(Placed, a[0..3], b[0..3]);
    try t.expectEqual(Form.full, a[0].form);
    try t.expectEqual(Form.full, a[1].form);
    try t.expectEqual(Form.dropped, a[2].form);
}

test "status_layout: nothing fits — every segment goes, and nothing is placed past the row" {
    const items = [_]Item{
        .{ .full = 8, .priority = 100 },
        .{ .side = .right, .full = 9, .priority = 90 },
    };
    const out = run(&items, 4);
    try t.expectEqual(Form.dropped, out[0].form);
    try t.expectEqual(Form.dropped, out[1].form);
    // Whatever survives at any width stays inside it.
    for (0..30) |w| {
        const o = run(&items, w);
        for (o[0..2]) |p| if (p.form != .dropped) try t.expect(p.col + p.cols <= w);
    }
}

test "status_layout: a cut is between codepoints, marked at the end it removed" {
    var buf: [64]u8 = undefined;
    try t.expectEqualStrings("hello", cut(&buf, "hello", 8, .end));
    try t.expectEqualStrings("a mes…", cut(&buf, "a message that is long", 6, .end));
    try t.expectEqualStrings("…s.zig", cut(&buf, "src/view/status.zig", 6, .start));
    // Multi-byte text: cells are codepoints, and no codepoint is split.
    const cut_text = cut(&buf, "ünïcödé text", 5, .end);
    try t.expectEqualStrings("ünïc…", cut_text);
    try t.expect(std.unicode.utf8ValidateSlice(cut_text));
    try t.expectEqual(@as(usize, 5), cells(cut_text));
    const tail = cut(&buf, "→→→→→→→→", 4, .start);
    try t.expectEqualStrings("…→→→", tail);
    try t.expect(std.unicode.utf8ValidateSlice(tail));
}

test "status_layout: a title keeps its label and its leaf — the path shortens from the left" {
    var buf: [256]u8 = undefined;
    const title = "files: /tmp/nix-shell-3f9a/weft-project/src/deeply";
    try t.expectEqualStrings(title, fitTitle(&buf, title, 80));
    try t.expectEqualStrings("files: …ject/src/deeply", fitTitle(&buf, title, 23));
    // No label to keep: the whole title is the path, and keeps its end.
    try t.expectEqualStrings("…/src/deeply", fitTitle(&buf, "/tmp/nix-shell-3f9a/src/deeply", 12));
    // Too narrow to keep the label and a useful cut of the path: the title
    // is prose, cut at its end.
    try t.expectEqualStrings("files: /…", fitTitle(&buf, title, 9));
    // Never mid-glyph, never past the room.
    for (1..60) |w| {
        const fitted = fitTitle(&buf, "files: ~/ünïcödé/→→→/leaf", w);
        try t.expect(std.unicode.utf8ValidateSlice(fitted));
        try t.expect(cells(fitted) <= w);
    }
}
