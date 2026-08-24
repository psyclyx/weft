//! Head-local interaction/dialog contracts. Presentation and key policy are
//! providers layered on these semantic actions.

const handle = @import("handle.zig");
const scene = @import("scene.zig");
const view = @import("view.zig");

pub const Tag = struct {};
pub const Ref = handle.Handle(Tag);

pub const Role = enum { dialog, picker, popup, custom };

pub const Action = scene.Action;

/// Interaction-local input routing. These bindings are consulted only while
/// the interaction is active; they do not create an editor mode and do not
/// implicitly open a global key-help surface.
pub const Binding = struct {
    input: []const u8,
    action: []const u8,
};

/// Plugin-authored interaction meaning before the host assigns identity.
/// `presentation` is an open-ended renderer hint, not a core layout choice.
pub const Definition = struct {
    role: Role,
    view: view.Ref,
    root: scene.NodeId,
    actions: []const Action,
    bindings: []const Binding = &.{},
    default_action: ?[]const u8 = null,
    cancel_action: ?[]const u8 = null,
    presentation: []const u8 = &.{},
};

pub const Descriptor = struct {
    ref: Ref,
    role: Role,
    view: view.Ref,
    root: scene.NodeId,
    actions: []const Action,
    bindings: []const Binding = &.{},
    default_action: ?[]const u8 = null,
    cancel_action: ?[]const u8 = null,
    presentation: []const u8 = &.{},
};
