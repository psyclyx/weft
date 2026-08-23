//! `graph.zig` — the weft-side facade over stemma's `ObjectDoc`: the graph
//! substrate named in doc/north-star-plan.md §2.6 ("the graph substrate,
//! projections, and the path to the inversion"). `GraphDoc` mirrors
//! `Document.zig`'s shape for the pieces that generalize across BOTH
//! substrates — one owning agent, one replica, `version`/`eventsSince`/
//! `merge`/`serialize` with ObjectDoc's own token model (identical to
//! `TextDoc`'s, per `ObjectDoc.zig`'s own doc comment) — WITHOUT forcing
//! `Document`'s peer/anchor/commit-log/backing machinery onto every graph
//! client prematurely. That machinery is real infrastructure `Document`
//! earns because EVERY text buffer needs peers + anchors + undo + save;
//! a graph doc's session/collab integration (spawned peers authoring as
//! themselves, a commit log for subscription) is its own ledgered piece of
//! work — stemma delta 5, "ObjectDoc session/share integration" — not this
//! slice (W5 slice 1: the facade + the first client, host-side, no wire).
//!
//! ## `NodeRef` — portable, deliberately NOT the plan's literal pseudocode
//!
//! §2.6 sketches `NodeRef = struct { doc: DocId, obj: ObjectDoc.ObjId }`.
//! Taken literally that's a landmine: `ObjId` is explicitly a DOC-LOCAL
//! handle — `ObjectDoc.zig`'s own doc comment says "ObjId values are
//! DOC-LOCAL handles (they embed replica-local agent numbering) — never
//! transport one to another replica", and `causal.AgentId`'s doc comment
//! confirms it: "NOT stable across replicas; cross-peer ordering uses the
//! name bytes." Embedding a raw `ObjId` in a value meant to travel (into a
//! subbuffer fact, across a `merge`, eventually onto a wire) would resolve
//! to the WRONG object on a different replica — silently, since the numeric
//! value is always "valid", just not for the object you meant.
//!
//! This facade instead backs `NodeRef` with `ObjectDoc.exportId`'s portable
//! token (`"sto\x01"` + agent name + seq) — the exact bytes ObjectDoc
//! already uses for its own cross-replica object references, resolved back
//! to a local `ObjId` via `importId`. `DocId` is elided for this slice:
//! every client built here (the transcript) is a single `ObjectDoc`, so
//! there is exactly one doc a token could mean — no ambiguity to carry a
//! discriminant for. Cross-doc refs are stemma delta 4 ("bless `exportId`
//! as NodeRef's wire form" — already true here); `NodeRef` gains a
//! doc-identifying field only when a client actually spans docs and needs
//! one token to disambiguate among several.
//!
//! ## F3 — why `seq*` exists and `list*` doesn't
//!
//! F3 (north-star-plan.md §5, VALIDATED) picks parent-register +
//! fractional-order-keys for STRUCTURAL children (a file tree, a staging
//! set) — anything that can be identity-preservingly MOVED between
//! parents — and reserves ObjectDoc's built-in list op for LEAF SEQUENCES
//! that never reparent (chat log lines, history entries). The facade
//! enforces this by NAMING, not by a runtime check it can't cheaply make:
//! `seqInsert`/`seqAppend`/`seqDelete` wrap `ObjectDoc.listInsert`/
//! `listDelete` and are the only sequence-mutating exports; there is no
//! `moveNode`/`reparent` here, and there never will be one built on top of
//! these — ObjectDoc's list has no such primitive to wrap (`listInsert`/
//! `mapSet` accept only FRESH `Value`s, never an existing `ObjId`, so an
//! object's parent slot is fixed at creation). A workaround of
//! delete-then-recreate would mint a NEW identity, which is exactly the
//! bug F3 forbids (identity-preserving move is the whole point). A client
//! that needs real reparenting structure waits for F3's parent-register
//! mechanism (stemma deltas 3/6, validated in
//! `lib/stemma/.../collab/structure_sketch.zig`, not yet wired into
//! `ObjectDoc` proper) — it does not reach for `seqInsert` as a stand-in.
//!
//! `graph.zig`'s first (and, for this slice, only) client — `transcript.
//! zig` — uses `seq*` for its entry list precisely because transcript
//! entries are the legitimate case: appended, read, edited in place, never
//! reparented (an entry never moves to a different transcript, and entries
//! never nest under one another). See `transcript.zig`'s doc comment for
//! that reasoning stated against the actual model, not just in the
//! abstract.
//!
//! ## The struct forest — exposed (W7b, doc/w7-rebase.md §4)
//!
//! The paragraph above was true at W5/W6 slice time — stemma's F3
//! parent-register mechanism lived only in the test-only
//! `structure_sketch.zig`, unreachable from `ObjectDoc` proper, so this
//! facade correctly exposed no move/reparent primitive at all. **stemma
//! v0.5.1 (pinned) ships it for real** — `ObjectDoc.structCreate`/
//! `structMove`/`structDelete`/`structParent`/`structChildren`/
//! `structCycleBroken` (delta 6) — and W7b's flagship (a function-level
//! subtree grant that survives a peer's MOVE of the function,
//! w7-rebase.md §2.2 point 1: "an anchor-pair CANNOT [survive a move];
//! ... only real on the graph substrate") needs exactly this. So it is
//! exposed below, straight through, as its own accessor group.
//!
//! This does NOT reopen the `seq*`/`list*` discipline above: those wrap
//! `ObjectDoc.listInsert`/`listDelete` and remain LEAF-SEQUENCE-only
//! (`ObjectDoc`'s list has no reparent primitive to wrap — nothing
//! changed there). The struct forest is a genuinely SEPARATE parent
//! relation stemma maintains (`struct_parents`, keyed by portable
//! `EventId`, parented at one of two SENTINELS — `.root`/`.trash` — or
//! another struct node — never at an ordinary map/list `ObjId`) —
//! disjoint from, and composable with, the map/list containment tree a
//! struct node's OWN fields still use ordinarily (a function's struct
//! node is a real map object: `set(gpa, func_node, "body", .text)` works
//! exactly like any other map). See `contains`/`reachable`'s section doc
//! comment below for exactly how the two relations compose for
//! containment and collapse.
//!
//! `parent`/`node` arguments below are raw LOCAL `ObjId`s — the SAME
//! idiom `set`'s `parent: ?ObjId` already uses for ordinary local
//! composition within one replica's own call sequence. A `NodeRef` is
//! minted only where a value must CROSS a boundary (a grant's `root`, a
//! subbuffer fact, a caller resuming work after a merge) — see
//! `NodeRef`'s own doc comment; this is not a new rule, just applied to
//! one more accessor group.
//!
//! ## `Projection`/`ReconcileMode` (§2.6) — named, `on_save` now built for
//! one real client
//!
//! §2.6 sketches a generic `Projection` (a `fill` + a `ReconcileMode` of
//! `on_save`/`live`/`authoritative`) meant to run over a captured `Ctx` and
//! a rendering `Viewport` — machinery from W2b/W3 this slice does not
//! plumb through. Building that generic UNION type now, with only ONE
//! real graph-doc client, would still be exactly the kind of premature
//! abstraction this plan elsewhere refuses (F1's "two substrates is
//! scaffolding with a demolition date", the container's "systems are
//! values" discipline preferring a real client over a speculative
//! interface) — so `ReconcileMode` itself stays unbuilt as a runtime
//! type. What DID change (W5 slice 3): `on_save` itself — one arm of that
//! sketched union — is now a real, concrete MECHANISM with two
//! independent instances proving its shape instead of one: dired's
//! (guest/wasm, `doc/editable-projection.md`, ordered rename/move/delete/
//! create file ops inferred from a path snapshot) and `transcript.zig`'s
//! (host/in-process, `reconcileOnSave`, a per-row text-CRDT diff
//! reconciled BY NODEREF — no snapshot needed, since each row's own
//! current model text IS its live snapshot). Both wire through the
//! IDENTICAL dispatch mechanism — the `save` ACTION scoped by tool
//! identity (`action.zig`'s `When{.tool=...}`) — which is the actual
//! answer to "what does declaring an authority mode mean, mechanically":
//! not a field on a `Projection` struct instance (no such struct is
//! instantiated at runtime for either client), but WHICH action provider
//! a tool-backed buffer's `save` resolves to. `transcript.zig`'s
//! `reconcileOnSave` doc comment has the full contract and the concurrent-
//! edit refusal/re-target rules; this file just anchors where the second
//! real case lives, since a THIRD client is what would finally justify
//! promoting `ReconcileMode` to an actual generic type here. `live`
//! remains exactly as undesigned as before (D1, north-star-plan.md §7.1);
//! `authoritative` remains unneeded by anything built.

const std = @import("std");
const Allocator = std.mem.Allocator;

const stemma = @import("stemma");
const ObjectDoc = stemma.ObjectDoc;

const GraphDoc = @This();

/// The `ObjectDoc` replica this facade wraps.
obj: ObjectDoc = .empty,
/// This replica's CRDT agent name (owned).
agent_name: []u8 = &.{},

pub const empty: GraphDoc = .{};

pub const Error = Allocator.Error;
pub const MergeError = ObjectDoc.MergeError;
pub const VersionOrder = ObjectDoc.VersionOrder;

// Re-exported so callers of the facade don't reach past it into `stemma`
// for the vocabulary its own signatures use.
pub const ObjId = ObjectDoc.ObjId;
pub const Value = ObjectDoc.Value;
pub const Kind = ObjectDoc.Kind;
pub const ValueRef = ObjectDoc.ValueRef;
pub const Change = ObjectDoc.Change;

/// A fresh, empty graph doc owned by `agent_name` — the origin replica of
/// a brand-new graph document (mirrors `Document.init`'s "the user peer
/// edits the authoritative replica directly" degenerate case).
pub fn init(gpa: Allocator, agent_name: []const u8) Error!GraphDoc {
    var obj: ObjectDoc = .empty;
    errdefer obj.deinit(gpa);
    try obj.setAgent(gpa, agent_name);
    const name = try gpa.dupe(u8, agent_name);
    return .{ .obj = obj, .agent_name = name };
}

/// A graph doc bootstrapped from another replica's full history (`bytes`
/// from `serialize`/`eventsSince`), then given a local agent identity —
/// the `Document.addPeer` pattern (clone the history, register as
/// yourself), not an independent `init`. Two independently-`init`ed
/// replicas of what's meant to be "the same" graph document have no
/// shared root object; only a doc that GENUINELY starts empty (this
/// slice's origin case) should call `init` — every joining participant
/// that already HOLDS bytes to bootstrap from calls `open`. The one
/// documented exception: `session/GraphCollab.zig`'s wire driver binds a
/// joiner to a virgin `init` shell and lets the frontier exchange fill it
/// in place (there is no single "bytes" value to hand `open` in that
/// path) — see that file's module doc comment for why `init`, not `open`,
/// is the correct bootstrap shell there.
pub fn open(gpa: Allocator, agent_name: []const u8, bytes: []const u8) MergeError!GraphDoc {
    var obj = try ObjectDoc.open(gpa, bytes);
    errdefer obj.deinit(gpa);
    try obj.setAgent(gpa, agent_name);
    const name = try gpa.dupe(u8, agent_name);
    return .{ .obj = obj, .agent_name = name };
}

pub fn deinit(self: *GraphDoc, gpa: Allocator) void {
    self.obj.deinit(gpa);
    gpa.free(self.agent_name);
    self.* = .{};
}

// ── Reads ───────────────────────────────────────────────────────────

/// The root map.
pub fn root(self: *const GraphDoc) ValueRef {
    return self.obj.root();
}

/// A navigable `ValueRef` for any `ObjId` this facade or its clients hold
/// (typically one handed back by `set`/`seqInsert`/`seqAppend`, or
/// resolved from a `NodeRef` via `resolve`) — see `ObjectDoc.ref`'s doc
/// comment for why this is needed at all (mutators return `ObjId`s with
/// no way back into `ValueRef` navigation except re-walking from `root`).
pub fn ref(self: *const GraphDoc, obj: ?ObjId) ValueRef {
    return self.obj.ref(obj);
}

// ── Typed accessors (F3-disciplined — see module doc comment) ────────

/// Set a field on a map object (`parent = null` is the root map).
/// Map keys are not a reorderable axis; F3 has no opinion here.
pub fn set(self: *GraphDoc, gpa: Allocator, parent: ?ObjId, key: []const u8, val: Value) Error!?ObjId {
    return self.obj.mapSet(gpa, parent, key, val);
}

pub fn unset(self: *GraphDoc, gpa: Allocator, parent: ?ObjId, key: []const u8) Error!void {
    return self.obj.mapDelete(gpa, parent, key);
}

/// Insert a LEAF into a sequence object at `index`. See the module doc
/// comment: legitimate only for sequences that never reparent.
pub fn seqInsert(self: *GraphDoc, gpa: Allocator, seq: ObjId, index: usize, val: Value) Error!?ObjId {
    return self.obj.listInsert(gpa, seq, index, val);
}

/// Insert a LEAF at the end of a sequence object.
pub fn seqAppend(self: *GraphDoc, gpa: Allocator, seq: ObjId, val: Value) Error!?ObjId {
    return self.obj.listInsert(gpa, seq, self.ref(seq).listLen(), val);
}

pub fn seqDelete(self: *GraphDoc, gpa: Allocator, seq: ObjId, index: usize) Error!void {
    return self.obj.listDelete(gpa, seq, index);
}

/// Edit a text object — a real sequence CRDT, collaboratively editable
/// exactly like a `Document`'s text (same FugueMax semantics).
pub fn textInsert(self: *GraphDoc, gpa: Allocator, text_obj: ObjId, byte_offset: usize, content: []const u8) Error!stemma.Edit {
    return self.obj.textInsert(gpa, text_obj, byte_offset, content);
}

pub fn textDelete(self: *GraphDoc, gpa: Allocator, text_obj: ObjId, range: stemma.Range) Error!stemma.Edit {
    return self.obj.textDelete(gpa, text_obj, range);
}

// ── The struct forest (W7b) — see the module doc comment's "The struct
// forest — exposed" section for why this exists now and how it differs
// from `seq*`/`list*` above. ────────────────────────────────────────────

/// Where a structural node's parent register can point: the two
/// permanent sentinels, or another structural node by LOCAL `ObjId`
/// (mirrors `set`'s `parent: ?ObjId` idiom — mint a `NodeRef` only at a
/// boundary, per the module doc comment).
pub const StructRef = ObjectDoc.StructRef;

/// Create a new structural node under `parent`, ordered by `order_key`
/// among its siblings (`orderKeyBetween`). Returns the new node's LOCAL
/// `ObjId` — immediately usable with `set`/`ref` like any other map
/// object (a struct node IS a map object; the struct forest is a
/// SEPARATE parent relation layered on top, not a new value kind).
pub fn structCreate(self: *GraphDoc, gpa: Allocator, parent: StructRef, order_key: []const u8) (Error || error{OrderKeyTooLong})!ObjId {
    return self.obj.structCreate(gpa, parent, order_key);
}

/// Identity-preserving move: `node` keeps its `ObjId` — hence keeps any
/// grant keyed on it (`grants.GraphSubtree`) — while its EFFECTIVE parent
/// register changes. This is precisely the capability an `EventAnchor`
/// PAIR cannot express (w7-rebase.md §2.2: a cut+paste relocate mints new
/// insertion identity and collapses an anchor-pair grant; a struct node's
/// identity is untouched by a move because nothing about the node's OWN
/// fields/text changed, only its placement in the forest).
pub fn structMove(self: *GraphDoc, gpa: Allocator, node: ObjId, parent: StructRef, order_key: []const u8) (Error || error{OrderKeyTooLong})!void {
    return self.obj.structMove(gpa, node, parent, order_key);
}

/// Sugar: move `node` to `.trash` (F3: "trash is another parent," not a
/// true delete) — NOT recursive; `node`'s own struct-forest children keep
/// pointing at it, unreachable from `.root` until it (and them) move
/// back out. See `reachable`'s doc comment for how this is the
/// collapse-trap condition a subtree grant relies on.
pub fn structDelete(self: *GraphDoc, gpa: Allocator, node: ObjId) Error!void {
    return self.obj.structDelete(gpa, node);
}

/// `node`'s current effective parent register, or `null` if `node` was
/// never a struct node. LANDMINE (see `ObjectDoc.structParent`'s own doc
/// comment in full): the winner is picked by a DIFFERENT rule than
/// `ValueRef.mapGet`'s — a global Lamport-then-identity order over EVERY
/// structural write in the doc, not a per-register MV rule — so the
/// winner can sit OUTSIDE `structConflictCount`'s reported set when a
/// cross-node cycle was broken (`structCycleBroken`). A projection
/// surfacing "why is this node here" must check that before explaining
/// the placement as an ordinary uncontested write.
pub fn structParent(self: *const GraphDoc, node: ObjId) ?StructRef {
    return self.obj.structParent(node);
}

/// Children of `parent` (`.root`/`.trash`/a node), sorted by order key
/// then authoring identity — the sibling-order `structChildren` itself
/// guarantees. Caller owns the returned slice.
pub fn structChildren(self: *const GraphDoc, gpa: Allocator, parent: StructRef) Allocator.Error![]ObjId {
    return self.obj.structChildren(gpa, parent);
}

/// `node`'s current order-key bytes (the sort key `structChildren` uses)
/// — borrowed, valid for the doc's lifetime, `null` if `node` isn't a
/// struct node. The currency `orderKeyBetween` computes a fresh midpoint
/// against.
pub fn structOrderKey(self: *const GraphDoc, node: ObjId) ?[]const u8 {
    return self.obj.structOrderKey(node);
}

/// True iff `node`'s effective parent is a cycle-break survivor sitting
/// OUTSIDE its own reported conflict set (`structParent`'s doc comment).
pub fn structCycleBroken(self: *const GraphDoc, node: ObjId) bool {
    return self.obj.structCycleBroken(node);
}

/// A byte-string fractional order-key strictly between `a` and `b`
/// (either bound `null` for "no bound on that side") — the sibling-order
/// currency `structCreate`/`structMove` consume. Caller owns the
/// returned bytes.
pub const orderKeyBetween = ObjectDoc.orderKeyBetween;

// ── Per-object identity anchors (delta 3, already shipped) — exposed here
// for a struct node's OWN body text object: "does this position inside a
// granted function's body still name the same CHARACTER after a
// concurrent edit shifts it" (doc/w7-rebase.md §4 W7b's "identity
// persistence across an in-function edit" gate assertion; D1 §4's ledgered
// "REQUIRED — delta 3", SHIPPED at this pin). Thin wrappers, same idiom as
// everything above: raw local `ObjId` in, no boundary crossed. ──────────

pub const AnchorSide = ObjectDoc.AnchorSide;
pub const EventAnchor = ObjectDoc.EventAnchor;
pub const AnchorError = ObjectDoc.AnchorError;

pub fn objectAnchorAt(self: *const GraphDoc, gpa: Allocator, obj: ObjId, byte_offset: usize, stickiness: AnchorSide) AnchorError!EventAnchor {
    return self.obj.objectAnchorAt(gpa, obj, byte_offset, stickiness);
}

pub fn resolveObjectAnchors(self: *const GraphDoc, gpa: Allocator, obj: ObjId, anchors: []const EventAnchor, out: []usize) AnchorError!void {
    return self.obj.resolveObjectAnchors(gpa, obj, anchors, out);
}

// ── NodeRef — the portable identity token ─────────────────────────────

/// A portable reference to one object in a `GraphDoc`, backed by
/// `ObjectDoc.exportId`'s wire token. Safe to store, copy, and carry
/// across a merge or (later) a wire — unlike a raw `ObjId`. This is the
/// graph↔text identity bridge `subbuffer.zig` id-spans carry (see
/// `transcript.zig`'s `fill`): a buffer row's subbuffer fact holds a
/// `NodeRef.token`, not an `ObjId`.
pub const NodeRef = struct {
    /// `ObjectDoc.exportId` bytes (`"sto\x01"` + agent name + seq).
    /// Owned by whoever holds this value.
    token: []const u8,

    pub fn eql(a: NodeRef, b: NodeRef) bool {
        return std.mem.eql(u8, a.token, b.token);
    }

    pub fn dupe(self: NodeRef, gpa: Allocator) Allocator.Error!NodeRef {
        return .{ .token = try gpa.dupe(u8, self.token) };
    }

    pub fn free(self: NodeRef, gpa: Allocator) void {
        gpa.free(self.token);
    }
};

pub const ResolveError = error{ Corrupt, MissingDependency };

/// Mint a portable `NodeRef` for `obj` (an id local to THIS replica).
/// Caller owns the returned token.
pub fn nodeRef(self: *const GraphDoc, gpa: Allocator, obj: ObjId) Allocator.Error!NodeRef {
    return .{ .token = try self.obj.exportId(gpa, obj) };
}

/// Resolve a `NodeRef` (possibly minted on another replica) to an `ObjId`
/// valid on THIS replica. `error.MissingDependency` if this replica
/// hasn't seen the creating event yet (merge first).
pub fn resolve(self: *const GraphDoc, ref_: NodeRef) ResolveError!ObjId {
    return self.obj.importId(ref_.token);
}

// ── Versions & sync (same token model as `Document`/`TextDoc`) ───────

pub fn version(self: *const GraphDoc, gpa: Allocator) Allocator.Error![]u8 {
    return self.obj.version(gpa);
}

pub fn compareVersions(self: *const GraphDoc, gpa: Allocator, a: []const u8, b: []const u8) MergeError!VersionOrder {
    return self.obj.compareVersions(gpa, a, b);
}

pub fn eventsSince(self: *const GraphDoc, gpa: Allocator, remote_version: []const u8) (Allocator.Error || error{Corrupt})![]u8 {
    return self.obj.eventsSince(gpa, remote_version);
}

/// Integrate a remote event batch; returns the change stream (caller owns).
pub fn merge(self: *GraphDoc, gpa: Allocator, bytes: []const u8) MergeError![]Change {
    return self.obj.merge(gpa, bytes);
}

/// Which regions (portable `NodeRef`s, deduplicated) would merging `batch`
/// touch — WITHOUT committing it to this replica. Caller owns the returned
/// slice and each ref's token (`NodeRef.free`).
///
/// ## Why this exists, and why it's shaped as a dry-run instead of a decode
///
/// W6 slice 1's per-region admission (doc/d1-live-reconcile.md §5.2,
/// §0 "admission is per-document and coarse") needs to know which `ObjId`s
/// an INCOMING batch targets *before* deciding whether to merge it — a
/// batch touching a region leased by another principal must never be
/// merged at all (§6 test 5: "assert B's op is NOT merged" — not merged
/// then reverted, not merged then compensated, never merged). `ObjectDoc`
/// hands back exactly this mapping (`Change.obj`) from `merge` itself
/// (ObjectDoc.zig:611-684), but only AFTER applying the batch — too late,
/// and `ObjectDoc`'s batch decoder (`Decoder`, ObjectDoc.zig:1030) is a
/// private implementation type, not a public pre-merge peek API. Two other
/// options were weighed and rejected: merge-then-roll-back the REAL doc has
/// no undo (events are permanent in `history`; a "rollback" that only
/// reverted the materialized tree would still leave the events integrated,
/// so a future `serialize`/`eventsSince` on this replica would silently
/// forward the refused ops to a THIRD peer — exactly the silent divergence
/// this mechanism exists to prevent). Admit-then-compensate (merge for
/// real, then apply an undo op) fails test 5's letter directly ("NOT
/// merged") and, worse, the compensating op is itself a new causal event
/// that races with what a third replica sees.
///
/// So: merge the batch into a throwaway CLONE (`serialize` + `open` — both
/// already public), read the clone's `Change` stream, mint portable tokens
/// from the CLONE's local `ObjId`s (portable because `exportId` keys on
/// agent NAME + seq, not local numbering — see `NodeRef`'s doc comment —
/// so the tokens are identical to what a real merge into `self` would
/// produce), then discard the clone entirely. If the caller decides to
/// admit, it calls `merge` again on the real doc with the SAME bytes — safe
/// because `self` hasn't been touched by this call, and `merge` is a pure
/// function of `(current history, batch bytes)`, so replaying it is not a
/// second causal event, just the same integration done once instead of
/// speculatively twice. If the caller refuses, `self` was NEVER merged, so
/// there is nothing to un-forward — divergence is structurally impossible,
/// not just avoided by discipline. The cost (a full `serialize`+`open`+
/// `merge` per admission-checked batch) is paid only when the caller has
/// active regions to protect — `GraphCollab.admitRegions` checks BOTH
/// tables it composes (a bound, non-empty grant table OR a bound,
/// non-empty lease table) BEFORE ever calling `touchedRegionsWithin` below,
/// so an ordinary share (neither bound, the common case) returns `.admit`
/// without touching this function at all — an honest, named cost, not a
/// hidden one; a cheaper stemma-side peek API (exposing `Decoder`'s op→obj
/// mapping without applying it) would remove it, and is the delta to ask
/// for if this cost ever matters.
/// One touched region, optionally answering the SUBTREE GRANT containment
/// question for it in the SAME pass — see `touchedRegionsWithin`.
pub const TouchedRegion = struct {
    region: NodeRef,
    /// Self-inclusive containment against ANY of the `roots` passed to
    /// `touchedRegionsWithin` — always `false` when `roots` was empty
    /// (nothing to test against; callers must not read this as "outside
    /// every root" in that case, only as "not evaluated").
    within_roots: bool,
};

/// Which regions (portable `NodeRef`s, deduplicated) would merging `batch`
/// touch, and — when `roots` is non-empty — whether EACH is contained
/// (self-inclusive, `contains`'s walk) within ANY of `roots`. `touchedRegions`
/// below is the `roots = &.{}` degenerate case, kept as the historical,
/// narrower-typed entry point every existing caller/test still uses.
///
/// ## Why containment is resolved HERE, against the scratch clone — not by
/// the caller, against `self` (W6 slice 2 REQUIRED FIX 2)
///
/// A batch that both CREATES a node under a granted root and immediately
/// mutates the new node (an append-and-populate, the ordinary shape of
/// "grantee adds an entry") produces a touched region — the new node's own
/// `ObjId` — that `self` (the enforcer's PRE-merge replica) has never seen:
/// the creating event is itself part of the very batch under evaluation.
/// Resolving that region's containment against `self.doc.resolve(...)`
/// (this function's first shipped version did exactly that) fails with
/// `error.MissingDependency` EVERY time, forever — not a transient refusal
/// that later heals on retry (`admitRegions`'s "deferred-until-release"
/// property assumes the SENDER'S state changes before a retry helps; here
/// nothing ever will, since the new node's identity never becomes any
/// older). The result was a PERMANENT lockout of the primary W6 use case
/// (grantee appends an entry to its own granted subtree) — confirmed by
/// the reviewer's adversarial test (`grants.tests`: create-and-populate in
/// one batch). The fix: resolve `roots` and every touched region's
/// containment INSIDE the scratch clone this function already builds and
/// merges the batch into — the clone has the FULL post-merge state, so a
/// batch-fresh node's parentage is exactly as visible as a pre-existing
/// one's. `roots` are always PRE-EXISTING nodes (a grant can only be
/// declared over a node that already exists at grant time), so resolving
/// THEM inside the clone costs nothing extra in correctness — they resolve
/// identically whether checked against `self` or the clone, since the
/// clone is `self`'s history plus the batch, never less.
///
/// A root that fails to resolve even in the clone (`scratch.resolve`
/// erroring) is genuinely foreign — not a batch-creation artifact, since
/// the clone has strictly MORE history than `self` — and is silently
/// excluded from `roots` for this call (contributes no containment); the
/// caller's own fail-closed policy for "no live root at all" (an empty
/// effective `roots`) still applies on top (see `GraphCollab.
/// gatherGrantRoots`'s doc comment).
pub fn touchedRegionsWithin(self: *const GraphDoc, gpa: Allocator, batch: []const u8, roots: []const NodeRef) MergeError![]TouchedRegion {
    const bytes = try self.serialize(gpa);
    defer gpa.free(bytes);
    // The scratch clone never originates a local write (only ever merges
    // remote bytes), so its own agent identity is inert — any name works.
    var scratch = try GraphDoc.open(gpa, "~region-peek-scratch", bytes);
    defer scratch.deinit(gpa);
    const changes = try scratch.merge(gpa, batch);
    defer gpa.free(changes);

    var root_objs: std.ArrayList(ObjId) = .empty;
    defer root_objs.deinit(gpa);
    for (roots) |root_ref| {
        const obj = scratch.resolve(root_ref) catch continue; // foreign to even the post-merge clone — excluded, not fatal
        root_objs.append(gpa, obj) catch |e| return e;
    }

    var out: std.ArrayList(TouchedRegion) = .empty;
    errdefer {
        for (out.items) |r| r.region.free(gpa);
        out.deinit(gpa);
    }
    for (changes) |c| {
        var is_structure = false;
        const obj: ObjId = switch (c) {
            .map => |m| m.obj,
            .list_ins => |l| l.obj,
            .list_del => |l| l.obj,
            .text => |tc| tc.obj,
            // W7b: the struct forest is now exposed (see the module doc
            // comment), so a peer's batch CAN carry a `struct_create`/
            // `struct_move`. The moved/created node is the region — see
            // the MOVE-ADMISSION RULE below for why node-containment
            // ALONE (the pre-W7b generic shape every other change kind
            // still uses) is not sufficient for this one.
            .structure => |s| blk: {
                is_structure = true;
                break :blk s.node;
            },
        } orelse continue; // a change directly on the root map has no
        // leaseable ObjId of its own (§1.1: region = one ObjId).
        const ref_ = try scratch.nodeRef(gpa, obj);
        var dup = false;
        for (out.items) |existing| {
            if (existing.region.eql(ref_)) {
                dup = true;
                break;
            }
        }
        if (dup) {
            gpa.free(ref_.token);
            continue;
        }
        var within = false;
        for (root_objs.items) |root_obj| {
            if (try scratch.contains(gpa, root_obj, obj)) {
                within = true;
                break;
            }
        }
        if (within and is_structure) {
            within = try structuralChangeAdmitted(self, &scratch, gpa, root_objs.items, obj, ref_);
        }
        try out.append(gpa, .{ .region = ref_, .within_roots = within });
    }
    return out.toOwnedSlice(gpa);
}

/// ## MOVE-ADMISSION RULE, DECIDED (W7b, doc/w7-rebase.md §4) — REVISED
/// after review found the first version's reasoning self-contradictory
/// (a `struct_create`/`struct_move` whose region is `node`, already known
/// `within` the peer's granted union by the caller's node-containment
/// check, evaluated against `scratch` — i.e. POST-merge).
///
/// The ORIGINAL rule (destination-parent-also-within-union) does NOT close
/// the adopt-in direction it claimed to, and the flaw is visible in its
/// own words: "making X a descendant of the granted root" is EXACTLY what
/// the destination check admits, by construction — a peer holding a grant
/// on `G` sends `struct_move(foreign, .{.node = G}, key)` for some node
/// `foreign` they were never granted authority over; post-merge (in
/// `scratch`) `foreign` IS now `G`'s struct child, so `contains(G,
/// foreign)` is true (the node check) AND `contains(G, G)` is true
/// (self-inclusive — the destination check). Both pass; ADMITTED. The
/// peer just annexed arbitrary foreign content into their subtree and, by
/// the SAME containment mechanism, gained ongoing edit authority over its
/// entire contents — repeatable to escalate a narrow grant to the whole
/// document. Checking only where a node ENDS UP can never distinguish
/// "the peer reorganized their own territory" from "the peer imported
/// someone else's" — both produce an identical post-merge state.
///
/// **THE FIX: admission for a structural change is a pure INTRA-SUBTREE
/// REPARENT — origin ∈ union AND destination ∈ union AND node ∈ union
/// post-merge (already checked by the caller); `.root`/`.trash` never
/// count as "within" on either end.** The origin is `node`'s parent
/// BEFORE this batch — read from `self` (the ENFORCER's own real,
/// pre-merge replica), NEVER from `scratch`. This is not a stylistic
/// choice: `scratch` already has the batch's move applied, so
/// `scratch.structParent(node)` can only ever report the NEW parent —
/// asking `scratch` "what was the origin" is asking the post-state to
/// remember the pre-state, which it structurally cannot; only `self`,
/// untouched by this batch, still holds it. With both ends checked
/// against the union, the reviewer's trace now fails correctly:
/// `foreign`'s pre-merge origin (on `self`) is `.root` — not a member of
/// `{G}` — so admission refuses it, `.authority`, before the destination
/// check even matters.
///
/// **`.root`/`.trash` origins are DECIDED to never count** — the export
/// and self-delete directions this rule was already right about: a peer
/// moving their OWN granted root/child to a foreign parent or to `.trash`
/// has origin ∈ union but destination ∉ union → refused (kept from the
/// original rule, still correct — see the corollary below).
///
/// **CREATE vs MOVE, decided explicitly, per review's ask.** A brand-new
/// node minted by THIS batch (`struct_create`) has no origin at all —
/// nothing is being "reparented FROM" anywhere; it is the direct
/// structural analog of the already-admitted "grantee appends an entry to
/// its own subtree" case (`touchedRegionsWithin`'s own doc comment, the
/// create-and-populate fix). Decided: admit a create iff its destination
/// ∈ union (already established by the caller's node check, since a
/// freshly-created node's only containment path IS through its parent).
/// Detecting "no origin" is NOT a matter of asking `scratch.structParent`
/// (which reports SOME placement for both a create and a move — the
/// Change stream cannot tell them apart syntactically) — it is asking
/// **does `node` exist on `self` AT ALL, before this batch?** via
/// `self.resolve` on the SAME portable token `scratch` minted. A
/// `MissingDependency`/`Corrupt` failure means `self` has never seen this
/// object's creating event — it is genuinely new, born in this very
/// batch, and there is categorically nothing prior to check.
///
/// **The case review's literal wording left implicit, closed here rather
/// than left open: a PRE-EXISTING node that resolves on `self` but was
/// NEVER a struct-forest member before (`self.structParent` returns
/// `null`, not because it's new, but because it's an ordinary map/list/
/// text object nothing ever `structCreate`d) is NOT treated as a
/// no-origin create.** `ObjectDoc.structMove` has no precondition that
/// `node` was ever `structCreate`d — it will happily adopt ANY existing
/// `ObjId` into the struct forest for the first time. Treating "no prior
/// struct placement" as automatically create-like would reopen the exact
/// hole this rule exists to close, just spelled with `structMove` on a
/// plain object (another function's own `"body"` text object, say)
/// instead of on a sibling struct node — same annexation, same
/// escalation. So: pre-existing + no struct placement is INELIGIBLE
/// (treated exactly like a `.root`/`.trash` origin — never within any
/// union), not create-like. Only a node `self` has never heard of at all
/// gets the permissive create path.
///
/// **This branch is defense-in-depth, confirmed unreachable via an
/// ordinary REMOTE batch today** (`session/tests.zig`'s move-admission
/// test 5/5): stemma's own `Walker.resolveStructNode` already refuses,
/// with `error.Corrupt`, ANY `struct_move` whose `node` doesn't trace back
/// to a `.struct_create` op when merging from an untrusted source — one
/// layer BELOW this function, inside `scratch.merge` itself. A plain
/// object can never even survive the merge that would let this branch's
/// logic run. Kept anyway: a future caller reaching a node without going
/// through that untrusted-merge validation (this facade offers no such
/// path today, but the admission primitive shouldn't assume one never
/// will) still needs this to be correct, not merely lucky.
///
/// `roots.items` (passed in, `ObjId`s already resolved against `scratch`)
/// are used against `self` too for the origin check without re-resolving:
/// `touchedRegionsWithin`'s own doc comment already establishes this is
/// sound — "`roots` are always PRE-EXISTING nodes... they resolve
/// identically whether checked against `self` or the clone, since the
/// clone is `self`'s history plus the batch, never less."
///
/// Corollary, unchanged from the original rule, still correct: a peer's
/// own `struct_delete` (→ `struct_move` to `.trash`) of a node they hold
/// a grant ROOT on is refused (origin ∈ union, destination = `.trash` ∉
/// union) — a subtree grant confers authority to edit WITHIN a function,
/// not to strike it from existence. Deletion is the host's call (gate
/// scenario (c)): the host deletes, the peer's grant COLLAPSES per
/// `reachable`, and the peer's next edit traps loudly, `.collapsed` —
/// never through this rule refusing a delete batch the peer never gets to
/// send, since it's the host's own local edit.
fn structuralChangeAdmitted(
    self: *const GraphDoc,
    scratch: *const GraphDoc,
    gpa: Allocator,
    roots: []const ObjId,
    obj: ObjId,
    node_ref: NodeRef,
) Allocator.Error!bool {
    // Destination: `node`'s parent AFTER this batch (post-merge, only
    // `scratch` has this — `self` hasn't merged the batch at all). `obj`
    // is already `node`'s SCRATCH-local id (the caller resolved it from
    // the `Change` stream directly); `node_ref` (the portable token, also
    // already minted by the caller) is what the ORIGIN check below needs
    // to look `node` up on `self` instead — a scratch-local id is not
    // safe to reuse against `self` in general (only `roots`, established
    // PRE-EXISTING, are — see the doc comment above).
    const dest = scratch.structParent(obj) orelse return false;
    const dest_within = switch (dest) {
        .root, .trash => false,
        .node => |pid| blk: {
            for (roots) |root_obj| {
                if (try scratch.contains(gpa, root_obj, pid)) break :blk true;
            }
            break :blk false;
        },
    };
    if (!dest_within) return false;

    // Origin: does `node` exist on `self` (pre-merge) at all?
    const self_obj = self.resolve(node_ref) catch return true; // genuinely new — CREATE case; destination check above already governs.

    // Pre-existing: a reparent (or an adoption attempt of a plain,
    // never-struct-forest object — see the doc comment above). Its
    // ORIGIN must ALSO be within the union, read from `self` — never
    // `scratch`, which only ever knows the NEW parent.
    const origin = self.structParent(self_obj) orelse return false; // pre-existing, no prior struct placement — ineligible, not "no origin"
    return switch (origin) {
        .root, .trash => false,
        .node => |pid| blk: {
            for (roots) |root_obj| {
                if (try self.contains(gpa, root_obj, pid)) break :blk true;
            }
            break :blk false;
        },
    };
}

/// The `roots = &.{}` case of `touchedRegionsWithin`, kept as its own
/// narrower-typed entry point: every `within_roots` flag is `false`
/// (vacuous — nothing was asked), so this returns just the touched
/// `NodeRef`s, exactly as it always has (W6 slice 1's lease check, and
/// this function's own tests, depend on this exact shape).
pub fn touchedRegions(self: *const GraphDoc, gpa: Allocator, batch: []const u8) MergeError![]NodeRef {
    const withins = try self.touchedRegionsWithin(gpa, batch, &.{});
    defer gpa.free(withins); // ownership of each `.region` token moves into `out` below
    const out = try gpa.alloc(NodeRef, withins.len);
    for (withins, 0..) |w, i| out[i] = w.region;
    return out;
}

/// The whole history (bootstrap batch for `open`).
pub fn serialize(self: *const GraphDoc, gpa: Allocator) Allocator.Error![]u8 {
    return self.obj.serialize(gpa) catch |e| switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        // stemma ≥0.5.0-dev widens ObjectDoc.serialize with
        // error.Unrealized (partial checkout). A GraphDoc's ObjectDoc is
        // never partial — no facade path calls openPartial or mints
        // holes — so it is unreachable here; the `else` (not a named
        // arm) keeps this compiling on both sides of the pin boundary
        // (the pinned stemma's error set doesn't name Unrealized).
        else => unreachable,
    };
}

// ── Ancestry / reachability — the identity-anchored SUBTREE GRANT ────────
// predicate (W6 slice 2, doc/north-star-plan.md §6 W6, §2.4's "on graph
// docs, limits key on ObjId subtrees and are exact"; d1-live-reconcile.md
// §5.2's "the same [per-region admission] machinery W6 needs for
// identity-anchored subtree grants... used for mutual exclusion instead of
// authority"; D1 §3/§4's "small facade addition: a reachability/trash
// predicate ... buildable now"; W7b, doc/w7-rebase.md §4, taught this walk
// the STRUCT FOREST — see "Containment semantics" below).
//
// Two predicates, one walk:
//   - `contains(root, target)` — is `target` within the subtree rooted at
//     `root` (self-inclusive)? The subtree-grant admission check
//     (`GraphCollab.admitRegions`'s second predicate).
//   - `reachable(target)` — is `target` still linked from the DOC ROOT at
//     all? `false` for a deleted/trashed node — the collapse-trap check a
//     grant's root needs (§2.4's doc_region collapse discipline,
//     generalized: "if the root node is DELETED/unreachable, the grant
//     must trap/refuse loudly on next use — never silently widen or
//     narrow").
//
// ## Why a walk DOWN, never a walk up
//
// `ObjectDoc` stores no REVERSE parent pointer for the value tree (an
// object's map/list parent slot is fixed at creation, nothing indexes
// "who points at me") — so the only navigable direction there is DOWN,
// from a `ValueRef`, through `mapKeys`/`mapConflictAt` (every CONCURRENT
// value at a key, not just `mapGet`'s deterministic winner — a losing
// MV-conflict branch is still a real, live object, and excluding it from
// containment would make an authority decision depend on a tiebreak that
// has nothing to do with authority) and `listAt`. The struct forest DOES
// store the effective parent per node (`structParent`) but this walk
// still goes DOWN through it too, via `structChildren` — for the same
// reason `touchedRegionsWithin` resolves things forward, not backward: a
// single downward walk from `root`/`self.root()` composes both relations
// uniformly (see "Containment semantics" below) without needing two
// different traversal directions. Cost: O(size of the walked subtree) —
// `contains` returns as soon as `target` is found; `reachable`'s worst
// case (a genuinely deleted/foreign target) walks every live object in
// the doc. This is the same class of honest, named,
// unavoidable-without-parent-pointers cost `touchedRegions`'s own doc
// comment prices for its dry-run merge; a cheaper reverse index would be
// the delta to ask stemma for if this cost ever matters at real-document
// scale — not built speculatively here.
//
// ## Containment semantics, DECIDED (W7b): value-tree UNION struct-forest
//
// A code buffer's function struct nodes compose BOTH relations at once —
// a function node is a real map object (its OWN fields, e.g. `"body"`, sit
// in the ordinary value tree) AND a struct-forest node (its nested
// functions, if any, sit in `structChildren`). So "is `target` inside the
// subtree rooted at `root`" must union both: `target` is contained if it
// is reachable from `root` by ANY sequence of map/list-containment edges
// AND/OR struct-forest parent edges, in any order/mix. This is the
// honest reading of "subtree" for a node that legitimately has children
// of both kinds — narrower semantics (say, "only the relation the ROOT's
// own kind implies") would make a function's OWN nested helper functions
// silently fall OUTSIDE a grant on the function, which is not what
// "grant this function's subtree" means to a caller. Implementation:
// `walkContains`, for the node `v` it is currently expanding, ALSO
// fetches `v`'s struct-forest children (when `v` has an `ObjId`) and
// treats them exactly like a map/list child — same eligibility test, same
// recursion, same `visited` guard.
//
// ## `reachable` and the struct forest's OWN root sentinel
//
// One asymmetry `contains` doesn't have to worry about (its `subtree_root`
// is always a concrete, already-existing `ObjId`) but `reachable` does:
// `self.root()` (the value-tree's root MAP object) and the struct forest's
// `.root` SENTINEL are two DIFFERENT anchors with no edge between them — a
// TOP-LEVEL struct node (`structParent(node) == .root`) is parented at the
// sentinel, never at `self.root()`'s `ObjId`, so a walk that only ever
// starts from `self.root()` would never discover it (and would therefore
// wrongly report it `unreachable`, since nothing links `self.root()` to
// it). `reachable` therefore runs the value-tree walk from `self.root()`
// AND, separately, the struct-forest's own top level
// (`structChildren(.root)`) — the union of "linked from the document's
// value root" and "resolves, via the struct forest, to the struct
// forest's root sentinel (not `.trash`)." A struct node whose ancestry
// terminates at `.trash` (directly, via `structDelete`, or transitively —
// an ancestor was trashed, per `structDelete`'s "not recursive" doc
// comment) is NOT reachable by either path: exactly the collapse-trap
// condition a subtree grant on that node relies on (§2.4 generalized,
// above).
//
// ## The move-op stability contract — and the cycle guard it needs
//
// With `structMove` exposed (W7b, "The struct forest — exposed" module doc
// comment section), `contains`/`reachable`'s CONTRACT does not change
// shape from what it always promised: "is `target` reachable from `root`
// under the CURRENT live parentage" — a move-aware walk answers exactly
// that; only the STABILITY guarantee narrows from "for the object's whole
// lifetime, modulo deletion" (true of the value tree, whose parent slot is
// fixed at creation) to "at the moment of the call" for anything reached
// through the struct forest, same as any live containment check over a
// mutable tree. No caller needs to change; a grant whose node got moved
// OUT of its subtree correctly starts reading as outside it — the honest
// answer to a question about CURRENT structure, neither a silent widening
// nor a silent narrowing.
//
// A move op also means a graph with reparenting can, in principle, contain
// a CYCLE — something this walk never had to consider when every parent
// edge was creation-time-immutable. stemma's OWN cycle-break
// (`structCycleBroken`) keeps the MATERIALIZED `struct_parents` table
// acyclic by construction (a write that would create a cycle is
// deterministically rejected — `ObjectDoc.wouldCycleLocal`/the global
// Lamport replay), so this walk does not strictly need the guard to stay
// terminating. It keeps the guard anyway, unconditionally, over BOTH
// relations: `walkContains` carries a `visited` set from its first call —
// each `ObjId` is marked before recursing into it, and an already-visited
// id is skipped rather than re-walked. This is defense-in-depth an
// authority predicate should not go without (a stemma-side cycle-break
// bug would otherwise turn a permission check into an infinite recursion,
// the worst possible failure mode for exactly this code), and it is what
// already made shared MV-conflict substructure in the value tree safe to
// walk, unchanged.
fn childObjId(v: ValueRef) ?ObjId {
    // `ValueRef.objId()` is documented `unreachable` on a scalar node
    // (scalars have no identity) — gate on `kind()` first so a string/int/
    // bool/null map value or list element is skipped rather than panicking.
    return switch (v.kind()) {
        .map, .list, .text => v.objId(),
        else => null,
    };
}

/// Walk `oid`'s struct-forest children (W7b) exactly like a map/list
/// child: eligibility test, recurse, `visited` guard. Shared by both
/// branches below (a struct node's children can themselves have BOTH
/// value-tree and struct-forest children — see "Containment semantics"
/// above).
fn walkStructChildren(
    self: *const GraphDoc,
    gpa: Allocator,
    visited: *std.AutoHashMapUnmanaged(ObjId, void),
    oid: ObjId,
    target: ObjId,
) Allocator.Error!bool {
    const kids = try self.obj.structChildren(gpa, .{ .node = oid });
    defer gpa.free(kids);
    for (kids) |kid| {
        if (std.meta.eql(kid, target)) return true;
        const gop = try visited.getOrPut(gpa, kid);
        if (gop.found_existing) continue; // already walked — cycle guard
        if (try self.walkContains(gpa, visited, self.ref(kid), target)) return true;
    }
    return false;
}

fn walkContains(
    self: *const GraphDoc,
    gpa: Allocator,
    visited: *std.AutoHashMapUnmanaged(ObjId, void),
    v: ValueRef,
    target: ObjId,
) Allocator.Error!bool {
    // Struct-forest children of `v` ITSELF, unioned with its value-tree
    // children below — see "Containment semantics, DECIDED (W7b)" above.
    if (childObjId(v)) |vid| {
        if (try self.walkStructChildren(gpa, visited, vid, target)) return true;
    }
    switch (v.kind()) {
        .map => {
            var it = v.mapKeys();
            while (it.next()) |key| {
                const n = v.mapConflictCount(key);
                var i: usize = 0;
                while (i < n) : (i += 1) {
                    const child = v.mapConflictAt(key, i);
                    if (childObjId(child)) |oid| {
                        if (std.meta.eql(oid, target)) return true;
                        const gop = try visited.getOrPut(gpa, oid);
                        if (gop.found_existing) continue; // already walked — cycle guard
                        if (try self.walkContains(gpa, visited, child, target)) return true;
                    }
                }
            }
        },
        .list => {
            const len = v.listLen();
            var i: usize = 0;
            while (i < len) : (i += 1) {
                const child = v.listAt(i);
                if (childObjId(child)) |oid| {
                    if (std.meta.eql(oid, target)) return true;
                    const gop = try visited.getOrPut(gpa, oid);
                    if (gop.found_existing) continue; // already walked — cycle guard
                    if (try self.walkContains(gpa, visited, child, target)) return true;
                }
            }
        },
        else => {}, // text/scalar leaves have no value-tree children
    }
    return false;
}

/// Is `target` within the subtree rooted at `subtree_root` (self-inclusive:
/// `subtree_root == target` counts)? See the section doc comment above for
/// cost, the containment-semantics decision (value-tree UNION struct
/// forest), and the move-op stability + cycle-guard contract.
pub fn contains(self: *const GraphDoc, gpa: Allocator, subtree_root: ObjId, target: ObjId) Allocator.Error!bool {
    if (std.meta.eql(subtree_root, target)) return true;
    var visited: std.AutoHashMapUnmanaged(ObjId, void) = .empty;
    defer visited.deinit(gpa);
    try visited.put(gpa, subtree_root, {});
    return self.walkContains(gpa, &visited, self.ref(subtree_root), target);
}

/// Is `target` still reachable from the DOC ROOT — i.e. NOT deleted/
/// trashed? See the section doc comment above, especially "`reachable`
/// and the struct forest's own root sentinel": this walks BOTH the
/// value-tree root (`self.root()`) and the struct forest's OWN top level
/// (`structChildren(.root)`), since a top-level struct node is parented
/// at a sentinel disconnected from `self.root()`'s `ObjId`.
pub fn reachable(self: *const GraphDoc, gpa: Allocator, target: ObjId) Allocator.Error!bool {
    var visited: std.AutoHashMapUnmanaged(ObjId, void) = .empty;
    defer visited.deinit(gpa);
    if (try self.walkContains(gpa, &visited, self.root(), target)) return true;
    // The struct forest's OWN top level is queried with the SENTINEL
    // `.root`, not a node `ObjId` — `walkStructChildren` is node-keyed
    // (`structChildren(.{ .node = oid })`), so the sentinel case is
    // spelled out directly here instead.
    const top = try self.obj.structChildren(gpa, .root);
    defer gpa.free(top);
    for (top) |kid| {
        if (std.meta.eql(kid, target)) return true;
        const gop = try visited.getOrPut(gpa, kid);
        if (gop.found_existing) continue;
        if (try self.walkContains(gpa, &visited, self.ref(kid), target)) return true;
    }
    return false;
}

// ── Tests ───────────────────────────────────────────────────────────

const t = std.testing;

fn syncOne(gpa: Allocator, from: *const GraphDoc, to: *GraphDoc) !void {
    const ver = try to.version(gpa);
    defer gpa.free(ver);
    const batch = try from.eventsSince(gpa, ver);
    defer gpa.free(batch);
    const changes = try to.merge(gpa, batch);
    gpa.free(changes);
}

test "GraphDoc: CRUD through the typed accessors" {
    const gpa = t.allocator;
    var g = try GraphDoc.init(gpa, "alice");
    defer g.deinit(gpa);

    _ = try g.set(gpa, null, "title", .{ .str = "demo" });
    const tags = (try g.set(gpa, null, "tags", .list)).?;
    _ = try g.seqAppend(gpa, tags, .{ .str = "x" });
    _ = try g.seqAppend(gpa, tags, .{ .str = "y" });
    const body = (try g.set(gpa, null, "body", .text)).?;
    _ = try g.textInsert(gpa, body, 0, "hello");

    try t.expectEqualStrings("demo", g.root().mapGet("title").?.asStr());
    try t.expectEqual(@as(usize, 2), g.ref(tags).listLen());
    try t.expectEqualStrings("x", g.ref(tags).listAt(0).asStr());
    try t.expectEqualStrings("y", g.ref(tags).listAt(1).asStr());
    const body_bytes = try g.ref(body).textRope().toOwnedSlice(gpa);
    defer gpa.free(body_bytes);
    try t.expectEqualStrings("hello", body_bytes);

    try g.unset(gpa, null, "title");
    try t.expect(g.root().mapGet("title") == null);

    try g.seqDelete(gpa, tags, 0);
    try t.expectEqual(@as(usize, 1), g.ref(tags).listLen());
    try t.expectEqualStrings("y", g.ref(tags).listAt(0).asStr());
}

test "GraphDoc: version/eventsSince/merge round-trip converges across replicas" {
    const gpa = t.allocator;
    var a = try GraphDoc.init(gpa, "alice");
    defer a.deinit(gpa);
    const tags = (try a.set(gpa, null, "tags", .list)).?;
    _ = try a.seqAppend(gpa, tags, .{ .str = "x" });

    // A raw ObjId does NOT cross replicas (agent numbering is per-replica —
    // see the module doc comment); only a NodeRef does. No deterministic
    // NEGATIVE test exists on purpose: a foreign ObjId's failure mode is
    // coincidental (agent-table registration order can happen to align, in
    // which case it silently resolves to the WRONG node) — which is exactly
    // why the portable token is the only sanctioned form, and why a test
    // asserting misresolution would be flaky by the nature of the bug.
    const tags_ref = try a.nodeRef(gpa, tags);
    defer tags_ref.free(gpa);

    const bytes = try a.serialize(gpa);
    defer gpa.free(bytes);
    var b = try GraphDoc.open(gpa, "bob", bytes);
    defer b.deinit(gpa);

    const b_tags = try b.resolve(tags_ref);
    _ = try b.seqAppend(gpa, b_tags, .{ .str = "y" });

    try syncOne(gpa, &b, &a);

    try t.expectEqual(@as(usize, 2), a.ref(tags).listLen());
    try t.expectEqualStrings("x", a.ref(tags).listAt(0).asStr());
    try t.expectEqualStrings("y", a.ref(tags).listAt(1).asStr());

    // Fully synced: identical version frontiers.
    const av = try a.version(gpa);
    defer gpa.free(av);
    const bv = try b.version(gpa);
    defer gpa.free(bv);
    try t.expectEqual(VersionOrder.equal, try a.compareVersions(gpa, av, bv));
}

test "GraphDoc.touchedRegions: dry-run peek identifies the touched object without merging or mutating" {
    const gpa = t.allocator;
    var a = try GraphDoc.init(gpa, "alice");
    defer a.deinit(gpa);
    const n1 = (try a.set(gpa, null, "n1", .map)).?;
    _ = (try a.set(gpa, null, "n2", .map)).?;
    const n1_ref = try a.nodeRef(gpa, n1);
    defer n1_ref.free(gpa);

    const bytes = try a.serialize(gpa);
    defer gpa.free(bytes);
    var b = try GraphDoc.open(gpa, "bob", bytes);
    defer b.deinit(gpa);
    const b_n1 = try b.resolve(n1_ref);
    _ = try b.set(gpa, b_n1, "label", .{ .str = "hi" });

    const av = try a.version(gpa);
    defer gpa.free(av);
    const batch = try b.eventsSince(gpa, av);
    defer gpa.free(batch);

    const touched = try a.touchedRegions(gpa, batch);
    defer {
        for (touched) |r| r.free(gpa);
        gpa.free(touched);
    }
    try t.expectEqual(@as(usize, 1), touched.len);
    try t.expect(touched[0].eql(n1_ref));

    // The dry run must not have mutated `a` at all.
    try t.expect(a.ref(n1).mapGet("label") == null);
    const av2 = try a.version(gpa);
    defer gpa.free(av2);
    try t.expectEqualStrings(av, av2);

    // A real merge with the SAME bytes afterwards still works — the
    // scratch clone never touched `a`'s own state, so replaying is not a
    // second causal event, just the integration done for real.
    const changes = try a.merge(gpa, batch);
    defer gpa.free(changes);
    try t.expectEqualStrings("hi", a.ref(n1).mapGet("label").?.asStr());
}

test "GraphDoc.touchedRegions: correct under init-then-merge bootstrap order (mirrors GraphCollab, not GraphDoc.open)" {
    // `GraphDoc.open` merges BEFORE `setAgent` (registers the bootstrap
    // sender's agent name first, the local identity second); `GraphCollab`
    // bootstraps the opposite way (`GraphDoc.init` registers the LOCAL
    // identity first, then `merge` registers the remote sender during the
    // batch) — see GraphCollab.zig's module doc comment on why `init`, not
    // `open`, is the joiner's bootstrap shell. Both orders must resolve
    // portable tokens identically; this pins the order the wire path
    // actually uses (a real cross-wire regression surfaced exactly this
    // ordering difference during development — a test-harness bug where a
    // stray reused variable name shadowed the real one, not a
    // `touchedRegions`/stemma bug, but worth pinning given how easy the
    // confusion was).
    const gpa = t.allocator;
    var a = try GraphDoc.init(gpa, "alice");
    defer a.deinit(gpa);
    const room1 = (try a.set(gpa, null, "room1", .map)).?;
    _ = (try a.set(gpa, null, "room2", .map)).?;
    const room1_ref = try a.nodeRef(gpa, room1);
    defer room1_ref.free(gpa);

    var b = try GraphDoc.init(gpa, "bob");
    defer b.deinit(gpa);
    const boot = try a.serialize(gpa);
    defer gpa.free(boot);
    const changes = try b.merge(gpa, boot);
    gpa.free(changes);

    const b_room1 = try b.resolve(room1_ref);
    _ = try b.set(gpa, b_room1, "hacked", .{ .str = "evil" });

    const av = try a.version(gpa);
    defer gpa.free(av);
    const batch = try b.eventsSince(gpa, av);
    defer gpa.free(batch);

    const touched = try a.touchedRegions(gpa, batch);
    defer {
        for (touched) |r| gpa.free(r.token);
        gpa.free(touched);
    }
    try t.expectEqual(@as(usize, 1), touched.len);
    try t.expect(touched[0].eql(room1_ref));
}

test "GraphDoc.contains: subtree membership walks maps and lists, self-inclusive, siblings excluded" {
    const gpa = t.allocator;
    var g = try GraphDoc.init(gpa, "alice");
    defer g.deinit(gpa);

    const inside = (try g.set(gpa, null, "inside", .map)).?;
    const child = (try g.set(gpa, inside, "child", .map)).?;
    const items = (try g.set(gpa, child, "items", .list)).?;
    const leaf = (try g.seqAppend(gpa, items, .map)).?;
    const outside = (try g.set(gpa, null, "outside", .map)).?;

    try t.expect(try g.contains(gpa, inside, inside)); // self-inclusive
    try t.expect(try g.contains(gpa, inside, child)); // direct child
    try t.expect(try g.contains(gpa, inside, leaf)); // grandchild through a list
    try t.expect(!try g.contains(gpa, inside, outside)); // sibling of the root, not a descendant
    try t.expect(!try g.contains(gpa, outside, inside)); // containment isn't symmetric
}

test "GraphDoc.contains: sees BOTH sides of a live MV conflict, not just mapGet's winner" {
    const gpa = t.allocator;
    var a = try GraphDoc.init(gpa, "alice");
    defer a.deinit(gpa);
    const root_node = (try a.set(gpa, null, "root", .map)).?;
    const root_ref = try a.nodeRef(gpa, root_node);
    defer root_ref.free(gpa);

    const bytes = try a.serialize(gpa);
    defer gpa.free(bytes);
    var b = try GraphDoc.open(gpa, "bob", bytes);
    defer b.deinit(gpa);
    const b_root = try b.resolve(root_ref);

    // Concurrent mapSet of the SAME key on both replicas — two live
    // conflicting objects, one MV-register winner (`mapGet`), two members
    // in the conflict set.
    const a_child = (try a.set(gpa, root_node, "slot", .map)).?;
    const b_child = (try b.set(gpa, b_root, "slot", .map)).?;

    try syncOne(gpa, &b, &a);
    try t.expectEqual(@as(usize, 2), a.ref(root_node).mapConflictCount("slot"));

    // Both branches are reachable from `root_node`'s subtree — containment
    // must not silently drop the MV-conflict loser.
    try t.expect(try a.contains(gpa, root_node, a_child));
    const b_child_ref = try b.nodeRef(gpa, b_child);
    defer b_child_ref.free(gpa);
    const a_view_of_b_child = try a.resolve(b_child_ref);
    try t.expect(try a.contains(gpa, root_node, a_view_of_b_child));
}

test "GraphDoc.reachable: true while linked, false once deleted (the collapse-trap check)" {
    const gpa = t.allocator;
    var g = try GraphDoc.init(gpa, "alice");
    defer g.deinit(gpa);

    const node = (try g.set(gpa, null, "doomed", .map)).?;
    _ = try g.set(gpa, node, "field", .{ .str = "x" });
    try t.expect(try g.reachable(gpa, node));

    try g.unset(gpa, null, "doomed");
    try t.expect(!try g.reachable(gpa, node)); // unlinked from root — the grant-collapse condition
}

test {
    std.testing.refAllDecls(@This());
}
