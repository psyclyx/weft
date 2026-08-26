//! `LeaseTable` — W6 slice 1's per-region lease (doc/substrate.md §4, the
//! declared single-writer-per-region fallback D1 designed). One table per
//! replica's view of ONE `GraphDoc`: a region (a `GraphDoc. NodeRef` —
//! one `ObjId`, per §1.1) maps to the principal currently holding it,
//! soft-state, re-announced and reaped exactly like presence (§5.2
//! "leases are soft-state, re-announced like presence and reaped on
//! disconnect").
//!
//! ## Trust model, stated honestly
//!
//! A lease claim is self-declared, exactly like a presence name or hue —
//! there is no cryptographic binding between a `holder` string and the
//! session that announced it. This is not a security boundary (nothing in
//! this fallback claims to stop a malicious peer); it is collaboration
//! hygiene between well-behaved principals, same trust level as the
//! presence layer it reuses (§5.2, §5.3). Two operations reflect two
//! different trust needs:
//!
//! - `tryAcquire` — the LOCAL "I want this region" intent (`GraphCollab.
//!   acquireLease`): conditional — granted iff free or already held by the
//!   same principal, and the conflict answer (who holds it) is returned as
//!   DATA (§5.2 "the conflict answer... is data the caller can display, not
//!   a silent failure"), never silently swallowed.
//! - `foldRemoteAcquire`/`release` — folding what a PEER announced over the
//!   wire: `release` is holder-conditional (a stale reordered release can't
//!   clobber a newer holder). `foldRemoteAcquire` runs a DETERMINISTIC
//!   TIEBREAK against whatever this table already believes for that region
//!   (see below) — it is NOT last-writer-wins.
//!
//! ## The concurrent-acquire race, and why the tiebreak is load-bearing
//!
//! Focus-enter is a real race: two principals can `tryAcquire` the SAME
//! free region locally, on their own replicas, before either announcement
//! has propagated. Each replica's local `tryAcquire` legitimately succeeds
//! (the region looks free locally) — so BOTH now believe they hold it, and
//! each announces. When the announcements cross, a naive last-writer-wins
//! fold would let A's table land on "A learns B, clobbers itself" and B's
//! table land on "B learns A, clobbers itself" — order-dependent and, for
//! two peers directly exchanging exactly one announcement each, STABLY
//! INVERTED (A's table ends up holder=B, B's table ends up holder=A) with
//! nothing left to re-announce and heal it. That is a silently defeated
//! mutual-exclusion guarantee: both principals' subsequent edits would
//! read as "sent by the region's own holder" on the RECEIVING side and be
//! admitted — concurrent writes into one region, zero refusals, exactly
//! what §5.3 exists to make impossible.
//!
//! The fix: `foldRemoteAcquire`, on a genuine conflict (an existing holder
//! that disagrees with the incoming announcement), keeps whichever name
//! sorts LOWER byte-wise (`std.mem.order`), dropping the loser's
//! announcement. This is a pure function of the two NAMES being compared —
//! not of arrival order, not of which replica is doing the folding, not of
//! which side is "self" — so every replica that ever sees both competing
//! claims computes the IDENTICAL winner and CONVERGES to one holder
//! table-wide, self-healing without any extra re-announce. Concretely, for
//! the race above: on A's replica, folding B's announcement against A's
//! own self-claim compares "A" vs "B" and keeps whichever is lower; on B's
//! replica, folding A's announcement against B's own self-claim runs the
//! SAME comparison and reaches the SAME answer. The loser's local belief
//! ("I hold this") is overwritten by the fold — correctly, since it lost —
//! so the loser's own next `tryAcquire` on that region reports `held_by`
//! honestly, and the loser's in-flight edit gets refused LOUDLY on the
//! winner's replica (`GraphCollab.admitRegions`: the sender's declared name
//! no longer matches the table's holder). This is weaker than a real
//! distributed lock (a lexicographically-favored name always wins a race,
//! not "whoever asked first") but it is DETERMINISTIC, CONVERGENT, and
//! LOUD to the loser — the three properties §5.3 actually needs; linearizable
//! acquisition order was never promised (this fallback is declared soft-
//! state, not a distributed lock service).
//!
//! The property this table's caller (`GraphCollab.admitRegions`) enforces —
//! "an op batch touching a region held by ANOTHER principal is refused at
//! admission, never silently merged" — holds once tables have converged:
//! whichever replica RECEIVES a batch enforces against its OWN local view,
//! and after a fold resolves a race, a replica's local view of ITS OWN
//! standing (winner or loser) is exactly what `foldRemoteAcquire` just
//! computed — never stale relative to a competing claim it has already
//! seen. See GraphCollab.zig's module doc comment for the full admission
//! chokepoint.

const std = @import("std");
const Allocator = std.mem.Allocator;

const GraphDoc = @import("../graph.zig");
const NodeRef = GraphDoc.NodeRef;

pub const LeaseTable = @This();

const Lease = struct {
    region: NodeRef, // owned token
    holder: []u8, // owned
    hue16: u32 = 0,
};

entries: std.ArrayList(Lease) = .empty,

pub const empty: LeaseTable = .{};

pub fn deinit(self: *LeaseTable, gpa: Allocator) void {
    for (self.entries.items) |e| {
        gpa.free(e.region.token);
        gpa.free(e.holder);
    }
    self.entries.deinit(gpa);
    self.* = .{};
}

pub fn isEmpty(self: *const LeaseTable) bool {
    return self.entries.items.len == 0;
}

fn indexOf(self: *const LeaseTable, region: NodeRef) ?usize {
    for (self.entries.items, 0..) |e, i| {
        if (e.region.eql(region)) return i;
    }
    return null;
}

/// The current holder of `region`, or `null` if free. Borrowed — valid
/// until the next mutation of this table.
pub fn holderOf(self: *const LeaseTable, region: NodeRef) ?[]const u8 {
    const i = self.indexOf(region) orelse return null;
    return self.entries.items[i].holder;
}

/// The hue (16-bit, same quantization as `Collab`'s presence hue) of
/// `region`'s current holder, or `null` if free.
pub fn hueOf(self: *const LeaseTable, region: NodeRef) ?u32 {
    const i = self.indexOf(region) orelse return null;
    return self.entries.items[i].hue16;
}

pub const AcquireResult = union(enum) {
    granted,
    /// Already held by someone else — the conflict answer, as data.
    held_by: []const u8, // borrowed, valid until the next mutation
};

/// The LOCAL "I want this region" intent: granted iff free or already
/// held by `holder`. Never silently swallows a conflict — the caller gets
/// `held_by` back to display.
pub fn tryAcquire(self: *LeaseTable, gpa: Allocator, region: NodeRef, holder: []const u8, hue16: u32) !AcquireResult {
    if (self.indexOf(region)) |i| {
        const e = &self.entries.items[i];
        if (std.mem.eql(u8, e.holder, holder)) {
            e.hue16 = hue16; // idempotent re-acquire refreshes hue
            return .granted;
        }
        return .{ .held_by = e.holder };
    }
    const region_owned = try region.dupe(gpa);
    errdefer gpa.free(region_owned.token);
    const holder_owned = try gpa.dupe(u8, holder);
    errdefer gpa.free(holder_owned);
    try self.entries.append(gpa, .{ .region = region_owned, .holder = holder_owned, .hue16 = hue16 });
    return .granted;
}

/// Fold a peer's self-declared acquire announcement. If this table has no
/// existing belief about `region`, or already agrees, the incoming
/// announcement is simply recorded. If it DISAGREES (a genuine concurrent
/// claim — see the module doc comment's race walkthrough), a deterministic
/// tiebreak decides: the lower name (`std.mem.order`) wins, so every
/// replica that folds the SAME two competing names reaches the SAME
/// winner regardless of arrival order — this is what makes lease tables
/// converge instead of landing in a stable, silent inversion.
pub fn foldRemoteAcquire(self: *LeaseTable, gpa: Allocator, region: NodeRef, holder: []const u8, hue16: u32) !void {
    if (self.indexOf(region)) |i| {
        const e = &self.entries.items[i];
        if (std.mem.eql(u8, e.holder, holder)) {
            e.hue16 = hue16;
            return;
        }
        if (std.mem.order(u8, holder, e.holder) == .lt) {
            // The incoming claim wins the tiebreak — adopt it.
            gpa.free(e.holder);
            e.holder = try gpa.dupe(u8, holder);
            e.hue16 = hue16;
        }
        // Else the existing holder wins the tiebreak: the incoming
        // (losing) announcement is dropped, on EVERY replica that folds
        // it — never a stale one-sided override.
        return;
    }
    const region_owned = try region.dupe(gpa);
    errdefer gpa.free(region_owned.token);
    const holder_owned = try gpa.dupe(u8, holder);
    errdefer gpa.free(holder_owned);
    try self.entries.append(gpa, .{ .region = region_owned, .holder = holder_owned, .hue16 = hue16 });
}

/// Every region currently held by `holder` — used to re-announce a
/// principal's still-local leases after a reconnect (§5.2: "re-announced
/// like presence"; see `GraphCollab.rebind`). Caller owns the returned
/// slice and each ref's token (`NodeRef.free`).
pub fn regionsHeldBy(self: *const LeaseTable, gpa: Allocator, holder: []const u8) Allocator.Error![]NodeRef {
    var out: std.ArrayList(NodeRef) = .empty;
    errdefer {
        for (out.items) |r| gpa.free(r.token);
        out.deinit(gpa);
    }
    for (self.entries.items) |e| {
        if (std.mem.eql(u8, e.holder, holder)) {
            try out.append(gpa, try e.region.dupe(gpa));
        }
    }
    return out.toOwnedSlice(gpa);
}

/// Release `region` iff currently held by `holder` (a mismatched or
/// already-free release is a harmless no-op — guards a stale/reordered
/// release from clobbering a newer holder). Used for both the explicit
/// local release and folding an inbound release announcement.
pub fn release(self: *LeaseTable, gpa: Allocator, region: NodeRef, holder: []const u8) void {
    const i = self.indexOf(region) orelse return;
    if (!std.mem.eql(u8, self.entries.items[i].holder, holder)) return;
    const e = self.entries.swapRemove(i);
    gpa.free(e.region.token);
    gpa.free(e.holder);
}

/// Disconnect reaping (§5.2): drop every lease held by `holder` — "a dead
/// session's leases die". Idempotent; safe to call on an already-reaped
/// principal.
pub fn reap(self: *LeaseTable, gpa: Allocator, holder: []const u8) void {
    var i: usize = 0;
    while (i < self.entries.items.len) {
        if (std.mem.eql(u8, self.entries.items[i].holder, holder)) {
            const e = self.entries.swapRemove(i);
            gpa.free(e.region.token);
            gpa.free(e.holder);
        } else i += 1;
    }
}

pub const Span = struct {
    region: NodeRef,
    holder: []const u8,
    /// Same bit layout as `Collab.packPresenceKind` (hue in bits 0..15) —
    /// bit 16 is always set (locked), not a caret side. A future unified
    /// span renderer can share the low-16 hue decode; see
    /// `doc/substrate.md` §4 "a lease is a presence span with a
    /// locked flag, in the holder's hue".
    kind: u32,
};

/// Display plumbing (not full UI — doc/substrate.md §4's wire-the-data-
/// path scope): every held region as a presence-shaped span. Rendering
/// into an actual buffer range is a projection's job (needs the region's
/// subbuffer span, `fill`/`Viewport` machinery not yet plumbed per
/// graph.zig's `Projection` doc comment) — later slice.
pub fn spans(self: *const LeaseTable, gpa: Allocator) Allocator.Error![]Span {
    var out = try gpa.alloc(Span, self.entries.items.len);
    for (self.entries.items, 0..) |e, i| {
        out[i] = .{ .region = e.region, .holder = e.holder, .kind = packLeaseKind(e.hue16) };
    }
    return out;
}

pub fn packLeaseKind(hue16: u32) u32 {
    return (hue16 & 0xffff) | (1 << 16);
}

const t = std.testing;

test "LeaseTable: acquire, conflict answer, release, re-acquire by other" {
    const gpa = t.allocator;
    var table: LeaseTable = .empty;
    defer table.deinit(gpa);

    const region: NodeRef = .{ .token = "sto\x01\x05alice\x01" };

    const r1 = try table.tryAcquire(gpa, region, "alice", 10);
    try t.expectEqual(AcquireResult.granted, r1);

    // Conflict: bob can't take alice's region; the conflict answer is data.
    const r2 = try table.tryAcquire(gpa, region, "bob", 20);
    switch (r2) {
        .held_by => |h| try t.expectEqualStrings("alice", h),
        .granted => return error.TestUnexpectedResult,
    }

    // Re-acquiring your own region is idempotent, not a conflict.
    const r3 = try table.tryAcquire(gpa, region, "alice", 11);
    try t.expectEqual(AcquireResult.granted, r3);

    // Bob releasing alice's region is a no-op (holder mismatch guard).
    table.release(gpa, region, "bob");
    try t.expectEqualStrings("alice", table.holderOf(region).?);

    // Alice releases for real.
    table.release(gpa, region, "alice");
    try t.expect(table.holderOf(region) == null);

    // Now bob can acquire it.
    const r4 = try table.tryAcquire(gpa, region, "bob", 20);
    try t.expectEqual(AcquireResult.granted, r4);
    try t.expectEqualStrings("bob", table.holderOf(region).?);
}

test "LeaseTable: disconnect reaping drops only the dead principal's leases" {
    const gpa = t.allocator;
    var table: LeaseTable = .empty;
    defer table.deinit(gpa);

    const r1: NodeRef = .{ .token = "r1" };
    const r2: NodeRef = .{ .token = "r2" };
    _ = try table.tryAcquire(gpa, r1, "alice", 0);
    _ = try table.tryAcquire(gpa, r2, "bob", 0);

    table.reap(gpa, "alice");
    try t.expect(table.holderOf(r1) == null);
    try t.expectEqualStrings("bob", table.holderOf(r2).?);

    // Reaping an already-gone principal is a harmless no-op.
    table.reap(gpa, "alice");
    try t.expect(table.isEmpty() == false);
}

test "LeaseTable: foldRemoteAcquire agrees or refreshes hue when uncontested" {
    const gpa = t.allocator;
    var table: LeaseTable = .empty;
    defer table.deinit(gpa);
    const region: NodeRef = .{ .token = "r" };

    try table.foldRemoteAcquire(gpa, region, "alice", 5);
    try t.expectEqualStrings("alice", table.holderOf(region).?);
    try t.expectEqual(@as(u32, 5), table.hueOf(region).?);

    // The SAME holder re-announcing (no conflict) just refreshes hue.
    try table.foldRemoteAcquire(gpa, region, "alice", 9);
    try t.expectEqualStrings("alice", table.holderOf(region).?);
    try t.expectEqual(@as(u32, 9), table.hueOf(region).?);
}

test "LeaseTable: foldRemoteAcquire tiebreak is deterministic and order-independent" {
    const gpa = t.allocator;
    const region: NodeRef = .{ .token = "r" };

    // "alice" sorts lower than "bob" — alice wins regardless of which
    // claim this replica folds first.
    {
        var table: LeaseTable = .empty;
        defer table.deinit(gpa);
        try table.foldRemoteAcquire(gpa, region, "bob", 1); // existing
        try table.foldRemoteAcquire(gpa, region, "alice", 2); // incoming, lower — wins
        try t.expectEqualStrings("alice", table.holderOf(region).?);
        try t.expectEqual(@as(u32, 2), table.hueOf(region).?);
    }
    {
        var table: LeaseTable = .empty;
        defer table.deinit(gpa);
        try table.foldRemoteAcquire(gpa, region, "alice", 2); // existing, lower
        try table.foldRemoteAcquire(gpa, region, "bob", 1); // incoming, higher — loses, dropped
        try t.expectEqualStrings("alice", table.holderOf(region).?);
        try t.expectEqual(@as(u32, 2), table.hueOf(region).?);
    }
}

test "LeaseTable: regionsHeldBy returns exactly the caller's own regions" {
    const gpa = t.allocator;
    var table: LeaseTable = .empty;
    defer table.deinit(gpa);
    const r1: NodeRef = .{ .token = "r1" };
    const r2: NodeRef = .{ .token = "r2" };
    const r3: NodeRef = .{ .token = "r3" };
    _ = try table.tryAcquire(gpa, r1, "alice", 0);
    _ = try table.tryAcquire(gpa, r2, "bob", 0);
    _ = try table.tryAcquire(gpa, r3, "alice", 0);

    const held = try table.regionsHeldBy(gpa, "alice");
    defer {
        for (held) |r| gpa.free(r.token);
        gpa.free(held);
    }
    try t.expectEqual(@as(usize, 2), held.len);
    var saw_r1 = false;
    var saw_r3 = false;
    for (held) |r| {
        if (r.eql(r1)) saw_r1 = true;
        if (r.eql(r3)) saw_r3 = true;
    }
    try t.expect(saw_r1);
    try t.expect(saw_r3);
}

test "LeaseTable: spans surface holder + hue for display, locked bit set" {
    const gpa = t.allocator;
    var table: LeaseTable = .empty;
    defer table.deinit(gpa);
    const region: NodeRef = .{ .token = "r" };
    _ = try table.tryAcquire(gpa, region, "alice", 0x1234);

    const sp = try table.spans(gpa);
    defer gpa.free(sp);
    try t.expectEqual(@as(usize, 1), sp.len);
    try t.expectEqualStrings("alice", sp[0].holder);
    try t.expectEqual(@as(u32, 0x1234), sp[0].kind & 0xffff);
    try t.expectEqual(@as(u32, 1), sp[0].kind >> 16);
}
