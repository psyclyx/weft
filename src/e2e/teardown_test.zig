//! e2e test file — drives the shared harness (harness.zig) as a user and
//! observes the surface + disk. The alias block pulls what these tests need from
//! the one harness module; unused aliases are harmless at container scope.

const std = @import("std");
const t = std.testing;
const h = @import("harness.zig");

const core = h.core;
const snail = h.snail;
const session = h.session;
const region = h.region;
const window_layout = h.window_layout;
const harness = h.gfx_harness;
const app_providers = h.app_providers;
const app_session = h.app_session;
const app_collab = h.app_collab;

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

// ── Teardown ordering: shells outlive buffers (the untestable shutdown path) ──
//
// main()'s shutdown is invisible to the compiler and to every GUI-less test: a
// mis-ordered deinit only crashes a real user at quit. This test stands up the
// two ordering-critical clusters (`Session` owns the buffers; `Providers` owns
// the persistent remote shells) exactly as main() builds them, attaches a
// shell-backed buffer with an IN-FLIGHT save, then tears them down IN MAIN()'s
// ORDER — Session before Providers, with the pool joined in between. Under
// std.testing.allocator (leak detection) + the DebugAllocator (double-free/UAF),
// a wrong cut (shells freed before the buffers whose save worker still holds a
// shell backing) fails HERE instead of crashing at a user's quit.
//
// Editor.deinit spin-waits any in-flight save to completion using the shell fs,
// so the shell MUST still be alive when the buffer dies — precisely the
// shells-outlive-buffers invariant. Freeing Providers before Session would UAF.
test "app/teardown: shells outlive buffers through an in-flight shell save" {
    const gpa = t.allocator;
    var td = t.tmpDir(.{});
    defer td.cleanup();
    const path = try tmpPath(gpa, &td.sub_path, "shell-backed.txt");
    defer gpa.free(path);
    // The backing shell reads the path off the local fs; seed it on disk.
    try core.file.writeBytes(gpa, path, "initial contents\n");

    const environ: std.process.Environ = .{ .block = .{ .slice = std.mem.span(std.c.environ) } };
    const pool = try core.task.Pool.init(gpa, .{});

    // Build the two clusters in main()'s construction order: Providers'
    // registries first (the session's capability consumers bind onto them),
    // then the Session, then Providers' attach phase (borrows session caps).
    var prov: app_providers.Providers = undefined;
    try prov.initRegistries(gpa);
    var which_key_now = false;
    var sess: app_session.Session = undefined;
    try sess.init(gpa, pool, "teardown-user", &prov.grammars, &which_key_now);
    prov.initAttach(gpa, &sess.caps, environ);

    // A persistent shell registered in Providers.attach_deps.shells, exactly as
    // AttachDeps.shellFor does (gpa.create + spawn + put with a duped key), so
    // Providers.deinit is what frees it — the cross-cluster resource.
    const fs = try gpa.create(core.ShellFs);
    fs.* = try core.ShellFs.spawn(gpa, &.{"/bin/sh"}, environ);
    try prov.attach_deps.shells.put(gpa, try gpa.dupe(u8, "localhost"), fs);

    // Back buffer 0 by that shell and kick an in-flight save: the pool worker now
    // holds `fs`, and Editor.deinit will spin-wait it out at teardown.
    const ed = &sess.buffers.active().editor;
    try ed.openShell(gpa, fs, path);
    try ed.doc.insert(gpa, ed.text().byteLen(), "an unsaved edit\n");
    try ed.requestSave(gpa);

    // ── Tear down in main()'s EXACT order ──
    // 1. detach per-buffer providers (before the buffers/caps die).
    {
        var it = sess.buffers.iterator();
        while (it.next()) |b| app_providers.detachProviders(&prov.attach_deps, b);
    }
    // 2. Session (buffers die here; Editor.deinit waits out the save on `fs`).
    sess.deinit(gpa);
    // 3. Pool joins remaining workers.
    pool.deinit();
    // DETERMINISTIC proof of shells-outlive-buffers: the buffers and every save
    // worker that referenced `fs` are now gone (Session + pool torn down), yet
    // the shell — owned by Providers, not yet freed — is still ALIVE. A live
    // round-trip succeeds here; if the cut were inverted (Providers freed first)
    // this would UAF the shell instead. (This is the checkable core of the
    // invariant. The in-flight-save UAF itself is timing-dependent — a fast
    // shell save can complete before teardown — so we assert liveness directly
    // rather than racing the crash.)
    const live_size = try fs.size(gpa, path);
    try t.expect(live_size > 0);
    // 4. Providers LAST — frees the shells, safely after every buffer + worker
    //    that referenced them. (A leak/double-free trips the allocator.)
    prov.deinit(gpa);
}

// The default modeless path (no --connect/--listen): Collab still owns the async
// `.peer` fs bridge, the reply-correlation map, and the share intent surface.
// Its deinit must free them and clear the process-global bridge pointer without
// leak or double-free. (The CONNECTED teardown — conn/hub/session/partial —
// needs a live socket + GUI, so it can't run here; Collab.deinit mirrors the
// prior main() defers line-for-line, verified by inspection. This covers the
// path every bare launch hits, under the leak-checking allocator.)
test "app/teardown: unconnected Collab constructs + tears down clean" {
    const gpa = t.allocator;
    const pool = try core.task.Pool.init(gpa, .{});
    defer pool.deinit();
    var prov: app_providers.Providers = undefined;
    try prov.initRegistries(gpa);
    defer prov.deinit(gpa);
    var which_key_now = false;
    var sess: app_session.Session = undefined;
    try sess.init(gpa, pool, "collab-user", &prov.grammars, &which_key_now);
    defer sess.deinit(gpa);
    // known_peers + my_identity stay main() locals (Collab borrows them); an empty
    // in-memory store keeps this hermetic (no config-home read/write).
    var known: core.known_peers.KnownPeers = .{ .gpa = gpa };
    defer known.deinit();
    var id = core.identity.Identity.generate();

    var col: app_collab.Collab = undefined;
    col.initBase(gpa, &sess.buffers, &sess.caps, &known, null, .none, null, .view);
    try col.connect(gpa, &sess.buffers.active().editor, &sess.caps, &id, null, "tok", "user", false);
    // main()'s order: Collab before Session (it reads the session caps + must
    // unbind before the doc layers drop).
    col.deinit(gpa);
}
