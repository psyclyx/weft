//! View — Editor state → snail shapes. One monospace face on a cell
//! grid (the terminal demo's placement path: explicit integer columns,
//! `CellSnap.grid` for pixel-exact columns), plus cursor and selection
//! rendered as FULL BLOCK (U+2588) cell runs *behind* the text — no
//! extra pipeline, same atlas, correct by construction.
//!
//! The view is a pure subscriber: it reads the rope and the editor's
//! cursor/selection, and owns only presentation state (scroll, metrics,
//! atlas residency). Damage is the caller's concern (rebuild when the
//! commit count moved); atlas growth is reported so the caller knows
//! when to upload.

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const snail = @import("snail");
const stemma = @import("stemma");
const core = @import("../core/core.zig");
const prepare = @import("prepare.zig");

const font_id_mono: u32 = 1;
const margin: f32 = 8;

/// sRGB-authored theme, converted to linear at init (snail's color ABI
/// is linear, straight alpha).
pub const Theme = struct {
    background: [4]f32 = .{ 0.086, 0.09, 0.102, 1 },
    foreground: [4]f32 = .{ 0.85, 0.86, 0.87, 1 },
    cursor: [4]f32 = .{ 0.95, 0.75, 0.30, 1 },
    cursor_text: [4]f32 = .{ 0.086, 0.09, 0.102, 1 },
    selection: [4]f32 = .{ 0.25, 0.34, 0.47, 1 },

    fn linearized(self: Theme) Theme {
        return .{
            .background = snail.color.srgbToLinearColor(self.background),
            .foreground = snail.color.srgbToLinearColor(self.foreground),
            .cursor = snail.color.srgbToLinearColor(self.cursor),
            .cursor_text = snail.color.srgbToLinearColor(self.cursor_text),
            .selection = snail.color.srgbToLinearColor(self.selection),
        };
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

pub const View = struct {
    gpa: Allocator,
    font: *snail.Font,
    faces: snail.Faces,
    pool: *snail.PagePool,
    atlas: snail.Atlas,
    theme: Theme,

    em: f32,
    cell_w: f32,
    line_h: f32,
    ascent: f32,
    top_row: usize = 0,

    pub fn init(gpa: Allocator, font_bytes: []const u8, em: f32) !View {
        const font = try gpa.create(snail.Font);
        errdefer gpa.destroy(font);
        font.* = try snail.Font.init(font_bytes);

        var faces = try snail.Faces.build(gpa, &.{
            .{ .font = font, .font_id = font_id_mono },
        });
        errdefer faces.deinit();

        const pool = try snail.PagePool.init(gpa, .{
            .max_pages = 16,
            .curve_words_per_page = 1 << 19,
            .band_words_per_page = 1 << 15,
        });
        errdefer pool.deinit();
        var atlas = try snail.Atlas.init(gpa, pool);
        errdefer atlas.deinit();

        const upem: f32 = @floatFromInt(font.unitsPerEm());
        const lm = try font.lineMetrics();
        const advance = try font.advanceWidth(try font.glyphIndex('M'));
        const ascent: f32 = @floatFromInt(lm.ascent);
        const descent: f32 = @floatFromInt(lm.descent);
        const gap: f32 = @floatFromInt(lm.line_gap);

        return .{
            .gpa = gpa,
            .font = font,
            .faces = faces,
            .pool = pool,
            .atlas = atlas,
            .theme = (Theme{}).linearized(),
            .em = em,
            .cell_w = em * @as(f32, @floatFromInt(advance)) / upem,
            .line_h = em * (ascent - descent + gap) / upem,
            .ascent = em * ascent / upem,
        };
    }

    pub fn deinit(self: *View) void {
        self.atlas.deinit();
        self.pool.deinit();
        self.faces.deinit();
        self.gpa.destroy(self.font);
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

    /// Keep the cursor's row inside the viewport (call before build).
    pub fn scrollToCursor(self: *View, editor: *const core.Editor, fb_h: u32) void {
        const rows = self.visibleRows(fb_h);
        const cur = editor.text().offsetToPoint(editor.cursorOffset()).row;
        if (cur < self.top_row) self.top_row = cur;
        if (cur >= self.top_row + rows) self.top_row = cur + 1 - rows;
    }

    const Run = struct {
        shaped: snail.ShapedText,
        cells: []snail.Cell,
        baseline_y: f32,
    };

    /// Build the visible picture: selection/cursor block runs first (they
    /// draw behind), then one text run per non-empty visible line.
    pub fn build(
        self: *View,
        scratch: Allocator,
        editor: *const core.Editor,
        fb_w: u32,
        fb_h: u32,
        world_to_pixel: snail.Transform2D,
    ) !Built {
        const rope = editor.text();
        const rows_visible = self.visibleRows(fb_h);
        const cols_visible = self.visibleCols(fb_w);
        const total_rows = rope.lineCount();
        const cursor_off = editor.cursorOffset();
        const cursor_pt = rope.offsetToPoint(cursor_off);
        const selection = editor.selectedRange();

        var runs: std.ArrayList(Run) = .empty;
        defer {
            for (runs.items) |*r| r.shaped.deinit();
            runs.deinit(scratch);
        }

        var row = self.top_row;
        while (row < total_rows and row < self.top_row + rows_visible) : (row += 1) {
            const baseline = margin + self.ascent +
                @as(f32, @floatFromInt(row - self.top_row)) * self.line_h;
            const line = rope.lineRange(row);

            // Block layer: selection cells on this row, and the cursor.
            var block_cols: std.ArrayList(BlockCell) = .empty;
            defer block_cols.deinit(scratch);
            if (selection) |sel| {
                const s = @max(sel.start, line.start);
                const e = @min(sel.end, line.end);
                if (s < e) {
                    const c0 = rope.offsetToScalar(s) - rope.offsetToScalar(line.start);
                    const c1 = rope.offsetToScalar(e) - rope.offsetToScalar(line.start);
                    var c = c0;
                    while (c < c1 and c < cols_visible) : (c += 1) {
                        try block_cols.append(scratch, .{ .col = @intCast(c), .color = self.theme.selection });
                    }
                }
            }
            const cursor_here = cursor_pt.row == row;
            const cursor_col = if (cursor_here)
                rope.offsetToScalar(@min(cursor_off, line.end)) - rope.offsetToScalar(line.start)
            else
                0;
            if (cursor_here and cursor_col < cols_visible) {
                try block_cols.append(scratch, .{ .col = @intCast(cursor_col), .color = self.theme.cursor });
            }
            if (block_cols.items.len > 0) {
                try self.appendBlockRun(scratch, &runs, block_cols.items, baseline);
            }

            // Text layer.
            if (!line.isEmpty()) {
                try self.appendTextRun(
                    scratch,
                    &runs,
                    rope,
                    line,
                    cols_visible,
                    baseline,
                    if (cursor_here) cursor_col else null,
                );
            }
        }

        // Prepare all runs' glyphs into the atlas (idempotent for
        // resident records), then place.
        const run_ptrs = try scratch.alloc(*const snail.ShapedText, runs.items.len);
        defer scratch.free(run_ptrs);
        for (runs.items, run_ptrs) |*r, *out| out.* = &r.shaped;
        const sources = [_]snail.FontSource{.{
            .font_id = font_id_mono,
            .font = self.font,
            .cache_key = [_]u8{font_id_mono} ** 16,
        }};
        const before = self.atlas.recordCount();
        try prepare.run(self.gpa, &self.atlas, &sources, run_ptrs, .{ .unhinted = .{ .colr = .layers } });
        const after = self.atlas.recordCount();

        var shape_count: usize = 0;
        for (runs.items) |*r| {
            shape_count += try snail.placedCellRunShapeCount(
                &r.shaped,
                &self.faces,
                r.cells,
                self.placement(r.baseline_y, world_to_pixel),
            );
        }
        const shapes = try self.gpa.alloc(snail.Shape, shape_count);
        errdefer self.gpa.free(shapes);
        var at: usize = 0;
        for (runs.items) |*r| {
            const placed = try snail.placeCellRun(
                shapes[at..],
                &r.shaped,
                &self.faces,
                r.cells,
                self.placement(r.baseline_y, world_to_pixel),
            );
            at += placed.len;
        }
        assert(at == shapes.len);

        return .{ .shapes = shapes, .records_added = after - before };
    }

    fn placement(self: *const View, baseline_y: f32, world_to_pixel: snail.Transform2D) snail.CellRunPlacement {
        return .{
            .baseline = .{ .x = margin, .y = baseline_y },
            .cell_width = self.cell_w,
            .em = self.em,
            .snap = .grid,
            .y_axis = .down,
            .world_to_pixel = world_to_pixel,
        };
    }

    /// One text run for a visible line: one cell per scalar, truncated
    /// at the viewport's right edge. The character under a block cursor
    /// flips to the cursor-text color. `scratch` must be an arena — run
    /// text and cell arrays live in it until the build returns.
    fn appendTextRun(
        self: *View,
        scratch: Allocator,
        runs: *std.ArrayList(Run),
        rope: *const stemma.Rope,
        line: stemma.Range,
        cols_visible: usize,
        baseline_y: f32,
        cursor_col: ?usize,
    ) !void {
        // Enough bytes for the visible columns even if all are 4-byte
        // scalars; boundary-snap the cut.
        const cap = @min(line.len(), cols_visible * 4 + 4);
        const raw = try scratch.alloc(u8, cap);
        var sr = rope.streamReader(.{ .start = line.start, .end = line.start + cap }, &.{});
        sr.interface.readSliceAll(raw) catch unreachable;
        var end = raw.len;
        if (cap < line.len()) {
            // The window may have cut a multi-byte scalar; drop the
            // incomplete tail (never a complete final character).
            while (end > 0 and (raw[end - 1] & 0xC0) == 0x80) end -= 1;
            if (end > 0 and raw[end - 1] >= 0xC0) end -= 1;
        }
        const text = raw[0..end];
        // Tabs render as a space column (display substitution only —
        // the document is untouched).
        for (text) |*b| {
            if (b.* == '\t') b.* = ' ';
        }

        var cells: std.ArrayList(snail.Cell) = .empty;
        var it = (std.unicode.Utf8View.init(text) catch return error.InvalidUtf8).iterator();
        var col: usize = 0;
        var byte: usize = 0;
        while (it.nextCodepointSlice()) |s| : (col += 1) {
            if (col >= cols_visible) break;
            const color = if (cursor_col != null and col == cursor_col.?)
                self.theme.cursor_text
            else
                self.theme.foreground;
            try cells.append(scratch, .{
                .source = .{ .start = @intCast(byte), .end = @intCast(byte + s.len) },
                .column = @intCast(col),
                .color = color,
            });
            byte += s.len;
        }
        if (cells.items.len == 0) return;

        const shaped = try snail.shape(scratch, &self.faces, text[0..byte], .{});
        try runs.append(scratch, .{
            .shaped = shaped,
            .cells = cells.items,
            .baseline_y = baseline_y,
        });
    }

    const BlockCell = struct { col: u32, color: [4]f32 };
    const block_utf8 = "\u{2588}"; // FULL BLOCK, 3 bytes

    /// Cursor/selection backgrounds: a run of FULL BLOCK glyphs at the
    /// given columns, drawn behind the text layer.
    fn appendBlockRun(
        self: *View,
        scratch: Allocator,
        runs: *std.ArrayList(Run),
        cols: []const BlockCell,
        baseline_y: f32,
    ) !void {
        const text = try scratch.alloc(u8, cols.len * block_utf8.len);
        var cells = try scratch.alloc(snail.Cell, cols.len);
        for (cols, 0..) |bc, i| {
            const start = i * block_utf8.len;
            @memcpy(text[start..][0..block_utf8.len], block_utf8);
            cells[i] = .{
                .source = .{ .start = @intCast(start), .end = @intCast(start + block_utf8.len) },
                .column = bc.col,
                .color = bc.color,
            };
        }
        const shaped = try snail.shape(scratch, &self.faces, text, .{});
        try runs.append(scratch, .{
            .shaped = shaped,
            .cells = cells,
            .baseline_y = baseline_y,
        });
    }
};
