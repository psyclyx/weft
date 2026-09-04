//! rogue (wasm) — a guest that registers a command it never declared in
//! `describe()`. The host's manifest cross-check must reject it and roll the
//! partial load back, exactly as abi.zig does for an in-process plugin. This
//! is the perm handshake proving itself across the membrane.

const weft = @import("weft");

fn describe() callconv(.c) void {
    weft.declareCommand("declared"); // declares one name…
}

fn init() callconv(.c) void {
    _ = weft.register("undeclared"); // …but registers a different one → reject
}

fn on_command(id: u32) callconv(.c) void {
    _ = id;
}

comptime {
    weft.exportCallback("describe", &describe);
    weft.exportCallback("init", &init);
    weft.exportCallback("on_command", &on_command);
}
