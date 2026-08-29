//! windows — the window/split surface (design §6.1), a `.wasm` plugin
//! (perms `{}`). It provides the `win.*` command names over the core region
//! primitives (split/vsplit/focus/unsplit/center are carved by the gfx region
//! tree, never offset math), so a config binds windows through one door. Local
//! by irrelevance — no wire — and identical over a remote buffer.

const std = @import("std");
const weft = @import("weft");

const Cmd = struct { name: []const u8, handler: *const fn () void };
const cmds = [_]Cmd{
    .{ .name = "win-split", .handler = split },
    .{ .name = "win-vsplit", .handler = vsplit },
    .{ .name = "win-focus", .handler = focus },
    .{ .name = "win-close", .handler = close },
    .{ .name = "win-center", .handler = center },
};

export fn describe() void {
    for (cmds) |c| weft.declareCommand(c.name);
}
export fn init() void {
    for (cmds) |c| _ = weft.register(c.name);
}
export fn on_command(id: u32) void {
    if (id < cmds.len) cmds[id].handler();
}

fn split() void {
    weft.run("split");
}
fn vsplit() void {
    weft.run("vsplit");
}
fn focus() void {
    weft.run("focus-other");
}
fn close() void {
    weft.run("unsplit");
}
fn center() void {
    weft.run("center-line");
}
