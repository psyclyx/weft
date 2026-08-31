//! hostile_handle (wasm) — a guest that hands the session/stream doors
//! handles it was never given.
//!
//! The membrane's handle parameters are DECLARED `.u32`, but a host handler
//! receives the raw 32-bit word: a guest passing 2^31 arrives at the host as a
//! NEGATIVE `i32`. `wasm_host/sessions.zig` used to `@intCast` that straight
//! to `usize`, so `weft.replSend(0x8000_0000, …)` — four public SDK calls, no
//! permission of any kind — panicked the HOST. `wasm_host/proc.zig` checked
//! for it and the session doors did not, because the bounds check was written
//! out once per registry instead of once.
//!
//! Every door below is ungated by design (they only address or RELEASE a
//! resource), which is exactly why a permless guest is the right thing to
//! point at them. The whole fixture is "nothing happens": each call must be
//! refused as a dead handle, and the host must still be standing afterwards.

const weft = @import("weft");

/// Handles no `*_start`/`*_spawn` ever returned: the sign-bit word that used
/// to reach `@intCast`, its neighbours, and an ordinary out-of-range index.
const bogus = [_]u32{ 0x8000_0000, 0xFFFF_FFFF, 0x7FFF_FFFF, 9999, 1 };

export fn describe() void {
    weft.declareCommand("hostile-handles");
}

export fn init() void {
    _ = weft.register("hostile-handles");
}

export fn on_command(id: u32) void {
    _ = id;
    var scratch: [16]u8 = undefined;
    for (bogus) |h| {
        // Streamed sessions (repl §6.3, net §6.5) — the two that panicked.
        weft.replSend(h, "x");
        weft.replQuit(h);
        weft.netSend(h, "x");
        weft.netClose(h);
        // Raw proc streams, which always checked — here so a regression that
        // moves the check back out of the shared door is caught on both.
        weft.procSend(h, "x");
        _ = weft.procRead(h, &scratch);
        weft.procClose(h);
    }
    // Reached only if every call above was refused rather than fatal.
    weft.echo("survived");
}
