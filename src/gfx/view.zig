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
const region = @import("region.zig");
const fonts = @import("fonts.zig");
const statusline = @import("view/statusline.zig");

const InlineAttr = core.capability.InlineAttr;
const HighlightClass = core.capability.HighlightClass;
const StyleClass = core.capability.StyleClass;

const font_id_mono = fonts.font_id_mono;
const margin: f32 = 8;

/// The frame's non-buffer chrome + caret shape + markdown-styling handle +
/// tab datum, split into `view/hud.zig` and re-exported so `view_mod.Hud`
/// (and friends) are unchanged. `buildTabStrip` is the pure strip builder.
const hud_mod = @import("view/hud.zig");
pub const CursorStyle = hud_mod.CursorStyle;
pub const MdInline = hud_mod.MdInline;
pub const Hud = hud_mod.Hud;
pub const Tab = hud_mod.Tab;
const buildTabStrip = hud_mod.buildTabStrip;

/// The view's color palette (data + role→color lookups). Split into
/// `view/theme.zig`; re-exported here so `view_mod.Theme` is unchanged.
pub const Theme = @import("view/theme.zig").Theme;

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
/// `pub` only so the extracted render/layout submodules can name it — it is
/// not part of the module's public surface (view.zig re-exports none of it).
pub const Run = struct {
    shaped: snail.ShapedText,
    baseline_y: f32,
    place: union(enum) {
        cell: []snail.Cell,
        prop: struct { x: f32, em: f32, color: [4]f32 },
    },
};

/// A solid rectangle painted through the unit-square record: selection
/// backgrounds, caret, peer carets, HUD row highlights. `pub` for the
/// extracted submodules only (see `Run`).
pub const Rect = struct { x: f32, y: f32, w: f32, h: f32, color: [4]f32 };

/// Bulk style feeds resolved once per frame for the visible range.
const StyleInputs = struct {
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
    /// The current build's content origin (its frame inset by `margin`) — a
    /// pane renders into its own region, so layout and HUD baselines derive
    /// from here rather than the whole framebuffer. Defaults to the
    /// single-pane, frame-at-origin case.
    origin_x: f32 = margin,
    origin_y: f32 = margin,
    /// The last build's body region height, for scroll commands (`bodyRows`).
    body_h: f32 = 0,
    /// Whether the active buffer is markdown (from the last build). Off-screen
    /// vertical-motion goal-x uses this to shape rows with the proportional body
    /// face at their heading scale, instead of the mono approximation.
    md_active: bool = false,

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

    /// Rows that fit in a rect of pixel height `h` (its usable body height).
    pub fn rowsIn(self: *const View, h: f32) usize {
        return @intFromFloat(@max(1, @floor((h - 2 * margin) / self.line_h)));
    }

    pub fn colsIn(self: *const View, w: f32) usize {
        return @intFromFloat(@max(1, @floor((w - 2 * margin) / self.cell_w)));
    }

    /// Rows in the focused pane's body (for the scroll commands, which run
    /// between frames and read the last build's body region).
    pub fn bodyRows(self: *const View) usize {
        return @intFromFloat(@max(1, @floor(self.body_h / self.line_h)));
    }

    fn rowMetrics(self: *const View, baseline_y: f32) layout.RowMetrics {
        return self.rowMetricsEm(self.em, baseline_y);
    }
    fn rowMetricsEm(self: *const View, em: f32, baseline_y: f32) layout.RowMetrics {
        return .{
            .em = em,
            .margin = self.origin_x,
            .baseline_y = baseline_y,
            .ascent = self.ascent,
            .descent = self.line_h - self.ascent,
            .height = self.line_h,
        };
    }

    /// The heading em-scale of a row, from its leading `#`s (matching
    /// `inlineStyle`), or 1.0 for a non-heading. Used to shape an OFF-SCREEN
    /// markdown row at the right size without the published per-byte styling.
    fn headingScale(self: *const View, rope: *const stemma.Rope, row: usize) f32 {
        _ = self;
        const line = rope.lineRange(row);
        var buf: [8]u8 = undefined;
        const n = @min(line.len(), buf.len);
        if (n == 0) return 1.0;
        var sr = rope.streamReader(.{ .start = line.start, .end = line.start + n }, &.{});
        sr.interface.readSliceAll(buf[0..n]) catch return 1.0;
        var h: usize = 0;
        while (h < n and buf[h] == '#') h += 1;
        if (h == 0 or h > 6) return 1.0;
        if (h < n and buf[h] != ' ') return 1.0; // `#foo` is not a heading
        return switch (h) {
            1 => 2.0,
            2 => 1.6,
            3 => 1.3,
            4 => 1.15,
            else => 1.05,
        };
    }

    /// Build stops for an OFF-SCREEN row (not in the frame map). For markdown,
    /// shape with the proportional body face at the row's heading scale — so
    /// vertical motion into an off-screen heading/paragraph lands at the right
    /// column, not the mono approximation. Plain buffers use the mono grid.
    fn offRowStops(self: *View, la: Allocator, rope: *const stemma.Rope, row: usize) !layout.VisualLine {
        if (self.md_active) {
            const em = self.em * self.headingScale(rope, row);
            return layout.buildRowStops(la, &self.face_set.body, rope, row, self.rowMetricsEm(em, 0));
        }
        return layout.buildRowStops(la, &self.face_set.mono, rope, row, self.rowMetrics(0));
    }

    /// World-x of the caret at `off`. Prefers the frame's real geometry
    /// (markdown-aware) when the row is visible; else re-shapes it as mono.
    /// The goal-x seam for interactive vertical motion.
    pub fn xOfOffsetOnRow(self: *View, rope: *const stemma.Rope, off: usize) !f32 {
        const row = rope.offsetToPoint(off).row;
        for (self.frame_layout.lines) |*l| if (l.row == row) return l.xAt(off);
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const line = try self.offRowStops(arena.allocator(), rope, row);
        return line.xAt(off);
    }

    /// Source offset nearest world-x `goal_x` on `row` — the target of a
    /// visual up/down step. Uses the frame map when the row is visible.
    pub fn xToOffsetOnRow(self: *View, rope: *const stemma.Rope, row: usize, goal_x: f32) !usize {
        for (self.frame_layout.lines) |*l| if (l.row == row) return l.offsetAt(goal_x);
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const line = try self.offRowStops(arena.allocator(), rope, row);
        return line.offsetAt(goal_x);
    }

    /// Source offset under a framebuffer-space point (a click). Reads the
    /// last frame's map — the geometry seam for click-to-place.
    pub fn offsetAtPoint(self: *const View, x: f32, y: f32) usize {
        return self.frame_layout.offsetAtPoint(x, y);
    }

    /// Scroll a pane by whole rows (wheel). Clamped to the document next
    /// `build()`.
    pub fn scrollBy(top_row: *usize, delta_rows: i32) void {
        if (delta_rows < 0)
            top_row.* -|= @intCast(-delta_rows)
        else
            top_row.* += @intCast(delta_rows);
    }

    /// Reset the per-frame layout arena. With split panes the caller resets
    /// once, then builds each pane (their geometry maps coexist in it).
    pub fn resetFrame(self: *View) void {
        _ = self.layout_arena.reset(.retain_capacity);
    }

    /// Keep the cursor's row inside a pane's body viewport.
    fn scrollToCursor(editor: *const core.Editor, top_row: *usize, body_rows: usize) void {
        const cur = editor.text().offsetToPoint(editor.cursorOffset()).row;
        if (cur < top_row.*) top_row.* = cur;
        if (cur >= top_row.* + body_rows) top_row.* = cur + 1 - body_rows;
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
        top_row: *usize,
        frame: region.Rect,
        pick_dock: region.Rect,
        world_to_pixel: snail.Transform2D,
    ) !Built {
        const rope = editor.text();
        // Carve the pane's frame into regions (no element computes an offset
        // against another): content is the frame inset by `margin`; a top
        // tab strip and a bottom HUD (status line + optional panel) are cut
        // off it, and the body is what remains. Everything below renders
        // into its own rect.
        const content: region.Rect = .{
            .x = frame.x + margin,
            .y = frame.y + margin,
            .w = frame.w - 2 * margin,
            .h = frame.h - 2 * margin,
        };
        self.origin_x = content.x;
        self.origin_y = content.y;
        const cols_visible: usize = @intFromFloat(@max(1, @floor(content.w / self.cell_w)));

        var stack = content;
        var tab_rect: ?region.Rect = null;
        if (hud.tabs != null) {
            const c = stack.cutTop(self.line_h);
            tab_rect = c.strip;
            stack = c.rest;
        }
        const status_cut = stack.cutBottom(self.line_h);
        const status_rect = status_cut.strip;
        const panel_cut = status_cut.rest.cutBottom(@as(f32, @floatFromInt(hud.panelRows())) * self.line_h);
        const panel_rect = panel_cut.strip;
        const body_rect = panel_cut.rest;
        self.body_h = body_rect.h;
        self.md_active = hud.md_inline != null;

        const rows_visible: usize = @intFromFloat(@max(1, @floor(body_rect.h / self.line_h)));
        scrollToCursor(editor, top_row, rows_visible);
        const total_rows = rope.lineCount();
        if (top_row.* >= total_rows) top_row.* = total_rows -| 1;
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

        // Lay out the body's visible rows into the frame arena (the geometry
        // map outlives the frame for hit-testing). The caller resets the
        // arena once per frame (resetFrame) so split panes' maps coexist.
        const la = self.layout_arena.allocator();
        var lines: std.ArrayList(layout.VisualLine) = .empty;
        var y_top: f32 = body_rect.y;
        const body_limit_y = body_rect.y + body_rect.h;
        var row = top_row.*;
        var shown: usize = 0; // VISIBLE rows emitted (folded rows are skipped)
        while (row < total_rows and shown < rows_visible and y_top < body_limit_y) : (row += 1) {
            // Fold: a hidden row isn't drawn (and vertical motion skips it), so
            // the folded body collapses to nothing while its header stays.
            if (editor.rowHidden(row)) continue;
            const runs_mark = runs.items.len;
            const vl = try self.layoutLine(scratch, la, &runs, rope, row, y_top, cols_visible, hud.md_inline, styles, flip_off);
            // A proportional/heading row can be taller than a mono line, so a
            // row whose top is in-bounds can still paint past the body onto the
            // status bar. Gate on the ACTUAL scaled height: discard an
            // overflowing row's glyphs (truncate the arena-backed runs) rather
            // than draw them out of region. Always keep the first row so an
            // absurdly short window still shows something.
            if (shown != 0 and y_top + vl.height > body_limit_y) {
                runs.items.len = runs_mark;
                break;
            }
            try lines.append(la, vl);
            y_top += vl.height;
            shown += 1;
        }
        self.frame_layout = .{ .lines = try lines.toOwnedSlice(la) };

        // Decorations, from the geometry map: selection behind, then caret,
        // then each remote peer's selection + caret in its own color.
        if (selection) |sel| try self.selectionRects(scratch, &rects, sel, self.theme.selection);
        // vim-goggles: a transient flash over a just-operated range (e.g. yank).
        if (hud.flash) |fl| try self.selectionRects(scratch, &rects, fl, self.theme.accent);
        if (hud.cursor_on) try self.caretRect(scratch, &rects, cursor_off, hud.cursor_style, self.theme.cursor);
        if (hud.presence_layer) |pl| {
            for (0..pl.spanCount()) |i| {
                const span = pl.resolvedSpan(i);
                // A peer span packs its identity hue in kind's low 16 bits;
                // bit 16 marks which end holds the caret (see session.zig
                // republishPresence). start==end ⇒ a caret with no selection.
                const hue = @as(f32, @floatFromInt(span.kind & 0xffff)) / 65535.0;
                if (span.end > span.start) {
                    try self.selectionRects(scratch, &rects, .{ .start = span.start, .end = span.end }, peerColor(hue, 0.55, 0.28));
                }
                const head = if (span.kind & 0x10000 == 0) span.start else span.end;
                try self.caretRect(scratch, &rects, head, .bar, peerColor(hue, 0.62, 1.0));
            }
        }

        // Top buffer-tab strip, into its own region.
        if (hud.tabs) |tabs| {
            var tbuf: [1024]u8 = undefined;
            const strip = buildTabStrip(&tbuf, tabs);
            try statusline.appendPlainRun(self, scratch, &runs, &rects, strip, tab_rect.?.y + self.ascent, cols_visible, self.theme.status, null);
        }

        try statusline.buildHud(self, scratch, &runs, &rects, hud, status_rect, panel_rect, cols_visible);
        // Floating surfaces (which-key popup, dired/magit) float within the BODY
        // region — never over the status/tab/panel rects, which are carved out.
        // Hand the caret's y so a corner surface can flip away from it.
        const caret_y: ?f32 = if (self.frame_layout.lineForOffset(cursor_off)) |li|
            self.frame_layout.lines[li].caretAt(cursor_off).y_top
        else
            null;
        try self.drawSurfaces(scratch, &runs, &rects, hud, body_rect, caret_y);
        // The picker draws into its carved window-bottom dock (main cut it off
        // the window with cutBottom, so it cannot overlap panes or a status
        // line). A completion pick anchors at the caret instead — a popup.
        if (hud.pick) |p| {
            if (p.caret_anchor) |off|
                try self.drawPickAtCaret(scratch, &runs, &rects, p, off, body_rect)
            else
                try self.drawPickInto(scratch, &runs, &rects, p, pick_dock);
        }
        // Hover info floats at the caret, above everything else.
        if (hud.hover) |hv| try self.drawHoverAtCaret(scratch, &runs, &rects, hv.text, hv.offset, body_rect);

        // Thin pane dividers: a 1px line on each internal (shared) edge of
        // the pane's frame. Drawn on the frame boundary — outside the
        // `content` inset — so it never touches a glyph. Subtle: the dim
        // status grey, like the very slight lines between vim splits.
        {
            const bd = hud.pane_border;
            const c = self.theme.status;
            const th: f32 = 1;
            if (bd.left) try rects.append(scratch, .{ .x = frame.x, .y = frame.y, .w = th, .h = frame.h, .color = c });
            if (bd.right) try rects.append(scratch, .{ .x = frame.x + frame.w - th, .y = frame.y, .w = th, .h = frame.h, .color = c });
            if (bd.top) try rects.append(scratch, .{ .x = frame.x, .y = frame.y, .w = frame.w, .h = th, .color = c });
            if (bd.bottom) try rects.append(scratch, .{ .x = frame.x, .y = frame.y + frame.h - th, .w = frame.w, .h = th, .color = c });
        }

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
        if (hud.styles_layer) |sl| {
            if (sl.bulk) |b| {
                s.st = @ptrCast(b.classes);
                s.st_base = b.start;
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
            // A tab's glyph (a space, substituted below) sits at its own
            // column; the NEXT cell jumps to the tab stop, so the tab reads
            // as blank whitespace. Offset↔stop stays 1:1 — the caret is exact.
            try cells.append(scratch, .{
                .source = .{ .start = @intCast(byte), .end = @intCast(byte + s.len) },
                .column = @intCast(col),
                .color = color,
            });
            try stops.append(la, .{ .off = @intCast(abs), .x = self.origin_x + @as(f32, @floatFromInt(col)) * self.cell_w });
            byte += s.len;
            if (s.len == 1 and s[0] == '\t') col = layout.tabStopAfter(col) - 1; // loop's +1 lands on the stop
        }
        try stops.append(la, .{ .off = @intCast(line.start + byte), .x = self.origin_x + @as(f32, @floatFromInt(col)) * self.cell_w });

        if (cells.items.len > 0) {
            const shbuf = try scratch.dupe(u8, text[0..byte]);
            for (shbuf) |*b| {
                if (b.* == '\t') b.* = ' ';
            }
            const shaped = try snail.shape(scratch, &self.face_set.mono, shbuf, .{});
            try runs.append(scratch, .{ .shaped = shaped, .baseline_y = baseline_y, .place = .{ .cell = cells.items } });
        }
        return .{
            .src = line,
            .row = row,
            .baseline_y = baseline_y,
            .ascent = self.ascent,
            .descent = self.line_h - self.ascent,
            .height = self.line_h,
            .x0 = self.origin_x,
            .stops = stops.items,
        };
    }

    /// Per-byte non-caret, non-diagnostic color. Precedence: syntax highlight
    /// wins for code; the plugin styles feed paints tool buffers where there is
    /// no highlight. Tool buffers never have a grammar, so the two never overlap
    /// in practice — the order just fixes a defined winner if they ever did.
    fn hlColor(self: *const View, styles: StyleInputs, abs: usize) [4]f32 {
        if (styles.hl) |h| {
            if (abs >= styles.hl_base and abs - styles.hl_base < h.len)
                return self.theme.classColor(h[abs - styles.hl_base]);
        }
        if (styles.st) |st| {
            if (abs >= styles.st_base and abs - styles.st_base < st.len)
                return self.theme.styleColor(st[abs - styles.st_base]);
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
        var pen: f32 = self.origin_x;
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
            .x0 = self.origin_x,
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

    fn selectionRects(self: *View, scratch: Allocator, rects: *std.ArrayList(Rect), sel: stemma.Range, color: [4]f32) !void {
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
                .color = color,
            });
        }
    }

    /// A peer's caret/selection color from its identity hue (fixed
    /// saturation, caller-chosen lightness/alpha so a caret reads solid and
    /// a selection reads as a translucent wash). Authored in sRGB, returned
    /// linear like the rest of the theme.
    fn peerColor(hue: f32, light: f32, alpha: f32) [4]f32 {
        return snail.color.srgbToLinearColor(hslToSrgb(hue, 0.65, light, alpha));
    }

    fn hslToSrgb(h: f32, s: f32, l: f32, a: f32) [4]f32 {
        const c = (1 - @abs(2 * l - 1)) * s;
        const hp = h * 6;
        const x = c * (1 - @abs(@mod(hp, 2) - 1));
        var r: f32 = 0;
        var g: f32 = 0;
        var b: f32 = 0;
        if (hp < 1) {
            r = c;
            g = x;
        } else if (hp < 2) {
            r = x;
            g = c;
        } else if (hp < 3) {
            g = c;
            b = x;
        } else if (hp < 4) {
            g = x;
            b = c;
        } else if (hp < 5) {
            r = x;
            b = c;
        } else {
            r = c;
            b = x;
        }
        const m = l - c / 2;
        return .{ r + m, g + m, b + m, a };
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
            .baseline = .{ .x = self.origin_x, .y = baseline_y },
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

    /// Pixel height the picker dock needs: the query line + one row per shown
    /// result. The SINGLE source of truth for both the dock carve (main cuts
    /// exactly this off the window) and the render, so they cannot drift — the
    /// same discipline `panelRows` uses. Zero when no pick is open.
    pub fn pickDockHeight(self: *const View, pick: ?*const core.Pick) f32 {
        const p = pick orelse return 0;
        if (p.caret_anchor != null) return 0; // a caret popup (completion), not a dock
        const shown = @min(p.filtered.items.len, Hud.max_pick_rows);
        return @as(f32, @floatFromInt(1 + shown)) * self.line_h;
    }

    /// Draw the picker INTO its carved `dock` region (a window-bottom strip cut
    /// off the frame with `cutBottom`, so it never overlaps the panes or a
    /// status line — the region system's whole point). Every position is
    /// relative to `dock`, whose height is exactly `pickDockHeight`, so nothing
    /// spills. It receives its OWN rect, never the whole window.
    fn drawPickInto(
        self: *View,
        scratch: Allocator,
        runs: *std.ArrayList(Run),
        rects: *std.ArrayList(Rect),
        p: *const core.Pick,
        dock: region.Rect,
    ) !void {
        if (dock.h <= 0) return;
        const total = p.filtered.items.len;
        const shown = @min(total, Hud.max_pick_rows);
        // A thin top rule sets the picker dock off from the panes above it.
        try rects.append(scratch, .{ .x = dock.x, .y = dock.y, .w = dock.w, .h = dock.h, .color = self.theme.selection });
        try rects.append(scratch, .{ .x = dock.x, .y = dock.y, .w = dock.w, .h = 1, .color = self.theme.accent });

        const narrow_chip = if (p.narrow.items.len > 0)
            try std.fmt.allocPrint(scratch, "[{s}]", .{p.narrow.items})
        else
            "";
        const query = try std.fmt.allocPrint(scratch, "  {s}{s}> {s}_   [{d}/{d}] ·{s}", .{
            p.prompt,                              narrow_chip, p.query.items,
            if (total == 0) 0 else p.selected + 1, total,       @tagName(p.style),
        });
        try self.propLine(scratch, runs, query, dock.x, dock.y + self.ascent, self.theme.foreground);

        const start = if (p.selected >= shown) p.selected + 1 - shown else 0;
        for (0..shown) |i| {
            const fi = start + i;
            const item = p.items.items[p.filtered.items[fi]];
            const doc = p.docOf(fi);
            const l = if (doc.len > 0)
                try std.fmt.allocPrint(scratch, "  {s}  · {s}", .{ item, doc })
            else
                try std.fmt.allocPrint(scratch, "  {s}", .{item});
            const row_y = dock.y + @as(f32, @floatFromInt(1 + i)) * self.line_h;
            const selected = fi == p.selected;
            if (selected) try rects.append(scratch, .{ .x = dock.x, .y = row_y, .w = dock.w, .h = self.line_h, .color = self.theme.accent });
            try self.propLine(scratch, runs, l, dock.x, row_y + self.ascent, if (selected) self.theme.background else self.theme.status);
        }
    }

    /// Draw a completion pick as a popup anchored at the caret (byte offset
    /// `off`): a small outlined box of candidates just below the caret line
    /// (flipped above if it would overflow the body), the selected row
    /// highlighted. No query line — the query is what you're typing in the
    /// buffer. Skips if the anchor line is off-screen or there are no rows.
    fn drawPickAtCaret(
        self: *View,
        scratch: Allocator,
        runs: *std.ArrayList(Run),
        rects: *std.ArrayList(Rect),
        p: *const core.Pick,
        off: usize,
        body: region.Rect,
    ) !void {
        const total = p.filtered.items.len;
        if (total == 0) return;
        const li = self.frame_layout.lineForOffset(off) orelse return; // off-screen
        const c = self.frame_layout.lines[li].caretAt(off);

        const shown = @min(total, Hud.max_pick_rows);
        const start = if (p.selected >= shown) p.selected + 1 - shown else 0;
        var max_cols: usize = 8;
        for (0..shown) |i| {
            const item = p.items.items[p.filtered.items[start + i]];
            max_cols = @max(max_cols, std.unicode.utf8CountCodepoints(item) catch item.len);
        }
        const box_w = @as(f32, @floatFromInt(max_cols + 2)) * self.cell_w;
        const box_h = @as(f32, @floatFromInt(shown)) * self.line_h;
        const box_x = std.math.clamp(c.x, body.x, @max(body.x, body.x + body.w - box_w));
        var box_y = c.y_top + c.height; // just below the caret line
        if (box_y + box_h > body.y + body.h) box_y = c.y_top - box_h; // flip above
        box_y = std.math.clamp(box_y, body.y, @max(body.y, body.y + body.h - box_h));
        try self.outlinedBox(scratch, rects, box_x, box_y, box_w, box_h, self.theme.selection, self.theme.accent);

        for (0..shown) |i| {
            const fi = start + i;
            const item = p.items.items[p.filtered.items[fi]];
            const row_y = box_y + @as(f32, @floatFromInt(i)) * self.line_h;
            const selected = fi == p.selected;
            if (selected) try rects.append(scratch, .{ .x = box_x, .y = row_y, .w = box_w, .h = self.line_h, .color = self.theme.accent });
            try self.propLine(scratch, runs, item, box_x + self.cell_w, row_y + self.ascent, if (selected) self.theme.background else self.theme.foreground);
        }
    }

    /// Draw hover text (LSP) as an outlined box anchored below the caret at
    /// `off` (flipping above when it would overflow the body). Multi-line: the
    /// text is split on '\n', capped to `max_hover_rows`, each line rendered as
    /// a mono run. Off-screen caret ⇒ nothing (same rule as the caret popup).
    fn drawHoverAtCaret(
        self: *View,
        scratch: Allocator,
        runs: *std.ArrayList(Run),
        rects: *std.ArrayList(Rect),
        text: []const u8,
        off: usize,
        body: region.Rect,
    ) !void {
        if (text.len == 0) return;
        const li = self.frame_layout.lineForOffset(off) orelse return; // off-screen
        const c = self.frame_layout.lines[li].caretAt(off);

        var rows: usize = 0;
        var max_cols: usize = 8;
        var it = std.mem.splitScalar(u8, text, '\n');
        while (it.next()) |line| : (rows += 1) {
            if (rows >= Hud.max_hover_rows) break;
            max_cols = @max(max_cols, std.unicode.utf8CountCodepoints(line) catch line.len);
        }
        if (rows == 0) return;

        const box_w = @as(f32, @floatFromInt(max_cols + 2)) * self.cell_w;
        const box_h = @as(f32, @floatFromInt(rows)) * self.line_h;
        const box_x = std.math.clamp(c.x, body.x, @max(body.x, body.x + body.w - box_w));
        var box_y = c.y_top + c.height; // just below the caret line
        if (box_y + box_h > body.y + body.h) box_y = c.y_top - box_h; // flip above
        box_y = std.math.clamp(box_y, body.y, @max(body.y, body.y + body.h - box_h));
        try self.outlinedBox(scratch, rects, box_x, box_y, box_w, box_h, self.theme.selection, self.theme.accent);

        var line_it = std.mem.splitScalar(u8, text, '\n');
        var i: usize = 0;
        while (line_it.next()) |line| : (i += 1) {
            if (i >= rows) break;
            const row_y = box_y + @as(f32, @floatFromInt(i)) * self.line_h;
            try self.propLine(scratch, runs, line, box_x + self.cell_w, row_y + self.ascent, self.theme.foreground);
        }
    }

    /// A filled box with a 1px outline: the border rect (1px larger all round)
    /// drawn first, the fill on top, so the border reads as a thin frame.
    fn outlinedBox(self: *View, scratch: Allocator, rects: *std.ArrayList(Rect), x: f32, y: f32, w: f32, h: f32, fill: [4]f32, border: [4]f32) !void {
        _ = self;
        try rects.append(scratch, .{ .x = x - 1, .y = y - 1, .w = w + 2, .h = h + 2, .color = border });
        try rects.append(scratch, .{ .x = x, .y = y, .w = w, .h = h, .color = fill });
    }

    /// Shape `text` as one mono run at an explicit world x/baseline + color (a
    /// `.prop` placement — independent of the pane's content origin).
    fn propLine(self: *View, scratch: Allocator, runs: *std.ArrayList(Run), text: []const u8, x: f32, baseline_y: f32, color: [4]f32) !void {
        const shaped = try snail.shape(scratch, &self.face_set.mono, text, .{});
        try runs.append(scratch, .{ .shaped = shaped, .baseline_y = baseline_y, .place = .{ .prop = .{ .x = x, .em = self.em, .color = color } } });
    }

    /// Draw retained plugin overlays (surfaces) as floating boxes. corner docks
    /// top-right of the pane, center is centered; bottom is left to the dock
    /// (buildHud) and skipped here. Each row's spans render at their own color
    /// (by Role), and a `selected` row gets a highlight behind it. Overlays are
    /// drawn last, so they sit above the body — and, being boxes with their own
    /// background, they don't reflow it.
    fn drawSurfaces(
        self: *View,
        scratch: Allocator,
        runs: *std.ArrayList(Run),
        rects: *std.ArrayList(Rect),
        hud: Hud,
        body: region.Rect,
        caret_y: ?f32,
    ) !void {
        // A surface floats within `body`; cap the row count to what fits, so a
        // popup can never extend past the region it was handed.
        const max_rows = @max(1, @as(usize, @intFromFloat(@max(0, body.h) / self.line_h)) -| 1);
        for (hud.surfaces) |surf| {
            if (!surf.active or surf.rows.items.len == 0) continue;
            if (surf.placement == .bottom) continue; // dock handled by buildHud

            const nrows = @min(surf.rows.items.len, max_rows);
            // Width = widest row, in cells (one space between spans).
            var max_cols: usize = 0;
            for (surf.rows.items[0..nrows]) |row| {
                var cols: usize = 0;
                for (row.spans.items, 0..) |sp, si| {
                    if (si != 0) cols += 1;
                    cols += std.unicode.utf8CountCodepoints(sp.text) catch sp.text.len;
                }
                max_cols = @max(max_cols, cols);
            }
            const pad_x: f32 = self.cell_w;
            const pad_y: f32 = self.line_h * 0.25;
            const box_w = @as(f32, @floatFromInt(max_cols)) * self.cell_w + 2 * pad_x;
            const box_h = @as(f32, @floatFromInt(nrows)) * self.line_h + 2 * pad_y;
            // Positioned within `body`, then clamped so the box stays inside it
            // (its own background reads as a popup over the text, never over the
            // status/tab strips, which live outside `body`).
            // A corner surface docks top-right by default, but gets out of the
            // way of the caret: if the caret sits in the top half of the body
            // (where the box would land), it flips to the bottom-right instead,
            // so a which-key popup never covers the line you're editing.
            const corner_top = if (caret_y) |cy|
                cy > body.y + body.h / 2
            else
                true;
            const raw_x, const raw_y = switch (surf.placement) {
                .corner => .{
                    body.x + body.w - box_w - pad_x,
                    if (corner_top) body.y + pad_x else body.y + body.h - box_h - pad_x,
                },
                .center => .{ body.x + (body.w - box_w) / 2, body.y + (body.h - box_h) / 2 },
                .bottom => unreachable,
            };
            const box_x = std.math.clamp(raw_x, body.x, @max(body.x, body.x + body.w - box_w));
            const box_y = std.math.clamp(raw_y, body.y, @max(body.y, body.y + body.h - box_h));
            // Panel background with a thin accent outline, so the popup reads
            // as a distinct floating box (not text bleeding over the buffer).
            try self.outlinedBox(scratch, rects, box_x, box_y, box_w, box_h, self.theme.selection, self.theme.accent);

            for (surf.rows.items[0..nrows], 0..) |row, i| {
                const row_y = box_y + pad_y + @as(f32, @floatFromInt(i)) * self.line_h;
                if (surf.selected != null and surf.selected.? == i) {
                    try rects.append(scratch, .{ .x = box_x, .y = row_y, .w = box_w, .h = self.line_h, .color = self.theme.accent });
                }
                var x = box_x + pad_x;
                const baseline = row_y + self.ascent;
                for (row.spans.items, 0..) |sp, si| {
                    if (si != 0) x += self.cell_w; // gap between spans
                    const shaped = try snail.shape(scratch, &self.face_set.mono, sp.text, .{});
                    try runs.append(scratch, .{
                        .shaped = shaped,
                        .baseline_y = baseline,
                        .place = .{ .prop = .{ .x = x, .em = self.em, .color = self.theme.roleColor(sp.role) } },
                    });
                    x += shaped.advanceX() * self.em;
                }
            }
        }
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

test {
    // Pull the extracted submodules' own tests into this file's test set (it
    // is the one referenced by src/tests.zig, so re-exports alone would not
    // guarantee their discovery).
    _ = @import("view/theme.zig");
    _ = @import("view/hud.zig");
    _ = @import("view/statusline.zig");
}

test "literal tabs: a tab advances to the next tab stop; offsets stay exact" {
    const gpa = testing.allocator;
    var view = try View.init(gpa, @embedFile("font_mono"), 16);
    defer view.deinit();
    // "a\tb": 'a' at col 0, the tab starts at col 1 and advances 'b' to the
    // next tab stop (col 4). Empty frame_layout → the motion path
    // (buildRowStops) computes x; the on-screen mono builder mirrors it.
    var rope = try stemma.Rope.fromSlice(gpa, "a\tb");
    defer rope.deinit(gpa);
    const cw = view.cell_w;
    try testing.expectApproxEqAbs(margin, try view.xOfOffsetOnRow(&rope, 0), 0.5);
    try testing.expectApproxEqAbs(margin + cw, try view.xOfOffsetOnRow(&rope, 1), 0.5);
    try testing.expectApproxEqAbs(margin + 4 * cw, try view.xOfOffsetOnRow(&rope, 2), 0.5);
    // Two leading tabs → 8 columns of indent before the text.
    var rope2 = try stemma.Rope.fromSlice(gpa, "\t\tx");
    defer rope2.deinit(gpa);
    try testing.expectApproxEqAbs(margin + 8 * cw, try view.xOfOffsetOnRow(&rope2, 2), 0.5);
}

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

test "styles: a published styles bulk resolves to StyleClass colors; highlight wins" {
    const gpa = testing.allocator;
    var view = try View.init(gpa, @embedFile("font_mono"), 16);
    defer view.deinit();

    // A styles feed (as the host publishes it): one class byte per doc byte.
    var classes = [_]u8{
        @intFromEnum(StyleClass.added),
        @intFromEnum(StyleClass.removed),
        @intFromEnum(StyleClass.location),
        @intFromEnum(StyleClass.normal),
    };
    const si: StyleInputs = .{ .st = @ptrCast(classes[0..]), .st_base = 0 };
    try testing.expectEqual(view.theme.styleColor(.added), view.hlColor(si, 0));
    try testing.expectEqual(view.theme.styleColor(.removed), view.hlColor(si, 1));
    try testing.expectEqual(view.theme.styleColor(.location), view.hlColor(si, 2));
    try testing.expectEqual(view.theme.foreground, view.hlColor(si, 3)); // .normal
    try testing.expectEqual(view.theme.foreground, view.hlColor(si, 99)); // out of range

    // Where both feeds cover a byte, syntax highlight wins (a code buffer never
    // has styles, but the precedence is defined).
    var hl = [_]u8{@intFromEnum(HighlightClass.keyword)};
    const si2: StyleInputs = .{ .hl = @ptrCast(hl[0..]), .st = @ptrCast(classes[0..]) };
    try testing.expectEqual(view.theme.classColor(.keyword), view.hlColor(si2, 0));
}

test "styles: Hud.styles_layer flows through resolveStyleInputs (the render seam)" {
    const gpa = testing.allocator;
    var view = try View.init(gpa, @embedFile("font_mono"), 16);
    defer view.deinit();

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
    const si = try view.resolveStyleInputs(arena.allocator(), hud, doc.text(), 2, 2);
    try testing.expect(si.st != null);
    try testing.expectEqual(view.theme.styleColor(.added), view.hlColor(si, 0));
    try testing.expectEqual(view.theme.styleColor(.removed), view.hlColor(si, 5));
    try testing.expectEqual(view.theme.foreground, view.hlColor(si, 1)); // unpainted
}
