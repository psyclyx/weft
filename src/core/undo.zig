//! Per-peer selective undo, by op inverse — never state restoration.
//!
//! `UndoLog` is a *subscriber* of a Document's commit log (a cursor and
//! a tree of steps); the Document knows nothing about undo. Undoing one of
//! your own commits builds its inverse from the commit's own patches
//! (they carry both inserted and removed bytes, so every commit is
//! invertible), *transforms* that inverse through every commit that
//! landed since — your later work, other peers' concurrent work — and
//! applies it as a fresh commit. Other peers' edits are never touched:
//! selective undo is just "invert mine, rebase over everyone else's".
//!
//! History is a TREE of steps (`Node`), rooted at the state before any of
//! your edits. Undo walks to the parent, redo to the child last walked from
//! (undo of an undo — the machinery is symmetric), and a new own commit after
//! an undo starts a BRANCH beside the undone step instead of discarding it.
//! `jump` reaches any node: undo up to the common ancestor, then redo down
//! the other branch — each step through the same gated apply, so a jump is
//! exactly the undos and redos a person could have typed.
//!
//! Grouping: consecutive user commits coalesce into one undo unit until
//! `barrier()`. Dispatch calls it where the grammar DECLARED that a step
//! begins (`step.zig`, `mode.set-undo-step`): a caret motion or a mode change
//! is no boundary of its own.
//!
//! Authority: applying an inverse is applying an edit, so `undo`/`redo`
//! take a `Gate` the one apply site must clear — a narrowed principal
//! cannot reach past its grant by asking for undo instead of a forward
//! edit. A refused unit stays on its stack; when a unit spans several
//! commits, inverses applied before the refusal remain as ordinary
//! commits (the document stays consistent, the unwind is partial).
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

/// Why an undo application was refused — the SAME vocabulary the edit door
/// (`command.Context.edit`) speaks, since it is the same authority question.
pub const Refusal = error{ Unauthorized, OutOfLimit, Collapsed };

pub const Error = Allocator.Error || Refusal;

/// The authority gate every undo application must clear. Undo lands text
/// through inverse ops, so without a gate a narrowed principal could reach
/// past its grant by asking for undo instead of a forward edit. It is a
/// REQUIRED argument of `undo`/`redo`: a caller must NAME its authority
/// (`command.Context.undoGate` for a dispatching principal, `.user_driven`
/// for a human at the keyboard), so no path is silently ungated.
pub const Gate = struct {
    ctx: ?*anyopaque = null,
    admits: *const fn (ctx: ?*anyopaque, repls: []const Document.Replacement) Refusal!void,

    /// A human unwinding their own history on their own keypress — not an
    /// autonomous principal acting, so no grant narrows it.
    pub const user_driven: Gate = .{ .admits = admitAll };

    fn admitAll(_: ?*anyopaque, _: []const Document.Replacement) Refusal!void {}
};

const Group = struct {
    /// Log indices of the commits in this unit, ascending.
    indices: std.ArrayList(usize) = .empty,

    fn deinit(self: *Group, gpa: Allocator) void {
        self.indices.deinit(gpa);
    }
};

/// A node of the history tree: its index in `UndoLog.nodes`, which is also
/// the order steps were taken in.
pub const NodeId = u32;

/// The state before any own edit.
pub const root: NodeId = 0;

/// What a step did, as it was first taken: how many bytes it inserted and
/// removed, and the start of the text it wrote (else of the text it took
/// away) — enough for a tool to tell one step from another.
pub const Summary = struct {
    pub const cap = 32;

    inserted: u32 = 0,
    removed: u32 = 0,
    text_buf: [cap]u8 = undefined,
    text_len: u8 = 0,
    /// Whether `text` is removed text (nothing was inserted).
    text_removed: bool = false,

    pub fn text(self: *const Summary) []const u8 {
        return self.text_buf[0..self.text_len];
    }

    fn add(self: *Summary, c: *const Document.Commit) void {
        self.inserted +|= @intCast(@min(c.bytes.len, std.math.maxInt(u32)));
        self.removed +|= @intCast(@min(c.removed_bytes.len, std.math.maxInt(u32)));
        if (c.bytes.len > 0 and self.text_removed) {
            // Inserted text says more than removed text: it replaces it.
            self.text_len = 0;
            self.text_removed = false;
        }
        const from = if (c.bytes.len > 0) c.bytes else if (self.text_len == 0 or self.text_removed) c.removed_bytes else "";
        if (c.bytes.len == 0 and from.len > 0) self.text_removed = true;
        const room = cap - self.text_len;
        const n = @min(room, from.len);
        @memcpy(self.text_buf[self.text_len..][0..n], from[0..n]);
        self.text_len += @intCast(n);
    }
};

/// Node `id` as a reader of the tree sees it.
pub const NodeInfo = struct {
    parent: NodeId,
    /// On the path from the root to the current node.
    applied: bool,
    /// The child a redo from here walks to.
    redo_child: ?NodeId = null,
    summary: Summary,
};

const Node = struct {
    /// Older than this node; the root is its own parent.
    parent: NodeId,
    /// The commits that last expressed this step: its forward commits while
    /// applied, the inverse commits that undid it while not. Toggling it
    /// inverts exactly these.
    live: Group = .{},
    applied: bool,
    redo_child: ?NodeId = null,
    summary: Summary = .{},
};

pub const UndoLog = struct {
    /// Whose commits this log owns. `.user` is the interactive default;
    /// a spawned peer (`Document.spawnPeer`) gets its own log keyed to its
    /// PeerId, so each identity's undo is truly independent — the design's
    /// per-peer selective undo. Set at construction, never changed.
    author: Document.PeerId = .user,
    cursor: usize = 0,
    /// Every step ever taken, in the order taken: index 0 is the root (the
    /// state before any own edit), and a node's parent is always older than
    /// it. Nodes are never removed, so an index names one step for the life
    /// of the log — what a tool showing the tree hands back to `jump`.
    nodes: std.ArrayList(Node) = .empty,
    /// The node the document is at: every step on the path from the root to
    /// it is applied, every other is not.
    current: NodeId = root,
    /// `current` still accepts newly ingested commits (the step is open).
    open: bool = false,
    /// Depth of `beginUnit`/`endUnit` brackets. While held, `barrier()` does
    /// not close the open unit, so a composite edit whose steps move the
    /// cursor between commits (an operator run once per selection) still
    /// undoes as one.
    held: u32 = 0,
    /// (commit, its inverse) log-index pairs this log created. When an
    /// inverse is transformed through history, a pair that lies wholly
    /// inside the transform window composes to identity — skipping both
    /// sides avoids the collapse artifacts of mapping through a delete
    /// and its own un-delete, and makes linear undo *exact*. Foreign
    /// commits are never in a pair, so concurrency still transforms.
    pairs: std.ArrayList([2]usize) = .empty,
    /// The tree as text, as `describe` last wrote it (borrowed by whoever
    /// asked, until the next `describe`).
    listing: std.ArrayList(u8) = .empty,

    pub const empty: UndoLog = .{};

    pub fn deinit(self: *UndoLog, gpa: Allocator) void {
        for (self.nodes.items) |*n| n.live.deinit(gpa);
        self.nodes.deinit(gpa);
        self.pairs.deinit(gpa);
        self.listing.deinit(gpa);
        self.* = .{};
    }

    /// The whole tree as text, one line per node in the order taken, the
    /// root first — what a tool reads to draw it (`edit.undo-tree`):
    ///
    ///   `<id>\t<parent>\t<flags>\t<inserted>\t<removed>\t<text>`
    ///
    /// `flags` holds `c` for the current node, `a` for a node applied (on the
    /// path to it), `r` for the child its parent's redo walks to, `x` when
    /// `text` is text the step removed. `text` is the step's summary text
    /// (`Summary`), with tabs and line breaks shown as `→` and `⏎`. Folds in
    /// pending own commits first. Borrowed until the next call.
    pub fn describe(self: *UndoLog, gpa: Allocator, doc: *const Document) Allocator.Error![]const u8 {
        try self.ingest(gpa, doc);
        self.listing.clearRetainingCapacity();
        const w = &self.listing;
        for (0..self.nodeCount()) |i| {
            const id: NodeId = @intCast(i);
            const n = self.nodeAt(id).?;
            var flags: [4]u8 = undefined;
            var nf: usize = 0;
            if (id == self.current) {
                flags[nf] = 'c';
                nf += 1;
            }
            if (n.applied) {
                flags[nf] = 'a';
                nf += 1;
            }
            if (id != root and self.nodeAt(n.parent).?.redo_child == id) {
                flags[nf] = 'r';
                nf += 1;
            }
            if (n.summary.text_removed) {
                flags[nf] = 'x';
                nf += 1;
            }
            try w.print(gpa, "{d}\t{d}\t{s}\t{d}\t{d}\t", .{ id, n.parent, flags[0..nf], n.summary.inserted, n.summary.removed });
            const text = n.summary.text();
            // Whole scalars only: the summary may have cut one short.
            var end = text.len;
            while (end > 0 and (std.unicode.utf8ValidateSlice(text[0..end]) == false)) end -= 1;
            for (text[0..end]) |b| switch (b) {
                '\t' => try w.appendSlice(gpa, "→"),
                '\n' => try w.appendSlice(gpa, "⏎"),
                0...8, 11...31, 127 => try w.append(gpa, ' '),
                else => try w.append(gpa, b),
            };
            try w.append(gpa, '\n');
        }
        return w.items;
    }

    /// The node the document is at.
    pub fn currentNode(self: *const UndoLog) NodeId {
        return self.current;
    }

    /// How many nodes the tree holds, the root included (at least one).
    pub fn nodeCount(self: *const UndoLog) usize {
        return @max(self.nodes.items.len, 1);
    }

    /// Node `id` as a reader sees it (the root reads as an empty step that
    /// is its own parent). Null past the end.
    pub fn nodeAt(self: *const UndoLog, id: NodeId) ?NodeInfo {
        if (id == root and self.nodes.items.len == 0) return .{ .parent = root, .applied = true, .summary = .{} };
        if (id >= self.nodes.items.len) return null;
        const n = &self.nodes.items[id];
        return .{ .parent = n.parent, .applied = n.applied, .redo_child = n.redo_child, .summary = n.summary };
    }

    fn ensureRoot(self: *UndoLog, gpa: Allocator) Allocator.Error!void {
        if (self.nodes.items.len == 0) try self.nodes.append(gpa, .{ .parent = root, .applied = true });
    }

    fn skippable(self: *const UndoLog, j: usize, window_start: usize) bool {
        for (self.pairs.items) |p| {
            if ((p[0] == j or p[1] == j) and p[0] >= window_start) return true;
        }
        return false;
    }

    /// Fold newly logged commits into undo bookkeeping: own commits
    /// become (or extend) the open step — a new step is a new CHILD of the
    /// current node, beside any step undone from there, never in place of
    /// one; foreign commits are ignored (transform handles them at undo
    /// time). Call before reading the tree; `undo`/`redo`/`jump` call it
    /// themselves.
    pub fn ingest(self: *UndoLog, gpa: Allocator, doc: *const Document) Allocator.Error!void {
        const total = doc.commitCount();
        while (self.cursor < total) : (self.cursor += 1) {
            const c = doc.commitAt(self.cursor);
            if (c.author != self.author) continue;
            try self.ensureRoot(gpa);
            if (!self.open) {
                const id: NodeId = @intCast(self.nodes.items.len);
                try self.nodes.append(gpa, .{ .parent = self.current, .applied = true });
                self.nodes.items[self.current].redo_child = id;
                self.current = id;
                self.open = true;
            }
            const top = &self.nodes.items[self.current];
            try top.live.indices.append(gpa, self.cursor);
            top.summary.add(c);
        }
    }

    /// Close the open undo unit; the next own commit starts a new one.
    pub fn barrier(self: *UndoLog) void {
        if (self.held > 0) return;
        self.open = false;
    }

    /// Open a composite unit: everything ingested until the matching
    /// `endUnit` is one undo unit, whatever barriers fire in between. Starts
    /// fresh (never extends the unit before it) and nests.
    pub fn beginUnit(self: *UndoLog) void {
        if (self.held == 0) self.open = false;
        self.held += 1;
    }

    /// Close the composite unit `beginUnit` opened; the next own commit
    /// starts a new unit.
    pub fn endUnit(self: *UndoLog) void {
        assert(self.held > 0);
        self.held -= 1;
        if (self.held == 0) self.open = false;
    }

    pub fn canUndo(self: *const UndoLog) bool {
        return self.current != root;
    }

    pub fn canRedo(self: *const UndoLog) bool {
        if (self.nodes.items.len == 0) return false;
        return self.nodes.items[self.current].redo_child != null;
    }

    /// Would `undo` find a unit, counting own commits `ingest` has not folded
    /// in yet? A pure read — availability is asked on every keystroke's
    /// offer sync, and asking must not move the bookkeeping it asks about.
    pub fn hasUndo(self: *const UndoLog, doc: *const Document) bool {
        return self.canUndo() or self.pendingOwn(doc);
    }

    /// Would `redo` find a unit? An own commit still waiting for `ingest`
    /// becomes a new step the moment it is folded in — the node redo would
    /// start from — so it answers no.
    pub fn hasRedo(self: *const UndoLog, doc: *const Document) bool {
        return self.canRedo() and !self.pendingOwn(doc);
    }

    fn pendingOwn(self: *const UndoLog, doc: *const Document) bool {
        var i = self.cursor;
        while (i < doc.commitCount()) : (i += 1) {
            if (doc.commitAt(i).author == self.author) return true;
        }
        return false;
    }

    /// Undo the current step: walk to its parent. Returns false at the root;
    /// refuses (leaving the step applied) when `gate` denies the inverse.
    pub fn undo(self: *UndoLog, gpa: Allocator, doc: *Document, gate: Gate) Error!bool {
        try self.ingest(gpa, doc);
        // Unconditionally, not `barrier()`: the step is about to be undone,
        // so nothing may keep extending it even inside a held unit.
        self.open = false;
        if (self.current == root) return false;
        try self.stepUp(gpa, doc, gate);
        return true;
    }

    /// Redo: walk to the child last walked from here (the branch most
    /// recently undone, or most recently made). Returns false where no step
    /// was ever taken from the current node.
    pub fn redo(self: *UndoLog, gpa: Allocator, doc: *Document, gate: Gate) Error!bool {
        try self.ingest(gpa, doc);
        self.open = false;
        if (self.nodes.items.len == 0) return false;
        const child = self.nodes.items[self.current].redo_child orelse return false;
        try self.stepDown(gpa, doc, child, gate);
        return true;
    }

    /// Bring the document to node `target`, wherever it is in the tree:
    /// undo up to the common ancestor, then redo down to it. Each move is
    /// the gated apply an undo or redo is, so a refusal stops the walk
    /// where it was refused (the document consistent, `current` true to
    /// it). `error.NoSuchNode` for an id the tree never held.
    pub fn jump(self: *UndoLog, gpa: Allocator, doc: *Document, target: NodeId, gate: Gate) (Error || error{NoSuchNode})!void {
        try self.ingest(gpa, doc);
        self.open = false;
        if (target != root and target >= self.nodes.items.len) return error.NoSuchNode;
        if (target == self.current) return;
        // Every ancestor of the target, the target first: a parent is older
        // than its child, so the path is a descending chain of indices.
        var down: std.ArrayList(NodeId) = .empty;
        defer down.deinit(gpa);
        var n = target;
        while (true) {
            try down.append(gpa, n);
            if (n == root) break;
            n = self.nodes.items[n].parent;
        }
        // Up from the current node until the path to the target is met.
        while (std.mem.indexOfScalar(NodeId, down.items, self.current) == null)
            try self.stepUp(gpa, doc, gate);
        // Then down it: the common ancestor's child on the path, and on.
        const at = std.mem.indexOfScalar(NodeId, down.items, self.current).?;
        var i = at;
        while (i > 0) {
            i -= 1;
            try self.stepDown(gpa, doc, down.items[i], gate);
        }
    }

    /// Undo the current step (not the root): its inverse lands, it becomes
    /// its parent's redo child, and the parent is current.
    fn stepUp(self: *UndoLog, gpa: Allocator, doc: *Document, gate: Gate) Error!void {
        const id = self.current;
        assert(id != root);
        try self.toggle(gpa, doc, id, gate);
        const parent = self.nodes.items[id].parent;
        self.nodes.items[parent].redo_child = id;
        self.current = parent;
    }

    /// Redo `child`, a child of the current node.
    fn stepDown(self: *UndoLog, gpa: Allocator, doc: *Document, child: NodeId, gate: Gate) Error!void {
        assert(self.nodes.items[child].parent == self.current);
        try self.toggle(gpa, doc, child, gate);
        self.nodes.items[self.current].redo_child = child;
        self.current = child;
    }

    /// Flip node `id` between applied and undone by inverting the commits
    /// that last expressed it — the forward commits while applied, the
    /// inverse ones while undone. Those new commits are its `live` group now.
    fn toggle(self: *UndoLog, gpa: Allocator, doc: *Document, id: NodeId, gate: Gate) Error!void {
        const inverse = try self.invertGroup(gpa, doc, self.nodes.items[id].live.indices.items, gate);
        const node = &self.nodes.items[id];
        node.live.deinit(gpa);
        node.live = inverse;
        node.applied = !node.applied;
    }

    /// Invert every commit of a unit (newest first — each inversion
    /// lands in the log and the next transform naturally includes it)
    /// and return the resulting commits as a new unit. The commits this
    /// creates are consumed directly (cursor advanced past them), never
    /// re-ingested as undoable.
    fn invertGroup(self: *UndoLog, gpa: Allocator, doc: *Document, indices: []const usize, gate: Gate) Error!Group {
        var out: Group = .{};
        errdefer out.deinit(gpa);
        var i = indices.len;
        while (i > 0) {
            i -= 1;
            const before = doc.commitCount();
            try self.invertCommit(gpa, doc, indices[i], gate);
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
    fn invertCommit(self: *UndoLog, gpa: Allocator, doc: *Document, index: usize, gate: Gate) Error!void {
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
        // THE apply site, hence the ONE place the invoking principal's
        // authority is asked about: an inverse reaches wherever the
        // original commit did, so a narrowed principal must clear the same
        // check a forward edit of these ranges would (see `Gate`). A
        // commit's whole replacement set is judged before any of it lands.
        try gate.admits(gate.ctx, repls.items);
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
    try t.expect(try log.undo(gpa, &doc, .user_driven));
    {
        const s = try doc.text().toOwnedSlice(gpa);
        defer gpa.free(s);
        try t.expectEqualStrings("the very best base text", s);
    }
    try t.expect(try log.undo(gpa, &doc, .user_driven));
    {
        const s = try doc.text().toOwnedSlice(gpa);
        defer gpa.free(s);
        try t.expectEqualStrings("the base text", s);
    }
    try t.expect(try log.undo(gpa, &doc, .user_driven));
    try t.expectEqual(@as(usize, 0), doc.text().byteLen());
    try t.expect(!try log.undo(gpa, &doc, .user_driven));

    // Redo everything back.
    try t.expect(try log.redo(gpa, &doc, .user_driven));
    try t.expect(try log.redo(gpa, &doc, .user_driven));
    try t.expect(try log.redo(gpa, &doc, .user_driven));
    {
        const s = try doc.text().toOwnedSlice(gpa);
        defer gpa.free(s);
        try t.expectEqualStrings("very best base text", s);
    }
    try t.expect(!try log.redo(gpa, &doc, .user_driven));

    // And back again — the stacks stay coherent through cycles.
    try t.expect(try log.undo(gpa, &doc, .user_driven));
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
    try t.expect(try log.undo(gpa, &doc, .user_driven));
    {
        const s = try doc.text().toOwnedSlice(gpa);
        defer gpa.free(s);
        try t.expectEqualStrings("<<SEED>>", s);
    }

    // Redo it: comes back inside the (still present) peer wrapping.
    try t.expect(try log.redo(gpa, &doc, .user_driven));
    {
        const s = try doc.text().toOwnedSlice(gpa);
        defer gpa.free(s);
        try t.expectEqualStrings("<<SE-own-ED>>", s);
    }

    // Undo does NOT touch the peer's commit even as the newest change:
    // only own units are undoable.
    try t.expect(try log.undo(gpa, &doc, .user_driven));
    try t.expect(try log.undo(gpa, &doc, .user_driven)); // seed
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
    try t.expect(try log_a.undo(gpa, &doc, .user_driven));
    {
        const s = try doc.text().toOwnedSlice(gpa);
        defer gpa.free(s);
        try t.expectEqualStrings("base-B-", s);
    }
    // B undoes: only B's insertion unwinds.
    try t.expect(try log_b.undo(gpa, &doc, .user_driven));
    {
        const s = try doc.text().toOwnedSlice(gpa);
        defer gpa.free(s);
        try t.expectEqualStrings("base", s);
    }
    // A's log cannot undo B's work and vice versa — each is empty now.
    try t.expect(!try log_a.undo(gpa, &doc, .user_driven));
    try t.expect(!try log_b.undo(gpa, &doc, .user_driven));
}

fn expectDoc(doc: *const Document, want: []const u8) !void {
    const s = try doc.text().toOwnedSlice(t.allocator);
    defer t.allocator.free(s);
    try t.expectEqualStrings(want, s);
}

/// One own step: `bytes` appended, then the step closed.
fn appendStep(log: *UndoLog, doc: *Document, bytes: []const u8) !void {
    try doc.insert(t.allocator, doc.text().byteLen(), bytes);
    try log.ingest(t.allocator, doc);
    log.barrier();
}

test "undo: a new own commit after an undo BRANCHES — redo takes the new step, the undone one stays reachable" {
    const gpa = t.allocator;
    var doc = try Document.init(gpa, "user");
    defer doc.deinit(gpa);
    var log: UndoLog = .empty;
    defer log.deinit(gpa);

    try doc.insert(gpa, 0, "abc");
    try t.expect(try log.undo(gpa, &doc, .user_driven));
    try t.expect(log.canRedo());
    try doc.insert(gpa, 0, "xyz");
    try log.ingest(gpa, &doc);
    // Nothing to redo from the new step…
    try t.expect(!log.canRedo());
    try t.expect(!try log.redo(gpa, &doc, .user_driven));
    // …and both steps are children of the root: a branch, not a loss.
    try t.expectEqual(@as(usize, 3), log.nodeCount());
    try t.expectEqual(root, log.nodeAt(1).?.parent);
    try t.expectEqual(root, log.nodeAt(2).?.parent);
    try t.expectEqualStrings("abc", log.nodeAt(1).?.summary.text());
    try t.expectEqualStrings("xyz", log.nodeAt(2).?.summary.text());
    try t.expectEqual(@as(NodeId, 2), log.currentNode());

    // Redo from the root walks the branch last walked: the new one.
    try t.expect(try log.undo(gpa, &doc, .user_driven));
    try expectDoc(&doc, "");
    try t.expect(try log.redo(gpa, &doc, .user_driven));
    try expectDoc(&doc, "xyz");

    // The undone step is a jump away, and back.
    try log.jump(gpa, &doc, 1, .user_driven);
    try expectDoc(&doc, "abc");
    try t.expectEqual(@as(NodeId, 1), log.currentNode());
    try t.expect(log.nodeAt(1).?.applied and !log.nodeAt(2).?.applied);
    try log.jump(gpa, &doc, 2, .user_driven);
    try expectDoc(&doc, "xyz");
    try t.expectError(error.NoSuchNode, log.jump(gpa, &doc, 9, .user_driven));

    // What a tool reads: every node, the current one and the path to it
    // marked, and which child redo takes.
    try doc.delete(gpa, .{ .start = 1, .end = 3 });
    try t.expectEqualStrings(
        "0\t0\ta\t0\t0\t\n" ++
            "1\t0\t\t3\t0\tabc\n" ++
            "2\t0\tar\t3\t0\txyz\n" ++
            "3\t2\tcarx\t0\t2\tyz\n",
        try log.describe(gpa, &doc),
    );
}

test "undo: jump across branches — up to the common ancestor, down the other branch" {
    const gpa = t.allocator;
    var doc = try Document.init(gpa, "user");
    defer doc.deinit(gpa);
    var log: UndoLog = .empty;
    defer log.deinit(gpa);

    try appendStep(&log, &doc, "base"); // 1
    try appendStep(&log, &doc, " A"); // 2
    try appendStep(&log, &doc, " B"); // 3
    try t.expect(try log.undo(gpa, &doc, .user_driven));
    try t.expect(try log.undo(gpa, &doc, .user_driven));
    try appendStep(&log, &doc, " C"); // 4, beside 2
    try appendStep(&log, &doc, " D"); // 5
    try expectDoc(&doc, "base C D");
    try t.expectEqual(@as(NodeId, 1), log.nodeAt(4).?.parent);

    try log.jump(gpa, &doc, 3, .user_driven);
    try expectDoc(&doc, "base A B");
    for ([_]bool{ true, true, true, true, false, false }, 0..) |applied, id|
        try t.expectEqual(applied, log.nodeAt(@intCast(id)).?.applied);
    try log.jump(gpa, &doc, 5, .user_driven);
    try expectDoc(&doc, "base C D");
    // Mid-branch, and the root.
    try log.jump(gpa, &doc, 2, .user_driven);
    try expectDoc(&doc, "base A");
    try log.jump(gpa, &doc, root, .user_driven);
    try expectDoc(&doc, "");
    try t.expect(!log.canUndo());
    // Redo from the root now walks toward where the jump came from.
    try t.expect(try log.redo(gpa, &doc, .user_driven));
    try t.expect(try log.redo(gpa, &doc, .user_driven));
    try expectDoc(&doc, "base A");
}

test "undo: collaboration — a jump across branches never undoes a remote peer's commits" {
    const gpa = t.allocator;
    var doc = try Document.init(gpa, "user");
    defer doc.deinit(gpa);
    var log: UndoLog = .empty;
    defer log.deinit(gpa);

    try appendStep(&log, &doc, "SEED"); // 1
    try appendStep(&log, &doc, "-a"); // 2
    try t.expect(try log.undo(gpa, &doc, .user_driven));
    try appendStep(&log, &doc, "-b"); // 3, a branch beside 2

    // A peer, caught up, wraps the text while the tree stands.
    const p = try doc.addPeer(gpa, "peer");
    var s0 = try doc.peerSnapshot(gpa, p);
    s0.deinit(gpa);
    try doc.peerInsert(gpa, p, 0, "<<");
    try doc.peerInsert(gpa, p, 8, ">>");
    _ = try doc.peerCommit(gpa, p);
    try expectDoc(&doc, "<<SEED-b>>");

    // Across to the other branch: our "-b" leaves, our "-a" returns, the
    // peer's wrapping is untouched.
    try log.jump(gpa, &doc, 2, .user_driven);
    try expectDoc(&doc, "<<SEED-a>>");
    // All the way up: only the peer's text is left.
    try log.jump(gpa, &doc, root, .user_driven);
    try expectDoc(&doc, "<<>>");
    // The peer's commit is in no node: the tree holds only our steps.
    try t.expectEqual(@as(usize, 4), log.nodeCount());
    try log.jump(gpa, &doc, 3, .user_driven);
    try expectDoc(&doc, "<<SEED-b>>");
}

test "undo: hasUndo/hasRedo answer before ingest, without moving the log" {
    const gpa = t.allocator;
    var doc = try Document.init(gpa, "user");
    defer doc.deinit(gpa);
    var log: UndoLog = .empty;
    defer log.deinit(gpa);

    try t.expect(!log.hasUndo(&doc));
    try t.expect(!log.hasRedo(&doc));
    // An own commit not yet ingested already counts — availability is read
    // on every keystroke's offer sync, before any undo has run.
    try doc.insert(gpa, 0, "abc");
    try t.expect(log.hasUndo(&doc));
    try t.expectEqual(@as(usize, 0), log.cursor); // asking moved nothing
    try t.expect(try log.undo(gpa, &doc, .user_driven));
    try t.expect(!log.hasUndo(&doc));
    try t.expect(log.hasRedo(&doc));
    // A fresh own commit will clear the redo stack the moment it is folded
    // in, so it already answers no.
    try doc.insert(gpa, 0, "x");
    try t.expect(!log.hasRedo(&doc));
}
