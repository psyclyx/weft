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
const linux = std.os.linux;

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

pub fn tcpListener(port: u16) !i32 {
    const fd_rc = linux.socket(linux.AF.INET, linux.SOCK.STREAM, 0);
    if (linux.errno(fd_rc) != .SUCCESS) return error.Socket;
    const fd: i32 = @intCast(fd_rc);
    var one: i32 = 1;
    _ = linux.setsockopt(fd, linux.SOL.SOCKET, linux.SO.REUSEADDR, @ptrCast(&one), 4);
    var addr: linux.sockaddr.in = .{ .port = std.mem.nativeToBig(u16, port), .addr = 0 };
    if (linux.errno(linux.bind(fd, @ptrCast(&addr), @sizeOf(linux.sockaddr.in))) != .SUCCESS) return error.Bind;
    if (linux.errno(linux.listen(fd, 8)) != .SUCCESS) return error.Listen;
    return fd;
}

/// Return the port currently bound to a TCP listener. This is especially
/// useful for callers that ask the OS for an ephemeral port (`port == 0`):
/// the endpoint remains owned by the listener, while callers can advertise
/// the resolved port without reaching into platform socket details.
pub fn tcpListenerPort(listener: i32) !u16 {
    var addr: linux.sockaddr.in = undefined;
    var addr_len: linux.socklen_t = @sizeOf(linux.sockaddr.in);
    if (linux.errno(linux.getsockname(listener, @ptrCast(&addr), &addr_len)) != .SUCCESS)
        return error.SocketName;
    return std.mem.bigToNative(u16, addr.port);
}

pub fn tcpAccept(listener: i32) !i32 {
    const conn_rc = linux.accept4(listener, null, null, 0);
    if (linux.errno(conn_rc) != .SUCCESS) return error.Accept;
    return @intCast(conn_rc);
}

/// Single-peer convenience (editor pairing): accept one, close the
/// listener.
pub fn tcpListen(port: u16) !i32 {
    const listener = try tcpListener(port);
    defer _ = linux.close(listener);
    return tcpAccept(listener);
}

/// How long a TCP connect may take before we give up. Bounds every
/// connect path (boot, runtime, reconnect) so an unreachable host can
/// never wedge the caller — the editor's frame thread included.
pub const connect_timeout_ms: i32 = 8000;

/// O_NONBLOCK as a file-status flag (Linux x86_64/arm64); numerically the
/// same as SOCK.NONBLOCK, which is why socket(...|SOCK.NONBLOCK) sets it.
const o_nonblock: usize = 0o4000;

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
    const fd_rc = linux.socket(linux.AF.INET, linux.SOCK.STREAM | linux.SOCK.NONBLOCK, 0);
    if (linux.errno(fd_rc) != .SUCCESS) return error.Socket;
    const fd: i32 = @intCast(fd_rc);
    errdefer _ = linux.close(fd);
    var addr: linux.sockaddr.in = .{
        .port = std.mem.nativeToBig(u16, port),
        .addr = std.mem.bytesToValue(u32, &octets),
    };
    switch (linux.errno(linux.connect(fd, @ptrCast(&addr), @sizeOf(linux.sockaddr.in)))) {
        .SUCCESS => {}, // connected immediately (e.g. localhost)
        .INPROGRESS, .INTR, .AGAIN => {
            // Wait until writable (or the deadline), then read SO_ERROR.
            var pfd: linux.pollfd = .{ .fd = fd, .events = linux.POLL.OUT, .revents = 0 };
            const prc = linux.poll(@ptrCast(&pfd), 1, connect_timeout_ms);
            if (linux.errno(prc) != .SUCCESS) return error.Connect;
            if (prc == 0) return error.ConnectTimeout;
            var sockerr: i32 = 0;
            var len: linux.socklen_t = @sizeOf(i32);
            _ = linux.getsockopt(fd, linux.SOL.SOCKET, linux.SO.ERROR, @ptrCast(&sockerr), &len);
            if (sockerr != 0) return error.Connect;
        },
        else => return error.Connect,
    }
    // Back to blocking: the reader/writer threads expect blocking I/O.
    const flags = linux.fcntl(fd, linux.F.GETFL, 0);
    _ = linux.fcntl(fd, linux.F.SETFL, flags & ~o_nonblock);
    return fd;
}

test {
    std.testing.refAllDecls(@This());
    _ = @import("session/clock.zig");
    _ = @import("session/export_grants.zig");
    _ = @import("session/tests.zig");
}
