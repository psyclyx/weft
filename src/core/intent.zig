//! The intention PLANE — the live wiring between a binding's intention arms
//! (doc/configuration.md §5.2), the pushed-offer kernel in `catalog.zig`, and
//! the code that actually runs a decision.
//!
//! `catalog.zig` stays pure: it ranks opaque `EndpointToken`s and never
//! dereferences one. This is where a token MEANS something — `Invokers`
//! below owns the token contract, and `Plane` bundles the catalog, that
//! registry, and core's own editing provider into the ONE value a
//! `command.Context` carries, so a half-wired pair is unrepresentable.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Actions = @import("action.zig");
const catalog_mod = @import("catalog.zig");
const command = @import("command.zig");
const intentions = @import("intentions.zig");
const semantic = @import("semantic.zig");
const view_offers = @import("view_offers.zig");
const action_here = @import("action_here.zig");
const action_offers = @import("action_offers.zig");
const Head = @import("Head.zig");

pub const Catalog = catalog_mod.Catalog;
pub const IntentionId = catalog_mod.IntentionId;
pub const Decision = catalog_mod.Decision;

// ── The endpoint-token contract ──────────────────────────────────────

/// THE CONTRACT an offer provider mints tokens under. An `EndpointToken` is
/// `(slot, generation, payload)`:
///
///   · `slot`       — which registered invoker runs it;
///   · `generation` — that slot's registration, bumped on `unregister`, so a
///                    token outliving its provider is REFUSED, never run;
///   · `payload`    — 32 bits private to that invoker (a command index, a
///                    scene node, a view handle). Nothing else reads them.
///
/// A provider registers an invoker once, mints tokens off its `Handle`, and
/// publishes them in an offer table. `Invokers.invoke` rechecks slot and
/// generation at the effect door, because catalog visibility is never
/// authority (architecture §9.1). Registration is open: a new provider kind
/// plugs in here without dispatch learning what it is.
pub const Endpoint = packed struct(u64) {
    payload: u32 = 0,
    generation: u16 = 0,
    slot: u16 = 0,

    pub fn token(self: Endpoint) catalog_mod.EndpointToken {
        return @bitCast(self);
    }

    pub fn of(raw: catalog_mod.EndpointToken) Endpoint {
        return @bitCast(raw);
    }
};

/// A registered invoker's minting handle — the only way to make a valid token.
pub const Handle = struct {
    slot: u16,
    generation: u16,

    pub fn endpoint(self: Handle, payload: u32) catalog_mod.EndpointToken {
        return (Endpoint{ .slot = self.slot, .generation = self.generation, .payload = payload }).token();
    }
};

pub const InvokeFn = *const fn (data: ?*anyopaque, ctx: *command.Context, payload: u32) anyerror!void;

pub const Error = error{ StaleEndpoint, StaleDecision };

/// Token → invoke fn + generation.
pub const Invokers = struct {
    const Slot = struct {
        /// Borrowed (a literal at every call site); trace text only.
        name: []const u8,
        invoke: ?InvokeFn,
        data: ?*anyopaque,
        generation: u16,
    };

    slots: std.ArrayList(Slot) = .empty,

    pub fn deinit(self: *Invokers, gpa: Allocator) void {
        self.slots.deinit(gpa);
        self.* = .{};
    }

    pub fn register(
        self: *Invokers,
        gpa: Allocator,
        name: []const u8,
        run: InvokeFn,
        data: ?*anyopaque,
    ) Allocator.Error!Handle {
        for (self.slots.items, 0..) |*s, i| {
            if (s.invoke != null) continue;
            s.* = .{ .name = name, .invoke = run, .data = data, .generation = s.generation };
            return .{ .slot = @intCast(i), .generation = s.generation };
        }
        try self.slots.append(gpa, .{ .name = name, .invoke = run, .data = data, .generation = 1 });
        return .{ .slot = @intCast(self.slots.items.len - 1), .generation = 1 };
    }

    /// Retire an invoker: every token it minted is refused from here on, and
    /// the slot is reusable at a new generation.
    pub fn unregister(self: *Invokers, handle: Handle) void {
        if (handle.slot >= self.slots.items.len) return;
        const s = &self.slots.items[handle.slot];
        if (s.generation != handle.generation) return;
        s.invoke = null;
        s.generation +%= 1;
        if (s.generation == 0) s.generation = 1;
    }

    /// The registered invoker a token names — trace text, never authority.
    pub fn invokerName(self: *const Invokers, raw: catalog_mod.EndpointToken) []const u8 {
        const e = Endpoint.of(raw);
        if (e.slot >= self.slots.items.len) return "?";
        return self.slots.items[e.slot].name;
    }

    pub fn invoke(self: *const Invokers, ctx: *command.Context, raw: catalog_mod.EndpointToken) anyerror!void {
        const e = Endpoint.of(raw);
        if (e.slot >= self.slots.items.len) return Error.StaleEndpoint;
        const s = self.slots.items[e.slot];
        if (s.generation != e.generation) return Error.StaleEndpoint;
        const f = s.invoke orelse return Error.StaleEndpoint;
        return f(s.data, ctx, e.payload);
    }
};

// ── Core's own editing offers ────────────────────────────────────────

/// A `std.*` intention and the core builtin that already implements it. The
/// table IS the provider: authority stays where it was, at the command door
/// (`command.run` → `command.edit`), exactly as when the same builtin is
/// bound by name.
const CoreOffer = struct {
    intention: []const u8,
    command: []const u8,
    /// Whether the offer needs an editable text endpoint to mean anything.
    /// The EDITING offers do; the break-out (§10.4) is about how the entry
    /// takes input, so it stands exactly where text does not.
    needs_text: bool = true,
};

const core_offers = [_]CoreOffer{
    .{ .intention = "std.history.undo", .command = "undo" },
    .{ .intention = "std.history.redo", .command = "redo" },
    .{ .intention = "std.persistence.save", .command = "save" },
    .{ .intention = "std.editing.insert-line-break", .command = "insert-newline" },
    .{ .intention = "std.input.break-out", .command = "posture-break-out", .needs_text = false },
};

/// A text-needing core offer on an editor-less entry gets `disabled` rather
/// than absence, so a fallback list REPORTS the obstacle instead of quietly
/// running its next arm (§9.3, §10.2).
const no_text: catalog_mod.Availability = .{ .disabled = .{
    .reason = "no-text",
    .message = "this entry holds no text",
} };

fn invokeCore(data: ?*anyopaque, ctx: *command.Context, payload: u32) anyerror!void {
    _ = data;
    if (payload >= core_offers.len) return Error.StaleEndpoint;
    _ = try command.run(ctx.commands, ctx, core_offers[payload].command, &.{});
}

// ── The plane ────────────────────────────────────────────────────────

/// Pinned once initialized: the published core table BORROWS `rows`, per the
/// catalog's publication discipline. `System` heap-allocates it, so it never
/// moves.
pub const Plane = struct {
    catalog: Catalog,
    invokers: Invokers = .{},
    provider: catalog_mod.ProviderId = undefined,
    handle: Handle = undefined,
    rows: [core_offers.len]catalog_mod.Offer = undefined,
    revision: u64 = 0,
    /// The entry shape the published table was computed for.
    has_text: bool = true,
    /// Core's other built-in provider: the generic adapter that derives a
    /// focused view's std offers from its scene (`view_offers.zig`). Held
    /// here for the same reason as the editing table — a plane without its
    /// host providers is a half-wired state nothing should be able to build.
    views: view_offers.Publisher = undefined,
    /// The DERIVED table: every declared action with an eligible provider
    /// here. `view_offers` derives from a scene.s shape; this derives from the
    /// providers bound against the focused context, which is what connects
    /// `provide` to the plane a keystroke actually reads.
    derived: *action_offers.Publisher = undefined,
    derived_attached: bool = false,

    /// Wire the DERIVED publisher, once `Actions` exists. Separate from `init`
    /// because the two are constructed in the other order and neither can be
    /// moved: `Actions` needs the container, the plane needs the catalog, and
    /// the derived table needs both.
    pub fn attachActions(self: *Plane, gpa: Allocator, actions: *Actions) !void {
        const pub_ptr = try gpa.create(action_offers.Publisher);
        errdefer gpa.destroy(pub_ptr);
        pub_ptr.* = try action_offers.Publisher.init(gpa, self, actions);
        self.derived = pub_ptr;
        self.derived_attached = true;
    }

    pub fn init(self: *Plane, gpa: Allocator) !void {
        self.* = .{ .catalog = .init(gpa) };
        errdefer self.deinit(gpa);
        // The std vocabulary is interned up front so a binding naming it
        // resolves without a first-use allocation on the keystroke path.
        for (intentions.std_intentions) |i| _ = try self.catalog.intention(i.name);
        self.provider = try self.catalog.provider("core.editing");
        self.handle = try self.invokers.register(gpa, "core.editing", invokeCore, null);
        for (core_offers, 0..) |offer, i| self.rows[i] = .{
            .intention = try self.catalog.intention(offer.intention),
            .endpoint = self.handle.endpoint(@intCast(i)),
        };
        try self.publishCore();
        self.views = try .init(gpa, self);
    }

    pub fn deinit(self: *Plane, gpa: Allocator) void {
        if (self.derived_attached) {
            self.derived.deinit(gpa);
            gpa.destroy(self.derived);
            self.derived_attached = false;
        }
        self.invokers.deinit(gpa);
        self.catalog.deinit();
        self.* = undefined;
    }

    /// Republish the view adapter's table when this head's focus or scene
    /// moved. A signature comparison when nothing moved; no probe either way.
    pub fn syncFocus(
        self: *Plane,
        services: *const semantic.Services,
        head: *const Head,
        here: ?view_offers.Here,
    ) Allocator.Error!void {
        _ = try self.views.refresh(&self.catalog, services, head, here);
    }

    /// What point is on, when the active entry is a text PROJECTION and its
    /// producer named the semantic view behind it. The view adapter derives
    /// what a listing affords from this, exactly as it derives a scene's from
    /// the focused node — one question, two planes.
    fn hereFor(ctx: *command.Context) ?view_offers.Here {
        const entry = ctx.buffers.active();
        const view = entry.tool_view orelse return null;
        if (action_here.subjectsHere(ctx).row) |node| return .{ .view = view, .node = node };
        // NO ROW IS NOT NOTHING. An empty directory has a listing, and what it
        // affords — paste, create — is the LISTING's, which is the same
        // fallback `action_here` makes when it offers a verb to the view after
        // the row declines.
        const services = ctx.semantic orelse return null;
        const instance = services.views.get(view) orelse return null;
        return .{ .view = view, .node = instance.scene.id };
    }

    /// Republish the DERIVED table when the context or the provider set moved.
    /// A signature comparison when nothing moved — the same pushed-offer
    /// discipline every other table here follows, so nothing recomputes
    /// eligibility on the keystroke path.
    pub fn syncDerived(self: *Plane, gpa: Allocator, f: @import("weft_facts").Facts) !void {
        if (!self.derived_attached) return;
        _ = try self.derived.refresh(gpa, &self.catalog, f);
    }

    /// Republish core's table when the focused entry's shape changes — the
    /// pushed-offer discipline: eligibility moves because a provider says so,
    /// never because something probed it mid-resolution.
    pub fn syncEntryShape(self: *Plane, has_text: bool) Allocator.Error!void {
        if (self.has_text == has_text and self.revision != 0) return;
        self.has_text = has_text;
        try self.publishCore();
    }

    fn publishCore(self: *Plane) Allocator.Error!void {
        for (&self.rows, core_offers) |*row, offer|
            row.availability = if (self.has_text or !offer.needs_text) .enabled else no_text;
        self.revision += 1;
        _ = try self.catalog.publish(.{
            .provider = self.provider,
            .revision = self.revision,
            .tier = .core,
            .offers = &self.rows,
        });
    }

    /// Intern a binding's arm NAMES into ids, in authored order. Interning is
    /// a hash hit after a name's first use; the resolution that follows
    /// (`Snapshot.resolve`) allocates nothing at all.
    pub fn armIds(
        self: *Plane,
        names: []const []const u8,
        out: []IntentionId,
    ) (catalog_mod.NameError || Allocator.Error)![]const IntentionId {
        std.debug.assert(names.len <= out.len);
        for (names, 0..) |n, i| out[i] = try self.catalog.intention(n);
        return out[0..names.len];
    }

    /// The snapshot of everything offered to `ctx` right now — the ONE place
    /// core's own providers re-publish before a single offer is read. Pushed,
    /// not probed: eligibility moves because a provider said so. Both syncs
    /// are value comparisons when nothing moved, and an unchanged context
    /// leaves the clock alone, so a repeat is a cache hit.
    pub fn snapshotFor(self: *Plane, ctx: *command.Context) ?*const catalog_mod.Snapshot {
        self.syncEntryShape(ctx.buffers.active().textEditor() != null) catch {};
        if (ctx.semantic) |services| self.syncFocus(services, ctx.head, hereFor(ctx)) catch {};
        // The third built-in provider, synced HERE rather than on the dispatch
        // path, because "what would this key do" and "what does this key do"
        // must read the same table. Hung off `dispatchSpec` first, and the
        // difference was visible immediately: `s` staged the row while
        // which-key, one call earlier, said nothing was offered.
        self.syncDerived(ctx.gpa, factsFor(ctx)) catch {};
        return self.catalog.snapshot(catalogContext(ctx)) catch |err| {
            std.log.warn("intent: catalog snapshot failed: {t}", .{err});
            return null;
        };
    }

    /// THE EFFECT DOOR. A decision is good only while the table it was
    /// resolved against and the epoch it saw are still current (§9.1); the
    /// invoker then rechecks the endpoint's own generation.
    pub fn invoke(self: *const Plane, ctx: *command.Context, d: Decision) anyerror!void {
        if (d.epoch != self.catalog.epoch) return Error.StaleDecision;
        const table = self.catalog.published(d.provider) orelse return Error.StaleDecision;
        if (table.revision != d.revision) return Error.StaleDecision;
        return self.invokers.invoke(ctx, d.endpoint);
    }

    /// Resolve `name` against the CURRENT context and invoke what wins — the
    /// door a UI (the command palette) accepts an offer through. Resolution
    /// happens here, at accept time: nothing a list was built with is stored,
    /// so a snapshot that went stale between listing and accept resolves
    /// again rather than running yesterday's endpoint.
    ///
    /// A refusal is a `reason` to SHOW, never silence (§9.3) — formatted into
    /// the caller's `buf`, which the returned text borrows.
    pub fn invokeNamed(
        self: *Plane,
        ctx: *command.Context,
        name: []const u8,
        buf: []u8,
    ) Invocation {
        if (!catalog_mod.isIntentionName(name)) return .unknown;
        const id = self.catalog.findIntention(name) orelse return .unknown;
        const snap = self.snapshotFor(ctx) orelse return refused(buf, "{s}: no catalog here", .{name});
        return switch (snap.resolveOne(id)) {
            .decision => |d| if (self.invoke(ctx, d)) .invoked else |err| refused(
                buf,
                "{s}: refused at the door: {t}",
                .{ name, err },
            ),
            .unavailable => |u| switch (u) {
                .no_offer => refused(buf, "{s}: nothing offers this here", .{name}),
                .disabled => |d| refused(buf, "{s}: {s} — {s}", .{ name, d.reason.reason, d.reason.message }),
                .checking => |c| refused(buf, "{s}: {s} is still computing it", .{
                    name,
                    self.catalog.providerName(c.provider),
                }),
            },
            .ambiguous => |a| refused(buf, "{s}: ambiguous — {s} and {s} offer equally", .{ name, a.a.owner, a.b.owner }),
        };
    }
};

/// What `invokeNamed` did. `unknown` is not a refusal: the name is no
/// intention at all, so the caller's other vocabulary (commands) still owns it.
pub const Invocation = union(enum) {
    invoked,
    /// Relevant but impossible — text to show, borrowed from the caller's buf.
    refused: []const u8,
    unknown,
};

fn refused(buf: []u8, comptime fmt: []const u8, args: anytype) Invocation {
    return .{ .refused = std.fmt.bufPrint(buf, fmt, args) catch buf };
}

// ── The question dispatch asks ───────────────────────────────────────

/// This head's `catalog.Context` for right now. The clock's signature folds
/// every input the eligible offer set depends on (focused entry, entry shape,
/// mode, tool, semantic view and its revision); deriving it HERE, in ONE
/// place, is why no focus or scene chokepoint can be missed. A repeat in an
/// unchanged context leaves the revision alone, so `snapshot` is a cache hit.
///
/// Dispatch asks it on the keystroke path; `explain` and the palette ask the
/// SAME question through it — a second, drifting context builder is the bug
/// this prevents.
/// The FACTS this head presents right now — what any contextual resolution
/// (the offer catalog below, the Container's slot bindings, a guest-fired
/// `wl_slot_fire`) matches its predicates against.
///
/// Split out of `catalogContext` so there is ONE fact builder, not one per
/// consumer: a slot fired from a guest and an intention resolved from a
/// keystroke see the same world, and a fact added here reaches both without
/// anyone remembering to copy it. `catalogContext` adds only the clock
/// (a cache key), which a fire has no use for.
pub fn factsFor(ctx: *command.Context) catalog_mod.Facts {
    const entry = ctx.buffers.active();
    return .{
        .path = if (entry.textEditor()) |ed| ed.backingPath() else null,
        .name = entry.name,
        .mode = ctx.head.currentMode(),
        .lang = Actions.langOfName(entry.name),
        .tool = entry.tool,
        .role = entry.focusedRole(),
        .locality = localityOf(entry),
        .pane = ctx.head.focused_pane,
    };
}

/// WHERE this entry's bytes live (`facts.zig`'s `Locality`) — answerable
/// only now that an entry has a place. A tool entry is `.tool` first: its
/// content is a projection, so "are the files real here" is not a question
/// about it.
fn localityOf(entry: anytype) @import("weft_facts").Locality {
    return if (entry.tool.len > 0) .tool else if (entry.place.isHere()) .local else .remote;
}

pub fn catalogContext(ctx: *command.Context) catalog_mod.Context {
    const entry = ctx.buffers.active();
    const facts = factsFor(ctx);
    const locality = facts.locality;
    const path = facts.path;
    var h = std.hash.Wyhash.init(0);
    h.update(ctx.head.currentMode());
    h.update(entry.tool);
    // Fold the locality too. The `.facts` literal below and this signature
    // must always name the same fields: a fact the hash omits changes
    // resolution without bumping the revision, so `cached()` keeps handing
    // back a snapshot built for a different world. That is the one edit here
    // with neither a compiler nor a test to catch it -- hence this comment
    // sitting on the line it applies to.
    h.update(&[_]u8{@intFromEnum(locality)});
    h.update(&[_]u8{@intFromBool(path != null)});
    if (ctx.head.semantic_focus.view) |view| {
        h.update(std.mem.asBytes(&view.slot));
        h.update(std.mem.asBytes(&view.generation));
        const rev: u64 = if (ctx.semantic) |s|
            if (s.views.get(view)) |inst| inst.descriptor.revision else 0
        else
            0;
        h.update(std.mem.asBytes(&rev));
    }
    ctx.head.catalog_clock.observe(ctx.buffers.active_id, h.final());
    return .{
        .key = ctx.head.catalog_clock.key,
        .revision = ctx.head.catalog_clock.revision,
        .facts = facts,
    };
}

// ── Explanation (architecture §9.5) ──────────────────────────────────

/// What a binding's authored arms WOULD do here — the answer an explain UI
/// (which-key) renders. Names are catalog- or keymap-owned: borrowed, valid
/// until either mutates.
pub const Explanation = union(enum) {
    /// No arm is a resolvable intention here: nothing offers one, or a flat
    /// command arm claims the key first. The UI keeps showing the command.
    none,
    /// The arm that would win, and the provider that would run it.
    ready: struct { intention: []const u8, provider: []const u8 },
    /// The arm that would be reported, and the obstacle it hits (§10.2) —
    /// either a provider refusing it, or nobody offering it at all (then
    /// `provider` is empty and the arm named is the first authored one).
    blocked: struct { intention: []const u8, provider: []const u8, reason: []const u8 },
};

/// The whole list was applicable to nobody — every arm fell through (§10.2).
const unoffered = "not offered here";

/// Ask the catalog what `arms` would do, WITHOUT doing it. This walks the
/// same first-applicable order dispatch walks, over the same published
/// tables, so a hint cannot promise what the keypress would not deliver.
///
/// It resolves against the same freshly synced snapshot dispatch resolves
/// against, so an explanation cannot answer from a table the keystroke would
/// not have used.
///
/// Explanation conveys no authority by construction: it reads offers and
/// mints nothing. No endpoint is invoked and no decision leaves this call.
pub fn explain(ctx: *command.Context, arms: []const []const u8) Explanation {
    const plane = ctx.intent orelse return .none;
    const cat = &plane.catalog;
    const snap = plane.snapshotFor(ctx) orelse return .none;
    var first: ?[]const u8 = null;
    for (arms) |name| {
        if (!catalog_mod.isIntentionName(name)) {
            // A flat arm that resolves ends the walk exactly as it would for
            // dispatch — no later intention is ever reached.
            if (ctx.commands.resolve(name) != null or ctx.keymap.isMenuMode(name)) return .none;
            continue;
        }
        if (first == null) first = name;
        const id = cat.findIntention(name) orelse continue;
        switch (snap.resolveOne(id)) {
            .decision => |d| return .{ .ready = .{
                .intention = cat.intentionName(d.intention),
                .provider = d.owner,
            } },
            .unavailable => |u| switch (u) {
                .no_offer => {}, // nonapplicable — the next arm gets its turn
                .disabled => |d| return .{ .blocked = .{
                    .intention = cat.intentionName(d.intention),
                    .provider = d.owner,
                    .reason = d.reason.reason,
                } },
                .checking => |ch| return .{ .blocked = .{
                    .intention = cat.intentionName(ch.intention),
                    .provider = ch.owner,
                    .reason = "checking",
                } },
            },
            .ambiguous => |a| return .{ .blocked = .{
                .intention = cat.intentionName(a.intention),
                .provider = a.a.owner,
                .reason = "ambiguous",
            } },
        }
    }
    // Every intention arm fell through: name the one the binding leads with,
    // so the hint says "bound, but nothing here answers it".
    const led = first orelse return .none;
    return .{ .blocked = .{ .intention = led, .provider = "", .reason = unoffered } };
}

// ── Tests ───────────────────────────────────────────────────────────

const t = std.testing;

test "intent: an endpoint token refused once its invoker is retired" {
    const gpa = t.allocator;
    var inv: Invokers = .{};
    defer inv.deinit(gpa);

    const S = struct {
        var runs: u32 = 0;
        fn go(_: ?*anyopaque, _: *command.Context, _: u32) anyerror!void {
            runs += 1;
        }
    };
    S.runs = 0;
    const h = try inv.register(gpa, "fixture", S.go, null);
    try inv.invoke(undefined, h.endpoint(7)); // `go` never dereferences the ctx
    try t.expectEqual(@as(u32, 1), S.runs);

    inv.unregister(h);
    try t.expectError(Error.StaleEndpoint, inv.invoke(undefined, h.endpoint(7)));

    // The reused slot is a DIFFERENT generation, so the old token stays dead.
    const h2 = try inv.register(gpa, "fixture-2", S.go, null);
    try t.expectEqual(h.slot, h2.slot);
    try t.expectError(Error.StaleEndpoint, inv.invoke(undefined, h.endpoint(7)));
    try inv.invoke(undefined, h2.endpoint(7));
    try t.expectEqual(@as(u32, 2), S.runs);
}

test "intent: core offers go disabled for an editor-less entry, and say why" {
    const gpa = t.allocator;
    var plane: Plane = undefined;
    try plane.init(gpa);
    defer plane.deinit(gpa);

    var buf: [2]IntentionId = undefined;
    const arms = try plane.armIds(&.{ "std.target.activate", "std.editing.insert-line-break" }, &buf);

    const ctx: catalog_mod.Context = .{ .key = 1, .revision = 1 };
    {
        const snap = try plane.catalog.snapshot(ctx);
        const r = snap.resolve(arms);
        try t.expect(r == .decision);
        try t.expectEqual(@as(u32, 1), r.decision.arm); // the first arm has no offer
    }

    try plane.syncEntryShape(false);
    {
        const snap = try plane.catalog.snapshot(.{ .key = 1, .revision = 2 });
        const r = snap.resolve(arms);
        try t.expect(r == .unavailable);
        try t.expectEqualStrings("no-text", r.unavailable.disabled.reason.reason);
    }
}
