//! Pure semantic projection from dired draft rows to a host-independent scene.
//!
//! The host owns field providers and mints `scene.FieldRef` values.  This
//! layer only carries those typed references into an arena-owned scene; it
//! never imports view runtime or mutates the dired model.

const std = @import("std");
const kernel = @import("weft_kernel");
const fs = @import("weft_fs");
const model = @import("model.zig");

const scene = kernel.scene;
const standard = kernel.action.standard;
const contract = fs.contract;

pub const FieldBinding = struct {
    row: model.NodeId,
    field: scene.FieldRef,
};

pub const metadata_column: u16 = 0;
pub const name_column: u16 = 16;
pub const original_column: u16 = 48;

pub const OwnedScene = struct {
    arena: std.heap.ArenaAllocator,
    value: scene.Node,

    pub fn deinit(self: *OwnedScene) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

const row_domain: u64 = 1;
const field_domain: u64 = 2;
const metadata_domain: u64 = 3;
const original_domain: u64 = 4;
const root_id: scene.NodeId = @enumFromInt((7 << 61) | 1);
const id_payload_mask: u64 = (@as(u64, 1) << 61) - 1;

/// Validate all external bindings before allocating any published scene.
pub fn project(gpa: std.mem.Allocator, rows: []const model.Row, bindings: []const FieldBinding) !OwnedScene {
    try validateInputs(rows, bindings);

    var owned: OwnedScene = .{ .arena = .init(gpa), .value = undefined };
    errdefer owned.deinit();
    const arena = owned.arena.allocator();
    const children = try arena.alloc(scene.Node, rows.len);
    for (rows, children) |row, *child| {
        const binding = findBinding(bindings, row.id).?;
        child.* = try projectRow(arena, row, binding.field);
    }
    owned.value = .{
        .id = root_id,
        .role = "dired",
        .content = .{ .container = .{ .axis = .vertical, .children = children } },
    };
    return owned;
}

fn validateInputs(rows: []const model.Row, bindings: []const FieldBinding) !void {
    for (rows, 0..) |row, index| {
        if (row.id == 0) return error.InvalidRow;
        _ = try stableId(row.id, row_domain);
        _ = try stableId(row.id, field_domain);
        _ = try stableId(row.id, metadata_domain);
        if (isOriginalVisible(row)) _ = try stableId(row.id, original_domain);
        for (rows[index + 1 ..]) |later| if (row.id == later.id) return error.DuplicateRow;
    }
    for (bindings, 0..) |binding, index| {
        if (binding.row == 0 or binding.field.generation == 0) return error.InvalidField;
        if (findRow(rows, binding.row) == null) return error.UnknownBinding;
        for (bindings[index + 1 ..]) |later| {
            if (binding.row == later.row) return error.DuplicateBinding;
            if (sameField(binding.field, later.field)) return error.DuplicateBinding;
        }
    }
    if (rows.len != bindings.len) return error.MissingBinding;
    for (rows) |row| if (findBinding(bindings, row.id) == null) return error.MissingBinding;
}

fn projectRow(arena: std.mem.Allocator, row: model.Row, field: scene.FieldRef) !scene.Node {
    const original_visible = isOriginalVisible(row);
    const child_count: usize = 2 + @as(usize, if (original_visible) 1 else 0);
    const children = try arena.alloc(scene.Node, child_count);
    const leaf_facts = try toneFacts(arena, row);
    children[0] = .{
        .id = try stableId(row.id, metadata_domain),
        .role = "dired.metadata",
        .layout = .{ .column = metadata_column },
        .facts = leaf_facts,
        .content = .{ .label = try metadataLabel(arena, row) },
    };
    children[1] = .{
        .id = try stableId(row.id, field_domain),
        .role = "dired.name",
        .layout = .{ .column = name_column },
        .facts = leaf_facts,
        .focusable = true,
        .content = .{ .field = .{ .ref = field, .single_line = true } },
    };
    if (original_visible) {
        const original = row.base.?.name;
        children[2] = .{
            .id = try stableId(row.id, original_domain),
            .role = "dired.original-name",
            .layout = .{ .column = original_column },
            .facts = leaf_facts,
            .content = .{ .label = try prefixedEscapedLabel(arena, "original: ", original) },
        };
    }

    const facts = try rowFacts(arena, row);
    const actions = try rowActions(arena, row);
    return .{
        .id = try stableId(row.id, row_domain),
        .role = "dired.row",
        .facts = facts,
        .actions = actions,
        .content = .{ .container = .{ .axis = .horizontal, .children = children } },
    };
}

fn rowFacts(arena: std.mem.Allocator, row: model.Row) ![]scene.Fact {
    var count: usize = 3;
    if (row.draft.mode != null) count += 1;
    if (row.conflict == .stale and row.pending != .observed) count += 1;
    const facts = try arena.alloc(scene.Fact, count);
    var index: usize = 0;
    facts[index] = .{ .name = "change", .value = changeName(row) };
    index += 1;
    facts[index] = .{ .name = "kind", .value = kindName(row.draft.kind) };
    index += 1;
    facts[index] = .{ .name = "tone", .value = toneName(row) };
    index += 1;
    if (row.draft.mode) |mode| {
        facts[index] = .{ .name = "mode", .value = try std.fmt.allocPrint(arena, "{d}", .{mode}) };
        index += 1;
    }
    if (row.conflict == .stale and row.pending != .observed) {
        facts[index] = .{ .name = "pending", .value = pendingName(row.pending) };
    }
    return facts;
}

fn rowActions(arena: std.mem.Allocator, row: model.Row) ![]scene.Action {
    const actions = try arena.alloc(scene.Action, 7);
    const unavailable = row.pending == .deleted or row.conflict == .stale;
    actions[0] = .{ .id = standard.open, .label = "Open", .enabled = !unavailable };
    actions[1] = .{ .id = standard.edit, .label = "Edit name", .enabled = row.pending != .deleted };
    actions[2] = .{ .id = standard.copy, .label = "Copy", .enabled = !unavailable };
    actions[3] = .{ .id = standard.cut, .label = "Cut", .enabled = !unavailable };
    actions[4] = .{ .id = standard.delete, .label = "Delete", .enabled = row.pending != .deleted };
    actions[5] = .{ .id = standard.paste_before, .label = "Paste before", .enabled = !unavailable };
    actions[6] = .{ .id = standard.paste_after, .label = "Paste after", .enabled = !unavailable };
    return actions;
}

fn metadataLabel(arena: std.mem.Allocator, row: model.Row) ![]const u8 {
    if (row.draft.mode) |mode| return std.fmt.allocPrint(arena, "kind={s} mode={d}", .{ kindName(row.draft.kind), mode });
    return std.fmt.allocPrint(arena, "kind={s}", .{kindName(row.draft.kind)});
}

fn prefixedEscapedLabel(arena: std.mem.Allocator, prefix: []const u8, value: []const u8) ![]const u8 {
    const escaped = try escapeLabel(arena, value);
    return std.fmt.allocPrint(arena, "{s}{s}", .{ prefix, escaped });
}

fn escapeLabel(arena: std.mem.Allocator, value: []const u8) ![]const u8 {
    var length: usize = 0;
    for (value) |byte| length += if (byte >= 0x20 and byte != 0x7f and byte != '\\') 1 else 4;
    const escaped = try arena.alloc(u8, length);
    var index: usize = 0;
    const hex = "0123456789abcdef";
    for (value) |byte| {
        if (byte >= 0x20 and byte != 0x7f and byte != '\\') {
            escaped[index] = byte;
            index += 1;
        } else {
            escaped[index] = '\\';
            escaped[index + 1] = 'x';
            escaped[index + 2] = hex[byte >> 4];
            escaped[index + 3] = hex[byte & 0xf];
            index += 4;
        }
    }
    return escaped;
}

fn changeName(row: model.Row) []const u8 {
    if (row.conflict == .stale) return "stale";
    return switch (row.pending) {
        .observed => "observed",
        .renamed => "rename",
        .modified => "modify",
        .added => "add",
        .copied, .copied_renamed => "copy",
        .deleted => "delete",
    };
}

fn toneName(row: model.Row) []const u8 {
    if (row.conflict == .stale) return "conflict";
    return switch (row.pending) {
        .observed => "normal",
        .renamed, .modified => "changed",
        .added, .copied, .copied_renamed => "added",
        .deleted => "deleted",
    };
}

fn toneFacts(arena: std.mem.Allocator, row: model.Row) ![]scene.Fact {
    const facts = try arena.alloc(scene.Fact, 1);
    facts[0] = .{ .name = "tone", .value = toneName(row) };
    return facts;
}

fn pendingName(pending: model.Pending) []const u8 {
    return switch (pending) {
        .observed => "observed",
        .renamed => "rename",
        .modified => "modified",
        .added => "add",
        .copied, .copied_renamed => "copy",
        .deleted => "delete",
    };
}

fn kindName(kind: contract.Kind) []const u8 {
    return switch (kind) {
        .regular => "regular",
        .directory => "directory",
        .symlink => "symlink",
        .other => "other",
    };
}

fn isOriginalVisible(row: model.Row) bool {
    return row.base != null and row.name_dirty;
}

fn stableId(raw: model.NodeId, domain: u64) !scene.NodeId {
    if (raw == 0 or raw > id_payload_mask or domain == 0 or domain > 7) return error.InvalidRow;
    return @enumFromInt((domain << 61) | raw);
}

fn findRow(rows: []const model.Row, id: model.NodeId) ?usize {
    for (rows, 0..) |row, index| if (row.id == id) return index;
    return null;
}

fn findBinding(bindings: []const FieldBinding, id: model.NodeId) ?FieldBinding {
    for (bindings) |binding| if (binding.row == id) return binding;
    return null;
}

fn sameField(left: scene.FieldRef, right: scene.FieldRef) bool {
    return left.authority == right.authority and left.slot == right.slot and left.generation == right.generation;
}

test "projection keeps row ids and order stable across draft rename" {
    var dired = model.Model.init(std.testing.allocator, .{ .authority = .here, .slot = 0, .generation = 1 });
    defer dired.deinit();
    try dired.reconcile(.{ .entries = &.{
        .{ .identity = .{ .authority = .here, .slot = 1, .generation = 1 }, .name = "a", .revision = "1", .kind = .regular },
        .{ .identity = .{ .authority = .here, .slot = 2, .generation = 1 }, .name = "b", .revision = "1", .kind = .regular },
    } });
    const refs = [_]FieldBinding{
        .{ .row = dired.rows.items[0].id, .field = .{ .authority = .here, .slot = 10, .generation = 1 } },
        .{ .row = dired.rows.items[1].id, .field = .{ .authority = .here, .slot = 11, .generation = 1 } },
    };
    var first = try project(std.testing.allocator, dired.rows.items, &refs);
    defer first.deinit();
    const first_ids = [_]scene.NodeId{ first.value.content.container.children[0].id, first.value.content.container.children[1].id };
    try dired.rename(dired.rows.items[0].id, "renamed");
    var second = try project(std.testing.allocator, dired.rows.items, &refs);
    defer second.deinit();
    try std.testing.expectEqual(first_ids[0], second.value.content.container.children[0].id);
    try std.testing.expectEqual(first_ids[1], second.value.content.container.children[1].id);
    try std.testing.expectEqual(
        first.value.content.container.children[0].content.container.children[0].id,
        second.value.content.container.children[0].content.container.children[0].id,
    );
}

test "projection keeps deleted rows visible and labels original renamed name" {
    var dired = model.Model.init(std.testing.allocator, .{ .authority = .here, .slot = 0, .generation = 1 });
    defer dired.deinit();
    try dired.reconcile(.{ .entries = &.{.{ .identity = .{ .authority = .here, .slot = 3, .generation = 1 }, .name = "old", .revision = "1", .kind = .regular }} });
    const id = dired.rows.items[0].id;
    try dired.rename(id, "new");
    try dired.markDelete(id);
    const refs = [_]FieldBinding{.{ .row = id, .field = .{ .authority = .here, .slot = 12, .generation = 1 } }};
    var output = try project(std.testing.allocator, dired.rows.items, &refs);
    defer output.deinit();
    const row = output.value.content.container.children[0];
    try std.testing.expectEqualStrings("delete", row.facts[0].value);
    try std.testing.expectEqual(@as(usize, 3), row.content.container.children.len);
    try std.testing.expectEqualStrings("original: old", row.content.container.children[2].content.label);
    try std.testing.expectEqualStrings("deleted", row.content.container.children[2].facts[0].value);
    try std.testing.expectEqualStrings(standard.paste_before, row.actions[5].id);
    try std.testing.expectEqualStrings(standard.paste_after, row.actions[6].id);
    try std.testing.expect(!row.actions[5].enabled and !row.actions[6].enabled);
}

test "projection reports add copy and stale facts with metadata" {
    var dired = model.Model.init(std.testing.allocator, .{ .authority = .here, .slot = 0, .generation = 1 });
    defer dired.deinit();
    const added = try dired.addDirectory(null, "new", 0);
    const refs = [_]FieldBinding{.{ .row = added, .field = .{ .authority = .here, .slot = 13, .generation = 1 } }};
    var added_output = try project(std.testing.allocator, dired.rows.items, &refs);
    defer added_output.deinit();
    try std.testing.expectEqualStrings("add", added_output.value.content.container.children[0].facts[0].value);
    try std.testing.expectEqualStrings("kind=directory mode=0", added_output.value.content.container.children[0].content.container.children[0].content.label);

    try dired.markDelete(added);
    var stale_output = try project(std.testing.allocator, dired.rows.items, &refs);
    defer stale_output.deinit();
    try std.testing.expectEqualStrings("delete", stale_output.value.content.container.children[0].facts[0].value);

    var source = model.Model.init(std.testing.allocator, .{ .authority = .here, .slot = 1, .generation = 1 });
    defer source.deinit();
    try source.reconcile(.{ .entries = &.{.{ .identity = .{ .authority = .here, .slot = 20, .generation = 1 }, .name = "source", .revision = "1", .kind = .regular }} });
    var item = try source.yank(source.rows.items[0].id, .copy);
    defer item.deinit();
    const copied = try dired.paste(null, &item);
    const copy_refs = [_]FieldBinding{
        .{ .row = added, .field = .{ .authority = .here, .slot = 13, .generation = 1 } },
        .{ .row = copied, .field = .{ .authority = .here, .slot = 14, .generation = 1 } },
    };
    var copy_output = try project(std.testing.allocator, dired.rows.items, &copy_refs);
    defer copy_output.deinit();
    try std.testing.expectEqualStrings("copy", copy_output.value.content.container.children[1].facts[0].value);

    var stale_source = model.Model.init(std.testing.allocator, .{ .authority = .here, .slot = 2, .generation = 1 });
    defer stale_source.deinit();
    try stale_source.reconcile(.{ .entries = &.{.{ .identity = .{ .authority = .here, .slot = 21, .generation = 1 }, .name = "stale", .revision = "1", .kind = .regular }} });
    const stale_id = stale_source.rows.items[0].id;
    try stale_source.rename(stale_id, "draft");
    try stale_source.reconcile(.{ .entries = &.{} });
    const stale_refs = [_]FieldBinding{.{ .row = stale_id, .field = .{ .authority = .here, .slot = 15, .generation = 1 } }};
    var stale_projection = try project(std.testing.allocator, stale_source.rows.items, &stale_refs);
    defer stale_projection.deinit();
    try std.testing.expectEqualStrings("stale", stale_projection.value.content.container.children[0].facts[0].value);
}

test "projection fixes metadata field columns and styles mode-only modifications" {
    var dired = model.Model.init(std.testing.allocator, .{ .authority = .here, .slot = 0, .generation = 1 });
    defer dired.deinit();
    try dired.reconcile(.{ .entries = &.{.{ .identity = .{ .authority = .here, .slot = 30, .generation = 1 }, .name = "mode", .revision = "1", .kind = .regular, .mode = 0o644 }} });
    const id = dired.rows.items[0].id;
    try dired.setMode(id, 0);
    const refs = [_]FieldBinding{.{ .row = id, .field = .{ .authority = .here, .slot = 17, .generation = 1 } }};
    var output = try project(std.testing.allocator, dired.rows.items, &refs);
    defer output.deinit();
    const row = output.value.content.container.children[0];
    const children = row.content.container.children;
    try std.testing.expectEqual(@as(usize, 2), children.len);
    try std.testing.expectEqual(metadata_column, children[0].layout.column.?);
    try std.testing.expectEqual(name_column, children[1].layout.column.?);
    try std.testing.expectEqualStrings("modify", row.facts[0].value);
    try std.testing.expectEqualStrings("changed", row.facts[2].value);
    try std.testing.expectEqualStrings("changed", children[0].facts[0].value);
    try std.testing.expectEqualStrings("changed", children[1].facts[0].value);
    try std.testing.expectEqualStrings(standard.paste_before, row.actions[5].id);
    try std.testing.expect(row.actions[5].enabled and row.actions[6].enabled);
}

test "projection rejects duplicate missing and generation-zero bindings" {
    var dired = model.Model.init(std.testing.allocator, .{ .authority = .here, .slot = 0, .generation = 1 });
    defer dired.deinit();
    try dired.reconcile(.{ .entries = &.{.{ .identity = .{ .authority = .here, .slot = 4, .generation = 1 }, .name = "x", .revision = "1", .kind = .regular }} });
    const id = dired.rows.items[0].id;
    try std.testing.expectError(error.MissingBinding, project(std.testing.allocator, dired.rows.items, &.{}));
    const duplicate = [_]FieldBinding{
        .{ .row = id, .field = .{ .authority = .here, .slot = 14, .generation = 1 } },
        .{ .row = id, .field = .{ .authority = .here, .slot = 15, .generation = 1 } },
    };
    try std.testing.expectError(error.DuplicateBinding, project(std.testing.allocator, dired.rows.items, &duplicate));
    const zero = [_]FieldBinding{.{ .row = id, .field = .{ .authority = .here, .slot = 14, .generation = 0 } }};
    try std.testing.expectError(error.InvalidField, project(std.testing.allocator, dired.rows.items, &zero));
}

test "projection leaves unusual raw names in model provider data" {
    var dired = model.Model.init(std.testing.allocator, .{ .authority = .here, .slot = 0, .generation = 1 });
    defer dired.deinit();
    const raw = "line\n-[]'\\";
    try dired.reconcile(.{ .entries = &.{.{ .identity = .{ .authority = .here, .slot = 5, .generation = 1 }, .name = raw, .revision = "1", .kind = .regular }} });
    const id = dired.rows.items[0].id;
    const refs = [_]FieldBinding{.{ .row = id, .field = .{ .authority = .here, .slot = 16, .generation = 1 } }};
    var output = try project(std.testing.allocator, dired.rows.items, &refs);
    defer output.deinit();
    try std.testing.expectEqualStrings(raw, dired.rows.items[0].draft.name);
}
