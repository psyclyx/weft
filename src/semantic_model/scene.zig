//! Provider-neutral semantic scene values. Nodes carry stable identity and
//! behavior-facing facts; renderers resolve layout and visual styling.

const std = @import("std");
const handle = @import("handle.zig");
const target = @import("target.zig");

pub const NodeId = enum(u64) {
    _,
};

pub const FieldTag = struct {};
pub const FieldRef = handle.Handle(FieldTag);

/// A scene node may name a resource without naming the plugin that handles it.
/// The target registry remains the authority for resolving this revision-stamped
/// link.  Locations deliberately remain opaque to the scene model so local,
/// remote, and synthetic producers share one value contract.
pub const TargetLink = target.Located;

pub const Axis = enum { horizontal, vertical, overlay };

pub const Fact = struct {
    name: []const u8,
    value: []const u8,
};

pub const Action = struct {
    id: []const u8,
    label: []const u8 = &.{},
    enabled: bool = true,
};

pub const Layout = struct {
    grow: u16 = 0,
    column: ?u16 = null,
    min_cells: ?u16 = null,
};

pub const Content = union(enum) {
    container: struct {
        axis: Axis = .vertical,
        children: []const Node,
    },
    label: []const u8,
    field: struct {
        ref: FieldRef,
        placeholder: []const u8 = &.{},
        single_line: bool = false,
    },
    action: struct {
        action: []const u8,
        label: []const u8,
        enabled: bool = true,
    },
};

pub const Node = struct {
    id: NodeId,
    role: []const u8 = &.{},
    facts: []const Fact = &.{},
    actions: []const Action = &.{},
    layout: Layout = .{},
    focusable: bool = false,
    target: ?TargetLink = null,
    content: Content,
};

pub const ValidationError = error{
    InvalidId,
    DuplicateId,
    InvalidFact,
    DuplicateFact,
    InvalidAction,
    DuplicateAction,
    InvalidTarget,
    TooDeep,
} || std.mem.Allocator.Error;

/// Validate the invariants a retained reconciler relies on. This is kept in
/// the semantic module so every renderer and guest adapter agrees on them.
pub fn validate(gpa: std.mem.Allocator, root: Node) ValidationError!void {
    var seen: std.AutoHashMapUnmanaged(u64, void) = .empty;
    defer seen.deinit(gpa);
    try validateNode(gpa, &seen, root, 0);
}

fn validateNode(gpa: std.mem.Allocator, seen: *std.AutoHashMapUnmanaged(u64, void), node: Node, depth: usize) ValidationError!void {
    if (depth > 1024) return error.TooDeep;
    const raw = @intFromEnum(node.id);
    if (raw == 0) return error.InvalidId;
    const result = try seen.getOrPut(gpa, raw);
    if (result.found_existing) return error.DuplicateId;
    var fact_names: std.StringHashMapUnmanaged(void) = .empty;
    defer fact_names.deinit(gpa);
    for (node.facts) |fact| {
        if (fact.name.len == 0) return error.InvalidFact;
        const fact_result = try fact_names.getOrPut(gpa, fact.name);
        if (fact_result.found_existing) return error.DuplicateFact;
    }
    var action_ids: std.StringHashMapUnmanaged(void) = .empty;
    defer action_ids.deinit(gpa);
    for (node.actions) |action| {
        if (action.id.len == 0) return error.InvalidAction;
        const action_result = try action_ids.getOrPut(gpa, action.id);
        if (action_result.found_existing) return error.DuplicateAction;
    }
    if (node.target) |link| try validateTargetLink(link);
    switch (node.content) {
        .container => |container| for (container.children) |child|
            try validateNode(gpa, seen, child, depth + 1),
        .action => |action| if (action.action.len == 0) return error.InvalidAction,
        else => {},
    }
}

pub fn validateTargetLink(link: TargetLink) error{InvalidTarget}!void {
    if (link.target.generation == 0 or link.revision == 0) return error.InvalidTarget;
    switch (link.location) {
        .whole => {},
        .text => |range| if (range.start > range.end) return error.InvalidTarget,
        .node => |value| if (value.len == 0) return error.InvalidTarget,
        .provider => |value| if (value.schema.len == 0) return error.InvalidTarget,
    }
}

test "scene validation rejects duplicate stable ids" {
    const children = [_]Node{
        .{ .id = @enumFromInt(2), .content = .{ .label = "a" } },
        .{ .id = @enumFromInt(2), .content = .{ .label = "b" } },
    };
    const root: Node = .{
        .id = @enumFromInt(1),
        .content = .{ .container = .{ .children = &children } },
    };
    try std.testing.expectError(error.DuplicateId, validate(std.testing.allocator, root));
}

test "scene validation rejects ambiguous fact and action names" {
    const duplicate_facts: Node = .{
        .id = @enumFromInt(1),
        .facts = &.{ .{ .name = "kind", .value = "a" }, .{ .name = "kind", .value = "b" } },
        .content = .{ .label = "row" },
    };
    try std.testing.expectError(error.DuplicateFact, validate(std.testing.allocator, duplicate_facts));
    const duplicate_actions: Node = .{
        .id = @enumFromInt(1),
        .actions = &.{ .{ .id = "open" }, .{ .id = "open" } },
        .content = .{ .label = "row" },
    };
    try std.testing.expectError(error.DuplicateAction, validate(std.testing.allocator, duplicate_actions));
}

test "scene validation rejects empty content action ids" {
    const node: Node = .{
        .id = @enumFromInt(1),
        .content = .{ .action = .{ .action = "", .label = "Run" } },
    };
    try std.testing.expectError(error.InvalidAction, validate(std.testing.allocator, node));
}

test "scene validation accepts opaque target links and rejects malformed ones" {
    const target_ref: target.Ref = .{ .authority = @enumFromInt(77), .slot = 4, .generation = 9 };
    try validate(std.testing.allocator, .{
        .id = @enumFromInt(1),
        .target = .{ .target = target_ref, .revision = 3, .location = .{ .provider = .{ .schema = "remote.node", .payload = &.{ 0, 0xff } } } },
        .content = .{ .label = "remote" },
    });
    try std.testing.expectError(error.InvalidTarget, validate(std.testing.allocator, .{
        .id = @enumFromInt(1),
        .target = .{ .target = target_ref, .revision = 0 },
        .content = .{ .label = "bad" },
    }));
    try std.testing.expectError(error.InvalidTarget, validate(std.testing.allocator, .{
        .id = @enumFromInt(1),
        .target = .{ .target = target_ref, .revision = 1, .location = .{ .text = .{ .start = 3, .end = 2 } } },
        .content = .{ .label = "bad" },
    }));
}
