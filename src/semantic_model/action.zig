//! Semantic action requests shared by input plugins and tool/view providers.
//! Names are open protocol strings: core routes them but does not implement
//! editor modes or tool-specific policy.

const interaction = @import("interaction.zig");
const scene = @import("scene.zig");
const selection = @import("selection.zig");
const transfer = @import("transfer.zig");
const view = @import("view.zig");

pub const Request = struct {
    action: []const u8,
    view: view.Ref,
    subject: scene.NodeId,
    selection: selection.Selection = .none,
    /// Paste-like actions receive the current system transfer here. Other
    /// actions ignore it; absence is explicit rather than an empty sentinel.
    transfer: ?transfer.Item = null,
};

pub const Outcome = union(enum) {
    declined,
    handled,
    /// Capture-only: the provider must not mutate its model before returning
    /// this borrowed value. The host first takes ownership; a controller may
    /// then issue a separate delete action for cut semantics without losing
    /// data if capture/allocation fails.
    transfer: transfer.Item,
    /// Request-only: mutation waits for an action on the resulting dialog.
    interaction: interaction.Definition,
};

/// Interoperable names are conveniences, not a closed enum. A plugin may
/// define additional actions without changing core or coordinating globally.
pub const standard = struct {
    pub const copy = "selection.copy";
    pub const cut = "selection.cut";
    pub const delete = "selection.delete";
    pub const paste_before = "selection.paste-before";
    pub const paste_after = "selection.paste-after";
    pub const open = "target.open";
    pub const edit = "field.edit";
    /// Lifecycle intents for retained, structured views.  They are open
    /// protocol names: a provider advertises only the ones it supports, while
    /// generic input configurations can expose them without knowing the
    /// provider (directory editor, picker, or another tool).
    pub const refresh = "view.refresh";
    pub const revert = "view.revert";
    pub const apply = "view.apply";
    pub const confirm = "interaction.confirm";
    pub const cancel = "interaction.cancel";
};
