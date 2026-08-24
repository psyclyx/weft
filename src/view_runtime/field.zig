//! Generic editable byte fields. Text documents and tool-owned names adapt to
//! this same contract; modal policy and filesystem meaning live above it.

const std = @import("std");
const kernel = @import("weft_kernel");

pub const Selection = struct {
    anchor: u64,
    caret: u64,
};

pub const Snapshot = struct {
    revision: []const u8,
    bytes: []const u8,
    selection: Selection,
    read_only: bool = false,
    single_line: bool = false,
};

pub const OwnedSnapshot = struct {
    arena: std.heap.ArenaAllocator,
    value: Snapshot = undefined,

    pub fn init(gpa: std.mem.Allocator) OwnedSnapshot {
        return .{ .arena = .init(gpa) };
    }

    pub fn allocator(self: *OwnedSnapshot) std.mem.Allocator {
        return self.arena.allocator();
    }

    pub fn deinit(self: *OwnedSnapshot) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub const Edit = struct {
    start: u64,
    end: u64,
    replacement: []const u8,
    selection_after: ?Selection = null,
};

pub const Error = error{ InvalidRange, Stale, ReadOnly, Unsupported } || std.mem.Allocator.Error;

pub const Provider = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        snapshot: *const fn (*anyopaque, std.mem.Allocator) Error!OwnedSnapshot,
        edit: *const fn (*anyopaque, []const u8, Edit) Error!void,
    };

    pub fn init(pointer: anytype) Provider {
        const Pointer = @TypeOf(pointer);
        const pointer_info = switch (@typeInfo(Pointer)) {
            .pointer => |info| info,
            else => @compileError("field provider must be initialized from a pointer"),
        };
        if (pointer_info.size != .one or pointer_info.is_const)
            @compileError("field provider requires a mutable single-item pointer");
        const Implementation = pointer_info.child;
        const Adapter = struct {
            fn self(raw: *anyopaque) *Implementation {
                return @ptrCast(@alignCast(raw));
            }
            fn snapshot(raw: *anyopaque, gpa: std.mem.Allocator) Error!OwnedSnapshot {
                return self(raw).snapshot(gpa);
            }
            fn edit(raw: *anyopaque, expected_revision: []const u8, value: Edit) Error!void {
                return self(raw).edit(expected_revision, value);
            }
            const vtable: VTable = .{ .snapshot = @This().snapshot, .edit = @This().edit };
        };
        return .{ .context = pointer, .vtable = &Adapter.vtable };
    }

    pub fn snapshot(self: Provider, gpa: std.mem.Allocator) Error!OwnedSnapshot {
        var result = try self.vtable.snapshot(self.context, gpa);
        errdefer result.deinit();
        if (result.value.selection.anchor > result.value.bytes.len or
            result.value.selection.caret > result.value.bytes.len)
            return error.InvalidRange;
        return result;
    }

    pub fn edit(self: Provider, expected_revision: []const u8, value: Edit) Error!void {
        if (value.start > value.end) return error.InvalidRange;
        return self.vtable.edit(self.context, expected_revision, value);
    }
};

/// Generation-checked field endpoints. Views carry only `FieldRef`; this
/// table remains the sole place that can turn one into behavior.
pub const Registry = struct {
    authority: kernel.handle.Authority,
    slots: std.ArrayList(Slot) = .empty,

    const Slot = struct {
        generation: u32 = 1,
        provider: ?Provider = null,
    };

    pub fn init(authority: kernel.handle.Authority) Registry {
        return .{ .authority = authority };
    }

    pub fn deinit(self: *Registry, gpa: std.mem.Allocator) void {
        self.slots.deinit(gpa);
    }

    pub fn insert(self: *Registry, gpa: std.mem.Allocator, provider: Provider) std.mem.Allocator.Error!kernel.scene.FieldRef {
        for (self.slots.items, 0..) |*slot, index| {
            if (slot.provider == null) {
                slot.provider = provider;
                return .{ .authority = self.authority, .slot = @intCast(index), .generation = slot.generation };
            }
        }
        try self.slots.append(gpa, .{ .provider = provider });
        return .{ .authority = self.authority, .slot = @intCast(self.slots.items.len - 1), .generation = 1 };
    }

    pub fn get(self: *Registry, ref: kernel.scene.FieldRef) ?Provider {
        if (ref.authority != self.authority or ref.slot >= self.slots.items.len) return null;
        const slot = &self.slots.items[ref.slot];
        if (slot.generation != ref.generation) return null;
        return slot.provider;
    }

    pub fn remove(self: *Registry, ref: kernel.scene.FieldRef) bool {
        if (ref.authority != self.authority or ref.slot >= self.slots.items.len) return false;
        const slot = &self.slots.items[ref.slot];
        if (slot.generation != ref.generation or slot.provider == null) return false;
        slot.provider = null;
        slot.generation +%= 1;
        if (slot.generation == 0) slot.generation = 1;
        return true;
    }
};

test "field registry rejects a removed generation" {
    const Memory = struct {
        fn snapshot(_: *@This(), gpa: std.mem.Allocator) Error!OwnedSnapshot {
            var result = OwnedSnapshot.init(gpa);
            errdefer result.deinit();
            const arena = result.allocator();
            result.value = .{ .revision = try arena.dupe(u8, "1"), .bytes = try arena.dupe(u8, "name"), .selection = .{ .anchor = 0, .caret = 0 } };
            return result;
        }
        fn edit(_: *@This(), _: []const u8, _: Edit) Error!void {}
    };
    var memory: Memory = .{};
    var fields = Registry.init(.here);
    defer fields.deinit(std.testing.allocator);
    const first = try fields.insert(std.testing.allocator, .init(&memory));
    try std.testing.expect(fields.get(first) != null);
    try std.testing.expect(fields.remove(first));
    try std.testing.expect(fields.get(first) == null);
    const second = try fields.insert(std.testing.allocator, .init(&memory));
    try std.testing.expectEqual(first.slot, second.slot);
    try std.testing.expect(first.generation != second.generation);
}

test "field provider rejects malformed values at its boundary" {
    const Invalid = struct {
        edits: usize = 0,

        fn snapshot(_: *@This(), gpa: std.mem.Allocator) Error!OwnedSnapshot {
            var result = OwnedSnapshot.init(gpa);
            result.value = .{
                .revision = "1",
                .bytes = "x",
                .selection = .{ .anchor = 2, .caret = 2 },
            };
            return result;
        }

        fn edit(self: *@This(), _: []const u8, _: Edit) Error!void {
            self.edits += 1;
        }
    };
    var invalid: Invalid = .{};
    const provider = Provider.init(&invalid);
    try std.testing.expectError(error.InvalidRange, provider.snapshot(std.testing.allocator));
    try std.testing.expectError(error.InvalidRange, provider.edit("1", .{ .start = 2, .end = 1, .replacement = "" }));
    try std.testing.expectEqual(@as(usize, 0), invalid.edits);
}
