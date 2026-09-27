//! Where each status segment goes when the row is too short (doc/chrome.md
//! §4.2) — a pure function of the segments' measures and the row's width, so
//! what a narrow pane shows is decided in ONE place, deterministically, and
//! tested without drawing anything.
//!
//! Segments sit in two clusters: `left` from the row's start, `right` ending
//! at its end. Every segment has a priority (who keeps its room longest), a
//! full form and, optionally, a compact one. When the row is too short:
//!
//!   1. segments shrink to their compact form, lowest priority first;
//!   2. then they go, lowest priority first — except that a segment whose
//!      text may be cut short (`elide`) is cut to fit, ending (or starting)
//!      in `…`, when that leaves it at least `min_elided` cells;
//!   3. and a segment compacted in step 1 gets its full form back, highest
//!      priority first, wherever the room step 2 made lets it.
//!
//! The two clusters draw from one budget, so a high-priority segment on the
//! right (`Ln 12, Col 4`) outlives a low-priority one on the left. Equal
//! priorities yield later-drawn first. Widths are cells of the mono grid —
//! one per codepoint, the unit every status run is placed in — so a cut
//! (`elide`) is always between two codepoints, never inside one.

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
pub const gap = 1;
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

    // 1. Compact, least important first.
    for (yielding) |i| {
        if (used(items, out, n) <= width) break;
        const c = items[i].compact orelse continue;
        if (out[i].form == .full and c > 0 and c < items[i].full) out[i] = .{ .form = .compact, .cols = c, .compact = true };
    }
    // 2. Elide or drop, least important first.
    for (yielding) |i| {
        const total = used(items, out, n);
        if (total <= width) break;
        if (out[i].form == .dropped) continue;
        const over = total - width;
        if (items[i].elide != .none and out[i].cols > over and out[i].cols - over >= min_elided) {
            out[i] = .{ .form = .elided, .cols = out[i].cols - over, .compact = out[i].compact };
            break;
        }
        out[i] = .{};
    }
    // 3. Give a compacted segment its full form back where it now fits, most
    // important first.
    var k = yielding.len;
    while (k > 0) {
        k -= 1;
        const i = yielding[k];
        if (out[i].form != .compact) continue;
        const grow = items[i].full - out[i].cols;
        if (used(items, out, n) + grow <= width) out[i] = .{ .form = .full, .cols = items[i].full };
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
    try t.expectEqual(Placed{ .form = .full, .col = 7, .cols = 8 }, out[1]);
    // The right cluster ends on the last cell: 5 + gap + 3 = 9 cells.
    try t.expectEqual(Placed{ .form = .full, .col = 31, .cols = 5 }, out[2]);
    try t.expectEqual(Placed{ .form = .full, .col = 37, .cols = 3 }, out[3]);
}

test "status_layout: short of room, the least important segment goes compact first" {
    const items = [_]Item{
        .{ .full = 6, .compact = 3, .priority = 100 },
        .{ .full = 12, .compact = 4, .priority = 10 },
        .{ .side = .right, .full = 12, .compact = 5, .priority = 90 },
    };
    // Full: 6 + 1 + 12 + 2 + 12 = 33. At 25, compacting the priority-10
    // segment (−8) is enough; nothing else changes.
    const out = run(&items, 25);
    try t.expectEqual(Form.full, out[0].form);
    try t.expectEqual(Placed{ .form = .compact, .col = 7, .cols = 4, .compact = true }, out[1]);
    try t.expectEqual(Placed{ .form = .full, .col = 13, .cols = 12 }, out[2]);
}

test "status_layout: then segments go, least important first — a high-priority right segment outlives a low-priority left one" {
    const items = [_]Item{
        .{ .full = 6, .priority = 100 }, // the mode chip
        .{ .full = 10, .priority = 20 }, // a low-priority left segment
        .{ .side = .right, .full = 12, .compact = 5, .priority = 90 }, // Ln/Col
    };
    // 6 + 1 + 10 + 2 + 12 = 31. At 16: compacting Ln/Col (−7) leaves 24,
    // still too long, so the priority-20 segment goes — and with it gone
    // Ln/Col has room for its full form again (6 + 2 + 12 = 20 > 16: no).
    const out = run(&items, 16);
    try t.expectEqual(Form.full, out[0].form);
    try t.expectEqual(Form.dropped, out[1].form);
    try t.expectEqual(Placed{ .form = .compact, .col = 11, .cols = 5, .compact = true }, out[2]);
    // With a little more room, the full form comes back once the low one is
    // gone: 6 + 2 + 12 = 20.
    const wider = run(&items, 20);
    try t.expectEqual(Form.dropped, wider[1].form);
    try t.expectEqual(Placed{ .form = .full, .col = 8, .cols = 12 }, wider[2]);
}

test "status_layout: text too long for the room is cut to fit with an ellipsis, never below the shortest useful cut" {
    const items = [_]Item{
        .{ .full = 6, .priority = 100 },
        .{ .full = 30, .priority = 50, .elide = .start },
    };
    const out = run(&items, 20);
    try t.expectEqual(Form.full, out[0].form);
    try t.expectEqual(Placed{ .form = .elided, .col = 7, .cols = 13 }, out[1]);
    // Too little left for a useful cut: it goes whole.
    const narrow = run(&items, 12);
    try t.expectEqual(Form.dropped, narrow[1].form);
    try t.expectEqual(Form.full, narrow[0].form);
}

test "status_layout: equal priorities yield later-drawn first, and the same input always lays out the same" {
    const items = [_]Item{
        .{ .full = 5, .priority = 30 },
        .{ .full = 5, .priority = 30 },
        .{ .side = .right, .full = 5, .priority = 30 },
    };
    // 5 + 1 + 5 + 2 + 5 = 18. At 12 one must go: the right one, drawn last.
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
