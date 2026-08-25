//! Transport + sync primitives shared across the session subsystem: the
//! byte-stream `Link` seam (a connected fd today, a chaos-injecting
//! wrapper in the tests) and the tiny futex `Mutex`/`futex*` helpers the
//! writer thread and the main tick contend on.

const std = @import("std");
const linux = std.os.linux;
const Allocator = std.mem.Allocator;
const task = @import("../task.zig");

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
        // shutdown() forces a read()/write() ALREADY blocked on this fd to
        // return at once — close() alone does not (the underlying file
        // description outlives the fd number, so a thread parked in read()
        // stays parked until the peer sends or closes). Without this, the
        // reader thread hangs in destroy() until the peer's next ~1s
        // heartbeat. Sockets only; ENOTSOCK on a non-socket fd is harmless.
        _ = linux.shutdown(self.fd, 2); // SHUT_RDWR
        _ = linux.close(self.fd);
    }
};

// ── Chaos link (fault injection without root) ───────────────────────

/// Wraps a Link with injected propagation latency and partitions. Writes are
/// copied into an ordered delivery queue and return once enqueued: real TCP
/// pipelines bytes rather than charging one full network delay to every
/// sender syscall. A single delivery worker releases each queued write at its
/// sampled deadline, preserving stream order even when later jitter samples
/// are shorter. Loss on a reliable stream remains a stall/partition.
///
/// Call `start` only after the ChaosLink has reached its stable address; the
/// delivery thread borrows `self`. `Link.close` joins it and is idempotent.
pub const ChaosLink = struct {
    gpa: Allocator = undefined,
    inner: Link = undefined,
    /// Deterministic one-way propagation model. Sampling belongs to the
    /// transport write boundary: renderer cadence and encoder backpressure can
    /// never alter which delay a queued write receives.
    latency_mutex: Mutex = .{},
    latency_base_ns: u64 = 0,
    latency_jitter_ns: u64 = 0,
    latency_seed: u64 = 0,
    latency_sample: u64 = 0,
    /// While true, delivery stalls (the cable is out).
    partitioned: std.atomic.Value(bool) = .init(false),
    park: std.atomic.Value(u32) = .init(0),
    mutex: Mutex = .{},
    head: ?*Pending = null,
    tail: ?*Pending = null,
    shutdown: std.atomic.Value(bool) = .init(false),
    failed: std.atomic.Value(bool) = .init(false),
    inner_closed: std.atomic.Value(bool) = .init(false),
    close_started: std.atomic.Value(bool) = .init(false),
    delivery_thread: ?std.Thread = null,

    const Pending = struct {
        next: ?*Pending = null,
        eligible_ns: u64,
        bytes: []u8,
    };

    pub fn start(self: *ChaosLink, gpa: Allocator, inner: Link) !void {
        self.* = .{ .gpa = gpa, .inner = inner };
        self.delivery_thread = try std.Thread.spawn(.{}, deliveryMain, .{self});
    }

    pub fn link(self: *ChaosLink) Link {
        std.debug.assert(self.delivery_thread != null);
        return .{ .ctx = self, .readFn = readC, .writeFn = writeC, .closeFn = closeC };
    }

    pub fn close(self: *ChaosLink) void {
        closeC(self);
    }

    /// Configure deterministic propagation latency for subsequent writes.
    /// Safe before or during use; resetting configuration starts a fresh
    /// sample sequence. Ordinary tests leave the zero defaults untouched.
    pub fn configureLatency(self: *ChaosLink, base_ns: u64, jitter_ns: u64, seed: u64) void {
        self.latency_mutex.lock();
        defer self.latency_mutex.unlock();
        self.latency_base_ns = base_ns;
        self.latency_jitter_ns = jitter_ns;
        self.latency_seed = seed;
        self.latency_sample = 0;
    }

    fn splitMix64(value: u64) u64 {
        var z = value +% 0x9e3779b97f4a7c15;
        z = (z ^ (z >> 30)) *% 0xbf58476d1ce4e5b9;
        z = (z ^ (z >> 27)) *% 0x94d049bb133111eb;
        return z ^ (z >> 31);
    }

    fn sampleLatency(self: *ChaosLink) u64 {
        self.latency_mutex.lock();
        defer self.latency_mutex.unlock();
        const base = self.latency_base_ns;
        const span = self.latency_jitter_ns;
        if (span == 0) return base;
        const ordinal = self.latency_sample;
        self.latency_sample +%= 1;
        const sample = splitMix64(self.latency_seed +% ordinal *% 0x9e3779b97f4a7c15);
        const extra = if (span == std.math.maxInt(u64)) sample else sample % (span + 1);
        return base +| extra;
    }

    fn readC(ctx: ?*anyopaque, buf: []u8) anyerror!usize {
        const self: *ChaosLink = @ptrCast(@alignCast(ctx.?));
        return self.inner.read(buf);
    }

    fn writeC(ctx: ?*anyopaque, bytes: []const u8) anyerror!void {
        const self: *ChaosLink = @ptrCast(@alignCast(ctx.?));
        if (self.shutdown.load(.acquire) or self.failed.load(.acquire)) return error.LinkBroken;

        const node = try self.gpa.create(Pending);
        errdefer self.gpa.destroy(node);
        const owned = try self.gpa.dupe(u8, bytes);
        errdefer self.gpa.free(owned);
        const lat = self.sampleLatency();
        node.* = .{ .eligible_ns = task.nowNs() +| lat, .bytes = owned };

        self.mutex.lock();
        defer self.mutex.unlock();
        // closeC may have started while allocation was in progress.
        if (self.shutdown.load(.acquire) or self.failed.load(.acquire)) return error.LinkBroken;
        if (self.tail) |tail| {
            tail.next = node;
        } else {
            self.head = node;
        }
        self.tail = node;
        _ = self.park.fetchAdd(1, .release);
        futexWake(&self.park, 1);
        // Queue owns both allocations from here.
        return;
    }

    fn closeC(ctx: ?*anyopaque) void {
        const self: *ChaosLink = @ptrCast(@alignCast(ctx.?));
        if (self.close_started.swap(true, .acq_rel)) return;
        self.shutdown.store(true, .release);
        self.partitioned.store(false, .release);
        _ = self.park.fetchAdd(1, .release);
        futexWake(&self.park, std.math.maxInt(i32));
        self.closeInner();
        if (self.delivery_thread) |thread| thread.join();
        self.delivery_thread = null;
        self.discardPending();
    }

    fn closeInner(self: *ChaosLink) void {
        if (!self.inner_closed.swap(true, .acq_rel)) self.inner.close();
    }

    fn discardPending(self: *ChaosLink) void {
        self.mutex.lock();
        var node = self.head;
        self.head = null;
        self.tail = null;
        self.mutex.unlock();
        while (node) |pending| {
            node = pending.next;
            self.gpa.free(pending.bytes);
            self.gpa.destroy(pending);
        }
    }

    fn deliveryMain(self: *ChaosLink) void {
        while (!self.shutdown.load(.acquire)) {
            if (self.partitioned.load(.acquire)) {
                const generation = self.park.load(.acquire);
                futexWaitTimed(&self.park, generation, 20 * std.time.ns_per_ms);
                continue;
            }

            self.mutex.lock();
            const pending = self.head;
            self.mutex.unlock();
            const node = pending orelse {
                const generation = self.park.load(.acquire);
                if (!self.shutdown.load(.acquire))
                    futexWaitTimed(&self.park, generation, 20 * std.time.ns_per_ms);
                continue;
            };

            const now = task.nowNs();
            if (now < node.eligible_ns) {
                const generation = self.park.load(.acquire);
                futexWaitTimed(&self.park, generation, @min(node.eligible_ns - now, 20 * std.time.ns_per_ms));
                continue;
            }

            self.mutex.lock();
            // This worker is the only consumer, so the peeked FIFO head cannot
            // change while the lock is released; producers only append.
            std.debug.assert(self.head == node);
            self.head = node.next;
            if (self.head == null) self.tail = null;
            self.mutex.unlock();

            self.inner.write(node.bytes) catch {
                self.gpa.free(node.bytes);
                self.gpa.destroy(node);
                self.failed.store(true, .release);
                self.shutdown.store(true, .release);
                self.closeInner();
                _ = self.park.fetchAdd(1, .release);
                futexWake(&self.park, std.math.maxInt(i32));
                return;
            };
            self.gpa.free(node.bytes);
            self.gpa.destroy(node);
        }
    }
};
