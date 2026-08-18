//! project — the project domain (design §6 `project/`), as a catalog plugin
//! over `abi.zig` with no core privilege. Tracks recently visited files
//! (kv-backed, most-recent-first, deduped, capped) — the substrate a
//! switch-file / recent-files picker renders. Pure ABI: commands + kv.

const std = @import("std");
const abi = @import("../abi.zig");
const command = @import("../command.zig");

const recent_key = "recent";
const max_recent = 50;

pub fn plugin() abi.Plugin {
    return .{ .describe = describe, .init = init };
}

fn describe() abi.Manifest {
    return .{
        .name = "project",
        .commands = &.{ .{ .name = "project-remember" }, .{ .name = "project-recent" } },
    };
}

fn init(a: *abi.Abi) anyerror!void {
    try a.registerCommand("project-remember", remember);
    try a.registerCommand("project-recent", recent);
}

/// Push the active buffer's path onto the recent list; returns the count
/// (or -1 when the buffer has no path). Deduped and capped.
fn remember(a: *abi.Abi, args: []const command.Value) anyerror!command.Value {
    _ = args;
    const p = a.path() orelse return .{ .integer = -1 };
    const gpa = a.host.ctx.gpa;
    const existing = a.kvGet(recent_key) orelse "";
    const list = try prepend(gpa, existing, p);
    defer gpa.free(list);
    try a.kvPut(recent_key, list);
    return .{ .integer = @intCast(countLines(list)) };
}

/// The recent list as a newline-joined blob (a picker splits it). Borrowed
/// from kv until the next mutation.
fn recent(a: *abi.Abi, args: []const command.Value) anyerror!command.Value {
    _ = args;
    return .{ .string = a.kvGet(recent_key) orelse "" };
}

/// `path` newline-joined ahead of `list`, dropping any prior copy of `path`
/// and capping at `max_recent` entries. Caller frees.
fn prepend(gpa: std.mem.Allocator, list: []const u8, path: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, path);
    var kept: usize = 1;
    var it = std.mem.splitScalar(u8, list, '\n');
    while (it.next()) |line| {
        if (line.len == 0 or std.mem.eql(u8, line, path)) continue;
        if (kept >= max_recent) break;
        try out.append(gpa, '\n');
        try out.appendSlice(gpa, line);
        kept += 1;
    }
    return out.toOwnedSlice(gpa);
}

fn countLines(list: []const u8) usize {
    if (list.len == 0) return 0;
    return std.mem.count(u8, list, "\n") + 1;
}
