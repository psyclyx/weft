//! demo-config — a Zig CONFIG plugin (plan 06A: config parity). Config is a
//! plugin with no special powers — the same door, the same ABI `init.fnl`
//! uses through `weft.*`. This one composes two catalog commands into one
//! (`dup-up` = duplicate then upper-case) and binds it to a key, exactly
//! how a user's config would wire their editor. The seam that lets the
//! sample config migrate off Fennel: nothing here is privileged.

const std = @import("std");
const abi = @import("../abi.zig");
const command = @import("../command.zig");

pub fn plugin() abi.Plugin {
    return .{ .describe = describe, .init = init };
}

fn describe() abi.Manifest {
    return .{ .name = "demo-config", .commands = &.{.{ .name = "dup-up" }} };
}

fn init(a: *abi.Abi) anyerror!void {
    try a.registerCommand("dup-up", dupUp);
    // Wire a key, as a config would. Late binding: the target need not exist
    // yet — it resolves at keypress time.
    try a.bindKey("default", "C-d", "dup-up");
}

/// Compose two other commands (late-bound through the registry) — the
/// config-as-glue pattern. Each runs and authors as its own plugin peer.
fn dupUp(a: *abi.Abi, args: []const command.Value) anyerror!command.Value {
    _ = args;
    _ = try a.run("duplicate-line", &.{});
    _ = try a.run("upcase-line", &.{});
    return .nil;
}
