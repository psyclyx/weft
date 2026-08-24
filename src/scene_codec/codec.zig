//! Canonical, bounded wire codec for portable semantic values.

const std = @import("std");
const semantic = @import("weft_semantic");
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
    pub const max_representations: usize = 1024;
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
// Scene v1 remains the compact wire form for target-less scenes.  v2 adds an
// optional typed target link to each node; decode accepts both forms so older
// guests remain readable while new guests only opt into v2 when needed.
const scene_v2_kind: u8 = 8;
const interaction_kind: u8 = 2;
const target_kind: u8 = 3;
const transfer_kind: u8 = 4;
const action_request_kind: u8 = 5;
// 9 is target_relation_kind; keep attachment-bearing transfer forms on
// distinct protocol tags so adding relation transport cannot alias them.
const transfer_kind_v2: u8 = 11;
const action_request_kind_v2: u8 = 12;
const target_descriptor_kind: u8 = 6;
const located_target_kind: u8 = 7;
const target_relation_kind: u8 = 9;
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

    fn blob(self: *Writer, value: []const u8) Error!void {
        if (value.len > Limits.max_payload_bytes) return error.LimitExceeded;
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

    fn blob(self: *Reader, arena: std.mem.Allocator) Error![]const u8 {
        const len = try self.count(Limits.max_payload_bytes);
        return try arena.dupe(u8, try self.take(len));
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

fn nodeId(raw: u64) Error!semantic.scene.NodeId {
    if (raw == 0) return error.InvalidData;
    return @enumFromInt(raw);
}

fn axisTag(axis: semantic.scene.Axis) u8 {
    return switch (axis) {
        .horizontal => 0,
        .vertical => 1,
        .overlay => 2,
    };
}

fn axisFromTag(raw: u8) Error!semantic.scene.Axis {
    return switch (raw) {
        0 => .horizontal,
        1 => .vertical,
        2 => .overlay,
        else => error.Corrupt,
    };
}

fn roleTag(role: semantic.interaction.Role) u8 {
    return switch (role) {
        .dialog => 0,
        .picker => 1,
        .popup => 2,
        .custom => 3,
    };
}

fn roleFromTag(raw: u8) Error!semantic.interaction.Role {
    return switch (raw) {
        0 => .dialog,
        1 => .picker,
        2 => .popup,
        3 => .custom,
        else => error.Corrupt,
    };
}

fn dispositionTag(disposition: semantic.interaction.Disposition) u8 {
    return switch (disposition) {
        .keep_open => 0,
        .close_on_handled => 1,
    };
}

fn dispositionFromTag(raw: u8) Error!semantic.interaction.Disposition {
    return switch (raw) {
        0 => .keep_open,
        1 => .close_on_handled,
        else => error.Corrupt,
    };
}

fn targetKindTag(kind: semantic.target.Kind) u8 {
    return switch (kind) {
        .unknown => 0,
        .file => 1,
        .directory => 2,
        .synthetic => 3,
    };
}

fn writeHandle(writer: *Writer, handle: anytype) Error!void {
    const wire = handle.toWire();
    if (wire.generation == 0) return error.InvalidData;
    try writer.writeU32(wire.authority);
    try writer.writeU32(wire.slot);
    try writer.writeU32(wire.generation);
}

fn readFieldHandle(reader: *Reader) Error!semantic.scene.FieldRef {
    const authority = try reader.readU32();
    const slot = try reader.readU32();
    const generation = try reader.readU32();
    if (generation == 0) return error.InvalidData;
    return .fromWire(.{ .authority = authority, .slot = slot, .generation = generation });
}

fn readViewHandle(reader: *Reader) Error!semantic.view.Ref {
    const authority = try reader.readU32();
    const slot = try reader.readU32();
    const generation = try reader.readU32();
    if (generation == 0) return error.InvalidData;
    return .fromWire(.{ .authority = authority, .slot = slot, .generation = generation });
}

fn readTargetHandle(reader: *Reader) Error!semantic.target.Ref {
    const authority = try reader.readU32();
    const slot = try reader.readU32();
    const generation = try reader.readU32();
    if (generation == 0) return error.InvalidData;
    return .fromWire(.{ .authority = authority, .slot = slot, .generation = generation });
}

fn validateSceneTargetLink(link: semantic.scene.TargetLink) Error!void {
    semantic.scene.validateTargetLink(link) catch return error.InvalidData;
    switch (link.location) {
        .whole, .text => {},
        .node => |value| if (value.len > Limits.max_payload_bytes) return error.LimitExceeded,
        .provider => |value| {
            if (value.schema.len > Limits.max_string_bytes or value.payload.len > Limits.max_payload_bytes)
                return error.LimitExceeded;
        },
    }
}

fn writeTargetLink(writer: *Writer, link: semantic.scene.TargetLink) Error!void {
    try validateSceneTargetLink(link);
    try writeHandle(writer, link.target);
    try writer.writeU64(link.revision);
    switch (link.location) {
        .whole => try writer.byte(0),
        .text => |range| {
            try writer.byte(1);
            try writer.writeU64(range.start);
            try writer.writeU64(range.end);
        },
        .node => |value| {
            try writer.byte(2);
            try writer.blob(value);
        },
        .provider => |value| {
            try writer.byte(3);
            try writer.string(value.schema);
            try writer.blob(value.payload);
        },
    }
}

fn readTargetLink(reader: *Reader, arena: std.mem.Allocator) Error!semantic.scene.TargetLink {
    const target_ref = try readTargetHandle(reader);
    const revision = try reader.readU64();
    if (revision == 0) return error.InvalidData;
    const location: semantic.target.Location = switch (try reader.byte()) {
        0 => .whole,
        1 => blk: {
            const start = try reader.readU64();
            const end = try reader.readU64();
            if (start > end) return error.InvalidData;
            break :blk .{ .text = .{ .start = start, .end = end } };
        },
        2 => blk: {
            const value = try reader.blob(arena);
            if (value.len == 0) return error.InvalidData;
            break :blk .{ .node = value };
        },
        3 => blk: {
            const schema_value = try reader.string(arena);
            if (schema_value.len == 0) return error.InvalidData;
            break :blk .{ .provider = .{ .schema = schema_value, .payload = try reader.blob(arena) } };
        },
        else => return error.Corrupt,
    };
    const link: semantic.scene.TargetLink = .{ .target = target_ref, .revision = revision, .location = location };
    try validateSceneTargetLink(link);
    return link;
}

// ── Scene ────────────────────────────────────────────────────────────────

const SceneCount = struct { nodes: usize = 0 };

fn validateSceneNode(gpa: std.mem.Allocator, node: semantic.scene.Node, seen: *std.AutoHashMapUnmanaged(u64, void), depth: usize, count: *SceneCount) Error!void {
    if (depth > Limits.max_depth) return error.LimitExceeded;
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
        if (fact.name.len == 0) return error.InvalidData;
        if (fact.name.len > Limits.max_string_bytes or fact.value.len > Limits.max_string_bytes) return error.LimitExceeded;
        const result = try fact_names.getOrPut(gpa, fact.name);
        if (result.found_existing) return error.Duplicate;
    }
    if (node.actions.len > Limits.max_actions) return error.LimitExceeded;
    var action_ids: std.StringHashMapUnmanaged(void) = .empty;
    defer action_ids.deinit(gpa);
    for (node.actions) |action| {
        if (action.id.len == 0 or action.id.len > Limits.max_string_bytes or action.label.len > Limits.max_string_bytes) return error.InvalidData;
        const result = try action_ids.getOrPut(gpa, action.id);
        if (result.found_existing) return error.Duplicate;
    }
    if (node.target) |link| try validateSceneTargetLink(link);
    switch (node.content) {
        .container => |container| {
            if (container.children.len > Limits.max_children) return error.LimitExceeded;
            for (container.children) |child| try validateSceneNode(gpa, child, seen, depth + 1, count);
        },
        .label => |label| if (label.len > Limits.max_string_bytes) return error.LimitExceeded,
        .field => |field| if (field.placeholder.len > Limits.max_string_bytes) return error.LimitExceeded,
        .action => |action| {
            if (action.action.len == 0) return error.InvalidData;
            if (action.action.len > Limits.max_string_bytes or action.label.len > Limits.max_string_bytes) return error.LimitExceeded;
        },
    }
}

fn sceneHasTarget(node: semantic.scene.Node) bool {
    if (node.target != null) return true;
    return switch (node.content) {
        .container => |container| for (container.children) |child| {
            if (sceneHasTarget(child)) break true;
        } else false,
        else => false,
    };
}

fn countScene(gpa: std.mem.Allocator, root: semantic.scene.Node) Error!usize {
    var seen: std.AutoHashMapUnmanaged(u64, void) = .empty;
    defer seen.deinit(gpa);
    var count: SceneCount = .{};
    try validateSceneNode(gpa, root, &seen, 0, &count);
    return count.nodes;
}

fn encodeSceneNode(writer: *Writer, node: semantic.scene.Node, parent: u32, index: *u32, versioned_targets: bool) Error!void {
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
    try writer.count(node.actions.len, Limits.max_actions);
    for (node.actions) |action| {
        try writer.string(action.id);
        try writer.string(action.label);
        try writer.byte(if (action.enabled) 1 else 0);
    }
    try writer.writeU16(node.layout.grow);
    try writer.byte(if (node.layout.column != null) 1 else 0);
    if (node.layout.column) |value| try writer.writeU16(value);
    try writer.byte(if (node.layout.min_cells != null) 1 else 0);
    if (node.layout.min_cells) |value| try writer.writeU16(value);
    try writer.byte(if (node.focusable) 1 else 0);
    if (versioned_targets) {
        try writer.byte(if (node.target != null) 1 else 0);
        if (node.target) |link| try writeTargetLink(writer, link);
    }
    switch (node.content) {
        .container => |container| {
            try writer.byte(0);
            try writer.byte(axisTag(container.axis));
            try writer.count(container.children.len, Limits.max_children);
            for (container.children) |child| try encodeSceneNode(writer, child, this_index, index, versioned_targets);
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

pub fn encodeScene(gpa: std.mem.Allocator, root: semantic.scene.Node) Error![]u8 {
    const count = try countScene(gpa, root);
    const versioned_targets = sceneHasTarget(root);
    var writer = Writer.init(gpa);
    errdefer writer.deinit();
    try header(&writer, if (versioned_targets) scene_v2_kind else scene_kind);
    try writer.count(count, Limits.max_nodes);
    var index: u32 = 0;
    try encodeSceneNode(&writer, root, @intCast(root_parent), &index, versioned_targets);
    return writer.finish();
}

const TempContainer = struct { axis: semantic.scene.Axis, child_count: usize, children: []u32 = &.{} };
const TempField = struct { ref: semantic.scene.FieldRef, placeholder: []const u8, single_line: bool };
const TempAction = struct { action: []const u8, label: []const u8, enabled: bool };

const TempContent = union(enum) {
    container: TempContainer,
    label: []const u8,
    field: TempField,
    action: TempAction,
};

const TempNode = struct {
    id: semantic.scene.NodeId,
    parent: u32,
    role: []const u8,
    facts: []const semantic.scene.Fact,
    actions: []const semantic.scene.Action,
    layout: semantic.scene.Layout,
    focusable: bool,
    target: ?semantic.scene.TargetLink,
    content: TempContent,
};

pub const OwnedScene = struct {
    arena: std.heap.ArenaAllocator,
    root: *const semantic.scene.Node,

    pub fn deinit(self: *OwnedScene) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

fn readFacts(reader: *Reader, arena: std.mem.Allocator) Error![]const semantic.scene.Fact {
    const count = try reader.count(Limits.max_facts);
    const facts = try arena.alloc(semantic.scene.Fact, count);
    var names: std.StringHashMapUnmanaged(void) = .empty;
    defer names.deinit(arena);
    for (facts) |*fact| {
        fact.name = try reader.string(arena);
        fact.value = try reader.string(arena);
        if (fact.name.len == 0) return error.InvalidData;
        const result = try names.getOrPut(arena, fact.name);
        if (result.found_existing) return error.Duplicate;
    }
    return facts;
}

fn readActions(reader: *Reader, arena: std.mem.Allocator) Error![]const semantic.scene.Action {
    const actions = try arena.alloc(semantic.scene.Action, try reader.count(Limits.max_actions));
    var ids: std.StringHashMapUnmanaged(void) = .empty;
    defer ids.deinit(arena);
    for (actions) |*action| {
        action.id = try reader.string(arena);
        action.label = try reader.string(arena);
        action.enabled = try reader.strictBool();
        if (action.id.len == 0) return error.InvalidData;
        const result = try ids.getOrPut(arena, action.id);
        if (result.found_existing) return error.Duplicate;
    }
    return actions;
}

fn readTempNode(reader: *Reader, arena: std.mem.Allocator, versioned_targets: bool) Error!TempNode {
    const id = try nodeId(try reader.readU64());
    const parent_raw = try reader.uv();
    if (parent_raw > root_parent) return error.BadReference;
    const role = try reader.string(arena);
    const facts = try readFacts(reader, arena);
    const actions = try readActions(reader, arena);
    const grow = try reader.readU16();
    const column = if (try reader.strictBool()) try reader.readU16() else null;
    const min_cells = if (try reader.strictBool()) try reader.readU16() else null;
    const focusable = try reader.strictBool();
    const target_link: ?semantic.scene.TargetLink = if (versioned_targets and try reader.strictBool())
        try readTargetLink(reader, arena)
    else
        null;
    const content: TempContent = switch (try reader.byte()) {
        0 => .{ .container = TempContainer{ .axis = try axisFromTag(try reader.byte()), .child_count = try reader.count(Limits.max_children) } },
        1 => .{ .label = try reader.string(arena) },
        2 => .{ .field = TempField{ .ref = try readFieldHandle(reader), .placeholder = try reader.string(arena), .single_line = try reader.strictBool() } },
        3 => blk: {
            const action = try reader.string(arena);
            if (action.len == 0) return error.InvalidData;
            break :blk .{ .action = TempAction{ .action = action, .label = try reader.string(arena), .enabled = try reader.strictBool() } };
        },
        else => return error.Corrupt,
    };
    return .{
        .id = id,
        .parent = @intCast(parent_raw),
        .role = role,
        .facts = facts,
        .actions = actions,
        .layout = .{ .grow = grow, .column = column, .min_cells = min_cells },
        .focusable = focusable,
        .target = target_link,
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

fn materializeNode(arena: std.mem.Allocator, records: []const TempNode, index: usize, depth: usize) Error!*semantic.scene.Node {
    if (depth > Limits.max_depth or index >= records.len) return error.BadReference;
    const record = records[index];
    const node = try arena.create(semantic.scene.Node);
    node.* = .{ .id = record.id, .role = record.role, .facts = record.facts, .actions = record.actions, .layout = record.layout, .focusable = record.focusable, .target = record.target, .content = undefined };
    switch (record.content) {
        .container => |container| {
            const children = try arena.alloc(semantic.scene.Node, container.children.len);
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
    if (!std.mem.eql(u8, try reader.take(magic.len), magic)) return error.Corrupt;
    if (try reader.byte() != protocol_version) return error.Corrupt;
    const encoded_kind = try reader.byte();
    const versioned_targets = switch (encoded_kind) {
        scene_kind => false,
        scene_v2_kind => true,
        else => return error.Corrupt,
    };
    const arena_init = std.heap.ArenaAllocator.init(gpa);
    var owned: OwnedScene = .{ .arena = arena_init, .root = undefined };
    errdefer owned.arena.deinit();
    const arena = owned.arena.allocator();
    const count = try reader.count(Limits.max_nodes);
    const records = try arena.alloc(TempNode, count);
    for (records) |*record| record.* = try readTempNode(&reader, arena, versioned_targets);
    try validateParents(arena, records);
    try reader.done();
    owned.root = try materializeNode(arena, records, 0, 0);
    return owned;
}

// ── Interaction ─────────────────────────────────────────────────────────

fn validateActionLists(gpa: std.mem.Allocator, actions: []const semantic.interaction.Action, bindings: []const semantic.interaction.Binding) Error!void {
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
    if (!try reader.strictBool()) return null;
    const value = try reader.string(arena);
    if (value.len == 0) return error.InvalidData;
    return value;
}

pub fn encodeInteraction(gpa: std.mem.Allocator, definition: semantic.interaction.Definition) Error![]u8 {
    try validateActionLists(gpa, definition.actions, definition.bindings);
    if (definition.presentation.len > Limits.max_string_bytes) return error.LimitExceeded;
    if (@intFromEnum(definition.root) == 0) return error.InvalidData;
    var action_ids = std.ArrayList([]const u8).empty;
    defer action_ids.deinit(gpa);
    for (definition.actions) |action| try action_ids.append(gpa, action.id);
    if (definition.default_action) |id| {
        if (id.len == 0) return error.InvalidData;
        if (!containsString(action_ids.items, id)) return error.BadReference;
    }
    if (definition.cancel_action) |id| {
        if (id.len == 0) return error.InvalidData;
        if (!containsString(action_ids.items, id)) return error.BadReference;
    }
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
        try writer.byte(dispositionTag(action.disposition));
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
    value: semantic.interaction.Definition,

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
    const actions = try arena.alloc(semantic.interaction.Action, try reader.count(Limits.max_actions));
    var action_ids = std.StringHashMapUnmanaged(void).empty;
    defer action_ids.deinit(arena);
    for (actions) |*action| {
        action.id = try reader.string(arena);
        action.label = try reader.string(arena);
        action.enabled = try reader.strictBool();
        action.disposition = try dispositionFromTag(try reader.byte());
        if (action.id.len == 0) return error.InvalidData;
        const result = try action_ids.getOrPut(arena, action.id);
        if (result.found_existing) return error.Duplicate;
    }
    const bindings = try arena.alloc(semantic.interaction.Binding, try reader.count(Limits.max_bindings));
    var inputs = std.StringHashMapUnmanaged(void).empty;
    defer inputs.deinit(arena);
    for (bindings) |*binding| {
        binding.input = try reader.string(arena);
        binding.action = try reader.string(arena);
        if (binding.input.len == 0 or binding.action.len == 0) return error.InvalidData;
        if (!action_ids.contains(binding.action)) return error.BadReference;
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

fn validateFacts(gpa: std.mem.Allocator, facts: []const semantic.target.Fact) Error!void {
    if (facts.len > Limits.max_facts) return error.LimitExceeded;
    var names = std.StringHashMapUnmanaged(void).empty;
    defer names.deinit(gpa);
    for (facts) |fact| {
        if (fact.name.len == 0) return error.InvalidData;
        if (fact.name.len > Limits.max_string_bytes or fact.value.len > Limits.max_string_bytes) return error.LimitExceeded;
        const result = try names.getOrPut(gpa, fact.name);
        if (result.found_existing) return error.Duplicate;
    }
}

fn writeTargetBody(writer: *Writer, kind: semantic.target.Kind, display_name: []const u8, facts: []const semantic.target.Fact) Error!void {
    try writer.byte(targetKindTag(kind));
    if (kind == .synthetic) try writer.string(kind.synthetic);
    try writer.string(display_name);
    try writer.count(facts.len, Limits.max_facts);
    for (facts) |fact| {
        try writer.string(fact.name);
        try writer.string(fact.value);
    }
}

const TargetBody = struct {
    kind: semantic.target.Kind,
    display_name: []const u8,
    facts: []const semantic.target.Fact,
};

fn readTargetBody(reader: *Reader, arena: std.mem.Allocator) Error!TargetBody {
    const kind: semantic.target.Kind = switch (try reader.byte()) {
        0 => .unknown,
        1 => .file,
        2 => .directory,
        3 => .{ .synthetic = try reader.string(arena) },
        else => return error.Corrupt,
    };
    const display_name = try reader.string(arena);
    const facts = try arena.alloc(semantic.target.Fact, try reader.count(Limits.max_facts));
    var names = std.StringHashMapUnmanaged(void).empty;
    defer names.deinit(arena);
    for (facts) |*fact| {
        fact.name = try reader.string(arena);
        fact.value = try reader.string(arena);
        if (fact.name.len == 0) return error.InvalidData;
        const result = try names.getOrPut(arena, fact.name);
        if (result.found_existing) return error.Duplicate;
    }
    return .{ .kind = kind, .display_name = display_name, .facts = facts };
}

pub fn encodeTarget(gpa: std.mem.Allocator, definition: semantic.target.Definition) Error![]u8 {
    try validateFacts(gpa, definition.facts);
    if (definition.display_name.len > Limits.max_string_bytes) return error.LimitExceeded;
    var writer = Writer.init(gpa);
    errdefer writer.deinit();
    try header(&writer, target_kind);
    try writeTargetBody(&writer, definition.kind, definition.display_name, definition.facts);
    return writer.finish();
}

pub const OwnedTarget = struct {
    arena: std.heap.ArenaAllocator,
    value: semantic.target.Definition,

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
    const body = try readTargetBody(&reader, arena);
    try reader.done();
    owned.value = .{ .kind = body.kind, .display_name = body.display_name, .facts = body.facts };
    return owned;
}

pub fn encodeTargetDescriptor(gpa: std.mem.Allocator, descriptor: semantic.target.Descriptor) Error![]u8 {
    if (descriptor.ref.generation == 0 or descriptor.revision == 0) return error.InvalidData;
    try validateFacts(gpa, descriptor.facts);
    if (descriptor.display_name.len > Limits.max_string_bytes) return error.LimitExceeded;
    var writer = Writer.init(gpa);
    errdefer writer.deinit();
    try header(&writer, target_descriptor_kind);
    try writeHandle(&writer, descriptor.ref);
    try writer.writeU64(descriptor.revision);
    try writeTargetBody(&writer, descriptor.kind, descriptor.display_name, descriptor.facts);
    return writer.finish();
}

pub const OwnedTargetDescriptor = struct {
    arena: std.heap.ArenaAllocator,
    value: semantic.target.Descriptor,

    pub fn deinit(self: *OwnedTargetDescriptor) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub fn decodeTargetDescriptor(gpa: std.mem.Allocator, bytes: []const u8) Error!OwnedTargetDescriptor {
    var reader = try Reader.init(bytes);
    try checkHeader(&reader, target_descriptor_kind);
    var owned: OwnedTargetDescriptor = .{ .arena = .init(gpa), .value = undefined };
    errdefer owned.arena.deinit();
    const ref = try readTargetHandle(&reader);
    const revision = try reader.readU64();
    if (revision == 0) return error.InvalidData;
    const body = try readTargetBody(&reader, owned.arena.allocator());
    try reader.done();
    owned.value = .{ .ref = ref, .revision = revision, .kind = body.kind, .display_name = body.display_name, .facts = body.facts };
    return owned;
}

pub fn encodeLocatedTarget(gpa: std.mem.Allocator, located: semantic.target.Located) Error![]u8 {
    if (located.target.generation == 0 or located.revision == 0) return error.InvalidData;
    var writer = Writer.init(gpa);
    errdefer writer.deinit();
    try header(&writer, located_target_kind);
    try writeHandle(&writer, located.target);
    try writer.writeU64(located.revision);
    switch (located.location) {
        .whole => try writer.byte(0),
        .text => |range| {
            if (range.start > range.end) return error.InvalidData;
            try writer.byte(1);
            try writer.writeU64(range.start);
            try writer.writeU64(range.end);
        },
        .node => |node| {
            if (node.len == 0) return error.InvalidData;
            try writer.byte(2);
            try writer.blob(node);
        },
        .provider => |provider| {
            if (provider.schema.len == 0) return error.InvalidData;
            try writer.byte(3);
            try writer.string(provider.schema);
            try writer.blob(provider.payload);
        },
    }
    return writer.finish();
}

pub const OwnedLocatedTarget = struct {
    arena: std.heap.ArenaAllocator,
    value: semantic.target.Located,

    pub fn deinit(self: *OwnedLocatedTarget) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub fn decodeLocatedTarget(gpa: std.mem.Allocator, bytes: []const u8) Error!OwnedLocatedTarget {
    var reader = try Reader.init(bytes);
    try checkHeader(&reader, located_target_kind);
    var owned: OwnedLocatedTarget = .{ .arena = .init(gpa), .value = undefined };
    errdefer owned.arena.deinit();
    const target_ref = try readTargetHandle(&reader);
    const revision = try reader.readU64();
    if (revision == 0) return error.InvalidData;
    const arena = owned.arena.allocator();
    const location: semantic.target.Location = switch (try reader.byte()) {
        0 => .whole,
        1 => blk: {
            const start = try reader.readU64();
            const end = try reader.readU64();
            if (start > end) return error.InvalidData;
            break :blk .{ .text = .{ .start = start, .end = end } };
        },
        2 => blk: {
            const node = try reader.blob(arena);
            if (node.len == 0) return error.InvalidData;
            break :blk .{ .node = node };
        },
        3 => blk: {
            const schema_value = try reader.string(arena);
            if (schema_value.len == 0) return error.InvalidData;
            break :blk .{ .provider = .{ .schema = schema_value, .payload = try reader.blob(arena) } };
        },
        else => return error.Corrupt,
    };
    try reader.done();
    owned.value = .{ .target = target_ref, .revision = revision, .location = location };
    return owned;
}

pub fn encodeTargetRelation(gpa: std.mem.Allocator, request: semantic.action.RelationRequest) Error![]u8 {
    if (request.name.len == 0) return error.InvalidData;
    if (request.name.len > Limits.max_string_bytes) return error.LimitExceeded;
    var writer = Writer.init(gpa);
    errdefer writer.deinit();
    try header(&writer, target_relation_kind);
    try writeTargetLink(&writer, request.source);
    try writer.string(request.name);
    return writer.finish();
}

pub const OwnedTargetRelation = struct {
    arena: std.heap.ArenaAllocator,
    value: semantic.action.RelationRequest,

    pub fn deinit(self: *OwnedTargetRelation) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub fn decodeTargetRelation(gpa: std.mem.Allocator, bytes: []const u8) Error!OwnedTargetRelation {
    var reader = try Reader.init(bytes);
    try checkHeader(&reader, target_relation_kind);
    var owned: OwnedTargetRelation = .{ .arena = .init(gpa), .value = undefined };
    errdefer owned.arena.deinit();
    const arena = owned.arena.allocator();
    const source = try readTargetLink(&reader, arena);
    const name = try reader.string(arena);
    if (name.len == 0) return error.InvalidData;
    try reader.done();
    owned.value = .{ .source = source, .name = name };
    return owned;
}

// ── Transfer ────────────────────────────────────────────────────────────

fn validateTransfer(gpa: std.mem.Allocator, item: semantic.transfer.Item) Error!void {
    if (item.representations.len == 0) return error.InvalidData;
    if (item.representations.len > Limits.max_representations) return error.LimitExceeded;
    if (item.suggested_name.len > Limits.max_string_bytes) return error.LimitExceeded;
    if (item.source) |source| {
        if (source.revision.len == 0) return error.InvalidData;
        if (source.revision.len > Limits.max_string_bytes) return error.LimitExceeded;
        if (source.target.generation == 0) return error.InvalidData;
    }
    var media_types: std.StringHashMapUnmanaged(void) = .empty;
    defer media_types.deinit(gpa);
    for (item.representations) |representation| {
        if (representation.media_type.len == 0) return error.InvalidData;
        if (representation.media_type.len > Limits.max_string_bytes or representation.payload.len > Limits.max_payload_bytes) return error.LimitExceeded;
        if (representation.schema) |value| {
            if (value.len == 0) return error.InvalidData;
            if (value.len > Limits.max_string_bytes) return error.LimitExceeded;
        }
        if (representation.attachment) |attachment| {
            if (attachment.generation == 0) return error.InvalidData;
        }
        const result = try media_types.getOrPut(gpa, representation.media_type);
        if (result.found_existing) return error.Duplicate;
    }
}

fn writeTransferBody(writer: *Writer, item: semantic.transfer.Item, include_attachments: bool) Error!void {
    try writer.byte(switch (item.intent) {
        .copy => 0,
        .cut => 1,
    });
    try writer.string(item.suggested_name);
    try writer.byte(@intFromBool(item.source != null));
    if (item.source) |source| {
        try writeHandle(writer, source.target);
        try writer.string(source.revision);
    }
    try writer.count(item.representations.len, Limits.max_representations);
    for (item.representations) |representation| {
        try writer.string(representation.media_type);
        try optionalString(writer, representation.schema);
        if (include_attachments) {
            try writer.byte(@intFromBool(representation.attachment != null));
            if (representation.attachment) |attachment| {
                const wire = attachment.toWire();
                try writer.writeU32(wire.authority);
                try writer.writeU32(wire.slot);
                try writer.writeU32(wire.generation);
            }
        }
        try writer.blob(representation.payload);
    }
}

fn readTransferBody(reader: *Reader, arena: std.mem.Allocator, include_attachments: bool) Error!semantic.transfer.Item {
    const intent: semantic.transfer.Intent = switch (try reader.byte()) {
        0 => .copy,
        1 => .cut,
        else => return error.Corrupt,
    };
    const suggested_name = try reader.string(arena);
    const source: ?semantic.transfer.Source = if (try reader.strictBool()) .{
        .target = try readTargetHandle(reader),
        .revision = try reader.string(arena),
    } else null;
    if (source) |value| if (value.revision.len == 0) return error.InvalidData;
    const representations = try arena.alloc(semantic.transfer.Representation, try reader.count(Limits.max_representations));
    if (representations.len == 0) return error.InvalidData;
    var media_types: std.StringHashMapUnmanaged(void) = .empty;
    defer media_types.deinit(arena);
    for (representations) |*representation| {
        representation.resource = null;
        representation.media_type = try reader.string(arena);
        representation.schema = try readOptionalString(reader, arena);
        representation.attachment = if (include_attachments and try reader.strictBool()) semantic.transfer.Attachment.fromWire(.{
            .authority = try reader.readU32(),
            .slot = try reader.readU32(),
            .generation = try reader.readU32(),
        }) else null;
        if (representation.attachment) |attachment| if (attachment.generation == 0) return error.InvalidData;
        representation.payload = try reader.blob(arena);
        if (representation.media_type.len == 0) return error.InvalidData;
        const result = try media_types.getOrPut(arena, representation.media_type);
        if (result.found_existing) return error.Duplicate;
    }
    return .{ .intent = intent, .suggested_name = suggested_name, .source = source, .representations = representations };
}

pub fn encodeTransfer(gpa: std.mem.Allocator, item: semantic.transfer.Item) Error![]u8 {
    try validateTransfer(gpa, item);
    var writer = Writer.init(gpa);
    errdefer writer.deinit();
    try header(&writer, transfer_kind_v2);
    try writeTransferBody(&writer, item, true);
    return writer.finish();
}

pub const OwnedTransfer = struct {
    arena: std.heap.ArenaAllocator,
    value: semantic.transfer.Item,

    pub fn deinit(self: *OwnedTransfer) void {
        for (self.value.representations) |representation|
            if (representation.resource) |resource| resource.release();
        self.arena.deinit();
        self.* = undefined;
    }
};

pub fn decodeTransfer(gpa: std.mem.Allocator, bytes: []const u8) Error!OwnedTransfer {
    var reader = try Reader.init(bytes);
    if (!std.mem.eql(u8, try reader.take(magic.len), magic)) return error.Corrupt;
    if (try reader.byte() != protocol_version) return error.Corrupt;
    const kind = try reader.byte();
    if (kind != transfer_kind and kind != transfer_kind_v2) return error.Corrupt;
    var owned: OwnedTransfer = .{ .arena = .init(gpa), .value = undefined };
    errdefer owned.arena.deinit();
    owned.value = try readTransferBody(&reader, owned.arena.allocator(), kind == transfer_kind_v2);
    try reader.done();
    return owned;
}

// ── Action request ──────────────────────────────────────────────────────

fn validateSelection(selection: semantic.selection.Selection) Error!void {
    switch (selection) {
        .none => {},
        .text => |range| {
            if (range.field.generation == 0 or range.start > range.end) return error.InvalidData;
        },
        .nodes => |nodes| {
            if (nodes.len > Limits.max_nodes) return error.LimitExceeded;
            for (nodes) |node| if (@intFromEnum(node) == 0) return error.InvalidData;
        },
        .custom => |custom| {
            if (custom.schema.len == 0) return error.InvalidData;
            if (custom.schema.len > Limits.max_string_bytes or custom.payload.len > Limits.max_payload_bytes) return error.LimitExceeded;
        },
    }
}

fn writeSelection(writer: *Writer, selection: semantic.selection.Selection) Error!void {
    switch (selection) {
        .none => try writer.byte(0),
        .text => |range| {
            try writer.byte(1);
            try writeHandle(writer, range.field);
            try writer.writeU64(range.start);
            try writer.writeU64(range.end);
            try writer.byte(@intFromBool(range.linewise));
        },
        .nodes => |nodes| {
            try writer.byte(2);
            try writer.count(nodes.len, Limits.max_nodes);
            for (nodes) |node| try writer.writeU64(@intFromEnum(node));
        },
        .custom => |custom| {
            try writer.byte(3);
            try writer.string(custom.schema);
            try writer.blob(custom.payload);
        },
    }
}

fn readSelection(reader: *Reader, arena: std.mem.Allocator) Error!semantic.selection.Selection {
    return switch (try reader.byte()) {
        0 => .none,
        1 => blk: {
            const field = try readFieldHandle(reader);
            const start = try reader.readU64();
            const end = try reader.readU64();
            if (start > end) return error.InvalidData;
            break :blk .{ .text = .{ .field = field, .start = start, .end = end, .linewise = try reader.strictBool() } };
        },
        2 => blk: {
            const nodes = try arena.alloc(semantic.scene.NodeId, try reader.count(Limits.max_nodes));
            for (nodes) |*node| {
                const raw = try reader.readU64();
                if (raw == 0) return error.InvalidData;
                node.* = @enumFromInt(raw);
            }
            break :blk .{ .nodes = nodes };
        },
        3 => blk: {
            const schema_value = try reader.string(arena);
            if (schema_value.len == 0) return error.InvalidData;
            break :blk .{ .custom = .{ .schema = schema_value, .payload = try reader.blob(arena) } };
        },
        else => error.Corrupt,
    };
}

pub fn encodeActionRequest(gpa: std.mem.Allocator, request: semantic.action.Request) Error![]u8 {
    if (request.action.len == 0) return error.InvalidData;
    if (request.action.len > Limits.max_string_bytes) return error.LimitExceeded;
    if (request.view.generation == 0 or @intFromEnum(request.subject) == 0) return error.InvalidData;
    try validateSelection(request.selection);
    if (request.transfer) |item| try validateTransfer(gpa, item);
    var writer = Writer.init(gpa);
    errdefer writer.deinit();
    try header(&writer, action_request_kind_v2);
    try writer.string(request.action);
    try writeHandle(&writer, request.view);
    try writer.writeU64(@intFromEnum(request.subject));
    try writeSelection(&writer, request.selection);
    try writer.byte(@intFromBool(request.transfer != null));
    if (request.transfer) |item| try writeTransferBody(&writer, item, true);
    return writer.finish();
}

pub const OwnedActionRequest = struct {
    arena: std.heap.ArenaAllocator,
    value: semantic.action.Request,

    pub fn deinit(self: *OwnedActionRequest) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub fn decodeActionRequest(gpa: std.mem.Allocator, bytes: []const u8) Error!OwnedActionRequest {
    var reader = try Reader.init(bytes);
    if (!std.mem.eql(u8, try reader.take(magic.len), magic)) return error.Corrupt;
    if (try reader.byte() != protocol_version) return error.Corrupt;
    const kind = try reader.byte();
    if (kind != action_request_kind and kind != action_request_kind_v2) return error.Corrupt;
    var owned: OwnedActionRequest = .{ .arena = .init(gpa), .value = undefined };
    errdefer owned.arena.deinit();
    const arena = owned.arena.allocator();
    const action = try reader.string(arena);
    if (action.len == 0) return error.InvalidData;
    const view = try readViewHandle(&reader);
    const subject_raw = try reader.readU64();
    if (subject_raw == 0) return error.InvalidData;
    const selection = try readSelection(&reader, arena);
    const transfer: ?semantic.transfer.Item = if (try reader.strictBool()) try readTransferBody(&reader, arena, kind == action_request_kind_v2) else null;
    try reader.done();
    owned.value = .{ .action = action, .view = view, .subject = @enumFromInt(subject_raw), .selection = selection, .transfer = transfer };
    return owned;
}

// ── Tests ────────────────────────────────────────────────────────────────

const t = std.testing;

test "scene codec: preorder scene round-trip preserves semantic fields" {
    const field_ref: semantic.scene.FieldRef = .{ .authority = .here, .slot = 4, .generation = 2 };
    const leaf = semantic.scene.Node{ .id = @enumFromInt(2), .role = "button", .facts = &.{.{ .name = "kind", .value = "ok" }}, .actions = &.{.{ .id = "save", .label = "Save", .enabled = false }}, .layout = .{ .grow = 3, .column = 2 }, .focusable = true, .content = .{ .field = .{ .ref = field_ref, .placeholder = "name", .single_line = true } } };
    const root = semantic.scene.Node{ .id = @enumFromInt(1), .role = "root", .content = .{ .container = .{ .axis = .horizontal, .children = &.{leaf} } } };
    const bytes = try encodeScene(t.allocator, root);
    defer t.allocator.free(bytes);
    var decoded = try decodeScene(t.allocator, bytes);
    defer decoded.deinit();
    try t.expectEqual(@as(u64, 1), @intFromEnum(decoded.root.id));
    try t.expectEqualStrings("root", decoded.root.role);
    try t.expectEqual(semantic.scene.Axis.horizontal, decoded.root.content.container.axis);
    try t.expectEqual(@as(usize, 1), decoded.root.content.container.children.len);
    const child = &decoded.root.content.container.children[0];
    try t.expectEqual(@as(u64, 2), @intFromEnum(child.id));
    try t.expectEqualStrings("name", child.content.field.placeholder);
    try t.expectEqual(field_ref, child.content.field.ref);
    try t.expectEqualStrings("save", child.actions[0].id);
    try t.expect(!child.actions[0].enabled);
    try t.expect(child.target == null);
}

test "scene v2 codec round-trips target links and v1 remains readable" {
    const links = [_]semantic.scene.TargetLink{
        .{ .target = .{ .authority = .here, .slot = 1, .generation = 2 }, .revision = 3 },
        .{ .target = .{ .authority = @enumFromInt(41), .slot = 4, .generation = 5 }, .revision = 6, .location = .{ .text = .{ .start = 2, .end = 9 } } },
        .{ .target = .{ .authority = @enumFromInt(42), .slot = 7, .generation = 8 }, .revision = 9, .location = .{ .node = &.{ 0, 0xff, '/', '\n' } } },
        .{ .target = .{ .authority = @enumFromInt(43), .slot = 10, .generation = 11 }, .revision = 12, .location = .{ .provider = .{ .schema = "remote.node.v1", .payload = &.{ 1, 2, 3 } } } },
    };
    var children: [links.len]semantic.scene.Node = undefined;
    for (&children, links) |*child, link| child.* = .{ .id = @enumFromInt(1), .focusable = true, .target = link, .content = .{ .label = "target" } };
    for (&children, 0..) |*child, index| child.id = @enumFromInt(index + 2);
    const root: semantic.scene.Node = .{ .id = @enumFromInt(1), .content = .{ .container = .{ .children = &children } } };
    const bytes = try encodeScene(t.allocator, root);
    defer t.allocator.free(bytes);
    try t.expectEqual(@as(u8, scene_v2_kind), bytes[4]);
    var decoded = try decodeScene(t.allocator, bytes);
    defer decoded.deinit();
    for (decoded.root.content.container.children, links) |child, expected| {
        try t.expectEqual(expected.target, child.target.?.target);
        try t.expectEqual(expected.revision, child.target.?.revision);
        try t.expectEqualDeep(expected.location, child.target.?.location);
    }

    const v1 = try encodeScene(t.allocator, .{ .id = @enumFromInt(1), .content = .{ .label = "old guest" } });
    defer t.allocator.free(v1);
    try t.expectEqual(@as(u8, scene_kind), v1[4]);
    var old = try decodeScene(t.allocator, v1);
    defer old.deinit();
    try t.expect(old.root.target == null);
}

test "scene v2 codec rejects malformed target link handles and locations" {
    const target_node: semantic.scene.Node = .{
        .id = @enumFromInt(1),
        .target = .{ .target = .{ .authority = .here, .slot = 1, .generation = 2 }, .revision = 3, .location = .{ .provider = .{ .schema = "schema", .payload = "payload" } } },
        .content = .{ .label = "target" },
    };
    const encoded = try encodeScene(t.allocator, target_node);
    defer t.allocator.free(encoded);

    var malformed_generation = try t.allocator.dupe(u8, encoded);
    defer t.allocator.free(malformed_generation);
    var generation_reader = try Reader.init(malformed_generation);
    var generation_arena = std.heap.ArenaAllocator.init(t.allocator);
    defer generation_arena.deinit();
    _ = try generation_reader.take(magic.len);
    _ = try generation_reader.byte();
    _ = try generation_reader.byte();
    _ = try generation_reader.count(Limits.max_nodes);
    _ = try generation_reader.readU64();
    _ = try generation_reader.uv();
    _ = try generation_reader.string(generation_arena.allocator());
    _ = try generation_reader.count(Limits.max_facts);
    _ = try generation_reader.count(Limits.max_actions);
    _ = try generation_reader.readU16();
    _ = try generation_reader.strictBool();
    _ = try generation_reader.strictBool();
    _ = try generation_reader.strictBool();
    try t.expectEqual(@as(u8, 1), try generation_reader.byte());
    const generation_offset = generation_reader.pos + 8;
    @memset(malformed_generation[generation_offset .. generation_offset + 4], 0);
    try t.expectError(error.InvalidData, decodeScene(t.allocator, malformed_generation));

    const text_node: semantic.scene.Node = .{
        .id = @enumFromInt(1),
        .target = .{ .target = .{ .authority = .here, .slot = 1, .generation = 2 }, .revision = 3, .location = .{ .text = .{ .start = 1, .end = 4 } } },
        .content = .{ .label = "target" },
    };
    const text_encoded = try encodeScene(t.allocator, text_node);
    defer t.allocator.free(text_encoded);
    var malformed_range = try t.allocator.dupe(u8, text_encoded);
    defer t.allocator.free(malformed_range);
    var range_reader = try Reader.init(malformed_range);
    var range_arena = std.heap.ArenaAllocator.init(t.allocator);
    defer range_arena.deinit();
    _ = try range_reader.take(magic.len);
    _ = try range_reader.byte();
    _ = try range_reader.byte();
    _ = try range_reader.count(Limits.max_nodes);
    _ = try range_reader.readU64();
    _ = try range_reader.uv();
    _ = try range_reader.string(range_arena.allocator());
    _ = try range_reader.count(Limits.max_facts);
    _ = try range_reader.count(Limits.max_actions);
    _ = try range_reader.readU16();
    _ = try range_reader.strictBool();
    _ = try range_reader.strictBool();
    _ = try range_reader.strictBool();
    try t.expectEqual(@as(u8, 1), try range_reader.byte());
    range_reader.pos += 12 + 8;
    try t.expectEqual(@as(u8, 1), try range_reader.byte());
    const start_offset = range_reader.pos;
    var start_bytes: [8]u8 = undefined;
    var end_bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &start_bytes, 8, .little);
    std.mem.writeInt(u64, &end_bytes, 2, .little);
    @memcpy(malformed_range[start_offset .. start_offset + 8], &start_bytes);
    @memcpy(malformed_range[start_offset + 8 .. start_offset + 16], &end_bytes);
    try t.expectError(error.InvalidData, decodeScene(t.allocator, malformed_range));
}

test "interaction and target codecs round-trip defaults, handles, variants, and facts" {
    const definition: semantic.interaction.Definition = .{ .view = .{ .authority = .here, .slot = 3, .generation = 4 }, .role = .picker, .root = @enumFromInt(9), .actions = &.{.{ .id = "ok", .label = "OK", .enabled = true, .disposition = .close_on_handled }}, .bindings = &.{.{ .input = "enter", .action = "ok" }}, .default_action = "ok", .cancel_action = null, .presentation = "compact" };
    const interaction_bytes = try encodeInteraction(t.allocator, definition);
    defer t.allocator.free(interaction_bytes);
    var interaction_value = try decodeInteraction(t.allocator, interaction_bytes);
    defer interaction_value.deinit();
    try t.expectEqual(definition.view, interaction_value.value.view);
    try t.expectEqual(semantic.interaction.Disposition.close_on_handled, interaction_value.value.actions[0].disposition);
    try t.expectEqualStrings("ok", interaction_value.value.default_action.?);
    try t.expectEqualStrings("enter", interaction_value.value.bindings[0].input);

    const target_definition: semantic.target.Definition = .{ .kind = .{ .synthetic = "dired" }, .display_name = "Files", .facts = &.{.{ .name = "scope", .value = "project" }} };
    const target_bytes = try encodeTarget(t.allocator, target_definition);
    defer t.allocator.free(target_bytes);
    var target_value = try decodeTarget(t.allocator, target_bytes);
    defer target_value.deinit();
    try t.expectEqualStrings("dired", target_value.value.kind.synthetic);
    try t.expectEqualStrings("project", target_value.value.facts[0].value);
}

test "target descriptor and located codecs preserve revisions and opaque locations" {
    const ref: semantic.target.Ref = .{ .authority = @enumFromInt(7), .slot = 11, .generation = 3 };
    const descriptor: semantic.target.Descriptor = .{
        .ref = ref,
        .revision = 42,
        .kind = .directory,
        .display_name = "remote bytes",
        .facts = &.{.{ .name = "locus", .value = "peer:alice" }},
    };
    const descriptor_bytes = try encodeTargetDescriptor(t.allocator, descriptor);
    defer t.allocator.free(descriptor_bytes);
    var decoded_descriptor = try decodeTargetDescriptor(t.allocator, descriptor_bytes);
    defer decoded_descriptor.deinit();
    try t.expectEqual(ref, decoded_descriptor.value.ref);
    try t.expectEqual(@as(u64, 42), decoded_descriptor.value.revision);
    try t.expectEqualStrings("peer:alice", decoded_descriptor.value.facts[0].value);

    const located: semantic.target.Located = .{
        .target = ref,
        .revision = 42,
        .location = .{ .provider = .{ .schema = "remote/node-v1", .payload = &.{ 0, 0xff, '/', '\n' } } },
    };
    const located_bytes = try encodeLocatedTarget(t.allocator, located);
    defer t.allocator.free(located_bytes);
    var decoded_located = try decodeLocatedTarget(t.allocator, located_bytes);
    defer decoded_located.deinit();
    try t.expectEqual(ref, decoded_located.value.target);
    try t.expectEqual(@as(u64, 42), decoded_located.value.revision);
    try t.expectEqualStrings("remote/node-v1", decoded_located.value.location.provider.schema);
    try t.expectEqualSlices(u8, located.location.provider.payload, decoded_located.value.location.provider.payload);

    try t.expectError(error.InvalidData, encodeTargetDescriptor(t.allocator, .{
        .ref = ref,
        .revision = 0,
        .kind = .file,
        .display_name = "stale",
    }));
    try t.expectError(error.InvalidData, encodeLocatedTarget(t.allocator, .{
        .target = ref,
        .revision = 42,
        .location = .{ .text = .{ .start = 9, .end = 2 } },
    }));
    try t.expectError(error.InvalidData, encodeLocatedTarget(t.allocator, .{
        .target = ref,
        .revision = 42,
        .location = .{ .node = &.{} },
    }));
}

test "transfer and action request codecs preserve captured data and wide node ids" {
    const ProcessResource = struct {
        fn retain(_: *anyopaque) void {}
        fn release(_: *anyopaque) void {}
    };
    var process_resource_context: u8 = 0;
    const process_resource: semantic.transfer.Resource = .{
        .context = &process_resource_context,
        .vtable = &.{ .retain = ProcessResource.retain, .release = ProcessResource.release },
    };
    const representations = [_]semantic.transfer.Representation{
        .{ .media_type = "application/vnd.weft.file", .schema = "file/v1", .payload = &.{ 0, 0xff, '/', '\n' }, .resource = process_resource },
        .{ .media_type = "text/plain", .payload = "display" },
    };
    const transfer_value: semantic.transfer.Item = .{
        .intent = .cut,
        .suggested_name = "raw-name",
        .source = .{ .target = .{ .authority = .here, .slot = 5, .generation = 9 }, .revision = "opaque-revision" },
        .representations = &.{
            .{ .media_type = "application/vnd.weft.file", .schema = "file/v1", .payload = &.{ 0, 0xff, '/', '\n' }, .resource = process_resource, .attachment = semantic.transfer.Attachment.fromWire(.{ .authority = 7, .slot = 12, .generation = 3 }) },
            .{ .media_type = "text/plain", .payload = "display" },
        },
    };
    const transfer_bytes = try encodeTransfer(t.allocator, transfer_value);
    defer t.allocator.free(transfer_bytes);
    var decoded_transfer = try decodeTransfer(t.allocator, transfer_bytes);
    defer decoded_transfer.deinit();
    try t.expectEqual(semantic.transfer.Intent.cut, decoded_transfer.value.intent);
    try t.expectEqualStrings("opaque-revision", decoded_transfer.value.source.?.revision);
    try t.expectEqualSlices(u8, representations[0].payload, decoded_transfer.value.representations[0].payload);
    try t.expect(decoded_transfer.value.representations[0].resource == null);
    try t.expectEqual(@as(u32, 7), @intFromEnum(decoded_transfer.value.representations[0].attachment.?.authority));
    try t.expectEqual(@as(u32, 12), decoded_transfer.value.representations[0].attachment.?.slot);
    var owned_transfer = try semantic.transfer.OwnedItem.init(t.allocator, decoded_transfer.value);
    defer owned_transfer.deinit();
    try t.expect(owned_transfer.value.representations[0].resource == null);

    const wide_node: semantic.scene.NodeId = @enumFromInt(0x1_0000_0002);
    const request: semantic.action.Request = .{
        .action = semantic.action.standard.paste_after,
        .view = .{ .authority = .here, .slot = 8, .generation = 3 },
        .subject = wide_node,
        .selection = .{ .nodes = &.{ wide_node, @enumFromInt(7) } },
        .transfer = transfer_value,
    };
    const request_bytes = try encodeActionRequest(t.allocator, request);
    defer t.allocator.free(request_bytes);
    var decoded_request = try decodeActionRequest(t.allocator, request_bytes);
    defer decoded_request.deinit();
    try t.expectEqualStrings(semantic.action.standard.paste_after, decoded_request.value.action);
    try t.expectEqual(@as(u64, 0x1_0000_0002), @intFromEnum(decoded_request.value.subject));
    try t.expectEqual(@as(u64, 0x1_0000_0002), @intFromEnum(decoded_request.value.selection.nodes[0]));
    try t.expectEqualStrings("application/vnd.weft.file", decoded_request.value.transfer.?.representations[0].media_type);
}

test "target relation action codec preserves source revision, location, and name" {
    const request: semantic.action.RelationRequest = .{
        .source = .{
            .target = .{ .authority = @enumFromInt(7), .slot = 11, .generation = 3 },
            .revision = 42,
            .location = .{ .provider = .{ .schema = "tree/v1", .payload = &.{ 0, 0xff, '/', '\n' } } },
        },
        .name = "container",
    };
    const bytes = try encodeTargetRelation(t.allocator, request);
    defer t.allocator.free(bytes);
    var decoded = try decodeTargetRelation(t.allocator, bytes);
    defer decoded.deinit();
    try t.expectEqual(request.source.target, decoded.value.source.target);
    try t.expectEqual(request.source.revision, decoded.value.source.revision);
    try t.expectEqualStrings(request.name, decoded.value.name);
    try t.expectEqualStrings(request.source.location.provider.schema, decoded.value.source.location.provider.schema);
    try t.expectEqualSlices(u8, request.source.location.provider.payload, decoded.value.source.location.provider.payload);
    try t.expectError(error.InvalidData, encodeTargetRelation(t.allocator, .{ .source = request.source, .name = "" }));
}

test "transfer codec remains readable when an older sender has no attachment field" {
    var writer = Writer.init(t.allocator);
    defer writer.deinit();
    try header(&writer, transfer_kind);
    try writeTransferBody(&writer, .{
        .intent = .copy,
        .representations = &.{.{ .media_type = "text/plain", .payload = "old" }},
    }, false);
    const bytes = try writer.finish();
    defer t.allocator.free(bytes);
    var decoded = try decodeTransfer(t.allocator, bytes);
    defer decoded.deinit();
    try t.expect(decoded.value.representations[0].attachment == null);
    try t.expectEqualStrings("old", decoded.value.representations[0].payload);
}

test "transfer and action request codecs reject ambiguous or malformed values" {
    const duplicates = [_]semantic.transfer.Representation{
        .{ .media_type = "same", .payload = "a" },
        .{ .media_type = "same", .payload = "b" },
    };
    try t.expectError(error.Duplicate, encodeTransfer(t.allocator, .{ .intent = .copy, .representations = &duplicates }));
    try t.expectError(error.InvalidData, encodeTransfer(t.allocator, .{
        .intent = .copy,
        .representations = &.{.{ .media_type = "typed", .schema = "", .payload = "x" }},
    }));
    try t.expectError(error.InvalidData, encodeTransfer(t.allocator, .{
        .intent = .copy,
        .source = .{ .target = .{ .authority = .here, .slot = 1, .generation = 0 }, .revision = "1" },
        .representations = &.{.{ .media_type = "typed", .payload = "x" }},
    }));
    try t.expectError(error.InvalidData, encodeActionRequest(t.allocator, .{
        .action = "",
        .view = .{ .authority = .here, .slot = 1, .generation = 1 },
        .subject = @enumFromInt(1),
    }));
    try t.expectError(error.InvalidData, encodeActionRequest(t.allocator, .{
        .action = "go",
        .view = .{ .authority = .here, .slot = 1, .generation = 1 },
        .subject = @enumFromInt(1),
        .selection = .{ .text = .{
            .field = .{ .authority = .here, .slot = 2, .generation = 1 },
            .start = 4,
            .end = 3,
        } },
    }));

    const valid = try encodeTransfer(t.allocator, .{
        .intent = .copy,
        .representations = &.{.{ .media_type = "typed", .payload = "x" }},
    });
    defer t.allocator.free(valid);
    try t.expectError(error.Corrupt, decodeTransfer(t.allocator, valid[0 .. valid.len - 1]));
    const trailing = try t.allocator.alloc(u8, valid.len + 1);
    defer t.allocator.free(trailing);
    @memcpy(trailing[0..valid.len], valid);
    trailing[valid.len] = 0;
    try t.expectError(error.Corrupt, decodeTransfer(t.allocator, trailing));
}

test "scene codec: hostile tags, truncation, trailing bytes, and duplicate IDs refuse" {
    const root: semantic.scene.Node = .{ .id = @enumFromInt(1), .content = .{ .label = "x" } };
    const bytes = try encodeScene(t.allocator, root);
    defer t.allocator.free(bytes);
    try t.expectError(error.Corrupt, decodeScene(t.allocator, bytes[0 .. bytes.len - 1]));
    var trailing = try t.allocator.alloc(u8, bytes.len + 1);
    defer t.allocator.free(trailing);
    @memcpy(trailing[0..bytes.len], bytes);
    trailing[bytes.len] = 0;
    try t.expectError(error.Corrupt, decodeScene(t.allocator, trailing));
    try t.expectError(error.Corrupt, decodeTarget(t.allocator, &.{ 'W', 'S', 'C', 1, target_kind, 99 }));

    const duplicate = semantic.scene.Node{ .id = @enumFromInt(1), .content = .{ .container = .{ .children = &.{.{ .id = @enumFromInt(1), .content = .{ .label = "bad" } }} } } };
    try t.expectError(error.Duplicate, encodeScene(t.allocator, duplicate));
}

test "scene codec: reject empty names, action ids, and zero-generation handles" {
    const empty_fact_scene: semantic.scene.Node = .{
        .id = @enumFromInt(1),
        .facts = &.{.{ .name = "", .value = "value" }},
        .content = .{ .label = "row" },
    };
    try t.expectError(error.InvalidData, encodeScene(t.allocator, empty_fact_scene));
    const empty_content_action: semantic.scene.Node = .{
        .id = @enumFromInt(1),
        .content = .{ .action = .{ .action = "", .label = "Run" } },
    };
    try t.expectError(error.InvalidData, encodeScene(t.allocator, empty_content_action));
    const empty_fact_target: semantic.target.Definition = .{
        .kind = .file,
        .display_name = "file",
        .facts = &.{.{ .name = "", .value = "value" }},
    };
    try t.expectError(error.InvalidData, encodeTarget(t.allocator, empty_fact_target));

    const zero_field: semantic.scene.Node = .{
        .id = @enumFromInt(1),
        .content = .{ .field = .{ .ref = .{ .authority = .here, .slot = 1, .generation = 0 } } },
    };
    try t.expectError(error.InvalidData, encodeScene(t.allocator, zero_field));
    const zero_view: semantic.interaction.Definition = .{
        .view = .{ .authority = .here, .slot = 1, .generation = 0 },
        .role = .dialog,
        .root = @enumFromInt(1),
        .actions = &.{},
    };
    try t.expectError(error.InvalidData, encodeInteraction(t.allocator, zero_view));

    var scene_writer = Writer.init(t.allocator);
    try header(&scene_writer, scene_kind);
    try scene_writer.count(1, Limits.max_nodes);
    try scene_writer.writeU64(1);
    try scene_writer.uv(root_parent);
    try scene_writer.string("root");
    try scene_writer.count(1, Limits.max_facts);
    try scene_writer.string("");
    try scene_writer.string("value");
    try scene_writer.count(0, Limits.max_actions);
    try scene_writer.writeU16(0);
    try scene_writer.byte(0);
    try scene_writer.byte(0);
    try scene_writer.byte(0);
    try scene_writer.byte(1);
    try scene_writer.string("row");
    const empty_fact_scene_bytes = try scene_writer.finish();
    defer t.allocator.free(empty_fact_scene_bytes);
    try t.expectError(error.InvalidData, decodeScene(t.allocator, empty_fact_scene_bytes));

    var action_writer = Writer.init(t.allocator);
    try header(&action_writer, scene_kind);
    try action_writer.count(1, Limits.max_nodes);
    try action_writer.writeU64(1);
    try action_writer.uv(root_parent);
    try action_writer.string("root");
    try action_writer.count(0, Limits.max_facts);
    try action_writer.count(0, Limits.max_actions);
    try action_writer.writeU16(0);
    try action_writer.byte(0);
    try action_writer.byte(0);
    try action_writer.byte(0);
    try action_writer.byte(3);
    try action_writer.string("");
    try action_writer.string("Run");
    try action_writer.byte(1);
    const empty_content_action_bytes = try action_writer.finish();
    defer t.allocator.free(empty_content_action_bytes);
    try t.expectError(error.InvalidData, decodeScene(t.allocator, empty_content_action_bytes));

    var target_writer = Writer.init(t.allocator);
    try header(&target_writer, target_kind);
    try target_writer.byte(targetKindTag(.file));
    try target_writer.string("file");
    try target_writer.count(1, Limits.max_facts);
    try target_writer.string("");
    try target_writer.string("value");
    const empty_fact_target_bytes = try target_writer.finish();
    defer t.allocator.free(empty_fact_target_bytes);
    try t.expectError(error.InvalidData, decodeTarget(t.allocator, empty_fact_target_bytes));
}

test "scene codec: duplicate facts/actions/bindings and invalid interaction tags refuse" {
    const duplicate_facts: semantic.scene.Node = .{
        .id = @enumFromInt(1),
        .facts = &.{ .{ .name = "same", .value = "a" }, .{ .name = "same", .value = "b" } },
        .content = .{ .label = "x" },
    };
    try t.expectError(error.Duplicate, encodeScene(t.allocator, duplicate_facts));
    const duplicate_node_actions: semantic.scene.Node = .{
        .id = @enumFromInt(1),
        .actions = &.{ .{ .id = "same", .label = "a" }, .{ .id = "same", .label = "b" } },
        .content = .{ .label = "x" },
    };
    try t.expectError(error.Duplicate, encodeScene(t.allocator, duplicate_node_actions));

    const duplicate_actions: semantic.interaction.Definition = .{
        .view = .{ .authority = .here, .slot = 1, .generation = 1 },
        .role = .dialog,
        .root = @enumFromInt(1),
        .actions = &.{ .{ .id = "go", .label = "Go" }, .{ .id = "go", .label = "Again" } },
    };
    try t.expectError(error.Duplicate, encodeInteraction(t.allocator, duplicate_actions));

    const duplicate_bindings: semantic.interaction.Definition = .{
        .view = .{ .authority = .here, .slot = 1, .generation = 1 },
        .role = .dialog,
        .root = @enumFromInt(1),
        .actions = &.{.{ .id = "go", .label = "Go" }},
        .bindings = &.{ .{ .input = "x", .action = "go" }, .{ .input = "x", .action = "go" } },
    };
    try t.expectError(error.Duplicate, encodeInteraction(t.allocator, duplicate_bindings));

    const interaction_definition: semantic.interaction.Definition = .{
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

    var invalid_disposition = try t.allocator.dupe(u8, encoded);
    defer t.allocator.free(invalid_disposition);
    var disposition_reader = try Reader.init(invalid_disposition);
    try checkHeader(&disposition_reader, interaction_kind);
    _ = try readViewHandle(&disposition_reader);
    _ = try roleFromTag(try disposition_reader.byte());
    _ = try disposition_reader.readU64();
    _ = try disposition_reader.count(Limits.max_actions);
    var disposition_arena = std.heap.ArenaAllocator.init(t.allocator);
    defer disposition_arena.deinit();
    _ = try disposition_reader.string(disposition_arena.allocator());
    _ = try disposition_reader.string(disposition_arena.allocator());
    _ = try disposition_reader.strictBool();
    invalid_disposition[disposition_reader.pos] = 0xff;
    try t.expectError(error.Corrupt, decodeInteraction(t.allocator, invalid_disposition));

    var invalid_view_generation = try t.allocator.dupe(u8, encoded);
    defer t.allocator.free(invalid_view_generation);
    @memset(invalid_view_generation[13..17], 0);
    try t.expectError(error.InvalidData, decodeInteraction(t.allocator, invalid_view_generation));

    const field_node: semantic.scene.Node = .{
        .id = @enumFromInt(1),
        .content = .{ .field = .{ .ref = .{ .authority = .here, .slot = 1, .generation = 1 } } },
    };
    const field_encoded = try encodeScene(t.allocator, field_node);
    defer t.allocator.free(field_encoded);
    var invalid_field_generation = try t.allocator.dupe(u8, field_encoded);
    defer t.allocator.free(invalid_field_generation);
    var field_reader = try Reader.init(invalid_field_generation);
    var field_arena = std.heap.ArenaAllocator.init(t.allocator);
    defer field_arena.deinit();
    try checkHeader(&field_reader, scene_kind);
    _ = try field_reader.count(Limits.max_nodes);
    _ = try field_reader.readU64();
    _ = try field_reader.uv();
    _ = try field_reader.string(field_arena.allocator());
    _ = try field_reader.count(Limits.max_facts);
    _ = try field_reader.count(Limits.max_actions);
    _ = try field_reader.readU16();
    _ = try field_reader.strictBool();
    _ = try field_reader.strictBool();
    _ = try field_reader.strictBool();
    try t.expectEqual(@as(u8, 2), try field_reader.byte());
    @memset(invalid_field_generation[field_reader.pos + 8 .. field_reader.pos + 12], 0);
    try t.expectError(error.InvalidData, decodeScene(t.allocator, invalid_field_generation));
}

test "scene codec: forward parent references and invalid target tags refuse" {
    const child: semantic.scene.Node = .{ .id = @enumFromInt(2), .content = .{ .label = "child" } };
    const root: semantic.scene.Node = .{ .id = @enumFromInt(1), .content = .{ .container = .{ .children = &.{child} } } };
    const encoded = try encodeScene(t.allocator, root);
    defer t.allocator.free(encoded);
    var invalid = try t.allocator.dupe(u8, encoded);
    defer t.allocator.free(invalid);
    var reader = try Reader.init(invalid);
    try checkHeader(&reader, scene_kind);
    _ = try reader.count(Limits.max_nodes);
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    _ = try readTempNode(&reader, arena.allocator(), false);
    // The child record starts with its id, followed by its parent varint.
    reader.pos += 8;
    invalid[reader.pos] = 2; // parent index must be earlier, not forward.
    try t.expectError(error.BadReference, decodeScene(t.allocator, invalid));

    const target_definition: semantic.target.Definition = .{ .kind = .file, .display_name = "f" };
    const target_bytes = try encodeTarget(t.allocator, target_definition);
    defer t.allocator.free(target_bytes);
    var invalid_target = try t.allocator.dupe(u8, target_bytes);
    defer t.allocator.free(invalid_target);
    invalid_target[5] = 0xfe;
    try t.expectError(error.Corrupt, decodeTarget(t.allocator, invalid_target));
}

test "scene codec: limits reject excessive child counts and action bindings" {
    var children: [Limits.max_children + 1]semantic.scene.Node = undefined;
    for (&children, 0..) |*child, i| child.* = .{ .id = @enumFromInt(@as(u64, i + 2)), .content = .{ .label = "x" } };
    const too_many: semantic.scene.Node = .{ .id = @enumFromInt(1), .content = .{ .container = .{ .children = &children } } };
    try t.expectError(error.LimitExceeded, encodeScene(t.allocator, too_many));
}
