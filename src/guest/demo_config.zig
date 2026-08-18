//! demo-config (wasm twin) — the Zig config plugin (src/core/catalog/demo_config.zig)
//! recompiled as `.wasm`. Config is a plugin with no special powers: it
//! composes two catalog commands into one (`dup-up`) and binds it to a key,
//! reaching the editor only through the config surface the sandbox grants —
//! exactly how a user's config.js does, one tier down.

const weft = @import("weft.zig");

var id_dup_up: u32 = 0;

export fn describe() void {
    weft.declareCommand("dup-up");
}

export fn init() void {
    id_dup_up = weft.register("dup-up");
    // Wire a key, as a config would (late-bound: the target resolves at press).
    weft.bindKey("default", "C-d", "dup-up");
}

export fn on_command(id: u32) void {
    _ = id;
    // Compose two other commands through the registry — the config-as-glue
    // pattern. Each authors as its own plugin peer, grade-gated.
    weft.run("duplicate-line");
    weft.run("upcase-line");
}
