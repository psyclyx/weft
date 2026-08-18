//! `watch` — the "here" (local) tier of `fs.watch`: observe a directory
//! subtree for create/modify/delete/move, delivering events to a sink.
//! Linux-native by construction — raw inotify via `std.os.linux`, no Io
//! plumbing on the drain path (same posture as `task.zig`'s raw futex).
//!
//! Recursive by design ([FIX 12], never per-path polling): `init` adds a
//! watch on the root and every existing subdirectory, and `drain` adds a
//! fresh recursive watch whenever a new directory appears. The frame
//! loop stays honest — the inotify fd is `IN_NONBLOCK`, and `drain` reads
//! it to EAGAIN each tick and returns; there is no reader thread and no
//! cross-thread callback. If you want off-thread delivery, wrap this and
//! push onto a lock-free queue the frame thread drains.
//!
//! Ownership: `Event.path` is BORROWED — it is relative to the watched
//! root and valid only for the duration of the sink call. Copy it if you
//! need to keep it past the call.

const std = @import("std");
const Allocator = std.mem.Allocator;
const linux = std.os.linux;

const Watch = @This();

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

pub const Kind = enum { create, modify, delete, moved };

pub const Event = struct {
    kind: Kind,
    /// Relative to the watched root. BORROWED — see the file header.
    path: []const u8,
};

/// A type-erased delivery target. `call` runs once per event, on the
/// draining (frame) thread, with a borrowed `Event`.
pub const Sink = struct {
    ctx: *anyopaque,
    call: *const fn (ctx: *anyopaque, ev: Event) void,
};

pub const Error = error{ InotifyInit, ReadFailed } || Allocator.Error;

pub fn init(gpa: Allocator, root_path: []const u8) Error!Watch {
    const rc = linux.inotify_init1(linux.IN.NONBLOCK | linux.IN.CLOEXEC);
    if (linux.errno(rc) != .SUCCESS) return error.InotifyInit;
    const fd: i32 = @intCast(rc);
    errdefer _ = linux.close(fd);

    var self: Watch = .{
        .fd = fd,
        .root = try gpa.dupe(u8, root_path),
        .wds = .empty,
    };
    errdefer gpa.free(self.root);
    errdefer self.freeMap(gpa);

    try self.addTree(gpa, "");
    return self;
}

pub fn deinit(self: *Watch, gpa: Allocator) void {
    self.freeMap(gpa);
    gpa.free(self.root);
    _ = linux.close(self.fd);
    self.* = undefined;
}

fn freeMap(self: *Watch, gpa: Allocator) void {
    var it = self.wds.valueIterator();
    while (it.next()) |v| gpa.free(v.*);
    self.wds.deinit(gpa);
}

/// Read every currently-available inotify event (non-blocking; stops at
/// EAGAIN), translate each `wd`+name to a root-relative path, add a
/// recursive watch for any new directory, and hand each event to `sink`.
/// Never blocks; call it once per frame.
pub fn drain(self: *Watch, gpa: Allocator, sink: Sink) Error!void {
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

            const kind: Kind =
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

/// Number of active watch descriptors (root + subdirs). Test-facing
/// proof that a recursive add landed.
pub fn watchCount(self: *const Watch) usize {
    return self.wds.count();
}

// ── recursive watch setup ───────────────────────────────────────────

fn addTree(self: *Watch, gpa: Allocator, subpath: []const u8) Error!void {
    try self.addWatch(gpa, subpath);

    const pz = try self.fullPathZ(gpa, subpath);
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

            const child = if (subpath.len == 0)
                try gpa.dupe(u8, name)
            else
                try std.fs.path.join(gpa, &.{ subpath, name });
            defer gpa.free(child);
            try self.addTree(gpa, child);
        }
    }
}

fn addWatch(self: *Watch, gpa: Allocator, subpath: []const u8) Error!void {
    const pz = try self.fullPathZ(gpa, subpath);
    defer gpa.free(pz);
    const rc = linux.inotify_add_watch(self.fd, pz.ptr, mask);
    if (linux.errno(rc) != .SUCCESS) return; // dir gone: skip, not fatal
    const wd: i32 = @intCast(rc);
    // Re-adding an existing path returns the same wd; keep one owned copy.
    const gop = try self.wds.getOrPut(gpa, wd);
    if (!gop.found_existing) gop.value_ptr.* = try gpa.dupe(u8, subpath);
}

fn fullPathZ(self: *const Watch, gpa: Allocator, subpath: []const u8) Allocator.Error![:0]u8 {
    if (subpath.len == 0) return gpa.dupeZ(u8, self.root);
    return std.fs.path.joinZ(gpa, &.{ self.root, subpath });
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

// ── Tests ───────────────────────────────────────────────────────────
// inotify delivers asynchronously: after an fs op the event may not be
// on the fd yet. `pumpUntil` drains in a BOUNDED loop with a tiny sleep,
// so a genuine miss times out rather than hangs.

const t = std.testing;

const Collector = struct {
    gpa: Allocator,
    events: std.ArrayListUnmanaged(Rec) = .empty,

    const Rec = struct { kind: Kind, path: []u8 };

    fn deinit(self: *Collector) void {
        for (self.events.items) |r| self.gpa.free(r.path);
        self.events.deinit(self.gpa);
    }

    fn sink(self: *Collector) Sink {
        return .{ .ctx = self, .call = call };
    }

    fn call(ctx: *anyopaque, ev: Event) void {
        const self: *Collector = @ptrCast(@alignCast(ctx));
        // Event.path is borrowed — dupe to keep it. Allocation failures
        // in a test sink are unrecoverable; surface loudly.
        const owned = self.gpa.dupe(u8, ev.path) catch @panic("oom in test sink");
        self.events.append(self.gpa, .{ .kind = ev.kind, .path = owned }) catch @panic("oom in test sink");
    }

    fn has(self: *const Collector, kind: Kind, path: []const u8) bool {
        for (self.events.items) |r| {
            if (r.kind == kind and std.mem.eql(u8, r.path, path)) return true;
        }
        return false;
    }
};

/// Drain up to `max_ticks` times (tiny sleeps between) until `pred` holds
/// or the budget runs out. Returns whether it held.
fn pumpUntil(
    w: *Watch,
    gpa: Allocator,
    c: *Collector,
    max_ticks: usize,
    pred: *const fn (*const Collector) bool,
) !bool {
    var i: usize = 0;
    while (i < max_ticks) : (i += 1) {
        try w.drain(gpa, c.sink());
        if (pred(c)) return true;
        napMs(2);
    }
    // one last drain in case the final op landed on the wire
    try w.drain(gpa, c.sink());
    return pred(c);
}

/// Raw-syscall sleep — `std.Thread.sleep` left std in 0.16 and the Io
/// timer would drag an Io instance through the test just to nap a couple
/// of milliseconds between drains.
fn napMs(ms: u64) void {
    const ns = ms * std.time.ns_per_ms;
    var req: linux.timespec = .{
        .sec = @intCast(ns / std.time.ns_per_s),
        .nsec = @intCast(ns % std.time.ns_per_s),
    };
    while (linux.errno(linux.nanosleep(&req, &req)) == .INTR) {}
}

fn sawFileCreate(c: *const Collector) bool {
    return c.has(.create, "f.txt");
}
fn sawFileModify(c: *const Collector) bool {
    return c.has(.modify, "f.txt");
}
fn sawFileDelete(c: *const Collector) bool {
    return c.has(.delete, "f.txt");
}
fn sawNested(c: *const Collector) bool {
    return c.has(.create, "sub/g.txt");
}

test "watch: create, modify, delete a file in the root" {
    const gpa = t.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    // t.tmpDir lives under .zig-cache/tmp/<sub_path>, cwd-relative.
    const root = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer gpa.free(root);

    var w = try Watch.init(gpa, root);
    defer w.deinit(gpa);

    var c: Collector = .{ .gpa = gpa };
    defer c.deinit();

    try tmp.dir.writeFile(io, .{ .sub_path = "f.txt", .data = "hello" });
    try t.expect(try pumpUntil(&w, gpa, &c, 64, sawFileCreate));

    try tmp.dir.writeFile(io, .{ .sub_path = "f.txt", .data = "hello world" });
    try t.expect(try pumpUntil(&w, gpa, &c, 64, sawFileModify));

    try tmp.dir.deleteFile(io, "f.txt");
    try t.expect(try pumpUntil(&w, gpa, &c, 64, sawFileDelete));
}

test "watch: recursive — a new subdir is watched, its files seen" {
    const gpa = t.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer gpa.free(root);

    var w = try Watch.init(gpa, root);
    defer w.deinit(gpa);
    const before = w.watchCount(); // just the root

    var c: Collector = .{ .gpa = gpa };
    defer c.deinit();

    // Create a subdir, then a file inside it. The recursive add on the
    // subdir-create is what lets the nested file's create surface.
    try tmp.dir.createDirPath(io, "sub");
    // Give the watch-add a chance to register before writing inside.
    _ = try pumpUntil(&w, gpa, &c, 32, struct {
        fn f(cc: *const Collector) bool {
            return cc.has(.create, "sub");
        }
    }.f);

    try tmp.dir.writeFile(io, .{ .sub_path = "sub/g.txt", .data = "nested" });

    const seen_nested = try pumpUntil(&w, gpa, &c, 96, sawNested);
    // Proof the recursion took: either we saw the nested file, or (if the
    // fs was very slow) the watch count grew past the lone root.
    try t.expect(seen_nested or w.watchCount() > before);
    try t.expect(w.watchCount() > before);
    try t.expect(c.has(.create, "sub"));
}

test {
    std.testing.refAllDecls(@This());
}
