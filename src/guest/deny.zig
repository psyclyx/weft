//! deny (wasm) — a guest that registers a command but never requests the
//! `fs_read` perm, then calls `fs.read` anyway. Proves trap-on-deny
//! (doc/north-star-plan.md §2.4, review C9/[FIX 10]): a denied effect must
//! abort the guest's call with a real wasm trap, never hand back a fake -1
//! the guest could silently ignore. Mirrors `rogue.zig`'s pattern of a guest
//! built to misbehave for the test it backs.

const weft = @import("weft.zig");

export fn describe() void {
    weft.declareCommand("go");
    // Deliberately NOT weft.requestPerm(.fs_read) — the point of the test.
}

export fn init() void {
    _ = weft.register("go");
}

export fn on_command(id: u32) void {
    _ = id;
    // Must trap before returning here — if it ever returns, mark the result
    // so a regression (silent -1) is visible to the host-side test too.
    _ = weft.fsRead("whatever");
    weft.setResultStr("did not trap");
}
