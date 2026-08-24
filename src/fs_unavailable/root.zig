//! Platform provider placeholder used until a host implementation is selected.
//!
//! This preserves the app-facing `Provider` shape on Darwin while returning
//! explicit Unsupported results. Replacing this build-selected module with a
//! Darwin implementation requires no core, plugin, or app call-site changes.

const std = @import("std");
const fs = @import("weft_fs");

const contract = fs.contract;

pub const Provider = struct {
    pub fn init(_: std.mem.Allocator) Provider {
        return .{};
    }

    pub fn deinit(_: *Provider) void {}

    pub fn provider(self: *Provider) fs.service.Provider {
        return .init(self);
    }

    pub fn acquireRoot(_: *Provider, _: []const u8) contract.Error!contract.Root {
        return error.Unsupported;
    }

    pub fn sameRoot(_: *Provider, _: contract.Root, _: contract.Root) contract.Error!bool {
        return error.Unsupported;
    }

    pub fn deriveRoot(_: *Provider, _: contract.EntrySource) contract.Error!contract.Root {
        return error.Unsupported;
    }

    pub fn releaseRoot(_: *Provider, _: contract.Root) void {}

    pub fn acquireParent(_: *Provider, _: contract.Root) contract.Error!?contract.Root {
        return error.Unsupported;
    }

    pub fn capabilities(_: *Provider, _: contract.Root) contract.Error!contract.Capabilities {
        return error.Unsupported;
    }

    pub fn observe(_: *Provider, _: std.mem.Allocator, _: contract.Root, _: contract.NodeRef) contract.Error!contract.OwnedObservation {
        return error.Unsupported;
    }

    pub fn list(_: *Provider, _: std.mem.Allocator, _: contract.Root, _: contract.NodeRef) contract.Error!contract.OwnedListing {
        return error.Unsupported;
    }

    pub fn read(_: *Provider, _: std.mem.Allocator, _: contract.ReadRequest) contract.Error!contract.OwnedReadResult {
        return error.Unsupported;
    }

    pub fn capture(_: *Provider, _: contract.EntrySource) contract.Error!contract.LeaseRef {
        return error.Unsupported;
    }

    pub fn releaseLease(_: *Provider, _: contract.LeaseSource) void {}

    pub fn apply(_: *Provider, _: std.mem.Allocator, _: contract.Plan) contract.Error!contract.OwnedApplyReport {
        return error.Unsupported;
    }

    pub fn watch(_: *Provider, _: contract.Root, _: contract.NodeRef, _: bool) contract.Error!contract.WatchRef {
        return error.Unsupported;
    }

    pub fn pollInvalidation(_: *Provider, _: contract.WatchRef) contract.Error!?contract.Invalidation {
        return error.Unsupported;
    }

    pub fn closeWatch(_: *Provider, _: contract.WatchRef) void {}
};

test "unavailable platform provider fails explicitly" {
    var provider = Provider.init(std.testing.allocator);
    defer provider.deinit();
    try std.testing.expectError(error.Unsupported, provider.acquireRoot("."));
}
