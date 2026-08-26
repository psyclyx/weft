//! Pure semantic projection from dired draft rows to a host-independent scene.
//!
//! The host owns field providers and mints `scene.FieldRef` values.  This
//! layer only carries those typed references into an arena-owned scene; it
//! never imports view runtime or mutates the dired model.

const std = @import("std");
const semantic = @import("weft_semantic");
const fs = @import("weft_fs");
const model = @import("weft_dired_model");

const scene = semantic.scene;
const standard = semantic.action.standard;
const contract = fs.contract;

pub const FieldBinding = struct {
    row: model.NodeId,
    /// The row's primary navigation field. Ordinary focus traversal visits
    /// exactly this field once per row.
    field: scene.FieldRef,
    /// An optional, provider-capability-dependent POSIX mode editor. It is a
    /// secondary field entered by an advertised action, not another primary
    /// traversal stop.
    mode_field: ?scene.FieldRef = null,
    /// An exact, revision-stamped target for an observed directory row. A
    /// missing link is intentional for pending, deleted, stale, and
    /// provider-unobserved rows.
    target: ?scene.TargetLink = null,
};

pub const permissions_edit_action = fs.action.permissions_edit;
pub const create_file_action = fs.action.entry_create_file;
pub const create_directory_action = fs.action.entry_create_directory;

/// Root-level capabilities are supplied by the session adapter. The pure
/// projection does not query target registries or infer hierarchy from paths.
pub const Options = struct {
    has_container: bool = false,
};

pub const metadata_column: u16 = 0;
pub const mode_column: u16 = 4;
pub const name_column: u16 = 11;
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
const mode_domain: u64 = 5;
const root_id: scene.NodeId = @enumFromInt((7 << 61) | 1);
const id_payload_mask: u64 = (@as(u64, 1) << 61) - 1;

/// Validate all external bindings before allocating any published scene.
pub fn project(gpa: std.mem.Allocator, rows: []const model.Row, bindings: []const FieldBinding) !OwnedScene {
    return projectWith(gpa, rows, bindings, .{});
}

pub fn projectWith(gpa: std.mem.Allocator, rows: []const model.Row, bindings: []const FieldBinding, options: Options) !OwnedScene {
    try validateInputs(rows, bindings);

    var owned: OwnedScene = .{ .arena = .init(gpa), .value = undefined };
    errdefer owned.deinit();
    const arena = owned.arena.allocator();
    const children = try arena.alloc(scene.Node, rows.len);
    for (rows, children) |row, *child| {
        const binding = findBinding(bindings, row.id).?;
        child.* = try projectRow(arena, row, binding);
    }
    owned.value = .{
        .id = root_id,
        .role = "files",
        // The container itself is a focus stop only when there is no ordinary
        // name field to select. Root actions remain reachable through every
        // row's ancestor path in non-empty directories.
        .focusable = rows.len == 0,
        .actions = try rootActions(arena, rows, options),
        .content = .{ .container = .{ .axis = .vertical, .children = children } },
    };
    return owned;
}

fn rootActions(arena: std.mem.Allocator, rows: []const model.Row, options: Options) ![]scene.Action {
    var dirty = false;
    for (rows) |*row| {
        if (model.rowHasPendingChanges(row)) {
            dirty = true;
            break;
        }
    }
    const result = try arena.alloc(scene.Action, 8 + @as(usize, @intFromBool(options.has_container)));
    var index: usize = 0;
    if (options.has_container) {
        result[index] = .{ .id = standard.open_container, .label = "Open container" };
        index += 1;
    }
    result[index] = .{ .id = standard.refresh, .label = "Refresh" };
    result[index + 1] = .{ .id = create_file_action, .label = "New file" };
    result[index + 2] = .{ .id = create_directory_action, .label = "New directory" };
    result[index + 3] = .{ .id = standard.paste_after, .label = "Paste into directory" };
    result[index + 4] = .{ .id = standard.paste_before, .label = "Paste into directory" };
    result[index + 5] = .{ .id = standard.apply, .label = "Apply draft", .enabled = dirty };
    result[index + 6] = .{ .id = standard.revert, .label = "Revert draft", .enabled = dirty };
    result[index + 7] = .{ .id = standard.set_working_target, .label = "Use as working target" };
    return result;
}

fn validateInputs(rows: []const model.Row, bindings: []const FieldBinding) !void {
    for (rows, 0..) |row, index| {
        if (row.id == 0) return error.InvalidRow;
        _ = try stableId(row.id, row_domain);
        _ = try stableId(row.id, field_domain);
        _ = try stableId(row.id, metadata_domain);
        _ = try stableId(row.id, mode_domain);
        if (isOriginalVisible(row)) _ = try stableId(row.id, original_domain);
        for (rows[index + 1 ..]) |later| if (row.id == later.id) return error.DuplicateRow;
    }
    for (bindings, 0..) |binding, index| {
        if (binding.row == 0 or binding.field.generation == 0 or
            (binding.mode_field != null and binding.mode_field.?.generation == 0))
            return error.InvalidField;
        if (binding.target) |target| try scene.validateTargetLink(target);
        if (findRow(rows, binding.row) == null) return error.UnknownBinding;
        if (binding.mode_field) |mode_field| {
            if (sameField(binding.field, mode_field)) return error.DuplicateBinding;
        }
        for (bindings[index + 1 ..]) |later| {
            if (binding.row == later.row) return error.DuplicateBinding;
            if (sameField(binding.field, later.field)) return error.DuplicateBinding;
            if (later.mode_field) |later_mode| {
                if (sameField(binding.field, later_mode)) return error.DuplicateBinding;
            }
            if (binding.mode_field) |mode_field| {
                if (sameField(mode_field, later.field)) return error.DuplicateBinding;
                if (later.mode_field) |later_mode| {
                    if (sameField(mode_field, later_mode)) return error.DuplicateBinding;
                }
            }
        }
    }
    if (rows.len != bindings.len) return error.MissingBinding;
    for (rows) |row| if (findBinding(bindings, row.id) == null) return error.MissingBinding;
}

fn projectRow(arena: std.mem.Allocator, row: model.Row, binding: FieldBinding) !scene.Node {
    const original_visible = isOriginalVisible(row);
    // Metadata, mode, and name are structural columns even when the provider
    // cannot edit modes. Rows therefore never shift horizontally as their
    // kind or capability changes.
    const child_count: usize = 3 + @as(usize, if (original_visible) 1 else 0);
    const children = try arena.alloc(scene.Node, child_count);
    const leaf_facts = try toneFacts(arena, row);
    children[0] = .{
        .id = try stableId(row.id, metadata_domain),
        .role = "files.metadata",
        .layout = .{ .column = metadata_column },
        .facts = leaf_facts,
        .content = .{ .label = kindGlyph(row.draft.kind) },
    };
    children[1] = .{
        .id = try stableId(row.id, mode_domain),
        .role = "files.mode",
        .layout = .{ .column = mode_column, .min_cells = 4 },
        .facts = leaf_facts,
        .content = if (binding.mode_field) |mode_field|
            .{ .field = .{ .ref = mode_field, .placeholder = "mode", .single_line = true } }
        else
            .{ .label = try modeLabel(arena, row.draft.mode) },
    };
    children[2] = .{
        .id = try stableId(row.id, field_domain),
        .role = "files.name",
        .layout = .{ .column = name_column },
        .facts = leaf_facts,
        .target = binding.target,
        .focusable = true,
        .content = .{ .field = .{ .ref = binding.field, .single_line = true } },
    };
    if (original_visible) {
        const original = row.base.?.name;
        children[3] = .{
            .id = try stableId(row.id, original_domain),
            .role = "files.original-name",
            .layout = .{ .column = original_column },
            .facts = leaf_facts,
            .content = .{ .label = try prefixedEscapedLabel(arena, "original: ", original) },
        };
    }

    const facts = try rowFacts(arena, row);
    const actions = try rowActions(arena, row, binding.mode_field != null, binding.target != null);
    return .{
        .id = try stableId(row.id, row_domain),
        .role = "files.row",
        .facts = facts,
        .actions = actions,
        .target = binding.target,
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

fn rowActions(arena: std.mem.Allocator, row: model.Row, mode_editable: bool, has_target: bool) ![]scene.Action {
    const unavailable = row.pending == .deleted or row.conflict == .stale;
    const can_set_working = row.draft.kind == .directory and has_target and !unavailable;
    const actions = try arena.alloc(scene.Action, 9 +
        @as(usize, @intFromBool(mode_editable)) +
        @as(usize, @intFromBool(can_set_working)));
    actions[0] = .{ .id = standard.open, .label = "Open", .enabled = !unavailable and has_target };
    // Deletion is a reversible draft state, not the destruction of this row.
    // Keep its name editor advertised so any input policy can revive it; only
    // an externally stale row is unsafe to edit.
    actions[1] = .{ .id = standard.edit, .label = "Edit name", .enabled = row.conflict != .stale };
    actions[2] = .{ .id = standard.copy, .label = "Copy", .enabled = !unavailable };
    actions[3] = .{ .id = standard.cut, .label = "Cut", .enabled = !unavailable };
    actions[4] = .{ .id = standard.delete, .label = "Delete", .enabled = row.pending != .deleted };
    actions[5] = .{ .id = standard.paste_before, .label = "Paste before", .enabled = row.conflict != .stale };
    actions[6] = .{ .id = standard.paste_after, .label = "Paste after", .enabled = row.conflict != .stale };
    actions[7] = .{ .id = create_file_action, .label = "New file" };
    actions[8] = .{ .id = create_directory_action, .label = "New directory" };
    var index: usize = 9;
    if (mode_editable) {
        actions[index] = .{
            .id = permissions_edit_action,
            .label = "Edit permissions",
            .enabled = !unavailable,
        };
        index += 1;
    }
    if (can_set_working) actions[index] = .{
        .id = standard.set_working_target,
        .label = "Use as working target",
    };
    return actions;
}

fn modeLabel(arena: std.mem.Allocator, mode: ?u32) ![]const u8 {
    if (mode) |value| return std.fmt.allocPrint(arena, "{o:0>4}", .{value});
    return arena.dupe(u8, "----");
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

fn kindGlyph(kind: contract.Kind) []const u8 {
    return switch (kind) {
        .regular => "·",
        .directory => "▸",
        .symlink => "↗",
        .other => "?",
    };
}

fn isOriginalVisible(row: model.Row) bool {
    return row.base != null and row.name_dirty;
}

fn stableId(raw: model.NodeId, domain: u64) !scene.NodeId {
    if (raw == 0 or raw > id_payload_mask or domain == 0 or domain > 7) return error.InvalidRow;
    return @enumFromInt((domain << 61) | raw);
}

/// Stable semantic identity for the row node corresponding to a model row.
/// Providers use this instead of visible position or a renderer-local index.
pub fn rowNodeId(raw: model.NodeId) !scene.NodeId {
    return stableId(raw, row_domain);
}

/// Stable identity of a row's ordinary editable name field. Actions which
/// create an entry focus this node so any editing model can immediately edit
/// the selected placeholder through the generic field endpoint.
pub fn nameNodeId(raw: model.NodeId) !scene.NodeId {
    return stableId(raw, field_domain);
}

/// Stable identity of a row's secondary permissions field/label node.
pub fn modeNodeId(raw: model.NodeId) !scene.NodeId {
    return stableId(raw, mode_domain);
}

pub fn rootNodeId() scene.NodeId {
    return root_id;
}

/// Resolve only row-domain scene identities back to model identity.
pub fn modelRowId(node: scene.NodeId) !model.NodeId {
    const raw = @intFromEnum(node);
    if (raw >> 61 != row_domain) return error.UnknownRow;
    const id = raw & id_payload_mask;
    if (id == 0) return error.UnknownRow;
    return id;
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
    try std.testing.expectEqualStrings(standard.refresh, first.value.actions[0].id);
    try std.testing.expect(first.value.actions[0].enabled);
    try std.testing.expectEqualStrings(standard.paste_after, first.value.actions[3].id);
    try std.testing.expect(first.value.actions[3].enabled);
    try std.testing.expect(!first.value.actions[5].enabled);
    try std.testing.expectEqualStrings(standard.set_working_target, first.value.actions[7].id);
    var with_container = try projectWith(std.testing.allocator, dired.rows.items, &refs, .{ .has_container = true });
    defer with_container.deinit();
    try std.testing.expectEqualStrings(standard.open_container, with_container.value.actions[0].id);
    try std.testing.expectEqualStrings(standard.refresh, with_container.value.actions[1].id);
    try std.testing.expectEqualStrings(standard.set_working_target, with_container.value.actions[8].id);
    const first_ids = [_]scene.NodeId{ first.value.content.container.children[0].id, first.value.content.container.children[1].id };
    try dired.rename(dired.rows.items[0].id, "renamed");
    var second = try project(std.testing.allocator, dired.rows.items, &refs);
    defer second.deinit();
    try std.testing.expect(second.value.actions[5].enabled and second.value.actions[6].enabled);
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
    try std.testing.expectEqual(@as(usize, 4), row.content.container.children.len);
    try std.testing.expectEqualStrings("original: old", row.content.container.children[3].content.label);
    try std.testing.expectEqualStrings("deleted", row.content.container.children[3].facts[0].value);
    try std.testing.expectEqualStrings(standard.edit, row.actions[1].id);
    try std.testing.expect(row.actions[1].enabled);
    try std.testing.expectEqualStrings(standard.paste_before, row.actions[5].id);
    try std.testing.expectEqualStrings(standard.paste_after, row.actions[6].id);
    try std.testing.expect(row.actions[5].enabled and row.actions[6].enabled);
}

test "projection reports add copy and stale facts with metadata" {
    var dired = model.Model.init(std.testing.allocator, .{ .authority = .here, .slot = 0, .generation = 1 });
    defer dired.deinit();
    const added = try dired.addDirectory(null, "new", 0);
    const refs = [_]FieldBinding{.{ .row = added, .field = .{ .authority = .here, .slot = 13, .generation = 1 } }};
    var added_output = try project(std.testing.allocator, dired.rows.items, &refs);
    defer added_output.deinit();
    try std.testing.expectEqualStrings("add", added_output.value.content.container.children[0].facts[0].value);
    const added_children = added_output.value.content.container.children[0].content.container.children;
    try std.testing.expectEqualStrings("▸", added_children[0].content.label);
    try std.testing.expectEqualStrings("0000", added_children[1].content.label);

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
    const refs = [_]FieldBinding{.{
        .row = id,
        .field = .{ .authority = .here, .slot = 17, .generation = 1 },
        .mode_field = .{ .authority = .here, .slot = 18, .generation = 1 },
    }};
    var output = try project(std.testing.allocator, dired.rows.items, &refs);
    defer output.deinit();
    const row = output.value.content.container.children[0];
    const children = row.content.container.children;
    try std.testing.expectEqual(@as(usize, 3), children.len);
    try std.testing.expectEqual(metadata_column, children[0].layout.column.?);
    try std.testing.expectEqual(mode_column, children[1].layout.column.?);
    try std.testing.expectEqual(name_column, children[2].layout.column.?);
    try std.testing.expect(!children[1].focusable);
    try std.testing.expectEqual(refs[0].mode_field.?, children[1].content.field.ref);
    try std.testing.expectEqual(try modeNodeId(id), children[1].id);
    try std.testing.expectEqualStrings("modify", row.facts[0].value);
    try std.testing.expectEqualStrings("changed", row.facts[2].value);
    try std.testing.expectEqualStrings("changed", children[0].facts[0].value);
    try std.testing.expectEqualStrings("changed", children[1].facts[0].value);
    try std.testing.expectEqualStrings("changed", children[2].facts[0].value);
    try std.testing.expectEqualStrings(standard.paste_before, row.actions[5].id);
    try std.testing.expect(row.actions[5].enabled and row.actions[6].enabled);
    try std.testing.expectEqual(@as(usize, 10), row.actions.len);
    try std.testing.expectEqualStrings(permissions_edit_action, row.actions[9].id);
    try std.testing.expect(row.actions[9].enabled);
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
    const same_mode = [_]FieldBinding{.{
        .row = id,
        .field = .{ .authority = .here, .slot = 14, .generation = 1 },
        .mode_field = .{ .authority = .here, .slot = 14, .generation = 1 },
    }};
    try std.testing.expectError(error.DuplicateBinding, project(std.testing.allocator, dired.rows.items, &same_mode));
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
