//! git — git as a MODEL rendered into a foldable buffer (design §6.6), a
//! `.wasm` plugin. A `*git*` buffer is READ-ONLY and owned entirely by this
//! plugin: one combined `git status`/`git diff`/`git diff --cached`/`git log`
//! runs via `procToBuffer`, its raw output lands in the buffer that fill
//! captured, the host fires `on_fill_token`, and we PARSE that output into a
//! section→file→hunk tree then RE-RENDER the tree as pretty, foldable text over
//! the same buffer (`edit` + `styleClear`/`style` + `foldClear`/`fold`).
//!
//! The parallel node table (each node's rendered `[start,end)`) is DISPLAY and
//! only display: it hit-tests the cursor to a row. What a verb acts on is the
//! identity that row carries — a `Target` — resolved against the live model
//! when the verb fires (design §14.3): a commit is a durable OID, a file is a
//! revisioned name (section + path), a hunk and any line selection inside it
//! are scoped to the render `snapshot` they were named in. A verb whose target
//! the model no longer names refuses; it never falls back to whatever row a
//! stale offset now covers.
//!
//! REPOSITORY SESSIONS (design §14.3). The model is per REPOSITORY, not per
//! plugin: a `RepoSession` keyed by repository root owns the files/hunks/raw/
//! render/branch/fold/interaction state and its own instanced buffer (`*git*`,
//! `*git:2*`, …). `git-status` in a buffer whose repository differs opens THAT
//! repository's session; every other command routes to the session of the
//! focused git buffer, and a fill routes by the session its token carries. Two
//! repositories therefore list their own files and stage independently.
//!
//! SNAPSHOT IDENTITY (§14.3). Commit OIDs are durable, so log/show/cherry-pick
//! keep working across a re-gather. Working paths and hunks are SNAPSHOT-SCOPED:
//! each gathered status carries a snapshot ordinal, and the one command funnel
//! refuses a path/hunk action whose snapshot the model has moved past — a
//! visible `stale — refreshed` echo plus a re-render, never a mutation against
//! shifted hunks. Focus restoration still uses correlation hints; those are
//! presentation comfort and grant no authority.
//!
//! The verbs are published as OFFERS, not hidden behind a locked mode: git
//! pushes a `plugin.git.*` table (stage/unstage/open-diff/commit/refresh/
//! push/pull/fetch) scoped to the `*git*` entry's tool identity and stamped
//! with the model ordinal, so `s`/`u`/`RET` in this buffer resolve what THIS
//! row affords — with the reason when it affords nothing — and an offer
//! resolved against a model a mutation replaced dies at the effect door.
//!
//! Staging is pure plugin logic: file → `git add`/`git reset`; hunk → synthesize
//! a one-file/one-hunk patch (kept diff header + the `@@` hunk) and
//! `git apply --cached [--reverse]`; a selected line-range → a PARTIAL hunk
//! (git's line algorithm: drop unselected `+`, turn unselected `-` into
//! context) applied the same way. Every mutation chains a re-gather in ONE shell
//! command so the buffer reflects the new index (the old `stageThenRefresh`
//! discipline). Discard is destructive, so it ASKS — through the pick membrane,
//! like every other destructive verb here; git owns no confirmation mode.
//!
//! A COMMIT DRAFT is not part of that projection: it is an ordinary instanced
//! text entry (`*git-commit*`, `*git-commit:2*`, …) with no mode and no keys of
//! its own. It is tool-backed, so `save` in it resolves to `git-commit-save` —
//! saving the draft IS the commit, aborting it is closing the entry, and
//! amend/reword/fixup/squash are offers that re-seat the draft rather than
//! commands with their own buffers. Each draft records the repository it was
//! written for, so a second repository's draft is genuinely a second entry. A
//! REBASE PLAN is the same shape: an instanced entry saved to run its rebase
//! through git's own `GIT_SEQUENCE_EDITOR`.
//!
//! perms `{proc, timer}` — NO filesystem capability at all, which for the most
//! privileged plugin in the tree is the whole point of `doc/place.md` §4.2.
//! The three things git hands a subprocess on disk — a synthesized patch, a
//! draft's message, a rebase plan — go through `weft.procSpool`, which writes
//! them to a temp the HOST names and removes; git names no path it writes and
//! cleans up nothing. The two things it PROBES for — is this project a git
//! repository, is a rebase mid-flight — go through `weft.placeHas`, which
//! answers about the place this command already dispatches in and cannot
//! escape it. Neither reason for a grant survived the primitive that replaced
//! it. grant_max edit (it authors its own buffer).

const std = @import("std");
const weft = @import("weft");
const prompt = @import("weft_prompt");

// The plugin's own parts. A verb below composes them; none of them knows
// about a verb, so the model can be read without the commands and the
// projection without either.
const model = @import("model.zig");
const parser = @import("parse.zig");
const render_mod = @import("render.zig");
const patch_mod = @import("patch.zig");

const Section = model.Section;
const File = model.File;
const Hunk = model.Hunk;
const RepoSession = model.RepoSession;
const InputAction = model.InputAction;
const render_order = model.render_order;
const cur = model.cur;
const sessionById = model.sessionById;
const focusBuffer = model.focusBuffer;
const sessions = &model.sessions;
const Target = model.Target;
const Lines = model.Lines;
const RAW_CAP = model.RAW_CAP;
const findFile = render_mod.findFile;
const buildPatch = patch_mod.buildPatch;
const transient = @import("transient.zig");
const gather_mod = @import("gather.zig");
const show = gather_mod.show;
const gather = gather_mod.gather;
const after = gather_mod.after;
const afterInput = gather_mod.afterInput;
const afterNoted = gather_mod.afterNoted;
const Argv = gather_mod.Argv;
const selectedLines = render_mod.selectedLines;
const nodeAtCursor = render_mod.nodeAtCursor;
const nameFile = render_mod.nameFile;
const fileTarget = render_mod.fileTarget;
const countLines = render_mod.countLines;
const Kind = model.Kind;
const Node = model.Node;
const MARK_U = model.MARK_U;
const MARK_S = model.MARK_S;
const MARK_R = model.MARK_R;
const buf_base = model.buf_base;
const tool = model.tool;

var cmd_buf: [1 << 13]u8 = undefined;
var msg_buf: [1 << 16]u8 = undefined;

/// Buffer for building a rebase plan's todo lines + the transient op command.
var op_buf: [1 << 14]u8 = undefined;
/// The command handed to `procToBuffer`: the session's `cd` guard + the body.
/// Scratch for an absolute path inside the session's repository (`inRepo`).
var tmp_buf: [1024]u8 = undefined;
/// Scratch for the focused buffer's path made absolute (`activePathAbs`) —
/// `weft.path` and `weft.placeRoot` both borrow the shim's shared read
/// scratch, so the join needs a buffer neither of them owns.
var probe_buf: [1024]u8 = undefined;
/// Scratch for the dispatching place's directory (`placeDir`), copied off that
/// same shared scratch.
var base_buf: [1024]u8 = undefined;

// ── Commands ──────────────────────────────────────────────────────────────
/// Which session a command is about. `.repo` opens (or reuses) the session of
/// the REPOSITORY the focused buffer belongs to — the door into a second repo.
/// `.focus` follows the focused git buffer, so a key pressed in `*git:2*` can
/// only ever act on that repository — and from a companion buffer that names no
/// repository (`*git-commit*`, `*git-input*`, `*git-rebase*`) it stays with the
/// session that opened it. `.carried` keeps the session its caller already set:
/// the internal deferrals a background fill schedules.
const Route = enum { repo, focus, carried };

/// What the command's arguments are designated by (§14.3).
///   `.durable`  — nothing snapshot-scoped (commit OIDs, refs, whole-tree verbs).
///   `.snapshot` — a working path or hunk resolved from the CURRENT render.
///   `.arm`      — opens an interaction against the current snapshot. What the
///                 answer may then do is the target it captured (see `resolve`).
const Scope = enum { durable, snapshot, arm };

/// git's own metadata, one entry per command, PARALLEL to the manifest table:
/// the SDK's `Entry` holds the name and the call, this holds what the funnel
/// (`dispatch`, below) needs before it runs.
const Cmd = struct {
    name: []const u8,
    handler: *const fn () void,
    route: Route = .focus,
    scope: Scope = .durable,
};
const base_cmds = [_]Cmd{
    .{ .name = "git-status", .handler = gitStatus, .route = .repo },
    .{ .name = "git-init", .handler = gitInit, .route = .repo },
    .{ .name = "git-refresh", .handler = gitRefresh },
    .{ .name = "git-toggle-fold", .handler = gitToggleFold },
    // Row motion: core's cursor move, then republish — the offers describe
    // the row under point, so moving point is a new eligibility fact.
    .{ .name = "git-next-row", .handler = gitNextRow },
    .{ .name = "git-prev-row", .handler = gitPrevRow },
    .{ .name = "git-stage", .handler = gitStage, .scope = .snapshot },
    .{ .name = "git-unstage", .handler = gitUnstage, .scope = .snapshot },
    .{ .name = "git-stage-all", .handler = gitStageAll },
    .{ .name = "git-unstage-all", .handler = gitUnstageAll },
    .{ .name = "git-discard", .handler = gitDiscard, .scope = .arm },
    .{ .name = "git-visit", .handler = gitVisit },
    .{ .name = "git-commit", .handler = gitCommit },
    // Saving a draft entry IS its commit; the settle runs on the fill's way
    // back. A draft names its own repository (`currentDraft` routes to it), so
    // both stay `.carried` — never "whatever git buffer was focused".
    .{ .name = "git-commit-save", .handler = gitCommitSave, .route = .carried },
    .{ .name = "git-commit-settle", .handler = gitCommitSettle, .route = .carried },
    // Commit dispatch (the `c` transient): each opens a draft for the commit it
    // means; fixup/squash resolve the commit under point into its message.
    .{ .name = "git-amend", .handler = gitAmend },
    .{ .name = "git-extend", .handler = gitExtend },
    .{ .name = "git-reword", .handler = gitReword },
    .{ .name = "git-fixup", .handler = gitFixup },
    .{ .name = "git-squash", .handler = gitSquash },
    // The draft entry's own offers — they re-seat the draft under point.
    .{ .name = "git-draft-close", .handler = gitDraftClose, .route = .carried },
    .{ .name = "git-draft-amend", .handler = gitDraftAmend, .route = .carried },
    .{ .name = "git-draft-reword", .handler = gitDraftReword, .route = .carried },
    .{ .name = "git-draft-fixup", .handler = gitDraftFixup, .route = .carried },
    .{ .name = "git-draft-squash", .handler = gitDraftSquash, .route = .carried },
    // Commit-scoped verbs on a recent-commit node.
    .{ .name = "git-show", .handler = gitShow },
    .{ .name = "git-cherry-pick", .handler = gitCherryPick },
    .{ .name = "git-revert", .handler = gitRevert },
    .{ .name = "git-reset-soft", .handler = gitResetSoft },
    .{ .name = "git-reset-mixed", .handler = gitResetMixed },
    .{ .name = "git-reset-hard", .handler = gitResetHard },
    // Branch transient.
    .{ .name = "git-branch-checkout", .handler = gitBranchCheckout },
    .{ .name = "git-branch-create", .handler = gitBranchCreate },
    .{ .name = "git-branch-new", .handler = gitBranchNew },
    .{ .name = "git-branch-delete", .handler = gitBranchDelete },
    .{ .name = "git-branch-rename", .handler = gitBranchRename },
    // Stash transient.
    .{ .name = "git-stash-save", .handler = gitStashSave },
    .{ .name = "git-stash-pop", .handler = gitStashPop },
    .{ .name = "git-stash-apply", .handler = gitStashApply },
    .{ .name = "git-stash-list", .handler = gitStashList },
    .{ .name = "git-stash-drop", .handler = gitStashDrop },
    // Log transient.
    .{ .name = "git-log-all", .handler = gitLogAll },
    // Push/pull/fetch flag transients (toggle flags, then execute).
    .{ .name = "git-push", .handler = transient.gitPush },
    .{ .name = "git-pull", .handler = transient.gitPull },
    .{ .name = "git-fetch", .handler = transient.gitFetch },
    .{ .name = "git-push-toggle-force", .handler = transient.gitPushToggleForce },
    .{ .name = "git-push-toggle-upstream", .handler = transient.gitPushToggleUpstream },
    .{ .name = "git-push-do", .handler = transient.gitPushDo },
    .{ .name = "git-pull-toggle-rebase", .handler = transient.gitPullToggleRebase },
    .{ .name = "git-pull-do", .handler = transient.gitPullDo },
    .{ .name = "git-fetch-toggle-all", .handler = transient.gitFetchToggleAll },
    .{ .name = "git-fetch-toggle-prune", .handler = transient.gitFetchTogglePrune },
    .{ .name = "git-fetch-do", .handler = transient.gitFetchDo },
    // Interactive rebase: the plan is an entry; saving it runs the rebase.
    .{ .name = "git-rebase-interactive", .handler = gitRebaseInteractive },
    .{ .name = "git-rebase-continue", .handler = gitRebaseContinue },
    .{ .name = "git-rebase-abort", .handler = gitRebaseAbort },
    .{ .name = "git-rebase-skip", .handler = gitRebaseSkip },
    .{ .name = "git-rebase-save", .handler = gitRebaseSave, .route = .carried },
    .{ .name = "git-rebase-settle", .handler = gitRebaseSettle, .route = .carried },
    .{ .name = "git-menu-cancel", .handler = transient.gitMenuCancel },
    .{ .name = "git-menu-cancel-surface", .handler = transient.gitMenuCancelSurface },
    // Kept for the SPC-g leader menu: read-only views into their own buffers.
    .{ .name = "git-log", .handler = gitLog },
    .{ .name = "git-diff", .handler = gitDiff },
    .{ .name = "git-diff-staged", .handler = gitDiffStaged },
    .{ .name = "git-blame", .handler = gitBlame },
    // Internal: the deferred half of `noteDrops` (task #19 item 4) — not a
    // user-facing verb, invoked only via `weft.run` from `on_fill_token`.
    .{ .name = "git-note-drops-deliver", .handler = gitNoteDropsDeliver, .route = .carried },
};

/// The shared prompt's five editing commands (`input`, below), mapped into
/// git's `Cmd`. They route like any other git verb: the prompt is an
/// echo-line overlay, not a buffer, so the focused entry is still the `*git*`
/// the branch name is for — which is precisely what the old `*git-input*`
/// buffer had to work around by carrying the session in `input_action`.
const input_cmds: [input.commands.len]Cmd = blk: {
    var arr: [input.commands.len]Cmd = undefined;
    for (input.commands, 0..) |c, i| arr[i] = .{ .name = c.name, .handler = c.handler };
    break :blk arr;
};

const cmds = base_cmds ++ input_cmds;

/// The manifest's table, derived from `cmds` — same order, so `dispatch`'s
/// index reaches the same entry's route and scope.
const entries: [cmds.len]weft.CommandEntry = blk: {
    var arr: [cmds.len]weft.CommandEntry = undefined;
    for (cmds, 0..) |c, i| arr[i] = .{ .name = c.name, .call = c.handler };
    break :blk arr;
};

comptime {
    // `{proc, timer}` and nothing else — the set `direnv` and `spool` have.
    // Every file git hands a subprocess is spooled by the host
    // (`weft.procSpool`), and every path it used to PROBE is inside the place
    // it already dispatches in (`weft.placeHas`), so there is no filesystem
    // question left for a grant to answer. `wasm_abi/tests.zig` asserts the
    // absence of both fs capabilities, so a regrant is loud.
    weft.plugin(&entries, .{
        .perms = &.{ .proc, .timer },
        .init = initExtra,
        .before = dispatch,
    }).exportAll();
}

fn initExtra() void {
    // What a settled gather owes the rest of the plugin, and how a view is
    // coloured. Installed rather than called directly so `gather.zig` stays
    // readable without the rest of this file in your head.
    model.on_gathered = onGathered;
    model.on_view_filled = onViewFilled;
    // git mode: navigation plus the interactive verbs. It declares no text
    // commit, and the `*git*` entry holds no editor at all, so typing refuses
    // STRUCTURALLY — there is nothing for a mode lock to protect. It is the
    // buffer's RESTING mode instead: leaving a transient lands back here
    // rather than in a generic editing mode with dead keys.
    weft.restingMode("git");
    weft.bindKey("git", "j", "git-next-row"); // core's fold-aware move, then republish
    weft.bindKey("git", "k", "git-prev-row");
    weft.bindKey("git", "Down", "git-next-row");
    weft.bindKey("git", "Up", "git-prev-row");
    weft.bindKey("git", "Tab", "git-toggle-fold");
    // The row verbs resolve OFFERS (see publishOffers): the key names what
    // the user means, git's published table says whether this row affords it
    // and why not, and the effect door rechecks the model ordinal.
    weft.bindKeys("git", "s", &.{"plugin.git.stage"});
    weft.bindKeys("git", "u", &.{"plugin.git.unstage"});
    weft.bindKey("git", "S", "git-stage-all");
    weft.bindKey("git", "U", "git-unstage-all");
    // Discard is destructive; `x` (not git's `k`, which we spend on vim-style
    // up-motion) asks before anything is thrown away.
    // `x` dispatches by node kind (file/hunk → discard; commit → reset menu).
    weft.bindKey("git", "x", "git-discard");
    // `c` opens the commit dispatch transient (which-key renders it).
    weft.bindKey("git", "c", "git-commit-dispatch");
    weft.bindKey("git", "b", "git-branch-menu");
    weft.bindKey("git", "z", "git-stash-menu");
    weft.bindKey("git", "l", "git-log-menu");
    weft.bindKey("git", "r", "git-rebase-menu");
    // Cherry-pick / revert the commit under point (resolve the hash live).
    weft.bindKey("git", "A", "git-cherry-pick");
    weft.bindKey("git", "V", "git-revert");
    // Entry-level offers: about the repository this buffer projects, not
    // about the row under point.
    weft.bindKeys("git", "P", &.{"plugin.git.push"});
    weft.bindKeys("git", "F", &.{"plugin.git.pull"});
    weft.bindKeys("git", "f", &.{"plugin.git.fetch"});
    weft.bindKeys("git", "g", &.{"plugin.git.refresh"});
    // RET dispatches: file/hunk → visit; commit → show.
    weft.bindKeys("git", "Return", &.{"plugin.git.open-diff"});
    weft.bindKey("git", "q", "buffer-back");

    // Discard and the other destructive verbs ask through the pick membrane
    // (`confirmPick`), so git owns no confirmation modes at all.

    // A commit draft owns NO mode and NO keys: it is an ordinary text entry in
    // the configuration's own editing modes. Its tool identity is what makes it
    // a draft, and `save` in it resolves here instead of to a file write — so
    // `:w`, `SPC f s`, and the palette's `std.persistence.save` all commit it.
    weft.provide("save", .{ .tool = draft_tool }, "git-commit-save", 10);
    // A written draft has no file to recover it from, so closing it asks first
    // — the same `close` action the workspace's own keys resolve.
    weft.provide("close", .{ .tool = draft_tool }, "git-draft-close", 10);
    // What else a draft affords is PUBLISHED, like every other `plugin.git.*`
    // intention (see publishOffers) — one namespace, one plane.

    // Commit dispatch (`c`): a which-key transient. Each key is terminal, so the
    // core's one-shot menu auto-return lands back in git for free.
    weft.menuMode("git-commit-dispatch");
    weft.bindKeys("git-commit-dispatch", "c", &.{"plugin.git.commit"});
    weft.bindKey("git-commit-dispatch", "a", "git-amend");
    weft.bindKey("git-commit-dispatch", "e", "git-extend");
    weft.bindKey("git-commit-dispatch", "w", "git-reword");
    weft.bindKey("git-commit-dispatch", "f", "git-fixup");
    weft.bindKey("git-commit-dispatch", "s", "git-squash");
    weft.bindKey("git-commit-dispatch", "Escape", "git-menu-cancel");
    weft.bindKey("git-commit-dispatch", "C-g", "git-menu-cancel");

    // Reset transient (entered by `x` on a commit): soft/mixed, hard→confirm.
    weft.menuMode("git-reset-menu");
    weft.bindKey("git-reset-menu", "s", "git-reset-soft");
    weft.bindKey("git-reset-menu", "m", "git-reset-mixed");
    weft.bindKey("git-reset-menu", "h", "git-reset-hard");
    weft.bindKey("git-reset-menu", "Escape", "git-menu-cancel");
    weft.bindKey("git-reset-menu", "C-g", "git-menu-cancel");

    // Branch transient (`b`).
    weft.menuMode("git-branch-menu");
    weft.bindKey("git-branch-menu", "b", "git-branch-checkout");
    weft.bindKey("git-branch-menu", "c", "git-branch-create");
    weft.bindKey("git-branch-menu", "n", "git-branch-new");
    weft.bindKey("git-branch-menu", "d", "git-branch-delete");
    weft.bindKey("git-branch-menu", "r", "git-branch-rename");
    weft.bindKey("git-branch-menu", "Escape", "git-menu-cancel");
    weft.bindKey("git-branch-menu", "C-g", "git-menu-cancel");

    // Stash transient (`z`).
    weft.menuMode("git-stash-menu");
    weft.bindKey("git-stash-menu", "z", "git-stash-save");
    weft.bindKey("git-stash-menu", "p", "git-stash-pop");
    weft.bindKey("git-stash-menu", "a", "git-stash-apply");
    weft.bindKey("git-stash-menu", "l", "git-stash-list");
    weft.bindKey("git-stash-menu", "k", "git-stash-drop");
    weft.bindKey("git-stash-menu", "Escape", "git-menu-cancel");
    weft.bindKey("git-stash-menu", "C-g", "git-menu-cancel");

    // Log transient (`l`) — the inline Recent section covers most needs.
    weft.menuMode("git-log-menu");
    weft.bindKey("git-log-menu", "l", "git-log");
    weft.bindKey("git-log-menu", "a", "git-log-all");
    weft.bindKey("git-log-menu", "Escape", "git-menu-cancel");
    weft.bindKey("git-log-menu", "C-g", "git-menu-cancel");

    // Rebase transient (`r`): interactive + in-progress continue/abort/skip. The
    // right verb is chosen per state; the wrong one just no-ops with a git error.
    // STICKY (matching git-push/pull/fetch-menu's idiom): needed ONLY for `i`
    // when a rebase is mid-flight, which re-sets the SAME mode to keep the
    // menu open (dispatch.zig's leaf auto-pop otherwise treats "still the same
    // mode after the leaf" as "did nothing, pop it" — undoing the re-set).
    // c/a/s/`i`-when-clean all still close normally: each explicitly leaves via
    // `weft.setMode` to a DIFFERENT mode (git or git-input), which dispatch's
    // "leaf moved us elsewhere" branch honors regardless of stickiness — same
    // as git-push-menu's sticky toggles vs. its mode-changing `-do` leaf.
    weft.stickyMenu("git-rebase-menu");
    weft.bindKey("git-rebase-menu", "i", "git-rebase-interactive");
    weft.bindKey("git-rebase-menu", "c", "git-rebase-continue");
    weft.bindKey("git-rebase-menu", "a", "git-rebase-abort");
    weft.bindKey("git-rebase-menu", "s", "git-rebase-skip");
    weft.bindKey("git-rebase-menu", "Escape", "git-menu-cancel");
    weft.bindKey("git-rebase-menu", "C-g", "git-menu-cancel");

    // The single-line prompt (branch names, rebase depth): the shared
    // minibuffer's mode and keys, not a bespoke buffer with a C-c submenu.
    input.install();

    // Push/pull/fetch flag transients: STICKY menu modes. Sticky means a leaf key
    // does NOT one-shot auto-pop — the transient stays open while flags
    // accumulate (a toggle re-renders and we're still in the mode); only the
    // execute key (p/RET, which re-gathers into git) or Escape/q leaves. Being
    // menu modes, which-key lists the keys, AND our own surface paints the live
    // flag state (see renderPushSurface & co.).
    weft.stickyMenu("git-push-menu");
    weft.bindKey("git-push-menu", "f", "git-push-toggle-force");
    weft.bindKey("git-push-menu", "u", "git-push-toggle-upstream");
    weft.bindKey("git-push-menu", "p", "git-push-do");
    weft.bindKey("git-push-menu", "Return", "git-push-do");
    weft.bindKey("git-push-menu", "Escape", "git-menu-cancel-surface");
    weft.bindKey("git-push-menu", "C-g", "git-menu-cancel-surface");
    weft.bindKey("git-push-menu", "q", "git-menu-cancel-surface");

    weft.stickyMenu("git-pull-menu");
    weft.bindKey("git-pull-menu", "r", "git-pull-toggle-rebase");
    weft.bindKey("git-pull-menu", "p", "git-pull-do");
    weft.bindKey("git-pull-menu", "Return", "git-pull-do");
    weft.bindKey("git-pull-menu", "Escape", "git-menu-cancel-surface");
    weft.bindKey("git-pull-menu", "C-g", "git-menu-cancel-surface");
    weft.bindKey("git-pull-menu", "q", "git-menu-cancel-surface");

    weft.stickyMenu("git-fetch-menu");
    weft.bindKey("git-fetch-menu", "a", "git-fetch-toggle-all");
    weft.bindKey("git-fetch-menu", "p", "git-fetch-toggle-prune");
    weft.bindKey("git-fetch-menu", "f", "git-fetch-do");
    weft.bindKey("git-fetch-menu", "Return", "git-fetch-do");
    weft.bindKey("git-fetch-menu", "Escape", "git-menu-cancel-surface");
    weft.bindKey("git-fetch-menu", "C-g", "git-menu-cancel-surface");
    weft.bindKey("git-fetch-menu", "q", "git-menu-cancel-surface");

    // A rebase plan is a list of verbs in an ordinary text entry: it is edited
    // by typing, like the todo `git rebase -i` would have opened, and saving it
    // hands it to git through the same sequence editor.
    weft.provide("save", .{ .tool = todo_tool }, "git-rebase-save", 10);
    weft.provide("close", .{ .tool = todo_tool }, "git-draft-close", 10);

    // A shared read-only view mode for the show/log/stash buffers (own their own
    // buffers, so git's mutating keys never fire against a stale model). Like
    // `git`, these entries hold no editor — nothing to lock, so it is simply
    // the mode those buffers rest in.
    weft.restingMode("git-view");
    weft.bindKey("git-view", "j", "cursor-down");
    weft.bindKey("git-view", "k", "cursor-up");
    weft.bindKey("git-view", "Down", "cursor-down");
    weft.bindKey("git-view", "Up", "cursor-up");
    weft.bindKey("git-view", "g", "git-status");
    weft.bindKey("git-view", "q", "git-status");
}
/// THE funnel — the manifest's dispatch prologue. Two decisions live here and
/// nowhere else: which repository session the command is about, and whether the
/// snapshot its arguments were designated against is still the one the model
/// holds. Returning false refuses the dispatch; the handler never runs.
fn dispatch(index: usize) bool {
    const c = cmds[index];
    const s = route(c.route) orelse return false;
    model.routed = s;
    switch (c.scope) {
        .durable => {},
        .snapshot => if (!s.fresh()) {
            refuseStale();
            return false;
        },
        .arm => if (!s.fresh()) {
            refuseStale();
            return false;
        },
    }
    return true;
}

/// A path/hunk action whose snapshot the model has moved past does NOT act on
/// the shifted node: it says so and shows the current status instead.
fn refuseStale() void {
    weft.echo("git: stale — refreshed");
    // A gather in flight repaints on its own; otherwise show what IS current,
    // and only in the session's own buffer (never author someone else's).
    if (cur().fresh() and focusedSession() == model.routed) rerender();
}

// ── What runs when a gather settles, and when a view's text lands ──────────
//
// This was `on_fill_token`: one export receiving a `u32` the plugin had packed
// `(session << 8) | kind` into, unpacked back into a session and an
// eight-member `Fill` enum, and demultiplexed by a switch — one delivery door
// for eight unrelated things, each far from the code that asked for it.
//
// Every one of those eight is now the continuation of the call that wanted it,
// carrying its own session (`execWith`). What is left is the pair of hooks
// `gather.zig` calls when the bytes are in: the sequencing that a settled
// gather owes the rest of the plugin, and how a read-only view is coloured.

fn onGathered() void {
    paintOwnEntry();
    // The settles run OUTSIDE the focus scope above, because each does its own
    // focus work — landing on a draft to close it, then landing back — and a
    // restore wrapped around that would put focus on an entry the settle had
    // just retired.
    if (cur().committing != null) gitCommitSettle();
    if (cur().sequencing != null) gitRebaseSettle();
}

/// Repaint the session's OWN entry, whatever happens to be focused.
///
/// The fill door used to guarantee this by binding the target entry at spawn:
/// a delivery could not be misdirected because it never asked what was active.
/// `exec` carries a PLACE, not an entry, and `repaint` authors the active
/// buffer — so the guarantee is re-made here, by landing on the entry and
/// landing back.
///
/// This is the seam the projection closes for good: `wl_proj_begin` captures
/// the entry once, and nothing between then and the commit can redirect it.
/// Deleting this function is the first thing git's port to it buys.
fn paintOwnEntry() void {
    var prev_buf: [64]u8 = undefined;
    const prev = weft.activeBufferName(&prev_buf);
    if (!model.focusBuffer(cur().name())) return; // the entry went away mid-flight
    defer if (prev) |name| {
        if (!std.mem.eql(u8, name, cur().name())) _ = model.focusBuffer(name);
    };
    renderStatus();
}

fn onViewFilled(style: model.ViewStyle) void {
    // Colouring a read-only view is `render.zig`.s, beside the projection it
    // is deliberately NOT: a view is one command.s output shown verbatim, with
    // no model behind it and no rows to name, which is why it still paints
    // spans by offset and the projection never does.
    render_mod.styleView(style);
    if (style == .rebase_todo) rebaseTodoFill();
}

/// A buffer took focus. One offer table is live for the `git` tool identity,
/// so it has to describe the repository the user is now looking at — this is
/// the routing entry for focus, exactly as `on_fill_token` is for a delivery.
export fn on_activate() void {
    if (focusedSession()) |s| model.routed = s;
    publishOffers();
}

// ── Repository sessions: root detection, minting, routing ──────────────────
/// The session whose projection buffer is focused, if any — a command pressed
/// in `*git:2*` is about repository 2, whatever ran before it.
fn focusedSession() ?*RepoSession {
    var buf: [64]u8 = undefined;
    const active = weft.activeBufferName(&buf) orelse return null;
    for (sessions.items) |s| {
        if (std.mem.eql(u8, s.name(), active)) return s;
    }
    return null;
}

/// The session already open for `root`, or null. The find half of
/// `sessionFor`, without the mint -- so a caller can prefer "the session for
/// where I am" without that preference itself opening a repository.
fn openSessionFor(root: []const u8) ?*RepoSession {
    if (root.len == 0) return null;
    for (sessions.items) |s| {
        if (std.mem.eql(u8, s.root, root)) return s;
    }
    return null;
}

/// Find-or-mint the session for `root`, taking the next free instance name.
fn sessionFor(root: []const u8) ?*RepoSession {
    // No local directory to be a repository in (`doc/place.md`: a peer place,
    // or a container that went away). Refuse by name rather than mint a
    // session whose `cd` guard would fall through to wherever this process
    // happens to be.
    if (root.len == 0) {
        weft.echo("git: this place has no local repository");
        return null;
    }
    if (openSessionFor(root)) |s| return s;
    var name_buf: [64]u8 = undefined;
    const name = mintName(&name_buf) orelse return null;
    const alloc = weft.allocator;
    sessions.ensureUnusedCapacity(alloc, 1) catch return refuseNoMemory();
    const owned_root = alloc.dupe(u8, root) catch return refuseNoMemory();
    const s = alloc.create(RepoSession) catch {
        alloc.free(owned_root);
        return refuseNoMemory();
    };
    s.* = .{ .id = model.next_session_id, .root = owned_root };
    model.next_session_id += 1;
    s.name_len = @min(name.len, s.name_buf.len);
    @memcpy(s.name_buf[0..s.name_len], name[0..s.name_len]);
    sessions.appendAssumeCapacity(s);
    return s;
}

/// The one refusal a mint has left. Where the old refusal named a cap nobody
/// chose, this names the only thing that can actually stop us — and says so,
/// rather than opening the wrong repository's session.
fn refuseNoMemory() ?*RepoSession {
    weft.echo("git: out of memory — could not open this repository");
    return null;
}

/// The lowest instance name (`*git*`, `*git:2*`, …) neither a buffer nor a
/// live session already answers to — a new session's identity. Needs no
/// ceiling: an ordinal is held only by a buffer or a live session, both finite,
/// so one of the first `buffers + sessions + 1` is always free.
fn mintName(out: []u8) ?[]const u8 {
    var n: u32 = 1;
    while (true) : (n += 1) {
        const candidate = weft.instanceName(buf_base, n, out) orelse return null;
        if (weft.bufferNamed(candidate)) continue;
        if (nameTaken(candidate)) continue;
        return candidate;
    }
}

fn nameTaken(name: []const u8) bool {
    for (sessions.items) |s| {
        if (std.mem.eql(u8, s.name(), name)) return true;
    }
    return false;
}

/// Which session this command is about.
fn route(kind: Route) ?*RepoSession {
    if (kind == .carried) return model.routed;
    // `.repo` asks the LOCUS, never what is focused: that is the whole door
    // into a second repository, and it must open one from a git buffer too.
    if (kind == .repo) return sessionFor(activeRoot());
    if (focusedSession()) |s| return s; // a git buffer names its own session
    // Then a session for the place we are actually in, if one is already open.
    // Falling straight through to `cur` meant the MOST RECENT session won, and
    // "most recent" tracks the last thing you touched anywhere — so a git
    // command run from a file in one repository routinely acted on another.
    // Same rung, same reason, as `weft.Instances.current`'s place link.
    //
    // Deliberately a lookup and not `sessionFor`: this must not MINT a session
    // where it previously did not, which would change when a second repository
    // silently opens.
    if (openSessionFor(activeRoot())) |s| return s;
    return if (sessions.items.len == 0) sessionFor(activeRoot()) else model.routed;
}

/// The repository root this command is about: WHERE it runs (`doc/place.md`).
/// Absolute, so the same repository always keys one session.
///
/// **The climb is gone, and with it git's last filesystem grant.** The host
/// detects a place when a file is opened by walking exactly the markers this
/// plugin used to walk itself (`app/session.zig`'s `project_markers`) — up
/// from the file, stopping at a floor, `.git` counting whatever kind it is —
/// so climbing again here was a SECOND detector of one fact, running on a
/// grant that reached the whole filesystem to answer a question about the
/// user's own project. The focused buffer's path is not consulted either: an
/// entry's place is derived from its path, so asking the place already asks
/// about that file.
///
/// It also makes the marker rule right by construction rather than by care.
/// The place is where the project's OWN marker is, and this plugin can no
/// longer walk up out of it: a project rooted at a `.jj` or `.hg` top stays
/// its own root instead of resolving to whatever enclosing `.git` checkout
/// happens to contain it — the "must not claim a foreign repository" property,
/// held by DELETING the climb rather than by adding a check to it.
///
/// Note what is deliberately NOT asked here: whether the place holds `.git`.
/// That question has its own door (`weft.placeHas`) and a real caller
/// (`rebaseInProgress`), but it cannot pick a root, because both answers pick
/// the SAME directory. A place without a repository is where `git-init`
/// creates one, and the gather renders the honest "Not a git repository."
/// until it does — so a `.git` probe here would decide nothing.
///
/// Empty is the one refusal (a peer place, or a container that went away);
/// `sessionFor` names it.
fn activeRoot() []const u8 {
    return placeDir();
}

/// The focused buffer's file, absolute, or null for a tool buffer (or for a
/// place with no local directory to name it against).
fn activePathAbs() ?[]const u8 {
    const here = placeDir();
    const abs = absolute(weft.path() orelse return null, here);
    return if (abs.len == 0) null else abs;
}

/// WHERE this dispatch runs (`doc/place.md`), copied off the shim's shared read
/// scratch. Empty when the place has no local directory at all, which every
/// caller below treats as a refusal rather than as "here".
fn placeDir() []const u8 {
    const root = weft.placeRoot();
    const n = @min(root.len, base_buf.len);
    @memcpy(base_buf[0..n], root[0..n]);
    return base_buf[0..n];
}

/// `pth` made absolute against this dispatch's place — a buffer path may be
/// relative, a repository root never is. `weft.placePath` owns the join,
/// because a path spelled relative to the launch directory and a place below
/// it share components neither spelling admits to (see its doc).
fn absolute(pth: []const u8, here: []const u8) []const u8 {
    return weft.placePath(here, pth, &probe_buf);
}

/// Pull the buffer's raw bytes into `raw` (paged in `slice`-sized windows, since
/// Re-render the model over this session's buffer. The projection is
/// authored FIRST; styles and folds then index the new bytes. `render.zig`
/// owns every step, including the write — this is the name a verb calls.
const repaint = render_mod.repaint;

/// Model → projection. Landing the cursor is the HOST.s: it remembered which
/// ROW point was on before the rebuild and puts it back there by key, so the
/// captured target, the fallback offset, and the home offset this used to
/// juggle are all gone.
fn renderStatus() void {
    parser.parse();
    repaint();
    // A new model is a new offer table: the previous one described rows that
    // no longer exist, and its ordinal is now stale at the door.
    publishOffers();
    noteDrops();
}

/// `noteDrops` is only ever reached from `on_fill_token` (BACKGROUND — see the
/// on_fill_token body above: it's the tail of `parseAndRender`, called nowhere
/// else). `weft.echo` is head-gated (task #19 item 4), so the actual
/// echoes defer through a self-registered command: a nested `weft.run` from
/// a background entry IS a dispatching entry for its duration (the same
/// door an async LSP response uses — see `src/plugins/lsp/root.zig`'s identical
/// pattern), so `gitNoteDropsDeliver` below runs with a real dispatching
/// head. The session travels WITH the deferral (`.carried` routing) — a
/// background note never asks what is focused.
fn noteDrops() void {
    if (!(cur().dropped_files or cur().dropped_hunks or cur().truncated_raw)) return;
    weft.run("git-note-drops-deliver");
}

fn gitNoteDropsDeliver() void {
    if (cur().dropped_files) weft.echo("git: >128 files — some omitted");
    if (cur().dropped_hunks) weft.echo("git: >512 hunks — some omitted");
    if (cur().truncated_raw) weft.echo("git: output > 256 KiB — diff truncated");
}

// Every verb targets through `nodeAtCursor` and resolves through `resolve`.
// The display tables and the projection buffer are `render.zig`'s, and a
// verb cannot reach them except through the four readers it exports —
// which `e2e/project` asserts by scanning THIS file for a rendered offset.

/// A target → the live node it names, or null when it can no longer act.
fn resolve(t: Target) ?Node {
    switch (t.kind) {
        .none => return null,
        // A durable OID: valid whatever the working tree has since done.
        .commit => return .{ .kind = .commit, .idx = 0 },
        .section => {
            const idx = @intFromEnum(t.section);
            return if (cur().sec_present[idx]) .{ .kind = .section, .idx = idx } else null;
        },
        .file => {
            const fi = findFile(t.section, t.path_()) orelse return null;
            return .{ .kind = .file, .idx = fi };
        },
        .hunk => {
            // Snapshot-scoped: an ordinal from a superseded model names nothing.
            if (t.snap != cur().snapshot) return null;
            const fi = findFile(t.section, t.path_()) orelse return null;
            const f = &cur().files[fi];
            if (t.ord >= f.n_hunks) return null;
            return .{ .kind = .hunk, .idx = f.first_hunk + t.ord };
        },
    }
}

/// Resolve for a verb: silent on empty space, loud when the target went stale.
fn liveNode(t: Target, verb: []const u8) ?Node {
    if (t.kind == .none) return null;
    return resolve(t) orelse {
        var b: [64]u8 = undefined;
        weft.echo(std.fmt.bufPrint(&b, "{s}: target moved — nothing done", .{verb}) catch verb);
        return null;
    };
}

/// The commit under point, or null when point isn't on one.
fn commitAtCursor() ?Target {
    const t = nodeAtCursor();
    return if (t.kind == .commit) t else null;
}

// ── Published offers: what the row under point affords ─────────────────────
/// The section the target belongs to — the fact every staging verb turns on.
fn sectionOf(t: Target) ?Section {
    return switch (t.kind) {
        .file, .hunk, .section => t.section,
        .commit, .none => null,
    };
}

fn stageReason(t: Target) []const u8 {
    if (t.kind == .commit) return "not-a-change";
    return switch (sectionOf(t) orelse return "no-row") {
        .untracked, .unstaged => "",
        .staged => "already-staged",
        .recent => "not-a-change",
    };
}

fn unstageReason(t: Target) []const u8 {
    if (t.kind == .commit) return "not-staged";
    return if ((sectionOf(t) orelse return "no-row") == .staged) "" else "not-staged";
}

fn openReason(t: Target) []const u8 {
    return switch (t.kind) {
        .file, .hunk, .commit => "",
        .section => "no-target",
        .none => "no-row",
    };
}

/// Publish what git affords RIGHT HERE: the row verbs, from the target under
/// point, and the repository-level verbs, from being in a repo at all. Pushed
/// on every event that can change either — a new model, a fold, a row move —
/// so nothing has to probe git mid-resolution.
///
/// The table is scoped to git's own tool identity and stamped with the
/// session's snapshot ordinal: it applies in a status entry, and only while the
/// model it was computed from is the current one.
///
/// ONE table is live, and it must describe the entry the user is looking at: a
/// commit draft offers what it can be re-seated as, a status projection offers
/// its row verbs, and a gather landing in an unfocused session says nothing.
/// `on_activate` republishes when focus moves.
fn publishOffers() void {
    if (focusedDraft()) |slot| return publishDraftOffers(slot);
    // Before the first repository is opened there is nothing to describe. This
    // is the one reader that can run unrouted, which is why `model.routed` is the
    // thing it tests rather than a blank session standing in for one.
    if (model.routed == null) return weft.offersRetract();
    if (focusedSession() != model.routed) return;
    if (!cur().in_repo) {
        weft.offersRetract();
        return;
    }
    const t = nodeAtCursor();
    weft.offersBegin(tool, cur().snapshot);
    weft.offer("plugin.git.stage", "git-stage", stageReason(t));
    weft.offer("plugin.git.unstage", "git-unstage", unstageReason(t));
    weft.offer("plugin.git.open-diff", "git-visit", openReason(t));
    weft.offer("plugin.git.commit", "git-commit", "");
    weft.offer("plugin.git.refresh", "git-refresh", "");
    weft.offer("plugin.git.push", "git-push", "");
    weft.offer("plugin.git.pull", "git-pull", "");
    weft.offer("plugin.git.fetch", "git-fetch", "");
    weft.offersCommit();
}

/// The draft entry that is FOCUSED, if any. Unlike `Drafts.current` this never
/// falls back to the most recent: an offer table is about the buffer under the
/// user's eyes, not the one a command last touched.
fn focusedDraft() ?*Drafts.Slot {
    var buf: [64]u8 = undefined;
    const active = weft.activeBufferName(&buf) orelse return null;
    for (drafts.slots.items) |slot| {
        if (std.mem.eql(u8, slot.name(), active)) return slot;
    }
    return null;
}

/// What a draft affords: the same `plugin.git.*` namespace, published through
/// the same door — a re-seat onto a commit needs the commit the draft was
/// opened for, and says so when there is none.
fn publishDraftOffers(slot: *Drafts.Slot) void {
    const onto: []const u8 = if (slot.value.onto.kind == .commit) "" else "no-commit-chosen";
    weft.offersBegin(draft_tool, draft_ordinal);
    weft.offer("plugin.git.amend", "git-draft-amend", "");
    weft.offer("plugin.git.reword", "git-draft-reword", "");
    weft.offer("plugin.git.fixup", "git-draft-fixup", onto);
    weft.offer("plugin.git.squash", "git-draft-squash", onto);
    weft.offersCommit();
}

// ── Navigation / folding ────────────────────────────────────────────────────
/// Core moves point (fold-aware); we republish, because the row under point
/// IS the offers' subject. A cursor moved by anything else leaves the table
/// describing the previous row — the verb then refuses out loud when it
/// re-resolves the node, exactly as it always has.
fn gitNextRow() void {
    weft.run("cursor-down");
    publishOffers();
}
fn gitPrevRow() void {
    weft.run("cursor-up");
    publishOffers();
}

fn gitStatus() void {
    gather_mod.gather();
    weft.setMode("git");
}

/// Start version control from inside the editor: `git init` in the project,
/// then gather straight into `*git*`. Without this, `git-status` on a
/// non-repo just shows an empty buffer and there is no in-editor way to create
/// the repo — you had to drop to a shell. Reuses the same gather scaffolding as
/// every other mutation (no git-init special-casing); after init, GATHER's
/// `git status --branch` renders the fresh `Branch: main` header.
fn gitInit() void {
    after(&.{ "git", "init" });
}
fn gitRefresh() void {
    gather_mod.gather();
    weft.setMode("git");
}

/// TAB: flip the fold of the section/file under point, re-render (no re-gather —
/// the model is intact), republish, and keep the cursor on the header.
fn gitToggleFold() void {
    const t = nodeAtCursor();
    const n = resolve(t) orelse return;
    // The head to keep point on, named by identity — it survives the re-render.
    // A fold is the HOST.s: it flips the collapsed set for that key, re-lays
    // the tree it already holds, and keeps point on the row. No producer is
    // consulted and the revision does not move — a fold changes the view, not
    // the model — so a decision made before it is still about the same model.
    //
    // A hunk row folds its parent FILE (hunk-granularity folds are a later
    // phase), which is now a matter of naming a different key rather than of
    // recomputing an offset to jump back to.
    const fold_key = switch (n.kind) {
        .section, .file => render_mod.keyOf(t),
        .hunk => render_mod.keyOf(fileTarget(cur().hunks[n.idx].file)),
        else => return,
    };
    render_mod.toggleFold(fold_key);
    publishOffers();
}

/// Repaint from the model in hand — no re-gather, the model is intact (a
/// refused stale action showing what IS current). Point keeps its ROW without
/// being saved and restored, because the host remembers which row it was on.
fn rerender() void {
    repaint();
}

fn gitVisit() void {
    const t = nodeAtCursor();
    const n = resolve(t) orelse return;
    const fi: usize = switch (n.kind) {
        .file => n.idx,
        .hunk => cur().hunks[n.idx].file,
        // RET on a recent commit → show it (a diff-colored read-only buffer).
        .commit => {
            showCommit(t);
            return;
        },
        else => return,
    };
    weft.runStr("open", cur().inRepo(cur().files[fi].path_()));
}

// ── Staging: file / hunk / region, resolved from the node under point ───────
fn gitStage() void {
    const t = nodeAtCursor();
    const n = liveNode(t, "stage") orelse return;
    switch (n.kind) {
        .hunk => {
            if (cur().files[cur().hunks[n.idx].file].section != .unstaged) {
                weft.echo("stage: not an unstaged hunk");
                return;
            }
            applyHunk(n.idx, t.sel, false);
        },
        .file => {
            const f = &cur().files[n.idx];
            if (f.section == .staged) {
                weft.echo("stage: already staged");
                return;
            }
            after(&.{ "git", "add", "--", f.path_() });
        },
        .section => {
            if (t.section == .staged) return;
            stageSection(t.section, true);
        },
        else => {},
    }
}

fn gitUnstage() void {
    const t = nodeAtCursor();
    const n = liveNode(t, "unstage") orelse return;
    switch (n.kind) {
        .hunk => {
            if (cur().files[cur().hunks[n.idx].file].section != .staged) {
                weft.echo("unstage: not a staged hunk");
                return;
            }
            applyHunk(n.idx, t.sel, true);
        },
        .file => {
            const f = &cur().files[n.idx];
            if (f.section != .staged) {
                weft.echo("unstage: not staged");
                return;
            }
            after(&.{ "git", "reset", "-q", "HEAD", "--", f.path_() });
        },
        .section => {
            if (t.section != .staged) return;
            stageSection(t.section, false);
        },
        else => {},
    }
}

fn gitStageAll() void {
    after(&.{ "git", "add", "-A" });
}
fn gitUnstageAll() void {
    after(&.{ "git", "reset", "-q", "HEAD" });
}

/// Stage/unstage every file of a section (a section header operation).
///
/// One command with one argument per file — where this used to build a shell
/// line by wrapping each path in `'{s}'`, which is wrong for any path
/// containing an apostrophe and was never going to be right for one containing
/// a newline.
fn stageSection(sec: Section, stage: bool) void {
    var argv: Argv = .{};
    if (stage) argv.pushAll(&.{ "git", "add", "--" }) else argv.pushAll(&.{ "git", "reset", "-q", "HEAD", "--" });
    const before = argv.n;
    var fi: usize = 0;
    while (fi < cur().file_count) : (fi += 1) {
        if (cur().files[fi].section != sec) continue;
        argv.push(cur().files[fi].path_());
    }
    if (argv.n == before) return;
    after(argv.slice());
}

// ── Discard (destructive — always confirmed) ────────────────────────────────
/// What a discard was armed against: the repository, and the row as it was
/// named at the moment the question was asked. Carried through the question, so
/// the answer acts on THIS target and no later one.
const Armed = struct { session: u32, target: Target };

/// Arm a destructive verb: capture WHAT it targets now, ask, act later.
fn gitDiscard() void {
    const t = nodeAtCursor();
    const n = liveNode(t, "discard") orelse return;
    const armed: Armed = .{ .session = cur().id, .target = t };
    switch (n.kind) {
        .file => _ = weft.confirmWith(Armed, armed, "discard changes to this file?", gitDiscardDo),
        .hunk => _ = weft.confirmWith(Armed, armed, "discard this hunk?", gitDiscardDo),
        // `x` on a recent commit → the reset transient, scoped to that OID.
        .commit => {
            cur().pending_target = t;
            weft.echo("reset: s soft  m mixed  h hard");
            weft.setMode("git-reset-menu");
        },
        .section => _ = weft.confirmWith(Armed, armed, "discard the whole section?", gitDiscardDo),
        .none => {},
    }
}
/// The confirmed destructive path. It acts on the target captured when the
/// question was asked, re-resolved against the live model — a target the model
/// no longer names (a background re-gather landed under the prompt) destroys
/// nothing.
fn gitDiscardDo(yes: bool, armed: Armed) void {
    if (!route_to(armed.session)) return;
    if (!yes) return weft.echo("cancelled");
    const t = armed.target;
    const n = resolve(t) orelse {
        weft.echo("discard refused: the target moved since you asked");
        return;
    };
    switch (n.kind) {
        .hunk => {
            // Reverse the worktree change; for a staged hunk, drop it from the
            // index too (git's discard reverts both sides).
            const staged = cur().files[cur().hunks[n.idx].file].section == .staged;
            discardHunk(n.idx, t.sel, staged);
        },
        .file => {
            const f = &cur().files[n.idx];
            switch (f.section) {
                // `rm` has no `-C`, so it gets the path made absolute against the
                // session.s root — the same join `open` already uses for a row.
                .untracked => after(&.{ "rm", "--", cur().inRepo(f.path_()) }),
                .unstaged => after(&.{ "git", "checkout", "--", f.path_() }),
                // `checkout HEAD --` restores index AND worktree in one
                // command. The pair it replaces (`reset -q HEAD` then
                // `checkout`) existed because the two were fused with `&&` into
                // a shell line; without a shell there is no reason to spell as
                // two what git spells as one.
                .staged => after(&.{ "git", "checkout", "HEAD", "--", f.path_() }),
                .recent => {},
            }
        },
        .section => discardSection(t.section),
        else => {},
    }
}

/// Discard a whole section: ONE command, with every path as an argument.
///
/// It used to be a `;`-joined shell line with a per-file command in it —
/// necessary only because the staged case was a two-command `&&` pair, which
/// `checkout HEAD --` collapses. Once every case is a single verb, a section
/// is that verb applied to a list, which is what git wanted to be told.
fn discardSection(sec: Section) void {
    var argv: Argv = .{};
    switch (sec) {
        .untracked => argv.pushAll(&.{ "rm", "--" }),
        .unstaged => argv.pushAll(&.{ "git", "checkout", "--" }),
        .staged => argv.pushAll(&.{ "git", "checkout", "HEAD", "--" }),
        .recent => return,
    }
    const before = argv.n;
    var fi: usize = 0;
    while (fi < cur().file_count) : (fi += 1) {
        if (cur().files[fi].section != sec) continue;
        // `rm` runs with no `-C`, so its paths are absolute; git.s are
        // repository-relative, which is what git wants.
        argv.push(if (sec == .untracked) cur().inRepo(cur().files[fi].path_()) else cur().files[fi].path_());
    }
    if (argv.n == before) {
        weft.setMode("git");
        return;
    }
    after(argv.slice());
}

// ── Patch synthesis + git apply ─────────────────────────────────────────────
/// Stage (`reverse=false`) or unstage (`reverse=true`) a hunk against the index.
/// With a selection overlapping the hunk, synthesize a PARTIAL patch; otherwise
/// the whole hunk. Index-only — the worktree is never touched.
fn applyHunk(hi: usize, sel: ?Lines, reverse: bool) void {
    const patch = buildPatch(hi, sel) orelse {
        weft.echo("git: patch too large");
        return;
    };
    // `{}` is the SPOOLED patch: the host writes it to a temp it names, hands
    // `git apply` that path, and removes it — succeeded or failed. git names
    // no path it writes, which is why the most privileged plugin here still
    // declares no filesystem capability at all.
    if (reverse) {
        afterInput(&.{ "git", "apply", "--cached", "--reverse", "{}" }, patch);
    } else {
        afterInput(&.{ "git", "apply", "--cached", "{}" }, patch);
    }
}

/// Discard a hunk: reverse it back out. For a STAGED hunk that means index and
/// worktree both, which is `--index` — one apply, where the fused shell line
/// ran two (`--cached --reverse`, then `--reverse`) because it had no way to
/// say "both" other than saying it twice.
fn discardHunk(hi: usize, sel: ?Lines, staged: bool) void {
    const patch = buildPatch(hi, sel) orelse {
        weft.echo("git: patch too large");
        weft.setMode("git");
        return;
    };
    if (staged) {
        afterInput(&.{ "git", "apply", "--index", "--reverse", "{}" }, patch);
    } else {
        afterInput(&.{ "git", "apply", "--reverse", "{}" }, patch);
    }
}

// ── The commit draft ───────────────────────────────────────────────────────
// A draft is an ORDINARY text entry: no mode of its own, no owned keys. It is
// tool-backed, so `std.persistence.save` resolves to `git-commit-save` in it —
// saving the draft IS the commit. Aborting is closing the entry. Drafts are
// instanced, so each repository (and each parallel message) is its own entry.

// The draft/plan TYPES are model.zig's; these are this plugin's live tables.
const Draft = model.Draft;
const Drafts = model.Drafts;
var drafts: Drafts = .{};
const Todo = model.Todo;
const Todos = model.Todos;
var todos: Todos = .{};
const draft_tool = model.draft_tool;
const todo_tool = model.todo_tool;

/// The ordinal of what the drafts' published offers describe — bumped whenever
/// a draft opens or is re-seated, i.e. whenever its meaning changes. It is that
/// table's `revision`, so a decision resolved against the old meaning dies at
/// the effect door.
var draft_ordinal: u32 = 0;

/// What the effect said and whether it succeeded. Scratch, not state: the
/// settle that reads it is nested inside the very delivery that wrote it.
/// Open a commit draft. `prefill` (or "") is a shell command whose stdout seeds
/// the message — `git log -1 --format=%B` for amend/reword.
fn openDraft(flags: []const u8, prefill: []const []const u8) ?*Drafts.Slot {
    const slot = drafts.open(draft_tool) orelse {
        weft.echo("git: out of memory — could not open another commit draft");
        return null;
    };
    slot.value = .{ .session = cur().id };
    setFlags(slot, flags);
    weft.toolBacking(draft_tool);
    seedDraft(slot, prefill);
    weft.jump(0);
    weft.echo("commit draft: save to commit, close to abort");
    return slot;
}

/// A draft's meaning is its flags: setting them is a new model to offer from.
fn setFlags(slot: *Drafts.Slot, flags: []const u8) void {
    slot.value.flags_len = @min(flags.len, slot.value.flags.len);
    @memcpy(slot.value.flags[0..slot.value.flags_len], flags[0..slot.value.flags_len]);
    draft_ordinal +%= 1;
    publishOffers();
}

/// Seed a draft's message from `prefill`'s stdout (`git log -1 --format=%B` for
/// amend, `fixup! …` for a fixup). The empty prefill is the plain commit: the
/// entry stays exactly as it is, so nothing can land on top of what was typed.
fn seedDraft(slot: *Drafts.Slot, prefill: []const []const u8) void {
    if (prefill.len == 0) return;
    show(prefill, slot.name(), .none); // read from the draft.s own repository
}

/// The draft this command is about — the entry it was invoked in — and, with
/// it, the repository it was written for: a draft routes its own session.
fn currentDraft() ?*Drafts.Slot {
    const slot = drafts.current("commit draft") orelse {
        weft.echo("no commit draft here");
        return null;
    };
    model.routed = sessionById(slot.value.session) orelse return null;
    return slot;
}

/// `save` in a draft entry: write the message and run the commit it stands for.
/// git's exit status and git's own words come back as themselves, so the draft
/// closes only when git accepted it.
fn gitCommitSave() void {
    const slot = currentDraft() orelse return;
    const text = weft.slice(0, weft.byteLen());
    if (std.mem.trim(u8, text, " \t\r\n").len == 0) {
        weft.echo("commit: the message is empty");
        return;
    }
    const n = @min(text.len, msg_buf.len);
    @memcpy(msg_buf[0..n], text[0..n]);
    cur().committing = slot;
    // `{}` is the SPOOLED message: the host writes it, `git commit -F` reads
    // it, and the host removes it whether or not the commit was accepted.
    var argv: Argv = .{};
    argv.pushAll(&.{ "git", "commit" });
    var flags = std.mem.tokenizeAny(u8, slot.value.flagsOf(), " ");
    while (flags.next()) |flag| argv.push(flag);
    argv.pushAll(&.{ "-F", "{}" });
    afterNoted(argv.slice(), msg_buf[0..n]);
}

/// A draft git accepted is closed like any other entry; one it refused stays,
/// with the refusal shown — git's own first line of stderr, which used to be
/// recovered from the bytes ahead of a sentinel in stdout.
fn gitCommitSettle() void {
    const slot = cur().committing orelse return;
    cur().committing = null;
    if (!cur().effect_ok) {
        weft.echo(cur().effect_note[0..cur().effect_note_len]);
        return;
    }
    // Retiring the entry is focus-scoped: land on it, then close it.
    if (focusBuffer(slot.name())) weft.run("buffer-close");
    drafts.close(slot);
    _ = focusBuffer(cur().name());
    weft.echo("committed");
}

// ── The draft's own offers (amend/reword/fixup/squash) ─────────────────────
// Each re-seats the draft under point: the entry stays, its meaning changes.
fn reseat(slot: *Drafts.Slot, flags: []const u8, prefill: []const []const u8, note: []const u8) void {
    setFlags(slot, flags);
    seedDraft(slot, prefill);
    weft.echo(note);
}
const head_message: []const []const u8 = &.{ "git", "log", "-1", "--format=%B" };
fn gitDraftAmend() void {
    reseat(currentDraft() orelse return, "--amend", head_message, "draft: amends HEAD");
}
fn gitDraftReword() void {
    reseat(currentDraft() orelse return, "--amend --only", head_message, "draft: rewords HEAD");
}
fn gitDraftFixup() void {
    reseatOnto("fixup");
}
fn gitDraftSquash() void {
    reseatOnto("squash");
}
/// `fixup!`/`squash!` is a MESSAGE, so a draft expresses it by re-seeding its
/// text from the named commit's subject — no flag, no separate command path.
fn reseatOnto(kind: []const u8) void {
    const slot = currentDraft() orelse return;
    if (slot.value.onto.kind != .commit) {
        weft.echo("no commit chosen to fix up");
        return;
    }
    const fmt = std.fmt.bufPrint(&op_buf, "--format={s}! %s", .{kind}) catch return;
    reseat(slot, "", &.{ "git", "log", "-1", fmt, slot.value.onto.hash_() }, kind);
}

// ── Opening a draft from the status buffer ─────────────────────────────────
fn gitCommit() void {
    _ = openDraft("", &.{});
}
/// Amend: edit the current message (pre-filled), include staged changes.
fn gitAmend() void {
    _ = openDraft("--amend", head_message);
}
/// Reword: amend the MESSAGE ONLY (`--only`) — staged changes stay staged.
fn gitReword() void {
    _ = openDraft("--amend --only", head_message);
}
/// Extend: fold staged changes into HEAD, keep the message (no draft).
fn gitExtend() void {
    after(&.{ "git", "commit", "--amend", "--no-edit" });
}
fn gitFixup() void {
    openOnto("fixup");
}
fn gitSquash() void {
    openOnto("squash");
}
/// `fixup!`/`squash!` is a MESSAGE, so a draft opened onto a commit is seeded
/// from that commit's subject and REMEMBERS the OID it was opened onto.
fn openOnto(kind: []const u8) void {
    const onto = commitAtCursor() orelse {
        weft.echo("no commit under point");
        return;
    };
    const fmt = std.fmt.bufPrint(&op_buf, "--format={s}! %s", .{kind}) catch return;
    const slot = openDraft("", &.{ "git", "log", "-1", fmt, onto.hash_() }) orelse return;
    slot.value.onto = onto;
}

// ── The SPC-g read-only views (unchanged behavior) ──────────────────────────
fn gitLog() void {
    show(&.{ "git", "log", "--oneline", "--graph", "-30" }, "*git-log*", .log);
}
fn gitDiff() void {
    show(&.{ "git", "diff" }, "*git-diff*", .diff);
}
fn gitDiffStaged() void {
    show(&.{ "git", "diff", "--staged" }, "*git-diff-staged*", .diff);
}
fn gitBlame() void {
    // Absolute: the command runs in the repository, the buffer path may not be
    // spelled relative to it.
    const path = activePathAbs() orelse return;
    show(&.{ "git", "blame", "--", path }, "*git-blame*", .none);
}

// ── Confirmation is an interaction, not a mode ─────────────────────────────
// A destructive verb asks through the pick membrane: the question is the
// prompt, the two candidates are the answer. No mode of git's own stands
// between the two — and, since `weft.confirmWith`, no `u32` either.
//
// What the packed id used to carry — which question this was, and which
// repository asked it — now travels WITH the question as an ordinary value. So
// does the thing being confirmed. That closes the gap this file used to have to
// bridge with module state: `pending_target` for a discard, and a per-session
// `confirm_cmd` buffer for a staged mutation, both written before the question
// and read after it, with an unrelated background re-gather able to land in
// between. A carried value cannot be overwritten by the next question.

/// A confirmed mutation: WHICH verb, and the one ref or OID it acts on.
/// Composed from durable names, so it needs no re-resolution against a working
/// tree that may have moved.
///
/// It used to be a 4 KiB buffer holding a SHELL LINE, assembled before the
/// question and run verbatim after it. Naming the verb instead of spelling it
/// means the answer cannot run something the question did not describe, and it
/// costs a fixed-size struct rather than a kilobyte of command text carried
/// through a continuation.
const Staged = struct {
    session: u32,
    verb: enum { reset_hard, stash_drop, branch_delete },
    arg: [128]u8 = undefined,
    arg_len: usize = 0,

    fn argument(self: *const Staged) []const u8 {
        return self.arg[0..self.arg_len];
    }
};

/// Ask before running `verb`. Safe answer first (`confirmSpec`), so accepting
/// the leading candidate changes nothing.
fn confirmThen(verb: @FieldType(Staged, "verb"), arg: []const u8, question: []const u8) void {
    var staged: Staged = .{ .session = cur().id, .verb = verb };
    staged.arg_len = @min(arg.len, staged.arg.len);
    @memcpy(staged.arg[0..staged.arg_len], arg[0..staged.arg_len]);
    _ = weft.confirmWith(Staged, staged, question, runStaged);
}

fn runStaged(yes: bool, staged: Staged) void {
    if (!route_to(staged.session)) return;
    if (!yes) return weft.echo("cancelled");
    switch (staged.verb) {
        .reset_hard => after(&.{ "git", "reset", "--hard", staged.argument() }),
        .stash_drop => after(&.{ "git", "stash", "drop" }),
        .branch_delete => after(&.{ "git", "branch", "-d", staged.argument() }),
    }
}

/// Route a carried answer back to the repository that asked. A session that
/// closed while the question was open answers nothing — the check the packed
/// id's `sessionById` used to make, at the same seam.
fn route_to(session: u32) bool {
    const s = sessionById(session) orelse return false;
    model.routed = s;
    return true;
}

/// `close` in a draft or a rebase plan: its text is written work with no file
/// behind it, so dropping it ASKS. An empty one has nothing to lose and goes.
fn gitDraftClose() void {
    const text = weft.slice(0, weft.byteLen());
    if (std.mem.trim(u8, text, " \t\r\n").len == 0) {
        weft.run("buffer-close");
        return;
    }
    _ = weft.confirm("discard this draft?", closeIfConfirmed);
}

/// The entry the question was asked in is still the active one.
fn closeIfConfirmed(yes: bool) void {
    if (yes) weft.run("buffer-close") else weft.echo("cancelled");
}

// ── Show / cherry-pick / revert / reset on the commit under point ───────────
fn gitShow() void {
    const t = commitAtCursor() orelse {
        weft.echo("show: no commit under point");
        return;
    };
    showCommit(t);
}
fn showCommit(t: Target) void {
    show(&.{ "git", "show", t.hash_() }, "*git-show*", .diff);
    weft.setMode("git-view");
}
fn gitCherryPick() void {
    const t = commitAtCursor() orelse {
        weft.echo("cherry-pick: no commit under point");
        return;
    };
    after(&.{ "git", "cherry-pick", t.hash_() });
}
fn gitRevert() void {
    const t = commitAtCursor() orelse {
        weft.echo("revert: no commit under point");
        return;
    };
    after(&.{ "git", "revert", "--no-edit", t.hash_() });
}
fn gitResetSoft() void {
    resetTo("--soft");
}
fn gitResetMixed() void {
    resetTo("--mixed");
}
/// The reset transient acts on the OID `x` armed it with — durable, so no
/// re-resolution against the working tree is needed or wanted.
fn resetTo(kind: []const u8) void {
    if (cur().pending_target.kind != .commit) return;
    after(&.{ "git", "reset", kind, cur().pending_target.hash_() });
}
fn gitResetHard() void {
    if (cur().pending_target.kind != .commit) return;
    confirmThen(.reset_hard, cur().pending_target.hash_(), "reset --hard (loses changes)?");
}

// ── Branch transient (names come from the `*git-input*` prompt) ─────────────
fn gitBranchCheckout() void {
    openInput(.branch_checkout, "checkout branch: (C-c C-c)");
}
fn gitBranchCreate() void {
    openInput(.branch_create, "create & checkout branch: (C-c C-c)");
}
fn gitBranchNew() void {
    openInput(.branch_new, "new branch: (C-c C-c)");
}
fn gitBranchDelete() void {
    openInput(.branch_delete, "delete branch: (C-c C-c)");
}
fn gitBranchRename() void {
    openInput(.branch_rename, "rename current branch to: (C-c C-c)");
}

// ── Stash transient ─────────────────────────────────────────────────────────
fn gitStashSave() void {
    after(&.{ "git", "stash", "push" });
}
fn gitStashPop() void {
    after(&.{ "git", "stash", "pop" });
}
fn gitStashApply() void {
    after(&.{ "git", "stash", "apply" });
}
fn gitStashList() void {
    show(&.{ "git", "stash", "list" }, "*git-stash*", .none);
    weft.setMode("git-view");
}
fn gitStashDrop() void {
    confirmThen(.stash_drop, "", "drop stash@{0}?");
}

// ── Log transient (the inline Recent section covers the common case) ────────
fn gitLogAll() void {
    show(&.{ "git", "log", "--oneline", "--graph", "--all", "-50" }, "*git-log*", .log);
    weft.setMode("git-view");
}

// ── The single-line prompt (branch names, rebase depth) ─────────────────────
// This used to be a REAL BUFFER — `*git-input*`, created, focused, cleared
// with an `edit`, then read back out of the document line by line, with its
// own mode, its own C-c menu, and its own abort/resume/finish commands. All
// of that to ask for a branch name. It is `weft_prompt` now: the same
// minibuffer vim's `:` and lsp's rename use, so backing out of a branch name
// is the same key as backing out of anything else, and git no longer owns
// four commands and two modes for text entry.
const input = prompt.Prompt(.{
    .name = "git-input",
    .resting = "git",
    .capacity = 256,
    .on_accept = onInput,
    .on_cancel = struct {
        fn cancelled() void {
            cur().input_action = .none;
            weft.echo("cancelled");
        }
    }.cancelled,
});

fn openInput(action: InputAction, label: []const u8) void {
    cur().input_action = action;
    input.open(label);
}

fn onInput(name: []const u8) void {
    const act = cur().input_action;
    cur().input_action = .none;
    if (name.len == 0) {
        weft.echo("cancelled");
        return;
    }
    switch (act) {
        .branch_checkout => after(&.{ "git", "checkout", name }),
        .branch_create => after(&.{ "git", "checkout", "-b", name }),
        .branch_new => after(&.{ "git", "branch", name }),
        .branch_rename => after(&.{ "git", "branch", "-m", name }),
        .branch_delete => confirmThen(.branch_delete, name, "delete branch?"),
        .rebase_start => startRebase(name),
        .none => {},
    }
}

// ── Interactive rebase (Phase 2c) ───────────────────────────────────────────
/// A rebase is mid-flight iff `.git/rebase-merge` or `.git/rebase-apply`
/// exists. Two questions about the place this command dispatches in — which is
/// this session's repository, because that is where the session came from
/// (`activeRoot`) and what its entry carries: a key pressed in `*git:2*` is
/// dispatched at repo B's place, so the probe follows the buffer the user is
/// looking at, exactly as `cur` does.
///
/// It used to LIST `<root>/.git` and grep the names, which needed `fs_read`
/// over the whole filesystem to look at two entries inside the project the
/// user is already in — and, being a list, would also have matched a
/// `rebase-merge` that was merely a prefix of something else.
fn rebaseInProgress() bool {
    return weft.placeHas(".git/rebase-merge") != .none or
        weft.placeHas(".git/rebase-apply") != .none;
}
fn gitRebaseInteractive() void {
    if (rebaseInProgress()) {
        weft.echo("rebase in progress — c continue / a abort / s skip");
        // Re-set the SAME mode we're already in: with `git-rebase-menu` sticky
        // this is a genuine no-op leaf (mode unchanged, nothing to auto-pop) —
        // the menu stays open, unlike the plain-menuMode case where dispatch
        // would read "unchanged" as "close it".
        weft.setMode("git-rebase-menu");
        return;
    }
    openInput(.rebase_start, "interactive rebase last N commits: (C-c C-c)");
}
/// Kick off the todo: an ordinary instanced entry listing `HEAD~N..HEAD`
/// oldest-first; the `.rebase` fill rewrites those lines into a `pick …` todo,
/// which is then plain text — edited, reordered, and SAVED to run the rebase.
fn startRebase(nstr: []const u8) void {
    for (nstr) |c| if (c < '0' or c > '9') {
        weft.echo("rebase: expected a number");
        weft.setMode("git");
        return;
    };
    const slot = todos.open(todo_tool) orelse {
        weft.echo("git: out of memory — could not open another rebase plan");
        return;
    };
    slot.value = .{ .session = cur().id };
    const base = std.fmt.bufPrint(&slot.value.base, "HEAD~{s}", .{nstr}) catch return;
    slot.value.base_len = base.len;
    weft.toolBacking(todo_tool);
    const range = std.fmt.bufPrint(&cmd_buf, "{s}..HEAD", .{base}) catch return;
    show(&.{ "git", "log", "--reverse", "--format=%h %s", range }, slot.name(), .rebase_todo);
    weft.echo("rebase plan: edit the verbs, save to run, close to abandon");
}
/// The `git log` listing landed → rewrite `<hash> <subject>` lines into
/// `pick <hash> <subject>` in-place (git's todo, authored by us).
fn rebaseTodoFill() void {
    const text = weft.slice(0, weft.byteLen());
    var w: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        var le = i;
        while (le < text.len and text[le] != '\n') le += 1;
        if (le > i) {
            const seg = std.fmt.bufPrint(op_buf[w..], "pick {s}\n", .{text[i..le]}) catch break;
            w += seg.len;
        }
        i = le + 1;
    }
    weft.edit(.{ .start = 0, .end = weft.byteLen() }, op_buf[0..w]);
    weft.jump(0);
}
/// `save` in a rebase plan: hand the edited todo to git through the same
/// `GIT_SEQUENCE_EDITOR` mechanism, and let its exit status decide whether the
/// plan entry is spent. `GIT_EDITOR=true` keeps squash/fixup/reword
/// non-interactive; an `edit` stop just leaves a rebase the `r` menu drives.
fn gitRebaseSave() void {
    const slot = todos.current("rebase plan") orelse {
        weft.echo("no rebase plan here");
        return;
    };
    model.routed = sessionById(slot.value.session) orelse return; // a plan names its own repository
    const text = weft.slice(0, weft.byteLen());
    const n = @min(text.len, msg_buf.len);
    @memcpy(msg_buf[0..n], text[0..n]);
    const v = &slot.value;
    cur().sequencing = slot;
    // `{}` is the SPOOLED plan, substituted INSIDE the config value: git runs
    // `sequence.editor <todo>` while `git rebase -i` is still in flight, so the
    // temp is alive exactly when the `cp` needs it and gone the moment the
    // rebase returns — including a rebase that stopped on a conflict, where the
    // old in-repo plan used to linger.
    //
    // `-c` rather than an environment variable, because there is no shell to
    // set one in — and git's own config override is what the env var was
    // standing in for.
    afterNoted(&.{
        "git",
        "-c",
        "sequence.editor=cp {}",
        "-c",
        "core.editor=true",
        "rebase",
        "-i",
        v.base[0..v.base_len],
    }, msg_buf[0..n]);
}

/// A plan git ran is spent, and closes like any other entry; one it refused
/// stays, with the refusal shown — git.s own words, off its own stderr.
fn gitRebaseSettle() void {
    const slot = cur().sequencing orelse return;
    cur().sequencing = null;
    if (!cur().effect_ok) {
        weft.echo(cur().effect_note[0..cur().effect_note_len]);
        return;
    }
    // Retiring the entry is focus-scoped: land on it, then close it.
    if (focusBuffer(slot.name())) weft.run("buffer-close");
    todos.close(slot);
    _ = focusBuffer(cur().name());
    weft.echo("rebased");
}
fn gitRebaseContinue() void {
    after(&.{ "git", "-c", "core.editor=true", "rebase", "--continue" });
}
fn gitRebaseAbort() void {
    after(&.{ "git", "rebase", "--abort" });
}
fn gitRebaseSkip() void {
    after(&.{ "git", "-c", "core.editor=true", "rebase", "--skip" });
}

// ── Styling for the plain read-only views (diff/log) ────────────────────────
