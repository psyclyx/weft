//! Open PLACEMENT — where a §9.4 "open a workspace entry" outcome lands
//! (doc/contextual-workspace-architecture.md §9.4, decided in
//! doc/cwa-config-decisions.md D3).
//!
//! Three parts, and no fourth:
//!
//! 1. An outcome carries an optional `Hint` — a coarse intent, not a pane.
//! 2. One FIRST-WINS policy maps `(hint, source viewport attributes, target
//!    kind)` to a `Decision`. `Policy` holds the chain; `defaultPolicy` is a
//!    deliberately small table.
//! 3. Exotic routing overrides the policy with a little code. There is no
//!    placement rule LANGUAGE — `display-buffer-alist` is the cautionary tale
//!    of a rule grammar accreting until nobody can predict placement.
//!
//! The status quo this replaces is openers picking panes imperatively, which
//! is where "the grep result opened inside my sidebar" comes from: with the
//! source viewport's attributes as a policy INPUT, a companion viewport can
//! never be the accidental answer, because the one table says so once.
//!
//! Note what is NOT here: this policy is a synchronous, pure function of
//! plain values, so it is a first-wins provider chain of native functions
//! rather than a `slot.zig` schema-marshalled slot. A placement decision is
//! taken inside the frame's layout phase; racing schema-encoded payloads
//! through `SlotHost` sessions to answer "which pane" would buy nothing and
//! cost the latency contract. Registration, ordering, and overridability —
//! everything that makes a slot a slot — are here.

const std = @import("std");
const semantic_model = @import("weft_semantic");
const viewport = @import("viewport.zig");

/// The coarse intent an outcome may carry. Optional by design: a provider
/// that has no opinion omits it and gets the policy's default for its
/// context, rather than being forced to guess a pane.
pub const Hint = enum {
    /// Replace what the acting viewport shows.
    self,
    /// The ordinary editing pane, whichever that is from here.
    primary,
    /// Beside the pane that would otherwise have been chosen.
    new_split,
    /// Open the entry without giving it a viewport.
    background,
};

/// The target kinds a placement decision distinguishes. Deliberately a plain
/// enum rather than `semantic_model.target.Kind` itself: that union's
/// `synthetic` arm carries a NAME borrowed from a provider's descriptor, and
/// a placement request outlives the call that recorded it (it is consumed by
/// the next layout phase). A policy that genuinely needs the synthetic name
/// is exotic routing — it reads the live descriptor itself.
pub const Kind = enum {
    unknown,
    file,
    directory,
    synthetic,

    pub fn of(k: semantic_model.target.Kind) Kind {
        return switch (k) {
            .unknown => .unknown,
            .file => .file,
            .directory => .directory,
            .synthetic => .synthetic,
        };
    }
};

/// What the policy is asked. `source` is the ACTING viewport's attributes —
/// the input that lets one table say "activating from a companion goes
/// elsewhere" once, instead of every opener remembering to.
pub const Request = struct {
    hint: Hint = .primary,
    source: viewport.Attrs = .tiled,
    kind: Kind = .unknown,
};

/// A pane-relative answer. Deliberately not a pane id: the policy runs above
/// the pane tree and must not learn its handles, and "the primary pane" is a
/// question only the layout can answer at apply time.
pub const Decision = enum {
    /// The acting viewport shows it.
    source,
    /// The nearest primary-eligible viewport shows it.
    primary,
    /// Split the primary-eligible viewport and show it in the new half.
    split_primary,
    /// No viewport changes; the entry stays open but unshown.
    none,
};

pub const Provider = *const fn (ctx: ?*anyopaque, req: Request) ?Decision;

/// The small default table (D3: "resist growing the default's table").
///
/// The only row that is not the hint read literally is `primary` from a
/// companion: from an ordinary pane "the primary pane" IS the acting one, so
/// activation stays in place and nothing jumps; from a docked companion the
/// acting pane is by definition not primary, so the entry goes to the
/// primary pane and the companion keeps its own subject. That single row is
/// the whole "Return in the sidebar opens in the editor" behavior.
pub fn defaultPolicy(_: ?*anyopaque, req: Request) ?Decision {
    return switch (req.hint) {
        .self => .source,
        .background => .none,
        .new_split => .split_primary,
        .primary => if (req.source.isPrimary()) .source else .primary,
    };
}

/// A first-wins provider chain. `resolve` walks registrations in order and
/// takes the first non-null answer, falling back to `defaultPolicy`; an
/// override therefore never has to reimplement the rows it does not care
/// about. Registration order is the caller's total order
/// (doc/configuration.md §7.2) — this structure records it, it does not
/// invent one.
pub const Policy = struct {
    entries: std.ArrayList(Entry) = .empty,

    pub const Entry = struct {
        owner: []u8,
        context: ?*anyopaque,
        provider: Provider,
    };

    pub const empty: Policy = .{};

    pub fn deinit(self: *Policy, gpa: std.mem.Allocator) void {
        for (self.entries.items) |e| gpa.free(e.owner);
        self.entries.deinit(gpa);
        self.* = undefined;
    }

    /// Register `provider` ahead of every previously registered one, so the
    /// later (higher-tier) declaration wins first — config overrides a
    /// plugin, which overrides core.
    pub fn register(self: *Policy, gpa: std.mem.Allocator, owner: []const u8, context: ?*anyopaque, provider: Provider) !void {
        const owned = try gpa.dupe(u8, owner);
        errdefer gpa.free(owned);
        try self.entries.insert(gpa, 0, .{ .owner = owned, .context = context, .provider = provider });
    }

    /// The winning decision, plus who decided it — the trace line
    /// (§9.5) a resolution explanation prints. `"core"` when no
    /// registration answered and the default table did.
    pub fn explain(self: *const Policy, req: Request) struct { decision: Decision, owner: []const u8 } {
        for (self.entries.items) |e| {
            if (e.provider(e.context, req)) |d| return .{ .decision = d, .owner = e.owner };
        }
        return .{ .decision = defaultPolicy(null, req).?, .owner = "core" };
    }

    pub fn resolve(self: *const Policy, req: Request) Decision {
        return self.explain(req).decision;
    }
};

const t = std.testing;

/// A docked companion's attributes, spelled out — core names no role.
const companion: viewport.Attrs = .{ .cycles = false, .persistent = true, .dock = .left, .focus_source = false };

test "placement: the default table routes a companion's open to the primary pane" {
    const bar = companion;
    // The one row that matters: same hint, different source, different answer.
    try t.expectEqual(Decision.primary, defaultPolicy(null, .{ .hint = .primary, .source = bar, .kind = .file }).?);
    try t.expectEqual(Decision.source, defaultPolicy(null, .{ .hint = .primary, .source = .tiled, .kind = .file }).?);
    // The other hints read literally.
    try t.expectEqual(Decision.source, defaultPolicy(null, .{ .hint = .self, .source = bar }).?);
    try t.expectEqual(Decision.none, defaultPolicy(null, .{ .hint = .background, .source = .tiled }).?);
    try t.expectEqual(Decision.split_primary, defaultPolicy(null, .{ .hint = .new_split, .source = .tiled }).?);
}

test "placement: an override wins first-wins and declining falls through" {
    const gpa = t.allocator;
    var policy: Policy = .empty;
    defer policy.deinit(gpa);

    // An empty chain is the default table, attributed to core.
    const bare = policy.explain(.{ .hint = .primary, .source = .tiled });
    try t.expectEqual(Decision.source, bare.decision);
    try t.expectEqualStrings("core", bare.owner);

    const Exotic = struct {
        // Opinionated about directories only; everything else falls through.
        fn provide(_: ?*anyopaque, req: Request) ?Decision {
            return if (req.kind == .directory) .split_primary else null;
        }
    };
    try policy.register(gpa, "config", null, Exotic.provide);
    const dir = policy.explain(.{ .hint = .self, .source = .tiled, .kind = .directory });
    try t.expectEqual(Decision.split_primary, dir.decision);
    try t.expectEqualStrings("config", dir.owner);
    // Declining leaves the default's answer intact, unchanged and attributed
    // honestly — an override never has to restate rows it does not want.
    const file = policy.explain(.{ .hint = .self, .source = .tiled, .kind = .file });
    try t.expectEqual(Decision.source, file.decision);
    try t.expectEqualStrings("core", file.owner);

    // A later registration outranks an earlier one.
    const Blunt = struct {
        fn provide(_: ?*anyopaque, _: Request) ?Decision {
            return .none;
        }
    };
    try policy.register(gpa, "project", null, Blunt.provide);
    try t.expectEqual(Decision.none, policy.resolve(.{ .hint = .self, .source = .tiled, .kind = .directory }));
}
