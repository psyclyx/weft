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

pub const Error = target_runtime.target.Error || router_mod.Error;

pub const Definition = struct {
    display_name: []const u8,
    directory: fs.target.Directory,
    /// Additional descriptive facts are copied into the target registry. A
    /// second filesystem-directory fact is rejected by the registry just like
    /// any other duplicate vocabulary name.
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

    /// Close only when the target registry accepts the same owner. A stale or
    /// fabricated registration therefore cannot remove somebody else's live
    /// filesystem authority. Provider retirement may already have removed the
    /// binding; target closure still succeeds in that case.
    pub fn close(
        self: *Registration,
        gpa: std.mem.Allocator,
        targets: *target_runtime.target.Registry,
        router: *router_mod.Router,
    ) bool {
        if (!self.active) return false;
        if (!targets.close(gpa, self.owner, self.ref)) return false;
        _ = router.unbindTarget(self.ref);
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
    try router.bindTarget(ref, descriptor.revision, definition.directory);
    return .{ .ref = ref, .revision = descriptor.revision, .owner = owner };
}

const TestProvider = struct {
    authority: semantic.handle.Authority,
    observed_kind: fs.contract.Kind = .directory,
    observe_calls: usize = 0,

    fn provider(self: *TestProvider) fs.service.Provider {
        return .init(self);
    }

    pub fn capabilities(_: *TestProvider, _: fs.contract.Root) fs.contract.Error!fs.contract.Capabilities {
        return .{};
    }

    pub fn observe(self: *TestProvider, gpa: std.mem.Allocator, root: fs.contract.Root, node: fs.contract.NodeRef) fs.contract.Error!fs.contract.OwnedObservation {
        if (root.authority != self.authority) return error.Confined;
        self.observe_calls += 1;
        var owned = fs.contract.OwnedObservation.init(gpa);
        owned.value = .{ .node = node, .revision = .{ .token = &.{} }, .kind = self.observed_kind };
        return owned;
    }

    pub fn list(_: *TestProvider, _: std.mem.Allocator, _: fs.contract.Root, _: fs.contract.NodeRef) fs.contract.Error!fs.contract.OwnedListing {
        return error.Unsupported;
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
