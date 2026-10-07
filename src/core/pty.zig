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
//! PORTABLE POSIX, one path on every OS: `posix_openpt`/`grantpt`/
//! `unlockpt`/`ptsname_r` for the pair (the slave opened in the parent, as
//! `openpty` does — see `openPair`), libc `fork`/`setsid`/`execve`, the
//! TIOCSCTTY/TIOCSWINSZ ioctls by each OS's own number (`tioc`), `termios`
//! from `std.c`. Where an OS has a better call it is named in one branch
//! (`closeInherited`: Linux's `close_range`, a close loop elsewhere).
//!
//! THREADS. The frame thread opens the pty (`spawn`), writes, resizes and
//! reads; one RESIDENT reader (`task.Pool.spawnResident`, like
//! `proc_stream`'s) forks the child, then waits in `poll` on the master and
//! a kick wake fd, and never blocks anywhere else:
//! - output is appended to `inbox` under `mutex`, up to `inbox_cap`; past it
//!   the reader stops reading until the frame thread drains, so a flood
//!   (`yes`) is held back by the kernel's pty buffer, not by memory;
//! - what the frame thread writes is queued in `outbox` and written by the
//!   reader as the master takes it, so a child that is not reading (a paste
//!   bigger than the tty buffer) can never stall a frame;
//! - arrival wakes the frame loop through the pool's notify fd — once per
//!   batch the frame thread has not seen yet, never once per read.
//!
//! EXIT is the child's, not the master's end of file, which a background
//! job still holding the tty would postpone past the shell's own exit. No
//! fd for "this child ended" can be `poll`ed on every OS (a pidfd is Linux's
//! alone; Darwin's `poll` does not take a kqueue), so a small WATCHER thread
//! per child blocks in `waitid(WEXITED|WNOWAIT)` (`child_status.peek`) and
//! kicks the reader when it returns. The peek does not reap: the pid stays
//! the zombie's until the reader reaps it, so the reader's teardown signal
//! can never reach a recycled pid. The child's status is published after
//! the last of its output was read, so a consumer that drains first reports
//! the end after everything the child printed.
//!
//! Local only: the child runs on this machine. A pty in a remote place (a
//! shell on a peer) is a later door (doc/terminal.md §6).

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const c = std.c;
const task = @import("task.zig");
const scheduler = @import("scheduler.zig");
const posix_fd = @import("posix_fd.zig");
const child_status = @import("child_status.zig");

// libc's pty and fd calls `std.c` does not declare. All are in glibc and in
// Darwin's libSystem. `ioctl` is redeclared with the request as C's
// `unsigned long`: Darwin's request numbers (TIOCSWINSZ = 0x80087467) do not
// fit `std.c.ioctl`'s `c_int`, and a sign-extended request is a different
// request to a 64-bit kernel.
extern "c" fn posix_openpt(flags: c_int) c_int;
extern "c" fn grantpt(fd: c_int) c_int;
extern "c" fn unlockpt(fd: c_int) c_int;
extern "c" fn ptsname_r(fd: c_int, buf: [*]u8, len: usize) c_int;
extern "c" fn ioctl(fd: c_int, request: c_ulong, ...) c_int;
extern "c" fn getdtablesize() c_int;

/// The two tty ioctls by this OS's numbers. Linux's are `std.c.T`'s; Darwin's
/// (BSD's `_IO`/`_IOW` encodings, `<sys/ttycom.h>`) are not in `std.c`, so
/// they are built from the same macros the header uses.
const tioc = switch (builtin.os.tag) {
    .linux => struct {
        const SWINSZ: c_ulong = c.T.IOCSWINSZ;
        const SCTTY: c_ulong = c.T.IOCSCTTY;
    },
    .macos, .ios, .tvos, .visionos, .watchos, .maccatalyst, .driverkit => struct {
        const IOC_VOID: c_ulong = 0x20000000;
        const IOC_IN: c_ulong = 0x80000000;
        const IOCPARM_MASK: c_ulong = 0x1fff;
        fn io(group: u8, num: u8) c_ulong {
            return IOC_VOID | (@as(c_ulong, group) << 8) | num;
        }
        fn iow(group: u8, num: u8, size: usize) c_ulong {
            return IOC_IN | ((@as(c_ulong, size) & IOCPARM_MASK) << 16) | (@as(c_ulong, group) << 8) | num;
        }
        const SWINSZ = iow('t', 103, @sizeOf(std.posix.winsize));
        const SCTTY = io('t', 97);
        comptime {
            std.debug.assert(SWINSZ == 0x80087467);
            std.debug.assert(SCTTY == 0x20007461);
        }
    },
    else => @compileError("pty: no tty ioctl numbers for this OS"),
};

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

/// What the reader knows of the child's end, written by the watcher.
const Watch = enum(u8) {
    /// Running, or not yet seen to end.
    running,
    /// Ended (a zombie, not yet reaped): drain, reap, publish.
    ended,
    /// No watcher could be started, or its wait failed: the master's end of
    /// file is all there is to go on.
    blind,
};

pub const Pty = struct {
    gpa: Allocator,
    pool: *task.Pool,
    master: c.fd_t,
    /// Wakes the reader out of `poll`: a stop, a write queued, room made,
    /// the child's end.
    kick: c.fd_t,
    /// The slave side, opened here (close-on-exec, not our controlling
    /// tty) and handed to the child at the fork; the reader closes this
    /// copy right after. -1 once closed.
    slave: c.fd_t,
    /// What the reader needs to start the child, owned until it has.
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
    pid: c.pid_t = 0,
    /// The watcher's word on the child (reader-side; see `Watch`).
    watch: std.atomic.Value(Watch) = .init(.running),
    /// The frame loop has been woken for output it has not read yet: the
    /// reader rings once per such batch.
    rung: std.atomic.Value(bool) = .init(false),
    stop: std.atomic.Value(bool) = .init(false),
    /// How the child ended — exit code, or 128 + the signal — once the reader
    /// saw it end and read what it printed; -1 until then.
    status: std.atomic.Value(i32) = .init(-1),
    /// Frame thread: the consumer was told how the child ended (`exitCode`
    /// answered it), so the end is no longer news (`ready`).
    exit_told: bool = false,
    reader: task.Handle(void),

    /// Open a pty `size` big and start `cmd` (under `/bin/sh -c`, like the
    /// other proc doors) on it, in `cwd` (null: weft's own), with `environ`.
    /// Returns once the master is open; the fork+exec happens on the reader,
    /// off the frame thread, and input written before it lands is queued.
    pub fn spawn(gpa: Allocator, pool: *task.Pool, cmd: []const u8, cwd: ?[]const u8, environ: std.process.Environ, size: Size) SpawnError!*Pty {
        const s = try gpa.create(Pty);
        errdefer gpa.destroy(s);
        const cmd_z = try gpa.dupeZ(u8, cmd);
        errdefer gpa.free(cmd_z);
        const cwd_z = if (cwd) |d| try gpa.dupeZ(u8, d) else null;
        errdefer if (cwd_z) |d| gpa.free(d);

        const pair = try openPair();
        errdefer {
            _ = c.close(pair.master);
            _ = c.close(pair.slave);
        }
        var ws = size.winsize();
        _ = ioctl(pair.master, tioc.SWINSZ, &ws);
        const kick = scheduler.newWakeFd() catch return error.PtyUnavailable;
        errdefer scheduler.closeWakeFd(kick);

        s.* = .{
            .gpa = gpa,
            .pool = pool,
            .master = pair.master,
            .kick = kick,
            .slave = pair.slave,
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
        _ = ioctl(s.master, tioc.SWINSZ, &ws);
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
        s.exit_told = true;
        return @intCast(code);
    }

    /// Frame thread: whether there is news for the consumer — output to
    /// read, or an end it has not been told of.
    pub fn ready(s: *Pty) bool {
        return s.pending() > 0 or (s.status.load(.acquire) >= 0 and !s.exit_told);
    }

    /// Stop the reader (it hangs the child up and reaps it on the way out),
    /// join it, and free. The single owner of teardown.
    pub fn deinit(s: *Pty) void {
        const gpa = s.gpa;
        requestStop(s);
        while (!s.reader.residentExited()) std.Thread.yield() catch {}; // join the reader
        _ = s.reader.poll();
        _ = c.close(s.master);
        scheduler.closeWakeFd(s.kick);
        s.inbox.deinit(gpa);
        s.outbox.deinit(gpa);
        if (s.environ_owned) s.environ.block.deinit(gpa);
        gpa.free(s.cmd);
        if (s.cwd) |d| gpa.free(d);
        gpa.destroy(s);
    }

    /// Shutdown's reach into the reader (also `deinit`'s): a flag and a kick,
    /// which is all its `poll` waits on besides the master.
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
        const forked = forkChild(s);
        // The child holds the slave now (or never will): this copy goes, so
        // the master's end of file means the CHILD's side let go.
        _ = c.close(s.slave);
        s.slave = -1;
        const pid = forked catch {
            s.status.store(127, .release);
            s.ring();
            return waitForStop(s);
        };
        s.mutex.lock();
        s.pid = pid;
        s.mutex.unlock();
        // The watcher only waits; it is joined on both ways out, each time
        // after the child is gone (ended on its own, or killed below), so
        // the join returns promptly.
        const watcher: ?std.Thread = std.Thread.spawn(.{}, watchChild, .{ s, pid }) catch blk: {
            s.watch.store(.blind, .release);
            break :blk null;
        };

        var buf: [64 * 1024]u8 = undefined;
        var master_open = true;
        while (!s.stop.load(.acquire)) {
            s.mutex.lock();
            const room = s.inbox.items.len < inbox_cap;
            const to_write = s.outbox.items.len > 0;
            s.mutex.unlock();

            var master_events: i16 = 0;
            if (master_open and room) master_events |= c.POLL.IN;
            if (master_open and to_write) master_events |= c.POLL.OUT;
            var fds = [2]c.pollfd{
                .{ .fd = s.kick, .events = c.POLL.IN, .revents = 0 },
                .{ .fd = if (master_events != 0) s.master else -1, .events = master_events, .revents = 0 },
            };

            if (c.poll(&fds, fds.len, -1) < 0) continue; // EINTR
            if (fds[0].revents != 0) scheduler.drainWakeFd(s.kick);
            if (s.stop.load(.acquire)) break;

            const mrev = fds[1].revents;
            if (mrev & c.POLL.OUT != 0) flushOutbox(s);
            if (mrev & (c.POLL.IN | c.POLL.HUP | c.POLL.ERR) != 0) {
                // EIO once no process holds the slave any more: nothing more
                // will come, but the child's end is still the watcher's to say.
                if (!drain(s, &buf, true)) master_open = false;
            }
            const watch = s.watch.load(.acquire);
            if (watch == .ended or (watch == .blind and !master_open)) {
                // The child is gone: what it printed is already in the tty
                // buffer, so read it all, then say how it ended. (Blind: the
                // master's end is all there was, and the child may still be
                // running — a background job holding the tty would have kept
                // it open — so this reap can wait for it.)
                _ = drain(s, &buf, false);
                if (watcher) |w| w.join();
                s.status.store(child_status.reap(pid), .release);
                s.mutex.lock();
                s.pid = 0;
                s.mutex.unlock();
                s.ring();
                return waitForStop(s);
            }
        }
        // Asked to stop with the child still running: hang it up, as closing
        // a terminal does, and reap it — SIGKILL too, so a shell that traps
        // SIGHUP cannot hold teardown. The watcher, if any, returns once the
        // child is a zombie; the pid is ours until the reap.
        s.mutex.lock();
        const live = s.pid;
        s.pid = 0;
        s.mutex.unlock();
        std.debug.assert(live > 0); // only the end above clears it, and that returns
        _ = c.kill(-live, .HUP);
        _ = c.kill(live, .KILL);
        if (watcher) |w| w.join();
        _ = child_status.reap(live);
    }

    /// The watcher thread: wait for the child to end, without reaping it,
    /// and tell the reader.
    fn watchChild(s: *Pty, pid: c.pid_t) void {
        const ended = child_status.peek(pid, .wait) != null;
        s.watch.store(if (ended) .ended else .blind, .release);
        scheduler.signalWakeFd(s.kick);
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
            const rc = c.read(s.master, buf, buf.len);
            if (rc < 0) switch (c.errno(rc)) {
                .AGAIN => return true,
                .INTR => continue,
                else => return false, // EIO: no process holds the slave
            };
            if (rc == 0) return false;
            const n: usize = @intCast(rc);
            s.mutex.lock();
            s.inbox.appendSlice(s.gpa, buf[0..n]) catch {};
            s.mutex.unlock();
            s.ring();
        }
    }

    /// Write as much of the outbox as the master takes now.
    fn flushOutbox(s: *Pty) void {
        s.mutex.lock();
        defer s.mutex.unlock();
        while (s.outbox.items.len > 0) {
            const rc = c.write(s.master, s.outbox.items.ptr, s.outbox.items.len);
            if (rc < 0) switch (c.errno(rc)) {
                .INTR => continue,
                .AGAIN => return,
                else => {
                    s.outbox.clearRetainingCapacity(); // no reader on the other side
                    return;
                },
            };
            const n: usize = @intCast(rc);
            std.mem.copyForwards(u8, s.outbox.items[0 .. s.outbox.items.len - n], s.outbox.items[n..]);
            s.outbox.items.len -= n;
        }
    }

    /// After the child: nothing to do but wait to be torn down.
    fn waitForStop(s: *Pty) void {
        while (!s.stop.load(.acquire)) {
            var fds = [_]c.pollfd{.{ .fd = s.kick, .events = c.POLL.IN, .revents = 0 }};
            _ = c.poll(&fds, 1, -1);
            scheduler.drainWakeFd(s.kick);
        }
    }

    /// Fork the child onto the pty's slave and exec its command. Everything
    /// the child needs is built BEFORE the fork: between fork and exec it may
    /// only make async-signal-safe calls (another thread may hold the
    /// allocator's lock, or libc's).
    fn forkChild(s: *Pty) !c.pid_t {
        var argv = [_:null]?[*:0]const u8{ "/bin/sh", "-c", s.cmd.ptr, null };
        const envp: [*:null]const ?[*:0]const u8 = if (s.environ.block.slice.len == 0) &[_:null]?[*:0]const u8{} else s.environ.block.slice.ptr;
        const prep: ChildPrep = .{
            .fd_limit = getdtablesize(),
            .dfl = .{ .handler = .{ .handler = c.SIG.DFL }, .mask = std.posix.sigemptyset(), .flags = 0 },
            .empty = std.posix.sigemptyset(),
        };
        const pid = c.fork();
        if (pid < 0) return error.ProcessSpawnFailed;
        if (pid != 0) return pid;
        childExec(s, &prep, &argv, envp);
    }

    const ChildPrep = struct {
        /// Upper bound of this process's fd numbers, for `closeInherited`.
        fd_limit: c_int,
        dfl: c.Sigaction,
        empty: c.sigset_t,
    };

    fn childExec(s: *Pty, prep: *const ChildPrep, argv: [*:null]const ?[*:0]const u8, envp: [*:null]const ?[*:0]const u8) noreturn {
        // A new session, whose controlling terminal is the slave: job control
        // and C-c's SIGINT reach the child's jobs, never weft.
        _ = c.setsid();
        // The slave was opened O_NOCTTY in the parent, so it becomes the
        // controlling terminal only by this ioctl — the one way on both
        // Linux and Darwin.
        // (Unchecked: a child without job control still runs.)
        _ = ioctl(s.slave, tioc.SCTTY, @as(c_int, 0));
        for (0..3) |i| {
            const fd: c_int = @intCast(i);
            _ = c.dup2(s.slave, fd);
            // dup2 onto itself (a slave that landed on 0–2) keeps its
            // close-on-exec flag; clear it on all three either way.
            _ = c.fcntl(fd, c.F.SETFD, @as(c_int, 0));
        }
        // Nothing of weft's leaks into the shell: not its window, its
        // sockets, nor the master (nor the slave's original number).
        closeInherited(prep.fd_limit);
        // Signal dispositions weft ignores and masks its threads block would
        // otherwise survive the exec, and a shell cannot undo an inherited
        // ignore: reset them.
        for ([_]c.SIG{ .HUP, .INT, .QUIT, .PIPE, .TERM, .CHLD, .TSTP, .TTIN, .TTOU, .WINCH, .ALRM, .USR1, .USR2 }) |sig|
            _ = c.sigaction(sig, &prep.dfl, null);
        _ = c.sigprocmask(c.SIG.SETMASK, &prep.empty, null);
        if (s.cwd) |cwd| {
            if (c.chdir(cwd.ptr) != 0) {
                const msg = "weft: cannot enter the terminal's directory\r\n";
                _ = c.write(2, msg, msg.len);
                c._exit(126);
            }
        }
        _ = c.execve("/bin/sh", argv, envp);
        const msg = "weft: cannot run /bin/sh\r\n";
        _ = c.write(2, msg, msg.len);
        c._exit(127);
    }
};

/// In the forked child: close every fd above stderr. Linux has one call for
/// it (glibc's `close_range`); elsewhere each number up to the process's fd
/// limit is closed in turn (`close` is async-signal-safe; EBADF on the gaps
/// is the expected answer).
fn closeInherited(fd_limit: c_int) void {
    if (builtin.os.tag == .linux) {
        const close_range = struct {
            extern "c" fn close_range(first: c_uint, last: c_uint, flags: c_int) c_int;
        }.close_range;
        if (close_range(3, std.math.maxInt(c_uint), 0) == 0) return;
    }
    var fd: c_int = 3;
    while (fd < fd_limit) : (fd += 1) _ = c.close(fd);
}

/// Open a pty pair: the master non-blocking and close-on-exec, the slave
/// close-on-exec and NOT our controlling terminal. The slave is opened here,
/// in the parent, as `openpty` does, so it is held from before the reader's
/// first `poll` until the child lets go: a master that has never had a slave
/// open reads as ended on some systems, and the reader must not take "not
/// opened yet" for "gone".
fn openPair() SpawnError!struct { master: c.fd_t, slave: c.fd_t } {
    const master = posix_openpt(@bitCast(c.O{ .ACCMODE = .RDWR, .NOCTTY = true }));
    if (master < 0) return error.PtyUnavailable;
    errdefer _ = c.close(master);
    if (!posix_fd.setCloexec(master) or !posix_fd.setNonblocking(master, true)) return error.PtyUnavailable;
    if (grantpt(master) != 0 or unlockpt(master) != 0) return error.PtyUnavailable;
    var path: [128:0]u8 = @splat(0);
    if (ptsname_r(master, &path, path.len) != 0) return error.PtyUnavailable;
    const slave = c.open(&path, .{ .ACCMODE = .RDWR, .NOCTTY = true, .CLOEXEC = true });
    if (slave < 0) return error.PtyUnavailable;
    // UTF-8 input: the line discipline's erase takes back a whole character.
    var tio: c.termios = undefined;
    if (c.tcgetattr(slave, &tio) == 0) {
        tio.iflag.IUTF8 = true;
        _ = c.tcsetattr(slave, .NOW, &tio);
    }
    return .{ .master = master, .slave = slave };
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
