//! Portable, multi-representation transfer values.

const std = @import("std");
const target = @import("target.zig");
const handle = @import("handle.zig");

pub const Intent = enum { copy, cut };

/// A provider-owned attachment identifier.  It is only meaningful to the
/// owner-scoped membrane that minted it; its fields are never an OS handle or
/// a pointer.  The host resolves it while the issuing plugin is live, then
/// transfers retain the resolved resource independently of this identifier.
pub const AttachmentTag = struct {};
pub const Attachment = handle.Handle(AttachmentTag);

pub const Representation = struct {
    media_type: []const u8,
    schema: ?[]const u8 = null,
    payload: []const u8,
    /// Host-local ownership is opaque to semantic core and is not serialized.
    /// It may represent a durable lease or another retained native resource.
    resource: ?Resource = null,
    /// A portable, owner-scoped reference to a host attachment.  This is
    /// serialized; `resource` is not.  Host transports resolve the reference
    /// before admitting the value into a process-local transfer owner.
    attachment: ?Attachment = null,
};

pub const Resource = struct {
    /// Process-local retention only. Canonical codecs intentionally serialize
    /// the representation data and omit this callback; the host-side owned
    /// transfer keeps it live while a sandbox consumes the portable payload.
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        retain: *const fn (*anyopaque) void,
        release: *const fn (*anyopaque) void,
    };

    pub fn retain(self: Resource) void {
        self.vtable.retain(self.context);
    }

    pub fn release(self: Resource) void {
        self.vtable.release(self.context);
    }
};

pub const Source = struct {
    target: target.Ref,
    revision: []const u8,
};

pub const ValidationError = error{
    NoRepresentations,
    InvalidMediaType,
    InvalidAttachment,
    DuplicateRepresentation,
} || std.mem.Allocator.Error;

pub const Item = struct {
    intent: Intent,
    suggested_name: []const u8 = &.{},
    source: ?Source = null,
    representations: []const Representation,

    pub fn validate(self: Item, gpa: std.mem.Allocator) ValidationError!void {
        if (self.representations.len == 0) return error.NoRepresentations;
        var seen: std.StringHashMapUnmanaged(void) = .empty;
        defer seen.deinit(gpa);
        for (self.representations) |candidate| {
            if (candidate.media_type.len == 0) return error.InvalidMediaType;
            if (candidate.attachment) |attachment| {
                if (attachment.generation == 0) return error.InvalidAttachment;
            }
            const result = try seen.getOrPut(gpa, candidate.media_type);
            if (result.found_existing) return error.DuplicateRepresentation;
        }
    }

    pub fn representation(self: Item, media_type: []const u8) ?Representation {
        for (self.representations) |candidate|
            if (std.mem.eql(u8, candidate.media_type, media_type)) return candidate;
        return null;
    }
};

/// A clipboard/register owns its transfer independently of the view or plugin
/// instance that produced it. Every representation is immutable after capture,
/// so closing or reconciling the source cannot retarget a later paste.
pub const OwnedItem = struct {
    arena: std.heap.ArenaAllocator,
    value: Item = undefined,

    pub fn init(gpa: std.mem.Allocator, source_item: Item) ValidationError!OwnedItem {
        try source_item.validate(gpa);
        var owned: OwnedItem = .{ .arena = .init(gpa) };
        errdefer owned.deinit();
        const arena = owned.arena.allocator();
        owned.value = .{
            .intent = source_item.intent,
            .suggested_name = &.{},
            .source = null,
            .representations = &.{},
        };
        const representations = try arena.alloc(Representation, source_item.representations.len);
        @memset(representations, .{ .media_type = &.{}, .payload = &.{} });
        owned.value.representations = representations;
        for (source_item.representations, representations) |source, *destination| {
            destination.resource = source.resource;
            if (source.resource) |resource| resource.retain();
            destination.attachment = source.attachment;
            destination.media_type = try arena.dupe(u8, source.media_type);
            destination.schema = if (source.schema) |schema| try arena.dupe(u8, schema) else null;
            destination.payload = try arena.dupe(u8, source.payload);
        }
        owned.value.suggested_name = try arena.dupe(u8, source_item.suggested_name);
        owned.value.source = if (source_item.source) |source| .{
            .target = source.target,
            .revision = try arena.dupe(u8, source.revision),
        } else null;
        return owned;
    }

    pub fn deinit(self: *OwnedItem) void {
        for (self.value.representations) |representation|
            if (representation.resource) |resource| resource.release();
        self.arena.deinit();
        self.* = undefined;
    }

    /// Replace atomically from the caller's perspective: allocation and
    /// resource retention for the new item complete before the old item is
    /// released. A failed replacement therefore leaves the old transfer
    /// usable and still owning its resources.
    pub fn replace(self: *OwnedItem, gpa: std.mem.Allocator, source_item: Item) ValidationError!void {
        const next = try OwnedItem.init(gpa, source_item);
        self.deinit();
        self.* = next;
    }
};

test "transfer requires unique typed representations" {
    const reps = [_]Representation{
        .{ .media_type = "text/plain", .payload = "a" },
        .{ .media_type = "text/plain", .payload = "b" },
    };
    const item: Item = .{ .intent = .copy, .representations = &reps };
    try std.testing.expectError(error.DuplicateRepresentation, item.validate(std.testing.allocator));
}

test "transfer rejects malformed attachment generations before transport" {
    const reps = [_]Representation{.{
        .media_type = "application/test",
        .payload = "payload",
        .attachment = Attachment.fromWire(.{ .authority = 7, .slot = 1, .generation = 0 }),
    }};
    const item: Item = .{ .intent = .copy, .representations = &reps };
    try std.testing.expectError(error.InvalidAttachment, item.validate(std.testing.allocator));
}

test "owned transfer survives mutation of producer storage" {
    var name = [_]u8{ 'o', 'l', 'd' };
    var payload = [_]u8{ 'd', 'a', 't', 'a' };
    const reps = [_]Representation{.{ .media_type = "application/test", .payload = &payload }};
    var owned = try OwnedItem.init(std.testing.allocator, .{
        .intent = .copy,
        .suggested_name = &name,
        .representations = &reps,
    });
    defer owned.deinit();
    @memset(&name, 'x');
    @memset(&payload, 'x');
    try std.testing.expectEqualStrings("old", owned.value.suggested_name);
    try std.testing.expectEqualStrings("data", owned.value.representations[0].payload);
}

test "owned transfer replaces and releases host resources exactly once" {
    const Probe = struct {
        retains: usize = 0,
        releases: usize = 0,

        fn retain(raw: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.retains += 1;
        }

        fn release(raw: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.releases += 1;
        }
    };
    var first_probe: Probe = .{};
    var second_probe: Probe = .{};
    const first_resource: Resource = .{ .context = &first_probe, .vtable = &.{ .retain = Probe.retain, .release = Probe.release } };
    const second_resource: Resource = .{ .context = &second_probe, .vtable = &.{ .retain = Probe.retain, .release = Probe.release } };
    var item = try OwnedItem.init(std.testing.allocator, .{
        .intent = .copy,
        .representations = &.{.{ .media_type = "application/test", .payload = "one", .resource = first_resource }},
    });
    first_resource.release(); // relinquish the caller's initial reference
    try item.replace(std.testing.allocator, .{
        .intent = .copy,
        .representations = &.{.{ .media_type = "application/test", .payload = "two", .resource = second_resource }},
    });
    second_resource.release(); // relinquish the replacement caller reference
    defer item.deinit();
    try std.testing.expectEqual(@as(usize, 1), first_probe.retains);
    try std.testing.expectEqual(@as(usize, 2), first_probe.releases);
    try std.testing.expectEqual(@as(usize, 1), second_probe.retains);
    try std.testing.expectEqual(@as(usize, 1), second_probe.releases);
    try std.testing.expect(item.value.representations[0].resource != null);
}

test "retained resource survives an independent transfer copy" {
    const Probe = struct {
        retains: usize = 0,
        releases: usize = 0,

        fn retain(raw: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.retains += 1;
        }

        fn release(raw: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.releases += 1;
        }
    };
    var probe: Probe = .{};
    const resource: Resource = .{ .context = &probe, .vtable = &.{ .retain = Probe.retain, .release = Probe.release } };
    var source = try OwnedItem.init(std.testing.allocator, .{
        .intent = .copy,
        .representations = &.{.{ .media_type = "application/test", .payload = "data", .resource = resource }},
    });
    resource.release();
    var destination = try OwnedItem.init(std.testing.allocator, source.value);
    defer destination.deinit();
    source.deinit();
    try std.testing.expectEqual(@as(usize, 2), probe.retains);
    try std.testing.expectEqual(@as(usize, 2), probe.releases);
    try std.testing.expect(destination.value.representations[0].resource != null);
}
