//! Generic semantic action controller for a dired model.
//!
//! This layer translates stable row-node requests into model operations. It
//! owns no key policy, editor mode, confirmation UI, or filesystem provider;
//! those concerns remain outside the plugin model.

const std = @import("std");
const semantic = @import("weft_semantic");
const fs = @import("weft_fs");
const model = @import("weft_dired_model");
const projection = @import("weft_dired_projection");

const action = semantic.action;
const selection = semantic.selection;
const transfer = semantic.transfer;
const view = semantic.view;
const contract = fs.contract;

pub const max_selection: usize = 4096;

pub const Error = error{
    InvalidView,
    UnknownSubject,
    StaleSubject,
    AmbiguousSubject,
    InvalidSelection,
    MissingTransfer,
    InvalidTransfer,
} || std.mem.Allocator.Error;

pub const Controller = struct {
    gpa: std.mem.Allocator,
    model: *model.Model,
    view_ref: view.Ref,
    capture: ?transfer.OwnedItem = null,

    pub fn init(gpa: std.mem.Allocator, dired: *model.Model, view_ref: view.Ref) Controller {
        return .{ .gpa = gpa, .model = dired, .view_ref = view_ref };
    }

    pub fn deinit(self: *Controller) void {
        self.clearCapture();
        self.* = undefined;
    }

    /// Captures remain borrowed from the controller until the next copy/cut,
    /// deinit, or explicit clear. This matches the semantic action outcome's
    /// synchronous lifetime and permits a later controller to paste it.
    pub fn captured(self: *const Controller) ?transfer.Item {
        return if (self.capture) |item| item.value else null;
    }

    pub fn clearCapture(self: *Controller) void {
        if (self.capture) |*item| item.deinit();
        self.capture = null;
    }

    pub fn invoke(self: *Controller, request: action.Request) Error!action.Outcome {
        if (self.view_ref.generation == 0) return error.InvalidView;
        if (!self.view_ref.eql(request.view)) return .declined;

        const is_paste = std.mem.eql(u8, request.action, action.standard.paste_before) or
            std.mem.eql(u8, request.action, action.standard.paste_after);
        const subject = try self.resolveRow(request.subject, is_paste);
        const selected = try self.resolveSelection(request, subject, is_paste);
        defer self.gpa.free(selected);
        if (std.mem.eql(u8, request.action, action.standard.copy) or
            std.mem.eql(u8, request.action, action.standard.cut))
        {
            if (selected.len != 1) return error.AmbiguousSubject;
            const intent: transfer.Intent = if (std.mem.eql(u8, request.action, action.standard.copy)) .copy else .cut;
            const next = self.model.yank(selected[0], intent) catch |err| return mapModelError(err);
            self.clearCapture();
            self.capture = next;
            return .{ .transfer = self.capture.?.value };
        }

        if (std.mem.eql(u8, request.action, action.standard.delete)) {
            // All subjects are resolved before the first mutation, so an
            // unknown or stale selection cannot produce a partial delete.
            for (selected) |id| self.model.markDelete(id) catch |err| return mapModelError(err);
            return .handled;
        }

        if (is_paste) {
            if (selected.len != 1) return error.AmbiguousSubject;
            const item = request.transfer orelse return error.MissingTransfer;
            var owned = transfer.OwnedItem.init(self.gpa, item) catch |err| return mapTransferError(err);
            defer owned.deinit();
            const placement: model.PastePlacement = if (std.mem.eql(u8, request.action, action.standard.paste_before)) .before else .after;
            _ = self.model.pasteAt(.{ .row = subject, .parent = self.model.row(subject).?.parent }, placement, &owned) catch |err| return mapModelError(err);
            return .handled;
        }

        return .declined;
    }

    fn resolveRow(self: *const Controller, node: semantic.scene.NodeId, allow_deleted: bool) Error!model.NodeId {
        const id = projection.modelRowId(node) catch return error.UnknownSubject;
        const row = self.model.row(id) orelse return error.UnknownSubject;
        if (row.conflict == .stale or (!allow_deleted and row.pending == .deleted)) return error.StaleSubject;
        return id;
    }

    fn resolveSelection(self: *const Controller, request: action.Request, subject: model.NodeId, allow_deleted: bool) Error![]model.NodeId {
        return switch (request.selection) {
            .none => blk: {
                const ids = try self.gpa.alloc(model.NodeId, 1);
                ids[0] = subject;
                break :blk ids;
            },
            .nodes => |nodes| blk: {
                if (nodes.len == 0 or nodes.len > max_selection or nodes.len != 1) return error.AmbiguousSubject;
                const ids = try self.gpa.alloc(model.NodeId, nodes.len);
                errdefer self.gpa.free(ids);
                for (nodes, ids) |node, *id| id.* = try self.resolveRow(node, allow_deleted);
                for (ids, 0..) |id, index| for (ids[index + 1 ..]) |later| if (id == later) return error.AmbiguousSubject;
                break :blk ids;
            },
            .text, .custom => return error.InvalidSelection,
        };
    }
};

fn mapTransferError(err: anyerror) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidTransfer,
    };
}

fn mapModelError(err: anyerror) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.StaleAnchor, error.StaleParent, error.Stale => error.StaleSubject,
        error.UnknownAnchor, error.UnknownParent, error.UnknownNode => error.UnknownSubject,
        error.InvalidTransfer, error.UnsupportedTransfer, error.TransferTooLarge => error.InvalidTransfer,
        else => error.InvalidSelection,
    };
}

fn ref(slot: u32, generation: u32) contract.EntryRef {
    return .{ .authority = .here, .slot = slot, .generation = generation };
}

fn rowNode(id: model.NodeId) semantic.scene.NodeId {
    return projection.rowNodeId(id) catch unreachable;
}

test "dired actions capture copy and cut, delete selected rows, and reject ambiguity" {
    var dired = model.Model.init(std.testing.allocator, .{ .authority = .here, .slot = 1, .generation = 1 });
    defer dired.deinit();
    try dired.reconcile(.{ .entries = &.{
        .{ .identity = ref(1, 1), .name = "one", .revision = "r1", .kind = .regular },
        .{ .identity = ref(2, 1), .name = "two", .revision = "r2", .kind = .regular },
    } });
    const first = dired.rows.items[0].id;
    const second = dired.rows.items[1].id;
    var controller = Controller.init(std.testing.allocator, &dired, .{ .authority = .here, .slot = 4, .generation = 1 });
    defer controller.deinit();

    const copied = try controller.invoke(.{ .action = action.standard.copy, .view = controller.view_ref, .subject = rowNode(first) });
    try std.testing.expectEqual(transfer.Intent.copy, copied.transfer.intent);
    try std.testing.expectEqualStrings("one", copied.transfer.suggested_name);
    const cut = try controller.invoke(.{ .action = action.standard.cut, .view = controller.view_ref, .subject = rowNode(first) });
    try std.testing.expectEqual(transfer.Intent.cut, cut.transfer.intent);
    const selected = [_]semantic.scene.NodeId{rowNode(second)};
    _ = try controller.invoke(.{ .action = action.standard.delete, .view = controller.view_ref, .subject = rowNode(first), .selection = .{ .nodes = &selected } });
    try std.testing.expectEqual(model.Pending.deleted, dired.row(second).?.pending);
    const ambiguous = [_]semantic.scene.NodeId{ rowNode(first), rowNode(second) };
    try std.testing.expectError(error.AmbiguousSubject, controller.invoke(.{ .action = action.standard.copy, .view = controller.view_ref, .subject = rowNode(first), .selection = .{ .nodes = &ambiguous } }));
    try std.testing.expectEqual(model.Pending.observed, dired.row(first).?.pending);
}

test "dired actions paste relative to a retained deleted row" {
    var dired = model.Model.init(std.testing.allocator, .{ .authority = .here, .slot = 5, .generation = 1 });
    defer dired.deinit();
    try dired.reconcile(.{ .entries = &.{.{ .identity = ref(5, 1), .name = "kept", .revision = "r1", .kind = .regular }} });
    const id = dired.rows.items[0].id;
    var controller = Controller.init(std.testing.allocator, &dired, .{ .authority = .here, .slot = 5, .generation = 1 });
    defer controller.deinit();

    const copied = try controller.invoke(.{ .action = action.standard.copy, .view = controller.view_ref, .subject = rowNode(id) });
    _ = try controller.invoke(.{ .action = action.standard.delete, .view = controller.view_ref, .subject = rowNode(id) });
    _ = try controller.invoke(.{
        .action = action.standard.paste_after,
        .view = controller.view_ref,
        .subject = rowNode(id),
        .transfer = copied.transfer,
    });

    try std.testing.expectEqual(@as(usize, 2), dired.rows.items.len);
    try std.testing.expectEqual(model.Pending.deleted, dired.rows.items[0].pending);
    try std.testing.expectEqual(model.Pending.copied, dired.rows.items[1].pending);
    try std.testing.expectEqualStrings("kept", dired.rows.items[1].draft.name);
}

test "dired actions paste before and after across model instances" {
    var source = model.Model.init(std.testing.allocator, .{ .authority = .here, .slot = 10, .generation = 1 });
    defer source.deinit();
    try source.reconcile(.{ .entries = &.{.{ .identity = ref(10, 1), .name = "captured", .revision = "r", .kind = .regular }} });
    var source_controller = Controller.init(std.testing.allocator, &source, .{ .authority = .here, .slot = 1, .generation = 1 });
    defer source_controller.deinit();
    const source_id = source.rows.items[0].id;
    const captured = try source_controller.invoke(.{ .action = action.standard.copy, .view = source_controller.view_ref, .subject = rowNode(source_id) });

    var destination = model.Model.init(std.testing.allocator, .{ .authority = .here, .slot = 11, .generation = 1 });
    defer destination.deinit();
    try destination.reconcile(.{ .entries = &.{
        .{ .identity = ref(11, 1), .name = "left", .revision = "r", .kind = .regular },
        .{ .identity = ref(12, 1), .name = "right", .revision = "r", .kind = .regular },
    } });
    var destination_controller = Controller.init(std.testing.allocator, &destination, .{ .authority = .here, .slot = 2, .generation = 1 });
    defer destination_controller.deinit();
    const right = destination.rows.items[1].id;
    _ = try destination_controller.invoke(.{ .action = action.standard.paste_before, .view = destination_controller.view_ref, .subject = rowNode(right), .transfer = captured.transfer });
    try std.testing.expectEqualStrings("left", destination.rows.items[0].draft.name);
    try std.testing.expectEqualStrings("captured", destination.rows.items[1].draft.name);
    try std.testing.expectEqualStrings("right", destination.rows.items[2].draft.name);
    const left = destination.rows.items[0].id;
    _ = try destination_controller.invoke(.{ .action = action.standard.paste_after, .view = destination_controller.view_ref, .subject = rowNode(left), .transfer = captured.transfer });
    try std.testing.expectEqualStrings("left", destination.rows.items[0].draft.name);
    try std.testing.expectEqualStrings("captured", destination.rows.items[1].draft.name);
}

test "dired actions reject unknown and stale subjects transactionally" {
    var dired = model.Model.init(std.testing.allocator, .{ .authority = .here, .slot = 20, .generation = 1 });
    defer dired.deinit();
    try dired.reconcile(.{ .entries = &.{.{ .identity = ref(20, 1), .name = "stale", .revision = "r", .kind = .regular }} });
    const id = dired.rows.items[0].id;
    var controller = Controller.init(std.testing.allocator, &dired, .{ .authority = .here, .slot = 3, .generation = 1 });
    defer controller.deinit();
    try std.testing.expectError(error.UnknownSubject, controller.invoke(.{ .action = action.standard.delete, .view = controller.view_ref, .subject = @enumFromInt(1) }));
    try dired.rename(id, "draft");
    try dired.reconcile(.{ .entries = &.{} });
    try std.testing.expectError(error.StaleSubject, controller.invoke(.{ .action = action.standard.delete, .view = controller.view_ref, .subject = rowNode(id) }));
    try std.testing.expectEqual(model.Pending.renamed, dired.row(id).?.pending);
}
