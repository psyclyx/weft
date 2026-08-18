//! ts — structural (tree-sitter) navigation + selection (design §6.2), a
//! `.wasm` plugin with perms `{}` (view; reads only). It composes the native
//! `syntax` surface — `nodeAt`, `nodeEnclosing` (expand-to-scope), `query`
//! (materialized captures) — none of which lets the TREE cross the membrane;
//! only kinds and byte spans do. Selection uses the native `editor.setSelection`
//! primitive. Grammar-agnostic: `ts-select-function` grows by node KIND, and
//! `ts-query` runs a caller-supplied `.scm`, so nothing hardcodes a language.

const std = @import("std");
const weft = @import("weft.zig");

const Cmd = struct { name: []const u8, handler: *const fn () void };
const cmds = [_]Cmd{
    .{ .name = "ts-node-kind", .handler = nodeKind },
    .{ .name = "ts-select-node", .handler = selectNode },
    .{ .name = "ts-expand-selection", .handler = expandSelection },
    .{ .name = "ts-goto-parent", .handler = gotoParent },
    .{ .name = "ts-select-function", .handler = selectFunction },
    .{ .name = "ts-query", .handler = queryCount },
};

export fn describe() void {
    for (cmds) |c| weft.declareCommand(c.name);
}
export fn init() void {
    for (cmds) |c| _ = weft.register(c.name);
}
export fn on_command(id: u32) void {
    if (id < cmds.len) cmds[id].handler();
}

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

/// Grow to the nearest enclosing function-like node (kind contains "function",
/// "fn", or "method" — grammar-agnostic).
fn selectFunction() void {
    var r = sel();
    var i: usize = 0;
    while (i < 64) : (i += 1) {
        const n = weft.nodeEnclosing(r) orelse return;
        if (isFn(n.kind)) return weft.setSelection(.{ .start = n.start, .end = n.end });
        r = .{ .start = n.start, .end = n.end };
    }
}
fn isFn(kind: []const u8) bool {
    return std.mem.indexOf(u8, kind, "function") != null or
        std.mem.indexOf(u8, kind, "fn_") != null or
        std.mem.indexOf(u8, kind, "method") != null;
}

/// Run a caller-supplied tree-sitter query over the whole buffer and return the
/// capture count (exercises the materialized-capture path). Argument: the `.scm`.
fn queryCount() void {
    const scm = weft.argStr(0) orelse return weft.setResultInt(0);
    const n = weft.query(scm, .{ .start = 0, .end = weft.byteLen() });
    weft.setResultInt(@intCast(n));
}
