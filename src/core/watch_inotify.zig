//! The Linux backend of `watch.zig`: raw inotify. One watch descriptor per
//! directory; the kernel names each event's entry, so `drain` only has to
//! map `wd` back to a root-relative directory. The inotify fd is
//! `IN_NONBLOCK`, and `drain` reads it to EAGAIN and returns.

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
/// Owned copy of the root path (as handed to `init`); used to build the
/// filesystem paths passed to `inotify_add_watch` and `open`.
root: []u8,
/// watch-descriptor → subpath relative to root ("" is the root itself).
/// The kernel hands events a `wd`; this reconstructs the relative dir so
/// `join(dir, name)` yields the event's path.
wds: std.AutoHashMapUnmanaged(i32, []u8),

/// Directory-level events we care about. `IN.ISDIR` rides along on the
/// mask when the subject is a directory (drives the recursive add).
const mask: u32 = linux.IN.CREATE | linux.IN.MODIFY | linux.IN.DELETE |
    linux.IN.MOVED_TO | linux.IN.MOVED_FROM;

pub fn init(gpa: Allocator, root_path: []const u8) watch.Error!Inotify {
    const rc = linux.inotify_init1(linux.IN.NONBLOCK | linux.IN.CLOEXEC);
    if (linux.errno(rc) != .SUCCESS) return error.WatchInit;
    const fd: i32 = @intCast(rc);
    errdefer _ = linux.close(fd);

    var self: Inotify = .{
        .fd = fd,
        .root = try gpa.dupe(u8, root_path),
        .wds = .empty,
    };
    errdefer gpa.free(self.root);
    errdefer self.freeMap(gpa);

    try self.addTree(gpa, "");
    return self;
}

pub fn deinit(self: *Inotify, gpa: Allocator) void {
    self.freeMap(gpa);
    gpa.free(self.root);
    _ = linux.close(self.fd);
    self.* = undefined;
}

fn freeMap(self: *Inotify, gpa: Allocator) void {
    var it = self.wds.valueIterator();
    while (it.next()) |v| gpa.free(v.*);
    self.wds.deinit(gpa);
}

/// Read every currently-available inotify event (non-blocking; stops at
/// EAGAIN), translate each `wd`+name to a root-relative path, add a
/// recursive watch for any new directory, and hand each event to `sink`.
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

            // The watch was removed (auto on delete of the watched dir):
            // drop our mapping and move on.
            if (emask & linux.IN.IGNORED != 0) {
                if (self.wds.fetchRemove(wd)) |kv| gpa.free(kv.value);
                continue;
            }

            const dir_sub = self.wds.get(wd) orelse continue;

            // Reconstruct the root-relative path. Allocate only when we
            // must actually join a non-empty dir and name.
            var joined: ?[]u8 = null;
            defer if (joined) |j| gpa.free(j);
            const rel: []const u8 = if (name.len == 0)
                dir_sub
            else if (dir_sub.len == 0)
                name
            else blk: {
                joined = try std.fs.path.join(gpa, &.{ dir_sub, name });
                break :blk joined.?;
            };

            const kind: watch.Kind =
                if (emask & (linux.IN.MOVED_TO | linux.IN.MOVED_FROM) != 0)
                    .moved
                else if (emask & linux.IN.CREATE != 0)
                    .create
                else if (emask & linux.IN.MODIFY != 0)
                    .modify
                else if (emask & linux.IN.DELETE != 0)
                    .delete
                else
                    continue;

            // A new subdirectory (created or moved in): extend the watch
            // recursively so its future contents are seen too. Best
            // effort — a dir that vanished before we could open it is not
            // an error.
            if (emask & linux.IN.ISDIR != 0 and
                emask & (linux.IN.CREATE | linux.IN.MOVED_TO) != 0)
            {
                self.addTree(gpa, rel) catch {};
            }

            sink.call(sink.ctx, .{ .kind = kind, .path = rel });
        }
    }
}

pub fn watchCount(self: *const Inotify) usize {
    return self.wds.count();
}

// ── recursive watch setup ───────────────────────────────────────────

fn addTree(self: *Inotify, gpa: Allocator, subpath: []const u8) watch.Error!void {
    try self.addWatch(gpa, subpath);

    const pz = try watch.fullPathZ(gpa, self.root, subpath);
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
            try self.addTree(gpa, child);
        }
    }
}

fn addWatch(self: *Inotify, gpa: Allocator, subpath: []const u8) watch.Error!void {
    const pz = try watch.fullPathZ(gpa, self.root, subpath);
    defer gpa.free(pz);
    const rc = linux.inotify_add_watch(self.fd, pz.ptr, mask);
    if (linux.errno(rc) != .SUCCESS) return; // dir gone: skip, not fatal
    const wd: i32 = @intCast(rc);
    // Re-adding an existing path returns the same wd; keep one owned copy.
    const gop = try self.wds.getOrPut(gpa, wd);
    if (!gop.found_existing) gop.value_ptr.* = try gpa.dupe(u8, subpath);
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
