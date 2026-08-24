//! Per-head semantic focus path.

const scene = @import("scene.zig");
const view = @import("view.zig");

pub const Path = struct {
    view: view.Ref,
    nodes: []const scene.NodeId,
    field: ?scene.FieldRef = null,

    pub fn leaf(self: Path) ?scene.NodeId {
        return if (self.nodes.len == 0) null else self.nodes[self.nodes.len - 1];
    }
};
