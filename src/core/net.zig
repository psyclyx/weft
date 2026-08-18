//! net — the native TRANSPORT primitive: a byte-stream `Sock` (TCP today,
//! wasi-sockets-shaped tomorrow) plus one native TLS client. This is the
//! whole of what the host lends the guest for networking: *transport, not
//! protocol*. HTTP, WebSocket, gRPC — every wire format above the byte
//! stream — is built in the guest over a `Sock`; only TLS is native, and
//! only because one audited implementation is safer than N guest copies
//! (carve rule b: a single trust root). Shaping the socket like
//! wasi-sockets (connect → send/recv/close, EOF = a 0-length recv) means a
//! guest stdlib's socket layer lights up over this seam later with no
//! translation.
//!
//! Blocking discipline: a `Sock`'s `send`/`recv` are thin blocking
//! syscalls — they are NOT hot-path-safe and make no such claim. The frame
//! loop never calls them directly; the caller drives a `Sock` off-thread
//! (on a `task.Pool` worker, as `proc.zig` drives subprocess pipes) or over
//! a non-blocking fd it polls itself. `connect` is likewise blocking (it
//! reuses `session.tcpConnect`'s bounded non-blocking connect + poll, so a
//! dead host times out rather than wedging the worker).
//!
//! TLS lifetime: `TlsSock` wraps a `Sock` in a `std.crypto.tls.Client`
//! driven over a `std.Io` the CALLER owns and must keep alive for the
//! socket's lifetime (the Io backs every encrypted read/write). The client,
//! its four record buffers, the CA bundle, and the file reader/writer live
//! in one heap `TlsCtx` so their addresses stay stable — the tls client
//! stores interior pointers into them.
//!
//! Scope: the local ("here") tier only — `connect` dials from THIS process.
//! Dialing from a locus/peer vantage (through a session, from the far end)
//! is deferred.
//! TODO(locus): dial from the peer's vantage — forward `connect` over a
//! `session.Conn` so a sandboxed guest reaches the network its locus sees,
//! not ours.

const std = @import("std");
const linux = std.os.linux;
const Allocator = std.mem.Allocator;

const session = @import("session.zig");

const tls = std.crypto.tls;

// ── TCP byte-stream socket ──────────────────────────────────────────

/// Errors from the byte-stream read/write path. A clean end-of-stream is
/// NOT an error — `recv` returns 0 for it (wasi-sockets shape). `connect`
/// has its own inferred set (it delegates to `session.tcpConnect`).
pub const StreamError = error{
    /// The peer reset the connection (RST / broken pipe).
    ConnReset,
    /// A read/write syscall failed for another reason (bad fd, etc.).
    TransportFailed,
};

/// A connected byte stream over a single fd. Owns the fd; `close` exactly
/// once. Copyable (it is just an fd) — but a copy must not outlive the
/// `close` of any other copy.
pub const Sock = struct {
    fd: i32,

    /// Dial `host:port` (TCP). `host` is a dotted-quad or `localhost`
    /// (native name resolution is a guest concern; a resolver lands with
    /// the agent domain). Blocking with a bounded connect timeout — call
    /// off the frame thread. `gpa` is unused today; it is the seam for a
    /// future resolver's scratch allocation.
    pub fn connect(gpa: Allocator, hostport: []const u8) !Sock {
        _ = gpa;
        const fd = try session.tcpConnect(hostport);
        return .{ .fd = fd };
    }

    /// Wrap an already-connected fd (an accepted server end, a socketpair
    /// half). The fd must be blocking; ownership transfers to the `Sock`.
    pub fn fromFd(fd: i32) Sock {
        return .{ .fd = fd };
    }

    /// Write some bytes; returns how many were accepted (may be short — the
    /// caller loops). Blocking. `EINTR` is retried transparently.
    pub fn send(self: Sock, bytes: []const u8) StreamError!usize {
        while (true) {
            const rc = linux.write(self.fd, bytes.ptr, bytes.len);
            switch (linux.errno(rc)) {
                .SUCCESS => return rc,
                .INTR => continue,
                .PIPE, .CONNRESET => return error.ConnReset,
                else => return error.TransportFailed,
            }
        }
    }

    /// Read up to `buf.len` bytes; returns the count. A return of 0 is a
    /// clean end-of-stream (the peer hung up), NOT an error. Blocking.
    pub fn recv(self: Sock, buf: []u8) StreamError!usize {
        while (true) {
            const rc = linux.read(self.fd, buf.ptr, buf.len);
            switch (linux.errno(rc)) {
                .SUCCESS => return rc, // 0 == EOF
                .INTR => continue,
                .CONNRESET => return error.ConnReset,
                else => return error.TransportFailed,
            }
        }
    }

    pub fn close(self: Sock) void {
        _ = linux.close(self.fd);
    }
};

// ── Native TLS client over a Sock ───────────────────────────────────

/// Errors from the TLS path. Handshake failures (a hostile peer, a bad
/// cert, no CA store, a truncated stream) all surface as
/// `TlsHandshakeFailed` — the caller cannot recover them differently, and
/// the underlying std alert/verification detail is a log concern, not a
/// control-flow one.
pub const TlsError = error{
    TlsHandshakeFailed,
    TlsWriteFailed,
    TlsReadFailed,
} || Allocator.Error;

/// Each of the tls client's four buffers is sized to a full ciphertext
/// record — the std client asserts at least this much on both the socket
/// reader and its own read buffer.
const buf_len = tls.Client.min_buffer_len;

/// Everything a live TLS connection needs at a STABLE address: the tls
/// client stores interior pointers to the file reader/writer interfaces and
/// to these buffers, so the whole thing is one heap allocation that never
/// moves until `close`.
const TlsCtx = struct {
    sock: Sock,
    /// Caller-owned Io, kept only as a handle for reads/writes/close.
    io: std.Io,
    /// System trust roots, loaded once at connect. Freed in `close`.
    bundle: std.crypto.Certificate.Bundle,
    ca_lock: std.Io.RwLock,
    reader: std.Io.File.Reader,
    writer: std.Io.File.Writer,
    client: tls.Client,
    socket_read: [buf_len]u8,
    socket_write: [buf_len]u8,
    tls_read: [buf_len]u8,
    tls_write: [buf_len]u8,
};

/// A TLS 1.2/1.3 client stream. Same blocking discipline as `Sock`: drive
/// it off the frame thread. `send`/`recv`/`close` route plaintext through
/// the tls client; the record layer rides the wrapped `Sock`.
pub const TlsSock = struct {
    gpa: Allocator,
    ctx: *TlsCtx,

    /// Dial `host:port`, then run the TLS handshake, verifying the server
    /// against the system CA store for `host_name`. `io` must outlive the
    /// returned socket. Blocking (full handshake round trip).
    pub fn connectTls(
        gpa: Allocator,
        io: std.Io,
        hostport: []const u8,
        host_name: []const u8,
    ) TlsError!TlsSock {
        const sock = Sock.connect(gpa, hostport) catch return error.TlsHandshakeFailed;
        errdefer sock.close();
        return handshake(gpa, io, sock, host_name);
    }

    /// Run the TLS handshake over an ALREADY-connected `Sock` (ownership of
    /// the sock transfers in; it is closed by `close`). Split out from
    /// `connectTls` so the transport and the crypto compose independently —
    /// and so the handshake is exercisable over a loopback fd.
    pub fn handshake(
        gpa: Allocator,
        io: std.Io,
        sock: Sock,
        host_name: []const u8,
    ) TlsError!TlsSock {
        const ctx = try gpa.create(TlsCtx);
        errdefer gpa.destroy(ctx);
        ctx.sock = sock;
        ctx.io = io;
        ctx.bundle = .empty;
        ctx.ca_lock = .init;
        // Best-effort: a host with no CA store yields an empty bundle, and
        // the handshake below then fails verification honestly rather than
        // trusting nothing silently.
        ctx.bundle.rescan(gpa, io, std.Io.Clock.now(.real, io)) catch {};
        errdefer ctx.bundle.deinit(gpa);

        const file: std.Io.File = .{ .handle = sock.fd, .flags = .{ .nonblocking = false } };
        ctx.reader = file.readerStreaming(io, &ctx.socket_read);
        ctx.writer = file.writerStreaming(io, &ctx.socket_write);

        var entropy: [tls.Client.Options.entropy_len]u8 = undefined;
        io.random(&entropy);

        ctx.client = tls.Client.init(&ctx.reader.interface, &ctx.writer.interface, .{
            .host = .{ .explicit = host_name },
            .ca = .{ .bundle = .{
                .gpa = gpa,
                .io = io,
                .lock = &ctx.ca_lock,
                .bundle = &ctx.bundle,
            } },
            .read_buffer = &ctx.tls_read,
            .write_buffer = &ctx.tls_write,
            .entropy = &entropy,
            .realtime_now = std.Io.Clock.now(.real, io),
        }) catch return error.TlsHandshakeFailed;

        return .{ .gpa = gpa, .ctx = ctx };
    }

    /// Encrypt and send all of `bytes`; returns `bytes.len` on success
    /// (the tls client buffers, so a partial write is not surfaced). Flushes
    /// to the wire before returning.
    pub fn send(self: TlsSock, bytes: []const u8) TlsError!usize {
        const c = &self.ctx.client;
        c.writer.writeAll(bytes) catch return error.TlsWriteFailed;
        c.writer.flush() catch return error.TlsWriteFailed; // encrypt → output
        self.ctx.writer.interface.flush() catch return error.TlsWriteFailed; // output → fd
        return bytes.len;
    }

    /// Read and decrypt up to `buf.len` bytes; returns the count. 0 is a
    /// clean end-of-stream (peer sent close_notify / hung up), matching
    /// `Sock.recv`.
    pub fn recv(self: TlsSock, buf: []u8) TlsError!usize {
        return self.ctx.client.reader.readSliceShort(buf) catch return error.TlsReadFailed;
    }

    /// Send close_notify (best effort), close the fd, and free the context.
    pub fn close(self: TlsSock) void {
        self.ctx.client.end() catch {};
        self.ctx.writer.interface.flush() catch {};
        self.ctx.sock.close();
        self.ctx.bundle.deinit(self.gpa);
        self.gpa.destroy(self.ctx);
    }
};

// ── Tests ───────────────────────────────────────────────────────────
// TCP is exercised for real over a socketpair and a loopback listener (no
// external network). TLS is exercised as far as is honest offline: the CA
// rescan runs, and the handshake is driven far enough to prove a real
// ClientHello reaches the wire. A full TLS round trip needs a network peer
// with a valid cert and is exercised in the agent domain (plan 04), not
// here — see the comment on that test.

const t = std.testing;

fn socketPair() ![2]i32 {
    var fds: [2]i32 = undefined;
    const rc = linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM, 0, &fds);
    if (linux.errno(rc) != .SUCCESS) return error.SocketPair;
    return fds;
}

test "net: TCP Sock round-trips bytes both ways over a socketpair" {
    const fds = try socketPair();
    const a = Sock.fromFd(fds[0]);
    defer a.close();
    const b = Sock.fromFd(fds[1]);
    defer b.close();

    try t.expectEqual(@as(usize, 4), try a.send("ping"));
    var buf: [16]u8 = undefined;
    const got = try b.recv(&buf);
    try t.expectEqualStrings("ping", buf[0..got]);

    try t.expectEqual(@as(usize, 6), try b.send("pong!!"));
    const got2 = try a.recv(&buf);
    try t.expectEqualStrings("pong!!", buf[0..got2]);
}

test "net: recv returns 0 at EOF once the peer hangs up" {
    const fds = try socketPair();
    const a = Sock.fromFd(fds[0]);
    defer a.close();
    const b = Sock.fromFd(fds[1]);
    b.close(); // peer closes its end

    var buf: [4]u8 = undefined;
    try t.expectEqual(@as(usize, 0), try a.recv(&buf));
}

test "net: Sock.connect reaches a live loopback listener" {
    // Bind an ephemeral loopback port; skip if the sandbox forbids it
    // (mirrors session.zig's tcpConnect test).
    const listener = session.tcpListener(0) catch return;
    defer _ = linux.close(listener);
    var addr: linux.sockaddr.in = undefined;
    var alen: linux.socklen_t = @sizeOf(linux.sockaddr.in);
    if (linux.errno(linux.getsockname(listener, @ptrCast(&addr), &alen)) != .SUCCESS) return;
    const port = std.mem.bigToNative(u16, addr.port);

    const hostport = try std.fmt.allocPrint(t.allocator, "127.0.0.1:{d}", .{port});
    defer t.allocator.free(hostport);

    const Accept = struct {
        fn go(l: i32) void {
            const cfd = session.tcpAccept(l) catch return;
            const srv = Sock.fromFd(cfd);
            defer srv.close();
            _ = srv.send("hi") catch {};
        }
    };
    var th = try std.Thread.spawn(.{}, Accept.go, .{listener});
    defer th.join();

    const sock = Sock.connect(t.allocator, hostport) catch return;
    defer sock.close();
    var buf: [2]u8 = undefined;
    var got: usize = 0;
    while (got < 2) {
        const n = try sock.recv(buf[got..]);
        if (n == 0) break;
        got += n;
    }
    try t.expectEqualStrings("hi", buf[0..got]);
}

test "net: TLS — system CA bundle rescans without crashing (offline-safe)" {
    const gpa = t.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var bundle: std.crypto.Certificate.Bundle = .empty;
    defer bundle.deinit(gpa);
    // A host without a CA store is tolerated: the only claim is that the
    // rescan neither crashes nor leaks (testing allocator would flag a leak).
    bundle.rescan(gpa, io, std.Io.Clock.now(.real, io)) catch {};
}

test "net: TLS handshake emits a real ClientHello onto the wire" {
    // What this DOES verify: TlsSock.handshake drives std.crypto.tls.Client
    // to generate and transmit a genuine TLS ClientHello over a real fd —
    // the record header (0x16 handshake, 0x03 version-major) lands on the
    // peer. It confirms the buffer wiring, the Io/reader/writer plumbing,
    // and entropy/bundle setup are all correct end-to-end up to first flight.
    //
    // What it does NOT (cannot, offline) verify: a full handshake, server
    // cert verification against the CA bundle, or an encrypted round trip —
    // those need a live peer holding a valid certificate. The "server" here
    // reads the first record then hangs up, so `handshake` returns
    // TlsHandshakeFailed by design. The real TLS round trip is exercised in
    // the agent domain (plan 04) against an actual endpoint.
    const gpa = t.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const fds = try socketPair();

    const Peer = struct {
        fn go(fd: i32, out: *[5]u8, n: *usize) void {
            var got: usize = 0;
            while (got < 5) {
                const rc = linux.read(fd, out[got..].ptr, 5 - got);
                if (linux.errno(rc) != .SUCCESS) break;
                if (rc == 0) break;
                got += rc;
            }
            n.* = got;
            _ = linux.close(fd); // hang up to unblock the client's read
        }
    };
    var hdr: [5]u8 = .{0} ** 5;
    var got: usize = 0;
    var th = try std.Thread.spawn(.{}, Peer.go, .{ fds[1], &hdr, &got });

    const sock = Sock.fromFd(fds[0]);
    // The handshake fails (the peer closes after one record), but the
    // ClientHello reaches the peer first — which is exactly what we assert.
    if (TlsSock.handshake(gpa, io, sock, "example.com")) |ts| {
        ts.close();
    } else |_| {
        sock.close();
    }

    // Join before asserting so `hdr`/`got` are fully written by the peer.
    th.join();
    try t.expect(got >= 2);
    try t.expectEqual(@as(u8, 0x16), hdr[0]); // TLS record: handshake
    try t.expectEqual(@as(u8, 0x03), hdr[1]); // ProtocolVersion major (TLS 1.x)
}

test {
    std.testing.refAllDecls(@This());
}
