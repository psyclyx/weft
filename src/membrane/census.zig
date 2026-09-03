const std = @import("std");

pub const Direction = enum { guest_import, host_export };

pub const Operation = struct {
    major: u16 = 0,
    name: ?[]const u8 = null,
};

pub const Door = struct {
    symbol: []const u8,
    direction: Direction,
    operation: Operation = .{},
};

pub const Counts = struct {
    imports: usize,
    exports: usize,
    semantic_operations: usize,
};

pub const Limits = Counts;

pub const ValidationError = error{
    ImportBudgetExceeded,
    ExportBudgetExceeded,
    SemanticOperationBudgetExceeded,
};

const legacy_prefix = "legacy.";

fn legacyMatches(symbol: []const u8, explicit: []const u8) bool {
    return std.mem.startsWith(u8, explicit, legacy_prefix) and
        std.mem.eql(u8, explicit[legacy_prefix.len..], symbol);
}

fn sameSemanticOperation(a: Door, b: Door) bool {
    if (a.direction != b.direction or a.operation.major != b.operation.major)
        return false;
    if (a.operation.name) |a_name| {
        if (b.operation.name) |b_name| return std.mem.eql(u8, a_name, b_name);
        return legacyMatches(b.symbol, a_name);
    }
    if (b.operation.name) |b_name| return legacyMatches(a.symbol, b_name);
    return std.mem.eql(u8, a.symbol, b.symbol);
}

pub fn count(doors: []const Door) Counts {
    var result: Counts = .{
        .imports = 0,
        .exports = 0,
        .semantic_operations = 0,
    };

    for (doors, 0..) |door, i| {
        switch (door.direction) {
            .guest_import => result.imports += 1,
            .host_export => result.exports += 1,
        }

        var first = true;
        for (doors[0..i]) |prior| {
            if (sameSemanticOperation(prior, door)) {
                first = false;
                break;
            }
        }
        if (first) result.semantic_operations += 1;
    }

    return result;
}

pub fn validate(doors: []const Door, limits: Limits) ValidationError!Counts {
    const result = count(doors);
    if (result.imports > limits.imports) return error.ImportBudgetExceeded;
    if (result.exports > limits.exports) return error.ExportBudgetExceeded;
    if (result.semantic_operations > limits.semantic_operations)
        return error.SemanticOperationBudgetExceeded;
    return result;
}

const t = std.testing;

test "census rejects an import overrun independently" {
    const doors = [_]Door{
        .{ .symbol = "wl_a", .direction = .guest_import },
    };
    try t.expectError(error.ImportBudgetExceeded, validate(&doors, .{
        .imports = 0,
        .exports = 0,
        .semantic_operations = 1,
    }));
}

test "census rejects an export overrun independently" {
    const doors = [_]Door{
        .{ .symbol = "on_a", .direction = .host_export },
    };
    try t.expectError(error.ExportBudgetExceeded, validate(&doors, .{
        .imports = 0,
        .exports = 0,
        .semantic_operations = 1,
    }));
}

test "census rejects a semantic-operation overrun independently" {
    const doors = [_]Door{
        .{ .symbol = "wl_begin", .direction = .guest_import, .operation = .{ .major = 1, .name = "view.publish" } },
        .{ .symbol = "wl_finish", .direction = .guest_import, .operation = .{ .major = 1, .name = "view.publish" } },
    };
    try t.expectError(error.SemanticOperationBudgetExceeded, validate(&doors, .{
        .imports = 2,
        .exports = 0,
        .semantic_operations = 0,
    }));
}

test "census counts unique operation identity per direction" {
    const doors = [_]Door{
        .{ .symbol = "wl_begin", .direction = .guest_import, .operation = .{ .major = 1, .name = "view.publish" } },
        .{ .symbol = "wl_finish", .direction = .guest_import, .operation = .{ .major = 1, .name = "view.publish" } },
        .{ .symbol = "on_publish", .direction = .host_export, .operation = .{ .major = 1, .name = "view.publish" } },
        .{ .symbol = "wl_legacy", .direction = .guest_import },
    };

    try t.expectEqual(Counts{
        .imports = 3,
        .exports = 1,
        .semantic_operations = 3,
    }, count(&doors));
}

test "legacy identity is prefixed rather than the raw symbol" {
    const doors = [_]Door{
        .{ .symbol = "wl_legacy", .direction = .guest_import },
        .{ .symbol = "another_physical_row", .direction = .guest_import, .operation = .{ .major = 0, .name = "legacy.wl_legacy" } },
        .{ .symbol = "third_physical_row", .direction = .guest_import, .operation = .{ .major = 0, .name = "wl_legacy" } },
    };

    try t.expectEqual(@as(usize, 2), count(&doors).semantic_operations);
}
