//! Publish the focused view's standard offers into the catalog — the host
//! half of the generic adapter (architecture §9.2, §10.2, §14.2).
//!
//! `view_runtime/offers.zig` derives WHAT a scene affords from its shape;
//! this names those affordances in the standard vocabulary, points each at an
//! existing host route, and pushes the result as one revision-stamped table.
//! Files, dired, git, and any future view therefore answer Tab, Return, the
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

const offers = view_runtime.offers;
const standard = model.action.standard;

pub const provider_name = "core.view";

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
    .{ .intent = .toggle_expanded, .intention = "std.hierarchy.toggle-expanded", .route = "hierarchy-toggle-expanded" },
    .{ .intent = .step_out, .intention = "std.hierarchy.step-out", .route = "hierarchy-step-out" },
    .{ .intent = .activate, .intention = "std.target.activate", .route = "target-open-focused" },
    // Transfer rides the routes the register already owns: capture, place,
    // and capture-as-a-move. The provider decides what a capture MEANS for
    // its rows; the standard word only says which half of the ferry runs.
    .{ .intent = .transfer_yank, .intention = "std.transfer.yank", .route = "selection-copy" },
    .{ .intent = .transfer_paste, .intention = "std.transfer.paste", .route = "selection-paste-after" },
    .{ .intent = .transfer_delete, .intention = "std.transfer.delete-to-register", .route = "selection-cut" },
    .{ .intent = .navigate_up, .intention = "std.navigation.up", .route = "cursor-up" },
    .{ .intent = .navigate_down, .intention = "std.navigation.down", .route = "cursor-down" },
    .{ .intent = .navigate_left, .intention = "std.navigation.left", .route = "cursor-left" },
    .{ .intent = .navigate_right, .intention = "std.navigation.right", .route = "cursor-right" },
    .{ .intent = .back, .intention = "std.navigation.back", .route = "navigate-back" },
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
    table: [offers.Intent.count]catalog.Offer = undefined,
    count: usize = 0,
    revision: u64 = 0,
    signature: ?Signature = null,

    pub const InitError = catalog.NameError || Allocator.Error;

    /// Register one invoker for the whole table (`intent.zig`'s token
    /// contract) and mint an endpoint per intent, its payload the intent's
    /// index in `bindings`.
    pub fn init(gpa: Allocator, plane: *intent.Plane) InitError!Publisher {
        var self: Publisher = .{
            .provider = try plane.catalog.provider(provider_name),
            .intentions = undefined,
            .endpoints = undefined,
        };
        const handle = try plane.invokers.register(gpa, provider_name, invokeRoute, null);
        for (bindings, 0..) |binding, index| {
            self.intentions[index] = try plane.catalog.intention(binding.intention);
            self.endpoints[index] = handle.endpoint(@intCast(index));
        }
        return self;
    }

    /// Bring the catalog in line with this head's focus. Returns true when a
    /// new table was published or the old one withdrawn; an unchanged
    /// signature costs one comparison and touches neither the epoch nor the
    /// caller's cached snapshot.
    pub fn refresh(
        self: *Publisher,
        cat: *catalog.Catalog,
        services: *const semantic.Services,
        head: *const Head,
    ) Allocator.Error!bool {
        const path = head.semantic_focus.path() orelse return self.withdraw(cat);
        const instance = services.views.get(path.view) orelse return self.withdraw(cat);
        const leaf = path.leaf() orelse return self.withdraw(cat);
        const next: Signature = .{
            .view = path.view,
            .leaf = leaf,
            .scene = instance.descriptor.revision,
        };
        if (self.signature) |current| if (std.meta.eql(current, next)) return false;

        var buffer: offers.Buffer = undefined;
        const items = offers.derive(instance, .{ .path = path }, &buffer);
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
        }
        self.count = items.len;
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

    /// A head with no live semantic view offers nothing. Withdrawing is the
    /// honest spelling: an empty table would still be a claim.
    pub fn withdraw(self: *Publisher, cat: *catalog.Catalog) bool {
        if (self.signature == null) return false;
        _ = cat.retract(self.provider);
        self.signature = null;
        self.count = 0;
        return true;
    }
};

/// Run the route the winning endpoint names. Authority stays at the command
/// door, exactly as when a key is bound to that command by name.
fn invokeRoute(_: ?*anyopaque, ctx: *command.Context, payload: u32) anyerror!void {
    if (payload >= bindings.len) return intent.Error.StaleEndpoint;
    _ = try command.run(ctx.commands, ctx, bindings[payload].route, &.{});
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

    /// `src/plugins/dired/projection.zig`'s shape: a vertical `files` root of
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
        return self.plane.views.refresh(&self.plane.catalog, &self.services, &self.head);
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
    try t.expectEqualStrings("target-open-focused", fixture.routeOf(activated.decision));
    try fixture.absent("std.hierarchy.toggle-expanded");

    const down = try fixture.resolve(&.{"std.navigation.down"});
    try t.expectEqualStrings("cursor-down", fixture.routeOf(down.decision));
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
    fixture.head.semantic_focus.clear();
    try t.expect(try fixture.refresh());
    try t.expect(fixture.plane.catalog.published(fixture.plane.views.provider) == null);
    try t.expect(!try fixture.refresh());
}

test "a row's transfer designations resolve to the register's own routes" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();

    const view = try fixture.services.publishView(t.allocator, fixture.owner, null, 1, fixture.transferScene());
    _ = try fixture.services.focusView(&fixture.head, t.allocator, view, @enumFromInt(12));
    try t.expect(try fixture.refresh());

    const words = [_][2][]const u8{
        .{ "std.transfer.yank", "selection-copy" },
        .{ "std.transfer.paste", "selection-paste-after" },
        .{ "std.transfer.delete-to-register", "selection-cut" },
        .{ "std.hierarchy.step-out", "hierarchy-step-out" },
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
