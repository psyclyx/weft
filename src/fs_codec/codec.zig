//! Canonical bounded codec for the platform-neutral filesystem contract.

const std = @import("std");
const fs = @import("weft_fs");
const semantic = @import("weft_semantic");

const c = fs.contract;

pub const Limits = struct {
    pub const max_payload_bytes: usize = 16 * 1024 * 1024;
    pub const max_count: usize = 16 * 1024;
    pub const max_string_bytes: usize = 1024 * 1024;
    pub const max_depth: usize = 256;
};

pub const Error = error{
    Corrupt,
    LimitExceeded,
    InvalidData,
    Duplicate,
    BadReference,
    InvalidName,
    InvalidHandle,
} || std.mem.Allocator.Error;

pub fn Owned(comptime T: type) type {
    return struct {
        arena: std.heap.ArenaAllocator,
        value: T = undefined,

        const Self = @This();

        pub fn init(gpa: std.mem.Allocator) Self {
            return .{ .arena = .init(gpa) };
        }

        pub fn allocator(self: *Self) std.mem.Allocator {
            return self.arena.allocator();
        }

        pub fn deinit(self: *Self) void {
            self.arena.deinit();
            self.* = undefined;
        }
    };
}

pub const OwnedListing = Owned(c.Listing);
pub const OwnedPlan = Owned(c.Plan);
pub const OwnedApplyReport = Owned(c.ApplyReport);

/// A request to turn one observed direct child directory into an independently
/// confined semantic target. The parent target is the authority-bearing
/// capability; the entry handle and opaque revision are only guarded
/// identifiers within that authority.
pub const ChildDirectory = struct {
    parent: semantic.target.Located,
    entry: c.EntryRef,
    revision: c.Revision,
};

pub const OwnedChildDirectory = Owned(ChildDirectory);

const Writer = struct {
    bytes: std.ArrayList(u8) = .empty,
    gpa: std.mem.Allocator,

    fn init(gpa: std.mem.Allocator) Writer {
        return .{ .gpa = gpa };
    }

    fn deinit(self: *Writer) void {
        self.bytes.deinit(self.gpa);
    }

    fn finish(self: *Writer) Error![]u8 {
        return self.bytes.toOwnedSlice(self.gpa);
    }

    fn append(self: *Writer, value: []const u8) Error!void {
        if (value.len > Limits.max_payload_bytes -| self.bytes.items.len) return error.LimitExceeded;
        try self.bytes.appendSlice(self.gpa, value);
    }

    fn byte(self: *Writer, value: u8) Error!void {
        try self.append(&.{value});
    }

    fn writeU32(self: *Writer, value: u32) Error!void {
        var buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &buf, value, .little);
        try self.append(&buf);
    }

    fn writeU64(self: *Writer, value: u64) Error!void {
        var buf: [8]u8 = undefined;
        std.mem.writeInt(u64, &buf, value, .little);
        try self.append(&buf);
    }

    fn writeI128(self: *Writer, value: i128) Error!void {
        var buf: [16]u8 = undefined;
        std.mem.writeInt(u128, &buf, @bitCast(value), .little);
        try self.append(&buf);
    }

    fn varint(self: *Writer, raw: usize) Error!void {
        if (raw > Limits.max_payload_bytes) return error.LimitExceeded;
        var value: u64 = @intCast(raw);
        while (value >= 0x80) : (value >>= 7) try self.byte(@intCast(value & 0x7f | 0x80));
        try self.byte(@intCast(value));
    }

    fn count(self: *Writer, value: usize) Error!void {
        if (value > Limits.max_count) return error.LimitExceeded;
        try self.varint(value);
    }

    fn bytesField(self: *Writer, value: []const u8, string: bool) Error!void {
        const limit = if (string) Limits.max_string_bytes else Limits.max_payload_bytes;
        if (value.len > limit) return error.LimitExceeded;
        try self.varint(value.len);
        try self.append(value);
    }
};

const Reader = struct {
    bytes: []const u8,
    pos: usize = 0,

    fn init(bytes: []const u8) Error!Reader {
        if (bytes.len > Limits.max_payload_bytes) return error.LimitExceeded;
        return .{ .bytes = bytes };
    }

    fn take(self: *Reader, n: usize) Error![]const u8 {
        if (n > self.bytes.len -| self.pos) return error.Corrupt;
        const result = self.bytes[self.pos .. self.pos + n];
        self.pos += n;
        return result;
    }

    fn byte(self: *Reader) Error!u8 {
        return (try self.take(1))[0];
    }

    fn readU32(self: *Reader) Error!u32 {
        var buf: [4]u8 = undefined;
        @memcpy(&buf, try self.take(4));
        return std.mem.readInt(u32, &buf, .little);
    }

    fn readU64(self: *Reader) Error!u64 {
        var buf: [8]u8 = undefined;
        @memcpy(&buf, try self.take(8));
        return std.mem.readInt(u64, &buf, .little);
    }

    fn readI128(self: *Reader) Error!i128 {
        var buf: [16]u8 = undefined;
        @memcpy(&buf, try self.take(16));
        return @bitCast(std.mem.readInt(u128, &buf, .little));
    }

    fn varint(self: *Reader) Error!u64 {
        var value: u64 = 0;
        var shift: u6 = 0;
        var used: usize = 0;
        while (used < 10) : (used += 1) {
            const b = try self.byte();
            const bits: u64 = b & 0x7f;
            if (shift == 63 and bits > 1) return error.Corrupt;
            value |= bits << shift;
            if (b & 0x80 == 0) {
                if (used > 0 and bits == 0) return error.Corrupt;
                return value;
            }
            // There are only ten bytes in a u64 varint. In particular, do
            // not advance a u6 shift after byte ten: malformed input must
            // become Corrupt rather than relying on integer-overflow mode.
            if (used == 9) return error.Corrupt;
            shift += 7;
        }
        return error.Corrupt;
    }

    fn count(self: *Reader) Error!usize {
        const value = try self.varint();
        if (value > Limits.max_count or value > std.math.maxInt(usize)) return error.LimitExceeded;
        return @intCast(value);
    }

    fn field(self: *Reader, arena: std.mem.Allocator, string: bool) Error![]const u8 {
        const raw = try self.varint();
        const limit = if (string) Limits.max_string_bytes else Limits.max_payload_bytes;
        if (raw > limit or raw > std.math.maxInt(usize)) return error.LimitExceeded;
        return try arena.dupe(u8, try self.take(@intCast(raw)));
    }

    fn strictBool(self: *Reader) Error!bool {
        return switch (try self.byte()) {
            0 => false,
            1 => true,
            else => error.Corrupt,
        };
    }

    fn done(self: *const Reader) Error!void {
        if (self.pos != self.bytes.len) return error.Corrupt;
    }
};

const version: u8 = 1;
const magic = "WFS";
const listing_kind: u8 = 1;
const plan_kind: u8 = 2;
const report_kind: u8 = 3;
const child_directory_kind: u8 = 4;

fn header(w: *Writer, kind: u8) Error!void {
    try w.append(magic);
    try w.byte(version);
    try w.byte(kind);
}

fn checkHeader(r: *Reader, kind: u8) Error!void {
    if (!std.mem.eql(u8, try r.take(magic.len), magic)) return error.Corrupt;
    if (try r.byte() != version or try r.byte() != kind) return error.Corrupt;
}

fn validateHandle(handle: anytype) Error!void {
    if (handle.generation == 0) return error.InvalidHandle;
}

fn writeHandle(w: *Writer, handle: anytype) Error!void {
    try validateHandle(handle);
    try w.writeU32(@intFromEnum(handle.authority));
    try w.writeU32(handle.slot);
    try w.writeU32(handle.generation);
}

fn readWire(r: *Reader) Error!semantic.handle.Wire {
    const wire: semantic.handle.Wire = .{ .authority = try r.readU32(), .slot = try r.readU32(), .generation = try r.readU32() };
    if (wire.generation == 0) return error.InvalidHandle;
    return wire;
}

fn readHandle(comptime T: type, r: *Reader) Error!T {
    return T.fromWire(try readWire(r));
}

fn writeRevision(w: *Writer, revision: c.Revision) Error!void {
    try w.bytesField(revision.token, false);
}

fn readRevision(r: *Reader, arena: std.mem.Allocator) Error!c.Revision {
    return .{ .token = try r.field(arena, false) };
}

fn writeName(w: *Writer, name: c.Name) Error!void {
    _ = c.Name.init(name.bytes) catch return error.InvalidName;
    try w.bytesField(name.bytes, true);
}

fn readName(r: *Reader, arena: std.mem.Allocator) Error!c.Name {
    const bytes = try r.field(arena, true);
    return c.Name.init(bytes) catch error.InvalidName;
}

fn writeNode(w: *Writer, node: c.NodeRef) Error!void {
    switch (node) {
        .root => try w.byte(0),
        .entry => |entry| {
            try w.byte(1);
            try writeHandle(w, entry);
        },
    }
}

fn readNode(r: *Reader) Error!c.NodeRef {
    return switch (try r.byte()) {
        0 => .root,
        1 => .{ .entry = try readHandle(c.EntryRef, r) },
        else => error.Corrupt,
    };
}

fn writeMetadata(w: *Writer, metadata: c.Metadata) Error!void {
    try w.byte(if (metadata.mode != null) 1 else 0);
    if (metadata.mode) |mode| try w.writeU32(mode);
    try w.byte(if (metadata.size != null) 1 else 0);
    if (metadata.size) |size| try w.writeU64(size);
    try w.byte(if (metadata.modified_ns != null) 1 else 0);
    if (metadata.modified_ns) |modified| try w.writeI128(modified);
    try w.byte(if (metadata.link_target != null) 1 else 0);
    if (metadata.link_target) |target| try w.bytesField(target, false);
}

fn readMetadata(r: *Reader, arena: std.mem.Allocator) Error!c.Metadata {
    var metadata: c.Metadata = .{};
    if (try r.strictBool()) metadata.mode = try r.readU32();
    if (try r.strictBool()) metadata.size = try r.readU64();
    if (try r.strictBool()) metadata.modified_ns = try r.readI128();
    if (try r.strictBool()) metadata.link_target = try r.field(arena, false);
    return metadata;
}

fn writeObservation(w: *Writer, observation: c.Observation) Error!void {
    try writeNode(w, observation.node);
    try writeRevision(w, observation.revision);
    try w.byte(@intFromEnum(observation.kind));
    try writeMetadata(w, observation.metadata);
}

fn readObservation(r: *Reader, arena: std.mem.Allocator) Error!c.Observation {
    const node = try readNode(r);
    const revision = try readRevision(r, arena);
    const kind = try readKind(r);
    return .{ .node = node, .revision = revision, .kind = kind, .metadata = try readMetadata(r, arena) };
}

fn readKind(r: *Reader) Error!c.Kind {
    return switch (try r.byte()) {
        0 => .regular,
        1 => .directory,
        2 => .symlink,
        3 => .other,
        else => error.Corrupt,
    };
}

fn writeDirEntry(w: *Writer, entry: c.DirEntry) Error!void {
    try writeName(w, entry.name);
    try writeObservation(w, entry.observation);
}

fn readDirEntry(r: *Reader, arena: std.mem.Allocator) Error!c.DirEntry {
    return .{ .name = try readName(r, arena), .observation = try readObservation(r, arena) };
}

fn writeParent(w: *Writer, parent: c.ParentRef) Error!void {
    switch (parent) {
        .root => try w.byte(0),
        .entry => |entry| {
            try w.byte(1);
            try writeHandle(w, entry);
        },
        .planned => |index| {
            try w.byte(2);
            try w.count(index);
        },
    }
}

fn readParent(r: *Reader) Error!c.ParentRef {
    return switch (try r.byte()) {
        0 => .root,
        1 => .{ .entry = try readHandle(c.EntryRef, r) },
        2 => .{ .planned = try r.count() },
        else => error.Corrupt,
    };
}

fn writeSlot(w: *Writer, slot: c.Slot) Error!void {
    try writeParent(w, slot.parent);
    try writeName(w, slot.name);
}

fn readSlot(r: *Reader, arena: std.mem.Allocator) Error!c.Slot {
    return .{ .parent = try readParent(r), .name = try readName(r, arena) };
}

fn writeExpected(w: *Writer, expected: c.Expected) Error!void {
    switch (expected) {
        .anything => try w.byte(0),
        .absent => try w.byte(1),
        .entry => |entry| {
            try w.byte(2);
            try writeHandle(w, entry.ref);
            try writeRevision(w, entry.revision);
        },
    }
}

fn readExpected(r: *Reader, arena: std.mem.Allocator) Error!c.Expected {
    return switch (try r.byte()) {
        0 => .anything,
        1 => .absent,
        2 => .{ .entry = .{ .ref = try readHandle(c.EntryRef, r), .revision = try readRevision(r, arena) } },
        else => error.Corrupt,
    };
}

fn writeSource(w: *Writer, source: c.Source) Error!void {
    switch (source) {
        .entry => |entry| {
            try w.byte(0);
            try writeHandle(w, entry.root);
            try writeHandle(w, entry.ref);
            try writeRevision(w, entry.revision);
        },
        .lease => |lease| {
            try w.byte(1);
            try writeHandle(w, lease.root);
            try writeHandle(w, lease.ref);
        },
    }
}

fn readSource(r: *Reader, arena: std.mem.Allocator) Error!c.Source {
    return switch (try r.byte()) {
        0 => .{ .entry = .{
            .root = try readHandle(c.Root, r),
            .ref = try readHandle(c.EntryRef, r),
            .revision = try readRevision(r, arena),
        } },
        1 => .{ .lease = .{ .root = try readHandle(c.Root, r), .ref = try readHandle(c.LeaseRef, r) } },
        else => error.Corrupt,
    };
}

fn writeOperation(w: *Writer, operation: c.Operation, depth: usize) Error!void {
    if (depth > Limits.max_depth) return error.LimitExceeded;
    switch (operation) {
        .create_file => |value| {
            try w.byte(0);
            try writeSlot(w, value.destination);
            try writeExpected(w, value.expected);
            try w.bytesField(value.contents, false);
            try w.byte(if (value.mode != null) 1 else 0);
            if (value.mode) |mode| try w.writeU32(mode);
        },
        .create_directory => |value| {
            try w.byte(1);
            try writeSlot(w, value.destination);
            try writeExpected(w, value.expected);
            try w.byte(if (value.mode != null) 1 else 0);
            if (value.mode) |mode| try w.writeU32(mode);
        },
        .create_symlink => |value| {
            try w.byte(2);
            try writeSlot(w, value.destination);
            try writeExpected(w, value.expected);
            try w.bytesField(value.target, false);
        },
        .copy => |value| {
            try w.byte(3);
            try writeSource(w, value.source);
            try writeSlot(w, value.destination);
            try writeExpected(w, value.expected);
        },
        .rename => |value| {
            try w.byte(4);
            try writeHandle(w, value.source.root);
            try writeHandle(w, value.source.ref);
            try writeRevision(w, value.source.revision);
            try writeSlot(w, value.destination);
            try writeExpected(w, value.expected);
        },
        .remove => |value| {
            try w.byte(5);
            try writeHandle(w, value.source.root);
            try writeHandle(w, value.source.ref);
            try writeRevision(w, value.source.revision);
            try w.byte(@intFromEnum(value.policy));
        },
        .set_permissions => |value| {
            try w.byte(6);
            try writeHandle(w, value.source.root);
            try writeHandle(w, value.source.ref);
            try writeRevision(w, value.source.revision);
            try w.writeU32(value.mode);
            try w.byte(@intFromBool(value.follow_symlink));
        },
    }
}

fn readOperation(r: *Reader, arena: std.mem.Allocator, depth: usize) Error!c.Operation {
    if (depth > Limits.max_depth) return error.LimitExceeded;
    return switch (try r.byte()) {
        0 => .{ .create_file = .{
            .destination = try readSlot(r, arena),
            .expected = try readExpected(r, arena),
            .contents = try r.field(arena, false),
            .mode = if (try r.strictBool()) try r.readU32() else null,
        } },
        1 => .{ .create_directory = .{
            .destination = try readSlot(r, arena),
            .expected = try readExpected(r, arena),
            .mode = if (try r.strictBool()) try r.readU32() else null,
        } },
        2 => .{ .create_symlink = .{
            .destination = try readSlot(r, arena),
            .expected = try readExpected(r, arena),
            .target = try r.field(arena, false),
        } },
        3 => .{ .copy = .{
            .source = try readSource(r, arena),
            .destination = try readSlot(r, arena),
            .expected = try readExpected(r, arena),
        } },
        4 => .{ .rename = .{
            .source = .{
                .root = try readHandle(c.Root, r),
                .ref = try readHandle(c.EntryRef, r),
                .revision = try readRevision(r, arena),
            },
            .destination = try readSlot(r, arena),
            .expected = try readExpected(r, arena),
        } },
        5 => .{ .remove = .{
            .source = .{
                .root = try readHandle(c.Root, r),
                .ref = try readHandle(c.EntryRef, r),
                .revision = try readRevision(r, arena),
            },
            .policy = try readRemovePolicy(r),
        } },
        6 => .{ .set_permissions = .{
            .source = .{
                .root = try readHandle(c.Root, r),
                .ref = try readHandle(c.EntryRef, r),
                .revision = try readRevision(r, arena),
            },
            .mode = try r.readU32(),
            .follow_symlink = try r.strictBool(),
        } },
        else => error.Corrupt,
    };
}

fn readRemovePolicy(r: *Reader) Error!c.RemovePolicy {
    return switch (try r.byte()) {
        0 => .quarantine,
        1 => .permanent,
        else => error.Corrupt,
    };
}

fn writeId(w: *Writer, id: c.OperationId) Error!void {
    try w.append(&id);
}

fn readId(r: *Reader) Error!c.OperationId {
    var id: c.OperationId = undefined;
    @memcpy(&id, try r.take(id.len));
    return id;
}

fn writeOutcome(w: *Writer, outcome: c.Outcome, depth: usize) Error!void {
    if (depth > Limits.max_depth) return error.LimitExceeded;
    switch (outcome) {
        .applied => |observation| {
            try w.byte(0);
            try w.byte(if (observation != null) 1 else 0);
            if (observation) |value| try writeObservation(w, value);
        },
        .already_satisfied => try w.byte(1),
        .conflict => |message| {
            try w.byte(2);
            try w.bytesField(message, false);
        },
        .stale => try w.byte(3),
        .unsupported => try w.byte(4),
        .ambiguous => |message| {
            try w.byte(5);
            try w.bytesField(message, false);
        },
        .recoverable_at => |slot| {
            try w.byte(6);
            try writeSlot(w, slot);
        },
    }
}

fn readOutcome(r: *Reader, arena: std.mem.Allocator, depth: usize) Error!c.Outcome {
    if (depth > Limits.max_depth) return error.LimitExceeded;
    return switch (try r.byte()) {
        0 => if (try r.strictBool()) .{ .applied = try readObservation(r, arena) } else .{ .applied = null },
        1 => .already_satisfied,
        2 => .{ .conflict = try r.field(arena, false) },
        3 => .stale,
        4 => .unsupported,
        5 => .{ .ambiguous = try r.field(arena, false) },
        6 => .{ .recoverable_at = try readSlot(r, arena) },
        else => error.Corrupt,
    };
}

fn writePlanBody(w: *Writer, plan: c.Plan, depth: usize) Error!void {
    if (depth > Limits.max_depth) return error.LimitExceeded;
    try writeHandle(w, plan.root);
    try w.bytesField(plan.base_revision, false);
    try w.count(plan.operations.len);
    for (plan.operations) |planned| {
        try writeId(w, planned.id);
        try w.count(planned.depends_on.len);
        for (planned.depends_on) |dependency| try w.count(dependency);
        try writeOperation(w, planned.operation, depth + 1);
    }
}

fn readPlanBody(r: *Reader, arena: std.mem.Allocator, depth: usize) Error!c.Plan {
    if (depth > Limits.max_depth) return error.LimitExceeded;
    const root = try readHandle(c.Root, r);
    const base_revision = try r.field(arena, false);
    const count = try r.count();
    const operations = try arena.alloc(c.Planned, count);
    for (operations, 0..) |*planned, i| {
        planned.id = try readId(r);
        const dep_count = try r.count();
        const dependencies = try arena.alloc(usize, dep_count);
        for (dependencies) |*dependency| {
            const raw = try r.count();
            if (raw >= count or raw >= i) return error.InvalidData;
            dependency.* = raw;
        }
        planned.depends_on = dependencies;
        planned.operation = try readOperation(r, arena, depth + 1);
    }
    const plan: c.Plan = .{ .root = root, .base_revision = base_revision, .operations = operations };
    fs.plan.validate(arena, plan) catch |err| return switch (err) {
        error.DuplicateOperationId => error.Duplicate,
        error.InvalidDependency => error.InvalidData,
        error.OutOfMemory => error.OutOfMemory,
    };
    return plan;
}

pub fn encodeListing(gpa: std.mem.Allocator, listing: c.Listing) Error![]u8 {
    var w = Writer.init(gpa);
    defer w.deinit();
    try header(&w, listing_kind);
    try writeObservation(&w, listing.directory);
    try writeRevision(&w, listing.revision);
    try w.count(listing.entries.len);
    for (listing.entries) |entry| try writeDirEntry(&w, entry);
    return try w.finish();
}

pub fn decodeListing(gpa: std.mem.Allocator, bytes: []const u8) Error!OwnedListing {
    var owned = OwnedListing.init(gpa);
    errdefer owned.deinit();
    var r = try Reader.init(bytes);
    try checkHeader(&r, listing_kind);
    const arena = owned.allocator();
    const directory = try readObservation(&r, arena);
    const revision = try readRevision(&r, arena);
    const entries = try arena.alloc(c.DirEntry, try r.count());
    for (entries) |*entry| entry.* = try readDirEntry(&r, arena);
    try r.done();
    owned.value = .{ .directory = directory, .revision = revision, .entries = entries };
    return owned;
}

/// Encode the minimum immutable evidence needed to derive a child directory
/// target. Names deliberately do not cross this request: the authority
/// provider re-reads the direct child and supplies its current raw name.
pub fn encodeChildDirectory(gpa: std.mem.Allocator, request: ChildDirectory) Error![]u8 {
    if (request.parent.revision == 0) return error.InvalidData;
    switch (request.parent.location) {
        .whole => {},
        else => return error.InvalidData,
    }
    var w = Writer.init(gpa);
    defer w.deinit();
    try header(&w, child_directory_kind);
    try writeHandle(&w, request.parent.target);
    try w.writeU64(request.parent.revision);
    try writeHandle(&w, request.entry);
    try writeRevision(&w, request.revision);
    return try w.finish();
}

pub fn decodeChildDirectory(gpa: std.mem.Allocator, bytes: []const u8) Error!OwnedChildDirectory {
    var owned = OwnedChildDirectory.init(gpa);
    errdefer owned.deinit();
    var r = try Reader.init(bytes);
    try checkHeader(&r, child_directory_kind);
    const parent = try readHandle(semantic.target.Ref, &r);
    const parent_revision = try r.readU64();
    if (parent_revision == 0) return error.InvalidData;
    const entry = try readHandle(c.EntryRef, &r);
    const revision = try readRevision(&r, owned.allocator());
    try r.done();
    owned.value = .{
        .parent = .{ .target = parent, .revision = parent_revision },
        .entry = entry,
        .revision = revision,
    };
    return owned;
}

pub fn encodePlan(gpa: std.mem.Allocator, plan: c.Plan) Error![]u8 {
    var w = Writer.init(gpa);
    defer w.deinit();
    fs.plan.validate(gpa, plan) catch |err| switch (err) {
        error.DuplicateOperationId => return error.Duplicate,
        error.InvalidDependency => return error.InvalidData,
        error.OutOfMemory => return error.OutOfMemory,
    };
    try header(&w, plan_kind);
    try writePlanBody(&w, plan, 0);
    return try w.finish();
}

pub fn decodePlan(gpa: std.mem.Allocator, bytes: []const u8) Error!OwnedPlan {
    var owned = OwnedPlan.init(gpa);
    errdefer owned.deinit();
    var r = try Reader.init(bytes);
    try checkHeader(&r, plan_kind);
    owned.value = try readPlanBody(&r, owned.allocator(), 0);
    try r.done();
    return owned;
}

pub fn encodeApplyReport(gpa: std.mem.Allocator, report: c.ApplyReport) Error![]u8 {
    var w = Writer.init(gpa);
    defer w.deinit();
    try header(&w, report_kind);
    try w.count(report.entries.len);
    for (report.entries) |entry| {
        try writeId(&w, entry.id);
        try writeOutcome(&w, entry.outcome, 0);
    }
    return try w.finish();
}

pub fn decodeApplyReport(gpa: std.mem.Allocator, bytes: []const u8) Error!OwnedApplyReport {
    var owned = OwnedApplyReport.init(gpa);
    errdefer owned.deinit();
    var r = try Reader.init(bytes);
    try checkHeader(&r, report_kind);
    const entries = try owned.allocator().alloc(c.ReportEntry, try r.count());
    for (entries) |*entry| {
        entry.id = try readId(&r);
        entry.outcome = try readOutcome(&r, owned.allocator(), 0);
    }
    try r.done();
    owned.value = .{ .entries = entries };
    return owned;
}

fn testHandles() struct { root: c.Root, entry: c.EntryRef, lease: c.LeaseRef } {
    return .{
        .root = .{ .authority = @enumFromInt(7), .slot = 11, .generation = 13 },
        .entry = .{ .authority = @enumFromInt(7), .slot = 17, .generation = 19 },
        .lease = .{ .authority = @enumFromInt(7), .slot = 23, .generation = 29 },
    };
}

test "filesystem codec round trips every listing value, raw bytes, metadata, and symlink" {
    const h = testHandles();
    const entry = c.DirEntry{
        .name = try c.Name.init(&[_]u8{ 'x', 0x80 }),
        .observation = .{
            .node = .{ .entry = h.entry },
            .revision = .{ .token = &[_]u8{ 0, 0xff, 7 } },
            .kind = .symlink,
            .metadata = .{ .mode = 0o755, .size = 9, .modified_ns = -1234567890123456789, .link_target = &[_]u8{ 'a', '/', 0xff } },
        },
    };
    const input: c.Listing = .{
        .directory = .{ .node = .root, .revision = .{ .token = "dir" }, .kind = .directory },
        .revision = .{ .token = &[_]u8{0xff} },
        .entries = &[_]c.DirEntry{entry},
    };
    const bytes = try encodeListing(std.testing.allocator, input);
    defer std.testing.allocator.free(bytes);
    var decoded = try decodeListing(std.testing.allocator, bytes);
    defer decoded.deinit();
    try std.testing.expectEqualDeep(input, decoded.value);
}

test "filesystem codec round trips guarded child directory requests" {
    const h = testHandles();
    const input: ChildDirectory = .{
        .parent = .{
            .target = .{ .authority = @enumFromInt(31), .slot = 37, .generation = 41 },
            .revision = 43,
        },
        .entry = h.entry,
        .revision = .{ .token = &[_]u8{ 0, 0xff, 7 } },
    };
    const bytes = try encodeChildDirectory(std.testing.allocator, input);
    defer std.testing.allocator.free(bytes);
    var decoded = try decodeChildDirectory(std.testing.allocator, bytes);
    defer decoded.deinit();
    try std.testing.expectEqualDeep(input, decoded.value);

    var trailing = try std.testing.allocator.alloc(u8, bytes.len + 1);
    defer std.testing.allocator.free(trailing);
    @memcpy(trailing[0..bytes.len], bytes);
    trailing[bytes.len] = 1;
    try std.testing.expectError(error.Corrupt, decodeChildDirectory(std.testing.allocator, trailing));
    try std.testing.expectError(error.InvalidData, encodeChildDirectory(std.testing.allocator, .{
        .parent = .{ .target = input.parent.target, .revision = 0 },
        .entry = input.entry,
        .revision = input.revision,
    }));
}

test "filesystem codec round trips every operation and source variant" {
    const h = testHandles();
    const name_a = try c.Name.init("a");
    const name_b = try c.Name.init("b");
    const slot = c.Slot{ .parent = .root, .name = name_a };
    const source = c.EntrySource{ .root = h.root, .ref = h.entry, .revision = .{ .token = "r" } };
    const operations = [_]c.Planned{
        .{ .id = [_]u8{0} ** 16, .operation = .{ .create_file = .{ .destination = slot, .contents = &[_]u8{ 0, 1 }, .mode = 0o644 } } },
        .{ .id = [_]u8{1} ** 16, .operation = .{ .create_directory = .{ .destination = .{ .parent = .{ .planned = 0 }, .name = name_b } } }, .depends_on = &.{0} },
        .{ .id = [_]u8{2} ** 16, .operation = .{ .create_symlink = .{ .destination = slot, .target = "../x" } }, .depends_on = &.{0} },
        .{ .id = [_]u8{3} ** 16, .operation = .{ .copy = .{ .source = .{ .entry = source }, .destination = slot, .expected = .anything } }, .depends_on = &.{0} },
        .{ .id = [_]u8{4} ** 16, .operation = .{ .copy = .{ .source = .{ .lease = .{ .root = h.root, .ref = h.lease } }, .destination = slot } }, .depends_on = &.{0} },
        .{ .id = [_]u8{5} ** 16, .operation = .{ .rename = .{ .source = source, .destination = slot, .expected = .{ .entry = .{ .ref = h.entry, .revision = .{ .token = "e" } } } } }, .depends_on = &.{0} },
        .{ .id = [_]u8{6} ** 16, .operation = .{ .remove = .{ .source = source, .policy = .permanent } }, .depends_on = &.{0} },
        .{ .id = [_]u8{7} ** 16, .operation = .{ .set_permissions = .{ .source = source, .mode = 0o600, .follow_symlink = true } }, .depends_on = &.{0} },
    };
    const input: c.Plan = .{ .root = h.root, .base_revision = "base", .operations = &operations };
    const bytes = try encodePlan(std.testing.allocator, input);
    defer std.testing.allocator.free(bytes);
    var decoded = try decodePlan(std.testing.allocator, bytes);
    defer decoded.deinit();
    try std.testing.expectEqualDeep(input, decoded.value);
}

test "filesystem codec round trips every outcome variant" {
    const h = testHandles();
    const observation: c.Observation = .{ .node = .{ .entry = h.entry }, .revision = .{ .token = "o" }, .kind = .regular };
    const slot: c.Slot = .{ .parent = .root, .name = try c.Name.init("recover") };
    const entries = [_]c.ReportEntry{
        .{ .id = [_]u8{0} ** 16, .outcome = .{ .applied = observation } },
        .{ .id = [_]u8{1} ** 16, .outcome = .{ .applied = null } },
        .{ .id = [_]u8{2} ** 16, .outcome = .already_satisfied },
        .{ .id = [_]u8{3} ** 16, .outcome = .{ .conflict = &[_]u8{0xff} } },
        .{ .id = [_]u8{4} ** 16, .outcome = .stale },
        .{ .id = [_]u8{5} ** 16, .outcome = .unsupported },
        .{ .id = [_]u8{6} ** 16, .outcome = .{ .ambiguous = "amb" } },
        .{ .id = [_]u8{7} ** 16, .outcome = .{ .recoverable_at = slot } },
    };
    const bytes = try encodeApplyReport(std.testing.allocator, .{ .entries = &entries });
    defer std.testing.allocator.free(bytes);
    var decoded = try decodeApplyReport(std.testing.allocator, bytes);
    defer decoded.deinit();
    try std.testing.expectEqualDeep(@as(c.ApplyReport, .{ .entries = &entries }), decoded.value);
}

test "filesystem codec rejects tags, names, handles, trailing data, and malformed booleans" {
    const h = testHandles();
    const listing: c.Listing = .{ .directory = .{ .node = .root, .revision = .{ .token = "r" }, .kind = .directory }, .revision = .{ .token = "r" }, .entries = &.{} };
    var bytes = try encodeListing(std.testing.allocator, listing);
    defer std.testing.allocator.free(bytes);
    const original = bytes[0];
    bytes[0] = 2;
    try std.testing.expectError(error.Corrupt, decodeListing(std.testing.allocator, bytes));
    bytes[0] = original;
    var bad_bool = try std.testing.allocator.dupe(u8, bytes);
    defer std.testing.allocator.free(bad_bool);
    bad_bool[9] = 2;
    try std.testing.expectError(error.Corrupt, decodeListing(std.testing.allocator, bad_bool));
    var trailing = try std.testing.allocator.alloc(u8, bytes.len + 1);
    defer std.testing.allocator.free(trailing);
    @memcpy(trailing[0..bytes.len], bytes);
    trailing[bytes.len] = 9;
    try std.testing.expectError(error.Corrupt, decodeListing(std.testing.allocator, trailing));

    const bad_name = c.Listing{ .directory = listing.directory, .revision = listing.revision, .entries = &[_]c.DirEntry{.{ .name = .{ .bytes = "." }, .observation = listing.directory }} };
    try std.testing.expectError(error.InvalidName, encodeListing(std.testing.allocator, bad_name));

    var bad_handle = try encodeApplyReport(std.testing.allocator, .{ .entries = &[_]c.ReportEntry{.{ .id = [_]u8{0} ** 16, .outcome = .{ .applied = .{ .node = .{ .entry = h.entry }, .revision = .{ .token = "x" }, .kind = .regular } } }} });
    defer std.testing.allocator.free(bad_handle);
    // The generation sits at the end of the entry handle in this report.
    bad_handle[33] = 0;
    try std.testing.expectError(error.InvalidHandle, decodeApplyReport(std.testing.allocator, bad_handle));
}

test "filesystem codec rejects unterminated and overflowing tenth varints" {
    // Header, root node tag, then a revision length. Both malformed lengths
    // reach the public listing decoder, so this protects the wire boundary
    // rather than only exercising Reader in isolation.
    var unterminated: [16]u8 = .{
        'W',  'F',  'S',  1,    1,    0,
        0x80, 0x80, 0x80, 0x80, 0x80, 0x80,
        0x80, 0x80, 0x80, 0x80,
    };
    try std.testing.expectError(error.Corrupt, decodeListing(std.testing.allocator, &unterminated));

    var overflowing = unterminated;
    overflowing[15] = 0x02;
    try std.testing.expectError(error.Corrupt, decodeListing(std.testing.allocator, &overflowing));
}

test "filesystem codec rejects duplicate and forward plan dependencies" {
    const h = testHandles();
    const operation = c.Planned{ .id = [_]u8{1} ** 16, .operation = .{ .remove = .{ .source = .{ .root = h.root, .ref = h.entry, .revision = .{ .token = "x" } } } } };
    const duplicate = [_]c.Planned{ operation, operation };
    try std.testing.expectError(error.Duplicate, encodePlan(std.testing.allocator, .{ .root = h.root, .base_revision = &.{}, .operations = &duplicate }));
    const forward = [_]c.Planned{ .{ .id = [_]u8{1} ** 16, .operation = operation.operation, .depends_on = &.{1} }, .{ .id = [_]u8{2} ** 16, .operation = operation.operation } };
    try std.testing.expectError(error.InvalidData, encodePlan(std.testing.allocator, .{ .root = h.root, .base_revision = &.{}, .operations = &forward }));
}
