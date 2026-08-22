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
//! ## `Projection`/`ReconcileMode` (§2.6) — named, not yet generically built
//!
//! §2.6 sketches a generic `Projection` (a `fill` + a `ReconcileMode` of
//! `on_save`/`live`/`authoritative`) meant to run over a captured `Ctx` and
//! a rendering `Viewport` — machinery from W2b/W3 this slice does not
//! plumb through. Building that generic type now, unused by anything but a
//! single client, would be exactly the kind of premature abstraction this
//! plan elsewhere refuses (F1's "two substrates is scaffolding with a
//! demolition date", the container's "systems are values" discipline
//! preferring one real client over a speculative interface). `transcript.
//! zig`'s `fill` is that ONE variant, concretely: a `.read_only` reconcile
//! (edits refused — the existing `Buffer.read_only` mechanism, not
//! anything new), documented there against `on_save`/`live`'s real
//! unsuitability for a transcript. The generic union lands when a second
//! client needs a different mode and the shape can be inferred from two
//! real cases instead of guessed from one.

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
/// calls `open`.
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

test {
    std.testing.refAllDecls(@This());
}
