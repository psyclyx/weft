//! Focus and editing in structural views (doc/chrome.md §5.2): where a focus
//! LANDS in a scene, and the life of an edit of a row's field.
//!
//! Focusing a row and editing its text are different states. A row focus is
//! the scene selection's path; an edit is `SceneSelection.edit`: the field
//! being edited, a text extent inside the row, with the text it held when
//! the edit began — one value, so no field is ever edited without the text a
//! cancel puts back, and ending an edit is one assignment made before
//! anything that can fail. Which one a focus becomes is the granularity the
//! head's mode declares (`Services.granularityFor`, `input.Granularity`),
//! read here and nowhere else:
//!
//!   text  the focus edits the field it lands on — the editable listings
//!         vim, helix and emacs keep, whose modes decide the keys.
//!   row   the focus is the row. An edit is BEGUN (`std.editing.begin`, a
//!         slow second click, a provider entering a field), takes printable
//!         input itself (`textCommit`), and ends by commit — activating it,
//!         or moving the focus off its row — or by cancel, which puts back
//!         the text it began from. Under `row` every edit is a begun one
//!         (`begun`): there is no field edited that nothing types into.
//!
//! What a row's text IS stays the projection's: it marks one PRIMARY field
//! per row (`scene.Content.field.primary`) and learns nothing else. Committing
//! applies the view's own draft (`view.apply`), when the edit changed it.

const std = @import("std");
const semantic = @import("weft_semantic");
const view_runtime = @import("weft_view_runtime");
const Head = @import("Head.zig");
const Keymap = @import("Keymap.zig");
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

/// Whether `head` holds a BEGUN edit: an edit under `row` granularity,
/// which takes printable input itself, answers activation as commit and
/// cancel as cancel, and commits when the focus leaves its row. Under
/// `text` an edit is the grammar's modes' to drive.
pub fn begun(services: *const Services, head: *const Head) bool {
    return head.scene_selection.edit != null and services.granularityFor(head) == .row;
}

/// Where a printable keystroke nothing bound goes as TEXT in `mode`, or
/// null when it inserts nothing: the mode's commit command, else core's own
/// `edit.insert-text` while a begun edit holds a field — the edit took the
/// keys, whatever the resting mode says. The one question the commit path,
/// type-ahead and the caret shape ask, so a bar can never be drawn where
/// typing does nothing, nor rows jump while a line takes text.
pub fn textCommit(services: ?*const Services, km: *const Keymap, head: *const Head, mode: []const u8) ?[]const u8 {
    if (km.commitCommand(mode)) |cmd| return cmd;
    const s = services orelse return null;
    if (head.scene_selection.edit != null and s.granularityIn(mode) == .row) return "edit.insert-text";
    return null;
}

/// Make `path` the head's focus. Under `row`, an edit in progress on
/// another row is committed first, and landing on the row being edited
/// keeps the edit.
pub fn land(services: *Services, head: *Head, gpa: std.mem.Allocator, path: semantic.focus.Path, how: How) std.mem.Allocator.Error!void {
    const selection = &head.scene_selection;
    const rows = services.granularityFor(head) == .row;
    if (rows) if (selection.edit) |edit| {
        if (selection.path()) |current| if (current.view.eql(path.view) and current.leaf() == path.leaf()) {
            var kept = path;
            kept.field = edit.field;
            return selection.set(gpa, kept);
        };
        _ = commit(services, head, gpa) catch |err| blk: {
            std.log.warn("scene_edit: committing the edit a focus left failed: {t}", .{err});
            break :blk false;
        };
    };
    var next = path;
    if (how == .navigate and rows) next.field = null;
    try selection.set(gpa, next);
    if (next.field) |field| try startEdit(services, selection, gpa, field);
}

pub const Error = Services.FieldInputError || view_runtime.view.Error || error{ActionRefused};

/// `std.editing.begin`: edit the focused row's primary field. Under `row`
/// granularity the edit is BEGUN — all of it selected, so typing replaces
/// it (the platform convention). Under `text` the focus already edits; this
/// only moves it onto the primary field. False when the focus holds no row
/// with a field.
pub fn begin(services: *Services, head: *Head, gpa: std.mem.Allocator) Error!bool {
    const selection = &head.scene_selection;
    const path = selection.path() orelse return false;
    const instance = services.views.get(path.view) orelse return false;
    if (begun(services, head)) return true;
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
    try selection.startEdit(gpa, target.ref, snapshot.value.bytes);
    // The primary field may not be the leaf navigation stops on; the row
    // stays where the next move is measured from.
    if (row != target.node) selection.setNavigationAnchor(row);
    if (services.granularityFor(head) == .text) return true;
    try provider.edit(snapshot.value.revision, .{ .start = 0, .end = 0, .replacement = &.{}, .selection_after = .{
        .anchor = 0,
        .caret = snapshot.value.bytes.len,
    } });
    return true;
}

/// End a begun edit, keeping what was typed, and apply the view's draft
/// when the edit changed it — the listing's own `view.apply`, which may
/// ask first. The focus goes back to the row. False when no edit was begun.
/// The edit is over before anything here can fail.
pub fn commit(services: *Services, head: *Head, gpa: std.mem.Allocator) !bool {
    if (!begun(services, head)) return false;
    const selection = &head.scene_selection;
    const edit = selection.edit.?;
    selection.edit = null;
    const changed = try changedFrom(services, edit, gpa);
    if (!changed) return true;
    _ = services.invokeFocusedAction(&head.interactions, head, gpa, standard.apply) catch |err| switch (err) {
        error.ActionUnavailable, error.ProviderUnavailable => {},
        else => return err,
    };
    return true;
}

/// End a begun edit, putting back the text it began from. False when no
/// edit was begun. The edit is over before anything here can fail.
pub fn cancel(services: *Services, head: *Head, gpa: std.mem.Allocator) Services.FieldInputError!bool {
    if (!begun(services, head)) return false;
    const selection = &head.scene_selection;
    const edit = selection.edit.?;
    selection.edit = null;
    const provider = services.fields.get(edit.field) orelse return error.StaleField;
    var snapshot = try provider.snapshot(gpa);
    defer snapshot.deinit();
    const at: u64 = edit.origin.len;
    try provider.edit(snapshot.value.revision, .{
        .start = 0,
        .end = snapshot.value.bytes.len,
        .replacement = edit.origin,
        .selection_after = .{ .anchor = at, .caret = at },
    });
    return true;
}

/// Select the word at the caret of the field being edited — a double click
/// inside the edit, which belongs to the field as it does in any text field.
/// False when nothing is being edited.
pub fn selectWord(services: *Services, head: *Head, gpa: std.mem.Allocator) Services.FieldInputError!bool {
    const edit = head.scene_selection.edit orelse return false;
    const provider = services.fields.get(edit.field) orelse return error.StaleField;
    var snapshot = try provider.snapshot(gpa);
    defer snapshot.deinit();
    const bytes = snapshot.value.bytes;
    const caret: usize = @min(@as(usize, @intCast(snapshot.value.selection.caret)), bytes.len);
    var start = caret;
    while (start > 0 and wordByte(bytes[start - 1])) start -= 1;
    var end = caret;
    while (end < bytes.len and wordByte(bytes[end])) end += 1;
    try provider.edit(snapshot.value.revision, .{ .start = 0, .end = 0, .replacement = &.{}, .selection_after = .{
        .anchor = start,
        .caret = end,
    } });
    return true;
}

fn wordByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_' or byte >= 0x80;
}

/// Start editing `field` with the text it holds now as its origin — unless
/// it is the field already being edited, whose origin stands.
fn startEdit(services: *Services, selection: *Head.SceneSelection, gpa: std.mem.Allocator, field: semantic.scene.FieldRef) std.mem.Allocator.Error!void {
    if (selection.edit) |edit| if (edit.field.eql(field)) return;
    const provider = services.fields.get(field) orelse return;
    var snapshot = provider.snapshot(gpa) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        // A field that cannot say what it holds cannot be edited.
        else => return,
    };
    defer snapshot.deinit();
    try selection.startEdit(gpa, field, snapshot.value.bytes);
}

fn changedFrom(services: *Services, edit: Head.SceneSelection.Edit, gpa: std.mem.Allocator) !bool {
    const provider = services.fields.get(edit.field) orelse return false;
    var snapshot = try provider.snapshot(gpa);
    defer snapshot.deinit();
    return !std.mem.eql(u8, snapshot.value.bytes, edit.origin);
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

const t = std.testing;

/// A host-memory field: the provider contract, nothing else.
const Memory = struct {
    bytes: std.ArrayList(u8) = .empty,
    selection: view_runtime.field.Selection = .{ .anchor = 0, .caret = 0 },
    revision: u64 = 1,
    /// Refuse snapshots, as a provider whose plugin went away does.
    gone: bool = false,

    fn deinit(self: *Memory) void {
        self.bytes.deinit(t.allocator);
    }

    pub fn snapshot(self: *Memory, gpa: std.mem.Allocator) view_runtime.field.Error!view_runtime.field.OwnedSnapshot {
        if (self.gone) return error.Stale;
        var owned = view_runtime.field.OwnedSnapshot.init(gpa);
        errdefer owned.deinit();
        const arena = owned.allocator();
        owned.value = .{
            .revision = try std.fmt.allocPrint(arena, "{d}", .{self.revision}),
            .bytes = try arena.dupe(u8, self.bytes.items),
            .selection = self.selection,
            .single_line = true,
        };
        return owned;
    }

    pub fn edit(self: *Memory, expected: []const u8, value: view_runtime.field.Edit) view_runtime.field.Error!void {
        var buf: [32]u8 = undefined;
        if (!std.mem.eql(u8, expected, std.fmt.bufPrint(&buf, "{d}", .{self.revision}) catch unreachable)) return error.Stale;
        try self.bytes.replaceRange(t.allocator, @intCast(value.start), @intCast(value.end - value.start), value.replacement);
        if (value.selection_after) |selection| self.selection = selection;
        self.revision += 1;
    }
};

test "scene_edit: under `row` a focus is the row; begin edits the primary field, cancel puts it back; under `text` a focus edits" {
    const gpa = t.allocator;
    var name: Memory = .{};
    defer name.deinit();
    try name.bytes.appendSlice(gpa, "a.txt");
    var services = Services.init(.here);
    defer services.deinit(gpa);
    const owner = try services.acquireOwner();
    const ref = try services.insertField(gpa, owner, .init(&name));
    // A row of a label and its primary name field; the row is what the focus
    // order visits.
    const cells = [_]semantic.scene.Node{
        .{ .id = @enumFromInt(3), .content = .{ .label = "·" } },
        .{ .id = @enumFromInt(4), .content = .{ .field = .{ .ref = ref, .single_line = true, .primary = true } } },
    };
    const rows = [_]semantic.scene.Node{
        .{ .id = @enumFromInt(2), .focusable = true, .content = .{ .container = .{ .axis = .horizontal, .children = &cells } } },
    };
    const view = try services.publishView(gpa, owner, null, 1, .{ .id = @enumFromInt(1), .content = .{ .container = .{ .children = &rows } } });
    var head: Head = .empty;
    defer head.deinit(gpa);

    try t.expectEqual(@import("weft_input").Granularity.row, services.granularityFor(&head));
    _ = try services.focusView(&head, gpa, view, @enumFromInt(2));
    try t.expect(head.scene_selection.edit == null);

    // Begin: the primary field is edited, all of it selected, its text kept.
    try t.expect(try begin(&services, &head, gpa));
    try t.expect(begun(&services, &head));
    try t.expect(head.scene_selection.edit.?.field.eql(ref));
    try t.expectEqual(@as(u64, 5), name.selection.caret);
    try t.expect(try services.inputFocusedField(&head, gpa, .{ .commit = .from("b") }));
    try t.expectEqualStrings("b", name.bytes.items);
    // Cancel restores it, and the focus is the row again.
    try t.expect(try cancel(&services, &head, gpa));
    try t.expectEqualStrings("a.txt", name.bytes.items);
    try t.expect(head.scene_selection.edit == null);
    try t.expect(!try cancel(&services, &head, gpa));

    // Commit keeps the text; unchanged, it applies nothing, and the focus is
    // the row again.
    try t.expect(try begin(&services, &head, gpa));
    try t.expect(try commit(&services, &head, gpa));
    try t.expect(head.scene_selection.edit == null);

    // Under `text` the same focus edits the field it lands on, and nothing
    // was begun: the grammar's own modes own the keys.
    services.granularity_of = .always(.text);
    _ = try services.focusView(&head, gpa, view, @enumFromInt(4));
    try t.expect(head.scene_selection.edit.?.field.eql(ref));
    try t.expect(!begun(&services, &head));
}

/// A fixture: one row holding its primary name field, `a.txt`.
const OneRow = struct {
    name: Memory = .{},
    services: Services = Services.init(.here),
    head: Head = .empty,
    view: semantic.view.Ref = undefined,
    ref: semantic.scene.FieldRef = undefined,

    fn init(self: *OneRow) !void {
        const gpa = t.allocator;
        try self.name.bytes.appendSlice(gpa, "a.txt");
        const owner = try self.services.acquireOwner();
        self.ref = try self.services.insertField(gpa, owner, .init(&self.name));
        const cells = [_]semantic.scene.Node{
            .{ .id = @enumFromInt(4), .content = .{ .field = .{ .ref = self.ref, .single_line = true, .primary = true } } },
        };
        const rows = [_]semantic.scene.Node{
            .{ .id = @enumFromInt(2), .focusable = true, .content = .{ .container = .{ .axis = .horizontal, .children = &cells } } },
        };
        self.view = try self.services.publishView(gpa, owner, null, 1, .{ .id = @enumFromInt(1), .content = .{ .container = .{ .children = &rows } } });
    }

    fn deinit(self: *OneRow) void {
        self.head.deinit(t.allocator);
        self.services.deinit(t.allocator);
        self.name.deinit();
    }
};

test "scene_edit: an edit whose commit fails is over all the same — no field is left edited with nothing taking its keys" {
    const gpa = t.allocator;
    var f: OneRow = .{};
    try f.init();
    defer f.deinit();
    _ = try f.services.focusView(&f.head, gpa, f.view, @enumFromInt(2));
    try t.expect(try begin(&f.services, &f.head, gpa));

    // The provider goes away mid-edit: the commit fails, and the edit ends.
    f.name.gone = true;
    try t.expectError(error.Stale, commit(&f.services, &f.head, gpa));
    try t.expect(f.head.scene_selection.edit == null);
    try t.expect(f.head.scene_selection.path().?.field == null);
    // …and a cancel that fails the same way.
    f.name.gone = false;
    try t.expect(try begin(&f.services, &f.head, gpa));
    f.name.gone = true;
    try t.expectError(error.Stale, cancel(&f.services, &f.head, gpa));
    try t.expect(f.head.scene_selection.edit == null);
}

test "scene_edit: an edit made under `text` is a begun one once the head's mode focuses rows — its keys go to it, and cancel puts back its origin" {
    const gpa = t.allocator;
    var f: OneRow = .{};
    try f.init();
    defer f.deinit();
    const Switch = struct {
        granularity: @import("weft_input").Granularity = .text,
        fn get(ctx: *anyopaque, _: []const u8) @import("weft_input").Granularity {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            return self.granularity;
        }
    };
    var grammar: Switch = .{};
    f.services.granularity_of = .{ .ctx = &grammar, .get = Switch.get };
    _ = try f.services.focusView(&f.head, gpa, f.view, @enumFromInt(4));
    try t.expect(f.head.scene_selection.edit != null);
    var km: Keymap = .empty;
    defer km.deinit(gpa);
    // Under `text` the grammar's mode decides the keys: none here.
    try t.expect(textCommit(&f.services, &km, &f.head, "normal") == null);

    grammar.granularity = .row;
    // Under `row` the same edit takes the keys itself, and ends as any does.
    try t.expectEqualStrings("edit.insert-text", textCommit(&f.services, &km, &f.head, "normal").?);
    try t.expect(try f.services.inputFocusedField(&f.head, gpa, .{ .commit = .from("z") }));
    try t.expect(try cancel(&f.services, &f.head, gpa));
    try t.expectEqualStrings("a.txt", f.name.bytes.items);
    try t.expect(f.head.scene_selection.edit == null);
}
