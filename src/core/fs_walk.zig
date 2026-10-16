//! A directory walk a plugin starts and reads as it goes (`wl_fs_walk`).
//!
//! The mechanism, not the policy: a worker walks `root` depth-first off the
//! frame thread and hands back every FILE's path, relative to `root`, as it
//! finds it; the frame loop is woken per batch and at the end. What to skip
//! is the caller's (`Options`): dot-entries, and directory names to prune
//! without entering (`node_modules`, `zig-cache`) — a file finder's taste,
//! not core's. A symlink is listed, never followed, so a walk stays under its
//! root. A walk is capped (`max_files`) and says so when it is cut.
//!
//! Ownership is a refcount, not a join: closing must not block (a pick closes
//! inside the input hot path), so `deinit` flips `cancel` and drops the
//! owner's reference; whichever of {worker, owner} lets go last frees it.

const std = @import("std");
const Allocator = std.mem.Allocator;
const task = @import("task.zig");

/// Files one walk hands back at most. Past it the walk stops and says it was
/// cut (`status` 1), rather than growing without bound on a runaway tree.
pub const max_files = 200_000;
/// Wake the loop after this many new paths (and at the end).
const wake_every = 256;

pub const Options = struct {
    /// Skip every entry whose name starts with a dot (`.git`, dotfiles).
    skip_hidden: bool = true,
    /// Directory names never entered.
    prune: []const []const u8 = &.{},
    /// Asked of every directory below the root, by its full path, before it
    /// is entered: true = not entered. The door passes the machinery
    /// carve-out here, so a walk never lists what no fs door may open.
    /// Called on the worker thread.
    refuse: ?*const fn (path: []const u8) bool = null,
};

pub const Walk = struct {
    gpa: Allocator,
    pool: *task.Pool,
    refs: std.atomic.Value(u32) = .init(2),
    cancel: std.atomic.Value(bool) = .init(false),
    done: std.atomic.Value(bool) = .init(false),
    cut: std.atomic.Value(bool) = .init(false),
    mutex: task.Mutex = .{},
    /// Paths found and not yet read, each ended by '\n'. Under `mutex`.
    out: std.ArrayList(u8) = .empty,
    root: []u8,
    skip_hidden: bool,
    /// Owned copies of `Options.prune`.
    prune: [][]u8,
    refuse: ?*const fn (path: []const u8) bool,
    /// Frame thread: the end has been taken, so it is no longer news.
    done_heard: bool = false,

    /// Start walking `root` (an absolute directory) on `pool`.
    pub fn start(gpa: Allocator, pool: *task.Pool, root: []const u8, opts: Options) !*Walk {
        const prune = try gpa.alloc([]u8, opts.prune.len);
        var made: usize = 0;
        errdefer {
            for (prune[0..made]) |n| gpa.free(n);
            gpa.free(prune);
        }
        for (opts.prune, prune) |name, *owned| {
            owned.* = try gpa.dupe(u8, name);
            made += 1;
        }
        const self = try gpa.create(Walk);
        errdefer gpa.destroy(self);
        self.* = .{ .gpa = gpa, .pool = pool, .root = try gpa.dupe(u8, root), .skip_hidden = opts.skip_hidden, .prune = prune, .refuse = opts.refuse };
        errdefer gpa.free(self.root);
        var h = try pool.spawn(work, .{self});
        h.detach();
        return self;
    }

    pub const Taken = union(enum) {
        /// This many bytes of whole paths were copied.
        bytes: usize,
        /// Nothing yet; the walk goes on.
        waiting,
        /// The walk is over and every path was taken; `cut`: at `max_files`.
        over: struct { cut: bool },
    };

    /// Frame thread: take the paths found since the last take, as many whole
    /// ones as fit in `buf` (which must hold one: `max_path_bytes`), or hear
    /// the end. The end is looked at BEFORE the read, so an end seen means
    /// every path was already queued — none can land between the two.
    pub fn take(self: *Walk, buf: []u8) Taken {
        const finished = self.done.load(.acquire);
        const n = self.read(buf);
        if (n > 0) return .{ .bytes = n };
        if (!finished) return .waiting;
        self.done_heard = true;
        return .{ .over = .{ .cut = self.cut.load(.acquire) } };
    }

    fn read(self: *Walk, buf: []u8) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        const avail = self.out.items;
        if (avail.len == 0) return 0;
        var n = @min(avail.len, buf.len);
        if (n < avail.len) n = (std.mem.lastIndexOfScalar(u8, avail[0..n], '\n') orelse return 0) + 1;
        @memcpy(buf[0..n], avail[0..n]);
        std.mem.copyForwards(u8, self.out.items[0 .. avail.len - n], avail[n..]);
        self.out.shrinkRetainingCapacity(avail.len - n);
        return n;
    }

    /// Frame thread: something for the reader — paths waiting, or an end it
    /// has not heard.
    pub fn ready(self: *Walk) bool {
        if (!self.done_heard and self.done.load(.acquire)) return true;
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.out.items.len > 0;
    }

    /// Stop and let go. Never blocks: the worker sees `cancel` and frees the
    /// walk itself if it is the last to let go.
    pub fn deinit(self: *Walk) void {
        self.cancel.store(true, .release);
        self.release();
    }

    fn release(self: *Walk) void {
        if (self.refs.fetchSub(1, .acq_rel) != 1) return;
        const gpa = self.gpa;
        self.out.deinit(gpa);
        for (self.prune) |n| gpa.free(n);
        gpa.free(self.prune);
        gpa.free(self.root);
        gpa.destroy(self);
    }

    fn pruned(self: *const Walk, name: []const u8) bool {
        for (self.prune) |p| if (std.mem.eql(u8, p, name)) return true;
        return false;
    }

    fn push(self: *Walk, rel: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.out.ensureUnusedCapacity(self.gpa, rel.len + 1) catch return;
        self.out.appendSliceAssumeCapacity(rel);
        self.out.appendAssumeCapacity('\n');
    }

    fn work(self: *Walk) void {
        defer self.release();
        defer {
            self.done.store(true, .release);
            self.pool.wakeLoop();
        }
        const gpa = self.gpa;
        var threaded: std.Io.Threaded = .init(gpa, .{});
        defer threaded.deinit();
        const io = threaded.io();
        const cwd = std.Io.Dir.cwd();

        var stack: std.ArrayList([]u8) = .empty;
        defer {
            for (stack.items) |p| gpa.free(p);
            stack.deinit(gpa);
        }
        stack.append(gpa, gpa.dupe(u8, "") catch return) catch return;
        var count: usize = 0;
        var since_wake: usize = 0;
        while (stack.pop()) |rel| {
            defer gpa.free(rel);
            if (self.cancel.load(.acquire)) return;
            const full = if (rel.len == 0)
                gpa.dupe(u8, self.root) catch continue
            else
                std.Io.Dir.path.join(gpa, &.{ self.root, rel }) catch continue;
            defer gpa.free(full);
            if (rel.len > 0) if (self.refuse) |refuse| if (refuse(full)) continue;
            var dir = cwd.openDir(io, full, .{ .iterate = true }) catch continue;
            defer dir.close(io);
            var it = dir.iterate();
            while (it.next(io) catch null) |e| {
                if (e.name.len == 0) continue;
                if (self.skip_hidden and e.name[0] == '.') continue;
                if (e.kind == .directory and self.pruned(e.name)) continue;
                const child = if (rel.len == 0)
                    gpa.dupe(u8, e.name) catch continue
                else
                    std.Io.Dir.path.join(gpa, &.{ rel, e.name }) catch continue;
                switch (e.kind) {
                    // A directory is entered; a symlink is listed, never followed.
                    .directory => stack.append(gpa, child) catch gpa.free(child),
                    else => {
                        defer gpa.free(child);
                        self.push(child);
                        count += 1;
                        since_wake += 1;
                        if (count >= max_files) {
                            self.cut.store(true, .release);
                            return;
                        }
                        if (since_wake >= wake_every) {
                            since_wake = 0;
                            self.pool.wakeLoop();
                        }
                    },
                }
            }
        }
    }
};

const t = std.testing;

test "fs_walk: files under the root, relative to it, hidden and pruned skipped, symlinks not followed" {
    const gpa = t.allocator;
    var pool = try task.Pool.init(gpa, .{ .threads = 2 });
    defer pool.deinit();
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    try tmp.dir.createDirPath(io, "src/app");
    try tmp.dir.createDirPath(io, "node_modules/x");
    try tmp.dir.createDirPath(io, ".git");
    for ([_][]const u8{ "README", "src/main.zig", "src/app/frame.zig", "node_modules/x/i.js", ".git/HEAD", ".env" }) |f| {
        try tmp.dir.writeFile(io, .{ .sub_path = f, .data = "x" });
    }
    const root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(root);

    const w = try Walk.start(gpa, pool, root, .{ .prune = &.{"node_modules"} });
    var got: std.ArrayList(u8) = .empty;
    defer got.deinit(gpa);
    var buf: [256]u8 = undefined;
    const deadline = task.nowNs() + 5 * std.time.ns_per_s;
    const cut = while (task.nowNs() < deadline) {
        switch (w.take(&buf)) {
            .bytes => |n| try got.appendSlice(gpa, buf[0..n]),
            .waiting => std.Thread.yield() catch {},
            .over => |o| break o.cut,
        }
    } else return error.Timeout;
    w.deinit();
    try t.expect(!cut);
    var seen: [3]bool = @splat(false);
    var lines = std.mem.splitScalar(u8, got.items, '\n');
    while (lines.next()) |l| {
        if (l.len == 0) continue;
        if (std.mem.eql(u8, l, "README")) seen[0] = true else if (std.mem.eql(u8, l, "src/main.zig")) seen[1] = true else if (std.mem.eql(u8, l, "src/app/frame.zig")) seen[2] = true else return error.UnexpectedPath;
    }
    try t.expect(seen[0] and seen[1] and seen[2]);
}

test "fs_walk: closed mid-walk, it frees itself" {
    const gpa = t.allocator;
    var pool = try task.Pool.init(gpa, .{ .threads = 1 });
    defer pool.deinit(); // drains the worker; the refcount frees the walk
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    try tmp.dir.writeFile(threaded.io(), .{ .sub_path = "x", .data = "" });
    const root = try tmp.dir.realPathFileAlloc(threaded.io(), ".", gpa);
    defer gpa.free(root);
    const w = try Walk.start(gpa, pool, root, .{});
    w.deinit(); // the owner lets go at once; t.allocator checks the rest
}
