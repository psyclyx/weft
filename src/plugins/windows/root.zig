//! windows — the window/split surface (design §6.1), a `.wasm` plugin
//! (perms `{}`). It provides the `win.*` command names over the core region
//! primitives (split/vsplit/focus/unsplit/center are carved by the gfx region
//! tree, never offset math), so a config binds windows through one door. Local
//! by irrelevance — no wire — and identical over a remote buffer.

const std = @import("std");
const weft = @import("weft");

const cmds = [_]weft.CommandEntry{
    .{ .name = "win-split", .call = split },
    .{ .name = "win-vsplit", .call = vsplit },
    .{ .name = "win-focus", .call = focus },
    .{ .name = "win-close", .call = close },
    .{ .name = "win-center", .call = center },
};

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

comptime {
    weft.plugin(&cmds, .{}).exportAll();
}
