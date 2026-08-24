//! Deterministic in-memory implementation of `weft_fs.service.Provider`.
//!
//! This is a real build module used for contract/convergence tests. It models
//! external mutation explicitly and never imports host, platform, or dired
//! code, so portable semantics cannot quietly depend on Linux behavior.

const std = @import("std");
const fs = @import("weft_fs");

const contract = fs.contract;

pub const Fake = struct {
    gpa: std.mem.Allocator,
    records: std.ArrayList(Record) = .empty,
    root_revision: u64 = 1,

    const Record = struct {
        parent: ?u32,
        name: []u8,
        kind: contract.Kind,
        contents: []u8 = &.{},
        link_target: []u8 = &.{},
        mode: u32 = 0o644,
        revision: u64 = 1,
        generation: u32 = 1,
        alive: bool = true,
    };

    pub fn init(gpa: std.mem.Allocator) Fake {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Fake) void {
        for (self.records.items) |record| {
            self.gpa.free(record.name);
            self.gpa.free(record.contents);
            self.gpa.free(record.link_target);
        }
        self.records.deinit(self.gpa);
    }

    pub fn provider(self: *Fake) fs.service.Provider {
        return .init(self);
    }

    pub fn root() contract.Root {
        return .{ .authority = .here, .slot = 0, .generation = 1 };
    }

    /// Seed fixtures without pretending the creation came through the
    /// provider. Tests use this to model state that predates a draft.
    pub fn seed(self: *Fake, parent: contract.NodeRef, name: []const u8, kind: contract.Kind, payload: []const u8) !contract.EntryRef {
        const parent_index = try self.directoryIndex(parent, null);
        if (self.findChild(parent_index, name) != null) return error.AlreadyExists;
        const index = try self.appendRecord(
            parent_index,
            name,
            kind,
            if (kind == .regular) payload else &.{},
            if (kind == .symlink) payload else &.{},
        );
        self.bump(index);
        return self.refFor(index);
    }

    /// A mutation outside weft's plan executor. Existing observations become
    /// stale exactly as they would after another process changes the tree.
    pub fn deleteExternally(self: *Fake, entry: contract.EntryRef) contract.Error!void {
        const index = try self.entryIndex(entry);
        self.removeTree(index);
        self.root_revision +%= 1;
    }

    pub fn capabilities(self: *Fake, root_ref: contract.Root) contract.Error!contract.Capabilities {
        _ = self;
        try validateRoot(root_ref);
        return .{
            .exclusive_create = true,
            .symlink = true,
            .posix_mode = true,
            .guard_strength = .atomic,
        };
    }

    pub fn observe(self: *Fake, gpa: std.mem.Allocator, root_ref: contract.Root, node: contract.NodeRef) contract.Error!contract.OwnedObservation {
        try validateRoot(root_ref);
        var owned = contract.OwnedObservation.init(gpa);
        errdefer owned.deinit();
        owned.value = try self.copyObservation(owned.allocator(), node);
        return owned;
    }

    pub fn list(self: *Fake, gpa: std.mem.Allocator, root_ref: contract.Root, directory: contract.NodeRef) contract.Error!contract.OwnedListing {
        try validateRoot(root_ref);
        const parent_index = try self.directoryIndex(directory, null);
        var owned = contract.OwnedListing.init(gpa);
        errdefer owned.deinit();
        const arena = owned.allocator();

        var count: usize = 0;
        for (self.records.items) |record|
            if (record.alive and record.parent == parent_index) {
                count += 1;
            };

        const entries = try arena.alloc(contract.DirEntry, count);
        var next: usize = 0;
        for (self.records.items, 0..) |record, index| {
            if (!record.alive or record.parent != parent_index) continue;
            const name = try arena.dupe(u8, record.name);
            entries[next] = .{
                .name = contract.Name.init(name) catch unreachable,
                .observation = try self.copyObservation(arena, .{ .entry = self.refFor(index) }),
            };
            next += 1;
        }

        owned.value = .{
            .directory = try self.copyObservation(arena, directory),
            .revision = .{ .token = try revisionToken(arena, try self.nodeRevision(directory)) },
            .entries = entries,
        };
        return owned;
    }

    pub fn read(self: *Fake, gpa: std.mem.Allocator, root_ref: contract.Root, request: contract.ReadRequest) contract.Error!contract.OwnedReadResult {
        try validateRoot(root_ref);
        const source = switch (request.source) {
            .entry => |entry| entry,
            .lease => return error.Unsupported,
        };
        const index = try self.entryIndex(source.ref);
        const record = &self.records.items[index];
        if (!revisionMatches(record.revision, source.revision)) return error.Stale;
        if (record.kind != .regular) return error.Unsupported;
        if (request.offset > record.contents.len) return error.Stale;
        const start: usize = @intCast(request.offset);
        const available = record.contents.len - start;
        const length = @min(available, request.limit orelse available);

        var owned = contract.OwnedReadResult.init(gpa);
        errdefer owned.deinit();
        const arena = owned.allocator();
        owned.value = .{
            .observation = try self.copyObservation(arena, .{ .entry = source.ref }),
            .bytes = try arena.dupe(u8, record.contents[start..][0..length]),
            .eof = length == available,
        };
        return owned;
    }

    pub fn apply(self: *Fake, gpa: std.mem.Allocator, effect_plan: contract.Plan) contract.Error!contract.OwnedApplyReport {
        try validateRoot(effect_plan.root);
        var owned = contract.OwnedApplyReport.init(gpa);
        errdefer owned.deinit();
        const arena = owned.allocator();
        const reports = try arena.alloc(contract.ReportEntry, effect_plan.operations.len);
        const outputs = try arena.alloc(?contract.EntryRef, effect_plan.operations.len);
        @memset(outputs, null);

        const base_matches = effect_plan.base_revision.len == 0 or revisionMatches(self.root_revision, .{ .token = effect_plan.base_revision });
        for (effect_plan.operations, 0..) |planned, index| {
            reports[index].id = planned.id;
            if (!base_matches) {
                reports[index].outcome = .stale;
                continue;
            }
            var dependency_failed = false;
            for (planned.depends_on) |dependency| {
                const tag = std.meta.activeTag(reports[dependency].outcome);
                if (tag != .applied and tag != .already_satisfied) dependency_failed = true;
            }
            if (dependency_failed) {
                reports[index].outcome = .{ .conflict = "dependency did not apply" };
                continue;
            }
            reports[index].outcome = self.applyOne(planned.operation, outputs, index) catch |err| switch (err) {
                error.NotFound, error.Stale => .stale,
                error.Unsupported => .unsupported,
                error.AlreadyExists => .{ .conflict = "destination exists" },
                error.NotDirectory => .{ .conflict = "parent is not a directory" },
                else => return err,
            };
        }
        owned.value = .{ .entries = reports };
        return owned;
    }

    pub fn watch(self: *Fake, root_ref: contract.Root, directory: contract.NodeRef, recursive: bool) contract.Error!contract.WatchRef {
        _ = self;
        _ = root_ref;
        _ = directory;
        _ = recursive;
        return error.Unsupported;
    }

    pub fn pollInvalidation(self: *Fake, watch_ref: contract.WatchRef) contract.Error!?contract.Invalidation {
        _ = self;
        _ = watch_ref;
        return error.Unsupported;
    }

    pub fn closeWatch(self: *Fake, watch_ref: contract.WatchRef) void {
        _ = self;
        _ = watch_ref;
    }

    fn applyOne(self: *Fake, operation: contract.Operation, outputs: []?contract.EntryRef, operation_index: usize) contract.Error!contract.Outcome {
        return switch (operation) {
            .create_file => |operation_value| self.create(outputs, operation_index, operation_value.destination, operation_value.expected, .regular, operation_value.contents, operation_value.mode orelse 0o644),
            .create_directory => |operation_value| self.create(outputs, operation_index, operation_value.destination, operation_value.expected, .directory, &.{}, operation_value.mode orelse 0o755),
            .create_symlink => |operation_value| self.create(outputs, operation_index, operation_value.destination, operation_value.expected, .symlink, operation_value.target, 0o777),
            .copy => |operation_value| self.copy(outputs, operation_index, operation_value),
            .rename => |operation_value| self.rename(outputs, operation_value),
            .remove => |operation_value| self.remove(operation_value),
            .set_permissions => |operation_value| self.setPermissions(operation_value),
        };
    }

    fn create(
        self: *Fake,
        outputs: []?contract.EntryRef,
        operation_index: usize,
        destination: contract.Slot,
        expected: contract.Expected,
        kind: contract.Kind,
        payload: []const u8,
        mode: u32,
    ) contract.Error!contract.Outcome {
        const parent = try self.parentIndex(destination.parent, outputs);
        if (!try self.prepareDestination(parent, destination.name.bytes, expected)) return .{ .conflict = "destination changed" };
        const index = try self.appendRecord(parent, destination.name.bytes, kind, if (kind == .regular) payload else &.{}, if (kind == .symlink) payload else &.{});
        self.records.items[index].mode = mode;
        self.bump(index);
        outputs[operation_index] = self.refFor(index);
        return .{ .applied = null };
    }

    fn copy(self: *Fake, outputs: []?contract.EntryRef, operation_index: usize, operation: anytype) contract.Error!contract.Outcome {
        const source = switch (operation.source) {
            .entry => |entry| entry,
            .lease => return .unsupported,
        };
        const source_index = self.entryIndex(source.ref) catch return .stale;
        if (!revisionMatches(self.records.items[source_index].revision, source.revision)) return .stale;
        const parent = try self.parentIndex(operation.destination.parent, outputs);
        if (self.records.items[source_index].kind == .directory and parent != null and self.isWithin(parent.?, source_index))
            return .{ .conflict = "cannot copy a directory inside itself" };
        if (!try self.prepareDestination(parent, operation.destination.name.bytes, operation.expected)) return .{ .conflict = "destination changed" };
        const new_index = try self.copyTree(source_index, parent, operation.destination.name.bytes);
        self.bump(new_index);
        outputs[operation_index] = self.refFor(new_index);
        return .{ .applied = null };
    }

    fn rename(self: *Fake, outputs: []?contract.EntryRef, operation: anytype) contract.Error!contract.Outcome {
        const source_index = self.entryIndex(operation.source) catch return .stale;
        const source = &self.records.items[source_index];
        if (!revisionMatches(source.revision, operation.source_revision)) return .stale;
        const parent = try self.parentIndex(operation.destination.parent, outputs);
        if (source.parent == parent and std.mem.eql(u8, source.name, operation.destination.name.bytes)) return .already_satisfied;
        if (source.kind == .directory and parent != null and self.isWithin(parent.?, source_index))
            return .{ .conflict = "cannot move a directory inside itself" };
        if (self.findChild(parent, operation.destination.name.bytes)) |existing|
            if (self.isWithin(source_index, existing)) return .{ .conflict = "cannot replace an ancestor of the source" };
        if (!try self.prepareDestination(parent, operation.destination.name.bytes, operation.expected)) return .{ .conflict = "destination changed" };
        const name = try self.gpa.dupe(u8, operation.destination.name.bytes);
        self.gpa.free(source.name);
        source.name = name;
        source.parent = parent;
        self.bump(source_index);
        return .{ .applied = null };
    }

    fn remove(self: *Fake, operation: anytype) contract.Error!contract.Outcome {
        const index = self.entryIndex(operation.source) catch return .stale;
        if (!revisionMatches(self.records.items[index].revision, operation.revision)) return .stale;
        self.removeTree(index);
        self.root_revision +%= 1;
        return .{ .applied = null };
    }

    fn setPermissions(self: *Fake, operation: anytype) contract.Error!contract.Outcome {
        const index = self.entryIndex(operation.source) catch return .stale;
        const record = &self.records.items[index];
        if (!revisionMatches(record.revision, operation.revision)) return .stale;
        record.mode = operation.mode;
        self.bump(index);
        return .{ .applied = null };
    }

    fn prepareDestination(self: *Fake, parent: ?u32, name: []const u8, expected: contract.Expected) contract.Error!bool {
        const existing = self.findChild(parent, name);
        switch (expected) {
            .absent => return existing == null,
            .anything => return existing == null,
            .entry => |wanted| {
                const index = existing orelse return false;
                const record = &self.records.items[index];
                if (wanted.ref.authority != .here or wanted.ref.slot != index or wanted.ref.generation != record.generation or
                    !revisionMatches(record.revision, wanted.revision)) return false;
                self.removeTree(index);
                return true;
            },
        }
    }

    fn appendRecord(self: *Fake, parent: ?u32, name: []const u8, kind: contract.Kind, contents: []const u8, link_target: []const u8) !u32 {
        const owned_name = try self.gpa.dupe(u8, name);
        errdefer self.gpa.free(owned_name);
        const owned_contents = try self.gpa.dupe(u8, contents);
        errdefer self.gpa.free(owned_contents);
        const owned_link = try self.gpa.dupe(u8, link_target);
        errdefer self.gpa.free(owned_link);
        try self.records.append(self.gpa, .{
            .parent = parent,
            .name = owned_name,
            .kind = kind,
            .contents = owned_contents,
            .link_target = owned_link,
            .mode = if (kind == .directory) 0o755 else 0o644,
        });
        return @intCast(self.records.items.len - 1);
    }

    fn copyTree(self: *Fake, source_index: u32, parent: ?u32, name: []const u8) !u32 {
        const source = self.records.items[source_index];
        const copied = try self.appendRecord(parent, name, source.kind, source.contents, source.link_target);
        self.records.items[copied].mode = source.mode;
        var child_index: u32 = 0;
        while (child_index < self.records.items.len) : (child_index += 1) {
            const child = self.records.items[child_index];
            if (!child.alive or child.parent != source_index) continue;
            _ = try self.copyTree(child_index, copied, child.name);
        }
        return copied;
    }

    fn copyObservation(self: *Fake, arena: std.mem.Allocator, node: contract.NodeRef) contract.Error!contract.Observation {
        return switch (node) {
            .root => .{
                .node = .root,
                .revision = .{ .token = try revisionToken(arena, self.root_revision) },
                .kind = .directory,
                .metadata = .{ .mode = 0o755 },
            },
            .entry => |entry| blk: {
                const index = try self.entryIndex(entry);
                const record = self.records.items[index];
                break :blk .{
                    .node = .{ .entry = entry },
                    .revision = .{ .token = try revisionToken(arena, record.revision) },
                    .kind = record.kind,
                    .metadata = .{
                        .mode = record.mode,
                        .size = if (record.kind == .regular) record.contents.len else null,
                        .link_target = if (record.kind == .symlink) try arena.dupe(u8, record.link_target) else null,
                    },
                };
            },
        };
    }

    fn nodeRevision(self: *Fake, node: contract.NodeRef) contract.Error!u64 {
        return switch (node) {
            .root => self.root_revision,
            .entry => |entry| self.records.items[try self.entryIndex(entry)].revision,
        };
    }

    fn directoryIndex(self: *Fake, node: contract.NodeRef, outputs: ?[]?contract.EntryRef) contract.Error!?u32 {
        _ = outputs;
        return switch (node) {
            .root => null,
            .entry => |entry| blk: {
                const index = try self.entryIndex(entry);
                if (self.records.items[index].kind != .directory) return error.NotDirectory;
                break :blk index;
            },
        };
    }

    fn parentIndex(self: *Fake, parent: contract.ParentRef, outputs: []?contract.EntryRef) contract.Error!?u32 {
        return switch (parent) {
            .root => null,
            .entry => |entry| try self.directoryIndex(.{ .entry = entry }, null),
            .planned => |index| {
                if (index >= outputs.len) return error.Stale;
                const entry = outputs[index] orelse return error.Stale;
                return try self.directoryIndex(.{ .entry = entry }, null);
            },
        };
    }

    fn entryIndex(self: *Fake, entry: contract.EntryRef) contract.Error!u32 {
        if (entry.authority != .here or entry.slot >= self.records.items.len) return error.Stale;
        const record = self.records.items[entry.slot];
        if (record.generation != entry.generation) return error.Stale;
        if (!record.alive) return error.NotFound;
        return entry.slot;
    }

    fn findChild(self: *Fake, parent: ?u32, name: []const u8) ?u32 {
        for (self.records.items, 0..) |record, index|
            if (record.alive and record.parent == parent and std.mem.eql(u8, record.name, name)) return @intCast(index);
        return null;
    }

    fn refFor(self: *Fake, index: usize) contract.EntryRef {
        return .{ .authority = .here, .slot = @intCast(index), .generation = self.records.items[index].generation };
    }

    fn bump(self: *Fake, index: u32) void {
        self.records.items[index].revision +%= 1;
        self.root_revision +%= 1;
    }

    fn removeTree(self: *Fake, index: u32) void {
        for (self.records.items, 0..) |record, child|
            if (record.alive and record.parent == index) self.removeTree(@intCast(child));
        self.records.items[index].alive = false;
        self.records.items[index].revision +%= 1;
    }

    fn isWithin(self: *Fake, candidate: u32, ancestor: u32) bool {
        var cursor: ?u32 = candidate;
        while (cursor) |index| {
            if (index == ancestor) return true;
            cursor = self.records.items[index].parent;
        }
        return false;
    }
};

fn validateRoot(root_ref: contract.Root) contract.Error!void {
    if (root_ref.authority != .here or root_ref.slot != 0 or root_ref.generation != 1) return error.Stale;
}

fn revisionToken(gpa: std.mem.Allocator, revision: u64) std.mem.Allocator.Error![]u8 {
    const token = try gpa.alloc(u8, @sizeOf(u64));
    std.mem.writeInt(u64, token[0..8], revision, .little);
    return token;
}

fn revisionMatches(actual: u64, expected: contract.Revision) bool {
    return expected.token.len == @sizeOf(u64) and std.mem.readInt(u64, expected.token[0..8], .little) == actual;
}

fn opId(byte: u8) contract.OperationId {
    return [_]u8{byte} ** 16;
}

test "fake provider applies ordered plans with planned parents and raw names" {
    var fake = Fake.init(std.testing.allocator);
    defer fake.deinit();
    const provider = fake.provider();

    var before = try provider.list(std.testing.allocator, Fake.root(), .root);
    defer before.deinit();
    const unusual = try contract.Name.init("line\n-[]'");
    const operations = [_]contract.Planned{
        .{
            .id = opId(1),
            .operation = .{ .create_directory = .{ .destination = .{ .parent = .root, .name = try .init("tree") } } },
        },
        .{
            .id = opId(2),
            .operation = .{ .create_file = .{ .destination = .{ .parent = .{ .planned = 0 }, .name = unusual }, .contents = "payload" } },
        },
    };
    const effect_plan: contract.Plan = .{
        .root = Fake.root(),
        .base_revision = before.value.revision.token,
        .operations = &operations,
    };
    var report = try provider.apply(std.testing.allocator, effect_plan);
    defer report.deinit();
    try std.testing.expectEqual(std.meta.Tag(contract.Outcome).applied, std.meta.activeTag(report.value.entries[0].outcome));
    try std.testing.expectEqual(std.meta.Tag(contract.Outcome).applied, std.meta.activeTag(report.value.entries[1].outcome));

    var root_listing = try provider.list(std.testing.allocator, Fake.root(), .root);
    defer root_listing.deinit();
    try std.testing.expectEqual(@as(usize, 1), root_listing.value.entries.len);
    var tree_listing = try provider.list(std.testing.allocator, Fake.root(), root_listing.value.entries[0].observation.node);
    defer tree_listing.deinit();
    try std.testing.expectEqualStrings(unusual.bytes, tree_listing.value.entries[0].name.bytes);
}

test "fake provider reports stale observations after external deletion" {
    var fake = Fake.init(std.testing.allocator);
    defer fake.deinit();
    const entry = try fake.seed(.root, "gone", .regular, "old");
    const provider = fake.provider();
    var observed = try provider.observe(std.testing.allocator, Fake.root(), .{ .entry = entry });
    defer observed.deinit();
    try fake.deleteExternally(entry);

    const operations = [_]contract.Planned{.{
        .id = opId(3),
        .operation = .{ .remove = .{ .source = entry, .revision = observed.value.revision } },
    }};
    const effect_plan: contract.Plan = .{ .root = Fake.root(), .base_revision = &.{}, .operations = &operations };
    var report = try provider.apply(std.testing.allocator, effect_plan);
    defer report.deinit();
    try std.testing.expectEqual(std.meta.Tag(contract.Outcome).stale, std.meta.activeTag(report.value.entries[0].outcome));
}

test "fake provider copies symlinks as entries without following them" {
    var fake = Fake.init(std.testing.allocator);
    defer fake.deinit();
    const link = try fake.seed(.root, "link", .symlink, "target/elsewhere");
    const provider = fake.provider();
    var observed = try provider.observe(std.testing.allocator, Fake.root(), .{ .entry = link });
    defer observed.deinit();
    const operations = [_]contract.Planned{.{
        .id = opId(4),
        .operation = .{ .copy = .{
            .source = .{ .entry = .{ .ref = link, .revision = observed.value.revision } },
            .destination = .{ .parent = .root, .name = try .init("link-copy") },
        } },
    }};
    var report = try provider.apply(std.testing.allocator, .{ .root = Fake.root(), .base_revision = &.{}, .operations = &operations });
    defer report.deinit();
    var listing = try provider.list(std.testing.allocator, Fake.root(), .root);
    defer listing.deinit();
    try std.testing.expectEqual(@as(usize, 2), listing.value.entries.len);
    try std.testing.expectEqual(contract.Kind.symlink, listing.value.entries[1].observation.kind);
    try std.testing.expectEqualStrings("target/elsewhere", listing.value.entries[1].observation.metadata.link_target.?);
}

test "fake provider keeps dependency failures inside the apply report" {
    var fake = Fake.init(std.testing.allocator);
    defer fake.deinit();
    _ = try fake.seed(.root, "occupied", .regular, "old");
    const provider = fake.provider();
    const operations = [_]contract.Planned{
        .{
            .id = opId(5),
            .operation = .{ .create_directory = .{ .destination = .{ .parent = .root, .name = try .init("occupied") } } },
        },
        .{
            .id = opId(6),
            .operation = .{ .create_file = .{ .destination = .{ .parent = .{ .planned = 0 }, .name = try .init("child") }, .contents = "new" } },
            .depends_on = &.{0},
        },
    };
    var report = try provider.apply(std.testing.allocator, .{ .root = Fake.root(), .base_revision = &.{}, .operations = &operations });
    defer report.deinit();
    try std.testing.expectEqual(std.meta.Tag(contract.Outcome).conflict, std.meta.activeTag(report.value.entries[0].outcome));
    try std.testing.expectEqual(std.meta.Tag(contract.Outcome).conflict, std.meta.activeTag(report.value.entries[1].outcome));
}

test "fake provider refuses recursive copy into the source subtree" {
    var fake = Fake.init(std.testing.allocator);
    defer fake.deinit();
    const directory = try fake.seed(.root, "tree", .directory, &.{});
    const provider = fake.provider();
    var observed = try provider.observe(std.testing.allocator, Fake.root(), .{ .entry = directory });
    defer observed.deinit();
    const operations = [_]contract.Planned{.{
        .id = opId(7),
        .operation = .{ .copy = .{
            .source = .{ .entry = .{ .ref = directory, .revision = observed.value.revision } },
            .destination = .{ .parent = .{ .entry = directory }, .name = try .init("again") },
        } },
    }};
    var report = try provider.apply(std.testing.allocator, .{ .root = Fake.root(), .base_revision = &.{}, .operations = &operations });
    defer report.deinit();
    try std.testing.expectEqual(std.meta.Tag(contract.Outcome).conflict, std.meta.activeTag(report.value.entries[0].outcome));
}

test {
    std.testing.refAllDecls(@This());
}
