//! Persistent streamed sessions the guest holds by handle: interactive REPL
//! subprocesses (design §6.3) and network connections (design §6.5). Both share
//! the same handle/lifecycle model — start returns an index, the frame loop
//! drains streamed output, quit/close kills + joins (the slot stays for handle
//! stability).

const wasm = @import("../wasm.zig");

const shared = @import("plugin.zig");
const WasmPlugin = shared.WasmPlugin;
const perm_net = shared.perm_net;
const perm_proc = shared.perm_proc;
const perm_timer = shared.perm_timer;

const repl_session = @import("../repl_session.zig");

/// Start a persistent REPL: `<cmd>` runs under /bin/sh, its output streaming
/// into the named comint buffer. Returns a session handle, or -1.
pub fn hReplStart(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    if (!p.perms[perm_proc] or !p.perms[perm_timer]) {
        results[0] = -1;
        return;
    }
    const pool = p.pool orelse {
        results[0] = -1;
        return;
    };
    const gpa = p.gpa;
    const cmd = caller.readMemory(gpa, @intCast(args[0]), @intCast(args[1])) catch {
        results[0] = -1;
        return;
    };
    defer gpa.free(cmd);
    const buf = caller.readMemory(gpa, @intCast(args[2]), @intCast(args[3])) catch {
        results[0] = -1;
        return;
    };
    defer gpa.free(buf);
    const s = repl_session.Session.start(gpa, pool, p.ctx, p.name, buf, &.{ "/bin/sh", "-c", cmd }, shared.g_environ) catch {
        results[0] = -1;
        return;
    };
    p.sessions.append(gpa, s) catch {
        s.deinit();
        results[0] = -1;
        return;
    };
    results[0] = @intCast(p.sessions.items.len - 1);
}

/// Write a line to a REPL session's stdin.
pub fn hReplSend(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = results;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const h: usize = @intCast(args[0]);
    if (h >= p.sessions.items.len) return;
    const s = p.sessions.items[h] orelse return;
    const line = caller.readMemory(p.gpa, @intCast(args[1]), @intCast(args[2])) catch return;
    defer p.gpa.free(line);
    s.send(line);
}

/// Quit a REPL session (kill + join); its handle stays valid but dead.
pub fn hReplQuit(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = caller;
    _ = results;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const h: usize = @intCast(args[0]);
    if (h >= p.sessions.items.len) return;
    if (p.sessions.items[h]) |s| {
        s.deinit();
        p.sessions.items[h] = null;
    }
}

/// Frame-thread: drain every session's streamed output into its buffer.
/// Returns true if anything was written (the view repaints).
pub fn drainReplSessions(p: *WasmPlugin) bool {
    var any = false;
    for (p.sessions.items) |maybe| {
        if (maybe) |s| {
            if (s.drain()) any = true;
        }
    }
    for (p.net_sessions.items) |maybe| {
        if (maybe) |s| {
            if (s.drain()) any = true;
        }
    }
    return any;
}

const net_session = @import("../net_session.zig");

/// net.connect (perm net): dial `host:port` — TLS verifying `sni` when non-empty
/// — streaming the socket into buffer `name`. Returns a handle, or -1.
pub fn hNetConnect(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    if (!p.perms[perm_net]) {
        results[0] = -1;
        return;
    }
    const pool = p.pool orelse {
        results[0] = -1;
        return;
    };
    const gpa = p.gpa;
    const hostport = caller.readMemory(gpa, @intCast(args[0]), @intCast(args[1])) catch {
        results[0] = -1;
        return;
    };
    defer gpa.free(hostport);
    const name = caller.readMemory(gpa, @intCast(args[2]), @intCast(args[3])) catch {
        results[0] = -1;
        return;
    };
    defer gpa.free(name);
    const sni = caller.readMemory(gpa, @intCast(args[4]), @intCast(args[5])) catch {
        results[0] = -1;
        return;
    };
    defer gpa.free(sni);
    const s = net_session.Session.start(gpa, pool, p.ctx, p.name, name, hostport, if (sni.len > 0) sni else null) catch {
        results[0] = -1;
        return;
    };
    p.net_sessions.append(gpa, s) catch {
        s.deinit();
        results[0] = -1;
        return;
    };
    results[0] = @intCast(p.net_sessions.items.len - 1);
}

pub fn hNetSend(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = results;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const h: usize = @intCast(args[0]);
    if (h >= p.net_sessions.items.len) return;
    const s = p.net_sessions.items[h] orelse return;
    const bytes = caller.readMemory(p.gpa, @intCast(args[1]), @intCast(args[2])) catch return;
    defer p.gpa.free(bytes);
    s.send(bytes);
}

pub fn hNetClose(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = caller;
    _ = results;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const h: usize = @intCast(args[0]);
    if (h >= p.net_sessions.items.len) return;
    if (p.net_sessions.items[h]) |s| {
        s.deinit();
        p.net_sessions.items[h] = null;
    }
}
