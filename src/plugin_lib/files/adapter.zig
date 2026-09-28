//! Sandboxed files adapter over the public guest SDK.
//!
//! The portable files library owns draft meaning and scene projection. This
//! module supplies only guest-host plumbing: exact target-scoped filesystem
//! calls, retained view/field publication, and generic action callbacks. It
//! has no path access, editor mode, keymap, renderer, syscall, or app import.

const std = @import("std");
const weft = @import("weft");
const files = @import("weft_files");

const semantic = weft.semantic;
const fs = weft.fs;
const contract = fs.contract;

/// What a reveal that has folders to read raises for itself: heard at the
/// frame boundary (`Plugin.signal`), so the reading never runs in the layout
/// pass that asked.
pub const reveal_signal = "files.reveal";

/// A draft's rows by (parent, name) — what a reveal walks, one lookup per
/// name instead of a scan of every row at every level. Borrows the draft's
/// names: built again whenever the draft it indexes changes.
const NameIndex = struct {
    map: std.HashMapUnmanaged(Key, usize, KeyContext, std.hash_map.default_max_load_percentage) = .empty,

    /// A top-level row's parent, which has no id.
    const top = std.math.maxInt(files.NodeId);
    const Key = struct { parent: files.NodeId, name: []const u8 };
    const KeyContext = struct {
        pub fn hash(_: KeyContext, k: Key) u64 {
            var h = std.hash.Wyhash.init(k.parent);
            h.update(k.name);
            return h.final();
        }
        pub fn eql(_: KeyContext, a: Key, b: Key) bool {
            return a.parent == b.parent and std.mem.eql(u8, a.name, b.name);
        }
    };

    fn deinit(self: *NameIndex, gpa: std.mem.Allocator) void {
        self.map.deinit(gpa);
    }

    fn build(self: *NameIndex, gpa: std.mem.Allocator, draft: *const files.Model) !void {
        self.map.clearRetainingCapacity();
        try self.map.ensureTotalCapacity(gpa, @intCast(draft.rows.items.len));
        for (draft.rows.items, 0..) |row, i| {
            // The first row of a name wins, as a scan in row order would.
            const slot = self.map.getOrPutAssumeCapacity(.{ .parent = row.parent orelse top, .name = row.draft.name });
            if (!slot.found_existing) slot.value_ptr.* = i;
        }
    }

    fn get(self: *const NameIndex, draft: *const files.Model, parent: ?files.NodeId, name: []const u8) ?*const files.Row {
        const i = self.map.get(.{ .parent = parent orelse top, .name = name }) orelse return null;
        return &draft.rows.items[i];
    }
};

pub const Plugin = struct {
    gpa: std.mem.Allocator,
    sessions: std.ArrayList(*Session) = .empty,
    next_field_token: u32 = 1,
    started: bool = false,
    reveal_signal_id: ?u32 = null,

    pub fn init(gpa: std.mem.Allocator) Plugin {
        return .{ .gpa = gpa };
    }

    pub fn start(self: *Plugin) !void {
        if (self.started) return error.AlreadyStarted;
        if (!weft.semanticActionProvider()) return error.Rejected;
        _ = try weft.semanticTargetHandlerRegister(1, "files.directory");
        _ = try weft.semanticRelationProviderRegister(1, "files.container");
        self.reveal_signal_id = weft.signalSubscribe(reveal_signal);
        self.started = true;
    }

    /// A signal this plugin hears (export `on_signal` to here). The only one
    /// is its own `files.reveal`: the reading reveals accepted in the layout
    /// pass, done at the frame boundary.
    pub fn signal(self: *Plugin, id: u32) void {
        if (self.reveal_signal_id != id) return;
        for (self.sessions.items) |session| session.revealWork();
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
        _ = files.directoryFromDescriptor(descriptor.value) catch {
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
        const directory = files.directoryFromDescriptor(descriptor.value) catch {
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
        if (!weft.semanticTargetHandlerOpenProvisional(session.view_ref)) {
            _ = self.removeSession(session.view_ref);
            return;
        }
    }

    /// Settle only sessions created by a provisional open. Existing retained
    /// sessions never receive this callback. Rejection rolls the entire tool
    /// session back, including its view, fields, and child publications.
    pub fn targetSettle(self: *Plugin, token: u32, view_ref: semantic.view.Ref, accepted: bool) void {
        if (!self.started or token != 1 or accepted) return;
        _ = self.removeSession(view_ref);
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
                const row = session.draft.row(row_target.row) orelse continue;
                const parent = session.containingTarget(row.*) orelse continue;
                weft.semanticRelationRespondTarget(parent) catch {
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

    pub fn provideRowVerbs() void {
        weft.provide("file.save", .{ .tool = "files" }, "view.apply", 0);
    }

    fn sessionForView(self: *Plugin, ref: semantic.view.Ref) ?*Session {
        for (self.sessions.items) |session| if (session.view_ref.eql(ref)) return session;
        return null;
    }

    fn removeSession(self: *Plugin, ref: semantic.view.Ref) bool {
        for (self.sessions.items, 0..) |session, index| {
            if (!session.view_ref.eql(ref)) continue;
            _ = self.sessions.swapRemove(index);
            session.deinit();
            self.gpa.destroy(session);
            return true;
        }
        return false;
    }

    fn allocateFieldToken(self: *Plugin) !u32 {
        if (self.next_field_token == 0) return error.Exhausted;
        const token = self.next_field_token;
        self.next_field_token +%= 1;
        return token;
    }
};

const Field = struct {
    row: files.NodeId,
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
    row: files.NodeId,
    // The target registry revision is not the filesystem entry revision.
    // Retaining by row id alone would leave a child target stale after an
    // external rename or metadata change.
    entry: contract.EntryRef,
    entry_revision: []u8,
    kind: contract.Kind,
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
    draft: files.Model,
    fields: std.ArrayList(Field) = .empty,
    row_targets: std.ArrayList(RowTarget) = .empty,
    view_ref: semantic.view.Ref = undefined,
    controller: files.ActionController = undefined,
    loaded: bool = false,
    apply_committed: bool = false,
    scene_revision: u32 = 1,
    /// A reveal accepted with folders still to read (`view.reveal` answered
    /// `.handled`): its designation, owned, read at the `files.reveal`
    /// signal — never in the layout pass that asked.
    reveal_want: ?[]u8 = null,
    /// A reveal whose reading failed, owned: asked again it declines rather
    /// than waiting for a republish that is not coming.
    reveal_failed: ?[]u8 = null,
    /// The folders reveals opened, and the user has not touched since: a
    /// later reveal that does not pass through one folds it again, so the
    /// listing does not grow (and re-read on refresh) every folder the
    /// editor ever visited.
    reveal_opened: std.ArrayList(files.NodeId) = .empty,

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
        var initial = try files.reconcileListing(self.plugin.gpa, self.directory, null, listing.value);
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
        if (self.reveal_want) |w| self.plugin.gpa.free(w);
        if (self.reveal_failed) |w| self.plugin.gpa.free(w);
        self.reveal_opened.deinit(self.plugin.gpa);
        self.* = undefined;
    }

    fn invoke(self: *Session, request: semantic.action.Request) !semantic.action.Outcome {
        try self.validateTarget();
        if (std.mem.eql(u8, request.action, semantic.action.standard.apply)) {
            if (self.apply_committed or !self.draft.hasPendingChanges()) return .declined;
            // The draft says whether to ask (`Model.applyAsks`): a single
            // name just typed applies as typed; the rest confirm first.
            if (!self.draft.applyAsks()) return if (try self.applyConfirmed()) .handled else .declined;
            return .{ .interaction = self.applyConfirmation() };
        }
        if (std.mem.eql(u8, request.action, semantic.action.standard.confirm))
            return if (try self.applyConfirmed()) .handled else .declined;
        if (std.mem.eql(u8, request.action, semantic.action.standard.cancel)) return .handled;
        if (std.mem.eql(u8, request.action, semantic.action.standard.open)) {
            const id = files.modelRowId(request.subject) catch return .declined;
            const row = self.draft.row(id) orelse return .declined;
            if (row.draft.kind != .directory) return .declined;
            return .{ .open_target = self.rowTarget(id) orelse return .declined };
        }
        if (std.mem.eql(u8, request.action, semantic.action.standard.open_container)) return .{
            .open_relation = .{
                .source = .{ .target = self.target, .revision = self.target_revision },
                .name = "container",
            },
        };
        if (std.mem.eql(u8, request.action, semantic.action.standard.toggle_expanded)) {
            const row = files.modelRowId(request.subject) catch return .declined;
            try self.toggleExpanded(row);
            return .handled;
        }
        if (std.mem.eql(u8, request.action, semantic.action.standard.reveal)) return switch (try self.reveal(request.argument)) {
            .found => |node| .{ .focus = node },
            // Accepted: the folders are read at the signal, and the view's
            // republish is what has the viewport ask again.
            .pending => .handled,
            .absent => .declined,
        };
        if (std.mem.eql(u8, request.action, semantic.action.standard.set_working_target)) {
            if (request.subject == files.rootNodeId()) return .{ .set_working_target = .{
                .target = self.target,
                .revision = self.target_revision,
            } };
            const row = files.modelRowId(request.subject) catch return .declined;
            const target = self.rowTarget(row) orelse return .declined;
            return .{ .set_working_target = target };
        }
        if (std.mem.eql(u8, request.action, semantic.action.standard.insert_before) or
            std.mem.eql(u8, request.action, semantic.action.standard.insert_after))
            return .{ .focus = try self.insertPending(request.subject, if (std.mem.eql(u8, request.action, semantic.action.standard.insert_before)) .before else .after) };
        if (std.mem.eql(u8, request.action, files.create_file_action))
            return .{ .focus = try self.addPending(.regular) };
        if (std.mem.eql(u8, request.action, files.create_directory_action))
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

        var staged = try self.stage();
        defer staged.deinit();
        var staged_controller = files.ActionController.init(self.plugin.gpa, &staged, self.view_ref);
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
            .focus => if (std.mem.eql(u8, request.action, files.permissions_edit_action)) {
                const row = files.modelRowId(request.subject) catch return error.UnknownSubject;
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
        const described = try files.directoryFromDescriptor(descriptor.value);
        if (!files.sameDirectory(described, self.directory)) return error.StaleTarget;
    }

    fn refresh(self: *Session, discard: bool) !void {
        var listing = try weft.semanticFsList(self.plugin.gpa, self.target, self.target_revision);
        defer listing.deinit();
        var staged = try files.reconcileListing(
            self.plugin.gpa,
            self.directory,
            if (discard or self.apply_committed) null else &self.draft,
            listing.value,
        );
        defer staged.deinit();
        try self.refreshExpanded(&staged);
        try self.publishDraft(&staged);
        self.apply_committed = false;
    }

    /// Rows folded open are part of what this view shows, so one refresh
    /// re-reads every open scope. The open set is taken up front — a listing
    /// only ever adds closed rows, so it cannot grow while being walked.
    fn refreshExpanded(self: *Session, staged: *files.Model) !void {
        var open: std.ArrayList(files.NodeId) = .empty;
        defer open.deinit(self.plugin.gpa);
        for (staged.rows.items) |row| {
            if (row.expanded) try open.append(self.plugin.gpa, row.id);
        }
        for (open.items) |row| {
            // A scope whose directory vanished went away with its parent's
            // listing; one that can no longer be read folds shut rather than
            // failing the whole refresh.
            const current = staged.row(row) orelse continue;
            if (!current.expanded) continue;
            self.readChildren(staged, row) catch {
                staged.setExpanded(row, false) catch {};
            };
        }
    }

    fn stage(self: *Session) !files.Model {
        return self.draft.duplicate();
    }

    /// Fold a directory row open or closed. Collapsing keeps its rows in the
    /// draft; opening re-reads the provider, so a fold is never a stale
    /// replay of what the directory held last time.
    fn toggleExpanded(self: *Session, row: files.NodeId) !void {
        var staged = try self.stage();
        defer staged.deinit();
        const current = staged.row(row) orelse return error.UnknownSubject;
        if (current.expanded)
            try staged.setExpanded(row, false)
        else
            try self.readChildren(&staged, row);
        try self.publishDraft(&staged);
        // The user folded it: theirs now, never folded behind their back.
        for (self.reveal_opened.items, 0..) |id, i| if (id == row) {
            _ = self.reveal_opened.swapRemove(i);
            break;
        };
    }

    /// What a reveal came to.
    const RevealAnswer = union(enum) {
        /// The name node of the row that shows it.
        found: semantic.scene.NodeId,
        /// Below this listing, behind a folder not read yet: accepted, and
        /// answered once the reading (at the `files.reveal` signal) has
        /// republished the view.
        pending,
        /// Not below this listing, or not there.
        absent,
    };

    /// `view.reveal`: the row showing `argument`, a designation somewhere
    /// below this listing's directory. Answered from what the draft already
    /// holds, one index lookup per name: found when every folder on the way
    /// is open, else `pending` — this runs in the layout pass that asked, so
    /// it never reads a directory (a peer's is a round trip) or publishes;
    /// `revealWork` does, off that pass, once.
    fn reveal(self: *Session, argument: []const u8) !RevealAnswer {
        const gpa = self.plugin.gpa;
        if (self.reveal_failed) |failed| {
            if (std.mem.eql(u8, failed, argument)) return .absent;
            gpa.free(failed);
            self.reveal_failed = null;
        }
        const rest = (try self.revealPath(argument)) orelse return .absent;
        var index: NameIndex = .{};
        defer index.deinit(gpa);
        try index.build(gpa, &self.draft);
        var parent: ?files.NodeId = null;
        var found: ?files.NodeId = null;
        var closed = false;
        var through: std.ArrayList(files.NodeId) = .empty;
        defer through.deinit(gpa);
        var names = std.mem.tokenizeScalar(u8, rest, '/');
        while (names.next()) |name| {
            const row = index.get(&self.draft, parent, name) orelse return .absent;
            found = row.id;
            if (names.peek() == null) break;
            if (row.draft.kind != .directory) return .absent;
            if (!row.expanded) {
                closed = true;
                break;
            }
            try through.append(gpa, row.id);
            parent = row.id;
        }
        // Folders an earlier reveal opened that this one does not pass
        // through are folded again — by the same deferred work.
        const stale = for (self.reveal_opened.items) |id| {
            if (std.mem.indexOfScalar(files.NodeId, through.items, id) == null) break true;
        } else false;
        if (closed or stale) {
            const owned = try gpa.dupe(u8, argument);
            if (self.reveal_want) |w| gpa.free(w);
            self.reveal_want = owned;
            weft.signalEmit(reveal_signal);
        }
        if (closed) return .pending;
        return .{ .found = try files.nameNodeId(found orelse return .absent) };
    }

    /// The part of `argument` below this listing's directory (`/`-separated
    /// names), or null when it is not below it: another authority, another
    /// tree. The listing's own designation is the one its publisher bound it
    /// under, stated on its descriptor.
    fn revealPath(self: *Session, argument: []const u8) !?[]const u8 {
        const durable = semantic.durable;
        const want = durable.parse(argument) orelse return null;
        if (!want.kind.isPath()) return null;
        var descriptor = try weft.semanticTargetDescribe(self.target, self.plugin.gpa);
        defer descriptor.deinit();
        const own_text = for (descriptor.value.facts) |fact| {
            if (std.mem.eql(u8, fact.name, fs.target.designation_fact_name)) break fact.value;
        } else return null;
        const own = durable.parse(own_text) orelse return null;
        if (!own.authority.eql(want.authority)) return null;
        const base = std.mem.trimEnd(u8, own.ref, "/");
        if (want.ref.len <= base.len or !std.mem.startsWith(u8, want.ref, base) or want.ref[base.len] != '/') return null;
        return want.ref[base.len..];
    }

    /// The reading a reveal asked for, at the `files.reveal` signal — the
    /// frame boundary, off the layout pass: open every folder on the way,
    /// fold the ones earlier reveals opened that this one does not pass
    /// through, and publish ONCE. The waiting viewport asks again when the
    /// view republishes, and the answer is then `found`. A failure records
    /// the reveal as failed, so asking again declines.
    fn revealWork(self: *Session) void {
        const want = self.reveal_want orelse return;
        self.reveal_want = null;
        self.openTowards(want) catch {
            self.abortRowTargets();
            if (self.reveal_failed) |w| self.plugin.gpa.free(w);
            self.reveal_failed = want;
            return;
        };
        self.plugin.gpa.free(want);
    }

    fn openTowards(self: *Session, want: []const u8) !void {
        const gpa = self.plugin.gpa;
        const rest = (try self.revealPath(want)) orelse return;
        var staged = try self.stage();
        defer staged.deinit();
        var index: NameIndex = .{};
        defer index.deinit(gpa);
        try index.build(gpa, &staged);
        var through: std.ArrayList(files.NodeId) = .empty;
        defer through.deinit(gpa);
        var opened: std.ArrayList(files.NodeId) = .empty;
        defer opened.deinit(gpa);
        var parent: ?files.NodeId = null;
        var names = std.mem.tokenizeScalar(u8, rest, '/');
        while (names.next()) |name| {
            if (names.peek() == null) break;
            const row = index.get(&staged, parent, name) orelse break;
            if (row.draft.kind != .directory) break;
            const id = row.id;
            try through.append(gpa, id);
            if (!row.expanded) {
                // A folder is read through its row's own target; a row this
                // walk just listed has none until the staged rows' targets
                // are published (the scene publish below keeps them).
                if (self.rowTarget(id) == null) try self.prepareRowTargets(&staged);
                try self.readChildren(&staged, id);
                try opened.append(gpa, id);
                try index.build(gpa, &staged);
            }
            parent = id;
        }
        var folded = false;
        for (self.reveal_opened.items) |id| {
            if (std.mem.indexOfScalar(files.NodeId, through.items, id) != null) continue;
            const row = staged.row(id) orelse continue;
            if (!row.expanded) continue;
            try staged.setExpanded(id, false);
            folded = true;
        }
        if (opened.items.len == 0 and !folded) return;
        try self.publishDraft(&staged);
        // What reveals hold open now: the folders on this path they opened.
        var kept: usize = 0;
        for (self.reveal_opened.items) |id| {
            if (std.mem.indexOfScalar(files.NodeId, through.items, id) == null) continue;
            self.reveal_opened.items[kept] = id;
            kept += 1;
        }
        self.reveal_opened.shrinkRetainingCapacity(kept);
        try self.reveal_opened.appendSlice(gpa, opened.items);
    }
    /// Read one expanded row's directory through its own exact child target
    /// and reconcile the result into that row's scope.
    fn readChildren(self: *Session, staged: *files.Model, row: files.NodeId) !void {
        const located = self.rowTarget(row) orelse return error.MissingTarget;
        var descriptor = try weft.semanticTargetDescribe(located.target, self.plugin.gpa);
        defer descriptor.deinit();
        if (descriptor.value.revision != located.revision) return error.StaleTarget;
        const directory = try files.directoryFromDescriptor(descriptor.value);
        var listing = try weft.semanticFsList(self.plugin.gpa, located.target, located.revision);
        defer listing.deinit();
        try files.reconcileChildListing(self.plugin.gpa, directory, staged, row, listing.value);
        try staged.setExpanded(row, true);
    }

    fn insertPending(self: *Session, subject: semantic.scene.NodeId, placement: files.PastePlacement) !semantic.scene.NodeId {
        var staged = try self.stage();
        defer staged.deinit();
        const anchor: ?files.PasteAnchor = if (subject == files.rootNodeId()) null else blk: {
            const id = try files.modelRowId(subject);
            const row = staged.row(id) orelse return error.UnknownSubject;
            break :blk .{ .row = id, .parent = row.parent };
        };
        const row = try staged.insertFileAt(anchor, placement);
        try self.publishDraft(&staged);
        return files.nameNodeId(row);
    }

    fn addPending(self: *Session, kind: contract.Kind) !semantic.scene.NodeId {
        var staged = try self.stage();
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
        return files.nameNodeId(row);
    }

    fn applyConfirmation(self: *const Session) semantic.interaction.Definition {
        return .{
            .role = .dialog,
            .view = self.view_ref,
            .root = files.rootNodeId(),
            .actions = &.{
                .{ .id = semantic.action.standard.confirm, .label = "Apply", .disposition = .close_on_handled },
                .{ .id = semantic.action.standard.cancel, .label = "Cancel", .disposition = .close_on_handled },
            },
            .bindings = &.{
                .{ .input = "y", .action = semantic.action.standard.confirm },
                .{ .input = "n", .action = semantic.action.standard.cancel },
                .{ .input = "Return", .action = semantic.action.standard.confirm },
                .{ .input = "Escape", .action = semantic.action.standard.cancel },
            },
            .default_action = semantic.action.standard.confirm,
            .cancel_action = semantic.action.standard.cancel,
            .presentation = "which-key-like",
        };
    }

    fn applyConfirmed(self: *Session) !bool {
        // Quarantine is the conservative default for portable model clients,
        // but it is not universally available. The provider capability is the
        // sole policy input at this boundary; files does not inspect kinds or
        // platforms and therefore keeps the same plan shape everywhere.
        const remove_policy: contract.RemovePolicy = if (self.capabilities.quarantine)
            .quarantine
        else
            .permanent;
        var effect_plan = try self.draft.buildPlanWith(.{ .remove = remove_policy });
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

    /// Lease every copied file the capture carries — each item of a set the
    /// same as a lone one — so the copy survives its source changing.
    fn materializeCapture(self: *Session, captured: *semantic.transfer.OwnedItem) !void {
        if (captured.value.intent != .copy or self.capabilities.durable_lease == null) return;
        const gpa = self.plugin.gpa;
        const count = captured.value.partCount();
        var arena_state = std.heap.ArenaAllocator.init(gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const parts = try arena.alloc(semantic.transfer.Item, count);
        var changed = false;
        for (parts, 0..) |*part, index| {
            part.* = captured.value.part(index);
            if (try self.leased(arena, part.*)) |representations| {
                part.representations = representations;
                changed = true;
            }
        }
        if (!changed) return;
        var set = parts[0];
        set.members = parts[1..];
        const materialized = try semantic.transfer.OwnedItem.init(gpa, set);
        captured.deinit();
        captured.* = materialized;
    }

    /// `item`'s representations with its entry leased, allocated in `arena`,
    /// or null when there is nothing to lease (a directory, an existing
    /// lease, no entry representation).
    fn leased(self: *Session, arena: std.mem.Allocator, item: semantic.transfer.Item) !?[]semantic.transfer.Representation {
        const representation = item.representation(files.entry_media_type) orelse return null;
        const schema = representation.schema orelse return error.InvalidTransfer;
        const decoded = try files.decodeEntryTransferWithAttachment(
            representation.payload,
            schema,
            representation.resource,
            representation.attachment,
        );
        const entry = switch (decoded.source) {
            .entry => |source| source,
            .lease => return null,
        };
        switch (decoded.kind) {
            .regular, .symlink => {},
            .directory, .other => return null,
        }
        const capture = try weft.semanticTransferCapture(self.target, self.target_revision, entry);
        const payload = try files.encodeEntryTransfer(arena, .{ .lease = capture.source }, decoded.kind, decoded.mode);
        const representations = try arena.alloc(semantic.transfer.Representation, item.representations.len);
        for (item.representations, representations) |source, *destination| {
            destination.* = source;
            if (!std.mem.eql(u8, source.media_type, files.entry_media_type)) continue;
            destination.schema = files.entry_schema_current;
            destination.payload = payload;
            destination.resource = null;
            destination.attachment = capture.attachment;
        }
        return representations;
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
        if (start == end and edit.replacement.len == 0) {
            const previous = field.selection;
            field.selection = edit.selection_after orelse .{ .anchor = edit.start, .caret = edit.start };
            errdefer field.selection = previous;
            const revision = try std.math.add(u64, field.revision, 1);
            try self.updateField(field, &self.draft, revision);
            field.revision = revision;
            return;
        }
        const next = try self.plugin.gpa.alloc(u8, current.len - (end - start) + edit.replacement.len);
        defer self.plugin.gpa.free(next);
        @memcpy(next[0..start], current[0..start]);
        @memcpy(next[start..][0..edit.replacement.len], edit.replacement);
        @memcpy(next[start + edit.replacement.len ..], current[end..]);
        var staged = try self.stage();
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
    fn publishDraft(self: *Session, staged: *files.Model) !void {
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

        var updated_fields: std.ArrayList(usize) = .empty;
        defer updated_fields.deinit(self.plugin.gpa);
        errdefer {
            for (updated_fields.items) |field_index| {
                const field = &self.fields.items[field_index];
                self.updateField(field, &self.draft, field.revision) catch {};
            }
        }
        for (self.fields.items[0..old_fields_len], 0..) |*field, field_index| {
            // A clean row may disappear during refresh. Its field has no
            // staged value to update; pruneFields closes it after the new
            // scene commits. Treating that expected disappearance as stale
            // would reject the entire external reconciliation.
            if (staged.row(field.row) == null) continue;
            // Reserve the exact tracking slot before changing the host. The
            // list may contain removed rows interleaved with retained rows;
            // a positional prefix would restore the wrong fields if scene
            // replacement fails after one of those gaps. Append only after
            // the host update succeeds, so rollback names completed updates.
            try updated_fields.ensureUnusedCapacity(self.plugin.gpa, 1);
            try self.updateField(field, staged, field.revision +| 1);
            updated_fields.appendAssumeCapacity(field_index);
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

    fn prepareFields(self: *Session, draft: *const files.Model) !void {
        for (draft.rows.items) |row| {
            try self.ensureField(draft, row.id, .name);
            if (self.modeEditable(row)) try self.ensureField(draft, row.id, .mode);
        }
    }

    fn ensureField(self: *Session, draft: *const files.Model, row: files.NodeId, kind: Field.Kind) !void {
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

    fn registerField(self: *Session, field: Field, draft: *const files.Model) !semantic.scene.FieldRef {
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

    fn updateField(self: *Session, field: *Field, draft: *const files.Model, revision_value: u64) !void {
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

    fn fieldFor(self: *Session, row: files.NodeId, kind: Field.Kind) ?*Field {
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

    fn prepareRowTargets(self: *Session, draft: *const files.Model) !void {
        for (self.row_targets.items) |*target| target.active = false;
        const old_len = self.row_targets.items.len;
        errdefer {
            while (self.row_targets.items.len > old_len) {
                const target = self.row_targets.pop().?;
                _ = weft.semanticTargetClose(target.located.target);
                self.plugin.gpa.free(target.entry_revision);
            }
            for (self.row_targets.items) |*target| target.active = true;
        }
        for (draft.rows.items) |row| {
            const child = files.observedChild(self.directory, row) orelse continue;
            var retained = false;
            var target_index: usize = 0;
            while (target_index < self.row_targets.items.len) : (target_index += 1) {
                const target = &self.row_targets.items[target_index];
                if (target.row != row.id) continue;
                if (target.kind == child.kind and target.entry.eql(child.entry) and
                    std.mem.eql(u8, target.entry_revision, child.revision.token))
                {
                    target.active = true;
                    target.fresh = false;
                    retained = true;
                    break;
                }
                // The row identity survived, but the observation that
                // justified its child target did not. Hide the old target
                // while publishing a replacement, so project() cannot bind
                // stale authority after an external refresh. It remains
                // available to abortRowTargets if publication fails.
                target.active = false;
                target.fresh = false;
                break;
            }
            if (retained) continue;
            // A row inside an expanded directory is a child of THAT
            // directory's exact target, never of the view's own. Rows precede
            // their children, so the containing target is already published.
            const parent = self.containingTarget(row) orelse continue;
            const located = switch (child.kind) {
                .directory => weft.semanticFsPublishChildDirectory(self.plugin.gpa, parent, child.entry, child.revision),
                .regular => weft.semanticFsPublishChildFile(self.plugin.gpa, parent, child.entry, child.revision),
                .symlink, .other => unreachable,
            } catch continue;
            var owned = true;
            errdefer {
                if (owned) _ = weft.semanticTargetClose(located.target);
            }
            const entry_revision = try self.plugin.gpa.dupe(u8, child.revision.token);
            var revision_owned = true;
            errdefer if (revision_owned) self.plugin.gpa.free(entry_revision);
            try self.row_targets.append(self.plugin.gpa, .{
                .row = row.id,
                .entry = child.entry,
                .entry_revision = entry_revision,
                .kind = child.kind,
                .located = located,
                .fresh = true,
            });
            // The row target now owns the revision copy.
            revision_owned = false;
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
            self.plugin.gpa.free(target.entry_revision);
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
            self.plugin.gpa.free(target.entry_revision);
        }
        for (self.row_targets.items) |*target| target.fresh = false;
    }

    fn closeAllRowTargets(self: *Session) void {
        for (self.row_targets.items) |target| {
            _ = weft.semanticTargetClose(target.located.target);
            self.plugin.gpa.free(target.entry_revision);
        }
        self.row_targets.deinit(self.plugin.gpa);
    }

    fn rowTarget(self: *Session, row: files.NodeId) ?semantic.scene.TargetLink {
        for (self.row_targets.items) |target|
            if (target.active and target.row == row) return target.located;
        return null;
    }

    /// The exact directory a row is listed in: the view's own target at the
    /// top level, and the folded-open row's target below it.
    fn containingTarget(self: *Session, row: files.Row) ?semantic.target.Located {
        const parent = row.parent orelse
            return .{ .target = self.target, .revision = self.target_revision };
        return self.rowTarget(parent);
    }

    fn project(self: *Session, draft: *const files.Model) !files.OwnedScene {
        const bindings = try self.plugin.gpa.alloc(files.FieldBinding, draft.rows.items.len);
        defer self.plugin.gpa.free(bindings);
        for (draft.rows.items, bindings) |row, *binding| binding.* = .{
            .row = row.id,
            .field = self.fieldFor(row.id, .name).?.ref,
            .mode_field = if (self.fieldFor(row.id, .mode)) |field| field.ref else null,
            .target = self.rowTarget(row.id),
        };
        // A relation request is harmless when no provider answers it. Keeping
        // the action available lets an independent local/remote/synthetic
        // target provider contribute containment without a files-specific
        // query or config branch.
        return files.projectWith(self.plugin.gpa, draft.rows.items, bindings, .{ .has_container = true });
    }

    fn modeEditable(self: *const Session, row: files.Row) bool {
        if (!self.capabilities.posix_mode) return false;
        return switch (row.draft.kind) {
            .regular, .directory => true,
            .symlink, .other => false,
        };
    }
};

fn fieldBytes(row: files.Row, field: *const Field) []const u8 {
    return switch (field.kind) {
        .name => row.draft.name,
        .mode => field.modeText(),
    };
}

fn fieldReadOnly(session: *const Session, row: files.Row, kind: Field.Kind) bool {
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
        .set_working_target => |located| try weft.semanticActionSetWorkingTarget(located),
    }
}
