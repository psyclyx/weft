//! Publish, as offers, every declared ACTION that has an eligible provider
//! here — the derived offer table.
//!
//! This is the third built-in provider, and a sibling of `view_offers.zig`:
//! that one derives what a SCENE affords from its shape, this one derives what
//! the focused CONTEXT affords from the providers bound against it. Neither
//! asks a plugin to enumerate anything.
//!
//! WHY IT HAD TO EXIST. A dotted key arm (`bindKeys("git", "s",
//! &.{"plugin.git.stage"})`) resolves through the CATALOG, not through
//! `Actions`. So before this, a plugin that wanted a key to reach a
//! context-dependent verb had exactly one route: publish an offer table by
//! hand, recomputing it on every model change and every cursor move, with a
//! sentence per verb explaining why it did or did not apply. git does that for
//! eight verbs across six call sites.
//!
//! The cost of that route is not the bookkeeping. It is that the table is a
//! CLOSED LIST: a producer can only offer verbs it thought of, so extending
//! another plugin's rows means forking it. `Actions` already had the open
//! shape — `provide(action, predicate, cmd)`, resolved by the same engine as
//! everything else — and it simply was not connected to the plane a keystroke
//! reads. This is that wire.
//!
//! ELIGIBILITY IS NOT AUTHORITY (architecture §9.1). The published table is
//! what the catalog may SHOW and rank; `invoke` re-resolves against the live
//! facts and runs whatever wins then. A row that became ineligible between
//! publication and the keypress runs nothing, rather than running the command
//! that was eligible when the table was built.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Actions = @import("action.zig");
const catalog = @import("catalog.zig");
const command = @import("command.zig");
const facts_mod = @import("weft_facts");
const intent = @import("intent.zig");

pub const provider_name = "core.action";

/// One published row: the action it stands for, kept so `invoke` can
/// re-resolve by name rather than trusting an index into a table that may have
/// been republished since.
const Row = struct {
    /// Borrowed from `Actions`' own key storage, which outlives any table we
    /// publish from it (an action name is never freed while declared).
    action: []const u8,
};

pub const Publisher = struct {
    provider: catalog.ProviderId,
    handle: intent.Handle = undefined,
    actions: *Actions,
    /// The rows of the LAST published table, in published order.
    rows: std.ArrayList(Row) = .empty,
    offers: std.ArrayList(catalog.Offer) = .empty,
    revision: u64 = 0,
    signature: ?Signature = null,

    /// What the table was computed for. The container's `epoch` covers "a
    /// provider was added or removed"; the facts cover "the context moved".
    /// Everything a resolution depends on is in one of the two, so an
    /// unchanged signature really does mean an unchanged table.
    const Signature = struct {
        epoch: u64,
        role: u64,
        tool: u64,
        mode: u64,
        lang: u64,
        locality: facts_mod.Locality,
    };

    fn hash(s: []const u8) u64 {
        return std.hash.Wyhash.hash(0, s);
    }

    fn signatureOf(self: *const Publisher, f: facts_mod.Facts) Signature {
        return .{
            .epoch = self.actions.container.epoch,
            .role = hash(f.role),
            .tool = hash(f.tool),
            .mode = hash(f.mode),
            .lang = hash(f.lang),
            .locality = f.locality,
        };
    }

    pub const InitError = catalog.NameError || Allocator.Error;

    pub fn init(gpa: Allocator, plane: *intent.Plane, actions: *Actions) InitError!Publisher {
        var self: Publisher = .{
            .provider = try plane.catalog.provider(provider_name),
            .actions = actions,
        };
        self.handle = try plane.invokers.register(gpa, provider_name, invokeRow, self.actions);
        return self;
    }

    pub fn deinit(self: *Publisher, gpa: Allocator) void {
        self.rows.deinit(gpa);
        self.offers.deinit(gpa);
    }

    /// Recompute and publish when the context or the provider set moved.
    ///
    /// The table is UNBOUNDED — one row per declared action that resolves —
    /// because a fixed cap here would silently hide verbs, which is the one
    /// failure this whole mechanism exists to prevent. It is bounded in
    /// practice by the number of declared actions, which is a handful.
    pub fn refresh(
        self: *Publisher,
        gpa: Allocator,
        cat: *catalog.Catalog,
        f: facts_mod.Facts,
    ) (catalog.NameError || Allocator.Error)!bool {
        const next = self.signatureOf(f);
        if (self.signature) |current| if (std.meta.eql(current, next)) return false;

        self.rows.clearRetainingCapacity();
        self.offers.clearRetainingCapacity();
        var it = self.actions.actions.iterator();
        while (it.next()) |entry| {
            const name = entry.key_ptr.*;
            // An offer is addressed BY INTENTION, so only an action whose name
            // IS one (`catalog.isIntentionName` — the same §5.1 grammar a key
            // arm is read with) can have a row here. A flat action name
            // (`save`, `format`) names a command; it is reachable by running
            // that command, and putting it in this table would be claiming a
            // cross-plugin vocabulary word that was never spelled as one.
            if (!catalog.isIntentionName(name)) continue;
            // A `race` action's providers are async capability providers
            // registered elsewhere; resolving one here would always miss.
            if (entry.value_ptr.policy == .race) continue;
            const winner = self.actions.container.resolveOne(name, f) orelse continue;
            const index = self.rows.items.len;
            try self.rows.append(gpa, .{ .action = name });
            try self.offers.append(gpa, .{
                .intention = try cat.intention(name),
                .endpoint = self.handle.endpoint(@intCast(index)),
                .availability = .enabled,
                // The row is FROM whoever bound it, not from this table. See
                // `catalog.Offer.attribution`: a stand-in publisher that kept
                // its own name would collapse every plugin's verbs onto one
                // owner and defeat the cross-owner ambiguity refusal. Borrowed
                // from the binding, which outlives this publication — the next
                // `refresh` rebuilds from the bindings anyway.
                .attribution = winner.owner,
            });
        }

        self.revision += 1;
        // The WEAKEST tier, exactly as `view_offers` publishes at: a provider
        // that means something more specific by an intention outranks a
        // derived row by simply saying so.
        _ = try cat.publish(.{
            .provider = self.provider,
            .revision = self.revision,
            .tier = .core,
            .offers = self.offers.items,
        });
        self.signature = next;
        return true;
    }

    /// Run the row's action by RE-RESOLVING it. The payload names a row in the
    /// published table, and the row names an action — never a command. A table
    /// says what was eligible when it was built; the door decides what runs.
    fn invokeRow(data: ?*anyopaque, ctx: *command.Context, payload: u32) anyerror!void {
        const actions: *Actions = @ptrCast(@alignCast(data.?));
        const plane = ctx.intent orelse return intent.Error.StaleEndpoint;
        const self = plane.derived;
        if (payload >= self.rows.items.len) return intent.Error.StaleEndpoint;
        const name = self.rows.items[payload].action;
        const cmd = actions.resolveFacts(name, ctx.capturedCtx().mergedFacts()) orelse
            return intent.Error.StaleEndpoint;
        _ = try command.run(ctx.commands, ctx, cmd, &.{});
    }
};

const t = std.testing;

test "action offers: a provider bound by role becomes an offer on that row" {
    // The wire this module is: `provide` puts a verb in `Actions`, and a key
    // arm reads the CATALOG. Without a derived table the two never meet.
    const gpa = t.allocator;
    var container = @import("container.zig").Container.init(gpa);
    defer container.deinit();
    var actions: Actions = .init(gpa, &container);
    defer actions.deinit();

    try actions.provide(.{
        .action = "row.verb",
        .predicate = .{ .role = "git.file.unstaged" },
        .command = "stage-it",
        .owner = "third-party",
    });

    // Eligible on the row it named…
    try t.expectEqualStrings("stage-it", actions.resolveFacts("row.verb", .{ .role = "git.file.unstaged" }).?);
    // …and nowhere else, which is what makes the derived table context-shaped
    // rather than a list of everything a plugin can do.
    try t.expectEqual(@as(?[]const u8, null), actions.resolveFacts("row.verb", .{ .role = "git.file.staged" }));
    try t.expectEqual(@as(?[]const u8, null), actions.resolveFacts("row.verb", .{}));
}
