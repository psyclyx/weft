//! Per-buffer bulk layers a guest paints: the styles feed (a StyleClass per
//! byte, rendered through Theme.styleColor), the fold set (invisible spans the
//! view elides), and vim-goggles flash (a faded range the frame loop times).

const std = @import("std");
const wasm = @import("../wasm.zig");
const core_layers = @import("../layers.zig");

const shared = @import("plugin.zig");
const WasmPlugin = shared.WasmPlugin;

/// vim-goggles: a guest (an operator) flashes the range it just acted on
/// (`wl_flash(start, end)`). The range + a generation counter live here; the
/// frame loop times the fade and the view draws it. Name-based/global, like the
/// other host↔frame-loop bridges.
var g_flash: struct { start: u32 = 0, end: u32 = 0, gen: u64 = 0 } = .{};
pub const Flash = struct { start: usize, end: usize, gen: u64 };
pub fn flashState() Flash {
    return .{ .start = g_flash.start, .end = g_flash.end, .gen = g_flash.gen };
}
pub fn hFlash(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = data;
    _ = caller;
    _ = results;
    const start: u32 = @bitCast(args[0]);
    const end: u32 = @bitCast(args[1]);
    g_flash = .{ .start = @min(start, end), .end = @max(start, end), .gen = g_flash.gen + 1 };
}

const folds_layer_name = "folds";
pub const readonly_layer_name = "readonly";
const decorations_layer_name = "decorations";

/// `decorateClear()`: (re)claim the ACTIVE buffer's decorations layer and empty
/// it — the guest republishes its full set of placed decorations each render.
pub fn hDecorateClear(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = caller;
    _ = args;
    _ = results;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const doc = p.activeCtx().document() orelse return;
    const layer = p.activeCtx().caps.layers.claim(p.gpa, doc, decorations_layer_name, .local, p.name) catch return;
    layer.publishSpans(p.gpa, &.{}) catch {};
}

/// `decorate(anchor, placement, role, text)`: place a display-only decoration
/// anchored at `anchor` — virtual text drawn BESIDE the line (never in the
/// document, so it takes no commit and `yy` never yanks it), colored by `role`
/// (a styles-palette class). `placement`: 1=virtual_before, 2=virtual_after,
/// 3=eol, 4=gutter (0=range is ignored — decorations only). A no-op if the
/// layer wasn't claimed this round. This is the metadata-is-decoration door:
/// files's perms/size/arrow/mark, an inlay hint, a blame chip.
pub fn hDecorate(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = results;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const doc = p.activeCtx().document() orelse return;
    const layer = p.activeCtx().caps.layers.find(doc, decorations_layer_name) orelse return;
    const anchor: usize = @intCast(@as(u32, @bitCast(args[0])));
    const placement: core_layers.Placement = switch (@as(u32, @bitCast(args[1]))) {
        1 => .virtual_before,
        2 => .virtual_after,
        3 => .eol,
        4 => .gutter,
        else => return,
    };
    const role: u32 = @bitCast(args[2]);
    const text = caller.readMemory(p.gpa, @intCast(args[3]), @intCast(args[4])) catch return;
    defer p.gpa.free(text);
    layer.appendSpan(p.gpa, .{
        .start = anchor,
        .end = anchor,
        .kind = role,
        .message = text,
        .placement = placement,
    }) catch {};
}

const breakpoints = @import("../breakpoints.zig");

/// `breakpointToggle(offset)` → 1 if a breakpoint is now SET at `offset` in the
/// active document, 0 if it was cleared. The mark is an ANCHOR on that
/// document's breakpoint layer, so an edit above it carries it along; the
/// guest keeps no copy to go stale. Display-only — no document bytes, no perm.
pub fn hBreakpointToggle(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = caller;
    results[0] = 0;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const doc = p.activeCtx().document() orelse return;
    const off: usize = @intCast(@as(u32, @bitCast(args[0])));
    const set = breakpoints.toggle(p.gpa, &p.activeCtx().caps.layers, doc, off) catch return;
    results[0] = if (set) 1 else 0;
}

/// `breakpointClear()`: drop every breakpoint in the active document.
pub fn hBreakpointClear(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = caller;
    _ = args;
    _ = results;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const doc = p.activeCtx().document() orelse return;
    breakpoints.clear(p.gpa, &p.activeCtx().caps.layers, doc);
}

/// `breakpointOffsets(out)` → the active document's breakpoints as an offset
/// CSV at the CURRENT head, so the guest paints its gutter markers from the
/// anchored truth instead of remembering positions of its own.
pub fn hBreakpointOffsets(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    results[0] = 0;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const doc = p.activeCtx().document() orelse return;
    var offs: [breakpoints.max]usize = undefined;
    const n = breakpoints.offsets(&p.activeCtx().caps.layers, doc, &offs);
    // One decimal offset plus its separator per breakpoint; a document big
    // enough to need wider ones stops at the buffer rather than past it.
    var buf: [breakpoints.max * 21]u8 = undefined;
    var w: usize = 0;
    for (offs[0..n]) |o| {
        var num: [20]u8 = undefined;
        const s = std.fmt.bufPrint(&num, "{d}", .{o}) catch continue;
        if (w + s.len + @intFromBool(w != 0) > buf.len) break;
        if (w != 0) {
            buf[w] = ',';
            w += 1;
        }
        @memcpy(buf[w .. w + s.len], s);
        w += s.len;
    }
    results[0] = @intCast(caller.writeMemory(@intCast(args[0]), @intCast(args[1]), buf[0..w]) catch 0);
}

/// `fold.clear()`: (re)claim the ACTIVE buffer's fold layer for this plugin and
/// empty it — the guest republishes its full fold set (a `fold` per range)
/// after. Targets the active document, as every layer-claiming door does.
pub fn hFoldClear(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = caller;
    _ = args;
    _ = results;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const doc = p.activeCtx().document() orelse return;
    const layer = p.activeCtx().caps.layers.claim(p.gpa, doc, folds_layer_name, .local, p.name) catch return;
    layer.publishSpans(p.gpa, &.{}) catch {};
}

/// `fold(start, end)`: hide `[start, end)` as an invisible span — the view
/// elides those rows and vertical motion skips them. Accumulates onto the
/// layer (call `fold.clear` first to reset); a no-op if the layer wasn't
/// claimed this round.
pub fn hFold(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = caller;
    _ = results;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const doc = p.activeCtx().document() orelse return;
    const layer = p.activeCtx().caps.layers.find(doc, folds_layer_name) orelse return;
    const start: usize = @intCast(@as(u32, @bitCast(args[0])));
    const end: usize = @intCast(@as(u32, @bitCast(args[1])));
    if (end <= start) return;
    layer.appendSpan(p.gpa, .{
        .start = start,
        .end = end,
        .kind = 0,
        .message = "",
        .face = .{ .invisible = true, .foldable = true },
    }) catch {};
}
