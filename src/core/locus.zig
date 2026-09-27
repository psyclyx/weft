//! Locus — the locality primitive: *where* bytes and effects live. A
//! path or handle is meaningless on its own (rule R1); it means something
//! only paired with the locus that hosts it. Three tiers:
//!
//! - **here** — this process. The always-present sentinel, `Locus` 0, so
//!   the local case is never a branch and never a lookup.
//! - **peer** — another weft, named by its identity FINGERPRINT (rule R2:
//!   the fingerprint is identity, the address is a hint). The connection
//!   that reaches it now is a BINDING on the entry, not its key: a reconnect
//!   from another address rebinds the same locus to whatever `Conn` reaches
//!   it (and `Conn.rebind` re-points that one at a fresh `Session`), while
//!   the `Locus` — and every place and `Resource` built on it — is
//!   unchanged.
//! - **shell** — a persistent coreutils channel (`ShellFs`), the tramp tier,
//!   named by its shell id (`weft://shell:<id>/…`). Its channel is a binding
//!   the same way: a respawned shell rebinds the same locus.
//!
//! Effect handles carry their locus *inside* them: a `Resource` is an
//! opaque `(locus, kind, ref)` triple whose `ref` only the owning tier
//! interprets, so a guest holding one cannot re-target it at another
//! locus. `Loci` is the host-side registry that owns the table and hands
//! back stable handles; `peer`/`shell` are idempotent per NAME (same
//! fingerprint / shell id → same `Locus`), so a place minted before a
//! reconnect and one minted after it are the same place.

const std = @import("std");
const Allocator = std.mem.Allocator;
const linux = std.os.linux;

const session = @import("session.zig");
const ShellFs = @import("ShellFs.zig");
const durable = @import("weft_semantic").durable;

/// Which kind of place a locus names.
pub const Tier = enum { here, peer, shell };

/// What a resource *is*, so its `ref` can be interpreted by the tier that
/// owns it. Opaque to everyone else.
pub const Kind = enum { file, dir, proc, lsp, sock, buf };

/// A small opaque locality handle. `here` is the sentinel (index 0, the
/// local process); every other value is an index into a `Loci` table.
/// Compare for equality, never interpret the integer.
pub const Locus = enum(u32) { here = 0, _ };

/// How reachable a locus is (substrate §7, R5) — the session's own
/// vocabulary, for every tier: a remote degrades exactly like a dead
/// provider, and nothing remote is simply "up".
pub const Liveness = session.Liveness;

/// An opaque effect handle. Carries its own locus, so it cannot be
/// mis-targeted: whoever holds it can only act *there*. `ref` is a u64
/// the locus's tier interprets (a file id, pid, socket handle, …).
pub const Resource = struct {
    loc: Locus,
    knd: Kind,
    rf: u64,

    pub fn locus(self: Resource) Locus {
        return self.loc;
    }
    pub fn kind(self: Resource) Kind {
        return self.knd;
    }
    pub fn ref(self: Resource) u64 {
        return self.rf;
    }
};

/// The host-side locus registry. Owns the table; entry index == `Locus`
/// value, with index 0 permanently the `here` sentinel. Entries are never
/// removed: a locus names a place that may come back, and an index that
/// could be reused would let an old place silently mean a new peer.
pub const Loci = struct {
    gpa: Allocator,
    entries: std.ArrayList(Entry) = .empty,

    /// A registered place. The tag is the `Tier`; the name is its identity
    /// (owned), the transport a replaceable binding — null while nothing
    /// reaches it, which is what `offline` means.
    const Entry = union(Tier) {
        here,
        peer: struct { fingerprint: []u8, conn: ?*session.Conn = null },
        shell: struct { id: []u8, channel: ?*ShellFs = null },
    };

    pub fn init(gpa: Allocator) !Loci {
        var self: Loci = .{ .gpa = gpa };
        try self.entries.append(gpa, .here); // index 0 is the sentinel
        return self;
    }

    pub fn deinit(self: *Loci) void {
        for (self.entries.items) |e| switch (e) {
            .here => {},
            .peer => |p| self.gpa.free(p.fingerprint),
            .shell => |s| self.gpa.free(s.id),
        };
        self.entries.deinit(self.gpa);
    }

    fn handle(i: usize) Locus {
        return @enumFromInt(@as(u32, @intCast(i)));
    }

    fn entry(self: *const Loci, l: Locus) Entry {
        return self.entries.items[@intFromEnum(l)];
    }

    /// The peer locus named by `fingerprint`, minted on first sight.
    /// Idempotent per fingerprint (R2): whatever address or connection
    /// reached it, the same peer is the same locus.
    pub fn peer(self: *Loci, fingerprint: []const u8) Allocator.Error!Locus {
        if (self.findPeer(fingerprint)) |l| return l;
        const owned = try self.gpa.dupe(u8, fingerprint);
        errdefer self.gpa.free(owned);
        try self.entries.append(self.gpa, .{ .peer = .{ .fingerprint = owned } });
        return handle(self.entries.items.len - 1);
    }

    /// The shell locus named by `id` (`weft://shell:<id>/…`), minted on
    /// first sight. Idempotent per id.
    pub fn shell(self: *Loci, id: []const u8) Allocator.Error!Locus {
        if (self.findShell(id)) |l| return l;
        const owned = try self.gpa.dupe(u8, id);
        errdefer self.gpa.free(owned);
        try self.entries.append(self.gpa, .{ .shell = .{ .id = owned } });
        return handle(self.entries.items.len - 1);
    }

    /// The locus an authority names, minted on first sight — `here` for
    /// `here`. What a trusted publisher calls when it binds something under
    /// a designation: the place it makes is on the locus its name says.
    pub fn of(self: *Loci, named: durable.Authority) Allocator.Error!Locus {
        return switch (named) {
            .here => .here,
            .peer => |fp| self.peer(fp),
            .shell => |id| self.shell(id),
        };
    }

    fn findPeer(self: *const Loci, fingerprint: []const u8) ?Locus {
        for (self.entries.items, 0..) |e, i| switch (e) {
            .peer => |p| if (std.mem.eql(u8, p.fingerprint, fingerprint)) return handle(i),
            else => {},
        };
        return null;
    }

    fn findShell(self: *const Loci, id: []const u8) ?Locus {
        for (self.entries.items, 0..) |e, i| switch (e) {
            .shell => |s| if (std.mem.eql(u8, s.id, id)) return handle(i),
            else => {},
        };
        return null;
    }

    /// Point a peer locus at the connection that reaches it now, or at none
    /// (the connection went away). The locus value does not move — that is
    /// the whole of R2.
    pub fn bindPeer(self: *Loci, l: Locus, c: ?*session.Conn) void {
        switch (self.entries.items[@intFromEnum(l)]) {
            .peer => |*p| p.conn = c,
            else => unreachable, // a connection bound to a non-peer locus
        }
    }

    /// Point a shell locus at its live channel, or at none.
    pub fn bindShell(self: *Loci, l: Locus, ch: ?*ShellFs) void {
        switch (self.entries.items[@intFromEnum(l)]) {
            .shell => |*s| s.channel = ch,
            else => unreachable, // a channel bound to a non-shell locus
        }
    }

    /// The locus a designation's authority names, if one has been minted.
    /// Never mints: an authority string alone must not grow the table.
    pub fn resolve(self: *const Loci, named: durable.Authority) ?Locus {
        return switch (named) {
            .here => .here,
            .peer => |fp| self.findPeer(fp),
            .shell => |id| self.findShell(id),
        };
    }

    /// The authority a locus is named by in a designation — `resolve`'s
    /// inverse. Borrowed from the table.
    pub fn authority(self: *const Loci, l: Locus) durable.Authority {
        return switch (self.entry(l)) {
            .here => .here,
            .peer => |p| .{ .peer = p.fingerprint },
            .shell => |s| .{ .shell = s.id },
        };
    }

    pub fn tier(self: *const Loci, l: Locus) Tier {
        return std.meta.activeTag(self.entry(l));
    }

    /// The peer connection bound to a locus now, or null (not a peer, or
    /// nothing reaches it).
    pub fn conn(self: *const Loci, l: Locus) ?*session.Conn {
        return switch (self.entry(l)) {
            .peer => |p| p.conn,
            else => null,
        };
    }

    /// The shell channel bound to a locus now, or null.
    pub fn channel(self: *const Loci, l: Locus) ?*ShellFs {
        return switch (self.entry(l)) {
            .shell => |s| s.channel,
            else => null,
        };
    }

    /// Reachability of the place a locus names (R5). `here` is always up; a
    /// peer reports whatever its connection's CURRENT session reports (a
    /// rebound session is read, not the one the place was minted under); a
    /// shell reports its channel's own state. A locus with nothing bound is
    /// offline — never "connected" by default.
    pub fn liveness(self: *const Loci, l: Locus) Liveness {
        return switch (self.entry(l)) {
            .here => .connected,
            .peer => |p| if (p.conn) |c| c.session.liveness() else .offline,
            .shell => |s| if (s.channel) |ch| ch.liveness() else .offline,
        };
    }

    /// Mint a resource handle rooted at a locus. Pure: no table entry, the
    /// resource simply *carries* its locus.
    pub fn resource(self: *const Loci, l: Locus, kind: Kind, ref: u64) Resource {
        _ = self;
        return .{ .loc = l, .knd = kind, .rf = ref };
    }
};

// ── tests ───────────────────────────────────────────────────────────

const t = std.testing;

fn socketPair() ![2]i32 {
    var fds: [2]i32 = undefined;
    const rc = linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM, 0, &fds);
    if (linux.errno(rc) != .SUCCESS) return error.SocketPair;
    return fds;
}

test "locus: here sentinel is index 0, tier .here, always connected" {
    const gpa = t.allocator;
    var loci = try Loci.init(gpa);
    defer loci.deinit();

    try t.expectEqual(@as(u32, 0), @intFromEnum(Locus.here));
    try t.expectEqual(Tier.here, loci.tier(.here));
    try t.expectEqual(Liveness.connected, loci.liveness(.here));
    try t.expect(loci.conn(.here) == null);
    try t.expect(loci.channel(.here) == null);
    try t.expect(loci.authority(.here) == .here);
}

test "locus: an authority resolves only once something minted it, and names it back" {
    const gpa = t.allocator;
    var loci = try Loci.init(gpa);
    defer loci.deinit();

    try t.expect(loci.resolve(.here) == Locus.here);
    try t.expect(loci.resolve(.{ .peer = "deadbeef" }) == null);
    try t.expect(loci.resolve(.{ .shell = "box" }) == null);

    const p = try loci.of(.{ .peer = "deadbeef" });
    const s = try loci.of(.{ .shell = "box" });
    try t.expect(p != .here and s != .here and p != s);
    try t.expectEqual(p, loci.resolve(.{ .peer = "deadbeef" }).?);
    try t.expectEqual(s, loci.resolve(.{ .shell = "box" }).?);
    // A shell and a peer with the same name are different places.
    try t.expect(loci.resolve(.{ .shell = "deadbeef" }) == null);
    try t.expect(loci.authority(p).eql(.{ .peer = "deadbeef" }));
    try t.expect(loci.authority(s).eql(.{ .shell = "box" }));
    // Nothing reaches either yet: offline, never connected by default.
    try t.expectEqual(Liveness.offline, loci.liveness(p));
    try t.expectEqual(Liveness.offline, loci.liveness(s));
}

test "locus: a peer is its fingerprint — rebinding the connection, or Conn.rebind, moves nothing built on it (R2)" {
    const gpa = t.allocator;

    // Two live sessions over their own socketpairs. The session owns the
    // near end and closes it on destroy; we close the far end *first* (its
    // defer is registered after destroy, so LIFO runs it before destroy)
    // to hand the blocked reader an EOF — closing only our own fd would
    // not wake it. The handshake need not complete — we only need a
    // `*Conn` whose `rebind` we can call.
    const fds_a = try socketPair();
    var link_a: session.FdLink = .{ .fd = fds_a[0] };
    const sa = try session.Session.create(gpa, link_a.link(), .server, "tok", .own, null);
    defer sa.destroy();
    defer _ = linux.close(fds_a[1]);

    const fds_b = try socketPair();
    var link_b: session.FdLink = .{ .fd = fds_b[0] };
    const sb = try session.Session.create(gpa, link_b.link(), .server, "tok", .own, null);
    defer sb.destroy();
    defer _ = linux.close(fds_b[1]);

    var first = try session.Conn.init(gpa, sa, "peer", .client);
    defer first.deinit();
    var second = try session.Conn.init(gpa, sb, "peer", .client);
    defer second.deinit();

    var loci = try Loci.init(gpa);
    defer loci.deinit();

    const l = try loci.peer("fp-of-alice");
    const r = loci.resource(l, .file, 42);
    loci.bindPeer(l, &first);
    try t.expectEqual(Tier.peer, loci.tier(l));
    try t.expect(loci.conn(l).? == &first);
    // Not yet handshaken: the session says connecting, and so does the locus.
    try t.expectEqual(Liveness.connecting, loci.liveness(l));

    // Idempotent per fingerprint.
    try t.expectEqual(l, try loci.peer("fp-of-alice"));

    // R2: Conn.rebind swaps the session under the same connection…
    try first.rebind(sb);
    try t.expect(loci.conn(l).? == &first);
    // …and a reconnect from elsewhere rebinds the locus to another
    // connection. Neither moves the locus or anything built on it.
    loci.bindPeer(l, &second);
    try t.expectEqual(l, try loci.peer("fp-of-alice"));
    try t.expectEqual(l, r.locus());
    try t.expectEqual(@as(u64, 42), r.ref());
    try t.expect(loci.conn(l).? == &second);

    // The connection goes away: the place stays, offline.
    loci.bindPeer(l, null);
    try t.expectEqual(Liveness.offline, loci.liveness(l));
    try t.expectEqual(l, loci.resolve(.{ .peer = "fp-of-alice" }).?);
}

test "locus: a shell is its id, and reports its channel's liveness" {
    const gpa = t.allocator;
    var loci = try Loci.init(gpa);
    defer loci.deinit();

    var sh = try ShellFs.spawn(gpa, &.{"/bin/sh"}, .{ .block = .{ .slice = std.mem.span(std.c.environ) } });
    defer sh.deinit();

    const l = try loci.shell("box");
    try t.expectEqual(Tier.shell, loci.tier(l));
    try t.expectEqual(Liveness.offline, loci.liveness(l));
    loci.bindShell(l, &sh);
    try t.expect(loci.channel(l).? == &sh);
    try t.expect(loci.conn(l) == null);
    try t.expect(loci.liveness(l) != .offline);
    try t.expectEqual(l, try loci.shell("box"));
}

test {
    std.testing.refAllDecls(@This());
}
