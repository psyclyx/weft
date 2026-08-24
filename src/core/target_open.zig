//! Generic target opening for the core command surface.
//!
//! A target is already a semantic identity: this module does not inspect its
//! kind, derive a path, or name a tool.  It asks the system's registered
//! handlers to claim the target, reports an unhandled or ambiguous claim
//! explicitly, and focuses the selected view on the dispatching head.
//!
//! Path-to-target publication is deliberately not hidden here.  The local and
//! remote filesystem routers are not yet system-wired at this layer; ordinary
//! `open` therefore retains its ordinary file handler/fallback until a caller
//! publishes a typed target through its filesystem provider.

const std = @import("std");
const semantic_model = @import("weft_semantic");
const target_runtime = @import("weft_target_runtime");

const Head = @import("Head.zig");
const Services = @import("semantic.zig").Services;

pub const Match = target_runtime.resolver.Strength;

pub const Result = union(enum) {
    opened: struct {
        view: semantic_model.view.Ref,
        node: semantic_model.scene.NodeId,
    },
    no_handler,
    ambiguous: struct {
        strength: Match,
        count: usize,
    },
};

pub const Error = Services.ResolveTargetError || Services.OpenTargetError || Services.FocusError || Services.FocusedTargetError;

/// Resolve, open, and focus one target on one head.
///
/// The target descriptor revision is captured by `resolveTarget` and checked
/// again by `openTarget`; a filesystem or plugin update between those steps
/// therefore produces `error.StaleTarget`, never a silent retarget.  Equal
/// strongest claims are returned as `.ambiguous`; this function never lets
/// registration order choose for the caller.
pub fn open(
    services: *Services,
    head: *Head,
    gpa: std.mem.Allocator,
    target: semantic_model.target.Ref,
    location: semantic_model.target.Location,
    preferred: ?semantic_model.scene.NodeId,
) Error!Result {
    const descriptor = services.targets.get(target) orelse return error.StaleTarget;
    return admitAndFocus(services, head, gpa, .{
        .target = target,
        .revision = descriptor.revision,
        .location = location,
    }, preferred);
}

/// Open an already revision-stamped link. This is the scene-node path: unlike
/// `open`, it must not silently upgrade a retained link to the target's latest
/// descriptor revision.
pub fn openLocated(
    services: *Services,
    head: *Head,
    gpa: std.mem.Allocator,
    located: semantic_model.target.Located,
    preferred: ?semantic_model.scene.NodeId,
) Error!Result {
    return admitAndFocus(services, head, gpa, located, preferred);
}

fn admitAndFocus(
    services: *Services,
    head: *Head,
    gpa: std.mem.Allocator,
    located: semantic_model.target.Located,
    preferred: ?semantic_model.scene.NodeId,
) Error!Result {
    return switch (try services.openLocatedTarget(gpa, located)) {
        .no_handler => .no_handler,
        .ambiguous => |match| .{ .ambiguous = .{
            .strength = match.strength,
            .count = match.count,
        } },
        .opened => |view| blk: {
            const node = try services.focusView(head, gpa, view, preferred);
            break :blk .{ .opened = .{ .view = view, .node = node } };
        },
    };
}

/// The command-facing form performs the same operation and focuses the
/// resulting view.  It returns the selected node through the API above; the
/// command ABI has no semantic-handle value yet, so a successful invocation
/// returns nil and the head's semantic focus is the observable result.
pub fn openAndFocus(
    services: *Services,
    head: *Head,
    gpa: std.mem.Allocator,
    target: semantic_model.target.Ref,
) Error!Result {
    return open(services, head, gpa, target, .whole, null);
}

/// Follow the nearest typed link on the active focus path. `null` means no
/// node supplied a link, allowing an input command to fall back to an open
/// action advertised by a bespoke structured view. A present but stale,
/// unhandled, or ambiguous link remains explicit.
pub fn openFocused(
    services: *Services,
    head: *Head,
    gpa: std.mem.Allocator,
) Error!?Result {
    const located = try services.focusedTarget(head) orelse return null;
    return try openLocated(services, head, gpa, located, null);
}

test "generic target opening distinguishes none, ambiguity, and focus" {
    const semantic = semantic_model;
    const Handler = struct {
        view: semantic.view.Ref,

        pub fn probe(_: *@This(), _: semantic.target.Descriptor) target_runtime.resolver.ProbeError!?Match {
            return .exact;
        }

        pub fn open(self: *@This(), _: semantic.target.Located) target_runtime.resolver.OpenError!semantic.view.Ref {
            return self.view;
        }
    };

    var services = Services.init(.here);
    defer services.deinit(std.testing.allocator);
    const owner = try services.acquireOwner();
    const target = try services.publishTarget(std.testing.allocator, owner, .{
        .kind = .{ .synthetic = "test" },
        .display_name = "test-target",
    });
    var head: Head = .empty;
    defer head.deinit(std.testing.allocator);

    try std.testing.expect((try openAndFocus(&services, &head, std.testing.allocator, target)) == .no_handler);

    const view = try services.publishView(std.testing.allocator, owner, target, 1, .{
        .id = @enumFromInt(1),
        .focusable = true,
        .content = .{ .label = "target" },
    });
    var first: Handler = .{ .view = view };
    _ = try services.registerTargetHandler(std.testing.allocator, owner, "first", .init(&first));
    const opened = try openAndFocus(&services, &head, std.testing.allocator, target);
    try std.testing.expectEqual(view, opened.opened.view);
    try std.testing.expectEqual(@as(semantic.scene.NodeId, @enumFromInt(1)), opened.opened.node);
    try std.testing.expectEqual(view, head.semantic_focus.path().?.view);

    var second: Handler = .{ .view = view };
    _ = try services.registerTargetHandler(std.testing.allocator, owner, "second", .init(&second));
    const ambiguous = try openAndFocus(&services, &head, std.testing.allocator, target);
    try std.testing.expectEqual(@as(usize, 2), ambiguous.ambiguous.count);
    try std.testing.expectEqual(Match.exact, ambiguous.ambiguous.strength);
}

test "focused target opening prefers the nearest revision-stamped scene link" {
    const semantic = semantic_model;
    const Handler = struct {
        ancestor_target: semantic.target.Ref,
        ancestor_view: semantic.view.Ref,
        leaf_target: semantic.target.Ref,
        leaf_view: semantic.view.Ref,
        opens: usize = 0,

        pub fn probe(_: *@This(), _: semantic.target.Descriptor) target_runtime.resolver.ProbeError!?Match {
            return .exact;
        }

        pub fn open(self: *@This(), located: semantic.target.Located) target_runtime.resolver.OpenError!semantic.view.Ref {
            self.opens += 1;
            if (located.target.eql(self.leaf_target)) return self.leaf_view;
            if (located.target.eql(self.ancestor_target)) return self.ancestor_view;
            return error.Rejected;
        }
    };

    var services = Services.init(.here);
    defer services.deinit(std.testing.allocator);
    const owner = try services.acquireOwner();
    const ancestor_target = try services.publishTarget(std.testing.allocator, owner, .{
        .kind = .{ .synthetic = "ancestor" },
        .display_name = "ancestor",
    });
    const leaf_target = try services.publishTarget(std.testing.allocator, owner, .{
        .kind = .{ .synthetic = "leaf" },
        .display_name = "leaf",
    });
    const ancestor_view = try services.publishView(std.testing.allocator, owner, ancestor_target, 1, .{
        .id = @enumFromInt(10),
        .focusable = true,
        .content = .{ .label = "ancestor target" },
    });
    const leaf_view = try services.publishView(std.testing.allocator, owner, leaf_target, 1, .{
        .id = @enumFromInt(20),
        .focusable = true,
        .content = .{ .label = "leaf target" },
    });
    var handler: Handler = .{
        .ancestor_target = ancestor_target,
        .ancestor_view = ancestor_view,
        .leaf_target = leaf_target,
        .leaf_view = leaf_view,
    };
    _ = try services.registerTargetHandler(std.testing.allocator, owner, "scene-links", .init(&handler));

    const linked_child: semantic.scene.Node = .{
        .id = @enumFromInt(2),
        .focusable = true,
        .target = .{ .target = leaf_target, .revision = 1, .location = .{ .node = "selected" } },
        .content = .{ .label = "linked leaf" },
    };
    const linked_root: semantic.scene.Node = .{
        .id = @enumFromInt(1),
        .target = .{ .target = ancestor_target, .revision = 1 },
        .content = .{ .container = .{ .children = &.{linked_child} } },
    };
    const host_view = try services.publishView(std.testing.allocator, owner, null, 1, linked_root);
    var head: Head = .empty;
    defer head.deinit(std.testing.allocator);

    _ = try services.focusView(&head, std.testing.allocator, host_view, linked_child.id);
    const leaf_opened = (try openFocused(&services, &head, std.testing.allocator)).?;
    try std.testing.expectEqual(leaf_view, leaf_opened.opened.view);

    const plain_child: semantic.scene.Node = .{
        .id = linked_child.id,
        .focusable = true,
        .content = .{ .label = "plain leaf" },
    };
    const ancestor_only: semantic.scene.Node = .{
        .id = linked_root.id,
        .target = linked_root.target,
        .content = .{ .container = .{ .children = &.{plain_child} } },
    };
    try services.replaceView(std.testing.allocator, owner, host_view, 2, ancestor_only);
    _ = try services.focusView(&head, std.testing.allocator, host_view, plain_child.id);
    const ancestor_opened = (try openFocused(&services, &head, std.testing.allocator)).?;
    try std.testing.expectEqual(ancestor_view, ancestor_opened.opened.view);

    try services.replaceView(std.testing.allocator, owner, host_view, 3, linked_root);
    _ = try services.focusView(&head, std.testing.allocator, host_view, linked_child.id);
    try services.replaceTarget(std.testing.allocator, owner, leaf_target, .{
        .kind = .{ .synthetic = "leaf" },
        .display_name = "new leaf revision",
    });
    try std.testing.expectError(error.StaleTarget, openFocused(&services, &head, std.testing.allocator));
    try std.testing.expectEqual(@as(usize, 2), handler.opens);
}
