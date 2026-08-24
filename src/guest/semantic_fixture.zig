//! Test-only guest proving that portable semantic values cross the wasm
//! membrane without importing host runtime implementation.

const weft = @import("weft");
const kernel = weft.semantic_kernel;

export fn init() void {
    const target = weft.semanticTargetPublish(.{
        .kind = .directory,
        .display_name = "fixture directory",
        .facts = &.{.{ .name = "locus", .value = "synthetic:test" }},
    }) catch unreachable;
    const child: kernel.scene.Node = .{
        .id = @enumFromInt(2),
        .focusable = true,
        .actions = &.{.{ .id = "fixture.open", .label = "Open" }},
        .content = .{ .label = "hello" },
    };
    _ = weft.semanticViewPublish(.{
        .id = @enumFromInt(1),
        .role = "fixture",
        .content = .{ .container = .{ .children = &.{child} } },
    }, target, 7) catch unreachable;
}
