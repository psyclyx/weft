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
const sessions_lib = @import("weft_sessions");

// ── Caps on ONE repository's working state (bounded, degrade loud) ──
// These bound what a single gather can show — files, hunks, bytes of git
// output — and every one of them says so when it is reached. What is NOT here
// any more is a cap on how many repositories may be open: that was never about
// a gather's size, only about the height of a static array, and a wasm guest
// has a growable heap (`weft.allocator`) to hold sessions on instead.
pub const MAX_FILES = 128;
pub const MAX_HUNKS = 512;
pub const RAW_CAP = 1 << 18; // 256 KiB of raw git output (paged in via `slice`)
pub const PATCH_CAP = 1 << 16; // a synthesized one-hunk patch

pub var cmd_buf: [1 << 13]u8 = undefined;
pub var msg_buf: [1 << 16]u8 = undefined;
pub var patch_buf: [PATCH_CAP]u8 = undefined;
/// Scratch for a partial hunk's transformed body (static — keeps it off the
/// small wasm stack).
pub var body_out: [PATCH_CAP]u8 = undefined;

/// Buffer for building a rebase plan's todo lines + the transient op command.
pub var op_buf: [1 << 14]u8 = undefined;
/// Scratch for an absolute path inside the session's repository (`inRepo`).
pub var tmp_buf: [1024]u8 = undefined;
/// Scratch for the focused buffer's path made absolute (`activePathAbs`) —
/// `weft.path` and `weft.placeRoot` both borrow the shim's shared read
/// scratch, so the join needs a buffer neither of them owns.
pub var probe_buf: [1024]u8 = undefined;
/// Scratch for the dispatching place's directory (`placeDir`), copied off that
/// same shared scratch.
pub var base_buf: [1024]u8 = undefined;

/// A gather is FOUR commands, and it always was — it merely had one output
/// channel, so it was written as one shell line with sentinel lines
/// (`\x1e\x1e{U,S,R}`) printed between the parts for the parser to split on.
/// The sentinels were never about git; they were about the door.
///
/// `weft.exec` returns each command's stdout separately, so the parts arrive
/// as parts. What the parser needs is where each region begins and ends, and
/// the assembler records that as it appends (`Session.bounds`) instead of
/// scanning the bytes for a marker that had to be chosen to never collide
/// with a filename.
pub const Part = enum(u8) { status = 0, unstaged = 1, staged = 2, recent = 3 };
pub const part_count = 4;

/// How a read-only view's text is coloured. These used to be members of a
/// `Fill` enum that also carried the routing — which delivery this was, and
/// for whom — because a fill token was one `u32` doing three jobs. The routing
/// travels with the continuation now, so what is left here is only the
/// question a view actually has: what does this text look like.
pub const ViewStyle = enum { none, diff, log, rebase_todo };

/// What runs after a gather assembles, and after a view's text lands. Set by
/// `root.zig` at init.
///
/// A hook rather than a direct call because the SEQUENCING is root's: a
/// settled gather has to parse, repaint, land the cursor, republish offers,
/// and note anything dropped — a chain that reaches most of the plugin. This
/// file's job ends when the bytes are in the model, and saying so with a
/// function pointer keeps `gather.zig` readable without the rest of the
/// plugin in your head, which is the property its module doc claims.
pub var on_gathered: ?*const fn () void = null;
pub var on_view_filled: ?*const fn (ViewStyle) void = null;
/// Publish this view as a projection, given the command's own output. Returns
/// false for the styles that stay plain text, which then take `on_view_filled`.
pub var on_view_project: ?*const fn (name: []const u8, ViewStyle, text: []const u8) bool = null;

/// The argv for each part. No shell, so no quoting, and a path with an
/// apostrophe or a newline in it is one argument rather than a broken command.
pub fn argvFor(part: Part) []const []const u8 {
    return switch (part) {
        .status => &.{ "git", "status", "--porcelain=v1", "--branch" },
        .unstaged => &.{ "git", "diff" },
        .staged => &.{ "git", "diff", "--cached" },
        .recent => &.{ "git", "log", "--format=%h %s", "-10" },
    };
}

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
    pub fn path_(self: *const File) []const u8 {
        return self.path[0..self.plen];
    }
};

pub const Hunk = struct {
    file: usize,
    at: usize, // `@@` line through end of body, in `raw`
    len: usize,
};

/// One repository.s whole world: its model, its projection, its in-flight
/// interaction. Nothing here is shared, so two repositories open at once cannot
/// read or stage each other.s files (§18: "two repositories … remain
/// isolated").
///
/// IDENTITY IS NOT HERE. The id, the absolute root and the instanced buffer
/// name belong to `weft_sessions`, which owns find-or-mint and routing for
/// every plugin that projects a per-place authority — so this struct is the
/// part that is actually about git.
pub const RepoState = struct {
    files: [MAX_FILES]File = undefined,
    file_count: usize = 0,
    hunks: [MAX_HUNKS]Hunk = undefined,
    hunk_count: usize = 0,

    raw: [RAW_CAP]u8 = undefined,
    raw_len: usize = 0,
    /// Where each gathered part ENDS in `raw`, in `Part` order. Recorded by
    /// the assembler as it appends, which is what replaced scanning the bytes
    /// for a sentinel: the boundary is known at the moment it is created, so
    /// nothing has to be chosen to never collide with a filename.
    bounds: [part_count]usize = @splat(0),
    /// Parts of the in-flight gather still outstanding. A gather is done when
    /// this reaches zero; until then the model is the previous one.
    pending_parts: u8 = 0,
    /// Each part's stdout, owned, held only between its arrival and the
    /// assembly that consumes every part. Allocated rather than four more
    /// fixed arrays: the four subprocesses finish in whatever order they
    /// finish, so all four have to be holdable at once, and a `git diff` is
    /// exactly the thing whose size the plugin does not get to decide.
    part_bytes: [part_count]?[]u8 = @splat(null),

    /// What the last noted mutation said and whether it succeeded. `git`'s own
    /// words, off its own stderr, and its own exit status — where both used to
    /// be recovered from a marker the command was made to print into stdout.
    effect_ok: bool = false,
    effect_note: [512]u8 = undefined,
    effect_note_len: usize = 0,

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
    sec_present: [4]bool = @splat(false),
    sec_count: [4]usize = @splat(0),

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

    // ── Interaction state ──
    //
    // ONE field, where there were nine. The rest were each half of a demux,
    // and each went when its other half did: the push/pull/fetch flags belong
    // to the transient that arms them, `commit_flags` and `rebase_base` to the
    // draft that carries them, and `input_action` to the prompt that asks.
    // What is left is the one case where a value really is parked between two
    // keystrokes rather than travelling with a question.
    /// The commit `x` armed the reset menu with. Not a confirmation stash: a
    /// menu is a mode, and the leaf that reads this runs while it is still
    /// open. What a CONFIRMED verb acts on travels with its question instead.
    pending_target: Target = .{},

    /// The projection is provisional while a newer gather is in flight.
    pub fn fresh(self: *const RepoState) bool {
        return !self.gathering;
    }
};

/// git.s sessions. Identity, find-or-mint, instance naming and routing are the
/// library.s; what is per-repository and about GIT is `RepoState` above.
pub const Repos = sessions_lib.Registry(RepoState, .{
    .base = buf_base,
    .no_place = "git: this place has no local repository",
    .no_memory = "git: out of memory — could not open this repository",
});
pub const RepoSession = Repos.Session;

/// A repository-relative path made absolute — `open` resolves against the
/// editor.s own working directory, which is not where this repository is.
pub fn inRepo(s: *const RepoSession, leaf: []const u8) []const u8 {
    return std.fmt.bufPrint(&tmp_buf, "{s}/{s}", .{ s.root, leaf }) catch leaf;
}

/// The session the running command is about, as a POINTER TO ITS STATE. Every
/// entry point routes before it hands control to a handler, so a handler.s
/// `cur()` is always answered — the same dominated assertion `Buffers.active()`
/// makes. Two spellings because two questions: `cur()` is "the repository I am
/// acting on", `curSession()` is "which session that is".
pub fn cur() *RepoState {
    return &Repos.routed.?.value;
}
pub fn curSession() *RepoSession {
    return Repos.routed.?;
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
