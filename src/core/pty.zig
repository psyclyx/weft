//! pty — a child process on a pseudo-terminal: the mechanism a terminal
//! emulator stands on (doc/terminal.md §1). The child's stdin, stdout and
//! stderr are the pty's slave side, so it sees a real tty — line discipline,
//! job control, `isatty`, a window size — and the parent holds the master:
//! what the child prints arrives there as raw bytes, escape sequences and all,
//! and what is written there is what the child reads as typed. Interpreting
//! those bytes (a VT emulator) is NOT this file's business, nor the host's:
//! core moves bytes and sizes, the terminal plugin emulates.
//!
//! What a keystroke means to the child is the line discipline's call, as on
//! any terminal: a 0x03 written here is `C-c` — the kernel turns it into
//! SIGINT for the foreground job — and a 0x04 at an empty line is end of
//! file. No signal is ever sent from here on the user's behalf.
//!
//! THREADS. The frame thread opens the pty (`spawn`), writes, resizes and
//! reads; one RESIDENT reader (`task.Pool.spawnResident`, like
//! `proc_stream`'s) forks the child, then waits in `poll` on the master, the
//! child's pidfd and a kick eventfd, and never blocks anywhere else:
//! - output is appended to `inbox` under `mutex`, up to `inbox_cap`; past it
//!   the reader stops reading until the frame thread drains, so a flood
//!   (`yes`) is held back by the kernel's pty buffer, not by memory;
//! - what the frame thread writes is queued in `outbox` and written by the
//!   reader as the master takes it, so a child that is not reading (a paste
//!   bigger than the tty buffer) can never stall a frame;
//! - arrival wakes the frame loop through the pool's notify fd — once per
//!   batch the frame thread has not seen yet, never once per read.
//!
//! EXIT is the child's, seen through its pidfd — not the master's end of
//! file, which a background job still holding the tty would postpone past
//! the shell's own exit. Its status is published after the last of its
//! output was read, so a consumer that drains first reports the end after
//! everything the child printed.
//!
//! Local only: the child runs on this machine. A pty in a remote place (a
//! shell on a peer) is a later door (doc/terminal.md §6).

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const linux = std.os.linux;
const task = @import("task.zig");
const scheduler = @import("scheduler.zig");

/// A terminal's size: cells, and the pixels they cover (0 when unknown).
pub const Size = struct {
    cols: u16,
    rows: u16,
    px_w: u16 = 0,
    px_h: u16 = 0,

    fn winsize(self: Size) std.posix.winsize {
        return .{ .row = self.rows, .col = self.cols, .xpixel = self.px_w, .ypixel = self.px_h };
    }
};

pub const SpawnError = error{ PtyUnavailable, ProcessSpawnFailed } || Allocator.Error;

/// Output held for the frame thread past which the reader stops reading: the
/// child then blocks on its own writes, in the kernel, until the frame thread
/// has caught up.
pub const inbox_cap = 1 << 20;

pub const Pty = struct {
    gpa: Allocator,
    pool: *task.Pool,
    master: linux.fd_t,
    /// Wakes the reader out of `poll`: a stop, a write queued, room made.
    kick: linux.fd_t,
    /// What the reader needs to start the child, owned until it has.
    slave_path: [32:0]u8 = @splat(0),
    cmd: [:0]u8,
    cwd: ?[:0]u8,
    environ: std.process.Environ,
    environ_owned: bool = false,

    mutex: task.Mutex = .{},
    /// Output read and not yet taken (`read`), guarded by `mutex`.
    inbox: std.ArrayList(u8) = .empty,
    /// Input queued and not yet written to the master, guarded by `mutex`.
    outbox: std.ArrayList(u8) = .empty,
    /// The child, once forked (0 before, or when the fork failed); guarded
    /// by `mutex`.
    pid: linux.pid_t = 0,
    /// The frame loop has been woken for output it has not read yet: the
    /// reader rings once per such batch.
    rung: std.atomic.Value(bool) = .init(false),
    stop: std.atomic.Value(bool) = .init(false),
    /// How the child ended — exit code, or 128 + the signal — once the reader
    /// saw it end and read what it printed; -1 until then.
    status: std.atomic.Value(i32) = .init(-1),
    reader: task.Handle(void),

    /// Open a pty `size` big and start `cmd` (under `/bin/sh -c`, like the
    /// other proc doors) on it, in `cwd` (null: weft's own), with `environ`.
    /// Returns once the master is open; the fork+exec happens on the reader,
    /// off the frame thread, and input written before it lands is queued.
    pub fn spawn(gpa: Allocator, pool: *task.Pool, cmd: []const u8, cwd: ?[]const u8, environ: std.process.Environ, size: Size) SpawnError!*Pty {
        if (builtin.os.tag != .linux) return error.PtyUnavailable;
        const s = try gpa.create(Pty);
        errdefer gpa.destroy(s);
        const cmd_z = try gpa.dupeZ(u8, cmd);
        errdefer gpa.free(cmd_z);
        const cwd_z = if (cwd) |c| try gpa.dupeZ(u8, c) else null;
        errdefer if (cwd_z) |c| gpa.free(c);

        const master = try openMaster(&s.slave_path);
        errdefer _ = linux.close(master);
        var ws = size.winsize();
        _ = linux.ioctl(master, linux.T.IOCSWINSZ, @intFromPtr(&ws));
        const kick = scheduler.newWakeFd() catch return error.PtyUnavailable;
        errdefer scheduler.closeWakeFd(kick);

        s.* = .{
            .gpa = gpa,
            .pool = pool,
            .master = master,
            .kick = kick,
            .slave_path = s.slave_path,
            .cmd = cmd_z,
            .cwd = cwd_z,
            .environ = environ,
            .reader = undefined,
        };
        s.reader = pool.spawnResident(.{ .name = "pty reader", .stop = .of(s, requestStop) }, run, .{s}) catch
            return error.ProcessSpawnFailed;
        return s;
    }

    /// Take ownership of the environment `spawn` was given (a merged
    /// per-place one): freed with the pty. Only after a successful `spawn`.
    pub fn adoptEnviron(s: *Pty) void {
        s.environ_owned = true;
    }

    /// Frame thread: queue `bytes` for the child to read, as if typed.
    pub fn write(s: *Pty, bytes: []const u8) void {
        if (bytes.len == 0) return;
        s.mutex.lock();
        s.outbox.appendSlice(s.gpa, bytes) catch {};
        s.mutex.unlock();
        scheduler.signalWakeFd(s.kick);
    }

    /// Frame thread: the terminal is now `size`. The kernel tells the
    /// foreground job (SIGWINCH).
    pub fn resize(s: *Pty, size: Size) void {
        var ws = size.winsize();
        _ = linux.ioctl(s.master, linux.T.IOCSWINSZ, @intFromPtr(&ws));
    }

    /// Frame thread: move up to `out.len` bytes of output into `out`.
    pub fn read(s: *Pty, out: []u8) usize {
        s.mutex.lock();
        const was_full = s.inbox.items.len >= inbox_cap;
        const n = @min(out.len, s.inbox.items.len);
        @memcpy(out[0..n], s.inbox.items[0..n]);
        std.mem.copyForwards(u8, s.inbox.items[0 .. s.inbox.items.len - n], s.inbox.items[n..]);
        s.inbox.items.len -= n;
        const left = s.inbox.items.len;
        if (left == 0) s.rung.store(false, .release);
        s.mutex.unlock();
        // Room again: the reader parked the master when the inbox filled.
        if (was_full and left < inbox_cap) scheduler.signalWakeFd(s.kick);
        // Output this read left behind is still news: ring for it, so the
        // frame loop comes back even when nothing else wakes it.
        if (left > 0) s.ring();
        return n;
    }

    /// Frame thread: bytes of output waiting.
    pub fn pending(s: *Pty) usize {
        s.mutex.lock();
        defer s.mutex.unlock();
        return s.inbox.items.len;
    }

    /// Frame thread: how the child ended — its exit code, or 128 + the
    /// signal that killed it — once it has, and once everything it printed
    /// has been read. Null while it runs.
    pub fn exitCode(s: *Pty) ?u8 {
        const code = s.status.load(.acquire);
        if (code < 0 or s.pending() > 0) return null;
        return @intCast(code);
    }

    /// Stop the reader (it hangs the child up and reaps it on the way out),
    /// join it, and free. The single owner of teardown.
    pub fn deinit(s: *Pty) void {
        const gpa = s.gpa;
        requestStop(s);
        while (!s.reader.residentExited()) std.Thread.yield() catch {}; // join the reader
        _ = s.reader.poll();
        _ = linux.close(s.master);
        scheduler.closeWakeFd(s.kick);
        s.inbox.deinit(gpa);
        s.outbox.deinit(gpa);
        if (s.environ_owned) s.environ.block.deinit(gpa);
        gpa.free(s.cmd);
        if (s.cwd) |c| gpa.free(c);
        gpa.destroy(s);
    }

    /// Shutdown's reach into the reader (also `deinit`'s): a flag and a kick,
    /// which is all its `poll` waits on besides the child.
    fn requestStop(s: *Pty) void {
        s.stop.store(true, .release);
        scheduler.signalWakeFd(s.kick);
    }

    /// Wake the frame loop for output it has not been told of.
    fn ring(s: *Pty) void {
        if (s.rung.swap(true, .acq_rel)) return;
        if (s.pool.notify_fd) |fd| scheduler.signalWakeFd(fd);
    }

    // ── The reader ──────────────────────────────────────────────────

    fn run(s: *Pty) void {
        const pid = forkChild(s) catch {
            s.status.store(127, .release);
            s.ring();
            return waitForStop(s);
        };
        s.mutex.lock();
        s.pid = pid;
        s.mutex.unlock();
        const pidfd_rc = linux.pidfd_open(pid, 0);
        const pidfd: ?linux.fd_t = if (linux.errno(pidfd_rc) == .SUCCESS) @intCast(pidfd_rc) else null;
        defer if (pidfd) |fd| {
            _ = linux.close(fd);
        };

        var buf: [64 * 1024]u8 = undefined;
        var master_open = true;
        while (!s.stop.load(.acquire)) {
            s.mutex.lock();
            const room = s.inbox.items.len < inbox_cap;
            const to_write = s.outbox.items.len > 0;
            s.mutex.unlock();

            var fds: [3]linux.pollfd = undefined;
            var n: usize = 0;
            fds[n] = .{ .fd = s.kick, .events = linux.POLL.IN, .revents = 0 };
            n += 1;
            const master_at = n;
            var master_events: i16 = 0;
            if (master_open and room) master_events |= linux.POLL.IN;
            if (master_open and to_write) master_events |= linux.POLL.OUT;
            fds[n] = .{ .fd = if (master_events != 0) s.master else -1, .events = master_events, .revents = 0 };
            n += 1;
            const pid_at = n;
            fds[n] = .{ .fd = pidfd orelse -1, .events = linux.POLL.IN, .revents = 0 };
            n += 1;

            const rc = linux.poll(&fds, n, -1);
            if (linux.errno(rc) != .SUCCESS) continue; // EINTR
            if (fds[0].revents != 0) scheduler.drainWakeFd(s.kick);
            if (s.stop.load(.acquire)) break;

            const mrev = fds[master_at].revents;
            if (mrev & linux.POLL.OUT != 0) flushOutbox(s);
            if (mrev & (linux.POLL.IN | linux.POLL.HUP | linux.POLL.ERR) != 0) {
                // EIO once no process holds the slave any more: nothing more
                // will come, but the child's end is still its pidfd's to say.
                if (!drain(s, &buf, true)) master_open = false;
            }
            if (fds[pid_at].revents != 0) {
                // The child is gone: what it printed is already in the tty
                // buffer, so read it all, then say how it ended.
                _ = drain(s, &buf, false);
                s.status.store(reap(pid), .release);
                s.mutex.lock();
                s.pid = 0;
                s.mutex.unlock();
                s.ring();
                return waitForStop(s);
            }
            if (pidfd == null and !master_open) {
                // No pidfd (an old kernel): the master's end is all there is.
                s.status.store(reap(pid), .release);
                s.mutex.lock();
                s.pid = 0;
                s.mutex.unlock();
                s.ring();
                return waitForStop(s);
            }
        }
        // Asked to stop with the child still running: hang it up, as closing
        // a terminal does, and reap it — SIGKILL too, so a shell that traps
        // SIGHUP cannot hold teardown.
        s.mutex.lock();
        const live = s.pid;
        s.pid = 0;
        s.mutex.unlock();
        if (live > 0) {
            _ = linux.kill(-live, .HUP);
            _ = linux.kill(live, .KILL);
            _ = reap(live);
        }
    }

    /// Read what the master has, up to the inbox's room (all of it when
    /// `bounded` is false: the child is gone and nothing will drain it
    /// later). False once the master reports its end.
    fn drain(s: *Pty, buf: *[64 * 1024]u8, bounded: bool) bool {
        while (true) {
            if (bounded) {
                s.mutex.lock();
                const full = s.inbox.items.len >= inbox_cap;
                s.mutex.unlock();
                if (full) return true;
            }
            const rc = linux.read(s.master, buf, buf.len);
            switch (linux.errno(rc)) {
                .SUCCESS => {},
                .AGAIN => return true,
                .INTR => continue,
                else => return false, // EIO: no process holds the slave
            }
            if (rc == 0) return false;
            s.mutex.lock();
            s.inbox.appendSlice(s.gpa, buf[0..rc]) catch {};
            s.mutex.unlock();
            s.ring();
        }
    }

    /// Write as much of the outbox as the master takes now.
    fn flushOutbox(s: *Pty) void {
        s.mutex.lock();
        defer s.mutex.unlock();
        while (s.outbox.items.len > 0) {
            const rc = linux.write(s.master, s.outbox.items.ptr, s.outbox.items.len);
            switch (linux.errno(rc)) {
                .SUCCESS => {},
                .INTR => continue,
                .AGAIN => return,
                else => {
                    s.outbox.clearRetainingCapacity(); // no reader on the other side
                    return;
                },
            }
            const n: usize = rc;
            std.mem.copyForwards(u8, s.outbox.items[0 .. s.outbox.items.len - n], s.outbox.items[n..]);
            s.outbox.items.len -= n;
        }
    }

    /// After the child: nothing to do but wait to be torn down.
    fn waitForStop(s: *Pty) void {
        while (!s.stop.load(.acquire)) {
            var fds = [_]linux.pollfd{.{ .fd = s.kick, .events = linux.POLL.IN, .revents = 0 }};
            _ = linux.poll(&fds, 1, -1);
            scheduler.drainWakeFd(s.kick);
        }
    }

    /// Fork the child onto the pty's slave and exec its command. Everything
    /// the child needs is built BEFORE the fork: between fork and exec it may
    /// only make system calls (another thread may hold the allocator's lock).
    fn forkChild(s: *Pty) !linux.pid_t {
        var argv = [_:null]?[*:0]const u8{ "/bin/sh", "-c", s.cmd.ptr, null };
        const envp: [*:null]const ?[*:0]const u8 = if (s.environ.block.slice.len == 0) &[_:null]?[*:0]const u8{} else s.environ.block.slice.ptr;
        const rc = linux.fork();
        switch (linux.errno(rc)) {
            .SUCCESS => {},
            else => return error.ProcessSpawnFailed,
        }
        if (rc != 0) return @intCast(rc);
        childExec(s, &argv, envp);
    }

    fn childExec(s: *Pty, argv: [*:null]const ?[*:0]const u8, envp: [*:null]const ?[*:0]const u8) noreturn {
        // A new session, whose controlling terminal is the slave: job control
        // and C-c's SIGINT reach the child's jobs, never weft.
        _ = linux.setsid();
        const slave_rc = linux.open(&s.slave_path, .{ .ACCMODE = .RDWR }, 0);
        if (linux.errno(slave_rc) != .SUCCESS) linux.exit_group(126);
        const slave: linux.fd_t = @intCast(slave_rc);
        _ = linux.ioctl(slave, linux.T.IOCSCTTY, 0);
        _ = linux.dup2(slave, 0);
        _ = linux.dup2(slave, 1);
        _ = linux.dup2(slave, 2);
        // Nothing of weft's leaks into the shell: not its window, its
        // sockets, nor the master.
        _ = linux.close_range(3, std.math.maxInt(linux.fd_t), .{ .UNSHARE = false, .CLOEXEC = false });
        // Signal dispositions weft ignores and masks its threads block would
        // otherwise survive the exec, and a shell cannot undo an inherited
        // ignore: reset them.
        const dfl: linux.Sigaction = .{ .handler = .{ .handler = linux.SIG.DFL }, .mask = linux.sigemptyset(), .flags = 0 };
        for ([_]linux.SIG{ .HUP, .INT, .QUIT, .PIPE, .TERM, .CHLD, .TSTP, .TTIN, .TTOU, .WINCH, .ALRM, .USR1, .USR2 }) |sig|
            _ = linux.sigaction(sig, &dfl, null);
        const empty = linux.sigemptyset();
        _ = linux.sigprocmask(linux.SIG.SETMASK, &empty, null);
        if (s.cwd) |cwd| {
            if (linux.errno(linux.chdir(cwd.ptr)) != .SUCCESS) {
                const msg = "weft: cannot enter the terminal's directory\r\n";
                _ = linux.write(2, msg, msg.len);
                linux.exit_group(126);
            }
        }
        _ = linux.execve("/bin/sh", argv, envp);
        const msg = "weft: cannot run /bin/sh\r\n";
        _ = linux.write(2, msg, msg.len);
        linux.exit_group(127);
    }
};

/// Open a pty master and unlock its slave, writing the slave's path into
/// `path`.
fn openMaster(path: *[32:0]u8) SpawnError!linux.fd_t {
    const rc = linux.open("/dev/ptmx", .{ .ACCMODE = .RDWR, .NOCTTY = true, .CLOEXEC = true, .NONBLOCK = true }, 0);
    if (linux.errno(rc) != .SUCCESS) return error.PtyUnavailable;
    const master: linux.fd_t = @intCast(rc);
    errdefer _ = linux.close(master);
    var unlock: c_int = 0;
    if (linux.errno(linux.ioctl(master, linux.T.IOCSPTLCK, @intFromPtr(&unlock))) != .SUCCESS) return error.PtyUnavailable;
    var n: c_uint = 0;
    if (linux.errno(linux.ioctl(master, linux.T.IOCGPTN, @intFromPtr(&n))) != .SUCCESS) return error.PtyUnavailable;
    const written = std.fmt.bufPrintZ(path, "/dev/pts/{d}", .{n}) catch return error.PtyUnavailable;
    // UTF-8 input: the line discipline's erase takes back a whole character.
    var tio: linux.termios = undefined;
    if (linux.errno(linux.tcgetattr(master, &tio)) == .SUCCESS) {
        tio.iflag.IUTF8 = true;
        _ = linux.tcsetattr(master, .NOW, &tio);
    }
    _ = written;
    return master;
}

/// Reap `pid` — gone, or killed just now, so this returns promptly —
/// returning its exit code or 128 + the signal that killed it.
fn reap(pid: linux.pid_t) i32 {
    var info = std.mem.zeroes(linux.siginfo_t);
    while (true) {
        const rc = linux.waitid(.PID, pid, &info, linux.W.EXITED, null);
        switch (linux.errno(rc)) {
            .SUCCESS => break,
            .INTR => continue,
            else => return 127,
        }
    }
    const status: u8 = @truncate(@as(u32, @bitCast(info.fields.common.second.sigchld.status)));
    return switch (@as(linux.CLD, @enumFromInt(info.code))) {
        .EXITED => status,
        .KILLED, .DUMPED => 128 + @as(i32, status),
        else => 127,
    };
}

// ── Tests ───────────────────────────────────────────────────────────
// Each test drives a real shell on a real pty. Waiting is a bounded spin on
// the condition itself (`until`), never a timed sleep.

const t = std.testing;

/// Spin until `pred(ctx)` holds, or fail after a generous bound.
fn until(ctx: anytype, comptime pred: fn (@TypeOf(ctx)) bool) !void {
    const deadline = task.nowNs() + 10 * std.time.ns_per_s;
    while (!pred(ctx)) {
        if (task.nowNs() >= deadline) return error.TimedOut;
        std.Thread.yield() catch {};
    }
}

/// Collects a pty's output as it is read.
const Sink = struct {
    pty: *Pty,
    got: std.ArrayList(u8) = .empty,
    want: []const u8 = "",

    fn pump(self: *Sink) void {
        var buf: [4096]u8 = undefined;
        while (true) {
            const n = self.pty.read(&buf);
            if (n == 0) break;
            self.got.appendSlice(t.allocator, buf[0..n]) catch {};
        }
    }

    fn has(self: *Sink) bool {
        self.pump();
        return std.mem.indexOf(u8, self.got.items, self.want) != null;
    }

    fn ended(self: *Sink) bool {
        self.pump();
        return self.pty.exitCode() != null;
    }

    fn waitFor(self: *Sink, want: []const u8) !void {
        self.want = want;
        until(self, has) catch |err| {
            std.debug.print("pty output so far: {f}\n", .{std.zig.fmtString(self.got.items)});
            return err;
        };
    }
};

fn testPool() !*task.Pool {
    return task.Pool.init(t.allocator, .{ .threads = 1 });
}

test "pty: the child runs on a tty, and what it prints arrives raw" {
    const pool = try testPool();
    defer pool.deinit();
    const s = try Pty.spawn(t.allocator, pool, "test -t 0 && test -t 1 && printf '\\033[1mhi\\033[0m\\n'; exit 3", null, .empty, .{ .cols = 80, .rows = 24 });
    defer s.deinit();
    var sink: Sink = .{ .pty = s };
    defer sink.got.deinit(t.allocator);
    try sink.waitFor("\x1b[1mhi\x1b[0m\r\n");
    try until(&sink, Sink.ended);
    try t.expectEqual(@as(?u8, 3), s.exitCode());
}

test "pty: its size is the child's `stty size`, and a resize reaches it" {
    const pool = try testPool();
    defer pool.deinit();
    const s = try Pty.spawn(t.allocator, pool, "stty size; read x; stty size", null, try testEnviron(), .{ .cols = 80, .rows = 24 });
    defer s.deinit();
    var sink: Sink = .{ .pty = s };
    defer sink.got.deinit(t.allocator);
    try sink.waitFor("24 80");
    s.resize(.{ .cols = 132, .rows = 40 });
    s.write("\r");
    try sink.waitFor("40 132");
}

test "pty: C-c interrupts the foreground job, and C-d ends a reader's input" {
    const pool = try testPool();
    defer pool.deinit();
    // `cat` waits on the tty forever; 0x03 is the line discipline's SIGINT,
    // which the foreground job dies of.
    {
        const s = try Pty.spawn(t.allocator, pool, "exec cat", null, try testEnviron(), .{ .cols = 80, .rows = 24 });
        defer s.deinit();
        var sink: Sink = .{ .pty = s };
        defer sink.got.deinit(t.allocator);
        s.write("one\r");
        try sink.waitFor("one\r\none\r\n"); // echoed by the tty, then by cat
        s.write("\x03");
        try until(&sink, Sink.ended);
        try t.expectEqual(@as(?u8, 128 + 2), s.exitCode());
    }
    // 0x04 at the start of a line is end of file: `cat` reads it and exits 0.
    {
        const s = try Pty.spawn(t.allocator, pool, "exec cat", null, try testEnviron(), .{ .cols = 80, .rows = 24 });
        defer s.deinit();
        var sink: Sink = .{ .pty = s };
        defer sink.got.deinit(t.allocator);
        s.write("\x04");
        try until(&sink, Sink.ended);
        try t.expectEqual(@as(?u8, 0), s.exitCode());
    }
}

test "pty: teardown with the child still running hangs it up" {
    const pool = try testPool();
    defer pool.deinit();
    const s = try Pty.spawn(t.allocator, pool, "cat", null, try testEnviron(), .{ .cols = 80, .rows = 24 });
    var sink: Sink = .{ .pty = s };
    defer sink.got.deinit(t.allocator);
    s.write("x\r");
    try sink.waitFor("x\r\n");
    s.deinit(); // joins the reader, which kills and reaps `cat`
}

/// The test's own environment: a PATH to find `cat` and `stty` by. `sh -c`
/// reads no startup file, so nothing else in it changes what runs.
fn testEnviron() !std.process.Environ {
    return t.environ;
}
