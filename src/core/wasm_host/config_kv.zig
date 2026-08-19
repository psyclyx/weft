//! Group E admin: the namespaced key-value store (runtime scratch) and the
//! read-only config store the config plane staged (weft.set). Two DISTINCT
//! stores so injected config and runtime kv scratch can never collide.

const wasm = @import("../wasm.zig");

const shared = @import("plugin.zig");
const WasmPlugin = shared.WasmPlugin;

/// `wl_config_get(key_ptr, key_len, out_ptr, out_cap) → n` — read this plugin's
/// staged config value for `key` into guest memory, returning bytes written or
/// -1 if absent. Reads the DISTINCT config store (never runtime kv scratch).
/// The blob is the framed encoding the config shim produced (see guest
/// weft.configList); the guest decoder detects a short buffer.
pub fn hConfigGet(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const store = p.config_store orelse {
        results[0] = -1;
        return;
    };
    const key = caller.readMemory(p.gpa, @intCast(args[0]), @intCast(args[1])) catch {
        results[0] = -1;
        return;
    };
    defer p.gpa.free(key);
    const val = store.get(p.name, key) orelse {
        results[0] = -1;
        return;
    };
    const n = caller.writeMemory(@intCast(args[2]), @intCast(args[3]), val) catch {
        results[0] = -1;
        return;
    };
    results[0] = @intCast(n);
}

pub fn hKvGet(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const store = p.store orelse {
        results[0] = -1;
        return;
    };
    const key = caller.readMemory(p.gpa, @intCast(args[0]), @intCast(args[1])) catch {
        results[0] = -1;
        return;
    };
    defer p.gpa.free(key);
    const val = store.get(p.name, key) orelse {
        results[0] = -1;
        return;
    };
    const n = caller.writeMemory(@intCast(args[2]), @intCast(args[3]), val) catch {
        results[0] = -1;
        return;
    };
    results[0] = @intCast(n);
}

pub fn hKvPut(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = results;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const store = p.store orelse return;
    const key = caller.readMemory(p.gpa, @intCast(args[0]), @intCast(args[1])) catch return;
    defer p.gpa.free(key);
    const val = caller.readMemory(p.gpa, @intCast(args[2]), @intCast(args[3])) catch return;
    defer p.gpa.free(val);
    store.put(p.gpa, p.name, key, val) catch {};
}
