//! Semantic filesystem provider facade.
//!
//! The interface is synchronous on purpose: scheduling is a separate concern.
//! A local provider can run on a worker, a peer provider can wait on its
//! transport there, and a synthetic provider can answer immediately without
//! infecting filesystem semantics with three different async models.

const std = @import("std");
const contract = @import("contract.zig");
const plan = @import("plan.zig");

pub const ApplyError = contract.Error || plan.ValidationError || plan.ReportValidationError;

pub const Provider = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        capabilities: *const fn (*anyopaque, contract.Root) contract.Error!contract.Capabilities,
        same_root: *const fn (*anyopaque, contract.Root, contract.Root) contract.Error!bool,
        observe: *const fn (*anyopaque, std.mem.Allocator, contract.Root, contract.NodeRef) contract.Error!contract.OwnedObservation,
        list: *const fn (*anyopaque, std.mem.Allocator, contract.Root, contract.NodeRef) contract.Error!contract.OwnedListing,
        read: *const fn (*anyopaque, std.mem.Allocator, contract.ReadRequest) contract.Error!contract.OwnedReadResult,
        capture: *const fn (*anyopaque, contract.EntrySource) contract.Error!contract.LeaseRef,
        release_lease: *const fn (*anyopaque, contract.LeaseSource) void,
        apply: *const fn (*anyopaque, std.mem.Allocator, contract.Plan) contract.Error!contract.OwnedApplyReport,
        watch: *const fn (*anyopaque, contract.Root, contract.NodeRef, bool) contract.Error!contract.WatchRef,
        poll_invalidation: *const fn (*anyopaque, contract.WatchRef) contract.Error!?contract.Invalidation,
        close_watch: *const fn (*anyopaque, contract.WatchRef) void,
    };

    /// Adapt a pointer to an implementation with methods matching `VTable`.
    /// The generated shim is the only erased layer; provider code retains
    /// concrete types and ordinary Zig method calls.
    pub fn init(pointer: anytype) Provider {
        const Pointer = @TypeOf(pointer);
        const pointer_info = switch (@typeInfo(Pointer)) {
            .pointer => |info| info,
            else => @compileError("filesystem provider must be initialized from a pointer"),
        };
        if (pointer_info.size != .one or pointer_info.is_const)
            @compileError("filesystem provider requires a mutable single-item pointer");
        const Implementation = pointer_info.child;

        const Adapter = struct {
            fn self(raw: *anyopaque) *Implementation {
                return @ptrCast(@alignCast(raw));
            }

            fn capabilities(raw: *anyopaque, root: contract.Root) contract.Error!contract.Capabilities {
                return self(raw).capabilities(root);
            }

            fn observe(raw: *anyopaque, gpa: std.mem.Allocator, root: contract.Root, node: contract.NodeRef) contract.Error!contract.OwnedObservation {
                return self(raw).observe(gpa, root, node);
            }

            fn sameRoot(raw: *anyopaque, left: contract.Root, right: contract.Root) contract.Error!bool {
                return self(raw).sameRoot(left, right);
            }

            fn list(raw: *anyopaque, gpa: std.mem.Allocator, root: contract.Root, directory: contract.NodeRef) contract.Error!contract.OwnedListing {
                return self(raw).list(gpa, root, directory);
            }

            fn read(raw: *anyopaque, gpa: std.mem.Allocator, request: contract.ReadRequest) contract.Error!contract.OwnedReadResult {
                return self(raw).read(gpa, request);
            }

            fn capture(raw: *anyopaque, source: contract.EntrySource) contract.Error!contract.LeaseRef {
                return self(raw).capture(source);
            }

            fn releaseLease(raw: *anyopaque, source: contract.LeaseSource) void {
                self(raw).releaseLease(source);
            }

            fn apply(raw: *anyopaque, gpa: std.mem.Allocator, effect_plan: contract.Plan) contract.Error!contract.OwnedApplyReport {
                return self(raw).apply(gpa, effect_plan);
            }

            fn watch(raw: *anyopaque, root: contract.Root, directory: contract.NodeRef, recursive: bool) contract.Error!contract.WatchRef {
                return self(raw).watch(root, directory, recursive);
            }

            fn pollInvalidation(raw: *anyopaque, watch_ref: contract.WatchRef) contract.Error!?contract.Invalidation {
                return self(raw).pollInvalidation(watch_ref);
            }

            fn closeWatch(raw: *anyopaque, watch_ref: contract.WatchRef) void {
                self(raw).closeWatch(watch_ref);
            }

            const vtable: VTable = .{
                .capabilities = @This().capabilities,
                .same_root = @This().sameRoot,
                .observe = @This().observe,
                .list = @This().list,
                .read = @This().read,
                .capture = @This().capture,
                .release_lease = @This().releaseLease,
                .apply = @This().apply,
                .watch = @This().watch,
                .poll_invalidation = @This().pollInvalidation,
                .close_watch = @This().closeWatch,
            };
        };

        return .{ .context = pointer, .vtable = &Adapter.vtable };
    }

    pub fn capabilities(self: Provider, root: contract.Root) contract.Error!contract.Capabilities {
        return self.vtable.capabilities(self.context, root);
    }

    /// Compare the provider-owned identities behind two roots. Handle equality
    /// is not sufficient: a path may be reacquired into a fresh slot after an
    /// external rename, while the underlying directory object remains the
    /// same. This operation is deliberately provider-owned so Darwin and
    /// remote implementations can use their own stable identity mechanism.
    pub fn sameRoot(self: Provider, left: contract.Root, right: contract.Root) contract.Error!bool {
        return self.vtable.same_root(self.context, left, right);
    }

    pub fn observe(self: Provider, gpa: std.mem.Allocator, root: contract.Root, node: contract.NodeRef) contract.Error!contract.OwnedObservation {
        return self.vtable.observe(self.context, gpa, root, node);
    }

    pub fn list(self: Provider, gpa: std.mem.Allocator, root: contract.Root, directory: contract.NodeRef) contract.Error!contract.OwnedListing {
        return self.vtable.list(self.context, gpa, root, directory);
    }

    pub fn read(self: Provider, gpa: std.mem.Allocator, request: contract.ReadRequest) contract.Error!contract.OwnedReadResult {
        return self.vtable.read(self.context, gpa, request);
    }

    /// Materialize an entry into a provider-owned capability. The returned
    /// lease is independent of the source namespace, but remains scoped to
    /// this provider authority and is valid until `releaseLease`.
    pub fn capture(self: Provider, source: contract.EntrySource) contract.Error!contract.LeaseRef {
        return self.vtable.capture(self.context, source);
    }

    pub fn releaseLease(self: Provider, source: contract.LeaseSource) void {
        self.vtable.release_lease(self.context, source);
    }

    pub fn apply(self: Provider, gpa: std.mem.Allocator, effect_plan: contract.Plan) ApplyError!contract.OwnedApplyReport {
        try plan.validate(gpa, effect_plan);
        var report = try self.vtable.apply(self.context, gpa, effect_plan);
        errdefer report.deinit();
        try plan.validateReport(gpa, effect_plan, report.value);
        return report;
    }

    pub fn watch(self: Provider, root: contract.Root, directory: contract.NodeRef, recursive: bool) contract.Error!contract.WatchRef {
        return self.vtable.watch(self.context, root, directory, recursive);
    }

    pub fn pollInvalidation(self: Provider, watch_ref: contract.WatchRef) contract.Error!?contract.Invalidation {
        return self.vtable.poll_invalidation(self.context, watch_ref);
    }

    pub fn closeWatch(self: Provider, watch_ref: contract.WatchRef) void {
        self.vtable.close_watch(self.context, watch_ref);
    }
};
