//! Per-head semantic focus path.

const scene = @import("scene.zig");
const view = @import("view.zig");

/// Directional intent over a semantic focus order. Editors bind their usual
/// movement commands to this open surface; a tool does not need to know which
/// editing model produced the intent.
pub const Movement = enum { previous, next, first, last };

pub const Path = struct {
    view: view.Ref,
    nodes: []const scene.NodeId,
    field: ?scene.FieldRef = null,

    pub fn leaf(self: Path) ?scene.NodeId {
        return if (self.nodes.len == 0) null else self.nodes[self.nodes.len - 1];
    }
};
