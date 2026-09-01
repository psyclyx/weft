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
    .{ .name = "files-list", .call = filesList, .summary = "List this place as an editable buffer." },
    .{ .name = "files-enter", .call = filesEnter, .summary = "Descend into, or open, the row under point." },
    .{ .name = "files-up", .call = filesUp, .summary = "List the parent directory." },
};
comptime {
    weft.plugin(&cmds, .{
        .perms = &.{ .fs_read, .fs_write },
        .init = start,
    }).exportAll();
}

fn installList() void {
    weft.restingMode(list_mode);
    weft.setFallback(list_mode, "normal");
    weft.bindKey(list_mode, "Return", "files-enter");
    weft.bindKey(list_mode, "^", "files-up");
    weft.bindKey(list_mode, "j", "cursor-down");
    weft.bindKey(list_mode, "k", "cursor-up");
    weft.bindKey(list_mode, "q", "buffer-back");
}

fn start() void {
    installList();
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

// ── The listing as a BUFFER ────────────────────────────────────────
//
// One implementation, two placements. A sidebar is a VIEWPORT
// (`weft.viewport`) and presenting a resource in one is an ordinary operation
// (`weft.present`) whose implementation runs `open` and puts the resulting
// BUFFER in the pane. So what a directory looks like must not depend on where
// it is shown — and it did, because the listing was a SCENE, and a scene is
// not a buffer.
//
// Everything that made the scene worth choosing is on the text projection now:
// row identity (keys), roles, verbs derived against those roles, folding, and
// — the last one, and the reason this could not be written before —
// `Node.editable`, so a rename is TYPING on the row.
//
// What this buys beyond placement is the other half of doc/plugin-api.md §F2:
// the listing is text, so search, yank and selection work in it. Renaming
// three files is a multi-cursor edit, not three field dialogs.

const list_view = "*files-list*";
const list_mode = "files-list";

/// Row keys are the ENTRY NAME as listed, which is this listing's identity for
/// a row: the projection hands the key back after an edit, so what the user
/// typed can be compared against what was there.
fn filesList() void {
    // COPIED FIRST. `placeRoot` borrows the shim's shared read scratch, and
    // every door below reads through it — `focusOrCreateBuffer` walks the
    // buffer list. Using it after would list whatever name was read last.
    var here: [1024]u8 = undefined;
    const root = weft.placeRoot();
    if (root.len == 0) {
        weft.echo("files: this place has no local directory");
        return;
    }
    const n = @min(root.len, here.len);
    @memcpy(here[0..n], root[0..n]);
    const where = here[0..n];
    weft.focusOrCreateBuffer(list_view);
    weft.toolBacking("files-list");
    weft.setMode(list_mode);
    listInto(where);
}

var list_at: [1024]u8 = undefined;
var list_at_len: usize = 0;

fn listInto(dir: []const u8) void {
    list_at_len = @min(dir.len, list_at.len);
    @memcpy(list_at[0..list_at_len], dir[0..list_at_len]);
    const listing = weft.fsList("here", dir) orelse {
        weft.echo("files: cannot list this directory");
        return;
    };
    const b = weft.project(list_view) orelse {
        weft.echo("files: no projection for this listing");
        return;
    };
    var it = std.mem.splitScalar(u8, listing, '\n');
    while (it.next()) |entry| {
        if (entry.len == 0) continue;
        const is_dir = entry[entry.len - 1] == '/';
        const name = if (is_dir) entry[0 .. entry.len - 1] else entry;
        var text_buf: [1024]u8 = undefined;
        const line = std.fmt.bufPrint(&text_buf, "{s} {s}", .{
            if (is_dir) "▸" else "·",
            name,
        }) catch continue;
        var key_buf: [512]u8 = undefined;
        const key = std.fmt.bufPrint(&key_buf, "{s}:{s}", .{ if (is_dir) "d" else "f", name }) catch continue;
        const node = b.add(.{
            .key = key,
            .role = if (is_dir) "fs.directory" else "fs.file",
            .text = line,
            .focusable = true,
            // NOT editable yet, and deliberately: a rename is a typed FS PLAN
            // (`weft_fs`.s contract), which needs the directory TARGET the
            // adapter holds and this raw listing does not. Editable rows with
            // no apply behind them would be a listing that lets you type and
            // then silently discards it. The projection half is proven in
            // `projection_gate`; the two meet when this moves onto the target.
        }) orelse continue;
        // The NAME, so a theme can distinguish it from the glyph and so a
        // reader knows which part of the line a rename may touch.
        b.span(node, line.len - name.len, line.len, "fs.name");
    }
    _ = b.commit();
}

/// Return on a row: a directory descends, a file opens. Both from the row.s
/// KEY, which carries WHAT the entry is (`d:` or `f:`) alongside its name —
/// so nothing here re-stats the filesystem to recover a fact the listing
/// already had, and nothing reads the rendered line back.
fn filesEnter() void {
    const key = weft.projectionAtCursor() orelse return;
    if (key.len < 2 or key[1] != ':') return;
    const is_dir = key[0] == 'd';
    var joined: [1024]u8 = undefined;
    const path = std.fmt.bufPrint(&joined, "{s}/{s}", .{ list_at[0..list_at_len], key[2..] }) catch return;
    if (!is_dir) return weft.runStr("open", path);
    // A directory descends IN PLACE: one buffer for the listing, rather than a
    // buffer per directory for someone to clean up after.
    var next: [1024]u8 = undefined;
    const n = @min(path.len, next.len);
    @memcpy(next[0..n], path[0..n]);
    listInto(next[0..n]);
}

/// Up one directory, by the same listing.
fn filesUp() void {
    const here = list_at[0..list_at_len];
    const cut = std.mem.lastIndexOfScalar(u8, here, '/') orelse return;
    if (cut == 0) return listInto("/");
    var parent: [1024]u8 = undefined;
    @memcpy(parent[0..cut], here[0..cut]);
    listInto(parent[0..cut]);
}
