//! Provider discovery for targets. The registry gathers claims; it never lets
//! plugin registration order silently decide which handler wins a tie.

const std = @import("std");
const kernel = @import("weft_kernel");

pub const HandlerTag = struct {};
pub const HandlerRef = kernel.handle.Handle(HandlerTag);

pub const Strength = enum(u8) {
    fallback,
    compatible,
    preferred,
    exact,
};

pub const ProbeError = error{ Unavailable, InvalidTarget, Failed };
pub const OpenError = error{ StaleTarget, Unavailable, Rejected, Failed };

pub const Provider = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        probe: *const fn (*anyopaque, kernel.target.Descriptor) ProbeError!?Strength,
        open: *const fn (*anyopaque, kernel.target.Located) OpenError!kernel.view.Ref,
    };

    pub fn init(pointer: anytype) Provider {
        const Pointer = @TypeOf(pointer);
        const pointer_info = switch (@typeInfo(Pointer)) {
            .pointer => |info| info,
            else => @compileError("target handler must be initialized from a pointer"),
        };
        if (pointer_info.size != .one or pointer_info.is_const)
            @compileError("target handler requires a mutable single-item pointer");
        const Implementation = pointer_info.child;
        const Adapter = struct {
            fn self(raw: *anyopaque) *Implementation {
                return @ptrCast(@alignCast(raw));
            }
            fn probe(raw: *anyopaque, descriptor: kernel.target.Descriptor) ProbeError!?Strength {
                return self(raw).probe(descriptor);
            }
            fn open(raw: *anyopaque, located: kernel.target.Located) OpenError!kernel.view.Ref {
                return self(raw).open(located);
            }
            const vtable: VTable = .{ .probe = @This().probe, .open = @This().open };
        };
        return .{ .context = pointer, .vtable = &Adapter.vtable };
    }

    pub fn probe(self: Provider, descriptor: kernel.target.Descriptor) ProbeError!?Strength {
        return self.vtable.probe(self.context, descriptor);
    }

    pub fn open(self: Provider, located: kernel.target.Located) OpenError!kernel.view.Ref {
        return self.vtable.open(self.context, located);
    }
};

pub const HandlerDescriptor = struct {
    ref: HandlerRef,
    owner: []const u8,
    id: []const u8,
};

pub const Candidate = struct {
    handler: HandlerRef,
    strength: Strength,
};

pub const Failure = struct {
    handler: HandlerRef,
    reason: ProbeError,
};

pub const Decision = union(enum) {
    none,
    selected: HandlerRef,
    ambiguous: Strength,
};

pub const Resolution = struct {
    candidates: []const Candidate,
    failures: []const Failure,

    pub fn decide(self: Resolution) Decision {
        if (self.candidates.len == 0) return .none;
        var best = self.candidates[0];
        var count: usize = 1;
        for (self.candidates[1..]) |candidate| {
            if (@intFromEnum(candidate.strength) > @intFromEnum(best.strength)) {
                best = candidate;
                count = 1;
            } else if (candidate.strength == best.strength) {
                count += 1;
            }
        }
        return if (count == 1) .{ .selected = best.handler } else .{ .ambiguous = best.strength };
    }
};

pub const OwnedResolution = struct {
    arena: std.heap.ArenaAllocator,
    value: Resolution = undefined,

    pub fn deinit(self: *OwnedResolution) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub const Error = std.mem.Allocator.Error || error{
    InvalidHandler,
    DuplicateHandler,
    StaleHandler,
};

pub const Registry = struct {
    authority: kernel.handle.Authority,
    slots: std.ArrayList(Slot) = .empty,

    const Slot = struct {
        generation: u32 = 1,
        instance: ?*Instance = null,
    };

    const Instance = struct {
        arena: std.heap.ArenaAllocator,
        descriptor: HandlerDescriptor,
        provider: Provider,

        fn create(
            gpa: std.mem.Allocator,
            ref: HandlerRef,
            owner: []const u8,
            id: []const u8,
            provider: Provider,
        ) std.mem.Allocator.Error!*Instance {
            const self = try gpa.create(Instance);
            errdefer gpa.destroy(self);
            self.arena = .init(gpa);
            errdefer self.arena.deinit();
            const arena = self.arena.allocator();
            self.descriptor = .{
                .ref = ref,
                .owner = try arena.dupe(u8, owner),
                .id = try arena.dupe(u8, id),
            };
            self.provider = provider;
            return self;
        }

        fn destroy(self: *Instance, gpa: std.mem.Allocator) void {
            self.arena.deinit();
            gpa.destroy(self);
        }
    };

    pub fn init(authority: kernel.handle.Authority) Registry {
        return .{ .authority = authority };
    }

    pub fn deinit(self: *Registry, gpa: std.mem.Allocator) void {
        for (self.slots.items) |slot| if (slot.instance) |handler| handler.destroy(gpa);
        self.slots.deinit(gpa);
    }

    pub fn register(
        self: *Registry,
        gpa: std.mem.Allocator,
        owner: []const u8,
        id: []const u8,
        provider: Provider,
    ) Error!HandlerRef {
        if (owner.len == 0 or id.len == 0) return error.InvalidHandler;
        for (self.slots.items) |slot| if (slot.instance) |handler| {
            if (std.mem.eql(u8, handler.descriptor.owner, owner) and
                std.mem.eql(u8, handler.descriptor.id, id)) return error.DuplicateHandler;
        };
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

    pub fn descriptor(self: *const Registry, ref: HandlerRef) ?*const HandlerDescriptor {
        const handler = self.lookup(ref) orelse return null;
        return &handler.descriptor;
    }

    pub fn unregister(self: *Registry, gpa: std.mem.Allocator, ref: HandlerRef) bool {
        if (ref.authority != self.authority or ref.slot >= self.slots.items.len) return false;
        const slot = &self.slots.items[ref.slot];
        if (slot.generation != ref.generation) return false;
        const value = slot.instance orelse return false;
        value.destroy(gpa);
        slot.instance = null;
        slot.generation +%= 1;
        if (slot.generation == 0) slot.generation = 1;
        return true;
    }

    pub fn resolve(
        self: *const Registry,
        gpa: std.mem.Allocator,
        target_descriptor: kernel.target.Descriptor,
    ) std.mem.Allocator.Error!OwnedResolution {
        var owned: OwnedResolution = .{ .arena = .init(gpa) };
        errdefer owned.deinit();
        const arena = owned.arena.allocator();
        var candidates: std.ArrayList(Candidate) = .empty;
        defer candidates.deinit(arena);
        var failures: std.ArrayList(Failure) = .empty;
        defer failures.deinit(arena);
        for (self.slots.items) |slot| {
            const handler = slot.instance orelse continue;
            const strength = handler.provider.probe(target_descriptor) catch |reason| {
                try failures.append(arena, .{ .handler = handler.descriptor.ref, .reason = reason });
                continue;
            } orelse continue;
            try candidates.append(arena, .{ .handler = handler.descriptor.ref, .strength = strength });
        }
        owned.value = .{
            .candidates = try arena.dupe(Candidate, candidates.items),
            .failures = try arena.dupe(Failure, failures.items),
        };
        return owned;
    }

    pub fn open(self: *const Registry, ref: HandlerRef, located: kernel.target.Located) (Error || OpenError)!kernel.view.Ref {
        const handler = self.lookup(ref) orelse return error.StaleHandler;
        return handler.provider.open(located);
    }

    fn lookup(self: *const Registry, ref: HandlerRef) ?*const Instance {
        if (ref.authority != self.authority or ref.slot >= self.slots.items.len) return null;
        const slot = self.slots.items[ref.slot];
        if (slot.generation != ref.generation) return null;
        return slot.instance;
    }

    fn refFor(self: *const Registry, index: usize, generation: u32) HandlerRef {
        return .{ .authority = self.authority, .slot = @intCast(index), .generation = generation };
    }
};

fn fact(descriptor: kernel.target.Descriptor, name: []const u8) ?[]const u8 {
    for (descriptor.facts) |candidate|
        if (std.mem.eql(u8, candidate.name, name)) return candidate.value;
    return null;
}

test "directory handlers claim local and remote targets from the same facts" {
    const Directory = struct {
        opened: usize = 0,

        fn probe(_: *@This(), descriptor: kernel.target.Descriptor) ProbeError!?Strength {
            if (descriptor.kind != .directory) return null;
            return if (fact(descriptor, "locus") != null) .exact else .preferred;
        }

        fn open(self: *@This(), _: kernel.target.Located) OpenError!kernel.view.Ref {
            self.opened += 1;
            return .{ .authority = .here, .slot = 8, .generation = 1 };
        }
    };
    var directory: Directory = .{};
    var handlers = Registry.init(.here);
    defer handlers.deinit(std.testing.allocator);
    const handler = try handlers.register(std.testing.allocator, "dired", "directory", .init(&directory));
    const descriptor: kernel.target.Descriptor = .{
        .ref = .{ .authority = .here, .slot = 1, .generation = 1 },
        .kind = .directory,
        .display_name = "peer project",
        .facts = &.{.{ .name = "locus", .value = "peer:alice" }},
    };
    var resolution = try handlers.resolve(std.testing.allocator, descriptor);
    defer resolution.deinit();
    const selected = resolution.value.decide().selected;
    try std.testing.expect(selected.eql(handler));
    _ = try handlers.open(selected, .{ .target = descriptor.ref });
    try std.testing.expectEqual(@as(usize, 1), directory.opened);
}

test "equal handler claims are ambiguous rather than registration ordered" {
    const Synthetic = struct {
        fn probe(_: *@This(), descriptor: kernel.target.Descriptor) ProbeError!?Strength {
            return switch (descriptor.kind) {
                .synthetic => .exact,
                else => null,
            };
        }
        fn open(_: *@This(), _: kernel.target.Located) OpenError!kernel.view.Ref {
            return error.Rejected;
        }
    };
    var first: Synthetic = .{};
    var second: Synthetic = .{};
    var handlers = Registry.init(.here);
    defer handlers.deinit(std.testing.allocator);
    _ = try handlers.register(std.testing.allocator, "one", "logs", .init(&first));
    _ = try handlers.register(std.testing.allocator, "two", "logs", .init(&second));
    const descriptor: kernel.target.Descriptor = .{
        .ref = .{ .authority = .here, .slot = 2, .generation = 1 },
        .kind = .{ .synthetic = "logs" },
        .display_name = "logs",
    };
    var resolution = try handlers.resolve(std.testing.allocator, descriptor);
    defer resolution.deinit();
    try std.testing.expect(resolution.value.decide() == .ambiguous);
}

test "probe failures remain visible without suppressing valid claims" {
    const Broken = struct {
        fail: bool,
        fn probe(self: *@This(), _: kernel.target.Descriptor) ProbeError!?Strength {
            if (self.fail) return error.Unavailable;
            return .compatible;
        }
        fn open(_: *@This(), _: kernel.target.Located) OpenError!kernel.view.Ref {
            return error.Rejected;
        }
    };
    var broken: Broken = .{ .fail = true };
    var healthy: Broken = .{ .fail = false };
    var handlers = Registry.init(.here);
    defer handlers.deinit(std.testing.allocator);
    _ = try handlers.register(std.testing.allocator, "broken", "handler", .init(&broken));
    _ = try handlers.register(std.testing.allocator, "healthy", "handler", .init(&healthy));
    const descriptor: kernel.target.Descriptor = .{
        .ref = .{ .authority = .here, .slot = 3, .generation = 1 },
        .kind = .file,
        .display_name = "file",
    };
    var resolution = try handlers.resolve(std.testing.allocator, descriptor);
    defer resolution.deinit();
    try std.testing.expectEqual(@as(usize, 1), resolution.value.candidates.len);
    try std.testing.expectEqual(@as(usize, 1), resolution.value.failures.len);
    try std.testing.expect(resolution.value.decide() == .selected);
}
