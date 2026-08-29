//! Sandboxed file-browser plugin.
//!
//! The internal `weft_files_guest` library composes the portable draft model,
//! semantic projection, and public target-scoped filesystem ABI. This root
//! contributes only wasm callbacks plus the user-facing launcher. It owns no
//! text projection, editor mode, keymap, shell command, syscall, or platform
//! policy.

const weft = @import("weft");
const files_guest = @import("weft_files_adapter");

const command_name = "files";
var plugin: files_guest.Plugin = undefined;

export fn describe() void {
    weft.requestPerm(.fs_read);
    weft.requestPerm(.fs_write);
    weft.declareCommand(command_name);
}

export fn init() void {
    plugin = .init(weft.allocator);
    // The launcher remains usable in a command-only host. Target callbacks
    // decline until the generic semantic services become available.
    plugin.start() catch {};
    _ = weft.register(command_name);
}

export fn on_command(id: u32) void {
    if (id != 0) return;
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
