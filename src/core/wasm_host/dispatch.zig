//! Per-dispatch data marshalling across the membrane: echo to the status line
//! (the asking head's, or a notice to the system from a background entry),
//! the command args a guest reads during on_command (arg_count/int/str) and the
//! result it sets back (set_result_int/str). Integers cross as i32 — the
//! membrane word; string results borrow the plugin's result_buf.

const wasm = @import("../wasm.zig");

const shared = @import("plugin.zig");
const WasmPlugin = shared.WasmPlugin;

pub fn hEcho(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = results;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const msg = caller.readMemory(p.gpa, @intCast(args[0]), @intCast(args[1])) catch return;
    defer p.gpa.free(msg);
    // A dispatching entry answers the head that asked. A BACKGROUND entry
    // (`on_activate`, `on_complete`, `on_fill_token`, …) has no head that
    // asked, so what it says is a notice to the whole system
    // (`Buffers.notices`), shown briefly where core's own background refusals
    // already go. It used to trap — the message was lost and the rest of the guest's
    // callback aborted with it, so every plugin had to remember a nested
    // `wl_run` to say anything off a keystroke, and three did not. Head state
    // is still never written from the background.
    if (!shared.canDispatch(p)) return shared.noteBackground(p.activeCtx(), p.name, msg);
    p.activeCtx().head.echo.clearRetainingCapacity();
    p.activeCtx().head.echo.appendSlice(p.gpa, msg) catch {};
}

// Command args in + result out. Integers cross as i32 — the membrane word.
pub fn hArgCount(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = caller;
    _ = args;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    results[0] = @intCast(p.cur_args.len);
}

pub fn hArgInt(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = caller;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const i: usize = @intCast(args[0]);
    results[0] = if (i < p.cur_args.len and p.cur_args[i] == .integer)
        @truncate(p.cur_args[i].integer)
    else
        0;
}

pub fn hArgStr(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const i: usize = @intCast(args[0]);
    if (i >= p.cur_args.len or p.cur_args[i] != .string) {
        results[0] = -1;
        return;
    }
    const n = caller.writeMemory(@intCast(args[1]), @intCast(args[2]), p.cur_args[i].string) catch {
        results[0] = -1;
        return;
    };
    results[0] = @intCast(n);
}

pub fn hSetResultInt(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = caller;
    _ = results;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    p.result = .{ .integer = args[0] };
}

pub fn hSetResultStr(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = results;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const bytes = caller.readMemory(p.gpa, @intCast(args[0]), @intCast(args[1])) catch return;
    defer p.gpa.free(bytes);
    p.result_buf.clearRetainingCapacity();
    p.result_buf.appendSlice(p.gpa, bytes) catch return;
    p.result = .{ .string = p.result_buf.items };
}

/// `keySerial() -> n`: how many keys the dispatching head has dispatched, the
/// one being dispatched included (`Head.key_serial`). A read, nothing more —
/// "was the key before this one mine?" is the guest's comparison to make, so
/// a repeat-on-the-same-key (Emacs's transient map) needs no keymap in core
/// that knows it is one.
pub fn hKeySerial(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = caller;
    _ = args;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    results[0] = @bitCast(p.activeCtx().head.key_serial);
}
