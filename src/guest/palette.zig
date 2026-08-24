//! std (wasm twin) — the bundled UI plugin (src/core/catalog/palette.zig)
//! recompiled as `.wasm`: the command palette (pick-commands/help), the
//! buffers picker, and the status line. UI policy over core mechanisms
//! through the guest shim — introspection (commandCount/bufferAt), the
//! incremental pick (begin/add/end), and accept dispatched back to
//! on_pick_accept. No core privilege; the same door a user's config uses.

const std = @import("std");
const weft = @import("weft");

var id_palette: u32 = 0;
var id_help: u32 = 0;
var id_buffers: u32 = 0;
var id_status: u32 = 0;

/// Scratch for building a buffer label / status message.
var label_buf: [512]u8 = undefined;

const pick_commands = 0;
const pick_buffers = 1;

export fn describe() void {
    weft.declareCommand("pick-commands");
    weft.declareCommand("help");
    weft.declareCommand("buffers");
    weft.declareCommand("status");
}

export fn init() void {
    id_palette = weft.register("pick-commands");
    id_help = weft.register("help");
    id_buffers = weft.register("buffers");
    id_status = weft.register("status");
}

export fn on_command(id: u32) void {
    if (id == id_palette or id == id_help) palette() else if (id == id_buffers) buffers() else if (id == id_status) status();
}

/// A fuzzy pick over the whole command registry; accept runs the choice.
fn palette() void {
    weft.pickBegin("command", pick_commands);
    const n = weft.commandCount();
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const name = weft.commandName(i) orelse continue;
        weft.pickAdd(name, weft.commandSummary(i) orelse "");
    }
    weft.pickEnd();
}

/// Pick over the open buffers ("id: name"); accept switches to that buffer.
fn buffers() void {
    weft.pickBegin("buffer", pick_buffers);
    const n = weft.bufferCount();
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const bid = weft.bufferId(i) orelse continue;
        const name = weft.bufferName(i) orelse continue;
        const label = std.fmt.bufPrint(&label_buf, "{d}: {s}{s}{s}", .{
            bid,                                         name,
            if (weft.bufferReadOnly(i)) " [ro]" else "", if (weft.bufferActive(i)) " *" else "",
        }) catch continue;
        weft.pickAdd(label, "");
    }
    weft.pickEnd();
}

/// Echo the active buffer's name + read-only state (the status line).
fn status() void {
    const n = weft.bufferCount();
    var i: usize = 0;
    while (i < n) : (i += 1) {
        if (!weft.bufferActive(i)) continue;
        const name = weft.bufferName(i) orelse continue;
        const msg = std.fmt.bufPrint(&label_buf, "{s}{s}", .{
            name, if (weft.bufferReadOnly(i)) "  read-only" else "",
        }) catch return;
        weft.echo(msg);
        break;
    }
}

export fn on_pick_accept(pick_id: u32) void {
    const choice = weft.pickChoice();
    if (pick_id == pick_commands) {
        weft.run(choice);
    } else if (pick_id == pick_buffers) {
        const colon = std.mem.indexOfScalar(u8, choice, ':') orelse return;
        const bid = std.fmt.parseInt(i32, choice[0..colon], 10) catch return;
        weft.runInt("buffer-switch", bid);
    }
}
