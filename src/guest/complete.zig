//! complete (wasm twin) — buffer-word completion (src/core/catalog/complete.zig)
//! recompiled as a `.wasm` component. The SAME dabbrev behavior — scan the
//! active buffer for words sharing the query prefix — expressed against the
//! guest ABI shim (weft.zig). It proves the host→guest data-gather membrane:
//! `describe` declares the capability, `init` registers the provider, and the
//! host calls `on_complete(session)` per request, during which the guest reads
//! the prefix and offers candidates for that session, then commits them (a sync
//! source — it answers before returning).

const std = @import("std");
const weft = @import("weft.zig");

const seps = " \t\n\r(){}[].,;:\"'`<>=+-*/\\|&!?@#$%^~";

export fn describe() void {
    weft.declareCapability("edit/completion");
}

export fn init() void {
    weft.provideCompletion();
}

export fn on_complete(session: u32) void {
    const prefix = weft.completionPrefix();
    if (prefix.len == 0) {
        weft.capsDecline(session);
        return;
    }
    const text = weft.slice(0, weft.byteLen());
    var it = std.mem.tokenizeAny(u8, text, seps);
    var rank: i32 = 0;
    while (it.next()) |word| {
        if (word.len <= prefix.len or !std.mem.startsWith(u8, word, prefix)) continue;
        // kind 1 = Text (LSP CompletionItemKind); the merge dedups by text.
        weft.capsItem(session, .{ .text = word, .kind = 1, .rank = rank });
        rank += 1;
    }
    weft.capsCommit(session);
}
