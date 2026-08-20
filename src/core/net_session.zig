//! net_session — a persistent network connection behind a buffer (design §4
//! Group D `net.connect`, §6.5 agents). The socket mirror of `repl_session`:
//! `send` writes bytes, a blocking reader task streams the socket into a
//! mutex-guarded accumulator the frame thread drains into a buffer (authored as
//! the plugin peer). Teardown SHUTs the socket so the reader's `recv` returns
//! EOF, then JOINS it before closing/freeing — no use-after-free, no hang.
//! Plaintext TCP and native TLS (verified against the system CA store).

const std = @import("std");
const Allocator = std.mem.Allocator;
const command = @import("command.zig");
const Buffers = @import("Buffers.zig");
const task = @import("task.zig");
const net = @import("net.zig");

const Conn = union(enum) {
    plain: net.Sock,
    tls: net.TlsSock,

    fn send(self: Conn, bytes: []const u8) !usize {
        return switch (self) {
            .plain => |s| s.send(bytes),
            .tls => |s| s.send(bytes),
        };
    }
    fn recv(self: Conn, buf: []u8) !usize {
        return switch (self) {
            .plain => |s| s.recv(buf),
            .tls => |s| s.recv(buf),
        };
    }
    fn fd(self: Conn) i32 {
        return switch (self) {
            .plain => |s| s.fd,
            .tls => |s| s.ctx.sock.fd,
        };
    }
    fn close(self: Conn) void {
        switch (self) {
            .plain => |s| s.close(),
            .tls => |s| s.close(),
        }
    }
};

pub const Session = struct {
    gpa: Allocator,
    ctx: *command.Context,
    plugin: []u8,
    buf: []u8,
    io_threaded: std.Io.Threaded, // for the TLS handshake io
    conn: Conn,
    out_mutex: task.Mutex = .{},
    out_buf: std.ArrayList(u8) = .empty,
    reader: task.Handle(void),

    /// Dial `hostport` (plaintext, or TLS verifying `host_name`) and stream it.
    pub fn start(
        gpa: Allocator,
        pool: *task.Pool,
        ctx: *command.Context,
        plugin: []const u8,
        buf: []const u8,
        hostport: []const u8,
        host_name: ?[]const u8, // non-null → TLS
    ) !*Session {
        const s = try alloc(gpa, ctx, plugin, buf);
        errdefer free(s);
        if (host_name) |hn| {
            s.conn = .{ .tls = net.TlsSock.connectTls(gpa, s.io_threaded.io(), hostport, hn) catch return error.ConnectFailed };
        } else {
            s.conn = .{ .plain = net.Sock.connect(gpa, hostport) catch return error.ConnectFailed };
        }
        s.reader = try pool.spawn(readLoop, .{s});
        return s;
    }

    /// Wrap an already-connected fd (tests, socketpairs). Plaintext.
    pub fn startFd(gpa: Allocator, pool: *task.Pool, ctx: *command.Context, plugin: []const u8, buf: []const u8, fd: i32) !*Session {
        const s = try alloc(gpa, ctx, plugin, buf);
        errdefer free(s);
        s.conn = .{ .plain = net.Sock.fromFd(fd) };
        s.reader = try pool.spawn(readLoop, .{s});
        return s;
    }

    fn alloc(gpa: Allocator, ctx: *command.Context, plugin: []const u8, buf: []const u8) !*Session {
        const s = try gpa.create(Session);
        s.* = .{
            .gpa = gpa,
            .ctx = ctx,
            .plugin = try gpa.dupe(u8, plugin),
            .buf = try gpa.dupe(u8, buf),
            .io_threaded = .init(gpa, .{}),
            .conn = undefined,
            .reader = undefined,
        };
        return s;
    }
    fn free(s: *Session) void {
        const gpa = s.gpa;
        s.io_threaded.deinit();
        gpa.free(s.plugin);
        gpa.free(s.buf);
        gpa.destroy(s);
    }

    fn readLoop(s: *Session) void {
        var buf: [4096]u8 = undefined;
        while (true) {
            const n = s.conn.recv(&buf) catch break;
            if (n == 0) break; // EOF (peer hung up or we shut down)
            s.out_mutex.lock();
            s.out_buf.appendSlice(s.gpa, buf[0..n]) catch {};
            s.out_mutex.unlock();
        }
    }

    /// Frame thread: drain streamed bytes into the buffer (append, plugin peer).
    pub fn drain(s: *Session) bool {
        s.out_mutex.lock();
        defer s.out_mutex.unlock();
        if (s.out_buf.items.len == 0) return false;
        const bufs = s.ctx.buffers;
        var target: ?*Buffers.Buffer = null;
        var it = bufs.iterator();
        while (it.next()) |b| if (std.mem.eql(u8, b.name, s.buf)) {
            target = b;
            break;
        };
        if (target == null) {
            const id = bufs.create(s.gpa, s.buf) catch return false;
            target = bufs.get(id);
        }
        const b = target orelse return false;
        const doc = &b.editor.doc;
        const end = b.editor.text().byteLen();
        command.renderInto(s.gpa, doc, .plugin, s.plugin, &.{.{ .range = .{ .start = end, .end = end }, .bytes = s.out_buf.items }}) catch {
            s.out_buf.clearRetainingCapacity();
            return false;
        };
        s.out_buf.clearRetainingCapacity();
        return true;
    }

    /// Frame thread: send bytes (looping over short writes).
    pub fn send(s: *Session, bytes: []const u8) void {
        var off: usize = 0;
        while (off < bytes.len) {
            const n = s.conn.send(bytes[off..]) catch return;
            if (n == 0) return;
            off += n;
        }
    }

    /// Shut the socket so the reader's recv returns EOF, JOIN it, then close.
    pub fn deinit(s: *Session) void {
        _ = std.os.linux.shutdown(s.conn.fd(), 2); // SHUT_RDWR — unblocks recv
        while (s.reader.poll() == null) std.atomic.spinLoopHint(); // join
        s.conn.close();
        s.out_buf.deinit(s.gpa);
        free(s);
    }
};
