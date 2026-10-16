//! What a read hands back lives until the host calls this plugin again.
//!
//! The SDK's reads (`weft.path()`, `slice`, `argStr`, `config`, …) fill
//! scratch buffers the host writes into, and they used to return slices OF
//! those buffers — so the next read of the same kind, often hidden inside an
//! unrelated SDK call, overwrote the first one's answer underneath its holder.
//! A plugin that read a path, then focused a buffer, then used the path, ran
//! a command named after whatever the focus read had left there.
//!
//! Now every such slice is copied (`keep`) into an ENTRY arena: memory that
//! stays valid for the whole host→guest call it was read in — a command, a
//! poll, a delivery, however many reads follow — and is reclaimed when the
//! host next calls in from the top. A value kept past that (in a global) is
//! the plugin's to copy, as it always was. Nested entries (a command that runs
//! another of this plugin's commands) share the outer entry's arena.

const std = @import("std");

var arena_state: std.heap.ArenaAllocator = .init(std.heap.wasm_allocator);
var depth: u32 = 0;

/// Above this, an entry's reads are given back to the system on the next one
/// rather than kept for reuse.
const retain_limit = 1 << 20;

/// The host is calling in. The outermost call starts a fresh arena.
pub fn enter() void {
    if (depth == 0) {
        _ = arena_state.reset(if (arena_state.queryCapacity() > retain_limit) .free_all else .retain_capacity);
    }
    depth += 1;
}

pub fn leave() void {
    depth -= 1;
}

/// `bytes` (a slice of a scratch the next read will overwrite), copied into
/// memory that lives until the host's next call into this plugin. Out of
/// memory, the scratch slice itself — what every read returned before.
pub fn keep(bytes: []const u8) []const u8 {
    if (bytes.len == 0) return bytes;
    return arena_state.allocator().dupe(u8, bytes) catch bytes;
}

/// `keep` for a read that hands back a mutable slice.
pub fn keepMut(bytes: []u8) []u8 {
    if (bytes.len == 0) return bytes;
    return arena_state.allocator().dupe(u8, bytes) catch bytes;
}

/// Wrap `function` so the call is an entry: `enter` before, `leave` after.
pub fn wrap(comptime function: anytype) *const @typeInfo(@TypeOf(function)).pointer.child {
    const F = @typeInfo(@TypeOf(function)).pointer.child;
    const info = @typeInfo(F).@"fn";
    const R = info.return_type.?;
    const P = info.params;
    return switch (P.len) {
        0 => &struct {
            fn f() callconv(.c) R {
                enter();
                defer leave();
                return function();
            }
        }.f,
        1 => &struct {
            fn f(a: P[0].type.?) callconv(.c) R {
                enter();
                defer leave();
                return function(a);
            }
        }.f,
        2 => &struct {
            fn f(a: P[0].type.?, b: P[1].type.?) callconv(.c) R {
                enter();
                defer leave();
                return function(a, b);
            }
        }.f,
        3 => &struct {
            fn f(a: P[0].type.?, b: P[1].type.?, c: P[2].type.?) callconv(.c) R {
                enter();
                defer leave();
                return function(a, b, c);
            }
        }.f,
        4 => &struct {
            fn f(a: P[0].type.?, b: P[1].type.?, c: P[2].type.?, d: P[3].type.?) callconv(.c) R {
                enter();
                defer leave();
                return function(a, b, c, d);
            }
        }.f,
        5 => &struct {
            fn f(a: P[0].type.?, b: P[1].type.?, c: P[2].type.?, d: P[3].type.?, e: P[4].type.?) callconv(.c) R {
                enter();
                defer leave();
                return function(a, b, c, d, e);
            }
        }.f,
        else => @compileError("an exported callback with more than five parameters"),
    };
}
