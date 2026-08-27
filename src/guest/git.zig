//! git — git as a MODEL rendered into a foldable buffer (design §6.6), a
//! `.wasm` plugin. The `*git*` buffer is READ-ONLY and owned entirely by this
//! plugin: one combined `git status`/`git diff`/`git diff --cached`/`git log`
//! runs via `procToBuffer`, its raw output lands in the buffer that fill
//! captured, the host fires `on_fill_token`, and we PARSE that output into a
//! section→file→hunk tree then RE-RENDER the tree as pretty, foldable text over
//! the same buffer (`edit` + `styleClear`/`style` + `foldClear`/`fold`). Because
//! only we ever write the buffer, the parallel node table (each node's
//! `[start,end)` byte range) is never stale — "the thing under point" is the
//! node whose range contains
//! `weft.cursor()`, the pattern `consult.zig` uses.
//!
//! Staging is pure plugin logic: file → `git add`/`git reset`; hunk → synthesize
//! a one-file/one-hunk patch (kept diff header + the `@@` hunk) and
//! `git apply --cached [--reverse]`; a selected line-range → a PARTIAL hunk
//! (git's line algorithm: drop unselected `+`, turn unselected `-` into
//! context) applied the same way. Every mutation chains a re-gather in ONE shell
//! command so the buffer reflects the new index (the old `stageThenRefresh`
//! discipline). `k`/discard is destructive, gated behind a y/n confirm mode.
//!
//! A COMMIT DRAFT is not part of that projection: it is an ordinary instanced
//! text entry (`*git-commit*`, `*git-commit:2*`, …) with no mode and no keys of
//! its own. It is tool-backed, so `save` in it resolves to `git-commit-save` —
//! saving the draft IS the commit, aborting it is closing the entry, and
//! amend/reword/fixup/squash are offers that re-seat the draft rather than
//! commands with their own buffers. Each draft resolves its repository when it
//! opens, so a second repository's draft is genuinely a second entry.
//!
//! perms `{proc, timer, fs_write}` — fs_write drops each draft's message and the
//! synthesized patch into temp files. grant_max edit (it authors its own buffer).

const std = @import("std");
const weft = @import("weft");

// ── Caps (freestanding: no allocator, bounded static state; degrade loud) ──
const MAX_FILES = 128;
const MAX_HUNKS = 512;
const RAW_CAP = 1 << 18; // 256 KiB of raw git output (paged in via `slice`)
const RENDER_CAP = 1 << 18; // the pretty projection
const PATCH_CAP = 1 << 16; // a synthesized one-hunk patch

var cmd_buf: [1 << 13]u8 = undefined;
var msg_buf: [1 << 16]u8 = undefined;
var patch_buf: [PATCH_CAP]u8 = undefined;
/// Scratch for a partial hunk's transformed body (static — keeps it off the
/// small wasm stack).
var body_out: [PATCH_CAP]u8 = undefined;

/// Temp files, cwd-relative (the locus the shell command runs in). Removed by
/// the same command that consumes them.
const patch_tmp = ".weft-git.patch";
const rebase_tmp = ".weft-rebase.todo";

// ── Phase 2b/2c transient state (all bounded; see the caps note above) ──
/// The commit hash under point, captured when a commit-scoped verb (show/fixup/
/// squash/cherry-pick/revert/reset) fires — survives the mode hop into a submenu.
var pending_hash: [64]u8 = undefined;
var pending_hash_len: usize = 0;
/// A full mutation staged behind the generic y/n confirm (branch delete, stash
/// drop, reset --hard) — run verbatim by `git-confirm-yes`.
var confirm_cmd: [1 << 12]u8 = undefined;
var confirm_len: usize = 0;
/// Name typed into the `*git-input*` prompt (branch names, the rebase depth).
var input_name: [256]u8 = undefined;
var input_name_len: usize = 0;
const InputAction = enum(u8) { none, branch_checkout, branch_create, branch_new, branch_rename, branch_delete, rebase_start };
var input_action: InputAction = .none;
/// The rebase base ref (`HEAD~N`), used for both the todo listing and the finish.
var rebase_base: [64]u8 = undefined;
var rebase_base_len: usize = 0;
/// Buffer for building `*git-rebase*` todo lines + the transient op command.
var op_buf: [1 << 14]u8 = undefined;
// Push/pull/fetch flags accumulated in the (persistent, surface-rendered)
// transient modes; reset each time the transient is (re)opened.
var push_force = false;
var push_upstream = false;
var pull_rebase = false;
var fetch_all = false;
var fetch_prune = false;

/// ONE gather command: porcelain status (+ branch), the unstaged diff, the
/// staged diff, and recent commits, delimited by RS-prefixed sentinel lines we
/// can split on unambiguously (`\x1e\x1e{U,S,R}`). We repaint the buffer from
/// the parse, so these markers never reach the user's eyes.
const GATHER =
    "git status --porcelain=v1 --branch 2>/dev/null; " ++
    "printf '\\036\\036U\\n'; git diff 2>/dev/null; " ++
    "printf '\\036\\036S\\n'; git diff --cached 2>/dev/null; " ++
    "printf '\\036\\036R\\n'; git log --format='%h %s' -10 2>/dev/null; " ++
    "printf '\\036\\036T\\n'; git rev-parse --show-toplevel 2>/dev/null";
const MARK_U = "\x1e\x1eU";
const MARK_S = "\x1e\x1eS";
const MARK_R = "\x1e\x1eR";
const MARK_T = "\x1e\x1eT";
/// Precedes `git commit`'s exit status in the commit fill.
const MARK_C = "\x1e\x1eC";

const buf_name = "*git*";

// ── The model ────────────────────────────────────────────────────────────
const Section = enum(u8) { untracked = 0, unstaged = 1, staged = 2, recent = 3 };
const render_order = [_]Section{ .untracked, .unstaged, .staged, .recent };

const File = struct {
    section: Section,
    path: [256]u8 = undefined,
    plen: usize = 0,
    idx_ch: u8 = ' ', // porcelain X (index/staged column)
    wt_ch: u8 = ' ', // porcelain Y (worktree/unstaged column)
    // The file's diff preamble (`diff --git`/`index`/`---`/`+++`) in `raw` — the
    // header git apply needs in front of any single hunk. 0 len ⇒ no diff (e.g.
    // an untracked file: file-level staging only).
    header_off: usize = 0,
    header_len: usize = 0,
    first_hunk: usize = 0,
    n_hunks: usize = 0,
    folded: bool = false,
    // Rendered byte ranges (recorded each render): whole block, and the offset
    // its body (first hunk) begins so a fold keeps the file header visible.
    r_start: usize = 0,
    r_end: usize = 0,
    body: usize = 0, // == first hunk r_start; 0 when n_hunks == 0
    fn path_(self: *const File) []const u8 {
        return self.path[0..self.plen];
    }
};

const Hunk = struct {
    file: usize,
    at: usize, // `@@` line through end of body, in `raw`
    len: usize,
    r_start: usize = 0, // rendered verbatim, so raw↔render is a fixed shift
    r_end: usize = 0,
};

var files: [MAX_FILES]File = undefined;
var file_count: usize = 0;
var hunks: [MAX_HUNKS]Hunk = undefined;
var hunk_count: usize = 0;

var raw: [RAW_CAP]u8 = undefined;
var raw_len: usize = 0;
var render_buf: [RENDER_CAP]u8 = undefined;
var out: usize = 0;

var branch: [256]u8 = undefined;
var branch_len: usize = 0;
// Whether the porcelain gave us a `## ` line — i.e. cwd IS a git repo. A fresh
// repo with no commits still emits `## No commits yet on <branch>`, so absence
// means "not a repository" (git exited 128), not "empty repo".
var in_repo: bool = false;
var recent_start: usize = 0; // recent-commits region in `raw`
var recent_end: usize = 0;
/// The repository this gather described (its worktree root). A commit draft
/// copies it when it opens, so the draft keeps committing to the repository it
/// was written for even after the status buffer moves on.
var repo_root: [256]u8 = undefined;
var repo_root_len: usize = 0;

/// Section fold state PERSISTS across gathers (indexed by Section) — so a
/// collapsed Recent stays collapsed through a refresh/stage. Files rebuild each
/// gather (default expanded); only the section posture is remembered. Recent
/// defaults EXPANDED so a commit is directly actionable (RET/A/V/x/fixup) on a
/// fresh `*git*` without a TAB first; TAB still toggles it.
var sec_folded = [_]bool{ false, false, false, false };
var sec_present = [_]bool{ false, false, false, false };
var sec_rstart = [_]usize{ 0, 0, 0, 0 };
var sec_rend = [_]usize{ 0, 0, 0, 0 };
var sec_body = [_]usize{ 0, 0, 0, 0 }; // fold start: just past the header newline
var sec_count = [_]usize{ 0, 0, 0, 0 };

/// FILE fold state also persists — but files rebuild each gather, so we can't
/// carry a bool on the struct. Instead remember a bounded set of COLLAPSED file
/// paths; a file the user folds stays folded through refreshes. Past the cap we
/// echo and stop recording (degrade loud, never silently drop). Keyed by path
/// only, so the same path partially staged in two sections shares fold state.
const MAX_COLLAPSED = 64;
var collapsed_paths: [MAX_COLLAPSED][256]u8 = undefined;
var collapsed_plen: [MAX_COLLAPSED]usize = undefined;
var collapsed_count: usize = 0;

// Cursor restoration across a re-gather. Rather than a clamped byte offset
// (which drifts when a file hops sections), we capture the IDENTITY of the node
// under point before a mutation — section + file path + hunk ordinal, or a
// recent commit's hash — and the status fill re-finds it in the NEW model,
// landing on its rendered start. `pending_cursor` is the fallback when the node is gone
// (e.g. the file was fully staged away). `home_off` is where a fresh open lands.
var restore_cursor = false;
var pending_cursor: usize = 0;
var home_off: usize = 0;
const RestoreKind = enum { none, section, file, hunk, commit };
var restore_kind: RestoreKind = .none;
var restore_section: Section = .untracked;
var restore_path: [256]u8 = undefined;
var restore_plen: usize = 0;
var restore_hunk_ord: usize = 0; // the hunk's ordinal within its file
var restore_hash: [64]u8 = undefined;
var restore_hlen: usize = 0;

var dropped_files = false;
var dropped_hunks = false;
var truncated_raw = false;

// ── Commands ──────────────────────────────────────────────────────────────
const Cmd = struct { name: []const u8, handler: *const fn () void };
const cmds = [_]Cmd{
    .{ .name = "git-status", .handler = gitStatus },
    .{ .name = "git-init", .handler = gitInit },
    .{ .name = "git-refresh", .handler = gitRefresh },
    .{ .name = "git-toggle-fold", .handler = gitToggleFold },
    .{ .name = "git-stage", .handler = gitStage },
    .{ .name = "git-unstage", .handler = gitUnstage },
    .{ .name = "git-stage-all", .handler = gitStageAll },
    .{ .name = "git-unstage-all", .handler = gitUnstageAll },
    .{ .name = "git-discard", .handler = gitDiscard },
    .{ .name = "git-discard-do", .handler = gitDiscardDo },
    .{ .name = "git-discard-cancel", .handler = gitDiscardCancel },
    .{ .name = "git-visit", .handler = gitVisit },
    .{ .name = "git-commit", .handler = gitCommit },
    // Saving a draft entry IS its commit; the settle runs on the fill's way back.
    .{ .name = "git-commit-save", .handler = gitCommitSave },
    .{ .name = "git-commit-settle", .handler = gitCommitSettle },
    // Commit dispatch (the `c` transient): each opens a draft for the commit it
    // means; fixup/squash resolve the commit under point into its message.
    .{ .name = "git-amend", .handler = gitAmend },
    .{ .name = "git-extend", .handler = gitExtend },
    .{ .name = "git-reword", .handler = gitReword },
    .{ .name = "git-fixup", .handler = gitFixup },
    .{ .name = "git-squash", .handler = gitSquash },
    // The draft entry's own offers — they re-seat the draft under point.
    .{ .name = "git-draft-amend", .handler = gitDraftAmend },
    .{ .name = "git-draft-reword", .handler = gitDraftReword },
    .{ .name = "git-draft-fixup", .handler = gitDraftFixup },
    .{ .name = "git-draft-squash", .handler = gitDraftSquash },
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
    // The `*git-input*` prompt (branch names / rebase depth).
    .{ .name = "git-input-finish", .handler = gitInputFinish },
    .{ .name = "git-input-abort", .handler = gitInputAbort },
    .{ .name = "git-input-resume", .handler = gitInputResume },
    // Push/pull/fetch flag transients (toggle flags, then execute).
    .{ .name = "git-push", .handler = gitPush },
    .{ .name = "git-pull", .handler = gitPull },
    .{ .name = "git-fetch", .handler = gitFetch },
    .{ .name = "git-push-toggle-force", .handler = gitPushToggleForce },
    .{ .name = "git-push-toggle-upstream", .handler = gitPushToggleUpstream },
    .{ .name = "git-push-do", .handler = gitPushDo },
    .{ .name = "git-pull-toggle-rebase", .handler = gitPullToggleRebase },
    .{ .name = "git-pull-do", .handler = gitPullDo },
    .{ .name = "git-fetch-toggle-all", .handler = gitFetchToggleAll },
    .{ .name = "git-fetch-toggle-prune", .handler = gitFetchTogglePrune },
    .{ .name = "git-fetch-do", .handler = gitFetchDo },
    // Interactive rebase (Phase 2c).
    .{ .name = "git-rebase-interactive", .handler = gitRebaseInteractive },
    .{ .name = "git-rebase-continue", .handler = gitRebaseContinue },
    .{ .name = "git-rebase-abort", .handler = gitRebaseAbort },
    .{ .name = "git-rebase-skip", .handler = gitRebaseSkip },
    .{ .name = "git-rebase-pick", .handler = gitRebasePick },
    .{ .name = "git-rebase-squash", .handler = gitRebaseSquash },
    .{ .name = "git-rebase-edit", .handler = gitRebaseEdit },
    .{ .name = "git-rebase-reword", .handler = gitRebaseReword },
    .{ .name = "git-rebase-fixup", .handler = gitRebaseFixup },
    .{ .name = "git-rebase-drop", .handler = gitRebaseDrop },
    .{ .name = "git-rebase-finish", .handler = gitRebaseFinish },
    .{ .name = "git-rebase-cancel", .handler = gitRebaseCancel },
    .{ .name = "git-rebase-resume", .handler = gitRebaseResume },
    // Generic y/n confirm + menu-leave helpers.
    .{ .name = "git-confirm-yes", .handler = gitConfirmYes },
    .{ .name = "git-confirm-no", .handler = gitConfirmNo },
    .{ .name = "git-menu-cancel", .handler = gitMenuCancel },
    .{ .name = "git-menu-cancel-surface", .handler = gitMenuCancelSurface },
    // Kept for the SPC-g leader menu: read-only views into their own buffers.
    .{ .name = "git-log", .handler = gitLog },
    .{ .name = "git-diff", .handler = gitDiff },
    .{ .name = "git-diff-staged", .handler = gitDiffStaged },
    .{ .name = "git-blame", .handler = gitBlame },
    // Internal: the deferred half of `noteDrops` (task #19 item 4) — not a
    // user-facing verb, invoked only via `weft.run` from `on_fill_token`.
    .{ .name = "git-note-drops-deliver", .handler = gitNoteDropsDeliver },
};

export fn describe() void {
    for (cmds) |c| weft.declareCommand(c.name);
    weft.requestPerm(.proc);
    weft.requestPerm(.timer);
    weft.requestPerm(.fs_write);
    // fs_read: detect an in-progress rebase (.git/rebase-{merge,apply}).
    weft.requestPerm(.fs_read);
}
export fn init() void {
    for (cmds) |c| _ = weft.register(c.name);
    // git mode: navigation-only plus the interactive verbs. It declares no
    // text commit, so typing can never reach the read-only status buffer.
    // A read-only projection: its keymap is PINNED — you can't drop into a
    // generic editing mode (`normal`) inside it, so git's keys never go dead.
    // The framework enforces it; git just declares it (no defensive handling).
    weft.lockedMode("git");
    weft.bindKey("git", "j", "cursor-down"); // fold-aware in core
    weft.bindKey("git", "k", "cursor-up");
    weft.bindKey("git", "Down", "cursor-down");
    weft.bindKey("git", "Up", "cursor-up");
    weft.bindKey("git", "Tab", "git-toggle-fold");
    weft.bindKey("git", "s", "git-stage");
    weft.bindKey("git", "u", "git-unstage");
    weft.bindKey("git", "S", "git-stage-all");
    weft.bindKey("git", "U", "git-unstage-all");
    // Discard is destructive; `x` (not git's `k`, which we spend on vim-style
    // up-motion) enters the y/n confirm before anything is thrown away.
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
    weft.bindKey("git", "P", "git-push");
    weft.bindKey("git", "F", "git-pull");
    weft.bindKey("git", "f", "git-fetch");
    weft.bindKey("git", "g", "git-refresh");
    // RET dispatches: file/hunk → visit; commit → show.
    weft.bindKey("git", "Return", "git-visit");
    weft.bindKey("git", "q", "buffer-back");

    // Discard confirm: a tiny menu mode — y does it, n/Escape backs out.
    weft.menuMode("git-confirm");
    weft.bindKey("git-confirm", "y", "git-discard-do");
    weft.bindKey("git-confirm", "n", "git-discard-cancel");
    weft.bindKey("git-confirm", "Escape", "git-discard-cancel");
    weft.bindKey("git-confirm", "C-g", "git-discard-cancel");

    // A GENERIC y/n confirm (branch delete, stash drop, reset --hard): y runs the
    // staged `confirm_cmd`, n/Escape backs out. One menu, many destructive verbs.
    weft.menuMode("git-confirm2");
    weft.bindKey("git-confirm2", "y", "git-confirm-yes");
    weft.bindKey("git-confirm2", "n", "git-confirm-no");
    weft.bindKey("git-confirm2", "Escape", "git-confirm-no");
    weft.bindKey("git-confirm2", "C-g", "git-confirm-no");

    // A commit draft owns NO mode and NO keys: it is an ordinary text entry in
    // the configuration's own editing modes. Its tool identity is what makes it
    // a draft, and `save` in it resolves here instead of to a file write — so
    // `:w`, `SPC f s`, and the palette's `std.persistence.save` all commit it.
    weft.provide("save", .{ .tool = draft_tool }, "git-commit-save", 10);
    // What else a draft affords, offered rather than bound.
    weft.provide("plugin.git.amend", .{ .tool = draft_tool }, "git-draft-amend", 0);
    weft.provide("plugin.git.reword", .{ .tool = draft_tool }, "git-draft-reword", 0);
    weft.provide("plugin.git.fixup", .{ .tool = draft_tool }, "git-draft-fixup", 0);
    weft.provide("plugin.git.squash", .{ .tool = draft_tool }, "git-draft-squash", 0);

    // Commit dispatch (`c`): a which-key transient. Each key is terminal, so the
    // core's one-shot menu auto-return lands back in git for free.
    weft.menuMode("git-commit-dispatch");
    weft.bindKey("git-commit-dispatch", "c", "git-commit");
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

    // A generic single-line prompt buffer (branch names, rebase depth). Same
    // editable shape as the commit buffer; the pending `input_action` routes it.
    weft.setFallback("git-input", "default");
    weft.textInput("git-input", "insert-text");
    weft.bindKey("git-input", "C-c", "git-input-menu");
    weft.menuMode("git-input-menu");
    weft.bindKey("git-input-menu", "C-c", "git-input-finish");
    weft.bindKey("git-input-menu", "C-k", "git-input-abort");
    weft.bindKey("git-input-menu", "Escape", "git-input-resume");
    weft.bindKey("git-input-menu", "C-g", "git-input-resume");

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

    // The rebase-todo buffer is STRUCTURAL: the action letters set the todo
    // verb on the current line, `default`'s editing keys reorder lines, and
    // C-c finishes/aborts. It commits no typed text — a todo list is a list of
    // verbs, not prose.
    weft.setFallback("git-rebase", "default");
    weft.bindKey("git-rebase", "p", "git-rebase-pick");
    weft.bindKey("git-rebase", "s", "git-rebase-squash");
    weft.bindKey("git-rebase", "e", "git-rebase-edit");
    weft.bindKey("git-rebase", "r", "git-rebase-reword");
    weft.bindKey("git-rebase", "f", "git-rebase-fixup");
    weft.bindKey("git-rebase", "d", "git-rebase-drop");
    weft.bindKey("git-rebase", "k", "git-rebase-drop");
    weft.bindKey("git-rebase", "C-c", "git-rebase-cc");
    weft.menuMode("git-rebase-cc");
    weft.bindKey("git-rebase-cc", "C-c", "git-rebase-finish");
    weft.bindKey("git-rebase-cc", "C-k", "git-rebase-cancel");
    weft.bindKey("git-rebase-cc", "Escape", "git-rebase-resume");
    weft.bindKey("git-rebase-cc", "C-g", "git-rebase-resume");

    // A shared read-only view mode for the show/log/stash buffers (own their own
    // buffers, so git's mutating keys never fire against a stale model).
    weft.lockedMode("git-view"); // read-only projection: keymap pinned (see git)
    weft.bindKey("git-view", "j", "cursor-down");
    weft.bindKey("git-view", "k", "cursor-up");
    weft.bindKey("git-view", "Down", "cursor-down");
    weft.bindKey("git-view", "Up", "cursor-up");
    weft.bindKey("git-view", "g", "git-status");
    weft.bindKey("git-view", "q", "git-status");
}
export fn on_command(id: u32) void {
    if (id < cmds.len) cmds[id].handler();
}

// ── on_fill_token: the async output landed → parse + render + publish ──────
/// Which fill a `show` issued. Declared at spawn, handed back at delivery, so
/// the landing output routes to its own handler — never to whichever buffer
/// happens to be focused when the command finishes.
const Fill = enum(u32) {
    none = 0, // nothing to do after
    status, // the `*git*` projection: parse the raw output into the model
    diff, // a raw diff/show listing: color it
    log, // a `git log` listing: color it
    rebase, // the rebase todo: rewrite into editable `pick …` lines
    draft, // a commit draft's repository + seeded message
    commit, // a commit's outcome, ahead of the status gather
};

export fn on_fill_token(token: u32) void {
    // A token we never issued routes nowhere.
    switch (std.enums.fromInt(Fill, token) orelse return) {
        .none => {},
        .status => parseAndRender(),
        .diff => classify(styleDiffLine),
        .log => classify(styleLogLine),
        .rebase => rebaseTodoFill(),
        .draft => draftFill(),
        .commit => commitFill(),
    }
}

/// Pull the buffer's raw bytes into `raw` (paged in `slice`-sized windows, since
/// a read clamps to the 64 KiB scratch). Cap at RAW_CAP and note truncation —
/// no silent drop.
fn loadRaw() void {
    const total = weft.byteLen();
    raw_len = 0;
    truncated_raw = false;
    while (raw_len < total and raw_len < RAW_CAP) {
        const chunk = weft.slice(raw_len, total); // returns ≤ 64 KiB
        if (chunk.len == 0) break;
        const n = @min(chunk.len, RAW_CAP - raw_len);
        @memcpy(raw[raw_len .. raw_len + n], chunk[0..n]);
        raw_len += n;
        if (n < chunk.len) break;
    }
    if (total > RAW_CAP) truncated_raw = true;
}

fn parseAndRender() void {
    loadRaw();
    renderStatus();
}

/// Model → projection, over whatever `raw` currently holds.
fn renderStatus() void {
    parse();
    render();
    // The projection is authored FIRST; styles/folds then index the new bytes.
    weft.edit(.{ .start = 0, .end = weft.byteLen() }, render_buf[0..out]);
    publishStyles();
    publishFolds();
    // Land the cursor: re-find the captured node identity after a mutation (so
    // point tracks the file/hunk/commit even when it moved), else the clamped
    // offset, else home.
    const target = if (restore_cursor)
        (findIdentityOffset() orelse @min(pending_cursor, out))
    else
        home_off;
    weft.jump(weft.lineAt(target).start);
    restore_cursor = false;
    restore_kind = .none;
    noteDrops();
}

/// `noteDrops` is only ever reached from `on_fill_token` (BACKGROUND — see the
/// on_fill_token body above: it's the tail of `parseAndRender`, called nowhere
/// else). `weft.echo` is head-gated (task #19 item 4), so the actual
/// echoes defer through a self-registered command: a nested `weft.run` from
/// a background entry IS a dispatching entry for its duration (the same
/// door an async LSP response uses — see `src/guest/lsp.zig`'s identical
/// pattern), so `gitNoteDropsDeliver` below runs with a real dispatching
/// head.
fn noteDrops() void {
    if (dropped_files or dropped_hunks or truncated_raw) weft.run("git-note-drops-deliver");
}

fn gitNoteDropsDeliver() void {
    if (dropped_files) weft.echo("git: >128 files — some omitted");
    if (dropped_hunks) weft.echo("git: >512 hunks — some omitted");
    if (truncated_raw) weft.echo("git: output > 256 KiB — diff truncated");
}

// ── Parse ──────────────────────────────────────────────────────────────────
fn parse() void {
    file_count = 0;
    hunk_count = 0;
    branch_len = 0;
    in_repo = false;
    recent_start = 0;
    recent_end = 0;
    dropped_files = false;
    dropped_hunks = false;
    for (0..4) |i| {
        sec_present[i] = false;
        sec_count[i] = 0;
    }
    const data = raw[0..raw_len];
    // Split on the sentinels. A missing marker ⇒ the command failed; render
    // whatever prefix we have (usually just the branch header).
    const ui = std.mem.indexOf(u8, data, MARK_U) orelse data.len;
    const si = std.mem.indexOf(u8, data, MARK_S) orelse data.len;
    const ri = std.mem.indexOf(u8, data, MARK_R) orelse data.len;
    const ti = std.mem.indexOf(u8, data, MARK_T) orelse data.len;
    parsePorcelain(0, ui);
    if (ui < si) parseDiff(ui + MARK_U.len, si, .unstaged);
    if (si < ri) parseDiff(si + MARK_S.len, ri, .staged);
    if (ri < ti) {
        recent_start = ri + MARK_R.len;
        recent_end = ti;
    }
    repo_root_len = 0;
    if (ti < data.len) {
        const root = std.mem.trim(u8, data[ti + MARK_T.len ..], " \t\r\n");
        repo_root_len = @min(root.len, repo_root.len);
        @memcpy(repo_root[0..repo_root_len], root[0..repo_root_len]);
    }
    // Re-apply the remembered file-fold state (files rebuilt default-expanded).
    for (files[0..file_count]) |*f| f.folded = isCollapsed(f.path_());
    // Present iff non-empty (recent by commit lines).
    for (render_order) |sec| {
        const idx = @intFromEnum(sec);
        if (sec == .recent) {
            sec_count[idx] = countLines(recent_start, recent_end);
        } else {
            var c: usize = 0;
            for (files[0..file_count]) |f| if (f.section == sec) {
                c += 1;
            };
            sec_count[idx] = c;
        }
        sec_present[idx] = sec_count[idx] > 0;
    }
}

fn parsePorcelain(s: usize, e: usize) void {
    var i = s;
    while (i < e) {
        const ls = i;
        var le = i;
        while (le < e and raw[le] != '\n') le += 1;
        i = le + 1;
        const line = raw[ls..le];
        if (line.len == 0) continue;
        if (std.mem.startsWith(u8, line, "## ")) {
            in_repo = true;
            const b = std.mem.trim(u8, line[3..], " \t\r");
            branch_len = @min(b.len, branch.len);
            @memcpy(branch[0..branch_len], b[0..branch_len]);
            continue;
        }
        if (line.len < 3) continue;
        const x = line[0];
        const y = line[1];
        var pth = std.mem.trim(u8, line[3..], " \t\r");
        // Rename: "old -> new" — track the new path (what the diff names).
        if (std.mem.indexOf(u8, pth, " -> ")) |ai| pth = pth[ai + 4 ..];
        pth = dequote(pth);
        if (x == '?' and y == '?') {
            addFile(.untracked, pth, x, y);
            continue;
        }
        if (x != ' ' and x != '?') addFile(.staged, pth, x, y);
        if (y != ' ' and y != '?') addFile(.unstaged, pth, x, y);
    }
}

/// Best-effort unquote of a porcelain C-quoted path (spaces/specials). We drop
/// the surrounding quotes but don't unescape — a corner enough case to note, not
/// solve, in 2a.
fn dequote(pth: []const u8) []const u8 {
    if (pth.len >= 2 and pth[0] == '"' and pth[pth.len - 1] == '"') return pth[1 .. pth.len - 1];
    return pth;
}

fn addFile(section: Section, pth: []const u8, x: u8, y: u8) void {
    if (file_count >= MAX_FILES) {
        dropped_files = true;
        return;
    }
    var f = &files[file_count];
    f.* = .{ .section = section, .idx_ch = x, .wt_ch = y };
    f.plen = @min(pth.len, f.path.len);
    @memcpy(f.path[0..f.plen], pth[0..f.plen]);
    file_count += 1;
}

fn parseDiff(ds: usize, de: usize, sec: Section) void {
    var i = ds;
    var cur: ?usize = null;
    var hstart: ?usize = null;
    while (i < de) {
        const ls = i;
        var le = i;
        while (le < de and raw[le] != '\n') le += 1;
        i = le + 1;
        const line = raw[ls..le];
        if (std.mem.startsWith(u8, line, "diff --git ")) {
            closeHunk(&hstart, cur, ls);
            cur = findFile(sec, pathFromDiffGit(line));
            if (cur) |fi| {
                files[fi].header_off = ls;
                files[fi].header_len = 0; // set at the first @@
                files[fi].first_hunk = hunk_count;
                files[fi].n_hunks = 0;
            }
        } else if (std.mem.startsWith(u8, line, "@@")) {
            if (cur) |fi| {
                if (files[fi].header_len == 0) files[fi].header_len = ls - files[fi].header_off;
            }
            closeHunk(&hstart, cur, ls);
            hstart = ls;
        }
    }
    closeHunk(&hstart, cur, de);
}

fn closeHunk(hstart: *?usize, cur: ?usize, end: usize) void {
    const s = hstart.* orelse return;
    hstart.* = null;
    const fi = cur orelse return;
    if (hunk_count >= MAX_HUNKS) {
        dropped_hunks = true;
        return;
    }
    hunks[hunk_count] = .{ .file = fi, .at = s, .len = end - s };
    hunk_count += 1;
    files[fi].n_hunks += 1;
}

fn pathFromDiffGit(line: []const u8) []const u8 {
    if (std.mem.indexOf(u8, line, " b/")) |bi| return std.mem.trimEnd(u8, line[bi + 3 ..], " \t\r");
    return "";
}

// ── Persisted file-fold set (collapsed paths survive a re-gather) ───────────
fn collapsedIndex(pth: []const u8) ?usize {
    var i: usize = 0;
    while (i < collapsed_count) : (i += 1) {
        if (std.mem.eql(u8, collapsed_paths[i][0..collapsed_plen[i]], pth)) return i;
    }
    return null;
}
fn isCollapsed(pth: []const u8) bool {
    return collapsedIndex(pth) != null;
}
/// Remember (or forget) a file's collapsed state. Bounded — a full set echoes
/// and refuses the new entry rather than dropping silently.
fn setCollapsed(pth: []const u8, on: bool) void {
    if (on) {
        if (collapsedIndex(pth) != null) return;
        if (collapsed_count >= MAX_COLLAPSED) {
            weft.echo("git: >64 folded files — this fold won't persist");
            return;
        }
        const n = @min(pth.len, collapsed_paths[collapsed_count].len);
        @memcpy(collapsed_paths[collapsed_count][0..n], pth[0..n]);
        collapsed_plen[collapsed_count] = n;
        collapsed_count += 1;
    } else if (collapsedIndex(pth)) |i| {
        // swap-remove (order doesn't matter).
        collapsed_count -= 1;
        collapsed_paths[i] = collapsed_paths[collapsed_count];
        collapsed_plen[i] = collapsed_plen[collapsed_count];
    }
}

fn findFile(sec: Section, pth: []const u8) ?usize {
    if (pth.len == 0) return null;
    var i: usize = 0;
    while (i < file_count) : (i += 1) {
        if (files[i].section == sec and std.mem.eql(u8, files[i].path_(), pth)) return i;
    }
    return null;
}

fn countLines(s: usize, e: usize) usize {
    var n: usize = 0;
    var i = s;
    while (i < e) {
        var le = i;
        while (le < e and raw[le] != '\n') le += 1;
        if (le > i) n += 1;
        i = le + 1;
    }
    return n;
}

// ── Render: the model → pretty, foldable text (offsets recorded into nodes) ──
fn put(bytes: []const u8) void {
    const n = @min(bytes.len, render_buf.len - out);
    @memcpy(render_buf[out .. out + n], bytes[0..n]);
    out += n;
}
fn putNum(n: usize) void {
    var b: [20]u8 = undefined;
    put(std.fmt.bufPrint(&b, "{d}", .{n}) catch return);
}

fn secTitle(sec: Section) []const u8 {
    return switch (sec) {
        .untracked => "Untracked files",
        .unstaged => "Unstaged changes",
        .staged => "Staged changes",
        .recent => "Recent commits",
    };
}

fn statusLabel(f: *const File) []const u8 {
    // The relevant column: index for a staged node, worktree otherwise.
    const c = if (f.section == .staged) f.idx_ch else f.wt_ch;
    return switch (c) {
        'M' => "modified  ",
        'A' => "new file  ",
        'D' => "deleted   ",
        'R' => "renamed   ",
        'C' => "copied    ",
        else => "",
    };
}

fn render() void {
    out = 0;
    home_off = 0;
    // Not in a repo: say so plainly rather than a fake `Branch: (no branch)`.
    // `SPC g i` (git-init) is the natural next move from here.
    if (!in_repo) {
        put("Not a git repository.\n\nRun git-init (SPC g i) to start one.\n");
        return;
    }
    // Branch header.
    put("Branch: ");
    if (branch_len > 0) put(branch[0..branch_len]) else put("(no branch)");
    put("\n\n");

    for (render_order) |sec| {
        const idx = @intFromEnum(sec);
        if (!sec_present[idx]) continue;
        sec_rstart[idx] = out;
        put(if (sec_folded[idx]) "\xe2\x96\xb8 " else "\xe2\x96\xbe "); // ▸ / ▾
        put(secTitle(sec));
        put(" (");
        putNum(sec_count[idx]);
        put(")\n");
        sec_body[idx] = out; // fold start: header stays visible
        if (sec == .recent) {
            renderRecent();
        } else {
            var fi: usize = 0;
            while (fi < file_count) : (fi += 1) {
                if (files[fi].section != sec) continue;
                renderFile(fi);
                if (home_off == 0) home_off = files[fi].r_start;
            }
        }
        sec_rend[idx] = out;
        put("\n"); // separator, outside the fold
    }
    if (home_off == 0) {
        // No files: land on the first present section header, else the top.
        for (render_order) |sec| {
            if (sec_present[@intFromEnum(sec)]) {
                home_off = sec_rstart[@intFromEnum(sec)];
                break;
            }
        }
    }
}

fn renderFile(fi: usize) void {
    var f = &files[fi];
    f.r_start = out;
    put("  ");
    if (f.n_hunks > 0) put(if (f.folded) "\xe2\x96\xb8 " else "\xe2\x96\xbe ");
    put(statusLabel(f));
    put(f.path_());
    put("\n");
    f.body = out;
    var h = f.first_hunk;
    while (h < f.first_hunk + f.n_hunks) : (h += 1) {
        hunks[h].r_start = out;
        put(raw[hunks[h].at .. hunks[h].at + hunks[h].len]); // verbatim
        hunks[h].r_end = out;
    }
    f.r_end = out;
}

fn renderRecent() void {
    var i = recent_start;
    while (i < recent_end) {
        var le = i;
        while (le < recent_end and raw[le] != '\n') le += 1;
        if (le > i) {
            put("  ");
            put(raw[i..le]);
            put("\n");
        }
        i = le + 1;
    }
}

// ── Publish styles + folds over the freshly-authored buffer ─────────────────
fn publishStyles() void {
    weft.styleClear();
    // Branch header line.
    weft.style(0, lineEnd(0), .header);
    for (render_order) |sec| {
        const idx = @intFromEnum(sec);
        if (!sec_present[idx]) continue;
        weft.style(sec_rstart[idx], lineEnd(sec_rstart[idx]), .emphasis);
    }
    var fi: usize = 0;
    while (fi < file_count) : (fi += 1) {
        weft.style(files[fi].r_start, lineEnd(files[fi].r_start), .location);
        var h = files[fi].first_hunk;
        while (h < files[fi].first_hunk + files[fi].n_hunks) : (h += 1) styleHunk(h);
    }
    styleRecent();
}

/// Classify a hunk's rendered lines by their leading diff marker (rendered
/// verbatim, so `render_buf[ls]` IS the diff column).
fn styleHunk(h: usize) void {
    var i = hunks[h].r_start;
    const e = hunks[h].r_end;
    while (i < e) {
        var le = i;
        while (le < e and render_buf[le] != '\n') le += 1;
        if (le > i) {
            const cls: weft.StyleClass = if (std.mem.startsWith(u8, render_buf[i..le], "@@"))
                .muted
            else switch (render_buf[i]) {
                '+' => .added,
                '-' => .removed,
                else => .normal,
            };
            if (cls != .normal) weft.style(i, le, cls);
        }
        i = le + 1;
    }
}

fn styleRecent() void {
    const idx = @intFromEnum(Section.recent);
    if (!sec_present[idx]) return;
    var i = sec_body[idx];
    const e = sec_rend[idx];
    while (i < e) {
        var le = i;
        while (le < e and render_buf[le] != '\n') le += 1;
        // "  <hash> <subject>" — dim the whole line, hash as a location.
        const hs = i + 2;
        var he = hs;
        while (he < le and render_buf[he] != ' ') he += 1;
        if (he > hs) weft.style(hs, he, .location);
        if (le > he) weft.style(he, le, .muted);
        i = le + 1;
    }
}

fn publishFolds() void {
    weft.foldClear();
    for (render_order) |sec| {
        const idx = @intFromEnum(sec);
        if (sec_present[idx] and sec_folded[idx]) weft.fold(sec_body[idx], sec_rend[idx]);
    }
    var fi: usize = 0;
    while (fi < file_count) : (fi += 1) {
        const f = &files[fi];
        if (f.folded and f.n_hunks > 0) weft.fold(f.body, f.r_end);
    }
}

fn lineEnd(off: usize) usize {
    var e = off;
    while (e < out and render_buf[e] != '\n') e += 1;
    return e;
}

// ── Node resolution: cursor/offset → the innermost node it lands in ─────────
const Kind = enum { none, section, file, hunk };
const Node = struct { kind: Kind, idx: usize };

fn nodeAt(off: usize) Node {
    var i: usize = 0;
    while (i < hunk_count) : (i += 1) {
        if (off >= hunks[i].r_start and off < hunks[i].r_end) return .{ .kind = .hunk, .idx = i };
    }
    i = 0;
    while (i < file_count) : (i += 1) {
        if (off >= files[i].r_start and off < files[i].r_end) return .{ .kind = .file, .idx = i };
    }
    for (render_order) |sec| {
        const idx = @intFromEnum(sec);
        if (sec_present[idx] and off >= sec_rstart[idx] and off < sec_rend[idx]) return .{ .kind = .section, .idx = idx };
    }
    return .{ .kind = .none, .idx = 0 };
}

// ── Navigation / folding ────────────────────────────────────────────────────
fn gitStatus() void {
    restore_cursor = false;
    show(GATHER, buf_name, .status);
    weft.setMode("git");
}

/// Start version control from inside the editor: `git init` in the project,
/// then gather straight into `*git*`. Without this, `git-status` on a
/// non-repo just shows an empty buffer and there is no in-editor way to create
/// the repo — you had to drop to a shell. Reuses the same gather scaffolding as
/// every other mutation (no git-init special-casing); after init, GATHER's
/// `git status --branch` renders the fresh `Branch: main` header.
fn gitInit() void {
    restore_cursor = false;
    gatherAfterSeq("git init");
}
fn gitRefresh() void {
    markRestore();
    show(GATHER, buf_name, .status);
    weft.setMode("git");
}

/// TAB: flip the fold of the section/file under point, re-render (no re-gather —
/// the model is intact), republish, and keep the cursor on the header.
fn gitToggleFold() void {
    const n = nodeAt(weft.cursor());
    var head: usize = weft.cursor();
    switch (n.kind) {
        .section => {
            sec_folded[n.idx] = !sec_folded[n.idx];
            head = sec_rstart[n.idx];
        },
        .file => {
            files[n.idx].folded = !files[n.idx].folded;
            setCollapsed(files[n.idx].path_(), files[n.idx].folded); // persist
            head = files[n.idx].r_start;
        },
        .hunk => {
            // Fold the parent file (hunk-granularity folds are a later phase).
            const fi = hunks[n.idx].file;
            files[fi].folded = !files[fi].folded;
            setCollapsed(files[fi].path_(), files[fi].folded); // persist
            head = files[fi].r_start;
        },
        .none => return,
    }
    render();
    weft.edit(.{ .start = 0, .end = weft.byteLen() }, render_buf[0..out]);
    publishStyles();
    publishFolds();
    weft.jump(weft.lineAt(head).start);
}

fn gitVisit() void {
    const n = nodeAt(weft.cursor());
    const fi: usize = switch (n.kind) {
        .file => n.idx,
        .hunk => hunks[n.idx].file,
        // RET on a recent commit → show it (a diff-colored read-only buffer).
        .section => if (@as(Section, @enumFromInt(n.idx)) == .recent) {
            gitShow();
            return;
        } else return,
        else => return,
    };
    weft.runStr("open", files[fi].path_());
}

// ── Staging: file / hunk / region, resolved from the node under point ───────
fn gitStage() void {
    const n = nodeAt(weft.cursor());
    const sel = weft.selection();
    switch (n.kind) {
        .hunk => {
            const h = &hunks[n.idx];
            if (files[h.file].section != .unstaged) {
                weft.echo("stage: not an unstaged hunk");
                return;
            }
            applyHunk(h, sel, false);
        },
        .file => {
            const f = &files[n.idx];
            if (f.section == .staged) {
                weft.echo("stage: already staged");
                return;
            }
            gatherAfter1("git add -- '{s}'", f.path_());
        },
        .section => {
            const sec: Section = @enumFromInt(n.idx);
            if (sec == .staged) return;
            stageSection(sec, true);
        },
        .none => {},
    }
}

fn gitUnstage() void {
    const n = nodeAt(weft.cursor());
    const sel = weft.selection();
    switch (n.kind) {
        .hunk => {
            const h = &hunks[n.idx];
            if (files[h.file].section != .staged) {
                weft.echo("unstage: not a staged hunk");
                return;
            }
            applyHunk(h, sel, true);
        },
        .file => {
            const f = &files[n.idx];
            if (f.section != .staged) {
                weft.echo("unstage: not staged");
                return;
            }
            gatherAfter1("git reset -q HEAD -- '{s}'", f.path_());
        },
        .section => {
            const sec: Section = @enumFromInt(n.idx);
            if (sec != .staged) return;
            stageSection(sec, false);
        },
        .none => {},
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
    while (fi < file_count) : (fi += 1) {
        if (files[fi].section != sec) continue;
        const seg = std.fmt.bufPrint(cmd_buf[w..], " '{s}'", .{files[fi].path_()}) catch break;
        w += seg.len;
        any = true;
    }
    if (!any) return;
    gatherAfter(cmd_buf[0..w]);
}

// ── Discard (destructive — always confirmed) ────────────────────────────────
fn gitDiscard() void {
    const n = nodeAt(weft.cursor());
    switch (n.kind) {
        .file => {
            weft.echo("discard changes to this file? y/n");
            weft.setMode("git-confirm");
        },
        .hunk => {
            weft.echo("discard this hunk? y/n");
            weft.setMode("git-confirm");
        },
        .section => {
            // `x` on the Recent section → reset transient to the commit under
            // point; other sections → the whole-section discard confirm.
            if (@as(Section, @enumFromInt(n.idx)) == .recent) {
                if (recentHashAt() == null) {
                    weft.echo("no commit under point");
                    return;
                }
                weft.echo("reset: s soft  m mixed  h hard");
                weft.setMode("git-reset-menu");
                return;
            }
            weft.echo("discard the whole section? y/n");
            weft.setMode("git-confirm");
        },
        .none => {},
    }
}
fn gitDiscardCancel() void {
    weft.setMode("git");
    weft.echo("discard cancelled");
}
/// The confirmed destructive path. Re-resolves the node from the (unmoved)
/// cursor/selection, so no state has to survive the mode hop.
fn gitDiscardDo() void {
    const n = nodeAt(weft.cursor());
    const sel = weft.selection();
    switch (n.kind) {
        .hunk => {
            const h = &hunks[n.idx];
            const staged = files[h.file].section == .staged;
            // Reverse the worktree change; for a staged hunk, drop it from the
            // index too (git's discard reverts both sides).
            discardHunk(h, sel, staged);
        },
        .file => {
            const f = &files[n.idx];
            switch (f.section) {
                .untracked => gatherAfter1("rm -- '{s}'", f.path_()),
                .unstaged => gatherAfter1("git checkout -- '{s}'", f.path_()),
                .staged => {
                    const mut = std.fmt.bufPrint(&msg_buf, "git reset -q HEAD -- '{s}' && git checkout -- '{s}'", .{ f.path_(), f.path_() }) catch return;
                    gatherAfter(mut);
                },
                .recent => weft.setMode("git"),
            }
        },
        .section => discardSection(@enumFromInt(n.idx)),
        .none => weft.setMode("git"),
    }
}

fn discardSection(sec: Section) void {
    // Compose a per-file discard for the whole section, then re-gather.
    var w: usize = 0;
    var any = false;
    var fi: usize = 0;
    while (fi < file_count) : (fi += 1) {
        const f = &files[fi];
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
fn applyHunk(h: *const Hunk, sel: ?weft.Range, reverse: bool) void {
    const patch = buildPatch(h, sel) orelse {
        weft.echo("git: patch too large");
        return;
    };
    if (!weft.fsWrite(patch_tmp, patch)) {
        weft.echo("git: could not write patch");
        return;
    }
    gatherAfterPatch(if (reverse) "--cached --reverse" else "--cached", false);
}

/// Discard a hunk: reverse it out of the worktree; for a staged hunk, also drop
/// it from the index. Two `git apply`s, chained before the re-gather.
fn discardHunk(h: *const Hunk, sel: ?weft.Range, staged: bool) void {
    const patch = buildPatch(h, sel) orelse {
        weft.echo("git: patch too large");
        weft.setMode("git");
        return;
    };
    if (!weft.fsWrite(patch_tmp, patch)) {
        weft.setMode("git");
        return;
    }
    // Unstaged hunk: reverse it out of the worktree. Staged hunk: reverse it out
    // of the index (`--cached --reverse`) AND the worktree (the trailing
    // `--reverse` gatherAfterPatch adds) — git discards the change entirely.
    if (staged) gatherAfterPatch("--cached --reverse", true) else gatherAfterPatch("--reverse", false);
}

/// Build a one-file/one-hunk patch: the file's kept diff header + the hunk. With
/// `sel`, transform the hunk to only the selected +/- lines (git's algorithm:
/// unselected `+` dropped, unselected `-` demoted to context) and recompute the
/// `@@` counts. Returns null if it won't fit.
fn buildPatch(h: *const Hunk, sel: ?weft.Range) ?[]const u8 {
    const f = &files[h.file];
    if (f.header_len == 0) return null;
    var w: usize = 0;
    const hdr = raw[f.header_off .. f.header_off + f.header_len];
    if (hdr.len > patch_buf.len) return null;
    @memcpy(patch_buf[0..hdr.len], hdr);
    w = hdr.len;

    const hunk = raw[h.at .. h.at + h.len];
    if (sel == null or !overlaps(sel.?, h.r_start, h.r_end)) {
        if (w + hunk.len > patch_buf.len) return null;
        @memcpy(patch_buf[w .. w + hunk.len], hunk);
        w += hunk.len;
        return ensureNl(patch_buf[0..w]);
    }
    return buildPartial(f, h, hunk, sel.?, &w);
}

fn buildPartial(f: *const File, h: *const Hunk, hunk: []const u8, sel: weft.Range, w: *usize) ?[]const u8 {
    _ = f;
    // Split the @@ header line from the body.
    var hl: usize = 0;
    while (hl < hunk.len and hunk[hl] != '\n') hl += 1;
    const starts = parseHunkStarts(hunk[0..hl]);
    // First pass over the body: transform lines, counting old/new.
    // The body begins at hunk[hl+1]; its render offset for a byte q is
    // h.r_start + (h.at + <local> - h.at) = h.r_start + local.
    var bw: usize = 0;
    var old_count: usize = 0;
    var new_count: usize = 0;
    var i: usize = hl + 1;
    while (i < hunk.len) {
        var le = i;
        while (le < hunk.len and hunk[le] != '\n') le += 1;
        const has_nl = le < hunk.len;
        const line = hunk[i..le];
        // This body line's rendered span (verbatim shift by h.r_start - h.at).
        const rstart = h.r_start + (h.at + i) - h.at; // = h.r_start + i
        const rend = h.r_start + (h.at + le) - h.at;
        const selected = overlaps(sel, rstart, rend);
        if (line.len == 0) {
            i = le + 1;
            continue;
        }
        const c = line[0];
        var keep = true;
        var demote = false;
        switch (c) {
            '\\' => {}, // "\ No newline at end of file" — carry as-is
            ' ' => {
                old_count += 1;
                new_count += 1;
            },
            '+' => {
                if (selected) {
                    new_count += 1;
                } else keep = false; // an addition we're not taking: drop it
            },
            '-' => {
                if (selected) {
                    old_count += 1;
                } else {
                    demote = true; // keep the line as context, both sides
                    old_count += 1;
                    new_count += 1;
                }
            },
            else => {},
        }
        if (keep) {
            if (bw + line.len + 1 > body_out.len) return null;
            if (demote) body_out[bw] = ' ' else body_out[bw] = c;
            bw += 1;
            @memcpy(body_out[bw .. bw + line.len - 1], line[1..]);
            bw += line.len - 1;
            if (has_nl) {
                body_out[bw] = '\n';
                bw += 1;
            }
        }
        i = le + 1;
    }
    // Emit the recomputed header + transformed body after the file header.
    const hh = std.fmt.bufPrint(patch_buf[w.*..], "@@ -{d},{d} +{d},{d} @@\n", .{ starts.old, old_count, starts.new, new_count }) catch return null;
    w.* += hh.len;
    if (w.* + bw > patch_buf.len) return null;
    @memcpy(patch_buf[w.* .. w.* + bw], body_out[0..bw]);
    w.* += bw;
    return ensureNl(patch_buf[0..w.*]);
}

const Starts = struct { old: usize, new: usize };
fn parseHunkStarts(line: []const u8) Starts {
    var old: usize = 0;
    var new: usize = 0;
    if (std.mem.indexOfScalar(u8, line, '-')) |mi| old = parseUint(line[mi + 1 ..]);
    if (std.mem.indexOfScalar(u8, line, '+')) |pi| new = parseUint(line[pi + 1 ..]);
    return .{ .old = old, .new = new };
}
fn parseUint(s: []const u8) usize {
    var v: usize = 0;
    for (s) |c| {
        if (c < '0' or c > '9') break;
        v = v * 10 + (c - '0');
    }
    return v;
}

fn ensureNl(patch: []const u8) []const u8 {
    if (patch.len > 0 and patch[patch.len - 1] == '\n') return patch;
    if (patch.len >= patch_buf.len) return patch;
    patch_buf[patch.len] = '\n';
    return patch_buf[0 .. patch.len + 1];
}

fn overlaps(r: weft.Range, s: usize, e: usize) bool {
    return r.start < e and r.end > s;
}

// ── The commit draft ───────────────────────────────────────────────────────
// A draft is an ORDINARY text entry: no mode of its own, no owned keys. It is
// tool-backed, so `std.persistence.save` resolves to `git-commit-save` in it —
// saving the draft IS the commit. Aborting is closing the entry. Drafts are
// instanced, so each repository (and each parallel message) is its own entry.

/// What a draft remembers besides its text: the repository it commits to
/// (resolved once, when the entry opens) and the flags amend/reword put on it.
const Draft = struct {
    root: [256]u8 = undefined,
    root_len: usize = 0,
    flags: [64]u8 = undefined,
    flags_len: usize = 0,
    /// This draft's message file, named after its entry so two live drafts
    /// never write over each other.
    tmp: [64]u8 = undefined,
    tmp_len: usize = 0,

    /// The `-C` target for this draft's commit. `.` while the root is still
    /// resolving — the cwd repository, which is what a fresh draft means.
    fn repo(self: *const Draft) []const u8 {
        return if (self.root_len == 0) "." else self.root[0..self.root_len];
    }
    fn flagsOf(self: *const Draft) []const u8 {
        return self.flags[0..self.flags_len];
    }
    fn tmpOf(self: *const Draft) []const u8 {
        return self.tmp[0..self.tmp_len];
    }
};
/// The tool identity a draft entry carries — what scopes its `save` provider.
const draft_tool = "git-commit";
const Drafts = weft.Instances(Draft, 4);
var drafts: Drafts = .{};
/// The draft a landing commit fill answers for. One commit is in flight at a
/// time; a fill that finds none simply has nothing left to tell.
var committing: ?*Drafts.Slot = null;
var commit_ok = false;
/// What git said about the commit, kept for the failure echo.
var commit_note: [512]u8 = undefined;
var commit_note_len: usize = 0;

/// Open a commit draft. `prefill` (or "") is a shell command whose stdout seeds
/// the message — `git log -1 --format=%B` for amend/reword.
fn openDraft(flags: []const u8, prefill: []const u8) void {
    const slot = drafts.open(draft_tool) orelse {
        weft.echo("git: too many commit drafts open");
        return;
    };
    slot.value = .{};
    setFlags(slot, flags);
    setTmpPath(slot);
    slot.value.root_len = repo_root_len;
    @memcpy(slot.value.root[0..repo_root_len], repo_root[0..repo_root_len]);
    weft.toolBacking(draft_tool);
    seedDraft(slot, prefill);
    weft.jump(0);
    weft.echo("commit draft: save to commit, close to abort");
}

fn setFlags(slot: *Drafts.Slot, flags: []const u8) void {
    slot.value.flags_len = @min(flags.len, slot.value.flags.len);
    @memcpy(slot.value.flags[0..slot.value.flags_len], flags[0..slot.value.flags_len]);
}

fn setTmpPath(slot: *Drafts.Slot) void {
    const prefix = ".weft-";
    var w: usize = prefix.len;
    @memcpy(slot.value.tmp[0..w], prefix);
    for (slot.name()) |c| {
        if (w == slot.value.tmp.len) break;
        const keep: u8 = switch (c) {
            'a'...'z', '0'...'9' => c,
            '-', ':' => '-',
            else => continue,
        };
        slot.value.tmp[w] = keep;
        w += 1;
    }
    slot.value.tmp_len = w;
}

/// Seed a draft's message from `prefill`'s stdout (`git log -1 --format=%B` for
/// amend, `fixup! …` for a fixup). The empty prefill is the plain commit: the
/// entry stays exactly as it is, so nothing can land on top of what was typed.
fn seedDraft(slot: *Drafts.Slot, prefill: []const u8) void {
    if (prefill.len == 0) return;
    weft.procToBuffer(prefill, slot.name(), @intFromEnum(Fill.draft));
}

/// A seeded message landed — start at the top of it.
fn draftFill() void {
    weft.jump(0);
}

/// The draft this command is about — the entry it was invoked in.
fn currentDraft() ?*Drafts.Slot {
    return drafts.current("commit draft") orelse {
        weft.echo("no commit draft here");
        return null;
    };
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
    if (!weft.fsWrite(d.tmpOf(), msg_buf[0..n])) {
        weft.echo("commit: could not write the message");
        return;
    }
    committing = slot;
    // The message file is cwd-relative and the commit runs in the draft's own
    // repository, so the path is absolutized before the subshell changes
    // directory — and the gather that follows still describes the cwd repository.
    const cmd = std.fmt.bufPrint(
        &cmd_buf,
        "m=\"$PWD/{s}\"; (cd '{s}' && git commit {s} -F \"$m\") 2>&1; s=$?; rm -f \"$m\"; " ++
            "printf '\\036\\036C%d\\n' \"$s\"; " ++ GATHER,
        .{ d.tmpOf(), d.repo(), d.flagsOf() },
    ) catch return;
    restore_cursor = false;
    weft.procToBuffer(cmd, buf_name, @intFromEnum(Fill.commit));
}

/// The commit ran: git's output and exit status precede the status gather.
fn commitFill() void {
    loadRaw();
    commit_ok = false;
    if (std.mem.indexOf(u8, raw[0..raw_len], MARK_C)) |ci| {
        commit_note_len = @min(ci, commit_note.len);
        @memcpy(commit_note[0..commit_note_len], raw[0..commit_note_len]);
        var i = ci + MARK_C.len;
        var status: usize = 0;
        while (i < raw_len and raw[i] >= '0' and raw[i] <= '9') : (i += 1) {
            status = status * 10 + (raw[i] - '0');
        }
        commit_ok = status == 0;
        // Hand `parse` the gather alone — the commit prologue is not status.
        if (i < raw_len and raw[i] == '\n') i += 1;
        std.mem.copyForwards(u8, raw[0 .. raw_len - i], raw[i..raw_len]);
        raw_len -= i;
    }
    renderStatus();
    weft.run("git-commit-settle");
}

/// Deferred to a dispatching entry (like `git-note-drops-deliver`): a draft git
/// accepted is closed like any other entry; one it refused stays, with the
/// refusal shown.
fn gitCommitSettle() void {
    const slot = committing orelse return;
    committing = null;
    if (!commit_ok) {
        weft.echo(firstLine(commit_note[0..commit_note_len]));
        return;
    }
    if (focusBuffer(slot.name())) weft.run("buffer-close");
    drafts.close(slot);
    _ = focusBuffer(buf_name);
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
    if (pending_hash_len == 0) {
        weft.echo("no commit chosen to fix up");
        return;
    }
    const slot = currentDraft() orelse return;
    const prefill = std.fmt.bufPrint(
        &op_buf,
        "git log -1 --format='{s}! %s' {s} 2>/dev/null",
        .{ kind, pending_hash[0..pending_hash_len] },
    ) catch return;
    reseat(slot, "", prefill, kind);
}

// ── Opening a draft from the status buffer ─────────────────────────────────
fn gitCommit() void {
    openDraft("", "");
}
/// Amend: edit the current message (pre-filled), include staged changes.
fn gitAmend() void {
    openDraft("--amend", head_message);
}
/// Reword: amend the MESSAGE ONLY (`--only`) — staged changes stay staged.
fn gitReword() void {
    openDraft("--amend --only", head_message);
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
fn openOnto(kind: []const u8) void {
    const h = recentHashAt() orelse {
        weft.echo("no commit under point");
        return;
    };
    const prefill = std.fmt.bufPrint(
        &op_buf,
        "git log -1 --format='{s}! %s' {s} 2>/dev/null",
        .{ kind, h },
    ) catch return;
    openDraft("", prefill);
}

fn focusBuffer(name: []const u8) bool {
    const count = weft.bufferCount();
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const bn = weft.bufferName(i) orelse continue;
        if (std.mem.eql(u8, bn, name)) {
            const id = weft.bufferId(i) orelse return false;
            weft.runInt("buffer-switch", id);
            return true;
        }
    }
    return false;
}

// ── push/pull/fetch: flag transients (sticky menu + our own surface) ─────────
// Flags accumulate in globals; a single key executes. On execute we refresh
// *git* (the branch header's ahead/behind reflects the result) rather than
// dumping normal output. NOTE: `procToBuffer` captures only stdout, so op
// output is suppressed for a clean re-gather — the post-op git state IS the
// feedback; hard errors surface via the host log, not a buffer (see report).
fn flagRow(key: []const u8, label: []const u8, on: bool) void {
    weft.surfaceRow();
    weft.surfaceSpan(key, .accent);
    weft.surfaceSpan(label, .leaf);
    weft.surfaceSpan(if (on) "on" else "off", if (on) .effect else .muted);
}
fn actRow(key: []const u8, label: []const u8) void {
    weft.surfaceRow();
    weft.surfaceSpan(key, .accent);
    weft.surfaceSpan(label, .leaf);
}

fn gitPush() void {
    push_force = false;
    push_upstream = false;
    weft.setMode("git-push-menu");
    renderPushSurface();
}
fn renderPushSurface() void {
    weft.surfaceBegin(.corner);
    weft.surfaceRow();
    weft.surfaceSpan("Push", .accent);
    flagRow("f", "--force-with-lease", push_force);
    flagRow("u", "--set-upstream", push_upstream);
    actRow("p", "push");
    weft.surfaceEnd(-1);
}
fn gitPushToggleForce() void {
    push_force = !push_force;
    renderPushSurface();
}
fn gitPushToggleUpstream() void {
    push_upstream = !push_upstream;
    renderPushSurface();
}
fn gitPushDo() void {
    weft.surfaceClose();
    var w: usize = 0;
    w += (std.fmt.bufPrint(op_buf[w..], "git push", .{}) catch return).len;
    if (push_force) w += (std.fmt.bufPrint(op_buf[w..], " --force-with-lease", .{}) catch return).len;
    if (push_upstream) w += (std.fmt.bufPrint(op_buf[w..], " --set-upstream origin HEAD", .{}) catch return).len;
    weft.echo("pushing…");
    gatherAfterSeq(op_buf[0..w]);
}

fn gitPull() void {
    pull_rebase = false;
    weft.setMode("git-pull-menu");
    renderPullSurface();
}
fn renderPullSurface() void {
    weft.surfaceBegin(.corner);
    weft.surfaceRow();
    weft.surfaceSpan("Pull", .accent);
    flagRow("r", "--rebase", pull_rebase);
    actRow("p", "pull");
    weft.surfaceEnd(-1);
}
fn gitPullToggleRebase() void {
    pull_rebase = !pull_rebase;
    renderPullSurface();
}
fn gitPullDo() void {
    weft.surfaceClose();
    weft.echo("pulling…");
    if (pull_rebase) gatherAfterSeq("git pull --rebase") else gatherAfterSeq("git pull");
}

fn gitFetch() void {
    fetch_all = false;
    fetch_prune = false;
    weft.setMode("git-fetch-menu");
    renderFetchSurface();
}
fn renderFetchSurface() void {
    weft.surfaceBegin(.corner);
    weft.surfaceRow();
    weft.surfaceSpan("Fetch", .accent);
    flagRow("a", "--all", fetch_all);
    flagRow("p", "--prune", fetch_prune);
    actRow("f", "fetch");
    weft.surfaceEnd(-1);
}
fn gitFetchToggleAll() void {
    fetch_all = !fetch_all;
    renderFetchSurface();
}
fn gitFetchTogglePrune() void {
    fetch_prune = !fetch_prune;
    renderFetchSurface();
}
fn gitFetchDo() void {
    weft.surfaceClose();
    var w: usize = 0;
    w += (std.fmt.bufPrint(op_buf[w..], "git fetch", .{}) catch return).len;
    if (fetch_all) w += (std.fmt.bufPrint(op_buf[w..], " --all", .{}) catch return).len;
    if (fetch_prune) w += (std.fmt.bufPrint(op_buf[w..], " --prune", .{}) catch return).len;
    weft.echo("fetching…");
    gatherAfterSeq(op_buf[0..w]);
}
fn gitMenuCancelSurface() void {
    weft.surfaceClose();
    weft.setMode("git");
}
fn gitMenuCancel() void {
    weft.setMode("git");
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
    const path = weft.path() orelse return;
    const cmd = std.fmt.bufPrint(&cmd_buf, "git blame -- {s}", .{path}) catch return;
    show(cmd, "*git-blame*", .none);
}

// ── Gather plumbing: mutate-then-re-gather in ONE shell command ─────────────
/// Focus the named tool buffer (reused across refreshes — `buffer-create` does
/// NOT dedupe by name, so re-creating would pile up duplicates and misdirect the
/// async fill to a stale, unfocused copy), then fill it with `cmd`'s output.
fn show(cmd: []const u8, name: []const u8, fill: Fill) void {
    if (!focusBuffer(name)) weft.runStr("buffer-create", name);
    weft.procToBuffer(cmd, name, @intFromEnum(fill));
}

/// Preserve the cursor spot across the coming re-render: capture the node
/// identity (re-found in the new model) plus the raw offset as a fallback.
fn markRestore() void {
    restore_cursor = true;
    pending_cursor = weft.cursor();
    captureIdentity();
}

/// `mutation && GATHER` into *git* — the index reflects the mutation with no
/// async read/write race.
fn gatherAfter(mutation: []const u8) void {
    markRestore();
    const cmd = std.fmt.bufPrint(&cmd_buf, "{s} && " ++ GATHER, .{mutation}) catch return;
    show(cmd, buf_name, .status);
    weft.setMode("git");
}
/// Same, but the mutation is a `fmt` with a single path arg.
fn gatherAfter1(comptime fmt: []const u8, pth: []const u8) void {
    markRestore();
    const cmd = std.fmt.bufPrint(&cmd_buf, fmt ++ " && " ++ GATHER, .{pth}) catch return;
    show(cmd, buf_name, .status);
    weft.setMode("git");
}
/// Like `gatherAfter` but SEQUENCES with `;` (not `&&`) and swallows the op's
/// stdout — the op runs, then we ALWAYS re-gather so *git* reflects the real
/// post-op state even when the op "failed" (a cherry-pick conflict, a reset, a
/// push that left us still-ahead). Used by every Phase-2b/2c mutation.
fn gatherAfterSeq(mutation: []const u8) void {
    markRestore();
    const cmd = std.fmt.bufPrint(&cmd_buf, "{s} >/dev/null 2>&1; " ++ GATHER, .{mutation}) catch return;
    show(cmd, buf_name, .status);
    weft.setMode("git");
}
/// Same, with a single `{s}` arg (a hash or a quoted name) in `fmt`.
fn gatherAfterSeq1(comptime fmt: []const u8, arg: []const u8) void {
    markRestore();
    const cmd = std.fmt.bufPrint(&cmd_buf, fmt ++ " >/dev/null 2>&1; " ++ GATHER, .{arg}) catch return;
    show(cmd, buf_name, .status);
    weft.setMode("git");
}

/// `git apply <flags> <patch>` (optionally also reverse it from the worktree for
/// a staged-hunk discard), rm the temp patch, then re-gather.
fn gatherAfterPatch(flags: []const u8, also_worktree: bool) void {
    markRestore();
    const cmd = if (also_worktree)
        std.fmt.bufPrint(&cmd_buf, "git apply {s} {s}; git apply --reverse {s}; rm -f {s}; " ++ GATHER, .{ flags, patch_tmp, patch_tmp, patch_tmp }) catch return
    else
        std.fmt.bufPrint(&cmd_buf, "git apply {s} {s}; rm -f {s}; " ++ GATHER, .{ flags, patch_tmp, patch_tmp }) catch return;
    show(cmd, buf_name, .status);
    weft.setMode("git");
}

// ── Commit-node resolution: the hash on the rendered line under point ───────
/// The commit hash of the recent-commits line the cursor is on, copied into
/// `pending_hash` (so it survives a mode hop), or null when the cursor isn't on
/// a commit line. `render_buf[0..out]` IS the buffer we authored, so buffer
/// offsets index it directly (the `nodeAt` invariant).
fn recentHashAt() ?[]const u8 {
    pending_hash_len = recentHashToken(&pending_hash) orelse return null;
    return pending_hash[0..pending_hash_len];
}

/// Copy the commit-hash token on the recent line under point into `dst`,
/// returning its length, or null when the cursor isn't on a commit line. Shared
/// by the commit verbs (`recentHashAt`) and identity capture.
fn recentHashToken(dst: []u8) ?usize {
    const idx = @intFromEnum(Section.recent);
    if (!sec_present[idx]) return null;
    const cur = weft.cursor();
    if (cur < sec_body[idx] or cur >= sec_rend[idx]) return null;
    const ln = weft.lineAt(cur);
    var s = ln.start;
    while (s < ln.end and s < out and render_buf[s] == ' ') s += 1;
    var e = s;
    while (e < ln.end and e < out and render_buf[e] != ' ') e += 1;
    if (e == s) return null;
    const n = @min(e - s, dst.len);
    @memcpy(dst[0..n], render_buf[s .. s + n]);
    return n;
}

// ── Node identity capture/lookup (survives a re-gather; see the restore block) ─
/// Snapshot the identity of the node under point BEFORE a mutation, so the fill
/// can re-find it in the freshly-gathered model.
fn captureIdentity() void {
    restore_kind = .none;
    const n = nodeAt(weft.cursor());
    switch (n.kind) {
        .none => {},
        .file => {
            const f = &files[n.idx];
            restore_kind = .file;
            restore_section = f.section;
            restore_plen = @min(f.plen, restore_path.len);
            @memcpy(restore_path[0..restore_plen], f.path[0..restore_plen]);
        },
        .hunk => {
            const h = &hunks[n.idx];
            const f = &files[h.file];
            restore_kind = .hunk;
            restore_section = f.section;
            restore_plen = @min(f.plen, restore_path.len);
            @memcpy(restore_path[0..restore_plen], f.path[0..restore_plen]);
            restore_hunk_ord = n.idx - f.first_hunk;
        },
        .section => {
            const sec: Section = @enumFromInt(n.idx);
            // A recent-commit line is a section node — remember it by hash so it
            // tracks even after commits above it churn.
            if (sec == .recent) {
                if (recentHashToken(&restore_hash)) |hn| {
                    restore_kind = .commit;
                    restore_hlen = hn;
                    return;
                }
            }
            restore_kind = .section;
            restore_section = sec;
        },
    }
}

/// Re-find the captured identity in the freshly-rendered model → its rendered
/// start offset, or null when it's gone (caller falls back to the clamped offset).
fn findIdentityOffset() ?usize {
    switch (restore_kind) {
        .none => return null,
        .section => {
            const idx = @intFromEnum(restore_section);
            return if (sec_present[idx]) sec_rstart[idx] else null;
        },
        .file => {
            const fi = findFile(restore_section, restore_path[0..restore_plen]) orelse return null;
            return files[fi].r_start;
        },
        .hunk => {
            const fi = findFile(restore_section, restore_path[0..restore_plen]) orelse return null;
            const f = &files[fi];
            if (f.n_hunks == 0) return f.r_start; // hunks gone → the file header
            return hunks[f.first_hunk + @min(restore_hunk_ord, f.n_hunks - 1)].r_start;
        },
        .commit => {
            const idx = @intFromEnum(Section.recent);
            if (!sec_present[idx]) return null;
            const want = restore_hash[0..restore_hlen];
            var i = sec_body[idx];
            const e = sec_rend[idx];
            while (i < e) {
                var le = i;
                while (le < e and render_buf[le] != '\n') le += 1;
                const hs = @min(i + 2, le); // skip the "  " indent
                var he = hs;
                while (he < le and render_buf[he] != ' ') he += 1;
                if (he > hs and std.mem.eql(u8, render_buf[hs..he], want)) return i;
                i = le + 1;
            }
            return null;
        },
    }
}

// ── Generic destructive confirm (branch delete / stash drop / reset --hard) ──
/// Stage a full mutation behind the y/n `git-confirm2` menu.
fn confirmThen(cmd: []const u8, prompt: []const u8) void {
    confirm_len = @min(cmd.len, confirm_cmd.len);
    @memcpy(confirm_cmd[0..confirm_len], cmd[0..confirm_len]);
    weft.echo(prompt);
    weft.setMode("git-confirm2");
}
fn gitConfirmYes() void {
    gatherAfterSeq(confirm_cmd[0..confirm_len]);
}
fn gitConfirmNo() void {
    weft.setMode("git");
    weft.echo("cancelled");
}

// ── Show / cherry-pick / revert / reset on the commit under point ───────────
fn gitShow() void {
    const h = recentHashAt() orelse {
        weft.echo("show: no commit under point");
        return;
    };
    const cmd = std.fmt.bufPrint(&cmd_buf, "git show {s}", .{h}) catch return;
    show(cmd, "*git-show*", .diff);
    weft.setMode("git-view");
}
fn gitCherryPick() void {
    const h = recentHashAt() orelse {
        weft.echo("cherry-pick: no commit under point");
        return;
    };
    gatherAfterSeq1("git cherry-pick {s}", h);
}
fn gitRevert() void {
    const h = recentHashAt() orelse {
        weft.echo("revert: no commit under point");
        return;
    };
    gatherAfterSeq1("git revert --no-edit {s}", h);
}
fn gitResetSoft() void {
    resetTo("--soft");
}
fn gitResetMixed() void {
    resetTo("--mixed");
}
fn resetTo(kind: []const u8) void {
    const m = std.fmt.bufPrint(&op_buf, "git reset {s} {s}", .{ kind, pending_hash[0..pending_hash_len] }) catch return;
    gatherAfterSeq(m);
}
fn gitResetHard() void {
    const m = std.fmt.bufPrint(&op_buf, "git reset --hard {s}", .{pending_hash[0..pending_hash_len]}) catch return;
    confirmThen(m, "reset --hard (loses changes)? y/n");
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
    confirmThen("git stash drop", "drop stash@{0}? y/n");
}

// ── Log transient (the inline Recent section covers the common case) ────────
fn gitLogAll() void {
    show("git log --oneline --graph --all -50", "*git-log*", .log);
    weft.setMode("git-view");
}

// ── The `*git-input*` single-line prompt ────────────────────────────────────
fn openInput(action: InputAction, prompt: []const u8) void {
    input_action = action;
    if (!focusBuffer("*git-input*")) weft.runStr("buffer-create", "*git-input*");
    weft.edit(.{ .start = 0, .end = weft.byteLen() }, "");
    weft.jump(0);
    weft.setMode("git-input");
    weft.echo(prompt);
}
fn gitInputAbort() void {
    input_action = .none;
    weft.setMode("git");
    weft.echo("cancelled");
}
fn gitInputResume() void {
    weft.setMode("git-input");
}
fn gitInputFinish() void {
    // First line, trimmed — the typed name/depth. Copy off the shared scratch
    // before any further host read reuses it.
    const text = weft.slice(0, weft.byteLen());
    var e: usize = 0;
    while (e < text.len and text[e] != '\n') e += 1;
    const line = std.mem.trim(u8, text[0..e], " \t\r");
    input_name_len = @min(line.len, input_name.len);
    @memcpy(input_name[0..input_name_len], line[0..input_name_len]);
    const name = input_name[0..input_name_len];
    if (name.len == 0) {
        gitInputAbort();
        return;
    }
    const act = input_action;
    input_action = .none;
    switch (act) {
        .branch_checkout => gatherAfterSeq1("git checkout '{s}'", name),
        .branch_create => gatherAfterSeq1("git checkout -b '{s}'", name),
        .branch_new => gatherAfterSeq1("git branch '{s}'", name),
        .branch_rename => gatherAfterSeq1("git branch -m '{s}'", name),
        .branch_delete => {
            const cmd = std.fmt.bufPrint(&op_buf, "git branch -d '{s}'", .{name}) catch return;
            confirmThen(cmd, "delete branch? y/n");
        },
        .rebase_start => startRebase(name),
        .none => weft.setMode("git"),
    }
}

// ── Interactive rebase (Phase 2c) ───────────────────────────────────────────
/// A rebase is mid-flight iff `.git/rebase-merge` or `.git/rebase-apply` exists.
fn rebaseInProgress() bool {
    const entries = weft.fsList("here", ".git") orelse return false;
    return std.mem.indexOf(u8, entries, "rebase-merge") != null or
        std.mem.indexOf(u8, entries, "rebase-apply") != null;
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
/// Kick off the todo: list `HEAD~N..HEAD` oldest-first into `*git-rebase*`;
/// the `.rebase` fill rewrites those lines into an editable `pick …` todo.
fn startRebase(nstr: []const u8) void {
    for (nstr) |c| if (c < '0' or c > '9') {
        weft.echo("rebase: expected a number");
        weft.setMode("git");
        return;
    };
    const base = std.fmt.bufPrint(&rebase_base, "HEAD~{s}", .{nstr}) catch return;
    rebase_base_len = base.len;
    const cmd = std.fmt.bufPrint(&cmd_buf, "git log --reverse --format='%h %s' {s}..HEAD 2>/dev/null", .{base}) catch return;
    show(cmd, "*git-rebase*", .rebase);
    weft.setMode("git-rebase");
    weft.echo("rebase todo: p/s/e/r/f/d set verb, edit to reorder, C-c C-c to run");
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
fn gitRebasePick() void {
    setRebaseAction("pick");
}
fn gitRebaseSquash() void {
    setRebaseAction("squash");
}
fn gitRebaseEdit() void {
    setRebaseAction("edit");
}
fn gitRebaseReword() void {
    setRebaseAction("reword");
}
fn gitRebaseFixup() void {
    setRebaseAction("fixup");
}
fn gitRebaseDrop() void {
    setRebaseAction("drop");
}
/// Replace the first whitespace-delimited token (the verb) of the current todo
/// line with `word`; keep the cursor on the line.
fn setRebaseAction(word: []const u8) void {
    const ln = weft.lineAt(weft.cursor());
    const line = weft.slice(ln.start, ln.end);
    var e: usize = 0;
    while (e < line.len and line[e] != ' ') e += 1;
    weft.edit(.{ .start = ln.start, .end = ln.start + e }, word);
    weft.jump(ln.start);
}
fn gitRebaseResume() void {
    weft.setMode("git-rebase");
}
fn gitRebaseCancel() void {
    // Nothing was started (we only drafted the todo) — just return to git.
    restore_cursor = false;
    show(GATHER, buf_name, .status);
    weft.setMode("git");
}
/// Finish: write the edited todo to a temp file and run the rebase with a
/// sequence editor that `cp`s our todo over git's generated one. GIT_EDITOR=true
/// keeps squash/fixup/reword non-interactive (no mid-session editor round-trip);
/// an `edit` stop just leaves a rebase-in-progress the `r` menu then drives.
fn gitRebaseFinish() void {
    const text = weft.slice(0, weft.byteLen());
    const n = @min(text.len, msg_buf.len);
    @memcpy(msg_buf[0..n], text[0..n]);
    if (!weft.fsWrite(rebase_tmp, msg_buf[0..n])) {
        weft.echo("rebase: could not write todo");
        weft.setMode("git");
        return;
    }
    const cmd = std.fmt.bufPrint(
        &cmd_buf,
        "GIT_SEQUENCE_EDITOR='cp {s}' GIT_EDITOR=true git rebase -i {s} >/dev/null 2>&1; rm -f {s}; " ++ GATHER,
        .{ rebase_tmp, rebase_base[0..rebase_base_len], rebase_tmp },
    ) catch return;
    restore_cursor = false;
    show(cmd, buf_name, .status);
    weft.setMode("git");
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
