//! demo-config — a test fixture (not installed; see build.zig's `guests`
//! table): config as a plugin with no special powers. It composes two OTHER
//! plugins' commands into one (`dup-up`) and binds it to a key, reaching the
//! editor only through the config surface the sandbox grants — exactly how a
//! user's config.js does, one tier down.

const weft = @import("weft");

var id_dup_up: u32 = 0;

fn describe() callconv(.c) void {
    weft.declareCommand("dup-up");
}

fn init() callconv(.c) void {
    id_dup_up = weft.register("dup-up");
    // Wire a key, as a config would (late-bound: the target resolves at press).
    weft.bindKey("default", "C-d", "dup-up");
}

fn on_command(id: u32) callconv(.c) void {
    _ = id;
    // Compose two other commands through the registry — the config-as-glue
    // pattern. Each authors as its own plugin peer, grade-gated.
    weft.run("duplicate-line");
    weft.run("upcase-line");
}

comptime {
    weft.exportCallback("describe", &describe);
    weft.exportCallback("init", &init);
    weft.exportCallback("on_command", &on_command);
}
