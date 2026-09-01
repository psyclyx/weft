//! A PLUGIN's pushed-offer table (architecture §9.2, §9.3) — the third
//! provider kind, beside core's editing table (`intent.zig`) and the view
//! adapter (`view_offers.zig`), and the first one a guest owns.
//!
//! The shape is deliberately the same as those two: a table of
//! `(intention, endpoint)` rows where the endpoint names a COMMAND the
//! plugin already registered. Authority therefore stays at the command
//! door — invoking an offer is exactly running that command by name, which
//! is what a key bound to it did before. The catalog only decides WHICH one
//! answers here, and the effect door rechecks epoch, table revision, and
//! endpoint generation on the way through (`intent.Plane.invoke`).
//!
//! Two properties the offer path buys over a bound command name:
//!
//!   · **Eligibility is pushed, not guessed.** A row publishes `disabled`
//!     with a reason code when the plugin knows it cannot run here, so a
//!     fallback list REPORTS the obstacle instead of quietly running its
//!     next arm, and which-key explains the key without invoking anything.
//!   · **A stale offer dies at the door.** `revision` is the plugin's own
//!     model ordinal: a table published against a model that has since been
//!     replaced cannot invoke, because the decision carries the ordinal it
//!     was resolved against.
//!
//! Scope: one optional `tool` fact, the identity of the plugin's own
//! projection buffer (`Buffers.Buffer.tool`). A git offer is eligible in the
//! git buffer and nowhere else — not because a mode was locked, but because
//! the offer says which entry it is about.

const std = @import("std");
const Allocator = std.mem.Allocator;
const catalog = @import("catalog.zig");
const command = @import("command.zig");
const facts = @import("weft_facts");
const intent = @import("intent.zig");

/// §9.3's sanitized human fallback: the reason CODE is the plugin's, the
/// prose is ours, so a guest cannot paint arbitrary text into a UI.
pub const disabled_message = "the plugin that owns this buffer refuses it right now";

/// One published row: the intention, the plugin command that answers it,
/// and the reason it cannot right now (empty = enabled). Both strings are
/// owned — a guest's memory is gone the moment its call returns.
const Row = struct {
    intention: catalog.IntentionId,
    command: []u8,
    reason: []u8,
};

/// One plugin's provider slot, the offer storage behind it, and the invoker
/// its endpoints are minted from.
///
/// PINNED once initialized: the published table borrows `offers`, and the
/// registered invoker borrows `self`. Hold it by pointer (a `WasmPlugin`
/// field, heap-allocated), exactly as `view_offers.Publisher` is held.
pub const Publisher = struct {
    plane: *intent.Plane,
    provider: catalog.ProviderId,
    handle: intent.Handle,
    /// The `tool` identity the offers are about; empty = unconstrained.
    scope: []u8 = &.{},
    /// The staging table the guest is filling right now.
    staged: std.ArrayList(Row) = .empty,
    pending_scope: []u8 = &.{},
    pending_revision: u64 = 0,
    open: bool = false,
    /// The published generation: rows own their strings, `offers` is the
    /// slice the catalog borrows.
    live: []Row = &.{},
    offers: []catalog.Offer = &.{},
    revision: u64 = 0,

    pub const Error = catalog.NameError || Allocator.Error || error{NotStaging};

    /// Initializes IN PLACE: the invoker it registers carries `self`, so the
    /// storage must already be where it will stay.
    pub fn init(self: *Publisher, gpa: Allocator, plane: *intent.Plane, name: []const u8) Error!void {
        self.* = .{
            .plane = plane,
            .provider = try plane.catalog.provider(name),
            .handle = undefined,
        };
        self.handle = try plane.invokers.register(gpa, name, invokeRow, self);
    }

    pub fn deinit(self: *Publisher, gpa: Allocator) void {
        _ = self.plane.catalog.retract(self.provider);
        self.plane.invokers.unregister(self.handle);
        freeRows(gpa, self.live);
        gpa.free(self.offers);
        freeRows(gpa, self.staged.items);
        self.staged.deinit(gpa);
        gpa.free(self.scope);
        gpa.free(self.pending_scope);
        self.* = undefined;
    }

    /// Start a new table for `revision` (the plugin's model ordinal),
    /// scoped to the `tool` identity of the entry it is about. Abandons any
    /// half-staged previous attempt — a table only ever reaches the catalog
    /// whole, through `commit`.
    pub fn begin(self: *Publisher, gpa: Allocator, scope: []const u8, revision: u64) Allocator.Error!void {
        freeRows(gpa, self.staged.items);
        self.staged.clearRetainingCapacity();
        gpa.free(self.pending_scope);
        self.pending_scope = try gpa.dupe(u8, scope);
        self.pending_revision = revision;
        self.open = true;
    }

    /// Stage one row. `reason` empty means enabled; otherwise it is the
    /// stable, machine-readable code §9.3 asks for.
    pub fn add(
        self: *Publisher,
        gpa: Allocator,
        intention: []const u8,
        cmd: []const u8,
        reason: []const u8,
    ) Error!void {
        if (!self.open) return error.NotStaging;
        const id = try self.plane.catalog.intention(intention);
        const owned_cmd = try gpa.dupe(u8, cmd);
        errdefer gpa.free(owned_cmd);
        const owned_reason = try gpa.dupe(u8, reason);
        errdefer gpa.free(owned_reason);
        try self.staged.append(gpa, .{ .intention = id, .command = owned_cmd, .reason = owned_reason });
    }

    /// Publish the staged table as this provider's whole set. The new
    /// generation is published BEFORE the old one is freed, so the catalog
    /// never holds a slice into released memory for an instant.
    pub fn commit(self: *Publisher, gpa: Allocator) Allocator.Error!void {
        if (!self.open) return;
        self.open = false;
        const rows = try self.staged.toOwnedSlice(gpa);
        errdefer freeRows(gpa, rows);
        const offers = try gpa.alloc(catalog.Offer, rows.len);
        errdefer gpa.free(offers);
        const scope = self.pending_scope;
        self.pending_scope = &.{};

        for (rows, offers, 0..) |row, *offer, index| offer.* = .{
            .intention = row.intention,
            .endpoint = self.handle.endpoint(@intCast(index)),
            .availability = if (row.reason.len == 0) .enabled else .{ .disabled = .{
                .reason = row.reason,
                .message = disabled_message,
            } },
            .predicate = if (scope.len == 0) .{ .all = &.{} } else .{ .tool = scope },
        };

        _ = try self.plane.catalog.publish(.{
            .provider = self.provider,
            .revision = self.pending_revision,
            .offers = offers,
        });

        freeRows(gpa, self.live);
        gpa.free(self.offers);
        gpa.free(self.scope);
        self.live = rows;
        self.offers = offers;
        self.scope = scope;
        self.revision = self.pending_revision;
    }

    /// Withdraw the whole table. An empty table would still be a claim; a
    /// plugin with nothing to offer here says nothing (§9.3).
    pub fn retract(self: *Publisher, gpa: Allocator) void {
        _ = self.plane.catalog.retract(self.provider);
        freeRows(gpa, self.live);
        gpa.free(self.offers);
        self.live = &.{};
        self.offers = &.{};
    }

    /// The command an endpoint payload names, or null when the table it was
    /// minted against is gone — read by the invoker, and by tests.
    pub fn commandAt(self: *const Publisher, payload: u32) ?[]const u8 {
        if (payload >= self.live.len) return null;
        return self.live[payload].command;
    }
};

fn freeRows(gpa: Allocator, rows: []Row) void {
    for (rows) |row| {
        gpa.free(row.command);
        gpa.free(row.reason);
    }
    gpa.free(rows);
}

/// Run the command the winning row names. Authority stays at the command
/// door, exactly as when that command is bound by name.
fn invokeRow(data: ?*anyopaque, ctx: *command.Context, payload: u32) anyerror!void {
    const self: *Publisher = @ptrCast(@alignCast(data orelse return intent.Error.StaleEndpoint));
    const name = self.commandAt(payload) orelse return intent.Error.StaleEndpoint;
    _ = try command.run(ctx.commands, ctx, name, &.{});
}

// ── Tests ───────────────────────────────────────────────────────────

const t = std.testing;

const Fixture = struct {
    plane: intent.Plane,
    publisher: Publisher,

    fn init(self: *Fixture) !void {
        try self.plane.init(t.allocator);
        try self.publisher.init(t.allocator, &self.plane, "plugin.git");
    }

    fn deinit(self: *Fixture) void {
        self.publisher.deinit(t.allocator);
        self.plane.deinit(t.allocator);
    }

    fn resolve(self: *Fixture, intention: []const u8, ctx: catalog.Context) !catalog.Resolution {
        const id = try self.plane.catalog.intention(intention);
        const snap = try self.plane.catalog.snapshot(ctx);
        return snap.resolveOne(id);
    }
};

test "plugin offers: a row resolves to its command, scoped to the plugin's own tool" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();

    try fixture.publisher.begin(t.allocator, "git", 7);
    try fixture.publisher.add(t.allocator, "plugin.git.stage", "git-stage", "");
    try fixture.publisher.add(t.allocator, "plugin.git.unstage", "git-unstage", "not-staged");
    try fixture.publisher.commit(t.allocator);

    const inside: catalog.Context = .{ .key = 1, .revision = 1, .facts = .{ .tool = "git" } };
    const staged = try fixture.resolve("plugin.git.stage", inside);
    try t.expectEqual(@as(u64, 7), staged.decision.revision);
    try t.expectEqualStrings(
        "git-stage",
        fixture.publisher.commandAt(intent.Endpoint.of(staged.decision.endpoint).payload).?,
    );

    // Relevant but impossible says which obstacle, in the plugin's own code.
    const unstage = try fixture.resolve("plugin.git.unstage", inside);
    try t.expectEqualStrings("not-staged", unstage.unavailable.disabled.reason.reason);
    try t.expectEqualStrings(disabled_message, unstage.unavailable.disabled.reason.message);

    // Another entry is not this plugin's buffer: nonapplicable, not refused.
    const elsewhere = try fixture.resolve("plugin.git.stage", .{ .key = 2, .revision = 2 });
    try t.expect(elsewhere.unavailable == .no_offer);
}

test "plugin offers: republishing replaces the table whole, and retracting says nothing" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();

    try fixture.publisher.begin(t.allocator, "git", 1);
    try fixture.publisher.add(t.allocator, "plugin.git.stage", "git-stage", "");
    try fixture.publisher.add(t.allocator, "plugin.git.refresh", "git-refresh", "");
    try fixture.publisher.commit(t.allocator);

    // The next model ordinal publishes a SMALLER table: the dropped row is
    // gone from the catalog, and the endpoint it minted no longer resolves.
    try fixture.publisher.begin(t.allocator, "git", 2);
    try fixture.publisher.add(t.allocator, "plugin.git.refresh", "git-refresh", "");
    try fixture.publisher.commit(t.allocator);

    const ctx: catalog.Context = .{ .key = 1, .revision = 1, .facts = .{ .tool = "git" } };
    try t.expect((try fixture.resolve("plugin.git.stage", ctx)).unavailable == .no_offer);
    const refresh = try fixture.resolve("plugin.git.refresh", ctx);
    try t.expectEqual(@as(u64, 2), refresh.decision.revision);

    // A decision from the FIRST table is refused at the door: it names a
    // revision the provider has replaced.
    var stale = refresh.decision;
    stale.revision = 1;
    try t.expectError(intent.Error.StaleDecision, fixture.plane.invoke(undefined, stale));

    fixture.publisher.retract(t.allocator);
    try t.expect(fixture.plane.catalog.published(fixture.publisher.provider) == null);
    try t.expect((try fixture.resolve("plugin.git.refresh", ctx)).unavailable == .no_offer);
}

test "plugin offers: an endpoint outliving its table is refused, never run" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();

    try fixture.publisher.begin(t.allocator, "git", 1);
    try fixture.publisher.add(t.allocator, "plugin.git.stage", "git-stage", "");
    try fixture.publisher.commit(t.allocator);
    const token = fixture.publisher.handle.endpoint(0);

    fixture.publisher.retract(t.allocator);
    try t.expectError(intent.Error.StaleEndpoint, fixture.plane.invokers.invoke(undefined, token));
}
