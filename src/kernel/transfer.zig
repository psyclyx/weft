//! Portable, multi-representation transfer values.

const std = @import("std");
const target = @import("target.zig");

pub const Intent = enum { copy, cut };

pub const Representation = struct {
    media_type: []const u8,
    schema: ?[]const u8 = null,
    payload: []const u8,
};

pub const Source = struct {
    target: target.Ref,
    revision: []const u8,
};

pub const ValidationError = error{
    NoRepresentations,
    InvalidMediaType,
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
        const representations = try arena.alloc(Representation, source_item.representations.len);
        for (source_item.representations, representations) |source, *destination| destination.* = .{
            .media_type = try arena.dupe(u8, source.media_type),
            .schema = if (source.schema) |schema| try arena.dupe(u8, schema) else null,
            .payload = try arena.dupe(u8, source.payload),
        };
        owned.value = .{
            .intent = source_item.intent,
            .suggested_name = try arena.dupe(u8, source_item.suggested_name),
            .source = if (source_item.source) |source| .{
                .target = source.target,
                .revision = try arena.dupe(u8, source.revision),
            } else null,
            .representations = representations,
        };
        return owned;
    }

    pub fn deinit(self: *OwnedItem) void {
        self.arena.deinit();
        self.* = undefined;
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
