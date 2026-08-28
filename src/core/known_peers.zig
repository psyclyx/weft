//! TOFU store — remembers peer identity fingerprints across sessions and
//! whether each was verified out of band via its SAS. First contact with
//! an unknown fingerprint is accepted but recorded UNVERIFIED (the SSH
//! known_hosts model); reading the four-word SAS aloud once and marking
//! the peer verified promotes it, and future sessions auto-trust. The
//! authentication is the handshake's (see secure.zig); this module only
//! remembers the human's verdict.
//!
//! Persisted to `$XDG_CONFIG_HOME/weft/known_peers` (else
//! `$HOME/.config/weft/known_peers`), one line per peer:
//!
//!     <fingerprint> <verified|unverified>
//!
//! The whole (small) file is rewritten on every change — no partial
//! writes to reason about.

const std = @import("std");
const identity = @import("identity.zig");

/// How much the local human trusts the key on the other end.
pub const Trust = enum {
    /// Never seen this fingerprint — first contact.
    unknown,
    /// Seen and accepted (TOFU), but the SAS was never confirmed.
    unverified,
    /// The SAS was compared out of band and matched.
    verified,

    pub fn label(self: Trust) []const u8 {
        return @tagName(self);
    }
};

const fp_len = 24; // identity.Identity.fingerprint() length

const Entry = struct {
    fp: [fp_len]u8,
    verified: bool,
};

pub const KnownPeers = struct {
    gpa: std.mem.Allocator,
    entries: std.ArrayList(Entry) = .empty,
    /// Absolute path to persist to, or null when no config home exists
    /// (the store then works in memory only — still correct for a run).
    path: ?[]u8 = null,

    pub const LoadError = std.mem.Allocator.Error;

    /// Load the store (parsing the file if it exists). A missing file or
    /// unreadable config home is not an error: you get an empty store,
    /// and first contacts simply always read as `.unknown`.
    pub fn load(gpa: std.mem.Allocator, environ: anytype) LoadError!KnownPeers {
        var self: KnownPeers = .{ .gpa = gpa };
        var buf: [512]u8 = undefined;
        if (configPath(&buf, environ)) |p| {
            self.path = try gpa.dupe(u8, p);
            self.readInto() catch {}; // absent/garbled file → empty store
        }
        return self;
    }

    pub fn deinit(self: *KnownPeers) void {
        self.entries.deinit(self.gpa);
        if (self.path) |p| self.gpa.free(p);
    }

    /// The trust level for a fingerprint (pure lookup).
    pub fn trust(self: *const KnownPeers, fp: [fp_len]u8) Trust {
        if (self.find(fp)) |e| return if (e.verified) .verified else .unverified;
        return .unknown;
    }

    /// Record a first contact (TOFU): add the fingerprint as unverified if
    /// absent, and persist. Idempotent — an already-known peer keeps its
    /// (possibly verified) status. Returns the trust level BEFORE this
    /// call, so a caller can tell a brand-new peer from a returning one.
    pub fn remember(self: *KnownPeers, fp: [fp_len]u8) !Trust {
        const before = self.trust(fp);
        if (before == .unknown) {
            try self.entries.append(self.gpa, .{ .fp = fp, .verified = false });
            try self.persist();
        }
        return before;
    }

    /// Mark a fingerprint verified (adding it if somehow absent) and
    /// persist. This is the out-of-band SAS confirmation.
    pub fn verify(self: *KnownPeers, fp: [fp_len]u8) !void {
        if (self.find(fp)) |e| {
            e.verified = true;
        } else {
            try self.entries.append(self.gpa, .{ .fp = fp, .verified = true });
        }
        try self.persist();
    }

    /// Forget a peer entirely (revoke trust) and persist.
    pub fn forget(self: *KnownPeers, fp: [fp_len]u8) !void {
        for (self.entries.items, 0..) |e, i| {
            if (std.mem.eql(u8, &e.fp, &fp)) {
                _ = self.entries.orderedRemove(i);
                try self.persist();
                return;
            }
        }
    }

    fn find(self: *const KnownPeers, fp: [fp_len]u8) ?*Entry {
        for (self.entries.items) |*e| {
            if (std.mem.eql(u8, &e.fp, &fp)) return e;
        }
        return null;
    }

    fn readInto(self: *KnownPeers) !void {
        const path = self.path orelse return;
        var threaded: std.Io.Threaded = .init(self.gpa, .{});
        defer threaded.deinit();
        const io = threaded.io();
        const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, self.gpa, .unlimited);
        defer self.gpa.free(bytes);
        var lines = std.mem.tokenizeScalar(u8, bytes, '\n');
        while (lines.next()) |line| {
            var parts = std.mem.tokenizeScalar(u8, line, ' ');
            const fp_s = parts.next() orelse continue;
            if (fp_s.len != fp_len) continue;
            const status = parts.next() orelse "unverified";
            var fp: [fp_len]u8 = undefined;
            @memcpy(&fp, fp_s);
            try self.entries.append(self.gpa, .{
                .fp = fp,
                .verified = std.mem.eql(u8, status, "verified"),
            });
        }
    }

    fn persist(self: *KnownPeers) !void {
        const path = self.path orelse return; // in-memory only
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(self.gpa);
        for (self.entries.items) |e| {
            try out.appendSlice(self.gpa, &e.fp);
            try out.append(self.gpa, ' ');
            try out.appendSlice(self.gpa, if (e.verified) "verified" else "unverified");
            try out.append(self.gpa, '\n');
        }
        var threaded: std.Io.Threaded = .init(self.gpa, .{});
        defer threaded.deinit();
        const io = threaded.io();
        const cwd = std.Io.Dir.cwd();
        if (std.fs.path.dirname(path)) |dir| cwd.createDirPath(io, dir) catch {};
        try cwd.writeFile(io, .{ .sub_path = path, .data = out.items });
        // The list of who you trust is not a secret, but it is yours.
        var zbuf: [512]u8 = undefined;
        if (path.len < zbuf.len) {
            @memcpy(zbuf[0..path.len], path);
            zbuf[path.len] = 0;
            _ = std.os.linux.fchmodat(std.os.linux.AT.FDCWD, zbuf[0..path.len :0].ptr, 0o600);
        }
    }
};

/// Where the trust list lives. Public for the same reason
/// `identity.configPath` is: `core/machinery.zig`'s carve-out asks the owner
/// rather than re-deriving the XDG chain, so the refusal cannot drift from
/// the file (doc/place.md §4.1).
pub fn configPath(buf: []u8, environ: anytype) ?[:0]const u8 {
    if (environ.getPosix("XDG_CONFIG_HOME")) |x| {
        if (x.len > 0) return std.fmt.bufPrintZ(buf, "{s}/weft/known_peers", .{x}) catch null;
    }
    if (environ.getPosix("HOME")) |h| {
        return std.fmt.bufPrintZ(buf, "{s}/.config/weft/known_peers", .{h}) catch null;
    }
    return null;
}

// ── Tests ───────────────────────────────────────────────────────────

const t = std.testing;

const TestEnv = struct {
    home: []const u8,
    fn getPosix(self: @This(), name: []const u8) ?[]const u8 {
        if (std.mem.eql(u8, name, "HOME")) return self.home;
        return null; // no XDG_CONFIG_HOME → falls back to HOME/.config
    }
};

test "known_peers: TOFU lifecycle across reloads" {
    const gpa = t.allocator;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const home = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer gpa.free(home);
    const env = TestEnv{ .home = home };

    const a = identity.Identity.forTest(0x11).fingerprint();
    const b = identity.Identity.forTest(0x22).fingerprint();

    {
        var kp = try KnownPeers.load(gpa, env);
        defer kp.deinit();
        // First contact: unknown, then remembered as unverified.
        try t.expectEqual(Trust.unknown, kp.trust(a));
        try t.expectEqual(Trust.unknown, try kp.remember(a));
        try t.expectEqual(Trust.unverified, kp.trust(a));
        // Remembering again is idempotent and reports the prior state.
        try t.expectEqual(Trust.unverified, try kp.remember(a));
        // Verify promotes it; b stays unknown.
        try kp.verify(a);
        try t.expectEqual(Trust.verified, kp.trust(a));
        try t.expectEqual(Trust.unknown, kp.trust(b));
    }

    // A fresh store reads the persisted verdicts back.
    {
        var kp = try KnownPeers.load(gpa, env);
        defer kp.deinit();
        try t.expectEqual(Trust.verified, kp.trust(a));
        try t.expectEqual(Trust.unknown, kp.trust(b));
        // Forget revokes and persists.
        try kp.forget(a);
        try t.expectEqual(Trust.unknown, kp.trust(a));
    }
    {
        var kp = try KnownPeers.load(gpa, env);
        defer kp.deinit();
        try t.expectEqual(Trust.unknown, kp.trust(a));
    }
}

test "known_peers: no config home → in-memory store still works" {
    const gpa = t.allocator;
    const Empty = struct {
        fn getPosix(_: @This(), _: []const u8) ?[]const u8 {
            return null;
        }
    };
    var kp = try KnownPeers.load(gpa, Empty{});
    defer kp.deinit();
    const a = identity.Identity.forTest(0x33).fingerprint();
    try t.expectEqual(@as(?[]u8, null), kp.path);
    try t.expectEqual(Trust.unknown, try kp.remember(a));
    try t.expectEqual(Trust.unverified, kp.trust(a));
}

test {
    std.testing.refAllDecls(@This());
}
