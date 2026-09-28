//! project — the project domain, a `.wasm` plugin. Tracks recently visited
//! files (kv-backed, most-recent-first, deduped, capped) — the substrate a
//! switch-file picker renders. Command args/result, `path`, and `kv` all cross
//! the membrane here, over a non-trivial pure computation (prepend/dedup/cap).
//!
//! Declares NO capabilities. It used to hold `fs_read` for one reason — a
//! VCS-marker climb up from the active buffer — and that climb was a second
//! detector of a fact the host already establishes when a file is opened;
//! `project.show-root` reads it through `weft.placeRoot()` now (`doc/place.md`
//! §4.2). What remains is pure list arithmetic over the kv store.

const std = @import("std");
const weft = @import("weft");

const recent_key = "recent";
const recent_roots_key = "recent-roots";

/// How many files "recently visited" means. This one IS policy, and it is the
/// only bound here: a recents list is a UI affordance — the handful of files a
/// picker offers you back — not a resource table, and nothing is refused when
/// it is reached. The fifty-first entry falls off the end, which is what a
/// recents list means. Every OTHER limit this file used to carry was an
/// artifact of believing a freestanding guest had no allocator; it has one
/// (`weft.allocator`), and a path that did not fit was silently recorded
/// TRUNCATED, naming a different file than the one you visited.
const max_recent = 50;

/// The joined list being built. Growable, so `max_recent` alone decides how
/// long a recents list is, rather than sharing that decision with a byte count.
var list_buf: std.ArrayList(u8) = .empty;

// NO capabilities. The VCS-marker climb this plugin used to run — its only
// reason for `fs_read` — is gone: the host detects a project root when a file
// is opened, over exactly the same markers (`app/session.zig`'s
// `project_markers`), and `weft.placeRoot()` reads that answer
// (`doc/place.md` §4.2). Two detectors of one fact were one too many, and the
// second cost a grant over the whole filesystem.
const cmds = [_]weft.CommandEntry{
    // Plumbing and diagnostics: in the palette, not in a menu — a
    // conventional File menu has no "remember" or "where is the root" row.
    .{ .name = "project.remember", .arity = .whole, .call = remember, .summary = "Remember this project so it shows up in recents.", .label = "Remember Project" },
    // The list as text, for the dashboard's section and a picker to read;
    // a person chooses from `project.open-recent`.
    .{ .name = "project.recent", .arity = .whole, .call = recent, .summary = "List the files you visited recently.", .internal = true },
    .{ .name = "project.recent-roots", .arity = .whole, .call = recentRoots, .summary = "List recently visited project roots.", .internal = true },
    .{ .name = "project.show-root", .arity = .whole, .call = projectRoot, .summary = "Say where this project's root is.", .label = "Show Project Root" },
    .{ .name = "project.open-recent", .arity = .whole, .call = openRecent, .summary = "Choose a file you visited recently and open it.", .label = "Open Recent", .prompts = true, .menu = "File", .group = "open", .order = 6, .icon = "history" },
};
comptime {
    weft.plugin(&cmds, .{ .pick = onPickAccept }).exportAll();
}

const pick_recent = 0;

/// `project.open-recent`: the recent files, most recent first, as a picker —
/// File › Open Recent….
fn openRecent() void {
    const list = weft.kvGet(recent_key) orelse "";
    if (list.len == 0) return weft.echo("no recent files");
    const owned = weft.allocator.dupe(u8, list) catch return;
    defer weft.allocator.free(owned);
    weft.pickBegin("recent", pick_recent);
    weft.pickCategory("file");
    var lines = std.mem.splitScalar(u8, owned, '\n');
    while (lines.next()) |path| if (path.len > 0) weft.pickAdd(path, "");
    weft.pickEnd();
}

fn onPickAccept(pick_id: u32) void {
    if (pick_id != pick_recent) return;
    var outcome = (weft.pickOutcome(weft.allocator) catch return) orelse return;
    defer outcome.deinit(weft.allocator);
    switch (outcome) {
        .candidate => |c| weft.runStr("file.open", c.text),
        .input, .cancelled => {},
    }
}

/// Every buffer focus records the file. The root no longer needs recording:
/// it is a property of WHERE the next command dispatches, read when asked
/// (`projectRoot`), not a value this plugin has to keep chasing focus to hold
/// current — and a tool buffer with no path of its own still answers, because
/// it carries the place of the entry that produced it.
fn on_activate() callconv(.c) void {
    _ = recordActive();
}

/// Push the active buffer's path onto the recent list (front, deduped, capped).
/// Returns the new count, or -1 when the buffer has no path (a tool buffer).
fn recordActive() i32 {
    const alloc = weft.allocator;
    // Copy both borrowed reads out before the next call reuses the shim
    // scratch. Owned, not copied into a fixed field: a truncated path names a
    // DIFFERENT file, and a recents list that quietly offers you one is worse
    // than a recents list that is short.
    const path = alloc.dupe(u8, weft.path() orelse return -1) catch return -1;
    defer alloc.free(path);
    const root = alloc.dupe(u8, weft.placeRoot()) catch return -1;
    defer alloc.free(root);
    if (root.len > 0) {
        const old_roots = alloc.dupe(u8, weft.kvGet(recent_roots_key) orelse "") catch return -1;
        defer alloc.free(old_roots);
        if (prepend(old_roots, root)) |roots| weft.kvPut(recent_roots_key, roots);
    }
    const existing = alloc.dupe(u8, weft.kvGet(recent_key) orelse "") catch return -1;
    defer alloc.free(existing);

    const list = prepend(existing, path) orelse return -1;
    weft.kvPut(recent_key, list);
    return @intCast(countLines(list));
}

/// The `project.remember` command: record + report the count.
fn remember() void {
    weft.setResultInt(recordActive());
}

/// The recent list as a newline-joined blob (a picker splits it).
fn recent() void {
    weft.setResultStr(weft.kvGet(recent_key) orelse "");
}

fn recentRoots() void {
    weft.setResultStr(weft.kvGet(recent_roots_key) orelse "");
}

/// `project.show-root` command: the project this command is in, absolute — which is
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

/// `path` newline-joined ahead of `list`, dropping any prior copy of `path` and
/// capping at `max_recent`. Builds into `list_buf`; null when the guest heap
/// refuses, so the caller reports rather than writing back a half list.
fn prepend(list: []const u8, path: []const u8) ?[]const u8 {
    const alloc = weft.allocator;
    list_buf.clearRetainingCapacity();
    list_buf.appendSlice(alloc, path) catch return null;
    var kept: usize = 1;
    var it = std.mem.splitScalar(u8, list, '\n');
    while (it.next()) |line| {
        if (line.len == 0 or std.mem.eql(u8, line, path)) continue;
        if (kept >= max_recent) break;
        list_buf.append(alloc, '\n') catch return null;
        list_buf.appendSlice(alloc, line) catch return null;
        kept += 1;
    }
    return list_buf.items;
}

fn countLines(list: []const u8) usize {
    if (list.len == 0) return 0;
    return std.mem.count(u8, list, "\n") + 1;
}

comptime {
    weft.exportCallback("on_activate", &on_activate);
}
