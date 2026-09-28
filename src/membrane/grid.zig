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
    /// What the cell IS, when the program said (a shell's OSC 133 marks):
    /// part of a prompt, part of a typed command line, or neither (output).
    mark: Mark = .{},

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

/// A cell's part in a shell's conversation, as the program marked it.
pub const Mark = packed struct(u8) {
    /// The shell's prompt.
    prompt: bool = false,
    /// A command line being (or that was) typed at a prompt.
    input: bool = false,
    _pad: u6 = 0,
};

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

// ── Sections ────────────────────────────────────────────────────────
//
// After the rows, a publish may carry SECTIONS: what else the grid's owner
// says about the entry, each framed by a `SectionHead` (its tag and length)
// and read only by tag, so a reader skips what it does not know. The screen
// is the rows; everything past the screen is a section.

pub const Tag = enum(u8) {
    /// What the entry is called for now (a terminal's OSC 0/2 title): UTF-8,
    /// one line. An empty one clears it.
    title = 1,
    /// Rows above the screen (a terminal's scrollback): `HistoryHead`, then
    /// `count` rows, each a little-endian `u32` cell count and its cells.
    history = 2,
    _,
};

pub const SectionHead = extern struct {
    tag: Tag,
    _pad: [3]u8 = .{ 0, 0, 0 },
    /// Bytes that follow.
    len: u32,
};

/// A history section's head. `dropped` rows go from the FRONT of the history
/// first (the oldest, past the owner's scrollback), then `count` rows are
/// appended after the newest — the rows that scrolled off the top of the
/// screen since the last history said. `reset` drops the whole history first.
pub const HistoryHead = extern struct {
    dropped: u32 = 0,
    count: u32 = 0,
    flags: u32 = 0,
    _pad: u32 = 0,

    pub const reset: u32 = 1;
};

comptime {
    std.debug.assert(@sizeOf(SectionHead) == 8);
    std.debug.assert(@sizeOf(HistoryHead) == 16);
}

/// The most rows one history section may carry.
pub const max_history_rows = 1 << 20;

/// Append a section tagged `tag` holding `payload` to a message being built.
pub fn appendSection(list: *std.ArrayList(u8), gpa: std.mem.Allocator, tag: Tag, payload: []const u8) std.mem.Allocator.Error!void {
    const head: SectionHead = .{ .tag = tag, .len = @intCast(payload.len) };
    try list.appendSlice(gpa, std.mem.asBytes(&head));
    try list.appendSlice(gpa, payload);
}

pub const Section = struct { tag: Tag, bytes: []const u8 };

pub const Sections = struct {
    rest: []const u8,

    pub fn next(self: *Sections) ?Section {
        if (self.rest.len < @sizeOf(SectionHead)) return null;
        const head = std.mem.bytesToValue(SectionHead, self.rest[0..@sizeOf(SectionHead)]);
        const body = self.rest[@sizeOf(SectionHead)..][0..head.len];
        self.rest = self.rest[@sizeOf(SectionHead) + head.len ..];
        return .{ .tag = head.tag, .bytes = body };
    }
};

/// A history section, read in place and checked whole before anything is
/// trusted.
pub const History = struct {
    head: HistoryHead,
    rows: []const u8,

    pub fn parse(bytes: []const u8) DecodeError!History {
        if (bytes.len < @sizeOf(HistoryHead)) return error.Malformed;
        const head = std.mem.bytesToValue(HistoryHead, bytes[0..@sizeOf(HistoryHead)]);
        if (head.count > max_history_rows) return error.Malformed;
        const rows = bytes[@sizeOf(HistoryHead)..];
        var it: RowIterator = .{ .rest = rows };
        var n: usize = 0;
        while (n < head.count) : (n += 1) _ = try it.next() orelse return error.Malformed;
        if (it.rest.len != 0) return error.Malformed;
        return .{ .head = head, .rows = rows };
    }

    pub fn iterator(self: History) RowIterator {
        return .{ .rest = self.rows };
    }
};

/// Rows of a history section: each one's cells, as bytes (unaligned: copy
/// them out, never cast).
pub const RowIterator = struct {
    rest: []const u8,

    pub fn next(self: *RowIterator) DecodeError!?[]const u8 {
        if (self.rest.len == 0) return null;
        if (self.rest.len < 4) return error.Malformed;
        const n = std.mem.readInt(u32, self.rest[0..4], .little);
        if (n > max_cells) return error.Malformed;
        const len = @as(usize, n) * @sizeOf(Cell);
        if (self.rest.len - 4 < len) return error.Malformed;
        const cells = self.rest[4..][0..len];
        self.rest = self.rest[4 + len ..];
        return cells;
    }
};

/// Append one history row (its cells, trailing blanks already trimmed by
/// the caller if it likes) to a history payload being built.
pub fn appendHistoryRow(list: *std.ArrayList(u8), gpa: std.mem.Allocator, cells: []const Cell) std.mem.Allocator.Error!void {
    var n: [4]u8 = undefined;
    std.mem.writeInt(u32, &n, @intCast(cells.len), .little);
    try list.appendSlice(gpa, &n);
    try list.appendSlice(gpa, std.mem.sliceAsBytes(cells));
}

/// A publish, read in place: the header and each row's cells, checked
/// against the message's length before anything is trusted — and its
/// sections, framed.
pub const Message = struct {
    header: Header,
    body: []const u8,
    /// The section bytes after the rows.
    extra: []const u8 = &.{},

    pub fn parse(bytes: []const u8) DecodeError!Message {
        if (bytes.len < @sizeOf(Header)) return error.Malformed;
        const h = std.mem.bytesToValue(Header, bytes[0..@sizeOf(Header)]);
        if (@as(usize, h.cols) * h.rows > max_cells) return error.Malformed;
        if (h.rows_sent > h.rows) return error.Malformed;
        const len = messageLen(h.cols, h.rows_sent);
        if (bytes.len < len) return error.Malformed;
        // Every section framed within the message, to its last byte.
        var rest = bytes[len..];
        while (rest.len > 0) {
            if (rest.len < @sizeOf(SectionHead)) return error.Malformed;
            const head = std.mem.bytesToValue(SectionHead, rest[0..@sizeOf(SectionHead)]);
            if (rest.len - @sizeOf(SectionHead) < head.len) return error.Malformed;
            rest = rest[@sizeOf(SectionHead) + head.len ..];
        }
        return .{ .header = h, .body = bytes[@sizeOf(Header)..len], .extra = bytes[len..] };
    }

    /// The `i`-th row sent: its index and its cells (unaligned: copy them
    /// out, never cast).
    pub fn row(self: Message, i: usize) struct { index: u32, cells: []const u8 } {
        const stride = 4 + @as(usize, self.header.cols) * @sizeOf(Cell);
        const at = self.body[i * stride ..][0..stride];
        return .{ .index = std.mem.readInt(u32, at[0..4], .little), .cells = at[4..] };
    }

    pub fn sections(self: Message) Sections {
        return .{ .rest = self.extra };
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

test "grid wire: sections follow the rows, framed, and a reader finds them by tag" {
    const gpa = std.testing.allocator;
    var msg: std.ArrayList(u8) = .empty;
    defer msg.deinit(gpa);
    const h: Header = .{ .cols = 2, .rows = 1 };
    try msg.appendSlice(gpa, std.mem.asBytes(&h));
    try appendSection(&msg, gpa, .title, "~/src");
    var hist: std.ArrayList(u8) = .empty;
    defer hist.deinit(gpa);
    const head: HistoryHead = .{ .dropped = 1, .count = 2 };
    try hist.appendSlice(gpa, std.mem.asBytes(&head));
    try appendHistoryRow(&hist, gpa, &.{ .{ .cp = 'a' }, .{ .cp = 'b', .mark = .{ .prompt = true } } });
    try appendHistoryRow(&hist, gpa, &.{});
    try appendSection(&msg, gpa, .history, hist.items);

    const m = try Message.parse(msg.items);
    var it = m.sections();
    const title = it.next().?;
    try std.testing.expectEqual(Tag.title, title.tag);
    try std.testing.expectEqualStrings("~/src", title.bytes);
    const history = it.next().?;
    const parsed = try History.parse(history.bytes);
    try std.testing.expectEqual(@as(u32, 1), parsed.head.dropped);
    var rows = parsed.iterator();
    const first = (try rows.next()).?;
    try std.testing.expectEqual(@as(usize, 2 * @sizeOf(Cell)), first.len);
    try std.testing.expect(std.mem.bytesToValue(Cell, first[16..32]).mark.prompt);
    try std.testing.expectEqual(@as(usize, 0), (try rows.next()).?.len);
    try std.testing.expectEqual(@as(?[]const u8, null), try rows.next());
    try std.testing.expectEqual(@as(?Section, null), it.next());
    // A section cut short, or a history that says more rows than it holds,
    // is refused whole.
    try std.testing.expectError(error.Malformed, Message.parse(msg.items[0 .. msg.items.len - 1]));
    var short = head;
    short.count = 3;
    @memcpy(hist.items[0..@sizeOf(HistoryHead)], std.mem.asBytes(&short));
    try std.testing.expectError(error.Malformed, History.parse(hist.items));
}
