//! autopair — a `.wasm` plugin with NO core privilege beyond the edit door
//! (perms `{}`, grant_max edit). Each command inserts a matched delimiter pair
//! at the cursor and leaves the cursor BETWEEN the two bytes: insert the two
//! bytes as an empty-range edit at the cursor, then jump one byte forward. The
//! edit crosses the gated door, authored as this plugin's peer, so a `view`
//! doc refuses it with zero permission logic here. Meant for insert mode.

const weft = @import("weft.zig");

/// Registration order == the id the host hands `on_command`. Each command's
/// `pair` is the two bytes to insert (open, then close).
const Cmd = struct { name: []const u8, pair: []const u8 };
const cmds = [_]Cmd{
    .{ .name = "pair-paren", .pair = "()" },
    .{ .name = "pair-brace", .pair = "{}" },
    .{ .name = "pair-bracket", .pair = "[]" },
    .{ .name = "pair-quote", .pair = "\"\"" },
};

export fn describe() void {
    for (cmds) |c| weft.declareCommand(c.name);
}
export fn init() void {
    for (cmds) |c| _ = weft.register(c.name);
}
export fn on_command(id: u32) void {
    if (id < cmds.len) insertPair(cmds[id].pair);
}

/// Insert the delimiter `pair` at the cursor and place the cursor between the
/// two bytes (after the open, before the close).
fn insertPair(pair: []const u8) void {
    const off = weft.cursor();
    weft.edit(.{ .start = off, .end = off }, pair);
    weft.jump(off + 1);
}
