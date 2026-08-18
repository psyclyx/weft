//! Locus — the locality primitive: *where* bytes and effects live. A
//! path or handle is meaningless on its own (rule R1); it means something
//! only paired with the locus that hosts it. Three tiers:
//!
//! - **here** — this process. The always-present sentinel, `Locus` 0, so
//!   the local case is never a branch and never a lookup.
//! - **peer** — an authenticated weft connection (`session.Conn`). Its
//!   identity is the connection itself, not the wire address: `Conn.rebind`
//!   re-points a live connection at a fresh `Session` after a reconnect,
//!   and the `Locus` (and every `Resource` built on it) is unchanged —
//!   rule R2. So a peer locus references the stable `*Conn`, never the
//!   swappable `*Session`.
//! - **shell** — a persistent coreutils channel (`ShellFs`), the tramp tier.
//!
//! Effect handles carry their locus *inside* them: a `Resource` is an
//! opaque `(locus, kind, ref)` triple whose `ref` only the owning tier
//! interprets, so a guest holding one cannot re-target it at another
//! locus. `Loci` is the host-side registry that owns the table and hands
//! back stable handles; `resolve*` is idempotent per authority (same
//! connection/shell/name → same `Locus`).

const std = @import("std");
const Allocator = std.mem.Allocator;
const linux = std.os.linux;

const session = @import("session.zig");
const ShellFs = @import("ShellFs.zig");

/// Which kind of place a locus names.
pub const Tier = enum { here, peer, shell };

/// What a resource *is*, so its `ref` can be interpreted by the tier that
/// owns it. Opaque to everyone else.
pub const Kind = enum { file, dir, proc, lsp, sock, buf };

/// A small opaque locality handle. `here` is the sentinel (index 0, the
/// local process); every other value is an index into a `Loci` table.
/// Compare for equality, never interpret the integer.
pub const Locus = enum(u32) { here = 0, _ };

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
/// value, with index 0 permanently the `here` sentinel.
pub const Loci = struct {
    gpa: Allocator,
    entries: std.ArrayList(Entry) = .empty,

    /// A registered place. The tag is the `Tier`; a peer holds the stable
    /// `*Conn` (never the session, which `rebind` swaps), a shell holds
    /// its `*ShellFs`.
    const Entry = union(Tier) {
        here,
        peer: *session.Conn,
        shell: *ShellFs,
    };

    pub fn init(gpa: Allocator) !Loci {
        var self: Loci = .{ .gpa = gpa };
        try self.entries.append(gpa, .here); // index 0 is the sentinel
        return self;
    }

    pub fn deinit(self: *Loci) void {
        self.entries.deinit(self.gpa);
    }

    /// Register a live connection as a peer locus. Idempotent: the same
    /// `*Conn` always maps to the same `Locus` (the connection *is* the
    /// identity, per R2).
    pub fn resolvePeer(self: *Loci, c: *session.Conn) !Locus {
        for (self.entries.items, 0..) |e, i| switch (e) {
            .peer => |ec| if (ec == c) return @enumFromInt(@as(u32, @intCast(i))),
            else => {},
        };
        const idx = self.entries.items.len;
        try self.entries.append(self.gpa, .{ .peer = c });
        return @enumFromInt(@as(u32, @intCast(idx)));
    }

    /// Register a live coreutils channel as a shell locus. Idempotent per
    /// `*ShellFs`.
    pub fn resolveShell(self: *Loci, sh: *ShellFs) !Locus {
        for (self.entries.items, 0..) |e, i| switch (e) {
            .shell => |es| if (es == sh) return @enumFromInt(@as(u32, @intCast(i))),
            else => {},
        };
        const idx = self.entries.items.len;
        try self.entries.append(self.gpa, .{ .shell = sh });
        return @enumFromInt(@as(u32, @intCast(idx)));
    }

    /// Resolve a URI authority to a locus. Only the trivial `"here"` case
    /// today; anything else is null.
    /// TODO: fingerprint/alias resolution arrives with the connection
    /// registry (a known-peer fingerprint or short name → its live `Conn`).
    pub fn resolve(self: *Loci, authority: []const u8) ?Locus {
        _ = self;
        if (std.mem.eql(u8, authority, "here")) return .here;
        return null;
    }

    pub fn tier(self: *const Loci, l: Locus) Tier {
        return std.meta.activeTag(self.entries.items[@intFromEnum(l)]);
    }

    /// The peer connection behind a locus, or null if it is not a peer.
    pub fn conn(self: *const Loci, l: Locus) ?*session.Conn {
        return switch (self.entries.items[@intFromEnum(l)]) {
            .peer => |c| c,
            else => null,
        };
    }

    /// The shell channel behind a locus, or null if it is not a shell.
    pub fn shell(self: *const Loci, l: Locus) ?*ShellFs {
        return switch (self.entries.items[@intFromEnum(l)]) {
            .shell => |s| s,
            else => null,
        };
    }

    /// Reachability of the place a locus names. `here` is always up; a
    /// peer delegates to its connection's current session (the point of
    /// R2: the same locus reports whatever the freshly-rebound session
    /// reports).
    pub fn liveness(self: *const Loci, l: Locus) session.Liveness {
        return switch (self.entries.items[@intFromEnum(l)]) {
            .here => .connected,
            .peer => |c| c.session.liveness(),
            // TODO: ShellFs exposes no liveness signal yet; a dead shell
            // surfaces as an error on the next call, not here.
            .shell => .connected,
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
    try t.expectEqual(session.Liveness.connected, loci.liveness(.here));
    try t.expect(loci.conn(.here) == null);
    try t.expect(loci.shell(.here) == null);
}

test "locus: resolve authority — here sentinel, everything else null" {
    const gpa = t.allocator;
    var loci = try Loci.init(gpa);
    defer loci.deinit();

    try t.expect(loci.resolve("here") == Locus.here);
    try t.expect(loci.resolve("weft://deadbeef") == null);
    try t.expect(loci.resolve("") == null);
}

test "locus: a resource built on a locus survives Conn.rebind (handle stable)" {
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

    var conn = try session.Conn.init(gpa, sa, "peer", .client);
    defer conn.deinit();

    var loci = try Loci.init(gpa);
    defer loci.deinit();

    const l = try loci.resolvePeer(&conn);
    const r = loci.resource(l, .file, 42);

    try t.expectEqual(Tier.peer, loci.tier(l));
    try t.expect(loci.conn(l).? == &conn);
    try t.expectEqual(l, r.locus());
    try t.expectEqual(Kind.file, r.kind());
    try t.expectEqual(@as(u64, 42), r.ref());

    // Idempotent: the same connection resolves to the same locus.
    const l_again = try loci.resolvePeer(&conn);
    try t.expectEqual(l, l_again);

    // R2: rebind swaps the underlying session but not the identity. The
    // locus and every resource on it are byte-for-byte unchanged.
    try conn.rebind(sb);
    try t.expect(conn.session == sb);
    try t.expectEqual(l, r.locus());
    try t.expectEqual(@as(u64, 42), r.ref());
    try t.expectEqual(Tier.peer, loci.tier(l));
    try t.expect(loci.conn(l).? == &conn);
}

test "locus: shell resolves, reports tier .shell, idempotent" {
    const gpa = t.allocator;
    var loci = try Loci.init(gpa);
    defer loci.deinit();

    // We only register the pointer and read back its tier — never call
    // into ShellFs — so an uninitialized value is a fine identity token.
    var sh: ShellFs = undefined;

    const l = try loci.resolveShell(&sh);
    try t.expectEqual(Tier.shell, loci.tier(l));
    try t.expect(loci.shell(l).? == &sh);
    try t.expect(loci.conn(l) == null);
    try t.expectEqual(session.Liveness.connected, loci.liveness(l));

    const l_again = try loci.resolveShell(&sh);
    try t.expectEqual(l, l_again);
    try t.expect(l != Locus.here);
}

test {
    std.testing.refAllDecls(@This());
}
