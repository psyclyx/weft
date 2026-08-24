//! Head-local interaction lifetimes and input resolution. This is deliberately
//! unaware of editor modes and menu/help presentation: a plugin publishes
//! semantic actions, while a head routes input to only its active interaction.

const std = @import("std");
const kernel = @import("weft_kernel");

pub const Error = std.mem.Allocator.Error || error{
    InvalidRoot,
    InvalidAction,
    DuplicateAction,
    InvalidBinding,
    DuplicateBinding,
    UnknownAction,
    NotActive,
};

pub const Instance = struct {
    arena: std.heap.ArenaAllocator,
    descriptor: kernel.interaction.Descriptor,

    fn create(
        gpa: std.mem.Allocator,
        ref: kernel.interaction.Ref,
        definition: kernel.interaction.Definition,
    ) Error!*Instance {
        try validate(gpa, definition);
        const self = try gpa.create(Instance);
        errdefer gpa.destroy(self);
        self.arena = .init(gpa);
        errdefer self.arena.deinit();
        const arena = self.arena.allocator();

        const actions = try arena.alloc(kernel.interaction.Action, definition.actions.len);
        for (definition.actions, actions) |source, *destination| destination.* = .{
            .id = try arena.dupe(u8, source.id),
            .label = try arena.dupe(u8, source.label),
            .enabled = source.enabled,
        };
        const bindings = try arena.alloc(kernel.interaction.Binding, definition.bindings.len);
        for (definition.bindings, bindings) |source, *destination| destination.* = .{
            .input = try arena.dupe(u8, source.input),
            .action = try arena.dupe(u8, source.action),
        };
        self.descriptor = .{
            .ref = ref,
            .role = definition.role,
            .view = definition.view,
            .root = definition.root,
            .actions = actions,
            .bindings = bindings,
            .default_action = if (definition.default_action) |value| try arena.dupe(u8, value) else null,
            .cancel_action = if (definition.cancel_action) |value| try arena.dupe(u8, value) else null,
            .presentation = try arena.dupe(u8, definition.presentation),
        };
        return self;
    }

    fn destroy(self: *Instance, gpa: std.mem.Allocator) void {
        self.arena.deinit();
        gpa.destroy(self);
    }

    pub fn action(self: *const Instance, id: []const u8) ?*const kernel.interaction.Action {
        for (self.descriptor.actions) |*candidate| {
            if (std.mem.eql(u8, candidate.id, id)) return candidate;
        }
        return null;
    }

    pub fn actionForInput(self: *const Instance, input: []const u8) ?*const kernel.interaction.Action {
        for (self.descriptor.bindings) |binding| {
            if (!std.mem.eql(u8, binding.input, input)) continue;
            const candidate = self.action(binding.action) orelse return null;
            return if (candidate.enabled) candidate else null;
        }
        return null;
    }
};

/// A LIFO interaction scope owned by one head. Closing out of order is an
/// explicit error, so one plugin cannot accidentally expose a buried dialog.
pub const Stack = struct {
    authority: kernel.handle.Authority = .here,
    slots: std.ArrayList(Slot) = .empty,
    order: std.ArrayList(kernel.interaction.Ref) = .empty,

    const Slot = struct {
        generation: u32 = 1,
        instance: ?*Instance = null,
    };

    pub const empty: Stack = .{};

    pub fn init(authority: kernel.handle.Authority) Stack {
        return .{ .authority = authority };
    }

    pub fn deinit(self: *Stack, gpa: std.mem.Allocator) void {
        for (self.slots.items) |slot| if (slot.instance) |instance| instance.destroy(gpa);
        self.slots.deinit(gpa);
        self.order.deinit(gpa);
        self.* = .{};
    }

    pub fn open(
        self: *Stack,
        gpa: std.mem.Allocator,
        definition: kernel.interaction.Definition,
    ) Error!kernel.interaction.Ref {
        var slot_index: usize = self.slots.items.len;
        for (self.slots.items, 0..) |slot, index| {
            if (slot.instance == null) {
                slot_index = index;
                break;
            }
        }
        if (slot_index == self.slots.items.len) try self.slots.append(gpa, .{});
        const slot = &self.slots.items[slot_index];
        const ref: kernel.interaction.Ref = .{
            .authority = self.authority,
            .slot = @intCast(slot_index),
            .generation = slot.generation,
        };
        const instance = try Instance.create(gpa, ref, definition);
        errdefer instance.destroy(gpa);
        try self.order.append(gpa, ref);
        slot.instance = instance;
        return ref;
    }

    pub fn active(self: *const Stack) ?*const Instance {
        if (self.order.items.len == 0) return null;
        return self.get(self.order.items[self.order.items.len - 1]);
    }

    pub fn get(self: *const Stack, ref: kernel.interaction.Ref) ?*const Instance {
        if (ref.authority != self.authority or ref.slot >= self.slots.items.len) return null;
        const slot = self.slots.items[ref.slot];
        if (slot.generation != ref.generation) return null;
        return slot.instance;
    }

    pub fn close(self: *Stack, gpa: std.mem.Allocator, ref: kernel.interaction.Ref) Error!void {
        if (self.order.items.len == 0 or !self.order.items[self.order.items.len - 1].eql(ref))
            return error.NotActive;
        const slot = &self.slots.items[ref.slot];
        const instance = slot.instance orelse return error.NotActive;
        _ = self.order.pop();
        instance.destroy(gpa);
        slot.instance = null;
        slot.generation +%= 1;
        if (slot.generation == 0) slot.generation = 1;
    }

    pub fn actionForInput(self: *const Stack, input: []const u8) ?*const kernel.interaction.Action {
        const current = self.active() orelse return null;
        return current.actionForInput(input);
    }
};

fn validate(gpa: std.mem.Allocator, definition: kernel.interaction.Definition) Error!void {
    if (@intFromEnum(definition.root) == 0) return error.InvalidRoot;
    var actions: std.StringHashMapUnmanaged(void) = .empty;
    defer actions.deinit(gpa);
    for (definition.actions) |action| {
        if (action.id.len == 0) return error.InvalidAction;
        const result = try actions.getOrPut(gpa, action.id);
        if (result.found_existing) return error.DuplicateAction;
    }
    var inputs: std.StringHashMapUnmanaged(void) = .empty;
    defer inputs.deinit(gpa);
    for (definition.bindings) |binding| {
        if (binding.input.len == 0 or binding.action.len == 0) return error.InvalidBinding;
        if (!actions.contains(binding.action)) return error.UnknownAction;
        const result = try inputs.getOrPut(gpa, binding.input);
        if (result.found_existing) return error.DuplicateBinding;
    }
    if (definition.default_action) |id| if (!actions.contains(id)) return error.UnknownAction;
    if (definition.cancel_action) |id| if (!actions.contains(id)) return error.UnknownAction;
}

const confirm_definition: kernel.interaction.Definition = .{
    .role = .dialog,
    .view = .{ .authority = .here, .slot = 1, .generation = 1 },
    .root = @enumFromInt(1),
    .actions = &.{
        .{ .id = "confirm", .label = "Apply" },
        .{ .id = "cancel", .label = "Cancel" },
    },
    .bindings = &.{
        .{ .input = "y", .action = "confirm" },
        .{ .input = "n", .action = "cancel" },
    },
    .default_action = "confirm",
    .cancel_action = "cancel",
    .presentation = "which-key-like",
};

test "interaction bindings are local to one head stack" {
    var a: Stack = .empty;
    defer a.deinit(std.testing.allocator);
    var b: Stack = .empty;
    defer b.deinit(std.testing.allocator);
    _ = try a.open(std.testing.allocator, confirm_definition);
    try std.testing.expectEqualStrings("confirm", a.actionForInput("y").?.id);
    try std.testing.expect(b.actionForInput("y") == null);
}

test "interactions close in strict nesting order and stale refs stay stale" {
    var stack: Stack = .empty;
    defer stack.deinit(std.testing.allocator);
    const below = try stack.open(std.testing.allocator, confirm_definition);
    const above = try stack.open(std.testing.allocator, confirm_definition);
    try std.testing.expectError(error.NotActive, stack.close(std.testing.allocator, below));
    try stack.close(std.testing.allocator, above);
    try stack.close(std.testing.allocator, below);
    try std.testing.expect(stack.get(below) == null);
    const next = try stack.open(std.testing.allocator, confirm_definition);
    try std.testing.expect(below.generation != next.generation);
}

test "interaction rejects a binding to an unknown action" {
    var stack: Stack = .empty;
    defer stack.deinit(std.testing.allocator);
    var invalid = confirm_definition;
    invalid.bindings = &.{.{ .input = "x", .action = "missing" }};
    try std.testing.expectError(error.UnknownAction, stack.open(std.testing.allocator, invalid));
}
