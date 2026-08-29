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
const nodeAt = render_mod.nodeAt;
const setCollapsed = render_mod.setCollapsed;
const isCollapsed = render_mod.isCollapsed;
const findFile = render_mod.findFile;
const buildPatch = patch_mod.buildPatch;
const transient = @import("transient.zig");
const gather_mod = @import("gather.zig");
const show = gather_mod.show;
const showInput = gather_mod.showInput;
const gather = gather_mod.gather;
const gatherAfter = gather_mod.gatherAfter;
const gatherAfter1 = gather_mod.gatherAfter1;
const gatherAfterSeq = gather_mod.gatherAfterSeq;
const gatherAfterSeq1 = gather_mod.gatherAfterSeq1;
const gatherAfterPatch = gather_mod.gatherAfterPatch;
const markRestore = gather_mod.markRestore;
const selectedLines = render_mod.selectedLines;
const hashTokenAt = render_mod.hashTokenAt;
const offsetOf = render_mod.offsetOf;
const commitRow = render_mod.commitRow;
const nodeAtCursor = render_mod.nodeAtCursor;
const nameFile = render_mod.nameFile;
const fileTarget = render_mod.fileTarget;
const publishStyles = render_mod.publishStyles;
const publishFolds = render_mod.publishFolds;
const renderFile = render_mod.renderFile;
const toggleFileFold = render_mod.toggleFile;
const lineEnd = render_mod.lineEnd;
const countLines = render_mod.countLines;
const Kind = model.Kind;
const Fill = model.Fill;
const fillToken = model.fillToken;
const gathers = model.gathers;
const Node = model.Node;
const MARK_C = model.MARK_C;
const MARK_U = model.MARK_U;
const MARK_S = model.MARK_S;
const MARK_R = model.MARK_R;
const GATHER = model.GATHER;
const buf_base = model.buf_base;
const tool = model.tool;

var cmd_buf: [1 << 13]u8 = undefined;
var msg_buf: [1 << 16]u8 = undefined;

/// Buffer for building a rebase plan's todo lines + the transient op command.
var op_buf: [1 << 14]u8 = undefined;
/// The command handed to `procToBuffer`: the session's `cd` guard + the body.
var run_buf: [1 << 14]u8 = undefined;
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

export fn describe() void {
    for (cmds) |c| weft.declareCommand(c.name);
    // `{proc, timer}` and nothing else — the set `direnv` and `spool` have.
    // Every file git hands a subprocess is spooled by the host
    // (`weft.procSpool`), and every path it used to PROBE is inside the place
    // it already dispatches in (`weft.placeHas`), so there is no filesystem
    // question left for a grant to answer. `wasm_abi/tests.zig` asserts the
    // absence of both fs capabilities, so a regrant is loud.
    weft.requestPerm(.proc);
    weft.requestPerm(.timer);
}
export fn init() void {
    for (cmds) |c| _ = weft.register(c.name);
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
/// THE funnel. Two decisions live here and nowhere else: which repository
/// session the command is about, and whether the snapshot its arguments were
/// designated against is still the one the model holds.
export fn on_command(id: u32) void {
    if (id >= cmds.len) return;
    const c = cmds[id];
    const s = route(c.route) orelse return;
    model.routed = s;
    switch (c.scope) {
        .durable => {},
        .snapshot => if (!s.fresh()) return refuseStale(),
        .arm => if (!s.fresh()) return refuseStale(),
    }
    c.handler();
}

/// A path/hunk action whose snapshot the model has moved past does NOT act on
/// the shifted node: it says so and shows the current status instead.
fn refuseStale() void {
    weft.echo("git: stale — refreshed");
    // A gather in flight repaints on its own; otherwise show what IS current,
    // and only in the session's own buffer (never author someone else's).
    if (cur().fresh() and focusedSession() == model.routed) rerender();
}

// ── on_fill_token: the async output landed → parse + render + publish ──────

export fn on_fill_token(token: u32) void {
    // A token we never issued routes nowhere.
    const s = sessionById(token >> 8) orelse return;
    const fill = std.enums.fromInt(Fill, token & 0xff) orelse return;
    model.routed = s;
    if (gathers(fill)) {
        cur().gathering = false;
        cur().snapshot +%= 1;
    }
    switch (fill) {
        .none => {},
        .status => parseAndRender(),
        .diff => classify(styleDiffLine),
        .log => classify(styleLogLine),
        .rebase => rebaseTodoFill(),
        .draft => draftFill(),
        .commit => commitFill(),
        .sequence => sequenceFill(),
    }
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
/// a read clamps to the 64 KiB scratch). Cap at RAW_CAP and note truncation —
/// no silent drop.
fn loadRaw() void {
    const total = weft.byteLen();
    cur().raw_len = 0;
    cur().truncated_raw = false;
    while (cur().raw_len < total and cur().raw_len < RAW_CAP) {
        const chunk = weft.slice(cur().raw_len, total); // returns ≤ 64 KiB
        if (chunk.len == 0) break;
        const n = @min(chunk.len, RAW_CAP - cur().raw_len);
        @memcpy(cur().raw[cur().raw_len .. cur().raw_len + n], chunk[0..n]);
        cur().raw_len += n;
        if (n < chunk.len) break;
    }
    if (total > RAW_CAP) cur().truncated_raw = true;
}

/// Re-render the model over this session's buffer. The projection is
/// authored FIRST; styles and folds then index the new bytes. `render.zig`
/// owns every step, including the write — this is the name a verb calls.
const repaint = render_mod.repaint;

fn parseAndRender() void {
    loadRaw();
    renderStatus();
}

/// Model → projection, over whatever `raw` currently holds.
fn renderStatus() void {
    parser.parse();
    repaint();
    // Land the cursor: re-find the captured target after a mutation (so point
    // tracks the file/hunk/commit even when it moved), else the clamped offset,
    // else home.
    const landing = if (cur().restore_cursor)
        (offsetOf(cur().restore_target) orelse @min(cur().pending_cursor, cur().out))
    else
        cur().home_off;
    weft.jump(weft.lineAt(landing).start);
    cur().restore_cursor = false;
    cur().restore_target = .{};
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
    cur().restore_cursor = false;
    gather(GATHER);
    weft.setMode("git");
}

/// Start version control from inside the editor: `git init` in the project,
/// then gather straight into `*git*`. Without this, `git-status` on a
/// non-repo just shows an empty buffer and there is no in-editor way to create
/// the repo — you had to drop to a shell. Reuses the same gather scaffolding as
/// every other mutation (no git-init special-casing); after init, GATHER's
/// `git status --branch` renders the fresh `Branch: main` header.
fn gitInit() void {
    cur().restore_cursor = false;
    gatherAfterSeq("git init");
}
fn gitRefresh() void {
    markRestore();
    gather(GATHER);
    weft.setMode("git");
}

/// TAB: flip the fold of the section/file under point, re-render (no re-gather —
/// the model is intact), republish, and keep the cursor on the header.
fn gitToggleFold() void {
    const t = nodeAtCursor();
    const n = resolve(t) orelse return;
    // The head to keep point on, named by identity — it survives the re-render.
    const head: Target = switch (n.kind) {
        .section => blk: {
            cur().sec_folded[n.idx] = !cur().sec_folded[n.idx];
            break :blk t;
        },
        .file => blk: {
            toggleFile(n.idx);
            break :blk t;
        },
        // Fold the parent file (hunk-granularity folds are a later phase).
        .hunk => blk: {
            const fi = cur().hunks[n.idx].file;
            toggleFile(fi);
            break :blk fileTarget(fi);
        },
        else => return,
    };
    repaint();
    weft.jump(weft.lineAt(offsetOf(head) orelse 0).start);
    publishOffers(); // every node moved; point landed on a header
}

fn toggleFile(fi: usize) void {
    cur().files[fi].folded = !cur().files[fi].folded;
    setCollapsed(cur().files[fi].path_(), cur().files[fi].folded); // persist
}

/// Repaint the buffer from the model in hand — no re-gather, the model is
/// intact (a refused stale action showing what IS current). Authoring the whole
/// buffer moves point, so it lands back on its line.
fn rerender() void {
    const at = weft.cursor();
    repaint();
    weft.jump(weft.lineAt(@min(at, cur().out)).start);
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
            gatherAfter1("git add -- '{s}'", f.path_());
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
            gatherAfter1("git reset -q HEAD -- '{s}'", f.path_());
        },
        .section => {
            if (t.section != .staged) return;
            stageSection(t.section, false);
        },
        else => {},
    }
}

fn gitStageAll() void {
    gatherAfter("git add -A");
}
fn gitUnstageAll() void {
    gatherAfter("git reset -q HEAD");
}

/// Stage/unstage every file of a section (a section header operation).
fn stageSection(sec: Section, stage: bool) void {
    const verb = if (stage) "git add --" else "git reset -q HEAD --";
    var w: usize = 0;
    w += (std.fmt.bufPrint(cmd_buf[w..], "{s}", .{verb}) catch return).len;
    var any = false;
    var fi: usize = 0;
    while (fi < cur().file_count) : (fi += 1) {
        if (cur().files[fi].section != sec) continue;
        const seg = std.fmt.bufPrint(cmd_buf[w..], " '{s}'", .{cur().files[fi].path_()}) catch break;
        w += seg.len;
        any = true;
    }
    if (!any) return;
    gatherAfter(cmd_buf[0..w]);
}

// ── Discard (destructive — always confirmed) ────────────────────────────────
/// Arm a destructive verb: capture WHAT it targets now, ask, act later.
fn gitDiscard() void {
    const t = nodeAtCursor();
    const n = liveNode(t, "discard") orelse return;
    cur().pending_target = t;
    switch (n.kind) {
        .file => confirmPick(.discard, "discard changes to this file?"),
        .hunk => confirmPick(.discard, "discard this hunk?"),
        // `x` on a recent commit → the reset transient, scoped to that OID.
        .commit => {
            weft.echo("reset: s soft  m mixed  h hard");
            weft.setMode("git-reset-menu");
        },
        .section => confirmPick(.discard, "discard the whole section?"),
        .none => {},
    }
}
/// The confirmed destructive path. It acts on the target captured when the
/// question was asked, re-resolved against the live model — a target the model
/// no longer names (a background re-gather landed under the prompt) destroys
/// nothing.
fn gitDiscardDo() void {
    const t = cur().pending_target;
    cur().pending_target = .{};
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
                .untracked => gatherAfter1("rm -- '{s}'", f.path_()),
                .unstaged => gatherAfter1("git checkout -- '{s}'", f.path_()),
                .staged => {
                    const mut = std.fmt.bufPrint(&msg_buf, "git reset -q HEAD -- '{s}' && git checkout -- '{s}'", .{ f.path_(), f.path_() }) catch return;
                    gatherAfter(mut);
                },
                .recent => {},
            }
        },
        .section => discardSection(t.section),
        else => {},
    }
}

fn discardSection(sec: Section) void {
    // Compose a per-file discard for the whole section, then re-gather.
    var w: usize = 0;
    var any = false;
    var fi: usize = 0;
    while (fi < cur().file_count) : (fi += 1) {
        const f = &cur().files[fi];
        if (f.section != sec) continue;
        const seg = switch (sec) {
            .untracked => std.fmt.bufPrint(cmd_buf[w..], "rm -- '{s}'; ", .{f.path_()}),
            .unstaged => std.fmt.bufPrint(cmd_buf[w..], "git checkout -- '{s}'; ", .{f.path_()}),
            .staged => std.fmt.bufPrint(cmd_buf[w..], "git reset -q HEAD -- '{s}' && git checkout -- '{s}'; ", .{ f.path_(), f.path_() }),
            .recent => break,
        } catch break;
        w += seg.len;
        any = true;
    }
    if (!any) {
        weft.setMode("git");
        return;
    }
    gatherAfter(cmd_buf[0..w]);
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
    gatherAfterPatch(patch, if (reverse) "--cached --reverse" else "--cached", false);
}

/// Discard a hunk: reverse it out of the worktree; for a staged hunk, also drop
/// it from the index. Two `git apply`s, chained before the re-gather.
fn discardHunk(hi: usize, sel: ?Lines, staged: bool) void {
    const patch = buildPatch(hi, sel) orelse {
        weft.echo("git: patch too large");
        weft.setMode("git");
        return;
    };
    // Unstaged hunk: reverse it out of the worktree. Staged hunk: reverse it out
    // of the index (`--cached --reverse`) AND the worktree (the trailing
    // `--reverse` gatherAfterPatch adds) — git discards the change entirely.
    if (staged) gatherAfterPatch(patch, "--cached --reverse", true) else gatherAfterPatch(patch, "--reverse", false);
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
var commit_ok = false;
var commit_note: [512]u8 = undefined;
var commit_note_len: usize = 0;

/// Open a commit draft. `prefill` (or "") is a shell command whose stdout seeds
/// the message — `git log -1 --format=%B` for amend/reword.
fn openDraft(flags: []const u8, prefill: []const u8) ?*Drafts.Slot {
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
fn seedDraft(slot: *Drafts.Slot, prefill: []const u8) void {
    if (prefill.len == 0) return;
    show(prefill, slot.name(), .draft); // read from the draft's own repository
}

/// A seeded message landed — start at the top of it.
fn draftFill() void {
    weft.jump(0);
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
/// The exit status and git's own words come back through the `.commit` fill, so
/// the draft closes only when git accepted it.
fn gitCommitSave() void {
    const slot = currentDraft() orelse return;
    const text = weft.slice(0, weft.byteLen());
    if (std.mem.trim(u8, text, " \t\r\n").len == 0) {
        weft.echo("commit: the message is empty");
        return;
    }
    const n = @min(text.len, msg_buf.len);
    @memcpy(msg_buf[0..n], text[0..n]);
    const d = &slot.value;
    cur().committing = slot;
    // `{}` is the SPOOLED message: the host writes it, `git commit -F` reads it
    // (an absolute path outside the work tree is fine — git only opens it), and
    // the host removes it whether or not the commit was accepted.
    const cmd = std.fmt.bufPrint(
        &cmd_buf,
        "git commit {s} -F '{{}}' 2>&1; s=$?; " ++
            "printf '\\036\\036C%d\\n' \"$s\"; " ++ GATHER,
        .{d.flagsOf()},
    ) catch return;
    cur().restore_cursor = false;
    showInput(cmd, msg_buf[0..n], cur().name(), .commit);
}

/// The commit ran: git's own words and exit status precede the status gather.
fn commitFill() void {
    loadRaw();
    commit_ok = takeEffectOutcome();
    renderStatus();
    weft.run("git-commit-settle");
}
/// Split an "effect, then gather" fill: keep what the effect said, report
/// whether it succeeded, and leave `raw` holding the gather alone — a command's
/// prologue is not status.
fn takeEffectOutcome() bool {
    commit_note_len = 0;
    const ci = std.mem.indexOf(u8, cur().raw[0..cur().raw_len], MARK_C) orelse return false;
    commit_note_len = @min(ci, commit_note.len);
    @memcpy(commit_note[0..commit_note_len], cur().raw[0..commit_note_len]);
    var i = ci + MARK_C.len;
    var status: usize = 0;
    while (i < cur().raw_len and cur().raw[i] >= '0' and cur().raw[i] <= '9') : (i += 1) {
        status = status * 10 + (cur().raw[i] - '0');
    }
    if (i < cur().raw_len and cur().raw[i] == '\n') i += 1;
    std.mem.copyForwards(u8, cur().raw[0 .. cur().raw_len - i], cur().raw[i..cur().raw_len]);
    cur().raw_len -= i;
    return status == 0;
}

/// Deferred to a dispatching entry (like `git-note-drops-deliver`): a draft git
/// accepted is closed like any other entry; one it refused stays, with the
/// refusal shown.
fn gitCommitSettle() void {
    const slot = cur().committing orelse return;
    cur().committing = null;
    if (!commit_ok) {
        weft.echo(firstLine(commit_note[0..commit_note_len]));
        return;
    }
    // Retiring the entry is focus-scoped: land on it, then close it.
    if (focusBuffer(slot.name())) weft.run("buffer-close");
    drafts.close(slot);
    _ = focusBuffer(cur().name());
    weft.echo("committed");
}

fn firstLine(text: []const u8) []const u8 {
    var i: usize = 0;
    while (i < text.len) {
        var e = i;
        while (e < text.len and text[e] != '\n') e += 1;
        const line = std.mem.trim(u8, text[i..e], " \t\r");
        if (line.len > 0) return line;
        i = e + 1;
    }
    return "commit: refused";
}

// ── The draft's own offers (amend/reword/fixup/squash) ─────────────────────
// Each re-seats the draft under point: the entry stays, its meaning changes.
fn reseat(slot: *Drafts.Slot, flags: []const u8, prefill: []const u8, note: []const u8) void {
    setFlags(slot, flags);
    seedDraft(slot, prefill);
    weft.echo(note);
}
const head_message = "git log -1 --format=%B 2>/dev/null";
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
    const prefill = std.fmt.bufPrint(
        &op_buf,
        "git log -1 --format='{s}! %s' {s} 2>/dev/null",
        .{ kind, slot.value.onto.hash_() },
    ) catch return;
    reseat(slot, "", prefill, kind);
}

// ── Opening a draft from the status buffer ─────────────────────────────────
fn gitCommit() void {
    _ = openDraft("", "");
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
    gatherAfterSeq("git commit --amend --no-edit");
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
    const prefill = std.fmt.bufPrint(
        &op_buf,
        "git log -1 --format='{s}! %s' {s} 2>/dev/null",
        .{ kind, onto.hash_() },
    ) catch return;
    const slot = openDraft("", prefill) orelse return;
    slot.value.onto = onto;
}

// ── The SPC-g read-only views (unchanged behavior) ──────────────────────────
fn gitLog() void {
    show("git log --oneline --graph -30", "*git-log*", .log);
}
fn gitDiff() void {
    show("git diff", "*git-diff*", .diff);
}
fn gitDiffStaged() void {
    show("git diff --staged", "*git-diff-staged*", .diff);
}
fn gitBlame() void {
    // Absolute: the command runs in the repository, the buffer path may not be
    // spelled relative to it.
    const path = activePathAbs() orelse return;
    const cmd = std.fmt.bufPrint(&cmd_buf, "git blame -- '{s}'", .{path}) catch return;
    show(cmd, "*git-blame*", .none);
}

// ── Confirmation is an interaction, not a mode ─────────────────────────────
// A destructive verb asks through the pick membrane: the question is the
// prompt, the two candidates are the answer, and the pick id says which
// question was answered. No mode of git's own stands between the two.

/// Which question a pick answers.
const Confirm = enum(u32) { discard = 1, staged = 2, close = 3 };

/// Ask, safe answer first, so accepting the leading candidate changes nothing.
/// The id carries the session as well as the question, exactly as a fill token
/// does: repository 2's answer can only ever act on repository 2.
fn confirmPick(which: Confirm, question: []const u8) void {
    weft.pickBegin(question, @intFromEnum(which) | (cur().id << 8));
    weft.pickAdd("no", "leave it alone");
    weft.pickAdd("yes", "go ahead");
    weft.pickEnd();
}

/// Stage a full mutation behind that confirmation.
fn confirmThen(cmd: []const u8, question: []const u8) void {
    cur().confirm_len = @min(cmd.len, cur().confirm_cmd.len);
    @memcpy(cur().confirm_cmd[0..cur().confirm_len], cmd[0..cur().confirm_len]);
    confirmPick(.staged, question);
}

export fn on_pick_accept(pick_id: u32) void {
    // An id we never issued answers nothing.
    const s = sessionById(pick_id >> 8) orelse return;
    const question = std.enums.fromInt(Confirm, pick_id & 0xff) orelse return;
    model.routed = s;
    var outcome = (weft.pickOutcome(weft.allocator) catch return) orelse return;
    defer outcome.deinit(weft.allocator);
    const answer = switch (outcome) {
        .candidate => |c| c.text,
        .input => |typed| typed,
        .cancelled => "",
    };
    if (!std.mem.eql(u8, answer, "yes")) {
        weft.echo("cancelled");
        return;
    }
    switch (question) {
        // A discard acts on the target it captured, resolved against the live
        // model — `resolve` is the whole rule (a file re-resolves, a hunk is
        // snapshot-scoped), so nothing coarser belongs here.
        .discard => gitDiscardDo(),
        // The staged command is composed from refs and OIDs — durable.
        .staged => gatherAfterSeq(cur().confirm_cmd[0..cur().confirm_len]),
        // The entry the question was asked in is still the active one.
        .close => weft.run("buffer-close"),
    }
}

/// `close` in a draft or a rebase plan: its text is written work with no file
/// behind it, so dropping it ASKS. An empty one has nothing to lose and goes.
fn gitDraftClose() void {
    const text = weft.slice(0, weft.byteLen());
    if (std.mem.trim(u8, text, " \t\r\n").len == 0) {
        weft.run("buffer-close");
        return;
    }
    confirmPick(.close, "discard this draft?");
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
    const cmd = std.fmt.bufPrint(&cmd_buf, "git show {s}", .{t.hash_()}) catch return;
    show(cmd, "*git-show*", .diff);
    weft.setMode("git-view");
}
fn gitCherryPick() void {
    const t = commitAtCursor() orelse {
        weft.echo("cherry-pick: no commit under point");
        return;
    };
    gatherAfterSeq1("git cherry-pick {s}", t.hash_());
}
fn gitRevert() void {
    const t = commitAtCursor() orelse {
        weft.echo("revert: no commit under point");
        return;
    };
    gatherAfterSeq1("git revert --no-edit {s}", t.hash_());
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
    const m = std.fmt.bufPrint(&op_buf, "git reset {s} {s}", .{ kind, cur().pending_target.hash_() }) catch return;
    gatherAfterSeq(m);
}
fn gitResetHard() void {
    if (cur().pending_target.kind != .commit) return;
    const m = std.fmt.bufPrint(&op_buf, "git reset --hard {s}", .{cur().pending_target.hash_()}) catch return;
    confirmThen(m, "reset --hard (loses changes)?");
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
    gatherAfterSeq("git stash push");
}
fn gitStashPop() void {
    gatherAfterSeq("git stash pop");
}
fn gitStashApply() void {
    gatherAfterSeq("git stash apply");
}
fn gitStashList() void {
    show("git stash list", "*git-stash*", .none);
    weft.setMode("git-view");
}
fn gitStashDrop() void {
    confirmThen("git stash drop", "drop stash@{0}?");
}

// ── Log transient (the inline Recent section covers the common case) ────────
fn gitLogAll() void {
    show("git log --oneline --graph --all -50", "*git-log*", .log);
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
        .branch_checkout => gatherAfterSeq1("git checkout '{s}'", name),
        .branch_create => gatherAfterSeq1("git checkout -b '{s}'", name),
        .branch_new => gatherAfterSeq1("git branch '{s}'", name),
        .branch_rename => gatherAfterSeq1("git branch -m '{s}'", name),
        .branch_delete => {
            const cmd = std.fmt.bufPrint(&op_buf, "git branch -d '{s}'", .{name}) catch return;
            confirmThen(cmd, "delete branch?");
        },
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
    const cmd = std.fmt.bufPrint(&cmd_buf, "git log --reverse --format='%h %s' {s}..HEAD 2>/dev/null", .{base}) catch return;
    show(cmd, slot.name(), .rebase); // listed from the plan's own repository
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
    // `{}` is the SPOOLED plan. git runs `$GIT_SEQUENCE_EDITOR <todo>` while
    // `git rebase -i` is still in flight, so the temp is alive exactly when the
    // `cp` needs it and gone the moment the rebase returns — including a rebase
    // that stopped on a conflict, where the old in-repo plan used to linger.
    const cmd = std.fmt.bufPrint(
        &cmd_buf,
        "GIT_SEQUENCE_EDITOR='cp {{}}' GIT_EDITOR=true git rebase -i {s} 2>&1; s=$?; " ++
            "printf '\\036\\036C%d\\n' \"$s\"; " ++ GATHER,
        .{v.base[0..v.base_len]},
    ) catch return;
    cur().restore_cursor = false;
    showInput(cmd, msg_buf[0..n], cur().name(), .sequence);
}

fn sequenceFill() void {
    loadRaw();
    commit_ok = takeEffectOutcome();
    renderStatus();
    weft.run("git-rebase-settle");
}

/// Deferred to a dispatching entry: a plan git ran is spent, and closes like
/// any other entry; one it refused stays, with the refusal shown.
fn gitRebaseSettle() void {
    const slot = cur().sequencing orelse return;
    cur().sequencing = null;
    if (!commit_ok) {
        weft.echo(firstLine(commit_note[0..commit_note_len]));
        return;
    }
    // Retiring the entry is focus-scoped: land on it, then close it.
    if (focusBuffer(slot.name())) weft.run("buffer-close");
    todos.close(slot);
    _ = focusBuffer(cur().name());
    weft.echo("rebased");
}
fn gitRebaseContinue() void {
    gatherAfterSeq("GIT_EDITOR=true git rebase --continue");
}
fn gitRebaseAbort() void {
    gatherAfterSeq("git rebase --abort");
}
fn gitRebaseSkip() void {
    gatherAfterSeq("GIT_EDITOR=true git rebase --skip");
}

// ── Styling for the plain read-only views (diff/log) ────────────────────────
fn classify(line_fn: *const fn (base: usize, line: []const u8) void) void {
    weft.styleClear();
    const text = weft.slice(0, weft.byteLen());
    var i: usize = 0;
    while (i < text.len) {
        var e = i;
        while (e < text.len and text[e] != '\n') e += 1;
        line_fn(i, text[i..e]);
        i = e + 1;
    }
}

fn styleDiffLine(base: usize, line: []const u8) void {
    if (line.len == 0) return;
    const cls: weft.StyleClass = if (std.mem.startsWith(u8, line, "diff --git") or
        std.mem.startsWith(u8, line, "index "))
        .muted
    else if (std.mem.startsWith(u8, line, "+++ ") or std.mem.startsWith(u8, line, "--- "))
        .muted
    else if (std.mem.startsWith(u8, line, "@@"))
        .header
    else switch (line[0]) {
        '+' => .added,
        '-' => .removed,
        else => .normal,
    };
    if (cls != .normal) weft.style(base, base + line.len, cls);
}

fn styleLogLine(base: usize, line: []const u8) void {
    var i: usize = 0;
    while (i < line.len and isGraph(line[i])) i += 1;
    var h = i;
    while (h < line.len and isHex(line[h])) h += 1;
    if (h == i) return;
    weft.style(base + i, base + h, .location);
    var j = h;
    while (j < line.len and line[j] == ' ') j += 1;
    if (j < line.len and line[j] == '(') {
        var k = j;
        while (k < line.len and line[k] != ')') k += 1;
        if (k < line.len) k += 1;
        weft.style(base + j, base + k, .header);
    }
}

fn isGraph(c: u8) bool {
    return c == '*' or c == '|' or c == '/' or c == '\\' or c == ' ' or c == '_' or c == '.';
}
fn isHex(c: u8) bool {
    return (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f');
}
