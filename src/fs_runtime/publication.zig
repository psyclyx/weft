//! Trusted composition of semantic target identity and filesystem authority.
//!
//! A target fact describes a directory but grants nothing. Publication first
//! creates that ordinary semantic target, then asks the filesystem router to
//! bind the exact target revision to a provider-observed directory. Sandboxed
//! plugins can publish matching facts, but cannot mint this binding.

const std = @import("std");
const semantic = @import("weft_semantic");
const fs = @import("weft_fs");
const target_runtime = @import("weft_target_runtime");
const router_mod = @import("router.zig");

const contract = fs.contract;

pub const Error = target_runtime.target.Error || router_mod.Error;

pub const Definition = struct {
    display_name: []const u8,
    directory: fs.target.Directory,
    /// Additional descriptive facts are copied into the target registry. A
    /// second filesystem-directory fact is rejected by the registry just like
    /// any other duplicate vocabulary name.
    facts: []const semantic.target.Fact = &.{},
};

/// A direct child publication request contains only an observed opaque entry
/// and its revision. The parent target is the authority boundary; callers
/// cannot supply a path, raw root, or display name.
pub const ChildDefinition = struct {
    parent: semantic.target.Located,
    entry: contract.EntryRef,
    entry_revision: contract.Revision,
};

pub const EntryDefinition = struct {
    display_name: []const u8,
    entry: fs.target.Entry,
    facts: []const semantic.target.Fact = &.{},
};

/// The two-part lifetime created by `publish`. Keeping it as a value makes
/// ownership explicit without coupling either registry to the other.
pub const Registration = struct {
    ref: semantic.target.Ref,
    revision: u64,
    owner: semantic.owner.Id,
    active: bool = true,

    pub fn located(self: Registration) semantic.target.Located {
        return .{ .target = self.ref, .revision = self.revision };
    }

    /// Retire both halves exactly once. Either half may already be absent due
    /// to independent owner/provider teardown; absence never prevents cleanup
    /// of the other half. Exact owner and revision checks keep a stale or
    /// fabricated registration away from a newer or foreign publication.
    pub fn close(
        self: *Registration,
        gpa: std.mem.Allocator,
        targets: *target_runtime.target.Registry,
        router: *router_mod.Router,
    ) bool {
        if (!self.active) return false;
        if (targets.ownerOf(self.ref)) |owner| if (owner != self.owner) return false;
        if (router.bindingOwner(self.ref)) |owner| if (owner != self.owner) return false;
        _ = targets.closeRevision(gpa, self.owner, self.ref, self.revision);
        _ = router.unbindTargetOwned(self.owner, self.ref, self.revision);
        self.active = false;
        return true;
    }
};

/// Owns both halves of a child publication: the semantic target/binding and
/// the provider root derived from the guarded child entry. A copied value is
/// not an additional owner; callers close the original value exactly once.
pub const ChildRegistration = struct {
    registration: Registration,
    derived_root: contract.Root,
    router: *router_mod.Router,
    active: bool = true,

    pub fn located(self: ChildRegistration) semantic.target.Located {
        return self.registration.located();
    }

    pub fn close(
        self: *ChildRegistration,
        gpa: std.mem.Allocator,
        targets: *target_runtime.target.Registry,
    ) bool {
        if (!self.active) return false;
        if (!self.registration.close(gpa, targets, self.router)) return false;
        // Provider retirement may already have reclaimed the descriptor. The
        // target lifetime is still closed in that case, and deinit owns the
        // final provider cleanup.
        _ = self.router.releaseRoot(self.derived_root) catch {};
        self.active = false;
        return true;
    }
};

/// Publish one directory target as an all-or-nothing composition. Failure to
/// observe or bind the provider directory rolls the descriptive target back;
/// callers never receive a target that merely looks authorized.
pub fn publish(
    gpa: std.mem.Allocator,
    targets: *target_runtime.target.Registry,
    router: *router_mod.Router,
    owner: semantic.owner.Id,
    definition: Definition,
) Error!Registration {
    const encoded_directory = try fs.target.encode(gpa, definition.directory);
    defer gpa.free(encoded_directory);

    const facts = try gpa.alloc(semantic.target.Fact, definition.facts.len + 1);
    defer gpa.free(facts);
    facts[0] = .{ .name = fs.target.fact_name, .value = encoded_directory };
    @memcpy(facts[1..], definition.facts);

    const ref = try targets.publish(gpa, owner, .{
        .kind = .directory,
        .display_name = definition.display_name,
        .facts = facts,
    });
    errdefer _ = targets.close(gpa, owner, ref);

    const descriptor = targets.get(ref) orelse return error.StaleTarget;
    try router.bindTarget(owner, ref, descriptor.revision, definition.directory);
    return .{ .ref = ref, .revision = descriptor.revision, .owner = owner };
}

/// Publish an ordinary-file target from an already observed provider entry.
/// The descriptive target and executable router binding are committed as one
/// composition; a failed observation never leaves a target that merely looks
/// openable.
pub fn publishEntry(
    gpa: std.mem.Allocator,
    targets: *target_runtime.target.Registry,
    router: *router_mod.Router,
    owner: semantic.owner.Id,
    definition: EntryDefinition,
) Error!Registration {
    const encoded_entry = try fs.target.encodeEntry(gpa, definition.entry);
    defer gpa.free(encoded_entry);

    const facts = try gpa.alloc(semantic.target.Fact, definition.facts.len + 1);
    defer gpa.free(facts);
    facts[0] = .{ .name = fs.target.entry_fact_name, .value = encoded_entry };
    @memcpy(facts[1..], definition.facts);

    const ref = try targets.publish(gpa, owner, .{
        .kind = .file,
        .display_name = definition.display_name,
        .facts = facts,
    });
    errdefer _ = targets.close(gpa, owner, ref);
    const descriptor = targets.get(ref) orelse return error.StaleTarget;
    try router.bindEntry(owner, ref, descriptor.revision, definition.entry);
    return .{ .ref = ref, .revision = descriptor.revision, .owner = owner };
}

/// Publish a regular direct child from a live directory target.  Listing is
/// the relation proof; the router repeats the no-follow observation during
/// binding, preserving the provider's TOCTOU boundary.
pub fn publishChildFile(
    gpa: std.mem.Allocator,
    targets: *target_runtime.target.Registry,
    router: *router_mod.Router,
    owner: semantic.owner.Id,
    definition: ChildDefinition,
) Error!Registration {
    switch (definition.parent.location) {
        .whole => {},
        else => return error.Unsupported,
    }
    const parent_descriptor = targets.get(definition.parent.target) orelse return error.StaleTarget;
    if (parent_descriptor.revision != definition.parent.revision or parent_descriptor.kind != .directory)
        return error.StaleTarget;
    const parent = try router.authorizedDirectory(definition.parent.target, definition.parent.revision);
    var listing = try router.list(gpa, parent.root, parent.node);
    defer listing.deinit();
    for (listing.value.entries) |entry| {
        const entry_ref = switch (entry.observation.node) {
            .root => continue,
            .entry => |ref| ref,
        };
        if (!entry_ref.eql(definition.entry)) continue;
        if (!std.mem.eql(u8, entry.observation.revision.token, definition.entry_revision.token))
            return error.Stale;
        if (entry.observation.kind != .regular) return error.Unsupported;
        return publishEntry(gpa, targets, router, owner, .{
            .display_name = entry.name.bytes,
            .entry = .{ .root = parent.root, .ref = definition.entry, .revision = entry.observation.revision },
        });
    }
    return error.Stale;
}

/// Publish a directory target from a live, directly listed child. Listing is
/// the relation proof: the entry must occur in the authorized parent's
/// current listing with the exact opaque identity, revision, and directory
/// kind requested. The provider then repeats its own no-follow checks while
/// deriving the confined root, so this composition remains honest about the
/// unavoidable TOCTOU interval.
pub fn publishChildDirectory(
    gpa: std.mem.Allocator,
    targets: *target_runtime.target.Registry,
    router: *router_mod.Router,
    owner: semantic.owner.Id,
    definition: ChildDefinition,
) Error!ChildRegistration {
    switch (definition.parent.location) {
        .whole => {},
        else => return error.Unsupported,
    }
    const parent_descriptor = targets.get(definition.parent.target) orelse return error.StaleTarget;
    if (parent_descriptor.revision != definition.parent.revision or parent_descriptor.kind != .directory)
        return error.StaleTarget;
    const parent = router.authorizedDirectory(definition.parent.target, definition.parent.revision) catch |err| return err;

    var listing = try router.list(gpa, parent.root, parent.node);
    defer listing.deinit();
    var found: ?contract.DirEntry = null;
    for (listing.value.entries) |entry| {
        const entry_ref = switch (entry.observation.node) {
            .root => continue,
            .entry => |ref| ref,
        };
        if (!entry_ref.eql(definition.entry)) continue;
        if (!std.mem.eql(u8, entry.observation.revision.token, definition.entry_revision.token))
            return error.Stale;
        if (entry.observation.kind != .directory) return error.NotDirectory;
        found = entry;
        break;
    }
    const direct = found orelse return error.Stale;
    const child_source: contract.EntrySource = .{
        .root = parent.root,
        .ref = definition.entry,
        .revision = direct.observation.revision,
    };
    const derived_root = try router.deriveRoot(child_source);
    errdefer router.releaseRoot(derived_root) catch {};

    const registration = try publish(gpa, targets, router, owner, .{
        .display_name = direct.name.bytes,
        .directory = .{ .root = derived_root },
    });
    return .{
        .registration = registration,
        .derived_root = derived_root,
        .router = router,
    };
}

/// Provider-neutral child lookup. The caller supplies only an opaque raw leaf
/// name; Router-owned listing and the existing guarded publishers establish
/// the entry identity and kind. This keeps namespace interpretation reusable
/// by local, remote, and synthetic Router providers instead of putting it in
/// an app/session implementation.
pub const ChildPublication = union(enum) {
    directory: ChildRegistration,
    file: Registration,
};

pub fn publishChildByName(
    gpa: std.mem.Allocator,
    targets: *target_runtime.target.Registry,
    router: *router_mod.Router,
    owner: semantic.owner.Id,
    parent: semantic.target.Located,
    name: []const u8,
) Error!?ChildPublication {
    if (name.len == 0) return error.InvalidName;
    const directory = try router.authorizedDirectory(parent.target, parent.revision);
    var listing = try router.list(gpa, directory.root, directory.node);
    defer listing.deinit();
    for (listing.value.entries) |entry| {
        if (!std.mem.eql(u8, entry.name.bytes, name)) continue;
        const entry_ref = switch (entry.observation.node) {
            .root => return error.InvalidHandle,
            .entry => |ref| ref,
        };
        const definition: ChildDefinition = .{
            .parent = parent,
            .entry = entry_ref,
            .entry_revision = entry.observation.revision,
        };
        return switch (entry.observation.kind) {
            .directory => .{ .directory = try publishChildDirectory(gpa, targets, router, owner, definition) },
            .regular => .{ .file = try publishChildFile(gpa, targets, router, owner, definition) },
            .symlink, .other => null,
        };
    }
    return null;
}

const TestProvider = struct {
    authority: semantic.handle.Authority,
    observed_kind: fs.contract.Kind = .directory,
    /// Optional kind override for the derived child root.  This lets the
    /// publication contract test the bind-after-derive failure path without
    /// making the parent itself unpublishable.
    derived_observed_kind: ?fs.contract.Kind = null,
    observe_calls: usize = 0,
    list_enabled: bool = false,
    list_parent_only: bool = false,
    listed_name: []const u8 = "child",
    listed_ref: fs.contract.EntryRef = .{ .authority = .here, .slot = 4, .generation = 1 },
    listed_kind: fs.contract.Kind = .directory,
    listed_revision: []const u8 = "child-revision",
    observed_revision: ?[]const u8 = null,
    derive_calls: usize = 0,
    release_calls: usize = 0,

    fn provider(self: *TestProvider) fs.service.Provider {
        return .init(self);
    }

    pub fn capabilities(_: *TestProvider, _: fs.contract.Root) fs.contract.Error!fs.contract.Capabilities {
        return .{};
    }

    pub fn sameRoot(self: *TestProvider, left: fs.contract.Root, right: fs.contract.Root) fs.contract.Error!bool {
        if (left.authority != self.authority or right.authority != self.authority) return error.Confined;
        return left.eql(right);
    }

    pub fn deriveRoot(self: *TestProvider, source: fs.contract.EntrySource) fs.contract.Error!fs.contract.Root {
        if (source.root.authority != self.authority) return error.Confined;
        if (!self.list_enabled or !source.ref.eql(self.listed_ref)) return error.Stale;
        if (!std.mem.eql(u8, source.revision.token, self.listed_revision)) return error.Stale;
        if (self.listed_kind != .directory) return error.NotDirectory;
        self.derive_calls += 1;
        return .{ .authority = source.root.authority, .slot = source.root.slot + 1, .generation = 1 };
    }

    pub fn releaseRoot(self: *TestProvider, _: fs.contract.Root) void {
        self.release_calls += 1;
    }

    pub fn observe(self: *TestProvider, gpa: std.mem.Allocator, root: fs.contract.Root, node: fs.contract.NodeRef) fs.contract.Error!fs.contract.OwnedObservation {
        if (root.authority != self.authority) return error.Confined;
        self.observe_calls += 1;
        var owned = fs.contract.OwnedObservation.init(gpa);
        const kind = if (self.derived_observed_kind != null and root.slot == 4)
            self.derived_observed_kind.?
        else if (self.list_enabled and std.meta.eql(node, .{ .entry = self.listed_ref }))
            self.listed_kind
        else
            self.observed_kind;
        const observed_revision = self.observed_revision orelse if (self.list_enabled and
            std.meta.eql(node, .{ .entry = self.listed_ref })) self.listed_revision else "";
        owned.value = .{ .node = node, .revision = .{ .token = observed_revision }, .kind = kind };
        return owned;
    }

    pub fn list(self: *TestProvider, gpa: std.mem.Allocator, root: fs.contract.Root, node: fs.contract.NodeRef) fs.contract.Error!fs.contract.OwnedListing {
        if (!self.list_enabled) return error.Unsupported;
        var owned = fs.contract.OwnedListing.init(gpa);
        errdefer owned.deinit();
        const arena = owned.allocator();
        const token = try arena.dupe(u8, self.listed_revision);
        const entry_count: usize = @intFromBool(!self.list_parent_only or root.slot == 3);
        const entries = try arena.alloc(fs.contract.DirEntry, entry_count);
        if (entry_count != 0) {
            const name = try arena.dupe(u8, self.listed_name);
            entries[0] = .{
                .name = fs.contract.Name.init(name) catch unreachable,
                .observation = .{
                    .node = .{ .entry = self.listed_ref },
                    .revision = .{ .token = token },
                    .kind = self.listed_kind,
                },
            };
        }
        owned.value = .{
            .directory = .{ .node = node, .revision = .{ .token = token }, .kind = .directory },
            .revision = .{ .token = token },
            .entries = entries,
        };
        return owned;
    }

    pub fn read(_: *TestProvider, _: std.mem.Allocator, _: fs.contract.ReadRequest) fs.contract.Error!fs.contract.OwnedReadResult {
        return error.Unsupported;
    }

    pub fn capture(_: *TestProvider, _: fs.contract.EntrySource) fs.contract.Error!fs.contract.LeaseRef {
        return error.Unsupported;
    }

    pub fn releaseLease(_: *TestProvider, _: fs.contract.LeaseSource) void {}

    pub fn apply(_: *TestProvider, _: std.mem.Allocator, _: fs.contract.Plan) fs.contract.Error!fs.contract.OwnedApplyReport {
        return error.Unsupported;
    }

    pub fn watch(_: *TestProvider, _: fs.contract.Root, _: fs.contract.NodeRef, _: bool) fs.contract.Error!fs.contract.WatchRef {
        return error.Unsupported;
    }

    pub fn pollInvalidation(_: *TestProvider, _: fs.contract.WatchRef) fs.contract.Error!?fs.contract.Invalidation {
        return error.Unsupported;
    }

    pub fn closeWatch(_: *TestProvider, _: fs.contract.WatchRef) void {}
};

fn testRoot(authority: semantic.handle.Authority) fs.contract.Root {
    return .{ .authority = authority, .slot = 3, .generation = 1 };
}

test "publication couples a copied fact to provider-observed authority" {
    const gpa = std.testing.allocator;
    const fs_authority: semantic.handle.Authority = @enumFromInt(41);
    const target_authority: semantic.handle.Authority = @enumFromInt(73);
    const owner: semantic.owner.Id = @enumFromInt(9);
    const directory: fs.target.Directory = .{ .root = testRoot(fs_authority) };

    var provider = TestProvider{ .authority = fs_authority };
    var router = router_mod.Router.init(gpa);
    defer router.deinit();
    try router.register(fs_authority, provider.provider());
    var targets = target_runtime.target.Registry.init(target_authority);
    defer targets.deinit(gpa);

    var registration = try publish(gpa, &targets, &router, owner, .{
        .display_name = "remote project",
        .directory = directory,
        .facts = &.{.{ .name = "peer", .value = "alice" }},
    });
    const descriptor = targets.get(registration.ref).?;
    try std.testing.expectEqual(semantic.target.Kind.directory, descriptor.kind);
    try std.testing.expectEqualStrings("remote project", descriptor.display_name);
    try std.testing.expectEqual(directory, (try fs.target.find(descriptor.facts)).?);
    try std.testing.expectEqual(directory, try router.authorizedDirectory(registration.ref, descriptor.revision));
    try std.testing.expectEqual(registration.ref, registration.located().target);
    try std.testing.expectEqual(@as(usize, 1), provider.observe_calls);

    var wrong_owner = registration;
    wrong_owner.owner = @enumFromInt(10);
    try std.testing.expect(!wrong_owner.close(gpa, &targets, &router));
    try std.testing.expect(targets.get(registration.ref) != null);
    _ = try router.authorizedDirectory(registration.ref, 1);

    try std.testing.expect(registration.close(gpa, &targets, &router));
    try std.testing.expect(!registration.close(gpa, &targets, &router));
    try std.testing.expect(targets.get(registration.ref) == null);
    try std.testing.expectError(error.TargetUnbound, router.authorizedDirectory(registration.ref, 1));
}

test "publication rolls back descriptive targets when authority cannot bind" {
    const gpa = std.testing.allocator;
    const fs_authority: semantic.handle.Authority = @enumFromInt(42);
    const owner: semantic.owner.Id = @enumFromInt(11);
    var provider = TestProvider{ .authority = fs_authority, .observed_kind = .regular };
    var router = router_mod.Router.init(gpa);
    defer router.deinit();
    try router.register(fs_authority, provider.provider());
    var targets = target_runtime.target.Registry.init(@enumFromInt(74));
    defer targets.deinit(gpa);

    try std.testing.expectError(error.NotDirectory, publish(gpa, &targets, &router, owner, .{
        .display_name = "not a directory",
        .directory = .{ .root = testRoot(fs_authority) },
    }));
    try std.testing.expectEqual(@as(usize, 0), targets.closeOwner(gpa, owner));

    const encoded = try fs.target.encode(gpa, .{ .root = testRoot(fs_authority) });
    defer gpa.free(encoded);
    try std.testing.expectError(error.DuplicateFact, publish(gpa, &targets, &router, owner, .{
        .display_name = "duplicate authority description",
        .directory = .{ .root = testRoot(fs_authority) },
        .facts = &.{.{ .name = fs.target.fact_name, .value = encoded }},
    }));
    try std.testing.expectEqual(@as(usize, 0), targets.closeOwner(gpa, owner));
}

test "child publication rolls back its target and derived root when binding fails" {
    const gpa = std.testing.allocator;
    const fs_authority: semantic.handle.Authority = @enumFromInt(44);
    const target_authority: semantic.handle.Authority = @enumFromInt(76);
    const owner: semantic.owner.Id = @enumFromInt(13);
    const child_ref: fs.contract.EntryRef = .{ .authority = fs_authority, .slot = 8, .generation = 1 };
    var provider = TestProvider{
        .authority = fs_authority,
        .list_enabled = true,
        .listed_ref = child_ref,
        .derived_observed_kind = .regular,
    };
    var router = router_mod.Router.init(gpa);
    defer router.deinit();
    try router.register(fs_authority, provider.provider());
    var targets = target_runtime.target.Registry.init(target_authority);
    defer targets.deinit(gpa);

    var parent = try publish(gpa, &targets, &router, owner, .{
        .display_name = "parent",
        .directory = .{ .root = testRoot(fs_authority) },
    });
    defer _ = parent.close(gpa, &targets, &router);
    const child_target: semantic.target.Ref = .{
        .authority = target_authority,
        .slot = 1,
        .generation = 1,
    };
    try std.testing.expectError(error.NotDirectory, publishChildDirectory(gpa, &targets, &router, owner, .{
        .parent = parent.located(),
        .entry = child_ref,
        .entry_revision = .{ .token = "child-revision" },
    }));
    // The descriptive target and provider-derived root are both reclaimed;
    // only the independently published parent remains live.
    try std.testing.expect(targets.get(child_target) == null);
    try std.testing.expectError(error.TargetUnbound, router.authorizedDirectory(child_target, 1));
    try std.testing.expectEqual(@as(usize, 1), provider.derive_calls);
    try std.testing.expectEqual(@as(usize, 1), provider.release_calls);
    try std.testing.expectEqual(@as(usize, 1), targets.closeOwner(gpa, owner));
}

test "child publication proves direct identity, owns derived root, and preserves raw name" {
    const gpa = std.testing.allocator;
    const fs_authority: semantic.handle.Authority = @enumFromInt(43);
    const target_authority: semantic.handle.Authority = @enumFromInt(75);
    const owner: semantic.owner.Id = @enumFromInt(12);
    const parent_root = testRoot(fs_authority);
    const child_ref: fs.contract.EntryRef = .{ .authority = fs_authority, .slot = 8, .generation = 1 };
    var provider = TestProvider{
        .authority = fs_authority,
        .list_enabled = true,
        .listed_name = "line\n-[]'\xff",
        .listed_ref = child_ref,
        .list_parent_only = true,
    };
    var router = router_mod.Router.init(gpa);
    defer router.deinit();
    try router.register(fs_authority, provider.provider());
    var targets = target_runtime.target.Registry.init(target_authority);
    defer targets.deinit(gpa);

    var parent = try publish(gpa, &targets, &router, owner, .{
        .display_name = "parent",
        .directory = .{ .root = parent_root },
    });
    defer _ = parent.close(gpa, &targets, &router);
    var child = try publishChildDirectory(gpa, &targets, &router, owner, .{
        .parent = parent.located(),
        .entry = child_ref,
        .entry_revision = .{ .token = "child-revision" },
    });
    try std.testing.expectEqualStrings("line\n-[]'\xff", targets.get(child.registration.ref).?.display_name);
    try std.testing.expectEqual(@as(usize, 1), provider.derive_calls);
    try std.testing.expectEqual(@as(u32, parent_root.slot + 1), child.derived_root.slot);
    try std.testing.expectEqual(child.registration.ref, child.located().target);
    try std.testing.expectEqual(@as(usize, 2), provider.observe_calls);
    const child_directory = try router.authorizedDirectory(child.registration.ref, child.registration.revision);
    try std.testing.expect(!child_directory.root.eql(parent_root));
    try std.testing.expectError(error.StaleTarget, router.authorizedDirectory(child.registration.ref, child.registration.revision + 1));
    var child_listing = try router.list(gpa, child_directory.root, child_directory.node);
    defer child_listing.deinit();
    try std.testing.expectEqual(@as(usize, 0), child_listing.value.entries.len);
    try std.testing.expect(child.close(gpa, &targets));
    try std.testing.expectEqual(@as(usize, 1), provider.release_calls);
    try std.testing.expectError(error.TargetUnbound, router.authorizedDirectory(child.registration.ref, child.registration.revision));
    try std.testing.expect(!child.close(gpa, &targets));

    provider.listed_kind = .regular;
    try std.testing.expectError(error.NotDirectory, publishChildDirectory(gpa, &targets, &router, owner, .{
        .parent = parent.located(),
        .entry = child_ref,
        .entry_revision = .{ .token = "child-revision" },
    }));
    provider.listed_kind = .symlink;
    try std.testing.expectError(error.NotDirectory, publishChildDirectory(gpa, &targets, &router, owner, .{
        .parent = parent.located(),
        .entry = child_ref,
        .entry_revision = .{ .token = "child-revision" },
    }));
    provider.listed_kind = .directory;
    try std.testing.expectError(error.Stale, publishChildDirectory(gpa, &targets, &router, owner, .{
        .parent = parent.located(),
        .entry = child_ref,
        .entry_revision = .{ .token = "old" },
    }));
    const foreign: fs.contract.EntryRef = .{ .authority = fs_authority, .slot = 99, .generation = 1 };
    try std.testing.expectError(error.Stale, publishChildDirectory(gpa, &targets, &router, owner, .{
        .parent = parent.located(),
        .entry = foreign,
        .entry_revision = .{ .token = "child-revision" },
    }));

    try std.testing.expectError(error.Unsupported, publishChildDirectory(gpa, &targets, &router, owner, .{
        .parent = .{ .target = parent.ref, .revision = parent.revision, .location = .{ .node = "not-whole" } },
        .entry = child_ref,
        .entry_revision = .{ .token = "child-revision" },
    }));

    var revoked = try publishChildDirectory(gpa, &targets, &router, owner, .{
        .parent = parent.located(),
        .entry = child_ref,
        .entry_revision = .{ .token = "child-revision" },
    });
    // Simulate semantic owner teardown happening before the host's resource
    // collection gets to release its child registration.
    try std.testing.expectEqual(@as(usize, 2), targets.closeOwner(gpa, owner));
    try std.testing.expect(revoked.close(gpa, &targets));
    try std.testing.expectEqual(@as(usize, 2), provider.release_calls);
    try std.testing.expectError(error.TargetUnbound, router.authorizedDirectory(revoked.registration.ref, revoked.registration.revision));
    try std.testing.expect(!revoked.close(gpa, &targets));
}

test "stale registration closes only its exact authority revision" {
    const gpa = std.testing.allocator;
    const fs_authority: semantic.handle.Authority = @enumFromInt(48);
    const target_authority: semantic.handle.Authority = @enumFromInt(78);
    const owner: semantic.owner.Id = @enumFromInt(15);
    const directory: fs.target.Directory = .{ .root = testRoot(fs_authority) };

    var provider = TestProvider{ .authority = fs_authority };
    var router = router_mod.Router.init(gpa);
    defer router.deinit();
    try router.register(fs_authority, provider.provider());
    var targets = target_runtime.target.Registry.init(target_authority);
    defer targets.deinit(gpa);

    var registration = try publish(gpa, &targets, &router, owner, .{
        .display_name = "before",
        .directory = directory,
    });
    try targets.replace(gpa, owner, registration.ref, .{
        .kind = .directory,
        .display_name = "after",
    });
    try std.testing.expectEqual(@as(u64, 2), targets.get(registration.ref).?.revision);

    try std.testing.expect(registration.close(gpa, &targets, &router));
    try std.testing.expectEqualStrings("after", targets.get(registration.ref).?.display_name);
    try std.testing.expectError(error.TargetUnbound, router.authorizedDirectory(registration.ref, 1));
}

test "ordinary-file publication composes an opaque entry fact and guarded binding" {
    const gpa = std.testing.allocator;
    const fs_authority: semantic.handle.Authority = @enumFromInt(47);
    const target_authority: semantic.handle.Authority = @enumFromInt(77);
    const owner: semantic.owner.Id = @enumFromInt(14);
    const child_ref: fs.contract.EntryRef = .{ .authority = fs_authority, .slot = 12, .generation = 1 };
    var provider = TestProvider{
        .authority = fs_authority,
        .list_enabled = true,
        .listed_name = "ordinary\nfile\xff",
        .listed_ref = child_ref,
        .listed_kind = .regular,
    };
    var router = router_mod.Router.init(gpa);
    defer router.deinit();
    try router.register(fs_authority, provider.provider());
    var targets = target_runtime.target.Registry.init(target_authority);
    defer targets.deinit(gpa);

    var parent = try publish(gpa, &targets, &router, owner, .{
        .display_name = "parent",
        .directory = .{ .root = testRoot(fs_authority) },
    });
    defer _ = parent.close(gpa, &targets, &router);

    const registration = switch ((try publishChildByName(
        gpa,
        &targets,
        &router,
        owner,
        parent.located(),
        "ordinary\nfile\xff",
    )).?) {
        .file => |value| value,
        .directory => return error.TestUnexpectedResult,
    };
    var file = registration;
    defer _ = file.close(gpa, &targets, &router);
    const descriptor = targets.get(registration.ref).?;
    try std.testing.expectEqual(semantic.target.Kind.file, descriptor.kind);
    try std.testing.expectEqualStrings("ordinary\nfile\xff", descriptor.display_name);
    const attachment = (try fs.target.findEntry(descriptor.facts)).?;
    try std.testing.expectEqual(child_ref, attachment.ref);
    try std.testing.expectEqual(testRoot(fs_authority), attachment.root);
    try std.testing.expectEqualStrings("child-revision", attachment.revision.token);
    const authorized = try router.authorizedEntry(registration.ref, registration.revision);
    try std.testing.expectEqual(attachment.root, authorized.root);
    try std.testing.expectEqual(attachment.ref, authorized.ref);
    try std.testing.expectEqualSlices(u8, attachment.revision.token, authorized.revision.token);
}
