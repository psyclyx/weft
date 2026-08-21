//! make — build/test runners into tool buffers, a `.wasm` plugin. Each command
//! creates+focuses a tool buffer and fills it asynchronously with the output of
//! a build invocation via the native `proc` surface — the output lands authored
//! as this plugin's peer, off the frame thread. perms `{proc, timer}`; it only
//! writes its own tool buffers. Commands are hardcoded for now; project-aware
//! detection (which runner, which target) arrives with the project plugin.

const std = @import("std");
const weft = @import("weft.zig");

const Cmd = struct { name: []const u8, handler: *const fn () void };
const cmds = [_]Cmd{
    .{ .name = "make-build", .handler = makeBuild },
    .{ .name = "make-test", .handler = makeTest },
    .{ .name = "make-run", .handler = makeRun },
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

/// Create+focus the tool buffer, then fill it with `cmd`'s output async. Build
/// and test output is command output like `run`'s, so it enters the same shared
/// `output` mode — Return jumps to a compiler error's `file:line` (the `run`
/// plugin owns the mode + output-visit; if it isn't loaded this is an inert
/// no-op). weft modes are global, so this is reuse, not a hard dependency.
fn run(cmd: []const u8, name: []const u8) void {
    weft.runStr("buffer-create", name); // creates + focuses an empty scratch
    weft.setMode("output"); // navigable: Return visits a file:line (see run.zig)
    weft.procToBuffer(cmd, name);
}
fn makeBuild() void {
    run("zig build", "*build*");
}
fn makeTest() void {
    run("zig build test", "*test*");
}
fn makeRun() void {
    run("make", "*build*");
}
