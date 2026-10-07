//! The macOS backend of `watch.zig`: kqueue `EVFILT_VNODE` on `O_EVTONLY`
//! descriptors (event-only: they never block an unmount and grant no I/O).
//!
//! kqueue reports WHICH vnode changed, never which entry: a directory's
//! `NOTE_WRITE` only says "my entries changed". So every watched directory
//! keeps the entries it last saw (name → inode, is-dir), and `drain`
//! rescans each directory that fired and diffs:
//! - an inode that vanished under one name and appeared under another in the
//!   same drain is a `.moved` of BOTH names (inotify's MOVED_FROM/MOVED_TO);
//! - otherwise vanished is `.delete`, appeared is `.create` — except a name
//!   that is itself a move destination is not also reported deleted;
//! - a new directory gets a recursive watch, a vanished one drops its subtree.
//! File CONTENT changes surface on per-file descriptors (`NOTE_WRITE` /
//! `NOTE_EXTEND` → `.modify`), because a directory vnode does not change when
//! a file inside it is written in place.
//!
//! Costs, stated plainly: one descriptor per watched directory AND per
//! regular file. A file whose descriptor cannot be opened (e.g. `EMFILE` —
//! macOS's default soft limit is 256) is still tracked by its directory for
//! create/delete/move, but its in-place modifications go unreported. That is
//! the inherent kqueue trade; FSEvents is the tree-scale mechanism if this
//! module is ever wired to large trees (it needs CoreServices and a dispatch
//! queue, which is why it is not used here).
//!
//! `drain` calls `kevent` with a zero timeout: non-blocking, frame-thread
//! only, and the kqueue fd is never handed to `poll()` (see `watch.zig`).

comptime {
    if (!@import("builtin").os.tag.isDarwin()) @compileError("watch_kqueue.zig is Darwin-only (O_EVTONLY)");
}

const std = @import("std");
const c = std.c;
const Allocator = std.mem.Allocator;
const watch = @import("watch.zig");

const Kqueue = @This();

kq: i32,
/// Owned copy of the root path (as handed to `init`).
root: []u8,
/// Every open vnode watch, keyed by its descriptor (the kevent `ident`).
nodes: std.AutoHashMapUnmanaged(i32, Node),
/// Root-relative directory path → its watch descriptor. Keys borrow
/// `Node.path`.
dirs: std.StringHashMapUnmanaged(i32),
/// Root-relative file path → its watch descriptor. Keys borrow `Node.path`.
files: std.StringHashMapUnmanaged(i32),

const Node = struct {
    /// Root-relative ("" is the root itself). Owned.
    path: []u8,
    is_dir: bool,
    /// Directories only: what the last scan saw. Keys owned.
    entries: std.StringHashMapUnmanaged(Seen) = .empty,
};

/// What a scan saw an entry to be. Only `.dir` is descended into and only
/// `.file` gets a content watch; symlinks and specials (a fifo would block an
/// open) are tracked by name — create/delete/move — but never opened.
const EntryKind = enum { dir, file, other };

const Seen = struct { inode: u64, kind: EntryKind };

/// One side of a structural change found by a rescan. `path` owned.
const Change = struct { path: []u8, inode: u64, kind: EntryKind, paired: bool = false };

const dir_notes: u32 = c.NOTE.WRITE | c.NOTE.EXTEND | c.NOTE.DELETE | c.NOTE.RENAME | c.NOTE.REVOKE;
const file_notes: u32 = c.NOTE.WRITE | c.NOTE.EXTEND | c.NOTE.DELETE | c.NOTE.RENAME | c.NOTE.REVOKE;

pub fn init(gpa: Allocator, root_path: []const u8) watch.Error!Kqueue {
    const kq = c.kqueue();
    if (kq < 0) return error.WatchInit;
    errdefer _ = c.close(kq);
    var self: Kqueue = .{
        .kq = kq,
        .root = try gpa.dupe(u8, root_path),
        .nodes = .empty,
        .dirs = .empty,
        .files = .empty,
    };
    errdefer self.freeAll(gpa);
    try self.addTree(gpa, "");
    return self;
}

pub fn deinit(self: *Kqueue, gpa: Allocator) void {
    self.freeAll(gpa);
    _ = c.close(self.kq);
    self.* = undefined;
}

fn freeAll(self: *Kqueue, gpa: Allocator) void {
    var it = self.nodes.iterator();
    while (it.next()) |kv| {
        _ = c.close(kv.key_ptr.*);
        freeNode(gpa, kv.value_ptr);
    }
    self.nodes.deinit(gpa);
    self.dirs.deinit(gpa);
    self.files.deinit(gpa);
    gpa.free(self.root);
}

fn freeNode(gpa: Allocator, node: *Node) void {
    var keys = node.entries.keyIterator();
    while (keys.next()) |k| gpa.free(k.*);
    node.entries.deinit(gpa);
    gpa.free(node.path);
}

pub fn watchCount(self: *const Kqueue) usize {
    return self.dirs.count();
}

/// Collect every queued vnode event (zero-timeout `kevent`), rescan the
/// directories that changed, then report: moves, deletes, creates, and
/// finally in-place modifications.
pub fn drain(self: *Kqueue, gpa: Allocator, sink: watch.Sink) watch.Error!void {
    // Phase 1: copy out what fired, by PATH. Nothing is opened or closed
    // until every queued event is read, so a descriptor number can never be
    // reused under an event that still names its old owner.
    var rescan: std.ArrayList([]u8) = .empty;
    defer {
        for (rescan.items) |p| gpa.free(p);
        rescan.deinit(gpa);
    }
    var modified: std.ArrayList([]u8) = .empty;
    defer {
        for (modified.items) |p| gpa.free(p);
        modified.deinit(gpa);
    }
    var events: [64]c.Kevent = undefined;
    const zero: c.timespec = .{ .sec = 0, .nsec = 0 };
    while (true) {
        const n = c.kevent(self.kq, &events, 0, &events, @intCast(events.len), &zero);
        if (n < 0) {
            if (c.errno(n) == .INTR) continue;
            return error.ReadFailed;
        }
        for (events[0..@intCast(n)]) |ev| {
            const node = self.nodes.get(@intCast(ev.ident)) orelse continue;
            if (node.is_dir) {
                if (ev.fflags & (c.NOTE.WRITE | c.NOTE.EXTEND) != 0 and !containsPath(rescan.items, node.path))
                    try rescan.append(gpa, try gpa.dupe(u8, node.path));
            } else if (ev.fflags & (c.NOTE.WRITE | c.NOTE.EXTEND) != 0) {
                try modified.append(gpa, try gpa.dupe(u8, node.path));
            }
            // DELETE/RENAME on any vnode: its parent directory's NOTE_WRITE
            // names it, and that rescan drops the watch.
        }
        if (n < events.len) break;
    }

    // Phase 2: diff the changed directories.
    var vanished: std.ArrayList(Change) = .empty;
    var appeared: std.ArrayList(Change) = .empty;
    defer {
        for (vanished.items) |ch| gpa.free(ch.path);
        vanished.deinit(gpa);
        for (appeared.items) |ch| gpa.free(ch.path);
        appeared.deinit(gpa);
    }
    for (rescan.items) |dir_path| try self.rescanDir(gpa, dir_path, &vanished, &appeared);

    // Phase 3: retarget the watches (vanished first, so a replaced name's
    // old descriptor is gone before the new one opens).
    for (vanished.items) |ch| switch (ch.kind) {
        .dir => self.unwatchTree(gpa, ch.path),
        .file => self.unwatchFile(gpa, ch.path),
        .other => {},
    };
    for (appeared.items) |ch| switch (ch.kind) {
        .dir => self.addTree(gpa, ch.path) catch {},
        .file => self.watchFile(gpa, ch.path) catch {},
        .other => {},
    };

    // Phase 4: report.
    for (vanished.items) |*from| {
        for (appeared.items) |*to| {
            if (to.paired or to.inode != from.inode) continue;
            from.paired = true;
            to.paired = true;
            sink.call(sink.ctx, .{ .kind = .moved, .path = from.path });
            sink.call(sink.ctx, .{ .kind = .moved, .path = to.path });
            break;
        }
    }
    for (vanished.items) |from| {
        if (from.paired) continue;
        if (isMoveDestination(appeared.items, from.path)) continue;
        sink.call(sink.ctx, .{ .kind = .delete, .path = from.path });
    }
    for (appeared.items) |to| {
        if (!to.paired) sink.call(sink.ctx, .{ .kind = .create, .path = to.path });
    }
    for (modified.items) |p| sink.call(sink.ctx, .{ .kind = .modify, .path = p });
}

fn containsPath(paths: []const []u8, path: []const u8) bool {
    for (paths) |p| if (std.mem.eql(u8, p, path)) return true;
    return false;
}

fn isMoveDestination(appeared: []const Change, path: []const u8) bool {
    for (appeared) |ch| if (ch.paired and std.mem.eql(u8, ch.path, path)) return true;
    return false;
}

// ── watch management ────────────────────────────────────────────────

/// Watch directory `subpath`, record its entries, and recurse: every
/// subdirectory gets its own watch, every regular file a content watch.
fn addTree(self: *Kqueue, gpa: Allocator, subpath: []const u8) watch.Error!void {
    if (self.dirs.contains(subpath)) return;
    const fd = try self.openWatch(gpa, subpath, true) orelse return;
    const node = self.nodes.getPtr(fd).?;
    // The snapshot is the directory as it is now (a fresh node has none).
    node.entries = try self.scan(gpa, subpath) orelse return;
    // Recurse only after collecting the children: `node` may move as
    // `nodes` grows, so the pointer is not held across the recursion.
    var children: std.ArrayList(Change) = .empty;
    defer {
        for (children.items) |ch| gpa.free(ch.path);
        children.deinit(gpa);
    }
    var names = node.entries.iterator();
    while (names.next()) |kv| try appendChange(gpa, &children, subpath, kv.key_ptr.*, kv.value_ptr.*);
    for (children.items) |ch| switch (ch.kind) {
        .dir => try self.addTree(gpa, ch.path),
        .file => try self.watchFile(gpa, ch.path),
        .other => {},
    };
}

fn watchFile(self: *Kqueue, gpa: Allocator, path: []const u8) watch.Error!void {
    if (self.files.contains(path)) return;
    _ = try self.openWatch(gpa, path, false);
}

/// Open `path` event-only (never following a symlink), register it, and
/// record it. `null` when it cannot be watched (gone, not the expected kind,
/// or out of descriptors) — best effort, never fatal.
fn openWatch(self: *Kqueue, gpa: Allocator, path: []const u8, is_dir: bool) watch.Error!?i32 {
    const pz = try watch.fullPathZ(gpa, self.root, path);
    defer gpa.free(pz);
    // NONBLOCK: if the name was swapped for a fifo since the scan, the open
    // must not wait for a writer.
    const fd = c.open(pz.ptr, .{ .EVTONLY = true, .NOFOLLOW = true, .NONBLOCK = true, .CLOEXEC = true, .DIRECTORY = is_dir }, @as(c_uint, 0));
    if (fd < 0) return null;
    var change: [1]c.Kevent = .{.{
        .ident = @intCast(fd),
        .filter = c.EVFILT.VNODE,
        .flags = c.EV.ADD | c.EV.ENABLE | c.EV.CLEAR,
        .fflags = if (is_dir) dir_notes else file_notes,
        .data = 0,
        .udata = 0,
    }};
    var none: [0]c.Kevent = .{};
    if (c.kevent(self.kq, &change, 1, &none, 0, null) < 0) {
        _ = c.close(fd);
        return null;
    }
    const owned = gpa.dupe(u8, path) catch |err| {
        _ = c.close(fd);
        return err;
    };
    self.nodes.put(gpa, fd, .{ .path = owned, .is_dir = is_dir }) catch |err| {
        gpa.free(owned);
        _ = c.close(fd);
        return err;
    };
    const index = if (is_dir) &self.dirs else &self.files;
    index.put(gpa, owned, fd) catch |err| {
        _ = self.nodes.remove(fd);
        gpa.free(owned);
        _ = c.close(fd);
        return err;
    };
    return fd;
}

fn unwatchFd(self: *Kqueue, gpa: Allocator, fd: i32) void {
    var kv = self.nodes.fetchRemove(fd) orelse return;
    if (kv.value.is_dir) _ = self.dirs.remove(kv.value.path) else _ = self.files.remove(kv.value.path);
    _ = c.close(fd); // closing the descriptor also deletes its knote
    freeNode(gpa, &kv.value);
}

fn unwatchFile(self: *Kqueue, gpa: Allocator, path: []const u8) void {
    const fd = self.files.get(path) orelse return;
    self.unwatchFd(gpa, fd);
}

/// Drop the watch on directory `path` and on everything beneath it.
fn unwatchTree(self: *Kqueue, gpa: Allocator, path: []const u8) void {
    // Find-then-remove, one at a time: the map is never mutated while it is
    // being iterated, and nothing here needs to allocate.
    while (true) {
        var it = self.nodes.iterator();
        const victim: i32 = while (it.next()) |kv| {
            if (within(kv.value_ptr.path, path)) break kv.key_ptr.*;
        } else return;
        self.unwatchFd(gpa, victim);
    }
}

/// `p` is `dir` or lies beneath it.
fn within(p: []const u8, dir: []const u8) bool {
    if (std.mem.eql(u8, p, dir)) return true;
    return std.mem.startsWith(u8, p, dir) and p.len > dir.len and p[dir.len] == '/';
}

// ── scanning ────────────────────────────────────────────────────────

/// The current entries of directory `subpath` (keys owned by the caller's
/// map), or `null` if it can no longer be opened.
fn scan(self: *Kqueue, gpa: Allocator, subpath: []const u8) watch.Error!?std.StringHashMapUnmanaged(Seen) {
    const pz = try watch.fullPathZ(gpa, self.root, subpath);
    defer gpa.free(pz);
    const fd = c.open(pz.ptr, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .NOFOLLOW = true, .CLOEXEC = true }, @as(c_uint, 0));
    if (fd < 0) return null;
    defer _ = c.close(fd);
    var out: std.StringHashMapUnmanaged(Seen) = .empty;
    errdefer {
        var keys = out.keyIterator();
        while (keys.next()) |k| gpa.free(k.*);
        out.deinit(gpa);
    }
    var threaded: std.Io.Threaded = .init_single_threaded;
    const dir: std.Io.Dir = .{ .handle = fd };
    var it = dir.iterateAssumeFirstIteration();
    while (it.next(threaded.io()) catch return error.ReadFailed) |entry| {
        const kind: EntryKind = switch (entry.kind) {
            .directory => .dir,
            .file => .file,
            .unknown => kindAt(fd, entry.name),
            else => .other,
        };
        const name = try gpa.dupe(u8, entry.name);
        out.put(gpa, name, .{ .inode = entry.inode, .kind = kind }) catch |err| {
            gpa.free(name);
            return err;
        };
    }
    return out;
}

/// `d_type` was `DT_UNKNOWN`: ask the inode, without following.
fn kindAt(dir_fd: i32, name: []const u8) EntryKind {
    var buf: [1024]u8 = undefined;
    if (name.len >= buf.len) return .other;
    @memcpy(buf[0..name.len], name);
    buf[name.len] = 0;
    var st: c.Stat = undefined;
    if (c.fstatat(dir_fd, buf[0..name.len :0], &st, c.AT.SYMLINK_NOFOLLOW) != 0) return .other;
    return switch (st.mode & c.S.IFMT) {
        c.S.IFDIR => .dir,
        c.S.IFREG => .file,
        else => .other,
    };
}

/// Diff directory `dir_path` against its snapshot; append what left to
/// `vanished` and what arrived (or changed inode) to `appeared`, and adopt
/// the new listing as the snapshot.
fn rescanDir(
    self: *Kqueue,
    gpa: Allocator,
    dir_path: []const u8,
    vanished: *std.ArrayList(Change),
    appeared: *std.ArrayList(Change),
) watch.Error!void {
    const fd = self.dirs.get(dir_path) orelse return;
    var fresh = try self.scan(gpa, dir_path) orelse std.StringHashMapUnmanaged(Seen).empty;
    errdefer {
        var keys = fresh.keyIterator();
        while (keys.next()) |k| gpa.free(k.*);
        fresh.deinit(gpa);
    }
    const node = self.nodes.getPtr(fd).?;
    var old_it = node.entries.iterator();
    while (old_it.next()) |kv| {
        const now = fresh.get(kv.key_ptr.*);
        if (now != null and now.?.inode == kv.value_ptr.inode) continue;
        try appendChange(gpa, vanished, dir_path, kv.key_ptr.*, kv.value_ptr.*);
    }
    var new_it = fresh.iterator();
    while (new_it.next()) |kv| {
        const before = node.entries.get(kv.key_ptr.*);
        if (before != null and before.?.inode == kv.value_ptr.inode) continue;
        try appendChange(gpa, appeared, dir_path, kv.key_ptr.*, kv.value_ptr.*);
    }
    var keys = node.entries.keyIterator();
    while (keys.next()) |k| gpa.free(k.*);
    node.entries.deinit(gpa);
    node.entries = fresh;
}

fn appendChange(gpa: Allocator, list: *std.ArrayList(Change), dir: []const u8, name: []const u8, seen: Seen) watch.Error!void {
    const path = try watch.childPath(gpa, dir, name);
    list.append(gpa, .{ .path = path, .inode = seen.inode, .kind = seen.kind }) catch |err| {
        gpa.free(path);
        return err;
    };
}
