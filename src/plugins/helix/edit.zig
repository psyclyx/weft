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

/// Remember where the primary selection is as the last place edited.
pub fn noteEdit() void {
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
    sel.flashPrimary();
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
    const lines = weft.registerLinewiseIn(slot);
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
    putEach(points[0..sel.n], .{ .register = .{ .slot = slot, .count = sel.n } }, newline[0..sel.n]);
    selectWritten();
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
    sel.flashPrimary();
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
    var k = state.takeCount();
    while (k > 0) : (k -= 1) weft.runRangeArgEach(cmd, handles[0..m]);
    sel.flashPrimary();
    noteEdit();
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
    sel.flashPrimary();
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
    var k = state.takeCount();
    while (k > 0) : (k -= 1) putEach(points[0..sel.n], .{ .literal = "\n" }, null);
}

// ── Surround (the `surround` plugin, per selection) ─────────────────────

/// Choose the pair, then run a surround operator over every selection.
pub fn surround(cmd: []const u8, pair: []const u8, replacement: ?[]const u8) void {
    if (!sel.load()) return;
    if (replacement) |r| weft.runStr2("surround-pair", pair, r) else weft.runStr("surround-pair", pair);
    var handles: [max]?u32 = undefined;
    for (sel.items[0..sel.n], handles[0..sel.n]) |s, *h| h.* = weft.anchorRange(sel.span(s));
    weft.runRangeArgEach(cmd, handles[0..sel.n]);
    sel.flashPrimary();
    noteEdit();
}
