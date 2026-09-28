//! The cell-grid wire (`wl_grid_publish`, doc/terminal.md §3): what a plugin
//! says about a grid entry's rows, in the one layout both sides compile.
//!
//! A grid is rows × cols of `Cell`s plus a cursor. A publish carries a
//! `Header` and then `rows_sent` rows, each a little-endian `u32` row index
//! followed by exactly `cols` cells — only the rows that changed, so a
//! terminal whose prompt line moved republishes that line, not the screen.
//! A header whose size differs from the grid's resizes it (every row blank
//! until sent).
//!
//! Colours are raw RGB, chosen by the plugin: this is the one render door
//! where they are. A grid IS pixels-by-cell — a terminal's 256-colour and
//! truecolor output has no theme role to map onto — and two values name the
//! theme's own foreground and background, so a terminal that prints plain
//! text looks like every other pane, and one in reverse video swaps the
//! theme's colours rather than guessing at them.

const std = @import("std");

/// One cell. 16 bytes, little-endian, no padding the two sides could read
/// differently.
pub const Cell = extern struct {
    /// The cell's first scalar; 0 is an empty cell (drawn as its background).
    cp: u32 = 0,
    /// `0x00RRGGBB`, `theme_fg` or `theme_bg`.
    fg: u32 = theme_fg,
    /// `0x00RRGGBB`, `theme_fg`, or `theme_bg` — which is no background of
    /// the cell's own: the pane's shows.
    bg: u32 = theme_bg,
    attrs: Attrs = .{},
    /// 1 for an ordinary cell, 2 for the first half of a wide character, 0
    /// for the second half (nothing is drawn there; the first half covers it).
    width: u8 = 1,
    _pad: u8 = 0,

    /// The theme's foreground.
    pub const theme_fg: u32 = 0xff00_0001;
    /// The theme's background.
    pub const theme_bg: u32 = 0xff00_0002;

    /// A colour that is RGB, as its three bytes; null for a theme value.
    pub fn rgb(c: u32) ?[3]u8 {
        if (c & 0xff00_0000 != 0) return null;
        return .{ @truncate(c >> 16), @truncate(c >> 8), @truncate(c) };
    }
};

/// How a cell's glyph is drawn. Inverse is the plugin's to resolve (it
/// knows the colours it swapped); what reaches the grid is already the
/// colours to draw.
pub const Attrs = packed struct(u16) {
    bold: bool = false,
    italic: bool = false,
    faint: bool = false,
    underline: Underline = .none,
    strikethrough: bool = false,
    overline: bool = false,
    invisible: bool = false,
    _pad: u7 = 0,
};

pub const Underline = enum(u3) { none, single, double, curly, dotted, dashed };

pub const CursorShape = enum(u8) { block, bar, underline, hollow };

/// A publish's first 16 bytes.
pub const Header = extern struct {
    cols: u16,
    rows: u16,
    cursor_x: u16 = 0,
    cursor_y: u16 = 0,
    cursor_shape: CursorShape = .block,
    /// Bit 0: the cursor is shown.
    flags: u8 = 0,
    _pad: u16 = 0,
    /// Rows that follow.
    rows_sent: u32 = 0,

    pub const cursor_visible: u8 = 1;
};

comptime {
    std.debug.assert(@sizeOf(Cell) == 16);
    std.debug.assert(@sizeOf(Header) == 16);
}

/// The most cells a grid may hold — a guard against a publish sizing a grid
/// to the whole address space, far past any screen.
pub const max_cells = 1 << 20;

/// Bytes a publish of `rows_sent` rows `cols` wide takes.
pub fn messageLen(cols: usize, rows_sent: usize) usize {
    return @sizeOf(Header) + rows_sent * (4 + cols * @sizeOf(Cell));
}

pub const DecodeError = error{Malformed};

/// A publish, read in place: the header and each row's cells, checked
/// against the message's length before anything is trusted.
pub const Message = struct {
    header: Header,
    body: []const u8,

    pub fn parse(bytes: []const u8) DecodeError!Message {
        if (bytes.len < @sizeOf(Header)) return error.Malformed;
        const h = std.mem.bytesToValue(Header, bytes[0..@sizeOf(Header)]);
        if (@as(usize, h.cols) * h.rows > max_cells) return error.Malformed;
        if (h.rows_sent > h.rows) return error.Malformed;
        if (bytes.len != messageLen(h.cols, h.rows_sent)) return error.Malformed;
        return .{ .header = h, .body = bytes[@sizeOf(Header)..] };
    }

    /// The `i`-th row sent: its index and its cells (unaligned: copy them
    /// out, never cast).
    pub fn row(self: Message, i: usize) struct { index: u32, cells: []const u8 } {
        const stride = 4 + @as(usize, self.header.cols) * @sizeOf(Cell);
        const at = self.body[i * stride ..][0..stride];
        return .{ .index = std.mem.readInt(u32, at[0..4], .little), .cells = at[4..] };
    }
};

test "grid wire: a message round-trips and a short one is refused" {
    var buf: [messageLen(2, 1)]u8 = undefined;
    const h: Header = .{ .cols = 2, .rows = 3, .cursor_x = 1, .flags = Header.cursor_visible, .rows_sent = 1 };
    @memcpy(buf[0..16], std.mem.asBytes(&h));
    std.mem.writeInt(u32, buf[16..20], 2, .little);
    const cells = [2]Cell{ .{ .cp = 'h', .fg = 0x00ff0000, .attrs = .{ .bold = true } }, .{ .cp = 'i' } };
    @memcpy(buf[20..], std.mem.sliceAsBytes(&cells));
    const m = try Message.parse(&buf);
    try std.testing.expectEqual(@as(u16, 3), m.header.rows);
    const r = m.row(0);
    try std.testing.expectEqual(@as(u32, 2), r.index);
    const first = std.mem.bytesToValue(Cell, r.cells[0..16]);
    try std.testing.expectEqual(@as(u32, 'h'), first.cp);
    try std.testing.expect(first.attrs.bold);
    try std.testing.expectEqual([3]u8{ 0xff, 0, 0 }, Cell.rgb(first.fg).?);
    try std.testing.expectEqual(@as(?[3]u8, null), Cell.rgb(Cell.theme_fg));
    try std.testing.expectError(error.Malformed, Message.parse(buf[0 .. buf.len - 1]));
}
