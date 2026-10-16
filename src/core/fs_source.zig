//! A native candidate producer for the picker (pick.Source): the remote
//! directory browser, listing one level over a ShellFs. It lists ONCE on a
//! worker thread and streams results in; the picker's in-core fuzzy filter
//! narrows them. (The local file finder is the files plugin's, fed by
//! `wl_fs_walk`; this is what is left to move the same way.)
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

// ── Single-level directory browsers ─────────────────────────────────
// Entries carry a trailing "/" for directories — the only channel to
// the accept handler, which sees just the chosen string. A leading
// "../" lets the browser walk upward.

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

test {
    std.testing.refAllDecls(@This());
}
