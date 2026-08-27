//! Standard offers derived from a focused scene — the generic adapter every
//! semantic view gets, not a per-provider courtesy (architecture §9.3, §10.2,
//! §14.2).
//!
//! The input is scene VOCABULARY: container content, target links, container
//! axes, and the head's focus path. No provider identity, no plugin name, no
//! role string is consulted, so a view that says nothing about input still
//! answers Tab, Return, the motion keys, and `q`.
//!
//! Absence means NONAPPLICABLE (§9.3). A focused leaf publishes no
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
    activate,
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
    /// The head holds a navigation anchor: an action moved focus here from a
    /// remembered node, so there is somewhere to go back to.
    anchored: bool = false,
};

/// One item per intent at most, so callers can size storage exactly.
pub const Buffer = [Intent.count]Item;

/// Derive the offers for one focus. Deterministic and in `Intent` order:
/// two identical scenes never publish two different tables.
pub fn derive(instance: *const view.Instance, focus: Focus, out: *Buffer) []const Item {
    var count: usize = 0;
    const leaf_id = focus.path.leaf() orelse return out[0..0];
    const leaf = instance.node(leaf_id) orelse return out[0..0];

    // Expansion acts on the FOCUSED node — a leaf has no children to open, so
    // it is nonapplicable rather than disabled.
    if (leaf.content == .container) {
        out[count] = .{
            .intent = .toggle_expanded,
            .disabled = actionState(instance, focus.path, standard.open_container),
        };
        count += 1;
    }
    // Activation follows the same nearest-target walk the target-open route
    // performs, so an offer can never name a subject the route would not.
    if (nearestTarget(instance, focus.path) != null) {
        out[count] = .{
            .intent = .activate,
            .disabled = actionState(instance, focus.path, standard.open),
        };
        count += 1;
    }
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
    if (focus.anchored) {
        out[count] = .{ .intent = .back };
        count += 1;
    }
    return out[0..count];
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
    var index = path.nodes.len;
    while (index > 0) {
        index -= 1;
        const node = instance.node(path.nodes[index]) orelse continue;
        for (node.actions) |candidate| {
            if (!std.mem.eql(u8, candidate.id, id)) continue;
            return if (candidate.enabled) null else provider_disabled;
        }
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

/// The shape `src/plugins/dired/projection.zig` publishes: a vertical `files`
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

fn filesRow(comptime base: u32, comptime open_enabled: bool) semantic.scene.Node {
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
        const actions = [_]semantic.scene.Action{
            .{ .id = standard.open, .label = "Open", .enabled = open_enabled },
        };
    };
    return .{
        .id = @enumFromInt(base),
        .role = "files.row",
        .actions = &row.actions,
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

    fn focus(self: *Published, node: semantic.scene.NodeId, anchored: bool) !Focus {
        const path = (try self.instance().focusPath(node, &self.storage)).?;
        return .{ .path = path, .anchored = anchored };
    }
};

test "a focused files row offers activation and its grid, never expansion" {
    const rows = [_]semantic.scene.Node{ filesRow(10, true), filesRow(20, true) };
    var published = try Published.open(filesScene(&rows));
    defer published.deinit();

    var buffer: Buffer = undefined;
    const items = derive(published.instance(), try published.focus(@enumFromInt(13), false), &buffer);

    // The name field is a LEAF: absence, not a disabled "not expandable"
    // offer, is how §9.3 says nonapplicable is spelled.
    try t.expect(find(items, .toggle_expanded) == null);
    try t.expect(find(items, .activate).?.disabled == null);
    // Vertical list of rows, horizontal columns inside the focused row.
    try t.expect(find(items, .navigate_up) != null);
    try t.expect(find(items, .navigate_down) != null);
    try t.expect(find(items, .navigate_left) != null);
    try t.expect(find(items, .navigate_right) != null);
    // No anchor: `q` has nowhere to return to, so nothing is published.
    try t.expect(find(items, .back) == null);
}

test "a refused row action is disabled, an absent target is nothing at all" {
    const rows = [_]semantic.scene.Node{ filesRow(10, false), filesRow(20, true) };
    var published = try Published.open(filesScene(&rows));
    defer published.deinit();

    var buffer: Buffer = undefined;
    const refused = derive(published.instance(), try published.focus(@enumFromInt(13), false), &buffer);
    try t.expectEqualStrings(provider_disabled, find(refused, .activate).?.disabled.?);

    const bare = [_]semantic.scene.Node{
        .{ .id = @enumFromInt(2), .role = "files.name", .focusable = true, .content = .{ .label = "a" } },
        .{ .id = @enumFromInt(3), .role = "files.name", .focusable = true, .content = .{ .label = "b" } },
    };
    var flat = try Published.open(filesScene(&bare));
    defer flat.deinit();
    const items = derive(flat.instance(), try flat.focus(@enumFromInt(2), false), &buffer);
    try t.expect(find(items, .activate) == null);
    // A single-column list has no horizontal axis to move along.
    try t.expect(find(items, .navigate_up) != null);
    try t.expect(find(items, .navigate_left) == null);
}

test "a focused container offers expansion, and an anchored head offers back" {
    const rows = [_]semantic.scene.Node{ filesRow(10, true), filesRow(20, true) };
    var published = try Published.open(filesScene(&rows));
    defer published.deinit();

    var buffer: Buffer = undefined;
    const items = derive(published.instance(), try published.focus(@enumFromInt(10), true), &buffer);
    try t.expect(find(items, .toggle_expanded).?.disabled == null);
    try t.expect(find(items, .activate) != null);
    try t.expect(find(items, .back) != null);
    // The row's own horizontal axis is BELOW it; only the vertical list it
    // sits in is a movement axis for the row itself.
    try t.expect(find(items, .navigate_down) != null);
    try t.expect(find(items, .navigate_right) == null);
}

test "a container that refuses its own open/close route is disabled, not absent" {
    const actions = [_]semantic.scene.Action{
        .{ .id = standard.open_container, .label = "Open container", .enabled = false },
    };
    const children = [_]semantic.scene.Node{
        .{ .id = @enumFromInt(2), .focusable = true, .content = .{ .label = "only" } },
    };
    const root: semantic.scene.Node = .{
        .id = @enumFromInt(1),
        .role = "files",
        .focusable = true,
        .actions = &actions,
        .content = .{ .container = .{ .axis = .vertical, .children = &children } },
    };
    var published = try Published.open(root);
    defer published.deinit();

    var buffer: Buffer = undefined;
    const items = derive(published.instance(), try published.focus(@enumFromInt(1), false), &buffer);
    try t.expectEqualStrings(provider_disabled, find(items, .toggle_expanded).?.disabled.?);
    // One child on the axis: there is no sibling to move to.
    try t.expect(find(items, .navigate_up) == null);
}
