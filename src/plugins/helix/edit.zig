//! Every verb that edits, over every selection at once, as ONE undo unit.
//!
//! The one mechanism: `putEach` anchors one range per selection and runs
//! helix's own operator `hx-op-put` over them through `runRangeArgEach` —
//! reverse offset order (a later edit never shifts an earlier range), all
//! inside one undo unit. The operator is handed only its range, so what to
//! write there is a PLAN set up before the run: the job whose start offset
//! the range still has (earlier jobs have not moved yet) and the `Source`
//! that says what that job writes. Delete, change, paste, replace, case,
//! replace-with-a-character, join and open-a-line are all `putEach` with a
//! different source. Each job leaves a live range over what it wrote, and the
//! verb reads those back to place the selections afterwards.

const std = @import("std");
const weft = @import("weft");
const sel = @import("selection.zig");
const text = @import("text.zig");
const state = @import("state.zig");

const max = sel.max;
const semantic_action = weft.semantic.action.standard;

// ── The plan ────────────────────────────────────────────────────────────

pub const Case = enum { toggle, lower, upper };

/// What each job writes over its range.
const Source = union(enum) {
    /// The same bytes everywhere (`""` deletes).
    literal: []const u8,
    /// Register `slot`'s value for this selection, under core's
    /// distribution rule (`count` selections share it).
    register: struct { slot: u8, count: usize },
    /// Every character but a line end, replaced by this one (`r`).
    fill: struct { buf: [4]u8, len: usize },
    /// The range's own text, case-mapped (`~`, `` ` ``, `` A-` ``).
    case: Case,
    /// A line break plus the line's indentation (`o`), or the indentation plus
    /// a line break (`O`).
    open: enum { below, above },
    /// Job `i` writes `pad[i]` spaces (`&`).
    pad: []const usize,
};

var source: Source = .{ .literal = "" };
var jobs: usize = 0;
var job_at: [max]usize = undefined;
var job_used: [max]bool = undefined;
/// A linewise paste after a last line with no newline to land after: the job
/// writes one first.
var job_newline: [max]bool = undefined;
/// The live range over what each job wrote.
var job_result: [max]?u32 = undefined;

var put_buf: [(1 << 16) + 8]u8 = undefined;

/// Write `src` over each of `ranges` (document order, one per selection), as
/// one undo unit.
fn putEach(ranges: []const weft.Range, src: Source, newline: ?[]const bool) void {
    source = src;
    jobs = ranges.len;
    var handles: [max]?u32 = undefined;
    for (ranges, 0..) |r, i| {
        job_at[i] = r.start;
        job_used[i] = false;
        job_newline[i] = if (newline) |nl| nl[i] else false;
        job_result[i] = null;
        handles[i] = weft.anchorRange(r);
    }
    weft.runRangeArgEach("hx-op-put", handles[0..ranges.len]);
}

/// Which job a range is. Jobs run from the last offset back, so the latest
/// unused job starting here is the one.
fn claim(start: usize) ?usize {
    var i = jobs;
    while (i > 0) {
        i -= 1;
        if (!job_used[i] and job_at[i] == start) {
            job_used[i] = true;
            return i;
        }
    }
    return null;
}

/// What job `i` writes over `r`, built in `put_buf` where it is derived.
fn bytesFor(i: usize, r: weft.Range) ?[]const u8 {
    switch (source) {
        .literal => |l| return l,
        .register => |reg| return weft.registerPasteValueIn(reg.slot, i, reg.count),
        .fill => |f| {
            const src = weft.slice(r.start, r.end);
            var w: usize = 0;
            var k: usize = 0;
            while (k < src.len) {
                const step = std.unicode.utf8ByteSequenceLength(src[k]) catch 1;
                const out: []const u8 = if (src[k] == '\n') "\n" else f.buf[0..f.len];
                if (w + out.len > put_buf.len) return null;
                @memcpy(put_buf[w..][0..out.len], out);
                w += out.len;
                k += step;
            }
            return put_buf[0..w];
        },
        .case => |c| {
            const src = weft.slice(r.start, r.end);
            if (src.len > put_buf.len) return null;
            for (src, put_buf[0..src.len]) |b, *o| o.* = switch (c) {
                .lower => std.ascii.toLower(b),
                .upper => std.ascii.toUpper(b),
                .toggle => if (std.ascii.isUpper(b)) std.ascii.toLower(b) else std.ascii.toUpper(b),
            };
            return put_buf[0..src.len];
        },
        .open => |where| {
            const l = weft.lineAt(r.start);
            const line = weft.slice(l.start, l.end);
            var indent: usize = 0;
            while (indent < line.len and (line[indent] == ' ' or line[indent] == '\t')) indent += 1;
            if (indent + 1 > put_buf.len) return null;
            switch (where) {
                .below => {
                    put_buf[0] = '\n';
                    @memcpy(put_buf[1..][0..indent], line[0..indent]);
                },
                .above => {
                    @memcpy(put_buf[0..indent], line[0..indent]);
                    put_buf[indent] = '\n';
                },
            }
            return put_buf[0 .. indent + 1];
        },
        .pad => |pad| {
            const k = @min(pad[i], put_buf.len);
            @memset(put_buf[0..k], ' ');
            return put_buf[0..k];
        },
    }
}

/// `hx-op-put`: the operator `putEach` runs once per selection.
pub fn opPut() void {
    const h = weft.argRange(0) orelse return;
    const r = weft.rangeEnds(h) orelse return;
    const i = claim(r.start) orelse return;
    var bytes = bytesFor(i, r) orelse return;
    var base = r.start;
    if (job_newline[i]) {
        if (bytes.len + 1 > put_buf.len) return;
        std.mem.copyBackwards(u8, put_buf[1..][0..bytes.len], bytes);
        put_buf[0] = '\n';
        bytes = put_buf[0 .. bytes.len + 1];
        base += 1;
    }
    weft.editRange(h, bytes);
    const written = bytes.len - (base - r.start);
    switch (source) {
        .register => |reg| weft.pasteValueAtIn(reg.slot, base, i, reg.count),
        else => {},
    }
    job_result[i] = weft.anchorRange(.{ .start = base, .end = base + written });
}

/// What job `i` wrote, where it is now.
fn wrote(i: usize) ?weft.Range {
    return weft.rangeEnds(job_result[i] orelse return null);
}

// ── The last modification (`g.`) ────────────────────────────────────────

var last_edit: ?u32 = null;

/// The buffers edited most recently, newest first, by name (`gm`).
var modified: [2][256]u8 = undefined;
var modified_len: [2]usize = .{ 0, 0 };

fn noteBuffer() void {
    var buf: [256]u8 = undefined;
    const name = weft.activeBufferName(&buf) orelse return;
    if (std.mem.eql(u8, name, modified[0][0..modified_len[0]])) return;
    modified[1] = modified[0];
    modified_len[1] = modified_len[0];
    @memcpy(modified[0][0..name.len], name);
    modified_len[0] = name.len;
}

/// `gm`: the buffer edited last, other than this one. Only edits helix made
/// count — it knows no other history of modification.
pub fn gotoLastModified() void {
    var buf: [256]u8 = undefined;
    const here = weft.activeBufferName(&buf) orelse "";
    for (&modified, modified_len) |*name, len| {
        if (len == 0 or std.mem.eql(u8, name[0..len], here)) continue;
        if (weft.focusBuffer(name[0..len])) return;
    }
    weft.echo("no other modified buffer");
}

/// Remember where the primary selection is as the last place edited.
pub fn noteEdit() void {
    noteBuffer();
    if (!sel.load()) return;
    const r = sel.primarySpan();
    const h = weft.anchorRange(.{ .start = r.start, .end = r.start }) orelse return;
    if (!weft.retainRange(h)) return;
    if (last_edit) |old| weft.releaseRange(old);
    last_edit = h;
}

/// `g.`: back to the last place edited.
pub fn gotoLastEdit() void {
    const h = last_edit orelse return weft.echo("no edit to go back to");
    const r = weft.rangeEnds(h) orelse return;
    _ = weft.setSelections(&.{sel.caret(r.start)}, 0);
}

// ── Transfer: yank, delete, change, paste, replace ──────────────────────

/// Every selection's span, and whether they are all whole lines.
fn spans(out: []weft.Range) bool {
    var lines = true;
    for (sel.items[0..sel.n], out[0..sel.n]) |s, *r| {
        r.* = sel.span(s);
        lines = lines and sel.isLinewise(r.*);
    }
    return lines;
}

/// `y`'s text arm: one register value per selection. The selections stay.
pub fn yank() void {
    const slot = state.takeRegister();
    if (!sel.load()) return;
    var ranges: [max]weft.Range = undefined;
    const lines = spans(&ranges);
    weft.yankEachIn(slot, ranges[0..sel.n], lines);
    sel.flashAll();
}

/// Delete every selection, first yanking it into `slot` (null: no yank),
/// and leave a caret where each one was.
fn remove(slot: ?u8) void {
    if (!sel.load()) return;
    var ranges: [max]weft.Range = undefined;
    const lines = spans(&ranges);
    if (slot) |s| weft.yankEachIn(s, ranges[0..sel.n], lines);
    putEach(ranges[0..sel.n], .{ .literal = "" }, null);
    for (sel.items[0..sel.n], 0..) |*s, i| s.* = sel.caret((wrote(i) orelse ranges[i]).start);
    sel.store();
    noteEdit();
}

/// `d`'s text arm (and `A-d`, which keeps the register).
pub fn delete(keep_register: bool) void {
    const slot = state.takeRegister();
    remove(if (keep_register) null else slot);
    weft.exitToResting();
}

/// `c` (and `A-c`): delete every selection, then type where each one was.
pub fn change(keep_register: bool) void {
    const slot = state.takeRegister();
    if (onText()) remove(if (keep_register) null else slot);
    enterInsert();
}

/// `p` / `P`: place the register after (before) every selection — each its
/// own value when the register holds one per selection. A linewise value lands
/// on the line after (before) the selection's lines. The pasted text is
/// selected afterwards, as in helix.
pub fn paste(after: bool) void {
    const slot = state.takeRegister();
    if (!after) switch (weft.semanticAction(semantic_action.paste_before)) {
        .handled, .transfer_stored, .interaction_opened, .target_opened, .focus_changed, .relation_opened, .working_target_changed => return,
        .unavailable, .failed, _ => {},
    };
    if (!sel.load()) return;
    if (weft.registerTextIn(slot).len == 0) return weft.echo("register is empty");
    pasteFrom(.{ .register = .{ .slot = slot, .count = sel.n } }, weft.registerLinewiseIn(slot), after);
}

/// Place `src` after (before) every loaded selection — on the next
/// (previous) line when it is whole lines — and select what landed.
fn pasteFrom(src: Source, lines: bool, after: bool) void {
    var points: [max]weft.Range = undefined;
    var newline: [max]bool = undefined;
    for (sel.items[0..sel.n], 0..) |s, i| {
        const r = sel.span(s);
        newline[i] = false;
        var at = if (after) r.end else r.start;
        if (lines) {
            if (after) {
                const l = weft.lineAt(if (r.end > r.start) r.end - 1 else r.start);
                at = if (l.end >= text.len()) l.end else l.end + 1;
                newline[i] = l.end >= text.len();
            } else at = weft.lineAt(r.start).start;
        }
        points[i] = .{ .start = at, .end = at };
    }
    putEach(points[0..sel.n], src, newline[0..sel.n]);
    selectWritten();
}

// ── The system clipboard (`SPC y p P R`) ────────────────────────────────
// The clipboard door is config-granted (helix.js grants it). What mirrors it
// is helix's choice: the unnamed register. A clipboard that still holds what
// the unnamed register holds pastes FROM the register, so a projection
// row's ferried identity survives the round trip.

/// `SPC y`: yank, then hand the unnamed register's text to the clipboard.
pub fn yankToClipboard() void {
    yank();
    if (!weft.clipboardSet(weft.registerTextIn(0))) weft.echo("clipboard unavailable");
}

/// What the clipboard offers a paste: nothing (said why), the unnamed
/// register (it holds the same text — paste that, identity and all), or
/// text from elsewhere. The rule is the SDK's, shared with ide and vim.
const Clip = union(enum) { none, register, text: []const u8 };

fn clipboard() Clip {
    return switch (weft.clipboardPasteSource()) {
        .unavailable => blk: {
            weft.echo("clipboard unavailable");
            break :blk .none;
        },
        .empty => blk: {
            weft.echo("clipboard is empty");
            break :blk .none;
        },
        .register => .register,
        .foreign => |t| .{ .text = t },
    };
}

/// `SPC p` / `SPC P`: the clipboard after (before) every selection.
pub fn pasteClipboard(after: bool) void {
    _ = state.takeRegister();
    switch (clipboard()) {
        .none => {},
        .register => paste(after),
        .text => |t| {
            if (!sel.load()) return;
            pasteFrom(.{ .literal = t }, t[t.len - 1] == '\n', after);
        },
    }
}

/// `SPC R`: replace every selection with the clipboard.
pub fn replaceWithClipboard() void {
    _ = state.takeRegister();
    switch (clipboard()) {
        .none => {},
        .register => replaceWithRegister(),
        .text => |t| rewrite(.{ .literal = t }),
    }
}

// ── Align (`&`) ─────────────────────────────────────────────────────────

/// `&`: pad the selections with spaces so they line up. The first selection
/// on each line aligns with the first on every other line, the second with
/// the second, and so on — each group's heads move to the rightmost head of
/// the group, by spaces inserted before the selection. A column is counted
/// in characters (a tab is one).
pub fn alignSelections() void {
    if (!sel.load()) return;
    var row: [max]usize = undefined;
    var col: [max]usize = undefined;
    var group: [max]usize = undefined;
    var groups: usize = 0;
    for (sel.items[0..sel.n], 0..) |s, i| {
        const line = weft.lineAt(s.head);
        if (weft.lineAt(s.anchor).start != line.start) return weft.echo("align cannot work with multi line selections");
        row[i] = line.start;
        col[i] = std.unicode.utf8CountCodepoints(weft.slice(line.start, s.head)) catch s.head - line.start;
        group[i] = if (i > 0 and row[i - 1] == row[i]) group[i - 1] + 1 else 0;
        groups = @max(groups, group[i] + 1);
    }
    // Each group aligns after the ones left of it have already pushed its
    // members right, so a member's column counts the pads before it on its
    // own line.
    var pad: [max]usize = @splat(0);
    for (0..groups) |g| {
        var widest: usize = 0;
        for (0..sel.n) |i| if (group[i] == g) {
            widest = @max(widest, col[i] + shiftBefore(&row, &group, &pad, i, g));
        };
        for (0..sel.n) |i| if (group[i] == g) {
            pad[i] = widest - (col[i] + shiftBefore(&row, &group, &pad, i, g));
        };
    }
    var points: [max]weft.Range = undefined;
    var pads: [max]usize = undefined;
    var m: usize = 0;
    for (sel.items[0..sel.n], 0..) |s, i| {
        if (pad[i] == 0) continue;
        const at = s.range().start;
        points[m] = .{ .start = at, .end = at };
        pads[m] = pad[i];
        m += 1;
    }
    if (m == 0) return;
    const before = sel.items;
    const count = sel.n;
    putEach(points[0..m], .{ .pad = pads[0..m] }, null);
    // Every insertion sits at or before the selections after it: each moves
    // right by the pads up to and including its own.
    var shift: usize = 0;
    for (before[0..count], 0..) |s, i| {
        shift += pad[i];
        sel.items[i] = .{ .anchor = s.anchor + shift, .head = s.head + shift };
    }
    sel.n = count;
    sel.store();
    noteEdit();
}

fn shiftBefore(row: []const usize, group: []const usize, pad: []const usize, i: usize, g: usize) usize {
    var total: usize = 0;
    var j = i;
    while (j > 0) {
        j -= 1;
        if (row[j] != row[i]) break;
        if (group[j] < g) total += pad[j];
    }
    return total;
}

/// `R`: replace every selection with the register (one value each where the
/// counts match), selecting what was written.
pub fn replaceWithRegister() void {
    const slot = state.takeRegister();
    if (!sel.load()) return;
    var ranges: [max]weft.Range = undefined;
    _ = spans(&ranges);
    putEach(ranges[0..sel.n], .{ .register = .{ .slot = slot, .count = sel.n } }, null);
    selectWritten();
}

/// Select what each job wrote (a selection whose job wrote nothing stays).
fn selectWritten() void {
    for (sel.items[0..sel.n], 0..) |*s, i| {
        const w = wrote(i) orelse continue;
        s.* = .{ .anchor = w.start, .head = w.end };
    }
    sel.store();
    sel.flashAll();
    noteEdit();
}

/// Rewrite every selection in place from `src`, keeping them selected.
fn rewrite(src: Source) void {
    if (!sel.load()) return;
    var ranges: [max]weft.Range = undefined;
    _ = spans(&ranges);
    putEach(ranges[0..sel.n], src, null);
    selectWritten();
}

/// `r<c>`: every character of every selection becomes `c`.
pub fn replaceWith(c: []const u8) void {
    if (c.len == 0) return;
    var f: @FieldType(Source, "fill") = .{ .buf = undefined, .len = @min(c.len, 4) };
    @memcpy(f.buf[0..f.len], c[0..f.len]);
    rewrite(.{ .fill = f });
}

/// `~` / `` ` `` / `` A-` ``.
pub fn setCase(c: Case) void {
    rewrite(.{ .case = c });
}

// ── Lines: join, indent, comment ────────────────────────────────────────

/// Every selection's lines as merged blocks, `[first line start, past the last
/// line's newline)` — two selections on one line give that line once.
fn lineBlocks(out: []weft.Range) usize {
    var m: usize = 0;
    for (sel.items[0..sel.n]) |s| {
        const r = sel.span(s);
        const first = weft.lineAt(r.start).start;
        const last = weft.lineAt(@max(r.start, r.end -| 1));
        const block: weft.Range = .{ .start = first, .end = @min(last.end + 1, text.len()) };
        if (m > 0 and block.start < out[m - 1].end) {
            out[m - 1].end = @max(out[m - 1].end, block.end);
        } else {
            out[m] = block;
            m += 1;
        }
    }
    return m;
}

/// Run a line operator (`op.indent`, `op.comment`, …) once per line block.
pub fn onLines(cmd: []const u8) void {
    if (!sel.load()) return;
    var blocks: [max]weft.Range = undefined;
    const m = lineBlocks(&blocks);
    var handles: [max]?u32 = undefined;
    for (blocks[0..m], handles[0..m]) |b, *h| h.* = weft.anchorRange(b);
    // `3>` is one edit: the count loop is one undo unit, not three.
    weft.undoUnit(repeatOnLines, .{ cmd, handles[0..m], state.takeCount() });
    sel.flashAll();
    noteEdit();
}

fn repeatOnLines(cmd: []const u8, handles: []const ?u32, count: u32) void {
    var k = count;
    while (k > 0) : (k -= 1) weft.runRangeArgEach(cmd, handles);
}

/// `J`: join each selection's lines into one — or, for a selection on one
/// line, that line and the next. Each line break and the next line's indent
/// become a single space.
pub fn join() void {
    if (!sel.load()) return;
    var blocks: [max]weft.Range = undefined;
    const m = lineBlocks(&blocks);
    var handles: [max]?u32 = undefined;
    for (blocks[0..m], handles[0..m]) |*b, *h| {
        // Past the block's own last newline is the next line: a one-line
        // block joins with it.
        var end = b.end;
        if (weft.lineAt(b.start).end + 1 >= end) end = @min(weft.lineAt(@min(end, text.len())).end, text.len());
        h.* = weft.anchorRange(.{ .start = b.start, .end = @max(b.start, end) });
    }
    weft.runRangeArgEach("hx-op-join", handles[0..m]);
    sel.flashAll();
    noteEdit();
}

/// `hx-op-join`: collapse every line break inside the range (and the indent
/// after it) to one space, last first so earlier offsets hold.
pub fn opJoin() void {
    const h = weft.argRange(0) orelse return;
    const r = weft.rangeEnds(h) orelse return;
    text.begin();
    var end = r.end;
    // The range's own trailing newline, if any, is not a join point.
    if (end > r.start and text.at(end - 1) == '\n') end -= 1;
    var i = end;
    while (i > r.start) {
        i -= 1;
        if (text.at(i) != '\n') continue;
        var after = i + 1;
        while (text.at(after)) |c| {
            if (c != ' ' and c != '\t') break;
            after += 1;
        }
        const next_empty = text.at(after) == null or text.at(after) == '\n';
        weft.edit(.{ .start = i, .end = after }, if (next_empty) "" else " ");
    }
}

// ── Inserting ───────────────────────────────────────────────────────────

/// The ONE door into helix's insert-like state. An entry that declared a
/// non-`text` posture does not take it: the grammar declines instead of
/// parking the user where every key would be refused (§10.4).
pub fn enterInsert() void {
    switch (weft.posture()) {
        .text, .field => weft.setMode("helix-insert"),
        .structural, .capture => weft.echo("this entry takes no text"),
    }
}

/// Whether the entry's own text is what the keys edit. A focused field or a
/// listing owns its caret; helix moves only carets it holds.
pub fn onText() bool {
    return weft.posture() == .text;
}

/// Where each of `i a I A` puts a caret, from a selection.
pub const Entry = enum { before, after, line_start, line_end };

fn entryPoint(s: weft.Selection, where: Entry) usize {
    const r = sel.span(s);
    return switch (where) {
        .before => r.start,
        // After a caret on a line end is still before that line end.
        .after => if (s.anchor == s.head and text.at(s.head) == '\n') s.head else r.end,
        .line_start => text.firstNonBlank(r.start),
        .line_end => weft.lineAt(@max(r.start, r.end -| 1)).end,
    };
}

/// `i a I A`: a caret at the entry point of every selection, then type — at
/// all of them at once.
pub fn insertAt(where: Entry) void {
    if (onText() and sel.load()) {
        for (sel.items[0..sel.n]) |*s| s.* = sel.caret(entryPoint(s.*, where));
        sel.store();
    }
    enterInsert();
}

/// `o` / `O`: open a line below (above) every selection, indented like its
/// own, and type there. A structured view answers the insertion intention (a
/// new row) instead.
pub fn openLine(below: bool) void {
    if (weft.invokeIntention(if (below) "std.editing.insert-after" else "std.editing.insert-before") == .invoked) return enterInsert();
    if (!onText() or !sel.load()) return enterInsert();
    var points: [max]weft.Range = undefined;
    for (sel.items[0..sel.n], points[0..sel.n]) |s, *p| {
        const r = sel.span(s);
        const at = if (below) weft.lineAt(@max(r.start, r.end -| 1)).end else weft.lineAt(r.start).start;
        p.* = .{ .start = at, .end = at };
    }
    putEach(points[0..sel.n], .{ .open = if (below) .below else .above }, null);
    for (sel.items[0..sel.n], 0..) |*s, i| {
        const w = wrote(i) orelse continue;
        s.* = sel.caret(if (below) w.end else w.end - 1);
    }
    sel.store();
    enterInsert();
}

/// `[ space` / `] space`: a blank line above (below) every selection, the
/// selections left where they are.
pub fn addBlankLine(below: bool) void {
    if (!sel.load()) return;
    var points: [max]weft.Range = undefined;
    for (sel.items[0..sel.n], points[0..sel.n]) |s, *p| {
        const r = sel.span(s);
        const at = if (below) weft.lineAt(@max(r.start, r.end -| 1)).end else weft.lineAt(r.start).start;
        p.* = .{ .start = at, .end = at };
    }
    weft.undoUnit(repeatBlankLine, .{ points[0..sel.n], state.takeCount() });
}

fn repeatBlankLine(points: []const weft.Range, count: u32) void {
    var k = count;
    while (k > 0) : (k -= 1) putEach(points, .{ .literal = "\n" }, null);
}

// ── Surround (the `surround` plugin, per selection) ─────────────────────

pub const SurroundVerb = enum { add, delete, replace };

/// Choose the pair, then surround every selection. Adding wraps each on its
/// own; deleting and replacing PLAN every selection's pair on the untouched
/// text first, so two selections inside one pair edit it once (the
/// `surround` plugin's module doc), then apply the plan as one undo unit.
pub fn surround(verb: SurroundVerb, pair: []const u8, replacement: ?[]const u8) void {
    if (!sel.load()) return;
    if (replacement) |r| weft.runStr2("surround-pair", pair, r) else weft.runStr("surround-pair", pair);
    var handles: [max]?u32 = undefined;
    for (sel.items[0..sel.n], handles[0..sel.n]) |s, *h| h.* = weft.anchorRange(sel.span(s));
    switch (verb) {
        .add => weft.runRangeArgEach("surround.add", handles[0..sel.n]),
        .delete, .replace => {
            weft.runRangeArgEach("surround.plan", handles[0..sel.n]);
            weft.runStr("surround.apply", @tagName(verb));
        },
    }
    sel.flashAll();
    noteEdit();
}
