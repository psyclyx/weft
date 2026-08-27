//! `publication.zig` — what a channel quad MEANS.
//!
//! A quad is transport: ops on `base`, presence on `base+1`, diagnostics on
//! `base+2`, blob/base/fs requests on `base+3`. Which of those are LIVE is a
//! separate, typed value — the publication descriptor (architecture §13.2):
//! a replica export plus the endpoint surfaces the owner chose to export.
//! v1 surfaces are exactly what the wire already carries; this layer names
//! and gates them, it invents no transport.
//!
//! Owner and audience are never read from the wire. They are the
//! authenticated participants of the connection a descriptor arrived on — a
//! self-asserted owner would be a spoof, not an authority (§13.5: the owner
//! trusts the authenticated participant).
//!
//! Absence is the legacy default: a quad with no descriptor (an older peer,
//! or the pre-sharing quad 0) is ungated and behaves exactly as before.

const std = @import("std");
const Allocator = std.mem.Allocator;

const wire = @import("weft_wire");
const peer_fs = @import("../peer_fs.zig");
const BlobOp = @import("remote_fs.zig").BlobOp;

/// The endpoint surfaces v1 exports. Each names traffic the wire already
/// carries. Adding one is additive: an older peer skips a descriptor it
/// cannot parse, and an unknown surface value inside a descriptor it can
/// parse is skipped export-by-export (see `decode`).
pub const Surface = enum(u8) {
    presence = 0,
    diagnostics = 1,
    fs_hierarchy = 2,
    fs_bytes = 3,
    fs_mutate = 4,
};

pub const ReplicaKind = enum(u8) { text = 0, graph = 1 };

/// The admission policy a replica's driver applies to a peer's ops.
pub const Admission = enum(u8) {
    /// The peer's connection grade decides (`Session.Access`) — text quads.
    by_grade = 0,
    /// Grade, then the per-region grant/lease hook — graph quads, whose
    /// driver runs `admitRegions` (vacuous until a grant or lease is bound).
    by_region = 1,
};

/// Operations an export offers. v1 splits fs operations INTO surfaces
/// (hierarchy/bytes/mutate), so what is left is the feed/call distinction:
/// `observe` admits a feed frame, `invoke` admits a request.
pub const Ops = packed struct(u8) {
    observe: bool = true,
    invoke: bool = true,
    _reserved: u6 = 0,
};

pub const Replica = struct {
    kind: ReplicaKind = .text,
    admission: Admission = .by_grade,
};

pub const Endpoint = struct {
    surface: Surface,
    ops: Ops = .{},
};

pub const Export = union(enum) {
    replica: Replica,
    endpoint: Endpoint,
};

/// How long the owner promises the publication stands. Declared and
/// rendered (§13.6's "until disconnect"); v1 enforces neither bound beyond
/// `unpublish`, which is why this is a descriptor field and not a timer.
pub const Lifetime = enum(u8) { until_unpublished = 0, until_disconnect = 1 };

/// Who a publication is for. v1 has exactly one connection's authenticated
/// peer to name; a third-party audience needs a directory this layer does
/// not have.
pub const Audience = enum(u8) { connection_peer = 0 };

/// The export selection a share path makes — §13.6's checkbox bundle, in
/// the one place that compiles it to a descriptor.
pub const ExportSpec = struct {
    replica: ?Replica = .{},
    presence: bool = true,
    diagnostics: bool = true,
    fs_hierarchy: bool = true,
    fs_bytes: bool = true,
    fs_mutate: bool = true,

    /// Everything the implicit per-buffer bundle carried before this layer
    /// existed. A quad published with it is indistinguishable from one with
    /// no descriptor at all — which is what keeps old peers and old flows
    /// unchanged.
    pub const legacy: ExportSpec = .{};
};

pub const max_exports = 32;
pub const max_resource = 512;

pub const Publication = struct {
    /// Stable per-connection identity. The quad base serves: a publication
    /// outlives its epochs but not its quad.
    id: u64,
    /// Authenticated owner fingerprint, from the session — never the wire.
    owner: ?[24]u8 = null,
    /// What is published. v1 carries the share's display name.
    resource: []u8,
    audience: Audience = .connection_peer,
    epoch: u32 = 0,
    lifetime: Lifetime = .until_disconnect,
    exports: std.ArrayList(Export) = .empty,
    /// Unpublished: the epoch advanced and no export is live.
    stale: bool = false,

    pub fn deinit(self: *Publication, gpa: Allocator) void {
        gpa.free(self.resource);
        self.exports.deinit(gpa);
        self.* = undefined;
    }

    pub fn replicaExport(self: *const Publication) ?Replica {
        for (self.exports.items) |e| switch (e) {
            .replica => |r| return r,
            .endpoint => {},
        };
        return null;
    }

    pub fn surfaceOps(self: *const Publication, surface: Surface) ?Ops {
        for (self.exports.items) |e| switch (e) {
            .replica => {},
            .endpoint => |ep| if (ep.surface == surface) return ep.ops,
        };
        return null;
    }

    /// Whether a frame addressed at `at` is live under this descriptor.
    /// Replies are never gated — an answer to a call we made is not an
    /// invocation, and settling it beats waiting out a deadline.
    pub fn admits(self: *const Publication, at: Address, class: wire.Class) bool {
        return switch (at) {
            .unclassified => true,
            .replica => !self.stale and self.replicaExport() != null,
            .surface => |s| !self.stale and if (self.surfaceOps(s)) |ops| switch (class) {
                .feed => ops.observe,
                .request => ops.invoke,
                .op, .control => true,
            } else false,
        };
    }

    /// Revoke every export and advance the epoch. Translated references
    /// held against this publication are invalid from here on.
    pub fn unpublish(self: *Publication, gpa: Allocator) void {
        self.exports.clearAndFree(gpa);
        self.epoch +%= 1;
        self.stale = true;
    }

    /// Descriptor bytes for the `publish` op kind. Caller owns.
    pub fn encode(self: *const Publication, gpa: Allocator, base: u64) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);
        try wire.putUv(gpa, &out, base);
        try wire.putUv(gpa, &out, self.id);
        try wire.putUv(gpa, &out, self.epoch);
        try out.append(gpa, @intFromEnum(self.lifetime));
        try wire.putUv(gpa, &out, self.resource.len);
        try out.appendSlice(gpa, self.resource);
        try wire.putUv(gpa, &out, self.exports.items.len);
        // Each export is length-framed so a peer that does not know a tag
        // or a surface can skip exactly that one and keep the rest.
        for (self.exports.items) |e| {
            var body: [3]u8 = undefined;
            switch (e) {
                .replica => |r| body = .{ 0, @intFromEnum(r.kind), @intFromEnum(r.admission) },
                .endpoint => |ep| body = .{ 1, @intFromEnum(ep.surface), @bitCast(ep.ops) },
            }
            try wire.putUv(gpa, &out, body.len);
            try out.appendSlice(gpa, &body);
        }
        return out.toOwnedSlice(gpa);
    }
};

pub const Decoded = struct { base: u64, publication: Publication };

/// Parse a `publish` payload. `owner` comes from the caller's session, not
/// from these bytes. Unknown export tags and surfaces are skipped; trailing
/// bytes a newer peer appended are ignored.
pub fn decode(gpa: Allocator, payload: []const u8, owner: ?[24]u8) !Decoded {
    var cur: []const u8 = payload;
    const base = try wire.getUv(&cur);
    const id = try wire.getUv(&cur);
    const epoch = try wire.getUv(&cur);
    if (cur.len == 0) return error.Corrupt;
    const lifetime = std.enums.fromInt(Lifetime, cur[0]) orelse Lifetime.until_disconnect;
    cur = cur[1..];
    const rlen = try wire.getUv(&cur);
    if (rlen > cur.len or rlen > max_resource) return error.Corrupt;
    const resource = try gpa.dupe(u8, cur[0..@intCast(rlen)]);
    errdefer gpa.free(resource);
    cur = cur[@intCast(rlen)..];

    var pub_: Publication = .{
        .id = id,
        .owner = owner,
        .resource = resource,
        .epoch = @truncate(epoch),
        .lifetime = lifetime,
    };
    errdefer pub_.exports.deinit(gpa);
    const count = try wire.getUv(&cur);
    if (count > max_exports) return error.Corrupt;
    for (0..@intCast(count)) |_| {
        const len = try wire.getUv(&cur);
        if (len > cur.len) return error.Corrupt;
        const body = cur[0..@intCast(len)];
        cur = cur[@intCast(len)..];
        if (body.len < 3) continue;
        switch (body[0]) {
            0 => try pub_.exports.append(gpa, .{ .replica = .{
                .kind = std.enums.fromInt(ReplicaKind, body[1]) orelse continue,
                .admission = std.enums.fromInt(Admission, body[2]) orelse .by_grade,
            } }),
            1 => try pub_.exports.append(gpa, .{ .endpoint = .{
                .surface = std.enums.fromInt(Surface, body[1]) orelse continue,
                .ops = @bitCast(body[2]),
            } }),
            else => {}, // a tag from a newer peer: skip this export only
        }
    }
    return .{ .base = base, .publication = pub_ };
}

/// Build the descriptor a share path publishes.
pub fn fromSpec(gpa: Allocator, id: u64, resource: []const u8, owner: ?[24]u8, spec: ExportSpec) !Publication {
    var p: Publication = .{
        .id = id,
        .owner = owner,
        .resource = try gpa.dupe(u8, resource),
    };
    errdefer p.deinit(gpa);
    if (spec.replica) |r| try p.exports.append(gpa, .{ .replica = r });
    const endpoints: [5]struct { bool, Surface } = .{
        .{ spec.presence, .presence },
        .{ spec.diagnostics, .diagnostics },
        .{ spec.fs_hierarchy, .fs_hierarchy },
        .{ spec.fs_bytes, .fs_bytes },
        .{ spec.fs_mutate, .fs_mutate },
    };
    for (endpoints) |e| {
        if (e[0]) try p.exports.append(gpa, .{ .endpoint = .{ .surface = e[1] } });
    }
    return p;
}

/// `unpublish` payload: the quad and the epoch it advanced to.
pub fn encodeUnpublish(gpa: Allocator, base: u64, epoch: u32) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try wire.putUv(gpa, &out, base);
    try wire.putUv(gpa, &out, epoch);
    return out.toOwnedSlice(gpa);
}

pub const Unpublished = struct { base: u64, epoch: u32 };

pub fn decodeUnpublish(payload: []const u8) !Unpublished {
    var cur: []const u8 = payload;
    const base = try wire.getUv(&cur);
    const epoch = try wire.getUv(&cur);
    return .{ .base = base, .epoch = @truncate(epoch) };
}

/// What a frame within a quad addresses.
pub const Address = union(enum) {
    /// Ops on the quad base: the replica export, or a connection-level
    /// frame (`grant`) no publication gates.
    replica,
    surface: Surface,
    /// A reply to a call we made, or a frame this version cannot name.
    unclassified,
};

/// Classify one frame within its quad. `offset` is `channel - base`.
pub fn addressOf(offset: u64, class: wire.Class, kind: u8, payload: []const u8) Address {
    return switch (class) {
        .op => if (offset == 0) .replica else .unclassified,
        .feed => switch (offset) {
            1 => .{ .surface = .presence },
            2 => .{ .surface = .diagnostics },
            else => .unclassified,
        },
        .request => if (offset == 3) requestAddress(kind, payload) else .unclassified,
        .control => .unclassified,
    };
}

fn requestAddress(kind: u8, payload: []const u8) Address {
    const rk = std.enums.fromInt(wire.RequestKind, kind) orelse return .unclassified;
    var cur: []const u8 = payload;
    _ = wire.getUv(&cur) catch return .unclassified; // request id
    if (cur.len == 0) return .unclassified;
    return switch (rk) {
        .call => switch (std.enums.fromInt(BlobOp, cur[0]) orelse return .unclassified) {
            // The document's compacted base IS the replica, not a file.
            .base_open, .base_read => .replica,
            .stat, .read => .{ .surface = .fs_bytes },
        },
        // One mapping for one fact: the descriptor names the surface
        // `peer_fs` will enforce on, never a second opinion about it.
        .fs_call => .{ .surface = fsSurface(@enumFromInt(cur[0])) },
        .ok, .err, .fs_ok, .fs_err, .cancel => .unclassified,
    };
}

/// The publication surface a `.peer` fs op draws on, from the one mapping
/// its own gate uses (`peer_fs.exportOf`). An op with no surface there —
/// the opaque `service` envelope, or a kind a newer peer invented — is
/// gated at the widest fs surface it could reach: core cannot see inside
/// it, so it fails closed.
fn fsSurface(op: peer_fs.Op) Surface {
    const e = peer_fs.exportOf(op) orelse return .fs_mutate;
    return switch (e) {
        .hierarchy => .fs_hierarchy,
        .bytes => .fs_bytes,
        .mutate => .fs_mutate,
    };
}

pub fn addressLabel(at: Address) []const u8 {
    return switch (at) {
        .replica => "replica",
        .unclassified => "unclassified",
        .surface => |s| @tagName(s),
    };
}

const t = std.testing;

test "publication: a descriptor round-trips and keeps its export set" {
    const gpa = t.allocator;
    var p = try fromSpec(gpa, 16, "parser.zig", null, .{ .fs_mutate = false });
    defer p.deinit(gpa);
    p.lifetime = .until_unpublished;

    const bytes = try p.encode(gpa, 16);
    defer gpa.free(bytes);
    var got = try decode(gpa, bytes, null);
    defer got.publication.deinit(gpa);

    try t.expectEqual(@as(u64, 16), got.base);
    try t.expectEqualStrings("parser.zig", got.publication.resource);
    try t.expectEqual(Lifetime.until_unpublished, got.publication.lifetime);
    try t.expectEqual(ReplicaKind.text, got.publication.replicaExport().?.kind);
    try t.expect(got.publication.surfaceOps(.presence) != null);
    try t.expect(got.publication.surfaceOps(.fs_bytes) != null);
    try t.expect(got.publication.surfaceOps(.fs_mutate) == null);
}

test "publication: an export a newer peer invented is skipped, the rest survive" {
    const gpa = t.allocator;
    // A descriptor from a peer that knows one export tag and one surface
    // this build does not. Both are length-framed, so both skip cleanly.
    var forged: std.ArrayList(u8) = .empty;
    defer forged.deinit(gpa);
    try wire.putUv(gpa, &forged, 24);
    try wire.putUv(gpa, &forged, 24);
    try wire.putUv(gpa, &forged, 0);
    try forged.append(gpa, @intFromEnum(Lifetime.until_disconnect));
    try wire.putUv(gpa, &forged, 5);
    try forged.appendSlice(gpa, "notes");
    try wire.putUv(gpa, &forged, 4);
    try wire.putUv(gpa, &forged, 3);
    try forged.appendSlice(gpa, &.{ 0, 0, 0 }); // replica text/by_grade
    try wire.putUv(gpa, &forged, 3);
    try forged.appendSlice(gpa, &.{ 1, 0, 3 }); // endpoint presence
    try wire.putUv(gpa, &forged, 3);
    try forged.appendSlice(gpa, &.{ 7, 9, 9 }); // unknown tag
    try wire.putUv(gpa, &forged, 5);
    try forged.appendSlice(gpa, &.{ 1, 200, 3, 0, 0 }); // unknown surface, longer body

    var decoded = try decode(gpa, forged.items, null);
    defer decoded.publication.deinit(gpa);
    try t.expectEqual(@as(usize, 2), decoded.publication.exports.items.len);
    try t.expect(decoded.publication.replicaExport() != null);
    try t.expect(decoded.publication.surfaceOps(.presence) != null);
}

test "publication: a surface outside the export set is not admitted; unpublish revokes all of them" {
    const gpa = t.allocator;
    var p = try fromSpec(gpa, 16, "doc", null, .{ .presence = false, .fs_mutate = false });
    defer p.deinit(gpa);

    try t.expect(p.admits(.replica, .op));
    try t.expect(!p.admits(.{ .surface = .presence }, .feed));
    try t.expect(p.admits(.{ .surface = .diagnostics }, .feed));
    try t.expect(p.admits(.{ .surface = .fs_bytes }, .request));
    try t.expect(!p.admits(.{ .surface = .fs_mutate }, .request));
    // A reply settles a call we made; the export set does not gate answers.
    try t.expect(p.admits(.unclassified, .request));

    p.unpublish(gpa);
    try t.expectEqual(@as(u32, 1), p.epoch);
    try t.expect(!p.admits(.replica, .op));
    try t.expect(!p.admits(.{ .surface = .diagnostics }, .feed));
    try t.expect(p.admits(.unclassified, .request));
}

test "publication: frames classify to the surface they actually address" {
    const gpa = t.allocator;
    try t.expectEqual(Address.replica, addressOf(0, .op, @intFromEnum(wire.OpKind.batch), ""));
    try t.expectEqual(Surface.presence, addressOf(1, .feed, 0, "").surface);
    try t.expectEqual(Surface.diagnostics, addressOf(2, .feed, 0, "").surface);

    var call: std.ArrayList(u8) = .empty;
    defer call.deinit(gpa);
    try wire.putUv(gpa, &call, 7);
    try call.append(gpa, @intFromEnum(BlobOp.read));
    try t.expectEqual(Surface.fs_bytes, addressOf(3, .request, @intFromEnum(wire.RequestKind.call), call.items).surface);
    call.items[call.items.len - 1] = @intFromEnum(BlobOp.base_read);
    try t.expectEqual(Address.replica, addressOf(3, .request, @intFromEnum(wire.RequestKind.call), call.items));

    var fs_call: std.ArrayList(u8) = .empty;
    defer fs_call.deinit(gpa);
    try wire.putUv(gpa, &fs_call, 9);
    try fs_call.append(gpa, @intFromEnum(peer_fs.Op.write));
    const fk = @intFromEnum(wire.RequestKind.fs_call);
    try t.expectEqual(Surface.fs_mutate, addressOf(3, .request, fk, fs_call.items).surface);
    fs_call.items[fs_call.items.len - 1] = @intFromEnum(peer_fs.Op.list);
    try t.expectEqual(Surface.fs_hierarchy, addressOf(3, .request, fk, fs_call.items).surface);
    // Replies are answers, never invocations.
    try t.expectEqual(Address.unclassified, addressOf(3, .request, @intFromEnum(wire.RequestKind.fs_ok), fs_call.items));
}
