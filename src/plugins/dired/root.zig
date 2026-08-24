//! Pure dired draft/reconcile model.
//!
//! This module owns only browser state: observed filesystem identity/revision,
//! editable draft fields, and pending intent.  Filesystem effects are emitted
//! as `weft_fs.contract.Plan`; no provider is called here and no guest/plugin
//! state is shared.  Transfer values cross the boundary only as the generic
//! `weft_kernel.transfer.Item`.

const std = @import("std");
const kernel = @import("weft_kernel");
const fs = @import("weft_fs");

const transfer = kernel.transfer;
const target = kernel.target;
const contract = fs.contract;

pub const NodeId = u64;

pub const Pending = enum {
    observed,
    renamed,
    added,
    copied,
    deleted,
};

pub const SnapshotEntry = struct {
    identity: contract.EntryRef,
    name: []const u8,
    revision: []const u8,
    kind: contract.Kind,
    mode: ?u32 = null,
    contents: []const u8 = &.{},
    link_target: []const u8 = &.{},
};

pub const Snapshot = struct {
    entries: []const SnapshotEntry,
};

pub const Observed = struct {
    identity: contract.EntryRef,
    /// These bytes are copied from the immutable observation.  A later
    /// listing may replace the observation, but never by row position/name.
    revision: []u8,
    name: []u8,
    kind: contract.Kind,
};

pub const Draft = struct {
    name: []u8,
    kind: contract.Kind,
    mode: ?u32 = null,
    contents: []u8 = &.{},
    link_target: []u8 = &.{},
};

pub const Row = struct {
    id: NodeId,
    parent: ?NodeId,
    observed: ?Observed,
    draft: Draft,
    pending: Pending,
};

pub const OwnedPlan = struct {
    arena: std.heap.ArenaAllocator,
    value: contract.Plan,

    pub fn deinit(self: *OwnedPlan) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

const snapshot_media = "application/x-weft-dired-snapshot";
const entry_media = "application/x-weft-fs-entry";
const snapshot_magic = "dired-snapshot-v1\x00";
const no_parent = std.math.maxInt(u32);

pub const Model = struct {
    gpa: std.mem.Allocator,
    root: contract.Root,
    rows: std.ArrayList(Row) = .empty,
    transfer_reps: std.ArrayList([]transfer.Representation) = .empty,
    transfer_names: std.ArrayList([]u8) = .empty,
    transfer_revisions: std.ArrayList([]u8) = .empty,
    transfer_payloads: std.ArrayList([]u8) = .empty,
    next_id: NodeId = 1,

    pub fn init(gpa: std.mem.Allocator, root: contract.Root) Model {
        return .{ .gpa = gpa, .root = root };
    }

    pub fn deinit(self: *Model) void {
        for (self.rows.items) |*row_value| self.freeRow(row_value);
        self.rows.deinit(self.gpa);
        for (self.transfer_reps.items) |reps| self.gpa.free(reps);
        for (self.transfer_names.items) |name| self.gpa.free(name);
        for (self.transfer_revisions.items) |revision| self.gpa.free(revision);
        for (self.transfer_payloads.items) |payload| self.gpa.free(payload);
        self.transfer_reps.deinit(self.gpa);
        self.transfer_names.deinit(self.gpa);
        self.transfer_revisions.deinit(self.gpa);
        self.transfer_payloads.deinit(self.gpa);
        self.* = undefined;
    }

    pub fn row(self: *const Model, id: NodeId) ?*const Row {
        for (self.rows.items) |*candidate| if (candidate.id == id) return candidate;
        return null;
    }

    pub fn rowForIdentity(self: *const Model, identity: contract.EntryRef) ?NodeId {
        for (self.rows.items) |candidate| {
            if (candidate.observed) |observed| if (sameEntry(observed.identity, identity)) return candidate.id;
        }
        return null;
    }

    /// Reconcile by opaque identity, never by listing position or visible
    /// name. Existing draft names remain anchored to their identity.
    pub fn reconcile(self: *Model, snapshot: Snapshot) !void {
        var ordered: std.ArrayList(NodeId) = .empty;
        defer ordered.deinit(self.gpa);

        for (snapshot.entries) |snapshot_entry| {
            const existing = self.rowForIdentity(snapshot_entry.identity);
            if (existing) |id| {
                const row_ptr = self.row(id).?;
                const old_name = row_ptr.observed.?.name;
                const keep_draft = row_ptr.pending == .renamed or
                    !std.mem.eql(u8, row_ptr.draft.name, old_name);
                const mutable = self.rowMutable(id).?;
                self.replaceObserved(mutable, snapshot_entry) catch return error.OutOfMemory;
                if (!keep_draft) {
                    self.replaceBytes(&mutable.draft.name, snapshot_entry.name) catch return error.OutOfMemory;
                }
                if (mutable.pending == .observed or mutable.pending == .renamed) {
                    // A renamed draft remains renamed; an untouched row stays
                    // observed even when only metadata/revision changed.
                    if (mutable.pending == .renamed and std.mem.eql(u8, mutable.draft.name, snapshot_entry.name))
                        mutable.pending = .observed;
                }
                try ordered.append(self.gpa, id);
            } else {
                const id = try self.appendObserved(null, snapshot_entry);
                try ordered.append(self.gpa, id);
            }
        }

        // Pending rows are not in the provider snapshot, but remain visible
        // and addressable after an external listing reorder.
        for (self.rows.items) |candidate| {
            if (candidate.pending == .added or candidate.pending == .copied or candidate.pending == .deleted) {
                var present = false;
                for (ordered.items) |id| {
                    if (id == candidate.id) present = true;
                }
                if (!present) try ordered.append(self.gpa, candidate.id);
            }
        }

        // Rows absent from the latest snapshot are no longer displayed. Free
        // their owned observation/draft bytes before moving surviving rows.
        for (self.rows.items) |*candidate| {
            var present = false;
            for (ordered.items) |id| {
                if (id == candidate.id) present = true;
            }
            if (!present) self.freeRow(candidate);
        }

        var reordered: std.ArrayList(Row) = .empty;
        defer reordered.deinit(self.gpa);
        try reordered.ensureTotalCapacity(self.gpa, ordered.items.len);
        for (ordered.items) |id| {
            const index = self.indexOf(id).?;
            try reordered.append(self.gpa, self.rows.items[index]);
        }
        self.rows.deinit(self.gpa);
        self.rows = reordered;
        reordered = .empty;
    }

    pub fn rename(self: *Model, id: NodeId, name: []const u8) !void {
        _ = try contract.Name.init(name);
        const row_ptr = self.rowMutable(id) orelse return error.UnknownNode;
        try self.replaceBytes(&row_ptr.draft.name, name);
        if (row_ptr.pending == .observed) row_ptr.pending = .renamed;
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

    /// Capture a transfer item. Observed entries carry only generic target
    /// identity/revision. Pending rows carry a self-contained representation,
    /// so later deletion of the draft subtree cannot invalidate the transfer.
    pub fn yank(self: *Model, id: NodeId, intent: transfer.Intent) !transfer.Item {
        const row_ptr = self.row(id) orelse return error.UnknownNode;
        if (intent == .copy and row_ptr.pending != .deleted)
            self.rowMutable(id).?.pending = .copied;
        const suggested_name = try self.gpa.dupe(u8, row_ptr.draft.name);
        errdefer self.gpa.free(suggested_name);
        try self.transfer_names.append(self.gpa, suggested_name);
        const reps = try self.gpa.alloc(transfer.Representation, 1);
        errdefer self.gpa.free(reps);
        try self.transfer_reps.append(self.gpa, reps);
        if (row_ptr.observed) |observed| {
            reps[0] = .{ .media_type = entry_media, .payload = &.{} };
            const source = contract.EntryRef.fromWire(observed.identity.toWire());
            const revision = try self.gpa.dupe(u8, observed.revision);
            errdefer self.gpa.free(revision);
            try self.transfer_revisions.append(self.gpa, revision);
            return .{
                .intent = intent,
                .suggested_name = suggested_name,
                .source = .{ .target = target.Ref.fromWire(source.toWire()), .revision = revision },
                .representations = reps,
            };
        }
        const payload = try self.encodePendingSubtree(id);
        try self.transfer_payloads.append(self.gpa, payload);
        reps[0] = .{ .media_type = snapshot_media, .payload = payload };
        return .{ .intent = intent, .suggested_name = suggested_name, .representations = reps };
    }

    /// Convert a generic transfer item into a typed filesystem plan. The
    /// source identity is reconstructed from its generic wire representation;
    /// no dired instance or mutable row pointer crosses the boundary.
    pub fn planPaste(self: *const Model, destination: contract.ParentRef, item: transfer.Item) !OwnedPlan {
        var owned: OwnedPlan = .{ .arena = .init(self.gpa), .value = undefined };
        errdefer owned.deinit();
        const arena = owned.arena.allocator();
        var operations: std.ArrayList(contract.Planned) = .empty;
        defer operations.deinit(arena);

        if (item.representation(snapshot_media)) |representation| {
            try decodePending(arena, &operations, destination, item.intent, representation.payload);
        } else if (item.source) |source| {
            const name = try copyName(arena, item.suggested_name);
            const source_ref = contract.EntryRef.fromWire(source.target.toWire());
            const source_revision = contract.Revision{ .token = try arena.dupe(u8, source.revision) };
            const operation: contract.Operation = switch (item.intent) {
                .copy => .{ .copy = .{
                    .source = .{ .entry = .{ .ref = source_ref, .revision = source_revision } },
                    .destination = .{ .parent = destination, .name = name },
                } },
                .cut => .{ .rename = .{
                    .source = source_ref,
                    .source_revision = source_revision,
                    .destination = .{ .parent = destination, .name = name },
                } },
            };
            try operations.append(arena, .{ .id = opId(operations.items.len), .operation = operation });
        } else return error.UnsupportedTransfer;

        owned.value = .{
            .root = self.root,
            .base_revision = &.{},
            .operations = try arena.dupe(contract.Planned, operations.items),
        };
        return owned;
    }

    fn appendObserved(self: *Model, parent: ?NodeId, snapshot_entry: SnapshotEntry) !NodeId {
        const id = self.next_id;
        self.next_id += 1;
        try self.rows.append(self.gpa, .{
            .id = id,
            .parent = parent,
            .observed = .{
                .identity = snapshot_entry.identity,
                .revision = try self.gpa.dupe(u8, snapshot_entry.revision),
                .name = try self.gpa.dupe(u8, snapshot_entry.name),
                .kind = snapshot_entry.kind,
            },
            .draft = .{
                .name = try self.gpa.dupe(u8, snapshot_entry.name),
                .kind = snapshot_entry.kind,
                .mode = snapshot_entry.mode,
                .contents = try self.gpa.dupe(u8, snapshot_entry.contents),
                .link_target = try self.gpa.dupe(u8, snapshot_entry.link_target),
            },
            .pending = .observed,
        });
        return id;
    }

    fn appendPending(self: *Model, parent: ?NodeId, name: []const u8, kind: contract.Kind, mode: ?u32, contents: []const u8, link_target: []const u8, pending: Pending) !NodeId {
        _ = try contract.Name.init(name);
        const id = self.next_id;
        self.next_id += 1;
        try self.rows.append(self.gpa, .{
            .id = id,
            .parent = parent,
            .observed = null,
            .draft = .{
                .name = try self.gpa.dupe(u8, name),
                .kind = kind,
                .mode = mode,
                .contents = try self.gpa.dupe(u8, contents),
                .link_target = try self.gpa.dupe(u8, link_target),
            },
            .pending = pending,
        });
        return id;
    }

    fn replaceObserved(self: *Model, row_ptr: *Row, snapshot_entry: SnapshotEntry) !void {
        row_ptr.observed.?.identity = snapshot_entry.identity;
        try self.replaceBytes(&row_ptr.observed.?.revision, snapshot_entry.revision);
        try self.replaceBytes(&row_ptr.observed.?.name, snapshot_entry.name);
        row_ptr.observed.?.kind = snapshot_entry.kind;
        row_ptr.draft.kind = snapshot_entry.kind;
        row_ptr.draft.mode = snapshot_entry.mode;
        try self.replaceBytes(&row_ptr.draft.contents, snapshot_entry.contents);
        try self.replaceBytes(&row_ptr.draft.link_target, snapshot_entry.link_target);
    }

    fn replaceBytes(self: *Model, slot: *[]u8, value: []const u8) !void {
        const next = try self.gpa.dupe(u8, value);
        self.gpa.free(slot.*);
        slot.* = next;
    }

    fn freeRow(self: *Model, row_ptr: *Row) void {
        if (row_ptr.observed) |*observed| {
            self.gpa.free(observed.revision);
            self.gpa.free(observed.name);
        }
        self.gpa.free(row_ptr.draft.name);
        self.gpa.free(row_ptr.draft.contents);
        self.gpa.free(row_ptr.draft.link_target);
    }

    fn rowMutable(self: *Model, id: NodeId) ?*Row {
        for (self.rows.items) |*candidate| if (candidate.id == id) return candidate;
        return null;
    }

    fn indexOf(self: *const Model, id: NodeId) ?usize {
        for (self.rows.items, 0..) |candidate, index| if (candidate.id == id) return index;
        return null;
    }

    fn encodePendingSubtree(self: *const Model, id: NodeId) ![]u8 {
        var nodes: std.ArrayList(NodeId) = .empty;
        defer nodes.deinit(self.gpa);
        try collectSubtree(self, id, &nodes);
        var bytes: std.ArrayList(u8) = .empty;
        errdefer bytes.deinit(self.gpa);
        try bytes.appendSlice(self.gpa, snapshot_magic);
        try appendU32(self.gpa, &bytes, @intCast(nodes.items.len));
        for (nodes.items) |node_id| {
            const row_ptr = self.row(node_id).?;
            var parent_index: u32 = no_parent;
            if (row_ptr.parent) |parent| {
                for (nodes.items, 0..) |candidate, index| {
                    if (candidate == parent) parent_index = @intCast(index);
                }
            }
            try appendU32(self.gpa, &bytes, parent_index);
            try bytes.append(self.gpa, @intFromEnum(row_ptr.draft.kind));
            try appendU32(self.gpa, &bytes, row_ptr.draft.mode orelse 0);
            try appendBytes(self.gpa, &bytes, row_ptr.draft.name);
            try appendBytes(self.gpa, &bytes, row_ptr.draft.contents);
            try appendBytes(self.gpa, &bytes, row_ptr.draft.link_target);
        }
        return try bytes.toOwnedSlice(self.gpa);
    }
};

fn collectSubtree(model: *const Model, id: NodeId, out: *std.ArrayList(NodeId)) !void {
    try out.append(model.gpa, id);
    for (model.rows.items) |row_ptr| if (row_ptr.parent == id) try collectSubtree(model, row_ptr.id, out);
}

fn appendU32(gpa: std.mem.Allocator, bytes: *std.ArrayList(u8), value: u32) !void {
    var encoded: [4]u8 = undefined;
    std.mem.writeInt(u32, &encoded, value, .little);
    try bytes.appendSlice(gpa, &encoded);
}

fn appendBytes(gpa: std.mem.Allocator, bytes: *std.ArrayList(u8), value: []const u8) !void {
    try appendU32(gpa, bytes, @intCast(value.len));
    try bytes.appendSlice(gpa, value);
}

fn copyName(arena: std.mem.Allocator, bytes: []const u8) !contract.Name {
    const owned = try arena.dupe(u8, bytes);
    return contract.Name.init(owned);
}

fn decodePending(arena: std.mem.Allocator, operations: *std.ArrayList(contract.Planned), destination: contract.ParentRef, intent: transfer.Intent, payload: []const u8) !void {
    _ = intent;
    if (!std.mem.startsWith(u8, payload, snapshot_magic)) return error.InvalidTransfer;
    var cursor: usize = snapshot_magic.len;
    const count = try readU32(payload, &cursor);
    const op_indexes = try arena.alloc(usize, count);
    for (op_indexes) |*index| index.* = no_parent;
    var records: usize = 0;
    while (records < count) : (records += 1) {
        const parent_record = try readU32(payload, &cursor);
        const raw_kind = try readU8(payload, &cursor);
        if (raw_kind > @intFromEnum(contract.Kind.other)) return error.InvalidTransfer;
        const kind: contract.Kind = @enumFromInt(raw_kind);
        const mode = try readU32(payload, &cursor);
        const name = try readBytes(payload, &cursor);
        const contents = try readBytes(payload, &cursor);
        const link_target = try readBytes(payload, &cursor);
        const parent: contract.ParentRef = if (parent_record == no_parent)
            destination
        else blk: {
            if (parent_record >= records) return error.InvalidTransfer;
            break :blk .{ .planned = op_indexes[parent_record] };
        };
        const name_value = try copyName(arena, name);
        const operation: contract.Operation = switch (kind) {
            .directory => .{ .create_directory = .{ .destination = .{ .parent = parent, .name = name_value }, .mode = if (mode == 0) null else mode } },
            .regular => .{ .create_file = .{ .destination = .{ .parent = parent, .name = name_value }, .contents = try arena.dupe(u8, contents), .mode = if (mode == 0) null else mode } },
            .symlink => .{ .create_symlink = .{ .destination = .{ .parent = parent, .name = name_value }, .target = try arena.dupe(u8, link_target) } },
            .other => return error.UnsupportedTransfer,
        };
        const index = operations.items.len;
        try operations.append(arena, .{ .id = opId(index), .operation = operation, .depends_on = if (parent_record == no_parent) &.{} else try arena.dupe(usize, &.{op_indexes[parent_record]}) });
        op_indexes[records] = index;
    }
    if (cursor != payload.len) return error.InvalidTransfer;
}

fn readU8(bytes: []const u8, cursor: *usize) !u8 {
    if (cursor.* >= bytes.len) return error.InvalidTransfer;
    const value = bytes[cursor.*];
    cursor.* += 1;
    return value;
}

fn readU32(bytes: []const u8, cursor: *usize) !u32 {
    if (bytes.len -| cursor.* < 4) return error.InvalidTransfer;
    const value = std.mem.readInt(u32, bytes[cursor.*..][0..4], .little);
    cursor.* += 4;
    return value;
}

fn readBytes(bytes: []const u8, cursor: *usize) ![]const u8 {
    const length = try readU32(bytes, cursor);
    if (length > bytes.len - cursor.*) return error.InvalidTransfer;
    const result = bytes[cursor.*..][0..length];
    cursor.* += length;
    return result;
}

fn sameEntry(a: contract.EntryRef, b: contract.EntryRef) bool {
    return a.authority == b.authority and a.slot == b.slot and a.generation == b.generation;
}

fn opId(index: usize) contract.OperationId {
    var id: contract.OperationId = @splat(0);
    std.mem.writeInt(usize, id[0..@sizeOf(usize)], index, .little);
    return id;
}

fn entryRef(slot: u32, generation: u32) contract.EntryRef {
    return .{ .authority = .here, .slot = slot, .generation = generation };
}

test "yank copy and cut paste use generic transfer items across instances" {
    var source = Model.init(std.testing.allocator, .{ .authority = .here, .slot = 0, .generation = 1 });
    defer source.deinit();
    var destination = Model.init(std.testing.allocator, source.root);
    defer destination.deinit();
    try source.reconcile(.{ .entries = &.{.{ .identity = entryRef(1, 1), .name = "a", .revision = "r1", .kind = .regular }} });
    const id = source.rows.items[0].id;
    const copied = try source.yank(id, .copy);
    var copy_plan = try destination.planPaste(.root, copied);
    defer copy_plan.deinit();
    try std.testing.expect(std.meta.activeTag(copy_plan.value.operations[0].operation) == .copy);
    var same_copy_plan = try source.planPaste(.root, copied);
    defer same_copy_plan.deinit();
    try std.testing.expect(std.meta.activeTag(same_copy_plan.value.operations[0].operation) == .copy);
    const cut = try source.yank(id, .cut);
    var cut_plan = try source.planPaste(.root, cut);
    defer cut_plan.deinit();
    try std.testing.expect(std.meta.activeTag(cut_plan.value.operations[0].operation) == .rename);
}

test "copy keeps old suggested name and source revision after source rename" {
    var source = Model.init(std.testing.allocator, .{ .authority = .here, .slot = 0, .generation = 1 });
    defer source.deinit();
    try source.reconcile(.{ .entries = &.{.{ .identity = entryRef(2, 1), .name = "old", .revision = "r1", .kind = .regular }} });
    const id = source.rows.items[0].id;
    const item = try source.yank(id, .copy);
    try source.rename(id, "new");
    var plan = try source.planPaste(.root, item);
    defer plan.deinit();
    const operation = plan.value.operations[0].operation.copy;
    try std.testing.expectEqualStrings("old", operation.destination.name.bytes);
    try std.testing.expectEqualStrings("r1", operation.source.entry.revision.token);
}

test "deleted source and reused name still paste by old identity" {
    var model = Model.init(std.testing.allocator, .{ .authority = .here, .slot = 0, .generation = 1 });
    defer model.deinit();
    try model.reconcile(.{ .entries = &.{.{ .identity = entryRef(3, 1), .name = "same", .revision = "r-old", .kind = .regular }} });
    const item = try model.yank(model.rows.items[0].id, .copy);
    try model.reconcile(.{ .entries = &.{.{ .identity = entryRef(3, 2), .name = "same", .revision = "r-new", .kind = .regular }} });
    var plan = try model.planPaste(.root, item);
    defer plan.deinit();
    try std.testing.expectEqual(@as(u32, 1), plan.value.operations[0].operation.copy.source.entry.ref.generation);
    try std.testing.expectEqualStrings("r-old", plan.value.operations[0].operation.copy.source.entry.revision.token);
}

test "externally deleted source remains an identity-guarded paste" {
    var model = Model.init(std.testing.allocator, .{ .authority = .here, .slot = 0, .generation = 1 });
    defer model.deinit();
    try model.reconcile(.{ .entries = &.{.{ .identity = entryRef(7, 1), .name = "gone", .revision = "r-gone", .kind = .regular }} });
    const item = try model.yank(model.rows.items[0].id, .copy);
    try model.reconcile(.{ .entries = &.{} });
    var plan = try model.planPaste(.root, item);
    defer plan.deinit();
    const operation = plan.value.operations[0].operation.copy;
    try std.testing.expectEqual(@as(u32, 7), operation.source.entry.ref.slot);
    try std.testing.expectEqualStrings("r-gone", operation.source.entry.revision.token);
}

test "pending subtree transfer is immutable after original delete" {
    var model = Model.init(std.testing.allocator, .{ .authority = .here, .slot = 0, .generation = 1 });
    defer model.deinit();
    const directory = try model.addDirectory(null, "pending", null);
    _ = try model.addFile(directory, "line\n-[]'", "body", null);
    const item = try model.yank(directory, .copy);
    try model.markDelete(directory);
    var plan = try model.planPaste(.root, item);
    defer plan.deinit();
    try std.testing.expectEqual(@as(usize, 2), plan.value.operations.len);
    try std.testing.expect(std.meta.activeTag(plan.value.operations[0].operation) == .create_directory);
    try std.testing.expect(std.meta.activeTag(plan.value.operations[1].operation) == .create_file);
    try std.testing.expectEqual(@as(usize, 1), plan.value.operations[1].depends_on.len);
}

test "unusual names and symlinks remain raw and are copied without following" {
    var model = Model.init(std.testing.allocator, .{ .authority = .here, .slot = 0, .generation = 1 });
    defer model.deinit();
    try model.reconcile(.{ .entries = &.{
        .{ .identity = entryRef(4, 1), .name = "line\n-[]'", .revision = "r", .kind = .symlink, .link_target = "target" },
    } });
    const item = try model.yank(model.rows.items[0].id, .copy);
    var plan = try model.planPaste(.root, item);
    defer plan.deinit();
    const operation = plan.value.operations[0].operation.copy;
    try std.testing.expectEqual(@as(u32, 4), operation.source.entry.ref.slot);
    try std.testing.expectEqualStrings("line\n-[]'", operation.destination.name.bytes);
}

test "external reorder and mutation preserve draft anchoring" {
    var model = Model.init(std.testing.allocator, .{ .authority = .here, .slot = 0, .generation = 1 });
    defer model.deinit();
    try model.reconcile(.{ .entries = &.{
        .{ .identity = entryRef(5, 1), .name = "a", .revision = "r1", .kind = .regular },
        .{ .identity = entryRef(6, 1), .name = "b", .revision = "r1", .kind = .regular },
    } });
    const a_id = model.rowForIdentity(entryRef(5, 1)).?;
    try model.rename(a_id, "draft-a");
    try model.reconcile(.{ .entries = &.{
        .{ .identity = entryRef(6, 1), .name = "b-new", .revision = "r2", .kind = .regular },
        .{ .identity = entryRef(5, 1), .name = "a-external", .revision = "r3", .kind = .regular },
    } });
    const anchored = model.row(a_id).?;
    try std.testing.expectEqualStrings("draft-a", anchored.draft.name);
    try std.testing.expectEqualStrings("r3", anchored.observed.?.revision);
    try std.testing.expectEqual(@as(u32, 5), anchored.observed.?.identity.slot);
}
