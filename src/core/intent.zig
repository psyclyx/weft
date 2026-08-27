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
const catalog_mod = @import("catalog.zig");
const command = @import("command.zig");
const Actions = @import("action.zig");
const intentions = @import("intentions.zig");
const semantic = @import("semantic.zig");
const view_offers = @import("view_offers.zig");
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
const CoreOffer = struct { intention: []const u8, command: []const u8 };

const core_offers = [_]CoreOffer{
    .{ .intention = "std.history.undo", .command = "undo" },
    .{ .intention = "std.history.redo", .command = "redo" },
    .{ .intention = "std.persistence.save", .command = "save" },
    .{ .intention = "std.editing.insert-line-break", .command = "insert-newline" },
};

/// Every core offer needs an editable text endpoint. An editor-less entry
/// gets `disabled` rather than absence, so a fallback list REPORTS the
/// obstacle instead of quietly running its next arm (§9.3, §10.2).
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
    ) Allocator.Error!void {
        _ = try self.views.refresh(&self.catalog, services, head);
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
        for (&self.rows) |*row| row.availability = if (self.has_text) .enabled else no_text;
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

    /// THE EFFECT DOOR. A decision is good only while the table it was
    /// resolved against and the epoch it saw are still current (§9.1); the
    /// invoker then rechecks the endpoint's own generation.
    pub fn invoke(self: *const Plane, ctx: *command.Context, d: Decision) anyerror!void {
        if (d.epoch != self.catalog.epoch) return Error.StaleDecision;
        const table = self.catalog.published(d.provider) orelse return Error.StaleDecision;
        if (table.revision != d.revision) return Error.StaleDecision;
        return self.invokers.invoke(ctx, d.endpoint);
    }
};

// ── The question dispatch asks ───────────────────────────────────────

/// This head's `catalog.Context` for right now. The clock's signature folds
/// every input the eligible offer set depends on (focused entry, entry shape,
/// mode, tool, semantic view and its revision); deriving it HERE, in ONE
/// place, is why no focus or scene chokepoint can be missed. A repeat in an
/// unchanged context leaves the revision alone, so `snapshot` is a cache hit.
///
/// Dispatch calls it on the keystroke path; `explain` calls it to ask the
/// SAME question — a second, drifting context builder is the bug this
/// prevents.
pub fn catalogContext(ctx: *command.Context) catalog_mod.Context {
    const entry = ctx.buffers.active();
    const path = if (entry.textEditor()) |ed| ed.backingPath() else null;
    var h = std.hash.Wyhash.init(0);
    h.update(ctx.head.currentMode());
    h.update(entry.tool);
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
        .facts = .{
            .path = path,
            .name = entry.name,
            .mode = ctx.head.currentMode(),
            .lang = Actions.langOfName(entry.name),
            .tool = entry.tool,
            .pane = ctx.head.focused_pane,
        },
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
/// Explanation conveys no authority by construction: it reads published
/// offers and mints nothing. No endpoint is invoked, and no provider is asked
/// to republish — this is a describing read, not the pushed-offer sync the
/// keystroke path performs.
pub fn explain(ctx: *command.Context, arms: []const []const u8) Explanation {
    const plane = ctx.intent orelse return .none;
    const cat = &plane.catalog;
    const c = catalogContext(ctx);
    const snap = cat.snapshot(c) catch return .none;
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
                .provider = cat.providerName(d.provider),
            } },
            .unavailable => |u| switch (u) {
                .no_offer => {}, // nonapplicable — the next arm gets its turn
                .disabled => |d| return .{ .blocked = .{
                    .intention = cat.intentionName(d.intention),
                    .provider = cat.providerName(d.provider),
                    .reason = d.reason.reason,
                } },
                .checking => |ch| return .{ .blocked = .{
                    .intention = cat.intentionName(ch.intention),
                    .provider = cat.providerName(ch.provider),
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
