//! git — git as a MODEL rendered into a foldable buffer (design §6.6), a
//! `.wasm` plugin. A `*git*` buffer is READ-ONLY and owned entirely by this
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

/// A temp file, written INSIDE the session's repository (see `RepoSession.inRepo`)
/// — the plugin's cwd is the editor's, which is not where the repository is.
/// Removed by the same command that consumes it.
const patch_tmp = ".weft-git.patch";

const InputAction = enum(u8) { none, branch_checkout, branch_create, branch_new, branch_rename, branch_delete, rebase_start };

/// Buffer for building a rebase plan's todo lines + the transient op command.
var op_buf: [1 << 14]u8 = undefined;
/// The command handed to `procToBuffer`: the session's `cd` guard + the body.
var run_buf: [1 << 14]u8 = undefined;
/// Scratch for an absolute temp-file path inside the session's repository.
var tmp_buf: [1024]u8 = undefined;
/// Scratch for the path a repository root is detected from (`weft.path` and
/// `weft.cwd` both borrow the shim's shared read scratch).
var probe_buf: [1024]u8 = undefined;
var base_buf: [1024]u8 = undefined;

/// ONE gather command: porcelain status (+ branch), the unstaged diff, the
/// staged diff, and recent commits, delimited by RS-prefixed sentinel lines we
/// can split on unambiguously (`\x1e\x1e{U,S,R}`). We repaint the buffer from
/// the parse, so these markers never reach the user's eyes.
const GATHER =
    "git status --porcelain=v1 --branch 2>/dev/null; " ++
    "printf '\\036\\036U\\n'; git diff 2>/dev/null; " ++
    "printf '\\036\\036S\\n'; git diff --cached 2>/dev/null; " ++
    "printf '\\036\\036R\\n'; git log --format='%h %s' -10 2>/dev/null";
const MARK_U = "\x1e\x1eU";
const MARK_S = "\x1e\x1eS";
const MARK_R = "\x1e\x1eR";
/// Precedes an effect's exit status when a fill carries one ahead of a gather.
const MARK_C = "\x1e\x1eC";

/// Instance base: session 1 takes `*git*`, session 2 `*git:2*` (weft.zig's
/// instanced-tool-buffer naming — a buffer name IS an instance's identity).
const buf_base = "git";
/// A status entry's tool identity. Every offer we publish is predicated on it,
/// so the verbs below are about a git buffer — not about whichever mode happens
/// to be active, and not about a rendered byte range.
const tool = "git";

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

/// FILE fold state persists across gathers — but files rebuild each gather, so
/// we can't carry a bool on the struct. Instead remember a bounded set of
/// COLLAPSED file paths; a file the user folds stays folded through refreshes.
/// Past the cap we echo and stop recording (degrade loud, never silently drop).
/// Keyed by path only, so the same path partially staged in two sections shares
/// fold state.
const MAX_COLLAPSED = 64;
const RestoreKind = enum { none, section, file, hunk, commit };

/// One repository's whole world: its model, its projection, its buffer, its
/// in-flight interaction. Nothing here is shared, so two repositories open at
/// once cannot read or stage each other's files (§18: "two repositories …
/// remain isolated").
const RepoSession = struct {
    /// Absolute repository root — the session's key AND the directory every
    /// one of its commands runs in.
    root_buf: [1024]u8 = undefined,
    root_len: usize = 0,
    /// The instanced buffer this session projects into (`*git*`, `*git:2*`).
    name_buf: [64]u8 = undefined,
    name_len: usize = 0,

    files: [MAX_FILES]File = undefined,
    file_count: usize = 0,
    hunks: [MAX_HUNKS]Hunk = undefined,
    hunk_count: usize = 0,

    raw: [RAW_CAP]u8 = undefined,
    raw_len: usize = 0,
    render_buf: [RENDER_CAP]u8 = undefined,
    out: usize = 0,

    branch: [256]u8 = undefined,
    branch_len: usize = 0,
    /// Whether the porcelain gave us a `## ` line — i.e. the root IS a git
    /// repo. A fresh repo with no commits still emits `## No commits yet on
    /// <branch>`, so absence means "not a repository" (git exited 128), not
    /// "empty repo".
    in_repo: bool = false,
    recent_start: usize = 0, // recent-commits region in `raw`
    recent_end: usize = 0,

    /// Section fold state persists across gathers (indexed by Section) — so a
    /// collapsed Recent stays collapsed through a refresh/stage. Recent
    /// defaults EXPANDED so a commit is directly actionable (RET/A/V/x/fixup)
    /// on a fresh `*git*` without a TAB first; TAB still toggles it.
    sec_folded: [4]bool = @splat(false),
    sec_present: [4]bool = @splat(false),
    sec_rstart: [4]usize = @splat(0),
    sec_rend: [4]usize = @splat(0),
    sec_body: [4]usize = @splat(0), // fold start: just past the header newline
    sec_count: [4]usize = @splat(0),

    collapsed_paths: [MAX_COLLAPSED][256]u8 = undefined,
    collapsed_plen: [MAX_COLLAPSED]usize = undefined,
    collapsed_count: usize = 0,

    // Cursor restoration across a re-gather: a correlation HINT, never
    // identity (§14.3). We remember what the node under point was — section +
    // file path + hunk ordinal, or a recent commit's hash — and the status
    // fill re-finds it in the NEW model, landing on its rendered start.
    // `pending_cursor` is the fallback when the node is gone (e.g. the file was
    // fully staged away). `home_off` is where a fresh open lands.
    restore_cursor: bool = false,
    pending_cursor: usize = 0,
    home_off: usize = 0,
    restore_kind: RestoreKind = .none,
    restore_section: Section = .untracked,
    restore_path: [256]u8 = undefined,
    restore_plen: usize = 0,
    restore_hunk_ord: usize = 0, // the hunk's ordinal within its file
    restore_hash: [64]u8 = undefined,
    restore_hlen: usize = 0,

    dropped_files: bool = false,
    dropped_hunks: bool = false,
    truncated_raw: bool = false,

    /// Snapshot identity (§14.3). `snapshot` names the gathered status the
    /// render (and therefore every path/hunk reference in it) belongs to;
    /// `gathering` says a newer one is already on its way, which makes the
    /// visible projection provisional; `intent` is the snapshot an armed
    /// interaction (a y/n confirm) was formed against.
    snapshot: u32 = 0,
    gathering: bool = false,
    intent: u32 = 0,
    /// The draft / rebase plan whose effect this repository has in flight —
    /// read by the settle the landing fill defers to.
    committing: ?*Drafts.Slot = null,
    sequencing: ?*Todos.Slot = null,

    // ── Interaction state (per repository: two sessions can each have their
    // own half-finished commit, confirm or prompt) ──
    /// The commit hash under point, captured when a commit-scoped verb (show/
    /// fixup/squash/cherry-pick/revert/reset) fires — survives the mode hop
    /// into a submenu. A commit OID is a DURABLE designation: no snapshot.
    pending_hash: [64]u8 = undefined,
    pending_hash_len: usize = 0,
    /// A full mutation staged behind the generic y/n confirm (branch delete,
    /// stash drop, reset --hard) — run verbatim by `git-confirm-yes`.
    confirm_cmd: [1 << 12]u8 = undefined,
    confirm_len: usize = 0,
    /// Name typed into the `*git-input*` prompt (branch names, rebase depth).
    input_name: [256]u8 = undefined,
    input_name_len: usize = 0,
    input_action: InputAction = .none,
    /// Extra flags the commit-finish path passes to `git commit` (amend/
    /// reword), so the ONE editable `*git-commit*` buffer serves commit AND
    /// amend/reword.
    commit_flags: []const u8 = "",
    /// The rebase base ref (`HEAD~N`), for both the todo listing and finish.
    rebase_base: [64]u8 = undefined,
    rebase_base_len: usize = 0,
    // Push/pull/fetch flags accumulated in the (persistent, surface-rendered)
    // transient modes; reset each time the transient is (re)opened.
    push_force: bool = false,
    push_upstream: bool = false,
    pull_rebase: bool = false,
    fetch_all: bool = false,
    fetch_prune: bool = false,

    fn root(self: *const RepoSession) []const u8 {
        return self.root_buf[0..self.root_len];
    }
    fn name(self: *const RepoSession) []const u8 {
        return self.name_buf[0..self.name_len];
    }
    /// A repository-relative path made absolute — the editor's own doors
    /// (`fsWrite`, `open`) resolve against ITS working directory, which is not
    /// where this repository is.
    fn inRepo(self: *const RepoSession, leaf: []const u8) []const u8 {
        return std.fmt.bufPrint(&tmp_buf, "{s}/{s}", .{ self.root(), leaf }) catch leaf;
    }
    /// The projection is provisional while a newer gather is in flight.
    fn fresh(self: *const RepoSession) bool {
        return !self.gathering;
    }
};

/// Live sessions, in open order. A session is never retired: its buffer, and
/// therefore its instance identity, outlives any single command.
const MAX_SESSIONS = 4;
var sessions: [MAX_SESSIONS]RepoSession = undefined;
var session_count: usize = 0;
/// The session the running command is about — set by the command funnel (from
/// the focused buffer or the buffer's repository) and by a landing fill (from
/// the session its token carries). Never inferred inside a handler.
var cur: *RepoSession = undefined;

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
///   `.arm`      — opens an interaction against the current snapshot.
///   `.consume`  — completes an armed interaction; the snapshot must not have
///                 moved since it was armed.
const Scope = enum { durable, snapshot, arm, consume };

const Cmd = struct {
    name: []const u8,
    handler: *const fn () void,
    route: Route = .focus,
    scope: Scope = .durable,
};
const cmds = [_]Cmd{
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
    // Interactive rebase: the plan is an entry; saving it runs the rebase.
    .{ .name = "git-rebase-interactive", .handler = gitRebaseInteractive },
    .{ .name = "git-rebase-continue", .handler = gitRebaseContinue },
    .{ .name = "git-rebase-abort", .handler = gitRebaseAbort },
    .{ .name = "git-rebase-skip", .handler = gitRebaseSkip },
    .{ .name = "git-rebase-save", .handler = gitRebaseSave, .route = .carried },
    .{ .name = "git-rebase-settle", .handler = gitRebaseSettle, .route = .carried },
    .{ .name = "git-menu-cancel", .handler = gitMenuCancel },
    .{ .name = "git-menu-cancel-surface", .handler = gitMenuCancelSurface },
    // Kept for the SPC-g leader menu: read-only views into their own buffers.
    .{ .name = "git-log", .handler = gitLog },
    .{ .name = "git-diff", .handler = gitDiff },
    .{ .name = "git-diff-staged", .handler = gitDiffStaged },
    .{ .name = "git-blame", .handler = gitBlame },
    // Internal: the deferred half of `noteDrops` (task #19 item 4) — not a
    // user-facing verb, invoked only via `weft.run` from `on_fill_token`.
    .{ .name = "git-note-drops-deliver", .handler = gitNoteDropsDeliver, .route = .carried },
};

export fn describe() void {
    for (cmds) |c| weft.declareCommand(c.name);
    weft.requestPerm(.proc);
    weft.requestPerm(.timer);
    weft.requestPerm(.fs_write);
    // fs_read: find the repository root, detect an in-progress rebase.
    weft.requestPerm(.fs_read);
}
export fn init() void {
    for (&sessions) |*s| s.* = .{};
    cur = &sessions[0];
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

    // A rebase plan is a list of verbs in an ordinary text entry: it is edited
    // by typing, like the todo `git rebase -i` would have opened, and saving it
    // hands it to git through the same sequence editor.
    weft.provide("save", .{ .tool = todo_tool }, "git-rebase-save", 10);

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
    cur = s;
    switch (c.scope) {
        .durable => {},
        .snapshot => if (!s.fresh()) return refuseStale(),
        .arm => {
            if (!s.fresh()) return refuseStale();
            s.intent = s.snapshot;
        },
        .consume => if (!s.fresh() or s.intent != s.snapshot) {
            refuseStale();
            weft.setMode("git"); // the armed interaction is over, not pending
            return;
        },
    }
    c.handler();
}

/// A path/hunk action whose snapshot the model has moved past does NOT act on
/// the shifted node: it says so and shows the current status instead.
fn refuseStale() void {
    weft.echo("git: stale — refreshed");
    // A gather in flight repaints on its own; otherwise show what IS current,
    // and only in the session's own buffer (never author someone else's).
    if (cur.fresh() and focusedSession() == cur) rerender();
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
    rebase, // a rebase plan: rewrite the listing into `pick …` lines
    draft, // a commit draft's seeded message
    commit, // a commit's outcome, ahead of the status gather
    sequence, // a rebase's outcome, ahead of the status gather
};

/// A fill token carries BOTH what landed and whose it is: the low byte is the
/// `Fill`, the rest the session ordinal. Delivery therefore needs no guess
/// about focus — the output of repository 2's gather can only ever parse into
/// repository 2's model.
fn fillToken(fill: Fill, s: *const RepoSession) u32 {
    return @intFromEnum(fill) | (@as(u32, @intCast(sessionIndex(s))) << 8);
}

export fn on_fill_token(token: u32) void {
    // A token we never issued routes nowhere.
    const idx = token >> 8;
    if (idx >= session_count) return;
    const fill = std.enums.fromInt(Fill, token & 0xff) orelse return;
    cur = &sessions[idx];
    if (gathers(fill)) {
        cur.gathering = false;
        cur.snapshot +%= 1;
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
    if (focusedSession()) |s| cur = s;
    publishOffers();
}

// ── Repository sessions: root detection, minting, routing ──────────────────
fn sessionIndex(s: *const RepoSession) usize {
    return (@intFromPtr(s) - @intFromPtr(&sessions[0])) / @sizeOf(RepoSession);
}

/// The session whose projection buffer is focused, if any — a command pressed
/// in `*git:2*` is about repository 2, whatever ran before it.
fn focusedSession() ?*RepoSession {
    var buf: [64]u8 = undefined;
    const active = weft.activeBufferName(&buf) orelse return null;
    for (sessions[0..session_count]) |*s| {
        if (std.mem.eql(u8, s.name(), active)) return s;
    }
    return null;
}

/// Find-or-mint the session for `root`, taking the next free instance name.
/// Past the cap we echo and refuse rather than silently reusing a session that
/// belongs to another repository.
fn sessionFor(root: []const u8) ?*RepoSession {
    for (sessions[0..session_count]) |*s| {
        if (std.mem.eql(u8, s.root(), root)) return s;
    }
    if (session_count >= MAX_SESSIONS) {
        weft.echo("git: too many repositories open");
        return null;
    }
    var name_buf: [64]u8 = undefined;
    const name = mintName(&name_buf) orelse return null;
    const s = &sessions[session_count];
    s.* = .{};
    s.root_len = @min(root.len, s.root_buf.len);
    @memcpy(s.root_buf[0..s.root_len], root[0..s.root_len]);
    s.name_len = @min(name.len, s.name_buf.len);
    @memcpy(s.name_buf[0..s.name_len], name[0..s.name_len]);
    session_count += 1;
    return s;
}

/// The lowest instance name (`*git*`, `*git:2*`, …) neither a buffer nor a
/// live session already answers to — a new session's identity.
fn mintName(out: []u8) ?[]const u8 {
    var n: u32 = 1;
    while (n <= MAX_SESSIONS) : (n += 1) {
        const candidate = weft.instanceName(buf_base, n, out) orelse return null;
        if (weft.bufferNamed(candidate)) continue;
        if (nameTaken(candidate)) continue;
        return candidate;
    }
    return null;
}

fn nameTaken(name: []const u8) bool {
    for (sessions[0..session_count]) |*s| {
        if (std.mem.eql(u8, s.name(), name)) return true;
    }
    return false;
}

/// Which session this command is about.
fn route(kind: Route) ?*RepoSession {
    if (kind == .carried) return cur;
    if (focusedSession()) |s| return s; // a git buffer names its own session
    if (kind == .repo or session_count == 0) return sessionFor(activeRoot());
    return cur;
}

/// The repository root the FOCUSED buffer belongs to: the nearest ancestor
/// holding `.git`, else the editor's working directory (the locus a repo would
/// be created in). Absolute, so the same repository always keys one session.
fn activeRoot() []const u8 {
    const here = editorCwd();
    const pth = weft.path() orelse return detectRoot(here, here) orelse here;
    return detectRoot(absolute(pth, here), here) orelse here;
}

/// The focused buffer's file, absolute, or null for a tool buffer.
fn activePathAbs() ?[]const u8 {
    const here = editorCwd();
    return absolute(weft.path() orelse return null, here);
}

/// The editor's working directory, copied off the shim's shared read scratch.
fn editorCwd() []const u8 {
    const cwd = weft.cwd();
    const n = @min(cwd.len, base_buf.len);
    @memcpy(base_buf[0..n], cwd[0..n]);
    return base_buf[0..n];
}

/// `pth` made absolute against the editor's working directory — a buffer path
/// may be relative, a repository root never is.
fn absolute(pth: []const u8, here: []const u8) []const u8 {
    if (pth.len > 0 and pth[0] == '/') {
        const n = @min(pth.len, probe_buf.len);
        @memcpy(probe_buf[0..n], pth[0..n]);
        return probe_buf[0..n];
    }
    return std.fmt.bufPrint(&probe_buf, "{s}/{s}", .{ here, pth }) catch here;
}

/// Climb from `path` to the nearest ancestor holding `.git` (a submodule or
/// worktree makes it a FILE, so any kind counts). The climb STOPS at `floor`
/// when `floor` contains `path`: the editor's working directory is the project
/// locus, so a repository above it — a version-controlled home directory, a
/// `/tmp` someone made a repo — never captures a session that belongs to the
/// project. A path outside `floor` climbs freely: it belongs to its own
/// repository, wherever that is. Null when there is none.
fn detectRoot(path: []const u8, floor: []const u8) ?[]const u8 {
    var end = path.len;
    if (weft.fsExists(path) != .dir) end = std.mem.lastIndexOfScalar(u8, path, '/') orelse return null;
    const stop = if (contains(floor, path)) floor.len else 0;
    while (end >= stop) {
        const dir = if (end == 0) "/" else path[0..end];
        if (weft.fsExists(markerPath(dir)) != .none) return dir;
        if (end == 0 or end == stop) return null;
        end = std.mem.lastIndexOfScalar(u8, path[0..end], '/') orelse 0;
    }
    return null;
}

/// Whether `dir` is `path` or one of its ancestors.
fn contains(dir: []const u8, path: []const u8) bool {
    if (dir.len == 0 or !std.mem.startsWith(u8, path, dir)) return false;
    return path.len == dir.len or path[dir.len] == '/';
}

/// `<dir>/.git`, in scratch that is NOT the buffer `path` borrows.
fn markerPath(dir: []const u8) []const u8 {
    const base = if (std.mem.eql(u8, dir, "/")) "" else dir;
    return std.fmt.bufPrint(&tmp_buf, "{s}/.git", .{base}) catch ".git";
}

/// Pull the buffer's raw bytes into `raw` (paged in `slice`-sized windows, since
/// a read clamps to the 64 KiB scratch). Cap at RAW_CAP and note truncation —
/// no silent drop.
fn loadRaw() void {
    const total = weft.byteLen();
    cur.raw_len = 0;
    cur.truncated_raw = false;
    while (cur.raw_len < total and cur.raw_len < RAW_CAP) {
        const chunk = weft.slice(cur.raw_len, total); // returns ≤ 64 KiB
        if (chunk.len == 0) break;
        const n = @min(chunk.len, RAW_CAP - cur.raw_len);
        @memcpy(cur.raw[cur.raw_len .. cur.raw_len + n], chunk[0..n]);
        cur.raw_len += n;
        if (n < chunk.len) break;
    }
    if (total > RAW_CAP) cur.truncated_raw = true;
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
    weft.edit(.{ .start = 0, .end = weft.byteLen() }, cur.render_buf[0..cur.out]);
    publishStyles();
    publishFolds();
    // Land the cursor: re-find the captured node identity after a mutation (so
    // point tracks the file/hunk/commit even when it moved), else the clamped
    // offset, else home.
    const target = if (cur.restore_cursor)
        (findIdentityOffset() orelse @min(cur.pending_cursor, cur.out))
    else
        cur.home_off;
    weft.jump(weft.lineAt(target).start);
    cur.restore_cursor = false;
    cur.restore_kind = .none;
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
/// door an async LSP response uses — see `src/guest/lsp.zig`'s identical
/// pattern), so `gitNoteDropsDeliver` below runs with a real dispatching
/// head. The session travels WITH the deferral (`.carried` routing) — a
/// background note never asks what is focused.
fn noteDrops() void {
    if (!(cur.dropped_files or cur.dropped_hunks or cur.truncated_raw)) return;
    weft.run("git-note-drops-deliver");
}

fn gitNoteDropsDeliver() void {
    if (cur.dropped_files) weft.echo("git: >128 files — some omitted");
    if (cur.dropped_hunks) weft.echo("git: >512 hunks — some omitted");
    if (cur.truncated_raw) weft.echo("git: output > 256 KiB — diff truncated");
}

// ── Parse ──────────────────────────────────────────────────────────────────
fn parse() void {
    cur.file_count = 0;
    cur.hunk_count = 0;
    cur.branch_len = 0;
    cur.in_repo = false;
    cur.recent_start = 0;
    cur.recent_end = 0;
    cur.dropped_files = false;
    cur.dropped_hunks = false;
    for (0..4) |i| {
        cur.sec_present[i] = false;
        cur.sec_count[i] = 0;
    }
    const data = cur.raw[0..cur.raw_len];
    // Split on the sentinels. A missing marker ⇒ the command failed; render
    // whatever prefix we have (usually just the branch header).
    const ui = std.mem.indexOf(u8, data, MARK_U) orelse data.len;
    const si = std.mem.indexOf(u8, data, MARK_S) orelse data.len;
    const ri = std.mem.indexOf(u8, data, MARK_R) orelse data.len;
    parsePorcelain(0, ui);
    if (ui < si) parseDiff(ui + MARK_U.len, si, .unstaged);
    if (si < ri) parseDiff(si + MARK_S.len, ri, .staged);
    if (ri < data.len) {
        cur.recent_start = ri + MARK_R.len;
        cur.recent_end = data.len;
    }
    // Re-apply the remembered file-fold state (files rebuilt default-expanded).
    for (cur.files[0..cur.file_count]) |*f| f.folded = isCollapsed(f.path_());
    // Present iff non-empty (recent by commit lines).
    for (render_order) |sec| {
        const idx = @intFromEnum(sec);
        if (sec == .recent) {
            cur.sec_count[idx] = countLines(cur.recent_start, cur.recent_end);
        } else {
            var c: usize = 0;
            for (cur.files[0..cur.file_count]) |f| if (f.section == sec) {
                c += 1;
            };
            cur.sec_count[idx] = c;
        }
        cur.sec_present[idx] = cur.sec_count[idx] > 0;
    }
}

fn parsePorcelain(s: usize, e: usize) void {
    var i = s;
    while (i < e) {
        const ls = i;
        var le = i;
        while (le < e and cur.raw[le] != '\n') le += 1;
        i = le + 1;
        const line = cur.raw[ls..le];
        if (line.len == 0) continue;
        if (std.mem.startsWith(u8, line, "## ")) {
            cur.in_repo = true;
            const b = std.mem.trim(u8, line[3..], " \t\r");
            cur.branch_len = @min(b.len, cur.branch.len);
            @memcpy(cur.branch[0..cur.branch_len], b[0..cur.branch_len]);
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
    if (cur.file_count >= MAX_FILES) {
        cur.dropped_files = true;
        return;
    }
    var f = &cur.files[cur.file_count];
    f.* = .{ .section = section, .idx_ch = x, .wt_ch = y };
    f.plen = @min(pth.len, f.path.len);
    @memcpy(f.path[0..f.plen], pth[0..f.plen]);
    cur.file_count += 1;
}

fn parseDiff(ds: usize, de: usize, sec: Section) void {
    var i = ds;
    var cur_file: ?usize = null;
    var hstart: ?usize = null;
    while (i < de) {
        const ls = i;
        var le = i;
        while (le < de and cur.raw[le] != '\n') le += 1;
        i = le + 1;
        const line = cur.raw[ls..le];
        if (std.mem.startsWith(u8, line, "diff --git ")) {
            closeHunk(&hstart, cur_file, ls);
            cur_file = findFile(sec, pathFromDiffGit(line));
            if (cur_file) |fi| {
                cur.files[fi].header_off = ls;
                cur.files[fi].header_len = 0; // set at the first @@
                cur.files[fi].first_hunk = cur.hunk_count;
                cur.files[fi].n_hunks = 0;
            }
        } else if (std.mem.startsWith(u8, line, "@@")) {
            if (cur_file) |fi| {
                if (cur.files[fi].header_len == 0) cur.files[fi].header_len = ls - cur.files[fi].header_off;
            }
            closeHunk(&hstart, cur_file, ls);
            hstart = ls;
        }
    }
    closeHunk(&hstart, cur_file, de);
}

fn closeHunk(hstart: *?usize, file: ?usize, end: usize) void {
    const s = hstart.* orelse return;
    hstart.* = null;
    const fi = file orelse return;
    if (cur.hunk_count >= MAX_HUNKS) {
        cur.dropped_hunks = true;
        return;
    }
    cur.hunks[cur.hunk_count] = .{ .file = fi, .at = s, .len = end - s };
    cur.hunk_count += 1;
    cur.files[fi].n_hunks += 1;
}

fn pathFromDiffGit(line: []const u8) []const u8 {
    if (std.mem.indexOf(u8, line, " b/")) |bi| return std.mem.trimEnd(u8, line[bi + 3 ..], " \t\r");
    return "";
}

// ── Persisted file-fold set (collapsed paths survive a re-gather) ───────────
fn collapsedIndex(pth: []const u8) ?usize {
    var i: usize = 0;
    while (i < cur.collapsed_count) : (i += 1) {
        if (std.mem.eql(u8, cur.collapsed_paths[i][0..cur.collapsed_plen[i]], pth)) return i;
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
        if (cur.collapsed_count >= MAX_COLLAPSED) {
            weft.echo("git: >64 folded files — this fold won't persist");
            return;
        }
        const n = @min(pth.len, cur.collapsed_paths[cur.collapsed_count].len);
        @memcpy(cur.collapsed_paths[cur.collapsed_count][0..n], pth[0..n]);
        cur.collapsed_plen[cur.collapsed_count] = n;
        cur.collapsed_count += 1;
    } else if (collapsedIndex(pth)) |i| {
        // swap-remove (order doesn't matter).
        cur.collapsed_count -= 1;
        cur.collapsed_paths[i] = cur.collapsed_paths[cur.collapsed_count];
        cur.collapsed_plen[i] = cur.collapsed_plen[cur.collapsed_count];
    }
}

fn findFile(sec: Section, pth: []const u8) ?usize {
    if (pth.len == 0) return null;
    var i: usize = 0;
    while (i < cur.file_count) : (i += 1) {
        if (cur.files[i].section == sec and std.mem.eql(u8, cur.files[i].path_(), pth)) return i;
    }
    return null;
}

fn countLines(s: usize, e: usize) usize {
    var n: usize = 0;
    var i = s;
    while (i < e) {
        var le = i;
        while (le < e and cur.raw[le] != '\n') le += 1;
        if (le > i) n += 1;
        i = le + 1;
    }
    return n;
}

// ── Render: the model → pretty, foldable text (offsets recorded into nodes) ──
fn put(bytes: []const u8) void {
    const n = @min(bytes.len, cur.render_buf.len - cur.out);
    @memcpy(cur.render_buf[cur.out .. cur.out + n], bytes[0..n]);
    cur.out += n;
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
    cur.out = 0;
    cur.home_off = 0;
    // Not in a repo: say so plainly rather than a fake `Branch: (no branch)`.
    // `SPC g i` (git-init) is the natural next move from here.
    if (!cur.in_repo) {
        put("Not a git repository.\n\nRun git-init (SPC g i) to start one.\n");
        return;
    }
    // Branch header.
    put("Branch: ");
    if (cur.branch_len > 0) put(cur.branch[0..cur.branch_len]) else put("(no branch)");
    put("\n\n");

    for (render_order) |sec| {
        const idx = @intFromEnum(sec);
        if (!cur.sec_present[idx]) continue;
        cur.sec_rstart[idx] = cur.out;
        put(if (cur.sec_folded[idx]) "\xe2\x96\xb8 " else "\xe2\x96\xbe "); // ▸ / ▾
        put(secTitle(sec));
        put(" (");
        putNum(cur.sec_count[idx]);
        put(")\n");
        cur.sec_body[idx] = cur.out; // fold start: header stays visible
        if (sec == .recent) {
            renderRecent();
        } else {
            var fi: usize = 0;
            while (fi < cur.file_count) : (fi += 1) {
                if (cur.files[fi].section != sec) continue;
                renderFile(fi);
                if (cur.home_off == 0) cur.home_off = cur.files[fi].r_start;
            }
        }
        cur.sec_rend[idx] = cur.out;
        put("\n"); // separator, outside the fold
    }
    if (cur.home_off == 0) {
        // No files: land on the first present section header, else the top.
        for (render_order) |sec| {
            if (cur.sec_present[@intFromEnum(sec)]) {
                cur.home_off = cur.sec_rstart[@intFromEnum(sec)];
                break;
            }
        }
    }
}

fn renderFile(fi: usize) void {
    var f = &cur.files[fi];
    f.r_start = cur.out;
    put("  ");
    if (f.n_hunks > 0) put(if (f.folded) "\xe2\x96\xb8 " else "\xe2\x96\xbe ");
    put(statusLabel(f));
    put(f.path_());
    put("\n");
    f.body = cur.out;
    var h = f.first_hunk;
    while (h < f.first_hunk + f.n_hunks) : (h += 1) {
        cur.hunks[h].r_start = cur.out;
        put(cur.raw[cur.hunks[h].at .. cur.hunks[h].at + cur.hunks[h].len]); // verbatim
        cur.hunks[h].r_end = cur.out;
    }
    f.r_end = cur.out;
}

fn renderRecent() void {
    var i = cur.recent_start;
    while (i < cur.recent_end) {
        var le = i;
        while (le < cur.recent_end and cur.raw[le] != '\n') le += 1;
        if (le > i) {
            put("  ");
            put(cur.raw[i..le]);
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
        if (!cur.sec_present[idx]) continue;
        weft.style(cur.sec_rstart[idx], lineEnd(cur.sec_rstart[idx]), .emphasis);
    }
    var fi: usize = 0;
    while (fi < cur.file_count) : (fi += 1) {
        weft.style(cur.files[fi].r_start, lineEnd(cur.files[fi].r_start), .location);
        var h = cur.files[fi].first_hunk;
        while (h < cur.files[fi].first_hunk + cur.files[fi].n_hunks) : (h += 1) styleHunk(h);
    }
    styleRecent();
}

/// Classify a hunk's rendered lines by their leading diff marker (rendered
/// verbatim, so `render_buf[ls]` IS the diff column).
fn styleHunk(h: usize) void {
    var i = cur.hunks[h].r_start;
    const e = cur.hunks[h].r_end;
    while (i < e) {
        var le = i;
        while (le < e and cur.render_buf[le] != '\n') le += 1;
        if (le > i) {
            const cls: weft.StyleClass = if (std.mem.startsWith(u8, cur.render_buf[i..le], "@@"))
                .muted
            else switch (cur.render_buf[i]) {
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
    if (!cur.sec_present[idx]) return;
    var i = cur.sec_body[idx];
    const e = cur.sec_rend[idx];
    while (i < e) {
        var le = i;
        while (le < e and cur.render_buf[le] != '\n') le += 1;
        // "  <hash> <subject>" — dim the whole line, hash as a location.
        const hs = i + 2;
        var he = hs;
        while (he < le and cur.render_buf[he] != ' ') he += 1;
        if (he > hs) weft.style(hs, he, .location);
        if (le > he) weft.style(he, le, .muted);
        i = le + 1;
    }
}

fn publishFolds() void {
    weft.foldClear();
    for (render_order) |sec| {
        const idx = @intFromEnum(sec);
        if (cur.sec_present[idx] and cur.sec_folded[idx]) weft.fold(cur.sec_body[idx], cur.sec_rend[idx]);
    }
    var fi: usize = 0;
    while (fi < cur.file_count) : (fi += 1) {
        const f = &cur.files[fi];
        if (f.folded and f.n_hunks > 0) weft.fold(f.body, f.r_end);
    }
}

fn lineEnd(off: usize) usize {
    var e = off;
    while (e < cur.out and cur.render_buf[e] != '\n') e += 1;
    return e;
}

// ── Node resolution: cursor/offset → the innermost node it lands in ─────────
const Kind = enum { none, section, file, hunk };
const Node = struct { kind: Kind, idx: usize };

fn nodeAt(off: usize) Node {
    var i: usize = 0;
    while (i < cur.hunk_count) : (i += 1) {
        if (off >= cur.hunks[i].r_start and off < cur.hunks[i].r_end) return .{ .kind = .hunk, .idx = i };
    }
    i = 0;
    while (i < cur.file_count) : (i += 1) {
        if (off >= cur.files[i].r_start and off < cur.files[i].r_end) return .{ .kind = .file, .idx = i };
    }
    for (render_order) |sec| {
        const idx = @intFromEnum(sec);
        if (cur.sec_present[idx] and off >= cur.sec_rstart[idx] and off < cur.sec_rend[idx]) return .{ .kind = .section, .idx = idx };
    }
    return .{ .kind = .none, .idx = 0 };
}

// ── Published offers: what the row under point affords ─────────────────────
/// The section a node belongs to — the fact every staging verb turns on.
fn sectionOf(n: Node) ?Section {
    return switch (n.kind) {
        .file => cur.files[n.idx].section,
        .hunk => cur.files[cur.hunks[n.idx].file].section,
        .section => @enumFromInt(n.idx),
        .none => null,
    };
}

/// Is point on a commit line of the Recent section?
fn onCommitLine() bool {
    var scratch: [64]u8 = undefined;
    return recentHashToken(&scratch) != null;
}

fn stageReason(n: Node) []const u8 {
    return switch (sectionOf(n) orelse return "no-row") {
        .untracked, .unstaged => "",
        .staged => "already-staged",
        .recent => "not-a-change",
    };
}

fn unstageReason(n: Node) []const u8 {
    return if ((sectionOf(n) orelse return "no-row") == .staged) "" else "not-staged";
}

fn openReason(n: Node) []const u8 {
    return switch (n.kind) {
        .file, .hunk => "",
        .section => if (@as(Section, @enumFromInt(n.idx)) == .recent and onCommitLine()) "" else "no-target",
        .none => "no-row",
    };
}

/// Publish what git affords RIGHT HERE: the row verbs, from the node under
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
    if (focusedSession() != cur) return;
    if (!cur.in_repo) {
        weft.offersRetract();
        return;
    }
    const n = nodeAt(weft.cursor());
    weft.offersBegin(tool, cur.snapshot);
    weft.offer("plugin.git.stage", "git-stage", stageReason(n));
    weft.offer("plugin.git.unstage", "git-unstage", unstageReason(n));
    weft.offer("plugin.git.open-diff", "git-visit", openReason(n));
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
    for (&drafts.slots) |*maybe| {
        const slot = if (maybe.*) |*s| s else continue;
        if (std.mem.eql(u8, slot.name(), active)) return slot;
    }
    return null;
}

/// What a draft affords: the same `plugin.git.*` namespace, published through
/// the same door — a re-seat needs a commit under point in the repository the
/// draft was written for, and says so when there is none.
fn publishDraftOffers(slot: *Drafts.Slot) void {
    const s = &sessions[slot.value.session];
    const onto: []const u8 = if (s.pending_hash_len == 0) "no-commit-chosen" else "";
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
    cur.restore_cursor = false;
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
    cur.restore_cursor = false;
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
    const n = nodeAt(weft.cursor());
    var head: usize = weft.cursor();
    switch (n.kind) {
        .section => {
            cur.sec_folded[n.idx] = !cur.sec_folded[n.idx];
            head = cur.sec_rstart[n.idx];
        },
        .file => {
            cur.files[n.idx].folded = !cur.files[n.idx].folded;
            setCollapsed(cur.files[n.idx].path_(), cur.files[n.idx].folded); // persist
            head = cur.files[n.idx].r_start;
        },
        .hunk => {
            // Fold the parent file (hunk-granularity folds are a later phase).
            const fi = cur.hunks[n.idx].file;
            cur.files[fi].folded = !cur.files[fi].folded;
            setCollapsed(cur.files[fi].path_(), cur.files[fi].folded); // persist
            head = cur.files[fi].r_start;
        },
        .none => return,
    }
    rerender();
    weft.jump(weft.lineAt(head).start);
    publishOffers(); // every node moved; point landed on a header
}

/// Repaint the buffer from the model in hand — no re-gather, the model is
/// intact (a fold flip, or a refused stale action showing what IS current).
/// Authoring the whole buffer moves point, so it lands back on its line.
fn rerender() void {
    const at = weft.cursor();
    render();
    weft.edit(.{ .start = 0, .end = weft.byteLen() }, cur.render_buf[0..cur.out]);
    publishStyles();
    publishFolds();
    weft.jump(weft.lineAt(@min(at, cur.out)).start);
}

fn gitVisit() void {
    const n = nodeAt(weft.cursor());
    const fi: usize = switch (n.kind) {
        .file => n.idx,
        .hunk => cur.hunks[n.idx].file,
        // RET on a recent commit → show it (a diff-colored read-only buffer).
        .section => if (@as(Section, @enumFromInt(n.idx)) == .recent) {
            gitShow();
            return;
        } else return,
        else => return,
    };
    weft.runStr("open", cur.inRepo(cur.files[fi].path_()));
}

// ── Staging: file / hunk / region, resolved from the node under point ───────
fn gitStage() void {
    const n = nodeAt(weft.cursor());
    const sel = weft.selection();
    switch (n.kind) {
        .hunk => {
            const h = &cur.hunks[n.idx];
            if (cur.files[h.file].section != .unstaged) {
                weft.echo("stage: not an unstaged hunk");
                return;
            }
            applyHunk(h, sel, false);
        },
        .file => {
            const f = &cur.files[n.idx];
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
            const h = &cur.hunks[n.idx];
            if (cur.files[h.file].section != .staged) {
                weft.echo("unstage: not a staged hunk");
                return;
            }
            applyHunk(h, sel, true);
        },
        .file => {
            const f = &cur.files[n.idx];
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
    while (fi < cur.file_count) : (fi += 1) {
        if (cur.files[fi].section != sec) continue;
        const seg = std.fmt.bufPrint(cmd_buf[w..], " '{s}'", .{cur.files[fi].path_()}) catch break;
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
        .file => confirmPick(.discard, "discard changes to this file?"),
        .hunk => confirmPick(.discard, "discard this hunk?"),
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
            confirmPick(.discard, "discard the whole section?");
        },
        .none => {},
    }
}
/// The confirmed destructive path. Re-resolves the node from the (unmoved)
/// cursor/selection, so no state has to survive the question.
fn gitDiscardDo() void {
    const n = nodeAt(weft.cursor());
    const sel = weft.selection();
    switch (n.kind) {
        .hunk => {
            const h = &cur.hunks[n.idx];
            const staged = cur.files[h.file].section == .staged;
            // Reverse the worktree change; for a staged hunk, drop it from the
            // index too (git's discard reverts both sides).
            discardHunk(h, sel, staged);
        },
        .file => {
            const f = &cur.files[n.idx];
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
    while (fi < cur.file_count) : (fi += 1) {
        const f = &cur.files[fi];
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
    if (!weft.fsWrite(cur.inRepo(patch_tmp), patch)) {
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
    if (!weft.fsWrite(cur.inRepo(patch_tmp), patch)) {
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
    const f = &cur.files[h.file];
    if (f.header_len == 0) return null;
    var w: usize = 0;
    const hdr = cur.raw[f.header_off .. f.header_off + f.header_len];
    if (hdr.len > patch_buf.len) return null;
    @memcpy(patch_buf[0..hdr.len], hdr);
    w = hdr.len;

    const hunk = cur.raw[h.at .. h.at + h.len];
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

/// What a draft remembers besides its text: the repository SESSION it commits
/// to (bound once, when the entry opens) and the flags amend/reword put on it.
const Draft = struct {
    /// The session this draft belongs to. A draft never asks what is focused —
    /// it commits to the repository it was written for, forever.
    session: usize = 0,
    flags: [64]u8 = undefined,
    flags_len: usize = 0,
    /// This draft's message file, named after its entry so two live drafts
    /// never write over each other.
    tmp: [64]u8 = undefined,
    tmp_len: usize = 0,

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
/// A rebase plan: an ordinary instanced entry too, saved to run its rebase.
const Todo = struct {
    session: usize = 0,
    base: [64]u8 = undefined, // the rebase base ref (`HEAD~N`)
    base_len: usize = 0,
    tmp: [64]u8 = undefined,
    tmp_len: usize = 0,
};
const todo_tool = "git-rebase";
const Todos = weft.Instances(Todo, 4);
var todos: Todos = .{};

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
fn openDraft(flags: []const u8, prefill: []const u8) void {
    const slot = drafts.open(draft_tool) orelse {
        weft.echo("git: too many commit drafts open");
        return;
    };
    slot.value = .{ .session = sessionIndex(cur) };
    setFlags(slot, flags);
    slot.value.tmp_len = tmpPathFor(slot.name(), &slot.value.tmp);
    weft.toolBacking(draft_tool);
    seedDraft(slot, prefill);
    weft.jump(0);
    weft.echo("commit draft: save to commit, close to abort");
}

/// A draft's meaning is its flags: setting them is a new model to offer from.
fn setFlags(slot: *Drafts.Slot, flags: []const u8) void {
    slot.value.flags_len = @min(flags.len, slot.value.flags.len);
    @memcpy(slot.value.flags[0..slot.value.flags_len], flags[0..slot.value.flags_len]);
    draft_ordinal +%= 1;
    publishOffers();
}

/// A per-entry temp file named after the entry, so two live ones never write
/// over each other. Returns its length in `tmp`.
fn tmpPathFor(name: []const u8, tmp: []u8) usize {
    const prefix = ".weft-";
    var w: usize = prefix.len;
    @memcpy(tmp[0..w], prefix);
    for (name) |c| {
        if (w == tmp.len) break;
        tmp[w] = switch (c) {
            'a'...'z', '0'...'9' => c,
            '-', ':' => '-',
            else => continue,
        };
        w += 1;
    }
    return w;
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
    cur = &sessions[slot.value.session];
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
    // The message file lives in the draft's own repository — `show` runs the
    // command there, so it names the file relative to that root.
    if (!weft.fsWrite(cur.inRepo(d.tmpOf()), msg_buf[0..n])) {
        weft.echo("commit: could not write the message");
        return;
    }
    cur.committing = slot;
    const cmd = std.fmt.bufPrint(
        &cmd_buf,
        "git commit {s} -F '{s}' 2>&1; s=$?; rm -f '{s}'; " ++
            "printf '\\036\\036C%d\\n' \"$s\"; " ++ GATHER,
        .{ d.flagsOf(), d.tmpOf(), d.tmpOf() },
    ) catch return;
    cur.restore_cursor = false;
    show(cmd, cur.name(), .commit);
}

/// The commit ran: git's own words and exit status precede the status gather.
fn commitFill() void {
    loadRaw();
    commit_ok = takeEffectOutcome();
    renderStatus();
    weft.run("git-commit-settle");
}

/// Which fills carry a status gather — the ones that make the projection
/// provisional on the way out and land a new snapshot on the way back.
fn gathers(fill: Fill) bool {
    return switch (fill) {
        .status, .commit, .sequence => true,
        else => false,
    };
}

/// Split an "effect, then gather" fill: keep what the effect said, report
/// whether it succeeded, and leave `raw` holding the gather alone — a command's
/// prologue is not status.
fn takeEffectOutcome() bool {
    commit_note_len = 0;
    const ci = std.mem.indexOf(u8, cur.raw[0..cur.raw_len], MARK_C) orelse return false;
    commit_note_len = @min(ci, commit_note.len);
    @memcpy(commit_note[0..commit_note_len], cur.raw[0..commit_note_len]);
    var i = ci + MARK_C.len;
    var status: usize = 0;
    while (i < cur.raw_len and cur.raw[i] >= '0' and cur.raw[i] <= '9') : (i += 1) {
        status = status * 10 + (cur.raw[i] - '0');
    }
    if (i < cur.raw_len and cur.raw[i] == '\n') i += 1;
    std.mem.copyForwards(u8, cur.raw[0 .. cur.raw_len - i], cur.raw[i..cur.raw_len]);
    cur.raw_len -= i;
    return status == 0;
}

/// Deferred to a dispatching entry (like `git-note-drops-deliver`): a draft git
/// accepted is closed like any other entry; one it refused stays, with the
/// refusal shown.
fn gitCommitSettle() void {
    const slot = cur.committing orelse return;
    cur.committing = null;
    if (!commit_ok) {
        weft.echo(firstLine(commit_note[0..commit_note_len]));
        return;
    }
    // Retiring the entry is focus-scoped: land on it, then close it.
    if (focusBuffer(slot.name())) weft.run("buffer-close");
    drafts.close(slot);
    _ = focusBuffer(cur.name());
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
    if (cur.pending_hash_len == 0) {
        weft.echo("no commit chosen to fix up");
        return;
    }
    const prefill = std.fmt.bufPrint(
        &op_buf,
        "git log -1 --format='{s}! %s' {s} 2>/dev/null",
        .{ kind, cur.pending_hash[0..cur.pending_hash_len] },
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
    // Already there: switching again would reset the head to the buffer's
    // resting mode, which would tear the surface off an open interaction (a
    // background re-gather must not answer a question the user is still on).
    var buf: [64]u8 = undefined;
    if (weft.activeBufferName(&buf)) |active| {
        if (std.mem.eql(u8, active, name)) return true;
    }
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
    cur.push_force = false;
    cur.push_upstream = false;
    weft.setMode("git-push-menu");
    renderPushSurface();
}
fn renderPushSurface() void {
    weft.surfaceBegin(.corner);
    weft.surfaceRow();
    weft.surfaceSpan("Push", .accent);
    flagRow("f", "--force-with-lease", cur.push_force);
    flagRow("u", "--set-upstream", cur.push_upstream);
    actRow("p", "push");
    weft.surfaceEnd(-1);
}
fn gitPushToggleForce() void {
    cur.push_force = !cur.push_force;
    renderPushSurface();
}
fn gitPushToggleUpstream() void {
    cur.push_upstream = !cur.push_upstream;
    renderPushSurface();
}
fn gitPushDo() void {
    weft.surfaceClose();
    var w: usize = 0;
    w += (std.fmt.bufPrint(op_buf[w..], "git push", .{}) catch return).len;
    if (cur.push_force) w += (std.fmt.bufPrint(op_buf[w..], " --force-with-lease", .{}) catch return).len;
    if (cur.push_upstream) w += (std.fmt.bufPrint(op_buf[w..], " --set-upstream origin HEAD", .{}) catch return).len;
    weft.echo("pushing…");
    gatherAfterSeq(op_buf[0..w]);
}

fn gitPull() void {
    cur.pull_rebase = false;
    weft.setMode("git-pull-menu");
    renderPullSurface();
}
fn renderPullSurface() void {
    weft.surfaceBegin(.corner);
    weft.surfaceRow();
    weft.surfaceSpan("Pull", .accent);
    flagRow("r", "--rebase", cur.pull_rebase);
    actRow("p", "pull");
    weft.surfaceEnd(-1);
}
fn gitPullToggleRebase() void {
    cur.pull_rebase = !cur.pull_rebase;
    renderPullSurface();
}
fn gitPullDo() void {
    weft.surfaceClose();
    weft.echo("pulling…");
    if (cur.pull_rebase) gatherAfterSeq("git pull --rebase") else gatherAfterSeq("git pull");
}

fn gitFetch() void {
    cur.fetch_all = false;
    cur.fetch_prune = false;
    weft.setMode("git-fetch-menu");
    renderFetchSurface();
}
fn renderFetchSurface() void {
    weft.surfaceBegin(.corner);
    weft.surfaceRow();
    weft.surfaceSpan("Fetch", .accent);
    flagRow("a", "--all", cur.fetch_all);
    flagRow("p", "--prune", cur.fetch_prune);
    actRow("f", "fetch");
    weft.surfaceEnd(-1);
}
fn gitFetchToggleAll() void {
    cur.fetch_all = !cur.fetch_all;
    renderFetchSurface();
}
fn gitFetchTogglePrune() void {
    cur.fetch_prune = !cur.fetch_prune;
    renderFetchSurface();
}
fn gitFetchDo() void {
    weft.surfaceClose();
    var w: usize = 0;
    w += (std.fmt.bufPrint(op_buf[w..], "git fetch", .{}) catch return).len;
    if (cur.fetch_all) w += (std.fmt.bufPrint(op_buf[w..], " --all", .{}) catch return).len;
    if (cur.fetch_prune) w += (std.fmt.bufPrint(op_buf[w..], " --prune", .{}) catch return).len;
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
    // Absolute: the command runs in the repository, the buffer path may not be
    // spelled relative to it.
    const path = activePathAbs() orelse return;
    const cmd = std.fmt.bufPrint(&cmd_buf, "git blame -- '{s}'", .{path}) catch return;
    show(cmd, "*git-blame*", .none);
}

// ── Gather plumbing: mutate-then-re-gather in ONE shell command ─────────────
/// Focus the named tool buffer (reused across refreshes — `buffer-create` does
/// NOT dedupe by name, so re-creating would pile up duplicates and misdirect the
/// async fill to a stale, unfocused copy), then fill it with `cmd`'s output RUN
/// IN THIS SESSION'S REPOSITORY. The `cd` guard is the session boundary: a root
/// that has gone away aborts the command rather than letting it act on whatever
/// repository the editor's working directory happens to be.
fn show(cmd: []const u8, name: []const u8, fill: Fill) void {
    const body = std.fmt.bufPrint(&run_buf, "cd '{s}' || exit 0\n{s}", .{ cur.root(), cmd }) catch return;
    if (!focusBuffer(name)) weft.runStr("buffer-create", name);
    if (gathers(fill)) {
        // A status entry carries git's tool identity: it is what the published
        // offers are ABOUT, and the fact the catalog matches them on.
        weft.toolBacking(tool);
        cur.gathering = true; // the projection is now provisional
    }
    weft.procToBuffer(body, name, fillToken(fill, cur));
}

/// Re-gather this session's status into its own buffer.
fn gather(cmd: []const u8) void {
    show(cmd, cur.name(), .status);
}

/// Preserve the cursor spot across the coming re-render: capture the node
/// identity (re-found in the new model) plus the raw offset as a fallback.
fn markRestore() void {
    cur.restore_cursor = true;
    cur.pending_cursor = weft.cursor();
    captureIdentity();
}

/// `mutation && GATHER` into *git* — the index reflects the mutation with no
/// async read/write race.
fn gatherAfter(mutation: []const u8) void {
    markRestore();
    const cmd = std.fmt.bufPrint(&cmd_buf, "{s} && " ++ GATHER, .{mutation}) catch return;
    gather(cmd);
    weft.setMode("git");
}
/// Same, but the mutation is a `fmt` with a single path arg.
fn gatherAfter1(comptime fmt: []const u8, pth: []const u8) void {
    markRestore();
    const cmd = std.fmt.bufPrint(&cmd_buf, fmt ++ " && " ++ GATHER, .{pth}) catch return;
    gather(cmd);
    weft.setMode("git");
}
/// Like `gatherAfter` but SEQUENCES with `;` (not `&&`) and swallows the op's
/// stdout — the op runs, then we ALWAYS re-gather so *git* reflects the real
/// post-op state even when the op "failed" (a cherry-pick conflict, a reset, a
/// push that left us still-ahead). Used by every Phase-2b/2c mutation.
fn gatherAfterSeq(mutation: []const u8) void {
    markRestore();
    const cmd = std.fmt.bufPrint(&cmd_buf, "{s} >/dev/null 2>&1; " ++ GATHER, .{mutation}) catch return;
    gather(cmd);
    weft.setMode("git");
}
/// Same, with a single `{s}` arg (a hash or a quoted name) in `fmt`.
fn gatherAfterSeq1(comptime fmt: []const u8, arg: []const u8) void {
    markRestore();
    const cmd = std.fmt.bufPrint(&cmd_buf, fmt ++ " >/dev/null 2>&1; " ++ GATHER, .{arg}) catch return;
    gather(cmd);
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
    gather(cmd);
    weft.setMode("git");
}

// ── Commit-node resolution: the hash on the rendered line under point ───────
/// The commit hash of the recent-commits line the cursor is on, copied into
/// `pending_hash` (so it survives a mode hop), or null when the cursor isn't on
/// a commit line. `render_buf[0..out]` IS the buffer we authored, so buffer
/// offsets index it directly (the `nodeAt` invariant).
fn recentHashAt() ?[]const u8 {
    cur.pending_hash_len = recentHashToken(&cur.pending_hash) orelse return null;
    return cur.pending_hash[0..cur.pending_hash_len];
}

/// Copy the commit-hash token on the recent line under point into `dst`,
/// returning its length, or null when the cursor isn't on a commit line. Shared
/// by the commit verbs (`recentHashAt`) and identity capture.
fn recentHashToken(dst: []u8) ?usize {
    const idx = @intFromEnum(Section.recent);
    if (!cur.sec_present[idx]) return null;
    const at = weft.cursor();
    if (at < cur.sec_body[idx] or at >= cur.sec_rend[idx]) return null;
    const ln = weft.lineAt(at);
    var s = ln.start;
    while (s < ln.end and s < cur.out and cur.render_buf[s] == ' ') s += 1;
    var e = s;
    while (e < ln.end and e < cur.out and cur.render_buf[e] != ' ') e += 1;
    if (e == s) return null;
    const n = @min(e - s, dst.len);
    @memcpy(dst[0..n], cur.render_buf[s .. s + n]);
    return n;
}

// ── Node identity capture/lookup (survives a re-gather; see the restore block) ─
/// Snapshot the identity of the node under point BEFORE a mutation, so the fill
/// can re-find it in the freshly-gathered model.
fn captureIdentity() void {
    cur.restore_kind = .none;
    const n = nodeAt(weft.cursor());
    switch (n.kind) {
        .none => {},
        .file => {
            const f = &cur.files[n.idx];
            cur.restore_kind = .file;
            cur.restore_section = f.section;
            cur.restore_plen = @min(f.plen, cur.restore_path.len);
            @memcpy(cur.restore_path[0..cur.restore_plen], f.path[0..cur.restore_plen]);
        },
        .hunk => {
            const h = &cur.hunks[n.idx];
            const f = &cur.files[h.file];
            cur.restore_kind = .hunk;
            cur.restore_section = f.section;
            cur.restore_plen = @min(f.plen, cur.restore_path.len);
            @memcpy(cur.restore_path[0..cur.restore_plen], f.path[0..cur.restore_plen]);
            cur.restore_hunk_ord = n.idx - f.first_hunk;
        },
        .section => {
            const sec: Section = @enumFromInt(n.idx);
            // A recent-commit line is a section node — remember it by hash so it
            // tracks even after commits above it churn.
            if (sec == .recent) {
                if (recentHashToken(&cur.restore_hash)) |hn| {
                    cur.restore_kind = .commit;
                    cur.restore_hlen = hn;
                    return;
                }
            }
            cur.restore_kind = .section;
            cur.restore_section = sec;
        },
    }
}

/// Re-find the captured identity in the freshly-rendered model → its rendered
/// start offset, or null when it's gone (caller falls back to the clamped offset).
fn findIdentityOffset() ?usize {
    switch (cur.restore_kind) {
        .none => return null,
        .section => {
            const idx = @intFromEnum(cur.restore_section);
            return if (cur.sec_present[idx]) cur.sec_rstart[idx] else null;
        },
        .file => {
            const fi = findFile(cur.restore_section, cur.restore_path[0..cur.restore_plen]) orelse return null;
            return cur.files[fi].r_start;
        },
        .hunk => {
            const fi = findFile(cur.restore_section, cur.restore_path[0..cur.restore_plen]) orelse return null;
            const f = &cur.files[fi];
            if (f.n_hunks == 0) return f.r_start; // hunks gone → the file header
            return cur.hunks[f.first_hunk + @min(cur.restore_hunk_ord, f.n_hunks - 1)].r_start;
        },
        .commit => {
            const idx = @intFromEnum(Section.recent);
            if (!cur.sec_present[idx]) return null;
            const want = cur.restore_hash[0..cur.restore_hlen];
            var i = cur.sec_body[idx];
            const e = cur.sec_rend[idx];
            while (i < e) {
                var le = i;
                while (le < e and cur.render_buf[le] != '\n') le += 1;
                const hs = @min(i + 2, le); // skip the "  " indent
                var he = hs;
                while (he < le and cur.render_buf[he] != ' ') he += 1;
                if (he > hs and std.mem.eql(u8, cur.render_buf[hs..he], want)) return i;
                i = le + 1;
            }
            return null;
        },
    }
}

// ── Confirmation is an interaction, not a mode ─────────────────────────────
// A destructive verb asks through the pick membrane: the question is the
// prompt, the two candidates are the answer, and the pick id says which
// question was answered. No mode of git's own stands between the two.

/// Which question a pick answers.
const Confirm = enum(u32) { discard = 1, staged = 2 };

/// Ask, safe answer first, so accepting the leading candidate changes nothing.
/// The id carries the session as well as the question, exactly as a fill token
/// does: repository 2's answer can only ever act on repository 2.
fn confirmPick(which: Confirm, prompt: []const u8) void {
    weft.pickBegin(prompt, @intFromEnum(which) | (@as(u32, @intCast(sessionIndex(cur))) << 8));
    weft.pickAdd("no", "leave it alone");
    weft.pickAdd("yes", "go ahead");
    weft.pickEnd();
}

/// Stage a full mutation behind that confirmation.
fn confirmThen(cmd: []const u8, prompt: []const u8) void {
    cur.confirm_len = @min(cmd.len, cur.confirm_cmd.len);
    @memcpy(cur.confirm_cmd[0..cur.confirm_len], cmd[0..cur.confirm_len]);
    confirmPick(.staged, prompt);
}

export fn on_pick_accept(pick_id: u32) void {
    const idx = pick_id >> 8;
    if (idx >= session_count) return; // an id we never issued answers nothing
    const question = std.enums.fromInt(Confirm, pick_id & 0xff) orelse return;
    cur = &sessions[idx];
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
        // A discard designates a working path or hunk: it may only run against
        // the snapshot it was armed on (§14.3's `.consume`).
        .discard => if (cur.fresh() and cur.intent == cur.snapshot) gitDiscardDo() else refuseStale(),
        // The staged command is composed from refs and OIDs — durable.
        .staged => gatherAfterSeq(cur.confirm_cmd[0..cur.confirm_len]),
    }
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
    const m = std.fmt.bufPrint(&op_buf, "git reset {s} {s}", .{ kind, cur.pending_hash[0..cur.pending_hash_len] }) catch return;
    gatherAfterSeq(m);
}
fn gitResetHard() void {
    const m = std.fmt.bufPrint(&op_buf, "git reset --hard {s}", .{cur.pending_hash[0..cur.pending_hash_len]}) catch return;
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

// ── The `*git-input*` single-line prompt ────────────────────────────────────
fn openInput(action: InputAction, prompt: []const u8) void {
    cur.input_action = action;
    if (!focusBuffer("*git-input*")) weft.runStr("buffer-create", "*git-input*");
    weft.edit(.{ .start = 0, .end = weft.byteLen() }, "");
    weft.jump(0);
    weft.setMode("git-input");
    weft.echo(prompt);
}
fn gitInputAbort() void {
    cur.input_action = .none;
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
    cur.input_name_len = @min(line.len, cur.input_name.len);
    @memcpy(cur.input_name[0..cur.input_name_len], line[0..cur.input_name_len]);
    const name = cur.input_name[0..cur.input_name_len];
    if (name.len == 0) {
        gitInputAbort();
        return;
    }
    const act = cur.input_action;
    cur.input_action = .none;
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
        .none => weft.setMode("git"),
    }
}

// ── Interactive rebase (Phase 2c) ───────────────────────────────────────────
/// A rebase is mid-flight iff `.git/rebase-merge` or `.git/rebase-apply` exists.
fn rebaseInProgress() bool {
    const entries = weft.fsList("here", cur.inRepo(".git")) orelse return false;
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
        weft.echo("git: too many rebase plans open");
        return;
    };
    slot.value = .{ .session = sessionIndex(cur) };
    const base = std.fmt.bufPrint(&slot.value.base, "HEAD~{s}", .{nstr}) catch return;
    slot.value.base_len = base.len;
    slot.value.tmp_len = tmpPathFor(slot.name(), &slot.value.tmp);
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
    cur = &sessions[slot.value.session]; // a plan names its own repository
    const text = weft.slice(0, weft.byteLen());
    const n = @min(text.len, msg_buf.len);
    @memcpy(msg_buf[0..n], text[0..n]);
    const v = &slot.value;
    if (!weft.fsWrite(cur.inRepo(v.tmp[0..v.tmp_len]), msg_buf[0..n])) {
        weft.echo("rebase: could not write the plan");
        return;
    }
    cur.sequencing = slot;
    const cmd = std.fmt.bufPrint(
        &cmd_buf,
        "GIT_SEQUENCE_EDITOR='cp {s}' GIT_EDITOR=true git rebase -i {s} 2>&1; s=$?; rm -f {s}; " ++
            "printf '\\036\\036C%d\\n' \"$s\"; " ++ GATHER,
        .{ v.tmp[0..v.tmp_len], v.base[0..v.base_len], v.tmp[0..v.tmp_len] },
    ) catch return;
    cur.restore_cursor = false;
    show(cmd, cur.name(), .sequence);
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
    const slot = cur.sequencing orelse return;
    cur.sequencing = null;
    if (!commit_ok) {
        weft.echo(firstLine(commit_note[0..commit_note_len]));
        return;
    }
    // Retiring the entry is focus-scoped: land on it, then close it.
    if (focusBuffer(slot.name())) weft.run("buffer-close");
    todos.close(slot);
    _ = focusBuffer(cur.name());
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
