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
    .{ .name = "ts-node-kind", .call = nodeKind, .summary = "say what syntax node the cursor is in" },
    .{ .name = "ts-select-node", .call = selectNode, .summary = "select the syntax node under the cursor" },
    .{ .name = "ts-expand-selection", .call = expandSelection, .summary = "grow the selection to the enclosing node" },
    .{ .name = "ts-goto-parent", .call = gotoParent, .summary = "move to the enclosing node" },
    .{ .name = "ts-select-function", .call = selectFunction, .summary = "select the enclosing function" },
    .{ .name = "ts-select-class", .call = selectClass, .summary = "select the enclosing class" },
    .{ .name = "ts-select-call", .call = selectCall, .summary = "select the enclosing call" },
    .{ .name = "ts-select-block", .call = selectBlock, .summary = "select the enclosing block" },
    .{ .name = "ts-select-comment", .call = selectComment, .summary = "select the enclosing comment" },
    .{ .name = "ts-goto-first-child", .call = gotoFirstChild, .summary = "move to the first child node" },
    .{ .name = "ts-select-child", .call = selectChild, .summary = "select the first child node" },
    .{ .name = "ts-raise", .call = raise, .summary = "replace the enclosing node with this one" },
    .{ .name = "ts-query", .call = queryCount, .summary = "count what a tree-sitter query matches here" },
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
fn selectFunction() void {
    selectKind(&.{ "function", "fn_", "method" });
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

comptime {
    weft.plugin(&cmds, .{}).exportAll();
}
