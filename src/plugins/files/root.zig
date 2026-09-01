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
    .{ .name = "files", .call = browse },
    .{ .name = "files-show", .call = files_guest.showPending },
    .{ .name = "files-enter", .call = enterRow, .summary = "Open what the focused listing row names." },
    .{ .name = "files-up", .call = stepOut, .summary = "Open the directory containing this listing." },
    .{ .name = "files-apply", .call = applyFocused, .summary = "Apply the renames typed into this listing." },
};
comptime {
    weft.plugin(&cmds, .{
        .perms = &.{ .fs_read, .fs_write },
        .init = start,
    }).exportAll();
}

fn enterRow() void {
    plugin.enterRow();
}
fn stepOut() void {
    plugin.stepOut();
}
fn applyFocused() void {
    plugin.applyFocused();
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
    const directory = weft.placeRoot();
    if (directory.len == 0) {
        weft.echo("files: this place has no local directory to browse");
        return;
    }
    weft.runStr("open", directory);
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
