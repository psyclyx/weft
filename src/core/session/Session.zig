//! `Session` — one encrypted, multiplexed peer link (wire v2): the
//! reader/writer threads, the handshake, liveness, and crypto state.
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
//! clock: connected → degraded (>3s) → offline (>10s).

const std = @import("std");
const Allocator = std.mem.Allocator;

const wire = @import("weft_wire");
const secure = @import("../secure.zig");
const identity = @import("../identity.zig");
const task = @import("../task.zig");
const grants = @import("../grants.zig");

const Clock = @import("clock.zig").Clock;
const link_mod = @import("link.zig");
const Link = link_mod.Link;
const Mutex = link_mod.Mutex;
const futexWaitTimed = link_mod.futexWaitTimed;
const futexWake = link_mod.futexWake;
const scheduler_mod = @import("../scheduler.zig");

pub const Liveness = enum { connecting, connected, degraded, offline };

/// Authorization grade for the peer at the other end of a link — distinct
/// from authentication (the token/crypto proves you *may connect*; the
/// access grade proves what you *may do*). Enforced by the host at op
/// admission: a `view` peer's ops never enter the shared document, so they
/// cannot write no matter what they send. Defaults are safe: a new peer is
/// a viewer until explicitly granted more.
pub const Access = enum {
    /// Read-only: receives everyone's edits, but its own ops are dropped.
    view,
    /// May edit the shared document.
    edit,
    /// Edit plus administrative authority (reserved; treated as edit for
    /// op admission today, the hook for privileged capabilities later).
    own,

    pub fn canEdit(self: Access) bool {
        return self != .view;
    }
    pub fn label(self: Access) []const u8 {
        return @tagName(self);
    }
    pub fn parse(s: []const u8) ?Access {
        return std.meta.stringToEnum(Access, s);
    }

    /// The preset BUNDLE this grade stands for (§13.5: "connection-level
    /// roles may exist as user-facing presets or maxima"). This is the whole
    /// remaining meaning of a grade — the legacy one-byte grant frame is
    /// read through here, and `authorize` applies it as a ceiling over any
    /// per-export grant.
    ///
    /// Endpoint ops are deliberately absent from every preset: the grade
    /// byte never governed the `.peer` filesystem or the blob cycle (their
    /// own `peer_fs.Grant` does), so a preset bundle must not start claiming
    /// authority the grade never carried.
    pub fn ops(self: Access) grants.OpSet {
        const view_ops = grants.OpSet.of(&.{ .replica_read, .presence_read, .presence_publish });
        return switch (self) {
            .view => view_ops,
            .edit => view_ops.with(.replica_write),
            .own => view_ops.with(.replica_write).with(.admin),
        };
    }

    /// The coarsest grade whose preset covers `set` — what a peer that only
    /// speaks the legacy grade byte must be told so it degrades to the same
    /// authority, never a wider one.
    pub fn fromOps(set: grants.OpSet) Access {
        if (set.has(.admin)) return .own;
        if (set.has(.replica_write)) return .edit;
        return .view;
    }
};

const InNode = struct {
    next: ?*InNode = null,
    frame: wire.Decoder.Decoded,
};

const Session = @This();

gpa: Allocator,
link: Link,
role: secure.Role,
token: []u8,
/// What the peer on the other end may do to our shared state. On a
/// host this is the grade granted to that peer; on a client it is
/// `.own` (we trust the host we chose to reach out to).
access: Access,
/// Time source for the liveness windows and the heartbeat cadence.
clock: Clock,
/// Owner side: this link's per-export grant book (§13.5). Not owned — one
/// book per link, bound by whoever publishes a quad's resource
/// (`Collab.publish`). `null` keeps the grade-only authority this session
/// had before per-export grants existed, byte for byte.
exports: ?*grants.ExportBook = null,

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
/// Our long-term identity (names us to the peer). Ephemeral when the
/// caller had none — the channel is still encrypted, but the peer's
/// fingerprint is then meaningless (a fresh key each run).
id: identity.Identity,
/// The peer's identity public key, learned in the handshake. Valid
/// once `established`; the peer's fingerprint/color derive from it.
their_id: [secure.pub_len]u8 = undefined,
/// Short Authentication String seed for this session (see secure.zig).
/// Valid once `established`; rendered by `sas()`.
sas_bytes: [secure.sas_len]u8 = undefined,
tx: secure.Channel = undefined,
rx: secure.Channel = undefined,

last_rx_ns: std.atomic.Value(u64) = .init(0),

/// Optional scheduler wake-fd (doc/contextual-workspace-architecture.md §7): the reader
/// thread signals it whenever it pushes fresh inbox data, and at
/// terminal reader exit (a liveness transition worth noticing promptly
/// too) — the fd Hub/Collab register as a scheduler source so tick
/// servicing wakes on real activity instead of a per-frame poll. Not
/// owned here: Hub shares ONE fd across every peer Session it creates;
/// Collab owns one for the outbound session across reconnects.
wake_fd: ?std.posix.fd_t = null,

/// Counts what this session PUTS on the wire (see `Tap`). Null everywhere
/// but the emission gates.
tap: ?Tap = null,

/// Observes every frame this session posts, by class, kind and channel,
/// before sealing. The gates that assert an export emits NOTHING
/// (doc/contextual-workspace-architecture.md §18, "no emission without a
/// legible selection") need a seam that counts what was SENT: a receiver
/// cannot distinguish "never sent" from "sent and dropped", and the bytes
/// at the `Link` are ciphertext by then.
pub const Tap = struct {
    ctx: ?*anyopaque,
    postedFn: *const fn (ctx: ?*anyopaque, class: wire.Class, kind: u8, channel: u64) void,

    fn saw(self: Tap, class: wire.Class, kind: u8, channel: u64) void {
        self.postedFn(self.ctx, class, kind, channel);
    }
};

pub fn setWakeFd(self: *Session, fd: ?std.posix.fd_t) void {
    self.wake_fd = fd;
}

fn notifyWake(self: *Session) void {
    const fd = self.wake_fd orelse return;
    scheduler_mod.signalWakeFd(fd);
}

pub fn create(
    gpa: Allocator,
    link: Link,
    role: secure.Role,
    token: []const u8,
    access: Access,
    id: ?*const identity.Identity,
) !*Session {
    return createOn(gpa, link, role, token, access, id, .real);
}

/// `create` against an injected clock. The threads sample it as soon as
/// they spawn, so the clock has to be chosen here rather than set after.
pub fn createOn(
    gpa: Allocator,
    link: Link,
    role: secure.Role,
    token: []const u8,
    access: Access,
    id: ?*const identity.Identity,
    clock: Clock,
) !*Session {
    const self = try gpa.create(Session);
    errdefer gpa.destroy(self);
    self.* = .{
        .gpa = gpa,
        .link = link,
        .role = role,
        .token = try gpa.dupe(u8, token),
        .access = access,
        .clock = clock,
        .eph = secure.Ephemeral.generate(),
        .id = if (id) |i| i.* else identity.Identity.generate(),
    };
    self.last_rx_ns.store(clock.nowNs(), .release);
    self.reader_thread = try std.Thread.spawn(.{}, readerMain, .{self});
    self.writer_thread = try std.Thread.spawn(.{}, writerMain, .{self});
    return self;
}

/// The peer's fingerprint (who is on the other end), or null before
/// the handshake completes. This is what a human verifies out of band.
pub fn peerFingerprint(self: *const Session) ?[24]u8 {
    if (!self.established.load(.acquire)) return null;
    return identity.fingerprintOf(self.their_id);
}

/// Public, per-handshake identity of this concrete connection lifetime. The
/// ephemeral key is freshly generated for every Session and already travels
/// in the authenticated transcript, so it distinguishes a same-peer
/// reconnect without adding a platform RNG dependency at the Conn layer.
pub fn incarnation(self: *const Session) [secure.pub_len]u8 {
    return self.eph.public;
}

/// The peer's identity hue seed (for a stable per-peer color), or null
/// before the handshake completes.
pub fn peerHue(self: *const Session) ?f32 {
    if (!self.established.load(.acquire)) return null;
    return identity.hueOf(self.their_id);
}

/// This session's Short Authentication String — the four words to read
/// aloud against the peer — or null before the handshake completes.
pub fn sas(self: *const Session) ?[identity.sas_len]u8 {
    if (!self.established.load(.acquire)) return null;
    return identity.sasWords(self.sas_bytes);
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

/// THE remote-authority decision (§13.5's intersection, as much of it as
/// this process can evaluate): may this link's peer perform `op` on
/// `pub_ref`? Every enforcement point calls exactly this — there is no
/// second way to spell "authorized" on a session.
///
/// The intersection, in order:
///   1. **the connection grade, as a MAXIMUM** — a preset ceiling, never a
///      grant. `edit` no longer means "may write"; it means "may not write
///      more than a writer".
///   2. **the publication's own book**, when one is bound AND knows this
///      publication. A publication this book never heard of is not its to
///      decide: the grade alone governs, exactly as before this slice — the
///      one and only permissive fallback, and it is a fallback to the
///      PREVIOUS behavior, never to unrestricted.
///   3. **an authenticated grantee**. A confined publication whose sender
///      cannot be attributed to any identity fails CLOSED.
///
/// The remaining two terms of §13.5's intersection are enforced elsewhere
/// and deliberately not folded in here: the requester's grant to its
/// invoking local plugin is the `HandleTable` check at the plugin membrane,
/// and a designation scope is checked at its own live-document chokepoint
/// (`checkDocRegion` / `admitRegions`). Each narrows; none widens.
pub fn authorize(self: *const Session, pub_ref: grants.PublicationRef, op: grants.Op) grants.Reason {
    if (!self.access.ops().has(op)) return .out_of_ops;
    const book = self.exports orelse return .ok;
    if (!book.knows(pub_ref.id)) return .ok;
    const fp = self.peerFingerprint() orelse return .never_granted;
    return book.check(fp, pub_ref, op);
}

pub fn liveness(self: *const Session) Liveness {
    if (self.dead.load(.acquire)) return .offline;
    if (!self.established.load(.acquire)) return .connecting;
    const silent = self.clock.nowNs() -| self.last_rx_ns.load(.acquire);
    if (silent > 10 * std.time.ns_per_s) return .offline;
    if (silent > 3 * std.time.ns_per_s) return .degraded;
    return .connected;
}

// ── Posting (main thread; sealed + written by the writer) ───

pub fn post(self: *Session, class: wire.Class, kind: u8, channel: u64, payload: []const u8) !void {
    if (self.tap) |tap| tap.saw(class, kind, channel);
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
    if (self.tap) |tap| tap.saw(.feed, @intFromEnum(wire.FeedKind.publish), channel);
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
    self.notifyWake(); // a liveness transition is worth noticing promptly
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
                self.last_rx_ns.store(self.clock.nowNs(), .release);
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
                self.notifyWake();
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

/// Plaintext fixed-size handshake, then keys + MAC verification. Each
/// side sends its ephemeral public key followed by its long-term
/// identity public key; both feed `derive`, which mixes the static
/// identity DH into the key schedule (authentication) and both
/// identity keys into the transcript (so the SAS binds them).
fn handshake(self: *Session) !void {
    const P = secure.pub_len;
    const M = secure.mac_len;
    var their_pub: [P]u8 = undefined;
    switch (self.role) {
        .client => {
            try self.writeWireVersion();
            try self.link.write(&self.eph.public);
            try self.link.write(&self.id.public);
            try self.readWireVersion();
            try self.readExact(&their_pub);
            try self.readExact(&self.their_id);
            const keys = try secure.derive(
                self.eph,
                their_pub,
                self.token,
                self.eph.public,
                their_pub,
                self.id.secret,
                self.their_id,
                self.id.public,
                self.their_id,
            );
            var mac_s: [M]u8 = undefined;
            try self.readExact(&mac_s);
            if (!secure.macEql(mac_s, keys.mac_s)) return error.AuthFailed;
            try self.link.write(&keys.mac_c);
            self.tx = .{ .key = keys.c2s };
            self.rx = .{ .key = keys.s2c };
            self.sas_bytes = keys.sas;
        },
        .server => {
            try self.readWireVersion();
            try self.readExact(&their_pub);
            try self.readExact(&self.their_id);
            try self.writeWireVersion();
            try self.link.write(&self.eph.public);
            try self.link.write(&self.id.public);
            const keys = try secure.derive(
                self.eph,
                their_pub,
                self.token,
                their_pub,
                self.eph.public,
                self.id.secret,
                self.their_id,
                self.their_id,
                self.id.public,
            );
            try self.link.write(&keys.mac_s);
            var mac_c: [M]u8 = undefined;
            try self.readExact(&mac_c);
            if (!secure.macEql(mac_c, keys.mac_c)) return error.AuthFailed;
            self.tx = .{ .key = keys.s2c };
            self.rx = .{ .key = keys.c2s };
            self.sas_bytes = keys.sas;
        },
    }
    self.established.store(true, .release);
    self.wakeWriter();
    self.notifyWake(); // the peer's fingerprint/SAS just became readable
}

fn writeWireVersion(self: *Session) !void {
    var bytes: [2]u8 = undefined;
    std.mem.writeInt(u16, &bytes, wire.version, .little);
    try self.link.write(&bytes);
}

fn readWireVersion(self: *Session) !void {
    var bytes: [2]u8 = undefined;
    try self.readExact(&bytes);
    if (std.mem.readInt(u16, &bytes, .little) != wire.version) return error.UnsupportedWireVersion;
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
        const now = self.clock.nowNs();
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
                self.notifyWake(); // a half-open link (write fails, read blocks) must be noticed
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
                self.notifyWake(); // a half-open link (write fails, read blocks) must be noticed
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
