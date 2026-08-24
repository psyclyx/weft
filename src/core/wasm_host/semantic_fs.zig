//! Generic target-scoped filesystem transport for sandboxed plugins.
//!
//! This is deliberately not a dired door.  A plugin presents a semantic
//! target and its descriptor revision; the host re-reads the live descriptor,
//! extracts the ordinary `weft.fs.directory.v1` fact, and routes the typed
//! operation through the platform-neutral filesystem router.  Root and entry
//! handles are identifiers only.  They are never accepted as capabilities on
//! their own.

const std = @import("std");
const wasm = @import("../wasm.zig");
const semantic = @import("weft_semantic");
const fs = @import("weft_fs");
const fs_codec = @import("weft_fs_codec");
const fs_runtime = @import("weft_fs_runtime");

const shared = @import("plugin.zig");
const WasmPlugin = shared.WasmPlugin;
const requirePerm = shared.requirePerm;
const wire_util = @import("semantic_wire.zig");

/// A non-negative result is the encoded response length.  Negative values
/// are stable transport statuses, so a guest can distinguish stale target
/// state from an unavailable provider without guessing from an empty listing.
pub const Status = enum(i32) {
    unavailable = -1,
    stale_target = -2,
    unsupported = -3,
    invalid = -4,
    failed = -5,
    output_too_small = -6,
};

const AuthorizationError = error{
    Unavailable,
    StaleTarget,
    Unsupported,
    InvalidTarget,
};

pub const AuthorizedDirectory = struct {
    root: fs.contract.Root,
    node: fs.contract.NodeRef,
};

fn status(err: anyerror) i32 {
    return @intFromEnum(switch (err) {
        error.Unavailable => Status.unavailable,
        error.StaleTarget => Status.stale_target,
        error.Unsupported => Status.unsupported,
        error.InvalidTarget, error.InvalidDirectoryTarget => Status.invalid,
        else => Status.failed,
    });
}

fn revisionFromArgs(args: []const i32) u64 {
    const low: u64 = @as(u64, @as(u32, @bitCast(args[3])));
    const high: u64 = @as(u64, @as(u32, @bitCast(args[4])));
    return low | (high << 32);
}

fn targetFromArgs(args: []const i32) ?semantic.target.Ref {
    return wire_util.readHandle(semantic.target.Ref, args[0..3]);
}

/// Re-derive the filesystem authority from the live semantic target.  The
/// descriptor revision is part of the request specifically so replacing a
/// target cannot retarget an old plugin request to a different directory.
pub fn authorizeDirectory(
    router: *const fs_runtime.Router,
    descriptor: semantic.target.Descriptor,
    target: semantic.target.Ref,
    revision: u64,
) AuthorizationError!AuthorizedDirectory {
    if (descriptor.ref.eql(target)) {} else return error.StaleTarget;
    if (descriptor.revision != revision) return error.StaleTarget;
    if (descriptor.kind != .directory) return error.Unsupported;
    const directory = fs.target.find(descriptor.facts) catch return error.InvalidTarget;
    const value = directory orelse return error.Unsupported;
    const bound = router.authorizedDirectory(target, revision) catch |err| switch (err) {
        error.StaleTarget => return error.StaleTarget,
        error.TargetUnbound => return error.InvalidTarget,
        else => return error.InvalidTarget,
    };
    if (!sameRoot(value.root, bound.root) or !sameNode(value.node, bound.node)) return error.InvalidTarget;
    // A target attached to an existing entry is not a confinement boundary:
    // the plan contract names only its provider root. Until providers mint a
    // genuinely confined subroot, sandbox calls must stay root-backed.
    switch (bound.node) {
        .root => {},
        .entry => return error.Unsupported,
    }
    return .{ .root = bound.root, .node = bound.node };
}

fn authorize(plugin: *WasmPlugin, target: semantic.target.Ref, revision: u64) AuthorizationError!AuthorizedDirectory {
    const scope = plugin.semanticScope() orelse return error.Unavailable;
    const router = plugin.activeCtx().filesystems orelse return error.Unavailable;
    const descriptor = scope.services.targets.get(target) orelse return error.StaleTarget;
    return authorizeDirectory(router, descriptor.*, target, revision);
}

fn sameRoot(a: fs.contract.Root, b: fs.contract.Root) bool {
    return a.authority == b.authority and a.slot == b.slot and a.generation == b.generation;
}

fn sameNode(a: fs.contract.NodeRef, b: fs.contract.NodeRef) bool {
    return switch (a) {
        .root => b == .root,
        .entry => |left| switch (b) {
            .root => false,
            .entry => |right| left.eql(right),
        },
    };
}

pub fn requireUnrestricted(plugin: *WasmPlugin, caller: *wasm.Caller, comptime perm: shared.Perm) bool {
    switch (shared.limitFor(plugin, perm)) {
        .none => return true,
        .fs_root, .doc_region, .graph_subtree => {
            caller.trap("plugin '{s}' denied capability '{s}': typed filesystem targets cannot be proven against a path-limited grant", .{ plugin.name, perm.label() });
            return false;
        },
    }
}

/// V1 intentionally keeps the membrane's authority boundary simple and
/// explicit: a plan can only touch the root attached to its target, and
/// every captured source must name that same root.  Cross-root transfers need
/// a provider-issued durable lease; accepting a raw foreign root here would
/// turn an identifier into an ambient capability.
pub fn validatePlanRoot(effect_plan: fs.contract.Plan, authorized_root: fs.contract.Root) AuthorizationError!void {
    if (!sameRoot(effect_plan.root, authorized_root)) return error.Unsupported;
    for (effect_plan.operations) |planned| switch (planned.operation) {
        .copy => |copy| try validateSourceRoot(copy.source, authorized_root),
        .rename => |rename| try validateSourceRoot(.{ .entry = rename.source }, authorized_root),
        .remove => |remove| try validateSourceRoot(.{ .entry = remove.source }, authorized_root),
        .set_permissions => |permissions| try validateSourceRoot(.{ .entry = permissions.source }, authorized_root),
        .create_file, .create_directory, .create_symlink => {},
    };
}

fn validateSourceRoot(source: fs.contract.Source, authorized_root: fs.contract.Root) AuthorizationError!void {
    const root = switch (source) {
        .entry => |entry| entry.root,
        .lease => |lease| lease.root,
    };
    if (!sameRoot(root, authorized_root)) return error.Unsupported;
}

pub fn hList(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    const plugin: *WasmPlugin = @ptrCast(@alignCast(data.?));
    results[0] = @intFromEnum(Status.unavailable);
    if (!requirePerm(plugin, caller, .fs_read)) return;
    if (!requireUnrestricted(plugin, caller, .fs_read)) return;
    const target = targetFromArgs(args) orelse {
        results[0] = @intFromEnum(Status.invalid);
        return;
    };
    const authorized = authorize(plugin, target, revisionFromArgs(args)) catch |err| {
        results[0] = status(err);
        return;
    };
    const router = plugin.activeCtx().filesystems orelse return;
    var listing = router.list(plugin.gpa, authorized.root, authorized.node) catch |err| {
        results[0] = status(err);
        return;
    };
    defer listing.deinit();
    const encoded = fs_codec.encodeListing(plugin.gpa, listing.value) catch |err| {
        results[0] = status(err);
        return;
    };
    defer plugin.gpa.free(encoded);
    const out_ptr: u32 = @bitCast(args[5]);
    const out_cap: u32 = @bitCast(args[6]);
    if (out_cap < encoded.len) {
        results[0] = @intFromEnum(Status.output_too_small);
        return;
    }
    results[0] = @intCast(caller.writeMemory(out_ptr, out_cap, encoded) catch {
        results[0] = @intFromEnum(Status.failed);
        return;
    });
}

pub fn hApply(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    const plugin: *WasmPlugin = @ptrCast(@alignCast(data.?));
    results[0] = @intFromEnum(Status.unavailable);
    if (!requirePerm(plugin, caller, .fs_write)) return;
    if (!requireUnrestricted(plugin, caller, .fs_write)) return;
    const target = targetFromArgs(args) orelse {
        results[0] = @intFromEnum(Status.invalid);
        return;
    };
    const authorized = authorize(plugin, target, revisionFromArgs(args)) catch |err| {
        results[0] = status(err);
        return;
    };
    const plan_bytes = wire_util.readBounded(plugin.gpa, caller, args[5], args[6], 1, fs_codec.Limits.max_payload_bytes) orelse {
        results[0] = @intFromEnum(Status.invalid);
        return;
    };
    defer plugin.gpa.free(plan_bytes);
    var decoded = fs_codec.decodePlan(plugin.gpa, plan_bytes) catch |err| {
        results[0] = status(err);
        return;
    };
    defer decoded.deinit();
    validatePlanRoot(decoded.value, authorized.root) catch |err| {
        results[0] = status(err);
        return;
    };
    const router = plugin.activeCtx().filesystems orelse return;
    var report = router.apply(plugin.gpa, decoded.value) catch |err| {
        results[0] = status(err);
        return;
    };
    defer report.deinit();
    const encoded = fs_codec.encodeApplyReport(plugin.gpa, report.value) catch |err| {
        results[0] = status(err);
        return;
    };
    defer plugin.gpa.free(encoded);
    const out_ptr: u32 = @bitCast(args[7]);
    const out_cap: u32 = @bitCast(args[8]);
    if (out_cap < encoded.len) {
        results[0] = @intFromEnum(Status.output_too_small);
        return;
    }
    results[0] = @intCast(caller.writeMemory(out_ptr, out_cap, encoded) catch {
        results[0] = @intFromEnum(Status.failed);
        return;
    });
}

test "typed filesystem plans cannot cross the target root boundary" {
    const root: fs.contract.Root = .{ .authority = .here, .slot = 1, .generation = 2 };
    const foreign: fs.contract.Root = .{ .authority = .here, .slot = 3, .generation = 4 };
    const destination: fs.contract.Slot = .{ .parent = .root, .name = try .init("copy") };
    const source: fs.contract.EntrySource = .{ .root = foreign, .ref = .{ .authority = .here, .slot = 8, .generation = 1 }, .revision = .{ .token = &.{} } };
    const operations = [_]fs.contract.Planned{.{
        .id = [_]u8{1} ** 16,
        .operation = .{ .copy = .{ .source = .{ .entry = source }, .destination = destination } },
    }};
    try std.testing.expectError(error.Unsupported, validatePlanRoot(.{ .root = root, .base_revision = &.{}, .operations = &operations }, root));
}

test "typed filesystem authorization rejects forged facts and entry attachments" {
    const Provider = struct {
        pub fn capabilities(_: *@This(), _: fs.contract.Root) fs.contract.Error!fs.contract.Capabilities {
            return .{};
        }
        pub fn observe(_: *@This(), gpa: std.mem.Allocator, _: fs.contract.Root, node: fs.contract.NodeRef) fs.contract.Error!fs.contract.OwnedObservation {
            var owned = fs.contract.OwnedObservation.init(gpa);
            owned.value = .{ .node = node, .revision = .{ .token = &.{} }, .kind = .directory };
            return owned;
        }
        pub fn list(_: *@This(), _: std.mem.Allocator, _: fs.contract.Root, _: fs.contract.NodeRef) fs.contract.Error!fs.contract.OwnedListing {
            return error.Unsupported;
        }
        pub fn read(_: *@This(), _: std.mem.Allocator, _: fs.contract.ReadRequest) fs.contract.Error!fs.contract.OwnedReadResult {
            return error.Unsupported;
        }
        pub fn capture(_: *@This(), _: fs.contract.EntrySource) fs.contract.Error!fs.contract.LeaseRef {
            return error.Unsupported;
        }
        pub fn releaseLease(_: *@This(), _: fs.contract.LeaseSource) void {}
        pub fn apply(_: *@This(), _: std.mem.Allocator, _: fs.contract.Plan) fs.contract.Error!fs.contract.OwnedApplyReport {
            return error.Unsupported;
        }
        pub fn watch(_: *@This(), _: fs.contract.Root, _: fs.contract.NodeRef, _: bool) fs.contract.Error!fs.contract.WatchRef {
            return error.Unsupported;
        }
        pub fn pollInvalidation(_: *@This(), _: fs.contract.WatchRef) fs.contract.Error!?fs.contract.Invalidation {
            return error.Unsupported;
        }
        pub fn closeWatch(_: *@This(), _: fs.contract.WatchRef) void {}
    };
    const target: semantic.target.Ref = .{ .authority = .here, .slot = 7, .generation = 1 };
    const root: fs.contract.Root = .{ .authority = .here, .slot = 1, .generation = 2 };
    const other_root: fs.contract.Root = .{ .authority = .here, .slot = 9, .generation = 2 };
    const encoded = try fs.target.encode(std.testing.allocator, .{ .root = root });
    defer std.testing.allocator.free(encoded);
    const forged = try fs.target.encode(std.testing.allocator, .{ .root = other_root });
    defer std.testing.allocator.free(forged);
    const entry_encoded = try fs.target.encode(std.testing.allocator, .{
        .root = root,
        .node = .{ .entry = .{ .authority = .here, .slot = 2, .generation = 1 } },
    });
    defer std.testing.allocator.free(entry_encoded);
    var descriptor: semantic.target.Descriptor = .{
        .ref = target,
        .kind = .directory,
        .display_name = "directory",
        .facts = &.{.{ .name = fs.target.fact_name, .value = encoded }},
    };
    var router = fs_runtime.Router.init(std.testing.allocator);
    defer router.deinit();
    var provider: Provider = .{};
    try router.register(.here, .init(&provider));
    try std.testing.expectError(error.TargetUnbound, router.authorizedDirectory(target, 1));
    try router.bindTarget(target, 1, .{ .root = root });
    try std.testing.expectEqual(root, (try authorizeDirectory(&router, descriptor, target, 1)).root);
    descriptor.facts = &.{.{ .name = fs.target.fact_name, .value = forged }};
    try std.testing.expectError(error.InvalidTarget, authorizeDirectory(&router, descriptor, target, 1));
    descriptor.facts = &.{.{ .name = fs.target.fact_name, .value = entry_encoded }};
    try std.testing.expect(router.unbindTarget(target));
    try router.bindTarget(target, 1, .{ .root = root, .node = .{ .entry = .{ .authority = .here, .slot = 2, .generation = 1 } } });
    try std.testing.expectError(error.Unsupported, authorizeDirectory(&router, descriptor, target, 1));
}
