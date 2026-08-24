//! Retained field-state bridge for sandboxed providers.
//!
//! Snapshots are pushed into host-owned state. Ordinary editor edits call the
//! provider synchronously through a transport callback; the provider accepts
//! by pushing a new, differently-revisioned snapshot before returning. This
//! keeps rendering pull-free and makes rejection/failure explicit without
//! exposing guest pointers or baking an editor/tool model into the contract.

const std = @import("std");
const semantic = @import("weft_semantic");
const view_runtime = @import("weft_view_runtime");

pub const max_revision_bytes: usize = 4096;
pub const max_value_bytes: usize = 16 * 1024 * 1024;

pub const CallbackError = error{Failed};

pub const Callback = struct {
    context: *anyopaque,
    invoke_edit: *const fn (*anyopaque, u32) CallbackError!void,
};

pub const Error = view_runtime.field.Error || error{
    DuplicateToken,
    UnknownField,
    Busy,
};

pub const CurrentEdit = struct {
    field: semantic.scene.FieldRef,
    token: u32,
    expected_revision: []const u8,
    edit: view_runtime.field.Edit,
};

const State = struct {
    arena: std.heap.ArenaAllocator,
    snapshot: view_runtime.field.Snapshot,

    fn init(gpa: std.mem.Allocator, value: view_runtime.field.Snapshot) Error!State {
        if (value.revision.len == 0 or value.revision.len > max_revision_bytes) return error.InvalidRevision;
        if (value.bytes.len > max_value_bytes) return error.InvalidRange;
        if (value.selection.anchor > value.bytes.len or value.selection.caret > value.bytes.len) return error.InvalidRange;
        var result: State = .{ .arena = .init(gpa), .snapshot = undefined };
        errdefer result.arena.deinit();
        const arena = result.arena.allocator();
        result.snapshot = .{
            .revision = try arena.dupe(u8, value.revision),
            .bytes = try arena.dupe(u8, value.bytes),
            .selection = value.selection,
            .read_only = value.read_only,
            .single_line = value.single_line,
        };
        return result;
    }

    fn deinit(self: *State) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

const Proxy = struct {
    bridge: *Bridge,
    token: u32,
    ref: semantic.scene.FieldRef = undefined,
    state: State,

    pub fn snapshot(self: *Proxy, gpa: std.mem.Allocator) view_runtime.field.Error!view_runtime.field.OwnedSnapshot {
        var result = view_runtime.field.OwnedSnapshot.init(gpa);
        errdefer result.deinit();
        const arena = result.allocator();
        result.value = .{
            .revision = try arena.dupe(u8, self.state.snapshot.revision),
            .bytes = try arena.dupe(u8, self.state.snapshot.bytes),
            .selection = self.state.snapshot.selection,
            .read_only = self.state.snapshot.read_only,
            .single_line = self.state.snapshot.single_line,
        };
        return result;
    }

    pub fn edit(self: *Proxy, expected_revision: []const u8, value: view_runtime.field.Edit) view_runtime.field.Error!void {
        const before = self.state.snapshot;
        if (!std.mem.eql(u8, before.revision, expected_revision)) return error.Stale;
        if (before.read_only) return error.ReadOnly;
        if (value.start > value.end or value.end > before.bytes.len) return error.InvalidRange;
        const prefix_len: usize = @intCast(value.start);
        const suffix_start: usize = @intCast(value.end);
        const next_len = std.math.add(usize, prefix_len, value.replacement.len) catch return error.InvalidRange;
        const final_len = std.math.add(usize, next_len, before.bytes.len - suffix_start) catch return error.InvalidRange;
        if (final_len > max_value_bytes) return error.InvalidRange;
        if (value.selection_after) |selection|
            if (selection.anchor > final_len or selection.caret > final_len) return error.InvalidRange;
        if (self.bridge.current != null) return error.Unsupported;

        const original_revision = try self.bridge.gpa.dupe(u8, before.revision);
        const original_bytes = self.bridge.gpa.dupe(u8, before.bytes) catch |err| {
            self.bridge.gpa.free(original_revision);
            return err;
        };
        self.bridge.current = .{ .value = .{
            .field = self.ref,
            .token = self.token,
            .expected_revision = expected_revision,
            .edit = value,
        }, .original_revision = original_revision, .original_bytes = original_bytes, .original_selection = before.selection, .original_read_only = before.read_only, .original_single_line = before.single_line };
        defer {
            const in_flight = self.bridge.current.?;
            self.bridge.gpa.free(in_flight.original_revision);
            self.bridge.gpa.free(in_flight.original_bytes);
            self.bridge.current = null;
        }
        self.bridge.callback.invoke_edit(self.bridge.callback.context, self.token) catch return error.Failed;
        const current = &self.bridge.current.?.value;
        if (!self.bridge.current.?.updated) return error.Failed;
        if (std.mem.eql(u8, current.expected_revision, self.state.snapshot.revision)) return error.InvalidRevision;
    }
};

const InFlight = struct {
    value: CurrentEdit,
    original_revision: []u8,
    original_bytes: []u8,
    original_selection: view_runtime.field.Selection,
    original_read_only: bool,
    original_single_line: bool,
    updated: bool = false,
};

pub const Bridge = struct {
    gpa: std.mem.Allocator = undefined,
    callback: Callback = undefined,
    proxies: std.ArrayList(*Proxy) = .empty,
    current: ?InFlight = null,
    initialized: bool = false,

    pub const empty: Bridge = .{};

    pub fn init(gpa: std.mem.Allocator, callback: Callback) Bridge {
        return .{ .gpa = gpa, .callback = callback, .initialized = true };
    }

    /// Registry endpoints must be revoked before this call. The bridge owns
    /// only proxy/cache memory; the registry owns handle generations.
    pub fn deinit(self: *Bridge) void {
        if (!self.initialized) return;
        std.debug.assert(self.current == null);
        for (self.proxies.items) |proxy| self.destroyProxy(proxy);
        self.proxies.deinit(self.gpa);
        self.* = .empty;
    }

    pub fn register(
        self: *Bridge,
        fields: *view_runtime.field.Registry,
        owner: semantic.owner.Id,
        token: u32,
        initial: view_runtime.field.Snapshot,
    ) Error!semantic.scene.FieldRef {
        if (!self.initialized) return error.Failed;
        for (self.proxies.items) |proxy| if (proxy.token == token) return error.DuplicateToken;
        const proxy = try self.gpa.create(Proxy);
        errdefer self.gpa.destroy(proxy);
        proxy.* = .{ .bridge = self, .token = token, .state = try .init(self.gpa, initial) };
        errdefer proxy.state.deinit();
        const ref = try fields.insert(self.gpa, owner, .init(proxy));
        errdefer _ = fields.remove(self.gpa, owner, ref);
        proxy.ref = ref;
        try self.proxies.append(self.gpa, proxy);
        return ref;
    }

    pub fn update(self: *Bridge, ref: semantic.scene.FieldRef, value: view_runtime.field.Snapshot) Error!void {
        const proxy = self.find(ref) orelse return error.UnknownField;
        var restoring = false;
        if (self.current) |current| {
            if (current.value.field.eql(ref) and std.mem.eql(u8, current.value.expected_revision, value.revision)) {
                // A failed provider callback may need to restore the exact
                // pre-edit snapshot. Permit that one rollback after an
                // accepted update, but keep it unaccepted so Proxy.edit still
                // reports the callback failure to its caller.
                restoring = current.updated and
                    std.mem.eql(u8, current.original_revision, value.revision) and
                    std.mem.eql(u8, current.original_bytes, value.bytes) and
                    current.original_selection.anchor == value.selection.anchor and
                    current.original_selection.caret == value.selection.caret and
                    current.original_read_only == value.read_only and
                    current.original_single_line == value.single_line;
                if (!restoring) return error.InvalidRevision;
            }
        }
        const next = try State.init(self.gpa, value);
        var prior = proxy.state;
        proxy.state = next;
        prior.deinit();
        if (self.current) |*current| {
            if (current.value.field.eql(ref)) current.updated = !restoring;
        }
    }

    pub fn remove(
        self: *Bridge,
        fields: *view_runtime.field.Registry,
        owner: semantic.owner.Id,
        ref: semantic.scene.FieldRef,
    ) Error!void {
        if (self.current) |current| if (current.value.field.eql(ref)) return error.Busy;
        for (self.proxies.items, 0..) |proxy, index| {
            if (!proxy.ref.eql(ref)) continue;
            if (!fields.remove(self.gpa, owner, ref)) return error.UnknownField;
            _ = self.proxies.swapRemove(index);
            self.destroyProxy(proxy);
            return;
        }
        return error.UnknownField;
    }

    pub fn currentEdit(self: *const Bridge) ?CurrentEdit {
        return if (self.current) |current| current.value else null;
    }

    fn find(self: *const Bridge, ref: semantic.scene.FieldRef) ?*Proxy {
        for (self.proxies.items) |proxy| if (proxy.ref.eql(ref)) return proxy;
        return null;
    }

    fn destroyProxy(self: *Bridge, proxy: *Proxy) void {
        proxy.state.deinit();
        self.gpa.destroy(proxy);
    }
};

test "sandbox field accepts an edit only through a revision-changing update" {
    const owner: semantic.owner.Id = @enumFromInt(1);
    const Fixture = struct {
        bridge: *Bridge = undefined,
        ref: semantic.scene.FieldRef = undefined,
        calls: usize = 0,

        fn invoke(raw: *anyopaque, token: u32) CallbackError!void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.calls += 1;
            const request = self.bridge.currentEdit() orelse return error.Failed;
            if (request.token != token) return error.Failed;
            self.bridge.update(self.ref, .{
                .revision = "2",
                .bytes = "renamed",
                .selection = .{ .anchor = 7, .caret = 7 },
                .single_line = true,
            }) catch return error.Failed;
        }
    };
    var fields = view_runtime.field.Registry.init(.here);
    defer fields.deinit(std.testing.allocator);
    var fixture: Fixture = .{};
    var bridge = Bridge.init(std.testing.allocator, .{ .context = &fixture, .invoke_edit = Fixture.invoke });
    defer bridge.deinit();
    fixture.bridge = &bridge;
    fixture.ref = try bridge.register(&fields, owner, 7, .{
        .revision = "1",
        .bytes = "name",
        .selection = .{ .anchor = 0, .caret = 4 },
        .single_line = true,
    });
    const provider = fields.get(fixture.ref).?;
    try provider.edit("1", .{ .start = 0, .end = 4, .replacement = "renamed", .selection_after = .{ .anchor = 7, .caret = 7 } });
    try std.testing.expectEqual(@as(usize, 1), fixture.calls);
    var snapshot = try provider.snapshot(std.testing.allocator);
    defer snapshot.deinit();
    try std.testing.expectEqualStrings("2", snapshot.value.revision);
    try std.testing.expectEqualStrings("renamed", snapshot.value.bytes);
    try std.testing.expectError(error.Stale, provider.edit("1", .{ .start = 0, .end = 0, .replacement = "x" }));
}

test "sandbox field rejects duplicate tokens and callbacks that do not update" {
    const owner: semantic.owner.Id = @enumFromInt(1);
    const Decline = struct {
        fn invoke(_: *anyopaque, _: u32) CallbackError!void {}
    };
    var fields = view_runtime.field.Registry.init(.here);
    defer fields.deinit(std.testing.allocator);
    var marker: u8 = 0;
    var bridge = Bridge.init(std.testing.allocator, .{ .context = &marker, .invoke_edit = Decline.invoke });
    defer bridge.deinit();
    const ref = try bridge.register(&fields, owner, 1, .{ .revision = "1", .bytes = "x", .selection = .{ .anchor = 1, .caret = 1 } });
    try std.testing.expectError(error.DuplicateToken, bridge.register(&fields, owner, 1, .{ .revision = "1", .bytes = "y", .selection = .{ .anchor = 0, .caret = 0 } }));
    try std.testing.expectError(error.Failed, fields.get(ref).?.edit("1", .{ .start = 1, .end = 1, .replacement = "!" }));
    try bridge.remove(&fields, owner, ref);
    try std.testing.expect(fields.get(ref) == null);
}
