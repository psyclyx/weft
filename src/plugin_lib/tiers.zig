const std = @import("std");

pub const Tier = enum(u8) {
    protocol_data,
    service_presentation,
    interaction_orchestration,
    editor_composition,
};

pub const ValidationError = error{
    SameTierDependency,
    UpwardDependency,
};

pub fn validateEdge(consumer: Tier, dependency: Tier) ValidationError!void {
    const consumer_level = @intFromEnum(consumer);
    const dependency_level = @intFromEnum(dependency);
    if (dependency_level == consumer_level) return error.SameTierDependency;
    if (dependency_level > consumer_level) return error.UpwardDependency;
}

const t = std.testing;

test "tier validation accepts only a lower dependency" {
    try validateEdge(.interaction_orchestration, .service_presentation);
}

test "tier validation rejects a same-tier dependency" {
    try t.expectError(
        error.SameTierDependency,
        validateEdge(.service_presentation, .service_presentation),
    );
}

test "tier validation rejects an upward dependency" {
    try t.expectError(
        error.UpwardDependency,
        validateEdge(.protocol_data, .service_presentation),
    );
}
