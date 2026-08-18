//! direnv — per-project environment tooling (design §6.6), a `.wasm` plugin
//! (perms `{proc, timer}`). It surfaces direnv's state/actions into tool
//! buffers via the native `proc` surface: status, allow (TOFU-shaped — runs
//! arbitrary code on the target host, hence a deliberate explicit action), and
//! reload. Applying the exported env to sibling `proc`/LSP calls (the
//! `direnv.env-for` provider) is the next step, once a per-project env overlay
//! crosses the membrane.

const std = @import("std");
const weft = @import("weft.zig");

const Cmd = struct { name: []const u8, handler: *const fn () void };
const cmds = [_]Cmd{
    .{ .name = "direnv-status", .handler = status },
    .{ .name = "direnv-allow", .handler = allow },
    .{ .name = "direnv-reload", .handler = reload },
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

fn show(cmd: []const u8) void {
    weft.runStr("buffer-create", "*direnv*");
    weft.procToBuffer(cmd, "*direnv*");
}
fn status() void {
    show("direnv status 2>&1");
}
fn allow() void {
    show("direnv allow 2>&1 && echo allowed");
}
fn reload() void {
    show("direnv reload 2>&1 && echo reloaded");
}
