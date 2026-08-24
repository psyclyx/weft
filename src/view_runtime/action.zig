//! Dispatch semantic actions to the provider that owns the subject view.
//! Input plugins name intent; they never need to know the tool implementation.

const std = @import("std");
const semantic = @import("weft_semantic");
const view_runtime = @import("view.zig");

pub const ProviderError = error{ Rejected, Stale, Failed };

pub const Provider = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        invoke: *const fn (*anyopaque, semantic.action.Request) ProviderError!semantic.action.Outcome,
    };

    pub fn init(pointer: anytype) Provider {
        const Pointer = @TypeOf(pointer);
        const pointer_info = switch (@typeInfo(Pointer)) {
            .pointer => |info| info,
            else => @compileError("action provider must be initialized from a pointer"),
        };
        if (pointer_info.size != .one or pointer_info.is_const)
            @compileError("action provider requires a mutable single-item pointer");
        const Implementation = pointer_info.child;
        const Adapter = struct {
            fn self(raw: *anyopaque) *Implementation {
                return @ptrCast(@alignCast(raw));
            }
            fn invoke(raw: *anyopaque, request: semantic.action.Request) ProviderError!semantic.action.Outcome {
                return self(raw).invoke(request);
            }
            const vtable: VTable = .{ .invoke = @This().invoke };
        };
        return .{ .context = pointer, .vtable = &Adapter.vtable };
    }

    pub fn invoke(self: Provider, request: semantic.action.Request) ProviderError!semantic.action.Outcome {
        return self.vtable.invoke(self.context, request);
    }
};

pub const Error = std.mem.Allocator.Error || ProviderError || error{
    InvalidOwner,
    DuplicateOwner,
    StaleView,
    UnknownSubject,
    InvalidSelection,
    ActionUnavailable,
    ProviderUnavailable,
};

pub const Registry = struct {
    entries: std.ArrayList(Entry) = .empty,

    const Entry = struct {
        owner: semantic.owner.Id,
        provider: Provider,
    };

    pub fn deinit(self: *Registry, gpa: std.mem.Allocator) void {
        self.entries.deinit(gpa);
    }

    pub fn register(self: *Registry, gpa: std.mem.Allocator, owner: semantic.owner.Id, provider: Provider) Error!void {
        if (!owner.isValid()) return error.InvalidOwner;
        if (self.find(owner) != null) return error.DuplicateOwner;
        try self.entries.append(gpa, .{ .owner = owner, .provider = provider });
    }

    pub fn unregister(self: *Registry, _: std.mem.Allocator, owner: semantic.owner.Id) bool {
        for (self.entries.items, 0..) |entry, index| {
            if (entry.owner != owner) continue;
            _ = self.entries.swapRemove(index);
            return true;
        }
        return false;
    }

    pub fn invoke(
        self: *const Registry,
        views: *const view_runtime.Registry,
        request: semantic.action.Request,
    ) Error!semantic.action.Outcome {
        const view_instance = views.get(request.view) orelse return error.StaleView;
        const subject = view_instance.node(request.subject) orelse return error.UnknownSubject;
        var advertised = false;
        for (subject.actions) |action| {
            if (!std.mem.eql(u8, action.id, request.action)) continue;
            if (!action.enabled) return error.ActionUnavailable;
            advertised = true;
            break;
        }
        if (!advertised) return error.ActionUnavailable;
        return invokeProvider(self, view_instance, request);
    }

    /// Invoke an action already authorized by an active interaction. The
    /// interaction declaration is the action advertisement; requiring the
    /// underlying scene node to duplicate it would couple dialogs to tool
    /// projections and make local bindings indistinguishable from globals.
    pub fn invokeInteraction(
        self: *const Registry,
        views: *const view_runtime.Registry,
        request: semantic.action.Request,
    ) Error!semantic.action.Outcome {
        const view_instance = views.get(request.view) orelse return error.StaleView;
        if (view_instance.node(request.subject) == null) return error.UnknownSubject;
        return invokeProvider(self, view_instance, request);
    }

    fn invokeProvider(
        self: *const Registry,
        view_instance: *const view_runtime.Instance,
        request: semantic.action.Request,
    ) Error!semantic.action.Outcome {
        if (!selectionBelongsToView(view_instance, request.selection)) return error.InvalidSelection;
        const provider = self.find(view_instance.descriptor.owner) orelse return error.ProviderUnavailable;
        return provider.invoke(request);
    }

    fn find(self: *const Registry, owner: semantic.owner.Id) ?Provider {
        for (self.entries.items) |entry|
            if (entry.owner == owner) return entry.provider;
        return null;
    }
};

fn selectionBelongsToView(instance: *const view_runtime.Instance, selection: semantic.selection.Selection) bool {
    return switch (selection) {
        .none, .custom => true,
        .nodes => |nodes| blk: {
            for (nodes) |node| if (instance.node(node) == null) break :blk false;
            break :blk true;
        },
        .text => |range| blk: {
            if (range.start > range.end) break :blk false;
            break :blk nodeHasField(&instance.scene, range.field);
        },
    };
}

fn nodeHasField(node: *const semantic.scene.Node, field: semantic.scene.FieldRef) bool {
    switch (node.content) {
        .field => |value| if (value.ref.eql(field)) return true,
        .container => |container| for (container.children) |*child|
            if (nodeHasField(child, field)) return true,
        else => {},
    }
    return false;
}

test "an input action routes by view ownership and advertised node action" {
    const owner: semantic.owner.Id = @enumFromInt(1);
    const Handler = struct {
        calls: usize = 0,
        fn invoke(self: *@This(), _: semantic.action.Request) ProviderError!semantic.action.Outcome {
            self.calls += 1;
            return .handled;
        }
    };
    const child: semantic.scene.Node = .{
        .id = @enumFromInt(2),
        .focusable = true,
        .actions = &.{.{ .id = semantic.action.standard.delete, .label = "Delete" }},
        .content = .{ .label = "row" },
    };
    const root: semantic.scene.Node = .{
        .id = @enumFromInt(1),
        .content = .{ .container = .{ .children = &.{child} } },
    };
    var views = view_runtime.Registry.init(.here);
    defer views.deinit(std.testing.allocator);
    const view_ref = try views.publish(std.testing.allocator, owner, null, 1, root);
    var handler: Handler = .{};
    var actions: Registry = .{};
    defer actions.deinit(std.testing.allocator);
    try actions.register(std.testing.allocator, owner, .init(&handler));
    const outcome = try actions.invoke(&views, .{
        .action = semantic.action.standard.delete,
        .view = view_ref,
        .subject = @enumFromInt(2),
        .selection = .{ .nodes = &.{@enumFromInt(2)} },
    });
    try std.testing.expect(outcome == .handled);
    try std.testing.expectEqual(@as(usize, 1), handler.calls);
}

test "actions not advertised by the subject are unavailable" {
    const owner: semantic.owner.Id = @enumFromInt(1);
    const Handler = struct {
        fn invoke(_: *@This(), _: semantic.action.Request) ProviderError!semantic.action.Outcome {
            return .handled;
        }
    };
    const root: semantic.scene.Node = .{ .id = @enumFromInt(1), .content = .{ .label = "row" } };
    var views = view_runtime.Registry.init(.here);
    defer views.deinit(std.testing.allocator);
    const view_ref = try views.publish(std.testing.allocator, owner, null, 1, root);
    var handler: Handler = .{};
    var actions: Registry = .{};
    defer actions.deinit(std.testing.allocator);
    try actions.register(std.testing.allocator, owner, .init(&handler));
    try std.testing.expectError(error.ActionUnavailable, actions.invoke(&views, .{
        .action = semantic.action.standard.delete,
        .view = view_ref,
        .subject = @enumFromInt(1),
    }));
    try std.testing.expect((try actions.invokeInteraction(&views, .{
        .action = "dialog.confirm",
        .view = view_ref,
        .subject = @enumFromInt(1),
    })) == .handled);
}
