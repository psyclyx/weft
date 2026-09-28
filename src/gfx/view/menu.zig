//! The menu widget (doc/chrome.md §2): how every menu LOOKS — the menubar's
//! drop-downs and the context menu alike, through the chrome style.
//!
//! A menu is a scene a provider publishes; this is its presenter. It reads a
//! small vocabulary of roles and facts and nothing else, so a menu's behaviour
//! (what is lit, which submenu is open, what a key does) stays with whoever
//! published it, and its look stays here, one look for every menu:
//!
//!   · a `menu` node is one PANEL — a vertical container whose children are,
//!     in order, `menu-item` action nodes, `separator` label nodes, and at most
//!     one nested `menu`: the open submenu of the item just before it;
//!   · a `menu-item`'s facts: `keys` (its key hint, right-aligned), `icon`,
//!     `reason` (why it cannot run: greyed, and its tooltip says why),
//!     `checked` and `radio` (`on`: a check mark, or a choice's dot),
//!     `submenu` (`on`: a chevron), `mnemonic` (the codepoint index of the
//!     label's underlined letter), `lit` (`on`: the keyboard's place — and a
//!     submenu's parent while it is open), `name` (what it runs, for the
//!     tooltip);
//!   · the root panel hangs below the node its `anchor-view`/`anchor-node`
//!     facts name in another view (a menubar title), else at the overlay's
//!     presentation point (`pointer`, `caret`).
//!
//! Placement is against the FRAME (`bounds`): a panel is clamped inside it, a
//! submenu opens beside its item and flips to the other side when it would
//! overflow, and a panel hung at a point flips above it when it would not fit
//! below. A panel still taller than the frame once packed to the text grid
//! scrolls: a window of its rows, an indicator where rows are hidden, kept
//! across frames (`Scroll`) and moved to show the lit row whenever that row
//! moves, or by the owner's wheel steps (the panel's `scroll` fact; its
//! `opened` fact names each opening). The text styles keep every row and
//! column on the cell grid — a clean outlined box; `widget` pads in pixels,
//! rounds, and casts a shadow.
//!
//! A `menubar-item` is a menubar's title (`chrome.Role.menu_title`), laid out
//! in a scene row like a button; the presenter paints it with this module's
//! mnemonic underline.

const std = @import("std");
const Allocator = std.mem.Allocator;
const semantic = @import("weft_semantic");

const region = @import("../region.zig");
const view = @import("../view.zig");
const chrome = @import("chrome.zig");

const View = view.View;
const Run = view.Run;
const Rect = view.Rect;
const Node = semantic.scene.Node;
const NodeId = semantic.scene.NodeId;

pub const role_menu = "menu";
pub const role_item = "menu-item";
pub const role_title = "menubar-item";

/// One row of a panel as the scene says it.
pub const Item = struct {
    node: NodeId,
    separator: bool = false,
    /// A plain label among the items: a heading, never lit or chosen.
    heading: bool = false,
    label: []const u8 = "",
    icon: ?[]const u8 = null,
    keys: []const u8 = "",
    reason: []const u8 = "",
    name: []const u8 = "",
    checked: bool = false,
    radio: bool = false,
    submenu: bool = false,
    lit: bool = false,
    mnemonic: ?usize = null,
};

/// One panel: its rows, and — for a submenu — the row of its parent panel it
/// opened from.
pub const Panel = struct {
    items: []const Item,
    parent: ?struct { panel: usize, item: usize } = null,
    /// The panel's own node and the stamp of its opening (its `opened`
    /// fact), which together name this opening of it across frames
    /// (`Scroll`): opened again, it starts at its top.
    node: ?NodeId = null,
    opened: u32 = 0,
    /// The wheel steps its owner has heard over it since it opened (its
    /// `scroll` fact; down is positive). Only the change between frames
    /// moves it.
    wheel: i32 = 0,

    /// The lit row, if one is.
    pub fn lit(self: Panel) ?usize {
        for (self.items, 0..) |it, i| if (it.lit) return i;
        return null;
    }
};

/// A role's last dotted segment: `offers.menu` and `menu` alike.
pub fn leaf(role: []const u8) []const u8 {
    return if (std.mem.lastIndexOfScalar(u8, role, '.')) |dot| role[dot + 1 ..] else role;
}

pub fn fact(node: *const Node, name: []const u8) ?[]const u8 {
    for (node.facts) |f| if (std.mem.eql(u8, f.name, name)) return f.value;
    return null;
}

fn on(node: *const Node, name: []const u8) bool {
    const v = fact(node, name) orelse return false;
    return std.mem.eql(u8, v, "on");
}

/// Whether `node` is a menu panel the widget draws.
pub fn isMenu(node: *const Node) bool {
    return std.mem.eql(u8, leaf(node.role), role_menu) and node.content == .container;
}

/// A mnemonic fact's value.
pub fn mnemonicOf(node: *const Node) ?usize {
    const v = fact(node, "mnemonic") orelse return null;
    return std.fmt.parseInt(usize, v, 10) catch null;
}

/// The panels of the menu rooted at `root`, outermost first: each open
/// submenu follows its parent.
pub fn panelsOf(arena: Allocator, root: *const Node) Allocator.Error![]const Panel {
    var out: std.ArrayList(Panel) = .empty;
    try collect(arena, &out, root, null);
    return out.toOwnedSlice(arena);
}

fn collect(arena: Allocator, out: *std.ArrayList(Panel), node: *const Node, parent: @FieldType(Panel, "parent")) Allocator.Error!void {
    if (out.items.len >= max_panels) return;
    const children = switch (node.content) {
        .container => |c| c.children,
        else => return,
    };
    const index = out.items.len;
    const wheel = if (fact(node, "scroll")) |s| std.fmt.parseInt(i32, s, 10) catch 0 else 0;
    const opened = if (fact(node, "opened")) |s| std.fmt.parseInt(u32, s, 10) catch 0 else 0;
    try out.append(arena, .{ .items = &.{}, .parent = parent, .node = node.id, .opened = opened, .wheel = wheel });
    var items: std.ArrayList(Item) = .empty;
    var sub: ?*const Node = null;
    var sub_parent: usize = 0;
    for (children) |*child| {
        if (isMenu(child)) {
            // The open submenu of the item before it; one per panel.
            if (sub == null and items.items.len > 0) {
                sub = child;
                sub_parent = items.items.len - 1;
            }
            continue;
        }
        switch (child.content) {
            .action => |a| try items.append(arena, .{
                .node = child.id,
                .label = a.label,
                .icon = fact(child, "icon"),
                .keys = fact(child, "keys") orelse "",
                .reason = fact(child, "reason") orelse "",
                .name = fact(child, "name") orelse "",
                .checked = on(child, "checked"),
                .radio = on(child, "radio"),
                .submenu = on(child, "submenu"),
                .lit = on(child, "lit"),
                .mnemonic = mnemonicOf(child),
            }),
            .label => |text| if (std.mem.eql(u8, leaf(child.role), "separator")) {
                try items.append(arena, .{ .node = child.id, .separator = true });
            } else try items.append(arena, .{ .node = child.id, .label = text, .heading = true }),
            else => {},
        }
    }
    out.items[index].items = try items.toOwnedSlice(arena);
    if (sub) |s| try collect(arena, out, s, .{ .panel = index, .item = sub_parent });
}

const max_panels = 8;

// ── Geometry ────────────────────────────────────────────────────────

/// The style's measures, in pixels.
pub const Metrics = struct {
    row_h: f32,
    sep_h: f32,
    pad_x: f32,
    pad_y: f32,
    /// A submenu's overlap with its parent (or, flipped, the gap).
    overlap: f32,
    min_w: f32,

    pub fn of(v: *const View) Metrics {
        return switch (v.chrome) {
            // A clean cell box: rows are text rows, a rule is a row, and the
            // box's edges fall on cell boundaries.
            .text, .text_icons => .{ .row_h = v.line_h, .sep_h = v.line_h, .pad_x = 0, .pad_y = 0, .overlap = 0, .min_w = 16 * v.cell_w },
            .widget => .{ .row_h = @round(v.line_h * 1.4), .sep_h = 9, .pad_x = 5, .pad_y = 5, .overlap = 3, .min_w = @max(190, 16 * v.cell_w) },
        };
    }
};

/// Where the columns of a panel's rows fall, as offsets from the row's left.
pub const Columns = struct {
    /// The check / icon column (0 wide when no row needs one).
    lead: f32,
    /// The label's left.
    label: f32,
    /// The key hints' right edge, from the row's right.
    keys_right: f32,
    /// The chevron column's width at the far right (0 when no row opens).
    chevron: f32,
};

pub const RowBox = struct { item: usize, rect: region.Rect };

pub const PanelBox = struct {
    box: region.Rect,
    /// The rows shown: every row, or — in a panel taller than the frame —
    /// the window of them it is scrolled to.
    rows: []const RowBox,
    columns: Columns,
    /// A submenu that opened on its parent's LEFT (it would have overflowed
    /// the frame on the right); a root panel that hangs ABOVE its point.
    flipped: bool = false,
    /// A scrolled panel's indicators: rows are hidden above (`more_up`) or
    /// below (`more_down`); each takes one row's height.
    more_up: ?region.Rect = null,
    more_down: ?region.Rect = null,
};

/// Wheel steps scroll this many rows.
pub const wheel_rows = 3;

/// Where each open panel taller than the frame is scrolled to, across
/// frames — the menu's `top_row`. Kept by the view; a panel is known by its
/// node and its opening, so another submenu at the same depth, or the same
/// menu opened again, starts at its top. Settling is idempotent: a frame
/// built twice from one input lays out the same rows.
pub const Scroll = struct {
    kept: [max_panels]Kept = @splat(.{}),

    pub const Kept = struct {
        /// The panel's node and the stamp of its opening.
        key: ?[2]u64 = null,
        top: usize = 0,
        /// The lit row last laid out: the window follows it only when it moves.
        lit: ?usize = null,
        /// The panel's wheel count last seen.
        wheel: i32 = 0,
    };
};

pub const Anchor = union(enum) {
    /// Hang below this box, left edges aligned (a menubar title).
    below: region.Rect,
    /// Hang at this point, below it — above it when it does not fit.
    point: [2]f32,
};

fn cols(text: []const u8) usize {
    return std.unicode.utf8CountCodepoints(text) catch text.len;
}

fn cellsW(v: *const View, n: usize) f32 {
    return @as(f32, @floatFromInt(n)) * v.cell_w;
}

fn columnsFor(v: *const View, items: []const Item) struct { columns: Columns, width: f32 } {
    var label_w: usize = 0;
    var keys_w: usize = 0;
    var any_mark = false;
    var any_icon = false;
    var any_sub = false;
    for (items) |it| {
        if (it.separator) continue;
        label_w = @max(label_w, cols(it.label));
        keys_w = @max(keys_w, cols(it.keys));
        any_mark = any_mark or it.checked or it.radio;
        any_icon = any_icon or (it.icon != null and v.icon(it.icon.?) != null);
        any_sub = any_sub or it.submenu;
    }
    const widget = v.chrome == .widget;
    // The lead column holds a check, a dot or an icon; labels align whether
    // or not a row has one. Under `text` there are no icons, so it is there
    // only for a menu that can check.
    const has_lead = any_mark or (v.chrome.showsIcons() and any_icon);
    const lead: f32 = if (!has_lead) 0 else if (widget) chrome.iconSide(v) + 12 else 2 * v.cell_w;
    const pad: f32 = if (widget) 10 else v.cell_w;
    const chevron: f32 = if (!any_sub) 0 else if (widget) chrome.iconSide(v) + 6 else 2 * v.cell_w;
    const gap: f32 = if (keys_w == 0) 0 else 3 * v.cell_w;
    const label_x = if (has_lead) lead else pad;
    return .{
        .columns = .{ .lead = lead, .label = label_x, .keys_right = pad + chevron, .chevron = chevron },
        .width = label_x + cellsW(v, label_w) + gap + cellsW(v, keys_w) + chevron + pad,
    };
}

/// Lay out every panel of a menu inside `bounds`: the root at `anchor`, each
/// submenu beside the row it opened from. A panel taller than the frame,
/// once packed, shows a window of its rows with an indicator for what is
/// hidden above and below: scrolled by its owner's wheel steps, and moved —
/// only as far as it must — to show the lit row whenever that row moves, so
/// every row the keys can reach is one a person can see. `scroll` keeps the
/// windows across frames; without it each panel starts at its top.
pub fn layout(v: *const View, arena: Allocator, panels: []const Panel, anchor: Anchor, bounds: region.Rect, scroll: ?*Scroll) Allocator.Error![]const PanelBox {
    const roomy = Metrics.of(v);
    const out = try arena.alloc(PanelBox, panels.len);
    for (panels, 0..) |panel, pi| {
        const measured = columnsFor(v, panel.items);
        // A panel too long for the frame at the style's spacing packs its
        // rows to the text grid (and a text style's rules to a thin line)
        // before any row is cut off.
        var m = roomy;
        if (panelHeight(panel, m) > bounds.h - 2 * v.line_h) {
            m.row_h = v.line_h;
            m.sep_h = @min(m.sep_h, @round(v.line_h * 0.5));
        }
        var h = panelHeight(panel, m);
        const w = @min(bounds.w, snap(v, @max(m.min_w, measured.width + 2 * m.pad_x)));
        h = @min(bounds.h, h);
        var x: f32 = undefined;
        var y: f32 = undefined;
        var flipped = false;
        if (panel.parent) |parent| {
            const pb = out[parent.panel];
            const row = rowRect(pb, parent.item) orelse pb.box;
            x = pb.box.x + pb.box.w - m.overlap;
            if (x + w > bounds.x + bounds.w) {
                x = pb.box.x - w + m.overlap;
                flipped = true;
            }
            y = row.y - m.pad_y;
        } else switch (anchor) {
            .below => |r| {
                x = r.x;
                y = r.y + r.h;
            },
            .point => |p| {
                x = p[0];
                y = p[1];
                if (y + h > bounds.y + bounds.h and p[1] - h - v.line_h >= bounds.y) {
                    y = p[1] - h - v.line_h;
                    flipped = true;
                }
            },
        }
        x = std.math.clamp(x, bounds.x, @max(bounds.x, bounds.x + bounds.w - w));
        y = std.math.clamp(y, bounds.y, @max(bounds.y, bounds.y + bounds.h - h));
        if (v.chrome != .widget) {
            x = @floor((x - bounds.x) / v.cell_w + 0.01) * v.cell_w + bounds.x;
            y = @round(y);
        }
        const avail = h - 2 * m.pad_y;
        const shown = settle(panel, m, avail, if (scroll) |s| keptFor(s, panels, pi) else null);
        const rows = try arena.alloc(RowBox, shown.end - shown.top);
        const row_w = w - 2 * m.pad_x;
        var ry = y + m.pad_y;
        var more_up: ?region.Rect = null;
        if (shown.up) {
            more_up = .{ .x = x + m.pad_x, .y = ry, .w = row_w, .h = m.row_h };
            ry += m.row_h;
        }
        for (panel.items[shown.top..shown.end], shown.top.., rows) |it, i, *row| {
            const rh = if (it.separator) m.sep_h else m.row_h;
            row.* = .{ .item = i, .rect = .{ .x = x + m.pad_x, .y = ry, .w = row_w, .h = rh } };
            ry += rh;
        }
        const more_down: ?region.Rect = if (shown.end < panel.items.len) .{ .x = x + m.pad_x, .y = ry, .w = row_w, .h = m.row_h } else null;
        out[pi] = .{
            .box = .{ .x = x, .y = y, .w = w, .h = h },
            .rows = rows,
            .columns = measured.columns,
            .flipped = flipped,
            .more_up = more_up,
            .more_down = more_down,
        };
    }
    return out;
}

/// Which rows of `panel` a window `avail` high shows, from row `top`: up to
/// `end`, and whether indicators take a row above (`up`) and below.
const Window = struct { top: usize, end: usize, up: bool };

fn windowFrom(panel: Panel, m: Metrics, avail: f32, top: usize) Window {
    const up = top > 0;
    var room = avail - if (up) m.row_h else 0;
    var end = fitting(panel, m, room, top);
    if (end < panel.items.len) {
        // Hidden below too: its indicator takes a row.
        room -= m.row_h;
        end = fitting(panel, m, room, top);
    }
    // A window always shows a row, however little room it has.
    return .{ .top = top, .end = @max(end, @min(top + 1, panel.items.len)), .up = up };
}

/// How far from `top` the rows fit in `room`.
fn fitting(panel: Panel, m: Metrics, room: f32, top: usize) usize {
    var used: f32 = 0;
    var end = top;
    for (panel.items[top..]) |it| {
        const rh = if (it.separator) m.sep_h else m.row_h;
        if (used + rh > room + 0.5) break;
        used += rh;
        end += 1;
    }
    return end;
}

/// The window `panel` shows. Every row, when all fit. Else it scrolls: from
/// where it was (`kept`), moved by the wheel steps since, then — when the
/// lit row moved — only as far as shows it, and never past its last row.
fn settle(panel: Panel, m: Metrics, avail: f32, kept: ?*Scroll.Kept) Window {
    const n = panel.items.len;
    const all = windowFrom(panel, m, avail, 0);
    const lit = panel.lit();
    var top: usize = 0;
    var reveal = true;
    if (kept) |k| {
        const moved = (panel.wheel - k.wheel) * wheel_rows;
        top = if (moved < 0) k.top -| @as(usize, @intCast(-moved)) else k.top + @as(usize, @intCast(moved));
        reveal = !std.meta.eql(lit, k.lit);
        k.wheel = panel.wheel;
        k.lit = lit;
    }
    if (all.end == n) {
        if (kept) |k| k.top = 0;
        return all;
    }
    top = @min(top, n - 1);
    if (reveal) if (lit) |at| {
        if (at < top) top = at;
        while (windowFrom(panel, m, avail, top).end <= at) top += 1;
    };
    // Scrolled past the end: back until the last row sits at the bottom.
    while (top > 0 and windowFrom(panel, m, avail, top - 1).end == n) top -= 1;
    if (kept) |k| k.top = top;
    return windowFrom(panel, m, avail, top);
}

/// The kept window of panel `pi`, begun afresh when another panel, or
/// another opening of it, now stands at that depth.
fn keptFor(scroll: *Scroll, panels: []const Panel, pi: usize) ?*Scroll.Kept {
    if (pi >= scroll.kept.len) return null;
    const panel = panels[pi];
    const key: [2]u64 = .{ if (panel.node) |node| @intFromEnum(node) else 0, panel.opened };
    const k = &scroll.kept[pi];
    if (k.key == null or !std.mem.eql(u64, &k.key.?, &key)) k.* = .{ .key = key, .wheel = panel.wheel };
    return k;
}

fn panelHeight(panel: Panel, m: Metrics) f32 {
    var h: f32 = 2 * m.pad_y;
    for (panel.items) |it| h += if (it.separator) m.sep_h else m.row_h;
    return h;
}

/// A text style's widths are whole cells.
fn snap(v: *const View, w: f32) f32 {
    if (v.chrome == .widget) return @round(w);
    return @ceil(w / v.cell_w - 0.01) * v.cell_w;
}

fn rowRect(pb: PanelBox, item: usize) ?region.Rect {
    for (pb.rows) |r| if (r.item == item) return r.rect;
    return null;
}

/// The union of every panel's box: what the pointer treats as the menu's.
pub fn extent(boxes: []const PanelBox) ?region.Rect {
    if (boxes.len == 0) return null;
    var x0 = boxes[0].box.x;
    var y0 = boxes[0].box.y;
    var x1 = x0 + boxes[0].box.w;
    var y1 = y0 + boxes[0].box.h;
    for (boxes[1..]) |b| {
        x0 = @min(x0, b.box.x);
        y0 = @min(y0, b.box.y);
        x1 = @max(x1, b.box.x + b.box.w);
        y1 = @max(y1, b.box.y + b.box.h);
    }
    return .{ .x = x0, .y = y0, .w = x1 - x0, .h = y1 - y0 };
}

// ── Anchors ─────────────────────────────────────────────────────────

/// The box of node `node` of view `slot.generation` in the frame's pane maps
/// (a menubar title, drawn earlier in this frame or the last).
pub fn anchorBox(v: *const View, root: *const Node) ?region.Rect {
    const spelled = fact(root, "anchor-view") orelse return null;
    const node_text = fact(root, "anchor-node") orelse return null;
    const dot = std.mem.indexOfScalar(u8, spelled, '.') orelse return null;
    const slot = std.fmt.parseInt(u32, spelled[0..dot], 10) catch return null;
    const generation = std.fmt.parseInt(u32, spelled[dot + 1 ..], 10) catch return null;
    const node = std.fmt.parseInt(u64, node_text, 10) catch return null;
    for (v.pane_maps[0..v.pane_map_count]) |m| for (m.hits) |hit| {
        if (@intFromEnum(hit.node) != node) continue;
        if (hit.view.slot != slot or hit.view.generation != generation) continue;
        return hit.rect;
    };
    return null;
}

// ── Drawing ─────────────────────────────────────────────────────────

pub const Hit = struct { node: NodeId, rect: region.Rect };

pub const Drawn = struct { hits: []const Hit, box: ?region.Rect };

/// Paint the menu rooted at `root` against `bounds`, hung at `anchor`.
/// `hovered` is the node the pointer rests on; `tooltip` whether its tooltip
/// is due, which a disabled row answers with its reason (`View.build_tip`).
pub fn draw(
    v: *View,
    scratch: Allocator,
    hit_arena: Allocator,
    runs: *std.ArrayList(Run),
    rects: *std.ArrayList(Rect),
    root: *const Node,
    anchor: Anchor,
    bounds: region.Rect,
    hovered: ?NodeId,
    pressed: bool,
    tooltip: bool,
) !Drawn {
    const panels = try panelsOf(scratch, root);
    // An empty root panel is a menu with nothing dropped down yet (a
    // menubar title lit from the keyboard): nothing to draw.
    if (panels.len == 0 or panels[0].items.len == 0) return .{ .hits = &.{}, .box = null };
    const boxes = try layout(v, scratch, panels, anchor, bounds, &v.menu_scroll);
    const sink: chrome.Sink = .{ .v = v, .scratch = scratch, .runs = runs, .rects = rects };
    const th = &v.theme;
    const fill = switch (v.chrome) {
        .text, .text_icons => chrome.mix(th.background, th.selection, 0.22),
        .widget => chrome.mix(th.background, th.selection, 0.3),
    };
    var hits: std.ArrayList(Hit) = .empty;
    for (panels, boxes) |panel, pb| {
        try chrome.paintPanel(sink, pb.box, fill, th.status, .menu);
        if (pb.more_up) |r| try chrome.paintMenuMore(sink, r, .up);
        if (pb.more_down) |r| try chrome.paintMenuMore(sink, r, .down);
        for (pb.rows) |rb| {
            const it = panel.items[rb.item];
            if (it.separator) {
                const inset: f32 = if (v.chrome == .widget) 6 else v.cell_w;
                try chrome.paintSeparator(sink, .{ .x = rb.rect.x + inset, .y = rb.rect.y, .w = @max(0, rb.rect.w - 2 * inset), .h = rb.rect.h }, .horizontal);
                continue;
            }
            const is_hovered = if (hovered) |n| n == it.node else false;
            const state: chrome.State = .{
                .hover = is_hovered,
                .pressed = is_hovered and pressed,
                .disabled = it.reason.len != 0 or it.heading,
                .focused = it.lit,
                .checked = it.checked,
            };
            try chrome.paintMenuRow(sink, state, .{
                .label = it.label,
                .icon = it.icon,
                .key_hint = it.keys,
                .mnemonic = it.mnemonic,
                .submenu = it.submenu,
                .radio = it.radio,
            }, rb.rect, pb.columns);
            if (is_hovered and tooltip and it.reason.len != 0)
                v.build_tip = .{ .label = it.label, .key_hint = it.keys, .reason = it.reason, .command = it.name };
            try hits.append(hit_arena, .{ .node = it.node, .rect = rb.rect });
        }
    }
    return .{ .hits = try hits.toOwnedSlice(hit_arena), .box = extent(boxes) };
}

// ── Tests ───────────────────────────────────────────────────────────

const t = std.testing;

fn testItem(id: u64, label: []const u8, facts: []const semantic.scene.Fact) Node {
    return .{ .id = @enumFromInt(id), .role = role_item, .facts = facts, .content = .{ .action = .{ .action = "menu.choose", .label = label } } };
}

test "menu: panels are read from the scene, an open submenu after its item" {
    const sub_items = [_]Node{ testItem(20, "Text", &.{.{ .name = "radio", .value = "on" }}), testItem(21, "Widget", &.{ .{ .name = "radio", .value = "on" }, .{ .name = "checked", .value = "on" } }) };
    const items = [_]Node{
        testItem(2, "Command Palette", &.{.{ .name = "keys", .value = "C-S-p" }}),
        .{ .id = @enumFromInt(3), .role = "separator", .content = .{ .label = "──" } },
        testItem(4, "Appearance", &.{ .{ .name = "submenu", .value = "on" }, .{ .name = "lit", .value = "on" } }),
        .{ .id = @enumFromInt(5), .role = role_menu, .content = .{ .container = .{ .children = &sub_items } } },
        testItem(6, "Zoom In", &.{ .{ .name = "reason", .value = "not now" }, .{ .name = "mnemonic", .value = "5" } }),
    };
    const root: Node = .{ .id = @enumFromInt(1), .role = role_menu, .content = .{ .container = .{ .children = &items } } };
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const panels = try panelsOf(arena.allocator(), &root);
    try t.expectEqual(@as(usize, 2), panels.len);
    try t.expectEqual(@as(usize, 4), panels[0].items.len);
    try t.expect(panels[0].items[1].separator);
    try t.expect(panels[0].items[2].submenu and panels[0].items[2].lit);
    try t.expectEqualStrings("not now", panels[0].items[3].reason);
    try t.expectEqual(@as(?usize, 5), panels[0].items[3].mnemonic);
    try t.expectEqual(@as(usize, 0), panels[1].parent.?.panel);
    try t.expectEqual(@as(usize, 2), panels[1].parent.?.item);
    try t.expect(panels[1].items[1].checked and panels[1].items[1].radio);
}

test "menu: a submenu opens beside its row, flips at the frame's edge, and every panel stays inside the frame" {
    const font_provider = @import("weft_font_provider");
    var v = try View.init(t.allocator, font_provider.defaultMono(), 16);
    defer v.deinit();
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const top = [_]Item{ .{ .node = @enumFromInt(2), .label = "New File" }, .{ .node = @enumFromInt(3), .separator = true }, .{ .node = @enumFromInt(4), .label = "Share", .submenu = true } };
    const sub = [_]Item{ .{ .node = @enumFromInt(5), .label = "Host Session…", .keys = "C-x h" }, .{ .node = @enumFromInt(6), .label = "Join Session…" } };
    const panels = [_]Panel{ .{ .items = &top }, .{ .items = &sub, .parent = .{ .panel = 0, .item = 2 } } };
    const bounds: region.Rect = .{ .x = 0, .y = 0, .w = 800, .h = 600 };
    for ([_]chrome.Style{ .text, .text_icons, .widget }) |style| {
        v.chrome = style;
        // Room on the right: the submenu opens there, level with its row.
        const beside = try layout(&v, a, &panels, .{ .below = .{ .x = 10, .y = 0, .w = 40, .h = 20 } }, bounds, null);
        try t.expectEqual(@as(f32, 20), beside[0].box.y);
        try t.expect(!beside[1].flipped);
        try t.expect(beside[1].box.x >= beside[0].box.x + beside[0].box.w - 4);
        try t.expectApproxEqAbs(beside[0].rows[2].rect.y, beside[1].rows[0].rect.y, 0.5);
        // No room: it flips to the parent's left.
        const edge = try layout(&v, a, &panels, .{ .below = .{ .x = 700, .y = 0, .w = 40, .h = 20 } }, bounds, null);
        try t.expect(edge[1].flipped);
        try t.expect(edge[1].box.x + edge[1].box.w <= edge[0].box.x + 4);
        for (edge) |pb| {
            try t.expect(pb.box.x >= 0 and pb.box.x + pb.box.w <= 800);
            try t.expect(pb.box.y >= 0 and pb.box.y + pb.box.h <= 600);
        }
        // Hung at a point near the bottom: above it instead.
        const low = try layout(&v, a, panels[0..1], .{ .point = .{ 100, 590 } }, bounds, null);
        try t.expect(low[0].flipped);
        try t.expect(low[0].box.y + low[0].box.h <= 590);
        // The text styles keep the cell grid.
        if (style != .widget) try t.expectApproxEqAbs(@round(low[0].box.w / v.cell_w) * v.cell_w, low[0].box.w, 0.01);
    }
}

test "menu: a panel taller than the frame scrolls — the lit row is always laid out, wherever the keys took it" {
    const font_provider = @import("weft_font_provider");
    var v = try View.init(t.allocator, font_provider.defaultMono(), 16);
    defer v.deinit();
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var items: [60]Item = undefined;
    for (&items, 0..) |*it, i| it.* = .{ .node = @enumFromInt(100 + i), .label = "Row" };
    const bounds: region.Rect = .{ .x = 0, .y = 0, .w = 800, .h = 200 };
    for ([_]chrome.Style{ .text, .text_icons, .widget }) |style| {
        v.chrome = style;
        for ([_]usize{ 0, 30, 59 }) |lit| {
            for (&items, 0..) |*it, i| it.lit = i == lit;
            const panels = [_]Panel{.{ .items = &items }};
            const boxes = try layout(&v, a, &panels, .{ .below = .{ .x = 10, .y = 0, .w = 40, .h = 20 } }, bounds, null);
            const laid = for (boxes[0].rows) |r| {
                if (r.item == lit) break true;
            } else false;
            try t.expect(laid);
            // Indicators say where rows are hidden; every row shown is inside the panel.
            try t.expectEqual(boxes[0].rows[0].item > 0, boxes[0].more_up != null);
            try t.expectEqual(boxes[0].rows[boxes[0].rows.len - 1].item < 59, boxes[0].more_down != null);
            const box = boxes[0].box;
            for (boxes[0].rows) |r| try t.expect(r.rect.y >= box.y and r.rect.y + r.rect.h <= box.y + box.h + 0.5);
        }
    }
}

test "menu: a scrolled panel keeps its window — the lit row moves inside it, the wheel moves it, a new opening starts at the top" {
    const font_provider = @import("weft_font_provider");
    var v = try View.init(t.allocator, font_provider.defaultMono(), 16);
    defer v.deinit();
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    v.chrome = .text;
    var items: [60]Item = undefined;
    for (&items, 0..) |*it, i| it.* = .{ .node = @enumFromInt(100 + i), .label = "Row" };
    var scroll: Scroll = .{};
    const Frame = struct {
        fn at(vv: *View, aa: Allocator, its: []Item, lit: usize, wheel: i32, opened: u32, s: *Scroll) !PanelBox {
            for (its, 0..) |*it, i| it.lit = i == lit;
            const panels = [_]Panel{.{ .items = its, .node = @enumFromInt(1), .opened = opened, .wheel = wheel }};
            const boxes = try layout(vv, aa, &panels, .{ .below = .{ .x = 10, .y = 0, .w = 40, .h = 20 } }, .{ .x = 0, .y = 0, .w = 800, .h = 200 }, s);
            return boxes[0];
        }
    };
    // Down past the bottom: the window follows, the lit row last.
    const first = try Frame.at(&v, a, &items, 0, 0, 1, &scroll);
    const shown = first.rows.len;
    const deep = try Frame.at(&v, a, &items, shown + 4, 0, 1, &scroll);
    try t.expectEqual(shown + 4, deep.rows[deep.rows.len - 1].item);
    const top = deep.rows[0].item;
    // Up one: the lit row moves inside the window, which stays.
    const up = try Frame.at(&v, a, &items, shown + 3, 0, 1, &scroll);
    try t.expectEqual(top, up.rows[0].item);
    // Built again from the same input: the same rows.
    const again = try Frame.at(&v, a, &items, shown + 3, 0, 1, &scroll);
    try t.expectEqual(top, again.rows[0].item);
    // Two wheel steps down move it `2 * wheel_rows`, lit row or not.
    const wheeled = try Frame.at(&v, a, &items, shown + 3, 2, 1, &scroll);
    try t.expectEqual(top + 2 * wheel_rows, wheeled.rows[0].item);
    // Wheeled far past the end: the last row sits at the bottom.
    const end = try Frame.at(&v, a, &items, shown + 3, 100, 1, &scroll);
    try t.expectEqual(@as(usize, 59), end.rows[end.rows.len - 1].item);
    try t.expect(end.more_down == null and end.more_up != null);
    // Opened again: from the top.
    const reopened = try Frame.at(&v, a, &items, 0, 0, 2, &scroll);
    try t.expectEqual(@as(usize, 0), reopened.rows[0].item);
    try t.expect(reopened.more_up == null);
}
