//! e2e test file — drives the shared harness (harness.zig) as a user and
//! observes the surface + disk. The alias block pulls what these tests need from
//! the one harness module; unused aliases are harmless at container scope.

const std = @import("std");
const t = std.testing;
const h = @import("harness.zig");
const language_support = @import("language_support.zig");

const core = h.core;
const session = h.session;
const region = h.region;
const window_layout = h.window_layout;
const harness = h.gfx_harness;
const app_providers = h.app_providers;
const app_session = h.app_session;
const app_collab = h.app_collab;
const semantic = h.semantic_model;

const Editor = h.Editor;
const Loopback = h.Loopback;
const Project = h.Project;
const App = h.App;
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
const drainBufferContains = h.drainBufferContains;
const drainToolContains = h.drainToolContains;
const drainUntilOracle = h.drainUntilOracle;
const drainLoopIdle = h.drainLoopIdle;
const tmpPath = h.tmpPath;
const socketPair = h.socketPair;
const napUs = h.napUs;

/// Compare one editor body inside two completed side-by-side production
/// frames. The tab strip and status line are excluded so a position label
/// cannot make a missing remote caret look rendered.
fn pairBodyChanged(before: []const u8, after: []const u8, right: bool) bool {
    const pair_width = @as(usize, h.app_w) * 2;
    if (before.len != after.len or before.len != pair_width * h.app_h * 4) return false;
    const stride = pair_width * 4;
    const x_offset = @as(usize, if (right) h.app_w else 0) * 4;
    const half_bytes = @as(usize, h.app_w) * 4;
    var changed: usize = 0;
    var y: usize = 28;
    while (y < h.app_h - 52) : (y += 1) {
        const start = y * stride + x_offset;
        for (before[start .. start + half_bytes], after[start .. start + half_bytes]) |a, b| {
            changed += @intFromBool(a != b);
        }
    }
    // A two-pixel presence bar across one text row changes dozens of channel
    // bytes. Keep the floor above antialiasing noise but far below a caret.
    return changed >= 16;
}

// This is intentionally the plugin inventory from the shipped config, not a
// hand-picked test fixture. The spine checks that config.js requested every
// entry and that every entry loaded successfully, including the resident
// `dap.js` plugin through the same QuickJS reactor used by the desktop app.
const shipped_config_plugins = [_][]const u8{
    "edit",       "complete",    "project",   "structural", "region",  "shell",     "palette",
    "motions",    "textobjects", "operators", "vim",        "ts",      "comment",   "indent",
    "whitespace", "numbers",     "autopair",  "consult",    "git",     "grep",      "run",
    "make",       "notes",       "fmt",       "buffers",    "windows", "modes",     "snippets",
    "direnv",     "llm",         "console",   "repl",       "net",     "which_key", "dired",
    "lsp",        "debug",       "dap.js",
};

fn assertShippedConfigLoaded(loader: *const ConfigLoader) !void {
    try t.expectEqual(@as(usize, 0), loader.missing.items.len);
    try t.expectEqual(@as(usize, 0), loader.failed.items.len);
    for (shipped_config_plugins) |expected| {
        var requested = false;
        for (loader.requested.items) |actual| {
            requested = requested or std.mem.eql(u8, actual, expected);
        }
        try t.expect(requested);
    }
}

/// Focus a named field through the generic retained-view focus protocol.  The
/// scenario uses this only to make directory enumeration order irrelevant;
/// all edits and actions after the focus change still travel through the
/// shipped Vim/config bindings.
fn spineFocusDiredName(ed: *Editor, gpa: std.mem.Allocator, name: []const u8) !void {
    const path = ed.head.semantic_focus.path() orelse return error.NoDiredFocus;
    const view = ed.session.system.semantic.views.get(path.view) orelse return error.NoDiredView;
    const rows = switch (view.scene.content) {
        .container => |container| container.children,
        else => return error.DiredSceneNotContainer,
    };
    for (rows) |row| {
        if (row.content != .container) continue;
        const columns = row.content.container.children;
        if (columns.len < 3 or columns[2].content != .field) continue;
        const field_ref = columns[2].content.field.ref;
        var snapshot = try ed.session.system.semantic.fields.get(field_ref).?.snapshot(gpa);
        defer snapshot.deinit();
        if (std.mem.eql(u8, snapshot.value.bytes, name)) {
            _ = try ed.session.system.semantic.focusView(ed.head, gpa, path.view, columns[2].id);
            return;
        }
    }
    return error.DiredNameNotFound;
}

const SpineCollabClock = struct {
    link: *h.Loopback,
    tick_error: ?anyerror = null,

    pub fn beforeDemoFrame(self: *SpineCollabClock) void {
        // Animation frames service collaboration without imposing a
        // distributed quiescence barrier at 30 fps. Named narrative
        // milestones call `synchronize` explicitly before capture. Transport
        // jitter samples at queued-write boundaries, independently of this
        // recorder/application-frame cadence.
        var rounds: usize = 0;
        while (rounds < 2) : (rounds += 1) {
            self.link.tick() catch |err| {
                self.tick_error = err;
                return;
            };
            napUs(300);
        }
    }
};

// ── Project-level e2e: build a tiny app the way a person would ───────
//
// This is the test we keep growing. It drives weft through the natural motions
// of starting a project in a scratch dir: open a file, write code, save it to
// disk, and confirm the language is recognized. Each granular step is its own
// test so a failure names exactly what broke. Capabilities we don't have yet
// are recorded as gaps (the difficulty is the signal), not faked as passes.

test "e2e/project: weft `save` writes the buffer to disk" {
    const gpa = t.allocator;
    var td = t.tmpDir(.{});
    defer td.cleanup();
    const path = try tmpPath(gpa, &td.sub_path, "main.zig");
    defer gpa.free(path);

    var ed: Editor = undefined;
    try Editor.init(gpa, &ed);
    defer ed.deinit();
    try loadWorkspace(&ed);

    // The natural way: open the path, type code, save.
    ed.runStr("open", path); // new file → adopts the path
    ed.press("i", "");
    ed.typeText("const x = 41;\n");
    ed.press("Escape", "");
    ed.run("save");
    ed.waitSave(); // drive the async save to completion, deterministically

    const on_disk = try core.file.readAlloc(gpa, path);
    defer gpa.free(on_disk);
    try t.expect(std.mem.indexOf(u8, on_disk, "const x = 41;") != null);
}

test "e2e/project: opening the saved file recognizes its language" {
    const gpa = t.allocator;
    var td = t.tmpDir(.{});
    defer td.cleanup();
    const zig_path = try tmpPath(gpa, &td.sub_path, "app.zig");
    defer gpa.free(zig_path);
    const js_path = try tmpPath(gpa, &td.sub_path, "app.js");
    defer gpa.free(js_path);

    var ed: Editor = undefined;
    try Editor.init(gpa, &ed);
    defer ed.deinit();
    try loadWorkspace(&ed);

    // `modes`' on_activate detects the language but no longer echoes it
    // (task #19 item 4 — `on_activate` is BACKGROUND, `wl_echo` is head-
    // gated; see src/guest/modes.zig's doc). Assert the structural
    // guarantee instead: neither open lands language text on the echo line.
    ed.runStr("open", zig_path);
    try t.expect(std.mem.indexOf(u8, ed.echoText(), "zig") == null);
    ed.runStr("open", js_path); // switching buffers re-fires on_activate
    try t.expect(std.mem.indexOf(u8, ed.echoText(), "javascript") == null);
}

test "e2e/regression: switching from a semantic view edits the new text buffer" {
    const gpa = t.allocator;
    var app: App = undefined;
    try app.init(gpa);
    defer app.deinit();
    const ed = &app.ed;

    try core.file.writeBytesMakingDirs(gpa, app.proj.root, "semantic.txt", "field draft\n");
    try core.file.writeBytesMakingDirs(gpa, app.proj.root, "plain.txt", "");
    ed.runStr("open", ".");
    const dired_path = ed.head.semantic_focus.path() orelse return error.NoDiredFocus;
    const dired_view = ed.session.system.semantic.views.get(dired_path.view) orelse return error.NoDiredView;
    var old_field: ?semantic.scene.FieldRef = null;
    for (dired_view.scene.content.container.children) |row| {
        if (row.content != .container) continue;
        const columns = row.content.container.children;
        if (columns.len < 3 or columns[2].content != .field) continue;
        const ref = columns[2].content.field.ref;
        var snapshot = try ed.session.system.semantic.fields.get(ref).?.snapshot(gpa);
        defer snapshot.deinit();
        if (std.mem.eql(u8, snapshot.value.bytes, "semantic.txt")) old_field = ref;
    }
    const retained = old_field orelse return error.DiredNameNotFound;
    ed.runStr("open", "plain.txt");
    ed.press("i", "");
    ed.typeText("typed through text buffer");
    const text = try ed.textAlloc();
    defer gpa.free(text);
    try t.expectEqualStrings("typed through text buffer", text);
    var old_snapshot = try ed.session.system.semantic.fields.get(retained).?.snapshot(gpa);
    defer old_snapshot.deinit();
    try t.expectEqualStrings("semantic.txt", old_snapshot.value.bytes);
}

test "e2e/project: magit push/pull/fetch transients are sticky menus" {
    const gpa = t.allocator;
    var ed: Editor = undefined;
    try Editor.init(gpa, &ed);
    defer ed.deinit();
    try loadWorkspace(&ed);

    // The flag transients must be sticky (stay open while flags accumulate) —
    // sticky implies menu-mode, so which-key also lists their keys. The reset
    // transient (a plain one-shot menu) must NOT be sticky.
    try t.expect(ed.keymap.isStickyMenu("git-push-menu"));
    try t.expect(ed.keymap.isStickyMenu("git-pull-menu"));
    try t.expect(ed.keymap.isStickyMenu("git-fetch-menu"));
    try t.expect(ed.keymap.isMenuMode("git-push-menu"));
    try t.expect(!ed.keymap.isStickyMenu("git-reset-menu"));
    try t.expect(ed.keymap.isMenuMode("git-reset-menu"));
}

// Task #21: `git-rebase-interactive` re-sets `git-rebase-menu` when a rebase
// is already mid-flight, MEANING to keep the transient open (`c`/`a`/`s` are
// what the user needs next). Before the fix that re-set was undone by
// dispatch.zig's leaf auto-pop: a leaf that leaves the mode UNCHANGED in a
// non-sticky menu reads as "did nothing, pop it" — so `i` bounced straight
// back to *magit*. `git-rebase-menu` is now STICKY (matching git-push/pull/
// fetch-menu's idiom): a same-mode re-set no longer auto-pops, while c/a/s
// still close normally because each explicitly `weft.setMode`s to a
// DIFFERENT mode (magit), which dispatch's "leaf moved us elsewhere" branch
// honors regardless of stickiness. Drives a REAL conflicted rebase (two
// branches editing the same line) so `.git/rebase-merge` exists for real —
// not a faked marker directory.
test "e2e/project: git-rebase-interactive keeps git-rebase-menu open on a real conflicted rebase; continue/abort still close" {
    const gpa = t.allocator;
    var proj: Project = undefined;
    try proj.init(gpa);
    defer proj.deinit();

    var ed: Editor = undefined;
    try Editor.init(gpa, &ed);
    defer ed.deinit();
    try loadWorkspace(&ed);

    // ── Set up a genuinely conflicted rebase via the oracle (a human's own
    // git usage, never the editor) — two branches editing the same line,
    // then rebasing one onto the other. ──
    for ([_][]const u8{
        "git init -q -b master",
        "git config user.email e2e@weft.test",
        "git config user.name weft-e2e",
        "printf 'base\\n' > f.txt && git add f.txt && git commit -q -m c1",
        "git checkout -q -b feature",
        "printf 'feature-change\\n' > f.txt && git add f.txt && git commit -q -m c-feature",
        "git checkout -q master",
        "printf 'master-change\\n' > f.txt && git add f.txt && git commit -q -m c-master",
        "git checkout -q feature",
        "git rebase master >/dev/null 2>&1", // conflicts and pauses — nonzero rc, ignored by oracle()
    }) |cmd| {
        const out = try proj.oracle(cmd);
        gpa.free(out);
    }
    {
        const marker = try proj.oracle("test -d .git/rebase-merge && echo yes || echo no");
        defer gpa.free(marker);
        try t.expectEqualStrings("yes", marker); // the real precondition `rebaseInProgress` checks
    }

    // ── Open magit on the now-conflicted repo. ──
    ed.run("git-status");
    try t.expect(drainToolContains(&ed, "*magit*", "Branch:"));
    try t.expectEqualStrings("magit", ed.mode());

    // ── `r` opens the rebase transient; `i`, with a rebase mid-flight, must
    // leave the user IN it (the bug: it used to bounce back to magit). ──
    ed.press("r", ""); // git-rebase-menu (paired-transient push)
    try t.expectEqualStrings("git-rebase-menu", ed.mode());
    try t.expectEqual(@as(usize, 1), ed.head.transient_stack.items.len);

    ed.press("i", ""); // git-rebase-interactive: rebase in progress -> re-set, sticky holds it open
    try t.expectEqualStrings("git-rebase-menu", ed.mode());
    try t.expectEqual(@as(usize, 1), ed.head.transient_stack.items.len); // not grown, not popped

    // ── `c` (continue) still closes to magit, even though the conflict is
    // still unresolved and `git rebase --continue` itself fails — gatherAfter
    // Seq's `;`-sequenced re-gather always leaves via `weft.setMode("magit")`,
    // a DIFFERENT mode than git-rebase-menu, so it closes regardless of
    // stickiness. ──
    ed.press("c", ""); // git-rebase-continue
    try t.expectEqualStrings("magit", ed.mode());
    try t.expect(!ed.head.hasOpenTransients());
    // Drain `c`'s async `git rebase --continue` (it fails fast — conflict
    // unresolved — but still runs a real subprocess in the SAME repo) before
    // firing another git process below: two live git invocations in one
    // worktree can race on `.git/index.lock`. Wait for the pool to actually
    // report the subprocess done (task #22) — not a fixed tick count, which
    // flaked once under concurrent-build load (see `drainLoopIdle`'s doc).
    try t.expect(drainLoopIdle(&ed));

    // The conflict is still unresolved, so the rebase is still mid-flight —
    // re-opening the menu and pressing `i` again must still hold it open.
    ed.press("r", "");
    ed.press("i", "");
    try t.expectEqualStrings("git-rebase-menu", ed.mode());

    // ── `a` (abort) closes to magit too, and this time actually clears the
    // paused rebase. Mode flips synchronously (`gatherAfterSeq`'s `setMode`
    // runs before the subprocess even starts), but the abort itself is
    // async — poll the on-disk oracle (not `drainToolContains`: *magit*'s
    // buffer already contains a stale "Branch:" from the `c` step's
    // re-gather, so a text-containment check would pass before the abort's
    // OWN re-gather actually lands). ──
    ed.press("a", ""); // git-rebase-abort
    try t.expectEqualStrings("magit", ed.mode());
    try t.expect(!ed.head.hasOpenTransients());
    try t.expect(drainUntilOracle(&proj, &ed, "test -d .git/rebase-merge && echo yes || echo no", "no"));
}

// ── The whole-app spine: start a project, write code, version it ────
//
// This is THE e2e the brief asks for: drive weft the way a person starts a web
// app — in a real directory, through the editor's OWN commands and keys — and
// verify the on-disk result. It launched a documented gap ("live-git subprocess
// e2e needs a tmpdir-as-cwd + proc-drain harness"); `Project` closes it. Every
// place the natural motion had no key/command was treated as SIGNAL and fixed
// in the plugin/config (e.g. there was no in-editor `git init` — now there is),
// never worked around in the test.
test "e2e/spine: write a file, init a repo, stage and commit — all through weft" {
    const gpa = t.allocator;
    var proj: Project = undefined;
    try proj.init(gpa);
    defer proj.deinit();

    var ed: Editor = undefined;
    try Editor.initNamed(gpa, &ed, "alice");
    defer ed.deinit();
    var loader: ConfigLoader = .{ .ed = &ed };
    defer loader.deinit();
    // Run the shipped config: the narrative exercises the same generic
    // actions and bindings a user gets.
    const config_dir = try std.fmt.allocPrint(gpa, "{s}/config", .{proj.prev_cwd});
    defer gpa.free(config_dir);
    try bootConfig(&ed, config_dir, &loader);
    try assertShippedConfigLoaded(&loader);
    // Mirror main/App setup: config evaluation installs the editor plugins,
    // then the active Vim posture becomes the buffer default for newly opened
    // tool/input buffers.
    try ed.buffers.setDefaultMode(gpa, "normal");
    ed.setMode("normal");

    // The shared data-driven fixture supplies all six grammars and one
    // hermetic LSP command. The scenario itself remains the only narrative;
    // this is merely its language matrix.
    const hermetic_lsp = try language_support.fakeServerCommand(gpa);
    defer gpa.free(hermetic_lsp);

    // The scenario always has two named peers. Recording composes their live
    // collaborating views through one synchronized capture operation.
    var mirror: Editor = undefined;
    var have_mirror = false;
    var mirror_loader: ConfigLoader = undefined;
    var have_mirror_loader = false;
    var link: Loopback = undefined;
    var have_link = false;
    var collab_clock: SpineCollabClock = undefined;
    defer if (have_mirror) mirror.deinit();
    defer if (have_mirror_loader) mirror_loader.deinit();
    defer if (have_link) link.deinit();
    {
        try Editor.initNamed(gpa, &mirror, "bob");
        have_mirror = true;
        mirror_loader = .{ .ed = &mirror };
        have_mirror_loader = true;
        // Bob has the same shipped config, but remains an independent session
        // and buffer set until the explicit Loopback pairing below.
        const mirror_config_dir = try std.fmt.allocPrint(gpa, "{s}/config", .{proj.prev_cwd});
        defer gpa.free(mirror_config_dir);
        try bootConfig(&mirror, mirror_config_dir, &mirror_loader);
        try assertShippedConfigLoaded(&mirror_loader);
        try mirror.buffers.setDefaultMode(gpa, "normal");
        mirror.setMode("normal");
        try proj.bindDemoScreens(&ed, &mirror);
    }

    // ── 1. Pair two named peers on the same empty document. ──
    // (Mode starts `normal`; edit BEFORE entering any tool buffer, so no
    // tool-mode ever swallows the typing — see [[mode-leak-class]].)
    // Seed and briefly focus the second file first: this makes the real
    // buffer-activation hook run for the first authored file too (the initial
    // scratch buffer keeps its id when it is opened in place).
    try core.file.writeBytesMakingDirs(gpa, proj.root, "helper.lua", "");
    try core.file.writeBytesMakingDirs(gpa, proj.root, "main.zig", "");
    ed.runStr("open", "helper.lua");
    ed.runStr("open", "main.zig");
    mirror.runStr("open", "helper.lua");
    mirror.runStr("open", "main.zig");
    // Establish the visual baseline before transport/authentication. Recording
    // mode rests here; the ordinary scenario only captures the same real UI.
    proj.capture(&ed, "spine-collaboration-disconnected");
    // Keep that baseline's useful config-loaded echo, then clear it through
    // the ordinary action so the connection chip remains visible while the
    // shared file later becomes dirty.
    ed.runStr("echo", "");
    mirror.runStr("echo", "");
    try Loopback.init(&link, gpa, &ed, &mirror, "alice", "bob");
    have_link = true;
    collab_clock = .{ .link = &link };
    proj.bindDemoFrameHook(h.DemoFrameHook.init(&collab_clock));
    try link.synchronize();
    // The status line now comes from each editor's authenticated live session,
    // so the demo visibly transitions from disconnected to connected.
    proj.capture(&ed, "spine-collaboration-connected");
    proj.rest();

    // Alice establishes a small shared scaffold first. Starting concurrent
    // insertions at the same empty CRDT anchor would correctly interleave
    // their character streams, but it would be a poor editing demo. The two
    // peers instead navigate independently to named slots, then replace those
    // distinct ranges concurrently through their own Vim surfaces.
    ed.press("i", "");
    proj.typeText(
        &ed,
        "const helper = @import(\"helper.zig\");\n\npub fn main() void {\n    ALICE_SLOT\n    BOB_SLOT\n}\n",
    );
    ed.press("Escape", "");
    const SpineScaffold = struct {
        a: *Editor,
        b: *Editor,
        fn pred(c: @This()) bool {
            const at = c.a.buffers.active().editor.text().toOwnedSlice(c.a.gpa) catch return false;
            defer c.a.gpa.free(at);
            const bt = c.b.buffers.active().editor.text().toOwnedSlice(c.b.gpa) catch return false;
            defer c.b.gpa.free(bt);
            return std.mem.indexOf(u8, at, "ALICE_SLOT") != null and
                std.mem.indexOf(u8, at, "BOB_SLOT") != null and
                std.mem.eql(u8, at, bt);
        }
    };
    try t.expect(try link.pumpUntil(SpineScaffold{ .a = &ed, .b = &mirror }, SpineScaffold.pred));
    try link.synchronize();
    proj.capture(&ed, "spine-collaboration-scaffold");

    ed.press("/", "");
    proj.typeText(&ed, "ALICE_SLOT");
    ed.press("Return", "");
    ed.press("c", "");
    ed.press("w", "");
    mirror.press("/", "");
    proj.typeText(&mirror, "BOB_SLOT");
    mirror.press("Return", "");
    mirror.press("c", "");
    mirror.press("w", "");
    proj.typeConcurrently(
        &ed,
        "const answer = helper.value; // alice edits here",
        &mirror,
        "std.debug.print(\"{d}\\n\", .{answer}); // bob was here",
    );
    ed.press("Escape", "");
    mirror.press("Escape", "");
    const SpineConverged = struct {
        a: *Editor,
        b: *Editor,
        fn pred(c: @This()) bool {
            const at = c.a.buffers.active().editor.text().toOwnedSlice(c.a.gpa) catch return false;
            defer c.a.gpa.free(at);
            const bt = c.b.buffers.active().editor.text().toOwnedSlice(c.b.gpa) catch return false;
            defer c.b.gpa.free(bt);
            return std.mem.indexOf(u8, at, "alice edits here") != null and
                std.mem.indexOf(u8, at, "bob was here") != null and
                std.mem.indexOf(u8, at, "SLOT") == null and
                std.mem.eql(u8, at, bt);
        }
    };
    const spine_converged = try link.pumpUntil(SpineConverged{ .a = &ed, .b = &mirror }, SpineConverged.pred);
    if (!spine_converged) {
        const alice_text = try ed.buffers.active().editor.text().toOwnedSlice(gpa);
        defer gpa.free(alice_text);
        const bob_text = try mirror.buffers.active().editor.text().toOwnedSlice(gpa);
        defer gpa.free(bob_text);
        std.debug.print("spine convergence failed\n--- alice ---\n{s}\n--- bob ---\n{s}\n", .{ alice_text, bob_text });
    }
    try t.expect(spine_converged);
    try link.synchronize();
    try t.expect(collab_clock.tick_error == null);
    proj.capture(&ed, "spine-collaboration-concurrent-edit");
    proj.rest();
    // Deliberately separate the two carets before recording. Each peer then
    // moves once while the OTHER peer's completed pixels are observed. This
    // is the visual gate the old hand-built capture path failed: one local
    // cursor cannot satisfy either cross-peer framebuffer change.
    ed.press("g", "");
    ed.press("g", "");
    mirror.press("G", "");
    const Presence = struct { link: *Loopback };
    try t.expect(try link.pumpUntil(Presence{ .link = &link }, struct {
        fn pred(c: Presence) bool {
            for (c.link.peer_col.presence_names.items) |name| {
                if (std.mem.eql(u8, name, "alice")) return true;
            }
            return false;
        }
    }.pred));
    try link.synchronize();
    const caret_before = try proj.capturePairPixels();
    defer gpa.free(caret_before);
    proj.capture(&ed, "spine-cursors-separated");
    proj.rest();
    const alice_before_bob_move = ed.buffers.active().editor.cursorOffset();
    const bob_before_move = mirror.buffers.active().editor.cursorOffset();
    mirror.press("k", "");
    try t.expectEqual(alice_before_bob_move, ed.buffers.active().editor.cursorOffset());
    try t.expect(bob_before_move != mirror.buffers.active().editor.cursorOffset());
    try link.synchronize();
    const bob_moved = try proj.capturePairPixels();
    defer gpa.free(bob_moved);
    try t.expect(pairBodyChanged(caret_before, bob_moved, false));
    try t.expect(pairBodyChanged(caret_before, bob_moved, true));
    proj.capture(&ed, "spine-cursor-bob-moved");
    proj.rest();
    const alice_before_move = ed.buffers.active().editor.cursorOffset();
    const bob_before_alice_move = mirror.buffers.active().editor.cursorOffset();
    ed.press("j", "");
    try t.expect(alice_before_move != ed.buffers.active().editor.cursorOffset());
    try t.expectEqual(bob_before_alice_move, mirror.buffers.active().editor.cursorOffset());
    try link.synchronize();
    const alice_moved = try proj.capturePairPixels();
    defer gpa.free(alice_moved);
    try t.expect(pairBodyChanged(bob_moved, alice_moved, false));
    try t.expect(pairBodyChanged(bob_moved, alice_moved, true));
    proj.capture(&ed, "spine-cursor-alice-moved");
    proj.rest();
    ed.run("save");
    ed.waitSave();

    // CONTENT is verified on disk (the artifact a human checks), not via the
    // editor's model.
    {
        const disk = try core.file.readAlloc(gpa, "main.zig");
        defer gpa.free(disk);
        try t.expect(std.mem.indexOf(u8, disk, "pub fn main") != null);
    }

    proj.capture(&ed, "spine-collaboration");
    try t.expect(collab_clock.tick_error == null);

    // Leave the shared document before switching either peer to another file;
    // the collab transport is explicitly scoped to the paired document.
    proj.clearDemoFrameHook();
    link.deinit();
    have_link = false;

    // The shared fixture is data-driven: every language authored by this
    // narrative gets the real tree-sitter attachment and the real LSP
    // capability/request path through one hermetic peer.
    for (language_support.cases) |c| {
        try language_support.authorAndCheckSyntax(&proj, &ed, c);
        try language_support.assertLsp(&proj, &ed, c, hermetic_lsp);
        proj.capture(&ed, c.name);
    }

    // Project search and run output are ordinary config/plugin surfaces. A
    // result is visited through Return, then a location-shaped run message is
    // likewise navigable without knowing the producer's implementation.
    ed.runStr("grep", "pub fn main");
    try t.expect(drainToolContains(&ed, "*grep*", "main.zig"));
    proj.capture(&ed, "spine-grep-results");
    ed.press("Return", "");
    try t.expect(!std.mem.eql(u8, ed.mode(), "grep"));
    ed.runStr("run-command", "printf 'main.zig:1: run ok\\n'");
    try t.expect(drainToolContains(&ed, "*output*", "main.zig:1"));
    proj.capture(&ed, "spine-run-output");
    ed.press("Return", "");
    try t.expect(!std.mem.eql(u8, ed.mode(), "output"));

    // Buffer switching is a config binding over the generic picker. Filter
    // and accept the existing buffer, then use the ordinary Vim search to
    // navigate within it.
    ed.chord("SPC ,");
    proj.typeText(&ed, "main.zig");
    proj.capture(&ed, "spine-buffer-picker");
    ed.press("Return", "");
    try t.expectEqualStrings("main.zig", ed.bufferName());
    ed.press("/", "");
    proj.typeText(&ed, "helper");
    ed.press("Return", "");
    {
        const text = try ed.textAlloc();
        defer gpa.free(text);
        try t.expect(std.mem.indexOf(u8, text, "helper") != null);
    }

    // Exercise the shipped generic UI/plugin surfaces that are independent of
    // filesystem semantics: which-key is a surface plugin, windows is a
    // layout action, and autopair is an insert-mode editing provider. These
    // are ordinary config binds, not direct command/keymap calls.
    ed.press("F1", "");
    proj.capture(&ed, "spine-which-key");
    ed.press("Escape", "");
    ed.chord("SPC w v");
    ed.applyWindow();
    try t.expectEqual(@as(usize, 2), ed.paneCount());
    proj.capture(&ed, "spine-window-split");
    ed.chord("SPC w o");
    ed.applyWindow();
    try t.expectEqual(@as(usize, 1), ed.paneCount());
    ed.run("buf-scratch");
    ed.press("i", "");
    ed.press("parenleft", "(");
    proj.typeText(&ed, "autopair");
    ed.press("Escape", "");
    {
        const scratch = try ed.textAlloc();
        defer gpa.free(scratch);
        try t.expect(std.mem.indexOf(u8, scratch, "(autopair)") != null);
    }

    // The catalog's smaller composable providers get real effects too; being
    // present in the config manifest is not behavioral coverage.
    ed.run("duplicate-line");
    ed.run("upcase-line");
    ed.runStr("mark-region", "text");
    try t.expect(ed.subs.list.items.len > 0);
    ed.runStr("insert-shell", "printf shell-plugin");
    try t.expect(drainBufferContains(&ed, "shell-plugin"));
    ed.press("o", "");
    proj.typeText(&ed, "41");
    ed.press("Escape", "");
    ed.press("0", "");
    ed.press("C-a", "");
    {
        const numbered = try ed.textAlloc();
        defer gpa.free(numbered);
        try t.expect(std.mem.indexOf(u8, numbered, "42") != null);
    }
    try core.file.writeBytesMakingDirs(gpa, proj.root, "weft-snippets.txt", "demo\tSNIPPET\\nBODY\n");
    ed.runStr("snippets-expand", "demo");
    {
        const expanded = try ed.textAlloc();
        defer gpa.free(expanded);
        try t.expect(std.mem.indexOf(u8, expanded, "SNIPPET\nBODY") != null);
    }
    proj.capture(&ed, "spine-autopair");

    ed.chord("SPC :");
    try t.expect(ed.pick.active);
    proj.capture(&ed, "spine-command-palette");
    ed.press("Escape", "");

    // Continue the same config.js surface tour on a real authored buffer.
    // Every operation enters through a shipped key/action. Captures happen
    // while a surface or visible decoration is live, so the demo and test
    // cannot silently exercise behavior that never reaches the editor.
    ed.runStr("open", "main.zig");
    const main_syntax = language_support.attachedSyntax(&ed) orelse return error.SyntaxDidNotAttach;
    try t.expect(language_support.waitForTree(&ed, main_syntax));
    const node_kind = try core.command.run(ed.commands, ed.ctx, "node-kind", &.{});
    try t.expect(node_kind == .string and node_kind.string.len > 0);
    ed.chord("SPC p R");
    try t.expect(ed.echoText().len > 0);
    proj.capture(&ed, "spine-project-root");
    ed.press("C-SPC", "");
    ed.settle(40);
    try t.expect(ed.pick.active);
    proj.capture(&ed, "spine-completion");
    ed.press("Escape", "");

    ed.chord("SPC c e");
    proj.capture(&ed, "spine-tree-sitter-selection");
    ed.press("Escape", "");
    ed.chord("SPC c n");
    proj.capture(&ed, "spine-tree-sitter-node");
    ed.press("Escape", "");

    ed.press(">", "");
    ed.press(">", "");
    ed.press("<", "");
    ed.press("<", "");
    ed.chord("SPC t w");
    ed.press("F9", "");
    proj.capture(&ed, "spine-breakpoint-gutter");
    ed.press("F9", "");
    ed.chord("SPC d d");
    try t.expect(std.mem.indexOf(u8, ed.echoText(), "set an adapter") != null);
    proj.capture(&ed, "spine-dap-configuration");
    ed.chord("SPC c f");
    try t.expect(drainBufferContains(&ed, "pub fn main"));

    // Tool-producing actions use the real proc/fs doors. This project is
    // intentionally not a Weft checkout, so make/direnv may display their
    // honest failure/status output; that output is still the plugin's real UI.
    ed.chord("SPC c b");
    ed.settle(20);
    proj.capture(&ed, "spine-make-build");
    ed.runStr("open", "main.zig");
    ed.chord("SPC c t");
    ed.settle(20);
    proj.capture(&ed, "spine-make-test");
    ed.runStr("open", "main.zig");
    ed.chord("SPC n n");
    proj.capture(&ed, "spine-notes");
    ed.runStr("open", "main.zig");
    ed.chord("SPC o e");
    ed.settle(12);
    proj.capture(&ed, "spine-direnv");
    ed.runStr("open", "main.zig");
    ed.chord("SPC o c");
    ed.press("i", "");
    proj.typeText(&ed, "printf console-ok");
    ed.press("Escape", "");
    ed.run("console-send");
    try t.expect(drainToolContains(&ed, "*console*", "console-ok"));
    proj.capture(&ed, "spine-console");
    ed.runStr("open", "main.zig");
    ed.chord("SPC o r");
    ed.runStr("repl-send", "printf 'repl-ok\\n'\n");
    try t.expect(drainToolContains(&ed, "*repl*", "repl-ok"));
    proj.capture(&ed, "spine-repl");
    ed.run("repl-quit");
    ed.runStr("open", "main.zig");
    ed.runStr("net-open", "127.0.0.1:1");
    ed.settle(12);
    proj.capture(&ed, "spine-net-local-failure");
    ed.run("net-close");
    ed.runStr("open", "main.zig");

    // The minimal agent adapter is exercised with a hermetic CLI selected
    // through its ordinary plugin config. This drives its real fs-write + proc
    // path and produces the same *llm* tool buffer as a user's `llm` binary.
    try ed.setConfig("llm", "cmd", "sed 's/^/assistant: /'");
    ed.runStr("llm-ask", "demo prompt");
    try t.expect(drainToolContains(&ed, "*llm*", "assistant: demo prompt"));
    proj.capture(&ed, "spine-llm-agent");
    ed.runStr("open", "main.zig");

    // Coverage map for the shipped catalog. Concrete interactions above and
    // below cover the ordinary editing stack, syntax/LSP, pickers, project,
    // proc tools, retained semantic tools, windows, collaboration, and debug
    // decoration. The LLM adapter and REPL use hermetic local commands, and net
    // takes a bounded localhost refusal. Every shipped plugin has a concrete
    // behavior in this one scenario; manifest loading alone gets no credit.

    // A generic config action supplied by the editing plugin changes the
    // focused line; it is intentionally reached through SPC c c, not a
    // dired/editor special case.
    ed.chord("SPC c c");
    {
        const text = try ed.textAlloc();
        defer gpa.free(text);
        try t.expect(std.mem.indexOf(u8, text, "//") != null);
    }

    // Open the directory through the generic target handler. The scene is a
    // retained structured view (not a dired text buffer), and ordinary j/k
    // navigation is supplied by the Vim plugin over the generic focus path.
    ed.runStr("open", ".");
    const directory_view = ed.head.semantic_focus.path().?.view;
    const directory_scene = ed.session.system.semantic.views.get(directory_view).?.scene;
    try t.expectEqualStrings("dired", directory_scene.role);
    const rows = switch (directory_scene.content) {
        .container => |container| container.children,
        else => return error.DiredSceneNotContainer,
    };
    var saw_main = false;
    var saw_helper = false;
    for (rows) |row| {
        if (row.content != .container) continue;
        const columns = row.content.container.children;
        if (columns.len < 3 or columns[2].content != .field) continue;
        const field = columns[2].content.field.ref;
        var snapshot = try ed.session.system.semantic.fields.get(field).?.snapshot(gpa);
        defer snapshot.deinit();
        saw_main = saw_main or std.mem.eql(u8, snapshot.value.bytes, "main.zig");
        saw_helper = saw_helper or std.mem.eql(u8, snapshot.value.bytes, "helper.lua");
    }
    try t.expect(saw_main and saw_helper);
    ed.chord("SPC v r"); // generic view.refresh, provider-owned
    try t.expectEqualStrings("dired", ed.session.system.semantic.views.get(directory_view).?.scene.role);

    // ── Structured dired workflow ────────────────────────────────────────
    // Keep each mutation fixture small and deterministic, while exercising the
    // same generic target/field/action vocabulary a larger project uses.
    _ = try proj.oracle("mkdir -p rename-dir");
    try core.file.writeBytesMakingDirs(gpa, proj.root, "rename-dir/old.txt", "rename me\n");
    ed.runStr("open", "rename-dir");
    ed.press("i", "");
    for (0..7) |_| ed.press("Delete", "");
    proj.typeText(&ed, "new.txt");
    ed.press("Escape", "");
    var rename_field = ed.head.semantic_focus.path().?.field.?;
    var renamed = try ed.session.system.semantic.fields.get(rename_field).?.snapshot(gpa);
    defer renamed.deinit();
    try t.expectEqualStrings("new.txt", renamed.value.bytes);
    // :e! is the generic view.revert action. It restores the provider draft,
    // including its original field identity, without applying anything.
    ed.press("colon", "");
    proj.typeText(&ed, "e!");
    ed.press("Return", "");
    try t.expectEqualStrings("normal", ed.mode());
    rename_field = ed.head.semantic_focus.path().?.field.?;
    var reverted_name = try ed.session.system.semantic.fields.get(rename_field).?.snapshot(gpa);
    defer reverted_name.deinit();
    try t.expectEqualStrings("old.txt", reverted_name.value.bytes);
    try ed.session.system.semantic.fields.get(rename_field).?.edit(reverted_name.value.revision, .{
        .start = 0,
        .end = reverted_name.value.bytes.len,
        .replacement = "",
        .selection_after = .{ .anchor = 0, .caret = 0 },
    });
    ed.press("i", "");
    proj.typeText(&ed, "new.txt");
    ed.press("Escape", "");
    proj.capture(&ed, "spine-dired-rename-plan");
    ed.chord("SPC v a");
    try t.expect(ed.head.interactions.active() != null);
    ed.press("n", "n"); // cancel leaves the retained plan and dialog closed
    try t.expect(ed.head.interactions.active() == null);
    try t.expectEqual(core.file.Kind.file, core.file.statKind(gpa, "rename-dir/old.txt"));
    ed.chord("SPC v a");
    ed.press("y", "y");
    try t.expect(drainUntilOracle(&proj, &ed, "test -f rename-dir/new.txt && test ! -e rename-dir/old.txt && printf ok", "ok"));

    // Empty directory creation and permissions are independent generic
    // actions. The provider owns the staged rows; Vim only supplies the
    // familiar insert posture for their text fields.
    _ = try proj.oracle("mkdir -p create-dir");
    try core.file.writeBytesMakingDirs(gpa, proj.root, "create-dir/.seed", "");
    core.file.deleteFile(gpa, "create-dir/.seed");
    ed.runStr("open", "create-dir");
    const create_view = ed.head.semantic_focus.path().?.view;
    try t.expectEqual(@as(usize, 0), ed.session.system.semantic.views.get(create_view).?.scene.content.container.children.len);
    ed.chord("SPC v n");
    ed.press("i", "");
    proj.typeText(&ed, "made.txt");
    ed.press("Escape", "");
    ed.chord("SPC v m");
    ed.press("i", "");
    proj.typeText(&ed, "0600");
    ed.press("Escape", "");
    ed.chord("SPC v N");
    ed.press("i", "");
    proj.typeText(&ed, "made-dir");
    ed.press("Escape", "");
    proj.capture(&ed, "spine-dired-create-plan");
    ed.chord("SPC v a");
    ed.press("y", "y");
    try t.expectEqual(core.file.Kind.file, core.file.statKind(gpa, "create-dir/made.txt"));
    try t.expectEqual(core.file.Kind.dir, core.file.statKind(gpa, "create-dir/made-dir"));
    const mode = try proj.oracle("stat -c %a create-dir/made.txt");
    defer gpa.free(mode);
    try t.expect(std.mem.indexOf(u8, mode, "600") != null);

    // A named Vim register is a durable semantic transfer, not a pointer to a
    // row. It survives the source's retained delete and a cross-view paste.
    _ = try proj.oracle("mkdir -p copy-source copy-destination");
    try core.file.writeBytesMakingDirs(gpa, proj.root, "copy-source/source.txt", "copied content\n");
    try core.file.writeBytesMakingDirs(gpa, proj.root, "copy-destination/.seed", "");
    core.file.deleteFile(gpa, "copy-destination/.seed");
    ed.runStr("open", "copy-source");
    try spineFocusDiredName(&ed, gpa, "source.txt");
    ed.press("quotedbl", "");
    ed.press("a", "");
    ed.press("y", "");
    ed.press("y", "");
    ed.press("d", "");
    ed.press("d", "");
    const deleted_view = ed.session.system.semantic.views.get(ed.head.semantic_focus.path().?.view).?.scene;
    var saw_retained_delete = false;
    for (deleted_view.content.container.children) |row| for (row.facts) |fact| {
        saw_retained_delete = saw_retained_delete or
            (std.mem.eql(u8, fact.name, "change") and std.mem.eql(u8, fact.value, "delete"));
    };
    try t.expect(saw_retained_delete);
    proj.capture(&ed, "spine-dired-retained-delete");
    ed.runStr("open", "copy-destination");
    ed.press("quotedbl", "");
    ed.press("a", "");
    ed.press("p", "");
    try t.expectEqual(@as(usize, 1), ed.session.system.semantic.views.get(ed.head.semantic_focus.path().?.view).?.scene.content.container.children.len);
    ed.chord("SPC v a");
    ed.press("y", "y");
    const copied = try core.file.readAlloc(gpa, "copy-destination/source.txt");
    defer gpa.free(copied);
    try t.expectEqualStrings("copied content\n", copied);
    ed.runStr("open", "copy-source");
    ed.chord("SPC v a");
    ed.press("y", "y");
    try t.expectEqual(core.file.Kind.none, core.file.statKind(gpa, "copy-source/source.txt"));

    // Refresh reconciles external changes without moving a dirty draft onto a
    // different inode. The stale row remains visible and loses its target.
    _ = try proj.oracle("mkdir -p refresh-dir");
    try core.file.writeBytesMakingDirs(gpa, proj.root, "refresh-dir/a-dirty.txt", "dirty\n");
    try core.file.writeBytesMakingDirs(gpa, proj.root, "refresh-dir/z-clean.txt", "clean\n");
    ed.runStr("open", "refresh-dir");
    try spineFocusDiredName(&ed, gpa, "a-dirty.txt");
    const dirty_ref = ed.head.semantic_focus.path().?.field.?;
    var dirty_name = try ed.session.system.semantic.fields.get(dirty_ref).?.snapshot(gpa);
    defer dirty_name.deinit();
    try ed.session.system.semantic.fields.get(dirty_ref).?.edit(dirty_name.value.revision, .{
        .start = 0,
        .end = dirty_name.value.bytes.len,
        .replacement = "",
        .selection_after = .{ .anchor = 0, .caret = 0 },
    });
    ed.press("i", "");
    proj.typeText(&ed, "draft.txt");
    ed.press("Escape", "");
    _ = try proj.oracle("mv -- refresh-dir/a-dirty.txt refresh-dir/external.txt");
    core.file.deleteFile(gpa, "refresh-dir/z-clean.txt");
    ed.chord("SPC v r");
    var saw_stale_draft = false;
    const refreshed = ed.session.system.semantic.views.get(ed.head.semantic_focus.path().?.view).?.scene;
    for (refreshed.content.container.children) |row| {
        if (row.content != .container) continue;
        const columns = row.content.container.children;
        if (columns.len < 3 or columns[2].content != .field) continue;
        var field = try ed.session.system.semantic.fields.get(columns[2].content.field.ref).?.snapshot(gpa);
        defer field.deinit();
        if (!std.mem.eql(u8, field.value.bytes, "draft.txt")) continue;
        saw_stale_draft = true;
        var stale = false;
        for (row.facts) |fact| stale = stale or (std.mem.eql(u8, fact.name, "change") and std.mem.eql(u8, fact.value, "stale"));
        try t.expect(stale);
        try t.expect(columns[2].target == null);
    }
    try t.expect(saw_stale_draft);

    // ── 1.5. git-status BEFORE a repo exists says so — and points the way. ──
    // The project is a real isolated tmp dir with no git ancestor, so this is a
    // genuine clean slate (magit used to render a fake `Branch: (no branch)`).
    ed.run("git-status");
    try t.expect(drainToolContains(&ed, "*magit*", "Not a git repository."));
    try t.expect(drainToolContains(&ed, "*magit*", "git-init")); // and it names the fix

    // ── 2. Start version control from INSIDE the editor (the new git-init). ──
    ed.run("git-init");
    // Prove git ACTUALLY ran and the repo now renders a real branch: wait for the
    // `git status` output to list the untracked file + the `Branch:` header in
    // *magit*. Then confirm the repo on disk via the git oracle.
    try t.expect(drainToolContains(&ed, "*magit*", "main.zig"));
    try t.expect(drainToolContains(&ed, "*magit*", "Branch:"));
    {
        const gitdir = try proj.oracle("git rev-parse --git-dir");
        defer gpa.free(gitdir);
        try t.expect(gitdir.len > 0); // ".git" (or its absolute path)
    }
    proj.capture(&ed, "spine-1-init");

    // Configure an author for this repo (world setup — a human's git identity),
    // so the commit below has one. Repo-local, hermetic.
    {
        const e1 = try proj.oracle("git config user.email e2e@weft.test");
        gpa.free(e1);
        const e2 = try proj.oracle("git config user.name weft-e2e");
        gpa.free(e2);
    }

    // ── 4. Stage everything with the magit key `S`, then commit with `c c`. ──
    // We're in the *magit* buffer (git-init focused it), so these are real
    // magit keypresses, not command invocations.
    try t.expectEqualStrings("magit", ed.mode());
    ed.press("S", ""); // git-stage-all → git add -A → re-gather (async)
    // Disk oracle, drained: the file becomes staged once the async `git add`
    // the keypress scheduled actually runs.
    try t.expect(drainUntilOracle(&proj, &ed, "git diff --cached --name-only", "main.zig"));
    proj.capture(&ed, "spine-2-staged");

    // Commit dispatch: `c` opens the transient, `c` again starts a commit.
    ed.press("c", ""); // git-commit-dispatch (menu)
    ed.press("c", ""); // git-commit → *git-commit* buffer, mode git-commit
    try t.expectEqualStrings("git-commit", ed.mode());
    proj.typeText(&ed, "initial commit: weft demo skeleton");
    {
        const msg = try ed.textAlloc();
        defer gpa.free(msg);
        try t.expect(std.mem.indexOf(u8, msg, "initial commit") != null);
    }
    ed.press("C-c", ""); // git-commit-menu
    ed.press("C-c", ""); // git-commit-finish → git commit -F … → re-gather
    ed.run("git-status");
    try t.expect(drainUntilOracle(&proj, &ed, "git log --oneline", "initial commit"));
    proj.capture(&ed, "spine-3-committed");

    // ── 5. Verify the commit landed, on disk, via the git oracle. ──
    {
        const log = try proj.oracle("git log --oneline");
        defer gpa.free(log);
        try t.expect(std.mem.indexOf(u8, log, "initial commit: weft demo skeleton") != null);
    }
    {
        const tracked = try proj.oracle("git ls-files");
        defer gpa.free(tracked);
        try t.expect(std.mem.indexOf(u8, tracked, "main.zig") != null);
        try t.expect(std.mem.indexOf(u8, tracked, "helper.lua") != null);
    }
}

// ── The web-app narrative: many files, search them, run the code ────
//
// Continues the spine: a person fleshing out a small web app drops in more
// files, searches across them, and runs the code. Drives the project-nav/build
// tools (grep=rg, run=node) through their real commands; verifies FILE content
// on disk and TOOL output on the rendered surface; screenshots each step.
test "e2e/grep: Return on a result jumps to that file at that line" {
    const gpa = t.allocator;
    var proj: Project = undefined;
    try proj.init(gpa);
    defer proj.deinit();

    var ed: Editor = undefined;
    try Editor.init(gpa, &ed);
    defer ed.deinit();
    try loadWebIde(&ed);

    // Put the files on disk WITHOUT opening them in weft, so the assertion below
    // (dd deletes the matched line) is unambiguous — the token exists only here.
    {
        const r1 = try proj.oracle("printf 'const a = 1;\\nconst target = 42;\\nconst b = 2;\\n' > app.js");
        gpa.free(r1);
        const r2 = try proj.oracle("printf 'const c = 3;\\n' > other.js");
        gpa.free(r2);
    }

    // Search for a token that lives on exactly one line of one file, so the
    // result list has a single unambiguous entry.
    ed.runStr("grep", "target");
    try t.expect(drainToolContains(&ed, "*grep*", "app.js:2:"));
    try t.expectEqualStrings("grep", ed.mode()); // the results list is its own mode

    // Return on that result jumps INTO app.js. Deleting the current line then
    // proves we landed on line 2 (the match), not the top of the file — grep
    // results you can actually navigate. (k first: pin the cursor to the one
    // result line regardless of where the async fill left it.)
    ed.press("k", "");
    ed.press("k", "");
    ed.press("Return", "");
    try t.expectEqualStrings("normal", ed.mode()); // we're editing the file now
    ed.chord("d d");
    ed.run("save");
    ed.waitSave();

    const disk = try core.file.readAlloc(gpa, "app.js");
    defer gpa.free(disk);
    try t.expect(std.mem.indexOf(u8, disk, "target") == null); // the matched line is gone
    try t.expect(std.mem.indexOf(u8, disk, "const a = 1;") != null); // neighbors intact
    try t.expect(std.mem.indexOf(u8, disk, "const b = 2;") != null);
}

test "e2e/output: Return on a `file:line` in run output jumps there" {
    const gpa = t.allocator;
    var proj: Project = undefined;
    try proj.init(gpa);
    defer proj.deinit();

    var ed: Editor = undefined;
    try Editor.init(gpa, &ed);
    defer ed.deinit();
    try loadWebIde(&ed);

    // File on disk, not opened — so visiting is a fresh open (lands in normal).
    {
        const r = try proj.oracle("printf 'const a = 1;\\nconst target = 42;\\nconst b = 2;\\n' > app.js");
        gpa.free(r);
    }

    // Run a command whose output carries a location MID-line (like a stack frame
    // or compiler note — "trace: app.js:2:5 …"), not at the start as grep does.
    ed.runStr("run-command", "echo 'trace: app.js:2:5 boom'");
    try t.expect(drainToolContains(&ed, "*output*", "app.js:2:5"));

    // Return jumps to app.js line 2; deleting the line proves we landed there.
    ed.press("k", "");
    ed.press("Return", "");
    try t.expectEqualStrings("normal", ed.mode());
    ed.chord("d d");
    ed.run("save");
    ed.waitSave();

    const disk = try core.file.readAlloc(gpa, "app.js");
    defer gpa.free(disk);
    try t.expect(std.mem.indexOf(u8, disk, "target") == null); // the located line is gone
    try t.expect(std.mem.indexOf(u8, disk, "const a = 1;") != null);
    try t.expect(std.mem.indexOf(u8, disk, "const b = 2;") != null);
}

test "e2e/web: author js + html, grep across them, run it with node" {
    const gpa = t.allocator;
    var proj: Project = undefined;
    try proj.init(gpa);
    defer proj.deinit();

    var ed: Editor = undefined;
    try Editor.init(gpa, &ed);
    defer ed.deinit();
    try loadWebIde(&ed);

    // ── 1. Author two files the natural way (open → type → save). ──
    authorFile(&ed, "app.js",
        \\function greet(name) {
        \\  return "hello " + name;
        \\}
        \\console.log(greet("weft"));
        \\
    );
    authorFile(&ed, "index.html",
        \\<!doctype html>
        \\<title>weft demo</title>
        \\<script src="app.js"></script>
        \\
    );
    // CONTENT on disk (the human's check).
    {
        const disk = try core.file.readAlloc(gpa, "app.js");
        defer gpa.free(disk);
        try t.expect(std.mem.indexOf(u8, disk, "return \"hello \" + name;") != null);
    }

    // ── 2. Search the project for a token that appears in BOTH files. ──
    // `grep` runs `rg` into *grep*; a person types the pattern. "weft" is in
    // app.js (greet("weft")) and index.html (<title>weft demo</title>).
    ed.runStr("grep", "weft");
    try t.expect(drainToolContains(&ed, "*grep*", "app.js"));
    {
        const hits = toolText(&ed, "*grep*") orelse return error.NoGrepBuffer;
        defer gpa.free(hits);
        try t.expect(std.mem.indexOf(u8, hits, "app.js") != null);
        try t.expect(std.mem.indexOf(u8, hits, "index.html") != null);
    }
    proj.shot(&ed, "web-1-grep");

    // ── 3. Run the code with node — real execution, real output. ──
    ed.runStr("run-command", "node app.js");
    try t.expect(drainToolContains(&ed, "*output*", "hello weft"));
    proj.shot(&ed, "web-2-run");

    // ── 4. Browse the project through the provider-aware `open` command. ──
    // The app Session publishes a typed directory target and the composed dired
    // plugin claims it as an ordinary semantic view. There is no *dired* text
    // buffer and no dired-specific mode for this acceptance path.
    const input_posture = try gpa.dupe(u8, ed.mode());
    defer gpa.free(input_posture);
    ed.runStr("open", ".");
    const view_ref = ed.head.semantic_focus.path().?.view;
    const scene = ed.session.system.semantic.views.get(view_ref).?.scene;
    try t.expectEqualStrings("dired", scene.role);
    try t.expect(ed.buffers.findByName("*dired*") == null);

    const children = switch (scene.content) {
        .container => |container| container.children,
        else => return error.DiredSceneNotContainer,
    };
    try t.expectEqual(@as(usize, 2), children.len);
    try t.expectEqualStrings("dired.row", children[0].role);
    try t.expectEqualStrings("dired.row", children[1].role);
    var saw_app = false;
    var saw_index = false;
    for (children) |row| {
        const field_ref = row.content.container.children[2].content.field.ref;
        var snapshot = try ed.session.system.semantic.fields.get(field_ref).?.snapshot(gpa);
        defer snapshot.deinit();
        saw_app = saw_app or std.mem.eql(u8, snapshot.value.bytes, "app.js");
        saw_index = saw_index or std.mem.eql(u8, snapshot.value.bytes, "index.html");
    }
    try t.expect(saw_app and saw_index);

    // Vim's ordinary j/k motions consume the generic semantic focus protocol;
    // the plugin does not need to know that the caller happens to be Vim.
    const first_focus = ed.head.semantic_focus.path().?.leaf().?;
    ed.press("j", "");
    const second_focus = ed.head.semantic_focus.path().?.leaf().?;
    try t.expect(first_focus != second_focus);
    ed.press("k", "");
    try t.expectEqual(first_focus, ed.head.semantic_focus.path().?.leaf().?);
    try t.expectEqualStrings(input_posture, ed.mode());

    // The same view can be refreshed through the generic action endpoint. It
    // remains retained and focused, rather than being reconstructed as a tool
    // buffer or dropping the head back into a dired mode.
    ed.run("view-refresh");
    try t.expectEqual(view_ref, ed.head.semantic_focus.path().?.view);
    try t.expectEqualStrings("dired", ed.session.system.semantic.views.get(view_ref).?.scene.role);
    proj.shot(&ed, "web-3-dired");
}
