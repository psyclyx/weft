//! Surface membrane: a guest builds its retained overlay begin→row→span→end,
//! then the view draws it every frame until close. Mirrors the pick membrane —
//! which-key/files/git render through this.

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
        4 => .top,
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
    // A fresh popup: no document until this build gives it one.
    p.surface.setInfo(p.gpa, "");
    p.surface.above = false;
}
/// The caret surface's document body: markdown the host renders as a
/// document (`gfx/view/doc_popup.zig`), beside the surface's rows or, with
/// none, as the popup itself. Flags bit 0: it would rather sit above the
/// caret's line.
pub fn hSurfaceDoc(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = results;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const text = caller.readMemory(p.gpa, @intCast(args[0]), @intCast(args[1])) catch return;
    defer p.gpa.free(text);
    p.surface.setInfo(p.gpa, text);
    const flags: u32 = @bitCast(args[2]);
    p.surface.above = flags & 1 != 0;
    // Bits 8+: visual lines scrolled off the document's top.
    p.surface.info_skip = flags >> 8;
}
/// `wl_surface_hint(ptr, len)`: the keys that drive the surface, shown in its
/// frame — `key\tlabel` per line (`core.surface.Surface.hint`).
pub fn hSurfaceHint(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = results;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const text = caller.readMemory(p.gpa, @intCast(args[0]), @intCast(args[1])) catch return;
    defer p.gpa.free(text);
    p.surface.setHint(p.gpa, text);
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
    // The role in the low byte; the next one is the span's column (a caret
    // surface's alignment hint: 0 main, 1+ annotations beside it).
    const packed_role: u32 = @bitCast(args[2]);
    p.surface.addSpanCol(p.gpa, text, surface_mod.Role.fromInt(packed_role & 0xff), @intCast((packed_role >> 8) & 0xff));
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
