//! run — run an arbitrary shell command into a tool buffer (design §6.6), a
//! `.wasm` plugin cut from the same cloth as `git`. Each command creates+focuses
//! an `*output*` buffer and fills it asynchronously with the command's stdout via
//! the native `proc` surface — the output lands authored as this plugin's peer,
//! off the frame thread. perms `{proc, timer}`; grant_max edit (it only writes
//! its own tool buffer). The command line comes either as an arg (`run-command`)
//! or from the current buffer line (`run-line`, for scratch/command notes).
//! Navigation is `output.zig`'s: each row's location is captured when the fill
//! lands, and Return visits the focused row's location.

const std = @import("std");
const weft = @import("weft");
const output = @import("weft_output");

/// Scratch for the shell command line built from a buffer slice (`run-line`),
/// which borrows `weft`'s read scratch and so must be copied before use.
var cmd_buf: [1 << 12]u8 = undefined;

const out_name = "*output*";

/// `params` is the command's argument shape, written the way a person reads
/// it back (`describeCommand`): the palette shows it beside the row, the `:`
/// line hints it while you type, and it is what gets ASKED for when a call
/// arrives short.
const Cmd = struct {
    name: []const u8,
    handler: *const fn () void,
    params: []const u8 = "",
    summary: []const u8 = "",
};
const cmds = [_]weft.CommandEntry{
    .{ .name = "run-command", .call = runCommand, .params = "command", .summary = "Run a shell command, streaming it into *output*." },
    .{ .name = "run-line", .call = runLine, .summary = "Run the current line as a shell command." },
    .{ .name = "output-visit", .call = output.visit, .summary = "Open the location the focused output row names." },
};

fn describeExtra() void {
    weft.requestPerm(.proc);
    weft.requestPerm(.timer);
}
fn initExtra() void {
    // `*output*` is navigable: Return jumps to the stack frame or compile error
    // the focused row points at, j/k walk, q goes back.
    output.installMode("output", "output-visit");
}

// A shell, spelled out. `run` is the one consumer that genuinely wants one —
// its whole purpose is running a shell command line — so it says `sh -c` and
// hands the line over as ONE argument. That is a decision in the source rather
// than a string that happens to reach a shell, and it is why every OTHER
// consumer of this library no longer has a shell in its path at all.
fn shell(line: []const u8) void {
    output.show(&.{ "sh", "-c", line }, out_name, "output", .{ .want_err = true });
}

/// Run the command line passed as arg 0; no-op if none was given.
fn runCommand() void {
    shell(weft.argStr(0) orelse return);
}
/// Run the current line of the buffer as a shell command.
fn runLine() void {
    const l = weft.lineAt(weft.cursor());
    const line = weft.slice(l.start, l.end); // borrows read scratch
    // Copy out of the read scratch — the call below outlives this read.
    const cmd = std.fmt.bufPrint(&cmd_buf, "{s}", .{line}) catch return;
    shell(cmd);
}

comptime {
    weft.plugin(&cmds, .{ .describe = describeExtra, .init = initExtra }).exportAll();
}
