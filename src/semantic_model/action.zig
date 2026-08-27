//! Semantic action requests shared by input plugins and tool/view providers.
//! Names are open protocol strings: core routes them but does not implement
//! editor modes or tool-specific policy.

const interaction = @import("interaction.zig");
const scene = @import("scene.zig");
const selection = @import("selection.zig");
const target = @import("target.zig");
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

/// Provider-neutral request to follow a named edge from an exact source
/// target revision. Core resolves the relation and chooses the target handler.
pub const RelationRequest = struct {
    source: target.Located,
    name: []const u8,
};

pub const Outcome = union(enum) {
    declined,
    handled,
    /// Capture-only: the provider must not mutate its model before returning
    /// this borrowed value. The host first takes ownership; an input model may
    /// then issue a separate delete action for copy-then-delete workflows
    /// (Vim `dd`, for example) without losing data if capture/allocation fails.
    /// A transfer whose own intent is `.cut` instead remains a deferred move
    /// consumed by paste.
    transfer: transfer.Item,
    /// Request-only: mutation waits for an action on the resulting dialog.
    interaction: interaction.Definition,
    /// Request-only: ask core to resolve and admit the located target through
    /// the generic target-handler registry. The provider never chooses a
    /// handler or manufactures a view handle.
    open_target: target.Located,
    /// Request-only: move the dispatching head to another stable node in the
    /// same retained view. This is useful for tool actions that reveal or
    /// enter a secondary field without knowing the caller's editing model.
    /// Core validates the node against the request view before changing focus.
    focus: scene.NodeId,
    /// Request-only: resolve a named relation from this exact source and open
    /// the admitted destination. Handler selection remains core policy.
    open_relation: RelationRequest,
    /// Request-only: make an exact, whole target the dispatching head's
    /// working container. Core validates the descriptor revision before
    /// storing it; relative-effect routing remains a provider concern.
    set_working_target: target.Located,
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
    /// Follow the provider-owned `container` relation of the focused view's
    /// target. A directory parent is one use; archives, remote loci, and
    /// synthetic hierarchies can expose the same interaction.
    pub const open_container = "target.open-container";
    /// Open or close the subject's own children IN PLACE. This is the other
    /// half of hierarchy movement: `open_container` leaves the current locus
    /// for the one above it, while this one splices a locus into the view
    /// that already shows it. A node advertises it exactly when something can
    /// open or close it, which is what the generic Tab offer reads.
    pub const toggle_expanded = "hierarchy.toggle-expanded";
    /// Set the focused whole target as this head's working container. This is
    /// the target-oriented analogue of `cd`: it applies equally to local,
    /// remote, archive, and synthetic hierarchies.
    pub const set_working_target = "workspace.set-working-target";
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
