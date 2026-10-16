//! Line layout — the shared layout primitive, in both placements.
//!
//! Free functions over `*View`. `layoutLine` fans out to the mono cell-grid
//! builder (plain buffers: uniform advances, integer columns) or the
//! proportional markdown builder (maximal same-style runs at varying faces
//! and sizes). Both emit the frame's runs AND the caret `Stop`s that feed the
//! geometry map. `resolveStyleInputs` lifts the bulk style feeds once a frame.
//! Split out of `view.zig`; `build` calls `resolveStyleInputs` then `layoutLine`.

const std = @import("std");
const Allocator = std.mem.Allocator;

const text_engine = @import("weft_text");
const font_provider = @import("weft_font_provider");
const stemma = @import("stemma");
const core = @import("weft_core");
const layout = @import("../layout.zig");
const view = @import("../view.zig");
const ui_mesh = @import("ui_mesh.zig");

const View = view.View;
const Run = view.Run;
const Hud = view.Hud;
const MdInline = view.MdInline;

const InlineAttr = core.capability.InlineAttr;
const HighlightClass = core.capability.HighlightClass;
const StyleClass = core.capability.StyleClass;

/// Bulk style feeds resolved once per frame for the visible range.
pub const StyleInputs = struct {
    hl: ?[]const HighlightClass = null,
    hl_base: usize = 0,
    /// Plugin styles feed (tool buffers): class-per-byte from `hl_base`-style
    /// bulk, consulted only where there is no syntax highlight.
    st: ?[]const StyleClass = null,
    st_base: usize = 0,
    diag: ?[]const u8 = null,
    diag_base: usize = 0,
    /// Placed decorations (virtual text) for the visible range — drawn beside
    /// the text, never in the document. files's metadata/arrow/mark ride this,
    /// so the buffer text is only the editable name (yy yanks the name alone).
    deco: ?*const core.layers.Snapshot = null,
    /// Third-party annotation roles over the visible range: `anno[i]` is the
    /// StyleClass painted at byte `anno_base + i`, plus one (0 = unpainted, so
    /// an unannotated byte costs nothing to check). Composited from every
    /// annotation feed the entry hosts; a feed whose spans no longer resolve
    /// against the entry revision contributes none (§11.7).
    anno: ?[]const u8 = null,
    anno_base: usize = 0,
    /// The annotation feeds' placed decorations, drawn beside the line by the
    /// same prefix path the `decorations` layer uses.
    anno_layers: []const core.layers.Snapshot = &.{},
    /// The `ui/gutter-segment` mesh's per-frame resolution
    /// (doc/contextual-workspace-architecture.md §11), passed through
    /// from `Hud.gutter` unchanged — null (today's default) means no
    /// gutter cells render, at the cost of one pointer copy per frame.
    gutter: ?ui_mesh.GutterFrame = null,
    /// Width, in cells, of the sign column `gutter`-placement decorations
    /// draw in (a breakpoint dot, a severity mark): 0 when no feed places
    /// one, so an entry with none pays no column. Fixed for the frame, so a
    /// row with a mark and a row without start their text in the same column.
    mark_cols: usize = 0,
};

/// A row's text length in cells: one per scalar (the mono grid's rule).
fn cellWidth(text: []const u8) usize {
    return std.unicode.utf8CountCodepoints(text) catch text.len;
}

/// The sign column's width over every `gutter`-placed span the entry's feeds
/// hold: the widest mark plus a separating blank, or 0 when there is none.
fn markCols(deco: ?*const core.layers.Snapshot, anno: []const core.layers.Snapshot) usize {
    var widest: usize = 0;
    if (deco) |dl| {
        for (0..dl.spanCount()) |i| {
            const s = dl.resolvedSpan(i);
            if (s.placement == .gutter) widest = @max(widest, cellWidth(s.message));
        }
    }
    for (anno) |al| {
        for (0..al.spanCount()) |i| {
            const s = al.resolvedSpan(i);
            if (s.placement == .gutter) widest = @max(widest, cellWidth(s.message));
        }
    }
    return if (widest == 0) 0 else widest + 1;
}

/// The face + size + color a markdown attribute renders as.
const InlineStyle = struct {
    faces: *text_engine.StyleSet,
    style: text_engine.FontStyle,
    em: f32,
    color: [4]f32,

    fn eql(a: InlineStyle, b: InlineStyle) bool {
        return a.faces == b.faces and
            a.style.weight == b.style.weight and a.style.italic == b.style.italic and
            a.em == b.em and std.mem.eql(f32, &a.color, &b.color);
    }
};

/// Resolve the highlight + diagnostic bulk feeds for the visible range.
pub fn resolveStyleInputs(
    scratch: Allocator,
    hud: Hud,
    rope: *const stemma.Rope,
    top_row: usize,
    rows_visible: usize,
    total_rows: usize,
) !StyleInputs {
    var s: StyleInputs = .{};
    if (hud.highlight_layer) |hl| {
        if (hl.bulk) |b| {
            s.hl = @ptrCast(b.classes);
            s.hl_base = b.start;
        }
    }
    if (hud.styles_layer) |sl| {
        if (sl.bulk) |b| {
            s.st = @ptrCast(b.classes);
            s.st_base = b.start;
        }
    }
    const diag_count = if (hud.diag_layer) |dl| dl.spanCount() else 0;
    if (diag_count > 0 and rows_visible > 0 and top_row < total_rows) {
        const dl = hud.diag_layer.?;
        const last = @min(total_rows, top_row + rows_visible);
        const vis_start = rope.lineRange(top_row).start;
        const vis_end = rope.lineRange(last - 1).end;
        const tint = try scratch.alloc(u8, vis_end - vis_start);
        @memset(tint, 0);
        for (0..dl.spanCount()) |di| {
            const d = dl.resolvedSpan(di);
            const a = @max(d.start, vis_start);
            const e = @min(@max(d.end, d.start + 1), vis_end);
            if (a >= e) continue;
            for (tint[a - vis_start .. e - vis_start]) |*b| {
                if (b.* == 0 or d.kind < b.*) b.* = @intCast(@min(d.kind, 255));
            }
        }
        s.diag = tint;
        s.diag_base = vis_start;
    }
    s.deco = hud.decorations_layer;
    s.anno_layers = hud.annotations;
    if (hud.annotations.len > 0 and rows_visible > 0 and top_row < total_rows) {
        const last = @min(total_rows, top_row + rows_visible);
        const vis_start = rope.lineRange(top_row).start;
        const vis_end = rope.lineRange(last - 1).end;
        const roles = try scratch.alloc(u8, vis_end - vis_start);
        @memset(roles, 0);
        var painted = false;
        for (hud.annotations) |al| {
            // `spanCount` is 0 while a feed is stale, so a decorator that has
            // not republished since the last edit simply contributes nothing.
            for (0..al.spanCount()) |i| {
                const a = al.resolvedSpan(i);
                if (a.placement != .range) continue;
                const from = @max(a.start, vis_start);
                const to = @min(a.end, vis_end);
                if (from >= to) continue;
                const raw: u8 = @truncate(a.kind);
                const cls: u8 = if (raw <= @intFromEnum(StyleClass.muted)) raw else @intFromEnum(StyleClass.muted);
                @memset(roles[from - vis_start .. to - vis_start], cls + 1);
                painted = true;
            }
        }
        if (painted) {
            s.anno = roles;
            s.anno_base = vis_start;
        }
    }
    s.gutter = hud.gutter;
    s.mark_cols = markCols(s.deco, s.anno_layers);
    return s;
}

// ── Line layout (the shared primitive) ───────────────────────────

/// Whether a block caret covers `off`: its glyph (a label's included) then
/// draws in `cursor_text`, legible on the caret. `flips` holds every
/// caret's draw offset in document order — each selection has one, not
/// only the primary.
fn flipped(flips: []const usize, off: usize) bool {
    return std.sort.binarySearch(usize, flips, off, struct {
        fn order(target: usize, item: usize) std.math.Order {
            return std.math.order(target, item);
        }
    }.order) != null;
}

/// Soft wrap for one row: break where the room ends — at a word boundary
/// where one is in reach, else mid-word — and stop emitting segments that
/// would start below `y_limit` (the body's bottom).
pub const Wrap = struct {
    /// The room for text, in pixels, from the content's origin (proportional
    /// lines; a mono line reads its room in cells).
    width: f32,
    /// No segment after a row's first starts at or past this y.
    y_limit: f32 = std.math.inf(f32),
};

/// Lay `row` out as one visual line — no wrap. Kept for callers and tests
/// that measure a single row.
pub fn layoutLine(
    v: *View,
    scratch: Allocator,
    la: Allocator,
    runs: *std.ArrayList(Run),
    rope: *const stemma.Rope,
    row: usize,
    y_top: f32,
    cols_visible: usize,
    md: ?MdInline,
    styles: StyleInputs,
    flips: []const usize,
) !layout.VisualLine {
    var out: std.ArrayList(layout.VisualLine) = .empty;
    try layoutRow(v, scratch, la, runs, rope, row, y_top, cols_visible, md, styles, flips, null, &out);
    return out.items[0];
}

/// Lay `row` out into `out`: one visual line, or — under `wrap` — as many
/// segments as its text needs, each the next one down (`VisualLine.wraps`
/// on all but the last). Every segment's stops are the caret's, so the
/// geometry map, selections and clicks read a wrapped row as they read any.
pub fn layoutRow(
    v: *View,
    scratch: Allocator,
    la: Allocator,
    runs: *std.ArrayList(Run),
    rope: *const stemma.Rope,
    row: usize,
    y_top: f32,
    cols_visible: usize,
    md: ?MdInline,
    styles: StyleInputs,
    flips: []const usize,
    wrap: ?Wrap,
    out: *std.ArrayList(layout.VisualLine),
) !void {
    if (md) |m|
        try layoutMarkdownLine(v, scratch, la, runs, rope, row, y_top, m, flips, wrap, out)
    else
        try layoutMonoLine(v, scratch, la, runs, rope, row, y_top, cols_visible, styles, flips, wrap, out);
}

/// Where a line of `text` breaks to fit `room` units, measuring each scalar
/// with `width(byte_index, scalar, x)`: the byte index each segment after
/// the first starts at. A break goes after the last space in reach; with
/// none, mid-word. Scratch-owned.
fn breaksOf(
    scratch: Allocator,
    text: []const u8,
    room: f32,
    ctx: anytype,
    comptime width: fn (@TypeOf(ctx), usize, []const u8, f32) f32,
) ![]usize {
    var breaks: std.ArrayList(usize) = .empty;
    if (room <= 0) return breaks.items;
    var seg_start: usize = 0;
    var x: f32 = 0;
    // The byte after the last space in this segment, and the x there.
    var soft: ?struct { at: usize, x: f32 } = null;
    var byte: usize = 0;
    while (byte < text.len) {
        const len = std.unicode.utf8ByteSequenceLength(text[byte]) catch 1;
        const s = text[byte..@min(text.len, byte + len)];
        const w = width(ctx, byte, s, x);
        if (x + w > room + 0.01 and byte > seg_start) {
            if (soft) |sp| if (sp.at > seg_start and sp.at <= byte) {
                try breaks.append(scratch, sp.at);
                seg_start = sp.at;
                x -= sp.x;
                soft = null;
                continue; // re-measure this scalar against the new segment
            };
            try breaks.append(scratch, byte);
            seg_start = byte;
            x = 0;
            soft = null;
            continue;
        }
        x += w;
        byte += s.len;
        if (s.len == 1 and (s[0] == ' ' or s[0] == '\t')) soft = .{ .at = byte, .x = x };
    }
    return breaks.items;
}

/// Plain buffers: one mono cell per scalar on the pixel grid (uniform
/// advances). Per-cell color from the caret flip, diagnostics, then
/// highlight. Stops fall on integer columns — the degenerate case. Under
/// `wrap` a row longer than the pane goes on in segments beneath, indented
/// past the gutter; without it, it is cut at the pane's edge.
fn layoutMonoLine(
    v: *View,
    scratch: Allocator,
    la: Allocator,
    runs: *std.ArrayList(Run),
    rope: *const stemma.Rope,
    row: usize,
    y_top: f32,
    cols_visible: usize,
    styles: StyleInputs,
    flips: []const usize,
    wrap: ?Wrap,
    out: *std.ArrayList(layout.VisualLine),
) !void {
    const line = rope.lineRange(row);
    const text = try readLine(scratch, rope, line, if (wrap != null) max_wrapped_line else cols_visible * 4 + 4);

    var cells: std.ArrayList(text_engine.Cell) = .empty;
    var stops: std.ArrayList(layout.Stop) = .empty;
    // Virtual-text prefix: decorations anchored on this row (files's metadata/
    // arrow/mark) laid out as leading dimmed cells at the front of the shaped
    // buffer. They carry NO stop, so the caret (mapped through stops) sits after
    // them, and they're never in the document — `yy` yanks only the real line.
    var pfx_bytes: std.ArrayList(u8) = .empty;
    var col: usize = 0;
    // The sign column first (breakpoint dots, severity marks), then the
    // `ui/gutter-segment` cells, then the row's own virtual prefix.
    if (styles.mark_cols > 0) col = try layoutMarkColumn(v, scratch, styles, line, cols_visible, &pfx_bytes, &cells);
    if (styles.gutter) |gf| col = try layoutGutterPrefix(v, scratch, gf, line, row, cols_visible, &pfx_bytes, &cells, col);
    if (styles.deco) |dl| col = try layoutRowPrefix(v, scratch, dl, line, cols_visible, &pfx_bytes, &cells, col);
    // Third-party feeds compose onto the same prefix, after the entry's own
    // decorations: one more producer of leading cells, not a new mechanism.
    for (styles.anno_layers) |*al| col = try layoutRowPrefix(v, scratch, al, line, cols_visible, &pfx_bytes, &cells, col);
    // Where a continuation segment's text starts: under the first's.
    const text_col = col;

    // Where the row breaks, in cells of the room past the prefix.
    // A tab reaches the next stop of the row's absolute columns, as drawn.
    const Cols = struct {
        fn width(start: usize, _: usize, s: []const u8, x: f32) f32 {
            if (s.len == 1 and s[0] == '\t') {
                const c = start + @as(usize, @intFromFloat(x));
                return @floatFromInt(layout.tabStopAfter(c) - c);
            }
            return 1;
        }
    };
    const breaks: []const usize = if (wrap != null and cols_visible > text_col + 1)
        try breaksOf(scratch, text, @floatFromInt(cols_visible - text_col), text_col, Cols.width)
    else
        &.{};
    var next_break: usize = 0;

    // Overlays draw OVER real cells: a covered cell sources its glyph from
    // the overlay's text instead of the document's. The text, its stops, and
    // the caret are untouched — a label hides a glyph, it never moves one.
    var overlays: Overlays = .{};
    overlays.collect(styles, line);

    var seg_start = line.start;
    var seg_top = y_top;
    // The shaped buffer is built cell by cell after the prefix: each cell
    // appends exactly the bytes its glyph comes from (a real scalar, a tab's
    // space, or an overlay's scalar), so every shaped glyph has its cell.
    var it = (std.unicode.Utf8View.init(text) catch return error.InvalidUtf8).iterator();
    var byte: usize = 0;
    while (it.nextCodepointSlice()) |s| : (col += 1) {
        if (next_break < breaks.len and byte == breaks[next_break]) {
            // The room is used: finish this segment, go on beneath it.
            next_break += 1;
            const abs_here = line.start + byte;
            try stops.append(la, .{ .off = @intCast(abs_here), .x = v.origin_x + @as(f32, @floatFromInt(col)) * v.cell_w });
            try emitMono(v, scratch, la, runs, out, &cells, &pfx_bytes, &stops, .{ .start = seg_start, .end = abs_here }, row, seg_top, true);
            seg_top += v.line_h;
            seg_start = abs_here;
            col = text_col;
            if (seg_top >= wrap.?.y_limit) return;
        }
        if (col >= cols_visible) break;
        const abs = line.start + byte;
        const b0 = pfx_bytes.items.len;
        if (overlays.next(abs)) |ov| {
            try pfx_bytes.appendSlice(scratch, ov.cp);
            try cells.append(scratch, .{
                .source = .{ .start = @intCast(b0), .end = @intCast(pfx_bytes.items.len) },
                .column = @intCast(col),
                .color = if (flipped(flips, abs)) v.theme.cursor_text else ov.color(v),
            });
        } else {
            const color = if (flipped(flips, abs))
                v.theme.cursor_text
            else if (styles.diag) |d| (if (abs >= styles.diag_base and abs - styles.diag_base < d.len and d[abs - styles.diag_base] != 0)
                (if (d[abs - styles.diag_base] == 1) v.theme.diag_error else v.theme.diag_warn)
            else
                hlColor(v, styles, abs)) else hlColor(v, styles, abs);
            // A tab's glyph (a space) sits at its own column; the NEXT cell
            // jumps to the tab stop, so the tab reads as blank whitespace.
            // Offset↔stop stays 1:1 — the caret is exact.
            if (s.len == 1 and s[0] == '\t') try pfx_bytes.append(scratch, ' ') else try pfx_bytes.appendSlice(scratch, s);
            try cells.append(scratch, .{
                .source = .{ .start = @intCast(b0), .end = @intCast(pfx_bytes.items.len) },
                .column = @intCast(col),
                .color = color,
            });
        }
        try stops.append(la, .{ .off = @intCast(abs), .x = v.origin_x + @as(f32, @floatFromInt(col)) * v.cell_w });
        byte += s.len;
        if (s.len == 1 and s[0] == '\t') col = layout.tabStopAfter(col) - 1; // loop's +1 lands on the stop
    }
    try stops.append(la, .{ .off = @intCast(line.start + byte), .x = v.origin_x + @as(f32, @floatFromInt(col)) * v.cell_w });
    // An overlay running past the line's end (a two-letter label on its last
    // character, or one anchored at the newline) finishes in the empty cells
    // beyond it.
    var tail_col = col;
    while (overlays.rest()) |ov| : (tail_col += 1) {
        if (tail_col >= cols_visible) break;
        const b0 = pfx_bytes.items.len;
        try pfx_bytes.appendSlice(scratch, ov.cp);
        try cells.append(scratch, .{
            .source = .{ .start = @intCast(b0), .end = @intCast(pfx_bytes.items.len) },
            .column = @intCast(tail_col),
            .color = ov.color(v),
        });
    }
    try emitMono(v, scratch, la, runs, out, &cells, &pfx_bytes, &stops, .{ .start = seg_start, .end = line.end }, row, seg_top, false);
}

/// The longest line a wrapped pane reads whole (bytes); past it the rest is
/// cut, as an unwrapped pane cuts at its edge.
const max_wrapped_line = 64 * 1024;

/// Shape a mono segment's cells into a run and file its visual line; the
/// buffers start over for the next segment.
fn emitMono(
    v: *View,
    scratch: Allocator,
    la: Allocator,
    runs: *std.ArrayList(Run),
    out: *std.ArrayList(layout.VisualLine),
    cells: *std.ArrayList(text_engine.Cell),
    pfx_bytes: *std.ArrayList(u8),
    stops: *std.ArrayList(layout.Stop),
    src: stemma.Range,
    row: usize,
    top: f32,
    wraps: bool,
) !void {
    const baseline_y = top + v.ascent;
    if (cells.items.len > 0) {
        const shaped = try text_engine.shape(scratch, &v.face_set.mono, pfx_bytes.items, .{});
        try runs.append(scratch, .{ .shaped = shaped, .baseline_y = baseline_y, .place = .{ .cell = cells.items } });
    }
    try out.append(la, .{
        .src = src,
        .row = row,
        .baseline_y = baseline_y,
        .ascent = v.ascent,
        .descent = v.line_h - v.ascent,
        .height = v.line_h,
        .x0 = v.origin_x,
        .stops = stops.items,
        .wraps = wraps,
    });
    cells.* = .empty;
    pfx_bytes.* = .empty;
    stops.* = .empty;
}

/// Lay out a row's `virtual_before` decorations as leading dimmed cells at the
/// front of the shaped buffer. Each decoration anchored within `[line.start,
/// line.end]` contributes its `message` (one mono cell per codepoint, colored
/// by its `kind` via the styles palette); they carry NO caret stop, so the real
/// text (and the caret) begin at the returned column. This is the one render
/// path for placed decorations — files's metadata rides it, and inlay hints /
/// blame / breakpoint glyphs can too. Returns the first real-text column.
fn layoutRowPrefix(
    v: *View,
    scratch: Allocator,
    dl: *const core.layers.Snapshot,
    line: stemma.Range,
    cols_visible: usize,
    pfx_bytes: *std.ArrayList(u8),
    cells: *std.ArrayList(text_engine.Cell),
    start_col: usize,
) !usize {
    // Collect this row's virtual_before decorations, ordered by anchor so a row
    // with several (arrow, then metadata) reads left-to-right deterministically.
    const MAX = 16;
    var segs: [MAX]struct { start: usize, kind: u32, message: []const u8 } = undefined;
    var n: usize = 0;
    for (0..dl.spanCount()) |i| {
        const s = dl.resolvedSpan(i);
        if (s.placement != .virtual_before) continue;
        if (s.start < line.start or s.start > line.end) continue;
        if (n >= MAX) break;
        segs[n] = .{ .start = s.start, .kind = s.kind, .message = s.message };
        n += 1;
    }
    if (n == 0) return start_col;
    std.mem.sort(@TypeOf(segs[0]), segs[0..n], {}, struct {
        fn lt(_: void, a: @TypeOf(segs[0]), b: @TypeOf(segs[0])) bool {
            return a.start < b.start;
        }
    }.lt);

    var col: usize = start_col;
    for (segs[0..n]) |seg| {
        // `role` is a styles-palette class; clamp an out-of-range value rather
        // than panic on @enumFromInt (StyleClass is contiguous 0..=muted).
        const raw: u8 = @truncate(seg.kind);
        const cls: StyleClass = if (raw <= @intFromEnum(StyleClass.muted)) @enumFromInt(raw) else .muted;
        const color = v.theme.styleColor(cls);
        var it = (std.unicode.Utf8View.init(seg.message) catch continue).iterator();
        while (it.nextCodepointSlice()) |cp| {
            if (col >= cols_visible) break;
            const b0 = pfx_bytes.items.len;
            try pfx_bytes.appendSlice(scratch, cp);
            try cells.append(scratch, .{
                .source = .{ .start = @intCast(b0), .end = @intCast(b0 + cp.len) },
                .column = @intCast(col),
                .color = color,
            });
            col += 1;
        }
    }
    return col;
}

/// Lay out this row's `ui/gutter-segment` cells
/// (doc/contextual-workspace-architecture.md §11) as leading dimmed cells,
/// BEFORE the decoration prefix `layoutRowPrefix` builds — the same
/// leading-cell mechanism, generalized to a second producer. `gf.bindings`
/// is the ALREADY-RESOLVED, priority-sorted provider list
/// (`ui_mesh.gutterBindings`, fired once for the whole frame); this call is
/// the "invoke per visible row" half — no Container scan here, one
/// fn-pointer call per (row × eligible provider). Empty `bindings` (nothing
/// bound — today's default) returns 0 immediately without allocating or
/// calling anything past the length check. Returns the first column past the
/// gutter, so the decoration/real-text prefixes continue from there.
fn layoutGutterPrefix(
    v: *View,
    scratch: Allocator,
    gf: ui_mesh.GutterFrame,
    line: stemma.Range,
    row: usize,
    cols_visible: usize,
    pfx_bytes: *std.ArrayList(u8),
    cells: *std.ArrayList(text_engine.Cell),
    start_col: usize,
) !usize {
    if (gf.bindings.len == 0) return start_col;
    var args: ui_mesh.GutterLineArgs = .{
        .line = row,
        .row = line,
        .caret_line = gf.caret_line,
        .line_count = gf.line_count,
        .diag_layer = gf.diag_layer,
        .bp_lines = gf.bp_lines,
        .theme = &v.theme,
        .batch = gf.batch,
    };
    const segs = try ui_mesh.gutterCellsForLine(gf.bindings, scratch, &args);
    var col: usize = start_col;
    for (segs) |seg| {
        const color = seg.fg_override orelse v.theme.roleColor(seg.role);
        var it = (std.unicode.Utf8View.init(seg.text) catch continue).iterator();
        while (it.nextCodepointSlice()) |cp| {
            if (col >= cols_visible) break;
            const b0 = pfx_bytes.items.len;
            try pfx_bytes.appendSlice(scratch, cp);
            try cells.append(scratch, .{
                .source = .{ .start = @intCast(b0), .end = @intCast(b0 + cp.len) },
                .column = @intCast(col),
                .color = color,
            });
            col += 1;
        }
    }
    return col;
}

/// Lay out this row's sign column: every `gutter`-placed span anchored on the
/// row (the entry's own decorations, then the annotation feeds), joined and
/// padded to `styles.mark_cols` so the column is the same width on every row.
/// A mark wider than the column is cut, never allowed to push the text.
fn layoutMarkColumn(
    v: *View,
    scratch: Allocator,
    styles: StyleInputs,
    line: stemma.Range,
    cols_visible: usize,
    pfx_bytes: *std.ArrayList(u8),
    cells: *std.ArrayList(text_engine.Cell),
) !usize {
    const width = @min(styles.mark_cols, cols_visible);
    var col: usize = 0;
    const Walk = struct {
        fn layer(vv: *View, sc: Allocator, dl: *const core.layers.Snapshot, ln: stemma.Range, w: usize, c: *usize, pb: *std.ArrayList(u8), cs: *std.ArrayList(text_engine.Cell)) !void {
            for (0..dl.spanCount()) |i| {
                const s = dl.resolvedSpan(i);
                if (s.placement != .gutter) continue;
                if (s.start < ln.start or s.start > ln.end) continue;
                const color = vv.theme.styleColor(styleClassOf(s.kind));
                var it = (std.unicode.Utf8View.init(s.message) catch continue).iterator();
                while (it.nextCodepointSlice()) |cp| {
                    // Keep the column's last cell blank: it separates the
                    // mark from what follows.
                    if (c.* + 1 >= w) return;
                    const b0 = pb.items.len;
                    try pb.appendSlice(sc, cp);
                    try cs.append(sc, .{
                        .source = .{ .start = @intCast(b0), .end = @intCast(b0 + cp.len) },
                        .column = @intCast(c.*),
                        .color = color,
                    });
                    c.* += 1;
                }
            }
        }
    };
    if (styles.deco) |dl| try Walk.layer(v, scratch, dl, line, width, &col, pfx_bytes, cells);
    for (styles.anno_layers) |*al| try Walk.layer(v, scratch, al, line, width, &col, pfx_bytes, cells);
    return width;
}

/// A span's `kind` as a styles-palette class, clamped rather than trusted
/// (StyleClass is contiguous 0..=muted).
fn styleClassOf(kind: u32) StyleClass {
    const raw: u8 = @truncate(kind);
    return if (raw <= @intFromEnum(StyleClass.muted)) @enumFromInt(raw) else .muted;
}

/// The row's `overlay`-placed spans, consumed left to right as the layout
/// walks the row's cells: at a span's anchor it starts covering cells with
/// its text, one scalar per cell, until the text runs out.
const Overlays = struct {
    const max = 32;
    items: [max]Item = undefined,
    n: usize = 0,
    /// The next span not yet reached.
    at: usize = 0,
    /// The span whose text is covering cells now, and how much of it is left.
    live: ?Live = null,

    const Item = struct { start: usize, kind: u32, message: []const u8 };
    const Live = struct { rest: []const u8, kind: u32 };
    pub const Cp = struct {
        cp: []const u8,
        kind: u32,
        fn color(self: Cp, v: *const View) [4]f32 {
            return v.theme.styleColor(styleClassOf(self.kind));
        }
    };

    fn collect(self: *Overlays, styles: StyleInputs, line: stemma.Range) void {
        if (styles.deco) |dl| self.add(dl, line);
        for (styles.anno_layers) |*al| self.add(al, line);
        std.mem.sort(Item, self.items[0..self.n], {}, struct {
            fn lt(_: void, a: Item, b: Item) bool {
                return a.start < b.start;
            }
        }.lt);
    }

    fn add(self: *Overlays, dl: *const core.layers.Snapshot, line: stemma.Range) void {
        for (0..dl.spanCount()) |i| {
            const s = dl.resolvedSpan(i);
            if (s.placement != .overlay or s.message.len == 0) continue;
            if (s.start < line.start or s.start > line.end) continue;
            if (self.n == max) return;
            self.items[self.n] = .{ .start = s.start, .kind = s.kind, .message = s.message };
            self.n += 1;
        }
    }

    /// The overlay scalar covering the cell at document offset `abs`, if any.
    /// A span reached while another is still covering replaces it — the
    /// later anchor wins its own cell.
    fn next(self: *Overlays, abs: usize) ?Cp {
        while (self.at < self.n and self.items[self.at].start <= abs) : (self.at += 1) {
            if (self.items[self.at].start == abs)
                self.live = .{ .rest = self.items[self.at].message, .kind = self.items[self.at].kind };
        }
        return self.take();
    }

    /// What is left of the covering span once the row's text has ended.
    fn rest(self: *Overlays) ?Cp {
        // A span anchored exactly at the line end (past the last scalar)
        // starts here too.
        if (self.live == null and self.at < self.n)
            self.live = .{ .rest = self.items[self.at].message, .kind = self.items[self.at].kind };
        self.at = self.n;
        return self.take();
    }

    fn take(self: *Overlays) ?Cp {
        const lv = if (self.live) |*l| l else return null;
        if (lv.rest.len == 0) {
            self.live = null;
            return null;
        }
        const n = std.unicode.utf8ByteSequenceLength(lv.rest[0]) catch 1;
        const cp = lv.rest[0..@min(n, lv.rest.len)];
        const out: Cp = .{ .cp = cp, .kind = lv.kind };
        lv.rest = lv.rest[cp.len..];
        if (lv.rest.len == 0) self.live = null;
        return out;
    }
};

/// Per-byte non-caret, non-diagnostic color. Precedence: a third-party
/// annotation role wins (it was published ABOUT this entry, so hiding it under
/// the grammar would make the feed pointless); then syntax highlight for code;
/// then the plugin styles feed paints tool buffers where there is no
/// highlight. Tool buffers never have a grammar, so the last two never overlap
/// in practice — the order just fixes a defined winner if they ever did.
pub fn hlColor(v: *const View, styles: StyleInputs, abs: usize) [4]f32 {
    if (styles.anno) |a| {
        if (abs >= styles.anno_base and abs - styles.anno_base < a.len) {
            const role = a[abs - styles.anno_base];
            if (role != 0) return v.theme.styleColor(@enumFromInt(role - 1));
        }
    }
    if (styles.hl) |h| {
        if (abs >= styles.hl_base and abs - styles.hl_base < h.len)
            return v.theme.classColor(h[abs - styles.hl_base]);
    }
    if (styles.st) |st| {
        if (abs >= styles.st_base and abs - styles.st_base < st.len)
            return v.theme.styleColor(st[abs - styles.st_base]);
    }
    return v.theme.foreground;
}

/// Markdown buffers: split the line into maximal runs of one effective
/// style (face + size + color, including the block-caret recolor), shape
/// each with its face/weight/italic at its em, and place proportionally
/// at an accumulating pen. Line height scales with its largest role.
fn layoutMarkdownLine(
    v: *View,
    scratch: Allocator,
    la: Allocator,
    runs: *std.ArrayList(Run),
    rope: *const stemma.Rope,
    row: usize,
    y_top: f32,
    md: MdInline,
    flips: []const usize,
    wrap: ?Wrap,
    out: *std.ArrayList(layout.VisualLine),
) !void {
    const line = rope.lineRange(row);
    const text = try readLine(scratch, rope, line, if (wrap != null) max_wrapped_line else 4096);
    for (text) |*b| {
        if (b.* == '\t') b.* = ' ';
    }
    // Read, not edited (a popup's document): the syntax markers go, and a
    // line that is nothing but markers (a code fence) goes with them.
    if (md.rendered) {
        var all_markers = text.len > 0;
        for (0..text.len) |k| if (!md.at(line.start + k).marker or md.at(line.start + k).block) {
            all_markers = false;
            break;
        };
        if (all_markers) return;
        // A blank line between blocks is spacing, not a line of nothing.
        if (text.len == 0) {
            const h = @round(v.line_h * 0.5);
            try out.append(la, .{ .src = line, .row = row, .baseline_y = y_top + h, .ascent = h, .descent = 0, .height = h, .x0 = v.origin_x, .stops = try la.dupe(layout.Stop, &.{.{ .off = @intCast(line.end), .x = v.origin_x }}) });
            return;
        }
    }

    // The caret cluster [lo, hi) whose glyph flips to cursor_text: the first
    // caret on the line (a styled run carries one flip range).
    var caret_lo: usize = std.math.maxInt(usize);
    var caret_hi: usize = 0;
    for (flips) |co| {
        if (co >= line.start and co < line.start + text.len) {
            caret_lo = co;
            caret_hi = nextScalar(text, line.start, co);
            break;
        }
    }

    // Line height follows the tallest role on the line (headings).
    var max_scale: f32 = 1;
    for (0..text.len) |k| max_scale = @max(max_scale, inlineStyle(v, md.at(line.start + k)).em / v.em);

    const Shape = struct {
        v: *View,
        md: MdInline,
        text: []const u8,
        base: usize,
        lo: usize,
        hi: usize,

        fn style(self: @This(), k: usize) InlineStyle {
            return effStyle(self.v, self.md, self.base + k, self.lo, self.hi);
        }
        fn hidden(self: @This(), k: usize) bool {
            const a = self.md.at(self.base + k);
            return self.md.rendered and a.marker and !a.block;
        }
    };
    const sh: Shape = .{ .v = v, .md = md, .text = text, .base = line.start, .lo = caret_lo, .hi = caret_hi };

    // Under wrap, measure the whole line first: each scalar's advance, from
    // the same styled shaping the segments draw with.
    const breaks: []const usize = if (wrap) |w| blk: {
        const adv = try scratch.alloc(f32, text.len);
        @memset(adv, 0);
        var i: usize = 0;
        while (i < text.len) {
            if (sh.hidden(i)) {
                i += 1;
                continue;
            }
            const st = sh.style(i);
            var j = i + 1;
            while (j < text.len and !sh.hidden(j) and sh.style(j).eql(st)) j += 1;
            const shaped = try text_engine.shape(scratch, st.faces, text[i..j], .{ .style = st.style });
            for (shaped.glyphs) |g| adv[i + g.source_start] += st.em * g.x_advance;
            i = j;
        }
        const Adv = struct {
            fn width(a: []const f32, byte: usize, s: []const u8, _: f32) f32 {
                var sum: f32 = 0;
                for (a[byte .. byte + s.len]) |x| sum += x;
                return sum;
            }
        };
        break :blk try breaksOf(scratch, text, w.width, @as([]const f32, adv), Adv.width);
    } else &.{};

    var seg_from: usize = 0;
    var top = y_top;
    for (0..breaks.len + 1) |k| {
        const seg_to = if (k < breaks.len) breaks[k] else text.len;
        const wraps = k < breaks.len;
        const ascent = v.ascent * max_scale;
        const baseline_y = top + ascent;
        var stops: std.ArrayList(layout.Stop) = .empty;
        var pen: f32 = v.origin_x;
        var i = seg_from;
        while (i < seg_to) {
            if (sh.hidden(i)) {
                try stops.append(la, .{ .off = @intCast(line.start + i), .x = pen });
                i += 1;
                continue;
            }
            const st = sh.style(i);
            var j = i + 1;
            while (j < seg_to and !sh.hidden(j) and sh.style(j).eql(st)) j += 1;
            const shaped = try text_engine.shape(scratch, st.faces, text[i..j], .{ .style = st.style });
            for (shaped.glyphs) |g| {
                try stops.append(la, .{ .off = @intCast(line.start + i + g.source_start), .x = pen + st.em * g.x_offset });
            }
            try runs.append(scratch, .{
                .shaped = shaped,
                .baseline_y = baseline_y,
                .place = .{ .prop = .{ .x = pen, .em = st.em, .color = st.color } },
            });
            pen += shaped.advanceX() * st.em;
            i = j;
        }
        try stops.append(la, .{ .off = @intCast(line.start + seg_to), .x = pen });
        try out.append(la, .{
            .src = .{ .start = line.start + seg_from, .end = if (wraps) line.start + seg_to else line.end },
            .row = row,
            .baseline_y = baseline_y,
            .ascent = ascent,
            .descent = v.line_h * max_scale - ascent,
            .height = v.line_h * max_scale,
            .x0 = v.origin_x,
            .stops = stops.items,
            .wraps = wraps,
        });
        top += v.line_h * max_scale;
        seg_from = seg_to;
        if (wraps) if (wrap) |w| if (top >= w.y_limit) return;
    }
}

/// Base style for a markdown attribute: role → size + face family,
/// bold/italic → sans variant, marker/link/code/heading → color.
fn inlineStyle(v: *View, a: InlineAttr) InlineStyle {
    if (a.role == .code) {
        return .{
            .faces = &v.face_set.mono,
            .style = .{},
            .em = v.em,
            .color = if (a.marker) v.theme.md_marker else v.theme.md_code,
        };
    }
    const scale: f32 = switch (a.role) {
        .h1 => 2.0,
        .h2 => 1.6,
        .h3 => 1.3,
        .h4 => 1.15,
        .h5 => 1.05,
        else => 1.0,
    };
    const heading = a.role != .normal;
    const color = if (a.marker)
        v.theme.md_marker
    else if (a.link)
        v.theme.md_link
    else if (heading)
        v.theme.heading
    else
        v.theme.foreground;
    return .{
        .faces = &v.face_set.body,
        .style = .{ .weight = if (a.bold or heading) .bold else .regular, .italic = a.italic },
        .em = v.em * scale,
        .color = color,
    };
}

/// `inlineStyle` with the block-caret glyph recolored to cursor_text.
fn effStyle(v: *View, md: MdInline, off: usize, caret_lo: usize, caret_hi: usize) InlineStyle {
    var st = inlineStyle(v, md.at(off));
    if (off >= caret_lo and off < caret_hi) st.color = v.theme.cursor_text;
    return st;
}

// ── Helpers ──

/// Read up to `cap` bytes of a line into `scratch`, dropping any trailing
/// partial UTF-8 scalar the cap may have cut.
fn readLine(scratch: Allocator, rope: *const stemma.Rope, line: stemma.Range, cap_hint: usize) ![]u8 {
    const cap = @min(line.len(), cap_hint);
    const raw = try scratch.alloc(u8, cap);
    var sr = rope.streamReader(.{ .start = line.start, .end = line.start + cap }, &.{});
    sr.interface.readSliceAll(raw) catch unreachable;
    var end = raw.len;
    if (cap < line.len()) {
        while (end > 0 and (raw[end - 1] & 0xC0) == 0x80) end -= 1;
        if (end > 0 and raw[end - 1] >= 0xC0) end -= 1;
    }
    return raw[0..end];
}

/// Absolute offset of the scalar boundary after `off` within `text`.
fn nextScalar(text: []const u8, base: usize, off: usize) usize {
    var k = off - base + 1;
    while (k < text.len and (text[k] & 0xC0) == 0x80) k += 1;
    return base + k;
}

// ── Tests ──

const testing = std.testing;

/// The whole of `doc`, as a snapshot window.
fn wholeOf(doc: *const core.Document) stemma.Range {
    return .{ .start = 0, .end = doc.text().byteLen() };
}

/// Every feed in `feeds` as the frame would take it now.
fn snapshotsOf(a: Allocator, doc: *const core.Document, feeds: []const *const core.layers.Layer) ![]const core.layers.Snapshot {
    const out = try a.alloc(core.layers.Snapshot, feeds.len);
    for (feeds, out) |f, *s| s.* = try f.snapshot(a, wholeOf(doc));
    return out;
}

test "styles: a published styles bulk resolves to StyleClass colors; highlight wins" {
    const gpa = testing.allocator;
    var v = try View.init(gpa, font_provider.defaultMono(), 16);
    defer v.deinit();

    // A styles feed (as the host publishes it): one class byte per doc byte.
    var classes = [_]u8{
        @intFromEnum(StyleClass.added),
        @intFromEnum(StyleClass.removed),
        @intFromEnum(StyleClass.location),
        @intFromEnum(StyleClass.normal),
    };
    const si: StyleInputs = .{ .st = @ptrCast(classes[0..]), .st_base = 0 };
    try testing.expectEqual(v.theme.styleColor(.added), hlColor(&v, si, 0));
    try testing.expectEqual(v.theme.styleColor(.removed), hlColor(&v, si, 1));
    try testing.expectEqual(v.theme.styleColor(.location), hlColor(&v, si, 2));
    try testing.expectEqual(v.theme.foreground, hlColor(&v, si, 3)); // .normal
    try testing.expectEqual(v.theme.foreground, hlColor(&v, si, 99)); // out of range

    // Where both feeds cover a byte, syntax highlight wins (a code buffer never
    // has styles, but the precedence is defined).
    var hl = [_]u8{@intFromEnum(HighlightClass.keyword)};
    const si2: StyleInputs = .{ .hl = @ptrCast(hl[0..]), .st = @ptrCast(classes[0..]) };
    try testing.expectEqual(v.theme.classColor(.keyword), hlColor(&v, si2, 0));
}

test "styles: Hud.styles_layer flows through resolveStyleInputs (the render seam)" {
    const gpa = testing.allocator;
    var v = try View.init(gpa, font_provider.defaultMono(), 16);
    defer v.deinit();

    // A plugin-published styles layer, exactly as the host writes it: a zeroed
    // class-per-byte baseline over the buffer, then two painted bytes.
    var doc = try core.Document.init(gpa, "user");
    defer doc.deinit(gpa);
    try doc.insert(gpa, 0, "+add\n-del\n");
    var store: core.layers.Layers = .empty;
    defer store.deinit(gpa);
    const layer = try store.claim(gpa, &doc, "styles", .local, "git");
    var classes = [_]u8{0} ** 10;
    classes[0] = @intFromEnum(StyleClass.added); // the '+'
    classes[5] = @intFromEnum(StyleClass.removed); // the '-'
    const version = try doc.version(gpa);
    defer gpa.free(version);
    try layer.publishBulk(gpa, version, 0, &classes);

    // The Hud carries the layer (as main.zig threads it); resolveStyleInputs
    // lifts its bulk into StyleInputs.st, and the per-cell path resolves colors.
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const snap = try layer.snapshot(arena.allocator(), wholeOf(&doc));
    const hud: Hud = .{ .mode = "normal", .styles_layer = &snap };
    const si = try resolveStyleInputs(arena.allocator(), hud, doc.text(), 0, 2, 2);
    try testing.expect(si.st != null);
    try testing.expectEqual(v.theme.styleColor(.added), hlColor(&v, si, 0));
    try testing.expectEqual(v.theme.styleColor(.removed), hlColor(&v, si, 5));
    try testing.expectEqual(v.theme.foreground, hlColor(&v, si, 1)); // unpainted
}

test "decorations: a virtual_before decoration draws leading cells and shifts the caret; the doc text is only the name" {
    const gpa = testing.allocator;
    var v = try View.init(gpa, font_provider.defaultMono(), 16);
    defer v.deinit();

    // A files-style row: the document text is ONLY the editable name; the
    // metadata is a virtual_before decoration anchored at the name start.
    var doc = try core.Document.init(gpa, "user");
    defer doc.deinit(gpa);
    try doc.insert(gpa, 0, "main.zig\n");
    var store: core.layers.Layers = .empty;
    defer store.deinit(gpa);
    const layer = try store.claim(gpa, &doc, "decorations", .local, "files");
    const meta = "-rw- "; // 5 display columns of chrome
    try layer.appendSpan(gpa, .{ .start = 0, .end = 0, .kind = @intFromEnum(StyleClass.muted), .message = meta, .placement = .virtual_before });

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const snap = try layer.snapshot(a, wholeOf(&doc));
    const hud: Hud = .{ .mode = "normal", .decorations_layer = &snap };
    const si = try resolveStyleInputs(a, hud, doc.text(), 0, 1, 1);
    try testing.expect(si.deco == &snap);

    var runs: std.ArrayList(Run) = .empty;
    const vl = try layoutLine(&v, a, a, &runs, doc.text(), 0, 0, 40, null, si, &.{});

    // The caret at the line start (offset 0) sits AFTER the 5-column prefix —
    // the decoration displaced the text without becoming part of it.
    try testing.expectEqual(@as(usize, 0), vl.stops[0].off);
    try testing.expectApproxEqAbs(v.origin_x + 5 * v.cell_w, vl.stops[0].x, 0.01);
    // One run, holding prefix cells (5) + name cells ("main.zig" = 8) = 13.
    try testing.expectEqual(@as(usize, 1), runs.items.len);
    try testing.expectEqual(@as(usize, 13), runs.items[0].place.cell.len);
    // The name cells begin at column 5 (past the prefix).
    try testing.expectEqual(@as(u32, 5), runs.items[0].place.cell[5].column);
    // yy-name-only is structural: the document holds no metadata bytes at all.
    const s = try doc.text().toOwnedSlice(gpa);
    defer gpa.free(s);
    try testing.expectEqualStrings("main.zig\n", s);
}

test "gutter: a bound line-numbers provider draws leading cells through the real render path" {
    const gpa = testing.allocator;
    var v = try View.init(gpa, font_provider.defaultMono(), 16);
    defer v.deinit();

    var doc = try core.Document.init(gpa, "user");
    defer doc.deinit(gpa);
    try doc.insert(gpa, 0, "main.zig\n");

    // The real mesh machinery end-to-end: declared slots, the DEFAULT gutter
    // providers (unbound in production — this test is the proof they would
    // RENDER if bound, closing the bound-but-invisible third-result gap),
    // resolved once per frame, invoked per row by layoutGutterPrefix.
    var mesh = core.container.Container.init(gpa);
    defer mesh.deinit();
    try ui_mesh.declareSlots(&mesh);
    try ui_mesh.bindDefaultGutter(&mesh);

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const bindings = try ui_mesh.gutterBindings(&mesh, a, .{ .mode = "normal" });
    try testing.expectEqual(@as(usize, 3), bindings.len);

    const si: StyleInputs = .{ .gutter = .{ .bindings = bindings } };
    var runs: std.ArrayList(Run) = .empty;
    const vl = try layoutLine(&v, a, a, &runs, doc.text(), 0, 0, 40, null, si, &.{});

    // Row 0 → "1 " = 2 leading gutter cells; diag/breakpoint providers opt
    // out (no layer, no bp lines), contributing nothing. The caret at
    // offset 0 sits past the gutter, exactly like the decoration prefix.
    try testing.expectEqual(@as(usize, 0), vl.stops[0].off);
    try testing.expectApproxEqAbs(v.origin_x + 2 * v.cell_w, vl.stops[0].x, 0.01);
    try testing.expectEqual(@as(usize, 1), runs.items.len);
    // 2 gutter cells + "main.zig" (8) = 10 cells; text starts at column 2.
    try testing.expectEqual(@as(usize, 10), runs.items[0].place.cell.len);
    try testing.expectEqual(@as(u32, 2), runs.items[0].place.cell[2].column);
    // The document holds no gutter bytes — the gutter is chrome, not content.
    const s = try doc.text().toOwnedSlice(gpa);
    defer gpa.free(s);
    try testing.expectEqualStrings("main.zig\n", s);
}

test "gutter placement: a breakpoint mark draws in a sign column every row shares" {
    const gpa = testing.allocator;
    var v = try View.init(gpa, font_provider.defaultMono(), 16);
    defer v.deinit();

    var doc = try core.Document.init(gpa, "user");
    defer doc.deinit(gpa);
    try doc.insert(gpa, 0, "one\ntwo\n");
    var store: core.layers.Layers = .empty;
    defer store.deinit(gpa);
    // What the `debug` plugin publishes for a breakpoint on line 2.
    const layer = try store.claim(gpa, &doc, "decorations", .local, "debug");
    try layer.appendSpan(gpa, .{ .start = 4, .end = 4, .kind = @intFromEnum(StyleClass.removed), .message = "\u{25CF}", .placement = .gutter });

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const snap = try layer.snapshot(a, wholeOf(&doc));
    const hud: Hud = .{ .mode = "normal", .decorations_layer = &snap };
    const si = try resolveStyleInputs(a, hud, doc.text(), 0, 2, 3);
    try testing.expectEqual(@as(usize, 2), si.mark_cols); // the dot + a blank

    // The marked row draws the dot at column 0; BOTH rows start their text at
    // column 2, so a mark never pushes one line out of alignment.
    var runs: std.ArrayList(Run) = .empty;
    const marked = try layoutLine(&v, a, a, &runs, doc.text(), 1, 0, 40, null, si, &.{});
    try testing.expectApproxEqAbs(v.origin_x + 2 * v.cell_w, marked.stops[0].x, 0.01);
    try testing.expectEqual(@as(u32, 0), runs.items[0].place.cell[0].column);
    try testing.expectEqual(v.theme.styleColor(.removed), runs.items[0].place.cell[0].color);
    var plain_runs: std.ArrayList(Run) = .empty;
    const plain = try layoutLine(&v, a, a, &plain_runs, doc.text(), 0, 0, 40, null, si, &.{});
    try testing.expectApproxEqAbs(v.origin_x + 2 * v.cell_w, plain.stops[0].x, 0.01);
    // …and a row without a mark draws nothing in the column: "one" only.
    try testing.expectEqual(@as(usize, 3), plain_runs.items[0].place.cell.len);
}

test "overlay placement: a label covers its cell without moving any text" {
    const gpa = testing.allocator;
    var v = try View.init(gpa, font_provider.defaultMono(), 16);
    defer v.deinit();

    var doc = try core.Document.init(gpa, "user");
    defer doc.deinit(gpa);
    try doc.insert(gpa, 0, "alpha beta\n");
    var store: core.layers.Layers = .empty;
    defer store.deinit(gpa);
    // Two jump labels, the way the `labels` library (helix `gw`) publishes
    // them: over the `a` at 4 and the `a` at 9 (the last character — a
    // two-letter label runs past it).
    const labels = try store.claimAnnotation(gpa, &doc, "labels", "helix");
    labels.begin(gpa);
    try labels.appendSpan(gpa, .{ .start = 4, .end = 4, .kind = @intFromEnum(StyleClass.removed), .message = "s", .placement = .overlay });
    try labels.appendSpan(gpa, .{ .start = 9, .end = 9, .kind = @intFromEnum(StyleClass.removed), .message = "df", .placement = .overlay });

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const feeds = try store.annotations(a, &doc);
    const hud: Hud = .{ .mode = "normal", .annotations = try snapshotsOf(a, &doc, feeds) };
    const si = try resolveStyleInputs(a, hud, doc.text(), 0, 1, 1);
    var runs: std.ArrayList(Run) = .empty;
    const vl = try layoutLine(&v, a, a, &runs, doc.text(), 0, 0, 40, null, si, &.{});

    // No prefix, and every stop where it was: the caret maps exactly.
    try testing.expectApproxEqAbs(v.origin_x, vl.stops[0].x, 0.01);
    try testing.expectApproxEqAbs(v.origin_x + 4 * v.cell_w, vl.stops[4].x, 0.01);
    // "alpha beta" is 10 cells, plus the label's second letter past the end.
    const cells = runs.items[0].place.cell;
    try testing.expectEqual(@as(usize, 11), cells.len);
    try testing.expectEqual(@as(u32, 10), cells[10].column);
    // The covered cells take the label's color; their neighbors keep theirs.
    try testing.expectEqual(v.theme.styleColor(.removed), cells[4].color);
    try testing.expectEqual(v.theme.styleColor(.removed), cells[9].color);
    try testing.expectEqual(v.theme.foreground, cells[3].color);
    // The glyph sources are the labels' bytes, not the text's.
    try testing.expectEqual(@as(usize, 11), runs.items[0].shaped.glyphs.len);

    // Under a block caret — any selection's, not only the primary's — a
    // glyph draws in `cursor_text`, a label's included, so it stays legible.
    var flipped_runs: std.ArrayList(Run) = .empty;
    _ = try layoutLine(&v, a, a, &flipped_runs, doc.text(), 0, 0, 40, null, si, &.{ 0, 4, 6 });
    const flipped_cells = flipped_runs.items[0].place.cell;
    try testing.expectEqual(v.theme.cursor_text, flipped_cells[0].color);
    try testing.expectEqual(v.theme.cursor_text, flipped_cells[4].color);
    try testing.expectEqual(v.theme.cursor_text, flipped_cells[6].color);
    try testing.expectEqual(v.theme.foreground, flipped_cells[5].color);
    try testing.expectEqual(v.theme.styleColor(.removed), flipped_cells[9].color);
}

test "annotations: the presentation composites third-party feeds it was never told about" {
    const gpa = testing.allocator;
    var v = try View.init(gpa, font_provider.defaultMono(), 16);
    defer v.deinit();

    var doc = try core.Document.init(gpa, "user");
    defer doc.deinit(gpa);
    try doc.insert(gpa, 0, "// TODO: ship\n");
    var store: core.layers.Layers = .empty;
    defer store.deinit(gpa);

    // Two decorators over one entry, neither of them named anywhere in this
    // file or in the view: a keyword highlighter (a face over its range) and
    // a lens (virtual text beside the line).
    const marks = try store.claimAnnotation(gpa, &doc, "marks", "marks");
    marks.begin(gpa);
    try marks.appendSpan(gpa, .{ .start = 3, .end = 7, .kind = @intFromEnum(StyleClass.emphasis), .message = "" });
    const lens = try store.claimAnnotation(gpa, &doc, "lens", "codelens");
    lens.begin(gpa);
    try lens.appendSpan(gpa, .{ .start = 0, .end = 0, .kind = @intFromEnum(StyleClass.muted), .message = "2 refs ", .placement = .virtual_before });

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const feeds = try store.annotations(a, &doc);
    const hud: Hud = .{ .mode = "normal", .annotations = try snapshotsOf(a, &doc, feeds) };
    const si = try resolveStyleInputs(a, hud, doc.text(), 0, 1, 1);

    // The range feed colors its bytes by role; everything else is untouched.
    try testing.expectEqual(v.theme.styleColor(.emphasis), hlColor(&v, si, 3));
    try testing.expectEqual(v.theme.foreground, hlColor(&v, si, 2));

    // The placed feed draws leading cells, exactly like a projection's own
    // decorations, and displaces the caret without entering the document.
    var runs: std.ArrayList(Run) = .empty;
    const vl = try layoutLine(&v, a, a, &runs, doc.text(), 0, 0, 40, null, si, &.{});
    try testing.expectEqual(@as(usize, 0), vl.stops[0].off);
    try testing.expectApproxEqAbs(v.origin_x + 7 * v.cell_w, vl.stops[0].x, 0.01);

    // An edit moves the entry past both stamps: the next frame's snapshot of
    // them is empty until the decorators republish — a stale span is never
    // guessed onto new text.
    try doc.insert(gpa, 0, "\n");
    const next: Hud = .{ .mode = "normal", .annotations = try snapshotsOf(a, &doc, feeds) };
    const stale = try resolveStyleInputs(a, next, doc.text(), 0, 2, 2);
    try testing.expect(stale.anno == null);
    var stale_runs: std.ArrayList(Run) = .empty;
    const stale_line = try layoutLine(&v, a, a, &stale_runs, doc.text(), 1, 0, 40, null, stale, &.{});
    try testing.expectApproxEqAbs(v.origin_x, stale_line.stops[0].x, 0.01);
}

test "soft wrap breaks after the last space in reach, mid-word only when a word is longer than the room" {
    const Unit = struct {
        fn width(_: void, _: usize, _: []const u8, _: f32) f32 {
            return 1;
        }
    };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // "alpha beta gamma" in 11 cells: "alpha beta " | "gamma".
    try testing.expectEqualSlices(usize, &.{11}, try breaksOf(a, "alpha beta gamma", 11, {}, Unit.width));
    // In 8: "alpha " | "beta " | "gamma".
    try testing.expectEqualSlices(usize, &.{ 6, 11 }, try breaksOf(a, "alpha beta gamma", 8, {}, Unit.width));
    // A word longer than the room breaks inside it.
    try testing.expectEqualSlices(usize, &.{ 4, 8 }, try breaksOf(a, "abcdefghij", 4, {}, Unit.width));
    // What fits does not break.
    try testing.expectEqual(@as(usize, 0), (try breaksOf(a, "short", 40, {}, Unit.width)).len);
}
