//! Head-local interaction/dialog contracts. Presentation and key policy are
//! providers layered on these semantic actions.

const handle = @import("handle.zig");
const scene = @import("scene.zig");
const view = @import("view.zig");

pub const Tag = struct {};
pub const Ref = handle.Handle(Tag);

pub const Role = enum { dialog, picker, popup, custom };

pub const Disposition = enum {
    keep_open,
    close_on_handled,
};

/// Interaction actions are intentionally distinct from actions advertised by
/// ordinary scene nodes. The latter say what a subject can do; this value also
/// says what should happen to the head-local interaction after that action is
/// handled. No editor mode or dialog-specific command is involved.
pub const Action = struct {
    id: []const u8,
    label: []const u8 = &.{},
    enabled: bool = true,
    disposition: Disposition = .keep_open,
};

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
