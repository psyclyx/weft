//! Test-only guest proving that portable semantic values cross the wasm
//! membrane without importing host runtime implementation.

const weft = @import("weft");
const semantic = weft.semantic;
const std = @import("std");

var field_ref: semantic.scene.FieldRef = undefined;
var target_ref: semantic.target.Ref = undefined;
var view_ref: semantic.view.Ref = undefined;

export fn init() void {
    if (!weft.semanticActionProvider()) unreachable;
    const target_definition: semantic.target.Definition = .{
        .kind = .directory,
        .display_name = "fixture directory",
        .facts = &.{.{ .name = "locus", .value = "synthetic:test" }},
    };
    target_ref = weft.semanticTargetPublish(target_definition) catch unreachable;
    var initial_target = weft.semanticTargetDescribe(target_ref, weft.allocator) catch unreachable;
    defer initial_target.deinit();
    if (!initial_target.value.ref.eql(target_ref) or initial_target.value.revision != 1 or
        !std.mem.eql(u8, initial_target.value.display_name, "fixture directory")) unreachable;
    const stale_ref: semantic.target.Ref = .{ .authority = target_ref.authority, .slot = target_ref.slot, .generation = target_ref.generation + 1 };
    if (weft.semanticTargetDescribe(stale_ref, weft.allocator)) |_| unreachable else |_| {}
    weft.semanticTargetReplace(target_ref, target_definition) catch unreachable;
    var replaced_target = weft.semanticTargetDescribe(target_ref, weft.allocator) catch unreachable;
    defer replaced_target.deinit();
    if (replaced_target.value.revision != 2 or !replaced_target.value.ref.eql(target_ref)) unreachable;
    _ = weft.semanticTargetHandlerRegister(77, "fixture-directory") catch unreachable;
    _ = weft.semanticRelationProviderRegister(88, "fixture-container") catch unreachable;
    field_ref = weft.semanticFieldRegister(41, .{
        .revision = "1",
        .bytes = "name",
        .selection = .{ .anchor = 0, .caret = 4 },
        .single_line = true,
    }) catch unreachable;
    const child: semantic.scene.Node = .{
        // Deliberately above wasm32's word width: the focus import must carry
        // the canonical NodeId without truncating its high half.
        .id = @enumFromInt(0x1_0000_0002),
        .focusable = true,
        .actions = &.{.{ .id = "fixture.open", .label = "Open" }},
        .content = .{ .field = .{ .ref = field_ref, .placeholder = "name", .single_line = true } },
    };
    view_ref = weft.semanticViewPublish(.{
        .id = @enumFromInt(1),
        .role = "fixture",
        .content = .{ .container = .{ .children = &.{child} } },
    }, target_ref, 7) catch unreachable;
    if (!weft.semanticViewFocus(view_ref, child.id)) unreachable;

    const definition: semantic.interaction.Definition = .{
        .role = .dialog,
        .view = view_ref,
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

/// A target handler is a tool-level adapter: the membrane supplies an
/// immutable descriptor and this guest claims only the synthetic directory
/// target it published above.  Probes are deliberately total from the host's
/// perspective; malformed or unrelated requests simply decline.
export fn on_semantic_target_probe(token: u32) void {
    if (token != 77) {
        _ = weft.semanticTargetHandlerProbeNone();
        return;
    }
    var request = weft.semanticTargetHandlerCurrentDescriptor(weft.allocator) catch {
        _ = weft.semanticTargetHandlerProbeNone();
        return;
    };
    defer request.deinit();
    const descriptor = request.value;
    if (descriptor.kind != .directory or descriptor.revision != 2 or
        !descriptor.ref.eql(target_ref) or !hasFact(descriptor, "locus", "synthetic:test"))
    {
        _ = weft.semanticTargetHandlerProbeNone();
        return;
    }
    _ = weft.semanticTargetHandlerProbeMatch(.exact);
}

/// Opening is separately guarded by target identity and the resolved
/// descriptor revision.  The host performs its own revision/ownership checks
/// after this callback returns; these guest checks make the provider's intent
/// explicit and keep stale requests from being treated as opens.
export fn on_semantic_target_open(token: u32) void {
    if (token != 77) {
        _ = weft.semanticTargetHandlerOpenError(error.Rejected);
        return;
    }
    var request = weft.semanticTargetHandlerCurrentLocated(weft.allocator) catch {
        _ = weft.semanticTargetHandlerOpenError(error.Rejected);
        return;
    };
    defer request.deinit();
    if (!request.value.target.eql(target_ref) or request.value.revision != 2) {
        _ = weft.semanticTargetHandlerOpenError(error.StaleTarget);
        return;
    }
    switch (request.value.location) {
        .whole => {},
        else => {
            _ = weft.semanticTargetHandlerOpenError(error.Rejected);
            return;
        },
    }
    _ = weft.semanticTargetHandlerOpenView(view_ref);
}

/// Relation publication is independent from target handling. This fixture
/// answers only the named edge for its exact target revision; the response
/// contains a destination, not an echoed relation name.
export fn on_semantic_relation_query(token: u32) void {
    if (token != 88) {
        _ = weft.semanticRelationRespondNone();
        return;
    }
    var query = weft.semanticRelationCurrentQuery(weft.allocator) catch {
        _ = weft.semanticRelationRespondError(error.InvalidRelation);
        return;
    };
    defer query.deinit();
    if (!std.mem.eql(u8, query.value.name, "container") or
        !query.value.source.target.eql(target_ref) or query.value.source.revision != 2)
    {
        _ = weft.semanticRelationRespondNone();
        return;
    }
    weft.semanticRelationRespondTarget(.{ .target = target_ref, .revision = 2 }) catch {
        _ = weft.semanticRelationRespondError(error.Failed);
    };
}

fn hasFact(descriptor: semantic.target.Descriptor, name: []const u8, value: []const u8) bool {
    for (descriptor.facts) |fact| {
        if (std.mem.eql(u8, fact.name, name) and std.mem.eql(u8, fact.value, value)) return true;
    }
    return false;
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
