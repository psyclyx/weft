//! The Container — ONE resolution engine (north-star-plan §2.2, W1). Named
//! `container.zig` because `registry.zig` is taken by the late-binding NAME
//! registry (command shadowing) — a different, smaller mechanism this module
//! does not replace in W1 (that's a later fold-in). This module subsumes the
//! crude, one-off resolvers §1 catalogued: `action.zig`'s When/Ctx matcher
//! and capability.zig's extension filter become Container CLIENTS (F5
//! adapters, `action.zig`/`capability.zig`), not reimplementations.
//!
//! A `Binding` offers a `provider` for a `SlotDecl`'s `slot` name, gated by a
//! `facts.Predicate`. Resolving a slot against a `Facts` value picks the
//! best ELIGIBLE (predicate-matching) binding by one STRICT WEAK ORDER:
//!
//!   (tier, priority, specificity, owner, declaration-index)
//!
//! "Strict weak order," not "total order," on purpose: two bindings that tie
//! on the full key (same owner AND same `decl_index`) form a genuine
//! equivalence class, not a resolvable ranking — see `betterThan`'s doc for
//! when that's actually reachable (an adapter's responsibility to avoid, not
//! something this module can force) and how the collision rule keeps a
//! CROSS-owner tie from ever being a live ambiguity.
//!
//! There is no scope term anywhere in this order — on purpose. Revision 1 of
//! the north-star plan made scope depth dominate resolution and it was
//! FATAL (review A1/A3, §9): mode scope (the most GENERAL interaction state)
//! outranked buffer scope's language identity, with no priority escape, and
//! cross-axis predicates had no home scope at all. That bug is what
//! `facts.zig` and this order exist to make permanently inexpressible. A
//! scope's only jobs, per §2.1, are supplying facts and bounding a binding's
//! lifetime — never ranking it. This module doesn't model scope at all yet
//! (that's Ctx/W2b); it only guarantees the order never grows a
//! scope-shaped back door.
//!
//! **Collision, the honest approximation** (§2.2, §9 A3): predicate overlap
//! is undecidable in general. Two bindings on the same slot, from DIFFERENT
//! owners, that tie on `(tier, priority, specificity)` are refused at
//! `bind()` time — UNLESS `facts.disjoint` can prove their predicates can
//! never both hold (same axis, different literal — `ext=".zig"` vs
//! `ext=".py"`). Within ONE owner, `decl_index` decides: a manifest is a
//! LIST, its authored order, never load order. This check applies only to
//! `first_wins`-composition slots: an `ordered_union`/`merge_ranked` slot
//! WANTS multiple equally-ranked eligible bindings (a completion popup
//! merging several plugins' suggestions is the point, not an ambiguity).
//!
//! Allocation discipline: `resolveOne` — the hot-path entry (action dispatch
//! rides it every keystroke, see action.zig) — never allocates. `eligible`/
//! `explain` allocate through a caller-supplied `Allocator` (off the hot
//! path: load-time binding, or an explicit `explain-binding` command).

const std = @import("std");
const Allocator = std.mem.Allocator;
const facts_mod = @import("facts.zig");

pub const Facts = facts_mod.Facts;
pub const Predicate = facts_mod.Predicate;

/// What kind of thing a slot vends. Descriptive metadata today (W1 adapters
/// don't branch on it); it becomes load-bearing once consumers other than
/// "one command name" / "one caps provider id" exist (D2's schema-directed
/// payloads).
pub const Shape = enum { query, feed, action, value };

/// How a slot's eligible bindings combine. Declared AT THE SLOT (data), not
/// hardcoded per name in core — the thing capability.zig's `Kind.composition`
/// switch is today, and what the F5 adapter maps onto this enum.
pub const Composition = enum { first_wins, ordered_union, merge_ranked };

/// Placeholder for D2's schema-directed marshalling (§4 C18, §5 F6/D2). A
/// slot's schema is a bare version number until the schema language
/// (scalars/strings/arrays/structs/anchor/range) is designed; 0 = "no schema
/// yet" for every W1 slot.
pub const SchemaRef = u32;

pub const SlotDecl = struct {
    name: []const u8,
    shape: Shape,
    composition: Composition,
    schema: SchemaRef = 0,
};

/// The dispatch.md ladder (§2.2), kept and extended. HIGHER wins: an
/// imported manifest's bindings sit one tier below the importer (so
/// `weft.use("defaults")` + your later binds override, deterministically);
/// `transient` (a paired, scope-bounded override) outranks everything.
pub const Tier = enum(i8) { core = -2, imported = -1, plugin = 0, config = 1, transient = 2 };

/// What a binding hands the caller when it wins. Grow-only: today's
/// adapters need exactly a command name (action.zig) or a caps provider
/// reference (capability.zig); `value` is a literal-payload placeholder for
/// config-value slots and this module's own end-to-end tests, standing in
/// for D2's typed schema-marshalled payload.
pub const ProviderRef = union(enum) {
    command: []const u8,
    /// `id` is the human-facing, prefix-matchable name (`Caps.Provider.id`
    /// — NOT guaranteed unique: `syntax.registerProviders` legitimately
    /// registers the same id once per buffer). `seq` is a per-registration
    /// monotonic counter the capability adapter assigns, guaranteed unique
    /// for the `Caps` instance's lifetime — the only safe way to map a
    /// winning binding back to the EXACT `Provider` it came from. Look up
    /// by `seq`, never by `id` alone.
    caps_provider: struct { id: []const u8, seq: u64 },
    value: []const u8,
    /// North-star-plan §6 W3 — a host-side native UI-mesh provider: an
    /// in-process function + opaque context. This is the in-process
    /// transport's PREVIEW of D2's future schema-directed guest payloads
    /// (F6, §4 C18): it exists so a host-side slot CLIENT (the UI mesh —
    /// `ui/statusline-seg`, `ui/gutter-segment`) can prove `Container`'s
    /// composition machinery on real UI before any guest can bind a slot
    /// (P2). Deliberately narrow — a real guest provider will marshal
    /// through a schema VALUE, never a raw Zig function pointer, so this
    /// variant does not try to anticipate that shape; it is deleted (or
    /// gains a schema-marshalled sibling) the day D2 ships, not extended.
    /// `call`/`ctx`/its `args` parameter are erased exactly like
    /// `caps_provider`'s `id`/`seq` are erased to an opaque handle:
    /// `Container` never dereferences any of them — only the ADAPTER that
    /// declared the slot (the UI mesh, `gfx/view/ui_mesh.zig`) knows the
    /// concrete `Args` type on both ends of a call for a given slot name.
    ui_provider: struct {
        call: *const fn (ctx: ?*anyopaque, gpa: Allocator, args: *anyopaque) anyerror!bool,
        /// Owned by the BINDER: the Container never dereferences or frees
        /// it; whoever binds must keep it alive until the matching
        /// `unbindOwnerExact`/`unbindOwnerPrefix` and free it after.
        ctx: ?*anyopaque = null,
    },
};

/// Which adapter a `Binding` came from — task #19's cross-domain unbind
/// hazard fix (review send-back). `owner` strings are free-form per domain
/// (a plugin name, a caps provider id, a manifest owner) and were NEVER
/// guaranteed distinct ACROSS domains — see `unbindOwnerPrefix`'s doc for
/// the reachable-today collision this closes. `Domain` is compared ONLY by
/// the two unbind functions below; `bind`'s collision check, `resolveOne`,
/// `eligible`, and `explain` never read it — resolution is already
/// domain-safe by construction (action names / `edit/*` capability names /
/// `ui/*` mesh names are disjoint SLOT namespaces), so adding a domain
/// filter there would be a no-op, not a fix. `other` covers this module's
/// own tests and any future ad hoc/`value`-shaped binding with no adapter
/// of its own.
pub const Domain = enum { action, caps, ui, other };

pub const Binding = struct {
    slot: []const u8,
    provider: ProviderRef,
    predicate: Predicate,
    priority: i32 = 0,
    tier: Tier = .plugin,
    /// Owner NAME — compared by byte equality, not identity — the collision
    /// rule's identity axis, and the within-owner decl_index tie-break's
    /// grouping key. (§2.2 speaks of an "owner fingerprint"; that's the W4
    /// end state once owners are cryptographic identities, not yet true
    /// here — a plain name is what both F5 adapters actually have.)
    /// Bindings are NOT removed by `Container` when their owner's underlying
    /// strings are freed — `unbindOwnerPrefix` must be called first (see the
    /// F5 adapters for the ordering this requires).
    owner: []const u8,
    /// Which adapter bound this — see `Domain`'s doc. Defaults to `.other`
    /// so a bare test/one-off `bind()` call doesn't need to name one.
    domain: Domain = .other,
    /// Position within ONE owner's authored list — data, never load order.
    /// See `betterThan`'s doc for the "earlier decl_index wins" convention
    /// and what an adapter whose legacy contract is "later wins" must do.
    decl_index: u32 = 0,
};

pub const Container = struct {
    gpa: Allocator,
    /// Slot names are OWNED (duped) here regardless of what the caller
    /// passes to `declareSlot` — a slot must outlive any single provider
    /// registration that happens to have been first to declare it (a second
    /// provider on the same slot must not leave the slot's identity pinned
    /// to the first provider's now-freed memory).
    slots: std.StringArrayHashMapUnmanaged(SlotDecl) = .empty,
    /// Bindings BORROW `slot`/`owner`/predicate string data from their
    /// caller (typically a Provider struct the adapter already owns) —
    /// Container allocates nothing per binding beyond this list's own
    /// backing storage. Callers must `unbindOwnerPrefix` before freeing the
    /// memory a binding borrows.
    bindings: std.ArrayList(Binding) = .empty,
    /// TRUE EPOCH (north-star-plan task #19 item 2 — CONTAINER-WIDE, not
    /// per-slot; see the body below): a monotonic counter bumped on every
    /// successful `declareSlot`/`bind`/
    /// `unbindOwnerPrefix`/`unbindOwnerExact` call — i.e. every mutation of
    /// this Container's resolvable state. `ctx.zig`'s `Ctx.epoch` reads this
    /// directly (`ctx.actions.container.epoch` — `Actions`/`Caps` now BOTH
    /// borrow the same instance, System/Session's shared fold-in, so either
    /// path reads the identical counter) as its cache key at capture time.
    /// Before the fold-in this was `System.generation` — a coarse "has
    /// ANYTHING in this system's bindings changed" flag that was never
    /// actually wired to `Ctx.epoch` in the first place (no `command.Context`
    /// held a `*System` to read it from). This field is the honest
    /// replacement: real, Container-wide (not yet per-SLOT — a resolveOne
    /// for slot A still sees its epoch bump when slot B's bindings change —
    /// but a true, live, always-correct-to-read counter, wired end to end).
    /// Wraps (`+%=`) rather than panicking on overflow — matching
    /// `System.generation`'s old convention — since a real process will
    /// never bind/unbind `2^64` times, this only guards against Zig's
    /// safety-checked `+=` panicking in the theoretical limit.
    epoch: u64 = 0,

    pub fn init(gpa: Allocator) Container {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Container) void {
        for (self.slots.keys()) |k| self.gpa.free(k);
        self.slots.deinit(self.gpa);
        self.bindings.deinit(self.gpa);
        self.* = undefined;
    }

    /// Declare (or idempotently re-declare) a slot. A manifest/plugin may
    /// only `bind` a slot that's been declared — the load-time cross-check
    /// the plan asks for (§2.2: "a blob may bind only slots its manifest
    /// declares"). Re-declaring with a different shape/composition keeps
    /// the FIRST declaration (matches `action.Actions.ensure`'s
    /// keep-the-first-declared-policy convention) and warns.
    pub fn declareSlot(self: *Container, decl: SlotDecl) Allocator.Error!void {
        const gop = try self.slots.getOrPut(self.gpa, decl.name);
        if (!gop.found_existing) {
            gop.key_ptr.* = try self.gpa.dupe(u8, decl.name);
            gop.value_ptr.* = decl;
            gop.value_ptr.name = gop.key_ptr.*;
        } else if (gop.value_ptr.shape != decl.shape or gop.value_ptr.composition != decl.composition) {
            std.log.warn("container: slot '{s}' redeclared with a different shape/composition; keeping the first", .{decl.name});
        }
        self.epoch +%= 1;
    }

    pub const BindError = error{ UnknownSlot, SlotCollision } || Allocator.Error;

    /// Register `binding` on its (already-declared) slot. On a
    /// `first_wins`-composition slot, refuses (as `error.SlotCollision`) a
    /// tie against a DIFFERENT owner at equal `(tier, priority,
    /// specificity)` unless `facts.disjoint` proves the two predicates can
    /// never both hold — see the module doc. `ordered_union`/`merge_ranked`
    /// slots skip this check entirely: ties there are the composition
    /// working as designed.
    pub fn bind(self: *Container, binding: Binding) BindError!void {
        const decl = self.slots.get(binding.slot) orelse return error.UnknownSlot;
        if (decl.composition == .first_wins) {
            for (self.bindings.items) |existing| {
                if (!std.mem.eql(u8, existing.slot, binding.slot)) continue;
                if (std.mem.eql(u8, existing.owner, binding.owner)) continue;
                if (existing.tier != binding.tier or existing.priority != binding.priority) continue;
                if (existing.predicate.specificity() != binding.predicate.specificity()) continue;
                if (facts_mod.disjoint(existing.predicate, binding.predicate)) continue;
                return error.SlotCollision;
            }
        }
        try self.bindings.append(self.gpa, binding);
        self.epoch +%= 1;
    }

    /// Remove every binding in `domain` whose owner starts with `prefix`
    /// (plugin teardown) — across every SLOT (still cross-slot: a plugin's
    /// action providers live on many different action-name slots), but
    /// scoped to ONE domain. Callers MUST call this before freeing the
    /// memory those bindings' `owner`/`slot`/predicate fields borrow —
    /// `Container` does not own that memory and does not dereference it
    /// here, but a binding left dangling past this call is a use-after-free
    /// waiting for the next `resolveOne`/`eligible`/`bind`.
    ///
    /// **Cross-domain hazard, FIXED (task #19's shared-Container fold-in;
    /// review send-back).** Before `domain` existed, this was
    /// container-WIDE: `owner` strings from DIFFERENT domains (a plugin
    /// name, a caps provider id, a manifest owner) sat in the SAME bindings
    /// list, and `action.zig`'s `unregisterByOwnerPrefix` /
    /// `capability.zig`'s `unregisterByIdPrefix` each called this with no
    /// way to say "only MY domain." Reachable TODAY, not merely
    /// theoretical: `wasm_abi/WasmPlugin.zig`'s completion-provider caps id
    /// is `"plugin.<name>/edit/completion"` — a plugin literally named
    /// `"plugin"` calling `unregisterByOwnerPrefix("plugin")` (its own
    /// action-provider teardown) would `startsWith`-match and silently
    /// delete every OTHER plugin's `"plugin.<name>/..."` caps binding too,
    /// while `Caps.providers` (untouched) still believed them registered —
    /// a desync, not a crash. `Domain` closes this structurally: each
    /// adapter's unbind call now names its own domain, so a same-prefix
    /// collision across domains can no longer remove the wrong bindings —
    /// see the regression test below ("cross-domain prefix collision").
    pub fn unbindOwnerPrefix(self: *Container, domain: Domain, prefix: []const u8) void {
        var i: usize = 0;
        while (i < self.bindings.items.len) {
            if (self.bindings.items[i].domain == domain and std.mem.startsWith(u8, self.bindings.items[i].owner, prefix)) {
                _ = self.bindings.swapRemove(i);
            } else i += 1;
        }
        self.epoch +%= 1;
    }

    /// Remove every binding in `domain` whose owner EQUALS `owner` exactly
    /// — the collision-free sibling of `unbindOwnerPrefix`: a caller whose
    /// owner identities are dynamically named (e.g. `manifest.zig`'s
    /// `"import: <name>"`, where one imported name can be a literal
    /// string-prefix of another — `"def"` of `"defaults"`) must use this,
    /// not the prefix form, or tearing down one owner can silently take an
    /// unrelated one with it. `domain` closes the SAME-owner, cross-domain
    /// collision the prefix form's doc names (e.g. a config manifest's
    /// owner `"config"` names an `action` provide AND a `ui` status
    /// segment at once — see `manifest.zig`'s `teardownOwned`, which now
    /// issues two scoped calls, one per domain, instead of one that would
    /// have removed both regardless of which was meant).
    pub fn unbindOwnerExact(self: *Container, domain: Domain, owner: []const u8) void {
        var i: usize = 0;
        while (i < self.bindings.items.len) {
            if (self.bindings.items[i].domain == domain and std.mem.eql(u8, self.bindings.items[i].owner, owner)) {
                _ = self.bindings.swapRemove(i);
            } else i += 1;
        }
        self.epoch +%= 1;
    }

    /// The single winner for `slot` against `f` — `first_wins` resolution,
    /// the action-dispatch hot path (`action.Actions.resolve`). Never
    /// allocates: a plain scan, matching `action.zig`'s pre-Container
    /// algorithm's allocation profile exactly.
    pub fn resolveOne(self: *const Container, slot: []const u8, f: Facts) ?*const Binding {
        var best: ?*const Binding = null;
        for (self.bindings.items) |*b| {
            if (!std.mem.eql(u8, b.slot, slot)) continue;
            if (!b.predicate.matches(f)) continue;
            if (best == null or betterThan(b, best.?)) best = b;
        }
        return best;
    }

    /// Every eligible binding for `slot` against `f`, best-first by the
    /// strict weak order — the `ordered_union`/`merge_ranked` shape (capability
    /// fan-out) and `explain`'s raw material. Allocates through `gpa`
    /// (caller-supplied — pass an arena/scratch on a path that cares).
    pub fn eligible(self: *const Container, gpa: Allocator, slot: []const u8, f: Facts) Allocator.Error![]const *const Binding {
        var out: std.ArrayList(*const Binding) = .empty;
        errdefer out.deinit(gpa);
        for (self.bindings.items) |*b| {
            if (!std.mem.eql(u8, b.slot, slot)) continue;
            if (!b.predicate.matches(f)) continue;
            try out.append(gpa, b);
        }
        std.mem.sort(*const Binding, out.items, {}, cmpBetter);
        return out.toOwnedSlice(gpa);
    }

    pub const ExplainEntry = struct {
        provider: ProviderRef,
        owner: []const u8,
        tier: Tier,
        priority: i32,
        specificity: u32,
        decl_index: u32,
    };

    /// `explain(slot, facts)` — a first-class kernel query, not a debug
    /// printf (§2.2): which bindings were eligible, their full sort keys
    /// (so "why the winner won" is reconstructable by DIFFING `eligible[0]`
    /// against `eligible[1]`, not by re-running resolution), and whether the
    /// top two are a live collision (should be structurally impossible given
    /// `bind`'s check — this recomputes it independently rather than
    /// trusting that invariant blindly).
    pub const ExplainResult = struct {
        gpa: Allocator,
        slot: []const u8,
        /// Best-first.
        eligible: []ExplainEntry,
        winner: ?usize,
        collision: bool,

        pub fn deinit(self: *ExplainResult) void {
            self.gpa.free(self.eligible);
            self.* = undefined;
        }
    };

    pub fn explain(self: *const Container, gpa: Allocator, slot: []const u8, f: Facts) Allocator.Error!ExplainResult {
        const list = try self.eligible(gpa, slot, f);
        defer gpa.free(list);
        const entries = try gpa.alloc(ExplainEntry, list.len);
        errdefer gpa.free(entries);
        for (list, 0..) |b, i| entries[i] = .{
            .provider = b.provider,
            .owner = b.owner,
            .tier = b.tier,
            .priority = b.priority,
            .specificity = b.predicate.specificity(),
            .decl_index = b.decl_index,
        };
        var collision = false;
        if (entries.len >= 2) {
            const a = entries[0];
            const b = entries[1];
            if (a.tier == b.tier and a.priority == b.priority and a.specificity == b.specificity and
                !std.mem.eql(u8, a.owner, b.owner)) collision = true;
        }
        return .{
            .gpa = gpa,
            .slot = slot,
            .eligible = entries,
            .winner = if (entries.len > 0) 0 else null,
            .collision = collision,
        };
    }
};

fn cmpBetter(_: void, a: *const Binding, b: *const Binding) bool {
    return betterThan(a, b);
}

/// The strict weak order (§2.2, [FIX 9]): `(tier, priority, specificity,
/// owner, declaration-index)`. No scope term — see the module doc for why
/// that is the entire point. "Strict weak order" rather than "total order"
/// because `decl_index` is data an ADAPTER assigns, not something this
/// module can force to be unique — two bindings tied on the full key really
/// are an unresolvable equivalence class (whichever the scan meets first
/// stays "best" in `resolveOne`/sorts stably in `eligible`), not a silent
/// bug. In practice: `action.zig` assigns `decl_index` from a monotonic,
/// never-reused sequence, so a same-owner tie there is now unreachable
/// (fixed after a review found the pre-fix version reusing indices post-
/// teardown); `capability.zig` leaves `decl_index` at its default (0) for
/// every binding — harmless there because nothing calls `resolveOne` on a
/// capability slot (composition picks among the FULL eligible set, never a
/// single `decl_index`-broken winner), so a same-owner tie is an accepted,
/// inert residual rather than an eliminated one.
///
/// Within one owner, EARLIER `decl_index` wins (the Container's canonical
/// convention: a manifest/provider list's first entry is its "primary"
/// declaration). An adapter whose LEGACY contract is "later registration
/// wins" (action.zig's pre-Container `Actions.resolve`) must assign
/// `decl_index` in DESCENDING registration order — first-registered gets the
/// LARGEST index, each later one smaller — to reproduce that contract
/// exactly through this convention. Get the direction wrong and a
/// previously-passing tie-break test silently flips; action.zig documents
/// and tests this at its call site.
///
/// Across DIFFERENT owners, `bind()` has already refused a same-`(tier,
/// priority, specificity)` tie on a `first_wins` slot unless the predicates
/// are provably disjoint (facts.disjoint) — meaning at most one of them is
/// EVER eligible for the same `Facts`. The owner-name comparison below never
/// resolves a live ambiguity; it only gives `eligible`/`explain` a
/// deterministic full ordering to enumerate (and, on non-`first_wins` slots,
/// a stable order among bindings that are all legitimately eligible at once
/// — which is the composition working, not a collision).
fn betterThan(a: *const Binding, b: *const Binding) bool {
    if (a.tier != b.tier) return @intFromEnum(a.tier) > @intFromEnum(b.tier);
    if (a.priority != b.priority) return a.priority > b.priority;
    const asp = a.predicate.specificity();
    const bsp = b.predicate.specificity();
    if (asp != bsp) return asp > bsp;
    if (std.mem.eql(u8, a.owner, b.owner)) return a.decl_index < b.decl_index;
    return std.mem.lessThan(u8, a.owner, b.owner);
}

// ── Tests ───────────────────────────────────────────────────────────

const t = std.testing;

fn declared(c: *Container, name: []const u8, comp: Composition) !void {
    try c.declareSlot(.{ .name = name, .shape = .action, .composition = comp });
}

test "container: strict weak order — tier beats priority beats specificity beats decl_index" {
    const gpa = t.allocator;
    var c = Container.init(gpa);
    defer c.deinit();
    try declared(&c, "s", .first_wins);

    try c.bind(.{ .slot = "s", .provider = .{ .value = "core" }, .predicate = .{ .all = &.{} }, .tier = .core, .priority = 1000, .owner = "a" });
    try c.bind(.{ .slot = "s", .provider = .{ .value = "config" }, .predicate = .{ .all = &.{} }, .tier = .config, .priority = -1000, .owner = "b" });
    // Lower priority, higher tier still wins: tier dominates.
    const w1 = c.resolveOne("s", .{}).?;
    try t.expectEqualStrings("config", w1.provider.value);

    var c2 = Container.init(gpa);
    defer c2.deinit();
    try declared(&c2, "s", .first_wins);
    try c2.bind(.{ .slot = "s", .provider = .{ .value = "lowprio" }, .predicate = .{ .mode = "normal" }, .tier = .plugin, .priority = 1, .owner = "a" });
    try c2.bind(.{ .slot = "s", .provider = .{ .value = "hiprio" }, .predicate = .{ .all = &.{} }, .tier = .plugin, .priority = 5, .owner = "b" });
    const w2 = c2.resolveOne("s", .{ .mode = "normal" }).?;
    try t.expectEqualStrings("hiprio", w2.provider.value);

    var c3 = Container.init(gpa);
    defer c3.deinit();
    try declared(&c3, "s", .first_wins);
    try c3.bind(.{ .slot = "s", .provider = .{ .value = "generic" }, .predicate = .{ .all = &.{} }, .tier = .plugin, .priority = 0, .owner = "a" });
    try c3.bind(.{ .slot = "s", .provider = .{ .value = "specific" }, .predicate = .{ .all = &.{.{ .mode = "normal" }} }, .tier = .plugin, .priority = 0, .owner = "b" });
    const w3 = c3.resolveOne("s", .{ .mode = "normal" }).?;
    try t.expectEqualStrings("specific", w3.provider.value);
}

test "container: [FIX 5] scenario — an ext binding at higher priority beats a mode binding, no scope ranking" {
    // The exact bug class revision 1 resurrected (review A1, §9): mode scope
    // (general interaction state) must NEVER structurally outrank a more
    // specific-feeling axis like buffer language merely because it's
    // "closer" — precedence is priority, declared as data, full stop.
    const gpa = t.allocator;
    var c = Container.init(gpa);
    defer c.deinit();
    try declared(&c, "reindent", .first_wins);
    try c.bind(.{ .slot = "reindent", .provider = .{ .command = "mode-reindent" }, .predicate = .{ .mode = "normal" }, .tier = .plugin, .priority = 10, .owner = "vim" });
    try c.bind(.{ .slot = "reindent", .provider = .{ .command = "nix-eq-reindent" }, .predicate = .{ .ext = ".nix" }, .tier = .plugin, .priority = 20, .owner = "nix-mode" });

    const f: Facts = .{ .path = "flake.nix", .mode = "normal" };
    const w = c.resolveOne("reindent", f).?;
    try t.expectEqualStrings("nix-eq-reindent", w.provider.command);
}

test "container: within-owner decl_index — earlier index wins by convention" {
    const gpa = t.allocator;
    var c = Container.init(gpa);
    defer c.deinit();
    try declared(&c, "s", .first_wins);
    try c.bind(.{ .slot = "s", .provider = .{ .value = "first" }, .predicate = .{ .all = &.{} }, .owner = "a", .decl_index = 0 });
    try c.bind(.{ .slot = "s", .provider = .{ .value = "second" }, .predicate = .{ .all = &.{} }, .owner = "a", .decl_index = 1 });
    try t.expectEqualStrings("first", c.resolveOne("s", .{}).?.provider.value);
}

test "container: same-owner rebind never collides; cross-owner tie collides unless disjoint" {
    const gpa = t.allocator;
    var c = Container.init(gpa);
    defer c.deinit();
    try declared(&c, "s", .first_wins);
    try c.bind(.{ .slot = "s", .provider = .{ .value = "a1" }, .predicate = .{ .all = &.{} }, .owner = "same", .decl_index = 0 });
    try c.bind(.{ .slot = "s", .provider = .{ .value = "a2" }, .predicate = .{ .all = &.{} }, .owner = "same", .decl_index = 1 });

    // Different owner, equal (tier,priority,specificity), overlapping (both
    // match-all) predicates: a real, undecidable ambiguity — refused.
    try t.expectError(error.SlotCollision, c.bind(.{ .slot = "s", .provider = .{ .value = "b" }, .predicate = .{ .all = &.{} }, .owner = "other" }));

    // Different owner, same tuple, but PROVABLY disjoint predicates (never
    // both eligible for the same Facts) — permitted.
    try c.bind(.{ .slot = "s", .provider = .{ .value = "zig-only" }, .predicate = .{ .ext = ".zig" }, .owner = "zig-plugin" });
    try c.bind(.{ .slot = "s", .provider = .{ .value = "py-only" }, .predicate = .{ .ext = ".py" }, .owner = "py-plugin" });
    try t.expectEqualStrings("zig-only", c.resolveOne("s", .{ .path = "x.zig" }).?.provider.value);
    try t.expectEqualStrings("py-only", c.resolveOne("s", .{ .path = "x.py" }).?.provider.value);
}

test "container: ordered_union/merge_ranked slots never collision-check" {
    const gpa = t.allocator;
    var c = Container.init(gpa);
    defer c.deinit();
    try declared(&c, "completion", .merge_ranked);
    // Two different owners, identical (tier,priority,specificity), fully
    // overlapping predicates — legitimate for a race/fan-out slot.
    try c.bind(.{ .slot = "completion", .provider = .{ .caps_provider = .{ .id = "lsp", .seq = 0 } }, .predicate = .{ .all = &.{} }, .owner = "lsp" });
    try c.bind(.{ .slot = "completion", .provider = .{ .caps_provider = .{ .id = "dabbrev", .seq = 1 } }, .predicate = .{ .all = &.{} }, .owner = "dabbrev" });

    const list = try c.eligible(gpa, "completion", .{});
    defer gpa.free(list);
    try t.expectEqual(@as(usize, 2), list.len);
}

test "container: bind against an undeclared slot fails" {
    const gpa = t.allocator;
    var c = Container.init(gpa);
    defer c.deinit();
    try t.expectError(error.UnknownSlot, c.bind(.{ .slot = "nope", .provider = .{ .value = "x" }, .predicate = .{ .all = &.{} }, .owner = "a" }));
}

test "container: unbindOwnerPrefix drops every binding from matching owners" {
    const gpa = t.allocator;
    var c = Container.init(gpa);
    defer c.deinit();
    try declared(&c, "s", .merge_ranked);
    try c.bind(.{ .slot = "s", .provider = .{ .value = "1" }, .predicate = .{ .all = &.{} }, .owner = "plugin#1" });
    try c.bind(.{ .slot = "s", .provider = .{ .value = "2" }, .predicate = .{ .all = &.{} }, .owner = "plugin#2" });
    try c.bind(.{ .slot = "s", .provider = .{ .value = "3" }, .predicate = .{ .all = &.{} }, .owner = "other" });
    c.unbindOwnerPrefix(.other, "plugin#");
    const list = try c.eligible(gpa, "s", .{});
    defer gpa.free(list);
    try t.expectEqual(@as(usize, 1), list.len);
    try t.expectEqualStrings("other", list[0].owner);
}

test "container: DOMAIN closes the cross-domain prefix-collision hazard (task #19 review send-back)" {
    // The reachable-TODAY shape `unbindOwnerPrefix`'s doc names: a wasm
    // plugin's action-provider owner is its bare NAME (`WasmPlugin.zig`'s
    // `unregisterByOwnerPrefix(self.name)`); a caps provider's id is
    // `"plugin.<name>/edit/completion"` (`wasm_host/capability.zig`). A
    // plugin literally named "plugin" makes "plugin.foo/edit/completion"
    // (some OTHER plugin's caps id) start with "plugin". Before `Domain`
    // existed, tearing down the action-domain owner "plugin" would ALSO
    // have swept the unrelated caps-domain binding below out from under
    // it, desyncing `Caps.providers` (still believing it registered) from
    // the Container (now missing it).
    const gpa = t.allocator;
    var c = Container.init(gpa);
    defer c.deinit();
    try declared(&c, "eval", .first_wins); // an action slot
    try c.declareSlot(.{ .name = "edit/completion", .shape = .query, .composition = .merge_ranked }); // a caps slot

    try c.bind(.{ .slot = "eval", .provider = .{ .command = "plugin-eval" }, .predicate = .{ .all = &.{} }, .owner = "plugin", .domain = .action });
    try c.bind(.{ .slot = "edit/completion", .provider = .{ .caps_provider = .{ .id = "plugin.foo/edit/completion", .seq = 0 } }, .predicate = .{ .all = &.{} }, .owner = "plugin.foo/edit/completion", .domain = .caps });

    // Tear down ONLY the action-domain owner "plugin" — a bare
    // `startsWith` would ALSO match the caps owner above
    // ("plugin.foo/edit/completion".startsWith("plugin")).
    c.unbindOwnerPrefix(.action, "plugin");

    // The action-domain binding is gone...
    try t.expectEqual(@as(?*const Binding, null), c.resolveOne("eval", .{}));
    // ...but the caps-domain binding SURVIVES and still resolves — the
    // exact desync the domain filter closes.
    const elig = try c.eligible(gpa, "edit/completion", .{});
    defer gpa.free(elig);
    try t.expectEqual(@as(usize, 1), elig.len);
    try t.expectEqualStrings("plugin.foo/edit/completion", elig[0].owner);

    // The SAME collision, `unbindOwnerExact` this time: a config manifest's
    // owner "config" names an action provide AND (after this send-back's
    // fix) a ui status segment at once — exact-match teardown of one must
    // not remove the other.
    try c.bind(.{ .slot = "eval", .provider = .{ .command = "config-eval" }, .predicate = .{ .all = &.{} }, .owner = "config", .domain = .action });
    try c.declareSlot(.{ .name = "ui/statusline-seg", .shape = .query, .composition = .ordered_union });
    try c.bind(.{ .slot = "ui/statusline-seg", .provider = .{ .value = "seg" }, .predicate = .{ .all = &.{} }, .owner = "config", .domain = .ui });

    c.unbindOwnerExact(.action, "config");
    try t.expectEqual(@as(?*const Binding, null), c.resolveOne("eval", .{}));
    const ui_elig = try c.eligible(gpa, "ui/statusline-seg", .{});
    defer gpa.free(ui_elig);
    try t.expectEqual(@as(usize, 1), ui_elig.len);
}

test "container: explain reports the eligible set, sort keys, and the winner" {
    const gpa = t.allocator;
    var c = Container.init(gpa);
    defer c.deinit();
    try declared(&c, "s", .first_wins);
    try c.bind(.{ .slot = "s", .provider = .{ .value = "low" }, .predicate = .{ .all = &.{} }, .priority = 0, .owner = "a" });
    try c.bind(.{ .slot = "s", .provider = .{ .value = "high" }, .predicate = .{ .all = &.{} }, .priority = 10, .owner = "b" });
    try c.bind(.{ .slot = "s", .provider = .{ .value = "unmatched" }, .predicate = .{ .mode = "insert" }, .priority = 999, .owner = "c" });

    var ex = try c.explain(gpa, "s", .{ .mode = "normal" });
    defer ex.deinit();
    try t.expectEqual(@as(usize, 2), ex.eligible.len); // the mode=insert one never matches
    try t.expectEqual(@as(?usize, 0), ex.winner);
    try t.expectEqualStrings("high", ex.eligible[0].provider.value);
    try t.expectEqualStrings("low", ex.eligible[1].provider.value);
    try t.expectEqual(@as(i32, 10), ex.eligible[0].priority);
    try t.expect(!ex.collision);
}

test "container: host-side client declares a new slot end-to-end (declare/bind/resolve/explain)" {
    const gpa = t.allocator;
    var c = Container.init(gpa);
    defer c.deinit();

    try c.declareSlot(.{ .name = "test/greeting", .shape = .value, .composition = .first_wins });
    try c.bind(.{ .slot = "test/greeting", .provider = .{ .value = "hello" }, .predicate = .{ .all = &.{} }, .priority = 0, .owner = "a" });
    try c.bind(.{ .slot = "test/greeting", .provider = .{ .value = "howdy" }, .predicate = .{ .all = &.{} }, .priority = 10, .owner = "b" });

    const winner = c.resolveOne("test/greeting", .{}).?;
    try t.expectEqualStrings("howdy", winner.provider.value);

    var ex = try c.explain(gpa, "test/greeting", .{});
    defer ex.deinit();
    try t.expectEqual(@as(usize, 2), ex.eligible.len);
    try t.expectEqualStrings("howdy", ex.eligible[ex.winner.?].provider.value);
}

test "container: ui_provider — an erased host fn/ctx round-trips through bind/resolve, Container never dereferences it" {
    // Proves the shape north-star-plan §6 W3 needs: Container stores the fn
    // pointer + ctx opaquely (like caps_provider's id/seq) and the CALLER
    // (an adapter, not Container) is the one who knows the concrete Args
    // type and invokes `call`.
    const gpa = t.allocator;
    var c = Container.init(gpa);
    defer c.deinit();
    try declared(&c, "ui/test-seg", .ordered_union);

    const Ctx = struct { tag: []const u8 };
    var ctx1: Ctx = .{ .tag = "alpha" };
    var ctx2: Ctx = .{ .tag = "beta" };
    const Impl = struct {
        fn call(ctx: ?*anyopaque, gpa2: Allocator, args: *anyopaque) anyerror!bool {
            _ = gpa2;
            const c2: *Ctx = @ptrCast(@alignCast(ctx.?));
            const out: *std.ArrayList([]const u8) = @ptrCast(@alignCast(args));
            try out.append(t.allocator, c2.tag);
            return true;
        }
    };
    try c.bind(.{ .slot = "ui/test-seg", .provider = .{ .ui_provider = .{ .call = Impl.call, .ctx = &ctx1 } }, .predicate = .{ .all = &.{} }, .priority = 10, .owner = "a" });
    try c.bind(.{ .slot = "ui/test-seg", .provider = .{ .ui_provider = .{ .call = Impl.call, .ctx = &ctx2 } }, .predicate = .{ .all = &.{} }, .priority = 5, .owner = "b" });

    const list = try c.eligible(gpa, "ui/test-seg", .{});
    defer gpa.free(list);
    try t.expectEqual(@as(usize, 2), list.len);

    var out: std.ArrayList([]const u8) = .empty;
    defer out.deinit(gpa);
    for (list) |b| {
        switch (b.provider) {
            .ui_provider => |up| _ = try up.call(up.ctx, gpa, @ptrCast(&out)),
            else => unreachable,
        }
    }
    // Priority order preserved: "alpha" (priority 10) before "beta" (priority 5).
    try t.expectEqual(@as(usize, 2), out.items.len);
    try t.expectEqualStrings("alpha", out.items[0]);
    try t.expectEqualStrings("beta", out.items[1]);
}

test "container: epoch is a real monotonic counter over declareSlot/bind/unbind" {
    const gpa = t.allocator;
    var c = Container.init(gpa);
    defer c.deinit();
    try t.expectEqual(@as(u64, 0), c.epoch);

    try declared(&c, "s", .first_wins);
    const after_declare = c.epoch;
    try t.expect(after_declare != 0);

    try c.bind(.{ .slot = "s", .provider = .{ .value = "a" }, .predicate = .{ .all = &.{} }, .owner = "a" });
    const after_bind = c.epoch;
    try t.expect(after_bind != after_declare);

    // A failed bind (unknown slot) never mutates state — never bumps epoch.
    try t.expectError(error.UnknownSlot, c.bind(.{ .slot = "nope", .provider = .{ .value = "x" }, .predicate = .{ .all = &.{} }, .owner = "a" }));
    try t.expectEqual(after_bind, c.epoch);

    c.unbindOwnerExact(.other, "a");
    try t.expect(c.epoch != after_bind);
}

test {
    std.testing.refAllDecls(@This());
}
