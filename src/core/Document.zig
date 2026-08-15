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
const Range = stemma.Range;
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

/// `user` is the interactive peer (the authoritative replica's own
/// agent); other values are handles from `addPeer`.
pub const PeerId = enum(u32) {
    user = 0,
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
/// old-space) with their inserted bytes concatenated in `bytes`, plus
/// the post-commit version token. Everything owned by the log.
pub const Commit = struct {
    author: PeerId,
    version: []u8,
    patches: []Patch,
    bytes: []u8,

    /// Inserted content of `patches[i]`.
    pub fn insertedBytes(self: *const Commit, i: usize) []const u8 {
        var start: usize = 0;
        for (self.patches[0..i]) |p| start += p.inserted;
        return self.bytes[start..][0..self.patches[i].inserted];
    }

    fn deinit(self: *Commit, gpa: Allocator) void {
        gpa.free(self.version);
        gpa.free(self.patches);
        gpa.free(self.bytes);
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
    const edit = try self.doc.insert(gpa, byte_offset, bytes);
    try self.commitEdits(gpa, .user, &.{edit});
}

pub fn delete(self: *Document, gpa: Allocator, range: Range) Error!void {
    const edit = try self.doc.delete(gpa, range);
    try self.commitEdits(gpa, .user, &.{edit});
}

// ── Peers ───────────────────────────────────────────────────────────

pub const AddPeerError = Error || error{DuplicatePeer};

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

    const history = try self.doc.serialize(gpa);
    defer gpa.free(history);
    var replica = TextDoc.open(gpa, history) catch |e| switch (e) {
        error.Corrupt, error.MissingDependency => unreachable, // trusted local encode
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
    const edits = self.doc.merge(gpa, batch) catch |e| switch (e) {
        error.Corrupt, error.MissingDependency => unreachable, // trusted local sync
        else => |err| return err,
    };
    defer gpa.free(edits);
    if (edits.len == 0) return false;
    try self.commitEdits(gpa, id, edits);
    return true;
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

/// Shift anchors through the edit stream, compose it into patches,
/// slice their inserted bytes from the post-commit rope, and log.
fn commitEdits(self: *Document, gpa: Allocator, author: PeerId, edits: []const Edit) Error!void {
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
    const rope = self.doc.text();
    var delta: isize = 0;
    for (patches) |p| {
        const new_off: usize = @intCast(@as(isize, @intCast(p.offset)) + delta);
        if (p.inserted > 0) {
            const dest = try bytes.addManyAsSlice(gpa, p.inserted);
            var sr = rope.streamReader(.{ .start = new_off, .end = new_off + p.inserted }, &.{});
            sr.interface.readSliceAll(dest) catch unreachable; // range is in bounds
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
