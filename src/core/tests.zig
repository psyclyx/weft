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

/// A registry holding the grammars these tests highlight with, registered the
/// SAME way config does it — there is no built-in set to fall back on, so a
/// test that wants zig has to ask for zig, exactly like a user's config. The
/// search path comes from the build (the nix shell's `WEFT_GRAMMAR_PATH`),
/// which is the only thing the test knows that a user wouldn't.
fn testRuntime(gpa: Allocator) !core.syntax.Runtime {
    var rt: core.syntax.Runtime = .empty;
    errdefer rt.deinit(gpa);
    try rt.setSearchPath(gpa, @import("build_options").grammar_path);
    try rt.add(gpa, .{ .extensions = ".zig", .grammar = "zig", .symbol = "tree_sitter_zig" });
    try rt.add(gpa, .{ .extensions = ".nix", .grammar = "nix", .symbol = "tree_sitter_nix" });
    return rt;
}

test "syntax: application lookup goes through the runtime grammar registry" {
    var runtime = try testRuntime(t.allocator);
    defer runtime.deinit(t.allocator);
    try t.expect(runtime.forPath("demo.zig") != null);
    try t.expect(runtime.forPath("demo.unknown") == null);
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

// ── Editor (milestone 4) ────────────────────────────────────────────

const Editor = core.Editor;
const task = core.task;

test "editor: typing, movement, selection, vim-flavored undo units" {
    const gpa = t.allocator;
    var pool = try task.Pool.init(gpa, .{ .threads = 1 });
    defer pool.deinit();
    var ed = try Editor.init(gpa, pool, "user");
    defer ed.deinit(gpa);

    try ed.insertText(gpa, "hello world");
    try t.expectEqual(@as(usize, 11), ed.cursorOffset());

    // Move to line start, type — the placement is an undo barrier.
    ed.placeCursor(0);
    try ed.insertText(gpa, ">> ");
    {
        const s = try ed.text().toOwnedSlice(gpa);
        defer gpa.free(s);
        try t.expectEqualStrings(">> hello world", s);
    }
    try t.expect(try ed.undo(gpa, .user_driven));
    {
        const s = try ed.text().toOwnedSlice(gpa);
        defer gpa.free(s);
        try t.expectEqualStrings("hello world", s);
    }
    try t.expect(try ed.undo(gpa, .user_driven));
    try t.expectEqual(@as(usize, 0), ed.text().byteLen());
    try t.expect(try ed.redo(gpa, .user_driven));
    try t.expect(try ed.redo(gpa, .user_driven));

    // Selection replace is one undoable unit.
    ed.placeCursor(0);
    try ed.setMark(gpa);
    ed.moveRight();
    ed.moveRight();
    ed.moveRight();
    try ed.insertText(gpa, "**");
    {
        const s = try ed.text().toOwnedSlice(gpa);
        defer gpa.free(s);
        try t.expectEqualStrings("**hello world", s);
    }
    try t.expect(try ed.undo(gpa, .user_driven));
    {
        const s = try ed.text().toOwnedSlice(gpa);
        defer gpa.free(s);
        try t.expectEqualStrings(">> hello world", s);
    }
}

test "editor: vertical movement with goal column, utf-8 safe" {
    const gpa = t.allocator;
    var pool = try task.Pool.init(gpa, .{ .threads = 1 });
    defer pool.deinit();
    var ed = try Editor.init(gpa, pool, "user");
    defer ed.deinit(gpa);

    // Word/line motions now live in the `motions` plugin; core keeps only the
    // vertical goal-column step (moveDown/moveVertical) and utf-8 safety.
    try ed.insertText(gpa, "first_long line α\nab\nthird θθ line");
    ed.placeCursor(ed.text().lineRange(0).end); // col past short line's length
    ed.moveDown(); // clamps to "ab" end
    const p1 = ed.text().offsetToPoint(ed.cursorOffset());
    try t.expectEqual(@as(usize, 1), p1.row);
    try t.expectEqual(@as(usize, 2), p1.col);
    ed.moveDown(); // goal column sticks, snaps to scalar boundary
    const p2 = ed.text().offsetToPoint(ed.cursorOffset());
    try t.expectEqual(@as(usize, 2), p2.row);

    // Backspace across a multi-byte scalar.
    ed.placeCursor(ed.text().byteLen());
    try ed.deleteBackward(gpa);
    try ed.deleteBackward(gpa);
    const s = try ed.text().toOwnedSlice(gpa);
    defer gpa.free(s);
    try t.expect(std.unicode.utf8ValidateSlice(s));
}

test "editor: folded rows are hidden and vertical motion skips them" {
    const gpa = t.allocator;
    var pool = try task.Pool.init(gpa, .{ .threads = 1 });
    defer pool.deinit();
    var ed = try Editor.init(gpa, pool, "user");
    defer ed.deinit(gpa);

    // Four rows; fold the whole body of row 1 ("bbb").
    try ed.insertText(gpa, "aaa\nbbb\nccc\nddd");
    const r1 = ed.text().lineRange(1);

    var store: core.layers.Layers = .empty;
    defer store.deinit(gpa);
    const layer = try store.claim(gpa, &ed.doc, "folds", .local, "test");
    try layer.appendSpan(gpa, .{ .start = r1.start, .end = r1.end, .kind = 0, .message = "", .face = .{ .invisible = true } });
    ed.fold_layer = layer;

    try t.expect(ed.rowHidden(1));
    try t.expect(!ed.rowHidden(0));
    try t.expect(!ed.rowHidden(2));
    // Down from row 0 skips the folded row 1, landing on row 2.
    try t.expectEqual(@as(?usize, 2), ed.nextVisibleRow(0, 1, ed.text().lineCount()));
    ed.placeCursor(ed.text().lineRange(0).start);
    ed.moveDown();
    try t.expectEqual(@as(usize, 2), ed.text().offsetToPoint(ed.cursorOffset()).row);
    // stepOffset (the guest line-step primitive) skips it too.
    const stepped = ed.stepOffset(ed.text().lineRange(0).start, .fwd, .line);
    try t.expectEqual(@as(usize, 2), ed.text().offsetToPoint(stepped).row);
}

test "editor: save request round trip + dirty tracking" {
    const gpa = t.allocator;
    var tmp_dir = t.tmpDir(.{});
    defer tmp_dir.cleanup();
    const path = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/doc.txt", .{tmp_dir.sub_path});
    defer gpa.free(path);

    var pool = try task.Pool.init(gpa, .{ .threads = 1 });
    defer pool.deinit();
    var ed = try Editor.init(gpa, pool, "user");
    defer ed.deinit(gpa);

    // Fresh empty editor: no file, not dirty in any meaningful sense.
    try ed.insertText(gpa, "content to keep\n");
    try t.expect(try ed.isDirty(gpa));

    // Adopt a path by saving through the file host: write, then open.
    try ed.adoptPath(gpa, path);
    try ed.requestSave(gpa);
    while (!ed.pollSave(gpa)) std.Thread.yield() catch {};
    try t.expect(!try ed.isDirty(gpa));

    const on_disk = try core.file.readAlloc(gpa, path);
    defer gpa.free(on_disk);
    try t.expectEqualStrings("content to keep\n", on_disk);

    try ed.insertText(gpa, "more");
    try t.expect(try ed.isDirty(gpa));

    // A second editor opens the file via the host.fs peer.
    var ed2 = try Editor.init(gpa, pool, "user2");
    defer ed2.deinit(gpa);
    try ed2.openFile(gpa, path);
    try t.expect(!try ed2.isDirty(gpa));
    const s = try ed2.text().toOwnedSlice(gpa);
    defer gpa.free(s);
    try t.expectEqualStrings("content to keep\n", s);
    // The load is not undoable (host mutation, not user).
    try t.expect(!try ed2.undo(gpa, .user_driven));
}

// ── Plugins (milestone 5) ───────────────────────────────────────────

const TestHost = struct {
    pool: *task.Pool,
    buffers: core.Buffers,
    commands: core.command.Commands,
    keymap: core.Keymap,
    /// The ONE shared Container `caps`/`actions` bind into (task #19).
    container: core.container.Container,
    head: core.Head,
    caps: core.Caps,
    actions: core.Actions,
    quit: bool,
    ctx: core.command.Context,

    fn init(gpa: Allocator, host: *TestHost) !void {
        host.pool = try task.Pool.init(gpa, .{ .threads = 1 });
        host.buffers = try core.Buffers.init(gpa, host.pool, "user");
        host.commands = .empty;
        host.keymap = .empty;
        host.head = .empty;
        host.container = core.container.Container.init(gpa);
        host.caps = core.Caps.init(gpa, core.task.nowNs, &host.container);
        host.actions = core.Actions.init(gpa, &host.container);
        host.quit = false;
        host.ctx = .{
            .gpa = gpa,
            .buffers = &host.buffers,
            .commands = &host.commands,
            .keymap = &host.keymap,
            .actions = &host.actions,
            .caps = &host.caps,
            .quit = &host.quit,
            .head = &host.head,
        };
        try core.builtins.install(gpa, &host.commands, &host.keymap, &host.head, &host.actions);
    }

    fn editor(host: *TestHost) *Editor {
        return host.buffers.active().textEditor().?;
    }

    fn deinit(host: *TestHost, gpa: Allocator) void {
        host.actions.deinit();
        host.caps.deinit();
        host.container.deinit();
        host.head.deinit(gpa);
        host.keymap.deinit(gpa);
        host.commands.deinit(gpa);
        host.buffers.deinit(gpa);
        host.pool.deinit();
    }
};

// ── Authority: attribution + the grade gate (plan 01, phases 1–2) ───

test "authority: a view grade refuses edits, forms no ghost, and echoes" {
    const gpa = t.allocator;
    var host: TestHost = undefined;
    try TestHost.init(gpa, &host);
    defer host.deinit(gpa);

    host.editor().doc.my_grant = .view;
    const before = host.editor().text().byteLen();
    // The user path (default principal) is refused; the replica is untouched
    // and an honest echo is set — no divergent local ghost.
    _ = try core.command.run(&host.commands, &host.ctx, "insert-text", &.{.{ .string = "x" }});
    try t.expectEqual(before, host.editor().text().byteLen());
    try t.expectEqualStrings("read-only: view access", host.head.echo.items);

    // With edit grade restored, the same command applies.
    host.editor().doc.my_grant = .own;
    _ = try core.command.run(&host.commands, &host.ctx, "insert-text", &.{.{ .string = "x" }});
    try t.expectEqual(before + 1, host.editor().text().byteLen());

    // A read-only buffer is refused by the same door, and says which refusal
    // it was — the builtin holds no permission check of its own.
    host.buffers.active().read_only = true;
    host.head.echo.clearRetainingCapacity();
    _ = try core.command.run(&host.commands, &host.ctx, "insert-text", &.{.{ .string = "x" }});
    try t.expectEqual(before + 1, host.editor().text().byteLen());
    try t.expectEqualStrings("read-only buffer", host.head.echo.items);
}

test "entries: a view carries no editor — text ops refuse politely, undo is a no-op" {
    const gpa = t.allocator;
    var host: TestHost = undefined;
    try TestHost.init(gpa, &host);
    defer host.deinit(gpa);

    const view = try host.buffers.createView(gpa, "files: /tmp", "files");
    try host.buffers.switchTo(gpa, view, &host.head, &host.keymap);
    const entry = host.buffers.get(view).?;
    try t.expect(entry.textEditor() == null);
    try t.expectEqualStrings("files", entry.tool); // still resolves providers

    // Typing, deleting, and moving the caret are echoed refusals, not errors —
    // the same door the grade gate and read-only flag report through.
    for ([_][]const u8{ "delete-backward", "cursor-left", "undo-barrier" }) |cmd| {
        host.head.echo.clearRetainingCapacity();
        _ = try core.command.run(&host.commands, &host.ctx, cmd, &.{});
        try t.expectEqualStrings("no text in this view", host.head.echo.items);
    }
    host.head.echo.clearRetainingCapacity();
    _ = try core.command.run(&host.commands, &host.ctx, "insert-text", &.{.{ .string = "x" }});
    try t.expectEqualStrings("no text in this view", host.head.echo.items);

    // Undo reports "nothing undone" instead of reaching a stand-in history.
    host.head.echo.clearRetainingCapacity();
    const undone = try core.command.run(&host.commands, &host.ctx, "undo", &.{});
    try t.expect(undone.boolean == false);
    try t.expectEqualStrings("no text in this view", host.head.echo.items);
}

// ── Syntax (milestone 7) ────────────────────────────────────────────

test "syntax: incremental highlight tracks edits and peer merges" {
    const gpa = t.allocator;
    var doc = try Document.init(gpa, "user");
    defer doc.deinit(gpa);
    try doc.insert(gpa, 0, "const x = 42; // note\n");

    var spec_rt = try testRuntime(gpa);
    defer spec_rt.deinit(gpa);
    const spec = spec_rt.forPath("demo.zig").?;
    const syn = try core.syntax.Syntax.create(gpa, &spec_rt, spec, &doc);
    defer syn.destroy();

    const whole: stemma.Range = .{ .start = 0, .end = doc.text().byteLen() };
    {
        const classes = try syn.paint(gpa, whole);
        defer gpa.free(classes);
        // "const" is a keyword; "42" a number; the comment a comment.
        try t.expectEqual(core.syntax.Class.keyword, classes[0]);
        try t.expectEqual(core.syntax.Class.number, classes[10]);
        try t.expectEqual(core.syntax.Class.comment, classes[15]);
    }

    // Edit through the document (user + a peer) and resync.
    try doc.insert(gpa, 0, "// lead\n");
    const p = try doc.addPeer(gpa, "plug");
    var s = try doc.peerSnapshot(gpa, p);
    s.deinit(gpa);
    try doc.peerInsert(gpa, p, doc.text().byteLen(), "var y = \"str\";\n");
    _ = try doc.peerCommit(gpa, p);
    try t.expect(try syn.sync(gpa, &doc));

    const all: stemma.Range = .{ .start = 0, .end = doc.text().byteLen() };
    const classes = try syn.paint(gpa, all);
    defer gpa.free(classes);
    const text = try doc.text().toOwnedSlice(gpa);
    defer gpa.free(text);
    // The leading comment, the shifted keyword, and the peer's string.
    try t.expectEqual(core.syntax.Class.comment, classes[0]);
    const const_at = std.mem.indexOf(u8, text, "const").?;
    try t.expectEqual(core.syntax.Class.keyword, classes[const_at]);
    const str_at = std.mem.indexOf(u8, text, "\"str\"").?;
    try t.expectEqual(core.syntax.Class.string, classes[str_at + 1]);
}

test "syntax: tree queries — node-at-offset, ancestors, and captures" {
    const gpa = t.allocator;
    var doc = try Document.init(gpa, "user");
    defer doc.deinit(gpa);
    try doc.insert(gpa, 0, "const x = 42;\n");

    var spec_rt = try testRuntime(gpa);
    defer spec_rt.deinit(gpa);
    const spec = spec_rt.forPath("demo.zig").?;
    const syn = try core.syntax.Syntax.create(gpa, &spec_rt, spec, &doc);
    defer syn.destroy();

    // node-at-offset: the "42" literal is a number node.
    const num_at = std.mem.indexOf(u8, "const x = 42;\n", "42").?;
    const node = syn.nodeAt(num_at).?;
    try t.expectEqual(num_at, node.start);
    try t.expectEqual(num_at + 2, node.end);
    try t.expect(std.mem.indexOf(u8, node.kind, "integer") != null or
        std.mem.indexOf(u8, node.kind, "number") != null);

    // ancestors are outermost-first (root ... → the leaf at the offset).
    const chain = try syn.ancestorsAt(gpa, num_at);
    defer gpa.free(chain);
    try t.expect(chain.len >= 2);
    try t.expectEqualStrings("source_file", chain[0].kind); // zig grammar root
    try t.expect(chain[chain.len - 1].start <= num_at and chain[chain.len - 1].end >= num_at + 2);

    // an arbitrary query captures what it names — build it from the real
    // grammar node kind so the test is grammar-version agnostic.
    var qbuf: [64]u8 = undefined;
    const scm = try std.fmt.bufPrint(&qbuf, "({s}) @n", .{node.kind});
    const caps = try syn.queryCaptures(gpa, scm, .{ .start = 0, .end = doc.text().byteLen() });
    defer {
        for (caps) |cp| gpa.free(cp.name);
        gpa.free(caps);
    }
    try t.expectEqual(@as(usize, 1), caps.len);
    try t.expectEqualStrings("n", caps[0].name);
    try t.expectEqual(num_at, caps[0].start);

    // a malformed query traps (never a silent empty result).
    try t.expectError(error.QueryLoad, syn.queryCaptures(gpa, "(nonsense_node", .{ .start = 0, .end = 1 }));
}

// ── Syntax: async initial parse (open must not block) ───────────────
//
// `createAsync` is what the interactive `open` path uses (unlike the
// `create` calls above, which stay synchronous for tests/tools that want
// a tree back immediately). The initial full parse — the one tree-sitter
// cost that scales with the WHOLE file — runs on a pool worker instead
// of inline; `sync` adopts the tree once it lands.

test "syntax: createAsync returns before the initial parse runs" {
    const gpa = t.allocator;
    var pool = try task.Pool.init(gpa, .{ .threads = 1 });
    defer pool.deinit();
    var doc = try Document.init(gpa, "user");
    defer doc.deinit(gpa);

    // A synthetic large file: many repeated top-level declarations. The
    // assertion below is structural (a parse-ran seam), not wall-clock —
    // it holds no matter how big this actually is or how fast the
    // worker thread gets scheduled.
    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(gpa);
    for (0..20_000) |i| {
        var line_buf: [64]u8 = undefined;
        const line = try std.fmt.bufPrint(&line_buf, "const x{d} = {d}; // note {d}\n", .{ i, i, i });
        try src.appendSlice(gpa, line);
    }
    try doc.insert(gpa, 0, src.items);

    var spec_rt = try testRuntime(gpa);
    defer spec_rt.deinit(gpa);
    const spec = spec_rt.forPath("big.zig").?;
    const syn = try core.syntax.Syntax.createAsync(gpa, pool, &spec_rt, spec, &doc);
    defer syn.destroy();

    // No one but `sync`/`destroy` ever clears `pending_initial` or sets
    // `tree`, and we've called neither yet — so both are deterministic
    // right here, independent of how far the background worker has
    // actually gotten. The parse has not run synchronously on this path.
    try t.expect(syn.pending_initial != null);
    try t.expectEqual(@as(?*core.syntax.c.TSTree, null), syn.tree);
    // The buffer itself is fully usable regardless — the document
    // doesn't wait on the parse at all.
    try t.expectEqual(src.items.len, doc.text().byteLen());

    // paint() degrades gracefully with no tree yet: unhighlighted, not
    // an error — this is the buffer's honest first paint.
    const classes = try syn.paint(gpa, .{ .start = 0, .end = 200 });
    defer gpa.free(classes);
    for (classes) |cl| try t.expectEqual(core.syntax.Class.none, cl);
}

test "syntax: highlights arrive and paint once the background parse lands" {
    const gpa = t.allocator;
    var pool = try task.Pool.init(gpa, .{ .threads = 1 });
    defer pool.deinit();
    var doc = try Document.init(gpa, "user");
    defer doc.deinit(gpa);
    try doc.insert(gpa, 0, "const x = 42; // note\n");

    var spec_rt = try testRuntime(gpa);
    defer spec_rt.deinit(gpa);
    const spec = spec_rt.forPath("demo.zig").?;
    const syn = try core.syntax.Syntax.createAsync(gpa, pool, &spec_rt, spec, &doc);
    defer syn.destroy();
    try t.expectEqual(@as(?*core.syntax.c.TSTree, null), syn.tree);

    // Drive the loop until the parse lands — the same poll-until-done
    // idiom `Editor.pollSave`'s tests use for the save worker, not a
    // sleep: `sync` returns true exactly once the tree is adopted.
    while (!try syn.sync(gpa, &doc)) std.Thread.yield() catch {};
    try t.expect(syn.tree != null);

    const classes = try syn.paint(gpa, .{ .start = 0, .end = doc.text().byteLen() });
    defer gpa.free(classes);
    try t.expectEqual(core.syntax.Class.keyword, classes[0]);
    try t.expectEqual(core.syntax.Class.number, classes[10]);
    try t.expectEqual(core.syntax.Class.comment, classes[15]);
}

test "syntax: an edit during the pending initial parse lands coherently, not torn" {
    const gpa = t.allocator;
    var pool = try task.Pool.init(gpa, .{ .threads = 1 });
    defer pool.deinit();
    var doc = try Document.init(gpa, "user");
    defer doc.deinit(gpa);
    try doc.insert(gpa, 0, "const x = 1;\n");

    var spec_rt = try testRuntime(gpa);
    defer spec_rt.deinit(gpa);
    const spec = spec_rt.forPath("demo.zig").?;
    const syn = try core.syntax.Syntax.createAsync(gpa, pool, &spec_rt, spec, &doc);
    defer syn.destroy();
    // Guaranteed still pending here (see the test above) — no `sync`
    // call has happened yet to adopt anything.
    try t.expect(syn.pending_initial != null);

    // An edit lands before the buffer has ever synced — exactly the
    // torn-highlight hazard: there is no tree yet to `ts_tree_edit`, so
    // a naive implementation could drop this edit's delta once the
    // background tree finally lands.
    try doc.insert(gpa, doc.text().byteLen(), "var y = \"str\";\n");

    while (!try syn.sync(gpa, &doc)) std.Thread.yield() catch {};
    try t.expect(syn.tree != null);

    const text = try doc.text().toOwnedSlice(gpa);
    defer gpa.free(text);
    const classes = try syn.paint(gpa, .{ .start = 0, .end = doc.text().byteLen() });
    defer gpa.free(classes);
    // Both the original text and the edit that landed during the
    // pending window highlight correctly — coherent, not torn.
    const const_at = std.mem.indexOf(u8, text, "const").?;
    try t.expectEqual(core.syntax.Class.keyword, classes[const_at]);
    const str_at = std.mem.indexOf(u8, text, "\"str\"").?;
    try t.expectEqual(core.syntax.Class.string, classes[str_at + 1]);
}

test "syntax: destroy while pending on a saturated pool returns promptly, no leak" {
    const gpa = t.allocator;
    // ONE worker, matching production's floor (`min(4, cpus-1)`, as low
    // as 1) — and occupied for the WHOLE test by a "hog" task standing in
    // for a persistent reader (proc_stream/repl_session/net_session/proc
    // — a shell, a REPL, the agent door, net collab — any of which can
    // occupy a worker for its session's lifetime). With the pool fully
    // saturated like this, the initial-parse task this test spawns next
    // cannot even START running until the hog is released, below — the
    // exact condition that used to deadlock `destroy`'s old join.
    var pool = try task.Pool.init(gpa, .{ .threads = 1 });
    defer pool.deinit();
    var release: std.atomic.Value(bool) = .init(false);
    const Hog = struct {
        fn run(flag: *std.atomic.Value(bool)) void {
            while (!flag.load(.acquire)) std.Thread.yield() catch {};
        }
    };
    var hog = try pool.spawn(Hog.run, .{&release});
    hog.detach();

    var doc = try Document.init(gpa, "user");
    defer doc.deinit(gpa);
    try doc.insert(gpa, 0, "const x = 1;\n");
    var spec_rt = try testRuntime(gpa);
    defer spec_rt.deinit(gpa);
    const spec = spec_rt.forPath("demo.zig").?;
    const syn = try core.syntax.Syntax.createAsync(gpa, pool, &spec_rt, spec, &doc);
    // Queued behind the hog — cannot have started.
    try t.expect(syn.pending_initial != null);

    // The actual assertion: this returns immediately (no join, no spin —
    // see syntax.zig's `destroy`) despite the parse having no way to run
    // yet. Before the ownership-restructure fix, this line hung the
    // calling thread forever.
    syn.destroy();

    // Let the hog go so the now-abandoned parse job actually runs to
    // completion on the worker it was queued for, exercising its
    // self-clean path (`initialParseWorker` losing the `state` CAS to
    // `destroy`, above) for real rather than leaving it forever queued.
    // `pool.deinit()` below would otherwise hang joining a worker stuck
    // in the hog's loop.
    release.store(true, .release);
    // `t.allocator` is the assertion: it fails the test if the job
    // struct or its rope snapshot outlives this scope — the worker frees
    // both itself once it sees it lost the claim (a `*TSTree`, if the
    // parse even produced one, is tree-sitter's own C allocation, outside
    // `t.allocator`'s ledger — `ts_tree_delete`'s correctness there is
    // exercised by the coherence/adoption tests above, not this one).
}

// ── Capabilities (phase 2, milestone 1) ─────────────────────────────

const capability = core.capability;

fn instantWords(data: ?*anyopaque, caps: *core.Caps, req: *const capability.Request) anyerror!void {
    _ = data;
    var items = [_]capability.CompletionItem{
        .{ .text = @constCast("alpha"), .rank = 1 },
        .{ .text = @constCast("beta"), .rank = 2 },
    };
    try caps.push(req.session, .{ .id = "test.instant", .latency = .instant }, .{ .completion = &items });
}

fn neverAnswers(data: ?*anyopaque, caps: *core.Caps, req: *const capability.Request) anyerror!void {
    _ = data;
    _ = caps;
    _ = req;
    // A dead provider: no push, no decline — the deadline reaps it.
}

test "capability: race, refine, merge-ranked composition, dead provider" {
    const gpa = t.allocator;
    var host: TestHost = undefined;
    try TestHost.init(gpa, &host);
    defer host.deinit(gpa);
    try host.editor().insertText(gpa, "alpha beta gamma");

    try host.caps.register(.{ .capability = "edit/completion", .id = "test.instant", .latency = .instant, .handler = instantWords });
    try host.caps.register(.{ .capability = "edit/completion", .id = "test.dead", .latency = .slow, .handler = neverAnswers });

    const id = (try host.caps.fire(.completion, &host.editor().doc, null, .{ .text = "a", .timeout_ns = 0 })).?;
    defer host.caps.finish(id);
    const s = host.caps.session(id).?;

    // Instant results landed during fire; the dead provider is still
    // outstanding but the deadline (0) already reaps the session.
    const fresh = s.poll();
    try t.expectEqual(@as(usize, 1), fresh.len);
    try t.expectEqual(capability.Latency.instant, fresh[0].latency);
    try t.expect(s.done(core.task.nowNs()));

    // A slow provider pushing later refines; merge dedups by text and
    // keeps instant-class items first.
    var late = [_]capability.CompletionItem{
        .{ .text = @constCast("alpha"), .rank = 0 }, // duplicate: first wins
        .{ .text = @constCast("zeta"), .rank = 1 },
    };
    try host.caps.push(id, .{ .id = "test.late", .latency = .slow }, .{ .completion = &late });
    const merged = try host.caps.mergedCompletion(gpa, id);
    defer gpa.free(merged);
    try t.expectEqual(@as(usize, 3), merged.len);
    try t.expectEqualStrings("alpha", merged[0].text);
    try t.expectEqualStrings("beta", merged[1].text);
    try t.expectEqualStrings("zeta", merged[2].text);
}

fn definesHere(data: ?*anyopaque, caps: *core.Caps, req: *const capability.Request) anyerror!void {
    _ = data;
    // "Definition" = the first byte of the document, stamped at the
    // fire version by the core (restamp).
    var locs = [_]capability.Location{
        .{ .range = core.position.StampedRange.at(req.version, 2, 7) },
    };
    try caps.push(req.session, .{ .id = "test.def", .priority = 3 }, .{ .locations = &locs });
}

test "capability: stamped results rebase through later edits or discard" {
    const gpa = t.allocator;
    var host: TestHost = undefined;
    try TestHost.init(gpa, &host);
    defer host.deinit(gpa);
    try host.editor().insertText(gpa, "xx target yy");

    try host.caps.register(.{ .capability = "edit/definition", .id = "test.def", .priority = 3, .handler = definesHere });
    const id = (try host.caps.fire(.definition, &host.editor().doc, null, .{ .offset = 0 })).?;
    defer host.caps.finish(id);

    // The document moves on before the consumer looks.
    try host.editor().doc.insert(gpa, 0, ">>>> ");
    const best = host.caps.session(id).?.best().?;
    const range = best.payload.locations[0].range.rebase(&host.editor().doc).?;
    try t.expectEqual(@as(usize, 7), range.start);
    try t.expectEqual(@as(usize, 12), range.end);

    // A stamp the document never produced → discard arm.
    const bogus = core.position.StampedRange.at("not-a-version", 0, 1);
    try t.expectEqual(@as(?stemma.Range, null), bogus.rebase(&host.editor().doc));
}

// ── Tree-sitter over capabilities (phase 2, milestone 2) ────────────

test "syntax: instant-tier definition + symbols providers race through registry" {
    const gpa = t.allocator;
    var host: TestHost = undefined;
    try TestHost.init(gpa, &host);
    defer host.deinit(gpa);
    try host.editor().adoptPath(gpa, "demo.zig");
    try host.editor().insertText(gpa,
        \\fn alpha() void {}
        \\fn beta() void {
        \\    alpha();
        \\}
    );

    var spec_rt = try testRuntime(gpa);
    defer spec_rt.deinit(gpa);
    const spec = spec_rt.forPath("demo.zig").?;
    const syn = try core.syntax.Syntax.create(gpa, &spec_rt, spec, &host.editor().doc);
    defer syn.destroy();
    try core.syntax.registerProviders(&host.caps, syn);

    // Symbols: both functions, stamped ranges rebase to themselves.
    {
        const id = (try host.caps.fire(.symbols, &host.editor().doc, host.editor().backingPath(), .{})).?;
        defer host.caps.finish(id);
        const best = host.caps.session(id).?.best().?;
        try t.expectEqual(@as(usize, 2), best.payload.symbols.len);
        try t.expectEqualStrings("alpha", best.payload.symbols[0].name);
        try t.expectEqualStrings("beta", best.payload.symbols[1].name);
    }

    // Definition: fire at the `alpha()` call site; instant answer, and
    // its stamped range survives a later edit.
    const text = try host.editor().text().toOwnedSlice(gpa);
    defer gpa.free(text);
    const call_at = std.mem.lastIndexOf(u8, text, "alpha").? + 2;
    {
        const id = (try host.caps.fire(.definition, &host.editor().doc, host.editor().backingPath(), .{ .offset = call_at })).?;
        defer host.caps.finish(id);
        try host.editor().doc.insert(gpa, 0, "// lead\n");
        const best = host.caps.session(id).?.best().?;
        try t.expect(best.payload.locations.len > 0);
        const range = best.payload.locations[0].range.rebase(&host.editor().doc).?;
        try t.expectEqual(@as(usize, 8), range.start); // "fn alpha" after the lead
    }
}

test "capability: two languages' tree-sitter providers bind without collision and fire only for their own language" {
    // Regression for a W1 review finding: `syntax.registerProviders` scopes
    // `edit/definition`/`edit/symbols-document` (both `first_wins`
    // composition) by a SINGLE extension via `predicateFromExtensions`. A
    // `.any`-blind `disjoint()` treated that single-extension `any(...)` as
    // one opaque, never-disjoint atom, so a .zig buffer's provider and a
    // .nix buffer's provider — same slot, same default priority, same
    // specificity, different owners — looked like an unresolvable
    // collision. `Caps.register` (via `registerProviders`) would then fail
    // for the SECOND language attached in a session, which propagates
    // through buffer attach into the `open` command. This exercises the
    // REAL `Caps.register` path (not a synthetic Container test) for
    // exactly that two-language scenario.
    const gpa = t.allocator;
    var host: TestHost = undefined;
    try TestHost.init(gpa, &host);
    defer host.deinit(gpa);

    var doc_zig = try Document.init(gpa, "user");
    defer doc_zig.deinit(gpa);
    try doc_zig.insert(gpa, 0, "fn f() void {}\n");
    var zig_spec_rt = try testRuntime(gpa);
    defer zig_spec_rt.deinit(gpa);
    const zig_spec = zig_spec_rt.forPath("a.zig").?;
    const zig_syn = try core.syntax.Syntax.create(gpa, &zig_spec_rt, zig_spec, &doc_zig);
    defer zig_syn.destroy();
    try core.syntax.registerProviders(&host.caps, zig_syn);

    var doc_nix = try Document.init(gpa, "user");
    defer doc_nix.deinit(gpa);
    try doc_nix.insert(gpa, 0, "{ x = 1; }\n");
    var nix_spec_rt = try testRuntime(gpa);
    defer nix_spec_rt.deinit(gpa);
    const nix_spec = nix_spec_rt.forPath("b.nix").?;
    const nix_syn = try core.syntax.Syntax.create(gpa, &nix_spec_rt, nix_spec, &doc_nix);
    defer nix_syn.destroy();
    // Must NOT error — the exact call that used to trap with SlotCollision.
    try core.syntax.registerProviders(&host.caps, nix_syn);

    // Each fires only against its OWN language's buffer: exactly one
    // provider matches and answers per fire, never both.
    {
        const id = (try host.caps.fire(.symbols, &doc_zig, "a.zig", .{})).?;
        defer host.caps.finish(id);
        try t.expectEqual(@as(usize, 1), host.caps.session(id).?.all().len);
    }
    {
        const id = (try host.caps.fire(.symbols, &doc_nix, "b.nix", .{})).?;
        defer host.caps.finish(id);
        try t.expectEqual(@as(usize, 1), host.caps.session(id).?.all().len);
    }
    {
        const id = (try host.caps.fire(.definition, &doc_zig, "a.zig", .{ .offset = 0 })).?;
        defer host.caps.finish(id);
        try t.expectEqual(@as(usize, 1), host.caps.session(id).?.all().len);
    }
}

test "syntax: highlight feed publishes stamped bulk into its layer" {
    const gpa = t.allocator;
    var host: TestHost = undefined;
    try TestHost.init(gpa, &host);
    defer host.deinit(gpa);
    try host.editor().insertText(gpa, "const x = 1;\n");

    var spec_rt = try testRuntime(gpa);
    defer spec_rt.deinit(gpa);
    const spec = spec_rt.forPath("a.zig").?;
    const syn = try core.syntax.Syntax.create(gpa, &spec_rt, spec, &host.editor().doc);
    defer syn.destroy();
    const layer = try host.caps.registerFeed(&host.editor().doc, "edit/highlight", "highlight", .local, "treesitter");
    try syn.publishHighlight(gpa, &host.editor().doc, layer, .{ .start = 0, .end = host.editor().text().byteLen() });

    const b = layer.bulk.?;
    try t.expectEqual(@as(usize, 0), b.start);
    const classes: []const core.capability.HighlightClass = @ptrCast(b.classes);
    try t.expectEqual(core.capability.HighlightClass.keyword, classes[0]); // const
    try t.expectEqual(core.capability.HighlightClass.number, classes[10]); // 1
}

test "syntax: holey document parses the realized prefix, never crashes" {
    const gpa = t.allocator;
    var doc = try Document.init(gpa, "user");
    defer doc.deinit(gpa);
    try doc.insert(gpa, 0, "fn seed() void {}\n");
    var spec_rt = try testRuntime(gpa);
    defer spec_rt.deinit(gpa);
    const spec = spec_rt.forPath("h.zig").?;
    const syn = try core.syntax.Syntax.create(gpa, &spec_rt, spec, &doc);
    defer syn.destroy();

    // A synthetic partially-materialized rope: realized prefix, hole tail.
    var holey = try stemma.Rope.fromUnrealized(gpa, 4096);
    defer holey.deinit(gpa);
    try holey.realize(gpa, 0, "fn top() void {}\n_");
    syn.reparseRope(&holey);
    // Paint over the realized region works; the hole region stays .none.
    const classes = try syn.paint(gpa, .{ .start = 0, .end = 64 });
    defer gpa.free(classes);
    try t.expectEqual(core.capability.HighlightClass.keyword, classes[0]); // fn
    try t.expectEqual(core.capability.HighlightClass.none, classes[40]);
}

test "editor: shell backing — guarded save, external change poll, stale retry" {
    const gpa = t.allocator;
    var tmp_dir = t.tmpDir(.{});
    defer tmp_dir.cleanup();
    const path = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/remote.txt", .{tmp_dir.sub_path});
    defer gpa.free(path);
    {
        var threaded: std.Io.Threaded = .init(gpa, .{});
        defer threaded.deinit();
        try std.Io.Dir.cwd().writeFile(threaded.io(), .{ .sub_path = path, .data = "remote content\n" });
    }

    var fs = try core.ShellFs.spawn(gpa, &.{"/bin/sh"}, .{ .block = .{ .slice = std.mem.span(std.c.environ) } });
    defer fs.deinit();
    var pool = try task.Pool.init(gpa, .{ .threads = 1 });
    defer pool.deinit();
    var ed = try Editor.init(gpa, pool, "user");
    defer ed.deinit(gpa);

    try ed.openShell(gpa, &fs, path);
    try t.expectEqualStrings(path, ed.backingPath().?);
    try t.expect(!try ed.isDirty(gpa));

    // Edit + guarded save through the shell.
    ed.placeCursor(ed.text().byteLen());
    try ed.insertText(gpa, "typed locally\n");
    try ed.requestSave(gpa);
    while (!ed.pollSave(gpa)) std.Thread.yield() catch {};
    try t.expect(!try ed.isDirty(gpa));

    // An external writer (nvim) rewrites the file; the poll merges it
    // with fresh unsaved local work.
    try ed.insertText(gpa, "unsaved\n");
    {
        var threaded: std.Io.Threaded = .init(gpa, .{});
        defer threaded.deinit();
        try std.Io.Dir.cwd().writeFile(threaded.io(), .{ .sub_path = path, .data = "remote content\ntyped locally\nEXTERNAL\n" });
    }
    try ed.requestBackingPoll(gpa);
    var changed = false;
    while (true) {
        if (ed.poll_state == .idle and changed) break;
        changed = try ed.pollBacking(gpa) or changed;
        if (ed.poll_state == .idle and !changed) {
            // Race with the worker: re-request until the change lands.
            try ed.requestBackingPoll(gpa);
        }
        std.Thread.yield() catch {};
    }
    const merged = try ed.text().toOwnedSlice(gpa);
    defer gpa.free(merged);
    try t.expect(std.mem.indexOf(u8, merged, "EXTERNAL") != null);
    try t.expect(std.mem.indexOf(u8, merged, "unsaved") != null);

    // Save now succeeds against the merged token (no lost update).
    try ed.requestSave(gpa);
    while (!ed.pollSave(gpa)) {
        if (ed.save_state == .stale) break;
        std.Thread.yield() catch {};
    }
    try t.expect(ed.save_state == .idle);
    try t.expect(!try ed.isDirty(gpa));
}

// ── Multi-buffer (phase 3) ──────────────────────────────────────────

test "buffers: switch restores modes, close/create keep the set sane" {
    const gpa = t.allocator;
    var host: TestHost = undefined;
    try TestHost.init(gpa, &host);
    defer host.deinit(gpa);
    const run = core.command.run;

    try host.head.setModeRaw(gpa, "normal");
    try t.expectEqual(@as(usize, 1), host.buffers.count());
    const scratch_id = host.buffers.active().id;

    // Create+focus a second buffer; give it its own mode.
    _ = try run(&host.commands, &host.ctx, "buffer-create", &.{.{ .string = "*tool*" }});
    try t.expectEqual(@as(usize, 2), host.buffers.count());
    try t.expectEqualStrings("*tool*", host.buffers.active().name);
    try host.head.setModeRaw(gpa, "git");

    // Switching away saves "git" on the tool buffer and restores the
    // scratch buffer's "normal"; switching back restores "git".
    _ = try run(&host.commands, &host.ctx, "buffer-switch", &.{.{ .integer = @intCast(scratch_id) }});
    try t.expectEqualStrings("normal", host.head.currentMode());
    _ = try run(&host.commands, &host.ctx, "buffer-next", &.{});
    try t.expectEqualStrings("*tool*", host.buffers.active().name);
    try t.expectEqualStrings("git", host.head.currentMode());

    // Read-only swallows text commands but not others.
    _ = try run(&host.commands, &host.ctx, "buffer-read-only", &.{.{ .boolean = true }});
    _ = try run(&host.commands, &host.ctx, "insert-text", &.{.{ .string = "nope" }});
    try t.expectEqual(@as(usize, 0), host.editor().text().byteLen());
    _ = try run(&host.commands, &host.ctx, "buffer-read-only", &.{.{ .boolean = false }});
    _ = try run(&host.commands, &host.ctx, "insert-text", &.{.{ .string = "yes" }});
    try t.expectEqual(@as(usize, 3), host.editor().text().byteLen());

    // Dirty close refuses; a clean one proceeds and refocuses.
    const res = try run(&host.commands, &host.ctx, "buffer-close", &.{});
    try t.expect(res == .string); // "dirty"
    try host.editor().doc.delete(gpa, .{ .start = 0, .end = 3 });
    // Deleting back to empty is still a diverged version — dirty by
    // design. Fresh scratch buffers close cleanly instead.
    _ = try run(&host.commands, &host.ctx, "buffer-switch", &.{.{ .integer = @intCast(scratch_id) }});
    _ = try run(&host.commands, &host.ctx, "buffer-close", &.{});
    try t.expectEqual(@as(usize, 1), host.buffers.count());
    try t.expectEqualStrings("*tool*", host.buffers.active().name);

    // Open dedupes by path.
    var tmp_dir = t.tmpDir(.{});
    defer tmp_dir.cleanup();
    const path = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/file.txt", .{tmp_dir.sub_path});
    defer gpa.free(path);
    const id1 = try run(&host.commands, &host.ctx, "open", &.{.{ .string = path }});
    const id2 = try run(&host.commands, &host.ctx, "open", &.{.{ .string = path }});
    try t.expectEqual(id1.integer, id2.integer);
}

test "buffers: a fresh buffer opens in default_mode — a tool mode never leaks" {
    const gpa = t.allocator;
    var host: TestHost = undefined;
    try TestHost.init(gpa, &host);
    defer host.deinit(gpa);
    const run = core.command.run;

    // The config base editing mode, captured once.
    try host.head.setModeRaw(gpa, "normal");
    try host.buffers.setDefaultMode(gpa, "normal");

    // Enter a tool buffer and put it in its own tool mode.
    _ = try run(&host.commands, &host.ctx, "buffer-create", &.{.{ .string = "*tool*" }});
    try host.head.setModeRaw(gpa, "tool");
    try t.expectEqualStrings("tool", host.head.currentMode());

    // Open a file FROM the tool buffer — a fresh buffer. Structurally it must
    // start in default_mode, never inherit "tool" (the bug this makes
    // impossible to express: a tool mode sticking after you open a file).
    _ = try run(&host.commands, &host.ctx, "open", &.{.{ .string = "/tmp/weft-mode-test.zig" }});
    try t.expectEqualStrings("normal", host.head.currentMode());

    // Going back to the tool buffer still restores its mode (per-buffer intact).
    _ = try run(&host.commands, &host.ctx, "buffer-switch", &.{.{ .integer = 1 }});
    try t.expectEqualStrings("tool", host.head.currentMode());
}

test "editor: bulk load — big file opens as a compacted base, edits and saves" {
    const gpa = t.allocator;
    var tmp_dir = t.tmpDir(.{});
    defer tmp_dir.cleanup();
    const path = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/big.txt", .{tmp_dir.sub_path});
    defer gpa.free(path);
    {
        // A megabyte is no longer a threshold — every load takes this path
        // now — but a size that used to be "big" still makes the O(1)-events
        // assertion below mean something a small file could fake.
        const big = try gpa.alloc(u8, (1 << 20) + 4096);
        defer gpa.free(big);
        for (big, 0..) |*b, i| b.* = if (i % 64 == 63) '\n' else 'x';
        var threaded: std.Io.Threaded = .init(gpa, .{});
        defer threaded.deinit();
        try std.Io.Dir.cwd().writeFile(threaded.io(), .{ .sub_path = path, .data = big });
    }

    var pool = try task.Pool.init(gpa, .{ .threads = 1 });
    defer pool.deinit();
    var ed = try Editor.init(gpa, pool, "user");
    defer ed.deinit(gpa);
    try ed.openFile(gpa, path);
    // O(1) events, not O(content): the content is the base. Under the
    // graph substrate (W7a) that floor is 1, not 0 — the body text
    // object's founder creation event, which is never itself a
    // compaction target (`Document.founder_event_count`'s doc comment) —
    // still nowhere near the millions a per-scalar load of a multi-MB
    // file would cost, which is the property this assertion actually
    // guards.
    try t.expectEqual(@as(usize, 1), ed.doc.eventCount());
    try t.expect(!try ed.isDirty(gpa));

    // Ordinary editing + guarded save on top of the base.
    try ed.insertText(gpa, "EDIT ");
    try t.expect(try ed.isDirty(gpa));
    try ed.requestSave(gpa);
    while (!ed.pollSave(gpa)) std.Thread.yield() catch {};
    try t.expect(!try ed.isDirty(gpa));
}

test "editor: loaded content is anchorable — every open, not just small ones" {
    // The gate on the bulk load path having no size threshold. A region
    // grant, a shared cursor and a shell insertion all name a character in
    // the file rather than an offset into it, so a load whose content could
    // not be anchored would break every one of them the moment it became
    // the only load path.
    const gpa = t.allocator;
    var tmp_dir = t.tmpDir(.{});
    defer tmp_dir.cleanup();
    const path = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/small.txt", .{tmp_dir.sub_path});
    defer gpa.free(path);
    {
        var threaded: std.Io.Threaded = .init(gpa, .{});
        defer threaded.deinit();
        try std.Io.Dir.cwd().writeFile(threaded.io(), .{ .sub_path = path, .data = "hello world\n" });
    }

    var pool = try task.Pool.init(gpa, .{ .threads = 1 });
    defer pool.deinit();
    var ed = try Editor.init(gpa, pool, "user");
    defer ed.deinit(gpa);
    try ed.openFile(gpa, path);

    // Anchor the 'w' of "world" — content that came from the file, not typed.
    const anchor = try ed.doc.exportAnchor(gpa, 6, .before);
    defer gpa.free(anchor.agent);
    var out: [1]usize = undefined;
    try ed.doc.resolveAnchors(gpa, &.{anchor}, &out);
    try t.expectEqual(@as(usize, 6), out[0]);

    // It tracks the character across an edit ahead of it, which is the whole
    // reason to hold an anchor instead of an offset.
    try ed.insertText(gpa, "say: ");
    try ed.doc.resolveAnchors(gpa, &.{anchor}, &out);
    try t.expectEqual(@as(usize, 11), out[0]);
}

test "completion UI: source-driven fold into the pick; accept replaces the prefix" {
    const gpa = t.allocator;
    var host: TestHost = undefined;
    try TestHost.init(gpa, &host);
    defer host.deinit(gpa);

    var comp: core.complete_ui.CompletionUi = .empty;
    _ = try host.commands.bind(gpa, "complete", comp.commandSpec());
    try host.caps.register(.{
        .capability = "edit/completion",
        .id = "test.instant",
        .latency = .instant,
        .handler = instantWords,
    });

    // A word prefix at the cursor; the instant provider offers alpha/beta.
    try host.editor().insertText(gpa, "al");
    _ = try core.command.run(&host.commands, &host.ctx, "complete", &.{});
    try t.expect(host.head.pick.active);
    // Instant-tier results were folded during fire (source path); the
    // pick already carries them, no bespoke tick needed.
    try t.expect(host.head.pick.items.items.len >= 2);

    _ = try core.command.run(&host.commands, &host.ctx, "pick-input", &.{.{ .string = "alp" }});
    _ = try core.command.run(&host.commands, &host.ctx, "pick-accept", &.{});
    try t.expect(!host.head.pick.active);
    const text = try host.editor().text().toOwnedSlice(gpa);
    defer gpa.free(text);
    try t.expectEqualStrings("alpha", text);
}

test "completion UI: switching buffers dismisses the originating session" {
    const gpa = t.allocator;
    var host: TestHost = undefined;
    try TestHost.init(gpa, &host);
    defer host.deinit(gpa);

    var comp: core.complete_ui.CompletionUi = .empty;
    _ = try host.commands.bind(gpa, "complete", comp.commandSpec());
    try host.caps.register(.{
        .capability = "edit/completion",
        .id = "test.instant",
        .latency = .instant,
        .handler = instantWords,
    });

    try host.head.setModeRaw(gpa, "normal");
    try host.editor().insertText(gpa, "al");
    _ = try core.command.run(&host.commands, &host.ctx, "complete", &.{});
    try t.expect(host.head.pick.active);
    const origin = host.buffers.active().ref();

    const other = try host.buffers.create(gpa, "other");
    try host.buffers.switchTo(gpa, other, &host.head, &host.keymap);
    try t.expect((try host.head.pick.tick(&host.ctx)));
    try t.expect(!host.head.pick.active);
    try t.expectEqualStrings("normal", host.head.currentMode());

    // The originating document was neither edited nor mistaken for the new
    // active buffer; the target token still resolves to the exact old buffer.
    const original = host.buffers.resolve(origin) orelse return error.OriginLost;
    const original_text = try original.textEditor().?.text().toOwnedSlice(gpa);
    defer gpa.free(original_text);
    try t.expectEqualStrings("al", original_text);
    try t.expectEqual(@as(usize, 0), host.editor().text().byteLen());
}

test "editor: compactNow keeps the backing mirror and saves working" {
    const gpa = t.allocator;
    var tmp_dir = t.tmpDir(.{});
    defer tmp_dir.cleanup();
    const path = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/host.txt", .{tmp_dir.sub_path});
    defer gpa.free(path);
    {
        var threaded: std.Io.Threaded = .init(gpa, .{});
        defer threaded.deinit();
        try std.Io.Dir.cwd().writeFile(threaded.io(), .{ .sub_path = path, .data = "served content\n" });
    }
    var pool = try task.Pool.init(gpa, .{ .threads = 1 });
    defer pool.deinit();
    var ed = try Editor.init(gpa, pool, "host");
    defer ed.deinit(gpa);
    try ed.openFile(gpa, path);
    try ed.compactNow(gpa);
    // Same floor as the bulk-load case above: `compact` folds every
    // text_ins/text_del away but never the founder's creation event, so
    // the post-compact floor is 1, not 0, under the graph substrate.
    try t.expectEqual(@as(usize, 1), ed.doc.eventCount());
    try t.expect(!try ed.isDirty(gpa));

    // The panic case: edit + save AFTER compaction — markSaved's
    // peerSyncTo must work against the rebuilt mirror.
    ed.placeCursor(ed.text().byteLen());
    try ed.insertText(gpa, "post-compact edit\n");
    try ed.requestSave(gpa);
    while (!ed.pollSave(gpa)) std.Thread.yield() catch {};
    try t.expect(ed.save_state == .idle);
    try t.expect(!try ed.isDirty(gpa));
}

test "syntax: a grammar compiles once per runtime, not once per buffer" {
    // Compiling a highlight query costs ~18ms in ReleaseFast — an order of
    // magnitude more than opening the file it highlights, reading it and
    // building its CRDT put together. Two buffers of the same language must
    // therefore share one compiled grammar; a regression to per-buffer
    // compilation would put that cost back on every single open, which is
    // exactly where it used to be.
    const gpa = t.allocator;
    var rt = try testRuntime(gpa);
    defer rt.deinit(gpa);
    var doc_a = try Document.init(gpa, "user");
    defer doc_a.deinit(gpa);
    try doc_a.insert(gpa, 0, "const a = 1;\n");
    var doc_b = try Document.init(gpa, "user");
    defer doc_b.deinit(gpa);
    try doc_b.insert(gpa, 0, "const b = 2;\n");

    const spec = rt.forPath("a.zig").?;
    const a = try core.syntax.Syntax.create(gpa, &rt, spec, &doc_a);
    defer a.destroy();
    const b = try core.syntax.Syntax.create(gpa, &rt, spec, &doc_b);
    defer b.destroy();
    try t.expectEqual(a.compiled, b.compiled);

    // Shared does not mean entangled: the parse-time state each buffer
    // mutates stays its own, which is what makes sharing the query safe.
    try t.expect(a.parser != b.parser);
    try t.expect(a.qcursor != b.qcursor);

    // A different language is a different entry, not a clobbered one.
    const nix_spec = rt.forPath("b.nix").?;
    const n = try core.syntax.Syntax.create(gpa, &rt, nix_spec, &doc_a);
    defer n.destroy();
    try t.expect(a.compiled != n.compiled);

    // Both still highlight — sharing the query did not break painting.
    try t.expect(a.tree != null);
    try t.expect(b.tree != null);
}

test "syntax: registering a grammar queues its compile off the frame thread" {
    // tree-sitter cannot persist a compiled query between runs, so the only
    // caching available is to precompute within the session — and the moment
    // to do it is registration, which is why there is no separate warm step to
    // forget. Asserted without a clock and without a sleep: `Pool.deinit`
    // joins its threads and drains whatever is still queued, so once the block
    // exits the job has run however the OS chose to schedule it.
    const gpa = t.allocator;
    var rt: core.syntax.Runtime = .empty;
    defer rt.deinit(gpa);
    try rt.setSearchPath(gpa, @import("build_options").grammar_path);
    try t.expectEqual(@as(usize, 0), rt.compiledCount());
    {
        var pool = try task.Pool.init(gpa, .{ .threads = 1 });
        defer pool.deinit();
        rt.setPool(pool);
        try rt.add(gpa, .{ .extensions = ".zig", .grammar = "zig", .symbol = "tree_sitter_zig" });
        try rt.add(gpa, .{ .extensions = ".nix", .grammar = "nix", .symbol = "tree_sitter_nix" });
        // A grammar registered LATE is not second class — this one is queued
        // by the same act, with no batch pass to have missed it.
        try rt.add(gpa, .{ .extensions = ".lua", .grammar = "lua", .symbol = "tree_sitter_lua" });
    }
    // The pool is gone; nothing may be queued against it afterwards.
    rt.pool = null;
    try t.expectEqual(rt.specCount(), rt.compiledCount());

    // A warmed grammar is the SAME entry a buffer then gets — a warm that
    // built a second, parallel copy would pay the compile twice and defeat the
    // point entirely.
    const before = rt.compiledCount();
    var doc = try Document.init(gpa, "user");
    defer doc.deinit(gpa);
    try doc.insert(gpa, 0, "const x = 1;\n");
    const spec = rt.forPath("a.zig").?;
    const syn = try core.syntax.Syntax.create(gpa, &rt, spec, &doc);
    defer syn.destroy();
    try t.expectEqual(before, rt.compiledCount());
}

test "syntax: an external registration can say everything a built-in can" {
    // The point of the registry is that a grammar declared from config is not
    // a second-class version of a compiled-in one. Anything the built-in table
    // could express — several extensions, document-symbol kinds, a query that
    // does not live at the package's default path — has to be expressible
    // here too, or "grammars as data" is only half true and the privileged
    // path stays the easier one to use.
    const gpa = t.allocator;
    var tmp_dir = t.tmpDir(.{});
    defer tmp_dir.cleanup();
    const root = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/gram", .{tmp_dir.sub_path});
    defer gpa.free(root);

    // A grammar package laid out the way the nixpkgs ones are. `add` only
    // registers — the `.so` is not opened until something compiles it — so a
    // placeholder parser file is enough to exercise registration.
    const pkg = try std.fmt.allocPrint(gpa, "{s}/mylang", .{root});
    defer gpa.free(pkg);
    const parser_path = try std.fmt.allocPrint(gpa, "{s}/parser", .{pkg});
    defer gpa.free(parser_path);
    try core.file.writeBytesMakingDirs(gpa, pkg, parser_path, "not-really-a-so");
    const qdir = try std.fmt.allocPrint(gpa, "{s}/queries", .{pkg});
    defer gpa.free(qdir);
    const qpath = try std.fmt.allocPrint(gpa, "{s}/highlights.scm", .{qdir});
    defer gpa.free(qpath);
    try core.file.writeBytesMakingDirs(gpa, qdir, qpath, "(identifier) @variable");

    var rt: core.syntax.Runtime = .empty;
    defer rt.deinit(gpa);
    try rt.setSearchPath(gpa, root);

    // An outline query where the package keeps one, picked up without config
    // naming it.
    const opath = try std.fmt.allocPrint(gpa, "{s}/outline.scm", .{qdir});
    defer gpa.free(opath);
    try core.file.writeBytesMakingDirs(gpa, qdir, opath, "(x) @item (y) @name");

    try rt.add(gpa, .{
        .extensions = ".ml,.mli, .mll",
        .grammar = "mylang",
        .symbol = "tree_sitter_mylang",
    });

    // Every declared extension resolves, including the space-padded one.
    for ([_][]const u8{ "a.ml", "a.mli", "a.mll" }) |p| {
        const spec = rt.forPath(p) orelse return error.TestUnexpectedResult;
        try t.expectEqualStrings("mylang", spec.name);
        try t.expectEqualStrings("tree_sitter_mylang", spec.symbol);
        try t.expectEqualStrings("(identifier) @variable", spec.highlights);
        try t.expectEqualStrings("(x) @item (y) @name", spec.outline);
    }
    try t.expect(rt.forPath("a.rs") == null);

    // A name that is not on the search path is a refusal, not a silent
    // registration that fails later at dlopen time.
    try t.expectError(error.GrammarNotFound, rt.add(gpa, .{
        .extensions = ".nope",
        .grammar = "absent",
        .symbol = "tree_sitter_absent",
    }));

    // A query somewhere other than the package default, which is what a
    // grammar shipping no query of its own needs.
    const alt = try std.fmt.allocPrint(gpa, "{s}/alt.scm", .{root});
    defer gpa.free(alt);
    try core.file.writeBytesMakingDirs(gpa, root, alt, "(comment) @comment");
    // An ABSOLUTE package path bypasses the search path entirely, which is
    // what a grammar built somewhere the path doesn't cover needs.
    var cwd_buf: [4096]u8 = undefined;
    const cwd = core.file.processDirectory(&cwd_buf).?;
    const abs_pkg = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ cwd, pkg });
    defer gpa.free(abs_pkg);
    try rt.add(gpa, .{
        .extensions = ".other",
        .grammar = abs_pkg,
        .symbol = "tree_sitter_mylang",
        .query = alt,
    });
    const other = rt.forPath("x.other").?;
    try t.expectEqualStrings("(comment) @comment", other.highlights);
    try t.expectEqualStrings(abs_pkg, other.parser_dir);
}

test "syntax: outline queries name what a first-identifier walk got wrong" {
    // The two concrete defects the old depth-≤3 walk had. It took a
    // definition's first identifier DESCENDANT as its name, which is not the
    // name in either of these cases — and no list of node kinds can express
    // the difference, which is why this is a query.
    const gpa = t.allocator;
    var rt: core.syntax.Runtime = .empty;
    defer rt.deinit(gpa);
    try rt.setSearchPath(gpa, @import("build_options").grammar_path);
    try rt.add(gpa, .{ .extensions = ".zig", .grammar = "zig", .symbol = "tree_sitter_zig" });
    try rt.add(gpa, .{ .extensions = ".lua", .grammar = "lua", .symbol = "tree_sitter_lua" });
    try rt.add(gpa, .{ .extensions = ".js", .grammar = "javascript", .symbol = "tree_sitter_javascript" });

    const Case = struct { path: []const u8, src: []const u8, want: []const []const u8 };
    const cases = [_]Case{
        // `Point`, not `x`: the struct's first identifier descendant is its
        // first FIELD. And a `const` inside a function body is a local, which
        // a depth cap only accidentally excluded.
        .{
            .path = "a.zig",
            .src =
            \\const Point = struct { x: u8, y: u8 };
            \\pub fn area(p: Point) u8 {
            \\    const scratch = 1;
            \\    return scratch;
            \\}
            \\test "it works" {}
            ,
            .want = &.{ "Point", "area", "it works" },
        },
        // `g` and `h`, not `M` twice: the table is the first identifier in
        // both `M.g` and `M:h`.
        .{
            .path = "a.lua",
            .src =
            \\local function f() end
            \\function M.g() end
            \\function M:h() end
            ,
            .want = &.{ "f", "g", "h" },
        },
        // A binding earns an entry by holding a function, not by existing —
        // the old rule listed every `lexical_declaration`.
        .{
            .path = "a.js",
            .src =
            \\function f() {}
            \\class C { m() {} }
            \\const g = () => {};
            \\let plain = 1;
            ,
            .want = &.{ "f", "C", "m", "g" },
        },
    };

    inline for (cases) |case| {
        var doc = try Document.init(gpa, "user");
        defer doc.deinit(gpa);
        try doc.insert(gpa, 0, case.src);
        const spec = rt.forPath(case.path).?;
        const syn = try core.syntax.Syntax.create(gpa, &rt, spec, &doc);
        defer syn.destroy();

        var syms: std.ArrayList(core.syntax.Syntax.Sym) = .empty;
        defer {
            for (syms.items) |s| gpa.free(s.name);
            syms.deinit(gpa);
        }
        try syn.collectSymbols(gpa, &doc, &syms);

        var got: std.ArrayList(u8) = .empty;
        defer got.deinit(gpa);
        for (syms.items, 0..) |s, i| {
            if (i > 0) try got.appendSlice(gpa, ",");
            try got.appendSlice(gpa, s.name);
        }
        var want: std.ArrayList(u8) = .empty;
        defer want.deinit(gpa);
        for (case.want, 0..) |w, i| {
            if (i > 0) try want.appendSlice(gpa, ",");
            try want.appendSlice(gpa, w);
        }
        try t.expectEqualStrings(want.items, got.items);
    }
}

test "syntax: re-registering a grammar replaces it instead of piling up" {
    // `config-reload` re-runs every `grammar-add`. Appending would grow the
    // registry by the whole language set on each reload — invisible, because
    // `forPath` is last-wins, until the list is enormous.
    const gpa = t.allocator;
    var rt: core.syntax.Runtime = .empty;
    defer rt.deinit(gpa);
    try rt.setSearchPath(gpa, @import("build_options").grammar_path);

    try rt.add(gpa, .{ .extensions = ".zig", .grammar = "zig", .symbol = "tree_sitter_zig" });
    try rt.add(gpa, .{ .extensions = ".nix", .grammar = "nix", .symbol = "tree_sitter_nix" });
    try t.expectEqual(@as(usize, 2), rt.specCount());

    for (0..3) |_| {
        try rt.add(gpa, .{ .extensions = ".zig", .grammar = "zig", .symbol = "tree_sitter_zig" });
        try rt.add(gpa, .{ .extensions = ".nix", .grammar = "nix", .symbol = "tree_sitter_nix" });
    }
    try t.expectEqual(@as(usize, 2), rt.specCount());

    // And the LAST registration is the one that answers, so a reload that
    // changes a grammar's extensions takes effect rather than being shadowed
    // by the copy underneath it.
    try rt.add(gpa, .{ .extensions = ".zg2", .grammar = "zig", .symbol = "tree_sitter_zig" });
    try t.expectEqual(@as(usize, 2), rt.specCount());
    try t.expect(rt.forPath("a.zg2") != null);
    try t.expect(rt.forPath("a.zig") == null);
}
