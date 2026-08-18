//! peer_fs — the `.peer` filesystem wire protocol + server (design Part D).
//!
//! A collab HOST serves a shared project root to a connected client: LIST /
//! READ / WRITE / STAT, confined by `rooted_fs` (openat2, so a client can never
//! escape the shared root), and gated by a per-connection `Grant` that defaults
//! to DENY. This addresses the round-2 findings that the old blob channel had
//! no arbitrary-path/list/write ops, no confinement, and no write precondition:
//!
//! - **Grant** (round-2 D5): a post-handshake access level (`none`/`read`/
//!   `read_write`). Absent ⇒ deny, so a random client gets nothing; same-project
//!   collab grants the tree. It is NOT the doc-level `Access` — it is fs-scoped.
//! - **Confinement** (round-2 D3): every path goes through `rooted_fs`, so `..`
//!   / absolute / symlink escapes are refused in the kernel.
//! - **Write precondition** (round-2 D6): WRITE carries the content token the
//!   client last READ; the server refuses (`stale`) if the file changed since,
//!   so concurrent writers don't clobber. STAT/READ return the token.
//!
//! This file is pure protocol + a server handler — transport-agnostic (it rides
//! a session fs-channel), so it is unit-tested in-process with no real network.

const std = @import("std");
const Allocator = std.mem.Allocator;
const RootedFs = @import("rooted_fs.zig").RootedFs;

pub const Op = enum(u8) { list = 0, read = 1, write = 2, stat = 3, _ };
pub const Status = enum(u8) { ok = 0, denied = 1, not_found = 2, confined = 3, stale = 4, io = 5, bad = 6 };

/// fs-scoped access a host grants a peer for the shared root. Distinct from the
/// document-level session `Access`. Default `none` (deny).
pub const Access = enum(u8) { none = 0, read = 1, read_write = 2 };
pub const Grant = struct { access: Access = .none };

/// An opaque content token (a hash of the file's bytes), returned by READ/STAT
/// and echoed by WRITE as its precondition.
pub const Token = [8]u8;

fn tokenOf(bytes: []const u8) Token {
    const h = std.hash.Wyhash.hash(0, bytes);
    var out: Token = undefined;
    std.mem.writeInt(u64, &out, h, .little);
    return out;
}

// ── uvarint framing (self-contained; same LEB128 style as kv) ──
fn putUv(gpa: Allocator, out: *std.ArrayList(u8), value: u64) Allocator.Error!void {
    var x = value;
    while (true) {
        const b: u8 = @intCast(x & 0x7f);
        x >>= 7;
        if (x == 0) return out.append(gpa, b);
        try out.append(gpa, b | 0x80);
    }
}
fn getUv(cur: *[]const u8) ?u64 {
    var shift: u6 = 0;
    var v: u64 = 0;
    while (cur.len > 0) {
        const b = cur.*[0];
        cur.* = cur.*[1..];
        v |= @as(u64, b & 0x7f) << shift;
        if (b & 0x80 == 0) return v;
        if (shift >= 57) return null;
        shift += 7;
    }
    return null;
}
fn putBytes(gpa: Allocator, out: *std.ArrayList(u8), b: []const u8) Allocator.Error!void {
    try putUv(gpa, out, b.len);
    try out.appendSlice(gpa, b);
}
fn getBytes(cur: *[]const u8) ?[]const u8 {
    const n = getUv(cur) orelse return null;
    if (n > cur.len) return null;
    const out = cur.*[0..@intCast(n)];
    cur.* = cur.*[@intCast(n)..];
    return out;
}

// ── Client-side request encoders (owned; caller frees) ──
pub fn encodeList(gpa: Allocator, path: []const u8) Allocator.Error![]u8 {
    return encodeSimple(gpa, .list, path);
}
pub fn encodeRead(gpa: Allocator, path: []const u8) Allocator.Error![]u8 {
    return encodeSimple(gpa, .read, path);
}
pub fn encodeStat(gpa: Allocator, path: []const u8) Allocator.Error![]u8 {
    return encodeSimple(gpa, .stat, path);
}
fn encodeSimple(gpa: Allocator, op: Op, path: []const u8) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.append(gpa, @intFromEnum(op));
    try putBytes(gpa, &out, path);
    return out.toOwnedSlice(gpa);
}
pub fn encodeWrite(gpa: Allocator, path: []const u8, token: Token, data: []const u8) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.append(gpa, @intFromEnum(Op.write));
    try putBytes(gpa, &out, path);
    try putBytes(gpa, &out, &token);
    try putBytes(gpa, &out, data);
    return out.toOwnedSlice(gpa);
}

/// Client-side response: (status, payload). payload is the listing/bytes for
/// LIST/READ, or the token for STAT/WRITE (borrowed from `resp`).
pub const Response = struct { status: Status, payload: []const u8 };
pub fn decodeResponse(resp: []const u8) ?Response {
    if (resp.len == 0) return null;
    const status: Status = @enumFromInt(resp[0]);
    var cur = resp[1..];
    const payload = getBytes(&cur) orelse return null;
    return .{ .status = status, .payload = payload };
}

// ── Server: handle one request against `fs` under `grant` → response bytes ──

/// Confined path buffer: rooted_fs needs a NUL-terminated relative path.
fn dupeZ(gpa: Allocator, path: []const u8) Allocator.Error![:0]u8 {
    return gpa.dupeZ(u8, path);
}

fn reply(gpa: Allocator, status: Status, payload: []const u8) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.append(gpa, @intFromEnum(status));
    try putBytes(gpa, &out, payload);
    return out.toOwnedSlice(gpa);
}

fn statusOf(e: anyerror) Status {
    return switch (e) {
        error.Confined => .confined,
        error.NotFound => .not_found,
        error.Stale => .stale,
        error.OutOfMemory => .io,
        else => .io,
    };
}

/// Handle one wire request. Pure over the confined `fs` + the `grant`; returns
/// an owned response the caller writes back to the peer. Never touches anything
/// outside the shared root, and never acts beyond the grant.
pub fn handle(gpa: Allocator, fs: *const RootedFs, grant: Grant, req: []const u8) Allocator.Error![]u8 {
    if (req.len == 0) return reply(gpa, .bad, "");
    const op: Op = @enumFromInt(req[0]);
    var cur = req[1..];
    const path = getBytes(&cur) orelse return reply(gpa, .bad, "");
    const pz = try dupeZ(gpa, path);
    defer gpa.free(pz);

    switch (op) {
        .list => {
            if (@intFromEnum(grant.access) < @intFromEnum(Access.read)) return reply(gpa, .denied, "");
            const listing = fs.list(gpa, pz.ptr) catch |e| return reply(gpa, statusOf(e), "");
            defer gpa.free(listing);
            return reply(gpa, .ok, listing);
        },
        .read => {
            if (@intFromEnum(grant.access) < @intFromEnum(Access.read)) return reply(gpa, .denied, "");
            const bytes = fs.read(gpa, pz.ptr) catch |e| return reply(gpa, statusOf(e), "");
            defer gpa.free(bytes);
            return reply(gpa, .ok, bytes);
        },
        .stat => {
            if (@intFromEnum(grant.access) < @intFromEnum(Access.read)) return reply(gpa, .denied, "");
            const bytes = fs.read(gpa, pz.ptr) catch |e| return reply(gpa, statusOf(e), "");
            defer gpa.free(bytes);
            const tok = tokenOf(bytes);
            return reply(gpa, .ok, &tok);
        },
        .write => {
            if (@intFromEnum(grant.access) < @intFromEnum(Access.read_write)) return reply(gpa, .denied, "");
            const token = getBytes(&cur) orelse return reply(gpa, .bad, "");
            const data = getBytes(&cur) orelse return reply(gpa, .bad, "");
            if (token.len != @sizeOf(Token)) return reply(gpa, .bad, "");
            // Precondition: the file must match the token the client last read.
            // A missing file matches the zero token (a fresh create).
            const cur_bytes = fs.read(gpa, pz.ptr) catch |e| switch (e) {
                error.NotFound => &[_]u8{},
                else => return reply(gpa, statusOf(e), ""),
            };
            const owns = cur_bytes.len != 0;
            defer if (owns) gpa.free(cur_bytes);
            const cur_tok = tokenOf(cur_bytes);
            if (!std.mem.eql(u8, token, &cur_tok)) return reply(gpa, .stale, "");
            fs.write(pz.ptr, data) catch |e| return reply(gpa, statusOf(e), "");
            const new_tok = tokenOf(data);
            return reply(gpa, .ok, &new_tok);
        },
        _ => return reply(gpa, .bad, ""),
    }
}

// ── tests ───────────────────────────────────────────────────────────

const t = std.testing;
const linux = std.os.linux;

fn tmpRoot(buf: []u8) ![:0]const u8 {
    const path = try std.fmt.bufPrintZ(buf, "/tmp/weft-peerfs-{d}", .{linux.getpid()});
    _ = linux.rmdir(path.ptr);
    if (linux.errno(linux.mkdir(path.ptr, 0o755)) != .SUCCESS) return error.Mkdir;
    return path;
}

test "peer_fs: grant gates ops; list/read/write round-trip; stale write refused" {
    const gpa = t.allocator;
    var pbuf: [128]u8 = undefined;
    const root_path = try tmpRoot(&pbuf);
    var fs = try RootedFs.open(root_path.ptr);
    defer fs.close();
    defer {
        _ = linux.unlinkat(fs.root_fd, "a.txt", 0);
        _ = linux.unlinkat(fs.root_fd, "new.txt", 0);
        _ = linux.rmdir(root_path.ptr);
    }
    try fs.write("a.txt", "one");

    // Default deny: no grant → every op is denied.
    {
        const req = try encodeRead(gpa, "a.txt");
        defer gpa.free(req);
        const resp = try handle(gpa, &fs, .{}, req);
        defer gpa.free(resp);
        try t.expectEqual(Status.denied, decodeResponse(resp).?.status);
    }

    const ro: Grant = .{ .access = .read };
    const rw: Grant = .{ .access = .read_write };

    // READ under a read grant returns the bytes.
    {
        const req = try encodeRead(gpa, "a.txt");
        defer gpa.free(req);
        const resp = try handle(gpa, &fs, ro, req);
        defer gpa.free(resp);
        const d = decodeResponse(resp).?;
        try t.expectEqual(Status.ok, d.status);
        try t.expectEqualStrings("one", d.payload);
    }

    // LIST sees the file.
    {
        const req = try encodeList(gpa, ".");
        defer gpa.free(req);
        const resp = try handle(gpa, &fs, ro, req);
        defer gpa.free(resp);
        const d = decodeResponse(resp).?;
        try t.expectEqual(Status.ok, d.status);
        try t.expect(std.mem.indexOf(u8, d.payload, "a.txt") != null);
    }

    // WRITE needs read_write; under read it is denied.
    {
        const req = try encodeWrite(gpa, "a.txt", tokenOf("one"), "two");
        defer gpa.free(req);
        const resp = try handle(gpa, &fs, ro, req);
        defer gpa.free(resp);
        try t.expectEqual(Status.denied, decodeResponse(resp).?.status);
    }

    // WRITE with the correct precondition token succeeds and updates the file.
    {
        const req = try encodeWrite(gpa, "a.txt", tokenOf("one"), "two");
        defer gpa.free(req);
        const resp = try handle(gpa, &fs, rw, req);
        defer gpa.free(resp);
        try t.expectEqual(Status.ok, decodeResponse(resp).?.status);
        const got = try fs.read(gpa, "a.txt");
        defer gpa.free(got);
        try t.expectEqualStrings("two", got);
    }

    // A stale WRITE (wrong token — the file is now "two") is refused.
    {
        const req = try encodeWrite(gpa, "a.txt", tokenOf("one"), "three");
        defer gpa.free(req);
        const resp = try handle(gpa, &fs, rw, req);
        defer gpa.free(resp);
        try t.expectEqual(Status.stale, decodeResponse(resp).?.status);
    }

    // A confined-escape path is refused even with a grant.
    {
        const req = try encodeRead(gpa, "../etc/hostname");
        defer gpa.free(req);
        const resp = try handle(gpa, &fs, ro, req);
        defer gpa.free(resp);
        try t.expectEqual(Status.confined, decodeResponse(resp).?.status);
    }

    // Fresh create: WRITE a new file with the zero token (matches "absent").
    {
        const req = try encodeWrite(gpa, "new.txt", tokenOf(""), "fresh");
        defer gpa.free(req);
        const resp = try handle(gpa, &fs, rw, req);
        defer gpa.free(resp);
        try t.expectEqual(Status.ok, decodeResponse(resp).?.status);
    }
}

test {
    std.testing.refAllDecls(@This());
}
