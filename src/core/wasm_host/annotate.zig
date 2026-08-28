//! The third-party decoration door (architecture §11.7): a guest claims a
//! named annotation layer on an entry it can REFERENCE — not "the active
//! buffer" — reads that entry's text to compute its marks, and publishes
//! revision-stamped spans with roles. The presentation hosting the entry
//! composites whatever annotation feeds it finds; it never learns the
//! decorator exists.
//!
//! The standing rules are structural, not conventional:
//!   - the target is a CAPTURED REF behind an opaque handle, so a closed
//!     entry resolves to nothing instead of falling through to the active one;
//!   - ownership is per-name, and a builtin layer name (`styles`, `folds`, …)
//!     is refused — a decorator cannot paint through core's own feeds;
//!   - `begin` stamps the entry revision the spans are computed against, so a
//!     set that no longer resolves is DROPPED, not rebased into a guess;
//!   - annotations never grant: a span carries a role and display text, and
//!     nothing here makes a decorated row focusable, editable, or reachable
//!     into the decorator's authority;
//!   - `close` (and plugin teardown) removes that provider's paint and
//!     nothing else — feeds are droppable by definition.

const std = @import("std");
const wasm = @import("../wasm.zig");
const core_layers = @import("../layers.zig");

const shared = @import("plugin.zig");
const WasmPlugin = shared.WasmPlugin;

/// `annotate.open(entry_id, name)` → an opaque target handle, or -1 when the
/// entry is unknown/holds no text, or the name is already a builtin feed.
pub fn hOpen(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    results[0] = -1;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const name = caller.readMemory(p.gpa, @intCast(args[1]), @intCast(args[2])) catch return;
    defer p.gpa.free(name);
    if (name.len == 0) return;
    const handle = p.openAnnotation(@bitCast(args[0]), name) catch return;
    results[0] = @intCast(handle);
}

/// `annotate.close(handle)`: drop this provider's layer on that entry.
pub fn hClose(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = caller;
    _ = results;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    p.closeAnnotation(@bitCast(args[0]));
}

/// `annotate.byteLen(handle)` → the decorated entry's length at the current
/// head, or -1 when the entry is gone.
pub fn hLen(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = caller;
    results[0] = -1;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const doc = p.annotationDoc(@bitCast(args[0])) orelse return;
    results[0] = @intCast(doc.text().byteLen());
}

/// `annotate.read(handle, start, end, ptr, cap)` → bytes written. The read a
/// decorator needs to have anything to say about the entry; it grants nothing
/// beyond reading text the guest could already open.
pub fn hRead(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    results[0] = 0;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const doc = p.annotationDoc(@bitCast(args[0])) orelse return;
    const rope = doc.text();
    const len = rope.byteLen();
    const s = @min(@as(usize, @intCast(@as(u32, @bitCast(args[1])))), len);
    const e = @min(@as(usize, @intCast(@as(u32, @bitCast(args[2])))), len);
    if (e <= s) return;
    const buf = p.gpa.alloc(u8, e - s) catch return;
    defer p.gpa.free(buf);
    var sr = rope.streamReader(.{ .start = s, .end = e }, &.{});
    sr.interface.readSliceAll(buf) catch return;
    results[0] = @intCast(caller.writeMemory(@intCast(args[3]), @intCast(args[4]), buf) catch 0);
}

/// `annotate.begin(handle)` → 1 when the round opened. Drops the previous set
/// and stamps the entry revision the spans about to be published are computed
/// against; they stop painting the moment the entry moves off it.
pub fn hBegin(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = caller;
    results[0] = 0;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const layer = p.annotationLayer(@bitCast(args[0])) orelse return;
    layer.begin(p.gpa);
    results[0] = 1;
}

/// `annotate.span(handle, start, end, role, placement, ptr, len)`: one
/// anchored span in the open round — a face over `[start, end)` (placement
/// 0), or a display-only decoration anchored at `start` carrying `text`.
pub fn hSpan(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = results;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const layer = p.annotationLayer(@bitCast(args[0])) orelse return;
    const placement: core_layers.Placement = switch (@as(u32, @bitCast(args[4]))) {
        0 => .range,
        1 => .virtual_before,
        2 => .virtual_after,
        3 => .eol,
        4 => .gutter,
        else => return,
    };
    const len = layer.doc.text().byteLen();
    const start = @min(@as(usize, @intCast(@as(u32, @bitCast(args[1])))), len);
    const end = @min(@max(start, @as(usize, @intCast(@as(u32, @bitCast(args[2]))))), len);
    if (placement == .range and end == start) return;
    const text = caller.readMemory(p.gpa, @intCast(args[5]), @intCast(args[6])) catch return;
    defer p.gpa.free(text);
    // No `face`: a decorator may not fold, conceal, or make a row clickable.
    // Those are the entry's own presentation to decide — an annotation says
    // what a range MEANS, and means nothing about who may act on it.
    layer.appendSpan(p.gpa, .{
        .start = start,
        .end = end,
        .kind = @bitCast(args[3]),
        .message = text,
        .placement = placement,
    }) catch {};
}
