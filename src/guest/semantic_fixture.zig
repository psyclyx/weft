//! Test-only guest proving that portable semantic values cross the wasm
//! membrane without importing host runtime implementation.

const weft = @import("weft");
const kernel = weft.semantic_kernel;
const std = @import("std");

var field_ref: kernel.scene.FieldRef = undefined;

export fn init() void {
    if (!weft.semanticActionProvider()) unreachable;
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
        // Deliberately above wasm32's word width: the focus import must carry
        // the canonical NodeId without truncating its high half.
        .id = @enumFromInt(0x1_0000_0002),
        .focusable = true,
        .actions = &.{.{ .id = "fixture.open", .label = "Open" }},
        .content = .{ .field = .{ .ref = field_ref, .placeholder = "name", .single_line = true } },
    };
    const view = weft.semanticViewPublish(.{
        .id = @enumFromInt(1),
        .role = "fixture",
        .content = .{ .container = .{ .children = &.{child} } },
    }, target, 7) catch unreachable;
    if (!weft.semanticViewFocus(view, child.id)) unreachable;

    const definition: kernel.interaction.Definition = .{
        .role = .dialog,
        .view = view,
        .root = @enumFromInt(1),
        .actions = &.{
            .{ .id = "fixture.yes", .label = "Yes" },
            .{ .id = "fixture.no", .label = "No" },
        },
        .bindings = &.{
            .{ .input = "y", .action = "fixture.yes" },
            .{ .input = "n", .action = "fixture.no" },
        },
        .presentation = "fixture-dialog",
    };
    const first = weft.semanticInteractionOpen(definition) catch unreachable;
    const second = weft.semanticInteractionOpen(definition) catch unreachable;
    // Strict LIFO and generation checks are observable from the guest API:
    // the buried ref and then its stale generation both refuse to close.
    if (weft.semanticInteractionClose(first)) unreachable;
    if (!weft.semanticInteractionClose(second)) unreachable;
    if (!weft.semanticInteractionClose(first)) unreachable;
    if (weft.semanticInteractionClose(first)) unreachable;
    _ = weft.semanticInteractionOpen(definition) catch unreachable;
}

export fn on_semantic_action() void {
    var request = weft.semanticActionCurrent(weft.allocator) catch return;
    defer request.deinit();
    if (std.mem.eql(u8, request.value.action, "fixture.open")) {
        _ = weft.semanticActionHandled();
    } else {
        _ = weft.semanticActionDecline();
    }
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
