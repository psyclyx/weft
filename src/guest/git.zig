//! git — a magit-lite over the git subprocess (design §6.6), a `.wasm` plugin.
//! Each command creates+focuses a tool buffer and fills it asynchronously with
//! the output of a git invocation via the native `proc` surface — the output
//! lands authored as this plugin's peer, off the frame thread. perms
//! `{proc, timer}`; grant_max edit (it only writes its own tool buffers).
//! Read-only views for now; staging/commit verbs arrive with an interactive
//! proc channel.

const std = @import("std");
const weft = @import("weft.zig");

var cmd_buf: [1 << 12]u8 = undefined;

const Cmd = struct { name: []const u8, handler: *const fn () void };
const cmds = [_]Cmd{
    .{ .name = "git-status", .handler = gitStatus },
    .{ .name = "git-log", .handler = gitLog },
    .{ .name = "git-diff", .handler = gitDiff },
    .{ .name = "git-diff-staged", .handler = gitDiffStaged },
    .{ .name = "git-blame", .handler = gitBlame },
    // magit-style verbs, live in the *git-status* buffer's own mode.
    .{ .name = "git-stage", .handler = gitStage },
    .{ .name = "git-unstage", .handler = gitUnstage },
    .{ .name = "git-refresh", .handler = gitStatus },
    .{ .name = "git-open", .handler = gitOpen },
};

export fn describe() void {
    for (cmds) |c| weft.declareCommand(c.name);
    weft.requestPerm(.proc);
    weft.requestPerm(.timer);
}
export fn init() void {
    for (cmds) |c| _ = weft.register(c.name);
    // The magit-style keymap is navigation-only: it swallows typing (the status
    // list isn't editable) and binds movement + its verbs — no fallback to
    // normal, so there's no insert leak into the tool buffer.
    weft.textInput("magit", null);
    weft.bindKey("magit", "j", "cursor-down");
    weft.bindKey("magit", "k", "cursor-up");
    weft.bindKey("magit", "Down", "cursor-down");
    weft.bindKey("magit", "Up", "cursor-up");
    weft.bindKey("magit", "s", "git-stage");
    weft.bindKey("magit", "u", "git-unstage");
    weft.bindKey("magit", "g", "git-refresh");
    weft.bindKey("magit", "Return", "git-open");
    weft.bindKey("magit", "q", "buf-scratch");
}
export fn on_command(id: u32) void {
    if (id < cmds.len) cmds[id].handler();
}

/// The path on the current *git-status* line: `git status --short` prints
/// "XY path" (status in cols 0-1, path from col 3), so drop the leading status
/// field. Returns "" for a header line (e.g. the `## branch` line). Copied out
/// of the shared scratch into `path_buf` before any further membrane call.
var path_buf: [512]u8 = undefined;
fn currentPath() []const u8 {
    const line = weft.lineAt(weft.cursor());
    const raw = weft.slice(line.start, line.end);
    if (raw.len < 4 or (raw[0] == '#' and raw[1] == '#')) return "";
    const rel = std.mem.trim(u8, raw[3..], " \t\r\n");
    const n = @min(rel.len, path_buf.len);
    @memcpy(path_buf[0..n], rel[0..n]);
    return path_buf[0..n];
}

/// Stage / unstage the file under the cursor, then refresh — chained in one
/// shell command so the status re-reads AFTER the index change (no async race).
fn gitStage() void {
    const path = currentPath();
    if (path.len == 0) return;
    const cmd = std.fmt.bufPrint(&cmd_buf, "git add -- '{s}' && git status --short --branch", .{path}) catch return;
    show(cmd, "*git-status*");
    weft.setMode("magit");
}
fn gitUnstage() void {
    const path = currentPath();
    if (path.len == 0) return;
    const cmd = std.fmt.bufPrint(&cmd_buf, "git reset -q HEAD -- '{s}' && git status --short --branch", .{path}) catch return;
    show(cmd, "*git-status*");
    weft.setMode("magit");
}
fn gitOpen() void {
    const path = currentPath();
    if (path.len == 0) return;
    weft.runStr("open", path);
}

/// Create+focus the tool buffer, then fill it with `cmd`'s output async.
fn show(cmd: []const u8, name: []const u8) void {
    weft.runStr("buffer-create", name); // creates + focuses an empty scratch
    weft.procToBuffer(cmd, name);
}
fn gitStatus() void {
    show("git status --short --branch", "*git-status*");
    weft.setMode("magit"); // rich status buffer: s stage, u unstage, g refresh
}
fn gitLog() void {
    show("git log --oneline --graph -30", "*git-log*");
}
fn gitDiff() void {
    show("git diff", "*git-diff*");
}
fn gitDiffStaged() void {
    show("git diff --staged", "*git-diff-staged*");
}
fn gitBlame() void {
    const path = weft.path() orelse return;
    const cmd = std.fmt.bufPrint(&cmd_buf, "git blame -- {s}", .{path}) catch return;
    show(cmd, "*git-blame*");
}
