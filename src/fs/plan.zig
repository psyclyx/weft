//! Validation shared by planners, dialogs, and executors.

const std = @import("std");
const contract = @import("contract.zig");

pub const ValidationError = error{ InvalidDependency, DuplicateOperationId } || std.mem.Allocator.Error;
pub const ReportValidationError = error{InvalidApplyReport} || std.mem.Allocator.Error;

pub fn validate(gpa: std.mem.Allocator, plan: contract.Plan) ValidationError!void {
    var ids: std.AutoHashMapUnmanaged(contract.OperationId, void) = .empty;
    defer ids.deinit(gpa);
    for (plan.operations, 0..) |operation, i| {
        const id_result = try ids.getOrPut(gpa, operation.id);
        if (id_result.found_existing) return error.DuplicateOperationId;
        // Plans are already in canonical execution order. Dependencies may
        // only name earlier operations, which makes cycles unrepresentable
        // while still allowing independent operations to run in parallel.
        for (operation.depends_on) |dependency|
            if (dependency >= i) return error.InvalidDependency;
        if (destinationParent(operation.operation)) |parent| switch (parent) {
            .planned => |dependency| if (dependency >= i) return error.InvalidDependency,
            else => {},
        };
    }
}

/// An apply report is a total, one-to-one answer to a particular plan. A
/// provider may reorder entries, but it may not omit, duplicate, or invent an
/// operation id. Validate this at the provider membrane so tools never have to
/// defensively rediscover the same rule.
pub fn validateReport(gpa: std.mem.Allocator, effect_plan: contract.Plan, report: contract.ApplyReport) ReportValidationError!void {
    if (effect_plan.operations.len != report.entries.len) return error.InvalidApplyReport;
    var seen: std.AutoHashMapUnmanaged(contract.OperationId, void) = .empty;
    defer seen.deinit(gpa);
    for (report.entries) |entry| {
        var belongs = false;
        for (effect_plan.operations) |planned| {
            if (std.mem.eql(u8, &entry.id, &planned.id)) {
                belongs = true;
                break;
            }
        }
        if (!belongs) return error.InvalidApplyReport;
        const result = try seen.getOrPut(gpa, entry.id);
        if (result.found_existing) return error.InvalidApplyReport;
    }
}

fn destinationParent(operation: contract.Operation) ?contract.ParentRef {
    return switch (operation) {
        .create_file => |create| create.destination.parent,
        .create_directory => |create| create.destination.parent,
        .create_symlink => |create| create.destination.parent,
        .copy => |copy| copy.destination.parent,
        .rename => |rename| rename.destination.parent,
        .remove, .set_permissions => null,
    };
}

test "plan rejects forward dependencies" {
    const destination: contract.Slot = .{
        .parent = .root,
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
    try std.testing.expectError(error.InvalidDependency, validate(std.testing.allocator, plan));
}

test "apply report must answer every planned operation exactly once" {
    const operations = [_]contract.Planned{
        .{ .id = [_]u8{1} ** 16, .operation = .{ .create_directory = .{ .destination = .{ .parent = .root, .name = try .init("one") } } } },
        .{ .id = [_]u8{2} ** 16, .operation = .{ .create_directory = .{ .destination = .{ .parent = .root, .name = try .init("two") } } } },
    };
    const effect_plan: contract.Plan = .{
        .root = .{ .authority = .here, .slot = 1, .generation = 1 },
        .base_revision = &.{},
        .operations = &operations,
    };
    const valid = [_]contract.ReportEntry{
        .{ .id = operations[1].id, .outcome = .already_satisfied },
        .{ .id = operations[0].id, .outcome = .{ .applied = null } },
    };
    try validateReport(std.testing.allocator, effect_plan, .{ .entries = &valid });
    const duplicate = [_]contract.ReportEntry{ valid[0], valid[0] };
    try std.testing.expectError(error.InvalidApplyReport, validateReport(std.testing.allocator, effect_plan, .{ .entries = &duplicate }));
    try std.testing.expectError(error.InvalidApplyReport, validateReport(std.testing.allocator, effect_plan, .{ .entries = valid[0..1] }));
}
