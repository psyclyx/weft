//! Test fixture ONLY (not installed — see build.zig's `guests` table):
//! commands whose one required argument says what it takes, one per way of
//! saying it, each echoing what it was handed — so a test can watch an asker
//! offer values and see which one arrived.
//!
//!   - `argtest.open <target:file>`: a kind answered LATE, by a walk;
//!   - `argtest.run <what:command>`: a kind answered at once;
//!   - `argtest.paint <color:red|green|blue>`: values listed in the
//!     declaration, offered with nobody asked.

const std = @import("std");
const weft = @import("weft");

var msg: [512]u8 = undefined;

fn got(comptime what: []const u8) fn () void {
    return struct {
        fn f() void {
            const arg = weft.argStr(0) orelse "";
            weft.echo(std.fmt.bufPrint(&msg, what ++ " {s}", .{arg}) catch return);
        }
    }.f;
}

const cmds = [_]weft.CommandEntry{
    .{ .name = "argtest.open", .arity = .whole, .call = got("opened"), .params = "target:file", .summary = "Echo the file it was handed.", .label = "Argtest Open", .prompts = true },
    .{ .name = "argtest.run", .arity = .whole, .call = got("ran"), .params = "what:command", .summary = "Echo the command it was handed.", .label = "Argtest Run", .prompts = true },
    .{ .name = "argtest.paint", .arity = .whole, .call = got("painted"), .params = "color:red|green|blue", .summary = "Echo the colour it was handed.", .label = "Argtest Paint", .prompts = true },
};

comptime {
    weft.plugin(&cmds, .{}).exportAll();
}
