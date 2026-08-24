//! Owner-scoped semantic transfer attachments for sandboxed plugins.
//!
//! An attachment is a wire identifier, never a pointer or an authority by
//! itself.  This registry binds it to a provider lease only after the live
//! filesystem target membrane has authorized the source.  The registry's
//! guest reference is the guest's explicit capture/retain/release lifetime;
//! each decoded transfer representation retains the host resource independently.

const std = @import("std");
const wasm = @import("../wasm.zig");
const semantic = @import("weft_semantic");
const scene_codec = @import("weft_scene_codec");
const fs = @import("weft_fs");
const fs_runtime = @import("weft_fs_runtime");
const semantic_fs = @import("semantic_fs.zig");
const shared = @import("plugin.zig");
const WasmPlugin = shared.WasmPlugin;
const wire_util = @import("semantic_wire.zig");

const contract = fs.contract;

pub const Error = fs_runtime.Error || error{
    InvalidAttachment,
    AttachmentExhausted,
    InvalidOwner,
    OwnerNamespaceExhausted,
};

/// The guest receives both the opaque transfer identity and the exact lease
/// source it may carry in a provider-neutral filesystem plan. The source is
/// still only usable when `authorizeLease` proves that this registry minted
/// and currently owns it.
pub const CaptureResult = struct {
    attachment: semantic.transfer.Attachment,
    source: contract.LeaseSource,
};

const CaptureStatus = enum(i32) {
    unavailable = -1,
    stale_target = -2,
    unsupported = -3,
    invalid = -4,
    failed = -5,
    output_too_small = -6,
};

const AttachmentState = struct {
    gpa: std.mem.Allocator,
    provider_resource: semantic.transfer.Resource,
    handle: semantic.transfer.Attachment,
    source: contract.LeaseSource,
    registry: ?*Registry,
    guest_refs: usize = 1,
    host_refs: usize = 0,

    const vtable: semantic.transfer.Resource.VTable = .{
        .retain = retainHost,
        .release = releaseHost,
    };

    fn create(
        gpa: std.mem.Allocator,
        provider_resource: semantic.transfer.Resource,
        handle: semantic.transfer.Attachment,
        source: contract.LeaseSource,
        registry: *Registry,
    ) !*AttachmentState {
        const state = try gpa.create(AttachmentState);
        state.* = .{
            .gpa = gpa,
            .provider_resource = provider_resource,
            .handle = handle,
            .source = source,
            .registry = registry,
        };
        return state;
    }

    fn resource(self: *AttachmentState) semantic.transfer.Resource {
        return .{ .context = self, .vtable = &vtable };
    }

    fn retainHost(raw: *anyopaque) void {
        const self: *AttachmentState = @ptrCast(@alignCast(raw));
        if (self.host_refs == std.math.maxInt(usize)) @panic("semantic attachment reference overflow");
        self.host_refs += 1;
    }

    fn releaseHost(raw: *anyopaque) void {
        const self: *AttachmentState = @ptrCast(@alignCast(raw));
        if (self.host_refs == 0) @panic("semantic attachment released without ownership");
        self.host_refs -= 1;
        self.collectIfUnused();
    }

    fn collectIfUnused(self: *AttachmentState) void {
        if (self.guest_refs != 0 or self.host_refs != 0) return;
        if (self.registry) |registry| {
            registry.detach(self);
            self.registry = null;
        }
        self.provider_resource.release();
        self.gpa.destroy(self);
    }
};

pub const Registry = struct {
    gpa: std.mem.Allocator,
    /// The semantic-owner namespace is part of every wire attachment handle;
    /// it prevents two live plugin principals from interpreting the same
    /// `(authority, slot, generation)` tuple as their own resource.
    namespace: semantic.handle.Authority,
    entries: std.AutoHashMap(semantic.transfer.Attachment, *AttachmentState),
    next_slot: u32 = 1,

    pub fn init(gpa: std.mem.Allocator, owner: ?semantic.owner.Id) Error!Registry {
        const namespace = if (owner) |id| blk: {
            if (!id.isValid()) return error.InvalidOwner;
            const raw = @intFromEnum(id);
            if (raw > std.math.maxInt(u32)) return error.OwnerNamespaceExhausted;
            break :blk @as(semantic.handle.Authority, @enumFromInt(@as(u32, @intCast(raw))));
        } else semantic.handle.Authority.here;
        return .{ .gpa = gpa, .namespace = namespace, .entries = .init(gpa) };
    }

    /// Detaches all guest handles. States with host transfer references stay
    /// alive without a registry back-pointer and release their provider lease
    /// when the last host owner drops it.
    pub fn deinit(self: *Registry) void {
        var values = self.entries.valueIterator();
        while (values.next()) |state| {
            state.*.registry = null;
            state.*.guest_refs = 0;
            state.*.collectIfUnused();
        }
        self.entries.deinit();
        self.* = undefined;
    }

    /// Capture a source after the caller has checked its root against a live
    /// target binding.  The router still performs its own authority and entry
    /// validation; this registry adds only ownership and wire identity.
    pub fn capture(self: *Registry, router: *fs_runtime.Router, source: contract.EntrySource) Error!CaptureResult {
        if (self.next_slot == 0) return error.AttachmentExhausted;
        const lease = router.capture(source) catch |err| return err;
        const lease_resource = fs_runtime.LeaseResource.create(self.gpa, router, lease) catch |err| {
            router.release(lease) catch {};
            return err;
        };
        const attachment: semantic.transfer.Attachment = .{
            .authority = self.namespace,
            .slot = self.next_slot,
            .generation = 1,
        };
        self.next_slot +%= 1;
        const state = AttachmentState.create(self.gpa, lease_resource, attachment, lease, self) catch |err| {
            lease_resource.release();
            return err;
        };
        // The state owns the initial guest reference. If the registry cannot
        // publish the mapping, release that reference before collecting so
        // both the state allocation and provider lease are reclaimed.
        self.entries.put(attachment, state) catch |err| {
            state.guest_refs = 0;
            state.collectIfUnused();
            return err;
        };
        return .{ .attachment = attachment, .source = lease };
    }

    pub fn retain(self: *Registry, attachment: semantic.transfer.Attachment) Error!void {
        const state = self.entries.get(attachment) orelse return error.InvalidAttachment;
        if (state.guest_refs == std.math.maxInt(usize)) return error.AttachmentExhausted;
        state.guest_refs += 1;
    }

    pub fn release(self: *Registry, attachment: semantic.transfer.Attachment) Error!void {
        const state = self.entries.get(attachment) orelse return error.InvalidAttachment;
        if (state.guest_refs == 0) return error.InvalidAttachment;
        state.guest_refs -= 1;
        state.collectIfUnused();
    }

    /// Authorize a lease source only if it is the exact lease minted by this
    /// live plugin registry. This preserves cross-root transfers without
    /// treating a raw provider lease identifier as ambient authority.
    pub fn authorizeLease(self: *const Registry, source: contract.LeaseSource) Error!void {
        var values = self.entries.valueIterator();
        while (values.next()) |state| {
            if (sameLease(state.*.source, source)) return;
        }
        return error.InvalidAttachment;
    }

    /// Check all lease-backed copy sources in a generic filesystem plan. The
    /// destination root is intentionally not consulted here; semantic-fs
    /// validates that independently before admitting this proof.
    pub fn authorizePlan(self: *const Registry, plan: contract.Plan) Error!void {
        for (plan.operations) |planned| switch (planned.operation) {
            .copy => |copy| switch (copy.source) {
                .entry => {},
                .lease => |lease| try self.authorizeLease(lease),
            },
            else => {},
        };
    }

    fn detach(self: *Registry, state: *AttachmentState) void {
        if (self.entries.get(state.handle) == state) _ = self.entries.remove(state.handle);
    }

    fn lookupState(self: *const Registry, attachment: semantic.transfer.Attachment) ?*AttachmentState {
        return self.entries.get(attachment);
    }

    fn sameLease(a: contract.LeaseSource, b: contract.LeaseSource) bool {
        return a.root.authority == b.root.authority and
            a.root.slot == b.root.slot and
            a.root.generation == b.root.generation and
            a.ref.authority == b.ref.authority and
            a.ref.slot == b.ref.slot and
            a.ref.generation == b.ref.generation;
    }

    /// Resolve every wire attachment transactionally.  The codec owns the
    /// decoded transfer; once this succeeds, each non-null resource reference
    /// is owned by that `OwnedTransfer` and released by its deinit.  No
    /// process pointer crosses the wasm boundary.
    pub fn resolve(self: *const Registry, owned: *scene_codec.transfer.Owned) Error!void {
        for (owned.value.representations) |representation| {
            if (representation.attachment) |attachment| {
                if (representation.resource != null or self.lookupState(attachment) == null)
                    return error.InvalidAttachment;
            }
        }
        for (@constCast(owned.value.representations)) |*representation| {
            if (representation.attachment) |attachment| {
                const state = self.lookupState(attachment).?;
                const resource = state.resource();
                resource.retain();
                representation.resource = resource;
            }
        }
    }
};

fn status(err: anyerror) i32 {
    return @intFromEnum(switch (err) {
        error.Unavailable => CaptureStatus.unavailable,
        error.StaleTarget, error.Stale => CaptureStatus.stale_target,
        error.Unsupported => CaptureStatus.unsupported,
        error.InvalidTarget, error.InvalidHandle, error.InvalidAttachment => CaptureStatus.invalid,
        else => CaptureStatus.failed,
    });
}

fn sourceRoot(args: []const i32) fs.contract.Root {
    return .{ .authority = @enumFromInt(@as(u32, @bitCast(args[5]))), .slot = @bitCast(args[6]), .generation = @bitCast(args[7]) };
}

fn sourceEntry(args: []const i32) fs.contract.EntryRef {
    return .{ .authority = @enumFromInt(@as(u32, @bitCast(args[8]))), .slot = @bitCast(args[9]), .generation = @bitCast(args[10]) };
}

fn attachmentFromArgs(args: []const i32) semantic.transfer.Attachment {
    return .{
        .authority = @enumFromInt(@as(u32, @bitCast(args[0]))),
        .slot = @bitCast(args[1]),
        .generation = @bitCast(args[2]),
    };
}

const TestProvider = struct {
    released: usize = 0,

    pub fn capabilities(_: *@This(), _: contract.Root) contract.Error!contract.Capabilities {
        return .{ .durable_lease = .{ .regular_file_max_bytes = 1024, .symlink_target_max_bytes = 1024 } };
    }
    pub fn sameRoot(_: *@This(), left: contract.Root, right: contract.Root) contract.Error!bool {
        return left.eql(right);
    }
    pub fn observe(_: *@This(), gpa: std.mem.Allocator, _: contract.Root, node: contract.NodeRef) contract.Error!contract.OwnedObservation {
        var value = contract.OwnedObservation.init(gpa);
        value.value = .{ .node = node, .revision = .{ .token = "r" }, .kind = .regular };
        return value;
    }
    pub fn list(_: *@This(), _: std.mem.Allocator, _: contract.Root, _: contract.NodeRef) contract.Error!contract.OwnedListing {
        return error.Unsupported;
    }
    pub fn read(_: *@This(), _: std.mem.Allocator, _: contract.ReadRequest) contract.Error!contract.OwnedReadResult {
        return error.Unsupported;
    }
    pub fn capture(_: *@This(), _: contract.EntrySource) contract.Error!contract.LeaseRef {
        return .{ .authority = .here, .slot = 11, .generation = 1 };
    }
    pub fn releaseLease(self: *@This(), _: contract.LeaseSource) void {
        self.released += 1;
    }
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

/// Capture a typed filesystem entry into a generic semantic transfer
/// attachment.  The target binding is the authority source; the raw root and
/// entry identifiers are checked against it before the provider sees them.
pub fn hCapture(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    const plugin: *WasmPlugin = @ptrCast(@alignCast(data.?));
    results[0] = @intFromEnum(CaptureStatus.unavailable);
    if (!shared.requirePerm(plugin, caller, .fs_read)) return;
    if (!semantic_fs.requireUnrestricted(plugin, caller, .fs_read)) return;
    const scope = plugin.semanticScope() orelse return;
    const target = wire_util.readHandle(semantic.target.Ref, args[0..3]) orelse {
        results[0] = @intFromEnum(CaptureStatus.invalid);
        return;
    };
    const revision = (@as(u64, @as(u32, @bitCast(args[3]))) | (@as(u64, @as(u32, @bitCast(args[4]))) << 32));
    const router = plugin.activeCtx().filesystems orelse return;
    const descriptor = scope.services.targets.get(target) orelse {
        results[0] = @intFromEnum(CaptureStatus.stale_target);
        return;
    };
    const authorized = semantic_fs.authorizeDirectory(router, descriptor.*, target, revision) catch |err| {
        results[0] = status(err);
        return;
    };
    const root = sourceRoot(args);
    if (root.authority != authorized.root.authority or root.slot != authorized.root.slot or root.generation != authorized.root.generation) {
        results[0] = @intFromEnum(CaptureStatus.invalid);
        return;
    }
    if (@as(u32, @bitCast(args[10])) == 0) {
        results[0] = @intFromEnum(CaptureStatus.invalid);
        return;
    }
    const caps = router.capabilities(root) catch |err| {
        results[0] = status(err);
        return;
    };
    if (caps.durable_lease == null) {
        results[0] = @intFromEnum(CaptureStatus.unsupported);
        return;
    }
    const revision_bytes = caller.readMemory(plugin.gpa, @intCast(args[11]), @intCast(args[12])) catch {
        results[0] = @intFromEnum(CaptureStatus.invalid);
        return;
    };
    defer plugin.gpa.free(revision_bytes);
    const result = plugin.semantic_attachments.capture(router, .{ .root = root, .ref = sourceEntry(args), .revision = .{ .token = revision_bytes } }) catch |err| {
        results[0] = status(err);
        return;
    };
    const out_ptr: u32 = @bitCast(args[13]);
    const out_cap: u32 = @bitCast(args[14]);
    if (out_cap < 36) {
        plugin.semantic_attachments.release(result.attachment) catch {};
        results[0] = @intFromEnum(CaptureStatus.output_too_small);
        return;
    }
    var bytes: [12]u8 = undefined;
    const wire = result.attachment.toWire();
    std.mem.writeInt(u32, bytes[0..4], wire.authority, .little);
    std.mem.writeInt(u32, bytes[4..8], wire.slot, .little);
    std.mem.writeInt(u32, bytes[8..12], wire.generation, .little);
    var output: [36]u8 = undefined;
    @memcpy(output[0..12], &bytes);
    const root_wire = result.source.root;
    std.mem.writeInt(u32, output[12..16], @intFromEnum(root_wire.authority), .little);
    std.mem.writeInt(u32, output[16..20], root_wire.slot, .little);
    std.mem.writeInt(u32, output[20..24], root_wire.generation, .little);
    std.mem.writeInt(u32, output[24..28], @intFromEnum(result.source.ref.authority), .little);
    std.mem.writeInt(u32, output[28..32], result.source.ref.slot, .little);
    std.mem.writeInt(u32, output[32..36], result.source.ref.generation, .little);
    _ = caller.writeMemory(out_ptr, out_cap, &output) catch {
        plugin.semantic_attachments.release(result.attachment) catch {};
        results[0] = @intFromEnum(CaptureStatus.failed);
        return;
    };
    results[0] = 36;
}

pub fn hRetain(data: ?*anyopaque, _: *wasm.Caller, args: []const i32, results: []i32) void {
    const plugin: *WasmPlugin = @ptrCast(@alignCast(data.?));
    plugin.semantic_attachments.retain(attachmentFromArgs(args)) catch {
        results[0] = 0;
        return;
    };
    results[0] = 1;
}

pub fn hRelease(data: ?*anyopaque, _: *wasm.Caller, args: []const i32, results: []i32) void {
    const plugin: *WasmPlugin = @ptrCast(@alignCast(data.?));
    plugin.semantic_attachments.release(attachmentFromArgs(args)) catch {
        results[0] = 0;
        return;
    };
    results[0] = 1;
}

test "attachment ownership spans clipboard replacement and pending paste" {
    var provider: TestProvider = .{};
    var router = fs_runtime.Router.init(std.testing.allocator);
    defer router.deinit();
    try router.register(.here, .init(&provider));
    var registry = try Registry.init(std.testing.allocator, @enumFromInt(1));
    const root: contract.Root = .{ .authority = .here, .slot = 1, .generation = 1 };
    const captured_result = try registry.capture(&router, .{
        .root = root,
        .ref = .{ .authority = .here, .slot = 2, .generation = 1 },
        .revision = .{ .token = "r" },
    });
    const captured = captured_result.attachment;
    const cross_root_plan = contract.Plan{
        .root = .{ .authority = .here, .slot = 99, .generation = 1 },
        .base_revision = &.{},
        .operations = &.{.{
            .id = [_]u8{1} ** 16,
            .operation = .{ .copy = .{
                .source = .{ .lease = captured_result.source },
                .destination = .{ .parent = .root, .name = try contract.Name.init("paste") },
            } },
        }},
    };
    try registry.authorizePlan(cross_root_plan);
    var forged_source = captured_result.source;
    forged_source.ref.slot +%= 1;
    const forged_plan = contract.Plan{
        .root = cross_root_plan.root,
        .base_revision = &.{},
        .operations = &.{.{
            .id = [_]u8{2} ** 16,
            .operation = .{ .copy = .{
                .source = .{ .lease = forged_source },
                .destination = .{ .parent = .root, .name = try contract.Name.init("paste") },
            } },
        }},
    };
    try std.testing.expectError(error.InvalidAttachment, registry.authorizePlan(forged_plan));
    const encoded = try scene_codec.transfer.encode(std.testing.allocator, .{
        .intent = .copy,
        .representations = &.{.{ .media_type = "application/test", .attachment = captured, .payload = "x" }},
    });
    defer std.testing.allocator.free(encoded);
    var wire = try scene_codec.transfer.decode(std.testing.allocator, encoded);
    try registry.resolve(&wire);

    // Returning the transfer transfers host ownership to the clipboard. The
    // guest may release its capture handle immediately; the identifier must
    // remain resolvable for a later paste.
    try registry.release(captured);
    var pending = try scene_codec.transfer.decode(std.testing.allocator, encoded);
    try registry.resolve(&pending);
    try registry.retain(captured);

    // Replacing the clipboard drops only its representation reference. The
    // pending row remains live until apply/revert releases its reference.
    wire.deinit();
    try std.testing.expectEqual(@as(usize, 0), provider.released);
    pending.deinit();
    try std.testing.expectEqual(@as(usize, 0), provider.released);
    try registry.release(captured);
    try std.testing.expectEqual(@as(usize, 1), provider.released);

    const unattached = try registry.capture(&router, .{
        .root = root,
        .ref = .{ .authority = .here, .slot = 4, .generation = 1 },
        .revision = .{ .token = "r" },
    });
    try registry.release(unattached.attachment);
    try std.testing.expectError(error.InvalidAttachment, registry.authorizePlan(.{
        .root = cross_root_plan.root,
        .base_revision = &.{},
        .operations = &.{.{
            .id = [_]u8{3} ** 16,
            .operation = .{ .copy = .{
                .source = .{ .lease = unattached.source },
                .destination = .{ .parent = .root, .name = try contract.Name.init("paste") },
            } },
        }},
    }));
    try std.testing.expectEqual(@as(usize, 2), provider.released);

    // Unloading the plugin detaches guest handles but cannot invalidate a
    // host transfer that is still held by another view.
    const surviving = (try registry.capture(&router, .{
        .root = root,
        .ref = .{ .authority = .here, .slot = 3, .generation = 1 },
        .revision = .{ .token = "r" },
    })).attachment;
    const surviving_bytes = try scene_codec.transfer.encode(std.testing.allocator, .{
        .intent = .copy,
        .representations = &.{.{ .media_type = "application/test", .attachment = surviving, .payload = "x" }},
    });
    defer std.testing.allocator.free(surviving_bytes);
    var surviving_wire = try scene_codec.transfer.decode(std.testing.allocator, surviving_bytes);
    try registry.resolve(&surviving_wire);
    registry.deinit();
    try std.testing.expectEqual(@as(usize, 2), provider.released);
    surviving_wire.deinit();
    try std.testing.expectEqual(@as(usize, 3), provider.released);
}

test "attachment namespaces reject a foreign registry handle" {
    var provider: TestProvider = .{};
    var router = fs_runtime.Router.init(std.testing.allocator);
    defer router.deinit();
    try router.register(.here, .init(&provider));
    var first = try Registry.init(std.testing.allocator, @enumFromInt(1));
    defer first.deinit();
    var second = try Registry.init(std.testing.allocator, @enumFromInt(2));
    defer second.deinit();

    const first_capture = try first.capture(&router, .{
        .root = .{ .authority = .here, .slot = 1, .generation = 1 },
        .ref = .{ .authority = .here, .slot = 2, .generation = 1 },
        .revision = .{ .token = "r" },
    });
    const second_capture = try second.capture(&router, .{
        .root = .{ .authority = .here, .slot = 1, .generation = 1 },
        .ref = .{ .authority = .here, .slot = 3, .generation = 1 },
        .revision = .{ .token = "r" },
    });
    try std.testing.expectEqual(@as(u32, 1), first_capture.attachment.slot);
    try std.testing.expectEqual(@as(u32, 1), second_capture.attachment.slot);
    try std.testing.expect(first_capture.attachment.authority != second_capture.attachment.authority);

    const encoded = try scene_codec.transfer.encode(std.testing.allocator, .{
        .intent = .copy,
        .representations = &.{.{ .media_type = "application/test", .attachment = first_capture.attachment, .payload = "x" }},
    });
    defer std.testing.allocator.free(encoded);
    var foreign = try scene_codec.transfer.decode(std.testing.allocator, encoded);
    defer foreign.deinit();
    try std.testing.expectError(error.InvalidAttachment, second.resolve(&foreign));
    try std.testing.expect(foreign.value.representations[0].resource == null);
}

test "attachment namespace exhaustion is explicit" {
    const exhausted: semantic.owner.Id = @enumFromInt(@as(u64, std.math.maxInt(u32)) + 1);
    try std.testing.expectError(error.OwnerNamespaceExhausted, Registry.init(std.testing.allocator, exhausted));
}

test "capture releases lease when attachment publication runs out of memory" {
    var provider: TestProvider = .{};
    var router = fs_runtime.Router.init(std.testing.allocator);
    defer router.deinit();
    try router.register(.here, .init(&provider));

    // capture allocates the provider resource and attachment state first;
    // the third allocation is the registry's first hash-table publication.
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 2 });
    var registry = try Registry.init(failing.allocator(), @enumFromInt(1));
    defer registry.deinit();
    const result = registry.capture(&router, .{
        .root = .{ .authority = .here, .slot = 1, .generation = 1 },
        .ref = .{ .authority = .here, .slot = 2, .generation = 1 },
        .revision = .{ .token = "r" },
    });
    try std.testing.expectError(error.OutOfMemory, result);
    try std.testing.expectEqual(@as(usize, 1), provider.released);
}
