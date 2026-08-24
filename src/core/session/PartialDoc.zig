//! Client side of editable partial checkout (stemma hole-bases). The
//! host serves its compacted base via `remote_fs.serveBase` (base_open
//! reply: base_version + agent watermarks + a chunk table snapped to
//! scalar boundaries; base_read: pristine base bytes). `PartialDoc`
//! adopts that table as an all-holes document, realizes spans on demand
//! — from the viewport (`want`) or because a merge bounced (`stash` +
//! `pump`) — and retries merges that hit unrealized spans. Sync itself
//! is the ordinary frontier exchange.

const std = @import("std");
const Allocator = std.mem.Allocator;

const wire = @import("weft_wire");
const Document = @import("../Document.zig");
const Session = @import("Session.zig");
const BlobOp = @import("remote_fs.zig").BlobOp;

const PartialDoc = @This();

gpa: Allocator,
doc: *Document,
next_call: u64 = 1,
inflight: std.AutoHashMapUnmanaged(u64, Req) = .empty,
state: enum { idle, opening, open, unsupported } = .idle,
/// A batch that bounced off unrealized spans; retried after every
/// realization (idempotent — duplicate events are no-ops).
pending_batch: ?[]u8 = null,
/// Fetch everything (`realize-all`): pump keeps requesting until
/// the base is fully realized.
fetch_all: bool = false,

const Req = union(enum) { open, read: u64 };
const max_inflight_reads = 8;

pub fn init(gpa: Allocator, doc: *Document) PartialDoc {
    return .{ .gpa = gpa, .doc = doc };
}

pub fn deinit(self: *PartialDoc) void {
    self.inflight.deinit(self.gpa);
    if (self.pending_batch) |b| self.gpa.free(b);
}

/// Ask the host for its base table (once).
pub fn requestOpen(self: *PartialDoc, session: *Session, base: u64) !void {
    if (self.state != .idle) return;
    self.state = .opening;
    var p: std.ArrayList(u8) = .empty;
    defer p.deinit(self.gpa);
    const id = self.next_call;
    self.next_call += 1;
    try wire.putUv(self.gpa, &p, id);
    try p.append(self.gpa, @intFromEnum(BlobOp.base_open));
    try self.inflight.put(self.gpa, id, .open);
    try session.post(.request, @intFromEnum(wire.RequestKind.call), base + 3, p.items);
}

/// Request realization of the unrealized spans intersecting the
/// current byte range `[start, end)` (the viewport).
pub fn want(self: *PartialDoc, session: *Session, base: u64, start: usize, end: usize) !void {
    if (self.state != .open) return;
    for (self.doc.unrealizedBase()) |h| {
        if (h.cur_offset >= end or h.cur_offset + h.bytes <= start) continue;
        try self.requestRead(session, base, h.base_offset, h.bytes);
    }
}

/// Remember a batch that bounced off unrealized spans.
pub fn stash(self: *PartialDoc, batch: []const u8) !void {
    const dup = try self.gpa.dupe(u8, batch);
    if (self.pending_batch) |old| self.gpa.free(old);
    self.pending_batch = dup;
}

/// Keep realization moving: while a merge is stalled (or fetch_all
/// is set), fetch every hole (bounded concurrency); each arrival
/// retries the merge.
pub fn pump(self: *PartialDoc, session: *Session, base: u64) !void {
    if (self.state != .open) return;
    if (self.pending_batch == null and !self.fetch_all) return;
    if (self.fetch_all and self.doc.baseRealized()) self.fetch_all = false;
    for (self.doc.unrealizedBase()) |h| {
        try self.requestRead(session, base, h.base_offset, h.bytes);
    }
}

fn requestRead(self: *PartialDoc, session: *Session, base: u64, base_offset: usize, len: usize) !void {
    var reads: usize = 0;
    var it = self.inflight.valueIterator();
    while (it.next()) |r| {
        if (r.* == .read) {
            if (r.read == base_offset) return; // already inflight
            reads += 1;
        }
    }
    if (reads >= max_inflight_reads) return;
    var p: std.ArrayList(u8) = .empty;
    defer p.deinit(self.gpa);
    const id = self.next_call;
    self.next_call += 1;
    try wire.putUv(self.gpa, &p, id);
    try p.append(self.gpa, @intFromEnum(BlobOp.base_read));
    try wire.putUv(self.gpa, &p, base_offset);
    try wire.putUv(self.gpa, &p, len);
    try self.inflight.put(self.gpa, id, .{ .read = base_offset });
    try session.post(.request, @intFromEnum(wire.RequestKind.call), base + 3, p.items);
}

/// Fold a base reply. Returns true when the document changed.
pub fn onReply(self: *PartialDoc, session: *Session, base: u64, payload: []const u8) !bool {
    _ = session;
    _ = base;
    const gpa = self.gpa;
    var cur: []const u8 = payload;
    const id = try wire.getUv(&cur);
    const kv = self.inflight.fetchRemove(id) orelse return false;
    if (cur.len == 0) return false;
    const ok = cur[0] == 1;
    cur = cur[1..];
    switch (kv.value) {
        .open => {
            if (!ok) {
                self.state = .unsupported; // host not compacted: full sync
                return false;
            }
            const vlen = try wire.getUv(&cur);
            if (vlen > cur.len) return error.Corrupt;
            const version = cur[0..@intCast(vlen)];
            cur = cur[@intCast(vlen)..];
            const wm_count = try wire.getUv(&cur);
            if (wm_count > 4096) return error.Corrupt;
            var wms: std.ArrayList(Document.AgentWatermark) = .empty;
            defer wms.deinit(gpa);
            for (0..@intCast(wm_count)) |_| {
                const nlen = try wire.getUv(&cur);
                if (nlen > cur.len) return error.Corrupt;
                const name = cur[0..@intCast(nlen)];
                cur = cur[@intCast(nlen)..];
                const seq_base = try wire.getUv(&cur);
                try wms.append(gpa, .{ .name = name, .seq_base = seq_base });
            }
            const chunk_count = try wire.getUv(&cur);
            if (chunk_count > 1 << 24) return error.Corrupt;
            var chunks: std.ArrayList(Document.BaseChunk) = .empty;
            defer chunks.deinit(gpa);
            for (0..@intCast(chunk_count)) |_| {
                const bytes = try wire.getUv(&cur);
                const scalars = try wire.getUv(&cur);
                try chunks.append(gpa, .{ .hole = .{
                    .bytes = @intCast(bytes),
                    .scalars = @intCast(scalars),
                } });
            }
            self.doc.adoptPartial(gpa, version, wms.items, chunks.items) catch |e| switch (e) {
                error.Corrupt => {
                    self.state = .unsupported;
                    return false;
                },
                else => |err| return err,
            };
            self.state = .open;
            return true;
        },
        .read => |base_offset| {
            if (!ok or cur.len == 0) return false;
            self.doc.realizeBase(gpa, @intCast(base_offset), cur) catch |e| switch (e) {
                error.Corrupt => return false, // stale/duplicate span
                else => |err| return err,
            };
            // A realization may unblock the stalled merge.
            if (self.pending_batch) |b| {
                if (self.doc.mergeRemote(gpa, b)) |_| {
                    gpa.free(b);
                    self.pending_batch = null;
                } else |err| if (err != error.Unrealized) {
                    std.log.warn("partial: stashed batch rejected: {t}", .{err});
                    gpa.free(b);
                    self.pending_batch = null;
                }
            }
            return true;
        },
    }
}
