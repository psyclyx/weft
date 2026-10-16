//! `listen` — a slot's answers, handed over as they land.
//!
//! A `Fire` asks every plugin that answers a slot here. Some answer inside the
//! fire; some answer LATER — a walk of a directory, a server — and may answer
//! more than once. The host wakes the asker when an answer lands (`on_poll`);
//! the SDK reads the new ones and calls the handler, so a plugin consuming a
//! slot neither polls nor counts what it has already read.
//!
//! The listening owns the `Fire`: `stop` finishes it, and nothing more is
//! delivered after.

const std = @import("std");
const weft = @import("root.zig");

pub const Handlers = struct {
    ctx: ?*anyopaque = null,
    /// One answer: its schema-encoded payload (decode it against the slot's
    /// schema) and who gave it. Both are valid for the call.
    answer: *const fn (ctx: ?*anyopaque, payload: []const u8, provider: []const u8) void,
    /// Frees `ctx` once nothing more will be delivered.
    release: ?*const fn (gpa: std.mem.Allocator, ctx: ?*anyopaque) void = null,
};

/// A slot being listened to.
pub const Listening = struct {
    slot: u32,
    generation: u32,

    /// Stop listening and finish the fired session.
    pub fn stop(self: Listening) void {
        const r = live(self) orelse return;
        r.fire.deinit();
        retire(self.slot);
    }

    pub fn alive(self: Listening) bool {
        return live(self) != null;
    }
};

const Running = struct {
    fire: weft.Fire,
    generation: u32,
    handlers: Handlers,
    /// Answers already handed over.
    seen: usize = 0,
};

var slots: std.ArrayList(?Running) = .empty;
var generations: std.ArrayList(u32) = .empty;

fn live(l: Listening) ?*Running {
    if (l.slot >= slots.items.len) return null;
    const r = &(slots.items[l.slot] orelse return null);
    return if (r.generation == l.generation) r else null;
}

/// Hand `fire`'s answers to `handlers`: those already in, now, and each later
/// one as it lands. Null when it could not be held — and then `fire` is
/// finished and `handlers.release` has run.
pub fn listen(fire: weft.Fire, handlers: Handlers) ?Listening {
    const gpa = weft.allocator;
    const slot: u32 = for (slots.items, 0..) |s, i| {
        if (s == null) break @intCast(i);
    } else blk: {
        slots.append(gpa, null) catch return refuse(fire, handlers);
        generations.append(gpa, 0) catch {
            _ = slots.pop();
            return refuse(fire, handlers);
        };
        break :blk @intCast(slots.items.len - 1);
    };
    generations.items[slot] +%= 1;
    slots.items[slot] = .{ .fire = fire, .generation = generations.items[slot], .handlers = handlers };
    const l: Listening = .{ .slot = slot, .generation = generations.items[slot] };
    drain(slot);
    return l;
}

/// `listen`, carrying a value of your own to a typed handler (`H.answer`).
pub fn listenWith(comptime Ctx: type, ctx: Ctx, fire: weft.Fire, comptime H: type) ?Listening {
    const Shim = struct {
        fn held(raw: ?*anyopaque) *Ctx {
            return @ptrCast(@alignCast(raw.?));
        }
        fn answer(raw: ?*anyopaque, payload: []const u8, provider: []const u8) void {
            H.answer(held(raw).*, payload, provider);
        }
        fn release(gpa: std.mem.Allocator, raw: ?*anyopaque) void {
            gpa.destroy(held(raw));
        }
    };
    const held = weft.allocator.create(Ctx) catch {
        fire.deinit();
        return null;
    };
    held.* = ctx;
    return listen(fire, .{ .ctx = @ptrCast(held), .answer = Shim.answer, .release = Shim.release });
}

fn refuse(fire: weft.Fire, handlers: Handlers) ?Listening {
    fire.deinit();
    if (handlers.release) |f| f(weft.allocator, handlers.ctx);
    return null;
}

fn retire(slot: u32) void {
    const r = slots.items[slot] orelse return;
    slots.items[slot] = null;
    if (r.handlers.release) |f| f(weft.allocator, r.handlers.ctx);
}

/// Hand every listening's new answers over. Called from `on_poll`, beside
/// `process.pump` and `walk.pump`.
pub fn pump() void {
    var i: usize = 0;
    while (i < slots.items.len) : (i += 1) {
        if (slots.items[i] != null) drain(@intCast(i));
    }
}

fn drain(slot: u32) void {
    while (true) {
        // Re-read the slot each turn: a handler may stop this listening.
        const r = &(slots.items[slot] orelse return);
        if (r.seen >= r.fire.count()) return;
        const i = r.seen;
        r.seen += 1;
        const payload = r.fire.result(i) orelse continue;
        const provider = r.fire.provider(i) orelse "";
        r.handlers.answer(r.handlers.ctx, payload, provider);
    }
}
