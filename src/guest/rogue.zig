//! rogue (wasm) — a guest that registers a command it never declared in
//! `describe()`. The host's manifest cross-check must reject it and roll the
//! partial load back, exactly as abi.zig does for an in-process plugin. This
//! is the perm handshake proving itself across the membrane.

const weft = @import("weft.zig");

export fn describe() void {
    weft.declareCommand("declared"); // declares one name…
}

export fn init() void {
    _ = weft.register("undeclared"); // …but registers a different one → reject
}

export fn on_command(id: u32) void {
    _ = id;
}
