//! Retained semantic view instances with stable-node focus reconciliation.

const std = @import("std");
const semantic = @import("weft_semantic");

pub const Error = semantic.scene.ValidationError || std.mem.Allocator.Error || error{ InvalidOwner, OwnerMismatch, StaleView, FocusPathTooDeep };

pub const Movement = semantic.focus.Movement;

pub const Instance = struct {
    arena: std.heap.ArenaAllocator,
    descriptor: semantic.view.Descriptor,
    scene: semantic.scene.Node,
    focus_order: []const semantic.scene.NodeId,

    fn create(
        gpa: std.mem.Allocator,
        ref: semantic.view.Ref,
        owner: semantic.owner.Id,
        target: ?semantic.view.TargetBinding,
        revision: u64,
        root: semantic.scene.Node,
    ) Error!*Instance {
        try semantic.scene.validate(gpa, root);
        const self = try gpa.create(Instance);
        errdefer gpa.destroy(self);
        self.arena = .init(gpa);
        errdefer self.arena.deinit();
        const arena = self.arena.allocator();
        self.scene = try cloneNode(arena, root);
        var focusable: std.ArrayList(semantic.scene.NodeId) = .empty;
        defer focusable.deinit(gpa);
        try collectFocusable(gpa, self.scene, &focusable);
        self.focus_order = try arena.dupe(semantic.scene.NodeId, focusable.items);
        self.descriptor = .{
            .ref = ref,
            .owner = owner,
            .target = target,
            .revision = revision,
            .root = self.scene.id,
        };
        return self;
    }

    fn destroy(self: *Instance, gpa: std.mem.Allocator) void {
        self.arena.deinit();
        gpa.destroy(self);
    }

    pub fn node(self: *const Instance, id: semantic.scene.NodeId) ?*const semantic.scene.Node {
        return findNode(&self.scene, id);
    }

    pub fn containsFocusable(self: *const Instance, id: semantic.scene.NodeId) bool {
        for (self.focus_order) |candidate| if (candidate == id) return true;
        return false;
    }

    /// Stable ids survive a scene reorder. If a focused node vanished, choose
    /// the first remaining focusable node; no text offset participates.
    pub fn reconcileFocus(self: *const Instance, current: ?semantic.scene.NodeId) ?semantic.scene.NodeId {
        if (current) |id| if (self.containsFocusable(id)) return id;
        return if (self.focus_order.len == 0) null else self.focus_order[0];
    }

    pub fn move(self: *const Instance, current: ?semantic.scene.NodeId, movement: Movement) ?semantic.scene.NodeId {
        if (self.focus_order.len == 0) return null;
        return switch (movement) {
            .first => self.focus_order[0],
            .last => self.focus_order[self.focus_order.len - 1],
            .previous, .next => blk: {
                const id = self.reconcileFocus(current) orelse break :blk null;
                var index: usize = 0;
                while (index < self.focus_order.len and self.focus_order[index] != id) : (index += 1) {}
                if (movement == .previous) break :blk self.focus_order[index -| 1];
                break :blk self.focus_order[@min(index + 1, self.focus_order.len - 1)];
            },
        };
    }

    /// A row's primary field and the node that shows it (doc/chrome.md §5.2).
    pub const PrimaryField = struct { node: semantic.scene.NodeId, ref: semantic.scene.FieldRef };

    /// The field editing the row focused by `path` would edit: the primary
    /// field of the deepest node on the path that is one or holds one as a
    /// child, else the focused leaf itself when it is a field (a scene that
    /// marks nothing primary). Null when the row holds no field at all.
    pub fn primaryField(self: *const Instance, path: semantic.focus.Path) ?PrimaryField {
        var index = path.nodes.len;
        while (index > 0) {
            index -= 1;
            const at = self.node(path.nodes[index]) orelse continue;
            switch (at.content) {
                .field => |value| if (value.primary) return .{ .node = at.id, .ref = value.ref },
                .container => |container| for (container.children) |child| switch (child.content) {
                    .field => |value| if (value.primary) return .{ .node = child.id, .ref = value.ref },
                    else => {},
                },
                else => {},
            }
        }
        const leaf = self.node(path.leaf() orelse return null) orelse return null;
        return switch (leaf.content) {
            .field => |value| .{ .node = leaf.id, .ref = value.ref },
            else => null,
        };
    }

    pub fn focusPath(self: *const Instance, id: semantic.scene.NodeId, output: []semantic.scene.NodeId) Error!?semantic.focus.Path {
        var depth: usize = 0;
        const found = try buildPath(&self.scene, id, output, &depth);
        if (!found) return null;
        const node_value = self.node(id).?;
        const field_ref: ?semantic.scene.FieldRef = switch (node_value.content) {
            .field => |value| value.ref,
            else => null,
        };
        return .{ .view = self.descriptor.ref, .nodes = output[0..depth], .field = field_ref };
    }
};

pub const Registry = struct {
    authority: semantic.handle.Authority,
    slots: std.ArrayList(Slot) = .empty,

    const Slot = struct {
        generation: u32 = 1,
        instance: ?*Instance = null,
        /// The node a viewport's `reveal` last named in this view — a
        /// highlight the renderer draws beside the selection, never the
        /// selection itself. Kept across `replace` (node ids are stable); a
        /// node the new scene lacks reads as none.
        revealed: ?semantic.scene.NodeId = null,
    };

    pub fn init(authority: semantic.handle.Authority) Registry {
        return .{ .authority = authority };
    }

    pub fn deinit(self: *Registry, gpa: std.mem.Allocator) void {
        for (self.slots.items) |slot| if (slot.instance) |instance| instance.destroy(gpa);
        self.slots.deinit(gpa);
    }

    pub fn publish(
        self: *Registry,
        gpa: std.mem.Allocator,
        owner: semantic.owner.Id,
        target: ?semantic.view.TargetBinding,
        revision: u64,
        root: semantic.scene.Node,
    ) Error!semantic.view.Ref {
        if (!owner.isValid()) return error.InvalidOwner;
        for (self.slots.items, 0..) |*slot, index| {
            if (slot.instance != null) continue;
            const ref: semantic.view.Ref = .{ .authority = self.authority, .slot = @intCast(index), .generation = slot.generation };
            slot.instance = try Instance.create(gpa, ref, owner, target, revision, root);
            return ref;
        }
        const index = self.slots.items.len;
        const ref: semantic.view.Ref = .{ .authority = self.authority, .slot = @intCast(index), .generation = 1 };
        const instance = try Instance.create(gpa, ref, owner, target, revision, root);
        errdefer instance.destroy(gpa);
        try self.slots.append(gpa, .{ .instance = instance });
        return ref;
    }

    pub fn get(self: *const Registry, ref: semantic.view.Ref) ?*const Instance {
        if (ref.authority != self.authority or ref.slot >= self.slots.items.len) return null;
        const slot = self.slots.items[ref.slot];
        if (slot.generation != ref.generation) return null;
        return slot.instance;
    }

    /// Mark `node` as what view `ref` reveals (doc/model.md §2.5). This is
    /// the ONLY thing a reveal writes: no head's focus and no entry's
    /// selection is reachable from here, so revealing can never move what
    /// the user selected. Null reveals nothing (what was revealed is not in
    /// this view, or not yet). False when the view is gone or lacks the
    /// node, which reveals nothing too.
    pub fn reveal(self: *Registry, ref: semantic.view.Ref, node: ?semantic.scene.NodeId) bool {
        const instance = self.get(ref) orelse return false;
        const slot = &self.slots.items[ref.slot];
        slot.revealed = null;
        const id = node orelse return true;
        if (instance.node(id) == null) return false;
        slot.revealed = id;
        return true;
    }

    /// The node view `ref` reveals, while its scene still holds it.
    pub fn revealed(self: *const Registry, ref: semantic.view.Ref) ?semantic.scene.NodeId {
        const instance = self.get(ref) orelse return null;
        const node = self.slots.items[ref.slot].revealed orelse return null;
        return if (instance.node(node) != null) node else null;
    }

    pub fn replace(self: *Registry, gpa: std.mem.Allocator, owner: semantic.owner.Id, ref: semantic.view.Ref, revision: u64, root: semantic.scene.Node) Error!void {
        if (ref.authority != self.authority or ref.slot >= self.slots.items.len) return error.StaleView;
        const slot = &self.slots.items[ref.slot];
        if (slot.generation != ref.generation) return error.StaleView;
        const prior = slot.instance orelse return error.StaleView;
        if (prior.descriptor.owner != owner) return error.OwnerMismatch;
        const next = try Instance.create(gpa, ref, prior.descriptor.owner, prior.descriptor.target, revision, root);
        slot.instance = next;
        prior.destroy(gpa);
    }

    pub fn close(self: *Registry, gpa: std.mem.Allocator, owner: semantic.owner.Id, ref: semantic.view.Ref) bool {
        if (ref.authority != self.authority or ref.slot >= self.slots.items.len) return false;
        const slot = &self.slots.items[ref.slot];
        if (slot.generation != ref.generation) return false;
        const instance = slot.instance orelse return false;
        if (instance.descriptor.owner != owner) return false;
        self.retire(gpa, slot);
        return true;
    }

    pub fn closeOwner(self: *Registry, gpa: std.mem.Allocator, owner: semantic.owner.Id) usize {
        var closed: usize = 0;
        for (self.slots.items) |*slot| {
            const instance = slot.instance orelse continue;
            if (instance.descriptor.owner != owner) continue;
            self.retire(gpa, slot);
            closed += 1;
        }
        return closed;
    }

    fn retire(_: *Registry, gpa: std.mem.Allocator, slot: *Slot) void {
        slot.instance.?.destroy(gpa);
        slot.instance = null;
        slot.revealed = null;
        slot.generation +%= 1;
        if (slot.generation == 0) slot.generation = 1;
    }
};

fn cloneNode(gpa: std.mem.Allocator, node: semantic.scene.Node) std.mem.Allocator.Error!semantic.scene.Node {
    const facts = try gpa.alloc(semantic.scene.Fact, node.facts.len);
    for (node.facts, facts) |source, *destination| destination.* = .{
        .name = try gpa.dupe(u8, source.name),
        .value = try gpa.dupe(u8, source.value),
    };
    const actions = try gpa.alloc(semantic.scene.Action, node.actions.len);
    for (node.actions, actions) |source, *destination| destination.* = .{
        .id = try gpa.dupe(u8, source.id),
        .label = try gpa.dupe(u8, source.label),
        .enabled = source.enabled,
    };
    const content: semantic.scene.Content = switch (node.content) {
        .container => |container| blk: {
            const children = try gpa.alloc(semantic.scene.Node, container.children.len);
            for (container.children, children) |child, *destination| destination.* = try cloneNode(gpa, child);
            break :blk .{ .container = .{ .axis = container.axis, .children = children } };
        },
        .label => |label| .{ .label = try gpa.dupe(u8, label) },
        .field => |field_value| .{ .field = .{
            .ref = field_value.ref,
            .placeholder = try gpa.dupe(u8, field_value.placeholder),
            .single_line = field_value.single_line,
            .primary = field_value.primary,
        } },
        .action => |action| .{ .action = .{
            .action = try gpa.dupe(u8, action.action),
            .label = try gpa.dupe(u8, action.label),
            .enabled = action.enabled,
        } },
    };
    return .{
        .id = node.id,
        .role = try gpa.dupe(u8, node.role),
        .facts = facts,
        .actions = actions,
        .layout = node.layout,
        .focusable = node.focusable,
        .target = if (node.target) |link| try cloneTargetLink(gpa, link) else null,
        .content = content,
    };
}

fn cloneTargetLink(gpa: std.mem.Allocator, link: semantic.scene.TargetLink) std.mem.Allocator.Error!semantic.scene.TargetLink {
    return .{
        .target = link.target,
        .revision = link.revision,
        .location = switch (link.location) {
            .whole => .whole,
            .text => |range| .{ .text = range },
            .node => |value| .{ .node = try gpa.dupe(u8, value) },
            .provider => |value| .{ .provider = .{
                .schema = try gpa.dupe(u8, value.schema),
                .payload = try gpa.dupe(u8, value.payload),
            } },
        },
    };
}

fn collectFocusable(gpa: std.mem.Allocator, node: semantic.scene.Node, output: *std.ArrayList(semantic.scene.NodeId)) std.mem.Allocator.Error!void {
    if (node.focusable) try output.append(gpa, node.id);
    switch (node.content) {
        .container => |container| for (container.children) |child| try collectFocusable(gpa, child, output),
        else => {},
    }
}

fn findNode(node: *const semantic.scene.Node, id: semantic.scene.NodeId) ?*const semantic.scene.Node {
    if (node.id == id) return node;
    switch (node.content) {
        .container => |container| for (container.children) |*child| if (findNode(child, id)) |found| return found,
        else => {},
    }
    return null;
}

fn buildPath(node: *const semantic.scene.Node, id: semantic.scene.NodeId, output: []semantic.scene.NodeId, depth: *usize) Error!bool {
    if (depth.* >= output.len) return error.FocusPathTooDeep;
    output[depth.*] = node.id;
    depth.* += 1;
    if (node.id == id) return true;
    switch (node.content) {
        .container => |container| for (container.children) |*child| {
            if (try buildPath(child, id, output, depth)) return true;
            depth.* -= 1;
        },
        else => {},
    }
    return false;
}

fn labelNode(id: u64, label: []const u8) semantic.scene.Node {
    return .{ .id = @enumFromInt(id), .focusable = true, .content = .{ .label = label } };
}

test "stable focus survives row reorder without text anchors" {
    const owner: semantic.owner.Id = @enumFromInt(1);
    const other: semantic.owner.Id = @enumFromInt(2);
    const first_children = [_]semantic.scene.Node{ labelNode(2, "a"), labelNode(3, "b") };
    const first: semantic.scene.Node = .{ .id = @enumFromInt(1), .content = .{ .container = .{ .children = &first_children } } };
    var views = Registry.init(.here);
    defer views.deinit(std.testing.allocator);
    const ref = try views.publish(std.testing.allocator, owner, null, 1, first);
    try std.testing.expectEqual(@as(?semantic.scene.NodeId, @enumFromInt(3)), views.get(ref).?.reconcileFocus(@enumFromInt(3)));

    const reordered_children = [_]semantic.scene.Node{ labelNode(3, "b"), labelNode(2, "a") };
    const reordered: semantic.scene.Node = .{ .id = @enumFromInt(1), .content = .{ .container = .{ .children = &reordered_children } } };
    try std.testing.expectError(error.OwnerMismatch, views.replace(std.testing.allocator, other, ref, 2, reordered));
    try views.replace(std.testing.allocator, owner, ref, 2, reordered);
    const instance = views.get(ref).?;
    try std.testing.expectEqual(@as(?semantic.scene.NodeId, @enumFromInt(3)), instance.reconcileFocus(@enumFromInt(3)));
    try std.testing.expectEqual(@as(?semantic.scene.NodeId, @enumFromInt(2)), instance.move(@enumFromInt(3), .next));
}

test "a view's revealed node survives a republish that keeps it, and reads as none once it is gone" {
    const gpa = std.testing.allocator;
    const owner: semantic.owner.Id = @enumFromInt(1);
    const both = [_]semantic.scene.Node{ labelNode(2, "a"), labelNode(3, "b") };
    const root: semantic.scene.Node = .{ .id = @enumFromInt(1), .content = .{ .container = .{ .children = &both } } };
    var views = Registry.init(.here);
    defer views.deinit(gpa);
    const ref = try views.publish(gpa, owner, null, 1, root);
    try std.testing.expect(!views.reveal(ref, @enumFromInt(9)));
    try std.testing.expect(views.reveal(ref, @enumFromInt(3)));
    try views.replace(gpa, owner, ref, 2, root);
    try std.testing.expectEqual(@as(?semantic.scene.NodeId, @enumFromInt(3)), views.revealed(ref));
    const one = [_]semantic.scene.Node{labelNode(2, "a")};
    try views.replace(gpa, owner, ref, 3, .{ .id = @enumFromInt(1), .content = .{ .container = .{ .children = &one } } });
    try std.testing.expectEqual(@as(?semantic.scene.NodeId, null), views.revealed(ref));
}

test "focus path identifies a field semantically" {
    const owner: semantic.owner.Id = @enumFromInt(1);
    const field_ref: semantic.scene.FieldRef = .{ .authority = .here, .slot = 4, .generation = 1 };
    const child: semantic.scene.Node = .{ .id = @enumFromInt(2), .focusable = true, .content = .{ .field = .{ .ref = field_ref, .single_line = true } } };
    const root: semantic.scene.Node = .{ .id = @enumFromInt(1), .content = .{ .container = .{ .children = &.{child} } } };
    var views = Registry.init(.here);
    defer views.deinit(std.testing.allocator);
    const ref = try views.publish(std.testing.allocator, owner, null, 1, root);
    var path_storage: [8]semantic.scene.NodeId = undefined;
    const path = (try views.get(ref).?.focusPath(@enumFromInt(2), &path_storage)).?;
    try std.testing.expectEqual(@as(usize, 2), path.nodes.len);
    try std.testing.expectEqual(field_ref, path.field.?);
    try std.testing.expectEqual(@as(usize, 1), views.closeOwner(std.testing.allocator, owner));
    try std.testing.expect(views.get(ref) == null);
}
