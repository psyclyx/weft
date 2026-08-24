//! Provider-neutral semantic scene values. Nodes carry stable identity and
//! behavior-facing facts; renderers resolve layout and visual styling.

const std = @import("std");
const handle = @import("handle.zig");

pub const NodeId = enum(u64) {
    _,
};

pub const FieldTag = struct {};
pub const FieldRef = handle.Handle(FieldTag);

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
    content: Content,
};

pub const ValidationError = error{
    InvalidId,
    DuplicateId,
    InvalidFact,
    DuplicateFact,
    InvalidAction,
    DuplicateAction,
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
    switch (node.content) {
        .container => |container| for (container.children) |child|
            try validateNode(gpa, seen, child, depth + 1),
        else => {},
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
