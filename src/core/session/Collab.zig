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
last_presence_offset: usize = std.math.maxInt(usize),
last_presence_anchor: usize = std.math.maxInt(usize),
/// Peer presence by name; the FULL set republishes into the layer on
/// every change, so any number of peers coexist. Parallel arrays:
/// caret (head), selection anchor, and identity hue quantized to u16.
presence_names: std.ArrayList([]u8) = .empty,
presence_offsets: std.ArrayList(usize) = .empty,
presence_anchors: std.ArrayList(usize) = .empty,
presence_hues: std.ArrayList(u32) = .empty,
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
    for (self.presence_names.items) |n| self.gpa.free(n);
    self.presence_names.deinit(self.gpa);
    self.presence_offsets.deinit(self.gpa);
    self.presence_anchors.deinit(self.gpa);
    self.presence_hues.deinit(self.gpa);
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
    self.last_presence_offset = std.math.maxInt(usize);
    self.last_presence_anchor = std.math.maxInt(usize);
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
            // Presence: uv name_len | name | uv head | uv anchor | uv
            // hue16 (the last two additive — an older peer sends only
            // head, so anchor defaults to head and the hue to a stable
            // per-name fallback). Fold, republish, and (in hub role)
            // relay to the other sessions.
            var cur: []const u8 = frame.payload;
            const nlen = wire.getUv(&cur) catch return false;
            if (nlen > cur.len) return false;
            const peer_name = cur[0..nlen];
            cur = cur[nlen..];
            const head = wire.getUv(&cur) catch return false;
            const anchor = wire.getUv(&cur) catch head;
            const hue16 = wire.getUv(&cur) catch (nameKey(peer_name) & 0xffff);
            try self.updatePeerPresence(peer_name, @intCast(head), @intCast(anchor), @intCast(hue16 & 0xffff));
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

    if (self.publish_presence and
        (self.cursor_offset != self.last_presence_offset or self.selection_anchor != self.last_presence_anchor))
    {
        self.last_presence_offset = self.cursor_offset;
        self.last_presence_anchor = self.selection_anchor;
        var payload: std.ArrayList(u8) = .empty;
        defer payload.deinit(gpa);
        // uv name_len | name | uv head | uv anchor | uv hue16. The
        // trailing fields are additive: an older peer's decoder reads
        // name+head and ignores the rest (frame length-delimited).
        try wire.putUv(gpa, &payload, self.name.len);
        try payload.appendSlice(gpa, self.name);
        try wire.putUv(gpa, &payload, self.cursor_offset);
        try wire.putUv(gpa, &payload, self.selection_anchor);
        const hue16: u32 = @intFromFloat(self.session.id.hue() * 65535.0);
        try wire.putUv(gpa, &payload, hue16);
        // Coalescing key is per-peer: N cursors never collapse.
        try self.session.postFeed(self.base + 1, nameKey(self.name), payload.items);
    }
    return false;
}

fn nameKey(name: []const u8) u64 {
    return std.hash.Fnv1a_64.hash(name);
}

fn updatePeerPresence(self: *Collab, peer_name: []const u8, head: usize, anchor: usize, hue16: u32) !void {
    for (self.presence_names.items, 0..) |n, i| {
        if (std.mem.eql(u8, n, peer_name)) {
            self.presence_offsets.items[i] = head;
            self.presence_anchors.items[i] = anchor;
            self.presence_hues.items[i] = hue16;
            return;
        }
    }
    const owned = try self.gpa.dupe(u8, peer_name);
    errdefer self.gpa.free(owned);
    try self.presence_names.append(self.gpa, owned);
    errdefer _ = self.presence_names.pop();
    try self.presence_offsets.append(self.gpa, head);
    errdefer _ = self.presence_offsets.pop();
    try self.presence_anchors.append(self.gpa, anchor);
    errdefer _ = self.presence_anchors.pop();
    try self.presence_hues.append(self.gpa, hue16);
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
    const limit = self.doc.text().byteLen();
    for (
        self.presence_names.items,
        self.presence_offsets.items,
        self.presence_anchors.items,
        self.presence_hues.items,
    ) |n, head, anchor, hue16| {
        const h = @min(head, limit);
        const a = @min(anchor, limit);
        try spans.append(gpa, .{
            .start = @min(h, a),
            .end = @max(h, a),
            .kind = packPresenceKind(hue16, h <= a),
            .message = n,
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
    try c.updatePeerPresence("bob", 2, 7, 100);
    try c.republishPresence();
    try t.expectEqual(@as(usize, 1), layer.spanCount());
    const s = layer.resolvedSpan(0);
    try t.expectEqual(@as(usize, 2), s.start);
    try t.expectEqual(@as(usize, 7), s.end);
    try t.expectEqualStrings("bob", s.message);
    try t.expectEqual(@as(u32, 100), s.kind & 0xffff); // hue in low 16 bits
    try t.expectEqual(@as(u32, 0), s.kind >> 16); // caret at lower end (2<=7)

    // Backward selection: caret at 7, anchor at 2 → same range, caret flag set.
    try c.updatePeerPresence("bob", 7, 2, 100);
    try c.republishPresence();
    const s2 = layer.resolvedSpan(0);
    try t.expectEqual(@as(usize, 2), s2.start);
    try t.expectEqual(@as(usize, 7), s2.end);
    try t.expectEqual(@as(u32, 1), s2.kind >> 16); // caret at upper end
}
