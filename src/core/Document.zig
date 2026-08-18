//! Document — a buffer as a CRDT replica, where **every mutator is a
//! peer**: the user, plugins, host agents, remote collaborators. Solo
//! editing is the degenerate one-replica case.
//!
//! ## The peer model (no shortcuts)
//! The user peer edits the authoritative replica directly — that IS the
//! degenerate case, and it keeps the input→commit path allocation-only
//! (no await, no lock, no channel). Every other peer holds a literal
//! shadow `stemma.TextDoc` replica of its own:
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
const TextDoc = stemma.TextDoc;

pub const EventAnchor = TextDoc.EventAnchor;
pub const AnchorSide = TextDoc.AnchorSide;
pub const AnchorHandle = stemma.AnchorSet.Handle;

const Document = @This();

doc: TextDoc = .empty,
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
    replica: TextDoc,
    name: []u8,
};

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
    return self.doc.text();
}

/// The current version frontier as an opaque portable token. Caller owns.
pub fn version(self: *const Document, gpa: Allocator) Error![]u8 {
    return self.doc.version(gpa);
}

/// Immutable snapshot of the current head. Caller owns.
pub fn snapshot(self: *const Document, gpa: Allocator) Error!Snapshot {
    return .{
        .rope = self.doc.text().snapshot(),
        .version = try self.doc.version(gpa),
    };
}

// ── The user peer (hot path) ────────────────────────────────────────
// Direct edits on the authoritative replica: record events, apply to
// the rope, log the commit. Allocation is the only system interaction.

pub fn insert(self: *Document, gpa: Allocator, byte_offset: usize, bytes: []const u8) Error!void {
    var pre = self.doc.text().snapshot();
    defer pre.deinit(gpa);
    const edit = try self.doc.insert(gpa, byte_offset, bytes);
    try self.commitEdits(gpa, .user, &.{edit}, &pre);
}

pub fn delete(self: *Document, gpa: Allocator, range: Range) Error!void {
    var pre = self.doc.text().snapshot();
    defer pre.deinit(gpa);
    const edit = try self.doc.delete(gpa, range);
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
    var pre = self.doc.text().snapshot();
    defer pre.deinit(gpa);
    var edits: std.ArrayList(Edit) = .empty;
    defer edits.deinit(gpa);
    var i = items.len;
    while (i > 0) {
        i -= 1;
        const r = items[i];
        if (!r.range.isEmpty()) {
            try edits.append(gpa, try self.doc.delete(gpa, r.range));
        }
        if (r.bytes.len > 0) {
            try edits.append(gpa, try self.doc.insert(gpa, r.range.start, r.bytes));
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
pub fn addPeer(self: *Document, gpa: Allocator, name: []const u8) AddPeerError!PeerId {
    if (std.mem.eql(u8, name, self.user_name)) return error.DuplicatePeer;
    for (self.peers.items) |slot| {
        if (slot) |p| if (std.mem.eql(u8, p.name, name)) return error.DuplicatePeer;
    }

    // A partial base cannot bootstrap a peer replica until realized —
    // peers (plugins, backings) wait for the content they would edit.
    const history = try self.doc.serialize(gpa);
    defer gpa.free(history);
    var replica = TextDoc.open(gpa, history) catch |e| switch (e) {
        error.Corrupt, error.MissingDependency => unreachable, // trusted local encode
        error.Unrealized => unreachable, // editing replicas are always realized
        else => |err| return err,
    };
    errdefer replica.deinit(gpa);
    try replica.setAgent(gpa, name);

    const owned_name = try gpa.dupe(u8, name);
    errdefer gpa.free(owned_name);
    // Reuse a freed slot if any, else append.
    for (self.peers.items, 0..) |slot, i| {
        if (slot == null) {
            self.peers.items[i] = .{ .replica = replica, .name = owned_name };
            return @enumFromInt(i + 1);
        }
    }
    try self.peers.append(gpa, .{ .replica = replica, .name = owned_name });
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
    return peer.replica.merge(gpa, batch) catch |e| switch (e) {
        error.Corrupt, error.MissingDependency => unreachable, // trusted local sync
        error.Unrealized => unreachable, // editing replicas are always realized
        else => |err| return err,
    };
}

/// Sync the peer to the main head and return an immutable snapshot of
/// it — the version the peer's next op batch will be stated against.
pub fn peerSnapshot(self: *Document, gpa: Allocator, id: PeerId) Error!Snapshot {
    const edits = try self.peerPull(gpa, id);
    gpa.free(edits);
    const peer = self.peerAt(id);
    return .{
        .rope = peer.replica.text().snapshot(),
        .version = try peer.replica.version(gpa),
    };
}

/// Apply an op to the peer's own replica. `byte_offset` is valid against
/// the peer's last snapshot/pull — nothing else edits this replica, so
/// the stated version and the replica's frontier are the same thing.
pub fn peerInsert(self: *Document, gpa: Allocator, id: PeerId, byte_offset: usize, bytes: []const u8) Error!void {
    _ = try self.peerAt(id).replica.insert(gpa, byte_offset, bytes);
}

pub fn peerDelete(self: *Document, gpa: Allocator, id: PeerId, range: Range) Error!void {
    _ = try self.peerAt(id).replica.delete(gpa, range);
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
    var pre = self.doc.text().snapshot();
    defer pre.deinit(gpa);
    const edits = self.doc.merge(gpa, batch) catch |e| switch (e) {
        error.Corrupt, error.MissingDependency => unreachable, // trusted local sync
        error.Unrealized => unreachable, // editing replicas are always realized
        else => |err| return err,
    };
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
    const edits = peer.replica.merge(gpa, batch) catch |e| switch (e) {
        error.Corrupt, error.MissingDependency => unreachable, // trusted local sync
        error.Unrealized => unreachable, // editing replicas are always realized
        else => |err| return err,
    };
    gpa.free(edits);
}

/// Read access to a peer replica's text (the backing mirror's diff base).
pub fn peerText(self: *const Document, id: PeerId) *const Rope {
    return self.peers.items[id.index()].?.replica.text();
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
    const rope = self.doc.text();
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

pub const ExportAnchorError = TextDoc.AnchorError;

/// A portable identity anchor for `offset` at the current head: names
/// the character's inserting event, survives concurrent edits, resolves
/// on any replica that has seen the event. `EventAnchor.agent` is
/// gpa-owned.
pub fn exportAnchor(self: *const Document, gpa: Allocator, offset: usize, side: AnchorSide) ExportAnchorError!EventAnchor {
    return self.doc.anchorAt(gpa, offset, side);
}

/// Resolve identity anchors to offsets at the current head (deleted
/// targets collapse to their deletion point). One history replay for
/// the whole batch.
pub fn resolveAnchors(self: *const Document, gpa: Allocator, anchors: []const EventAnchor, out: []usize) ExportAnchorError!void {
    return self.doc.resolveAnchors(gpa, anchors, out);
}

// ── Versions ────────────────────────────────────────────────────────

pub const VersionOrder = TextDoc.VersionOrder;

/// Causal relation between two version tokens known to this replica.
pub fn compareVersions(self: *const Document, gpa: Allocator, a: []const u8, b: []const u8) TextDoc.MergeError!VersionOrder {
    return self.doc.compareVersions(gpa, a, b);
}

/// The text as it was at `version_token` (time travel; O(history)).
/// Caller owns the rope.
pub fn textAt(self: *const Document, gpa: Allocator, version_token: []const u8) TextDoc.MergeError!Rope {
    return self.doc.materializeAt(gpa, version_token);
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

pub const BaseChunk = TextDoc.BaseChunk;
pub const AgentWatermark = TextDoc.AgentWatermark;
pub const BaseHole = TextDoc.BaseHole;

/// Replace this (still virgin: no events, no peers, empty rope)
/// document with a partially realized replica of a compacted remote
/// document. The user agent is re-registered on the new history.
pub fn adoptPartial(
    self: *Document,
    gpa: Allocator,
    base_version: []const u8,
    watermarks: []const AgentWatermark,
    chunks: []const BaseChunk,
) (Error || error{Corrupt})!void {
    assert(self.doc.history.eventCount() == 0);
    assert(self.log.items.len == 0);
    for (self.peers.items) |slot| assert(slot == null);
    var fresh = try TextDoc.openPartial(gpa, base_version, watermarks, chunks);
    errdefer fresh.deinit(gpa);
    try fresh.setAgent(gpa, self.user_name);
    self.doc.deinit(gpa);
    self.doc = fresh;
}

/// Replace this (still virgin) document's content wholesale with a
/// compacted base — the bulk-load path (O(content), zero events; a
/// per-scalar event load of a 4MB file costs 4M events). Identity
/// anchors into the loaded content resolve as `error.Compacted`; use
/// for large files where that trade is right.
pub fn adoptContent(self: *Document, gpa: Allocator, content: []const u8) Error!void {
    assert(self.doc.history.eventCount() == 0);
    assert(self.log.items.len == 0);
    for (self.peers.items) |slot| assert(slot == null);
    var fresh = TextDoc.openFromContent(gpa, content) catch |e| switch (e) {
        error.Corrupt => unreachable, // self-produced token
        else => |err| return err,
    };
    errdefer fresh.deinit(gpa);
    try fresh.setAgent(gpa, self.user_name);
    self.doc.deinit(gpa);
    self.doc = fresh;
}

/// The unrealized base spans (fetch list; `base_offset` keys pristine
/// base coordinates, `cur_offset` tracks the rope). Borrows.
pub fn unrealizedBase(self: *const Document) []const BaseHole {
    return self.doc.unrealizedBase();
}

pub fn baseRealized(self: *const Document) bool {
    return self.doc.baseRealized();
}

/// Supply one unrealized span's pristine content. Not an edit: no
/// commit, offsets and anchors unaffected.
pub fn realizeBase(self: *Document, gpa: Allocator, base_offset: usize, content: []const u8) (Error || error{Corrupt})!void {
    return self.doc.realizeBase(gpa, base_offset, content);
}

/// Compact all history at-or-before `stable_token` into a frozen base
/// (host-side: makes a freshly loaded file servable as a partial base
/// and bounds graph growth). The commit log is retained — its version
/// tokens may reference the compacted horizon; consumers compare token
/// bytes before causal comparison.
pub fn compact(self: *Document, gpa: Allocator, stable_token: []const u8) TextDoc.CompactError!void {
    try self.doc.compact(gpa, stable_token);
}

/// Raw stemma event count since the last compaction (or since genesis,
/// uncompacted) — the walker's replay cost scales with this.
pub fn eventCount(self: *const Document) usize {
    return self.doc.history.eventCount();
}

/// Per-agent compaction watermarks for serving `adoptPartial` peers.
/// Names borrow from the document; caller frees the slice only.
pub fn agentWatermarks(self: *const Document, gpa: Allocator) Error![]AgentWatermark {
    return self.doc.agentWatermarks(gpa);
}

// ── Remote sync (the wire's entry points) ───────────────────────────

/// Merge a remote peer's encoded event batch (stemma wire bytes) into
/// the document; commits log under the reserved `remote` author (never
/// undoable locally, never re-broadcast as ours). Returns whether text
/// changed. Duplicate events are no-ops — blind retransmit is safe.
pub fn mergeRemote(self: *Document, gpa: Allocator, batch: []const u8) TextDoc.MergeError!bool {
    var pre = self.doc.text().snapshot();
    defer pre.deinit(gpa);
    const edits = try self.doc.merge(gpa, batch);
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
