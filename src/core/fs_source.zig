//! Native candidate producers for the picker (pick.Source): a recursive
//! file finder and single-level directory browsers (local + remote over
//! a ShellFs). Each walks/lists ONCE on a worker thread and streams
//! results in; the picker's in-core fuzzy filter narrows them.
//!
//! These run off the main thread, so — unlike a Fennel source — they are
//! pure Zig and never touch a Lua VM. Ownership is a refcount, not a
//! join: a pick can close inside the input hot section, and `close` must
//! not block, so it only flips `cancel` and drops the owner's reference.
//! Whichever of {worker exiting, owner closing} runs last frees the
//! shared block. Produced strings are owned by the shared block until
//! then; `pick.appendItems` deep-copies what it folds in, so nothing
//! dangles.

const std = @import("std");
const Allocator = std.mem.Allocator;

const task = @import("task.zig");
const pick = @import("pick.zig");
const command = @import("command.zig");
const ShellFs = @import("ShellFs.zig");

/// Fold this many new candidates (or reaching `done`) before paying for
/// a refilter — bounds the O(items) refilter cost on huge trees.
const batch_flush = 256;
/// Hard cap on a recursive walk (a runaway-tree backstop).
const max_files = 200_000;

/// Refcounted worker↔owner rendezvous. `produced` is worker-append /
/// main-drain under `mutex`; `root` and the block itself are freed by
/// the last `release`.
const Shared = struct {
    gpa: Allocator,
    refs: std.atomic.Value(u32),
    mutex: task.Mutex = .{},
    produced: std.ArrayList([]u8) = .empty,
    cancel: std.atomic.Value(bool) = .init(false),
    done: std.atomic.Value(bool) = .init(false),
    root: []u8,

    fn create(gpa: Allocator, root: []const u8) !*Shared {
        const self = try gpa.create(Shared);
        errdefer gpa.destroy(self);
        self.* = .{ .gpa = gpa, .refs = .init(2), .root = try gpa.dupe(u8, root) };
        return self;
    }

    /// Worker pushes an owned candidate string (frees it if the buffer
    /// can't grow — a full queue drops, never crashes).
    fn push(self: *Shared, s: []u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.produced.append(self.gpa, s) catch self.gpa.free(s);
    }

    fn release(self: *Shared) void {
        if (self.refs.fetchSub(1, .acq_rel) == 1) {
            for (self.produced.items) |s| self.gpa.free(s);
            self.produced.deinit(self.gpa);
            self.gpa.free(self.root);
            self.gpa.destroy(self);
        }
    }
};

/// Drain the produced delta into the live pick. Snapshots the new
/// pointers under the lock (the outer array may realloc under the
/// worker), then folds outside it. Returns whether it changed the UI.
fn drain(shared: *Shared, seen: *usize, ctx: *command.Context) anyerror!bool {
    const done = shared.done.load(.acquire);
    shared.mutex.lock();
    const total = shared.produced.items.len;
    const grown = total - seen.*;
    if (grown == 0 or (!done and grown < batch_flush)) {
        shared.mutex.unlock();
        return false;
    }
    const batch = ctx.gpa.alloc([]const u8, grown) catch {
        shared.mutex.unlock();
        return false;
    };
    defer ctx.gpa.free(batch);
    for (batch, 0..) |*b, i| b.* = shared.produced.items[seen.* + i];
    shared.mutex.unlock();
    try ctx.head.pick.appendItems(ctx.gpa, batch, null);
    seen.* = total;
    return true;
}

// ── Recursive local file finder ─────────────────────────────────────

pub const LocalFinder = struct {
    shared: *Shared,
    seen: usize = 0,

    /// Spawns the walk immediately. `root` is the directory to search
    /// (relative "." keeps produced paths openable as-is). Caller owns
    /// the returned finder; its lifecycle is the pick's — hand
    /// `source()` to `pick.openWith` and the pick's close frees it.
    pub fn create(gpa: Allocator, pool: *task.Pool, root: []const u8) !*LocalFinder {
        const shared = try Shared.create(gpa, root);
        errdefer {
            shared.release();
            shared.release();
        }
        const self = try gpa.create(LocalFinder);
        errdefer gpa.destroy(self);
        self.* = .{ .shared = shared };
        var h = try pool.spawn(walk, .{shared});
        h.detach();
        return self;
    }

    pub fn source(self: *LocalFinder) pick.Source {
        return .{ .data = self, .poll = poll, .close = close };
    }

    fn poll(data: ?*anyopaque, ctx: *command.Context) anyerror!bool {
        const self: *LocalFinder = @ptrCast(@alignCast(data.?));
        return drain(self.shared, &self.seen, ctx);
    }

    fn close(data: ?*anyopaque, gpa: Allocator) void {
        const self: *LocalFinder = @ptrCast(@alignCast(data.?));
        self.shared.cancel.store(true, .release);
        self.shared.release();
        gpa.destroy(self);
    }
};

/// Worker: DFS under `root`, emitting root-relative file paths, pruning
/// dot-entries (skips `.git` and friends). Dirs are pushed as pending
/// work; files are produced. A worker owns a short-lived blocking Io
/// (the file.zig / ShellFs pattern) — the main thread is never touched.
fn walk(shared: *Shared) void {
    defer shared.release();
    const gpa = shared.gpa;
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
    while (stack.pop()) |rel| {
        defer gpa.free(rel);
        if (shared.cancel.load(.acquire)) break;
        const full = if (rel.len == 0)
            gpa.dupe(u8, shared.root) catch continue
        else
            std.Io.Dir.path.join(gpa, &.{ shared.root, rel }) catch continue;
        defer gpa.free(full);
        var dir = cwd.openDir(io, full, .{ .iterate = true }) catch continue;
        defer dir.close(io);
        var it = dir.iterate();
        while (it.next(io) catch null) |e| {
            if (e.name.len == 0 or e.name[0] == '.') continue; // dotfiles + .git
            const child = if (rel.len == 0)
                gpa.dupe(u8, e.name) catch continue
            else
                std.Io.Dir.path.join(gpa, &.{ rel, e.name }) catch continue;
            switch (e.kind) {
                .directory => stack.append(gpa, child) catch gpa.free(child),
                else => {
                    shared.push(child);
                    count += 1;
                    if (count >= max_files) {
                        shared.done.store(true, .release);
                        return;
                    }
                },
            }
        }
    }
    shared.done.store(true, .release);
}

// ── Single-level directory browsers ─────────────────────────────────
// Entries carry a trailing "/" for directories — the only channel to
// the accept handler, which sees just the chosen string. A leading
// "../" lets the browser walk upward.

pub const LocalDir = struct {
    shared: *Shared,
    seen: usize = 0,

    pub fn create(gpa: Allocator, pool: *task.Pool, root: []const u8) !*LocalDir {
        const shared = try Shared.create(gpa, root);
        errdefer {
            shared.release();
            shared.release();
        }
        const self = try gpa.create(LocalDir);
        errdefer gpa.destroy(self);
        self.* = .{ .shared = shared };
        var h = try pool.spawn(listLocal, .{shared});
        h.detach();
        return self;
    }

    pub fn source(self: *LocalDir) pick.Source {
        return .{ .data = self, .poll = poll, .close = close };
    }

    fn poll(data: ?*anyopaque, ctx: *command.Context) anyerror!bool {
        const self: *LocalDir = @ptrCast(@alignCast(data.?));
        return drain(self.shared, &self.seen, ctx);
    }

    fn close(data: ?*anyopaque, gpa: Allocator) void {
        const self: *LocalDir = @ptrCast(@alignCast(data.?));
        self.shared.cancel.store(true, .release);
        self.shared.release();
        gpa.destroy(self);
    }
};

fn listLocal(shared: *Shared) void {
    defer shared.release();
    const gpa = shared.gpa;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    shared.push(gpa.dupe(u8, "../") catch return);
    var dir = std.Io.Dir.cwd().openDir(io, shared.root, .{ .iterate = true }) catch {
        shared.done.store(true, .release);
        return;
    };
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch null) |e| {
        if (shared.cancel.load(.acquire)) break;
        const marked = markEntry(gpa, e.name, e.kind == .directory) orelse continue;
        shared.push(marked);
    }
    shared.done.store(true, .release);
}

pub const RemoteDir = struct {
    shared: *Shared,
    fs: *ShellFs,
    seen: usize = 0,

    pub fn create(gpa: Allocator, pool: *task.Pool, fs: *ShellFs, path: []const u8) !*RemoteDir {
        const shared = try Shared.create(gpa, path);
        errdefer {
            shared.release();
            shared.release();
        }
        const self = try gpa.create(RemoteDir);
        errdefer gpa.destroy(self);
        self.* = .{ .shared = shared, .fs = fs };
        var h = try pool.spawn(listRemote, .{ shared, fs });
        h.detach();
        return self;
    }

    pub fn source(self: *RemoteDir) pick.Source {
        return .{ .data = self, .poll = poll, .close = close };
    }

    fn poll(data: ?*anyopaque, ctx: *command.Context) anyerror!bool {
        const self: *RemoteDir = @ptrCast(@alignCast(data.?));
        return drain(self.shared, &self.seen, ctx);
    }

    fn close(data: ?*anyopaque, gpa: Allocator) void {
        const self: *RemoteDir = @ptrCast(@alignCast(data.?));
        self.shared.cancel.store(true, .release);
        self.shared.release();
        gpa.destroy(self);
    }
};

/// One ssh round-trip (`ls`), serialized on the ShellFs mutex — cancel
/// is only checked around it, since the round-trip can't be interrupted.
fn listRemote(shared: *Shared, fs: *ShellFs) void {
    defer shared.release();
    const gpa = shared.gpa;
    if (shared.cancel.load(.acquire)) {
        shared.done.store(true, .release);
        return;
    }
    var listing = fs.list(gpa, shared.root) catch {
        shared.done.store(true, .release);
        return;
    };
    defer listing.deinit(gpa);
    shared.push(gpa.dupe(u8, "../") catch return);
    for (listing.entries) |e| {
        if (shared.cancel.load(.acquire)) break;
        const marked = markEntry(gpa, e.name, e.kind == .dir) orelse continue;
        shared.push(marked);
    }
    shared.done.store(true, .release);
}

fn markEntry(gpa: Allocator, name: []const u8, is_dir: bool) ?[]u8 {
    if (is_dir) return std.fmt.allocPrint(gpa, "{s}/", .{name}) catch null;
    return gpa.dupe(u8, name) catch null;
}

// ── Tests ───────────────────────────────────────────────────────────

const t = std.testing;

test "LocalFinder: enumerates files recursively, prunes dot-dirs" {
    const gpa = t.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "" });
    try tmp.dir.createDirPath(io, "sub");
    try tmp.dir.writeFile(io, .{ .sub_path = "sub/b.txt", .data = "" });
    try tmp.dir.createDirPath(io, ".git");
    try tmp.dir.writeFile(io, .{ .sub_path = ".git/config", .data = "" });

    var pool = try task.Pool.init(gpa, .{ .threads = 1 });
    defer pool.deinit();
    // t.tmpDir lives under .zig-cache/tmp/<sub_path>, cwd-relative.
    const root = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer gpa.free(root);

    const finder = try LocalFinder.create(gpa, pool, root);
    // Drive the worker to completion, then drop the owner ref.
    while (!finder.shared.done.load(.acquire)) std.Thread.yield() catch {};
    // One more yield window for the final push under the lock.
    std.Thread.yield() catch {};

    finder.shared.mutex.lock();
    var saw_a = false;
    var saw_b = false;
    var saw_git = false;
    for (finder.shared.produced.items) |p| {
        if (std.mem.endsWith(u8, p, "a.txt")) saw_a = true;
        if (std.mem.endsWith(u8, p, "b.txt")) saw_b = true;
        if (std.mem.indexOf(u8, p, ".git") != null) saw_git = true;
    }
    finder.shared.mutex.unlock();
    try t.expect(saw_a);
    try t.expect(saw_b);
    try t.expect(!saw_git);

    // Owner close (no pick involved here): cancel + release. The worker
    // already exited and released its ref, so this frees Shared.
    LocalFinder.close(finder, gpa);
}

test "LocalFinder: create-then-close mid-walk leaks nothing" {
    const gpa = t.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "x", .data = "" });
    var pool = try task.Pool.init(gpa, .{ .threads = 1 });
    defer pool.deinit(); // drains the worker; refcount frees Shared
    const root = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer gpa.free(root);
    const finder = try LocalFinder.create(gpa, pool, root);
    LocalFinder.close(finder, gpa); // immediate owner drop
    // t.allocator leak-checking is the assertion once the pool drains.
}

test {
    std.testing.refAllDecls(@This());
}
