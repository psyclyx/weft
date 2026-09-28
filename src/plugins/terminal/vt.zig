//! Vt — one libghostty-vt terminal, and the three things the plugin asks of
//! it: take the child's bytes (`write`), say which rows changed as grid
//! cells (`publish`), and turn a key into the bytes the child should read
//! (`encodeKey`), in whatever mode the child put the terminal in.
//!
//! Everything here runs inside the plugin's sandbox: the emulator is linked
//! into this module, and what leaves it is a `wl_grid_publish` message and
//! the bytes for `wl_pty_write`.

const std = @import("std");
const weft = @import("weft");
const c = @import("c.zig").c;
const keys = @import("keys.zig");

const Cell = weft.grid.Cell;

pub const Vt = struct {
    term: c.GhosttyTerminal,
    render: c.GhosttyRenderState,
    rows_it: c.GhosttyRenderStateRowIterator,
    cells_it: c.GhosttyRenderStateRowCells,
    key_enc: c.GhosttyKeyEncoder,
    key_ev: c.GhosttyKeyEvent,
    mouse_enc: c.GhosttyMouseEncoder,
    mouse_ev: c.GhosttyMouseEvent,
    cols: u16,
    rows: u16,
    cell_w: u16 = 8,
    cell_h: u16 = 16,
    /// Where the emulator's own replies (device attributes, cursor position
    /// reports) go: the pty, once there is one.
    pty: ?u32 = null,
    /// Everything must go out again: a new size, a scroll, a fresh screen.
    all_dirty: bool = true,
    /// How many scrollback rows core holds (the history it was sent), and
    /// the newest of them, tracked as the scrollback moves under it — so
    /// what to send next is exactly the rows that scrolled up past it, and
    /// how many of the oldest the scrollback dropped. Null: core holds none.
    hist_sent: usize = 0,
    hist_mark: c.GhosttyTrackedGridRef = null,
    /// The title changed (OSC 0/2) since it was last published.
    title_dirty: bool = false,

    pub const Error = error{VtUnavailable};

    /// `scrollback` is in lines; ghostty's budget is bytes, at ~1 KiB a line
    /// (as escarghost sizes it).
    pub fn init(self: *Vt, cols: u16, rows: u16, scrollback: usize) Error!void {
        self.* = .{
            .term = undefined,
            .render = undefined,
            .rows_it = undefined,
            .cells_it = undefined,
            .key_enc = undefined,
            .key_ev = undefined,
            .mouse_enc = undefined,
            .mouse_ev = undefined,
            .cols = cols,
            .rows = rows,
        };
        const opts: c.GhosttyTerminalOptions = .{ .cols = cols, .rows = rows, .max_scrollback = scrollback *| 1024 };
        if (c.ghostty_terminal_new(null, &self.term, opts) != c.GHOSTTY_SUCCESS) return error.VtUnavailable;
        errdefer c.ghostty_terminal_free(self.term);
        if (c.ghostty_render_state_new(null, &self.render) != c.GHOSTTY_SUCCESS) return error.VtUnavailable;
        errdefer c.ghostty_render_state_free(self.render);
        if (c.ghostty_render_state_row_iterator_new(null, &self.rows_it) != c.GHOSTTY_SUCCESS) return error.VtUnavailable;
        errdefer c.ghostty_render_state_row_iterator_free(self.rows_it);
        if (c.ghostty_render_state_row_cells_new(null, &self.cells_it) != c.GHOSTTY_SUCCESS) return error.VtUnavailable;
        errdefer c.ghostty_render_state_row_cells_free(self.cells_it);
        if (c.ghostty_key_encoder_new(null, &self.key_enc) != c.GHOSTTY_SUCCESS) return error.VtUnavailable;
        errdefer c.ghostty_key_encoder_free(self.key_enc);
        if (c.ghostty_key_event_new(null, &self.key_ev) != c.GHOSTTY_SUCCESS) return error.VtUnavailable;
        errdefer c.ghostty_key_event_free(self.key_ev);
        if (c.ghostty_mouse_encoder_new(null, &self.mouse_enc) != c.GHOSTTY_SUCCESS) return error.VtUnavailable;
        errdefer c.ghostty_mouse_encoder_free(self.mouse_enc);
        if (c.ghostty_mouse_event_new(null, &self.mouse_ev) != c.GHOSTTY_SUCCESS) return error.VtUnavailable;
        _ = c.ghostty_terminal_set(self.term, c.GHOSTTY_TERMINAL_OPT_USERDATA, @ptrCast(self));
        _ = c.ghostty_terminal_set(self.term, c.GHOSTTY_TERMINAL_OPT_WRITE_PTY, @ptrCast(&writePty));
        _ = c.ghostty_terminal_set(self.term, c.GHOSTTY_TERMINAL_OPT_TITLE_CHANGED, @ptrCast(&titleChanged));
    }

    fn titleChanged(_: c.GhosttyTerminal, userdata: ?*anyopaque) callconv(.c) void {
        const self: *Vt = @ptrCast(@alignCast(userdata orelse return));
        self.title_dirty = true;
    }

    /// The title the program set (OSC 0/2), borrowed until the next write.
    pub fn title(self: *Vt) []const u8 {
        var s: c.GhosttyString = undefined;
        if (c.ghostty_terminal_get(self.term, c.GHOSTTY_TERMINAL_DATA_TITLE, @ptrCast(&s)) != c.GHOSTTY_SUCCESS) return "";
        if (s.ptr == null) return "";
        return s.ptr[0..s.len];
    }

    pub fn deinit(self: *Vt) void {
        if (self.hist_mark != null) c.ghostty_tracked_grid_ref_free(self.hist_mark);
        c.ghostty_mouse_event_free(self.mouse_ev);
        c.ghostty_mouse_encoder_free(self.mouse_enc);
        c.ghostty_key_event_free(self.key_ev);
        c.ghostty_key_encoder_free(self.key_enc);
        c.ghostty_render_state_row_cells_free(self.cells_it);
        c.ghostty_render_state_row_iterator_free(self.rows_it);
        c.ghostty_render_state_free(self.render);
        c.ghostty_terminal_free(self.term);
    }

    /// The emulator answering the child (a DA or DSR query): straight back
    /// down the pty.
    fn writePty(_: c.GhosttyTerminal, userdata: ?*anyopaque, data: [*c]const u8, len: usize) callconv(.c) void {
        const self: *Vt = @ptrCast(@alignCast(userdata orelse return));
        const h = self.pty orelse return;
        if (data == null) return;
        weft.ptyWrite(h, data[0..len]);
    }

    /// Feed the child's output through the emulator.
    pub fn write(self: *Vt, bytes: []const u8) void {
        c.ghostty_terminal_vt_write(self.term, bytes.ptr, bytes.len);
    }

    pub fn resize(self: *Vt, cols: u16, rows: u16, cell_w: u16, cell_h: u16) void {
        if (cols == self.cols and rows == self.rows and cell_w == self.cell_w and cell_h == self.cell_h) return;
        _ = c.ghostty_terminal_resize(self.term, cols, rows, @max(1, cell_w), @max(1, cell_h));
        self.cols = cols;
        self.rows = rows;
        self.cell_w = cell_w;
        self.cell_h = cell_h;
        self.all_dirty = true;
        // The scrollback reflowed: core's copy of it is sent again whole.
        self.forgetHistory();
    }

    /// Move the viewport `delta` rows into (negative) or out of the
    /// scrollback.
    pub fn scroll(self: *Vt, delta: isize) void {
        c.ghostty_terminal_scroll_viewport(self.term, .{ .tag = c.GHOSTTY_SCROLL_VIEWPORT_DELTA, .value = .{ .delta = delta } });
    }

    /// Back to the live screen, as typing does.
    pub fn scrollToBottom(self: *Vt) void {
        c.ghostty_terminal_scroll_viewport(self.term, .{ .tag = c.GHOSTTY_SCROLL_VIEWPORT_BOTTOM, .value = .{ .delta = 0 } });
    }

    fn mode(self: *Vt, value: u16) bool {
        var on: bool = false;
        _ = c.ghostty_terminal_mode_get(self.term, value, &on);
        return on;
    }

    /// The child asked for mouse reports (any of X10/normal/button/any).
    pub fn mouseTracking(self: *Vt) bool {
        return self.mode(9) or self.mode(1000) or self.mode(1002) or self.mode(1003);
    }

    /// The alternate screen is up (a full-screen program: less, vim).
    pub fn altScreen(self: *Vt) bool {
        var screen: c.GhosttyTerminalScreen = c.GHOSTTY_TERMINAL_SCREEN_PRIMARY;
        _ = c.ghostty_terminal_get(self.term, c.GHOSTTY_TERMINAL_DATA_ACTIVE_SCREEN, &screen);
        return screen == c.GHOSTTY_TERMINAL_SCREEN_ALTERNATE;
    }

    pub fn bracketedPaste(self: *Vt) bool {
        return self.mode(2004);
    }

    /// The bytes key `k` sends in the terminal's current modes, into `out`.
    pub fn encodeKey(self: *Vt, k: keys.Key, out: []u8) []const u8 {
        c.ghostty_key_encoder_setopt_from_terminal(self.key_enc, self.term);
        c.ghostty_key_event_set_action(self.key_ev, c.GHOSTTY_KEY_ACTION_PRESS);
        c.ghostty_key_event_set_key(self.key_ev, k.key);
        c.ghostty_key_event_set_mods(self.key_ev, k.mods);
        c.ghostty_key_event_set_consumed_mods(self.key_ev, k.consumed);
        c.ghostty_key_event_set_composing(self.key_ev, false);
        c.ghostty_key_event_set_utf8(self.key_ev, if (k.text.len > 0) k.text.ptr else null, k.text.len);
        c.ghostty_key_event_set_unshifted_codepoint(self.key_ev, k.unshifted);
        var n: usize = 0;
        if (c.ghostty_key_encoder_encode(self.key_enc, self.key_ev, out.ptr, out.len, &n) != c.GHOSTTY_SUCCESS) return out[0..0];
        return out[0..n];
    }

    /// A wheel notch as the mouse report the child asked for, at cell
    /// (`col`, `row`); empty when it asked for none.
    pub fn encodeWheel(self: *Vt, up: bool, col: u16, row: u16, out: []u8) []const u8 {
        c.ghostty_mouse_encoder_setopt_from_terminal(self.mouse_enc, self.term);
        const size: c.GhosttyMouseEncoderSize = .{
            .size = @sizeOf(c.GhosttyMouseEncoderSize),
            .screen_width = @as(u32, self.cols) * @max(1, self.cell_w),
            .screen_height = @as(u32, self.rows) * @max(1, self.cell_h),
            .cell_width = @max(1, self.cell_w),
            .cell_height = @max(1, self.cell_h),
            .padding_top = 0,
            .padding_bottom = 0,
            .padding_right = 0,
            .padding_left = 0,
        };
        c.ghostty_mouse_encoder_setopt(self.mouse_enc, c.GHOSTTY_MOUSE_ENCODER_OPT_SIZE, &size);
        c.ghostty_mouse_event_set_action(self.mouse_ev, c.GHOSTTY_MOUSE_ACTION_PRESS);
        c.ghostty_mouse_event_set_button(self.mouse_ev, if (up) c.GHOSTTY_MOUSE_BUTTON_FOUR else c.GHOSTTY_MOUSE_BUTTON_FIVE);
        c.ghostty_mouse_event_set_mods(self.mouse_ev, 0);
        c.ghostty_mouse_event_set_position(self.mouse_ev, .{
            .x = (@as(f32, @floatFromInt(col)) + 0.5) * @as(f32, @floatFromInt(@max(1, self.cell_w))),
            .y = (@as(f32, @floatFromInt(row)) + 0.5) * @as(f32, @floatFromInt(@max(1, self.cell_h))),
        });
        var n: usize = 0;
        if (c.ghostty_mouse_encoder_encode(self.mouse_enc, self.mouse_ev, out.ptr, out.len, &n) != c.GHOSTTY_SUCCESS) return out[0..0];
        return out[0..n];
    }

    /// `text` as a paste: unsafe control bytes stripped, and bracketed when
    /// the child asked for bracketed paste. Into `out`; empty when it does
    /// not fit.
    pub fn encodePaste(self: *Vt, text: []u8, out: []u8) []const u8 {
        var n: usize = 0;
        if (c.ghostty_paste_encode(text.ptr, text.len, self.bracketedPaste(), out.ptr, out.len, &n) != c.GHOSTTY_SUCCESS) return out[0..0];
        return out[0..n];
    }

    /// Where the cursor is, on the viewport.
    pub fn cursorCell(self: *Vt) struct { col: u16, row: u16 } {
        var x: u16 = 0;
        var y: u16 = 0;
        _ = c.ghostty_terminal_get(self.term, c.GHOSTTY_TERMINAL_DATA_CURSOR_X, &x);
        _ = c.ghostty_terminal_get(self.term, c.GHOSTTY_TERMINAL_DATA_CURSOR_Y, &y);
        return .{ .col = x, .row = y };
    }

    /// Publish what changed since the last publish into grid entry `name`:
    /// the dirty rows (all of them after a resize or scroll) and the cursor
    /// — and, while the pane READS the entry (`reading`), the rows that
    /// scrolled up into the scrollback since core last heard (a history
    /// section), and a new title. Nothing when nothing changed. `msg` is
    /// scratch the message is built in, grown as needed.
    pub fn publish(self: *Vt, name: []const u8, msg: *std.ArrayList(u8), reading: bool) void {
        var hist: std.ArrayList(u8) = .empty;
        defer hist.deinit(weft.allocator);
        // Read, the screen is the live one, whatever S-Prior scrolled to.
        if (reading) self.scrollToBottom();
        const history = reading and !self.altScreen() and (self.historyDelta(&hist) catch false);
        if (c.ghostty_render_state_update(self.render, self.term) != c.GHOSTTY_SUCCESS) return;
        var dirty: c.GhosttyRenderStateDirty = c.GHOSTTY_RENDER_STATE_DIRTY_FALSE;
        _ = c.ghostty_render_state_get(self.render, c.GHOSTTY_RENDER_STATE_DATA_DIRTY, &dirty);
        if (dirty == c.GHOSTTY_RENDER_STATE_DIRTY_FALSE and !self.all_dirty and !history and !self.title_dirty) return;
        const all = self.all_dirty or dirty == c.GHOSTTY_RENDER_STATE_DIRTY_FULL;
        self.all_dirty = false;

        var cols: u16 = 0;
        var rows: u16 = 0;
        _ = c.ghostty_render_state_get(self.render, c.GHOSTTY_RENDER_STATE_DATA_COLS, &cols);
        _ = c.ghostty_render_state_get(self.render, c.GHOSTTY_RENDER_STATE_DATA_ROWS, &rows);
        msg.clearRetainingCapacity();
        msg.ensureTotalCapacity(weft.allocator, weft.grid.messageLen(cols, rows)) catch return;
        msg.items.len = @sizeOf(weft.grid.Header);

        var sent: u32 = 0;
        _ = c.ghostty_render_state_get(self.render, c.GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR, @ptrCast(&self.rows_it));
        var y: u32 = 0;
        const no: bool = false;
        while (c.ghostty_render_state_row_iterator_next(self.rows_it)) : (y += 1) {
            var row_dirty: bool = true;
            _ = c.ghostty_render_state_row_get(self.rows_it, c.GHOSTTY_RENDER_STATE_ROW_DATA_DIRTY, @ptrCast(&row_dirty));
            _ = c.ghostty_render_state_row_set(self.rows_it, c.GHOSTTY_RENDER_STATE_ROW_OPTION_DIRTY, @ptrCast(&no));
            if (!(all or row_dirty) or y >= rows) continue;
            var index: [4]u8 = undefined;
            std.mem.writeInt(u32, &index, y, .little);
            msg.appendSliceAssumeCapacity(&index);
            _ = c.ghostty_render_state_row_get(self.rows_it, c.GHOSTTY_RENDER_STATE_ROW_DATA_CELLS, @ptrCast(&self.cells_it));
            var x: u16 = 0;
            while (x < cols) : (x += 1) {
                const cell: Cell = if (c.ghostty_render_state_row_cells_next(self.cells_it)) self.cellHere() else .{};
                msg.appendSliceAssumeCapacity(std.mem.asBytes(&cell));
            }
            sent += 1;
        }
        var clean: c.GhosttyRenderStateDirty = c.GHOSTTY_RENDER_STATE_DIRTY_FALSE;
        _ = c.ghostty_render_state_set(self.render, c.GHOSTTY_RENDER_STATE_OPTION_DIRTY, @ptrCast(&clean));

        const cur = self.cursor();
        const header: weft.grid.Header = .{
            .cols = cols,
            .rows = rows,
            .cursor_x = cur.x,
            .cursor_y = cur.y,
            .cursor_shape = cur.shape,
            .flags = if (cur.visible) weft.grid.Header.cursor_visible else 0,
            .rows_sent = sent,
        };
        @memcpy(msg.items[0..@sizeOf(weft.grid.Header)], std.mem.asBytes(&header));
        if (history) weft.grid.appendSection(msg, weft.allocator, .history, hist.items) catch return;
        if (self.title_dirty) {
            weft.grid.appendSection(msg, weft.allocator, .title, self.title()) catch return;
            self.title_dirty = false;
        }
        _ = weft.gridPublish(name, msg.items);
    }

    /// The history section's payload into `out`, when core's copy of the
    /// scrollback is behind: the rows the scrollback dropped from its front,
    /// and the rows that scrolled up past the newest one core holds — or,
    /// when that one can no longer be found (a clear, a resize), all of it
    /// again. False when core is up to date.
    fn historyDelta(self: *Vt, out: *std.ArrayList(u8)) !bool {
        var n: usize = 0;
        _ = c.ghostty_terminal_get(self.term, c.GHOSTTY_TERMINAL_DATA_SCROLLBACK_ROWS, @ptrCast(&n));
        var head: weft.grid.HistoryHead = .{};
        var from: usize = 0;
        find: {
            if (self.hist_mark == null) break :find;
            var at: c.GhosttyPointCoordinate = undefined;
            if (c.ghostty_tracked_grid_ref_point(self.hist_mark, c.GHOSTTY_POINT_TAG_HISTORY, &at) != c.GHOSTTY_SUCCESS) break :find;
            const y: usize = at.y;
            if (y + 1 > self.hist_sent or y + 1 > n) break :find;
            head.dropped = @intCast(self.hist_sent - (y + 1));
            from = y + 1;
        }
        if (self.hist_mark == null or (from == 0 and self.hist_sent > 0)) head.flags = weft.grid.HistoryHead.reset;
        const count = n - @min(n, from);
        if (head.flags == 0 and count == 0 and head.dropped == 0) return false;
        head.count = @intCast(count);
        try out.appendSlice(weft.allocator, std.mem.asBytes(&head));
        try self.readHistory(from, count, out);
        // The newest row core now holds is the one to find next time.
        if (n > 0) {
            const point: c.GhosttyPoint = .{ .tag = c.GHOSTTY_POINT_TAG_HISTORY, .value = .{ .coordinate = .{ .x = 0, .y = @intCast(n - 1) } } };
            const ok = if (self.hist_mark == null)
                c.ghostty_terminal_grid_ref_track(self.term, point, &self.hist_mark)
            else
                c.ghostty_tracked_grid_ref_set(self.hist_mark, self.term, point);
            if (ok != c.GHOSTTY_SUCCESS) self.forgetHistory();
        } else self.forgetHistory();
        self.hist_sent = n;
        return true;
    }

    /// Core's history is to be sent whole next time.
    pub fn forgetHistory(self: *Vt) void {
        if (self.hist_mark != null) c.ghostty_tracked_grid_ref_free(self.hist_mark);
        self.hist_mark = null;
    }

    /// Scrollback rows `[from, from + count)` into `out`, each its cells with
    /// the trailing blanks trimmed: read a viewport at a time through the
    /// render state (colours resolved as the screen's are), then the
    /// viewport goes back to the live screen, which is sent whole next.
    fn readHistory(self: *Vt, from: usize, count: usize, out: *std.ArrayList(u8)) !void {
        defer {
            self.scrollToBottom();
            self.all_dirty = true;
        }
        var row_cells: std.ArrayList(Cell) = .empty;
        defer row_cells.deinit(weft.allocator);
        var got: usize = 0;
        while (got < count) {
            c.ghostty_terminal_scroll_viewport(self.term, .{ .tag = c.GHOSTTY_SCROLL_VIEWPORT_ROW, .value = .{ .row = from + got } });
            if (c.ghostty_render_state_update(self.render, self.term) != c.GHOSTTY_SUCCESS) return error.VtUnavailable;
            var cols: u16 = 0;
            _ = c.ghostty_render_state_get(self.render, c.GHOSTTY_RENDER_STATE_DATA_COLS, &cols);
            _ = c.ghostty_render_state_get(self.render, c.GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR, @ptrCast(&self.rows_it));
            const take = @min(@as(usize, self.rows), count - got);
            var y: usize = 0;
            while (y < take and c.ghostty_render_state_row_iterator_next(self.rows_it)) : (y += 1) {
                _ = c.ghostty_render_state_row_get(self.rows_it, c.GHOSTTY_RENDER_STATE_ROW_DATA_CELLS, @ptrCast(&self.cells_it));
                row_cells.clearRetainingCapacity();
                var x: u16 = 0;
                while (x < cols) : (x += 1) {
                    try row_cells.append(weft.allocator, if (c.ghostty_render_state_row_cells_next(self.cells_it)) self.cellHere() else .{});
                }
                var len = row_cells.items.len;
                while (len > 0 and blank(row_cells.items[len - 1])) len -= 1;
                try weft.grid.appendHistoryRow(out, weft.allocator, row_cells.items[0..len]);
            }
            if (y == 0) return error.VtUnavailable; // the viewport would not move
            got += y;
        }
    }

    fn blank(cell: Cell) bool {
        return cell.cp == 0 and cell.bg == Cell.theme_bg and @as(u16, @bitCast(cell.attrs)) == 0 and @as(u8, @bitCast(cell.mark)) == 0;
    }

    /// The cell the row-cells iterator is on, as the grid wire says it.
    fn cellHere(self: *Vt) Cell {
        var out: Cell = .{};
        var raw: c.GhosttyCell = 0;
        _ = c.ghostty_render_state_row_cells_get(self.cells_it, c.GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_RAW, @ptrCast(&raw));
        var wide: c.GhosttyCellWide = c.GHOSTTY_CELL_WIDE_NARROW;
        _ = c.ghostty_cell_get(raw, c.GHOSTTY_CELL_DATA_WIDE, @ptrCast(&wide));
        out.width = switch (wide) {
            c.GHOSTTY_CELL_WIDE_WIDE => 2,
            c.GHOSTTY_CELL_WIDE_SPACER_TAIL => 0,
            else => 1,
        };
        var len: u32 = 0;
        _ = c.ghostty_render_state_row_cells_get(self.cells_it, c.GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_LEN, @ptrCast(&len));
        if (len > 0) {
            var cps: [16]u32 = undefined;
            if (len <= cps.len) {
                _ = c.ghostty_render_state_row_cells_get(self.cells_it, c.GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_BUF, @ptrCast(&cps));
                out.cp = cps[0];
            } else out.cp = 0xfffd;
        }
        var rgb: c.GhosttyColorRgb = undefined;
        if (c.ghostty_render_state_row_cells_get(self.cells_it, c.GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_BG_COLOR, @ptrCast(&rgb)) == c.GHOSTTY_SUCCESS)
            out.bg = pack(rgb);
        var styled: bool = false;
        _ = c.ghostty_render_state_row_cells_get(self.cells_it, c.GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_HAS_STYLING, @ptrCast(&styled));
        if (!styled) return out;
        if (c.ghostty_render_state_row_cells_get(self.cells_it, c.GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_FG_COLOR, @ptrCast(&rgb)) == c.GHOSTTY_SUCCESS)
            out.fg = pack(rgb);
        var style: c.GhosttyStyle = undefined;
        style.size = @sizeOf(c.GhosttyStyle);
        if (c.ghostty_render_state_row_cells_get(self.cells_it, c.GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_STYLE, @ptrCast(&style)) != c.GHOSTTY_SUCCESS) return out;
        out.attrs = .{
            .bold = style.bold,
            .italic = style.italic,
            .faint = style.faint,
            .strikethrough = style.strikethrough,
            .overline = style.overline,
            .invisible = style.invisible,
            .underline = std.enums.fromInt(weft.grid.Underline, style.underline) orelse .single,
        };
        // Reverse video swaps the colours the cell would have had — the
        // theme's own when it named none.
        if (style.inverse) std.mem.swap(u32, &out.fg, &out.bg);
        return out;
    }

    fn pack(rgb: c.GhosttyColorRgb) u32 {
        return (@as(u32, rgb.r) << 16) | (@as(u32, rgb.g) << 8) | rgb.b;
    }

    const Cursor = struct { x: u16, y: u16, shape: weft.grid.CursorShape, visible: bool };

    fn cursor(self: *Vt) Cursor {
        var visible: bool = false;
        var in_view: bool = false;
        var x: u16 = 0;
        var y: u16 = 0;
        var style: c.GhosttyRenderStateCursorVisualStyle = c.GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BLOCK;
        _ = c.ghostty_render_state_get(self.render, c.GHOSTTY_RENDER_STATE_DATA_CURSOR_VISIBLE, @ptrCast(&visible));
        _ = c.ghostty_render_state_get(self.render, c.GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_HAS_VALUE, @ptrCast(&in_view));
        _ = c.ghostty_render_state_get(self.render, c.GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_X, @ptrCast(&x));
        _ = c.ghostty_render_state_get(self.render, c.GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_Y, @ptrCast(&y));
        _ = c.ghostty_render_state_get(self.render, c.GHOSTTY_RENDER_STATE_DATA_CURSOR_VISUAL_STYLE, @ptrCast(&style));
        return .{
            .x = x,
            .y = y,
            .visible = visible and in_view,
            .shape = switch (style) {
                c.GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BAR => .bar,
                c.GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_UNDERLINE => .underline,
                c.GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BLOCK_HOLLOW => .hollow,
                else => .block,
            },
        };
    }
};
