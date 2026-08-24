//! Owner-scoped relation providers over immutable semantic targets.
//!
//! Relations are intentionally separate from target opening.  A filesystem
//! or document publisher can describe containment even when another plugin
//! owns the view handler for that target.  This registry only gathers edges;
//! semantic.Services validates destination authority, revision, and location.

const std = @import("std");
const semantic = @import("weft_semantic");

pub const ProviderTag = struct {};
pub const ProviderRef = semantic.handle.Handle(ProviderTag);

pub const Error = std.mem.Allocator.Error || error{
    InvalidProvider,
    DuplicateProvider,
    StaleProvider,
};

pub const QueryError = error{ Unavailable, InvalidRelation, StaleTarget, Failed };

pub const Query = struct {
    source: semantic.target.Located,
    name: []const u8,
    /// Optional provider-owned selector/argument. Core treats this as raw
    /// opaque bytes; an absent selector preserves the legacy query contract.
    argument: ?[]const u8 = null,
};

pub const standard = struct {
    /// Resolve one raw child name below a container target. The relation
    /// registry owns this vocabulary; target handlers remain independent.
    pub const child = "child";
};

pub const Relation = semantic.target.Relation;

pub const Provider = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        query: *const fn (*anyopaque, Query) QueryError!?Relation,
    };

    pub fn init(pointer: anytype) Provider {
        const Pointer = @TypeOf(pointer);
        const pointer_info = switch (@typeInfo(Pointer)) {
            .pointer => |info| info,
            else => @compileError("relation provider must be initialized from a pointer"),
        };
        if (pointer_info.size != .one or pointer_info.is_const)
            @compileError("relation provider requires a mutable single-item pointer");
        const Implementation = pointer_info.child;
        const Adapter = struct {
            fn self(raw: *anyopaque) *Implementation {
                return @ptrCast(@alignCast(raw));
            }
            fn query(raw: *anyopaque, request: Query) QueryError!?Relation {
                return self(raw).query(request);
            }
            const vtable: VTable = .{ .query = @This().query };
        };
        return .{ .context = pointer, .vtable = &Adapter.vtable };
    }

    pub fn query(self: Provider, request: Query) QueryError!?Relation {
        return self.vtable.query(self.context, request);
    }
};

pub const Descriptor = struct {
    ref: ProviderRef,
    owner: semantic.owner.Id,
    id: []const u8,
};

pub const Candidate = struct {
    provider: ProviderRef,
    relation: Relation,
};

pub const Failure = struct {
    provider: ProviderRef,
    reason: QueryError,
};

pub const Resolution = struct {
    candidates: []const Candidate,
    failures: []const Failure,
};

pub const OwnedResolution = struct {
    arena: std.heap.ArenaAllocator,
    value: Resolution = undefined,

    pub fn deinit(self: *OwnedResolution) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub const Registry = struct {
    authority: semantic.handle.Authority,
    slots: std.ArrayList(Slot) = .empty,

    const Slot = struct {
        generation: u32 = 1,
        instance: ?*Instance = null,
    };

    const Instance = struct {
        arena: std.heap.ArenaAllocator,
        descriptor: Descriptor,
        provider: Provider,

        fn create(
            gpa: std.mem.Allocator,
            ref: ProviderRef,
            owner: semantic.owner.Id,
            id: []const u8,
            provider: Provider,
        ) std.mem.Allocator.Error!*Instance {
            const self = try gpa.create(Instance);
            errdefer gpa.destroy(self);
            self.arena = .init(gpa);
            errdefer self.arena.deinit();
            self.descriptor = .{
                .ref = ref,
                .owner = owner,
                .id = try self.arena.allocator().dupe(u8, id),
            };
            self.provider = provider;
            return self;
        }

        fn destroy(self: *Instance, gpa: std.mem.Allocator) void {
            self.arena.deinit();
            gpa.destroy(self);
        }
    };

    pub fn init(authority: semantic.handle.Authority) Registry {
        return .{ .authority = authority };
    }

    pub fn deinit(self: *Registry, gpa: std.mem.Allocator) void {
        for (self.slots.items) |slot| if (slot.instance) |instance| instance.destroy(gpa);
        self.slots.deinit(gpa);
    }

    pub fn register(
        self: *Registry,
        gpa: std.mem.Allocator,
        owner: semantic.owner.Id,
        id: []const u8,
        provider: Provider,
    ) Error!ProviderRef {
        if (!owner.isValid() or id.len == 0) return error.InvalidProvider;
        for (self.slots.items) |slot| if (slot.instance) |instance|
            if (instance.descriptor.owner == owner and std.mem.eql(u8, instance.descriptor.id, id))
                return error.DuplicateProvider;
        for (self.slots.items, 0..) |*slot, index| {
            if (slot.instance != null) continue;
            const ref = self.refFor(index, slot.generation);
            slot.instance = try Instance.create(gpa, ref, owner, id, provider);
            return ref;
        }
        const index = self.slots.items.len;
        const ref = self.refFor(index, 1);
        const instance = try Instance.create(gpa, ref, owner, id, provider);
        errdefer instance.destroy(gpa);
        try self.slots.append(gpa, .{ .instance = instance });
        return ref;
    }

    pub fn descriptor(self: *const Registry, ref: ProviderRef) ?*const Descriptor {
        const instance = self.lookup(ref) orelse return null;
        return &instance.descriptor;
    }

    pub fn unregister(self: *Registry, gpa: std.mem.Allocator, ref: ProviderRef) bool {
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

    pub fn unregisterOwner(self: *Registry, gpa: std.mem.Allocator, owner: semantic.owner.Id) usize {
        var removed: usize = 0;
        for (self.slots.items) |*slot| {
            const instance = slot.instance orelse continue;
            if (instance.descriptor.owner != owner) continue;
            instance.destroy(gpa);
            slot.instance = null;
            slot.generation +%= 1;
            if (slot.generation == 0) slot.generation = 1;
            removed += 1;
        }
        return removed;
    }

    pub fn query(self: *const Registry, gpa: std.mem.Allocator, request: Query) std.mem.Allocator.Error!OwnedResolution {
        var owned: OwnedResolution = .{ .arena = .init(gpa) };
        errdefer owned.deinit();
        const arena = owned.arena.allocator();
        var candidates: std.ArrayList(Candidate) = .empty;
        defer candidates.deinit(arena);
        var failures: std.ArrayList(Failure) = .empty;
        defer failures.deinit(arena);
        for (self.slots.items) |slot| {
            const instance = slot.instance orelse continue;
            const relation = instance.provider.query(request) catch |reason| {
                try failures.append(arena, .{ .provider = instance.descriptor.ref, .reason = reason });
                continue;
            } orelse continue;
            try candidates.append(arena, .{
                .provider = instance.descriptor.ref,
                .relation = try cloneRelation(arena, relation),
            });
        }
        owned.value = .{
            .candidates = try arena.dupe(Candidate, candidates.items),
            .failures = try arena.dupe(Failure, failures.items),
        };
        return owned;
    }

    fn lookup(self: *const Registry, ref: ProviderRef) ?*const Instance {
        if (ref.authority != self.authority or ref.slot >= self.slots.items.len) return null;
        const slot = self.slots.items[ref.slot];
        if (slot.generation != ref.generation) return null;
        return slot.instance;
    }

    fn refFor(self: *const Registry, index: usize, generation: u32) ProviderRef {
        return .{ .authority = self.authority, .slot = @intCast(index), .generation = generation };
    }
};

fn cloneRelation(arena: std.mem.Allocator, relation: Relation) std.mem.Allocator.Error!Relation {
    var target = relation.target;
    target.location = switch (relation.target.location) {
        .whole => .whole,
        .text => |range| .{ .text = range },
        .node => |node| .{ .node = try arena.dupe(u8, node) },
        .provider => |provider| .{ .provider = .{
            .schema = try arena.dupe(u8, provider.schema),
            .payload = try arena.dupe(u8, provider.payload),
        } },
    };
    return .{ .name = try arena.dupe(u8, relation.name), .target = target };
}

test "relation providers are independent from target handlers" {
    const owner: semantic.owner.Id = @enumFromInt(1);
    const source: semantic.target.Located = .{ .target = .{ .authority = .here, .slot = 1, .generation = 1 }, .revision = 7 };
    const destination: semantic.target.Located = .{
        .target = .{ .authority = .here, .slot = 2, .generation = 1 },
        .revision = 9,
        .location = .{ .provider = .{ .schema = "tree", .payload = "root" } },
    };
    const RelationProvider = struct {
        destination: semantic.target.Located,
        pub fn query(self: *@This(), request: Query) QueryError!?Relation {
            if (!std.mem.eql(u8, request.name, "container")) return null;
            return .{ .name = request.name, .target = self.destination };
        }
    };
    var implementation = RelationProvider{ .destination = destination };
    var registry = Registry.init(.here);
    defer registry.deinit(std.testing.allocator);
    _ = try registry.register(std.testing.allocator, owner, "filesystem", .init(&implementation));
    var resolution = try registry.query(std.testing.allocator, .{ .source = source, .name = "container" });
    defer resolution.deinit();
    try std.testing.expectEqual(@as(usize, 1), resolution.value.candidates.len);
    const resolved = resolution.value.candidates[0].relation.target;
    try std.testing.expectEqual(destination.target, resolved.target);
    try std.testing.expectEqual(destination.revision, resolved.revision);
    switch (resolved.location) {
        .provider => |provider| {
            try std.testing.expectEqualStrings("tree", provider.schema);
            try std.testing.expectEqualStrings("root", provider.payload);
        },
        else => return error.TestUnexpectedResult,
    }
}
