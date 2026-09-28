//! Search retained presentation values, resolving results by stable node identity.
//! No document, filesystem, or input grammar is involved.
const std = @import("std");
const model = @import("weft_semantic");
const command = @import("command.zig");
const pick = @import("pick.zig");
const Services = @import("semantic.zig").Services;

const Search = struct {
    arena: std.heap.ArenaAllocator,
    view: model.view.Ref,
    revision: u64,
    nodes: std.ArrayList(model.scene.NodeId) = .empty,
    entries: std.ArrayList(pick.Entry) = .empty,

    fn collect(self: *Search, services: *Services, node: model.scene.Node, parent: ?model.scene.NodeId) !void {
        const gpa = self.arena.allocator();
        const subject = if (node.focusable) node.id else parent;
        switch (node.content) {
            .container => |container| for (container.children) |child| try self.collect(services, child, subject),
            .field => |field| {
                const provider = services.fields.get(field.ref) orelse return;
                var snapshot = try provider.snapshot(gpa);
                defer snapshot.deinit();
                if (subject) |id| try self.add(id, snapshot.value.bytes);
            },
            .label => |label| if (subject) |id| try self.add(id, label),
            .action => |action| if (subject) |id| try self.add(id, action.label),
        }
    }

    fn add(self: *Search, node: model.scene.NodeId, text: []const u8) !void {
        if (text.len == 0) return;
        const gpa = self.arena.allocator();
        try self.entries.append(gpa, .{ .text = try gpa.dupe(u8, text) });
        try self.nodes.append(gpa, node);
    }

    fn accept(ctx: *command.Context, raw: ?*anyopaque, outcome: pick.Outcome) !void {
        const self: *Search = @ptrCast(@alignCast(raw.?));
        const candidate = switch (outcome) {
            .candidate => |value| value,
            else => return,
        };
        const services = ctx.semantic orelse return;
        const path = ctx.head.scene_selection.path() orelse return;
        if (!std.meta.eql(path.view, self.view)) return;
        const view = services.views.get(self.view) orelse return;
        // A refreshed scene may have removed or repurposed a candidate. Never
        // apply presentation match coordinates to a different snapshot.
        if (view.descriptor.revision != self.revision) return;
        if (candidate.index >= self.nodes.items.len) return;
        const node = self.nodes.items[candidate.index];
        const current = view.node(node) orelse return;
        const field = switch (current.content) {
            .field => |value| value.ref,
            else => null,
        };
        if (field) |ref| {
            const provider = services.fields.get(ref) orelse return;
            var snapshot = try provider.snapshot(ctx.gpa);
            defer snapshot.deinit();
            if (!std.mem.eql(u8, snapshot.value.bytes, candidate.text)) return;
        }
        _ = try services.focusView(ctx.head, ctx.gpa, self.view, node);
        if (field != null) {
            _ = try services.inputFocusedField(ctx.head, ctx.gpa, .clear_selection);
            _ = try services.inputFocusedField(ctx.head, ctx.gpa, .{ .jump = candidate.match.start });
        }
    }

    fn cleanup(raw: ?*anyopaque, gpa: std.mem.Allocator) void {
        const self: *Search = @ptrCast(@alignCast(raw.?));
        self.arena.deinit();
        gpa.destroy(self);
    }
};

/// False lets another presentation plane implement the same action.
pub fn open(ctx: *command.Context) !bool {
    const services = ctx.semantic orelse return false;
    const path = ctx.head.scene_selection.path() orelse return false;
    const view = services.views.get(path.view) orelse return false;
    const search = try ctx.gpa.create(Search);
    search.* = .{ .arena = .init(ctx.gpa), .view = path.view, .revision = view.descriptor.revision };
    errdefer Search.cleanup(search, ctx.gpa);
    try search.collect(services, view.scene, null);
    try ctx.head.pick.open(ctx, "search", search.entries.items, .{ .handler = Search.accept, .cleanup = Search.cleanup, .data = search });
    return true;
}

test "semantic view edits: search uses scene identity without a text document" {
    const t = std.testing;
    const gpa = t.allocator;
    var services: Services = .init(.here);
    defer services.deinit(gpa);
    var env: @import("TestHost.zig") = undefined;
    try @import("TestHost.zig").init(gpa, &env);
    defer env.deinit(gpa);
    env.ctx.semantic = &services;
    try pick.install(gpa, &env.commands, &env.keymap);
    const owner = try services.acquireOwner();
    const scene: model.scene.Node = .{
        .id = @enumFromInt(1),
        .content = .{ .container = .{ .children = &.{
            .{ .id = @enumFromInt(2), .focusable = true, .content = .{ .label = "alpha" } },
            .{ .id = @enumFromInt(3), .focusable = true, .content = .{ .label = "beta" } },
        } } },
    };
    const view = try services.publishView(gpa, owner, null, 1, scene);
    _ = try services.focusView(&env.head, gpa, view, null);
    _ = try env.buffers.attachFocusedSemanticView(gpa, &env.head, &env.keymap, "objects", "synthetic");
    try t.expect(env.buffers.active().textEditor() == null);
    const effect = try @import("action_here.zig").invokeHere(&env.ctx, model.action.standard.search, 0);
    try t.expect(effect.? == .handled);
    _ = try command.run(&env.commands, &env.ctx, "pick.input", &.{.{ .string = "beta" }});
    _ = try command.run(&env.commands, &env.ctx, "pick.accept", &.{});
    try t.expectEqual(@as(model.scene.NodeId, @enumFromInt(3)), env.head.scene_selection.path().?.leaf().?);

    // Replacement invalidates the candidate snapshot even if its node survives.
    try t.expect(try open(&env.ctx));
    _ = try command.run(&env.commands, &env.ctx, "pick.input", &.{.{ .string = "alpha" }});
    try services.replaceView(gpa, owner, view, 2, scene);
    _ = try command.run(&env.commands, &env.ctx, "pick.accept", &.{});
    try t.expectEqual(@as(model.scene.NodeId, @enumFromInt(3)), env.head.scene_selection.path().?.leaf().?);
}
