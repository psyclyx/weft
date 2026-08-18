//! std — the bundled UI plugin (the sel/consult domain), porting
//! `bundled.fnl` to Zig for plan 06 (Lua removal). UI POLICY over core
//! mechanisms, through the same ABI a user's config uses: the command
//! palette (`pick-commands`/`help`), the buffers picker (`buffers`), and the
//! status line (`status`). No core privilege — replaceable by rebinding the
//! same command names.
//!
//! Note vs. `bundled.fnl`: the palette runs the accepted command directly;
//! per-argument prompting (the Fennel `read-args` flow) is not ported —
//! arg-taking file commands go through `find-file` (the native file picker)
//! instead. Everything else is at parity.

const std = @import("std");
const abi = @import("../abi.zig");
const command = @import("../command.zig");
const V = command.Value;

pub fn plugin() abi.Plugin {
    return .{ .describe = describe, .init = init };
}

fn describe() abi.Manifest {
    return .{
        .name = "std",
        .commands = &.{
            .{ .name = "pick-commands" },
            .{ .name = "help" },
            .{ .name = "buffers" },
            .{ .name = "status" },
        },
    };
}

fn init(a: *abi.Abi) anyerror!void {
    try a.registerCommand("pick-commands", palette);
    try a.registerCommand("help", palette);
    try a.registerCommand("buffers", buffers);
    try a.registerCommand("status", status);
}

/// A fuzzy pick over the whole command registry; accept runs the choice.
fn palette(a: *abi.Abi, _: []const V) anyerror!V {
    const gpa = a.host.ctx.gpa;
    var items: std.ArrayList(abi.PickItem) = .empty;
    defer items.deinit(gpa);
    for (0..a.commandCount()) |i| {
        if (a.commandAt(i)) |c| try items.append(gpa, .{ .text = c.name, .doc = c.summary });
    }
    try a.openPick("command", items.items, runChoice);
    return .nil;
}

fn runChoice(a: *abi.Abi, choice: []const u8) anyerror!void {
    _ = a.run(choice, &.{}) catch {
        a.log(.warn, "pick-commands: command failed");
    };
}

/// Pick over the open buffers ("id: name"); accept switches to that buffer.
fn buffers(a: *abi.Abi, _: []const V) anyerror!V {
    const gpa = a.host.ctx.gpa;
    var labels: std.ArrayList([]u8) = .empty;
    defer {
        for (labels.items) |l| gpa.free(l);
        labels.deinit(gpa);
    }
    var items: std.ArrayList(abi.PickItem) = .empty;
    defer items.deinit(gpa);
    for (0..a.bufferCount()) |i| {
        const b = a.bufferAt(i) orelse continue;
        const label = try std.fmt.allocPrint(gpa, "{d}: {s}{s}{s}", .{
            b.id,                             b.name,
            if (b.read_only) " [ro]" else "", if (b.active) " *" else "",
        });
        try labels.append(gpa, label);
        try items.append(gpa, .{ .text = label });
    }
    try a.openPick("buffer", items.items, switchChoice);
    return .nil;
}

fn switchChoice(a: *abi.Abi, choice: []const u8) anyerror!void {
    // Parse the leading "N:" buffer id.
    const colon = std.mem.indexOfScalar(u8, choice, ':') orelse return;
    const id = std.fmt.parseInt(i64, choice[0..colon], 10) catch return;
    _ = try a.run("buffer-switch", &.{.{ .integer = id }});
}

/// Echo the active buffer's name + read-only state (the status line).
fn status(a: *abi.Abi, _: []const V) anyerror!V {
    for (0..a.bufferCount()) |i| {
        const b = a.bufferAt(i) orelse continue;
        if (!b.active) continue;
        const gpa = a.host.ctx.gpa;
        const msg = try std.fmt.allocPrint(gpa, "{s}{s}", .{ b.name, if (b.read_only) "  read-only" else "" });
        defer gpa.free(msg);
        try a.echo(msg);
        break;
    }
    return .nil;
}
