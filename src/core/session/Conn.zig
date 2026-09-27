//! `Conn` — one authenticated connection carrying any number of shared
//! buffers over a single `Session`. Owns the session drain and routes
//! frames to per-buffer `Collab`s by channel quad (`base = channel & ~3`);
//! `share` announces a buffer on channel 0, the peer's announcements
//! surface as `offers` until opened.
//!
//! Routing is by quad; MEANING is by publication descriptor
//! (`publication.zig`). Each base the connection knows may carry one — ours
//! for a quad we allocated, the peer's for a quad it announced — and an
//! inbound frame whose surface that descriptor does not export is dropped
//! with a line in the log. A quad with no descriptor is ungated: that is
//! exactly an older peer, and it behaves as it always did.

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const wire = @import("weft_wire");
const secure = @import("../secure.zig");
const Document = @import("../Document.zig");
const GraphDoc = @import("../graph.zig");

const Session = @import("Session.zig");
const Collab = @import("Collab.zig");
const GraphCollab = @import("GraphCollab.zig");
pub const publication = @import("publication.zig");
const Publication = publication.Publication;
pub const ExportSpec = publication.ExportSpec;

const Conn = @This();

gpa: Allocator,
session: *Session,
name: []u8,
role: secure.Role,
collabs: std.ArrayList(*Collab) = .empty,
/// Graph-doc quads (stemma delta 5) — a separate list rather than a
/// generalized `collabs` because the two drivers are genuinely different
/// shapes (see `GraphCollab.zig`'s module doc comment on the seam); frame
/// routing tries `collabs` first, then `graph_collabs` (bases never
/// collide — both draw from the one `next_base` counter).
graph_collabs: std.ArrayList(*GraphCollab) = .empty,
offers: std.ArrayList(Offer) = .empty,
/// Our shares' display names by base (owned) — re-announced on
/// rebind.
share_names: std.AutoHashMapUnmanaged(u64, []u8) = .empty,
/// Same, for graph-doc shares (kept separate so rebind re-announces each
/// with its own `DocKind`).
graph_share_names: std.AutoHashMapUnmanaged(u64, []u8) = .empty,
/// The descriptor governing each quad, by base: ours for a quad we
/// allocated, the peer's for one it announced (a base is allocated by
/// exactly one side, so exactly one side publishes for it). Absent ⇒
/// ungated legacy bundle.
publications: std.AutoHashMapUnmanaged(u64, Publication) = .empty,
next_base: u64,

/// What kind of document a share/offer names — carried as an ADDITIVE
/// trailing byte on the `.share` announce payload (base|name were the
/// whole payload before this slice; an older decoder that doesn't read
/// past `name` is unaffected, exactly like the presence frame's trailing-
/// fields precedent in `Collab.handleFrame`). Absent (older sender, or a
/// short payload) defaults to `.text` — the only kind that existed before
/// stemma delta 5.
pub const DocKind = enum(u8) { text = 0, graph = 1 };

pub const Offer = struct {
    base: u64,
    name: []u8,
    kind: DocKind = .text,
    /// The shared document's minted identity (doc/model.md §2.1), carried
    /// after the kind byte. What makes `weft://<peer>/doc/<id>` name the
    /// same document across a reconnect, where `base` is re-allocated. Null
    /// from a sender that predates it (or for a graph quad): the offer still
    /// opens, and only its durable name degrades.
    doc_id: ?Document.Id = null,
    /// The owner unpublished this quad: its exports are revoked and any
    /// reference translated out of it is invalid.
    stale: bool = false,
};

pub fn init(gpa: Allocator, session: *Session, name: []const u8, role: secure.Role) !Conn {
    return .{
        .gpa = gpa,
        .session = session,
        .name = try gpa.dupe(u8, name),
        .role = role,
        .next_base = if (role == .server) 16 else 20,
    };
}

pub fn deinit(self: *Conn) void {
    for (self.collabs.items) |c| {
        c.deinit();
        self.gpa.destroy(c);
    }
    self.collabs.deinit(self.gpa);
    for (self.graph_collabs.items) |c| {
        c.deinit();
        self.gpa.destroy(c);
    }
    self.graph_collabs.deinit(self.gpa);
    for (self.offers.items) |o| self.gpa.free(o.name);
    self.offers.deinit(self.gpa);
    var it = self.share_names.valueIterator();
    while (it.next()) |v| self.gpa.free(v.*);
    self.share_names.deinit(self.gpa);
    var git = self.graph_share_names.valueIterator();
    while (git.next()) |v| self.gpa.free(v.*);
    self.graph_share_names.deinit(self.gpa);
    var pit = self.publications.valueIterator();
    while (pit.next()) |p| p.deinit(self.gpa);
    self.publications.deinit(self.gpa);
    self.gpa.free(self.name);
}

/// Unbind every Collab tagged `tag` (buffer close): a quad we published is
/// unpublished first, so the peer learns its exports are gone instead of
/// watching a quad go quiet — re-sharing allocates a fresh quad. A replica
/// of a PEER's quad just stops being bound, so that peer's offer can be
/// opened again (`isOpen`).
pub fn unbindTag(self: *Conn, tag: u64) void {
    var i: usize = 0;
    while (i < self.collabs.items.len) {
        if (self.collabs.items[i].tag == tag) {
            const c = self.collabs.swapRemove(i);
            self.unpublish(c.base);
            c.deinit();
            self.gpa.destroy(c);
        } else i += 1;
    }
    i = 0;
    while (i < self.graph_collabs.items.len) {
        if (self.graph_collabs.items[i].tag == tag) {
            const c = self.graph_collabs.swapRemove(i);
            self.unpublish(c.base);
            c.deinit();
            self.gpa.destroy(c);
        } else i += 1;
    }
}

/// Revoke a quad's exports and tell the peer. Only a quad WE allocated is
/// ours to unpublish — closing our view of a peer's share revokes nothing.
/// Best-effort on the wire: a teardown must not fail, and a peer that never
/// hears it degrades to today's behaviour (the quad stops answering).
pub fn unpublish(self: *Conn, base: u64) void {
    if (!self.ownsBase(base)) return;
    const p = self.publications.getPtr(base) orelse return;
    if (p.stale) return;
    p.unpublish(self.gpa);
    const payload = publication.encodeUnpublish(self.gpa, base, p.epoch) catch return;
    defer self.gpa.free(payload);
    self.session.post(.op, @intFromEnum(wire.OpKind.unpublish), 0, payload) catch
        std.log.warn("publication: could not announce unpublish of quad {d}", .{base});
}

pub fn findBase(self: *const Conn, base: u64) ?*Collab {
    for (self.collabs.items) |c| {
        if (c.base == base) return c;
    }
    return null;
}

pub fn findGraphBase(self: *const Conn, base: u64) ?*GraphCollab {
    for (self.graph_collabs.items) |c| {
        if (c.base == base) return c;
    }
    return null;
}

fn bind(self: *Conn, doc: *Document, base: u64, tag: u64) !*Collab {
    const c = try self.gpa.create(Collab);
    errdefer self.gpa.destroy(c);
    c.* = try Collab.init(self.gpa, self.session, doc, self.name);
    c.base = base;
    c.tag = tag;
    // Fail safe: a client-role side of a shared document holds off local
    // edits until the host's grant arrives (the host admits our ops by
    // our grade, so editing before we know it would only make a ghost).
    // The server role owns its replica and keeps `.own`.
    if (self.role == .client) {
        doc.my_grant = .view;
        c.client_bound = true;
    }
    try self.collabs.append(self.gpa, c);
    return c;
}

/// Same shape as `bind`, for a `GraphDoc` quad. No fail-safe `my_grant`
/// lowering — `GraphDoc` has no per-doc authority field yet (see
/// `GraphCollab.zig`'s module doc comment: nothing consumes one because
/// this slice's only client projects `.read_only` and has no interactive
/// edit path to gate). Admission is still authorized at the session grade
/// (`GraphCollab.handleFrame`'s `canEdit` check), same as text.
fn bindGraph(self: *Conn, doc: *GraphDoc, base: u64, tag: u64) !*GraphCollab {
    const c = try self.gpa.create(GraphCollab);
    errdefer self.gpa.destroy(c);
    c.* = try GraphCollab.init(self.gpa, self.session, doc, self.name);
    c.base = base;
    c.tag = tag;
    try self.graph_collabs.append(self.gpa, c);
    return c;
}

/// The legacy quad-0 document (the --listen/--connect flow): both
/// ends bind it by convention, no announcement on the wire.
pub fn bindPrimary(self: *Conn, doc: *Document, tag: u64) !*Collab {
    assert(self.findBase(0) == null);
    return self.bind(doc, 0, tag);
}

/// Share a buffer over this connection: allocate a quad, announce
/// it, start syncing. Returns the bound Collab. Exports the legacy
/// bundle — `shareExports` is the same call with a chosen export set.
pub fn share(self: *Conn, doc: *Document, display_name: []const u8, tag: u64) !*Collab {
    return self.shareExports(doc, display_name, tag, .legacy);
}

/// Share a buffer with an explicit export selection (§13.6's bundle,
/// compiled to a descriptor). The `share` announce still goes out first, so
/// a peer that knows nothing of publications sees the quad exactly as
/// before — it just never learns the set was narrowed.
pub fn shareExports(self: *Conn, doc: *Document, display_name: []const u8, tag: u64, spec: ExportSpec) !*Collab {
    const base = self.next_base;
    self.next_base += 8;
    const c = try self.bind(doc, base, tag);
    const owned = try self.gpa.dupe(u8, display_name);
    errdefer self.gpa.free(owned);
    try self.share_names.put(self.gpa, base, owned);
    try self.announceShare(base, display_name, .text, doc.id);
    try self.publish(base, display_name, spec);
    return c;
}

/// Share a `GraphDoc` over this connection (stemma delta 5's host-side
/// API — mirrors `share`, no config verb needed for this slice). Allocates
/// a quad from the SAME counter `share` uses, so bases never collide
/// regardless of which kind a peer shares first.
pub fn shareGraph(self: *Conn, doc: *GraphDoc, display_name: []const u8, tag: u64) !*GraphCollab {
    const base = self.next_base;
    self.next_base += 8;
    const c = try self.bindGraph(doc, base, tag);
    const owned = try self.gpa.dupe(u8, display_name);
    errdefer self.gpa.free(owned);
    try self.graph_share_names.put(self.gpa, base, owned);
    try self.announceShare(base, display_name, .graph, null);
    // Graph quads run the per-region admission hook on top of the grade.
    try self.publish(base, display_name, .{ .replica = .{ .kind = .graph, .admission = .by_region } });
    return c;
}

/// Record and announce the descriptor for a quad we own.
fn publish(self: *Conn, base: u64, resource: []const u8, spec: ExportSpec) !void {
    var p = try publication.fromSpec(self.gpa, base, resource, self.session.peerFingerprint(), spec);
    errdefer p.deinit(self.gpa);
    const gop = try self.publications.getOrPut(self.gpa, base);
    if (gop.found_existing) {
        p.epoch = gop.value_ptr.epoch;
        gop.value_ptr.deinit(self.gpa);
    }
    gop.value_ptr.* = p;
    try self.announcePublication(base);
}

fn announcePublication(self: *Conn, base: u64) !void {
    const p = self.publications.getPtr(base) orelse return;
    const payload = try p.encode(self.gpa, base);
    defer self.gpa.free(payload);
    try self.session.post(.op, @intFromEnum(wire.OpKind.publish), 0, payload);
}

/// The descriptor governing `base`, or null when the quad is ungated.
pub fn publicationFor(self: *const Conn, base: u64) ?*const Publication {
    return self.publications.getPtr(base);
}

/// Did WE allocate this quad? A base is allocated by exactly one side, and
/// only that side publishes or unpublishes for it.
fn ownsBase(self: *const Conn, base: u64) bool {
    return self.share_names.contains(base) or self.graph_share_names.contains(base);
}

/// `base | name | kind | [doc id]`. The id is a second ADDITIVE trailer, after
/// the kind byte, on the same terms the kind byte was added: an older decoder
/// reads `trailer[0]` and stops, so it never sees the id, and the wire
/// version is unchanged (doc/wire.md, "Shares").
fn announceShare(self: *Conn, base: u64, display_name: []const u8, kind: DocKind, id: ?Document.Id) !void {
    var payload: std.ArrayList(u8) = .empty;
    defer payload.deinit(self.gpa);
    try wire.putUv(self.gpa, &payload, base);
    try wire.putUv(self.gpa, &payload, display_name.len);
    try payload.appendSlice(self.gpa, display_name);
    try payload.append(self.gpa, @intFromEnum(kind));
    if (id) |minted| try payload.appendSlice(self.gpa, &minted.bytes);
    try self.session.post(.op, @intFromEnum(wire.OpKind.share), 0, payload.items);
}

/// Open one of the peer's announced buffers into `doc` (typically a
/// fresh empty document: the frontier exchange bootstraps content). The
/// replica takes the sharer's minted id when the announcement carried one:
/// it is a replica of THAT document, not a new one, so both ends name it
/// alike.
///
/// Whether an offer is open is not remembered beside it: it is whether a
/// replica of its quad is BOUND (`isOpen`), which is exactly what closing
/// the replica's entry undoes (`unbindTag`). So a share closed and opened
/// again binds again — the same document by its id, one binding at a time —
/// and a second bind while one stands is refused, not asserted away.
pub fn openOffer(self: *Conn, index: usize, doc: *Document, tag: u64) !*Collab {
    const o = &self.offers.items[index];
    if (o.kind != .text) return error.NotText;
    if (self.isOpen(o.*)) return error.AlreadyBound;
    const c = try self.bind(doc, o.base, tag);
    if (o.doc_id) |id| doc.id = id;
    return c;
}

/// Whether a replica of offer `o`'s quad is bound on this connection.
pub fn isOpen(self: *const Conn, o: Offer) bool {
    return switch (o.kind) {
        .text => self.findBase(o.base) != null,
        .graph => self.findGraphBase(o.base) != null,
    };
}

/// The index of the live text offer naming document `id`, if the peer
/// announced one — how `weft://<peer>/doc/<id>` finds its document again on
/// a connection whose bases were all re-allocated. It may be open already
/// (`isOpen`): the caller then shows the entry bound to it.
pub fn offerFor(self: *const Conn, id: Document.Id) ?usize {
    for (self.offers.items, 0..) |o, i| {
        const offered = o.doc_id orelse continue;
        if (o.kind == .text and !o.stale and offered.eql(id)) return i;
    }
    return null;
}

/// Open one of the peer's announced GRAPH docs into `doc` — same shape as
/// `openOffer`, and the same "fresh empty document" contract: `doc` should
/// be a virgin, structurally-empty replica (`GraphDoc.init(gpa,
/// agent_name)` — see `GraphCollab.zig`'s module doc comment on why `init`,
/// not `.open`, is the right bootstrap shell here); the frontier exchange
/// fills it.
pub fn openGraphOffer(self: *Conn, index: usize, doc: *GraphDoc, tag: u64) !*GraphCollab {
    const o = &self.offers.items[index];
    if (o.kind != .graph) return error.NotGraph;
    if (self.isOpen(o.*)) return error.AlreadyBound;
    return self.bindGraph(doc, o.base, tag);
}

/// Point every bound buffer at a fresh session after a reconnect
/// and re-announce our shares (idempotent for the peer: an already
/// known base is a no-op offer).
pub fn rebind(self: *Conn, new_session: *Session) !void {
    self.session = new_session;
    for (self.collabs.items) |c| {
        c.rebind(new_session);
        if (self.share_names.get(c.base)) |dn| {
            try self.announceShare(c.base, dn, .text, c.doc.id);
            try self.announcePublication(c.base);
        }
    }
    for (self.graph_collabs.items) |c| {
        c.rebind(new_session);
        if (self.graph_share_names.get(c.base)) |dn| {
            try self.announceShare(c.base, dn, .graph, null);
            try self.announcePublication(c.base);
        }
    }
}

/// Drain the session once, route frames, push every bound buffer.
/// Callers update each Collab's `cursor_offset` beforehand.
pub fn tick(self: *Conn) !bool {
    const gpa = self.gpa;
    var changed = false;
    var frames: std.ArrayList(wire.Decoder.Decoded) = .empty;
    defer frames.deinit(gpa);
    try self.session.drain(gpa, &frames);
    for (frames.items) |frame| {
        defer gpa.free(frame.payload);
        if (frame.class == .op and frame.channel == 0) {
            switch (std.enums.fromInt(wire.OpKind, frame.kind) orelse .batch) {
                .share => {
                    self.acceptOffer(frame.payload) catch {};
                    continue;
                },
                .publish => {
                    self.acceptPublication(frame.payload) catch {};
                    continue;
                },
                .unpublish => {
                    changed = self.acceptUnpublish(frame.payload) or changed;
                    continue;
                },
                else => {},
            }
        }
        const base = frame.channel - (frame.channel % 4);
        // Transport routes by quad; the descriptor says which surfaces are
        // live. A frame for a surface this quad does not export is dropped
        // loudly — never a crash, never a silent acceptance.
        if (self.publications.getPtr(base)) |p| {
            const at = publication.addressOf(frame.channel - base, frame.class, frame.kind, frame.payload);
            if (!p.admits(at, frame.class)) {
                std.log.warn("publication: quad {d} does not export {s} — frame dropped", .{ base, publication.addressLabel(at) });
                continue;
            }
        }
        if (self.findBase(base)) |c| {
            changed = (c.handleFrame(frame) catch false) or changed;
        } else if (self.findGraphBase(base)) |gc| {
            changed = (gc.handleFrame(frame) catch false) or changed;
        }
    }
    for (self.collabs.items) |c| {
        changed = (c.push() catch false) or changed;
    }
    for (self.graph_collabs.items) |gc| {
        changed = (gc.push() catch false) or changed;
    }
    return changed;
}

fn acceptOffer(self: *Conn, payload: []const u8) !void {
    var cur: []const u8 = payload;
    const base = try wire.getUv(&cur);
    const nlen = try wire.getUv(&cur);
    if (nlen > cur.len or nlen > 512) return error.Corrupt;
    if (base % 4 != 0 or base < 16) return error.Corrupt;
    for (self.offers.items) |o| {
        if (o.base == base) return; // duplicate announce (reconnect)
    }
    if (self.findBase(base) != null or self.findGraphBase(base) != null) return; // already bound
    // Additive trailing kind byte (see `DocKind`'s doc comment). ABSENT
    // means `.text` — the only kind an older sender ever announced.
    // UNRECOGNIZED is a newer sender's export surface we cannot render:
    // skip the whole announce (§13.4, "unknown required semantics fail
    // closed"). Defaulting it to `.text` would hand a graph-shaped export
    // to the text driver and mis-decode every frame on the quad; skipping
    // costs only that one offer and leaves the connection whole.
    const trailer = cur[nlen..];
    const kind: DocKind = if (trailer.len == 0) .text else std.enums.fromInt(DocKind, trailer[0]) orelse return;
    // The minted id rides after the kind byte. Absent (an older sender) or
    // short is no id — the offer opens all the same; anything past the id
    // is a newer sender's and is ignored, like every trailer before it.
    const id_bytes = @sizeOf(Document.Id);
    const doc_id: ?Document.Id = if (kind == .text and trailer.len >= 1 + id_bytes)
        .{ .bytes = trailer[1..][0..id_bytes].* }
    else
        null;
    const name = try self.gpa.dupe(u8, cur[0..nlen]);
    errdefer self.gpa.free(name);
    try self.offers.append(self.gpa, .{ .base = base, .name = name, .kind = kind, .doc_id = doc_id });
}

/// Record the peer's descriptor for one of ITS quads. The owner is the
/// authenticated peer of this connection, never a field in the payload.
fn acceptPublication(self: *Conn, payload: []const u8) !void {
    var decoded = try publication.decode(self.gpa, payload, self.session.peerFingerprint());
    errdefer decoded.publication.deinit(self.gpa);
    if (decoded.base % 4 != 0) return error.Corrupt;
    if (self.ownsBase(decoded.base)) {
        decoded.publication.deinit(self.gpa);
        return; // only the owner publishes for a quad
    }
    const gop = try self.publications.getOrPut(self.gpa, decoded.base);
    if (gop.found_existing) {
        // A re-announce (reconnect) is idempotent; an older epoch is a
        // stale replay and never resurrects revoked exports.
        if (decoded.publication.epoch < gop.value_ptr.epoch) {
            decoded.publication.deinit(self.gpa);
            return;
        }
        gop.value_ptr.deinit(self.gpa);
    }
    gop.value_ptr.* = decoded.publication;
}

/// The peer revoked a quad: advance our recorded epoch, mark it stale, and
/// invalidate everything we translated out of it (rendered cursors,
/// imported host diagnostics). Frames on it are dropped from here on.
fn acceptUnpublish(self: *Conn, payload: []const u8) bool {
    const msg = publication.decodeUnpublish(payload) catch return false;
    // A peer revokes ITS publications, never ours — the same reverse-vector
    // guard the `grant` frame enforces.
    if (self.ownsBase(msg.base)) return false;
    const p = self.publications.getPtr(msg.base) orelse return false;
    if (p.stale) return false;
    p.unpublish(self.gpa);
    p.epoch = @max(p.epoch, msg.epoch);
    for (self.offers.items) |*o| {
        if (o.base == msg.base) o.stale = true;
    }
    if (self.findBase(msg.base)) |c| {
        c.invalidateTranslated() catch {};
        return true;
    }
    return false;
}
