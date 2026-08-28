//! Viewport ATTRIBUTES — small, orthogonal, workspace-enforced properties of
//! a pane (doc/contextual-workspace-architecture.md §7, decided in
//! doc/cwa-config-decisions.md D1). Deliberately NOT a role enum: a closed
//! `primary|dock|drawer` ontology bakes semantics into names whose vocabulary
//! churns, and every sidebar-ish plugin then reinvents window management
//! around it. "Sidebar" and "drawer" are named BUNDLES of these attributes in
//! a config fragment (`sidebar` below is the bundle, not a kind).
//!
//! Each attribute earns its place by the rendering.md granularity rule —
//! someone would swap just it:
//!
//! - `cycles`: a docked tree should not appear in `focus-other`'s rotation,
//!   but a peek split should.
//! - `persistent`: a sidebar keeps its own entry when the active buffer
//!   changes; an ordinary pane follows it.
//! - `dock`: an edge-anchored extent instead of a share of a split.
//! - `focus_source`: whether focus landing here is a PRIMARY-focus change on
//!   `focus_feed`. False for companions, which is what structurally kills the
//!   outline-retargets-to-itself bug (D2): a companion cannot observe its own
//!   focus, so it cannot chase it.
//!
//! Attributes live in core, not `gfx/window_layout.zig`, because the focus
//! feed and the placement policy both read them and neither may depend on
//! gfx. The pane TREE (geometry, dock nodes) stays in gfx.

const std = @import("std");

/// Which frame edge a docked viewport anchors to.
pub const Edge = enum {
    left,
    right,
    top,
    bottom,

    /// The name a config fragment writes, and what `parseEdge` accepts.
    pub fn label(self: Edge) []const u8 {
        return @tagName(self);
    }
};

/// `""` and unknown spellings are `null` (undocked) — a caller that needs a
/// typo to be loud checks for the empty string itself.
pub fn parseEdge(name: []const u8) ?Edge {
    return std.meta.stringToEnum(Edge, name);
}

pub const Attrs = struct {
    /// Participates in pane cycling (`focus-other`).
    cycles: bool = true,
    /// Keeps its own workspace entry when the active entry changes.
    persistent: bool = false,
    /// Anchored to a frame edge at a fixed share, rather than tiled.
    dock: ?Edge = null,
    /// Focus landing here is a primary-focus change others may follow.
    focus_source: bool = true,

    /// The ordinary tiled pane every split produces.
    pub const tiled: Attrs = .{};

    /// The "sidebar" bundle — the whole of what makes a sidebar, as data.
    pub fn sidebar(edge: Edge) Attrs {
        return .{ .cycles = false, .persistent = true, .dock = edge, .focus_source = false };
    }

    /// Eligible to host an ordinary workspace entry: the panes placement
    /// treats as "primary". A docked companion is not one even if some other
    /// attribute were relaxed, so this is a conjunction, not an alias.
    pub fn isPrimary(self: Attrs) bool {
        return self.dock == null and !self.persistent;
    }

    pub fn eql(self: Attrs, other: Attrs) bool {
        return std.meta.eql(self, other);
    }
};

const t = std.testing;

test "viewport: the sidebar bundle is attributes, not a kind" {
    const bar = Attrs.sidebar(.left);
    try t.expectEqual(@as(?Edge, .left), bar.dock);
    try t.expect(!bar.cycles);
    try t.expect(bar.persistent);
    try t.expect(!bar.focus_source);
    try t.expect(!bar.isPrimary());

    // Every attribute is independently settable: a bottom drawer that DOES
    // cycle and DOES source focus is expressible without a new role name.
    const drawer: Attrs = .{ .dock = .bottom, .persistent = true };
    try t.expect(drawer.cycles);
    try t.expect(drawer.focus_source);
    try t.expect(!drawer.isPrimary());

    try t.expect(Attrs.tiled.isPrimary());
    try t.expect(Attrs.tiled.eql(.{}));
}

test "viewport: edge names round-trip; an unknown spelling is not an edge" {
    for (std.enums.values(Edge)) |e|
        try t.expectEqual(@as(?Edge, e), parseEdge(e.label()));
    try t.expectEqual(@as(?Edge, null), parseEdge(""));
    try t.expectEqual(@as(?Edge, null), parseEdge("LEFT"));
}
