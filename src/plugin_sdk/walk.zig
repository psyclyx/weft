//! `walk` — the files under a directory, handed over as they are found.
//!
//! The host walks off the frame thread (`wl_fs_walk`) and wakes the plugin
//! when paths land (`on_poll`); the SDK takes them and calls the handlers, so
//! a plugin listing a large tree neither blocks the editor nor writes a poll
//! loop. What to skip is the caller's to say (`Spec`). Needs `fs_read`.
//!
//! Never blocking: one poll takes a bounded amount from each walk (`budget`);
//! the host keeps waking the plugin while more is waiting.

const std = @import("std");
const weft = @import("root.zig");
const e = @import("externs.zig");

fn p(ptr: anytype) u32 {
    return @intCast(@intFromPtr(ptr));
}

pub const Spec = struct {
    /// The directory, absolute or as this plugin's `fs_read` grant reads it.
    /// Empty: the place this dispatch runs in, which core resolves — paths
    /// then come back relative to it, which is what `openTyped` reads a name
    /// against.
    root: []const u8 = "",
    /// Directory names never entered (`node_modules`, `zig-cache`).
    prune: []const []const u8 = &.{},
    /// List dot-entries too (`.git` and dotfiles are skipped otherwise).
    hidden: bool = false,
};

pub const Handlers = struct {
    ctx: ?*anyopaque = null,
    /// Each file's path, relative to `Spec.root`.
    path: ?*const fn (ctx: ?*anyopaque, path: []const u8) void = null,
    /// After each batch handed over (once per poll that had some).
    drained: ?*const fn (ctx: ?*anyopaque) void = null,
    /// The walk is over, after its last path; `cut`: it stopped at the host's
    /// cap rather than at the end of the tree.
    end: ?*const fn (ctx: ?*anyopaque, cut: bool) void = null,
    /// Frees `ctx` once nothing more will be delivered.
    release: ?*const fn (gpa: std.mem.Allocator, ctx: ?*anyopaque) void = null,
};

/// A walk in progress.
pub const Walk = struct {
    slot: u32,
    generation: u32,

    /// Stop it. Nothing more is delivered — not even its end.
    pub fn stop(self: Walk) void {
        const r = live(self) orelse return;
        e.wl_fs_walk_close(r.handle);
        retire(self.slot);
    }

    pub fn alive(self: Walk) bool {
        return live(self) != null;
    }
};

const Running = struct {
    handle: u32,
    generation: u32,
    handlers: Handlers,
};

/// The most taken from one walk in one poll: about two thousand paths. Each
/// becomes a row somewhere (a pick ranks it as it lands), so this bounds what
/// one frame pays; the host wakes the plugin again at once while more waits.
const budget = 32 * 1024;

var slots: std.ArrayList(?Running) = .empty;
var generations: std.ArrayList(u32) = .empty;

fn live(w: Walk) ?*Running {
    if (w.slot >= slots.items.len) return null;
    const r = &(slots.items[w.slot] orelse return null);
    return if (r.generation == w.generation) r else null;
}

/// Start walking `spec.root`; its paths go to `handlers`. Null when it could
/// not start (no such directory, or a place with none) — and then no handler runs, and
/// `handlers.release` has already run.
pub fn walk(spec: Spec, handlers: Handlers) ?Walk {
    const gpa = weft.allocator;
    const started = start(spec) orelse {
        if (handlers.release) |f| f(gpa, handlers.ctx);
        return null;
    };
    for (slots.items, 0..) |slot, i| {
        if (slot == null) return occupy(@intCast(i), started, handlers);
    }
    slots.append(gpa, null) catch return refuse(started, handlers);
    generations.append(gpa, 0) catch {
        _ = slots.pop();
        return refuse(started, handlers);
    };
    return occupy(@intCast(slots.items.len - 1), started, handlers);
}

/// `walk`, carrying a value of your own to typed handlers (`H.path`,
/// `H.drained`, `H.end`, each optional).
pub fn walkWith(comptime Ctx: type, ctx: Ctx, spec: Spec, comptime H: type) ?Walk {
    const Shim = struct {
        fn held(raw: ?*anyopaque) *Ctx {
            return @ptrCast(@alignCast(raw.?));
        }
        fn path(raw: ?*anyopaque, text: []const u8) void {
            H.path(held(raw).*, text);
        }
        fn drained(raw: ?*anyopaque) void {
            H.drained(held(raw).*);
        }
        fn end(raw: ?*anyopaque, cut: bool) void {
            H.end(held(raw).*, cut);
        }
        fn release(gpa: std.mem.Allocator, raw: ?*anyopaque) void {
            gpa.destroy(held(raw));
        }
    };
    const held = weft.allocator.create(Ctx) catch return null;
    held.* = ctx;
    return walk(spec, .{
        .ctx = @ptrCast(held),
        .path = if (@hasDecl(H, "path")) Shim.path else null,
        .drained = if (@hasDecl(H, "drained")) Shim.drained else null,
        .end = if (@hasDecl(H, "end")) Shim.end else null,
        .release = Shim.release,
    });
}

fn start(spec: Spec) ?u32 {
    const gpa = weft.allocator;
    var block: std.ArrayList(u8) = .empty;
    defer block.deinit(gpa);
    for (spec.prune, 0..) |name, i| {
        if (i > 0) block.append(gpa, 0) catch return null;
        block.appendSlice(gpa, name) catch return null;
    }
    const h = e.wl_fs_walk(p(spec.root.ptr), @intCast(spec.root.len), p(block.items.ptr), @intCast(block.items.len), @intFromBool(spec.hidden));
    return if (h < 0) null else @intCast(h);
}

fn occupy(slot: u32, handle: u32, handlers: Handlers) Walk {
    generations.items[slot] +%= 1;
    const generation = generations.items[slot];
    slots.items[slot] = .{ .handle = handle, .generation = generation, .handlers = handlers };
    return .{ .slot = slot, .generation = generation };
}

fn refuse(handle: u32, handlers: Handlers) ?Walk {
    e.wl_fs_walk_close(handle);
    if (handlers.release) |f| f(weft.allocator, handlers.ctx);
    return null;
}

fn retire(slot: u32) void {
    const r = slots.items[slot] orelse return;
    slots.items[slot] = null;
    if (r.handlers.release) |f| f(weft.allocator, r.handlers.ctx);
}

/// Hand every walk's waiting paths to its handlers, and its end after the
/// last. Called from `on_poll`, beside `process.pump`.
pub fn pump() void {
    var i: usize = 0;
    while (i < slots.items.len) : (i += 1) {
        if (slots.items[i] == null) continue;
        drain(@intCast(i));
    }
}

fn drain(slot: u32) void {
    var buf: [budget]u8 = undefined;
    var taken: usize = 0;
    while (taken < budget) {
        // Re-read the slot each turn: a handler may stop this walk.
        const r = &(slots.items[slot] orelse return);
        const n = e.wl_fs_walk_read(r.handle, p(&buf), buf.len);
        if (n == 0) break;
        if (n < 0) {
            if (taken > 0) if (r.handlers.drained) |f| f(r.handlers.ctx);
            const over = &(slots.items[slot] orelse return);
            if (over.handlers.end) |f| f(over.handlers.ctx, n == -2);
            if (slots.items[slot] == null) return; // stopped inside its own end
            e.wl_fs_walk_close(over.handle);
            retire(slot);
            return;
        }
        taken += @intCast(n);
        var it = std.mem.splitScalar(u8, buf[0..@intCast(n)], '\n');
        while (it.next()) |path| {
            if (path.len == 0) continue;
            const cur = &(slots.items[slot] orelse return);
            if (cur.generation != r.generation) return;
            if (cur.handlers.path) |f| f(cur.handlers.ctx, path);
        }
    }
    if (taken > 0) {
        const r = &(slots.items[slot] orelse return);
        if (r.handlers.drained) |f| f(r.handlers.ctx);
    }
}
