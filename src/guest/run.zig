//! run — run an arbitrary shell command into a tool buffer (design §6.6), a
//! `.wasm` plugin cut from the same cloth as `git`. Each command creates+focuses
//! an `*output*` buffer and fills it asynchronously with the command's stdout via
//! the native `proc` surface — the output lands authored as this plugin's peer,
//! off the frame thread. perms `{proc, timer}`; grant_max edit (it only writes
//! its own tool buffer). The command line comes either as an arg (`run-command`)
//! or from the current buffer line (`run-line`, for scratch/command notes).

const std = @import("std");
const weft = @import("weft.zig");

/// Scratch for the shell command line built from a buffer slice (`run-line`),
/// which borrows `weft`'s read scratch and so must be copied before use.
var cmd_buf: [1 << 12]u8 = undefined;

const out_name = "*output*";

const Cmd = struct { name: []const u8, handler: *const fn () void };
const cmds = [_]Cmd{
    .{ .name = "run-command", .handler = runCommand },
    .{ .name = "run-line", .handler = runLine },
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

/// Create+focus the `*output*` tool buffer, then fill it with `cmd`'s output async.
fn show(cmd: []const u8) void {
    weft.runStr("buffer-create", out_name); // creates + focuses an empty scratch
    weft.procToBuffer(cmd, out_name);
}
/// Run the command line passed as arg 0; no-op if none was given.
fn runCommand() void {
    const cmd = weft.argStr(0) orelse return;
    show(cmd);
}
/// Run the current line of the buffer as a shell command.
fn runLine() void {
    const l = weft.lineAt(weft.cursor());
    const line = weft.slice(l.start, l.end); // borrows read scratch
    // Copy out of the read scratch — `procToBuffer`/`runStr` need it stable.
    const cmd = std.fmt.bufPrint(&cmd_buf, "{s}", .{line}) catch return;
    show(cmd);
}
