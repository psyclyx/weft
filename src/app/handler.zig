//! Tiny helpers shared by the command handlers: writing the transient
//! echo/status line. Both say a one-line message on a head's echo
//! (`Head.Echo.say`, its one writer); `ok_echo` also returns `.nil` so a handler can
//! `return ok_echo(ctx, "…")` in one line.

const std = @import("std");
const core = @import("weft_core");

pub fn ok_echo(ctx: *core.command.Context, msg: []const u8) !core.command.Value {
    try ctx.head.echo.say(ctx.gpa, msg);
    return .nil;
}

pub fn setEcho(echo: *core.Head.Echo, gpa: std.mem.Allocator, msg: []const u8) void {
    echo.say(gpa, msg) catch {};
}
