//! complete (wasm twin) — buffer-word completion (src/core/catalog/complete.zig)
//! recompiled as a `.wasm` component. The SAME dabbrev behavior — scan the
//! active buffer for words sharing the query prefix — expressed against the
//! guest ABI shim (weft.zig). It proves the host→guest data-gather membrane:
//! `describe` declares the capability, `init` registers the provider, and the
//! host calls `on_complete` per request, during which the guest reads the
//! prefix and pushes candidates back across the sandbox.

const std = @import("std");
const weft = @import("weft.zig");

const seps = " \t\n\r(){}[].,;:\"'`<>=+-*/\\|&!?@#$%^~";

export fn describe() void {
    weft.declareCapability("edit/completion");
}

export fn init() void {
    weft.provideCompletion();
}

export fn on_complete() void {
    const prefix = weft.completionPrefix();
    if (prefix.len == 0) return;
    const text = weft.slice(0, weft.byteLen());
    var it = std.mem.tokenizeAny(u8, text, seps);
    while (it.next()) |word| {
        if (word.len <= prefix.len or !std.mem.startsWith(u8, word, prefix)) continue;
        weft.pushCompletion(word); // the host dedups on collection
    }
}
