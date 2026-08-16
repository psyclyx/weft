//! View — Editor state → snail shapes.
//!
//! One layout model, two placements. Every visible line is laid out into
//! `Run`s and caret `Stop`s by a single primitive; the *same* stops feed
//! both the rendered picture and the source-offset ↔ geometry map (motion,
//! hit-testing, caret, selection). Plain buffers place each line on the
//! monospace cell grid (uniform advances — the degenerate case, pixel-crisp
//! via `CellSnap.grid`); markdown buffers place proportional runs at varying
//! faces and sizes. Caret and selection are solid rectangles (one resident
//! unit-square record, placed by an affine transform) — no extra pipeline.
//!
//! The view is a pure subscriber: it reads the rope and the editor's
//! cursor/selection plus published style feeds (highlight, diagnostics,
//! markdown), and owns only presentation state (scroll, metrics, atlas
//! residency). Damage is the caller's concern; atlas growth is reported.

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const snail = @import("snail");
const stemma = @import("stemma");
const core = @import("../core/core.zig");
const prepare = @import("prepare.zig");
const layout = @import("layout.zig");
const fonts = @import("fonts.zig");

const InlineAttr = core.capability.InlineAttr;
const HighlightClass = core.capability.HighlightClass;

const font_id_mono = fonts.font_id_mono;
const margin: f32 = 8;

/// Caret shape. Configurable per mode by the host (vim: block in normal,
/// bar in insert). `block` covers the glyph (which flips to `cursor_text`);
/// `bar`/`underline` sit beside/under it and never recolor the glyph.
pub const CursorStyle = enum { block, bar, underline };

/// Per-byte markdown styling over a source window, published by the
/// markdown runtime and consumed here. `attrs[i]` styles byte `base + i`.
pub const MdInline = struct {
    base: usize,
    attrs: []const InlineAttr,

    fn at(self: MdInline, off: usize) InlineAttr {
        if (off < self.base or off - self.base >= self.attrs.len) return .{};
        return self.attrs[off - self.base];
    }
};

/// sRGB-authored theme, converted to linear at init (snail's color ABI
/// is linear, straight alpha).
pub const Theme = struct {
    background: [4]f32 = .{ 0.086, 0.09, 0.102, 1 },
    foreground: [4]f32 = .{ 0.85, 0.86, 0.87, 1 },
    cursor: [4]f32 = .{ 0.95, 0.75, 0.30, 1 },
    cursor_text: [4]f32 = .{ 0.086, 0.09, 0.102, 1 },
    selection: [4]f32 = .{ 0.25, 0.34, 0.47, 1 },
    status: [4]f32 = .{ 0.55, 0.58, 0.62, 1 },
    accent: [4]f32 = .{ 0.55, 0.78, 0.55, 1 },
    // Syntax classes.
    syn_keyword: [4]f32 = .{ 0.78, 0.56, 0.88, 1 },
    syn_string: [4]f32 = .{ 0.62, 0.79, 0.55, 1 },
    syn_comment: [4]f32 = .{ 0.45, 0.49, 0.54, 1 },
    syn_number: [4]f32 = .{ 0.85, 0.65, 0.45, 1 },
    syn_type: [4]f32 = .{ 0.45, 0.78, 0.78, 1 },
    syn_function: [4]f32 = .{ 0.53, 0.70, 0.92, 1 },
    syn_constant: [4]f32 = .{ 0.85, 0.65, 0.45, 1 },
    syn_operator: [4]f32 = .{ 0.70, 0.72, 0.75, 1 },
    syn_attribute: [4]f32 = .{ 0.86, 0.80, 0.55, 1 },
    diag_error: [4]f32 = .{ 0.92, 0.45, 0.45, 1 },
    diag_warn: [4]f32 = .{ 0.88, 0.72, 0.42, 1 },
    // Markdown styling.
    heading: [4]f32 = .{ 0.93, 0.87, 0.72, 1 },
    md_marker: [4]f32 = .{ 0.42, 0.46, 0.52, 1 },
    md_code: [4]f32 = .{ 0.62, 0.79, 0.55, 1 },
    md_link: [4]f32 = .{ 0.53, 0.70, 0.92, 1 },

    fn linearized(self: Theme) Theme {
        var out: Theme = undefined;
        inline for (@typeInfo(Theme).@"struct".fields) |f| {
            @field(out, f.name) = snail.color.srgbToLinearColor(@field(self, f.name));
        }
        return out;
    }

    fn classColor(self: *const Theme, class: HighlightClass) [4]f32 {
        return switch (class) {
            .none, .variable => self.foreground,
            .keyword => self.syn_keyword,
            .string => self.syn_string,
            .comment => self.syn_comment,
            .number => self.syn_number,
            .type => self.syn_type,
            .function => self.syn_function,
            .constant => self.syn_constant,
            .operator, .punctuation => self.syn_operator,
            .attribute, .label => self.syn_attribute,
        };
    }
};

/// What the frame shows besides the buffer: mode, file, dirtiness, and
/// the picker when one is open. Plain data — the caller assembles it,
/// the view renders it.
pub const Hud = struct {
    mode: []const u8,
    file: ?[]const u8 = null,
    dirty: bool = false,
    save_failed: bool = false,
    /// "2/3" — position in the buffer list.
    buffer_pos: ?[]const u8 = null,
    /// Backing kind chip: "file" | "shell" | "tool" | "@shared" | null.
    backing: ?[]const u8 = null,
    /// Save progress chip: "saving…" | "save stale" | null.
    save_note: ?[]const u8 = null,
    /// Partial checkout: percent NOT yet fetched (0 = complete).
    unfetched_pct: ?u8 = null,
    /// Remote peers with presence in this buffer.
    peers: usize = 0,
    /// Transient `echo` message (wins the right-hand slot).
    echo: ?[]const u8 = null,
    pick: ?*const core.Pick = null,
    /// The highlight feed layer (stamped bulk paint).
    highlight_layer: ?*const core.layers.Layer = null,
    /// The diagnostics feed layer (anchored spans, kind = severity).
    diag_layer: ?*const core.layers.Layer = null,
    /// Message of a diagnostic at the cursor, for the status line.
    cursor_diag: ?[]const u8 = null,
    /// Remote peers' cursors (replicated feed layer).
    presence_layer: ?*const core.layers.Layer = null,
    /// Collab link liveness for the status line.
    link: ?[]const u8 = null,
    /// Per-byte markdown styling for the active buffer (null = not md).
    md_inline: ?MdInline = null,
    /// Caret shape and blink phase (false = hidden this frame).
    cursor_style: CursorStyle = .block,
    cursor_on: bool = true,

    const max_pick_rows = 8;

    fn rows(self: *const Hud) usize {
        const p = self.pick orelse return 1;
        return 2 + @min(p.filtered.items.len, max_pick_rows);
    }
};

pub const Built = struct {
    shapes: []snail.Shape,
    records_added: u32,

    pub fn deinit(self: *Built, gpa: Allocator) void {
        gpa.free(self.shapes);
        self.* = undefined;
    }
};

/// A shaped glyph run to render, placed either on the mono cell grid
/// (uniform advances) or proportionally at a pen origin (markdown).
const Run = struct {
    shaped: snail.ShapedText,
    baseline_y: f32,
    place: union(enum) {
        cell: []snail.Cell,
        prop: struct { x: f32, em: f32, color: [4]f32 },
    },
};

/// A solid rectangle painted through the unit-square record: selection
/// backgrounds, caret, peer carets, HUD row highlights.
const Rect = struct { x: f32, y: f32, w: f32, h: f32, color: [4]f32 };

/// Bulk style feeds resolved once per frame for the visible range.
const StyleInputs = struct {
    hl: ?[]const HighlightClass = null,
    hl_base: usize = 0,
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

pub const View = struct {
    gpa: Allocator,
    face_set: fonts.FaceSet,
    pool: *snail.PagePool,
    atlas: snail.Atlas,
    theme: Theme,
    /// A resident unit-square geometry record (font_id 0), placed with an
    /// affine transform + `local_color` to paint arbitrary solid rects
    /// (caret, selection) through the one glyph pipeline — no extra
    /// shader, no per-frame path work.
    rect_key: snail.record_key.RecordKey,

    em: f32,
    cell_w: f32,
    line_h: f32,
    ascent: f32,
    top_row: usize = 0,

    /// The most recent frame's source-offset ↔ geometry map, for
    /// hit-testing, caret, selection, and vertical motion. Its `lines`
    /// and stops live in `layout_arena`, rebuilt each `build()`; a click
    /// between frames reads last frame's map (one-frame latency, unseen).
    layout_arena: std.heap.ArenaAllocator,
    frame_layout: layout.Layout = .{ .lines = &.{} },

    pub fn init(gpa: Allocator, font_bytes: []const u8, em: f32) !View {
        var face_set = try fonts.FaceSet.init(gpa, font_bytes);
        errdefer face_set.deinit();
        const font = face_set.monoFont();

        // Sized for the mono + sans family. Unhinted records are
        // size-independent (one per glyph, reused across heading sizes),
        // so the cost scales with distinct glyphs across ~5 faces, not
        // with font sizes. Exhaustion surfaces as OutOfLayers on prepare.
        const pool = try snail.PagePool.init(gpa, .{
            .max_pages = 24,
            .curve_words_per_page = 1 << 17,
            .band_words_per_page = 1 << 14,
        });
        errdefer pool.deinit();
        var atlas = try snail.Atlas.init(gpa, pool);
        errdefer atlas.deinit();

        // A unit-square fill record, resident for the atlas's life. Placed
        // by an affine transform it becomes any solid rect (caret/selection).
        const rect_key = snail.record_key.unhintedGlyph(0, 1);
        {
            var path = snail.Path.init(gpa);
            defer path.deinit();
            try path.addRect(.{ .x = 0, .y = 0, .w = 1, .h = 1 });
            var prepared_path = try path.prepare(gpa);
            defer prepared_path.deinit();
            var curves = try prepared_path.fillCurves(gpa, gpa);
            defer curves.deinit();
            try atlas.extendInPlace(gpa, .{ .entries = &.{
                .{ .geometry = .{ .key = rect_key, .curves = curves.view() } },
            } });
        }

        const upem: f32 = @floatFromInt(font.unitsPerEm());
        const lm = try font.lineMetrics();
        const advance = try font.advanceWidth(try font.glyphIndex('M'));
        const ascent: f32 = @floatFromInt(lm.ascent);
        const descent: f32 = @floatFromInt(lm.descent);
        const gap: f32 = @floatFromInt(lm.line_gap);

        return .{
            .gpa = gpa,
            .face_set = face_set,
            .pool = pool,
            .atlas = atlas,
            .theme = (Theme{}).linearized(),
            .rect_key = rect_key,
            .em = em,
            .cell_w = em * @as(f32, @floatFromInt(advance)) / upem,
            .line_h = em * (ascent - descent + gap) / upem,
            .ascent = em * ascent / upem,
            .layout_arena = std.heap.ArenaAllocator.init(gpa),
        };
    }

    pub fn deinit(self: *View) void {
        self.layout_arena.deinit();
        self.atlas.deinit();
        self.pool.deinit();
        self.face_set.deinit();
        self.* = undefined;
    }

    pub fn visibleRows(self: *const View, fb_h: u32) usize {
        const usable = @as(f32, @floatFromInt(fb_h)) - 2 * margin;
        return @intFromFloat(@max(1, @floor(usable / self.line_h)));
    }

    pub fn visibleCols(self: *const View, fb_w: u32) usize {
        const usable = @as(f32, @floatFromInt(fb_w)) - 2 * margin;
        return @intFromFloat(@max(1, @floor(usable / self.cell_w)));
    }

    fn rowMetrics(self: *const View, baseline_y: f32) layout.RowMetrics {
        return .{
            .em = self.em,
            .margin = margin,
            .baseline_y = baseline_y,
            .ascent = self.ascent,
            .descent = self.line_h - self.ascent,
            .height = self.line_h,
        };
    }

    /// World-x of the caret at `off`. Prefers the frame's real geometry
    /// (markdown-aware) when the row is visible; else re-shapes it as mono.
    /// The goal-x seam for interactive vertical motion.
    pub fn xOfOffsetOnRow(self: *View, rope: *const stemma.Rope, off: usize) !f32 {
        const row = rope.offsetToPoint(off).row;
        for (self.frame_layout.lines) |*l| if (l.row == row) return l.xAt(off);
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const line = try layout.buildRowStops(arena.allocator(), &self.face_set.mono, rope, row, self.rowMetrics(0));
        return line.xAt(off);
    }

    /// Source offset nearest world-x `goal_x` on `row` — the target of a
    /// visual up/down step. Uses the frame map when the row is visible.
    pub fn xToOffsetOnRow(self: *View, rope: *const stemma.Rope, row: usize, goal_x: f32) !usize {
        for (self.frame_layout.lines) |*l| if (l.row == row) return l.offsetAt(goal_x);
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const line = try layout.buildRowStops(arena.allocator(), &self.face_set.mono, rope, row, self.rowMetrics(0));
        return line.offsetAt(goal_x);
    }

    /// Source offset under a framebuffer-space point (a click). Reads the
    /// last frame's map — the geometry seam for click-to-place.
    pub fn offsetAtPoint(self: *const View, x: f32, y: f32) usize {
        return self.frame_layout.offsetAtPoint(x, y);
    }

    /// Scroll by whole rows (wheel). Clamped to the document next `build()`.
    pub fn scrollBy(self: *View, delta_rows: i32) void {
        if (delta_rows < 0)
            self.top_row -|= @intCast(-delta_rows)
        else
            self.top_row += @intCast(delta_rows);
    }

    /// Keep the cursor's row inside the body viewport.
    fn scrollToCursor(self: *View, editor: *const core.Editor, body_rows: usize) void {
        const cur = editor.text().offsetToPoint(editor.cursorOffset()).row;
        if (cur < self.top_row) self.top_row = cur;
        if (cur >= self.top_row + body_rows) self.top_row = cur + 1 - body_rows;
    }

    // ── Frame assembly ───────────────────────────────────────────────

    /// Build the visible picture: lay out each body row into runs + the
    /// geometry map, derive decoration rects (selection, caret, peers)
    /// from that map, add the HUD, then place everything into shapes.
    pub fn build(
        self: *View,
        scratch: Allocator,
        editor: *const core.Editor,
        hud: Hud,
        fb_w: u32,
        fb_h: u32,
        world_to_pixel: snail.Transform2D,
    ) !Built {
        const rope = editor.text();
        const rows_total = self.visibleRows(fb_h);
        const rows_visible = rows_total -| hud.rows();
        const cols_visible = self.visibleCols(fb_w);
        self.scrollToCursor(editor, @max(1, rows_visible));
        const total_rows = rope.lineCount();
        if (self.top_row >= total_rows) self.top_row = total_rows -| 1;
        const cursor_off = editor.cursorOffset();
        const selection = editor.selectedRange();

        var runs: std.ArrayList(Run) = .empty;
        defer {
            for (runs.items) |*r| r.shaped.deinit();
            runs.deinit(scratch);
        }
        var rects: std.ArrayList(Rect) = .empty;
        defer rects.deinit(scratch);

        const styles = try self.resolveStyleInputs(scratch, hud, rope, rows_visible, total_rows);

        // A block caret recolors the glyph under it to cursor_text; a
        // bar/underline never does. Only when the caret is shown this frame.
        const flip_off: ?usize =
            if (hud.cursor_on and hud.cursor_style == .block) cursor_off else null;

        // Lay out visible rows, stacking y by each line's height, into the
        // frame arena (the geometry map outlives the frame for hit-testing).
        _ = self.layout_arena.reset(.retain_capacity);
        const la = self.layout_arena.allocator();
        var lines: std.ArrayList(layout.VisualLine) = .empty;
        var y_top: f32 = margin;
        // Pixel gate: variable-height lines (headings) can't spill into the
        // HUD/picker region, which begins where the body row budget ends.
        const body_limit_y = margin + @as(f32, @floatFromInt(rows_visible)) * self.line_h;
        var row = self.top_row;
        while (row < total_rows and row < self.top_row + rows_visible and y_top < body_limit_y) : (row += 1) {
            const vl = try self.layoutLine(scratch, la, &runs, rope, row, y_top, cols_visible, hud.md_inline, styles, flip_off);
            try lines.append(la, vl);
            y_top += vl.height;
        }
        self.frame_layout = .{ .lines = try lines.toOwnedSlice(la) };

        // Decorations, from the geometry map: selection behind, then caret,
        // then remote peer carets.
        if (selection) |sel| try self.selectionRects(scratch, &rects, sel);
        if (hud.cursor_on) try self.caretRect(scratch, &rects, cursor_off, hud.cursor_style, self.theme.cursor);
        if (hud.presence_layer) |pl| {
            for (0..pl.spanCount()) |i| {
                const span = pl.resolvedSpan(i);
                try self.caretRect(scratch, &rects, span.start, .bar, self.theme.accent);
            }
        }

        try self.buildHud(scratch, &runs, &rects, hud, rows_total, cols_visible);

        return try self.render(world_to_pixel, runs.items, rects.items);
    }

    /// Resolve the highlight + diagnostic bulk feeds for the visible range.
    fn resolveStyleInputs(
        self: *View,
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
        const diag_count = if (hud.diag_layer) |dl| dl.spanCount() else 0;
        if (diag_count > 0 and rows_visible > 0 and self.top_row < total_rows) {
            const dl = hud.diag_layer.?;
            const last = @min(total_rows, self.top_row + rows_visible);
            const vis_start = rope.lineRange(self.top_row).start;
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

    fn layoutLine(
        self: *View,
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
            self.layoutMarkdownLine(scratch, la, runs, rope, row, y_top, m, flip_off)
        else
            self.layoutMonoLine(scratch, la, runs, rope, row, y_top, cols_visible, styles, flip_off);
    }

    /// Plain buffers: one mono cell per scalar on the pixel grid (uniform
    /// advances). Per-cell color from the caret flip, diagnostics, then
    /// highlight. Stops fall on integer columns — the degenerate case.
    fn layoutMonoLine(
        self: *View,
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
        const baseline_y = y_top + self.ascent;
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
                self.theme.cursor_text
            else if (styles.diag) |d| (if (abs >= styles.diag_base and abs - styles.diag_base < d.len and d[abs - styles.diag_base] != 0)
                (if (d[abs - styles.diag_base] == 1) self.theme.diag_error else self.theme.diag_warn)
            else
                self.hlColor(styles, abs)) else self.hlColor(styles, abs);
            try cells.append(scratch, .{
                .source = .{ .start = @intCast(byte), .end = @intCast(byte + s.len) },
                .column = @intCast(col),
                .color = color,
            });
            try stops.append(la, .{ .off = @intCast(abs), .x = margin + @as(f32, @floatFromInt(col)) * self.cell_w });
            byte += s.len;
        }
        try stops.append(la, .{ .off = @intCast(line.start + byte), .x = margin + @as(f32, @floatFromInt(col)) * self.cell_w });

        if (cells.items.len > 0) {
            const shaped = try snail.shape(scratch, &self.face_set.mono, text[0..byte], .{});
            try runs.append(scratch, .{ .shaped = shaped, .baseline_y = baseline_y, .place = .{ .cell = cells.items } });
        }
        return .{
            .src = line,
            .row = row,
            .baseline_y = baseline_y,
            .ascent = self.ascent,
            .descent = self.line_h - self.ascent,
            .height = self.line_h,
            .x0 = margin,
            .stops = stops.items,
        };
    }

    fn hlColor(self: *const View, styles: StyleInputs, abs: usize) [4]f32 {
        if (styles.hl) |h| {
            if (abs >= styles.hl_base and abs - styles.hl_base < h.len)
                return self.theme.classColor(h[abs - styles.hl_base]);
        }
        return self.theme.foreground;
    }

    /// Markdown buffers: split the line into maximal runs of one effective
    /// style (face + size + color, including the block-caret recolor), shape
    /// each with its face/weight/italic at its em, and place proportionally
    /// at an accumulating pen. Line height scales with its largest role.
    fn layoutMarkdownLine(
        self: *View,
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
        for (0..text.len) |k| max_scale = @max(max_scale, self.inlineStyle(md.at(line.start + k)).em / self.em);
        const ascent = self.ascent * max_scale;
        const baseline_y = y_top + ascent;

        var stops: std.ArrayList(layout.Stop) = .empty;
        var pen: f32 = margin;
        var i: usize = 0;
        while (i < text.len) {
            const st = self.effStyle(md, line.start + i, caret_lo, caret_hi);
            var j = i + 1;
            while (j < text.len and self.effStyle(md, line.start + j, caret_lo, caret_hi).eql(st)) j += 1;
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
            .descent = self.line_h * max_scale - ascent,
            .height = self.line_h * max_scale,
            .x0 = margin,
            .stops = stops.items,
        };
    }

    /// Base style for a markdown attribute: role → size + face family,
    /// bold/italic → sans variant, marker/link/code/heading → color.
    fn inlineStyle(self: *View, a: InlineAttr) InlineStyle {
        if (a.role == .code) {
            return .{
                .faces = &self.face_set.mono,
                .style = .{},
                .em = self.em,
                .color = if (a.marker) self.theme.md_marker else self.theme.md_code,
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
            self.theme.md_marker
        else if (a.link)
            self.theme.md_link
        else if (heading)
            self.theme.heading
        else
            self.theme.foreground;
        return .{
            .faces = &self.face_set.body,
            .style = .{ .weight = if (a.bold or heading) .bold else .regular, .italic = a.italic },
            .em = self.em * scale,
            .color = color,
        };
    }

    /// `inlineStyle` with the block-caret glyph recolored to cursor_text.
    fn effStyle(self: *View, md: MdInline, off: usize, caret_lo: usize, caret_hi: usize) InlineStyle {
        var st = self.inlineStyle(md.at(off));
        if (off >= caret_lo and off < caret_hi) st.color = self.theme.cursor_text;
        return st;
    }

    // ── Decorations ──────────────────────────────────────────────────

    fn selectionRects(self: *View, scratch: Allocator, rects: *std.ArrayList(Rect), sel: stemma.Range) !void {
        for (self.frame_layout.lines) |*vl| {
            const s = @max(sel.start, vl.src.start);
            const e = @min(sel.end, vl.src.end);
            if (s >= e) continue;
            const x0 = vl.xAt(s);
            const x1 = vl.xAt(e);
            try rects.append(scratch, .{
                .x = x0,
                .y = vl.baseline_y - vl.ascent,
                .w = @max(1, x1 - x0),
                .h = vl.height,
                .color = self.theme.selection,
            });
        }
    }

    fn caretRect(self: *View, scratch: Allocator, rects: *std.ArrayList(Rect), off: usize, style: CursorStyle, color: [4]f32) !void {
        const li = self.frame_layout.lineForOffset(off) orelse return;
        const vl = &self.frame_layout.lines[li];
        const c = vl.caretAt(off);
        const w = self.caretWidth(vl, off);
        const rect: Rect = switch (style) {
            .block => .{ .x = c.x, .y = c.y_top, .w = w, .h = c.height, .color = color },
            .bar => .{ .x = c.x - 1, .y = c.y_top, .w = 2, .h = c.height, .color = color },
            .underline => .{ .x = c.x, .y = c.y_top + c.height - 2, .w = w, .h = 2, .color = color },
        };
        try rects.append(scratch, rect);
    }

    /// Caret cell width: to the next caret stop, or one em-ish at line end.
    fn caretWidth(self: *const View, vl: *const layout.VisualLine, off: usize) f32 {
        const x0 = vl.xAt(off);
        for (vl.stops) |s| {
            if (s.off > off and s.x > x0) return s.x - x0;
        }
        return self.cell_w;
    }

    // ── Rendering (prepare + place) ──────────────────────────────────

    fn render(self: *View, world_to_pixel: snail.Transform2D, runs: []Run, rects: []const Rect) !Built {
        // Prepare every glyph run's records (idempotent for resident ones).
        const run_ptrs = try self.gpa.alloc(*const snail.ShapedText, runs.len);
        defer self.gpa.free(run_ptrs);
        for (runs, run_ptrs) |*r, *out| out.* = &r.shaped;
        const sources = self.face_set.sources();
        const before = self.atlas.recordCount();
        try prepare.run(self.gpa, &self.atlas, &sources, run_ptrs, .{ .unhinted = .{ .colr = .layers } });
        const after = self.atlas.recordCount();

        var count: usize = rects.len;
        for (runs) |*r| count += try self.runShapeCount(r, world_to_pixel);
        const shapes = try self.gpa.alloc(snail.Shape, count);
        errdefer self.gpa.free(shapes);

        var at: usize = 0;
        // Rects first — they draw behind the text (a block caret sits
        // behind its recolored glyph).
        for (rects) |rc| {
            shapes[at] = self.rectShape(rc);
            at += 1;
        }
        for (runs) |*r| {
            const placed = try self.placeRunInto(shapes[at..], r, world_to_pixel);
            at += placed.len;
        }
        assert(at == shapes.len);
        return .{ .shapes = shapes, .records_added = after - before };
    }

    fn runShapeCount(self: *View, r: *const Run, w2p: snail.Transform2D) !usize {
        return switch (r.place) {
            .cell => |cells| try snail.placedCellRunShapeCount(&r.shaped, &self.face_set.mono, cells, self.cellPlacement(r.baseline_y, w2p)),
            .prop => try snail.placedRunShapeCount(&r.shaped, null, self.propPlacement(r, w2p)),
        };
    }

    fn placeRunInto(self: *View, out: []snail.Shape, r: *const Run, w2p: snail.Transform2D) ![]snail.Shape {
        return switch (r.place) {
            .cell => |cells| try snail.placeCellRun(out, &r.shaped, &self.face_set.mono, cells, self.cellPlacement(r.baseline_y, w2p)),
            .prop => try snail.placeRun(out, &r.shaped, null, self.propPlacement(r, w2p)),
        };
    }

    fn cellPlacement(self: *const View, baseline_y: f32, world_to_pixel: snail.Transform2D) snail.CellRunPlacement {
        return .{
            .baseline = .{ .x = margin, .y = baseline_y },
            .cell_width = self.cell_w,
            .em = self.em,
            .snap = .grid,
            .y_axis = .down,
            .world_to_pixel = world_to_pixel,
        };
    }

    fn propPlacement(self: *const View, r: *const Run, world_to_pixel: snail.Transform2D) snail.RunPlacement {
        _ = self;
        const p = r.place.prop;
        return .{
            .baseline = .{ .x = p.x, .y = r.baseline_y },
            .em = p.em,
            .color = p.color,
            .mode = .unhinted,
            .snap = .origins,
            .y_axis = .down,
            .world_to_pixel = world_to_pixel,
        };
    }

    fn rectShape(self: *const View, r: Rect) snail.Shape {
        // The unit-square record spans [-1, 1]² (centered), so the affine
        // maps its center to the rect's center with half-extent scales.
        return .{
            .key = self.rect_key,
            .local_transform = .{
                .xx = r.w / 2,
                .xy = 0,
                .tx = r.x + r.w / 2,
                .yx = 0,
                .yy = r.h / 2,
                .ty = r.y + r.h / 2,
            },
            .local_color = r.color,
        };
    }

    // ── HUD (status line + picker; always mono) ──────────────────────

    fn baselineFor(self: *const View, row_from_top: usize) f32 {
        return margin + self.ascent + @as(f32, @floatFromInt(row_from_top)) * self.line_h;
    }

    fn buildHud(
        self: *View,
        scratch: Allocator,
        runs: *std.ArrayList(Run),
        rects: *std.ArrayList(Rect),
        hud: Hud,
        rows_total: usize,
        cols_visible: usize,
    ) !void {
        if (rows_total == 0) return;
        var parts: std.ArrayList(u8) = .empty;
        try parts.appendSlice(scratch, " ");
        try parts.appendSlice(scratch, hud.mode);
        try parts.appendSlice(scratch, "  ");
        if (hud.buffer_pos) |bp| {
            try parts.appendSlice(scratch, bp);
            try parts.appendSlice(scratch, " ");
        }
        try parts.appendSlice(scratch, hud.file orelse "[scratch]");
        if (hud.dirty) try parts.appendSlice(scratch, " [+]");
        if (hud.backing) |b| {
            try parts.appendSlice(scratch, " (");
            try parts.appendSlice(scratch, b);
            try parts.appendSlice(scratch, ")");
        }
        if (hud.save_note) |s| {
            try parts.appendSlice(scratch, " [");
            try parts.appendSlice(scratch, s);
            try parts.appendSlice(scratch, "]");
        }
        if (hud.save_failed) try parts.appendSlice(scratch, " [save failed]");
        if (hud.unfetched_pct) |pct| {
            if (pct > 0) {
                const fetched = try std.fmt.allocPrint(scratch, " [{d}% fetched]", .{100 - @as(u32, pct)});
                try parts.appendSlice(scratch, fetched);
            }
        }
        if (hud.peers > 0) {
            const peers = try std.fmt.allocPrint(scratch, "  ✦{d}", .{hud.peers});
            try parts.appendSlice(scratch, peers);
        }
        const status_diag_count = if (hud.diag_layer) |dl| dl.spanCount() else 0;
        if (status_diag_count > 0) {
            const dp = try std.fmt.allocPrint(scratch, "  !{d}", .{status_diag_count});
            try parts.appendSlice(scratch, dp);
        }
        if (hud.link) |l| {
            try parts.appendSlice(scratch, "  link:");
            try parts.appendSlice(scratch, l);
        }
        if (hud.echo orelse hud.cursor_diag) |msg| {
            try parts.appendSlice(scratch, "  ·  ");
            try parts.appendSlice(scratch, msg);
        }
        try self.appendPlainRun(scratch, runs, rects, parts.items, self.baselineFor(rows_total - 1), cols_visible, self.theme.status, null);

        const p = hud.pick orelse return;
        const total = p.filtered.items.len;
        const shown = @min(total, Hud.max_pick_rows);
        if (rows_total < shown + 2) return;
        const query_row = rows_total - 2 - shown;

        const query = try std.fmt.allocPrint(scratch, "{s}> {s}_   [{d}/{d}]", .{
            p.prompt,
            p.query.items,
            if (total == 0) 0 else p.selected + 1,
            total,
        });
        try self.appendPlainRun(scratch, runs, rects, query, self.baselineFor(query_row), cols_visible, self.theme.foreground, null);

        const start = if (p.selected >= shown) p.selected + 1 - shown else 0;
        for (0..shown) |i| {
            const fi = start + i;
            const item = p.items.items[p.filtered.items[fi]];
            const doc = p.docOf(fi);
            const l = if (doc.len > 0)
                try std.fmt.allocPrint(scratch, "  {s}  · {s}", .{ item, doc })
            else
                try std.fmt.allocPrint(scratch, "  {s}", .{item});
            const selected = fi == p.selected;
            try self.appendPlainRun(
                scratch,
                runs,
                rects,
                l,
                self.baselineFor(query_row + 1 + i),
                cols_visible,
                if (selected) self.theme.accent else self.theme.status,
                if (selected) self.theme.selection else null,
            );
        }
    }

    /// A HUD text run: mono cells truncated at the viewport, optionally over
    /// a full-width background rect.
    fn appendPlainRun(
        self: *View,
        scratch: Allocator,
        runs: *std.ArrayList(Run),
        rects: *std.ArrayList(Rect),
        text: []const u8,
        baseline_y: f32,
        cols_visible: usize,
        color: [4]f32,
        bg: ?[4]f32,
    ) !void {
        if (bg) |bgc| {
            try rects.append(scratch, .{
                .x = margin,
                .y = baseline_y - self.ascent,
                .w = @as(f32, @floatFromInt(cols_visible)) * self.cell_w,
                .h = self.line_h,
                .color = bgc,
            });
        }
        var cells: std.ArrayList(snail.Cell) = .empty;
        var it = (std.unicode.Utf8View.init(text) catch return error.InvalidUtf8).iterator();
        var col: usize = 0;
        var byte: usize = 0;
        while (it.nextCodepointSlice()) |s| : (col += 1) {
            if (col >= cols_visible) break;
            try cells.append(scratch, .{
                .source = .{ .start = @intCast(byte), .end = @intCast(byte + s.len) },
                .column = @intCast(col),
                .color = color,
            });
            byte += s.len;
        }
        if (cells.items.len == 0) return;
        const shaped = try snail.shape(scratch, &self.face_set.mono, text[0..byte], .{});
        try runs.append(scratch, .{ .shaped = shaped, .baseline_y = baseline_y, .place = .{ .cell = cells.items } });
    }
};

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

test "monospace parity gate: view-computed vertical target == old column target" {
    // The column-debt fix must not change plain-code editing. For a mono
    // font, the goal-x vertical step (xOfOffsetOnRow -> xToOffsetOnRow)
    // must land on exactly the offset the old scalar-column moveVertical
    // did: line.start + min(goal_col, line.len()). ASCII only, so every
    // byte is a scalar boundary and snapBoundary is the identity.
    const gpa = testing.allocator;
    var view = try View.init(gpa, @embedFile("font_mono"), 16);
    defer view.deinit();

    var rope = try stemma.Rope.fromSlice(gpa, "hello world\nhi\n\nwide load here\nx");
    defer rope.deinit(gpa);
    const rows = rope.lineCount();

    // From every offset, stepping to every other row, the two models agree.
    // (Empty frame_layout → both use the mono re-shape path.)
    var cur: usize = 0;
    while (cur <= rope.byteLen()) : (cur += 1) {
        const p = rope.offsetToPoint(cur);
        const gx = try view.xOfOffsetOnRow(&rope, cur);
        for (0..rows) |target_row| {
            const line = rope.lineRange(target_row);
            const old_target = line.start + @min(p.col, line.len());
            const new_target = try view.xToOffsetOnRow(&rope, target_row, gx);
            testing.expectEqual(old_target, new_target) catch |e| {
                std.debug.print(
                    "mismatch: cur={d} (row {d} col {d}) -> row {d}: old={d} new={d}\n",
                    .{ cur, p.row, p.col, target_row, old_target, new_target },
                );
                return e;
            };
        }
    }
}
