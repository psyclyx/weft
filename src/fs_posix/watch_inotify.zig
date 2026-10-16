//! The Linux backend of `watch.zig`: raw inotify. One instance for every
//! root; one watch descriptor per directory; the kernel names each event's
//! entry, so `drain` only has to map `wd` back to the roots watching that
//! directory and their root-relative subpaths. The inotify fd is
//! `IN_NONBLOCK`, and `drain` reads it to EAGAIN and returns — it is also
//! the wake descriptor (`poll` reports it readable while events wait).
//!
//! The kernel keeps ONE watch per inode per instance: adding a directory a
//! second root already watches returns the same `wd`. So a `wd` carries a
//! list of OWNERS (root, subpath), and only the last owner's removal asks
//! the kernel to drop the watch.

comptime {
    if (@import("builtin").os.tag != .linux) @compileError("watch_inotify.zig is Linux-only");
}

const std = @import("std");
const Allocator = std.mem.Allocator;
const linux = std.os.linux;
const watch = @import("watch.zig");

const Inotify = @This();

/// The inotify fd. Non-blocking; drained on the frame thread.
fd: i32,
next_root: watch.RootId = 1,
roots: std.AutoHashMapUnmanaged(watch.RootId, Root) = .empty,
/// watch descriptor → every (root, subpath) it stands for. The kernel hands
/// events a `wd`; this reconstructs each root's relative dir so
/// `join(subpath, name)` yields the event's path.
wds: std.AutoHashMapUnmanaged(i32, std.ArrayList(Owner)) = .empty,

const Root = struct {
    /// Owned copy of the path as `add` got it; the base for the paths handed
    /// to `inotify_add_watch` and `open` when a recursive root grows.
    path: []u8,
    recursive: bool,
};

const Owner = struct {
    root: watch.RootId,
    /// Relative to the root ("" is the root itself). Owned.
    sub: []u8,
};

/// Directory-level events we care about. `IN.ISDIR` rides along on the
/// mask when the subject is a directory (drives the recursive add).
/// `CLOSE_WRITE`, not `MODIFY`: one event when a writer finishes, not one per
/// `write(2)` — a log appended to all day must not read as a storm. `ATTRIB`:
/// a mode (or owner, or link count) changed. The `_SELF` pair reports the
/// watched directory itself leaving; only a root's own descriptor reports
/// them (a subdirectory's departure is its parent's DELETE/MOVED_FROM).
const mask: u32 = linux.IN.CREATE | linux.IN.CLOSE_WRITE | linux.IN.ATTRIB | linux.IN.DELETE |
    linux.IN.MOVED_TO | linux.IN.MOVED_FROM | linux.IN.DELETE_SELF | linux.IN.MOVE_SELF;

pub fn init(gpa: Allocator) watch.Error!Inotify {
    _ = gpa;
    const rc = linux.inotify_init1(linux.IN.NONBLOCK | linux.IN.CLOEXEC);
    if (linux.errno(rc) != .SUCCESS) return error.WatchInit;
    return .{ .fd = @intCast(rc) };
}

pub fn deinit(self: *Inotify, gpa: Allocator) void {
    var it = self.wds.valueIterator();
    while (it.next()) |owners| freeOwners(gpa, owners);
    self.wds.deinit(gpa);
    var roots = self.roots.valueIterator();
    while (roots.next()) |root| gpa.free(root.path);
    self.roots.deinit(gpa);
    _ = linux.close(self.fd);
    self.* = undefined;
}

fn freeOwners(gpa: Allocator, owners: *std.ArrayList(Owner)) void {
    for (owners.items) |o| gpa.free(o.sub);
    owners.deinit(gpa);
}

pub fn wakeFd(self: *Inotify) watch.Error!i32 {
    return self.fd;
}

pub fn add(self: *Inotify, gpa: Allocator, root_path: []const u8, options: watch.Options) watch.Error!watch.RootId {
    const id = self.next_root;
    const path = try gpa.dupe(u8, root_path);
    self.roots.put(gpa, id, .{ .path = path, .recursive = options.recursive }) catch |err| {
        gpa.free(path);
        return err;
    };
    self.next_root += 1;
    errdefer self.remove(gpa, id);
    // The root itself must take: a root nobody can watch is the caller's
    // error, unlike a subdirectory that vanished mid-walk.
    if (!try self.addWatch(gpa, id, "")) return error.WatchInit;
    if (options.recursive) try self.addChildren(gpa, id, "");
    return id;
}

pub fn remove(self: *Inotify, gpa: Allocator, root: watch.RootId) void {
    const kv = self.roots.fetchRemove(root) orelse return;
    gpa.free(kv.value.path);
    // Find-then-drop, one wd at a time: the map is never mutated while it
    // is being iterated.
    while (true) {
        var it = self.wds.iterator();
        const victim: i32 = find: while (it.next()) |entry| {
            for (entry.value_ptr.items) |o| if (o.root == root) break :find entry.key_ptr.*;
        } else break;
        const owners = self.wds.getPtr(victim).?;
        var i: usize = 0;
        while (i < owners.items.len) {
            if (owners.items[i].root != root) {
                i += 1;
                continue;
            }
            gpa.free(owners.swapRemove(i).sub);
        }
        if (owners.items.len == 0) {
            owners.deinit(gpa);
            _ = self.wds.remove(victim);
            // The kernel answers with IN_IGNORED for this wd; `drain` finds
            // no owner for it and drops it.
            _ = linux.inotify_rm_watch(self.fd, victim);
        }
    }
}

/// Read every currently-available inotify event (non-blocking; stops at
/// EAGAIN), translate each `wd`+name to a path under each owning root, add a
/// watch for any new directory under a recursive root, and hand each event
/// to `sink`.
pub fn drain(self: *Inotify, gpa: Allocator, sink: watch.Sink) watch.Error!void {
    // inotify events are naturally aligned within the read buffer; keep
    // the buffer aligned so the fixed header casts cleanly.
    var buf: [8192]u8 align(@alignOf(linux.inotify_event)) = undefined;
    while (true) {
        const n = linux.read(self.fd, &buf, buf.len);
        switch (linux.errno(n)) {
            .SUCCESS => {},
            .AGAIN => return, // EWOULDBLOCK — nothing left this tick
            .INTR => continue,
            else => return error.ReadFailed,
        }
        if (n == 0) return;

        var off: usize = 0;
        while (off < n) {
            const ev: *align(1) const linux.inotify_event = @ptrCast(&buf[off]);
            const wd = ev.wd;
            const emask = ev.mask;
            const namelen = ev.len;
            // The name is a null-padded string of `len` bytes after the
            // fixed header; sliceTo trims the padding.
            const name: []const u8 = if (namelen == 0) "" else blk: {
                const nptr: [*]const u8 = @ptrCast(&buf[off + @sizeOf(linux.inotify_event)]);
                break :blk std.mem.sliceTo(nptr[0..namelen], 0);
            };
            off += @sizeOf(linux.inotify_event) + namelen;

            // The queue overflowed: events were lost, for any root.
            if (emask & linux.IN.Q_OVERFLOW != 0) {
                var roots = self.roots.keyIterator();
                while (roots.next()) |root| sink.call(sink.ctx, .{ .root = root.*, .kind = .overflow, .path = "" });
                continue;
            }
            // The watch was removed (auto on delete of the watched dir, or
            // by `remove`): drop our mapping and move on.
            if (emask & linux.IN.IGNORED != 0) {
                if (self.wds.fetchRemove(wd)) |kv| {
                    var owners = kv.value;
                    freeOwners(gpa, &owners);
                }
                continue;
            }
            try self.deliver(gpa, sink, wd, emask, name);
        }
    }
}

/// One event, to every root watching `wd`. Owners are walked BY INDEX,
/// re-fetched each step: a recursive add below grows `wds` (and may move the
/// list this wd maps to).
fn deliver(self: *Inotify, gpa: Allocator, sink: watch.Sink, wd: i32, emask: u32, name: []const u8) watch.Error!void {
    const self_event = emask & (linux.IN.DELETE_SELF | linux.IN.MOVE_SELF) != 0;
    const kind: watch.Kind =
        if (emask & (linux.IN.MOVED_TO | linux.IN.MOVED_FROM | linux.IN.MOVE_SELF) != 0)
            .moved
        else if (emask & linux.IN.CREATE != 0)
            .create
        else if (emask & (linux.IN.CLOSE_WRITE | linux.IN.ATTRIB) != 0)
            .modify
        else if (emask & (linux.IN.DELETE | linux.IN.DELETE_SELF) != 0)
            .delete
        else
            return;
    var i: usize = 0;
    while (true) : (i += 1) {
        const owners = self.wds.getPtr(wd) orelse return;
        if (i >= owners.items.len) return;
        const owner = owners.items[i];
        // A directory leaving is news to the root it IS; below a root, its
        // parent already reported the delete or move by name.
        if (self_event and owner.sub.len != 0) continue;
        const root = self.roots.get(owner.root) orelse continue;

        // Reconstruct the root-relative path. Allocate only when we must
        // actually join a non-empty dir and name.
        var joined: ?[]u8 = null;
        defer if (joined) |j| gpa.free(j);
        const rel: []const u8 = if (name.len == 0)
            owner.sub
        else if (owner.sub.len == 0)
            name
        else blk: {
            joined = try std.fs.path.join(gpa, &.{ owner.sub, name });
            break :blk joined.?;
        };

        // A new subdirectory (created or moved in) under a recursive root:
        // extend the watch so its future contents are seen too. Best
        // effort — a dir that vanished before we could open it is not an
        // error.
        if (root.recursive and emask & linux.IN.ISDIR != 0 and
            emask & (linux.IN.CREATE | linux.IN.MOVED_TO) != 0)
        {
            self.addTree(gpa, owner.root, rel) catch {};
        }

        sink.call(sink.ctx, .{ .root = owner.root, .kind = kind, .path = rel });
    }
}

pub fn watchCount(self: *const Inotify) usize {
    return self.wds.count();
}

// ── recursive watch setup ───────────────────────────────────────────

fn addTree(self: *Inotify, gpa: Allocator, root: watch.RootId, subpath: []const u8) watch.Error!void {
    if (!try self.addWatch(gpa, root, subpath)) return;
    try self.addChildren(gpa, root, subpath);
}

/// Watch every directory below `subpath` (which is watched already).
fn addChildren(self: *Inotify, gpa: Allocator, root: watch.RootId, subpath: []const u8) watch.Error!void {
    const base = (self.roots.get(root) orelse return).path;
    const pz = try watch.fullPathZ(gpa, base, subpath);
    defer gpa.free(pz);
    const dfd = openDir(pz) orelse return; // vanished / not a dir: fine
    defer _ = linux.close(dfd);

    var dbuf: [4096]u8 align(@alignOf(linux.dirent64)) = undefined;
    while (true) {
        const n = linux.getdents64(dfd, &dbuf, dbuf.len);
        if (linux.errno(n) != .SUCCESS or n == 0) break;
        var off: usize = 0;
        while (off < n) {
            const d: *align(1) const linux.dirent64 = @ptrCast(&dbuf[off]);
            const name_z: [*:0]const u8 = @ptrCast(&dbuf[off + @offsetOf(linux.dirent64, "name")]);
            const name = std.mem.span(name_z);
            const dtype = d.type;
            off += d.reclen;

            if (dtype != linux.DT.DIR) continue;
            if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;

            const child = try watch.childPath(gpa, subpath, name);
            defer gpa.free(child);
            try self.addTree(gpa, root, child);
        }
    }
}

/// Watch directory `subpath` of `root`. False when the kernel refused (the
/// directory is gone, or this user is out of watches).
fn addWatch(self: *Inotify, gpa: Allocator, root: watch.RootId, subpath: []const u8) watch.Error!bool {
    const base = (self.roots.get(root) orelse return false).path;
    const pz = try watch.fullPathZ(gpa, base, subpath);
    defer gpa.free(pz);
    const rc = linux.inotify_add_watch(self.fd, pz.ptr, mask);
    if (linux.errno(rc) != .SUCCESS) return false;
    const wd: i32 = @intCast(rc);
    // Re-adding a watched inode returns the same wd; one owner per
    // (root, subpath).
    const gop = try self.wds.getOrPut(gpa, wd);
    if (!gop.found_existing) gop.value_ptr.* = .empty;
    for (gop.value_ptr.items) |o| if (o.root == root and std.mem.eql(u8, o.sub, subpath)) return true;
    errdefer if (gop.value_ptr.items.len == 0) {
        // No owner to show for the kernel's watch: give it back.
        gop.value_ptr.deinit(gpa);
        _ = self.wds.remove(wd);
        _ = linux.inotify_rm_watch(self.fd, wd);
    };
    const sub = try gpa.dupe(u8, subpath);
    gop.value_ptr.append(gpa, .{ .root = root, .sub = sub }) catch |err| {
        gpa.free(sub);
        return err;
    };
    return true;
}

fn openDir(path_z: [*:0]const u8) ?i32 {
    const rc = linux.open(path_z, .{
        .ACCMODE = .RDONLY,
        .DIRECTORY = true,
        .CLOEXEC = true,
        .NONBLOCK = true,
    }, 0);
    if (linux.errno(rc) != .SUCCESS) return null;
    return @intCast(rc);
}
