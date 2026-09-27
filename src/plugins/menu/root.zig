//! menu — the provider for designations of kind `menu` (doc/chrome.md §2):
//! the main menu, as a projection.
//!
//!   weft://here/menu/main   every command a person runs that says where it
//!                           lives (`menu` in its presentation, doc/chrome.md
//!                           §1.2), plus the items a config declares
//!
//! presented `as` one of
//!
//!   menubar   a row of titles — File, Edit, … — in a viewport
//!             (config/menubar.js); a click or Alt with a title's letter
//!             drops its menu down beneath it, F10 lights the first;
//!   menu      the same menus as one menu at the caret, each title a
//!             submenu — what F10 opens where no menubar is shown.
//!
//! THE MODEL is read when a menu opens, never kept: which commands exist,
//! what they are called, whether they could run and which key runs them are
//! all questions about NOW, asked of the PRIMARY context (`commandAt`) — the
//! editor, even while a sidebar holds the keys — because that is where a
//! chosen item runs (`invokeIntentionIn(.primary, …)`). A command with an
//! argument still to give is asked for it (`weft_invoke`), as the palette asks.
//!
//! What goes where is the commands' own say: a `menu` path (`View/Appearance`)
//! places a row, its `group` puts rules between groups and its `order` places
//! it within one. The top level is conventional — File, Edit, Selection, View,
//! Go, Run, Terminal, Help — and a plugin files INTO it; a path under any
//! other title is left out unless a config names that title
//! (`weft.set("menu", "menus", [...])`). Config places whatever else it likes:
//! `weft.command(id, {menu, group, order, …})` files a command anywhere, and
//! `weft.set("menu", "items", [...])` adds rows that run a command WITH an
//! argument — `Path\tLabel\tcommand arg\t[toggle]\t[group]\t[order]` — such
//! as the toggles for the viewports that config composes.
//!
//! A row's check mark is its `toggle` context key: truthy for a toggle, or
//! `key=value` for one choice among several (a dot while the key holds that
//! value). How a menu looks and behaves is the menu widget's (`weft_menu`,
//! `gfx/view/menu.zig`), shared with the context menu.

const std = @import("std");
const weft = @import("weft");
const menu_lib = @import("weft_menu");
const invoke = @import("weft_invoke");
const durable = weft.semantic.durable;
const Node = weft.semantic.scene.Node;
const Fact = weft.semantic.scene.Fact;
const Entry = menu_lib.Entry;
const cascade = menu_lib.cascade;

const kind = "menu";
const bar_root: u64 = 1;
/// The menubar's titles, far from any other view's ids: a pointer on one is
/// told from a sidebar row by its id alone (`titleUnderPointer`).
const bar_base: u64 = 1 << 45;
/// The drop-down's rows (`weft_menu`'s ids).
const drop_base: u64 = 1 << 46;
const act_title = "menu.title";

/// The conventional top level, in order (doc/chrome.md §2.1).
const default_menus = [_][]const u8{ "File", "Edit", "Selection", "View", "Go", "Run", "Terminal", "Help" };

/// Where each menu's groups fall, first to last; a group not named sorts
/// after these, by name. `submenus` is where a menu's submenus sit. A config
/// replaces any menu's line: `weft.set("menu", "groups", ["File\tnew open …"])`.
const default_groups = [_][2][]const u8{
    .{ "File", "new open save close project submenus preferences exit" },
    .{ "Edit", "history clipboard find search refactor format comment submenus" },
    .{ "Selection", "select expand cursors syntax" },
    .{ "View", "palette panels submenus" },
    .{ "View/Appearance", "viewports submenus chrome zoom" },
    .{ "View/Appearance/Chrome Style", "style" },
    .{ "Go", "history editors buffers line goto symbols symbol problems submenus" },
    .{ "Run", "run make debug step breakpoints submenus" },
    .{ "Terminal", "new run terminal direnv" },
    .{ "Help", "welcome keys permissions" },
};

/// Missing arguments are asked for in the entry's own resting mode, as the
/// palette asks them.
const asker = invoke.Invoker(.{ .name = "menu.arg" });

/// `menu.open-file`, `menu.open-edit`, …: one command per conventional menu,
/// what a config binds Alt with its letter to (`M-f`) — a key names a
/// command, not a call, and a person can run "File Menu" from the palette
/// too. A menu a config adds opens from the bar itself (F10, then its letter).
const open_cmds: [default_menus.len]weft.CommandEntry = blk: {
    var arr: [default_menus.len]weft.CommandEntry = undefined;
    for (default_menus, 0..) |title_label, i| {
        const Opener = struct {
            fn call() void {
                openByTitle(default_menus[i]);
            }
        };
        var lower: [title_label.len]u8 = undefined;
        for (title_label, 0..) |ch, k| lower[k] = std.ascii.toLower(ch);
        const spelled = lower;
        arr[i] = .{
            .name = "menu.open-" ++ spelled,
            .call = Opener.call,
            .arity = .whole,
            .summary = "Open the " ++ title_label ++ " menu, its first row lit for the keyboard.",
            .label = title_label ++ " Menu",
            .icon = "list",
        };
    }
    break :blk arr;
};

const own_cmds = [_]weft.CommandEntry{
    .{ .name = "menu.present", .arity = .whole, .call = present, .params = "designation", .summary = "Present a menu designation (weft://here/menu/main?as=menubar|menu).", .internal = true },
    .{ .name = "menu.focus-bar", .arity = .whole, .call = focusBar, .summary = "Put the keyboard on the menubar, its first menu lit; with no menubar shown, open the main menu at the caret.", .label = "Focus Menu Bar", .icon = "list" },
    .{ .name = "menu.title", .arity = .whole, .call = titleClicked, .params = "title", .summary = "Open (or close) the menubar menu a click landed on.", .internal = true },
    .{ .name = "menu.key", .arity = .whole, .call = menuKey, .params = "input", .summary = "Move through, choose from or close the open menu.", .internal = true },
};

const arg_cmds: [asker.commands.len]weft.CommandEntry = blk: {
    var arr: [asker.commands.len]weft.CommandEntry = undefined;
    for (asker.commands, 0..) |c, i| arr[i] = .{ .name = c.name, .call = c.handler, .arity = .whole, .summary = c.summary, .internal = true };
    break :blk arr;
};

const cmds = own_cmds ++ open_cmds ++ arg_cmds;

comptime {
    weft.plugin(&cmds, .{ .init = init }).exportAll();
    weft.exportCallback("on_semantic_action", &onSemanticAction);
}

fn init() void {
    asker.install();
    _ = weft.semanticActionProvider();
    _ = weft.designationOpener(kind, "menu.present");
}

// ── The model ───────────────────────────────────────────────────────

/// What a row runs: a command by name, with its arguments when a config item
/// gave some (`viewport.toggle toolbar`).
const Run = struct {
    invocation: []const u8,
    /// The registry index, for its arity; null for a config item.
    index: ?usize,
};

/// A menu of the bar: its rows, read the first time it opens — how each
/// stands (enabled, its key, its check) is a question per row, so only the
/// menu a person opens pays for it.
const Title = struct { label: []const u8, entries: ?[]const Entry = null };

const Model = struct {
    arena: std.heap.ArenaAllocator,
    titles: []Title = &.{},
    rows: []const Pending = &.{},
    runs: std.ArrayList(Run) = .empty,
};

var model: ?Model = null;

/// One row before it is placed: where it goes, how it sorts, and the
/// context key its check reads.
const Pending = struct {
    path: []const u8,
    entry: Entry,
    group: []const u8,
    order: ?i32,
    toggle: []const u8 = "",
};

/// Title `i`'s rows, read now if this is the first time it opens.
fn entriesOf(i: usize) []const Entry {
    const m = &(model orelse return &.{});
    if (i >= m.titles.len) return &.{};
    if (m.titles[i].entries) |e| return e;
    const built = build(m.arena.allocator(), m.rows, m.titles[i].label) catch &.{};
    m.titles[i].entries = built;
    return built;
}

fn dropModel() void {
    if (model) |*m| m.arena.deinit();
    model = null;
}

/// Read the whole menu model now.
fn readModel() void {
    dropModel();
    model = .{ .arena = .init(weft.allocator) };
    const m = &model.?;
    buildModel(m) catch {
        dropModel();
        weft.echo("menu: could not read the commands");
    };
}

fn buildModel(m: *Model) !void {
    const a = m.arena.allocator();
    // The titles, in order.
    var titles: std.ArrayList([]const u8) = .empty;
    if (weft.configList("menus")) |list| {
        var it = list;
        while (it.next()) |t| try titles.append(a, try a.dupe(u8, t));
    }
    if (titles.items.len == 0) for (default_menus) |t| try titles.append(a, t);

    var rows: std.ArrayList(Pending) = .empty;
    const n = weft.commandCount();
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const name = try a.dupe(u8, weft.commandName(i) orelse continue);
        const meta = weft.commandMeta(name) orelse continue;
        if (meta.internal or meta.menu.len == 0) continue;
        if (!hasTitle(titles.items, topOf(meta.menu))) continue;
        var shown_buf: [256]u8 = undefined;
        const label = try a.dupe(u8, meta.shown(&shown_buf, name));
        const path = try a.dupe(u8, meta.menu);
        const group = try a.dupe(u8, meta.group);
        const icon = try a.dupe(u8, meta.icon);
        const toggle = try a.dupe(u8, meta.toggle);
        try m.runs.append(a, .{ .invocation = name, .index = i });
        try rows.append(a, .{ .path = path, .group = group, .order = meta.order, .toggle = toggle, .entry = .{ .label = label, .name = name, .icon = icon, .tag = @intCast(m.runs.items.len - 1) } });
    }
    // Config's own rows.
    if (weft.configList("items")) |list| {
        var it = list;
        while (it.next()) |raw| {
            const rec = try a.dupe(u8, raw);
            var parts = std.mem.splitScalar(u8, rec, '\t');
            const path = parts.next() orelse continue;
            const label = parts.next() orelse continue;
            const invocation = parts.next() orelse continue;
            const toggle = parts.next() orelse "";
            const group = parts.next() orelse "";
            const order = if (parts.next()) |o| std.fmt.parseInt(i32, o, 10) catch null else null;
            if (path.len == 0 or invocation.len == 0 or !hasTitle(titles.items, topOf(path))) continue;
            try m.runs.append(a, .{ .invocation = invocation, .index = null });
            const name = invocation[0 .. std.mem.indexOfScalar(u8, invocation, ' ') orelse invocation.len];
            try rows.append(a, .{ .path = path, .group = group, .order = order, .toggle = toggle, .entry = .{ .label = label, .name = name, .tag = @intCast(m.runs.items.len - 1) } });
        }
    }

    const out = try a.alloc(Title, titles.items.len);
    for (titles.items, out) |title, *t| t.* = .{ .label = title };
    m.titles = out;
    m.rows = try rows.toOwnedSlice(a);
}

/// A leaf row as it stands in the primary context now: whether it can run
/// there, its key there, and its check.
fn stand(a: std.mem.Allocator, p: Pending) !Entry {
    var entry = p.entry;
    const name = entry.name;
    const toggle = p.toggle;
    if (weft.commandAt(.primary, name)) |s| {
        entry.reason = try a.dupe(u8, s.reason);
        entry.keys = try a.dupe(u8, s.firstKey());
    }
    if (toggle.len > 0) {
        if (std.mem.indexOfScalar(u8, toggle, '=')) |eq| {
            entry.radio = true;
            const value = weft.contextGet(toggle[0..eq]) orelse "";
            entry.checked = std.mem.eql(u8, value, toggle[eq + 1 ..]);
        } else {
            const value = weft.contextGet(toggle) orelse "";
            entry.checked = value.len > 0 and !std.mem.eql(u8, value, "off") and !std.mem.eql(u8, value, "false") and !std.mem.eql(u8, value, "0");
        }
    }
    return entry;
}

fn topOf(path: []const u8) []const u8 {
    return path[0 .. std.mem.indexOfScalar(u8, path, '/') orelse path.len];
}

fn hasTitle(titles: []const []const u8, title: []const u8) bool {
    for (titles) |t| if (std.mem.eql(u8, t, title)) return true;
    return false;
}

/// The rows of the menu at `path`: its own, and one submenu per next
/// segment below it, sorted by group, then order, then label, with a rule
/// wherever the group changes.
fn build(a: std.mem.Allocator, rows: []const Pending, path: []const u8) ![]const Entry {
    var here: std.ArrayList(Pending) = .empty;
    var subs: std.ArrayList([]const u8) = .empty;
    for (rows) |r| {
        if (std.mem.eql(u8, r.path, path)) {
            var stood = r;
            stood.entry = try stand(a, r);
            try here.append(a, stood);
            continue;
        }
        if (r.path.len <= path.len + 1 or !std.mem.startsWith(u8, r.path, path) or r.path[path.len] != '/') continue;
        const rest = r.path[path.len + 1 ..];
        const seg = rest[0 .. std.mem.indexOfScalar(u8, rest, '/') orelse rest.len];
        const seen = for (subs.items) |s| {
            if (std.mem.eql(u8, s, seg)) break true;
        } else false;
        if (!seen) try subs.append(a, seg);
    }
    for (subs.items) |seg| {
        const sub_path = try std.fmt.allocPrint(a, "{s}/{s}", .{ path, seg });
        const children = try build(a, rows, sub_path);
        if (children.len == 0) continue;
        try here.append(a, .{ .path = sub_path, .group = "submenus", .order = null, .entry = .{ .label = seg, .children = children } });
    }
    const ranks = groupsOf(path);
    const Ctx = struct {
        ranks: []const u8,
        fn lessThan(ctx: @This(), x: Pending, y: Pending) bool {
            const rx = rank(ctx.ranks, x.group);
            const ry = rank(ctx.ranks, y.group);
            if (rx != ry) return rx < ry;
            if (!std.mem.eql(u8, x.group, y.group)) return std.mem.lessThan(u8, x.group, y.group);
            const ox = x.order orelse std.math.maxInt(i32);
            const oy = y.order orelse std.math.maxInt(i32);
            if (ox != oy) return ox < oy;
            return std.mem.lessThan(u8, x.entry.label, y.entry.label);
        }
    };
    std.mem.sort(Pending, here.items, Ctx{ .ranks = ranks }, Ctx.lessThan);
    // A menu names a verb once: where two commands read the same (the
    // grammar's Copy and core's), the one a key runs here stands for both,
    // else the one that can run, else the first.
    var kept: std.ArrayList(Pending) = .empty;
    for (here.items) |p| {
        const twin = for (kept.items) |*k| {
            if (k.entry.children.len == 0 and p.entry.children.len == 0 and std.mem.eql(u8, k.entry.label, p.entry.label)) break k;
        } else null;
        if (twin) |k| {
            if (better(p.entry, k.entry)) k.* = p;
            continue;
        }
        try kept.append(a, p);
    }
    const out = try a.alloc(Entry, kept.items.len);
    for (kept.items, out, 0..) |p, *e, i| {
        e.* = p.entry;
        e.rule = i > 0 and !std.mem.eql(u8, kept.items[i - 1].group, p.group);
    }
    return out;
}

/// Whether row `x` should stand for a verb over its twin `y`.
fn better(x: Entry, y: Entry) bool {
    if ((x.keys.len > 0) != (y.keys.len > 0)) return x.keys.len > 0;
    return x.enabled() and !y.enabled();
}

/// The group line for the menu at `path`: config's, else the default.
fn groupsOf(path: []const u8) []const u8 {
    if (weft.configList("groups")) |list| {
        var it = list;
        while (it.next()) |rec| {
            const tab = std.mem.indexOfScalar(u8, rec, '\t') orelse continue;
            if (std.mem.eql(u8, rec[0..tab], path)) return rec[tab + 1 ..];
        }
    }
    for (default_groups) |g| if (std.mem.eql(u8, g[0], path)) return g[1];
    return "";
}

fn rank(line: []const u8, group: []const u8) usize {
    var words = std.mem.tokenizeScalar(u8, line, ' ');
    var i: usize = 0;
    while (words.next()) |w| : (i += 1) if (std.mem.eql(u8, w, group)) return i;
    return 1000;
}

// ── The menubar ─────────────────────────────────────────────────────

/// The menubar's entry and view, while one is presented.
var bar_view: ?weft.semantic.view.Ref = null;
var bar_revision: u32 = 0;
/// Titles as the bar last showed them — what a click on one names.
var bar_titles: std.ArrayList([]u8) = .empty;

/// The open menu, if any: which title is lit (null in a menu at the caret)
/// and the cascade under it (depth 0: only the title is lit).
const Open = struct {
    bar: ?usize = null,
    cascade: menu_lib.Cascade = .{},
    view: ?weft.semantic.view.Ref = null,
    interaction: ?weft.semantic.interaction.Ref = null,
    revision: u32 = 0,
};
var open: ?Open = null;

fn present() void {
    const text = weft.argStr(0) orelse return;
    const d = durable.parse(text) orelse return weft.echo("menu: not a designation");
    if (!std.mem.eql(u8, d.ref, "main")) return weft.echo("menu: only weft://here/menu/main");
    const as = d.param("as") orelse "menubar";
    if (std.mem.eql(u8, as, "menubar")) return presentBar();
    if (std.mem.eql(u8, as, "menu")) return openAtCaret(null);
    weft.echo("menu: as menubar or menu");
}

/// Make the menubar's entry active and drawn: what the viewport presenting it
/// then shows.
fn presentBar() void {
    weft.focusOrCreateBuffer("*menu main menubar*");
    weft.toolBacking(kind);
    _ = weft.designate("weft://here/menu/main?as=menubar");
    publishBar() catch return;
    if (bar_view) |v| _ = weft.semanticViewFocus(v, null);
}

fn titleLabels(a: std.mem.Allocator) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    if (weft.configList("menus")) |list| {
        var it = list;
        while (it.next()) |t| try out.append(a, try a.dupe(u8, t));
    }
    if (out.items.len == 0) for (default_menus) |t| try out.append(a, t);
    return out.toOwnedSlice(a);
}

fn publishBar() !void {
    var scratch = std.heap.ArenaAllocator.init(weft.allocator);
    defer scratch.deinit();
    const a = scratch.allocator();
    const titles = try titleLabels(a);
    for (bar_titles.items) |t| weft.allocator.free(t);
    bar_titles.clearRetainingCapacity();
    const as_entries = try a.alloc(Entry, titles.len);
    for (titles, as_entries) |t, *e| {
        e.* = .{ .label = t };
        try bar_titles.append(weft.allocator, try weft.allocator.dupe(u8, t));
    }
    var marks_buf: [32]?usize = undefined;
    const marks = cascade.mnemonics(as_entries, &marks_buf);
    const lit: ?usize = if (open) |o| o.bar else null;
    const keyboard = if (open) |o| o.cascade.keyboard else false;
    var nodes: std.ArrayList(Node) = .empty;
    for (titles, 0..) |t, i| {
        var facts: std.ArrayList(Fact) = .empty;
        if (lit == i) try facts.append(a, .{ .name = "lit", .value = "on" });
        // Underlined while the keyboard drives the bar, as the desktop does.
        if (keyboard and i < marks.len) if (marks[i]) |at| try facts.append(a, .{ .name = "mnemonic", .value = try std.fmt.allocPrint(a, "{d}", .{at}) });
        var shown_buf: [128]u8 = undefined;
        try nodes.append(a, .{
            .id = @enumFromInt(bar_base + i),
            .role = "menubar-item",
            .facts = try facts.toOwnedSlice(a),
            .content = .{ .action = .{ .action = act_title, .label = try a.dupe(u8, cascade.shown(t, &shown_buf).text) } },
        });
    }
    const root: Node = .{
        .id = @enumFromInt(bar_root),
        .role = "menubar",
        .content = .{ .container = .{ .axis = .horizontal, .children = try nodes.toOwnedSlice(a) } },
    };
    bar_revision += 1;
    if (bar_view) |ref| {
        if (weft.semanticViewReplace(ref, bar_revision, root)) |_| return else |_| bar_view = null;
    }
    bar_view = try weft.semanticViewPublish(root, null, bar_revision);
}

/// Whether the menubar is on screen: its viewport shown and its view drawn.
fn barShown() bool {
    if (bar_view == null) return false;
    var key_buf: [96]u8 = undefined;
    const name = weft.config("viewport");
    const key = std.fmt.bufPrint(&key_buf, "viewport.{s}.shown", .{if (name.len > 0) name else "menubar"}) catch return false;
    const shown = weft.contextGet(key) orelse return false;
    return shown.len > 0;
}

/// The title a letter is the mnemonic of.
fn titleByLetter(ch: u8) ?usize {
    const m = model orelse return null;
    var as_entries: [32]Entry = undefined;
    const n = @min(m.titles.len, as_entries.len);
    for (m.titles[0..n], 0..) |t, i| as_entries[i] = .{ .label = t.label };
    var marks_buf: [32]?usize = undefined;
    const marks = cascade.mnemonics(as_entries[0..n], &marks_buf);
    for (as_entries[0..n], marks, 0..) |e, mark, i| {
        const at = mark orelse continue;
        var buf: [128]u8 = undefined;
        const shown = cascade.shown(e.label, &buf).text;
        if (at < shown.len and std.ascii.toLower(shown[at]) == std.ascii.toLower(ch)) return i;
    }
    return null;
}

// ── Opening and closing ─────────────────────────────────────────────

/// F10: the keyboard onto the menubar, its first title lit — or, with no
/// menubar on screen, the main menu at the caret. Again closes it.
fn focusBar() void {
    if (open != null) return closeAll();
    readModel();
    if (model == null) return;
    if (!barShown()) return openAtCaret(null);
    open = .{ .bar = 0, .cascade = .{ .keyboard = true } };
    startInteraction();
}

/// Alt with a title's letter: that menu, dropped down and lit from the keys
/// (at the caret when no menubar is shown).
fn openByTitle(label: []const u8) void {
    closeAll();
    readModel();
    const m = model orelse return;
    const i = for (m.titles, 0..) |t, i| {
        if (std.mem.eql(u8, t.label, label)) break i;
    } else return weft.echo("menu: no such menu here");
    if (!barShown()) return openAtCaret(i);
    openTitle(i, true);
}

/// A click on a title while no menu is open.
fn titleClicked() void {
    const raw = weft.argStr(0) orelse return;
    const i = std.fmt.parseInt(usize, raw, 10) catch return;
    readModel();
    openTitle(i, false);
}

/// Drop title `i`'s menu down beneath it — opening the menu interaction if
/// none is open yet, or switching to it from another title's.
fn openTitle(i: usize, keyboard: bool) void {
    const m = model orelse return;
    if (i >= m.titles.len) return;
    const was_open = open != null;
    if (!was_open) open = .{};
    const o = &open.?;
    o.bar = i;
    o.cascade = .open(entriesOf(i), keyboard);
    if (!was_open) return startInteraction();
    publishDrop() catch return closeAll();
    publishBar() catch {};
}

/// The main menu at the caret, its titles the root panel — with title
/// `sub`'s submenu open when a letter asked for one.
fn openAtCaret(sub: ?usize) void {
    const m = model orelse return;
    closeInteraction();
    const a = model.?.arena.allocator();
    const roots = a.alloc(Entry, m.titles.len) catch return;
    for (m.titles, roots, 0..) |t, *e, i| e.* = .{ .label = t.label, .children = entriesOf(i) };
    open = .{ .cascade = .open(roots, true) };
    const o = &open.?;
    if (sub) |i| {
        o.cascade.lit[0] = i;
        _ = cascade.right(&o.cascade);
    }
    startInteraction();
}

fn startInteraction() void {
    const o = &(open orelse return);
    publishDrop() catch return closeAll();
    var scratch = std.heap.ArenaAllocator.init(weft.allocator);
    defer scratch.deinit();
    const definition = menu_lib.definition(scratch.allocator(), o.view.?, cascade.panelId(drop_base, 0), if (o.bar != null) "menu" else "caret", o.bar != null, &.{
        .{ .input = "F10", .name = "close" },
        .{ .input = "mouse-3", .name = "close" },
    }) catch return closeAll();
    o.interaction = weft.semanticInteractionOpen(definition) catch null;
    if (open != null and open.?.interaction == null) return closeAll();
    publishBar() catch {};
}

/// Publish the open menu's view: the cascade hung beneath its lit title, or
/// nothing but the anchor while only the title is lit.
fn publishDrop() !void {
    const o = &(open orelse return);
    var scratch = std.heap.ArenaAllocator.init(weft.allocator);
    defer scratch.deinit();
    const a = scratch.allocator();
    const anchor: ?menu_lib.AnchorNode = if (o.bar) |i| (if (bar_view) |v| .{ .view = v, .node = bar_base + i } else null) else null;
    // Only a title lit: an empty panel, which the widget does not draw.
    const nothing: menu_lib.Cascade = .{};
    const root = try menu_lib.scene(a, if (o.cascade.depth == 0) &nothing else &o.cascade, drop_base, anchor);
    o.revision += 1;
    if (o.view) |ref| {
        if (weft.semanticViewReplace(ref, o.revision, root)) |_| return else |_| o.view = null;
    }
    o.view = try weft.semanticViewPublish(root, null, o.revision);
}

fn closeInteraction() void {
    const o = open orelse return;
    open = null;
    if (o.interaction) |ref| _ = weft.semanticInteractionClose(ref);
    if (o.view) |ref| _ = weft.semanticViewClose(ref);
}

fn closeAll() void {
    closeInteraction();
    if (bar_view != null) publishBar() catch {};
}

/// Close the menu, then run what the row stands for in the primary context:
/// an intention or a command there, asking first for any argument it still
/// needs.
fn activate(entry: *const Entry) void {
    const m = model orelse return closeAll();
    if (entry.tag >= m.runs.items.len) return closeAll();
    const run = m.runs.items[entry.tag];
    var buf: [256]u8 = undefined;
    const invocation = std.fmt.bufPrint(&buf, "{s}", .{run.invocation}) catch return closeAll();
    const needs_args = if (run.index) |i| (weft.commandArityRequired(i) orelse 0) > 0 else std.mem.indexOfScalar(u8, invocation, ' ') != null;
    closeAll();
    if (needs_args) return asker.invokeLine(invocation);
    switch (weft.invokeIntentionIn(.primary, invocation)) {
        .invoked => {},
        .refused => |why| weft.echo(why),
        .unknown => asker.invokeLine(invocation),
    }
}

// ── Keys and the pointer ────────────────────────────────────────────

/// The menubar title under the pointer, if it is on one. Titles are in the
/// menubar's own pane, which never has the keys.
fn titleUnderPointer() ?usize {
    const p = weft.pointer() orelse return null;
    const node = p.node orelse return null;
    if (p.focused or node < bar_base or node >= bar_base + bar_titles.items.len) return null;
    return @intCast(node - bar_base);
}

/// `menu.key <verb>`: what the open menu's interaction heard.
fn menuKey() void {
    const verb = menu_lib.Verb.parse(weft.argStr(0) orelse return) orelse return;
    const o = &(open orelse return);
    if (o.interaction == null) return;
    const n_titles = if (model) |m| m.titles.len else 0;
    // Only a title lit: the bar's own keys.
    if (o.cascade.depth == 0) if (o.bar) |bar| {
        switch (verb) {
            .left, .right => {
                o.bar = if (verb == .right) (bar + 1) % n_titles else (bar + n_titles - 1) % n_titles;
                publishBar() catch {};
                publishDrop() catch {};
            },
            .down, .up, .choose => openTitle(bar, true),
            .close => closeAll(),
            .letter, .alt => |ch| if (titleByLetter(ch)) |i| openTitle(i, true),
            .click => if (titleUnderPointer()) |i| openTitle(i, false) else closeAll(),
            .other => closeAll(),
            else => {},
        }
        return;
    };
    const outcome: menu_lib.Outcome = switch (verb) {
        .click => if (menu_lib.pointedRow(drop_base)) |at|
            cascade.click(&o.cascade, at.panel, at.row)
        else if (titleUnderPointer()) |i| {
            if (o.bar == i) return closeAll();
            return openTitle(i, false);
        } else .close,
        .hover => if (menu_lib.pointedRow(drop_base)) |at|
            cascade.hover(&o.cascade, at.panel, at.row)
        else if (titleUnderPointer()) |i| {
            // With a menu down, the pointer moving to another title opens
            // that one instead.
            if (o.bar != null and o.bar != i) openTitle(i, false);
            return;
        } else .none,
        .alt => |ch| {
            if (titleByLetter(ch)) |i| if (o.bar != null) return openTitle(i, true);
            return;
        },
        .other => .close,
        else => menu_lib.key(&o.cascade, verb),
    };
    switch (outcome) {
        .none => {},
        .redraw => publishDrop() catch {},
        .activate => |entry| activate(entry),
        .close => closeAll(),
        .close_panel => if (o.bar != null) {
            // Escape out of the last panel: back to the lit title.
            o.cascade.depth = 0;
            publishDrop() catch {};
        } else closeAll(),
        .bar => |step| if (o.bar) |bar| {
            const next = if (step > 0) (bar + 1) % n_titles else (bar + n_titles - 1) % n_titles;
            openTitle(next, true);
        },
    }
}

/// Semantic callbacks are not dispatching entries, so each runs as this
/// plugin's own command, which is.
fn onSemanticAction() callconv(.c) void {
    var request = weft.semanticActionCurrent(weft.allocator) catch return;
    defer request.deinit();
    const action = request.value.action;
    if (std.mem.eql(u8, action, act_title)) {
        const raw = @intFromEnum(request.value.subject);
        if (raw < bar_base or raw >= bar_base + bar_titles.items.len) {
            _ = weft.semanticActionDecline();
            return;
        }
        _ = weft.semanticActionHandled();
        var buf: [24]u8 = undefined;
        weft.runStr("menu.title", std.fmt.bufPrint(&buf, "{d}", .{raw - bar_base}) catch return);
        return;
    }
    const verb = menu_lib.Verb.of(action) orelse {
        _ = weft.semanticActionDecline();
        return;
    };
    _ = weft.semanticActionHandled();
    if (verb == .swallow) return;
    var buf: [48]u8 = undefined;
    weft.runStr("menu.key", verb.spell(&buf));
}
