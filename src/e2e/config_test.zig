//! e2e test file — drives the shared harness (harness.zig) as a user and
//! observes the surface + disk. The alias block pulls what these tests need from
//! the one harness module; unused aliases are harmless at container scope.

const std = @import("std");
const t = std.testing;
const h = @import("harness.zig");

const core = h.core;
const session = h.session;
const region = h.region;
const window_layout = h.window_layout;
const harness = h.gfx_harness;
const app_providers = h.app_providers;
const app_session = h.app_session;
const app_collab = h.app_collab;
const semantic = h.semantic_model;
const view_runtime = h.view_runtime;
const target_runtime = h.target_runtime;

const Editor = h.Editor;
const Loopback = h.Loopback;
const Project = h.Project;
const ConfigLoader = h.ConfigLoader;
const app_w = h.app_w;

const loadVim = h.loadVim;
const loadWorkspace = h.loadWorkspace;
const loadWebIde = h.loadWebIde;
const bootConfig = h.bootConfig;
const bootConfigNamed = h.bootConfigNamed;
const whichKeyText = h.whichKeyText;
const whichKeyShows = h.whichKeyShows;
const authorFile = h.authorFile;
const toolText = h.toolText;
const drainToolContains = h.drainToolContains;
const drainUntilOracle = h.drainUntilOracle;
const tmpPath = h.tmpPath;
const socketPair = h.socketPair;
const napUs = h.napUs;

fn collectSceneActions(
    gpa: std.mem.Allocator,
    node: semantic.scene.Node,
    actions: *std.ArrayList([]const u8),
) std.mem.Allocator.Error!void {
    for (node.actions) |candidate| {
        var seen = false;
        for (actions.items) |existing| {
            if (std.mem.eql(u8, existing, candidate.id)) {
                seen = true;
                break;
            }
        }
        if (!seen) try actions.append(gpa, candidate.id);
    }
    switch (node.content) {
        .container => |container| for (container.children) |child|
            try collectSceneActions(gpa, child, actions),
        else => {},
    }
}

/// The standard intention a scene action is published under by the view
/// adapter (`core/view_offers.zig` over `view_runtime/offers.zig`), or null
/// when the vocabulary does not name it yet and config must still bind the
/// action name itself.
fn intentionFor(action: []const u8) ?[]const u8 {
    const standard = semantic.action.standard;
    const table = [_]struct { action: []const u8, intention: []const u8 }{
        .{ .action = standard.open, .intention = "std.target.activate" },
        .{ .action = standard.open_container, .intention = "std.hierarchy.step-out" },
        .{ .action = standard.toggle_expanded, .intention = "std.hierarchy.toggle-expanded" },
        .{ .action = standard.copy, .intention = "std.transfer.yank" },
        .{ .action = standard.cut, .intention = "std.transfer.delete-to-register" },
        .{ .action = standard.paste_after, .intention = "std.transfer.paste" },
    };
    for (table) |row| {
        if (std.mem.eql(u8, row.action, action)) return row.intention;
    }
    return null;
}

fn sceneNodeWithRole(node: semantic.scene.Node, role: []const u8) ?semantic.scene.Node {
    if (std.mem.eql(u8, node.role, role)) return node;
    return switch (node.content) {
        .container => |container| for (container.children) |child| {
            if (sceneNodeWithRole(child, role)) |found| break found;
        } else null,
        else => null,
    };
}

fn sceneNodeWithFact(node: semantic.scene.Node, role: []const u8, name: []const u8, value: []const u8) ?semantic.scene.Node {
    if (std.mem.eql(u8, node.role, role)) {
        for (node.facts) |fact| {
            if (std.mem.eql(u8, fact.name, name) and std.mem.eql(u8, fact.value, value)) return node;
        }
    }
    return switch (node.content) {
        .container => |container| for (container.children) |child| {
            if (sceneNodeWithFact(child, role, name, value)) |found| break found;
        } else null,
        else => null,
    };
}
const ConfigField = struct {
    snapshot_calls: usize = 0,
    edits: usize = 0,

    pub fn snapshot(self: *ConfigField, gpa: std.mem.Allocator) view_runtime.field.Error!view_runtime.field.OwnedSnapshot {
        self.snapshot_calls += 1;
        var owned = view_runtime.field.OwnedSnapshot.init(gpa);
        errdefer owned.deinit();
        const arena = owned.allocator();
        owned.value = .{
            .revision = try arena.dupe(u8, "1"),
            .bytes = try arena.dupe(u8, "name"),
            .selection = .{ .anchor = 0, .caret = 4 },
            .single_line = true,
        };
        return owned;
    }

    pub fn edit(self: *ConfigField, _: []const u8, _: view_runtime.field.Edit) view_runtime.field.Error!void {
        self.edits += 1;
    }
};

const ConfigActions = struct {
    view: semantic.view.Ref = undefined,
    permission_target: semantic.scene.NodeId = @enumFromInt(0),
    edit_requests: usize = 0,
    copies: usize = 0,
    cuts: usize = 0,
    deletes: usize = 0,
    paste_before: usize = 0,
    paste_after: usize = 0,
    refreshes: usize = 0,
    reverts: usize = 0,
    applies: usize = 0,
    confirms: usize = 0,
    plugin_actions: usize = 0,
    permission_edits: usize = 0,
    file_creates: usize = 0,
    directory_creates: usize = 0,
    container_opens: usize = 0,
    workspace_cds: usize = 0,
    relation_source: semantic.target.Located = undefined,

    pub fn invoke(self: *ConfigActions, request: semantic.action.Request) view_runtime.action.ProviderError!semantic.action.Outcome {
        const action = request.action;
        if (std.mem.eql(u8, action, "fixture.plugin-action")) {
            self.plugin_actions += 1;
            return .handled;
        }
        if (std.mem.eql(u8, action, "fs.permissions.edit")) {
            self.permission_edits += 1;
            return .{ .focus = self.permission_target };
        }
        if (std.mem.eql(u8, action, semantic.action.standard.open_container)) {
            self.container_opens += 1;
            return .{ .open_relation = .{ .source = self.relation_source, .name = "container" } };
        }
        if (std.mem.eql(u8, action, semantic.action.standard.set_working_target)) {
            self.workspace_cds += 1;
            return .handled;
        }
        if (std.mem.eql(u8, action, "fs.entry.create-file")) {
            self.file_creates += 1;
            return .handled;
        }
        if (std.mem.eql(u8, action, "fs.entry.create-directory")) {
            self.directory_creates += 1;
            return .handled;
        }
        if (std.mem.eql(u8, action, semantic.action.standard.edit)) {
            self.edit_requests += 1;
            return .declined; // generic field endpoint remains the fallback
        }
        if (std.mem.eql(u8, action, semantic.action.standard.copy) or
            std.mem.eql(u8, action, semantic.action.standard.cut))
        {
            const is_cut = std.mem.eql(u8, action, semantic.action.standard.cut);
            if (is_cut) self.cuts += 1 else self.copies += 1;
            return .{ .transfer = .{
                .intent = if (is_cut) .cut else .copy,
                .suggested_name = "captured",
                .representations = &.{.{ .media_type = "application/x-weft-config-fixture", .payload = "value" }},
            } };
        }
        if (std.mem.eql(u8, action, semantic.action.standard.paste_before) or
            std.mem.eql(u8, action, semantic.action.standard.paste_after))
        {
            if (request.transfer == null) return error.Failed;
            if (std.mem.eql(u8, action, semantic.action.standard.paste_before))
                self.paste_before += 1
            else
                self.paste_after += 1;
            return .handled;
        }
        if (std.mem.eql(u8, action, semantic.action.standard.delete)) {
            self.deletes += 1;
            return .handled;
        }
        if (std.mem.eql(u8, action, semantic.action.standard.refresh)) {
            self.refreshes += 1;
            return .handled;
        }
        if (std.mem.eql(u8, action, semantic.action.standard.revert)) {
            self.reverts += 1;
            return .handled;
        }
        if (std.mem.eql(u8, action, semantic.action.standard.apply)) {
            self.applies += 1;
            return .{ .interaction = .{
                .role = .dialog,
                .view = self.view,
                .root = @enumFromInt(1),
                .actions = &.{
                    .{ .id = semantic.action.standard.confirm, .label = "Apply", .disposition = .close_on_handled },
                    .{ .id = semantic.action.standard.cancel, .label = "Cancel", .disposition = .close_on_handled },
                },
                .bindings = &.{
                    .{ .input = "y", .action = semantic.action.standard.confirm },
                    .{ .input = "n", .action = semantic.action.standard.cancel },
                },
                .presentation = "config-fixture",
            } };
        }
        if (std.mem.eql(u8, action, semantic.action.standard.confirm)) {
            self.confirms += 1;
            return .handled;
        }
        if (std.mem.eql(u8, action, semantic.action.standard.cancel)) return .handled;
        return .declined;
    }
};

const ConfigTargetHandler = struct {
    view: semantic.view.Ref,
    opens: usize = 0,

    pub fn probe(_: *ConfigTargetHandler, _: semantic.target.Descriptor) target_runtime.resolver.ProbeError!?target_runtime.resolver.Strength {
        return .exact;
    }

    pub fn open(self: *ConfigTargetHandler, _: semantic.target.Located) target_runtime.resolver.OpenError!semantic.view.Ref {
        self.opens += 1;
        return self.view;
    }
};

const ConfigRelationProvider = struct {
    source: semantic.target.Located,
    destination: semantic.target.Located,
    queries: usize = 0,

    pub fn query(self: *ConfigRelationProvider, request: target_runtime.relation.Query) target_runtime.relation.QueryError!?target_runtime.relation.Relation {
        if (!std.mem.eql(u8, request.name, "container")) return null;
        if (!request.source.target.eql(self.source.target) or request.source.revision != self.source.revision)
            return null;
        self.queries += 1;
        return .{ .name = request.name, .target = self.destination };
    }
};

// ── Driving the REAL config as a user (chords + which-key) ──────────
//
// Everything above hand-wired a plugin set; this boots the actual sample
// config.js and drives it the way a person does — through the SPC leader tree,
// discovering keys via which-key. The value is what this SURFACES: plugins the
// config references that don't load, keys that are bound weird, motions that
// don't do what a vim user expects.
test "e2e/config: the sample config boots; SPC g i is discoverable via which-key" {
    const gpa = t.allocator;
    var proj: Project = undefined;
    try proj.init(gpa);
    defer proj.deinit();

    var ed: Editor = undefined;
    try Editor.init(gpa, &ed);
    defer ed.deinit();

    // Boot the REAL config/config.js (read from the repo, which the Project
    // captured as prev_cwd before chdir'ing into the tmp project).
    const config_dir = try std.fmt.allocPrint(gpa, "{s}/config", .{proj.prev_cwd});
    defer gpa.free(config_dir);
    var loader_state: ConfigLoader = .{ .ed = &ed };
    defer loader_state.deinit();
    try bootConfig(&ed, config_dir, &loader_state);

    // A plugin-owned action is deliberately not part of core's standard
    // vocabulary. The config API declares its focused-view trampoline from
    // data, then the retained fixture below advertises and handles it.
    try core.quickjs.evalConfig(&ed.engine, ed.ctx, null, &ed.config_kv, null, "weft.semanticAction('fixture.plugin-action'); weft.bind('normal', 'SPC v z', 'fixture.plugin-action');");
    try t.expect(ed.commands.resolve("fixture.plugin-action") != null);

    // Any plugin the sample config asked for but we couldn't load is a FINDING
    // — named on failure (only then, so a clean boot leaves stderr untouched).
    if (loader_state.missing.items.len > 0) {
        for (loader_state.missing.items) |nm| std.debug.print("[e2e/config] not in catalog: {s}\n", .{nm});
    }
    if (loader_state.failed.items.len > 0) {
        for (loader_state.failed.items) |nm| std.debug.print("[e2e/config] failed to load: {s}\n", .{nm});
    }
    try t.expect(loader_state.missing.items.len == 0);
    try t.expect(loader_state.failed.items.len == 0);

    // The config ran to completion (its last line echoes this).
    try t.expect(std.mem.indexOf(u8, ed.echoText(), "config.js loaded") != null);

    // Every open structured-view action exposed by the sample configuration
    // is a real semantic command, not merely an unvalidated keymap string.
    // This keeps the config surface honest for any plugin-owned scene: a
    // provider can advertise the same protocol without adding a core command
    // or a tool-specific dispatch branch.
    // Only the RESIDUE: operations no standard intention names yet. The rest
    // of the group now binds its intention directly (asserted below), so its
    // trampoline commands are gone — doc §19's "semantic-action-to-string-
    // command trampolines", shrinking as the vocabulary grows.
    const structured_view_actions = [_][]const u8{
        semantic.action.standard.set_working_target,
        semantic.action.standard.edit,
        semantic.action.standard.delete,
        "fs.permissions.edit",
        "fs.entry.create-file",
        "fs.entry.create-directory",
        semantic.action.standard.paste_before,
        semantic.action.standard.refresh,
        semantic.action.standard.revert,
        semantic.action.standard.apply,
    };
    for (structured_view_actions) |action_name| {
        try t.expect(ed.commands.resolve(action_name) != null);
    }

    // A user who forgets the git keys reaches for the leader and READS the
    // which-key overlay — so we assert on what the which_key plugin actually
    // renders to the surface, not on the keymap the harness could introspect.
    ed.press("SPC", "");
    try t.expectEqualStrings("space", ed.head.pending); // the chord is pending
    {
        const top = try whichKeyText(&ed, gpa);
        defer gpa.free(top);
        try t.expect(top.len > 0); // the overlay drew hints
        try t.expect(std.mem.indexOf(u8, top, "g") != null); // the git group key is shown
    }
    ed.press("g", ""); // drill into the git group
    try t.expectEqualStrings("space g", ed.head.pending);
    // The overlay now shows the git leaves BY THEIR COMMAND NAMES — what a user
    // reads to discover the binding we added.
    try t.expect(whichKeyShows(&ed, "git-init"));
    try t.expect(whichKeyShows(&ed, "git-status"));
    ed.press("Escape", ""); // abandon the chord; nothing ran
    try t.expectEqualStrings("", ed.head.pending);

    // Structured views use the same generic semantic action commands from
    // config: no files-specific keymap or dispatch branch is needed. The
    // non-baseline names are visible through which-key. (The plugin
    // intentionally filters ordinary cursor movement from its hints.)
    ed.press("SPC", "");
    ed.press("v", "");
    try t.expectEqualStrings("space v", ed.head.pending);
    try t.expect(whichKeyShows(&ed, semantic.action.standard.edit));
    try t.expect(whichKeyShows(&ed, "transfer.yank"));
    try t.expect(whichKeyShows(&ed, "transfer.delete-to-register"));
    try t.expect(whichKeyShows(&ed, semantic.action.standard.delete));
    try t.expect(whichKeyShows(&ed, semantic.action.standard.paste_before));
    // The intention-bound half of the group reads as its intention: the hint
    // names what is meant, and the focused view says who answers it.
    try t.expect(whichKeyShows(&ed, "transfer.paste"));
    try t.expect(whichKeyShows(&ed, "target.activate"));
    try t.expect(whichKeyShows(&ed, "hierarchy.step-out"));
    try t.expect(whichKeyShows(&ed, "hierarchy.toggle-expanded"));
    try t.expect(whichKeyShows(&ed, semantic.action.standard.set_working_target));
    try t.expect(whichKeyShows(&ed, semantic.action.standard.refresh));
    try t.expect(whichKeyShows(&ed, semantic.action.standard.revert));
    try t.expect(whichKeyShows(&ed, semantic.action.standard.apply));
    try t.expect(whichKeyShows(&ed, "fs.permissions.edit"));
    try t.expect(whichKeyShows(&ed, "fs.entry.create-file"));
    try t.expect(whichKeyShows(&ed, "fs.entry.create-directory"));
    // The fixture action is appended after the sample config's generic view
    // actions, so this assertion necessarily traverses which-key page 2.
    try t.expect(whichKeyShows(&ed, "fixture.plugin-action"));
    ed.press("Escape", "");

    // Assert the complete config surface directly, including the cursor
    // commands which which-key classifies as noise. This is the public
    // integration contract: config can name every intent as an ordinary
    // command, while the focused scene/provider decides whether to handle it.
    const structured_view_bindings = [_]struct { sequence: []const u8, command: []const u8 }{
        .{ .sequence = "space v j", .command = "cursor-down" },
        .{ .sequence = "space v k", .command = "cursor-up" },
        .{ .sequence = "space v c", .command = semantic.action.standard.set_working_target },
        .{ .sequence = "space v e", .command = semantic.action.standard.edit },
        .{ .sequence = "space v d", .command = semantic.action.standard.delete },
        .{ .sequence = "space v m", .command = "fs.permissions.edit" },
        .{ .sequence = "space v n", .command = "fs.entry.create-file" },
        .{ .sequence = "space v N", .command = "fs.entry.create-directory" },
        .{ .sequence = "space v P", .command = semantic.action.standard.paste_before },
        .{ .sequence = "space v r", .command = semantic.action.standard.refresh },
        .{ .sequence = "space v R", .command = semantic.action.standard.revert },
        .{ .sequence = "space v a", .command = semantic.action.standard.apply },
    };
    for (structured_view_bindings) |binding| {
        try t.expectEqualStrings(binding.command, ed.keymap.resolveExact("normal", binding.sequence).?);
    }

    // The migrated half of the group: the key IS the intention. No command by
    // that action name exists any more — the focused view's own vocabulary
    // publishes the offer that answers it.
    const intention_bindings = [_]struct { sequence: []const u8, intention: []const u8 }{
        .{ .sequence = "space v o", .intention = "std.target.activate" },
        .{ .sequence = "space v minus", .intention = "std.hierarchy.step-out" },
        .{ .sequence = "space v Tab", .intention = "std.hierarchy.toggle-expanded" },
        .{ .sequence = "space v y", .intention = "std.transfer.yank" },
        .{ .sequence = "space v x", .intention = "std.transfer.delete-to-register" },
        .{ .sequence = "space v p", .intention = "std.transfer.paste" },
    };
    for (intention_bindings) |binding| {
        const arms = ed.keymap.resolveExactArms("normal", binding.sequence).?;
        try t.expectEqual(@as(usize, 1), arms.len);
        try t.expectEqualStrings(binding.intention, arms[0]);
    }
    try t.expect(ed.commands.resolve(semantic.action.standard.open) == null);
    try t.expect(ed.commands.resolve(semantic.action.standard.copy) == null);

    // Seed both capability-varying row kinds so the real files scene has
    // concrete rows whose advertised target/actions can be checked below.
    // This remains a test-only observation of the plugin protocol; config and
    // core do not inspect files roles or dispatch files commands.
    _ = try proj.oracle("printf x > plain-file; mkdir -- child-directory");

    // The sample's ordinary file-group binding reaches the shipped launcher,
    // which delegates to generic target opening. Its observable result is a
    // retained semantic scene attached to an ordinary tool buffer, without a
    // file-browser-owned keymap mode.
    ed.chord("SPC f d");
    const configured_directory_view = ed.head.semantic_focus.path().?.view;
    try t.expectEqualStrings(
        "files",
        ed.session.system.semantic.views.get(configured_directory_view).?.scene.role,
    );
    try t.expect(std.mem.startsWith(u8, ed.buffers.active().name, "files: "));

    // The alternate open binding is the same ordinary launcher contract. It
    // must reuse the retained semantic target/view rather than introducing a
    // second tool-specific surface for the same directory.
    ed.chord("SPC o d");
    try t.expectEqual(configured_directory_view, ed.head.semantic_focus.path().?.view);
    try t.expect(std.mem.startsWith(u8, ed.buffers.active().name, "files: "));

    // The config surface must cover the actions the REAL directory scene
    // advertises, not merely a hand-built generic fixture. This is deliberately
    // a protocol-level gate: the scene owns action meaning, while config owns
    // command declarations and key policy. Adding an action to files without
    // making it reachable from config is therefore an immediate test failure.
    const files_scene = ed.session.system.semantic.views.get(configured_directory_view).?.scene;

    // First walk the actual scene and reject any newly advertised action that
    // lacks a config binding. This catches additions as well as removals; the
    // shared table above also makes the required public contract readable.
    var advertised_actions: std.ArrayList([]const u8) = .empty;
    defer advertised_actions.deinit(gpa);
    try collectSceneActions(gpa, files_scene, &advertised_actions);
    for (advertised_actions.items) |action| {
        // Reachable EITHER as its own command name, or — where the view
        // adapter publishes the action under a standard intention — through
        // the key that binds that intention. Both are config surface; only
        // the second needs no trampoline command to exist.
        if (intentionFor(action)) |intention| {
            var sequence: ?[]const u8 = null;
            for (intention_bindings) |binding| {
                if (std.mem.eql(u8, binding.intention, intention)) {
                    sequence = binding.sequence;
                    break;
                }
            }
            try t.expect(sequence != null);
            try t.expect(ed.commands.resolve(action) == null); // no trampoline left
            try t.expectEqualStrings(intention, ed.keymap.resolveExact("normal", sequence.?).?);
            continue;
        }
        var sequence: ?[]const u8 = null;
        for (structured_view_bindings) |binding| {
            if (std.mem.eql(u8, binding.command, action)) {
                sequence = binding.sequence;
                break;
            }
        }
        try t.expect(sequence != null);
        try t.expect(ed.commands.resolve(action) != null);
        try t.expectEqualStrings(action, ed.keymap.resolveExact("normal", sequence.?).?);
    }

    // Required actions are checked independently so an accidental removal
    // from the scene cannot make the dynamic walk vacuously pass.
    for (structured_view_bindings) |binding| {
        if (std.mem.eql(u8, binding.command, "cursor-down") or std.mem.eql(u8, binding.command, "cursor-up")) continue;
        var found = false;
        for (advertised_actions.items) |action| {
            if (std.mem.eql(u8, action, binding.command)) {
                found = true;
                break;
            }
        }
        try t.expect(found);
        try t.expect(ed.commands.resolve(binding.command) != null);
        try t.expectEqualStrings(binding.command, ed.keymap.resolveExact("normal", binding.sequence).?);
    }
    // Same check for the intention half: each bound intention must still be
    // one the real scene advertises an action for, or the key means nothing.
    for (intention_bindings) |binding| {
        var found = false;
        for (advertised_actions.items) |action| {
            const intention = intentionFor(action) orelse continue;
            if (std.mem.eql(u8, intention, binding.intention)) {
                found = true;
                break;
            }
        }
        try t.expect(found);
    }
    try t.expect(sceneNodeWithFact(files_scene, "files.row", "kind", "regular") != null);
    const directory_row = sceneNodeWithFact(files_scene, "files.row", "kind", "directory") orelse return error.MissingDirectoryRow;
    try t.expectEqualStrings("cursor-down", ed.keymap.resolveExact("normal", "space v j").?);
    try t.expectEqualStrings("cursor-up", ed.keymap.resolveExact("normal", "space v k").?);
    // Return/minus are generic Vim input policy, not files bindings. Keep the
    // two gates adjacent so config coverage includes the ordinary navigation
    // path into and out of a focused semantic target. Return leads with the
    // standard activation intention and keeps vim's `+` as its fallback
    // (architecture §10.2) — the list, in order, is the binding.
    const activate = ed.keymap.resolveExactArms("normal", "Return").?;
    try t.expectEqual(@as(usize, 2), activate.len);
    try t.expectEqualStrings("std.target.activate", activate[0]);
    try t.expectEqualStrings("vim-open-focused", activate[1]);
    const step_out = ed.keymap.resolveExactArms("normal", "minus").?;
    try t.expectEqual(@as(usize, 2), step_out.len);
    try t.expectEqualStrings("std.hierarchy.step-out", step_out[0]);
    try t.expectEqualStrings("vim-open-container", step_out[1]);

    // Exercise that policy against the real row: Return opens the child target
    // through generic target resolution, and minus follows its generic
    // `container` relation back to this directory. No files keymap is involved.
    const files_name = sceneNodeWithRole(directory_row, "files.name") orelse return error.MissingNameField;
    _ = try ed.session.system.semantic.focusView(ed.head, gpa, configured_directory_view, files_name.id);
    ed.press("Return", "");
    const child_view = ed.head.semantic_focus.path().?.view;
    try t.expect(!child_view.eql(configured_directory_view));
    try t.expectEqualStrings("files", ed.session.system.semantic.views.get(child_view).?.scene.role);
    ed.press("minus", "");
    try t.expectEqual(configured_directory_view, ed.head.semantic_focus.path().?.view);

    // Now drive those bindings against a real retained scene. This fixture is
    // intentionally generic: it owns fields, actions, a target link, and an
    // interaction, but has no directory/file/Vim branch. The sample config is
    // therefore proving the same path any tool plugin receives.
    var field: ConfigField = .{};
    var permission_field: ConfigField = .{};
    const semantic_services = &ed.session.system.semantic;
    const owner = try semantic_services.acquireOwner();
    const field_ref = try semantic_services.insertField(gpa, owner, .init(&field));
    const permission_field_ref = try semantic_services.insertField(gpa, owner, .init(&permission_field));
    const target_ref = try semantic_services.publishTarget(gpa, owner, .{
        .kind = .{ .synthetic = "config-fixture" },
        .display_name = "config fixture target",
    });
    const relation_source_ref = try semantic_services.publishTarget(gpa, owner, .{
        .kind = .{ .synthetic = "config-source" },
        .display_name = "config fixture source",
    });
    const target_view = try semantic_services.publishView(gpa, owner, target_ref, 1, .{
        .id = @enumFromInt(100),
        .focusable = true,
        .content = .{ .label = "opened target" },
    });
    var target_handler: ConfigTargetHandler = .{ .view = target_view };
    _ = try semantic_services.registerTargetHandler(gpa, owner, "config-fixture", .init(&target_handler));
    const relation_source: semantic.target.Located = .{ .target = relation_source_ref, .revision = 1 };
    var relation_provider: ConfigRelationProvider = .{
        .source = relation_source,
        .destination = .{ .target = target_ref, .revision = 1 },
    };
    _ = try semantic_services.registerTargetRelationProvider(gpa, owner, "config-container", .init(&relation_provider));

    const field_node: semantic.scene.Node = .{
        .id = @enumFromInt(3),
        .focusable = true,
        .target = .{ .target = target_ref, .revision = 1, .location = .{ .node = "config" } },
        .content = .{ .field = .{ .ref = field_ref, .single_line = true } },
    };
    const permission_node: semantic.scene.Node = .{
        .id = @enumFromInt(5),
        // A secondary field is entered by its advertised action and does not
        // add another stop to ordinary structured-view row traversal.
        .focusable = false,
        .content = .{ .field = .{ .ref = permission_field_ref, .single_line = true } },
    };
    const row_actions = [_]semantic.scene.Action{
        .{ .id = semantic.action.standard.open },
        .{ .id = semantic.action.standard.edit },
        .{ .id = semantic.action.standard.copy },
        .{ .id = semantic.action.standard.cut },
        .{ .id = semantic.action.standard.delete },
        .{ .id = "fs.permissions.edit" },
        .{ .id = semantic.action.standard.paste_before },
        .{ .id = semantic.action.standard.paste_after },
        .{ .id = "fixture.plugin-action" },
        .{ .id = "fs.entry.create-file" },
        .{ .id = "fs.entry.create-directory" },
    };
    const first_row: semantic.scene.Node = .{
        .id = @enumFromInt(2),
        .actions = &row_actions,
        .content = .{ .container = .{ .children = &.{ field_node, permission_node } } },
    };
    const second_row: semantic.scene.Node = .{
        .id = @enumFromInt(4),
        .focusable = true,
        .content = .{ .label = "second row" },
    };
    const root_actions = [_]semantic.scene.Action{
        .{ .id = semantic.action.standard.open_container },
        .{ .id = semantic.action.standard.set_working_target },
        .{ .id = semantic.action.standard.refresh },
        .{ .id = semantic.action.standard.revert },
        .{ .id = semantic.action.standard.apply },
    };
    const fixture_view = try semantic_services.publishView(gpa, owner, relation_source_ref, 1, .{
        .id = @enumFromInt(1),
        .actions = &root_actions,
        .content = .{ .container = .{ .children = &.{ first_row, second_row } } },
    });
    var actions: ConfigActions = .{
        .view = fixture_view,
        .permission_target = permission_node.id,
        .relation_source = relation_source,
    };
    try semantic_services.registerActionProvider(gpa, owner, .init(&actions));
    _ = try semantic_services.focusView(ed.head, gpa, fixture_view, field_node.id);

    ed.chord("SPC v j");
    try t.expectEqual(second_row.id, ed.head.semantic_focus.path().?.leaf().?);
    ed.chord("SPC v k");
    try t.expectEqual(field_node.id, ed.head.semantic_focus.path().?.leaf().?);
    const snapshots_before_edit = field.snapshot_calls;
    ed.chord("SPC v e");
    try t.expectEqual(@as(usize, 1), actions.edit_requests);
    // The action provider declined, so the generic field endpoint had to
    // validate a live snapshot. Full application wakes may also snapshot the
    // focused field for rendering; the semantic contract is the new read,
    // not an obsolete assumption that dispatch happens without a frame.
    try t.expect(field.snapshot_calls > snapshots_before_edit);
    try t.expectEqualStrings("normal", ed.head.currentMode());

    ed.chord("SPC v y");
    ed.chord("SPC v p");
    ed.chord("SPC v x");
    ed.chord("SPC v P");
    ed.chord("SPC v d");
    ed.chord("SPC v c");
    ed.chord("SPC v m");
    ed.chord("SPC v n");
    ed.chord("SPC v N");
    try t.expectEqual(@as(usize, 1), actions.copies);
    try t.expectEqual(@as(usize, 1), actions.cuts);
    try t.expectEqual(@as(usize, 1), actions.paste_after);
    try t.expectEqual(@as(usize, 1), actions.paste_before);
    try t.expectEqual(@as(usize, 1), actions.deletes);
    try t.expectEqual(@as(usize, 1), actions.workspace_cds);
    try t.expectEqual(@as(usize, 1), actions.permission_edits);
    try t.expectEqual(@as(usize, 1), actions.file_creates);
    try t.expectEqual(@as(usize, 1), actions.directory_creates);
    try t.expectEqual(permission_node.id, ed.head.semantic_focus.path().?.leaf().?);

    // The next row movement is relative to the primary field from which the
    // action entered this secondary field, not the scene's first row.
    ed.chord("SPC v j");
    try t.expectEqual(second_row.id, ed.head.semantic_focus.path().?.leaf().?);
    ed.chord("SPC v k");
    try t.expectEqual(field_node.id, ed.head.semantic_focus.path().?.leaf().?);

    ed.chord("SPC v z");
    try t.expectEqual(@as(usize, 1), actions.plugin_actions);

    ed.chord("SPC v r");
    ed.chord("SPC v R");
    ed.chord("SPC v a");
    try t.expectEqual(@as(usize, 1), actions.refreshes);
    try t.expectEqual(@as(usize, 1), actions.reverts);
    try t.expectEqual(@as(usize, 1), actions.applies);
    try t.expectEqualStrings("config-fixture", ed.head.interactions.active().?.descriptor.presentation);
    // `y` is also Vim's normal-mode operator prefix. The active dialog owns
    // the input locally, while the global keymap remains untouched; this is
    // the contract that keeps confirmation out of which-key/global modes.
    try t.expectEqualStrings("enter-op-yank", ed.keymap.resolveExact("normal", "y").?);
    try t.expectEqualStrings(semantic.action.standard.confirm, ed.head.interactions.actionForInput("y").?.id);
    ed.press("y", "y");
    try t.expectEqual(@as(usize, 1), actions.confirms);
    try t.expect(ed.head.interactions.active() == null);

    // Cancellation is interaction-local too: it is not a global config/Vim
    // command and must not leak into which-key or ordinary normal-mode input.
    ed.chord("SPC v a");
    try t.expect(ed.head.interactions.active() != null);
    try t.expectEqualStrings(semantic.action.standard.cancel, ed.head.interactions.actionForInput("n").?.id);
    ed.press("n", "n");
    try t.expectEqual(@as(usize, 1), actions.confirms);
    try t.expect(ed.head.interactions.active() == null);

    ed.chord("SPC v o");
    try t.expectEqual(@as(usize, 1), target_handler.opens);
    try t.expectEqual(target_view, ed.head.semantic_focus.path().?.view);

    // The config knows only an open action name. The view provider supplies a
    // named edge, an independent relation provider resolves it, and the usual
    // target handler opens the destination.
    _ = try semantic_services.focusView(ed.head, gpa, fixture_view, field_node.id);
    ed.chord("SPC v -");
    try t.expectEqual(@as(usize, 1), actions.container_opens);
    try t.expectEqual(@as(usize, 1), relation_provider.queries);
    try t.expectEqual(@as(usize, 2), target_handler.opens);
    try t.expectEqual(target_view, ed.head.semantic_focus.path().?.view);

    // Vim's modal editing remains a generic semantic-view consumer. A field
    // enters the ordinary insert posture, and Escape returns to the buffer's
    // resting mode; no tool-specific mode or keymap is involved. The normal
    // yy/dd/paste/open-container keys then resolve through the same advertised
    // semantic actions as the config chords above.
    _ = try semantic_services.focusView(ed.head, gpa, fixture_view, field_node.id);
    ed.press("j", "");
    try t.expectEqual(second_row.id, ed.head.semantic_focus.path().?.leaf().?);
    ed.press("k", "");
    try t.expectEqual(field_node.id, ed.head.semantic_focus.path().?.leaf().?);
    ed.press("i", "");
    try t.expectEqualStrings("insert", ed.head.currentMode());
    ed.typeText("x");
    try t.expectEqual(@as(usize, 1), field.edits);
    ed.press("Escape", "");
    try t.expectEqualStrings("normal", ed.head.currentMode());
    ed.press("y", "");
    ed.press("y", "");
    ed.press("p", "");
    ed.press("d", "");
    ed.press("d", "");
    ed.press("minus", "");
    try t.expectEqual(@as(usize, 3), actions.copies);
    try t.expectEqual(@as(usize, 2), actions.paste_after);
    try t.expectEqual(@as(usize, 2), actions.deletes);
    try t.expectEqual(@as(usize, 2), actions.container_opens);
    try t.expectEqual(@as(usize, 2), relation_provider.queries);
    try t.expectEqual(@as(usize, 3), target_handler.opens);

    // SPC : must open the command PALETTE (pick-commands), not the ex line.
    // Typing `:` needs Shift, and a real keyboard sends that Shift_L press as its
    // own event BETWEEN space and colon — it must not dead-end the chord.
    ed.press("SPC", "");
    try t.expectEqualStrings("space", ed.head.pending);
    ed.press("Shift_L", ""); // the modifier for `:` — a no-op for the chord
    try t.expectEqualStrings("space", ed.head.pending); // still pending, not reset
    ed.press(":", "");
    try t.expectEqualStrings("", ed.head.pending); // the chord resolved + ran
    try t.expect(ed.pick.active); // the palette (a pick), not the ex prompt
}

test "e2e/config: SPC , keeps stable order and places the active buffer last" {
    const gpa = t.allocator;
    var proj: Project = undefined;
    try proj.init(gpa);
    defer proj.deinit();
    _ = try proj.oracle("printf alpha > alpha.txt; printf bravo > bravo.txt");

    var ed: Editor = undefined;
    try Editor.init(gpa, &ed);
    defer ed.deinit();
    const config_dir = try std.fmt.allocPrint(gpa, "{s}/config", .{proj.prev_cwd});
    defer gpa.free(config_dir);
    var loader_state: ConfigLoader = .{ .ed = &ed };
    defer loader_state.deinit();
    try bootConfig(&ed, config_dir, &loader_state);

    ed.runStr("open", "alpha.txt");
    ed.runStr("open", "bravo.txt");
    try t.expectEqualStrings("bravo.txt", ed.bufferName());

    // This is the real config binding and the real resident buffers plugin;
    // the assertion observes the picker's candidate add-order, before any
    // query ranking can obscure the ordering policy.
    ed.chord("SPC ,");
    ed.settle(2);
    try t.expectEqualStrings("pick", ed.mode());
    try t.expectEqual(@as(usize, 3), ed.pick.items.items.len);
    try t.expectEqualStrings("*scratch*", ed.pick.items.items[0]);
    try t.expectEqualStrings("alpha.txt", ed.pick.items.items[1]);
    try t.expectEqualStrings("bravo.txt", ed.pick.items.items[2]);

    // The accepted row is resolved by the plugin's recorded buffer id, not
    // by re-scanning names after active-last reordering.
    ed.typeText("alpha");
    ed.settle(2);
    ed.press("Return", "");
    try t.expectEqualStrings("alpha.txt", ed.bufferName());

    // Reopening from the other active buffer moves only that buffer to the
    // tail; the inactive candidates retain their deterministic source order.
    ed.chord("SPC ,");
    ed.settle(2);
    try t.expectEqual(@as(usize, 3), ed.pick.items.items.len);
    try t.expectEqualStrings("*scratch*", ed.pick.items.items[0]);
    try t.expectEqualStrings("bravo.txt", ed.pick.items.items[1]);
    try t.expectEqualStrings("alpha.txt", ed.pick.items.items[2]);
    ed.typeText("bravo");
    ed.settle(2);
    ed.press("Return", "");
    try t.expectEqualStrings("bravo.txt", ed.bufferName());
}

// ── M3/M4 parity: config.js vs config.northstar.js (doc/configuration.md §7) ──
//
// north-star-config.js is doc/north-star-config.js's forcing-function
// argument made real: today's editor, reproduced as a config that evaluates
// to a sealed MANIFEST (src/core/manifest.zig) instead of mutating the
// editor inline. Its only declared semantic edits vs config/config.js are
// (1) the which-key delay moving from the "editor" grab-bag to its owning
// plugin's namespace, and (2) trust-root framing in comments. This test is
// the M4 skeleton's keymap/action/value surface, asserted now: two headless
// editors, booted from the two files (same config/ dir, so both resolve
// `weft.use("defaults")` identically), must reach the same resolved keymap
// tables, the same action-provider resolutions, and the same which-key
// delay — under its NEW owner.
test "e2e/config: config.js and config.northstar.js reach the same manifest surface (M3/M4 parity)" {
    const gpa = t.allocator;
    var proj: Project = undefined;
    try proj.init(gpa);
    defer proj.deinit();
    const config_dir = try std.fmt.allocPrint(gpa, "{s}/config", .{proj.prev_cwd});
    defer gpa.free(config_dir);

    var ed_a: Editor = undefined;
    try Editor.init(gpa, &ed_a);
    defer ed_a.deinit();
    var loader_a: ConfigLoader = .{ .ed = &ed_a };
    defer loader_a.deinit();
    try bootConfigNamed(&ed_a, config_dir, "config.js", &loader_a);

    var ed_b: Editor = undefined;
    try Editor.init(gpa, &ed_b);
    defer ed_b.deinit();
    var loader_b: ConfigLoader = .{ .ed = &ed_b };
    defer loader_b.deinit();
    try bootConfigNamed(&ed_b, config_dir, "config.northstar.js", &loader_b);

    if (loader_a.missing.items.len > 0) for (loader_a.missing.items) |nm| std.debug.print("[e2e/config parity] config.js: not in catalog: {s}\n", .{nm});
    if (loader_a.failed.items.len > 0) for (loader_a.failed.items) |nm| std.debug.print("[e2e/config parity] config.js: failed to load: {s}\n", .{nm});
    if (loader_b.missing.items.len > 0) for (loader_b.missing.items) |nm| std.debug.print("[e2e/config parity] config.northstar.js: not in catalog: {s}\n", .{nm});
    if (loader_b.failed.items.len > 0) for (loader_b.failed.items) |nm| std.debug.print("[e2e/config parity] config.northstar.js: failed to load: {s}\n", .{nm});
    try t.expect(loader_a.missing.items.len == 0);
    try t.expect(loader_a.failed.items.len == 0);
    try t.expect(loader_b.missing.items.len == 0);
    try t.expect(loader_b.failed.items.len == 0);

    // Both configs ran to completion.
    try t.expect(std.mem.indexOf(u8, ed_a.echoText(), "config.js loaded") != null);
    try t.expect(std.mem.indexOf(u8, ed_b.echoText(), "config.js loaded") != null);

    // 1. Resolved keymap tables, every mode — must match exactly (owner/
    //    priority excluded: reaching the same table through a different
    //    tier IS the point, not a difference to catch).
    const km_a = try h.keymapSnapshot(gpa, ed_a.keymap);
    defer gpa.free(km_a);
    const km_b = try h.keymapSnapshot(gpa, ed_b.keymap);
    defer gpa.free(km_b);
    try t.expectEqualStrings(km_a, km_b);

    // 2. Action provider sets — resolved outcomes across the modes/langs the
    //    configs actually declare providers for (`eval`: default, zig, py —
    //    "rs" exercises the unprovided-language DEFAULT fallthrough;
    //    `format`: default only, every lang) — must match exactly, plus
    //    explicit assertions naming what each SHOULD resolve to (not just
    //    "the two configs agree with each other", but "they agree on the
    //    RIGHT thing").
    const actions = [_][]const u8{ "eval", "format" };
    const modes = [_][]const u8{ "normal", "insert" };
    const langs = [_][]const u8{ "zig", "py", "rs" };
    const act_a = try h.actionSnapshot(gpa, ed_a.ctx, &actions, &modes, &langs);
    defer gpa.free(act_a);
    const act_b = try h.actionSnapshot(gpa, ed_b.ctx, &actions, &modes, &langs);
    defer gpa.free(act_b);
    try t.expectEqualStrings(act_a, act_b);

    inline for (.{ &ed_a, &ed_b }) |ed| {
        try t.expectEqualStrings("make-build", ed.ctx.actions.resolve("eval", .{ .mode = "normal", .lang = "zig" }).?);
        try t.expectEqualStrings("lang-run", ed.ctx.actions.resolve("eval", .{ .mode = "normal", .lang = "py" }).?);
        // "rs" has no provider of its own — the unconstrained default wins.
        try t.expectEqualStrings("run-line", ed.ctx.actions.resolve("eval", .{ .mode = "normal", .lang = "rs" }).?);
        try t.expectEqualStrings("format-buffer", ed.ctx.actions.resolve("format", .{ .mode = "normal", .lang = "zig" }).?);
        try t.expectEqualStrings("format-buffer", ed.ctx.actions.resolve("format", .{ .mode = "normal", .lang = "rs" }).?);
    }

    // 3. The which-key delay value — the ONE migrated key (§8's finding:
    //    "editor" grab-bag → the owning `which_key` plugin's namespace) —
    //    staged identically by both (raw framed blobs compare equal; "200"
    //    is legible in both as a sanity check the value itself is right).
    const raw_a = ed_a.config_kv.get("which_key", "delay-ms").?;
    const raw_b = ed_b.config_kv.get("which_key", "delay-ms").?;
    try t.expectEqualStrings(raw_a, raw_b);
    try t.expect(std.mem.indexOf(u8, raw_a, "200") != null);

    // 4. Theme values — a DIFFERENT config-value namespace than which_key's,
    //    exercising the "theme" core namespace side of the ownership check.
    inline for (.{ "accent", "cursor", "selection" }) |field| {
        const va = ed_a.config_kv.get("theme", field).?;
        const vb = ed_b.config_kv.get("theme", field).?;
        try t.expectEqualStrings(va, vb);
    }

    // 5. Plugin load-LIST set-equality — every `weft.plugin(name)` request,
    //    not just "no missing/failed" (which only checks the CATALOG side);
    //    this catches a name silently dropped or renamed between the two
    //    files.
    const req_a = try h.requestedPluginsSnapshot(gpa, &loader_a);
    defer gpa.free(req_a);
    const req_b = try h.requestedPluginsSnapshot(gpa, &loader_b);
    defer gpa.free(req_b);
    try t.expectEqualStrings(req_a, req_b);
    // config.js declares 38 `weft.plugin(...)` catalog entries (edit through
    // dap.js) — pin the count so a silently truncated list still fails
    // loudly even in the (impossible, given the equality above) case both
    // sides truncated identically.
    var req_count: usize = 0;
    for (req_a) |c| if (c == '\n') {
        req_count += 1;
    };
    try t.expectEqual(@as(usize, 38), req_count);

    // 6. The FULL config-store snapshot (namespace/key/value, every entry —
    //    not a hand-picked key), so e.g. `lsp/zig` agreeing is asserted too,
    //    not just `which_key/delay-ms` and `theme/*`.
    const kv_a = try h.kvSnapshot(gpa, &ed_a.config_kv);
    defer gpa.free(kv_a);
    const kv_b = try h.kvSnapshot(gpa, &ed_b.config_kv);
    defer gpa.free(kv_b);
    try t.expectEqualStrings(kv_a, kv_b);
    try t.expect(std.mem.indexOf(u8, kv_a, "lsp") != null); // the lsp/zig=zls entry is actually present

    // 7. Menu-mode / which-key GROUP structure (isMenuMode, sticky, locked,
    //    resting, text-swallow per mode) — not just individual binds; two
    //    configs could resolve the same bind table while disagreeing on
    //    which modes are which-key GROUPS vs runnable leaves.
    const ms_a = try h.modeStructureSnapshot(gpa, ed_a.keymap);
    defer gpa.free(ms_a);
    const ms_b = try h.modeStructureSnapshot(gpa, ed_b.keymap);
    defer gpa.free(ms_b);
    try t.expectEqualStrings(ms_a, ms_b);
}

// M3 review R1 regression, at the e2e layer (unit-level regression lives in
// quickjs.zig): the DOCUMENTED ACP setup — `weft.set("acp", "cmd", …)`
// before `weft.plugin("acp.js")` — must still land its value. `acp.js` is a
// path-form `.js` name; its config-store identity is the STEM ("acp"), not
// the raw declared name, and the value-ownership check
// (doc/contextual-workspace-architecture.md §13.5) must recognize that or a
// real, pre-M3-working config setup breaks silently (M4 parity item 6).
test "e2e/config: R1 — weft.set(\"acp\", ...) before weft.plugin(\"acp.js\") is not dropped" {
    const gpa = t.allocator;
    var proj: Project = undefined;
    try proj.init(gpa);
    defer proj.deinit();

    var ed: Editor = undefined;
    try Editor.init(gpa, &ed);
    defer ed.deinit();
    var loader_state: ConfigLoader = .{ .ed = &ed };
    defer loader_state.deinit();

    const dir = ".zig-cache/tmp/e2e-r1-acp";
    const cfg_path = dir ++ "/config.js";
    try core.file.writeBytesMakingDirs(gpa, dir, cfg_path,
        \\weft.set("acp", "cmd", "codex-acp");
        \\weft.plugin("acp.js");
    );
    defer core.file.deleteFile(gpa, cfg_path);

    try bootConfigNamed(&ed, dir, "config.js", &loader_state);

    const blob = ed.config_kv.get("acp", "cmd") orelse return error.ValueWronglyDropped;
    try t.expect(std.mem.indexOf(u8, blob, "codex-acp") != null);
}

// A resident `.js` plugin has no `describe()` handshake to request perms
// with, so a config `weft.grant` is its ONLY route to an effect. This is that
// route end to end: config → manifest → the System's grant table → the
// plugin's adopted handles. Revocation of a running JS plugin is proven in
// `core/quickjs.zig`'s own gate test instead: `HandleTable.Row` BORROWS its
// principal/capability strings, and a config's manifest — which owns them
// here — dies with the load, so `revoke` by name has nothing left to match.
test "e2e/config: weft.grant is a resident .js plugin's only authority — adopted at load" {
    const gpa = t.allocator;
    var proj: Project = undefined;
    try proj.init(gpa);
    defer proj.deinit();

    var ed: Editor = undefined;
    try Editor.init(gpa, &ed);
    defer ed.deinit();
    var loader_state: ConfigLoader = .{ .ed = &ed };
    defer loader_state.deinit();

    const dir = ".zig-cache/tmp/e2e-js-grant";
    const cfg_path = dir ++ "/config.js";
    try core.file.writeBytesMakingDirs(gpa, dir, cfg_path,
        \\weft.grant("dap", "proc");
        \\weft.plugin("dap.js");
    );
    defer core.file.deleteFile(gpa, cfg_path);

    try bootConfigNamed(&ed, dir, "config.js", &loader_state);

    try t.expectEqual(@as(usize, 1), ed.js_plugins.items.len);
    const dap = ed.js_plugins.items[0];
    try t.expect(core.wasm_host.hasPerm(dap, .proc));
    // One capability is not the others — nothing else was declared.
    try t.expect(!core.wasm_host.hasPerm(dap, .fs_read));
    try t.expect(!core.wasm_host.hasPerm(dap, .fs_write));
    try t.expect(!core.wasm_host.hasPerm(dap, .net));
    try t.expect(!core.wasm_host.hasPerm(dap, .timer));
}

// ── The palette over live offers (architecture §9.3, §14.2) ───────────

/// The palette row whose matchable text is `text`, or null.
fn pickRow(ed: *Editor, text: []const u8) ?usize {
    for (ed.pick.items.items, 0..) |item, i| {
        if (std.mem.eql(u8, item, text)) return i;
    }
    return null;
}

/// Open the palette, narrow to one row, and accept it.
fn paletteAccept(ed: *Editor, text: []const u8) void {
    ed.run("pick-commands");
    ed.settle(2);
    ed.typeText(text);
    ed.settle(2);
    ed.press("Return", "");
    ed.settle(2);
}

test "e2e/config: the palette accepts a live offer through the effect door" {
    const gpa = t.allocator;
    var proj: Project = undefined;
    try proj.init(gpa);
    defer proj.deinit();
    _ = try proj.oracle("printf alpha > alpha.txt");

    var ed: Editor = undefined;
    try Editor.init(gpa, &ed);
    defer ed.deinit();
    const config_dir = try std.fmt.allocPrint(gpa, "{s}/config", .{proj.prev_cwd});
    defer gpa.free(config_dir);
    var loader_state: ConfigLoader = .{ .ed = &ed };
    defer loader_state.deinit();
    try bootConfig(&ed, config_dir, &loader_state);

    ed.runStr("open", "alpha.txt");
    ed.runStr("insert-text", "x");
    {
        const edited = try ed.textAlloc();
        defer gpa.free(edited);
        try t.expectEqualStrings("xalpha", edited);
    }

    // The offer is LISTED, beside the raw commands, attributed to its provider.
    ed.run("pick-commands");
    ed.settle(2);
    const row = pickRow(&ed, "std.history.undo") orelse return error.OfferNotListed;
    try t.expectEqualStrings("offer · core.editing", ed.pick.docs.items[row]);
    try t.expect(pickRow(&ed, "buffers") != null); // commands still there
    ed.press("Escape", "");
    ed.settle(2);

    // Accepting it undoes exactly like the bound key would.
    paletteAccept(&ed, "std.history.undo");
    {
        const undone = try ed.textAlloc();
        defer gpa.free(undone);
        try t.expectEqualStrings("alpha", undone);
    }

    // An entry that holds no text keeps the offer VISIBLE with its reason —
    // absence would mean nonapplicable, and this is relevant-but-impossible.
    const view = try ed.buffers.createView(gpa, "files: .", "files");
    try ed.buffers.switchTo(gpa, view, ed.head, ed.keymap);
    ed.run("pick-commands");
    ed.settle(2);
    const disabled = pickRow(&ed, "std.history.undo") orelse return error.OfferNotListed;
    try t.expectEqualStrings("offer · core.editing · no-text", ed.pick.docs.items[disabled]);
    ed.press("Escape", "");
    ed.settle(2);

    // Accepting it surfaces the refusal instead of silently doing nothing.
    paletteAccept(&ed, "std.history.undo");
    try t.expect(std.mem.indexOf(u8, ed.echoText(), "no-text") != null);
}
