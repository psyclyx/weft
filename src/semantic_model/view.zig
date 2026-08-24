//! Per-buffer view instance identity and description.

const handle = @import("handle.zig");
const owner = @import("owner.zig");
const scene = @import("scene.zig");
const target = @import("target.zig");

pub const Tag = struct {};
pub const Ref = handle.Handle(Tag);

pub const Descriptor = struct {
    ref: Ref,
    owner: owner.Id,
    target: ?target.Ref = null,
    revision: u64 = 0,
    root: scene.NodeId,
};
