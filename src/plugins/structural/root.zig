//! structural — syntax-aware editing, a `.wasm` plugin. `structural.delete-node`
//! removes the innermost named node as one grade-gated edit. Built from `nodeAt` (the
//! host-resolved structural read) + the edit door — the same substrate
//! textobjects and folding compose from, across the membrane.

const weft = @import("weft");

const cmds = [_]weft.CommandEntry{
    .{ .name = "structural.delete-node", .call = deleteNode, .arity = weft.Arity.each_extent, .summary = "Delete the syntax node under the cursor.", .label = "Delete Syntax Node" },
};
comptime {
    weft.plugin(&cmds, .{}).exportAll();
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
