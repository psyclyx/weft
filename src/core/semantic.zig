//! System-scoped ownership of the semantic runtime registries. This is wiring,
//! not a policy object: each registry keeps its own narrow contract and can be
//! consumed independently through `command.Context.semantic`.

const std = @import("std");
const kernel = @import("weft_kernel");
const target_runtime = @import("weft_target_runtime");
const view_runtime = @import("weft_view_runtime");

pub const Services = struct {
    targets: target_runtime.target.Registry,
    target_handlers: target_runtime.resolver.Registry,
    views: view_runtime.view.Registry,
    fields: view_runtime.field.Registry,
    actions: view_runtime.action.Registry = .{},
    transfer: ?kernel.transfer.OwnedItem = null,

    pub fn init(authority: kernel.handle.Authority) Services {
        return .{
            .targets = .init(authority),
            .target_handlers = .init(authority),
            .views = .init(authority),
            .fields = .init(authority),
        };
    }

    pub fn deinit(self: *Services, gpa: std.mem.Allocator) void {
        // Providers are non-owning and must already have unregistered before
        // their plugin dies. The registries only release retained descriptors.
        if (self.transfer) |*item| item.deinit();
        self.actions.deinit(gpa);
        self.fields.deinit(gpa);
        self.views.deinit(gpa);
        self.target_handlers.deinit(gpa);
        self.targets.deinit(gpa);
        self.* = undefined;
    }

    pub const OpenInteractionError = view_runtime.interaction.Error || error{
        StaleView,
        UnknownRoot,
    };

    pub const InvokeActionError = view_runtime.action.Error || OpenInteractionError || kernel.transfer.ValidationError;

    pub const ActionEffect = union(enum) {
        declined,
        handled,
        transfer_stored,
        interaction_opened: kernel.interaction.Ref,
    };

    /// Invoke against the view owner's provider, then absorb any cross-view
    /// effect into the correct lifetime: transfers become system-owned and
    /// dialogs become head-owned. Provider memory never escapes the call.
    pub fn invokeAction(
        self: *Services,
        stack: *view_runtime.interaction.Stack,
        gpa: std.mem.Allocator,
        request: kernel.action.Request,
    ) InvokeActionError!ActionEffect {
        var with_transfer = request;
        if (with_transfer.transfer == null) {
            if (self.transfer) |*item| with_transfer.transfer = item.value;
        }
        const outcome = try self.actions.invoke(&self.views, with_transfer);
        return switch (outcome) {
            .declined => .declined,
            .handled => .handled,
            .transfer => |item| blk: {
                var owned = try kernel.transfer.OwnedItem.init(gpa, item);
                errdefer owned.deinit();
                if (self.transfer) |*prior| prior.deinit();
                self.transfer = owned;
                break :blk .transfer_stored;
            },
            .interaction => |definition| .{ .interaction_opened = try self.openInteraction(stack, gpa, definition) },
        };
    }

    /// Compose two otherwise-independent mechanisms at their one real
    /// invariant: an interaction root must name a node in its declared view.
    pub fn openInteraction(
        self: *const Services,
        stack: *view_runtime.interaction.Stack,
        gpa: std.mem.Allocator,
        definition: kernel.interaction.Definition,
    ) OpenInteractionError!kernel.interaction.Ref {
        const instance = self.views.get(definition.view) orelse return error.StaleView;
        if (instance.node(definition.root) == null) return error.UnknownRoot;
        return stack.open(gpa, definition);
    }
};

test "semantic services keep target, view, and field namespaces typed" {
    var services = Services.init(.here);
    defer services.deinit(std.testing.allocator);
    const target_ref = try services.targets.publish(std.testing.allocator, .{
        .kind = .directory,
        .display_name = "directory",
    });
    const view_ref = try services.views.publish(std.testing.allocator, "test", target_ref, 1, .{
        .id = @enumFromInt(1),
        .actions = &.{
            .{ .id = kernel.action.standard.copy },
            .{ .id = kernel.action.standard.paste_after },
            .{ .id = "confirm" },
        },
        .content = .{ .label = "directory" },
    });
    try std.testing.expect(services.targets.get(target_ref) != null);
    try std.testing.expect(services.views.get(view_ref) != null);

    var interactions: view_runtime.interaction.Stack = .empty;
    defer interactions.deinit(std.testing.allocator);
    _ = try services.openInteraction(&interactions, std.testing.allocator, .{
        .role = .dialog,
        .view = view_ref,
        .root = @enumFromInt(1),
        .actions = &.{.{ .id = "ok", .label = "OK" }},
    });
    try std.testing.expect(interactions.active() != null);

    const Handler = struct {
        view: kernel.view.Ref,

        pub fn invoke(self: *@This(), request: kernel.action.Request) view_runtime.action.ProviderError!kernel.action.Outcome {
            if (std.mem.eql(u8, request.action, kernel.action.standard.copy)) return .{ .transfer = .{
                .intent = .copy,
                .suggested_name = "directory",
                .representations = &.{.{ .media_type = "application/test", .payload = "snapshot" }},
            } };
            if (std.mem.eql(u8, request.action, kernel.action.standard.paste_after))
                return if (request.transfer != null) .handled else error.Failed;
            return .{ .interaction = .{
                .role = .dialog,
                .view = self.view,
                .root = @enumFromInt(1),
                .actions = &.{.{ .id = "ok", .label = "OK" }},
            } };
        }
    };
    var handler: Handler = .{ .view = view_ref };
    try services.actions.register(std.testing.allocator, "test", .init(&handler));
    const request: kernel.action.Request = .{
        .action = kernel.action.standard.copy,
        .view = view_ref,
        .subject = @enumFromInt(1),
    };
    try std.testing.expect((try services.invokeAction(&interactions, std.testing.allocator, request)) == .transfer_stored);
    try std.testing.expectEqualStrings("snapshot", services.transfer.?.value.representations[0].payload);
    var paste = request;
    paste.action = kernel.action.standard.paste_after;
    try std.testing.expect((try services.invokeAction(&interactions, std.testing.allocator, paste)) == .handled);
    var confirm = request;
    confirm.action = "confirm";
    try std.testing.expect((try services.invokeAction(&interactions, std.testing.allocator, confirm)) == .interaction_opened);
}
