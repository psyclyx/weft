//! operators — the operator domain (design §6.1), a `.wasm` plugin with NO core
//! privilege beyond the edit door (perms `{}`, grant_max edit). Each operator
//! AWAITS a `range` (its single arg — a motion's or textobject's returned span,
//! [FIX 3]) and applies an edit through the gated door, authored as this
//! plugin's peer. A `view`-grade peer's `op.delete` fails inside the gate with
//! ZERO permission code here; `op.upcase` on a view doc likewise refuses. The
//! range is document-anchored, so it follows concurrent edits directly.

const std = @import("std");
const weft = @import("weft");

var xform: [1 << 16]u8 = undefined;

const cmds = [_]weft.CommandEntry{
    .{ .name = "op.delete", .call = delete },
    .{ .name = "op.upcase", .call = upcase },
    .{ .name = "op.lowercase", .call = lowercase },
};

/// Delete the awaited range (the edit door, grade-gated + CRDT-anchored).
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

comptime {
    weft.plugin(&cmds, .{}).exportAll();
}
