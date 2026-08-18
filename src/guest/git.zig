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
};

export fn describe() void {
    for (cmds) |c| weft.declareCommand(c.name);
    weft.requestPerm(.proc);
    weft.requestPerm(.timer);
}
export fn init() void {
    for (cmds) |c| _ = weft.register(c.name);
}
export fn on_command(id: u32) void {
    if (id < cmds.len) cmds[id].handler();
}

/// Create+focus the tool buffer, then fill it with `cmd`'s output async.
fn show(cmd: []const u8, name: []const u8) void {
    weft.runStr("buffer-create", name); // creates + focuses an empty scratch
    weft.procToBuffer(cmd, name);
}
fn gitStatus() void {
    show("git status --short --branch", "*git-status*");
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
