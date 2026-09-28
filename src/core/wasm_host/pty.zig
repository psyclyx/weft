//! The terminal doors (doc/terminal.md): a child on a pseudo-terminal the
//! guest holds by handle (`core/pty.zig`), the cell grid an entry can be
//! (`core/grid.zig`), the room the pane showing it has, and the capture
//! declaration that routes raw input to it.
//!
//! These are MECHANISM. Which program runs, what TERM says, how bytes become
//! a screen and keys become bytes — all of that is the terminal plugin's; a
//! guest that is not a terminal (a game, a pager of its own) can stand on the
//! same four things.

const std = @import("std");
const wasm = @import("../wasm.zig");

const shared = @import("plugin.zig");
const WasmPlugin = shared.WasmPlugin;
const requirePerm = shared.requirePerm;
const requireDispatch = shared.requireDispatch;

const pty_mod = @import("../pty.zig");
const grid_mod = @import("../grid.zig");
const grid_mirror = @import("../grid_mirror.zig");
const Buffers = @import("../Buffers.zig");

/// `wl_pty_spawn(cmd, cols, rows) -> handle` (perm `proc`): run `cmd` under
/// `/bin/sh -c` on a new pty `cols`×`rows`, in the dispatching entry's place
/// with that place's environment — the same resolution every spawn door
/// makes, refused (-1) rather than run in the launch directory when the
/// place has no local directory. Its output is read with `wl_pty_read`.
pub fn hPtySpawn(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    if (!requirePerm(p, caller, .proc)) return;
    results[0] = -1;
    const pool = p.resources.pool orelse return;
    const gpa = p.gpa;
    const cmd = caller.readMemory(gpa, @intCast(args[0]), @intCast(args[1])) catch return;
    defer gpa.free(cmd);
    const at = shared.resolveSpawnAt(p, gpa);
    defer switch (at) {
        .at => |dir| gpa.free(dir),
        else => {},
    };
    const cwd: ?[]const u8 = switch (at) {
        .inherit => null,
        .at => |dir| dir,
        .refused => |why| return shared.noteSpawnRefusal(p.activeCtx(), p.name, why),
    };
    const spawn_env = shared.resolveSpawnEnv(p, gpa);
    var env_owned = true;
    defer if (env_owned) if (spawn_env) |owned_env| owned_env.block.deinit(gpa);
    const size: pty_mod.Size = .{ .cols = clampDim(args[2]), .rows = clampDim(args[3]) };
    const s = pty_mod.Pty.spawn(gpa, pool, cmd, cwd, spawn_env orelse p.resources.environ, size) catch return;
    // The child uses its environment for its whole life.
    if (spawn_env != null) {
        s.adoptEnviron();
        env_owned = false;
    }
    const handle = p.resources.ptys.open(gpa, s) catch return s.deinit();
    results[0] = @intCast(handle);
}

/// `wl_pty_write(h, bytes)`: what the child reads as typed. Queued; never
/// blocks the frame on a child that is not reading.
pub fn hPtyWrite(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = results;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const s = p.resources.ptys.at(args[0]) orelse return;
    const bytes = caller.readMemory(p.gpa, @intCast(args[1]), @intCast(args[2])) catch return;
    defer p.gpa.free(bytes);
    s.write(bytes);
}

/// `wl_pty_read(h, out, cap) -> n`: move up to `cap` bytes of the child's
/// output into `out`; -1 for a dead handle. A guest reads what it can
/// digest in one wake; what it leaves wakes it again.
pub fn hPtyRead(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const s = p.resources.ptys.at(args[0]) orelse {
        results[0] = -1;
        return;
    };
    var buf: [64 * 1024]u8 = undefined;
    const cap: usize = @min(buf.len, @as(u32, @bitCast(args[2])));
    const n = s.read(buf[0..cap]);
    results[0] = @intCast(caller.writeMemory(@intCast(args[1]), @intCast(n), buf[0..n]) catch 0);
}

/// `wl_pty_resize(h, cols, rows, px_w, px_h)`: the terminal's new size; the
/// kernel tells the foreground job.
pub fn hPtyResize(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = caller;
    _ = results;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const s = p.resources.ptys.at(args[0]) orelse return;
    s.resize(.{ .cols = clampDim(args[1]), .rows = clampDim(args[2]), .px_w = clampPx(args[3]), .px_h = clampPx(args[4]) });
}

/// `wl_pty_exited(h) -> code`: how the child ended — its exit code, 128 + a
/// killing signal — once everything it printed has been read; -1 while it
/// runs (or for a dead handle).
pub fn hPtyExited(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = caller;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const s = p.resources.ptys.at(args[0]) orelse {
        results[0] = -1;
        return;
    };
    results[0] = if (s.exitCode()) |c| c else -1;
}

/// `wl_pty_close(h)`: hang the child up (if it still runs), reap it, and
/// free the slot. The handle stays dead.
pub fn hPtyClose(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = caller;
    _ = results;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    p.resources.ptys.close(args[0]);
}

fn clampDim(raw: i32) u16 {
    return @intCast(std.math.clamp(raw, 1, 4096));
}

fn clampPx(raw: i32) u16 {
    return @intCast(std.math.clamp(raw, 0, std.math.maxInt(u16)));
}

/// Whether any pty `p` holds has news (`on_poll`'s readiness).
pub fn anyPtyReady(p: *WasmPlugin) bool {
    for (p.resources.ptys.slice()) |maybe| if (maybe) |s| if (s.ready()) return true;
    return false;
}

// ── Grid entries ────────────────────────────────────────────────────

/// The entry named `name` this plugin made with no text in it — the only
/// kind a grid may be published into. Null when there is none (the caller
/// may make one) — or when the name is another's or holds text (it may not).
fn ownGridEntry(p: *WasmPlugin, name: []const u8) union(enum) { found: *Buffers.Buffer, absent, refused } {
    const bufs = p.activeCtx().buffers;
    const id = bufs.findByName(name) orelse return .absent;
    const b = bufs.get(id) orelse return .absent;
    // A text entry is not a grid, whoever made it; a grid entry's only
    // text is the mirror of its cells.
    if (!std.mem.eql(u8, b.creator, p.name) or (b.editor != null and b.grid == null)) return .refused;
    return .{ .found = b };
}

/// `wl_grid_publish(name, msg) -> 0|-1`: apply one publish
/// (`weft_membrane.grid`) to the grid of the entry named `name`, making the
/// entry — this plugin's grid — if there is none yet. Refused for a name
/// another plugin's or the user's entry holds, or a text entry, and for a
/// malformed message (which changes nothing). A title section labels the
/// entry; while the entry is READ (not capturing) its document follows its
/// cells (`grid_mirror`).
pub fn hGridPublish(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    results[0] = -1;
    const gpa = p.gpa;
    const name = caller.readMemory(gpa, @intCast(args[0]), @intCast(args[1])) catch return;
    defer gpa.free(name);
    const msg = caller.readMemory(gpa, @intCast(args[2]), @intCast(args[3])) catch return;
    defer gpa.free(msg);
    const bufs = p.activeCtx().buffers;
    const b: *Buffers.Buffer = switch (ownGridEntry(p, name)) {
        .found => |b| b,
        .refused => return,
        .absent => blk: {
            const id = bufs.createView(gpa, name, "") catch return;
            const b = bufs.get(id) orelse return;
            b.read_only = grid_mirror.read_only;
            break :blk b;
        },
    };
    const g = b.grid orelse blk: {
        const g = gpa.create(grid_mod.Grid) catch return;
        g.* = .{};
        b.grid = g;
        break :blk g;
    };
    const applied = g.apply(gpa, msg) catch return;
    if (applied.title) |title| {
        // A label is one line, and short.
        const line = title[0 .. std.mem.indexOfAny(u8, title, "\r\n") orelse title.len];
        b.setTitle(gpa, line[0..@min(line.len, 256)]) catch {};
    }
    if (applied.cwd) |dir| followCwd(p, b, dir);
    _ = grid_mirror.ensureDocument(gpa, bufs, b) catch return;
    if (b.declared_posture != .capture) grid_mirror.sync(gpa, bufs, b) catch |err| {
        std.log.warn("grid: the text of {s} could not follow its cells: {t}", .{ b.name, err });
    };
    results[0] = 0;
}

/// The program behind grid entry `b` says it is in local directory `dir`
/// (a shell's OSC 7): the entry's place becomes that directory, so what is
/// opened or started from it — a relative file, another terminal — lands
/// where the shell is. A directory that is not one, or no embedding to say
/// what place it is, leaves the place as it was.
fn followCwd(p: *WasmPlugin, b: *Buffers.Buffer, dir: []const u8) void {
    if (dir.len == 0 or dir[0] != '/') return;
    const ctx = p.activeCtx();
    const realizer = ctx.realizer orelse return;
    switch (@import("../place.zig").realize(b.place, realizer)) {
        .path => |now| if (std.mem.eql(u8, std.mem.trimEnd(u8, now, "/"), std.mem.trimEnd(u8, dir, "/"))) return,
        else => {},
    }
    const place = realizer.placeOf(ctx, dir) orelse return;
    ctx.buffers.setPlace(b.id, place);
}

/// `wl_entry_extent(name, out) -> 1|0`: the room the pane showing the entry
/// named `name` had in the last frame, and how it showed it — five
/// little-endian `u16`s: cols, rows, cell width and height in pixels, and
/// flags (`grid.Extent.flag_reading`: the pane reads the entry as text, so
/// what is above its screen is wanted) — into `out`. 0 when no pane has
/// shown it yet. Asking clears the entry's "moved" flag: the asker has heard.
pub fn hEntryExtent(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    results[0] = 0;
    const name = caller.readMemory(p.gpa, @intCast(args[0]), @intCast(args[1])) catch return;
    defer p.gpa.free(name);
    const bufs = p.activeCtx().buffers;
    const b = bufs.get(bufs.findByName(name) orelse return) orelse return;
    const e = b.extent orelse return;
    var out: [10]u8 = undefined;
    std.mem.writeInt(u16, out[0..2], e.cols, .little);
    std.mem.writeInt(u16, out[2..4], e.rows, .little);
    std.mem.writeInt(u16, out[4..6], e.cell_w, .little);
    std.mem.writeInt(u16, out[6..8], e.cell_h, .little);
    std.mem.writeInt(u16, out[8..10], if (e.reading) grid_mod.Extent.flag_reading else 0, .little);
    _ = caller.writeMemory(@intCast(args[2]), out.len, &out) catch return;
    b.extent_moved = false;
    results[0] = 1;
}

/// Whether an entry `p` made has a new extent it has not asked for — or an
/// entry holding a grid has closed since `p` last heard (it may have been
/// one of `p`'s, whose feed `p` should end).
pub fn anyExtentMoved(p: *WasmPlugin) bool {
    const bufs = p.activeCtx().buffers;
    if (p.seen_grid_closes != bufs.grid_closes) {
        for (p.resources.ptys.slice()) |maybe| if (maybe != null) return true;
    }
    var it = bufs.iterator();
    while (it.next()) |b| if (b.extent_moved and b.grid != null and std.mem.eql(u8, b.creator, p.name)) return true;
    return false;
}

// ── Capture ─────────────────────────────────────────────────────────

/// `wl_declare_capture(cmd)`: the addressed entry CAPTURES input (§10.4):
/// every key but the grammar's break-out chord runs `cmd` with the key's
/// spec and the text it committed (`app/dispatch.zig`). Only the entry's
/// maker may: capture is how keystrokes leave the grammar, so no plugin may
/// turn an entry it does not own into a keylogger.
pub fn hDeclareCapture(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = results;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    if (!requireDispatch(p, caller, "wl_declare_capture")) return;
    const cmd = caller.readMemory(p.gpa, @intCast(args[0]), @intCast(args[1])) catch return;
    const b = p.activeCtx().buffer();
    if (cmd.len == 0 or !std.mem.eql(u8, b.creator, p.name)) {
        p.gpa.free(cmd);
        return;
    }
    p.gpa.free(b.capture_endpoint);
    b.capture_endpoint = cmd;
    b.declarePosture(.capture);
}
