//! peer_fs — the `.peer` filesystem wire protocol + server (design Part D).
//!
//! A collab HOST serves a shared project root to a connected client: LIST /
//! READ / WRITE / STAT, confined by `rooted_fs` (openat2, so a client can never
//! escape the shared root), and gated by a per-connection `Grant` that defaults
//! to DENY. This addresses the round-2 findings that the old blob channel had
//! no arbitrary-path/list/write ops, no confinement, and no write precondition:
//!
//! - **Grant** (round-2 D5, restructured per §13.5): NOT one access level but
//!   three separately granted EXPORT SURFACES — `hierarchy` (list a tree),
//!   `bytes` (read a file's content), `mutate` (write). `read`/`read_write`
//!   survive only as PRESETS over those surfaces. Every surface defaults to
//!   deny, so a random client gets nothing. It is NOT the doc-level `Access` —
//!   it is fs-scoped. An ungranted surface is refused as `error.NotGranted`,
//!   which the caller answers with `fs_err`/`.not_granted` (a served `denied`
//!   status would make "you may not" indistinguishable from "here is a
//!   listing you are allowed to see").
//! - **Confinement** (round-2 D3): every path goes through `rooted_fs`, so `..`
//!   / absolute / symlink escapes are refused in the semantic.
//! - **Write precondition** (round-2 D6): WRITE carries the content token the
//!   client last READ; the server refuses (`stale`) if the file changed since,
//!   so concurrent writers don't clobber. STAT/READ return the token.
//!
//! This file is pure protocol + a server handler — transport-agnostic (it rides
//! a session fs-channel), so it is unit-tested in-process with no real network.

const std = @import("std");
const Allocator = std.mem.Allocator;
const RootedFs = @import("rooted_fs.zig").RootedFs;

pub const Op = enum(u8) { list = 0, read = 1, write = 2, stat = 3, service = 4, _ };
/// `denied` is only ever sent by a host predating the export split, which
/// answered a refusal with a response instead of `fs_err`; kept so a client
/// still reads such a host correctly.
pub const Status = enum(u8) { ok = 0, denied = 1, not_found = 2, confined = 3, stale = 4, io = 5, bad = 6 };

/// The filesystem export surfaces, granted one by one. Listing a tree,
/// reading bytes out of it, and changing it are three different authorities
/// over one root — a peer that may see the shape of a project need not be
/// able to read its contents.
pub const Export = enum(u8) { hierarchy = 0, bytes = 1, mutate = 2 };

/// Which export surfaces a peer holds for the shared root. Distinct from the
/// document-level session `Access`; every surface defaults to deny.
pub const Grant = struct {
    hierarchy: bool = false,
    bytes: bool = false,
    mutate: bool = false,

    /// Presets, the only role-shaped thing left: a maximum a person picks
    /// from, never the unit authority is checked against.
    pub const none: Grant = .{};
    pub const read: Grant = .{ .hierarchy = true, .bytes = true };
    pub const read_write: Grant = .{ .hierarchy = true, .bytes = true, .mutate = true };

    pub fn allows(self: Grant, surface: Export) bool {
        return switch (surface) {
            .hierarchy => self.hierarchy,
            .bytes => self.bytes,
            .mutate => self.mutate,
        };
    }

    /// Whether any surface at all is granted — what an opaque `service`
    /// envelope needs before it may reach a semantic server (which splits
    /// the surfaces again on its own ops).
    pub fn any(self: Grant) bool {
        return self.hierarchy or self.bytes or self.mutate;
    }
};

/// Parse a selection: comma-separated surfaces (`hierarchy`, `bytes`,
/// `write`) and/or the legacy presets (`none`, `read`, `rw`). Null on an
/// unknown word — the caller falls back to `none` rather than guessing wide.
pub fn parseGrant(spec: []const u8) ?Grant {
    var out: Grant = .none;
    var it = std.mem.tokenizeScalar(u8, spec, ',');
    while (it.next()) |word| {
        const eql = std.mem.eql;
        if (eql(u8, word, "none")) continue;
        if (eql(u8, word, "hierarchy") or eql(u8, word, "list")) {
            out.hierarchy = true;
        } else if (eql(u8, word, "bytes")) {
            out.bytes = true;
        } else if (eql(u8, word, "write") or eql(u8, word, "mutate")) {
            out.mutate = true;
        } else if (eql(u8, word, "read")) {
            out.hierarchy = true;
            out.bytes = true;
        } else if (eql(u8, word, "rw") or eql(u8, word, "read_write")) {
            out = .read_write;
        } else return null;
    }
    return out;
}

/// Which export surface an op draws on. Null for `service`, whose surfaces
/// are the semantic server's own ops, not this envelope's.
pub fn exportOf(op: Op) ?Export {
    return switch (op) {
        .list => .hierarchy,
        .read, .stat => .bytes,
        .write => .mutate,
        .service, _ => null,
    };
}

/// The request asks for a surface this peer was not granted. Answered with
/// `fs_err`, not a response — see the module doc.
pub const Refusal = error{NotGranted};

/// Optional protocol extension owned outside core. The encrypted peer channel
/// transports opaque bounded bytes; app composition may install a semantic
/// filesystem server, while core remains unaware of providers, handles, or
/// target vocabularies.
pub const Service = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        handle: *const fn (*anyopaque, Allocator, []const u8) Allocator.Error![]u8,
    };

    pub fn init(pointer: anytype) Service {
        const Pointer = @TypeOf(pointer);
        const info = switch (@typeInfo(Pointer)) {
            .pointer => |value| value,
            else => @compileError("peer filesystem service requires a pointer"),
        };
        if (info.size != .one or info.is_const)
            @compileError("peer filesystem service requires a mutable single-item pointer");
        const Implementation = info.child;
        const Adapter = struct {
            fn handle(raw: *anyopaque, gpa: Allocator, request: []const u8) Allocator.Error![]u8 {
                const self: *Implementation = @ptrCast(@alignCast(raw));
                return self.handle(gpa, request);
            }
            const vtable: VTable = .{ .handle = @This().handle };
        };
        return .{ .context = pointer, .vtable = &Adapter.vtable };
    }

    pub fn handle(self: Service, gpa: Allocator, request: []const u8) Allocator.Error![]u8 {
        return self.vtable.handle(self.context, gpa, request);
    }
};

/// An opaque content token (a hash of the file's bytes), returned by READ/STAT
/// and echoed by WRITE as its precondition.
pub const Token = [8]u8;

/// The token `bytes` hash to — a client echoes the one it last READ, and
/// `tokenOf("")` is the precondition a path that does not exist matches.
pub fn tokenOf(bytes: []const u8) Token {
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
pub fn encodeService(gpa: Allocator, request: []const u8) Allocator.Error![]u8 {
    return encodeSimple(gpa, .service, request);
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
pub fn handle(gpa: Allocator, fs: *const RootedFs, grant: Grant, req: []const u8) (Allocator.Error || Refusal)![]u8 {
    return handleWithService(gpa, fs, grant, null, req);
}

pub fn handleWithService(gpa: Allocator, fs: *const RootedFs, grant: Grant, service: ?Service, req: []const u8) (Allocator.Error || Refusal)![]u8 {
    if (req.len == 0) return reply(gpa, .bad, "");
    const op: Op = @enumFromInt(req[0]);
    // The surface gate comes before the request is even parsed: an
    // ungranted export is refused on its own terms, not by what it asked.
    if (exportOf(op)) |surface| {
        if (!grant.allows(surface)) return error.NotGranted;
    } else if (!grant.any()) return error.NotGranted;
    var cur = req[1..];
    const path = getBytes(&cur) orelse return reply(gpa, .bad, "");
    const pz = try dupeZ(gpa, path);
    defer gpa.free(pz);

    switch (op) {
        .list => {
            const listing = fs.list(gpa, pz.ptr) catch |e| return reply(gpa, statusOf(e), "");
            defer gpa.free(listing);
            return reply(gpa, .ok, listing);
        },
        .read => {
            const bytes = fs.read(gpa, pz.ptr) catch |e| return reply(gpa, statusOf(e), "");
            defer gpa.free(bytes);
            return reply(gpa, .ok, bytes);
        },
        .stat => {
            const bytes = fs.read(gpa, pz.ptr) catch |e| return reply(gpa, statusOf(e), "");
            defer gpa.free(bytes);
            const tok = tokenOf(bytes);
            return reply(gpa, .ok, &tok);
        },
        .write => {
            const token = getBytes(&cur) orelse return reply(gpa, .bad, "");
            const data = getBytes(&cur) orelse return reply(gpa, .bad, "");
            if (token.len != @sizeOf(Token)) return reply(gpa, .bad, "");
            // Precondition: the file must match the token the client last read.
            // A missing file matches the token of empty content (a fresh create).
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
        .service => {
            const implementation = service orelse return reply(gpa, .bad, "");
            const response = implementation.handle(gpa, path) catch return reply(gpa, .io, "");
            defer gpa.free(response);
            return reply(gpa, .ok, response);
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

    // Default deny: no grant → every op is refused, out loud.
    {
        const req = try encodeRead(gpa, "a.txt");
        defer gpa.free(req);
        try t.expectError(error.NotGranted, handle(gpa, &fs, .none, req));
    }

    const ro: Grant = .read;
    const rw: Grant = .read_write;

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

    // WRITE needs the mutate surface; a read preset does not carry it.
    {
        const req = try encodeWrite(gpa, "a.txt", tokenOf("one"), "two");
        defer gpa.free(req);
        try t.expectError(error.NotGranted, handle(gpa, &fs, ro, req));
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

test "peer_fs: semantic service bytes share the granted encrypted channel" {
    const gpa = t.allocator;
    var pbuf: [128]u8 = undefined;
    const root_path = try tmpRoot(&pbuf);
    var fs = try RootedFs.open(root_path.ptr);
    defer fs.close();
    defer _ = linux.rmdir(root_path.ptr);

    var implementation = struct {
        calls: usize = 0,
        pub fn handle(self: *@This(), allocator: Allocator, request: []const u8) Allocator.Error![]u8 {
            self.calls += 1;
            const result = try allocator.alloc(u8, request.len + 1);
            result[0] = 0xaa;
            @memcpy(result[1..], request);
            return result;
        }
    }{};
    const service = Service.init(&implementation);
    const request = try encodeService(gpa, &[_]u8{ 0, 0xff, '\n' });
    defer gpa.free(request);

    try t.expectError(error.NotGranted, handleWithService(gpa, &fs, .none, service, request));
    try t.expectEqual(@as(usize, 0), implementation.calls);

    const response = try handleWithService(gpa, &fs, .read, service, request);
    defer gpa.free(response);
    const decoded = decodeResponse(response).?;
    try t.expectEqual(Status.ok, decoded.status);
    try t.expectEqualSlices(u8, &[_]u8{ 0xaa, 0, 0xff, '\n' }, decoded.payload);
    try t.expectEqual(@as(usize, 1), implementation.calls);
}

test "peer_fs: hierarchy, bytes, and mutate are three separately granted surfaces" {
    const gpa = t.allocator;
    var pbuf: [128]u8 = undefined;
    const root_path = try tmpRoot(&pbuf);
    var fs = try RootedFs.open(root_path.ptr);
    defer fs.close();
    defer {
        _ = linux.unlinkat(fs.root_fd, "a.txt", 0);
        _ = linux.rmdir(root_path.ptr);
    }
    try fs.write("a.txt", "one");

    const list = try encodeList(gpa, ".");
    defer gpa.free(list);
    const read = try encodeRead(gpa, "a.txt");
    defer gpa.free(read);
    const stat = try encodeStat(gpa, "a.txt");
    defer gpa.free(stat);
    const write = try encodeWrite(gpa, "a.txt", tokenOf("one"), "two");
    defer gpa.free(write);

    // Hierarchy only: the shape of the tree, never its contents.
    {
        const listing = try handle(gpa, &fs, .{ .hierarchy = true }, list);
        defer gpa.free(listing);
        try t.expectEqual(Status.ok, decodeResponse(listing).?.status);
        try t.expectError(error.NotGranted, handle(gpa, &fs, .{ .hierarchy = true }, read));
        try t.expectError(error.NotGranted, handle(gpa, &fs, .{ .hierarchy = true }, stat));
        try t.expectError(error.NotGranted, handle(gpa, &fs, .{ .hierarchy = true }, write));
    }

    // Bytes only: read a path you already know, without enumerating the tree.
    {
        const bytes = try handle(gpa, &fs, .{ .bytes = true }, read);
        defer gpa.free(bytes);
        try t.expectEqualStrings("one", decodeResponse(bytes).?.payload);
        const token = try handle(gpa, &fs, .{ .bytes = true }, stat);
        defer gpa.free(token);
        try t.expectEqual(Status.ok, decodeResponse(token).?.status);
        try t.expectError(error.NotGranted, handle(gpa, &fs, .{ .bytes = true }, list));
        try t.expectError(error.NotGranted, handle(gpa, &fs, .{ .bytes = true }, write));
    }

    // Mutate is its own surface, not the top of a ladder.
    {
        const applied = try handle(gpa, &fs, .{ .mutate = true }, write);
        defer gpa.free(applied);
        try t.expectEqual(Status.ok, decodeResponse(applied).?.status);
        try t.expectError(error.NotGranted, handle(gpa, &fs, .{ .mutate = true }, list));
        try t.expectError(error.NotGranted, handle(gpa, &fs, .{ .mutate = true }, read));
    }
}

test "peer_fs: a selection names surfaces; the presets are only shorthand" {
    try t.expectEqual(@as(?Grant, .none), parseGrant("none"));
    try t.expectEqual(@as(?Grant, .read), parseGrant("read"));
    try t.expectEqual(@as(?Grant, .read_write), parseGrant("rw"));
    try t.expectEqual(@as(?Grant, .{ .hierarchy = true }), parseGrant("hierarchy"));
    try t.expectEqual(@as(?Grant, .{ .bytes = true }), parseGrant("bytes"));
    try t.expectEqual(@as(?Grant, .{ .hierarchy = true, .mutate = true }), parseGrant("hierarchy,write"));
    try t.expectEqual(@as(?Grant, .read_write), parseGrant("read,write"));
    // Unknown words fail closed: the caller falls back to no grant at all.
    try t.expectEqual(@as(?Grant, null), parseGrant("everything"));
}

test {
    std.testing.refAllDecls(@This());
}
