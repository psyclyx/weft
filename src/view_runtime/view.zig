//! Retained semantic view instances with stable-node focus reconciliation.

const std = @import("std");
const kernel = @import("weft_kernel");

pub const Error = kernel.scene.ValidationError || std.mem.Allocator.Error || error{ StaleView, FocusPathTooDeep };

pub const Movement = kernel.focus.Movement;

pub const Instance = struct {
    arena: std.heap.ArenaAllocator,
    descriptor: kernel.view.Descriptor,
    scene: kernel.scene.Node,
    focus_order: []const kernel.scene.NodeId,

    fn create(
        gpa: std.mem.Allocator,
        ref: kernel.view.Ref,
        owner: []const u8,
        target: ?kernel.target.Ref,
        revision: u64,
        root: kernel.scene.Node,
    ) Error!*Instance {
        try kernel.scene.validate(gpa, root);
        const self = try gpa.create(Instance);
        errdefer gpa.destroy(self);
        self.arena = .init(gpa);
        errdefer self.arena.deinit();
        const arena = self.arena.allocator();
        self.scene = try cloneNode(arena, root);
        var focusable: std.ArrayList(kernel.scene.NodeId) = .empty;
        defer focusable.deinit(gpa);
        try collectFocusable(gpa, self.scene, &focusable);
        self.focus_order = try arena.dupe(kernel.scene.NodeId, focusable.items);
        self.descriptor = .{
            .ref = ref,
            .owner = try arena.dupe(u8, owner),
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

    pub fn node(self: *const Instance, id: kernel.scene.NodeId) ?*const kernel.scene.Node {
        return findNode(&self.scene, id);
    }

    pub fn containsFocusable(self: *const Instance, id: kernel.scene.NodeId) bool {
        for (self.focus_order) |candidate| if (candidate == id) return true;
        return false;
    }

    /// Stable ids survive a scene reorder. If a focused node vanished, choose
    /// the first remaining focusable node; no text offset participates.
    pub fn reconcileFocus(self: *const Instance, current: ?kernel.scene.NodeId) ?kernel.scene.NodeId {
        if (current) |id| if (self.containsFocusable(id)) return id;
        return if (self.focus_order.len == 0) null else self.focus_order[0];
    }

    pub fn move(self: *const Instance, current: ?kernel.scene.NodeId, movement: Movement) ?kernel.scene.NodeId {
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

    pub fn focusPath(self: *const Instance, id: kernel.scene.NodeId, output: []kernel.scene.NodeId) Error!?kernel.focus.Path {
        var depth: usize = 0;
        const found = try buildPath(&self.scene, id, output, &depth);
        if (!found) return null;
        const node_value = self.node(id).?;
        const field_ref: ?kernel.scene.FieldRef = switch (node_value.content) {
            .field => |value| value.ref,
            else => null,
        };
        return .{ .view = self.descriptor.ref, .nodes = output[0..depth], .field = field_ref };
    }
};

pub const Registry = struct {
    authority: kernel.handle.Authority,
    slots: std.ArrayList(Slot) = .empty,

    const Slot = struct {
        generation: u32 = 1,
        instance: ?*Instance = null,
    };

    pub fn init(authority: kernel.handle.Authority) Registry {
        return .{ .authority = authority };
    }

    pub fn deinit(self: *Registry, gpa: std.mem.Allocator) void {
        for (self.slots.items) |slot| if (slot.instance) |instance| instance.destroy(gpa);
        self.slots.deinit(gpa);
    }

    pub fn publish(
        self: *Registry,
        gpa: std.mem.Allocator,
        owner: []const u8,
        target: ?kernel.target.Ref,
        revision: u64,
        root: kernel.scene.Node,
    ) Error!kernel.view.Ref {
        for (self.slots.items, 0..) |*slot, index| {
            if (slot.instance != null) continue;
            const ref: kernel.view.Ref = .{ .authority = self.authority, .slot = @intCast(index), .generation = slot.generation };
            slot.instance = try Instance.create(gpa, ref, owner, target, revision, root);
            return ref;
        }
        const index = self.slots.items.len;
        const ref: kernel.view.Ref = .{ .authority = self.authority, .slot = @intCast(index), .generation = 1 };
        const instance = try Instance.create(gpa, ref, owner, target, revision, root);
        errdefer instance.destroy(gpa);
        try self.slots.append(gpa, .{ .instance = instance });
        return ref;
    }

    pub fn get(self: *const Registry, ref: kernel.view.Ref) ?*const Instance {
        if (ref.authority != self.authority or ref.slot >= self.slots.items.len) return null;
        const slot = self.slots.items[ref.slot];
        if (slot.generation != ref.generation) return null;
        return slot.instance;
    }

    pub fn replace(self: *Registry, gpa: std.mem.Allocator, ref: kernel.view.Ref, revision: u64, root: kernel.scene.Node) Error!void {
        if (ref.authority != self.authority or ref.slot >= self.slots.items.len) return error.StaleView;
        const slot = &self.slots.items[ref.slot];
        if (slot.generation != ref.generation) return error.StaleView;
        const prior = slot.instance orelse return error.StaleView;
        const next = try Instance.create(gpa, ref, prior.descriptor.owner, prior.descriptor.target, revision, root);
        slot.instance = next;
        prior.destroy(gpa);
    }

    pub fn close(self: *Registry, gpa: std.mem.Allocator, ref: kernel.view.Ref) bool {
        if (ref.authority != self.authority or ref.slot >= self.slots.items.len) return false;
        const slot = &self.slots.items[ref.slot];
        if (slot.generation != ref.generation) return false;
        const instance = slot.instance orelse return false;
        instance.destroy(gpa);
        slot.instance = null;
        slot.generation +%= 1;
        if (slot.generation == 0) slot.generation = 1;
        return true;
    }
};

fn cloneNode(gpa: std.mem.Allocator, node: kernel.scene.Node) std.mem.Allocator.Error!kernel.scene.Node {
    const facts = try gpa.alloc(kernel.scene.Fact, node.facts.len);
    for (node.facts, facts) |source, *destination| destination.* = .{
        .name = try gpa.dupe(u8, source.name),
        .value = try gpa.dupe(u8, source.value),
    };
    const actions = try gpa.alloc(kernel.scene.Action, node.actions.len);
    for (node.actions, actions) |source, *destination| destination.* = .{
        .id = try gpa.dupe(u8, source.id),
        .label = try gpa.dupe(u8, source.label),
        .enabled = source.enabled,
    };
    const content: kernel.scene.Content = switch (node.content) {
        .container => |container| blk: {
            const children = try gpa.alloc(kernel.scene.Node, container.children.len);
            for (container.children, children) |child, *destination| destination.* = try cloneNode(gpa, child);
            break :blk .{ .container = .{ .axis = container.axis, .children = children } };
        },
        .label => |label| .{ .label = try gpa.dupe(u8, label) },
        .field => |field_value| .{ .field = .{
            .ref = field_value.ref,
            .placeholder = try gpa.dupe(u8, field_value.placeholder),
            .single_line = field_value.single_line,
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
        .content = content,
    };
}

fn collectFocusable(gpa: std.mem.Allocator, node: kernel.scene.Node, output: *std.ArrayList(kernel.scene.NodeId)) std.mem.Allocator.Error!void {
    if (node.focusable) try output.append(gpa, node.id);
    switch (node.content) {
        .container => |container| for (container.children) |child| try collectFocusable(gpa, child, output),
        else => {},
    }
}

fn findNode(node: *const kernel.scene.Node, id: kernel.scene.NodeId) ?*const kernel.scene.Node {
    if (node.id == id) return node;
    switch (node.content) {
        .container => |container| for (container.children) |*child| if (findNode(child, id)) |found| return found,
        else => {},
    }
    return null;
}

fn buildPath(node: *const kernel.scene.Node, id: kernel.scene.NodeId, output: []kernel.scene.NodeId, depth: *usize) Error!bool {
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

fn labelNode(id: u64, label: []const u8) kernel.scene.Node {
    return .{ .id = @enumFromInt(id), .focusable = true, .content = .{ .label = label } };
}

test "stable focus survives row reorder without text anchors" {
    const first_children = [_]kernel.scene.Node{ labelNode(2, "a"), labelNode(3, "b") };
    const first: kernel.scene.Node = .{ .id = @enumFromInt(1), .content = .{ .container = .{ .children = &first_children } } };
    var views = Registry.init(.here);
    defer views.deinit(std.testing.allocator);
    const ref = try views.publish(std.testing.allocator, "test", null, 1, first);
    try std.testing.expectEqual(@as(?kernel.scene.NodeId, @enumFromInt(3)), views.get(ref).?.reconcileFocus(@enumFromInt(3)));

    const reordered_children = [_]kernel.scene.Node{ labelNode(3, "b"), labelNode(2, "a") };
    const reordered: kernel.scene.Node = .{ .id = @enumFromInt(1), .content = .{ .container = .{ .children = &reordered_children } } };
    try views.replace(std.testing.allocator, ref, 2, reordered);
    const instance = views.get(ref).?;
    try std.testing.expectEqual(@as(?kernel.scene.NodeId, @enumFromInt(3)), instance.reconcileFocus(@enumFromInt(3)));
    try std.testing.expectEqual(@as(?kernel.scene.NodeId, @enumFromInt(2)), instance.move(@enumFromInt(3), .next));
}

test "focus path identifies a field semantically" {
    const field_ref: kernel.scene.FieldRef = .{ .authority = .here, .slot = 4, .generation = 1 };
    const child: kernel.scene.Node = .{ .id = @enumFromInt(2), .focusable = true, .content = .{ .field = .{ .ref = field_ref, .single_line = true } } };
    const root: kernel.scene.Node = .{ .id = @enumFromInt(1), .content = .{ .container = .{ .children = &.{child} } } };
    var views = Registry.init(.here);
    defer views.deinit(std.testing.allocator);
    const ref = try views.publish(std.testing.allocator, "test", null, 1, root);
    var path_storage: [8]kernel.scene.NodeId = undefined;
    const path = (try views.get(ref).?.focusPath(@enumFromInt(2), &path_storage)).?;
    try std.testing.expectEqual(@as(usize, 2), path.nodes.len);
    try std.testing.expectEqual(field_ref, path.field.?);
}
