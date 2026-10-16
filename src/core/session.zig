//! `session` — the encrypted, multiplexed peer link (wire v1) and the
//! document-sync stack that rides it. This is the package facade: a thin,
//! curated re-export of the surface, plus the TCP bootstrap helpers shared
//! by the editor and the agent. The implementations live in focused files
//! under `session/`:
//!
//! - `session/link.zig`      — `Link`/`FdLink`/`ChaosLink` transport +
//!                             the futex `Mutex` (a namespace).
//! - `session/clock.zig`     — the monotonic `Clock` that liveness,
//!                             heartbeats and chaos eligibility read
//!                             through, plus the hand-advanced `Virtual`.
//! - `session/Session.zig`   — `Session` (reader/writer threads, handshake,
//!                             liveness, crypto), with `Access`/`Liveness`.
//! - `session/requests.zig`  — class-2 request ids with a deadline each
//!                             (a namespace).
//! - `session/remote_fs.zig` — `BlobServer`/`serveBase` (host serving),
//!                             `RemoteFile`/`RemoteFs`/`RemoteLsp`, `BlobOp`
//!                             (a namespace).
//! - `session/publication.zig` — the typed export set a quad publishes
//!                             (replica + endpoint surfaces), its wire
//!                             descriptor, and the frame→surface gate.
//! - `session/PartialDoc.zig`— editable partial checkout.
//! - `session/Collab.zig`    — per-document (TextDoc) sync driver.
//! - `session/GraphCollab.zig` — per-document (GraphDoc) sync driver, the
//!                             shared frontier/batch core WITHOUT the
//!                             text-only presence/diagnostics/blob/partial
//!                             machinery (stemma delta 5).
//! - `session/Conn.zig`      — N shared buffers (text or graph) over one
//!                             session.
//!
//! The cross-cutting integration tests (two live sessions over a
//! socketpair) live in `session/tests.zig`.

const std = @import("std");
const builtin = @import("builtin");
const c = std.c;
const posix_fd = @import("posix_fd.zig");

// ── Curated re-exports ──────────────────────────────────────────────

const clock_mod = @import("session/clock.zig");
pub const Clock = clock_mod.Clock;
pub const VirtualClock = clock_mod.Virtual;

const link_mod = @import("session/link.zig");
pub const Link = link_mod.Link;
pub const FdLink = link_mod.FdLink;
pub const ChaosLink = link_mod.ChaosLink;

pub const Session = @import("session/Session.zig");
pub const Liveness = Session.Liveness;
pub const Access = Session.Access;

pub const requests = @import("session/requests.zig");

/// The `grant` frame's per-export payload (§13.5) + the grantee-side
/// `Announced` state its preflight reads.
pub const export_grants = @import("session/export_grants.zig");

const remote_fs = @import("session/remote_fs.zig");
pub const blob_channel = remote_fs.blob_channel;
pub const BlobOp = remote_fs.BlobOp;
pub const BlobServer = remote_fs.BlobServer;
pub const RemoteFile = remote_fs.RemoteFile;
pub const RemoteFs = remote_fs.RemoteFs;
pub const RemoteLsp = remote_fs.RemoteLsp;

pub const publication = @import("session/publication.zig");
pub const Publication = publication.Publication;
pub const ExportSpec = publication.ExportSpec;

pub const PartialDoc = @import("session/PartialDoc.zig");
pub const Collab = @import("session/Collab.zig");
pub const GraphCollab = @import("session/GraphCollab.zig");
pub const Conn = @import("session/Conn.zig");

// ── TCP bootstrap (shared by editor and agent) ──────────────────────

/// Every socket weft makes is close-on-exec (a launched tool must not hold a
/// peer's connection open) and, on Darwin, `SO_NOSIGPIPE`. Sockets are
/// written with plain `write(2)`, which raises SIGPIPE on a peer that hung
/// up; while a `std.Io.Threaded` lives (main's does, for the process's life)
/// its handler absorbs that and the write answers EPIPE. Darwin has no
/// `MSG_NOSIGNAL` but does have the per-socket option, so there a broken
/// socket answers EPIPE with or without that handler. Best effort — a
/// refused option leaves a working socket.
fn ownSocket(fd: i32) void {
    _ = posix_fd.setCloexec(fd);
    if (comptime builtin.os.tag.isDarwin()) {
        const one: c_int = 1;
        _ = c.setsockopt(fd, c.SOL.SOCKET, c.SO.NOSIGPIPE, &one, @sizeOf(c_int));
    }
}

pub fn tcpListener(port: u16) !i32 {
    const fd = c.socket(c.AF.INET, c.SOCK.STREAM, 0);
    if (fd < 0) return error.Socket;
    errdefer _ = c.close(fd);
    ownSocket(fd);
    const one: c_int = 1;
    _ = c.setsockopt(fd, c.SOL.SOCKET, c.SO.REUSEADDR, &one, @sizeOf(c_int));
    var addr: c.sockaddr.in = .{ .port = std.mem.nativeToBig(u16, port), .addr = 0 };
    if (c.bind(fd, @ptrCast(&addr), @sizeOf(c.sockaddr.in)) != 0) return error.Bind;
    if (c.listen(fd, 8) != 0) return error.Listen;
    return fd;
}

/// Return the port currently bound to a TCP listener. This is especially
/// useful for callers that ask the OS for an ephemeral port (`port == 0`):
/// the endpoint remains owned by the listener, while callers can advertise
/// the resolved port without reaching into platform socket details.
pub fn tcpListenerPort(listener: i32) !u16 {
    var addr: c.sockaddr.in = undefined;
    var addr_len: c.socklen_t = @sizeOf(c.sockaddr.in);
    if (c.getsockname(listener, @ptrCast(&addr), &addr_len) != 0)
        return error.SocketName;
    return std.mem.bigToNative(u16, addr.port);
}

pub fn tcpAccept(listener: i32) !i32 {
    const conn = c.accept(listener, null, null);
    if (conn < 0) return error.Accept;
    ownSocket(conn);
    return conn;
}

/// Single-peer convenience (editor pairing): accept one, close the
/// listener.
pub fn tcpListen(port: u16) !i32 {
    const listener = try tcpListener(port);
    defer _ = c.close(listener);
    return tcpAccept(listener);
}

/// A connected pair of local stream sockets (AF_UNIX) — an in-process
/// stand-in for a TCP connection, owned like every other socket here.
pub fn unixSocketPair() ![2]i32 {
    var fds: [2]i32 = undefined;
    if (c.socketpair(c.AF.UNIX, c.SOCK.STREAM, 0, &fds) != 0) return error.SocketPair;
    for (fds) |fd| ownSocket(fd);
    return fds;
}

/// How long a TCP connect may take before we give up. Bounds every
/// connect path (boot, runtime, reconnect) so an unreachable host can
/// never wedge the caller — the editor's frame thread included.
pub const connect_timeout_ms: i32 = 8000;

pub fn tcpConnect(hostport: []const u8) !i32 {
    const colon = std.mem.lastIndexOfScalar(u8, hostport, ':') orelse return error.BadAddress;
    const host = hostport[0..colon];
    const port = std.fmt.parseInt(u16, hostport[colon + 1 ..], 10) catch return error.BadAddress;
    const ip = if (std.mem.eql(u8, host, "localhost")) "127.0.0.1" else host;
    var octets: [4]u8 = undefined;
    var it = std.mem.splitScalar(u8, ip, '.');
    for (&octets) |*o| {
        const part = it.next() orelse return error.BadAddress;
        o.* = std.fmt.parseInt(u8, part, 10) catch return error.BadAddress;
    }
    // Non-blocking connect + a bounded poll, so a dead host times out
    // instead of blocking indefinitely in the connect syscall.
    const fd = c.socket(c.AF.INET, c.SOCK.STREAM, 0);
    if (fd < 0) return error.Socket;
    errdefer _ = c.close(fd);
    ownSocket(fd);
    if (!posix_fd.setNonblocking(fd, true)) return error.Socket;
    var addr: c.sockaddr.in = .{
        .port = std.mem.nativeToBig(u16, port),
        .addr = std.mem.bytesToValue(u32, &octets),
    };
    switch (c.errno(c.connect(fd, @ptrCast(&addr), @sizeOf(c.sockaddr.in)))) {
        .SUCCESS => {}, // connected immediately (e.g. localhost)
        .INPROGRESS, .INTR, .AGAIN => {
            // Wait until writable (or the deadline), then read SO_ERROR.
            var pfd = [1]c.pollfd{.{ .fd = fd, .events = c.POLL.OUT, .revents = 0 }};
            const prc = c.poll(&pfd, 1, connect_timeout_ms);
            if (prc < 0) return error.Connect;
            if (prc == 0) return error.ConnectTimeout;
            var sockerr: c_int = 0;
            var len: c.socklen_t = @sizeOf(c_int);
            _ = c.getsockopt(fd, c.SOL.SOCKET, c.SO.ERROR, &sockerr, &len);
            if (sockerr != 0) return error.Connect;
        },
        else => return error.Connect,
    }
    // Back to blocking: the reader/writer threads expect blocking I/O.
    _ = posix_fd.setNonblocking(fd, false);
    return fd;
}

test {
    std.testing.refAllDecls(@This());
    _ = @import("session/clock.zig");
    _ = @import("session/export_grants.zig");
    _ = @import("session/tests.zig");
}
