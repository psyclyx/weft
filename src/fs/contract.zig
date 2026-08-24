//! Platform-neutral filesystem service values.
//!
//! Names are raw components and identities are opaque handles. Linux and
//! Darwin providers translate these semantic operations at the outer edge.

const std = @import("std");
const kernel = @import("weft_kernel");

pub const RootTag = struct {};
pub const EntryTag = struct {};
pub const LeaseTag = struct {};
pub const WatchTag = struct {};

pub const Root = kernel.handle.Handle(RootTag);
pub const EntryRef = kernel.handle.Handle(EntryTag);
pub const LeaseRef = kernel.handle.Handle(LeaseTag);
pub const WatchRef = kernel.handle.Handle(WatchTag);

pub const NameError = error{ Empty, Reserved, ContainsSlash, ContainsNul };

pub const Name = struct {
    bytes: []const u8,

    pub fn init(bytes: []const u8) NameError!Name {
        if (bytes.len == 0) return error.Empty;
        if (std.mem.eql(u8, bytes, ".") or std.mem.eql(u8, bytes, "..")) return error.Reserved;
        if (std.mem.indexOfScalar(u8, bytes, '/') != null) return error.ContainsSlash;
        if (std.mem.indexOfScalar(u8, bytes, 0) != null) return error.ContainsNul;
        return .{ .bytes = bytes };
    }
};

pub const Slot = struct {
    parent: EntryRef,
    name: Name,
};

pub const Kind = enum {
    regular,
    directory,
    symlink,
    other,
};

pub const Revision = struct {
    /// Provider-defined comparison token. Consumers compare bytes and never
    /// infer timestamps, hashes, inodes, or generations from it.
    token: []const u8,
};

pub const Metadata = struct {
    mode: ?u32 = null,
    size: ?u64 = null,
    modified_ns: ?i128 = null,
    link_target: ?[]const u8 = null,
};

pub const Observation = struct {
    entry: EntryRef,
    revision: Revision,
    kind: Kind,
    metadata: Metadata = .{},
};

pub const DirEntry = struct {
    name: Name,
    observation: Observation,
};

pub const GuardStrength = enum {
    /// Provider can detect changes before starting but cannot couple the check
    /// atomically to the namespace mutation.
    preflight,
    /// Provider captures/quarantines and verifies before destructive effects.
    claimed,
    /// Provider supplies an atomic conditional primitive for this operation.
    atomic,
};

pub const WatchPrecision = enum { none, invalidation, recursive_invalidation };

pub const Capabilities = struct {
    exclusive_create: bool = false,
    atomic_exchange: bool = false,
    durable_file_lease: bool = false,
    tree_snapshot: bool = false,
    symlink: bool = false,
    posix_mode: bool = false,
    quarantine: bool = false,
    clone_acceleration: bool = false,
    guard_strength: GuardStrength = .preflight,
    watch: WatchPrecision = .none,
};

pub const Expected = union(enum) {
    anything,
    absent,
    entry: struct {
        ref: EntryRef,
        revision: Revision,
    },
};

pub const Source = union(enum) {
    entry: struct {
        ref: EntryRef,
        revision: Revision,
    },
    lease: LeaseRef,
};

pub const RemovePolicy = enum { quarantine, permanent };

pub const Operation = union(enum) {
    create_file: struct {
        destination: Slot,
        expected: Expected = .absent,
        contents: []const u8,
        mode: ?u32 = null,
    },
    create_directory: struct {
        destination: Slot,
        expected: Expected = .absent,
        mode: ?u32 = null,
    },
    create_symlink: struct {
        destination: Slot,
        expected: Expected = .absent,
        target: []const u8,
    },
    copy: struct {
        source: Source,
        destination: Slot,
        expected: Expected = .absent,
    },
    rename: struct {
        source: EntryRef,
        source_revision: Revision,
        destination: Slot,
        expected: Expected = .absent,
    },
    remove: struct {
        source: EntryRef,
        revision: Revision,
        policy: RemovePolicy = .quarantine,
    },
    set_permissions: struct {
        source: EntryRef,
        revision: Revision,
        mode: u32,
        follow_symlink: bool = false,
    },
};

pub const Outcome = union(enum) {
    applied: ?Observation,
    already_satisfied,
    conflict: []const u8,
    stale,
    unsupported,
    ambiguous: []const u8,
    recoverable_at: Slot,
};

pub const OperationId = [16]u8;

pub const Planned = struct {
    id: OperationId,
    operation: Operation,
    depends_on: []const usize = &.{},
};

pub const Plan = struct {
    root: Root,
    base_revision: []const u8,
    operations: []const Planned,
};

pub const ReportEntry = struct {
    id: OperationId,
    outcome: Outcome,
};

pub const ApplyReport = struct {
    entries: []const ReportEntry,
};

pub const Invalidation = union(enum) {
    changed: ?EntryRef,
    root_changed,
    rescan_required,
};

test "raw names reject only invalid leaf components" {
    try std.testing.expectEqualStrings("a\n-[]'", (try Name.init("a\n-[]'")).bytes);
    try std.testing.expectError(error.Empty, Name.init(""));
    try std.testing.expectError(error.Reserved, Name.init(".."));
    try std.testing.expectError(error.ContainsSlash, Name.init("a/b"));
    try std.testing.expectError(error.ContainsNul, Name.init("a\x00b"));
}

test "filesystem handles retain authority and generation" {
    const root: Root = .{ .authority = .here, .slot = 4, .generation = 2 };
    try std.testing.expectEqual(root, Root.fromWire(root.toWire()));
}
