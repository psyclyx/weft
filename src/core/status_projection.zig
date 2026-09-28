//! A context's status, as a projection (doc/chrome.md §4.1).
//!
//! A status line is the status segments of a context (`ui/statusline-seg`,
//! `status_segment.zig`). Drawn under a pane, they are that pane's; PRESENTED,
//! they are a designation like any other:
//!
//!   weft://here/status/primary   the primary context's status — the editor's,
//!                                never a docked companion's that holds focus
//!   weft://here/status/active    the focused context's
//!
//! so a window-wide status bar is not a kind of thing core knows: it is a
//! viewport (a config fragment's, `config/statusbar.js`) presenting
//! `status/primary`, and the pane that shows it draws that context's
//! segments on its status row. This file is the kind's producer — the entry
//! the designation opens, and how the frame reads which context an entry
//! presents. Everything else about the line is the status line's own.

const std = @import("std");
const Allocator = std.mem.Allocator;

const command = @import("command.zig");
const Buffers = @import("Buffers.zig");
const designation = @import("designation.zig");
const durable = @import("weft_semantic").durable;

/// The projection kind.
pub const kind = "status";
/// The command core answers the kind with (`designation.Openers`).
pub const opener = "status.present";

/// Which context an entry presents the status of.
pub const Ref = enum {
    primary,
    active,

    pub fn parse(text: []const u8) ?Ref {
        return std.meta.stringToEnum(Ref, text);
    }
};

/// The context `entry` presents the status of, or null when it presents none.
pub fn refOf(entry: *const Buffers.Buffer) ?Ref {
    if (entry.designation.len == 0) return null;
    const d = durable.parse(entry.designation) orelse return null;
    if (d.authority != .here) return null;
    return switch (d.kind) {
        .projection => |k| if (std.mem.eql(u8, k, kind)) Ref.parse(d.ref) else null,
        else => null,
    };
}

/// `status.present <designation>`: make the entry presenting that context's
/// status active — one per context, reused. It holds no text and no scene:
/// what a pane showing it draws is the context's status row.
fn cPresent(ctx: *command.Context, data: ?*anyopaque, args: []const command.Value) anyerror!command.Value {
    _ = data;
    const text = if (args.len > 0 and args[0] == .string) args[0].string else return .{ .string = "status: which context" };
    const d = durable.parse(text) orelse return .{ .string = "status: not a designation" };
    const ref = switch (d.kind) {
        .projection => |k| if (std.mem.eql(u8, k, kind)) Ref.parse(d.ref) else null,
        else => null,
    } orelse return .{ .string = "status: primary or active" };
    var named: [64]u8 = undefined;
    const spelled = std.fmt.bufPrint(&named, "weft://here/{s}/{s}", .{ kind, @tagName(ref) }) catch unreachable;
    const id = if (designation.findText(ctx.buffers, spelled)) |b| b.id else blk: {
        var name_buf: [32]u8 = undefined;
        const name = std.fmt.bufPrint(&name_buf, "*status {s}*", .{@tagName(ref)}) catch unreachable;
        const made = try ctx.buffers.createView(ctx.gpa, name, kind);
        try ctx.buffers.get(made).?.setDesignation(ctx.gpa, spelled);
        break :blk made;
    };
    if (id != ctx.buffers.active_id) try ctx.buffers.switchTo(ctx.gpa, id, ctx.head, ctx.keymap);
    return .nil;
}

const table = [_]command.Command{
    .{ .name = opener, .summary = "Present a context's status (weft://here/status/primary|active).", .args = &.{.{ .name = "designation", .type = .string }}, .handler = cPresent, .meta = .{ .internal = true } },
};

/// Register the producer's command and claim the kind for it.
pub fn install(gpa: Allocator, commands: *command.Commands, openers: *designation.Openers) !void {
    for (table) |cmd| _ = try commands.bind(gpa, cmd.name, cmd);
    try openers.claim(gpa, kind, opener, "core");
}

// ── Tests ───────────────────────────────────────────────────────────

const t = std.testing;

test "status_projection: an entry presents a context's status by its designation, and nothing else does" {
    const task = @import("task.zig");
    const pool = try task.Pool.init(t.allocator, .{ .threads = 1 });
    defer pool.deinit();
    var bufs = try Buffers.init(t.allocator, pool, "user");
    defer bufs.deinit(t.allocator);
    const bar = bufs.get(try bufs.createView(t.allocator, "*status primary*", kind)).?;
    try t.expect(refOf(bar) == null);
    try bar.setDesignation(t.allocator, "weft://here/status/primary");
    try t.expectEqual(Ref.primary, refOf(bar).?);
    try bar.setDesignation(t.allocator, "weft://here/status/active");
    try t.expectEqual(Ref.active, refOf(bar).?);
    // Another kind, another ref, another authority: not a status.
    for ([_][]const u8{ "weft://here/offers/primary", "weft://here/status/nope", "weft://peer1/status/primary" }) |other| {
        try bar.setDesignation(t.allocator, other);
        try t.expect(refOf(bar) == null);
    }
}
