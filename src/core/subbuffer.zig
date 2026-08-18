//! Subbuffers ([FIX 11], design §3) — an anchored sub-range of a document
//! that carries its OWN facts, so an embedded language lights up inside a
//! host one: JavaScript inside a `<script>`, a code fence in markdown, a
//! SQL string in Zig. A subbuffer is not a second document — it is a
//! claimed range over the same CRDT replica, which means:
//!
//! - it **rebases for free**: `start`/`end` are anchors in the document's
//!   auto-shifted set (the same mechanism `layers` spans use), so edits
//!   before or inside it move it correctly, and "the range drifted under
//!   me" is inexpressible;
//! - it **inherits the parent locus**: the bytes live where the buffer's
//!   bytes live — no second backing, no second sync;
//! - it carries its own **facts** (`language=javascript`, tags), the input
//!   the mode/predicate engine (§7) matches on to scope keymap layers,
//!   capability `fire`, and grammars to just this range.
//!
//! Mechanism only: this stores claims and answers "what range is this
//! now" / "which claim owns this offset" / "what facts does it carry".
//! WHO claims what (the html plugin seeing a `<script>` node) is policy.

const std = @import("std");
const Allocator = std.mem.Allocator;

const stemma = @import("stemma");
const Document = @import("Document.zig");

pub const Range = Document.Range;
const AnchorHandle = stemma.AnchorSet.Handle;

/// A single claimed range and its facts. Anchored at the head at claim
/// time; resolves to a live range at any later head.
pub const SubBuffer = struct {
    doc: *Document,
    start: AnchorHandle,
    end: AnchorHandle,
    /// Fact name → value, both owned. The small, declared input the
    /// predicate engine reads (language, tags); NOT a general variable bag
    /// (the footgun list refuses those) — claimers set a handful and the
    /// mode model derives everything else.
    facts: std.StringHashMapUnmanaged([]u8) = .empty,

    /// The claim's range at the current head (anchors already shifted).
    pub fn resolve(self: *const SubBuffer) Range {
        const a = self.doc.anchorOffset(self.start);
        const b = self.doc.anchorOffset(self.end);
        return .{ .start = @min(a, b), .end = @max(a, b) };
    }

    pub fn contains(self: *const SubBuffer, offset: usize) bool {
        const r = self.resolve();
        return offset >= r.start and offset <= r.end;
    }

    /// Set (or replace) a fact. Copies both name and value.
    pub fn putFact(self: *SubBuffer, gpa: Allocator, name: []const u8, value: []const u8) Allocator.Error!void {
        const v = try gpa.dupe(u8, value);
        errdefer gpa.free(v);
        const gop = try self.facts.getOrPut(gpa, name);
        if (!gop.found_existing) {
            errdefer _ = self.facts.remove(name);
            gop.key_ptr.* = try gpa.dupe(u8, name);
        } else {
            gpa.free(gop.value_ptr.*);
        }
        gop.value_ptr.* = v;
    }

    pub fn fact(self: *const SubBuffer, name: []const u8) ?[]const u8 {
        return self.facts.get(name);
    }

    fn deinit(self: *SubBuffer, gpa: Allocator) void {
        self.doc.removeAnchor(self.start);
        self.doc.removeAnchor(self.end);
        var it = self.facts.iterator();
        while (it.next()) |e| {
            gpa.free(e.key_ptr.*);
            gpa.free(e.value_ptr.*);
        }
        self.facts.deinit(gpa);
    }
};

/// The per-session registry of claims across all documents (keyed by the
/// document, like `layers.Layers`). Buffer close drops a document's claims.
pub const SubBuffers = struct {
    list: std.ArrayList(*SubBuffer) = .empty,

    pub const empty: SubBuffers = .{};

    pub fn deinit(self: *SubBuffers, gpa: Allocator) void {
        for (self.list.items) |s| {
            s.deinit(gpa);
            gpa.destroy(s);
        }
        self.list.deinit(gpa);
        self.* = .{};
    }

    /// Claim `range` (valid at the current head) on `doc`. The endpoints
    /// bias inward (start .right, end .left) so text typed at either edge
    /// grows the surrounding buffer, not the embedded island — the honest
    /// default for a fenced region.
    pub fn claim(self: *SubBuffers, gpa: Allocator, doc: *Document, range: Range) Allocator.Error!*SubBuffer {
        const sub = try gpa.create(SubBuffer);
        errdefer gpa.destroy(sub);
        const a = try doc.addAnchor(gpa, range.start, .right);
        errdefer doc.removeAnchor(a);
        const b = try doc.addAnchor(gpa, @max(range.start, range.end), .left);
        errdefer doc.removeAnchor(b);
        sub.* = .{ .doc = doc, .start = a, .end = b };
        try self.list.append(gpa, sub);
        return sub;
    }

    /// The innermost claim on `doc` containing `offset` (smallest range
    /// wins — nested fences resolve to the tightest), or null.
    pub fn at(self: *const SubBuffers, doc: *const Document, offset: usize) ?*SubBuffer {
        var best: ?*SubBuffer = null;
        var best_len: usize = std.math.maxInt(usize);
        for (self.list.items) |s| {
            if (s.doc != doc or !s.contains(offset)) continue;
            const r = s.resolve();
            const len = r.end - r.start;
            if (len < best_len) {
                best = s;
                best_len = len;
            }
        }
        return best;
    }

    /// Release one claim (its anchors + facts freed).
    pub fn release(self: *SubBuffers, gpa: Allocator, sub: *SubBuffer) void {
        for (self.list.items, 0..) |s, i| {
            if (s == sub) {
                _ = self.list.swapRemove(i);
                s.deinit(gpa);
                gpa.destroy(s);
                return;
            }
        }
    }

    /// Drop every claim on `doc` (buffer close).
    pub fn dropDoc(self: *SubBuffers, gpa: Allocator, doc: *const Document) void {
        var i: usize = 0;
        while (i < self.list.items.len) {
            const s = self.list.items[i];
            if (s.doc == doc) {
                _ = self.list.swapRemove(i);
                s.deinit(gpa);
                gpa.destroy(s);
            } else i += 1;
        }
    }
};

// ── Tests ───────────────────────────────────────────────────────────

const t = std.testing;

test "subbuffer: a claimed range carries its own facts and rebases" {
    const gpa = t.allocator;
    var doc = try Document.init(gpa, "user");
    defer doc.deinit(gpa);
    //             0         1         2
    //             0123456789012345678901234567
    try doc.insert(gpa, 0, "<script>let x=1</script>");
    var subs: SubBuffers = .empty;
    defer subs.deinit(gpa);

    // Claim the JS island between the tags (offsets 8..15 = "let x=1").
    const js = try subs.claim(gpa, &doc, .{ .start = 8, .end = 15 });
    try js.putFact(gpa, "language", "javascript");

    try t.expectEqualStrings("javascript", js.fact("language").?);
    try t.expectEqual(@as(usize, 8), js.resolve().start);
    try t.expectEqual(@as(usize, 15), js.resolve().end);

    // The innermost claim owns an interior offset, not one outside it.
    try t.expect(subs.at(&doc, 10) == js);
    try t.expect(subs.at(&doc, 2) == null);

    // Insert 7 bytes before the island: the claim rebases (8→15, 15→22),
    // its facts intact — no re-claim, no drift.
    try doc.insert(gpa, 0, "<!--><!"); // 7 bytes at the head
    try t.expectEqual(@as(usize, 15), js.resolve().start);
    try t.expectEqual(@as(usize, 22), js.resolve().end);
    try t.expectEqualStrings("javascript", js.fact("language").?);
    try t.expect(subs.at(&doc, 17) == js);

    // Overwriting a fact replaces it; release frees cleanly.
    try js.putFact(gpa, "language", "typescript");
    try t.expectEqualStrings("typescript", js.fact("language").?);
    subs.release(gpa, js);
    try t.expectEqual(@as(usize, 0), subs.list.items.len);
}

test "subbuffer: nested claims resolve innermost; dropDoc clears" {
    const gpa = t.allocator;
    var doc = try Document.init(gpa, "user");
    defer doc.deinit(gpa);
    try doc.insert(gpa, 0, "0123456789");
    var subs: SubBuffers = .empty;
    defer subs.deinit(gpa);

    const outer = try subs.claim(gpa, &doc, .{ .start = 1, .end = 9 });
    const inner = try subs.claim(gpa, &doc, .{ .start = 3, .end = 6 });
    try t.expect(subs.at(&doc, 4) == inner); // tighter wins
    try t.expect(subs.at(&doc, 8) == outer); // only outer covers 8

    subs.dropDoc(gpa, &doc);
    try t.expectEqual(@as(usize, 0), subs.list.items.len);
}

test {
    std.testing.refAllDecls(@This());
}
