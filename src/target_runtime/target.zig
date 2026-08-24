//! Stable target identity and owned descriptors. Targets describe resources;
//! they do not choose the plugin or view that will handle them.

const std = @import("std");
const semantic = @import("weft_semantic");

pub const Error = std.mem.Allocator.Error || error{
    InvalidOwner,
    OwnerMismatch,
    InvalidFact,
    DuplicateFact,
    StaleTarget,
};

pub const Instance = struct {
    arena: std.heap.ArenaAllocator,
    owner: semantic.owner.Id,
    descriptor: semantic.target.Descriptor,

    fn create(
        gpa: std.mem.Allocator,
        owner: semantic.owner.Id,
        ref: semantic.target.Ref,
        revision: u64,
        definition: semantic.target.Definition,
    ) Error!*Instance {
        try validate(gpa, definition);
        const self = try gpa.create(Instance);
        errdefer gpa.destroy(self);
        self.arena = .init(gpa);
        errdefer self.arena.deinit();
        const arena = self.arena.allocator();
        self.owner = owner;
        const facts = try arena.alloc(semantic.target.Fact, definition.facts.len);
        for (definition.facts, facts) |source, *destination| destination.* = .{
            .name = try arena.dupe(u8, source.name),
            .value = try arena.dupe(u8, source.value),
        };
        self.descriptor = .{
            .ref = ref,
            .revision = revision,
            .kind = switch (definition.kind) {
                .synthetic => |kind| .{ .synthetic = try arena.dupe(u8, kind) },
                else => definition.kind,
            },
            .display_name = try arena.dupe(u8, definition.display_name),
            .facts = facts,
        };
        return self;
    }

    fn destroy(self: *Instance, gpa: std.mem.Allocator) void {
        self.arena.deinit();
        gpa.destroy(self);
    }
};

pub const Registry = struct {
    authority: semantic.handle.Authority,
    slots: std.ArrayList(Slot) = .empty,

    const Slot = struct {
        generation: u32 = 1,
        instance: ?*Instance = null,
    };

    pub fn init(authority: semantic.handle.Authority) Registry {
        return .{ .authority = authority };
    }

    pub fn deinit(self: *Registry, gpa: std.mem.Allocator) void {
        for (self.slots.items) |slot| if (slot.instance) |instance| instance.destroy(gpa);
        self.slots.deinit(gpa);
    }

    pub fn publish(
        self: *Registry,
        gpa: std.mem.Allocator,
        owner: semantic.owner.Id,
        definition: semantic.target.Definition,
    ) Error!semantic.target.Ref {
        if (!owner.isValid()) return error.InvalidOwner;
        for (self.slots.items, 0..) |*slot, index| {
            if (slot.instance != null) continue;
            const ref = self.refFor(index, slot.generation);
            slot.instance = try Instance.create(gpa, owner, ref, 1, definition);
            return ref;
        }
        const index = self.slots.items.len;
        const ref = self.refFor(index, 1);
        const instance = try Instance.create(gpa, owner, ref, 1, definition);
        errdefer instance.destroy(gpa);
        try self.slots.append(gpa, .{ .instance = instance });
        return ref;
    }

    pub fn get(self: *const Registry, ref: semantic.target.Ref) ?*const semantic.target.Descriptor {
        if (ref.authority != self.authority or ref.slot >= self.slots.items.len) return null;
        const slot = self.slots.items[ref.slot];
        if (slot.generation != ref.generation) return null;
        const instance = slot.instance orelse return null;
        return &instance.descriptor;
    }

    pub fn replace(
        self: *Registry,
        gpa: std.mem.Allocator,
        owner: semantic.owner.Id,
        ref: semantic.target.Ref,
        definition: semantic.target.Definition,
    ) Error!void {
        if (ref.authority != self.authority or ref.slot >= self.slots.items.len) return error.StaleTarget;
        const slot = &self.slots.items[ref.slot];
        if (slot.generation != ref.generation) return error.StaleTarget;
        const prior = slot.instance orelse return error.StaleTarget;
        if (prior.owner != owner) return error.OwnerMismatch;
        const next = try Instance.create(gpa, prior.owner, ref, prior.descriptor.revision +| 1, definition);
        slot.instance = next;
        prior.destroy(gpa);
    }

    pub fn close(self: *Registry, gpa: std.mem.Allocator, owner: semantic.owner.Id, ref: semantic.target.Ref) bool {
        if (ref.authority != self.authority or ref.slot >= self.slots.items.len) return false;
        const slot = &self.slots.items[ref.slot];
        if (slot.generation != ref.generation) return false;
        const instance = slot.instance orelse return false;
        if (instance.owner != owner) return false;
        self.retire(gpa, slot);
        return true;
    }

    pub fn closeOwner(self: *Registry, gpa: std.mem.Allocator, owner: semantic.owner.Id) usize {
        var closed: usize = 0;
        for (self.slots.items) |*slot| {
            const instance = slot.instance orelse continue;
            if (instance.owner != owner) continue;
            self.retire(gpa, slot);
            closed += 1;
        }
        return closed;
    }

    fn retire(_: *Registry, gpa: std.mem.Allocator, slot: *Slot) void {
        slot.instance.?.destroy(gpa);
        slot.instance = null;
        slot.generation +%= 1;
        if (slot.generation == 0) slot.generation = 1;
    }

    fn refFor(self: *const Registry, index: usize, generation: u32) semantic.target.Ref {
        return .{ .authority = self.authority, .slot = @intCast(index), .generation = generation };
    }
};

fn validate(gpa: std.mem.Allocator, definition: semantic.target.Definition) Error!void {
    var facts: std.StringHashMapUnmanaged(void) = .empty;
    defer facts.deinit(gpa);
    for (definition.facts) |fact| {
        if (fact.name.len == 0) return error.InvalidFact;
        const result = try facts.getOrPut(gpa, fact.name);
        if (result.found_existing) return error.DuplicateFact;
    }
}

test "target descriptors update without changing identity" {
    var targets = Registry.init(.here);
    defer targets.deinit(std.testing.allocator);
    const producer: semantic.owner.Id = @enumFromInt(1);
    const other: semantic.owner.Id = @enumFromInt(2);
    const ref = try targets.publish(std.testing.allocator, producer, .{
        .kind = .directory,
        .display_name = "remote project",
        .facts = &.{.{ .name = "locus", .value = "peer:alice" }},
    });
    const before = targets.get(ref).?.revision;
    try std.testing.expectError(error.OwnerMismatch, targets.replace(std.testing.allocator, other, ref, .{
        .kind = .directory,
        .display_name = "not theirs",
    }));
    try targets.replace(std.testing.allocator, producer, ref, .{
        .kind = .directory,
        .display_name = "renamed project",
        .facts = &.{.{ .name = "locus", .value = "peer:alice" }},
    });
    try std.testing.expectEqual(before + 1, targets.get(ref).?.revision);
    try std.testing.expectEqualStrings("renamed project", targets.get(ref).?.display_name);
    try std.testing.expect(!targets.close(std.testing.allocator, other, ref));
    try std.testing.expect(targets.close(std.testing.allocator, producer, ref));
    try std.testing.expect(targets.get(ref) == null);
}
