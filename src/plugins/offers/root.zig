//! offers — the provider for designations of kind `offers` (doc/model.md
//! §2.4): what a context offers right now, as a projection.
//!
//!   weft://here/offers/primary      the primary context (the editor, never
//!                                   a docked companion that holds focus)
//!   weft://here/offers/active       the focused context
//!   weft://here/offers/at-pointer   the context under the pointer — made the
//!                                   focused one first (`pointer.focus-point`)
//!
//! presented `as` one of
//!
//!   strip   a row of buttons (the default for `primary`), redrawn when the
//!           primary context's `offers` or `mode` move — never otherwise: no
//!           polling, and a caret move redraws nothing;
//!   list    the same entries down a column;
//!   menu    a transient menu at the pointer (`at-pointer`) or the caret —
//!           the menu widget's (`weft_menu`, doc/chrome.md §2): the rows'
//!           icons and keys, rules between groups, the keyboard and the
//!           pointer as in any menu, and a click anywhere else closes it (the
//!           default for the other two).
//!
//! This is what the toolbar and the context menu were. Neither owns a
//! viewport any more: a toolbar is a config viewport presenting
//! `weft://here/offers/primary` as a strip (config/toolbar.js), and mouse-3
//! presents `offers/at-pointer` as a menu (`offers.menu`). What each lists is
//! the shared `weft_offers` reading — pinned entries (`weft.set("offers",
//! "pinned", [...])`) then the context's offers arranged by their own
//! `group`/`order` — the same reading the palette's offer rows come from.
//! A strip greys what cannot run and keeps it clickable, so the click says
//! why; a menu leaves it out (`weft.set("offers", "hide", [...])` replaces
//! the key words a menu leaves out).
//!
//! A button runs its offer IN the context it describes (`invokeIntentionIn`),
//! so the strip's Undo undoes the editor, not the strip, and focus stays
//! where it was. Hover dispatches nothing yet, so the reason and the winning
//! provider ride on each button as scene facts for a tooltip to read.

const std = @import("std");
const weft = @import("weft");
const offers = @import("weft_offers");
const menu_lib = @import("weft_menu");
const Node = weft.semantic.scene.Node;
const Fact = weft.semantic.scene.Fact;
const durable = weft.semantic.durable;

const kind = "offers";
const root_id: u64 = 1;
const item_base: u64 = 2;
const sep_base: u64 = 1 << 33;
/// The menu's rows (`weft_menu`'s ids), far from any board's.
const menu_base: u64 = 1 << 44;

const act_press = "offers.press";

/// The words a menu leaves out unless a config says otherwise: they are
/// keys' business (moving, a line break, breaking out of a capture).
const default_hide = [_][]const u8{ "std.navigation.", "std.input.", "std.gesture.", "std.editing.insert-line-break" };

/// What a context menu leads with, as every conventional one does: Cut,
/// Copy, Paste — wherever the context offers them (text whose grammar means
/// them, a listing's rows), greyed in place when they cannot run, absent
/// where nothing offers them. `weft.set("offers", "menu-pinned", [...])`
/// replaces the list.
const default_menu_pinned: weft.ConfigIter = .{
    .cur = framed(&.{ "std.transfer.delete-to-register", "std.transfer.yank", "std.transfer.paste" }),
    .remaining = 3,
};

/// Names as a config list's records (a length byte, then the name).
fn framed(comptime names: []const []const u8) []const u8 {
    comptime var out: []const u8 = "";
    inline for (names) |n| {
        if (n.len >= 0x80) @compileError("a one-byte length: " ++ n);
        out = out ++ [_]u8{@intCast(n.len)} ++ n;
    }
    return out;
}

const Layout = enum { strip, list, menu };

/// Which context a designation's ref names.
const Ref = enum {
    primary,
    active,
    at_pointer,

    fn of(text: []const u8) ?Ref {
        if (std.mem.eql(u8, text, "primary")) return .primary;
        if (std.mem.eql(u8, text, "active")) return .active;
        if (std.mem.eql(u8, text, "at-pointer")) return .at_pointer;
        return null;
    }

    fn where(self: Ref) weft.OfferContext {
        return if (self == .primary) .primary else .active;
    }

    fn spelled(self: Ref) []const u8 {
        return switch (self) {
            .primary => "primary",
            .active => "active",
            .at_pointer => "at-pointer",
        };
    }
};

/// One standing presentation — a strip or a list — in its own entry.
const Board = struct {
    ref: Ref,
    layout: Layout,
    arena: std.heap.ArenaAllocator,
    items: []offers.Item = &.{},
    view: ?weft.semantic.view.Ref = null,
    revision: u32 = 0,
};

var boards: std.ArrayList(Board) = .empty;

/// The open menu, if any.
const Menu = struct {
    ref: Ref,
    arena: std.heap.ArenaAllocator,
    items: []offers.Item = &.{},
    cascade: menu_lib.Cascade = .{},
    view: ?weft.semantic.view.Ref = null,
    interaction: ?weft.semantic.interaction.Ref = null,
    revision: u32 = 0,
};
var menu: ?Menu = null;

const cmds = [_]weft.CommandEntry{
    .{ .name = "offers.present", .arity = .whole, .call = present, .params = "designation", .summary = "Present an offers designation (weft://here/offers/<context>?as=strip|list|menu).", .internal = true },
    .{ .name = "offers.menu", .arity = .whole, .call = menuAtPointer, .summary = "Open a menu of what the thing under the pointer offers.", .label = "Context Menu", .prompts = true, .icon = "more" },
    .{ .name = "offers.menu-at-caret", .arity = .whole, .call = menuAtCaret, .summary = "Open a menu of what the focused context offers, at the caret.", .label = "Context Menu at Caret", .prompts = true, .icon = "more" },
    .{ .name = "offers.press", .arity = .whole, .call = press, .params = "button", .summary = "Run the offer a strip button stands for.", .internal = true },
    .{ .name = "offers.menu-key", .arity = .whole, .call = menuKey, .params = "input", .summary = "Move through, choose from or close the open offers menu.", .internal = true },
};

comptime {
    weft.plugin(&cmds, .{ .init = init }).exportAll();
    weft.exportCallback("on_semantic_action", &onSemanticAction);
    weft.exportCallback("on_context_changed", &onContextChanged);
}

fn init() void {
    _ = weft.semanticActionProvider();
    _ = weft.designationOpener(kind, "offers.present");
}

/// The opener: `open weft://here/offers/<context>?as=<layout>` lands here,
/// whether a viewport presents it or a key does.
fn present() void {
    const text = weft.argStr(0) orelse return;
    const d = durable.parse(text) orelse return weft.echo("offers: not a designation");
    const ref = Ref.of(d.ref) orelse return weft.echo("offers: primary, active or at-pointer");
    const as = d.param("as") orelse "";
    const layout: Layout = if (as.len == 0)
        (if (ref == .primary) .strip else .menu)
    else
        std.meta.stringToEnum(Layout, as) orelse return weft.echo("offers: as strip, list or menu");
    switch (layout) {
        .menu => openMenu(ref, ref != .at_pointer),
        .strip, .list => presentBoard(ref, layout),
    }
}

// ── Strip and list ──────────────────────────────────────────────────

/// Make the board's entry active, drawn: what a viewport presenting it then
/// shows. The host puts the head back where it was afterwards.
fn presentBoard(ref: Ref, layout: Layout) void {
    var name_buf: [64]u8 = undefined;
    const name = std.fmt.bufPrint(&name_buf, "*offers {s} {s}*", .{ ref.spelled(), @tagName(layout) }) catch return;
    weft.focusOrCreateBuffer(name);
    weft.toolBacking(kind);
    var designation_buf: [96]u8 = undefined;
    // The entry IS this projection, as-parameter included: a strip is not
    // the list of the same offers, and reopening one must not find the other.
    _ = weft.designate(std.fmt.bufPrint(&designation_buf, "weft://here/offers/{s}?as={s}", .{ ref.spelled(), @tagName(layout) }) catch return);
    const board = boardFor(ref, layout) orelse return;
    redraw(board);
    if (board.view) |v| _ = weft.semanticViewFocus(v, null);
}

fn boardFor(ref: Ref, layout: Layout) ?*Board {
    for (boards.items) |*b| if (b.ref == ref and b.layout == layout) return b;
    boards.append(weft.allocator, .{ .ref = ref, .layout = layout, .arena = .init(weft.allocator) }) catch return null;
    return &boards.items[boards.items.len - 1];
}

fn onContextChanged() callconv(.c) void {
    if (!weft.contextChanged().any(&.{ "offers", "mode" })) return;
    // Only the primary context has an event; a board of another context is
    // what it was when presented.
    for (boards.items) |*b| if (b.view != null and b.ref == .primary) redraw(b);
}

fn redraw(board: *Board) void {
    _ = board.arena.reset(.retain_capacity);
    const a = board.arena.allocator();
    board.items = offers.collect(a, .{ .where = board.ref.where(), .pinned = weft.configList("pinned") }) catch return;
    publishBoard(board) catch return;
}

fn publishBoard(board: *Board) !void {
    const a = board.arena.allocator();
    var nodes: std.ArrayList(Node) = .empty;
    for (board.items, 0..) |item, i| {
        // A separator says what it is; the chrome style decides how it looks
        // (the label is only its text fallback).
        if (offers.separatorBefore(board.items, i))
            try nodes.append(a, .{ .id = @enumFromInt(sep_base + i), .role = "separator", .facts = &.{.{ .name = "tone", .value = "muted" }}, .content = .{ .label = if (board.layout == .strip) "│" else "──" } });
        var facts: std.ArrayList(Fact) = .empty;
        try facts.append(a, .{ .name = "name", .value = item.name });
        // What the offer's command presents itself with (doc/chrome.md §1.2):
        // the styles that draw icons put it beside the label.
        if (item.icon.len > 0) try facts.append(a, .{ .name = "icon", .value = item.icon });
        if (item.provider.len > 0) try facts.append(a, .{ .name = "provider", .value = item.provider });
        if (!item.enabled()) {
            // Greyed by the presenter's `muted` tone; still clickable, so the
            // click can say why.
            try facts.append(a, .{ .name = "reason", .value = item.reason });
            try facts.append(a, .{ .name = "tone", .value = "muted" });
        }
        try nodes.append(a, .{
            .id = @enumFromInt(item_base + i),
            .role = "offers.button",
            .facts = try facts.toOwnedSlice(a),
            .focusable = board.layout == .list,
            .content = .{ .action = .{ .action = act_press, .label = item.label } },
        });
    }
    const root: Node = .{
        .id = @enumFromInt(root_id),
        .role = "offers",
        .content = .{ .container = .{ .axis = if (board.layout == .strip) .horizontal else .vertical, .children = try nodes.toOwnedSlice(a) } },
    };
    board.revision += 1;
    if (board.view) |ref| {
        if (weft.semanticViewReplace(ref, board.revision, root)) |_| return else |_| board.view = null;
    }
    board.view = try weft.semanticViewPublish(root, null, board.revision);
}

/// `offers-press <board> <item>`: a click on a button. Runs in the context
/// the board describes, and leaves the head where it was.
fn press() void {
    const raw = weft.argStr(0) orelse return;
    var parts = std.mem.tokenizeScalar(u8, raw, ' ');
    const which = std.fmt.parseInt(usize, parts.next() orelse return, 10) catch return;
    const index = std.fmt.parseInt(usize, parts.next() orelse return, 10) catch return;
    if (which >= boards.items.len) return;
    const board = &boards.items[which];
    if (index >= board.items.len) return;
    offers.run(board.items[index], board.ref.where());
}

// ── The menu ────────────────────────────────────────────────────────
//
// The menu widget's (doc/chrome.md §2): `weft_menu` keeps the cascade, draws
// the scene the widget reads and binds the keys, so the context menu is the
// menubar's drop-down with different rows.

fn menuAtPointer() void {
    openMenu(.at_pointer, false);
}

fn menuAtCaret() void {
    openMenu(.active, true);
}

fn menuHide(buf: [][]const u8) []const []const u8 {
    var n: usize = 0;
    if (weft.configList("hide")) |list| {
        var it = list;
        while (it.next()) |prefix| {
            if (n >= buf.len) break;
            buf[n] = weft.allocator.dupe(u8, prefix) catch continue;
            n += 1;
        }
        return buf[0..n];
    }
    return &default_hide;
}

/// Open the menu of what `ref` offers — lit on its first row when the
/// keyboard opened it (S-F10), on nothing when a click did.
fn openMenu(ref: Ref, keyboard: bool) void {
    closeMenu();
    // Make the context under the pointer the active one first: the pane
    // there takes focus, and the row or the caret moves to the point.
    if (ref == .at_pointer) weft.run("pointer.focus-point");
    menu = .{ .ref = ref, .arena = .init(weft.allocator) };
    const m = &menu.?;
    const a = m.arena.allocator();
    var hide_buf: [32][]const u8 = undefined;
    const hide = menuHide(&hide_buf);
    defer if (hide.ptr != &default_hide) for (hide) |h| weft.allocator.free(h);
    m.items = offers.collect(a, .{
        .where = ref.where(),
        .pinned = weft.configList("menu-pinned") orelse default_menu_pinned,
        .grammar_words = true,
        .hide = hide,
        .disabled = .omit,
        .pinned_disabled = .keep,
    }) catch return closeMenu();
    if (m.items.len == 0) {
        closeMenu();
        weft.echo("nothing to offer here");
        return;
    }
    const rules = a.alloc(bool, m.items.len) catch return closeMenu();
    placeRules(m.items, rules);
    const entries = a.alloc(menu_lib.Entry, m.items.len) catch return closeMenu();
    for (m.items, rules, entries, 0..) |item, rule, *entry, i| entry.* = .{
        .label = item.label,
        .name = item.name,
        .icon = item.icon,
        // The key that runs it in the context it describes — the one this
        // menu opened over.
        .keys = a.dupe(u8, weft.firstKey(weft.keysFor(item.name))) catch "",
        .rule = rule,
        // A pinned word that cannot run here stays, greyed, saying why.
        .reason = item.reason,
        .tag = @intCast(i),
    };
    m.cascade = .open(entries, keyboard);
    publishMenu(m) catch return closeMenu();
    var scratch = std.heap.ArenaAllocator.init(weft.allocator);
    defer scratch.deinit();
    const definition = menu_lib.definition(scratch.allocator(), m.view.?, menu_lib.cascade.panelId(menu_base, 0), if (ref == .at_pointer) "pointer" else "caret", false, &.{
        .{ .input = "mouse-3", .name = "reopen" },
        .{ .input = "S-F10", .name = "close" },
        .{ .input = "Menu", .name = "close" },
    }) catch return closeMenu();
    m.interaction = weft.semanticInteractionOpen(definition) catch null;
    if (menu != null and menu.?.interaction == null) closeMenu();
}

/// The pinned words are ruled off from the rest. Otherwise a rule opens a
/// group of two or more, and only once what is above it since
/// the last rule is two or more as well; a lone item joins its neighbours,
/// so a menu of mostly single words is not a ladder of rules.
fn placeRules(list: []const offers.Item, rules: []bool) void {
    var section: usize = 0;
    var start: usize = 0;
    while (start < list.len) {
        var end = start + 1;
        while (end < list.len and std.mem.eql(u8, list[end].group, list[start].group)) end += 1;
        const size = end - start;
        for (rules[start..end]) |*r| r.* = false;
        // The pinned words are a block of their own, always ruled off.
        const after_pinned = start > 0 and list[start - 1].pinned and !list[start].pinned;
        rules[start] = start > 0 and ((size >= 2 and section >= 2) or after_pinned);
        section = if (rules[start]) size else section + size;
        start = end;
    }
}

/// Publish (or replace) the menu's view: the cascade as the menu widget's
/// scene.
fn publishMenu(m: *Menu) !void {
    var scratch = std.heap.ArenaAllocator.init(weft.allocator);
    defer scratch.deinit();
    const root = try menu_lib.scene(scratch.allocator(), &m.cascade, menu_base, null);
    m.revision += 1;
    if (m.view) |ref| {
        if (weft.semanticViewReplace(ref, m.revision, root)) |_| return else |_| m.view = null;
    }
    m.view = try weft.semanticViewPublish(root, null, m.revision);
}

fn closeMenu() void {
    var m = menu orelse return;
    menu = null;
    if (m.interaction) |ref| _ = weft.semanticInteractionClose(ref);
    if (m.view) |ref| _ = weft.semanticViewClose(ref);
    m.arena.deinit();
}

/// Close, then run the chosen offer where the menu was opened — the active
/// context, which opening made the one under the pointer.
fn choose(i: usize) void {
    const m = &(menu orelse return);
    if (i >= m.items.len) return closeMenu();
    // Copied out: closing frees the arena the item lives in.
    var name_buf: [256]u8 = undefined;
    var label_buf: [256]u8 = undefined;
    const item = m.items[i];
    const chosen: offers.Item = .{
        .kind = item.kind,
        .name = std.fmt.bufPrint(&name_buf, "{s}", .{item.name}) catch return closeMenu(),
        .label = std.fmt.bufPrint(&label_buf, "{s}", .{item.label}) catch return closeMenu(),
    };
    const where = m.ref.where();
    closeMenu();
    offers.run(chosen, where);
}

/// `offers.menu-key <verb>`: what the open menu's interaction heard.
fn menuKey() void {
    const verb = menu_lib.Verb.parse(weft.argStr(0) orelse return) orelse return;
    const m = &(menu orelse return);
    if (m.interaction == null) return;
    const outcome: menu_lib.Outcome = switch (verb) {
        // Over one of the menu's rows: that row. Anywhere else a click
        // closes it, and does nothing more.
        .click => if (menu_lib.pointedRow(menu_base)) |at| menu_lib.cascade.click(&m.cascade, at.panel, at.row) else .close,
        .hover => if (menu_lib.pointedRow(menu_base)) |at| menu_lib.cascade.hover(&m.cascade, at.panel, at.row) else .none,
        .other => |name| if (std.mem.eql(u8, name, "reopen")) {
            openMenu(.at_pointer, false);
            return;
        } else .close,
        else => menu_lib.key(&m.cascade, verb),
    };
    switch (outcome) {
        .none, .bar => {},
        .redraw => publishMenu(m) catch {},
        .activate => |entry| choose(entry.tag),
        .close, .close_panel => closeMenu(),
    }
}

// ── Semantic callbacks ──────────────────────────────────────────────

/// Semantic callbacks are not dispatching entries, so each runs as this
/// plugin's own command, which is.
fn onSemanticAction() callconv(.c) void {
    var request = weft.semanticActionCurrent(weft.allocator) catch return;
    defer request.deinit();
    const action = request.value.action;
    if (std.mem.eql(u8, action, act_press)) {
        for (boards.items, 0..) |b, which| {
            const v = b.view orelse continue;
            if (!v.eql(request.value.view)) continue;
            const raw = @intFromEnum(request.value.subject);
            if (raw < item_base or raw >= item_base + b.items.len) break;
            _ = weft.semanticActionHandled();
            var buf: [48]u8 = undefined;
            weft.runStr("offers.press", std.fmt.bufPrint(&buf, "{d} {d}", .{ which, raw - item_base }) catch return);
            return;
        }
        _ = weft.semanticActionDecline();
        return;
    }
    const verb = menu_lib.Verb.of(action) orelse {
        _ = weft.semanticActionDecline();
        return;
    };
    _ = weft.semanticActionHandled();
    if (verb == .swallow) return;
    var buf: [48]u8 = undefined;
    weft.runStr("offers.menu-key", verb.spell(&buf));
}
