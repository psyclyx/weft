//! structural — syntax-aware editing (the structural edge of the edit
//! domain), a catalog plugin over `abi.zig`. `node-kind` reports the
//! tree-sitter construct under the cursor; `delete-node` removes the
//! innermost named node (an argument, a statement, a string) as one
//! plugin-authored, grade-gated edit. Built purely from `nodeAt` (the
//! host-resolved syntax read) + the edit door — the substrate textobjects,
//! folding, and slurp/barf compose from.

const std = @import("std");
const abi = @import("../abi.zig");
const command = @import("../command.zig");

pub fn plugin() abi.Plugin {
    return .{ .describe = describe, .init = init };
}

fn describe() abi.Manifest {
    return .{ .name = "structural", .commands = &.{ .{ .name = "node-kind" }, .{ .name = "delete-node" } } };
}

fn init(a: *abi.Abi) anyerror!void {
    try a.registerCommand("node-kind", nodeKind);
    try a.registerCommand("delete-node", deleteNode);
}

/// The grammar kind of the node under the cursor (borrowed; valid this
/// frame), or nil when there is no grammar / no node.
fn nodeKind(a: *abi.Abi, args: []const command.Value) anyerror!command.Value {
    _ = args;
    const node = a.nodeAt(a.cursor()) orelse return .nil;
    return .{ .string = node.kind };
}

/// Delete the innermost named node under the cursor; returns the byte count
/// removed (0 when there is no node).
fn deleteNode(a: *abi.Abi, args: []const command.Value) anyerror!command.Value {
    _ = args;
    const node = a.nodeAt(a.cursor()) orelse return .{ .integer = 0 };
    try a.edit(.{ .start = node.start, .end = node.end }, "");
    return .{ .integer = @intCast(node.end - node.start) };
}
