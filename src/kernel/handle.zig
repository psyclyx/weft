//! Opaque, generation-checked handles shared by kernel contracts.
//!
//! A handle is portable between view instances in one authority, but it is
//! never an OS descriptor or a pointer.  The table that minted it remains the
//! only place that can interpret its slot.

const std = @import("std");

pub const Authority = enum(u32) {
    here = 0,
    _,
};

pub const Wire = extern struct {
    authority: u32,
    slot: u32,
    generation: u32,
};

/// A phantom-typed handle. Marker is intentionally zero-runtime-cost: it
/// prevents mixing a Target handle with a View or Field handle in native code
/// while every handle retains the same stable wire shape.
pub fn Handle(comptime Marker: type) type {
    return struct {
        authority: Authority,
        slot: u32,
        generation: u32,

        const Self = @This();
        pub const marker = Marker;

        pub fn fromWire(wire: Wire) Self {
            return .{
                .authority = @enumFromInt(wire.authority),
                .slot = wire.slot,
                .generation = wire.generation,
            };
        }

        pub fn toWire(self: Self) Wire {
            return .{
                .authority = @intFromEnum(self.authority),
                .slot = self.slot,
                .generation = self.generation,
            };
        }
    };
}

/// Minimal owning registry used by host services. Authorization remains a
/// concern of the service that owns the table; this type only establishes
/// authority and lifetime identity.
pub fn Table(comptime Marker: type, comptime T: type) type {
    return struct {
        authority: Authority,
        slots: std.ArrayList(Slot) = .empty,

        const Self = @This();
        pub const Ref = Handle(Marker);

        const Slot = struct {
            generation: u32 = 1,
            value: ?T = null,
        };

        pub fn init(authority: Authority) Self {
            return .{ .authority = authority };
        }

        pub fn deinit(self: *Self, gpa: std.mem.Allocator) void {
            self.slots.deinit(gpa);
        }

        pub fn insert(self: *Self, gpa: std.mem.Allocator, value: T) !Ref {
            for (self.slots.items, 0..) |*slot, i| {
                if (slot.value == null) {
                    slot.value = value;
                    return .{
                        .authority = self.authority,
                        .slot = @intCast(i),
                        .generation = slot.generation,
                    };
                }
            }
            try self.slots.append(gpa, .{ .value = value });
            return .{
                .authority = self.authority,
                .slot = @intCast(self.slots.items.len - 1),
                .generation = self.slots.items[self.slots.items.len - 1].generation,
            };
        }

        pub fn get(self: *Self, ref: Ref) ?*T {
            if (ref.authority != self.authority or ref.slot >= self.slots.items.len) return null;
            const slot = &self.slots.items[ref.slot];
            if (slot.generation != ref.generation) return null;
            return if (slot.value) |*value| value else null;
        }

        pub fn getConst(self: *const Self, ref: Ref) ?*const T {
            if (ref.authority != self.authority or ref.slot >= self.slots.items.len) return null;
            const slot = &self.slots.items[ref.slot];
            if (slot.generation != ref.generation) return null;
            return if (slot.value) |*value| value else null;
        }

        pub fn remove(self: *Self, ref: Ref) ?T {
            if (ref.authority != self.authority or ref.slot >= self.slots.items.len) return null;
            const slot = &self.slots.items[ref.slot];
            if (slot.generation != ref.generation) return null;
            const value = slot.value orelse return null;
            slot.value = null;
            slot.generation +%= 1;
            if (slot.generation == 0) slot.generation = 1;
            return value;
        }
    };
}

test "table rejects stale and foreign handles" {
    const Marker = struct {};
    var table = Table(Marker, u32).init(.here);
    defer table.deinit(std.testing.allocator);

    const first = try table.insert(std.testing.allocator, 7);
    try std.testing.expectEqual(@as(u32, 7), table.get(first).?.*);
    try std.testing.expectEqual(@as(u32, 7), table.remove(first).?);
    try std.testing.expect(table.get(first) == null);

    const second = try table.insert(std.testing.allocator, 9);
    try std.testing.expectEqual(first.slot, second.slot);
    try std.testing.expect(first.generation != second.generation);
    try std.testing.expect(table.get(first) == null);

    var foreign = second;
    foreign.authority = @enumFromInt(42);
    try std.testing.expect(table.get(foreign) == null);
}
