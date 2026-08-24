//! Semantic filesystem provider facade.
//!
//! The interface is synchronous on purpose: scheduling is a separate concern.
//! A local provider can run on a worker, a peer provider can wait on its
//! transport there, and a synthetic provider can answer immediately without
//! infecting filesystem semantics with three different async models.

const std = @import("std");
const contract = @import("contract.zig");
const plan = @import("plan.zig");

pub const ApplyError = contract.Error || plan.ValidationError;

pub const Provider = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        capabilities: *const fn (*anyopaque, contract.Root) contract.Error!contract.Capabilities,
        observe: *const fn (*anyopaque, std.mem.Allocator, contract.Root, contract.NodeRef) contract.Error!contract.OwnedObservation,
        list: *const fn (*anyopaque, std.mem.Allocator, contract.Root, contract.NodeRef) contract.Error!contract.OwnedListing,
        read: *const fn (*anyopaque, std.mem.Allocator, contract.ReadRequest) contract.Error!contract.OwnedReadResult,
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

            fn list(raw: *anyopaque, gpa: std.mem.Allocator, root: contract.Root, directory: contract.NodeRef) contract.Error!contract.OwnedListing {
                return self(raw).list(gpa, root, directory);
            }

            fn read(raw: *anyopaque, gpa: std.mem.Allocator, request: contract.ReadRequest) contract.Error!contract.OwnedReadResult {
                return self(raw).read(gpa, request);
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
                .observe = @This().observe,
                .list = @This().list,
                .read = @This().read,
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

    pub fn observe(self: Provider, gpa: std.mem.Allocator, root: contract.Root, node: contract.NodeRef) contract.Error!contract.OwnedObservation {
        return self.vtable.observe(self.context, gpa, root, node);
    }

    pub fn list(self: Provider, gpa: std.mem.Allocator, root: contract.Root, directory: contract.NodeRef) contract.Error!contract.OwnedListing {
        return self.vtable.list(self.context, gpa, root, directory);
    }

    pub fn read(self: Provider, gpa: std.mem.Allocator, request: contract.ReadRequest) contract.Error!contract.OwnedReadResult {
        return self.vtable.read(self.context, gpa, request);
    }

    pub fn apply(self: Provider, gpa: std.mem.Allocator, effect_plan: contract.Plan) ApplyError!contract.OwnedApplyReport {
        try plan.validate(gpa, effect_plan);
        return self.vtable.apply(self.context, gpa, effect_plan);
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
