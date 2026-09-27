//! Publish the focused view's standard offers into the catalog — the host
//! half of the generic adapter (architecture §9.2, §10.2, §14.2).
//!
//! `view_runtime/offers.zig` derives WHAT a scene affords from its shape;
//! this names those affordances in the standard vocabulary, points each at an
//! existing host route, and pushes the result as one revision-stamped table.
//! Files, files, git, and any future view therefore answer Tab, Return, the
//! motion keys, and `q` without binding a key or declaring an offer.
//!
//! Republication is a value comparison, not a callback: the head's focus, the
//! scene revision, and its back-capability are one signature, and a changed
//! signature is a new table under the same provider with a bumped revision.
//! Nothing recomputes eligibility on the keystroke path.
//!
//! The adapter publishes at the WEAKEST tier. A provider that means something
//! else by `activate` outranks it by simply saying so.

const std = @import("std");
const Allocator = std.mem.Allocator;
const model = @import("weft_semantic");
const view_runtime = @import("weft_view_runtime");
const catalog = @import("catalog.zig");
const command = @import("command.zig");
const intent = @import("intent.zig");
const intentions = @import("intentions.zig");
const semantic = @import("semantic.zig");
const Head = @import("Head.zig");
const action_here = @import("action_here.zig");

const offers = view_runtime.offers;
const standard = model.action.standard;

pub const provider_name = "core.view";

/// Deepest scene path a projection subject may synthesize. A listing is root →
/// row → column; anything deeper is a scene, which brings its own focus path.
const max_path = 32;

/// WHAT POINT IS ON, when the entry is a text projection. The head carries no
/// semantic focus for one — a listing is a buffer — so offers derived from "the
/// focused node" would be derived from nothing, and every std verb would fall
/// to whatever generic floor was left, claiming that a file row affords folding
/// and a listing affords everything. This is the same question asked of the
/// plane that IS showing.
pub const Here = struct {
    view: model.view.Ref,
    node: model.scene.NodeId,
};

/// One derived intent, the standard intention it publishes under, and the
/// existing host route that carries it. Both halves live in one table so an
/// intent can never acquire an intention without a route, or the reverse.
pub const Binding = struct {
    intent: offers.Intent,
    intention: []const u8,
    /// A registered command name — the route the input grammar's own keys
    /// already reach.
    route: []const u8,
};

pub const bindings = [_]Binding{
    .{ .intent = .toggle_expanded, .intention = "std.hierarchy.toggle-expanded", .route = "hierarchy.toggle-expanded" },
    .{ .intent = .step_out, .intention = "std.hierarchy.step-out", .route = "target.open-container" },
    .{ .intent = .activate, .intention = "std.target.activate", .route = "target.open" },
    // The same intention on an `action` node, routed to the action it names
    // (`pointer.zig`'s `activateFocusedAction`, also what a click on it runs).
    .{ .intent = .activate_action, .intention = "std.target.activate", .route = "view.run-focused-action" },
    // Transfer rides the routes the register already owns: capture, place,
    // and capture-as-a-move. The provider decides what a capture MEANS for
    // its rows; the standard word only says which half of the ferry runs.
    .{ .intent = .transfer_yank, .intention = "std.transfer.yank", .route = "selection.copy" },
    .{ .intent = .transfer_paste, .intention = "std.transfer.paste", .route = "selection.paste-after" },
    .{ .intent = .transfer_delete, .intention = "std.transfer.delete-to-register", .route = "selection.cut" },
    // ROW steps, not line steps. `cursor.row-up`/`cursor.row-down` fall through to the
    // ordinary cursor move when the entry is not a projection, so this is the
    // same route for a scene and strictly better for a listing: it lands on
    // the row's actionable part and keeps the column you were in.
    .{ .intent = .navigate_up, .intention = "std.navigation.up", .route = "cursor.row-up" },
    .{ .intent = .navigate_down, .intention = "std.navigation.down", .route = "cursor.row-down" },
    .{ .intent = .navigate_left, .intention = "std.navigation.left", .route = "cursor.left" },
    .{ .intent = .navigate_right, .intention = "std.navigation.right", .route = "cursor.right" },
    .{ .intent = .word_previous, .intention = "std.navigation.word-prev", .route = "field.word-prev" },
    .{ .intent = .word_next, .intention = "std.navigation.word-next", .route = "field.word-next" },
    .{ .intent = .word_end, .intention = "std.navigation.word-end", .route = "field.word-end" },
    .{ .intent = .WORD_previous, .intention = "std.navigation.big-word-prev", .route = "field.big-word-prev" },
    .{ .intent = .WORD_next, .intention = "std.navigation.big-word-next", .route = "field.big-word-next" },
    .{ .intent = .WORD_end, .intention = "std.navigation.big-word-end", .route = "field.big-word-end" },
    .{ .intent = .line_start, .intention = "std.navigation.line-start", .route = "field.line-start" },
    .{ .intent = .line_end, .intention = "std.navigation.line-end", .route = "field.line-end" },
    .{ .intent = .first_non_blank, .intention = "std.navigation.first-non-blank", .route = "field.first-non-blank" },
    .{ .intent = .back, .intention = "std.navigation.back", .route = "buffer.back" },
    .{ .intent = .insert_before, .intention = "std.editing.insert-before", .route = "item.insert-before" },
    .{ .intent = .insert_after, .intention = "std.editing.insert-after", .route = "item.insert-after" },
    .{ .intent = .begin_edit, .intention = "std.editing.begin", .route = "field.edit" },
    .{ .intent = .commit_edit, .intention = "std.target.activate", .route = "field.commit-edit" },
    .{ .intent = .cancel_edit, .intention = "std.gesture.cancel", .route = "field.cancel-edit" },
};

comptime {
    if (bindings.len != offers.Intent.count) @compileError("every intent needs a binding");
    for (bindings, 0..) |binding, index| {
        // Position IS the intent, so an endpoint's payload is its index here.
        if (@intFromEnum(binding.intent) != index)
            @compileError("bindings must be in Intent order: " ++ @tagName(binding.intent));
        for (intentions.std_intentions) |declared| {
            if (std.mem.eql(u8, declared.name, binding.intention)) break;
        } else @compileError("intention outside the standard vocabulary: " ++ binding.intention);
    }
}

/// Sanitized §9.3 fallback for the one reason code the derivation produces.
const disabled_message = "the focused view refuses this right now";

/// What one publication describes. Focus moves and scene replacements are
/// different clocks (§9.2); both are here, so neither can silently leave a
/// stale table published.
const Signature = struct {
    view: model.view.Ref,
    leaf: model.scene.NodeId,
    scene: u64,
    /// Whether a field is edited, and whether that edit was begun: the same
    /// leaf offers different verbs as a row, as a field, and mid-edit.
    field: bool,
    editing: bool,
};

/// Owns one provider slot in the catalog and the offer storage behind it.
///
/// A published `Table` BORROWS its offers, so this must outlive its
/// publication and must not be copied once it has published — hold it by
/// pointer, like the catalog's own snapshots.
pub const Publisher = struct {
    provider: catalog.ProviderId,
    intentions: [offers.Intent.count]catalog.IntentionId,
    endpoints: [offers.Intent.count]catalog.EndpointToken,
    table: [offers.Intent.count + max_node_actions]catalog.Offer = undefined,
    /// The node actions this publication carries beyond the standard
    /// vocabulary, in table order after the derived rows. Owned copies: the
    /// scene that advertised them can be replaced while a row is published.
    node_actions: [max_node_actions]NodeAction = undefined,
    node_action_count: usize = 0,
    /// Mints the node-action rows' endpoints (payload = index above).
    node_handle: intent.Handle = undefined,
    /// Storage for a path SYNTHESIZED from a projection subject. Borrowed by
    /// the `focus.Path` handed to `derive`, so it must outlive that call.
    path_buf: [max_path]model.scene.NodeId = undefined,
    /// The published `begin_edit` row's label (`editLabel`).
    edit_label_buf: [64]u8 = undefined,
    count: usize = 0,
    revision: u64 = 0,
    signature: ?Signature = null,

    pub const InitError = catalog.NameError || Allocator.Error;

    /// Register one invoker for the whole table (`intent.zig`'s token
    /// contract) and mint an endpoint per intent, its payload the intent's
    /// index in `bindings`. A second invoker runs the node-action rows; it
    /// captures `&plane.views`, which is where this value lives.
    pub fn init(gpa: Allocator, plane: *intent.Plane) InitError!Publisher {
        var self: Publisher = .{
            .provider = try plane.catalog.provider(provider_name),
            .intentions = undefined,
            .endpoints = undefined,
        };
        const handle = try plane.invokers.register(gpa, provider_name, invokeRoute, routeCommand, null);
        for (bindings, 0..) |binding, index| {
            self.intentions[index] = try plane.catalog.intention(binding.intention);
            self.endpoints[index] = handle.endpoint(@intCast(index));
        }
        self.node_handle = try plane.invokers.register(gpa, provider_name, invokeNodeAction, nodeActionCommand, &plane.views);
        return self;
    }

    /// Bring the catalog in line with a focus (the head's live one, or an
    /// entry's saved one when the question is about a context the head is not
    /// in). Returns true when a new table was published or the old one
    /// withdrawn; an unchanged signature costs one comparison and touches
    /// neither the epoch nor the caller's cached snapshot.
    pub fn refresh(
        self: *Publisher,
        cat: *catalog.Catalog,
        services: *const semantic.Services,
        focus: *const Head.SceneSelection,
        here: ?Here,
    ) Allocator.Error!bool {
        const path = self.pathHere(services, focus, here) orelse return self.withdraw(cat);
        const instance = services.views.get(path.view) orelse return self.withdraw(cat);
        const leaf = path.leaf() orelse return self.withdraw(cat);
        // A begun edit belongs to the head's own focus, never to a path
        // synthesized from a text projection.
        const editing = focus.began and focus.path() != null;
        const next: Signature = .{
            .view = path.view,
            .leaf = leaf,
            .scene = instance.descriptor.revision,
            .field = path.field != null,
            .editing = editing,
        };
        if (self.signature) |current| if (std.meta.eql(current, next)) return false;

        var buffer: offers.Buffer = undefined;
        const items = offers.derive(instance, .{ .path = path, .editing = editing }, &buffer);
        for (items, self.table[0..items.len]) |item, *offer| {
            const index = @intFromEnum(item.intent);
            offer.* = .{
                .intention = self.intentions[index],
                .endpoint = self.endpoints[index],
                .availability = if (item.disabled) |reason|
                    .{ .disabled = .{ .reason = reason, .message = disabled_message } }
                else
                    .enabled,
            };
            // Beginning an edit reads as the provider names editing THIS row
            // (a file's "Edit name"), where it says so.
            if (item.intent == .begin_edit) if (self.editLabel(instance, path)) |label| {
                offer.affordance = .{ .label = label };
            };
        }
        self.count = items.len;
        self.count += try self.publishNodeActions(cat, instance, path, self.table[self.count..], offers.find(items, .begin_edit) != null);
        self.revision += 1;
        _ = try cat.publish(.{
            .provider = self.provider,
            .revision = self.revision,
            .tier = .core,
            .offers = self.table[0..self.count],
        });
        self.signature = next;
        return true;
    }

    /// The label the path's `field.edit` advertiser gives it, copied (the
    /// scene can be replaced while the row is published).
    fn editLabel(self: *Publisher, instance: *const view_runtime.view.Instance, path: model.focus.Path) ?[]const u8 {
        var index = path.nodes.len;
        while (index > 0) {
            index -= 1;
            const node = instance.node(path.nodes[index]) orelse continue;
            for (node.actions) |action| {
                if (!std.mem.eql(u8, action.id, standard.edit) or action.label.len == 0) continue;
                const len = @min(action.label.len, self.edit_label_buf.len);
                @memcpy(self.edit_label_buf[0..len], action.label[0..len]);
                return self.edit_label_buf[0..len];
            }
        }
        return null;
    }

    /// The focused scene's path, or one synthesized from what point is on in a
    /// text projection. Same question, whichever plane is showing.
    fn pathHere(
        self: *Publisher,
        services: *const semantic.Services,
        focus: *const Head.SceneSelection,
        here: ?Here,
    ) ?model.focus.Path {
        if (focus.path()) |path| return path;
        const subject = here orelse return null;
        const instance = services.views.get(subject.view) orelse return null;
        return (instance.focusPath(subject.node, &self.path_buf) catch return null) orelse null;
    }

    /// A head with no live semantic view offers nothing. Withdrawing is the
    /// honest spelling: an empty table would still be a claim.
    pub fn withdraw(self: *Publisher, cat: *catalog.Catalog) bool {
        if (self.signature == null) return false;
        _ = cat.retract(self.provider);
        self.signature = null;
        self.count = 0;
        self.node_action_count = 0;
        return true;
    }

    /// Publish the actions the focus path ADVERTISES that no standard
    /// intention above already carries — `fs.create-file`, `view.apply`
    /// — so a toolbar or context menu enumerating offers sees them, labelled
    /// as the scene labels them. Deepest advertiser wins an id, the same walk
    /// the focused-action route makes. Each is offered under the
    /// `plugin.<action id>` intention: the scene names an open protocol
    /// string, and `plugin.` is the §5.1 root for a name the standard
    /// vocabulary does not own. An id that name cannot spell is skipped
    /// rather than mangled. Returns how many rows it wrote into `out`.
    fn publishNodeActions(
        self: *Publisher,
        cat: *catalog.Catalog,
        instance: *const view_runtime.view.Instance,
        path: model.focus.Path,
        out: []catalog.Offer,
        /// `std.editing.begin` is published for this focus, and carries the
        /// row's `field.edit`: one verb, one row.
        edit_covered: bool,
    ) Allocator.Error!usize {
        self.node_action_count = 0;
        var index = path.nodes.len;
        while (index > 0) {
            index -= 1;
            const node = instance.node(path.nodes[index]) orelse continue;
            for (node.actions) |action| {
                if (self.node_action_count == max_node_actions) break;
                if (coveredByStandard(action.id) or self.hasNodeAction(action.id)) continue;
                if (edit_covered and std.mem.eql(u8, action.id, standard.edit)) continue;
                const slot = &self.node_actions[self.node_action_count];
                const name = std.fmt.bufPrint(&slot.name_buf, "plugin.{s}", .{action.id}) catch continue;
                const id = cat.intention(name) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => continue,
                };
                if (action.id.len > slot.id_buf.len) continue;
                @memcpy(slot.id_buf[0..action.id.len], action.id);
                slot.id_len = action.id.len;
                const label_len = @min(action.label.len, slot.label_buf.len);
                @memcpy(slot.label_buf[0..label_len], action.label[0..label_len]);
                slot.label_len = label_len;
                out[self.node_action_count] = .{
                    .intention = id,
                    .endpoint = self.node_handle.endpoint(@intCast(self.node_action_count)),
                    .availability = if (action.enabled)
                        .enabled
                    else
                        .{ .disabled = .{ .reason = offers.provider_disabled, .message = disabled_message } },
                    .affordance = .{ .label = slot.label() },
                    // A node's own action acts on that node: it says nothing
                    // about several selected rows, so it is refused on them.
                    .arity = null,
                };
                self.node_action_count += 1;
            }
        }
        return self.node_action_count;
    }

    fn hasNodeAction(self: *const Publisher, id: []const u8) bool {
        for (self.node_actions[0..self.node_action_count]) |*a| {
            if (std.mem.eql(u8, a.id(), id)) return true;
        }
        return false;
    }
};

/// Most non-standard actions one focus publishes; a scene advertising more
/// keeps the first (deepest) ones. Generous for a row's verbs.
const max_node_actions = 24;

/// One published node action: the protocol id it runs, and the scene's label.
const NodeAction = struct {
    id_buf: [96]u8 = undefined,
    id_len: usize = 0,
    /// `plugin.<id>` — the intention it is offered under.
    name_buf: [104]u8 = undefined,
    label_buf: [64]u8 = undefined,
    label_len: usize = 0,

    fn id(self: *const NodeAction) []const u8 {
        return self.id_buf[0..self.id_len];
    }
    fn label(self: *const NodeAction) []const u8 {
        return self.label_buf[0..self.label_len];
    }
};

/// The node actions `offers.derive` already turns into a standard intention:
/// publishing them again would offer one verb twice under two names.
fn coveredByStandard(id: []const u8) bool {
    const covered = [_][]const u8{
        standard.toggle_expanded, standard.open_container, standard.open,
        standard.copy,            standard.paste_after,    standard.cut,
        standard.insert_before,   standard.insert_after,
    };
    for (covered) |c| if (std.mem.eql(u8, c, id)) return true;
    return false;
}

/// Run the route the winning endpoint names. Authority stays at the command
/// door, exactly as when a key is bound to that command by name.
fn invokeRoute(_: ?*anyopaque, ctx: *command.Context, payload: u32) anyerror!void {
    if (payload >= bindings.len) return intent.Error.StaleEndpoint;
    _ = try command.run(ctx.commands, ctx, bindings[payload].route, &.{});
}

fn routeCommand(_: ?*anyopaque, _: *command.Context, payload: u32) ?[]const u8 {
    if (payload >= bindings.len) return null;
    return bindings[payload].route;
}

/// A node action's protocol name — a semantic action, which is a command by
/// that name where one is registered.
fn nodeActionCommand(data: ?*anyopaque, _: *command.Context, payload: u32) ?[]const u8 {
    const self: *Publisher = @ptrCast(@alignCast(data.?));
    if (payload >= self.node_action_count) return null;
    return self.node_actions[payload].id();
}

/// Run a published node action through the SAME door a key bound to its
/// protocol name reaches (`action_here.invokeHere`): the focused view — scene
/// or listing — decides what it means. Nobody claiming it is a stale row.
fn invokeNodeAction(data: ?*anyopaque, ctx: *command.Context, payload: u32) anyerror!void {
    const self: *Publisher = @ptrCast(@alignCast(data.?));
    if (payload >= self.node_action_count) return intent.Error.StaleEndpoint;
    const id = self.node_actions[payload].id();
    if (try action_here.invokeHere(ctx, id, 0) == null) return intent.Error.StaleEndpoint;
}

const t = std.testing;

const Fixture = struct {
    services: semantic.Services,
    /// The real plane: its catalog, its invoker registry, and the publisher
    /// under test, wired exactly as a live system wires them.
    plane: intent.Plane,
    head: Head,
    owner: model.owner.Id,

    link: model.scene.TargetLink,
    columns: [2]model.scene.Node = undefined,
    rows: [2]model.scene.Node = undefined,

    const row_actions = [_]model.scene.Action{
        .{ .id = standard.open, .label = "Open", .enabled = true },
    };
    const refused_actions = [_]model.scene.Action{
        .{ .id = standard.open, .label = "Open", .enabled = false },
    };
    const transfer_actions = [_]model.scene.Action{
        .{ .id = standard.copy, .label = "Copy", .enabled = true },
        .{ .id = standard.cut, .label = "Cut", .enabled = true },
        .{ .id = standard.paste_after, .label = "Paste", .enabled = true },
    };
    const container_actions = [_]model.scene.Action{
        .{ .id = standard.open_container, .label = "Open container", .enabled = true },
    };

    /// `src/plugin_lib/files/projection.zig`'s shape: a vertical `files` root of
    /// horizontal `files.row` containers whose focusable `files.name` column
    /// carries the row's target.
    fn scene(self: *Fixture, refused: bool) model.scene.Node {
        self.columns = .{
            .{ .id = @enumFromInt(11), .role = "files.metadata", .content = .{ .label = "-" } },
            .{
                .id = @enumFromInt(12),
                .role = "files.name",
                .focusable = true,
                .target = self.link,
                .content = .{ .label = "a" },
            },
        };
        self.rows = .{
            .{
                .id = @enumFromInt(10),
                .role = "files.row",
                .actions = if (refused) &refused_actions else &row_actions,
                .content = .{ .container = .{ .axis = .horizontal, .children = &self.columns } },
            },
            .{ .id = @enumFromInt(20), .role = "files.row", .focusable = true, .content = .{ .label = "b" } },
        };
        return .{
            .id = @enumFromInt(1),
            .role = "files",
            .content = .{ .container = .{ .axis = .vertical, .children = &self.rows } },
        };
    }

    /// The same shape, with the designations a directory row carries: the row
    /// can be captured and pasted onto, and the listing has a parent.
    fn transferScene(self: *Fixture) model.scene.Node {
        var root = self.scene(false);
        self.rows[0].actions = &transfer_actions;
        root.actions = &container_actions;
        return root;
    }

    fn init(self: *Fixture) !void {
        self.services = .init(.here);
        self.head = .empty;
        self.owner = try self.services.acquireOwner();
        try self.plane.init(t.allocator);
        const target = try self.services.publishTarget(t.allocator, self.owner, .{
            .kind = .file,
            .display_name = "a",
        });
        self.link = .{ .target = target, .revision = self.services.targets.get(target).?.revision };
    }

    fn deinit(self: *Fixture) void {
        self.head.deinit(t.allocator);
        self.plane.deinit(t.allocator);
        self.services.deinit(t.allocator);
    }

    fn refresh(self: *Fixture) !bool {
        return self.plane.views.refresh(&self.plane.catalog, &self.services, &self.head.scene_selection, null);
    }

    fn context(self: *const Fixture) catalog.Context {
        return .{ .key = 1, .revision = self.plane.views.revision };
    }

    fn resolve(self: *Fixture, arms: []const []const u8) !catalog.Resolution {
        var ids: [4]catalog.IntentionId = undefined;
        for (arms, ids[0..arms.len]) |name, *id| id.* = try self.plane.catalog.intention(name);
        const snapshot = try self.plane.catalog.snapshot(self.context());
        return snapshot.resolve(ids[0..arms.len]);
    }

    /// The route a decision's endpoint carries, decoded the way its invoker
    /// decodes it.
    fn routeOf(_: *Fixture, decision: catalog.Decision) []const u8 {
        return bindings[intent.Endpoint.of(decision.endpoint).payload].route;
    }

    /// Nonapplicable: nothing was published for it at all (§9.3).
    fn absent(self: *Fixture, intention: []const u8) !void {
        const resolution = try self.resolve(&.{intention});
        try t.expect(resolution == .unavailable and resolution.unavailable == .no_offer);
    }
};

test "a focused files row publishes activation and its grid, never expansion" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();

    const view = try fixture.services.publishView(t.allocator, fixture.owner, null, 1, fixture.scene(false));
    _ = try fixture.services.focusView(&fixture.head, t.allocator, view, @enumFromInt(12));
    try t.expect(try fixture.refresh());

    // Return resolves activation through the target-open route; Tab finds
    // nothing to expand on a leaf and never reaches a text insertion.
    const activated = try fixture.resolve(&.{ "std.target.activate", "std.editing.insert-line-break" });
    try t.expectEqualStrings("target.open", fixture.routeOf(activated.decision));
    try fixture.absent("std.hierarchy.toggle-expanded");

    const down = try fixture.resolve(&.{"std.navigation.down"});
    // A ROW step. Falls through to the plain cursor move when the entry is not
    // a projection, so a scene reaches the same behaviour by the same route.
    try t.expectEqualStrings("cursor.row-down", fixture.routeOf(down.decision));
    // A row of columns has a horizontal axis, and a focused view can be left.
    try t.expect((try fixture.resolve(&.{"std.navigation.right"})) == .decision);
    try t.expect((try fixture.resolve(&.{"std.navigation.back"})) == .decision);
}

test "a refused row action publishes a disabled offer with its reason" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();

    const view = try fixture.services.publishView(t.allocator, fixture.owner, null, 1, fixture.scene(true));
    _ = try fixture.services.focusView(&fixture.head, t.allocator, view, @enumFromInt(12));
    try t.expect(try fixture.refresh());

    // Relevant but impossible STOPS the fallback walk: Return must not insert
    // a line break because activation is momentarily refused (§10.2).
    const resolution = try fixture.resolve(&.{ "std.target.activate", "std.editing.insert-line-break" });
    try t.expectEqualStrings(offers.provider_disabled, resolution.unavailable.disabled.reason.reason);
    try t.expectEqualStrings(disabled_message, resolution.unavailable.disabled.reason.message);
}

test "republication follows focus, scene revision, and the loss of a view" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();

    const view = try fixture.services.publishView(t.allocator, fixture.owner, null, 1, fixture.scene(false));
    _ = try fixture.services.focusView(&fixture.head, t.allocator, view, @enumFromInt(12));
    try t.expect(try fixture.refresh());
    const first = fixture.plane.views.revision;

    // Same focus, same scene: no new table, so no cached snapshot is voided.
    try t.expect(!try fixture.refresh());
    try t.expectEqual(first, fixture.plane.views.revision);

    // Focus moves to a plain label row: activation and the column axis go away.
    _ = try fixture.services.focusView(&fixture.head, t.allocator, view, @enumFromInt(20));
    try t.expect(try fixture.refresh());
    try t.expectEqual(first + 1, fixture.plane.views.revision);
    try fixture.absent("std.target.activate");
    try fixture.absent("std.navigation.right");

    // The provider replaces the scene under the same view ref.
    try fixture.services.replaceView(t.allocator, fixture.owner, view, 2, fixture.scene(true));
    _ = try fixture.services.focusView(&fixture.head, t.allocator, view, @enumFromInt(12));
    try t.expect(try fixture.refresh());
    try t.expectEqual(first + 2, fixture.plane.views.revision);

    // The view closes: the table is withdrawn, not left published as empty.
    try t.expect(fixture.services.closeView(t.allocator, fixture.owner, view));
    fixture.head.scene_selection.clear();
    try t.expect(try fixture.refresh());
    try t.expect(fixture.plane.catalog.published(fixture.plane.views.provider) == null);
    try t.expect(!try fixture.refresh());
}

test "node actions outside the standard vocabulary are offers too, labelled as the scene labels them" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();

    const extra = [_]model.scene.Action{
        .{ .id = standard.open, .label = "Open", .enabled = true },
        .{ .id = "fs.create-file", .label = "New file", .enabled = true },
        .{ .id = standard.apply, .label = "Apply draft", .enabled = false },
    };
    var root = fixture.scene(false);
    fixture.rows[0].actions = &extra;
    // The root advertises create-file too: the DEEPEST advertiser (the row)
    // owns the id, and it is offered once.
    root.actions = extra[1..2];
    const view = try fixture.services.publishView(t.allocator, fixture.owner, null, 1, root);
    _ = try fixture.services.focusView(&fixture.head, t.allocator, view, @enumFromInt(12));
    try t.expect(try fixture.refresh());

    const snapshot = try fixture.plane.catalog.snapshot(fixture.context());
    const create = fixture.plane.catalog.findIntention("plugin.fs.create-file").?;
    const rows = snapshot.offersFor(create);
    try t.expectEqual(@as(usize, 1), rows.len);
    try t.expectEqualStrings("New file", rows[0].affordance.label);
    try t.expect(rows[0].availability == .enabled);
    // A refused action is published disabled, with the derivation's reason.
    const apply = try fixture.resolve(&.{"plugin.view.apply"});
    try t.expectEqualStrings(offers.provider_disabled, apply.unavailable.disabled.reason.reason);
    // A standard action is NOT republished under a second name.
    try t.expect(fixture.plane.catalog.findIntention("plugin.target.open") == null);
}

test "a row's transfer designations resolve to the register's own routes" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();

    const view = try fixture.services.publishView(t.allocator, fixture.owner, null, 1, fixture.transferScene());
    _ = try fixture.services.focusView(&fixture.head, t.allocator, view, @enumFromInt(12));
    try t.expect(try fixture.refresh());

    const words = [_][2][]const u8{
        .{ "std.transfer.yank", "selection.copy" },
        .{ "std.transfer.paste", "selection.paste-after" },
        .{ "std.transfer.delete-to-register", "selection.cut" },
        .{ "std.hierarchy.step-out", "target.open-container" },
    };
    for (words) |word| {
        const resolution = try fixture.resolve(&.{word[0]});
        try t.expectEqualStrings(word[1], fixture.routeOf(resolution.decision));
    }

    // The same keys over a scene that designates none of it reach nobody.
    try fixture.services.replaceView(t.allocator, fixture.owner, view, 2, fixture.scene(false));
    _ = try fixture.services.focusView(&fixture.head, t.allocator, view, @enumFromInt(12));
    try t.expect(try fixture.refresh());
    for (words) |word| try fixture.absent(word[0]);
}
