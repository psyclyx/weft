//! operators — the operator domain (design §6.1), a `.wasm` plugin with NO core
//! privilege beyond the edit door (perms `{}`, grant_max edit). Each operator
//! AWAITS a `range` (its single arg — a motion's or textobject's returned span,
//! [FIX 3]) and applies an edit through the gated door, authored as this
//! plugin's peer. A `view`-grade peer's `op.delete` fails inside the gate with
//! ZERO permission code here; `op.upcase` on a view doc likewise refuses. The
//! range is version-stamped, so it rebases like a concurrent peer's edit.

const std = @import("std");
const weft = @import("weft.zig");

var xform: [1 << 16]u8 = undefined;

const Cmd = struct { name: []const u8, handler: *const fn () void };
const cmds = [_]Cmd{
    .{ .name = "op.delete", .handler = delete },
    .{ .name = "op.upcase", .handler = upcase },
    .{ .name = "op.lowercase", .handler = lowercase },
};

export fn describe() void {
    for (cmds) |c| weft.declareCommand(c.name);
}
export fn init() void {
    for (cmds) |c| _ = weft.register(c.name);
}
export fn on_command(id: u32) void {
    if (id < cmds.len) cmds[id].handler();
}

/// Delete the awaited range (the edit door, grade-gated + rebased).
fn delete() void {
    const h = weft.argRange(0) orelse return;
    weft.editRange(h, "");
}

/// Replace the awaited range with a case-mapped copy of its own text.
fn mapCase(comptime f: fn (u8) u8) void {
    const h = weft.argRange(0) orelse return;
    const r = weft.rangeEnds(h) orelse return;
    const src = weft.slice(r.start, r.end); // borrows shim scratch
    const n = @min(src.len, xform.len);
    for (0..n) |i| xform[i] = f(src[i]);
    weft.editRange(h, xform[0..n]);
}
fn upcase() void {
    mapCase(std.ascii.toUpper);
}
fn lowercase() void {
    mapCase(std.ascii.toLower);
}
