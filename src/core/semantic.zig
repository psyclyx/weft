//! System-scoped ownership of the semantic runtime registries. This is wiring,
//! not a policy object: each registry keeps its own narrow contract and can be
//! consumed independently through `command.Context.semantic`.

const std = @import("std");
const semantic = @import("weft_semantic");
const target_runtime = @import("weft_target_runtime");
const view_runtime = @import("weft_view_runtime");
const Head = @import("Head.zig");

pub const Services = struct {
    targets: target_runtime.target.Registry,
    target_handlers: target_runtime.resolver.Registry,
    target_relations: target_runtime.relation.Registry,
    views: view_runtime.view.Registry,
    fields: view_runtime.field.Registry,
    actions: view_runtime.action.Registry = .{},
    /// Config/plugin-declared semantic command names. These are open protocol
    /// strings, not a core vocabulary; the command trampoline borrows this
    /// owned name until the system is torn down.
    semantic_commands: std.ArrayList(*SemanticCommand) = .empty,
    transfer: ?semantic.transfer.OwnedItem = null,
    named_transfers: [26]?semantic.transfer.OwnedItem = @splat(null),
    next_owner: u64 = 1,

    pub const Released = struct {
        targets: usize = 0,
        target_handlers: usize = 0,
        target_relations: usize = 0,
        views: usize = 0,
        fields: usize = 0,
        action_provider: bool = false,
    };

    pub const SemanticCommand = struct { name: []u8 };

    pub const ViewAdmissionError = view_runtime.view.Error || error{ StaleTarget, StaleField };

    /// Allocate an identity for one provider instance. Human-readable plugin
    /// names remain metadata; ownership and teardown use only this value.
    pub fn acquireOwner(self: *Services) error{OwnerIdsExhausted}!semantic.owner.Id {
        if (self.next_owner == 0) return error.OwnerIdsExhausted;
        const id: semantic.owner.Id = @enumFromInt(self.next_owner);
        self.next_owner +%= 1;
        return id;
    }

    pub fn init(authority: semantic.handle.Authority) Services {
        return .{
            .targets = .init(authority),
            .target_handlers = .init(authority),
            .target_relations = .init(authority),
            .views = .init(authority),
            .fields = .init(authority),
        };
    }

    pub fn deinit(self: *Services, gpa: std.mem.Allocator) void {
        // Providers are non-owning and must already have unregistered before
        // their plugin dies. The registries only release retained descriptors.
        if (self.transfer) |*item| item.deinit();
        for (&self.named_transfers) |*item| if (item.*) |*owned| owned.deinit();
        self.actions.deinit(gpa);
        for (self.semantic_commands.items) |entry| {
            gpa.free(entry.name);
            gpa.destroy(entry);
        }
        self.semantic_commands.deinit(gpa);
        self.fields.deinit(gpa);
        self.views.deinit(gpa);
        self.target_handlers.deinit(gpa);
        self.target_relations.deinit(gpa);
        self.targets.deinit(gpa);
        self.* = undefined;
    }

    /// Own one open semantic action name for a command trampoline. Repeated
    /// declarations are idempotent, matching `weft.action`'s command side.
    pub fn declareSemanticCommand(self: *Services, gpa: std.mem.Allocator, name: []const u8) !*SemanticCommand {
        for (self.semantic_commands.items) |entry| {
            if (std.mem.eql(u8, entry.name, name)) return entry;
        }
        const entry = try gpa.create(SemanticCommand);
        errdefer gpa.destroy(entry);
        entry.* = .{ .name = try gpa.dupe(u8, name) };
        errdefer gpa.free(entry.name);
        try self.semantic_commands.append(gpa, entry);
        return entry;
    }

    pub fn publishTarget(
        self: *Services,
        gpa: std.mem.Allocator,
        owner: semantic.owner.Id,
        definition: semantic.target.Definition,
    ) target_runtime.target.Error!semantic.target.Ref {
        return self.targets.publish(gpa, owner, definition);
    }

    pub fn replaceTarget(
        self: *Services,
        gpa: std.mem.Allocator,
        owner: semantic.owner.Id,
        ref: semantic.target.Ref,
        definition: semantic.target.Definition,
    ) target_runtime.target.Error!void {
        return self.targets.replace(gpa, owner, ref, definition);
    }

    pub fn closeTarget(self: *Services, gpa: std.mem.Allocator, owner: semantic.owner.Id, ref: semantic.target.Ref) bool {
        return self.targets.close(gpa, owner, ref);
    }

    pub fn publishView(
        self: *Services,
        gpa: std.mem.Allocator,
        owner: semantic.owner.Id,
        target: ?semantic.target.Ref,
        revision: u64,
        root: semantic.scene.Node,
    ) ViewAdmissionError!semantic.view.Ref {
        const target_binding: ?semantic.view.TargetBinding = if (target) |ref| blk: {
            const descriptor = self.targets.get(ref) orelse return error.StaleTarget;
            break :blk .{ .ref = ref, .revision = descriptor.revision };
        } else null;
        try self.validateSceneRefs(root, 0);
        return self.views.publish(gpa, owner, target_binding, revision, root);
    }

    pub fn replaceView(
        self: *Services,
        gpa: std.mem.Allocator,
        owner: semantic.owner.Id,
        ref: semantic.view.Ref,
        revision: u64,
        root: semantic.scene.Node,
    ) ViewAdmissionError!void {
        try self.validateSceneRefs(root, 0);
        return self.views.replace(gpa, owner, ref, revision, root);
    }

    pub fn closeView(self: *Services, gpa: std.mem.Allocator, owner: semantic.owner.Id, ref: semantic.view.Ref) bool {
        return self.views.close(gpa, owner, ref);
    }

    pub fn insertField(
        self: *Services,
        gpa: std.mem.Allocator,
        owner: semantic.owner.Id,
        provider: view_runtime.field.Provider,
    ) view_runtime.field.Error!semantic.scene.FieldRef {
        return self.fields.insert(gpa, owner, provider);
    }

    pub fn registerActionProvider(
        self: *Services,
        gpa: std.mem.Allocator,
        owner: semantic.owner.Id,
        provider: view_runtime.action.Provider,
    ) view_runtime.action.Error!void {
        return self.actions.register(gpa, owner, provider);
    }

    pub fn registerTargetHandler(
        self: *Services,
        gpa: std.mem.Allocator,
        owner: semantic.owner.Id,
        id: []const u8,
        provider: target_runtime.resolver.Provider,
    ) target_runtime.resolver.Error!target_runtime.resolver.HandlerRef {
        return self.target_handlers.register(gpa, owner, id, provider);
    }

    pub fn registerTargetRelationProvider(
        self: *Services,
        gpa: std.mem.Allocator,
        owner: semantic.owner.Id,
        id: []const u8,
        provider: target_runtime.relation.Provider,
    ) target_runtime.relation.Error!target_runtime.relation.ProviderRef {
        return self.target_relations.register(gpa, owner, id, provider);
    }

    pub const ResolvedTarget = struct {
        target: semantic.target.Ref,
        revision: u64,
        handlers: target_runtime.resolver.OwnedResolution,

        pub fn deinit(self: *ResolvedTarget) void {
            self.handlers.deinit();
            self.* = undefined;
        }

        pub fn located(self: *const ResolvedTarget, location: semantic.target.Location) semantic.target.Located {
            return .{ .target = self.target, .revision = self.revision, .location = location };
        }
    };

    pub const ResolveTargetError = std.mem.Allocator.Error || error{StaleTarget};

    /// Probe every registered handler against one immutable descriptor
    /// revision. Registration order never breaks equal-strength ties.
    pub fn resolveTarget(
        self: *const Services,
        gpa: std.mem.Allocator,
        ref: semantic.target.Ref,
    ) ResolveTargetError!ResolvedTarget {
        const descriptor = self.targets.get(ref) orelse return error.StaleTarget;
        return .{
            .target = ref,
            .revision = descriptor.revision,
            .handlers = try self.target_handlers.resolve(gpa, descriptor.*),
        };
    }

    pub const OpenTargetError = target_runtime.resolver.Error || target_runtime.resolver.OpenError || error{
        InvalidLocation,
        StaleView,
        HandlerOwnerMismatch,
        ViewTargetMismatch,
        NoTargetHandler,
        AmbiguousTargetHandlers,
    };

    pub const TargetRelationError = std.mem.Allocator.Error || error{
        InvalidLocation,
        InvalidRelation,
        RelationFailed,
        RelationUnavailable,
        StaleTarget,
    };

    pub const TargetRelationResult = union(enum) {
        absent,
        resolved: semantic.target.Located,
        ambiguous: struct { count: usize },
    };

    /// Relation locations may carry provider-owned bytes. Keep the resolver's
    /// arena alive until the caller has consumed the returned value.
    pub const OwnedTargetRelationResult = struct {
        arena: std.heap.ArenaAllocator,
        value: TargetRelationResult = .absent,

        pub fn init(gpa: std.mem.Allocator) OwnedTargetRelationResult {
            return .{ .arena = .init(gpa) };
        }

        pub fn deinit(self: *OwnedTargetRelationResult) void {
            self.arena.deinit();
            self.* = undefined;
        }
    };

    pub const LocatedOpenResult = union(enum) {
        opened: semantic.view.Ref,
        no_handler,
        ambiguous: struct {
            strength: target_runtime.resolver.Strength,
            count: usize,
        },
    };

    /// Resolve and admit the exact located revision requested by a provider.
    /// A provider can request an open, but cannot select a handler or smuggle
    /// in a view it does not own. No focus is changed here; callers that have
    /// a head may focus the admitted view as a separate head-local concern.
    pub fn openLocatedTarget(
        self: *const Services,
        gpa: std.mem.Allocator,
        located: semantic.target.Located,
    ) (ResolveTargetError || OpenTargetError)!LocatedOpenResult {
        try validateLocation(located.location);
        const descriptor = self.targets.get(located.target) orelse return error.StaleTarget;
        if (descriptor.revision != located.revision) return error.StaleTarget;
        var resolution = try self.target_handlers.resolve(gpa, descriptor.*);
        defer resolution.deinit();
        return switch (resolution.value.decide()) {
            .none => .no_handler,
            .ambiguous => |strength| .{ .ambiguous = .{
                .strength = strength,
                .count = equalStrengthCount(resolution.value.candidates, strength),
            } },
            .selected => |handler| .{ .opened = try self.openTarget(handler, located) },
        };
    }

    /// Open only the descriptor revision that was actually resolved. A
    /// provider may return behavior it owns, never another plugin's view or
    /// an unrelated view that merely happens to be live.
    pub fn openTarget(
        self: *const Services,
        handler: target_runtime.resolver.HandlerRef,
        located: semantic.target.Located,
    ) OpenTargetError!semantic.view.Ref {
        try validateLocation(located.location);
        const target_descriptor = self.targets.get(located.target) orelse return error.StaleTarget;
        if (target_descriptor.revision != located.revision) return error.StaleTarget;
        const view_ref = try self.target_handlers.open(handler, located);
        // The callback may have replaced or closed the target while opening.
        const current_target = self.targets.get(located.target) orelse return error.StaleTarget;
        if (current_target.revision != located.revision) return error.StaleTarget;
        // Re-read after behavior returns: a handler that retired itself while
        // opening cannot leave us dereferencing its former descriptor arena.
        const handler_descriptor = self.target_handlers.descriptor(handler) orelse return error.StaleHandler;
        const view_instance = self.views.get(view_ref) orelse return error.StaleView;
        if (handler_descriptor.owner != view_instance.descriptor.owner)
            return error.HandlerOwnerMismatch;
        const view_target = view_instance.descriptor.target orelse return error.ViewTargetMismatch;
        if (!view_target.ref.eql(located.target) or view_target.revision != located.revision)
            return error.ViewTargetMismatch;
        return view_ref;
    }

    /// Query a named edge published by an independent relation provider. The
    /// provider owns vocabulary and lookup policy; this service only routes
    /// the immutable query and admits a live, revision-stamped destination.
    /// The returned result owns any provider location bytes; callers must
    /// call `deinit` after consuming it.
    pub fn resolveTargetRelation(
        self: *const Services,
        gpa: std.mem.Allocator,
        source: semantic.target.Located,
        name: []const u8,
    ) TargetRelationError!OwnedTargetRelationResult {
        if (!validRelationName(name)) return error.InvalidRelation;
        if (source.target.authority != self.targets.authority) return error.StaleTarget;
        const source_descriptor = self.targets.get(source.target) orelse return error.StaleTarget;
        if (source_descriptor.revision != source.revision) return error.StaleTarget;
        try validateLocation(source.location);

        var output = OwnedTargetRelationResult.init(gpa);
        errdefer output.deinit();
        var relations = try self.target_relations.query(gpa, .{ .source = source, .name = name });
        defer relations.deinit();
        if (relations.value.candidates.len == 0) {
            // Preserve explicit provider knowledge about a relation that was
            // invalidated or could not be answered. Only a provider that
            // explicitly declines the name contributes to `.absent`.
            for (relations.value.failures) |failure| switch (failure.reason) {
                error.InvalidRelation => return error.InvalidRelation,
                error.Failed => return error.RelationFailed,
                error.Unavailable => return error.RelationUnavailable,
                error.StaleTarget => return error.StaleTarget,
            };
            output.value = .absent;
            return output;
        }

        // A malformed or stale edge is never allowed to become a different
        // valid edge by provider registration order.  Validate every result
        // before deciding whether one or several providers answered.
        for (relations.value.candidates) |candidate| {
            if (!std.mem.eql(u8, candidate.relation.name, name)) return error.InvalidRelation;
            const located = candidate.relation.target;
            if (located.target.authority != self.targets.authority) return error.InvalidRelation;
            const descriptor = self.targets.get(located.target) orelse return error.StaleTarget;
            if (descriptor.revision != located.revision) return error.StaleTarget;
            validateLocation(located.location) catch return error.InvalidRelation;
        }
        if (relations.value.candidates.len != 1) {
            output.value = .{ .ambiguous = .{ .count = relations.value.candidates.len } };
            return output;
        }
        output.value = .{ .resolved = try cloneLocated(output.arena.allocator(), relations.value.candidates[0].relation.target) };
        return output;
    }

    /// Revoke behavior-bearing endpoints before the plugin frees the objects
    /// behind them. Generation bumps make every retained view/field/target or
    /// handler reference stale; resources belonging to other plugins remain.
    pub fn releaseOwner(self: *Services, gpa: std.mem.Allocator, owner: semantic.owner.Id) Released {
        const target_handlers = self.target_handlers.unregisterOwner(gpa, owner);
        const target_relations = self.target_relations.unregisterOwner(gpa, owner);
        const action_provider = self.actions.unregister(gpa, owner);
        const views = self.views.closeOwner(gpa, owner);
        const fields = self.fields.removeOwner(gpa, owner);
        const targets = self.targets.closeOwner(gpa, owner);
        return .{
            .targets = targets,
            .target_handlers = target_handlers,
            .target_relations = target_relations,
            .views = views,
            .fields = fields,
            .action_provider = action_provider,
        };
    }

    /// Scene facts remain descriptive; live typed references are admitted
    /// here. A copied target handle is insufficient after replacement: each
    /// link names the exact descriptor revision it was authored against.
    fn validateSceneRefs(self: *const Services, node: semantic.scene.Node, depth: usize) error{ StaleField, StaleTarget, TooDeep }!void {
        if (depth > 1024) return error.TooDeep;
        if (node.target) |link| {
            const descriptor = self.targets.get(link.target) orelse return error.StaleTarget;
            if (descriptor.revision != link.revision) return error.StaleTarget;
        }
        switch (node.content) {
            .field => |field| if (self.fields.get(field.ref) == null) return error.StaleField,
            .container => |container| for (container.children) |child| try self.validateSceneRefs(child, depth + 1),
            .label, .action => {},
        }
    }

    pub const OpenInteractionError = view_runtime.interaction.Error || error{
        StaleView,
        UnknownRoot,
    };

    pub const InvokeActionError = view_runtime.action.Error || OpenInteractionError || semantic.transfer.ValidationError || ResolveTargetError || TargetRelationError || OpenTargetError || FocusError || error{ InvalidRegister, UnknownFocusTarget, NoTargetRelation, AmbiguousTargetRelations };
    pub const InvokeInputError = InvokeActionError || view_runtime.interaction.Error;

    pub const FocusError = view_runtime.view.Error;
    pub const FieldInputError = view_runtime.field.Error || error{StaleField};
    pub const FocusedTargetError = error{ StaleView, StaleTarget };

    /// Attach one live retained view to exactly one head. A preferred node is
    /// accepted only while it exists in that view; stale preferences recover
    /// to the view's first focusable node, or its root when none are
    /// focusable. The path is copied into the head, so no view or scene
    /// storage escapes this call.
    pub fn focusView(
        self: *const Services,
        head: *Head,
        gpa: std.mem.Allocator,
        ref: semantic.view.Ref,
        preferred: ?semantic.scene.NodeId,
    ) FocusError!semantic.scene.NodeId {
        const instance = self.views.get(ref) orelse return error.StaleView;
        const selected = if (preferred) |candidate|
            if (instance.node(candidate) != null) candidate else instance.reconcileFocus(null) orelse instance.descriptor.root
        else
            instance.reconcileFocus(null) orelse instance.descriptor.root;
        var storage: [1026]semantic.scene.NodeId = undefined;
        const path = (try instance.focusPath(selected, &storage)) orelse return error.StaleView;
        try head.semantic_focus.set(gpa, path);
        return selected;
    }

    /// Return the closest target link on one head's retained focus path. The
    /// value is borrowed only for synchronous dispatch; the view registry owns
    /// any location payload. A target replacement is an explicit stale result,
    /// never an opportunity to reinterpret the old scene against new facts.
    pub fn focusedTarget(
        self: *const Services,
        head: *Head,
    ) FocusedTargetError!?semantic.target.Located {
        const path = head.semantic_focus.path() orelse return null;
        const instance = self.views.get(path.view) orelse {
            head.semantic_focus.clear();
            return error.StaleView;
        };
        var index = path.nodes.len;
        while (index > 0) {
            index -= 1;
            const node = instance.node(path.nodes[index]) orelse continue;
            const link = node.target orelse continue;
            const descriptor = self.targets.get(link.target) orelse return error.StaleTarget;
            if (descriptor.revision != link.revision) return error.StaleTarget;
            return link;
        }
        return null;
    }

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
        interaction_opened: semantic.interaction.Ref,
        target_opened: semantic.view.Ref,
        relation_opened: semantic.view.Ref,
        focus_requested: struct {
            view: semantic.view.Ref,
            node: semantic.scene.NodeId,
        },
    };

    /// Invoke against the view owner's provider, then absorb any cross-view
    /// effect into the correct lifetime: transfers become system-owned and
    /// dialogs become head-owned. Provider memory never escapes the call.
    pub fn invokeAction(
        self: *Services,
        stack: *view_runtime.interaction.Stack,
        gpa: std.mem.Allocator,
        request: semantic.action.Request,
    ) InvokeActionError!ActionEffect {
        return self.invokeActionInRegister(stack, gpa, request, 0);
    }

    pub fn invokeActionInRegister(
        self: *Services,
        stack: *view_runtime.interaction.Stack,
        gpa: std.mem.Allocator,
        request: semantic.action.Request,
        register: u8,
    ) InvokeActionError!ActionEffect {
        if (register > 26) return error.InvalidRegister;
        const with_transfer = self.withCurrentTransfer(request, register);
        const outcome = try self.actions.invoke(&self.views, with_transfer);
        return self.absorbActionOutcome(stack, gpa, with_transfer.view, outcome, register);
    }

    fn withCurrentTransfer(self: *Services, request: semantic.action.Request, register: u8) semantic.action.Request {
        var with_transfer = request;
        if (with_transfer.transfer == null) {
            if (register != 0) {
                const slot = if (register <= 26) self.named_transfers[register - 1] else null;
                if (slot == null) return with_transfer;
                with_transfer.transfer = slot.?.value;
            } else if (self.transfer) |*item| with_transfer.transfer = item.value;
        }
        return with_transfer;
    }

    fn absorbActionOutcome(
        self: *Services,
        stack: *view_runtime.interaction.Stack,
        gpa: std.mem.Allocator,
        view: semantic.view.Ref,
        outcome: semantic.action.Outcome,
        register: u8,
    ) InvokeActionError!ActionEffect {
        return switch (outcome) {
            .declined => .declined,
            .handled => .handled,
            .transfer => |item| blk: {
                var unnamed = try semantic.transfer.OwnedItem.init(gpa, item);
                errdefer unnamed.deinit();
                var named: ?semantic.transfer.OwnedItem = null;
                errdefer if (named) |*value| value.deinit();
                if (register != 0 and register <= 26)
                    named = try semantic.transfer.OwnedItem.init(gpa, item);
                if (self.transfer) |*prior| prior.deinit();
                self.transfer = unnamed;
                if (register != 0 and register <= 26) {
                    const slot = &self.named_transfers[register - 1];
                    if (slot.*) |*prior| prior.deinit();
                    slot.* = named.?;
                    named = null;
                }
                break :blk .transfer_stored;
            },
            .interaction => |definition| .{ .interaction_opened = try self.openInteraction(stack, gpa, definition) },
            .open_target => |located| switch (try self.openLocatedTarget(gpa, located)) {
                .opened => |opened_view| .{ .target_opened = opened_view },
                .no_handler => error.NoTargetHandler,
                .ambiguous => error.AmbiguousTargetHandlers,
            },
            .open_relation => |request| blk: {
                var relation = try self.resolveTargetRelation(gpa, request.source, request.name);
                defer relation.deinit();
                const located = switch (relation.value) {
                    .absent => return error.NoTargetRelation,
                    .ambiguous => return error.AmbiguousTargetRelations,
                    .resolved => |value| value,
                };
                break :blk switch (try self.openLocatedTarget(gpa, located)) {
                    .opened => |opened_view| .{ .relation_opened = opened_view },
                    .no_handler => error.NoTargetHandler,
                    .ambiguous => error.AmbiguousTargetHandlers,
                };
            },
            .focus => |node| blk: {
                const instance = self.views.get(view) orelse return error.StaleView;
                if (instance.node(node) == null) return error.UnknownFocusTarget;
                break :blk .{ .focus_requested = .{ .view = view, .node = node } };
            },
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
        head: *Head,
        gpa: std.mem.Allocator,
        input: []const u8,
    ) InvokeInputError!?ActionEffect {
        const active = stack.active() orelse return null;
        const action = active.actionForInput(input) orelse return null;
        const interaction_ref = active.descriptor.ref;
        const disposition = action.disposition;
        const prior_focus = head.semantic_focus.path();
        const effect = self.invokeInteractionAction(stack, gpa, .{
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
        try self.applyActionFocus(head, gpa, prior_focus, effect);
        if (disposition == .close_on_handled) switch (effect) {
            .handled, .transfer_stored, .target_opened, .relation_opened, .focus_requested => try stack.close(gpa, interaction_ref),
            .declined, .interaction_opened => {},
        };
        return effect;
    }

    fn invokeInteractionAction(
        self: *Services,
        stack: *view_runtime.interaction.Stack,
        gpa: std.mem.Allocator,
        request: semantic.action.Request,
    ) InvokeActionError!ActionEffect {
        const with_transfer = self.withCurrentTransfer(request, 0);
        const outcome = try self.actions.invokeInteraction(&self.views, with_transfer);
        return self.absorbActionOutcome(stack, gpa, with_transfer.view, outcome, 0);
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
        return self.invokeFocusedActionInRegister(stack, head, gpa, action, 0);
    }

    pub fn invokeFocusedActionInRegister(
        self: *Services,
        stack: *view_runtime.interaction.Stack,
        head: *Head,
        gpa: std.mem.Allocator,
        action: []const u8,
        register: u8,
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
                const prior_focus = head.semantic_focus.path();
                const effect = try self.invokeActionInRegister(stack, gpa, .{
                    .action = action,
                    .view = path.view,
                    .subject = node.id,
                }, register);
                try self.applyActionFocus(head, gpa, prior_focus, effect);
                return effect;
            }
        }
        return error.ActionUnavailable;
    }

    fn applyActionFocus(
        self: *const Services,
        head: *Head,
        gpa: std.mem.Allocator,
        prior_focus: ?semantic.focus.Path,
        effect: ActionEffect,
    ) FocusError!void {
        switch (effect) {
            .target_opened => |view| _ = try self.focusView(head, gpa, view, null),
            .relation_opened => |view| _ = try self.focusView(head, gpa, view, null),
            .focus_requested => |focus| {
                const anchor = if (prior_focus) |path|
                    if (path.view.eql(focus.view))
                        head.semantic_focus.navigation_anchor orelse path.leaf()
                    else
                        null
                else
                    null;
                _ = try self.focusView(head, gpa, focus.view, focus.node);
                if (anchor) |node| head.semantic_focus.setNavigationAnchor(node);
            },
            else => {},
        }
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
        definition: semantic.interaction.Definition,
    ) OpenInteractionError!semantic.interaction.Ref {
        const instance = self.views.get(definition.view) orelse return error.StaleView;
        if (instance.node(definition.root) == null) return error.UnknownRoot;
        return stack.open(gpa, definition);
    }

    /// Close only the active interaction on this head. The stack validates
    /// authority, generation, and strict LIFO order; stale or buried refs
    /// are harmless false results rather than cross-dialog mutations.
    pub fn closeInteraction(
        self: *const Services,
        stack: *view_runtime.interaction.Stack,
        gpa: std.mem.Allocator,
        ref: semantic.interaction.Ref,
    ) bool {
        _ = self;
        stack.close(gpa, ref) catch return false;
        return true;
    }

    /// Move one head through the active view's declared focus order. `false`
    /// means this head has no live semantic view, so a caller may fall back to
    /// its text-editor movement. A live view consumes the intent even when it
    /// has no focusable nodes or is already at an edge.
    pub fn moveHeadFocus(
        self: *const Services,
        head: *Head,
        gpa: std.mem.Allocator,
        movement: semantic.focus.Movement,
    ) FocusError!bool {
        const path = head.semantic_focus.path() orelse return false;
        const instance = self.views.get(path.view) orelse {
            head.semantic_focus.clear();
            return false;
        };
        const current = head.semantic_focus.navigation_anchor orelse path.leaf();
        // The anchor is a one-shot override for this movement intent. A
        // failed edge movement must not make later movement reinterpret the
        // still-focused secondary node as the row anchor.
        head.semantic_focus.setNavigationAnchor(null);
        const next = instance.move(current, movement) orelse return true;
        var storage: [1026]semantic.scene.NodeId = undefined;
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

    /// Resolve an ordinary "edit this field" request without choosing an
    /// editing model. This proves the endpoint is live and writable; Vim,
    /// Helix, Emacs, or a modeless input plugin independently decides how its
    /// subsequent keystrokes become the generic field edits above.
    pub fn requestFocusedFieldEdit(
        self: *const Services,
        head: *Head,
        gpa: std.mem.Allocator,
    ) FieldInputError!bool {
        const path = head.semantic_focus.path() orelse return false;
        const instance = self.views.get(path.view) orelse {
            head.semantic_focus.clear();
            return false;
        };
        const field_ref = path.field orelse return false;
        const leaf = path.leaf() orelse return error.StaleField;
        const node = instance.node(leaf) orelse return error.StaleField;
        switch (node.content) {
            .field => |field| if (!field.ref.eql(field_ref)) return error.StaleField,
            else => return error.StaleField,
        }
        const provider = self.fields.get(field_ref) orelse return error.StaleField;
        var snapshot = try provider.snapshot(gpa);
        defer snapshot.deinit();
        if (snapshot.value.read_only) return error.ReadOnly;
        return true;
    }
};

fn equalStrengthCount(candidates: []const target_runtime.resolver.Candidate, strength: target_runtime.resolver.Strength) usize {
    var count: usize = 0;
    for (candidates) |candidate| {
        if (candidate.strength == strength) count += 1;
    }
    return count;
}

fn validateLocation(location: semantic.target.Location) error{InvalidLocation}!void {
    switch (location) {
        .whole => {},
        .text => |range| if (range.start > range.end) return error.InvalidLocation,
        .node => |node| if (node.len == 0) return error.InvalidLocation,
        .provider => |provider| if (provider.schema.len == 0) return error.InvalidLocation,
    }
}

fn cloneLocated(arena: std.mem.Allocator, located: semantic.target.Located) std.mem.Allocator.Error!semantic.target.Located {
    var copy = located;
    copy.location = switch (located.location) {
        .whole => .whole,
        .text => |range| .{ .text = range },
        .node => |node| .{ .node = try arena.dupe(u8, node) },
        .provider => |provider| .{ .provider = .{
            .schema = try arena.dupe(u8, provider.schema),
            .payload = try arena.dupe(u8, provider.payload),
        } },
    };
    return copy;
}

fn validRelationName(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |byte| if (byte == 0) return false;
    return true;
}

fn collapsed(offset: usize) view_runtime.field.Selection {
    return .{ .anchor = offset, .caret = offset };
}

test "semantic services keep target, view, and field namespaces typed" {
    var services = Services.init(.here);
    defer services.deinit(std.testing.allocator);
    const owner = try services.acquireOwner();
    try std.testing.expectError(error.StaleField, services.publishView(std.testing.allocator, owner, null, 1, .{
        .id = @enumFromInt(99),
        .content = .{ .field = .{ .ref = .{ .authority = .here, .slot = 99, .generation = 1 } } },
    }));
    const target_ref = try services.publishTarget(std.testing.allocator, owner, .{
        .kind = .directory,
        .display_name = "directory",
    });
    try std.testing.expectError(error.StaleTarget, services.publishView(std.testing.allocator, owner, null, 1, .{
        .id = @enumFromInt(98),
        .target = .{ .target = target_ref, .revision = 2 },
        .content = .{ .label = "future target revision" },
    }));
    const view_ref = try services.publishView(std.testing.allocator, owner, target_ref, 1, .{
        .id = @enumFromInt(1),
        .actions = &.{
            .{ .id = semantic.action.standard.copy },
            .{ .id = semantic.action.standard.paste_after },
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
        view: semantic.view.Ref,

        pub fn invoke(self: *@This(), request: semantic.action.Request) view_runtime.action.ProviderError!semantic.action.Outcome {
            if (std.mem.eql(u8, request.action, semantic.action.standard.copy)) return .{ .transfer = .{
                .intent = .copy,
                .suggested_name = "directory",
                .representations = &.{.{ .media_type = "application/test", .payload = "snapshot" }},
            } };
            if (std.mem.eql(u8, request.action, semantic.action.standard.paste_after))
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
    try services.registerActionProvider(std.testing.allocator, owner, .init(&handler));
    const request: semantic.action.Request = .{
        .action = semantic.action.standard.copy,
        .view = view_ref,
        .subject = @enumFromInt(1),
    };
    try std.testing.expect((try services.invokeAction(&interactions, std.testing.allocator, request)) == .transfer_stored);
    try std.testing.expectEqualStrings("snapshot", services.transfer.?.value.representations[0].payload);
    try std.testing.expect((try services.invokeActionInRegister(&interactions, std.testing.allocator, request, 1)) == .transfer_stored);
    try std.testing.expectEqualStrings("snapshot", services.named_transfers[0].?.value.representations[0].payload);
    var paste = request;
    paste.action = semantic.action.standard.paste_after;
    try std.testing.expect((try services.invokeAction(&interactions, std.testing.allocator, paste)) == .handled);
    try std.testing.expect((try services.invokeActionInRegister(&interactions, std.testing.allocator, paste, 1)) == .handled);
    var confirm = request;
    confirm.action = "confirm";
    try std.testing.expect((try services.invokeAction(&interactions, std.testing.allocator, confirm)) == .interaction_opened);
    const released = services.releaseOwner(std.testing.allocator, owner);
    try std.testing.expectEqual(@as(usize, 1), released.targets);
    try std.testing.expectEqual(@as(usize, 1), released.views);
    try std.testing.expect(released.action_provider);
    try std.testing.expect(services.targets.get(target_ref) == null);
    try std.testing.expect(services.views.get(view_ref) == null);
    try std.testing.expectEqual(Services.Released{}, services.releaseOwner(std.testing.allocator, owner));
}

test "semantic action focus stays inside its retained view" {
    const Provider = struct {
        target: semantic.scene.NodeId,

        pub fn invoke(self: *@This(), _: semantic.action.Request) view_runtime.action.ProviderError!semantic.action.Outcome {
            return .{ .focus = self.target };
        }
    };
    const Field = struct {
        edits: usize = 0,

        pub fn snapshot(_: *@This(), gpa: std.mem.Allocator) view_runtime.field.Error!view_runtime.field.OwnedSnapshot {
            var owned = view_runtime.field.OwnedSnapshot.init(gpa);
            owned.value = .{
                .revision = "1",
                .bytes = "old",
                .selection = .{ .anchor = 0, .caret = 3 },
                .single_line = true,
            };
            return owned;
        }

        pub fn edit(self: *@This(), expected: []const u8, _: view_runtime.field.Edit) view_runtime.field.Error!void {
            if (!std.mem.eql(u8, expected, "1")) return error.Stale;
            self.edits += 1;
        }
    };

    var services = Services.init(.here);
    defer services.deinit(std.testing.allocator);
    const owner = try services.acquireOwner();
    var field: Field = .{};
    const field_ref = try services.insertField(std.testing.allocator, owner, .init(&field));
    const first: semantic.scene.Node = .{
        .id = @enumFromInt(2),
        .focusable = true,
        .content = .{ .label = "first" },
    };
    const row: semantic.scene.Node = .{
        .id = @enumFromInt(3),
        .focusable = true,
        .actions = &.{.{ .id = "field.secondary" }},
        .content = .{ .label = "row" },
    };
    const secondary: semantic.scene.Node = .{
        .id = @enumFromInt(4),
        // Secondary nodes need not participate in ordinary row traversal.
        .focusable = false,
        .content = .{ .field = .{ .ref = field_ref, .single_line = true } },
    };
    const last: semantic.scene.Node = .{
        .id = @enumFromInt(5),
        .focusable = true,
        .content = .{ .label = "last" },
    };
    const view_ref = try services.publishView(std.testing.allocator, owner, null, 1, .{
        .id = @enumFromInt(1),
        .content = .{ .container = .{ .children = &.{ first, row, secondary, last } } },
    });
    var provider: Provider = .{ .target = secondary.id };
    try services.registerActionProvider(std.testing.allocator, owner, .init(&provider));
    var head: Head = .empty;
    defer head.deinit(std.testing.allocator);
    _ = try services.focusView(&head, std.testing.allocator, view_ref, row.id);

    const effect = (try services.invokeFocusedAction(&head.interactions, &head, std.testing.allocator, "field.secondary")).?;
    try std.testing.expect(effect == .focus_requested);
    try std.testing.expectEqual(secondary.id, head.semantic_focus.path().?.leaf().?);
    try std.testing.expect(head.semantic_focus.path().?.field.?.eql(field_ref));
    try std.testing.expect(try services.inputFocusedField(&head, std.testing.allocator, .{ .replace_selection = "new" }));
    try std.testing.expectEqual(@as(usize, 1), field.edits);
    try std.testing.expect(try services.moveHeadFocus(&head, std.testing.allocator, .next));
    try std.testing.expectEqual(last.id, head.semantic_focus.path().?.leaf().?);

    // Re-enter the secondary field from the middle row and move backwards:
    // the one-shot anchor is the row, not the non-focusable field node.
    _ = try services.focusView(&head, std.testing.allocator, view_ref, row.id);
    _ = try services.invokeFocusedAction(&head.interactions, &head, std.testing.allocator, "field.secondary");
    try std.testing.expect(try services.moveHeadFocus(&head, std.testing.allocator, .previous));
    try std.testing.expectEqual(first.id, head.semantic_focus.path().?.leaf().?);

    provider.target = @enumFromInt(99);
    try std.testing.expectError(error.UnknownFocusTarget, services.invokeAction(&head.interactions, std.testing.allocator, .{
        .action = "field.secondary",
        .view = view_ref,
        .subject = row.id,
    }));
    try std.testing.expectEqual(first.id, head.semantic_focus.path().?.leaf().?);
}

test "semantic target relations resolve, stay absent, and reject stale or ambiguous edges" {
    const Opener = struct {
        pub fn probe(_: *@This(), _: semantic.target.Descriptor) target_runtime.resolver.ProbeError!?target_runtime.resolver.Strength {
            return null;
        }
        pub fn open(_: *@This(), _: semantic.target.Located) target_runtime.resolver.OpenError!semantic.view.Ref {
            return error.Rejected;
        }
    };
    const RelationProvider = struct {
        destination: semantic.target.Located,
        wrong_name: bool = false,
        foreign_authority: bool = false,
        unavailable: bool = false,
        failed: bool = false,

        pub fn query(self: *@This(), request: target_runtime.relation.Query) target_runtime.relation.QueryError!?target_runtime.relation.Relation {
            if (self.unavailable) return error.Unavailable;
            if (self.failed) return error.Failed;
            if (!std.mem.eql(u8, request.name, "container")) return null;
            var target = self.destination;
            if (self.foreign_authority) target.target.authority = @enumFromInt(99);
            return .{ .name = if (self.wrong_name) "other" else request.name, .target = target };
        }
    };

    var services = Services.init(.here);
    defer services.deinit(std.testing.allocator);
    const target_owner: semantic.owner.Id = @enumFromInt(1);
    const opener_owner: semantic.owner.Id = @enumFromInt(2);
    const relation_owner: semantic.owner.Id = @enumFromInt(3);
    const source_ref = try services.publishTarget(std.testing.allocator, target_owner, .{ .kind = .file, .display_name = "child" });
    const parent_ref = try services.publishTarget(std.testing.allocator, target_owner, .{ .kind = .directory, .display_name = "parent" });
    const source = semantic.target.Located{ .target = source_ref, .revision = 1 };
    const destination = semantic.target.Located{
        .target = parent_ref,
        .revision = 1,
        .location = .{ .provider = .{ .schema = "tree", .payload = "root" } },
    };
    var opener = Opener{};
    const opener_ref = try services.registerTargetHandler(std.testing.allocator, opener_owner, "opener", .init(&opener));
    var first = RelationProvider{ .destination = destination };
    const relation_ref = try services.registerTargetRelationProvider(std.testing.allocator, relation_owner, "relations-a", .init(&first));
    try std.testing.expectEqual(opener_owner, services.target_handlers.descriptor(opener_ref).?.owner);
    try std.testing.expectEqual(relation_owner, services.target_relations.descriptor(relation_ref).?.owner);

    var resolved = try services.resolveTargetRelation(std.testing.allocator, source, "container");
    defer resolved.deinit();
    try std.testing.expectEqual(destination.target, resolved.value.resolved.target);
    try std.testing.expectEqual(destination.revision, resolved.value.resolved.revision);
    switch (resolved.value.resolved.location) {
        .provider => |provider| {
            try std.testing.expectEqualStrings("tree", provider.schema);
            try std.testing.expectEqualStrings("root", provider.payload);
        },
        else => return error.TestUnexpectedResult,
    }
    var absent = try services.resolveTargetRelation(std.testing.allocator, source, "parent");
    defer absent.deinit();
    try std.testing.expectEqual(Services.TargetRelationResult.absent, absent.value);
    try std.testing.expectError(error.StaleTarget, services.resolveTargetRelation(std.testing.allocator, .{ .target = source_ref, .revision = 2 }, "container"));
    try std.testing.expectError(error.InvalidRelation, services.resolveTargetRelation(std.testing.allocator, source, ""));

    var stale = RelationProvider{ .destination = .{ .target = parent_ref, .revision = 2 } };
    const stale_handler = try services.registerTargetRelationProvider(std.testing.allocator, relation_owner, "relations-stale", .init(&stale));
    try std.testing.expectError(error.StaleTarget, services.resolveTargetRelation(std.testing.allocator, source, "container"));
    try std.testing.expect(services.target_relations.unregister(std.testing.allocator, stale_handler));

    var second = RelationProvider{ .destination = destination };
    _ = try services.registerTargetRelationProvider(std.testing.allocator, relation_owner, "relations-b", .init(&second));
    var ambiguous = try services.resolveTargetRelation(std.testing.allocator, source, "container");
    defer ambiguous.deinit();
    try std.testing.expectEqual(@as(usize, 2), ambiguous.value.ambiguous.count);

    var malformed = RelationProvider{ .destination = destination, .wrong_name = true };
    _ = try services.registerTargetRelationProvider(std.testing.allocator, relation_owner, "relations-c", .init(&malformed));
    try std.testing.expectError(error.InvalidRelation, services.resolveTargetRelation(std.testing.allocator, source, "container"));

    var foreign = RelationProvider{ .destination = destination, .foreign_authority = true };
    _ = try services.registerTargetRelationProvider(std.testing.allocator, relation_owner, "relations-d", .init(&foreign));
    try std.testing.expectError(error.InvalidRelation, services.resolveTargetRelation(std.testing.allocator, source, "container"));
    const released = services.releaseOwner(std.testing.allocator, relation_owner);
    try std.testing.expectEqual(@as(usize, 4), released.target_relations);
    try std.testing.expect(services.target_handlers.descriptor(opener_ref) != null);

    var unavailable = RelationProvider{ .destination = destination, .unavailable = true };
    _ = try services.registerTargetRelationProvider(std.testing.allocator, relation_owner, "unavailable", .init(&unavailable));
    try std.testing.expectError(error.RelationUnavailable, services.resolveTargetRelation(std.testing.allocator, source, "container"));
    _ = services.releaseOwner(std.testing.allocator, relation_owner);
    var failed = RelationProvider{ .destination = destination, .failed = true };
    _ = try services.registerTargetRelationProvider(std.testing.allocator, relation_owner, "failed", .init(&failed));
    try std.testing.expectError(error.RelationFailed, services.resolveTargetRelation(std.testing.allocator, source, "container"));
}

test "semantic relation action resolves through independent provider and handler owners" {
    const ActionProvider = struct {
        request: semantic.action.RelationRequest,

        pub fn invoke(self: *@This(), _: semantic.action.Request) view_runtime.action.ProviderError!semantic.action.Outcome {
            return .{ .open_relation = self.request };
        }
    };
    const RelationProvider = struct {
        destination: semantic.target.Located,
        pub fn query(self: *@This(), request: target_runtime.relation.Query) target_runtime.relation.QueryError!?target_runtime.relation.Relation {
            if (!std.mem.eql(u8, request.name, "container")) return null;
            return .{ .name = request.name, .target = self.destination };
        }
    };
    const Handler = struct {
        view: semantic.view.Ref,
        opened: usize = 0,

        pub fn probe(_: *@This(), descriptor: semantic.target.Descriptor) target_runtime.resolver.ProbeError!?target_runtime.resolver.Strength {
            return switch (descriptor.kind) {
                .synthetic => |kind| if (std.mem.eql(u8, kind, "parent")) .exact else null,
                else => null,
            };
        }

        pub fn open(self: *@This(), located: semantic.target.Located) target_runtime.resolver.OpenError!semantic.view.Ref {
            if (located.location != .whole) return error.Rejected;
            self.opened += 1;
            return self.view;
        }
    };

    var services = Services.init(.here);
    defer services.deinit(std.testing.allocator);
    const target_owner = try services.acquireOwner();
    const action_owner = try services.acquireOwner();
    const relation_owner = try services.acquireOwner();
    const opener_owner = try services.acquireOwner();
    const source_ref = try services.publishTarget(std.testing.allocator, target_owner, .{
        .kind = .{ .synthetic = "child" },
        .display_name = "child",
    });
    const destination_ref = try services.publishTarget(std.testing.allocator, target_owner, .{
        .kind = .{ .synthetic = "parent" },
        .display_name = "parent",
    });
    const source = semantic.target.Located{ .target = source_ref, .revision = 1 };
    const destination = semantic.target.Located{ .target = destination_ref, .revision = 1 };
    const original = try services.publishView(std.testing.allocator, action_owner, null, 1, .{
        .id = @enumFromInt(1),
        .actions = &.{.{ .id = "open-parent" }},
        .content = .{ .label = "child view" },
    });
    const destination_view = try services.publishView(std.testing.allocator, opener_owner, destination_ref, 1, .{
        .id = @enumFromInt(2),
        .focusable = true,
        .content = .{ .label = "parent view" },
    });
    var handler: Handler = .{ .view = destination_view };
    _ = try services.registerTargetHandler(std.testing.allocator, opener_owner, "parent-opener", .init(&handler));
    var relation_provider: RelationProvider = .{ .destination = destination };
    _ = try services.registerTargetRelationProvider(std.testing.allocator, relation_owner, "containment", .init(&relation_provider));
    var action_provider: ActionProvider = .{ .request = .{ .source = source, .name = "container" } };
    try services.registerActionProvider(std.testing.allocator, action_owner, .init(&action_provider));

    var head: Head = .empty;
    defer head.deinit(std.testing.allocator);
    _ = try services.focusView(&head, std.testing.allocator, original, @enumFromInt(1));
    const effect = (try services.invokeFocusedAction(&head.interactions, &head, std.testing.allocator, "open-parent")).?;
    try std.testing.expectEqual(destination_view, effect.relation_opened);
    try std.testing.expectEqual(@as(usize, 1), handler.opened);
    try std.testing.expectEqual(destination_view, head.semantic_focus.path().?.view);

    // The source revision is part of the request, so replacement cannot make
    // the same provider response silently open a newer target.
    try services.replaceTarget(std.testing.allocator, target_owner, source_ref, .{
        .kind = .{ .synthetic = "child" },
        .display_name = "replaced child",
    });
    try std.testing.expectError(error.StaleTarget, services.invokeAction(&head.interactions, std.testing.allocator, .{
        .action = "open-parent",
        .view = original,
        .subject = @enumFromInt(1),
    }));
}

test "target opening is revision guarded and confines handlers to their own attached views" {
    const Handler = struct {
        view: semantic.view.Ref,
        probes: usize = 0,
        opens: usize = 0,

        pub fn probe(self: *@This(), descriptor: semantic.target.Descriptor) target_runtime.resolver.ProbeError!?target_runtime.resolver.Strength {
            self.probes += 1;
            return if (descriptor.kind == .directory) .exact else null;
        }

        pub fn open(self: *@This(), _: semantic.target.Located) target_runtime.resolver.OpenError!semantic.view.Ref {
            self.opens += 1;
            return self.view;
        }
    };

    var services = Services.init(.here);
    defer services.deinit(std.testing.allocator);
    const producer = try services.acquireOwner();
    const opener = try services.acquireOwner();
    const foreign_owner = try services.acquireOwner();
    const target_ref = try services.publishTarget(std.testing.allocator, producer, .{
        .kind = .directory,
        .display_name = "directory",
    });
    const view_ref = try services.publishView(std.testing.allocator, opener, target_ref, 1, .{
        .id = @enumFromInt(1),
        .content = .{ .label = "directory" },
    });
    var handler: Handler = .{ .view = view_ref };
    const handler_ref = try services.registerTargetHandler(std.testing.allocator, opener, "directory", .init(&handler));

    var first = try services.resolveTarget(std.testing.allocator, target_ref);
    defer first.deinit();
    try std.testing.expectEqual(@as(usize, 1), first.handlers.value.candidates.len);
    const selected = first.handlers.value.decide().selected;
    try std.testing.expect(selected.eql(handler_ref));
    try std.testing.expectEqual(view_ref, try services.openTarget(selected, first.located(.whole)));

    // Handle generation remains live across replacement, but the resolved
    // revision is stale and the provider is not called a second time.
    try services.replaceTarget(std.testing.allocator, producer, target_ref, .{
        .kind = .directory,
        .display_name = "renamed",
    });
    try std.testing.expectError(error.StaleTarget, services.openTarget(selected, first.located(.whole)));
    try std.testing.expectEqual(@as(usize, 1), handler.opens);

    var current = try services.resolveTarget(std.testing.allocator, target_ref);
    defer current.deinit();
    try std.testing.expectError(error.InvalidLocation, services.openTarget(selected, current.located(.{ .text = .{ .start = 9, .end = 2 } })));
    try std.testing.expectEqual(@as(usize, 1), handler.opens);
    // A handler cannot answer the new target revision with a retained view
    // bound to the old one, even though both typed handles remain live.
    try std.testing.expectError(error.ViewTargetMismatch, services.openTarget(selected, current.located(.whole)));
    try std.testing.expectEqual(@as(usize, 2), handler.opens);

    const foreign_view = try services.publishView(std.testing.allocator, foreign_owner, target_ref, 1, .{
        .id = @enumFromInt(2),
        .content = .{ .label = "foreign" },
    });
    var foreign: Handler = .{ .view = foreign_view };
    const foreign_handler = try services.registerTargetHandler(std.testing.allocator, opener, "foreign", .init(&foreign));
    try std.testing.expectError(error.HandlerOwnerMismatch, services.openTarget(foreign_handler, current.located(.whole)));

    const other_target = try services.publishTarget(std.testing.allocator, producer, .{
        .kind = .directory,
        .display_name = "other",
    });
    const unrelated_view = try services.publishView(std.testing.allocator, opener, other_target, 1, .{
        .id = @enumFromInt(3),
        .content = .{ .label = "other" },
    });
    var unrelated: Handler = .{ .view = unrelated_view };
    const unrelated_handler = try services.registerTargetHandler(std.testing.allocator, opener, "unrelated", .init(&unrelated));
    try std.testing.expectError(error.ViewTargetMismatch, services.openTarget(unrelated_handler, current.located(.whole)));
}

test "semantic open-target actions use the nearest subject and preserve fallback, stale, and provider errors" {
    const ActionProvider = struct {
        located: semantic.target.Located,
        calls: usize = 0,
        last_subject: semantic.scene.NodeId = @enumFromInt(0),

        pub fn invoke(self: *@This(), request: semantic.action.Request) view_runtime.action.ProviderError!semantic.action.Outcome {
            self.calls += 1;
            self.last_subject = request.subject;
            return .{ .open_target = self.located };
        }
    };
    const TargetHandler = struct {
        view: semantic.view.Ref,
        kind: []const u8,
        fail: bool = false,

        pub fn probe(self: *@This(), descriptor: semantic.target.Descriptor) target_runtime.resolver.ProbeError!?target_runtime.resolver.Strength {
            return switch (descriptor.kind) {
                .synthetic => |kind| if (std.mem.eql(u8, kind, self.kind)) .exact else null,
                else => null,
            };
        }

        pub fn open(self: *@This(), _: semantic.target.Located) target_runtime.resolver.OpenError!semantic.view.Ref {
            if (self.fail) return error.Failed;
            return self.view;
        }
    };

    var services = Services.init(.here);
    defer services.deinit(std.testing.allocator);
    const owner = try services.acquireOwner();
    const target = try services.publishTarget(std.testing.allocator, owner, .{
        .kind = .{ .synthetic = "resource" },
        .display_name = "resource",
    });
    const child = semantic.scene.Node{ .id = @enumFromInt(2), .actions = &.{.{ .id = "open", .label = "Open" }}, .content = .{ .label = "child" } };
    const original = try services.publishView(std.testing.allocator, owner, null, 1, .{
        .id = @enumFromInt(1),
        .actions = &.{.{ .id = "open", .label = "Open" }},
        .content = .{ .container = .{ .children = &.{child} } },
    });
    const opened_view = try services.publishView(std.testing.allocator, owner, target, 1, .{
        .id = @enumFromInt(10),
        .focusable = true,
        .content = .{ .label = "opened" },
    });
    var target_handler: TargetHandler = .{ .view = opened_view, .kind = "resource" };
    _ = try services.registerTargetHandler(std.testing.allocator, owner, "resource", .init(&target_handler));
    var action_provider: ActionProvider = .{ .located = .{ .target = target, .revision = 1 } };
    try services.registerActionProvider(std.testing.allocator, owner, .init(&action_provider));

    var head: Head = .empty;
    defer head.deinit(std.testing.allocator);
    _ = try services.focusView(&head, std.testing.allocator, original, @enumFromInt(2));
    const effect = (try services.invokeFocusedAction(&head.interactions, &head, std.testing.allocator, "open")).?;
    try std.testing.expectEqual(@as(usize, 1), action_provider.calls);
    try std.testing.expectEqual(@as(semantic.scene.NodeId, @enumFromInt(2)), action_provider.last_subject);
    try std.testing.expectEqual(opened_view, effect.target_opened);
    try std.testing.expectEqual(opened_view, head.semantic_focus.path().?.view);
    // Re-select the source view for the following requests: opening is a
    // head-local admission plus focus operation, so the new view is now the
    // active subject just as it would be for an ordinary user action.
    _ = try services.focusView(&head, std.testing.allocator, original, @enumFromInt(2));

    // A target replacement invalidates the provider's captured Located value;
    // it must not fall through as an ordinary unhandled action.
    try services.replaceTarget(std.testing.allocator, owner, target, .{ .kind = .{ .synthetic = "resource" }, .display_name = "new" });
    try std.testing.expectError(error.StaleTarget, services.invokeFocusedAction(&head.interactions, &head, std.testing.allocator, "open"));

    // Provider failures remain errors after resolution, and an affirmative
    // open request never silently falls through when no handler exists.
    const error_target = try services.publishTarget(std.testing.allocator, owner, .{ .kind = .{ .synthetic = "error" }, .display_name = "error" });
    const error_view = try services.publishView(std.testing.allocator, owner, error_target, 1, .{ .id = @enumFromInt(11), .content = .{ .label = "error" } });
    var failing_handler: TargetHandler = .{ .view = error_view, .kind = "error", .fail = true };
    _ = try services.registerTargetHandler(std.testing.allocator, owner, "error", .init(&failing_handler));
    action_provider.located = .{ .target = error_target, .revision = 1 };
    try std.testing.expectError(error.Failed, services.invokeFocusedAction(&head.interactions, &head, std.testing.allocator, "open"));

    const fallback_target = try services.publishTarget(std.testing.allocator, owner, .{ .kind = .{ .synthetic = "fallback" }, .display_name = "fallback" });
    action_provider.located = .{ .target = fallback_target, .revision = 1 };
    try std.testing.expectError(error.NoTargetHandler, services.invokeFocusedAction(&head.interactions, &head, std.testing.allocator, "open"));

    const ambiguous_target = try services.publishTarget(std.testing.allocator, owner, .{ .kind = .{ .synthetic = "ambiguous" }, .display_name = "ambiguous" });
    const ambiguous_view_a = try services.publishView(std.testing.allocator, owner, ambiguous_target, 1, .{ .id = @enumFromInt(12), .content = .{ .label = "a" } });
    const ambiguous_view_b = try services.publishView(std.testing.allocator, owner, ambiguous_target, 1, .{ .id = @enumFromInt(13), .content = .{ .label = "b" } });
    var ambiguous_handler_a: TargetHandler = .{ .view = ambiguous_view_a, .kind = "ambiguous" };
    var ambiguous_handler_b: TargetHandler = .{ .view = ambiguous_view_b, .kind = "ambiguous" };
    _ = try services.registerTargetHandler(std.testing.allocator, owner, "ambiguous-a", .init(&ambiguous_handler_a));
    _ = try services.registerTargetHandler(std.testing.allocator, owner, "ambiguous-b", .init(&ambiguous_handler_b));
    action_provider.located = .{ .target = ambiguous_target, .revision = 1 };
    try std.testing.expectError(error.AmbiguousTargetHandlers, services.invokeFocusedAction(&head.interactions, &head, std.testing.allocator, "open"));
}

test "semantic view focus is head-scoped with preferred and root fallback" {
    var services = Services.init(.here);
    defer services.deinit(std.testing.allocator);
    const owner = try services.acquireOwner();
    const children = [_]semantic.scene.Node{
        .{ .id = @enumFromInt(2), .focusable = true, .content = .{ .label = "first" } },
        .{ .id = @enumFromInt(3), .focusable = true, .content = .{ .label = "second" } },
    };
    const view_ref = try services.publishView(std.testing.allocator, owner, null, 1, .{
        .id = @enumFromInt(1),
        .content = .{ .container = .{ .children = &children } },
    });
    var head_a: Head = .empty;
    defer head_a.deinit(std.testing.allocator);
    var head_b: Head = .empty;
    defer head_b.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(semantic.scene.NodeId, @enumFromInt(3)), try services.focusView(&head_a, std.testing.allocator, view_ref, @enumFromInt(3)));
    try std.testing.expectEqual(@as(semantic.scene.NodeId, @enumFromInt(3)), head_a.semantic_focus.path().?.leaf().?);
    try std.testing.expectEqual(@as(semantic.scene.NodeId, @enumFromInt(2)), try services.focusView(&head_b, std.testing.allocator, view_ref, null));
    try std.testing.expectEqual(@as(semantic.scene.NodeId, @enumFromInt(2)), head_b.semantic_focus.path().?.leaf().?);
    // An unknown preference recovers without disturbing the other head.
    try std.testing.expectEqual(@as(semantic.scene.NodeId, @enumFromInt(2)), try services.focusView(&head_a, std.testing.allocator, view_ref, @enumFromInt(99)));
    try std.testing.expectEqual(@as(semantic.scene.NodeId, @enumFromInt(2)), head_a.semantic_focus.path().?.leaf().?);
    try std.testing.expectEqual(@as(semantic.scene.NodeId, @enumFromInt(2)), head_b.semantic_focus.path().?.leaf().?);

    var foreign = view_ref;
    foreign.authority = @enumFromInt(42);
    try std.testing.expectError(error.StaleView, services.focusView(&head_a, std.testing.allocator, foreign, null));
    try std.testing.expectEqual(@as(semantic.scene.NodeId, @enumFromInt(2)), head_a.semantic_focus.path().?.leaf().?);
    try std.testing.expect(services.closeView(std.testing.allocator, owner, view_ref));
    try std.testing.expectError(error.StaleView, services.focusView(&head_b, std.testing.allocator, view_ref, null));

    const root_only = try services.publishView(std.testing.allocator, owner, null, 1, .{
        .id = @enumFromInt(10),
        .content = .{ .label = "root" },
    });
    try std.testing.expectEqual(@as(semantic.scene.NodeId, @enumFromInt(10)), try services.focusView(&head_b, std.testing.allocator, root_only, null));
    try std.testing.expectEqual(@as(semantic.scene.NodeId, @enumFromInt(10)), head_b.semantic_focus.path().?.leaf().?);
}

test "interaction-local input invokes semantic action and closes explicitly" {
    var services = Services.init(.here);
    defer services.deinit(std.testing.allocator);
    const owner = try services.acquireOwner();
    const root: semantic.scene.Node = .{
        .id = @enumFromInt(1),
        .actions = &.{.{ .id = "confirm" }},
        .content = .{ .label = "Apply changes?" },
    };
    const view_ref = try services.publishView(std.testing.allocator, owner, null, 1, root);
    const Handler = struct {
        calls: usize = 0,
        pub fn invoke(self: *@This(), _: semantic.action.Request) view_runtime.action.ProviderError!semantic.action.Outcome {
            self.calls += 1;
            return .handled;
        }
    };
    var handler: Handler = .{};
    try services.registerActionProvider(std.testing.allocator, owner, .init(&handler));
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
    var head: Head = .empty;
    defer head.deinit(std.testing.allocator);
    try std.testing.expect(try services.invokeInteractionInput(&interactions, &head, std.testing.allocator, "x") == null);
    try std.testing.expect((try services.invokeInteractionInput(&interactions, &head, std.testing.allocator, "y")).? == .handled);
    try std.testing.expectEqual(@as(usize, 1), handler.calls);
    try std.testing.expect(interactions.active() == null);

    _ = try services.openInteraction(&interactions, std.testing.allocator, .{
        .role = .dialog,
        .view = view_ref,
        .root = @enumFromInt(1),
        .actions = &.{.{ .id = "confirm" }},
        .bindings = &.{.{ .input = "y", .action = "confirm" }},
    });
    _ = services.releaseOwner(std.testing.allocator, owner);
    try std.testing.expect((try services.invokeInteractionInput(&interactions, &head, std.testing.allocator, "y")).? == .declined);
    try std.testing.expect(interactions.active() == null);
}

test "interaction-local target opens focus the admitted view on its head" {
    const ActionProvider = struct {
        located: semantic.target.Located,

        pub fn invoke(self: *@This(), _: semantic.action.Request) view_runtime.action.ProviderError!semantic.action.Outcome {
            return .{ .open_target = self.located };
        }
    };
    const TargetHandler = struct {
        view: semantic.view.Ref,

        pub fn probe(_: *@This(), descriptor: semantic.target.Descriptor) target_runtime.resolver.ProbeError!?target_runtime.resolver.Strength {
            return switch (descriptor.kind) {
                .synthetic => |kind| if (std.mem.eql(u8, kind, "interaction-target")) .exact else null,
                else => null,
            };
        }

        pub fn open(self: *@This(), _: semantic.target.Located) target_runtime.resolver.OpenError!semantic.view.Ref {
            return self.view;
        }
    };

    var services = Services.init(.here);
    defer services.deinit(std.testing.allocator);
    const owner = try services.acquireOwner();
    const interaction_view = try services.publishView(std.testing.allocator, owner, null, 1, .{
        .id = @enumFromInt(1),
        .actions = &.{.{ .id = "open" }},
        .content = .{ .label = "dialog" },
    });
    const target = try services.publishTarget(std.testing.allocator, owner, .{
        .kind = .{ .synthetic = "interaction-target" },
        .display_name = "target",
    });
    const opened_view = try services.publishView(std.testing.allocator, owner, target, 1, .{
        .id = @enumFromInt(2),
        .focusable = true,
        .content = .{ .label = "opened" },
    });
    var target_handler: TargetHandler = .{ .view = opened_view };
    _ = try services.registerTargetHandler(std.testing.allocator, owner, "interaction-target", .init(&target_handler));
    var action_provider: ActionProvider = .{ .located = .{ .target = target, .revision = 1 } };
    try services.registerActionProvider(std.testing.allocator, owner, .init(&action_provider));

    var interactions: view_runtime.interaction.Stack = .empty;
    defer interactions.deinit(std.testing.allocator);
    _ = try services.openInteraction(&interactions, std.testing.allocator, .{
        .role = .dialog,
        .view = interaction_view,
        .root = @enumFromInt(1),
        .actions = &.{.{ .id = "open", .disposition = .close_on_handled }},
        .bindings = &.{.{ .input = "y", .action = "open" }},
    });
    var head: Head = .empty;
    defer head.deinit(std.testing.allocator);
    const effect = (try services.invokeInteractionInput(&interactions, &head, std.testing.allocator, "y")).?;
    try std.testing.expectEqual(opened_view, effect.target_opened);
    try std.testing.expectEqual(opened_view, head.semantic_focus.path().?.view);
    try std.testing.expect(interactions.active() == null);
}

test "semantic interaction refs are head-local and close only the active scope" {
    var services = Services.init(.here);
    defer services.deinit(std.testing.allocator);
    const owner = try services.acquireOwner();
    const view_ref = try services.publishView(std.testing.allocator, owner, null, 1, .{
        .id = @enumFromInt(1),
        .content = .{ .label = "body" },
    });
    const definition: semantic.interaction.Definition = .{
        .role = .dialog,
        .view = view_ref,
        .root = @enumFromInt(1),
        .actions = &.{
            .{ .id = "yes", .label = "Yes" },
            .{ .id = "no", .label = "No" },
        },
        .bindings = &.{
            .{ .input = "y", .action = "yes" },
            .{ .input = "n", .action = "no" },
        },
        .presentation = "fixture-dialog",
    };
    var head_a: Head = .empty;
    defer head_a.deinit(std.testing.allocator);
    var head_b: Head = .empty;
    defer head_b.deinit(std.testing.allocator);
    const first = try services.openInteraction(&head_a.interactions, std.testing.allocator, definition);
    const second = try services.openInteraction(&head_a.interactions, std.testing.allocator, definition);
    const other = try services.openInteraction(&head_b.interactions, std.testing.allocator, definition);
    try std.testing.expectEqual(view_ref, head_a.interactions.active().?.descriptor.view);
    try std.testing.expectEqual(@as(semantic.scene.NodeId, @enumFromInt(1)), head_a.interactions.active().?.descriptor.root);
    try std.testing.expectEqualStrings("yes", head_a.interactions.actionForInput("y").?.id);
    try std.testing.expectEqualStrings("no", head_b.interactions.actionForInput("n").?.id);
    try std.testing.expect(!services.closeInteraction(&head_a.interactions, std.testing.allocator, first));
    try std.testing.expect(services.closeInteraction(&head_a.interactions, std.testing.allocator, second));
    try std.testing.expect(!services.closeInteraction(&head_a.interactions, std.testing.allocator, second));
    try std.testing.expect(services.closeInteraction(&head_a.interactions, std.testing.allocator, first));
    try std.testing.expect(!services.closeInteraction(&head_a.interactions, std.testing.allocator, other));
    try std.testing.expectEqual(other, head_b.interactions.active().?.descriptor.ref);
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
    const owner = try services.acquireOwner();
    const first_ref = try services.insertField(std.testing.allocator, owner, .init(&first));
    const second_ref = try services.insertField(std.testing.allocator, owner, .init(&second));
    const children = [_]semantic.scene.Node{
        .{ .id = @enumFromInt(2), .focusable = true, .content = .{ .field = .{ .ref = first_ref, .single_line = true } } },
        .{ .id = @enumFromInt(3), .focusable = true, .content = .{ .field = .{ .ref = second_ref, .single_line = true } } },
    };
    const view_ref = try services.publishView(std.testing.allocator, owner, null, 1, .{
        .id = @enumFromInt(1),
        .actions = &.{.{ .id = semantic.action.standard.copy }},
        .content = .{ .container = .{ .children = &children } },
    });
    const Actions = struct {
        calls: usize = 0,
        pub fn invoke(self: *@This(), _: semantic.action.Request) view_runtime.action.ProviderError!semantic.action.Outcome {
            self.calls += 1;
            return .handled;
        }
    };
    var actions: Actions = .{};
    try services.registerActionProvider(std.testing.allocator, owner, .init(&actions));
    var head: Head = .empty;
    defer head.deinit(std.testing.allocator);
    try head.semantic_focus.set(std.testing.allocator, .{ .view = view_ref, .nodes = &.{ @enumFromInt(1), @enumFromInt(2) }, .field = first_ref });

    try std.testing.expect(try services.inputFocusedField(&head, std.testing.allocator, .{ .replace_selection = "new" }));
    try std.testing.expectEqualStrings("new", first.bytes.items);
    try std.testing.expect(try services.moveHeadFocus(&head, std.testing.allocator, .next));
    try std.testing.expectEqual(@as(semantic.scene.NodeId, @enumFromInt(3)), head.semantic_focus.path().?.leaf().?);
    try std.testing.expect(head.semantic_focus.path().?.field.?.eql(second_ref));
    try std.testing.expect(try services.requestFocusedFieldEdit(&head, std.testing.allocator));
    try std.testing.expectEqual(@as(u64, 1), second.revision); // request is mode- and mutation-free
    try std.testing.expect((try services.invokeFocusedAction(&head.interactions, &head, std.testing.allocator, semantic.action.standard.copy)).? == .handled);
    try std.testing.expectEqual(@as(usize, 1), actions.calls);

    // A single-line field consumes a newline without changing its bytes.
    try std.testing.expect(try services.inputFocusedField(&head, std.testing.allocator, .{ .replace_selection = "\n" }));
    try std.testing.expectEqualStrings("next", second.bytes.items);
    const released = services.releaseOwner(std.testing.allocator, owner);
    try std.testing.expectEqual(@as(usize, 1), released.views);
    try std.testing.expectEqual(@as(usize, 2), released.fields);
    try std.testing.expect(released.action_provider);
    try std.testing.expect(services.fields.get(first_ref) == null);
    try std.testing.expect(!try services.moveHeadFocus(&head, std.testing.allocator, .next));
    try std.testing.expect(head.semantic_focus.path() == null);
}
