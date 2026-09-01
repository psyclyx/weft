//! Phase-8 exemplar acceptance gates for the git rework (doc/
//! contextual-workspace-architecture.md §14.3, §2.4, §18, §19). These drive
//! the real plugin through real keys/commands against real on-disk repos,
//! the same way the git spine in project_test.zig does.
//!
//! Each gate drives the capability the rework was for: per-repository session
//! isolation (G1), identity-not-byte-range targeting (G2), no locked tool
//! modes (G3), and the commit draft as an ordinary entry whose save commits
//! and whose close asks (G4).

const std = @import("std");
const t = std.testing;
const h = @import("harness.zig");

const Editor = h.Editor;
const Project = h.Project;
const loadWorkspace = h.loadWorkspace;
const drainToolContains = h.drainToolContains;
const drainUntilOracle = h.drainUntilOracle;
const chdirTo = h.chdirTo;

// ── GATE G1: two repositories opened side by side stay isolated ──
//
// doc §14.3/§18: "Two repositories ... remain isolated" — status, staging,
// and commits in one repo's git view must never touch the other's, and both
// views must be reachable AT THE SAME TIME (not one singleton buffer that
// forgets repo A the moment repo B is opened).
test "e2e/git-gates: G1 two repos stay isolated and both stay open" {
    const gpa = t.allocator;
    var proj: Project = undefined;
    try proj.init(gpa);
    defer proj.deinit();

    var ed: Editor = undefined;
    try Editor.init(gpa, &ed);
    defer ed.deinit();
    try loadWorkspace(&ed);

    // Two independent fixture repos, each with its own tracked file — real
    // git, via the oracle (a human's own usage), never the plugin.
    for ([_][]const u8{
        "mkdir -p repo-a repo-b",
        "cd repo-a && git init -q -b main && git config user.email e2e@weft.test && git config user.name weft-e2e",
        "cd repo-a && printf 'alpha\\n' > a.txt && git add a.txt && git commit -q -m a1",
        "cd repo-b && git init -q -b main && git config user.email e2e@weft.test && git config user.name weft-e2e",
        "cd repo-b && printf 'beta\\n' > b.txt && git add b.txt && git commit -q -m b1",
    }) |cmd| {
        const out = try proj.oracle(cmd);
        gpa.free(out);
    }

    // Open repo A's git view (the plugin shells out against the process cwd).
    const root_a = try proj.path("repo-a");
    defer gpa.free(root_a);
    try chdirTo(root_a);
    ed.run("git-status");
    try t.expect(drainToolContains(&ed, "*git*", "Branch:"));

    // Change something in repo A only.
    {
        const out = try proj.oracle("cd repo-a && printf 'alpha2\\n' >> a.txt");
        gpa.free(out);
    }
    ed.press("g", ""); // git-refresh
    try t.expect(drainToolContains(&ed, "*git*", "a.txt"));

    // Open repo B's git view WITHOUT losing repo A's — the gate itself. A
    // repository is a SESSION with its own instanced buffer, so repo B lands
    // in `*git:2*` and repo A's projection is still there, untouched.
    const root_b = try proj.path("repo-b");
    defer gpa.free(root_b);
    try chdirTo(root_b);
    ed.run("git-status");
    try t.expect(drainToolContains(&ed, "*git:2*", "Branch:"));
    try t.expect(ed.buffers.findByName("*git*") != null);
    {
        const first = h.toolText(&ed, "*git*") orelse return error.NoFirstGitBuffer;
        defer gpa.free(first);
        try t.expect(std.mem.indexOf(u8, first, "a.txt") != null); // repo A's own
        try t.expect(std.mem.indexOf(u8, first, "b.txt") == null);
    }

    // Staging in repo B must never touch repo A on disk.
    {
        const out = try proj.oracle("cd repo-b && printf 'beta2\\n' >> b.txt");
        gpa.free(out);
    }
    ed.press("g", "");
    try t.expect(drainToolContains(&ed, "*git:2*", "b.txt"));
    ed.press("S", ""); // git-stage-all in repo B
    try t.expect(drainUntilOracle(&proj, &ed, "cd repo-b && git diff --cached --name-only", "b.txt"));
    const staged_a = try proj.oracle("cd repo-a && git diff --cached --name-only");
    defer gpa.free(staged_a);
    try t.expectEqualStrings("", staged_a);
}

// ── GATE G1b: the number of repositories is not a number anyone chose ──
//
// G1 proves two repositories stay isolated. The table they lived in held FOUR,
// and a fifth was refused out loud with "too many repositories open" — a
// sentence describing a fixed array, not a decision. Sessions are individually
// allocated now, so this drives seven at once and asserts both halves of what
// the pointer-list shape is FOR:
//
//   • past the old ceiling nothing is refused — all seven projections are live
//     and each shows only its own repository, and
//   • an identity handed out before the table grew still names the same session
//     afterwards. The commit draft is that identity: it binds its repository
//     when it opens, and here it opens against repository 1 and is saved only
//     after six more sessions have been allocated behind it.
test "e2e/git-gates: G1b seven repos are all live, and a draft opened against the first still commits to it" {
    const gpa = t.allocator;
    var proj: Project = undefined;
    try proj.init(gpa);
    defer proj.deinit();

    var ed: Editor = undefined;
    try Editor.init(gpa, &ed);
    defer ed.deinit();
    try loadWorkspace(&ed);

    // Seven repositories, each with a tracked file only IT has, and each with a
    // staged change waiting so its projection has something of its own to show.
    const repos = 7;
    for (1..repos + 1) |n| {
        var cmd: [320]u8 = undefined;
        const out = try proj.oracle(try std.fmt.bufPrint(
            &cmd,
            "mkdir -p r{d} && cd r{d} && git init -q -b main" ++
                " && git config user.email e2e@weft.test && git config user.name weft-e2e" ++
                " && printf 'base\\n' > f{d}.txt && git add f{d}.txt && git commit -q -m base{d}" ++
                " && printf 'more\\n' >> f{d}.txt && git add f{d}.txt",
            .{ n, n, n, n, n, n, n },
        ));
        gpa.free(out);
    }

    // Repository 1 first, and a commit draft opened against it — the identity
    // that has to survive everything below.
    {
        const root = try proj.path("r1");
        defer gpa.free(root);
        try chdirTo(root);
    }
    ed.run("git-status");
    try t.expect(drainToolContains(&ed, "*git*", "f1.txt"));
    ed.run("git-commit");
    try t.expectEqualStrings("*git-commit*", ed.bufferName());
    ed.press("i", "");
    ed.typeText("G1b: committed to the first repository");
    ed.press("Escape", "");

    // Six more repositories. Each one grows the session table under the draft's
    // binding — the fifth is where the old cap refused outright.
    for (2..repos + 1) |n| {
        var leaf: [8]u8 = undefined;
        const root = try proj.path(try std.fmt.bufPrint(&leaf, "r{d}", .{n}));
        defer gpa.free(root);
        try chdirTo(root);
        ed.run("git-status");
        var name: [16]u8 = undefined;
        var needle: [16]u8 = undefined;
        try t.expect(drainToolContains(
            &ed,
            try std.fmt.bufPrint(&name, "*git:{d}*", .{n}),
            try std.fmt.bufPrint(&needle, "f{d}.txt", .{n}),
        ));
    }

    // ALL SEVEN ARE LIVE AND EACH IS ITSELF: every projection still holds its
    // own repository's file and no other's. A session that had been evicted,
    // reused, or moved would show up here as a projection describing the wrong
    // repository.
    for (1..repos + 1) |n| {
        var name_buf: [16]u8 = undefined;
        const name = if (n == 1) "*git*" else try std.fmt.bufPrint(&name_buf, "*git:{d}*", .{n});
        const text = h.toolText(&ed, name) orelse return error.MissingGitProjection;
        defer gpa.free(text);
        for (1..repos + 1) |other| {
            var needle: [16]u8 = undefined;
            const file = try std.fmt.bufPrint(&needle, "f{d}.txt", .{other});
            const present = std.mem.indexOf(u8, text, file) != null;
            try t.expectEqual(n == other, present);
        }
    }

    // THE DRAFT STILL NAMES REPOSITORY 1. Saving it is the commit, and it lands
    // in r1 — not in r7, which is where the process is standing and which every
    // "most recent session wins" shortcut would have picked.
    try h.focusBuffer(&ed, "*git-commit*");
    ed.press("colon", "");
    ed.typeText("w");
    ed.press("Return", "");
    try t.expect(drainUntilOracle(&proj, &ed, "cd r1 && git log --oneline", "G1b: committed to the first repository"));
    const seventh = try proj.oracle("cd r7 && git log --oneline");
    defer gpa.free(seventh);
    try t.expect(std.mem.indexOf(u8, seventh, "G1b") == null);
}

// ── GATE G2: a stale rendered hunk never gets staged after a render shift ──
//
// doc §2.4/§18: "No rendered row, byte range, or parsed display string serves
// as durable domain identity" and "Revision changes between resolution and
// invocation produce no mutation." Point is put on a real hunk, then a whole
// SECTION appears above it, so every rendered offset in the projection moves.
// After the refresh, staging must act on the hunk that was named — not on
// whatever now occupies the byte range it used to sit at.
test "e2e/git-gates: G2 stage-hunk after an external shift never stages the wrong lines" {
    const gpa = t.allocator;
    var proj: Project = undefined;
    try proj.init(gpa);
    defer proj.deinit();

    var ed: Editor = undefined;
    try Editor.init(gpa, &ed);
    defer ed.deinit();
    try loadWorkspace(&ed);

    for ([_][]const u8{
        "git init -q -b main",
        "git config user.email e2e@weft.test",
        "git config user.name weft-e2e",
        "seq 1 40 | sed 's/^/line/' > f.txt && git add f.txt && git commit -q -m base",
        // The one unstaged hunk: line30 -> THREE_CHANGED.
        "sed -i 's/^line30$/THREE_CHANGED/' f.txt",
    }) |cmd| {
        const out = try proj.oracle(cmd);
        gpa.free(out);
    }

    ed.run("git-status");
    try t.expect(drainToolContains(&ed, "*git*", "f.txt"));

    // Navigate point onto the hunk header (the first `@@` line) in the FIRST
    // rendering — before the shift, exactly how a person points at the change
    // they mean to stage.
    {
        const text = try ed.textAlloc();
        defer gpa.free(text);
        const at = std.mem.indexOf(u8, text, "@@") orelse return error.NoHunkRendered;
        const row = std.mem.count(u8, text[0..at], "\n");
        var i: usize = 0;
        while (i < row) : (i += 1) ed.press("j", "");
    }

    // An untracked file adds a whole SECTION above the change: every rendered
    // offset below it moves, while the hunk itself is untouched.
    {
        const out = try proj.oracle("printf 'scratch\\n' > zz_new.txt");
        gpa.free(out);
    }
    ed.press("g", ""); // git-refresh: re-gather without the user re-navigating
    try t.expect(drainToolContains(&ed, "*git*", "zz_new.txt"));

    // Stage what point names. The hunk is at a different byte range now, so a
    // stale-range implementation would build its patch from the wrong bytes.
    ed.press("s", "");
    try t.expect(drainLoopIdleOrDiff(&proj, &ed));

    const staged = try proj.oracle("git diff --cached");
    defer gpa.free(staged);
    try t.expect(std.mem.indexOf(u8, staged, "THREE_CHANGED") != null);
    // The untracked file was never part of the pointed-at change.
    try t.expect(std.mem.indexOf(u8, staged, "zz_new.txt") == null);
    try t.expect(std.mem.indexOf(u8, staged, "scratch") == null);
}

fn drainLoopIdleOrDiff(proj: *Project, ed: *Editor) bool {
    return h.drainLoopIdle(ed) or (proj.oracle("git diff --cached --name-only") catch return false).len > 0;
}

// ── GATE G3: no locked git modes ──
//
// doc §19: domain keymaps / locked tool modes are demolition targets for git
// specifically — the lock mechanism itself is gone (Keymap has no locked-mode
// concept any more), so this is now structurally impossible, not just untrue.
// The projections hold no editor, so typing refuses structurally and `git` is
// simply where they rest. Leaving a transient therefore lands back in git,
// not in a generic mode with dead keys — which is what the lock was standing
// in for.
test "e2e/git-gates: G3 no git mode is locked" {
    const gpa = t.allocator;
    var proj: Project = undefined;
    try proj.init(gpa);
    defer proj.deinit();

    var ed: Editor = undefined;
    try Editor.init(gpa, &ed);
    defer ed.deinit();
    try loadWorkspace(&ed);

    try t.expect(ed.keymap.isRestingMode("git"));
    try t.expect(ed.keymap.isRestingMode("git-view"));

    // A REAL status projection, because that is what makes `git` the resting
    // mode. Escape out of a menu asks the ENTRY where to land — no menu names
    // a mode to return to any more — so this gate only means anything with an
    // entry that has an answer.
    for ([_][]const u8{
        "git init -q -b main",
        "git config user.email e2e@weft.test",
        "git config user.name weft-e2e",
        "printf 'one\\n' > f.txt && git add f.txt && git commit -q -m base",
        "printf 'one\\ntwo\\n' > f.txt",
    }) |cmd| {
        const out = try proj.oracle(cmd);
        gpa.free(out);
    }
    ed.run("git-status");
    try t.expect(drainToolContains(&ed, "*git*", "Unstaged changes"));
    try t.expectEqualStrings("git", ed.mode());

    // Escape must never strand the projection in a dead mode: out of one of
    // git's plain action menus it comes back to git's keys…
    ed.press("b", ""); // the branch menu
    try t.expectEqualStrings("git-branch-menu", ed.mode());
    ed.press("Escape", "");
    try t.expectEqualStrings("git", ed.mode());

    // …and out of a flag TRANSIENT, whose mode, bindings and leave are all
    // generated, exactly the same way.
    ed.press("P", ""); // the push transient
    try t.expectEqualStrings("git-push-menu", ed.mode());
    ed.press("f", ""); // a toggle: sticky, so the menu stays open
    try t.expectEqualStrings("git-push-menu", ed.mode());
    ed.press("Escape", "");
    try t.expectEqualStrings("git", ed.mode());
}

// ── GATE G4: commit draft lifecycle as an ordinary entry ──
//
// doc §14.3: a commit message is a draft like any other — write it, switch
// away, come back, and it is still there and still EDITABLE with no resume
// step; saving it lands the real commit; closing it asks before throwing the
// text away (there is no file to recover it from).
test "e2e/git-gates: G4 commit draft survives a buffer switch, commits on save, and asks before it is dropped" {
    const gpa = t.allocator;
    var proj: Project = undefined;
    try proj.init(gpa);
    defer proj.deinit();

    var ed: Editor = undefined;
    try Editor.init(gpa, &ed);
    defer ed.deinit();
    try loadWorkspace(&ed);

    for ([_][]const u8{
        "git init -q -b main",
        "git config user.email e2e@weft.test",
        "git config user.name weft-e2e",
        "printf 'x\\n' > f.txt && git add f.txt",
    }) |cmd| {
        const out = try proj.oracle(cmd);
        gpa.free(out);
    }

    ed.run("git-status");
    try t.expect(drainToolContains(&ed, "*git*", "Branch:"));
    ed.press("c", ""); // git-commit-dispatch
    ed.press("c", ""); // the commit offer → a draft ENTRY
    try t.expectEqualStrings("*git-commit*", ed.bufferName());
    // Git owns no mode for it: it rests in the configuration's own editing
    // modes, and text reaches it because it is ordinary text.
    try t.expectEqualStrings("normal", ed.mode());
    ed.press("i", "");
    ed.typeText("draft: gate g4");
    ed.press("Escape", "");

    // Switch away to an ordinary buffer and back — a draft is just an entry.
    ed.runStr("buffer-create", "*scratch-g4*");
    try h.focusBuffer(&ed, "*git-commit*");
    {
        const msg = try ed.textAlloc();
        defer gpa.free(msg);
        try t.expect(std.mem.indexOf(u8, msg, "draft: gate g4") != null);
    }
    // …and still editable, with no resume step: the same keys as any entry.
    try t.expectEqualStrings("normal", ed.mode());
    ed.press("A", "");
    ed.typeText("!");
    ed.press("Escape", "");

    // Saving IS the commit — the `save` action, reached the way any entry's is.
    ed.press("colon", "");
    ed.typeText("w");
    ed.press("Return", "");
    try t.expect(drainUntilOracle(&proj, &ed, "git log --oneline", "draft: gate g4!"));

    // Abort path, second commit: the draft's text must survive a close that
    // was not confirmed.
    {
        const out = try proj.oracle("printf 'y\\n' >> f.txt && git add f.txt");
        gpa.free(out);
    }
    ed.run("git-status");
    // `f.txt` is in the buffer from the FIRST status already, so the needle
    // proves nothing about this one: wait for the refresh's own subprocess to
    // land, or its arrival re-focuses the status buffer over the draft below.
    try t.expect(drainToolContains(&ed, "*git*", "f.txt"));
    try t.expect(h.drainLoopIdle(&ed));
    ed.run("git-commit");
    try t.expectEqualStrings("*git-commit*", ed.bufferName());
    ed.press("i", "");
    ed.typeText("throwaway draft");
    ed.press("Escape", "");

    // `close` is an ACTION, so the draft's own provider answers it: it asks.
    ed.run("close");
    try t.expect(ed.pick.active);
    try t.expectEqualStrings("*git-commit*", ed.bufferName());

    // Answering "no" keeps the draft, text and all.
    ed.press("Return", ""); // the safe answer leads
    ed.settle(2);
    try t.expect(ed.buffers.findByName("*git-commit*") != null);
    {
        const msg = try ed.textAlloc();
        defer gpa.free(msg);
        try t.expect(std.mem.indexOf(u8, msg, "throwaway draft") != null);
    }

    // Answering "yes" is what drops it.
    ed.run("close");
    try t.expect(ed.pick.active);
    ed.run("pick-next");
    ed.run("pick-accept");
    ed.settle(2);
    try t.expect(ed.buffers.findByName("*git-commit*") == null);
}
