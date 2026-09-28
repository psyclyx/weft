//! grid — an entry whose content is a grid of styled cells: what a terminal
//! emulator presents (doc/terminal.md §3). The plugin that owns the entry
//! publishes rows (`wl_grid_publish`), only the ones that changed; core
//! keeps the cells and the cursor, and the frame draws a snapshot of them.
//!
//! Owned by the ENTRY (`Buffer.grid`), like a projection: it is what the pane
//! shows, and it outlives nothing but the entry.
//!
//! Above the screen is the HISTORY: the rows that scrolled off it, as the
//! owner says (a `history` section) — only while the entry is READ rather
//! than captured (`Extent.reading`), because a flood nobody reads should not
//! be copied. The history and the screen together are the entry's rows, and
//! their text is its document (`grid_mirror.zig`): row `i` is line `i`, a
//! cell's text is `cellText`, so an offset in the document names a cell.
//!
//! `Extent` is the other direction: the cells the pane showing the entry has
//! room for, as the last frame laid it out, and whether it reads the entry
//! as text. The frame writes it; the owner reads it (`wl_entry_extent`) and
//! sizes its grid — and its terminal — to it. A change is flagged so the
//! owner hears of it after the frame (`on_poll`), never during one.

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
/// in — and how the pane shows it.
pub const Extent = struct {
    cols: u16,
    rows: u16,
    cell_w: u16 = 0,
    cell_h: u16 = 0,
    /// The pane reads the entry as TEXT — it is not capturing — so what is
    /// above the screen is wanted too (a terminal sends its scrollback).
    reading: bool = false,

    pub fn eql(a: Extent, b: Extent) bool {
        return a.cols == b.cols and a.rows == b.rows and a.cell_w == b.cell_w and a.cell_h == b.cell_h and a.reading == b.reading;
    }

    /// `flags` on the wire (`wl_entry_extent`).
    pub const flag_reading: u16 = 1;
};

/// A cell's text in the entry's document: its scalar, a space for an empty
/// cell, nothing for the second half of a wide character, U+FFFD for what
/// is no scalar. The one spelling both the document and the view's
/// geometry read, so an offset and a cell can never disagree.
pub fn cellText(cell: Cell, buf: *[4]u8) []const u8 {
    if (cell.width == 0) return buf[0..0];
    if (cell.cp == 0) {
        buf[0] = ' ';
        return buf[0..1];
    }
    const cp = std.math.cast(u21, cell.cp) orelse 0xfffd;
    const n = std.unicode.utf8Encode(cp, buf) catch std.unicode.utf8Encode(0xfffd, buf) catch unreachable;
    return buf[0..n];
}

/// Append row `cells`' text (trailing blanks dropped) to `out`.
pub fn appendRowText(gpa: Allocator, out: *std.ArrayList(u8), cells: []const Cell) Allocator.Error!void {
    const start = out.items.len;
    var buf: [4]u8 = undefined;
    for (cells) |c| try out.appendSlice(gpa, cellText(c, &buf));
    while (out.items.len > start and out.items[out.items.len - 1] == ' ') out.items.len -= 1;
}

pub const Grid = struct {
    cols: u16 = 0,
    rows: u16 = 0,
    cells: []Cell = &.{},
    cursor: Cursor = .{},
    /// Bumped by every publish: what a frame compares to know the grid moved.
    revision: u64 = 0,
    /// The rows above the screen, oldest first (`historyRow`): their cells
    /// end to end, each row a span of them — one store, not an allocation a
    /// row, since a flood turns thousands over every wake. Rows dropped from
    /// the front stay dead in place until they outnumber the live ones.
    history_cells: std.ArrayList(Cell) = .empty,
    history_rows: std.ArrayList(Span) = .empty,
    dead_rows: usize = 0,
    /// How many history rows were ever dropped from the front: the absolute
    /// number of `historyRow(0)`, so a reader that remembered a range of
    /// rows can tell which of them are still here.
    history_start: u64 = 0,
    /// What the entry's document holds of these rows (`grid_mirror`), or
    /// null before it was first written.
    mirror: ?Mirror = null,
    /// Some cell ever said it is part of a prompt (a shell with integration):
    /// the rows have LANDMARKS to move between (`grid_mirror.landmark`).
    landmarks: bool = false,
    /// Who has the keys, as the program DECLARED it (`input` sections,
    /// doc/terminal.md §8). Until one says otherwise the program owns every
    /// key: a terminal with no shell integration captures, as it always did.
    input: Input = .{},
    /// The command line as the editor holds it — the document's text there,
    /// owned, taken after every keystroke that changed it — and what the
    /// program was last told it is. Meaningful while `input.line` is set
    /// (`grid_mirror`, doc/terminal.md §8).
    field_text: std.ArrayList(u8) = .empty,
    field_pushed: std.ArrayList(u8) = .empty,

    pub const Input = struct {
        owns_keys: bool = true,
        /// The command line at a prompt, when there is one for the editor
        /// to edit as a field: its screen row and the cell it starts at.
        line: ?Line = null,
        /// Keys the program claims at its prompt ('\n'-joined specs, owned):
        /// they reach it whatever the grammar binds them to (Tab, Return).
        claimed: []u8 = &.{},

        pub const Line = struct { row: u16, col: u16 };

        /// Whether `spec` is one of the claimed keys.
        pub fn claims(self: *const Input, spec: []const u8) bool {
            var it = std.mem.splitScalar(u8, self.claimed, '\n');
            while (it.next()) |k| if (k.len > 0 and std.mem.eql(u8, k, spec)) return true;
            return false;
        }
    };

    /// The document is history rows `[start, end)` (absolute), one line
    /// each, then the screen's rows.
    pub const Mirror = struct { start: u64, end: u64 };

    /// A history row: where its cells start in `history_cells`, how many.
    pub const Span = struct { at: usize, len: u32 };

    /// What a publish said beyond the rows, for the entry to take up.
    pub const Applied = struct {
        /// A new title (borrowed from the message), when it carried one.
        title: ?[]const u8 = null,
        /// Where the program now is (borrowed), when the message said.
        cwd: ?[]const u8 = null,
        /// Who has the keys, when the message said (borrowed): what the entry
        /// takes up beyond `input`, the program's command line.
        input: ?wire.Input = null,
    };

    pub fn deinit(self: *Grid, gpa: Allocator) void {
        gpa.free(self.cells);
        self.history_cells.deinit(gpa);
        self.history_rows.deinit(gpa);
        gpa.free(self.input.claimed);
        self.field_text.deinit(gpa);
        self.field_pushed.deinit(gpa);
        self.* = undefined;
    }

    /// How many rows the history holds.
    pub fn historyLen(self: *const Grid) usize {
        return self.history_rows.items.len - self.dead_rows;
    }

    /// History row `i`, oldest first: as many cells as were sent for it.
    pub fn historyRow(self: *const Grid, i: usize) []const Cell {
        const s = self.history_rows.items[self.dead_rows + i];
        return self.history_cells.items[s.at..][0..s.len];
    }

    /// Apply one publish (`wire.Message`): resize if its size differs, copy
    /// the rows it sent, take its cursor, and its sections. A malformed
    /// message changes nothing.
    pub fn apply(self: *Grid, gpa: Allocator, bytes: []const u8) (wire.DecodeError || Allocator.Error)!Applied {
        const m = try wire.Message.parse(bytes);
        const h = m.header;
        for (0..h.rows_sent) |i| if (m.row(i).index >= h.rows) return error.Malformed;
        // Check every section before any takes effect.
        var applied: Applied = .{};
        var history: ?wire.History = null;
        var it = m.sections();
        while (it.next()) |s| switch (s.tag) {
            .title => applied.title = s.bytes,
            .cwd => applied.cwd = s.bytes,
            .input => applied.input = try wire.Input.parse(s.bytes),
            .history => history = try wire.History.parse(s.bytes),
            _ => {},
        };
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
            const dst_cells = self.cells[@as(usize, r.index) * h.cols ..][0..h.cols];
            @memcpy(std.mem.sliceAsBytes(dst_cells), r.cells);
            if (!self.landmarks) for (dst_cells) |c| if (c.mark.prompt) {
                self.landmarks = true;
                break;
            };
        }
        if (history) |hist| try self.applyHistory(gpa, hist);
        if (applied.input) |in| {
            const claimed = try gpa.dupe(u8, in.claimed);
            gpa.free(self.input.claimed);
            self.input = .{
                .owns_keys = in.head.flags & wire.InputHead.owns_keys != 0,
                .line = if (in.head.flags & wire.InputHead.line != 0) .{ .row = @intCast(@min(in.head.row, h.rows -| 1)), .col = @intCast(@min(in.head.col, h.cols)) } else null,
                .claimed = claimed,
            };
        }
        self.cursor = .{
            .x = @min(h.cursor_x, h.cols -| 1),
            .y = @min(h.cursor_y, h.rows -| 1),
            .shape = std.enums.fromInt(CursorShape, @intFromEnum(h.cursor_shape)) orelse .block,
            .visible = h.flags & wire.Header.cursor_visible != 0,
        };
        self.revision +%= 1;
        return applied;
    }

    fn applyHistory(self: *Grid, gpa: Allocator, hist: wire.History) (wire.DecodeError || Allocator.Error)!void {
        const live = self.historyLen();
        const drop: usize = if (hist.head.flags & wire.HistoryHead.reset != 0) live else @min(hist.head.dropped, live);
        self.dead_rows += drop;
        self.history_start += drop;
        if (self.dead_rows == self.history_rows.items.len) {
            self.history_rows.clearRetainingCapacity();
            self.history_cells.clearRetainingCapacity();
            self.dead_rows = 0;
        } else if (self.dead_rows > 256 and self.dead_rows * 2 > self.history_rows.items.len) {
            // Most of the store is dead: move the live rows down over it.
            const first = self.history_rows.items[self.dead_rows].at;
            const cells = self.history_cells.items[first..];
            std.mem.copyForwards(Cell, self.history_cells.items[0..cells.len], cells);
            self.history_cells.shrinkRetainingCapacity(cells.len);
            const rows = self.history_rows.items[self.dead_rows..];
            for (rows) |*s| s.at -= first;
            std.mem.copyForwards(Span, self.history_rows.items[0..rows.len], rows);
            self.history_rows.shrinkRetainingCapacity(rows.len);
            self.dead_rows = 0;
        }
        try self.history_rows.ensureUnusedCapacity(gpa, hist.head.count);
        try self.history_cells.ensureUnusedCapacity(gpa, (hist.rows.len - 4 * @as(usize, hist.head.count)) / @sizeOf(Cell));
        var rows = hist.iterator();
        while (try rows.next()) |raw| {
            const n = raw.len / @sizeOf(Cell);
            const at = self.history_cells.items.len;
            const dst = self.history_cells.addManyAsSliceAssumeCapacity(n);
            @memcpy(std.mem.sliceAsBytes(dst), raw);
            self.history_rows.appendAssumeCapacity(.{ .at = at, .len = @intCast(n) });
        }
    }

    /// The cells of screen row `r`.
    pub fn row(self: *const Grid, r: usize) []const Cell {
        return self.cells[r * self.cols ..][0..self.cols];
    }

    /// Every row, history then screen.
    pub fn rowCount(self: *const Grid) usize {
        return self.historyLen() + self.rows;
    }

    /// Row `i` of `rowCount`: a history row (as long as it was sent) or a
    /// screen row.
    pub fn rowAt(self: *const Grid, i: usize) []const Cell {
        const n = self.historyLen();
        return if (i < n) self.historyRow(i) else self.row(i - n);
    }

    /// A copy for one frame (doc/model.md §2.7) of the screen: what the pane
    /// draws is this, whatever the owner publishes while the frame is built.
    pub fn snapshot(self: *const Grid, arena: Allocator) Allocator.Error!Snapshot {
        return .{ .cols = self.cols, .rows = self.rows, .cells = try arena.dupe(Cell, self.cells), .cursor = self.cursor };
    }

    /// A copy for one frame of rows `[first, first + n)` of history and
    /// screen, each `cols` wide — what a pane READING the entry shows,
    /// scrolled anywhere. Its cursor is none: the caret is the document's.
    pub fn snapshotRows(self: *const Grid, arena: Allocator, first: usize, n: usize) Allocator.Error!Snapshot {
        const total = self.rowCount();
        const from = @min(first, total);
        const count = @min(n, total - from);
        const cells = try arena.alloc(Cell, @as(usize, self.cols) * count);
        @memset(cells, .{ .cp = 0 });
        for (0..count) |i| {
            const src = self.rowAt(from + i);
            const w = @min(src.len, self.cols);
            @memcpy(cells[i * self.cols ..][0..w], src[0..w]);
        }
        return .{ .cols = self.cols, .rows = @intCast(count), .cells = cells, .cursor = .{}, .first_row = from, .reading = true };
    }
};

/// A grid as one frame saw it.
pub const Snapshot = struct {
    cols: u16,
    rows: u16,
    cells: []const Cell,
    cursor: Cursor,
    /// Which of the entry's rows (history then screen) `row(0)` is — its
    /// line in the entry's document, when `reading`.
    first_row: usize = 0,
    /// The pane reads the entry as text: rows are lines of its document,
    /// and the caret and selections are the document's, drawn on cells.
    reading: bool = false,

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
    _ = try g.apply(gpa, m1);
    try t.expectEqual(@as(u32, 'c'), g.row(1)[0].cp);
    try t.expect(g.cursor.visible);
    // Only row 0 changes; row 1 is kept.
    const m2 = try message(gpa, 4, 2, &.{.{ 0, "xy" }});
    defer gpa.free(m2);
    _ = try g.apply(gpa, m2);
    try t.expectEqual(@as(u32, 'x'), g.row(0)[0].cp);
    try t.expectEqual(@as(u32, 'd'), g.row(1)[1].cp);
    // Grow: the old cells stay at their places, the new ones are blank.
    const m3 = try message(gpa, 6, 3, &.{});
    defer gpa.free(m3);
    _ = try g.apply(gpa, m3);
    try t.expectEqual(@as(u32, 'd'), g.row(1)[1].cp);
    try t.expectEqual(@as(u32, 0), g.row(2)[0].cp);
    // A row past the grid is refused whole.
    const bad = try message(gpa, 6, 3, &.{.{ 3, "no" }});
    defer gpa.free(bad);
    try t.expectError(error.Malformed, g.apply(gpa, bad));
}
