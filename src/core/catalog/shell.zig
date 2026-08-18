//! shell — "insert command output" (the repl/shell domain edge), a catalog
//! plugin over `abi.zig`. `insert-shell "<cmd>"` runs the command OFF the
//! frame thread and inserts its stdout at the cursor when it finishes —
//! rebased if the buffer moved meanwhile, authored as the plugin peer. The
//! canonical effect-plugin shape: `editLater` (compute off-frame, edit
//! on-frame, never a blocking poll) with a `proc.run` inside the work body.
//!
//! Perms: `proc` (it shells out) + `timer` (the async delivery). In process
//! the work calls `proc.run` directly (trusted); the wasm membrane (plan
//! 05) routes proc through the perm-checked host import, so the `.proc`
//! declaration is the honest forward contract.

const std = @import("std");
const abi = @import("../abi.zig");
const command = @import("../command.zig");
const proc = @import("../proc.zig");

pub fn plugin() abi.Plugin {
    return .{ .describe = describe, .init = init };
}

fn describe() abi.Manifest {
    return .{
        .name = "shell",
        .perms = &.{ .proc, .timer },
        .commands = &.{.{ .name = "insert-shell" }},
    };
}

fn init(a: *abi.Abi) anyerror!void {
    try a.registerCommand("insert-shell", insertShell);
}

fn insertShell(a: *abi.Abi, args: []const command.Value) anyerror!command.Value {
    if (args.len < 1 or args[0] != .string) return error.TypeMismatch;
    _ = try a.editLater(runCmd, args[0].string);
    return .nil;
}

/// Off-frame work body: run `/bin/sh -c <cmd>`, return its stdout trimmed of
/// a trailing newline. A failure yields empty (nothing is inserted). Runs
/// `proc.run` SYNCHRONOUSLY on the async pool worker — no pool nesting, no
/// frame block.
fn runCmd(gpa: std.mem.Allocator, input: []const u8) anyerror![]u8 {
    var res = proc.run(gpa, &.{ "/bin/sh", "-c", input }, .{}) catch return gpa.alloc(u8, 0);
    defer res.deinit(gpa);
    return gpa.dupe(u8, std.mem.trimEnd(u8, res.stdout, "\n"));
}
