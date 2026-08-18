//! region — embedded-region marking (the subbuffer edge of the edit
//! domain), a catalog plugin over `abi.zig`. `mark-region` claims the
//! current line as a subbuffer with its own language fact — the substrate
//! an html-with-embedded-js or markdown-with-code-fences plugin uses to
//! give a range its own grammar/keymap/capabilities. Exercises Group E's
//! `claimSubbuffer`: an anchored range that rebases with the text and
//! carries facts the mode engine can predicate on.

const std = @import("std");
const abi = @import("../abi.zig");
const command = @import("../command.zig");

pub fn plugin() abi.Plugin {
    return .{ .describe = describe, .init = init };
}

fn describe() abi.Manifest {
    return .{ .name = "region", .commands = &.{.{ .name = "mark-region" }} };
}

fn init(a: *abi.Abi) anyerror!void {
    try a.registerCommand("mark-region", markRegion);
}

/// Claim the current line as a subbuffer tagged with a language fact (the
/// second arg, defaulting to "text"). Returns the claimed byte length.
fn markRegion(a: *abi.Abi, args: []const command.Value) anyerror!command.Value {
    const lang: []const u8 = if (args.len >= 1 and args[0] == .string) args[0].string else "text";
    const line = a.lineAt(a.cursor());
    const sub = try a.claimSubbuffer(line);
    try sub.putFact(a.host.ctx.gpa, "language", lang);
    return .{ .integer = @intCast(line.end - line.start) };
}
