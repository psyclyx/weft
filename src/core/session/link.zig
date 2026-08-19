//! Transport + sync primitives shared across the session subsystem: the
//! byte-stream `Link` seam (a connected fd today, a chaos-injecting
//! wrapper in the tests) and the tiny futex `Mutex`/`futex*` helpers the
//! writer thread and the main tick contend on.

const std = @import("std");
const linux = std.os.linux;

// ── Small primitives ────────────────────────────────────────────────

pub fn futexWaitTimed(word: *const std.atomic.Value(u32), expected: u32, timeout_ns: u64) void {
    var ts: linux.timespec = .{
        .sec = @intCast(timeout_ns / std.time.ns_per_s),
        .nsec = @intCast(timeout_ns % std.time.ns_per_s),
    };
    _ = linux.futex_4arg(&word.raw, .{ .cmd = .WAIT, .private = true }, expected, &ts);
}

pub fn futexWake(word: *const std.atomic.Value(u32), n: i32) void {
    _ = linux.futex_3arg(&word.raw, .{ .cmd = .WAKE, .private = true }, @intCast(n));
}

/// Futex mutex (std.Thread.Mutex left std in 0.16). Two contenders,
/// microsecond critical sections; never on the input hot section.
pub const Mutex = struct {
    state: std.atomic.Value(u32) = .init(0),

    pub fn lock(self: *Mutex) void {
        while (self.state.swap(1, .acquire) != 0) {
            futexWaitTimed(&self.state, 1, 10 * std.time.ns_per_ms);
        }
    }

    pub fn unlock(self: *Mutex) void {
        self.state.store(0, .release);
        futexWake(&self.state, 1);
    }
};

/// Byte-stream transport seam: TCP today, QUIC-shaped tomorrow, an
/// in-memory fault injector in the chaos tests.
pub const Link = struct {
    ctx: ?*anyopaque,
    readFn: *const fn (ctx: ?*anyopaque, buf: []u8) anyerror!usize,
    writeFn: *const fn (ctx: ?*anyopaque, bytes: []const u8) anyerror!void,
    closeFn: *const fn (ctx: ?*anyopaque) void,

    pub fn read(self: Link, buf: []u8) anyerror!usize {
        return self.readFn(self.ctx, buf);
    }
    pub fn write(self: Link, bytes: []const u8) anyerror!void {
        return self.writeFn(self.ctx, bytes);
    }
    pub fn close(self: Link) void {
        self.closeFn(self.ctx);
    }
};

/// A Link over a connected socket/pipe fd (raw syscalls; Linux-native).
pub const FdLink = struct {
    fd: i32,

    pub fn link(self: *FdLink) Link {
        return .{ .ctx = self, .readFn = readFd, .writeFn = writeFd, .closeFn = closeFd };
    }

    fn readFd(ctx: ?*anyopaque, buf: []u8) anyerror!usize {
        const self: *FdLink = @ptrCast(@alignCast(ctx.?));
        while (true) {
            const rc = linux.read(self.fd, buf.ptr, buf.len);
            switch (linux.errno(rc)) {
                .SUCCESS => return rc,
                .INTR => continue,
                else => return error.LinkBroken,
            }
        }
    }

    fn writeFd(ctx: ?*anyopaque, bytes: []const u8) anyerror!void {
        const self: *FdLink = @ptrCast(@alignCast(ctx.?));
        var rest = bytes;
        while (rest.len > 0) {
            const rc = linux.write(self.fd, rest.ptr, rest.len);
            switch (linux.errno(rc)) {
                .SUCCESS => rest = rest[rc..],
                .INTR => continue,
                else => return error.LinkBroken,
            }
        }
    }

    fn closeFd(ctx: ?*anyopaque) void {
        const self: *FdLink = @ptrCast(@alignCast(ctx.?));
        _ = linux.close(self.fd);
    }
};

// ── Chaos link (fault injection without root) ───────────────────────

/// Wraps a Link with injected latency and partitions. Stream semantics
/// are preserved (bytes delay or stall, never corrupt — loss on a
/// reliable stream is modeled as stall/partition, exactly what TCP
/// gives you on a lossy path).
pub const ChaosLink = struct {
    inner: Link,
    /// One-way added latency per write.
    latency_ns: std.atomic.Value(u64) = .init(0),
    /// While true, writes block (the cable is out).
    partitioned: std.atomic.Value(bool) = .init(false),
    park: std.atomic.Value(u32) = .init(0),

    pub fn link(self: *ChaosLink) Link {
        return .{ .ctx = self, .readFn = readC, .writeFn = writeC, .closeFn = closeC };
    }

    fn readC(ctx: ?*anyopaque, buf: []u8) anyerror!usize {
        const self: *ChaosLink = @ptrCast(@alignCast(ctx.?));
        return self.inner.read(buf);
    }

    fn writeC(ctx: ?*anyopaque, bytes: []const u8) anyerror!void {
        const self: *ChaosLink = @ptrCast(@alignCast(ctx.?));
        while (self.partitioned.load(.acquire)) {
            futexWaitTimed(&self.park, self.park.load(.acquire), 20 * std.time.ns_per_ms);
        }
        const lat = self.latency_ns.load(.acquire);
        if (lat > 0) futexWaitTimed(&self.park, self.park.load(.acquire), lat);
        return self.inner.write(bytes);
    }

    fn closeC(ctx: ?*anyopaque) void {
        const self: *ChaosLink = @ptrCast(@alignCast(ctx.?));
        self.partitioned.store(false, .release);
        self.inner.close();
    }
};
