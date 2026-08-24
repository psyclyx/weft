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
        self.fields.deinit(gpa);
        self.views.deinit(gpa);
        self.target_handlers.deinit(gpa);
        self.targets.deinit(gpa);
        self.* = undefined;
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
        .content = .{ .label = "directory" },
    });
    try std.testing.expect(services.targets.get(target_ref) != null);
    try std.testing.expect(services.views.get(view_ref) != null);
}
