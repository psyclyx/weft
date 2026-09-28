//! grid_mirror — a grid entry's cells as a READ-ONLY text document, kept in
//! step with the grid (doc/terminal.md §4), so the text machinery works on a
//! terminal unchanged: motions, search, snipe, visual selection, yank, the
//! pointer's drag-select and copy. Row `i` of the grid (its history, then
//! its screen) is line `i` of the document; a cell's text is
//! `grid.cellText`, so an offset names a cell and the view draws the
//! document's caret and selections ON the cells (`gfx/view/grid.zig`).
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

/// Bring `b`'s document up to its grid's rows.
pub fn sync(gpa: Allocator, buffers: *Buffers, b: *Buffers.Buffer) !void {
    const g = b.grid orelse return;
    const ed = try ensureDocument(gpa, buffers, b);
    const rope = ed.text();
    const new_start = g.history_start;
    const new_end = g.history_start + g.historyLen();

    var reps: [2]Document.Replacement = undefined;
    var n: usize = 0;
    var tail: std.ArrayList(u8) = .empty;
    defer tail.deinit(gpa);
    var old_tail: std.ArrayList(u8) = .empty;
    defer old_tail.deinit(gpa);

    // Where the document's history rows are still this grid's.
    const incremental = if (g.mirror) |m| m.start <= new_start and new_start <= m.end and m.end <= new_end else false;
    var tail_from: usize = 0; // old-document offset the tail replaces from
    var history_from: u64 = new_start; // first history row the tail writes
    if (incremental) {
        const m = g.mirror.?;
        // The rows that went from the front.
        const gone: usize = @intCast(new_start - m.start);
        if (gone > 0) {
            const cut = lineStart(rope, gone);
            reps[n] = .{ .range = .{ .start = 0, .end = cut }, .bytes = "" };
            n += 1;
        }
        tail_from = lineStart(rope, @intCast(m.end - m.start));
        history_from = m.end;
    }
    // The tail: history rows the document lacks, then the screen.
    for (@intCast(history_from - new_start)..g.historyLen()) |i| {
        try grid_mod.appendRowText(gpa, &tail, g.historyRow(i));
        try tail.append(gpa, '\n');
    }
    const field_row: ?usize = if (fieldLive(b)) g.input.line.?.row else null;
    for (0..g.rows) |r| {
        if (r > 0) try tail.append(gpa, '\n');
        if (field_row == r) {
            // The command line is the editor's while it edits it: the prompt
            // as the cells have it (blanks kept — they end where typing
            // starts), then the field's own text, whatever the cells echo.
            const line = g.input.line.?;
            var buf: [4]u8 = undefined;
            for (g.row(r)[0..@min(line.col, g.cols)]) |c| try tail.appendSlice(gpa, grid_mod.cellText(c, &buf));
            try tail.appendSlice(gpa, g.field_text.items);
        } else try grid_mod.appendRowText(gpa, &tail, g.row(r));
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
    if (n == 0) return;
    try ed.doc.produce(gpa, reps[0..n]);
    // The CRDT keeps every scalar that ever passed through as an event, and
    // what scrolled away as a tombstone: re-found the document on its text
    // now and then (a bulk load, milliseconds), so a long-lived terminal's
    // document holds its rows, not everything that went by.
    if (ed.doc.eventCount() > refound_events and !ed.doc.hasPeers()) try ed.doc.refound(gpa);
}

/// Events a grid's document collects before it is re-founded on its text.
const refound_events = 1 << 16;

/// Line `i`'s first byte in `rope` (its end when there are fewer lines).
fn lineStart(rope: anytype, i: usize) usize {
    if (i >= rope.lineCount()) return rope.byteLen();
    return rope.lineRange(i).start;
}

/// The document offset of the grid's own cursor: its screen row, below the
/// history, at the bytes its cells before it take.
pub fn cursorOffset(b: *Buffers.Buffer) ?usize {
    const g = b.grid orelse return null;
    const ed = b.textEditor() orelse return null;
    const rope = ed.text();
    const line = g.historyLen() + g.cursor.y;
    if (line >= rope.lineCount()) return rope.byteLen();
    const range = rope.lineRange(line);
    var off: usize = 0;
    var buf: [4]u8 = undefined;
    for (g.row(g.cursor.y)[0..@min(g.cursor.x, g.cols)]) |c| off += grid_mod.cellText(c, &buf).len;
    return range.start + @min(off, range.end - range.start);
}

// ── The command line: a field at the prompt (doc/terminal.md §8) ─────

/// Whether `b` has a command line the editor edits: its program declared a
/// line at a prompt, does not own the keys, and the user has not broken
/// out (out of capture a terminal is read, not typed into).
pub fn fieldLive(b: *const Buffers.Buffer) bool {
    const g = b.grid orelse return false;
    return g.input.line != null and !g.input.owns_keys and !b.broken_out;
}

/// The document range of `b`'s command line: from where its row's prompt
/// ends to the end of that line. Null when there is none, or the document
/// is not in step with the cells.
pub fn fieldRange(b: *Buffers.Buffer) ?Document.Range {
    if (!fieldLive(b)) return null;
    const g = b.grid.?;
    const ed = b.textEditor() orelse return null;
    if (!inStep(g, ed)) return null;
    const line = g.input.line.?;
    const range = ed.text().lineRange(g.historyLen() + line.row);
    var prefix: usize = 0;
    var buf: [4]u8 = undefined;
    for (g.row(line.row)[0..@min(line.col, g.cols)]) |c| prefix += grid_mod.cellText(c, &buf).len;
    return .{ .start = range.start + @min(prefix, range.end - range.start), .end = range.end };
}

/// Why an edit of `r` (writing `bytes`) on grid entry `b` is refused, or
/// null when it may land: only the command line takes edits, and only on
/// its one line. For an entry that is no grid, its `read_only` reason.
pub fn writeRefusal(b: *Buffers.Buffer, r: Document.Range, bytes: []const u8) ?[]const u8 {
    if (b.grid == null) return b.read_only;
    const f = fieldRange(b) orelse return b.read_only orelse read_only;
    if (r.start < f.start or r.end > f.end) return "terminal output: only the command line takes edits";
    if (std.mem.indexOfAny(u8, bytes, "\r\n") != null) return "the command line is one line";
    return null;
}

/// Take the command line's text from the document after a keystroke
/// (`field_text`). True when it changed.
pub fn takeField(gpa: Allocator, b: *Buffers.Buffer) !bool {
    const f = fieldRange(b) orelse return false;
    const g = b.grid.?;
    const ed = b.textEditor().?;
    const len = f.end - f.start;
    if (len == g.field_text.items.len) {
        var buf: [256]u8 = undefined;
        if (len <= buf.len) {
            ed.text().copyRange(buf[0..len], f);
            if (std.mem.eql(u8, buf[0..len], g.field_text.items)) return false;
        }
    }
    try g.field_text.resize(gpa, len);
    ed.text().copyRange(g.field_text.items, f);
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

/// The document is in step with the grid's rows: a line a row. Line-based
/// answers (a landmark's line) are only true then.
fn inStep(g: *const Grid, ed: *Editor) bool {
    return g.mirror != null and ed.text().lineCount() == g.rowCount();
}

/// Where the command line starts on prompt row `r`: the offset, in the
/// document, of the first cell after the row's prompt cells.
fn inputStart(g: *const Grid, ed: *Editor, r: usize) usize {
    const range = ed.text().lineRange(r);
    const cells = g.rowAt(r);
    var off: usize = 0;
    var buf: [4]u8 = undefined;
    var last_prompt: ?usize = null;
    for (cells, 0..) |c, i| if (c.mark.prompt) {
        last_prompt = i;
    };
    const upto = if (last_prompt) |i| i + 1 else 0;
    for (cells[0..@min(upto, cells.len)]) |c| off += grid_mod.cellText(c, &buf).len;
    return range.start + @min(off, range.end - range.start);
}

/// Move `b`'s caret to the landmark before (or after) it — the start of
/// that prompt's command line. False when there is none that way, or the
/// entry is no grid read as text.
pub fn moveToLandmark(b: *Buffers.Buffer, dir: Direction) bool {
    const g = b.grid orelse return false;
    const ed = b.textEditor() orelse return false;
    if (!inStep(g, ed)) return false;
    const row = ed.text().offsetToPoint(ed.cursorOffset()).row;
    const r = landmark(g, row, dir) orelse return false;
    ed.clearSelection();
    ed.placeCursor(inputStart(g, ed, r));
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
    const rope = ed.text();
    const row = rope.offsetToPoint(ed.cursorOffset()).row;
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
    while (end > first and rope.lineRange(end - 1).start == rope.lineRange(end - 1).end) end -= 1;
    if (end <= first) return false;
    try ed.selectRange(gpa, rope.lineRange(first).start, rope.lineRange(end - 1).end);
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
            try wire.appendHistoryRow(&payload, gpa, cells[0..line.len]);
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
