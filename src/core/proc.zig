//! proc — a subprocess capability shaped by weft's one iron rule: the
//! input→commit→render path never blocks and never awaits. A subprocess
//! is a blocking, unbounded-latency thing (a child can run forever), so
//! it cannot be a call that returns bytes. Instead `spawn` forks the
//! child, hands the *draining* (read both pipes to EOF, then reap) to a
//! `task.Pool` worker, and returns a `Proc` the frame loop polls once per
//! frame. `poll` yields the captured `Result` when the drain finishes and
//! null until then; there is no `wait`, by design — the same discipline
//! `task.Handle` enforces mechanically.
//!
//! Killing is deliberately *not* routed through the worker's Io: the
//! frame thread signals the child's pid directly (`std.posix.kill`) so a
//! runaway child can be stopped without the caller ever touching a
//! blocking API. Closing the child's pipes gives the drain its EOF and
//! `wait` its `Term`, so `kill` and the drain rendezvous naturally. The
//! stored pid is a copy taken at spawn; once the drain has reaped, a late
//! `kill` races pid reuse — the standard POSIX hazard, mitigated by only
//! signalling before `poll`/`deinit` consumes the handle, and by
//! swallowing `ProcessNotFound`.
//!
//! Scope: only the local ("here") tier lives here — `argv` runs as a
//! child of this process. The peer/shell tiers (a command that runs on
//! the far side of a session, or inside a `ShellFs` shell) share this
//! poll-only surface but forward the request over a connection.
//! TODO(locus): peer/shell tiers forward via Conn/ShellFs — the tier
//! switch dispatches into the `.here` arm implemented below.

const std = @import("std");
const Allocator = std.mem.Allocator;

const task = @import("task.zig");

/// Errors from `spawn` itself (surfaced synchronously on the frame
/// thread). Draining failures come back through `poll` as `DrainError`.
pub const SpawnError = error{
    /// fork/exec failed — bad argv[0], permissions, resource limits.
    ProcessSpawnFailed,
} || Allocator.Error;

/// Errors surfaced by `poll` when the drain task could not produce a
/// clean capture.
pub const DrainError = error{
    /// A pipe read (or its cancellation) failed mid-drain; the capture is
    /// unusable.
    DrainFailed,
    /// Captured output crossed `Options.max_output_bytes`; the child was
    /// killed and the partial buffers discarded.
    OutputTooLong,
    /// `runDeadline`'s wall-clock bound elapsed before the child reached
    /// EOF; the child was killed and reaped, and any partial output
    /// discarded. A real, distinct answer — never folded into a silent
    /// empty `Result`, so a caller that only skips on a genuine "no such
    /// tool"/"command failed" can tell the difference from "we gave up
    /// waiting". `run` (no deadline) never produces this.
    Timeout,
} || Allocator.Error;

/// A finished child's captured output and how it ended. Owns its byte
/// buffers; free exactly once with `deinit`.
pub const Result = struct {
    stdout: []u8,
    stderr: []u8,
    term: std.process.Child.Term,

    pub fn deinit(self: *Result, gpa: Allocator) void {
        gpa.free(self.stdout);
        gpa.free(self.stderr);
        self.* = undefined;
    }

    /// The exit code for a normally-exited child; null when it died by
    /// signal (killed, crashed) or was stopped.
    pub fn exitCode(self: Result) ?u8 {
        return switch (self.term) {
            .exited => |code| code,
            else => null,
        };
    }

    /// A clean `exit 0`.
    pub fn succeeded(self: Result) bool {
        return switch (self.term) {
            .exited => |code| code == 0,
            else => false,
        };
    }
};

pub const Options = struct {
    /// The child's environment. Defaults to empty (a hermetic child);
    /// pass the parent block when the child needs `PATH` to resolve
    /// non-absolute argv or to find helper commands. argv[0] itself is
    /// always resolved against the *parent* PATH.
    environ: std.process.Environ = .empty,
    /// The child's stdin. Defaults to `/dev/null`; the drain only reads
    /// stdout/stderr, so a child that blocks on stdin would never reach
    /// EOF.
    stdin: std.process.SpawnOptions.StdIo = .ignore,
    /// Hard cap on total captured bytes (stdout+stderr). On overflow the
    /// child is killed and `poll` yields `error.OutputTooLong` rather than
    /// letting a chatty child exhaust memory off-thread.
    max_output_bytes: usize = 16 << 20,
    /// The child's working directory. `null` inherits weft's cwd; a path
    /// `chdir`s the child after fork (project-rooted spawns — grep/run/git/an
    /// agent in the project root, not wherever weft was launched).
    cwd: ?[]const u8 = null,
};

/// The `SpawnOptions.cwd` for an optional path (null = inherit weft's cwd).
fn cwdOf(path: ?[]const u8) std.process.Child.Cwd {
    return if (path) |p| .{ .path = p } else .inherit;
}

/// Per-child state owned by the drain task once `spawn` succeeds: the
/// worker's Io instance and the child handle. Heap-allocated so its
/// address is stable across the frame→worker handoff; the drain frees it.
const DrainCtx = struct {
    gpa: Allocator,
    threaded: std.Io.Threaded,
    child: std.process.Child,
    max_output_bytes: usize,
};

/// A spawned child the frame loop polls. Holds a pid *copy* for signalling
/// and the poll-only handle to the drain task; the child struct and Io
/// live in the drain task's `DrainCtx`.
pub const Proc = struct {
    gpa: Allocator,
    /// Copy of the child pid, valid for signalling until the drain reaps.
    pid: std.posix.pid_t,
    handle: task.Handle(DrainError!Result),
    /// Set once the handle has been consumed (by `poll` or `deinit`), so
    /// neither runs twice and `kill` no longer signals a possibly-reused
    /// pid.
    done: bool = false,

    /// Fork the child and submit its drain to the pool. Lock-free on the
    /// pool side, so this is safe to call from the frame thread. The child
    /// is running by the time this returns.
    pub fn spawn(
        gpa: Allocator,
        pool: *task.Pool,
        argv: []const []const u8,
        opts: Options,
    ) SpawnError!Proc {
        const ctx = try gpa.create(DrainCtx);
        errdefer gpa.destroy(ctx);
        ctx.* = .{
            .gpa = gpa,
            .threaded = .init(gpa, .{ .environ = opts.environ }),
            .child = undefined,
            .max_output_bytes = opts.max_output_bytes,
        };
        errdefer ctx.threaded.deinit();
        const io = ctx.threaded.io();
        ctx.child = std.process.spawn(io, .{
            .argv = argv,
            .stdin = opts.stdin,
            .stdout = .pipe,
            .stderr = .pipe,
            .cwd = cwdOf(opts.cwd),
        }) catch return error.ProcessSpawnFailed;
        errdefer ctx.child.kill(io);
        const pid = ctx.child.id.?;
        // Ownership of `ctx` transfers to the drain task on success. `.none`:
        // the frame loop owns bounding this one (poll + explicit `kill`),
        // not `drain` — see `Proc`'s doc comment.
        const handle = try pool.spawn(drain, .{ ctx, .none });
        return .{ .gpa = gpa, .pid = pid, .handle = handle };
    }

    /// Non-blocking: the captured `Result` (or a `DrainError`) once the
    /// drain finished, null while still in flight. Consumes the handle on
    /// completion.
    pub fn poll(self: *Proc) ?(DrainError!Result) {
        if (self.done) return null;
        const outcome = self.handle.poll() orelse return null;
        self.done = true;
        return outcome;
    }

    /// Force-terminate the child (SIGKILL). The closed pipes give the
    /// drain its EOF and `wait` its `Term`, so a subsequent `poll` still
    /// returns a `Result` (with `term == .signal`). No-op once the handle
    /// has been consumed. `ProcessNotFound` (already reaped) is ignored.
    pub fn kill(self: *Proc) void {
        if (self.done) return;
        std.posix.kill(self.pid, std.posix.SIG.KILL) catch {};
    }

    /// Teardown for a Proc abandoned before it finished: stop the child so
    /// the drain can complete, then spin the handle to completion and free
    /// the result (shutdown path — blocking is fine here, as in
    /// `Editor.deinit`). A Proc already consumed by `poll` needs nothing.
    pub fn deinit(self: *Proc) void {
        if (self.done) return;
        self.kill();
        while (true) {
            if (self.handle.poll()) |outcome| {
                if (outcome) |res| {
                    var r = res;
                    r.deinit(self.gpa);
                } else |_| {}
                break;
            }
            std.Thread.yield() catch {};
        }
        self.done = true;
    }
};

/// Run `argv` to completion SYNCHRONOUSLY and return its capture. This
/// blocks the calling thread on the child, so it must NOT run on the frame
/// thread — it is the body a `DeferredWork` (abi.editLater) or any pool
/// worker runs to shell out without the poll-handle dance. Same spawn+drain
/// as `Proc`, minus the pool handoff.
///
/// UNBOUNDED: waits for the child's own EOF, however long that takes. Right
/// for a plugin's own shell-out (wasm_host/proc.zig's git/run/grep/filter
/// jobs) — the command is the USER's choice, and capping it would silently
/// truncate a legitimate long-running build. A caller that does NOT trust
/// its child to finish on its own (a test harness shelling out to `command
/// -v`, a compiler, or a disk oracle it can't otherwise bound) wants
/// `runDeadline` instead.
pub fn run(gpa: Allocator, argv: []const []const u8, opts: Options) (SpawnError || DrainError)!Result {
    return runDeadline(gpa, argv, opts, .none);
}

/// Like `run`, but bounds the drain with `timeout` (a real wall-clock cap on
/// how long the child may take to finish, not a poll budget) instead of
/// waiting for EOF unconditionally. On expiry the child is killed and
/// reaped — so no zombie survives the call — and `error.Timeout` comes back:
/// a distinct, real answer, never a silent empty `Result`. `run(...)` is
/// just `runDeadline(..., .none)`.
pub fn runDeadline(gpa: Allocator, argv: []const []const u8, opts: Options, timeout: std.Io.Timeout) (SpawnError || DrainError)!Result {
    const ctx = try gpa.create(DrainCtx);
    ctx.* = .{
        .gpa = gpa,
        .threaded = .init(gpa, .{ .environ = opts.environ }),
        .child = undefined,
        .max_output_bytes = opts.max_output_bytes,
    };
    const io = ctx.threaded.io();
    ctx.child = std.process.spawn(io, .{
        .argv = argv,
        .stdin = opts.stdin,
        .stdout = .pipe,
        .stderr = .pipe,
        .cwd = cwdOf(opts.cwd),
    }) catch {
        ctx.threaded.deinit();
        gpa.destroy(ctx);
        return error.ProcessSpawnFailed;
    };
    return drain(ctx, timeout); // drain owns ctx now (frees it in every case)
}

/// The off-thread body: read both pipes to EOF (concurrently, so a full
/// stderr pipe can't deadlock a stdout drain), reap the child, and return
/// the owned capture. Frees its own `DrainCtx`.
///
/// `timeout` bounds the WHOLE drain, not each individual read: `.duration`
/// is resolved to a fixed `.deadline` once up front (mirroring
/// `Io.Timeout.toDeadline`'s own doc'd purpose) and that same absolute
/// deadline is handed to every `mr.fill` call in the loop below — otherwise
/// a chatty-but-eventually-hung child would keep resetting a per-call
/// "N seconds from now" duration and never actually time out. `.none`
/// (from `run`) makes every `fill` block until EOF, exactly as before.
fn drain(ctx: *DrainCtx, timeout: std.Io.Timeout) DrainError!Result {
    const gpa = ctx.gpa;
    const io = ctx.threaded.io();
    defer {
        ctx.threaded.deinit();
        gpa.destroy(ctx);
    }

    var mr_buf: std.Io.File.MultiReader.Buffer(2) = undefined;
    var mr: std.Io.File.MultiReader = undefined;
    mr.init(gpa, io, mr_buf.toStreams(), &.{ ctx.child.stdout.?, ctx.child.stderr.? });
    defer mr.deinit();

    const deadline = timeout.toDeadline(io);
    while (mr.fill(64, deadline)) |_| {
        const buffered = mr.reader(0).bufferedLen() + mr.reader(1).bufferedLen();
        if (buffered > ctx.max_output_bytes) {
            std.posix.kill(ctx.child.id.?, std.posix.SIG.KILL) catch {};
            _ = ctx.child.wait(io) catch {};
            return error.OutputTooLong;
        }
    } else |err| switch (err) {
        error.EndOfStream => {},
        error.Timeout => {
            std.posix.kill(ctx.child.id.?, std.posix.SIG.KILL) catch {};
            _ = ctx.child.wait(io) catch {};
            return error.Timeout;
        },
        else => return error.DrainFailed,
    }
    mr.checkAnyError() catch return error.DrainFailed;

    const term = ctx.child.wait(io) catch return error.DrainFailed;
    const out = try mr.toOwnedSlice(0);
    errdefer gpa.free(out);
    const err_out = try mr.toOwnedSlice(1);
    return .{ .stdout = out, .stderr = err_out, .term = term };
}

// ── Tests (local "here" tier — a real /bin/sh child) ────────────────
// The bounded poll loops are test scaffolding: production consumers poll
// once per frame. Bounds are generous but finite, so a hung drain fails
// as a timeout rather than wedging the suite.

const t = std.testing;

/// Poll a Proc to completion within a finite round budget, yielding the
/// thread between tries. Returns the drain outcome or a timeout error.
fn pollToEnd(proc: *Proc, max_rounds: usize) !(DrainError!Result) {
    var rounds: usize = 0;
    while (rounds < max_rounds) : (rounds += 1) {
        if (proc.poll()) |outcome| return outcome;
        std.Thread.yield() catch {};
    }
    return error.ProcPollTimedOut;
}

test "proc: capture stdout/stderr and exit code" {
    const gpa = t.allocator;
    var pool = try task.Pool.init(gpa, .{ .threads = 2 });
    defer pool.deinit();

    var proc = try Proc.spawn(gpa, pool, &.{
        "/bin/sh", "-c", "printf hello; printf oops 1>&2; exit 3",
    }, .{});
    defer proc.deinit();

    var res = try (try pollToEnd(&proc, 1_000_000));
    defer res.deinit(gpa);
    try t.expectEqualStrings("hello", res.stdout);
    try t.expectEqualStrings("oops", res.stderr);
    try t.expectEqual(@as(u8, 3), res.exitCode().?);
    try t.expect(!res.succeeded());
}

test "proc: kill makes a long runner terminate (no hang)" {
    const gpa = t.allocator;
    var pool = try task.Pool.init(gpa, .{ .threads = 2 });
    defer pool.deinit();

    // A child that never exits on its own; only builtins, so no PATH.
    var proc = try Proc.spawn(gpa, pool, &.{
        "/bin/sh", "-c", "while :; do :; done",
    }, .{});
    defer proc.deinit();

    proc.kill();
    var res = try (try pollToEnd(&proc, 5_000_000));
    defer res.deinit(gpa);
    // Died by our signal, not a clean exit.
    try t.expect(res.exitCode() == null);
    switch (res.term) {
        .signal => {},
        else => return error.ExpectedSignalTermination,
    }
}

test "proc: cwd runs the child in the given directory" {
    const gpa = t.allocator;
    var pool = try task.Pool.init(gpa, .{ .threads = 2 });
    defer pool.deinit();

    // `pwd -P` in an explicit cwd reports that dir, not weft's. /tmp is a
    // stable, always-present absolute dir (resolve symlinks so macos /tmp
    // → /private/tmp doesn't trip the compare — Linux CI is the target here).
    var proc = try Proc.spawn(gpa, pool, &.{ "/bin/sh", "-c", "pwd -P" }, .{ .cwd = "/tmp" });
    defer proc.deinit();
    var res = try (try pollToEnd(&proc, 1_000_000));
    defer res.deinit(gpa);
    const out = std.mem.trimEnd(u8, res.stdout, "\n");
    try t.expectEqualStrings("/tmp", out);

    // null cwd (the default) inherits weft's cwd — not "/tmp" (unless weft is
    // literally in /tmp, which the test runner is not).
    var p2 = try Proc.spawn(gpa, pool, &.{ "/bin/sh", "-c", "pwd -P" }, .{});
    defer p2.deinit();
    var r2 = try (try pollToEnd(&p2, 1_000_000));
    defer r2.deinit(gpa);
    try t.expect(!std.mem.eql(u8, std.mem.trimEnd(u8, r2.stdout, "\n"), "/tmp"));
}

test {
    std.testing.refAllDecls(@This());
}
