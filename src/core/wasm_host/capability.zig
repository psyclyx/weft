//! Completion provider (host↔guest data-gather): the guest registers a provider
//! in init(); the host binds it into the caps registry with a trampoline that
//! calls the guest's on_complete per request, during which the guest pulls the
//! prefix and pushes candidates back (deduped, deep-copied host-side). Mirrors
//! abi.zig's in-process completionProvider — same shape, guest across the wire.

const std = @import("std");
const wasm = @import("../wasm.zig");
const capability = @import("../capability.zig");

const shared = @import("plugin.zig");
const WasmPlugin = shared.WasmPlugin;

pub fn hProvideCompletion(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = caller;
    _ = args;
    _ = results;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    // Cross-check: must be declared as the matching capability.
    if (!p.declaresCapability("edit/completion")) {
        p.load_error = error.UndeclaredCapability;
        return;
    }
    if (p.provider_id != null) return; // idempotent
    const gpa = p.gpa;
    const id = std.fmt.allocPrint(gpa, "plugin.{s}/edit/completion", .{p.name}) catch {
        p.load_error = error.OutOfMemory;
        return;
    };
    p.ctx.caps.register(.{
        .capability = "edit/completion",
        .id = id,
        .latency = .instant,
        .data = p,
        .handler = wpCompletionProvider,
    }) catch |e| {
        gpa.free(id);
        p.load_error = e;
        return;
    };
    p.provider_id = id;
}

pub fn hCompletionPrefix(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const n = caller.writeMemory(@intCast(args[0]), @intCast(args[1]), p.cur_prefix) catch 0;
    results[0] = @intCast(n);
}

pub fn hPushCompletion(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = results;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const out = p.completion_out orelse return;
    const gpa = p.gpa;
    const cand = caller.readMemory(gpa, @intCast(args[0]), @intCast(args[1])) catch return;
    // Dedup on collection (the in-process provider dedups too), so the
    // observable candidate set matches the Zig catalog plugin's.
    for (out.items) |w| if (std.mem.eql(u8, w, cand)) {
        gpa.free(cand);
        return;
    };
    out.append(gpa, cand) catch gpa.free(cand);
}

/// Caps trampoline: gather the guest's candidates for one request and push
/// them (the host deep-copies + re-stamps). Mirrors abi.zig's in-process
/// completionProvider — same shape, guest across the membrane.
fn wpCompletionProvider(data: ?*anyopaque, caps: *capability.Caps, req: *const capability.Request) anyerror!void {
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    if (req.kind != .completion) {
        caps.decline(req.session);
        return;
    }
    const gpa = p.gpa;
    var out: std.ArrayList([]const u8) = .empty;
    defer {
        for (out.items) |s| gpa.free(s);
        out.deinit(gpa);
    }
    p.cur_prefix = req.text;
    p.completion_out = &out;
    defer {
        p.completion_out = null;
        p.cur_prefix = &.{};
    }
    p.instance.callVoid("on_complete", &.{}) catch {
        caps.decline(req.session);
        return;
    };
    var items: std.ArrayList(capability.CompletionItem) = .empty;
    defer items.deinit(gpa);
    for (out.items, 0..) |txt, i| {
        try items.append(gpa, .{ .text = @constCast(txt), .rank = @intCast(i) });
    }
    try caps.push(req.session, .{ .id = p.provider_id.?, .latency = .instant }, .{ .completion = items.items });
}
