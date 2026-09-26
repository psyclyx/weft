//! `wl_pointer` — the pointer facts of the dispatch in flight, for a guest.
//!
//! A command bound to a pointer gesture (`mouse-1`, `double-mouse-1`,
//! `drag-mouse-1`, …; `core/pointer.zig`) needs to know WHERE: the byte
//! offset and the scene node under the pointer. The host writes them onto
//! the head before dispatch (`Head.pointer`); this door reads them back.
//! Read-only and ungated — the facts describe the user's own gesture — and
//! one body shared with the JS plane (`qjs_pointer`), like the edit reads.
//!
//! Layout written at `out_ptr`, eight little-endian u32 words:
//!
//!     0 kind      0 none, 1 press, 2 release, 3 drag, 4 wheel, 5 hover
//!     1 button    1 primary, 2 middle, 3 secondary
//!     2 clicks    1, 2, 3 for a press
//!     3 mods      bit 0 ctrl, 1 alt, 2 shift, 3 logo
//!     4 offset    the byte offset under the pointer, or 0xffff_ffff
//!     5 node lo   the scene node under the pointer (low word)
//!     6 node hi   (high word)
//!     7 flags     bit 0 over a pane, 1 that pane is focused, 2 over a node
//!
//! The offset is in the entry under the pointer, which is the active one
//! once flag bit 1 is set — a click-through command focuses that pane first.
//! Returns 1 when the head has pointer facts at all, else 0.

const std = @import("std");
const wasm = @import("../wasm.zig");
const shared = @import("plugin.zig");
const Door = @import("../plugin_resources.zig").Door;
const pointer = @import("../pointer.zig");

pub const no_offset: u32 = 0xffff_ffff;

/// Pack a gesture into the door's word layout (see the module doc).
pub fn encode(g: pointer.Gesture) [8]u32 {
    const kind: u32 = switch (g.kind) {
        .none => 0,
        .press => 1,
        .release => 2,
        .drag => 3,
        .wheel => 4,
        .hover => 5,
    };
    const node: u64 = if (g.hit.node) |n| @intFromEnum(n.node) else 0;
    var flags: u32 = 0;
    if (g.hit.pane != null) flags |= 1;
    if (g.hit.focused) flags |= 2;
    if (g.hit.node != null) flags |= 4;
    return .{
        kind,
        g.button,
        g.clicks,
        @as(u4, @bitCast(g.mods)),
        if (g.hit.offset) |off| @intCast(@min(off, no_offset - 1)) else no_offset,
        @truncate(node),
        @truncate(node >> 32),
        flags,
    };
}

pub fn pointerBody(d: Door, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    const g = d.ctx.head.pointer;
    if (g.kind == .none) {
        results[0] = 0;
        return;
    }
    const words = encode(g);
    _ = caller.writeMemory(@intCast(args[0]), @sizeOf(@TypeOf(words)), std.mem.asBytes(&words)) catch {
        results[0] = 0;
        return;
    };
    results[0] = 1;
}
pub const hPointer = shared.wasmDoor(pointerBody, null);

const t = std.testing;

test "wl_pointer: the gesture packs into the documented words" {
    var g: pointer.Gesture = .{
        .kind = .press,
        .button = 1,
        .clicks = 2,
        .mods = .{ .ctrl = true, .shift = true },
        .hit = .{ .pane = .{ .id = 0, .gen = 1 }, .focused = true, .offset = 42 },
    };
    try t.expectEqual([8]u32{ 1, 1, 2, 0b101, 42, 0, 0, 0b011 }, encode(g));
    g.hit.offset = null;
    g.hit.node = .{ .view = undefined, .node = @enumFromInt(0x1_0000_0002) };
    g.kind = .drag;
    try t.expectEqual([8]u32{ 3, 1, 2, 0b101, no_offset, 2, 1, 0b111 }, encode(g));
}
