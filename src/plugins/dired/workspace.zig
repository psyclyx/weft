//! Pure directory-workspace reconciliation.
//!
//! A workspace turns one provider listing into an independent dired draft.
//! It does not authorize targets, call a filesystem, publish views, or know
//! which input plugin will edit the resulting fields. Native and sandboxed
//! adapters use this same value boundary, so filesystem observations cannot
//! acquire different meaning depending on where the plugin is hosted.

const std = @import("std");
const semantic = @import("weft_semantic");
const fs = @import("weft_fs");
const model = @import("weft_dired_model");

const contract = fs.contract;

pub const Error = error{
    InvalidTarget,
    InvalidListing,
} || std.mem.Allocator.Error;

/// Read the descriptive directory value from a semantic target. This is not
/// authorization: an adapter must still present the exact target revision to
/// its filesystem service before the returned identifiers can do anything.
pub fn directoryFromDescriptor(descriptor: semantic.target.Descriptor) Error!fs.target.Directory {
    if (descriptor.kind != .directory) return error.InvalidTarget;
    return (fs.target.find(descriptor.facts) catch return error.InvalidTarget) orelse error.InvalidTarget;
}

/// Build the next draft as one value transaction. `previous == null` is an
/// explicit revert/load; otherwise dirty rows reconcile by opaque identity
/// and retain their base observation for conflict detection.
pub fn reconcileListing(
    gpa: std.mem.Allocator,
    directory: fs.target.Directory,
    previous: ?*const model.Model,
    listing: contract.Listing,
) Error!model.Model {
    try validateListing(directory, listing);
    const entries = try gpa.alloc(model.SnapshotEntry, listing.entries.len);
    defer gpa.free(entries);
    for (listing.entries, entries) |entry, *snapshot| {
        const identity = switch (entry.observation.node) {
            .root => return error.InvalidListing,
            .entry => |ref| ref,
        };
        snapshot.* = .{
            .identity = identity,
            .name = entry.name.bytes,
            .revision = entry.observation.revision.token,
            .kind = entry.observation.kind,
            .mode = entry.observation.metadata.mode,
            .link_target = entry.observation.metadata.link_target orelse &.{},
        };
    }
    var next = if (previous) |draft|
        try draft.duplicate()
    else
        model.Model.initAt(gpa, directory.root, directory.node);
    errdefer next.deinit();
    next.reconcile(.{ .entries = entries, .revision = listing.revision.token }) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidListing,
    };
    return next;
}

/// Return the guarded identity of an observed direct child directory. The
/// adapter may feed this value to its generic child-target publication port;
/// names remain provider-owned and are deliberately absent here.
pub fn observedChild(parent: fs.target.Directory, row: model.Row) ?struct {
    entry: contract.EntryRef,
    revision: contract.Revision,
} {
    if (row.conflict == .stale or row.pending == .deleted or row.draft.kind != .directory) return null;
    const observation = row.current orelse return null;
    if (observation.kind != .directory or observation.identity.authority != parent.root.authority) return null;
    return .{
        .entry = observation.identity,
        .revision = .{ .token = observation.revision },
    };
}

pub fn validateListing(directory: fs.target.Directory, listing: contract.Listing) Error!void {
    if (!std.meta.eql(listing.directory.node, directory.node) or listing.directory.kind != .directory)
        return error.InvalidListing;
    for (listing.entries) |entry| {
        _ = contract.Name.init(entry.name.bytes) catch return error.InvalidListing;
        const identity = switch (entry.observation.node) {
            .root => return error.InvalidListing,
            .entry => |ref| ref,
        };
        if (identity.generation == 0 or identity.authority != directory.root.authority)
            return error.InvalidListing;
    }
}

pub fn sameDirectory(left: fs.target.Directory, right: fs.target.Directory) bool {
    return left.root.eql(right.root) and std.meta.eql(left.node, right.node);
}

fn testEntry(slot: u32) contract.EntryRef {
    return .{ .authority = .here, .slot = slot, .generation = 1 };
}

test "listing reconciliation is identical for native and sandbox adapters" {
    const root: contract.Root = .{ .authority = .here, .slot = 9, .generation = 1 };
    const directory: fs.target.Directory = .{ .root = root };
    const observation: contract.Observation = .{
        .node = .root,
        .revision = .{ .token = "directory-r1" },
        .kind = .directory,
    };
    var draft = try reconcileListing(std.testing.allocator, directory, null, .{
        .directory = observation,
        .revision = observation.revision,
        .entries = &.{.{
            .name = try contract.Name.init("child\n\xff"),
            .observation = .{
                .node = .{ .entry = testEntry(4) },
                .revision = .{ .token = "child-r1" },
                .kind = .directory,
            },
        }},
    });
    defer draft.deinit();
    try std.testing.expectEqualStrings("child\n\xff", draft.rows.items[0].draft.name);
    const child = observedChild(directory, draft.rows.items[0]).?;
    try std.testing.expectEqual(testEntry(4), child.entry);
    try std.testing.expectEqualStrings("child-r1", child.revision.token);

    try draft.rename(draft.rows.items[0].id, "pending");
    var reconciled = try reconcileListing(std.testing.allocator, directory, &draft, .{
        .directory = observation,
        .revision = .{ .token = "directory-r2" },
        .entries = &.{},
    });
    defer reconciled.deinit();
    try std.testing.expectEqual(model.Conflict.stale, reconciled.rows.items[0].conflict);
    try std.testing.expectEqualStrings("pending", reconciled.rows.items[0].draft.name);
}

test "listing rejects retargeted directories and foreign entry authorities" {
    const directory: fs.target.Directory = .{
        .root = .{ .authority = .here, .slot = 9, .generation = 1 },
    };
    try std.testing.expectError(error.InvalidListing, validateListing(directory, .{
        .directory = .{
            .node = .{ .entry = testEntry(2) },
            .revision = .{ .token = "r" },
            .kind = .directory,
        },
        .revision = .{ .token = "r" },
        .entries = &.{},
    }));
    try std.testing.expectError(error.InvalidListing, validateListing(directory, .{
        .directory = .{ .node = .root, .revision = .{ .token = "r" }, .kind = .directory },
        .revision = .{ .token = "r" },
        .entries = &.{.{
            .name = try contract.Name.init("foreign"),
            .observation = .{
                .node = .{ .entry = .{ .authority = @enumFromInt(2), .slot = 1, .generation = 1 } },
                .revision = .{ .token = "r" },
                .kind = .regular,
            },
        }},
    }));
}
