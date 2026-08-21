//! Surface membrane: a guest builds its retained overlay begin→row→span→end,
//! then the view draws it every frame until close. Mirrors the pick membrane —
//! which-key/dired/magit render through this.

const wasm = @import("../wasm.zig");
const surface_mod = @import("../surface.zig");

const shared = @import("plugin.zig");
const WasmPlugin = shared.WasmPlugin;

pub fn hSurfaceBegin(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = caller;
    _ = results;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const placement: surface_mod.Placement = switch (@as(u32, @bitCast(args[0]))) {
        1 => .corner,
        2 => .center,
        else => .bottom,
    };
    p.surface.begin(p.gpa, placement);
}
/// Begin a `caret`-anchored overlay (rendering P2): like `hSurfaceBegin(3)`,
/// plus the anchor offset in the SAME call — `Surface.anchor` isn't part of
/// the begin/end double-buffered rebuild, so a guest sets it right alongside
/// the placement instead of a separate call the guest could forget.
pub fn hSurfaceCaret(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = caller;
    _ = results;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    p.surface.begin(p.gpa, .caret);
    p.surface.anchor = @intCast(@as(u32, @bitCast(args[0])));
}
pub fn hSurfaceRow(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = caller;
    _ = args;
    _ = results;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    p.surface.addRow(p.gpa);
}
pub fn hSurfaceSpan(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = results;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const text = caller.readMemory(p.gpa, @intCast(args[0]), @intCast(args[1])) catch return;
    defer p.gpa.free(text);
    p.surface.addSpan(p.gpa, text, surface_mod.Role.fromInt(@bitCast(args[2])));
}
pub fn hSurfaceEnd(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = caller;
    _ = results;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const selected: ?usize = if (args[0] < 0) null else @intCast(args[0]);
    p.surface.end(p.gpa, selected);
}
pub fn hSurfaceClose(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = caller;
    _ = args;
    _ = results;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    p.surface.close(p.gpa);
}
