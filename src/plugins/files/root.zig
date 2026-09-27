//! Sandboxed file-browser plugin.
//!
//! The internal `weft_files_guest` library composes the portable draft model,
//! semantic projection, and public target-scoped filesystem ABI. This root
//! contributes only wasm callbacks plus the user-facing launcher. It owns no
//! text projection, editor mode, keymap, shell command, syscall, or platform
//! policy.

const std = @import("std");
const weft = @import("weft");
const files_guest = @import("weft_files_adapter");

var plugin: files_guest.Plugin = undefined;

const cmds = [_]weft.CommandEntry{
    .{ .name = "files", .call = browse, .summary = "browse a directory" },
    .{ .name = "files-enter", .call = enterRow, .summary = "open the focused entry" },
    .{ .name = "files-up", .call = stepOut, .summary = "browse the containing directory" },
    .{ .name = "files-apply", .call = applyFocused, .summary = "apply this directory's draft" },
};

comptime {
    weft.plugin(&cmds, .{
        .perms = &.{ .fs_read, .fs_write },
        .init = start,
    }).exportAll();
}

fn enterRow() void {
    weft.run("target-open-focused");
}
fn stepOut() void {
    weft.run("hierarchy-step-out");
}
fn applyFocused() void {
    _ = weft.semanticAction(weft.semantic.action.standard.apply);
}

fn start() void {
    files_guest.Plugin.provideRowVerbs();
    plugin = .init(weft.allocator);
    // The launcher remains usable in a command-only host. Target callbacks
    // decline until the generic semantic services become available.
    plugin.start() catch {};
}

fn browse() void {
    // The browser opens WHERE the dispatch is (`doc/place.md`): the project the
    // focused file belongs to, not the directory the editor was launched in.
    // By its designation: the listing then IS that `dir`, and titles itself
    // absolute (doc/model.md §2.1).
    var named: [4096]u8 = undefined;
    const directory = weft.placeDesignation(&named) orelse {
        weft.echo("files: this place has no local directory to browse");
        return;
    };
    weft.openDesignation(directory);
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
    weft.exportCallback("on_semantic_target_probe", &on_semantic_target_probe);
    weft.exportCallback("on_semantic_target_open", &on_semantic_target_open);
    weft.exportCallback("on_semantic_target_settle", &on_semantic_target_settle);
    weft.exportCallback("on_semantic_relation_query", &on_semantic_relation_query);
    weft.exportCallback("on_semantic_action", &on_semantic_action);
    weft.exportCallback("on_semantic_field_edit", &on_semantic_field_edit);
}
