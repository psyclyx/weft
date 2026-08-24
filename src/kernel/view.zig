//! Per-buffer view instance identity and description.

const handle = @import("handle.zig");
const scene = @import("scene.zig");
const target = @import("target.zig");

pub const Tag = struct {};
pub const Ref = handle.Handle(Tag);

pub const Descriptor = struct {
    ref: Ref,
    owner: []const u8,
    target: ?target.Ref = null,
    revision: u64 = 0,
    root: scene.NodeId,
};
