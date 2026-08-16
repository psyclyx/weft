//! The securer seam — wire v1's noise-style channel from std.crypto
//! primitives only (no hand-rolled math): ephemeral X25519 both ways,
//! HKDF-SHA256 keyed by the DH secret with the shared session token as
//! salt and the transcript as info, transcript MACs to authenticate the
//! token before any payload, then per-direction XChaCha20-Poly1305 with
//! counter nonces. Trust model in doc/wire.md. The functions are pure
//! over byte slices; the session layer owns transport.

const std = @import("std");
const crypto = std.crypto;
const X25519 = crypto.dh.X25519;
const Hkdf = crypto.kdf.hkdf.HkdfSha256;
const Hmac = crypto.auth.hmac.sha2.HmacSha256;
const Aead = crypto.aead.chacha_poly.XChaCha20Poly1305;
const Sha256 = crypto.hash.sha2.Sha256;

pub const key_len = Aead.key_length;
pub const tag_len = Aead.tag_length;
pub const pub_len = X25519.public_length;
pub const sec_len = X25519.secret_length;
pub const mac_len = Hmac.mac_length;
pub const sas_len = 8;

pub const Role = enum { client, server };

pub const Keys = struct {
    /// Encryption keys, one per direction (client→server, server→client).
    c2s: [key_len]u8,
    s2c: [key_len]u8,
    /// Transcript MACs each side must present.
    mac_c: [mac_len]u8,
    mac_s: [mac_len]u8,
    /// Short Authentication String seed — identical on both untampered
    /// ends, divergent across a man in the middle. Rendered to words by
    /// `identity.sasWords`.
    sas: [sas_len]u8,
};

pub const Ephemeral = struct {
    secret: [X25519.secret_length]u8,
    public: [pub_len]u8,

    pub fn generate() Ephemeral {
        var secret: [X25519.secret_length]u8 = undefined;
        // getrandom(2): the kernel CSPRNG, no std.Io plumbing.
        var got: usize = 0;
        while (got < secret.len) {
            const rc = std.os.linux.getrandom(secret[got..].ptr, secret.len - got, 0);
            if (std.os.linux.errno(rc) != .SUCCESS) @panic("getrandom failed");
            got += rc;
        }
        const public = X25519.recoverPublicKey(secret) catch unreachable;
        return .{ .secret = secret, .public = public };
    }
};

/// Derive the channel keys from the ephemeral DH, the *static* identity
/// DH, the shared token, and the transcript. Symmetric: both sides
/// compute the same `Keys`.
///
/// Two Diffie-Hellmans feed the key schedule: the ephemeral one (forward
/// secrecy) and the identity one (`ss`, static-static). Mixing `ss` binds
/// the channel to the two long-term keys — a party that does not hold the
/// identity secret behind the key it presented cannot derive matching
/// keys, so the closing MACs authenticate identity possession. The
/// transcript (both ephemerals + both identity keys) hashes into the KDF
/// info and thus into the SAS, so any substituted key changes the words a
/// human compares. On first contact the identities are unknown (TOFU): the
/// handshake still completes, and the SAS is what defends it.
pub fn derive(
    our: Ephemeral,
    their_pub: [pub_len]u8,
    token: []const u8,
    client_pub: [pub_len]u8,
    server_pub: [pub_len]u8,
    our_id_secret: [sec_len]u8,
    their_id_pub: [pub_len]u8,
    client_id_pub: [pub_len]u8,
    server_id_pub: [pub_len]u8,
) error{IdentityElement}!Keys {
    const ee = try X25519.scalarmult(our.secret, their_pub);
    const ss = try X25519.scalarmult(our_id_secret, their_id_pub);
    // Input keying material: ephemeral DH then identity DH.
    var ikm: [pub_len * 2]u8 = undefined;
    @memcpy(ikm[0..pub_len], &ee);
    @memcpy(ikm[pub_len..], &ss);

    var transcript: [pub_len * 4]u8 = undefined;
    @memcpy(transcript[0..pub_len], &client_pub);
    @memcpy(transcript[pub_len .. pub_len * 2], &server_pub);
    @memcpy(transcript[pub_len * 2 .. pub_len * 3], &client_id_pub);
    @memcpy(transcript[pub_len * 3 ..], &server_id_pub);
    var th: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(&transcript, &th, .{});

    const prk = Hkdf.extract(token, &ikm);
    var okm: [key_len * 2 + 32 * 2 + sas_len]u8 = undefined;
    Hkdf.expand(&okm, &th, prk);

    var keys: Keys = undefined;
    @memcpy(&keys.c2s, okm[0..key_len]);
    @memcpy(&keys.s2c, okm[key_len .. key_len * 2]);
    var mac_key_c: [32]u8 = undefined;
    var mac_key_s: [32]u8 = undefined;
    @memcpy(&mac_key_c, okm[key_len * 2 .. key_len * 2 + 32]);
    @memcpy(&mac_key_s, okm[key_len * 2 + 32 .. key_len * 2 + 64]);
    @memcpy(&keys.sas, okm[key_len * 2 + 64 ..]);
    Hmac.create(&keys.mac_c, &th, &mac_key_c);
    Hmac.create(&keys.mac_s, &th, &mac_key_s);
    return keys;
}

pub fn macEql(a: [mac_len]u8, b: [mac_len]u8) bool {
    return crypto.timing_safe.eql([mac_len]u8, a, b);
}

/// One direction of the channel: seal/open with a counter nonce.
pub const Channel = struct {
    key: [key_len]u8,
    counter: u64 = 0,

    fn nonceFor(counter: u64) [Aead.nonce_length]u8 {
        var nonce: [Aead.nonce_length]u8 = @splat(0);
        std.mem.writeInt(u64, nonce[0..8], counter, .little);
        return nonce;
    }

    /// Caller owns the result (ciphertext || tag).
    pub fn seal(self: *Channel, gpa: std.mem.Allocator, plain: []const u8) ![]u8 {
        const out = try gpa.alloc(u8, plain.len + tag_len);
        var tag: [tag_len]u8 = undefined;
        Aead.encrypt(out[0..plain.len], &tag, plain, "", nonceFor(self.counter), self.key);
        @memcpy(out[plain.len..], &tag);
        self.counter += 1;
        return out;
    }

    /// Caller owns the result; error.AuthenticationFailed on tamper or
    /// desync (counters are strict — the stream is ordered).
    pub fn open(self: *Channel, gpa: std.mem.Allocator, sealed: []const u8) ![]u8 {
        if (sealed.len < tag_len) return error.AuthenticationFailed;
        const clen = sealed.len - tag_len;
        const out = try gpa.alloc(u8, clen);
        errdefer gpa.free(out);
        var tag: [tag_len]u8 = undefined;
        @memcpy(&tag, sealed[clen..]);
        try Aead.decrypt(out, sealed[0..clen], tag, "", nonceFor(self.counter), self.key);
        self.counter += 1;
        return out;
    }
};

// ── Tests ───────────────────────────────────────────────────────────

const t = std.testing;

/// A throwaway identity keypair for the crypto tests (getrandom-backed,
/// like Ephemeral — no persistence).
fn idPair() struct { secret: [sec_len]u8, public: [pub_len]u8 } {
    const e = Ephemeral.generate();
    return .{ .secret = e.secret, .public = e.public };
}

test "secure: handshake derives matching keys; wrong token fails the MAC" {
    const gpa = t.allocator;
    const c = Ephemeral.generate();
    const s = Ephemeral.generate();
    const ci = idPair();
    const si = idPair();

    const kc = try derive(c, s.public, "token-1", c.public, s.public, ci.secret, si.public, ci.public, si.public);
    const ks = try derive(s, c.public, "token-1", c.public, s.public, si.secret, ci.public, ci.public, si.public);
    try t.expect(macEql(kc.mac_c, ks.mac_c));
    try t.expect(macEql(kc.mac_s, ks.mac_s));
    try t.expectEqualSlices(u8, &kc.c2s, &ks.c2s);
    // Both untampered ends agree on the SAS.
    try t.expectEqualSlices(u8, &kc.sas, &ks.sas);

    const kw = try derive(s, c.public, "token-2", c.public, s.public, si.secret, ci.public, ci.public, si.public);
    try t.expect(!macEql(kc.mac_c, kw.mac_c));

    // Channel round trip + tamper detection + counter discipline.
    var tx: Channel = .{ .key = kc.c2s };
    var rx: Channel = .{ .key = ks.c2s };
    const sealed = try tx.seal(gpa, "op frame bytes");
    defer gpa.free(sealed);
    const opened = try rx.open(gpa, sealed);
    defer gpa.free(opened);
    try t.expectEqualStrings("op frame bytes", opened);

    var tampered = try gpa.dupe(u8, sealed);
    defer gpa.free(tampered);
    tampered[0] ^= 1;
    try t.expectError(error.AuthenticationFailed, rx.open(gpa, tampered));
}

test "secure: identity possession is required — a key you don't hold fails the MAC" {
    const c = Ephemeral.generate();
    const s = Ephemeral.generate();
    const ci = idPair();
    const si = idPair(); // the identity the server legitimately holds
    const impostor = idPair(); // some other secret

    // The honest client derives against the server identity `si`.
    const kc = try derive(c, s.public, "tok", c.public, s.public, ci.secret, si.public, ci.public, si.public);
    // An impostor PRESENTS si.public (public keys are public) but computes
    // the static DH with a secret it actually holds — not si's. The
    // transcript matches; the mixed `ss` does not, so the MACs diverge and
    // the honest client rejects it.
    const kx = try derive(s, c.public, "tok", c.public, s.public, impostor.secret, ci.public, ci.public, si.public);
    try t.expect(!macEql(kc.mac_s, kx.mac_s));
    try t.expect(!macEql(kc.mac_c, kx.mac_c));
}

test "secure: a man in the middle makes the SAS diverge" {
    // A ── M ── B, with M relaying but substituting its own keys. Each leg
    // is a *valid* handshake (M holds its own identity), so nothing fails
    // locally — but the SAS the two honest ends would read aloud differ,
    // which is the whole point of comparing it out of band.
    const a_eph = Ephemeral.generate();
    const b_eph = Ephemeral.generate();
    const ai = idPair(); // Alice identity
    const bi = idPair(); // Bob identity
    const mi = idPair(); // MITM identity (one, presented to both)
    const m_to_a = Ephemeral.generate(); // M's ephemeral facing Alice
    const m_to_b = Ephemeral.generate(); // M's ephemeral facing Bob

    // Alice⇄M leg: Alice is client, M plays server (with identity mi).
    const k_alice = try derive(a_eph, m_to_a.public, "tok", a_eph.public, m_to_a.public, ai.secret, mi.public, ai.public, mi.public);
    const k_m_left = try derive(m_to_a, a_eph.public, "tok", a_eph.public, m_to_a.public, mi.secret, ai.public, ai.public, mi.public);
    try t.expectEqualSlices(u8, &k_alice.sas, &k_m_left.sas); // the leg itself is consistent

    // M⇄Bob leg: M plays client (identity mi), Bob is server.
    const k_bob = try derive(b_eph, m_to_b.public, "tok", m_to_b.public, b_eph.public, bi.secret, mi.public, mi.public, bi.public);
    const k_m_right = try derive(m_to_b, b_eph.public, "tok", m_to_b.public, b_eph.public, mi.secret, bi.public, mi.public, bi.public);
    try t.expectEqualSlices(u8, &k_bob.sas, &k_m_right.sas);

    // The human check: Alice's words and Bob's words do NOT match.
    try t.expect(!std.mem.eql(u8, &k_alice.sas, &k_bob.sas));
}
