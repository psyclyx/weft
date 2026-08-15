//! Frame/latency accounting — present from day one so the 60fps gate is
//! measured, not assumed. Two rings: whole-frame CPU time, and
//! keystroke→submit latency (the input→commit→render path the
//! architecture promises never blocks).

const std = @import("std");

/// Monotonic clock read via the raw syscall (std.time.Timer is gone in
/// 0.16 and the std.Io clock would thread an Io instance through the
/// hot loop for one register read).
pub fn nowNs() u64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

pub const Ring = struct {
    buf: [512]u64 = undefined,
    len: usize = 0,
    next: usize = 0,

    pub fn push(self: *Ring, v: u64) void {
        self.buf[self.next] = v;
        self.next = (self.next + 1) % self.buf.len;
        if (self.len < self.buf.len) self.len += 1;
    }

    /// p in [0,100]. 0 when empty.
    pub fn percentileNs(self: *const Ring, p: u64) u64 {
        if (self.len == 0) return 0;
        var sorted: [512]u64 = undefined;
        @memcpy(sorted[0..self.len], self.buf[0..self.len]);
        std.mem.sort(u64, sorted[0..self.len], {}, std.sort.asc(u64));
        const idx = @min(self.len - 1, (p * self.len) / 100);
        return sorted[idx];
    }
};

pub const Stats = struct {
    frame: Ring = .{},
    input: Ring = .{},
    frames_since_log: usize = 0,

    pub fn recordFrame(self: *Stats, ns: u64) void {
        self.frame.push(ns);
        self.frames_since_log += 1;
    }

    pub fn recordInput(self: *Stats, ns: u64) void {
        self.input.push(ns);
    }

    /// Log p50/p99 roughly every `every` frames; returns true when it did.
    pub fn maybeLog(self: *Stats, every: usize) bool {
        if (self.frames_since_log < every) return false;
        self.frames_since_log = 0;
        std.log.info(
            "frame p50={d:.2}ms p99={d:.2}ms | input→submit p50={d:.2}ms p99={d:.2}ms",
            .{
                @as(f64, @floatFromInt(self.frame.percentileNs(50))) / 1e6,
                @as(f64, @floatFromInt(self.frame.percentileNs(99))) / 1e6,
                @as(f64, @floatFromInt(self.input.percentileNs(50))) / 1e6,
                @as(f64, @floatFromInt(self.input.percentileNs(99))) / 1e6,
            },
        );
        return true;
    }
};

const t = std.testing;

test "ring percentiles" {
    var r: Ring = .{};
    for (0..100) |i| r.push(i);
    try t.expectEqual(@as(u64, 50), r.percentileNs(50));
    try t.expectEqual(@as(u64, 99), r.percentileNs(99));
    try t.expectEqual(@as(u64, 0), (Ring{}).percentileNs(50));
}
