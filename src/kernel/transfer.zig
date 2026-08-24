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

pub const Item = struct {
    intent: Intent,
    suggested_name: []const u8 = &.{},
    source: ?Source = null,
    representations: []const Representation,

    pub fn validate(self: Item, gpa: std.mem.Allocator) !void {
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

test "transfer requires unique typed representations" {
    const reps = [_]Representation{
        .{ .media_type = "text/plain", .payload = "a" },
        .{ .media_type = "text/plain", .payload = "b" },
    };
    const item: Item = .{ .intent = .copy, .representations = &reps };
    try std.testing.expectError(error.DuplicateRepresentation, item.validate(std.testing.allocator));
}
