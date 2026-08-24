//! Plugin-owned dired sessions over generic filesystem and semantic services.
//!
//! This is adapter code, not editor core: it turns one typed directory target
//! into an independent draft model, retained scene, editable draft fields, and
//! semantic action endpoint. It knows no Vim modes, text buffers, local paths,
//! syscalls, renderer, or dialog presentation.

const std = @import("std");
const semantic = @import("weft_semantic");
const fs = @import("weft_fs");
const fs_runtime = @import("weft_fs_runtime");
const view_runtime = @import("weft_view_runtime");
const target_runtime = @import("weft_target_runtime");
const model = @import("weft_dired_model");
const projection = @import("weft_dired_projection");
const actions = @import("weft_dired_actions");

const contract = fs.contract;

pub const Plugin = struct {
    gpa: std.mem.Allocator,
    owner: semantic.owner.Id,
    host: Host,
    sessions: std.ArrayList(*Session) = .empty,
    handler_ref: ?target_runtime.resolver.HandlerRef = null,
    relation_ref: ?target_runtime.relation.ProviderRef = null,
    relation_provider: RelationProvider = undefined,
    started: bool = false,

    pub const Host = struct {
        filesystems: *fs_runtime.Router,
        targets: *target_runtime.target.Registry,
        target_handlers: *target_runtime.resolver.Registry,
        target_relations: *target_runtime.relation.Registry,
        views: *view_runtime.view.Registry,
        fields: *view_runtime.field.Registry,
        actions: *view_runtime.action.Registry,
    };

    pub fn init(gpa: std.mem.Allocator, owner: semantic.owner.Id, host: Host) Plugin {
        return .{ .gpa = gpa, .owner = owner, .host = host };
    }

    /// Register behavior only after this value has reached its stable address.
    /// The registries retain pointers to `self` until `deinit`.
    pub fn start(self: *Plugin) !void {
        if (self.started or !self.owner.isValid()) return error.InvalidPlugin;
        try self.host.actions.register(self.gpa, self.owner, .init(self));
        errdefer _ = self.host.actions.unregister(self.gpa, self.owner);
        self.relation_provider = .{ .plugin = self };
        self.relation_ref = self.host.target_relations.register(
            self.gpa,
            self.owner,
            "dired.container",
            .init(&self.relation_provider),
        ) catch |err| {
            return err;
        };
        errdefer if (self.relation_ref) |ref| {
            _ = self.host.target_relations.unregister(self.gpa, ref);
            self.relation_ref = null;
        };
        self.handler_ref = try self.host.target_handlers.register(
            self.gpa,
            self.owner,
            "dired.directory",
            .init(self),
        );
        self.started = true;
    }

    /// Retire every behavior endpoint before freeing the objects behind it.
    pub fn deinit(self: *Plugin) void {
        if (self.relation_ref) |ref| _ = self.host.target_relations.unregister(self.gpa, ref);
        if (self.handler_ref) |ref| _ = self.host.target_handlers.unregister(self.gpa, ref);
        if (self.started) _ = self.host.actions.unregister(self.gpa, self.owner);
        for (self.sessions.items) |session| {
            session.deinit();
            self.gpa.destroy(session);
        }
        self.sessions.deinit(self.gpa);
        self.* = undefined;
    }

    const RelationProvider = struct {
        plugin: *Plugin,

        pub fn query(self: *@This(), request: target_runtime.relation.Query) target_runtime.relation.QueryError!?target_runtime.relation.Relation {
            if (!std.mem.eql(u8, request.name, "container")) return null;
            if (request.source.location != .whole) return error.InvalidRelation;
            for (self.plugin.sessions.items) |session| {
                for (session.row_targets.items) |row_target| {
                    if (!row_target.active) continue;
                    if (!row_target.registration.ref.eql(request.source.target)) continue;
                    if (row_target.registration.revision != request.source.revision) return error.StaleTarget;
                    const descriptor = self.plugin.host.targets.get(request.source.target) orelse return error.StaleTarget;
                    if (descriptor.revision != request.source.revision or descriptor.kind != .directory)
                        return error.StaleTarget;
                    return .{
                        .name = request.name,
                        .target = .{ .target = session.target, .revision = session.target_revision },
                    };
                }
            }
            return null;
        }
    };

    /// Claim only an attachment that the trusted filesystem publisher bound
    /// to this exact target revision and the provider still observes as a
    /// directory. A decodable fact is descriptive, never authority.
    pub fn probe(self: *Plugin, descriptor: semantic.target.Descriptor) target_runtime.resolver.ProbeError!?semantic.target.Match {
        if (descriptor.kind != .directory) return null;
        const described = (fs.target.find(descriptor.facts) catch return error.InvalidTarget) orelse return null;
        const directory = self.host.filesystems.authorizedDirectory(descriptor.ref, descriptor.revision) catch |err| return switch (err) {
            error.TargetUnbound, error.StaleTarget, error.InvalidHandle, error.NotFound, error.NotDirectory => error.InvalidTarget,
            else => error.Unavailable,
        };
        if (!sameDirectory(described, directory)) return error.InvalidTarget;
        var observed = self.host.filesystems.observe(self.gpa, directory.root, directory.node) catch |err| return switch (err) {
            error.InvalidHandle, error.NotFound, error.NotDirectory => error.InvalidTarget,
            else => error.Unavailable,
        };
        defer observed.deinit();
        if (!std.meta.eql(observed.value.node, directory.node) or observed.value.kind != .directory)
            return error.InvalidTarget;
        return .exact;
    }

    /// Reuse only an exact target revision. Different dired windows may focus
    /// the same retained view, while different targets always own sessions.
    pub fn open(self: *Plugin, located: semantic.target.Located) target_runtime.resolver.OpenError!semantic.view.Ref {
        switch (located.location) {
            .whole => {},
            else => return error.Rejected,
        }
        const descriptor = self.host.targets.get(located.target) orelse return error.StaleTarget;
        if (descriptor.revision != located.revision or descriptor.kind != .directory) return error.StaleTarget;
        for (self.sessions.items) |session| {
            if (session.target.eql(located.target) and session.target_revision == located.revision)
                return session.view_ref;
        }
        const described = (fs.target.find(descriptor.facts) catch return error.Rejected) orelse return error.Rejected;
        const directory = self.host.filesystems.authorizedDirectory(located.target, located.revision) catch |err| return switch (err) {
            error.TargetUnbound, error.StaleTarget, error.InvalidHandle => error.StaleTarget,
            error.UnknownAuthority, error.AuthorityRetired => error.Unavailable,
            else => error.Rejected,
        };
        if (!sameDirectory(described, directory)) return error.Rejected;
        const session = self.gpa.create(Session) catch return error.Failed;
        errdefer self.gpa.destroy(session);
        session.* = Session.init(self, located.target, located.revision, directory);
        errdefer session.deinit();
        session.load() catch |err| return mapOpenError(err);
        self.sessions.append(self.gpa, session) catch return error.Failed;
        return session.view_ref;
    }

    /// One owner-scoped provider routes actions to the session named by the
    /// typed view reference. Input plugins need no dired-specific branch.
    pub fn invoke(self: *Plugin, request: semantic.action.Request) view_runtime.action.ProviderError!semantic.action.Outcome {
        for (self.sessions.items) |session| {
            if (!session.view_ref.eql(request.view)) continue;
            session.validateTarget() catch |err| return switch (err) {
                error.StaleTarget => error.Stale,
                else => error.Failed,
            };
            if (std.mem.eql(u8, request.action, semantic.action.standard.apply)) {
                if (session.apply_committed or !session.draft.hasPendingChanges()) return error.Rejected;
                return .{ .interaction = session.applyConfirmation() };
            }
            if (std.mem.eql(u8, request.action, semantic.action.standard.revert)) {
                session.revert() catch |err| return mapActionError(err);
                return .handled;
            }
            if (std.mem.eql(u8, request.action, semantic.action.standard.refresh)) {
                session.refresh() catch |err| return mapActionError(err);
                return .handled;
            }
            if (std.mem.eql(u8, request.action, semantic.action.standard.confirm)) {
                return if (session.applyConfirmed() catch |err| return mapActionError(err)) .handled else .declined;
            }
            if (std.mem.eql(u8, request.action, semantic.action.standard.cancel)) return .handled;
            var staged = session.draft.duplicate() catch return error.Failed;
            defer staged.deinit();
            var staged_controller = actions.Controller.init(self.gpa, &staged, session.view_ref);
            defer staged_controller.deinit();
            const outcome = staged_controller.invoke(request) catch |err| return mapActionError(err);
            switch (outcome) {
                .handled => {
                    session.publishDraft(&staged) catch return error.Failed;
                },
                .transfer => {
                    var captured = staged_controller.takeCapture() orelse return error.Failed;
                    errdefer captured.deinit();
                    self.materializeCapture(&captured) catch |err| return mapActionError(err);
                    session.controller.clearCapture();
                    session.controller.capture = captured;
                    return .{ .transfer = session.controller.captured().? };
                },
                .declined, .interaction, .open_target, .open_relation, .focus => {},
            }
            return outcome;
        }
        return error.Stale;
    }

    /// Replace a guarded entry address with a provider-owned snapshot when
    /// that provider advertises durable leases. The transfer remains an
    /// ordinary immutable plugin value; the opaque resource only keeps the
    /// provider lease live while a clipboard or pasted draft retains it.
    fn materializeCapture(self: *Plugin, captured: *semantic.transfer.OwnedItem) !void {
        if (captured.value.intent != .copy) return;
        const representation = captured.value.representation(model.entry_media_type) orelse return;
        const schema = representation.schema orelse return error.InvalidTransfer;
        const decoded = try model.decodeEntryTransfer(representation.payload, schema, representation.resource);
        const entry = switch (decoded.source) {
            .entry => |value| value,
            .lease => return,
        };
        switch (decoded.kind) {
            .regular, .symlink => {},
            .directory, .other => return,
        }
        const capabilities = try self.host.filesystems.capabilities(entry.root);
        if (capabilities.durable_lease == null) return;

        const lease = try self.host.filesystems.capture(entry);
        var release_lease = true;
        errdefer if (release_lease) {
            _ = self.host.filesystems.release(lease) catch {};
        };
        const resource = try fs_runtime.LeaseResource.create(self.gpa, self.host.filesystems, lease);
        release_lease = false;
        var release_resource = true;
        defer if (release_resource) resource.release();

        const payload = try model.encodeEntryTransfer(self.gpa, .{ .lease = lease }, decoded.kind, decoded.mode);
        defer self.gpa.free(payload);
        const representations = try self.gpa.alloc(semantic.transfer.Representation, captured.value.representations.len);
        defer self.gpa.free(representations);
        var replaced = false;
        for (captured.value.representations, representations) |source, *destination| {
            destination.* = source;
            if (!std.mem.eql(u8, source.media_type, model.entry_media_type)) continue;
            destination.schema = model.entry_schema_current;
            destination.payload = payload;
            destination.resource = resource;
            replaced = true;
        }
        if (!replaced) return error.InvalidTransfer;
        const materialized = try semantic.transfer.OwnedItem.init(self.gpa, .{
            .intent = captured.value.intent,
            .suggested_name = captured.value.suggested_name,
            .source = captured.value.source,
            .representations = representations,
        });
        resource.release();
        release_resource = false;
        captured.deinit();
        captured.* = materialized;
    }

    fn mapOpenError(err: anyerror) target_runtime.resolver.OpenError {
        return switch (err) {
            error.Stale, error.StaleTarget, error.AuthorityRetired => error.StaleTarget,
            error.UnknownAuthority, error.Unavailable, error.Unsupported => error.Unavailable,
            else => error.Failed,
        };
    }

    fn mapActionError(err: anyerror) view_runtime.action.ProviderError {
        return switch (err) {
            error.Stale, error.StaleSubject, error.StaleTarget, error.InvalidView => error.Stale,
            error.UnknownSubject,
            error.AmbiguousSubject,
            error.InvalidSelection,
            error.MissingTransfer,
            error.InvalidTransfer,
            => error.Rejected,
            else => error.Failed,
        };
    }
};

pub const Session = struct {
    const RowTarget = struct {
        row: model.NodeId,
        directory: fs.target.Directory,
        registration: fs_runtime.publication.Registration,
        active: bool = true,
        fresh: bool = false,
    };

    plugin: *Plugin,
    target: semantic.target.Ref,
    target_revision: u64,
    directory: fs.target.Directory,
    draft: model.Model,
    fields: std.ArrayList(*DraftField) = .empty,
    view_ref: semantic.view.Ref = undefined,
    controller: actions.Controller = undefined,
    loaded: bool = false,
    /// All effects completed but rebuilding the view failed. While set, a
    /// second confirmation may refresh state but must never replay the plan.
    apply_committed: bool = false,
    scene_revision: u64 = 1,
    posix_mode: bool = false,
    row_targets: std.ArrayList(RowTarget) = .empty,

    fn init(plugin: *Plugin, target: semantic.target.Ref, target_revision: u64, directory: fs.target.Directory) Session {
        return .{
            .plugin = plugin,
            .target = target,
            .target_revision = target_revision,
            .directory = directory,
            .draft = .initAt(plugin.gpa, directory.root, directory.node),
        };
    }

    fn load(self: *Session) !void {
        self.posix_mode = (try self.plugin.host.filesystems.capabilities(self.directory.root)).posix_mode;
        var initial = try self.refreshedDraft(true);
        defer initial.deinit();
        const previous = self.draft;
        self.draft = initial;
        initial = previous;
        try self.prepareRowTargets(&self.draft);
        errdefer self.closeAllRowTargets();
        try self.prepareFieldsFor(&self.draft);
        var scene = try self.projectSceneFor(&self.draft);
        defer scene.deinit();
        self.view_ref = try self.plugin.host.views.publish(
            self.plugin.gpa,
            self.plugin.owner,
            .{ .ref = self.target, .revision = self.target_revision },
            self.scene_revision,
            scene.value,
        );
        self.controller = .init(self.plugin.gpa, &self.draft, self.view_ref);
        self.loaded = true;
        self.pruneFields();
        self.retireRowTargets();
    }

    pub fn deinit(self: *Session) void {
        if (self.loaded) {
            self.controller.deinit();
            _ = self.plugin.host.views.close(self.plugin.gpa, self.plugin.owner, self.view_ref);
        }
        self.closeAllRowTargets();
        for (self.fields.items) |field| {
            _ = self.plugin.host.fields.remove(self.plugin.gpa, self.plugin.owner, field.ref);
            self.plugin.gpa.destroy(field);
        }
        self.fields.deinit(self.plugin.gpa);
        self.draft.deinit();
        self.* = undefined;
    }

    /// Reconcile an external listing by opaque identity. Dirty rows survive
    /// disappearance and become conflicts; no watcher mutates the draft.
    pub fn refresh(self: *Session) !void {
        try self.validateTarget();
        var staged = try self.refreshedDraft(self.apply_committed);
        defer staged.deinit();
        try self.publishDraft(&staged);
        self.apply_committed = false;
    }

    /// Explicit revert discards the draft and rebuilds from current authority
    /// state. This is the generic operation `:e!` can invoke for a tool view.
    pub fn revert(self: *Session) !void {
        try self.validateTarget();
        var staged = try self.refreshedDraft(true);
        defer staged.deinit();
        try self.publishDraft(&staged);
        self.controller.clearCapture();
        self.apply_committed = false;
    }

    pub fn buildPlan(self: *const Session) !model.OwnedPlan {
        return self.draft.buildPlan();
    }

    pub fn apply(self: *Session, gpa: std.mem.Allocator) !contract.OwnedApplyReport {
        try self.validateTarget();
        if (self.apply_committed) return error.AlreadyApplied;
        var effect_plan = try self.buildPlan();
        defer effect_plan.deinit();
        return self.plugin.host.filesystems.apply(gpa, effect_plan.value);
    }

    fn applyConfirmation(self: *const Session) semantic.interaction.Definition {
        return .{
            .role = .dialog,
            .view = self.view_ref,
            .root = projection.rootNodeId(),
            .actions = &.{
                .{ .id = semantic.action.standard.confirm, .label = "Apply", .disposition = .close_on_handled },
                .{ .id = semantic.action.standard.cancel, .label = "Cancel", .disposition = .close_on_handled },
            },
            .bindings = &.{
                .{ .input = "y", .action = semantic.action.standard.confirm },
                .{ .input = "n", .action = semantic.action.standard.cancel },
                .{ .input = "enter", .action = semantic.action.standard.confirm },
                .{ .input = "escape", .action = semantic.action.standard.cancel },
            },
            .default_action = semantic.action.standard.confirm,
            .cancel_action = semantic.action.standard.cancel,
            .presentation = "which-key-like",
        };
    }

    /// Execute the immutable plan represented by the visible diff. A partial
    /// report leaves the interaction open; a complete report closes it. Once
    /// every effect completes, a failed refresh cannot make confirmation run
    /// the plan twice.
    fn applyConfirmed(self: *Session) !bool {
        var report = try self.apply(self.plugin.gpa);
        defer report.deinit();
        var complete = true;
        for (report.value.entries) |entry| switch (entry.outcome) {
            .applied, .already_satisfied => {},
            .conflict, .stale, .unsupported, .ambiguous, .recoverable_at => complete = false,
        };
        if (!complete) {
            self.refresh() catch {};
            return false;
        }
        self.apply_committed = true;
        self.revert() catch {};
        return true;
    }

    fn refreshedDraft(self: *Session, discard_draft: bool) !model.Model {
        var listing = try self.plugin.host.filesystems.list(
            self.plugin.gpa,
            self.directory.root,
            self.directory.node,
        );
        defer listing.deinit();
        try validateListing(self.directory, listing.value);
        const arena = listing.allocator();
        const entries = try arena.alloc(model.SnapshotEntry, listing.value.entries.len);
        for (listing.value.entries, entries) |entry, *snapshot| {
            const identity = switch (entry.observation.node) {
                .entry => |ref| ref,
                .root => return error.InvalidListing,
            };
            snapshot.* = .{
                .identity = identity,
                .name = entry.name.bytes,
                .revision = entry.observation.revision.token,
                .kind = entry.observation.kind,
                .mode = entry.observation.metadata.mode,
                .link_target = entry.observation.metadata.link_target orelse &.{},
            };
        }
        var staged = if (discard_draft)
            model.Model.initAt(self.plugin.gpa, self.directory.root, self.directory.node)
        else
            try self.draft.duplicate();
        errdefer staged.deinit();
        try staged.reconcile(.{ .entries = entries, .revision = listing.value.revision.token });
        return staged;
    }

    fn validateTarget(self: *const Session) !void {
        const descriptor = self.plugin.host.targets.get(self.target) orelse return error.StaleTarget;
        if (descriptor.revision != self.target_revision or descriptor.kind != .directory) return error.StaleTarget;
        const described = (try fs.target.find(descriptor.facts)) orelse return error.StaleTarget;
        const authorized = try self.plugin.host.filesystems.authorizedDirectory(self.target, self.target_revision);
        if (!sameDirectory(described, authorized) or !sameDirectory(authorized, self.directory)) return error.StaleTarget;
    }

    /// Publish a staged model's scene first, then commit it with an infallible
    /// value swap. Failed allocation or view replacement leaves both the live
    /// draft and retained scene unchanged.
    fn publishDraft(self: *Session, staged: *model.Model) !void {
        const old_fields_len = self.fields.items.len;
        var committed = false;
        defer if (!committed) self.rollbackFieldsFrom(old_fields_len);
        try self.prepareRowTargets(staged);
        errdefer self.abortRowTargets();
        try self.prepareFieldsFor(staged);
        var scene = try self.projectSceneFor(staged);
        defer scene.deinit();
        const next_revision = std.math.add(u64, self.scene_revision, 1) catch return error.RevisionOverflow;
        try self.plugin.host.views.replace(
            self.plugin.gpa,
            self.plugin.owner,
            self.view_ref,
            next_revision,
            scene.value,
        );
        const previous = self.draft;
        self.draft = staged.*;
        staged.* = previous;
        self.scene_revision = next_revision;
        self.controller.model = &self.draft;
        self.bumpFieldRevisions();
        self.pruneFields();
        self.retireRowTargets();
        committed = true;
    }

    /// Retain one trusted filesystem publication per observed directory row.
    /// The row id is model identity, so reorder does not churn the target.
    fn prepareRowTargets(self: *Session, draft: *const model.Model) !void {
        for (self.row_targets.items) |*row_target| row_target.active = false;
        const old_len = self.row_targets.items.len;
        errdefer {
            while (self.row_targets.items.len > old_len) {
                var row_target = self.row_targets.pop().?;
                _ = row_target.registration.close(self.plugin.gpa, self.plugin.host.targets, self.plugin.host.filesystems);
            }
            for (self.row_targets.items) |*row_target| row_target.active = true;
        }
        for (draft.rows.items) |row| {
            const directory = observedDirectory(self.directory, row) orelse continue;
            var retained = false;
            for (self.row_targets.items) |*row_target| {
                if (row_target.row != row.id or !sameDirectory(row_target.directory, directory)) continue;
                row_target.active = true;
                row_target.fresh = false;
                retained = true;
                break;
            }
            if (retained) continue;
            var registration = try fs_runtime.publication.publish(self.plugin.gpa, self.plugin.host.targets, self.plugin.host.filesystems, self.plugin.owner, .{
                .display_name = row.draft.name,
                .directory = directory,
            });
            var retained_registration = false;
            defer {
                if (!retained_registration)
                    _ = registration.close(self.plugin.gpa, self.plugin.host.targets, self.plugin.host.filesystems);
            }
            try self.row_targets.append(self.plugin.gpa, .{
                .row = row.id,
                .directory = directory,
                .registration = registration,
                .fresh = true,
            });
            retained_registration = true;
        }
    }

    fn abortRowTargets(self: *Session) void {
        var index: usize = self.row_targets.items.len;
        while (index > 0) {
            index -= 1;
            if (!self.row_targets.items[index].fresh) continue;
            var row_target = self.row_targets.swapRemove(index);
            _ = row_target.registration.close(self.plugin.gpa, self.plugin.host.targets, self.plugin.host.filesystems);
        }
        for (self.row_targets.items) |*row_target| {
            row_target.active = true;
            row_target.fresh = false;
        }
    }

    fn retireRowTargets(self: *Session) void {
        var index: usize = self.row_targets.items.len;
        while (index > 0) {
            index -= 1;
            if (self.row_targets.items[index].active) continue;
            var row_target = self.row_targets.swapRemove(index);
            _ = row_target.registration.close(self.plugin.gpa, self.plugin.host.targets, self.plugin.host.filesystems);
        }
        for (self.row_targets.items) |*row_target| row_target.fresh = false;
    }

    fn closeAllRowTargets(self: *Session) void {
        for (self.row_targets.items) |*row_target|
            _ = row_target.registration.close(self.plugin.gpa, self.plugin.host.targets, self.plugin.host.filesystems);
        self.row_targets.deinit(self.plugin.gpa);
    }

    /// Additions are staged before scene replacement; obsolete field refs are
    /// retained until the new scene is live. An allocation failure therefore
    /// cannot publish a scene containing a missing field.
    fn prepareFieldsFor(self: *Session, draft: *const model.Model) !void {
        for (draft.rows.items) |row| {
            try self.ensureField(row.id, .name);
            if (self.modeEditable(row)) try self.ensureField(row.id, .mode);
        }
    }

    fn ensureField(self: *Session, row: model.NodeId, kind: DraftField.Kind) !void {
        if (self.draftFieldFor(row, kind) != null) return;
        const field = try self.plugin.gpa.create(DraftField);
        errdefer self.plugin.gpa.destroy(field);
        field.* = .{ .session = self, .row = row, .kind = kind };
        field.ref = try self.plugin.host.fields.insert(
            self.plugin.gpa,
            self.plugin.owner,
            .init(field),
        );
        errdefer _ = self.plugin.host.fields.remove(self.plugin.gpa, self.plugin.owner, field.ref);
        try self.fields.append(self.plugin.gpa, field);
    }

    fn rollbackFieldsFrom(self: *Session, first: usize) void {
        while (self.fields.items.len > first) {
            const field = self.fields.pop().?;
            _ = self.plugin.host.fields.remove(self.plugin.gpa, self.plugin.owner, field.ref);
            self.plugin.gpa.destroy(field);
        }
    }

    fn pruneFields(self: *Session) void {
        var index: usize = self.fields.items.len;
        while (index > 0) {
            index -= 1;
            const field = self.fields.items[index];
            if (self.draft.row(field.row)) |row| {
                if (field.kind == .name or self.modeEditable(row.*)) continue;
            }
            _ = self.plugin.host.fields.remove(self.plugin.gpa, self.plugin.owner, field.ref);
            _ = self.fields.swapRemove(index);
            self.plugin.gpa.destroy(field);
        }
    }

    fn projectSceneFor(self: *Session, draft: *const model.Model) !projection.OwnedScene {
        const bindings = try self.plugin.gpa.alloc(projection.FieldBinding, draft.rows.items.len);
        defer self.plugin.gpa.free(bindings);
        for (draft.rows.items, bindings) |row, *binding| binding.* = .{
            .row = row.id,
            .field = self.fieldFor(row.id).?.ref,
            .mode_field = if (self.modeFieldFor(row.id)) |field| field.ref else null,
            .target = self.rowTargetFor(row.id),
        };
        return projection.project(self.plugin.gpa, draft.rows.items, bindings);
    }

    fn draftFieldFor(self: *const Session, row: model.NodeId, kind: DraftField.Kind) ?*DraftField {
        for (self.fields.items) |field| if (field.row == row and field.kind == kind) return field;
        return null;
    }

    fn fieldFor(self: *const Session, row: model.NodeId) ?*DraftField {
        return self.draftFieldFor(row, .name);
    }

    fn modeFieldFor(self: *const Session, row: model.NodeId) ?*DraftField {
        return self.draftFieldFor(row, .mode);
    }

    fn modeEditable(self: *const Session, row: model.Row) bool {
        if (!self.posix_mode) return false;
        return switch (row.draft.kind) {
            .regular, .directory => true,
            .symlink, .other => false,
        };
    }

    fn bumpFieldRevisions(self: *Session) void {
        for (self.fields.items) |field| field.revision +|= 1;
    }

    fn rowTargetFor(self: *const Session, row: model.NodeId) ?semantic.scene.TargetLink {
        for (self.row_targets.items) |row_target| if (row_target.active and row_target.row == row)
            return row_target.registration.located();
        return null;
    }
};

fn observedDirectory(parent: fs.target.Directory, row: model.Row) ?fs.target.Directory {
    if (row.conflict == .stale or row.pending == .deleted or row.draft.kind != .directory) return null;
    const observation = row.current orelse return null;
    if (observation.kind != .directory or observation.identity.authority != parent.root.authority) return null;
    return .{ .root = parent.root, .node = .{ .entry = observation.identity } };
}

fn validateListing(directory: fs.target.Directory, listing: contract.Listing) !void {
    if (!std.meta.eql(listing.directory.node, directory.node) or listing.directory.kind != .directory)
        return error.InvalidListing;
    for (listing.entries) |entry| {
        _ = contract.Name.init(entry.name.bytes) catch return error.InvalidListing;
        const identity = switch (entry.observation.node) {
            .root => return error.InvalidListing,
            .entry => |ref| ref,
        };
        if (identity.generation == 0 or identity.authority != directory.root.authority)
            return error.InvalidListing;
    }
}

fn sameDirectory(a: fs.target.Directory, b: fs.target.Directory) bool {
    return a.root.eql(b.root) and std.meta.eql(a.node, b.node);
}

const DraftField = struct {
    session: *Session,
    row: model.NodeId,
    kind: Kind,
    ref: semantic.scene.FieldRef = undefined,
    revision: u64 = 1,
    selection: view_runtime.field.Selection = .{ .anchor = 0, .caret = 0 },

    const Kind = enum { name, mode };

    pub fn snapshot(self: *DraftField, gpa: std.mem.Allocator) view_runtime.field.Error!view_runtime.field.OwnedSnapshot {
        const row = self.session.draft.row(self.row) orelse return error.Stale;
        var owned = view_runtime.field.OwnedSnapshot.init(gpa);
        errdefer owned.deinit();
        const arena = owned.allocator();
        const revision = try arena.alloc(u8, @sizeOf(u64));
        std.mem.writeInt(u64, revision[0..8], self.revision, .little);
        const bytes = switch (self.kind) {
            .name => try arena.dupe(u8, row.draft.name),
            .mode => if (row.draft.mode) |mode|
                try std.fmt.allocPrint(arena, "{o:0>4}", .{mode})
            else
                try arena.alloc(u8, 0),
        };
        const end: u64 = @intCast(bytes.len);
        if (self.selection.anchor > end or self.selection.caret > end)
            self.selection = .{ .anchor = end, .caret = end };
        owned.value = .{
            .revision = revision,
            .bytes = bytes,
            .selection = self.selection,
            .read_only = row.pending == .deleted or row.conflict == .stale or
                (self.kind == .mode and !self.session.modeEditable(row.*)),
            .single_line = true,
        };
        return owned;
    }

    pub fn edit(self: *DraftField, expected_revision: []const u8, edit_value: view_runtime.field.Edit) view_runtime.field.Error!void {
        self.session.validateTarget() catch return error.Stale;
        if (expected_revision.len != @sizeOf(u64) or
            std.mem.readInt(u64, expected_revision[0..8], .little) != self.revision)
            return error.Stale;
        const row = self.session.draft.row(self.row) orelse return error.Stale;
        if (row.pending == .deleted or row.conflict == .stale) return error.ReadOnly;
        if (self.kind == .mode and !self.session.modeEditable(row.*)) return error.ReadOnly;
        var owned_current: ?[]u8 = null;
        defer if (owned_current) |bytes| self.session.plugin.gpa.free(bytes);
        const current = switch (self.kind) {
            .name => row.draft.name,
            .mode => blk: {
                const bytes = if (row.draft.mode) |mode|
                    std.fmt.allocPrint(self.session.plugin.gpa, "{o:0>4}", .{mode}) catch return error.OutOfMemory
                else
                    self.session.plugin.gpa.alloc(u8, 0) catch return error.OutOfMemory;
                owned_current = bytes;
                break :blk bytes;
            },
        };
        if (edit_value.start > edit_value.end or edit_value.end > current.len) return error.InvalidRange;
        const start: usize = @intCast(edit_value.start);
        const end: usize = @intCast(edit_value.end);
        const next_len = std.math.add(usize, current.len - (end - start), edit_value.replacement.len) catch return error.Failed;
        const next = self.session.plugin.gpa.alloc(u8, next_len) catch return error.OutOfMemory;
        defer self.session.plugin.gpa.free(next);
        @memcpy(next[0..start], current[0..start]);
        @memcpy(next[start..][0..edit_value.replacement.len], edit_value.replacement);
        @memcpy(next[start + edit_value.replacement.len ..], current[end..]);
        var staged = self.session.draft.duplicate() catch return error.OutOfMemory;
        defer staged.deinit();
        switch (self.kind) {
            .name => staged.rename(self.row, next) catch |err| return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                else => error.Unsupported,
            },
            .mode => staged.setMode(self.row, parseMode(next) catch return error.Unsupported) catch return error.Unsupported,
        }
        const caret: u64 = @intCast(start + edit_value.replacement.len);
        self.session.publishDraft(&staged) catch return error.Failed;
        self.selection = edit_value.selection_after orelse .{ .anchor = caret, .caret = caret };
    }
};

fn parseMode(bytes: []const u8) !u32 {
    const digits = if (std.mem.startsWith(u8, bytes, "0o")) bytes[2..] else bytes;
    if (digits.len == 0 or digits.len > 4) return error.InvalidMode;
    for (digits) |byte| if (byte < '0' or byte > '7') return error.InvalidMode;
    const value = std.fmt.parseInt(u32, digits, 8) catch return error.InvalidMode;
    if (value > 0o7777) return error.InvalidMode;
    return value;
}

test "plugin opens typed directory targets as independent semantic sessions" {
    var fake: FakeFilesystem = .{};
    defer fake.deinit();
    try fake.set(&.{
        .{ .name = "alpha", .ref = entryRef(1), .revision = "1", .kind = .regular, .mode = 0o644 },
        .{ .name = "odd\n\xff", .ref = entryRef(2), .revision = "2", .kind = .symlink, .link_target = "target" },
    });
    var router = fs_runtime.Router.init(std.testing.allocator);
    defer router.deinit();
    try router.register(.here, fs.service.Provider.init(&fake));
    var targets = target_runtime.target.Registry.init(.here);
    defer targets.deinit(std.testing.allocator);
    var handlers = target_runtime.resolver.Registry.init(.here);
    defer handlers.deinit(std.testing.allocator);
    var relations = target_runtime.relation.Registry.init(.here);
    defer relations.deinit(std.testing.allocator);
    var views = view_runtime.view.Registry.init(.here);
    defer views.deinit(std.testing.allocator);
    var fields = view_runtime.field.Registry.init(.here);
    defer fields.deinit(std.testing.allocator);
    var action_registry: view_runtime.action.Registry = .{};
    defer action_registry.deinit(std.testing.allocator);

    var publication = try fs_runtime.publication.publish(std.testing.allocator, &targets, &router, @enumFromInt(1), .{
        .display_name = "fixture",
        .directory = .{ .root = rootRef() },
    });
    defer _ = publication.close(std.testing.allocator, &targets, &router);
    const target = publication.ref;
    var plugin = Plugin.init(std.testing.allocator, @enumFromInt(2), .{
        .filesystems = &router,
        .targets = &targets,
        .target_handlers = &handlers,
        .target_relations = &relations,
        .views = &views,
        .fields = &fields,
        .actions = &action_registry,
    });
    try plugin.start();
    defer plugin.deinit();

    const forged_fact = try fs.target.encode(std.testing.allocator, .{ .root = rootRef() });
    defer std.testing.allocator.free(forged_fact);
    const forged = try targets.publish(std.testing.allocator, @enumFromInt(3), .{
        .kind = .directory,
        .display_name = "descriptive only",
        .facts = &.{.{ .name = fs.target.fact_name, .value = forged_fact }},
    });
    var forged_resolution = try handlers.resolve(std.testing.allocator, targets.get(forged).?.*);
    defer forged_resolution.deinit();
    try std.testing.expectEqual(@as(usize, 0), forged_resolution.value.candidates.len);
    try std.testing.expectEqual(@as(usize, 1), forged_resolution.value.failures.len);
    try std.testing.expectEqual(target_runtime.resolver.ProbeError.InvalidTarget, forged_resolution.value.failures[0].reason);

    var resolution = try handlers.resolve(std.testing.allocator, targets.get(target).?.*);
    defer resolution.deinit();
    try std.testing.expectEqual(@as(usize, 1), resolution.value.candidates.len);
    const selected = resolution.value.decide().selected;
    const view_ref = try handlers.open(selected, .{ .target = target, .revision = 1 });
    try std.testing.expectEqual(view_ref, try handlers.open(selected, .{ .target = target, .revision = 1 }));
    try std.testing.expectEqual(@as(usize, 1), plugin.sessions.items.len);
    const session = plugin.sessions.items[0];
    try std.testing.expectEqual(@as(usize, 2), session.draft.rows.items.len);
    try std.testing.expectEqualStrings("odd\n\xff", session.draft.rows.items[1].draft.name);
    try std.testing.expectEqualStrings("dired", views.get(view_ref).?.scene.role);

    const first_field = session.fieldFor(session.draft.rows.items[0].id).?;
    try std.testing.expect(session.modeFieldFor(session.draft.rows.items[0].id) != null);
    try std.testing.expect(session.modeFieldFor(session.draft.rows.items[1].id) == null);
    var snapshot = try fields.get(first_field.ref).?.snapshot(std.testing.allocator);
    defer snapshot.deinit();
    try std.testing.expectEqualStrings("alpha", snapshot.value.bytes);
    try fields.get(first_field.ref).?.edit(snapshot.value.revision, .{ .start = 0, .end = 5, .replacement = "renamed" });
    try std.testing.expectEqualStrings("renamed", session.draft.rows.items[0].draft.name);
    const scene_row = views.get(view_ref).?.scene.content.container.children[0];
    try std.testing.expectEqualStrings("rename", scene_row.facts[0].value);
}

test "provider capabilities expose permissions as an ordinary secondary action and field" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const session = fixture.plugin.sessions.items[0];
    const row = session.draft.rows.items[0].id;
    const subject = try projection.rowNodeId(row);
    const mode_field = session.modeFieldFor(row).?;

    const scene_row = fixture.views.get(session.view_ref).?.scene.content.container.children[0];
    try std.testing.expectEqualStrings(projection.permissions_edit_action, scene_row.actions[7].id);
    try std.testing.expectEqual(mode_field.ref, scene_row.content.container.children[1].content.field.ref);
    try std.testing.expect(!scene_row.content.container.children[1].focusable);

    const focus = try fixture.actions.invoke(&fixture.views, .{
        .action = projection.permissions_edit_action,
        .view = session.view_ref,
        .subject = subject,
    });
    try std.testing.expectEqual(try projection.modeNodeId(row), focus.focus);

    var before = try fixture.fields.get(mode_field.ref).?.snapshot(std.testing.allocator);
    defer before.deinit();
    try std.testing.expectEqualStrings("0644", before.value.bytes);
    try fixture.fields.get(mode_field.ref).?.edit(before.value.revision, .{
        .start = 0,
        .end = before.value.bytes.len,
        .replacement = "0600",
    });
    try std.testing.expectEqual(@as(?u32, 0o600), session.draft.row(row).?.draft.mode);

    var effect_plan = try session.buildPlan();
    defer effect_plan.deinit();
    try std.testing.expectEqual(@as(usize, 1), effect_plan.value.operations.len);
    try std.testing.expectEqual(std.meta.activeTag(effect_plan.value.operations[0].operation), .set_permissions);
    try std.testing.expectEqual(@as(u32, 0o600), effect_plan.value.operations[0].operation.set_permissions.mode);

    var current = try fixture.fields.get(mode_field.ref).?.snapshot(std.testing.allocator);
    defer current.deinit();
    try std.testing.expectError(error.Unsupported, fixture.fields.get(mode_field.ref).?.edit(current.value.revision, .{
        .start = 0,
        .end = current.value.bytes.len,
        .replacement = "0788",
    }));
    try std.testing.expectEqual(@as(?u32, 0o600), session.draft.row(row).?.draft.mode);
}

test "actions retain deleted rows as portable paste anchors and revert discards the draft" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const session = fixture.plugin.sessions.items[0];
    const row = session.draft.rows.items[0].id;
    const subject = try projection.rowNodeId(row);
    const copied = try fixture.actions.invoke(&fixture.views, .{
        .action = semantic.action.standard.copy,
        .view = session.view_ref,
        .subject = subject,
    });
    _ = try fixture.actions.invoke(&fixture.views, .{
        .action = semantic.action.standard.delete,
        .view = session.view_ref,
        .subject = subject,
    });
    _ = try fixture.actions.invoke(&fixture.views, .{
        .action = semantic.action.standard.paste_after,
        .view = session.view_ref,
        .subject = subject,
        .transfer = copied.transfer,
    });
    try std.testing.expectEqual(@as(usize, 2), session.draft.rows.items.len);
    try std.testing.expectEqual(model.Pending.deleted, session.draft.rows.items[0].pending);
    try std.testing.expectEqual(model.Pending.copied, session.draft.rows.items[1].pending);
    try session.revert();
    try std.testing.expectEqual(@as(usize, 1), session.draft.rows.items.len);
    try std.testing.expectEqual(model.Pending.observed, session.draft.rows.items[0].pending);
}

test "durable copy survives clipboard replacement and restores a deleted source name" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    fixture.fake.durable_leases = true;
    const session = fixture.plugin.sessions.items[0];
    const row = session.draft.rows.items[0].id;
    const subject = try projection.rowNodeId(row);

    const copied = try fixture.actions.invoke(&fixture.views, .{
        .action = semantic.action.standard.copy,
        .view = session.view_ref,
        .subject = subject,
    });
    try std.testing.expectEqual(@as(usize, 1), fixture.fake.capture_calls);
    const representation = copied.transfer.representation(model.entry_media_type).?;
    const decoded = try model.decodeEntryTransfer(representation.payload, representation.schema.?, representation.resource);
    try std.testing.expect(decoded.source == .lease);
    try std.testing.expect(representation.resource != null);

    var clipboard = try semantic.transfer.OwnedItem.init(std.testing.allocator, copied.transfer);
    var clipboard_live = true;
    defer if (clipboard_live) clipboard.deinit();
    _ = try fixture.actions.invoke(&fixture.views, .{
        .action = semantic.action.standard.delete,
        .view = session.view_ref,
        .subject = subject,
    });
    _ = try fixture.actions.invoke(&fixture.views, .{
        .action = semantic.action.standard.paste_after,
        .view = session.view_ref,
        .subject = subject,
        .transfer = clipboard.value,
    });

    // Replacing the plugin capture and the external clipboard cannot retire
    // the provider lease while a pasted draft row still names it.
    session.controller.clearCapture();
    clipboard.deinit();
    clipboard_live = false;
    try std.testing.expectEqual(@as(usize, 0), fixture.fake.release_calls);

    var effect_plan = try session.buildPlan();
    defer effect_plan.deinit();
    try std.testing.expectEqual(@as(usize, 2), effect_plan.value.operations.len);
    try std.testing.expectEqual(std.meta.activeTag(effect_plan.value.operations[0].operation), .remove);
    try std.testing.expectEqual(std.meta.activeTag(effect_plan.value.operations[1].operation), .copy);
    try std.testing.expectEqual(@as(u32, 1), effect_plan.value.operations[1].operation.copy.source.lease.ref.slot);
    try std.testing.expectEqualStrings("kept", effect_plan.value.operations[1].operation.copy.destination.name.bytes);

    try session.revert();
    try std.testing.expectEqual(@as(usize, 1), fixture.fake.release_calls);
}

test "entry-backed directory sessions preserve their destination and namespace revision" {
    var fixture: Fixture = undefined;
    const directory: fs.target.Directory = .{ .root = rootRef(), .node = .{ .entry = entryRef(99) } };
    try fixture.initAt(directory);
    defer fixture.deinit();
    const session = fixture.plugin.sessions.items[0];
    const row = session.draft.rows.items[0].id;
    try session.draft.rename(row, "nested-name");
    var effect_plan = try session.buildPlan();
    defer effect_plan.deinit();
    try std.testing.expectEqualStrings("listing", effect_plan.value.base_revision);
    try std.testing.expectEqual(@as(usize, 1), effect_plan.value.operations.len);
    const rename = effect_plan.value.operations[0].operation.rename;
    try std.testing.expectEqual(entryRef(99), rename.destination.parent.entry);
}

test "failed scene replacement leaves action and field drafts unchanged" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const session = fixture.plugin.sessions.items[0];
    const row = session.draft.rows.items[0].id;
    const field = session.fieldFor(row).?;
    var before = try fixture.fields.get(field.ref).?.snapshot(std.testing.allocator);
    defer before.deinit();

    try std.testing.expect(fixture.views.close(std.testing.allocator, fixture.plugin.owner, session.view_ref));
    try std.testing.expectError(error.Failed, fixture.plugin.invoke(.{
        .action = semantic.action.standard.delete,
        .view = session.view_ref,
        .subject = try projection.rowNodeId(row),
    }));
    try std.testing.expectEqual(model.Pending.observed, session.draft.row(row).?.pending);

    try std.testing.expectError(error.Failed, fixture.fields.get(field.ref).?.edit(before.value.revision, .{
        .start = 0,
        .end = before.value.bytes.len,
        .replacement = "not-committed",
    }));
    try std.testing.expectEqualStrings("kept", session.draft.row(row).?.draft.name);
    var after = try fixture.fields.get(field.ref).?.snapshot(std.testing.allocator);
    defer after.deinit();
    try std.testing.expectEqualSlices(u8, before.value.revision, after.value.revision);
}

test "target replacement makes the session stale and cannot inherit old authority" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const old_session = fixture.plugin.sessions.items[0];
    const binding = try fs.target.encode(std.testing.allocator, .{ .root = rootRef() });
    defer std.testing.allocator.free(binding);
    try fixture.targets.replace(std.testing.allocator, @enumFromInt(1), fixture.target, .{
        .kind = .directory,
        .display_name = "replacement",
        .facts = &.{.{ .name = fs.target.fact_name, .value = binding }},
    });
    try std.testing.expectError(error.StaleTarget, old_session.refresh());
    const old_row = old_session.draft.rows.items[0].id;
    try std.testing.expectError(error.Stale, fixture.plugin.invoke(.{
        .action = semantic.action.standard.delete,
        .view = old_session.view_ref,
        .subject = try projection.rowNodeId(old_row),
    }));
    const old_field = old_session.fieldFor(old_row).?;
    var old_snapshot = try fixture.fields.get(old_field.ref).?.snapshot(std.testing.allocator);
    defer old_snapshot.deinit();
    try std.testing.expectError(error.Stale, fixture.fields.get(old_field.ref).?.edit(old_snapshot.value.revision, .{
        .start = 0,
        .end = old_snapshot.value.bytes.len,
        .replacement = "stale-edit",
    }));

    var resolution = try fixture.handlers.resolve(std.testing.allocator, fixture.targets.get(fixture.target).?.*);
    defer resolution.deinit();
    try std.testing.expectEqual(@as(usize, 0), resolution.value.candidates.len);
    try std.testing.expectEqual(@as(usize, 1), resolution.value.failures.len);
    try std.testing.expectEqual(target_runtime.resolver.ProbeError.InvalidTarget, resolution.value.failures[0].reason);
    try std.testing.expect(fixture.publication.close(std.testing.allocator, &fixture.targets, &fixture.router));
    try std.testing.expectError(error.TargetUnbound, fixture.router.authorizedDirectory(fixture.target, 1));
}

test "directory listing boundary rejects retargeted and invalid entries" {
    const directory: fs.target.Directory = .{ .root = rootRef() };
    const valid_directory: contract.Observation = .{
        .node = .root,
        .revision = .{ .token = "r" },
        .kind = .directory,
    };
    try validateListing(directory, .{ .directory = valid_directory, .revision = .{ .token = "r" }, .entries = &.{} });
    try std.testing.expectError(error.InvalidListing, validateListing(directory, .{
        .directory = .{ .node = .{ .entry = entryRef(4) }, .revision = .{ .token = "r" }, .kind = .directory },
        .revision = .{ .token = "r" },
        .entries = &.{},
    }));
    try std.testing.expectError(error.InvalidListing, validateListing(directory, .{
        .directory = valid_directory,
        .revision = .{ .token = "r" },
        .entries = &.{.{
            .name = .{ .bytes = "bad/name" },
            .observation = .{
                .node = .{ .entry = .{ .authority = @enumFromInt(9), .slot = 1, .generation = 1 } },
                .revision = .{ .token = "r" },
                .kind = .regular,
            },
        }},
    }));
    try std.testing.expectError(error.InvalidListing, validateListing(directory, .{
        .directory = valid_directory,
        .revision = .{ .token = "r" },
        .entries = &.{.{
            .name = try contract.Name.init("other-authority"),
            .observation = .{
                .node = .{ .entry = .{ .authority = @enumFromInt(9), .slot = 1, .generation = 1 } },
                .revision = .{ .token = "r" },
                .kind = .regular,
            },
        }},
    }));
}

test "draft apply is a generic confirmation interaction and revert action" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const session = fixture.plugin.sessions.items[0];
    const row = session.draft.rows.items[0].id;
    const field = session.fieldFor(row).?;
    var snapshot = try fixture.fields.get(field.ref).?.snapshot(std.testing.allocator);
    defer snapshot.deinit();
    try fixture.fields.get(field.ref).?.edit(snapshot.value.revision, .{
        .start = 0,
        .end = snapshot.value.bytes.len,
        .replacement = "pending",
    });

    const requested = try fixture.actions.invoke(&fixture.views, .{
        .action = semantic.action.standard.apply,
        .view = session.view_ref,
        .subject = projection.rootNodeId(),
    });
    const interaction = requested.interaction;
    try std.testing.expectEqual(semantic.interaction.Role.dialog, interaction.role);
    try std.testing.expectEqualStrings("which-key-like", interaction.presentation);
    try std.testing.expectEqualStrings(semantic.action.standard.confirm, interaction.bindings[0].action);
    try std.testing.expectEqualStrings(semantic.action.standard.cancel, interaction.bindings[1].action);

    const applied = try fixture.actions.invokeInteraction(&fixture.views, .{
        .action = semantic.action.standard.confirm,
        .view = session.view_ref,
        .subject = projection.rootNodeId(),
    });
    try std.testing.expect(applied == .handled);
    try std.testing.expectEqual(model.Pending.observed, session.draft.rows.items[0].pending);
    try std.testing.expectEqualStrings("kept", session.draft.rows.items[0].draft.name);
}

test "observed directory rows publish exact links and independent containment" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const session = fixture.plugin.sessions.items[0];
    try fixture.fake.set(&.{
        .{ .name = "kept", .ref = entryRef(8), .revision = "1", .kind = .regular, .mode = 0o644 },
        .{ .name = "child", .ref = entryRef(9), .revision = "1", .kind = .directory },
        .{ .name = "link", .ref = entryRef(10), .revision = "1", .kind = .symlink, .link_target = "child" },
    });
    try session.refresh();

    var directory_row: ?model.NodeId = null;
    var symlink_row: ?model.NodeId = null;
    for (session.draft.rows.items) |row| switch (row.draft.kind) {
        .directory => directory_row = row.id,
        .symlink => symlink_row = row.id,
        else => {},
    };
    const row_id = directory_row orelse return error.TestUnexpectedResult;
    const symlink_id = symlink_row orelse return error.TestUnexpectedResult;
    const row_target = session.rowTargetFor(row_id) orelse return error.TestUnexpectedResult;
    try std.testing.expect(session.rowTargetFor(symlink_id) == null);
    const scene_row = fixture.views.get(session.view_ref).?.scene.content.container.children[1];
    try std.testing.expectEqual(row_target, scene_row.target.?);
    try std.testing.expectEqual(row_target, scene_row.content.container.children[2].target.?);
    try std.testing.expect(scene_row.actions[0].enabled);

    var resolution = try fixture.handlers.resolve(std.testing.allocator, fixture.targets.get(row_target.target).?.*);
    defer resolution.deinit();
    const selected = resolution.value.decide().selected;
    _ = try fixture.handlers.open(selected, row_target);
    var relation = try fixture.relations.query(std.testing.allocator, .{ .source = row_target, .name = "container" });
    defer relation.deinit();
    try std.testing.expectEqual(@as(usize, 1), relation.value.candidates.len);
    try std.testing.expectEqual(session.target, relation.value.candidates[0].relation.target.target);
    try std.testing.expectEqual(session.target_revision, relation.value.candidates[0].relation.target.revision);

    const stable_id = session.draft.row(row_id).?.id;
    try fixture.fake.set(&.{
        .{ .name = "link", .ref = entryRef(10), .revision = "1", .kind = .symlink, .link_target = "child" },
        .{ .name = "child", .ref = entryRef(9), .revision = "1", .kind = .directory },
        .{ .name = "kept", .ref = entryRef(8), .revision = "1", .kind = .regular, .mode = 0o644 },
    });
    try session.refresh();
    try std.testing.expectEqual(stable_id, session.draft.row(row_id).?.id);
    try std.testing.expectEqual(row_target.target, session.rowTargetFor(row_id).?.target);

    var pending = try session.draft.duplicate();
    defer pending.deinit();
    const pending_id = try pending.addDirectory(null, "pending", null);
    try session.publishDraft(&pending);
    try std.testing.expect(session.rowTargetFor(pending_id) == null);

    try session.draft.rename(row_id, "draft-child");
    try fixture.fake.set(&.{
        .{ .name = "link", .ref = entryRef(10), .revision = "1", .kind = .symlink, .link_target = "child" },
        .{ .name = "kept", .ref = entryRef(8), .revision = "1", .kind = .regular, .mode = 0o644 },
    });
    try session.refresh();
    try std.testing.expectEqual(model.Conflict.stale, session.draft.row(row_id).?.conflict);
    try std.testing.expect(session.rowTargetFor(row_id) == null);
}

test "row target publication is closed when its session retires" {
    var fixture: Fixture = undefined;
    try fixture.init();
    const session = fixture.plugin.sessions.items[0];
    try fixture.fake.set(&.{.{ .name = "child", .ref = entryRef(9), .revision = "1", .kind = .directory }});
    try session.refresh();
    const row_target = session.rowTargetFor(session.draft.rows.items[0].id) orelse return error.TestUnexpectedResult;
    const retired = fixture.plugin.sessions.pop().?;
    retired.deinit();
    fixture.plugin.gpa.destroy(retired);
    try std.testing.expect(fixture.targets.get(row_target.target) == null);
    var relation = try fixture.relations.query(std.testing.allocator, .{ .source = row_target, .name = "container" });
    defer relation.deinit();
    try std.testing.expectEqual(@as(usize, 0), relation.value.candidates.len);
    fixture.deinit();
}

const FakeEntry = struct {
    name: []const u8,
    ref: contract.EntryRef,
    revision: []const u8,
    kind: contract.Kind,
    mode: ?u32 = null,
    link_target: ?[]const u8 = null,
};

const FakeFilesystem = struct {
    arena: std.heap.ArenaAllocator = .init(std.testing.allocator),
    entries: []const FakeEntry = &.{},
    durable_leases: bool = false,
    capture_calls: usize = 0,
    release_calls: usize = 0,

    fn deinit(self: *FakeFilesystem) void {
        self.arena.deinit();
    }

    fn set(self: *FakeFilesystem, entries: []const FakeEntry) !void {
        self.arena.deinit();
        self.arena = .init(std.testing.allocator);
        const arena = self.arena.allocator();
        const owned = try arena.alloc(FakeEntry, entries.len);
        for (entries, owned) |entry, *destination| destination.* = .{
            .name = try arena.dupe(u8, entry.name),
            .ref = entry.ref,
            .revision = try arena.dupe(u8, entry.revision),
            .kind = entry.kind,
            .mode = entry.mode,
            .link_target = if (entry.link_target) |target| try arena.dupe(u8, target) else null,
        };
        self.entries = owned;
    }

    pub fn capabilities(self: *FakeFilesystem, _: contract.Root) contract.Error!contract.Capabilities {
        return .{
            .durable_lease = if (self.durable_leases) .{
                .regular_file_max_bytes = 1024 * 1024,
                .symlink_target_max_bytes = 4096,
            } else null,
            .symlink = true,
            .posix_mode = true,
        };
    }

    pub fn observe(_: *FakeFilesystem, gpa: std.mem.Allocator, _: contract.Root, node: contract.NodeRef) contract.Error!contract.OwnedObservation {
        var owned = contract.OwnedObservation.init(gpa);
        owned.value = .{ .node = node, .revision = .{ .token = &.{} }, .kind = .directory };
        return owned;
    }

    pub fn list(self: *FakeFilesystem, gpa: std.mem.Allocator, _: contract.Root, directory: contract.NodeRef) contract.Error!contract.OwnedListing {
        var owned = contract.OwnedListing.init(gpa);
        errdefer owned.deinit();
        const arena = owned.allocator();
        const entries = try arena.alloc(contract.DirEntry, self.entries.len);
        for (self.entries, entries) |entry, *destination| {
            const name = contract.Name.init(try arena.dupe(u8, entry.name)) catch return error.InvalidName;
            destination.* = .{
                .name = name,
                .observation = .{
                    .node = .{ .entry = entry.ref },
                    .revision = .{ .token = try arena.dupe(u8, entry.revision) },
                    .kind = entry.kind,
                    .metadata = .{
                        .mode = entry.mode,
                        .link_target = if (entry.link_target) |target| try arena.dupe(u8, target) else null,
                    },
                },
            };
        }
        owned.value = .{
            .directory = .{ .node = directory, .revision = .{ .token = "listing" }, .kind = .directory },
            .revision = .{ .token = "listing" },
            .entries = entries,
        };
        return owned;
    }

    pub fn read(_: *FakeFilesystem, _: std.mem.Allocator, _: contract.ReadRequest) contract.Error!contract.OwnedReadResult {
        return error.Unsupported;
    }

    pub fn capture(self: *FakeFilesystem, source: contract.EntrySource) contract.Error!contract.LeaseRef {
        if (!self.durable_leases) return error.Unsupported;
        if (!source.root.eql(rootRef())) return error.NotFound;
        for (self.entries) |entry| {
            if (!source.ref.eql(entry.ref)) continue;
            if (!std.mem.eql(u8, source.revision.token, entry.revision)) return error.Stale;
            if (entry.kind != .regular and entry.kind != .symlink) return error.Unsupported;
            self.capture_calls += 1;
            return .{
                .authority = source.root.authority,
                .slot = @intCast(self.capture_calls),
                .generation = 1,
            };
        }
        return error.NotFound;
    }

    pub fn releaseLease(self: *FakeFilesystem, source: contract.LeaseSource) void {
        if (!self.durable_leases or !source.root.eql(rootRef()) or source.ref.generation != 1) return;
        self.release_calls += 1;
    }

    pub fn apply(_: *FakeFilesystem, gpa: std.mem.Allocator, effect_plan: contract.Plan) contract.Error!contract.OwnedApplyReport {
        var owned = contract.OwnedApplyReport.init(gpa);
        const entries = try owned.allocator().alloc(contract.ReportEntry, effect_plan.operations.len);
        for (effect_plan.operations, entries) |planned, *entry| entry.* = .{ .id = planned.id, .outcome = .{ .applied = null } };
        owned.value = .{ .entries = entries };
        return owned;
    }

    pub fn watch(_: *FakeFilesystem, _: contract.Root, _: contract.NodeRef, _: bool) contract.Error!contract.WatchRef {
        return error.Unsupported;
    }

    pub fn pollInvalidation(_: *FakeFilesystem, _: contract.WatchRef) contract.Error!?contract.Invalidation {
        return error.Unsupported;
    }

    pub fn closeWatch(_: *FakeFilesystem, _: contract.WatchRef) void {}
};

const Fixture = struct {
    fake: FakeFilesystem,
    router: fs_runtime.Router,
    targets: target_runtime.target.Registry,
    handlers: target_runtime.resolver.Registry,
    relations: target_runtime.relation.Registry,
    views: view_runtime.view.Registry,
    fields: view_runtime.field.Registry,
    actions: view_runtime.action.Registry,
    target: semantic.target.Ref,
    publication: fs_runtime.publication.Registration,
    plugin: Plugin,

    fn init(self: *Fixture) !void {
        return self.initAt(.{ .root = rootRef() });
    }

    fn initAt(self: *Fixture, directory: fs.target.Directory) !void {
        self.* = .{
            .fake = .{},
            .router = .init(std.testing.allocator),
            .targets = .init(.here),
            .handlers = .init(.here),
            .relations = .init(.here),
            .views = .init(.here),
            .fields = .init(.here),
            .actions = .{},
            .target = undefined,
            .publication = undefined,
            .plugin = undefined,
        };
        try self.fake.set(&.{.{ .name = "kept", .ref = entryRef(8), .revision = "1", .kind = .regular, .mode = 0o644 }});
        try self.router.register(.here, .init(&self.fake));
        self.publication = try fs_runtime.publication.publish(std.testing.allocator, &self.targets, &self.router, @enumFromInt(1), .{
            .display_name = "fixture",
            .directory = directory,
        });
        self.target = self.publication.ref;
        self.plugin = .init(std.testing.allocator, @enumFromInt(2), .{
            .filesystems = &self.router,
            .targets = &self.targets,
            .target_handlers = &self.handlers,
            .target_relations = &self.relations,
            .views = &self.views,
            .fields = &self.fields,
            .actions = &self.actions,
        });
        try self.plugin.start();
        var resolution = try self.handlers.resolve(std.testing.allocator, self.targets.get(self.target).?.*);
        defer resolution.deinit();
        _ = try self.handlers.open(resolution.value.decide().selected, .{ .target = self.target, .revision = 1 });
    }

    fn deinit(self: *Fixture) void {
        self.plugin.deinit();
        self.actions.deinit(std.testing.allocator);
        self.fields.deinit(std.testing.allocator);
        self.views.deinit(std.testing.allocator);
        self.handlers.deinit(std.testing.allocator);
        self.relations.deinit(std.testing.allocator);
        _ = self.publication.close(std.testing.allocator, &self.targets, &self.router);
        self.targets.deinit(std.testing.allocator);
        self.router.deinit();
        self.fake.deinit();
    }
};

fn rootRef() contract.Root {
    return .{ .authority = .here, .slot = 1, .generation = 1 };
}

fn entryRef(slot: u32) contract.EntryRef {
    return .{ .authority = .here, .slot = slot, .generation = 1 };
}
