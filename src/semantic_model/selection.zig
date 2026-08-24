//! Selections are semantic values. Text ranges remain one case rather than the
//! representation every tool must flatten itself into.

const scene = @import("scene.zig");

pub const TextRange = struct {
    field: scene.FieldRef,
    start: u64,
    end: u64,
    linewise: bool = false,
};

pub const Custom = struct {
    schema: []const u8,
    payload: []const u8,
};

pub const Selection = union(enum) {
    none,
    text: TextRange,
    nodes: []const scene.NodeId,
    custom: Custom,
};
