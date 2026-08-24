//! Test-only guest proving that portable semantic values cross the wasm
//! membrane without importing host runtime implementation.

const weft = @import("weft");
const kernel = weft.semantic_kernel;

var field_ref: kernel.scene.FieldRef = undefined;

export fn init() void {
    const target = weft.semanticTargetPublish(.{
        .kind = .directory,
        .display_name = "fixture directory",
        .facts = &.{.{ .name = "locus", .value = "synthetic:test" }},
    }) catch unreachable;
    field_ref = weft.semanticFieldRegister(41, .{
        .revision = "1",
        .bytes = "name",
        .selection = .{ .anchor = 0, .caret = 4 },
        .single_line = true,
    }) catch unreachable;
    const child: kernel.scene.Node = .{
        .id = @enumFromInt(2),
        .focusable = true,
        .actions = &.{.{ .id = "fixture.open", .label = "Open" }},
        .content = .{ .field = .{ .ref = field_ref, .placeholder = "name", .single_line = true } },
    };
    _ = weft.semanticViewPublish(.{
        .id = @enumFromInt(1),
        .role = "fixture",
        .content = .{ .container = .{ .children = &.{child} } },
    }, target, 7) catch unreachable;
}

export fn on_semantic_field_edit(token: u32) void {
    if (token != 41) return;
    var edit = weft.semanticFieldCurrentEdit(weft.allocator) catch return;
    defer edit.deinit();
    weft.semanticFieldUpdate(field_ref, .{
        .revision = "2",
        .bytes = edit.replacement,
        .selection = edit.selection_after orelse .{
            .anchor = @intCast(edit.replacement.len),
            .caret = @intCast(edit.replacement.len),
        },
        .single_line = true,
    }) catch {};
}
