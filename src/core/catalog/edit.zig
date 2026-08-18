//! edit — the edit domain (design §6 `edit/`), as a catalog plugin over
//! `abi.zig`. Line-oriented operators built purely from the ABI's read
//! (`cursor`/`slice`/`lineAt`) and the one write door (`edit`, authored as
//! this plugin's peer, grade-gated). No core privilege: these are exactly
//! the vim-flavored ops a config composes, shipped as a plugin.

const std = @import("std");
const abi = @import("../abi.zig");
const command = @import("../command.zig");

pub fn plugin() abi.Plugin {
    return .{ .describe = describe, .init = init };
}

fn describe() abi.Manifest {
    return .{
        .name = "edit",
        .commands = &.{ .{ .name = "duplicate-line" }, .{ .name = "upcase-line" } },
    };
}

fn init(a: *abi.Abi) anyerror!void {
    try a.registerCommand("duplicate-line", duplicateLine);
    try a.registerCommand("upcase-line", upcaseLine);
}

/// Copy the current line and insert the copy right below it.
fn duplicateLine(a: *abi.Abi, args: []const command.Value) anyerror!command.Value {
    _ = args;
    const gpa = a.host.ctx.gpa;
    const line = a.lineAt(a.cursor());
    const text = try a.slice(gpa, line.start, line.end);
    defer gpa.free(text);
    // Insert "\n<line>" at the line end — the duplicate lands below.
    const dup = try std.fmt.allocPrint(gpa, "\n{s}", .{text});
    defer gpa.free(dup);
    try a.edit(.{ .start = line.end, .end = line.end }, dup);
    return .{ .integer = @intCast(text.len) };
}

/// Upper-case the current line in place (one undoable unit).
fn upcaseLine(a: *abi.Abi, args: []const command.Value) anyerror!command.Value {
    _ = args;
    const gpa = a.host.ctx.gpa;
    const line = a.lineAt(a.cursor());
    const text = try a.slice(gpa, line.start, line.end);
    defer gpa.free(text);
    const up = try gpa.alloc(u8, text.len);
    defer gpa.free(up);
    for (text, up) |c, *o| o.* = std.ascii.toUpper(c);
    try a.edit(.{ .start = line.start, .end = line.end }, up);
    return .{ .integer = @intCast(text.len) };
}
