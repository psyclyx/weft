//! A wasm GUEST plugin exercising the FULL lifecycle across the membrane,
//! written against the guest-side ABI shim (weft.zig) so the logic reads like
//! an in-process catalog plugin. `describe` declares the command up front (the
//! perm handshake's no-authority half); `init` registers it; when the user
//! runs it the host calls back into `on_command`, which edits the buffer
//! through the host edit gate (authored as this plugin's peer, grade-gated).
//! This is the bidirectional host↔guest ABI every `.wasm` catalog plugin uses.

const weft = @import("weft");

/// Declare-phase (no authority): announce the command the host will cross-check
/// every `register` against.
export fn describe() void {
    weft.declareCommand("wasm-mark");
}

/// Post-approval: register the declared command.
export fn init() void {
    _ = weft.register("wasm-mark");
}

/// The host dispatches a registered command back here by id. `wasm-mark`
/// inserts a marker at the cursor through the host edit gate.
export fn on_command(id: u32) void {
    _ = id;
    const off = weft.cursor();
    weft.edit(.{ .start = off, .end = off }, "[wasm]");
}
