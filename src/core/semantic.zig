//! System-scoped ownership of the semantic runtime registries. This is wiring,
//! not a policy object: each registry keeps its own narrow contract and can be
//! consumed independently through `command.Context.semantic`.

const std = @import("std");
const kernel = @import("weft_kernel");
const target_runtime = @import("weft_target_runtime");
const view_runtime = @import("weft_view_runtime");
const Head = @import("Head.zig");

pub const Services = struct {
    targets: target_runtime.target.Registry,
    target_handlers: target_runtime.resolver.Registry,
    views: view_runtime.view.Registry,
    fields: view_runtime.field.Registry,
    actions: view_runtime.action.Registry = .{},
    transfer: ?kernel.transfer.OwnedItem = null,

    pub const Released = struct {
        targets: usize = 0,
        target_handlers: usize = 0,
        views: usize = 0,
        fields: usize = 0,
        action_provider: bool = false,
    };

    pub const ViewAdmissionError = view_runtime.view.Error || error{ StaleTarget, StaleField };

    pub fn init(authority: kernel.handle.Authority) Services {
        return .{
            .targets = .init(authority),
            .target_handlers = .init(authority),
            .views = .init(authority),
            .fields = .init(authority),
        };
    }

    pub fn deinit(self: *Services, gpa: std.mem.Allocator) void {
        // Providers are non-owning and must already have unregistered before
        // their plugin dies. The registries only release retained descriptors.
        if (self.transfer) |*item| item.deinit();
        self.actions.deinit(gpa);
        self.fields.deinit(gpa);
        self.views.deinit(gpa);
        self.target_handlers.deinit(gpa);
        self.targets.deinit(gpa);
        self.* = undefined;
    }

    pub fn publishTarget(
        self: *Services,
        gpa: std.mem.Allocator,
        owner: []const u8,
        definition: kernel.target.Definition,
    ) target_runtime.target.Error!kernel.target.Ref {
        return self.targets.publish(gpa, owner, definition);
    }

    pub fn replaceTarget(
        self: *Services,
        gpa: std.mem.Allocator,
        owner: []const u8,
        ref: kernel.target.Ref,
        definition: kernel.target.Definition,
    ) target_runtime.target.Error!void {
        return self.targets.replace(gpa, owner, ref, definition);
    }

    pub fn closeTarget(self: *Services, gpa: std.mem.Allocator, owner: []const u8, ref: kernel.target.Ref) bool {
        return self.targets.close(gpa, owner, ref);
    }

    pub fn publishView(
        self: *Services,
        gpa: std.mem.Allocator,
        owner: []const u8,
        target: ?kernel.target.Ref,
        revision: u64,
        root: kernel.scene.Node,
    ) ViewAdmissionError!kernel.view.Ref {
        if (target) |ref| if (self.targets.get(ref) == null) return error.StaleTarget;
        try self.validateFieldRefs(root, 0);
        return self.views.publish(gpa, owner, target, revision, root);
    }

    pub fn replaceView(
        self: *Services,
        gpa: std.mem.Allocator,
        owner: []const u8,
        ref: kernel.view.Ref,
        revision: u64,
        root: kernel.scene.Node,
    ) ViewAdmissionError!void {
        try self.validateFieldRefs(root, 0);
        return self.views.replace(gpa, owner, ref, revision, root);
    }

    pub fn closeView(self: *Services, gpa: std.mem.Allocator, owner: []const u8, ref: kernel.view.Ref) bool {
        return self.views.close(gpa, owner, ref);
    }

    pub fn insertField(
        self: *Services,
        gpa: std.mem.Allocator,
        owner: []const u8,
        provider: view_runtime.field.Provider,
    ) view_runtime.field.Error!kernel.scene.FieldRef {
        return self.fields.insert(gpa, owner, provider);
    }

    pub fn registerActionProvider(
        self: *Services,
        gpa: std.mem.Allocator,
        owner: []const u8,
        provider: view_runtime.action.Provider,
    ) view_runtime.action.Error!void {
        return self.actions.register(gpa, owner, provider);
    }

    pub fn registerTargetHandler(
        self: *Services,
        gpa: std.mem.Allocator,
        owner: []const u8,
        id: []const u8,
        provider: target_runtime.resolver.Provider,
    ) target_runtime.resolver.Error!target_runtime.resolver.HandlerRef {
        return self.target_handlers.register(gpa, owner, id, provider);
    }

    /// Revoke behavior-bearing endpoints before the plugin frees the objects
    /// behind them. Generation bumps make every retained view/field/target or
    /// handler reference stale; resources belonging to other plugins remain.
    pub fn releaseOwner(self: *Services, gpa: std.mem.Allocator, owner: []const u8) Released {
        const target_handlers = self.target_handlers.unregisterOwner(gpa, owner);
        const action_provider = self.actions.unregister(gpa, owner);
        const views = self.views.closeOwner(gpa, owner);
        const fields = self.fields.removeOwner(gpa, owner);
        const targets = self.targets.closeOwner(gpa, owner);
        return .{
            .targets = targets,
            .target_handlers = target_handlers,
            .views = views,
            .fields = fields,
            .action_provider = action_provider,
        };
    }

    fn validateFieldRefs(self: *const Services, node: kernel.scene.Node, depth: usize) error{ StaleField, TooDeep }!void {
        if (depth > 1024) return error.TooDeep;
        switch (node.content) {
            .field => |field| if (self.fields.get(field.ref) == null) return error.StaleField,
            .container => |container| for (container.children) |child| try self.validateFieldRefs(child, depth + 1),
            .label, .action => {},
        }
    }

    pub const OpenInteractionError = view_runtime.interaction.Error || error{
        StaleView,
        UnknownRoot,
    };

    pub const InvokeActionError = view_runtime.action.Error || OpenInteractionError || kernel.transfer.ValidationError;
    pub const InvokeInputError = InvokeActionError || view_runtime.interaction.Error;

    pub const FocusError = view_runtime.view.Error;
    pub const FieldInputError = view_runtime.field.Error || error{StaleField};

    /// The small generic editing vocabulary used by ordinary editor commands
    /// when focus belongs to a semantic field. Byte offsets are deliberate:
    /// fields may contain raw filesystem names, not necessarily UTF-8 text.
    pub const FieldInput = union(enum) {
        replace_selection: []const u8,
        delete_previous,
        delete_next,
        move_previous,
        move_next,
    };

    pub const ActionEffect = union(enum) {
        declined,
        handled,
        transfer_stored,
        interaction_opened: kernel.interaction.Ref,
    };

    /// Invoke against the view owner's provider, then absorb any cross-view
    /// effect into the correct lifetime: transfers become system-owned and
    /// dialogs become head-owned. Provider memory never escapes the call.
    pub fn invokeAction(
        self: *Services,
        stack: *view_runtime.interaction.Stack,
        gpa: std.mem.Allocator,
        request: kernel.action.Request,
    ) InvokeActionError!ActionEffect {
        var with_transfer = request;
        if (with_transfer.transfer == null) {
            if (self.transfer) |*item| with_transfer.transfer = item.value;
        }
        const outcome = try self.actions.invoke(&self.views, with_transfer);
        return switch (outcome) {
            .declined => .declined,
            .handled => .handled,
            .transfer => |item| blk: {
                var owned = try kernel.transfer.OwnedItem.init(gpa, item);
                errdefer owned.deinit();
                if (self.transfer) |*prior| prior.deinit();
                self.transfer = owned;
                break :blk .transfer_stored;
            },
            .interaction => |definition| .{ .interaction_opened = try self.openInteraction(stack, gpa, definition) },
        };
    }

    /// Resolve only the active interaction's local bindings, invoke the owning
    /// view provider, and apply the action's explicit lifetime disposition.
    /// Null means the interaction did not bind this input, so a caller may
    /// continue with its ordinary input stack. A bound input is never exposed
    /// as an editor mode and never implicitly opens global key help.
    pub fn invokeInteractionInput(
        self: *Services,
        stack: *view_runtime.interaction.Stack,
        gpa: std.mem.Allocator,
        input: []const u8,
    ) InvokeInputError!?ActionEffect {
        const active = stack.active() orelse return null;
        const action = active.actionForInput(input) orelse return null;
        const interaction_ref = active.descriptor.ref;
        const disposition = action.disposition;
        const effect = self.invokeAction(stack, gpa, .{
            .action = action.id,
            .view = active.descriptor.view,
            .subject = active.descriptor.root,
        }) catch |err| switch (err) {
            // Views are generation-checked and may disappear when their owner
            // unloads. Retire the now-invisible interaction lazily on any
            // head; consume its bound key so it cannot leak into the editor.
            error.StaleView => {
                try stack.close(gpa, interaction_ref);
                return ActionEffect.declined;
            },
            else => return err,
        };
        if (disposition == .close_on_handled) switch (effect) {
            .handled, .transfer_stored => try stack.close(gpa, interaction_ref),
            .declined, .interaction_opened => {},
        };
        return effect;
    }

    /// Invoke an action against the deepest node on the active focus path that
    /// advertises it. Tool projections can therefore keep behavior on a row
    /// container while the editable field inside that row owns keyboard focus.
    /// `null` means there is no live semantic view on this head.
    pub fn invokeFocusedAction(
        self: *Services,
        stack: *view_runtime.interaction.Stack,
        head: *Head,
        gpa: std.mem.Allocator,
        action: []const u8,
    ) InvokeActionError!?ActionEffect {
        const path = head.semantic_focus.path() orelse return null;
        const instance = self.views.get(path.view) orelse {
            head.semantic_focus.clear();
            return null;
        };
        var index = path.nodes.len;
        while (index > 0) {
            index -= 1;
            const node = instance.node(path.nodes[index]) orelse continue;
            for (node.actions) |candidate| {
                if (!std.mem.eql(u8, candidate.id, action)) continue;
                return try self.invokeAction(stack, gpa, .{
                    .action = action,
                    .view = path.view,
                    .subject = node.id,
                });
            }
        }
        return error.ActionUnavailable;
    }

    pub fn hasActiveView(self: *const Services, head: *const Head) bool {
        const path = head.semantic_focus.path() orelse return false;
        const instance = self.views.get(path.view) orelse return false;
        const leaf = path.leaf() orelse return false;
        return instance.node(leaf) != null;
    }

    /// Compose two otherwise-independent mechanisms at their one real
    /// invariant: an interaction root must name a node in its declared view.
    pub fn openInteraction(
        self: *const Services,
        stack: *view_runtime.interaction.Stack,
        gpa: std.mem.Allocator,
        definition: kernel.interaction.Definition,
    ) OpenInteractionError!kernel.interaction.Ref {
        const instance = self.views.get(definition.view) orelse return error.StaleView;
        if (instance.node(definition.root) == null) return error.UnknownRoot;
        return stack.open(gpa, definition);
    }

    /// Move one head through the active view's declared focus order. `false`
    /// means this head has no live semantic view, so a caller may fall back to
    /// its text-editor movement. A live view consumes the intent even when it
    /// has no focusable nodes or is already at an edge.
    pub fn moveHeadFocus(
        self: *const Services,
        head: *Head,
        gpa: std.mem.Allocator,
        movement: kernel.focus.Movement,
    ) FocusError!bool {
        const path = head.semantic_focus.path() orelse return false;
        const instance = self.views.get(path.view) orelse {
            head.semantic_focus.clear();
            return false;
        };
        const next = instance.move(path.leaf(), movement) orelse return true;
        var storage: [1026]kernel.scene.NodeId = undefined;
        const next_path = (try instance.focusPath(next, &storage)) orelse return true;
        try head.semantic_focus.set(gpa, next_path);
        return true;
    }

    /// Apply ordinary text-editing intent to the active semantic field. The
    /// field provider remains the authority for revision checks and mutation;
    /// this adapter only translates common editor commands into its raw-byte
    /// edit contract. A semantic non-field node still consumes text input, so
    /// typing can never leak into a hidden backing document.
    pub fn inputFocusedField(
        self: *const Services,
        head: *Head,
        gpa: std.mem.Allocator,
        input: FieldInput,
    ) FieldInputError!bool {
        const path = head.semantic_focus.path() orelse return false;
        const instance = self.views.get(path.view) orelse {
            head.semantic_focus.clear();
            return false;
        };
        const field_ref = path.field orelse return true;
        const leaf = path.leaf() orelse return error.StaleField;
        const node = instance.node(leaf) orelse return error.StaleField;
        switch (node.content) {
            .field => |field| if (!field.ref.eql(field_ref)) return error.StaleField,
            else => return error.StaleField,
        }
        const provider = self.fields.get(field_ref) orelse return error.StaleField;
        var snapshot = try provider.snapshot(gpa);
        defer snapshot.deinit();
        const value = snapshot.value;
        const anchor: usize = @intCast(value.selection.anchor);
        const caret: usize = @intCast(value.selection.caret);
        const selection_start = @min(anchor, caret);
        const selection_end = @max(anchor, caret);
        const edit: view_runtime.field.Edit = switch (input) {
            .replace_selection => |replacement| blk: {
                if (value.single_line and std.mem.indexOfAny(u8, replacement, "\r\n") != null)
                    return true;
                break :blk .{
                    .start = selection_start,
                    .end = selection_end,
                    .replacement = replacement,
                    .selection_after = collapsed(selection_start + replacement.len),
                };
            },
            .delete_previous => blk: {
                const start = if (selection_start != selection_end) selection_start else selection_start -| 1;
                break :blk .{
                    .start = start,
                    .end = selection_end,
                    .replacement = &.{},
                    .selection_after = collapsed(start),
                };
            },
            .delete_next => blk: {
                const end = if (selection_start != selection_end) selection_end else @min(selection_end + 1, value.bytes.len);
                break :blk .{
                    .start = selection_start,
                    .end = end,
                    .replacement = &.{},
                    .selection_after = collapsed(selection_start),
                };
            },
            .move_previous => blk: {
                const offset = if (selection_start != selection_end) selection_start else selection_start -| 1;
                break :blk .{ .start = offset, .end = offset, .replacement = &.{}, .selection_after = collapsed(offset) };
            },
            .move_next => blk: {
                const offset = if (selection_start != selection_end) selection_end else @min(selection_end + 1, value.bytes.len);
                break :blk .{ .start = offset, .end = offset, .replacement = &.{}, .selection_after = collapsed(offset) };
            },
        };
        try provider.edit(value.revision, edit);
        return true;
    }
};

fn collapsed(offset: usize) view_runtime.field.Selection {
    return .{ .anchor = offset, .caret = offset };
}

test "semantic services keep target, view, and field namespaces typed" {
    var services = Services.init(.here);
    defer services.deinit(std.testing.allocator);
    try std.testing.expectError(error.StaleField, services.publishView(std.testing.allocator, "test", null, 1, .{
        .id = @enumFromInt(99),
        .content = .{ .field = .{ .ref = .{ .authority = .here, .slot = 99, .generation = 1 } } },
    }));
    const target_ref = try services.publishTarget(std.testing.allocator, "test", .{
        .kind = .directory,
        .display_name = "directory",
    });
    const view_ref = try services.publishView(std.testing.allocator, "test", target_ref, 1, .{
        .id = @enumFromInt(1),
        .actions = &.{
            .{ .id = kernel.action.standard.copy },
            .{ .id = kernel.action.standard.paste_after },
            .{ .id = "confirm" },
        },
        .content = .{ .label = "directory" },
    });
    try std.testing.expect(services.targets.get(target_ref) != null);
    try std.testing.expect(services.views.get(view_ref) != null);

    var interactions: view_runtime.interaction.Stack = .empty;
    defer interactions.deinit(std.testing.allocator);
    _ = try services.openInteraction(&interactions, std.testing.allocator, .{
        .role = .dialog,
        .view = view_ref,
        .root = @enumFromInt(1),
        .actions = &.{.{ .id = "ok", .label = "OK" }},
    });
    try std.testing.expect(interactions.active() != null);

    const Handler = struct {
        view: kernel.view.Ref,

        pub fn invoke(self: *@This(), request: kernel.action.Request) view_runtime.action.ProviderError!kernel.action.Outcome {
            if (std.mem.eql(u8, request.action, kernel.action.standard.copy)) return .{ .transfer = .{
                .intent = .copy,
                .suggested_name = "directory",
                .representations = &.{.{ .media_type = "application/test", .payload = "snapshot" }},
            } };
            if (std.mem.eql(u8, request.action, kernel.action.standard.paste_after))
                return if (request.transfer != null) .handled else error.Failed;
            return .{ .interaction = .{
                .role = .dialog,
                .view = self.view,
                .root = @enumFromInt(1),
                .actions = &.{.{ .id = "ok", .label = "OK" }},
            } };
        }
    };
    var handler: Handler = .{ .view = view_ref };
    try services.registerActionProvider(std.testing.allocator, "test", .init(&handler));
    const request: kernel.action.Request = .{
        .action = kernel.action.standard.copy,
        .view = view_ref,
        .subject = @enumFromInt(1),
    };
    try std.testing.expect((try services.invokeAction(&interactions, std.testing.allocator, request)) == .transfer_stored);
    try std.testing.expectEqualStrings("snapshot", services.transfer.?.value.representations[0].payload);
    var paste = request;
    paste.action = kernel.action.standard.paste_after;
    try std.testing.expect((try services.invokeAction(&interactions, std.testing.allocator, paste)) == .handled);
    var confirm = request;
    confirm.action = "confirm";
    try std.testing.expect((try services.invokeAction(&interactions, std.testing.allocator, confirm)) == .interaction_opened);
    const released = services.releaseOwner(std.testing.allocator, "test");
    try std.testing.expectEqual(@as(usize, 1), released.targets);
    try std.testing.expectEqual(@as(usize, 1), released.views);
    try std.testing.expect(released.action_provider);
    try std.testing.expect(services.targets.get(target_ref) == null);
    try std.testing.expect(services.views.get(view_ref) == null);
    try std.testing.expectEqual(Services.Released{}, services.releaseOwner(std.testing.allocator, "test"));
}

test "interaction-local input invokes semantic action and closes explicitly" {
    var services = Services.init(.here);
    defer services.deinit(std.testing.allocator);
    const root: kernel.scene.Node = .{
        .id = @enumFromInt(1),
        .actions = &.{.{ .id = "confirm" }},
        .content = .{ .label = "Apply changes?" },
    };
    const view_ref = try services.publishView(std.testing.allocator, "dialog-owner", null, 1, root);
    const Handler = struct {
        calls: usize = 0,
        pub fn invoke(self: *@This(), _: kernel.action.Request) view_runtime.action.ProviderError!kernel.action.Outcome {
            self.calls += 1;
            return .handled;
        }
    };
    var handler: Handler = .{};
    try services.registerActionProvider(std.testing.allocator, "dialog-owner", .init(&handler));
    var interactions: view_runtime.interaction.Stack = .empty;
    defer interactions.deinit(std.testing.allocator);
    _ = try services.openInteraction(&interactions, std.testing.allocator, .{
        .role = .dialog,
        .view = view_ref,
        .root = @enumFromInt(1),
        .actions = &.{.{ .id = "confirm", .disposition = .close_on_handled }},
        .bindings = &.{.{ .input = "y", .action = "confirm" }},
        .presentation = "which-key-like",
    });
    try std.testing.expect(try services.invokeInteractionInput(&interactions, std.testing.allocator, "x") == null);
    try std.testing.expect((try services.invokeInteractionInput(&interactions, std.testing.allocator, "y")).? == .handled);
    try std.testing.expectEqual(@as(usize, 1), handler.calls);
    try std.testing.expect(interactions.active() == null);

    _ = try services.openInteraction(&interactions, std.testing.allocator, .{
        .role = .dialog,
        .view = view_ref,
        .root = @enumFromInt(1),
        .actions = &.{.{ .id = "confirm" }},
        .bindings = &.{.{ .input = "y", .action = "confirm" }},
    });
    _ = services.releaseOwner(std.testing.allocator, "dialog-owner");
    try std.testing.expect((try services.invokeInteractionInput(&interactions, std.testing.allocator, "y")).? == .declined);
    try std.testing.expect(interactions.active() == null);
}

test "ordinary editor input targets semantic fields and focus order" {
    const Memory = struct {
        bytes: std.ArrayList(u8) = .empty,
        selection: view_runtime.field.Selection = .{ .anchor = 0, .caret = 0 },
        revision: u64 = 1,

        fn deinit(self: *@This(), gpa: std.mem.Allocator) void {
            self.bytes.deinit(gpa);
        }

        pub fn snapshot(self: *@This(), gpa: std.mem.Allocator) view_runtime.field.Error!view_runtime.field.OwnedSnapshot {
            var owned = view_runtime.field.OwnedSnapshot.init(gpa);
            errdefer owned.deinit();
            const arena = owned.allocator();
            owned.value = .{
                .revision = try std.fmt.allocPrint(arena, "{d}", .{self.revision}),
                .bytes = try arena.dupe(u8, self.bytes.items),
                .selection = self.selection,
                .single_line = true,
            };
            return owned;
        }

        pub fn edit(self: *@This(), expected: []const u8, value: view_runtime.field.Edit) view_runtime.field.Error!void {
            var revision_buf: [32]u8 = undefined;
            const revision = std.fmt.bufPrint(&revision_buf, "{d}", .{self.revision}) catch unreachable;
            if (!std.mem.eql(u8, expected, revision)) return error.Stale;
            const start: usize = @intCast(value.start);
            const end: usize = @intCast(value.end);
            if (start > end or end > self.bytes.items.len) return error.InvalidRange;
            try self.bytes.replaceRange(std.testing.allocator, start, end - start, value.replacement);
            if (value.selection_after) |selection| self.selection = selection;
            self.revision += 1;
        }
    };

    var first: Memory = .{};
    defer first.deinit(std.testing.allocator);
    try first.bytes.appendSlice(std.testing.allocator, "old");
    first.selection = .{ .anchor = 0, .caret = 3 };
    var second: Memory = .{};
    defer second.deinit(std.testing.allocator);
    try second.bytes.appendSlice(std.testing.allocator, "next");

    var services = Services.init(.here);
    defer services.deinit(std.testing.allocator);
    const first_ref = try services.insertField(std.testing.allocator, "tool", .init(&first));
    const second_ref = try services.insertField(std.testing.allocator, "tool", .init(&second));
    const children = [_]kernel.scene.Node{
        .{ .id = @enumFromInt(2), .focusable = true, .content = .{ .field = .{ .ref = first_ref, .single_line = true } } },
        .{ .id = @enumFromInt(3), .focusable = true, .content = .{ .field = .{ .ref = second_ref, .single_line = true } } },
    };
    const view_ref = try services.publishView(std.testing.allocator, "tool", null, 1, .{
        .id = @enumFromInt(1),
        .actions = &.{.{ .id = kernel.action.standard.copy }},
        .content = .{ .container = .{ .children = &children } },
    });
    const Actions = struct {
        calls: usize = 0,
        pub fn invoke(self: *@This(), _: kernel.action.Request) view_runtime.action.ProviderError!kernel.action.Outcome {
            self.calls += 1;
            return .handled;
        }
    };
    var actions: Actions = .{};
    try services.registerActionProvider(std.testing.allocator, "tool", .init(&actions));
    var head: Head = .empty;
    defer head.deinit(std.testing.allocator);
    try head.semantic_focus.set(std.testing.allocator, .{ .view = view_ref, .nodes = &.{ @enumFromInt(1), @enumFromInt(2) }, .field = first_ref });

    try std.testing.expect(try services.inputFocusedField(&head, std.testing.allocator, .{ .replace_selection = "new" }));
    try std.testing.expectEqualStrings("new", first.bytes.items);
    try std.testing.expect(try services.moveHeadFocus(&head, std.testing.allocator, .next));
    try std.testing.expectEqual(@as(kernel.scene.NodeId, @enumFromInt(3)), head.semantic_focus.path().?.leaf().?);
    try std.testing.expect(head.semantic_focus.path().?.field.?.eql(second_ref));
    try std.testing.expect((try services.invokeFocusedAction(&head.interactions, &head, std.testing.allocator, kernel.action.standard.copy)).? == .handled);
    try std.testing.expectEqual(@as(usize, 1), actions.calls);

    // A single-line field consumes a newline without changing its bytes.
    try std.testing.expect(try services.inputFocusedField(&head, std.testing.allocator, .{ .replace_selection = "\n" }));
    try std.testing.expectEqualStrings("next", second.bytes.items);
    const released = services.releaseOwner(std.testing.allocator, "tool");
    try std.testing.expectEqual(@as(usize, 1), released.views);
    try std.testing.expectEqual(@as(usize, 2), released.fields);
    try std.testing.expect(released.action_provider);
    try std.testing.expect(services.fields.get(first_ref) == null);
    try std.testing.expect(!try services.moveHeadFocus(&head, std.testing.allocator, .next));
    try std.testing.expect(head.semantic_focus.path() == null);
}
