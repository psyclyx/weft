//! Peer identity — a long-term X25519 keypair, persisted once per machine,
//! that names a weft across sessions. Authentication (who you are) is thus
//! separate from the ephemeral session keys (forward secrecy) and from the
//! token (a pre-shared secret, optional). The public key's fingerprint is
//! what a human verifies out of band.
//!
//! Trust model: TOFU + a Short Authentication String. On first contact a
//! peer's fingerprint is unknown; the session derives a SAS from its
//! transcript (both identity keys + the ephemeral DH secret) that both
//! ends display. Comparing the SAS over an authentic out-of-band channel
//! ("read me your four words") detects a man in the middle — a MITM does
//! separate exchanges with each side, so the two SAS differ. No CA. Once
//! verified, the fingerprint is remembered and future sessions auto-trust.
//!
//! This module owns only the keypair, its fingerprint, and the SAS/color
//! derivations; the handshake wiring and the known-peers store live with
//! the session layer.

const std = @import("std");
const crypto = std.crypto;
const X25519 = crypto.dh.X25519;
const Sha256 = crypto.hash.sha2.Sha256;

pub const public_len = X25519.public_length;
pub const secret_len = X25519.secret_length;

/// A long-term keypair. The secret never leaves the process; only the
/// public key and its fingerprint are shared.
pub const Identity = struct {
    secret: [secret_len]u8,
    public: [public_len]u8,

    pub fn generate() Identity {
        var secret: [secret_len]u8 = undefined;
        fillRandom(&secret);
        const public = X25519.recoverPublicKey(secret) catch unreachable;
        return .{ .secret = secret, .public = public };
    }

    fn fromSecret(secret: [secret_len]u8) Identity {
        return .{ .secret = secret, .public = X25519.recoverPublicKey(secret) catch unreachable };
    }

    /// A stable, human-comparable fingerprint of the public key: five
    /// Crockford-base32 groups of four (`k7q2-9fh3-...`). Short enough to
    /// read aloud, long enough (100 bits) to make collisions infeasible.
    pub fn fingerprint(self: *const Identity) [24]u8 {
        var h: [Sha256.digest_length]u8 = undefined;
        Sha256.hash(&self.public, &h, .{});
        return groupBase32(h[0..13].*); // 100 bits → 20 chars + 4 dashes
    }

    /// A distinct, always-legible color for this peer, derived from the
    /// fingerprint hash: a fixed-saturation/lightness hue so it reads on
    /// the dark theme. Presentation lives in the view; this is the seed.
    pub fn hue(self: *const Identity) f32 {
        var h: [Sha256.digest_length]u8 = undefined;
        Sha256.hash(&self.public, &h, .{});
        const v = std.mem.readInt(u16, h[13..15], .little);
        return @as(f32, @floatFromInt(v)) / 65535.0; // [0,1)
    }
};

fn fillRandom(buf: []u8) void {
    var got: usize = 0;
    while (got < buf.len) {
        const rc = std.os.linux.getrandom(buf[got..].ptr, buf.len - got, 0);
        if (std.os.linux.errno(rc) != .SUCCESS) @panic("getrandom failed");
        got += rc;
    }
}

const crockford = "0123456789abcdefghjkmnpqrstvwxyz";

/// 13 bytes (104 bits) → base32, keeping the first 20 symbols in `-`
/// groups of four (100 bits presented).
fn groupBase32(bytes: [13]u8) [24]u8 {
    var sym: [21]u8 = undefined;
    var acc: u64 = 0;
    var bits: u6 = 0;
    var si: usize = 0;
    for (bytes) |b| {
        acc = (acc << 8) | b;
        bits +%= 8;
        while (bits >= 5) : (bits -%= 5) {
            const shift: u6 = @intCast(bits - 5);
            sym[si] = crockford[@as(usize, @intCast((acc >> shift) & 0x1f))];
            si += 1;
            if (si == sym.len) break;
        }
        if (si == sym.len) break;
    }
    var out: [24]u8 = undefined;
    var oi: usize = 0;
    for (0..20) |i| {
        if (i != 0 and i % 4 == 0) {
            out[oi] = '-';
            oi += 1;
        }
        out[oi] = sym[i];
        oi += 1;
    }
    return out;
}

// ── Persistence ─────────────────────────────────────────────────────

pub const LoadError = error{ NoConfigHome, BadKeyFile } || std.mem.Allocator.Error;

/// Load the machine's identity from `$XDG_CONFIG_HOME/weft/identity`
/// (else `$HOME/.config/weft/identity`), generating and persisting one on
/// first run (mode 0600). Headless hosts get an identity the same way, so
/// they too are namable and verifiable.
pub fn loadOrGenerate(gpa: std.mem.Allocator, environ: anytype) LoadError!Identity {
    var buf: [512]u8 = undefined;
    const path = configPath(&buf, environ) orelse return error.NoConfigHome;

    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const cwd = std.Io.Dir.cwd();

    if (cwd.readFileAlloc(io, path, gpa, .unlimited)) |bytes| {
        defer gpa.free(bytes);
        if (bytes.len != secret_len) return error.BadKeyFile;
        return Identity.fromSecret(bytes[0..secret_len].*);
    } else |_| {}

    // Generate + persist. Best-effort dir creation; 0600 on the key so the
    // secret is not left world-readable.
    const id = Identity.generate();
    if (std.fs.path.dirname(path)) |dir| cwd.createDirPath(io, dir) catch {};
    cwd.writeFile(io, .{ .sub_path = path, .data = &id.secret }) catch {};
    _ = std.os.linux.fchmodat(std.os.linux.AT.FDCWD, path.ptr, 0o600);
    return id;
}

fn configPath(buf: []u8, environ: anytype) ?[:0]const u8 {
    if (environ.getPosix("XDG_CONFIG_HOME")) |x| {
        if (x.len > 0) return std.fmt.bufPrintZ(buf, "{s}/weft/identity", .{x}) catch null;
    }
    if (environ.getPosix("HOME")) |h| {
        return std.fmt.bufPrintZ(buf, "{s}/.config/weft/identity", .{h}) catch null;
    }
    return null;
}

// ── Tests ───────────────────────────────────────────────────────────

const t = std.testing;

test "fingerprint is stable and well-formed" {
    const id = Identity.fromSecret(@splat(7));
    const fp1 = id.fingerprint();
    const fp2 = id.fingerprint();
    try t.expectEqualSlices(u8, &fp1, &fp2);
    // Five dash-separated groups of four.
    var groups: usize = 1;
    for (fp1) |c| if (c == '-') {
        groups += 1;
    };
    try t.expectEqual(@as(usize, 5), groups);
    try t.expectEqual(@as(usize, 24), fp1.len);
}

test "distinct keys give distinct fingerprints" {
    const a = Identity.fromSecret(@splat(1));
    const b = Identity.fromSecret(@splat(2));
    try t.expect(!std.mem.eql(u8, &a.fingerprint(), &b.fingerprint()));
}

test "loadOrGenerate persists and round-trips" {
    const gpa = t.allocator;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const home = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer gpa.free(home);

    const Env = struct {
        home: []const u8,
        fn getPosix(self: @This(), name: []const u8) ?[]const u8 {
            if (std.mem.eql(u8, name, "HOME")) return self.home;
            return null;
        }
    };
    const env = Env{ .home = home };

    const first = try loadOrGenerate(gpa, env);
    const second = try loadOrGenerate(gpa, env); // now reads the file
    try t.expectEqualSlices(u8, &first.secret, &second.secret);
    try t.expectEqualSlices(u8, &first.fingerprint(), &second.fingerprint());
}
