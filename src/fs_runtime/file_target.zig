//! Generic ordinary-file target handler integration.
//!
//! Filesystem providers own observations and bytes; target dispatch owns only
//! opaque semantic identities. `Handler` composes those interfaces for a
//! plugin that wants to open regular-file targets, without teaching core
//! about paths, local/remote authorities, or buffer implementations.

const std = @import("std");
const semantic = @import("weft_semantic");
const fs = @import("weft_fs");
const target_runtime = @import("weft_target_runtime");

const contract = fs.contract;
const resolver = target_runtime.resolver;
const router_mod = @import("router.zig");

pub const Error = resolver.OpenError || router_mod.Error;

pub const ViewFactory = struct {
    context: *anyopaque,
    open: *const fn (*anyopaque, semantic.target.Located, *contract.OwnedReadResult) resolver.OpenError!semantic.view.Ref,

    pub fn init(pointer: anytype) ViewFactory {
        const Pointer = @TypeOf(pointer);
        const info = switch (@typeInfo(Pointer)) {
            .pointer => |value| value,
            else => @compileError("ordinary-file view factory must be initialized from a pointer"),
        };
        if (info.size != .one or info.is_const)
            @compileError("ordinary-file view factory requires a mutable pointer");
        const Implementation = info.child;
        const Adapter = struct {
            fn self(raw: *anyopaque) *Implementation {
                return @ptrCast(@alignCast(raw));
            }
            fn open(raw: *anyopaque, located: semantic.target.Located, result: *contract.OwnedReadResult) resolver.OpenError!semantic.view.Ref {
                return self(raw).open(located, result);
            }
            const open_fn = @This().open;
        };
        return .{ .context = pointer, .open = Adapter.open_fn };
    }
};

pub const Handler = struct {
    allocator: std.mem.Allocator,
    targets: *const target_runtime.target.Registry,
    router: *router_mod.Router,
    factory: ViewFactory,

    pub fn probe(self: *Handler, descriptor: semantic.target.Descriptor) resolver.ProbeError!?resolver.Strength {
        _ = self;
        if (descriptor.kind != .file) return null;
        const entry = fs.target.findEntry(descriptor.facts) catch return error.InvalidTarget;
        return if (entry != null) .exact else null;
    }

    pub fn open(self: *Handler, located: semantic.target.Located) resolver.OpenError!semantic.view.Ref {
        const descriptor = self.targets.get(located.target) orelse return error.StaleTarget;
        if (descriptor.revision != located.revision or descriptor.kind != .file)
            return error.StaleTarget;
        const maybe_entry = fs.target.findEntry(descriptor.facts) catch return error.Failed;
        const entry = maybe_entry orelse return error.Rejected;
        const authorized = self.router.authorizedEntry(located.target, located.revision) catch |err| return mapError(err);
        if (!sameEntry(entry, authorized)) return error.StaleTarget;
        var result = self.router.read(self.allocator, .{ .source = .{ .entry = .{
            .root = authorized.root,
            .ref = authorized.ref,
            .revision = authorized.revision,
        } } }) catch |err| return mapError(err);
        defer result.deinit();
        return self.factory.open(self.factory.context, located, &result);
    }

    fn sameEntry(left: fs.target.Entry, right: fs.target.Entry) bool {
        return left.root.eql(right.root) and left.ref.eql(right.ref) and
            std.mem.eql(u8, left.revision.token, right.revision.token);
    }
};

fn mapError(err: anyerror) resolver.OpenError {
    return switch (err) {
        error.Stale, error.StaleTarget, error.NotFound => error.StaleTarget,
        error.Unsupported, error.Unavailable, error.PermissionDenied => error.Unavailable,
        error.Rejected => error.Rejected,
        else => error.Failed,
    };
}

test "ordinary-file handler claims only canonical file attachments" {
    const target: semantic.target.Ref = .{ .authority = .here, .slot = 1, .generation = 1 };
    const descriptor: semantic.target.Descriptor = .{
        .ref = target,
        .revision = 2,
        .kind = .file,
        .display_name = "notes",
        .facts = &.{},
    };
    var targets = target_runtime.target.Registry.init(.here);
    defer targets.deinit(std.testing.allocator);
    var router = router_mod.Router.init(std.testing.allocator);
    defer router.deinit();
    var factory = struct {
        pub fn open(_: *@This(), _: semantic.target.Located, _: *contract.OwnedReadResult) resolver.OpenError!semantic.view.Ref {
            return .{ .authority = .here, .slot = 3, .generation = 1 };
        }
    }{};
    var handler = Handler{ .allocator = std.testing.allocator, .targets = &targets, .router = &router, .factory = ViewFactory.init(&factory) };
    try std.testing.expectEqual(@as(?resolver.Strength, null), try handler.probe(descriptor));
    var directory = descriptor;
    directory.kind = .directory;
    try std.testing.expectEqual(@as(?resolver.Strength, null), try handler.probe(directory));
}

const TestProvider = struct {
    pub fn capabilities(_: *@This(), _: contract.Root) contract.Error!contract.Capabilities {
        return .{};
    }
    pub fn sameRoot(_: *@This(), left: contract.Root, right: contract.Root) contract.Error!bool {
        return left.eql(right);
    }
    pub fn deriveRoot(_: *@This(), _: contract.EntrySource) contract.Error!contract.Root {
        return error.Unsupported;
    }
    pub fn releaseRoot(_: *@This(), _: contract.Root) void {}
    pub fn observe(_: *@This(), gpa: std.mem.Allocator, root: contract.Root, node: contract.NodeRef) contract.Error!contract.OwnedObservation {
        var owned = contract.OwnedObservation.init(gpa);
        owned.value = .{ .node = node, .revision = .{ .token = "r1" }, .kind = .regular };
        _ = root;
        return owned;
    }
    pub fn list(_: *@This(), _: std.mem.Allocator, _: contract.Root, _: contract.NodeRef) contract.Error!contract.OwnedListing {
        return error.Unsupported;
    }
    pub fn read(_: *@This(), gpa: std.mem.Allocator, request: contract.ReadRequest) contract.Error!contract.OwnedReadResult {
        var owned = contract.OwnedReadResult.init(gpa);
        owned.value = .{
            .observation = .{ .node = switch (request.source) {
                .entry => |entry| .{ .entry = entry.ref },
                .lease => .root,
            }, .revision = .{ .token = "r1" }, .kind = .regular },
            .bytes = try owned.allocator().dupe(u8, "hello"),
            .eof = true,
        };
        return owned;
    }
    pub fn capture(_: *@This(), _: contract.EntrySource) contract.Error!contract.LeaseRef {
        return error.Unsupported;
    }
    pub fn releaseLease(_: *@This(), _: contract.LeaseSource) void {}
    pub fn apply(_: *@This(), _: std.mem.Allocator, _: contract.Plan) contract.Error!contract.OwnedApplyReport {
        return error.Unsupported;
    }
    pub fn watch(_: *@This(), _: contract.Root, _: contract.NodeRef, _: bool) contract.Error!contract.WatchRef {
        return error.Unsupported;
    }
    pub fn pollInvalidation(_: *@This(), _: contract.WatchRef) contract.Error!?contract.Invalidation {
        return error.Unsupported;
    }
    pub fn closeWatch(_: *@This(), _: contract.WatchRef) void {}
};

test "ordinary-file handler opens through the provider and hands bytes to a view factory" {
    const gpa = std.testing.allocator;
    const owner: semantic.owner.Id = @enumFromInt(1);
    const root: contract.Root = .{ .authority = .here, .slot = 2, .generation = 1 };
    const source = fs.target.Entry{
        .root = root,
        .ref = .{ .authority = .here, .slot = 3, .generation = 1 },
        .revision = .{ .token = "r1" },
    };
    var provider = TestProvider{};
    var router = router_mod.Router.init(gpa);
    defer router.deinit();
    try router.register(.here, .init(&provider));
    var targets = target_runtime.target.Registry.init(.here);
    defer targets.deinit(gpa);
    const encoded = try fs.target.encodeEntry(gpa, source);
    defer gpa.free(encoded);
    const target = try targets.publish(gpa, owner, .{
        .kind = .file,
        .display_name = "notes",
        .facts = &.{.{ .name = fs.target.entry_fact_name, .value = encoded }},
    });
    const descriptor = targets.get(target).?;
    try router.bindEntry(target, descriptor.revision, source);

    const Factory = struct {
        bytes: []const u8 = &.{},
        pub fn open(self: *@This(), _: semantic.target.Located, result: *contract.OwnedReadResult) resolver.OpenError!semantic.view.Ref {
            self.bytes = result.value.bytes;
            return .{ .authority = .here, .slot = 8, .generation = 1 };
        }
    };
    var factory = Factory{};
    var handler = Handler{ .allocator = gpa, .targets = &targets, .router = &router, .factory = ViewFactory.init(&factory) };
    try std.testing.expectEqual(.exact, try handler.probe(descriptor.*));
    const opened = try handler.open(.{ .target = target, .revision = descriptor.revision });
    try std.testing.expectEqual(@as(u32, 8), opened.slot);
    try std.testing.expectEqualStrings("hello", factory.bytes);
    try std.testing.expectError(error.StaleTarget, handler.open(.{ .target = target, .revision = descriptor.revision + 1 }));
}
