//! Per-peer selective undo, by op inverse — never state restoration.
//!
//! `UndoLog` is a *subscriber* of a Document's commit log (a cursor and
//! two stacks); the Document knows nothing about undo. Undoing one of
//! your own commits builds its inverse from the commit's own patches
//! (they carry both inserted and removed bytes, so every commit is
//! invertible), *transforms* that inverse through every commit that
//! landed since — your later work, other peers' concurrent work — and
//! applies it as a fresh commit. Other peers' edits are never touched:
//! selective undo is just "invert mine, rebase over everyone else's".
//!
//! Redo is undo of an undo (the machinery is symmetric), and a new
//! user-authored commit empties the redo stack.
//!
//! Grouping: consecutive user commits coalesce into one undo unit until
//! `barrier()` (the editor calls it on cursor motion, mode change,
//! command boundaries — vim-flavored units for free).
//!
//! Honesty note: transforming positions through concurrent edits is a
//! positional rebase. If a concurrent edit landed *inside* the range an
//! undo re-deletes, the collapse is bias-resolved (foreign insertions at
//! the boundary survive; interior overlap shrinks the range) — the
//! standard behavior, stated rather than hidden.

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const stemma = @import("stemma");
const Document = @import("Document.zig");
const patch = @import("patch.zig");
const Patch = patch.Patch;
const Bias = stemma.Bias;

/// The offset-mapping kernel lives in position.zig (shared with the
/// capability system's stamped-position rebasing).
const mapOffset = @import("position.zig").mapOffset;

const Group = struct {
    /// Log indices of the commits in this unit, ascending.
    indices: std.ArrayList(usize) = .empty,

    fn deinit(self: *Group, gpa: Allocator) void {
        self.indices.deinit(gpa);
    }
};

pub const UndoLog = struct {
    /// Whose commits this log owns. `.user` is the interactive default;
    /// a spawned peer (`Document.spawnPeer`) gets its own log keyed to its
    /// PeerId, so each identity's undo is truly independent — the design's
    /// per-peer selective undo. Set at construction, never changed.
    author: Document.PeerId = .user,
    cursor: usize = 0,
    undoable: std.ArrayList(Group) = .empty,
    redoable: std.ArrayList(Group) = .empty,
    /// The top of `undoable` still accepts newly ingested commits.
    open: bool = false,
    /// (commit, its inverse) log-index pairs this log created. When an
    /// inverse is transformed through history, a pair that lies wholly
    /// inside the transform window composes to identity — skipping both
    /// sides avoids the collapse artifacts of mapping through a delete
    /// and its own un-delete, and makes linear undo *exact*. Foreign
    /// commits are never in a pair, so concurrency still transforms.
    pairs: std.ArrayList([2]usize) = .empty,

    pub const empty: UndoLog = .{};

    pub fn deinit(self: *UndoLog, gpa: Allocator) void {
        for (self.undoable.items) |*g| g.deinit(gpa);
        self.undoable.deinit(gpa);
        for (self.redoable.items) |*g| g.deinit(gpa);
        self.redoable.deinit(gpa);
        self.pairs.deinit(gpa);
        self.* = .{};
    }

    fn skippable(self: *const UndoLog, j: usize, window_start: usize) bool {
        for (self.pairs.items) |p| {
            if ((p[0] == j or p[1] == j) and p[0] >= window_start) return true;
        }
        return false;
    }

    /// Fold newly logged commits into undo bookkeeping: own commits
    /// become (or extend) the open undo unit and clear the redo stack;
    /// foreign commits are ignored (transform handles them at undo
    /// time). Call before reading either stack; `undo`/`redo` call it
    /// themselves.
    pub fn ingest(self: *UndoLog, gpa: Allocator, doc: *const Document) Allocator.Error!void {
        const total = doc.commitCount();
        while (self.cursor < total) : (self.cursor += 1) {
            const c = doc.commitAt(self.cursor);
            if (c.author != self.author) continue;
            self.clearRedo(gpa);
            if (!self.open) {
                try self.undoable.append(gpa, .{});
                self.open = true;
            }
            const top = &self.undoable.items[self.undoable.items.len - 1];
            try top.indices.append(gpa, self.cursor);
        }
    }

    /// Close the open undo unit; the next own commit starts a new one.
    pub fn barrier(self: *UndoLog) void {
        self.open = false;
    }

    fn clearRedo(self: *UndoLog, gpa: Allocator) void {
        for (self.redoable.items) |*g| g.deinit(gpa);
        self.redoable.clearRetainingCapacity();
    }

    pub fn canUndo(self: *const UndoLog) bool {
        return self.undoable.items.len > 0;
    }

    pub fn canRedo(self: *const UndoLog) bool {
        return self.redoable.items.len > 0;
    }

    /// Undo the newest unit. Returns false if there is nothing to undo.
    pub fn undo(self: *UndoLog, gpa: Allocator, doc: *Document) Allocator.Error!bool {
        try self.ingest(gpa, doc);
        self.barrier();
        var group = self.undoable.pop() orelse return false;
        defer group.deinit(gpa);
        const inverse = try self.invertGroup(gpa, doc, group.indices.items);
        try self.redoable.append(gpa, inverse);
        return true;
    }

    /// Redo the newest undone unit. Returns false if there is none.
    pub fn redo(self: *UndoLog, gpa: Allocator, doc: *Document) Allocator.Error!bool {
        try self.ingest(gpa, doc);
        var group = self.redoable.pop() orelse return false;
        defer group.deinit(gpa);
        const inverse = try self.invertGroup(gpa, doc, group.indices.items);
        try self.undoable.append(gpa, inverse);
        self.open = false;
        return true;
    }

    /// Invert every commit of a unit (newest first — each inversion
    /// lands in the log and the next transform naturally includes it)
    /// and return the resulting commits as a new unit. The commits this
    /// creates are consumed directly (cursor advanced past them), never
    /// re-ingested as undoable.
    fn invertGroup(self: *UndoLog, gpa: Allocator, doc: *Document, indices: []const usize) Allocator.Error!Group {
        var out: Group = .{};
        errdefer out.deinit(gpa);
        var i = indices.len;
        while (i > 0) {
            i -= 1;
            const before = doc.commitCount();
            try self.invertCommit(gpa, doc, indices[i]);
            // 0 or 1 commit results (empty inverses are not logged).
            assert(doc.commitCount() <= before + 1);
            if (doc.commitCount() > before) {
                try out.indices.append(gpa, before);
                try self.pairs.append(gpa, .{ indices[i], before });
            }
            self.cursor = doc.commitCount();
        }
        return out;
    }

    /// Build the inverse of log commit `index`, transform it through
    /// every later commit (skipping balanced pairs — see `pairs`), and
    /// apply it as one fresh user commit.
    fn invertCommit(self: *UndoLog, gpa: Allocator, doc: *Document, index: usize) Allocator.Error!void {
        const c = doc.commitAt(index);

        var repls: std.ArrayList(Document.Replacement) = .empty;
        defer repls.deinit(gpa);

        for (c.patches, 0..) |p, k| {
            // Inverse in post-commit coordinates: the inserted run comes
            // back out, the removed bytes go back in.
            var start = patch.newOffsetOf(c.patches, k);
            var end = start + p.inserted;
            // Rebase over everything that landed after this commit. A
            // commit's patches are old-space, i.e. the coordinate space
            // right before it applied — exactly the space `start`/`end`
            // are in when we reach it, so the transforms chain (a
            // skipped balanced pair contributes identity).
            for (index + 1..doc.commitCount()) |j| {
                if (self.skippable(j, index + 1)) continue;
                const later = doc.commitAt(j).patches;
                start = mapOffset(later, start, .right);
                end = mapOffset(later, end, .left);
                if (end < start) end = start;
            }
            const removed = c.removedBytes(k);
            if (end == start and removed.len == 0) continue;
            try repls.append(gpa, .{ .range = .{ .start = start, .end = end }, .bytes = removed });
        }
        if (repls.items.len == 0) return;

        // Replacements can lose ascending order or overlap only if later
        // commits collapsed ranges together; merge conservatively.
        normalize(&repls);
        // Author the inverse as THIS log's identity so it is that peer's
        // own unit (a spawned peer's undo never lands as the user's edit).
        if (self.author == .user) {
            try doc.replaceAll(gpa, repls.items);
        } else {
            try doc.peerReplaceAll(gpa, self.author, repls.items);
        }
    }
};

/// Sort ascending and merge overlapping/touching replacements so
/// `replaceAll`'s non-overlap contract holds even after collapses.
fn normalize(repls: *std.ArrayList(Document.Replacement)) void {
    const items = repls.items;
    std.mem.sort(Document.Replacement, items, {}, struct {
        fn lt(_: void, a: Document.Replacement, b: Document.Replacement) bool {
            return a.range.start < b.range.start;
        }
    }.lt);
    var w: usize = 0;
    for (items[0..], 0..) |r, i| {
        if (i == 0) {
            items[w] = r;
            w += 1;
            continue;
        }
        const prev = &items[w - 1];
        if (r.range.start < prev.range.end) {
            // Overlap from a collapse: extend the deletion; drop the
            // later re-insertion (its content was concurrent-deleted).
            if (r.range.end > prev.range.end) prev.range.end = r.range.end;
        } else {
            items[w] = r;
            w += 1;
        }
    }
    repls.items.len = w;
}

// ── Tests ───────────────────────────────────────────────────────────

const t = std.testing;

test "mapOffset: boundary bias around insertions and deletions" {
    // One patch: replace [4,7) with 2 bytes.
    const ps = [_]Patch{.{ .offset = 4, .removed = 3, .inserted = 2 }};
    try t.expectEqual(@as(usize, 2), mapOffset(&ps, 2, .left));
    try t.expectEqual(@as(usize, 4), mapOffset(&ps, 5, .left)); // collapse
    try t.expectEqual(@as(usize, 9), mapOffset(&ps, 10, .right)); // past: -1
    // Pure insertion at 4 of 3 bytes.
    const ins = [_]Patch{.{ .offset = 4, .removed = 0, .inserted = 3 }};
    try t.expectEqual(@as(usize, 4), mapOffset(&ins, 4, .left));
    try t.expectEqual(@as(usize, 7), mapOffset(&ins, 4, .right));
}

test "undo: solo round trip — undo-all restores, redo-all replays" {
    const gpa = t.allocator;
    var doc = try Document.init(gpa, "user");
    defer doc.deinit(gpa);
    var log: UndoLog = .empty;
    defer log.deinit(gpa);

    try doc.insert(gpa, 0, "the base text");
    try log.ingest(gpa, &doc);
    log.barrier(); // the seed is its own unit

    try doc.insert(gpa, 3, " very");
    try doc.insert(gpa, 8, " best");
    try log.ingest(gpa, &doc);
    log.barrier();
    try doc.delete(gpa, .{ .start = 0, .end = 4 });

    const full = try doc.text().toOwnedSlice(gpa);
    defer gpa.free(full);
    try t.expectEqualStrings("very best base text", full);

    // Undo delete, then the coalesced insert pair, then the seed.
    try t.expect(try log.undo(gpa, &doc));
    {
        const s = try doc.text().toOwnedSlice(gpa);
        defer gpa.free(s);
        try t.expectEqualStrings("the very best base text", s);
    }
    try t.expect(try log.undo(gpa, &doc));
    {
        const s = try doc.text().toOwnedSlice(gpa);
        defer gpa.free(s);
        try t.expectEqualStrings("the base text", s);
    }
    try t.expect(try log.undo(gpa, &doc));
    try t.expectEqual(@as(usize, 0), doc.text().byteLen());
    try t.expect(!try log.undo(gpa, &doc));

    // Redo everything back.
    try t.expect(try log.redo(gpa, &doc));
    try t.expect(try log.redo(gpa, &doc));
    try t.expect(try log.redo(gpa, &doc));
    {
        const s = try doc.text().toOwnedSlice(gpa);
        defer gpa.free(s);
        try t.expectEqualStrings("very best base text", s);
    }
    try t.expect(!try log.redo(gpa, &doc));

    // And back again — the stacks stay coherent through cycles.
    try t.expect(try log.undo(gpa, &doc));
    {
        const s = try doc.text().toOwnedSlice(gpa);
        defer gpa.free(s);
        try t.expectEqualStrings("the very best base text", s);
    }
}

test "undo: selective — own edits unwind, concurrent peer edits survive" {
    const gpa = t.allocator;
    var doc = try Document.init(gpa, "user");
    defer doc.deinit(gpa);
    var log: UndoLog = .empty;
    defer log.deinit(gpa);

    try doc.insert(gpa, 0, "SEED");
    try log.ingest(gpa, &doc);
    log.barrier();

    const p = try doc.addPeer(gpa, "peer");

    // User edits inside the seed; peer concurrently wraps it.
    var s0 = try doc.peerSnapshot(gpa, p);
    s0.deinit(gpa);
    try doc.insert(gpa, 2, "-own-");
    try log.ingest(gpa, &doc);
    log.barrier();
    try doc.peerInsert(gpa, p, 0, "<<");
    try doc.peerInsert(gpa, p, 6, ">>"); // end of peer's stale view
    _ = try doc.peerCommit(gpa, p);

    {
        const s = try doc.text().toOwnedSlice(gpa);
        defer gpa.free(s);
        try t.expectEqualStrings("<<SE-own-ED>>", s);
    }

    // Undo own insertion: peer's wrapping must be untouched.
    try t.expect(try log.undo(gpa, &doc));
    {
        const s = try doc.text().toOwnedSlice(gpa);
        defer gpa.free(s);
        try t.expectEqualStrings("<<SEED>>", s);
    }

    // Redo it: comes back inside the (still present) peer wrapping.
    try t.expect(try log.redo(gpa, &doc));
    {
        const s = try doc.text().toOwnedSlice(gpa);
        defer gpa.free(s);
        try t.expectEqualStrings("<<SE-own-ED>>", s);
    }

    // Undo does NOT touch the peer's commit even as the newest change:
    // only own units are undoable.
    try t.expect(try log.undo(gpa, &doc));
    try t.expect(try log.undo(gpa, &doc)); // seed
    {
        const s = try doc.text().toOwnedSlice(gpa);
        defer gpa.free(s);
        try t.expectEqualStrings("<<>>", s);
    }
}

test "undo: spawned peers each undo only their own edits" {
    const gpa = t.allocator;
    var doc = try Document.init(gpa, "user");
    defer doc.deinit(gpa);
    try doc.insert(gpa, 0, "base");

    // Two spawned sub-identities, each with its own undo log.
    const a = try doc.spawnPeer(gpa, "agent.a", .edit);
    const b = try doc.spawnPeer(gpa, "repl.b", .edit);
    try t.expectEqual(@import("authority.zig").Grade.edit, a.grade); // min(own, edit)
    var log_a: UndoLog = .{ .author = a.id };
    defer log_a.deinit(gpa);
    var log_b: UndoLog = .{ .author = b.id };
    defer log_b.deinit(gpa);

    // A appends "-A-", then B appends "-B-".
    try doc.peerReplaceAll(gpa, a.id, &.{.{ .range = .{ .start = 4, .end = 4 }, .bytes = "-A-" }});
    try log_a.ingest(gpa, &doc);
    log_a.barrier();
    const end = doc.text().byteLen();
    try doc.peerReplaceAll(gpa, b.id, &.{.{ .range = .{ .start = end, .end = end }, .bytes = "-B-" }});
    try log_b.ingest(gpa, &doc);
    log_b.barrier();
    {
        const s = try doc.text().toOwnedSlice(gpa);
        defer gpa.free(s);
        try t.expectEqualStrings("base-A--B-", s);
    }

    // A undoes: only A's insertion unwinds; B's survives (distinct undo).
    try t.expect(try log_a.undo(gpa, &doc));
    {
        const s = try doc.text().toOwnedSlice(gpa);
        defer gpa.free(s);
        try t.expectEqualStrings("base-B-", s);
    }
    // B undoes: only B's insertion unwinds.
    try t.expect(try log_b.undo(gpa, &doc));
    {
        const s = try doc.text().toOwnedSlice(gpa);
        defer gpa.free(s);
        try t.expectEqualStrings("base", s);
    }
    // A's log cannot undo B's work and vice versa — each is empty now.
    try t.expect(!try log_a.undo(gpa, &doc));
    try t.expect(!try log_b.undo(gpa, &doc));
}

test "undo: new own commit clears redo" {
    const gpa = t.allocator;
    var doc = try Document.init(gpa, "user");
    defer doc.deinit(gpa);
    var log: UndoLog = .empty;
    defer log.deinit(gpa);

    try doc.insert(gpa, 0, "abc");
    try t.expect(try log.undo(gpa, &doc));
    try t.expect(log.canRedo());
    try doc.insert(gpa, 0, "xyz");
    try log.ingest(gpa, &doc);
    try t.expect(!log.canRedo());
    try t.expect(!try log.redo(gpa, &doc));
}
