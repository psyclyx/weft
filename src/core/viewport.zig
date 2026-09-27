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
//! - `cycles`: a docked tree should not appear in `window.focus-next`'s rotation,
//!   but a peek split should.
//! - `persistent`: a sidebar keeps its own entry when the active buffer
//!   changes; an ordinary pane follows it.
//! - `dock`: an edge-anchored extent instead of a share of a split.
//! - `focus_source`: whether focus landing here moves the PRIMARY context
//!   (`context.zig`). False for companions, which is what structurally kills
//!   the outline-retargets-to-itself bug (D2): a companion cannot observe its
//!   own focus, so it cannot chase it.
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
const semantic = @import("weft_semantic");
const durable = semantic.durable;
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
    /// Participates in pane cycling (`window.focus-next`).
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

/// A designation, or the name of ONE context key whose current value is one
/// (doc/model.md §2.5, doc/cwa-config-decisions.md D2 revisited): what a
/// viewport presents (`subject`) or highlights inside it (`reveal`). Never an
/// expression — a key is read, not evaluated, so there is no function, no
/// composition and no evaluation order to define.
pub const Binding = struct {
    /// The designation (or an absolute path standing in for one), or the
    /// context key when `key` is set; `""` binds nothing.
    text: []const u8 = "",
    key: bool = false,

    pub const none: Binding = .{};

    pub fn isSet(self: Binding) bool {
        return self.text.len != 0;
    }

    /// Whether this is bound to `name`, the key a context change reported.
    pub fn follows(self: Binding, name: []const u8) bool {
        return self.key and std.mem.eql(u8, self.text, name);
    }

    pub fn eql(a: Binding, b: Binding) bool {
        return a.key == b.key and std.mem.eql(u8, a.text, b.text);
    }
};

/// Everything `weft.present(viewport, {subject, as, reveal})` says.
pub const Presentation = struct {
    subject: Binding = .none,
    /// Which projection of the subject to show, when its kind has several:
    /// `dir` as a tree or a list, `offers` as a strip or a menu — or another
    /// producer's projection OF the subject (`symbols` of an entry). It rides
    /// to `open` as the designation's `as` view parameter, and routing reads
    /// it there (`designation.openHeld`). A plain lowercase name.
    as: []const u8 = "",
    reveal: Binding = .none,
};

pub const PresentError = error{ UnknownViewport, RelativeSubject, MalformedSubject, MalformedKey, MalformedProjection, PathWithProjection } || std.mem.Allocator.Error;

/// Refuse what could never present, where it is written: a relative path
/// names nothing, a key must be one word, and `as` is a name.
pub fn validate(p: Presentation) PresentError!void {
    try validateBinding(p.subject);
    try validateBinding(p.reveal);
    if (p.as.len == 0) return;
    if (!durable.Kind.isProjectionName(p.as)) return error.MalformedProjection;
    // A path's kind is not in its spelling, so there is no designation to
    // carry the projection: name it by its designation instead.
    if (!p.subject.key and durable.Spec.of(p.subject.text) == .path) return error.PathWithProjection;
}

fn validateBinding(b: Binding) PresentError!void {
    if (!b.isSet()) return;
    if (b.key) {
        if (std.mem.indexOfAny(u8, b.text, " \t\n?&=/") != null) return error.MalformedKey;
        return;
    }
    switch (durable.Spec.of(b.text)) {
        .designation, .path => {},
        .relative => return error.RelativeSubject,
        .malformed => return error.MalformedSubject,
    }
}

/// One declared viewport plus the workspace's note of whether it has been
/// realized yet. The declaration half is manifest data (`weft.viewport` /
/// `weft.present`); `pane`/`presented` are the layout phase's bookkeeping,
/// kept beside it so "declared but not yet on screen" is one lookup rather
/// than a second parallel table that can disagree with this one.
/// Where a pending reveal waits: the view asked, at the revision it answered.
pub const RevealWait = struct {
    view: semantic.view.Ref,
    revision: u64,
};

pub const Declaration = struct {
    name: []u8,
    attrs: Attrs,
    extent: Extent,
    /// What to present (`Binding`; its text owned). A literal subject is a
    /// designation or an absolute path standing in for one (`durable.Spec`);
    /// a relative path is refused where it is declared (`present`), never
    /// resolved later against wherever the process happens to be. A keyed
    /// subject is re-read, and re-presented, when that key of the primary
    /// context moves — and only then, so a persistent viewport keeps what the
    /// user navigated to inside it until the key changes.
    subject: Binding = .none,
    /// The projection to present the subject as (`Presentation.as`), owned.
    as: []u8 = &.{},
    /// What to highlight inside what is presented, without taking focus
    /// (`Binding`; its text owned).
    reveal: Binding = .none,
    /// The `window_layout` pane slot this was materialized into.
    pane: ?u32 = null,
    presented: bool = false,
    /// The reveal is to be (re)applied at the next layout phase: after a
    /// presentation, or when the reveal key moved.
    reveal_due: bool = false,
    /// A reveal the provider accepted but could not answer yet (it has
    /// folders to read, off the layout pass): the view and the revision it
    /// answered at. Asked again when that view republishes — the provider's
    /// own "the children arrived" — and never before, so nothing polls.
    reveal_waits: ?RevealWait = null,
    /// What a keyed subject resolved to when it was last presented — the
    /// designation opened, `as` included, or `""` for the empty state.
    /// Owned. Compared, never interpreted, so showing a hidden viewport
    /// again re-presents only when its key moved while it was away.
    resolved: ?[]u8 = null,
    /// The entry that says "nothing to present here" for this viewport,
    /// made the first time a keyed subject has no value, and reused.
    empty: ?EmptyState = null,
    /// The entry the last presentation MADE (it did not exist before), so
    /// the next one can close it once nothing shows it: following a key
    /// must not leave a trail of listings behind as tabs.
    made: ?Buffers.Ref = null,
    /// Whether the workspace holds this viewport on screen. A declaration
    /// starts shown; `toggle` flips it and the layout phase docks or undocks
    /// to match. Workspace state, not manifest data: a config reload
    /// re-declaring the viewport leaves it as the user left it.
    shown: bool = true,
    /// The entry this viewport last showed: what the layout phase presented
    /// into it, or what `take` put there. Kept across a hide, so showing it
    /// again brings the same entry back rather than whatever is active, and
    /// so the chrome can tell a docked companion's entry from a document
    /// (`holdsEntry`). Held as the entry's DESIGNATION (doc/model.md §2.2),
    /// owned: the entry can close and its slot be reused by an unrelated
    /// entry, which a slot would then name and the viewport capture. A
    /// designation names what was shown instead, so a reused slot is simply
    /// something else, and a closed entry is opened again when the viewport
    /// next shows.
    entry: ?[]u8 = null,
    /// A pending `take`: put the entry opening this designation in the
    /// viewport, show it, and focus it, at the next layout phase. Owned.
    take: ?[]u8 = null,

    /// The empty state's entry and the view it shows.
    pub const EmptyState = struct { entry_generation: u64, view: semantic.view.Ref };

    /// Whether there is anything to present.
    pub fn hasPresentation(self: *const Declaration) bool {
        return self.subject.isSet();
    }

    fn freeBindings(self: *Declaration, gpa: std.mem.Allocator) void {
        gpa.free(self.subject.text);
        gpa.free(self.as);
        gpa.free(self.reveal.text);
        self.subject = .none;
        self.as = &.{};
        self.reveal = .none;
    }
};

/// The declared viewports of one system. Keyed by name, last declaration
/// wins — so a config RELOAD re-declaring "sidebar" updates it in place
/// instead of docking a second one, and re-applying an unchanged manifest is
/// a genuine no-op (which is what lets `Manifest.reconcile` leave viewports
/// out of its teardown pass).
pub const Registry = struct {
    list: std.ArrayList(Declaration) = .empty,
    /// Who publishes the empty states' views (core, through the workspace's
    /// semantic services), acquired on first need.
    owner: ?semantic.owner.Id = null,

    pub const empty: Registry = .{};

    pub fn deinit(self: *Registry, gpa: std.mem.Allocator) void {
        for (self.list.items) |*d| {
            gpa.free(d.name);
            d.freeBindings(gpa);
            if (d.entry) |held| gpa.free(held);
            if (d.take) |held| gpa.free(held);
            if (d.resolved) |held| gpa.free(held);
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
        try self.list.append(gpa, .{ .name = owned, .attrs = attrs, .extent = extent, .shown = !opts.hidden });
    }

    /// Publish every declared viewport's shown state into `context` as the
    /// global key `viewport.<name>.shown` — `on` while shown, absent while
    /// hidden — so what is on screen is a FACT like any other: a toggle
    /// command's check mark reads it (doc/chrome.md §1.2 `toggle`), and a
    /// predicate may name it. Called wherever the state is decided.
    pub fn publishShown(self: *const Registry, context: *@import("context.zig").Context) void {
        for (self.list.items) |d| {
            var buf: [96]u8 = undefined;
            const key = std.fmt.bufPrint(&buf, "viewport.{s}.shown", .{d.name}) catch continue;
            _ = context.store.set("viewport", .global, key, if (d.shown) "on" else "") catch {};
        }
    }

    /// Flip whether `name` is held on screen; returns the new state. Only the
    /// intent is recorded here — the layout phase realizes it, exactly as it
    /// realizes a declaration.
    pub fn toggle(self: *Registry, name: []const u8) error{UnknownViewport}!bool {
        const d = self.find(name) orelse return error.UnknownViewport;
        d.shown = !d.shown;
        return d.shown;
    }

    /// Put the entry opening `designation` in `name`, show it, and focus it —
    /// at the next layout phase, which owns the pane tree. What a plugin runs
    /// to bring its own entry (a terminal, a problems list) into a declared
    /// panel: the viewport shows one entry at a time, so this REPLACES what it
    /// showed.
    pub fn takeEntry(self: *Registry, gpa: std.mem.Allocator, name: []const u8, designation: []const u8) (error{UnknownViewport} || std.mem.Allocator.Error)!void {
        const d = self.find(name) orelse return error.UnknownViewport;
        try hold(gpa, &d.take, designation);
        d.shown = true;
    }

    /// Replace the designation `slot` holds (null lets go).
    pub fn hold(gpa: std.mem.Allocator, slot: *?[]u8, designation: ?[]const u8) std.mem.Allocator.Error!void {
        const owned: ?[]u8 = if (designation) |text| try gpa.dupe(u8, text) else null;
        if (slot.*) |old| gpa.free(old);
        slot.* = owned;
    }

    /// Whether the entry designated `designation` is what some DOCKED
    /// viewport holds — a companion's entry (a file tree, a panel, a
    /// toolbar), which the chrome lists apart from the documents (never as a
    /// tab).
    pub fn holdsEntry(self: *const Registry, designation: []const u8) bool {
        for (self.list.items) |d| {
            if (d.attrs.dock == null) continue;
            const held = d.entry orelse continue;
            if (std.mem.eql(u8, held, designation)) return true;
        }
        return false;
    }

    /// "Present resource R in viewport V" as a declaration. A NEW
    /// presentation clears `presented`, so the layout phase presents it; the
    /// same one again changes nothing. A literal subject must name something
    /// wherever it is read: a designation or an absolute path.
    pub fn present(self: *Registry, gpa: std.mem.Allocator, name: []const u8, p: Presentation) PresentError!void {
        try validate(p);
        const d = self.find(name) orelse return error.UnknownViewport;
        if (d.subject.eql(p.subject) and std.mem.eql(u8, d.as, p.as) and d.reveal.eql(p.reveal)) return;
        const subject = try gpa.dupe(u8, p.subject.text);
        errdefer gpa.free(subject);
        const as = try gpa.dupe(u8, p.as);
        errdefer gpa.free(as);
        const reveal = try gpa.dupe(u8, p.reveal.text);
        d.freeBindings(gpa);
        d.subject = .{ .text = subject, .key = p.subject.key };
        d.as = as;
        d.reveal = .{ .text = reveal, .key = p.reveal.key };
        d.presented = false;
        d.reveal_due = d.reveal.isSet();
        try hold(gpa, &d.resolved, null);
    }

    /// A context change reported `keys` moved: every viewport whose subject
    /// follows one of them presents again, and every one whose reveal does
    /// reveals again, at the next layout phase. Returns whether any did —
    /// the caller then runs that phase. This is `on_context_changed`'s own
    /// per-key comparison, read by the workspace: one mechanism for plugins
    /// and viewports alike.
    pub fn follow(self: *Registry, keys: []const []const u8) bool {
        var any = false;
        for (self.list.items) |*d| {
            for (keys) |k| {
                if (d.subject.follows(k)) {
                    d.presented = false;
                    any = true;
                }
                if (d.reveal.follows(k)) {
                    d.reveal_due = true;
                    any = true;
                }
            }
        }
        return any;
    }

    /// Whether any viewport's reveal waits on its provider — so the frame
    /// boundary, having delivered the signals a provider does its reading
    /// in, runs the layout phase once more to ask again.
    pub fn revealsWaiting(self: *const Registry) bool {
        for (self.list.items) |d| if (d.reveal_waits != null) return true;
        return false;
    }

    /// The context keys any declared viewport follows — so the frame
    /// boundary observes the primary context even when no plugin listens.
    pub fn followsAny(self: *const Registry) bool {
        for (self.list.items) |d| if (d.subject.key or d.reveal.key) return true;
        return false;
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
    try reg.present(gpa, "sidebar", .{ .subject = .{ .text = "/srv/proj" } });
    reg.find("sidebar").?.pane = 3;
    reg.find("sidebar").?.presented = true;

    // Re-applying the same manifest updates in place — no second sidebar,
    // and nothing already realized is disturbed.
    try reg.declare(gpa, "sidebar", companion, .{ .fraction = 0.25 });
    try reg.present(gpa, "sidebar", .{ .subject = .{ .text = "/srv/proj" } });
    try t.expectEqual(@as(usize, 1), reg.list.items.len);
    try t.expectEqual(@as(?u32, 3), reg.find("sidebar").?.pane);
    try t.expect(reg.find("sidebar").?.presented);

    // A new subject is a new presentation, and only that.
    try reg.present(gpa, "sidebar", .{ .subject = .{ .text = "weft://here/dir/srv/proj/src" } });
    try t.expect(!reg.find("sidebar").?.presented);
    try t.expectEqual(@as(?u32, 3), reg.find("sidebar").?.pane);

    try t.expectError(error.UnknownViewport, reg.present(gpa, "nope", .{ .subject = .{ .text = "/srv" } }));
    // A relative subject names nothing, and says so where it is written.
    try t.expectError(error.RelativeSubject, reg.present(gpa, "sidebar", .{ .subject = .{ .text = "." } }));
    try t.expectError(error.MalformedSubject, reg.present(gpa, "sidebar", .{ .subject = .{ .text = "weft://here/nope" } }));
    // A key is one word; `as` is a name; a bare path has no kind to project.
    try t.expectError(error.MalformedKey, reg.present(gpa, "sidebar", .{ .subject = .{ .text = "a b", .key = true } }));
    try t.expectError(error.MalformedProjection, reg.present(gpa, "sidebar", .{ .subject = .{ .text = "place", .key = true }, .as = "Tree!" }));
    try t.expectError(error.PathWithProjection, reg.present(gpa, "sidebar", .{ .subject = .{ .text = "/srv" }, .as = "tree" }));
    try t.expectEqualStrings("weft://here/dir/srv/proj/src", reg.find("sidebar").?.subject.text);
}

test "viewport: a subject bound to a context key presents again when THAT key moves, and a reveal reveals again" {
    const gpa = t.allocator;
    var reg: Registry = .empty;
    defer reg.deinit(gpa);
    try reg.declare(gpa, "sidebar", companion, .{ .fraction = 0.25 });
    try reg.declare(gpa, "strip", .{ .dock = .top, .takes_focus = false }, .{ .rows = 1 });
    try reg.present(gpa, "sidebar", .{ .subject = .{ .text = "place", .key = true }, .reveal = .{ .text = "entry", .key = true } });
    try reg.present(gpa, "strip", .{ .subject = .{ .text = "weft://here/offers/primary" }, .as = "strip" });
    try t.expect(reg.followsAny());
    const sidebar = reg.find("sidebar").?;
    try t.expect(sidebar.reveal_due);
    sidebar.presented = true;
    sidebar.reveal_due = false;
    reg.find("strip").?.presented = true;

    // A key nothing follows moves nothing.
    try t.expect(!reg.follow(&.{ "mode", "offers" }));
    try t.expect(sidebar.presented and !sidebar.reveal_due);
    // The entry moved: reveal again, but keep what the listing shows.
    try t.expect(reg.follow(&.{"entry"}));
    try t.expect(sidebar.presented and sidebar.reveal_due);
    // The place moved: present again. A literal subject never follows.
    try t.expect(reg.follow(&.{ "place", "entry" }));
    try t.expect(!sidebar.presented);
    try t.expect(reg.find("strip").?.presented);
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

test "viewport: a projection is part of the presentation, and rows are an extent" {
    const gpa = t.allocator;
    var reg: Registry = .empty;
    defer reg.deinit(gpa);
    try reg.declare(gpa, "strip", .{ .dock = .top, .takes_focus = false }, .{ .rows = 1 });
    try reg.present(gpa, "strip", .{ .subject = .{ .text = "weft://here/offers/primary" }, .as = "strip" });
    const d = reg.find("strip").?;
    try t.expectEqualStrings("strip", d.as);
    try t.expect(d.extent.eql(.{ .rows = 1 }));
    d.presented = true;
    // The same presentation is no change; another projection is a new one.
    try reg.present(gpa, "strip", .{ .subject = .{ .text = "weft://here/offers/primary" }, .as = "strip" });
    try t.expect(reg.find("strip").?.presented);
    try reg.present(gpa, "strip", .{ .subject = .{ .text = "weft://here/offers/primary" }, .as = "list" });
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
    const terminal = "weft://here/proc/terminal.1";
    const problems = "weft://here/diagnostics/srv/proj";
    try reg.takeEntry(gpa, "panel", terminal);
    try t.expect(reg.find("panel").?.shown);
    try t.expectEqualStrings(terminal, reg.find("panel").?.take.?);
    try t.expectError(error.UnknownViewport, reg.takeEntry(gpa, "nope", terminal));

    // Only what a DOCKED viewport shows is chrome.
    try Registry.hold(gpa, &reg.find("panel").?.entry, terminal);
    try t.expect(reg.holdsEntry(terminal));
    try t.expect(!reg.holdsEntry(problems));
    // What the panel holds is WHAT it showed: whichever entry opens that
    // designation now, never whatever reuses the slot the old one had.
    try t.expect(!reg.holdsEntry("weft://here/proc/terminal.2"));
    try reg.declare(gpa, "tiled", .{}, .{ .fraction = 0.5 });
    try Registry.hold(gpa, &reg.find("tiled").?.entry, problems);
    try t.expect(!reg.holdsEntry(problems));
}
