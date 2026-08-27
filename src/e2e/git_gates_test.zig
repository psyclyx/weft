//! Phase-8 exemplar acceptance gates for the git rework (doc/
//! contextual-workspace-architecture.md §14.3, §2.4, §18, §19). These drive
//! the real plugin through real keys/commands against real on-disk repos,
//! the same way the git spine in project_test.zig does.
//!
//! HONESTY NOTE: this gate suite is written against the git rework's target
//! shape, not today's shipped `src/guest/git.zig`. It REQUIRES four sibling
//! branches (identity rework, per-repo session isolation, offer-based
//! dispatch replacing locked modes, and the commit-draft-as-ordinary-entry
//! rework) that have not landed on this branch. Each gate below states,
//! at its failing assertion, exactly which sibling capability is missing.
//! Once those land, these gates should go green with no further edits here.

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

    // Open repo B's git view WITHOUT losing repo A's — the gate itself. Today
    // `*git*` is a hardcoded module-global singleton buffer name
    // (src/guest/git.zig `buf_name`), so opening repo B reuses/overwrites the
    // SAME buffer: there is no second, independently addressable git view.
    // The sibling rework (per-repo session isolation) must give repo B its
    // own instanced buffer (e.g. `*git<2>*`) so both stay open side by side.
    const root_b = try proj.path("repo-b");
    defer gpa.free(root_b);
    try chdirTo(root_b);
    ed.run("git-status");
    try t.expect(drainToolContains(&ed, "*git*", "Branch:"));

    // PENDING (needs per-repo session isolation): repo A's view must still
    // exist as its own buffer, distinct from the one now showing repo B.
    try t.expect(ed.buffers.findByName("*git<2>*") != null);

    // Staging in repo B must never touch repo A on disk, regardless of the
    // buffer-identity gap above — this half of the gate already holds today.
    ed.press("S", ""); // git-stage-all in repo B
    try t.expect(drainUntilOracle(&proj, &ed, "cd repo-b && git diff --cached --name-only", "b.txt"));
    const staged_a = try proj.oracle("cd repo-a && git diff --cached --name-only");
    defer gpa.free(staged_a);
    try t.expectEqualStrings("", staged_a);
}

// ── GATE G2: a stale rendered hunk never gets staged after an external
// change ──
//
// doc §2.4/§18: "No rendered row, byte range, or parsed display string
// serves as durable domain identity" and "Revision changes between
// resolution and invocation produce no mutation." `src/guest/git.zig` today
// tracks hunks by rendered byte range (`r_start`/`r_end`) with a heuristic
// `captureIdentity`/`findIdentityOffset` restore — exactly the receipt kind
// §2.4 calls disease. This drives point onto a real hunk, shifts the file
// out from under it, refreshes, and stages — the result must be the
// re-resolved hunk (or a visible refusal), never whatever now sits at the
// stale byte range.
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
        "printf 'one\\ntwo\\nTHREE\\nfour\\nfive\\n' > f.txt && git add f.txt && git commit -q -m base",
        // The one unstaged hunk: THREE -> THREE_CHANGED.
        "sed -i 's/THREE/THREE_CHANGED/' f.txt",
    }) |cmd| {
        const out = try proj.oracle(cmd);
        gpa.free(out);
    }

    ed.run("git-status");
    try t.expect(drainToolContains(&ed, "*git*", "f.txt"));

    // Navigate point onto the hunk header (the first `@@` line) in the FIRST
    // rendering — before the external shift, exactly how a person points at
    // the change they mean to stage.
    {
        const text = try ed.textAlloc();
        defer gpa.free(text);
        const at = std.mem.indexOf(u8, text, "@@") orelse return error.NoHunkRendered;
        const row = std.mem.count(u8, text[0..at], "\n");
        var i: usize = 0;
        while (i < row) : (i += 1) ed.press("j", "");
    }

    // External change, entirely unrelated to the hunk's own content, shifts
    // every line number below it — the classic stale-identity trigger.
    {
        const out = try proj.oracle("sed -i '1i ZERO' f.txt");
        gpa.free(out);
    }
    ed.press("g", ""); // git-refresh: re-gather without the user re-navigating

    // Stage whatever the refreshed view now has point on. The only hunk that
    // may ever land staged is the THREE -> THREE_CHANGED one — never a hunk
    // built from stale byte offsets into the pre-shift rendering.
    ed.press("s", "");
    try t.expect(drainLoopIdleOrDiff(&proj, &ed));

    const staged = try proj.oracle("git diff --cached");
    defer gpa.free(staged);
    try t.expect(std.mem.indexOf(u8, staged, "THREE_CHANGED") != null);
    // The ZERO line was never part of the pointed-at hunk — a stale-range
    // restage would otherwise happily include it.
    try t.expect(std.mem.indexOf(u8, staged, "+ZERO") == null);
}

fn drainLoopIdleOrDiff(proj: *Project, ed: *Editor) bool {
    return h.drainLoopIdle(ed) or (proj.oracle("git diff --cached --name-only") catch return false).len > 0;
}

// ── GATE G3: no locked git modes ──
//
// doc §19: domain keymaps / locked tool modes are demolition targets for
// git specifically. `src/guest/git.zig` still calls `weft.lockedMode` for
// both "git" and "git-view" (task-only escape hatch, per §19's replacement:
// offers + structural refusal, not a keymap prison). This is a pure
// structural check, no repo needed — `isLockedMode` is the seam.
test "e2e/git-gates: G3 no git mode is locked" {
    const gpa = t.allocator;
    var ed: Editor = undefined;
    try Editor.init(gpa, &ed);
    defer ed.deinit();
    try loadWorkspace(&ed);

    // PENDING (needs the offer-based-dispatch rework): both calls must be
    // gone from src/guest/git.zig.
    try t.expect(!ed.keymap.isLockedMode("git"));
    try t.expect(!ed.keymap.isLockedMode("git-view"));

    // Escape must never strand the buffer in a dead mode: from "git" it
    // returns to ordinary navigation, not nowhere.
    ed.setMode("git");
    ed.press("Escape", "");
    try t.expect(!std.mem.eql(u8, ed.mode(), "git"));
}

// ── GATE G4: commit draft lifecycle as an ordinary entry ──
//
// doc §14.3: a commit message is a draft like any other — write it, switch
// away, come back, and it is still there; finishing lands the real commit;
// aborting CONFIRMS before it discards (no silent data loss). Today's
// `gitCommitAbort` (src/guest/git.zig) discards unconditionally on the
// first keypress — the confirm step is the sibling `uc/git-drafts` rework.
test "e2e/git-gates: G4 commit draft survives a buffer switch, finishes, and abort confirms" {
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
    ed.press("c", ""); // git-commit
    try t.expectEqualStrings("git-commit", ed.mode());
    ed.typeText("draft: gate g4");

    // Switch away to an ordinary buffer and back — a draft is just an entry:
    // its TEXT survives a generic buffer switch today (real, passes below).
    ed.runStr("buffer-create", "*scratch-g4*");
    try h.focusBuffer(&ed, "*git-commit*");
    {
        const msg = try ed.textAlloc();
        defer gpa.free(msg);
        try t.expect(std.mem.indexOf(u8, msg, "draft: gate g4") != null);
    }

    // PENDING (needs uc/git-drafts): resuming a draft must resume EDITING
    // it too. `Buffers.switchTo` deliberately remembers a buffer's own
    // RESTING mode on the way out (its own doc: "not the transient mode
    // itself"), so leaving `git-commit` stamps this buffer `default` — a
    // generic buffer switch today drops the commit posture, landing back
    // in `default` instead of `git-commit`. An ordinary-entry draft must
    // not need a special resume step to keep editing.
    try t.expectEqualStrings("git-commit", ed.mode());

    // Finish: the real commit lands with the drafted message. (Resuming
    // `git-commit` by hand here isolates THIS assertion from the pending
    // one above — the finish mechanics themselves are not what G4 is
    // about once resume is fixed.)
    ed.setMode("git-commit");
    ed.press("C-c", "");
    ed.press("C-c", "");
    try t.expect(drainUntilOracle(&proj, &ed, "git log --oneline", "draft: gate g4"));

    // Abort path, second commit: draft text must require confirmation before
    // it is thrown away.
    {
        const out = try proj.oracle("printf 'y\\n' >> f.txt && git add f.txt");
        gpa.free(out);
    }
    ed.run("git-status");
    ed.press("c", "");
    ed.press("c", "");
    try t.expectEqualStrings("git-commit", ed.mode());
    ed.typeText("throwaway draft");
    ed.press("C-c", "");
    ed.press("C-k", ""); // git-commit-abort

    // PENDING (needs uc/git-drafts): abort must ask before discarding —
    // today it discards immediately and lands straight back in "git".
    try t.expect(!std.mem.eql(u8, ed.mode(), "git"));
}
