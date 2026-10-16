//! `spawn` — a process whose output arrives as it is written.
//!
//! `exec` answers once, when the command has exited: right for `git status`,
//! wrong for a search that is still finding things, or a build whose first
//! error is worth seeing before its last. A process started here streams:
//! its stdout comes to the plugin line by line (or chunk by chunk, for a
//! protocol peer that frames its own messages) as the child writes it, and
//! its exit comes after its last line. The host wakes the plugin when bytes
//! land (`on_poll`); the SDK drains them and calls the handlers, so a plugin
//! never writes a poll loop, a line splitter or an exit check of its own.
//!
//! Argv only, like `exec`: no shell, so no quoting layer to get wrong. A
//! caller that wants a shell says so (`sh -c <script>`).
//!
//! Never blocking: one poll takes a bounded amount from each process
//! (`budget`); a flood of output is taken over several frames, and the host
//! keeps waking the plugin while some is waiting.

const std = @import("std");
const weft = @import("root.zig");
const e = @import("externs.zig");

fn p(ptr: anytype) u32 {
    return @intCast(@intFromPtr(ptr));
}

/// What to run.
pub const Spec = struct {
    argv: []const []const u8,
    /// Keep a stdin pipe for `Process.send` (a protocol peer). Without it the
    /// child's stdin is the null device.
    duplex: bool = false,
};

/// Where its output goes. Each handler is handed `ctx`.
pub const Handlers = struct {
    ctx: ?*anyopaque = null,
    /// Each complete stdout line, without its newline. The last line is
    /// handed over at exit even when the child did not end it.
    line: ?*const fn (ctx: ?*anyopaque, line: []const u8) void = null,
    /// stdout as it lands, unsplit (a protocol peer frames its own messages).
    chunk: ?*const fn (ctx: ?*anyopaque, bytes: []const u8) void = null,
    /// The exit, after the last of its output: the code (-1 by signal, or it
    /// never ran) and the tail of what it said on stderr.
    exit: ?*const fn (ctx: ?*anyopaque, code: i32, stderr: []const u8) void = null,
    /// Frees `ctx` once nothing more will be delivered.
    release: ?*const fn (gpa: std.mem.Allocator, ctx: ?*anyopaque) void = null,
};

/// A running process.
pub const Process = struct {
    slot: u32,
    /// Bumped each time a slot is reused, so a stale `Process` addresses
    /// nothing rather than whatever took its slot.
    generation: u32,

    /// Write to its stdin (`Spec.duplex`).
    pub fn send(self: Process, bytes: []const u8) void {
        const r = live(self) orelse return;
        e.wl_proc_send(r.handle, p(bytes.ptr), @intCast(bytes.len));
    }

    /// Kill it. Nothing more is delivered — not even its exit.
    pub fn kill(self: Process) void {
        const r = live(self) orelse return;
        e.wl_proc_close(r.handle);
        retire(self.slot);
    }

    /// Whether it is still running (or still has output to hand over).
    pub fn alive(self: Process) bool {
        return live(self) != null;
    }
};

const Running = struct {
    handle: u32,
    generation: u32,
    handlers: Handlers,
    /// A stdout line not yet ended.
    carry: std.ArrayList(u8) = .empty,
    /// What it said on stderr, the last `err_keep` bytes.
    err: std.ArrayList(u8) = .empty,
};

/// The most stderr kept for `Handlers.exit`.
const err_keep = 4096;
/// The most taken from one process in one poll.
const budget = 256 * 1024;

var slots: std.ArrayList(?Running) = .empty;
var generations: std.ArrayList(u32) = .empty;

fn live(proc: Process) ?*Running {
    if (proc.slot >= slots.items.len) return null;
    const r = &(slots.items[proc.slot] orelse return null);
    return if (r.generation == proc.generation) r else null;
}

/// Start `spec`; its output goes to `handlers`. Null when it could not be
/// started (no `proc` grant, no local place, an empty argv) — and then no
/// handler runs, and `handlers.release` has already run.
pub fn spawn(spec: Spec, handlers: Handlers) ?Process {
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

/// `spawn`, carrying a value of your own to typed handlers — the query a
/// search was started for, rather than a module-level "current search".
pub fn spawnWith(
    comptime Ctx: type,
    ctx: Ctx,
    spec: Spec,
    comptime H: type,
) ?Process {
    const Shim = struct {
        fn held(raw: ?*anyopaque) *Ctx {
            return @ptrCast(@alignCast(raw.?));
        }
        fn line(raw: ?*anyopaque, text: []const u8) void {
            H.line(held(raw).*, text);
        }
        fn chunk(raw: ?*anyopaque, bytes: []const u8) void {
            H.chunk(held(raw).*, bytes);
        }
        fn exit(raw: ?*anyopaque, code: i32, err: []const u8) void {
            H.exit(held(raw).*, code, err);
        }
        fn release(gpa: std.mem.Allocator, raw: ?*anyopaque) void {
            gpa.destroy(held(raw));
        }
    };
    const held = weft.allocator.create(Ctx) catch return null;
    held.* = ctx;
    return spawn(spec, .{
        .ctx = held,
        .line = if (@hasDecl(H, "line")) Shim.line else null,
        .chunk = if (@hasDecl(H, "chunk")) Shim.chunk else null,
        .exit = if (@hasDecl(H, "exit")) Shim.exit else null,
        .release = Shim.release,
    });
}

fn start(spec: Spec) ?u32 {
    if (spec.argv.len == 0 or spec.argv[0].len == 0) return null;
    const gpa = weft.allocator;
    // Arguments back to back, NUL-separated: the encoding `exec` uses.
    var block: std.ArrayList(u8) = .empty;
    defer block.deinit(gpa);
    for (spec.argv, 0..) |arg, i| {
        if (i > 0) block.append(gpa, 0) catch return null;
        block.appendSlice(gpa, arg) catch return null;
    }
    const h = e.wl_proc_spawn(p(block.items.ptr), @intCast(block.items.len), @intCast(spec.argv.len), @intFromBool(spec.duplex));
    return if (h < 0) null else @intCast(h);
}

fn occupy(slot: u32, handle: u32, handlers: Handlers) Process {
    generations.items[slot] +%= 1;
    const generation = generations.items[slot];
    slots.items[slot] = .{ .handle = handle, .generation = generation, .handlers = handlers };
    return .{ .slot = slot, .generation = generation };
}

fn refuse(handle: u32, handlers: Handlers) ?Process {
    e.wl_proc_close(handle);
    if (handlers.release) |f| f(weft.allocator, handlers.ctx);
    return null;
}

fn retire(slot: u32) void {
    const gpa = weft.allocator;
    var r = slots.items[slot] orelse return;
    slots.items[slot] = null;
    r.carry.deinit(gpa);
    r.err.deinit(gpa);
    if (r.handlers.release) |f| f(gpa, r.handlers.ctx);
}

/// Hand every live process's waiting output to its handlers, and its exit
/// once its output is all handed over. Called from `on_poll` (the SDK's own
/// export, before the plugin's `poll` hook).
pub fn pump() void {
    var i: usize = 0;
    while (i < slots.items.len) : (i += 1) {
        if (slots.items[i] == null) continue;
        drain(@intCast(i));
    }
}

fn drain(slot: u32) void {
    const gpa = weft.allocator;
    var buf: [16 * 1024]u8 = undefined;
    var taken: usize = 0;
    while (taken < budget) {
        // Re-read the slot each turn: a handler may kill this process.
        const r = &(slots.items[slot] orelse return);
        const n = e.wl_proc_read(r.handle, 0, p(&buf), buf.len);
        if (n <= 0) break;
        const bytes = buf[0..@intCast(n)];
        taken += bytes.len;
        if (r.handlers.chunk) |f| f(r.handlers.ctx, bytes);
        if (r.handlers.line != null) lines(slot, bytes);
    }
    if (taken >= budget) return; // more next poll; the host keeps waking us
    const r = &(slots.items[slot] orelse return);
    while (true) {
        const n = e.wl_proc_read(r.handle, 1, p(&buf), buf.len);
        if (n <= 0) break;
        keepErr(r, buf[0..@intCast(n)]);
    }
    const code = e.wl_proc_status(r.handle);
    if (code == -2) return; // still running
    // Exited (or the stream is gone, -3): the last unended line, then the exit.
    if (r.carry.items.len > 0) {
        if (r.handlers.line) |f| f(r.handlers.ctx, r.carry.items);
        if (slots.items[slot] == null) return;
    }
    const done = &(slots.items[slot] orelse return);
    if (done.handlers.exit) |f| f(done.handlers.ctx, if (code == -3) -1 else code, done.err.items);
    if (slots.items[slot] == null) return; // killed inside its own exit
    e.wl_proc_close(done.handle);
    retire(slot);
    _ = gpa;
}

/// Split `bytes` into lines, carrying an unended one to the next chunk.
fn lines(slot: u32, bytes: []const u8) void {
    const gpa = weft.allocator;
    var rest = bytes;
    while (std.mem.indexOfScalar(u8, rest, '\n')) |nl| {
        const r = &(slots.items[slot] orelse return);
        const f = r.handlers.line.?;
        if (r.carry.items.len > 0) {
            r.carry.appendSlice(gpa, rest[0..nl]) catch {};
            // Handed over by value: the handler may kill this process, which
            // frees the carry.
            const whole = gpa.dupe(u8, r.carry.items) catch return;
            defer gpa.free(whole);
            r.carry.clearRetainingCapacity();
            f(r.handlers.ctx, trimCr(whole));
        } else {
            f(r.handlers.ctx, trimCr(rest[0..nl]));
        }
        rest = rest[nl + 1 ..];
    }
    if (rest.len > 0) {
        const r = &(slots.items[slot] orelse return);
        r.carry.appendSlice(gpa, rest) catch {};
    }
}

fn trimCr(line: []const u8) []const u8 {
    return if (line.len > 0 and line[line.len - 1] == '\r') line[0 .. line.len - 1] else line;
}

fn keepErr(r: *Running, bytes: []const u8) void {
    const gpa = weft.allocator;
    r.err.appendSlice(gpa, bytes) catch return;
    if (r.err.items.len > err_keep) {
        const drop = r.err.items.len - err_keep;
        std.mem.copyForwards(u8, r.err.items[0..err_keep], r.err.items[drop..]);
        r.err.shrinkRetainingCapacity(err_keep);
    }
}
