//! git — GATHER PLUMBING: run a command, then re-read the world.
//!
//! Every mutation git makes is `mutation && GATHER` (or `mutation; GATHER`)
//! in ONE shell command, so the index reflects the mutation with no async
//! read/write race in between. Bytes a command needs — a patch, a commit
//! message, a rebase plan — are SPOOLED: the host writes a temp it names and
//! removes, which is why this plugin holds no `fs_write` and no command of
//! ours ends in `rm -f`.
//!
//! It sits under both the verbs and the transients, which is why it is its
//! own file rather than living with either.

const std = @import("std");
const weft = @import("weft");
const model = @import("model.zig");
const render_mod = @import("render.zig");
const cur = model.cur;
const Target = model.Target;
const GATHER = model.GATHER;
const MARK_C = model.MARK_C;
const tool = model.tool;
const Fill = model.Fill;
const fillToken = model.fillToken;
const gathers = model.gathers;
const nodeAtCursor = render_mod.nodeAtCursor;
const focusBuffer = model.focusBuffer;

/// Scratch for a command line built here.
var cmd_buf: [1 << 13]u8 = undefined;

/// The command handed to `procToBuffer`: the session's `cd` guard + the body.
var run_buf: [1 << 14]u8 = undefined;
/// Buffer for building a mutation's command line.
var op_buf: [1 << 14]u8 = undefined;

// ── Gather plumbing: mutate-then-re-gather in ONE shell command ─────────────
/// Focus the named tool buffer (reused across refreshes — `buffer-create` does
/// NOT dedupe by name, so re-creating would pile up duplicates and misdirect the
/// async fill to a stale, unfocused copy), then fill it with `cmd`'s output RUN
/// IN THIS SESSION'S REPOSITORY. The `cd` guard is the session boundary: a root
/// that has gone away aborts the command rather than letting it act on whatever
/// repository the editor's working directory happens to be.
pub fn show(cmd: []const u8, name: []const u8, fill: Fill) void {
    showInput(cmd, null, name, fill);
}

/// `show`, plus bytes the command reads back off disk from `{}`. The bytes are
/// SPOOLED: `weft.procSpool` writes them to a temp the HOST names, substitutes
/// its path, and deletes it when the command is done — succeeded or failed.
/// Every file git used to drop into the work tree (`.weft-git.patch`, a draft's
/// message, a rebase plan) comes through here instead, which is why git holds
/// no `fs_write` and no command of ours ends in `rm -f`.
pub fn showInput(cmd: []const u8, stdin: ?[]const u8, name: []const u8, fill: Fill) void {
    const body = std.fmt.bufPrint(&run_buf, "cd '{s}' || exit 0\n{s}", .{ cur().root, cmd }) catch return;
    if (!focusBuffer(name)) weft.runStr("buffer-create", name);
    if (gathers(fill)) {
        // A status entry carries git's tool identity: it is what the published
        // offers are ABOUT, and the fact the catalog matches them on.
        weft.toolBacking(tool);
        cur().gathering = true; // the projection is now provisional
    }
    const token = fillToken(fill, cur());
    if (stdin) |bytes| weft.procSpool(body, bytes, name, token) else weft.procToBuffer(body, name, token);
}

/// Re-gather this session's status into its own buffer.
pub fn gather(cmd: []const u8) void {
    show(cmd, cur().name(), .status);
}

/// Preserve the cursor spot across the coming re-render: capture the node
/// identity (re-found in the new model) plus the raw offset as a fallback.
pub fn markRestore() void {
    cur().restore_cursor = true;
    cur().pending_cursor = weft.cursor();
    cur().restore_target = nodeAtCursor();
}

/// `mutation && GATHER` into *git* — the index reflects the mutation with no
/// async read/write race.
pub fn gatherAfter(mutation: []const u8) void {
    markRestore();
    const cmd = std.fmt.bufPrint(&cmd_buf, "{s} && " ++ GATHER, .{mutation}) catch return;
    gather(cmd);
    weft.setMode("git");
}
/// Same, but the mutation is a `fmt` with a single path arg.
pub fn gatherAfter1(comptime fmt: []const u8, pth: []const u8) void {
    markRestore();
    const cmd = std.fmt.bufPrint(&cmd_buf, fmt ++ " && " ++ GATHER, .{pth}) catch return;
    gather(cmd);
    weft.setMode("git");
}
/// Like `gatherAfter` but SEQUENCES with `;` (not `&&`) and swallows the op's
/// stdout — the op runs, then we ALWAYS re-gather so *git* reflects the real
/// post-op state even when the op "failed" (a cherry-pick conflict, a reset, a
/// push that left us still-ahead). Used by every Phase-2b/2c mutation.
pub fn gatherAfterSeq(mutation: []const u8) void {
    markRestore();
    const cmd = std.fmt.bufPrint(&cmd_buf, "{s} >/dev/null 2>&1; " ++ GATHER, .{mutation}) catch return;
    gather(cmd);
    weft.setMode("git");
}
/// Same, with a single `{s}` arg (a hash or a quoted name) in `fmt`.
pub fn gatherAfterSeq1(comptime fmt: []const u8, arg: []const u8) void {
    markRestore();
    const cmd = std.fmt.bufPrint(&cmd_buf, fmt ++ " >/dev/null 2>&1; " ++ GATHER, .{arg}) catch return;
    gather(cmd);
    weft.setMode("git");
}

/// `git apply <flags> <patch>` (optionally also reverse it from the worktree for
/// a staged-hunk discard), then re-gather. `{}` is the SPOOLED patch: the host
/// writes it, hands `git apply` the path, and removes it — including when the
/// apply fails, which is exactly when the old in-repo temp used to survive.
/// `git apply` reads its patch file from anywhere, so it need not be in the
/// work tree; only the paths INSIDE the patch are repo-relative, and those are
/// resolved by the `cd` guard `showInput` prepends.
pub fn gatherAfterPatch(patch: []const u8, flags: []const u8, also_worktree: bool) void {
    markRestore();
    const cmd = if (also_worktree)
        std.fmt.bufPrint(&cmd_buf, "git apply {s} {{}}; git apply --reverse {{}}; " ++ GATHER, .{flags}) catch return
    else
        std.fmt.bufPrint(&cmd_buf, "git apply {s} {{}}; " ++ GATHER, .{flags}) catch return;
    showInput(cmd, patch, cur().name(), .status);
    weft.setMode("git");
}
