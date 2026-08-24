//! Stable target identity and owned descriptors. Targets describe resources;
//! they do not choose the plugin or view that will handle them.

const std = @import("std");
const kernel = @import("weft_kernel");

pub const Error = std.mem.Allocator.Error || error{
    InvalidFact,
    DuplicateFact,
    StaleTarget,
};

pub const Instance = struct {
    arena: std.heap.ArenaAllocator,
    descriptor: kernel.target.Descriptor,

    fn create(
        gpa: std.mem.Allocator,
        ref: kernel.target.Ref,
        revision: u64,
        definition: kernel.target.Definition,
    ) Error!*Instance {
        try validate(gpa, definition);
        const self = try gpa.create(Instance);
        errdefer gpa.destroy(self);
        self.arena = .init(gpa);
        errdefer self.arena.deinit();
        const arena = self.arena.allocator();
        const facts = try arena.alloc(kernel.target.Fact, definition.facts.len);
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
    authority: kernel.handle.Authority,
    slots: std.ArrayList(Slot) = .empty,

    const Slot = struct {
        generation: u32 = 1,
        instance: ?*Instance = null,
    };

    pub fn init(authority: kernel.handle.Authority) Registry {
        return .{ .authority = authority };
    }

    pub fn deinit(self: *Registry, gpa: std.mem.Allocator) void {
        for (self.slots.items) |slot| if (slot.instance) |instance| instance.destroy(gpa);
        self.slots.deinit(gpa);
    }

    pub fn publish(
        self: *Registry,
        gpa: std.mem.Allocator,
        definition: kernel.target.Definition,
    ) Error!kernel.target.Ref {
        for (self.slots.items, 0..) |*slot, index| {
            if (slot.instance != null) continue;
            const ref = self.refFor(index, slot.generation);
            slot.instance = try Instance.create(gpa, ref, 1, definition);
            return ref;
        }
        const index = self.slots.items.len;
        const ref = self.refFor(index, 1);
        const instance = try Instance.create(gpa, ref, 1, definition);
        errdefer instance.destroy(gpa);
        try self.slots.append(gpa, .{ .instance = instance });
        return ref;
    }

    pub fn get(self: *const Registry, ref: kernel.target.Ref) ?*const kernel.target.Descriptor {
        if (ref.authority != self.authority or ref.slot >= self.slots.items.len) return null;
        const slot = self.slots.items[ref.slot];
        if (slot.generation != ref.generation) return null;
        const instance = slot.instance orelse return null;
        return &instance.descriptor;
    }

    pub fn replace(
        self: *Registry,
        gpa: std.mem.Allocator,
        ref: kernel.target.Ref,
        definition: kernel.target.Definition,
    ) Error!void {
        if (ref.authority != self.authority or ref.slot >= self.slots.items.len) return error.StaleTarget;
        const slot = &self.slots.items[ref.slot];
        if (slot.generation != ref.generation) return error.StaleTarget;
        const prior = slot.instance orelse return error.StaleTarget;
        const next = try Instance.create(gpa, ref, prior.descriptor.revision +| 1, definition);
        slot.instance = next;
        prior.destroy(gpa);
    }

    pub fn close(self: *Registry, gpa: std.mem.Allocator, ref: kernel.target.Ref) bool {
        if (ref.authority != self.authority or ref.slot >= self.slots.items.len) return false;
        const slot = &self.slots.items[ref.slot];
        if (slot.generation != ref.generation) return false;
        const instance = slot.instance orelse return false;
        instance.destroy(gpa);
        slot.instance = null;
        slot.generation +%= 1;
        if (slot.generation == 0) slot.generation = 1;
        return true;
    }

    fn refFor(self: *const Registry, index: usize, generation: u32) kernel.target.Ref {
        return .{ .authority = self.authority, .slot = @intCast(index), .generation = generation };
    }
};

fn validate(gpa: std.mem.Allocator, definition: kernel.target.Definition) Error!void {
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
    const ref = try targets.publish(std.testing.allocator, .{
        .kind = .directory,
        .display_name = "remote project",
        .facts = &.{.{ .name = "locus", .value = "peer:alice" }},
    });
    const before = targets.get(ref).?.revision;
    try targets.replace(std.testing.allocator, ref, .{
        .kind = .directory,
        .display_name = "renamed project",
        .facts = &.{.{ .name = "locus", .value = "peer:alice" }},
    });
    try std.testing.expectEqual(before + 1, targets.get(ref).?.revision);
    try std.testing.expectEqualStrings("renamed project", targets.get(ref).?.display_name);
    try std.testing.expect(targets.close(std.testing.allocator, ref));
    try std.testing.expect(targets.get(ref) == null);
}
