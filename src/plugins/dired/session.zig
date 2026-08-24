//! Plugin-owned dired sessions over generic filesystem and semantic services.
//!
//! This is adapter code, not editor core: it turns one typed directory target
//! into an independent draft model, retained scene, editable name fields, and
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
    started: bool = false,

    pub const Host = struct {
        filesystems: *fs_runtime.Router,
        targets: *target_runtime.target.Registry,
        target_handlers: *target_runtime.resolver.Registry,
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
        if (self.handler_ref) |ref| _ = self.host.target_handlers.unregister(self.gpa, ref);
        if (self.started) _ = self.host.actions.unregister(self.gpa, self.owner);
        for (self.sessions.items) |session| {
            session.deinit();
            self.gpa.destroy(session);
        }
        self.sessions.deinit(self.gpa);
        self.* = undefined;
    }

    /// Claim any valid directory attachment whose authority has a live route.
    pub fn probe(self: *Plugin, descriptor: semantic.target.Descriptor) target_runtime.resolver.ProbeError!?semantic.target.Match {
        if (descriptor.kind != .directory) return null;
        const directory = (fs.target.find(descriptor.facts) catch return error.InvalidTarget) orelse return null;
        _ = self.host.filesystems.capabilities(directory.root) catch return error.Unavailable;
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
        const directory = (fs.target.find(descriptor.facts) catch return error.Rejected) orelse return error.Rejected;
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
            const outcome = session.controller.invoke(request) catch |err| return mapActionError(err);
            switch (outcome) {
                .handled => {
                    session.bumpFieldRevisions();
                    session.refreshScene() catch return error.Failed;
                },
                else => {},
            }
            return outcome;
        }
        return error.Stale;
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
            error.StaleSubject, error.InvalidView => error.Stale,
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
    plugin: *Plugin,
    target: semantic.target.Ref,
    target_revision: u64,
    directory: fs.target.Directory,
    draft: model.Model,
    fields: std.ArrayList(*NameField) = .empty,
    view_ref: semantic.view.Ref = undefined,
    controller: actions.Controller = undefined,
    loaded: bool = false,
    scene_revision: u64 = 1,

    fn init(plugin: *Plugin, target: semantic.target.Ref, target_revision: u64, directory: fs.target.Directory) Session {
        return .{
            .plugin = plugin,
            .target = target,
            .target_revision = target_revision,
            .directory = directory,
            .draft = .init(plugin.gpa, directory.root),
        };
    }

    fn load(self: *Session) !void {
        try self.refreshModel(false);
        try self.prepareFields();
        var scene = try self.projectScene();
        defer scene.deinit();
        self.view_ref = try self.plugin.host.views.publish(
            self.plugin.gpa,
            self.plugin.owner,
            self.target,
            self.scene_revision,
            scene.value,
        );
        self.controller = .init(self.plugin.gpa, &self.draft, self.view_ref);
        self.loaded = true;
        self.pruneFields();
    }

    pub fn deinit(self: *Session) void {
        if (self.loaded) {
            self.controller.deinit();
            _ = self.plugin.host.views.close(self.plugin.gpa, self.plugin.owner, self.view_ref);
        }
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
        try self.refreshModel(false);
        self.bumpFieldRevisions();
        try self.refreshScene();
    }

    /// Explicit revert discards the draft and rebuilds from current authority
    /// state. This is the generic operation `:e!` can invoke for a tool view.
    pub fn revert(self: *Session) !void {
        self.controller.clearCapture();
        try self.refreshModel(true);
        self.bumpFieldRevisions();
        try self.refreshScene();
    }

    pub fn buildPlan(self: *const Session) !model.OwnedPlan {
        return self.draft.buildPlan();
    }

    pub fn apply(self: *Session, gpa: std.mem.Allocator) !contract.OwnedApplyReport {
        var effect_plan = try self.buildPlan();
        defer effect_plan.deinit();
        return self.plugin.host.filesystems.apply(gpa, effect_plan.value);
    }

    fn refreshModel(self: *Session, discard_draft: bool) !void {
        var listing = try self.plugin.host.filesystems.list(
            self.plugin.gpa,
            self.directory.root,
            self.directory.node,
        );
        defer listing.deinit();
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
        if (discard_draft) {
            var replacement = model.Model.init(self.plugin.gpa, self.directory.root);
            errdefer replacement.deinit();
            try replacement.reconcile(.{ .entries = entries });
            self.draft.deinit();
            self.draft = replacement;
            if (self.loaded) self.controller.model = &self.draft;
        } else {
            try self.draft.reconcile(.{ .entries = entries });
        }
    }

    fn refreshScene(self: *Session) !void {
        try self.prepareFields();
        var scene = try self.projectScene();
        defer scene.deinit();
        self.scene_revision +|= 1;
        try self.plugin.host.views.replace(
            self.plugin.gpa,
            self.plugin.owner,
            self.view_ref,
            self.scene_revision,
            scene.value,
        );
        self.pruneFields();
    }

    /// Additions are staged before scene replacement; obsolete field refs are
    /// retained until the new scene is live. An allocation failure therefore
    /// cannot publish a scene containing a missing field.
    fn prepareFields(self: *Session) !void {
        for (self.draft.rows.items) |row| {
            if (self.fieldFor(row.id) != null) continue;
            const field = try self.plugin.gpa.create(NameField);
            errdefer self.plugin.gpa.destroy(field);
            field.* = .{ .session = self, .row = row.id };
            field.ref = try self.plugin.host.fields.insert(
                self.plugin.gpa,
                self.plugin.owner,
                .init(field),
            );
            errdefer _ = self.plugin.host.fields.remove(self.plugin.gpa, self.plugin.owner, field.ref);
            try self.fields.append(self.plugin.gpa, field);
        }
    }

    fn pruneFields(self: *Session) void {
        var index: usize = self.fields.items.len;
        while (index > 0) {
            index -= 1;
            const field = self.fields.items[index];
            if (self.draft.row(field.row) != null) continue;
            _ = self.plugin.host.fields.remove(self.plugin.gpa, self.plugin.owner, field.ref);
            _ = self.fields.swapRemove(index);
            self.plugin.gpa.destroy(field);
        }
    }

    fn projectScene(self: *Session) !projection.OwnedScene {
        const bindings = try self.plugin.gpa.alloc(projection.FieldBinding, self.draft.rows.items.len);
        defer self.plugin.gpa.free(bindings);
        for (self.draft.rows.items, bindings) |row, *binding| binding.* = .{
            .row = row.id,
            .field = self.fieldFor(row.id).?.ref,
        };
        return projection.project(self.plugin.gpa, self.draft.rows.items, bindings);
    }

    fn fieldFor(self: *const Session, row: model.NodeId) ?*NameField {
        for (self.fields.items) |field| if (field.row == row) return field;
        return null;
    }

    fn bumpFieldRevisions(self: *Session) void {
        for (self.fields.items) |field| field.revision +|= 1;
    }
};

const NameField = struct {
    session: *Session,
    row: model.NodeId,
    ref: semantic.scene.FieldRef = undefined,
    revision: u64 = 1,
    selection: view_runtime.field.Selection = .{ .anchor = 0, .caret = 0 },

    pub fn snapshot(self: *NameField, gpa: std.mem.Allocator) view_runtime.field.Error!view_runtime.field.OwnedSnapshot {
        const row = self.session.draft.row(self.row) orelse return error.Stale;
        var owned = view_runtime.field.OwnedSnapshot.init(gpa);
        errdefer owned.deinit();
        const arena = owned.allocator();
        const revision = try arena.alloc(u8, @sizeOf(u64));
        std.mem.writeInt(u64, revision[0..8], self.revision, .little);
        const bytes = try arena.dupe(u8, row.draft.name);
        const end: u64 = @intCast(bytes.len);
        if (self.selection.anchor > end or self.selection.caret > end)
            self.selection = .{ .anchor = end, .caret = end };
        owned.value = .{
            .revision = revision,
            .bytes = bytes,
            .selection = self.selection,
            .read_only = row.pending == .deleted or row.conflict == .stale,
            .single_line = true,
        };
        return owned;
    }

    pub fn edit(self: *NameField, expected_revision: []const u8, edit_value: view_runtime.field.Edit) view_runtime.field.Error!void {
        if (expected_revision.len != @sizeOf(u64) or
            std.mem.readInt(u64, expected_revision[0..8], .little) != self.revision)
            return error.Stale;
        const row = self.session.draft.row(self.row) orelse return error.Stale;
        if (row.pending == .deleted or row.conflict == .stale) return error.ReadOnly;
        if (edit_value.start > edit_value.end or edit_value.end > row.draft.name.len) return error.InvalidRange;
        const start: usize = @intCast(edit_value.start);
        const end: usize = @intCast(edit_value.end);
        const next_len = std.math.add(usize, row.draft.name.len - (end - start), edit_value.replacement.len) catch return error.Failed;
        const next = self.session.plugin.gpa.alloc(u8, next_len) catch return error.OutOfMemory;
        defer self.session.plugin.gpa.free(next);
        @memcpy(next[0..start], row.draft.name[0..start]);
        @memcpy(next[start..][0..edit_value.replacement.len], edit_value.replacement);
        @memcpy(next[start + edit_value.replacement.len ..], row.draft.name[end..]);
        self.session.draft.rename(self.row, next) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.Unsupported,
        };
        const caret: u64 = @intCast(start + edit_value.replacement.len);
        self.selection = edit_value.selection_after orelse .{ .anchor = caret, .caret = caret };
        self.revision +|= 1;
        self.session.refreshScene() catch return error.Failed;
    }
};

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
    var views = view_runtime.view.Registry.init(.here);
    defer views.deinit(std.testing.allocator);
    var fields = view_runtime.field.Registry.init(.here);
    defer fields.deinit(std.testing.allocator);
    var action_registry: view_runtime.action.Registry = .{};
    defer action_registry.deinit(std.testing.allocator);

    const binding = try fs.target.encode(std.testing.allocator, .{ .root = rootRef() });
    defer std.testing.allocator.free(binding);
    const target = try targets.publish(std.testing.allocator, @enumFromInt(1), .{
        .kind = .directory,
        .display_name = "fixture",
        .facts = &.{.{ .name = fs.target.fact_name, .value = binding }},
    });
    var plugin = Plugin.init(std.testing.allocator, @enumFromInt(2), .{
        .filesystems = &router,
        .targets = &targets,
        .target_handlers = &handlers,
        .views = &views,
        .fields = &fields,
        .actions = &action_registry,
    });
    try plugin.start();
    defer plugin.deinit();

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
    var snapshot = try fields.get(first_field.ref).?.snapshot(std.testing.allocator);
    defer snapshot.deinit();
    try std.testing.expectEqualStrings("alpha", snapshot.value.bytes);
    try fields.get(first_field.ref).?.edit(snapshot.value.revision, .{ .start = 0, .end = 5, .replacement = "renamed" });
    try std.testing.expectEqualStrings("renamed", session.draft.rows.items[0].draft.name);
    const scene_row = views.get(view_ref).?.scene.content.container.children[0];
    try std.testing.expectEqualStrings("rename", scene_row.facts[0].value);
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

    pub fn capabilities(_: *FakeFilesystem, _: contract.Root) contract.Error!contract.Capabilities {
        return .{ .symlink = true, .posix_mode = true };
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
    views: view_runtime.view.Registry,
    fields: view_runtime.field.Registry,
    actions: view_runtime.action.Registry,
    plugin: Plugin,

    fn init(self: *Fixture) !void {
        self.* = .{
            .fake = .{},
            .router = .init(std.testing.allocator),
            .targets = .init(.here),
            .handlers = .init(.here),
            .views = .init(.here),
            .fields = .init(.here),
            .actions = .{},
            .plugin = undefined,
        };
        try self.fake.set(&.{.{ .name = "kept", .ref = entryRef(8), .revision = "1", .kind = .regular }});
        try self.router.register(.here, .init(&self.fake));
        const binding = try fs.target.encode(std.testing.allocator, .{ .root = rootRef() });
        defer std.testing.allocator.free(binding);
        const target = try self.targets.publish(std.testing.allocator, @enumFromInt(1), .{
            .kind = .directory,
            .display_name = "fixture",
            .facts = &.{.{ .name = fs.target.fact_name, .value = binding }},
        });
        self.plugin = .init(std.testing.allocator, @enumFromInt(2), .{
            .filesystems = &self.router,
            .targets = &self.targets,
            .target_handlers = &self.handlers,
            .views = &self.views,
            .fields = &self.fields,
            .actions = &self.actions,
        });
        try self.plugin.start();
        var resolution = try self.handlers.resolve(std.testing.allocator, self.targets.get(target).?.*);
        defer resolution.deinit();
        _ = try self.handlers.open(resolution.value.decide().selected, .{ .target = target, .revision = 1 });
    }

    fn deinit(self: *Fixture) void {
        self.plugin.deinit();
        self.actions.deinit(std.testing.allocator);
        self.fields.deinit(std.testing.allocator);
        self.views.deinit(std.testing.allocator);
        self.handlers.deinit(std.testing.allocator);
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
