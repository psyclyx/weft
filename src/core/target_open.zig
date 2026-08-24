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

pub const Error = Services.ResolveTargetError || Services.OpenTargetError || Services.FocusError;

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
    var resolution = try services.resolveTarget(gpa, target);
    defer resolution.deinit();

    return switch (resolution.handlers.value.decide()) {
        .none => .no_handler,
        .ambiguous => |strength| .{ .ambiguous = .{
            .strength = strength,
            .count = equalStrengthCount(resolution.handlers.value.candidates, strength),
        } },
        .selected => |handler| blk: {
            const view = try services.openTarget(handler, resolution.located(location));
            const node = try services.focusView(head, gpa, view, preferred);
            break :blk .{ .opened = .{ .view = view, .node = node } };
        },
    };
}

fn equalStrengthCount(candidates: []const target_runtime.resolver.Candidate, strength: Match) usize {
    var count: usize = 0;
    for (candidates) |candidate| {
        if (candidate.strength == strength) count += 1;
    }
    return count;
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
