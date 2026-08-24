//! Per-buffer view instance identity and description.

const handle = @import("handle.zig");
const owner = @import("owner.zig");
const scene = @import("scene.zig");
const target = @import("target.zig");

pub const Tag = struct {};
pub const Ref = handle.Handle(Tag);

/// The immutable target revision a retained view represents. A target handle
/// may remain live across descriptor replacement, so the handle alone cannot
/// prove that an already-open view still describes the revision a resolver
/// selected.
pub const TargetBinding = struct {
    ref: target.Ref,
    revision: u64,
};

pub const Descriptor = struct {
    ref: Ref,
    owner: owner.Id,
    target: ?TargetBinding = null,
    revision: u64 = 0,
    root: scene.NodeId,
};
