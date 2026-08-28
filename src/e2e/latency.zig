//! Latency measurement machinery: statistics + the baseline artifact's shape
//! and (de)serialization. Deliberately knows nothing about the editor, the
//! keymap, or what "dispatch" means — it reduces a stream of `u64` nanosecond
//! samples to robust statistics, and reads/writes those statistics as ZON.
//! `harness.zig`'s `Editor.pressTimed` is the ONLY app-specific piece (it
//! produces the samples); `latency_test.zig` is the policy (which categories,
//! how many iterations, what counts as a regression). This file is the
//! decomplected middle: reusable by any future "time N repetitions of X and
//! compare to a committed baseline" instrument, not just this one.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

/// One category's reduced statistics — what actually gets compared/recorded.
pub const Stats = struct {
    median_ns: u64,
    p95_ns: u64,
};

/// Sort `samples` (in place) and reduce to median + p95. `samples.len` must be
/// nonzero.
pub fn statsOf(samples: []u64) Stats {
    std.mem.sort(u64, samples, {}, std.sort.asc(u64));
    const n = samples.len;
    const median = if (n % 2 == 0) (samples[n / 2 - 1] + samples[n / 2]) / 2 else samples[n / 2];
    const p95_idx = @min(n - 1, (n * 95) / 100);
    return .{ .median_ns = median, .p95_ns = samples[p95_idx] };
}

/// Time `iters` calls to `sample_fn(ctx)` (each call is expected to return the
/// elapsed nanoseconds of ONE unit of work, e.g. `Editor.pressTimed`'s
/// result), repeated over `runs` independent runs, and reduce to the MEDIAN
/// of each run's median/p95 — not the median of the pooled sample. A single
/// run's tail is vulnerable to one scheduler hiccup (this box is fast enough
/// that such a hiccup is common background noise, not signal); taking the
/// median across whole runs means one bad run is outvoted rather than
/// smeared across the reported number. `scratch` is reused across runs
/// (`iters` long) so the measurement itself allocates nothing per-sample.
pub fn measure(
    gpa: Allocator,
    scratch: []u64,
    runs: usize,
    iters: usize,
    ctx: anytype,
    comptime sample_fn: fn (@TypeOf(ctx)) u64,
) !Stats {
    std.debug.assert(scratch.len >= iters);
    const run_medians = try gpa.alloc(u64, runs);
    defer gpa.free(run_medians);
    const run_p95s = try gpa.alloc(u64, runs);
    defer gpa.free(run_p95s);
    for (0..runs) |r| {
        for (0..iters) |i| scratch[i] = sample_fn(ctx);
        const s = statsOf(scratch[0..iters]);
        run_medians[r] = s.median_ns;
        run_p95s[r] = s.p95_ns;
    }
    return .{
        .median_ns = statsOf(run_medians).median_ns,
        .p95_ns = statsOf(run_p95s).median_ns,
    };
}

// ── The committed baseline artifact ──────────────────────────────────

/// One category's recorded baseline (the unit `latency_baseline.zon` stores a
/// list of).
pub const CategoryBaseline = struct {
    name: []const u8,
    median_ns: u64,
    p95_ns: u64,
    /// Total timed samples the recorded numbers were reduced from (runs *
    /// iters) — informational, read by a human sanity-checking the file, not
    /// compared against.
    samples: usize,
};

pub const Baseline = struct {
    /// `buildModeName()` at record time. Compare mode HARD-FAILS on a
    /// mismatch (see `latency_test.zig`) — a Debug baseline and a
    /// ReleaseFast run aren't the same measurement, they're two different
    /// programs, and silently comparing them either always passes (Release
    /// is faster) or always fails (Debug is slower) for reasons that have
    /// nothing to do with a regression.
    build_mode: []const u8 = "",
    /// `hostName()` at record time. Compare mode SKIPS (not fails) on a
    /// mismatch — different hardware isn't a regression to gate on, but a
    /// silent pass/fail against a foreign machine's numbers isn't a
    /// meaningful comparison either.
    host: []const u8 = "",
    /// Free-text provenance (when + how it was recorded), informational only.
    note: []const u8 = "",
    /// `calibrate()` at record time — how fast this box was executing a fixed
    /// pure-CPU loop when the numbers below were taken.
    ///
    /// The third provenance check, and the one the other two implied but could
    /// not express: `build_mode` catches a different program and `host` catches
    /// different hardware, but the SAME program on the SAME hardware is still
    /// not comparable when the machine is busy. Thread CPU time removes
    /// descheduling, not SMT contention, cache pressure, or frequency scaling —
    /// a busy sibling core makes identical instructions take measurably longer
    /// ON cpu. Measured at compare time and used to SKIP, never to scale a
    /// threshold: a number nobody can reproduce is not a gate.
    ///
    /// Zero means a baseline recorded before this existed; the check is then
    /// skipped rather than guessed at.
    calibration_ns: u64 = 0,
    categories: []const CategoryBaseline,
};

/// A fixed, deterministic, pure-CPU workload — the yardstick `calibration_ns`
/// records. Deliberately touches no allocator, no syscall, and no memory beyond
/// a register: it has to measure how fast this box executes instructions right
/// now, not how fast anything in weft is.
pub fn calibrate() u64 {
    // MEMORY-bound, not register-bound, and that distinction is the whole
    // point. A pure-arithmetic loop runs at full speed on a machine whose
    // caches and memory bus are saturated — it under-reports exactly the
    // contention that perturbs dispatch, which is itself full of maps, trees,
    // and allocations. Measured that way it happily reported a healthy box
    // while the samples it was vouching for ran 3x slow.
    //
    // A dependent pointer chase over a working set well past L2 defeats the
    // prefetcher, so each step waits on the previous one's load and the loop
    // feels the same pressure the code under test does.
    const n = chase.len;
    if (chase[1] == 0) { // build once; index 1 is 0 only before the fill
        for (&chase, 0..) |*slot, i| slot.* = @intCast((i + 65_521) % n);
    }
    const start = threadCpuNs();
    var cur: u32 = 0;
    var i: usize = 0;
    while (i < 400_000) : (i += 1) cur = chase[cur];
    std.mem.doNotOptimizeAway(cur);
    return threadCpuNs() -| start;
}

/// 4 MiB — past any L2, so the chase above actually reaches memory. The stride
/// is odd and the length a power of two, so successive steps are coprime and
/// the walk is a single cycle covering every slot rather than a short orbit.
var chase: [1 << 20]u32 = @splat(0);

/// This thread's CPU time. Same clock the samples use, so the calibration and
/// the measurement inflate together under load — which is exactly what makes
/// their ratio meaningful.
pub fn threadCpuNs() u64 {
    var ts: std.os.linux.timespec = undefined;
    const rc = std.os.linux.clock_gettime(.THREAD_CPUTIME_ID, &ts);
    if (std.os.linux.errno(rc) != .SUCCESS) return 0;
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

/// The running binary's optimize mode name ("Debug", "ReleaseFast", …).
pub fn buildModeName() []const u8 {
    return @tagName(builtin.mode);
}

/// This machine's hostname into `buf` (best-effort; "unknown" if the
/// syscall fails) — baselines are host-specific, so this is provenance to
/// SKIP on a mismatch, never a value to gate pass/fail on.
pub fn hostName(buf: *[std.posix.HOST_NAME_MAX]u8) []const u8 {
    return std.posix.gethostname(buf) catch "unknown";
}

/// Wall-clock seconds since the epoch (raw syscall, matching
/// `core.task.nowNs`'s idiom — this std has no ambient `std.time.timestamp`
/// left to reach for). Provenance only, for the baseline's `note`.
pub fn epochSeconds() i64 {
    var ts: std.os.linux.timespec = undefined;
    const rc = std.os.linux.clock_gettime(.REALTIME, &ts);
    if (std.os.linux.errno(rc) != .SUCCESS) return 0;
    return ts.sec;
}

/// Load a committed baseline from `path` (repo-relative). Caller must
/// `std.zon.parse.free(gpa, result)` (the parsed value owns its strings/
/// slices — `fromSliceAlloc`, not `fromSlice`, since `Baseline` isn't
/// alloc-free).
pub fn loadBaseline(gpa: Allocator, path: []const u8) !Baseline {
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const src = try std.Io.Dir.cwd().readFileAllocOptions(threaded.io(), path, gpa, .unlimited, .of(u8), 0);
    defer gpa.free(src);
    return std.zon.parse.fromSliceAlloc(Baseline, gpa, src, null, .{});
}

/// Serialize `baseline` as ZON and write it to `path` (repo-relative),
/// replacing whatever is there — the record step's whole job.
pub fn saveBaseline(gpa: Allocator, path: []const u8, baseline: Baseline) !void {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try std.zon.stringify.serialize(baseline, .{}, &aw.writer);
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    try std.Io.Dir.cwd().writeFile(threaded.io(), .{
        .sub_path = path,
        .data = aw.writer.buffer[0..aw.writer.end],
    });
}

/// Find `name`'s entry in a loaded baseline, or null if the category is new
/// (no prior recording to compare against).
pub fn find(baseline: Baseline, name: []const u8) ?CategoryBaseline {
    for (baseline.categories) |c| {
        if (std.mem.eql(u8, c.name, name)) return c;
    }
    return null;
}
