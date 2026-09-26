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

const std = @import("std");
const weft = @import("weft");

const file_pick = 0;
const path_pick = 1;
const line_pick = 2;

// ── Selection primitives (core's mark model) ─────────────────────────

/// Start a selection at the cursor unless one is already open — the half
/// every shift-move shares. An empty selection (mark on the cursor) reads as
/// none, and re-marking it there is the same state.
fn ensureMark() void {
    if (weft.selection() == null) weft.run("set-mark");
}

/// Drop the selection, if any — the half every plain move shares.
fn collapse() void {
    weft.run("clear-selection");
}

/// Where running `motion` (a `motions` range command) would put the cursor:
/// the end of its range that isn't the cursor, which carries the direction.
/// The cursor itself when the motion has nowhere to go (or is not loaded).
fn motionTarget(motion: []const u8) usize {
    const cur = weft.cursor();
    const h = weft.runRange(motion) orelse return cur;
    const r = weft.rangeEnds(h) orelse return cur;
    return if (r.end == cur) r.start else r.end;
}

/// Smart home: the first non-blank of the line, or column 0 when already
/// there — so a second press reaches the margin.
fn homeTarget() usize {
    const cur = weft.cursor();
    const target = motionTarget("motion.first-non-blank");
    return if (target == cur) weft.lineAt(cur).start else target;
}

/// A cursor move, as a plain key (collapse, then move) or a shifted one
/// (extend from the mark). `to` computes the destination at press time.
fn Move(comptime to: fn () usize) type {
    return struct {
        fn plain() void {
            collapse();
            weft.jump(to());
        }
        fn extend() void {
            ensureMark();
            weft.jump(to());
        }
    };
}

fn wordNext() usize {
    return motionTarget("motion.word-fwd");
}
fn wordPrev() usize {
    return motionTarget("motion.word-back");
}
fn lineEnd() usize {
    return weft.lineAt(weft.cursor()).end;
}
fn docStart() usize {
    return 0;
}
fn docEnd() usize {
    return weft.byteLen();
}

const word_right = Move(wordNext);
const word_left = Move(wordPrev);
const home = Move(homeTarget);
const end_of_line = Move(lineEnd);
const doc_start = Move(docStart);
const doc_end = Move(docEnd);

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

/// Left/Right with a selection collapse to its near edge instead of moving
/// one further — the convention every desktop editor shares.
fn left() void {
    if (weft.selection()) |s| {
        collapse();
        weft.jump(s.start);
    } else weft.run("cursor-left");
}
fn right() void {
    if (weft.selection()) |s| {
        collapse();
        weft.jump(s.end);
    } else weft.run("cursor-right");
}
/// Vertical moves stay core's: it owns the sticky visual column.
fn up() void {
    collapse();
    weft.run("cursor-up");
}
fn down() void {
    collapse();
    weft.run("cursor-down");
}
fn selectLeft() void {
    ensureMark();
    weft.run("cursor-left");
}
fn selectRight() void {
    ensureMark();
    weft.run("cursor-right");
}
fn selectUp() void {
    ensureMark();
    weft.run("cursor-up");
}
fn selectDown() void {
    ensureMark();
    weft.run("cursor-down");
}

fn selectAll() void {
    weft.setSelection(.{ .start = 0, .end = weft.byteLen() });
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

/// The whole lines the selection covers, or the cursor's line. A selection
/// ending at column 0 does not claim the line it ends on.
fn lineBlock() weft.Range {
    const s = weft.selection() orelse {
        const l = weft.lineAt(weft.cursor());
        return .{ .start = l.start, .end = l.end };
    };
    const last = if (s.end > s.start and weft.lineAt(s.end).start == s.end) s.end - 1 else s.end;
    return .{ .start = weft.lineAt(s.start).start, .end = weft.lineAt(last).end };
}

/// Run a range operator (`op.indent`, `op.dedent`) over the selected lines
/// and keep them selected afterwards, so Tab can be pressed again.
fn overSelectedLines(comptime op: []const u8) void {
    const block = lineBlock();
    const h = weft.anchorRange(block) orelse return;
    weft.runRangeArg(op, h);
    if (weft.rangeEnds(h)) |r| weft.setSelection(r);
}

/// Tab: indent the selected lines; with nothing selected, the floor's tab.
fn indent() void {
    if (weft.selection() == null) {
        weft.run("insert-tab");
        return;
    }
    overSelectedLines("op.indent");
}
/// S-Tab: dedent the selected lines, or the cursor's line.
fn dedent() void {
    overSelectedLines("op.dedent");
}

/// Line text copies: `slice` borrows one scratch, and a swap needs two
/// spans at once. Lines longer than this are left where they are.
var move_a: [1 << 15]u8 = undefined;
var move_b: [1 << 15]u8 = undefined;
var move_out: [(1 << 16) + 1]u8 = undefined;

/// Swap the block with the line below (`down`) or above, as ONE edit, so
/// the move is one undo unit. The cursor and selection travel with it.
fn moveBlock(down_dir: bool) void {
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

/// C-S-k: delete the block's lines, newline included, into no register.
fn deleteLine() void {
    const block = lineBlock();
    const len = weft.byteLen();
    const span: weft.Range = if (block.end < len)
        .{ .start = block.start, .end = block.end + 1 }
    else if (block.start > 0)
        .{ .start = block.start - 1, .end = block.end }
    else
        block;
    collapse();
    weft.edit(span, "");
    weft.jump(@min(block.start, weft.byteLen()));
}

var indent_buf: [256]u8 = undefined;

/// The cursor line's leading whitespace, copied (a new line inherits it).
fn leadingIndent(l: weft.Range) []const u8 {
    const t = weft.slice(l.start, l.end);
    var i: usize = 0;
    while (i < t.len and i < indent_buf.len - 1 and (t[i] == ' ' or t[i] == '\t')) i += 1;
    @memcpy(indent_buf[0..i], t[0..i]);
    return indent_buf[0..i];
}

var open_buf: [indent_buf.len + 1]u8 = undefined;

/// C-Return / C-S-Return: a fresh line below / above, at the same indent,
/// wherever the cursor sat on this one.
fn openBelow() void {
    const l = weft.lineAt(weft.cursor());
    const ind = leadingIndent(.{ .start = l.start, .end = l.end });
    open_buf[0] = '\n';
    @memcpy(open_buf[1..][0..ind.len], ind);
    collapse();
    weft.edit(.{ .start = l.end, .end = l.end }, open_buf[0 .. ind.len + 1]);
    weft.jump(l.end + 1 + ind.len);
}
fn openAbove() void {
    const l = weft.lineAt(weft.cursor());
    const ind = leadingIndent(.{ .start = l.start, .end = l.end });
    @memcpy(open_buf[0..ind.len], ind);
    open_buf[ind.len] = '\n';
    collapse();
    weft.edit(.{ .start = l.start, .end = l.start }, open_buf[0 .. ind.len + 1]);
    weft.jump(l.start + ind.len);
}

// ── Transfer: the text arm behind the std.transfer.* intentions ──────
// The register is core's shared one (the same `dd`/`p` and emacs's kill ring
// use), so a row cut in the sidebar and text copied here share one ferry.
// With nothing selected, copy and cut take the whole line, linewise — the
// convention that makes C-x C-v a line move.

/// The current line with its newline, for a linewise transfer.
fn wholeLine() weft.Range {
    const l = weft.lineAt(weft.cursor());
    return .{ .start = l.start, .end = if (l.end < weft.byteLen()) l.end + 1 else l.end };
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
    if (weft.selection()) |s| {
        weft.yankRange(s.start, s.end, false);
        weft.flash(s.start, s.end);
    } else {
        const l = wholeLine();
        weft.yankRange(l.start, l.end, true);
        weft.flash(l.start, l.end);
    }
    mirrorToClipboard();
}

fn cut() void {
    if (weft.selection()) |s| {
        weft.yankRange(s.start, s.end, false);
        mirrorToClipboard();
        weft.edit(s, "");
    } else {
        const l = wholeLine();
        weft.yankRange(l.start, l.end, true);
        mirrorToClipboard();
        weft.edit(l, "");
    }
}

var paste_buf: [(1 << 16) + 1]u8 = undefined;

/// C-v: replace the selection with the register, or insert it at the cursor.
/// A linewise register lands above the cursor's line, whole.
///
/// When the clipboard holds something else — text another program copied —
/// that is what the user means: it goes in at every selection, replacing
/// each, as typing would. When it still holds what the register holds, the
/// register pastes, which keeps a cut-and-paste a MOVE (its ferried ids)
/// and a linewise yank linewise.
fn paste() void {
    if (mirrorsClipboard()) switch (weft.clipboardPasteSource()) {
        .foreign => |clip| return weft.runStr("insert-text", clip),
        .unavailable, .empty, .register => {},
    };
    const txt = weft.registerText();
    if (txt.len == 0) return;
    if (weft.selection()) |s| {
        weft.edit(s, txt);
        weft.pasteAt(s.start);
        weft.jump(s.start + txt.len);
        return;
    }
    const cur = weft.cursor();
    if (weft.registerLinewiseIn(0)) {
        // A linewise register may or may not carry its closing newline.
        const n = txt.len;
        @memcpy(paste_buf[0..n], txt);
        const body = if (txt[n - 1] == '\n') paste_buf[0..n] else blk: {
            paste_buf[n] = '\n';
            break :blk paste_buf[0 .. n + 1];
        };
        const at = weft.lineAt(cur).start;
        weft.edit(.{ .start = at, .end = at }, body);
        weft.pasteAt(at);
        weft.jump(cur + body.len);
        return;
    }
    weft.edit(.{ .start = cur, .end = cur }, txt);
    weft.pasteAt(cur);
    weft.jump(cur + txt.len);
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

/// Put the cursor at the start of 1-based line `n`, clamped to the last,
/// leaving a jump where it was.
fn jumpToLine(n: usize) void {
    weft.jumpPush();
    var off: usize = 0;
    var line: usize = 1;
    const len = weft.byteLen();
    while (line < n) : (line += 1) {
        const l = weft.lineAt(off);
        if (l.end >= len) break;
        off = l.end + 1;
    }
    collapse();
    weft.jump(off);
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
    .{ .name = "ide-left", .call = left, .summary = "move left, or collapse the selection to its start" },
    .{ .name = "ide-right", .call = right, .summary = "move right, or collapse the selection to its end" },
    .{ .name = "ide-up", .call = up, .summary = "collapse the selection and move up" },
    .{ .name = "ide-down", .call = down, .summary = "collapse the selection and move down" },
    .{ .name = "ide-word-left", .call = word_left.plain, .summary = "move to the previous word" },
    .{ .name = "ide-word-right", .call = word_right.plain, .summary = "move to the next word" },
    .{ .name = "ide-home", .call = home.plain, .summary = "move to the first non-blank, then to column 0" },
    .{ .name = "ide-end", .call = end_of_line.plain, .summary = "move to the end of the line" },
    .{ .name = "ide-doc-start", .call = docStartJump, .summary = "move to the start of the buffer (a jump)" },
    .{ .name = "ide-doc-end", .call = docEndJump, .summary = "move to the end of the buffer (a jump)" },
    .{ .name = "ide-select-left", .call = selectLeft, .summary = "extend the selection left" },
    .{ .name = "ide-select-right", .call = selectRight, .summary = "extend the selection right" },
    .{ .name = "ide-select-up", .call = selectUp, .summary = "extend the selection up" },
    .{ .name = "ide-select-down", .call = selectDown, .summary = "extend the selection down" },
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
