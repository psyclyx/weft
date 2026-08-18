//! complete — buffer-word completion (the completion/sel domain), a catalog
//! plugin over `abi.zig`. Provides `edit/completion`: scans the active
//! buffer for words sharing the query prefix, deduped — vim's C-n / dabbrev
//! as a plugin. Read-only (no grant to register a query provider); its
//! results race and merge-rank with every other completion provider in the
//! capability model, exactly like the tree-sitter and LSP ones.

const std = @import("std");
const abi = @import("../abi.zig");

pub fn plugin() abi.Plugin {
    return .{ .describe = describe, .init = init };
}

fn describe() abi.Manifest {
    return .{ .name = "complete", .capabilities = &.{.{ .capability = "edit/completion" }} };
}

fn init(a: *abi.Abi) anyerror!void {
    try a.provideCompletion(bufferWords);
}

const word_seps = " \t\n\r(){}[].,;:\"'`<>=+-*/\\|&!?@#$%^~";

/// Append unique buffer words that begin with `prefix` and are longer than
/// it. Owned copies — the ABI frees them after the host deep-copies.
fn bufferWords(a: *abi.Abi, prefix: []const u8, out: *std.ArrayList([]const u8)) anyerror!void {
    if (prefix.len == 0) return;
    const gpa = a.host.ctx.gpa;
    const text = try a.slice(gpa, 0, a.byteLen());
    defer gpa.free(text);
    var it = std.mem.tokenizeAny(u8, text, word_seps);
    while (it.next()) |word| {
        if (word.len <= prefix.len or !std.mem.startsWith(u8, word, prefix)) continue;
        var dup = false;
        for (out.items) |w| if (std.mem.eql(u8, w, word)) {
            dup = true;
            break;
        };
        if (dup) continue;
        try out.append(gpa, try gpa.dupe(u8, word));
    }
}
