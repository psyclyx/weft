//! Every verb that edits.
//!
//! Each is a ONE-SELECTION program: it declares how it maps over the set
//! (`root.zig`'s table) and dispatch runs it once per selection, last first,
//! as one undo unit — the register filing one value per selection, the flash
//! one set over them all (doc/model.md §2.6). A verb whose work is per LINE
//! (`>`, `<`, `J`, `[ space`) maps over a target, the selection's lines, so
//! two selections on one line edit it once.

const std = @import("std");
const weft = @import("weft");
const sel = @import("selection.zig");
const text = @import("text.zig");
const state = @import("state.zig");

const semantic_action = weft.semantic.action.standard;

pub const Case = enum { toggle, lower, upper };

/// The range a target-mapped verb was handed.
fn arg() ?weft.Range {
    return weft.rangeEnds(weft.argRange(0) orelse return null);
}

/// Write `bytes` over `r` and select what landed.
fn writeSelect(r: weft.Range, bytes: []const u8) void {
    weft.edit(r, bytes);
    sel.put(.{ .anchor = r.start, .head = r.start + bytes.len });
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

/// Remember where the selection is as the last place edited. In a mapping
/// the last run — the first selection — is where `g.` returns.
pub fn noteEdit() void {
    noteBuffer();
    const r = sel.span(sel.get());
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

/// `y`'s text arm: the selection into the register (one value per
/// selection). The selection stays.
pub fn yank() void {
    const r = sel.span(sel.get());
    weft.yankRangeIn(state.takeRegister(), r.start, r.end, sel.isLinewise(r));
    weft.flash(r.start, r.end);
}

/// Delete the selection, first yanking it into `slot` (null: no yank),
/// leaving a caret where it was.
fn remove(slot: ?u8) void {
    const r = sel.span(sel.get());
    if (slot) |s| weft.yankRangeIn(s, r.start, r.end, sel.isLinewise(r));
    weft.edit(r, "");
    sel.put(sel.caret(r.start));
    noteEdit();
}

/// `d`'s text arm (and `A-d`, which keeps the register).
pub fn delete(keep_register: bool) void {
    const slot = state.takeRegister();
    remove(if (keep_register) null else slot);
    weft.exitToResting();
}

/// `c` (and `A-c`): delete the selection, then type where it was.
pub fn change(keep_register: bool) void {
    const slot = state.takeRegister();
    if (onText()) remove(if (keep_register) null else slot);
    enterInsert();
}

/// `p` / `P`: place the register after (before) the selection — its own
/// value when the register holds one per selection. A linewise value lands
/// on the line after (before) the selection's lines. The pasted text is
/// selected afterwards, as in helix.
pub fn paste(after: bool) void {
    const slot = state.takeRegister();
    if (!after) switch (weft.semanticAction(semantic_action.paste_before)) {
        .handled, .transfer_stored, .interaction_opened, .target_opened, .focus_changed, .relation_opened, .working_target_changed => return,
        .unavailable, .failed, _ => {},
    };
    const value = weft.registerTextIn(slot);
    if (value.len == 0) return weft.echo("register is empty");
    pasteText(value, weft.registerLinewiseIn(slot), after, slot);
}

/// Place `bytes` after (before) the selection — on the next (previous) line
/// when it is whole lines — select what landed, and re-stamp the identity a
/// register value ferries (`slot`).
fn pasteText(bytes: []const u8, lines: bool, after: bool, slot: ?u8) void {
    const r = sel.span(sel.get());
    var at = if (after) r.end else r.start;
    var lead = false;
    if (lines) {
        if (after) {
            const l = weft.lineAt(if (r.end > r.start) r.end - 1 else r.start);
            at = if (l.end >= text.len()) l.end else l.end + 1;
            // After a last line with no break of its own, one goes first.
            lead = l.end >= text.len();
        } else at = weft.lineAt(r.start).start;
    }
    const point: weft.Range = .{ .start = at, .end = at };
    if (lead) weft.edit(point, "\n");
    const base = at + @intFromBool(lead);
    weft.edit(.{ .start = base, .end = base }, bytes);
    if (slot) |s| weft.pasteAtIn(s, base);
    sel.put(.{ .anchor = base, .head = base + bytes.len });
    sel.flash();
    noteEdit();
}

// ── The system clipboard (`SPC y p P R`) ────────────────────────────────
// The clipboard door is config-granted (helix.js grants it). What mirrors it
// is helix's choice: the unnamed register. A clipboard that still holds what
// the unnamed register holds pastes FROM the register, so a projection
// row's ferried identity survives the round trip. These read or write the
// clipboard once, so they take the whole set; the per-selection part is the
// verb they run.

/// `SPC y`: yank, then hand the unnamed register's text to the clipboard.
pub fn yankToClipboard() void {
    weft.run("helix.yank");
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
        .register => weft.run(if (after) "helix.paste" else "helix.paste-before"),
        .text => |t| weft.runStr2("helix.paste-text", if (after) "after" else "before", t),
    }
}

/// `helix.paste-text <after|before> <text>`: text from elsewhere after (before)
/// the selection — whole lines when it ends in a line break.
pub fn pasteClipboardText(where: []const u8, t: []const u8) void {
    if (t.len == 0) return;
    pasteText(t, t[t.len - 1] == '\n', std.mem.eql(u8, where, "after"), null);
}

/// `SPC R`: replace every selection with the clipboard.
pub fn replaceWithClipboard() void {
    _ = state.takeRegister();
    switch (clipboard()) {
        .none => {},
        .register => weft.run("helix.replace-register"),
        .text => |t| weft.runStr("helix.replace-text", t),
    }
}

/// `helix.replace-text <text>`: the selection becomes `t`, selected.
pub fn replaceText(t: []const u8) void {
    writeSelect(sel.span(sel.get()), t);
    sel.flash();
    noteEdit();
}

// ── Align (`&`) ─────────────────────────────────────────────────────────

/// `&`: pad the selections with spaces so they line up. The first selection
/// on each line aligns with the first on every other line, the second with
/// the second, and so on — each group's heads move to the rightmost head of
/// the group, by spaces inserted before the selection. A column is counted
/// in characters (a tab is one). How far each moves depends on every other,
/// so this verb takes the WHOLE set, and writes its pads as one undo unit.
pub fn alignSelections() void {
    if (!sel.load()) return;
    const n = sel.n;
    var row: [sel.max]usize = undefined;
    var col: [sel.max]usize = undefined;
    var group: [sel.max]usize = undefined;
    var groups: usize = 0;
    for (sel.items[0..n], 0..) |s, i| {
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
    var pad: [sel.max]usize = @splat(0);
    for (0..groups) |g| {
        var widest: usize = 0;
        for (0..n) |i| if (group[i] == g) {
            widest = @max(widest, col[i] + shiftBefore(&row, &group, &pad, i, g));
        };
        for (0..n) |i| if (group[i] == g) {
            pad[i] = widest - (col[i] + shiftBefore(&row, &group, &pad, i, g));
        };
    }
    weft.undoUnit(writePads, .{ sel.items[0..n], pad[0..n] });
    // Every insertion sits at or before the selections after it: each moves
    // right by the pads up to and including its own.
    var shift: usize = 0;
    for (sel.items[0..n], pad[0..n]) |*s, p| {
        shift += p;
        s.* = .{ .anchor = s.anchor + shift, .head = s.head + shift };
    }
    sel.store();
    noteEdit();
}

/// Each selection's pad, before it — last first, so earlier offsets hold.
fn writePads(items: []const weft.Selection, pads: []const usize) void {
    const spaces = " " ** 256;
    var i = items.len;
    while (i > 0) {
        i -= 1;
        const at = items[i].range().start;
        var left = pads[i];
        while (left > 0) {
            const k = @min(left, spaces.len);
            weft.edit(.{ .start = at, .end = at }, spaces[0..k]);
            left -= k;
        }
    }
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

/// `R`: replace the selection with the register (its own value where the
/// counts match), selecting what was written.
pub fn replaceWithRegister() void {
    const slot = state.takeRegister();
    const r = sel.span(sel.get());
    const value = weft.registerTextIn(slot);
    weft.edit(r, value);
    weft.pasteAtIn(slot, r.start);
    sel.put(.{ .anchor = r.start, .head = r.start + value.len });
    sel.flash();
    noteEdit();
}

var rewrite_buf: [1 << 16]u8 = undefined;

/// `r<c>`: every character of the selection becomes `c`.
pub fn replaceWith(c: []const u8) void {
    if (c.len == 0 or c.len > 4) return;
    const r = sel.span(sel.get());
    const src = weft.slice(r.start, r.end);
    var w: usize = 0;
    var k: usize = 0;
    while (k < src.len) {
        const step = std.unicode.utf8ByteSequenceLength(src[k]) catch 1;
        const piece: []const u8 = if (src[k] == '\n') "\n" else c;
        if (w + piece.len > rewrite_buf.len) return;
        @memcpy(rewrite_buf[w..][0..piece.len], piece);
        w += piece.len;
        k += step;
    }
    writeSelect(r, rewrite_buf[0..w]);
    sel.flash();
    noteEdit();
}

/// `~` / `` ` `` / `` A-` ``.
pub fn setCase(c: Case) void {
    const r = sel.span(sel.get());
    const src = weft.slice(r.start, r.end);
    if (src.len > rewrite_buf.len) return;
    for (src, rewrite_buf[0..src.len]) |b, *o| o.* = switch (c) {
        .lower => std.ascii.toLower(b),
        .upper => std.ascii.toUpper(b),
        .toggle => if (std.ascii.isUpper(b)) std.ascii.toLower(b) else std.ascii.toUpper(b),
    };
    writeSelect(r, rewrite_buf[0..src.len]);
    sel.flash();
    noteEdit();
}

// ── Lines: join, indent, comment ────────────────────────────────────────

/// `helix.line-block`: the target the line verbs map over — the selection's
/// lines, `[first line start, past the last line's newline)`.
pub fn lineBlock() void {
    const r = sel.span(sel.get());
    const first = weft.lineAt(r.start).start;
    const last = weft.lineAt(@max(r.start, r.end -| 1));
    if (weft.anchorRange(.{ .start = first, .end = @min(last.end + 1, text.len()) })) |h| weft.setResultRange(h);
}

/// `>` `<` and the comment toggle: the line operator once per line block,
/// `count` times — and `3>` is one edit, since the mapping is one unit.
pub fn onLines(cmd: []const u8) void {
    const h = weft.argRange(0) orelse return;
    var k = state.takeCount();
    while (k > 0) : (k -= 1) weft.runRangeArg(cmd, h);
    sel.flash();
    noteEdit();
}

/// `helix.join-target`: what `J` joins — the selection's lines, or, for a
/// selection on one line, that line and the next.
pub fn joinTarget() void {
    const r = sel.span(sel.get());
    const first = weft.lineAt(r.start).start;
    const last = weft.lineAt(@max(r.start, r.end -| 1));
    var end = @min(last.end + 1, text.len());
    // Past the block's own last newline is the next line: a one-line block
    // joins with it.
    if (weft.lineAt(first).end + 1 >= end) end = @min(weft.lineAt(@min(end, text.len())).end, text.len());
    if (weft.anchorRange(.{ .start = first, .end = @max(first, end) })) |h| weft.setResultRange(h);
}

/// `J`: collapse every line break inside the target (and the indent after
/// it) to one space, last first so earlier offsets hold.
pub fn join() void {
    const r = arg() orelse return;
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
    sel.flash();
    noteEdit();
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

/// `i a I A`: a caret at the selection's entry point, then type — at every
/// selection's at once.
pub fn insertAt(where: Entry) void {
    if (onText()) sel.put(sel.caret(entryPoint(sel.get(), where)));
    enterInsert();
}

/// `o` / `O`: open a line below (above) the selection, indented like its
/// own, and type there. A structured view answers the insertion intention (a
/// new row) instead.
pub fn openLine(below: bool) void {
    if (weft.invokeIntention(if (below) "std.editing.insert-after" else "std.editing.insert-before") == .invoked) return enterInsert();
    if (!onText()) return enterInsert();
    const r = sel.span(sel.get());
    const at = if (below) weft.lineAt(@max(r.start, r.end -| 1)).end else weft.lineAt(r.start).start;
    const l = weft.lineAt(r.start);
    const line = weft.slice(l.start, l.end);
    var indent: usize = 0;
    while (indent < line.len and indent + 1 < rewrite_buf.len and (line[indent] == ' ' or line[indent] == '\t')) indent += 1;
    if (below) {
        rewrite_buf[0] = '\n';
        @memcpy(rewrite_buf[1..][0..indent], line[0..indent]);
    } else {
        @memcpy(rewrite_buf[0..indent], line[0..indent]);
        rewrite_buf[indent] = '\n';
    }
    weft.edit(.{ .start = at, .end = at }, rewrite_buf[0 .. indent + 1]);
    sel.put(sel.caret(at + if (below) indent + 1 else indent));
    enterInsert();
}

/// `hx-blank-point`: where `[ space` / `] space` insert — a line's start
/// (end), once per line however many selections sit on it.
pub fn blankPoint(below: bool) void {
    const r = sel.span(sel.get());
    const at = if (below) weft.lineAt(@max(r.start, r.end -| 1)).end else weft.lineAt(r.start).start;
    if (weft.anchorRange(.{ .start = at, .end = at })) |h| weft.setResultRange(h);
}

/// `[ space` / `] space`: `count` blank lines at the target, the selection
/// left where it is.
pub fn addBlankLine() void {
    const at = arg() orelse return;
    var k = state.takeCount();
    while (k > 0) : (k -= 1) weft.edit(at, "\n");
}

// ── Surround (the `surround` plugin) ────────────────────────────────────

pub const SurroundVerb = enum { add, delete, replace };

/// Choose the pair, then surround. Adding wraps each selection
/// (`helix.surround-wrap`, per selection); deleting and replacing are the
/// surround plugin's own commands, which map over each selection's PAIR —
/// so two selections inside one pair edit it once.
pub fn surround(verb: SurroundVerb, pair: []const u8, replacement: ?[]const u8) void {
    if (replacement) |r| weft.runStr2("surround.choose-pair", pair, r) else weft.runStr("surround.choose-pair", pair);
    weft.run(switch (verb) {
        .add => "helix.surround-wrap",
        .delete => "surround.delete",
        .replace => "surround.replace",
    });
}

/// `helix.surround-wrap`: the chosen pair around the selection.
pub fn surroundWrap() void {
    const r = sel.span(sel.get());
    if (weft.anchorRange(r)) |h| weft.runRangeArg("surround.add", h);
    sel.flash();
    noteEdit();
}
