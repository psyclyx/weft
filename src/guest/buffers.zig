//! buffers — buffer management (design §6.1), a `.wasm` plugin (perms `{}`). It
//! composes the buffer-introspection reads + the core buffer commands + the
//! pick candidate-index seam: `buf-pick` fuzzy-switches to a buffer (resolved
//! by the accepted ROW INDEX → the buffer id it recorded, robust under
//! duplicate names), `buf-scratch` opens a fresh scratch. The plain
//! next/close/save verbs stay the core primitives a config binds directly.

const std = @import("std");
const weft = @import("weft.zig");

const buf_pick = 0;
var ids: [1024]i32 = undefined;
var n_rows: usize = 0;

const Cmd = struct { name: []const u8, handler: *const fn () void };
const cmds = [_]Cmd{
    .{ .name = "buf-pick", .handler = bufPick },
    .{ .name = "buf-scratch", .handler = bufScratch },
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
export fn on_pick_accept(pick_id: u32) void {
    if (pick_id != buf_pick) return;
    const i = weft.pickChoiceIndex() orelse return;
    if (i < n_rows) weft.runInt("buffer-switch", ids[i]);
}

/// Fuzzy-pick a live buffer by name and switch to it (by recorded id).
fn bufPick() void {
    n_rows = 0;
    weft.pickBegin("buffer", buf_pick);
    const count = weft.bufferCount();
    var i: usize = 0;
    while (i < count and n_rows < ids.len) : (i += 1) {
        const id = weft.bufferId(i) orelse continue;
        const name = weft.bufferName(i) orelse continue;
        weft.pickAdd(name, if (weft.bufferReadOnly(i)) "ro" else "");
        ids[n_rows] = id;
        n_rows += 1;
    }
    weft.pickEnd();
}

/// Switch to the scratch buffer — reusing the existing one if present, else
/// creating it. Tool buffers (dired/magit) bind `q` here to leave; without the
/// reuse, `buffer-create` spawns a NEW `*scratch*` every time (duplicate names
/// are allowed), so leaving a tool repeatedly piled up scratch buffers.
fn bufScratch() void {
    const count = weft.bufferCount();
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const name = weft.bufferName(i) orelse continue;
        if (std.mem.eql(u8, name, "*scratch*")) {
            if (weft.bufferId(i)) |id| {
                weft.runInt("buffer-switch", id);
                return;
            }
        }
    }
    weft.runStr("buffer-create", "*scratch*");
}
