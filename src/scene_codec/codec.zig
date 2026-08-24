//! Canonical, bounded wire codec for the portable semantic kernel values.

const std = @import("std");
const kernel = @import("weft_kernel");
const schema = @import("weft_schema");

/// Re-exporting the named schema dependency makes the shared architecture
/// explicit to downstream guests without importing the wire implementation.
pub const Schema = schema.Schema;

pub const Limits = struct {
    pub const max_payload_bytes: usize = 16 * 1024 * 1024;
    pub const max_nodes: usize = 16 * 1024;
    pub const max_depth: usize = 256;
    pub const max_children: usize = 16 * 1024;
    pub const max_facts: usize = 16 * 1024;
    pub const max_string_bytes: usize = 1 * 1024 * 1024;
    pub const max_actions: usize = 4096;
    pub const max_bindings: usize = 4096;
};

pub const Error = error{
    Corrupt,
    LimitExceeded,
    InvalidData,
    Duplicate,
    BadReference,
} || std.mem.Allocator.Error;

const protocol_version: u8 = 1;
const magic = "WSC";
const scene_kind: u8 = 1;
const interaction_kind: u8 = 2;
const target_kind: u8 = 3;
const root_parent: u64 = std.math.maxInt(u32);

const Writer = struct {
    list: std.ArrayList(u8) = .empty,
    gpa: std.mem.Allocator,

    fn init(gpa: std.mem.Allocator) Writer {
        return .{ .gpa = gpa };
    }

    fn deinit(self: *Writer) void {
        self.list.deinit(self.gpa);
    }

    fn finish(self: *Writer) Error![]u8 {
        return self.list.toOwnedSlice(self.gpa);
    }

    fn append(self: *Writer, data: []const u8) Error!void {
        if (data.len > Limits.max_payload_bytes -| self.list.items.len) return error.LimitExceeded;
        try self.list.appendSlice(self.gpa, data);
    }

    fn byte(self: *Writer, value: u8) Error!void {
        try self.append(&.{value});
    }

    fn writeU16(self: *Writer, value: u16) Error!void {
        var buf: [2]u8 = undefined;
        std.mem.writeInt(u16, &buf, value, .little);
        try self.append(&buf);
    }

    fn writeU32(self: *Writer, value: u32) Error!void {
        var buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &buf, value, .little);
        try self.append(&buf);
    }

    fn writeU64(self: *Writer, value: u64) Error!void {
        var buf: [8]u8 = undefined;
        std.mem.writeInt(u64, &buf, value, .little);
        try self.append(&buf);
    }

    fn uv(self: *Writer, value: u64) Error!void {
        var x = value;
        while (true) {
            const low: u8 = @intCast(x & 0x7f);
            x >>= 7;
            if (x == 0) return self.byte(low);
            try self.byte(low | 0x80);
        }
    }

    fn string(self: *Writer, value: []const u8) Error!void {
        if (value.len > Limits.max_string_bytes) return error.LimitExceeded;
        try self.uv(value.len);
        try self.append(value);
    }

    fn count(self: *Writer, value: usize, limit: usize) Error!void {
        if (value > limit) return error.LimitExceeded;
        try self.uv(value);
    }
};

const Reader = struct {
    bytes: []const u8,
    pos: usize = 0,

    fn init(bytes: []const u8) Error!Reader {
        if (bytes.len > Limits.max_payload_bytes) return error.LimitExceeded;
        return .{ .bytes = bytes };
    }

    fn remaining(self: Reader) usize {
        return self.bytes.len - self.pos;
    }

    fn take(self: *Reader, n: usize) Error![]const u8 {
        if (n > self.remaining()) return error.Corrupt;
        const result = self.bytes[self.pos .. self.pos + n];
        self.pos += n;
        return result;
    }

    fn byte(self: *Reader) Error!u8 {
        return (try self.take(1))[0];
    }

    fn readU16(self: *Reader) Error!u16 {
        var buf: [2]u8 = undefined;
        @memcpy(&buf, try self.take(2));
        return std.mem.readInt(u16, &buf, .little);
    }

    fn readU32(self: *Reader) Error!u32 {
        var buf: [4]u8 = undefined;
        @memcpy(&buf, try self.take(4));
        return std.mem.readInt(u32, &buf, .little);
    }

    fn readU64(self: *Reader) Error!u64 {
        var buf: [8]u8 = undefined;
        @memcpy(&buf, try self.take(8));
        return std.mem.readInt(u64, &buf, .little);
    }

    fn uv(self: *Reader) Error!u64 {
        var value: u64 = 0;
        var shift: u6 = 0;
        var used: usize = 0;
        while (used < 10) : (used += 1) {
            const b = try self.byte();
            const bits = @as(u64, b & 0x7f);
            if (shift == 63 and bits > 1) return error.Corrupt;
            value |= bits << shift;
            if (b & 0x80 == 0) {
                // Canonical varints have no redundant high zero groups.
                if (used > 0 and bits == 0) return error.Corrupt;
                return value;
            }
            if (shift >= 63) return error.Corrupt;
            shift += 7;
        }
        return error.Corrupt;
    }

    fn count(self: *Reader, limit: usize) Error!usize {
        const raw = try self.uv();
        if (raw > limit or raw > std.math.maxInt(usize)) return error.LimitExceeded;
        return @intCast(raw);
    }

    fn string(self: *Reader, arena: std.mem.Allocator) Error![]const u8 {
        const n = try self.count(Limits.max_string_bytes);
        return try arena.dupe(u8, try self.take(n));
    }

    fn strictBool(self: *Reader) Error!bool {
        return switch (try self.byte()) {
            0 => false,
            1 => true,
            else => error.Corrupt,
        };
    }

    fn done(self: Reader) Error!void {
        if (self.pos != self.bytes.len) return error.Corrupt;
    }
};

fn header(writer: *Writer, kind: u8) Error!void {
    try writer.append(magic);
    try writer.byte(protocol_version);
    try writer.byte(kind);
}

fn checkHeader(reader: *Reader, expected_kind: u8) Error!void {
    if (!std.mem.eql(u8, try reader.take(magic.len), magic)) return error.Corrupt;
    if (try reader.byte() != protocol_version or try reader.byte() != expected_kind) return error.Corrupt;
}

fn nodeId(raw: u64) Error!kernel.scene.NodeId {
    if (raw == 0) return error.InvalidData;
    return @enumFromInt(raw);
}

fn axisTag(axis: kernel.scene.Axis) u8 {
    return switch (axis) {
        .horizontal => 0,
        .vertical => 1,
        .overlay => 2,
    };
}

fn axisFromTag(raw: u8) Error!kernel.scene.Axis {
    return switch (raw) {
        0 => .horizontal,
        1 => .vertical,
        2 => .overlay,
        else => error.Corrupt,
    };
}

fn roleTag(role: kernel.interaction.Role) u8 {
    return switch (role) {
        .dialog => 0,
        .picker => 1,
        .popup => 2,
        .custom => 3,
    };
}

fn roleFromTag(raw: u8) Error!kernel.interaction.Role {
    return switch (raw) {
        0 => .dialog,
        1 => .picker,
        2 => .popup,
        3 => .custom,
        else => error.Corrupt,
    };
}

fn targetKindTag(kind: kernel.target.Kind) u8 {
    return switch (kind) {
        .unknown => 0,
        .file => 1,
        .directory => 2,
        .synthetic => 3,
    };
}

fn writeHandle(writer: *Writer, handle: anytype) Error!void {
    const wire = handle.toWire();
    try writer.writeU32(wire.authority);
    try writer.writeU32(wire.slot);
    try writer.writeU32(wire.generation);
}

fn readFieldHandle(reader: *Reader) Error!kernel.scene.FieldRef {
    return .fromWire(.{ .authority = try reader.readU32(), .slot = try reader.readU32(), .generation = try reader.readU32() });
}

fn readViewHandle(reader: *Reader) Error!kernel.view.Ref {
    return .fromWire(.{ .authority = try reader.readU32(), .slot = try reader.readU32(), .generation = try reader.readU32() });
}

fn ensureUnique(gpa: std.mem.Allocator, values: []const []const u8) Error!void {
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(gpa);
    for (values) |value| {
        const result = try seen.getOrPut(gpa, value);
        if (result.found_existing) return error.Duplicate;
    }
}

// ── Scene ────────────────────────────────────────────────────────────────

const SceneCount = struct { nodes: usize = 0, depth: usize = 0 };

fn validateSceneNode(gpa: std.mem.Allocator, node: kernel.scene.Node, seen: *std.AutoHashMapUnmanaged(u64, void), depth: usize, count: *SceneCount) Error!void {
    if (depth > Limits.max_depth) return error.LimitExceeded;
    count.depth = @max(count.depth, depth);
    count.nodes += 1;
    if (count.nodes > Limits.max_nodes) return error.LimitExceeded;
    const raw_id = @intFromEnum(node.id);
    if (raw_id == 0) return error.InvalidData;
    const id_result = try seen.getOrPut(gpa, raw_id);
    if (id_result.found_existing) return error.Duplicate;
    if (node.role.len > Limits.max_string_bytes) return error.LimitExceeded;
    if (node.facts.len > Limits.max_facts) return error.LimitExceeded;
    var fact_names: std.StringHashMapUnmanaged(void) = .empty;
    defer fact_names.deinit(gpa);
    for (node.facts) |fact| {
        if (fact.name.len > Limits.max_string_bytes or fact.value.len > Limits.max_string_bytes) return error.LimitExceeded;
        const result = try fact_names.getOrPut(gpa, fact.name);
        if (result.found_existing) return error.Duplicate;
    }
    switch (node.content) {
        .container => |container| {
            if (container.children.len > Limits.max_children) return error.LimitExceeded;
            for (container.children) |child| try validateSceneNode(gpa, child, seen, depth + 1, count);
        },
        .label => |label| if (label.len > Limits.max_string_bytes) return error.LimitExceeded,
        .field => |field| if (field.placeholder.len > Limits.max_string_bytes) return error.LimitExceeded,
        .action => |action| {
            if (action.action.len > Limits.max_string_bytes or action.label.len > Limits.max_string_bytes) return error.LimitExceeded;
        },
    }
}

fn countScene(gpa: std.mem.Allocator, root: kernel.scene.Node) Error!usize {
    var seen: std.AutoHashMapUnmanaged(u64, void) = .empty;
    defer seen.deinit(gpa);
    var count: SceneCount = .{};
    try validateSceneNode(gpa, root, &seen, 0, &count);
    return count.nodes;
}

fn encodeSceneNode(writer: *Writer, node: kernel.scene.Node, parent: u32, index: *u32) Error!void {
    const this_index = index.*;
    index.* += 1;
    try writer.writeU64(@intFromEnum(node.id));
    try writer.uv(parent);
    try writer.string(node.role);
    try writer.count(node.facts.len, Limits.max_facts);
    for (node.facts) |fact| {
        try writer.string(fact.name);
        try writer.string(fact.value);
    }
    try writer.writeU16(node.layout.grow);
    try writer.byte(if (node.layout.column != null) 1 else 0);
    if (node.layout.column) |value| try writer.writeU16(value);
    try writer.byte(if (node.layout.min_cells != null) 1 else 0);
    if (node.layout.min_cells) |value| try writer.writeU16(value);
    try writer.byte(if (node.focusable) 1 else 0);
    switch (node.content) {
        .container => |container| {
            try writer.byte(0);
            try writer.byte(axisTag(container.axis));
            try writer.count(container.children.len, Limits.max_children);
            for (container.children) |child| try encodeSceneNode(writer, child, this_index, index);
        },
        .label => |label| {
            try writer.byte(1);
            try writer.string(label);
        },
        .field => |field| {
            try writer.byte(2);
            try writeHandle(writer, field.ref);
            try writer.string(field.placeholder);
            try writer.byte(if (field.single_line) 1 else 0);
        },
        .action => |action| {
            try writer.byte(3);
            try writer.string(action.action);
            try writer.string(action.label);
            try writer.byte(if (action.enabled) 1 else 0);
        },
    }
}

pub fn encodeScene(gpa: std.mem.Allocator, root: kernel.scene.Node) Error![]u8 {
    const count = try countScene(gpa, root);
    var writer = Writer.init(gpa);
    errdefer writer.deinit();
    try header(&writer, scene_kind);
    try writer.count(count, Limits.max_nodes);
    var index: u32 = 0;
    try encodeSceneNode(&writer, root, @intCast(root_parent), &index);
    return writer.finish();
}

const TempContainer = struct { axis: kernel.scene.Axis, child_count: usize, children: []u32 = &.{} };
const TempField = struct { ref: kernel.scene.FieldRef, placeholder: []const u8, single_line: bool };
const TempAction = struct { action: []const u8, label: []const u8, enabled: bool };

const TempContent = union(enum) {
    container: TempContainer,
    label: []const u8,
    field: TempField,
    action: TempAction,
};

const TempNode = struct {
    id: kernel.scene.NodeId,
    parent: u32,
    role: []const u8,
    facts: []const kernel.scene.Fact,
    layout: kernel.scene.Layout,
    focusable: bool,
    content: TempContent,
};

pub const OwnedScene = struct {
    arena: std.heap.ArenaAllocator,
    root: *const kernel.scene.Node,

    pub fn deinit(self: *OwnedScene) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

fn readFacts(reader: *Reader, arena: std.mem.Allocator) Error![]const kernel.scene.Fact {
    const count = try reader.count(Limits.max_facts);
    const facts = try arena.alloc(kernel.scene.Fact, count);
    var names: std.StringHashMapUnmanaged(void) = .empty;
    defer names.deinit(arena);
    for (facts) |*fact| {
        fact.name = try reader.string(arena);
        fact.value = try reader.string(arena);
        const result = try names.getOrPut(arena, fact.name);
        if (result.found_existing) return error.Duplicate;
    }
    return facts;
}

fn readTempNode(reader: *Reader, arena: std.mem.Allocator) Error!TempNode {
    const id = try nodeId(try reader.readU64());
    const parent_raw = try reader.uv();
    if (parent_raw > root_parent) return error.BadReference;
    const role = try reader.string(arena);
    const facts = try readFacts(reader, arena);
    const grow = try reader.readU16();
    const column = if (try reader.strictBool()) try reader.readU16() else null;
    const min_cells = if (try reader.strictBool()) try reader.readU16() else null;
    const focusable = try reader.strictBool();
    const content: TempContent = switch (try reader.byte()) {
        0 => .{ .container = TempContainer{ .axis = try axisFromTag(try reader.byte()), .child_count = try reader.count(Limits.max_children) } },
        1 => .{ .label = try reader.string(arena) },
        2 => .{ .field = TempField{ .ref = try readFieldHandle(reader), .placeholder = try reader.string(arena), .single_line = try reader.strictBool() } },
        3 => .{ .action = TempAction{ .action = try reader.string(arena), .label = try reader.string(arena), .enabled = try reader.strictBool() } },
        else => return error.Corrupt,
    };
    return .{
        .id = id,
        .parent = @intCast(parent_raw),
        .role = role,
        .facts = facts,
        .layout = .{ .grow = grow, .column = column, .min_cells = min_cells },
        .focusable = focusable,
        .content = content,
    };
}

fn validateParents(arena: std.mem.Allocator, records: []TempNode) Error!void {
    if (records.len == 0 or records[0].parent != @as(u32, @intCast(root_parent))) return error.BadReference;
    var ids: std.AutoHashMapUnmanaged(u64, void) = .empty;
    defer ids.deinit(arena);
    for (records, 0..) |record, i| {
        const result = try ids.getOrPut(arena, @intFromEnum(record.id));
        if (result.found_existing) return error.Duplicate;
        if (i > 0 and record.parent >= i) return error.BadReference;
    }
    var stack: [Limits.max_depth]struct { index: usize, remaining: usize } = undefined;
    var stack_len: usize = 0;
    for (records, 0..) |*record, i| {
        while (stack_len > 0 and stack[stack_len - 1].remaining == 0) stack_len -= 1;
        if (i > 0) {
            if (stack_len == 0 or record.parent != stack[stack_len - 1].index) return error.BadReference;
            stack[stack_len - 1].remaining -= 1;
        }
        if (record.content == .container) {
            if (stack_len == Limits.max_depth) return error.LimitExceeded;
            const children = try arena.alloc(u32, record.content.container.child_count);
            @memset(children, 0);
            record.content.container.children = children;
            stack[stack_len] = .{ .index = i, .remaining = children.len };
            stack_len += 1;
        }
    }
    while (stack_len > 0 and stack[stack_len - 1].remaining == 0) stack_len -= 1;
    if (stack_len != 0) return error.BadReference;
    for (records, 0..) |*record, i| {
        if (i == 0) continue;
        const parent = &records[record.parent];
        if (parent.content != .container) return error.BadReference;
        var found = false;
        for (parent.content.container.children) |*slot| {
            if (slot.* == 0 and !found) {
                slot.* = @intCast(i);
                found = true;
                break;
            }
        }
        if (!found) return error.BadReference;
    }
}

fn materializeNode(arena: std.mem.Allocator, records: []const TempNode, index: usize, depth: usize) Error!*kernel.scene.Node {
    if (depth > Limits.max_depth or index >= records.len) return error.BadReference;
    const record = records[index];
    const node = try arena.create(kernel.scene.Node);
    node.* = .{ .id = record.id, .role = record.role, .facts = record.facts, .layout = record.layout, .focusable = record.focusable, .content = undefined };
    switch (record.content) {
        .container => |container| {
            const children = try arena.alloc(kernel.scene.Node, container.children.len);
            for (children, container.children) |*child, child_index| child.* = (try materializeNode(arena, records, child_index, depth + 1)).*;
            node.content = .{ .container = .{ .axis = container.axis, .children = children } };
        },
        .label => |label| node.content = .{ .label = label },
        .field => |field| node.content = .{ .field = .{ .ref = field.ref, .placeholder = field.placeholder, .single_line = field.single_line } },
        .action => |action| node.content = .{ .action = .{ .action = action.action, .label = action.label, .enabled = action.enabled } },
    }
    return node;
}

pub fn decodeScene(gpa: std.mem.Allocator, bytes: []const u8) Error!OwnedScene {
    var reader = try Reader.init(bytes);
    try checkHeader(&reader, scene_kind);
    const arena_init = std.heap.ArenaAllocator.init(gpa);
    var owned: OwnedScene = .{ .arena = arena_init, .root = undefined };
    errdefer owned.arena.deinit();
    const arena = owned.arena.allocator();
    const count = try reader.count(Limits.max_nodes);
    const records = try arena.alloc(TempNode, count);
    for (records) |*record| record.* = try readTempNode(&reader, arena);
    try validateParents(arena, records);
    try reader.done();
    owned.root = try materializeNode(arena, records, 0, 0);
    return owned;
}

// ── Interaction ─────────────────────────────────────────────────────────

fn validateActionLists(gpa: std.mem.Allocator, actions: []const kernel.interaction.Action, bindings: []const kernel.interaction.Binding) Error!void {
    if (actions.len > Limits.max_actions or bindings.len > Limits.max_bindings) return error.LimitExceeded;
    var action_ids: std.StringHashMapUnmanaged(void) = .empty;
    defer action_ids.deinit(gpa);
    for (actions) |action| {
        if (action.id.len == 0 or action.id.len > Limits.max_string_bytes or action.label.len > Limits.max_string_bytes) return error.InvalidData;
        const result = try action_ids.getOrPut(gpa, action.id);
        if (result.found_existing) return error.Duplicate;
    }
    var inputs: std.StringHashMapUnmanaged(void) = .empty;
    defer inputs.deinit(gpa);
    for (bindings) |binding| {
        if (binding.input.len == 0 or binding.action.len == 0 or binding.input.len > Limits.max_string_bytes or binding.action.len > Limits.max_string_bytes) return error.InvalidData;
        if (!action_ids.contains(binding.action)) return error.BadReference;
        const result = try inputs.getOrPut(gpa, binding.input);
        if (result.found_existing) return error.Duplicate;
    }
}

fn containsString(values: []const []const u8, needle: []const u8) bool {
    for (values) |value| if (std.mem.eql(u8, value, needle)) return true;
    return false;
}

fn optionalString(writer: *Writer, value: ?[]const u8) Error!void {
    try writer.byte(if (value != null) 1 else 0);
    if (value) |string| try writer.string(string);
}

fn readOptionalString(reader: *Reader, arena: std.mem.Allocator) Error!?[]const u8 {
    return if (try reader.strictBool()) try reader.string(arena) else null;
}

pub fn encodeInteraction(gpa: std.mem.Allocator, definition: kernel.interaction.Definition) Error![]u8 {
    try validateActionLists(gpa, definition.actions, definition.bindings);
    if (definition.presentation.len > Limits.max_string_bytes) return error.LimitExceeded;
    if (@intFromEnum(definition.root) == 0) return error.InvalidData;
    var action_ids = std.ArrayList([]const u8).empty;
    defer action_ids.deinit(gpa);
    for (definition.actions) |action| try action_ids.append(gpa, action.id);
    if (definition.default_action) |id| if (!containsString(action_ids.items, id)) return error.BadReference;
    if (definition.cancel_action) |id| if (!containsString(action_ids.items, id)) return error.BadReference;
    var writer = Writer.init(gpa);
    errdefer writer.deinit();
    try header(&writer, interaction_kind);
    try writeHandle(&writer, definition.view);
    try writer.byte(roleTag(definition.role));
    try writer.writeU64(@intFromEnum(definition.root));
    try writer.count(definition.actions.len, Limits.max_actions);
    for (definition.actions) |action| {
        try writer.string(action.id);
        try writer.string(action.label);
        try writer.byte(if (action.enabled) 1 else 0);
    }
    try writer.count(definition.bindings.len, Limits.max_bindings);
    for (definition.bindings) |binding| {
        try writer.string(binding.input);
        try writer.string(binding.action);
    }
    try optionalString(&writer, definition.default_action);
    try optionalString(&writer, definition.cancel_action);
    try writer.string(definition.presentation);
    return writer.finish();
}

pub const OwnedInteraction = struct {
    arena: std.heap.ArenaAllocator,
    value: kernel.interaction.Definition,

    pub fn deinit(self: *OwnedInteraction) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub fn decodeInteraction(gpa: std.mem.Allocator, bytes: []const u8) Error!OwnedInteraction {
    var reader = try Reader.init(bytes);
    try checkHeader(&reader, interaction_kind);
    var owned: OwnedInteraction = .{ .arena = std.heap.ArenaAllocator.init(gpa), .value = undefined };
    errdefer owned.arena.deinit();
    const arena = owned.arena.allocator();
    const view_ref = try readViewHandle(&reader);
    const role = try roleFromTag(try reader.byte());
    const root = try nodeId(try reader.readU64());
    const actions = try arena.alloc(kernel.interaction.Action, try reader.count(Limits.max_actions));
    var action_ids = std.StringHashMapUnmanaged(void).empty;
    defer action_ids.deinit(arena);
    for (actions) |*action| {
        action.id = try reader.string(arena);
        action.label = try reader.string(arena);
        action.enabled = try reader.strictBool();
        const result = try action_ids.getOrPut(arena, action.id);
        if (result.found_existing or action.id.len == 0) return error.Duplicate;
    }
    const bindings = try arena.alloc(kernel.interaction.Binding, try reader.count(Limits.max_bindings));
    var inputs = std.StringHashMapUnmanaged(void).empty;
    defer inputs.deinit(arena);
    for (bindings) |*binding| {
        binding.input = try reader.string(arena);
        binding.action = try reader.string(arena);
        if (binding.input.len == 0 or !action_ids.contains(binding.action)) return error.BadReference;
        const result = try inputs.getOrPut(arena, binding.input);
        if (result.found_existing) return error.Duplicate;
    }
    const default_action = try readOptionalString(&reader, arena);
    const cancel_action = try readOptionalString(&reader, arena);
    const presentation = try reader.string(arena);
    if (default_action) |id| if (!action_ids.contains(id)) return error.BadReference;
    if (cancel_action) |id| if (!action_ids.contains(id)) return error.BadReference;
    try reader.done();
    owned.value = .{ .view = view_ref, .role = role, .root = root, .actions = actions, .bindings = bindings, .default_action = default_action, .cancel_action = cancel_action, .presentation = presentation };
    return owned;
}

// ── Target ──────────────────────────────────────────────────────────────

fn validateFacts(gpa: std.mem.Allocator, facts: []const kernel.target.Fact) Error!void {
    if (facts.len > Limits.max_facts) return error.LimitExceeded;
    var names = std.StringHashMapUnmanaged(void).empty;
    defer names.deinit(gpa);
    for (facts) |fact| {
        if (fact.name.len > Limits.max_string_bytes or fact.value.len > Limits.max_string_bytes) return error.LimitExceeded;
        const result = try names.getOrPut(gpa, fact.name);
        if (result.found_existing) return error.Duplicate;
    }
}

pub fn encodeTarget(gpa: std.mem.Allocator, definition: kernel.target.Definition) Error![]u8 {
    try validateFacts(gpa, definition.facts);
    if (definition.display_name.len > Limits.max_string_bytes) return error.LimitExceeded;
    var writer = Writer.init(gpa);
    errdefer writer.deinit();
    try header(&writer, target_kind);
    try writer.byte(targetKindTag(definition.kind));
    if (definition.kind == .synthetic) try writer.string(definition.kind.synthetic);
    try writer.string(definition.display_name);
    try writer.count(definition.facts.len, Limits.max_facts);
    for (definition.facts) |fact| {
        try writer.string(fact.name);
        try writer.string(fact.value);
    }
    return writer.finish();
}

pub const OwnedTarget = struct {
    arena: std.heap.ArenaAllocator,
    value: kernel.target.Definition,

    pub fn deinit(self: *OwnedTarget) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub fn decodeTarget(gpa: std.mem.Allocator, bytes: []const u8) Error!OwnedTarget {
    var reader = try Reader.init(bytes);
    try checkHeader(&reader, target_kind);
    var owned: OwnedTarget = .{ .arena = std.heap.ArenaAllocator.init(gpa), .value = undefined };
    errdefer owned.arena.deinit();
    const arena = owned.arena.allocator();
    const kind_tag = try reader.byte();
    const kind: kernel.target.Kind = switch (kind_tag) {
        0 => .unknown,
        1 => .file,
        2 => .directory,
        3 => .{ .synthetic = try reader.string(arena) },
        else => return error.Corrupt,
    };
    const display_name = try reader.string(arena);
    const facts = try arena.alloc(kernel.target.Fact, try reader.count(Limits.max_facts));
    var names = std.StringHashMapUnmanaged(void).empty;
    defer names.deinit(arena);
    for (facts) |*fact| {
        fact.name = try reader.string(arena);
        fact.value = try reader.string(arena);
        const result = try names.getOrPut(arena, fact.name);
        if (result.found_existing) return error.Duplicate;
    }
    try reader.done();
    owned.value = .{ .kind = kind, .display_name = display_name, .facts = facts };
    return owned;
}

// ── Tests ────────────────────────────────────────────────────────────────

const t = std.testing;

test "scene codec: preorder scene round-trip preserves semantic fields" {
    const field_ref: kernel.scene.FieldRef = .{ .authority = .here, .slot = 4, .generation = 2 };
    const leaf = kernel.scene.Node{ .id = @enumFromInt(2), .role = "button", .facts = &.{.{ .name = "kind", .value = "ok" }}, .layout = .{ .grow = 3, .column = 2 }, .focusable = true, .content = .{ .field = .{ .ref = field_ref, .placeholder = "name", .single_line = true } } };
    const root = kernel.scene.Node{ .id = @enumFromInt(1), .role = "root", .content = .{ .container = .{ .axis = .horizontal, .children = &.{leaf} } } };
    const bytes = try encodeScene(t.allocator, root);
    defer t.allocator.free(bytes);
    var decoded = try decodeScene(t.allocator, bytes);
    defer decoded.deinit();
    try t.expectEqual(@as(u64, 1), @intFromEnum(decoded.root.id));
    try t.expectEqualStrings("root", decoded.root.role);
    try t.expectEqual(kernel.scene.Axis.horizontal, decoded.root.content.container.axis);
    try t.expectEqual(@as(usize, 1), decoded.root.content.container.children.len);
    const child = &decoded.root.content.container.children[0];
    try t.expectEqual(@as(u64, 2), @intFromEnum(child.id));
    try t.expectEqualStrings("name", child.content.field.placeholder);
    try t.expectEqual(field_ref, child.content.field.ref);
}

test "interaction and target codecs round-trip defaults, handles, variants, and facts" {
    const definition: kernel.interaction.Definition = .{ .view = .{ .authority = .here, .slot = 3, .generation = 4 }, .role = .picker, .root = @enumFromInt(9), .actions = &.{.{ .id = "ok", .label = "OK", .enabled = true }}, .bindings = &.{.{ .input = "enter", .action = "ok" }}, .default_action = "ok", .cancel_action = null, .presentation = "compact" };
    const interaction_bytes = try encodeInteraction(t.allocator, definition);
    defer t.allocator.free(interaction_bytes);
    var interaction_value = try decodeInteraction(t.allocator, interaction_bytes);
    defer interaction_value.deinit();
    try t.expectEqual(definition.view, interaction_value.value.view);
    try t.expectEqualStrings("ok", interaction_value.value.default_action.?);
    try t.expectEqualStrings("enter", interaction_value.value.bindings[0].input);

    const target_definition: kernel.target.Definition = .{ .kind = .{ .synthetic = "dired" }, .display_name = "Files", .facts = &.{.{ .name = "scope", .value = "project" }} };
    const target_bytes = try encodeTarget(t.allocator, target_definition);
    defer t.allocator.free(target_bytes);
    var target_value = try decodeTarget(t.allocator, target_bytes);
    defer target_value.deinit();
    try t.expectEqualStrings("dired", target_value.value.kind.synthetic);
    try t.expectEqualStrings("project", target_value.value.facts[0].value);
}

test "scene codec: hostile tags, truncation, trailing bytes, and duplicate IDs refuse" {
    const root: kernel.scene.Node = .{ .id = @enumFromInt(1), .content = .{ .label = "x" } };
    const bytes = try encodeScene(t.allocator, root);
    defer t.allocator.free(bytes);
    try t.expectError(error.Corrupt, decodeScene(t.allocator, bytes[0 .. bytes.len - 1]));
    var trailing = try t.allocator.alloc(u8, bytes.len + 1);
    defer t.allocator.free(trailing);
    @memcpy(trailing[0..bytes.len], bytes);
    trailing[bytes.len] = 0;
    try t.expectError(error.Corrupt, decodeScene(t.allocator, trailing));
    try t.expectError(error.Corrupt, decodeTarget(t.allocator, &.{ 'W', 'S', 'C', 1, target_kind, 99 }));

    const duplicate = kernel.scene.Node{ .id = @enumFromInt(1), .content = .{ .container = .{ .children = &.{.{ .id = @enumFromInt(1), .content = .{ .label = "bad" } }} } } };
    try t.expectError(error.Duplicate, encodeScene(t.allocator, duplicate));
}

test "scene codec: duplicate facts/actions/bindings and invalid interaction tags refuse" {
    const duplicate_facts: kernel.scene.Node = .{
        .id = @enumFromInt(1),
        .facts = &.{ .{ .name = "same", .value = "a" }, .{ .name = "same", .value = "b" } },
        .content = .{ .label = "x" },
    };
    try t.expectError(error.Duplicate, encodeScene(t.allocator, duplicate_facts));

    const duplicate_actions: kernel.interaction.Definition = .{
        .view = .{ .authority = .here, .slot = 1, .generation = 1 },
        .role = .dialog,
        .root = @enumFromInt(1),
        .actions = &.{ .{ .id = "go", .label = "Go" }, .{ .id = "go", .label = "Again" } },
    };
    try t.expectError(error.Duplicate, encodeInteraction(t.allocator, duplicate_actions));

    const duplicate_bindings: kernel.interaction.Definition = .{
        .view = .{ .authority = .here, .slot = 1, .generation = 1 },
        .role = .dialog,
        .root = @enumFromInt(1),
        .actions = &.{.{ .id = "go", .label = "Go" }},
        .bindings = &.{ .{ .input = "x", .action = "go" }, .{ .input = "x", .action = "go" } },
    };
    try t.expectError(error.Duplicate, encodeInteraction(t.allocator, duplicate_bindings));

    const interaction_definition: kernel.interaction.Definition = .{
        .view = .{ .authority = .here, .slot = 1, .generation = 1 },
        .role = .dialog,
        .root = @enumFromInt(1),
        .actions = &.{.{ .id = "go", .label = "Go" }},
    };
    const encoded = try encodeInteraction(t.allocator, interaction_definition);
    defer t.allocator.free(encoded);
    var invalid = try t.allocator.dupe(u8, encoded);
    defer t.allocator.free(invalid);
    // Header is 5 bytes; a view handle is three little-endian u32s.
    invalid[5 + 12] = 0xff;
    try t.expectError(error.Corrupt, decodeInteraction(t.allocator, invalid));
}

test "scene codec: forward parent references and invalid target tags refuse" {
    const child: kernel.scene.Node = .{ .id = @enumFromInt(2), .content = .{ .label = "child" } };
    const root: kernel.scene.Node = .{ .id = @enumFromInt(1), .content = .{ .container = .{ .children = &.{child} } } };
    const encoded = try encodeScene(t.allocator, root);
    defer t.allocator.free(encoded);
    var invalid = try t.allocator.dupe(u8, encoded);
    defer t.allocator.free(invalid);
    var reader = try Reader.init(invalid);
    try checkHeader(&reader, scene_kind);
    _ = try reader.count(Limits.max_nodes);
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    _ = try readTempNode(&reader, arena.allocator());
    // The child record starts with its id, followed by its parent varint.
    reader.pos += 8;
    invalid[reader.pos] = 2; // parent index must be earlier, not forward.
    try t.expectError(error.BadReference, decodeScene(t.allocator, invalid));

    const target_definition: kernel.target.Definition = .{ .kind = .file, .display_name = "f" };
    const target_bytes = try encodeTarget(t.allocator, target_definition);
    defer t.allocator.free(target_bytes);
    var invalid_target = try t.allocator.dupe(u8, target_bytes);
    defer t.allocator.free(invalid_target);
    invalid_target[5] = 0xfe;
    try t.expectError(error.Corrupt, decodeTarget(t.allocator, invalid_target));
}

test "scene codec: limits reject excessive child counts and action bindings" {
    var children: [Limits.max_children + 1]kernel.scene.Node = undefined;
    for (&children, 0..) |*child, i| child.* = .{ .id = @enumFromInt(@as(u64, i + 2)), .content = .{ .label = "x" } };
    const too_many: kernel.scene.Node = .{ .id = @enumFromInt(1), .content = .{ .container = .{ .children = &children } } };
    try t.expectError(error.LimitExceeded, encodeScene(t.allocator, too_many));
}
