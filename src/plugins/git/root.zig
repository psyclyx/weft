//! git — git as a MODEL published as a foldable projection (design §6.6), a
//! `.wasm` plugin. A `*git*` buffer is READ-ONLY and owned entirely by this
//! plugin: four `git status`/`git diff`/`git diff --cached`/`git log` runs go
//! out through `weft.exec` as argv, their output comes back to a continuation
//! that carries what it was for, and we PARSE it into a section→file→hunk tree
//! and PUBLISH that tree (`weft.project`). The host lays it out, styles it from
//! each row's ROLE, folds it, and hit-tests the cursor back to a row.
//!
//! What a verb acts on is the identity the row carries — a `Target`, minted
//! and parsed in `render.zig` alone — resolved against the live model when the
//! verb fires (design §14.3): a commit is a durable OID, a file is a revisioned
//! name (section + path), a hunk and any line selection inside it are scoped to
//! the render `snapshot` they were named in. A verb whose target the model no
//! longer names refuses; it never falls back to whatever row a stale offset now
//! covers — and since no projection door takes or returns an offset, that is
//! now a thing this plugin cannot express rather than a thing it is careful
//! about.
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
const render_order = model.render_order;
const cur = model.cur;
const sessionById = model.Repos.byId;
const focusBuffer = model.focusBuffer;
const Target = model.Target;
const Lines = model.Lines;
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

/// WHAT A VERB DOES, when what it does is one of the shapes most of git's verbs
/// share. Nearly every entry below was a three-line function whose whole body
/// was one of these calls — `fn gitStashPop() void { after(&.{"git","stash",
/// "pop"}); }` — so the table listed the name and a function that listed the
/// command. Naming it once, here, makes the table the complete statement of
/// what git's verbs ARE.
///
/// `.call` is the escape hatch and stays populated for every verb that really
/// does something: staging resolves a target, the draft verbs re-seat a buffer,
/// the rebase verbs read the working tree. This is not a DSL trying to express
/// those — it is the observation that a third of the table was not expressing
/// anything.
const Do = union(enum) {
    /// A function, for a verb that is not one of the shapes below.
    call: *const fn () void,
    /// Run this, then re-gather. The largest family by far.
    run: []const []const u8,
    /// Show this command's output in a read-only view of its own.
    view: struct { argv: []const []const u8, name: []const u8, style: model.ViewStyle },
    /// Ask for a branch name, then run `before ++ &.{name}`.
    branch: struct { before: []const []const u8, label: []const u8, confirm: bool = false },
    /// Open a commit draft with these `git commit` flags, seeded from `prefill`.
    draft: struct { flags: []const u8, prefill: []const []const u8 = &.{} },
};

/// git's own metadata, one entry per command, PARALLEL to the manifest table:
/// the SDK's `Entry` holds the name and the call, this holds what the funnel
/// (`dispatch`, below) needs before it runs.
const Cmd = struct {
    name: []const u8,
    do: Do,
    route: Route = .focus,
    scope: Scope = .durable,
};

/// The `fn () void` for one table entry — the shape's implementation, closed
/// over that entry's data at comptime.
fn callFor(comptime i: usize) *const fn () void {
    const d = cmds[i].do;
    return switch (d) {
        .call => |f| f,
        .run => |argv| struct {
            fn go() void {
                after(argv);
            }
        }.go,
        .view => |v| struct {
            fn go() void {
                show(v.argv, v.name, v.style);
            }
        }.go,
        .branch => |b| struct {
            fn go() void {
                askBranch(.{ .before = b.before, .confirm = b.confirm }, b.label);
            }
        }.go,
        .draft => |c| struct {
            fn go() void {
                _ = openDraft(c.flags, c.prefill);
            }
        }.go,
    };
}
const base_cmds = [_]Cmd{
    .{ .name = "git-status", .do = .{ .call = gitStatus }, .route = .repo },
    .{ .name = "git-init", .do = .{ .run = &.{ "git", "init" } }, .route = .repo },
    .{ .name = "git-refresh", .do = .{ .call = gitRefresh } },
    .{ .name = "git-toggle-fold", .do = .{ .call = gitToggleFold } },
    // Row motion: core's cursor move, then republish — the offers describe
    // the row under point, so moving point is a new eligibility fact.
    .{ .name = "git-next-row", .do = .{ .call = gitNextRow } },
    .{ .name = "git-prev-row", .do = .{ .call = gitPrevRow } },
    .{ .name = "git-stage", .do = .{ .call = gitStage }, .scope = .snapshot },
    .{ .name = "git-unstage", .do = .{ .call = gitUnstage }, .scope = .snapshot },
    .{ .name = "git-stage-all", .do = .{ .run = &.{ "git", "add", "-A" } } },
    .{ .name = "git-unstage-all", .do = .{ .run = &.{ "git", "reset", "-q", "HEAD" } } },
    .{ .name = "git-discard", .do = .{ .call = gitDiscard }, .scope = .arm },
    .{ .name = "git-visit", .do = .{ .call = gitVisit } },
    .{ .name = "git-commit", .do = .{ .draft = .{ .flags = "" } } },
    // Saving a draft entry IS its commit; the settle runs on the fill's way
    // back. A draft names its own repository (`currentDraft` routes to it), so
    // both stay `.carried` — never "whatever git buffer was focused".
    .{ .name = "git-commit-save", .do = .{ .call = gitCommitSave }, .route = .carried },
    .{ .name = "git-commit-settle", .do = .{ .call = gitCommitSettle }, .route = .carried },
    // Commit dispatch (the `c` transient): each opens a draft for the commit it
    // means; fixup/squash resolve the commit under point into its message.
    .{ .name = "git-amend", .do = .{ .draft = .{ .flags = "--amend", .prefill = head_message } } },
    .{ .name = "git-extend", .do = .{ .run = &.{ "git", "commit", "--amend", "--no-edit" } } },
    .{ .name = "git-reword", .do = .{ .draft = .{ .flags = "--amend --only", .prefill = head_message } } },
    .{ .name = "git-fixup", .do = .{ .call = gitFixup } },
    .{ .name = "git-squash", .do = .{ .call = gitSquash } },
    // The draft entry's own offers — they re-seat the draft under point.
    .{ .name = "git-draft-close", .do = .{ .call = gitDraftClose }, .route = .carried },
    .{ .name = "git-draft-amend", .do = .{ .call = gitDraftAmend }, .route = .carried },
    .{ .name = "git-draft-reword", .do = .{ .call = gitDraftReword }, .route = .carried },
    .{ .name = "git-draft-fixup", .do = .{ .call = gitDraftFixup }, .route = .carried },
    .{ .name = "git-draft-squash", .do = .{ .call = gitDraftSquash }, .route = .carried },
    // Commit-scoped verbs on a recent-commit node.
    .{ .name = "git-show", .do = .{ .call = gitShow } },
    .{ .name = "git-cherry-pick", .do = .{ .call = gitCherryPick } },
    .{ .name = "git-revert", .do = .{ .call = gitRevert } },
    .{ .name = "git-reset-soft", .do = .{ .call = gitResetSoft } },
    .{ .name = "git-reset-mixed", .do = .{ .call = gitResetMixed } },
    .{ .name = "git-reset-hard", .do = .{ .call = gitResetHard } },
    // Branch transient.
    .{ .name = "git-branch-checkout", .do = .{ .branch = .{ .before = &.{ "git", "checkout" }, .label = "checkout branch: " } } },
    .{ .name = "git-branch-create", .do = .{ .branch = .{ .before = &.{ "git", "checkout", "-b" }, .label = "create & checkout branch: " } } },
    .{ .name = "git-branch-new", .do = .{ .branch = .{ .before = &.{ "git", "branch" }, .label = "new branch: " } } },
    .{ .name = "git-branch-delete", .do = .{ .branch = .{ .before = &.{ "git", "branch", "-d" }, .label = "delete branch: ", .confirm = true } } },
    .{ .name = "git-branch-rename", .do = .{ .branch = .{ .before = &.{ "git", "branch", "-m" }, .label = "rename current branch to: " } } },
    // Stash transient.
    .{ .name = "git-stash-save", .do = .{ .run = &.{ "git", "stash", "push" } } },
    .{ .name = "git-stash-pop", .do = .{ .run = &.{ "git", "stash", "pop" } } },
    .{ .name = "git-stash-apply", .do = .{ .run = &.{ "git", "stash", "apply" } } },
    .{ .name = "git-stash-list", .do = .{ .view = .{ .argv = &.{ "git", "stash", "list" }, .name = "*git-stash*", .style = .none } } },
    .{ .name = "git-stash-drop", .do = .{ .call = gitStashDrop } },
    // Log transient.
    .{ .name = "git-log-all", .do = .{ .view = .{ .argv = &.{ "git", "log", "--oneline", "--graph", "--all", "-50" }, .name = "*git-log*", .style = .log } } },
    // Push/pull/fetch are TRANSIENTS: their open/toggle/run/cancel commands are
    // generated from the declarations in `transient.zig` and spliced in below
    // (`transient_cmds`), so there is nothing to list here.
    // Interactive rebase: the plan is an entry; saving it runs the rebase.
    .{ .name = "git-rebase-interactive", .do = .{ .call = gitRebaseInteractive } },
    .{ .name = "git-rebase-continue", .do = .{ .run = &.{ "git", "-c", "core.editor=true", "rebase", "--continue" } } },
    .{ .name = "git-rebase-abort", .do = .{ .run = &.{ "git", "rebase", "--abort" } } },
    .{ .name = "git-rebase-skip", .do = .{ .run = &.{ "git", "rebase", "--skip" } } },
    .{ .name = "git-rebase-save", .do = .{ .call = gitRebaseSave }, .route = .carried },
    .{ .name = "git-rebase-settle", .do = .{ .call = gitRebaseSettle }, .route = .carried },
    .{ .name = "git-menu-cancel", .do = .{ .call = transient.gitMenuCancel } },
    // Kept for the SPC-g leader menu: read-only views into their own buffers.
    .{ .name = "git-log", .do = .{ .view = .{ .argv = &.{ "git", "log", "--oneline", "--graph", "-30" }, .name = "*git-log*", .style = .log } } },
    .{ .name = "git-diff", .do = .{ .view = .{ .argv = &.{ "git", "diff" }, .name = "*git-diff*", .style = .diff } } },
    .{ .name = "git-diff-staged", .do = .{ .view = .{ .argv = &.{ "git", "diff", "--staged" }, .name = "*git-diff-staged*", .style = .diff } } },
    .{ .name = "git-blame", .do = .{ .call = gitBlame } },
};

/// The shared prompt's five editing commands (`input`, below), mapped into
/// git's `Cmd`. They route like any other git verb: the prompt is an
/// echo-line overlay, not a buffer, so the focused entry is still the `*git*`
/// the branch name is for — which is precisely what the old `*git-input*`
/// buffer had to work around by carrying the session in `input_action`.
const input_cmds: [input.commands.len]Cmd = blk: {
    var arr: [input.commands.len]Cmd = undefined;
    for (input.commands, 0..) |c, i| arr[i] = .{ .name = c.name, .do = .{ .call = c.handler } };
    break :blk arr;
};

/// The push/pull/fetch transients' generated commands, adapted to git's own
/// `Cmd`. They take the table's defaults — `.focus` route, `.durable` scope —
/// which is what push/pull/fetch always had: a flag menu is about the
/// repository the focused entry names, and nothing it holds is a row from the
/// current render.
const transient_cmds: [transient.commands.len]Cmd = blk: {
    var arr: [transient.commands.len]Cmd = undefined;
    for (transient.commands, 0..) |c, i| arr[i] = .{ .name = c.name, .do = .{ .call = c.call } };
    break :blk arr;
};

const cmds = base_cmds ++ input_cmds ++ transient_cmds;

/// The manifest's table, derived from `cmds` — same order, so `dispatch`'s
/// index reaches the same entry's route and scope.
const entries: [cmds.len]weft.CommandEntry = blk: {
    var arr: [cmds.len]weft.CommandEntry = undefined;
    for (cmds, 0..) |c, i| arr[i] = .{ .name = c.name, .call = callFor(i) };
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
    provideRowVerbs();
    // What a settled gather owes the rest of the plugin, and how a view is
    // coloured. Installed rather than called directly so `gather.zig` stays
    // readable without the rest of this file in your head.
    model.on_gathered = onGathered;
    model.on_view_filled = onViewFilled;
    model.on_view_project = render_mod.projectView;
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
    weft.bindKey("git", "b", "git-branch");
    weft.bindKey("git", "z", "git-stash");
    weft.bindKey("git", "l", "git-log-choose");
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

    // Commit dispatch, reset, branch, stash and log are TRANSIENTS with no
    // flags — five `menuMode` blocks and their bindings are now five
    // declarations in `transient.zig`, installed with the three flag menus
    // below.

    // Rebase transient (`r`): interactive + in-progress continue/abort/skip. The
    // right verb is chosen per state; the wrong one just no-ops with a git error.
    // STICKY (matching git-push/pull/fetch-menu's idiom): needed ONLY for `i`
    // when a rebase is mid-flight, which re-sets the SAME mode to keep the
    // menu open (dispatch.zig's leaf auto-pop otherwise treats "still the same
    // mode after the leaf" as "did nothing, pop it" — undoing the re-set).
    // c/a/s/`i`-when-clean all still close normally: each explicitly leaves via
    // `weft.setMode` to a DIFFERENT mode (git or git-input), which dispatch's
    // "leaf moved us elsewhere" branch honors regardless of stickiness — same
    // as the git-push transient's sticky toggles vs. its leaving `-do` action.
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
    // execute key (p/RET, which re-gathers into git) or Escape/q leaves. All
    // of that — the sticky mode, every binding, the live flag surface, and the
    // leave — is generated from the three declarations in `transient.zig`.
    transient.install();

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
    model.Repos.routed = s;
    switch (c.scope) {
        .durable => {},
        .snapshot => if (!s.value.fresh()) {
            refuseStale();
            return false;
        },
        .arm => if (!s.value.fresh()) {
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
    if (cur().fresh() and focusedSession() == model.Repos.routed) rerender();
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

/// A gather settled: publish the new model, then let whatever was waiting on it
/// finish.
///
/// There used to be a `paintOwnEntry` here — save the focused buffer, land on
/// this session's entry, repaint, land back — because the repaint authored
/// whatever was ACTIVE and a delivery could arrive while you were somewhere
/// else. `wl_proj_begin` captures the entry by name, once, and nothing between
/// then and the commit can redirect it, so a session repaints its own entry
/// from wherever you happen to be standing. The dance is gone, and with it the
/// window where a gather landing mid-keystroke moved your focus.
fn onGathered() void {
    renderStatus();
    if (cur().committing != null) gitCommitSettle();
    if (cur().sequencing != null) gitRebaseSettle();
}

fn onViewFilled(style: model.ViewStyle) void {
    // What is LEFT after the diff and log views became projections: the plan a
    // rebase is edited in, which is plain text on purpose.
    if (style == .rebase_todo) rebaseTodoFill();
}

/// A buffer took focus. One offer table is live for the `git` tool identity,
/// so it has to describe the repository the user is now looking at — this is
/// the routing entry for focus, exactly as `on_fill_token` is for a delivery.
export fn on_activate() void {
    if (focusedSession()) |s| model.Repos.routed = s;
}

// ── Repository sessions: routing, and where a command runs ─────────────────
//
// This was 160 lines: find-or-mint by root, mint the next free instance name
// against both the live sessions and the open buffers, refuse for the two
// reasons a mint can fail, and route each command by whether it means the place
// it is in, the buffer it is in, or the session its caller chose. None of it
// was about git — any plugin projecting a per-place authority (a build tree, a
// test suite, a language server's workspace) writes exactly the same thing —
// so it is `weft_sessions` now, and what is left here is the two names git
// spells differently.

const focusedSession = model.Repos.focused;
const activeRoot = model.Repos.here;
const activePathAbs = model.Repos.pathHere;

/// Which session this command is about. git's `Route` is the library's, with
/// `.repo` as the name git gives `.place` — the door into a second repository.
fn route(kind: Route) ?*RepoSession {
    return model.Repos.route(switch (kind) {
        .repo => .place,
        .focus => .focus,
        .carried => .carried,
    });
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
            const f = &cur().files.items[fi];
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

// ── What a row affords is a PREDICATE, not a table this file pushes ────────
//
// git used to compute, on every model change and every cursor move, a table of
// eight offers each with a sentence saying why it did or did not apply
// (`stageReason`, `unstageReason`, `openReason`), and push it through
// `offersBegin`/`offer`/`offersCommit` stamped with the snapshot.
//
// Each is a `provide` now, bound ONCE at init against the ROLE a row carries.
// Core derives the offer table from whichever providers are eligible here
// (`core/action_offers.zig`), so the engine that already decides every other
// action decides these — and a third party can bind a verb to git's rows
// without git enumerating it or knowing it exists.
//
// What is lost, said plainly: the REASON. "already-staged" was better than
// silence. A row no provider bound now affords nothing rather than affording
// something disabled-with-an-explanation, and the two verbs that are
// state-dependent rather than row-dependent — fixing up onto a commit the
// draft never chose — refuse out loud when invoked instead of in advance.
fn provideRowVerbs() void {
    const file_unstaged: weft.Predicate = .{ .role = "git.file.unstaged" };
    const file_untracked: weft.Predicate = .{ .role = "git.file.untracked" };
    const file_staged: weft.Predicate = .{ .role = "git.file.staged" };
    const hunk_unstaged: weft.Predicate = .{ .role = "git.hunk.unstaged" };
    const hunk_staged: weft.Predicate = .{ .role = "git.hunk.staged" };
    const sec_unstaged: weft.Predicate = .{ .role = "git.section.unstaged" };
    const sec_untracked: weft.Predicate = .{ .role = "git.section.untracked" };
    const sec_staged: weft.Predicate = .{ .role = "git.section.staged" };
    const commit_row: weft.Predicate = .{ .role = "git.commit" };

    // The disjunction the old four-tag wire could not encode, doing the work a
    // reason string used to do.
    weft.provide("plugin.git.stage", .{ .any = &.{ file_unstaged, file_untracked, hunk_unstaged, sec_unstaged, sec_untracked } }, "git-stage", 0);
    weft.provide("plugin.git.unstage", .{ .any = &.{ file_staged, hunk_staged, sec_staged } }, "git-unstage", 0);
    weft.provide("plugin.git.open-diff", .{ .any = &.{
        file_unstaged, file_untracked, file_staged,
        hunk_unstaged, hunk_staged,    commit_row,
    } }, "git-visit", 0);

    // Entry-level verbs: about the repository this entry projects, not about
    // the row under point.
    const in_git: weft.Predicate = .{ .tool = tool };
    weft.provide("plugin.git.commit", in_git, "git-commit", 0);
    weft.provide("plugin.git.refresh", in_git, "git-refresh", 0);
    weft.provide("plugin.git.push", in_git, "git-push", 0);
    weft.provide("plugin.git.pull", in_git, "git-pull", 0);
    weft.provide("plugin.git.fetch", in_git, "git-fetch", 0);

    // A draft's own verbs, scoped to the draft's tool identity.
    const in_draft: weft.Predicate = .{ .tool = draft_tool };
    weft.provide("plugin.git.amend", in_draft, "git-draft-amend", 0);
    weft.provide("plugin.git.reword", in_draft, "git-draft-reword", 0);
    weft.provide("plugin.git.fixup", in_draft, "git-draft-fixup", 0);
    weft.provide("plugin.git.squash", in_draft, "git-draft-squash", 0);
}

// ── Navigation / folding ────────────────────────────────────────────────────
/// Core moves point (fold-aware); we republish, because the row under point
/// IS the offers' subject. A cursor moved by anything else leaves the table
/// describing the previous row — the verb then refuses out loud when it
/// re-resolves the node, exactly as it always has.
fn gitNextRow() void {
    weft.run("cursor-down");
}
fn gitPrevRow() void {
    weft.run("cursor-up");
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
        .hunk => render_mod.keyOf(fileTarget(cur().hunks.items[n.idx].file)),
        else => return,
    };
    render_mod.toggleFold(fold_key);
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
        .hunk => cur().hunks.items[n.idx].file,
        // RET on a recent commit → show it (a diff-colored read-only buffer).
        .commit => {
            showCommit(t);
            return;
        },
        else => return,
    };
    weft.runStr("open", model.inRepo(model.curSession(), cur().files.items[fi].path_()));
}

// ── Staging: file / hunk / region, resolved from the node under point ───────
fn gitStage() void {
    const t = nodeAtCursor();
    const n = liveNode(t, "stage") orelse return;
    switch (n.kind) {
        .hunk => {
            if (cur().files.items[cur().hunks.items[n.idx].file].section != .unstaged) {
                weft.echo("stage: not an unstaged hunk");
                return;
            }
            applyHunk(n.idx, t.sel, false);
        },
        .file => {
            const f = &cur().files.items[n.idx];
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
            if (cur().files.items[cur().hunks.items[n.idx].file].section != .staged) {
                weft.echo("unstage: not a staged hunk");
                return;
            }
            applyHunk(n.idx, t.sel, true);
        },
        .file => {
            const f = &cur().files.items[n.idx];
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
    while (fi < cur().files.items.len) : (fi += 1) {
        if (cur().files.items[fi].section != sec) continue;
        argv.push(cur().files.items[fi].path_());
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
    const armed: Armed = .{ .session = model.curSession().id, .target = t };
    switch (n.kind) {
        .file => _ = weft.confirmWith(Armed, armed, "discard changes to this file?", gitDiscardDo),
        .hunk => _ = weft.confirmWith(Armed, armed, "discard this hunk?", gitDiscardDo),
        // `x` on a recent commit → the reset transient, scoped to that OID.
        // Opened through its own command so the menu paints itself; the echo
        // line no longer has to be a hand-typed copy of its key list.
        .commit => {
            cur().pending_target = t;
            weft.run(transient.reset.open_command);
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
            const staged = cur().files.items[cur().hunks.items[n.idx].file].section == .staged;
            discardHunk(n.idx, t.sel, staged);
        },
        .file => {
            const f = &cur().files.items[n.idx];
            switch (f.section) {
                // `rm` has no `-C`, so it gets the path made absolute against the
                // session's root — the same join `open` already uses for a row.
                .untracked => after(&.{ "rm", "--", model.inRepo(model.curSession(), f.path_()) }),
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
    while (fi < cur().files.items.len) : (fi += 1) {
        if (cur().files.items[fi].section != sec) continue;
        // `rm` runs with no `-C`, so its paths are absolute; git's are
        // repository-relative, which is what git wants.
        argv.push(if (sec == .untracked) model.inRepo(model.curSession(), cur().files.items[fi].path_()) else cur().files.items[fi].path_());
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

/// Open a commit draft. `prefill` (or "") is a shell command whose stdout seeds
/// the message — `git log -1 --format=%B` for amend/reword.
fn openDraft(flags: []const u8, prefill: []const []const u8) ?*Drafts.Slot {
    const slot = drafts.open(draft_tool) orelse {
        weft.echo("git: out of memory — could not open another commit draft");
        return null;
    };
    slot.value = .{ .session = model.curSession().id };
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
}

/// Seed a draft's message from `prefill`'s stdout (`git log -1 --format=%B` for
/// amend, `fixup! …` for a fixup). The empty prefill is the plain commit: the
/// entry stays exactly as it is, so nothing can land on top of what was typed.
fn seedDraft(slot: *Drafts.Slot, prefill: []const []const u8) void {
    if (prefill.len == 0) return;
    show(prefill, slot.name(), .none); // read from the draft's own repository
}

/// The draft this command is about — the entry it was invoked in — and, with
/// it, the repository it was written for: a draft routes its own session.
fn currentDraft() ?*Drafts.Slot {
    const slot = drafts.current("commit draft") orelse {
        weft.echo("no commit draft here");
        return null;
    };
    model.Repos.routed = sessionById(slot.value.session) orelse return null;
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
    settleDraft(Drafts, &drafts, slot, "committed");
}

/// AN EDITABLE ENTRY THAT STOOD FOR AN OPERATION, after git answered.
///
/// Accepted, the entry is spent and closes like any other; refused, it STAYS,
/// with git's own first line of stderr, so what you wrote is still there to fix.
/// Two callers, one rule: the commit draft and the rebase plan differ in their
/// slot table and in one word, and having written it twice is how the two would
/// eventually differ in something that mattered.
fn settleDraft(comptime Table: type, table: *Table, slot: *Table.Slot, done: []const u8) void {
    if (!cur().effect_ok) {
        weft.echo(cur().effect_note[0..cur().effect_note_len]);
        return;
    }
    // Retiring the entry is focus-scoped: land on it, then close it.
    if (focusBuffer(slot.name())) weft.run("buffer-close");
    table.close(slot);
    _ = focusBuffer(model.curSession().name());
    weft.echo(done);
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
/// Amend: edit the current message (pre-filled), include staged changes.
/// Reword: amend the MESSAGE ONLY (`--only`) — staged changes stay staged.
/// Extend: fold staged changes into HEAD, keep the message (no draft).
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
    var staged: Staged = .{ .session = model.curSession().id, .verb = verb };
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
    model.Repos.routed = s;
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

// ── Stash transient ─────────────────────────────────────────────────────────
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
//
// Each opening carries WHAT IT IS FOR (`openWith`), so there is no
// `InputAction` enum, no `input_action` parked on the session, and no `onInput`
// switch translating one back into the other. The question and its purpose
// travel together, which is the same fix `confirmWith` made for confirmations.
const input = prompt.Prompt(.{
    .name = "git-input",
    .resting = "git",
    .capacity = 256,
    .payload_callers = true,
    .on_cancel = struct {
        fn cancelled() void {
            weft.echo("cancelled");
        }
    }.cancelled,
});

/// A branch verb is its argv template: everything before the name, and
/// everything after it. Five verbs, one continuation.
const BranchOp = struct {
    before: []const []const u8,
    /// Ask first — `branch -d` is the one that can lose work.
    confirm: bool = false,
};

fn askBranch(comptime op: BranchOp, label: []const u8) void {
    input.openWith(BranchOp, op, label, struct {
        fn done(name: []const u8, held: BranchOp) void {
            if (name.len == 0) return weft.echo("cancelled");
            if (held.confirm) return confirmThen(.branch_delete, name, "delete branch?");
            var argv: Argv = .{};
            argv.pushAll(held.before);
            argv.push(name);
            after(argv.slice());
        }
    }.done);
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
    input.openWith(void, {}, "interactive rebase last N commits: ", struct {
        fn done(depth: []const u8, _: void) void {
            if (depth.len == 0) return weft.echo("cancelled");
            startRebase(depth);
        }
    }.done);
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
    slot.value = .{ .session = model.curSession().id };
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
    model.Repos.routed = sessionById(slot.value.session) orelse return; // a plan names its own repository
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
/// stays, with the refusal shown — git's own words, off its own stderr.
fn gitRebaseSettle() void {
    const slot = cur().sequencing orelse return;
    cur().sequencing = null;
    settleDraft(Todos, &todos, slot, "rebased");
}

// ── Styling for the plain read-only views (diff/log) ────────────────────────
