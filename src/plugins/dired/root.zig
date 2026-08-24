//! Pure dired draft/reconcile model.
//!
//! The model owns browser state only.  It observes filesystem identities and
//! revisions, keeps editable drafts, and emits typed `weft_fs` plans.  It does
//! not call a provider and it does not share mutable state with a guest or
//! another dired instance.

const std = @import("std");
const kernel = @import("weft_kernel");
const fs = @import("weft_fs");

const transfer = kernel.transfer;
const contract = fs.contract;

pub const NodeId = u64;
pub const max_transfer_payload: usize = 1 << 20;
pub const max_transfer_records: usize = 4096;
pub const max_transfer_name: usize = 1 << 16;
pub const max_transfer_revision: usize = 1 << 16;

pub const Pending = enum {
    observed,
    renamed,
    modified,
    added,
    copied,
    copied_renamed,
    deleted,
};

pub const Conflict = enum { none, stale };

pub const SnapshotEntry = struct {
    identity: contract.EntryRef,
    name: []const u8,
    revision: []const u8,
    kind: contract.Kind,
    mode: ?u32 = null,
    contents: []const u8 = &.{},
    link_target: []const u8 = &.{},
};

pub const Snapshot = struct { entries: []const SnapshotEntry };

pub const Observation = struct {
    identity: contract.EntryRef,
    revision: []u8,
    name: []u8,
    kind: contract.Kind,
    mode: ?u32,
};

pub const Draft = struct {
    name: []u8,
    kind: contract.Kind,
    mode: ?u32,
    contents: []u8,
    link_target: []u8,
};

const CopySource = struct {
    root: contract.Root,
    entry: contract.EntryRef,
    revision: []u8,
    intent: transfer.Intent,
};

pub const Row = struct {
    id: NodeId,
    parent: ?NodeId,
    /// `base` is the last clean observation; `current` is the latest external
    /// observation.  Dirty rows retain base when current changes or vanishes.
    base: ?Observation,
    current: ?Observation,
    draft: Draft,
    pending: Pending,
    conflict: Conflict = .none,
    name_dirty: bool = false,
    mode_dirty: bool = false,
    copy_source: ?CopySource = null,
};

pub const OwnedPlan = struct {
    arena: std.heap.ArenaAllocator,
    value: contract.Plan,

    pub fn deinit(self: *OwnedPlan) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

const entry_media = "application/x-weft-dired-entry";
const entry_schema = "weft.dired.entry.v1";
const tree_media = "application/x-weft-dired-tree";
const tree_schema = "weft.dired.tree.v1";
const entry_magic = "weft-dired-entry-v1\x00";
const tree_magic = "weft-dired-tree-v1\x00";
const no_parent = std.math.maxInt(u32);

pub const Model = struct {
    gpa: std.mem.Allocator,
    root: contract.Root,
    rows: std.ArrayList(Row) = .empty,
    next_id: NodeId = 1,

    pub fn init(gpa: std.mem.Allocator, root: contract.Root) Model {
        return .{ .gpa = gpa, .root = root };
    }

    pub fn deinit(self: *Model) void {
        for (self.rows.items) |*row_ptr| self.freeRow(row_ptr);
        self.rows.deinit(self.gpa);
        self.* = undefined;
    }

    pub fn row(self: *const Model, id: NodeId) ?*const Row {
        for (self.rows.items) |*candidate| if (candidate.id == id) return candidate;
        return null;
    }

    pub fn rowForIdentity(self: *const Model, identity: contract.EntryRef) ?NodeId {
        for (self.rows.items) |candidate| {
            if (candidate.current) |current| if (sameEntry(current.identity, identity)) return candidate.id;
            if (candidate.base) |base| if (sameEntry(base.identity, identity)) return candidate.id;
        }
        return null;
    }

    /// Reconcile by identity, never by listing position or visible name.
    /// Dirty rows remain present when their source disappears, marked stale.
    pub fn reconcile(self: *Model, snapshot: Snapshot) !void {
        var seen = std.AutoHashMapUnmanaged(NodeId, void).empty;
        defer seen.deinit(self.gpa);
        for (snapshot.entries) |entry| {
            if (self.rowForIdentity(entry.identity)) |id| {
                const row_ptr = self.rowMutable(id).?;
                try seen.put(self.gpa, id, {});
                if (isDirty(row_ptr)) {
                    self.replaceObservation(&row_ptr.current, entry) catch return error.OutOfMemory;
                    row_ptr.conflict = .none;
                } else {
                    self.freeObservation(&row_ptr.base);
                    self.freeObservation(&row_ptr.current);
                    row_ptr.base = try cloneObservation(self.gpa, entry);
                    row_ptr.current = try cloneObservation(self.gpa, entry);
                    try self.replaceDraftFromSnapshot(row_ptr, entry);
                    row_ptr.conflict = .none;
                }
            } else {
                const id = try self.appendObserved(null, entry);
                try seen.put(self.gpa, id, {});
            }
        }

        var remove: std.ArrayList(NodeId) = .empty;
        defer remove.deinit(self.gpa);
        for (self.rows.items) |*row_ptr| {
            if (seen.contains(row_ptr.id)) continue;
            if (isDirty(row_ptr)) {
                self.freeObservation(&row_ptr.current);
                row_ptr.current = null;
                row_ptr.conflict = .stale;
            } else try remove.append(self.gpa, row_ptr.id);
        }
        for (remove.items) |id| self.removeRow(id);
    }

    pub fn rename(self: *Model, id: NodeId, name: []const u8) !void {
        _ = try contract.Name.init(name);
        const row_ptr = self.rowMutable(id) orelse return error.UnknownNode;
        try self.replaceBytes(&row_ptr.draft.name, name);
        row_ptr.name_dirty = true;
        if (row_ptr.pending == .observed) row_ptr.pending = .renamed;
        if (row_ptr.pending == .copied) row_ptr.pending = .copied_renamed;
    }

    pub fn setMode(self: *Model, id: NodeId, mode: u32) !void {
        const row_ptr = self.rowMutable(id) orelse return error.UnknownNode;
        row_ptr.draft.mode = mode;
        row_ptr.mode_dirty = true;
        if (row_ptr.pending == .observed) row_ptr.pending = .modified;
    }

    pub fn markDelete(self: *Model, id: NodeId) !void {
        const row_ptr = self.rowMutable(id) orelse return error.UnknownNode;
        row_ptr.pending = .deleted;
    }

    pub fn addDirectory(self: *Model, parent: ?NodeId, name: []const u8, mode: ?u32) !NodeId {
        return self.appendPending(parent, name, .directory, mode, &.{}, &.{}, .added);
    }

    pub fn addFile(self: *Model, parent: ?NodeId, name: []const u8, contents: []const u8, mode: ?u32) !NodeId {
        return self.appendPending(parent, name, .regular, mode, contents, &.{}, .added);
    }

    pub fn addSymlink(self: *Model, parent: ?NodeId, name: []const u8, link_target: []const u8) !NodeId {
        return self.appendPending(parent, name, .symlink, null, &.{}, link_target, .added);
    }

    /// Capture an independent transfer value. `OwnedItem` deep-copies every
    /// representation, so this item remains valid after `self.deinit()`.
    pub fn yank(self: *const Model, id: NodeId, intent: transfer.Intent) !transfer.OwnedItem {
        const row_ptr = self.row(id) orelse return error.UnknownNode;
        var payload: []u8 = &.{};
        defer if (payload.len != 0) self.gpa.free(payload);
        var reps: [1]transfer.Representation = undefined;
        if (sourceFor(self, row_ptr)) |source| {
            payload = try encodeEntry(self.gpa, source.root, source.entry, source.revision);
            reps[0] = .{ .media_type = entry_media, .schema = entry_schema, .payload = payload };
        } else {
            payload = try self.encodeTree(id);
            reps[0] = .{ .media_type = tree_media, .schema = tree_schema, .payload = payload };
        }
        return transfer.OwnedItem.init(self.gpa, .{
            .intent = intent,
            .suggested_name = row_ptr.draft.name,
            .representations = &reps,
        });
    }

    /// Paste mutates the destination draft. No one-off plan is returned: the
    /// visible rows and `buildPlan()` are the same preview/apply source.
    pub fn paste(self: *Model, parent: ?NodeId, item: *const transfer.OwnedItem) !NodeId {
        const value = item.value;
        if (value.representation(entry_media)) |representation| {
            if (!std.mem.eql(u8, representation.schema orelse return error.InvalidTransfer, entry_schema)) return error.InvalidTransfer;
            const captured = try decodeEntry(representation.payload);
            return self.appendCopied(parent, value.suggested_name, captured, value.intent);
        }
        const representation = value.representation(tree_media) orelse return error.UnsupportedTransfer;
        if (!std.mem.eql(u8, representation.schema orelse return error.InvalidTransfer, tree_schema)) return error.InvalidTransfer;
        return self.decodeTree(parent, value.suggested_name, representation.payload, value.intent);
    }

    /// Build the one typed effect plan consumed by preview/apply. It includes
    /// all visible dirty rows, not hidden clipboard state.
    pub fn buildPlan(self: *const Model) !OwnedPlan {
        var owned: OwnedPlan = .{ .arena = .init(self.gpa), .value = undefined };
        errdefer owned.deinit();
        var builder = Builder.init(owned.arena.allocator(), self);
        try builder.build();
        owned.value = .{
            .root = self.root,
            .base_revision = &.{},
            .operations = try owned.arena.allocator().dupe(contract.Planned, builder.operations.items),
        };
        return owned;
    }

    fn appendObserved(self: *Model, parent: ?NodeId, entry: SnapshotEntry) !NodeId {
        const base = try cloneObservation(self.gpa, entry);
        errdefer freeObservationWith(self.gpa, &base);
        const current = try cloneObservation(self.gpa, entry);
        errdefer freeObservationWith(self.gpa, &current);
        const draft = try draftFrom(self.gpa, entry);
        errdefer freeDraftWith(self.gpa, &draft);
        const id = self.next_id;
        self.next_id += 1;
        try self.rows.append(self.gpa, .{ .id = id, .parent = parent, .base = base, .current = current, .draft = draft, .pending = .observed });
        return id;
    }

    fn appendPending(self: *Model, parent: ?NodeId, name: []const u8, kind: contract.Kind, mode: ?u32, contents: []const u8, link_target: []const u8, pending: Pending) !NodeId {
        try self.validateParent(parent);
        _ = try contract.Name.init(name);
        const draft = Draft{ .name = try self.gpa.dupe(u8, name), .kind = kind, .mode = mode, .contents = try self.gpa.dupe(u8, contents), .link_target = try self.gpa.dupe(u8, link_target) };
        errdefer freeDraftWith(self.gpa, &draft);
        const id = self.next_id;
        self.next_id += 1;
        try self.rows.append(self.gpa, .{ .id = id, .parent = parent, .base = null, .current = null, .draft = draft, .pending = pending });
        return id;
    }

    fn appendCopied(self: *Model, parent: ?NodeId, name: []const u8, captured: EntryCapture, intent: transfer.Intent) !NodeId {
        try self.validateParent(parent);
        const id = try self.appendPending(parent, name, captured.kind, captured.mode, &.{}, &.{}, .copied);
        const row_ptr = self.rowMutable(id).?;
        row_ptr.copy_source = .{ .root = captured.root, .entry = captured.entry, .revision = try self.gpa.dupe(u8, captured.revision), .intent = intent };
        return id;
    }

    fn replaceDraftFromSnapshot(self: *Model, row_ptr: *Row, entry: SnapshotEntry) !void {
        try self.replaceBytes(&row_ptr.draft.name, entry.name);
        row_ptr.draft.kind = entry.kind;
        row_ptr.draft.mode = entry.mode;
        try self.replaceBytes(&row_ptr.draft.contents, entry.contents);
        try self.replaceBytes(&row_ptr.draft.link_target, entry.link_target);
        row_ptr.name_dirty = false;
        row_ptr.mode_dirty = false;
        row_ptr.pending = .observed;
        row_ptr.copy_source = null;
    }

    fn validateParent(self: *const Model, parent: ?NodeId) !void {
        var seen: std.AutoHashMapUnmanaged(NodeId, void) = .empty;
        defer seen.deinit(self.gpa);
        var cursor = parent;
        while (cursor) |id| {
            if (seen.contains(id)) return error.ParentCycle;
            try seen.put(self.gpa, id, {});
            const parent_row = self.row(id) orelse return error.UnknownParent;
            if (parent_row.draft.kind != .directory) return error.NotDirectory;
            cursor = parent_row.parent;
        }
    }

    fn replaceObservation(self: *Model, slot: *?Observation, entry: SnapshotEntry) !void {
        self.freeObservation(slot);
        slot.* = try cloneObservation(self.gpa, entry);
    }

    fn replaceBytes(self: *Model, slot: *[]u8, value: []const u8) !void {
        const next = try self.gpa.dupe(u8, value);
        self.gpa.free(slot.*);
        slot.* = next;
    }

    fn removeRow(self: *Model, id: NodeId) void {
        const index = self.indexOf(id) orelse return;
        self.freeRow(&self.rows.items[index]);
        _ = self.rows.orderedRemove(index);
    }

    fn freeRow(self: *Model, row_ptr: *Row) void {
        self.freeObservation(&row_ptr.base);
        self.freeObservation(&row_ptr.current);
        freeDraftWith(self.gpa, &row_ptr.draft);
        if (row_ptr.copy_source) |*source| self.gpa.free(source.revision);
    }

    fn freeObservation(self: *Model, slot: *?Observation) void {
        if (slot.*) |*observation| freeObservationWith(self.gpa, observation);
        slot.* = null;
    }

    fn rowMutable(self: *Model, id: NodeId) ?*Row {
        for (self.rows.items) |*candidate| if (candidate.id == id) return candidate;
        return null;
    }

    fn indexOf(self: *const Model, id: NodeId) ?usize {
        for (self.rows.items, 0..) |candidate, index| if (candidate.id == id) return index;
        return null;
    }

    fn encodeTree(self: *const Model, id: NodeId) ![]u8 {
        var nodes: std.ArrayList(NodeId) = .empty;
        defer nodes.deinit(self.gpa);
        try collect(self, id, &nodes);
        if (nodes.items.len > max_transfer_records) return error.TransferTooLarge;
        var bytes: std.ArrayList(u8) = .empty;
        errdefer bytes.deinit(self.gpa);
        try bytes.appendSlice(self.gpa, tree_magic);
        try putU32(self.gpa, &bytes, @intCast(nodes.items.len));
        for (nodes.items) |node_id| {
            const row_ptr = self.row(node_id).?;
            var parent_index: u32 = no_parent;
            if (row_ptr.parent) |parent| {
                for (nodes.items, 0..) |candidate, index| {
                    if (candidate == parent) parent_index = @intCast(index);
                }
            }
            try putU32(self.gpa, &bytes, parent_index);
            try bytes.append(self.gpa, @intFromEnum(row_ptr.draft.kind));
            try bytes.append(self.gpa, if (row_ptr.draft.mode != null) 1 else 0);
            try putU32(self.gpa, &bytes, row_ptr.draft.mode orelse 0);
            try putBytes(self.gpa, &bytes, row_ptr.draft.name, max_transfer_name);
            try putBytes(self.gpa, &bytes, row_ptr.draft.contents, max_transfer_payload);
            try putBytes(self.gpa, &bytes, row_ptr.draft.link_target, max_transfer_payload);
        }
        if (bytes.items.len > max_transfer_payload) return error.TransferTooLarge;
        return bytes.toOwnedSlice(self.gpa);
    }

    fn decodeTree(self: *Model, parent: ?NodeId, root_name: []const u8, payload: []const u8, intent: transfer.Intent) !NodeId {
        if (payload.len > max_transfer_payload or !std.mem.startsWith(u8, payload, tree_magic)) return error.InvalidTransfer;
        var cursor: usize = tree_magic.len;
        const count = try getU32(payload, &cursor);
        if (count == 0 or count > max_transfer_records) return error.InvalidTransfer;
        const ids = try self.gpa.alloc(NodeId, count);
        defer self.gpa.free(ids);
        for (ids) |*slot| slot.* = 0;
        for (ids, 0..) |*slot, index| {
            const parent_index = try getU32(payload, &cursor);
            const raw_kind = try getU8(payload, &cursor);
            if (raw_kind > @intFromEnum(contract.Kind.other) or cursor >= payload.len) return error.InvalidTransfer;
            const kind: contract.Kind = @enumFromInt(raw_kind);
            const has_mode = try getU8(payload, &cursor);
            const mode_value = try getU32(payload, &cursor);
            const name = try getBytes(payload, &cursor, max_transfer_name);
            const contents = try getBytes(payload, &cursor, max_transfer_payload);
            const link_target = try getBytes(payload, &cursor, max_transfer_payload);
            const row_parent = if (parent_index == no_parent) parent else blk: {
                if (parent_index >= index or ids[parent_index] == 0) return error.InvalidTransfer;
                break :blk ids[parent_index];
            };
            const actual_name = if (index == 0) root_name else name;
            if (index == 0 and !std.mem.eql(u8, actual_name, name)) {
                _ = try contract.Name.init(actual_name);
            }
            const id = try self.appendPending(row_parent, actual_name, kind, if (has_mode == 0) null else mode_value, contents, link_target, .added);
            slot.* = id;
        }
        if (cursor != payload.len) return error.InvalidTransfer;
        _ = intent;
        return ids[0];
    }
};

const Builder = struct {
    arena: std.mem.Allocator,
    model: *const Model,
    operations: std.ArrayList(contract.Planned) = .empty,
    emitted: std.ArrayList(NodeId) = .empty,
    create_operations: std.ArrayList(struct { id: NodeId, index: usize }) = .empty,
    visiting: std.ArrayList(NodeId) = .empty,

    fn init(arena: std.mem.Allocator, model: *const Model) Builder {
        return .{ .arena = arena, .model = model };
    }

    fn build(self: *Builder) !void {
        for (self.model.rows.items) |row| if (isDirty(&row)) try self.emit(row.id);
    }

    fn emit(self: *Builder, id: NodeId) !void {
        if (contains(self.emitted.items, id)) return;
        if (contains(self.visiting.items, id)) return error.ParentCycle;
        const row_ptr = self.model.row(id) orelse return error.UnknownNode;
        if (row_ptr.conflict == .stale) return error.Stale;
        // A pending-only subtree deleted before apply has no filesystem
        // operation to emit.  Suppress its descendants too; their captured
        // draft data remains available to any independent pasted subtree.
        if (row_ptr.pending == .deleted and row_ptr.base == null) {
            try self.emitted.append(self.arena, id);
            return;
        }
        if (row_ptr.parent) |parent| {
            if (self.model.row(parent)) |parent_row| {
                if (parent_row.pending == .deleted and parent_row.base == null) {
                    try self.emitted.append(self.arena, id);
                    return;
                }
            }
        }
        try self.visiting.append(self.arena, id);
        defer _ = self.visiting.pop();
        if (row_ptr.parent) |parent| {
            const parent_row = self.model.row(parent) orelse return error.UnknownParent;
            if (parent_row.draft.kind != .directory) return error.NotDirectory;
            if (parent_row.pending == .added or parent_row.pending == .copied or parent_row.pending == .copied_renamed)
                try self.emit(parent);
        }
        const parent_ref = try self.parentRef(row_ptr);
        if (row_ptr.pending == .deleted) {
            const source = baseSource(row_ptr) orelse return error.Stale;
            try self.add(.{ .remove = .{ .source = source.entry, .revision = try self.revision(source.revision) } }, row_ptr, null);
        } else if (row_ptr.pending == .added) {
            try self.addCreate(row_ptr, parent_ref, row_ptr.draft.name);
        } else if (row_ptr.pending == .copied or row_ptr.pending == .copied_renamed) {
            const source = row_ptr.copy_source orelse return error.Stale;
            const name = try copyName(self.arena, row_ptr.draft.name);
            const destination = contract.Slot{ .parent = parent_ref, .name = name };
            const captured_revision = contract.Revision{ .token = try self.arena.dupe(u8, source.revision) };
            const operation: contract.Operation = switch (source.intent) {
                .copy => .{ .copy = .{ .source = .{ .entry = .{ .ref = source.entry, .revision = captured_revision } }, .destination = destination } },
                .cut => .{ .rename = .{ .source = source.entry, .source_revision = captured_revision, .destination = destination } },
            };
            try self.add(operation, row_ptr, parent_ref);
        } else {
            const source = baseSource(row_ptr) orelse return error.Stale;
            if (row_ptr.name_dirty) {
                try self.add(.{ .rename = .{ .source = source.entry, .source_revision = try self.revision(source.revision), .destination = .{ .parent = parent_ref, .name = try copyName(self.arena, row_ptr.draft.name) } } }, row_ptr, parent_ref);
            }
            if (row_ptr.mode_dirty) {
                try self.add(.{ .set_permissions = .{ .source = source.entry, .revision = try self.revision(source.revision), .mode = row_ptr.draft.mode orelse return error.InvalidMode } }, row_ptr, null);
            }
        }
        try self.emitted.append(self.arena, id);
    }

    fn addCreate(self: *Builder, row_ptr: *const Row, parent: contract.ParentRef, name_bytes: []const u8) !void {
        const destination = contract.Slot{ .parent = parent, .name = try copyName(self.arena, name_bytes) };
        const operation: contract.Operation = switch (row_ptr.draft.kind) {
            .directory => .{ .create_directory = .{ .destination = destination, .mode = row_ptr.draft.mode } },
            .regular => .{ .create_file = .{ .destination = destination, .contents = try self.arena.dupe(u8, row_ptr.draft.contents), .mode = row_ptr.draft.mode } },
            .symlink => .{ .create_symlink = .{ .destination = destination, .target = try self.arena.dupe(u8, row_ptr.draft.link_target) } },
            .other => return error.Unsupported,
        };
        try self.add(operation, row_ptr, parent);
    }

    fn revision(self: *const Builder, value: []const u8) !contract.Revision {
        return .{ .token = try self.arena.dupe(u8, value) };
    }

    fn parentRef(self: *Builder, row_ptr: *const Row) !contract.ParentRef {
        const parent = row_ptr.parent orelse return .root;
        const parent_row = self.model.row(parent) orelse return error.UnknownParent;
        if (parent_row.pending == .added or parent_row.pending == .copied or parent_row.pending == .copied_renamed) {
            for (self.create_operations.items) |planned| if (planned.id == parent) return .{ .planned = planned.index };
            return error.UnknownParent;
        }
        const source = parent_row.current orelse parent_row.base orelse return error.Stale;
        if (source.kind != .directory) return error.NotDirectory;
        return .{ .entry = source.identity };
    }

    fn add(self: *Builder, operation: contract.Operation, row_ptr: *const Row, parent: ?contract.ParentRef) !void {
        const index = self.operations.items.len;
        const depends_on: []const usize = if (parent) |parent_ref| switch (parent_ref) {
            .root, .entry => &.{},
            .planned => |dependency| blk: {
                const values = try self.arena.alloc(usize, 1);
                values[0] = dependency;
                break :blk values;
            },
        } else &.{};
        try self.operations.append(self.arena, .{ .id = opId(index), .operation = operation, .depends_on = depends_on });
        if ((row_ptr.pending == .added or row_ptr.pending == .copied or row_ptr.pending == .copied_renamed) and
            !self.hasCreateOperation(row_ptr.id))
            try self.create_operations.append(self.arena, .{ .id = row_ptr.id, .index = index });
    }

    fn hasCreateOperation(self: *const Builder, id: NodeId) bool {
        for (self.create_operations.items) |planned| if (planned.id == id) return true;
        return false;
    }

    fn contains(values: []const NodeId, value: NodeId) bool {
        for (values) |candidate| if (candidate == value) return true;
        return false;
    }
};

const EntryCapture = struct {
    root: contract.Root,
    entry: contract.EntryRef,
    revision: []const u8,
    kind: contract.Kind = .other,
    mode: ?u32 = null,
};

fn sourceFor(model: *const Model, row_ptr: *const Row) ?struct { root: contract.Root, entry: contract.EntryRef, revision: []const u8 } {
    if (row_ptr.copy_source) |source| return .{ .root = source.root, .entry = source.entry, .revision = source.revision };
    const observed = row_ptr.current orelse row_ptr.base orelse return null;
    return .{ .root = model.root, .entry = observed.identity, .revision = observed.revision };
}

fn baseSource(row_ptr: *const Row) ?struct { entry: contract.EntryRef, revision: []const u8 } {
    const observed = row_ptr.base orelse return null;
    return .{ .entry = observed.identity, .revision = observed.revision };
}

fn isDirty(row_ptr: *const Row) bool {
    return row_ptr.pending != .observed or row_ptr.name_dirty or row_ptr.mode_dirty or row_ptr.conflict != .none;
}

fn cloneObservation(gpa: std.mem.Allocator, entry: SnapshotEntry) !Observation {
    return .{ .identity = entry.identity, .revision = try gpa.dupe(u8, entry.revision), .name = try gpa.dupe(u8, entry.name), .kind = entry.kind, .mode = entry.mode };
}

fn draftFrom(gpa: std.mem.Allocator, entry: SnapshotEntry) !Draft {
    return .{ .name = try gpa.dupe(u8, entry.name), .kind = entry.kind, .mode = entry.mode, .contents = try gpa.dupe(u8, entry.contents), .link_target = try gpa.dupe(u8, entry.link_target) };
}

fn freeObservationWith(gpa: std.mem.Allocator, observation: *const Observation) void {
    gpa.free(observation.revision);
    gpa.free(observation.name);
}

fn freeDraftWith(gpa: std.mem.Allocator, draft: *const Draft) void {
    gpa.free(draft.name);
    gpa.free(draft.contents);
    gpa.free(draft.link_target);
}

fn collect(model: *const Model, id: NodeId, nodes: *std.ArrayList(NodeId)) !void {
    try nodes.append(model.gpa, id);
    for (model.rows.items) |row| if (row.parent == id) try collect(model, row.id, nodes);
}

fn encodeEntry(gpa: std.mem.Allocator, root: contract.Root, entry_ref: contract.EntryRef, revision: []const u8) ![]u8 {
    if (revision.len > max_transfer_revision) return error.TransferTooLarge;
    var bytes: std.ArrayList(u8) = .empty;
    errdefer bytes.deinit(gpa);
    try bytes.appendSlice(gpa, entry_magic);
    try putHandle(gpa, &bytes, root.authority, root.slot, root.generation);
    try putHandle(gpa, &bytes, entry_ref.authority, entry_ref.slot, entry_ref.generation);
    try putBytes(gpa, &bytes, revision, max_transfer_revision);
    if (bytes.items.len > max_transfer_payload) return error.TransferTooLarge;
    return bytes.toOwnedSlice(gpa);
}

fn decodeEntry(payload: []const u8) !EntryCapture {
    if (payload.len > max_transfer_payload or !std.mem.startsWith(u8, payload, entry_magic)) return error.InvalidTransfer;
    var cursor: usize = entry_magic.len;
    const root = try getRoot(payload, &cursor);
    const entry_ref = try getEntry(payload, &cursor);
    const revision = try getBytes(payload, &cursor, max_transfer_revision);
    if (cursor != payload.len) return error.InvalidTransfer;
    return .{ .root = root, .entry = entry_ref, .revision = revision };
}

fn putHandle(gpa: std.mem.Allocator, bytes: *std.ArrayList(u8), authority: kernel.handle.Authority, slot: u32, generation: u32) !void {
    try putU32(gpa, bytes, @intFromEnum(authority));
    try putU32(gpa, bytes, slot);
    try putU32(gpa, bytes, generation);
}

fn getRoot(payload: []const u8, cursor: *usize) !contract.Root {
    return .{ .authority = @enumFromInt(try getU32(payload, cursor)), .slot = try getU32(payload, cursor), .generation = try getU32(payload, cursor) };
}

fn getEntry(payload: []const u8, cursor: *usize) !contract.EntryRef {
    return .{ .authority = @enumFromInt(try getU32(payload, cursor)), .slot = try getU32(payload, cursor), .generation = try getU32(payload, cursor) };
}

fn putU32(gpa: std.mem.Allocator, bytes: *std.ArrayList(u8), value: u32) !void {
    var data: [4]u8 = undefined;
    std.mem.writeInt(u32, &data, value, .little);
    try bytes.appendSlice(gpa, &data);
}

fn putBytes(gpa: std.mem.Allocator, bytes: *std.ArrayList(u8), value: []const u8, limit: usize) !void {
    if (value.len > limit) return error.TransferTooLarge;
    try putU32(gpa, bytes, @intCast(value.len));
    try bytes.appendSlice(gpa, value);
}

fn getU8(payload: []const u8, cursor: *usize) !u8 {
    if (cursor.* >= payload.len) return error.InvalidTransfer;
    const value = payload[cursor.*];
    cursor.* += 1;
    return value;
}

fn getU32(payload: []const u8, cursor: *usize) !u32 {
    if (cursor.* > payload.len or payload.len - cursor.* < 4) return error.InvalidTransfer;
    const value = std.mem.readInt(u32, payload[cursor.*..][0..4], .little);
    cursor.* += 4;
    return value;
}

fn getBytes(payload: []const u8, cursor: *usize, limit: usize) ![]const u8 {
    const length = try getU32(payload, cursor);
    if (length > limit or length > payload.len - cursor.*) return error.InvalidTransfer;
    const value = payload[cursor.*..][0..length];
    cursor.* += length;
    return value;
}

fn copyName(arena: std.mem.Allocator, value: []const u8) !contract.Name {
    return contract.Name.init(try arena.dupe(u8, value));
}

fn sameEntry(a: contract.EntryRef, b: contract.EntryRef) bool {
    return a.authority == b.authority and a.slot == b.slot and a.generation == b.generation;
}

fn opId(index: usize) contract.OperationId {
    var id: contract.OperationId = @splat(0);
    std.mem.writeInt(usize, id[0..@sizeOf(usize)], index, .little);
    return id;
}

fn ref(slot: u32, generation: u32) contract.EntryRef {
    return .{ .authority = .here, .slot = slot, .generation = generation };
}

test "owned copy and cut transfers work in same and different instances" {
    var source = Model.init(std.testing.allocator, .{ .authority = .here, .slot = 0, .generation = 1 });
    try source.reconcile(.{ .entries = &.{.{ .identity = ref(1, 1), .name = "a", .revision = "r1", .kind = .regular }} });
    const id = source.rows.items[0].id;
    var copy = try source.yank(id, .copy);
    var cut = try source.yank(id, .cut);
    source.deinit();
    var destination = Model.init(std.testing.allocator, .{ .authority = .here, .slot = 0, .generation = 1 });
    defer destination.deinit();
    const copied_id = try destination.paste(null, &copy);
    try std.testing.expectEqualStrings("a", destination.row(copied_id).?.draft.name);
    var cut_destination = Model.init(std.testing.allocator, .{ .authority = .here, .slot = 0, .generation = 1 });
    defer cut_destination.deinit();
    _ = try cut_destination.paste(null, &cut);
    var cut_plan = try cut_destination.buildPlan();
    defer cut_plan.deinit();
    try std.testing.expect(std.meta.activeTag(cut_plan.value.operations[0].operation) == .rename);
    copy.deinit();
    cut.deinit();
}

test "paste rows are visible and plan follows edited destination draft" {
    var source = Model.init(std.testing.allocator, .{ .authority = .here, .slot = 0, .generation = 1 });
    defer source.deinit();
    try source.reconcile(.{ .entries = &.{.{ .identity = ref(2, 1), .name = "old", .revision = "rev", .kind = .regular }} });
    var item = try source.yank(source.rows.items[0].id, .copy);
    defer item.deinit();
    var destination = Model.init(std.testing.allocator, source.root);
    defer destination.deinit();
    const copied = try destination.paste(null, &item);
    try destination.rename(copied, "edited");
    var plan = try destination.buildPlan();
    defer plan.deinit();
    try std.testing.expectEqualStrings("edited", plan.value.operations[0].operation.copy.destination.name.bytes);
}

test "captured transfer keeps old name across source rename or deletion" {
    var source = Model.init(std.testing.allocator, .{ .authority = .here, .slot = 0, .generation = 1 });
    defer source.deinit();
    try source.reconcile(.{ .entries = &.{.{ .identity = ref(20, 1), .name = "old", .revision = "r1", .kind = .regular }} });
    var renamed_item = try source.yank(source.rows.items[0].id, .copy);
    defer renamed_item.deinit();
    try source.rename(source.rows.items[0].id, "new");
    var destination = Model.init(std.testing.allocator, source.root);
    defer destination.deinit();
    const pasted_after_rename = try destination.paste(null, &renamed_item);
    try std.testing.expectEqualStrings("old", destination.row(pasted_after_rename).?.draft.name);

    var deleted_item = try source.yank(source.rows.items[0].id, .copy);
    defer deleted_item.deinit();
    try source.reconcile(.{ .entries = &.{} });
    const pasted_after_delete = try destination.paste(null, &deleted_item);
    try std.testing.expectEqualStrings("new", destination.row(pasted_after_delete).?.draft.name);
}

test "rename delete permissions and mode zero build guarded plans" {
    var model = Model.init(std.testing.allocator, .{ .authority = .here, .slot = 0, .generation = 1 });
    defer model.deinit();
    try model.reconcile(.{ .entries = &.{.{ .identity = ref(3, 1), .name = "old", .revision = "r", .kind = .regular, .mode = 0o644 }} });
    const id = model.rows.items[0].id;
    try model.rename(id, "new");
    try model.setMode(id, 0);
    var plan = try model.buildPlan();
    defer plan.deinit();
    try std.testing.expectEqual(@as(usize, 2), plan.value.operations.len);
    try std.testing.expectEqual(@as(u32, 0), plan.value.operations[1].operation.set_permissions.mode);
    try model.markDelete(id);
    var delete_plan = try model.buildPlan();
    defer delete_plan.deinit();
    try std.testing.expect(std.meta.activeTag(delete_plan.value.operations[0].operation) == .remove);
}

test "dirty external deletion is retained stale and clean reorder advances" {
    var model = Model.init(std.testing.allocator, .{ .authority = .here, .slot = 0, .generation = 1 });
    defer model.deinit();
    try model.reconcile(.{ .entries = &.{
        .{ .identity = ref(4, 1), .name = "a", .revision = "r1", .kind = .regular },
        .{ .identity = ref(5, 1), .name = "b", .revision = "r1", .kind = .regular },
    } });
    const a = model.rowForIdentity(ref(4, 1)).?;
    try model.rename(a, "draft");
    try model.reconcile(.{ .entries = &.{.{ .identity = ref(5, 1), .name = "b2", .revision = "r2", .kind = .regular }} });
    try std.testing.expectEqual(Conflict.stale, model.row(a).?.conflict);
    try std.testing.expectEqualStrings("draft", model.row(a).?.draft.name);
}

test "pending subtree paste survives deletion, preserves symlink and planned parent" {
    var model = Model.init(std.testing.allocator, .{ .authority = .here, .slot = 0, .generation = 1 });
    defer model.deinit();
    const directory = try model.addDirectory(null, "tree", @as(?u32, 0));
    _ = try model.addSymlink(directory, "link", "target");
    var item = try model.yank(directory, .copy);
    defer item.deinit();
    try model.markDelete(directory);
    _ = try model.paste(null, &item);
    var plan = try model.buildPlan();
    defer plan.deinit();
    try std.testing.expectEqual(@as(usize, 2), plan.value.operations.len);
    try std.testing.expectEqual(@as(?u32, 0), plan.value.operations[0].operation.create_directory.mode);
    try std.testing.expect(plan.value.operations[1].depends_on.len == 1);
    try std.testing.expect(std.meta.activeTag(plan.value.operations[1].operation) == .create_symlink);
}

test "unusual names, source identity reuse, and typed entry schema" {
    var model = Model.init(std.testing.allocator, .{ .authority = .here, .slot = 0, .generation = 1 });
    defer model.deinit();
    try model.reconcile(.{ .entries = &.{.{ .identity = ref(6, 1), .name = "line\n-[]'", .revision = "r-old", .kind = .symlink, .link_target = "target" }} });
    var item = try model.yank(model.rows.items[0].id, .copy);
    defer item.deinit();
    try std.testing.expectEqualStrings(entry_schema, item.value.representations[0].schema.?);
    try model.reconcile(.{ .entries = &.{.{ .identity = ref(6, 2), .name = "line\n-[]'", .revision = "r-new", .kind = .regular }} });
    const pasted = try model.paste(null, &item);
    try std.testing.expectEqual(Pending.copied, model.row(pasted).?.pending);
    try std.testing.expectEqual(@as(u32, 6), model.row(pasted).?.copy_source.?.entry.slot);
}

test "malformed and oversized transfer payloads are rejected" {
    var model = Model.init(std.testing.allocator, .{ .authority = .here, .slot = 0, .generation = 1 });
    defer model.deinit();
    const bad_reps = [_]transfer.Representation{.{ .media_type = entry_media, .schema = entry_schema, .payload = "bad" }};
    var bad = try transfer.OwnedItem.init(std.testing.allocator, .{ .intent = .copy, .suggested_name = "x", .representations = &bad_reps });
    defer bad.deinit();
    try std.testing.expectError(error.InvalidTransfer, model.paste(null, &bad));
    const huge = try std.testing.allocator.alloc(u8, max_transfer_payload + 1);
    defer std.testing.allocator.free(huge);
    const huge_reps = [_]transfer.Representation{.{ .media_type = tree_media, .schema = tree_schema, .payload = huge }};
    var oversized = try transfer.OwnedItem.init(std.testing.allocator, .{ .intent = .copy, .representations = &huge_reps });
    defer oversized.deinit();
    try std.testing.expectError(error.InvalidTransfer, model.paste(null, &oversized));
}

test "build plan rejects missing parent, non-directory parent, and cycles" {
    var model = Model.init(std.testing.allocator, .{ .authority = .here, .slot = 0, .generation = 1 });
    defer model.deinit();
    try std.testing.expectError(error.UnknownParent, model.addFile(99, "child", "x", null));
    const file = try model.addFile(null, "file", "x", null);
    try std.testing.expectError(error.NotDirectory, model.addFile(file, "child", "x", null));
    const first = try model.addDirectory(null, "first", null);
    const second = try model.addDirectory(first, "second", null);
    model.rowMutable(first).?.parent = second;
    try std.testing.expectError(error.ParentCycle, model.buildPlan());
}
