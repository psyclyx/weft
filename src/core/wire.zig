//! Wire v1 — frame codec and the sender-side class queue. Pure: no
//! sockets, no crypto, no threads; the conformance tests here are the
//! executable spec for doc/wire.md. Every frame belongs to exactly one
//! class; the queue implements the normative priority order and
//! latest-wins feed coalescing.

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

pub const version: u16 = 2;

pub const Class = enum(u8) {
    control = 0,
    op = 1,
    request = 2,
    feed = 3,
};

/// Kinds are class-scoped.
pub const ControlKind = enum(u8) { hello = 0, hello2 = 1, finish = 2, accept = 3, heartbeat = 4 };
/// `share` (channel 0) announces a shared buffer: payload =
/// uv base_channel | uv name_len | name. The announced quad
/// [base, base+3] carries that buffer's ops / presence / diagnostics /
/// blobs; the legacy single-document flow is exactly quad 0.
/// `grant` (host→client, on the quad's base) carries the grade the host
/// has assigned this peer for the quad's document: a single byte
/// (`Access`). The client sets `Document.my_grant` from it so it can refuse
/// a local edit its ops would only be dropped for — see session.zig.
/// `region_refused` (GraphDoc quads only, W6 slice 1's per-region lease —
/// doc/substrate.md §4) is the LOUD counterpart to a batch that was
/// decoded and passed the coarse `canEdit` gate but was refused at the
/// per-region admission hook because the sender doesn't hold the lease on
/// a region its ops touch: uv region_token_len | region_token | uv
/// holder_len | holder — sent back to the sender on the SAME quad so the
/// refusal is observable, never a silent drop (see GraphCollab.zig). A
/// `Collab` (text doc) peer that doesn't know this kind ignores it
/// gracefully (`std.enums.fromInt` returns null); text docs have no
/// regions to refuse.
/// `publish` (channel 0) announces a quad's PUBLICATION DESCRIPTOR — which
/// replica and which endpoint surfaces that quad exports (see
/// session/publication.zig). It replaces nothing: `share` still announces
/// the quad, and a quad with no descriptor is the legacy bundle (replica +
/// presence + diagnostics + blobs), which is why an older peer that skips
/// this kind behaves exactly as before. `unpublish` (channel 0) revokes a
/// quad's exports and advances its epoch: uv base | uv epoch.
pub const OpKind = enum(u8) { batch = 0, frontier = 1, share = 2, grant = 3, region_refused = 4, publish = 5, unpublish = 6 };
// call/ok/err/cancel are the blob (partial-checkout) request cycle; fs_call/
// fs_ok/fs_err are the .peer filesystem cycle (peer_fs) — DISTINCT kinds, so
// fs ops never collide with the blob op-space (which routes by op-byte value)
// and neither does a failure reply, since the two cycles number their ids
// independently.
// `err`/`fs_err` carry `uv id`, then an ADDITIVE trailing `FailureReason`
// byte: the responder cannot serve that call, so the requester settles it now
// instead of waiting out its deadline (see session/requests.zig). A peer built
// before them ignores an unknown request kind, which degrades to exactly the
// old behaviour — the deadline.
pub const RequestKind = enum(u8) { call = 0, ok = 1, err = 2, cancel = 3, fs_call = 4, fs_ok = 5, fs_err = 6 };
/// Why a call was refused — the trailing byte of an `err`/`fs_err` payload,
/// which was `uv id` alone before. Absent (an older responder, or a short
/// payload) reads as `.unspecified`, the failure every requester already
/// handled; an unknown reason reads the same way. Purely additive: it tells
/// the requester WHY, it never changes that the call failed.
pub const FailureReason = enum(u8) { unspecified = 0, not_granted = 1, _ };
pub const FeedKind = enum(u8) { publish = 0 };

pub const Frame = struct {
    class: Class,
    kind: u8,
    channel: u64,
    payload: []const u8,
};

pub fn putUv(gpa: Allocator, out: *std.ArrayList(u8), v: u64) !void {
    var x = v;
    while (true) {
        const b: u8 = @intCast(x & 0x7f);
        x >>= 7;
        if (x == 0) {
            try out.append(gpa, b);
            return;
        }
        try out.append(gpa, b | 0x80);
    }
}

pub fn getUv(cur: *[]const u8) error{Corrupt}!u64 {
    var shift: u6 = 0;
    var v: u64 = 0;
    while (cur.len > 0) {
        const b = cur.*[0];
        cur.* = cur.*[1..];
        v |= @as(u64, b & 0x7f) << shift;
        if (b & 0x80 == 0) return v;
        if (shift >= 57) return error.Corrupt;
        shift += 7;
    }
    return error.Corrupt;
}

/// Portable CRDT position on the wire. This mirrors Stemma's identity anchor
/// structurally without making the transport codec depend on Stemma: an
/// inserting agent and sequence identify the character, while `side` selects
/// the boundary before or after it. An empty agent is a document boundary.
pub const AnchorWire = struct {
    agent: []const u8,
    seq: u64,
    side: u8,
};

/// Encode one identity anchor. The agent bytes are opaque here; the CRDT
/// adapter owns their meaning and validates `side` against its anchor enum.
pub fn putAnchor(gpa: Allocator, out: *std.ArrayList(u8), anchor: AnchorWire) Allocator.Error!void {
    try putUv(gpa, out, anchor.agent.len);
    try out.appendSlice(gpa, anchor.agent);
    try putUv(gpa, out, anchor.seq);
    try out.append(gpa, anchor.side);
}

/// Decode one borrowed identity anchor and advance `cur` past it.
pub fn getAnchor(cur: *[]const u8) error{Corrupt}!AnchorWire {
    const agent_len = try getUv(cur);
    if (agent_len > cur.len) return error.Corrupt;
    const agent = cur.*[0..@intCast(agent_len)];
    cur.* = cur.*[@intCast(agent_len)..];
    const seq = try getUv(cur);
    if (cur.len == 0) return error.Corrupt;
    const side = cur.*[0];
    cur.* = cur.*[1..];
    return .{ .agent = agent, .seq = seq, .side = side };
}

/// Encode one frame (length-prefixed). Caller owns.
pub fn encode(gpa: Allocator, frame: Frame) ![]u8 {
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(gpa);
    try body.append(gpa, @intFromEnum(frame.class));
    try body.append(gpa, frame.kind);
    try putUv(gpa, &body, frame.channel);
    try body.appendSlice(gpa, frame.payload);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var len_bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &len_bytes, @intCast(body.items.len), .little);
    try out.appendSlice(gpa, &len_bytes);
    try out.appendSlice(gpa, body.items);
    return out.toOwnedSlice(gpa);
}

/// Incremental frame decoder over reassembled stream bytes.
pub const Decoder = struct {
    buf: std.ArrayList(u8) = .empty,

    pub const empty: Decoder = .{};

    pub fn deinit(self: *Decoder, gpa: Allocator) void {
        self.buf.deinit(gpa);
    }

    pub fn feed(self: *Decoder, gpa: Allocator, bytes: []const u8) !void {
        try self.buf.appendSlice(gpa, bytes);
    }

    pub const Decoded = struct {
        class: Class,
        kind: u8,
        channel: u64,
        /// Owned by the caller.
        payload: []u8,
    };

    pub fn next(self: *Decoder, gpa: Allocator) error{ Corrupt, OutOfMemory }!?Decoded {
        if (self.buf.items.len < 4) return null;
        const body_len = std.mem.readInt(u32, self.buf.items[0..4], .little);
        if (body_len > 64 << 20) return error.Corrupt; // sanity cap
        if (self.buf.items.len < 4 + body_len) return null;
        var cur: []const u8 = self.buf.items[4 .. 4 + body_len];
        if (cur.len < 2) return error.Corrupt;
        const class_raw = cur[0];
        const kind = cur[1];
        cur = cur[2..];
        if (class_raw > @intFromEnum(Class.feed)) return error.Corrupt;
        const class: Class = @enumFromInt(class_raw);
        const channel = try getUv(&cur);
        const payload = try gpa.dupe(u8, cur);
        errdefer gpa.free(payload);
        const consumed = 4 + body_len;
        const rest = self.buf.items.len - consumed;
        std.mem.copyForwards(u8, self.buf.items[0..rest], self.buf.items[consumed..]);
        self.buf.items.len = rest;
        return .{ .class = class, .kind = kind, .channel = channel, .payload = payload };
    }
};

// ── Sender-side class queue ─────────────────────────────────────────

/// The normative priority order with latest-wins feed coalescing.
/// Single-consumer (the session writer); producers enqueue on the main
/// thread — synchronization lives in the session, not here.
pub const Outbox = struct {
    control: std.ArrayList([]u8) = .empty,
    ops: std.ArrayList([]u8) = .empty,
    requests: std.ArrayList([]u8) = .empty,
    /// (channel, key) → encoded frame; replaced on re-publish.
    feeds: std.ArrayList(FeedSlot) = .empty,

    const FeedSlot = struct { channel: u64, key: u64, bytes: []u8 };

    pub const empty: Outbox = .{};

    pub fn deinit(self: *Outbox, gpa: Allocator) void {
        for (self.control.items) |b| gpa.free(b);
        self.control.deinit(gpa);
        for (self.ops.items) |b| gpa.free(b);
        self.ops.deinit(gpa);
        for (self.requests.items) |b| gpa.free(b);
        self.requests.deinit(gpa);
        for (self.feeds.items) |f| gpa.free(f.bytes);
        self.feeds.deinit(gpa);
    }

    pub fn push(self: *Outbox, gpa: Allocator, class: Class, encoded: []u8) !void {
        const list = switch (class) {
            .control => &self.control,
            .op => &self.ops,
            .request => &self.requests,
            .feed => unreachable, // use pushFeed
        };
        try list.append(gpa, encoded);
    }

    /// Latest-wins per (channel, key): a queued unsent publish for the
    /// same key is replaced, coalescing under backpressure.
    pub fn pushFeed(self: *Outbox, gpa: Allocator, channel: u64, key: u64, encoded: []u8) !void {
        for (self.feeds.items) |*slot| {
            if (slot.channel == channel and slot.key == key) {
                gpa.free(slot.bytes);
                slot.bytes = encoded;
                return;
            }
        }
        try self.feeds.append(gpa, .{ .channel = channel, .key = key, .bytes = encoded });
    }

    /// Highest-priority queued frame (caller owns), or null.
    pub fn pop(self: *Outbox) ?[]u8 {
        if (self.control.items.len > 0) return self.control.orderedRemove(0);
        if (self.ops.items.len > 0) return self.ops.orderedRemove(0);
        if (self.requests.items.len > 0) return self.requests.orderedRemove(0);
        if (self.feeds.items.len > 0) {
            const slot = self.feeds.orderedRemove(0);
            return slot.bytes;
        }
        return null;
    }

    pub fn isEmpty(self: *const Outbox) bool {
        return self.control.items.len == 0 and self.ops.items.len == 0 and
            self.requests.items.len == 0 and self.feeds.items.len == 0;
    }
};

// ── Conformance tests (the executable spec) ─────────────────────────

const t = std.testing;

test "wire: frame round trip, split delivery, corrupt class rejected" {
    const gpa = t.allocator;
    const f = try encode(gpa, .{ .class = .op, .kind = @intFromEnum(OpKind.batch), .channel = 7, .payload = "stemma-bytes" });
    defer gpa.free(f);

    var d: Decoder = .empty;
    defer d.deinit(gpa);
    try d.feed(gpa, f[0..5]);
    try t.expectEqual(@as(?Decoder.Decoded, null), try d.next(gpa));
    try d.feed(gpa, f[5..]);
    const got = (try d.next(gpa)).?;
    defer gpa.free(got.payload);
    try t.expectEqual(Class.op, got.class);
    try t.expectEqual(@as(u64, 7), got.channel);
    try t.expectEqualStrings("stemma-bytes", got.payload);

    // A frame with an unknown class is a spec bug, not a judgment call.
    var bad: std.ArrayList(u8) = .empty;
    defer bad.deinit(gpa);
    try bad.appendSlice(gpa, &.{ 3, 0, 0, 0, 9, 0, 0 });
    try d.feed(gpa, bad.items);
    try t.expectError(error.Corrupt, d.next(gpa));
}

test "wire: portable identity anchor round trips and rejects truncation" {
    const gpa = t.allocator;
    var encoded: std.ArrayList(u8) = .empty;
    defer encoded.deinit(gpa);
    try putAnchor(gpa, &encoded, .{ .agent = "alice", .seq = 42, .side = 1 });

    var cur: []const u8 = encoded.items;
    const decoded = try getAnchor(&cur);
    try t.expectEqualStrings("alice", decoded.agent);
    try t.expectEqual(@as(u64, 42), decoded.seq);
    try t.expectEqual(@as(u8, 1), decoded.side);
    try t.expectEqual(@as(usize, 0), cur.len);

    var truncated: []const u8 = encoded.items[0 .. encoded.items.len - 1];
    try t.expectError(error.Corrupt, getAnchor(&truncated));
}

test "wire: outbox priority order and feed coalescing" {
    const gpa = t.allocator;
    var q: Outbox = .empty;
    defer q.deinit(gpa);

    try q.pushFeed(gpa, 1, 42, try gpa.dupe(u8, "presence-old"));
    try q.push(gpa, .request, try gpa.dupe(u8, "req"));
    try q.push(gpa, .op, try gpa.dupe(u8, "op1"));
    try q.pushFeed(gpa, 1, 42, try gpa.dupe(u8, "presence-new")); // coalesces
    try q.pushFeed(gpa, 1, 43, try gpa.dupe(u8, "other-key"));
    try q.push(gpa, .control, try gpa.dupe(u8, "hb"));

    const order = [_][]const u8{ "hb", "op1", "req", "presence-new", "other-key" };
    for (order) |want| {
        const got = q.pop().?;
        defer gpa.free(got);
        try t.expectEqualStrings(want, got);
    }
    try t.expect(q.isEmpty());
}
