//! structural — syntax-aware editing, a `.wasm` plugin. `node-kind` reports
//! the tree-sitter construct under the cursor; `delete-node` removes the
//! innermost named node as one grade-gated edit. Built from `nodeAt` (the
//! host-resolved structural read) + the edit door — the same substrate
//! textobjects and folding compose from, across the membrane.

const weft = @import("weft");

const cmds = [_]weft.CommandEntry{
    .{ .name = "node-kind", .call = nodeKind, .summary = "say what syntax node the cursor is in" },
    .{ .name = "delete-node", .call = deleteNode, .summary = "delete the syntax node under the cursor" },
};
comptime {
    weft.plugin(&cmds, .{}).exportAll();
}

/// The grammar kind of the node under the cursor, or nil (no grammar / node).
fn nodeKind() void {
    const node = weft.nodeAt(weft.cursor()) orelse return; // result stays nil
    weft.setResultStr(node.kind);
}

/// Delete the innermost named node under the cursor; result is the byte count
/// removed (0 when there is no node).
fn deleteNode() void {
    const node = weft.nodeAt(weft.cursor()) orelse {
        weft.setResultInt(0);
        return;
    };
    weft.edit(.{ .start = node.start, .end = node.end }, "");
    weft.setResultInt(@intCast(node.end - node.start));
}
