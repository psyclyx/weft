//! grid — an entry whose content is a grid of styled cells, not text: what a
//! terminal emulator presents (doc/terminal.md §3). The plugin that owns the
//! entry publishes rows (`wl_grid_publish`), only the ones that changed; core
//! keeps the cells and the cursor, and the frame draws a snapshot of them.
//!
//! Owned by the ENTRY (`Buffer.grid`), like a projection: it is what the pane
//! shows, and it outlives nothing but the entry. No history, no document —
//! a screen that redraws sixty times a second must not leave a trail.
//!
//! `Extent` is the other direction: the cells the pane showing the entry has
//! room for, as the last frame laid it out. The frame writes it; the owner
//! reads it (`wl_entry_extent`) and sizes its grid — and its terminal — to
//! it. A change is flagged so the owner hears of it after the frame
//! (`on_poll`), never during one.

const std = @import("std");
const Allocator = std.mem.Allocator;
const wire = @import("weft_membrane").grid;

pub const Cell = wire.Cell;
pub const CursorShape = wire.CursorShape;

pub const Cursor = struct {
    x: u16 = 0,
    y: u16 = 0,
    shape: CursorShape = .block,
    visible: bool = false,
};

/// Room in cells, and the cell's size in pixels, of the pane an entry shows
/// in.
pub const Extent = struct {
    cols: u16,
    rows: u16,
    cell_w: u16 = 0,
    cell_h: u16 = 0,

    pub fn eql(a: Extent, b: Extent) bool {
        return a.cols == b.cols and a.rows == b.rows and a.cell_w == b.cell_w and a.cell_h == b.cell_h;
    }
};

pub const Grid = struct {
    cols: u16 = 0,
    rows: u16 = 0,
    cells: []Cell = &.{},
    cursor: Cursor = .{},
    /// Bumped by every publish: what a frame compares to know the grid moved.
    revision: u64 = 0,

    pub fn deinit(self: *Grid, gpa: Allocator) void {
        gpa.free(self.cells);
        self.* = undefined;
    }

    /// Apply one publish (`wire.Message`): resize if its size differs, copy
    /// the rows it sent, take its cursor. A malformed message changes
    /// nothing.
    pub fn apply(self: *Grid, gpa: Allocator, bytes: []const u8) (wire.DecodeError || Allocator.Error)!void {
        const m = try wire.Message.parse(bytes);
        const h = m.header;
        for (0..h.rows_sent) |i| if (m.row(i).index >= h.rows) return error.Malformed;
        if (h.cols != self.cols or h.rows != self.rows) {
            const cells = try gpa.alloc(Cell, @as(usize, h.cols) * h.rows);
            @memset(cells, .{ .cp = 0 });
            // What was there stays where it still fits, so a resize the plugin
            // answers a frame later does not blank the screen meanwhile.
            const keep_cols = @min(self.cols, h.cols);
            for (0..@min(self.rows, h.rows)) |r|
                @memcpy(cells[r * h.cols ..][0..keep_cols], self.cells[r * self.cols ..][0..keep_cols]);
            gpa.free(self.cells);
            self.cells = cells;
            self.cols = h.cols;
            self.rows = h.rows;
        }
        for (0..h.rows_sent) |i| {
            const r = m.row(i);
            const dst = std.mem.sliceAsBytes(self.cells[@as(usize, r.index) * h.cols ..][0..h.cols]);
            @memcpy(dst, r.cells);
        }
        self.cursor = .{
            .x = @min(h.cursor_x, h.cols -| 1),
            .y = @min(h.cursor_y, h.rows -| 1),
            .shape = std.enums.fromInt(CursorShape, @intFromEnum(h.cursor_shape)) orelse .block,
            .visible = h.flags & wire.Header.cursor_visible != 0,
        };
        self.revision +%= 1;
    }

    /// The cells of row `r`.
    pub fn row(self: *const Grid, r: usize) []const Cell {
        return self.cells[r * self.cols ..][0..self.cols];
    }

    /// A copy for one frame (doc/model.md §2.7): what the pane draws is this,
    /// whatever the owner publishes while the frame is built.
    pub fn snapshot(self: *const Grid, arena: Allocator) Allocator.Error!Snapshot {
        return .{ .cols = self.cols, .rows = self.rows, .cells = try arena.dupe(Cell, self.cells), .cursor = self.cursor };
    }
};

/// A grid as one frame saw it.
pub const Snapshot = struct {
    cols: u16,
    rows: u16,
    cells: []const Cell,
    cursor: Cursor,

    pub fn row(self: *const Snapshot, r: usize) []const Cell {
        return self.cells[r * self.cols ..][0..self.cols];
    }
};

// ── Tests ───────────────────────────────────────────────────────────

const t = std.testing;

fn message(gpa: Allocator, cols: u16, rows: u16, sent: []const struct { u32, []const u8 }) ![]u8 {
    const out = try gpa.alloc(u8, wire.messageLen(cols, sent.len));
    const h: wire.Header = .{ .cols = cols, .rows = rows, .cursor_x = 1, .cursor_y = 0, .flags = wire.Header.cursor_visible, .rows_sent = @intCast(sent.len) };
    @memcpy(out[0..16], std.mem.asBytes(&h));
    var at: usize = 16;
    for (sent) |s| {
        std.mem.writeInt(u32, out[at..][0..4], s[0], .little);
        at += 4;
        for (0..cols) |c| {
            const cell: Cell = .{ .cp = if (c < s[1].len) s[1][c] else 0 };
            @memcpy(out[at..][0..16], std.mem.asBytes(&cell));
            at += 16;
        }
    }
    return out;
}

test "grid: rows land where they are sent, and a resize keeps what still fits" {
    const gpa = t.allocator;
    var g: Grid = .{};
    defer g.deinit(gpa);
    const m1 = try message(gpa, 4, 2, &.{ .{ 0, "ab" }, .{ 1, "cd" } });
    defer gpa.free(m1);
    try g.apply(gpa, m1);
    try t.expectEqual(@as(u32, 'c'), g.row(1)[0].cp);
    try t.expect(g.cursor.visible);
    // Only row 0 changes; row 1 is kept.
    const m2 = try message(gpa, 4, 2, &.{.{ 0, "xy" }});
    defer gpa.free(m2);
    try g.apply(gpa, m2);
    try t.expectEqual(@as(u32, 'x'), g.row(0)[0].cp);
    try t.expectEqual(@as(u32, 'd'), g.row(1)[1].cp);
    // Grow: the old cells stay at their places, the new ones are blank.
    const m3 = try message(gpa, 6, 3, &.{});
    defer gpa.free(m3);
    try g.apply(gpa, m3);
    try t.expectEqual(@as(u32, 'd'), g.row(1)[1].cp);
    try t.expectEqual(@as(u32, 0), g.row(2)[0].cp);
    // A row past the grid is refused whole.
    const bad = try message(gpa, 6, 3, &.{.{ 3, "no" }});
    defer gpa.free(bad);
    try t.expectError(error.Malformed, g.apply(gpa, bad));
}
