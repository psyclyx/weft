//! Standard offers derived from a focused scene — the generic adapter every
//! semantic view gets, not a per-provider courtesy (architecture §9.3, §10.2,
//! §14.2).
//!
//! The input is scene VOCABULARY: container content, target links, container
//! axes, and the head's focus path. No provider identity, no plugin name, no
//! role string is consulted, so a view that says nothing about input still
//! answers Tab, Return, the motion keys, and `q`.
//!
//! Absence means NONAPPLICABLE (§9.3). A row nothing can open publishes no
//! `toggle-expanded` at all — not a disabled one with "not expandable" —
//! because nothing about expansion is relevant there. `disabled` is reserved
//! for relevant-but-impossible, which here means the scene advertises the
//! route's own action with `enabled = false`.
//!
//! Catalog identity, endpoints, and publication live one layer up
//! (`core/view_offers.zig`): this module has no allocator, no catalog, and no
//! dispatch — it is a function from a scene and a focus to a list of intents.

const std = @import("std");
const semantic = @import("weft_semantic");
const view = @import("view.zig");

const standard = semantic.action.standard;

/// The standard intents a scene's shape can imply. Names map to
/// `std.*` intentions one layer up; this enum stays catalog-free.
pub const Intent = enum {
    toggle_expanded,
    step_out,
    activate,
    transfer_yank,
    transfer_paste,
    transfer_delete,
    navigate_up,
    navigate_down,
    navigate_left,
    navigate_right,
    back,

    pub const count = @typeInfo(Intent).@"enum".fields.len;
};

/// §9.3 reason code: the offer is relevant, and the scene itself says the
/// route cannot run right now.
pub const provider_disabled = "provider-disabled";

pub const Item = struct {
    intent: Intent,
    /// `null` is `enabled`; otherwise a stable reason code.
    disabled: ?[]const u8 = null,
};

pub const Focus = struct {
    path: semantic.focus.Path,
};

/// One item per intent at most, so callers can size storage exactly.
pub const Buffer = [Intent.count]Item;

/// Derive the offers for one focus. Deterministic and in `Intent` order:
/// two identical scenes never publish two different tables.
pub fn derive(instance: *const view.Instance, focus: Focus, out: *Buffer) []const Item {
    var count: usize = 0;
    const leaf_id = focus.path.leaf() orelse return out[0..0];
    if (instance.node(leaf_id) == null) return out[0..0];

    // Expansion follows the deepest node on the path that ADVERTISES the
    // open/close route, the same walk that route itself makes. Shape cannot
    // stand in for it: a row of columns is a container too, yet only some
    // rows own children, and only their provider can splice them in. So a
    // path that names no such node is nonapplicable, never a disabled offer
    // whose route would reach nobody.
    count += pushAdvertised(instance, focus.path, out, count, .toggle_expanded, standard.toggle_expanded);
    // Stepping out is the same question asked upward: the path advertises a
    // container to leave for, exactly where a provider owns one. Shape cannot
    // answer it either — every row sits inside the root container, yet only a
    // provider knows whether anything encloses the LOCUS.
    count += pushAdvertised(instance, focus.path, out, count, .step_out, standard.open_container);
    // Activation follows the same nearest-target walk the target-open route
    // performs, so an offer can never name a subject the route would not.
    if (nearestTarget(instance, focus.path) != null) {
        out[count] = .{
            .intent = .activate,
            .disabled = actionState(instance, focus.path, standard.open),
        };
        count += 1;
    }
    // Transfer follows the designations the focus carries: a row that says it
    // can be captured, or a locus that says something can be placed in it.
    // The register itself is core's, so an empty one refuses at the door
    // rather than making the offer disappear here.
    count += pushAdvertised(instance, focus.path, out, count, .transfer_yank, standard.copy);
    count += pushAdvertised(instance, focus.path, out, count, .transfer_paste, standard.paste_after);
    count += pushAdvertised(instance, focus.path, out, count, .transfer_delete, standard.cut);
    const axes = pathAxes(instance, focus.path);
    if (axes.vertical) {
        out[count] = .{ .intent = .navigate_up };
        out[count + 1] = .{ .intent = .navigate_down };
        count += 2;
    }
    if (axes.horizontal) {
        out[count] = .{ .intent = .navigate_left };
        out[count + 1] = .{ .intent = .navigate_right };
        count += 2;
    }
    // Leaving a focused view always lands somewhere — the workspace keeps the
    // entry it came from, and the route falls back to another live one — so a
    // live focus is itself the back capability.
    out[count] = .{ .intent = .back };
    count += 1;
    return out[0..count];
}

/// Offer `intent` exactly when the path advertises `id`, disabled exactly
/// when its advertiser refuses. Returns how many items were written, so a
/// caller's cursor advances only on a real offer.
fn pushAdvertised(
    instance: *const view.Instance,
    path: semantic.focus.Path,
    out: *Buffer,
    count: usize,
    intent: Intent,
    id: []const u8,
) usize {
    const action = advertiser(instance, path, id) orelse return 0;
    out[count] = .{ .intent = intent, .disabled = if (action.enabled) null else provider_disabled };
    return 1;
}

pub fn find(items: []const Item, intent: Intent) ?Item {
    for (items) |item| if (item.intent == intent) return item;
    return null;
}

/// Availability follows the deepest node on the focus path that ADVERTISES
/// the route's action — the same walk the focused-action route makes, so a
/// row can refuse on behalf of the field inside it. A path that advertises
/// the action nowhere makes no claim about it, and stays enabled.
fn actionState(instance: *const view.Instance, path: semantic.focus.Path, id: []const u8) ?[]const u8 {
    const action = advertiser(instance, path, id) orelse return null;
    return if (action.enabled) null else provider_disabled;
}

/// The action as advertised by the deepest node on the path that names it.
fn advertiser(instance: *const view.Instance, path: semantic.focus.Path, id: []const u8) ?semantic.scene.Action {
    var index = path.nodes.len;
    while (index > 0) {
        index -= 1;
        const node = instance.node(path.nodes[index]) orelse continue;
        for (node.actions) |candidate| if (std.mem.eql(u8, candidate.id, id)) return candidate;
    }
    return null;
}

fn nearestTarget(instance: *const view.Instance, path: semantic.focus.Path) ?*const semantic.scene.Node {
    var index = path.nodes.len;
    while (index > 0) {
        index -= 1;
        const node = instance.node(path.nodes[index]) orelse continue;
        if (node.target != null) return node;
    }
    return null;
}

const Axes = struct { vertical: bool = false, horizontal: bool = false };

/// The axes the focused node SITS IN: its ancestors' container axes, and only
/// where an ancestor holds more than one child. One row in one list has no
/// sibling to move to, and `overlay` is a stacking axis, not a grid one.
fn pathAxes(instance: *const view.Instance, path: semantic.focus.Path) Axes {
    var axes: Axes = .{};
    if (path.nodes.len == 0) return axes;
    for (path.nodes[0 .. path.nodes.len - 1]) |id| {
        const node = instance.node(id) orelse continue;
        const container = switch (node.content) {
            .container => |value| value,
            else => continue,
        };
        if (container.children.len < 2) continue;
        switch (container.axis) {
            .vertical => axes.vertical = true,
            .horizontal => axes.horizontal = true,
            .overlay => {},
        }
    }
    return axes;
}

const t = std.testing;

const owner: semantic.owner.Id = @enumFromInt(1);

fn fieldRef(slot: u32) semantic.scene.FieldRef {
    return .{ .authority = .here, .slot = slot, .generation = 1 };
}

fn link(slot: u32) semantic.scene.TargetLink {
    return .{ .target = .{ .authority = .here, .slot = slot, .generation = 1 }, .revision = 1 };
}

/// The shape `src/plugin_lib/files/projection.zig` publishes: a vertical `files`
/// root of horizontal `files.row` containers, each holding a metadata label, a
/// mode column, and the focusable `files.name` field that carries the row's
/// target.
fn filesScene(rows: []const semantic.scene.Node) semantic.scene.Node {
    return .{
        .id = @enumFromInt(1),
        .role = "files",
        .content = .{ .container = .{ .axis = .vertical, .children = rows } },
    };
}

/// `open` is the row's activation state; `expand` is present only on a row
/// whose provider can open or close children under it.
const RowShape = struct { open: bool = true, expand: ?bool = null };

fn filesRow(comptime base: u32, comptime shape: RowShape) semantic.scene.Node {
    const row = struct {
        const columns = [_]semantic.scene.Node{
            .{ .id = @enumFromInt(base + 1), .role = "files.metadata", .content = .{ .label = "-" } },
            .{ .id = @enumFromInt(base + 2), .role = "files.mode", .content = .{ .label = "0644" } },
            .{
                .id = @enumFromInt(base + 3),
                .role = "files.name",
                .focusable = true,
                .target = link(base),
                .content = .{ .field = .{ .ref = fieldRef(base), .single_line = true } },
            },
        };
        const advertised = [_]semantic.scene.Action{
            .{ .id = standard.open, .label = "Open", .enabled = shape.open },
            .{ .id = standard.toggle_expanded, .label = "Expand", .enabled = shape.expand orelse false },
        };
    };
    return .{
        .id = @enumFromInt(base),
        .role = "files.row",
        .actions = if (shape.expand == null) row.advertised[0..1] else row.advertised[0..2],
        .target = link(base),
        .content = .{ .container = .{ .axis = .horizontal, .children = &row.columns } },
    };
}

const Published = struct {
    registry: view.Registry,
    ref: semantic.view.Ref,
    storage: [8]semantic.scene.NodeId = undefined,

    fn open(root: semantic.scene.Node) !Published {
        var self: Published = .{ .registry = .init(.here), .ref = undefined };
        self.ref = try self.registry.publish(t.allocator, owner, null, 1, root);
        return self;
    }

    fn deinit(self: *Published) void {
        self.registry.deinit(t.allocator);
    }

    fn instance(self: *const Published) *const view.Instance {
        return self.registry.get(self.ref).?;
    }

    fn focus(self: *Published, node: semantic.scene.NodeId) !Focus {
        const path = (try self.instance().focusPath(node, &self.storage)).?;
        return .{ .path = path };
    }
};

test "a focused files row offers activation and its grid, never expansion" {
    const rows = [_]semantic.scene.Node{ filesRow(10, .{}), filesRow(20, .{}) };
    var published = try Published.open(filesScene(&rows));
    defer published.deinit();

    var buffer: Buffer = undefined;
    const items = derive(published.instance(), try published.focus(@enumFromInt(13)), &buffer);

    // Nothing on this path claims to open children: absence, not a disabled
    // "not expandable" offer, is how §9.3 says nonapplicable is spelled.
    try t.expect(find(items, .toggle_expanded) == null);
    try t.expect(find(items, .activate).?.disabled == null);
    // Vertical list of rows, horizontal columns inside the focused row.
    try t.expect(find(items, .navigate_up) != null);
    try t.expect(find(items, .navigate_down) != null);
    try t.expect(find(items, .navigate_left) != null);
    try t.expect(find(items, .navigate_right) != null);
    // A live focus is the back capability: leaving lands on the entry the
    // workspace came from.
    try t.expect(find(items, .back) != null);
}

test "a refused row action is disabled, an absent target is nothing at all" {
    const rows = [_]semantic.scene.Node{ filesRow(10, .{ .open = false }), filesRow(20, .{}) };
    var published = try Published.open(filesScene(&rows));
    defer published.deinit();

    var buffer: Buffer = undefined;
    const refused = derive(published.instance(), try published.focus(@enumFromInt(13)), &buffer);
    try t.expectEqualStrings(provider_disabled, find(refused, .activate).?.disabled.?);

    const bare = [_]semantic.scene.Node{
        .{ .id = @enumFromInt(2), .role = "files.name", .focusable = true, .content = .{ .label = "a" } },
        .{ .id = @enumFromInt(3), .role = "files.name", .focusable = true, .content = .{ .label = "b" } },
    };
    var flat = try Published.open(filesScene(&bare));
    defer flat.deinit();
    const items = derive(flat.instance(), try flat.focus(@enumFromInt(2)), &buffer);
    try t.expect(find(items, .activate) == null);
    // A single-column list has no horizontal axis to move along.
    try t.expect(find(items, .navigate_up) != null);
    try t.expect(find(items, .navigate_left) == null);
}

test "an expandable row offers expansion to the field focused inside it" {
    const rows = [_]semantic.scene.Node{ filesRow(10, .{ .expand = true }), filesRow(20, .{}) };
    var published = try Published.open(filesScene(&rows));
    defer published.deinit();

    var buffer: Buffer = undefined;
    // The keyboard is on the editable name INSIDE the row that owns children,
    // which is where a directory browser leaves it while renaming.
    const items = derive(published.instance(), try published.focus(@enumFromInt(13)), &buffer);
    try t.expect(find(items, .toggle_expanded).?.disabled == null);
    try t.expect(find(items, .activate) != null);
    try t.expect(find(items, .back) != null);

    // The row beside it owns no children, so the same key is nonapplicable.
    var beside: Buffer = undefined;
    const flat = derive(published.instance(), try published.focus(@enumFromInt(23)), &beside);
    try t.expect(find(flat, .toggle_expanded) == null);
}

test "a row that refuses its own open/close route is disabled, not absent" {
    const rows = [_]semantic.scene.Node{ filesRow(10, .{ .expand = false }), filesRow(20, .{}) };
    var published = try Published.open(filesScene(&rows));
    defer published.deinit();

    var buffer: Buffer = undefined;
    const items = derive(published.instance(), try published.focus(@enumFromInt(13)), &buffer);
    try t.expectEqualStrings(provider_disabled, find(items, .toggle_expanded).?.disabled.?);

    // A single row on the axis has no sibling to move to.
    const lone = [_]semantic.scene.Node{filesRow(30, .{})};
    var only = try Published.open(filesScene(&lone));
    defer only.deinit();
    var single: Buffer = undefined;
    const alone = derive(only.instance(), try only.focus(@enumFromInt(33)), &single);
    try t.expect(find(alone, .navigate_up) == null);
}

test "transfer and step-out follow the designations the scene advertises" {
    const row_actions = [_]semantic.scene.Action{
        .{ .id = standard.copy, .label = "Copy", .enabled = true },
        .{ .id = standard.cut, .label = "Cut", .enabled = true },
        .{ .id = standard.paste_after, .label = "Paste", .enabled = false },
    };
    const rows = [_]semantic.scene.Node{
        .{ .id = @enumFromInt(10), .role = "files.row", .focusable = true, .actions = &row_actions, .content = .{ .label = "a" } },
        .{ .id = @enumFromInt(20), .role = "files.row", .focusable = true, .content = .{ .label = "b" } },
    };
    const root_actions = [_]semantic.scene.Action{
        .{ .id = standard.open_container, .label = "Open container", .enabled = true },
    };
    var published = try Published.open(.{
        .id = @enumFromInt(1),
        .role = "files",
        .actions = &root_actions,
        .content = .{ .container = .{ .axis = .vertical, .children = &rows } },
    });
    defer published.deinit();

    var buffer: Buffer = undefined;
    const items = derive(published.instance(), try published.focus(@enumFromInt(10)), &buffer);
    try t.expect(find(items, .transfer_yank).?.disabled == null);
    try t.expect(find(items, .transfer_delete).?.disabled == null);
    // Relevant but impossible: this row says a paste cannot land here, so the
    // offer is published disabled rather than withheld (§9.3).
    try t.expectEqualStrings(provider_disabled, find(items, .transfer_paste).?.disabled.?);
    // Stepping out is the ROOT's claim, and every row's path runs through it.
    try t.expect(find(items, .step_out).?.disabled == null);

    // The row beside it designates nothing transferable: absence, not a
    // disabled offer whose route would reach nobody.
    var beside: Buffer = undefined;
    const plain = derive(published.instance(), try published.focus(@enumFromInt(20)), &beside);
    try t.expect(find(plain, .transfer_yank) == null);
    try t.expect(find(plain, .transfer_paste) == null);
    try t.expect(find(plain, .transfer_delete) == null);
    try t.expect(find(plain, .step_out) != null);

    // A scene that names no enclosing container offers no way out of one.
    var rootless = try Published.open(filesScene(&rows));
    defer rootless.deinit();
    var enclosed: Buffer = undefined;
    const inside = derive(rootless.instance(), try rootless.focus(@enumFromInt(10)), &enclosed);
    try t.expect(find(inside, .step_out) == null);
    try t.expect(find(inside, .transfer_yank) != null);
}
