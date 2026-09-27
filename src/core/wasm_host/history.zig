//! `wl_jump_push` / `wl_macro_recording` — a head's history, for a grammar.
//!
//! The jumplist and the macro registers are core (`jumplist.zig`,
//! `Head.Macros`); what counts as a jump and which keys record are the
//! grammar's. These are the two things a grammar needs from core to make
//! those choices: "remember where I am, this was a jump", and "is a macro
//! recording" (for a status chip, and for vim's `q`, which stops a recording
//! or starts one). Travel and replay are ordinary commands (`jump-back`,
//! `macro-play`, …), reached through `wl_run*` like any other.
//!
//! Ungated: both act on the dispatching head's own history, never on the
//! desktop or another head's. One body each, shared with the JS plane.

const std = @import("std");
const wasm = @import("../wasm.zig");
const shared = @import("plugin.zig");
const Door = @import("../plugin_resources.zig").Door;
const jumplist = @import("../jumplist.zig");

/// `jumpPush()`: remember the caret as a jump in the head's jumplist. A push
/// equal to the newest entry is dropped, so a grammar may push on every
/// search without flooding the list.
pub fn jumpPushBody(d: Door, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = caller;
    _ = args;
    _ = results;
    const ctx = d.ctx;
    jumplist.push(&ctx.head.jumps, ctx.gpa, ctx.buffers, jumplist.here(ctx.buffers)) catch {};
}
pub const hJumpPush = shared.wasmDoor(jumpPushBody, null);

/// `macroRecording() -> reg`: the register a macro is recording into (its
/// byte), or 0 when none is.
pub fn macroRecordingBody(d: Door, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = caller;
    _ = args;
    results[0] = d.ctx.head.macros.recording orelse 0;
}
pub const hMacroRecording = shared.wasmDoor(macroRecordingBody, null);
