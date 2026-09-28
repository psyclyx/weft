//! grid_mirror — a grid entry's cells as a READ-ONLY text document, kept in
//! step with the grid (doc/terminal.md §4), so the text machinery works on a
//! terminal unchanged: motions, search, snipe, visual selection, yank, the
//! pointer's drag-select and copy. The grid's rows (its history, then its
//! screen) are the document's text, a LOGICAL line a document line — a row
//! that soft-wraps runs on into the next — and at a shell's prompt the
//! command line is the shell's buffer, flowed over the rows its echo takes.
//! Where each row's text is goes in the row map (`Grid.Map`), so an offset
//! names a cell and the view draws the document's caret and selections ON
//! the cells (`gfx/view/grid.zig`).
//!
//! The document is written only while the entry is READ — not capturing:
//! while a program takes every key nobody moves a caret through its output,
//! and a flood is not copied twice. Reading again brings it up to date:
//! once when capture is left (`enterReading`), then with every publish.
//!
//! Every write is core's own, as a producer (`Document.produce`, lean and
//! straight on the replica): never the user's undo, and minimal — the rows that
//! scrolled away from the front are cut, the rows that scrolled up are
//! appended, and only the part of the screen that changed is replaced, so a
//! caret or a selection in the scrollback holds still under new output.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Buffers = @import("Buffers.zig");
const Editor = @import("Editor.zig");
const Document = @import("Document.zig");
const grid_mod = @import("grid.zig");

const Grid = grid_mod.Grid;

/// Why a grid entry's text refuses edits: it is what the program printed.
pub const read_only = "terminal output: produced by the program";

/// Give `b` — an entry holding a grid — its document if it has none.
pub fn ensureDocument(gpa: Allocator, buffers: *Buffers, b: *Buffers.Buffer) Allocator.Error!*Editor {
    if (b.editor == null) {
        b.editor = try Editor.init(gpa, buffers.pool, buffers.user_agent);
        if (b.read_only == null) b.read_only = read_only;
    }
    return &b.editor.?;
}

/// Bring `b`'s document up to its grid's rows, and the map of where each
/// row's text is in it (`Grid.Map`).
pub fn sync(gpa: Allocator, buffers: *Buffers, b: *Buffers.Buffer) !void {
    const ed = try ensureDocument(gpa, buffers, b);
    try syncTo(gpa, b, ed);
}

/// A row's text and its break, into `out`: the break is a newline, unless
/// the row soft-wraps (its line goes on) or it is the last.
fn appendRow(gpa: Allocator, out: *std.ArrayList(u8), cells: []const grid_mod.Cell, wraps: bool) !void {
    try grid_mod.appendRowText(gpa, out, cells, wraps);
    if (!wraps) try out.append(gpa, '\n');
}

/// Collects the rows a command line flows over (`grid.flowText`).
const FlowRows = struct {
    gpa: Allocator,
    spans: *std.ArrayList(Grid.RowText),
    /// Where the row the line starts on starts, and the line itself.
    row_start: usize,
    field_start: usize,

    fn row(self: *FlowRows, s: usize, e: usize, col: u16) !void {
        const first = self.spans.items.len == 0;
        try self.spans.append(self.gpa, .{
            .start = if (first) self.row_start else self.field_start + s,
            .end = self.field_start + e,
            .flow_start = self.field_start + s,
            .flow_col = col,
        });
    }
};

fn syncTo(gpa: Allocator, b: *Buffers.Buffer, ed: *Editor) !void {
    const g = b.grid orelse return;
    const rope = ed.text();
    const map = &g.map;
    const new_start = g.history_start;
    const new_end = g.history_start + g.historyLen();

    var reps: [2]Document.Replacement = undefined;
    var n: usize = 0;
    var tail: std.ArrayList(u8) = .empty;
    defer tail.deinit(gpa);
    var old_tail: std.ArrayList(u8) = .empty;
    defer old_tail.deinit(gpa);

    // Where the document's history rows are still this grid's.
    const incremental = if (g.mirror) |m|
        m.start <= new_start and new_start <= m.end and m.end <= new_end and map.hist_bytes.items.len == m.end - m.start
    else
        false;
    var tail_from: usize = 0; // old-document offset the tail replaces from
    var history_from: u64 = new_start; // first history row the tail writes
    if (incremental) {
        const m = g.mirror.?;
        tail_from = map.hist_total;
        // The rows that went from the front.
        const gone: usize = @intCast(new_start - m.start);
        if (gone > 0) {
            var cut: usize = 0;
            for (map.hist_bytes.items[0..gone]) |x| cut += x;
            reps[n] = .{ .range = .{ .start = 0, .end = cut }, .bytes = "" };
            n += 1;
            const kept = map.hist_bytes.items.len - gone;
            std.mem.copyForwards(u32, map.hist_bytes.items[0..kept], map.hist_bytes.items[gone..]);
            map.hist_bytes.shrinkRetainingCapacity(kept);
            map.hist_total -= cut;
        }
        history_from = m.end;
    } else {
        map.hist_bytes.clearRetainingCapacity();
        map.hist_total = 0;
    }
    // The tail: history rows the document lacks, then the screen.
    try map.hist_bytes.ensureUnusedCapacity(gpa, g.historyLen());
    for (@intCast(history_from - new_start)..g.historyLen()) |i| {
        const before = tail.items.len;
        try appendRow(gpa, &tail, g.historyRow(i), g.rowWraps(i));
        const bytes: u32 = @intCast(tail.items.len - before);
        map.hist_bytes.appendAssumeCapacity(bytes);
        map.hist_total += bytes;
    }
    // The screen, each row where its text lands. Offsets are the NEW
    // document's: the kept history, then the rows just appended, then this.
    const base = map.hist_total - (tail.items.len);
    map.screen.clearRetainingCapacity();
    map.field = null;
    const field_line: ?Grid.Input.Line = if (fieldLive(b)) g.input.line else null;
    var r: usize = 0;
    while (r < g.rows) {
        const row_start = base + tail.items.len;
        if (field_line) |line| if (line.row == r) {
            // The command line is the shell's buffer, not its echo: the
            // prompt as the cells have it (blanks kept — they end where
            // typing starts), then the field's text, flowed over as many
            // rows as the line editor lays it out on.
            var buf: [4]u8 = undefined;
            for (g.row(r)[0..@min(line.col, g.cols)]) |c| try tail.appendSlice(gpa, grid_mod.cellText(c, &buf));
            const field_start = base + tail.items.len;
            try tail.appendSlice(gpa, g.field_text.items);
            map.field = .{ .start = field_start, .end = base + tail.items.len };
            const first_span = map.screen.items.len;
            var spans: std.ArrayList(Grid.RowText) = .empty;
            defer spans.deinit(gpa);
            var fr: FlowRows = .{ .gpa = gpa, .spans = &spans, .row_start = row_start, .field_start = field_start };
            try grid_mod.flowText(g.field_text.items, line.col, g.cols, &fr, FlowRows.row);
            // A line longer than the screen is still one field: its last row
            // takes the rest.
            const room = g.rows - r;
            if (spans.items.len > room) {
                spans.items[room - 1].end = spans.items[spans.items.len - 1].end;
                spans.shrinkRetainingCapacity(room);
            }
            try map.screen.appendSlice(gpa, spans.items);
            _ = first_span;
            r += spans.items.len;
            if (r < g.rows) try tail.append(gpa, '\n');
            continue;
        };
        const last = r + 1 == g.rows;
        try grid_mod.appendRowText(gpa, &tail, g.row(r), g.wraps[r] and !last);
        const end = base + tail.items.len;
        try map.screen.append(gpa, .{ .start = row_start, .end = end, .flow_start = end });
        if (!last and !g.wraps[r]) try tail.append(gpa, '\n');
        r += 1;
    }
    // Only what changed: the tail's common prefix and suffix stay.
    const end = rope.byteLen();
    try old_tail.resize(gpa, end - tail_from);
    rope.copyRange(old_tail.items, .{ .start = tail_from, .end = end });
    var pre: usize = 0;
    const most = @min(old_tail.items.len, tail.items.len);
    while (pre < most and old_tail.items[pre] == tail.items[pre]) pre += 1;
    var suf: usize = 0;
    while (suf < most - pre and old_tail.items[old_tail.items.len - 1 - suf] == tail.items[tail.items.len - 1 - suf]) suf += 1;
    const old_mid = old_tail.items.len - pre - suf;
    const new_mid = tail.items[pre .. tail.items.len - suf];
    if (old_mid > 0 or new_mid.len > 0) {
        const at = tail_from + pre;
        // A cut from the front never reaches into the tail (it ends where
        // the kept rows begin), so the two stay ordered and apart.
        if (n > 0 and reps[0].range.end > at) {
            reps[0].range.end = at;
        }
        reps[n] = .{ .range = .{ .start = at, .end = at + old_mid }, .bytes = new_mid };
        n += 1;
    }
    g.mirror = .{ .start = new_start, .end = new_end };
    map.revision = g.revision;
    if (n > 0) {
        try ed.doc.produce(gpa, reps[0..n]);
        // The CRDT keeps every scalar that ever passed through as an event,
        // and what scrolled away as a tombstone: re-found the document on
        // its text now and then (a bulk load, milliseconds), so a long-lived
        // terminal's document holds its rows, not everything that went by.
        if (ed.doc.eventCount() > refound_events and !ed.doc.hasPeers()) try ed.doc.refound(gpa);
    }
    map.doc_len = ed.text().byteLen();
}

/// Events a grid's document collects before it is re-founded on its text.
const refound_events = 1 << 16;

/// The map describes the document as it is: made for the grid as it is,
/// and nothing edited since.
fn inStep(g: *const Grid, ed: *Editor) bool {
    return g.mapped() and ed.text().byteLen() == g.map.doc_len;
}

/// The document offset of the grid's own cursor: the cell it is on, below
/// the history — on a command line, where the line's text flows to it.
pub fn cursorOffset(b: *Buffers.Buffer) ?usize {
    const g = b.grid orelse return null;
    const ed = b.textEditor() orelse return null;
    if (!inStep(g, ed)) return null;
    return g.offsetAtCell(g.historyLen() + g.cursor.y, g.cursor.x);
}

// ── The command line: a field at the prompt (doc/terminal.md §8) ─────

/// Whether `b` has a command line the editor edits: its program declared a
/// line at a prompt, does not own the keys, and the user has not broken
/// out (out of capture a terminal is read, not typed into).
pub fn fieldLive(b: *const Buffers.Buffer) bool {
    const g = b.grid orelse return false;
    return g.input.line != null and !g.input.owns_keys and !b.broken_out;
}

/// The document range of `b`'s command line — the shell's buffer, however
/// many rows it wraps over; never its prompt, never a right-hand prompt
/// beside it. Its end follows the edits made since the map (only the field
/// takes edits). Null when there is none, or the map is stale.
pub fn fieldRange(b: *Buffers.Buffer) ?Document.Range {
    if (!fieldLive(b)) return null;
    const g = b.grid.?;
    const ed = b.textEditor() orelse return null;
    if (!g.mapped()) return null;
    const f = g.map.field orelse return null;
    const now = ed.text().byteLen();
    const end = if (now >= g.map.doc_len) f.end + (now - g.map.doc_len) else f.end -| (g.map.doc_len - now);
    if (end < f.start) return null;
    return .{ .start = f.start, .end = end };
}

/// Why an edit of `r` (writing `bytes`) on grid entry `b` is refused, or
/// null when it may land: only the command line takes edits, and no edit
/// breaks it (the shell's own multi-line buffer keeps its breaks; a key
/// adding one would be a line accepted, which is the shell's Return). For
/// an entry that is no grid, its `read_only` reason.
pub fn writeRefusal(b: *Buffers.Buffer, r: Document.Range, bytes: []const u8) ?[]const u8 {
    if (b.grid == null) return b.read_only;
    const f = fieldRange(b) orelse return b.read_only orelse read_only;
    if (r.start < f.start or r.end > f.end) return "terminal output: only the command line takes edits";
    if (std.mem.indexOfAny(u8, bytes, "\r\n") != null) return "a line break would run the command line: Return does";
    return null;
}

/// Take the command line's text from the document after a keystroke
/// (`field_text`), and lay it out again over its rows. True when it
/// changed.
pub fn takeField(gpa: Allocator, b: *Buffers.Buffer) !bool {
    const f = fieldRange(b) orelse return false;
    const g = b.grid.?;
    const ed = b.textEditor().?;
    const len = f.end - f.start;
    if (len == g.field_text.items.len and ed.text().byteLen() == g.map.doc_len) {
        var buf: [256]u8 = undefined;
        if (len <= buf.len) {
            ed.text().copyRange(buf[0..len], f);
            if (std.mem.eql(u8, buf[0..len], g.field_text.items)) return false;
        }
    }
    try g.field_text.resize(gpa, len);
    ed.text().copyRange(g.field_text.items, f);
    // The document already says it: the sync writes nothing, and the map
    // follows the line as it now flows.
    try syncTo(gpa, b, ed);
    return true;
}

/// Where `b`'s caret stands in its command line, in bytes from its start
/// (clamped to it).
pub fn fieldCursor(b: *Buffers.Buffer) usize {
    const f = fieldRange(b) orelse return 0;
    const at = b.textEditor().?.cursorOffset();
    return @min(at -| f.start, f.end - f.start);
}

// ── Landmarks: where a program marked its turns (a shell's prompts) ───

/// Whether any cell of `cells` is part of a prompt.
fn promptRow(cells: []const grid_mod.Cell) bool {
    for (cells) |c| if (c.mark.prompt) return true;
    return false;
}

/// Whether any cell of `cells` holds text that is not a prompt's: a typed
/// command line, or output.
fn otherText(cells: []const grid_mod.Cell) bool {
    for (cells) |c| if (c.cp != 0 and c.cp != ' ' and !c.mark.prompt) return true;
    return false;
}

/// Whether row `r` starts a LANDMARK: a prompt row under a row that is not
/// all prompt — a prompt over two rows is one landmark, but a prompt under
/// the command line of the one before (a command that printed nothing) is
/// the next.
fn startsLandmark(g: *const Grid, r: usize) bool {
    if (!promptRow(g.rowAt(r))) return false;
    if (r == 0) return true;
    const above = g.rowAt(r - 1);
    return !promptRow(above) or otherText(above);
}

pub const Direction = enum { prev, next };

/// The landmark row before (or after) `row`, or null.
pub fn landmark(g: *const Grid, row: usize, dir: Direction) ?usize {
    switch (dir) {
        .prev => {
            var r = @min(row, g.rowCount());
            while (r > 0) {
                r -= 1;
                if (startsLandmark(g, r)) return r;
            }
        },
        .next => {
            var r = row + 1;
            while (r < g.rowCount()) : (r += 1) if (startsLandmark(g, r)) return r;
        },
    }
    return null;
}

/// Where the command line starts on prompt row `r`: the offset of the
/// first cell after the row's prompt cells.
fn inputStart(g: *const Grid, r: usize) usize {
    var last_prompt: ?usize = null;
    for (g.rowAt(r), 0..) |c, i| if (c.mark.prompt) {
        last_prompt = i;
    };
    return g.offsetAtCell(r, if (last_prompt) |i| i + 1 else 0);
}

/// Move `b`'s caret to the landmark before (or after) it — the start of
/// that prompt's command line. False when there is none that way, or the
/// entry is no grid read as text.
pub fn moveToLandmark(b: *Buffers.Buffer, dir: Direction) bool {
    const g = b.grid orelse return false;
    const ed = b.textEditor() orelse return false;
    if (!inStep(g, ed)) return false;
    const row = g.rowOfOffset(ed.cursorOffset());
    const r = landmark(g, row, dir) orelse return false;
    ed.clearSelection();
    ed.placeCursor(inputStart(g, r));
    return true;
}

/// Select what follows the landmark at or above `b`'s caret, up to the next
/// one: a command's output — the rows after its command line, to the row
/// before the next prompt, trailing blank rows left out. False when there is
/// none (the caret is above every prompt, or the command printed nothing).
pub fn selectLandmarkBody(gpa: Allocator, b: *Buffers.Buffer) !bool {
    const g = b.grid orelse return false;
    const ed = b.textEditor() orelse return false;
    if (!inStep(g, ed)) return false;
    const row = g.rowOfOffset(ed.cursorOffset());
    const top = if (startsLandmark(g, row)) row else landmark(g, row, .prev) orelse return false;
    // Past the prompt and the command line it holds (rows with a prompt or
    // typed input cell).
    var first = top;
    while (first < g.rowCount()) : (first += 1) {
        const cells = g.rowAt(first);
        var marked = false;
        for (cells) |c| if (c.mark.prompt or c.mark.input) {
            marked = true;
        };
        if (!marked) break;
    }
    var end = landmark(g, top, .next) orelse g.rowCount();
    while (end > first) {
        const s = g.rowText(end - 1);
        if (s.start != s.end) break;
        end -= 1;
    }
    if (end <= first) return false;
    try ed.selectRange(gpa, g.rowText(first).start, g.rowText(end - 1).end);
    return true;
}

/// `b` is READ from now on (capture was left): its document catches up, and
/// the caret goes where the terminal's cursor is, so reading starts where
/// the program was.
pub fn enterReading(gpa: Allocator, buffers: *Buffers, b: *Buffers.Buffer) !void {
    if (b.grid == null) return;
    try sync(gpa, buffers, b);
    const ed = b.textEditor() orelse return;
    ed.clearSelection();
    if (cursorOffset(b)) |off| ed.placeCursor(off);
}

// ── Tests ───────────────────────────────────────────────────────────

const t = std.testing;
const wire = @import("weft_membrane").grid;

fn publish(gpa: Allocator, g: *Grid, cols: u16, screen: []const []const u8, history: ?struct { dropped: u32, rows: []const []const u8, reset: bool = false }) !void {
    var msg: std.ArrayList(u8) = .empty;
    defer msg.deinit(gpa);
    const h: wire.Header = .{ .cols = cols, .rows = @intCast(screen.len), .rows_sent = @intCast(screen.len) };
    try msg.appendSlice(gpa, std.mem.asBytes(&h));
    for (screen, 0..) |line, r| {
        var idx: [4]u8 = undefined;
        std.mem.writeInt(u32, &idx, @intCast(r), .little);
        try msg.appendSlice(gpa, &idx);
        for (0..cols) |c| {
            const cell: wire.Cell = .{ .cp = if (c < line.len) line[c] else 0 };
            try msg.appendSlice(gpa, std.mem.asBytes(&cell));
        }
    }
    if (history) |hist| {
        var payload: std.ArrayList(u8) = .empty;
        defer payload.deinit(gpa);
        const head: wire.HistoryHead = .{ .dropped = hist.dropped, .count = @intCast(hist.rows.len), .flags = if (hist.reset) wire.HistoryHead.reset else 0 };
        try payload.appendSlice(gpa, std.mem.asBytes(&head));
        for (hist.rows) |line| {
            var cells: [16]wire.Cell = undefined;
            for (line, 0..) |ch, i| cells[i] = .{ .cp = ch };
            try wire.appendHistoryRow(&payload, gpa, cells[0..line.len], false);
        }
        try wire.appendSection(&msg, gpa, .history, payload.items);
    }
    _ = try g.apply(gpa, msg.items);
}

fn docText(gpa: Allocator, ed: *Editor) ![]u8 {
    const rope = ed.text();
    const out = try gpa.alloc(u8, rope.byteLen());
    rope.copyRange(out, .{ .start = 0, .end = rope.byteLen() });
    return out;
}

test "grid mirror: the document is the history then the screen, a line a row, and follows both" {
    const gpa = t.allocator;
    const task = @import("task.zig");
    var pool = try task.Pool.init(gpa, .{ .threads = 1 });
    defer pool.deinit();
    var bufs = try Buffers.init(gpa, pool, "user");
    defer bufs.deinit(gpa);
    const id = try bufs.createView(gpa, "*t*", "");
    const b = bufs.get(id).?;
    const g = try gpa.create(Grid);
    g.* = .{};
    b.grid = g;

    try publish(gpa, g, 6, &.{ "$ ls", "a  b", "$" }, null);
    try sync(gpa, &bufs, b);
    const ed = b.textEditor().?;
    try t.expect(b.read_only != null);
    {
        const s = try docText(gpa, ed);
        defer gpa.free(s);
        try t.expectEqualStrings("$ ls\na  b\n$", s);
    }
    // A caret in the first screen line holds still while rows scroll up
    // into history and new ones come: it moves with its text.
    ed.placeCursor(2); // on `ls`
    try publish(gpa, g, 6, &.{ "a  b", "$ pwd", "/srv" }, .{ .dropped = 0, .rows = &.{"$ ls"} });
    try sync(gpa, &bufs, b);
    {
        const s = try docText(gpa, ed);
        defer gpa.free(s);
        try t.expectEqualStrings("$ ls\na  b\n$ pwd\n/srv", s);
    }
    try t.expectEqual(@as(usize, 2), ed.cursorOffset());
    // The owner's scrollback drops its oldest row: so does the document.
    try publish(gpa, g, 6, &.{ "$ pwd", "/srv", "$" }, .{ .dropped = 1, .rows = &.{"a  b"} });
    try sync(gpa, &bufs, b);
    {
        const s = try docText(gpa, ed);
        defer gpa.free(s);
        try t.expectEqualStrings("a  b\n$ pwd\n/srv\n$", s);
    }
    // A reset replaces the history whole — and only what differs is written.
    try publish(gpa, g, 6, &.{ "$ pwd", "/srv", "$" }, .{ .dropped = 0, .rows = &.{ "x", "a  b" }, .reset = true });
    try sync(gpa, &bufs, b);
    {
        const s = try docText(gpa, ed);
        defer gpa.free(s);
        try t.expectEqualStrings("x\na  b\n$ pwd\n/srv\n$", s);
    }
    // The terminal's cursor, as a document offset: its row below the history.
    g.cursor = .{ .x = 1, .y = 2 };
    try t.expectEqual(@as(?usize, "x\na  b\n$ pwd\n/srv\n".len + 1), cursorOffset(b));
    // The mirror is core's writing, not the user's: nothing to undo.
    try t.expect(!ed.canUndo());
}

/// A screen of `rows` (text, wraps) `cols` wide, and an input section when
/// `line` is given: a prompt at that row and column, its line `text`.
fn publishWrapped(gpa: Allocator, g: *Grid, cols: u16, rows: []const struct { []const u8, bool }, line: ?struct { row: u32, col: u32, text: []const u8 }) !void {
    var msg: std.ArrayList(u8) = .empty;
    defer msg.deinit(gpa);
    const h: wire.Header = .{ .cols = cols, .rows = @intCast(rows.len), .rows_sent = @intCast(rows.len) };
    try msg.appendSlice(gpa, std.mem.asBytes(&h));
    for (rows, 0..) |r, i| {
        var idx: [4]u8 = undefined;
        std.mem.writeInt(u32, &idx, @as(u32, @intCast(i)) | (if (r[1]) wire.row_wraps else 0), .little);
        try msg.appendSlice(gpa, &idx);
        for (0..cols) |c| {
            const cell: wire.Cell = .{ .cp = if (c < r[0].len) r[0][c] else 0 };
            try msg.appendSlice(gpa, std.mem.asBytes(&cell));
        }
    }
    if (line) |l| {
        var payload: std.ArrayList(u8) = .empty;
        defer payload.deinit(gpa);
        try wire.Input.encode(&payload, gpa, .{ .flags = wire.InputHead.line | wire.InputHead.fresh, .row = l.row, .col = l.col, .cursor = @intCast(l.text.len) }, l.text, "Return");
        try wire.appendSection(&msg, gpa, .input, payload.items);
    }
    const applied = try g.apply(gpa, msg.items);
    if (applied.input) |in| if (in.head.flags & wire.InputHead.line != 0) {
        try g.field_text.resize(gpa, in.line.len);
        @memcpy(g.field_text.items, in.line);
    };
}

test "grid mirror: a soft-wrapped line is one document line, and its cells map back exactly" {
    const gpa = t.allocator;
    const task = @import("task.zig");
    var pool = try task.Pool.init(gpa, .{ .threads = 1 });
    defer pool.deinit();
    var bufs = try Buffers.init(gpa, pool, "user");
    defer bufs.deinit(gpa);
    const b = bufs.get(try bufs.createView(gpa, "*t*", "")).?;
    const g = try gpa.create(Grid);
    g.* = .{};
    b.grid = g;
    // "abcd efgh" wrapped at 5 — the blank at the wrap is the line's own.
    try publishWrapped(gpa, g, 5, &.{ .{ "abcd ", true }, .{ "efgh", false }, .{ "$", false } }, null);
    try sync(gpa, &bufs, b);
    const ed = b.textEditor().?;
    {
        const s = try docText(gpa, ed);
        defer gpa.free(s);
        try t.expectEqualStrings("abcd efgh\n$", s);
    }
    // Row 1's cell 2 is the line's `g`.
    try t.expectEqual(@as(usize, 7), g.offsetAtCell(1, 2));
    try t.expectEqual(@as(usize, 1), g.rowOfOffset(7));
    try t.expectEqual(@as(usize, 0), g.rowOfOffset(4));
}

test "grid mirror: a command line is its buffer flowed over its rows — never the echo, never a right-hand prompt" {
    const gpa = t.allocator;
    const task = @import("task.zig");
    var pool = try task.Pool.init(gpa, .{ .threads = 1 });
    defer pool.deinit();
    var bufs = try Buffers.init(gpa, pool, "user");
    defer bufs.deinit(gpa);
    const b = bufs.get(try bufs.createView(gpa, "*t*", "")).?;
    b.capture_endpoint = try gpa.dupe(u8, "x");
    const g = try gpa.create(Grid);
    g.* = .{};
    b.grid = g;
    // A prompt `$ ` with a right prompt `<R` on a 10-wide screen, and a
    // buffer of 12 that wraps onto the next row (whose echo the cells hold).
    try publishWrapped(gpa, g, 10, &.{ .{ "$ echo <R ", false }, .{ "", false }, .{ "", false } }, .{ .row = 0, .col = 2, .text = "echo abcdefg" });
    g.input.owns_keys = false;
    try sync(gpa, &bufs, b);
    const ed = b.textEditor().?;
    {
        const s = try docText(gpa, ed);
        defer gpa.free(s);
        try t.expectEqualStrings("$ echo abcdefg\n", s);
    }
    const f = fieldRange(b).?;
    try t.expectEqual(@as(usize, 2), f.start);
    try t.expectEqual(@as(usize, 14), f.end);
    // `echo abc` fills row 0 from column 2; `defg` flows onto row 1.
    try t.expectEqual(@as(usize, 10), g.offsetAtCell(1, 0));
    try t.expectEqual(@as(usize, 1), g.rowOfOffset(11));
    // Only the field takes edits.
    try t.expect(writeRefusal(b, .{ .start = 0, .end = 1 }, "") != null);
    try t.expect(writeRefusal(b, .{ .start = 12, .end = 12 }, "z") == null);
}
