//! Linux's word-wait for `futex.zig`: the raw `futex(2)` syscall, private to
//! this process. Linux-only by construction — `futex.zig` selects it on Linux
//! and on nothing else.

comptime {
    if (@import("builtin").os.tag != .linux) @compileError("futex_linux.zig is Linux-only");
}

const std = @import("std");
const linux = std.os.linux;

pub fn wait(ptr: *const u32, expected: u32, timeout_ns: ?u64) void {
    var ts: linux.timespec = undefined;
    const ts_ptr: ?*const linux.timespec = if (timeout_ns) |ns| blk: {
        ts = .{ .sec = @intCast(ns / std.time.ns_per_s), .nsec = @intCast(ns % std.time.ns_per_s) };
        break :blk &ts;
    } else null;
    // EAGAIN (the word moved), EINTR, ETIMEDOUT: the caller rechecks.
    _ = linux.futex_4arg(ptr, .{ .cmd = .WAIT, .private = true }, expected, ts_ptr);
}

/// `max_waiters` is read by the kernel as a SIGNED count — a negative one
/// wakes exactly one waiter instead of all (found the hard way: three parked
/// workers, one wake, a hung join) — so it is clamped to `maxInt(i32)`.
pub fn wake(ptr: *const u32, max_waiters: u32) void {
    _ = linux.futex_3arg(ptr, .{ .cmd = .WAKE, .private = true }, @min(max_waiters, std.math.maxInt(i32)));
}
