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

    ed.runStr("open", zig_path);
    try t.expect(std.mem.indexOf(u8, ed.echoText(), "zig") != null);
    ed.runStr("open", js_path); // switching buffers re-fires on_activate
    try t.expect(std.mem.indexOf(u8, ed.echoText(), "javascript") != null);
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
    try Editor.init(gpa, &ed);
    defer ed.deinit();
    try loadWorkspace(&ed);

    // ── 1. Write the first file the way a person does: open, type, save. ──
    // (Mode starts `normal`; edit BEFORE entering any tool buffer, so no
    // tool-mode ever swallows the typing — see [[mode-leak-class]].)
    ed.runStr("open", "index.html");
    ed.press("i", "");
    ed.typeText("<!doctype html>\n<title>weft demo</title>\n");
    ed.press("Escape", "");
    ed.run("save");
    ed.waitSave();

    // CONTENT is verified on disk (the artifact a human checks), not via the
    // editor's model.
    {
        const disk = try core.file.readAlloc(gpa, "index.html");
        defer gpa.free(disk);
        try t.expect(std.mem.indexOf(u8, disk, "<title>weft demo</title>") != null);
    }

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
    try t.expect(drainToolContains(&ed, "*magit*", "index.html"));
    try t.expect(drainToolContains(&ed, "*magit*", "Branch:"));
    {
        const gitdir = try proj.oracle("git rev-parse --git-dir");
        defer gpa.free(gitdir);
        try t.expect(gitdir.len > 0); // ".git" (or its absolute path)
    }
    proj.shot(&ed, "spine-1-init");

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
    try t.expect(drainUntilOracle(&proj, &ed, "git diff --cached --name-only", "index.html"));
    proj.shot(&ed, "spine-2-staged");

    // Commit dispatch: `c` opens the transient, `c` again starts a commit.
    ed.press("c", ""); // git-commit-dispatch (menu)
    ed.press("c", ""); // git-commit → *git-commit* buffer, mode git-commit
    try t.expectEqualStrings("git-commit", ed.mode());
    ed.typeText("initial commit: weft demo skeleton");
    ed.press("C-c", ""); // git-commit-menu
    ed.press("C-c", ""); // git-commit-finish → git commit -F … → re-gather
    try t.expect(drainToolContains(&ed, "*magit*", "initial commit"));
    proj.shot(&ed, "spine-3-committed");

    // ── 5. Verify the commit landed, on disk, via the git oracle. ──
    {
        const log = try proj.oracle("git log --oneline");
        defer gpa.free(log);
        try t.expect(std.mem.indexOf(u8, log, "initial commit: weft demo skeleton") != null);
    }
    {
        const tracked = try proj.oracle("git ls-files");
        defer gpa.free(tracked);
        try t.expectEqualStrings("index.html", tracked);
    }
}

// ── The web-app narrative: many files, search them, run the code ────
//
// Continues the spine: a person fleshing out a small web app drops in more
// files, searches across them, and runs the code. Drives the project-nav/build
// tools (grep=rg, run=node) through their real commands; verifies FILE content
// on disk and TOOL output on the rendered surface; screenshots each step.
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

    // ── 4. Browse the project as a file tree with dired. ──
    ed.run("dired");
    try t.expect(drainToolContains(&ed, "*dired*", "app.js"));
    {
        const tree = toolText(&ed, "*dired*") orelse return error.NoDiredBuffer;
        defer gpa.free(tree);
        try t.expect(std.mem.indexOf(u8, tree, "app.js") != null);
        try t.expect(std.mem.indexOf(u8, tree, "index.html") != null);
    }
    try t.expectEqualStrings("dired", ed.mode());
    proj.shot(&ed, "web-3-dired");
}
