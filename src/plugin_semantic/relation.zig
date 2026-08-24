//! Synchronous relation-provider bridge for sandboxed semantic plugins.
//!
//! A token owns one stable provider proxy. Queries and answers cross as
//! canonical values; the bridge retains an owned answer until the registry
//! has cloned it. No guest pointer or transport-specific type survives a
//! callback.

const std = @import("std");
const semantic = @import("weft_semantic");
const scene_codec = @import("weft_scene_codec");
const target_runtime = @import("weft_target_runtime");

const relation = target_runtime.relation;

pub const CallbackError = error{Failed};

pub const Callback = struct {
    context: *anyopaque,
    invoke_query: *const fn (*anyopaque, u32) CallbackError!void,
};

pub const Error = relation.Error || error{
    DuplicateToken,
    UnknownProvider,
    Busy,
    Failed,
};

pub const ResponseError = error{
    NotInFlight,
    AlreadyResponded,
};

const Response = union(enum) {
    none,
    resolved: scene_codec.target.OwnedLocated,
    failure: relation.QueryError,

    fn deinit(self: *Response) void {
        switch (self.*) {
            .resolved => |*owned| owned.deinit(),
            .none, .failure => {},
        }
        self.* = undefined;
    }

    fn borrowed(self: *const Response, name: []const u8) relation.QueryError!?relation.Relation {
        return switch (self.*) {
            .none => null,
            .resolved => |owned| .{ .name = name, .target = owned.value },
            .failure => |err| err,
        };
    }
};

const Proxy = struct {
    bridge: *Bridge,
    token: u32,
    ref: relation.ProviderRef = undefined,

    pub fn query(self: *Proxy, request: relation.Query) relation.QueryError!?relation.Relation {
        return self.bridge.query(self.token, request);
    }
};

pub const Bridge = struct {
    gpa: std.mem.Allocator = undefined,
    callback: Callback = undefined,
    proxies: std.ArrayList(*Proxy) = .empty,
    request_wire: ?[]u8 = null,
    response: ?Response = null,
    initialized: bool = false,

    pub const empty: Bridge = .{};

    pub fn init(gpa: std.mem.Allocator, callback: Callback) Bridge {
        return .{ .gpa = gpa, .callback = callback, .initialized = true };
    }

    /// Registry endpoints must be owner-revoked before this call.
    pub fn deinit(self: *Bridge) void {
        if (!self.initialized) return;
        std.debug.assert(self.request_wire == null);
        self.clearResponse();
        for (self.proxies.items) |proxy| self.gpa.destroy(proxy);
        self.proxies.deinit(self.gpa);
        self.* = .empty;
    }

    pub fn register(
        self: *Bridge,
        registry: *relation.Registry,
        owner: semantic.owner.Id,
        token: u32,
        id: []const u8,
    ) Error!relation.ProviderRef {
        if (!self.initialized) return error.Failed;
        if (self.request_wire != null) return error.Busy;
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

    pub fn remove(self: *Bridge, registry: *relation.Registry, ref: relation.ProviderRef) Error!void {
        if (self.request_wire != null) return error.Busy;
        for (self.proxies.items, 0..) |proxy, index| {
            if (!proxy.ref.eql(ref)) continue;
            if (!registry.unregister(self.gpa, ref)) return error.UnknownProvider;
            _ = self.proxies.swapRemove(index);
            self.gpa.destroy(proxy);
            return;
        }
        return error.UnknownProvider;
    }

    pub fn currentRequestBytes(self: *const Bridge) ?[]const u8 {
        return self.request_wire;
    }

    pub fn respondNone(self: *Bridge) ResponseError!void {
        try self.beginResponse();
        self.response = .none;
    }

    /// Move an already-decoded response into the bridge. On success `owned`
    /// is invalidated; on error it remains owned by the caller.
    pub fn adoptResolved(self: *Bridge, owned: *scene_codec.target.OwnedLocated) ResponseError!void {
        try self.beginResponse();
        self.response = .{ .resolved = owned.* };
        owned.* = undefined;
    }

    pub fn respondFailure(self: *Bridge, err: relation.QueryError) ResponseError!void {
        try self.beginResponse();
        self.response = .{ .failure = err };
    }

    fn query(self: *Bridge, token: u32, request: relation.Query) relation.QueryError!?relation.Relation {
        if (!self.initialized or self.request_wire != null) return error.Failed;
        self.clearResponse();
        self.request_wire = scene_codec.action.encodeRelation(self.gpa, .{
            .source = request.source,
            .name = request.name,
        }) catch return error.Failed;
        defer {
            self.gpa.free(self.request_wire.?);
            self.request_wire = null;
        }
        self.callback.invoke_query(self.callback.context, token) catch {
            self.clearResponse();
            return error.Failed;
        };
        const response = if (self.response) |*value| value else return error.Failed;
        return response.borrowed(request.name);
    }

    fn beginResponse(self: *const Bridge) ResponseError!void {
        if (self.request_wire == null) return error.NotInFlight;
        if (self.response != null) return error.AlreadyResponded;
    }

    fn clearResponse(self: *Bridge) void {
        if (self.response) |*response| response.deinit();
        self.response = null;
    }
};

test "sandbox relation bridge carries canonical queries and owned answers" {
    const Fixture = struct {
        bridge: *Bridge = undefined,
        queries: usize = 0,

        fn query(raw: *anyopaque, token: u32) CallbackError!void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            if (token != 9) return error.Failed;
            var request = scene_codec.action.decodeRelation(
                std.testing.allocator,
                self.bridge.currentRequestBytes() orelse return error.Failed,
            ) catch return error.Failed;
            defer request.deinit();
            if (!std.mem.eql(u8, request.value.name, "container")) return error.Failed;
            self.queries += 1;
            const bytes = scene_codec.target.encodeLocated(std.testing.allocator, .{
                .target = .{ .authority = .here, .slot = 8, .generation = 2 },
                .revision = 4,
                .location = .{ .node = "parent" },
            }) catch return error.Failed;
            defer std.testing.allocator.free(bytes);
            var resolved = scene_codec.target.decodeLocated(std.testing.allocator, bytes) catch return error.Failed;
            self.bridge.adoptResolved(&resolved) catch {
                resolved.deinit();
                return error.Failed;
            };
        }
    };

    const owner: semantic.owner.Id = @enumFromInt(1);
    var fixture: Fixture = .{};
    var bridge = Bridge.init(std.testing.allocator, .{ .context = &fixture, .invoke_query = Fixture.query });
    defer bridge.deinit();
    fixture.bridge = &bridge;
    var registry = relation.Registry.init(.here);
    defer registry.deinit(std.testing.allocator);
    const provider = try bridge.register(&registry, owner, 9, "tree");
    var resolution = try registry.query(std.testing.allocator, .{
        .source = .{ .target = .{ .authority = .here, .slot = 2, .generation = 1 }, .revision = 3 },
        .name = "container",
    });
    defer resolution.deinit();
    try std.testing.expectEqual(@as(usize, 1), resolution.value.candidates.len);
    try std.testing.expectEqual(@as(usize, 1), fixture.queries);
    try std.testing.expectEqual(@as(u32, 8), resolution.value.candidates[0].relation.target.target.slot);
    try std.testing.expectEqualStrings("parent", resolution.value.candidates[0].relation.target.location.node);
    try bridge.remove(&registry, provider);
}

test "sandbox relation bridge rejects duplicate tokens and out-of-flight responses" {
    const Fixture = struct {
        bridge: *Bridge = undefined,

        fn query(raw: *anyopaque, _: u32) CallbackError!void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.bridge.respondNone() catch return error.Failed;
            self.bridge.respondFailure(error.Failed) catch |err| {
                if (err == error.AlreadyResponded) return;
                return error.Failed;
            };
            return error.Failed;
        }
    };
    var fixture: Fixture = .{};
    var bridge = Bridge.init(std.testing.allocator, .{ .context = &fixture, .invoke_query = Fixture.query });
    defer bridge.deinit();
    fixture.bridge = &bridge;
    var registry = relation.Registry.init(.here);
    defer registry.deinit(std.testing.allocator);
    const owner: semantic.owner.Id = @enumFromInt(1);
    _ = try bridge.register(&registry, owner, 1, "one");
    try std.testing.expectError(error.DuplicateToken, bridge.register(&registry, owner, 1, "two"));
    try std.testing.expectError(error.NotInFlight, bridge.respondNone());
    var resolution = try registry.query(std.testing.allocator, .{
        .source = .{ .target = .{ .authority = .here, .slot = 1, .generation = 1 }, .revision = 1 },
        .name = "container",
    });
    defer resolution.deinit();
    try std.testing.expectEqual(@as(usize, 0), resolution.value.candidates.len);
    try std.testing.expectEqual(@as(usize, 0), resolution.value.failures.len);
}
