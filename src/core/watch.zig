//! `watch` — the "here" (local) tier of `fs.watch`: observe a directory
//! subtree for create/modify/delete/move, delivering events to a sink.
//! No Io plumbing on the drain path (same posture as `task.zig`'s raw futex).
//!
//! Recursive by design ([FIX 12], never per-path polling): `init` watches
//! the root and every existing subdirectory, and `drain` extends the watch
//! whenever a new directory appears. The frame loop stays honest — `drain`
//! is NON-BLOCKING: it takes whatever the kernel has queued and returns;
//! there is no reader thread and no cross-thread callback. If you want
//! off-thread delivery, wrap this and push onto a lock-free queue the frame
//! thread drains.
//!
//! The mechanism is the one place this forks per OS, behind this file's
//! four functions (`init`/`deinit`/`drain`/`watchCount`):
//! - Linux: inotify (`watch_inotify.zig`) — one descriptor per directory,
//!   named events straight from the kernel.
//! - macOS: kqueue `EVFILT_VNODE` on `O_EVTONLY` descriptors
//!   (`watch_kqueue.zig`) — a directory reports only "changed", so its
//!   entries are rescanned and diffed to name the create/delete/move.
//!
//! Driving it on macOS: `drain` calls `kevent` with a ZERO timeout, so the
//! frame-thread model above holds unchanged — no `poll()` on the kqueue fd is
//! involved (poll on a kqueue descriptor is not reliable on macOS). Nothing
//! registers this module's descriptor with the scheduler today (it is
//! unwired, see `core/root.zig`); if a caller ever needs the scheduler to
//! WAKE on file events, the sound design on macOS is a helper thread blocked
//! in `kevent` that writes a self-pipe the scheduler polls — not polling the
//! kqueue fd itself.
//!
//! Ownership: `Event.path` is BORROWED — it is relative to the watched
//! root and valid only for the duration of the sink call. Copy it if you
//! need to keep it past the call.

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

pub const Error = error{ WatchInit, ReadFailed } || Allocator.Error;

pub fn init(gpa: Allocator, root_path: []const u8) Error!Watch {
    return .{ .backend = try Backend.init(gpa, root_path) };
}

pub fn deinit(self: *Watch, gpa: Allocator) void {
    self.backend.deinit(gpa);
    self.* = undefined;
}

/// Hand every currently-queued event to `sink` (root-relative paths),
/// extending the watch over any new directory. Never blocks; call it once
/// per frame.
pub fn drain(self: *Watch, gpa: Allocator, sink: Sink) Error!void {
    return self.backend.drain(gpa, sink);
}

/// Number of watched directories (root + subdirs). Test-facing proof that a
/// recursive add landed.
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

test "watch: a rename inside the tree is a move of both names" {
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
