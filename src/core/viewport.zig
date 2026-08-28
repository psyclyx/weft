//! Viewport ATTRIBUTES — small, orthogonal, workspace-enforced properties of
//! a pane (doc/contextual-workspace-architecture.md §7, decided in
//! doc/cwa-config-decisions.md D1). Deliberately NOT a role enum: a closed
//! `primary|dock|drawer` ontology bakes semantics into names whose vocabulary
//! churns, and every sidebar-ish plugin then reinvents window management
//! around it. "Sidebar" and "drawer" are named BUNDLES of these attributes in
//! a config fragment (`config/sidebar.js`); no name for one appears here, so
//! nothing downstream can come to depend on core knowing what a sidebar is.
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

    /// The ordinary tiled pane every split produces. Deliberately the only
    /// named bundle in core: "sidebar" and "drawer" are bundles a CONFIG
    /// FRAGMENT names (see `config/sidebar.js`), and a constructor for one
    /// here would be the closed role ontology D1 rejected, reintroduced under
    /// a different spelling.
    pub const tiled: Attrs = .{};

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

/// One declared viewport plus the workspace's note of whether it has been
/// realized yet. The declaration half is manifest data (`weft.viewport` /
/// `weft.present`); `pane`/`presented` are the layout phase's bookkeeping,
/// kept beside it so "declared but not yet on screen" is one lookup rather
/// than a second parallel table that can disagree with this one.
pub const Declaration = struct {
    name: []u8,
    attrs: Attrs,
    extent: f32,
    /// The resource to present, or `""` for none.
    subject: []u8,
    /// The `window_layout` pane slot this was materialized into.
    pane: ?u32 = null,
    presented: bool = false,
};

/// The declared viewports of one system. Keyed by name, last declaration
/// wins — so a config RELOAD re-declaring "sidebar" updates it in place
/// instead of docking a second one, and re-applying an unchanged manifest is
/// a genuine no-op (which is what lets `Manifest.reconcile` leave viewports
/// out of its teardown pass).
pub const Registry = struct {
    list: std.ArrayList(Declaration) = .empty,

    pub const empty: Registry = .{};

    pub fn deinit(self: *Registry, gpa: std.mem.Allocator) void {
        for (self.list.items) |d| {
            gpa.free(d.name);
            gpa.free(d.subject);
        }
        self.list.deinit(gpa);
        self.* = undefined;
    }

    pub fn find(self: *Registry, name: []const u8) ?*Declaration {
        for (self.list.items) |*d| {
            if (std.mem.eql(u8, d.name, name)) return d;
        }
        return null;
    }

    pub fn declare(self: *Registry, gpa: std.mem.Allocator, name: []const u8, attrs: Attrs, extent: f32) !void {
        if (self.find(name)) |d| {
            d.attrs = attrs;
            d.extent = extent;
            return;
        }
        const owned = try gpa.dupe(u8, name);
        errdefer gpa.free(owned);
        const subject = try gpa.dupe(u8, "");
        errdefer gpa.free(subject);
        try self.list.append(gpa, .{ .name = owned, .attrs = attrs, .extent = extent, .subject = subject });
    }

    /// "Present resource R in viewport V" as a declaration. A NEW subject
    /// clears `presented`, so the layout phase presents it; the same subject
    /// again changes nothing.
    pub fn present(self: *Registry, gpa: std.mem.Allocator, name: []const u8, subject: []const u8) !void {
        const d = self.find(name) orelse return error.UnknownViewport;
        if (std.mem.eql(u8, d.subject, subject)) return;
        const owned = try gpa.dupe(u8, subject);
        gpa.free(d.subject);
        d.subject = owned;
        d.presented = false;
    }
};

const t = std.testing;

/// What a config fragment calls a "sidebar", written out: four attributes and
/// nothing else. Spelled here in the tests rather than exported, so no caller
/// can start depending on core knowing the word.
const companion: Attrs = .{ .cycles = false, .persistent = true, .dock = .left, .focus_source = false };

test "viewport: a registry declaration is idempotent and re-presentable" {
    const gpa = t.allocator;
    var reg: Registry = .empty;
    defer reg.deinit(gpa);

    try reg.declare(gpa, "sidebar", companion, 0.25);
    try reg.present(gpa, "sidebar", ".");
    reg.find("sidebar").?.pane = 3;
    reg.find("sidebar").?.presented = true;

    // Re-applying the same manifest updates in place — no second sidebar,
    // and nothing already realized is disturbed.
    try reg.declare(gpa, "sidebar", companion, 0.25);
    try reg.present(gpa, "sidebar", ".");
    try t.expectEqual(@as(usize, 1), reg.list.items.len);
    try t.expectEqual(@as(?u32, 3), reg.find("sidebar").?.pane);
    try t.expect(reg.find("sidebar").?.presented);

    // A new subject is a new presentation, and only that.
    try reg.present(gpa, "sidebar", "src");
    try t.expect(!reg.find("sidebar").?.presented);
    try t.expectEqual(@as(?u32, 3), reg.find("sidebar").?.pane);

    try t.expectError(error.UnknownViewport, reg.present(gpa, "nope", "."));
}

test "viewport: a sidebar is a bundle of attributes, not a kind" {
    const bar = companion;
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
