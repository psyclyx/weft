//! e2e test file — drives the shared harness (harness.zig) as a user and
//! observes the surface + disk. The alias block pulls what these tests need from
//! the one harness module; unused aliases are harmless at container scope.

const std = @import("std");
const t = std.testing;
const h = @import("harness.zig");

const core = h.core;
const session = h.session;
const region = h.region;
const window_layout = h.window_layout;
const harness = h.gfx_harness;
const app_providers = h.app.providers;
const app_session = h.app.session;
const app_collab = h.app.collab;

const Editor = h.Editor;
const Loopback = h.Loopback;
const Project = h.Project;
const ConfigLoader = h.ConfigLoader;
const app_w = h.app_w;

const loadVim = h.loadVim;
const loadWorkspace = h.loadWorkspace;
const loadWebIde = h.loadWebIde;
const bootConfig = h.bootConfig;
const whichKeyText = h.whichKeyText;
const whichKeyShows = h.whichKeyShows;
const authorFile = h.authorFile;
const toolText = h.toolText;
const drainToolContains = h.drainToolContains;
const drainUntilOracle = h.drainUntilOracle;
const tmpPath = h.tmpPath;
const socketPair = h.socketPair;
const napUs = h.napUs;
const loadEmacs = h.loadEmacs;
const loadHelix = h.loadHelix;

// ── Multiplayer: two harnesses pair on a document over the loopback ──
//
// Exercises the REAL session sync layer: two live encrypted Sessions over a
// socketpair, document sync via `Collab.tick` (drain → handleFrame → push) —
// the same code `collab.tickCollab` calls under the hood. Peer A types through
// the real keymap/command path; the pump converges it into peer B's buffer.

// The coworker scenario from the brief: they "use emacs, but can edit". A vim
// peer and an emacs peer share the document; both edit through their OWN editor
// and the real session sync converges them. Different keymaps, one document.
test "app/collab: an emacs coworker joins — vim + emacs peers converge" {
    const gpa = t.allocator;
    var a: Editor = undefined;
    try Editor.initNamed(gpa, &a, "alice");
    defer a.deinit();
    var b: Editor = undefined;
    try Editor.initNamed(gpa, &b, "bob");
    defer b.deinit();
    try loadVim(&a); // alice uses vim
    try loadEmacs(&b); // bob uses emacs (modeless — printable keys self-insert)

    var link: Loopback = undefined;
    try Loopback.init(&link, gpa, &a, &b, "alice", "bob");
    defer link.deinit();

    // Alice edits the vim way (i → text → Esc); Bob just types (emacs is modeless).
    a.press("i", "");
    a.typeText("ALICE");
    a.press("Escape", "");
    b.typeText("BOB");

    // Both replicas converge to carry BOTH peers' text — real merge, two editors.
    const Ctx = struct { a: *Editor, b: *Editor };
    const converged = try link.pumpUntil(Ctx{ .a = &a, .b = &b }, struct {
        fn pred(c: Ctx) bool {
            const at = c.a.buffers.active().textEditor().?.text().toOwnedSlice(c.a.gpa) catch return false;
            defer c.a.gpa.free(at);
            const bt = c.b.buffers.active().textEditor().?.text().toOwnedSlice(c.b.gpa) catch return false;
            defer c.b.gpa.free(bt);
            return std.mem.indexOf(u8, at, "ALICE") != null and std.mem.indexOf(u8, at, "BOB") != null and
                std.mem.indexOf(u8, bt, "ALICE") != null and std.mem.indexOf(u8, bt, "BOB") != null;
        }
    }.pred);
    try t.expect(converged);

    const at = try a.buffers.active().textEditor().?.text().toOwnedSlice(gpa);
    defer gpa.free(at);
    const bt = try b.buffers.active().textEditor().?.text().toOwnedSlice(gpa);
    defer gpa.free(bt);
    try t.expectEqualStrings(at, bt); // identical on both, despite different editors
}

// The partner matrix continues: a HELIX coworker, and an emacs+helix pair — so
// the three reference editors are all shown collaborating on one document. The
// keymap is just data; convergence is the session layer, editor-agnostic.
test "app/collab: a helix coworker joins — vim + helix peers converge" {
    const gpa = t.allocator;
    var a: Editor = undefined;
    try Editor.initNamed(gpa, &a, "alice");
    defer a.deinit();
    var b: Editor = undefined;
    try Editor.initNamed(gpa, &b, "bob");
    defer b.deinit();
    try loadVim(&a);
    try loadHelix(&b); // bob uses helix (selection-first modal editing)

    var link: Loopback = undefined;
    try Loopback.init(&link, gpa, &a, &b, "alice", "bob");
    defer link.deinit();

    a.press("i", "");
    a.typeText("ALICE");
    a.press("Escape", "");
    b.press("i", ""); // helix: i enters helix-insert
    b.typeText("HELIX");
    b.press("Escape", "");

    const Ctx = struct { a: *Editor, b: *Editor };
    const ok = try link.pumpUntil(Ctx{ .a = &a, .b = &b }, struct {
        fn pred(c: Ctx) bool {
            const at = c.a.buffers.active().textEditor().?.text().toOwnedSlice(c.a.gpa) catch return false;
            defer c.a.gpa.free(at);
            const bt = c.b.buffers.active().textEditor().?.text().toOwnedSlice(c.b.gpa) catch return false;
            defer c.b.gpa.free(bt);
            return std.mem.indexOf(u8, at, "ALICE") != null and std.mem.indexOf(u8, at, "HELIX") != null and
                std.mem.indexOf(u8, bt, "ALICE") != null and std.mem.indexOf(u8, bt, "HELIX") != null;
        }
    }.pred);
    try t.expect(ok);
}

test "app/collab: emacs + helix coworkers converge (no vim in sight)" {
    const gpa = t.allocator;
    var a: Editor = undefined;
    try Editor.initNamed(gpa, &a, "alice");
    defer a.deinit();
    var b: Editor = undefined;
    try Editor.initNamed(gpa, &b, "bob");
    defer b.deinit();
    try loadEmacs(&a); // alice: emacs (modeless)
    try loadHelix(&b); // bob: helix

    var link: Loopback = undefined;
    try Loopback.init(&link, gpa, &a, &b, "alice", "bob");
    defer link.deinit();

    a.typeText("EMACS"); // modeless self-insert
    b.press("i", "");
    b.typeText("HELIX");
    b.press("Escape", "");

    const Ctx = struct { a: *Editor, b: *Editor };
    const ok = try link.pumpUntil(Ctx{ .a = &a, .b = &b }, struct {
        fn pred(c: Ctx) bool {
            const at = c.a.buffers.active().textEditor().?.text().toOwnedSlice(c.a.gpa) catch return false;
            defer c.a.gpa.free(at);
            const bt = c.b.buffers.active().textEditor().?.text().toOwnedSlice(c.b.gpa) catch return false;
            defer c.b.gpa.free(bt);
            return std.mem.indexOf(u8, at, "EMACS") != null and std.mem.indexOf(u8, at, "HELIX") != null and
                std.mem.indexOf(u8, bt, "EMACS") != null and std.mem.indexOf(u8, bt, "HELIX") != null;
        }
    }.pred);
    try t.expect(ok);
}

test "app/collab: peer A types, it converges into peer B's buffer + cursor" {
    const gpa = t.allocator;
    var a: Editor = undefined;
    try Editor.initNamed(gpa, &a, "alice");
    defer a.deinit();
    var b: Editor = undefined;
    try Editor.initNamed(gpa, &b, "bob");
    defer b.deinit();
    try loadVim(&a);
    try loadVim(&b);

    var link: Loopback = undefined;
    try Loopback.init(&link, gpa, &a, &b, "alice", "bob");
    defer link.deinit();

    // Alice types through the real vim path (i → text → Esc).
    a.press("i", "");
    a.typeText("hello from alice");
    a.press("Escape", "");

    // Pump the loopback until Bob's document carries Alice's text.
    const Ctx = struct { b: *Editor };
    const converged = try link.pumpUntil(Ctx{ .b = &b }, struct {
        fn pred(c: Ctx) bool {
            const txt = c.b.buffers.active().textEditor().?.text().toOwnedSlice(c.b.gpa) catch return false;
            defer c.b.gpa.free(txt);
            return std.mem.indexOf(u8, txt, "hello from alice") != null;
        }
    }.pred);
    if (!converged) {
        const at0 = a.buffers.active().textEditor().?.text().toOwnedSlice(gpa) catch &.{};
        defer gpa.free(at0);
        const bt0 = b.buffers.active().textEditor().?.text().toOwnedSlice(gpa) catch &.{};
        defer gpa.free(bt0);
        std.debug.print("\n[CONVERGE-FAIL] host_live={} peer_live={} alice='{s}' bob='{s}' host_announced={} peer_announced={}\n", .{
            link.host_sess.liveness(),    link.peer_sess.liveness(),    at0, bt0,
            link.host_col.core.announced, link.peer_col.core.announced,
        });
    }
    try t.expect(converged);

    // Both replicas hold identical text — convergence, not just delivery.
    const at = try a.buffers.active().textEditor().?.text().toOwnedSlice(gpa);
    defer gpa.free(at);
    const bt = try b.buffers.active().textEditor().?.text().toOwnedSlice(gpa);
    defer gpa.free(bt);
    try t.expectEqualStrings(at, bt);

    // Cursor/presence: Alice's caret replicated into Bob's presence layer.
    // Presence rides a SEPARATE feed (channel base+1) from the text ops, so it
    // can land a tick or two after the text converges — pump for it rather than
    // asserting immediately (asserting bare here is a race that flakes under
    // load). This was the actual cause of the collab test's intermittent fail.
    const PCtx = struct { link: *Loopback };
    const saw_alice = try link.pumpUntil(PCtx{ .link = &link }, struct {
        fn pred(c: PCtx) bool {
            return c.link.peer_col.presenceNamed("alice") != null;
        }
    }.pred);
    try t.expect(saw_alice);

    // Round-trip the other way: Bob edits, it lands back on Alice.
    b.press("A", ""); // append at line end (vim)
    b.press("i", ""); // ensure insert (A may already switch; harmless)
    b.typeText(" + bob");
    b.press("Escape", "");
    const Ctx2 = struct { a: *Editor };
    const back = try link.pumpUntil(Ctx2{ .a = &a }, struct {
        fn pred(c: Ctx2) bool {
            const txt = c.a.buffers.active().textEditor().?.text().toOwnedSlice(c.a.gpa) catch return false;
            defer c.a.gpa.free(txt);
            return std.mem.indexOf(u8, txt, "bob") != null;
        }
    }.pred);
    try t.expect(back);
}

// Regression guard for the session teardown hang: `Session.destroy` must WAKE
// its blocked reader (via shutdown()), not park on it. Before the fix, close()
// alone left the reader blocked in read() until the peer's next ~1s heartbeat,
// so every teardown took ~1000ms — real dead time that starved other threads
// under load. This runs the isolated session sync (no wasm) and asserts each
// teardown is prompt AND the doc converged.
test "regression: session teardown is prompt (no reader-park hang)" {
    const gpa = t.allocator;
    var iter: usize = 0;
    while (iter < 12) : (iter += 1) {
        var da = try core.Document.init(gpa, "alice");
        defer da.deinit(gpa);
        var db = try core.Document.init(gpa, "bob");
        defer db.deinit(gpa);
        const fds = try socketPair();
        var fa = session.FdLink{ .fd = fds[0] };
        var fb = session.FdLink{ .fd = fds[1] };
        const sa = try session.Session.create(gpa, fa.link(), .server, "t", .own, null);
        const sb = try session.Session.create(gpa, fb.link(), .client, "t", .own, null);
        var ca = try session.Collab.init(gpa, sa, &da, "alice");
        var cb = try session.Collab.init(gpa, sb, &db, "bob");

        try da.insert(gpa, 0, "hello");
        var ok = false;
        const deadline = core.task.nowNs() + 5 * std.time.ns_per_s;
        while (core.task.nowNs() < deadline) {
            _ = try ca.tick(0);
            _ = try cb.tick(0);
            if (db.text().byteLen() >= 5) {
                ok = true;
                break;
            }
            napUs(200);
        }
        try t.expect(ok);

        // Teardown must be prompt — the whole point. A regressed destroy() that
        // parks on the blocked reader would blow well past this (~1s each).
        const t1 = core.task.nowNs();
        ca.deinit();
        cb.deinit();
        sb.destroy();
        sa.destroy();
        try t.expect(core.task.nowNs() - t1 < 300 * std.time.ns_per_ms);
    }
}
