//! Tiny helpers shared by the command handlers: writing the transient
//! echo/status line. Both set `ctx.head.echo` (or a raw ArrayList) to a
//! one-line message; `ok_echo` also returns `.nil` so a handler can
//! `return ok_echo(ctx, "…")` in one line.

const std = @import("std");
const core = @import("../core/core.zig");

pub fn ok_echo(ctx: *core.command.Context, msg: []const u8) !core.command.Value {
    ctx.head.echo.clearRetainingCapacity();
    try ctx.head.echo.appendSlice(ctx.gpa, msg);
    return .nil;
}

pub fn setEcho(echo: *std.ArrayList(u8), gpa: std.mem.Allocator, msg: []const u8) void {
    echo.clearRetainingCapacity();
    echo.appendSlice(gpa, msg) catch {};
}
