//! Test-only root for the real sandboxed files adapter.
//!
//! All behavior lives in the named `weft_files_guest` module. This file is
//! only the wasm callback table a third-party plugin root would provide.

const weft = @import("weft");
const files_guest = @import("weft_files_guest");

var plugin: files_guest.Plugin = undefined;

export fn describe() void {
    weft.requestPerm(.fs_read);
    weft.requestPerm(.fs_write);
}

export fn init() void {
    plugin = .init(weft.allocator);
    plugin.start() catch unreachable;
}

export fn on_semantic_target_probe(token: u32) void {
    plugin.targetProbe(token);
}

export fn on_semantic_target_open(token: u32) void {
    plugin.targetOpen(token);
}

export fn on_semantic_target_settle(token: u32, authority: u32, slot: u32, generation: u32, outcome: u32) void {
    if (generation == 0 or outcome > 1) return;
    plugin.targetSettle(token, .{
        .authority = @enumFromInt(authority),
        .slot = slot,
        .generation = generation,
    }, outcome == 0);
}

export fn on_semantic_relation_query(token: u32) void {
    plugin.relationQuery(token);
}

export fn on_semantic_action() void {
    plugin.semanticAction();
}

export fn on_semantic_field_edit(token: u32) void {
    plugin.fieldEdit(token);
}
