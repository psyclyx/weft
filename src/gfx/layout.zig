//! Layout — the source-offset ↔ rendered-geometry map.
//!
//! The monospace cell grid was a shortcut: it let the editor treat a
//! scalar column as a pixel position. That assumption is tech debt. The
//! general model is that the *view* owns where each source byte renders,
//! and vertical motion / hit-testing / selection read pixel-x, not
//! columns. Monospace then falls out as the degenerate case (uniform
//! advances: `stop.x == margin + col*cell_w`).
//!
//! A `Layout` is a per-frame value: a list of `VisualLine`s, each with a
//! baseline and an ascending list of `Stop`s — the caret x at each source
//! byte offset, read directly from snail's shaped glyphs (each glyph
//! carries its absolute cumulative pen `x_offset` in em units plus the
//! source byte range it came from). The same `buildRowStops` primitive
//! builds these lines AND answers off-screen vertical motion, so the map
//! the user sees and the map motion walks can never disagree.

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const snail = @import("snail");
const stemma = @import("stemma");

/// Caret x at a source byte offset. Stops are emitted in ascending
/// `off` order, one per shaped glyph cluster start, plus a terminal stop
/// at the line's end offset (the end-of-line caret).
pub const Stop = struct { off: u32, x: f32 };

/// A rendered line: a source byte range, its vertical placement, and the
/// caret stops across it. `src` excludes the trailing newline (content
/// only), matching `Rope.lineRange`.
pub const VisualLine = struct {
    src: stemma.Range,
    row: usize,
    baseline_y: f32,
    ascent: f32,
    descent: f32,
    height: f32,
    /// Left edge (the line's origin x); also the caret x for an empty
    /// line and for any offset at or before the start.
    x0: f32,
    /// Ascending by `off`. Always non-empty: an empty line still has the
    /// single end-of-line stop at `x0`.
    stops: []const Stop,

    /// Caret x for a source offset on this line. Exact stop → its x;
    /// between two stops (a multi-byte cluster or ligature interior) →
    /// linear interpolation by byte fraction; before the first / after
    /// the last → clamped to the edge stop.
    pub fn xAt(self: *const VisualLine, off: usize) f32 {
        const stops = self.stops;
        if (stops.len == 0) return self.x0;
        if (off <= stops[0].off) return stops[0].x;
        if (off >= stops[stops.len - 1].off) return stops[stops.len - 1].x;
        // Binary search for the last stop with off <= target.
        var lo: usize = 0;
        var hi: usize = stops.len - 1;
        while (lo + 1 < hi) {
            const mid = (lo + hi) / 2;
            if (stops[mid].off <= off) lo = mid else hi = mid;
        }
        const a = stops[lo];
        const b = stops[hi];
        if (off == a.off) return a.x;
        if (b.off == a.off) return a.x;
        const frac = @as(f32, @floatFromInt(off - a.off)) /
            @as(f32, @floatFromInt(b.off - a.off));
        return a.x + frac * (b.x - a.x);
    }

    pub fn caretAt(self: *const VisualLine, off: usize) Caret {
        return .{ .x = self.xAt(off), .y_top = self.baseline_y - self.ascent, .height = self.height };
    }

    /// Source offset nearest a pixel x on this line: the caret between
    /// adjacent stops is chosen by the midpoint rule. Left of `x0` →
    /// line start; past the last stop → line end.
    pub fn offsetAt(self: *const VisualLine, x: f32) usize {
        const stops = self.stops;
        if (stops.len == 0) return self.src.start;
        if (x <= stops[0].x) return stops[0].off;
        const last = stops[stops.len - 1];
        if (x >= last.x) return last.off;
        // Find the bracket [i, i+1] with stops[i].x <= x < stops[i+1].x.
        var lo: usize = 0;
        var hi: usize = stops.len - 1;
        while (lo + 1 < hi) {
            const mid = (lo + hi) / 2;
            if (stops[mid].x <= x) lo = mid else hi = mid;
        }
        const a = stops[lo];
        const b = stops[hi];
        const midpoint = (a.x + b.x) / 2;
        return if (x < midpoint) a.off else b.off;
    }
};

/// A caret rectangle: a thin vertical bar at `x`, top at `y_top`,
/// running `height` pixels down.
pub const Caret = struct { x: f32, y_top: f32, height: f32 };

/// Horizontal extent of a source range on one visual line.
pub const Extent = struct { x0: f32, x1: f32 };

/// The per-frame map. Owns nothing — `lines` and their `stops` live in
/// the frame arena the view builds them from.
pub const Layout = struct {
    lines: []const VisualLine,

    /// Caret geometry for a source offset, or null when no visible line
    /// covers it (offset scrolled off-screen).
    pub fn pointAtOffset(self: *const Layout, off: usize) ?Caret {
        const li = self.lineForOffset(off) orelse return null;
        return self.lines[li].caretAt(off);
    }

    /// Source offset under a pixel point. The y picks the line (clamped
    /// to the first/last visible line above/below the text); the x picks
    /// the offset within it. Always returns an offset — hit-testing a
    /// click never fails, it snaps to the nearest addressable spot.
    pub fn offsetAtPoint(self: *const Layout, x: f32, y: f32) usize {
        if (self.lines.len == 0) return 0;
        const li = self.lineForY(y);
        return self.lines[li].offsetAt(x);
    }

    /// x-extent of `[s, e)` clipped to one visual line, for a selection
    /// rectangle.
    pub fn lineExtent(self: *const Layout, line_index: usize, s: usize, e: usize) Extent {
        const line = &self.lines[line_index];
        return .{ .x0 = line.xAt(s), .x1 = line.xAt(e) };
    }

    /// Index of the visible line containing `off` (or the nearest one),
    /// or null when `off` is outside every visible line's source range
    /// and not adjacent to one.
    pub fn lineForOffset(self: *const Layout, off: usize) ?usize {
        for (self.lines, 0..) |line, i| {
            if (off >= line.src.start and off <= line.src.end) return i;
        }
        return null;
    }

    fn lineForY(self: *const Layout, y: f32) usize {
        for (self.lines, 0..) |line, i| {
            if (y < line.baseline_y + line.descent) return i;
        }
        return self.lines.len - 1;
    }
};

/// Metrics a row needs to place its stops. `margin`/`em` come from the
/// view; `baseline_y`/`ascent`/`descent`/`height` are the row's vertical
/// slot (uniform today; per-line once markdown brings variable heights).
pub const RowMetrics = struct {
    em: f32,
    margin: f32,
    baseline_y: f32,
    ascent: f32,
    descent: f32,
    height: f32,
};

/// Columns a tab advances to (tab stops every 4). Kept in step with the
/// view's mono line builder so on-screen and off-screen motion agree.
pub const tab_width: usize = 4;

/// The next tab stop strictly after column `col`.
pub fn tabStopAfter(col: usize) usize {
    return (col / tab_width + 1) * tab_width;
}

/// Shape one source row and emit its `VisualLine`. The single primitive
/// behind both the frame `Layout` and off-screen vertical motion. `arena`
/// owns the returned stops (and the transient shaping); pass a per-call
/// or per-frame arena. Tabs render as blank space advancing to the next
/// tab stop — a display substitution, the document is untouched.
pub fn buildRowStops(
    arena: Allocator,
    faces: *snail.Faces,
    rope: *const stemma.Rope,
    row: usize,
    m: RowMetrics,
) !VisualLine {
    const src = rope.lineRange(row);
    var stops: std.ArrayList(Stop) = .empty;

    if (!src.isEmpty()) {
        const raw = try arena.alloc(u8, src.len());
        var sr = rope.streamReader(.{ .start = src.start, .end = src.end }, &.{});
        sr.interface.readSliceAll(raw) catch unreachable;
        // Shape a tab→space copy (so tabs occupy a blank glyph); keep `raw`
        // to detect tabs and expand their advance to the next tab stop.
        const shbuf = try arena.dupe(u8, raw);
        for (shbuf) |*b| {
            if (b.* == '\t') b.* = ' ';
        }
        const shaped = try snail.shape(arena, faces, shbuf, .{});
        // A glyph's absolute pen x in em units is `x_offset`; world x is
        // `margin + em*x_offset`, plus the accumulated tab shift. Its
        // source cluster starts at `src.start + source_start`.
        var shift: f32 = 0;
        for (shaped.glyphs) |g| {
            const base_x = m.margin + m.em * g.x_offset;
            try stops.append(arena, .{
                .off = @intCast(src.start + g.source_start),
                .x = base_x + shift,
            });
            if (g.source_start < raw.len and raw[g.source_start] == '\t') {
                const cell = m.em * g.x_advance; // one mono cell (the space advance)
                if (cell > 0) {
                    const col: usize = @intFromFloat(@round((base_x + shift - m.margin) / cell));
                    const target = m.margin + @as(f32, @floatFromInt(tabStopAfter(col))) * cell;
                    const natural_next = m.margin + m.em * (g.x_offset + g.x_advance) + shift;
                    shift += target - natural_next;
                }
            }
        }
        // End-of-line caret: past the last glyph by its advance.
        if (shaped.glyphs.len > 0) {
            const last = shaped.glyphs[shaped.glyphs.len - 1];
            try stops.append(arena, .{
                .off = @intCast(src.end),
                .x = m.margin + m.em * (last.x_offset + last.x_advance) + shift,
            });
        }
    }
    if (stops.items.len == 0) {
        // Empty line: the sole stop is the end-of-line caret at x0.
        try stops.append(arena, .{ .off = @intCast(src.end), .x = m.margin });
    }

    return .{
        .src = src,
        .row = row,
        .baseline_y = m.baseline_y,
        .ascent = m.ascent,
        .descent = m.descent,
        .height = m.height,
        .x0 = m.margin,
        .stops = stops.items,
    };
}

// ---------------------------------------------------------------------------
// Tests — map logic over hand-built stops (no font needed).
// ---------------------------------------------------------------------------

const testing = std.testing;

fn lineWith(stops: []const Stop, src: stemma.Range) VisualLine {
    return .{
        .src = src,
        .row = 0,
        .baseline_y = 20,
        .ascent = 16,
        .descent = 4,
        .height = 20,
        .x0 = 8,
        .stops = stops,
    };
}

test "xAt: exact stops, interpolation, and clamping" {
    // Three ASCII columns at cell_w = 10, plus the end-of-line stop.
    const stops = [_]Stop{
        .{ .off = 0, .x = 8 },
        .{ .off = 1, .x = 18 },
        .{ .off = 2, .x = 28 },
        .{ .off = 3, .x = 38 },
    };
    const line = lineWith(&stops, .{ .start = 0, .end = 3 });
    try testing.expectEqual(@as(f32, 8), line.xAt(0));
    try testing.expectEqual(@as(f32, 28), line.xAt(2));
    try testing.expectEqual(@as(f32, 38), line.xAt(3));
    // Before/after clamp.
    try testing.expectEqual(@as(f32, 8), line.xAt(0));
    try testing.expectEqual(@as(f32, 38), line.xAt(99));
}

test "xAt: interpolates a multi-byte cluster interior" {
    // A 3-byte glyph spanning offsets [1,4), next stop the end at 4.
    const stops = [_]Stop{
        .{ .off = 0, .x = 8 },
        .{ .off = 1, .x = 18 },
        .{ .off = 4, .x = 48 },
    };
    const line = lineWith(&stops, .{ .start = 0, .end = 4 });
    // Interior byte 2 is 1/3 of the way from 18 to 48 → 28.
    try testing.expectApproxEqAbs(@as(f32, 28), line.xAt(2), 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 38), line.xAt(3), 1e-4);
}

test "offsetAt: midpoint rule and clamping" {
    const stops = [_]Stop{
        .{ .off = 0, .x = 8 },
        .{ .off = 1, .x = 18 },
        .{ .off = 2, .x = 28 },
        .{ .off = 3, .x = 38 },
    };
    const line = lineWith(&stops, .{ .start = 0, .end = 3 });
    try testing.expectEqual(@as(usize, 0), line.offsetAt(0)); // left of x0
    try testing.expectEqual(@as(usize, 0), line.offsetAt(12)); // before midpoint 13
    try testing.expectEqual(@as(usize, 1), line.offsetAt(14)); // past midpoint 13
    try testing.expectEqual(@as(usize, 2), line.offsetAt(24)); // past midpoint 23
    try testing.expectEqual(@as(usize, 3), line.offsetAt(999)); // past last
}

test "offset<->x round-trips at stop offsets" {
    const stops = [_]Stop{
        .{ .off = 0, .x = 8 },
        .{ .off = 1, .x = 18 },
        .{ .off = 2, .x = 28 },
        .{ .off = 3, .x = 38 },
    };
    const line = lineWith(&stops, .{ .start = 0, .end = 3 });
    for (stops) |s| {
        // x at the offset, then the offset nearest that exact x, is identity.
        try testing.expectEqual(s.off, @as(u32, @intCast(line.offsetAt(line.xAt(s.off)))));
    }
}

test "buildRowStops: monospace is the degenerate case (stop.x == margin + col*cell_w)" {
    const gpa = testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var font = try snail.Font.init(@embedFile("font_mono"));
    var faces = try snail.Faces.build(gpa, &.{.{ .font = &font, .font_id = 1 }});
    defer faces.deinit();

    const em: f32 = 16;
    const margin: f32 = 8;
    const upem: f32 = @floatFromInt(font.unitsPerEm());
    const advance: f32 = @floatFromInt(try font.advanceWidth(try font.glyphIndex('M')));
    const cell_w = em * advance / upem;

    var rope = try stemma.Rope.fromSlice(gpa, "abcd");
    defer rope.deinit(gpa);

    const line = try buildRowStops(arena, &faces, &rope, 0, .{
        .em = em,
        .margin = margin,
        .baseline_y = 20,
        .ascent = 16,
        .descent = 4,
        .height = 20,
    });
    // 4 glyphs + the end-of-line caret = 5 stops, each a whole column.
    try testing.expectEqual(@as(usize, 5), line.stops.len);
    for (line.stops, 0..) |s, i| {
        try testing.expectEqual(@as(u32, @intCast(i)), s.off);
        try testing.expectApproxEqAbs(margin + @as(f32, @floatFromInt(i)) * cell_w, s.x, 1e-3);
    }
    // The map agrees with column arithmetic both ways.
    try testing.expectApproxEqAbs(margin + 2 * cell_w, line.xAt(2), 1e-3);
    try testing.expectEqual(@as(usize, 2), line.offsetAt(margin + 2 * cell_w));
}

test "Layout: lineForOffset / offsetAtPoint pick the right line" {
    const l0 = [_]Stop{ .{ .off = 0, .x = 8 }, .{ .off = 2, .x = 28 } };
    const l1 = [_]Stop{ .{ .off = 3, .x = 8 }, .{ .off = 6, .x = 38 } };
    var lines = [_]VisualLine{
        lineWith(&l0, .{ .start = 0, .end = 2 }),
        lineWith(&l1, .{ .start = 3, .end = 6 }),
    };
    lines[1].baseline_y = 40;
    const layout = Layout{ .lines = &lines };
    try testing.expectEqual(@as(?usize, 0), layout.lineForOffset(1));
    try testing.expectEqual(@as(?usize, 1), layout.lineForOffset(5));
    // A click low on the second line's band returns an offset in [3,6].
    const off = layout.offsetAtPoint(8, 40);
    try testing.expect(off >= 3 and off <= 6);
}
