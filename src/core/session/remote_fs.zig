//! The blob/base request protocol (channel 3 of a collab quad): the
//! host-side `BlobServer` (on-disk file reads) and `serveBase` (a
//! compacted document's pristine base), plus the client-side
//! `RemoteFile` (read-only hole rope over a remote blob) and `RemoteFs`
//! (async `.peer` filesystem request/reply correlation).

const std = @import("std");
const Allocator = std.mem.Allocator;
const linux = std.os.linux;

const wire = @import("weft_wire");
const task = @import("../task.zig");
const Document = @import("../Document.zig");
const Session = @import("Session.zig");
const requests = @import("requests.zig");

// ── Request class: the blob channel (partial checkout) ──────────────
// Channel 3. Calls: payload = uv id | u8 op | body. op 0 = stat
// (reply: uv size), op 1 = read (body: uv offset | uv len; reply:
// bytes). Replies mirror the id. The agent serves reads with pread —
// the file is never loaded into memory.

pub const blob_channel: u64 = 3;
/// `stat`/`read` serve the on-disk file (read-only viewer). `base_open`
/// and `base_read` serve a compacted document's PRISTINE BASE — stable
/// under concurrent edits, which is what editable partial checkout
/// realizes against (stemma hole-bases).
pub const BlobOp = enum(u8) { stat = 0, read = 1, base_open = 2, base_read = 3 };

pub const BlobServer = struct {
    fd: i32,

    pub fn openPath(path: []const u8) !BlobServer {
        var buf: [512]u8 = undefined;
        if (path.len >= buf.len) return error.PathTooLong;
        @memcpy(buf[0..path.len], path);
        buf[path.len] = 0;
        const rc = linux.open(buf[0..path.len :0], .{ .ACCMODE = .RDONLY }, 0);
        if (linux.errno(rc) != .SUCCESS) return error.OpenFailed;
        return .{ .fd = @intCast(rc) };
    }

    pub fn close(self: *BlobServer) void {
        _ = linux.close(self.fd);
    }

    fn size(self: *BlobServer) u64 {
        // lseek(END) — no Stat struct churn.
        const rc = linux.lseek(self.fd, 0, linux.SEEK.END);
        return if (linux.errno(rc) == .SUCCESS) rc else 0;
    }

    fn read(self: *BlobServer, buf: []u8, offset: u64) usize {
        const rc = linux.pread(self.fd, buf.ptr, buf.len, @intCast(offset));
        return if (linux.errno(rc) == .SUCCESS) rc else 0;
    }

    /// Handle one call payload; returns the reply payload (caller owns).
    pub fn handle(self: *BlobServer, gpa: Allocator, payload: []const u8) ![]u8 {
        var cur: []const u8 = payload;
        const id = try wire.getUv(&cur);
        if (cur.len < 1) return error.Corrupt;
        const op: BlobOp = if (cur[0] <= 1) @enumFromInt(cur[0]) else return error.Corrupt;
        cur = cur[1..];
        var reply: std.ArrayList(u8) = .empty;
        errdefer reply.deinit(gpa);
        try wire.putUv(gpa, &reply, id);
        switch (op) {
            .stat => try wire.putUv(gpa, &reply, self.size()),
            .read => {
                const offset = try wire.getUv(&cur);
                const len = @min(try wire.getUv(&cur), 4 << 20);
                const buf = try gpa.alloc(u8, @intCast(len));
                defer gpa.free(buf);
                const n = self.read(buf, offset);
                try reply.appendSlice(gpa, buf[0..n]);
            },
            .base_open, .base_read => return error.Corrupt, // served by the document, not the file
        }
        return reply.toOwnedSlice(gpa);
    }
};

/// Client-side partial checkout: a hole rope over the remote blob,
/// viewport-driven materialization with readahead, and a
/// content-addressed cross-session chunk cache (chunks stored by
/// SHA-256 learned at fetch; a per-file manifest replays cached chunks
/// on reopen). Read-only: editable holes need stemma's hole-base
/// proposal (doc/stemma-holes-proposal.md).
pub const RemoteFile = struct {
    gpa: Allocator,
    rope: @import("stemma").Rope,
    /// Calls awaiting a reply, each under its deadline.
    inflight: requests.Inflight(Span) = .{},
    known_size: u64 = 0,
    cache_dir: ?[]u8 = null,
    manifest_path: ?[]u8 = null,

    pub const chunk = 64 * 1024;

    /// The byte range a call asks for; a zero `len` is a stat.
    pub const Span = struct { offset: u64, len: u64 };

    pub fn init(gpa: Allocator) RemoteFile {
        return .{ .gpa = gpa, .rope = .empty };
    }

    pub fn deinit(self: *RemoteFile) void {
        self.rope.deinit(self.gpa);
        self.inflight.deinit(self.gpa);
        if (self.cache_dir) |d| self.gpa.free(d);
        if (self.manifest_path) |m| self.gpa.free(m);
    }

    /// How long a blob call waits for its reply before it is failed.
    pub fn setTimeout(self: *RemoteFile, ns: u64) void {
        self.inflight.timeout_ns = ns;
    }

    /// This call will not be answered (a peer `err`, or its deadline
    /// passed). The span stays a hole; the viewport asks again if it
    /// still wants it.
    pub fn onFailure(self: *RemoteFile, id: u64) void {
        _ = self.inflight.settle(id);
    }

    /// Optional cross-session cache under `dir` for remote `name`.
    pub fn enableCache(self: *RemoteFile, dir: []const u8, name: []const u8) !void {
        var h: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(name, &h, .{});
        self.cache_dir = try self.gpa.dupe(u8, dir);
        self.manifest_path = try std.fmt.allocPrint(self.gpa, "{s}/manifest-{x}", .{ dir, h[0..8].* });
    }

    pub fn postStat(self: *RemoteFile, session: *Session) !void {
        var p: std.ArrayList(u8) = .empty;
        defer p.deinit(self.gpa);
        const id = try self.inflight.issue(self.gpa, .{ .offset = 0, .len = 0 });
        try wire.putUv(self.gpa, &p, id);
        try p.append(self.gpa, @intFromEnum(BlobOp.stat));
        try session.post(.request, @intFromEnum(wire.RequestKind.call), blob_channel, p.items);
    }

    /// Request materialization of `range` (chunk-aligned + readahead),
    /// skipping realized and already-inflight spans; cache hits realize
    /// immediately without a network round trip.
    pub fn want(self: *RemoteFile, session: *Session, start: u64, end: u64) !void {
        if (self.known_size == 0) return;
        const gpa = self.gpa;
        var at = (start / chunk) * chunk;
        const capped = @min(end + chunk, self.known_size); // readahead
        while (at < capped) : (at += chunk) {
            const clen = @min(chunk, self.known_size - at);
            if (clen == 0) break;
            if (self.rope.isRealized(.{ .start = @intCast(at), .end = @intCast(at + clen) })) continue;
            var skip = false;
            var it = self.inflight.pending();
            while (it.next()) |e| {
                if (e.ctx.offset == at) {
                    skip = true;
                    break;
                }
            }
            if (skip) continue;
            if (try self.tryCache(at, clen)) continue;
            var p: std.ArrayList(u8) = .empty;
            defer p.deinit(gpa);
            const id = try self.inflight.issue(gpa, .{ .offset = at, .len = clen });
            try wire.putUv(gpa, &p, id);
            try p.append(gpa, @intFromEnum(BlobOp.read));
            try wire.putUv(gpa, &p, at);
            try wire.putUv(gpa, &p, clen);
            try session.post(.request, @intFromEnum(wire.RequestKind.call), blob_channel, p.items);
        }
    }

    /// Fold a blob-channel reply. Returns true when content changed.
    pub fn onReply(self: *RemoteFile, payload: []const u8) !bool {
        const gpa = self.gpa;
        var cur: []const u8 = payload;
        const id = try wire.getUv(&cur);
        const span = self.inflight.settle(id) orelse return false;
        if (span.len == 0) {
            // stat reply: grow (or create) the hole rope.
            const sz = try wire.getUv(&cur);
            if (sz > self.known_size) {
                const grow = sz - self.known_size;
                var tail = try @import("stemma").Rope.fromUnrealized(gpa, @intCast(grow));
                errdefer tail.deinit(gpa);
                try self.rope.append(gpa, &tail);
                self.known_size = sz;
                return true;
            }
            return false;
        }
        if (cur.len == 0) return false;
        const n = @min(cur.len, span.len);
        try self.rope.realize(gpa, @intCast(span.offset), cur[0..n]);
        self.storeCache(span.offset, cur[0..n]);
        return true;
    }

    fn cachePathFor(self: *RemoteFile, hash: [32]u8, buf: []u8) ?[]const u8 {
        const dir = self.cache_dir orelse return null;
        return std.fmt.bufPrint(buf, "{s}/{x}", .{ dir, hash }) catch null;
    }

    fn storeCache(self: *RemoteFile, offset: u64, bytes: []const u8) void {
        const gpa = self.gpa;
        if (self.cache_dir == null) return;
        var h: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(bytes, &h, .{});
        var pbuf: [640]u8 = undefined;
        const p = self.cachePathFor(h, &pbuf) orelse return;
        const file = @import("../file.zig");
        var threaded: std.Io.Threaded = .init(gpa, .{});
        defer threaded.deinit();
        const io = threaded.io();
        std.Io.Dir.cwd().writeFile(io, .{ .sub_path = p, .data = bytes }) catch return;
        _ = file;
        // Append to the manifest: offset len hash\n
        if (self.manifest_path) |mp| {
            const line = std.fmt.allocPrint(gpa, "{d} {d} {x}\n", .{ offset, bytes.len, h }) catch return;
            defer gpa.free(line);
            var f = std.Io.Dir.cwd().createFile(io, mp, .{ .truncate = false }) catch return;
            defer f.close(io);
            const end = f.length(io) catch 0;
            f.writePositionalAll(io, line, end) catch return;
        }
    }

    /// On reopen: replay manifest entries whose chunks are cached.
    pub fn replayCache(self: *RemoteFile) !usize {
        const gpa = self.gpa;
        const mp = self.manifest_path orelse return 0;
        const file = @import("../file.zig");
        const data = file.readAlloc(gpa, mp) catch return 0;
        defer gpa.free(data);
        var restored: usize = 0;
        var lines = std.mem.tokenizeScalar(u8, data, '\n');
        while (lines.next()) |line| {
            var parts = std.mem.tokenizeScalar(u8, line, ' ');
            const off = std.fmt.parseInt(u64, parts.next() orelse continue, 10) catch continue;
            const len = std.fmt.parseInt(u64, parts.next() orelse continue, 10) catch continue;
            _ = parts.next() orelse continue;
            _ = len;
            if (try self.tryCacheLine(line, off)) restored += 1;
        }
        return restored;
    }

    fn tryCacheLine(self: *RemoteFile, line: []const u8, offset: u64) !bool {
        var parts = std.mem.tokenizeScalar(u8, line, ' ');
        _ = parts.next();
        const len_s = parts.next() orelse return false;
        const hash_s = parts.next() orelse return false;
        const len = std.fmt.parseInt(u64, len_s, 10) catch return false;
        return self.realizeFromCacheHex(offset, len, hash_s);
    }

    fn tryCache(self: *RemoteFile, offset: u64, len: u64) !bool {
        // Without a manifest lookup by offset we only use the cache via
        // replayCache at open; live fetches always hit the wire.
        _ = self;
        _ = offset;
        _ = len;
        return false;
    }

    fn realizeFromCacheHex(self: *RemoteFile, offset: u64, len: u64, hash_hex: []const u8) !bool {
        const gpa = self.gpa;
        const dir = self.cache_dir orelse return false;
        if (offset + len > self.known_size) return false;
        if (self.rope.isRealized(.{ .start = @intCast(offset), .end = @intCast(offset + len) })) return false;
        var pbuf: [640]u8 = undefined;
        const p = std.fmt.bufPrint(&pbuf, "{s}/{s}", .{ dir, hash_hex }) catch return false;
        const file = @import("../file.zig");
        const bytes = file.readAlloc(gpa, p) catch return false;
        defer gpa.free(bytes);
        if (bytes.len != len) return false;
        try self.rope.realize(gpa, @intCast(offset), bytes);
        return true;
    }
};

/// Client-side `.peer` filesystem: post LIST/READ/WRITE/STAT requests to a host
/// over the collab request channel and collect the replies. Each reply is a
/// `peer_fs` response (status + payload); the caller drains completed ones (a
/// dired-style plugin folds a listing into a buffer). Async by construction —
/// no blocking round-trip on the frame thread (round-2 D1).
pub const RemoteFs = struct {
    gpa: Allocator,
    /// Calls awaiting a reply, each under its deadline.
    inflight: requests.Inflight(void) = .{},
    /// Settled calls by id, until the caller takes them.
    settled: std.AutoHashMapUnmanaged(u64, Outcome) = .empty,

    /// What a call came back as: the peer's response bytes, or the peer
    /// saying it could not serve it.
    const Outcome = union(enum) { reply: []u8, failed };

    pub fn init(gpa: Allocator) RemoteFs {
        return .{ .gpa = gpa };
    }
    pub fn deinit(self: *RemoteFs) void {
        var it = self.settled.valueIterator();
        while (it.next()) |v| switch (v.*) {
            .reply => |bytes| self.gpa.free(bytes),
            .failed => {},
        };
        self.settled.deinit(self.gpa);
        self.inflight.deinit(self.gpa);
    }

    /// How long a call waits for its reply before `take` fails it.
    pub fn setTimeout(self: *RemoteFs, ns: u64) void {
        self.inflight.timeout_ns = ns;
    }

    /// Post a `peer_fs`-encoded request on `base+3`; returns the call id the
    /// reply will mirror. `req` is from `peer_fs.encodeList/Read/Write/Stat`.
    pub fn request(self: *RemoteFs, session: *Session, base: u64, req: []const u8) !u64 {
        const id = try self.inflight.issue(self.gpa, {});
        var p: std.ArrayList(u8) = .empty;
        defer p.deinit(self.gpa);
        try wire.putUv(self.gpa, &p, id);
        try p.appendSlice(self.gpa, req);
        try session.post(.request, @intFromEnum(wire.RequestKind.fs_call), base + 3, p.items);
        return id;
    }

    /// A reply frame arrived (`uv id | response`): store the response by id.
    pub fn onReply(self: *RemoteFs, gpa: Allocator, payload: []const u8) !void {
        var cur: []const u8 = payload;
        const id = wire.getUv(&cur) catch return;
        const owned = try gpa.dupe(u8, cur);
        errdefer gpa.free(owned);
        try self.put(gpa, id, .{ .reply = owned });
    }

    /// The peer cannot serve `id` (an `fs_err` frame). The caller takes
    /// the failure now rather than waiting out its deadline.
    pub fn onFailure(self: *RemoteFs, gpa: Allocator, id: u64) void {
        self.put(gpa, id, .failed) catch {};
    }

    fn put(self: *RemoteFs, gpa: Allocator, id: u64, outcome: Outcome) !void {
        const gop = try self.settled.getOrPut(gpa, id);
        if (gop.found_existing) switch (gop.value_ptr.*) {
            .reply => |bytes| gpa.free(bytes),
            .failed => {},
        };
        gop.value_ptr.* = outcome;
        _ = self.inflight.settle(id);
    }

    /// Take the completed response for `id` (owned; caller frees), or null
    /// while it is still in flight. A peer that refused the call, or a
    /// deadline that passed, is an error — never an endless wait.
    pub fn take(self: *RemoteFs, id: u64) requests.Error!?[]u8 {
        if (self.settled.fetchRemove(id)) |kv| switch (kv.value) {
            .reply => |bytes| return bytes,
            .failed => return error.RequestFailed,
        };
        if (self.inflight.timedOut(id, task.nowNs())) return error.RequestTimeout;
        return null;
    }
};

// ── Editable partial checkout (stemma hole-bases): host serving side ─
// Host: a compacted document's base is immutable under edits; ops
// base_open (reply: base_version + agent watermarks + a chunk table
// snapped to scalar boundaries) and base_read (pristine base bytes)
// serve it. The client side (PartialDoc) lives in session/partial.zig.

/// Serve a base_open / base_read call from `doc`'s compacted base.
/// Reply: uv id | u8 ok, then op-specific body. A doc that is not
/// (meaningfully) compacted answers ok=0 (client falls back to full
/// sync).
///
/// An earlier W7a draft added a server-side `openPartialCompatible` gate
/// here, working around a stemma v0.5.0 bug where `ObjectDoc.openPartial`
/// rejected any REAL (edited-then-compacted, not just the degenerate
/// founder) compaction boundary. Fixed upstream in stemma v0.5.1
/// (`build.zig.zon`'s pin): `openPartial`'s accepted range is now
/// `head.seq <= seq_base` (not `==`), covering both regimes — see
/// `ObjectDoc.openPartial`'s own doc comment for the two cases and why
/// `head.seq <= seq_base` holds. That invariant holds for ANY `base_
/// version`/watermark pair `Document` itself can produce, by
/// construction: `init` mints the founder via `openFromContent`
/// (`head.seq == seq_base`, trivially) and `compact` always raises the
/// compacting agent's `seq_base` to `stable_token`'s seq + 1 (`head.seq
/// == seq_base - 1`, i.e. `<`) — there is no path in this file that could
/// hand `openPartial` a self-inconsistent pair, so a redundant recheck
/// here would only ever assert something `serveBase` already guarantees.
/// `openPartial` itself validates loudly on genuine inconsistency (an
/// `assert`, not a silent wrong-identity mint — see its doc comment) — the
/// right place for that defense is centrally in stemma, once, not
/// duplicated at every caller. Removed rather than loosened.
///
/// W7a mechanical change (doc/substrate.md §2's "serveBase's TextDoc-only
/// base_bytes read"): `TextDoc` had one whole-document `base_bytes`
/// field; `ObjectDoc` compacts PER OBJECT (`text_bases`, keyed by the
/// object's `ObjId`) — this now reads `doc.doc.text_bases.get(doc.body)`
/// instead. The "not compacted" gate changed with it, honestly, not just
/// mechanically: under `TextDoc`, `base_version.len == 0` meant "never
/// compacted" (a fresh document has none). Under `Document`'s `ObjectDoc`
/// substrate, EVERY document has a non-empty `base_version` from
/// `init` onward (the founder text-object-creation event — see
/// `Document.init`'s doc comment), so that check would now say "ok=1"
/// for a perfectly ordinary, never-explicitly-compacted document with a
/// trivial (possibly zero-byte) base — exactly the case this gate exists
/// to say "no, fall back to full sync" for. The honest replacement: is
/// there any REAL content in the base worth serving — `text_bases[body].
/// bytes.len > 0`. True for a bulk-loaded file (the whole content IS the
/// base from `adoptContent`) and for a document `compact`ed after real
/// edits (the base is rebuilt to hold everything up to the stable
/// point); false for a plain `init`ed, never-compacted document (the
/// founder's base is the empty string) and, same as before, for a
/// document with any still-unrealized span (`!doc.baseRealized()`).
pub fn serveBase(gpa: Allocator, doc: *Document, payload: []const u8) ![]u8 {
    var cur: []const u8 = payload;
    const id = try wire.getUv(&cur);
    if (cur.len == 0) return error.Corrupt;
    const op = std.enums.fromInt(BlobOp, cur[0]) orelse return error.Corrupt;
    cur = cur[1..];
    var reply: std.ArrayList(u8) = .empty;
    errdefer reply.deinit(gpa);
    try wire.putUv(gpa, &reply, id);

    const base_version = doc.doc.base_version;
    const text_base = doc.doc.text_bases.get(doc.body);
    const base_bytes = if (text_base) |tb| tb.bytes else &.{};
    if (base_bytes.len == 0 or !doc.baseRealized()) {
        try reply.append(gpa, 0);
        return reply.toOwnedSlice(gpa);
    }
    try reply.append(gpa, 1);
    switch (op) {
        .base_open => {
            try wire.putUv(gpa, &reply, base_version.len);
            try reply.appendSlice(gpa, base_version);
            const wm = try doc.agentWatermarks(gpa);
            defer gpa.free(wm);
            try wire.putUv(gpa, &reply, wm.len);
            for (wm) |w| {
                try wire.putUv(gpa, &reply, w.name.len);
                try reply.appendSlice(gpa, w.name);
                try wire.putUv(gpa, &reply, w.seq_base);
            }
            // Chunk table: ~64K spans snapped to UTF-8 boundaries, each
            // with its scalar count (one scan of the base, once per
            // open).
            var counts: std.ArrayList([2]u64) = .empty;
            defer counts.deinit(gpa);
            var at: usize = 0;
            while (at < base_bytes.len) {
                var end = @min(at + RemoteFile.chunk, base_bytes.len);
                while (end > at and end < base_bytes.len and base_bytes[end] & 0xC0 == 0x80) end -= 1;
                const scalars = std.unicode.utf8CountCodepoints(base_bytes[at..end]) catch return error.Corrupt;
                try counts.append(gpa, .{ end - at, scalars });
                at = end;
            }
            try wire.putUv(gpa, &reply, counts.items.len);
            for (counts.items) |c| {
                try wire.putUv(gpa, &reply, c[0]);
                try wire.putUv(gpa, &reply, c[1]);
            }
        },
        .base_read => {
            const offset = try wire.getUv(&cur);
            const len = @min(try wire.getUv(&cur), 4 << 20);
            if (offset > base_bytes.len) return error.Corrupt;
            const end = @min(base_bytes.len, offset + len);
            try reply.appendSlice(gpa, base_bytes[@intCast(offset)..@intCast(end)]);
        },
        else => return error.Corrupt,
    }
    return reply.toOwnedSlice(gpa);
}
