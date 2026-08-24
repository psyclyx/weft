//! Synchronous action-provider bridge for sandboxed semantic plugins.
//!
//! The bridge gives a transport one canonical request byte slice during the
//! callback and retains any data-bearing response until the next invocation.
//! It knows no editor mode, tool kind, wasm runtime, or clipboard policy.

const std = @import("std");
const semantic = @import("weft_semantic");
const scene_codec = @import("weft_scene_codec");
const view_runtime = @import("weft_view_runtime");

pub const CallbackError = error{Failed};

pub const Callback = struct {
    context: *anyopaque,
    invoke: *const fn (*anyopaque) CallbackError!void,
};

pub const ResponseError = error{
    NotInFlight,
    AlreadyResponded,
};

const OwnedOutcome = union(enum) {
    declined,
    handled,
    transfer: scene_codec.transfer.Owned,
    interaction: scene_codec.interaction.Owned,
    open_target: scene_codec.target.OwnedLocated,
    focus: semantic.scene.NodeId,
    open_relation: scene_codec.action.OwnedRelation,

    fn deinit(self: *OwnedOutcome) void {
        switch (self.*) {
            .declined, .handled, .focus => {},
            .transfer => |*value| value.deinit(),
            .interaction => |*value| value.deinit(),
            .open_target => |*value| value.deinit(),
            .open_relation => |*value| value.deinit(),
        }
        self.* = undefined;
    }

    fn borrowed(self: *const OwnedOutcome) semantic.action.Outcome {
        return switch (self.*) {
            .declined => .declined,
            .handled => .handled,
            .transfer => |value| .{ .transfer = value.value },
            .interaction => |value| .{ .interaction = value.value },
            .open_target => |value| .{ .open_target = value.value },
            .focus => |value| .{ .focus = value },
            .open_relation => |value| .{ .open_relation = value.value },
        };
    }
};

pub const Bridge = struct {
    gpa: std.mem.Allocator = undefined,
    callback: Callback = undefined,
    request_wire: ?[]u8 = null,
    response: ?OwnedOutcome = null,
    initialized: bool = false,

    pub const empty: Bridge = .{};

    pub fn init(gpa: std.mem.Allocator, callback: Callback) Bridge {
        return .{ .gpa = gpa, .callback = callback, .initialized = true };
    }

    /// The registry endpoint must be revoked before destroying the bridge.
    pub fn deinit(self: *Bridge) void {
        if (!self.initialized) return;
        std.debug.assert(self.request_wire == null);
        self.clearResponse();
        self.* = .empty;
    }

    /// Implements `weft_view_runtime.action.Provider`. Returned aggregate data
    /// is borrowed from this bridge until the next invocation or deinit.
    pub fn invoke(self: *Bridge, request: semantic.action.Request) view_runtime.action.ProviderError!semantic.action.Outcome {
        if (!self.initialized or self.request_wire != null) return error.Failed;
        self.clearResponse();
        self.request_wire = scene_codec.action.encodeRequest(self.gpa, request) catch return error.Failed;
        defer {
            self.gpa.free(self.request_wire.?);
            self.request_wire = null;
        }
        self.callback.invoke(self.callback.context) catch {
            self.clearResponse();
            return error.Failed;
        };
        if (self.response) |*response| return response.borrowed();
        return error.Failed;
    }

    pub fn currentRequestBytes(self: *const Bridge) ?[]const u8 {
        return self.request_wire;
    }

    pub fn respondDeclined(self: *Bridge) ResponseError!void {
        try self.beginResponse();
        self.response = .declined;
    }

    pub fn respondHandled(self: *Bridge) ResponseError!void {
        try self.beginResponse();
        self.response = .handled;
    }

    /// Move an already-decoded response into the bridge. On success `owned`
    /// is invalidated; on error it remains owned by the caller.
    pub fn adoptTransfer(self: *Bridge, owned: *scene_codec.transfer.Owned) ResponseError!void {
        try self.beginResponse();
        self.response = .{ .transfer = owned.* };
        owned.* = undefined;
    }

    /// Move an already-decoded response into the bridge. On success `owned`
    /// is invalidated; on error it remains owned by the caller.
    pub fn adoptInteraction(self: *Bridge, owned: *scene_codec.interaction.Owned) ResponseError!void {
        try self.beginResponse();
        self.response = .{ .interaction = owned.* };
        owned.* = undefined;
    }

    /// Move a decoded located-target request into the bridge. Core resolves
    /// its handler and admits its resulting view; the provider supplies only
    /// the portable target identity, revision, and location.
    pub fn adoptOpenTarget(self: *Bridge, owned: *scene_codec.target.OwnedLocated) ResponseError!void {
        try self.beginResponse();
        self.response = .{ .open_target = owned.* };
        owned.* = undefined;
    }

    pub fn respondFocus(self: *Bridge, node: semantic.scene.NodeId) ResponseError!void {
        try self.beginResponse();
        self.response = .{ .focus = node };
    }

    pub fn adoptOpenRelation(self: *Bridge, owned: *scene_codec.action.OwnedRelation) ResponseError!void {
        try self.beginResponse();
        self.response = .{ .open_relation = owned.* };
        owned.* = undefined;
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

test "sandbox action bridge exposes canonical request and retains transfer response" {
    const Fixture = struct {
        bridge: *Bridge = undefined,
        payload: *[4]u8 = undefined,

        fn invoke(raw: *anyopaque) CallbackError!void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            const bytes = self.bridge.currentRequestBytes() orelse return error.Failed;
            var request = scene_codec.action.decodeRequest(std.testing.allocator, bytes) catch return error.Failed;
            defer request.deinit();
            if (!std.mem.eql(u8, request.value.action, "capture")) return error.Failed;

            const encoded = scene_codec.transfer.encode(std.testing.allocator, .{
                .intent = .copy,
                .representations = &.{.{ .media_type = "application/test", .payload = self.payload }},
            }) catch return error.Failed;
            defer std.testing.allocator.free(encoded);
            var transfer = scene_codec.transfer.decode(std.testing.allocator, encoded) catch return error.Failed;
            self.bridge.adoptTransfer(&transfer) catch {
                transfer.deinit();
                return error.Failed;
            };
        }
    };

    var source = [_]u8{ 'd', 'a', 't', 'a' };
    var fixture: Fixture = .{ .payload = &source };
    var bridge = Bridge.init(std.testing.allocator, .{ .context = &fixture, .invoke = Fixture.invoke });
    defer bridge.deinit();
    fixture.bridge = &bridge;
    const outcome = try bridge.invoke(.{
        .action = "capture",
        .view = .{ .authority = .here, .slot = 1, .generation = 2 },
        .subject = @enumFromInt(0x1_0000_0002),
    });
    @memset(&source, 'x');
    try std.testing.expectEqualStrings("data", outcome.transfer.representations[0].payload);
    try std.testing.expect(bridge.currentRequestBytes() == null);
}

test "sandbox action bridge requires exactly one response during callback" {
    const Fixture = struct {
        bridge: *Bridge = undefined,
        mode: enum { missing, duplicate } = .missing,

        fn invoke(raw: *anyopaque) CallbackError!void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            if (self.mode == .missing) return;
            self.bridge.respondHandled() catch return error.Failed;
            self.bridge.respondDeclined() catch |err| {
                if (err == error.AlreadyResponded) return;
                return error.Failed;
            };
            return error.Failed;
        }
    };
    var fixture: Fixture = .{};
    var bridge = Bridge.init(std.testing.allocator, .{ .context = &fixture, .invoke = Fixture.invoke });
    defer bridge.deinit();
    fixture.bridge = &bridge;
    const request: semantic.action.Request = .{
        .action = "go",
        .view = .{ .authority = .here, .slot = 1, .generation = 1 },
        .subject = @enumFromInt(1),
    };
    try std.testing.expectError(error.Failed, bridge.invoke(request));
    fixture.mode = .duplicate;
    try std.testing.expect((try bridge.invoke(request)) == .handled);
    try std.testing.expectError(error.NotInFlight, bridge.respondDeclined());
}

test "sandbox action bridge carries same-view focus as a scalar value" {
    const Fixture = struct {
        bridge: *Bridge = undefined,

        fn invoke(raw: *anyopaque) CallbackError!void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.bridge.respondFocus(@enumFromInt(0x1_0000_0002)) catch return error.Failed;
        }
    };
    var fixture: Fixture = .{};
    var bridge = Bridge.init(std.testing.allocator, .{ .context = &fixture, .invoke = Fixture.invoke });
    defer bridge.deinit();
    fixture.bridge = &bridge;
    const outcome = try bridge.invoke(.{
        .action = "focus-secondary",
        .view = .{ .authority = .here, .slot = 1, .generation = 1 },
        .subject = @enumFromInt(2),
    });
    try std.testing.expectEqual(@as(u64, 0x1_0000_0002), @intFromEnum(outcome.focus));
}

test "sandbox action bridge carries an owned relation request" {
    const Fixture = struct {
        bridge: *Bridge = undefined,

        fn invoke(raw: *anyopaque) CallbackError!void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            const bytes = self.bridge.currentRequestBytes() orelse return error.Failed;
            var request = scene_codec.action.decodeRequest(std.testing.allocator, bytes) catch return error.Failed;
            defer request.deinit();
            const encoded = scene_codec.action.encodeRelation(std.testing.allocator, .{
                .source = .{ .target = .{ .authority = .here, .slot = 3, .generation = 4 }, .revision = 9 },
                .name = "container",
            }) catch return error.Failed;
            defer std.testing.allocator.free(encoded);
            var relation = scene_codec.action.decodeRelation(std.testing.allocator, encoded) catch return error.Failed;
            self.bridge.adoptOpenRelation(&relation) catch {
                relation.deinit();
                return error.Failed;
            };
        }
    };
    var fixture: Fixture = .{};
    var bridge = Bridge.init(std.testing.allocator, .{ .context = &fixture, .invoke = Fixture.invoke });
    defer bridge.deinit();
    fixture.bridge = &bridge;
    const outcome = try bridge.invoke(.{
        .action = "open-parent",
        .view = .{ .authority = .here, .slot = 1, .generation = 1 },
        .subject = @enumFromInt(2),
    });
    try std.testing.expectEqual(@as(u64, 3), outcome.open_relation.source.target.slot);
    try std.testing.expectEqual(@as(u64, 9), outcome.open_relation.source.revision);
    try std.testing.expectEqualStrings("container", outcome.open_relation.name);
}
