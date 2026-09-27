//! ts — structural (tree-sitter) navigation + selection (design §6.2), a
//! `.wasm` plugin with perms `{}` (view; reads only). It composes the native
//! `syntax` surface — `nodeAt`, `nodeEnclosing` (expand-to-scope), `query`
//! (materialized captures) — none of which lets the TREE cross the membrane;
//! only kinds and byte spans do. Selection uses the native `editor.setSelection`
//! primitive. Grammar-agnostic: `ts-select-function` grows by node KIND, and
//! `ts-query` runs a caller-supplied `.scm`, so nothing hardcodes a language.

const std = @import("std");
const weft = @import("weft");

const cmds = [_]weft.CommandEntry{
    .{ .name = "ts-node-kind", .call = nodeKind, .arity = .whole, .summary = "say what syntax node the cursor is in" },
    .{ .name = "ts-select-node", .arity = weft.Arity.each_extent, .call = selectNode, .summary = "select the syntax node under the cursor" },
    .{ .name = "ts-expand-selection", .arity = weft.Arity.each_extent, .call = expandSelection, .summary = "grow the selection to the enclosing node" },
    .{ .name = "ts-goto-parent", .arity = weft.Arity.each_extent, .call = gotoParent, .summary = "move to the enclosing node" },
    .{ .name = "ts-select-function", .arity = weft.Arity.each_extent, .call = selectFunction, .summary = "select the enclosing function" },
    .{ .name = "ts-select-class", .arity = weft.Arity.each_extent, .call = selectClass, .summary = "select the enclosing class" },
    .{ .name = "ts-select-call", .arity = weft.Arity.each_extent, .call = selectCall, .summary = "select the enclosing call" },
    .{ .name = "ts-select-block", .arity = weft.Arity.each_extent, .call = selectBlock, .summary = "select the enclosing block" },
    .{ .name = "ts-select-comment", .arity = weft.Arity.each_extent, .call = selectComment, .summary = "select the enclosing comment" },
    .{ .name = "ts-goto-first-child", .arity = weft.Arity.each_extent, .call = gotoFirstChild, .summary = "move to the first child node" },
    .{ .name = "ts-select-child", .arity = weft.Arity.each_extent, .call = selectChild, .summary = "select the first child node" },
    .{ .name = "ts-raise", .arity = weft.Arity.each_extent, .call = raise, .summary = "replace the enclosing node with this one" },
    .{ .name = "ts-query", .call = queryCount, .arity = .whole, .summary = "count what a tree-sitter query matches here" },
    // Range-returning forms (like `textobjects`: an absolute span, not a
    // move). Each answers for THE selection, so dispatch maps them over
    // every selection a grammar has; none touches the selection itself.
    .{ .name = "ts.expand", .arity = weft.Arity.each_extent, .call = rangeExpand, .summary = "the node enclosing the selection" },
    .{ .name = "ts.shrink", .arity = weft.Arity.each_extent, .call = rangeShrink, .summary = "the first child node inside the selection" },
    .{ .name = "ts.sibling-next", .arity = weft.Arity.each_extent, .call = rangeSiblingNext, .summary = "the node after the selection's node" },
    .{ .name = "ts.sibling-prev", .arity = weft.Arity.each_extent, .call = rangeSiblingPrev, .summary = "the node before the selection's node" },
    .{ .name = "ts.function-next", .arity = weft.Arity.each_extent, .call = rangeFunctionNext, .summary = "the next function after the cursor's line" },
    .{ .name = "ts.function-prev", .arity = weft.Arity.each_extent, .call = rangeFunctionPrev, .summary = "the previous function before the cursor's line" },
};

var raise_buf: [1 << 15]u8 = undefined;

/// The current selection, or an empty range at the cursor.
fn sel() weft.Range {
    return weft.selection() orelse .{ .start = weft.cursor(), .end = weft.cursor() };
}

fn nodeKind() void {
    const n = weft.nodeAt(weft.cursor()) orelse return;
    weft.echo(n.kind);
}

fn selectNode() void {
    const n = weft.nodeAt(weft.cursor()) orelse return;
    weft.setSelection(.{ .start = n.start, .end = n.end });
}

/// Grow the selection to the smallest enclosing named node (repeat to widen).
fn expandSelection() void {
    const n = weft.nodeEnclosing(sel()) orelse return;
    weft.setSelection(.{ .start = n.start, .end = n.end });
}

fn gotoParent() void {
    const cur = weft.cursor();
    const n = weft.nodeEnclosing(.{ .start = cur, .end = cur }) orelse return;
    weft.jump(n.start);
}

/// Grow to the nearest enclosing node whose KIND contains ANY of `needles`
/// (grammar-agnostic — no language node names are hardcoded).
fn selectKind(comptime needles: []const []const u8) void {
    var r = sel();
    var i: usize = 0;
    while (i < 64) : (i += 1) {
        const n = weft.nodeEnclosing(r) orelse return;
        inline for (needles) |needle| {
            if (std.mem.indexOf(u8, n.kind, needle) != null)
                return weft.setSelection(.{ .start = n.start, .end = n.end });
        }
        r = .{ .start = n.start, .end = n.end };
    }
}
const function_kinds = [_][]const u8{ "function", "fn_", "method" };

fn selectFunction() void {
    selectKind(&function_kinds);
}
fn selectClass() void {
    selectKind(&.{ "class", "struct", "enum", "interface", "trait" });
}
fn selectCall() void {
    selectKind(&.{ "call", "invocation" });
}
fn selectBlock() void {
    selectKind(&.{ "block", "body", "compound" });
}
fn selectComment() void {
    selectKind(&.{"comment"});
}

/// Descend: move the cursor to the first named child of the node at point.
fn gotoFirstChild() void {
    if (weft.nodeChildren(weft.cursor()) == 0) return;
    const c = weft.queryCapture(0) orelse return;
    weft.jump(c.start);
}
/// Descend + select: select the first named child of the node at point.
fn selectChild() void {
    if (weft.nodeChildren(weft.cursor()) == 0) return;
    const c = weft.queryCapture(0) orelse return;
    weft.setSelection(.{ .start = c.start, .end = c.end });
}

/// Raise: replace the enclosing parent node with the node at point (unwrap —
/// e.g. `(x + y)` → `x + y`, or lift an expression out of its wrapper). One
/// grade-gated edit.
fn raise() void {
    const cur = weft.nodeAt(weft.cursor()) orelse return;
    const parent = weft.nodeEnclosing(.{ .start = cur.start, .end = cur.end }) orelse return;
    const txt = weft.slice(cur.start, cur.end); // borrows shim scratch
    const n = @min(txt.len, raise_buf.len);
    @memcpy(raise_buf[0..n], txt[0..n]);
    weft.edit(.{ .start = parent.start, .end = parent.end }, raise_buf[0..n]);
    weft.jump(parent.start);
}

/// Run a caller-supplied tree-sitter query over the whole buffer and return the
/// capture count (exercises the materialized-capture path). Argument: the `.scm`.
fn queryCount() void {
    const scm = weft.argStr(0) orelse return weft.setResultInt(0);
    const n = weft.query(scm, .{ .start = 0, .end = weft.byteLen() });
    weft.setResultInt(@intCast(n));
}

// ── Range forms ───────────────────────────────────────────────────────
// Each answers a span for "the selection" (the one a mapping's run visits,
// else the primary), or nothing. The tree is read through
// the same three doors as the verbs above: no new door, no language name.

fn ret(r: weft.Range) void {
    if (weft.anchorRange(r)) |h| weft.setResultRange(h);
}

/// The selection, or the node under a caret — what "the selection's node" is
/// when nothing is selected.
fn subject() ?weft.Range {
    if (weft.selection()) |s| if (s.end > s.start) return s;
    const n = weft.nodeAt(weft.cursor()) orelse return null;
    return .{ .start = n.start, .end = n.end };
}

fn isBlank(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r';
}

/// The first non-blank offset in `[from, to)`, or `to`.
fn skipBlankFwd(from: usize, to: usize) usize {
    var at = from;
    while (at < to) {
        const t = weft.slice(at, @min(to, at + 256));
        if (t.len == 0) return to;
        for (t, 0..) |c, i| if (!isBlank(c)) return at + i;
        at += t.len;
    }
    return to;
}

/// One past the last non-blank offset in `[from, to)`, or `from`.
fn skipBlankBack(from: usize, to: usize) usize {
    var at = to;
    while (at > from) {
        const lo = @max(from, at -| 256);
        const t = weft.slice(lo, at);
        if (t.len == 0) return from;
        var i = t.len;
        while (i > 0) : (i -= 1) if (!isBlank(t[i - 1])) return lo + i;
        at = lo;
    }
    return from;
}

/// The largest node over `off` that stays strictly inside `outer` and within
/// `[lo, hi)`: a child of `outer`, found by climbing from the leaf.
fn childAt(off: usize, outer: weft.Range, lo: usize, hi: usize) ?weft.Range {
    const leaf = weft.nodeAt(off) orelse return null;
    var c: weft.Range = .{ .start = leaf.start, .end = leaf.end };
    if (c.start < lo or c.end > hi or (c.start == outer.start and c.end == outer.end)) return null;
    var i: usize = 0;
    while (i < 64) : (i += 1) {
        const e = weft.nodeEnclosing(c) orelse break;
        if ((e.start == outer.start and e.end == outer.end) or e.start < lo or e.end > hi) break;
        c = .{ .start = e.start, .end = e.end };
    }
    return c;
}

/// Grow: the smallest node strictly enclosing the selection.
fn rangeExpand() void {
    const s = weft.selection() orelse weft.Range{ .start = weft.cursor(), .end = weft.cursor() };
    const n = weft.nodeEnclosing(s) orelse return;
    ret(.{ .start = n.start, .end = n.end });
}

/// Shrink: the first child inside the selection; with a caret, the node
/// under it.
fn rangeShrink() void {
    const s = weft.selection() orelse {
        const n = weft.nodeAt(weft.cursor()) orelse return;
        return ret(.{ .start = n.start, .end = n.end });
    };
    var at = skipBlankFwd(s.start, s.end);
    while (at < s.end) {
        if (childAt(at, s, s.start, s.end)) |c| return ret(c);
        at = skipBlankFwd(at + 1, s.end);
    }
}

/// The next sibling: the first child of the parent that starts after the
/// selection's node ends. Punctuation between siblings has no named node of
/// its own, so the scan steps past it.
fn rangeSiblingNext() void {
    const cur = subject() orelse return;
    const p = weft.nodeEnclosing(cur) orelse return;
    const parent: weft.Range = .{ .start = p.start, .end = p.end };
    var at = skipBlankFwd(cur.end, parent.end);
    while (at < parent.end) {
        if (childAt(at, parent, cur.end, parent.end)) |c| return ret(c);
        at = skipBlankFwd(at + 1, parent.end);
    }
}

/// The previous sibling, mirrored.
fn rangeSiblingPrev() void {
    const cur = subject() orelse return;
    const p = weft.nodeEnclosing(cur) orelse return;
    const parent: weft.Range = .{ .start = p.start, .end = p.end };
    var end = skipBlankBack(parent.start, cur.start);
    while (end > parent.start) {
        if (childAt(end - 1, parent, parent.start, cur.start)) |c| return ret(c);
        end = skipBlankBack(parent.start, end - 1);
    }
}

fn isFunctionKind(kind: []const u8) bool {
    inline for (function_kinds) |needle| {
        if (std.mem.indexOf(u8, kind, needle) != null) return true;
    }
    return false;
}

/// The function node that STARTS at the first non-blank of the line holding
/// `line_off`, or null. Climbs from the leaf while the start holds, so it
/// finds a function however its declaration nests.
fn functionOnLine(line_off: usize) ?weft.Range {
    const l = weft.lineAt(line_off);
    const at = skipBlankFwd(l.start, l.end);
    if (at >= l.end) return null;
    const leaf = weft.nodeAt(at) orelse return null;
    var r: weft.Range = .{ .start = leaf.start, .end = leaf.end };
    var hit = isFunctionKind(leaf.kind);
    var i: usize = 0;
    while (i < 64) : (i += 1) {
        if (r.start != at) return null;
        if (hit) return r;
        const e = weft.nodeEnclosing(r) orelse return null;
        hit = isFunctionKind(e.kind);
        r = .{ .start = e.start, .end = e.end };
    }
    return null;
}

/// `]f`: the first function starting on a line after the cursor's.
fn rangeFunctionNext() void {
    const len = weft.byteLen();
    var l = weft.lineAt(weft.cursor());
    while (l.end < len) {
        l = weft.lineAt(l.end + 1);
        if (functionOnLine(l.start)) |r| return ret(r);
    }
}

/// `[f`: the nearest function starting on a line before the cursor's.
fn rangeFunctionPrev() void {
    var l = weft.lineAt(weft.cursor());
    while (l.start > 0) {
        l = weft.lineAt(l.start - 1);
        if (functionOnLine(l.start)) |r| return ret(r);
    }
}

comptime {
    weft.plugin(&cmds, .{}).exportAll();
}
