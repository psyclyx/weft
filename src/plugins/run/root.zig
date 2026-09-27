//! run — run an arbitrary shell command into a tool buffer (design §6.6), a
//! `.wasm` plugin cut from the same cloth as `git`. Each command creates+focuses
//! an `*output*` buffer and fills it asynchronously with the command's stdout via
//! the native `proc` surface — the output lands authored as this plugin's peer,
//! off the frame thread. perms `{proc, timer}`; grant_max edit (it only writes
//! its own tool buffer). The command line comes either as an arg (`run.command`)
//! or from the current buffer line (`run.line`, for scratch/command notes).
//! Navigation is `output.zig`'s: each row's location is captured when the fill
//! lands, and Return visits the focused row's location.

const std = @import("std");
const weft = @import("weft");
const output = @import("weft_output");
const statusline = @import("weft_statusline");

/// Scratch for the shell command line built from a buffer slice (`run.line`),
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
    .{ .name = "run.command", .call = runCommand, .arity = .whole, .params = "command", .summary = "Run a shell command, streaming its output into *output*.", .label = "Run Command", .menu = "Terminal", .group = "run", .order = 1, .prompts = true },
    .{ .name = "run.line", .arity = .one, .call = runLine, .summary = "Run the current line as a shell command.", .label = "Run Line", .menu = "Run", .group = "run", .order = 2 },
    .{ .name = "run.visit-output", .call = output.visit, .arity = .one, .summary = "Open the location the focused output row names.", .internal = true },
};

fn describeExtra() void {
    weft.requestPerm(.proc);
    weft.requestPerm(.timer);
}
fn initExtra() void {
    // `*output*` is navigable: Return jumps to the stack frame or compile error
    // the focused row points at, j/k walk, q goes back.
    output.installMode("output", "run.visit-output");
    // A running command on the status line, beside a running build (94).
    statusline.bind(.{ .all = &.{} }, .core, 93);
}

// A shell, spelled out. `run` is the one consumer that genuinely wants one —
// its whole purpose is running a shell command line — so it says `sh -c` and
// hands the line over as ONE argument. That is a decision in the source rather
// than a string that happens to reach a shell, and it is why every OTHER
// consumer of this library no longer has a shell in its path at all.
fn shell(line: []const u8) void {
    output.show(&.{ "sh", "-c", line }, out_name, "output", .{ .want_err = true, .running = .{ .key = running_key, .what = "run" } });
}

// ── A running command, on the status line (doc/chrome.md §4.3) ──────────────

/// Said on the place a command started in while it runs (`output.Running`).
const running_key = "run.running";

fn onSlotFire(session: i32) callconv(.c) void {
    const handle: u32 = @bitCast(session);
    _ = statusline.ask(handle) orelse return;
    if (output.runningHere(running_key) == null) return statusline.tell(handle, &.{});
    statusline.tell(handle, &.{.{ .text = "running…", .role = .accent, .priority = 55, .icon = "play", .tooltip = "A shell command is running" }});
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
    weft.exportCallback("on_slot_fire", &onSlotFire);
}
