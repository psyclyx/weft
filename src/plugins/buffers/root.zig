//! buffers — buffer management (design §6.1), a `.wasm` plugin (perms `{}`). It
//! composes the buffer-introspection reads + the core buffer commands + the
//! pick candidate-key seam: `buf-pick` fuzzy-switches to a buffer (resolved
//! by the IDENTITY the accepted candidate carries, robust under duplicate
//! names and under a buffer closing mid-pick), `buf-scratch` opens a fresh
//! scratch. The plain next/close/save verbs stay the core primitives a config
//! binds directly.

const std = @import("std");
const weft = @import("weft");
const ordering = @import("order.zig");

const buf_pick = 0;

var candidates: [1024]ordering.Candidate = undefined;
var order: [1024]usize = undefined;

const cmds = [_]weft.CommandEntry{
    .{ .name = "buf-pick", .call = bufPick, .summary = "switch to another open buffer" },
    .{ .name = "buf-scratch", .call = bufScratch, .summary = "open a scratch buffer" },
};

fn onPickAccept(pick_id: u32) void {
    if (pick_id != buf_pick) return;
    var outcome = (weft.pickOutcome(weft.allocator) catch return) orelse return;
    defer outcome.deinit(weft.allocator);
    const id = switch (outcome) {
        .candidate => |candidate| candidate.buffer orelse return weft.echo("that buffer is closed"),
        .input, .cancelled => return,
    };
    weft.runInt("buffer-switch", @intCast(id));
}

/// Fuzzy-pick a live buffer by name and switch to it (by its identity).
fn bufPick() void {
    weft.pickBegin("buffer", buf_pick);
    weft.pickCategory("buffer");
    const count = weft.bufferCount();
    var n_candidates: usize = 0;
    var i: usize = 0;
    while (i < count and n_candidates < candidates.len) : (i += 1) {
        const id = weft.bufferId(i) orelse continue;
        candidates[n_candidates] = .{
            .buffer_index = i,
            .id = id,
            .active = weft.bufferActive(i),
        };
        n_candidates += 1;
    }
    const n_ordered = ordering.activeLastOrder(candidates[0..n_candidates], order[0..n_candidates]);
    var row: usize = 0;
    while (row < n_ordered) : (row += 1) {
        const candidate = candidates[order[row]];
        const name = weft.bufferName(candidate.buffer_index) orelse continue;
        weft.pickAddBuffer(name, if (weft.bufferReadOnly(candidate.buffer_index)) "ro" else "", candidate.buffer_index);
    }
    weft.pickEnd();
    // The candidate table filled with buffers still unvisited.
    if (i < count) weft.echo(std.fmt.comptimePrint("buffers: >{d} buffers — some omitted", .{candidates.len}));
}

/// Switch to the scratch buffer — reusing the existing one if present, else
/// creating it. Tool buffers (files/git) bind `q` here to leave; without the
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

comptime {
    weft.plugin(&cmds, .{ .pick = onPickAccept }).exportAll();
}
