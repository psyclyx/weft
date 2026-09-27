//! find — the incremental find/replace bar (doc/configs.md §3.4), a plugin
//! over the `regex` library and doors every plugin has. Core parses no
//! pattern and draws no bar.
//!
//! THE BAR is a `.bottom` surface this plugin repaints, and a `textInput`
//! mode (`find`) whose printable keys route to `find-type` — the prompt
//! library's idiom, with the keys a find bar needs on top of it. Every
//! keystroke re-runs the search:
//!
//!   · the caret (a selection over the match) moves to the first match at
//!     or after where the search started, wrapping past the end;
//!   · every match around it is painted on an annotation layer this plugin
//!     owns (`find`), the current one in its own colour — closed with the
//!     bar, so nothing is left behind on the document;
//!   · the bar says `n/m`, or why the pattern will not compile.
//!
//! Enter / F3 step forward and S-Enter / S-F3 back, wrapping with an echo;
//! Escape closes and leaves the caret on the match. M-r, M-c and M-w toggle
//! regex, case (smart → on → off) and whole word; Up/Down walk this
//! session's search history. C-h adds the replacement field: Enter there
//! replaces the current match and moves on, C-M-Return replaces every
//! match as ONE undo unit, and M-Return turns every match into a selection.
//! F3 and friends keep working after the bar closes, from the caret. A
//! committed search (Enter, F3, Escape, a replace, M-Return) is also the `/`
//! register every grammar shares, so helix's `n` goes on from it.
//!
//! LARGE BUFFERS. The search needs the whole document on every keystroke
//! (the count is over all of it), so the plugin keeps ONE copy and re-reads
//! it only when the document moved since — an opaque snapshot witness says
//! so. Typing into the bar reads nothing from the host. The match scan
//! skips to the places a match can start (the `search` library's module doc), and
//! only the matches around the current one are painted, so a thousand-hit
//! file costs the same paint as a ten-hit one.

const std = @import("std");
const weft = @import("weft");
const search = @import("weft_search");

const Span = search.Span;
const gpa = weft.allocator;

/// The bar's mode: typed text is the focused field's.
const mode = "find";
/// The annotation layer the matches are painted on.
const layer_name = "find";
/// Matches kept per search. Past this the count reads `N+`; a search that
/// finds a quarter of a million hits is not one anyone steps through.
const max_matches: usize = 1 << 18;
/// Matches painted around the current one — more than any screen shows.
const paint_window: usize = 1024;
/// Bytes read from the host per `slice` (the SDK's read scratch).
const chunk: usize = 1 << 16;
const history_cap = 32;
const field_cap = 512;

/// One editable line of the bar.
const Field = struct {
    buf: [field_cap]u8 = undefined,
    len: usize = 0,

    fn text(self: *const Field) []const u8 {
        return self.buf[0..self.len];
    }

    fn set(self: *Field, s: []const u8) void {
        self.len = @min(s.len, self.buf.len);
        @memcpy(self.buf[0..self.len], s[0..self.len]);
    }

    fn append(self: *Field, s: []const u8) bool {
        if (self.len + s.len > self.buf.len) return false;
        @memcpy(self.buf[self.len .. self.len + s.len], s);
        self.len += s.len;
        return true;
    }

    /// Drop the last codepoint.
    fn pop(self: *Field) void {
        if (self.len == 0) return;
        var n: usize = 1;
        while (self.len - n > 0 and (self.buf[self.len - n] & 0xc0) == 0x80) n += 1;
        self.len -= n;
    }
};

const Focus = enum { query, template };

// ── The bar ──────────────────────────────────────────────────────────
var bar_open = false;
var replacing = false;
var focus: Focus = .query;
var query: Field = .{};
var template: Field = .{};
var opts: search.Options = .{};
/// A query carried over from the last search, shown but not yet typed
/// into: the first character replaces it, as a selected field would.
var fresh = false;
/// Where this search started: the first match at or after it is the one
/// each keystroke lands on.
var origin: usize = 0;
/// The index of the match the caret is on, for painting.
var current: ?usize = null;
/// The entry the bar searches; leaving it closes the bar.
var entry: ?u32 = null;
var layer: ?weft.Annotations = null;

// ── The searched document and its matches ────────────────────────────
var doc: std.ArrayList(u8) = .empty;
var doc_snapshot: ?u32 = null;
var doc_entry: ?u32 = null;
var matcher: ?search.Matcher = null;
var matches: std.ArrayList(Span) = .empty;
var truncated = false;
/// Why the query cannot be searched, or empty.
var problem: []const u8 = "";
/// The query or its options changed since `matches` was computed.
var stale = true;

// ── History ──────────────────────────────────────────────────────────
/// Past queries, newest first.
var history: [history_cap]Field = undefined;
var history_len: usize = 0;
/// While walking the history: the entry shown, and the query that was being
/// typed before the walk began (Down past the newest brings it back).
var history_at: ?usize = null;
var draft: Field = .{};

const cmds = [_]weft.CommandEntry{
    .{ .name = "find", .call = openFind, .summary = "search this buffer as you type" },
    .{ .name = "find-replace", .call = openReplace, .summary = "search and replace in this buffer" },
    .{ .name = "find-next", .call = findNext, .summary = "go to the next match of the last search" },
    .{ .name = "find-prev", .call = findPrev, .summary = "go to the previous match of the last search" },
    .{ .name = "find-select-all", .call = selectAll, .summary = "select every match of the last search" },
    .{ .name = "find-replace-all", .call = replaceAll, .summary = "replace every match, as one undo step" },
    .{ .name = "find-replace-one", .call = replaceOne },
    .{ .name = "find-accept", .call = accept },
    .{ .name = "find-close", .call = close },
    .{ .name = "find-type", .call = typeText },
    .{ .name = "find-backspace", .call = backspace },
    .{ .name = "find-clear", .call = clearField },
    .{ .name = "find-paste", .call = paste },
    .{ .name = "find-switch-field", .call = switchField },
    .{ .name = "find-history-prev", .call = historyOlder },
    .{ .name = "find-history-next", .call = historyNewer },
    .{ .name = "find-toggle-regex", .call = toggleRegex },
    .{ .name = "find-toggle-case", .call = toggleCase },
    .{ .name = "find-toggle-word", .call = toggleWord },
};

comptime {
    // Nothing here maps over selections: the bar searches the document, and
    // a replace-all or select-all-matches answers for the whole of it.
    weft.plugin(&cmds, .{ .init = init, .arity = .whole }).exportAll();
}

/// The bar's keys. Bound here rather than by a config because they are the
/// bar's own grammar, the same under vim, helix or ide; a config that
/// disagrees rebinds the `find` mode.
fn init() void {
    weft.textInput(mode, "find-type");
    const keys = [_][2][]const u8{
        .{ "Return", "find-accept" },          .{ "KP_Enter", "find-accept" },
        .{ "S-Return", "find-prev" },          .{ "F3", "find-next" },
        .{ "S-F3", "find-prev" },              .{ "Escape", "find-close" },
        .{ "BackSpace", "find-backspace" },    .{ "C-u", "find-clear" },
        .{ "C-v", "find-paste" },              .{ "Tab", "find-switch-field" },
        .{ "Up", "find-history-prev" },        .{ "Down", "find-history-next" },
        .{ "M-r", "find-toggle-regex" },       .{ "M-c", "find-toggle-case" },
        .{ "M-w", "find-toggle-word" },        .{ "C-f", "find" },
        .{ "C-h", "find-replace" },            .{ "M-Return", "find-select-all" },
        .{ "C-M-Return", "find-replace-all" },
    };
    for (keys) |k| weft.bindKey(mode, k[0], k[1]);
}

// ── Opening and closing ──────────────────────────────────────────────

fn openFind() void {
    open(false);
}

fn openReplace() void {
    open(true);
}

/// Open the bar (or, already open, focus the field asked for). A one-line
/// selection becomes the query; otherwise the last query is offered again,
/// replaced by the first character typed.
fn open(replace: bool) void {
    const id = activeEntry() orelse return weft.echo("find: nothing to search here");
    if (weft.selectionCount() == 0) return weft.echo("find: this entry has no text");
    if (bar_open and entry == id) {
        if (replace) replacing = true;
        focus = if (replace) .template else .query;
        return render();
    }
    if (bar_open) clearPaint();
    entry = id;
    bar_open = true;
    replacing = replace;
    focus = .query;
    history_at = null;
    fresh = query.len > 0;
    const sel = weft.selection();
    origin = if (sel) |s| s.start else weft.cursor();
    if (sel) |s| {
        if (s.end - s.start <= field_cap) {
            const picked = weft.slice(s.start, s.end);
            if (std.mem.indexOfScalar(u8, picked, '\n') == null) {
                query.set(picked);
                fresh = true;
            }
        }
    }
    weft.setMode(mode);
    seek();
}

/// Escape: keep the caret where the search put it, take everything else
/// away — the paint, the bar, the mode.
fn close() void {
    remember();
    closeBar();
}

fn closeBar() void {
    if (!bar_open) return;
    bar_open = false;
    clearPaint();
    weft.surfaceClose();
    weft.exitToResting();
}

/// Still searching the entry the bar was opened on? A bar whose entry went
/// away (closed, switched) closes rather than searching somewhere else.
fn live() bool {
    if (!bar_open) return false;
    if (activeEntry() != entry) {
        closeBar();
        return false;
    }
    return true;
}

/// The focused entry's compact id (the handle an annotation layer opens on).
fn activeEntry() ?u32 {
    var i: usize = 0;
    while (i < weft.bufferCount()) : (i += 1) {
        if (!weft.bufferActive(i)) continue;
        const id = weft.bufferId(i) orelse return null;
        return @intCast(id);
    }
    return null;
}

// ── Editing the fields ───────────────────────────────────────────────

fn focused() *Field {
    return if (focus == .query) &query else &template;
}

/// A field edit: the query re-searches, the template just redraws.
fn edited() void {
    if (focus == .query) {
        history_at = null;
        seek();
    } else render();
}

fn typeText() void {
    if (!live()) return;
    const s = weft.argStr(0) orelse return;
    if (fresh and focus == .query) query.len = 0;
    fresh = false;
    if (!focused().append(s)) return weft.echo("find: that field is full");
    edited();
}

fn backspace() void {
    if (!live()) return;
    fresh = false;
    focused().pop();
    edited();
}

fn clearField() void {
    if (!live()) return;
    fresh = false;
    focused().len = 0;
    edited();
}

/// C-v: the register's text, to its first line — a field is one line.
fn paste() void {
    if (!live()) return;
    const text = weft.registerText();
    const line = text[0 .. std.mem.indexOfScalar(u8, text, '\n') orelse text.len];
    if (fresh and focus == .query) query.len = 0;
    fresh = false;
    if (!focused().append(line)) return weft.echo("find: that field is full");
    edited();
}

fn switchField() void {
    if (!live()) return;
    if (!replacing) return;
    focus = if (focus == .query) .template else .query;
    render();
}

fn toggleRegex() void {
    if (!live()) return;
    opts.regex = !opts.regex;
    seek();
}

fn toggleCase() void {
    if (!live()) return;
    opts.case = opts.case.next();
    seek();
}

fn toggleWord() void {
    if (!live()) return;
    opts.whole_word = !opts.whole_word;
    seek();
}

// ── History ──────────────────────────────────────────────────────────

/// Keep the query for Up to find later — once, newest first — and publish
/// it as the last search every grammar shares.
fn remember() void {
    if (query.len == 0) return;
    publish();
    if (history_len > 0 and std.mem.eql(u8, history[0].text(), query.text())) return;
    const keep = @min(history_len, history_cap - 1);
    var i = keep;
    while (i > 0) : (i -= 1) history[i] = history[i - 1];
    history[0] = query;
    history_len = keep + 1;
}

/// Write the committed search to core's `/` register (`register.Bank.search`)
/// as the REGEX it searched for: a literal query escaped, whole word wrapped
/// — `search.source`, the same translation the bar compiled. Everyone reads
/// that register as a smart-case regex (helix's `n`, vim's `"/p`), so a bar
/// folding case the pattern alone would not gets a leading `(?i)`. The one
/// setting that cannot travel is case-sensitive over an all-lowercase query:
/// the register has no spelling for "do not fold".
fn publish() void {
    const src = search.source(gpa, query.text(), opts) catch return;
    defer gpa.free(src);
    const read_as: search.Options = .{ .regex = true, .case = .smart };
    if (search.folds(query.text(), opts) and !search.folds(src, read_as)) {
        const folded = std.mem.concat(gpa, u8, &.{ "(?i)", src }) catch return;
        defer gpa.free(folded);
        return weft.registerSet(weft.register_search, folded);
    }
    weft.registerSet(weft.register_search, src);
}

fn historyOlder() void {
    if (!live()) return;
    const at = if (history_at) |a| a + 1 else 0;
    if (at >= history_len) return;
    if (history_at == null) draft = query;
    history_at = at;
    showHistory();
}

fn historyNewer() void {
    if (!live()) return;
    const at = history_at orelse return;
    if (at == 0) {
        history_at = null;
        query = draft;
    } else {
        history_at = at - 1;
        query = history[at - 1];
    }
    focus = .query;
    fresh = false;
    seek();
}

fn showHistory() void {
    query = history[history_at.?];
    focus = .query;
    fresh = false;
    seek();
}

// ── Searching ────────────────────────────────────────────────────────

/// Bring the copy of the searched document up to date — only when the
/// document moved since the last copy. Returns whether it copied.
fn refreshDoc() bool {
    const id = activeEntry() orelse return false;
    if (doc_snapshot) |snap| {
        if (doc_entry == id and weft.docSnapshotIsCurrent(snap)) return false;
        weft.releaseDocSnapshot(snap);
    }
    // The witness is taken BEFORE the read: an edit landing after it is
    // then always seen as a move, never folded into a copy that missed it.
    doc_snapshot = weft.docSnapshot();
    doc_entry = id;
    doc.clearRetainingCapacity();
    const len = weft.byteLen();
    doc.ensureTotalCapacity(gpa, len) catch return true;
    var at: usize = 0;
    while (at < len) {
        const bytes = weft.slice(at, @min(len, at + chunk));
        if (bytes.len == 0) break;
        doc.appendSliceAssumeCapacity(bytes);
        at += bytes.len;
    }
    return true;
}

/// Recompile the query and rescan the document.
fn recompute() void {
    if (matcher) |*m| m.deinit();
    matcher = null;
    matches.clearRetainingCapacity();
    truncated = false;
    problem = "";
    if (query.len == 0) return;
    matcher = search.Matcher.init(gpa, query.text(), opts) catch |err| {
        if (err != error.EmptyPattern) problem = search.describe(err);
        return;
    };
    truncated = matcher.?.collect(gpa, doc.items, &matches, max_matches) catch {
        problem = "out of memory";
        return;
    };
}

/// Make `matches` current: rescan when the document or the query moved.
fn sync() void {
    const moved = refreshDoc();
    if (moved or stale) {
        recompute();
        stale = false;
    }
}

/// The query or its options changed: search again and land on the first
/// match at or after the origin.
fn seek() void {
    stale = true;
    sync();
    const pick = search.nearest(matches.items, origin);
    land(pick);
}

/// Select match `pick` (or, with none, put the caret back where the search
/// started), then repaint and redraw.
fn land(pick: ?search.Pick) void {
    if (pick) |p| {
        current = p.index;
        const s = matches.items[p.index];
        weft.setSelection(.{ .start = s.start, .end = s.end });
        if (p.wrapped) weft.echo("find: wrapped around");
    } else {
        current = null;
        weft.jump(origin);
    }
    paint();
    render();
}

/// Where the caret is, as a span: the selection, or an empty span at the
/// caret.
fn here() Span {
    if (weft.selection()) |s| return .{ .start = s.start, .end = s.end };
    const c = weft.cursor();
    return .{ .start = c, .end = c };
}

/// F3 / S-F3 (and Enter / S-Enter in the bar): step from the caret, which
/// is the current match while the bar is open and wherever the user left
/// it once the bar is closed.
fn go(forward: bool) void {
    if (bar_open and !live()) return;
    if (query.len == 0) return weft.echo("find: nothing to find");
    remember();
    sync();
    if (problem.len > 0) return reportProblem();
    if (matches.items.len == 0) {
        render();
        return weft.echo("find: no matches");
    }
    const at = here();
    // A caret sitting ON a match (the one the last step selected) steps past
    // it; a bare caret takes the first match at or after it.
    const pick = if (forward)
        search.nearest(matches.items, if (at.end > at.start) at.start + 1 else at.start)
    else
        search.before(matches.items, at.start);
    origin = matches.items[pick.?.index].start;
    land(pick);
}

fn findNext() void {
    go(true);
}

fn findPrev() void {
    go(false);
}

/// Enter: the next match in the query field, a replacement in the template.
fn accept() void {
    if (!live()) return;
    if (focus == .template) replaceOne() else go(true);
}

fn reportProblem() void {
    var buf: [128]u8 = undefined;
    weft.echo(std.fmt.bufPrint(&buf, "find: {s}", .{problem}) catch "find: bad pattern");
}

// ── Replacing and selecting ──────────────────────────────────────────

/// The match the caret is on, or the first at or after the origin.
fn currentMatch() ?usize {
    if (search.indexOf(matches.items, here())) |i| return i;
    return if (search.nearest(matches.items, origin)) |p| p.index else null;
}

/// Replace the current match and move to the next one.
fn replaceOne() void {
    if (!live()) return;
    sync();
    if (problem.len > 0) return reportProblem();
    const i = currentMatch() orelse return weft.echo("find: no matches");
    const span = matches.items[i];
    const bytes = (matcher.?.replacement(gpa, doc.items, span, template.text()) catch null) orelse return;
    defer gpa.free(bytes);
    remember();
    weft.edit(.{ .start = span.start, .end = span.end }, bytes);
    weft.flash(span.start, span.start + bytes.len);
    // Past what was just written, so a replacement that itself matches is
    // not replaced again on the next Enter.
    origin = span.start + bytes.len;
    seek();
}

/// Replace every match. Planned in full first, then applied last-first
/// as one undo unit, so the whole pass undoes as one step.
fn replaceAll() void {
    if (!live()) return weft.echo("find: open the replace bar first (find-replace)");
    sync();
    if (problem.len > 0) return reportProblem();
    if (matches.items.len == 0) return weft.echo("find: no matches");
    var plan = search.planAll(gpa, &matcher.?, doc.items, matches.items, template.text()) catch
        return weft.echo("find: out of memory");
    defer plan.deinit(gpa);
    if (plan.edits.len == 0) return weft.echo("find: no matches");
    remember();
    weft.undoUnit(applyLastFirst, .{plan.edits});
    // Flash what was written, as far as anyone can see it: the replacements
    // around the first one.
    const shown = search.window(plan.edits.len, 0, paint_window);
    const first = plan.landed(shown.start);
    weft.flash(first.start, first.end);
    for (shown.start + 1..shown.end) |k| {
        const r = plan.landed(k);
        weft.flashAdd(r.start, r.end);
    }
    var buf: [64]u8 = undefined;
    weft.echo(std.fmt.bufPrint(&buf, "find: replaced {d}", .{plan.edits.len}) catch "find: replaced");
    origin = first.start;
    seek();
}

/// Apply `edits` last-first, so an earlier one's offsets still hold.
fn applyLastFirst(edits: []const search.Edit) void {
    var i = edits.len;
    while (i > 0) {
        i -= 1;
        const e = edits[i];
        weft.edit(.{ .start = e.span.start, .end = e.span.end }, e.bytes);
    }
}

var sel_buf: [weft.max_selections]weft.Selection = undefined;

/// A selection per match (up to what one selection set carries), the
/// current match primary; the bar closes, the selections stay.
fn selectAll() void {
    if (bar_open and !live()) return;
    if (query.len == 0) return weft.echo("find: nothing to find");
    sync();
    if (problem.len > 0) return reportProblem();
    const n = @min(matches.items.len, sel_buf.len);
    if (n == 0) return weft.echo("find: no matches");
    for (matches.items[0..n], sel_buf[0..n]) |m, *s| s.* = .{ .anchor = m.start, .head = m.end };
    const primary = if (current) |c| @min(c, n - 1) else 0;
    remember();
    closeBar();
    _ = weft.setSelections(sel_buf[0..n], primary);
    var buf: [96]u8 = undefined;
    const msg = if (n < matches.items.len)
        std.fmt.bufPrint(&buf, "find: selected the first {d} of {d} matches", .{ n, matches.items.len })
    else
        std.fmt.bufPrint(&buf, "find: {d} selections", .{n});
    weft.echo(msg catch "find: selected");
}

// ── Drawing ──────────────────────────────────────────────────────────

/// Paint the matches around the current one; the current in its own colour.
/// Every round replaces the last, and an edit drops the paint until the
/// next round — which every edit here is followed by.
fn paint() void {
    if (!bar_open) return;
    const id = entry orelse return;
    if (layer == null) layer = weft.Annotations.open(id, layer_name);
    const anno = layer orelse return;
    if (!anno.begin()) {
        anno.close();
        layer = null;
        return;
    }
    if (matches.items.len == 0) return;
    const w = search.window(matches.items.len, current orelse 0, paint_window);
    for (matches.items[w.start..w.end], w.start..) |s, i| {
        anno.span(s.start, s.end, if (current == i) .location else .emphasis, .range, "");
    }
}

fn clearPaint() void {
    if (layer) |anno| anno.close();
    layer = null;
}

var row_buf: [2 * field_cap + 256]u8 = undefined;

/// The bar: the query row with its count and options, and the replacement
/// row when replacing. The field being typed into carries the caret mark.
fn render() void {
    if (!bar_open) return;
    const mark = "▏";
    var count_buf: [48]u8 = undefined;
    const count: []const u8 = if (problem.len > 0)
        problem
    else if (query.len == 0)
        "type to search"
    else if (matches.items.len == 0)
        "no matches"
    else
        std.fmt.bufPrint(&count_buf, "{d}/{d}{s}", .{
            (current orelse 0) + 1, matches.items.len, if (truncated) "+" else "",
        }) catch "";
    weft.surfaceBegin(.bottom);
    weft.surfaceRow();
    const find_row = std.fmt.bufPrint(&row_buf, "Find: {s}{s}   {s}   M-r regex:{s}  M-c case:{s}  M-w word:{s}", .{
        query.text(),      if (focus == .query) mark else "",
        count,             if (opts.regex) "on" else "off",
        opts.case.label(), if (opts.whole_word) "on" else "off",
    }) catch "Find:";
    weft.surfaceSpan(find_row, if (focus == .query) .normal else .muted);
    if (replacing) {
        weft.surfaceRow();
        const replace_row = std.fmt.bufPrint(&row_buf, "Replace: {s}{s}   Enter one  C-M-Return all  M-Return select all", .{
            template.text(), if (focus == .template) mark else "",
        }) catch "Replace:";
        weft.surfaceSpan(replace_row, if (focus == .template) .normal else .muted);
    }
    weft.surfaceEnd(-1);
}
