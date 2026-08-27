//! make — build/test runners into tool buffers, a `.wasm` plugin. Each command
//! creates+focuses a tool buffer and fills it asynchronously with the output of
//! a build invocation via the native `proc` surface — the output lands authored
//! as this plugin's peer, off the frame thread. perms `{proc, timer}`; it only
//! writes its own tool buffers. Commands are hardcoded for now; project-aware
//! detection (which runner, which target) arrives with the project plugin.
//! Build output is navigable exactly like `run`'s because both consume
//! `output.zig` — same table, same visit — not because `make` borrows `run`'s
//! mode: it owns `build`, and works whether or not `run` is loaded.

const std = @import("std");
const weft = @import("weft");
const output = @import("output.zig");

const Cmd = struct { name: []const u8, handler: *const fn () void };
const cmds = [_]Cmd{
    .{ .name = "make-build", .handler = makeBuild },
    .{ .name = "make-test", .handler = makeTest },
    .{ .name = "make-run", .handler = makeRun },
    .{ .name = "make-visit", .handler = output.visit },
};

export fn describe() void {
    for (cmds) |c| weft.declareCommand(c.name);
    weft.requestPerm(.proc);
    weft.requestPerm(.timer);
}
export fn init() void {
    for (cmds) |c| _ = weft.register(c.name);
    // Return jumps to the compiler error the focused row points at.
    output.installMode("build", "make-visit");
}
export fn on_command(id: u32) void {
    if (id < cmds.len) cmds[id].handler();
}

/// The fill landed: capture each row's location before the text is anyone's
/// to restyle. The host bound the entry this fill captured, so nothing here
/// asks what is focused.
export fn on_fill_token(token: u32) void {
    output.fill(token, null);
}

fn makeBuild() void {
    output.show("zig build", "*build*", "build");
}
fn makeTest() void {
    output.show("zig build test", "*test*", "build");
}
fn makeRun() void {
    output.show("make", "*build*", "build");
}
