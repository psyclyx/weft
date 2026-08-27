//! grants — the GRANT TABLE (doc/contextual-workspace-architecture.md §13.5: "the
//! capture-time grant powerbox"). Read the plan section in full before
//! touching this file; this comment is the compressed version.
//!
//! **The shape, in one paragraph.** A `GrantDecl` is a declared authority
//! (`capability` name + `predicate` over `Facts` + a `limit`). A
//! `HandleTable` (owned by a `System`, see `System.zig`'s `grants` field) is
//! an APPEND-ONLY table of `Row`s — one row per (principal, capability) a
//! plugin's `describe()` handshake actually granted, minted at LOAD time
//! (`wasm_host/plugin.zig`'s `mintGrantHandles`). A `CapHandle` is a small
//! POD (`idx` + `gen`) naming one row — cheap to copy, cheap to compare,
//! cheap to invalidate. **Revocation is table invalidation**: flip `alive`
//! and bump `gen`, never mutate a live `CapHandle` anyone is holding — it
//! simply stops `check`ing true.
//!
//! **Two consumers, one table, no wallet.**
//!   1. **Use = possession** (`wasm_host/plugin.zig`'s `hasPerm`): a loaded
//!      plugin holds its OWN handles (`WasmPlugin.grant_handles`, minted
//!      once at load) and checks them directly at the point of use — no
//!      context-stack walk, no table scan, just `table.check(my_handle)`.
//!      This is what makes revoking a RUNNING plugin's fs perm take effect
//!      on its very next call: the plugin never re-reads a boolean, it
//!      re-checks the SAME row, which the revoke just flipped.
//!   2. **Capture-time resolution** (`ctx.zig`'s `Ctx.capture`): the
//!      OTHER consumer, for anything that wants "what can THIS interaction
//!      currently do" without being a plugin identity — `collectForPrincipal`
//!      scans the table for rows matching a principal + the captured facts
//!      and appends the matching handles into a caller-owned, bounded list
//!      (zero allocation — see `ctx.zig`'s `GrantList`). This is the
//!      capture-time powerbox itself: what rides `Ctx.grants` is exactly
//!      the rows eligible for THIS capture, never a wallet the receiving
//!      code could pick and choose from. STATUS: the table has two READERS,
//!      but consumer #2's RESULT has no production consumer yet — collected,
//!      tested, unconsumed (see `Ctx.grants`' field doc for the coupling
//!      rule its first consumer must honor). A swept scope's rows report the
//!      dedicated `.scope_expired` Reason (task #8's structured taxonomy),
//!      distinct from an explicit `revoke` — see `Row.scope_dead`.
//!
//! **Scope lifetime** (§2.4: "a handle's lifetime is bounded by the scope
//! its GrantDecl matched"). A row MAY carry an owning `scope: ?u64` token
//! (`HandleTable.newScope`/a caller-chosen token like a transient's `depth`,
//! see `ctx.zig`'s `Ctx.grantScopedToTransient`); `sweepScope` invalidates
//! every row tagged with a given token — the scope-exit sweep. **Honest v1
//! scope of this mechanism**: every PRODUCTION grant today (both the
//! describe()-boolean baseline AND a manifest-authored `weft.grant`, see
//! below) is plugin-lifetime (minted at load/apply, `scope = null`, swept
//! only when the whole table is torn down with its owning `System`) —
//! `sweepScope` exists and is tested (`ctx.zig`'s paired-transient test), but
//! nothing production wires a SCOPED grant yet (a buffer/transient-scoped
//! `weft.grant` is a later slice; this table is the machinery it will
//! populate, not a stand-in for it).
//!
//! **What's deliberately NOT here**: predicate-gated admission at USE time
//! (a row's `predicate` is recorded and inspectable, but `hasPerm`'s
//! possession check does not currently evaluate it — the fs semantic
//! bodies check ONLY aliveness, per capability, exactly like the boolean
//! they replace). `Limit.fs_root` ENFORCEMENT itself is no longer deferred:
//! W4 slice 2 wires it — `wasm_host/fs.zig`'s five split semantic bodies now
//! consult `limitFor` and confine a limited grant's paths (see that file's
//! module doc for the exact policy, including the named v1 symlink-handling
//! gap in `fsExists`).
//!
//! **`weft.grant` (W4 slice 4, this table's last deferred consumer landed)**:
//! `manifest.zig`'s `weft.grant(plugin, capability, opts)` verb stages a
//! `ManifestGrantDecl` (opts.root → `Limit.fs_root`) that `reconcileGrants`
//! mints into THIS table (`Manifest.apply` calls it too, with `old = null` —
//! there is no separate `applyGrants` function), strictly BEFORE the named
//! plugin's `describe()` handshake runs (`Manifest.apply`/`.reconcile`'s
//! ordering — grants before `loadPlugins`). **Composition, decided**: a
//! config-authored row for `(plugin, capability)` REPLACES the
//! describe()-boolean baseline for that exact pair — `findLive` (below) is
//! `mintGrantHandles`'s read side, consulted before it would otherwise mint a
//! second, unrestricted row; config is the user's EXPLICIT word, and tier
//! logic already says config outranks a plugin's own ask. The honest
//! consequence, also decided: since the baseline row for a config-narrowed
//! pair is never minted in the first place, revoking (or reconcile tearing
//! down) the config grant does NOT "fall back" to an unrestricted baseline —
//! there is none to fall back to; the plugin loses that capability entirely
//! until a fresh load re-establishes it (mirrors the existing "plugin
//! removed from config but unload isn't wired — restart to fully remove it"
//! honesty `manifest.zig` already states for plugins themselves). The MIRROR
//! case is equally honest: ADDING a narrowing grant for an ALREADY-RUNNING
//! plugin mints a real, independently-revocable row, but that plugin's OWN
//! possessed handle (`mintGrantHandles` only ever runs at ITS load) stays
//! pointed at its original, broader handle until a fresh load re-runs the
//! composition check — see `manifest.zig`'s `reconcileGrants` doc for the
//! full reasoning. An explicit `revoke` command, unlike a reload, takes
//! effect immediately (it invalidates the row a handle already points at,
//! rather than depending on `mintGrantHandles` running again).
//!
//! **`Limit.doc_region` (W4 slice 3, review B2's repair)**: identity-anchored
//! (not position-anchored) text-region confinement — see `DocRegion`'s doc
//! for the shape, side semantics, and collapse policy. ENFORCEMENT lives at
//! `command.Context.edit`/`checkDocRegion` (the ONE chokepoint every guest
//! `wl_edit`/`wl_edit_as`/`wl_edit_range` door and every host/in-process edit
//! already funnels through — see `wasm_host/edit.zig`'s module doc), not
//! here or in `wasm_host/*`: unlike `.fs_root`, this limit needs to resolve
//! anchors against a LIVE `Document`, which neither this table nor a bare
//! `CapHandle` has access to. **Still honest-v1 population**: `weft.grant`'s
//! `opts` v1 supports only `root` (→ `.fs_root`) — a config-authored
//! `.doc_region` limit is deliberately NOT expressible from config (doc
//! regions are RUNTIME identities, resolved against a live `Document`'s
//! anchors; a config script evaluates before any buffer exists, so it has no
//! anchor to author against — see `manifest.zig`'s `ManifestGrantDecl` doc
//! for the full reasoning). Tests still mint a `.doc_region` row directly via
//! `grant()`; a future runtime-side verb (a command a loaded plugin/keybind
//! invokes against a live buffer) is what would populate this in production.
//!
//! **`Limit.graph_subtree` (W6 slice 2, doc/substrate.md)**: the
//! graph-doc analog of `.doc_region` — see `GraphSubtree`'s doc for the
//! shape, collapse policy, and the union-of-grants confinement decision.
//! ENFORCEMENT lives at `session/GraphCollab.zig`'s `admitRegions` (that
//! file's per-region admission hook, shared verbatim with W6 slice 1's
//! lease — same split as `.doc_region`, a different live document type to
//! resolve against). **Provenance, honest-v1**: unlike `.fs_root`/
//! `.doc_region`, there is no config surface AT ALL yet, not even a
//! runtime-verb one — `GraphCollab.grantSubtree` is a host-called API with
//! no caller in production code, the same "collected, tested, unconsumed"
//! status `Ctx.grants`' own doc comment names for its still-unwired
//! consumer. A `weft.grant`-shaped config surface for subtree grants is
//! explicitly deferred (it would need the same "runtime identity, not a
//! config-time one" argument `.doc_region` already makes, plus a live
//! `GraphDoc` to resolve against — neither exists at config-eval time).
//!
//! **`ExportBook` (§13.5's per-export grants)**: this file's SECOND table,
//! the peer-authority sibling of `HandleTable` — see its own section comment
//! below for why it is a sibling and not a mode of the first. Grades survive
//! only as presets/maxima; effective remote authority is per publication
//! export, at a live epoch, keyed on an authenticated fingerprint.

const std = @import("std");
const Allocator = std.mem.Allocator;
const facts_mod = @import("facts.zig");
const graph = @import("graph.zig");
const Document = @import("Document.zig");

pub const Facts = facts_mod.Facts;
pub const Predicate = facts_mod.Predicate;

/// The portable identity anchor a `.doc_region` limit is keyed on — the
/// SAME (agent, seq, side) type `Document.zig` re-exports (both `TextDoc`
/// and `ObjectDoc` alias stemma's one `seq_walker.EventAnchor`/`AnchorSide`
/// rather than defining their own — see `Document.EventAnchor`'s doc for
/// the pin-vs-root-export note). Aliased through `Document` — not
/// `stemma.TextDoc` again — so there is exactly one place in weft that
/// resolves this type, not two independently-arrived-at aliases of the
/// same thing (see `DocRegion`'s doc for why the EXPORTED form, not a
/// byte offset, is what a limit stores).
pub const EventAnchor = Document.EventAnchor;
pub const AnchorSide = Document.AnchorSide;

/// A `.doc_region` limit (doc/contextual-workspace-architecture.md §13.5, review B2's
/// repair): "text-region limits are identity-anchored, not
/// position-anchored." `doc_id` names the target document — a grant table is
/// System-scoped (many buffers share it), so a region limit must say WHICH
/// buffer it narrows; today's minter uses the buffer's own `name` (the same
/// string `ctx.zig`'s buffer-scope `.path`/`.name` facts already read — see
/// `command.Context.checkDocRegion`).
///
/// `start`/`end` are the PORTABLE, EXPORTED anchor form
/// (`Document.exportAnchor`/stemma's `anchorAt`) — an (agent, seq, side)
/// triple identifying an INSERTION EVENT, never a replica-local index or a
/// bare byte offset — so the limit survives holding NO live `TextDoc` state
/// and resolves correctly on any replica that has seen the anchored events
/// (review B2: "content moves in or out and the range doesn't follow" is
/// exactly the position-anchored failure this form avoids). `EventAnchor.agent`
/// is heap-owned (`anchorAt`'s doc: caller-owned, `gpa.dupe`d) — the MINTER is
/// responsible for keeping it alive for the grant row's lifetime, the same
/// 'static-for-practical-purposes borrow convention `Row.principal`/
/// `.capability` already document.
///
/// **Side semantics, DECIDED (§6 W4 slice 3)**: mint `start` via
/// `exportAnchor(region.start, .after)` (binds to the character BEFORE the
/// region) and `end` via `exportAnchor(region.end, .before)` (binds to the
/// character AFTER it) — GROWING/inclusive boundaries. Concretely: text
/// typed at either edge, by anyone, resolves INSIDE the region on the next
/// `resolveAnchors` (see the worked arithmetic in `command.Context.checkDocRegion`'s
/// tests). Justification: the flagship scenario is "an agent granted a
/// function should keep authority over text typed at the function's edges"
/// — a SHRINKING choice (anchoring to the region's own first/last character
/// instead) would strand the agent unable to touch text it just typed at
/// its own boundary (its function's newly-typed opening brace, say). A
/// shrinking limit is also expressible (anchor `.before`-on-first-char /
/// `.after`-on-last-char) for a future caller that wants the opposite
/// trade — this type doesn't hard-code the anchor calls, only documents
/// which convention this slice's tests exercise.
///
/// **Collapse policy** (review B2: "collapsing on deletion, error.Compacted
/// on compaction... never silent drift"): stemma's OWN `resolveAnchors`
/// does NOT error on ordinary deletion — a deleted target "collapses to its
/// deletion point" (its doc), which is the wrong granularity for a GRANT
/// (silently narrowing to a still-resolvable-but-meaningless point would be
/// exactly the silent drift review B2 forbids). `command.Context.checkDocRegion`
/// therefore treats a limit as COLLAPSED — trap, never allow, never silently
/// narrow — under TWO conditions: (1) `resolveAnchors` itself errors
/// (`error.Compacted`/`.MissingDependency`/`.Corrupt`, or an allocation
/// failure — ANY failure fails CLOSED, not open); (2) the resolved region
/// degenerates to empty-or-inverted (`start >= end`) — stemma's
/// "collapses to its deletion point" behavior means BOTH boundary anchors
/// riding to the same gap (the whole region's text got deleted) resolves
/// WITHOUT an error, so the degenerate-width check is what actually catches
/// it. A single boundary character's deletion, with the region's interior
/// otherwise intact, is NOT collapse — the region just rides to its new
/// (still well-formed, non-degenerate) bounds; that is what "survives
/// concurrent edits" means.
///
/// **A whole-region REWRITE is not the same shape as a whole-region CLEAR
/// (empirically verified, W4 slice 3 review)**: a SINGLE `ctx.edit(region,
/// newText)` — one atomic delete-then-insert commit — does NOT collapse,
/// even though it removes every byte between the boundary anchors. The
/// insert's CRDT origin is computed against the LOCAL replica state right
/// after the delete already applied (same commit), i.e. immediately
/// adjacent to BOTH surviving boundary characters — so the new content
/// lands causally BETWEEN them and the region re-inflates around it on the
/// next resolve. A TWO-STEP clear-then-type (a delete commit, then a LATER,
/// separate insert commit) DOES collapse: the delete-only commit already
/// degenerates the region to empty (see condition 2 above), and the very
/// next `checkDocRegion` call — before the later insert can even happen —
/// sees `start >= end` and traps. **Practical consequence**: agent tooling
/// that wants to rewrite a granted region's content should emit it as ONE
/// replace (delete+insert in a single `edit` call), not a clear followed by
/// a separate type — the former is the intended, edit-stable idiom this
/// limit supports; the latter is an honest, by-design trap, not a bug.
pub const DocRegion = struct {
    doc_id: []const u8,
    start: EventAnchor,
    end: EventAnchor,
};

/// The graph-doc analog of `DocRegion` (W6 slice 2, doc/substrate.md):
/// identity-anchored, not position-anchored, EXACTLY like the text form —
/// doc/substrate.md §5's "on graph docs, limits key on `ObjId` subtrees and are exact."
/// `root` is a portable `graph.zig#GraphDoc.NodeRef`, never a raw `ObjId`
/// (see that type's own doc comment for why a doc-local handle can't be
/// stored in a row meant to outlive one merge). `doc_id` mirrors
/// `DocRegion.doc_id` exactly: which `GraphDoc` this narrows, since a grant
/// table is scoped wider than one doc — today's minter (`GraphCollab`) uses
/// the doc's own quad name, same convention `DocRegion`'s minter uses the
/// buffer's name for.
///
/// **ENFORCEMENT lives at `session/GraphCollab.zig`'s `admitRegions`**
/// (W6 slice 2), not here — same split `.doc_region` already has with
/// `command.Context.checkDocRegion`: this table has no LIVE `GraphDoc` to
/// resolve a `NodeRef`/walk containment against, only the driver that owns
/// one does. **Collapse policy**, stated once and reused verbatim (not a
/// new `Reason`): if `root` no longer resolves, OR resolves but is no
/// longer `GraphDoc.reachable` (deleted/trashed — the walk-down analog of a
/// text anchor collapsing to its deletion point), the grant is COLLAPSED —
/// `.collapsed`, the SAME reason `.doc_region` already carries in this
/// file's `Reason` enum below, never silently widened to unrestricted or
/// narrowed to deny-everything (§2.4: "never silently widen or narrow").
///
/// **Union-of-grants confinement, DECIDED (§6 W6, mirrors `weft.grant`'s
/// composition rule)**: once a principal holds ANY live `.graph_subtree` row
/// for a doc, every edit from that principal on that doc must fall within
/// the UNION of all its live granted subtrees (each row narrows; rows don't
/// stack into anything wider than their union — the same "config REPLACES
/// the baseline" shape `weft.grant` already commits to for `.fs_root`,
/// read honestly for a per-peer authority table instead of a per-plugin
/// capability table). A principal with ZERO rows for a doc is UNAFFECTED —
/// today's per-doc `canEdit` governs, unchanged; grants NARROW, they never
/// default-deny the whole world.
pub const GraphSubtree = struct {
    doc_id: []const u8,
    root: graph.NodeRef,
};

/// A limit narrowing a grant (doc/contextual-workspace-architecture.md
/// §13.5). `.none` = unrestricted within the capability; `.fs_root` =
/// confined to a subtree; `.doc_region` = confined to an identity-anchored
/// text span (`DocRegion`'s doc — §6 W4 slice 3, review B2's repair);
/// `.graph_subtree` = confined to an identity-anchored graph subtree
/// (`GraphSubtree`'s doc — §6 W6). A tagged union, not a bare string, so a
/// future limit kind (a net host) is a new variant, never a stringly-typed
/// convention.
pub const Limit = union(enum) {
    none,
    fs_root: []const u8,
    doc_region: DocRegion,
    graph_subtree: GraphSubtree,
};

/// A declared grant: what a principal MAY hold for `capability`, gated by
/// `predicate` over the merged `Facts` a `Ctx` captures, narrowed by
/// `limit`. `predicate` defaults to "always matches" (`.all` over zero
/// children — `Predicate.matches`'s vacuous-truth case) because every
/// PRODUCTION decl today is the plugin-lifetime baseline (§2.4's
/// "manifest-static baseline... what the approval diff shows"): a loaded
/// plugin's fs grant holds everywhere it dispatches, not just in some fact
/// subset. A predicate-scoped decl (§2.4's identity-anchored doc limits, a
/// later slice) sets this explicitly.
pub const GrantDecl = struct {
    capability: []const u8,
    predicate: Predicate = .{ .all = &.{} },
    limit: Limit = .none,
};

/// Sentinel: no row (a handle that was never minted, or was defaulted).
const none_idx: u32 = std.math.maxInt(u32);

/// An index+generation into a `HandleTable` — the revocation point (§2.4).
/// Cheap POD: copy it anywhere (a plugin's own `grant_handles` array, a
/// `Ctx.grants` list) without touching the table. `check`ing a stale copy
/// against an invalidated row (`gen` bumped, `alive` cleared) fails —
/// exactly the "use = possession, revocation = invalidation" contract.
pub const CapHandle = struct {
    idx: u32 = none_idx,
    gen: u32 = 0,

    pub const none: CapHandle = .{};

    pub fn isNone(self: CapHandle) bool {
        return self.idx == none_idx;
    }
};

/// One granted row. `principal`/`capability` are BORROWED (the caller — the
/// plugin's own `name`, a `Perm.label()` — owns the backing memory for at
/// least the table's lifetime; every current caller passes `'static`-for-
/// practical-purposes strings: a plugin's `name` field, a perm-enum literal
/// label). `scope`, `null` for a plugin-lifetime row, names the owning scope
/// token a `sweepScope` call invalidates by (see the module doc).
pub const Row = struct {
    principal: []const u8,
    capability: []const u8,
    predicate: Predicate,
    limit: Limit,
    gen: u32 = 0,
    alive: bool = true,
    scope: ?u64 = null,
    /// Set by `sweepScope` (never by `revoke`) — the #8 distinction between
    /// "the scope this grant lived in exited" and "someone explicitly
    /// revoked it": both invalidate the row identically for `check`, but
    /// `reasonFor` reads this to tell the two apart in a trap message.
    scope_dead: bool = false,
};

/// Why a handle fails `check` — the trap-message distinction §6 W4 asks for
/// ("revoked" vs "never requested"), and the shared vocabulary #8's
/// structured deny-trap taxonomy names throughout the membrane. NOT every
/// variant is produced by `reasonFor` below (which only ever inspects TABLE
/// state — aliveness/gen — so it returns `.ok`/`.never_granted`/`.revoked`/
/// `.scope_expired`, never `.out_of_limit`/`.collapsed`): `.out_of_limit` is
/// carried here purely so every deny-reason in the membrane has ONE enum to
/// name itself with, even though it's decided by `wasm_host/fs.zig`'s limit
/// check (it needs the checked PATH, which a bare `CapHandle` doesn't carry)
/// rather than by this table. `.collapsed` (§6 W4 slice 3, review B2's
/// repair) is the SAME kind of guest: decided by
/// `command.Context.checkDocRegion` (it needs to resolve the row's
/// `.doc_region` anchors against the live `Document`, which this table has
/// no access to), not by this table's own aliveness/gen state — a
/// `.doc_region` grant's Row stays perfectly ALIVE in this table even after
/// its anchors collapse; the collapse is a property of the DOCUMENT, not the
/// row. `requireDispatch`'s background-entry denial
/// (`wasm_host/plugin.zig`'s `trapNotDispatching`) is its own reason too,
/// but is deliberately NOT added here: it isn't a grant-table state at all
/// (`in_dispatch`/`loading`, unrelated to any `Row`) — folding it into this
/// enum would be table vocabulary standing in for a check that never
/// touches the table. Its trap message stays free text; what unifies it
/// with everything else here is that EVERY deny in this file (and
/// `wasm_host/plugin.zig`'s `trapPermDenied`/`trapNotDispatching`/
/// `trapOutOfLimit`, `wasm_host/edit.zig`'s doc-region trap) is HOST-raised
/// via `Caller.trap()`, which wasmtime's C API surfaces as a structurally
/// distinct channel from a guest's own native fault — see `wasm.zig`'s
/// module doc for the mechanics; no enum needed to carry that distinction,
/// the wasmtime channel already does.
/// `.dead_epoch`/`.out_of_ops` are the per-export additions (§13.5): decided
/// by `ExportBook.check`, the peer-authority table below, and never by
/// `reasonFor` — the same "one enum names every deny in the membrane, even
/// the ones this table doesn't decide" rule `.out_of_limit`/`.collapsed`
/// already ride on.
pub const Reason = enum { ok, never_granted, revoked, scope_expired, out_of_limit, collapsed, out_of_ops, dead_epoch };

/// The System-owned grant table (§2.4's "resolves the principal's
/// GrantDecls" mechanism; see `System.zig`'s `grants` field). Append-only:
/// rows are never removed or reordered, so a `CapHandle.idx` stays valid to
/// look up for the table's whole lifetime — only `alive`/`gen` change. Rows
/// live in a plain `ArrayList` (not individually heap-allocated): nothing
/// outside this file ever holds a raw `*Row`, only `CapHandle`s, so an
/// internal reallocation on grant/append never invalidates anything a
/// caller holds.
pub const HandleTable = struct {
    gpa: Allocator,
    rows: std.ArrayList(Row) = .empty,
    next_scope: u64 = 1,

    pub fn init(gpa: Allocator) HandleTable {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *HandleTable) void {
        self.rows.deinit(self.gpa);
        self.* = undefined;
    }

    /// Mint a new row for `principal`/`decl`, optionally scoped. This is the
    /// ONLY way a row is created — there is no "re-grant the same slot"; a
    /// second `grant` for the same (principal, capability) is a SEPARATE
    /// row (harmless: `hasPerm`'s possession check holds whichever handle
    /// it was given; `revoke` invalidates every matching row, not just one).
    pub fn grant(self: *HandleTable, decl: GrantDecl, principal: []const u8, scope: ?u64) !CapHandle {
        const idx: u32 = @intCast(self.rows.items.len);
        try self.rows.append(self.gpa, .{
            .principal = principal,
            .capability = decl.capability,
            .predicate = decl.predicate,
            .limit = decl.limit,
            .scope = scope,
        });
        return .{ .idx = idx, .gen = 0 };
    }

    /// The possession check (§2.4 "use = possession"): is `h` a live row?
    /// O(1), no allocation, no principal/predicate re-evaluation — a
    /// possessed handle is checked, not re-resolved.
    pub fn check(self: *const HandleTable, h: CapHandle) bool {
        if (h.isNone() or h.idx >= self.rows.items.len) return false;
        const r = self.rows.items[h.idx];
        return r.alive and r.gen == h.gen;
    }

    /// Why `h` fails `check` (or `.ok` if it wouldn't) — the trap-message
    /// distinction (§6 W4 gate: "distinct from never-granted"), now also
    /// distinguishing `.scope_expired` (task #8: "the scope_expired variant
    /// belongs with #8") from a plain `.revoked` — see `Row.scope_dead`'s
    /// doc. A `gen` mismatch on an otherwise-alive-looking row (can't
    /// happen today — `alive` and `gen` always flip together — but `gen` is
    /// still checked first, matching `check`'s own order) falls back to
    /// `.revoked`: whichever invalidation flipped `gen` didn't tag
    /// `scope_dead`, so it wasn't `sweepScope`.
    pub fn reasonFor(self: *const HandleTable, h: CapHandle) Reason {
        if (h.isNone() or h.idx >= self.rows.items.len) return .never_granted;
        const r = self.rows.items[h.idx];
        if (r.alive and r.gen == h.gen) return .ok;
        return if (r.scope_dead) .scope_expired else .revoked;
    }

    /// The `.fs_root` limit's read side (task #8 / W4 slice 2): `h`'s row's
    /// `Limit`, or `.none` for an invalid handle — a caller that wants to
    /// ENFORCE the limit has already gone through `check`/`reasonFor` for
    /// possession; this only ever reads the row, never re-derives
    /// possession itself. See `wasm_host/plugin.zig`'s `limitFor` for the
    /// duck-typed wrapper both transports call through.
    pub fn limitFor(self: *const HandleTable, h: CapHandle) Limit {
        if (h.isNone() or h.idx >= self.rows.items.len) return .none;
        return self.rows.items[h.idx].limit;
    }

    /// The composition rule's read side (doc/contextual-workspace-architecture.md §13.5:
    /// "a config-authored `weft.grant` NARROWS/REPLACES the describe()-boolean
    /// baseline for that exact (principal, capability) pair"). Returns the
    /// first LIVE row's handle for `(principal, capability)`, or `null` if
    /// none exists yet. `wasm_host/plugin.zig`'s `mintGrantHandles` calls this
    /// BEFORE minting a boolean-derived row — a config-authored row (staged by
    /// `manifest.zig`'s `applyGrants`/`reconcileGrants`, which mints strictly
    /// BEFORE a plugin's `describe()` handshake runs) is found here and reused
    /// as-is instead of leaving it orphaned alongside a second, unrestricted
    /// row for the same pair. O(n) linear scan — same cost class as `revoke`,
    /// called at most once per DECLARED perm per plugin LOAD, never a hot
    /// path.
    pub fn findLive(self: *const HandleTable, principal: []const u8, capability: []const u8) ?CapHandle {
        for (self.rows.items, 0..) |r, i| {
            if (r.alive and std.mem.eql(u8, r.principal, principal) and std.mem.eql(u8, r.capability, capability))
                return .{ .idx = @intCast(i), .gen = r.gen };
        }
        return null;
    }

    /// Invalidate every LIVE row for (principal, capability) — the
    /// revocation point. Bumps `gen` in addition to clearing `alive`
    /// (belt-and-suspenders: rows are never reused in v1, so `alive` alone
    /// already suffices, but a future slot-reuse scheme can't accidentally
    /// re-validate a stale handle whose `gen` this already moved past).
    /// Returns how many rows were invalidated (0 = no match: a typo'd name,
    /// an already-revoked capability, or a principal that never held it).
    pub fn revoke(self: *HandleTable, principal: []const u8, capability: []const u8) usize {
        var n: usize = 0;
        for (self.rows.items) |*r| {
            if (r.alive and std.mem.eql(u8, r.principal, principal) and std.mem.eql(u8, r.capability, capability)) {
                r.alive = false;
                r.gen +%= 1;
                n += 1;
            }
        }
        return n;
    }

    /// Mint a fresh scope token (monotonic, never reused within one table's
    /// lifetime) for a caller that wants to bind a grant's lifetime to
    /// something other than "the plugin's whole load-to-unload span" — see
    /// `ctx.zig`'s scope-lifetime test for the worked example.
    pub fn newScope(self: *HandleTable) u64 {
        defer self.next_scope += 1;
        return self.next_scope;
    }

    /// The scope-exit sweep (§2.4: "scope exit revokes; a stashed handle
    /// from a dead Ctx traps"). Invalidates every LIVE row tagged with
    /// `scope`. Returns the count invalidated (0 is ordinary: most scopes
    /// never had a grant bound to them).
    pub fn sweepScope(self: *HandleTable, scope: u64) usize {
        var n: usize = 0;
        for (self.rows.items) |*r| {
            if (r.alive and r.scope != null and r.scope.? == scope) {
                r.alive = false;
                r.gen +%= 1;
                r.scope_dead = true; // #8: distinct from an explicit `revoke`
                n += 1;
            }
        }
        return n;
    }

    /// CAPTURE-TIME resolution (§2.4's powerbox, the no-wallet rule): collect
    /// every LIVE row belonging to `principal` whose predicate holds against
    /// `facts`, appending each as a `CapHandle` into `out`. Zero allocation —
    /// this only ever READS `self.rows` (never grown/shrunk by a capture) and
    /// writes into the caller-owned `out`, which must expose an `append(CapHandle)
    /// void`-ish method (`ctx.zig`'s bounded `GrantList`, or a test double).
    /// `out` never sees the rows it DOESN'T match — there is no wallet to
    /// choose from, only what capture resolved.
    pub fn collectForPrincipal(self: *const HandleTable, principal: []const u8, facts: Facts, out: anytype) void {
        for (self.rows.items, 0..) |r, i| {
            if (!r.alive) continue;
            if (!std.mem.eql(u8, r.principal, principal)) continue;
            if (!r.predicate.matches(facts)) continue;
            out.append(.{ .idx = @as(u32, @intCast(i)), .gen = r.gen });
        }
    }
};

// ── Per-export grants (§13.5) ────────────────────────────────────────
//
// The SECOND table in this file, and deliberately not a widening of
// `HandleTable`. `HandleTable` answers "does this local PRINCIPAL (a
// plugin) possess this capability" — possession, minted at load, checked by
// handle. `ExportBook` answers "may this authenticated PEER perform this
// operation on this publication's export, at this epoch" — authority,
// minted per share, checked by identity. Same vocabulary (designation
// scopes, revocation by invalidation, one `Reason`), different question and
// different key, so they are siblings rather than one table with a mode
// flag. The designation types (`DocRegion`/`GraphSubtree`) ARE shared
// verbatim: a designation means one thing in this codebase.
//
// Grades (`view` < `edit` < `own`) survive only as PRESETS and MAXIMA
// (§13.5: "connection-level roles may exist as user-facing presets or
// maxima"). The grade → op-set bundle mapping lives with the grade enum
// itself (`session/Session.zig`'s `Access.ops`), not here — this file has no
// opinion about the legacy wire byte.

/// A publication's identity (§13.2): the resource's stable id plus the epoch
/// it is live at. Unpublishing advances the epoch, which invalidates every
/// grant minted against the old one WITHOUT touching a single row — the
/// bulk-revocation primitive §13.2 asks for ("unpublishing revokes its
/// exports, advances the epoch, and invalidates translated references").
/// `epoch = 0` is the never-published sentinel.
pub const PublicationRef = struct {
    id: u64,
    epoch: u64 = 0,

    pub fn eql(a: PublicationRef, b: PublicationRef) bool {
        return a.id == b.id and a.epoch == b.epoch;
    }
};

/// The export surface an `Op` belongs to (§13.2's `Export` variants, plus
/// the administrative surface the `own` preset stands for). Derived from an
/// `Op`, never stored beside one.
pub const Surface = enum { replica, presence, endpoint, admin };

/// One exported operation: the export SURFACE and the operation on it, fused
/// into a single name. Deliberately NOT modelled as a stored `{surface,
/// op_set}` pair — a surface recorded next to an op-set is two sources of
/// truth for one fact, and the pair that drifts apart is exactly the silent
/// widening §2.4 forbids. The surface is derived (`Op.surface`).
pub const Op = enum(u4) {
    /// Receive the replica's events (read the shared document).
    replica_read = 0,
    /// Author events the owner will admit into the shared replica.
    replica_write = 1,
    presence_read = 2,
    presence_publish = 3,
    endpoint_query = 4,
    endpoint_mutate = 5,
    /// Administrative authority over the publication (re-grant, unpublish).
    admin = 6,

    pub fn surface(self: Op) Surface {
        return switch (self) {
            .replica_read, .replica_write => .replica,
            .presence_read, .presence_publish => .presence,
            .endpoint_query, .endpoint_mutate => .endpoint,
            .admin => .admin,
        };
    }
};

/// A set of `Op`s — the op-set half of an export grant. A plain bitmask so
/// it copies freely, intersects in one instruction (the §13.5 authority
/// intersection is `a.intersect(b)`), and rides the wire as one uvarint.
pub const OpSet = struct {
    bits: u16 = 0,

    pub const empty: OpSet = .{};

    pub fn of(ops: []const Op) OpSet {
        var s: OpSet = .{};
        for (ops) |op| s = s.with(op);
        return s;
    }

    pub fn with(self: OpSet, op: Op) OpSet {
        return .{ .bits = self.bits | bit(op) };
    }

    pub fn has(self: OpSet, op: Op) bool {
        return self.bits & bit(op) != 0;
    }

    pub fn intersect(a: OpSet, b: OpSet) OpSet {
        return .{ .bits = a.bits & b.bits };
    }

    pub fn unite(a: OpSet, b: OpSet) OpSet {
        return .{ .bits = a.bits | b.bits };
    }

    pub fn isEmpty(self: OpSet) bool {
        return self.bits == 0;
    }

    fn bit(op: Op) u16 {
        return @as(u16, 1) << @intFromEnum(op);
    }
};

/// How long a grant lives. `until_disconnect` is swept when the grantee's
/// session dies (`ExportBook.sweepDisconnect`); `until_revoked` outlives a
/// reconnect and dies only by explicit revoke or an epoch advance.
///
/// §13.6's other two offered lifetimes are deliberately NOT variants here:
/// "once" is the approving interaction revoking after the invocation it
/// approved, and "persist for a verified participant" is a stored descriptor
/// re-minted at connect — both are POLICY over these two mechanisms, and
/// neither has a caller yet. A variant with no enforcement would be a
/// lifetime that lies.
pub const Lifetime = enum(u8) { until_revoked = 0, until_disconnect = 1 };

/// A grant's target scope (§13.5: "may be a designation"). `.whole` = the
/// entire published resource; the designation forms reuse `DocRegion` and
/// `GraphSubtree` verbatim, with their collapse-and-trap policies unchanged.
///
/// **Where a designation scope is ENFORCED**: at its own existing chokepoint
/// (`command.Context.checkDocRegion` for text, `GraphCollab.admitRegions`
/// for graph) — not at `ExportBook.check`, which sees an opaque event batch
/// and no live document. This book answers the op/epoch/identity question;
/// the designation narrows further downstream. Effective authority is the
/// intersection, so carrying the scope here (and ANNOUNCING it) is what lets
/// a grantee preflight against it before minting.
///
/// Borrow convention, same as `Row.principal`: the anchors' `agent` bytes
/// and a subtree's `root.token` are BORROWED — the minter keeps them alive
/// for the row's lifetime.
pub const ExportScope = union(enum) {
    whole,
    doc_region: DocRegion,
    graph_subtree: GraphSubtree,
};

/// One minted export grant (§13.5's `Grant`). `grantee` is the peer's
/// AUTHENTICATED fingerprint — never a self-declared name, the same
/// discipline `GraphCollab.grantSubtree` documents at length: the owner
/// trusts the authenticated participant, and a name nobody authenticates is
/// an authority hole a grantee sheds its confinement by renaming through.
pub const ExportGrant = struct {
    grantee: [24]u8,
    publication: PublicationRef,
    ops: OpSet,
    scope: ExportScope = .whole,
    lifetime: Lifetime = .until_revoked,
};

/// Names one row in an `ExportBook` — index + generation, exactly like
/// `CapHandle`, so revocation stays table invalidation and a stale handle
/// simply stops resolving.
pub const ExportHandle = struct {
    idx: u32 = std.math.maxInt(u32),
    gen: u32 = 0,

    pub const none: ExportHandle = .{};

    pub fn isNone(self: ExportHandle) bool {
        return self.idx == std.math.maxInt(u32);
    }
};

/// The owner-side authority table for one link's peer: which publications
/// are live at which epoch, and which exports their peer holds on them.
///
/// **Fail-closed by construction.** `check` never returns `.ok` by accident:
/// an unknown publication, an unattributable sender, a stale epoch, and a
/// missing row are four DISTINCT denials, and §13.5's "missing or malformed
/// grant state never means unrestricted" is why none of them fall through to
/// a permissive default. The one permissive case lives OUTSIDE this table,
/// at `Session.authorize`: a publication this book has never heard of is not
/// this book's to decide, so the connection grade governs it exactly as it
/// did before per-export grants existed.
pub const ExportBook = struct {
    gpa: Allocator,
    rows: std.ArrayList(ExportRow) = .empty,
    /// Live epoch per publication id. An id stays here forever once
    /// published — `unpublish` advances its epoch rather than forgetting it,
    /// so authority can never fall back OPEN by losing track of a
    /// publication it was confining.
    pubs: std.AutoHashMapUnmanaged(u64, u64) = .empty,
    /// Bumped by every mint, revoke, sweep, and epoch change — the
    /// announce side's "does the grantee still know what it holds" check
    /// (`Collab.push` re-announces when this moves).
    rev: u64 = 0,

    pub const ExportRow = struct {
        grant: ExportGrant,
        gen: u32 = 0,
        alive: bool = true,
    };

    pub const MintError = error{ NotPublished, DeadEpoch, OutOfMemory };

    pub fn init(gpa: Allocator) ExportBook {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *ExportBook) void {
        self.rows.deinit(self.gpa);
        self.pubs.deinit(self.gpa);
        self.* = undefined;
    }

    /// Publish `id` (idempotent): mints epoch 1 on first call, otherwise
    /// returns the live ref unchanged. Re-publishing after an `unpublish`
    /// returns the ADVANCED epoch — grants minted against the old one stay
    /// dead, which is the whole point of advancing it.
    pub fn publish(self: *ExportBook, id: u64) !PublicationRef {
        const gop = try self.pubs.getOrPut(self.gpa, id);
        if (!gop.found_existing) {
            gop.value_ptr.* = 1;
            self.rev += 1;
        }
        return .{ .id = id, .epoch = gop.value_ptr.* };
    }

    /// §13.2's unpublish: advance the epoch. Every grant minted at the old
    /// epoch stops checking, and every reference carrying it now refuses
    /// with `.dead_epoch` — no row walk, no window where a stale reference
    /// is still honoured. The id is KEPT (with its new epoch), never
    /// forgotten: a forgotten publication would read as "not mine to
    /// decide" and fall back to the connection grade, silently widening
    /// exactly when authority was meant to end.
    pub fn unpublish(self: *ExportBook, id: u64) !void {
        const gop = try self.pubs.getOrPut(self.gpa, id);
        gop.value_ptr.* = if (gop.found_existing) gop.value_ptr.* + 1 else 1;
        self.rev += 1;
    }

    pub fn knows(self: *const ExportBook, id: u64) bool {
        return self.pubs.contains(id);
    }

    pub fn liveEpoch(self: *const ExportBook, id: u64) ?u64 {
        return self.pubs.get(id);
    }

    /// Mint one grant. PREFLIGHT BEFORE MINTING (doc/substrate.md §5, read
    /// for the owner side): a grant against an unpublished resource or a
    /// dead epoch is refused HERE rather than minted and denied later — a
    /// row that can never check true is not a grant, it is a lie the UI
    /// would render as authority.
    pub fn grant(self: *ExportBook, g: ExportGrant) MintError!ExportHandle {
        const live = self.pubs.get(g.publication.id) orelse return error.NotPublished;
        if (g.publication.epoch != live) return error.DeadEpoch;
        const idx: u32 = @intCast(self.rows.items.len);
        try self.rows.append(self.gpa, .{ .grant = g });
        self.rev += 1;
        return .{ .idx = idx, .gen = 0 };
    }

    /// Revoke exactly one row. `false` if the handle is stale or already
    /// dead (an idempotent revoke, not an error).
    pub fn revoke(self: *ExportBook, h: ExportHandle) bool {
        if (h.isNone() or h.idx >= self.rows.items.len) return false;
        const r = &self.rows.items[h.idx];
        if (!r.alive or r.gen != h.gen) return false;
        r.alive = false;
        r.gen +%= 1;
        self.rev += 1;
        return true;
    }

    /// `setPeerAccess`'s per-export sibling: revoke every live export
    /// `grantee` holds on `id`. Returns how many died.
    pub fn revokePeer(self: *ExportBook, grantee: [24]u8, id: u64) usize {
        var n: usize = 0;
        for (self.rows.items) |*r| {
            if (!r.alive) continue;
            if (r.grant.publication.id != id) continue;
            if (!std.mem.eql(u8, &r.grant.grantee, &grantee)) continue;
            r.alive = false;
            r.gen +%= 1;
            n += 1;
        }
        if (n > 0) self.rev += 1;
        return n;
    }

    /// Sweep `grantee`'s `.until_disconnect` grants (their session died).
    pub fn sweepDisconnect(self: *ExportBook, grantee: [24]u8) usize {
        var n: usize = 0;
        for (self.rows.items) |*r| {
            if (!r.alive or r.grant.lifetime != .until_disconnect) continue;
            if (!std.mem.eql(u8, &r.grant.grantee, &grantee)) continue;
            r.alive = false;
            r.gen +%= 1;
            n += 1;
        }
        if (n > 0) self.rev += 1;
        return n;
    }

    /// THE decision: may `grantee` perform `op` on `pub_ref`? Every denial
    /// is a distinct reason — `.dead_epoch` for a reference or a row that
    /// outlived its publication's epoch, `.out_of_ops` for a peer that holds
    /// this publication but not this operation, `.never_granted` for one
    /// that holds nothing here at all.
    pub fn check(self: *const ExportBook, grantee: [24]u8, pub_ref: PublicationRef, op: Op) Reason {
        const live = self.pubs.get(pub_ref.id) orelse return .never_granted;
        if (pub_ref.epoch != live) return .dead_epoch;
        var saw_stale = false;
        var saw_row = false;
        for (self.rows.items) |r| {
            if (!r.alive) continue;
            if (r.grant.publication.id != pub_ref.id) continue;
            if (!std.mem.eql(u8, &r.grant.grantee, &grantee)) continue;
            if (r.grant.publication.epoch != live) {
                saw_stale = true;
                continue;
            }
            saw_row = true;
            if (r.grant.ops.has(op)) return .ok;
        }
        if (saw_row) return .out_of_ops;
        return if (saw_stale) .dead_epoch else .never_granted;
    }

    /// The announce side's read: append every live grant `grantee` holds on
    /// `id` at the live epoch into `out`. What is announced and what is
    /// enforced therefore come from the same walk and cannot disagree.
    pub fn collect(self: *const ExportBook, grantee: [24]u8, id: u64, out: *std.ArrayList(ExportGrant)) !void {
        const live = self.pubs.get(id) orelse return;
        for (self.rows.items) |r| {
            if (!r.alive) continue;
            if (r.grant.publication.id != id or r.grant.publication.epoch != live) continue;
            if (!std.mem.eql(u8, &r.grant.grantee, &grantee)) continue;
            try out.append(self.gpa, r.grant);
        }
    }
};

// ── Tests ───────────────────────────────────────────────────────────

const t = std.testing;

test "grants: grant/check/revoke — the possession + invalidation contract" {
    const gpa = t.allocator;
    var table = HandleTable.init(gpa);
    defer table.deinit();

    const h = try table.grant(.{ .capability = "fs_read" }, "notes", null);
    try t.expect(table.check(h));
    try t.expectEqual(Reason.ok, table.reasonFor(h));

    // A handle that was never minted (CapHandle.none) is never-granted, not
    // revoked — the message-distinction gate.
    try t.expectEqual(Reason.never_granted, table.reasonFor(.none));

    const n = table.revoke("notes", "fs_read");
    try t.expectEqual(@as(usize, 1), n);
    try t.expect(!table.check(h));
    try t.expectEqual(Reason.revoked, table.reasonFor(h));

    // Revoking again — nothing left to invalidate.
    try t.expectEqual(@as(usize, 0), table.revoke("notes", "fs_read"));

    // A DIFFERENT principal's identically-named capability is untouched.
    const h2 = try table.grant(.{ .capability = "fs_read" }, "vim", null);
    try t.expect(table.check(h2));
}

test "grants: revoke narrows to the exact (principal, capability) pair" {
    const gpa = t.allocator;
    var table = HandleTable.init(gpa);
    defer table.deinit();

    const read = try table.grant(.{ .capability = "fs_read" }, "notes", null);
    const write = try table.grant(.{ .capability = "fs_write" }, "notes", null);
    _ = table.revoke("notes", "fs_write");
    try t.expect(table.check(read)); // sibling capability unaffected
    try t.expect(!table.check(write));
}

test "grants: scope sweep invalidates only rows tagged with that scope" {
    const gpa = t.allocator;
    var table = HandleTable.init(gpa);
    defer table.deinit();

    const plugin_lifetime = try table.grant(.{ .capability = "fs_read" }, "notes", null);
    const scope = table.newScope();
    const transient = try table.grant(.{ .capability = "doc.edit" }, "notes", scope);

    try t.expect(table.check(plugin_lifetime));
    try t.expect(table.check(transient));

    const n = table.sweepScope(scope);
    try t.expectEqual(@as(usize, 1), n);
    try t.expect(table.check(plugin_lifetime)); // plugin-lifetime row untouched
    try t.expect(!table.check(transient)); // scoped row died with its scope

    // Sweeping an already-swept (or unused) scope is a harmless no-op.
    try t.expectEqual(@as(usize, 0), table.sweepScope(scope));
}

test "grants: scope_expired is distinct from revoked (task #8's taxonomy)" {
    const gpa = t.allocator;
    var table = HandleTable.init(gpa);
    defer table.deinit();

    const scope = table.newScope();
    const scoped = try table.grant(.{ .capability = "doc.edit" }, "notes", scope);
    const explicit = try table.grant(.{ .capability = "fs_read" }, "notes", null);

    _ = table.sweepScope(scope);
    _ = table.revoke("notes", "fs_read");

    // Same observable possession outcome (neither checks true)...
    try t.expect(!table.check(scoped));
    try t.expect(!table.check(explicit));
    // ...but a DIFFERENT reason: the scope dying is not the same event as a
    // deliberate revoke, and a trap message should say which happened.
    try t.expectEqual(Reason.scope_expired, table.reasonFor(scoped));
    try t.expectEqual(Reason.revoked, table.reasonFor(explicit));
}

test "grants: limitFor reads a row's Limit; .none for an invalid handle" {
    const gpa = t.allocator;
    var table = HandleTable.init(gpa);
    defer table.deinit();

    const unrestricted = try table.grant(.{ .capability = "fs_read" }, "notes", null);
    const limited = try table.grant(.{ .capability = "fs_read", .limit = .{ .fs_root = "notes-vault" } }, "agent", null);

    try t.expectEqual(Limit.none, table.limitFor(unrestricted));
    switch (table.limitFor(limited)) {
        .fs_root => |root| try t.expectEqualStrings("notes-vault", root),
        .none, .doc_region, .graph_subtree => return error.TestUnexpectedResult,
    }
    try t.expectEqual(Limit.none, table.limitFor(.none)); // never-minted handle degrades safely
}

test "grants: .doc_region limit round-trips through the table (W4 slice 3)" {
    const gpa = t.allocator;
    var table = HandleTable.init(gpa);
    defer table.deinit();

    const start: EventAnchor = .{ .agent = "user", .seq = 2, .side = .after };
    const end: EventAnchor = .{ .agent = "user", .seq = 6, .side = .before };
    const limited = try table.grant(.{
        .capability = "doc.edit",
        .limit = .{ .doc_region = .{ .doc_id = "notes.txt", .start = start, .end = end } },
    }, "agent", null);

    switch (table.limitFor(limited)) {
        .doc_region => |dr| {
            try t.expectEqualStrings("notes.txt", dr.doc_id);
            try t.expectEqualStrings("user", dr.start.agent);
            try t.expectEqual(@as(u64, 2), dr.start.seq);
            try t.expectEqual(AnchorSide.after, dr.start.side);
            try t.expectEqual(AnchorSide.before, dr.end.side);
        },
        .none, .fs_root, .graph_subtree => return error.TestUnexpectedResult,
    }
}

test "grants: .graph_subtree limit round-trips through the table (W6 slice 2)" {
    const gpa = t.allocator;
    var table = HandleTable.init(gpa);
    defer table.deinit();

    const root: graph.NodeRef = .{ .token = "sto\x01\x05alice\x03" };
    const limited = try table.grant(.{
        .capability = "graph.edit",
        .limit = .{ .graph_subtree = .{ .doc_id = "notes-graph", .root = root } },
    }, "agent", null);

    switch (table.limitFor(limited)) {
        .graph_subtree => |gs| {
            try t.expectEqualStrings("notes-graph", gs.doc_id);
            try t.expect(gs.root.eql(root));
        },
        .none, .fs_root, .doc_region => return error.TestUnexpectedResult,
    }
}

test "grants: findLive — the composition rule's read side" {
    const gpa = t.allocator;
    var table = HandleTable.init(gpa);
    defer table.deinit();

    // Nothing minted yet: no live row to find.
    try t.expectEqual(@as(?CapHandle, null), table.findLive("git", "fs_write"));

    const h = try table.grant(.{ .capability = "fs_write", .limit = .{ .fs_root = "repo" } }, "git", null);
    const found = table.findLive("git", "fs_write").?;
    try t.expectEqual(h.idx, found.idx);
    try t.expectEqual(h.gen, found.gen);

    // A different capability, or a different principal, doesn't match.
    try t.expectEqual(@as(?CapHandle, null), table.findLive("git", "fs_read"));
    try t.expectEqual(@as(?CapHandle, null), table.findLive("vim", "fs_write"));

    // Revoked rows are DEAD, not found — `findLive` only ever sees possession.
    _ = table.revoke("git", "fs_write");
    try t.expectEqual(@as(?CapHandle, null), table.findLive("git", "fs_write"));
}

test "grants: collectForPrincipal — capture-time resolution, predicate-gated, no cross-principal leak" {
    const gpa = t.allocator;
    var table = HandleTable.init(gpa);
    defer table.deinit();

    _ = try table.grant(.{ .capability = "fs_read" }, "notes", null); // always matches
    _ = try table.grant(.{ .capability = "doc.edit", .predicate = .{ .mode = "insert" } }, "notes", null);
    _ = try table.grant(.{ .capability = "fs_read" }, "vim", null); // different principal

    const Out = struct {
        items: [8]CapHandle = undefined,
        len: usize = 0,
        pub fn append(self: *@This(), h: CapHandle) void {
            self.items[self.len] = h;
            self.len += 1;
        }
    };
    var out: Out = .{};
    table.collectForPrincipal("notes", .{ .mode = "normal" }, &out);
    try t.expectEqual(@as(usize, 1), out.len); // only the always-matching row — insert-mode one doesn't hold in "normal"

    out = .{};
    table.collectForPrincipal("notes", .{ .mode = "insert" }, &out);
    try t.expectEqual(@as(usize, 2), out.len); // both notes rows now match

    out = .{};
    table.collectForPrincipal("ghost", .{ .mode = "insert" }, &out);
    try t.expectEqual(@as(usize, 0), out.len); // no such principal — never leaks vim's or notes's rows
}

test {
    std.testing.refAllDecls(@This());
}

// ── ExportBook (§13.5's per-export grants) ──────────────────────────

const alice_fp: [24]u8 = @splat(0xa1);
const bob_fp: [24]u8 = @splat(0xb0);

test "export grants: authority is per SURFACE — a granted op admits, a sibling op on the same publication does not" {
    var book = ExportBook.init(t.allocator);
    defer book.deinit();

    const pubref = try book.publish(7);
    _ = try book.grant(.{
        .grantee = alice_fp,
        .publication = pubref,
        .ops = OpSet.of(&.{ .replica_read, .presence_read }),
    });

    // Granted surface + op: admitted.
    try t.expectEqual(Reason.ok, book.check(alice_fp, pubref, .replica_read));
    try t.expectEqual(Reason.ok, book.check(alice_fp, pubref, .presence_read));
    // The SAME surface, a different op — the whole point of per-export
    // grants over a grade: read does not imply write.
    try t.expectEqual(Reason.out_of_ops, book.check(alice_fp, pubref, .replica_write));
    // A surface never mentioned at all.
    try t.expectEqual(Reason.out_of_ops, book.check(alice_fp, pubref, .endpoint_mutate));
    try t.expectEqual(Reason.out_of_ops, book.check(alice_fp, pubref, .admin));
    // Another peer holds nothing here — distinct from holding the wrong op.
    try t.expectEqual(Reason.never_granted, book.check(bob_fp, pubref, .replica_read));

    // Widening is additive and independently revocable, not a re-grade.
    const write = try book.grant(.{
        .grantee = alice_fp,
        .publication = pubref,
        .ops = OpSet.of(&.{.replica_write}),
    });
    try t.expectEqual(Reason.ok, book.check(alice_fp, pubref, .replica_write));
    try t.expect(book.revoke(write));
    try t.expectEqual(Reason.out_of_ops, book.check(alice_fp, pubref, .replica_write));
    try t.expectEqual(Reason.ok, book.check(alice_fp, pubref, .replica_read)); // sibling row untouched
    try t.expect(!book.revoke(write)); // idempotent, never an error
}

test "export grants: unpublishing advances the epoch — every grant minted against the old one refuses with dead_epoch" {
    var book = ExportBook.init(t.allocator);
    defer book.deinit();

    const first = try book.publish(1);
    _ = try book.grant(.{ .grantee = alice_fp, .publication = first, .ops = OpSet.of(&.{.replica_write}) });
    try t.expectEqual(Reason.ok, book.check(alice_fp, first, .replica_write));

    try book.unpublish(1);
    // The reference the peer is holding is itself stale now.
    try t.expectEqual(Reason.dead_epoch, book.check(alice_fp, first, .replica_write));

    // And so is the row, checked against the LIVE reference: a dead grant is
    // never confused with "never granted", and never falls back to the
    // connection grade — the publication stays known precisely so it can't.
    const live = try book.publish(1);
    try t.expect(live.epoch != first.epoch);
    try t.expect(book.knows(1));
    try t.expectEqual(Reason.dead_epoch, book.check(alice_fp, live, .replica_write));

    // Minting against a dead epoch is refused AT THE MINT, not silently
    // recorded as a row that can never check true.
    try t.expectError(error.DeadEpoch, book.grant(.{
        .grantee = alice_fp,
        .publication = first,
        .ops = OpSet.of(&.{.replica_write}),
    }));
    try t.expectError(error.NotPublished, book.grant(.{
        .grantee = alice_fp,
        .publication = .{ .id = 99, .epoch = 1 },
        .ops = OpSet.of(&.{.replica_write}),
    }));

    // A fresh grant at the live epoch works again.
    _ = try book.grant(.{ .grantee = alice_fp, .publication = live, .ops = OpSet.of(&.{.replica_write}) });
    try t.expectEqual(Reason.ok, book.check(alice_fp, live, .replica_write));
}

test "export grants: revokePeer, disconnect sweep, and collect (announce reads the same rows enforcement does)" {
    var book = ExportBook.init(t.allocator);
    defer book.deinit();

    const p = try book.publish(3);
    _ = try book.grant(.{ .grantee = alice_fp, .publication = p, .ops = OpSet.of(&.{.replica_write}) });
    _ = try book.grant(.{
        .grantee = alice_fp,
        .publication = p,
        .ops = OpSet.of(&.{.presence_publish}),
        .lifetime = .until_disconnect,
    });
    _ = try book.grant(.{ .grantee = bob_fp, .publication = p, .ops = OpSet.of(&.{.replica_write}) });

    var out: std.ArrayList(ExportGrant) = .empty;
    defer out.deinit(t.allocator);
    try book.collect(alice_fp, 3, &out);
    try t.expectEqual(@as(usize, 2), out.items.len); // alice's rows only — never bob's

    // A dead session takes only the grants that said they'd die with it.
    try t.expectEqual(@as(usize, 1), book.sweepDisconnect(alice_fp));
    try t.expectEqual(Reason.out_of_ops, book.check(alice_fp, p, .presence_publish));
    try t.expectEqual(Reason.ok, book.check(alice_fp, p, .replica_write));

    // setPeerAccess's per-export sibling: everything this peer holds here.
    try t.expectEqual(@as(usize, 1), book.revokePeer(alice_fp, 3));
    try t.expectEqual(Reason.never_granted, book.check(alice_fp, p, .replica_write));
    try t.expectEqual(Reason.ok, book.check(bob_fp, p, .replica_write)); // the other peer is untouched
    try t.expectEqual(@as(usize, 0), book.revokePeer(alice_fp, 3));

    out.clearRetainingCapacity();
    try book.collect(alice_fp, 3, &out);
    try t.expectEqual(@as(usize, 0), out.items.len);
}

test "export grants: a designation scope rides the row verbatim — one designation type, not two" {
    var book = ExportBook.init(t.allocator);
    defer book.deinit();

    const p = try book.publish(5);
    const h = try book.grant(.{
        .grantee = alice_fp,
        .publication = p,
        .ops = OpSet.of(&.{ .replica_read, .replica_write }),
        .scope = .{ .doc_region = .{
            .doc_id = "parser.zig",
            .start = .{ .agent = "user", .seq = 2, .side = .after },
            .end = .{ .agent = "user", .seq = 9, .side = .before },
        } },
    });
    switch (book.rows.items[h.idx].grant.scope) {
        .doc_region => |dr| {
            try t.expectEqualStrings("parser.zig", dr.doc_id);
            try t.expectEqual(@as(u64, 9), dr.end.seq);
        },
        .whole, .graph_subtree => return error.TestUnexpectedResult,
    }
    // The op/epoch question is this table's; the designation narrows further
    // downstream, so a scoped grant still admits HERE.
    try t.expectEqual(Reason.ok, book.check(alice_fp, p, .replica_write));
}

test "export grants: OpSet is a set — union widens, intersection narrows, surfaces are derived" {
    const read_only = OpSet.of(&.{ .replica_read, .presence_read });
    const writer = read_only.with(.replica_write);
    try t.expect(writer.has(.replica_read));
    try t.expect(!read_only.has(.replica_write));
    try t.expectEqual(read_only.bits, read_only.intersect(writer).bits);
    try t.expectEqual(writer.bits, read_only.unite(writer).bits);
    try t.expect(OpSet.empty.isEmpty());
    try t.expectEqual(Surface.replica, Op.replica_write.surface());
    try t.expectEqual(Surface.presence, Op.presence_publish.surface());
    try t.expectEqual(Surface.admin, Op.admin.surface());
}
