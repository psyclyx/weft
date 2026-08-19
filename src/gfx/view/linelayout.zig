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

const snail = @import("snail");
const stemma = @import("stemma");
const core = @import("../../core/core.zig");
const layout = @import("../layout.zig");
const view = @import("../view.zig");

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
};

/// The face + size + color a markdown attribute renders as.
const InlineStyle = struct {
    faces: *snail.Faces,
    style: snail.FontStyle,
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
    v: *View,
    scratch: Allocator,
    hud: Hud,
    rope: *const stemma.Rope,
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
    if (diag_count > 0 and rows_visible > 0 and v.top_row < total_rows) {
        const dl = hud.diag_layer.?;
        const last = @min(total_rows, v.top_row + rows_visible);
        const vis_start = rope.lineRange(v.top_row).start;
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
    return s;
}

// ── Line layout (the shared primitive) ───────────────────────────

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
    flip_off: ?usize,
) !layout.VisualLine {
    return if (md) |m|
        layoutMarkdownLine(v, scratch, la, runs, rope, row, y_top, m, flip_off)
    else
        layoutMonoLine(v, scratch, la, runs, rope, row, y_top, cols_visible, styles, flip_off);
}

/// Plain buffers: one mono cell per scalar on the pixel grid (uniform
/// advances). Per-cell color from the caret flip, diagnostics, then
/// highlight. Stops fall on integer columns — the degenerate case.
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
    flip_off: ?usize,
) !layout.VisualLine {
    const line = rope.lineRange(row);
    const baseline_y = y_top + v.ascent;
    const text = try readLine(scratch, rope, line, cols_visible * 4 + 4);

    var cells: std.ArrayList(snail.Cell) = .empty;
    var stops: std.ArrayList(layout.Stop) = .empty;
    var it = (std.unicode.Utf8View.init(text) catch return error.InvalidUtf8).iterator();
    var col: usize = 0;
    var byte: usize = 0;
    while (it.nextCodepointSlice()) |s| : (col += 1) {
        if (col >= cols_visible) break;
        const abs = line.start + byte;
        const color = if (flip_off != null and flip_off.? == abs)
            v.theme.cursor_text
        else if (styles.diag) |d| (if (abs >= styles.diag_base and abs - styles.diag_base < d.len and d[abs - styles.diag_base] != 0)
            (if (d[abs - styles.diag_base] == 1) v.theme.diag_error else v.theme.diag_warn)
        else
            hlColor(v, styles, abs)) else hlColor(v, styles, abs);
        // A tab's glyph (a space, substituted below) sits at its own
        // column; the NEXT cell jumps to the tab stop, so the tab reads
        // as blank whitespace. Offset↔stop stays 1:1 — the caret is exact.
        try cells.append(scratch, .{
            .source = .{ .start = @intCast(byte), .end = @intCast(byte + s.len) },
            .column = @intCast(col),
            .color = color,
        });
        try stops.append(la, .{ .off = @intCast(abs), .x = v.origin_x + @as(f32, @floatFromInt(col)) * v.cell_w });
        byte += s.len;
        if (s.len == 1 and s[0] == '\t') col = layout.tabStopAfter(col) - 1; // loop's +1 lands on the stop
    }
    try stops.append(la, .{ .off = @intCast(line.start + byte), .x = v.origin_x + @as(f32, @floatFromInt(col)) * v.cell_w });

    if (cells.items.len > 0) {
        const shbuf = try scratch.dupe(u8, text[0..byte]);
        for (shbuf) |*b| {
            if (b.* == '\t') b.* = ' ';
        }
        const shaped = try snail.shape(scratch, &v.face_set.mono, shbuf, .{});
        try runs.append(scratch, .{ .shaped = shaped, .baseline_y = baseline_y, .place = .{ .cell = cells.items } });
    }
    return .{
        .src = line,
        .row = row,
        .baseline_y = baseline_y,
        .ascent = v.ascent,
        .descent = v.line_h - v.ascent,
        .height = v.line_h,
        .x0 = v.origin_x,
        .stops = stops.items,
    };
}

/// Per-byte non-caret, non-diagnostic color. Precedence: syntax highlight
/// wins for code; the plugin styles feed paints tool buffers where there is
/// no highlight. Tool buffers never have a grammar, so the two never overlap
/// in practice — the order just fixes a defined winner if they ever did.
pub fn hlColor(v: *const View, styles: StyleInputs, abs: usize) [4]f32 {
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
    flip_off: ?usize,
) !layout.VisualLine {
    const line = rope.lineRange(row);
    const text = try readLine(scratch, rope, line, 4096);
    for (text) |*b| {
        if (b.* == '\t') b.* = ' ';
    }

    // The caret cluster [lo, hi) whose glyph flips to cursor_text.
    var caret_lo: usize = std.math.maxInt(usize);
    var caret_hi: usize = 0;
    if (flip_off) |co| {
        if (co >= line.start and co < line.start + text.len) {
            caret_lo = co;
            caret_hi = nextScalar(text, line.start, co);
        }
    }

    // Line height follows the tallest role on the line (headings).
    var max_scale: f32 = 1;
    for (0..text.len) |k| max_scale = @max(max_scale, inlineStyle(v, md.at(line.start + k)).em / v.em);
    const ascent = v.ascent * max_scale;
    const baseline_y = y_top + ascent;

    var stops: std.ArrayList(layout.Stop) = .empty;
    var pen: f32 = v.origin_x;
    var i: usize = 0;
    while (i < text.len) {
        const st = effStyle(v, md, line.start + i, caret_lo, caret_hi);
        var j = i + 1;
        while (j < text.len and effStyle(v, md, line.start + j, caret_lo, caret_hi).eql(st)) j += 1;
        const shaped = try snail.shape(scratch, st.faces, text[i..j], .{ .style = st.style });
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
    try stops.append(la, .{ .off = @intCast(line.end), .x = pen });

    return .{
        .src = line,
        .row = row,
        .baseline_y = baseline_y,
        .ascent = ascent,
        .descent = v.line_h * max_scale - ascent,
        .height = v.line_h * max_scale,
        .x0 = v.origin_x,
        .stops = stops.items,
    };
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

test "styles: a published styles bulk resolves to StyleClass colors; highlight wins" {
    const gpa = testing.allocator;
    var v = try View.init(gpa, @embedFile("font_mono"), 16);
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
    var v = try View.init(gpa, @embedFile("font_mono"), 16);
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
    const hud: Hud = .{ .mode = "normal", .styles_layer = layer };
    const si = try resolveStyleInputs(&v, arena.allocator(), hud, doc.text(), 2, 2);
    try testing.expect(si.st != null);
    try testing.expectEqual(v.theme.styleColor(.added), hlColor(&v, si, 0));
    try testing.expectEqual(v.theme.styleColor(.removed), hlColor(&v, si, 5));
    try testing.expectEqual(v.theme.foreground, hlColor(&v, si, 1)); // unpainted
}
