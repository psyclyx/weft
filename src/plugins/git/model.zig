//! git — the MODEL. One repository's world as data: what a status
//! gather produced (files, hunks, the raw bytes they index into), which
//! repositories are open, and which one the running command is about.
//!
//! Nothing here renders, parses, or acts. It is the noun every other file
//! in this plugin is a verb over, split out when the plugin became a
//! directory: 2900 lines in one file had the model, the parser, the
//! projection, the targeting and every verb sharing a scope, and the
//! section comments standing in for the file layout that was not allowed.

const std = @import("std");
pub const weft = @import("weft");

// ── Caps on ONE repository's working state (bounded, degrade loud) ──
// These bound what a single gather can show — files, hunks, bytes of git
// output — and every one of them says so when it is reached. What is NOT here
// any more is a cap on how many repositories may be open: that was never about
// a gather's size, only about the height of a static array, and a wasm guest
// has a growable heap (`weft.allocator`) to hold sessions on instead.
pub const MAX_FILES = 128;
pub const MAX_HUNKS = 512;
pub const RAW_CAP = 1 << 18; // 256 KiB of raw git output (paged in via `slice`)
pub const RENDER_CAP = 1 << 18; // the pretty projection
pub const PATCH_CAP = 1 << 16; // a synthesized one-hunk patch

pub var cmd_buf: [1 << 13]u8 = undefined;
pub var msg_buf: [1 << 16]u8 = undefined;
pub var patch_buf: [PATCH_CAP]u8 = undefined;
/// Scratch for a partial hunk's transformed body (static — keeps it off the
/// small wasm stack).
pub var body_out: [PATCH_CAP]u8 = undefined;

pub const InputAction = enum(u8) { none, branch_checkout, branch_create, branch_new, branch_rename, branch_delete, rebase_start };

/// Buffer for building a rebase plan's todo lines + the transient op command.
pub var op_buf: [1 << 14]u8 = undefined;
/// The command handed to `procToBuffer`: the session's `cd` guard + the body.
pub var run_buf: [1 << 14]u8 = undefined;
/// Scratch for an absolute path inside the session's repository (`inRepo`).
pub var tmp_buf: [1024]u8 = undefined;
/// Scratch for the focused buffer's path made absolute (`activePathAbs`) —
/// `weft.path` and `weft.placeRoot` both borrow the shim's shared read
/// scratch, so the join needs a buffer neither of them owns.
pub var probe_buf: [1024]u8 = undefined;
/// Scratch for the dispatching place's directory (`placeDir`), copied off that
/// same shared scratch.
pub var base_buf: [1024]u8 = undefined;

/// ONE gather command: porcelain status (+ branch), the unstaged diff, the
/// staged diff, and recent commits, delimited by RS-prefixed sentinel lines we
/// can split on unambiguously (`\x1e\x1e{U,S,R}`). We repaint the buffer from
/// the parse, so these markers never reach the user's eyes.
pub const GATHER =
    "git status --porcelain=v1 --branch 2>/dev/null; " ++
    "printf '\\036\\036U\\n'; git diff 2>/dev/null; " ++
    "printf '\\036\\036S\\n'; git diff --cached 2>/dev/null; " ++
    "printf '\\036\\036R\\n'; git log --format='%h %s' -10 2>/dev/null";
pub const MARK_U = "\x1e\x1eU";
pub const MARK_S = "\x1e\x1eS";
pub const MARK_R = "\x1e\x1eR";
/// Precedes an effect's exit status when a fill carries one ahead of a gather.
pub const MARK_C = "\x1e\x1eC";

/// Instance base: session 1 takes `*git*`, session 2 `*git:2*` (weft.zig's
/// instanced-tool-buffer naming — a buffer name IS an instance's identity).
pub const buf_base = "git";
/// A status entry's tool identity. Every offer we publish is predicated on it,
/// so the verbs below are about a git buffer — not about whichever mode happens
/// to be active, and not about a rendered byte range.
pub const tool = "git";

// ── The model ────────────────────────────────────────────────────────────
pub const Section = enum(u8) { untracked = 0, unstaged = 1, staged = 2, recent = 3 };
pub const render_order = [_]Section{ .untracked, .unstaged, .staged, .recent };

pub const File = struct {
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
    pub fn path_(self: *const File) []const u8 {
        return self.path[0..self.plen];
    }
};

pub const Hunk = struct {
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
pub const MAX_COLLAPSED = 64;

/// One repository's whole world: its model, its projection, its buffer, its
/// in-flight interaction. Nothing here is shared, so two repositories open at
/// once cannot read or stage each other's files (§18: "two repositories …
/// remain isolated").
pub const RepoSession = struct {
    /// This session's identity, minted once and never reused. What a fill
    /// token, a pick id and a draft carry — none of them may name a row of a
    /// table, because the table moves.
    id: u32,
    /// Absolute repository root — the session's key AND the directory every one
    /// of its commands runs in. OWNED: a root that did not fit used to be
    /// truncated silently, which keys the session on a directory that is not
    /// the repository and then `cd`s into it.
    root: []u8,
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
    // authority (§14.3). We remember the target the node under point named and
    // the status fill re-finds it in the NEW model, landing on its rendered
    // start. `pending_cursor` is the fallback when the node is gone (e.g. the
    // file was fully staged away). `home_off` is where a fresh open lands.
    restore_cursor: bool = false,
    pending_cursor: usize = 0,
    home_off: usize = 0,
    restore_target: Target = .{},

    dropped_files: bool = false,
    dropped_hunks: bool = false,
    truncated_raw: bool = false,

    /// Snapshot identity (§14.3). `snapshot` names the gathered status the
    /// render (and every path/hunk reference in it) belongs to — a `Target`
    /// carries it, so what is snapshot-scoped cannot act across a re-gather.
    /// `gathering` says a newer one is already on its way, which makes the
    /// visible projection provisional.
    snapshot: u32 = 0,
    gathering: bool = false,
    /// The draft / rebase plan whose effect this repository has in flight —
    /// read by the settle the landing fill defers to.
    committing: ?*Drafts.Slot = null,
    sequencing: ?*Todos.Slot = null,

    // ── Interaction state (per repository: two sessions can each have their
    // own half-finished commit, confirm or prompt) ──
    /// What a DEFERRED verb acts on — the destructive confirmations and the
    /// reset transient, which fire after the question. Captured when the verb
    /// is armed, re-resolved when it fires.
    /// The commit `x` armed the reset transient with. Not a confirmation stash:
    /// a menu is a mode, and the leaf that reads this runs while it is still
    /// open. What a CONFIRMED verb acts on travels with its question instead.
    pending_target: Target = .{},
    /// A full mutation staged behind a confirmation (branch delete, stash
    /// drop, reset --hard) — run verbatim once the answer comes back `yes`.
    /// WHICH question the open prompt is asking. The typed TEXT is the
    /// prompt library's, not ours — a session used to carry a copy of it
    /// (`input_name`) because the answer had to survive a round trip through
    /// a real buffer; it is handed straight to `onInput` now.
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

    pub fn name(self: *const RepoSession) []const u8 {
        return self.name_buf[0..self.name_len];
    }
    /// A repository-relative path made absolute — `open` resolves against the
    /// editor's own working directory, which is not where this repository is.
    pub fn inRepo(self: *const RepoSession, leaf: []const u8) []const u8 {
        return std.fmt.bufPrint(&tmp_buf, "{s}/{s}", .{ self.root, leaf }) catch leaf;
    }
    /// The projection is provisional while a newer gather is in flight.
    pub fn fresh(self: *const RepoSession) bool {
        return !self.gathering;
    }
};

/// Live sessions, in open order, each individually allocated so a
/// `*RepoSession` handed out earlier survives the table growing —
/// `core/Buffers.zig`'s shape, and its reason: a draft names the session it
/// commits to, a fill token names the session it parses into, and both outlive
/// the command that made them.
///
/// There is no cap. How many repositories you may have open at once was never a
/// decision anybody made; the guest heap is the real bound, and it says so when
/// it refuses. A session is still never retired: its buffer, and therefore its
/// instance identity, outlives any single command.
pub var sessions: std.ArrayList(*RepoSession) = .empty;

/// The next session's identity. An ORDINAL, not an index: a fill token and a
/// pick id carry it across an async round trip, and a draft carries it for as
/// long as the draft lives, so it has to name a session rather than a row of a
/// table that no longer exists in that shape.
pub var next_session_id: u32 = 1;

/// The session the running command is about — set by the command funnel (from
/// the focused buffer or the buffer's repository) and by a landing fill (from
/// the session its token carries). Never inferred inside a handler.
///
/// Optional because "no repository is open yet" is a real state. It used to be
/// spelled as a blank row of the fixed table — a session that is not one — and
/// the only reader that could see it was `on_activate`'s offer publication.
pub var routed: ?*RepoSession = null;

/// The session this command is about. Every entry point routes before it hands
/// control to a handler (`on_command`'s funnel, `on_fill_token`'s and
/// `on_pick_accept`'s token, `currentDraft`'s draft), so a handler's `cur()` is
/// always answered — the same dominated assertion `Buffers.active()` makes.
pub fn cur() *RepoSession {
    return routed.?;
}

/// The session `id` names, or null for an id we never issued.
pub fn sessionById(id: u32) ?*RepoSession {
    for (sessions.items) |s| {
        if (s.id == id) return s;
    }
    return null;
}

// ── Targeting: the identity a row carries (design §14.3) ────────────────────
// A commit is a durable OID. A file is a revisioned name — section plus path,
// re-resolved against whatever model is live. A hunk, and a line selection
// inside one, are SNAPSHOT-SCOPED: they name nothing once a re-gather has
// rebuilt the tree.
//
// The TYPES live here because a session holds one (`restore_target`); the
// resolution — hit-testing the cursor, checking a target against the live
// model — is a verb, and stays with the verbs.

/// What a rendered row IS. `render.zig` maps an offset to one of these;
/// nothing else may.
pub const Kind = enum { none, section, file, hunk, commit };
pub const Node = struct { kind: Kind, idx: usize };

/// A half-open range of BODY LINE ordinals inside one hunk.
pub const Lines = struct { lo: usize, hi: usize };

pub const Target = struct {
    kind: Kind = .none,
    snap: u32 = 0,
    section: Section = .untracked,
    path: [256]u8 = undefined,
    plen: usize = 0,
    ord: usize = 0, // the hunk's ordinal within its file
    sel: ?Lines = null, // selected body lines of that hunk
    hash: [64]u8 = undefined,
    hlen: usize = 0,

    pub fn path_(self: *const Target) []const u8 {
        return self.path[0..self.plen];
    }
    pub fn hash_(self: *const Target) []const u8 {
        return self.hash[0..self.hlen];
    }
};

// ── Drafts: the editable middle ─────────────────────────────────────────
// A commit message and a rebase plan are OWNED text a repository has in
// flight, so their types are model. The live instance tables are not:
// opening one is a verb, and `root.zig` owns it.

/// What a draft remembers besides its text: the repository SESSION it commits
/// to (bound once, when the entry opens) and the flags amend/reword put on it.
pub const Draft = struct {
    /// The session this draft belongs to, by ID. A draft never asks what is
    /// focused — it commits to the repository it was written for, forever, and
    /// an id outlives a table row.
    session: u32 = 0,
    flags: [64]u8 = undefined,
    flags_len: usize = 0,
    /// The commit this draft was opened ONTO (fixup/squash) — a durable OID,
    /// and what a re-seat needs. `.none` for an ordinary commit.
    onto: Target = .{},

    pub fn flagsOf(self: *const Draft) []const u8 {
        return self.flags[0..self.flags_len];
    }
};
pub const Drafts = weft.Instances(Draft);

/// A rebase plan: an ordinary instanced entry too, saved to run its rebase.
pub const Todo = struct {
    session: u32 = 0,
    base: [64]u8 = undefined, // the rebase base ref (`HEAD~N`)
    base_len: usize = 0,
};
pub const Todos = weft.Instances(Todo);

/// The tool identity a draft entry carries — what scopes its `save` provider.
pub const draft_tool = "git-commit";
pub const todo_tool = "git-rebase";

// ── Fill routing: what an async gather's output IS, and whose ────────────
/// Which fill a `show` issued. Declared at spawn, handed back at delivery, so
/// the landing output routes to its own handler — never to whichever buffer
/// happens to be focused when the command finishes.
pub const Fill = enum(u32) {
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
/// `Fill`, the rest the session's id. Delivery therefore needs no guess about
/// focus — the output of repository 2's gather can only ever parse into
/// repository 2's model.
///
/// The id gets 24 bits, and that is not a limit anyone can reach: a session is
/// half a megabyte and a wasm32 guest's linear memory tops out at 4 GiB, so the
/// heap refuses (out loud, in `sessionFor`) some four thousand ids before the
/// field could ever run out.
pub fn fillToken(fill: Fill, s: *const RepoSession) u32 {
    return @intFromEnum(fill) | (s.id << 8);
}

/// Which fills carry a status gather — the ones that make the projection
/// provisional on the way out and land a new snapshot on the way back.
pub fn gathers(fill: Fill) bool {
    return switch (fill) {
        .status, .commit, .sequence => true,
        else => false,
    };
}

/// Focus `name`, minting the buffer if it does not exist.
pub fn focusBuffer(name: []const u8) bool {
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
