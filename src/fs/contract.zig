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

/// A root is a directory object in its own right, but it deliberately has no
/// synthetic entry handle. Keeping that distinction explicit avoids sentinel
/// slots and makes confinement visible in every operation.
pub const NodeRef = union(enum) {
    root,
    entry: EntryRef,
};

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

/// Destinations may be beneath the root, an observed directory, or a
/// directory created by an earlier operation in the same ordered plan.
pub const ParentRef = union(enum) {
    root,
    entry: EntryRef,
    planned: usize,
};

pub const Slot = struct {
    parent: ParentRef,
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
    node: NodeRef,
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

/// A guarded entry address is complete: the root establishes the namespace,
/// the opaque ref establishes identity within its provider, and the revision
/// is the consumer's observation. Keeping the root here is what makes a
/// captured source portable to a plan whose destination is a different root;
/// executors may perform it directly, bridge providers, or report Unsupported,
/// but they can never silently reinterpret the entry in the destination root.
pub const EntrySource = struct {
    root: Root,
    ref: EntryRef,
    revision: Revision,
};

pub const LeaseSource = struct {
    root: Root,
    ref: LeaseRef,
};

pub const Source = union(enum) {
    entry: EntrySource,
    lease: LeaseSource,
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
        source: EntrySource,
        destination: Slot,
        expected: Expected = .absent,
    },
    remove: struct {
        source: EntrySource,
        policy: RemovePolicy = .quarantine,
    },
    set_permissions: struct {
        source: EntrySource,
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

pub const Listing = struct {
    directory: Observation,
    revision: Revision,
    entries: []const DirEntry,
};

pub const ReadRequest = struct {
    source: Source,
    offset: u64 = 0,
    limit: ?u64 = null,
};

pub const ReadResult = struct {
    observation: Observation,
    bytes: []const u8,
    eof: bool,
};

/// Results own one arena so nested raw names, revision tokens, link targets,
/// and report details share one obvious lifetime. Providers allocate from the
/// arena; callers call `deinit` exactly once.
pub fn Owned(comptime T: type) type {
    return struct {
        arena: std.heap.ArenaAllocator,
        value: T = undefined,

        const Self = @This();

        pub fn init(gpa: std.mem.Allocator) Self {
            return .{ .arena = .init(gpa) };
        }

        pub fn allocator(self: *Self) std.mem.Allocator {
            return self.arena.allocator();
        }

        pub fn deinit(self: *Self) void {
            self.arena.deinit();
            self.* = undefined;
        }
    };
}

pub const OwnedObservation = Owned(Observation);
pub const OwnedListing = Owned(Listing);
pub const OwnedReadResult = Owned(ReadResult);
pub const OwnedApplyReport = Owned(ApplyReport);

pub const Error = error{
    NotFound,
    AlreadyExists,
    NotDirectory,
    PermissionDenied,
    Confined,
    Stale,
    CrossDevice,
    Unsupported,
    InvalidName,
    Busy,
    Io,
} || std.mem.Allocator.Error;

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
