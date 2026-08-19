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
//! Teardown is the same UAF-safe discipline as `repl_session`: kill → JOIN the
//! reader (so it can't touch freed state) → reap → free. Every blocking step is
//! off the hot path (`deinit` runs at shutdown / plugin unload).

const std = @import("std");
const Allocator = std.mem.Allocator;
const task = @import("task.zig");

pub const SpawnError = error{ProcessSpawnFailed} || Allocator.Error;

pub const ProcStream = struct {
    gpa: Allocator,
    io_threaded: std.Io.Threaded, // frame-thread io (stdin writes)
    child: std.process.Child,
    out_mutex: task.Mutex = .{},
    out_buf: std.ArrayList(u8) = .empty,
    /// Bytes already handed to `read`. The buffer resets once fully drained, so
    /// steady-state memory is one frame's worth of output, not the whole run.
    cursor: usize = 0,
    reader: task.Handle(void),

    /// Spawn `cmd` (via `/bin/sh -c`, matching the other proc doors) as a
    /// persistent child with piped stdio, in `cwd` (null = weft's cwd), and
    /// start its reader on the pool. `environ` is the child's environment —
    /// pass weft's block so the child resolves `PATH` (an agent needs it);
    /// `.empty` is a hermetic child (only sh builtins / absolute argv).
    pub fn start(gpa: Allocator, pool: *task.Pool, cmd: []const u8, cwd: ?[]const u8, environ: std.process.Environ) SpawnError!*ProcStream {
        const s = try gpa.create(ProcStream);
        errdefer gpa.destroy(s);
        s.* = .{
            .gpa = gpa,
            .io_threaded = .init(gpa, .{ .environ = environ }),
            .child = undefined,
            .reader = undefined,
        };
        errdefer s.io_threaded.deinit();
        s.child = std.process.spawn(s.io_threaded.io(), .{
            .argv = &.{ "/bin/sh", "-c", cmd },
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .pipe,
            .cwd = if (cwd) |p| .{ .path = p } else .inherit,
        }) catch return error.ProcessSpawnFailed;
        s.reader = pool.spawn(readLoop, .{s}) catch return error.ProcessSpawnFailed;
        return s;
    }

    /// Reader task: block on stdout/stderr; append stdout to the accumulator,
    /// discard stderr (still drained so the pipe can't back up), until EOF.
    fn readLoop(s: *ProcStream) void {
        var threaded: std.Io.Threaded = .init(s.gpa, .{});
        defer threaded.deinit();
        const io = threaded.io();
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
    /// protocol — for NDJSON it appends the newline).
    pub fn send(s: *ProcStream, bytes: []const u8) void {
        const stdin = s.child.stdin orelse return;
        stdin.writeStreamingAll(s.io_threaded.io(), bytes) catch {};
    }

    /// Kill the child, JOIN the reader (so it can't touch freed state), reap,
    /// and free. The single owner of teardown.
    pub fn deinit(s: *ProcStream) void {
        const gpa = s.gpa;
        if (s.child.id) |id| std.posix.kill(id, std.posix.SIG.KILL) catch {};
        while (s.reader.poll() == null) std.atomic.spinLoopHint(); // join the reader
        _ = s.child.wait(s.io_threaded.io()) catch {};
        s.out_buf.deinit(gpa);
        s.io_threaded.deinit();
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

test {
    std.testing.refAllDecls(@This());
}
