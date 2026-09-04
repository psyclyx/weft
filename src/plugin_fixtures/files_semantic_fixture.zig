//! Test-only root for the real sandboxed files adapter.
//!
//! All behavior lives in the named `weft_files_guest` module. This file is
//! only the wasm callback table a third-party plugin root would provide.

const weft = @import("weft");
const files_guest = @import("weft_files_adapter");

var plugin: files_guest.Plugin = undefined;

fn describe() callconv(.c) void {
    weft.requestPerm(.fs_read);
    weft.requestPerm(.fs_write);
}

fn init() callconv(.c) void {
    plugin = .init(weft.allocator);
    plugin.start() catch unreachable;
}

fn on_semantic_target_probe(token: u32) callconv(.c) void {
    plugin.targetProbe(token);
}

fn on_semantic_target_open(token: u32) callconv(.c) void {
    plugin.targetOpen(token);
}

fn on_semantic_target_settle(token: u32, authority: u32, slot: u32, generation: u32, outcome: u32) callconv(.c) void {
    if (generation == 0 or outcome > 1) return;
    plugin.targetSettle(token, .{
        .authority = @enumFromInt(authority),
        .slot = slot,
        .generation = generation,
    }, outcome == 0);
}

fn on_semantic_relation_query(token: u32) callconv(.c) void {
    plugin.relationQuery(token);
}

fn on_semantic_action() callconv(.c) void {
    plugin.semanticAction();
}

fn on_semantic_field_edit(token: u32) callconv(.c) void {
    plugin.fieldEdit(token);
}

comptime {
    weft.exportCallback("describe", &describe);
    weft.exportCallback("init", &init);
    weft.exportCallback("on_semantic_target_probe", &on_semantic_target_probe);
    weft.exportCallback("on_semantic_target_open", &on_semantic_target_open);
    weft.exportCallback("on_semantic_target_settle", &on_semantic_target_settle);
    weft.exportCallback("on_semantic_relation_query", &on_semantic_relation_query);
    weft.exportCallback("on_semantic_action", &on_semantic_action);
    weft.exportCallback("on_semantic_field_edit", &on_semantic_field_edit);
}
