//! project (wasm twin) — the project-domain catalog plugin
//! (src/core/catalog/project.zig) recompiled as `.wasm`. Tracks recently
//! visited files (kv-backed, most-recent-first, deduped, capped) — the same
//! substrate a switch-file picker renders, expressed against the guest shim.
//! Proves command args/result + path + kv all cross the membrane, and that a
//! non-trivial pure computation (prepend/dedup/cap) ports unchanged.

const std = @import("std");
const weft = @import("weft");

const recent_key = "recent";
const root_key = "root"; // the current project's root (last detected)
const max_recent = 50;

/// Dominating markers that identify a project root, projectile/project.el-style:
/// the VCS top. A worktree/submodule makes `.git` a file, so `fs.exists` (any
/// kind) is the test, not "is a dir".
const markers = [_][]const u8{ ".git", ".jj", ".hg", ".svn", ".bzr" };

// Fixed guest buffers (no allocator in a freestanding guest): copy borrowed
// reads out before the next call reuses the shim scratch.
var path_buf: [4096]u8 = undefined;
var existing_buf: [1 << 16]u8 = undefined;
var list_buf: [1 << 16]u8 = undefined;
var probe_buf: [4096]u8 = undefined; // "<dir>/<marker>" for the root probe

var id_remember: u32 = 0;
var id_recent: u32 = 0;
var id_root: u32 = 0;

export fn describe() void {
    weft.declareCommand("project-remember");
    weft.declareCommand("project-recent");
    weft.declareCommand("project-root");
    weft.requestPerm(.fs_read); // probe for .git markers up the tree
}

export fn init() void {
    id_remember = weft.register("project-remember");
    id_recent = weft.register("project-recent");
    id_root = weft.register("project-root");
}

export fn on_command(id: u32) void {
    if (id == id_remember) remember() else if (id == id_recent) recent() else if (id == id_root) projectRoot();
}

/// Every buffer focus records the file AND updates the current project root —
/// so `project-root` stays valid even after focusing a tool buffer with no
/// path (grep/git output), which is exactly when an agent wants to know where
/// "here" is. A tool buffer (no path) leaves both unchanged.
export fn on_activate() void {
    _ = recordActive();
    _ = updateRoot();
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

/// `project-root` command: the current project's root directory. Detects from
/// the active buffer's path (VCS top); if that's a tool buffer with no path,
/// falls back to the last-detected root (kv) so grep/agent-in-project still
/// resolve. Empty string when nothing has a root yet.
fn projectRoot() void {
    const detected = updateRoot();
    if (detected.len > 0) {
        weft.setResultStr(detected);
    } else {
        weft.setResultStr(weft.kvGet(root_key) orelse "");
    }
}

/// Detect + persist the active buffer's project root. Returns the detected
/// root (borrowing `probe_buf`/`path_buf`), or "" for a buffer with no path
/// (leaving the stored root untouched).
fn updateRoot() []const u8 {
    const pth = weft.path() orelse return "";
    const pn = @min(pth.len, path_buf.len);
    @memcpy(path_buf[0..pn], pth[0..pn]);
    const root = detectRoot(path_buf[0..pn]);
    if (root.len > 0) weft.kvPut(root_key, root);
    return root;
}

/// Walk up from `path`'s directory to the nearest ancestor holding a VCS
/// marker (the project root). Falls back to the file's own directory when no
/// marker is found anywhere. `path` must be stable for the call (a copy in
/// `path_buf`); the returned slice points into it.
fn detectRoot(path: []const u8) []const u8 {
    const first = std.mem.lastIndexOfScalar(u8, path, '/') orelse return ""; // no dir
    var end = first;
    while (true) {
        const dir = if (end == 0) "/" else path[0..end];
        for (markers) |m| {
            if (weft.fsExists(joinMarker(dir, m)) != .none) return dir;
        }
        if (end == 0) break; // reached the filesystem root
        end = std.mem.lastIndexOfScalar(u8, path[0..end], '/') orelse 0;
    }
    // No marker: the file's own directory is the sensible root.
    return if (first == 0) "/" else path[0..first];
}

/// Build "<dir>/<marker>" into `probe_buf` (avoiding a double slash at root).
fn joinMarker(dir: []const u8, marker: []const u8) []const u8 {
    var w: usize = 0;
    const base = if (std.mem.eql(u8, dir, "/")) "" else dir; // "/" + "/x" → "/x"
    const bn = @min(base.len, probe_buf.len);
    @memcpy(probe_buf[0..bn], base[0..bn]);
    w = bn;
    if (w < probe_buf.len) {
        probe_buf[w] = '/';
        w += 1;
    }
    const mn = @min(marker.len, probe_buf.len - w);
    @memcpy(probe_buf[w .. w + mn], marker[0..mn]);
    w += mn;
    return probe_buf[0..w];
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
