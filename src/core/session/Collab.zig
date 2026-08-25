//! `Collab` — the document-sync driver for ONE document over one channel
//! quad of a `Session`: ops on `base`, presence feed on `base+1`,
//! diagnostics feed on `base+2`, blob/base/fs requests on `base+3`.
//! Multiple `Collab`s on one session are dispatched by `Conn` (which owns
//! the drain); a lone `Collab` may still `tick` itself.

const std = @import("std");
const Allocator = std.mem.Allocator;

const wire = @import("weft_wire");
const Document = @import("../Document.zig");
const layers_mod = @import("../layers.zig");

const Session = @import("Session.zig");
const Access = Session.Access;
const sync_core = @import("sync_core.zig");

const remote_fs_mod = @import("remote_fs.zig");
const BlobOp = remote_fs_mod.BlobOp;
const BlobServer = remote_fs_mod.BlobServer;
const RemoteFs = remote_fs_mod.RemoteFs;
const RemoteFile = remote_fs_mod.RemoteFile;
const serveBase = remote_fs_mod.serveBase;

const PartialDoc = @import("PartialDoc.zig");

const Collab = @This();

gpa: Allocator,
session: *Session,
doc: *Document,
name: []u8,
/// First channel of this document's quad (multiple of 4).
base: u64 = 0,
/// Caller-owned bookkeeping (the editor stores its buffer id).
tag: u64 = 0,
/// Our cursor in this document, published as presence (the caller
/// updates it before each tick).
cursor_offset: usize = 0,
/// The other end of our selection (== cursor_offset when nothing is
/// selected). Published so peers render our selection, not just our
/// caret; the caller sets it alongside cursor_offset.
selection_anchor: usize = 0,
/// Frontier tracking + batch/frontier wire framing — shared with
/// `GraphCollab` (see `sync_core.zig` for exactly what's shared and why
/// the merge call itself isn't).
core: sync_core.SyncCore(Document) = .{},
/// Host side: the grade last announced to this peer for this document,
/// so `push` re-emits a `grant` only when it changes (initial + on any
/// `setPeerAccess`). Unused on the client (which receives, never sends).
last_sent_grant: ?Access = null,
/// Set when a client-role bind lowered this doc's `my_grant` to `.view`
/// (fail-safe join). On teardown we restore `.own` so the doc, kept as a
/// local file after disconnect, is editable again. A plain flag — never
/// read `self.session` at deinit (tests bind with an `undefined` one).
client_bound: bool = false,
presence_layer: ?*layers_mod.Layer = null,
last_presence: ?PublishedPresence = null,
/// Peer presence is stored in its portable CRDT form. Offsets are derived only
/// at the display edge, against this replica's current projection; retaining a
/// projected offset here would silently attach it to the wrong character after
/// concurrent edits.
presence: std.ArrayList(PeerPresence) = .empty,
/// Publish our own cursor (a headless hub has none — it relays).
publish_presence: bool = true,
/// Hub relay: re-publish received presence to the other sessions.
relay: ?*const fn (?*anyopaque, key: u64, payload: []const u8) void = null,
relay_ctx: ?*anyopaque = null,
/// Agent side: serve blob requests for the hosted file.
blob_server: ?*BlobServer = null,
/// Host side: serve .peer filesystem requests, confined to a shared root,
/// gated by `fs_grant` (default deny — a peer gets nothing unless the host
/// opened a root and granted access).
peer_fs_root: ?*@import("../rooted_fs.zig").RootedFs = null,
fs_grant: @import("../peer_fs.zig").Grant = .{},
peer_fs_service: ?@import("../peer_fs.zig").Service = null,
/// Client side: correlate .peer fs replies (LIST/READ/WRITE).
remote_fs: ?*RemoteFs = null,
/// Client side: fold blob replies into the read-only viewer.
remote_file: ?*RemoteFile = null,
/// Client side: editable partial checkout (stemma hole-bases).
partial: ?*PartialDoc = null,
/// Host side: forward this layer's spans over the wire (feed ch 2).
export_diag_layer: ?*layers_mod.Layer = null,
export_diag_gen: usize = 0,
/// Client side: imported host-scoped diagnostics land here.
import_diag_layer: ?*layers_mod.Layer = null,

const PresencePosition = struct {
    head: Document.EventAnchor,
    selection_anchor: Document.EventAnchor,
    collapsed: bool,
    /// Local input coordinates are only a coalescing cache. They never cross
    /// the wire or resolve on another replica; the portable anchors above are
    /// the presence value.
    source_head: usize,
    source_selection_anchor: usize,

    fn selected(self: *const PresencePosition) Document.EventAnchor {
        return if (self.collapsed) self.head else self.selection_anchor;
    }

    fn deinit(self: *PresencePosition, gpa: Allocator) void {
        gpa.free(self.head.agent);
        if (!self.collapsed) gpa.free(self.selection_anchor.agent);
        self.* = undefined;
    }
};

const SourcePosition = struct {
    head: usize,
    selection_anchor: usize,
};

const PublishedPresence = union(enum) {
    absent: SourcePosition,
    position: PresencePosition,

    fn deinit(self: *PublishedPresence, gpa: Allocator) void {
        switch (self.*) {
            .absent => {},
            .position => |*position| position.deinit(gpa),
        }
        self.* = undefined;
    }
};

pub const PeerPresence = struct {
    name: []u8,
    head: Document.EventAnchor,
    selection_anchor: Document.EventAnchor,
    hue16: u32,

    fn deinit(self: *PeerPresence, gpa: Allocator) void {
        gpa.free(self.name);
        gpa.free(self.head.agent);
        gpa.free(self.selection_anchor.agent);
        self.* = undefined;
    }
};

pub const ResolvedPresence = struct {
    name: []const u8,
    head: usize,
    selection_anchor: usize,
    hue16: u32,
};

pub fn init(gpa: Allocator, session: *Session, doc: *Document, name: []const u8) !Collab {
    return .{
        .gpa = gpa,
        .session = session,
        .doc = doc,
        .name = try gpa.dupe(u8, name),
    };
}

pub fn deinit(self: *Collab) void {
    // A joined doc reverts to solo-owned when its collab goes away
    // (disconnect keeps the buffer as a local file; buffer-close unbinds
    // before the doc is freed — the doc always outlives this).
    if (self.client_bound) self.doc.my_grant = .own;
    self.core.deinit(self.gpa);
    self.clearLastPresence();
    for (self.presence.items) |*peer| peer.deinit(self.gpa);
    self.presence.deinit(self.gpa);
    self.gpa.free(self.name);
}

/// Point at a fresh session after a reconnect: the announce +
/// frontier exchange replays from scratch (idempotent by design —
/// duplicate events are no-ops), presence republishes.
pub fn rebind(self: *Collab, new_session: *Session) void {
    self.session = new_session;
    self.core.rebind(self.gpa);
    // Re-announce the grant after a reconnect (host side); the client
    // keeps its current my_grant so there is no read-only flash.
    self.last_sent_grant = null;
    self.clearLastPresence();
}

fn clearLastPresence(self: *Collab) void {
    if (self.last_presence) |*last| last.deinit(self.gpa);
    self.last_presence = null;
}

/// Per-frame (solo use): drain inbound frames, handle the ones in
/// our quad, then push our changes. Under `Conn` the drain/dispatch
/// happens once for all Collabs instead.
pub fn tick(self: *Collab, cursor_offset: usize) !bool {
    const gpa = self.gpa;
    var changed = false;
    var frames: std.ArrayList(wire.Decoder.Decoded) = .empty;
    defer frames.deinit(gpa);
    try self.session.drain(gpa, &frames);
    for (frames.items) |frame| {
        defer gpa.free(frame.payload);
        changed = (self.handleFrame(frame) catch false) or changed;
    }
    self.cursor_offset = cursor_offset;
    self.selection_anchor = cursor_offset; // solo tick: no selection
    return (try self.push()) or changed;
}

/// Fold one inbound frame belonging to this quad. Frames outside
/// the quad are ignored (returns false). Payload stays caller-owned.
pub fn handleFrame(self: *Collab, frame: wire.Decoder.Decoded) !bool {
    const gpa = self.gpa;
    if (frame.channel < self.base or frame.channel > self.base + 3) return false;
    // A partial client holds off ALL op traffic until the base is
    // adopted — answering a frontier announce now would elicit a
    // full-history bootstrap and defeat the partial checkout.
    if (self.partial) |p| {
        if (p.state != .open and p.state != .unsupported and frame.class == .op) return false;
    }
    var changed = false;
    switch (frame.class) {
        .op => if (frame.channel == self.base) {
            switch (std.enums.fromInt(wire.OpKind, frame.kind) orelse return false) {
                .batch => {
                    // Decode + frontier-track + view-peer admission gate:
                    // shared with the graph driver
                    // (`sync_core.SyncCore.admitBatch`) — a view-only
                    // peer's ops are never admitted to the shared document
                    // (and thus never propagate to other peers), but their
                    // frontier is still tracked so sync stays consistent
                    // and they keep receiving everyone else's edits. The
                    // merge call + its `Unrealized` recovery stay here —
                    // `GraphCollab` has no such branch (see
                    // `sync_core.zig`'s doc comment).
                    const batch = (try self.core.admitBatch(gpa, self.session, frame.payload)) orelse return changed;
                    const merged = self.doc.mergeRemote(gpa, batch) catch |err| blk: {
                        if (err == error.Unrealized) {
                            // Remote edits landed inside spans we
                            // have not fetched: stash the batch,
                            // realize (push() pumps the reads),
                            // merge again on arrival.
                            if (self.partial) |p| try p.stash(batch);
                        } else {
                            std.log.warn("collab: batch rejected: {t}", .{err});
                        }
                        break :blk false;
                    };
                    changed = changed or merged;
                    // A presence feed can legitimately arrive before the op
                    // which introduces its anchor's event. Keep the identity
                    // and try the display projection again after every merge.
                    if (merged) try self.republishPresence();
                },
                .frontier => {
                    try self.core.setTheirFrontier(gpa, frame.payload);
                    try self.sendBatch();
                },
                .share => {}, // connection-level; Conn consumes these
                .grant => {
                    // The host tells us our grade on this document. Only
                    // a client accepts it — a host is the authority and
                    // is never granted by a peer (closes the reverse
                    // vector where a client would gag the host's user).
                    if (self.session.role == .client and frame.payload.len >= 1) {
                        if (std.enums.fromInt(Access, frame.payload[0])) |g| {
                            self.doc.my_grant = g;
                            changed = true;
                        }
                    }
                },
                // Graph-doc-only (W6 slice 1's per-region lease,
                // doc/d1-live-reconcile.md §5): a text doc has no regions
                // to refuse against, so nothing to fold here. Named
                // explicitly rather than caught by an `else` so a THIRD
                // `OpKind` addition still forces a decision at this site.
                .region_refused => {},
            }
        },
        .feed => if (frame.channel == self.base + 2) {
            // Host-scoped diagnostics forwarded off the host:
            // repeated uv start | uv end | uv kind | uv mlen | msg.
            if (self.import_diag_layer) |layer| {
                var spans: std.ArrayList(layers_mod.SpanIn) = .empty;
                defer spans.deinit(gpa);
                var cur: []const u8 = frame.payload;
                while (cur.len > 0) {
                    const s = wire.getUv(&cur) catch break;
                    const e = wire.getUv(&cur) catch break;
                    const k = wire.getUv(&cur) catch break;
                    const ml = wire.getUv(&cur) catch break;
                    if (ml > cur.len) break;
                    const limit = self.doc.text().byteLen();
                    spans.append(gpa, .{
                        .start = @min(@as(usize, @intCast(s)), limit),
                        .end = @min(@as(usize, @intCast(e)), limit),
                        .kind = @intCast(k),
                        .message = cur[0..ml],
                    }) catch break;
                    cur = cur[ml..];
                }
                try layer.publishSpans(gpa, spans.items);
                changed = true;
            }
        } else if (frame.channel == self.base + 1) {
            // Presence is soft state, but its positions are CRDT identities:
            // uv name_len | name | byte present |, when present,
            // anchor head | anchor selection | uv hue16. A missing identity
            // stays retained and resolves after its introducing op arrives;
            // malformed or compacted identities fail closed at the display
            // edge instead of being guessed from a projected offset.
            var cur: []const u8 = frame.payload;
            const nlen = wire.getUv(&cur) catch return false;
            if (nlen > cur.len) return false;
            const peer_name = cur[0..nlen];
            cur = cur[nlen..];
            if (cur.len == 0) return false;
            const present = cur[0];
            cur = cur[1..];
            if (present == 0) {
                self.removePeerPresence(peer_name);
            } else if (present == 1) {
                const head_wire = wire.getAnchor(&cur) catch return false;
                const selection_wire = wire.getAnchor(&cur) catch return false;
                const head_side = std.enums.fromInt(Document.AnchorSide, head_wire.side) orelse return false;
                const selection_side = std.enums.fromInt(Document.AnchorSide, selection_wire.side) orelse return false;
                const hue16 = wire.getUv(&cur) catch return false;
                try self.updatePeerPresence(
                    peer_name,
                    .{ .agent = head_wire.agent, .seq = head_wire.seq, .side = head_side },
                    .{ .agent = selection_wire.agent, .seq = selection_wire.seq, .side = selection_side },
                    @intCast(hue16 & 0xffff),
                );
            } else return false;
            try self.republishPresence();
            changed = true;
            if (self.relay) |r| r(self.relay_ctx, nameKey(peer_name), frame.payload);
        },
        .request => if (frame.channel == self.base + 3) {
            switch (std.enums.fromInt(wire.RequestKind, frame.kind) orelse return false) {
                .call => {
                    // Peek the op: file ops go to the blob server,
                    // base ops are served from our document's base.
                    var peek: []const u8 = frame.payload;
                    _ = wire.getUv(&peek) catch return changed;
                    if (peek.len == 0) return changed;
                    const reply = if (peek[0] >= @intFromEnum(BlobOp.base_open))
                        serveBase(gpa, self.doc, frame.payload) catch return changed
                    else if (self.blob_server) |bs|
                        bs.handle(gpa, frame.payload) catch return changed
                    else
                        return changed;
                    defer gpa.free(reply);
                    try self.session.post(.request, @intFromEnum(wire.RequestKind.ok), self.base + 3, reply);
                },
                .ok => if (self.partial) |p| {
                    const c = p.onReply(self.session, self.base, frame.payload) catch false;
                    changed = changed or c;
                } else if (self.remote_file) |rf| {
                    const c = rf.onReply(frame.payload) catch false;
                    changed = changed or c;
                },
                // .peer filesystem: serve a client's request against the
                // shared root (confined + granted), reply mirroring the id.
                .fs_call => {
                    const peer_fs = @import("../peer_fs.zig");
                    var cur: []const u8 = frame.payload;
                    const id = wire.getUv(&cur) catch return changed;
                    const root = self.peer_fs_root orelse return changed;
                    const resp = peer_fs.handleWithService(gpa, root, self.fs_grant, self.peer_fs_service, cur) catch return changed;
                    defer gpa.free(resp);
                    var reply: std.ArrayList(u8) = .empty;
                    defer reply.deinit(gpa);
                    wire.putUv(gpa, &reply, id) catch return changed;
                    reply.appendSlice(gpa, resp) catch return changed;
                    try self.session.post(.request, @intFromEnum(wire.RequestKind.fs_ok), self.base + 3, reply.items);
                },
                .fs_ok => if (self.remote_fs) |rf| {
                    rf.onReply(gpa, frame.payload) catch {};
                    changed = true;
                },
                else => {},
            }
        },
        .control => {},
    }
    return changed;
}

/// Announce once, then push whenever our head moved; forward
/// diagnostics and presence. Call after the frames of a tick.
pub fn push(self: *Collab) !bool {
    const gpa = self.gpa;
    const live = self.session.liveness();
    if (live != .connected and live != .degraded) return false;

    if (self.partial) |p| {
        try p.requestOpen(self.session, self.base);
        if (p.state != .open and p.state != .unsupported) return false;
        try p.pump(self.session, self.base);
    }

    try self.core.announceOnce(gpa, self.session, self.base, self.doc);

    // Host side: announce the grade we grant this peer on this document
    // (initial + whenever it changes via setPeerAccess/applyGrades), so
    // the client gates its own edits instead of forming a ghost our op
    // admission would silently drop. The client never emits this.
    if (self.session.role == .server and
        (self.last_sent_grant == null or self.last_sent_grant.? != self.session.access))
    {
        self.last_sent_grant = self.session.access;
        const grade: [1]u8 = .{@intFromEnum(self.session.access)};
        try self.session.post(.op, @intFromEnum(wire.OpKind.grant), self.base, &grade);
    }
    try self.core.pushOnMove(gpa, self.session, self.base, self.doc, self.partialSkip());

    // Forward host-scoped diagnostics when they changed.
    if (self.export_diag_layer) |layer| {
        const gen = layer.spanCount() +% blk: {
            var acc: usize = 0;
            for (0..layer.spanCount()) |i| acc +%= layer.resolvedSpan(i).start;
            break :blk acc;
        };
        if (gen != self.export_diag_gen) {
            self.export_diag_gen = gen;
            var payload: std.ArrayList(u8) = .empty;
            defer payload.deinit(gpa);
            for (0..layer.spanCount()) |i| {
                const d = layer.resolvedSpan(i);
                try wire.putUv(gpa, &payload, d.start);
                try wire.putUv(gpa, &payload, d.end);
                try wire.putUv(gpa, &payload, d.kind);
                try wire.putUv(gpa, &payload, d.message.len);
                try payload.appendSlice(gpa, d.message);
            }
            try self.session.postFeed(self.base + 2, 0, payload.items);
        }
    }

    if (self.publish_presence) try self.publishPresence();
    return false;
}

fn publishPresence(self: *Collab) !void {
    // No local movement means the already-published identity remains the
    // right value: remote and local document edits resolve that same identity
    // independently. Avoid replaying CRDT history merely to rediscover it on
    // every idle application wake.
    if (self.last_presence) |last| switch (last) {
        .absent => |prior| if (prior.head == self.cursor_offset and
            prior.selection_anchor == self.selection_anchor) return,
        .position => |prior| if (prior.source_head == self.cursor_offset and
            prior.source_selection_anchor == self.selection_anchor) return,
    };

    var position = self.capturePresence() catch |err| switch (err) {
        // Compaction deliberately erases the identity needed to name an
        // interior position. Absence is safer than a plausible-but-wrong raw
        // offset, and a later move to an anchorable event republishes normally.
        error.Compacted, error.MissingDependency => return self.publishPresenceAbsent(),
        else => return err,
    };
    errdefer position.deinit(self.gpa);

    if (self.last_presence) |*last| switch (last.*) {
        .absent => {},
        .position => |*prior| if (presencePositionEql(prior.*, position)) {
            prior.source_head = position.source_head;
            prior.source_selection_anchor = position.source_selection_anchor;
            position.deinit(self.gpa);
            return;
        },
    };

    var payload: std.ArrayList(u8) = .empty;
    defer payload.deinit(self.gpa);
    try wire.putUv(self.gpa, &payload, self.name.len);
    try payload.appendSlice(self.gpa, self.name);
    try payload.append(self.gpa, 1);
    try putEventAnchor(self.gpa, &payload, position.head);
    try putEventAnchor(self.gpa, &payload, position.selected());
    const hue16: u32 = @intFromFloat(self.session.id.hue() * 65535.0);
    try wire.putUv(self.gpa, &payload, hue16);
    // Coalescing key is per-peer: N cursors never collapse.
    try self.session.postFeed(self.base + 1, nameKey(self.name), payload.items);

    self.clearLastPresence();
    self.last_presence = .{ .position = position };
}

fn publishPresenceAbsent(self: *Collab) !void {
    if (self.last_presence) |last| switch (last) {
        .absent => |prior| if (prior.head == self.cursor_offset and
            prior.selection_anchor == self.selection_anchor) return,
        .position => {},
    };
    var payload: std.ArrayList(u8) = .empty;
    defer payload.deinit(self.gpa);
    try wire.putUv(self.gpa, &payload, self.name.len);
    try payload.appendSlice(self.gpa, self.name);
    try payload.append(self.gpa, 0);
    try self.session.postFeed(self.base + 1, nameKey(self.name), payload.items);
    self.clearLastPresence();
    self.last_presence = .{ .absent = .{
        .head = self.cursor_offset,
        .selection_anchor = self.selection_anchor,
    } };
}

fn capturePresence(self: *const Collab) Document.ExportAnchorError!PresencePosition {
    const head = try self.doc.exportAnchor(self.gpa, self.cursor_offset, .after);
    errdefer self.gpa.free(head.agent);
    if (self.cursor_offset == self.selection_anchor) {
        return .{
            .head = head,
            .selection_anchor = head,
            .collapsed = true,
            .source_head = self.cursor_offset,
            .source_selection_anchor = self.selection_anchor,
        };
    }
    return .{
        .head = head,
        // Editor selections keep their mark left-biased. Preserve that
        // boundary behavior independently of the right-biased caret.
        .selection_anchor = try self.doc.exportAnchor(self.gpa, self.selection_anchor, .before),
        .collapsed = false,
        .source_head = self.cursor_offset,
        .source_selection_anchor = self.selection_anchor,
    };
}

fn putEventAnchor(gpa: Allocator, payload: *std.ArrayList(u8), anchor: Document.EventAnchor) !void {
    try wire.putAnchor(gpa, payload, .{
        .agent = anchor.agent,
        .seq = anchor.seq,
        .side = @intFromEnum(anchor.side),
    });
}

fn eventAnchorEql(a: Document.EventAnchor, b: Document.EventAnchor) bool {
    return a.seq == b.seq and a.side == b.side and std.mem.eql(u8, a.agent, b.agent);
}

fn presencePositionEql(a: PresencePosition, b: PresencePosition) bool {
    return eventAnchorEql(a.head, b.head) and eventAnchorEql(a.selected(), b.selected());
}

fn nameKey(name: []const u8) u64 {
    return std.hash.Fnv1a_64.hash(name);
}

fn updatePeerPresence(
    self: *Collab,
    peer_name: []const u8,
    head: Document.EventAnchor,
    selection_anchor: Document.EventAnchor,
    hue16: u32,
) !void {
    const owned_head = try dupeEventAnchor(self.gpa, head);
    errdefer self.gpa.free(owned_head.agent);
    const owned_selection = try dupeEventAnchor(self.gpa, selection_anchor);
    errdefer self.gpa.free(owned_selection.agent);

    for (self.presence.items) |*peer| {
        if (!std.mem.eql(u8, peer.name, peer_name)) continue;
        self.gpa.free(peer.head.agent);
        self.gpa.free(peer.selection_anchor.agent);
        peer.head = owned_head;
        peer.selection_anchor = owned_selection;
        peer.hue16 = hue16;
        return;
    }

    const owned_name = try self.gpa.dupe(u8, peer_name);
    errdefer self.gpa.free(owned_name);
    try self.presence.append(self.gpa, .{
        .name = owned_name,
        .head = owned_head,
        .selection_anchor = owned_selection,
        .hue16 = hue16,
    });
}

fn dupeEventAnchor(gpa: Allocator, anchor: Document.EventAnchor) !Document.EventAnchor {
    return .{
        .agent = try gpa.dupe(u8, anchor.agent),
        .seq = anchor.seq,
        .side = anchor.side,
    };
}

fn removePeerPresence(self: *Collab, peer_name: []const u8) void {
    for (self.presence.items, 0..) |*peer, i| {
        if (!std.mem.eql(u8, peer.name, peer_name)) continue;
        var removed = self.presence.orderedRemove(i);
        removed.deinit(self.gpa);
        return;
    }
}

pub fn presenceNamed(self: *const Collab, peer_name: []const u8) ?*const PeerPresence {
    for (self.presence.items) |*peer| {
        if (std.mem.eql(u8, peer.name, peer_name)) return peer;
    }
    return null;
}

pub fn resolvePresence(self: *const Collab, peer: *const PeerPresence) ?ResolvedPresence {
    var offsets: [2]usize = undefined;
    self.doc.resolveAnchors(self.gpa, &.{ peer.head, peer.selection_anchor }, &offsets) catch return null;
    return .{
        .name = peer.name,
        .head = offsets[0],
        .selection_anchor = offsets[1],
        .hue16 = peer.hue16,
    };
}

/// Build one presence span per peer: [lo,hi) is the selection (a bare
/// caret when head==anchor), kind carries the identity hue in its low
/// 16 bits plus a bit-16 flag for which end holds the caret. The view
/// decodes both. See `packPresenceKind`.
fn republishPresence(self: *Collab) !void {
    const layer = self.presence_layer orelse return;
    const gpa = self.gpa;
    var spans: std.ArrayList(layers_mod.SpanIn) = .empty;
    defer spans.deinit(gpa);
    for (self.presence.items) |*peer| {
        const resolved = self.resolvePresence(peer) orelse continue;
        try spans.append(gpa, .{
            .start = @min(resolved.head, resolved.selection_anchor),
            .end = @max(resolved.head, resolved.selection_anchor),
            .kind = packPresenceKind(resolved.hue16, resolved.head <= resolved.selection_anchor),
            .message = resolved.name,
        });
    }
    try layer.publishSpans(gpa, spans.items);
}

/// Presence span kind: identity hue in bits 0..15, "caret is at the
/// lower end" in bit 16. Shared with the hub's local union display.
pub fn packPresenceKind(hue16: u32, head_is_start: bool) u32 {
    return (hue16 & 0xffff) | (@as(u32, if (head_is_start) 0 else 1) << 16);
}

/// The no-frontier fallback (`sync_core.sendBatch`'s serialize branch)
/// would ship the whole document as a bootstrap — impossible (and wrong)
/// from a partial checkout; wait for the host's announce and send the
/// delta instead. `sync_core.zig` doesn't know `PartialDoc` exists, so
/// this is computed here and threaded through as `skip`.
fn partialSkip(self: *const Collab) bool {
    return self.core.their_frontier == null and self.partial != null;
}

/// Thin wrapper so the `.frontier` handler's call site reads the same as
/// before the extraction — the actual framing lives in `sync_core.zig`,
/// shared with `GraphCollab`.
fn sendBatch(self: *Collab) !void {
    try self.core.sendBatch(self.gpa, self.session, self.base, self.doc, self.partialSkip());
}

const t = std.testing;

test "presence: a peer selection publishes a colored range with the caret side" {
    const gpa = t.allocator;
    var doc = try Document.init(gpa, "d");
    defer doc.deinit(gpa);
    try doc.insert(gpa, 0, "0123456789");
    var layers: layers_mod.Layers = .empty;
    defer layers.deinit(gpa);
    const layer = try layers.claim(gpa, &doc, "presence", .replicated, "collab");

    // Drive a Collab's presence bookkeeping directly (republish/update
    // never touch the session, so it can be undefined here).
    var c = try Collab.init(gpa, undefined, &doc, "me");
    defer c.deinit();
    c.presence_layer = layer;

    // Peer "bob": caret at 2, selection anchor at 7, hue index 100.
    const head = try doc.exportAnchor(gpa, 2, .after);
    defer gpa.free(head.agent);
    const selection = try doc.exportAnchor(gpa, 7, .before);
    defer gpa.free(selection.agent);
    try c.updatePeerPresence("bob", head, selection, 100);
    try c.republishPresence();
    try t.expectEqual(@as(usize, 1), layer.spanCount());
    const s = layer.resolvedSpan(0);
    try t.expectEqual(@as(usize, 2), s.start);
    try t.expectEqual(@as(usize, 7), s.end);
    try t.expectEqualStrings("bob", s.message);
    try t.expectEqual(@as(u32, 100), s.kind & 0xffff); // hue in low 16 bits
    try t.expectEqual(@as(u32, 0), s.kind >> 16); // caret at lower end (2<=7)

    // Backward selection: caret at 7, anchor at 2 → same range, caret flag set.
    const backward_head = try doc.exportAnchor(gpa, 7, .after);
    defer gpa.free(backward_head.agent);
    const backward_selection = try doc.exportAnchor(gpa, 2, .before);
    defer gpa.free(backward_selection.agent);
    try c.updatePeerPresence("bob", backward_head, backward_selection, 100);
    try c.republishPresence();
    const s2 = layer.resolvedSpan(0);
    try t.expectEqual(@as(usize, 2), s2.start);
    try t.expectEqual(@as(usize, 7), s2.end);
    try t.expectEqual(@as(u32, 1), s2.kind >> 16); // caret at upper end
}

test "presence: portable cursor identity survives a concurrent prefix insert" {
    const gpa = t.allocator;
    var sender = try Document.init(gpa, "alice");
    defer sender.deinit(gpa);
    try sender.insert(gpa, 0, "abcdef");

    var receiver = try Document.init(gpa, "bob");
    defer receiver.deinit(gpa);
    const bootstrap = try sender.serialize(gpa);
    defer gpa.free(bootstrap);
    _ = try receiver.mergeRemote(gpa, bootstrap);

    // Alice's caret is between c and d. Bob inserts independently at the
    // beginning before the presence feed arrives; numeric offset 3 now points
    // inside Bob's insertion, while Alice's character identity still resolves
    // to the logical boundary after c.
    const alice_caret = try sender.exportAnchor(gpa, 3, .after);
    defer gpa.free(alice_caret.agent);
    try receiver.insert(gpa, 0, "BOB");

    var layers: layers_mod.Layers = .empty;
    defer layers.deinit(gpa);
    const layer = try layers.claim(gpa, &receiver, "presence", .replicated, "collab");
    var c = try Collab.init(gpa, undefined, &receiver, "bob");
    defer c.deinit();
    c.presence_layer = layer;
    try c.updatePeerPresence("alice", alice_caret, alice_caret, 123);
    try c.republishPresence();

    try t.expectEqual(@as(usize, 1), layer.spanCount());
    try t.expectEqual(@as(usize, 6), layer.resolvedSpan(0).start);
    try t.expectEqual(@as(usize, 6), layer.resolvedSpan(0).end);
}

test "presence: an anchor arriving before its op resolves after merge" {
    const gpa = t.allocator;
    var sender = try Document.init(gpa, "alice");
    defer sender.deinit(gpa);
    try sender.insert(gpa, 0, "base");

    var receiver = try Document.init(gpa, "bob");
    defer receiver.deinit(gpa);
    const base = try sender.serialize(gpa);
    defer gpa.free(base);
    _ = try receiver.mergeRemote(gpa, base);

    try sender.insert(gpa, 4, "!");
    const future_caret = try sender.exportAnchor(gpa, 5, .after);
    defer gpa.free(future_caret.agent);

    var layers: layers_mod.Layers = .empty;
    defer layers.deinit(gpa);
    const layer = try layers.claim(gpa, &receiver, "presence", .replicated, "collab");
    var c = try Collab.init(gpa, undefined, &receiver, "bob");
    defer c.deinit();
    c.presence_layer = layer;

    // Feed first: retain the identity but show nothing until it is knowable.
    try c.updatePeerPresence("alice", future_caret, future_caret, 321);
    try c.republishPresence();
    try t.expectEqual(@as(usize, 0), layer.spanCount());

    const with_future = try sender.serialize(gpa);
    defer gpa.free(with_future);
    try t.expect(try receiver.mergeRemote(gpa, with_future));
    try c.republishPresence();
    try t.expectEqual(@as(usize, 1), layer.spanCount());
    try t.expectEqual(@as(usize, 5), layer.resolvedSpan(0).start);
}
