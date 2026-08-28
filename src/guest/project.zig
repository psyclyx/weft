//! project (wasm twin) — the project-domain catalog plugin
//! (src/core/catalog/project.zig) recompiled as `.wasm`. Tracks recently
//! visited files (kv-backed, most-recent-first, deduped, capped) — the same
//! substrate a switch-file picker renders, expressed against the guest shim.
//! Proves command args/result + path + kv all cross the membrane, and that a
//! non-trivial pure computation (prepend/dedup/cap) ports unchanged.
//!
//! Declares NO capabilities. It used to hold `fs_read` for one reason — a
//! VCS-marker climb up from the active buffer — and that climb was a second
//! detector of a fact the host already establishes when a file is opened;
//! `project-root` reads it through `weft.placeRoot()` now (`doc/place.md`
//! §4.2). What remains is pure list arithmetic over the kv store.

const std = @import("std");
const weft = @import("weft");

const recent_key = "recent";
const max_recent = 50;

// Fixed guest buffers (no allocator in a freestanding guest): copy borrowed
// reads out before the next call reuses the shim scratch.
var path_buf: [4096]u8 = undefined;
var existing_buf: [1 << 16]u8 = undefined;
var list_buf: [1 << 16]u8 = undefined;

var id_remember: u32 = 0;
var id_recent: u32 = 0;
var id_root: u32 = 0;

export fn describe() void {
    weft.declareCommand("project-remember");
    weft.declareCommand("project-recent");
    weft.declareCommand("project-root");
    // NO capabilities. The VCS-marker climb this plugin used to run — its only
    // reason for `fs_read` — is gone: the host detects a project root when a
    // file is opened, over exactly the same markers (`app/session.zig`'s
    // `project_markers`), and `weft.placeRoot()` reads that answer
    // (`doc/place.md` §4.2). Two detectors of one fact were one too many, and
    // the second cost a grant over the whole filesystem.
}

export fn init() void {
    id_remember = weft.register("project-remember");
    id_recent = weft.register("project-recent");
    id_root = weft.register("project-root");
}

export fn on_command(id: u32) void {
    if (id == id_remember) remember() else if (id == id_recent) recent() else if (id == id_root) projectRoot();
}

/// Every buffer focus records the file. The root no longer needs recording:
/// it is a property of WHERE the next command dispatches, read when asked
/// (`projectRoot`), not a value this plugin has to keep chasing focus to hold
/// current — and a tool buffer with no path of its own still answers, because
/// it carries the place of the entry that produced it.
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

/// `project-root` command: the project this command is in, absolute — which is
/// WHERE it dispatches (`doc/place.md`). One door, no detection.
///
/// This used to be a climb: copy the active buffer's path, walk up probing
/// each ancestor for `.git`/`.jj`/`.hg`/`.svn`/`.bzr`, remember the answer in
/// kv so a tool buffer with no path of its own could still be answered. All
/// three parts are now someone else's job and done better. The host runs that
/// exact walk when a file is OPENED (`app/session.zig`'s `projectRootOf`, same
/// marker list, with a floor this plugin never had) and hands the result to
/// every entry, so a tool buffer inherits the place of whatever produced it —
/// the case the kv cache existed for — and a working target pinned by the user
/// overrides both, which no amount of climbing here could have discovered.
///
/// Empty means the place has no local directory (a peer, or a container that
/// went away). It stays empty: substituting a remembered path would be acting
/// in a directory that is not this one while reporting success, which is the
/// entire bug the place model exists to remove.
fn projectRoot() void {
    // `placeRoot` borrows the shim's shared read scratch; `setResultStr` hands
    // the pointer straight to the host with nothing in between, so no copy.
    weft.setResultStr(weft.placeRoot());
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
