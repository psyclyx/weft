//! The candidate pool + matcher seam (design §5/§8, plan 02 P9): an
//! append-only, columnar candidate store with a built-in bulk `rank`. The
//! single native primitive under the pick loop, ranked in one call per
//! keystroke by the pure matcher in `match.zig`.

const std = @import("std");
const Allocator = std.mem.Allocator;

const stemma = @import("stemma");
const match = @import("match.zig");
const Match = match.Match;
const matchScore = match.matchScore;
const Style = match.Style;

/// An append-only, columnar candidate pool — the single native primitive
/// under the pick loop. Sources push BATCHES (never one item across a
/// boundary; the footgun rule); a matcher ranks the WHOLE pool in one bulk
/// call per keystroke and returns `u32[]` ranked indices. Append-only makes
/// "the set changed under the matcher" inexpressible — the same inversion
/// the CRDT gives text. `version` advances on every append so a matcher's
/// mirror knows in O(1) that its copy is stale; `scope` is always `.local`
/// (your palette is not my palette — what's shared is only the consequence
/// of ACCEPTING, a versioned edit the CRDT merges).
///
/// The built-in `rank` here IS the fallback matcher; a guest `pick/matcher`
/// (plan 05, wasm) is a one-line swap that never crosses the bright line
/// (host invoking guest N=candidate-count times) — it scans its own mirror
/// once and hands back the ranked array.
pub const Pool = struct {
    /// All candidate text concatenated; the columns index into it.
    blob: std.ArrayList(u8) = .empty,
    /// Per-candidate `[start,end)` into `blob`.
    spans: std.ArrayList(Span) = .empty,
    /// Per-candidate metadata (source identity, an opaque accept key, and
    /// an optional document anchor so a candidate that names a position
    /// rebases through edits — the anchor column, [FIX 1]).
    meta: std.ArrayList(Meta) = .empty,
    /// Bumped on every content change; a matcher mirror polls it.
    version: u64 = 0,

    pub const scope: layers_scope = .local;
    const layers_scope = @import("../layers.zig").Scope;

    pub const Span = struct { start: u32, end: u32 };
    pub const Meta = struct {
        source_id: u32,
        /// Resolved at accept (embark: `{source_id,key}` → the real target).
        key: u64 = 0,
        /// A live document anchor for a candidate whose target is a
        /// position; resolve with `doc.anchorOffset` at accept time.
        anchor: ?stemma.AnchorSet.Handle = null,
    };

    pub const empty: Pool = .{};

    pub fn deinit(self: *Pool, gpa: Allocator) void {
        self.blob.deinit(gpa);
        self.spans.deinit(gpa);
        self.meta.deinit(gpa);
        self.* = .{};
    }

    pub fn count(self: *const Pool) usize {
        return self.spans.items.len;
    }

    /// The `i`-th candidate's text (borrowed; valid until the next append).
    pub fn text(self: *const Pool, i: usize) []const u8 {
        const s = self.spans.items[i];
        return self.blob.items[s.start..s.end];
    }

    /// Append a batch of candidates from one source. The ONLY ingest path —
    /// sources always batch. `keys`, if given, are the per-candidate accept
    /// keys (else 0). Bumps `version`.
    pub fn appendBatch(self: *Pool, gpa: Allocator, texts: []const []const u8, source_id: u32, keys: ?[]const u64) Allocator.Error!void {
        try self.blob.ensureUnusedCapacity(gpa, blk: {
            var n: usize = 0;
            for (texts) |txt| n += txt.len;
            break :blk n;
        });
        try self.spans.ensureUnusedCapacity(gpa, texts.len);
        try self.meta.ensureUnusedCapacity(gpa, texts.len);
        for (texts, 0..) |txt, i| {
            const start: u32 = @intCast(self.blob.items.len);
            self.blob.appendSliceAssumeCapacity(txt);
            self.spans.appendAssumeCapacity(.{ .start = start, .end = @intCast(self.blob.items.len) });
            self.meta.appendAssumeCapacity(.{ .source_id = source_id, .key = if (keys) |k| k[i] else 0 });
        }
        self.version +%= 1;
    }

    /// Attach a document anchor to candidate `i` (the anchor column).
    pub fn setAnchor(self: *Pool, i: usize, anchor: stemma.AnchorSet.Handle) void {
        self.meta.items[i].anchor = anchor;
    }

    /// Rank the whole pool against `query` in ONE call and return ranked
    /// candidate indices, best first (non-matches dropped). Caller frees.
    /// The same order the live pick uses (word-boundary, tightness, earliest
    /// start, then stable by index) minus frecency (a pool has no history).
    pub fn rank(self: *const Pool, gpa: Allocator, style: Style, query: []const u8) Allocator.Error![]u32 {
        const Scored = struct { index: u32, m: Match };
        var scored: std.ArrayList(Scored) = .empty;
        defer scored.deinit(gpa);
        for (0..self.count()) |i| {
            if (matchScore(style, query, self.text(i))) |m| {
                try scored.append(gpa, .{ .index = @intCast(i), .m = m });
            }
        }
        std.mem.sort(Scored, scored.items, {}, struct {
            fn lt(_: void, a: Scored, b: Scored) bool {
                if (a.m.boundaries != b.m.boundaries) return a.m.boundaries > b.m.boundaries;
                if (a.m.span != b.m.span) return a.m.span < b.m.span;
                if (a.m.start != b.m.start) return a.m.start < b.m.start;
                return a.index < b.index;
            }
        }.lt);
        const out = try gpa.alloc(u32, scored.items.len);
        for (scored.items, out) |s, *o| o.* = s.index;
        return out;
    }
};

test "pick pool: append batches, rank 100k in one call, anchor rebases" {
    const gpa = std.testing.allocator;
    var pool: Pool = .empty;
    defer pool.deinit(gpa);

    // 100k candidates pushed in batches (never one across a boundary).
    var batch: [1000][]const u8 = undefined;
    var buf: [1000][16]u8 = undefined;
    var b: usize = 0;
    while (b < 100) : (b += 1) {
        for (0..1000) |i| batch[i] = try std.fmt.bufPrint(&buf[i], "cand{d}_{d}", .{ b, i });
        try pool.appendBatch(gpa, &batch, @intCast(b), null);
    }
    try pool.appendBatch(gpa, &.{"zzTARGETzz"}, 999, null); // the needle
    try std.testing.expectEqual(@as(usize, 100_001), pool.count());
    const v_before = pool.version;

    // One bulk rank ranks the whole pool; only the needle matches "TARGET".
    const ranked = try pool.rank(gpa, .orderless, "TARGET");
    defer gpa.free(ranked);
    try std.testing.expectEqual(@as(usize, 1), ranked.len);
    try std.testing.expectEqualStrings("zzTARGETzz", pool.text(ranked[0]));
    try std.testing.expectEqual(v_before, pool.version); // rank is read-only

    // The anchor column: a candidate anchored into a live doc rebases.
    const Document = @import("../Document.zig");
    var doc = try Document.init(gpa, "user");
    defer doc.deinit(gpa);
    try doc.insert(gpa, 0, "abcdef");
    pool.setAnchor(ranked[0], try doc.addAnchor(gpa, 3, .right));
    try doc.insert(gpa, 0, "XX"); // shift everything right by two
    try std.testing.expectEqual(@as(usize, 5), doc.anchorOffset(pool.meta.items[ranked[0]].anchor.?));
}
