//! Synchronous target-handler bridge for sandboxed semantic plugins.
//!
//! Each token owns one stable provider proxy. Descriptor probes and located
//! opens cross as canonical values; responses are scalar claims, typed view
//! handles, or explicit provider errors. No guest pointer survives a call.

const std = @import("std");
const semantic = @import("weft_semantic");
const scene_codec = @import("weft_scene_codec");
const target_runtime = @import("weft_target_runtime");

const resolver = target_runtime.resolver;

pub const CallbackError = error{Failed};

pub const Callback = struct {
    context: *anyopaque,
    invoke_probe: *const fn (*anyopaque, u32) CallbackError!void,
    invoke_open: *const fn (*anyopaque, u32) CallbackError!void,
};

pub const Error = resolver.Error || error{
    DuplicateToken,
    UnknownHandler,
    Busy,
    Failed,
};

pub const ResponseError = error{
    NotInFlight,
    WrongPhase,
    AlreadyResponded,
    InvalidView,
};

const Phase = enum { probe, open };

const Response = union(enum) {
    probe_none,
    probe_match: semantic.target.Match,
    probe_error: resolver.ProbeError,
    open_view: semantic.view.Ref,
    open_error: resolver.OpenError,
};

const Current = struct {
    phase: Phase,
    request_wire: []u8,
    response: ?Response = null,
};

const Proxy = struct {
    bridge: *Bridge,
    token: u32,
    ref: resolver.HandlerRef = undefined,

    pub fn probe(self: *Proxy, descriptor: semantic.target.Descriptor) resolver.ProbeError!?resolver.Strength {
        self.bridge.begin(.probe, scene_codec.target.encodeDescriptor(self.bridge.gpa, descriptor) catch return error.Failed) catch return error.Failed;
        defer self.bridge.end();
        self.bridge.callback.invoke_probe(self.bridge.callback.context, self.token) catch return error.Failed;
        const response = self.bridge.current.?.response orelse return error.Failed;
        return switch (response) {
            .probe_none => null,
            .probe_match => |value| value,
            .probe_error => |err| err,
            else => error.Failed,
        };
    }

    pub fn open(self: *Proxy, located: semantic.target.Located) resolver.OpenError!semantic.view.Ref {
        self.bridge.begin(.open, scene_codec.target.encodeLocated(self.bridge.gpa, located) catch return error.Failed) catch return error.Failed;
        defer self.bridge.end();
        self.bridge.callback.invoke_open(self.bridge.callback.context, self.token) catch return error.Failed;
        const response = self.bridge.current.?.response orelse return error.Failed;
        return switch (response) {
            .open_view => |view| view,
            .open_error => |err| err,
            else => error.Failed,
        };
    }
};

pub const Bridge = struct {
    gpa: std.mem.Allocator = undefined,
    callback: Callback = undefined,
    proxies: std.ArrayList(*Proxy) = .empty,
    current: ?Current = null,
    initialized: bool = false,

    pub const empty: Bridge = .{};

    pub fn init(gpa: std.mem.Allocator, callback: Callback) Bridge {
        return .{ .gpa = gpa, .callback = callback, .initialized = true };
    }

    /// Registry endpoints must be owner-revoked before this call.
    pub fn deinit(self: *Bridge) void {
        if (!self.initialized) return;
        std.debug.assert(self.current == null);
        for (self.proxies.items) |proxy| self.gpa.destroy(proxy);
        self.proxies.deinit(self.gpa);
        self.* = .empty;
    }

    pub fn register(
        self: *Bridge,
        registry: *resolver.Registry,
        owner: semantic.owner.Id,
        token: u32,
        id: []const u8,
    ) Error!resolver.HandlerRef {
        if (!self.initialized) return error.Failed;
        if (self.current != null) return error.Busy;
        for (self.proxies.items) |proxy| if (proxy.token == token) return error.DuplicateToken;
        const proxy = try self.gpa.create(Proxy);
        errdefer self.gpa.destroy(proxy);
        proxy.* = .{ .bridge = self, .token = token };
        const ref = try registry.register(self.gpa, owner, id, .init(proxy));
        errdefer _ = registry.unregister(self.gpa, ref);
        proxy.ref = ref;
        try self.proxies.append(self.gpa, proxy);
        return ref;
    }

    pub fn remove(self: *Bridge, registry: *resolver.Registry, ref: resolver.HandlerRef) Error!void {
        if (self.current != null) return error.Busy;
        for (self.proxies.items, 0..) |proxy, index| {
            if (!proxy.ref.eql(ref)) continue;
            if (!registry.unregister(self.gpa, ref)) return error.UnknownHandler;
            _ = self.proxies.swapRemove(index);
            self.gpa.destroy(proxy);
            return;
        }
        return error.UnknownHandler;
    }

    pub fn currentRequestBytes(self: *const Bridge) ?[]const u8 {
        return if (self.current) |current| current.request_wire else null;
    }

    pub fn respondProbeNone(self: *Bridge) ResponseError!void {
        try self.setResponse(.probe, .probe_none);
    }

    pub fn respondProbeMatch(self: *Bridge, value: semantic.target.Match) ResponseError!void {
        try self.setResponse(.probe, .{ .probe_match = value });
    }

    pub fn respondProbeError(self: *Bridge, err: resolver.ProbeError) ResponseError!void {
        try self.setResponse(.probe, .{ .probe_error = err });
    }

    pub fn respondOpenView(self: *Bridge, view: semantic.view.Ref) ResponseError!void {
        if (view.generation == 0) return error.InvalidView;
        try self.setResponse(.open, .{ .open_view = view });
    }

    pub fn respondOpenError(self: *Bridge, err: resolver.OpenError) ResponseError!void {
        try self.setResponse(.open, .{ .open_error = err });
    }

    fn begin(self: *Bridge, phase: Phase, request_wire: []u8) error{Busy}!void {
        if (self.current != null) {
            self.gpa.free(request_wire);
            return error.Busy;
        }
        self.current = .{ .phase = phase, .request_wire = request_wire };
    }

    fn end(self: *Bridge) void {
        self.gpa.free(self.current.?.request_wire);
        self.current = null;
    }

    fn setResponse(self: *Bridge, phase: Phase, response: Response) ResponseError!void {
        const current = if (self.current) |*value| value else return error.NotInFlight;
        if (current.phase != phase) return error.WrongPhase;
        if (current.response != null) return error.AlreadyResponded;
        current.response = response;
    }
};

test "sandbox target bridge carries canonical probes and typed opens" {
    const Fixture = struct {
        bridge: *Bridge = undefined,
        view: semantic.view.Ref,
        probes: usize = 0,
        opens: usize = 0,

        fn probe(raw: *anyopaque, token: u32) CallbackError!void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            if (token != 7) return error.Failed;
            var descriptor = scene_codec.target.decodeDescriptor(std.testing.allocator, self.bridge.currentRequestBytes() orelse return error.Failed) catch return error.Failed;
            defer descriptor.deinit();
            if (descriptor.value.kind != .directory or descriptor.value.revision != 4) return error.Failed;
            self.probes += 1;
            self.bridge.respondProbeMatch(.exact) catch return error.Failed;
        }

        fn open(raw: *anyopaque, token: u32) CallbackError!void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            if (token != 7) return error.Failed;
            var located = scene_codec.target.decodeLocated(std.testing.allocator, self.bridge.currentRequestBytes() orelse return error.Failed) catch return error.Failed;
            defer located.deinit();
            if (located.value.revision != 4) return error.Failed;
            switch (located.value.location) {
                .whole => {},
                else => return error.Failed,
            }
            self.opens += 1;
            self.bridge.respondOpenView(self.view) catch return error.Failed;
        }
    };

    const owner: semantic.owner.Id = @enumFromInt(1);
    const view: semantic.view.Ref = .{ .authority = .here, .slot = 9, .generation = 2 };
    var fixture: Fixture = .{ .view = view };
    var bridge = Bridge.init(std.testing.allocator, .{ .context = &fixture, .invoke_probe = Fixture.probe, .invoke_open = Fixture.open });
    defer bridge.deinit();
    fixture.bridge = &bridge;
    var registry = resolver.Registry.init(.here);
    defer registry.deinit(std.testing.allocator);
    const handler = try bridge.register(&registry, owner, 7, "directory");
    const descriptor: semantic.target.Descriptor = .{
        .ref = .{ .authority = .here, .slot = 3, .generation = 1 },
        .revision = 4,
        .kind = .directory,
        .display_name = "dir",
    };
    var resolution = try registry.resolve(std.testing.allocator, descriptor);
    defer resolution.deinit();
    try std.testing.expectEqual(resolver.Strength.exact, resolution.value.candidates[0].strength);
    try std.testing.expectEqual(view, try registry.open(handler, .{ .target = descriptor.ref, .revision = 4 }));
    try std.testing.expectEqual(@as(usize, 1), fixture.probes);
    try std.testing.expectEqual(@as(usize, 1), fixture.opens);
    try bridge.remove(&registry, handler);
    try std.testing.expectError(error.StaleHandler, registry.open(handler, .{ .target = descriptor.ref, .revision = 4 }));
}

test "sandbox target bridge rejects reentrancy wrong phases and duplicate tokens" {
    const Fixture = struct {
        bridge: *Bridge = undefined,
        fn probe(raw: *anyopaque, _: u32) CallbackError!void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.bridge.respondOpenError(error.Rejected) catch |err| {
                if (err != error.WrongPhase) return error.Failed;
            };
            self.bridge.respondProbeNone() catch return error.Failed;
            self.bridge.respondProbeNone() catch |err| {
                if (err == error.AlreadyResponded) return;
                return error.Failed;
            };
            return error.Failed;
        }
        fn open(_: *anyopaque, _: u32) CallbackError!void {
            return error.Failed;
        }
    };
    const owner: semantic.owner.Id = @enumFromInt(1);
    var fixture: Fixture = .{};
    var bridge = Bridge.init(std.testing.allocator, .{ .context = &fixture, .invoke_probe = Fixture.probe, .invoke_open = Fixture.open });
    defer bridge.deinit();
    fixture.bridge = &bridge;
    var registry = resolver.Registry.init(.here);
    defer registry.deinit(std.testing.allocator);
    _ = try bridge.register(&registry, owner, 1, "one");
    try std.testing.expectError(error.DuplicateToken, bridge.register(&registry, owner, 1, "two"));
    try std.testing.expectError(error.NotInFlight, bridge.respondProbeNone());
}
