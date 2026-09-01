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
const output = @import("weft_output");

const cmds = [_]weft.CommandEntry{
    .{ .name = "make-build", .call = makeBuild },
    .{ .name = "make-test", .call = makeTest },
    .{ .name = "make-run", .call = makeRun },
    .{ .name = "make-visit", .call = output.visit },
};

fn describeExtra() void {
    weft.requestPerm(.proc);
    weft.requestPerm(.timer);
}
fn initExtra() void {
    // Return jumps to the compiler error the focused row points at.
    output.installMode("build", "make-visit");
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

comptime {
    weft.plugin(&cmds, .{ .describe = describeExtra, .init = initExtra }).exportAll();
}
