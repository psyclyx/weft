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
        _ = try weft.semanticTargetHandlerRegister(1, "files.directory");
        _ = try weft.semanticRelationProviderRegister(1, "files.container");
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
                // The listing is a BUFFER; opening one means looking at it.
                pending_show = session;
                weft.run("files-show");
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
        // OPENING a directory means looking at it, and what you look at is the
        // listing BUFFER. The host used to attach the scene to a buffer of its
        // own here (`session.zig`.s `attachFocusedSemanticView`).
        pending_show = session;
        weft.run("files-show");
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

/// WHAT A ROW AFFORDS, as predicates against what it IS.
///
/// The listing owns no keymap — the property the scene plane had, kept and made
/// cheaper. A grammar binds `Return` to `std.target.activate` and `minus` to
/// `std.hierarchy.step-out`; these `provide`s say those intentions reach here
/// when point is on a row of a listing. Neither side names the other, and a
/// third party can put its own verb on `fs.file` the same way.
pub fn provideRowVerbs() void {
    const on_row: weft.Predicate = .{ .any = &.{
        .{ .role = files.text_rows.role_file },
        .{ .role = files.text_rows.role_directory },
        .{ .role = files.text_rows.role_symlink },
        .{ .role = files.text_rows.role_other },
        .{ .role = files.text_rows.role_dirty },
    } };
    weft.provide("std.target.activate", on_row, "files-enter", 0);
    const in_files: weft.Predicate = .{ .tool = "files" };
    weft.provide("std.hierarchy.step-out", in_files, "files-up", 0);
    // The INTENTION spellings a grammar binds directly (`std.*`, doc §5.1)
    // alongside the bare ACTION names a config binds through
    // `bindActionGroup`. Two spellings of one verb is the vocabulary.s doing,
    // not this plugin.s — it claims both so a grammar reaches the listing
    // whichever way it asks.
    // Folding is offered on a DIRECTORY row and nowhere else. Offered for the
    // whole tool it would be "available" on a file row and then fail, which
    // turns "nothing offers this here" into an error message — absence is
    // nonapplicable (§9.3), and a row that cannot be opened simply does not
    // offer opening.
    weft.provide(
        "std.hierarchy.toggle-expanded",
        .{ .role = files.text_rows.role_directory },
        actionCommandName(semantic.action.standard.toggle_expanded),
        0,
    );
    inline for (.{
        .{ "std.transfer.yank", semantic.action.standard.copy },
        .{ "std.transfer.delete-to-register", semantic.action.standard.cut },
        .{ "std.transfer.paste", semantic.action.standard.paste_after },
    }) |pair| weft.provide(pair[0], on_row, actionCommandName(pair[1]), 0);
    // Saving a listing is applying what was typed into it — the same
    // `std.persistence.save` a text buffer resolves, scoped to this tool.
    weft.provide("save", .{ .tool = "files" }, "files-apply", 0);
    // The workspace vocabulary, claimed for a listing whose view is a text
    // projection. A config binds the NAME (`view.apply`, `fs.entry.create-file`);
    // which plane answers is core.s question, not the user.s — see
    // `builtins.invokeSemanticAction`.
    const in_listing: weft.Predicate = .{ .tool = "files" };
    inline for (action_verbs) |verb| {
        // The row-scoped verbs only where a row can answer them; the rest are
        // about the LISTING and apply wherever it is focused.
        const when: weft.Predicate = if (std.mem.eql(u8, verb, semantic.action.standard.toggle_expanded))
            .{ .role = files.text_rows.role_directory }
        else
            in_listing;
        weft.provide(verb, when, actionCommandName(verb), 0);
    }
}

/// One command per standard verb, each running it against the row under point.
///
/// Generated rather than listed: the table below IS the set the plugin
/// `provide`s, so a verb cannot be offered without a command behind it or the
/// reverse.
pub const action_verbs = [_][]const u8{
    semantic.action.standard.copy,
    semantic.action.standard.cut,
    semantic.action.standard.delete,
    semantic.action.standard.paste_before,
    semantic.action.standard.paste_after,
    semantic.action.standard.toggle_expanded,
    semantic.action.standard.set_working_target,
    semantic.action.standard.refresh,
    semantic.action.standard.revert,
    semantic.action.standard.apply,
    files.permissions_edit_action,
    files.create_file_action,
    files.create_directory_action,
};

pub fn actionCommandName(comptime verb: []const u8) []const u8 {
    return "files-act-" ++ verb;
}

/// The row under point, as the action plane.s subject.
///
/// A scene-backed view answers an action from its FOCUSED NODE; a listing that
/// is a text projection answers from the row point is on. Same action, same
/// name, same controller — only "which row" is asked differently, which is the
/// one thing that genuinely differs between a scene and a buffer.
fn subjectRow(session: *Session) ?semantic.scene.NodeId {
    _ = session;
    const key = weft.projectionAtCursor() orelse return null;
    const id = files.text_rows.idOf(key) orelse return null;
    return files.rowNodeId(id) catch null;
}

/// Run a standard action on the focused listing. `subject` is the row under
/// point when there is one — an action like `view.apply` or
/// `fs.entry.create-file` is about the VIEW and needs none.
pub fn actOnListing(self: *Plugin, name: []const u8) void {
    const session = self.focusedSession() orelse return;
    _ = session.invoke(.{
        .action = name,
        .view = session.view_ref,
        // A view-scoped verb (`view.apply`, a create) has no row; the view.s
        // own root node stands for "this listing", the same node the scene
        // handed such an action.
        .subject = subjectRow(session) orelse files.rootNodeId(),
    }) catch {};
}

/// The session whose listing is focused, if any.
fn focusedSession(self: *Plugin) ?*Session {
    var buf: [64]u8 = undefined;
    const active = weft.activeBufferName(&buf) orelse return null;
    for (self.sessions.items) |session| {
        if (std.mem.eql(u8, session.bufferName(), active)) return session;
    }
    return null;
}

/// Return on a row: open what it names, through the ordinary provider-aware
/// `open`. A directory comes back as another listing (this same handler); a
/// file comes back as an editor entry. Neither outcome is decided here.
pub fn enterRow(self: *Plugin) void {
    const session = self.focusedSession() orelse return;
    const key = weft.projectionAtCursor() orelse return;
    const id = files.text_rows.idOf(key) orelse return;
    const name = for (session.draft.rows.items) |row| {
        if (row.id == id) break row.draft.name;
    } else return;
    var joined: [1024]u8 = undefined;
    const path = std.fmt.bufPrint(&joined, "{s}/{s}", .{ session.path(), name }) catch return;
    setOpeningPath(path);
    weft.runStr("open", path);
}

/// `-`: the directory containing this one, opened the same way.
pub fn stepOut(self: *Plugin) void {
    const session = self.focusedSession() orelse return;
    const here = session.path();
    const cut = std.mem.lastIndexOfScalar(u8, here, '/') orelse return;
    const up = if (cut == 0) "/" else here[0..cut];
    setOpeningPath(up);
    weft.runStr("open", up);
}


/// `save` in a listing: apply what was typed.
pub fn applyFocused(self: *Plugin) void {
    const session = self.focusedSession() orelse return;
    _ = session.applyEdits() catch {
        weft.echo("files: could not apply");
    };
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

/// The absolute path the next listing is FOR, when a descend knows it.
///
/// A child target.s `display_name` is a bare entry name — its publisher is the
/// row-target machinery, not the directory opener — so a session reached by
/// descending cannot recover where it is from the descriptor. The descend knows
/// (it built the path to `open`), so it says.
var opening_path: [1024]u8 = undefined;
var opening_len: usize = 0;

fn setOpeningPath(p: []const u8) void {
    opening_len = @min(p.len, opening_path.len);
    @memcpy(opening_path[0..opening_len], p[0..opening_len]);
}

/// The session whose listing the next `files-show` is for. Set immediately
/// before the nested `weft.run` that consumes it, and cleared by it.
///
/// A nested `wl_run` IS a dispatching entry for its duration, which is the only
/// way a target handler — invocable from a background entry — may touch head
/// state at all (creating a buffer, declaring its posture). The same door git
/// defers its drop notices through.
var pending_show: ?*Session = null;

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

    /// The instanced buffer this listing projects into (`*files*`, `*files:2*`).
    ///
    /// A listing is a BUFFER, and that is the whole of what makes a sidebar
    /// trivial: a viewport presents a resource by running `open` and putting
    /// the resulting buffer in the pane, so a listing that is a buffer docks
    /// with no sidebar-specific code anywhere.
    buf_name: [64]u8 = undefined,
    buf_len: usize = 0,
    /// This listing.s directory, as the publisher named it. Kept so a row can
    /// be opened by the ordinary `open` — the same door the grammar.s Return
    /// reaches, so descending into a directory and opening a file are one path.
    path_buf: [1024]u8 = undefined,
    path_len: usize = 0,

    pub fn path(self: *const Session) []const u8 {
        return self.path_buf[0..self.path_len];
    }

    pub fn bufferName(self: *const Session) []const u8 {
        return self.buf_name[0..self.buf_len];
    }

    /// Take this listing's own instanced buffer, once — and give focus BACK.
    /// Creating a buffer focuses it, and a listing that steals focus whenever
    /// its model moves would yank the user out of whatever they were doing on
    /// every background refresh.
    /// Take this listing.s buffer and SHOW it. Called only from the display
    /// path (`targetOpen`), never from a refresh: creating a buffer and
    /// declaring its posture are head state, which a background delivery may
    /// not touch — and a listing resolved to answer "which project is this
    /// file in" must not materialise a buffer nobody asked to see.
    pub fn showBuffer(self: *Session) void {
        if (self.buf_len == 0) {
            var n: u32 = 1;
            while (n < 64) : (n += 1) {
                var buf: [64]u8 = undefined;
                const candidate = weft.instanceName("files", n, &buf) orelse return;
                if (weft.bufferNamed(candidate)) continue;
                self.buf_len = @min(candidate.len, self.buf_name.len);
                @memcpy(self.buf_name[0..self.buf_len], candidate[0..self.buf_len]);
                break;
            }
        }
        if (self.buf_len == 0) return;
        if (!weft.bufferNamed(self.bufferName())) {
            weft.runStr("buffer-create", self.bufferName());
            weft.toolBacking("files");
            // HOW it rests, not WHICH MODE. A listing is rows you navigate, so
            // it rests `structural`; the GRAMMAR says what that means in its
            // own vocabulary. The browser owns no keymap — the property the
            // scene plane had, kept.
            weft.declarePosture(.structural);
        } else _ = weft.focusBuffer(self.bufferName());
        self.publishRows(&self.draft);
    }

    /// The draft as a TEXT PROJECTION — the same rows the scene shows, in the
    /// form a viewport can hold. Every row is EDITABLE: a rename is typing on
    /// its line, and `applyEdits` reads them back BY KEY.
    /// Republish into the listing buffer IF it exists. A refresh never creates
    /// one: a model that moved while nobody was looking has nothing to show.
    fn publishRows(self: *Session, staged: *const files.Model) void {
        const name = self.bufferName();
        if (name.len == 0 or !weft.bufferNamed(name)) return;
        const b = weft.project(name) orelse return;
        for (staged.rows.items) |row| {
            if (files.text_rows.hidden(staged.rows.items, row)) continue;
            var key_buf: [24]u8 = undefined;
            var text_buf: [1024]u8 = undefined;
            const line = files.text_rows.lineOf(staged.rows.items, row, &text_buf) orelse continue;
            const node = b.add(.{
                .key = files.text_rows.keyOf(row.id, &key_buf),
                .role = files.text_rows.roleOf(row),
                .text = line.text,
                .foldable = row.draft.kind == .directory,
                .focusable = true,
                // Only the NAME is the user.s to change: the indent and the
                // glyph are structure, and a keystroke on them is not a rename.
                .editable = .{ .start = line.name_at, .end = line.nameEnd() },
            }) orelse continue;
            b.span(node, line.name_at, line.nameEnd(), files.text_rows.role_name);
        }
        _ = b.commit();
    }

    /// What the user typed IS the rename. Each row comes back under the KEY it
    /// was published with, so what it says NOW is compared against the draft's
    /// own name for that row — nothing positional, so an edit that shifted
    /// every line below it changes nothing about which row is which.
    ///
    /// The rename lands as a typed FS PLAN like any other draft change, so a
    /// rename typed here and one made through an action are the same operation
    /// reaching the filesystem by the same route.
    pub fn applyEdits(self: *Session) !bool {
        var rows: [512]weft.ProjectionRow = undefined;
        const live = weft.projectionRows(&rows);
        var changed = false;
        for (live) |r| {
            const id = files.text_rows.idOf(r.key) orelse continue;
            const now = files.text_rows.nameIn(r.text);
            if (now.len == 0) continue; // a blanked row is not a rename
            const found = for (self.draft.rows.items) |row| {
                if (row.id == id) break row;
            } else continue;
            if (std.mem.eql(u8, now, found.draft.name)) continue;
            // Its DISPLAYED name is not its real one (raw bytes shown as
            // U+FFFD), so what was typed cannot be turned back into a name.
            // Refused out loud rather than renamed to the replacement.
            if (!files.text_rows.renamable(found)) {
                weft.echo("files: this name is not text — rename it another way");
                continue;
            }
            try self.draft.rename(id, now);
            changed = true;
        }
        if (!changed) return false;
        return self.applyConfirmed();
    }

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
        if (opening_len > 0) {
            self.path_len = @min(opening_len, self.path_buf.len);
            @memcpy(self.path_buf[0..self.path_len], opening_path[0..self.path_len]);
            opening_len = 0;
        } else {
            var described = weft.semanticTargetDescribe(self.target, self.plugin.gpa) catch {
                return error.StaleTarget;
            };
            defer described.deinit();
            const name = described.value.display_name;
            self.path_len = @min(name.len, self.path_buf.len);
            @memcpy(self.path_buf[0..self.path_len], name[0..self.path_len]);
        }
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
        if (std.mem.eql(u8, request.action, semantic.action.standard.toggle_expanded)) {
            const row = files.modelRowId(request.subject) catch return .declined;
            try self.toggleExpanded(row);
            return .handled;
        }
        if (std.mem.eql(u8, request.action, semantic.action.standard.set_working_target)) {
            if (request.subject == files.rootNodeId()) return .{ .set_working_target = .{
                .target = self.target,
                .revision = self.target_revision,
            } };
            const row = files.modelRowId(request.subject) catch return .declined;
            const target = self.rowTarget(row) orelse return .declined;
            return .{ .set_working_target = target };
        }
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

        var staged = try self.draft.duplicate();
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

    /// Fold a directory row open or closed. Collapsing keeps its rows in the
    /// draft; opening re-reads the provider, so a fold is never a stale
    /// replay of what the directory held last time.
    fn toggleExpanded(self: *Session, row: files.NodeId) !void {
        var staged = try self.draft.duplicate();
        defer staged.deinit();
        const current = staged.row(row) orelse return error.UnknownSubject;
        if (current.expanded)
            try staged.setExpanded(row, false)
        else
            try self.readChildren(&staged, row);
        try self.publishDraft(&staged);
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
        // In the LISTING, the same thing: point lands on the new row with its
        // placeholder SELECTED, so the next keystroke replaces `new-file`
        // rather than appending to it. The selection is over the row.s own
        // text, which is the only kind of position a producer may name.
        self.selectRowName(row);
        return files.nameNodeId(row);
    }

    /// Put point on `id`.s row and select its NAME.
    fn selectRowName(self: *Session, id: files.NodeId) void {
        const name = self.bufferName();
        if (name.len == 0 or !weft.bufferNamed(name)) return;
        const view = self.draft;
        for (view.rows.items, 0..) |r, ordinal| {
            if (r.id != id) continue;
            var buf: [1024]u8 = undefined;
            const line = files.text_rows.lineOf(view.rows.items, r, &buf) orelse return;
            weft.projectionSelect(@intCast(ordinal), line.name_at, line.nameEnd());
            return;
        }
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
                .{ .input = "enter", .action = semantic.action.standard.confirm },
                .{ .input = "escape", .action = semantic.action.standard.cancel },
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

    fn materializeCapture(self: *Session, captured: *semantic.transfer.OwnedItem) !void {
        if (captured.value.intent != .copy or self.capabilities.durable_lease == null) return;
        const representation = captured.value.representation(files.entry_media_type) orelse return;
        const schema = representation.schema orelse return error.InvalidTransfer;
        const decoded = try files.decodeEntryTransferWithAttachment(
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
        const payload = try files.encodeEntryTransfer(self.plugin.gpa, .{ .lease = capture.source }, decoded.kind, decoded.mode);
        defer self.plugin.gpa.free(payload);
        const representations = try self.plugin.gpa.alloc(semantic.transfer.Representation, captured.value.representations.len);
        defer self.plugin.gpa.free(representations);
        var replaced = false;
        for (captured.value.representations, representations) |source, *destination| {
            destination.* = source;
            if (!std.mem.eql(u8, source.media_type, files.entry_media_type)) continue;
            destination.schema = files.entry_schema_current;
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
        self.publishRows(staged);

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

/// `files-show`: display the listing whose session was just opened.
///
/// It exists to BE a dispatching entry. A target handler may be invoked from a
/// background delivery, and creating a buffer or declaring its posture is head
/// state — so the open hands the work to this command through a nested
/// `weft.run` rather than doing it where it may not.
pub fn showPending() void {
    const session = pending_show orelse return;
    pending_show = null;
    session.showBuffer();
}
