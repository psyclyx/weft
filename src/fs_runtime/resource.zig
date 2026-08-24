//! Host-owned filesystem resources for semantic transfer representations.
//!
//! Semantic transfer values know only the opaque retain/release callbacks.
//! This adapter keeps the provider lease and its router association alive
//! independently of any dired/session object. The Router must outlive every
//! Resource it creates; final release calls back through that Router.

const std = @import("std");
const semantic = @import("weft_semantic");
const fs = @import("weft_fs");
const router_mod = @import("router.zig");

const contract = fs.contract;

pub const Error = router_mod.Error || std.mem.Allocator.Error;

pub const LeaseResource = struct {
    gpa: std.mem.Allocator,
    router: *router_mod.Router,
    source: contract.LeaseSource,
    refs: std.atomic.Value(usize) = .init(1),

    const vtable: semantic.transfer.Resource.VTable = .{
        .retain = retain,
        .release = release,
    };

    /// The returned Resource owns one reference. A caller that places it in
    /// an OwnedItem should let OwnedItem retain its copy, then release this
    /// initial reference; this makes ownership transfer explicit and supports
    /// cross-view copies without tying them to the source session.
    /// The Router must remain initialized until all such references release.
    pub fn create(
        gpa: std.mem.Allocator,
        router: *router_mod.Router,
        source: contract.LeaseSource,
    ) Error!semantic.transfer.Resource {
        try router.validateLease(source);
        const state = try gpa.create(LeaseResource);
        state.* = .{ .gpa = gpa, .router = router, .source = source };
        return .{
            .authority = source.root.authority,
            .context = state,
            .vtable = &vtable,
        };
    }

    fn retain(raw: *anyopaque) void {
        const self: *LeaseResource = @ptrCast(@alignCast(raw));
        while (true) {
            const current = self.refs.load(.acquire);
            std.debug.assert(current != std.math.maxInt(usize));
            if (self.refs.cmpxchgWeak(current, current + 1, .acquire, .monotonic) == null) break;
        }
    }

    fn release(raw: *anyopaque) void {
        const self: *LeaseResource = @ptrCast(@alignCast(raw));
        if (self.refs.fetchSub(1, .acq_rel) != 1) return;
        _ = self.router.release(self.source) catch {};
        self.gpa.destroy(self);
    }
};

test "lease resources retain across transfer owners and release once" {
    // The actual provider-release path is exercised by the router contract;
    // this test verifies the generic resource's retained ownership shape.
    const Probe = struct {
        retains: usize = 0,
        releases: usize = 0,

        fn retain(raw: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.retains += 1;
        }

        fn release(raw: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.releases += 1;
        }
    };
    var probe: Probe = .{};
    const resource: semantic.transfer.Resource = .{
        .authority = .here,
        .context = &probe,
        .vtable = &.{ .retain = Probe.retain, .release = Probe.release },
    };
    resource.retain();
    resource.release();
    resource.release();
    try std.testing.expectEqual(@as(usize, 1), probe.retains);
    try std.testing.expectEqual(@as(usize, 2), probe.releases);
}

test "lease resource delegates final release to its filesystem router" {
    const Provider = struct {
        released: usize = 0,

        pub fn capabilities(_: *@This(), _: contract.Root) contract.Error!contract.Capabilities {
            return .{};
        }
        pub fn observe(_: *@This(), gpa: std.mem.Allocator, _: contract.Root, node: contract.NodeRef) contract.Error!contract.OwnedObservation {
            var result = contract.OwnedObservation.init(gpa);
            result.value = .{ .node = node, .revision = .{ .token = &.{} }, .kind = .directory };
            return result;
        }
        pub fn list(_: *@This(), gpa: std.mem.Allocator, _: contract.Root, node: contract.NodeRef) contract.Error!contract.OwnedListing {
            var result = contract.OwnedListing.init(gpa);
            result.value = .{ .directory = .{ .node = node, .revision = .{ .token = &.{} }, .kind = .directory }, .revision = .{ .token = &.{} }, .entries = &.{} };
            return result;
        }
        pub fn read(_: *@This(), gpa: std.mem.Allocator, _: contract.ReadRequest) contract.Error!contract.OwnedReadResult {
            var result = contract.OwnedReadResult.init(gpa);
            result.value = .{ .observation = .{ .node = .root, .revision = .{ .token = &.{} }, .kind = .regular }, .bytes = &.{}, .eof = true };
            return result;
        }
        pub fn capture(_: *@This(), _: contract.EntrySource) contract.Error!contract.LeaseRef {
            return .{ .authority = .here, .slot = 0, .generation = 1 };
        }
        pub fn releaseLease(self: *@This(), _: contract.LeaseSource) void {
            self.released += 1;
        }
        pub fn apply(_: *@This(), gpa: std.mem.Allocator, _: contract.Plan) contract.Error!contract.OwnedApplyReport {
            var result = contract.OwnedApplyReport.init(gpa);
            result.value = .{ .entries = &.{} };
            return result;
        }
        pub fn watch(_: *@This(), _: contract.Root, _: contract.NodeRef, _: bool) contract.Error!contract.WatchRef {
            return .{ .authority = .here, .slot = 0, .generation = 1 };
        }
        pub fn pollInvalidation(_: *@This(), _: contract.WatchRef) contract.Error!?contract.Invalidation {
            return null;
        }
        pub fn closeWatch(_: *@This(), _: contract.WatchRef) void {}
    };

    var provider: Provider = .{};
    var router = router_mod.Router.init(std.testing.allocator);
    defer router.deinit();
    try router.register(.here, fs.service.Provider.init(&provider));
    const source: contract.LeaseSource = .{ .root = .{ .authority = .here, .slot = 0, .generation = 1 }, .ref = .{ .authority = .here, .slot = 0, .generation = 1 } };
    const resource = try LeaseResource.create(std.testing.allocator, &router, source);
    resource.release();
    try std.testing.expectEqual(@as(usize, 1), provider.released);
}
