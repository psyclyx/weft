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

const snail = @import("snail");
const stemma = @import("stemma");
const core = @import("../core/core.zig");
const layout = @import("layout.zig");
const region = @import("region.zig");
const fonts = @import("fonts.zig");
const statusline = @import("view/statusline.zig");
const popup = @import("view/popup.zig");
const decoration = @import("view/decoration.zig");
const linelayout = @import("view/linelayout.zig");
const render = @import("view/render.zig");

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

        const styles = try linelayout.resolveStyleInputs(self, scratch, hud, rope, rows_visible, total_rows);

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
            const vl = try linelayout.layoutLine(self, scratch, la, &runs, rope, row, y_top, cols_visible, hud.md_inline, styles, flip_off);
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
        if (selection) |sel| try decoration.selectionRects(self, scratch, &rects, sel, self.theme.selection);
        // vim-goggles: a transient flash over a just-operated range (e.g. yank).
        if (hud.flash) |fl| try decoration.selectionRects(self, scratch, &rects, fl, self.theme.accent);
        if (hud.cursor_on) try decoration.caretRect(self, scratch, &rects, cursor_off, hud.cursor_style, self.theme.cursor);
        if (hud.presence_layer) |pl| {
            for (0..pl.spanCount()) |i| {
                const span = pl.resolvedSpan(i);
                // A peer span packs its identity hue in kind's low 16 bits;
                // bit 16 marks which end holds the caret (see session.zig
                // republishPresence). start==end ⇒ a caret with no selection.
                const hue = @as(f32, @floatFromInt(span.kind & 0xffff)) / 65535.0;
                if (span.end > span.start) {
                    try decoration.selectionRects(self, scratch, &rects, .{ .start = span.start, .end = span.end }, decoration.peerColor(hue, 0.55, 0.28));
                }
                const head = if (span.kind & 0x10000 == 0) span.start else span.end;
                try decoration.caretRect(self, scratch, &rects, head, .bar, decoration.peerColor(hue, 0.62, 1.0));
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
        try popup.drawSurfaces(self, scratch, &runs, &rects, hud, body_rect, caret_y);
        // The picker draws into its carved window-bottom dock (main cut it off
        // the window with cutBottom, so it cannot overlap panes or a status
        // line). A completion pick anchors at the caret instead — a popup.
        if (hud.pick) |p| {
            if (p.caret_anchor) |off|
                try popup.drawPickAtCaret(self, scratch, &runs, &rects, p, off, body_rect)
            else
                try popup.drawPickInto(self, scratch, &runs, &rects, p, pick_dock);
        }
        // Hover info floats at the caret, above everything else.
        if (hud.hover) |hv| try popup.drawHoverAtCaret(self, scratch, &runs, &rects, hv.text, hv.offset, body_rect);

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

        return try render.render(self, world_to_pixel, runs.items, rects.items);
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
};

// ── Tests ──

const testing = std.testing;

test {
    // Pull the extracted submodules' own tests into this file's test set (it
    // is the one referenced by src/tests.zig, so re-exports alone would not
    // guarantee their discovery).
    _ = @import("view/theme.zig");
    _ = @import("view/hud.zig");
    _ = @import("view/statusline.zig");
    _ = @import("view/popup.zig");
    _ = @import("view/decoration.zig");
    _ = @import("view/linelayout.zig");
    _ = @import("view/render.zig");
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
