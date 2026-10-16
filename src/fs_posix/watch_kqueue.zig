//! The macOS backend of `watch.zig`: kqueue `EVFILT_VNODE` on `O_EVTONLY`
//! descriptors (event-only: they never block an unmount and grant no I/O).
//! One kqueue serves every root.
//!
//! kqueue reports WHICH vnode changed, never which entry: a directory's
//! `NOTE_WRITE` only says "my entries changed". So every watched directory
//! keeps the entries it last saw (name → inode, is-dir), and `drain`
//! rescans each directory that fired and diffs:
//! - an inode that vanished under one name and appeared under another in the
//!   same drain (and root) is a `.moved` of BOTH names (inotify's
//!   MOVED_FROM/MOVED_TO);
//! - otherwise vanished is `.delete`, appeared is `.create` — except a name
//!   that is itself a move destination is not also reported deleted;
//! - under a recursive root, a new directory gets a watch and a vanished one
//!   drops its subtree.
//! A root's own `NOTE_DELETE`/`NOTE_REVOKE` is a `.delete` of "", its
//! `NOTE_RENAME` a `.moved` of "" (`watch.zig`'s header).
//!
//! File CONTENT changes surface on per-file descriptors (`NOTE_WRITE` /
//! `NOTE_EXTEND` → `.modify`), because a directory vnode does not change when
//! a file inside it is written in place — and only under a RECURSIVE root.
//! A non-recursive root is its directory's entry set and costs exactly one
//! descriptor: a listing of a thousand-file directory must not take a
//! thousand of the process's descriptors (macOS's default soft limit is
//! 256), leaving none for the editor's own opens. So on macOS a
//! non-recursive root does not report an in-place write to one of its
//! files; inotify reports it for free, and does.
//!
//! Costs of a recursive root, stated plainly: one descriptor per watched
//! directory AND per regular file. A file whose descriptor cannot be opened
//! (e.g. `EMFILE`) is still tracked by its directory for create/delete/move,
//! but its in-place modifications go unreported. That is the inherent
//! kqueue trade; FSEvents is the tree-scale mechanism if this is ever wired
//! to large trees (it needs CoreServices and a dispatch queue, which is why
//! it is not used here).
//!
//! `drain` calls `kevent` with a zero timeout: non-blocking, frame-thread
//! only, and the kqueue fd is never handed to `poll()`. `wakeFd` is a
//! self-pipe a helper thread writes (see `Wake`).

comptime {
    if (!@import("builtin").os.tag.isDarwin()) @compileError("watch_kqueue.zig is Darwin-only (O_EVTONLY)");
}

const std = @import("std");
const c = std.c;
const Allocator = std.mem.Allocator;
const watch = @import("watch.zig");

const Kqueue = @This();

kq: i32,
next_root: watch.RootId = 1,
roots: std.AutoHashMapUnmanaged(watch.RootId, Root) = .empty,
/// Every open vnode watch, keyed by its descriptor (the kevent `ident`).
nodes: std.AutoHashMapUnmanaged(i32, Node) = .empty,
/// Started by the first `wakeFd`; null until a caller asks to be woken.
wake: ?Wake = null,

const Root = struct {
    /// Owned copy of the path as `add` got it.
    path: []u8,
    recursive: bool,
    /// Root-relative directory path → its watch descriptor. Keys borrow
    /// `Node.path`.
    dirs: std.StringHashMapUnmanaged(i32) = .empty,
    /// Root-relative file path → its watch descriptor. Keys borrow
    /// `Node.path`. Empty unless `recursive`.
    files: std.StringHashMapUnmanaged(i32) = .empty,
};

const Node = struct {
    root: watch.RootId,
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
const Change = struct { root: watch.RootId, path: []u8, inode: u64, kind: EntryKind, paired: bool = false };

/// Something phase 1 saw fire, by (root, path). `path` owned.
const Fired = struct { root: watch.RootId, path: []u8 };

/// A root that itself left. Reported after the entry changes of the drain.
const Gone = struct { root: watch.RootId, kind: watch.Kind };

const dir_notes: u32 = c.NOTE.WRITE | c.NOTE.EXTEND | c.NOTE.DELETE | c.NOTE.RENAME | c.NOTE.REVOKE;
const file_notes: u32 = c.NOTE.WRITE | c.NOTE.EXTEND | c.NOTE.DELETE | c.NOTE.RENAME | c.NOTE.REVOKE;

pub fn init(gpa: Allocator) watch.Error!Kqueue {
    _ = gpa;
    const kq = c.kqueue();
    if (kq < 0) return error.WatchInit;
    return .{ .kq = kq };
}

pub fn deinit(self: *Kqueue, gpa: Allocator) void {
    if (self.wake) |*w| w.stop();
    var it = self.nodes.iterator();
    while (it.next()) |kv| {
        _ = c.close(kv.key_ptr.*);
        freeNode(gpa, kv.value_ptr);
    }
    self.nodes.deinit(gpa);
    var roots = self.roots.valueIterator();
    while (roots.next()) |root| freeRoot(gpa, root);
    self.roots.deinit(gpa);
    _ = c.close(self.kq);
    self.* = undefined;
}

fn freeNode(gpa: Allocator, node: *Node) void {
    var keys = node.entries.keyIterator();
    while (keys.next()) |k| gpa.free(k.*);
    node.entries.deinit(gpa);
    gpa.free(node.path);
}

fn freeRoot(gpa: Allocator, root: *Root) void {
    root.dirs.deinit(gpa);
    root.files.deinit(gpa);
    gpa.free(root.path);
}

pub fn watchCount(self: *const Kqueue) usize {
    var n: usize = 0;
    var roots = self.roots.valueIterator();
    while (roots.next()) |root| n += root.dirs.count();
    return n;
}

pub fn add(self: *Kqueue, gpa: Allocator, root_path: []const u8, options: watch.Options) watch.Error!watch.RootId {
    const id = self.next_root;
    const path = try gpa.dupe(u8, root_path);
    self.roots.put(gpa, id, .{ .path = path, .recursive = options.recursive }) catch |err| {
        gpa.free(path);
        return err;
    };
    self.next_root += 1;
    errdefer self.remove(gpa, id);
    try self.addTree(gpa, id, "");
    // The root itself must take; a subdirectory that vanished mid-walk is
    // only best effort.
    const root = self.roots.getPtr(id).?;
    if (!root.dirs.contains("")) return error.WatchInit;
    return id;
}

pub fn remove(self: *Kqueue, gpa: Allocator, root: watch.RootId) void {
    if (!self.roots.contains(root)) return;
    // Find-then-remove, one at a time: the map is never mutated while it is
    // being iterated.
    while (true) {
        var it = self.nodes.iterator();
        const victim: i32 = while (it.next()) |kv| {
            if (kv.value_ptr.root == root) break kv.key_ptr.*;
        } else break;
        self.unwatchFd(gpa, victim);
    }
    var kv = self.roots.fetchRemove(root).?;
    freeRoot(gpa, &kv.value);
}

pub fn wakeFd(self: *Kqueue) watch.Error!i32 {
    if (self.wake == null) self.wake = try Wake.start(self.kq);
    return self.wake.?.pipe[0];
}

/// Collect every queued vnode event (zero-timeout `kevent`), rescan the
/// directories that changed, then report: moves, deletes, creates, in-place
/// modifications, and finally any root that itself left.
pub fn drain(self: *Kqueue, gpa: Allocator, sink: watch.Sink) watch.Error!void {
    // The wake pipe first: an event landing after the kqueue is read below
    // writes it again, so emptying it afterwards could swallow that wake.
    if (self.wake) |*w| w.drain();

    // Phase 1: copy out what fired, by (root, PATH). Nothing is opened or
    // closed until every queued event is read, so a descriptor number can
    // never be reused under an event that still names its old owner.
    var rescan: std.ArrayList(Fired) = .empty;
    defer freeFired(gpa, &rescan);
    var modified: std.ArrayList(Fired) = .empty;
    defer freeFired(gpa, &modified);
    var gone: std.ArrayList(Gone) = .empty;
    defer gone.deinit(gpa);
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
                if (ev.fflags & (c.NOTE.WRITE | c.NOTE.EXTEND) != 0 and !containsFired(rescan.items, node.root, node.path))
                    try appendFired(gpa, &rescan, node.root, node.path);
                // The root itself left. Below a root, a vnode's DELETE or
                // RENAME is named by its parent directory's NOTE_WRITE,
                // whose rescan drops the watch.
                if (node.path.len == 0) {
                    if (ev.fflags & (c.NOTE.DELETE | c.NOTE.REVOKE) != 0)
                        try gone.append(gpa, .{ .root = node.root, .kind = .delete })
                    else if (ev.fflags & c.NOTE.RENAME != 0)
                        try gone.append(gpa, .{ .root = node.root, .kind = .moved });
                }
            } else if (ev.fflags & (c.NOTE.WRITE | c.NOTE.EXTEND) != 0) {
                try appendFired(gpa, &modified, node.root, node.path);
            }
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
    for (rescan.items) |dir| try self.rescanDir(gpa, dir.root, dir.path, &vanished, &appeared);

    // Phase 3: retarget the watches of recursive roots (vanished first, so
    // a replaced name's old descriptor is gone before the new one opens). A
    // non-recursive root watches only its own directory: nothing to move.
    for (vanished.items) |ch| if (self.isRecursive(ch.root)) switch (ch.kind) {
        .dir => self.unwatchTree(gpa, ch.root, ch.path),
        .file => self.unwatchFile(gpa, ch.root, ch.path),
        .other => {},
    };
    for (appeared.items) |ch| if (self.isRecursive(ch.root)) switch (ch.kind) {
        .dir => self.addTree(gpa, ch.root, ch.path) catch {},
        .file => self.watchFile(gpa, ch.root, ch.path) catch {},
        .other => {},
    };

    // Phase 4: report.
    for (vanished.items) |*from| {
        for (appeared.items) |*to| {
            if (to.paired or to.root != from.root or to.inode != from.inode) continue;
            from.paired = true;
            to.paired = true;
            sink.call(sink.ctx, .{ .root = from.root, .kind = .moved, .path = from.path });
            sink.call(sink.ctx, .{ .root = to.root, .kind = .moved, .path = to.path });
            break;
        }
    }
    for (vanished.items) |from| {
        if (from.paired) continue;
        if (isMoveDestination(appeared.items, from.root, from.path)) continue;
        sink.call(sink.ctx, .{ .root = from.root, .kind = .delete, .path = from.path });
    }
    for (appeared.items) |to| {
        if (!to.paired) sink.call(sink.ctx, .{ .root = to.root, .kind = .create, .path = to.path });
    }
    for (modified.items) |p| sink.call(sink.ctx, .{ .root = p.root, .kind = .modify, .path = p.path });
    for (gone.items) |g| if (self.roots.contains(g.root)) sink.call(sink.ctx, .{ .root = g.root, .kind = g.kind, .path = "" });
}

fn isRecursive(self: *const Kqueue, root: watch.RootId) bool {
    const r = self.roots.get(root) orelse return false;
    return r.recursive;
}

fn freeFired(gpa: Allocator, list: *std.ArrayList(Fired)) void {
    for (list.items) |f| gpa.free(f.path);
    list.deinit(gpa);
}

fn appendFired(gpa: Allocator, list: *std.ArrayList(Fired), root: watch.RootId, path: []const u8) watch.Error!void {
    const owned = try gpa.dupe(u8, path);
    list.append(gpa, .{ .root = root, .path = owned }) catch |err| {
        gpa.free(owned);
        return err;
    };
}

fn containsFired(fired: []const Fired, root: watch.RootId, path: []const u8) bool {
    for (fired) |f| if (f.root == root and std.mem.eql(u8, f.path, path)) return true;
    return false;
}

fn isMoveDestination(appeared: []const Change, root: watch.RootId, path: []const u8) bool {
    for (appeared) |ch| if (ch.paired and ch.root == root and std.mem.eql(u8, ch.path, path)) return true;
    return false;
}

// ── watch management ────────────────────────────────────────────────

/// Watch directory `subpath` of `root` and record its entries; under a
/// recursive root, recurse: every subdirectory gets its own watch, every
/// regular file a content watch.
fn addTree(self: *Kqueue, gpa: Allocator, root: watch.RootId, subpath: []const u8) watch.Error!void {
    const state = self.roots.getPtr(root) orelse return;
    if (state.dirs.contains(subpath)) return;
    const recursive = state.recursive;
    const fd = try self.openWatch(gpa, root, subpath, true) orelse return;
    // The snapshot is the directory as it is now (a fresh node has none).
    const entries = try self.scan(gpa, root, subpath) orelse return;
    const node = self.nodes.getPtr(fd).?;
    node.entries = entries;
    if (!recursive) return;
    // Recurse only after collecting the children: `node` may move as
    // `nodes` grows, so the pointer is not held across the recursion.
    var children: std.ArrayList(Change) = .empty;
    defer {
        for (children.items) |ch| gpa.free(ch.path);
        children.deinit(gpa);
    }
    var names = node.entries.iterator();
    while (names.next()) |kv| try appendChange(gpa, &children, root, subpath, kv.key_ptr.*, kv.value_ptr.*);
    for (children.items) |ch| switch (ch.kind) {
        .dir => try self.addTree(gpa, root, ch.path),
        .file => try self.watchFile(gpa, root, ch.path),
        .other => {},
    };
}

fn watchFile(self: *Kqueue, gpa: Allocator, root: watch.RootId, path: []const u8) watch.Error!void {
    const state = self.roots.getPtr(root) orelse return;
    if (state.files.contains(path)) return;
    _ = try self.openWatch(gpa, root, path, false);
}

/// Open `path` of `root` event-only (never following a symlink), register
/// it, and record it. `null` when it cannot be watched (gone, not the
/// expected kind, or out of descriptors) — best effort, never fatal.
fn openWatch(self: *Kqueue, gpa: Allocator, root: watch.RootId, path: []const u8, is_dir: bool) watch.Error!?i32 {
    const base = (self.roots.get(root) orelse return null).path;
    const pz = try watch.fullPathZ(gpa, base, path);
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
    self.nodes.put(gpa, fd, .{ .root = root, .path = owned, .is_dir = is_dir }) catch |err| {
        gpa.free(owned);
        _ = c.close(fd);
        return err;
    };
    const state = self.roots.getPtr(root).?;
    const index = if (is_dir) &state.dirs else &state.files;
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
    if (self.roots.getPtr(kv.value.root)) |state| {
        if (kv.value.is_dir) _ = state.dirs.remove(kv.value.path) else _ = state.files.remove(kv.value.path);
    }
    _ = c.close(fd); // closing the descriptor also deletes its knote
    freeNode(gpa, &kv.value);
}

fn unwatchFile(self: *Kqueue, gpa: Allocator, root: watch.RootId, path: []const u8) void {
    const state = self.roots.getPtr(root) orelse return;
    const fd = state.files.get(path) orelse return;
    self.unwatchFd(gpa, fd);
}

/// Drop the watch on directory `path` of `root` and on everything beneath it.
fn unwatchTree(self: *Kqueue, gpa: Allocator, root: watch.RootId, path: []const u8) void {
    // Find-then-remove, one at a time: the map is never mutated while it is
    // being iterated, and nothing here needs to allocate.
    while (true) {
        var it = self.nodes.iterator();
        const victim: i32 = while (it.next()) |kv| {
            if (kv.value_ptr.root == root and within(kv.value_ptr.path, path)) break kv.key_ptr.*;
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

/// The current entries of directory `subpath` of `root` (keys owned by the
/// caller's map), or `null` if it can no longer be opened.
fn scan(self: *Kqueue, gpa: Allocator, root: watch.RootId, subpath: []const u8) watch.Error!?std.StringHashMapUnmanaged(Seen) {
    const base = (self.roots.get(root) orelse return null).path;
    const pz = try watch.fullPathZ(gpa, base, subpath);
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

/// Diff directory `dir_path` of `root` against its snapshot; append what
/// left to `vanished` and what arrived (or changed inode) to `appeared`, and
/// adopt the new listing as the snapshot.
fn rescanDir(
    self: *Kqueue,
    gpa: Allocator,
    root: watch.RootId,
    dir_path: []const u8,
    vanished: *std.ArrayList(Change),
    appeared: *std.ArrayList(Change),
) watch.Error!void {
    const state = self.roots.getPtr(root) orelse return;
    const fd = state.dirs.get(dir_path) orelse return;
    var fresh = try self.scan(gpa, root, dir_path) orelse std.StringHashMapUnmanaged(Seen).empty;
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
        try appendChange(gpa, vanished, root, dir_path, kv.key_ptr.*, kv.value_ptr.*);
    }
    var new_it = fresh.iterator();
    while (new_it.next()) |kv| {
        const before = node.entries.get(kv.key_ptr.*);
        if (before != null and before.?.inode == kv.value_ptr.inode) continue;
        try appendChange(gpa, appeared, root, dir_path, kv.key_ptr.*, kv.value_ptr.*);
    }
    var keys = node.entries.keyIterator();
    while (keys.next()) |k| gpa.free(k.*);
    node.entries.deinit(gpa);
    node.entries = fresh;
}

fn appendChange(gpa: Allocator, list: *std.ArrayList(Change), root: watch.RootId, dir: []const u8, name: []const u8, seen: Seen) watch.Error!void {
    const path = try watch.childPath(gpa, dir, name);
    list.append(gpa, .{ .root = root, .path = path, .inode = seen.inode, .kind = seen.kind }) catch |err| {
        gpa.free(path);
        return err;
    };
}

// ── waking the frame loop ───────────────────────────────────────────

/// The self-pipe `watch.zig`'s header describes. A helper thread waits in
/// `kevent` on `outer`, a second kqueue holding the watch kqueue as an
/// edge-triggered `EVFILT_READ` (a kqueue may wait on another; `poll` on one
/// is what is unreliable), and writes a byte to the pipe whenever events
/// arrive. It never reads an event: `drain`, on the frame thread, does.
/// `EVFILT_USER` is how `stop` tells it to leave.
const Wake = struct {
    outer: i32,
    /// `[0]` is the wake fd (non-blocking read end); `[1]` the helper's.
    pipe: [2]i32,
    thread: std.Thread,

    const stop_ident: usize = 1;

    fn start(kq: i32) watch.Error!Wake {
        const fds = makePipe() orelse return error.WatchInit;
        errdefer for (fds) |fd| {
            _ = c.close(fd);
        };
        const outer = c.kqueue();
        if (outer < 0) return error.WatchInit;
        errdefer _ = c.close(outer);
        var changes: [2]c.Kevent = .{
            .{ .ident = @intCast(kq), .filter = c.EVFILT.READ, .flags = c.EV.ADD | c.EV.ENABLE | c.EV.CLEAR, .fflags = 0, .data = 0, .udata = 0 },
            .{ .ident = stop_ident, .filter = c.EVFILT.USER, .flags = c.EV.ADD | c.EV.ENABLE | c.EV.CLEAR, .fflags = 0, .data = 0, .udata = 0 },
        };
        var none: [0]c.Kevent = .{};
        if (c.kevent(outer, &changes, changes.len, &none, 0, null) < 0) return error.WatchInit;
        const thread = std.Thread.spawn(.{}, run, .{ outer, fds[1] }) catch return error.WatchInit;
        return .{ .outer = outer, .pipe = fds, .thread = thread };
    }

    fn run(outer: i32, write_end: i32) void {
        var none: [0]c.Kevent = .{};
        var ev: [1]c.Kevent = undefined;
        while (true) {
            const n = c.kevent(outer, &none, 0, &ev, 1, null);
            if (n < 0) {
                if (c.errno(n) == .INTR) continue;
                return;
            }
            if (n == 0) continue;
            if (ev[0].filter == c.EVFILT.USER) return;
            // A full pipe already reads as woken: EAGAIN is the coalescing.
            const byte = [1]u8{1};
            _ = c.write(write_end, &byte, 1);
        }
    }

    fn drain(self: *Wake) void {
        var buf: [64]u8 = undefined;
        while (c.read(self.pipe[0], &buf, buf.len) > 0) {}
    }

    fn stop(self: *Wake) void {
        var trigger: [1]c.Kevent = .{.{ .ident = stop_ident, .filter = c.EVFILT.USER, .flags = 0, .fflags = c.NOTE.TRIGGER, .data = 0, .udata = 0 }};
        var none: [0]c.Kevent = .{};
        _ = c.kevent(self.outer, &trigger, 1, &none, 0, null);
        self.thread.join();
        _ = c.close(self.outer);
        for (self.pipe) |fd| _ = c.close(fd);
    }

    /// A non-blocking, close-on-exec pipe (Darwin has no `pipe2`).
    fn makePipe() ?[2]i32 {
        var fds: [2]i32 = undefined;
        if (c.pipe(&fds) != 0) return null;
        const nonblock: c_int = @bitCast(@as(u32, @bitCast(c.O{ .NONBLOCK = true })));
        for (fds) |fd| {
            const fl = c.fcntl(fd, c.F.GETFL);
            const fd_flags = c.fcntl(fd, c.F.GETFD);
            if (fl < 0 or fd_flags < 0 or
                c.fcntl(fd, c.F.SETFL, fl | nonblock) < 0 or
                c.fcntl(fd, c.F.SETFD, fd_flags | @as(c_int, c.FD_CLOEXEC)) < 0)
            {
                for (fds) |f| _ = c.close(f);
                return null;
            }
        }
        return fds;
    }
};
