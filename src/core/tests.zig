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

    // Move to line start, type — the motion is an undo barrier.
    ed.moveLineStart();
    try ed.insertText(gpa, ">> ");
    {
        const s = try ed.text().toOwnedSlice(gpa);
        defer gpa.free(s);
        try t.expectEqualStrings(">> hello world", s);
    }
    try t.expect(try ed.undo(gpa));
    {
        const s = try ed.text().toOwnedSlice(gpa);
        defer gpa.free(s);
        try t.expectEqualStrings("hello world", s);
    }
    try t.expect(try ed.undo(gpa));
    try t.expectEqual(@as(usize, 0), ed.text().byteLen());
    try t.expect(try ed.redo(gpa));
    try t.expect(try ed.redo(gpa));

    // Selection replace is one undoable unit.
    ed.moveDocStart();
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
    try t.expect(try ed.undo(gpa));
    {
        const s = try ed.text().toOwnedSlice(gpa);
        defer gpa.free(s);
        try t.expectEqualStrings(">> hello world", s);
    }
}

test "editor: vertical movement with goal column, word motions, utf-8 safe" {
    const gpa = t.allocator;
    var pool = try task.Pool.init(gpa, .{ .threads = 1 });
    defer pool.deinit();
    var ed = try Editor.init(gpa, pool, "user");
    defer ed.deinit(gpa);

    try ed.insertText(gpa, "first_long line α\nab\nthird θθ line");
    ed.moveDocStart();
    ed.moveLineEnd(); // col past short line's length
    ed.moveDown(); // clamps to "ab" end
    const p1 = ed.text().offsetToPoint(ed.cursorOffset());
    try t.expectEqual(@as(usize, 1), p1.row);
    try t.expectEqual(@as(usize, 2), p1.col);
    ed.moveDown(); // goal column sticks, snaps to scalar boundary
    const p2 = ed.text().offsetToPoint(ed.cursorOffset());
    try t.expectEqual(@as(usize, 2), p2.row);

    ed.moveDocStart();
    try ed.moveWordForward(gpa);
    const w = ed.text().offsetToPoint(ed.cursorOffset());
    try t.expectEqual(@as(usize, 11), w.col); // start of "line"
    try ed.moveWordBackward(gpa);
    try t.expectEqual(@as(usize, 0), ed.cursorOffset());

    // Backspace across a multi-byte scalar.
    ed.moveDocEnd();
    try ed.deleteBackward(gpa);
    try ed.deleteBackward(gpa);
    const s = try ed.text().toOwnedSlice(gpa);
    defer gpa.free(s);
    try t.expect(std.unicode.utf8ValidateSlice(s));
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
    try t.expect(!try ed2.undo(gpa));
}

// ── Plugins (milestone 5) ───────────────────────────────────────────

const TestHost = struct {
    pool: *task.Pool,
    buffers: core.Buffers,
    echo_line: std.ArrayList(u8),
    commands: core.command.Commands,
    keymap: core.Keymap,
    pick: core.Pick,
    caps: core.Caps,
    quit: bool,
    ctx: core.command.Context,

    fn init(gpa: Allocator, host: *TestHost) !void {
        host.pool = try task.Pool.init(gpa, .{ .threads = 1 });
        host.buffers = try core.Buffers.init(gpa, host.pool, "user");
        host.echo_line = .empty;
        host.commands = .empty;
        host.keymap = .empty;
        host.pick = .empty;
        host.caps = core.Caps.init(gpa, core.task.nowNs);
        host.quit = false;
        host.ctx = .{
            .gpa = gpa,
            .buffers = &host.buffers,
            .commands = &host.commands,
            .keymap = &host.keymap,
            .pick = &host.pick,
            .caps = &host.caps,
            .quit = &host.quit,
            .echo = &host.echo_line,
        };
        try core.builtins.install(gpa, &host.commands, &host.keymap);
    }

    fn editor(host: *TestHost) *Editor {
        return &host.buffers.active().editor;
    }

    fn deinit(host: *TestHost, gpa: Allocator) void {
        host.caps.deinit();
        host.pick.deinit(gpa);
        host.keymap.deinit(gpa);
        host.commands.deinit(gpa);
        host.echo_line.deinit(gpa);
        host.buffers.deinit(gpa);
        host.pool.deinit();
    }
};

test "plugin: fennel eval, scripted command, peer edits converge" {
    const gpa = t.allocator;
    var host: TestHost = undefined;
    try TestHost.init(gpa, &host);
    defer host.deinit(gpa);

    const p = try core.Plugin.create(gpa, &host.ctx, "test-plugin");
    defer p.destroy();

    // Fennel is alive.
    const three = try p.eval(gpa, "(+ 1 2)", "test");
    defer gpa.free(three);
    try t.expectEqualStrings("3", three);

    // The plugin edits through its own replica and commits — a peer.
    try host.editor().insertText(gpa, "hello world");
    const banner = try p.eval(gpa,
        \\(local text (scion.snapshot))
        \\(scion.insert 0 ";; ")
        \\(scion.commit)
        \\(string.len text)
    , "test");
    defer gpa.free(banner);
    try t.expectEqualStrings("11", banner);
    {
        const s = try host.editor().text().toOwnedSlice(gpa);
        defer gpa.free(s);
        try t.expectEqualStrings(";; hello world", s);
    }

    // A scripted command registered through the same registry
    // everything else uses, invocable from Zig by name.
    const reg = try p.eval(gpa,
        \\(scion.command "shout" "Upper-case a string."
        \\  (fn [s] (string.upper s)))
        \\true
    , "test");
    defer gpa.free(reg);
    const res = try core.command.run(&host.commands, &host.ctx, "shout", &.{
        .{ .string = "graft" },
    });
    try t.expectEqualStrings("GRAFT", res.string);

    // Scripted commands can call built-ins back through scion.run.
    const undo_res = try p.eval(gpa, "(scion.run \"undo\")", "test");
    defer gpa.free(undo_res);
    {
        const s = try host.editor().text().toOwnedSlice(gpa);
        defer gpa.free(s);
        // The user's insert is undone; the plugin's banner survives
        // (selective undo does not touch other peers' work).
        try t.expectEqualStrings(";; ", s);
    }
}

test "plugin: fennel config binds keys and switches modes" {
    const gpa = t.allocator;
    var host: TestHost = undefined;
    try TestHost.init(gpa, &host);
    defer host.deinit(gpa);

    const p = try core.Plugin.create(gpa, &host.ctx, "config");
    defer p.destroy();

    const out = try p.eval(gpa,
        \\(scion.bind "default" "C-t" "doc-start")
        \\(scion.bind "extra" "q" "quit")
        \\(scion.mode)
    , "init.fnl");
    defer gpa.free(out);
    try t.expectEqualStrings("default", out);

    try t.expectEqualStrings("doc-start", host.keymap.lookup("C-t").?);
    try t.expectEqual(@as(?[]const u8, null), host.keymap.lookup("q"));

    const sw = try p.eval(gpa, "(scion.mode \"extra\")", "init.fnl");
    defer gpa.free(sw);
    try t.expectEqualStrings("quit", host.keymap.lookup("q").?);

    // Dispatch a key end-to-end: lookup → run.
    var buf: [32]u8 = undefined;
    const spec = core.Keymap.keyspec(&buf, false, false, "q");
    const cmd_name = host.keymap.lookup(spec).?;
    _ = try core.command.run(&host.commands, &host.ctx, cmd_name, &.{});
    try t.expect(host.quit);
}

// ── Syntax (milestone 7) ────────────────────────────────────────────

test "syntax: incremental highlight tracks edits and peer merges" {
    const gpa = t.allocator;
    var doc = try Document.init(gpa, "user");
    defer doc.deinit(gpa);
    try doc.insert(gpa, 0, "const x = 42; // note\n");

    const spec = core.syntax.forPath("demo.zig").?;
    const syn = try core.syntax.Syntax.create(gpa, spec, &doc);
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

test "capability: feed layer spans shift with edits; scripted provider races" {
    const gpa = t.allocator;
    var host: TestHost = undefined;
    try TestHost.init(gpa, &host);
    defer host.deinit(gpa);
    try host.editor().insertText(gpa, "warn here later");

    // Feed: publish an anchored span, then edit in front of it.
    const layer = try host.caps.registerFeed(&host.editor().doc, "edit/diagnostics", "diagnostics", .host, "test.feed");
    try layer.publishSpans(gpa, &.{.{ .start = 5, .end = 9, .kind = 2, .message = "hm" }});
    try host.editor().doc.insert(gpa, 0, "____");
    const d = layer.resolvedSpan(0);
    try t.expectEqual(@as(usize, 9), d.start);
    try t.expectEqual(@as(usize, 13), d.end);
    try t.expectEqual(@as(u32, 2), d.kind);

    // Scripted provider through the same registry (the only coupling).
    const p = try core.Plugin.create(gpa, &host.ctx, "capdemo");
    defer p.destroy();
    const reg = try p.eval(gpa,
        \\(scion.provide "edit/completion" (fn [prefix] [(.. prefix "_scripted")]))
        \\true
    , "capdemo");
    defer gpa.free(reg);
    const id = (try host.caps.fire(.completion, &host.editor().doc, null, .{ .text = "wa" })).?;
    defer host.caps.finish(id);
    const merged = try host.caps.mergedCompletion(gpa, id);
    defer gpa.free(merged);
    try t.expectEqual(@as(usize, 1), merged.len);
    try t.expectEqualStrings("wa_scripted", merged[0].text);
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

    const spec = core.syntax.forPath("demo.zig").?;
    const syn = try core.syntax.Syntax.create(gpa, spec, &host.editor().doc);
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

test "syntax: highlight feed publishes stamped bulk into its layer" {
    const gpa = t.allocator;
    var host: TestHost = undefined;
    try TestHost.init(gpa, &host);
    defer host.deinit(gpa);
    try host.editor().insertText(gpa, "const x = 1;\n");

    const spec = core.syntax.forPath("a.zig").?;
    const syn = try core.syntax.Syntax.create(gpa, spec, &host.editor().doc);
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
    const spec = core.syntax.forPath("h.zig").?;
    const syn = try core.syntax.Syntax.create(gpa, spec, &doc);
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
    ed.moveDocEnd();
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

    try host.keymap.setMode(gpa, "normal");
    try t.expectEqual(@as(usize, 1), host.buffers.count());
    const scratch_id = host.buffers.active().id;

    // Create+focus a second buffer; give it its own mode.
    _ = try run(&host.commands, &host.ctx, "buffer-create", &.{.{ .string = "*tool*" }});
    try t.expectEqual(@as(usize, 2), host.buffers.count());
    try t.expectEqualStrings("*tool*", host.buffers.active().name);
    try host.keymap.setMode(gpa, "magit");

    // Switching away saves "magit" on the tool buffer and restores the
    // scratch buffer's "normal"; switching back restores "magit".
    _ = try run(&host.commands, &host.ctx, "buffer-switch", &.{.{ .integer = @intCast(scratch_id) }});
    try t.expectEqualStrings("normal", host.keymap.currentMode());
    _ = try run(&host.commands, &host.ctx, "buffer-next", &.{});
    try t.expectEqualStrings("*tool*", host.buffers.active().name);
    try t.expectEqualStrings("magit", host.keymap.currentMode());

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

test "tool buffer: plugin peer + sections + read-only (magit-class recipe)" {
    const gpa = t.allocator;
    var host: TestHost = undefined;
    try TestHost.init(gpa, &host);
    defer host.deinit(gpa);

    const p = try core.Plugin.create(gpa, &host.ctx, "status-tool");
    defer p.destroy();

    // The whole rev-3 recipe from fennel: create a buffer, generate
    // content as a plugin peer, publish sections, mark read-only.
    const out = try p.eval(gpa,
        \\(scion.run "buffer-create" "*status*")
        \\(scion.insert 0 "== staged ==\nfile-a\n== unstaged ==\nfile-b\n")
        \\(scion.commit)
        \\(scion.layer_publish "sections" [[0 12 1 "staged"] [13 19 2 "entry"] [20 34 1 "unstaged"] [35 41 2 "entry"]])
        \\(scion.run "buffer-read-only" true)
        \\(scion.section_at "sections" 15)
    , "tool.fnl");
    defer gpa.free(out);

    const buf = host.buffers.active();
    try t.expectEqualStrings("*status*", buf.name);
    try t.expect(buf.read_only);
    try t.expect(std.mem.startsWith(u8, out, "13")); // innermost section at 15

    // Refresh = the peer committing again; merges like any collaborator.
    const out2 = try p.eval(gpa,
        \\(scion.insert 7 "!")
        \\(scion.commit)
    , "tool2.fnl");
    gpa.free(out2);
    const text = try host.editor().text().toOwnedSlice(gpa);
    defer gpa.free(text);
    try t.expect(std.mem.indexOf(u8, text, "!") != null);

    // Sections survive the edit (anchored spans shift).
    const out3 = try p.eval(gpa, "(scion.section_at \"sections\" 0)", "tool3.fnl");
    defer gpa.free(out3);
    try t.expect(std.mem.startsWith(u8, out3, "0"));
}

test "editor: bulk load — big file opens as a compacted base, edits and saves" {
    const gpa = t.allocator;
    var tmp_dir = t.tmpDir(.{});
    defer tmp_dir.cleanup();
    const path = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/big.txt", .{tmp_dir.sub_path});
    defer gpa.free(path);
    {
        const big = try gpa.alloc(u8, core.Editor.bulk_load_bytes + 4096);
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
    // Zero events: the content is the base.
    try t.expectEqual(@as(usize, 0), ed.doc.doc.history.eventCount());
    try t.expect(!try ed.isDirty(gpa));

    // Ordinary editing + guarded save on top of the base.
    try ed.insertText(gpa, "EDIT ");
    try t.expect(try ed.isDirty(gpa));
    try ed.requestSave(gpa);
    while (!ed.pollSave(gpa)) std.Thread.yield() catch {};
    try t.expect(!try ed.isDirty(gpa));
}

test "bundled plugin: buffers/status/help built in fennel over introspection" {
    const gpa = t.allocator;
    var host: TestHost = undefined;
    try TestHost.init(gpa, &host);
    defer host.deinit(gpa);
    const run = core.command.run;

    const std_plugin = try core.Plugin.create(gpa, &host.ctx, "std");
    defer std_plugin.destroy();
    gpa.free(try std_plugin.eval(gpa, @embedFile("../bundled.fnl"), "bundled.fnl"));

    // A second buffer with content so dirty/label logic has teeth.
    _ = try run(&host.commands, &host.ctx, "buffer-create", &.{.{ .string = "notes" }});
    try host.editor().insertText(gpa, "hello");

    // status → echo describes the active buffer.
    _ = try run(&host.commands, &host.ctx, "status", &.{});
    try t.expect(std.mem.indexOf(u8, host.echo_line.items, "notes") != null);
    try t.expect(std.mem.indexOf(u8, host.echo_line.items, "modified") != null);

    // buffers → a live pick whose entries carry docstrings; accepting
    // the scratch row switches buffers.
    _ = try run(&host.commands, &host.ctx, "buffers", &.{});
    try t.expect(host.pick.active);
    try t.expect(host.pick.filtered.items.len == 2);
    var saw_doc = false;
    for (0..host.pick.filtered.items.len) |i| {
        if (host.pick.docOf(i).len > 0) saw_doc = true;
    }
    try t.expect(saw_doc);
    // Filter to the scratch buffer and accept.
    _ = try run(&host.commands, &host.ctx, "pick-input", &.{.{ .string = "scratch" }});
    _ = try run(&host.commands, &host.ctx, "pick-accept", &.{});
    try t.expect(!host.pick.active);
    try t.expectEqualStrings("*scratch*", host.buffers.active().name);

    // help → pick over commands with summaries as docs; frecency: the
    // accepted command ranks first on the next empty-query open.
    _ = try run(&host.commands, &host.ctx, "help", &.{});
    try t.expect(host.pick.active);
    _ = try run(&host.commands, &host.ctx, "pick-input", &.{.{ .string = "buffer-next" }});
    _ = try run(&host.commands, &host.ctx, "pick-accept", &.{}); // runs buffer-next
    try t.expectEqualStrings("notes", host.buffers.active().name);
    _ = try run(&host.commands, &host.ctx, "help", &.{});
    try t.expectEqualStrings("buffer-next", host.pick.selection().?);
    _ = try run(&host.commands, &host.ctx, "pick-cancel", &.{});

    // Tab completion: a query that is a strict subsequence completes to
    // the full command name (sole match).
    _ = try run(&host.commands, &host.ctx, "help", &.{});
    _ = try run(&host.commands, &host.ctx, "pick-input", &.{.{ .string = "svas" }});
    _ = try run(&host.commands, &host.ctx, "pick-complete", &.{});
    try t.expectEqualStrings("save-as", host.pick.query.items);
    _ = try run(&host.commands, &host.ctx, "pick-cancel", &.{});
}

test "plugin: scion.pick with a native file source streams candidates" {
    const gpa = t.allocator;
    // A known tree under the test's writable cache dir (same mechanism
    // the ShellFs/fs_source tests rely on), so the assertion is
    // cwd-independent.
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    {
        var threaded: std.Io.Threaded = .init(gpa, .{});
        defer threaded.deinit();
        const io = threaded.io();
        try tmp.dir.writeFile(io, .{ .sub_path = "one.zig", .data = "" });
        try tmp.dir.createDirPath(io, "sub");
        try tmp.dir.writeFile(io, .{ .sub_path = "sub/two.zig", .data = "" });
    }
    const root = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer gpa.free(root);

    var host: TestHost = undefined;
    try TestHost.init(gpa, &host);
    const p = try core.Plugin.create(gpa, &host.ctx, "std");
    // Teardown order (LIFO): close any open pick FIRST (its Lua cleanup
    // needs a live VM + ctx), then destroy the plugin (needs live
    // ctx.caps), then the host. Robust even if an assertion returns
    // early with the pick still open.
    defer host.deinit(gpa);
    defer p.destroy();
    defer if (host.pick.active) {
        _ = core.command.run(&host.commands, &host.ctx, "pick-cancel", &.{}) catch {};
    };

    // The LocalFinder walks on the pool; pick.tick folds candidates in.
    const src = try std.fmt.allocPrint(gpa,
        \\(scion.pick "file" nil (fn [_] nil) {{:source "files" :root "{s}" :free_text true}})
    , .{root});
    defer gpa.free(src);
    gpa.free(try p.eval(gpa, src, "t"));
    try t.expect(host.pick.active);

    var folded = false;
    for (0..2000) |_| {
        if (try host.pick.tick(&host.ctx)) folded = true;
        if (folded and host.pick.items.items.len > 0) break;
        std.Thread.yield() catch {};
    }
    try t.expectEqual(@as(usize, 2), host.pick.items.items.len);
    var saw_nested = false;
    for (host.pick.items.items) |it| {
        if (std.mem.endsWith(u8, it, "two.zig")) saw_nested = true;
    }
    try t.expect(saw_nested);

    // Close (runs the source's cancel + the accept-ref cleanup) before
    // teardown so the worker drains cleanly under the pool.
    _ = try core.command.run(&host.commands, &host.ctx, "pick-cancel", &.{});
    try t.expect(!host.pick.active);
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
    try t.expect(host.pick.active);
    // Instant-tier results were folded during fire (source path); the
    // pick already carries them, no bespoke tick needed.
    try t.expect(host.pick.items.items.len >= 2);

    _ = try core.command.run(&host.commands, &host.ctx, "pick-input", &.{.{ .string = "alp" }});
    _ = try core.command.run(&host.commands, &host.ctx, "pick-accept", &.{});
    try t.expect(!host.pick.active);
    const text = try host.editor().text().toOwnedSlice(gpa);
    defer gpa.free(text);
    try t.expectEqualStrings("alpha", text);
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
    try t.expectEqual(@as(usize, 0), ed.doc.doc.history.eventCount());
    try t.expect(!try ed.isDirty(gpa));

    // The panic case: edit + save AFTER compaction — markSaved's
    // peerSyncTo must work against the rebuilt mirror.
    ed.moveDocEnd();
    try ed.insertText(gpa, "post-compact edit\n");
    try ed.requestSave(gpa);
    while (!ed.pollSave(gpa)) std.Thread.yield() catch {};
    try t.expect(ed.save_state == .idle);
    try t.expect(!try ed.isDirty(gpa));
}
