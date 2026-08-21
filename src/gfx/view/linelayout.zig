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
    /// the text, never in the document. dired's metadata/arrow/mark ride this,
    /// so the buffer text is only the editable name (yy yanks the name alone).
    deco: ?*const core.layers.Layer = null,
    /// The `ui/gutter-segment` mesh's per-frame resolution (north-star-plan
    /// §6 W3-1), passed through from `Hud.gutter` unchanged — null (today's
    /// default) means no gutter cells render, at the cost of one pointer
    /// copy per frame.
    gutter: ?ui_mesh.GutterFrame = null,
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
    s.deco = hud.decorations_layer;
    s.gutter = hud.gutter;
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
    // Virtual-text prefix: decorations anchored on this row (dired's metadata/
    // arrow/mark) laid out as leading dimmed cells at the front of the shaped
    // buffer. They carry NO stop, so the caret (mapped through stops) sits after
    // them, and they're never in the document — `yy` yanks only the real line.
    var pfx_bytes: std.ArrayList(u8) = .empty;
    var col: usize = 0;
    if (styles.gutter) |gf| col = try layoutGutterPrefix(v, scratch, gf, line, row, cols_visible, &pfx_bytes, &cells);
    if (styles.deco) |dl| col = try layoutRowPrefix(v, scratch, dl, line, cols_visible, &pfx_bytes, &cells, col);
    const pfx_len = pfx_bytes.items.len;

    var it = (std.unicode.Utf8View.init(text) catch return error.InvalidUtf8).iterator();
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
            // Source indexes the shaped buffer, whose real text sits after the
            // virtual prefix bytes — so shift real cells past `pfx_len`.
            .source = .{ .start = @intCast(pfx_len + byte), .end = @intCast(pfx_len + byte + s.len) },
            .column = @intCast(col),
            .color = color,
        });
        try stops.append(la, .{ .off = @intCast(abs), .x = v.origin_x + @as(f32, @floatFromInt(col)) * v.cell_w });
        byte += s.len;
        if (s.len == 1 and s[0] == '\t') col = layout.tabStopAfter(col) - 1; // loop's +1 lands on the stop
    }
    try stops.append(la, .{ .off = @intCast(line.start + byte), .x = v.origin_x + @as(f32, @floatFromInt(col)) * v.cell_w });

    if (cells.items.len > 0) {
        // Shaped buffer = the virtual prefix bytes, then the real line (tabs→
        // space). Prefix cells source into the head; real cells into the tail.
        const shbuf = try scratch.alloc(u8, pfx_len + byte);
        @memcpy(shbuf[0..pfx_len], pfx_bytes.items);
        @memcpy(shbuf[pfx_len..], text[0..byte]);
        for (shbuf[pfx_len..]) |*b| {
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

/// Lay out a row's `virtual_before` decorations as leading dimmed cells at the
/// front of the shaped buffer. Each decoration anchored within `[line.start,
/// line.end]` contributes its `message` (one mono cell per codepoint, colored
/// by its `kind` via the styles palette); they carry NO caret stop, so the real
/// text (and the caret) begin at the returned column. This is the one render
/// path for placed decorations — dired's metadata rides it, and inlay hints /
/// blame / breakpoint glyphs can too. Returns the first real-text column.
fn layoutRowPrefix(
    v: *View,
    scratch: Allocator,
    dl: *const core.layers.Layer,
    line: stemma.Range,
    cols_visible: usize,
    pfx_bytes: *std.ArrayList(u8),
    cells: *std.ArrayList(snail.Cell),
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

/// Lay out this row's `ui/gutter-segment` cells (north-star-plan §6 W3-1) as
/// leading dimmed cells, BEFORE the decoration prefix `layoutRowPrefix`
/// builds — the same leading-cell mechanism, generalized to a second
/// producer. `gf.bindings` is the ALREADY-RESOLVED, priority-sorted provider
/// list (`ui_mesh.gutterBindings`, fired once for the whole frame); this
/// call is the "invoke per visible row" half — no Container scan here, one
/// fn-pointer call per (row × eligible provider). Empty `bindings` (nothing
/// bound — today's default) returns 0 immediately without allocating or
/// calling anything past the length check. Returns the first column past
/// the gutter, so the decoration/real-text prefixes continue from there.
fn layoutGutterPrefix(
    v: *View,
    scratch: Allocator,
    gf: ui_mesh.GutterFrame,
    line: stemma.Range,
    row: usize,
    cols_visible: usize,
    pfx_bytes: *std.ArrayList(u8),
    cells: *std.ArrayList(snail.Cell),
) !usize {
    if (gf.bindings.len == 0) return 0;
    var args: ui_mesh.GutterLineArgs = .{
        .line = row,
        .row = line,
        .diag_layer = gf.diag_layer,
        .bp_lines = gf.bp_lines,
        .theme = &v.theme,
    };
    const segs = try ui_mesh.gutterCellsForLine(gf.bindings, scratch, &args);
    var col: usize = 0;
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

test "decorations: a virtual_before decoration draws leading cells and shifts the caret; the doc text is only the name" {
    const gpa = testing.allocator;
    var v = try View.init(gpa, @embedFile("font_mono"), 16);
    defer v.deinit();

    // A dired-style row: the document text is ONLY the editable name; the
    // metadata is a virtual_before decoration anchored at the name start.
    var doc = try core.Document.init(gpa, "user");
    defer doc.deinit(gpa);
    try doc.insert(gpa, 0, "main.zig\n");
    var store: core.layers.Layers = .empty;
    defer store.deinit(gpa);
    const layer = try store.claim(gpa, &doc, "decorations", .local, "dired");
    const meta = "-rw- "; // 5 display columns of chrome
    try layer.appendSpan(gpa, .{ .start = 0, .end = 0, .kind = @intFromEnum(StyleClass.muted), .message = meta, .placement = .virtual_before });

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const hud: Hud = .{ .mode = "normal", .decorations_layer = layer };
    const si = try resolveStyleInputs(&v, a, hud, doc.text(), 1, 1);
    try testing.expect(si.deco == layer);

    var runs: std.ArrayList(Run) = .empty;
    const vl = try layoutLine(&v, a, a, &runs, doc.text(), 0, 0, 40, null, si, null);

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
    var v = try View.init(gpa, @embedFile("font_mono"), 16);
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
    const vl = try layoutLine(&v, a, a, &runs, doc.text(), 0, 0, 40, null, si, null);

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
