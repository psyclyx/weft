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
const Buffers = @import("Buffers.zig");
const context_mod = @import("context.zig");

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
    /// The one entry fact, beyond holding text, the row's availability reads.
    gate: Gate = .none,

    const Gate = enum {
        none,
        /// Disabled while the history holds no unit to reverse.
        undo,
        /// Disabled while the history holds no undone unit.
        redo,
        /// ABSENT unless the `save` action has an eligible provider here.
        /// Not disabled: a git listing has nothing durable, which is
        /// nonapplicable (§9.3), so a key's next arm must get its turn.
        persists,
    };
};

const core_offers = [_]CoreOffer{
    .{ .intention = "std.history.undo", .command = "undo", .gate = .undo },
    .{ .intention = "std.history.redo", .command = "redo", .gate = .redo },
    // Not a text verb: WHAT is durable is the `save` providers' call (a files
    // listing applies its draft), so the gate is theirs and holding text is
    // not a precondition.
    .{ .intention = "std.persistence.save", .command = "save", .needs_text = false, .gate = .persists },
    .{ .intention = "std.editing.insert-line-break", .command = "insert-newline" },
    .{ .intention = "std.input.break-out", .command = "posture-break-out", .needs_text = false },
};

/// The facts about the focused ENTRY core's table is computed from. A value,
/// so "did it change" is one comparison and an unchanged entry republishes
/// nothing.
pub const Shape = struct {
    has_text: bool = true,
    can_undo: bool = true,
    can_redo: bool = true,
    /// Some provider of the `save` action is eligible here. Decided by the
    /// providers' own predicates (core's `save-file` excludes tool
    /// projections by locality) — never by naming a tool.
    persists: bool = true,
};

/// A text-needing core offer on an editor-less entry gets `disabled` rather
/// than absence, so a fallback list REPORTS the obstacle instead of quietly
/// running its next arm (§9.3, §10.2).
const no_text: catalog_mod.Availability = .{ .disabled = .{
    .reason = "no-text",
    .message = "this entry holds no text",
} };
const nothing_to_undo: catalog_mod.Availability = .{ .disabled = .{
    .reason = "nothing-to-undo",
    .message = "there is no change to undo",
} };
const nothing_to_redo: catalog_mod.Availability = .{ .disabled = .{
    .reason = "nothing-to-redo",
    .message = "there is no undone change to redo",
} };

/// A core row's availability for `shape`, or null when the row is absent.
fn coreAvailability(offer: CoreOffer, shape: Shape) ?catalog_mod.Availability {
    if (offer.gate == .persists and !shape.persists) return null;
    if (offer.needs_text and !shape.has_text) return no_text;
    return switch (offer.gate) {
        .undo => if (shape.can_undo) .enabled else nothing_to_undo,
        .redo => if (shape.can_redo) .enabled else nothing_to_redo,
        .none, .persists => .enabled,
    };
}

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
    /// How many of `rows` the published table holds (an absent row is left
    /// out, not published disabled).
    row_count: usize = 0,
    revision: u64 = 0,
    /// The entry shape the published table was computed for.
    shape: Shape = .{},
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

    /// Republish the view adapter's table when the scope's focus or scene
    /// moved. A signature comparison when nothing moved; no probe either way.
    pub fn syncFocus(
        self: *Plane,
        services: *const semantic.Services,
        focus: *const Head.SemanticFocus,
        here: ?view_offers.Here,
    ) Allocator.Error!void {
        _ = try self.views.refresh(&self.catalog, services, focus, here);
    }

    /// What point is on, when the scope's entry is a text PROJECTION and its
    /// producer named the semantic view behind it. The view adapter derives
    /// what a listing affords from this, exactly as it derives a scene's from
    /// the focused node — one question, two planes.
    fn hereIn(ctx: *command.Context, scope: Scope) ?view_offers.Here {
        const view = scope.entry.tool_view orelse return null;
        if (action_here.subjectsIn(scope.entry).row) |node| return .{ .view = view, .node = node };
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
    pub fn syncShape(self: *Plane, shape: Shape) Allocator.Error!void {
        if (std.meta.eql(self.shape, shape) and self.revision != 0) return;
        self.shape = shape;
        try self.publishCore();
    }

    /// `syncShape` for a caller that knows only whether the entry holds text.
    pub fn syncEntryShape(self: *Plane, has_text: bool) Allocator.Error!void {
        return self.syncShape(.{ .has_text = has_text });
    }

    /// The shape of the scope's entry, read without touching it: the editor's
    /// history answers undo/redo, and the `save` action's providers answer
    /// whether anything here is durable.
    fn shapeOf(self: *Plane, scope: Scope) Shape {
        const persists = if (self.derived_attached)
            self.derived.actions.resolveFacts("save", factsIn(scope)) != null
        else
            true;
        const ed = scope.entry.textEditor() orelse
            return .{ .has_text = false, .can_undo = false, .can_redo = false, .persists = persists };
        return .{ .can_undo = ed.canUndo(), .can_redo = ed.canRedo(), .persists = persists };
    }

    fn publishCore(self: *Plane) Allocator.Error!void {
        var n: usize = 0;
        for (core_offers, 0..) |offer, i| {
            const availability = coreAvailability(offer, self.shape) orelse continue;
            self.rows[n] = .{
                // Interned at `init`, so a lookup: this path cannot fail on a name.
                .intention = self.catalog.findIntention(offer.intention).?,
                .endpoint = self.handle.endpoint(@intCast(i)),
                .availability = availability,
            };
            n += 1;
        }
        self.row_count = n;
        self.revision += 1;
        _ = try self.catalog.publish(.{
            .provider = self.provider,
            .revision = self.revision,
            .tier = .core,
            .offers = self.rows[0..n],
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
        return self.snapshotAt(ctx, .active);
    }

    /// The same snapshot for a CHOSEN context (`Where`): the active pane, or
    /// the head's primary focus while a companion holds the keyboard. One
    /// builder for both — the primary context is not a second resolver, it
    /// is the same syncs fed a different scope.
    ///
    /// Core's own tables describe ONE context at a time, so describing the
    /// primary from a sidebar republishes them for it; the next keypress in
    /// the sidebar republishes them back. Both are signature comparisons
    /// when nothing moved, and the two contexts keep separate cache keys.
    pub fn snapshotAt(self: *Plane, ctx: *command.Context, where: Where) ?*const catalog_mod.Snapshot {
        const scope = scopeOf(ctx, where);
        self.syncShape(self.shapeOf(scope)) catch {};
        if (ctx.semantic) |services| self.syncFocus(services, scope.focus, hereIn(ctx, scope)) catch {};
        // The third built-in provider, synced HERE rather than on the dispatch
        // path, because "what would this key do" and "what does this key do"
        // must read the same table. Hung off `dispatchSpec` first, and the
        // difference was visible immediately: `s` staged the row while
        // which-key, one call earlier, said nothing was offered.
        self.syncDerived(ctx.gpa, factsIn(scope)) catch {};
        return self.catalog.snapshot(contextIn(ctx, scope)) catch |err| {
            std.log.warn("intent: catalog snapshot failed: {t}", .{err});
            return null;
        };
    }

    /// A value that moves exactly when what `where` offers moves — the rows:
    /// intention, owner, availability, presentation. It is the primary
    /// context's `offers` key (`context.zig`), so it is CONTENT, not the
    /// catalog epoch: describing the primary from a sidebar flips core's
    /// tables back and forth without changing a single row, and that must not
    /// read as a change. The entry and mode the rows describe are keys of
    /// their own; folding them in here would report every focus move as an
    /// offers move too.
    pub fn offersFingerprint(self: *Plane, ctx: *command.Context, where: Where) u64 {
        const snap = self.snapshotAt(ctx, where) orelse return 0;
        var h = std.hash.Wyhash.init(0);
        for (snap.candidates, 0..) |c, i| {
            if (i != 0 and snap.candidates[i - 1].intention == c.intention) continue;
            h.update(self.catalog.intentionName(c.intention));
            h.update(c.owner);
            switch (c.availability) {
                .enabled => h.update("+"),
                .disabled => |d| {
                    h.update("-");
                    h.update(d.reason);
                },
                .checking => h.update("?"),
            }
            h.update(c.affordance.label);
            h.update(c.affordance.group);
            if (c.affordance.order) |o| h.update(std.mem.asBytes(&o));
        }
        return h.final();
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

    /// `invokeNamed` for a CHOSEN context: what a toolbar button does to the
    /// editor it describes while the toolbar holds focus.
    ///
    /// Every route an offer runs acts on the active entry (that is how the
    /// command door addresses a document), so an offer for the primary runs
    /// with the primary entry brought to the head for the call and the head
    /// put back after — the same round trip `presentIn` makes to open a
    /// subject in another viewport. Resolution still happens at accept time,
    /// in that entry, so a listing built one change ago cannot run a stale
    /// endpoint. If the invoked verb itself moved the head elsewhere (an
    /// open), that move stands.
    pub fn invokeNamedAt(
        self: *Plane,
        ctx: *command.Context,
        where: Where,
        name: []const u8,
        buf: []u8,
    ) Invocation {
        const scope = scopeOf(ctx, where);
        if (scope.live) return self.invokeNamed(ctx, name, buf);
        // A borrow, not navigation: the round trip records no jump.
        return ctx.buffers.withEntry(ctx.gpa, scope.entry_id, ctx.head, ctx.keymap, invokeNamed, .{ self, ctx, name, buf }) catch |err|
            refused(buf, "{s}: could not reach the primary entry: {t}", .{ name, err });
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
    return factsIn(scopeOf(ctx, .active));
}

/// The facts of a chosen scope — `factsFor` is this for the active one, so
/// the primary context is described by the same builder, never a copy.
pub fn factsIn(scope: Scope) catalog_mod.Facts {
    return entryFacts(scope.entry, scope.mode, scope.focus, scope.pane, scope.open);
}

/// The facts of `entry` in `mode`, as pane `pane` shows it — `factsIn` for
/// a scope, and what the frame asks a pane's chrome (status line, gutter)
/// with, so every pane is described by this one builder too. `open` is the
/// published context at the entry (`context.openAt`): the keys no typed
/// field names.
pub fn entryFacts(entry: *Buffers.Buffer, mode: []const u8, focus: *const Head.SemanticFocus, pane: u32, open: @import("weft_facts").context.Open) catalog_mod.Facts {
    return .{
        .path = if (entry.textEditor()) |ed| ed.backingPath() else null,
        .name = entry.name,
        .mode = mode,
        .lang = Actions.langOfName(entry.name),
        .tool = entry.tool,
        .role = entry.focusedRole(),
        .locality = localityOf(entry),
        .posture = @tagName(entry.posture(focus.field != null)),
        .pane = pane,
        .context = open,
    };
}

/// The mode an entry the head is NOT on is in: the one it saved when the
/// head left it, else where its posture rests (an entry never visited).
pub fn restingModeOf(buffers: *const Buffers, entry: *Buffers.Buffer) []const u8 {
    if (entry.mode.len > 0) return entry.mode;
    return buffers.restingModeFor(entry.posture(entry.semantic_focus.field != null));
}

// ── Chosen contexts ──────────────────────────────────────────────────

/// WHICH context an offer question is about (doc/configs.md §3.5.2). The
/// wire value is the enum's integer.
pub const Where = enum(u32) {
    /// The pane with the keyboard — what a keypress acts on.
    active = 0,
    /// The head's last PRIMARY focus (`Head.primary_focus`): the editor a
    /// toolbar or sidebar describes even while it holds focus itself.
    primary = 1,

    pub fn fromWire(raw: u32) ?Where {
        return std.enums.fromInt(Where, raw);
    }
};

/// One context, spelled out: the entry, how the head addresses it, and which
/// clock caches its snapshot. `live` is the entry the head is ON — its mode
/// and semantic focus are the head's own; any other entry's are the ones it
/// saved when the head left it (`Buffers.switchTo`).
pub const Scope = struct {
    entry: *Buffers.Buffer,
    entry_id: Buffers.Id,
    live: bool,
    mode: []const u8,
    pane: u32,
    focus: *const Head.SemanticFocus,
    clock: *Head.CatalogClock,
    /// The published context at this entry — its open keys.
    open: @import("weft_facts").context.Open,
};

pub fn scopeOf(ctx: *command.Context, where: Where) Scope {
    const head = ctx.head;
    const active: Scope = .{
        .entry = ctx.buffers.active(),
        .entry_id = ctx.buffers.active_id,
        .live = true,
        .mode = head.currentMode(),
        .pane = head.focused_pane,
        .focus = &head.semantic_focus,
        .clock = &head.catalog_clock,
        .open = context_mod.openAt(ctx.context, ctx.buffers.active()),
    };
    if (where == .active) return active;
    return primaryScopeOf(ctx) orelse active;
}

/// The head's PRIMARY context, or null when there is none: no focus-source
/// pane focused yet, or the entry it showed is gone. Offer readers fall back
/// to the active context (`scopeOf`); the primary context (`context.zig`)
/// does not, because the active pane may be a companion, and a companion that
/// could observe its own focus as "primary" could follow itself.
pub fn primaryScopeOf(ctx: *command.Context) ?Scope {
    const head = ctx.head;
    const primary = head.primary_focus orelse return null;
    // It IS where the head is: the live context, with the head's own mode.
    if (primary.entry == ctx.buffers.active_id) return scopeOf(ctx, .active);
    const entry = ctx.buffers.get(primary.entry) orelse return null;
    return .{
        .entry = entry,
        .entry_id = primary.entry,
        .live = false,
        .mode = entry.mode,
        .pane = primary.pane,
        .focus = &entry.semantic_focus,
        .clock = &head.primary_clock,
        .open = context_mod.openAt(ctx.context, entry),
    };
}

/// How to present `c`: what its provider declared, completed from the
/// intention table (a std intention's label, its package as the group, its
/// table position as the order) and, for anything else, from its name. A UI
/// therefore always has a label and a group, and "missing placement metadata
/// never hides an action" (§11.3) holds by construction.
pub fn presentation(cat: *const Catalog, c: catalog_mod.Candidate) catalog_mod.Affordance {
    const name = cat.intentionName(c.intention);
    const known = intentions.find(name);
    var out = c.affordance;
    if (out.label.len == 0) out.label = if (known) |k| k.intention.label else lastSegment(name);
    if (out.group.len == 0) out.group = packageOf(name);
    if (out.order == null) if (known) |k| {
        out.order = @intCast(k.index);
    };
    return out;
}

/// `std.history.undo` → `history`; `plugin.git.stage` → `git`.
fn packageOf(name: []const u8) []const u8 {
    var it = std.mem.splitScalar(u8, name, '.');
    _ = it.next();
    return it.next() orelse name;
}

fn lastSegment(name: []const u8) []const u8 {
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return name;
    return name[dot + 1 ..];
}

/// WHERE this entry's bytes live (`facts.zig`'s `Locality`) — answerable
/// only now that an entry has a place. A tool entry is `.tool` first: its
/// content is a projection, so "are the files real here" is not a question
/// about it.
fn localityOf(entry: anytype) @import("weft_facts").Locality {
    return if (entry.tool.len > 0) .tool else if (entry.place.isHere()) .local else .remote;
}

pub fn catalogContext(ctx: *command.Context) catalog_mod.Context {
    return contextIn(ctx, scopeOf(ctx, .active));
}

fn contextIn(ctx: *command.Context, scope: Scope) catalog_mod.Context {
    const entry = scope.entry;
    const facts = factsIn(scope);
    const locality = facts.locality;
    const path = facts.path;
    var h = std.hash.Wyhash.init(0);
    h.update(scope.mode);
    h.update(entry.tool);
    // Fold the locality too. The `.facts` literal below and this signature
    // must always name the same fields: a fact the hash omits changes
    // resolution without bumping the revision, so `cached()` keeps handing
    // back a snapshot built for a different world. That is the one edit here
    // with neither a compiler nor a test to catch it -- hence this comment
    // sitting on the line it applies to.
    h.update(&[_]u8{@intFromEnum(locality)});
    h.update(&[_]u8{@intFromBool(path != null)});
    // …and the open keys, through the store's revision and coordinates: a
    // plugin publishing `repl.session` changes which providers are eligible.
    const open = facts.context.digest();
    h.update(std.mem.asBytes(&open));
    if (scope.focus.view) |view| {
        h.update(std.mem.asBytes(&view.slot));
        h.update(std.mem.asBytes(&view.generation));
        const rev: u64 = if (ctx.semantic) |s|
            if (s.views.get(view)) |inst| inst.descriptor.revision else 0
        else
            0;
        h.update(std.mem.asBytes(&rev));
    }
    scope.clock.observe(scope.entry_id, h.final());
    return .{
        .key = scope.clock.key,
        .revision = scope.clock.revision,
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
            if (ctx.commands.resolve(name) != null or ctx.keymap.modeHasTag(name, "menu")) return .none;
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

test "intent: history offers report nothing to undo, and save is absent where nothing persists" {
    const gpa = t.allocator;
    var plane: Plane = undefined;
    try plane.init(gpa);
    defer plane.deinit(gpa);

    var buf: [2]IntentionId = undefined;
    const undo = (try plane.armIds(&.{"std.history.undo"}, buf[0..1]))[0];
    const save = (try plane.armIds(&.{"std.persistence.save"}, buf[1..2]))[0];

    // A fresh text entry: undo is RELEVANT but impossible — disabled, with
    // the reason a UI greys the button by — and a keypress refuses rather
    // than running a later arm.
    try plane.syncShape(.{ .can_undo = false, .can_redo = false });
    {
        const snap = try plane.catalog.snapshot(.{ .key = 1, .revision = 1 });
        try t.expectEqualStrings("nothing-to-undo", snap.resolveOne(undo).unavailable.disabled.reason.reason);
        try t.expect(snap.resolveOne(save) == .decision);
    }
    // An edit makes it ready.
    try plane.syncShape(.{ .can_redo = false });
    {
        const snap = try plane.catalog.snapshot(.{ .key = 1, .revision = 2 });
        try t.expect(snap.resolveOne(undo) == .decision);
    }
    // Where no `save` provider is eligible, the word is ABSENT — so a
    // fallback list moves on to its next arm instead of stopping on it.
    try plane.syncShape(.{ .persists = false });
    {
        const snap = try plane.catalog.snapshot(.{ .key = 1, .revision = 3 });
        try t.expect(snap.resolveOne(save).unavailable == .no_offer);
        try t.expectEqual(@as(usize, 0), snap.offersFor(save).len);
    }
    // An unchanged shape republishes nothing.
    const epoch = plane.catalog.epoch;
    try plane.syncShape(.{ .persists = false });
    try t.expectEqual(epoch, plane.catalog.epoch);
}

test "intent: presentation completes what a provider left unsaid from the intention table" {
    const gpa = t.allocator;
    var plane: Plane = undefined;
    try plane.init(gpa);
    defer plane.deinit(gpa);
    const snap = try plane.catalog.snapshot(.{ .key = 1, .revision = 1 });

    const undo = plane.catalog.findIntention("std.history.undo").?;
    const shown = presentation(&plane.catalog, snap.offersFor(undo)[0]);
    try t.expectEqualStrings("Undo", shown.label);
    try t.expectEqualStrings("history", shown.group);
    try t.expect(shown.order != null);

    // A provider's own words win; a plugin intention with none is labelled
    // from its name and grouped by its plugin.
    var c = snap.offersFor(undo)[0];
    c.affordance = .{ .label = "Take back", .order = 3 };
    const over = presentation(&plane.catalog, c);
    try t.expectEqualStrings("Take back", over.label);
    try t.expectEqualStrings("history", over.group);
    try t.expectEqual(@as(?i32, 3), over.order);

    c.intention = try plane.catalog.intention("plugin.git.stage");
    c.affordance = .{};
    const plugin_row = presentation(&plane.catalog, c);
    try t.expectEqualStrings("stage", plugin_row.label);
    try t.expectEqualStrings("git", plugin_row.group);
    try t.expectEqual(@as(?i32, null), plugin_row.order);
}
