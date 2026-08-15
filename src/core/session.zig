//! Session — one encrypted, multiplexed peer link (wire v1), plus the
//! document-sync driver (`Collab`) that rides it.
//!
//! Threading mirrors the LSP transport: a reader thread decodes the
//! outer envelope (u32le sealed length | AEAD-sealed frame), opens it,
//! and pushes frames into a lock-free inbox; a writer thread drains the
//! class-priority outbox (wire.Outbox under a tiny futex mutex — the
//! writer thread and the main tick are the only contenders; the input
//! hot section never touches the session), seals, and writes. The
//! writer's futex wait doubles as the heartbeat timer.
//!
//! Handshake runs on the reader thread (plaintext control frames, then
//! keys derived, then everything sealed); `established` flips when the
//! transcript MACs verify. Liveness is computed from the last-receive
//! clock: connected → degraded (>3s) → offline (>10s). Reconnect =
//! new link + same token (+ resume token when held): re-auth is one
//! round trip and the op resync is the ordinary frontier exchange —
//! offline-then-reconnect has no other path.

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const linux = std.os.linux;

const wire = @import("wire.zig");
const secure = @import("secure.zig");
const task = @import("task.zig");
const Document = @import("Document.zig");
const layers_mod = @import("layers.zig");

// ── Small primitives ────────────────────────────────────────────────

fn futexWaitTimed(word: *const std.atomic.Value(u32), expected: u32, timeout_ns: u64) void {
    var ts: linux.timespec = .{
        .sec = @intCast(timeout_ns / std.time.ns_per_s),
        .nsec = @intCast(timeout_ns % std.time.ns_per_s),
    };
    _ = linux.futex_4arg(&word.raw, .{ .cmd = .WAIT, .private = true }, expected, &ts);
}

fn futexWake(word: *const std.atomic.Value(u32), n: i32) void {
    _ = linux.futex_3arg(&word.raw, .{ .cmd = .WAKE, .private = true }, @intCast(n));
}

/// Futex mutex (std.Thread.Mutex left std in 0.16). Two contenders,
/// microsecond critical sections; never on the input hot section.
const Mutex = struct {
    state: std.atomic.Value(u32) = .init(0),

    fn lock(self: *Mutex) void {
        while (self.state.swap(1, .acquire) != 0) {
            futexWaitTimed(&self.state, 1, 10 * std.time.ns_per_ms);
        }
    }

    fn unlock(self: *Mutex) void {
        self.state.store(0, .release);
        futexWake(&self.state, 1);
    }
};

/// Byte-stream transport seam: TCP today, QUIC-shaped tomorrow, an
/// in-memory fault injector in the chaos tests.
pub const Link = struct {
    ctx: ?*anyopaque,
    readFn: *const fn (ctx: ?*anyopaque, buf: []u8) anyerror!usize,
    writeFn: *const fn (ctx: ?*anyopaque, bytes: []const u8) anyerror!void,
    closeFn: *const fn (ctx: ?*anyopaque) void,

    pub fn read(self: Link, buf: []u8) anyerror!usize {
        return self.readFn(self.ctx, buf);
    }
    pub fn write(self: Link, bytes: []const u8) anyerror!void {
        return self.writeFn(self.ctx, bytes);
    }
    pub fn close(self: Link) void {
        self.closeFn(self.ctx);
    }
};

/// A Link over a connected socket/pipe fd (raw syscalls; Linux-native).
pub const FdLink = struct {
    fd: i32,

    pub fn link(self: *FdLink) Link {
        return .{ .ctx = self, .readFn = readFd, .writeFn = writeFd, .closeFn = closeFd };
    }

    fn readFd(ctx: ?*anyopaque, buf: []u8) anyerror!usize {
        const self: *FdLink = @ptrCast(@alignCast(ctx.?));
        while (true) {
            const rc = linux.read(self.fd, buf.ptr, buf.len);
            switch (linux.errno(rc)) {
                .SUCCESS => return rc,
                .INTR => continue,
                else => return error.LinkBroken,
            }
        }
    }

    fn writeFd(ctx: ?*anyopaque, bytes: []const u8) anyerror!void {
        const self: *FdLink = @ptrCast(@alignCast(ctx.?));
        var rest = bytes;
        while (rest.len > 0) {
            const rc = linux.write(self.fd, rest.ptr, rest.len);
            switch (linux.errno(rc)) {
                .SUCCESS => rest = rest[rc..],
                .INTR => continue,
                else => return error.LinkBroken,
            }
        }
    }

    fn closeFd(ctx: ?*anyopaque) void {
        const self: *FdLink = @ptrCast(@alignCast(ctx.?));
        _ = linux.close(self.fd);
    }
};

pub const Liveness = enum { connecting, connected, degraded, offline };

const InNode = struct {
    next: ?*InNode = null,
    frame: wire.Decoder.Decoded,
};

pub const Session = struct {
    gpa: Allocator,
    link: Link,
    role: secure.Role,
    token: []u8,

    reader_thread: ?std.Thread = null,
    writer_thread: ?std.Thread = null,
    shutdown: std.atomic.Value(bool) = .init(false),
    dead: std.atomic.Value(bool) = .init(false),
    established: std.atomic.Value(bool) = .init(false),

    inbox: std.atomic.Value(?*InNode) = .init(null),
    out_mutex: Mutex = .{},
    outbox: wire.Outbox = .empty,
    out_wake: std.atomic.Value(u32) = .init(0),

    // Crypto state (reader owns until established; writer reads tx
    // only after `established` with acquire ordering).
    eph: secure.Ephemeral,
    tx: secure.Channel = undefined,
    rx: secure.Channel = undefined,

    last_rx_ns: std.atomic.Value(u64) = .init(0),
    /// Server-issued on accept; presented on reconnect.
    resume_token: [16]u8 = @splat(0),

    pub fn create(gpa: Allocator, link: Link, role: secure.Role, token: []const u8) !*Session {
        const self = try gpa.create(Session);
        errdefer gpa.destroy(self);
        self.* = .{
            .gpa = gpa,
            .link = link,
            .role = role,
            .token = try gpa.dupe(u8, token),
            .eph = secure.Ephemeral.generate(),
        };
        self.last_rx_ns.store(task.nowNs(), .release);
        self.reader_thread = try std.Thread.spawn(.{}, readerMain, .{self});
        self.writer_thread = try std.Thread.spawn(.{}, writerMain, .{self});
        return self;
    }

    pub fn destroy(self: *Session) void {
        task.assertMayBlock();
        const gpa = self.gpa;
        self.shutdown.store(true, .release);
        _ = self.out_wake.fetchAdd(1, .release);
        futexWake(&self.out_wake, std.math.maxInt(i32));
        self.link.close(); // unblocks the reader
        if (self.reader_thread) |t_| t_.join();
        if (self.writer_thread) |t_| t_.join();
        var cur = self.inbox.swap(null, .acquire);
        while (cur) |n| {
            cur = n.next;
            gpa.free(n.frame.payload);
            gpa.destroy(n);
        }
        self.out_mutex.lock();
        self.outbox.deinit(gpa);
        self.out_mutex.unlock();
        gpa.free(self.token);
        gpa.destroy(self);
    }

    pub fn liveness(self: *const Session) Liveness {
        if (self.dead.load(.acquire)) return .offline;
        if (!self.established.load(.acquire)) return .connecting;
        const silent = task.nowNs() -| self.last_rx_ns.load(.acquire);
        if (silent > 10 * std.time.ns_per_s) return .offline;
        if (silent > 3 * std.time.ns_per_s) return .degraded;
        return .connected;
    }

    // ── Posting (main thread; sealed + written by the writer) ───

    pub fn post(self: *Session, class: wire.Class, kind: u8, channel: u64, payload: []const u8) !void {
        const encoded = try wire.encode(self.gpa, .{
            .class = class,
            .kind = kind,
            .channel = channel,
            .payload = payload,
        });
        self.out_mutex.lock();
        defer self.out_mutex.unlock();
        self.outbox.push(self.gpa, class, encoded) catch |err| {
            self.gpa.free(encoded);
            return err;
        };
        self.wakeWriter();
    }

    pub fn postFeed(self: *Session, channel: u64, key: u64, payload: []const u8) !void {
        const encoded = try wire.encode(self.gpa, .{
            .class = .feed,
            .kind = @intFromEnum(wire.FeedKind.publish),
            .channel = channel,
            .payload = payload,
        });
        self.out_mutex.lock();
        defer self.out_mutex.unlock();
        self.outbox.pushFeed(self.gpa, channel, key, encoded) catch |err| {
            self.gpa.free(encoded);
            return err;
        };
        self.wakeWriter();
    }

    fn wakeWriter(self: *Session) void {
        _ = self.out_wake.fetchAdd(1, .release);
        futexWake(&self.out_wake, 1);
    }

    /// Frames that arrived since last drain, in arrival order; free
    /// each payload. Control frames are consumed internally.
    pub fn drain(self: *Session, gpa: Allocator, out: *std.ArrayList(wire.Decoder.Decoded)) !void {
        var list = self.inbox.swap(null, .acquire);
        var fifo: ?*InNode = null;
        while (list) |n| {
            list = n.next;
            n.next = fifo;
            fifo = n;
        }
        while (fifo) |n| {
            fifo = n.next;
            try out.append(gpa, n.frame);
            self.gpa.destroy(n);
        }
    }

    // ── Reader: handshake, then sealed frames ───────────────────

    fn readerMain(self: *Session) void {
        self.runReader() catch {};
        self.dead.store(true, .release);
    }

    fn runReader(self: *Session) !void {
        const gpa = self.gpa;
        try self.handshake();
        var buf: [16384]u8 = undefined;
        var acc: std.ArrayList(u8) = .empty;
        defer acc.deinit(gpa);
        while (!self.shutdown.load(.acquire)) {
            const n = try self.link.read(&buf);
            if (n == 0) return error.LinkBroken;
            try acc.appendSlice(gpa, buf[0..n]);
            while (try self.splitSealed(&acc)) |plain| {
                defer gpa.free(plain);
                var dec: wire.Decoder = .empty;
                defer dec.deinit(gpa);
                try dec.feed(gpa, plain);
                while (try dec.next(gpa)) |frame| {
                    self.last_rx_ns.store(task.nowNs(), .release);
                    if (frame.class == .control) {
                        gpa.free(frame.payload);
                        continue; // heartbeats etc.
                    }
                    const node = try gpa.create(InNode);
                    node.* = .{ .frame = frame };
                    var head = self.inbox.load(.monotonic);
                    while (true) {
                        node.next = head;
                        head = self.inbox.cmpxchgWeak(head, node, .release, .monotonic) orelse break;
                    }
                }
            }
        }
    }

    fn splitSealed(self: *Session, acc: *std.ArrayList(u8)) !?[]u8 {
        if (acc.items.len < 4) return null;
        const len = std.mem.readInt(u32, acc.items[0..4], .little);
        if (len > 64 << 20) return error.Corrupt;
        if (acc.items.len < 4 + len) return null;
        const plain = try self.rx.open(self.gpa, acc.items[4 .. 4 + len]);
        const rest = acc.items.len - (4 + len);
        std.mem.copyForwards(u8, acc.items[0..rest], acc.items[4 + len ..]);
        acc.items.len = rest;
        return plain;
    }

    fn readExact(self: *Session, buf: []u8) !void {
        var got: usize = 0;
        while (got < buf.len) {
            const n = try self.link.read(buf[got..]);
            if (n == 0) return error.LinkBroken;
            got += n;
        }
    }

    /// Plaintext fixed-size handshake, then keys + MAC verification.
    fn handshake(self: *Session) !void {
        const P = secure.pub_len;
        const M = secure.mac_len;
        var their_pub: [P]u8 = undefined;
        switch (self.role) {
            .client => {
                try self.link.write(&self.eph.public);
                try self.readExact(&their_pub);
                const keys = try secure.derive(self.eph, their_pub, self.token, self.eph.public, their_pub);
                var mac_s: [M]u8 = undefined;
                try self.readExact(&mac_s);
                if (!secure.macEql(mac_s, keys.mac_s)) return error.AuthFailed;
                try self.link.write(&keys.mac_c);
                self.tx = .{ .key = keys.c2s };
                self.rx = .{ .key = keys.s2c };
            },
            .server => {
                try self.readExact(&their_pub);
                try self.link.write(&self.eph.public);
                const keys = try secure.derive(self.eph, their_pub, self.token, their_pub, self.eph.public);
                try self.link.write(&keys.mac_s);
                var mac_c: [M]u8 = undefined;
                try self.readExact(&mac_c);
                if (!secure.macEql(mac_c, keys.mac_c)) return error.AuthFailed;
                self.tx = .{ .key = keys.s2c };
                self.rx = .{ .key = keys.c2s };
            },
        }
        self.established.store(true, .release);
        self.wakeWriter();
    }

    // ── Writer: priority drain + heartbeat clock ────────────────

    fn writerMain(self: *Session) void {
        const gpa = self.gpa;
        var last_hb: u64 = 0;
        while (!self.shutdown.load(.acquire)) {
            const gen = self.out_wake.load(.acquire);
            if (!self.established.load(.acquire)) {
                futexWaitTimed(&self.out_wake, gen, 200 * std.time.ns_per_ms);
                continue;
            }
            const now = task.nowNs();
            if (now - last_hb >= std.time.ns_per_s) {
                last_hb = now;
                const hb = wire.encode(gpa, .{
                    .class = .control,
                    .kind = @intFromEnum(wire.ControlKind.heartbeat),
                    .channel = 0,
                    .payload = "",
                }) catch continue;
                defer gpa.free(hb);
                self.writeSealed(hb) catch {
                    self.dead.store(true, .release);
                    return;
                };
            }
            const frame = blk: {
                self.out_mutex.lock();
                defer self.out_mutex.unlock();
                break :blk self.outbox.pop();
            };
            if (frame) |f| {
                defer gpa.free(f);
                self.writeSealed(f) catch {
                    self.dead.store(true, .release);
                    return;
                };
                continue;
            }
            futexWaitTimed(&self.out_wake, gen, std.time.ns_per_s);
        }
    }

    fn writeSealed(self: *Session, frame: []const u8) !void {
        const sealed = try self.tx.seal(self.gpa, frame);
        defer self.gpa.free(sealed);
        var len_bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &len_bytes, @intCast(sealed.len), .little);
        try self.link.write(&len_bytes);
        try self.link.write(sealed);
    }
};

// ── Document sync over a session ────────────────────────────────────

/// Batches carry the sender's frontier token so each side always knows
/// what the peer holds: payload = uv token_len | token | stemma bytes.
pub const Collab = struct {
    gpa: Allocator,
    session: *Session,
    doc: *Document,
    name: []u8,
    their_frontier: ?[]u8 = null,
    last_sent_version: ?[]u8 = null,
    presence_layer: ?*layers_mod.Layer = null,
    last_presence_offset: usize = std.math.maxInt(usize),
    announced: bool = false,

    pub fn init(gpa: Allocator, session: *Session, doc: *Document, name: []const u8) !Collab {
        return .{
            .gpa = gpa,
            .session = session,
            .doc = doc,
            .name = try gpa.dupe(u8, name),
        };
    }

    pub fn deinit(self: *Collab) void {
        if (self.their_frontier) |f| self.gpa.free(f);
        if (self.last_sent_version) |v| self.gpa.free(v);
        self.gpa.free(self.name);
    }

    /// Per-frame: drain inbound frames (merge op batches, answer
    /// frontier requests, fold presence), then push our changes.
    /// Returns true when the document or presence changed.
    pub fn tick(self: *Collab, cursor_offset: usize) !bool {
        const gpa = self.gpa;
        var changed = false;

        var frames: std.ArrayList(wire.Decoder.Decoded) = .empty;
        defer frames.deinit(gpa);
        try self.session.drain(gpa, &frames);
        for (frames.items) |frame| {
            defer gpa.free(frame.payload);
            switch (frame.class) {
                .op => switch (@as(wire.OpKind, @enumFromInt(frame.kind))) {
                    .batch => {
                        var cur: []const u8 = frame.payload;
                        const tlen = wire.getUv(&cur) catch continue;
                        if (tlen > cur.len) continue;
                        const token = cur[0..tlen];
                        const batch = cur[tlen..];
                        try self.setTheirFrontier(token);
                        if (batch.len > 0) {
                            const merged = self.doc.mergeRemote(gpa, batch) catch |err| blk: {
                                std.log.warn("collab: batch rejected: {t}", .{err});
                                break :blk false;
                            };
                            changed = changed or merged;
                        }
                    },
                    .frontier => {
                        try self.setTheirFrontier(frame.payload);
                        try self.sendBatch();
                    },
                },
                .feed => {
                    // Presence: uv name_len | name | uv offset.
                    var cur: []const u8 = frame.payload;
                    const nlen = wire.getUv(&cur) catch continue;
                    if (nlen > cur.len) continue;
                    const peer_name = cur[0..nlen];
                    cur = cur[nlen..];
                    const off = wire.getUv(&cur) catch continue;
                    if (self.presence_layer) |layer| {
                        const clamped = @min(@as(usize, @intCast(off)), self.doc.text().byteLen());
                        try layer.publishSpans(gpa, &.{.{
                            .start = clamped,
                            .end = @min(clamped + 1, self.doc.text().byteLen()),
                            .kind = 1,
                            .message = peer_name,
                        }});
                        changed = true;
                    }
                },
                .request, .control => {},
            }
        }

        // Announce once, then push whenever our head moved.
        if (self.session.liveness() == .connected or self.session.liveness() == .degraded) {
            if (!self.announced) {
                self.announced = true;
                const v = try self.doc.version(gpa);
                defer gpa.free(v);
                try self.session.post(.op, @intFromEnum(wire.OpKind.frontier), 0, v);
            }
            const head = try self.doc.version(gpa);
            defer gpa.free(head);
            const moved = self.last_sent_version == null or
                !std.mem.eql(u8, self.last_sent_version.?, head);
            if (moved) try self.sendBatch();

            if (cursor_offset != self.last_presence_offset) {
                self.last_presence_offset = cursor_offset;
                var payload: std.ArrayList(u8) = .empty;
                defer payload.deinit(gpa);
                try wire.putUv(gpa, &payload, self.name.len);
                try payload.appendSlice(gpa, self.name);
                try wire.putUv(gpa, &payload, cursor_offset);
                try self.session.postFeed(1, 1, payload.items);
            }
        }
        return changed;
    }

    fn setTheirFrontier(self: *Collab, token: []const u8) !void {
        if (self.their_frontier) |f| self.gpa.free(f);
        self.their_frontier = try self.gpa.dupe(u8, token);
    }

    /// Send everything the peer lacks (their frontier, or the whole
    /// history when unknown), prefixed with our frontier. Duplicates on
    /// their side are no-ops — retransmit-safe.
    fn sendBatch(self: *Collab) !void {
        const gpa = self.gpa;
        const head = try self.doc.version(gpa);
        errdefer gpa.free(head);
        const batch = if (self.their_frontier) |f|
            try self.doc.eventsSince(gpa, f)
        else
            try self.doc.serialize(gpa);
        defer gpa.free(batch);

        var payload: std.ArrayList(u8) = .empty;
        defer payload.deinit(gpa);
        try wire.putUv(gpa, &payload, head.len);
        try payload.appendSlice(gpa, head);
        try payload.appendSlice(gpa, batch);
        try self.session.post(.op, @intFromEnum(wire.OpKind.batch), 0, payload.items);

        if (self.last_sent_version) |v| gpa.free(v);
        self.last_sent_version = head;
    }
};

// ── Tests: two live sessions over a socketpair ──────────────────────

const t = std.testing;

fn socketPair() ![2]i32 {
    var fds: [2]i32 = undefined;
    const rc = linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM, 0, &fds);
    if (linux.errno(rc) != .SUCCESS) return error.SocketPair;
    return fds;
}

test "session+collab: two instances converge over an encrypted link with presence" {
    const gpa = t.allocator;
    const fds = try socketPair();
    var la: FdLink = .{ .fd = fds[0] };
    var lb: FdLink = .{ .fd = fds[1] };

    var doc_a = try Document.init(gpa, "alice");
    defer doc_a.deinit(gpa);
    var doc_b = try Document.init(gpa, "bob");
    defer doc_b.deinit(gpa);
    try doc_a.insert(gpa, 0, "shared ground\n");

    const sa = try Session.create(gpa, la.link(), .server, "tok");
    defer sa.destroy();
    const sb = try Session.create(gpa, lb.link(), .client, "tok");
    defer sb.destroy();

    var ca = try Collab.init(gpa, sa, &doc_a, "alice");
    defer ca.deinit();
    var cb = try Collab.init(gpa, sb, &doc_b, "bob");
    defer cb.deinit();

    var layers: layers_mod.Layers = .empty;
    defer layers.deinit(gpa);
    cb.presence_layer = try layers.claim(gpa, &doc_b, "presence", .replicated, "collab");

    // Pump both sides; concurrent edits mid-stream.
    var round: usize = 0;
    var edited = false;
    while (round < 400) : (round += 1) {
        _ = try ca.tick(3);
        _ = try cb.tick(0);
        if (round == 40 and !edited) {
            edited = true;
            try doc_a.insert(gpa, 0, "A>");
            try doc_b.insert(gpa, doc_b.text().byteLen(), "<B");
        }
        const ta = try doc_a.text().toOwnedSlice(gpa);
        defer gpa.free(ta);
        const tb = try doc_b.text().toOwnedSlice(gpa);
        defer gpa.free(tb);
        if (edited and ta.len > 16 and std.mem.eql(u8, ta, tb)) break;
        std.Thread.yield() catch {};
    }
    try t.expect(round < 400);

    const ta = try doc_a.text().toOwnedSlice(gpa);
    defer gpa.free(ta);
    try t.expect(std.mem.indexOf(u8, ta, "A>") != null);
    try t.expect(std.mem.indexOf(u8, ta, "<B") != null);
    try t.expect(std.mem.indexOf(u8, ta, "shared ground") != null);

    // Presence from alice landed in bob's replicated layer.
    var saw_presence = false;
    for (0..200) |_| {
        _ = try cb.tick(0);
        if (cb.presence_layer.?.spanCount() > 0) {
            saw_presence = true;
            break;
        }
        std.Thread.yield() catch {};
    }
    try t.expect(saw_presence);
    try t.expectEqualStrings("alice", cb.presence_layer.?.resolvedSpan(0).message);
}

test "session: wrong token never establishes" {
    const gpa = t.allocator;
    const fds = try socketPair();
    var la: FdLink = .{ .fd = fds[0] };
    var lb: FdLink = .{ .fd = fds[1] };
    const sa = try Session.create(gpa, la.link(), .server, "right");
    defer sa.destroy();
    const sb = try Session.create(gpa, lb.link(), .client, "wrong");
    defer sb.destroy();
    var waited: usize = 0;
    while (waited < 100) : (waited += 1) {
        if (sa.dead.load(.acquire) or sb.dead.load(.acquire)) break;
        std.Thread.yield() catch {};
        futexWaitTimed(&sa.out_wake, sa.out_wake.load(.acquire), 10 * std.time.ns_per_ms);
    }
    try t.expect(!sa.established.load(.acquire) or !sb.established.load(.acquire));
}

test {
    std.testing.refAllDecls(@This());
}
