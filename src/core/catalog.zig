//! The pushed-offer catalog (architecture §9.2, §9.5) — the kernel half:
//! pure data in, pure decisions out, no UI and no dispatch wiring.
//!
//! "Catalog" here means the CATALOG OF OFFERS — what the focused context
//! affords right now — and nothing else. It is not a registry of plugins:
//! weft ships no plugin catalog in-process (that one was deleted in 8ac1676,
//! "wasm-only plugins from disk"), and the shipped `.wasm`/`.js` set under
//! `lib/weft/plugins/` is spelled "the bundled plugins" everywhere, never
//! "the catalog". One word, one meaning; keep it that way.
//!
//! Providers PUSH revision-stamped `Table`s of `Offer`s. Nothing here ever
//! calls provider code: enumerating, resolving, and explaining are functions
//! over published tables plus a `Context` snapshot, so `explain()` cannot
//! have effects BY CONSTRUCTION (there is no callback to call). Genuinely
//! dynamic eligibility is a provider-published fact — a re-`publish` on the
//! provider's own schedule — or an honest `checking` availability, never a
//! synchronous probe.
//!
//! The hot path is a contract: `snapshot()` builds the eligible, ranked
//! candidate table for one context once; every later keystroke is
//! `cached()` + `resolve()`, a binary search plus a short walk, with no
//! allocator in scope at all (see `cached`'s signature — it takes none, and
//! `Snapshot.resolve` takes none). A snapshot is keyed by
//! `(Context.key, Context.revision, epoch)`: a publish/retract bumps the
//! catalog `epoch`, a focus or fact change bumps the caller's
//! `Context.revision`, and either one is a rebuild.
//!
//! Ranking is doc/configuration.md §7.2's one order,
//! `(tier, priority, specificity, owner, declaration index)` — the same
//! order `container.zig` applies to slots, over a different subject
//! (intentions rather than slot names), which is why `Tier` is imported
//! from there rather than redeclared. Two differences from the Container are
//! deliberate:
//!
//!   - **Specificity is DERIVED, not pushed.** It is the offer's eligibility
//!     predicate's conjunct count (plus its endpoint-class constraint), so a
//!     provider cannot inflate its own rank with a number; the only way up
//!     is to actually constrain more.
//!   - **Equal strongest offers are a VALUE, not a load-time error.** Offer
//!     tables arrive and depart at runtime, so a cross-owner tie is reported
//!     as `Resolution.ambiguous` naming both sides. Resolution never depends
//!     on publish order — the owner term compares provider NAMES, never
//!     interned ids (ids are assigned in intern order, which IS load order).
//!
//! Decomplection: this module knows nothing of keymaps, buffers, wasm, or
//! UI. An endpoint is an opaque `u64` it never dereferences. Catalog
//! visibility is never authority — a `Decision` carries the `epoch` and the
//! provider table `revision` it was resolved against precisely so the effect
//! door can recheck them (§9.1).

const std = @import("std");
const Allocator = std.mem.Allocator;
const facts_mod = @import("facts.zig");
const container = @import("container.zig");

pub const Facts = facts_mod.Facts;
pub const Predicate = facts_mod.Predicate;
/// One tier ladder for the whole kernel (doc/configuration.md §7.2), not a
/// second copy free to drift from the Container's.
pub const Tier = container.Tier;

// ── Identity ────────────────────────────────────────────────────────

/// An interned `std.<package>.<operation>` / `plugin.<id>.<...>` intention
/// name. Comparing intentions on the keystroke path is an integer compare;
/// the string exists once, in the catalog's interner.
pub const IntentionId = enum(u32) { _ };

/// An interned provider name. The RANKING never uses this integer (that
/// would be publish order); it uses the name bytes behind it.
pub const ProviderId = enum(u32) { _ };

/// An interned endpoint-class name (`std.<package>` / `plugin.<id>`) — the
/// protocol class of the focused endpoint, the coarse eligibility axis
/// `Facts` has no field for.
pub const ClassId = enum(u32) { _ };

/// Opaque provider-side handle to the thing an offer would invoke. The
/// catalog stores it, ranks around it, and hands it back in a `Decision`;
/// it never interprets it.
pub const EndpointToken = u64;

pub const NameError = error{
    EmptySegment,
    InvalidCharacter,
    UnknownRoot,
    WrongSegmentCount,
};

/// doc/configuration.md §5.1: dotted lowercase-kebab segments. The `std.`
/// prefix may be elided in prose, never in a manifest value or on the wire,
/// so the elided spelling is not a name — it is a `UnknownRoot` error here,
/// which is the cheapest possible place to catch it.
pub fn validateIntentionName(name: []const u8) NameError!void {
    const n = try countSegments(name);
    const root = rootSegment(name);
    if (std.mem.eql(u8, root, "std")) {
        if (n != 3) return error.WrongSegmentCount;
    } else if (std.mem.eql(u8, root, "plugin")) {
        if (n < 3) return error.WrongSegmentCount;
    } else return error.UnknownRoot;
}

/// Protocol-package identity — an endpoint class, one segment shorter than
/// an intention (`std.hierarchy`, `plugin.git`). `ui.<slot>` is a capability
/// slot, not a protocol class, and belongs to `container.zig`.
pub fn validateClassName(name: []const u8) NameError!void {
    const n = try countSegments(name);
    const root = rootSegment(name);
    if (!std.mem.eql(u8, root, "std") and !std.mem.eql(u8, root, "plugin")) return error.UnknownRoot;
    if (n != 2) return error.WrongSegmentCount;
}

/// Does a bound name REFER to an intention rather than name a command?
/// One grammar (doc/configuration.md §5.1): the §5.1 spelling IS the
/// reference, so a flat name (`insert-newline`) and a dotted name under an
/// unknown root (`git.commit`) both stay commands, and there is no second
/// sigil to keep in sync with the validator above.
pub fn isIntentionName(name: []const u8) bool {
    validateIntentionName(name) catch return false;
    return true;
}

fn rootSegment(name: []const u8) []const u8 {
    const dot = std.mem.indexOfScalar(u8, name, '.') orelse return name;
    return name[0..dot];
}

fn countSegments(name: []const u8) NameError!u32 {
    var n: u32 = 0;
    var it = std.mem.splitScalar(u8, name, '.');
    while (it.next()) |seg| {
        if (seg.len == 0) return error.EmptySegment;
        for (seg) |c| switch (c) {
            'a'...'z', '0'...'9', '-' => {},
            else => return error.InvalidCharacter,
        };
        n += 1;
    }
    return n;
}

/// Name→id, id→name, keys owned. Index in insertion order IS the id.
const Interner = struct {
    names: std.StringArrayHashMapUnmanaged(void) = .empty,

    fn deinit(self: *Interner, gpa: Allocator) void {
        for (self.names.keys()) |k| gpa.free(k);
        self.names.deinit(gpa);
        self.* = undefined;
    }

    fn intern(self: *Interner, gpa: Allocator, name: []const u8) Allocator.Error!u32 {
        if (self.names.getIndex(name)) |i| return @intCast(i);
        const owned = try gpa.dupe(u8, name);
        errdefer gpa.free(owned);
        try self.names.put(gpa, owned, {});
        return @intCast(self.names.count() - 1);
    }

    fn find(self: *const Interner, name: []const u8) ?u32 {
        const i = self.names.getIndex(name) orelse return null;
        return @intCast(i);
    }

    fn get(self: *const Interner, id: u32) []const u8 {
        return self.names.keys()[id];
    }
};

// ── Offers ──────────────────────────────────────────────────────────

/// Architecture §9.3. Absence of an offer means NONAPPLICABLE; `disabled`
/// means relevant but currently impossible; `checking` means a provider is
/// recomputing its own eligibility. All three are richer than a boolean
/// precisely so no UI has to invent an explanation.
pub const Availability = union(enum) {
    enabled,
    disabled: Disabled,
    /// The provider is recomputing; `task` is its opaque handle (0 = none).
    /// A dynamic provider APPEARS as dynamic instead of being probed.
    checking: struct { task: u64 = 0 },
};

pub const Disabled = struct {
    /// Stable, machine-readable reason code (`"no-selection"`).
    reason: []const u8,
    /// Sanitized human fallback. Borrowed from the published table.
    message: []const u8 = "",
    /// An intention that would remove the obstacle, if one exists.
    remediation: ?IntentionId = null,
};

/// One row of a pushed table: "for this intention, in contexts matching this
/// predicate, I offer this endpoint." Pure data — no callback, no closure.
pub const Offer = struct {
    intention: IntentionId,
    endpoint: EndpointToken,
    availability: Availability = .enabled,
    /// Eligibility over the context facts. The empty conjunction is the
    /// unconstrained offer (and the least specific one).
    predicate: Predicate = .{ .all = &.{} },
    /// Restrict to a focused endpoint class; `null` applies to any.
    class: ?ClassId = null,
    priority: i32 = 0,

    /// DERIVED, never pushed: conjunct count of the eligibility predicate,
    /// plus one for an endpoint-class constraint. A provider raises its rank
    /// only by genuinely narrowing what it claims.
    pub fn specificity(self: Offer) u32 {
        return self.predicate.specificity() + @intFromBool(self.class != null);
    }
};

/// A provider's whole published set, as a value. Publishing replaces the
/// provider's previous table atomically — there is no incremental "add one
/// offer" mutation, so a half-updated table is not a state this kernel can
/// be in.
///
/// `offers` and every string inside it are BORROWED (the Container's
/// discipline): the publisher keeps them alive until it publishes a
/// replacement or retracts.
pub const Table = struct {
    provider: ProviderId,
    /// Provider-stamped; travels into every `Decision` so the effect door
    /// can refuse a decision made against a superseded table.
    revision: u64,
    tier: Tier = .plugin,
    /// Authored order: position IS the declaration index tie-break.
    offers: []const Offer = &.{},
};

// ── Context and candidates ──────────────────────────────────────────

/// The resolution input the caller owns. `key` identifies the context
/// (a viewport, a head) for caching; `revision` is the caller's own clock —
/// bump it whenever `class` or `facts` change and the cached snapshot is
/// rebuilt. The catalog never stores `facts`, so nothing here has to outlive
/// the call.
pub const Context = struct {
    key: u64 = 0,
    revision: u64 = 0,
    /// Protocol class of the focused endpoint.
    class: ?ClassId = null,
    facts: Facts = .{},
};

/// An eligible offer, ranked. Carries every sort key so a trace explains the
/// winner by DIFFING candidates rather than by re-running resolution.
pub const Candidate = struct {
    intention: IntentionId,
    provider: ProviderId,
    /// Provider name — the order's owner term. Compared by bytes so ranking
    /// can never depend on intern (publish) order. Interner-owned.
    owner: []const u8,
    endpoint: EndpointToken,
    availability: Availability,
    tier: Tier,
    priority: i32,
    specificity: u32,
    /// Position in the provider's authored table.
    decl_index: u32,
    revision: u64,
};

/// doc/configuration.md §7.2's total order, HIGHER wins:
/// `(tier, priority, specificity, owner, declaration index)`.
///
/// The owner term compares provider NAMES; using `ProviderId` would make the
/// order depend on who published first, which is the exact property §9.2
/// forbids. Within one owner, earlier declaration wins — a table is a list
/// and its order is authored data. Candidates from one snapshot can only tie
/// on the full key if two providers share a name, which the interner makes
/// impossible.
pub fn betterThan(a: Candidate, b: Candidate) bool {
    if (a.tier != b.tier) return @intFromEnum(a.tier) > @intFromEnum(b.tier);
    if (a.priority != b.priority) return a.priority > b.priority;
    if (a.specificity != b.specificity) return a.specificity > b.specificity;
    if (!std.mem.eql(u8, a.owner, b.owner)) return std.mem.lessThan(u8, a.owner, b.owner);
    return a.decl_index < b.decl_index;
}

/// Equal STRENGTH — the ambiguity test. Deliberately ignores the owner and
/// declaration-index tie-breaks: those give enumeration a deterministic
/// order, they do not make one offer stronger than the other.
pub fn sameStrength(a: Candidate, b: Candidate) bool {
    return a.tier == b.tier and a.priority == b.priority and a.specificity == b.specificity;
}

// ── Resolution ──────────────────────────────────────────────────────

pub const Decision = struct {
    intention: IntentionId,
    provider: ProviderId,
    endpoint: EndpointToken,
    /// Index of the winning arm in the authored fallback list.
    arm: u32,
    /// Rechecked at the effect door — visibility is never authority.
    revision: u64,
    epoch: u64,
};

pub const Unavailable = union(enum) {
    /// No arm had any offer: nonapplicable, not refused.
    no_offer,
    /// The strongest offer for an applicable arm cannot run right now.
    disabled: struct {
        intention: IntentionId,
        provider: ProviderId,
        reason: Disabled,
    },
    /// The strongest offer's provider is still recomputing eligibility.
    checking: struct {
        intention: IntentionId,
        provider: ProviderId,
        task: u64,
    },
};

/// Equal strongest offers from different owners. An explicit value the caller
/// must handle — never silently broken by publish order.
pub const Ambiguity = struct {
    intention: IntentionId,
    arm: u32,
    a: Candidate,
    b: Candidate,
};

pub const Resolution = union(enum) {
    decision: Decision,
    unavailable: Unavailable,
    ambiguous: Ambiguity,
};

/// Why one arm of a fallback list ended the walk (or did not).
pub const ArmStatus = enum {
    won,
    ambiguous,
    disabled,
    checking,
    /// No offer at all — the fallback list moves on (§10.2).
    nonapplicable,
    /// An earlier arm applied; this one was never consulted.
    not_reached,
};

/// Why one candidate is not the answer.
pub const Verdict = enum {
    /// The arm's strongest offer — what its `ArmStatus` then reports on.
    selected,
    outranked,
    /// Equal strongest to the selected candidate.
    tied,
    class_mismatch,
    predicate_mismatch,
    /// Eligible, but its arm was never reached.
    not_reached,
};

pub const CandidateTrace = struct {
    candidate: Candidate,
    verdict: Verdict,
};

pub const ArmTrace = struct {
    intention: IntentionId,
    status: ArmStatus,
    /// Eligible candidates best-first, then the ineligible offers with the
    /// axis that rejected them.
    candidates: []const CandidateTrace,
};

/// Architecture §9.5. Produced by the SAME walk `resolve` runs; `outcome` is
/// bit-for-bit what `resolve` returns for the same inputs. Rendering it
/// executes no provider code — there is none to execute.
pub const Trace = struct {
    gpa: Allocator,
    arms: []const ArmTrace,
    outcome: Resolution,

    pub fn deinit(self: *Trace) void {
        for (self.arms) |a| self.gpa.free(a.candidates);
        self.gpa.free(self.arms);
        self.* = undefined;
    }
};

// ── Snapshot ────────────────────────────────────────────────────────

/// Every eligible candidate for one context, grouped by intention and ranked
/// within each group. Built once per `(context, revision, epoch)`; read on
/// the keystroke path without an allocator.
pub const Snapshot = struct {
    key: u64,
    revision: u64,
    epoch: u64,
    /// Sorted by `(intention, betterThan)`.
    candidates: []Candidate = &.{},

    /// The ranked run for one intention. Binary search, no allocation.
    pub fn offersFor(self: *const Snapshot, intention: IntentionId) []const Candidate {
        const key = @intFromEnum(intention);
        var lo: usize = 0;
        var hi: usize = self.candidates.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (@intFromEnum(self.candidates[mid].intention) < key) lo = mid + 1 else hi = mid;
        }
        var end = lo;
        while (end < self.candidates.len and @intFromEnum(self.candidates[end].intention) == key) end += 1;
        return self.candidates[lo..end];
    }

    /// How many intentions have an offer at all here — the length of the
    /// enumeration a UI (the palette) lists. Absence is nonapplicable, so an
    /// intention nobody offers simply is not in this count (§9.3).
    pub fn intentionCount(self: *const Snapshot) usize {
        var n: usize = 0;
        for (self.candidates, 0..) |c, i| {
            if (i == 0 or self.candidates[i - 1].intention != c.intention) n += 1;
        }
        return n;
    }

    /// The strongest candidate for the `i`-th offered intention. Stable
    /// order (intention id), so a UI can address a row by index across the
    /// name/provider/availability reads that build it.
    pub fn leader(self: *const Snapshot, i: usize) ?Candidate {
        var n: usize = 0;
        for (self.candidates, 0..) |c, j| {
            if (j != 0 and self.candidates[j - 1].intention == c.intention) continue;
            if (n == i) return c;
            n += 1;
        }
        return null;
    }

    /// Resolve an authored fallback list first-applicable (§10.2), before
    /// anything is invoked. No allocator, no provider code, no allocation.
    ///
    /// "Applicable" means an offer EXISTS, not that it is enabled: absence
    /// falls through to the next arm, `disabled`/`checking` stops the walk
    /// and reports itself. Otherwise `Return -> [target.activate,
    /// editing.insert-line-break]` would quietly insert a line break the
    /// moment activation was temporarily impossible.
    pub fn resolve(self: *const Snapshot, arms: []const IntentionId) Resolution {
        return walk(self, arms, null);
    }

    pub fn resolveOne(self: *const Snapshot, intention: IntentionId) Resolution {
        return self.resolve(&.{intention});
    }
};

/// One arm's verdict, shared by `resolve` and `explain`.
const ArmOutcome = union(enum) {
    nonapplicable,
    resolved: Resolution,
};

/// THE selection step. Everything that decides anything lives here, so a
/// trace cannot describe a resolution the dispatcher would not make.
fn selectArm(run: []const Candidate, arm: u32, epoch: u64) ArmOutcome {
    if (run.len == 0) return .nonapplicable;
    const best = run[0];
    if (run.len > 1 and sameStrength(best, run[1])) return .{ .resolved = .{ .ambiguous = .{
        .intention = best.intention,
        .arm = arm,
        .a = best,
        .b = run[1],
    } } };
    return .{ .resolved = switch (best.availability) {
        .enabled => .{ .decision = .{
            .intention = best.intention,
            .provider = best.provider,
            .endpoint = best.endpoint,
            .arm = arm,
            .revision = best.revision,
            .epoch = epoch,
        } },
        .disabled => |d| .{ .unavailable = .{ .disabled = .{
            .intention = best.intention,
            .provider = best.provider,
            .reason = d,
        } } },
        .checking => |c| .{ .unavailable = .{ .checking = .{
            .intention = best.intention,
            .provider = best.provider,
            .task = c.task,
        } } },
    } };
}

fn armStatus(outcome: Resolution) ArmStatus {
    return switch (outcome) {
        .decision => .won,
        .ambiguous => .ambiguous,
        .unavailable => |u| switch (u) {
            .disabled => .disabled,
            .checking => .checking,
            .no_offer => .nonapplicable,
        },
    };
}

/// The one resolver. `rec == null` is the keystroke path: no allocator in
/// scope, so the no-allocation property is structural rather than tested for.
fn walk(snap: *const Snapshot, arms: []const IntentionId, rec: ?*Recorder) Resolution {
    var result: Resolution = .{ .unavailable = .no_offer };
    var decided = false;
    for (arms, 0..) |intention, i| {
        // Only a trace needs the arms past the decision; the keystroke path
        // stops walking the moment it has an answer.
        if (decided and rec == null) break;
        const run = snap.offersFor(intention);
        if (decided) {
            if (rec) |r| r.record(intention, run, .not_reached, null);
            continue;
        }
        switch (selectArm(run, @intCast(i), snap.epoch)) {
            .nonapplicable => if (rec) |r| r.record(intention, run, .nonapplicable, null),
            .resolved => |res| {
                result = res;
                decided = true;
                if (rec) |r| r.record(intention, run, armStatus(res), res);
            },
        }
    }
    return result;
}

/// Collects a `Trace` alongside the walk. Allocation failure is a field, not
/// an error return, so `walk` keeps ONE signature and the hot path keeps no
/// error union it can never take.
const Recorder = struct {
    gpa: Allocator,
    cat: *const Catalog,
    ctx: Context,
    arms: std.ArrayList(ArmTrace) = .empty,
    err: ?Allocator.Error = null,

    fn record(
        self: *Recorder,
        intention: IntentionId,
        run: []const Candidate,
        status: ArmStatus,
        outcome: ?Resolution,
    ) void {
        self.tryRecord(intention, run, status, outcome) catch |e| {
            self.err = e;
        };
    }

    fn tryRecord(
        self: *Recorder,
        intention: IntentionId,
        run: []const Candidate,
        status: ArmStatus,
        outcome: ?Resolution,
    ) Allocator.Error!void {
        var out: std.ArrayList(CandidateTrace) = .empty;
        errdefer out.deinit(self.gpa);
        for (run, 0..) |c, i| try out.append(self.gpa, .{
            .candidate = c,
            .verdict = if (status == .not_reached)
                .not_reached
            else if (i == 0)
                .selected
            else if (outcome != null and outcome.? == .ambiguous and i == 1)
                .tied
            else
                .outranked,
        });
        try self.cat.appendIneligible(self.gpa, &out, intention, self.ctx);
        try self.arms.append(self.gpa, .{
            .intention = intention,
            .status = status,
            .candidates = try out.toOwnedSlice(self.gpa),
        });
    }

    fn abort(self: *Recorder) void {
        for (self.arms.items) |a| self.gpa.free(a.candidates);
        self.arms.deinit(self.gpa);
    }
};

// ── Catalog ─────────────────────────────────────────────────────────

/// Why an offer was not a candidate for a context.
const Fit = enum { ok, class_mismatch, predicate_mismatch };

fn fit(offer: Offer, ctx: Context) Fit {
    if (offer.class) |want| {
        const have = ctx.class orelse return .class_mismatch;
        if (have != want) return .class_mismatch;
    }
    if (!offer.predicate.matches(ctx.facts)) return .predicate_mismatch;
    return .ok;
}

pub const Catalog = struct {
    gpa: Allocator,
    intentions: Interner = .{},
    providers: Interner = .{},
    classes: Interner = .{},
    tables: std.AutoArrayHashMapUnmanaged(ProviderId, Table) = .empty,
    /// Bumped by every publish and retract. Starts at 1 so 0 is available as
    /// "no snapshot yet".
    epoch: u64 = 1,
    /// Heap-allocated so a cached pointer survives later cache insertions. A
    /// rebuild for the SAME key reuses its `Snapshot` in place, so resolve
    /// against the pointer you just asked for rather than holding one.
    cache: std.AutoArrayHashMapUnmanaged(u64, *Snapshot) = .empty,

    pub fn init(gpa: Allocator) Catalog {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Catalog) void {
        for (self.cache.values()) |s| {
            self.gpa.free(s.candidates);
            self.gpa.destroy(s);
        }
        self.cache.deinit(self.gpa);
        self.tables.deinit(self.gpa);
        self.intentions.deinit(self.gpa);
        self.providers.deinit(self.gpa);
        self.classes.deinit(self.gpa);
        self.* = undefined;
    }

    // -- identity --

    pub fn intention(self: *Catalog, name: []const u8) (NameError || Allocator.Error)!IntentionId {
        try validateIntentionName(name);
        return @enumFromInt(try self.intentions.intern(self.gpa, name));
    }

    pub fn findIntention(self: *const Catalog, name: []const u8) ?IntentionId {
        return if (self.intentions.find(name)) |i| @enumFromInt(i) else null;
    }

    pub fn intentionName(self: *const Catalog, id: IntentionId) []const u8 {
        return self.intentions.get(@intFromEnum(id));
    }

    pub fn provider(self: *Catalog, name: []const u8) Allocator.Error!ProviderId {
        return @enumFromInt(try self.providers.intern(self.gpa, name));
    }

    pub fn providerName(self: *const Catalog, id: ProviderId) []const u8 {
        return self.providers.get(@intFromEnum(id));
    }

    pub fn class(self: *Catalog, name: []const u8) (NameError || Allocator.Error)!ClassId {
        try validateClassName(name);
        return @enumFromInt(try self.classes.intern(self.gpa, name));
    }

    pub fn className(self: *const Catalog, id: ClassId) []const u8 {
        return self.classes.get(@intFromEnum(id));
    }

    // -- publication --

    /// Replace a provider's whole table and bump the epoch. Atomic by
    /// construction: the table is one value.
    pub fn publish(self: *Catalog, table: Table) Allocator.Error!u64 {
        try self.tables.put(self.gpa, table.provider, table);
        self.epoch += 1;
        return self.epoch;
    }

    /// Withdraw a provider's offers entirely. Bumps the epoch only if the
    /// provider had a table (a no-op publication is not a change).
    pub fn retract(self: *Catalog, id: ProviderId) u64 {
        if (self.tables.orderedRemove(id)) self.epoch += 1;
        return self.epoch;
    }

    pub fn published(self: *const Catalog, id: ProviderId) ?Table {
        return self.tables.get(id);
    }

    // -- snapshots --

    /// The valid cached snapshot for a context, or null. Takes no allocator:
    /// the keystroke path cannot allocate even by accident.
    pub fn cached(self: *const Catalog, ctx: Context) ?*const Snapshot {
        const s = self.cache.get(ctx.key) orelse return null;
        if (s.epoch != self.epoch or s.revision != ctx.revision) return null;
        return s;
    }

    /// The snapshot for `ctx`, building it if the epoch or the caller's
    /// context revision moved. A hit allocates nothing.
    pub fn snapshot(self: *Catalog, ctx: Context) Allocator.Error!*const Snapshot {
        if (self.cached(ctx)) |s| return s;
        return self.build(ctx);
    }

    fn build(self: *Catalog, ctx: Context) Allocator.Error!*Snapshot {
        var list: std.ArrayList(Candidate) = .empty;
        errdefer list.deinit(self.gpa);
        for (self.tables.values()) |table| {
            const owner = self.providerName(table.provider);
            for (table.offers, 0..) |offer, i| {
                if (fit(offer, ctx) != .ok) continue;
                try list.append(self.gpa, .{
                    .intention = offer.intention,
                    .provider = table.provider,
                    .owner = owner,
                    .endpoint = offer.endpoint,
                    .availability = offer.availability,
                    .tier = table.tier,
                    .priority = offer.priority,
                    .specificity = offer.specificity(),
                    .decl_index = @intCast(i),
                    .revision = table.revision,
                });
            }
        }
        std.mem.sort(Candidate, list.items, {}, candidateLess);
        const candidates = try list.toOwnedSlice(self.gpa);
        errdefer self.gpa.free(candidates);

        const gop = try self.cache.getOrPut(self.gpa, ctx.key);
        if (gop.found_existing) {
            self.gpa.free(gop.value_ptr.*.candidates);
        } else {
            gop.value_ptr.* = self.gpa.create(Snapshot) catch |e| {
                _ = self.cache.orderedRemove(ctx.key);
                return e;
            };
        }
        gop.value_ptr.*.* = .{
            .key = ctx.key,
            .revision = ctx.revision,
            .epoch = self.epoch,
            .candidates = candidates,
        };
        return gop.value_ptr.*;
    }

    /// Drop one context's cached snapshot (its viewport closed).
    pub fn forget(self: *Catalog, key: u64) void {
        if (self.cache.fetchOrderedRemove(key)) |kv| {
            self.gpa.free(kv.value.candidates);
            self.gpa.destroy(kv.value);
        }
    }

    // -- explanation --

    /// The same walk `resolve` runs, with its reasoning recorded (§9.5).
    /// `ctx` must be the context the snapshot was built for — the ineligible
    /// alternatives are re-derived against it — and a stale pair is refused
    /// rather than described.
    pub fn explain(
        self: *const Catalog,
        gpa: Allocator,
        snap: *const Snapshot,
        ctx: Context,
        arms: []const IntentionId,
    ) (Allocator.Error || error{StaleSnapshot})!Trace {
        if (snap.key != ctx.key or snap.revision != ctx.revision or snap.epoch != self.epoch) {
            return error.StaleSnapshot;
        }
        var rec: Recorder = .{ .gpa = gpa, .cat = self, .ctx = ctx };
        const outcome = walk(snap, arms, &rec);
        if (rec.err) |e| {
            rec.abort();
            return e;
        }
        errdefer rec.abort();
        return .{ .gpa = gpa, .arms = try rec.arms.toOwnedSlice(gpa), .outcome = outcome };
    }

    /// The offers this context filtered out, with the axis that rejected
    /// them — "why my binding does nothing here" answered from data.
    fn appendIneligible(
        self: *const Catalog,
        gpa: Allocator,
        out: *std.ArrayList(CandidateTrace),
        want: IntentionId,
        ctx: Context,
    ) Allocator.Error!void {
        for (self.tables.values()) |table| {
            for (table.offers, 0..) |offer, i| {
                if (offer.intention != want) continue;
                const verdict: Verdict = switch (fit(offer, ctx)) {
                    .ok => continue,
                    .class_mismatch => .class_mismatch,
                    .predicate_mismatch => .predicate_mismatch,
                };
                try out.append(gpa, .{ .verdict = verdict, .candidate = .{
                    .intention = want,
                    .provider = table.provider,
                    .owner = self.providerName(table.provider),
                    .endpoint = offer.endpoint,
                    .availability = offer.availability,
                    .tier = table.tier,
                    .priority = offer.priority,
                    .specificity = offer.specificity(),
                    .decl_index = @intCast(i),
                    .revision = table.revision,
                } });
            }
        }
    }
};

fn candidateLess(_: void, a: Candidate, b: Candidate) bool {
    const ai = @intFromEnum(a.intention);
    const bi = @intFromEnum(b.intention);
    if (ai != bi) return ai < bi;
    return betterThan(a, b);
}

// ── Tests ───────────────────────────────────────────────────────────

const t = std.testing;

const Fixture = struct {
    cat: Catalog,
    activate: IntentionId,
    linebreak: IntentionId,
    toggle: IntentionId,

    fn init() !Fixture {
        var cat = Catalog.init(t.allocator);
        errdefer cat.deinit();
        const activate = try cat.intention("std.target.activate");
        const linebreak = try cat.intention("std.editing.insert-line-break");
        const toggle = try cat.intention("std.hierarchy.toggle-expanded");
        return .{ .cat = cat, .activate = activate, .linebreak = linebreak, .toggle = toggle };
    }

    fn deinit(self: *Fixture) void {
        self.cat.deinit();
    }
};

test "catalog: §5.1 names are dotted, qualified, and validated at the interner" {
    var cat = Catalog.init(t.allocator);
    defer cat.deinit();

    const a = try cat.intention("std.hierarchy.toggle-expanded");
    try t.expectEqualStrings("std.hierarchy.toggle-expanded", cat.intentionName(a));
    // Interning is idempotent: one string, one id.
    try t.expectEqual(a, try cat.intention("std.hierarchy.toggle-expanded"));
    try t.expectEqual(a, cat.findIntention("std.hierarchy.toggle-expanded").?);
    try t.expect(cat.findIntention("std.hierarchy.collapse") == null);
    _ = try cat.intention("plugin.git.stage-hunk");

    // The prose-only elided spelling is not a name.
    try t.expectError(error.UnknownRoot, cat.intention("hierarchy.toggle-expanded"));
    // A slot is not an intention.
    try t.expectError(error.UnknownRoot, cat.intention("ui.gutter-segment"));
    try t.expectError(error.WrongSegmentCount, cat.intention("std.hierarchy"));
    try t.expectError(error.EmptySegment, cat.intention("std..activate"));
    try t.expectError(error.InvalidCharacter, cat.intention("std.Target.activate"));

    const c = try cat.class("std.hierarchy");
    try t.expectEqualStrings("std.hierarchy", cat.className(c));
    try t.expectError(error.WrongSegmentCount, cat.class("std.hierarchy.toggle-expanded"));
}

test "catalog: publish replaces atomically, retract withdraws, both bump the epoch" {
    var f = try Fixture.init();
    defer f.deinit();
    const cat = &f.cat;
    const tree = try cat.provider("tree");

    const e0 = cat.epoch;
    const e1 = try cat.publish(.{ .provider = tree, .revision = 1, .offers = &.{
        .{ .intention = f.toggle, .endpoint = 10 },
        .{ .intention = f.activate, .endpoint = 11 },
    } });
    try t.expect(e1 > e0);
    try t.expectEqual(@as(usize, 2), cat.published(tree).?.offers.len);

    // A second publish REPLACES; the first table's offers are simply gone.
    const e2 = try cat.publish(.{ .provider = tree, .revision = 2, .offers = &.{
        .{ .intention = f.toggle, .endpoint = 20 },
    } });
    try t.expect(e2 > e1);
    try t.expectEqual(@as(usize, 1), cat.published(tree).?.offers.len);

    const snap = try cat.snapshot(.{});
    try t.expectEqual(@as(usize, 0), snap.offersFor(f.activate).len);
    try t.expectEqual(@as(u64, 20), snap.offersFor(f.toggle)[0].endpoint);

    const e3 = cat.retract(tree);
    try t.expect(e3 > e2);
    try t.expect(cat.published(tree) == null);
    // Retracting nothing is not a change.
    try t.expectEqual(e3, cat.retract(tree));
}

test "catalog: a fallback list resolves first-applicable, absence falls through" {
    var f = try Fixture.init();
    defer f.deinit();
    const cat = &f.cat;
    const text = try cat.provider("text");
    _ = try cat.publish(.{ .provider = text, .revision = 1, .offers = &.{
        .{ .intention = f.linebreak, .endpoint = 77 },
    } });

    // Nothing offers target.activate here, so Return falls through (§10.2).
    const snap = try cat.snapshot(.{});
    const res = snap.resolve(&.{ f.activate, f.linebreak });
    try t.expectEqual(@as(u64, 77), res.decision.endpoint);
    try t.expectEqual(@as(u32, 1), res.decision.arm);
    try t.expectEqual(cat.epoch, res.decision.epoch);
    try t.expectEqual(@as(u64, 1), res.decision.revision);

    // With an activate offer present, the first arm wins.
    const tree = try cat.provider("tree");
    _ = try cat.publish(.{ .provider = tree, .revision = 5, .offers = &.{
        .{ .intention = f.activate, .endpoint = 42 },
    } });
    const snap2 = try cat.snapshot(.{});
    const res2 = snap2.resolve(&.{ f.activate, f.linebreak });
    try t.expectEqual(@as(u64, 42), res2.decision.endpoint);
    try t.expectEqual(@as(u32, 0), res2.decision.arm);

    // An arm nobody offers at all is nonapplicable, not refused.
    try t.expect(snap2.resolveOne(f.toggle).unavailable == .no_offer);
}

test "catalog: a disabled strongest offer stops the walk and carries its reason" {
    var f = try Fixture.init();
    defer f.deinit();
    const cat = &f.cat;
    const tree = try cat.provider("tree");
    const text = try cat.provider("text");
    _ = try cat.publish(.{ .provider = tree, .revision = 1, .offers = &.{
        .{
            .intention = f.activate,
            .endpoint = 1,
            .availability = .{ .disabled = .{
                .reason = "no-selection",
                .message = "select a row first",
                .remediation = f.toggle,
            } },
        },
    } });
    _ = try cat.publish(.{ .provider = text, .revision = 1, .offers = &.{
        .{ .intention = f.linebreak, .endpoint = 2 },
    } });

    // Relevant-but-impossible is not absence: the list must NOT silently
    // insert a line break because activation is momentarily unavailable.
    const snap = try cat.snapshot(.{});
    const res = snap.resolve(&.{ f.activate, f.linebreak });
    try t.expectEqualStrings("no-selection", res.unavailable.disabled.reason.reason);
    try t.expectEqualStrings("select a row first", res.unavailable.disabled.reason.message);
    try t.expectEqual(f.toggle, res.unavailable.disabled.reason.remediation.?);
    try t.expectEqual(f.activate, res.unavailable.disabled.intention);

    // `checking` is honest, not a probe: same stop, different report.
    _ = try cat.publish(.{ .provider = tree, .revision = 2, .offers = &.{
        .{ .intention = f.activate, .endpoint = 1, .availability = .{ .checking = .{ .task = 9 } } },
    } });
    const snap2 = try cat.snapshot(.{});
    const res2 = snap2.resolve(&.{ f.activate, f.linebreak });
    try t.expectEqual(@as(u64, 9), res2.unavailable.checking.task);
}

test "catalog: equal strongest offers are an explicit ambiguity, never publish order" {
    var f = try Fixture.init();
    defer f.deinit();
    const cat = &f.cat;
    const zed = try cat.provider("zed");
    const ash = try cat.provider("ash");
    const offers: []const Offer = &.{.{ .intention = f.activate, .endpoint = 1 }};
    _ = try cat.publish(.{ .provider = zed, .revision = 1, .offers = offers });
    _ = try cat.publish(.{ .provider = ash, .revision = 1, .offers = offers });

    const snap = try cat.snapshot(.{});
    const res = snap.resolveOne(f.activate);
    try t.expectEqualStrings("ash", cat.providerName(res.ambiguous.a.provider));
    try t.expectEqualStrings("zed", cat.providerName(res.ambiguous.b.provider));

    // Reversing publish order changes nothing: the owner term is the NAME.
    var cat2 = Catalog.init(t.allocator);
    defer cat2.deinit();
    const activate2 = try cat2.intention("std.target.activate");
    const ash2 = try cat2.provider("ash");
    const zed2 = try cat2.provider("zed");
    const offers2: []const Offer = &.{.{ .intention = activate2, .endpoint = 1 }};
    _ = try cat2.publish(.{ .provider = zed2, .revision = 1, .offers = offers2 });
    _ = try cat2.publish(.{ .provider = ash2, .revision = 1, .offers = offers2 });
    const res2 = (try cat2.snapshot(.{})).resolveOne(activate2);
    try t.expectEqualStrings("ash", cat2.providerName(res2.ambiguous.a.provider));

    // One more conjunct on either side ends the ambiguity honestly.
    _ = try cat.publish(.{ .provider = zed, .revision = 2, .offers = &.{
        .{ .intention = f.activate, .endpoint = 1, .predicate = .{ .mode = "normal" } },
    } });
    const snap2 = try cat.snapshot(.{ .facts = .{ .mode = "normal" } });
    try t.expectEqualStrings("zed", cat.providerName(snap2.resolveOne(f.activate).decision.provider));
}

test "catalog: the comparator is tier, priority, specificity, owner, declaration index" {
    const base: Candidate = .{
        .intention = @enumFromInt(0),
        .provider = @enumFromInt(0),
        .owner = "m",
        .endpoint = 0,
        .availability = .enabled,
        .tier = .plugin,
        .priority = 0,
        .specificity = 0,
        .decl_index = 0,
        .revision = 0,
    };
    var hi = base;

    // Tier dominates priority, even a huge one.
    hi.tier = .config;
    var lo = base;
    lo.priority = 1000;
    try t.expect(betterThan(hi, lo));
    try t.expect(!betterThan(lo, hi));
    // core is the FLOOR: config, plugin, and imported all outrank it.
    lo = base;
    lo.tier = .core;
    try t.expect(betterThan(base, lo));
    // transient outranks everything.
    hi = base;
    hi.tier = .transient;
    try t.expect(betterThan(hi, base));

    // Priority beats specificity.
    hi = base;
    hi.priority = 1;
    lo = base;
    lo.specificity = 9;
    try t.expect(betterThan(hi, lo));

    // Specificity beats the owner tie-break.
    hi = base;
    hi.owner = "z";
    hi.specificity = 1;
    try t.expect(betterThan(hi, base));

    // Owners tie-break by NAME, deterministically, and only then — a
    // different owner alone is not a difference in STRENGTH.
    hi = base;
    hi.owner = "a";
    try t.expect(betterThan(hi, base));
    try t.expect(sameStrength(hi, base));
    lo = base;
    lo.tier = .core;
    try t.expect(!sameStrength(base, lo));

    // Within one owner, earlier declaration wins.
    lo = base;
    lo.decl_index = 3;
    try t.expect(betterThan(base, lo));
    try t.expect(sameStrength(base, lo));
}

test "catalog: specificity is derived from the predicate, not pushed" {
    const i: IntentionId = @enumFromInt(0);
    try t.expectEqual(@as(u32, 0), (Offer{ .intention = i, .endpoint = 0 }).specificity());
    try t.expectEqual(@as(u32, 1), (Offer{ .intention = i, .endpoint = 0, .predicate = .{ .mode = "normal" } }).specificity());
    try t.expectEqual(@as(u32, 2), (Offer{
        .intention = i,
        .endpoint = 0,
        .predicate = .{ .all = &.{ .{ .mode = "normal" }, .{ .ext = ".zig" } } },
    }).specificity());
    // A class constraint is one more conjunct.
    try t.expectEqual(@as(u32, 2), (Offer{
        .intention = i,
        .endpoint = 0,
        .class = @enumFromInt(0),
        .predicate = .{ .mode = "normal" },
    }).specificity());
}

test "catalog: explain traces the same resolution, with rejected alternatives" {
    var f = try Fixture.init();
    defer f.deinit();
    const cat = &f.cat;
    const tree = try cat.provider("tree");
    const text = try cat.provider("text");
    const hier = try cat.class("std.hierarchy");
    const doc = try cat.class("std.text");

    _ = try cat.publish(.{ .provider = tree, .revision = 3, .offers = &.{
        .{ .intention = f.activate, .endpoint = 1, .class = hier },
        .{ .intention = f.activate, .endpoint = 2, .class = doc },
    } });
    _ = try cat.publish(.{ .provider = text, .revision = 1, .tier = .config, .offers = &.{
        .{ .intention = f.activate, .endpoint = 3, .predicate = .{ .mode = "insert" } },
        .{ .intention = f.linebreak, .endpoint = 4 },
    } });

    const ctx: Context = .{ .key = 7, .class = hier, .facts = .{ .mode = "normal" } };
    const snap = try cat.snapshot(ctx);
    const arms: []const IntentionId = &.{ f.activate, f.linebreak };

    var trace = try cat.explain(t.allocator, snap, ctx, arms);
    defer trace.deinit();

    // Parity: one resolver, two outputs.
    const res = snap.resolve(arms);
    try t.expectEqual(res.decision.endpoint, trace.outcome.decision.endpoint);
    try t.expectEqual(res.decision.arm, trace.outcome.decision.arm);
    try t.expectEqual(@as(u64, 1), trace.outcome.decision.endpoint);

    try t.expectEqual(@as(usize, 2), trace.arms.len);
    try t.expectEqual(ArmStatus.won, trace.arms[0].status);
    try t.expectEqual(ArmStatus.not_reached, trace.arms[1].status);

    // The winner, plus both rejected alternatives with the axis that
    // rejected them — nothing was executed to learn any of it.
    const cands = trace.arms[0].candidates;
    try t.expectEqual(@as(usize, 3), cands.len);
    try t.expectEqual(Verdict.selected, cands[0].verdict);
    try t.expectEqual(@as(u64, 1), cands[0].candidate.endpoint);
    var saw_class = false;
    var saw_predicate = false;
    for (cands[1..]) |c| switch (c.verdict) {
        .class_mismatch => {
            saw_class = true;
            try t.expectEqual(@as(u64, 2), c.candidate.endpoint);
        },
        .predicate_mismatch => {
            saw_predicate = true;
            try t.expectEqual(@as(u64, 3), c.candidate.endpoint);
        },
        else => try t.expect(false),
    };
    try t.expect(saw_class and saw_predicate);

    // The unreached arm still shows what it would have offered.
    try t.expectEqual(@as(usize, 1), trace.arms[1].candidates.len);
    try t.expectEqual(Verdict.not_reached, trace.arms[1].candidates[0].verdict);

    // An ambiguity traces as an ambiguity, with the tied peer named.
    const other = try cat.provider("also-text");
    _ = try cat.publish(.{ .provider = other, .revision = 1, .tier = .config, .offers = &.{
        .{ .intention = f.linebreak, .endpoint = 5 },
    } });
    const ctx2: Context = .{ .key = 8, .class = hier, .facts = .{ .mode = "normal" } };
    const snap2 = try cat.snapshot(ctx2);
    var trace2 = try cat.explain(t.allocator, snap2, ctx2, &.{f.linebreak});
    defer trace2.deinit();
    try t.expectEqual(ArmStatus.ambiguous, trace2.arms[0].status);
    try t.expectEqual(Verdict.selected, trace2.arms[0].candidates[0].verdict);
    try t.expectEqual(Verdict.tied, trace2.arms[0].candidates[1].verdict);
    try t.expect(snap2.resolve(&.{f.linebreak}) == .ambiguous);

    // Explaining a snapshot the epoch left behind is refused, not described.
    try t.expectError(error.StaleSnapshot, cat.explain(t.allocator, snap, ctx, arms));
}

test "catalog: the cache is keyed by (context, revision, epoch)" {
    var f = try Fixture.init();
    defer f.deinit();
    const cat = &f.cat;
    const tree = try cat.provider("tree");
    _ = try cat.publish(.{ .provider = tree, .revision = 1, .offers = &.{
        .{ .intention = f.toggle, .endpoint = 1, .predicate = .{ .mode = "normal" } },
    } });

    const ctx: Context = .{ .key = 3, .facts = .{ .mode = "normal" } };
    const snap = try cat.snapshot(ctx);
    try t.expectEqual(snap, cat.cached(ctx).?);

    // A publish invalidates every snapshot.
    _ = try cat.publish(.{ .provider = tree, .revision = 2, .offers = &.{
        .{ .intention = f.toggle, .endpoint = 99, .predicate = .{ .mode = "normal" } },
    } });
    try t.expect(cat.cached(ctx) == null);
    try t.expectEqual(@as(u64, 99), (try cat.snapshot(ctx)).offersFor(f.toggle)[0].endpoint);

    // So does the caller's own clock moving — facts changed, so the
    // predicate must be re-evaluated rather than trusted.
    const ctx2: Context = .{ .key = 3, .revision = 1, .facts = .{ .mode = "insert" } };
    try t.expect(cat.cached(ctx2) == null);
    try t.expectEqual(@as(usize, 0), (try cat.snapshot(ctx2)).offersFor(f.toggle).len);

    // Different contexts cache independently, and a closed one is dropped.
    const other: Context = .{ .key = 4, .facts = .{ .mode = "normal" } };
    _ = try cat.snapshot(other);
    try t.expect(cat.cached(other) != null);
    cat.forget(4);
    try t.expect(cat.cached(other) == null);
    try t.expect(cat.cached(ctx2) != null);
}

test "catalog: resolving over a warm snapshot allocates nothing" {
    var f = try Fixture.init();
    defer f.deinit();
    const cat = &f.cat;
    const tree = try cat.provider("tree");
    _ = try cat.publish(.{ .provider = tree, .revision = 1, .offers = &.{
        .{ .intention = f.toggle, .endpoint = 8 },
        .{ .intention = f.activate, .endpoint = 9 },
    } });

    const ctx: Context = .{ .key = 1, .facts = .{ .mode = "normal" } };
    _ = try cat.snapshot(ctx); // warm-up

    // Every allocation from here on is a failure, including inside
    // `snapshot()` — a warm context must not touch the allocator at all.
    var failing = std.testing.FailingAllocator.init(t.allocator, .{ .fail_index = 0 });
    cat.gpa = failing.allocator();
    defer cat.gpa = t.allocator;

    const snap = try cat.snapshot(ctx);
    const res = snap.resolve(&.{ f.activate, f.toggle });
    try t.expectEqual(@as(u64, 9), res.decision.endpoint);
    try t.expectEqual(@as(u64, 8), snap.resolveOne(f.toggle).decision.endpoint);
    try t.expectEqual(@as(usize, 0), failing.allocations);
}

test {
    std.testing.refAllDecls(@This());
}
