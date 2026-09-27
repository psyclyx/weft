//! ide — the CONVENTIONAL keymap (doc/configs.md §3.2) as a `.wasm` plugin,
//! perms `{clipboard}` grant_max edit. Built in emacs's mold: ONE resting
//! mode, `ide`, that falls back to the core `default` floor and commits typed
//! text, plus `ide-structural` for entries that take no text. What it adds over the
//! floor is the keyboard grammar every desktop editor shares: shift extends
//! the selection and a plain move collapses it, Home is smart, Tab indents
//! what is selected, C-c/C-x/C-v transfer.
//!
//! Its point is the dispatch tier more than the keys. Every operation a
//! standard intention names binds the INTENTION first and this plugin's text
//! command as the fallback arm, so the same key copies a row in the files
//! sidebar, activates a git row, and copies text in a buffer — with no
//! sidebar- or git-specific code here. Selection is core's mark model
//! (mark..cursor); motions are composed from the `motions` plugin by name.
//! Delete this plugin and weft is still modeless — `default` is the floor.
//!
//! The pointer is part of the grammar too: a double click selects a word, a
//! triple click the line, and C-click adds a caret — each reading WHERE from
//! the pointer facts of the gesture, never working a position out itself.
//! Copy and cut put the unnamed register on the system clipboard as well,
//! when the config grants `clipboard` and says the unnamed register mirrors
//! it; paste then takes the clipboard when something else put different
//! text there. Long moves (the ends of the buffer, a line
//! by number, a definition) leave a jump behind for M-Left to return to.
//!
//! EVERY SELECTION. C-d, C-S-l and C-click make several; every key here then
//! acts at each of them — moves map over the set, and the edits (transfer,
//! Tab, C-S-k, C-Return) are one `put` library write per selection, one undo
//! unit. M-Up/Down alone collapse to the primary first: two moved blocks
//! could swap into each other.

const std = @import("std");
const weft = @import("weft");
const put = @import("weft_put");

const file_pick = 0;
const path_pick = 1;
const line_pick = 2;

/// The put operator this grammar registers (`put.run`).
const put_op = "ide-op-put";

// ── The selection set ────────────────────────────────────────────────
// Read once per command into a private copy (the SDK's read scratch is
// reused by the next read), reshaped, and handed back whole: core
// normalizes it — sorted, overlaps and meeting carets merged.

const max = weft.max_selections;
var sels: [max]weft.Selection = undefined;
var sel_n: usize = 0;
var sel_primary: usize = 0;

fn load() bool {
    const set = weft.selections();
    sel_n = set.items.len;
    if (sel_n == 0) return false;
    @memcpy(sels[0..sel_n], set.items);
    sel_primary = set.primary;
    return true;
}

fn store() void {
    _ = weft.setSelections(sels[0..sel_n], sel_primary);
}

fn caret(at: usize) weft.Selection {
    return .{ .anchor = at, .head = at };
}

/// Whether every selection is a bare caret.
fn allCarets() bool {
    for (sels[0..sel_n]) |s| if (s.anchor != s.head) return false;
    return true;
}

/// Drop the selection, if any.
fn collapse() void {
    weft.run("clear-selection");
}

// ── Moves: plain collapses, shifted extends, at every selection ──────

const Target = enum { left, right, up, down, word_left, word_right, home, end, doc_start, doc_end };

/// Smart home: the first non-blank of the line, or column 0 when already
/// there — so a second press reaches the margin.
fn homeOf(head: usize) usize {
    const l = weft.lineAt(head);
    const t = weft.slice(l.start, l.end);
    var i: usize = 0;
    while (i < t.len and (t[i] == ' ' or t[i] == '\t')) i += 1;
    return if (head == l.start + i) l.start else l.start + i;
}

/// Where a `motions` range lands from `head`: the end that isn't `head`,
/// which carries the direction; `head` itself when there is no range.
fn motionEnd(head: usize, handle: ?u32) usize {
    const r = weft.rangeEnds(handle orelse return head) orelse return head;
    return if (r.end == head) r.start else r.end;
}

/// Move every selection's head to `t`: collapsed to a caret there (plain),
/// or with its anchor kept (shifted — a caret's anchor is where it was). A
/// plain Left/Right over a selection lands on its near edge instead of
/// moving one further, the convention every desktop editor shares.
fn moveAll(t: Target, extend: bool) void {
    // One caret moving vertically stays core's: it owns the sticky visual
    // column. Several step by byte column, each on its own line.
    if ((t == .up or t == .down) and weft.selectionCount() == 1) {
        if (!extend) collapse() else if (weft.selection() == null) weft.run("set-mark");
        return weft.run(if (t == .up) "cursor-up" else "cursor-down");
    }
    if (!load()) return;
    var words: [max]?u32 = undefined;
    const hops: []?u32 = switch (t) {
        .word_left => weft.runRangeEach("motion.word-back", &words),
        .word_right => weft.runRangeEach("motion.word-fwd", &words),
        else => words[0..0],
    };
    for (sels[0..sel_n], 0..) |*s, i| {
        const r = s.range();
        const edge = !extend and r.start != r.end;
        const to: usize = switch (t) {
            .left => if (edge) r.start else weft.step(s.head, .back, .char),
            .right => if (edge) r.end else weft.step(s.head, .fwd, .char),
            .up => weft.step(s.head, .back, .line),
            .down => weft.step(s.head, .fwd, .line),
            .word_left, .word_right => motionEnd(s.head, if (i < hops.len) hops[i] else null),
            .home => homeOf(s.head),
            .end => weft.lineAt(s.head).end,
            .doc_start => 0,
            .doc_end => weft.byteLen(),
        };
        s.* = if (extend) .{ .anchor = s.anchor, .head = to } else caret(to);
    }
    store();
}

/// A move as its two commands, plain and shifted.
fn Move(comptime t: Target) type {
    return struct {
        fn plain() void {
            moveAll(t, false);
        }
        fn extend() void {
            moveAll(t, true);
        }
    };
}

const left = Move(.left);
const right = Move(.right);
const up = Move(.up);
const down = Move(.down);
const word_right = Move(.word_right);
const word_left = Move(.word_left);
const home = Move(.home);
const end_of_line = Move(.end);
const doc_start = Move(.doc_start);
const doc_end = Move(.doc_end);

/// C-Home / C-End: a long move, so where it started is a jump to come back to.
fn docStartJump() void {
    weft.jumpPush();
    doc_start.plain();
}
fn docEndJump() void {
    weft.jumpPush();
    doc_end.plain();
}

/// F12: leave a jump here, then ask the language server where to go.
fn gotoDefinition() void {
    weft.jumpPush();
    weft.run("goto-definition");
}

fn selectAll() void {
    _ = weft.setSelections(&.{.{ .anchor = 0, .head = weft.byteLen() }}, 0);
}

/// Escape: back to one caret, drop the selection, and leave a capture posture
/// if one holds the entry — so the key a user reaches for first is always a
/// way out.
fn escape() void {
    if (weft.selectionCount() > 1) _ = weft.collapseSelections();
    collapse();
    if (weft.posture() == .capture) _ = weft.invokeIntention("std.input.break-out");
}

// ── Occurrences: C-d adds the next match, C-S-l selects them all ─────
// Literal, case-sensitive matching over the document. Core holds the
// selections (doc/configs.md §0.1); typing, deleting and pasting then act at
// every one of them as ONE undo unit, so nothing here edits anything.

/// Longest needle an occurrence command looks for.
const needle_max = 1024;
var needle_buf: [needle_max]u8 = undefined;

/// Bytes read per `slice` while searching — under the SDK's 64 KiB scratch
/// with room for a needle's overlap between windows.
const window = 1 << 15;

/// The word rule `\b` and the word motions share.
const isWordByte = @import("weft_regex").isWordByte;

/// The word around `at` (touching it on either side), or null on none.
fn wordAround(at: usize) ?weft.Range {
    const line = weft.lineAt(at);
    const text = weft.slice(line.start, line.end);
    const col = at - line.start;
    var s = col;
    while (s > 0 and isWordByte(text[s - 1])) s -= 1;
    var e = col;
    while (e < text.len and isWordByte(text[e])) e += 1;
    if (s == e) return null;
    return .{ .start = line.start + s, .end = line.start + e };
}

/// The first match of `needle` STARTING in `[from, to)`, or null.
fn findIn(needle: []const u8, from: usize, to: usize) ?usize {
    const len = weft.byteLen();
    var pos = from;
    while (pos < to) {
        const end = @min(len, pos + window + needle.len - 1);
        if (std.mem.indexOf(u8, weft.slice(pos, end), needle)) |i| {
            const at = pos + i;
            return if (at < to) at else null;
        }
        if (end >= len) return null;
        pos += window;
    }
    return null;
}

fn overlapsAny(items: []const weft.Selection, r: weft.Range) bool {
    for (items) |s| {
        const q = s.range();
        if (r.start < q.end and q.start < r.end) return true;
    }
    return false;
}

/// The primary selection's text as the needle, copied out of the scratch
/// every read shares. With a bare caret there is no needle yet: the word
/// under it becomes the selection, and that press is spent selecting it —
/// the convention every editor with this key shares.
fn needleOrSelectWord() ?[]const u8 {
    const set = weft.selections();
    if (set.items.len == 0) return null;
    const primary = set.items[set.primary].range();
    if (primary.start == primary.end) {
        const w = wordAround(primary.start) orelse return null;
        set.items[set.primary] = .{ .anchor = w.start, .head = w.end };
        _ = weft.setSelections(set.items, set.primary);
        weft.flash(w.start, w.end);
        return null;
    }
    const n = primary.end - primary.start;
    if (n > needle_max) {
        weft.echo("add next match: the selection is too long to search for");
        return null;
    }
    @memcpy(needle_buf[0..n], weft.slice(primary.start, primary.end));
    return needle_buf[0..n];
}

/// C-d: add the next occurrence of the primary selection's text after it
/// (wrapping at the end) as a new primary selection. An occurrence already
/// selected is skipped; when every one is, nothing changes.
fn addNextMatch() void {
    const needle = needleOrSelectWord() orelse return;
    const set = weft.selections();
    const after = set.items[set.primary].range().end;
    const len = weft.byteLen();
    // Past the primary to the end, then from the top back round to it.
    const spans = [_][2]usize{ .{ after, len }, .{ 0, after } };
    for (spans) |span| {
        var from = span[0];
        while (findIn(needle, from, span[1])) |at| {
            const hit: weft.Range = .{ .start = at, .end = at + needle.len };
            if (!overlapsAny(weft.selections().items, hit)) {
                _ = weft.addSelection(.{ .anchor = hit.start, .head = hit.end });
                weft.flash(hit.start, hit.end);
                return;
            }
            from = at + 1;
        }
    }
}

var all_items: [weft.max_selections]weft.Selection = undefined;
var all_ranges: [weft.max_selections]weft.Range = undefined;

/// C-S-l: select every occurrence of the primary selection's text (or of the
/// word under the caret), keeping the one the caret was on primary.
fn selectAllMatches() void {
    var needle = needleOrSelectWord();
    if (needle == null) {
        // The press that selected a word goes on to select its twins too.
        const set = weft.selections();
        if (set.items.len == 0) return;
        const w = set.items[set.primary].range();
        if (w.start == w.end or w.end - w.start > needle_max) return;
        @memcpy(needle_buf[0 .. w.end - w.start], weft.slice(w.start, w.end));
        needle = needle_buf[0 .. w.end - w.start];
    }
    const n = needle.?;
    const before = weft.selections();
    const origin = before.items[before.primary].range().start;
    var count: usize = 0;
    var primary: usize = 0;
    var from: usize = 0;
    const len = weft.byteLen();
    while (count < all_items.len) {
        const at = findIn(n, from, len) orelse break;
        if (at == origin) primary = count;
        all_items[count] = .{ .anchor = at, .head = at + n.len };
        count += 1;
        from = at + n.len;
    }
    if (count == 0) return;
    _ = weft.setSelections(all_items[0..count], primary);
    // ONE flash over the set: each `flash` call starts a new one.
    for (all_items[0..count], all_ranges[0..count]) |s, *r| r.* = s.range();
    weft.flashRanges(all_ranges[0..count]);
}

// ── The pointer ──────────────────────────────────────────────────────
// Where a gesture happened is a FACT of its dispatch (`weft.pointer()`): the
// byte offset under the pointer in text, or none over a scene. The single
// click before a double click already focused the pane and placed the caret
// (`pointer-click`, the floor's `mouse-1`); these only widen what it did.

fn pointerOffset() ?usize {
    const p = weft.pointer() orelse return null;
    return p.offset;
}

/// double-mouse-1: select the word under the pointer. Over a scene (a
/// listing row) there is no word: a double click opens the row instead.
fn selectWordAtPointer() void {
    const off = pointerOffset() orelse return weft.run("pointer-activate");
    const w = wordAround(off) orelse return;
    weft.setSelection(w);
}

/// triple-mouse-1: select the line under the pointer, with its line break.
fn selectLineAtPointer() void {
    const off = pointerOffset() orelse return;
    const l = weft.lineAt(off);
    weft.setSelection(.{ .start = l.start, .end = if (l.end < weft.byteLen()) l.end + 1 else l.end });
}

/// C-mouse-1: add a caret at the pointer, keeping the ones already there.
fn addCaretAtPointer() void {
    weft.run("pointer-focus-pane");
    const off = pointerOffset() orelse return;
    _ = weft.addSelection(.{ .anchor = off, .head = off });
}

// ── Line blocks ──────────────────────────────────────────────────────

/// The whole lines selection `s` covers, or its caret's line (end before the
/// last line's break). A selection ending at column 0 does not claim the
/// line it ends on.
fn linesOf(s: weft.Selection) weft.Range {
    const r = s.range();
    const last = if (r.end > r.start and weft.lineAt(r.end).start == r.end) r.end - 1 else r.end;
    return .{ .start = weft.lineAt(r.start).start, .end = weft.lineAt(last).end };
}

/// Every loaded selection's lines as blocks in document order. A block that
/// shares or touches the one before is merged into it, so no line is edited
/// twice and no two blocks' edits overlap.
fn lineBlocks(out: []weft.Range) usize {
    var m: usize = 0;
    for (sels[0..sel_n]) |s| {
        const b = linesOf(s);
        if (m > 0 and b.start <= out[m - 1].end + 1) {
            out[m - 1].end = @max(out[m - 1].end, b.end);
        } else {
            out[m] = b;
            m += 1;
        }
    }
    return m;
}

/// The primary selection's lines — the one block M-Up/Down move.
fn lineBlock() weft.Range {
    const set = weft.selections();
    if (set.items.len == 0) return .{ .start = 0, .end = 0 };
    return linesOf(set.items[set.primary]);
}

/// Run a range operator (`op.indent`, `op.dedent`) over every selection's
/// lines, as one undo unit. A selection is left over its lines, so Tab can
/// be pressed again; a caret stays a caret.
fn overSelectedLines(comptime op: []const u8) void {
    if (!load()) return;
    var blocks: [max]weft.Range = undefined;
    const m = lineBlocks(&blocks);
    var handles: [max]?u32 = undefined;
    for (blocks[0..m], handles[0..m]) |b, *h| h.* = weft.anchorRange(b);
    // Where each selection ends up, carried through the edit by anchors.
    var keep: [max]?u32 = undefined;
    for (sels[0..sel_n], keep[0..sel_n]) |s, *k| k.* = weft.anchorRange(if (s.anchor == s.head) s.range() else linesOf(s));
    weft.runRangeArgEach(op, handles[0..m]);
    for (sels[0..sel_n], keep[0..sel_n]) |*s, k| {
        const r = weft.rangeEnds(k orelse continue) orelse continue;
        s.* = if (s.anchor == s.head) caret(r.start) else .{ .anchor = r.start, .head = r.end };
    }
    store();
}

/// Tab: indent the selected lines; with only carets, the floor's tab (which
/// types at every caret).
fn indent() void {
    if (!load()) return;
    if (allCarets()) return weft.run("insert-tab");
    overSelectedLines("op.indent");
}
/// S-Tab: dedent the selected lines, or each caret's line.
fn dedent() void {
    overSelectedLines("op.dedent");
}

/// Line text copies: `slice` borrows one scratch, and a swap needs two
/// spans at once. Lines longer than this are left where they are.
var move_a: [1 << 15]u8 = undefined;
var move_b: [1 << 15]u8 = undefined;
var move_out: [(1 << 16) + 1]u8 = undefined;

/// Swap the primary's block with the line below (`down`) or above, as ONE
/// edit, so the move is one undo unit. The cursor and selection travel with
/// it. The one key that does not map over the selections: two blocks moving
/// at once could swap into each other, so the others collapse first.
fn moveBlock(down_dir: bool) void {
    if (weft.selectionCount() > 1) _ = weft.collapseSelections();
    const block = lineBlock();
    const len = weft.byteLen();
    const other = if (down_dir) blk: {
        if (block.end >= len) return;
        const l = weft.lineAt(block.end + 1);
        break :blk weft.Range{ .start = l.start, .end = l.end };
    } else blk: {
        if (block.start == 0) return;
        const l = weft.lineAt(block.start - 1);
        break :blk weft.Range{ .start = l.start, .end = l.end };
    };
    const a_len = block.end - block.start;
    const b_len = other.end - other.start;
    if (a_len > move_a.len or b_len > move_b.len) return;
    @memcpy(move_a[0..a_len], weft.slice(block.start, block.end));
    @memcpy(move_b[0..b_len], weft.slice(other.start, other.end));
    const first = if (down_dir) move_b[0..b_len] else move_a[0..a_len];
    const second = if (down_dir) move_a[0..a_len] else move_b[0..b_len];
    @memcpy(move_out[0..first.len], first);
    move_out[first.len] = '\n';
    @memcpy(move_out[first.len + 1 ..][0..second.len], second);
    const out = move_out[0 .. first.len + 1 + second.len];

    const sel = weft.selection();
    const cur = weft.cursor();
    const span: weft.Range = if (down_dir)
        .{ .start = block.start, .end = other.end }
    else
        .{ .start = other.start, .end = block.end };
    weft.edit(span, out);
    // Everything in the block shifted by the other line and its newline.
    const shift = b_len + 1;
    const moved = struct {
        fn at(off: usize, by: usize, fwd: bool) usize {
            return if (fwd) off + by else off - by;
        }
    }.at;
    if (sel) |s| {
        // `setSelection` is mark-then-cursor, so the far end goes first and
        // the selection keeps the direction it was made in.
        const mark = if (cur == s.start) s.end else s.start;
        weft.setSelection(.{ .start = moved(mark, shift, down_dir), .end = moved(cur, shift, down_dir) });
    } else weft.jump(moved(cur, shift, down_dir));
}
fn moveLineUp() void {
    moveBlock(false);
}
fn moveLineDown() void {
    moveBlock(true);
}

/// Keep `m` of the loaded selections (the rest merged away by an edit), the
/// primary clamped into them.
fn keepFirst(m: usize) void {
    sel_n = m;
    sel_primary = @min(sel_primary, m -| 1);
}

/// C-S-k: delete every selection's lines, line break included, into no
/// register — one undo unit, a caret left where each block was.
fn deleteLine() void {
    if (!load()) return;
    var spans: [max]weft.Range = undefined;
    const m = lineBlocks(&spans);
    const len = weft.byteLen();
    for (spans[0..m]) |*b| {
        if (b.end < len) {
            b.end += 1;
        } else if (b.start > 0) b.start -= 1;
    }
    put.each(put_op, spans[0..m], .{ .literal = "" }, null);
    keepFirst(m);
    for (sels[0..m], 0..) |*s, i| s.* = caret((put.wrote(i) orelse spans[i]).start);
    store();
}

var open_below = true;

fn opening(_: usize, r: weft.Range) ?[]const u8 {
    return put.lineOpening(r.start, open_below);
}

/// C-Return / C-S-Return: a fresh line below / above each selection's line,
/// at that line's indent, wherever the caret sat on it — a caret on each.
fn openLine(below: bool) void {
    if (!load()) return;
    var points: [max]weft.Range = undefined;
    var m: usize = 0;
    for (sels[0..sel_n]) |s| {
        const l = weft.lineAt(s.head);
        const at = if (below) l.end else l.start;
        if (m > 0 and points[m - 1].start == at) continue;
        points[m] = .{ .start = at, .end = at };
        m += 1;
    }
    open_below = below;
    put.each(put_op, points[0..m], .{ .derive = opening }, null);
    keepFirst(m);
    for (sels[0..m], 0..) |*s, i| {
        const w = put.wrote(i) orelse continue;
        // Below, the new line is all of what was written; above, it ends
        // before the line break that follows it.
        s.* = caret(if (below) w.end else w.end - 1);
    }
    store();
}
fn openBelow() void {
    openLine(true);
}
fn openAbove() void {
    openLine(false);
}

// ── Transfer: the text arm behind the std.transfer.* intentions ──────
// The register is core's shared one (the same `dd`/`p` and emacs's kill ring
// use), so a row cut in the sidebar and text copied here share one ferry.
// It holds one value per selection (`yankEachIn`), and a paste hands them
// back out by core's rule. With only carets, copy and cut take each caret's
// whole line, linewise — the convention that makes C-x C-v a line move.

/// The line `at` is on, with its line break, for a linewise transfer.
fn wholeLine(at: usize) weft.Range {
    const l = weft.lineAt(at);
    return .{ .start = l.start, .end = if (l.end < weft.byteLen()) l.end + 1 else l.end };
}

/// What copy and cut take from the loaded selections, into `out` in
/// document order: each caret's whole line (a line two carets share, once)
/// when there are only carets — `linewise` — else every selection's text.
fn transferRanges(out: []weft.Range, linewise: *bool) usize {
    linewise.* = allCarets();
    var m: usize = 0;
    for (sels[0..sel_n]) |s| {
        const r = if (linewise.*) wholeLine(s.head) else s.range();
        if (linewise.* and m > 0 and out[m - 1].start == r.start) continue;
        out[m] = r;
        m += 1;
    }
    return m;
}

/// Whether the unnamed register mirrors the system clipboard: the config
/// says so (`weft.set("ide", "clipboard", "unnamed")`) beside the grant that
/// makes it possible. Asked rather than assumed, because the clipboard doors
/// TRAP without the grant — and C-c, C-x and C-v must work either way.
fn mirrorsClipboard() bool {
    return std.mem.eql(u8, weft.config("clipboard"), "unnamed");
}

/// The unnamed register onto the system clipboard — ide's register IS the
/// clipboard's twin (vim keeps `"+` apart instead).
fn mirrorToClipboard() void {
    if (!mirrorsClipboard()) return;
    _ = weft.clipboardSet(weft.registerTextIn(0));
}

fn copy() void {
    if (!load()) return;
    var ranges: [max]weft.Range = undefined;
    var lines = false;
    const m = transferRanges(&ranges, &lines);
    weft.yankEachIn(0, ranges[0..m], lines);
    weft.flashRanges(ranges[0..m]);
    mirrorToClipboard();
}

/// C-x: copy, then delete what was copied at every selection as one undo
/// unit, a caret left where each one was.
fn cut() void {
    if (!load()) return;
    var ranges: [max]weft.Range = undefined;
    var lines = false;
    const m = transferRanges(&ranges, &lines);
    weft.yankEachIn(0, ranges[0..m], lines);
    mirrorToClipboard();
    put.each(put_op, ranges[0..m], .{ .literal = "" }, null);
    keepFirst(m);
    for (sels[0..m], 0..) |*s, i| s.* = caret((put.wrote(i) orelse ranges[i]).start);
    store();
}

/// C-v, at every selection, as one undo unit: over each selection, or at
/// each caret — a linewise register above the caret's line, whole, when
/// every selection is a caret. The register hands out its values by core's
/// rule: one each when the counts match, else all of them everywhere.
///
/// When the clipboard holds something else — text another program copied —
/// that is what the user means, and it goes in at every selection the same
/// way, as typing would. When it still holds the register's text
/// (`weft.clipboardPasteSource`, the rule helix and vim paste by too), the
/// register pastes, which keeps a cut-and-paste a MOVE (its ferried ids)
/// and a linewise yank linewise.
fn paste() void {
    if (!load()) return;
    if (mirrorsClipboard()) switch (weft.clipboardPasteSource()) {
        .foreign => |clip| return pasteFrom(.{ .literal = clip }, false),
        .unavailable, .empty, .register => {},
    };
    if (weft.registerTextIn(0).len == 0) return;
    const lines = weft.registerLinewiseIn(0) and allCarets();
    pasteFrom(.{ .register = .{ .slot = 0, .count = sel_n, .line = lines } }, lines);
}

/// Put `src` at every loaded selection — over it, or (`lines`) at the start
/// of each caret's line — and leave a caret after what landed (a line paste:
/// where it was, moved down with its line).
fn pasteFrom(src: put.Source, lines: bool) void {
    var spots: [max]weft.Range = undefined;
    for (sels[0..sel_n], spots[0..sel_n]) |s, *spot| {
        const at = weft.lineAt(s.head).start;
        spot.* = if (lines) .{ .start = at, .end = at } else s.range();
    }
    put.each(put_op, spots[0..sel_n], src, null);
    for (sels[0..sel_n], spots[0..sel_n], 0..) |*s, spot, i| {
        const w = put.wrote(i) orelse continue;
        s.* = caret(if (lines) w.end + (s.head - spot.start) else w.end);
    }
    store();
}

// ── Opening and jumping (the pickers this grammar owns) ──────────────

/// C-p: fuzzy-open a project file (the native recursive finder).
fn quickOpen() void {
    weft.pickCategory("file");
    weft.openFilePick("open", ".", file_pick);
}
/// C-o: open a path as typed — including one that does not exist yet.
fn openPath() void {
    weft.pickBegin("open path", path_pick);
    weft.pickFreeText();
    weft.pickEnd();
}
/// C-g: go to a line by number.
fn gotoLine() void {
    weft.pickBegin("go to line", line_pick);
    weft.pickFreeText();
    weft.pickEnd();
}

/// Put one caret at the start of 1-based line `number`, clamped to the last,
/// leaving a jump where it was.
fn jumpToLine(number: usize) void {
    weft.jumpPush();
    _ = weft.setSelections(&.{caret(weft.lineStart(number))}, 0);
}

/// C-b: show or hide the docked viewport this config names (`weft.set("ide",
/// "sidebar", …)`, default `sidebar`) through core's generic viewport door.
fn toggleSidebar() void {
    const name = weft.config("sidebar");
    weft.runStr("viewport-toggle", if (name.len > 0) name else "sidebar");
}

fn onPickAccept(pick_id: u32) void {
    var outcome = (weft.pickOutcome(weft.allocator) catch return) orelse return;
    defer outcome.deinit(weft.allocator);
    const text = switch (outcome) {
        .candidate => |candidate| candidate.text,
        .input => |input| input,
        .cancelled => return,
    };
    const trimmed = std.mem.trim(u8, text, " \t");
    if (trimmed.len == 0) return;
    switch (pick_id) {
        file_pick, path_pick => weft.runStr("open", trimmed),
        line_pick => jumpToLine(std.fmt.parseInt(usize, trimmed, 10) catch {
            weft.echo("go to line: not a line number");
            return;
        }),
        else => {},
    }
}

// ── Command table (registration order == on_command id) ──
const cmds = [_]weft.CommandEntry{
    .{ .name = "ide-left", .call = left.plain, .summary = "move left, or collapse the selection to its start" },
    .{ .name = "ide-right", .call = right.plain, .summary = "move right, or collapse the selection to its end" },
    .{ .name = "ide-up", .call = up.plain, .summary = "collapse the selection and move up" },
    .{ .name = "ide-down", .call = down.plain, .summary = "collapse the selection and move down" },
    .{ .name = "ide-word-left", .call = word_left.plain, .summary = "move to the previous word" },
    .{ .name = "ide-word-right", .call = word_right.plain, .summary = "move to the next word" },
    .{ .name = "ide-home", .call = home.plain, .summary = "move to the first non-blank, then to column 0" },
    .{ .name = "ide-end", .call = end_of_line.plain, .summary = "move to the end of the line" },
    .{ .name = "ide-doc-start", .call = docStartJump, .summary = "move to the start of the buffer (a jump)" },
    .{ .name = "ide-doc-end", .call = docEndJump, .summary = "move to the end of the buffer (a jump)" },
    .{ .name = "ide-select-left", .call = left.extend, .summary = "extend the selection left" },
    .{ .name = "ide-select-right", .call = right.extend, .summary = "extend the selection right" },
    .{ .name = "ide-select-up", .call = up.extend, .summary = "extend the selection up" },
    .{ .name = "ide-select-down", .call = down.extend, .summary = "extend the selection down" },
    .{ .name = "ide-select-word-left", .call = word_left.extend, .summary = "extend the selection to the previous word" },
    .{ .name = "ide-select-word-right", .call = word_right.extend, .summary = "extend the selection to the next word" },
    .{ .name = "ide-select-home", .call = home.extend, .summary = "extend the selection to the smart line start" },
    .{ .name = "ide-select-end", .call = end_of_line.extend, .summary = "extend the selection to the line end" },
    .{ .name = "ide-select-doc-start", .call = doc_start.extend, .summary = "extend the selection to the buffer start" },
    .{ .name = "ide-select-doc-end", .call = doc_end.extend, .summary = "extend the selection to the buffer end" },
    .{ .name = "ide-select-all", .call = selectAll, .summary = "select the whole buffer" },
    .{ .name = "ide-escape", .call = escape, .summary = "drop the selection, or break out of a capture" },
    .{ .name = "ide-indent", .call = indent, .summary = "indent the selected lines, or insert a tab" },
    .{ .name = "ide-dedent", .call = dedent, .summary = "dedent the selected lines" },
    .{ .name = "ide-move-line-up", .call = moveLineUp, .summary = "move the line (or selected lines) up" },
    .{ .name = "ide-move-line-down", .call = moveLineDown, .summary = "move the line (or selected lines) down" },
    .{ .name = "ide-delete-line", .call = deleteLine, .summary = "delete the line (or selected lines)" },
    .{ .name = "ide-open-below", .call = openBelow, .summary = "start a new line below this one" },
    .{ .name = "ide-open-above", .call = openAbove, .summary = "start a new line above this one" },
    .{ .name = "ide-copy", .call = copy, .summary = "copy the selection (or the line)" },
    .{ .name = "ide-cut", .call = cut, .summary = "cut the selection (or the line)" },
    .{ .name = "ide-paste", .call = paste, .summary = "paste over the selection, or at the cursor" },
    .{ .name = "quick-open", .call = quickOpen, .summary = "fuzzy-open a project file" },
    .{ .name = "open-path", .call = openPath, .summary = "open a file by typed path" },
    .{ .name = "goto-line", .call = gotoLine, .summary = "go to a line by number" },
    .{ .name = "ide-toggle-sidebar", .call = toggleSidebar, .summary = "show or hide the docked sidebar" },
    .{ .name = "ide-add-next-match", .call = addNextMatch, .summary = "select the word, then add the next occurrence of the selection" },
    .{ .name = "ide-select-all-matches", .call = selectAllMatches, .summary = "select every occurrence of the selection" },
    .{ .name = "ide-select-word-at-pointer", .call = selectWordAtPointer, .summary = "select the word under the pointer (a scene row: open it)" },
    .{ .name = "ide-select-line-at-pointer", .call = selectLineAtPointer, .summary = "select the line under the pointer" },
    .{ .name = "ide-add-caret-at-pointer", .call = addCaretAtPointer, .summary = "add a caret at the pointer" },
    .{ .name = "ide-goto-definition", .call = gotoDefinition, .summary = "leave a jump, then go to the definition" },
    // The operator the transfer and line keys write through (`put.each`).
    .{ .name = put_op, .call = put.run },
};

fn initExtra() void {
    // The one resting mode: `ide` inherits the `default` floor's BINDINGS
    // (BackSpace, Delete, Return's activate-else-break list, C-q) and
    // declares that it commits typed text — a declaration, never inherited.
    weft.setFallback("ide", "default");
    weft.textInput("ide", "insert-text");

    // §10.4: a modeless grammar's resting mode commits text, so a structural
    // entry needs a second state that does not. `ide-structural` inherits
    // every ide key by fallback and declares no commit, so the letters in a
    // listing can never leak into it.
    weft.setFallback("ide-structural", "ide");
    weft.setFallback("ide-source", "ide");
    // A document's code chords layer over `ide` by declaration. The
    // structural layer needs none: ide RESTS in `ide-structural` there.
    weft.bindingVariant(.source, "ide", "ide-source");
    weft.restingPosture(.text, "ide");
    weft.restingPosture(.structural, "ide-structural");
    // The break-out capture can never take away, retained in both resting
    // states (§10.4). Escape reaches it too, from a capture.
    for ([_][]const u8{ "ide", "ide-structural" }) |m|
        weft.bindKeys(m, "C-backslash", &.{"std.input.break-out"});

    // INTENTION FIRST, TEXT SECOND. Each list leads with the standard word
    // the focused view may answer (a listing row, a git row, a field) and
    // falls back to this plugin's text command where nothing offers it — so
    // one key serves every entry without this file knowing what any is.
    const intended = [_]struct { key: []const u8, arms: []const []const u8 }{
        .{ .key = "Left", .arms = &.{ "std.navigation.left", "ide-left" } },
        .{ .key = "Right", .arms = &.{ "std.navigation.right", "ide-right" } },
        .{ .key = "Up", .arms = &.{ "std.navigation.up", "ide-up" } },
        .{ .key = "Down", .arms = &.{ "std.navigation.down", "ide-down" } },
        .{ .key = "C-Left", .arms = &.{ "std.navigation.word-previous", "ide-word-left" } },
        .{ .key = "C-Right", .arms = &.{ "std.navigation.word-next", "ide-word-right" } },
        .{ .key = "Home", .arms = &.{ "std.navigation.line-start", "ide-home" } },
        .{ .key = "End", .arms = &.{ "std.navigation.line-end", "ide-end" } },
        // Tab folds a row that has children; in text it indents.
        .{ .key = "Tab", .arms = &.{ "std.hierarchy.toggle-expanded", "ide-indent" } },
        .{ .key = "C-c", .arms = &.{ "std.transfer.yank", "ide-copy" } },
        .{ .key = "C-x", .arms = &.{ "std.transfer.delete-to-register", "ide-cut" } },
        .{ .key = "C-v", .arms = &.{ "std.transfer.paste", "ide-paste" } },
        .{ .key = "C-z", .arms = &.{ "std.history.undo", "undo" } },
        .{ .key = "C-S-z", .arms = &.{ "std.history.redo", "redo" } },
        .{ .key = "C-y", .arms = &.{ "std.history.redo", "redo" } },
    };
    for (intended) |b| weft.bindKeys("ide", b.key, b.arms);
    // In a listing Tab is fold-or-nothing: never a character (GATE 2).
    weft.bindKeys("ide-structural", "Tab", &.{"std.hierarchy.toggle-expanded"});

    // Text-only keys: no standard word names these yet, so they bind the
    // text command outright. S-Tab arrives as ISO_Left_Tab on most layouts.
    const binds = [_][2][]const u8{
        .{ "S-Left", "ide-select-left" },                    .{ "S-Right", "ide-select-right" },
        .{ "S-Up", "ide-select-up" },                        .{ "S-Down", "ide-select-down" },
        .{ "C-S-Left", "ide-select-word-left" },             .{ "C-S-Right", "ide-select-word-right" },
        .{ "S-Home", "ide-select-home" },                    .{ "S-End", "ide-select-end" },
        .{ "C-Home", "ide-doc-start" },                      .{ "C-End", "ide-doc-end" },
        .{ "C-S-Home", "ide-select-doc-start" },             .{ "C-S-End", "ide-select-doc-end" },
        .{ "C-a", "ide-select-all" },                        .{ "Escape", "ide-escape" },
        .{ "S-Tab", "ide-dedent" },                          .{ "ISO_Left_Tab", "ide-dedent" },
        .{ "C-slash", "comment-selection" },                 .{ "M-Up", "ide-move-line-up" },
        .{ "M-Down", "ide-move-line-down" },                 .{ "C-S-k", "ide-delete-line" },
        .{ "C-Return", "ide-open-below" },                   .{ "C-S-Return", "ide-open-above" },
        .{ "C-d", "ide-add-next-match" },                    .{ "C-S-l", "ide-select-all-matches" },
        // The pointer's share of the grammar: what a second and third quick
        // click mean, and C-click's extra caret.
        .{ "double-mouse-1", "ide-select-word-at-pointer" }, .{ "triple-mouse-1", "ide-select-line-at-pointer" },
        .{ "C-mouse-1", "ide-add-caret-at-pointer" },
    };
    for (binds) |b| weft.bindKey("ide", b[0], b[1]);

    // A bar caret: a modeless editor is always between cells.
    for ([_][]const u8{ "ide", "ide-structural" }) |m| {
        weft.runStr2("set-cursor", m, "bar");
        weft.runStr2("cursor-blink", m, "on");
    }

    weft.setMode("ide");
}

comptime {
    // `.clipboard` is declared for the approval surface; only the config's
    // `weft.grant("ide", "clipboard")` confers it.
    weft.plugin(&cmds, .{ .init = initExtra, .pick = onPickAccept, .perms = &.{.clipboard} }).exportAll();
}
