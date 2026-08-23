//! proc_stream — a persistent DUPLEX child whose stdout a guest reads
//! incrementally, the generic primitive behind a line/JSON-RPC protocol peer
//! (an ACP coding agent, an LSP-shaped tool, a REPL that parses its output).
//!
//! Unlike `repl_session` (which drains a child's stdout INTO a buffer, authored
//! as the plugin's CRDT peer), this hands the raw bytes back to the guest to
//! parse: the off-thread reader appends stdout to a mutex-guarded accumulator,
//! and the frame thread pulls newly-arrived bytes with `read`. stderr is drained
//! SEPARATELY (discarded) so a chatty child can't block on a full pipe and so
//! diagnostics never corrupt the protocol stream on stdout.
//!
//! ASYNC SPAWN: `start()` is called synchronously from a wasm guest's export
//! (`lsp`'s `on_activate`, fired inline on file open — see `wasm_host/proc.zig`'s
//! `hProcSpawn`), which itself runs to completion on the frame thread — a wasm
//! guest entry cannot yield mid-call. So the fork+exec (`std.process.spawn`)
//! must NOT happen inline in `start()`: it moved onto the pool task that used
//! to be just the reader, so `start()` only allocates and enqueues — the
//! actual syscall (and any first-use page-fault/dynamic-link cost of a real
//! server binary) happens off the frame thread. `spawn_mutex` guards the
//! handoff: `send()` called before the child exists queues bytes into
//! `pending_out`, flushed the instant the pool task publishes `child`.
//!
//! Teardown is the same UAF-safe discipline as `repl_session`, extended for a
//! spawn that may still be in flight: `deinit` marks `canceled` (so a pool
//! task that hasn't spawned yet reaps its own child immediately instead of
//! entering the read loop), then spins — killing the child the moment it
//! becomes visible — until the pool task (JOIN) finishes, then reaps. Every
//! blocking step is off the hot path (`deinit` runs at shutdown / plugin
//! unload).

const std = @import("std");
const Allocator = std.mem.Allocator;
const task = @import("task.zig");

pub const SpawnError = error{ProcessSpawnFailed} || Allocator.Error;

/// `deinit`'s bound on waiting for a saturated pool (see its doc): generous
/// like `proc.zig`'s `toolAvailable` 5s bound (task #23) — something that
/// should start near-instantly, loudly reported if it doesn't. Only
/// approached when every pool worker is pinned in another stream's read
/// loop for that child's whole lifetime (the pre-existing capacity property
/// `spawnAndRead`'s doc names) — never in the common case.
const default_deinit_deadline_ns = 5 * std.time.ns_per_s;

pub const ProcStream = struct {
    gpa: Allocator,
    io_threaded: std.Io.Threaded, // frame-thread io (stdin writes)
    /// Valid only once `spawned` is true (guarded by `spawn_mutex`) — the pool
    /// task that owns the fork+exec publishes it; nobody else may touch it
    /// before that, and only the pool task touches it (read side) after.
    child: std.process.Child = undefined,
    argv_cmd: []u8, // owned copy: the caller's `cmd` may not outlive `start()`
    cwd_copy: ?[]u8,
    environ: std.process.Environ,
    spawn_mutex: task.Mutex = .{},
    spawned: bool = false,
    spawn_failed: bool = false,
    /// Set by `deinit` to tell the pool task, if the fork+exec hasn't landed
    /// yet, to reap its own child and return without entering the read loop —
    /// `deinit`'s kill-by-pid can't reach a child it never learned the pid of.
    canceled: std.atomic.Value(bool) = .init(false),
    /// Compiled into production (this is a real field, not `if (builtin.is_test)`
    /// cfg'd out) but only ever non-null via the test-only `startTesting` entry
    /// point below — production `start()` always passes `null`. Called on the
    /// pool task immediately before `std.process.spawn` — lets a test hold the
    /// fork+exec open deterministically (not via a wall-clock race) so it can
    /// prove `start()` already returned and `send()` already queued before the
    /// child exists.
    pre_spawn_hook: ?*const fn () void = null,
    /// Same shape as `pre_spawn_hook`, production-surface-but-test-only-set:
    /// called on the pool task WHILE STILL HOLDING `spawn_mutex`, after the
    /// queued flush's target (`s.child`) is set but before the flush write —
    /// lets a test prove a concurrent `send()` genuinely blocks on the mutex
    /// during the flush (mutual exclusion), not just that the bytes happen to
    /// land in order. Set via `setMidFlushHookForTesting` (only safe to call
    /// before the spawn has progressed this far — pair it with a still-closed
    /// `pre_spawn_hook` gate).
    mid_flush_hook: ?*const fn () void = null,
    /// `send()` calls that raced the still-in-flight spawn queue here;
    /// flushed to the child's stdin the instant it's published.
    pending_out: std.ArrayList(u8) = .empty,
    out_mutex: task.Mutex = .{},
    out_buf: std.ArrayList(u8) = .empty,
    /// Bytes already handed to `read`. The buffer resets once fully drained, so
    /// steady-state memory is one frame's worth of output, not the whole run.
    cursor: usize = 0,
    reader: task.Handle(void),
    /// How long `deinit` waits for this stream's pool task to even START
    /// (not finish — see `deinit`'s doc) before giving up. Per-instance so a
    /// test can shrink it (`setDeinitDeadlineForTesting`) instead of paying
    /// the real production bound; defaults to it otherwise.
    deinit_deadline_ns: u64 = default_deinit_deadline_ns,

    /// Enqueue `cmd` (via `/bin/sh -c`, matching the other proc doors) to spawn
    /// as a persistent child with piped stdio, in `cwd` (null = weft's cwd).
    /// Returns immediately — allocation only. The fork+exec itself, and the
    /// reader loop after it, run on the pool (see the file doc: a wasm guest
    /// export like `lsp`'s `on_activate` runs to completion on the frame
    /// thread, so it must never be the one blocking on a subprocess's exec).
    /// `environ` is the child's environment — pass weft's block so the child
    /// resolves `PATH` (an agent needs it); `.empty` is a hermetic child (only
    /// sh builtins / absolute argv).
    pub fn start(gpa: Allocator, pool: *task.Pool, cmd: []const u8, cwd: ?[]const u8, environ: std.process.Environ) SpawnError!*ProcStream {
        return startImpl(gpa, pool, cmd, cwd, environ, null);
    }

    /// Test-only: like `start`, but `hook` runs on the pool task right before
    /// the fork+exec, so a test can gate it open/closed deterministically
    /// instead of racing a wall clock against a real subprocess spawn.
    pub fn startTesting(gpa: Allocator, pool: *task.Pool, cmd: []const u8, cwd: ?[]const u8, environ: std.process.Environ, hook: *const fn () void) SpawnError!*ProcStream {
        return startImpl(gpa, pool, cmd, cwd, environ, hook);
    }

    /// Test-only: install `mid_flush_hook` (see its doc). Only meaningful
    /// while the pool task hasn't reached the flush yet — call this right
    /// after `startTesting` with a still-closed `pre_spawn_hook` gate.
    pub fn setMidFlushHookForTesting(s: *ProcStream, hook: *const fn () void) void {
        s.mid_flush_hook = hook;
    }

    /// Test-only: shrink `deinit`'s saturated-pool bound so a test can prove
    /// it's bounded without paying the real (5s) production wait.
    pub fn setDeinitDeadlineForTesting(s: *ProcStream, ns: u64) void {
        s.deinit_deadline_ns = ns;
    }

    fn startImpl(gpa: Allocator, pool: *task.Pool, cmd: []const u8, cwd: ?[]const u8, environ: std.process.Environ, hook: ?*const fn () void) SpawnError!*ProcStream {
        const s = try gpa.create(ProcStream);
        errdefer gpa.destroy(s);
        const cmd_dup = try gpa.dupe(u8, cmd);
        errdefer gpa.free(cmd_dup);
        const cwd_dup = if (cwd) |p| try gpa.dupe(u8, p) else null;
        errdefer if (cwd_dup) |p| gpa.free(p);
        s.* = .{
            .gpa = gpa,
            .io_threaded = .init(gpa, .{ .environ = environ }),
            .argv_cmd = cmd_dup,
            .cwd_copy = cwd_dup,
            .environ = environ,
            .pre_spawn_hook = hook,
            .reader = undefined,
        };
        errdefer s.io_threaded.deinit();
        s.reader = pool.spawn(spawnAndRead, .{s}) catch return error.ProcessSpawnFailed;
        return s;
    }

    /// Frame thread (or a test): whether the fork+exec has landed and `child`
    /// is live. A seam for tests that need to prove something DIDN'T wait for
    /// it, not wall-clock timing.
    pub fn isSpawned(s: *ProcStream) bool {
        s.spawn_mutex.lock();
        defer s.spawn_mutex.unlock();
        return s.spawned;
    }

    /// Frame thread (or a test): bytes queued by `send()` that haven't been
    /// flushed to the child's stdin yet (because the spawn hadn't landed when
    /// they were sent).
    pub fn pendingSendBytes(s: *ProcStream) usize {
        s.spawn_mutex.lock();
        defer s.spawn_mutex.unlock();
        return s.pending_out.items.len;
    }

    /// Pool task: fork+exec off the frame thread, publish `child` (unblocking
    /// any `send()` that queued while this was in flight), then run the same
    /// reader loop the old synchronous-spawn version ran. If `deinit` gave up
    /// waiting on us before the child existed (`canceled`), reap it ourselves
    /// and return without publishing — `deinit` never learned this pid and
    /// won't try to kill it, so leaving without reaping would zombie it.
    fn spawnAndRead(s: *ProcStream) void {
        var threaded: std.Io.Threaded = .init(s.gpa, .{ .environ = s.environ });
        defer threaded.deinit();
        const io = threaded.io();

        if (s.pre_spawn_hook) |h| h();

        var child = std.process.spawn(io, .{
            .argv = &.{ "/bin/sh", "-c", s.argv_cmd },
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .pipe,
            .cwd = if (s.cwd_copy) |p| .{ .path = p } else .inherit,
        }) catch {
            s.spawn_mutex.lock();
            s.spawn_failed = true;
            s.spawn_mutex.unlock();
            return;
        };

        if (s.canceled.load(.acquire)) {
            if (child.id) |id| std.posix.kill(id, std.posix.SIG.KILL) catch {};
            _ = child.wait(io) catch {};
            return;
        }

        // Flush `pending_out` to the real stdin WHILE STILL HOLDING
        // `spawn_mutex`, and only flip `spawned` true once that flush has
        // fully landed. `send()` takes the same lock and branches on
        // `spawned` — if it flipped true BEFORE the flush (as an earlier
        // version of this code did), a `send()` racing in right then would
        // see `spawned == true`, skip the queue, and write directly, landing
        // on the fd BEFORE (or byte-interleaved with, for a message bigger
        // than PIPE_BUF) the queued bytes it was supposed to follow. Holding
        // the lock across the write serializes every stdin writer behind
        // whatever queued while the spawn was in flight, in order.
        s.spawn_mutex.lock();
        s.child = child;
        var queued = s.pending_out;
        s.pending_out = .empty;
        if (s.mid_flush_hook) |h| h(); // test-only seam: see its own doc
        if (queued.items.len > 0) {
            if (s.child.stdin) |stdin| stdin.writeStreamingAll(io, queued.items) catch {};
        }
        s.spawned = true;
        s.spawn_mutex.unlock();
        queued.deinit(s.gpa);

        // STRUCTURAL NOTE (pre-existing, not introduced by the async-spawn
        // change above): this blocks on the pool worker it's running on for
        // the child's WHOLE LIFETIME — a persistent stream (LSP/ACP/REPL)
        // monopolizes one worker from here until the child exits or is
        // killed. `repl_session.zig` has the identical shape. N such live
        // streams saturate a pool (default `min(4, cpus-1)`; the harness
        // uses 2), so `start()`'s pool task for stream N+1 may never even
        // begin — `deinit`'s bounded-wait fallback below exists because of
        // this. The real fix is event/readiness-driven reads off
        // `core/scheduler.zig`'s fd-wake machinery instead of a thread
        // blocked in `fill`, so a live stream costs no dedicated worker —
        // out of scope here (a scheduler-level rework, not this task's
        // remit); named as a follow-up, not attempted.
        var mr_buf: std.Io.File.MultiReader.Buffer(2) = undefined;
        var mr: std.Io.File.MultiReader = undefined;
        mr.init(s.gpa, io, mr_buf.toStreams(), &.{ s.child.stdout.?, s.child.stderr.? });
        defer mr.deinit();
        while (mr.fill(256, .none)) |_| {
            const out = mr.reader(0);
            const out_chunk = out.buffered();
            if (out_chunk.len > 0) {
                s.out_mutex.lock();
                s.out_buf.appendSlice(s.gpa, out_chunk) catch {};
                s.out_mutex.unlock();
                out.toss(out_chunk.len);
            }
            const err = mr.reader(1);
            const err_chunk = err.buffered();
            if (err_chunk.len > 0) err.toss(err_chunk.len); // discard stderr
        } else |_| {} // EOF / read failure — the child is gone.
    }

    /// Frame thread: copy newly-arrived stdout into `out` (up to its length),
    /// advance past it, and return the count. Fully-drained → the buffer resets.
    pub fn read(s: *ProcStream, out: []u8) usize {
        s.out_mutex.lock();
        defer s.out_mutex.unlock();
        const avail = s.out_buf.items[s.cursor..];
        const n = @min(avail.len, out.len);
        @memcpy(out[0..n], avail[0..n]);
        s.cursor += n;
        if (s.cursor == s.out_buf.items.len) {
            s.out_buf.clearRetainingCapacity();
            s.cursor = 0;
        }
        return n;
    }

    /// Bytes waiting to be read (frame thread) — the frame loop fires the
    /// guest's output hook only when this is non-zero.
    pub fn pending(s: *ProcStream) usize {
        s.out_mutex.lock();
        defer s.out_mutex.unlock();
        return s.out_buf.items.len - s.cursor;
    }

    /// Frame thread: write `bytes` to stdin verbatim (the caller frames its own
    /// protocol — for NDJSON it appends the newline). The spawn may still be
    /// in flight (fork+exec runs on the pool now) — in that case the bytes
    /// queue in `pending_out` and the pool task flushes them the moment it
    /// publishes `child`, so a request fired right after `start()` (the LSP
    /// guest's `initialize`, sent inline on `on_activate`) is never lost.
    pub fn send(s: *ProcStream, bytes: []const u8) void {
        s.spawn_mutex.lock();
        if (!s.spawned) {
            defer s.spawn_mutex.unlock();
            if (s.spawn_failed) return; // never coming up — drop silently
            s.pending_out.appendSlice(s.gpa, bytes) catch {};
            return;
        }
        s.spawn_mutex.unlock();
        const stdin = s.child.stdin orelse return;
        stdin.writeStreamingAll(s.io_threaded.io(), bytes) catch {};
    }

    /// Kill the child, JOIN the reader (so it can't touch freed state), reap,
    /// and free. The single owner of teardown. The spawn may still be in
    /// flight when this runs (e.g. a language switch away from a server that
    /// hasn't finished forking yet): `canceled` tells the pool task to reap
    /// its own child rather than enter the read loop, but there's a window
    /// where the task publishes `child` right after we've already checked —
    /// so this spins, re-checking and killing the instant `child` appears,
    /// same as it would for a fully-spawned stream.
    ///
    /// BOUNDED, not unbounded (regression class 53aca18 closed elsewhere in
    /// this codebase — `proc.zig`'s deadline-bounded drain — reopened here by
    /// the async-spawn change unless guarded): `s.reader.poll()` only turns
    /// non-null once the pool task RUNS TO COMPLETION, and a saturated pool
    /// (every worker pinned in another live stream's `fill` loop — see
    /// `spawnAndRead`'s structural note) may never even START it. With
    /// nothing spawned there is no pid to kill, so the old unconditional
    /// `while (poll() == null)` spun the FRAME THREAD forever — the exact
    /// failure the old inline-fork code structurally could not have, since
    /// an inline fork always eventually completes.
    ///
    /// On deadline expiry: `canceled` is already set, so whenever the pool
    /// finally does run this task, it self-reaps its own child and returns
    /// without going near the read loop (the `canceled` branch above) — but
    /// it still holds a live `*ProcStream` until then, so freeing `s` now
    /// would be a use-after-free the moment the pool gets around to it. The
    /// only safe move is `detach()` (abandon the result — whichever of the
    /// pool / this call finishes second frees the task node) and LEAK `s`
    /// itself: no further access, ever, from here, so nothing after this
    /// point can race the eventually-running task. Loud (`log.warn`) because
    /// a leak that never surfaces is worse than one that does. This should
    /// never fire outside real pool exhaustion — see `spawnAndRead`'s
    /// structural note for the actual fix (event-driven reads instead of a
    /// worker blocked for a child's whole life); until that lands, this is
    /// the backstop.
    pub fn deinit(s: *ProcStream) void {
        const gpa = s.gpa;
        s.canceled.store(true, .release);
        var killed = false;
        const deadline = task.nowNs() + s.deinit_deadline_ns;
        while (s.reader.poll() == null) {
            if (!killed) {
                s.spawn_mutex.lock();
                const id_opt = if (s.spawned) s.child.id else null;
                s.spawn_mutex.unlock();
                if (id_opt) |id| {
                    std.posix.kill(id, std.posix.SIG.KILL) catch {};
                    killed = true;
                }
            }
            if (task.nowNs() >= deadline) {
                std.log.warn("proc_stream: deinit gave up after {d}ms waiting for a saturated pool (no free worker ever ran this stream's spawn) — leaking it; it self-reaps its child once the pool finally schedules it", .{s.deinit_deadline_ns / std.time.ns_per_ms});
                s.reader.detach();
                return; // deliberate leak — see the doc above; nothing past here
            }
            std.atomic.spinLoopHint();
        }
        s.spawn_mutex.lock();
        const spawned = s.spawned;
        s.spawn_mutex.unlock();
        if (spawned) _ = s.child.wait(s.io_threaded.io()) catch {};
        s.out_buf.deinit(gpa);
        s.pending_out.deinit(gpa);
        s.io_threaded.deinit();
        gpa.free(s.argv_cmd);
        if (s.cwd_copy) |p| gpa.free(p);
        gpa.destroy(s);
    }
};

// ── Tests ───────────────────────────────────────────────────────────

const t = std.testing;

test "proc_stream: duplex — write stdin, read stdout back" {
    const gpa = t.allocator;
    var pool = try task.Pool.init(gpa, .{ .threads = 2 });
    defer pool.deinit();

    // sh builtins only (read + printf), so the hermetic `.empty` environ needs
    // no PATH; the child reads a line and echoes it, then exits (flushing).
    var s = try ProcStream.start(gpa, pool, "read x; printf '%s\\n' \"$x\"", null, .empty);
    defer s.deinit();
    s.send("hello\n");

    var out: [64]u8 = undefined;
    var got: usize = 0;
    const deadline = task.nowNs() + 2 * std.time.ns_per_s;
    while (got < 6 and task.nowNs() < deadline) {
        const n = s.read(out[got..]);
        got += n;
        if (n == 0) std.atomic.spinLoopHint();
    }
    try t.expectEqualStrings("hello\n", out[0..got]);
    try t.expectEqual(@as(usize, 0), s.pending());
}

// The gates below are module-level (not stack locals) because
// `pre_spawn_hook` is a plain `*const fn () void` — no context pointer — so
// each hooked test needs its own addressable flag + closure. Reset at the
// top of each test rather than relying on zero-init, so test order/reruns
// can't leave a stale `true` behind.
var gate_deferred_spawn: std.atomic.Value(bool) = .init(false);
fn hookDeferredSpawn() void {
    while (!gate_deferred_spawn.load(.acquire)) std.atomic.spinLoopHint();
}

test "proc_stream: start() defers the fork+exec — a seam, not a wall-clock race" {
    // This is the host-side half of "file open must not block on LSP": a wasm
    // guest export (`lsp`'s `on_activate`, fired synchronously on open) calls
    // `procSpawn` and runs to completion on the frame thread — so the actual
    // fork+exec (and, for a real server, its binary's page-in/dynamic-link
    // cost) must not happen inside `start()`. `pre_spawn_hook` proves this
    // WITHOUT racing a clock: it parks the pool task immediately before
    // `std.process.spawn`, so `isSpawned()` is guaranteed false below no
    // matter how the OS schedules threads — there's a closed gate in the way,
    // not a hope that our check runs first.
    const gpa = t.allocator;
    var pool = try task.Pool.init(gpa, .{ .threads = 2 });
    defer pool.deinit();
    gate_deferred_spawn.store(false, .release);

    var s = try ProcStream.startTesting(gpa, pool, "read x; printf '%s\\n' \"$x\"", null, .empty, hookDeferredSpawn);
    defer s.deinit();

    try t.expect(!s.isSpawned()); // held at the gate: cannot have forked yet

    // A request fired right after `start()` — exactly what the `lsp` guest's
    // `ensureServer()` does (`conn.request("initialize", ...)` immediately
    // after `conn.start(cmd)`) — must queue, not block and not drop.
    s.send("hello\n");
    try t.expectEqual(@as(usize, 6), s.pendingSendBytes());
    try t.expect(!s.isSpawned());

    // Release the gate: the real fork+exec now runs, publishes `child`, and
    // flushes the queued bytes to its stdin.
    gate_deferred_spawn.store(true, .release);
    const deadline = task.nowNs() + 5 * std.time.ns_per_s;
    while (!s.isSpawned() and task.nowNs() < deadline) std.atomic.spinLoopHint();
    try t.expect(s.isSpawned());
    try t.expectEqual(@as(usize, 0), s.pendingSendBytes());

    // The child (`read x; printf ...`) echoes the queued line back — proof
    // the queue actually reached its real stdin, not just that a flag
    // flipped.
    var out: [64]u8 = undefined;
    var got: usize = 0;
    while (got < 6 and task.nowNs() < deadline) {
        const n = s.read(out[got..]);
        got += n;
        if (n == 0) std.atomic.spinLoopHint();
    }
    try t.expectEqualStrings("hello\n", out[0..got]);
}

var gate_cancel_race: std.atomic.Value(bool) = .init(false);
fn hookCancelRace() void {
    while (!gate_cancel_race.load(.acquire)) std.atomic.spinLoopHint();
}

test "proc_stream: canceled before the spawn lands reaps its own child — no hang, no touching undefined `child`" {
    // Mirrors what `deinit` actually does in production: it stamps
    // `canceled` as its very FIRST action, before it has any idea whether a
    // child exists yet (e.g. a language switch away from a server whose
    // fork+exec is still in flight). The pool task must notice, kill+reap
    // the child ITSELF (deinit never learned its pid), and return without
    // ever publishing `child` — so `deinit`'s own cleanup, which gates every
    // touch of `s.child` behind `spawned`, never reads that (deliberately
    // still-`undefined`) field.
    const gpa = t.allocator;
    var pool = try task.Pool.init(gpa, .{ .threads = 2 });
    defer pool.deinit();
    gate_cancel_race.store(false, .release);

    var s = try ProcStream.startTesting(gpa, pool, "read x; printf '%s\\n' \"$x\"", null, .empty, hookCancelRace);
    try t.expect(!s.isSpawned());

    s.canceled.store(true, .release); // what deinit() does first
    gate_cancel_race.store(true, .release); // let the (about-to-be-aborted) spawn proceed

    // Must return promptly: a hang here means the pool task never noticed
    // `canceled` and is stuck in the read loop; a crash means it touched
    // `s.child` (or `deinit` did) despite `spawned` staying false.
    s.deinit();
}

var gate_mid_flush: std.atomic.Value(bool) = .init(false);
// Set BEFORE parking: the test must not launch its concurrent `send()`
// until spawnAndRead has ALREADY taken `s.pending_out` and is holding
// `spawn_mutex` right here — otherwise the concurrent `send()` could win
// the race for the lock first (queueing into `pending_out` itself, quickly,
// since `spawned` is still false then too) and finish before spawnAndRead
// ever reaches this hook, which would prove nothing about mutual exclusion.
var reached_mid_flush: std.atomic.Value(bool) = .init(false);
fn hookMidFlush() void {
    reached_mid_flush.store(true, .release);
    while (!gate_mid_flush.load(.acquire)) std.atomic.spinLoopHint();
}

test "proc_stream: the queued flush happens under spawn_mutex — a concurrent send() can't race ahead of it" {
    // The ordering bug this guards: an earlier version set `spawned = true`
    // and unlocked BEFORE writing `pending_out` to the real stdin. A `send()`
    // racing in during that window would see `spawned == true`, skip the
    // queue, and write directly — landing on the fd before (or, for a
    // message bigger than PIPE_BUF, byte-interleaved with) the bytes it was
    // supposed to follow. Fixed shape: the flush now happens WHILE STILL
    // HOLDING `spawn_mutex`, and `spawned` only flips true after — so
    // `send()`'s own `spawn_mutex.lock()` cannot succeed until the flush has
    // fully landed. `mid_flush_hook` proves the mutual exclusion directly
    // (a concurrent `send()` provably BLOCKS, not just "happens to" finish
    // second), then the child's actual received bytes prove the ordering.
    const gpa = t.allocator;
    var pool = try task.Pool.init(gpa, .{ .threads = 2 });
    defer pool.deinit();
    gate_deferred_spawn.store(false, .release); // reused as this test's pre-spawn gate
    gate_mid_flush.store(false, .release);
    reached_mid_flush.store(false, .release);

    var s = try ProcStream.startTesting(gpa, pool, "read x; printf '%s' \"$x\"", null, .empty, hookDeferredSpawn);
    defer s.deinit();
    s.setMidFlushHookForTesting(hookMidFlush); // safe: pre-spawn gate is still closed

    // Queue "A" before the child exists — the exact shape `initialize` takes
    // right after `start()` in the `lsp` guest.
    s.send("A");
    try t.expectEqual(@as(usize, 1), s.pendingSendBytes());

    // Let the fork+exec proceed; spawnAndRead takes `s.pending_out` and
    // parks at the mid-flush gate — WHILE STILL HOLDING spawn_mutex. Wait
    // for it to actually get there before racing a `send()` against it —
    // see `hookMidFlush`'s doc for why this ordering matters to the test.
    gate_deferred_spawn.store(true, .release);
    {
        const deadline = task.nowNs() + 5 * std.time.ns_per_s;
        while (!reached_mid_flush.load(.acquire) and task.nowNs() < deadline) std.atomic.spinLoopHint();
        try t.expect(reached_mid_flush.load(.acquire));
    }

    var send_started: std.atomic.Value(bool) = .init(false);
    var send_done: std.atomic.Value(bool) = .init(false);
    const Ctx = struct {
        s: *ProcStream,
        started: *std.atomic.Value(bool),
        done: *std.atomic.Value(bool),
        fn run(self: @This()) void {
            self.started.store(true, .release);
            self.s.send("B\n"); // must block on spawn_mutex until the flush lands
            self.done.store(true, .release);
        }
    };
    const th = try std.Thread.spawn(.{}, Ctx.run, .{Ctx{ .s = s, .started = &send_started, .done = &send_done }});

    const start_deadline = task.nowNs() + 5 * std.time.ns_per_s;
    while (!send_started.load(.acquire) and task.nowNs() < start_deadline) std.atomic.spinLoopHint();
    try t.expect(send_started.load(.acquire));
    // Proof of mutual exclusion, not luck: give the scheduler every
    // reasonable chance to have run the concurrent send to completion if
    // `spawn_mutex` weren't actually held across the flush.
    for (0..200) |_| std.Thread.yield() catch {};
    try t.expect(!send_done.load(.acquire)); // still blocked on the held mutex

    // Release the flush: "A" (queued) is written, THEN `spawned` flips true,
    // and only THEN can the concurrent send acquire the lock and write "B".
    gate_mid_flush.store(true, .release);
    th.join();
    try t.expect(send_done.load(.acquire));

    // The child received "AB" — proof the flush's bytes reached the fd
    // before the concurrent send's did, not merely that `pending_out`'s
    // bookkeeping was cleared first (which happens either way).
    var out: [8]u8 = undefined;
    var got: usize = 0;
    const deadline = task.nowNs() + 5 * std.time.ns_per_s;
    while (got < 2 and task.nowNs() < deadline) {
        const n = s.read(out[got..]);
        got += n;
        if (n == 0) std.atomic.spinLoopHint();
    }
    try t.expectEqualStrings("AB", out[0..got]);
}

test "proc_stream: deinit on a saturated pool is bounded and leaves the pool sound (not an unbounded frame-thread spin)" {
    // The regression this guards: `deinit`'s old `while (reader.poll() ==
    // null) spin` had no deadline. `s.reader.poll()` only turns non-null
    // once the pool WORKER actually runs `spawnAndRead` to completion — and
    // `spawnAndRead` blocks on its worker for a live child's WHOLE lifetime
    // (the `mr.fill` loop). So N persistent streams (LSP+ACP+REPL) can
    // saturate a small pool, and the (N+1)th stream's `spawnAndRead` then
    // never even STARTS: `spawned` stays false forever, so `deinit`'s
    // kill-by-pid branch has nothing to kill, and the old code spun the
    // FRAME THREAD forever. The old inline-fork code structurally couldn't
    // have this failure (a fork always eventually completes) — this is a
    // regression the async-spawn change introduced unless guarded.
    //
    // Uses `std.heap.page_allocator`, not `t.allocator`: the fix's only safe
    // answer to "the pool task might still be running when the deadline
    // hits" is to LEAK the timed-out stream (never free under a pending
    // task — freeing here would itself be the use-after-free once that task
    // finally runs). That leak is the intended, tested behavior, not a bug
    // to report — `t.allocator`'s leak checker would fail the test for
    // exercising exactly the safety property under test.
    const gpa = std.heap.page_allocator;
    var pool = try task.Pool.init(gpa, .{ .threads = 1 }); // one worker: trivial to saturate
    defer pool.deinit();

    // Stream 1 monopolizes the sole worker: `read x` (a sh builtin — no
    // PATH needed under `.empty`) blocks forever with nothing sent to it and
    // nothing closing its stdin, so `spawnAndRead`'s `fill` loop never sees
    // output OR EOF — exactly the "pinned for the child's whole life" shape.
    var hog = try ProcStream.start(gpa, pool, "read x", null, .empty);
    {
        const deadline = task.nowNs() + 5 * std.time.ns_per_s;
        while (!hog.isSpawned() and task.nowNs() < deadline) std.atomic.spinLoopHint();
        try t.expect(hog.isSpawned()); // the sole worker is now pinned here
    }

    // Stream 2's `spawnAndRead` is queued but can never be popped — the pool
    // has no free worker, and won't until `hog` is torn down.
    var starved = try ProcStream.start(gpa, pool, "read x", null, .empty);
    starved.setDeinitDeadlineForTesting(200 * std.time.ns_per_ms); // don't pay the real 5s bound

    const t0 = task.nowNs();
    starved.deinit(); // must return near the shrunk deadline, never hang
    const elapsed_ms = (task.nowNs() - t0) / std.time.ns_per_ms;
    try t.expect(elapsed_ms < 2000); // generous bound above the 200ms deadline, not a perf gate
    try t.expect(!starved.isSpawned()); // confirms it really did time out unspawned, not race to a real answer

    // The pool itself is still sound afterward: freeing the hog frees the
    // worker, and a THIRD stream started fresh spawns normally — proving the
    // saturation was real (not e.g. a broken pool) and that leaking
    // `starved` didn't wedge anything else.
    hog.deinit();
    var third = try ProcStream.start(gpa, pool, "read x; printf '%s' \"$x\"", null, .empty);
    defer third.deinit();
    third.send("ok\n");
    var out: [8]u8 = undefined;
    var got: usize = 0;
    const deadline = task.nowNs() + 5 * std.time.ns_per_s;
    while (got < 2 and task.nowNs() < deadline) {
        const n = third.read(out[got..]);
        got += n;
        if (n == 0) std.atomic.spinLoopHint();
    }
    try t.expectEqualStrings("ok", out[0..got]);

    // With one worker, `starved`'s (detached) task and `third`'s share the
    // same FIFO queue: `starved`'s already ran to completion, self-reaping
    // its own child via the `canceled` branch in `spawnAndRead` and never
    // touching `starved` again, before `third`'s could even start — proven
    // by `third` having answered above at all. `starved` itself is
    // intentionally never freed (see `deinit`'s doc) — leaked on purpose, on
    // `page_allocator`, not `t.allocator`.
}

test {
    std.testing.refAllDecls(@This());
}
