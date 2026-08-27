//! The `grant` frame's per-export payload (§13.5's "for replicated state,
//! grants are announced to their grantees: authority must not be asymmetric
//! knowledge") and the grantee-side state it lands in.
//!
//! ## The frame, and why it is additive by construction
//!
//! Wire v1.2 shipped `OpKind.grant` (host→client, on a quad's `base`) with a
//! ONE-BYTE payload: the peer's `Access` grade. That byte keeps its exact
//! meaning here and stays FIRST — an older decoder reads `payload[0]` and
//! ignores the rest, so it learns the preset bundle the per-export grants
//! add up to (`Access.fromOps`) and behaves exactly as it does today. A
//! newer decoder reads on:
//!
//!     u8  grade                         legacy preset byte, unchanged
//!     u8  desc_version = 1
//!     uv  publication_id
//!     uv  publication_epoch
//!     uv  n
//!     n × ( uv rec_len | rec )
//!           rec := uv ops_bits | u8 lifetime | u8 scope_kind | scope
//!           scope: 0 whole         → ()
//!                  1 doc_region    → anchor(start) anchor(end)
//!                  2 graph_subtree → uv token_len | token
//!
//! Every unknown thing narrows, never widens — the one rule that makes an
//! authority frame safe to extend:
//!
//! - a peer predating `grant` entirely skips op kind 3 (unknown op kinds are
//!   skipped) and stays at its bind-time `.view` fail-safe;
//! - a peer predating THIS slice reads the grade byte alone → the preset
//!   bundle, i.e. today's behavior;
//! - a payload of exactly one byte (an older HOST) decodes as grade-only →
//!   the preset bundle governs, so a new grantee still preflights, just at
//!   grade granularity;
//! - an unknown `desc_version` falls back to the grade byte, which the
//!   sender itself derived as the ceiling of what it granted;
//! - an unknown `scope_kind` (or a truncated record) drops THAT RECORD via
//!   its length prefix — one fewer grant, never a wider one.
//!
//! The grantee's fingerprint is not on the wire: the frame is host→client on
//! this quad, so the grantee is the receiver, and a self-asserted identity in
//! an authority frame would be worth nothing anyway.
//!
//! ## Announced ≠ authority
//!
//! `Announced` is DISPLAY AND PREVENTION state, exactly like
//! `GraphCollab.granted_roots`: it can only ever make a grantee refuse its
//! own candidate edit early. The owner's `ExportBook`, consulted at
//! `Session.authorize`, remains the sole enforcement — a grantee that
//! ignores, misparses, or is fed a wider claim than the owner's book holds
//! still cannot get an out-of-grant op admitted.

const std = @import("std");
const Allocator = std.mem.Allocator;

const wire = @import("weft_wire");
const grants = @import("../grants.zig");
const Document = @import("../Document.zig");
const Session = @import("Session.zig");

const Access = Session.Access;
const Op = grants.Op;
const OpSet = grants.OpSet;
const PublicationRef = grants.PublicationRef;

pub const desc_version: u8 = 1;

const ScopeKind = enum(u8) { whole = 0, doc_region = 1, graph_subtree = 2 };

/// Encode a `grant` frame payload announcing `list` (the owner's live grants
/// for this grantee on `pub_ref`). `grade` is the connection ceiling; the
/// leading byte is the narrower of it and what the grants actually add up
/// to, so the legacy reader can never be told MORE than the descriptors say.
pub fn encode(
    gpa: Allocator,
    out: *std.ArrayList(u8),
    grade: Access,
    pub_ref: PublicationRef,
    list: []const grants.ExportGrant,
) !void {
    var union_ops: OpSet = .empty;
    for (list) |g| union_ops = union_ops.unite(g.ops);
    const effective = Access.fromOps(union_ops.intersect(grade.ops()));

    try out.append(gpa, @intFromEnum(effective));
    try out.append(gpa, desc_version);
    try wire.putUv(gpa, out, pub_ref.id);
    try wire.putUv(gpa, out, pub_ref.epoch);
    try wire.putUv(gpa, out, list.len);

    var rec: std.ArrayList(u8) = .empty;
    defer rec.deinit(gpa);
    for (list) |g| {
        rec.clearRetainingCapacity();
        try wire.putUv(gpa, &rec, g.ops.bits);
        try rec.append(gpa, @intFromEnum(g.lifetime));
        switch (g.scope) {
            .whole => try rec.append(gpa, @intFromEnum(ScopeKind.whole)),
            .doc_region => |dr| {
                try rec.append(gpa, @intFromEnum(ScopeKind.doc_region));
                try putAnchor(gpa, &rec, dr.start);
                try putAnchor(gpa, &rec, dr.end);
            },
            .graph_subtree => |gs| {
                try rec.append(gpa, @intFromEnum(ScopeKind.graph_subtree));
                try wire.putUv(gpa, &rec, gs.root.token.len);
                try rec.appendSlice(gpa, gs.root.token);
            },
        }
        try wire.putUv(gpa, out, rec.items.len);
        try out.appendSlice(gpa, rec.items);
    }
}

fn putAnchor(gpa: Allocator, out: *std.ArrayList(u8), a: Document.EventAnchor) !void {
    try wire.putAnchor(gpa, out, .{ .agent = a.agent, .seq = a.seq, .side = @intFromEnum(a.side) });
}

/// One announced grant, with its scope bytes OWNED (the wire's are borrowed
/// from a frame payload the caller frees). `doc_id` is not on the wire — it
/// is the publication itself — so a designation resolves against the quad's
/// own document by construction.
pub const Entry = struct {
    ops: OpSet,
    lifetime: grants.Lifetime,
    scope: grants.ExportScope,

    fn deinit(self: *Entry, gpa: Allocator) void {
        switch (self.scope) {
            .whole => {},
            .doc_region => |dr| {
                gpa.free(dr.start.agent);
                gpa.free(dr.end.agent);
            },
            .graph_subtree => |gs| gpa.free(gs.root.token),
        }
        self.* = undefined;
    }
};

/// The grantee's record of what the owner last told it (see this file's doc
/// comment: display and prevention, never authority). Replaced WHOLESALE on
/// every inbound frame — the owner always announces its current full live
/// set, never a delta — so a revoke reaches the preflight as promptly as a
/// grant does.
pub const Announced = struct {
    gpa: Allocator,
    /// The publication the last announcement was about. `id = 0` = nothing
    /// announced yet, or a grade-only announcement.
    publication: PublicationRef = .{ .id = 0, .epoch = 0 },
    /// The legacy grade byte, always present.
    grade: Access = .view,
    /// True once a descriptor-carrying announcement has been folded. False
    /// means the grade preset is the whole announced authority.
    described: bool = false,
    entries: std.ArrayList(Entry) = .empty,

    pub fn init(gpa: Allocator) Announced {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Announced) void {
        self.clear();
        self.entries.deinit(self.gpa);
    }

    fn clear(self: *Announced) void {
        for (self.entries.items) |*e| e.deinit(self.gpa);
        self.entries.clearRetainingCapacity();
    }

    /// Fold one inbound `grant` payload. Malformed input never widens: the
    /// worst case falls back to the grade byte, and a payload with no
    /// readable grade byte at all is ignored entirely (keeping whatever was
    /// announced before, which was itself owner-stated). Cannot fail: an
    /// authority announcement that a grantee could fail to apply is one it
    /// might apply half of.
    pub fn fold(self: *Announced, payload: []const u8) void {
        if (payload.len == 0) return;
        const grade = std.enums.fromInt(Access, payload[0]) orelse return;

        // Grade-only (an older owner), or a descriptor version we don't
        // speak: the preset bundle is what we know, and it is the ceiling
        // the sender derived from what it actually granted.
        if (payload.len < 2 or payload[1] != desc_version) {
            self.clear();
            self.described = false;
            self.publication = .{ .id = 0, .epoch = 0 };
            self.grade = grade;
            return;
        }

        var cur: []const u8 = payload[2..];
        const id = wire.getUv(&cur) catch return;
        const epoch = wire.getUv(&cur) catch return;
        const n = wire.getUv(&cur) catch return;

        var fresh: std.ArrayList(Entry) = .empty;
        var i: u64 = 0;
        while (i < n) : (i += 1) {
            const rec_len = wire.getUv(&cur) catch break;
            if (rec_len > cur.len) break;
            var rec: []const u8 = cur[0..@intCast(rec_len)];
            cur = cur[@intCast(rec_len)..];
            // An unreadable record (unknown scope kind, truncation, even an
            // allocation failure) costs exactly that grant — the set
            // narrows, which is the only safe direction for an authority
            // frame to be wrong in.
            var entry = (self.decodeRecord(&rec) catch continue) orelse continue;
            fresh.append(self.gpa, entry) catch {
                entry.deinit(self.gpa);
                break;
            };
        }

        self.clear();
        self.entries.deinit(self.gpa);
        self.entries = fresh;
        self.described = true;
        self.publication = .{ .id = id, .epoch = epoch };
        self.grade = grade;
    }

    /// `null` for a record whose scope kind we don't speak — skipped, so the
    /// set narrows rather than widening on an unknown designation.
    fn decodeRecord(self: *Announced, rec: *[]const u8) !?Entry {
        const bits = try wire.getUv(rec);
        if (rec.len == 0) return null;
        const lifetime = std.enums.fromInt(grants.Lifetime, rec.*[0]) orelse return null;
        rec.* = rec.*[1..];
        if (rec.len == 0) return null;
        const kind = std.enums.fromInt(ScopeKind, rec.*[0]) orelse return null;
        rec.* = rec.*[1..];
        const granted: OpSet = .{ .bits = @truncate(bits) };
        const scope: grants.ExportScope = switch (kind) {
            .whole => .whole,
            .doc_region => blk: {
                const start = try self.takeAnchor(rec);
                errdefer self.gpa.free(start.agent);
                const end = try self.takeAnchor(rec);
                break :blk .{ .doc_region = .{ .doc_id = "", .start = start, .end = end } };
            },
            .graph_subtree => blk: {
                const tlen = try wire.getUv(rec);
                if (tlen > rec.len) return error.Corrupt;
                const token = try self.gpa.dupe(u8, rec.*[0..@intCast(tlen)]);
                rec.* = rec.*[@intCast(tlen)..];
                break :blk .{ .graph_subtree = .{ .doc_id = "", .root = .{ .token = token } } };
            },
        };
        return .{ .ops = granted, .lifetime = lifetime, .scope = scope };
    }

    fn takeAnchor(self: *Announced, rec: *[]const u8) !Document.EventAnchor {
        const a = try wire.getAnchor(rec);
        const side = std.enums.fromInt(Document.AnchorSide, a.side) orelse return error.Corrupt;
        return .{ .agent = try self.gpa.dupe(u8, a.agent), .seq = a.seq, .side = side };
    }

    /// Everything the owner says we hold, as one set. The union of the
    /// announced grants, or the grade preset when only a grade was
    /// announced.
    pub fn ops(self: *const Announced) OpSet {
        if (!self.described) return self.grade.ops();
        var acc: OpSet = .empty;
        for (self.entries.items) |e| acc = acc.unite(e.ops);
        return acc.intersect(self.grade.ops());
    }

    /// The grade to project into a document's own edit gate
    /// (`Document.my_grant`) — the preset bundle equivalent of what we were
    /// actually granted, so the ONE existing text edit chokepoint enforces
    /// the announced export without a new edit-path layer.
    pub fn docGrade(self: *const Announced) Access {
        return Access.fromOps(self.ops());
    }

    /// §13.5's preflight: may we mint `op` right now? Consulted BEFORE a
    /// local op is committed, so an out-of-grant edit refuses locally and no
    /// out-of-grant event is ever minted (doc/substrate.md §5 — the poison
    /// class becomes unreachable, not merely recoverable).
    pub fn may(self: *const Announced, op: Op) grants.Reason {
        if (self.described and self.entries.items.len == 0) return .never_granted;
        return if (self.ops().has(op)) .ok else .out_of_ops;
    }

    /// The same question against a reference the caller is holding: an
    /// invocation carrying an epoch the owner has since advanced past
    /// refuses with `.dead_epoch`, distinct from ever asking about the wrong
    /// operation.
    pub fn mayAt(self: *const Announced, pub_ref: PublicationRef, op: Op) grants.Reason {
        if (self.described and !pub_ref.eql(self.publication)) return .dead_epoch;
        return self.may(op);
    }
};

// ── Tests ───────────────────────────────────────────────────────────

const t = std.testing;
const fp: [24]u8 = @splat(0xc3);

fn encoded(gpa: Allocator, grade: Access, pub_ref: PublicationRef, list: []const grants.ExportGrant) !std.ArrayList(u8) {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try encode(gpa, &out, grade, pub_ref, list);
    return out;
}

test "grant frame: descriptors round-trip, and the leading byte stays the legacy preset an older peer reads" {
    const gpa = t.allocator;
    const p: PublicationRef = .{ .id = 42, .epoch = 3 };
    var payload = try encoded(gpa, .own, p, &.{
        .{ .grantee = fp, .publication = p, .ops = grants.OpSet.of(&.{ .replica_read, .presence_read }) },
        .{ .grantee = fp, .publication = p, .ops = grants.OpSet.of(&.{.replica_write}), .lifetime = .until_disconnect },
    });
    defer payload.deinit(gpa);

    // An older peer reads byte 0 alone and gets the preset bundle these
    // grants add up to — `edit`, not the `own` ceiling they were minted
    // under: the legacy reader can never be told MORE than the descriptors.
    try t.expectEqual(Access.edit, std.enums.fromInt(Access, payload.items[0]).?);

    var a: Announced = .init(gpa);
    defer a.deinit();
    a.fold(payload.items);
    try t.expect(a.described);
    try t.expect(a.publication.eql(p));
    try t.expectEqual(@as(usize, 2), a.entries.items.len);
    try t.expectEqual(grants.Lifetime.until_disconnect, a.entries.items[1].lifetime);
    try t.expectEqual(grants.Reason.ok, a.may(.replica_write));
    try t.expectEqual(grants.Reason.ok, a.may(.presence_read));
    try t.expectEqual(grants.Reason.out_of_ops, a.may(.presence_publish));
    try t.expectEqual(grants.Reason.out_of_ops, a.may(.admin));
    try t.expectEqual(Access.edit, a.docGrade());

    // A reference at an epoch the owner has moved past is a distinct refusal
    // from asking about the wrong operation.
    try t.expectEqual(grants.Reason.dead_epoch, a.mayAt(.{ .id = 42, .epoch = 2 }, .replica_write));
    try t.expectEqual(grants.Reason.ok, a.mayAt(p, .replica_write));
}

test "grant frame: an empty announcement is a real value — everything revoked, nothing to preflight with" {
    const gpa = t.allocator;
    const p: PublicationRef = .{ .id = 1, .epoch = 1 };
    var payload = try encoded(gpa, .edit, p, &.{});
    defer payload.deinit(gpa);

    var a: Announced = .init(gpa);
    defer a.deinit();
    a.fold(payload.items);
    try t.expect(a.described);
    try t.expectEqual(grants.Reason.never_granted, a.may(.replica_write));
    try t.expectEqual(grants.Reason.never_granted, a.may(.replica_read));
    // The connection grade is a ceiling, never a grant: an empty descriptor
    // set does NOT fall back to `edit`'s preset.
    try t.expectEqual(Access.view, a.docGrade());
}

test "grant frame: a legacy one-byte announcement decodes as the preset bundle, unchanged" {
    const gpa = t.allocator;
    var a: Announced = .init(gpa);
    defer a.deinit();

    for ([_]Access{ .view, .edit, .own }) |grade| {
        a.fold(&.{@intFromEnum(grade)});
        try t.expect(!a.described);
        try t.expectEqual(grade, a.docGrade()); // the grade round-trips exactly
        try t.expectEqual(grade.ops().bits, a.ops().bits);
        const want: grants.Reason = if (grade.canEdit()) .ok else .out_of_ops;
        try t.expectEqual(want, a.may(.replica_write));
        try t.expectEqual(grants.Reason.ok, a.may(.replica_read));
    }
}

test "grant frame: every unknown thing NARROWS — unknown version, unknown scope kind, truncation, garbage" {
    const gpa = t.allocator;
    const p: PublicationRef = .{ .id = 9, .epoch = 1 };
    var a: Announced = .init(gpa);
    defer a.deinit();

    // An unknown descriptor version falls back to the grade byte, which the
    // sender derived as the ceiling of what it actually granted.
    a.fold(&.{ @intFromEnum(Access.edit), 0xfe, 0xff, 0xff });
    try t.expect(!a.described);
    try t.expectEqual(Access.edit, a.docGrade());

    // An unknown scope kind drops THAT record — one fewer grant, never a
    // wider one. Hand-build a frame: one good record, one with scope kind 7.
    var payload: std.ArrayList(u8) = .empty;
    defer payload.deinit(gpa);
    try payload.append(gpa, @intFromEnum(Access.own));
    try payload.append(gpa, desc_version);
    try wire.putUv(gpa, &payload, p.id);
    try wire.putUv(gpa, &payload, p.epoch);
    try wire.putUv(gpa, &payload, 2);
    const good = [_]u8{ @intCast(grants.OpSet.of(&.{.replica_read}).bits), @intFromEnum(grants.Lifetime.until_revoked), 0 };
    try wire.putUv(gpa, &payload, good.len);
    try payload.appendSlice(gpa, &good);
    const alien = [_]u8{ @intCast(grants.OpSet.of(&.{.admin}).bits), @intFromEnum(grants.Lifetime.until_revoked), 7 };
    try wire.putUv(gpa, &payload, alien.len);
    try payload.appendSlice(gpa, &alien);

    a.fold(payload.items);
    try t.expectEqual(@as(usize, 1), a.entries.items.len);
    try t.expectEqual(grants.Reason.ok, a.may(.replica_read));
    try t.expectEqual(grants.Reason.out_of_ops, a.may(.admin)); // the unreadable grant is NOT honoured

    // A truncated tail stops at the last whole record rather than inventing
    // one, and an empty payload changes nothing at all.
    a.fold(payload.items[0 .. payload.items.len - 2]);
    try t.expectEqual(@as(usize, 1), a.entries.items.len);
    const before = a.ops().bits;
    a.fold(&.{});
    try t.expectEqual(before, a.ops().bits);
}

test "grant frame: a designation scope survives the wire — the grantee preflights against the shape it was told" {
    const gpa = t.allocator;
    const p: PublicationRef = .{ .id = 4, .epoch = 1 };
    var payload = try encoded(gpa, .edit, p, &.{
        .{
            .grantee = fp,
            .publication = p,
            .ops = grants.OpSet.of(&.{ .replica_read, .replica_write }),
            .scope = .{ .doc_region = .{
                .doc_id = "parser.zig",
                .start = .{ .agent = "maya", .seq = 12, .side = .after },
                .end = .{ .agent = "maya", .seq = 40, .side = .before },
            } },
        },
        .{
            .grantee = fp,
            .publication = p,
            .ops = grants.OpSet.of(&.{.replica_write}),
            .scope = .{ .graph_subtree = .{ .doc_id = "plan", .root = .{ .token = "sto\x01\x05alice\x03" } } },
        },
    });
    defer payload.deinit(gpa);

    var a: Announced = .init(gpa);
    defer a.deinit();
    a.fold(payload.items);
    try t.expectEqual(@as(usize, 2), a.entries.items.len);
    switch (a.entries.items[0].scope) {
        .doc_region => |dr| {
            try t.expectEqualStrings("maya", dr.start.agent);
            try t.expectEqual(@as(u64, 40), dr.end.seq);
            try t.expectEqual(Document.AnchorSide.after, dr.start.side);
            // `doc_id` is the publication itself, never re-sent.
            try t.expectEqualStrings("", dr.doc_id);
        },
        .whole, .graph_subtree => return error.TestUnexpectedResult,
    }
    switch (a.entries.items[1].scope) {
        .graph_subtree => |gs| try t.expectEqualStrings("sto\x01\x05alice\x03", gs.root.token),
        .whole, .doc_region => return error.TestUnexpectedResult,
    }
}

test "grant frame: the connection grade is a CEILING over the announced ops, never a grant" {
    const gpa = t.allocator;
    const p: PublicationRef = .{ .id = 2, .epoch = 1 };
    // The owner minted write, but this link's grade is only `view`.
    var payload = try encoded(gpa, .view, p, &.{
        .{ .grantee = fp, .publication = p, .ops = grants.OpSet.of(&.{ .replica_read, .replica_write }) },
    });
    defer payload.deinit(gpa);
    try t.expectEqual(Access.view, std.enums.fromInt(Access, payload.items[0]).?);

    var a: Announced = .init(gpa);
    defer a.deinit();
    a.fold(payload.items);
    try t.expectEqual(grants.Reason.out_of_ops, a.may(.replica_write));
    try t.expectEqual(grants.Reason.ok, a.may(.replica_read));
    try t.expectEqual(Access.view, a.docGrade());
}

test {
    std.testing.refAllDecls(@This());
}
