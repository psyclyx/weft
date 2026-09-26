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
//! - `takes_focus`: whether the pane can hold a head's keyboard focus at
//!   all. False for a strip of buttons: a click acts through it and the
//!   editor keeps the keys, so what the strip describes never moves under it.
//! - `status_line`: whether the pane carries its own status line. A one-row
//!   strip has no room for one, and nothing to say in it.
//!
//! Attributes live in core, not `gfx/window_layout.zig`, because the focus
//! feed and the placement policy both read them and neither may depend on
//! gfx. The pane TREE (geometry, dock nodes) stays in gfx.

const std = @import("std");
const Buffers = @import("Buffers.zig");

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
    /// A head's keyboard focus may land here (a click, a window command).
    takes_focus: bool = true,
    /// The pane draws its own status line under its body.
    status_line: bool = true,

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
        return self.dock == null and !self.persistent and self.takes_focus;
    }

    pub fn eql(self: Attrs, other: Attrs) bool {
        return std.meta.eql(self, other);
    }
};

/// How much of the frame a docked viewport takes along its edge: a SHARE of
/// the frame, or a count of text ROWS (a one-row strip of buttons). Rows are
/// resolved to pixels by whoever knows the row height — the window layout,
/// from the view's metrics — so a font-size change keeps a one-row strip one
/// row tall instead of freezing the pixels it happened to be at declaration.
pub const Extent = union(enum) {
    /// A share of the frame, clamped to (0.05, 0.95).
    fraction: f32,
    /// Whole text rows, at least one.
    rows: u16,

    pub fn eql(a: Extent, b: Extent) bool {
        return std.meta.eql(a, b);
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
    extent: Extent,
    /// The resource to present, or `""` for none.
    subject: []u8,
    /// The command that presents `subject` (`open` when empty): the entry it
    /// leaves active is what the viewport shows. A plugin whose entry has no
    /// path presents it by naming its own command here.
    command: []u8,
    /// The `window_layout` pane slot this was materialized into.
    pane: ?u32 = null,
    presented: bool = false,
    /// Whether the workspace holds this viewport on screen. A declaration
    /// starts shown; `toggle` flips it and the layout phase docks or undocks
    /// to match. Workspace state, not manifest data: a config reload
    /// re-declaring the viewport leaves it as the user left it.
    shown: bool = true,
    /// The entry this viewport last showed: what the layout phase presented
    /// into it, or what `take` put there. Kept across a hide, so showing it
    /// again brings the same entry back rather than whatever is active, and
    /// so the chrome can tell a docked companion's entry from a document
    /// (`holdsEntry`). A generation-checked `Buffers.Ref`, never a bare id:
    /// the entry can close and its slot be reused by an unrelated entry, which
    /// a bare id would then name — and the viewport would capture.
    entry: ?Buffers.Ref = null,
    /// A pending `take`: put this entry in the viewport, show it, and focus
    /// it, at the next layout phase. Generation-checked for the same reason.
    take: ?Buffers.Ref = null,

    /// Whether there is anything to present: a subject to open, or a command
    /// that presents on its own.
    pub fn hasPresentation(self: *const Declaration) bool {
        return self.subject.len != 0 or self.command.len != 0;
    }
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
            gpa.free(d.command);
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

    pub fn declare(self: *Registry, gpa: std.mem.Allocator, name: []const u8, attrs: Attrs, extent: Extent) !void {
        return self.declareWith(gpa, name, attrs, extent, .{});
    }

    pub const DeclareOptions = struct {
        /// Start hidden: a panel that opens on demand (`take`, a toggle)
        /// rather than at startup. Only a FIRST declaration reads it — a
        /// re-declaration leaves the shown state as the user left it.
        hidden: bool = false,
    };

    pub fn declareWith(self: *Registry, gpa: std.mem.Allocator, name: []const u8, attrs: Attrs, extent: Extent, opts: DeclareOptions) !void {
        if (self.find(name)) |d| {
            d.attrs = attrs;
            d.extent = extent;
            return;
        }
        const owned = try gpa.dupe(u8, name);
        errdefer gpa.free(owned);
        const subject = try gpa.dupe(u8, "");
        errdefer gpa.free(subject);
        const command = try gpa.dupe(u8, "");
        errdefer gpa.free(command);
        try self.list.append(gpa, .{ .name = owned, .attrs = attrs, .extent = extent, .subject = subject, .command = command, .shown = !opts.hidden });
    }

    /// Flip whether `name` is held on screen; returns the new state. Only the
    /// intent is recorded here — the layout phase realizes it, exactly as it
    /// realizes a declaration.
    pub fn toggle(self: *Registry, name: []const u8) error{UnknownViewport}!bool {
        const d = self.find(name) orelse return error.UnknownViewport;
        d.shown = !d.shown;
        return d.shown;
    }

    /// Put entry `entry` in `name`, show it, and focus it — at the next
    /// layout phase, which owns the pane tree. What a plugin runs to bring its
    /// own entry (a terminal, a problems list) into a declared panel: the
    /// viewport shows one entry at a time, so this REPLACES what it showed.
    pub fn takeEntry(self: *Registry, name: []const u8, entry: Buffers.Ref) error{UnknownViewport}!void {
        const d = self.find(name) orelse return error.UnknownViewport;
        d.take = entry;
        d.shown = true;
    }

    /// Whether `entry` is what some DOCKED viewport holds — a companion's
    /// entry (a file tree, a panel, a toolbar), which the chrome lists
    /// apart from the documents (never as a tab).
    pub fn holdsEntry(self: *const Registry, entry: Buffers.Ref) bool {
        for (self.list.items) |d| {
            if (d.attrs.dock == null) continue;
            const held = d.entry orelse continue;
            if (held.id == entry.id and held.generation == entry.generation) return true;
        }
        return false;
    }

    /// "Present resource R in viewport V" as a declaration. A NEW subject
    /// (or presenting command) clears `presented`, so the layout phase
    /// presents it; the same pair again changes nothing.
    pub fn present(self: *Registry, gpa: std.mem.Allocator, name: []const u8, subject: []const u8, command: []const u8) !void {
        const d = self.find(name) orelse return error.UnknownViewport;
        if (std.mem.eql(u8, d.subject, subject) and std.mem.eql(u8, d.command, command)) return;
        const owned = try gpa.dupe(u8, subject);
        errdefer gpa.free(owned);
        const owned_command = try gpa.dupe(u8, command);
        gpa.free(d.subject);
        gpa.free(d.command);
        d.subject = owned;
        d.command = owned_command;
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

    try reg.declare(gpa, "sidebar", companion, .{ .fraction = 0.25 });
    try reg.present(gpa, "sidebar", ".", "");
    reg.find("sidebar").?.pane = 3;
    reg.find("sidebar").?.presented = true;

    // Re-applying the same manifest updates in place — no second sidebar,
    // and nothing already realized is disturbed.
    try reg.declare(gpa, "sidebar", companion, .{ .fraction = 0.25 });
    try reg.present(gpa, "sidebar", ".", "");
    try t.expectEqual(@as(usize, 1), reg.list.items.len);
    try t.expectEqual(@as(?u32, 3), reg.find("sidebar").?.pane);
    try t.expect(reg.find("sidebar").?.presented);

    // A new subject is a new presentation, and only that.
    try reg.present(gpa, "sidebar", "src", "");
    try t.expect(!reg.find("sidebar").?.presented);
    try t.expectEqual(@as(?u32, 3), reg.find("sidebar").?.pane);

    try t.expectError(error.UnknownViewport, reg.present(gpa, "nope", ".", ""));
}

test "viewport: toggling is workspace state a re-declaration leaves alone" {
    const gpa = t.allocator;
    var reg: Registry = .empty;
    defer reg.deinit(gpa);

    try reg.declare(gpa, "sidebar", companion, .{ .fraction = 0.25 });
    try t.expect(reg.find("sidebar").?.shown);
    try t.expect(!try reg.toggle("sidebar"));
    // A config reload re-declares it; the choice to hide it stands.
    try reg.declare(gpa, "sidebar", companion, .{ .fraction = 0.25 });
    try t.expect(!reg.find("sidebar").?.shown);
    try t.expect(try reg.toggle("sidebar"));
    try t.expectError(error.UnknownViewport, reg.toggle("nope"));
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

    // A strip that never takes the keys is a companion however else it is
    // declared: no entry is ever placed where no head can focus it.
    const strip: Attrs = .{ .dock = .top, .takes_focus = false, .status_line = false };
    try t.expect(!strip.isPrimary());
    try t.expect(!(Attrs{ .takes_focus = false }).isPrimary());
}

test "viewport: a command presents what has no path, and rows are an extent" {
    const gpa = t.allocator;
    var reg: Registry = .empty;
    defer reg.deinit(gpa);
    try reg.declare(gpa, "strip", .{ .dock = .top, .takes_focus = false }, .{ .rows = 1 });
    try reg.present(gpa, "strip", "", "strip-open");
    const d = reg.find("strip").?;
    try t.expectEqualStrings("strip-open", d.command);
    try t.expect(d.extent.eql(.{ .rows = 1 }));
    d.presented = true;
    // The same pair is no change; a different command is a new presentation.
    try reg.present(gpa, "strip", "", "strip-open");
    try t.expect(reg.find("strip").?.presented);
    try reg.present(gpa, "strip", "", "other-open");
    try t.expect(!reg.find("strip").?.presented);
}

test "viewport: edge names round-trip; an unknown spelling is not an edge" {
    for (std.enums.values(Edge)) |e|
        try t.expectEqual(@as(?Edge, e), parseEdge(e.label()));
    try t.expectEqual(@as(?Edge, null), parseEdge(""));
    try t.expectEqual(@as(?Edge, null), parseEdge("LEFT"));
}

test "viewport: a panel can start hidden, take an entry, and holds it as chrome" {
    const gpa = t.allocator;
    var reg: Registry = .empty;
    defer reg.deinit(gpa);
    const panel: Attrs = .{ .dock = .bottom, .persistent = true, .cycles = false };
    try reg.declareWith(gpa, "panel", panel, .{ .rows = 12 }, .{ .hidden = true });
    try t.expect(!reg.find("panel").?.shown);
    // A re-declaration never re-hides what the user showed.
    reg.find("panel").?.shown = true;
    try reg.declareWith(gpa, "panel", panel, .{ .rows = 12 }, .{ .hidden = true });
    try t.expect(reg.find("panel").?.shown);

    reg.find("panel").?.shown = false;
    const seven: Buffers.Ref = .{ .id = 7, .generation = 1 };
    const eight: Buffers.Ref = .{ .id = 8, .generation = 1 };
    try reg.takeEntry("panel", seven);
    try t.expect(reg.find("panel").?.shown);
    try t.expectEqual(@as(?Buffers.Ref, seven), reg.find("panel").?.take);
    try t.expectError(error.UnknownViewport, reg.takeEntry("nope", seven));

    // Only what a DOCKED viewport shows is chrome.
    reg.find("panel").?.entry = seven;
    try t.expect(reg.holdsEntry(seven));
    try t.expect(!reg.holdsEntry(eight));
    // Slot 7 reused by a later entry is not what the panel holds.
    try t.expect(!reg.holdsEntry(.{ .id = 7, .generation = 2 }));
    try reg.declare(gpa, "tiled", .{}, .{ .fraction = 0.5 });
    reg.find("tiled").?.entry = eight;
    try t.expect(!reg.holdsEntry(eight));
}
