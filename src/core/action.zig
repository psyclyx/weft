//! Actions — abstract intents resolved to a concrete command by CONTEXT. The
//! middle tier of weft's dispatch, between the keymap (key → name) and the
//! command registry (name → handler):
//!
//!   key ─(keymap layers)→ NAME ─(action: providers + when + priority)→ command
//!
//! A command is a concrete leaf ("zig-eval", "save"). An *action* is a name a
//! key can bind to that many plugins PROVIDE for, each with a `when` predicate
//! and a priority; firing it runs whichever provider's `when` holds in the
//! current context, highest priority winning. Bind `SPC e → eval` once; a
//! `.zig` buffer runs `zig-eval`, a `.py` buffer `python-repl`, and a new
//! language plugin just registers another provider — "dispatching for free".
//!
//! Actions ride the command door: declaring one registers a trampoline
//! `Command` of the same name (see command.registerAction), so the keymap, ex
//! commands, the palette, and programmatic `command.run` all dispatch actions
//! uniformly — no bespoke firing path. The trampoline resolves the provider
//! against the live `Ctx` and tail-calls the chosen command.
//!
//! Two dispatch policies. `pick` (implemented here) runs the single best
//! applicable provider — the synchronous, command-shaped intents (eval, format,
//! repl, run, test). `race` is the async fan-out already embodied by the
//! capability system (capability.zig): completion/hover/definition merge many
//! providers' results over time. They are the same "resolve by context +
//! priority" idea at two latencies; `race` actions are declared here as a
//! reserved policy and delegate to `Caps` at their (few, UI-bound) call sites,
//! folded in incrementally rather than migrated wholesale.
//!
//! **F5 Container adapter (north-star-plan §2.2/§5/§6 W1).** `pick`
//! resolution is re-expressed as a query against `container.Container`: each
//! `provide()` call also binds a Container `Binding` on a slot named for the
//! action; `resolve()` queries `container.resolveOne` instead of hand-rolling
//! the priority/specificity scan. This is a TRANSITIONAL adapter. Tie-break
//! behavior for EXISTING data is preserved exactly — see `resolve`'s and
//! `provide`'s doc comments for how.
//!
//! **The shared-Container fold-in (task #19, the W3 deletion gate's first
//! half).** `self.container` is no longer an instance THIS module owns —
//! it's a `*container.Container` BORROWED from whoever constructs this
//! `Actions` (`System.zig`/`app/session.zig`/every test `Env`), the SAME
//! instance `capability.zig`'s `Caps` and `gfx/view/ui_mesh.zig`'s
//! statusline/gutter slots bind into: action names, `edit/*` capability
//! names, and `ui/*` mesh names are one flat namespace of Container slot
//! names now (they already couldn't collide — see `container.zig`'s doc).
//! What this fold-in does NOT do — the deletion gate is not yet fully
//! reached: `resolve()` below still calls `container.resolveOne` through
//! THIS module's own adapter shape (its own `When`/`Ctx`/`ProvideSpec`
//! vocabulary, its own `decl_index` bookkeeping) rather than a caller
//! querying a bare `container.Container` directly — folding the RESOLVE
//! PATH itself (deleting this adapter outright, not just unifying the store
//! it adapts onto) is the remaining, later step the plan still calls W3's
//! deletion gate.

const std = @import("std");
const Allocator = std.mem.Allocator;
const facts = @import("facts.zig");
const container_mod = @import("container.zig");

const Actions = @This();

pub const Policy = enum {
    /// Run the single highest-priority applicable provider now (synchronous).
    pick,
    /// Async fan-out + merge — the capability system's race. Reserved: a
    /// `race` action names an intent whose providers answer over time; its
    /// call sites drive `Caps` directly (see capability.zig) until they are
    /// folded onto this registry.
    race,
};

/// A context predicate over the ambient facts of the moment. Every PRESENT
/// field must hold (conjunction); an absent field is "don't care", so an empty
/// `When` matches everything (the default provider). v1 vocabulary is `mode`
/// and `lang`; the shape is deliberately small and grow-only — disjunction and
/// negation are a later addition, not a rewrite (a provider list already gives
/// OR across providers, and priority gives override).
pub const When = struct {
    /// Keymap mode that must be active (`normal`, `insert`, `dired`, …).
    mode: ?[]const u8 = null,
    /// Buffer language — the active buffer name's extension without the dot
    /// (`zig`, `py`, `md`). Matched case-sensitively.
    lang: ?[]const u8 = null,
    /// The active buffer's tool-backing name (a plugin projection: `dired`,
    /// `magit`), or null = don't care. Unlike `mode` — which changes as you
    /// edit a projection (vim `i`/Escape → insert/normal) — the tool-backing is
    /// a stable per-BUFFER signal, so a projection scopes its `save` (and other
    /// context intents) to its own identity, in any mode.
    tool: ?[]const u8 = null,
    // Specificity (constraint count) and eligibility ("holds") used to be
    // hand-rolled methods here; both are now `facts.Predicate`'s job (via
    // `predicateFromWhen` + `container.Container`) — see `provide`/`resolve`.
};

/// The ambient facts a `When` tests against — snapshotted at fire time from the
/// live editor (active mode + active buffer). `lang` is "" when the buffer has
/// no extension (a tool buffer, `*scratch*`).
pub const Ctx = struct {
    mode: []const u8,
    lang: []const u8 = "",
    /// The active buffer's tool-backing name, or "" when it's not a projection.
    tool: []const u8 = "",
};

/// The extension (sans dot) of a buffer display name, or "" — the `lang` key a
/// `When` matches. `build.zig` → "zig", `*scratch*` / `Makefile` → "".
pub fn langOfName(name: []const u8) []const u8 {
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return "";
    if (dot == 0 or dot + 1 >= name.len) return "";
    // A leading-dot name (".envrc") is not an extension; require a stem.
    return name[dot + 1 ..];
}

const Provider = struct {
    when: When, // owned strings (when.mode/.lang)
    priority: i32,
    command: []u8, // owned — the concrete command this provider runs
    owner: []u8, // owned — plugin/config name, for teardown
    /// Owned backing array for the Container `Binding.predicate` this
    /// provider bound (`predicateFromWhen`'s `.all` slice — empty but still
    /// allocated when `when` is unconstrained, so `deinit` is uniform).
    predicate_owned: []facts.Predicate = &.{},

    fn deinit(self: *Provider, gpa: Allocator) void {
        if (self.when.mode) |m| gpa.free(m);
        if (self.when.lang) |l| gpa.free(l);
        if (self.when.tool) |tl| gpa.free(tl);
        gpa.free(self.command);
        gpa.free(self.owner);
        gpa.free(self.predicate_owned);
    }
};

const Action = struct {
    policy: Policy,
    providers: std.ArrayList(Provider) = .empty,

    fn deinit(self: *Action, gpa: Allocator) void {
        for (self.providers.items) |*p| p.deinit(gpa);
        self.providers.deinit(gpa);
    }
};

/// The trampoline closure a declared action's `Command` carries as its `data`
/// payload: the action name to resolve at fire time. Owned by the registry.
pub const Trampoline = struct { name: []u8 };

gpa: Allocator,
actions: std.StringArrayHashMapUnmanaged(Action) = .empty,
trampolines: std.ArrayList(*Trampoline) = .empty,
/// The Container this module adapts onto (F5, W1) — BORROWED, not owned
/// (task #19's shared-Container fold-in): the caller constructing this
/// `Actions` owns one `container.Container` per System/Session and hands a
/// pointer to every domain that binds into it (`Caps`, this module, the UI
/// mesh). `Actions.deinit` therefore never calls `.deinit()` on it — the
/// owner tears it down, after every domain that borrowed it has torn down
/// ITS OWN bindings (see this struct's `deinit`). Every `pick` action name
/// is a `first_wins` slot; every `provide()`'d provider is a `Binding`.
container: *container_mod.Container,
/// Assigns each `provide()`d provider its `decl_index` basis — monotonic,
/// GLOBAL across every action name, and NEVER reused, mirroring
/// `capability.zig`'s `next_provider_seq`. Using a live provider-list length
/// instead (the pre-fix approach) reuses indices after
/// `unregisterByOwnerPrefix` shrinks that list, inverting same-owner
/// tie-breaks for providers registered after a teardown — see `provide`'s
/// doc and the regression test for the exact reproduction.
next_provide_seq: u64 = 0,

/// `container` is BORROWED (task #19): the caller owns one shared
/// `container.Container` (per System/Session — see this struct's field doc)
/// and keeps it alive at least as long as this `Actions` and every other
/// domain sharing it.
pub fn init(gpa: Allocator, container: *container_mod.Container) Actions {
    return .{ .gpa = gpa, .container = container };
}

/// Does NOT deinit `self.container` — it's borrowed (see the field doc);
/// the owner (System/Session) tears it down once every borrower (this
/// module, `Caps`, the UI mesh) has finished. This module also does not
/// unbind its own bindings from it here — see `container.zig`'s
/// `Container.deinit` doc: a full deinit never dereferences a binding's
/// borrowed strings, only the Container's OWN duped slot names, so freeing
/// this module's `Provider` strings (below) before or after the shared
/// Container itself is torn down is equally safe, AS LONG AS nothing
/// resolves against the Container in between — true for a coordinated
/// System/Session teardown, not true for a partial reload (see `provide`'s
/// and `unregisterByOwnerPrefix`'s docs for the partial-teardown discipline
/// that still applies).
pub fn deinit(self: *Actions) void {
    const gpa = self.gpa;
    for (self.actions.keys(), self.actions.values()) |name, *a| {
        gpa.free(name);
        a.deinit(gpa);
    }
    self.actions.deinit(gpa);
    for (self.trampolines.items) |tr| {
        gpa.free(tr.name);
        gpa.destroy(tr);
    }
    self.trampolines.deinit(gpa);
}

/// Record action `name` with a dispatch `policy`, idempotently, WITHOUT binding
/// a trampoline command. First declaration sets the policy; a later one keeps
/// it (a policy mismatch is a warning, not a change — the name's identity is
/// fixed by whoever declared it first). Used by `provide` (auto-declare) and by
/// `noteRace` (register a capability intent); `declare` layers a trampoline on.
pub fn ensure(self: *Actions, name: []const u8, policy: Policy) !void {
    const gpa = self.gpa;
    const gop = try self.actions.getOrPut(gpa, name);
    if (!gop.found_existing) {
        gop.key_ptr.* = try gpa.dupe(u8, name);
        gop.value_ptr.* = .{ .policy = policy };
        // Every action name is a `first_wins` Container slot, `pick` or
        // `race` alike — `race` actions never get providers bound here
        // (Caps binds its own Container instead), so the declaration is
        // inert for them, but idempotent/harmless to make.
        try self.container.declareSlot(.{ .name = name, .shape = .action, .composition = .first_wins });
    } else if (gop.value_ptr.policy != policy) {
        std.log.warn("action '{s}': declared {s} but re-declared {s}; keeping the first", .{ name, @tagName(gop.value_ptr.policy), @tagName(policy) });
    }
}

/// Declare an action `name` with a dispatch `policy`, idempotently. Returns the
/// trampoline payload the caller binds a `Command` of the same name to (see
/// command.registerAction) — stable for the registry's lifetime. Re-declaring
/// keeps the existing action (and its providers) and returns its trampoline, so
/// declaration order across plugins/config doesn't matter.
pub fn declare(self: *Actions, name: []const u8, policy: Policy) !*Trampoline {
    const gpa = self.gpa;
    try self.ensure(name, policy);
    // A trampoline per declaration site is cheap and lets re-declaration stay
    // idempotent without deduping command binds; they all resolve the same name.
    const tr = try gpa.create(Trampoline);
    errdefer gpa.destroy(tr);
    tr.* = .{ .name = try gpa.dupe(u8, name) };
    try self.trampolines.append(gpa, tr);
    return tr;
}

/// Register a capability kind as a `race`-policy action (idempotent), so the
/// registry enumerates every intent — pick AND race — in one place. Race
/// resolution is the capability system's async fan-out (`Caps`), NOT the pick
/// provider list; `Context.fireRace` records the intent here and drives `Caps`.
pub fn noteRace(self: *Actions, name: []const u8) void {
    self.ensure(name, .race) catch {};
}

pub fn isAction(self: *const Actions, name: []const u8) bool {
    return self.actions.contains(name);
}

pub fn policyOf(self: *const Actions, name: []const u8) ?Policy {
    const a = self.actions.getPtr(name) orelse return null;
    return a.policy;
}

pub const ProvideSpec = struct {
    action: []const u8,
    when: When = .{},
    command: []const u8,
    priority: i32 = 0,
    owner: []const u8 = "plugin",
    /// Policy to auto-declare the action with if it doesn't exist yet — a
    /// provider can arrive before its `declare` (load order is free).
    declare_policy: Policy = .pick,
    /// The Container tier this provider binds at (north-star-plan §2.2/§6
    /// W1: "action provides carry Container Tier.imported vs Tier.config").
    /// Defaults to `.plugin` — every `.wasm`/JS-plugin call site through
    /// `capability.zig`-style registration keeps today's uniform-plugin-tier
    /// behavior unchanged. `manifest.zig`'s config-manifest apply is the ONE
    /// caller that now passes a REAL tier (`.config` for the root manifest,
    /// `.imported` for a `weft.use`-imported one) — the config-plane
    /// stratification the W2b-pending note anticipated, arriving here first.
    tier: container_mod.Tier = .plugin,
};

/// Register a provider for `spec.action`, auto-declaring the action if needed
/// (so `provide` before `declare` is fine). Owns copies of every string.
pub fn provide(self: *Actions, spec: ProvideSpec) !void {
    const gpa = self.gpa;
    // A race action's providers are the async capability providers (registered
    // through the capability ABI, not here) — a `pick` command provider on one
    // would never be consulted. Refuse it as a TYPED ERROR the caller must
    // handle, rather than a fire-and-forget `std.log.warn`: the membranes
    // surface it to the plugin author through `echo` (the normal user-facing
    // channel), so a mistake is reported where the author will see it instead
    // of on a global stderr a caller can ignore — and a test can assert the
    // refusal with `expectError` without polluting the suite's stderr (which
    // Zig's build runner flags, printing a spurious `failed command:`).
    if (self.actions.getPtr(spec.action)) |a| {
        if (a.policy == .race) return error.RaceRejectsProvider;
    } else {
        try self.ensure(spec.action, spec.declare_policy); // auto-declare (load order is free)
    }
    const gop = self.actions.getOrPut(gpa, spec.action) catch unreachable; // present now
    // Reserve capacity BEFORE any owned memory exists, so the append at the
    // end (after Container has already accepted the binding) is infallible
    // — otherwise a late OOM there would leave the Container referencing a
    // Provider that was never actually stored (see the ownership note by
    // `appendAssumeCapacity` below).
    try gop.value_ptr.providers.ensureUnusedCapacity(gpa, 1);

    var p: Provider = .{
        .when = .{},
        .priority = spec.priority,
        .command = try gpa.dupe(u8, spec.command),
        .owner = try gpa.dupe(u8, spec.owner),
    };
    errdefer p.deinit(gpa);
    if (spec.when.mode) |m| p.when.mode = try gpa.dupe(u8, m);
    if (spec.when.lang) |l| p.when.lang = try gpa.dupe(u8, l);
    if (spec.when.tool) |tl| p.when.tool = try gpa.dupe(u8, tl);

    const pred = try predicateFromWhen(gpa, p.when);
    p.predicate_owned = ownedBacking(pred);

    // decl_index: the Container's canonical tie-break convention is
    // "earlier decl_index wins" (container.zig's `betterThan`); THIS
    // module's pre-Container contract was "later registration wins"
    // (resolve's old doc comment, still true from a caller's view).
    // Subtracting a MONOTONIC, NEVER-REUSED `next_provide_seq` (not a live
    // provider-list length — that reuses indices after a teardown shrinks
    // the list, inverting same-owner tie-breaks; see the field doc and
    // "action: decl_index survives teardown...") makes "later registered"
    // mean "smaller decl_index" mean "wins", reproducing the legacy
    // contract exactly through the new convention, permanently — not just
    // until the next `unregisterByOwnerPrefix`.
    const seq = self.next_provide_seq;
    self.next_provide_seq += 1;
    const decl_index: u32 = std.math.maxInt(u32) - @as(u32, @intCast(seq));

    // Container.bind borrows `pred`/`p.command`/`p.owner` — all owned by
    // `p`. Bind BEFORE storing `p`: on failure (SlotCollision, or OOM
    // growing the container's own bindings list), `errdefer p.deinit`
    // above cleans up `p`'s memory and nothing has been stored anywhere
    // that could reference it afterward. On success, the capacity
    // reserved above makes storing `p` itself infallible, so the
    // Container's new binding is never left pointing at a Provider that
    // didn't end up recorded.
    try self.container.bind(.{
        .slot = self.actions.getKey(spec.action).?,
        .provider = .{ .command = p.command },
        .predicate = pred,
        .priority = spec.priority,
        // TIER: `spec.tier`, defaulting to `.plugin` — the uniform-tier
        // deviation from §2.2's "tier from owner class" language is now
        // scoped to callers that DON'T pass a real tier (every `.wasm`/
        // JS-plugin capability registration path), not a blanket rule.
        // `manifest.zig`'s config-manifest `apply` is the one caller that
        // now passes `.config`/`.imported` — the W2b-pending stratification
        // arriving for the config plane specifically (north-star-plan §6):
        // a config manifest's OWN providers stay relatively ordered by
        // priority/specificity exactly as before (they're all the SAME
        // tier, `.config`), so the "config sets a low-priority default"
        // pattern within one manifest is unaffected; only a DIFFERENT
        // tier's provider (an imported manifest, or a future plugin-tier
        // provide) now loses to config's on tier before priority is even
        // consulted — which is the point.
        .tier = spec.tier,
        .owner = p.owner,
        .domain = .action,
        .decl_index = decl_index,
    });
    gop.value_ptr.providers.appendAssumeCapacity(p);
}

/// Build the Container predicate for `when`: each present field is one
/// conjunct (`.all` of 0..3 leaves — 0 = unconstrained, matches always,
/// specificity 0, exactly the old `When{}` default provider's standing).
/// Always heap-allocates (even the empty case) so `Provider.deinit`'s
/// `gpa.free` is uniform regardless of how many fields were set.
fn predicateFromWhen(gpa: Allocator, w: When) Allocator.Error!facts.Predicate {
    var buf: [3]facts.Predicate = undefined;
    var n: usize = 0;
    if (w.mode) |m| {
        buf[n] = .{ .mode = m };
        n += 1;
    }
    if (w.lang) |l| {
        buf[n] = .{ .lang = l };
        n += 1;
    }
    if (w.tool) |tl| {
        buf[n] = .{ .tool = tl };
        n += 1;
    }
    const owned = try gpa.alloc(facts.Predicate, n);
    @memcpy(owned, buf[0..n]);
    return .{ .all = owned };
}

fn ownedBacking(p: facts.Predicate) []facts.Predicate {
    return switch (p) {
        .all => |k| @constCast(k),
        else => &.{},
    };
}

/// The concrete command an action resolves to in `ctx`, or null when no
/// provider's `when` holds. The winner is the highest priority among applicable
/// providers; ties break toward the MORE SPECIFIC `when` (a `lang:zig` provider
/// over an unconstrained default), then toward the later registration — a pure
/// function of the provider set and the context, never load-order dependent
/// beyond the deliberate same-(priority,specificity) last-wins.
///
/// F5 adapter: a Container query (`container.resolveOne`) rather than the
/// hand-rolled scan this doc comment used to describe verbatim — see
/// `provide`'s `decl_index` note for how "later registration wins" survives
/// the swap. On the dispatch-latency hot path (`e2e/latency`'s `action`
/// category): no allocation, matching the original scan's profile.
pub fn resolve(self: *const Actions, name: []const u8, ctx: Ctx) ?[]const u8 {
    const b = self.container.resolveOne(name, factsOf(ctx)) orelse return null;
    return b.provider.command;
}

fn factsOf(ctx: Ctx) facts.Facts {
    return .{ .mode = ctx.mode, .lang = ctx.lang, .tool = ctx.tool };
}

/// Remove every provider registered by an owner whose name starts with
/// `owner_prefix` (plugin teardown). Actions themselves persist (they are
/// names, cheap and idempotent to re-declare). Container bindings are
/// dropped FIRST — they borrow each provider's `command`/`owner` strings, so
/// removing them before `Provider.deinit` frees that memory is required, not
/// cosmetic (see container.zig's `unbindOwnerPrefix` doc).
pub fn unregisterByOwnerPrefix(self: *Actions, owner_prefix: []const u8) void {
    self.container.unbindOwnerPrefix(.action, owner_prefix);
    for (self.actions.values()) |*a| {
        var i: usize = 0;
        while (i < a.providers.items.len) {
            if (std.mem.startsWith(u8, a.providers.items[i].owner, owner_prefix)) {
                var p = a.providers.swapRemove(i);
                p.deinit(self.gpa);
            } else i += 1;
        }
    }
}

/// Remove every provider whose owner EQUALS `owner` exactly — for a caller
/// whose owner identities are dynamically named and could otherwise
/// false-prefix-match a sibling (e.g. `manifest.zig`'s reconcile teardown:
/// owner `"import:def"` must not also tear down `"import:defaults"`, which
/// `unregisterByOwnerPrefix`'s `startsWith` would do). Same shape as the
/// prefix version, `std.mem.eql` instead.
pub fn unregisterByOwner(self: *Actions, owner: []const u8) void {
    self.container.unbindOwnerExact(.action, owner);
    for (self.actions.values()) |*a| {
        var i: usize = 0;
        while (i < a.providers.items.len) {
            if (std.mem.eql(u8, a.providers.items[i].owner, owner)) {
                var p = a.providers.swapRemove(i);
                p.deinit(self.gpa);
            } else i += 1;
        }
    }
}

// ── Tests ───────────────────────────────────────────────────────────

const t = std.testing;

test "action: pick resolves by context, priority, and specificity" {
    var container = container_mod.Container.init(t.allocator);
    defer container.deinit();
    var acts = Actions.init(t.allocator, &container);
    defer acts.deinit();

    // eval: a zig provider, a python provider, and an unconstrained default.
    try acts.provide(.{ .action = "eval", .when = .{ .lang = "zig" }, .command = "zig-eval" });
    try acts.provide(.{ .action = "eval", .when = .{ .lang = "py" }, .command = "python-repl" });
    try acts.provide(.{ .action = "eval", .command = "eval-line-default", .priority = -10 });

    try t.expectEqualStrings("zig-eval", acts.resolve("eval", .{ .mode = "normal", .lang = "zig" }).?);
    try t.expectEqualStrings("python-repl", acts.resolve("eval", .{ .mode = "normal", .lang = "py" }).?);
    // No language-specific provider → the low-priority default still applies.
    try t.expectEqualStrings("eval-line-default", acts.resolve("eval", .{ .mode = "normal", .lang = "md" }).?);

    // Specificity breaks an equal-priority tie: a lang-scoped provider beats an
    // unconstrained one bound at the SAME priority.
    try acts.provide(.{ .action = "fmt", .command = "fmt-generic" });
    try acts.provide(.{ .action = "fmt", .when = .{ .lang = "zig" }, .command = "zig-fmt" });
    try t.expectEqualStrings("zig-fmt", acts.resolve("fmt", .{ .mode = "normal", .lang = "zig" }).?);
    try t.expectEqualStrings("fmt-generic", acts.resolve("fmt", .{ .mode = "normal", .lang = "c" }).?);

    // An unknown action, and an action with no applicable provider, resolve null.
    try t.expectEqual(@as(?[]const u8, null), acts.resolve("nope", .{ .mode = "normal" }));
    try acts.provide(.{ .action = "run", .when = .{ .mode = "debug" }, .command = "run-target" });
    try t.expectEqual(@as(?[]const u8, null), acts.resolve("run", .{ .mode = "normal", .lang = "zig" }));
}

test "action: a projection scopes save by its tool identity, in any mode" {
    var container = container_mod.Container.init(t.allocator);
    defer container.deinit();
    var acts = Actions.init(t.allocator, &container);
    defer acts.deinit();

    // Core's default save (file write), and dired's save for its projection.
    try acts.provide(.{ .action = "save", .command = "save-file" });
    try acts.provide(.{ .action = "save", .when = .{ .tool = "dired" }, .command = "dired-save" });

    // In the dired projection, dired's provider wins — REGARDLESS of mode
    // (normal while you :w, insert while you type): the tool identity is stable.
    try t.expectEqualStrings("dired-save", acts.resolve("save", .{ .mode = "normal", .tool = "dired" }).?);
    try t.expectEqualStrings("dired-save", acts.resolve("save", .{ .mode = "insert", .tool = "dired" }).?);
    // A normal file buffer (no tool) falls to the default file write.
    try t.expectEqualStrings("save-file", acts.resolve("save", .{ .mode = "normal", .lang = "zig", .tool = "" }).?);
    // A different projection doesn't get dired's save.
    try t.expectEqualStrings("save-file", acts.resolve("save", .{ .mode = "normal", .tool = "magit" }).?);
}

test "action: declare is idempotent and provider load-order-independent" {
    var container = container_mod.Container.init(t.allocator);
    defer container.deinit();
    var acts = Actions.init(t.allocator, &container);
    defer acts.deinit();

    // provide-before-declare works (auto-declares).
    try acts.provide(.{ .action = "eval", .when = .{ .lang = "zig" }, .command = "zig-eval" });
    _ = try acts.declare("eval", .pick);
    try t.expect(acts.isAction("eval"));
    try t.expectEqual(Policy.pick, acts.policyOf("eval").?);

    // Higher priority wins regardless of registration order.
    try acts.provide(.{ .action = "eval", .when = .{ .lang = "zig" }, .command = "zig-eval-lsp", .priority = 100 });
    try t.expectEqualStrings("zig-eval-lsp", acts.resolve("eval", .{ .mode = "normal", .lang = "zig" }).?);
}

test "action: owner-prefix teardown drops a plugin's providers" {
    var container = container_mod.Container.init(t.allocator);
    defer container.deinit();
    var acts = Actions.init(t.allocator, &container);
    defer acts.deinit();

    try acts.provide(.{ .action = "eval", .when = .{ .lang = "zig" }, .command = "zig-eval", .owner = "zig-tools#3" });
    try acts.provide(.{ .action = "eval", .command = "eval-default", .owner = "config", .priority = -10 });
    try t.expectEqualStrings("zig-eval", acts.resolve("eval", .{ .mode = "normal", .lang = "zig" }).?);

    acts.unregisterByOwnerPrefix("zig-tools#");
    // The plugin's provider is gone; the config default remains.
    try t.expectEqualStrings("eval-default", acts.resolve("eval", .{ .mode = "normal", .lang = "zig" }).?);
}

test "action: unregisterByOwner is exact — a false-prefix sibling survives" {
    var container = container_mod.Container.init(t.allocator);
    defer container.deinit();
    var acts = Actions.init(t.allocator, &container);
    defer acts.deinit();

    // "import:def" is a literal string-prefix of "import:defaults" — the
    // exact scenario `unregisterByOwnerPrefix` would get wrong.
    try acts.provide(.{ .action = "eval", .when = .{ .lang = "zig" }, .command = "from-def", .owner = "import:def" });
    try acts.provide(.{ .action = "eval", .when = .{ .lang = "py" }, .command = "from-defaults", .owner = "import:defaults" });

    acts.unregisterByOwner("import:def");
    // The false-prefix sibling's provider survives.
    try t.expectEqualStrings("from-defaults", acts.resolve("eval", .{ .mode = "normal", .lang = "py" }).?);
    // The exactly-named owner's provider is gone.
    try t.expectEqual(@as(?[]const u8, null), acts.resolve("eval", .{ .mode = "normal", .lang = "zig" }));
}

test "action: decl_index survives teardown — later-wins even after an unrelated owner's providers are removed" {
    // Reproduces the exact sequence a review found broken when decl_index
    // was derived from the live (shrinkable) provider-list length: provide
    // B1, provide C1, provide B2, unregister C (shrinking the list C1 sat
    // in), provide B3. C gets a distinct priority so its OWN registration
    // is a legitimate, non-colliding bind (an unconstrained same-priority
    // C would rightly collide with B's default provider — a different,
    // correct behavior this test isn't about); what matters is only that C
    // occupies a slot in the provider list before being torn down. The
    // three B-owned providers tie on (tier,priority,specificity) — same
    // owner, so decl_index alone decides — and the legacy, still-documented
    // contract is "later registration wins": B3 must win, not B2.
    var container = container_mod.Container.init(t.allocator);
    defer container.deinit();
    var acts = Actions.init(t.allocator, &container);
    defer acts.deinit();

    try acts.provide(.{ .action = "eval", .command = "b1", .owner = "B" });
    try acts.provide(.{ .action = "eval", .command = "c1", .owner = "C", .priority = 5 });
    try acts.provide(.{ .action = "eval", .command = "b2", .owner = "B" });
    try t.expectEqualStrings("c1", acts.resolve("eval", .{ .mode = "normal" }).?); // C's higher priority wins for now

    acts.unregisterByOwnerPrefix("C");
    try acts.provide(.{ .action = "eval", .command = "b3", .owner = "B" });
    try t.expectEqualStrings("b3", acts.resolve("eval", .{ .mode = "normal" }).?);
}

test "action: race intents are enumerable, and reject pick providers" {
    var container = container_mod.Container.init(t.allocator);
    defer container.deinit();
    var acts = Actions.init(t.allocator, &container);
    defer acts.deinit();

    // A capability kind noted as a race intent joins the one registry.
    acts.noteRace("hover");
    try t.expect(acts.isAction("hover"));
    try t.expectEqual(Policy.race, acts.policyOf("hover").?);

    // A pick provider on a race action is refused with a TYPED ERROR (its
    // providers are the async capability providers, registered elsewhere) —
    // asserted by value, so nothing is logged to the suite's stderr. resolve
    // stays empty.
    try t.expectError(error.RaceRejectsProvider, acts.provide(.{ .action = "hover", .command = "fake-hover" }));
    try t.expectEqual(@as(?[]const u8, null), acts.resolve("hover", .{ .mode = "normal", .lang = "zig" }));

    // noteRace is idempotent and doesn't disturb a real pick action.
    try acts.provide(.{ .action = "eval", .when = .{ .lang = "zig" }, .command = "zig-eval" });
    acts.noteRace("hover");
    try t.expectEqualStrings("zig-eval", acts.resolve("eval", .{ .mode = "normal", .lang = "zig" }).?);
}

test "action: langOfName extracts the extension, or empty" {
    try t.expectEqualStrings("zig", langOfName("build.zig"));
    try t.expectEqualStrings("py", langOfName("a/b/c.py"));
    try t.expectEqualStrings("", langOfName("*scratch*"));
    try t.expectEqualStrings("", langOfName("Makefile"));
    try t.expectEqualStrings("", langOfName(".envrc")); // leading dot ≠ extension
    try t.expectEqualStrings("", langOfName("trailing.")); // no stem after dot
}

test {
    std.testing.refAllDecls(@This());
}
