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

/// The single per-buffer styles feed layer name (one styler per tool buffer,
/// last claim wins — the registry discipline). Read by the view as bulk paint.
const styles_layer_name = "styles";

/// `style.clear()`: (re)claim the ACTIVE buffer's styles layer for this plugin
/// and baseline it to `.normal` — a zeroed class-per-byte bulk spanning the
/// whole buffer. The guest calls this before repainting spans with `wl_style`.
/// Targets the active document, exactly like `wl_edit`.
pub fn hStyleClear(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = caller;
    _ = args;
    _ = results;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const gpa = p.gpa;
    const doc = p.ctx.document();
    const len = p.ctx.editor().text().byteLen();
    const layer = p.ctx.caps.layers.claim(gpa, doc, styles_layer_name, .local, p.name) catch return;
    const zeros = gpa.alloc(u8, len) catch return;
    defer gpa.free(zeros);
    @memset(zeros, 0);
    const version = doc.version(gpa) catch return;
    defer gpa.free(version);
    layer.publishBulk(gpa, version, 0, zeros) catch {};
}

/// `style(start, end, class)`: paint the active buffer's styles bulk with
/// `class` over `[start, end)` (clamped), mutating the published array in place
/// so a whole classify pass is O(bytes), not O(spans²). A no-op when
/// `wl_style_clear` hasn't run this round (no bulk to paint into).
pub fn hStyle(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = caller;
    _ = results;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const layer = p.ctx.caps.layers.find(p.ctx.document(), styles_layer_name) orelse return;
    if (layer.bulk) |*b| {
        const start = @min(@as(usize, @intCast(@as(u32, @bitCast(args[0])))), b.classes.len);
        const end = @min(@as(usize, @intCast(@as(u32, @bitCast(args[1])))), b.classes.len);
        if (start >= end) return;
        const class: u8 = @truncate(@as(u32, @bitCast(args[2])));
        @memset(b.classes[start..end], class);
    }
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
    const layer = p.ctx.caps.layers.claim(p.gpa, p.ctx.document(), decorations_layer_name, .local, p.name) catch return;
    layer.publishSpans(p.gpa, &.{}) catch {};
}

/// `decorate(anchor, placement, role, text)`: place a display-only decoration
/// anchored at `anchor` — virtual text drawn BESIDE the line (never in the
/// document, so it takes no commit and `yy` never yanks it), colored by `role`
/// (a styles-palette class). `placement`: 1=virtual_before, 2=virtual_after,
/// 3=eol, 4=gutter (0=range is ignored — decorations only). A no-op if the
/// layer wasn't claimed this round. This is the metadata-is-decoration door:
/// dired's perms/size/arrow/mark, an inlay hint, a blame chip.
pub fn hDecorate(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = results;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const layer = p.ctx.caps.layers.find(p.ctx.document(), decorations_layer_name) orelse return;
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

/// `readOnlyClear()`: (re)claim the ACTIVE buffer's read-only-span layer and
/// empty it — the guest republishes its full set after (a comint marking its
/// produced output read-only while the input line stays editable).
pub fn hReadOnlyClear(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = caller;
    _ = args;
    _ = results;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const layer = p.ctx.caps.layers.claim(p.gpa, p.ctx.document(), readonly_layer_name, .local, p.name) catch return;
    layer.publishSpans(p.gpa, &.{}) catch {};
}

/// `readOnlySpan(start, end)`: mark `[start, end)` read-only — an interactive
/// edit overlapping it is refused at the edit door (span-level defense in
/// depth). Accumulates; a no-op if the layer wasn't claimed this round.
pub fn hReadOnlySpan(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = caller;
    _ = results;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const layer = p.ctx.caps.layers.find(p.ctx.document(), readonly_layer_name) orelse return;
    const start: usize = @intCast(@as(u32, @bitCast(args[0])));
    const end: usize = @intCast(@as(u32, @bitCast(args[1])));
    if (end <= start) return;
    layer.appendSpan(p.gpa, .{ .start = start, .end = end, .kind = 0, .message = "", .face = .{} }) catch {};
}

/// `fold.clear()`: (re)claim the ACTIVE buffer's fold layer for this plugin and
/// empty it — the guest republishes its full fold set (a `fold` per range)
/// after. Targets the active document, like `wl_style_clear`.
pub fn hFoldClear(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = caller;
    _ = args;
    _ = results;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const layer = p.ctx.caps.layers.claim(p.gpa, p.ctx.document(), folds_layer_name, .local, p.name) catch return;
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
    const layer = p.ctx.caps.layers.find(p.ctx.document(), folds_layer_name) orelse return;
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
