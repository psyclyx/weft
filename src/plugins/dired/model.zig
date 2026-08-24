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
pub const PastePlacement = enum { before, after };
pub const PasteAnchor = struct {
    row: NodeId,
    parent: ?NodeId,
};
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
    kind: contract.Kind,
    mode: ?u32,
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
const entry_schema = "weft.dired.entry.v2";
const tree_media = "application/x-weft-dired-tree";
const tree_schema = "weft.dired.tree.v1";
const entry_magic = "weft-dired-entry-v2\x00";
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
        try validateSnapshot(snapshot);
        var seen = std.AutoHashMapUnmanaged(NodeId, void).empty;
        defer seen.deinit(self.gpa);
        for (snapshot.entries) |entry| {
            if (self.rowForIdentity(entry.identity)) |id| {
                const row_ptr = self.rowMutable(id).?;
                try seen.put(self.gpa, id, {});
                if (isDirty(row_ptr)) {
                    const external_change = if (row_ptr.base) |base| !observationMatches(base, entry) else true;
                    const latest = try cloneObservation(self.gpa, entry);
                    self.freeObservation(&row_ptr.current);
                    row_ptr.current = latest;
                    if (external_change) row_ptr.conflict = .stale;
                } else {
                    const next_base = try cloneObservation(self.gpa, entry);
                    errdefer freeObservationWith(self.gpa, &next_base);
                    const next_current = try cloneObservation(self.gpa, entry);
                    errdefer freeObservationWith(self.gpa, &next_current);
                    const next_draft = try draftFrom(self.gpa, entry);
                    errdefer freeDraftWith(self.gpa, &next_draft);
                    self.freeObservation(&row_ptr.base);
                    self.freeObservation(&row_ptr.current);
                    freeDraftWith(self.gpa, &row_ptr.draft);
                    row_ptr.base = next_base;
                    row_ptr.current = next_current;
                    row_ptr.draft = next_draft;
                    row_ptr.name_dirty = false;
                    row_ptr.mode_dirty = false;
                    row_ptr.pending = .observed;
                    row_ptr.copy_source = null;
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
            payload = try encodeEntry(self.gpa, source.root, source.entry, source.revision, source.kind, source.mode);
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
        try self.validateParent(parent);
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

    /// Paste beside a stable row anchor. The anchor's parent is supplied by
    /// the caller so a stale listing cannot silently retarget the operation.
    /// Placement affects only visible draft ordering; filesystem plans carry
    /// typed destinations and never encode a row index.
    pub fn pasteAt(self: *Model, anchor: PasteAnchor, placement: PastePlacement, item: *const transfer.OwnedItem) !NodeId {
        const index = try self.anchorIndex(anchor, placement);
        const value = item.value;
        if (value.representation(entry_media)) |representation| {
            if (!std.mem.eql(u8, representation.schema orelse return error.InvalidTransfer, entry_schema)) return error.InvalidTransfer;
            const captured = try decodeEntry(representation.payload);
            var copied_row = try self.makeCopiedRow(self.next_id, anchor.parent, value.suggested_name, captured, value.intent);
            var committed = false;
            errdefer if (!committed) self.freeRow(&copied_row);
            const id = try self.insertOwnedRows(index, &.{copied_row});
            committed = true;
            return id;
        }
        const representation = value.representation(tree_media) orelse return error.UnsupportedTransfer;
        if (!std.mem.eql(u8, representation.schema orelse return error.InvalidTransfer, tree_schema)) return error.InvalidTransfer;
        return self.decodeTreeAt(anchor.parent, value.suggested_name, representation.payload, value.intent, index);
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
        if (entry.name.len > max_transfer_name or entry.revision.len > max_transfer_revision or
            entry.contents.len > max_transfer_payload or entry.link_target.len > max_transfer_payload)
            return error.TransferTooLarge;
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
        if (name.len > max_transfer_name) return error.TransferTooLarge;
        try self.validateParent(parent);
        const insertion_index = try self.parentInsertionIndex(parent);
        _ = try contract.Name.init(name);
        const id = self.next_id;
        var pending_row = try self.makePendingRow(id, parent, name, kind, mode, contents, link_target, pending);
        var committed = false;
        errdefer if (!committed) self.freeRow(&pending_row);
        _ = try self.insertOwnedRows(insertion_index, &.{pending_row});
        committed = true;
        return id;
    }

    fn appendCopied(self: *Model, parent: ?NodeId, name: []const u8, captured: EntryCapture, intent: transfer.Intent) !NodeId {
        try self.validateParent(parent);
        const insertion_index = try self.parentInsertionIndex(parent);
        const id = self.next_id;
        var copied_row = try self.makeCopiedRow(id, parent, name, captured, intent);
        var committed = false;
        errdefer if (!committed) self.freeRow(&copied_row);
        _ = try self.insertOwnedRows(insertion_index, &.{copied_row});
        committed = true;
        return id;
    }

    fn makePendingRow(self: *Model, id: NodeId, parent: ?NodeId, name: []const u8, kind: contract.Kind, mode: ?u32, contents: []const u8, link_target: []const u8, pending: Pending) !Row {
        _ = try contract.Name.init(name);
        var draft = Draft{ .name = &.{}, .kind = kind, .mode = mode, .contents = &.{}, .link_target = &.{} };
        errdefer freeDraftWith(self.gpa, &draft);
        draft.name = try self.gpa.dupe(u8, name);
        draft.contents = try self.gpa.dupe(u8, contents);
        draft.link_target = try self.gpa.dupe(u8, link_target);
        return .{ .id = id, .parent = parent, .base = null, .current = null, .draft = draft, .pending = pending };
    }

    fn makeCopiedRow(self: *Model, id: NodeId, parent: ?NodeId, name: []const u8, captured: EntryCapture, intent: transfer.Intent) !Row {
        if (name.len > max_transfer_name) return error.TransferTooLarge;
        const revision = try self.gpa.dupe(u8, captured.revision);
        errdefer self.gpa.free(revision);
        var copied_row = try self.makePendingRow(id, parent, name, captured.kind, captured.mode, &.{}, &.{}, .copied);
        errdefer self.freeRow(&copied_row);
        copied_row.copy_source = .{ .root = captured.root, .entry = captured.entry, .revision = revision, .kind = captured.kind, .mode = captured.mode, .intent = intent };
        return copied_row;
    }

    fn insertOwnedRows(self: *Model, index: usize, rows: []const Row) !NodeId {
        if (rows.len == 0 or index > self.rows.items.len) return error.InvalidPlacement;
        if (self.next_id > std.math.maxInt(NodeId) - rows.len) return error.TooManyRows;
        try self.rows.ensureTotalCapacity(self.gpa, self.rows.items.len + rows.len);
        const old_len = self.rows.items.len;
        self.rows.items.len = old_len + rows.len;
        std.mem.copyBackwards(Row, self.rows.items[index + rows.len .. old_len + rows.len], self.rows.items[index..old_len]);
        std.mem.copyForwards(Row, self.rows.items[index .. index + rows.len], rows);
        self.next_id += @intCast(rows.len);
        return rows[0].id;
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
            if (parent_row.pending == .deleted or parent_row.conflict == .stale) return error.StaleParent;
            cursor = parent_row.parent;
        }
    }

    fn parentInsertionIndex(self: *const Model, parent: ?NodeId) !usize {
        const id = parent orelse return self.rows.items.len;
        const index = self.indexOf(id) orelse return error.UnknownParent;
        return self.subtreeEnd(index);
    }

    fn anchorIndex(self: *const Model, anchor: PasteAnchor, placement: PastePlacement) !usize {
        const anchor_index = self.indexOf(anchor.row) orelse return error.UnknownAnchor;
        const anchor_row = &self.rows.items[anchor_index];
        if (!sameOptionalId(anchor_row.parent, anchor.parent)) return error.StaleAnchor;
        if (anchor_row.conflict == .stale or anchor_row.pending == .deleted) return error.StaleAnchor;
        if (anchor.parent) |parent| {
            const parent_row = self.row(parent) orelse return error.StaleAnchor;
            if (parent_row.draft.kind != .directory) return error.NotDirectory;
            if (parent_row.pending == .deleted or parent_row.conflict == .stale) return error.StaleAnchor;
        }
        return switch (placement) {
            .before => anchor_index,
            .after => self.subtreeEnd(anchor_index),
        };
    }

    fn subtreeEnd(self: *const Model, start: usize) usize {
        var end = start + 1;
        while (end < self.rows.items.len and self.isDescendant(self.rows.items[end].id, self.rows.items[start].id)) end += 1;
        return end;
    }

    fn isDescendant(self: *const Model, candidate: NodeId, ancestor: NodeId) bool {
        var cursor = self.row(candidate).?.parent;
        var steps: usize = 0;
        while (cursor) |parent| : (steps += 1) {
            if (parent == ancestor) return true;
            if (steps >= self.rows.items.len) return false;
            cursor = (self.row(parent) orelse return false).parent;
        }
        return false;
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
        const insertion_index = try self.parentInsertionIndex(parent);
        return self.decodeTreeAt(parent, root_name, payload, intent, insertion_index);
    }

    fn decodeTreeAt(self: *Model, parent: ?NodeId, root_name: []const u8, payload: []const u8, intent: transfer.Intent, insertion_index: usize) !NodeId {
        if (payload.len > max_transfer_payload or !std.mem.startsWith(u8, payload, tree_magic)) return error.InvalidTransfer;
        if (root_name.len > max_transfer_name) return error.TransferTooLarge;
        _ = try contract.Name.init(root_name);
        try self.validateParent(parent);
        var cursor: usize = tree_magic.len;
        const count = try getU32(payload, &cursor);
        if (count == 0 or count > max_transfer_records) return error.InvalidTransfer;
        const DecodedNode = struct {
            parent_index: u32,
            kind: contract.Kind,
            mode: ?u32,
            name: []const u8,
            contents: []const u8,
            link_target: []const u8,
        };
        var decoded: std.ArrayList(DecodedNode) = .empty;
        defer decoded.deinit(self.gpa);
        try decoded.ensureTotalCapacity(self.gpa, count);
        for (0..count) |index| {
            const parent_index = try getU32(payload, &cursor);
            const raw_kind = try getU8(payload, &cursor);
            if (raw_kind > @intFromEnum(contract.Kind.other) or cursor >= payload.len) return error.InvalidTransfer;
            const kind: contract.Kind = @enumFromInt(raw_kind);
            const has_mode = try getU8(payload, &cursor);
            if (has_mode > 1) return error.InvalidTransfer;
            const mode_value = try getU32(payload, &cursor);
            const name = try getBytes(payload, &cursor, max_transfer_name);
            const contents = try getBytes(payload, &cursor, max_transfer_payload);
            const link_target = try getBytes(payload, &cursor, max_transfer_payload);
            _ = try contract.Name.init(name);
            if (index == 0) {
                if (parent_index != no_parent) return error.InvalidTransfer;
            } else {
                if (parent_index == no_parent or parent_index >= index) return error.InvalidTransfer;
                if (decoded.items[parent_index].kind != .directory) return error.NotDirectory;
            }
            try decoded.append(self.gpa, .{ .parent_index = parent_index, .kind = kind, .mode = if (has_mode == 0) null else mode_value, .name = name, .contents = contents, .link_target = link_target });
        }
        if (cursor != payload.len) return error.InvalidTransfer;
        if (self.next_id > std.math.maxInt(NodeId) - @as(NodeId, @intCast(count))) return error.TooManyRows;
        const ids = try self.gpa.alloc(NodeId, count);
        defer self.gpa.free(ids);
        const inserted = try self.gpa.alloc(Row, count);
        defer self.gpa.free(inserted);
        var initialized: usize = 0;
        var committed = false;
        errdefer if (!committed) for (inserted[0..initialized]) |*row_ptr| self.freeRow(row_ptr);
        for (decoded.items, 0..) |node, index| {
            ids[index] = self.next_id + @as(NodeId, @intCast(index));
            const row_parent = if (index == 0) parent else ids[node.parent_index];
            const actual_name = if (index == 0) root_name else node.name;
            inserted[index] = try self.makePendingRow(ids[index], row_parent, actual_name, node.kind, node.mode, node.contents, node.link_target, .added);
            initialized += 1;
        }
        const first = try self.insertOwnedRows(insertion_index, inserted);
        committed = true;
        _ = intent;
        return first;
    }
};

const Builder = struct {
    arena: std.mem.Allocator,
    model: *const Model,
    operations: std.ArrayList(contract.Planned) = .empty,
    emitted: std.ArrayList(NodeId) = .empty,
    create_operations: std.ArrayList(struct { id: NodeId, index: usize }) = .empty,
    capture_operations: std.ArrayList(struct { source: contract.EntrySource, index: usize }) = .empty,
    visiting: std.ArrayList(NodeId) = .empty,

    fn init(arena: std.mem.Allocator, model: *const Model) Builder {
        return .{ .arena = arena, .model = model };
    }

    fn build(self: *Builder) !void {
        // Captured transfers are immutable references to an observed source.
        // Emit them in their own phase before source-local rename/remove
        // effects, regardless of where a pasted row sits in the listing.
        // This is the planner's ordering invariant; row order is only draft
        // presentation state and cannot establish source lifetime.
        for (self.model.rows.items) |row| {
            if (row.pending == .copied or row.pending == .copied_renamed)
                try self.emit(row.id);
        }
        for (self.model.rows.items) |row| if (isDirty(&row)) try self.emit(row.id);
    }

    fn emit(self: *Builder, id: NodeId) !void {
        if (contains(self.emitted.items, id)) return;
        if (contains(self.visiting.items, id)) return error.ParentCycle;
        const row_ptr = self.model.row(id) orelse return error.UnknownNode;
        if (row_ptr.conflict == .stale) return error.Stale;
        // A pending-only subtree deleted before apply has no filesystem
        // operation to emit. Suppress descendants at any depth; their
        // captured draft data remains available to an independent paste.
        if (try self.suppressedByDeletedAncestor(id)) {
            try self.emitted.append(self.arena, id);
            return;
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
            const source = baseSource(self.model, row_ptr) orelse return error.Stale;
            // A captured copy/cut still needs this exact source identity and
            // revision.  Do not queue a removal that would invalidate that
            // effect (and would make a later destination conflict destructive).
            // The source is intentionally preserved; provider policy belongs
            // to the executor, not this pure draft planner.
            if (!self.hasDependentCapture(source))
                try self.add(.{ .remove = .{ .source = try self.copyEntrySource(source) } }, row_ptr, null);
        } else if (row_ptr.pending == .added) {
            try self.addCreate(row_ptr, parent_ref, row_ptr.draft.name);
        } else if (row_ptr.pending == .copied or row_ptr.pending == .copied_renamed) {
            const source = row_ptr.copy_source orelse return error.Stale;
            const name = try copyName(self.arena, row_ptr.draft.name);
            const destination = contract.Slot{ .parent = parent_ref, .name = name };
            const captured_source = try self.capturedSource(source);
            const operation: contract.Operation = switch (source.intent) {
                .copy => .{ .copy = .{ .source = .{ .entry = captured_source }, .destination = destination } },
                .cut => .{ .rename = .{ .source = captured_source, .destination = destination } },
            };
            try self.add(operation, row_ptr, parent_ref);
        } else {
            const source = baseSource(self.model, row_ptr) orelse return error.Stale;
            if (row_ptr.name_dirty) {
                try self.add(.{ .rename = .{ .source = try self.copyEntrySource(source), .destination = .{ .parent = parent_ref, .name = try copyName(self.arena, row_ptr.draft.name) } } }, row_ptr, parent_ref);
            }
            if (row_ptr.mode_dirty) {
                try self.add(.{ .set_permissions = .{ .source = try self.copyEntrySource(source), .mode = row_ptr.draft.mode orelse return error.InvalidMode } }, row_ptr, null);
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

    fn copyEntrySource(self: *const Builder, value: contract.EntrySource) !contract.EntrySource {
        return .{ .root = value.root, .ref = value.ref, .revision = .{ .token = try self.arena.dupe(u8, value.revision.token) } };
    }

    fn capturedSource(self: *const Builder, value: CopySource) !contract.EntrySource {
        return .{ .root = value.root, .ref = value.entry, .revision = .{ .token = try self.arena.dupe(u8, value.revision) } };
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
        var dependencies: std.ArrayList(usize) = .empty;
        if (parent) |parent_ref| switch (parent_ref) {
            .root, .entry => {},
            .planned => |dependency| try appendDependency(self.arena, &dependencies, dependency),
        };
        // A source mutation must not run ahead of any captured effect that
        // uses the same root/ref/revision. These are real plan dependencies,
        // not an assumption about how rows happened to be listed.
        if (operationSource(operation)) |source| if (row_ptr.pending != .copied and row_ptr.pending != .copied_renamed) {
            for (self.capture_operations.items) |capture|
                if (sameSource(capture.source, source)) try appendDependency(self.arena, &dependencies, capture.index);
        };
        const depends_on = try dependencies.toOwnedSlice(self.arena);
        try self.operations.append(self.arena, .{ .id = opId(index), .operation = operation, .depends_on = depends_on });
        if (captureSource(row_ptr, operation)) |source|
            try self.capture_operations.append(self.arena, .{ .source = source, .index = index });
        if ((row_ptr.pending == .added or row_ptr.pending == .copied or row_ptr.pending == .copied_renamed) and
            !self.hasCreateOperation(row_ptr.id))
            try self.create_operations.append(self.arena, .{ .id = row_ptr.id, .index = index });
    }

    fn hasCreateOperation(self: *const Builder, id: NodeId) bool {
        for (self.create_operations.items) |planned| if (planned.id == id) return true;
        return false;
    }

    fn hasDependentCapture(self: *const Builder, source: contract.EntrySource) bool {
        for (self.model.rows.items) |row| {
            if (row.pending != .copied and row.pending != .copied_renamed) continue;
            const captured = row.copy_source orelse continue;
            if (sameRoot(captured.root, source.root) and
                sameEntry(captured.entry, source.ref) and
                std.mem.eql(u8, captured.revision, source.revision.token)) return true;
        }
        return false;
    }

    fn suppressedByDeletedAncestor(self: *const Builder, id: NodeId) !bool {
        var seen: std.AutoHashMapUnmanaged(NodeId, void) = .empty;
        defer seen.deinit(self.arena);
        var cursor: ?NodeId = id;
        while (cursor) |candidate| {
            if (seen.contains(candidate)) return error.ParentCycle;
            try seen.put(self.arena, candidate, {});
            const row_ptr = self.model.row(candidate) orelse return error.UnknownParent;
            if (row_ptr.pending == .deleted and row_ptr.base == null) return true;
            cursor = row_ptr.parent;
        }
        return false;
    }

    fn contains(values: []const NodeId, value: NodeId) bool {
        for (values) |candidate| if (candidate == value) return true;
        return false;
    }
};

fn appendDependency(arena: std.mem.Allocator, dependencies: *std.ArrayList(usize), value: usize) !void {
    for (dependencies.items) |existing| if (existing == value) return;
    try dependencies.append(arena, value);
}

fn operationSource(operation: contract.Operation) ?contract.EntrySource {
    return switch (operation) {
        .rename => |value| value.source,
        .remove => |value| value.source,
        .set_permissions => |value| value.source,
        else => null,
    };
}

fn captureSource(row_ptr: *const Row, operation: contract.Operation) ?contract.EntrySource {
    if (row_ptr.pending != .copied and row_ptr.pending != .copied_renamed) return null;
    return switch (operation) {
        .copy => |value| switch (value.source) {
            .entry => |source| source,
            .lease => null,
        },
        // A cut is represented as rename, but its source is still a captured
        // transfer and must participate in the same ordering invariant.
        .rename => |value| value.source,
        else => null,
    };
}

fn sameSource(a: contract.EntrySource, b: contract.EntrySource) bool {
    return sameRoot(a.root, b.root) and sameEntry(a.ref, b.ref) and std.mem.eql(u8, a.revision.token, b.revision.token);
}

const EntryCapture = struct {
    root: contract.Root,
    entry: contract.EntryRef,
    revision: []const u8,
    kind: contract.Kind,
    mode: ?u32 = null,
};

fn sourceFor(model: *const Model, row_ptr: *const Row) ?struct { root: contract.Root, entry: contract.EntryRef, revision: []const u8, kind: contract.Kind, mode: ?u32 } {
    if (row_ptr.copy_source) |source| return .{ .root = source.root, .entry = source.entry, .revision = source.revision, .kind = source.kind, .mode = source.mode };
    const observed = row_ptr.current orelse row_ptr.base orelse return null;
    return .{ .root = model.root, .entry = observed.identity, .revision = observed.revision, .kind = observed.kind, .mode = observed.mode };
}

fn baseSource(model: *const Model, row_ptr: *const Row) ?contract.EntrySource {
    const observed = row_ptr.base orelse return null;
    return .{ .root = model.root, .ref = observed.identity, .revision = .{ .token = observed.revision } };
}

fn isDirty(row_ptr: *const Row) bool {
    return row_ptr.pending != .observed or row_ptr.name_dirty or row_ptr.mode_dirty or row_ptr.conflict != .none;
}

fn validateSnapshot(snapshot: Snapshot) !void {
    for (snapshot.entries, 0..) |entry, index| {
        _ = entry;
        for (snapshot.entries[index + 1 ..]) |later| {
            if (sameEntry(snapshot.entries[index].identity, later.identity)) return error.DuplicateIdentity;
        }
    }
}

fn observationMatches(base: Observation, latest: SnapshotEntry) bool {
    return sameEntry(base.identity, latest.identity) and
        std.mem.eql(u8, base.revision, latest.revision) and
        std.mem.eql(u8, base.name, latest.name) and
        base.kind == latest.kind and
        base.mode == latest.mode;
}

fn cloneObservation(gpa: std.mem.Allocator, entry: SnapshotEntry) !Observation {
    var observation = Observation{ .identity = entry.identity, .revision = &.{}, .name = &.{}, .kind = entry.kind, .mode = entry.mode };
    errdefer freeObservationWith(gpa, &observation);
    observation.revision = try gpa.dupe(u8, entry.revision);
    observation.name = try gpa.dupe(u8, entry.name);
    return observation;
}

fn draftFrom(gpa: std.mem.Allocator, entry: SnapshotEntry) !Draft {
    var draft = Draft{ .name = &.{}, .kind = entry.kind, .mode = entry.mode, .contents = &.{}, .link_target = &.{} };
    errdefer freeDraftWith(gpa, &draft);
    draft.name = try gpa.dupe(u8, entry.name);
    draft.contents = try gpa.dupe(u8, entry.contents);
    draft.link_target = try gpa.dupe(u8, entry.link_target);
    return draft;
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
    if (nodes.items.len >= max_transfer_records) return error.TransferTooLarge;
    try nodes.append(model.gpa, id);
    for (model.rows.items) |row| if (row.parent == id) try collect(model, row.id, nodes);
}

fn encodeEntry(gpa: std.mem.Allocator, root: contract.Root, entry_ref: contract.EntryRef, revision: []const u8, kind: contract.Kind, mode: ?u32) ![]u8 {
    if (revision.len > max_transfer_revision) return error.TransferTooLarge;
    var bytes: std.ArrayList(u8) = .empty;
    errdefer bytes.deinit(gpa);
    try bytes.appendSlice(gpa, entry_magic);
    try putHandle(gpa, &bytes, root.authority, root.slot, root.generation);
    try putHandle(gpa, &bytes, entry_ref.authority, entry_ref.slot, entry_ref.generation);
    try putBytes(gpa, &bytes, revision, max_transfer_revision);
    try bytes.append(gpa, @intFromEnum(kind));
    try bytes.append(gpa, if (mode != null) 1 else 0);
    try putU32(gpa, &bytes, mode orelse 0);
    if (bytes.items.len > max_transfer_payload) return error.TransferTooLarge;
    return bytes.toOwnedSlice(gpa);
}

fn decodeEntry(payload: []const u8) !EntryCapture {
    if (payload.len > max_transfer_payload or !std.mem.startsWith(u8, payload, entry_magic)) return error.InvalidTransfer;
    var cursor: usize = entry_magic.len;
    const root = try getRoot(payload, &cursor);
    const entry_ref = try getEntry(payload, &cursor);
    const revision = try getBytes(payload, &cursor, max_transfer_revision);
    const raw_kind = try getU8(payload, &cursor);
    if (raw_kind > @intFromEnum(contract.Kind.other)) return error.InvalidTransfer;
    const has_mode = try getU8(payload, &cursor);
    if (has_mode > 1) return error.InvalidTransfer;
    const mode = try getU32(payload, &cursor);
    if (cursor != payload.len) return error.InvalidTransfer;
    return .{ .root = root, .entry = entry_ref, .revision = revision, .kind = @enumFromInt(raw_kind), .mode = if (has_mode == 0) null else mode };
}

fn putHandle(gpa: std.mem.Allocator, bytes: *std.ArrayList(u8), authority: kernel.handle.Authority, slot: u32, generation: u32) !void {
    if (generation == 0) return error.InvalidTransfer;
    try putU32(gpa, bytes, @intFromEnum(authority));
    try putU32(gpa, bytes, slot);
    try putU32(gpa, bytes, generation);
}

fn getRoot(payload: []const u8, cursor: *usize) !contract.Root {
    const authority = try getU32(payload, cursor);
    const slot = try getU32(payload, cursor);
    const generation = try getU32(payload, cursor);
    if (generation == 0) return error.InvalidTransfer;
    return .{ .authority = @enumFromInt(authority), .slot = slot, .generation = generation };
}

fn getEntry(payload: []const u8, cursor: *usize) !contract.EntryRef {
    const authority = try getU32(payload, cursor);
    const slot = try getU32(payload, cursor);
    const generation = try getU32(payload, cursor);
    if (generation == 0) return error.InvalidTransfer;
    return .{ .authority = @enumFromInt(authority), .slot = slot, .generation = generation };
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
    if (cursor.* > payload.len) return error.InvalidTransfer;
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

fn sameRoot(a: contract.Root, b: contract.Root) bool {
    return a.authority == b.authority and a.slot == b.slot and a.generation == b.generation;
}

fn sameOptionalId(left: ?NodeId, right: ?NodeId) bool {
    if (left) |value| return right != null and right.? == value;
    return right == null;
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
    try source.reconcile(.{ .entries = &.{.{ .identity = ref(2, 1), .name = "old", .revision = "rev", .kind = .regular, .mode = 0o600 }} });
    var item = try source.yank(source.rows.items[0].id, .copy);
    defer item.deinit();
    var destination = Model.init(std.testing.allocator, source.root);
    defer destination.deinit();
    const copied = try destination.paste(null, &item);
    try std.testing.expectEqual(contract.Kind.regular, destination.row(copied).?.draft.kind);
    try std.testing.expectEqual(@as(?u32, 0o600), destination.row(copied).?.draft.mode);
    try destination.rename(copied, "edited");
    var plan = try destination.buildPlan();
    defer plan.deinit();
    try std.testing.expectEqualStrings("edited", plan.value.operations[0].operation.copy.destination.name.bytes);
    try std.testing.expectEqual(source.root, plan.value.operations[0].operation.copy.source.entry.root);
}

test "entry paste before and after uses stable sibling anchors" {
    var source = Model.init(std.testing.allocator, .{ .authority = .here, .slot = 10, .generation = 1 });
    try source.reconcile(.{ .entries = &.{.{ .identity = ref(31, 1), .name = "copied", .revision = "r", .kind = .regular }} });
    var item = try source.yank(source.rows.items[0].id, .copy);
    source.deinit();
    defer item.deinit();

    var destination = Model.init(std.testing.allocator, .{ .authority = .here, .slot = 20, .generation = 1 });
    defer destination.deinit();
    try destination.reconcile(.{ .entries = &.{
        .{ .identity = ref(32, 1), .name = "left", .revision = "r", .kind = .regular },
        .{ .identity = ref(33, 1), .name = "right", .revision = "r", .kind = .regular },
    } });
    const right = destination.rows.items[1].id;
    _ = try destination.pasteAt(.{ .row = right, .parent = null }, .before, &item);
    try std.testing.expectEqualStrings("left", destination.rows.items[0].draft.name);
    try std.testing.expectEqualStrings("copied", destination.rows.items[1].draft.name);
    try std.testing.expectEqualStrings("right", destination.rows.items[2].draft.name);
    const left = destination.rows.items[0].id;
    _ = try destination.pasteAt(.{ .row = left, .parent = null }, .after, &item);
    try std.testing.expectEqualStrings("left", destination.rows.items[0].draft.name);
    try std.testing.expectEqualStrings("copied", destination.rows.items[1].draft.name);
    try std.testing.expectEqualStrings("copied", destination.rows.items[2].draft.name);
    try std.testing.expectEqualStrings("right", destination.rows.items[3].draft.name);
}

test "pending subtree paste stays contiguous preorder around siblings after source deletion" {
    var source = Model.init(std.testing.allocator, .{ .authority = .here, .slot = 40, .generation = 1 });
    _ = try source.addDirectory(null, "subtree", null);
    const subtree = source.rows.items[0].id;
    _ = try source.addFile(subtree, "leaf", "contents", null);
    var item = try source.yank(subtree, .copy);
    try source.markDelete(subtree);
    source.deinit();
    defer item.deinit();

    var destination = Model.init(std.testing.allocator, .{ .authority = .here, .slot = 41, .generation = 1 });
    defer destination.deinit();
    _ = try destination.addFile(null, "left", "", null);
    const right = try destination.addFile(null, "right", "", null);
    _ = try destination.pasteAt(.{ .row = right, .parent = null }, .before, &item);
    try std.testing.expectEqualStrings("left", destination.rows.items[0].draft.name);
    try std.testing.expectEqualStrings("subtree", destination.rows.items[1].draft.name);
    try std.testing.expectEqualStrings("leaf", destination.rows.items[2].draft.name);
    try std.testing.expectEqualStrings("right", destination.rows.items[3].draft.name);
    try std.testing.expectEqual(destination.rows.items[2].parent, destination.rows.items[1].id);

    const left = destination.rows.items[0].id;
    _ = try destination.pasteAt(.{ .row = left, .parent = null }, .after, &item);
    try std.testing.expectEqualStrings("left", destination.rows.items[0].draft.name);
    try std.testing.expectEqualStrings("subtree", destination.rows.items[1].draft.name);
    try std.testing.expectEqualStrings("leaf", destination.rows.items[2].draft.name);
    try std.testing.expectEqualStrings("subtree", destination.rows.items[3].draft.name);
    try std.testing.expectEqualStrings("leaf", destination.rows.items[4].draft.name);
    try std.testing.expectEqualStrings("right", destination.rows.items[5].draft.name);
}

test "late pending child is inserted after its parent subtree, not after later siblings" {
    var model = Model.init(std.testing.allocator, .{ .authority = .here, .slot = 60, .generation = 1 });
    defer model.deinit();
    const parent = try model.addDirectory(null, "parent", null);
    _ = try model.addFile(null, "sibling", "", null);
    const child = try model.addFile(parent, "child", "", null);
    try std.testing.expectEqual(parent, model.rows.items[0].id);
    try std.testing.expectEqual(child, model.rows.items[1].id);
    try std.testing.expectEqualStrings("sibling", model.rows.items[2].draft.name);
}

test "paste after directory lands after its complete existing subtree" {
    var source = Model.init(std.testing.allocator, .{ .authority = .here, .slot = 61, .generation = 1 });
    defer source.deinit();
    try source.reconcile(.{ .entries = &.{.{ .identity = ref(62, 1), .name = "copy", .revision = "r", .kind = .regular }} });
    var item = try source.yank(source.rows.items[0].id, .copy);
    defer item.deinit();

    var destination = Model.init(std.testing.allocator, .{ .authority = .here, .slot = 63, .generation = 1 });
    defer destination.deinit();
    const directory = try destination.addDirectory(null, "directory", null);
    _ = try destination.addFile(directory, "child", "", null);
    _ = try destination.addFile(null, "sibling", "", null);
    _ = try destination.paste(directory, &item);
    _ = try destination.pasteAt(.{ .row = directory, .parent = null }, .after, &item);
    try std.testing.expectEqualStrings("directory", destination.rows.items[0].draft.name);
    try std.testing.expectEqualStrings("child", destination.rows.items[1].draft.name);
    try std.testing.expectEqualStrings("copy", destination.rows.items[2].draft.name);
    try std.testing.expectEqualStrings("copy", destination.rows.items[3].draft.name);
    try std.testing.expectEqualStrings("sibling", destination.rows.items[4].draft.name);
}

test "paste placement rejects stale anchors without changing draft rows" {
    var source = Model.init(std.testing.allocator, .{ .authority = .here, .slot = 50, .generation = 1 });
    defer source.deinit();
    try source.reconcile(.{ .entries = &.{.{ .identity = ref(51, 1), .name = "source", .revision = "r", .kind = .regular }} });
    var item = try source.yank(source.rows.items[0].id, .copy);
    defer item.deinit();

    var destination = Model.init(std.testing.allocator, .{ .authority = .here, .slot = 52, .generation = 1 });
    defer destination.deinit();
    const anchor = try destination.addFile(null, "anchor", "", null);
    const before_rows = destination.rows.items.len;
    const before_next = destination.next_id;
    try std.testing.expectError(error.StaleAnchor, destination.pasteAt(.{ .row = anchor, .parent = 99 }, .before, &item));
    try std.testing.expectEqual(before_rows, destination.rows.items.len);
    try std.testing.expectEqual(before_next, destination.next_id);
    try std.testing.expectError(error.UnknownAnchor, destination.pasteAt(.{ .row = 99, .parent = null }, .after, &item));
    try destination.markDelete(anchor);
    try std.testing.expectError(error.StaleAnchor, destination.pasteAt(.{ .row = anchor, .parent = null }, .before, &item));
    try std.testing.expectEqual(before_rows, destination.rows.items.len);
    try std.testing.expectEqual(before_next, destination.next_id);

    const parent = try destination.addDirectory(null, "parent", null);
    const child = try destination.addFile(parent, "child", "", null);
    try destination.markDelete(parent);
    const parent_before_rows = destination.rows.items.len;
    const parent_before_next = destination.next_id;
    try std.testing.expectError(error.StaleAnchor, destination.pasteAt(.{ .row = child, .parent = parent }, .before, &item));
    try std.testing.expectEqual(parent_before_rows, destination.rows.items.len);
    try std.testing.expectEqual(parent_before_next, destination.next_id);

    var stale_model = Model.init(std.testing.allocator, .{ .authority = .here, .slot = 53, .generation = 1 });
    defer stale_model.deinit();
    try stale_model.reconcile(.{ .entries = &.{.{ .identity = ref(54, 1), .name = "parent", .revision = "r", .kind = .directory }} });
    const stale_parent = stale_model.rows.items[0].id;
    try stale_model.rename(stale_parent, "draft-parent");
    const stale_child = try stale_model.addFile(stale_parent, "child", "", null);
    try stale_model.reconcile(.{ .entries = &.{} });
    try std.testing.expectError(error.StaleAnchor, stale_model.pasteAt(.{ .row = stale_child, .parent = stale_parent }, .before, &item));
}

test "dirty external mutation is stale and duplicate snapshots are rejected transactionally" {
    var model = Model.init(std.testing.allocator, .{ .authority = .here, .slot = 0, .generation = 1 });
    defer model.deinit();
    try model.reconcile(.{ .entries = &.{.{ .identity = ref(21, 1), .name = "base", .revision = "r1", .kind = .regular, .mode = 0o644 }} });
    const id = model.rows.items[0].id;
    try model.rename(id, "draft");
    try model.reconcile(.{ .entries = &.{.{ .identity = ref(21, 1), .name = "external", .revision = "r2", .kind = .directory, .mode = 0 }} });
    try std.testing.expectEqual(Conflict.stale, model.row(id).?.conflict);
    try std.testing.expectEqualStrings("external", model.row(id).?.current.?.name);
    try std.testing.expectEqualStrings("draft", model.row(id).?.draft.name);

    const before_rows = model.rows.items.len;
    const before_next = model.next_id;
    try std.testing.expectError(error.DuplicateIdentity, model.reconcile(.{ .entries = &.{
        .{ .identity = ref(30, 1), .name = "one", .revision = "a", .kind = .regular },
        .{ .identity = ref(30, 1), .name = "two", .revision = "b", .kind = .regular },
    } }));
    try std.testing.expectEqual(before_rows, model.rows.items.len);
    try std.testing.expectEqual(before_next, model.next_id);
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

test "planner captures before source rename independent of row order" {
    var model = Model.init(std.testing.allocator, .{ .authority = .here, .slot = 70, .generation = 1 });
    defer model.deinit();
    try model.reconcile(.{ .entries = &.{.{ .identity = ref(71, 1), .name = "old", .revision = "r1", .kind = .regular }} });
    const source = model.rows.items[0].id;
    var item = try model.yank(source, .copy);
    defer item.deinit();
    try model.rename(source, "new");
    const pasted = try model.paste(null, &item);
    try std.testing.expectEqualStrings("old", model.row(pasted).?.draft.name);

    var plan = try model.buildPlan();
    defer plan.deinit();
    // The copied source is captured at r1 and must be consumed before the
    // source rename mutates that identity/revision. This ordering comes from
    // Builder's capture phase, not the visible row positions.
    try std.testing.expectEqual(@as(usize, 2), plan.value.operations.len);
    try std.testing.expectEqual(std.meta.activeTag(plan.value.operations[0].operation), .copy);
    try std.testing.expectEqual(std.meta.activeTag(plan.value.operations[1].operation), .rename);
    try std.testing.expectEqual(@as(usize, 1), plan.value.operations[1].depends_on.len);
    try std.testing.expectEqual(@as(usize, 0), plan.value.operations[1].depends_on[0]);
    try std.testing.expectEqualStrings("old", plan.value.operations[0].operation.copy.destination.name.bytes);
    try std.testing.expectEqualStrings("new", plan.value.operations[1].operation.rename.destination.name.bytes);
    try fs.plan.validate(std.testing.allocator, plan.value);
}

test "planner preserves deleted captured source for multiple pastes" {
    var model = Model.init(std.testing.allocator, .{ .authority = .here, .slot = 72, .generation = 1 });
    defer model.deinit();
    try model.reconcile(.{ .entries = &.{.{ .identity = ref(73, 1), .name = "captured", .revision = "r1", .kind = .regular }} });
    const source = model.rows.items[0].id;
    var item = try model.yank(source, .copy);
    defer item.deinit();
    try model.markDelete(source);
    _ = try model.paste(null, &item);
    _ = try model.paste(null, &item);

    var plan = try model.buildPlan();
    defer plan.deinit();
    // Both copies retain the immutable source capture. There is deliberately
    // no remove: deleting the source would invalidate one or both effects.
    try std.testing.expectEqual(@as(usize, 2), plan.value.operations.len);
    for (plan.value.operations) |planned|
        try std.testing.expectEqual(std.meta.activeTag(planned.operation), .copy);
    try std.testing.expectEqual(@as(u32, 72), plan.value.operations[0].operation.copy.source.entry.root.slot);
    try std.testing.expectEqual(@as(u32, 73), plan.value.operations[0].operation.copy.source.entry.ref.slot);
}

test "dependent capture preserves source when destination name is occupied" {
    var model = Model.init(std.testing.allocator, .{ .authority = .here, .slot = 74, .generation = 1 });
    defer model.deinit();
    try model.reconcile(.{ .entries = &.{
        .{ .identity = ref(75, 1), .name = "captured", .revision = "r1", .kind = .regular },
        .{ .identity = ref(76, 1), .name = "other", .revision = "r1", .kind = .regular },
    } });
    const source = model.rows.items[0].id;
    var item = try model.yank(source, .copy);
    defer item.deinit();
    try model.markDelete(source);
    const pasted = try model.paste(null, &item);
    try std.testing.expectEqualStrings("captured", model.row(pasted).?.draft.name);

    var plan = try model.buildPlan();
    defer plan.deinit();
    // The provider will report the occupied destination as a copy conflict;
    // this planner must not turn that conflict into source removal.
    try std.testing.expectEqual(@as(usize, 1), plan.value.operations.len);
    try std.testing.expectEqual(std.meta.activeTag(plan.value.operations[0].operation), .copy);
    try std.testing.expectEqualStrings("captured", plan.value.operations[0].operation.copy.destination.name.bytes);
}

test "foreign source root remains explicit in copied effect" {
    var source = Model.init(std.testing.allocator, .{ .authority = .here, .slot = 11, .generation = 1 });
    defer source.deinit();
    try source.reconcile(.{ .entries = &.{.{ .identity = ref(22, 1), .name = "foreign", .revision = "r", .kind = .regular }} });
    var item = try source.yank(source.rows.items[0].id, .copy);
    defer item.deinit();
    var destination = Model.init(std.testing.allocator, .{ .authority = .here, .slot = 33, .generation = 1 });
    defer destination.deinit();
    _ = try destination.paste(null, &item);
    var plan = try destination.buildPlan();
    defer plan.deinit();
    try std.testing.expectEqual(@as(u32, 11), plan.value.operations[0].operation.copy.source.entry.root.slot);
    try std.testing.expectEqual(@as(u32, 33), plan.value.root.slot);
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
    try std.testing.expectError(error.Stale, model.buildPlan());
    const b = model.rowForIdentity(ref(5, 1)).?;
    try std.testing.expectEqualStrings("b2", model.row(b).?.draft.name);
}

test "pending subtree paste survives deletion, preserves symlink and planned parent" {
    var model = Model.init(std.testing.allocator, .{ .authority = .here, .slot = 0, .generation = 1 });
    defer model.deinit();
    const directory = try model.addDirectory(null, "tree", @as(?u32, 0));
    _ = try model.addSymlink(directory, "link", "target");
    const nested = try model.addDirectory(directory, "nested", null);
    _ = try model.addFile(nested, "leaf", "contents", null);
    var item = try model.yank(directory, .copy);
    defer item.deinit();
    try model.markDelete(directory);
    _ = try model.paste(null, &item);
    var plan = try model.buildPlan();
    defer plan.deinit();
    try std.testing.expectEqual(@as(usize, 4), plan.value.operations.len);
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
    try model.reconcile(.{ .entries = &.{} });
    try model.reconcile(.{ .entries = &.{.{ .identity = ref(6, 2), .name = "line\n-[]'", .revision = "r-new", .kind = .regular }} });
    try std.testing.expect(model.rowForIdentity(ref(6, 1)) == null);
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

    const directory = try model.addDirectory(null, "tree", null);
    var valid_tree = try model.yank(directory, .copy);
    defer valid_tree.deinit();
    const tree_payload = valid_tree.value.representations[0].payload;
    const before_rows = model.rows.items.len;
    const before_next = model.next_id;
    const malformed_payload = try std.testing.allocator.alloc(u8, tree_payload.len + 1);
    defer std.testing.allocator.free(malformed_payload);
    @memcpy(malformed_payload[0..tree_payload.len], tree_payload);
    malformed_payload[tree_payload.len] = 0xff;
    const malformed_reps = [_]transfer.Representation{.{ .media_type = tree_media, .schema = tree_schema, .payload = malformed_payload }};
    var malformed = try transfer.OwnedItem.init(std.testing.allocator, .{ .intent = .copy, .suggested_name = "tree", .representations = &malformed_reps });
    defer malformed.deinit();
    try std.testing.expectError(error.InvalidTransfer, model.paste(null, &malformed));
    try std.testing.expectEqual(before_rows, model.rows.items.len);
    try std.testing.expectEqual(before_next, model.next_id);

    const invalid_mode_payload = try std.testing.allocator.dupe(u8, tree_payload);
    defer std.testing.allocator.free(invalid_mode_payload);
    invalid_mode_payload[tree_magic.len + 9] = 2;
    const invalid_mode_reps = [_]transfer.Representation{.{ .media_type = tree_media, .schema = tree_schema, .payload = invalid_mode_payload }};
    var invalid_mode = try transfer.OwnedItem.init(std.testing.allocator, .{ .intent = .copy, .suggested_name = "tree", .representations = &invalid_mode_reps });
    defer invalid_mode.deinit();
    try std.testing.expectError(error.InvalidTransfer, model.paste(null, &invalid_mode));
    try std.testing.expectEqual(before_rows, model.rows.items.len);
    try std.testing.expectEqual(before_next, model.next_id);

    var forest: std.ArrayList(u8) = .empty;
    defer forest.deinit(std.testing.allocator);
    try forest.appendSlice(std.testing.allocator, tree_magic);
    try putU32(std.testing.allocator, &forest, 2);
    try putU32(std.testing.allocator, &forest, no_parent);
    try forest.append(std.testing.allocator, @intFromEnum(contract.Kind.directory));
    try forest.append(std.testing.allocator, 0);
    try putU32(std.testing.allocator, &forest, 0);
    try putBytes(std.testing.allocator, &forest, "root", max_transfer_name);
    try putBytes(std.testing.allocator, &forest, &.{}, max_transfer_payload);
    try putBytes(std.testing.allocator, &forest, &.{}, max_transfer_payload);
    try putU32(std.testing.allocator, &forest, no_parent);
    try forest.append(std.testing.allocator, @intFromEnum(contract.Kind.regular));
    try forest.append(std.testing.allocator, 0);
    try putU32(std.testing.allocator, &forest, 0);
    try putBytes(std.testing.allocator, &forest, "child", max_transfer_name);
    try putBytes(std.testing.allocator, &forest, &.{}, max_transfer_payload);
    try putBytes(std.testing.allocator, &forest, &.{}, max_transfer_payload);
    const forest_payload = try forest.toOwnedSlice(std.testing.allocator);
    defer std.testing.allocator.free(forest_payload);
    const forest_reps = [_]transfer.Representation{.{ .media_type = tree_media, .schema = tree_schema, .payload = forest_payload }};
    var forest_item = try transfer.OwnedItem.init(std.testing.allocator, .{ .intent = .copy, .suggested_name = "root", .representations = &forest_reps });
    defer forest_item.deinit();
    try std.testing.expectError(error.InvalidTransfer, model.paste(null, &forest_item));

    try model.reconcile(.{ .entries = &.{.{ .identity = ref(40, 1), .name = "entry", .revision = "r", .kind = .regular }} });
    var valid_entry = try model.yank(model.rowForIdentity(ref(40, 1)).?, .copy);
    defer valid_entry.deinit();
    const entry_payload = valid_entry.value.representations[0].payload;
    const invalid_generation_payload = try std.testing.allocator.dupe(u8, entry_payload);
    defer std.testing.allocator.free(invalid_generation_payload);
    std.mem.writeInt(u32, invalid_generation_payload[entry_magic.len + 8 ..][0..4], 0, .little);
    const invalid_generation_reps = [_]transfer.Representation{.{ .media_type = entry_media, .schema = entry_schema, .payload = invalid_generation_payload }};
    var invalid_generation = try transfer.OwnedItem.init(std.testing.allocator, .{ .intent = .copy, .suggested_name = "entry", .representations = &invalid_generation_reps });
    defer invalid_generation.deinit();
    try std.testing.expectError(error.InvalidTransfer, model.paste(null, &invalid_generation));
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
