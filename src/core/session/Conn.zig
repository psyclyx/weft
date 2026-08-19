//! `Conn` — one authenticated connection carrying any number of shared
//! buffers over a single `Session`. Owns the session drain and routes
//! frames to per-buffer `Collab`s by channel quad (`base = channel & ~3`);
//! `share` announces a buffer on channel 0, the peer's announcements
//! surface as `offers` until opened.

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const wire = @import("../wire.zig");
const secure = @import("../secure.zig");
const Document = @import("../Document.zig");

const Session = @import("Session.zig");
const Collab = @import("Collab.zig");

const Conn = @This();

gpa: Allocator,
session: *Session,
name: []u8,
role: secure.Role,
collabs: std.ArrayList(*Collab) = .empty,
offers: std.ArrayList(Offer) = .empty,
/// Our shares' display names by base (owned) — re-announced on
/// rebind.
share_names: std.AutoHashMapUnmanaged(u64, []u8) = .empty,
next_base: u64,

pub const Offer = struct {
    base: u64,
    name: []u8,
    opened: bool = false,
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
    for (self.offers.items) |o| self.gpa.free(o.name);
    self.offers.deinit(self.gpa);
    var it = self.share_names.valueIterator();
    while (it.next()) |v| self.gpa.free(v.*);
    self.share_names.deinit(self.gpa);
    self.gpa.free(self.name);
}

/// Unbind every Collab tagged `tag` (buffer close): the peer's
/// frames on that quad drop harmlessly afterwards. The offer, if
/// any, stays consumed — re-sharing allocates a fresh quad.
pub fn unbindTag(self: *Conn, tag: u64) void {
    var i: usize = 0;
    while (i < self.collabs.items.len) {
        if (self.collabs.items[i].tag == tag) {
            const c = self.collabs.swapRemove(i);
            c.deinit();
            self.gpa.destroy(c);
        } else i += 1;
    }
}

pub fn findBase(self: *Conn, base: u64) ?*Collab {
    for (self.collabs.items) |c| {
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

/// The legacy quad-0 document (the --listen/--connect flow): both
/// ends bind it by convention, no announcement on the wire.
pub fn bindPrimary(self: *Conn, doc: *Document, tag: u64) !*Collab {
    assert(self.findBase(0) == null);
    return self.bind(doc, 0, tag);
}

/// Share a buffer over this connection: allocate a quad, announce
/// it, start syncing. Returns the bound Collab.
pub fn share(self: *Conn, doc: *Document, display_name: []const u8, tag: u64) !*Collab {
    const base = self.next_base;
    self.next_base += 8;
    const c = try self.bind(doc, base, tag);
    const owned = try self.gpa.dupe(u8, display_name);
    errdefer self.gpa.free(owned);
    try self.share_names.put(self.gpa, base, owned);
    try self.announceShare(base, display_name);
    return c;
}

fn announceShare(self: *Conn, base: u64, display_name: []const u8) !void {
    var payload: std.ArrayList(u8) = .empty;
    defer payload.deinit(self.gpa);
    try wire.putUv(self.gpa, &payload, base);
    try wire.putUv(self.gpa, &payload, display_name.len);
    try payload.appendSlice(self.gpa, display_name);
    try self.session.post(.op, @intFromEnum(wire.OpKind.share), 0, payload.items);
}

/// Open one of the peer's announced buffers into `doc` (typically a
/// fresh empty document: the frontier exchange bootstraps content).
pub fn openOffer(self: *Conn, index: usize, doc: *Document, tag: u64) !*Collab {
    const o = &self.offers.items[index];
    assert(!o.opened);
    const c = try self.bind(doc, o.base, tag);
    o.opened = true;
    return c;
}

/// Point every bound buffer at a fresh session after a reconnect
/// and re-announce our shares (idempotent for the peer: an already
/// known base is a no-op offer).
pub fn rebind(self: *Conn, new_session: *Session) !void {
    self.session = new_session;
    for (self.collabs.items) |c| {
        c.rebind(new_session);
        if (self.share_names.get(c.base)) |dn| try self.announceShare(c.base, dn);
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
        if (frame.class == .op and frame.channel == 0 and
            (std.enums.fromInt(wire.OpKind, frame.kind) orelse .batch) == .share)
        {
            self.acceptOffer(frame.payload) catch {};
            continue;
        }
        const base = frame.channel - (frame.channel % 4);
        if (self.findBase(base)) |c| {
            changed = (c.handleFrame(frame) catch false) or changed;
        }
    }
    for (self.collabs.items) |c| {
        changed = (c.push() catch false) or changed;
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
    if (self.findBase(base) != null) return; // already bound
    const name = try self.gpa.dupe(u8, cur[0..nlen]);
    errdefer self.gpa.free(name);
    try self.offers.append(self.gpa, .{ .base = base, .name = name });
}
