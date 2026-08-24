//! Validation shared by planners, dialogs, and executors.

const std = @import("std");
const contract = @import("contract.zig");

pub const ValidationError = error{ InvalidDependency, DependencyCycle, DuplicateOperationId } || std.mem.Allocator.Error;

const VisitState = enum { unseen, visiting, done };

pub fn validate(gpa: std.mem.Allocator, plan: contract.Plan) ValidationError!void {
    var ids: std.AutoHashMapUnmanaged(contract.OperationId, void) = .empty;
    defer ids.deinit(gpa);
    for (plan.operations, 0..) |operation, i| {
        const id_result = try ids.getOrPut(gpa, operation.id);
        if (id_result.found_existing) return error.DuplicateOperationId;
        for (operation.depends_on) |dependency|
            if (dependency >= plan.operations.len or dependency == i) return error.InvalidDependency;
    }

    const states = try gpa.alloc(VisitState, plan.operations.len);
    defer gpa.free(states);
    @memset(states, .unseen);
    for (plan.operations, 0..) |_, i| try visit(plan, states, i);
}

fn visit(plan: contract.Plan, states: []VisitState, i: usize) ValidationError!void {
    switch (states[i]) {
        .done => return,
        .visiting => return error.DependencyCycle,
        .unseen => {},
    }
    states[i] = .visiting;
    for (plan.operations[i].depends_on) |dependency| try visit(plan, states, dependency);
    states[i] = .done;
}

test "plan rejects cycles" {
    const destination: contract.Slot = .{
        .parent = .{ .authority = .here, .slot = 1, .generation = 1 },
        .name = try .init("cycle-test"),
    };
    const operations = [_]contract.Planned{
        .{ .id = [_]u8{1} ** 16, .operation = .{ .create_directory = .{ .destination = destination } }, .depends_on = &.{1} },
        .{ .id = [_]u8{2} ** 16, .operation = .{ .create_directory = .{ .destination = destination } }, .depends_on = &.{0} },
    };
    const plan: contract.Plan = .{
        .root = .{ .authority = .here, .slot = 0, .generation = 1 },
        .base_revision = &.{},
        .operations = &operations,
    };
    try std.testing.expectError(error.DependencyCycle, validate(std.testing.allocator, plan));
}
