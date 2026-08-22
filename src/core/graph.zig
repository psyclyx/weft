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
/// not just avoided by discipline. The cost (a full `serialize`+`open` per
/// admission-checked batch) is paid only when the caller has active
/// regions to protect (see `GraphCollab.admitRegions`'s empty-table fast
/// path) — an honest, named cost, not a hidden one; a cheaper stemma-side
/// peek API (exposing `Decoder`'s op→obj mapping without applying it) would
/// remove it, and is the delta to ask for if this cost ever matters.
pub fn touchedRegions(self: *const GraphDoc, gpa: Allocator, batch: []const u8) MergeError![]NodeRef {
    const bytes = try self.serialize(gpa);
    defer gpa.free(bytes);
    // The scratch clone never originates a local write (only ever merges
    // remote bytes), so its own agent identity is inert — any name works.
    var scratch = try GraphDoc.open(gpa, "~region-peek-scratch", bytes);
    defer scratch.deinit(gpa);
    const changes = try scratch.merge(gpa, batch);
    defer gpa.free(changes);

    var out: std.ArrayList(NodeRef) = .empty;
    errdefer {
        for (out.items) |r| r.free(gpa);
        out.deinit(gpa);
    }
    for (changes) |c| {
        const obj: ObjId = switch (c) {
            .map => |m| m.obj,
            .list_ins => |l| l.obj,
            .list_del => |l| l.obj,
            .text => |tc| tc.obj,
        } orelse continue; // a change directly on the root map has no
        // leaseable ObjId of its own (§1.1: region = one ObjId).
        const ref_ = try scratch.nodeRef(gpa, obj);
        var dup = false;
        for (out.items) |existing| {
            if (existing.eql(ref_)) {
                dup = true;
                break;
            }
        }
        if (dup) {
            gpa.free(ref_.token);
            continue;
        }
        try out.append(gpa, ref_);
    }
    return out.toOwnedSlice(gpa);
}

/// The whole history (bootstrap batch for `open`).
pub fn serialize(self: *const GraphDoc, gpa: Allocator) Allocator.Error![]u8 {
    return self.obj.serialize(gpa);
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

test {
    std.testing.refAllDecls(@This());
}
