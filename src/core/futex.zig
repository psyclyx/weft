//! futex — park a thread on a 32-bit word until another thread changes it
//! and says so. The one primitive weft's own locks and latches stand on
//! (`task.Mutex`/`task.Gate`/the pool's parking, `session/link.zig`'s
//! writer wake): `std.Thread.Futex` left std in 0.16 and its `std.Io`
//! replacement would drag an `Io` instance through every lock for two
//! system calls.
//!
//! Per OS, the kernel's own word-wait: Linux's `futex(2)` (its raw syscall
//! lives in the Linux-only `futex_linux.zig`, so this file names no Linux
//! interface), Darwin's `__ulock_wait2`/`__ulock_wake` — the private-but-
//! stable libSystem entry points libpthread and Zig's own `std.Io.Threaded`
//! park on. Any other OS is a compile error, not a silent spin.
//!
//! Semantics are the futex contract on both: `wait` returns when woken, when
//! `word` no longer holds `expected` at the moment of the call, on a signal,
//! or after `timeout_ns` (null: no deadline) — so every caller loops on its
//! own condition and treats a return as "recheck", never as "it changed".
//! `wake` never blocks.

const std = @import("std");
const builtin = @import("builtin");

const Word = std.atomic.Value(u32);

const impl = switch (builtin.os.tag) {
    .linux => @import("futex_linux.zig"),
    .macos, .ios, .tvos, .visionos, .watchos, .maccatalyst, .driverkit => Darwin,
    else => @compileError("futex: no word-wait for this OS"),
};

/// Park until woken while `word` holds `expected`, or `timeout_ns` passes.
/// Spurious returns are allowed: the caller rechecks.
pub fn wait(word: *const Word, expected: u32, timeout_ns: ?u64) void {
    impl.wait(&word.raw, expected, timeout_ns);
}

/// Wake up to `max_waiters` threads parked on `word` (`all` for every one).
pub fn wake(word: *const Word, max_waiters: u32) void {
    impl.wake(&word.raw, max_waiters);
}

/// Every waiter: the count the kernel reads as "all" on each OS.
pub const all: u32 = std.math.maxInt(i32);

const Darwin = struct {
    const c = std.c;
    /// `__ulock_wait2` (nanosecond timeouts) arrived in macOS 11; before it,
    /// `__ulock_wait` takes microseconds. 0 means "no timeout" to both.
    const has_wait2 = builtin.os.version_range.semver.min.major >= 11;

    fn wait(ptr: *const u32, expected: u32, timeout_ns: ?u64) void {
        const flags: c.UL = .{ .op = .COMPARE_AND_WAIT, .NO_ERRNO = true };
        // EINTR, ETIMEDOUT, EFAULT (the page holding the word was out): all
        // "recheck", which is every caller's loop anyway.
        if (has_wait2) {
            const ns: u64 = if (timeout_ns) |n| @max(n, 1) else 0;
            _ = c.__ulock_wait2(flags, ptr, expected, ns, 0);
        } else {
            const us: u32 = if (timeout_ns) |n| @max(std.math.lossyCast(u32, n / std.time.ns_per_us), 1) else 0;
            _ = c.__ulock_wait(flags, ptr, expected, us);
        }
    }

    fn wake(ptr: *const u32, max_waiters: u32) void {
        const flags: c.UL = .{ .op = .COMPARE_AND_WAIT, .NO_ERRNO = true, .WAKE_ALL = max_waiters > 1 };
        while (true) {
            const status = c.__ulock_wake(flags, ptr, 0);
            if (status >= 0) return;
            switch (@as(c.E, @enumFromInt(-status))) {
                .INTR, .CANCELED => continue,
                else => return, // ENOENT: nobody was parked there
            }
        }
    }
};

const t = std.testing;

test "futex: a wait on a word that already moved returns at once" {
    var w: Word = .init(1);
    wait(&w, 0, null);
}

test "futex: a parked thread wakes when the word changes" {
    var w: Word = .init(0);
    const Waiter = struct {
        fn run(word: *Word) void {
            while (word.load(.acquire) == 0) wait(word, 0, null);
        }
    };
    const th = try std.Thread.spawn(.{}, Waiter.run, .{&w});
    w.store(1, .release);
    wake(&w, all);
    th.join();
}
