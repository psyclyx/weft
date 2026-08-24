//! Head-local interaction/dialog contracts. Presentation and key policy are
//! providers layered on these semantic actions.

const handle = @import("handle.zig");
const scene = @import("scene.zig");

pub const Tag = struct {};
pub const Ref = handle.Handle(Tag);

pub const Role = enum { dialog, picker, popup, custom };

pub const Action = struct {
    id: []const u8,
    label: []const u8,
    enabled: bool = true,
};

pub const Descriptor = struct {
    ref: Ref,
    role: Role,
    root: scene.NodeId,
    actions: []const Action,
    default_action: ?[]const u8 = null,
    cancel_action: ?[]const u8 = null,
    presentation: []const u8 = &.{},
};
