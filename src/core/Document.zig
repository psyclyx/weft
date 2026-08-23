//! Document — a buffer as a CRDT replica, where **every mutator is a
//! peer**: the user, plugins, host agents, remote collaborators. Solo
//! editing is the degenerate one-replica case.
//!
//! ## The substrate (W7a — doc/w7-rebase.md)
//! `Document` is backed by `stemma.ObjectDoc`, the one graph doc-core,
//! degenerated to its simplest shape: a root map holding exactly one key
//! (`body_key`, below) whose value is a single text object — "text is a
//! degenerate graph doc" (w7-rebase.md §2.3). Every text operation routes
//! through that one object (`self.body`, an `ObjId` resolved once and
//! cached — see its doc comment for why that caching is safe). This
//! replaces the prior `stemma.TextDoc` backing; the public API below is
//! UNCHANGED in shape (every consumer — `Editor`, `backing.zig`,
//! `Collab`, `PartialDoc`, `command.checkDocRegion`, `grants.zig` —
//! compiles and behaves identically), so this note is the only place
//! that needs to know.
//!
//! ## The peer model (no shortcuts)
//! The user peer edits the authoritative replica directly — that IS the
//! degenerate case, and it keeps the input→commit path allocation-only
//! (no await, no lock, no channel). Every other peer holds a literal
//! shadow `stemma.ObjectDoc` replica of its own (heavier than the old
//! `TextDoc` shadow — a whole graph doc per peer, not just a rope + one
//! sequence's history — accepted per w7-rebase.md §3.2):
//!
//! 1. `peerSnapshot` syncs the shadow to the main replica and hands out
//!    an immutable rope snapshot + opaque version token — the version the
//!    peer's work is valid against.
//! 2. The peer computes against the snapshot, then applies its ops to its
//!    *own replica* (`peerInsert`/`peerDelete` — byte offsets valid at
//!    the snapshot it took, because nothing else edits that replica).
//! 3. `peerCommit` merges the shadow's new events into the main replica
//!    exactly as a remote collaborator's batch: `eventsSince` → `merge`.
//!    The CRDT transforms the ops against everything that landed since
//!    the snapshot. "Buffer changed during operation" is not expressible.
//!
//! ## Commits and subscription
//! Every mutation lands as a `Commit` in an append-only log: composed
//! non-overlapping patches (old-space) with their inserted bytes and the
//! post-commit version token. Subscription is pull-based — hold a cursor
//! (an index), drain `commitsSince(cursor)` when you please — so the
//! commit path never runs foreign code and never blocks. Replaying
//! commits from any cursor reconstructs the exact text (the causal
//! subscription property).
//!
//! ## Positions
//! No bare offset crosses this API without a version: snapshot offsets
//! are valid at `Snapshot.version`, peer op offsets at the peer's last
//! snapshot, anchor resolutions at the current head (single-threaded
//! access, so "current" is well-defined at the call). Durable positions
//! are anchors: `addAnchor` (cheap local, auto-shifted through every
//! commit) or `exportAnchor` (portable identity anchors that survive
//! concurrent edits, resolvable on any replica).
//!
//! The rope may carry unrealized holes when a document is opened lazily
//! (stemma's lazy-content contract); `Snapshot.isFullyRealized` reports
//! it, and content readers inherit stemma's deterministic panic on hole
//! access. Replica ropes produced by editing are always realized.

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const stemma = @import("stemma");
const patch = @import("patch.zig");
pub const Patch = patch.Patch;
const Rope = stemma.Rope;
const Edit = stemma.Edit;
/// A byte range `[start, end)`. Public so command/authority callers can
/// name the unit `Context.edit` and the peer API operate on.
pub const Range = stemma.Range;
const Bias = stemma.Bias;
const ObjectDoc = stemma.ObjectDoc;
const ObjId = ObjectDoc.ObjId;

/// The document's one text object lives under this root-map key.
/// `w7-rebase.md`'s brief named "body" (attributing it to a "transcript
/// precedent") or "text" as the two candidates; checked against the
/// actual code rather than the brief's paraphrase (this project's own
/// method, per w7-rebase.md's own header) — `transcript.zig`'s `Entry`
/// (the one other place weft puts a single text object under a map key,
/// `transcript.zig:163,186`) uses `"text"`, not `"body"` ("body" appears
/// only as a local variable name in one `graph.zig` test, not a key
/// convention anywhere). Picking `"text"` matches the real precedent.
const body_key = "text";

/// The portable identity-anchor type (agent name + seq + side). `TextDoc`
/// and `ObjectDoc` don't each define their own — both alias stemma's one
/// `seq_walker.EventAnchor`/`AnchorSide` (stemma-unification.md §3 step 3,
/// delta 3), so this facade's re-export and `grants.zig`'s `EventAnchor`/
/// `AnchorSide` (which alias THESE, not `stemma.TextDoc` again — one
/// source, not two independently-arrived-at aliases of the same type) are
/// the SAME type as each other by construction, not just by coincidence.
///
pub const EventAnchor = stemma.EventAnchor;
pub const AnchorSide = stemma.AnchorSide;
pub const AnchorHandle = stemma.AnchorSet.Handle;

const Document = @This();

doc: ObjectDoc = .empty,
/// `self.doc`'s body text object — resolved once (`resolveBody`) and
/// cached, not re-resolved on every use. Why that is safe: `ObjId` IS
/// the creation event's portable `EventId` (`ObjectDoc.zig`'s `Node` doc
/// comment), and `obj_index` (the `EventId → node` table `resolveObjNode`
/// consults) is populated once at creation and NEVER touched by `merge`
/// (new events only ever ADD entries) or by `compact` (its own doc
/// comment: "this is what makes an ObjId obtained before compaction still
/// resolve afterward"). So `self.body` stays valid across every mutation
/// this file ever applies to `self.doc` IN PLACE — `insert`/`delete`/
/// `mergeRemote`/`compact`/`peerCommit`, all of it.
/// The one time it goes stale: `self.doc` itself is replaced WHOLESALE by
/// a fresh `ObjectDoc` value (`adoptContent`/`adoptPartial` — the bulk-
/// load and partial-checkout constructors), which is a different graph
/// with its own, independently-assigned `AgentId` numbering (`ObjId`'s
/// `agent` field is a REPLICA-LOCAL handle — `ObjectDoc.zig`'s own doc
/// comment: "never transport one to another replica"). Both call sites
/// re-run `resolveBody` on the new `self.doc` immediately after the
/// swap; nothing else ever replaces `self.doc`.
body: ObjId = undefined,
anchors: stemma.AnchorSet = .empty,
user_name: []u8 = &.{},
peers: std.ArrayList(?Peer) = .empty,
log: std.ArrayList(Commit) = .empty,
/// The local peer's granted grade on THIS replica. `.own` for solo/owned
/// buffers; set to the host's grant by the collab wire handler when we
/// join a shared document (`.view` until the grant arrives — fail safe).
/// Document never consults it: it is storage the authority gate
/// (`command.Context.gradeOn`) reads. It lives here, not on `Buffer`,
/// because the collab handler can reach the Document but not the Buffer.
my_grant: @import("authority.zig").Grade = .own,

/// `user` is the interactive peer (the authoritative replica's own
/// agent); other values are handles from `addPeer` — except `remote`,
/// the reserved author for batches merged off the wire.
pub const PeerId = enum(u32) {
    user = 0,
    remote = std.math.maxInt(u32),
    _,

    fn index(self: PeerId) usize {
        assert(self != .user);
        return @intFromEnum(self) - 1;
    }
};

const Peer = struct {
    replica: ObjectDoc,
    /// This peer's OWN resolution of `body_key` on its OWN replica — see
    /// `Document.body`'s doc comment for why a peer can't just borrow the
    /// main document's `ObjId` (replica-local `AgentId` numbering).
    body: ObjId,
    name: []u8,
};

/// Resolve `body_key` on a just-constructed `ObjectDoc` (fresh from
/// `openFromContent`/`openPartial`/`open`) to its `ObjId`, once. Every
/// `Document`-shaped `ObjectDoc` — the main replica and every peer's
/// shadow — is constructed with exactly this one root key, so the lookup
/// never fails; `.?` twice over documents that construction itself.
fn resolveBody(doc: *const ObjectDoc) ObjId {
    return doc.root().mapGet(body_key).?.objId().?;
}

/// One materialized mutation: `patches` (ascending, non-overlapping,
/// old-space) with their inserted bytes concatenated in `bytes` and
/// their removed bytes concatenated in `removed_bytes`, plus the
/// post-commit version token. Carrying both sides makes every commit
/// *invertible* — the currency of per-peer op-inverse undo — and the
/// log self-contained for subscribers. Everything owned by the log.
pub const Commit = struct {
    author: PeerId,
    version: []u8,
    patches: []Patch,
    bytes: []u8,
    removed_bytes: []u8,

    /// Inserted content of `patches[i]`.
    pub fn insertedBytes(self: *const Commit, i: usize) []const u8 {
        var start: usize = 0;
        for (self.patches[0..i]) |p| start += p.inserted;
        return self.bytes[start..][0..self.patches[i].inserted];
    }

    /// Removed (pre-commit) content of `patches[i]`.
    pub fn removedBytes(self: *const Commit, i: usize) []const u8 {
        var start: usize = 0;
        for (self.patches[0..i]) |p| start += p.removed;
        return self.removed_bytes[start..][0..self.patches[i].removed];
    }

    fn deinit(self: *Commit, gpa: Allocator) void {
        gpa.free(self.version);
        gpa.free(self.patches);
        gpa.free(self.bytes);
        gpa.free(self.removed_bytes);
    }
};

/// An immutable view: O(1) rope snapshot + the opaque version token it
/// is valid at. Offsets derived from `rope` are meaningful only paired
/// with `version`.
pub const Snapshot = struct {
    rope: Rope,
    version: []u8,

    pub fn isFullyRealized(self: *const Snapshot) bool {
        return self.rope.isRealized(.{ .start = 0, .end = self.rope.byteLen() });
    }

    pub fn deinit(self: *Snapshot, gpa: Allocator) void {
        self.rope.deinit(gpa);
        gpa.free(self.version);
        self.* = undefined;
    }
};

pub const Error = Allocator.Error;

pub fn init(gpa: Allocator, user_agent: []const u8) Error!Document {
    var self: Document = .{};
    errdefer self.deinit(gpa);
    self.user_name = try gpa.dupe(u8, user_agent);
    // The body text object needs a real creation event — `ObjectDoc`'s
    // root is always a map (`ensureRoot`), so there is no way to have
    // `root.map -> text_key: text` without one, unlike `TextDoc.empty`,
    // which starts genuinely eventless. Minting that creation event under
    // a SYNTHETIC founder agent (`openFromContent`'s own content-hash-
    // derived "base-…" identity — here hashing the empty string under
    // `body_key`) rather than under `user_agent` is not cosmetic:
    // `ObjectDoc.compact`'s per-agent-prefix guard refuses whenever a
    // SINGLE agent both creates a text object and later edits it in the
    // causal past of the compaction point — named explicitly in
    // `compact`'s own doc comment as its first worked example. If the
    // founding `map_set` were authored by `user_agent`, EVERY keystroke
    // that agent ever makes on this document is, forever, in that
    // event's causal future — `compact` would refuse unconditionally,
    // the first real client of this exact guard. A dedicated founder
    // agent keeps the founder's timeline at exactly one event (never
    // itself a compaction target — only `text_ins`/`text_del` ever fold)
    // and the user's timeline a clean, foldable prefix — the same
    // "founder creates, a different agent edits" shape
    // `object_tests.zig`'s compaction battery already exercises for
    // exactly this reason. Reusing `openFromContent`'s existing synthetic-
    // agent machinery (rather than hand-rolling a `"<user>#founder"` name)
    // needed no new naming scheme and no new code path — see the W7a
    // report for the alternative considered and why this one shipped.
    self.doc = ObjectDoc.openFromContent(gpa, "", body_key) catch |e| switch (e) {
        error.Corrupt => unreachable, // "" is trivially valid UTF-8
        else => |err| return err,
    };
    self.body = resolveBody(&self.doc);
    try self.doc.setAgent(gpa, user_agent);
    return self;
}

pub fn deinit(self: *Document, gpa: Allocator) void {
    self.doc.deinit(gpa);
    self.anchors.deinit(gpa);
    gpa.free(self.user_name);
    for (self.peers.items) |*slot| {
        if (slot.*) |*p| {
            p.replica.deinit(gpa);
            gpa.free(p.name);
        }
    }
    self.peers.deinit(gpa);
    for (self.log.items) |*c| c.deinit(gpa);
    self.log.deinit(gpa);
    self.* = .{};
}

/// Read access to the materialized document (the current head).
pub fn text(self: *const Document) *const Rope {
    return self.doc.ref(self.body).textRope();
}

/// The current version frontier as an opaque portable token. Caller owns.
pub fn version(self: *const Document, gpa: Allocator) Error![]u8 {
    return self.doc.version(gpa);
}

/// Immutable snapshot of the current head. Caller owns.
pub fn snapshot(self: *const Document, gpa: Allocator) Error!Snapshot {
    return .{
        .rope = self.text().snapshot(),
        .version = try self.doc.version(gpa),
    };
}

/// Adapt an `ObjectDoc.merge` change stream to the flat `[]Edit` stream
/// `TextDoc.merge` returned directly (w7-rebase.md's "Change→Edit
/// adaptation"). `Document` is a one-text-node doc, so the only change
/// any well-formed batch from another `Document`-shaped peer ever
/// produces is `.text{obj: body, edit}` — `ObjectDoc.appendTextChange`
/// already coalesces contiguous same-object insert/delete runs into one
/// entry, exactly the batching `TextDoc.merge` did itself, so this is a
/// filter, not a re-batch. A `.map`/`.list_ins`/`.list_del`/`.structure`
/// change can only arise from a batch that mutated some OTHER object,
/// which no `Document`-shaped peer in this codebase ever creates (the
/// founder's one `map_set` at construction is the only non-text write,
/// authored once, never repeated) — skipped rather than asserted, so a
/// future wire extension or a malformed batch degrades to "those bytes
/// changed nothing observable here" instead of a remotely triggerable
/// panic on attacker-controlled input.
fn editsFromChanges(gpa: Allocator, changes: []const ObjectDoc.Change, body: ObjId) Error![]Edit {
    var out: std.ArrayList(Edit) = .empty;
    errdefer out.deinit(gpa);
    for (changes) |c| switch (c) {
        .text => |tc| if (std.meta.eql(tc.obj, body)) try out.append(gpa, tc.edit),
        // Dropped by design (see doc comment), but loudly enough to debug a
        // malformed batch or an unhandled future wire extension.
        else => std.log.warn("document: non-text graph change on a text share dropped ({s})", .{@tagName(c)}),
    };
    return out.toOwnedSlice(gpa);
}

// ── The user peer (hot path) ────────────────────────────────────────
// Direct edits on the authoritative replica: record events, apply to
// the rope, log the commit. Allocation is the only system interaction.

pub fn insert(self: *Document, gpa: Allocator, byte_offset: usize, bytes: []const u8) Error!void {
    var pre = self.text().snapshot();
    defer pre.deinit(gpa);
    const edit = try self.doc.textInsert(gpa, self.body, byte_offset, bytes);
    try self.commitEdits(gpa, .user, &.{edit}, &pre);
}

pub fn delete(self: *Document, gpa: Allocator, range: Range) Error!void {
    var pre = self.text().snapshot();
    defer pre.deinit(gpa);
    const edit = try self.doc.textDelete(gpa, self.body, range);
    try self.commitEdits(gpa, .user, &.{edit}, &pre);
}

pub const Replacement = struct {
    range: Range,
    bytes: []const u8,
};

/// Apply several non-overlapping replacements (ascending by offset) as
/// ONE user commit — the currency of undo/redo and of any command that
/// must be a single undoable unit. Applied descending so earlier
/// offsets stay valid while later ones mutate.
pub fn replaceAll(self: *Document, gpa: Allocator, items: []const Replacement) Error!void {
    var pre = self.text().snapshot();
    defer pre.deinit(gpa);
    var edits: std.ArrayList(Edit) = .empty;
    defer edits.deinit(gpa);
    var i = items.len;
    while (i > 0) {
        i -= 1;
        const r = items[i];
        if (!r.range.isEmpty()) {
            try edits.append(gpa, try self.doc.textDelete(gpa, self.body, r.range));
        }
        if (r.bytes.len > 0) {
            try edits.append(gpa, try self.doc.textInsert(gpa, self.body, r.range.start, r.bytes));
        }
    }
    try self.commitEdits(gpa, .user, edits.items, &pre);
}

// ── Peers ───────────────────────────────────────────────────────────

pub const AddPeerError = Error || error{ DuplicatePeer, Unrealized };

/// Register a mutator as a peer: a full shadow replica bootstrapped from
/// the main replica's history. `name` must be unique among live peers
/// (it is the CRDT agent name — also the concurrent-insert tiebreak).
/// Re-adding a previously removed peer's name continues its event
/// numbering, which is causally sound.
///
/// A plain one-call bootstrap (`serialize` → `open`), exactly the shape
/// `TextDoc` used. An earlier W7a draft split this into a two-phase
/// dance to work around a stemma v0.5.0 bootstrap-ordering bug (a base +
/// live edits for `body` in one `merge` call could corrupt or clobber —
/// see stemma's `ObjectDoc.merge` doc comment on `adoptTextBaseRope`/the
/// text-base-metadata-before-`historyPhase` ordering it now documents).
/// Fixed upstream in stemma v0.5.1 (`build.zig.zon`'s pin) — verified
/// against this exact shape (a founder-only base AND a real, non-empty,
/// edited-then-compacted base, each WITH live events layered on top,
/// bootstrapped in one call) by this file's own test battery, so the
/// workaround is gone, not just hidden.
pub fn addPeer(self: *Document, gpa: Allocator, name: []const u8) AddPeerError!PeerId {
    if (std.mem.eql(u8, name, self.user_name)) return error.DuplicatePeer;
    for (self.peers.items) |slot| {
        if (slot) |p| if (std.mem.eql(u8, p.name, name)) return error.DuplicatePeer;
    }

    // A partial base cannot bootstrap a peer replica until realized —
    // peers (plugins, backings) wait for the content they would edit.
    const history = try self.doc.serialize(gpa);
    defer gpa.free(history);
    var replica = ObjectDoc.open(gpa, history) catch |e| switch (e) {
        error.Corrupt, error.MissingDependency => unreachable, // trusted local encode
        error.Unrealized => unreachable, // editing replicas are always realized
        else => |err| return err,
    };
    errdefer replica.deinit(gpa);
    try replica.setAgent(gpa, name);
    const replica_body = resolveBody(&replica);

    const owned_name = try gpa.dupe(u8, name);
    errdefer gpa.free(owned_name);
    // Reuse a freed slot if any, else append.
    for (self.peers.items, 0..) |slot, i| {
        if (slot == null) {
            self.peers.items[i] = .{ .replica = replica, .body = replica_body, .name = owned_name };
            return @enumFromInt(i + 1);
        }
    }
    try self.peers.append(gpa, .{ .replica = replica, .body = replica_body, .name = owned_name });
    return @enumFromInt(self.peers.items.len);
}

/// A named sub-identity spawned on this document: its own CRDT peer (so
/// its edits are its own selective-undo unit — distinct from the user and
/// from every other spawned peer) capped at a grade. The public promotion
/// of the internal plugin-peer pattern: REPL comint output, agent session
/// peers, and any tool that must author as *itself*, not the user.
pub const Spawned = struct {
    id: PeerId,
    /// `min(owner_grant, grant_max)` — authority flows down from the
    /// document owner, never up.
    grade: @import("authority.zig").Grade,
};

/// Register `name` as a peer on this document, its grade capped at
/// `min(my_grant, grant_max)`. Thin, gated public wrapper over `addPeer`.
pub fn spawnPeer(self: *Document, gpa: Allocator, name: []const u8, grant_max: @import("authority.zig").Grade) AddPeerError!Spawned {
    const id = try self.addPeer(gpa, name);
    return .{ .id = id, .grade = @import("authority.zig").gradeMin(self.my_grant, grant_max) };
}

/// Get-or-create the peer named `name` (idempotent). The core of the
/// per-document "my peer on this doc" pattern that both the Lua bridge and
/// the Zig ABI need: re-adding a live name recovers its id rather than
/// erroring, so a plugin can resolve its peer against whatever doc is
/// active without bookkeeping.
pub fn peerNamed(self: *Document, gpa: Allocator, name: []const u8) AddPeerError!PeerId {
    return self.addPeer(gpa, name) catch |e| switch (e) {
        error.DuplicatePeer => {
            for (self.peers.items, 0..) |slot, i| {
                if (slot) |p| if (std.mem.eql(u8, p.name, name)) return @enumFromInt(i + 1);
            }
            unreachable; // DuplicatePeer means the name is live
        },
        else => |err| return err,
    };
}

pub fn removePeer(self: *Document, gpa: Allocator, id: PeerId) void {
    const slot = &self.peers.items[id.index()];
    var p = slot.*.?;
    p.replica.deinit(gpa);
    gpa.free(p.name);
    slot.* = null;
}

fn peerAt(self: *Document, id: PeerId) *Peer {
    return &self.peers.items[id.index()].?;
}

/// Sync the peer's replica up to the main head. Returns the edit stream
/// applied to the *peer's* view (caller owns; shift peer-side positions
/// through it, or ignore it and take a fresh snapshot).
pub fn peerPull(self: *Document, gpa: Allocator, id: PeerId) Error![]Edit {
    const peer = self.peerAt(id);
    const shadow_v = peer.replica.version(gpa) catch |e| return e;
    defer gpa.free(shadow_v);
    const batch = self.doc.eventsSince(gpa, shadow_v) catch |e| switch (e) {
        error.Corrupt => unreachable, // trusted local token
        else => |err| return err,
    };
    defer gpa.free(batch);
    const changes = peer.replica.merge(gpa, batch) catch |e| switch (e) {
        error.Corrupt, error.MissingDependency => unreachable, // trusted local sync
        error.Unrealized => unreachable, // editing replicas are always realized
        else => |err| return err,
    };
    defer gpa.free(changes);
    return editsFromChanges(gpa, changes, peer.body);
}

/// Sync the peer to the main head and return an immutable snapshot of
/// it — the version the peer's next op batch will be stated against.
pub fn peerSnapshot(self: *Document, gpa: Allocator, id: PeerId) Error!Snapshot {
    const edits = try self.peerPull(gpa, id);
    gpa.free(edits);
    const peer = self.peerAt(id);
    return .{
        .rope = peer.replica.ref(peer.body).textRope().snapshot(),
        .version = try peer.replica.version(gpa),
    };
}

/// Apply an op to the peer's own replica. `byte_offset` is valid against
/// the peer's last snapshot/pull — nothing else edits this replica, so
/// the stated version and the replica's frontier are the same thing.
pub fn peerInsert(self: *Document, gpa: Allocator, id: PeerId, byte_offset: usize, bytes: []const u8) Error!void {
    const peer = self.peerAt(id);
    _ = try peer.replica.textInsert(gpa, peer.body, byte_offset, bytes);
}

pub fn peerDelete(self: *Document, gpa: Allocator, id: PeerId, range: Range) Error!void {
    const peer = self.peerAt(id);
    _ = try peer.replica.textDelete(gpa, peer.body, range);
}

/// Merge the peer's uncommitted ops into the main replica — exactly a
/// remote collaborator's batch: the CRDT transforms them against
/// everything committed since the peer's snapshot. Returns whether any
/// text changed (a new commit was logged).
pub fn peerCommit(self: *Document, gpa: Allocator, id: PeerId) Error!bool {
    const peer = self.peerAt(id);
    const head_v = try self.doc.version(gpa);
    defer gpa.free(head_v);
    const batch = peer.replica.eventsSince(gpa, head_v) catch |e| switch (e) {
        error.Corrupt => unreachable, // trusted local token
        else => |err| return err,
    };
    defer gpa.free(batch);
    var pre = self.text().snapshot();
    defer pre.deinit(gpa);
    const changes = self.doc.merge(gpa, batch) catch |e| switch (e) {
        error.Corrupt, error.MissingDependency => unreachable, // trusted local sync
        error.Unrealized => unreachable, // editing replicas are always realized
        else => |err| return err,
    };
    defer gpa.free(changes);
    const edits = try editsFromChanges(gpa, changes, self.body);
    defer gpa.free(edits);
    if (edits.len == 0) return false;
    try self.commitEdits(gpa, id, edits, &pre);
    return true;
}

/// Apply several non-overlapping replacements (ascending by offset) as ONE
/// commit authored by peer `id` — the peer-authored analogue of
/// `replaceAll`. Syncs the peer's shadow to head first, so `items` offsets
/// (head coordinates) are valid, then applies descending and merges as the
/// peer. The currency of a spawned peer's own undoable unit.
pub fn peerReplaceAll(self: *Document, gpa: Allocator, id: PeerId, items: []const Replacement) Error!void {
    const edits = try self.peerPull(gpa, id); // shadow ← head; nothing else edits it
    gpa.free(edits);
    var i = items.len;
    while (i > 0) {
        i -= 1;
        const r = items[i];
        if (!r.range.isEmpty()) try self.peerDelete(gpa, id, r.range);
        if (r.bytes.len > 0) try self.peerInsert(gpa, id, r.range.start, r.bytes);
    }
    _ = try self.peerCommit(gpa, id);
}

/// Sync a peer's replica to an exact (possibly past) version of the
/// main replica: merge exactly the events in `version_token`'s causal
/// past that the shadow lacks — never the head's extras. The backing
/// peer's save flow needs this: after a save the disk holds the *saved*
/// version's content even when the head has already moved on.
pub fn peerSyncTo(self: *Document, gpa: Allocator, id: PeerId, version_token: []const u8) Error!void {
    const peer = self.peerAt(id);
    const shadow_v = try peer.replica.version(gpa);
    defer gpa.free(shadow_v);
    const batch = self.doc.eventsBetween(gpa, shadow_v, version_token) catch |e| switch (e) {
        error.Corrupt, error.MissingDependency => unreachable, // trusted local tokens
        error.Unrealized => unreachable, // editing replicas are always realized
        else => |err| return err,
    };
    defer gpa.free(batch);
    const changes = peer.replica.merge(gpa, batch) catch |e| switch (e) {
        error.Corrupt, error.MissingDependency => unreachable, // trusted local sync
        error.Unrealized => unreachable, // editing replicas are always realized
        else => |err| return err,
    };
    gpa.free(changes);
}

/// Read access to a peer replica's text (the backing mirror's diff base).
pub fn peerText(self: *const Document, id: PeerId) *const Rope {
    const peer = &self.peers.items[id.index()].?;
    return peer.replica.ref(peer.body).textRope();
}

// ── Commit log / subscription ───────────────────────────────────────

/// Commits at-or-after `cursor` (a count of commits already seen; start
/// at 0 or at `commitCount()`), in causal application order. Valid until
/// the next mutation.
pub fn commitsSince(self: *const Document, cursor: usize) []const Commit {
    return self.log.items[cursor..];
}

pub fn commitCount(self: *const Document) usize {
    return self.log.items.len;
}

pub fn commitAt(self: *const Document, index: usize) *const Commit {
    return &self.log.items[index];
}

/// Shift anchors through the edit stream, compose it into patches,
/// slice inserted bytes from the post-commit rope and removed bytes
/// from the pre-commit snapshot, and log.
fn commitEdits(self: *Document, gpa: Allocator, author: PeerId, edits: []const Edit, pre: *const Rope) Error!void {
    var comp: patch.Composer = .empty;
    defer comp.deinit(gpa);
    for (edits) |e| {
        self.anchors.shift(e);
        try comp.push(gpa, e);
    }
    if (comp.items().len == 0) return;

    const patches = try gpa.dupe(Patch, comp.items());
    errdefer gpa.free(patches);
    var bytes: std.ArrayList(u8) = .empty;
    errdefer bytes.deinit(gpa);
    var removed: std.ArrayList(u8) = .empty;
    errdefer removed.deinit(gpa);
    const rope = self.text();
    var delta: isize = 0;
    for (patches) |p| {
        const new_off: usize = @intCast(@as(isize, @intCast(p.offset)) + delta);
        if (p.inserted > 0) {
            const dest = try bytes.addManyAsSlice(gpa, p.inserted);
            var sr = rope.streamReader(.{ .start = new_off, .end = new_off + p.inserted }, &.{});
            sr.interface.readSliceAll(dest) catch unreachable; // range is in bounds
        }
        if (p.removed > 0) {
            const dest = try removed.addManyAsSlice(gpa, p.removed);
            var sr = pre.streamReader(.{ .start = p.offset, .end = p.offset + p.removed }, &.{});
            sr.interface.readSliceAll(dest) catch unreachable; // old-space, in bounds
        }
        delta += @as(isize, @intCast(p.inserted)) - @as(isize, @intCast(p.removed));
    }

    const token = try self.doc.version(gpa);
    errdefer gpa.free(token);
    try self.log.append(gpa, .{
        .author = author,
        .version = token,
        .patches = patches,
        .bytes = try bytes.toOwnedSlice(gpa),
        .removed_bytes = try removed.toOwnedSlice(gpa),
    });
}

// ── Anchors ─────────────────────────────────────────────────────────

/// A cheap local anchor at `offset` (valid at the current head),
/// auto-shifted through every subsequent commit.
pub fn addAnchor(self: *Document, gpa: Allocator, offset: usize, bias: Bias) Error!AnchorHandle {
    return self.anchors.add(gpa, .{ .offset = offset, .bias = bias });
}

/// The anchor's offset at the current head.
pub fn anchorOffset(self: *const Document, h: AnchorHandle) usize {
    return self.anchors.get(h).offset;
}

pub fn removeAnchor(self: *Document, h: AnchorHandle) void {
    self.anchors.remove(h);
}

pub const ExportAnchorError = ObjectDoc.AnchorError;

/// A portable identity anchor for `offset` at the current head: names
/// the character's inserting event, survives concurrent edits, resolves
/// on any replica that has seen the event. `EventAnchor.agent` is
/// gpa-owned.
pub fn exportAnchor(self: *const Document, gpa: Allocator, offset: usize, side: AnchorSide) ExportAnchorError!EventAnchor {
    return self.doc.objectAnchorAt(gpa, self.body, offset, side);
}

/// Resolve identity anchors to offsets at the current head (deleted
/// targets collapse to their deletion point). One history replay for
/// the whole batch.
pub fn resolveAnchors(self: *const Document, gpa: Allocator, anchors: []const EventAnchor, out: []usize) ExportAnchorError!void {
    return self.doc.resolveObjectAnchors(gpa, self.body, anchors, out);
}

// ── Versions ────────────────────────────────────────────────────────

pub const VersionOrder = ObjectDoc.VersionOrder;

/// Causal relation between two version tokens known to this replica.
pub fn compareVersions(self: *const Document, gpa: Allocator, a: []const u8, b: []const u8) ObjectDoc.MergeError!VersionOrder {
    return self.doc.compareVersions(gpa, a, b);
}

/// The text as it was at `version_token` (time travel; O(history)).
/// Caller owns the rope.
pub fn textAt(self: *const Document, gpa: Allocator, version_token: []const u8) ObjectDoc.MergeError!Rope {
    return self.doc.materializeAt(gpa, self.body, version_token);
}

test {
    std.testing.refAllDecls(@This());
}

// ── Partial checkout (stemma hole-bases) ────────────────────────────
// A huge remote document arrives as a compacted base described by a
// chunk table; unfetched spans are holes. Sync works immediately;
// content follows the viewport (`realizeBase` per span). Merges that
// land inside unrealized spans reject whole with `error.Unrealized`
// (via `mergeRemote`) — realize, then merge the same batch again.

pub const BaseChunk = ObjectDoc.BaseChunk;
pub const AgentWatermark = ObjectDoc.AgentWatermark;
pub const BaseHole = ObjectDoc.BaseHole;

/// A document fresh from `init` and never yet mutated always carries
/// EXACTLY this many events: the one founder `map_set` that mints the
/// body text object (`init`'s doc comment). Unlike `TextDoc.empty`
/// (genuinely zero events), `ObjectDoc`'s root-map shape can't exist
/// without it — the "virgin document" precondition `adoptPartial`/
/// `adoptContent` assert is this constant, not zero.
const founder_event_count = 1;

/// Replace this (still virgin: exactly the founder event, no other
/// events, no peers, empty rope — see `founder_event_count`) document
/// with a partially realized replica of a compacted remote document. The
/// user agent is re-registered on the new history.
pub fn adoptPartial(
    self: *Document,
    gpa: Allocator,
    base_version: []const u8,
    watermarks: []const AgentWatermark,
    chunks: []const BaseChunk,
) (Error || error{Corrupt})!void {
    assert(self.doc.eventCount() == founder_event_count);
    assert(self.log.items.len == 0);
    for (self.peers.items) |slot| assert(slot == null);
    var fresh = try ObjectDoc.openPartial(gpa, base_version, watermarks, body_key, chunks);
    errdefer fresh.deinit(gpa);
    try fresh.setAgent(gpa, self.user_name);
    self.doc.deinit(gpa);
    self.doc = fresh;
    self.body = resolveBody(&self.doc);
}

/// Replace this (still virgin) document's content wholesale with a
/// compacted base — the bulk-load path (O(content) cost; a per-scalar
/// event load of a 4MB file costs 4M events, this costs exactly
/// `founder_event_count`). Identity anchors into the loaded content
/// resolve as `error.Compacted`; use for large files where that trade is
/// right.
///
/// NOTE (parity, not a new bug): `ObjectDoc.openFromContent` validates
/// `content` is UTF-8 the same way `TextDoc.openFromContent` did
/// (`std.unicode.utf8CountCodepoints` over the base chunk), so its
/// `error.Corrupt` is reachable for non-UTF-8 file bytes — `Editor.
/// openFile` does not validate before calling this. The PRE-EXISTING
/// `TextDoc`-backed code already treated this as `unreachable` (comment:
/// "self-produced token", which only covers the OTHER `error.Corrupt`
/// causes in `openPartial`/`openFromContent` — duplicate agent names, a
/// malformed synthetic token — not invalid UTF-8 content). Reproduced
/// here unchanged for drop-in parity; not introduced by this rebase, not
/// fixed by it either (out of W7a's scope — see the report).
pub fn adoptContent(self: *Document, gpa: Allocator, content: []const u8) Error!void {
    assert(self.doc.eventCount() == founder_event_count);
    assert(self.log.items.len == 0);
    for (self.peers.items) |slot| assert(slot == null);
    var fresh = ObjectDoc.openFromContent(gpa, content, body_key) catch |e| switch (e) {
        error.Corrupt => unreachable, // self-produced token / parity, see doc comment above
        else => |err| return err,
    };
    errdefer fresh.deinit(gpa);
    try fresh.setAgent(gpa, self.user_name);
    self.doc.deinit(gpa);
    self.doc = fresh;
    self.body = resolveBody(&self.doc);
}

/// The unrealized base spans (fetch list; `base_offset` keys pristine
/// base coordinates, `cur_offset` tracks the rope). Borrows.
pub fn unrealizedBase(self: *const Document) []const BaseHole {
    return self.doc.unrealizedBase(self.body);
}

pub fn baseRealized(self: *const Document) bool {
    return self.doc.baseRealized(self.body);
}

/// Supply one unrealized span's pristine content. Not an edit: no
/// commit, offsets and anchors unaffected.
pub fn realizeBase(self: *Document, gpa: Allocator, base_offset: usize, content: []const u8) (Error || error{Corrupt})!void {
    return self.doc.realizeBase(gpa, self.body, base_offset, content);
}

/// Compact all history at-or-before `stable_token` into a frozen base
/// (host-side: makes a freshly loaded file servable as a partial base
/// and bounds graph growth). The commit log is retained — its version
/// tokens may reference the compacted horizon; consumers compare token
/// bytes before causal comparison.
pub fn compact(self: *Document, gpa: Allocator, stable_token: []const u8) ObjectDoc.CompactError!void {
    try self.doc.compact(gpa, stable_token);
}

/// Raw stemma event count since the last compaction (or since genesis,
/// uncompacted) — the walker's replay cost scales with this. Never below
/// `founder_event_count`: the founder's creation event is never itself a
/// compaction target (only `text_ins`/`text_del` ever fold — `ObjectDoc.
/// compact`'s doc comment).
pub fn eventCount(self: *const Document) usize {
    return self.doc.eventCount();
}

/// Per-agent compaction watermarks for serving `adoptPartial` peers.
/// Names borrow from the document, caller frees the slice only.
pub fn agentWatermarks(self: *const Document, gpa: Allocator) Error![]AgentWatermark {
    return self.doc.agentWatermarks(gpa);
}

// ── Remote sync (the wire's entry points) ───────────────────────────

/// Merge a remote peer's encoded event batch (stemma wire bytes) into
/// the document; commits log under the reserved `remote` author (never
/// undoable locally, never re-broadcast as ours). Returns whether text
/// changed. Duplicate events are no-ops — blind retransmit is safe.
pub fn mergeRemote(self: *Document, gpa: Allocator, batch: []const u8) ObjectDoc.MergeError!bool {
    var pre = self.text().snapshot();
    defer pre.deinit(gpa);
    const changes = try self.doc.merge(gpa, batch);
    defer gpa.free(changes);
    const edits = try editsFromChanges(gpa, changes, self.body);
    defer gpa.free(edits);
    if (edits.len == 0) return false;
    try self.commitEdits(gpa, .remote, edits, &pre);
    return true;
}

/// Wire-encode everything a peer holding `remote_version` lacks.
pub fn eventsSince(self: *const Document, gpa: Allocator, remote_version: []const u8) ![]u8 {
    return self.doc.eventsSince(gpa, remote_version);
}

/// The whole history (bootstrap batch for a peer with no frontier).
pub fn serialize(self: *const Document, gpa: Allocator) Error![]u8 {
    return self.doc.serialize(gpa) catch |e| switch (e) {
        error.Unrealized => unreachable, // editing replicas are always realized
        else => |err| return err,
    };
}
