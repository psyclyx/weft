//! project (wasm twin) — the project-domain catalog plugin
//! (src/core/catalog/project.zig) recompiled as `.wasm`. Tracks recently
//! visited files (kv-backed, most-recent-first, deduped, capped) — the same
//! substrate a switch-file picker renders, expressed against the guest shim.
//! Proves command args/result + path + kv all cross the membrane, and that a
//! non-trivial pure computation (prepend/dedup/cap) ports unchanged.

const std = @import("std");
const weft = @import("weft.zig");

const recent_key = "recent";
const max_recent = 50;

// Fixed guest buffers (no allocator in a freestanding guest): copy borrowed
// reads out before the next call reuses the shim scratch.
var path_buf: [4096]u8 = undefined;
var existing_buf: [1 << 16]u8 = undefined;
var list_buf: [1 << 16]u8 = undefined;

var id_remember: u32 = 0;
var id_recent: u32 = 0;

export fn describe() void {
    weft.declareCommand("project-remember");
    weft.declareCommand("project-recent");
}

export fn init() void {
    id_remember = weft.register("project-remember");
    id_recent = weft.register("project-recent");
}

export fn on_command(id: u32) void {
    if (id == id_remember) remember() else if (id == id_recent) recent();
}

/// Every buffer focus records the file — this is what actually POPULATES the
/// recent list in normal use (the `project-remember` command exists but nothing
/// invoked it, so recents were always empty). A tool buffer (no path) is a
/// no-op, and re-visiting an entry just moves it to the front (dedup).
export fn on_activate() void {
    _ = recordActive();
}

/// Push the active buffer's path onto the recent list (front, deduped, capped).
/// Returns the new count, or -1 when the buffer has no path (a tool buffer).
fn recordActive() i32 {
    const pth = weft.path() orelse return -1;
    const pn = @min(pth.len, path_buf.len);
    @memcpy(path_buf[0..pn], pth[0..pn]);
    const path = path_buf[0..pn];

    const ex = weft.kvGet(recent_key) orelse "";
    const en = @min(ex.len, existing_buf.len);
    @memcpy(existing_buf[0..en], ex[0..en]);

    const list = prepend(existing_buf[0..en], path);
    weft.kvPut(recent_key, list);
    return @intCast(countLines(list));
}

/// The `project-remember` command: record + report the count.
fn remember() void {
    weft.setResultInt(recordActive());
}

/// The recent list as a newline-joined blob (a picker splits it).
fn recent() void {
    weft.setResultStr(weft.kvGet(recent_key) orelse "");
}

/// `path` newline-joined ahead of `list`, dropping any prior copy of `path`
/// and capping at `max_recent`. Writes into `list_buf`.
fn prepend(list: []const u8, path: []const u8) []const u8 {
    @memcpy(list_buf[0..path.len], path);
    var w: usize = path.len;
    var kept: usize = 1;
    var it = std.mem.splitScalar(u8, list, '\n');
    while (it.next()) |line| {
        if (line.len == 0 or std.mem.eql(u8, line, path)) continue;
        if (kept >= max_recent) break;
        if (w + 1 + line.len > list_buf.len) break;
        list_buf[w] = '\n';
        w += 1;
        @memcpy(list_buf[w .. w + line.len], line);
        w += line.len;
        kept += 1;
    }
    return list_buf[0..w];
}

fn countLines(list: []const u8) usize {
    if (list.len == 0) return 0;
    return std.mem.count(u8, list, "\n") + 1;
}
