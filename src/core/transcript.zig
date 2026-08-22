//! `transcript.zig` — the agent transcript: W5's REQUIRED first `graph.zig`
//! client (doc/north-star-plan.md §2.6, §5 "W5 ordering — transcript
//! first, DECIDED"; review A7b: W6's check-in scenario needs a real graph
//! document to attach to, not magit, which stays on the current
//! tool-buffer machinery). A transcript is a sequence of role-tagged
//! entries (user/agent/tool turns), each entry's body a real text CRDT —
//! collaboratively editable later, without redesign.
//!
//! Model code runs HOST-SIDE/in-process, per §2.6's "where the graph-side
//! plugin code runs": no graph ABI crosses the wasm membrane yet (fn-
//! pointer `Projection` contracts don't survive wasm; a guest-facing
//! `wl_graph_*` ABI is its own later, priced step). `core` is the right
//! home for the same reason `Document`/`Buffers` are: this is
//! infrastructure other host machinery (W6's check-in, eventually the
//! session/wire layer) is built on, not a single feature's private state.
//!
//! ## Why entries are a `seq`, not a structural list (F3)
//!
//! `graph.zig`'s module doc comment states F3's general rule: ObjectDoc's
//! list op (`seqInsert`/`seqAppend` here) is legitimate ONLY for leaf
//! sequences that never reparent. Applied honestly to THIS model: a
//! transcript entry is created once (`append`), read, and its body text
//! may be edited in place (`editText`) — it never moves to a different
//! transcript, never nests under another entry, never gets reordered
//! relative to its siblings (a transcript's order IS its history; there is
//! no "drag message 3 above message 1"). That is exactly the "leaf
//! sequence" carve-out F3 draws, stated against this model rather than
//! asserted in the abstract: `entries` is legitimately a `seq`. Deletion
//! (retracting a turn) uses `seqDelete`, which removes an index — not a
//! move-to-trash reparent; a future "soft delete" would be a `deleted`
//! flag on the entry map, not a structural change.
//!
//! If a later graph client needs actual structure (a tool-call tree with
//! collapsible sub-turns that can be reparented, say) it must NOT reuse
//! this pattern — it waits for F3's parent-register mechanism.

const std = @import("std");
const Allocator = std.mem.Allocator;

const stemma = @import("stemma");
const GraphDoc = @import("graph.zig");
const Document = @import("Document.zig");
const Buffers = @import("Buffers.zig");
const subbuffer = @import("subbuffer.zig");
const command = @import("command.zig");

const TranscriptDoc = @This();

graph: GraphDoc = .{},

const entries_key = "entries";

/// Origin constructor: a fresh transcript, with its root `entries`
/// sequence created locally. Exactly ONE replica in a transcript's
/// lifetime should call `create` — mirrors `Document`'s peer model, where
/// the owning replica is `init`ed and every other participant is cloned
/// FROM it (`Document.addPeer`'s doc comment), never independently
/// `init`ed. Two independent `create` calls would each mint their own
/// competing "entries" list under the same root key: ObjectDoc's map
/// conflict resolution picks a deterministic winner (see `ObjectDoc.
/// ValueRef.mapGet`), but the LOSER's entries silently drop out of the
/// winning replica's view — a real footgun `create` cannot detect (a
/// virgin doc has no way to know whether it's "the first"), so this is a
/// documented discipline, not a structurally enforced one. Every joining
/// participant calls `open`.
pub fn create(gpa: Allocator, agent_name: []const u8) Allocator.Error!TranscriptDoc {
    var g = try GraphDoc.init(gpa, agent_name);
    errdefer g.deinit(gpa);
    _ = try g.set(gpa, null, entries_key, .list);
    return .{ .graph = g };
}

/// Joining constructor: bootstrap from another replica's full history
/// (`bytes` from `GraphDoc.serialize`/`eventsSince`), then register the
/// local agent identity. `entries` arrives with the merged bytes — never
/// created locally, so no competing-root-list race is possible here.
pub fn open(gpa: Allocator, agent_name: []const u8, bytes: []const u8) GraphDoc.MergeError!TranscriptDoc {
    var g = try GraphDoc.open(gpa, agent_name, bytes);
    errdefer g.deinit(gpa);
    if (g.root().mapGet(entries_key) == null) return error.Corrupt;
    // The documented split-brain footgun (two independent create()s merged
    // = two concurrent entries lists, one silently shadowed) made
    // DETECTABLE: a conflicted root key here means someone violated the
    // one-create rule — refuse rather than show half the transcript.
    if (g.root().mapConflictCount(entries_key) > 1) return error.Corrupt;
    return .{ .graph = g };
}

pub fn deinit(self: *TranscriptDoc, gpa: Allocator) void {
    self.graph.deinit(gpa);
}

fn entriesRef(self: *const TranscriptDoc) GraphDoc.ValueRef {
    return self.graph.root().mapGet(entries_key).?;
}

/// Number of entries.
pub fn count(self: *const TranscriptDoc) usize {
    return self.entriesRef().listLen();
}

/// A read handle onto one entry (`role`/`ts`/`text`/`node` — its own
/// `ObjId`, the identity `graph.zig`'s `NodeRef` wraps for anything that
/// needs to name this entry outside the local replica).
pub const Entry = struct {
    ref: GraphDoc.ValueRef,

    pub fn node(self: Entry) GraphDoc.ObjId {
        return self.ref.objId().?;
    }
    pub fn role(self: Entry) []const u8 {
        return self.ref.mapGet("role").?.asStr();
    }
    pub fn timestamp(self: Entry) i64 {
        return self.ref.mapGet("ts").?.asInt();
    }
    /// The entry body's text object id — pass to `TranscriptDoc.editText`.
    pub fn textObj(self: Entry) GraphDoc.ObjId {
        return self.ref.mapGet("text").?.objId().?;
    }
    /// The entry body's current content. Caller owns.
    pub fn text(self: Entry, gpa: Allocator) Allocator.Error![]u8 {
        return self.ref.mapGet("text").?.textRope().toOwnedSlice(gpa);
    }
};

/// The `i`-th entry, in append order (append order IS transcript order —
/// see the module doc comment on why that's a `seq`, not structure).
pub fn at(self: *const TranscriptDoc, index: usize) Entry {
    return .{ .ref = self.entriesRef().listAt(index) };
}

/// Append a new entry: `role` (e.g. "user"/"agent"/"tool"), a caller-
/// supplied timestamp, and its initial body text. Returns the entry's
/// `ObjId` (mint a `NodeRef` from it via `self.graph.nodeRef` to name it
/// portably — e.g. for a subbuffer identity fact; see `fill` below).
pub fn append(self: *TranscriptDoc, gpa: Allocator, role: []const u8, ts: i64, initial_text: []const u8) Allocator.Error!GraphDoc.ObjId {
    const entries = self.entriesRef().objId().?;
    const entry = (try self.graph.seqAppend(gpa, entries, .map)).?;
    _ = try self.graph.set(gpa, entry, "role", .{ .str = role });
    _ = try self.graph.set(gpa, entry, "ts", .{ .int = ts });
    const text_obj = (try self.graph.set(gpa, entry, "text", .text)).?;
    if (initial_text.len > 0) _ = try self.graph.textInsert(gpa, text_obj, 0, initial_text);
    return entry;
}

/// Edit an entry's body in place — a real CRDT text edit on the entry's
/// `text` object (`Entry.textObj`), collaboratively mergeable exactly
/// like a `Document`'s text.
pub fn editText(self: *TranscriptDoc, gpa: Allocator, text_obj: GraphDoc.ObjId, byte_offset: usize, content: []const u8) Allocator.Error!void {
    _ = try self.graph.textInsert(gpa, text_obj, byte_offset, content);
}

pub fn deleteText(self: *TranscriptDoc, gpa: Allocator, text_obj: GraphDoc.ObjId, range: stemma.Range) Allocator.Error!void {
    _ = try self.graph.textDelete(gpa, text_obj, range);
}

// ── The projection skeleton (§2.6) ────────────────────────────────────
//
// `graph.zig`'s module doc comment explains why this is a concrete `fill`
// rather than the generic `Projection`/`ReconcileMode` union §2.6
// sketches. What follows is that one concrete instance.

/// The `renderInto`/subbuffer peer identity `fill` authors content as and
/// claims id-spans under.
pub const projection_author = "agent-transcript";
/// Subbuffer fact name carrying an entry's `NodeRef` export token — the
/// graph↔text identity bridge §2.6 names ("subbuffer id-spans are the
/// existing text-side identity bridge; use them"). The fact's VALUE is
/// the raw token bytes (`GraphDoc.NodeRef.token`), not further encoded —
/// `SubBuffer.facts` stores arbitrary bytes, not just printable text.
pub const node_fact = "node";

/// Render `tr` into `doc` as READ-ONLY text: one row per entry, `"role:
/// text"` (an entry whose body contains newlines renders as-is — its
/// claimed span covers the whole entry, not just its first physical
/// line). Reclaims (drops ALL of `doc`'s existing claims, then re-claims)
/// one subbuffer id-span per row on EVERY call — a full re-fill, not an
/// incremental patch — carrying fact `node_fact` = the entry's portable
/// `NodeRef` token. `subs.at(doc, some_offset)` then answers "which graph
/// node produced the byte under the caret" without any position-based
/// guessing (exactly the id-span mechanism `subbuffer.zig`/`doc/
/// editable-projection.md` already use for dired's rows).
///
/// `doc` is assumed to be a buffer's `Editor.doc` where the OWNING
/// `Buffers.Buffer.read_only` has been set `true` (see `openBuffer`
/// below) — `fill` itself doesn't need to know that; it authors through
/// `command.renderInto`, which (like `Context.render`) bypasses
/// read-only by design: read-only blocks `edit` (interactive typing),
/// never `render`/`renderInto` (model-driven production).
///
/// ## Why read-only (the ReconcileMode question, honestly)
/// §2.6's `ReconcileMode` names three strategies: `on_save`, `live`,
/// `authoritative`. NONE of them is what this slice ships, and that's a
/// documented choice, not an oversight:
/// - `on_save` (dired's shipped design) is wrong for a transcript: it
///   reconciles gathered edits against an external authority (the
///   filesystem) at a save point. A transcript has no external authority
///   to reconcile against — the graph doc IS the truth, live, always.
/// - `live` is the RIGHT long-term mode for an editable transcript (edit
///   a past turn's text in place, see it merge) but is explicitly
///   UNDESIGNED (D1, north-star-plan.md §7.1: "region-atomic commit
///   points are a hypothesis, not a design"). Shipping it now would mean
///   faking a design that doesn't exist yet.
/// - `authoritative` doesn't fit either: a transcript is not a
///   single-writer/latest-wins feed like a media-player's seek position;
///   its entries are genuinely CRDT-mergeable content.
///
/// So this projection is `.read_only`: `edit` on the buffer is refused
/// (the existing `Buffer.read_only` flag — no new mechanism), and content
/// only changes via re-`fill`. That's a real, honest reconcile mode in
/// its own right, not a stand-in for the other two — and it still proves
/// the two things a projection must prove before reconcile can even be
/// discussed: `fill` renders the model correctly, and the identity map
/// threads graph identity through to buffer byte ranges without loss
/// across re-fills and merges. Making entries editable IN the buffer
/// waits on D1.
pub fn fill(gpa: Allocator, tr: *const TranscriptDoc, doc: *Document, subs: *subbuffer.SubBuffers) command.RenderError!void {
    const Span = struct { start: usize, end: usize, node: GraphDoc.ObjId };
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(gpa);
    var spans: std.ArrayList(Span) = .empty;
    defer spans.deinit(gpa);

    const n = tr.count();
    for (0..n) |i| {
        const e = tr.at(i);
        const body = try e.text(gpa);
        defer gpa.free(body);
        const start = text.items.len;
        try text.print(gpa, "{s}: {s}", .{ e.role(), body });
        try spans.append(gpa, .{ .start = start, .end = text.items.len, .node = e.node() });
        if (i + 1 < n) try text.append(gpa, '\n');
    }

    const old_len = doc.text().byteLen();
    try command.renderInto(gpa, doc, .plugin, projection_author, &.{
        .{ .range = .{ .start = 0, .end = old_len }, .bytes = text.items },
    });

    subs.dropDoc(gpa, doc);
    for (spans.items) |sp| {
        const sub = try subs.claim(gpa, doc, .{ .start = sp.start, .end = sp.end });
        const ref = try tr.graph.nodeRef(gpa, sp.node);
        defer ref.free(gpa);
        try sub.putFact(gpa, node_fact, ref.token);
    }
}

/// Create a read-only, tool-backed buffer suitable for `fill` — the
/// tool-buffer machinery `dired`/`magit` use (`Buffer.read_only`,
/// `Editor.setToolBacking`), wired up host-side instead of from a wasm
/// guest's `on_fill` (per `graph.zig`'s "where the graph-side plugin code
/// runs": this client's model AND its projection are host/in-process).
pub fn openBuffer(gpa: Allocator, buffers: *Buffers, display_name: []const u8) Buffers.Error!Buffers.Id {
    const id = try buffers.create(gpa, display_name);
    const buf = buffers.get(id).?;
    buf.read_only = true;
    try buf.editor.setToolBacking(gpa, projection_author);
    return id;
}

// ── Tests ───────────────────────────────────────────────────────────

const t = std.testing;

test "TranscriptDoc: append/read/edit" {
    const gpa = t.allocator;
    var tr = try TranscriptDoc.create(gpa, "alice");
    defer tr.deinit(gpa);

    _ = try tr.append(gpa, "user", 100, "hello");
    const agent_node = try tr.append(gpa, "agent", 101, "hi there");
    try t.expectEqual(@as(usize, 2), tr.count());

    const e0 = tr.at(0);
    try t.expectEqualStrings("user", e0.role());
    try t.expectEqual(@as(i64, 100), e0.timestamp());
    const b0 = try e0.text(gpa);
    defer gpa.free(b0);
    try t.expectEqualStrings("hello", b0);

    const e1 = tr.at(1);
    try t.expectEqual(agent_node, e1.node());

    // Edit entry 1's body in place.
    try tr.editText(gpa, e1.textObj(), 2, "XX");
    const b1 = try tr.at(1).text(gpa);
    defer gpa.free(b1);
    try t.expectEqualStrings("hiXX there", b1);
}

test "TranscriptDoc: two replicas converge; joiner never races the origin's entries list" {
    const gpa = t.allocator;
    var origin = try TranscriptDoc.create(gpa, "alice");
    defer origin.deinit(gpa);
    _ = try origin.append(gpa, "user", 1, "one");

    const bytes = try origin.graph.serialize(gpa);
    defer gpa.free(bytes);
    var joiner = try TranscriptDoc.open(gpa, "bob", bytes);
    defer joiner.deinit(gpa);
    try t.expectEqual(@as(usize, 1), joiner.count());

    _ = try joiner.append(gpa, "agent", 2, "two");

    const origin_v = try origin.graph.version(gpa);
    defer gpa.free(origin_v);
    const batch = try joiner.graph.eventsSince(gpa, origin_v);
    defer gpa.free(batch);
    const changes = try origin.graph.merge(gpa, batch);
    defer gpa.free(changes);

    try t.expectEqual(@as(usize, 2), origin.count());
    try t.expectEqualStrings("agent", origin.at(1).role());
    const txt = try origin.at(1).text(gpa);
    defer gpa.free(txt);
    try t.expectEqualStrings("two", txt);
    // Frontier equality, matching graph.zig's convergence rigor — content
    // agreement alone can mask an unconverged frontier.
    const ov = try origin.graph.version(gpa);
    defer gpa.free(ov);
    const jv = try joiner.graph.version(gpa);
    defer gpa.free(jv);
    try t.expectEqual(GraphDoc.VersionOrder.equal, try origin.graph.compareVersions(gpa, ov, jv));
}

test "Projection.fill: entries render to text; each row's subbuffer carries the right NodeRef" {
    const gpa = t.allocator;
    var tr = try TranscriptDoc.create(gpa, "alice");
    defer tr.deinit(gpa);
    const n0 = try tr.append(gpa, "user", 1, "hi");
    const n1 = try tr.append(gpa, "agent", 2, "yo");

    var doc = try Document.init(gpa, "user");
    defer doc.deinit(gpa);
    var subs: subbuffer.SubBuffers = .empty;
    defer subs.deinit(gpa);

    try fill(gpa, &tr, &doc, &subs);

    const got = try doc.text().toOwnedSlice(gpa);
    defer gpa.free(got);
    try t.expectEqualStrings("user: hi\nagent: yo", got);

    const ref0 = try tr.graph.nodeRef(gpa, n0);
    defer ref0.free(gpa);
    const ref1 = try tr.graph.nodeRef(gpa, n1);
    defer ref1.free(gpa);

    const sub0 = subs.at(&doc, 0).?;
    try t.expectEqualStrings(ref0.token, sub0.fact(node_fact).?);
    const sub1 = subs.at(&doc, "user: hi\n".len).?;
    try t.expectEqualStrings(ref1.token, sub1.fact(node_fact).?);
}

test "Projection.fill: a second append re-fills without losing the mapping" {
    const gpa = t.allocator;
    var tr = try TranscriptDoc.create(gpa, "alice");
    defer tr.deinit(gpa);
    const n0 = try tr.append(gpa, "user", 1, "hi");

    var doc = try Document.init(gpa, "user");
    defer doc.deinit(gpa);
    var subs: subbuffer.SubBuffers = .empty;
    defer subs.deinit(gpa);

    try fill(gpa, &tr, &doc, &subs);
    const n1 = try tr.append(gpa, "agent", 2, "yo");
    try fill(gpa, &tr, &doc, &subs);

    const got = try doc.text().toOwnedSlice(gpa);
    defer gpa.free(got);
    try t.expectEqualStrings("user: hi\nagent: yo", got);

    // Exactly two live claims (the old ones were dropped, not leaked
    // alongside fresh duplicates).
    try t.expectEqual(@as(usize, 2), subs.list.items.len);

    const ref0 = try tr.graph.nodeRef(gpa, n0);
    defer ref0.free(gpa);
    const ref1 = try tr.graph.nodeRef(gpa, n1);
    defer ref1.free(gpa);
    try t.expectEqualStrings(ref0.token, subs.at(&doc, 0).?.fact(node_fact).?);
    try t.expectEqualStrings(ref1.token, subs.at(&doc, "user: hi\n".len).?.fact(node_fact).?);
}

test "Projection.fill: merging a second replica's append updates the projection" {
    const gpa = t.allocator;
    var origin = try TranscriptDoc.create(gpa, "alice");
    defer origin.deinit(gpa);
    _ = try origin.append(gpa, "user", 1, "hi");

    var doc = try Document.init(gpa, "user");
    defer doc.deinit(gpa);
    var subs: subbuffer.SubBuffers = .empty;
    defer subs.deinit(gpa);
    try fill(gpa, &origin, &doc, &subs);

    const bytes = try origin.graph.serialize(gpa);
    defer gpa.free(bytes);
    var joiner = try TranscriptDoc.open(gpa, "bob", bytes);
    defer joiner.deinit(gpa);
    const n1 = try joiner.append(gpa, "agent", 2, "yo");

    const origin_v = try origin.graph.version(gpa);
    defer gpa.free(origin_v);
    const batch = try joiner.graph.eventsSince(gpa, origin_v);
    defer gpa.free(batch);
    const changes = try origin.graph.merge(gpa, batch);
    defer gpa.free(changes);

    try fill(gpa, &origin, &doc, &subs);
    const got = try doc.text().toOwnedSlice(gpa);
    defer gpa.free(got);
    try t.expectEqualStrings("user: hi\nagent: yo", got);

    // `n1` is a `joiner`-LOCAL ObjId (agent numbering doesn't cross
    // replicas — the whole reason `NodeRef` exists); mint its portable
    // token from `joiner` and use THAT to check the fact `fill` wrote on
    // `origin`'s (post-merge) buffer.
    const joiner_ref1 = try joiner.graph.nodeRef(gpa, n1);
    defer joiner_ref1.free(gpa);
    try t.expectEqualStrings(joiner_ref1.token, subs.at(&doc, "user: hi\n".len).?.fact(node_fact).?);
}

test {
    std.testing.refAllDecls(@This());
}
