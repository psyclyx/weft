//! posix_fd — the per-descriptor flags POSIX sets with `fcntl`, for the fds
//! weft makes itself (wake pipes, a pty master, sockets). Linux can ask for
//! these at creation (`SOCK_NONBLOCK|SOCK_CLOEXEC`, `pipe2`, `O_CLOEXEC` on
//! `/dev/ptmx`); Darwin cannot — no `pipe2`, no type flags on `socket` — so
//! every creator sets them after the fact, the same way on every OS, here.
//!
//! Setting close-on-exec after creation leaves a window in which a fork+exec
//! on another thread inherits the fd. `pty.zig`'s child closes everything
//! above stderr itself; a std-spawned child would keep the stray fd until it
//! exits — a wake pipe end or a socket held open a little longer, never a
//! wrong answer here.

const std = @import("std");
const c = std.c;

const o_nonblock: u32 = @bitCast(c.O{ .NONBLOCK = true });

/// Set or clear O_NONBLOCK. False when the descriptor refused.
pub fn setNonblocking(fd: c.fd_t, on: bool) bool {
    const flags = c.fcntl(fd, c.F.GETFL);
    if (flags < 0) return false;
    const bits: u32 = @bitCast(flags);
    const next: u32 = if (on) bits | o_nonblock else bits & ~o_nonblock;
    return c.fcntl(fd, c.F.SETFL, @as(c_int, @bitCast(next))) >= 0;
}

/// Mark the descriptor close-on-exec. False when it refused.
pub fn setCloexec(fd: c.fd_t) bool {
    const flags = c.fcntl(fd, c.F.GETFD);
    if (flags < 0) return false;
    return c.fcntl(fd, c.F.SETFD, flags | @as(c_int, c.FD_CLOEXEC)) >= 0;
}

/// A non-blocking, close-on-exec pipe: `[0]` reads, `[1]` writes.
pub fn pipe() error{PipeFailed}![2]c.fd_t {
    var fds: [2]c.fd_t = undefined;
    if (c.pipe(&fds) != 0) return error.PipeFailed;
    for (fds) |fd| {
        if (!setNonblocking(fd, true) or !setCloexec(fd)) {
            _ = c.close(fds[0]);
            _ = c.close(fds[1]);
            return error.PipeFailed;
        }
    }
    return fds;
}

const t = std.testing;

test "posix_fd: a pipe is non-blocking and close-on-exec at both ends" {
    const fds = try pipe();
    defer for (fds) |fd| {
        _ = c.close(fd);
    };
    for (fds) |fd| {
        try t.expect(@as(u32, @bitCast(c.fcntl(fd, c.F.GETFL))) & o_nonblock != 0);
        try t.expect(c.fcntl(fd, c.F.GETFD) & @as(c_int, c.FD_CLOEXEC) != 0);
    }
    // Empty and non-blocking: a read answers EAGAIN instead of parking.
    var b: [1]u8 = undefined;
    try t.expectEqual(c.E.AGAIN, c.errno(c.read(fds[0], &b, 1)));
}
