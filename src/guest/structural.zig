//! structural (wasm twin) — syntax-aware editing (src/core/catalog/structural.zig)
//! recompiled as `.wasm`. `node-kind` reports the tree-sitter construct under
//! the cursor; `delete-node` removes the innermost named node as one
//! grade-gated edit. Built from `nodeAt` (the host-resolved structural read)
//! + the edit door — the same substrate textobjects/folding compose from,
//! now across the membrane.

const weft = @import("weft.zig");

var id_kind: u32 = 0;
var id_del: u32 = 0;

export fn describe() void {
    weft.declareCommand("node-kind");
    weft.declareCommand("delete-node");
}

export fn init() void {
    id_kind = weft.register("node-kind");
    id_del = weft.register("delete-node");
}

export fn on_command(id: u32) void {
    if (id == id_kind) nodeKind() else if (id == id_del) deleteNode();
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
