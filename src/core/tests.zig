//! Property tests for the core ABI — the milestone-2 gate.
//!
//! What is being proven, per the peer model:
//! - convergence: user + two plugin peers editing concurrently against
//!   stale snapshots always reconcile to identical text on every replica;
//! - anchors: identity anchors keep naming the same character under
//!   adversarial concurrent edits (inserts at the anchor, deletes across
//!   it), and local anchors stay ordered and in-bounds;
//! - causal subscription: replaying the commit log's patches from any
//!   cursor reconstructs the exact document text, commit by commit.
//!
//! All generated content is ASCII so random byte offsets are always
//! valid scalar boundaries; identity targets are unique characters so
//! "same character" is checkable by search.

const std = @import("std");
const t = std.testing;
const Allocator = std.mem.Allocator;

const stemma = @import("stemma");
const core = @import("core.zig");
const Document = core.Document;

const lower = "abcdefghijklmnopqrstuvwxyz";

fn randomFill(rand: std.Random, buf: []u8) void {
    for (buf) |*b| b.* = lower[rand.uintLessThan(usize, lower.len)];
}

fn ownedText(gpa: Allocator, doc: *const Document) ![]u8 {
    return doc.text().toOwnedSlice(gpa);
}

/// A peer editing its own replica against the snapshot it took; tracks
/// the replica's length locally (nothing else edits that replica — the
/// point of the model).
const PeerDriver = struct {
    id: Document.PeerId,
    len: usize,

    fn takeSnapshot(self: *PeerDriver, gpa: Allocator, doc: *Document) !void {
        var s = try doc.peerSnapshot(gpa, self.id);
        self.len = s.rope.byteLen();
        s.deinit(gpa);
    }

    fn randomOps(self: *PeerDriver, gpa: Allocator, doc: *Document, rand: std.Random, ops: usize) !void {
        for (0..ops) |_| {
            if (self.len > 0 and rand.boolean()) {
                const start = rand.uintLessThan(usize, self.len);
                const end = start + 1 + rand.uintAtMost(usize, @min(self.len - start - 1, 5));
                try doc.peerDelete(gpa, self.id, .{ .start = start, .end = end });
                self.len -= end - start;
            } else {
                var buf: [6]u8 = undefined;
                const n = 1 + rand.uintAtMost(usize, buf.len - 1);
                randomFill(rand, buf[0..n]);
                const off = rand.uintAtMost(usize, self.len);
                try doc.peerInsert(gpa, self.id, off, buf[0..n]);
                self.len += n;
            }
        }
    }
};

fn convergenceRound(gpa: Allocator, seed: u64, rounds: usize) !void {
    var prng = std.Random.DefaultPrng.init(seed);
    const rand = prng.random();

    var doc = try Document.init(gpa, "user");
    defer doc.deinit(gpa);
    var a: PeerDriver = .{ .id = try doc.addPeer(gpa, "peer-a"), .len = 0 };
    var b: PeerDriver = .{ .id = try doc.addPeer(gpa, "peer-b"), .len = 0 };

    var seed_text: [24]u8 = undefined;
    randomFill(rand, &seed_text);
    try doc.insert(gpa, 0, &seed_text);

    for (0..rounds) |_| {
        // Both peers read the same head...
        try a.takeSnapshot(gpa, &doc);
        try b.takeSnapshot(gpa, &doc);
        // ...the user keeps typing (concurrent with both)...
        const len = doc.text().byteLen();
        if (len > 4 and rand.boolean()) {
            const start = rand.uintLessThan(usize, len - 1);
            const end = start + 1 + rand.uintAtMost(usize, @min(len - start - 1, 4));
            try doc.delete(gpa, .{ .start = start, .end = end });
        } else {
            var buf: [5]u8 = undefined;
            const n = 1 + rand.uintAtMost(usize, buf.len - 1);
            randomFill(rand, buf[0..n]);
            try doc.insert(gpa, rand.uintAtMost(usize, len), buf[0..n]);
        }
        // ...and both peers submit op batches stated against their
        // (now stale) snapshots. B does not see A's commit until its
        // next snapshot: genuinely concurrent three ways.
        try a.randomOps(gpa, &doc, rand, 1 + rand.uintAtMost(usize, 3));
        try b.randomOps(gpa, &doc, rand, 1 + rand.uintAtMost(usize, 3));
        _ = try doc.peerCommit(gpa, a.id);
        _ = try doc.peerCommit(gpa, b.id);
    }

    // Convergence: after a final sync every replica holds identical text.
    const main_text = try ownedText(gpa, &doc);
    defer gpa.free(main_text);
    inline for (.{ &a, &b }) |peer| {
        var s = try doc.peerSnapshot(gpa, peer.id);
        defer s.deinit(gpa);
        const peer_text = try s.rope.toOwnedSlice(gpa);
        defer gpa.free(peer_text);
        try t.expectEqualStrings(main_text, peer_text);
    }
}

test "property: 2-peer convergence under concurrent stale-snapshot batches" {
    for ([_]u64{ 0xa11ce, 0x5c1_0e2, 0xdead_f00d, 42 }) |seed| {
        try convergenceRound(t.allocator, seed, 25);
    }
}

test "property: identity anchors survive adversarial concurrency" {
    const gpa = t.allocator;
    for ([_]u64{ 0xbeef, 0x7777 }) |seed| {
        var prng = std.Random.DefaultPrng.init(seed);
        const rand = prng.random();

        var doc = try Document.init(gpa, "user");
        defer doc.deinit(gpa);
        var a: PeerDriver = .{ .id = try doc.addPeer(gpa, "peer-a"), .len = 0 };
        var b: PeerDriver = .{ .id = try doc.addPeer(gpa, "peer-b"), .len = 0 };

        // Unique identity targets: every initial character is distinct
        // and disjoint from the lowercase filler peers insert.
        const targets = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";
        try doc.insert(gpa, 0, targets);

        // One identity anchor in front of every target, plus local
        // anchors at the same spots.
        var anchors: [targets.len]Document.EventAnchor = undefined;
        var locals: [targets.len]stemma.AnchorSet.Handle = undefined;
        for (0..targets.len) |i| {
            anchors[i] = try doc.exportAnchor(gpa, i, .before);
            locals[i] = try doc.addAnchor(gpa, i, .left);
        }
        defer for (anchors) |an| {
            if (an.agent.len > 0) gpa.free(an.agent);
        };

        // Adversarial chaos: inserts landing exactly at anchored
        // positions, deletes spanning them, from two concurrent peers
        // plus the user.
        for (0..12) |_| {
            try a.takeSnapshot(gpa, &doc);
            try b.takeSnapshot(gpa, &doc);
            const len = doc.text().byteLen();
            try doc.insert(gpa, rand.uintAtMost(usize, len), "xy");
            try a.randomOps(gpa, &doc, rand, 3);
            try b.randomOps(gpa, &doc, rand, 3);
            _ = try doc.peerCommit(gpa, a.id);
            _ = try doc.peerCommit(gpa, b.id);
        }

        const now = try ownedText(gpa, &doc);
        defer gpa.free(now);

        // Identity: a surviving target's anchor resolves to exactly its
        // position; a deleted target's anchor collapses in-bounds.
        var resolved: [targets.len]usize = undefined;
        try doc.resolveAnchors(gpa, &anchors, &resolved);
        for (targets, resolved) |ch, off| {
            if (std.mem.indexOfScalar(u8, now, ch)) |idx| {
                try t.expectEqual(idx, off);
            } else {
                try t.expect(off <= now.len);
            }
        }

        // Local anchors: in-bounds and order-preserving.
        var prev: usize = 0;
        for (locals) |h| {
            const off = doc.anchorOffset(h);
            try t.expect(off <= now.len);
            try t.expect(off >= prev);
            prev = off;
        }
    }
}

test "property: causal subscription — patch replay reconstructs every version" {
    const gpa = t.allocator;
    var prng = std.Random.DefaultPrng.init(0xcafe);
    const rand = prng.random();

    var doc = try Document.init(gpa, "user");
    defer doc.deinit(gpa);
    var a: PeerDriver = .{ .id = try doc.addPeer(gpa, "peer-a"), .len = 0 };
    var b: PeerDriver = .{ .id = try doc.addPeer(gpa, "peer-b"), .len = 0 };

    // The subscriber: a dumb byte buffer + a cursor. It never reads the
    // rope — only the commit log.
    var mirror: std.ArrayList(u8) = .empty;
    defer mirror.deinit(gpa);
    var cursor: usize = 0;

    for (0..15) |_| {
        try a.takeSnapshot(gpa, &doc);
        try b.takeSnapshot(gpa, &doc);
        const len = doc.text().byteLen();
        var buf: [4]u8 = undefined;
        randomFill(rand, &buf);
        try doc.insert(gpa, rand.uintAtMost(usize, len), &buf);
        try a.randomOps(gpa, &doc, rand, 2);
        try b.randomOps(gpa, &doc, rand, 2);
        _ = try doc.peerCommit(gpa, a.id);
        _ = try doc.peerCommit(gpa, b.id);

        // Drain: apply each commit's patches (descending old-space
        // offset, so earlier offsets stay valid) and check the mirror
        // against the materialized text at that commit's version.
        for (doc.commitsSince(cursor)) |*c| {
            var i = c.patches.len;
            while (i > 0) {
                i -= 1;
                const p = c.patches[i];
                try mirror.replaceRange(gpa, p.offset, p.removed, c.insertedBytes(i));
            }
            var at = try doc.textAt(gpa, c.version);
            defer at.deinit(gpa);
            const want = try at.toOwnedSlice(gpa);
            defer gpa.free(want);
            try t.expectEqualStrings(want, mirror.items);
        }
        cursor = doc.commitCount();
    }

    const final = try ownedText(gpa, &doc);
    defer gpa.free(final);
    try t.expectEqualStrings(final, mirror.items);
}

test "document: snapshots are immutable and version-stamped" {
    const gpa = t.allocator;
    var doc = try Document.init(gpa, "user");
    defer doc.deinit(gpa);
    try doc.insert(gpa, 0, "stable ground");

    var snap = try doc.snapshot(gpa);
    defer snap.deinit(gpa);
    try t.expect(snap.isFullyRealized());

    try doc.insert(gpa, 0, "shifting ");
    const then = try snap.rope.toOwnedSlice(gpa);
    defer gpa.free(then);
    try t.expectEqualStrings("stable ground", then);

    const head = try doc.version(gpa);
    defer gpa.free(head);
    try t.expectEqual(Document.VersionOrder.ancestor, try doc.compareVersions(gpa, snap.version, head));

    // Time travel back to the snapshot's version.
    var at = try doc.textAt(gpa, snap.version);
    defer at.deinit(gpa);
    const back = try at.toOwnedSlice(gpa);
    defer gpa.free(back);
    try t.expectEqualStrings("stable ground", back);
}

test "document: peer lifecycle — duplicates rejected, slots reused" {
    const gpa = t.allocator;
    var doc = try Document.init(gpa, "user");
    defer doc.deinit(gpa);

    const a = try doc.addPeer(gpa, "plugin.fmt");
    try t.expectError(error.DuplicatePeer, doc.addPeer(gpa, "plugin.fmt"));
    try t.expectError(error.DuplicatePeer, doc.addPeer(gpa, "user"));

    doc.removePeer(gpa, a);
    // Same name after removal continues the old agent's numbering —
    // causally sound — and reuses the slot.
    const again = try doc.addPeer(gpa, "plugin.fmt");
    try t.expectEqual(a, again);

    try doc.peerInsert(gpa, again, 0, "hi");
    try t.expect(try doc.peerCommit(gpa, again));
    const text = try ownedText(gpa, &doc);
    defer gpa.free(text);
    try t.expectEqualStrings("hi", text);
}
