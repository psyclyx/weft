//! Sandboxed dired adapter over the public guest SDK.
//!
//! The portable dired library owns draft meaning and scene projection. This
//! module supplies only guest-host plumbing: exact target-scoped filesystem
//! calls, retained view/field publication, and generic action callbacks. It
//! has no path access, editor mode, keymap, renderer, syscall, or app import.

const std = @import("std");
const weft = @import("weft");
const dired = @import("weft_dired");

const semantic = weft.semantic;
const fs = weft.fs;
const contract = fs.contract;

pub const Plugin = struct {
    gpa: std.mem.Allocator,
    sessions: std.ArrayList(*Session) = .empty,
    next_field_token: u32 = 1,
    started: bool = false,

    pub fn init(gpa: std.mem.Allocator) Plugin {
        return .{ .gpa = gpa };
    }

    pub fn start(self: *Plugin) !void {
        if (self.started) return error.AlreadyStarted;
        if (!weft.semanticActionProvider()) return error.Rejected;
        _ = try weft.semanticTargetHandlerRegister(1, "dired.directory");
        _ = try weft.semanticRelationProviderRegister(1, "dired.container");
        self.started = true;
    }

    /// The wasm instance owns guest memory wholesale; host teardown revokes
    /// views, fields, targets, handlers, relations, and attachments by owner.
    /// This method is useful to native wasm tests that explicitly invoke the
    /// optional deinit export before destroying the instance.
    pub fn deinit(self: *Plugin) void {
        for (self.sessions.items) |session| {
            session.deinit();
            self.gpa.destroy(session);
        }
        self.sessions.deinit(self.gpa);
        self.* = undefined;
    }

    pub fn targetProbe(self: *Plugin, token: u32) void {
        if (!self.started or token != 1) {
            _ = weft.semanticTargetHandlerProbeNone();
            return;
        }
        var descriptor = weft.semanticTargetHandlerCurrentDescriptor(self.gpa) catch {
            _ = weft.semanticTargetHandlerProbeNone();
            return;
        };
        defer descriptor.deinit();
        _ = dired.directoryFromDescriptor(descriptor.value) catch {
            _ = weft.semanticTargetHandlerProbeNone();
            return;
        };
        // The descriptive filesystem fact is not authority. A capability
        // query forces the host to validate the exact target binding/revision
        // before this handler claims it.
        _ = weft.semanticFsCapabilities(self.gpa, descriptor.value.ref, descriptor.value.revision) catch {
            _ = weft.semanticTargetHandlerProbeError(error.InvalidTarget);
            return;
        };
        _ = weft.semanticTargetHandlerProbeMatch(.exact);
    }

    pub fn targetOpen(self: *Plugin, token: u32) void {
        if (!self.started or token != 1) {
            _ = weft.semanticTargetHandlerOpenError(error.Rejected);
            return;
        }
        var request = weft.semanticTargetHandlerCurrentLocated(self.gpa) catch {
            _ = weft.semanticTargetHandlerOpenError(error.Rejected);
            return;
        };
        defer request.deinit();
        switch (request.value.location) {
            .whole => {},
            else => {
                _ = weft.semanticTargetHandlerOpenError(error.Rejected);
                return;
            },
        }
        for (self.sessions.items) |session| {
            if (session.target.eql(request.value.target) and session.target_revision == request.value.revision) {
                _ = weft.semanticTargetHandlerOpenView(session.view_ref);
                return;
            }
        }
        var descriptor = weft.semanticTargetDescribe(request.value.target, self.gpa) catch {
            _ = weft.semanticTargetHandlerOpenError(error.StaleTarget);
            return;
        };
        defer descriptor.deinit();
        if (descriptor.value.revision != request.value.revision) {
            _ = weft.semanticTargetHandlerOpenError(error.StaleTarget);
            return;
        }
        const directory = dired.directoryFromDescriptor(descriptor.value) catch {
            _ = weft.semanticTargetHandlerOpenError(error.Rejected);
            return;
        };
        const session = self.gpa.create(Session) catch {
            _ = weft.semanticTargetHandlerOpenError(error.Failed);
            return;
        };
        session.* = Session.init(self, request.value.target, request.value.revision, directory);
        session.load() catch {
            session.deinit();
            self.gpa.destroy(session);
            _ = weft.semanticTargetHandlerOpenError(error.Failed);
            return;
        };
        self.sessions.append(self.gpa, session) catch {
            session.deinit();
            self.gpa.destroy(session);
            _ = weft.semanticTargetHandlerOpenError(error.Failed);
            return;
        };
        _ = weft.semanticTargetHandlerOpenView(session.view_ref);
    }

    pub fn relationQuery(self: *Plugin, token: u32) void {
        if (!self.started or token != 1) {
            _ = weft.semanticRelationRespondNone();
            return;
        }
        var request = weft.semanticRelationCurrentQuery(self.gpa) catch {
            _ = weft.semanticRelationRespondError(error.InvalidRelation);
            return;
        };
        defer request.deinit();
        if (!std.mem.eql(u8, request.value.name, "container") or request.value.source.location != .whole) {
            _ = weft.semanticRelationRespondNone();
            return;
        }
        for (self.sessions.items) |session| {
            for (session.row_targets.items) |row_target| {
                if (!row_target.active or !row_target.located.target.eql(request.value.source.target)) continue;
                if (row_target.located.revision != request.value.source.revision) {
                    _ = weft.semanticRelationRespondError(error.StaleTarget);
                    return;
                }
                weft.semanticRelationRespondTarget(.{
                    .target = session.target,
                    .revision = session.target_revision,
                }) catch {
                    _ = weft.semanticRelationRespondError(error.Failed);
                };
                return;
            }
        }
        _ = weft.semanticRelationRespondNone();
    }

    pub fn semanticAction(self: *Plugin) void {
        var request = weft.semanticActionCurrent(self.gpa) catch return;
        defer request.deinit();
        const session = self.sessionForView(request.value.view) orelse {
            _ = weft.semanticActionDecline();
            return;
        };
        const outcome = session.invoke(request.value) catch {
            _ = weft.semanticActionDecline();
            return;
        };
        respondOutcome(outcome) catch {
            _ = weft.semanticActionDecline();
        };
    }

    pub fn fieldEdit(self: *Plugin, token: u32) void {
        for (self.sessions.items) |session| {
            if (session.fieldForToken(token)) |field| {
                var edit = weft.semanticFieldCurrentEdit(self.gpa) catch return;
                defer edit.deinit();
                session.editField(field, edit) catch {};
                return;
            }
        }
    }

    fn sessionForView(self: *Plugin, ref: semantic.view.Ref) ?*Session {
        for (self.sessions.items) |session| if (session.view_ref.eql(ref)) return session;
        return null;
    }

    fn allocateFieldToken(self: *Plugin) !u32 {
        if (self.next_field_token == 0) return error.Exhausted;
        const token = self.next_field_token;
        self.next_field_token +%= 1;
        return token;
    }
};

const Field = struct {
    row: dired.NodeId,
    kind: Kind,
    token: u32,
    ref: semantic.scene.FieldRef,
    revision: u64 = 1,
    selection: weft.SemanticFieldSelection = .{ .anchor = 0, .caret = 0 },
    // Metadata values are typed incrementally just like names. Keep the
    // provider's exact field bytes separate from the parsed model value so a
    // partial octal edit ("0" -> "06" -> "060" -> "0600") is not
    // reformatted to four digits between keystrokes.
    mode_text: [16]u8 = undefined,
    mode_text_len: u8 = 0,

    const Kind = enum { name, mode };

    fn modeText(self: *const Field) []const u8 {
        return self.mode_text[0..self.mode_text_len];
    }

    fn setModeText(self: *Field, bytes: []const u8) !void {
        if (bytes.len > self.mode_text.len) return error.InvalidMode;
        @memcpy(self.mode_text[0..bytes.len], bytes);
        self.mode_text_len = @intCast(bytes.len);
    }

    fn resetModeText(self: *Field, mode: ?u32) !void {
        if (mode) |value| {
            const bytes = std.fmt.bufPrint(&self.mode_text, "{o:0>4}", .{value}) catch return error.InvalidMode;
            self.mode_text_len = @intCast(bytes.len);
        } else self.mode_text_len = 0;
    }

    fn syncModeText(self: *Field, mode: ?u32) !void {
        if (self.kind != .mode) return;
        if (mode == null and self.mode_text_len == 0) return;
        if (parseMode(self.modeText()) catch null) |parsed|
            if (mode != null and parsed == mode.?) return;
        try self.resetModeText(mode);
    }
};

const RowTarget = struct {
    row: dired.NodeId,
    located: semantic.target.Located,
    active: bool = true,
    fresh: bool = false,
};

pub const Session = struct {
    plugin: *Plugin,
    target: semantic.target.Ref,
    target_revision: u64,
    directory: fs.target.Directory,
    capabilities: contract.Capabilities = .{},
    draft: dired.Model,
    fields: std.ArrayList(Field) = .empty,
    row_targets: std.ArrayList(RowTarget) = .empty,
    view_ref: semantic.view.Ref = undefined,
    controller: dired.ActionController = undefined,
    loaded: bool = false,
    apply_committed: bool = false,
    scene_revision: u32 = 1,

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
        self.capabilities = try weft.semanticFsCapabilities(self.plugin.gpa, self.target, self.target_revision);
        var listing = try weft.semanticFsList(self.plugin.gpa, self.target, self.target_revision);
        defer listing.deinit();
        var initial = try dired.reconcileListing(self.plugin.gpa, self.directory, null, listing.value);
        defer initial.deinit();
        const previous = self.draft;
        self.draft = initial;
        initial = previous;
        try self.prepareRowTargets(&self.draft);
        errdefer self.closeAllRowTargets();
        try self.prepareFields(&self.draft);
        errdefer self.closeAllFields();
        var scene = try self.project(&self.draft);
        defer scene.deinit();
        self.view_ref = try weft.semanticViewPublish(scene.value, self.target, self.scene_revision);
        self.controller = .init(self.plugin.gpa, &self.draft, self.view_ref);
        self.loaded = true;
        self.retireRowTargets();
    }

    fn deinit(self: *Session) void {
        if (self.loaded) {
            self.controller.deinit();
            _ = weft.semanticViewClose(self.view_ref);
        }
        self.closeAllRowTargets();
        self.closeAllFields();
        self.draft.deinit();
        self.* = undefined;
    }

    fn invoke(self: *Session, request: semantic.action.Request) !semantic.action.Outcome {
        try self.validateTarget();
        if (std.mem.eql(u8, request.action, semantic.action.standard.apply)) {
            if (self.apply_committed or !self.draft.hasPendingChanges()) return .declined;
            return .{ .interaction = self.applyConfirmation() };
        }
        if (std.mem.eql(u8, request.action, semantic.action.standard.confirm))
            return if (try self.applyConfirmed()) .handled else .declined;
        if (std.mem.eql(u8, request.action, semantic.action.standard.cancel)) return .handled;
        if (std.mem.eql(u8, request.action, semantic.action.standard.open_container)) return .{
            .open_relation = .{
                .source = .{ .target = self.target, .revision = self.target_revision },
                .name = "container",
            },
        };
        if (std.mem.eql(u8, request.action, dired.create_file_action))
            return .{ .focus = try self.addPending(.regular) };
        if (std.mem.eql(u8, request.action, dired.create_directory_action))
            return .{ .focus = try self.addPending(.directory) };
        if (std.mem.eql(u8, request.action, semantic.action.standard.refresh)) {
            try self.refresh(false);
            return .handled;
        }
        if (std.mem.eql(u8, request.action, semantic.action.standard.revert)) {
            try self.refresh(true);
            self.controller.clearCapture();
            self.apply_committed = false;
            return .handled;
        }

        var staged = try self.draft.duplicate();
        defer staged.deinit();
        var staged_controller = dired.ActionController.init(self.plugin.gpa, &staged, self.view_ref);
        defer staged_controller.deinit();
        const outcome = try staged_controller.invoke(request);
        switch (outcome) {
            .handled => try self.publishDraft(&staged),
            .transfer => {
                var captured = staged_controller.takeCapture() orelse return error.MissingTransfer;
                errdefer captured.deinit();
                try self.materializeCapture(&captured);
                self.controller.clearCapture();
                self.controller.capture = captured;
                return .{ .transfer = self.controller.captured().? };
            },
            .focus => if (std.mem.eql(u8, request.action, dired.permissions_edit_action)) {
                const row = dired.modelRowId(request.subject) catch return error.UnknownSubject;
                const field = self.fieldFor(row, .mode) orelse return error.MissingField;
                field.selection = .{ .anchor = 0, .caret = field.mode_text_len };
                try self.updateField(field, &self.draft, field.revision);
            },
            else => {},
        }
        return outcome;
    }

    fn validateTarget(self: *Session) !void {
        var descriptor = try weft.semanticTargetDescribe(self.target, self.plugin.gpa);
        defer descriptor.deinit();
        if (descriptor.value.revision != self.target_revision) return error.StaleTarget;
        const described = try dired.directoryFromDescriptor(descriptor.value);
        if (!dired.sameDirectory(described, self.directory)) return error.StaleTarget;
    }

    fn refresh(self: *Session, discard: bool) !void {
        var listing = try weft.semanticFsList(self.plugin.gpa, self.target, self.target_revision);
        defer listing.deinit();
        var staged = try dired.reconcileListing(
            self.plugin.gpa,
            self.directory,
            if (discard or self.apply_committed) null else &self.draft,
            listing.value,
        );
        defer staged.deinit();
        try self.publishDraft(&staged);
        self.apply_committed = false;
    }

    fn addPending(self: *Session, kind: contract.Kind) !semantic.scene.NodeId {
        var staged = try self.draft.duplicate();
        defer staged.deinit();
        const name = switch (kind) {
            .regular => "new-file",
            .directory => "new-directory",
            else => return error.Unsupported,
        };
        const row = switch (kind) {
            .regular => try staged.addFile(null, name, &.{}, null),
            .directory => try staged.addDirectory(null, name, null),
            else => unreachable,
        };
        try self.publishDraft(&staged);
        const field = self.fieldFor(row, .name) orelse return error.MissingField;
        field.selection = .{ .anchor = 0, .caret = @intCast(name.len) };
        try self.updateField(field, &self.draft, field.revision);
        return dired.nameNodeId(row);
    }

    fn applyConfirmation(self: *const Session) semantic.interaction.Definition {
        return .{
            .role = .dialog,
            .view = self.view_ref,
            .root = dired.rootNodeId(),
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

    fn applyConfirmed(self: *Session) !bool {
        var effect_plan = try self.draft.buildPlan();
        defer effect_plan.deinit();
        var report = try weft.semanticFsApply(self.plugin.gpa, self.target, self.target_revision, effect_plan.value);
        defer report.deinit();
        for (report.value.entries) |entry| switch (entry.outcome) {
            .applied, .already_satisfied => {},
            else => {
                self.refresh(false) catch {};
                return false;
            },
        };
        self.apply_committed = true;
        self.refresh(true) catch return true;
        return true;
    }

    fn materializeCapture(self: *Session, captured: *semantic.transfer.OwnedItem) !void {
        if (captured.value.intent != .copy or self.capabilities.durable_lease == null) return;
        const representation = captured.value.representation(dired.entry_media_type) orelse return;
        const schema = representation.schema orelse return error.InvalidTransfer;
        const decoded = try dired.decodeEntryTransferWithAttachment(
            representation.payload,
            schema,
            representation.resource,
            representation.attachment,
        );
        const entry = switch (decoded.source) {
            .entry => |source| source,
            .lease => return,
        };
        switch (decoded.kind) {
            .regular, .symlink => {},
            .directory, .other => return,
        }
        const capture = try weft.semanticTransferCapture(self.target, self.target_revision, entry);
        const payload = try dired.encodeEntryTransfer(self.plugin.gpa, .{ .lease = capture.source }, decoded.kind, decoded.mode);
        defer self.plugin.gpa.free(payload);
        const representations = try self.plugin.gpa.alloc(semantic.transfer.Representation, captured.value.representations.len);
        defer self.plugin.gpa.free(representations);
        var replaced = false;
        for (captured.value.representations, representations) |source, *destination| {
            destination.* = source;
            if (!std.mem.eql(u8, source.media_type, dired.entry_media_type)) continue;
            destination.schema = dired.entry_schema_current;
            destination.payload = payload;
            destination.resource = null;
            destination.attachment = capture.attachment;
            replaced = true;
        }
        if (!replaced) return error.InvalidTransfer;
        const materialized = try semantic.transfer.OwnedItem.init(self.plugin.gpa, .{
            .intent = captured.value.intent,
            .suggested_name = captured.value.suggested_name,
            .source = captured.value.source,
            .representations = representations,
        });
        captured.deinit();
        captured.* = materialized;
    }

    fn editField(self: *Session, field: *Field, edit: weft.SemanticFieldEdit) !void {
        var expected: [8]u8 = undefined;
        std.mem.writeInt(u64, &expected, field.revision, .little);
        if (!std.mem.eql(u8, edit.expected_revision, &expected)) return error.Stale;
        const row = self.draft.row(field.row) orelse return error.Stale;
        const current = switch (field.kind) {
            .name => row.draft.name,
            .mode => field.modeText(),
        };
        const start: usize = edit.start;
        const end: usize = edit.end;
        if (start > end or end > current.len or std.mem.indexOfAny(u8, edit.replacement, "\r\n") != null)
            return error.InvalidEdit;
        const next = try self.plugin.gpa.alloc(u8, current.len - (end - start) + edit.replacement.len);
        defer self.plugin.gpa.free(next);
        @memcpy(next[0..start], current[0..start]);
        @memcpy(next[start..][0..edit.replacement.len], edit.replacement);
        @memcpy(next[start + edit.replacement.len ..], current[end..]);
        var staged = try self.draft.duplicate();
        defer staged.deinit();
        switch (field.kind) {
            .name => try staged.rename(field.row, next),
            .mode => try staged.setMode(field.row, try parseMode(next)),
        }
        const previous_selection = field.selection;
        const previous_mode_text = field.mode_text;
        const previous_mode_text_len = field.mode_text_len;
        if (field.kind == .mode) try field.setModeText(next);
        field.selection = edit.selection_after orelse .{
            .anchor = @intCast(start + edit.replacement.len),
            .caret = @intCast(start + edit.replacement.len),
        };
        self.publishDraft(&staged) catch |err| {
            field.selection = previous_selection;
            field.mode_text = previous_mode_text;
            field.mode_text_len = previous_mode_text_len;
            // publishDraft restores the authoritative model snapshots; push
            // this field's exact pre-edit presentation state as well (not a
            // canonicalized approximation of a partially typed mode).
            self.updateField(field, &self.draft, field.revision) catch {};
            return err;
        };
    }

    /// Publish fields and scene from the staged value, then swap the model.
    /// New handles are rolled back if any publication fails; existing field
    /// snapshots are restored to the live value if scene replacement fails.
    fn publishDraft(self: *Session, staged: *dired.Model) !void {
        const old_fields_len = self.fields.items.len;
        try self.prepareRowTargets(staged);
        errdefer self.abortRowTargets();
        self.prepareFields(staged) catch |err| {
            self.rollbackFields(old_fields_len);
            return err;
        };
        errdefer self.rollbackFields(old_fields_len);
        var scene = try self.project(staged);
        defer scene.deinit();

        var updated: usize = 0;
        errdefer {
            for (self.fields.items[0..updated]) |*field|
                self.updateField(field, &self.draft, field.revision) catch {};
        }
        for (self.fields.items[0..old_fields_len]) |*field| {
            try self.updateField(field, staged, field.revision +| 1);
            updated += 1;
        }

        const next_revision = std.math.add(u32, self.scene_revision, 1) catch return error.RevisionOverflow;
        try weft.semanticViewReplace(self.view_ref, next_revision, scene.value);
        const previous = self.draft;
        self.draft = staged.*;
        staged.* = previous;
        self.scene_revision = next_revision;
        self.controller.model = &self.draft;
        for (self.fields.items[0..old_fields_len]) |*field| field.revision +|= 1;
        self.pruneFields();
        self.retireRowTargets();
    }

    fn prepareFields(self: *Session, draft: *const dired.Model) !void {
        for (draft.rows.items) |row| {
            try self.ensureField(draft, row.id, .name);
            if (self.modeEditable(row)) try self.ensureField(draft, row.id, .mode);
        }
    }

    fn ensureField(self: *Session, draft: *const dired.Model, row: dired.NodeId, kind: Field.Kind) !void {
        if (self.fieldFor(row, kind) != null) return;
        const token = try self.plugin.allocateFieldToken();
        var field: Field = .{
            .row = row,
            .kind = kind,
            .token = token,
            .ref = undefined,
        };
        const draft_row = draft.row(row) orelse return error.Stale;
        if (kind == .mode) try field.resetModeText(draft_row.draft.mode);
        field.ref = try self.registerField(field, draft);
        errdefer _ = weft.semanticFieldClose(field.ref);
        try self.fields.append(self.plugin.gpa, field);
    }

    fn registerField(self: *Session, field: Field, draft: *const dired.Model) !semantic.scene.FieldRef {
        const row = draft.row(field.row) orelse return error.Stale;
        var revision: [8]u8 = undefined;
        std.mem.writeInt(u64, &revision, field.revision, .little);
        const bytes = fieldBytes(row.*, &field);
        return weft.semanticFieldRegister(field.token, .{
            .revision = &revision,
            .bytes = bytes,
            .selection = clampSelection(field.selection, bytes.len),
            .read_only = fieldReadOnly(self, row.*, field.kind),
            .single_line = true,
        });
    }

    fn updateField(self: *Session, field: *Field, draft: *const dired.Model, revision_value: u64) !void {
        const row = draft.row(field.row) orelse return error.Stale;
        var revision: [8]u8 = undefined;
        std.mem.writeInt(u64, &revision, revision_value, .little);
        try field.syncModeText(row.draft.mode);
        const bytes = fieldBytes(row.*, field);
        field.selection = clampSelection(field.selection, bytes.len);
        try weft.semanticFieldUpdate(field.ref, .{
            .revision = &revision,
            .bytes = bytes,
            .selection = field.selection,
            .read_only = fieldReadOnly(self, row.*, field.kind),
            .single_line = true,
        });
    }

    fn fieldFor(self: *Session, row: dired.NodeId, kind: Field.Kind) ?*Field {
        for (self.fields.items) |*field| if (field.row == row and field.kind == kind) return field;
        return null;
    }

    fn fieldForToken(self: *Session, token: u32) ?*Field {
        for (self.fields.items) |*field| if (field.token == token) return field;
        return null;
    }

    fn rollbackFields(self: *Session, first: usize) void {
        while (self.fields.items.len > first) {
            const field = self.fields.pop().?;
            _ = weft.semanticFieldClose(field.ref);
        }
    }

    fn pruneFields(self: *Session) void {
        var index = self.fields.items.len;
        while (index > 0) {
            index -= 1;
            const field = self.fields.items[index];
            if (self.draft.row(field.row)) |row| {
                if (field.kind == .name or self.modeEditable(row.*)) continue;
            }
            _ = weft.semanticFieldClose(field.ref);
            _ = self.fields.swapRemove(index);
        }
    }

    fn closeAllFields(self: *Session) void {
        for (self.fields.items) |field| _ = weft.semanticFieldClose(field.ref);
        self.fields.deinit(self.plugin.gpa);
    }

    fn prepareRowTargets(self: *Session, draft: *const dired.Model) !void {
        for (self.row_targets.items) |*target| target.active = false;
        const old_len = self.row_targets.items.len;
        errdefer {
            while (self.row_targets.items.len > old_len) {
                const target = self.row_targets.pop().?;
                _ = weft.semanticTargetClose(target.located.target);
            }
            for (self.row_targets.items) |*target| target.active = true;
        }
        for (draft.rows.items) |row| {
            const child = dired.observedChild(self.directory, row) orelse continue;
            var retained = false;
            for (self.row_targets.items) |*target| {
                if (target.row != row.id) continue;
                target.active = true;
                target.fresh = false;
                retained = true;
                break;
            }
            if (retained) continue;
            const located = weft.semanticFsPublishChildDirectory(
                self.plugin.gpa,
                .{ .target = self.target, .revision = self.target_revision },
                child.entry,
                child.revision,
            ) catch continue;
            var owned = true;
            errdefer {
                if (owned) _ = weft.semanticTargetClose(located.target);
            }
            try self.row_targets.append(self.plugin.gpa, .{
                .row = row.id,
                .located = located,
                .fresh = true,
            });
            owned = false;
        }
    }

    fn abortRowTargets(self: *Session) void {
        var index = self.row_targets.items.len;
        while (index > 0) {
            index -= 1;
            if (!self.row_targets.items[index].fresh) continue;
            const target = self.row_targets.swapRemove(index);
            _ = weft.semanticTargetClose(target.located.target);
        }
        for (self.row_targets.items) |*target| {
            target.active = true;
            target.fresh = false;
        }
    }

    fn retireRowTargets(self: *Session) void {
        var index = self.row_targets.items.len;
        while (index > 0) {
            index -= 1;
            if (self.row_targets.items[index].active) continue;
            const target = self.row_targets.swapRemove(index);
            _ = weft.semanticTargetClose(target.located.target);
        }
        for (self.row_targets.items) |*target| target.fresh = false;
    }

    fn closeAllRowTargets(self: *Session) void {
        for (self.row_targets.items) |target| _ = weft.semanticTargetClose(target.located.target);
        self.row_targets.deinit(self.plugin.gpa);
    }

    fn rowTarget(self: *Session, row: dired.NodeId) ?semantic.scene.TargetLink {
        for (self.row_targets.items) |target|
            if (target.active and target.row == row) return target.located;
        return null;
    }

    fn project(self: *Session, draft: *const dired.Model) !dired.OwnedScene {
        const bindings = try self.plugin.gpa.alloc(dired.FieldBinding, draft.rows.items.len);
        defer self.plugin.gpa.free(bindings);
        for (draft.rows.items, bindings) |row, *binding| binding.* = .{
            .row = row.id,
            .field = self.fieldFor(row.id, .name).?.ref,
            .mode_field = if (self.fieldFor(row.id, .mode)) |field| field.ref else null,
            .target = self.rowTarget(row.id),
        };
        // A relation request is harmless when no provider answers it. Keeping
        // the action available lets an independent local/remote/synthetic
        // target provider contribute containment without a dired-specific
        // query or config branch.
        return dired.projectWith(self.plugin.gpa, draft.rows.items, bindings, .{ .has_container = true });
    }

    fn modeEditable(self: *const Session, row: dired.Row) bool {
        if (!self.capabilities.posix_mode) return false;
        return switch (row.draft.kind) {
            .regular, .directory => true,
            .symlink, .other => false,
        };
    }
};

fn fieldBytes(row: dired.Row, field: *const Field) []const u8 {
    return switch (field.kind) {
        .name => row.draft.name,
        .mode => field.modeText(),
    };
}

fn fieldReadOnly(session: *const Session, row: dired.Row, kind: Field.Kind) bool {
    return row.conflict == .stale or
        (kind == .mode and (row.pending == .deleted or !session.modeEditable(row)));
}

fn clampSelection(selection: weft.SemanticFieldSelection, len: usize) weft.SemanticFieldSelection {
    const end: u32 = @intCast(@min(len, std.math.maxInt(u32)));
    return .{
        .anchor = @min(selection.anchor, end),
        .caret = @min(selection.caret, end),
    };
}

fn parseMode(bytes: []const u8) !u32 {
    if (bytes.len == 0 or bytes.len > 6) return error.InvalidMode;
    var value: u32 = 0;
    for (bytes) |byte| {
        if (byte < '0' or byte > '7') return error.InvalidMode;
        value = std.math.mul(u32, value, 8) catch return error.InvalidMode;
        value = std.math.add(u32, value, byte - '0') catch return error.InvalidMode;
    }
    if (value > 0o7777) return error.InvalidMode;
    return value;
}

fn respondOutcome(outcome: semantic.action.Outcome) !void {
    switch (outcome) {
        .declined => if (!weft.semanticActionDecline()) return error.Rejected,
        .handled => if (!weft.semanticActionHandled()) return error.Rejected,
        .transfer => |item| try weft.semanticActionTransfer(item),
        .interaction => |definition| try weft.semanticActionInteraction(definition),
        .open_target => |located| try weft.semanticActionOpenTarget(located),
        .focus => |node| if (!weft.semanticActionFocus(node)) return error.Rejected,
        .open_relation => |request| try weft.semanticActionOpenRelation(request),
    }
}
