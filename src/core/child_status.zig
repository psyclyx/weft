//! child_status — how a child process ended, read with POSIX `waitid` and
//! `waitpid` from libc (no `std.Io`): an exit code, or 128 + the signal that
//! killed it, the way a shell reports `$?`.
//!
//! Two reads, because two owners need them:
//! - `peek` — PEEK (`WNOWAIT`): the child is left a zombie, still reapable
//!   by whoever owns reaping (`std.process.Child.wait`, `reap`). `.wait`
//!   blocks until it ends; `.poll` answers null while it runs. Blocking
//!   without reaping is what lets a watcher thread report a child's end
//!   while the pid stays reserved — nobody can signal a recycled pid, since
//!   until the owner reaps there is nothing to recycle.
//! - `reap` — `waitpid`: collects it.
//!
//! `waitid` and its constants are declared here, not taken from `std.c`,
//! which carries neither for Darwin. `P_PID`, `WEXITED`, `WNOHANG` and the
//! `CLD_*` codes are the same number on Linux and Darwin; `WNOWAIT` is not.

const std = @import("std");
const builtin = @import("builtin");
const c = std.c;

const P_PID: c_int = 1;
const WEXITED: c_int = 4;
const WNOHANG: c_int = 1;
const WNOWAIT: c_int = switch (builtin.os.tag) {
    .linux => 0x01000000,
    .macos, .ios, .tvos, .visionos, .watchos, .maccatalyst, .driverkit => 0x20,
    else => @compileError("child_status: WNOWAIT unknown for this OS"),
};
const CLD_EXITED = 1;
const CLD_KILLED = 2;
const CLD_DUMPED = 3;

extern "c" fn waitid(idtype: c_int, id: c_uint, infop: *c.siginfo_t, options: c_int) c_int;

pub const Peek = enum { poll, wait };

/// Has `pid` (our child) ended? Its code if so, without reaping it. `.poll`
/// answers null while it runs; `.wait` blocks until it ends. Null too if the
/// question cannot be asked (no such child: already reaped elsewhere).
pub fn peek(pid: c.pid_t, how: Peek) ?u8 {
    var info: c.siginfo_t = undefined;
    while (true) {
        // A child still running under WNOHANG leaves the pid field 0 — on
        // both OSes, but only if it was 0 going in.
        @memset(std.mem.asBytes(&info), 0);
        const flags = WEXITED | WNOWAIT | (if (how == .poll) WNOHANG else 0);
        const rc = waitid(P_PID, @intCast(pid), &info, flags);
        if (rc == 0) break;
        if (c.errno(rc) == .INTR) continue;
        return null;
    }
    const got_pid, const code, const status = switch (builtin.os.tag) {
        .linux => .{ info.fields.common.first.piduid.pid, info.code, info.fields.common.second.sigchld.status },
        else => .{ info.pid, info.code, info.status },
    };
    if (got_pid == 0) return null; // still running (`.poll`)
    const low: u8 = @truncate(@as(u32, @bitCast(status)));
    return switch (code) {
        CLD_EXITED => low,
        CLD_KILLED, CLD_DUMPED => 128 +| low,
        else => null, // stopped/continued: not asked for, not an end
    };
}

/// Reap `pid` — ended, or killed just now, so this returns promptly —
/// returning its exit code or 128 + the signal that killed it (127 if it
/// cannot be reaped: someone else already did).
pub fn reap(pid: c.pid_t) u8 {
    var status: c_int = 0;
    while (true) {
        const rc = c.waitpid(pid, &status, 0);
        if (rc >= 0) break;
        if (c.errno(rc) != .INTR) return 127;
    }
    const s: u32 = @bitCast(status);
    if (c.W.IFEXITED(s)) return c.W.EXITSTATUS(s);
    if (c.W.IFSIGNALED(s)) return 128 +| @as(u8, @truncate(@intFromEnum(c.W.TERMSIG(s))));
    return 127;
}

const t = std.testing;

fn forkExit(code: u8) !c.pid_t {
    const pid = c.fork();
    if (pid < 0) return error.ForkFailed;
    if (pid == 0) c._exit(code);
    return pid;
}

test "child_status: a peek leaves the child reapable, and both read its code" {
    const pid = try forkExit(7);
    try t.expectEqual(@as(?u8, 7), peek(pid, .wait));
    try t.expectEqual(@as(?u8, 7), peek(pid, .poll)); // still there: peeked, not reaped
    try t.expectEqual(@as(u8, 7), reap(pid));
    try t.expectEqual(@as(?u8, null), peek(pid, .poll)); // gone now
}

test "child_status: a signal's end reads as 128 + the signal" {
    const pid = c.fork();
    try t.expect(pid >= 0);
    if (pid == 0) {
        _ = c.kill(c.getpid(), .KILL);
        c._exit(0);
    }
    try t.expectEqual(@as(?u8, 128 + 9), peek(pid, .wait));
    try t.expectEqual(@as(u8, 128 + 9), reap(pid));
}
