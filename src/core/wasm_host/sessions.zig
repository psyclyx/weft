//! Persistent streamed sessions the guest holds by handle: interactive REPL
//! subprocesses (design §6.3) and network connections (design §6.5). Both share
//! the same handle/lifecycle model — start returns an index, the frame loop
//! drains streamed output, quit/close kills + joins (the slot stays for handle
//! stability) — and both get it from `core/handles.zig`'s `Slots`, which is
//! also where the guest-supplied handle is bounds-checked. These handlers used
//! to `@intCast(args[0])` straight to `usize`: the import table declares the
//! parameter `.u32`, but a handler receives the raw word, so a guest passing
//! 2^31 arrived negative and panicked the HOST on a guest's bad argument.

const wasm = @import("../wasm.zig");

const shared = @import("plugin.zig");
const WasmPlugin = shared.WasmPlugin;
const requirePerm = shared.requirePerm;

const repl_session = @import("../repl_session.zig");

/// Start a persistent REPL (perm proc+timer, trap on deny): `<cmd>` runs
/// under /bin/sh, its output streaming into the named comint buffer. Returns
/// a session handle, or -1 if unavailable.
pub fn hReplStart(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    if (!requirePerm(p, caller, .proc)) return;
    if (!requirePerm(p, caller, .timer)) return;
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
    // A REPL runs where its entry is (`doc/place.md`): two interpreters started
    // from two projects are two interpreters IN those projects, not two names
    // for the same directory. `Session.start` dups the cwd, so this one is ours.
    const at = shared.resolveSpawnAt(p, gpa);
    defer switch (at) {
        .at => |dir| gpa.free(dir),
        else => {},
    };
    const cwd: ?[]const u8 = switch (at) {
        .inherit => null,
        .at => |dir| dir,
        .refused => |why| {
            shared.noteSpawnRefusal(p.name, why);
            results[0] = -1;
            return;
        },
    };
    const spawn_env = shared.resolveSpawnEnv(p, gpa);
    var env_owned = true;
    defer if (env_owned) if (spawn_env) |owned_env| owned_env.block.deinit(gpa);
    const s = repl_session.Session.start(gpa, pool, p.activeCtx(), p.name, buf, &.{ "/bin/sh", "-c", cmd }, spawn_env orelse shared.g_environ, cwd) catch {
        results[0] = -1;
        return;
    };
    // The session outlives this call and uses its environment throughout.
    if (spawn_env != null) {
        s.adoptEnviron();
        env_owned = false;
    }
    const handle = p.sessions.open(gpa, s) catch {
        s.deinit();
        results[0] = -1;
        return;
    };
    results[0] = @intCast(handle);
}

/// Write a line to a REPL session's stdin.
pub fn hReplSend(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = results;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const s = p.sessions.at(args[0]) orelse return;
    const line = caller.readMemory(p.gpa, @intCast(args[1]), @intCast(args[2])) catch return;
    defer p.gpa.free(line);
    s.send(line);
}

/// Quit a REPL session (kill + join); its handle stays valid but dead.
pub fn hReplQuit(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = caller;
    _ = results;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    p.sessions.close(args[0]);
}

/// Frame-thread: drain every session's streamed output into its buffer.
/// Returns true if anything was written (the view repaints).
pub fn drainReplSessions(p: *WasmPlugin) bool {
    var any = false;
    for (p.sessions.slice()) |maybe| {
        if (maybe) |s| {
            if (s.drain()) any = true;
        }
    }
    for (p.net_sessions.slice()) |maybe| {
        if (maybe) |s| {
            if (s.drain()) any = true;
        }
    }
    return any;
}

const net_session = @import("../net_session.zig");

/// net.connect (perm net, trap on deny): dial `host:port` — TLS verifying
/// `sni` when non-empty — streaming the socket into buffer `name`. Returns a
/// handle, or -1 if unavailable.
pub fn hNetConnect(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    if (!requirePerm(p, caller, .net)) return;
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
    const s = net_session.Session.start(gpa, pool, p.activeCtx(), p.name, name, hostport, if (sni.len > 0) sni else null) catch {
        results[0] = -1;
        return;
    };
    const handle = p.net_sessions.open(gpa, s) catch {
        s.deinit();
        results[0] = -1;
        return;
    };
    results[0] = @intCast(handle);
}

pub fn hNetSend(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = results;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const s = p.net_sessions.at(args[0]) orelse return;
    const bytes = caller.readMemory(p.gpa, @intCast(args[1]), @intCast(args[2])) catch return;
    defer p.gpa.free(bytes);
    s.send(bytes);
}

pub fn hNetClose(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = caller;
    _ = results;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    p.net_sessions.close(args[0]);
}
