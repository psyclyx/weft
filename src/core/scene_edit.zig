//! Focus and editing in structural views (doc/chrome.md §5.2): where a focus
//! LANDS in a scene, and the life of an edit of a row's field.
//!
//! Focusing a row and editing its text are different states. A row focus is
//! the scene selection's path; an edit is `SceneSelection.field`, a text
//! extent inside the row. Which one a focus becomes is the loaded grammar's
//! declared granularity (`Services.granularity`, `input.Granularity`), read
//! here and nowhere else:
//!
//!   text  the focus edits the field it lands on — the editable listings
//!         vim, helix and emacs keep, whose modes decide the keys.
//!   row   the focus is the row. An edit is BEGUN (`std.editing.begin`, a
//!         slow second click, a provider entering a field), takes printable
//!         input itself (`Head.textCommit`), and ends by commit — activating
//!         it, or moving the focus off its row — or by cancel, which puts
//!         back the text it began from.
//!
//! What a row's text IS stays the projection's: it marks one PRIMARY field
//! per row (`scene.Content.field.primary`) and learns nothing else. Committing
//! applies the view's own draft (`view.apply`), when the edit changed it.

const std = @import("std");
const semantic = @import("weft_semantic");
const view_runtime = @import("weft_view_runtime");
const Head = @import("Head.zig");
const Services = @import("semantic.zig").Services;

const standard = semantic.action.standard;

/// How a focus arrives.
pub const How = enum {
    /// Navigation: a move, a click, a view opening. The granularity decides
    /// whether a field is edited.
    navigate,
    /// A provider asked to ENTER this node (`Outcome.focus`): a secondary
    /// field, a row it just made. Entering a field is an edit whatever the
    /// granularity — under `row`, a begun one.
    enter,
};

/// Make `path` the head's focus. An edit in progress on another row is
/// committed first; landing on the row being edited keeps the edit.
pub fn land(services: *Services, head: *Head, gpa: std.mem.Allocator, path: semantic.focus.Path, how: How) std.mem.Allocator.Error!void {
    const selection = &head.scene_selection;
    if (selection.began) {
        if (selection.path()) |current| if (current.view.eql(path.view) and current.leaf() == path.leaf()) {
            var kept = path;
            kept.field = selection.field;
            return selection.set(gpa, kept);
        };
        _ = commit(services, head, gpa) catch |err| blk: {
            std.log.warn("scene_edit: committing the edit a focus left failed: {t}", .{err});
            break :blk false;
        };
    }
    var next = path;
    if (how == .navigate and services.granularity == .row) next.field = null;
    try selection.set(gpa, next);
    if (how == .enter and services.granularity == .row and next.field != null) try markBegun(services, head, gpa);
}

pub const Error = Services.FieldInputError || view_runtime.view.Error || error{ActionRefused};

/// `std.editing.begin`: edit the focused row's primary field. Under `row`
/// granularity the edit is BEGUN — its text recorded for cancel, all of it
/// selected, so typing replaces it (the platform convention). Under `text`
/// the focus already edits; this only moves it onto the primary field. False
/// when the focus holds no row with a field.
pub fn begin(services: *Services, head: *Head, gpa: std.mem.Allocator) Error!bool {
    const selection = &head.scene_selection;
    const path = selection.path() orelse return false;
    const instance = services.views.get(path.view) orelse return false;
    if (selection.began) return true;
    // A row that says it cannot be edited now (a stale one) is refused.
    if (advertised(instance, path, standard.edit)) |action| if (!action.enabled) return error.ActionRefused;
    const target = instance.primaryField(path) orelse return false;
    const provider = services.fields.get(target.ref) orelse return error.StaleField;
    var snapshot = try provider.snapshot(gpa);
    defer snapshot.deinit();
    if (snapshot.value.read_only) return error.ReadOnly;
    var storage: [1026]semantic.scene.NodeId = undefined;
    var focus = (try instance.focusPath(target.node, &storage)) orelse return false;
    focus.field = target.ref;
    const row = path.leaf();
    try selection.set(gpa, focus);
    // The primary field may not be the leaf navigation stops on; the row
    // stays where the next move is measured from.
    if (row != target.node) selection.setNavigationAnchor(row);
    if (services.granularity == .text) return true;
    try markBegun(services, head, gpa);
    try provider.edit(snapshot.value.revision, .{ .start = 0, .end = 0, .replacement = &.{}, .selection_after = .{
        .anchor = 0,
        .caret = snapshot.value.bytes.len,
    } });
    return true;
}

/// End a begun edit, keeping what was typed, and apply the view's draft
/// when the edit changed it — the listing's own `view.apply`, which may
/// ask first. The focus goes back to the row. False when no edit was begun.
pub fn commit(services: *Services, head: *Head, gpa: std.mem.Allocator) !bool {
    const selection = &head.scene_selection;
    if (!selection.began) return false;
    const changed = try changedFromOrigin(services, selection, gpa);
    selection.began = false;
    if (services.granularity == .row) selection.field = null;
    if (!changed) return true;
    _ = services.invokeFocusedAction(&head.interactions, head, gpa, standard.apply) catch |err| switch (err) {
        error.ActionUnavailable, error.ProviderUnavailable => {},
        else => return err,
    };
    return true;
}

/// End a begun edit, putting back the text it began from. False when no
/// edit was begun.
pub fn cancel(services: *Services, head: *Head, gpa: std.mem.Allocator) Services.FieldInputError!bool {
    const selection = &head.scene_selection;
    if (!selection.began) return false;
    selection.began = false;
    const field = selection.field orelse return true;
    if (services.granularity == .row) selection.field = null;
    const provider = services.fields.get(field) orelse return error.StaleField;
    var snapshot = try provider.snapshot(gpa);
    defer snapshot.deinit();
    const at: u64 = selection.origin.items.len;
    try provider.edit(snapshot.value.revision, .{
        .start = 0,
        .end = snapshot.value.bytes.len,
        .replacement = selection.origin.items,
        .selection_after = .{ .anchor = at, .caret = at },
    });
    return true;
}

fn markBegun(services: *Services, head: *Head, gpa: std.mem.Allocator) std.mem.Allocator.Error!void {
    const selection = &head.scene_selection;
    selection.origin.clearRetainingCapacity();
    selection.began = true;
    const provider = services.fields.get(selection.field orelse return) orelse return;
    var snapshot = provider.snapshot(gpa) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return,
    };
    defer snapshot.deinit();
    try selection.origin.appendSlice(gpa, snapshot.value.bytes);
}

fn changedFromOrigin(services: *Services, selection: *const Head.SceneSelection, gpa: std.mem.Allocator) !bool {
    const provider = services.fields.get(selection.field orelse return false) orelse return false;
    var snapshot = try provider.snapshot(gpa);
    defer snapshot.deinit();
    return !std.mem.eql(u8, snapshot.value.bytes, selection.origin.items);
}

/// The action `id` as the deepest node on the path advertises it.
fn advertised(instance: *const view_runtime.view.Instance, path: semantic.focus.Path, id: []const u8) ?semantic.scene.Action {
    var index = path.nodes.len;
    while (index > 0) {
        index -= 1;
        const node = instance.node(path.nodes[index]) orelse continue;
        for (node.actions) |action| if (std.mem.eql(u8, action.id, id)) return action;
    }
    return null;
}
