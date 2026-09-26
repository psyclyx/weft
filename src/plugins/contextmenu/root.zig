//! contextmenu — the offers of the context under the pointer, as a menu
//! (doc/configs.md §3.6.3).
//!
//! `contextmenu` (bound to `mouse-3`) first runs `pointer-focus-point`: the
//! pane under the pointer takes focus, and the node there (a listing row) or
//! the caret (in text, unless the click is inside the selection) moves to
//! the point. So the ACTIVE context is exactly the one clicked on, and its
//! offers — the node actions of the row included, which core publishes as
//! `plugin.<id>` offers on the focus path — are the menu. `contextmenu-at-
//! caret` (S-F10, Menu) skips the pointer and opens at the caret.
//!
//! The menu is a head-local semantic INTERACTION over a view this plugin
//! publishes, presented `pointer` or `caret` (the bundled presenter hangs it
//! below that point). Its keys are the interaction's own bindings, consulted
//! before any keymap: Up/Down move, Return runs, Escape closes. A click is a
//! binding too (`mouse-1`): on an item it runs it, anywhere else it closes
//! the menu — so no editor mode is entered and nothing leaks to the text.
//!
//! What is listed is every offer except the words that only make sense as
//! keys (moving, a line break, leaving a posture) — `weft.set("contextmenu",
//! "hide", [...])` replaces that list of name prefixes. A disabled offer is
//! listed, greyed, with its reason, and choosing it echoes the refusal.

const std = @import("std");
const weft = @import("weft");
const affordances = @import("weft_affordances");
const Node = weft.semantic.scene.Node;
const Fact = weft.semantic.scene.Fact;

const root_id: u64 = 1;
const item_base: u64 = 2;
const row_base: u64 = 1 << 32;
const sep_base: u64 = 1 << 33;

const act_up = "contextmenu.up";
const act_down = "contextmenu.down";
const act_choose = "contextmenu.choose";
const act_close = "contextmenu.close";
const act_click = "contextmenu.click";
const act_reopen = "contextmenu.reopen";
const act_swallow = "contextmenu.swallow";

/// The words a menu hides unless a config says otherwise: they are keys'
/// business (moving, a line break, breaking out of a capture).
const default_hide = [_][]const u8{ "std.navigation.", "std.input.", "std.gesture.", "std.editing.insert-line-break" };

const Item = struct {
    intention: []const u8,
    label: []const u8,
    group: []const u8,
    /// The reason it cannot run now; empty when it can.
    reason: []const u8,
};

var arena: std.heap.ArenaAllocator = undefined;
var items: std.ArrayList(Item) = .empty;
var selected: usize = 0;
var view_ref: ?weft.semantic.view.Ref = null;
var interaction: ?weft.semantic.interaction.Ref = null;
var revision: u32 = 0;
var presentation: []const u8 = "pointer";

const cmds = [_]weft.CommandEntry{
    .{ .name = "contextmenu", .call = openAtPointer, .summary = "open a menu of what the context under the pointer offers" },
    .{ .name = "contextmenu-at-caret", .call = openAtCaret, .summary = "open a menu of what the focused context offers, at the caret" },
    .{ .name = "contextmenu-key", .call = key, .params = "input", .summary = "drive the open context menu (up, down, choose, close, click)" },
};

comptime {
    weft.plugin(&cmds, .{ .init = init }).exportAll();
    weft.exportCallback("on_semantic_action", &onSemanticAction);
}

fn init() void {
    arena = std.heap.ArenaAllocator.init(weft.allocator);
    _ = weft.semanticActionProvider();
}

fn openAtPointer() void {
    close();
    // Make the context under the pointer the active one first.
    weft.run("pointer-focus-point");
    openMenu("pointer");
}

fn openAtCaret() void {
    close();
    openMenu("caret");
}

fn hidden(name: []const u8) bool {
    if (weft.configList("hide")) |list| {
        var it = list;
        while (it.next()) |prefix| if (prefix.len > 0 and std.mem.startsWith(u8, name, prefix)) return true;
        return false;
    }
    for (default_hide) |prefix| if (std.mem.startsWith(u8, name, prefix)) return true;
    return false;
}

fn openMenu(where: []const u8) void {
    _ = arena.reset(.retain_capacity);
    items = .empty;
    selected = 0;
    presentation = where;
    collect(arena.allocator()) catch return;
    if (items.items.len == 0) {
        weft.echo("nothing to offer here");
        return;
    }
    // Land on the first thing that can run.
    for (items.items, 0..) |it, i| if (it.reason.len == 0) {
        selected = i;
        break;
    };
    publish() catch return;
    interaction = weft.semanticInteractionOpen(.{
        .role = .popup,
        .view = view_ref.?,
        .root = @enumFromInt(root_id),
        .actions = &.{
            .{ .id = act_up },    .{ .id = act_down },   .{ .id = act_choose },  .{ .id = act_close },
            .{ .id = act_click }, .{ .id = act_reopen }, .{ .id = act_swallow },
        },
        .bindings = &.{
            .{ .input = "Up", .action = act_up },
            .{ .input = "Down", .action = act_down },
            .{ .input = "Return", .action = act_choose },
            .{ .input = "KP_Enter", .action = act_choose },
            .{ .input = "Escape", .action = act_close },
            .{ .input = "S-F10", .action = act_close },
            .{ .input = "Menu", .action = act_close },
            .{ .input = "mouse-1", .action = act_click },
            .{ .input = "mouse-3", .action = act_reopen },
            // The rest of a click that opened or chose: never the text's.
            .{ .input = "up-mouse-1", .action = act_swallow },
            .{ .input = "up-mouse-3", .action = act_swallow },
            .{ .input = "drag-mouse-1", .action = act_swallow },
        },
        .default_action = act_choose,
        .cancel_action = act_close,
        .presentation = presentation,
    }) catch null;
    if (interaction == null) closeView();
}

fn collect(a: std.mem.Allocator) !void {
    var found: std.ArrayList(Item) = .empty;
    var arrange: std.ArrayList(affordances.Item) = .empty;
    var offers = weft.offersIn(.active);
    while (offers.next()) |o| {
        if (hidden(o.intention)) continue;
        if (found.items.len >= affordances.max_items) break;
        const seq: u32 = @intCast(found.items.len);
        try found.append(a, .{
            .intention = try a.dupe(u8, o.intention),
            .label = try a.dupe(u8, o.label),
            .group = try a.dupe(u8, o.group),
            .reason = switch (o.availability) {
                .enabled => "",
                else => try a.dupe(u8, if (o.reason.len > 0) o.reason else "unavailable"),
            },
        });
        try arrange.append(a, .{ .group = found.items[seq].group, .order = o.order, .seq = seq });
    }
    affordances.arrange(arrange.items);
    for (arrange.items) |it| try items.append(a, found.items[it.seq]);
}

/// Publish (or replace) the menu's view. Only the selected item is in the
/// focus order, so it is the one the presenter highlights; every item is an
/// action node, which a click reaches regardless.
fn publish() !void {
    const a = arena.allocator();
    var rows: std.ArrayList(Node) = .empty;
    for (items.items, 0..) |it, i| {
        if (i > 0 and !std.mem.eql(u8, items.items[i - 1].group, it.group))
            try rows.append(a, .{ .id = @enumFromInt(sep_base + i), .facts = &.{.{ .name = "tone", .value = "muted" }}, .layout = .{ .column = 0 }, .content = .{ .label = "──" } });
        var facts: std.ArrayList(Fact) = .empty;
        try facts.append(a, .{ .name = "name", .value = it.intention });
        if (it.reason.len > 0) try facts.append(a, .{ .name = "tone", .value = "muted" });
        var cells: std.ArrayList(Node) = .empty;
        try cells.append(a, .{
            .id = @enumFromInt(item_base + i),
            .role = "contextmenu.item",
            .facts = try facts.toOwnedSlice(a),
            .layout = .{ .column = 0 },
            .focusable = i == selected,
            .content = .{ .action = .{ .action = act_choose, .label = it.label } },
        });
        if (it.reason.len > 0) try cells.append(a, .{
            .id = @enumFromInt(row_base + (1 << 16) + i),
            .facts = &.{.{ .name = "tone", .value = "muted" }},
            .content = .{ .label = it.reason },
        });
        try rows.append(a, .{
            .id = @enumFromInt(row_base + i),
            .content = .{ .container = .{ .axis = .horizontal, .children = try cells.toOwnedSlice(a) } },
        });
    }
    const root: Node = .{
        .id = @enumFromInt(root_id),
        .role = "contextmenu",
        .content = .{ .container = .{ .axis = .vertical, .children = try rows.toOwnedSlice(a) } },
    };
    revision += 1;
    if (view_ref) |ref| {
        if (weft.semanticViewReplace(ref, revision, root)) |_| return else |_| view_ref = null;
    }
    view_ref = try weft.semanticViewPublish(root, null, revision);
}

fn closeView() void {
    if (view_ref) |ref| _ = weft.semanticViewClose(ref);
    view_ref = null;
}

fn close() void {
    if (interaction) |ref| _ = weft.semanticInteractionClose(ref);
    interaction = null;
    closeView();
}

/// Close, then run the chosen offer where the menu was opened — the active
/// context, which opening made the one under the pointer.
fn choose(i: usize) void {
    if (i >= items.items.len) return close();
    const it = items.items[i];
    close();
    switch (weft.invokeIntentionIn(.active, it.intention)) {
        .invoked => {},
        // A refusal already says what refused and why.
        .refused => |why| weft.echo(why),
        .unknown => echoWhy(it.label, "not-offered-here"),
    }
}

fn echoWhy(label: []const u8, why: []const u8) void {
    var buf: [256]u8 = undefined;
    weft.echo(std.fmt.bufPrint(&buf, "{s}: {s}", .{ label, why }) catch return);
}

/// The interaction's actions arrive as semantic callbacks, which are not
/// dispatching entries; each runs as this plugin's own command, which is.
fn onSemanticAction() callconv(.c) void {
    var request = weft.semanticActionCurrent(weft.allocator) catch return;
    defer request.deinit();
    const action = request.value.action;
    const verb: []const u8 = if (std.mem.eql(u8, action, act_up))
        "up"
    else if (std.mem.eql(u8, action, act_down))
        "down"
    else if (std.mem.eql(u8, action, act_choose))
        "choose"
    else if (std.mem.eql(u8, action, act_close))
        "close"
    else if (std.mem.eql(u8, action, act_click))
        "click"
    else if (std.mem.eql(u8, action, act_reopen))
        "reopen"
    else if (std.mem.eql(u8, action, act_swallow))
        ""
    else {
        _ = weft.semanticActionDecline();
        return;
    };
    _ = weft.semanticActionHandled();
    if (verb.len > 0) weft.runStr("contextmenu-key", verb);
}

fn key() void {
    const verb = weft.argStr(0) orelse return;
    if (interaction == null) return;
    if (std.mem.eql(u8, verb, "up")) {
        if (selected > 0) selected -= 1;
        publish() catch {};
    } else if (std.mem.eql(u8, verb, "down")) {
        if (selected + 1 < items.items.len) selected += 1;
        publish() catch {};
    } else if (std.mem.eql(u8, verb, "choose")) {
        choose(selected);
    } else if (std.mem.eql(u8, verb, "close")) {
        close();
    } else if (std.mem.eql(u8, verb, "click")) {
        // Over one of the menu's items (it covers the focused pane, so a
        // node under the pointer there is the menu's): run it. Anywhere
        // else: close, and the click does nothing more.
        const p = weft.pointer() orelse return close();
        const node = p.node orelse return close();
        if (!p.focused or node < item_base or node >= item_base + items.items.len) return close();
        choose(@intCast(node - item_base));
    } else if (std.mem.eql(u8, verb, "reopen")) {
        openAtPointer();
    }
}
