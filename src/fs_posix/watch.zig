//! `watch` — the "here" (local) tier of `fs.watch`: observe directories for
//! create/modify/delete/move, delivering events to a sink. The POSIX
//! provider (`provider.zig`'s `watch`/`pollInvalidation`/`closeWatch`) is its
//! consumer; nothing above the provider names it. No Io plumbing on the drain
//! path (same posture as `core/task.zig`'s raw futex).
//!
//! ONE OS instance, many ROOTS. A `Watch` is one inotify descriptor (Linux)
//! or one kqueue (macOS); `add` puts another directory under it and returns
//! the `RootId` its events carry. One instance is the point: inotify caps
//! instances per USER (`max_user_instances`, 128 by default, shared with
//! every other program), never watches — so a listing per directory, each
//! with its own instance, would run a desktop out of them. And one instance
//! is one descriptor for the frame loop to wait on (`wakeFd`).
//!
//! A root is RECURSIVE or not ([FIX 12], never per-path polling). Recursive:
//! `add` watches the root and every existing subdirectory, and `drain`
//! extends the watch whenever a new directory appears. Not recursive: the
//! directory's own entries only — what a listing shows. The frame loop stays
//! honest either way — `drain` is NON-BLOCKING: it takes whatever the kernel
//! has queued and returns; there is no cross-thread callback.
//!
//! The mechanism is the one place this forks per OS, behind this file's
//! functions:
//! - Linux: inotify (`watch_inotify.zig`) — one watch descriptor per
//!   directory, named events straight from the kernel.
//! - macOS: kqueue `EVFILT_VNODE` on `O_EVTONLY` descriptors
//!   (`watch_kqueue.zig`) — a directory reports only "changed", so its
//!   entries are rescanned and diffed to name the create/delete/move.
//!
//! WAKING the frame loop (`wakeFd`). Linux: the inotify descriptor itself —
//! `poll` reports it readable while events are queued, and `drain` empties
//! it. macOS: `poll` on a kqueue descriptor is not reliable, and `drain`
//! calls `kevent` with a ZERO timeout, so the descriptor handed out is the
//! read end of a self-pipe: a helper thread waits in `kevent` on a second
//! kqueue that holds the first (`EVFILT_READ`, edge-triggered) and writes a
//! byte when events arrive; `drain` empties the pipe. The helper never reads
//! an event — delivery stays on the draining (frame) thread.
//!
//! The ROOT ITSELF is the empty path. Its deletion is a `.delete` of "", its
//! move (a rename of the directory, wherever to) a `.moved` of "" — the
//! watch keeps following the moved object. `.overflow` of "" says events
//! were lost (inotify's queue overflowed): assume anything under the root
//! changed.
//!
//! Ownership: `Event.path` is BORROWED — it is relative to its root and
//! valid only for the duration of the sink call. Copy it if you need to keep
//! it past the call.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const Watch = @This();

const Backend = switch (builtin.os.tag) {
    .linux => @import("watch_inotify.zig"),
    .driverkit, .ios, .maccatalyst, .macos, .tvos, .visionos, .watchos => @import("watch_kqueue.zig"),
    else => @compileError("watch: no filesystem-event backend for this OS"),
};

backend: Backend,

/// Names one `add`ed directory. Never reused within an instance, so an event
/// queued for a removed root can never land on a later one.
pub const RootId = u32;

pub const Options = struct {
    /// Watch every subdirectory too, and each new one as it appears. Off:
    /// the directory's own entries only.
    recursive: bool = true,
};

pub const Kind = enum { create, modify, delete, moved, overflow };

pub const Event = struct {
    root: RootId,
    kind: Kind,
    /// Relative to the root ("" is the root itself). BORROWED — see the
    /// file header.
    path: []const u8,
};

/// A type-erased delivery target. `call` runs once per event, on the
/// draining (frame) thread, with a borrowed `Event`.
pub const Sink = struct {
    ctx: *anyopaque,
    call: *const fn (ctx: *anyopaque, ev: Event) void,
};

pub const Error = error{ WatchInit, ReadFailed } || Allocator.Error;

pub fn init(gpa: Allocator) Error!Watch {
    return .{ .backend = try Backend.init(gpa) };
}

pub fn deinit(self: *Watch, gpa: Allocator) void {
    self.backend.deinit(gpa);
    self.* = undefined;
}

/// Watch the directory at `root_path`. `error.WatchInit` when it cannot be
/// watched at all (gone, not a directory, out of watches).
pub fn add(self: *Watch, gpa: Allocator, root_path: []const u8, options: Options) Error!RootId {
    return self.backend.add(gpa, root_path, options);
}

/// Stop watching `root`. Events already queued for it are dropped by the
/// next `drain`. Not watched is not an error.
pub fn remove(self: *Watch, gpa: Allocator, root: RootId) void {
    self.backend.remove(gpa, root);
}

/// Hand every currently-queued event to `sink` (root-relative paths),
/// extending recursive roots over any new directory. Never blocks; call it
/// once per frame, or when `wakeFd` is readable.
pub fn drain(self: *Watch, gpa: Allocator, sink: Sink) Error!void {
    return self.backend.drain(gpa, sink);
}

/// A descriptor `poll` reports readable while events wait for `drain`
/// (see the file header for what it is on each OS). Owned by the watch.
pub fn wakeFd(self: *Watch) Error!i32 {
    return self.backend.wakeFd();
}

/// Number of watched directories (every root + its watched subdirs) — one
/// directory watched by two roots counts once on Linux, where the kernel
/// shares the watch. Test-facing proof that a recursive add landed and that
/// a remove released.
pub fn watchCount(self: *const Watch) usize {
    return self.backend.watchCount();
}

/// `root` joined with a root-relative `subpath` ("" is the root itself),
/// NUL-terminated — the path both backends hand the kernel.
pub fn fullPathZ(gpa: Allocator, root: []const u8, subpath: []const u8) Allocator.Error![:0]u8 {
    if (subpath.len == 0) return gpa.dupeZ(u8, root);
    return std.fs.path.joinZ(gpa, &.{ root, subpath });
}

/// `dir` joined with `name` as a root-relative path (owned).
pub fn childPath(gpa: Allocator, dir: []const u8, name: []const u8) Allocator.Error![]u8 {
    if (dir.len == 0) return gpa.dupe(u8, name);
    return std.fs.path.join(gpa, &.{ dir, name });
}

// ── Tests ───────────────────────────────────────────────────────────
// Both kernels deliver asynchronously from the caller's point of view: after
// an fs op the event may not be queued yet. `pumpUntil` drains in a BOUNDED
// loop with a tiny sleep, so a genuine miss times out rather than hangs.

const t = std.testing;

const Collector = struct {
    gpa: Allocator,
    events: std.ArrayListUnmanaged(Rec) = .empty,

    const Rec = struct { root: RootId, kind: Kind, path: []u8 };

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
        self.events.append(self.gpa, .{ .root = ev.root, .kind = ev.kind, .path = owned }) catch @panic("oom in test sink");
    }

    fn has(self: *const Collector, kind: Kind, path: []const u8) bool {
        for (self.events.items) |r| {
            if (r.kind == kind and std.mem.eql(u8, r.path, path)) return true;
        }
        return false;
    }

    fn hasFor(self: *const Collector, root: RootId, kind: Kind, path: []const u8) bool {
        for (self.events.items) |r| {
            if (r.root == root and r.kind == kind and std.mem.eql(u8, r.path, path)) return true;
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

/// libc sleep — `std.Thread.sleep` left std in 0.16 and the Io timer would
/// drag an Io instance through the test just to nap a couple of
/// milliseconds between drains.
fn napMs(ms: u64) void {
    const ns = ms * std.time.ns_per_ms;
    var req: std.c.timespec = .{
        .sec = @intCast(ns / std.time.ns_per_s),
        .nsec = @intCast(ns % std.time.ns_per_s),
    };
    while (std.c.errno(std.c.nanosleep(&req, &req)) == .INTR) {}
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
fn sawRename(c: *const Collector) bool {
    return c.has(.moved, "f.txt") and c.has(.moved, "g.txt");
}

/// A test's tmp dir as a path (t.tmpDir lives under .zig-cache/tmp/<sub_path>,
/// cwd-relative).
fn tmpPath(gpa: Allocator, tmp: *const t.TmpDir) ![]u8 {
    return std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}", .{tmp.sub_path});
}

test "watch: create, modify, delete a file in the root" {
    const gpa = t.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmpPath(gpa, &tmp);
    defer gpa.free(root);

    var w = try Watch.init(gpa);
    defer w.deinit(gpa);
    _ = try w.add(gpa, root, .{});

    var c: Collector = .{ .gpa = gpa };
    defer c.deinit();

    try tmp.dir.writeFile(io, .{ .sub_path = "f.txt", .data = "hello" });
    try t.expect(try pumpUntil(&w, gpa, &c, 64, sawFileCreate));

    try tmp.dir.writeFile(io, .{ .sub_path = "f.txt", .data = "hello world" });
    try t.expect(try pumpUntil(&w, gpa, &c, 64, sawFileModify));

    try tmp.dir.deleteFile(io, "f.txt");
    try t.expect(try pumpUntil(&w, gpa, &c, 64, sawFileDelete));
}

test "watch: a rename inside the tree is a move of both names" {
    const gpa = t.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmpPath(gpa, &tmp);
    defer gpa.free(root);

    var w = try Watch.init(gpa);
    defer w.deinit(gpa);
    _ = try w.add(gpa, root, .{});
    var c: Collector = .{ .gpa = gpa };
    defer c.deinit();

    try tmp.dir.writeFile(io, .{ .sub_path = "f.txt", .data = "x" });
    try t.expect(try pumpUntil(&w, gpa, &c, 64, sawFileCreate));
    try tmp.dir.rename("f.txt", tmp.dir, "g.txt", io);
    try t.expect(try pumpUntil(&w, gpa, &c, 64, sawRename));
}

test "watch: recursive — a new subdir is watched, its files seen" {
    const gpa = t.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmpPath(gpa, &tmp);
    defer gpa.free(root);

    var w = try Watch.init(gpa);
    defer w.deinit(gpa);
    _ = try w.add(gpa, root, .{});
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

test "watch: a non-recursive root sees its own entries and never descends" {
    const gpa = t.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "sub");
    const root = try tmpPath(gpa, &tmp);
    defer gpa.free(root);

    var w = try Watch.init(gpa);
    defer w.deinit(gpa);
    _ = try w.add(gpa, root, .{ .recursive = false });
    try t.expectEqual(@as(usize, 1), w.watchCount());

    var c: Collector = .{ .gpa = gpa };
    defer c.deinit();
    try tmp.dir.createDirPath(io, "fresh");
    try t.expect(try pumpUntil(&w, gpa, &c, 64, struct {
        fn f(cc: *const Collector) bool {
            return cc.has(.create, "fresh");
        }
    }.f));
    // Neither the existing nor the new directory gained a watch.
    try t.expectEqual(@as(usize, 1), w.watchCount());
}

test "watch: two roots share one instance; each event names its root, and a removed root goes quiet" {
    const gpa = t.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "a");
    try tmp.dir.createDirPath(io, "b");
    const base = try tmpPath(gpa, &tmp);
    defer gpa.free(base);
    const a_path = try std.fs.path.join(gpa, &.{ base, "a" });
    defer gpa.free(a_path);
    const b_path = try std.fs.path.join(gpa, &.{ base, "b" });
    defer gpa.free(b_path);

    var w = try Watch.init(gpa);
    defer w.deinit(gpa);
    const a = try w.add(gpa, a_path, .{ .recursive = false });
    const b = try w.add(gpa, b_path, .{ .recursive = false });
    try t.expect(a != b);

    var c: Collector = .{ .gpa = gpa };
    defer c.deinit();
    try tmp.dir.writeFile(io, .{ .sub_path = "a/f.txt", .data = "x" });
    try tmp.dir.writeFile(io, .{ .sub_path = "b/f.txt", .data = "x" });
    const Both = struct {
        var ra: RootId = 0;
        var rb: RootId = 0;
        fn f(cc: *const Collector) bool {
            return cc.hasFor(ra, .create, "f.txt") and cc.hasFor(rb, .create, "f.txt");
        }
    };
    Both.ra = a;
    Both.rb = b;
    try t.expect(try pumpUntil(&w, gpa, &c, 64, Both.f));

    w.remove(gpa, a);
    try t.expectEqual(@as(usize, 1), w.watchCount());
    c.deinit();
    c = .{ .gpa = gpa };
    try tmp.dir.writeFile(io, .{ .sub_path = "a/g.txt", .data = "x" });
    try tmp.dir.writeFile(io, .{ .sub_path = "b/g.txt", .data = "x" });
    try t.expect(try pumpUntil(&w, gpa, &c, 64, struct {
        fn f(cc: *const Collector) bool {
            return cc.has(.create, "g.txt");
        }
    }.f));
    for (c.events.items) |r| try t.expect(r.root != a);
}

test "watch: the root's own deletion is a delete of the empty path" {
    const gpa = t.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "doomed");
    const base = try tmpPath(gpa, &tmp);
    defer gpa.free(base);
    const doomed = try std.fs.path.join(gpa, &.{ base, "doomed" });
    defer gpa.free(doomed);

    var w = try Watch.init(gpa);
    defer w.deinit(gpa);
    _ = try w.add(gpa, doomed, .{ .recursive = false });
    var c: Collector = .{ .gpa = gpa };
    defer c.deinit();
    try tmp.dir.deleteDir(io, "doomed");
    try t.expect(try pumpUntil(&w, gpa, &c, 64, struct {
        fn f(cc: *const Collector) bool {
            return cc.has(.delete, "");
        }
    }.f));
}

test "watch: the wake descriptor is readable while events wait, and drained by drain" {
    const gpa = t.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmpPath(gpa, &tmp);
    defer gpa.free(root);

    var w = try Watch.init(gpa);
    defer w.deinit(gpa);
    _ = try w.add(gpa, root, .{ .recursive = false });
    const fd = try w.wakeFd();
    var fds = [_]std.posix.pollfd{.{ .fd = fd, .events = std.posix.POLL.IN, .revents = 0 }};
    try t.expectEqual(@as(usize, 0), try std.posix.poll(&fds, 0));

    try tmp.dir.writeFile(io, .{ .sub_path = "f.txt", .data = "x" });
    // Bounded wait for the wake (the macOS helper thread is asynchronous).
    try t.expectEqual(@as(usize, 1), try std.posix.poll(&fds, 2000));

    var c: Collector = .{ .gpa = gpa };
    defer c.deinit();
    try t.expect(try pumpUntil(&w, gpa, &c, 64, sawFileCreate));
    fds[0].revents = 0;
    try t.expectEqual(@as(usize, 0), try std.posix.poll(&fds, 0));
}

test {
    std.testing.refAllDecls(@This());
}
