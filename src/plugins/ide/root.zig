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
//! EVERY SELECTION. C-d, C-S-l and C-click make several, and every key here
//! then acts at each of them — not by looping: each command DECLARES how it
//! maps over the selection (doc/model.md §2.6) and dispatch runs it once per
//! selection, one undo unit, the register holding one value per selection.
//! The handlers below are one-selection programs. Keys whose work is per
//! LINE (Tab, C-S-k, C-Return, C-c/C-x on carets) map over a TARGET — the
//! selection's lines — so two selections on one line act on it once.
//! M-Up/Down alone take the whole set and collapse it first: two moved blocks
//! could swap into each other.

const std = @import("std");
const weft = @import("weft");

const path_pick = 1;

/// The arity of a command that runs once per selection.
const each = weft.Arity.each_extent;
/// The arity of a command that runs once per TARGET `over` finds for each
/// selection, overlapping targets merged (lines).
fn eachOver(comptime over: []const u8) weft.Arity {
    return .{ .each = .{ .over = over, .merge = true } };
}

// ── The selection ────────────────────────────────────────────────────
// A command declared `.each` reads THE selection — during its run, the one
// dispatch is visiting — and writes it back. The same two calls read and
// replace the whole set in a `.whole` command, where there is one selection
// or the command means all of them.

fn one() weft.Selection {
    const set = weft.selections();
    if (set.items.len == 0) return caret(0);
    return set.items[set.primary];
}

fn place(s: weft.Selection) void {
    _ = weft.setSelections(&.{s}, 0);
}

fn caret(at: usize) weft.Selection {
    return .{ .anchor = at, .head = at };
}

/// Answer `r` as this range command's result (a target, a motion).
fn result(r: weft.Range) void {
    if (weft.anchorRange(r)) |h| weft.setResultRange(h);
}

/// Drop the selection, if any.
fn collapse() void {
    weft.run("selection.clear");
}

// ── Moves: plain collapses, shifted extends ──────────────────────────

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

/// Move the selection's head to `t`: collapsed to a caret there (plain), or
/// with its anchor kept (shifted — a caret's anchor is where it was). A plain
/// Left/Right over a selection lands on its near edge instead of moving one
/// further, the convention every desktop editor shares. Vertical moves are
/// core's: it owns the sticky visual column.
fn move(t: Target, extend: bool) void {
    if (t == .up or t == .down) {
        if (!extend) collapse() else if (weft.selection() == null) weft.run("selection.start");
        return weft.run(if (t == .up) "cursor.up" else "cursor.down");
    }
    const s = one();
    const r = s.range();
    const edge = !extend and r.start != r.end;
    const to: usize = switch (t) {
        .left => if (edge) r.start else weft.step(s.head, .back, .char),
        .right => if (edge) r.end else weft.step(s.head, .fwd, .char),
        .up, .down => unreachable,
        .word_left => motionEnd(s.head, weft.runRange("motions.word-prev")),
        .word_right => motionEnd(s.head, weft.runRange("motions.word-next")),
        .home => homeOf(s.head),
        .end => weft.lineAt(s.head).end,
        .doc_start => 0,
        .doc_end => weft.byteLen(),
    };
    place(if (extend) .{ .anchor = s.anchor, .head = to } else caret(to));
}

/// A move as its two commands, plain and shifted.
fn Move(comptime t: Target) type {
    return struct {
        fn plain() void {
            move(t, false);
        }
        fn extend() void {
            move(t, true);
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

/// C-Home / C-End: a long move to one caret, so where it started is a jump to
/// come back to.
fn docStartJump() void {
    weft.jumpPush();
    place(caret(0));
}
fn docEndJump() void {
    weft.jumpPush();
    place(caret(weft.byteLen()));
}

fn selectAll() void {
    place(.{ .anchor = 0, .head = weft.byteLen() });
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
// (`pointer.click`, the floor's `mouse-1`); these only widen what it did.

fn pointerOffset() ?usize {
    const p = weft.pointer() orelse return null;
    return p.offset;
}

/// double-mouse-1: select the word under the pointer. Over a scene (a
/// listing row) there is no word: a double click opens the row instead.
fn selectWordAtPointer() void {
    const off = pointerOffset() orelse return weft.run("pointer.activate");
    const w = wordAround(off) orelse return;
    weft.setSelection(w);
}

/// triple-mouse-1: select the line under the pointer, with its line break.
fn selectLineAtPointer() void {
    const off = pointerOffset() orelse return;
    const l = weft.lineAt(off);
    weft.setSelection(.{ .start = l.start, .end = if (l.end < weft.byteLen()) l.end + 1 else l.end });
}

// ── Line blocks ──────────────────────────────────────────────────────
// Keys that edit whole lines map over a TARGET: each selection's lines, found
// on the untouched text, overlapping blocks merged — so two selections on one
// line edit it once. The target commands answer a range; the key's command
// then runs once per block with it as its range argument.

/// The whole lines selection `s` covers, or its caret's line (end before the
/// last line's break). A selection ending at column 0 does not claim the
/// line it ends on.
fn linesOf(s: weft.Selection) weft.Range {
    const r = s.range();
    const last = if (r.end > r.start and weft.lineAt(r.end).start == r.end) r.end - 1 else r.end;
    return .{ .start = weft.lineAt(r.start).start, .end = weft.lineAt(last).end };
}

/// `ide.target-lines`: the selection's lines.
fn targetLines() void {
    result(linesOf(one()));
}

/// `ide.target-tab`: a caret's own point (Tab types there), else the
/// selection's lines (Tab indents them).
fn targetTab() void {
    const s = one();
    result(if (s.anchor == s.head) .{ .start = s.head, .end = s.head } else linesOf(s));
}

/// `ide.target-line-span`: the selection's lines with their line break — the
/// preceding one on a last line that has none — what C-S-k removes.
fn targetLineSpan() void {
    var b = linesOf(one());
    const len = weft.byteLen();
    if (b.end < len) {
        b.end += 1;
    } else if (b.start > 0) b.start -= 1;
    result(b);
}

/// `ide.target-line-end` / `ide.target-line-start`: where C-Return / C-S-Return open a
/// line — one point per line however many carets sit on it.
fn targetLineEnd() void {
    const l = weft.lineAt(one().head);
    result(.{ .start = l.end, .end = l.end });
}
fn targetLineStart() void {
    const l = weft.lineAt(one().head);
    result(.{ .start = l.start, .end = l.start });
}

/// The target this run was handed.
fn arg() ?weft.Range {
    return weft.rangeEnds(weft.argRange(0) orelse return null);
}

/// Tab: indent a selection's lines; at a caret, the floor's tab.
fn indent() void {
    const r = arg() orelse return;
    if (r.start == r.end) return weft.run("edit.insert-tab");
    if (weft.anchorRange(r)) |h| weft.runRangeArg("indent.increase", h);
}
/// S-Tab: dedent the selection's lines, or the caret's line.
fn dedent() void {
    if (weft.argRange(0)) |h| weft.runRangeArg("indent.decrease", h);
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
    const block = linesOf(one());
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

/// C-S-k: delete the lines, line break included, into no register — a caret
/// left where they were.
fn deleteLine() void {
    const r = arg() orelse return;
    weft.edit(r, "");
}

/// C-Return / C-S-Return: a fresh line below / above the caret's line, at
/// that line's indent, wherever the caret sat on it — the caret on it.
fn openLine(below: bool) void {
    const at = arg() orelse return;
    const l = weft.lineAt(at.start);
    const line = weft.slice(l.start, l.end);
    var indent_len: usize = 0;
    while (indent_len < line.len and (line[indent_len] == ' ' or line[indent_len] == '\t')) indent_len += 1;
    var buf: [256]u8 = undefined;
    if (indent_len + 1 > buf.len) return;
    if (below) {
        buf[0] = '\n';
        @memcpy(buf[1..][0..indent_len], line[0..indent_len]);
    } else {
        @memcpy(buf[0..indent_len], line[0..indent_len]);
        buf[indent_len] = '\n';
    }
    weft.edit(at, buf[0 .. indent_len + 1]);
    place(caret(at.start + if (below) indent_len + 1 else indent_len));
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
// Dispatch files one value per selection, and a paste reads each selection's
// own back by core's rule. A caret copies and cuts its whole line, linewise —
// the convention that makes C-x C-v a line move.

/// The line `at` is on, with its line break, for a linewise transfer.
fn wholeLine(at: usize) weft.Range {
    const l = weft.lineAt(at);
    return .{ .start = l.start, .end = if (l.end < weft.byteLen()) l.end + 1 else l.end };
}

/// `ide.target-transfer`: what copy and cut take — a caret's whole line
/// (once, however many carets share it), else the selection.
fn targetTransfer() void {
    const s = one();
    result(if (s.anchor == s.head) wholeLine(s.head) else s.range());
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

/// Yank this run's target: linewise when the selection is a caret.
fn yankTarget() ?weft.Range {
    const r = arg() orelse return null;
    const s = one();
    weft.yankRange(r.start, r.end, s.anchor == s.head);
    return r;
}

/// `ide.copy-each`: copy the target.
fn copyEach() void {
    const r = yankTarget() orelse return;
    weft.flash(r.start, r.end);
}

/// `ide.cut-each`: copy the target, then delete it — a caret left where it
/// was.
fn cutEach() void {
    const r = yankTarget() orelse return;
    weft.edit(r, "");
}

/// C-c / C-x: every selection's text into the register (one value each),
/// then the register onto the clipboard — which reads the whole of it, so
/// it waits for the mapping to end.
fn copy() void {
    weft.run("ide.copy-each");
    mirrorToClipboard();
}
fn cut() void {
    weft.run("ide.cut-each");
    mirrorToClipboard();
}

/// C-v: over each selection, or at each caret — a linewise register above the
/// caret's line, whole, when every selection is a caret. Each selection
/// pastes its own register value by core's rule: one each when the counts
/// match, else all of them everywhere.
///
/// When the clipboard holds something else — text another program copied —
/// that is what the user means, and it goes in at every selection the same
/// way, as typing would. When it still holds the register's text
/// (`weft.clipboardPasteSource`, the rule helix and vim paste by too), the
/// register pastes, which keeps a cut-and-paste a MOVE (its ferried ids)
/// and a linewise yank linewise.
fn paste() void {
    if (mirrorsClipboard()) switch (weft.clipboardPasteSource()) {
        .foreign => |clip| return weft.runStr2("ide.paste-each", "text", clip),
        .unavailable, .empty, .register => {},
    };
    if (weft.registerTextIn(0).len == 0) return;
    weft.runStr("ide.paste-each", if (weft.registerLinewiseIn(0) and allCarets()) "lines" else "register");
}

/// Whether every selection is a bare caret — the one fact a paste reads
/// off the whole set.
fn allCarets() bool {
    for (weft.selections().items) |s| if (s.anchor != s.head) return false;
    return true;
}

/// `ide.paste-each <text|lines|register> [text]`: put the text over this
/// selection, or (`lines`) at the start of the caret's line, and leave a
/// caret after what landed (a line paste: where it was, moved down with its
/// line).
fn pasteEach(how: []const u8, text: ?[]const u8) void {
    const s = one();
    const lines = std.mem.eql(u8, how, "lines");
    const from_register = !std.mem.eql(u8, how, "text");
    const bytes = if (from_register) weft.registerTextIn(0) else text orelse return;
    const at: weft.Range = if (lines) blk: {
        const l = weft.lineAt(s.head).start;
        break :blk .{ .start = l, .end = l };
    } else s.range();
    // A linewise value taken from a last line with no break of its own still
    // lands as a whole line.
    const trail = lines and (bytes.len == 0 or bytes[bytes.len - 1] != '\n');
    weft.edit(at, bytes);
    if (trail) weft.edit(.{ .start = at.start + bytes.len, .end = at.start + bytes.len }, "\n");
    if (from_register) weft.pasteAtIn(0, at.start);
    if (!lines) place(caret(at.start + bytes.len));
}

// ── Opening and jumping (the pickers this grammar owns) ──────────────

/// C-p: fuzzy-open a project file (the native recursive finder).
/// C-o: open a path as typed — including one that does not exist yet.
fn openPath() void {
    weft.pickBegin("open path", path_pick);
    weft.pickFreeText();
    weft.pickEnd();
}
/// C-b: show or hide the docked viewport this config names (`weft.set("ide",
/// "sidebar", …)`, default `sidebar`) through core's generic viewport door.
fn toggleSidebar() void {
    const name = weft.config("sidebar");
    weft.runStr("viewport.toggle", if (name.len > 0) name else "sidebar");
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
        path_pick => weft.openTyped(trimmed),
        else => {},
    }
}

// ── Command table (registration order == on_command id) ──
// Every command says how it maps over several selections: a move or an edit
// runs once per selection (`each`), a line edit once per line block
// (`eachOver`), what shapes or ignores the set runs once (`.whole`), and a
// goto from the primary's word is refused on several (`.one`).
const cmds = [_]weft.CommandEntry{
    .{ .name = "ide.left", .call = left.plain, .arity = each, .summary = "Move left, or collapse the selection to its start.", .label = "Move Left" },
    .{ .name = "ide.right", .call = right.plain, .arity = each, .summary = "Move right, or collapse the selection to its end.", .label = "Move Right" },
    .{ .name = "ide.up", .call = up.plain, .arity = each, .summary = "Collapse the selection and move up.", .label = "Move Up" },
    .{ .name = "ide.down", .call = down.plain, .arity = each, .summary = "Collapse the selection and move down.", .label = "Move Down" },
    .{ .name = "ide.word-left", .call = word_left.plain, .arity = each, .summary = "Move to the previous word.", .label = "Previous Word" },
    .{ .name = "ide.word-right", .call = word_right.plain, .arity = each, .summary = "Move to the next word.", .label = "Next Word" },
    .{ .name = "ide.smart-home", .call = home.plain, .arity = each, .summary = "Move to the first non-blank character, then to column 0.", .label = "Line Start" },
    .{ .name = "ide.line-end", .call = end_of_line.plain, .arity = each, .summary = "Move to the end of the line.", .label = "Line End" },
    .{ .name = "ide.doc-start", .call = docStartJump, .arity = .whole, .summary = "Jump to the start of the buffer.", .label = "Go to Start of Buffer" },
    .{ .name = "ide.doc-end", .call = docEndJump, .arity = .whole, .summary = "Jump to the end of the buffer.", .label = "Go to End of Buffer" },
    .{ .name = "ide.select-left", .call = left.extend, .arity = each, .summary = "Extend the selection left.", .label = "Select Left" },
    .{ .name = "ide.select-right", .call = right.extend, .arity = each, .summary = "Extend the selection right.", .label = "Select Right" },
    .{ .name = "ide.select-up", .call = up.extend, .arity = each, .summary = "Extend the selection up.", .label = "Select Up" },
    .{ .name = "ide.select-down", .call = down.extend, .arity = each, .summary = "Extend the selection down.", .label = "Select Down" },
    .{ .name = "ide.select-word-left", .call = word_left.extend, .arity = each, .summary = "Extend the selection to the previous word.", .label = "Select Previous Word" },
    .{ .name = "ide.select-word-right", .call = word_right.extend, .arity = each, .summary = "Extend the selection to the next word.", .label = "Select Next Word" },
    .{ .name = "ide.select-smart-home", .call = home.extend, .arity = each, .summary = "Extend the selection to the smart line start.", .label = "Select to Line Start" },
    .{ .name = "ide.select-line-end", .call = end_of_line.extend, .arity = each, .summary = "Extend the selection to the line end.", .label = "Select to Line End" },
    .{ .name = "ide.select-doc-start", .call = doc_start.extend, .arity = each, .summary = "Extend the selection to the buffer start.", .label = "Select to Start of Buffer" },
    .{ .name = "ide.select-doc-end", .call = doc_end.extend, .arity = each, .summary = "Extend the selection to the buffer end.", .label = "Select to End of Buffer" },
    .{ .name = "ide.select-all", .call = selectAll, .arity = .whole, .summary = "Select the whole buffer.", .label = "Select All", .menu = "Selection", .group = "select", .order = 1 },
    .{ .name = "ide.escape", .call = escape, .arity = .whole, .summary = "Drop the selection, or break out of a capture.", .label = "Clear Selection" },
    .{ .name = "ide.indent", .call = indent, .arity = eachOver("ide.target-tab"), .summary = "Indent the selected lines, or insert a tab.", .label = "Indent", .menu = "Edit/Lines", .group = "indent", .order = 1, .icon = "indent-increase" },
    .{ .name = "ide.dedent", .call = dedent, .arity = eachOver("ide.target-lines"), .summary = "Dedent the selected lines.", .label = "Dedent", .menu = "Edit/Lines", .group = "indent", .order = 2, .icon = "indent-decrease" },
    .{ .name = "ide.move-line-up", .call = moveLineUp, .arity = .whole, .summary = "Move the line, or the selected lines, up.", .label = "Move Line Up", .menu = "Edit/Lines", .group = "move", .order = 1 },
    .{ .name = "ide.move-line-down", .call = moveLineDown, .arity = .whole, .summary = "Move the line, or the selected lines, down.", .label = "Move Line Down", .menu = "Edit/Lines", .group = "move", .order = 2 },
    .{ .name = "ide.delete-line", .call = deleteLine, .arity = eachOver("ide.target-line-span"), .summary = "Delete the line, or the selected lines.", .label = "Delete Line", .menu = "Edit/Lines", .group = "delete", .order = 1 },
    .{ .name = "ide.open-below", .call = openBelow, .arity = eachOver("ide.target-line-end"), .summary = "Start a new line below this one.", .label = "Insert Line Below" },
    .{ .name = "ide.open-above", .call = openAbove, .arity = eachOver("ide.target-line-start"), .summary = "Start a new line above this one.", .label = "Insert Line Above" },
    .{ .name = "ide.copy", .call = copy, .arity = .whole, .summary = "Copy the selection, or the line.", .label = "Copy", .menu = "Edit", .group = "clipboard", .order = 2, .icon = "copy" },
    .{ .name = "ide.cut", .call = cut, .arity = .whole, .summary = "Cut the selection, or the line.", .label = "Cut", .menu = "Edit", .group = "clipboard", .order = 1, .icon = "scissors" },
    .{ .name = "ide.paste", .call = paste, .arity = .whole, .summary = "Paste over the selection, or at the cursor.", .label = "Paste", .menu = "Edit", .group = "clipboard", .order = 3, .icon = "clipboard-paste" },
    .{ .name = "ide.copy-each", .call = copyEach, .arity = eachOver("ide.target-transfer"), .summary = "Copy each selection, or its line.", .internal = true },
    .{ .name = "ide.cut-each", .call = cutEach, .arity = eachOver("ide.target-transfer"), .summary = "Cut each selection, or its line.", .internal = true },
    .{ .name = "ide.paste-each", .call = weft.thunk(pasteEach), .arity = each, .params = "how [text]", .summary = "Paste the given text at each selection.", .internal = true },
    // The targets the line and transfer keys map over — range commands,
    // each answering for the one selection it is run on.
    .{ .name = "ide.target-lines", .call = targetLines, .arity = each, .summary = "Answer the whole lines a selection covers.", .internal = true },
    .{ .name = "ide.target-tab", .call = targetTab, .arity = each, .summary = "Answer where the indent key acts for a selection.", .internal = true },
    .{ .name = "ide.target-line-span", .call = targetLineSpan, .arity = each, .summary = "Answer the line span a selection covers.", .internal = true },
    .{ .name = "ide.target-line-end", .call = targetLineEnd, .arity = each, .summary = "Answer the end of a selection's line.", .internal = true },
    .{ .name = "ide.target-line-start", .call = targetLineStart, .arity = each, .summary = "Answer the start of a selection's line.", .internal = true },
    .{ .name = "ide.target-transfer", .call = targetTransfer, .arity = each, .summary = "Answer the text a clipboard key moves for a selection.", .internal = true },
    .{ .name = "ide.open-path", .call = openPath, .arity = .whole, .summary = "Open a file by typing its path.", .label = "Open Path", .prompts = true, .icon = "file" },
    .{ .name = "ide.toggle-sidebar", .call = toggleSidebar, .arity = .whole, .summary = "Show or hide the docked sidebar.", .label = "Sidebar", .menu = "View", .group = "panels", .order = 1, .icon = "sidebar", .toggle = "viewport.sidebar.shown" },
    .{ .name = "ide.add-next-match", .call = addNextMatch, .arity = .whole, .summary = "Select the word, then add the next occurrence of the selection.", .label = "Add Next Occurrence", .menu = "Selection", .group = "cursors", .order = 1 },
    .{ .name = "ide.select-all-matches", .call = selectAllMatches, .arity = .whole, .summary = "Select every occurrence of the selection.", .label = "Select All Occurrences", .menu = "Selection", .group = "cursors", .order = 2 },
    .{ .name = "ide.select-word-at-pointer", .call = selectWordAtPointer, .arity = .whole, .summary = "Select the word under the pointer, or open the scene row there.", .internal = true },
    .{ .name = "ide.select-line-at-pointer", .call = selectLineAtPointer, .arity = .whole, .summary = "Select the line under the pointer.", .internal = true },
};

fn initExtra() void {
    // The one resting mode: `ide` inherits the `default` floor's BINDINGS
    // (BackSpace, Delete, Return's activate-else-break list, C-q) and
    // declares that it commits typed text — a declaration, never inherited.
    weft.setFallback("ide", "default");
    weft.textInput("ide", "edit.insert-text");

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
    // A listing is a list control here: focus is the row, and its name is
    // edited only when asked (F2, a slow second click) — doc/chrome.md §5.2.
    weft.runStr2("mode.set-structural-focus", "ide", "row");
    // The break-out capture can never take away, retained in both resting
    // states (§10.4). Escape reaches it too, from a capture.
    for ([_][]const u8{ "ide", "ide-structural" }) |m|
        weft.bindKeys(m, "C-backslash", &.{"std.input.break-out"});

    // INTENTION FIRST, TEXT SECOND. Each list leads with the standard word
    // the focused view may answer (a listing row, a git row, a field) and
    // falls back to this plugin's text command where nothing offers it — so
    // one key serves every entry without this file knowing what any is.
    const intended = [_]struct { key: []const u8, arms: []const []const u8 }{
        .{ .key = "Left", .arms = &.{ "std.navigation.left", "ide.left" } },
        .{ .key = "Right", .arms = &.{ "std.navigation.right", "ide.right" } },
        .{ .key = "Up", .arms = &.{ "std.navigation.up", "ide.up" } },
        .{ .key = "Down", .arms = &.{ "std.navigation.down", "ide.down" } },
        .{ .key = "C-Left", .arms = &.{ "std.navigation.word-prev", "ide.word-left" } },
        .{ .key = "C-Right", .arms = &.{ "std.navigation.word-next", "ide.word-right" } },
        .{ .key = "Home", .arms = &.{ "std.navigation.line-start", "ide.smart-home" } },
        .{ .key = "End", .arms = &.{ "std.navigation.line-end", "ide.line-end" } },
        // Tab folds a row that has children; in text it indents.
        .{ .key = "Tab", .arms = &.{ "std.hierarchy.toggle-expanded", "ide.indent" } },
        .{ .key = "C-c", .arms = &.{ "std.transfer.yank", "ide.copy" } },
        .{ .key = "C-x", .arms = &.{ "std.transfer.delete-to-register", "ide.cut" } },
        .{ .key = "C-v", .arms = &.{ "std.transfer.paste", "ide.paste" } },
        .{ .key = "C-z", .arms = &.{ "std.history.undo", "edit.undo" } },
        .{ .key = "C-S-z", .arms = &.{ "std.history.redo", "edit.redo" } },
        .{ .key = "C-y", .arms = &.{ "std.history.redo", "edit.redo" } },
    };
    for (intended) |b| weft.bindKeys("ide", b.key, b.arms);
    // Over text, THESE are what the transfer words mean: core offers
    // std.transfer.* where a grammar provides the matching action, so the
    // context menu over text has Cut, Copy and Paste, and the keys above
    // reach the same arms through the words.
    weft.provide("selection.cut", .{ .posture = "text" }, "ide.cut", 0);
    weft.provide("selection.copy", .{ .posture = "text" }, "ide.copy", 0);
    weft.provide("selection.paste-after", .{ .posture = "text" }, "ide.paste", 0);
    // Escape cancels what is pending where something offers that — a row's
    // name being edited, put back as it was — and is ide's own way out
    // everywhere else.
    weft.bindKeys("ide", "Escape", &.{ "std.gesture.cancel", "ide.escape" });
    // In a listing Tab is fold-or-nothing: never a character (GATE 2).
    weft.bindKeys("ide-structural", "Tab", &.{"std.hierarchy.toggle-expanded"});
    // Delete removes the selected rows — every one, marked or in a range.
    weft.bindKey("ide-structural", "Delete", "selection.delete");

    // Text-only keys: no standard word names these yet, so they bind the
    // text command outright. S-Tab arrives as ISO_Left_Tab on most layouts.
    const binds = [_][2][]const u8{
        .{ "S-Left", "ide.select-left" },                    .{ "S-Right", "ide.select-right" },
        .{ "S-Up", "ide.select-up" },                        .{ "S-Down", "ide.select-down" },
        .{ "C-S-Left", "ide.select-word-left" },             .{ "C-S-Right", "ide.select-word-right" },
        .{ "S-Home", "ide.select-smart-home" },              .{ "S-End", "ide.select-line-end" },
        .{ "C-Home", "ide.doc-start" },                      .{ "C-End", "ide.doc-end" },
        .{ "C-S-Home", "ide.select-doc-start" },             .{ "C-S-End", "ide.select-doc-end" },
        .{ "C-a", "ide.select-all" },                        .{ "S-Tab", "ide.dedent" },
        .{ "ISO_Left_Tab", "ide.dedent" },                   .{ "C-slash", "comment.toggle-selection" },
        .{ "M-Up", "ide.move-line-up" },                     .{ "M-Down", "ide.move-line-down" },
        .{ "C-S-k", "ide.delete-line" },                     .{ "C-Return", "ide.open-below" },
        .{ "C-S-Return", "ide.open-above" },                 .{ "C-d", "ide.add-next-match" },
        .{ "C-S-l", "ide.select-all-matches" },
        // The pointer's share of the grammar: what a second and third quick
        // click mean, and C-click's extra selection — a caret in text, a
        // marked row in a listing (core's, one act on either kind).
                     .{ "double-mouse-1", "ide.select-word-at-pointer" },
        .{ "triple-mouse-1", "ide.select-line-at-pointer" }, .{ "C-mouse-1", "pointer.add-selection" },
    };
    for (binds) |b| weft.bindKey("ide", b[0], b[1]);

    // A bar caret where `ide` types: a modeless editor is always between
    // cells. `ide-structural` declares no shape — typing inserts nothing
    // there, so core derives its caret (doc/chrome.md §5.2): none on a
    // focused row, a bar only while a row's name is being edited.
    weft.runStr2("cursor.set-style", "ide", "bar");
    for ([_][]const u8{ "ide", "ide-structural" }) |m| weft.runStr2("cursor.set-blink", m, "on");

    weft.setMode("ide");
}

comptime {
    // `.clipboard` is declared for the approval surface; only the config's
    // `weft.grant("ide", "clipboard")` confers it.
    weft.plugin(&cmds, .{ .init = initExtra, .pick = onPickAccept, .perms = &.{.clipboard} }).exportAll();
}
