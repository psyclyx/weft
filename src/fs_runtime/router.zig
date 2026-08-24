//! Authority-scoped provider routing for the portable filesystem contract.
//!
//! A Router owns the association between opaque filesystem authorities and
//! providers.  It does not interpret slots, generations, paths, or provider
//! policy; those remain the provider's concern.  Keeping this table explicit
//! makes roots and watches portable values rather than ambient global state.

const std = @import("std");
const semantic = @import("weft_semantic");
const fs = @import("weft_fs");

const contract = fs.contract;

pub const Error = contract.Error || fs.plan.ValidationError || fs.plan.ReportValidationError || fs.target.Error || error{
    AuthorityAlreadyRegistered,
    AuthorityRetired,
    UnknownAuthority,
    InvalidHandle,
    TargetAlreadyBound,
    TargetUnbound,
    StaleTarget,
};

pub const TargetBinding = struct {
    revision: u64,
    directory: fs.target.Directory,
};

pub const EntryBinding = struct {
    revision: u64,
    entry: fs.target.Entry,
    /// Owned by the router. `entry.revision.token` points into this slice;
    /// keeping the two together makes the borrowed provider observation safe
    /// after a listing/codec arena is released.
    revision_token: []u8,

    fn deinit(self: *EntryBinding, allocator: std.mem.Allocator) void {
        allocator.free(self.revision_token);
        self.* = undefined;
    }
};

pub const Router = struct {
    allocator: std.mem.Allocator,
    providers: std.AutoHashMap(semantic.handle.Authority, fs.service.Provider),
    retired: std.AutoHashMap(semantic.handle.Authority, void),
    target_bindings: std.AutoHashMap(u128, TargetBinding),
    entry_bindings: std.AutoHashMap(u128, EntryBinding),

    pub fn init(allocator: std.mem.Allocator) Router {
        return .{
            .allocator = allocator,
            .providers = .init(allocator),
            .retired = .init(allocator),
            .target_bindings = .init(allocator),
            .entry_bindings = .init(allocator),
        };
    }

    pub fn deinit(self: *Router) void {
        var entry_bindings = self.entry_bindings.valueIterator();
        while (entry_bindings.next()) |binding| binding.deinit(self.allocator);
        self.providers.deinit();
        self.retired.deinit();
        self.target_bindings.deinit();
        self.entry_bindings.deinit();
        self.* = undefined;
    }

    /// Register an authority exactly once for this router lifetime.  An
    /// authority is a provider identity, not a reusable table index: keeping
    /// it retired after unregister prevents old roots from being silently
    /// interpreted by a newly attached provider.
    pub fn register(self: *Router, authority: semantic.handle.Authority, provider: fs.service.Provider) Error!void {
        if (self.retired.contains(authority)) return error.AuthorityRetired;
        const result = try self.providers.getOrPut(authority);
        if (result.found_existing) return error.AuthorityAlreadyRegistered;
        result.value_ptr.* = provider;
    }

    pub fn unregister(self: *Router, authority: semantic.handle.Authority) Error!void {
        if (!self.providers.contains(authority)) {
            if (self.retired.contains(authority)) return error.AuthorityRetired;
            return error.UnknownAuthority;
        }
        var stale: std.ArrayList(u128) = .empty;
        defer stale.deinit(self.allocator);
        var bindings = self.target_bindings.iterator();
        while (bindings.next()) |entry| {
            if (entry.value_ptr.directory.root.authority == authority)
                try stale.append(self.allocator, entry.key_ptr.*);
        }
        var entry_bindings = self.entry_bindings.iterator();
        while (entry_bindings.next()) |entry| {
            if (entry.value_ptr.entry.root.authority == authority)
                try stale.append(self.allocator, entry.key_ptr.*);
        }
        // Retire only after every potentially failing allocation succeeds.
        // If either table insertion or stale-key collection fails, the live
        // route and its bindings remain intact.
        try self.retired.put(authority, {});
        _ = self.providers.remove(authority);
        for (stale.items) |key| _ = self.target_bindings.remove(key);
        for (stale.items) |key| _ = self.removeEntryBinding(key);
    }

    fn targetKey(target: semantic.target.Ref) u128 {
        return (@as(u128, @intFromEnum(target.authority)) << 64) |
            (@as(u128, target.slot) << 32) |
            @as(u128, target.generation);
    }

    /// Bind one target revision to a provider-owned filesystem directory.
    /// This is the authority-bearing counterpart to the target's descriptive
    /// `weft.fs.directory.v1` fact.  Callers must unbind before closing a
    /// target or replacing its revision.
    pub fn bindTarget(self: *Router, target: semantic.target.Ref, revision: u64, directory: fs.target.Directory) Error!void {
        if (target.generation == 0 or revision == 0) return error.InvalidHandle;
        try fs.target.validate(directory);
        // Binding is the authority-minting step, so establish that the route
        // and exact node are live directories now. Descriptive target facts
        // and well-shaped opaque handles are not enough.
        var observed = try self.observe(self.allocator, directory.root, directory.node);
        defer observed.deinit();
        if (!std.meta.eql(observed.value.node, directory.node)) return error.InvalidHandle;
        if (observed.value.kind != .directory) return error.NotDirectory;
        const key = targetKey(target);
        if (self.target_bindings.contains(key)) return error.TargetAlreadyBound;
        try self.target_bindings.put(key, .{ .revision = revision, .directory = directory });
    }

    pub fn unbindTarget(self: *Router, target: semantic.target.Ref) bool {
        const key = targetKey(target);
        const removed_directory = self.target_bindings.remove(key);
        const removed_entry = self.removeEntryBinding(key);
        return removed_directory or removed_entry;
    }

    /// Return only a binding minted by the in-process filesystem authority.
    /// A target fact, a root handle, or a matching revision alone is not
    /// sufficient to authorize a sandbox filesystem operation.
    pub fn authorizedDirectory(self: *const Router, target: semantic.target.Ref, revision: u64) Error!fs.target.Directory {
        const binding = self.target_bindings.get(targetKey(target)) orelse return error.TargetUnbound;
        if (binding.revision != revision) return error.StaleTarget;
        return binding.directory;
    }

    /// Return only a provider-issued ordinary-entry binding.  As with
    /// directories, the descriptive fact is not an authority and the
    /// requested semantic revision must match the binding exactly.
    pub fn authorizedEntry(self: *const Router, target: semantic.target.Ref, revision: u64) Error!fs.target.Entry {
        const binding = self.entry_bindings.get(targetKey(target)) orelse return error.TargetUnbound;
        if (binding.revision != revision) return error.StaleTarget;
        return binding.entry;
    }

    pub fn bindEntry(self: *Router, target: semantic.target.Ref, revision: u64, entry: fs.target.Entry) Error!void {
        if (target.generation == 0 or revision == 0) return error.InvalidHandle;
        try fs.target.validateEntry(entry);
        var observed = try self.observe(self.allocator, entry.root, .{ .entry = entry.ref });
        defer observed.deinit();
        if (!std.meta.eql(observed.value.node, .{ .entry = entry.ref })) return error.InvalidHandle;
        if (observed.value.kind != .regular) return error.Unsupported;
        if (!std.mem.eql(u8, observed.value.revision.token, entry.revision.token)) return error.Stale;
        const key = targetKey(target);
        if (self.target_bindings.contains(key) or self.entry_bindings.contains(key)) return error.TargetAlreadyBound;
        const revision_token = try self.allocator.dupe(u8, entry.revision.token);
        errdefer self.allocator.free(revision_token);
        var binding: EntryBinding = .{ .revision = revision, .entry = entry, .revision_token = revision_token };
        binding.entry.revision.token = revision_token;
        try self.entry_bindings.put(key, binding);
    }

    fn removeEntryBinding(self: *Router, key: u128) bool {
        const removed = self.entry_bindings.fetchRemove(key) orelse return false;
        var binding = removed.value;
        binding.deinit(self.allocator);
        return true;
    }

    /// Validate the authority envelope for a provider-owned lease without
    /// consuming it. The provider remains the authority for whether the
    /// lease slot itself is live.
    pub fn validateLease(self: *Router, source: contract.LeaseSource) Error!void {
        _ = try self.checkLease(source);
    }

    fn providerFor(self: *const Router, authority: semantic.handle.Authority) Error!fs.service.Provider {
        if (self.providers.get(authority)) |provider| return provider;
        if (self.retired.contains(authority)) return error.AuthorityRetired;
        return error.UnknownAuthority;
    }

    fn checkRoot(self: *Router, root: contract.Root) Error!fs.service.Provider {
        if (root.generation == 0) return error.InvalidHandle;
        return self.providerFor(root.authority);
    }

    /// Route a durable lease by its provider authority, not by the liveness
    /// of the root that happened to mint it. A root is a scoped namespace
    /// address and may be closed immediately after capture; the provider owns
    /// the lease materialization and decides whether its opaque slot remains
    /// live. The envelope checks stay here so a lease cannot cross authorities
    /// before reaching provider policy.
    fn checkLease(self: *Router, source: contract.LeaseSource) Error!fs.service.Provider {
        if (source.root.generation == 0 or
            source.ref.generation == 0 or
            source.ref.authority != source.root.authority)
            return error.InvalidHandle;
        return self.providerFor(source.root.authority);
    }

    fn checkEntry(root: contract.Root, entry: contract.EntryRef) Error!void {
        if (entry.generation == 0 or entry.authority != root.authority) return error.InvalidHandle;
    }

    fn checkNode(root: contract.Root, node: contract.NodeRef) Error!void {
        switch (node) {
            .root => {},
            .entry => |entry| try checkEntry(root, entry),
        }
    }

    fn checkSource(self: *Router, source: contract.Source) Error!fs.service.Provider {
        return switch (source) {
            .entry => |entry| {
                const provider = try self.checkRoot(entry.root);
                try checkEntry(entry.root, entry.ref);
                return provider;
            },
            .lease => |lease| {
                return self.checkLease(lease);
            },
        };
    }

    pub fn capabilities(self: *Router, root: contract.Root) Error!contract.Capabilities {
        const provider = try self.checkRoot(root);
        return provider.capabilities(root);
    }

    /// Compare two roots through their owning provider. The router only
    /// rejects cross-authority comparisons; identity remains provider policy.
    pub fn sameRoot(self: *const Router, left: contract.Root, right: contract.Root) Error!bool {
        if (left.authority != right.authority) return false;
        const provider = try self.providerFor(left.authority);
        return provider.sameRoot(left, right);
    }

    /// Ask the owning provider to derive a confined root from a guarded entry.
    /// The router validates only the portable authority envelope; the provider
    /// owns the namespace identity, revision, and no-follow checks.
    pub fn deriveRoot(self: *Router, source: contract.EntrySource) Error!contract.Root {
        const provider = try self.checkRoot(source.root);
        try checkEntry(source.root, source.ref);
        const root = try provider.deriveRoot(source);
        if (root.generation == 0 or root.authority != source.root.authority) return error.InvalidHandle;
        return root;
    }

    /// Release a provider-owned root through its authority route. This keeps
    /// descriptor/handle lifetime out of target and plugin registries.
    pub fn releaseRoot(self: *Router, root: contract.Root) Error!void {
        if (root.generation == 0) return error.InvalidHandle;
        const provider = try self.providerFor(root.authority);
        provider.releaseRoot(root);
    }

    pub fn observe(self: *Router, allocator: std.mem.Allocator, root: contract.Root, node: contract.NodeRef) Error!contract.OwnedObservation {
        const provider = try self.checkRoot(root);
        try checkNode(root, node);
        return provider.observe(allocator, root, node);
    }

    pub fn list(self: *Router, allocator: std.mem.Allocator, root: contract.Root, directory: contract.NodeRef) Error!contract.OwnedListing {
        const provider = try self.checkRoot(root);
        try checkNode(root, directory);
        return provider.list(allocator, root, directory);
    }

    pub fn read(self: *Router, allocator: std.mem.Allocator, request: contract.ReadRequest) Error!contract.OwnedReadResult {
        const provider = try self.checkSource(request.source);
        return provider.read(allocator, request);
    }

    /// Capture before a dired/tool session loses its namespace address. The
    /// provider owns the durable bytes/descriptor behind the returned opaque
    /// lease; the router only validates the source authority and preserves it
    /// in the portable value.
    pub fn capture(self: *Router, source: contract.EntrySource) Error!contract.LeaseSource {
        const provider = try self.checkRoot(source.root);
        try checkEntry(source.root, source.ref);
        const ref = try provider.capture(source);
        if (ref.generation == 0 or ref.authority != source.root.authority) return error.InvalidHandle;
        return .{ .root = source.root, .ref = ref };
    }

    /// Release is intentionally idempotent at the provider boundary. A
    /// stale/released lease is harmless, while a live lease is made unusable
    /// before its backing storage is reclaimed by the provider.
    pub fn release(self: *Router, source: contract.LeaseSource) Error!void {
        const provider = try self.checkLease(source);
        provider.releaseLease(source);
    }

    /// Validate the complete plan and every embedded authority before handing
    /// it to a provider.  Cross-provider plans are intentionally unsupported
    /// until a future explicit bridge operation is introduced; a source is
    /// never reinterpreted relative to the destination root.
    pub fn apply(self: *Router, allocator: std.mem.Allocator, effect_plan: contract.Plan) Error!contract.OwnedApplyReport {
        try fs.plan.validate(allocator, effect_plan);
        const provider = try self.checkRoot(effect_plan.root);
        try checkPlanAuthorities(self, effect_plan);
        return provider.apply(allocator, effect_plan);
    }

    fn checkPlanAuthorities(self: *Router, effect_plan: contract.Plan) Error!void {
        for (effect_plan.operations) |planned| {
            const operation = planned.operation;
            switch (operation) {
                .create_file => |create| try checkCreateAuthorities(self, effect_plan.root, create.destination, create.expected),
                .create_directory => |create| try checkCreateAuthorities(self, effect_plan.root, create.destination, create.expected),
                .create_symlink => |create| {
                    try checkCreateAuthorities(self, effect_plan.root, create.destination, create.expected);
                },
                .copy => |copy| {
                    try checkSourceForPlan(self, effect_plan.root.authority, copy.source);
                    try checkCreateAuthorities(self, effect_plan.root, copy.destination, copy.expected);
                },
                .rename => |rename| {
                    try checkSourceForPlan(self, effect_plan.root.authority, .{ .entry = rename.source });
                    try checkCreateAuthorities(self, effect_plan.root, rename.destination, rename.expected);
                },
                .remove => |remove| try checkSourceForPlan(self, effect_plan.root.authority, .{ .entry = remove.source }),
                .set_permissions => |permissions| try checkSourceForPlan(self, effect_plan.root.authority, .{ .entry = permissions.source }),
            }
        }
    }

    fn checkCreateAuthorities(
        self: *Router,
        root: contract.Root,
        destination: contract.Slot,
        expected: contract.Expected,
    ) Error!void {
        switch (destination.parent) {
            .root, .planned => {},
            .entry => |entry| try checkEntry(root, entry),
        }
        switch (expected) {
            .anything, .absent => {},
            .entry => |entry| {
                _ = try checkRoot(self, root);
                try checkEntry(root, entry.ref);
            },
        }
    }

    fn checkSourceForPlan(self: *Router, destination_authority: semantic.handle.Authority, source: contract.Source) Error!void {
        _ = try self.checkSource(source);
        const source_authority = switch (source) {
            .entry => |entry| entry.root.authority,
            .lease => |lease| lease.root.authority,
        };
        if (source_authority != destination_authority) return error.Unsupported;
    }

    pub fn watch(self: *Router, root: contract.Root, directory: contract.NodeRef, recursive: bool) Error!contract.WatchRef {
        const provider = try self.checkRoot(root);
        try checkNode(root, directory);
        const watch_ref = try provider.watch(root, directory, recursive);
        if (watch_ref.generation == 0 or watch_ref.authority != root.authority) return error.InvalidHandle;
        return watch_ref;
    }

    pub fn pollInvalidation(self: *Router, watch_ref: contract.WatchRef) Error!?contract.Invalidation {
        if (watch_ref.generation == 0) return error.InvalidHandle;
        const provider = try self.providerFor(watch_ref.authority);
        return provider.pollInvalidation(watch_ref);
    }

    pub fn closeWatch(self: *Router, watch_ref: contract.WatchRef) Error!void {
        if (watch_ref.generation == 0) return error.InvalidHandle;
        const provider = try self.providerFor(watch_ref.authority);
        provider.closeWatch(watch_ref);
    }
};

test {
    _ = Router;
}

const TestProvider = struct {
    authority: semantic.handle.Authority,
    observed_kind: contract.Kind = .directory,
    observed_revision: []const u8 = &.{},
    capabilities_calls: usize = 0,
    observe_calls: usize = 0,
    list_calls: usize = 0,
    read_calls: usize = 0,
    release_calls: usize = 0,
    source_root_closed: bool = false,
    apply_calls: usize = 0,
    watch_calls: usize = 0,
    poll_calls: usize = 0,
    close_calls: usize = 0,

    fn asProvider(self: *TestProvider) fs.service.Provider {
        return fs.service.Provider.init(self);
    }

    pub fn capabilities(self: *TestProvider, root: contract.Root) contract.Error!contract.Capabilities {
        if (root.authority != self.authority) return error.Confined;
        self.capabilities_calls += 1;
        return .{ .watch = .invalidation };
    }

    pub fn sameRoot(self: *TestProvider, left: contract.Root, right: contract.Root) contract.Error!bool {
        if (left.authority != self.authority or right.authority != self.authority) return error.Confined;
        return left.eql(right);
    }

    pub fn deriveRoot(self: *TestProvider, source: contract.EntrySource) contract.Error!contract.Root {
        if (source.root.authority != self.authority) return error.Confined;
        return source.root;
    }

    pub fn releaseRoot(_: *TestProvider, _: contract.Root) void {}

    pub fn observe(self: *TestProvider, gpa: std.mem.Allocator, root: contract.Root, node: contract.NodeRef) contract.Error!contract.OwnedObservation {
        if (root.authority != self.authority) return error.Confined;
        self.observe_calls += 1;
        var result = contract.OwnedObservation.init(gpa);
        result.value = .{ .node = node, .revision = .{ .token = self.observed_revision }, .kind = self.observed_kind };
        return result;
    }

    pub fn list(self: *TestProvider, gpa: std.mem.Allocator, root: contract.Root, node: contract.NodeRef) contract.Error!contract.OwnedListing {
        if (root.authority != self.authority) return error.Confined;
        self.list_calls += 1;
        var result = contract.OwnedListing.init(gpa);
        result.value = .{ .directory = .{ .node = node, .revision = .{ .token = &.{} }, .kind = .directory }, .revision = .{ .token = &.{} }, .entries = &.{} };
        return result;
    }

    pub fn read(self: *TestProvider, gpa: std.mem.Allocator, request: contract.ReadRequest) contract.Error!contract.OwnedReadResult {
        const source_authority = switch (request.source) {
            .entry => |entry| blk: {
                if (self.source_root_closed) return error.Stale;
                break :blk entry.root.authority;
            },
            // A provider-owned lease remains usable after the source root is
            // closed. The router must therefore route this by authority and
            // leave root/lease-slot liveness to the provider.
            .lease => |lease| lease.root.authority,
        };
        if (source_authority != self.authority) return error.Confined;
        self.read_calls += 1;
        var result = contract.OwnedReadResult.init(gpa);
        result.value = .{ .observation = .{ .node = .root, .revision = .{ .token = &.{} }, .kind = .regular }, .bytes = &.{}, .eof = true };
        return result;
    }

    pub fn capture(self: *TestProvider, source: contract.EntrySource) contract.Error!contract.LeaseRef {
        if (source.root.authority != self.authority or source.ref.authority != self.authority) return error.Confined;
        return .{ .authority = self.authority, .slot = 7, .generation = 1 };
    }

    pub fn releaseLease(self: *TestProvider, _: contract.LeaseSource) void {
        self.release_calls += 1;
    }

    pub fn apply(self: *TestProvider, gpa: std.mem.Allocator, effect_plan: contract.Plan) contract.Error!contract.OwnedApplyReport {
        if (effect_plan.root.authority != self.authority) return error.Confined;
        self.apply_calls += 1;
        var result = contract.OwnedApplyReport.init(gpa);
        result.value = .{ .entries = &.{} };
        return result;
    }

    pub fn watch(self: *TestProvider, root: contract.Root, _: contract.NodeRef, _: bool) contract.Error!contract.WatchRef {
        if (root.authority != self.authority) return error.Confined;
        self.watch_calls += 1;
        return .{ .authority = self.authority, .slot = 1, .generation = 1 };
    }

    pub fn pollInvalidation(self: *TestProvider, watch_ref: contract.WatchRef) contract.Error!?contract.Invalidation {
        if (watch_ref.authority != self.authority) return error.Confined;
        self.poll_calls += 1;
        return null;
    }

    pub fn closeWatch(self: *TestProvider, watch_ref: contract.WatchRef) void {
        if (watch_ref.authority == self.authority) self.close_calls += 1;
    }
};

fn makeRoot(authority: semantic.handle.Authority) contract.Root {
    return .{ .authority = authority, .slot = 0, .generation = 1 };
}

fn makeEntry(authority: semantic.handle.Authority) contract.EntryRef {
    return .{ .authority = authority, .slot = 0, .generation = 1 };
}

test "routes local, remote, and synthetic authorities" {
    var local = TestProvider{ .authority = .here };
    var remote = TestProvider{ .authority = @enumFromInt(10) };
    var synthetic = TestProvider{ .authority = @enumFromInt(11) };
    var router = Router.init(std.testing.allocator);
    defer router.deinit();
    try router.register(local.authority, local.asProvider());
    try router.register(remote.authority, remote.asProvider());
    try router.register(synthetic.authority, synthetic.asProvider());

    _ = try router.capabilities(makeRoot(local.authority));
    _ = try router.observe(std.testing.allocator, makeRoot(remote.authority), .root);
    var listing = try router.list(std.testing.allocator, makeRoot(synthetic.authority), .root);
    listing.deinit();
    var read_result = try router.read(std.testing.allocator, .{ .source = .{ .entry = .{ .root = makeRoot(remote.authority), .ref = makeEntry(remote.authority), .revision = .{ .token = &.{} } } } });
    read_result.deinit();
    try std.testing.expectEqual(@as(usize, 1), local.capabilities_calls);
    try std.testing.expectEqual(@as(usize, 1), remote.observe_calls);
    try std.testing.expectEqual(@as(usize, 1), remote.read_calls);
    try std.testing.expectEqual(@as(usize, 1), synthetic.list_calls);
}

test "leases route by provider authority after their source root closes" {
    var local = TestProvider{ .authority = .here };
    var router = Router.init(std.testing.allocator);
    defer router.deinit();
    try router.register(.here, local.asProvider());

    const root = makeRoot(.here);
    const lease = try router.capture(.{ .root = root, .ref = makeEntry(.here), .revision = .{ .token = &.{} } });

    // Closing the namespace invalidates ordinary entry operations, but does
    // not revoke the provider-owned materialization represented by `lease`.
    // The state boundary is owned by the concrete provider, while the router
    // only sees the authority.
    local.source_root_closed = true;
    try std.testing.expectError(error.Stale, router.read(std.testing.allocator, .{ .source = .{ .entry = .{
        .root = root,
        .ref = makeEntry(.here),
        .revision = .{ .token = &.{} },
    } } }));
    var read_result = try router.read(std.testing.allocator, .{ .source = .{ .lease = lease } });
    read_result.deinit();
    try router.release(lease);
    try std.testing.expectEqual(@as(usize, 1), local.read_calls);
    try std.testing.expectEqual(@as(usize, 1), local.release_calls);

    // A lease reference from another authority is not allowed to reach a
    // provider, even though its shape is otherwise valid.
    const forged = contract.LeaseSource{ .root = root, .ref = .{ .authority = @enumFromInt(10), .slot = 7, .generation = 1 } };
    try std.testing.expectError(error.InvalidHandle, router.validateLease(forged));
    try std.testing.expectError(error.InvalidHandle, router.release(forged));
}

test "unregister rejects stale and unknown authorities" {
    var local = TestProvider{ .authority = .here };
    var router = Router.init(std.testing.allocator);
    defer router.deinit();
    try router.register(.here, local.asProvider());
    try router.unregister(.here);
    try std.testing.expectError(error.AuthorityRetired, router.capabilities(makeRoot(.here)));
    try std.testing.expectError(error.AuthorityRetired, router.register(.here, local.asProvider()));
    try std.testing.expectError(error.UnknownAuthority, router.capabilities(makeRoot(@enumFromInt(91))));
    try std.testing.expectError(error.AuthorityRetired, router.pollInvalidation(.{ .authority = .here, .slot = 0, .generation = 1 }));
}

test "target bindings are explicit, revision-stamped, and retired with their authority" {
    var provider = TestProvider{ .authority = .here };
    var router = Router.init(std.testing.allocator);
    defer router.deinit();
    const target: semantic.target.Ref = .{ .authority = .here, .slot = 4, .generation = 3 };
    const directory: fs.target.Directory = .{ .root = makeRoot(.here), .node = .root };
    try std.testing.expectError(error.TargetUnbound, router.authorizedDirectory(target, 1));
    try std.testing.expectError(error.UnknownAuthority, router.bindTarget(target, 1, directory));
    try router.register(.here, provider.asProvider());
    try router.bindTarget(target, 1, directory);
    try std.testing.expectEqual(directory, try router.authorizedDirectory(target, 1));
    try std.testing.expectError(error.StaleTarget, router.authorizedDirectory(target, 2));
    try std.testing.expectError(error.InvalidHandle, router.bindTarget(target, 0, directory));
    try std.testing.expectError(error.TargetAlreadyBound, router.bindTarget(target, 1, directory));
    try std.testing.expect(router.unbindTarget(target));
    try std.testing.expectError(error.TargetUnbound, router.authorizedDirectory(target, 1));
    try router.bindTarget(target, 1, directory);
    try router.unregister(.here);
    try std.testing.expectError(error.TargetUnbound, router.authorizedDirectory(target, 1));
}

test "ordinary file bindings preserve provider entry identity and revision" {
    var provider = TestProvider{ .authority = .here, .observed_kind = .regular, .observed_revision = "file-r1" };
    var router = Router.init(std.testing.allocator);
    defer router.deinit();
    try router.register(.here, provider.asProvider());
    const target: semantic.target.Ref = .{ .authority = .here, .slot = 9, .generation = 1 };
    var source_revision = [_]u8{ 'f', 'i', 'l', 'e', '-', 'r', '1' };
    const source: fs.target.Entry = .{
        .root = makeRoot(.here),
        .ref = makeEntry(.here),
        .revision = .{ .token = &source_revision },
    };
    try router.bindEntry(target, 7, source);
    try std.testing.expectError(error.TargetAlreadyBound, router.bindEntry(target, 7, source));
    @memset(&source_revision, 'x');
    const authorized = try router.authorizedEntry(target, 7);
    try std.testing.expectEqual(source.root, authorized.root);
    try std.testing.expectEqual(source.ref, authorized.ref);
    try std.testing.expectEqualSlices(u8, "file-r1", authorized.revision.token);
    try std.testing.expectError(error.StaleTarget, router.authorizedEntry(target, 8));
    try std.testing.expect(router.unbindTarget(target));
    try std.testing.expectError(error.TargetUnbound, router.authorizedEntry(target, 7));
}

test "apply refuses a cross-provider plan before provider execution" {
    var local = TestProvider{ .authority = .here };
    var remote = TestProvider{ .authority = @enumFromInt(10) };
    var router = Router.init(std.testing.allocator);
    defer router.deinit();
    try router.register(local.authority, local.asProvider());
    try router.register(remote.authority, remote.asProvider());
    const operation: contract.Planned = .{
        .id = [_]u8{1} ** 16,
        .operation = .{ .copy = .{
            .source = .{ .entry = .{ .root = makeRoot(remote.authority), .ref = makeEntry(remote.authority), .revision = .{ .token = &.{} } } },
            .destination = .{ .parent = .root, .name = try contract.Name.init("copy") },
        } },
    };
    const operations = [_]contract.Planned{operation};
    const effect_plan: contract.Plan = .{ .root = makeRoot(.here), .base_revision = &.{}, .operations = &operations };
    try std.testing.expectError(error.Unsupported, router.apply(std.testing.allocator, effect_plan));
    try std.testing.expectEqual(@as(usize, 0), local.apply_calls);
    try std.testing.expectEqual(@as(usize, 0), remote.apply_calls);
}

test "watch poll and close route by watch authority" {
    var local = TestProvider{ .authority = .here };
    var remote = TestProvider{ .authority = @enumFromInt(10) };
    var router = Router.init(std.testing.allocator);
    defer router.deinit();
    try router.register(local.authority, local.asProvider());
    try router.register(remote.authority, remote.asProvider());
    const watch_ref = try router.watch(makeRoot(remote.authority), .root, true);
    _ = try router.pollInvalidation(watch_ref);
    try router.closeWatch(watch_ref);
    try std.testing.expectEqual(@as(usize, 0), local.watch_calls);
    try std.testing.expectEqual(@as(usize, 1), remote.watch_calls);
    try std.testing.expectEqual(@as(usize, 1), remote.poll_calls);
    try std.testing.expectEqual(@as(usize, 1), remote.close_calls);
}
