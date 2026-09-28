//! Chrome — how buttons, tabs, menu items, status segments, chips,
//! separators, rows and headers LOOK (doc/chrome.md §3).
//!
//! Chrome is not text. Every chrome element is a ROLE in a STATE with some
//! CONTENT (a label, an icon name, a key hint), and a chrome STYLE turns that
//! triple into draw items. A producer never picks a look: it says a node is a
//! button, or a separator, and the style decides — so the same toolbar is a
//! row of padded cells under `text`, cells with small icons under
//! `text-icons`, and flat buttons (a rounded face on hover) under `widget`, with no producer knowing.
//!
//! The style is a theme value (`theme/chrome`), resolved into `View.chrome`
//! and read here at draw time, so switching it is one binding and the next
//! frame (`theme.set-chrome`). The two text styles stay on the cell grid —
//! a cell-aligned, keyboard-first UI with no brackets; `widget` is not
//! cell-aligned where it need not be (tabs are laid out in pixels) and draws
//! with the D2 primitives: rounded rects, outlines, soft shadows and icons.
//!
//! Layout that other code measures (a button's cells in a scene row, a
//! status segment's columns) is decided by `buttonCols` and friends, which
//! every style answers; painting never moves anything a hit rect was taken
//! from. Hover and press are frame INPUT (`Hud.pointer`, doc/model.md §2.7):
//! a style reads them, it never asks for them.

const std = @import("std");
const Allocator = std.mem.Allocator;

const region = @import("../region.zig");
const icons = @import("../icons.zig");
const View = @import("View.zig");
const popup = @import("popup.zig");
const hud_mod = @import("hud.zig");
const menu = @import("menu.zig");

const Run = View.Run;
const Rect = View.Rect;

/// The three chrome styles (doc/chrome.md §3.2), spelled as the theme slot
/// spells them.
pub const Style = enum {
    text,
    text_icons,
    widget,

    pub fn parse(spelled: []const u8) ?Style {
        if (std.mem.eql(u8, spelled, "text")) return .text;
        if (std.mem.eql(u8, spelled, "text-icons")) return .text_icons;
        if (std.mem.eql(u8, spelled, "widget")) return .widget;
        return null;
    }

    pub fn name(self: Style) []const u8 {
        return switch (self) {
            .text => "text",
            .text_icons => "text-icons",
            .widget => "widget",
        };
    }

    /// The next style round the cycle (the palette's toggle).
    pub fn next(self: Style) Style {
        return switch (self) {
            .text => .text_icons,
            .text_icons => .widget,
            .widget => .text,
        };
    }

    /// Whether this style draws icons beside labels.
    pub fn showsIcons(self: Style) bool {
        return self != .text;
    }
};

/// `menu_title` is a menubar's title (File, Edit, …): a padded label with its
/// mnemonic underlined, lit while its menu is open.
pub const Role = enum { button, tab, menu_item, menu_title, status_segment, chip, separator, row, header };

pub const State = packed struct(u8) {
    hover: bool = false,
    pressed: bool = false,
    disabled: bool = false,
    selected: bool = false,
    focused: bool = false,
    checked: bool = false,
    _pad: u2 = 0,
};

pub const Content = struct {
    label: []const u8 = "",
    /// An icon NAME in the theme's set; drawn only by a style that shows
    /// icons, and only when the set has it.
    icon: ?[]const u8 = null,
    /// The keys that run it, right-aligned in a menu item.
    key_hint: []const u8 = "",
    /// The element's own text colour (a status segment's role, a tone).
    fg: ?[4]f32 = null,
    /// A chip's own background.
    bg: ?[4]f32 = null,
    /// The codepoint of the label a menu item or title underlines: its
    /// mnemonic, the letter that chooses it from the keyboard.
    mnemonic: ?usize = null,
    /// A menu item that opens a submenu: a chevron at the far right.
    submenu: bool = false,
    /// A checked menu item that is one choice among several: a dot, not a
    /// check.
    radio: bool = false,
};

/// Where a style's items go: the frame's run and rect lists.
pub const Sink = struct {
    v: *View,
    scratch: Allocator,
    runs: *std.ArrayList(Run),
    rects: *std.ArrayList(Rect),

    fn rect(self: Sink, r: Rect) !void {
        try self.rects.append(self.scratch, r);
    }

    fn fill(self: Sink, box: region.Rect, color: [4]f32) !void {
        try self.rect(.{ .x = box.x, .y = box.y, .w = box.w, .h = box.h, .color = color });
    }

    fn rounded(self: Sink, box: region.Rect, color: [4]f32, shape: Rect.Rounded) !void {
        try self.rect(.{ .x = box.x, .y = box.y, .w = box.w, .h = box.h, .color = color, .shape = .{ .rounded = shape } });
    }

    /// A label at x on the row whose top is `row_y`, clipped to `clip`.
    fn label(self: Sink, text: []const u8, x: f32, row_y: f32, color: [4]f32, clip: ?region.Rect) !void {
        if (text.len == 0) return;
        try popup.propLine(self.v, self.scratch, self.runs, text, x, row_y + self.v.ascent, color);
        self.runs.items[self.runs.items.len - 1].clip = clip;
    }

    /// The icon `name` in a square of side `side` centred on (cx, cy);
    /// false when the style or the set has none, so the caller can fall
    /// back to text.
    fn icon(self: Sink, name: []const u8, cx: f32, cy: f32, side: f32, color: [4]f32) !bool {
        const drawn = self.v.icon(name) orelse return false;
        try self.rect(.{
            .x = @round(cx - side / 2),
            .y = @round(cy - side / 2),
            .w = side,
            .h = side,
            .color = color,
            .shape = .{ .icon = drawn },
        });
        return true;
    }
};

/// The icon `name` in a square of side `side` centred on (cx, cy), tinted
/// `color`; false when the style or the set draws none.
pub fn drawIcon(s: Sink, name: []const u8, cx: f32, cy: f32, side: f32, color: [4]f32) !bool {
    return s.icon(name, cx, cy, side, color);
}

// ── Palette ─────────────────────────────────────────────────────────

pub fn mix(a: [4]f32, b: [4]f32, t: f32) [4]f32 {
    return .{ a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t, a[3] + (b[3] - a[3]) * t };
}

fn withAlpha(c: [4]f32, a: f32) [4]f32 {
    return .{ c[0], c[1], c[2], a };
}

/// A surface's resting, hovered and pressed fills, from the theme: a
/// button or an inactive tab is a lift of the background toward the
/// selection colour, more of it the more it is being touched.
fn surfaceFill(v: *const View, state: State, rest: f32) [4]f32 {
    const th = &v.theme;
    if (state.pressed) return mix(th.selection, th.accent, 0.25);
    if (state.hover) return mix(th.background, th.selection, @min(1, rest + 0.3));
    return mix(th.background, th.selection, rest);
}

fn textColor(v: *const View, state: State, content: Content) [4]f32 {
    if (state.disabled) return v.theme.status;
    return content.fg orelse v.theme.foreground;
}

/// The side of an icon drawn beside text of the view's size.
pub fn iconSide(v: *const View) f32 {
    return @round(@min(v.line_h - 2, v.em * 0.95));
}

fn cols(text: []const u8) usize {
    return std.unicode.utf8CountCodepoints(text) catch text.len;
}

fn colsW(v: *const View, n: usize) f32 {
    return @as(f32, @floatFromInt(n)) * v.cell_w;
}

// ── Measures ────────────────────────────────────────────────────────

/// Whether `content` gets an icon drawn under `v`'s style and set.
pub fn hasIcon(v: *const View, content: Content) bool {
    const name = content.icon orelse return false;
    return v.icon(name) != null;
}

/// A button's width in cells, in every style: a cell of padding either side
/// of the label, and two more for an icon when the style draws one. The
/// scene presenter lays buttons out on the cell grid with this, so a click
/// lands on the button whatever the style paints.
pub fn buttonCols(v: *const View, content: Content) usize {
    return cols(content.label) + 2 + @as(usize, if (hasIcon(v, content)) 2 else 0);
}

// ── Painting ────────────────────────────────────────────────────────

/// Paint one element of `role` into `box` (a row of the view's line height,
/// or the cells a measure above allotted it).
pub fn paint(s: Sink, role: Role, state: State, content: Content, box: region.Rect) !void {
    switch (role) {
        .button => try paintButton(s, state, content, box),
        .menu_item => try paintMenuRow(s, state, content, box, defaultColumns(s.v, content)),
        .menu_title => try paintTitle(s, state, content, box),
        .row => try paintRow(s, state, content, box),
        .status_segment, .chip => try paintSegment(s, role, state, content, box),
        .header => try paintHeader(s, content, box),
        .separator => try paintSeparator(s, box, if (box.w >= box.h) .horizontal else .vertical),
        .tab => try paintTab(s, state, content, box, null, false),
    }
}

fn paintButton(s: Sink, state: State, content: Content, box: region.Rect) !void {
    const v = s.v;
    const style = v.chrome;
    const fg = textColor(v, state, content);
    switch (style) {
        .text, .text_icons => {
            // Padded cells on a subtle lift; a disabled button keeps its
            // cells (it is still clickable, to say why) but barely lifts.
            const fill = if (state.disabled) mix(v.theme.background, v.theme.selection, 0.12) else surfaceFill(v, state, 0.28);
            try s.fill(box, fill);
        },
        .widget => {
            // FLAT: a toolbar button is its icon and label until the pointer
            // is on it; hover and press show a rounded rectangle (a small
            // radius, never a pill), inset from the cell box so neighbours
            // never touch. A disabled button draws no surface at all — its
            // dimmed text says it (it stays clickable, to say why).
            if (!state.disabled and (state.hover or state.pressed or state.focused)) {
                const inset: f32 = 3;
                const face: region.Rect = .{ .x = box.x + 1, .y = box.y + inset, .w = @max(0, box.w - 2), .h = @max(0, box.h - 2 * inset) };
                try s.rounded(face, surfaceFill(v, state, 0.5), .{ .radius = 4 });
            }
        },
    }
    var x = box.x + v.cell_w;
    if (hasIcon(v, content)) {
        if (try s.icon(content.icon.?, x + v.cell_w * 0.5 + 1, box.y + v.line_h / 2, iconSide(v), fg)) x += 2 * v.cell_w;
    }
    try s.label(content.label, x, box.y, fg, box);
}

/// The wash behind a lit row (hover, the keyboard's place, a press): the whole
/// cell row under the text styles, an inset rounded bar under `widget`.
fn rowWash(s: Sink, state: State, box: region.Rect) !void {
    const v = s.v;
    const th = &v.theme;
    if (!(state.hover or state.pressed or state.focused)) return;
    const strong = state.pressed or state.focused;
    switch (v.chrome) {
        .text, .text_icons => try s.fill(box, mix(th.background, th.selection, if (state.pressed) 0.95 else if (strong) 0.8 else 0.5)),
        .widget => try s.rounded(.{ .x = box.x, .y = box.y + 1, .w = box.w, .h = @max(0, box.h - 2) }, mix(th.background, th.selection, if (state.pressed) 1 else if (strong) 0.85 else 0.6), .{ .radius = 5 }),
    }
}

/// A plain row: a hover wash, the label, and a key hint right-aligned. The
/// wash here is hover's — a row's focus and selection highlights belong to
/// the presenter that knows what focus means there.
fn paintRow(s: Sink, state: State, content: Content, box: region.Rect) !void {
    const v = s.v;
    var hover = state;
    hover.focused = false;
    try rowWash(s, hover, box);
    const fg = textColor(v, state, content);
    var label_clip = box;
    if (content.key_hint.len != 0) {
        const hint_w = colsW(v, cols(content.key_hint));
        const hx = box.x + box.w - hint_w - v.cell_w;
        if (hx > box.x) {
            try s.label(content.key_hint, hx, box.y, v.theme.status, box);
            label_clip.w = @max(0, hx - v.cell_w - box.x);
        }
    }
    try s.label(content.label, box.x, box.y, fg, label_clip);
}

/// A lone menu item's columns (a panel's are `menu.layout`'s, shared by all
/// its rows).
fn defaultColumns(v: *const View, content: Content) menu.Columns {
    const lead: f32 = if (v.chrome == .widget) iconSide(v) + 12 else 2 * v.cell_w;
    const chevron: f32 = if (!content.submenu) 0 else if (v.chrome == .widget) iconSide(v) + 6 else 2 * v.cell_w;
    const pad: f32 = if (v.chrome == .widget) 10 else v.cell_w;
    return .{ .lead = lead, .label = lead, .keys_right = pad + chevron, .chevron = chevron };
}

/// One row of a menu (doc/chrome.md §2.1): a wash while it is lit — the
/// keyboard's place, or under the pointer — then, in `columns`, a check mark,
/// a choice's dot or the icon in the lead column, the label with its mnemonic
/// underlined, the key hint right-aligned, and a chevron when it opens a
/// submenu. A disabled row is greyed and never washed as pressed.
pub fn paintMenuRow(s: Sink, state: State, content: Content, box: region.Rect, columns: menu.Columns) !void {
    const v = s.v;
    const th = &v.theme;
    var wash = state;
    if (state.disabled) wash.pressed = false;
    try rowWash(s, wash, box);
    const fg = textColor(v, state, content);
    // The text row sits in the middle of a taller `widget` row.
    const ty = box.y + @round((box.h - v.line_h) / 2);
    const cy = box.y + box.h / 2;
    if (columns.lead > 0) {
        const cx = box.x + columns.lead / 2;
        if (state.checked and content.radio) {
            // The chosen one of several: a dot — a filled disc under
            // `widget`, the bullet glyph on the cell grid.
            if (v.chrome == .widget) {
                const d = @round(iconSide(v) * 0.42);
                try s.rounded(.{ .x = @round(cx - d / 2), .y = @round(cy - d / 2), .w = d, .h = d }, th.accent, .{ .radius = d / 2 });
            } else try s.label("•", cx - v.cell_w / 2, ty, th.accent, box);
        } else if (state.checked) {
            if (!try s.icon("check", cx, cy, iconSide(v), th.accent))
                try s.label("✓", cx - v.cell_w / 2, ty, th.accent, box);
        } else if (content.icon) |name| {
            _ = try s.icon(name, cx, cy, iconSide(v), fg);
        }
    }
    const lx = box.x + columns.label;
    const right = box.x + box.w - columns.keys_right;
    var label_clip = box;
    if (content.key_hint.len != 0) {
        const hx = right - colsW(v, cols(content.key_hint));
        if (hx > lx) {
            try s.label(content.key_hint, hx, ty, if (state.disabled) mix(th.background, th.status, 0.7) else th.status, box);
            label_clip.w = @max(0, hx - v.cell_w - box.x);
        }
    }
    try s.label(content.label, lx, ty, fg, label_clip);
    if (content.mnemonic) |at| try underline(s, content.label, at, lx, ty, fg);
    if (content.submenu and columns.chevron > 0) {
        const cx = box.x + box.w - columns.chevron / 2 - (if (v.chrome == .widget) @as(f32, 4) else 0);
        if (!try s.icon("chevron-right", cx, cy, iconSide(v) * 0.9, fg))
            try s.label("›", cx - v.cell_w / 2, ty, fg, box);
    }
}

/// A scrolled menu panel's indicator row: a chevron centred in `box`,
/// pointing to where rows are hidden.
pub fn paintMenuMore(s: Sink, box: region.Rect, dir: enum { up, down }) !void {
    const v = s.v;
    const fg = mix(v.theme.background, v.theme.status, 0.7);
    const cx = box.x + box.w / 2;
    const cy = box.y + box.h / 2;
    if (!try s.icon(if (dir == .up) "chevron-up" else "chevron-down", cx, cy, iconSide(v) * 0.9, fg))
        try s.label(if (dir == .up) "▲" else "▼", cx - v.cell_w / 2, box.y + @round((box.h - v.line_h) / 2), fg, box);
}

/// A menubar title: a padded label, its mnemonic underlined, washed while its
/// menu is open (`focused`) or the pointer is on it.
fn paintTitle(s: Sink, state: State, content: Content, box: region.Rect) !void {
    const v = s.v;
    const th = &v.theme;
    const lit = state.focused or state.hover or state.pressed;
    if (lit) switch (v.chrome) {
        .text, .text_icons => try s.fill(box, mix(th.background, th.selection, if (state.focused) 0.85 else 0.45)),
        .widget => try s.rounded(.{ .x = box.x, .y = box.y + 2, .w = box.w, .h = @max(0, box.h - 4) }, mix(th.background, th.selection, if (state.focused) 0.85 else 0.5), .{ .radius = 5 }),
    };
    const x = box.x + v.cell_w;
    try s.label(content.label, x, box.y, textColor(v, state, content), box);
    if (content.mnemonic) |at| try underline(s, content.label, at, x, box.y, textColor(v, state, content));
}

/// Underline codepoint `at` of `label`, drawn from `x` on the text row whose
/// top is `row_y`: a mnemonic.
fn underline(s: Sink, label: []const u8, at: usize, x: f32, row_y: f32, color: [4]f32) !void {
    const v = s.v;
    if (at >= cols(label)) return;
    const ux = x + colsW(v, at);
    const uy = @round(row_y + v.ascent + @max(1, (v.line_h - v.ascent) * 0.35));
    try s.fill(.{ .x = @round(ux + 1), .y = uy, .w = @max(1, @round(v.cell_w - 2)), .h = 1 }, color);
}

/// A menubar title's width in cells: its label and a cell either side.
pub fn titleCols(content: Content) usize {
    return cols(content.label) + 2;
}

/// A status segment (text in its own colour) or a chip (a label on its own
/// background). Both stay on the status line's cell grid — the layout is
/// the status line's (doc/chrome.md §4); only the look is the style's.
fn paintSegment(s: Sink, role: Role, state: State, content: Content, box: region.Rect) !void {
    const v = s.v;
    if (role == .chip) if (content.bg) |bg| switch (v.chrome) {
        .text, .text_icons => try s.fill(box, bg),
        .widget => try s.rounded(.{ .x = box.x, .y = box.y + 2, .w = box.w, .h = @max(0, box.h - 4) }, bg, .{ .radius = @max(0, box.h - 4) / 2 }),
    };
    if (state.hover and content.bg == null) try s.fill(box, mix(v.theme.selection, v.theme.foreground, 0.12));
}

fn paintHeader(s: Sink, content: Content, box: region.Rect) !void {
    const v = s.v;
    try s.label(content.label, box.x, box.y, content.fg orelse v.theme.status, box);
    if (v.chrome == .widget) try paintSeparator(s, .{ .x = box.x, .y = box.y + box.h - 1, .w = box.w, .h = 1 }, .horizontal);
}

pub const Axis = enum { horizontal, vertical };

/// A divider: a 1px line centred across (`horizontal`) or down (`vertical`)
/// its box. Under the text styles the status grey, a line a person reads as
/// a vim split's; under `widget` a softer one.
pub fn paintSeparator(s: Sink, box: region.Rect, axis: Axis) !void {
    const v = s.v;
    const color = switch (v.chrome) {
        .text, .text_icons => v.theme.status,
        .widget => mix(v.theme.background, v.theme.status, 0.4),
    };
    const line: region.Rect = switch (axis) {
        .horizontal => .{ .x = box.x, .y = @round(box.y + (box.h - 1) / 2), .w = box.w, .h = 1 },
        .vertical => .{ .x = @round(box.x + (box.w - 1) / 2), .y = box.y, .w = 1, .h = box.h },
    };
    try s.fill(line, color);
}

// ── Tabs ────────────────────────────────────────────────────────────

/// Where one tab of a strip landed: its whole box and its close glyph.
pub const TabBox = struct { index: usize, box: region.Rect, close: region.Rect };

/// The icon a tab paints, or null for none: an ordinary buffer tab always
/// shows "file"; a COMMAND tab (`tab.command` set — a docked pane's header)
/// shows its own icon from its presentation, or none (the trailing close
/// affordance, whose glyph IS its label — see `Hud.Tab`'s doc).
pub fn tabIconName(tab: hud_mod.Tab) ?[]const u8 {
    if (tab.command.len == 0) return "file";
    return if (tab.icon.len > 0) tab.icon else null;
}

/// Lay a tab strip out in `strip`, as many tabs as start inside it (the last
/// may be cut off, and is clipped when painted). Text styles: one cell of
/// padding, the label, a cell of padding, the close glyph, a cell, and a
/// one-cell gap between tabs. `widget`: the same parts in pixels, with an
/// icon before the label. A COMMAND tab reserves no close-glyph width — its
/// whole body is the click target, and it carries its own trailing close
/// affordance as another tab, not a sub-region of this one.
pub fn layoutTabs(v: *const View, scratch: Allocator, tabs: []const hud_mod.Tab, strip: region.Rect) ![]TabBox {
    var out: std.ArrayList(TabBox) = .empty;
    var x = strip.x;
    const right = strip.x + strip.w;
    for (tabs, 0..) |tab, i| {
        if (x >= right) break;
        const is_command = tab.command.len > 0;
        const has_icon = if (tabIconName(tab)) |name| v.icon(name) != null else false;
        const label_w = colsW(v, cols(tab.name));
        var w: f32 = undefined;
        var close_x: f32 = undefined;
        const close_w: f32 = if (is_command) 0 else if (v.chrome == .widget) v.line_h else v.cell_w;
        switch (v.chrome) {
            .text, .text_icons => {
                const icon_w: f32 = if (v.chrome == .text_icons and has_icon) 2 * v.cell_w else 0;
                close_x = x + v.cell_w + icon_w + label_w + v.cell_w;
                w = close_x + close_w + v.cell_w - x;
            },
            .widget => {
                const icon_w: f32 = if (has_icon) iconSide(v) + 6 else 0;
                close_x = x + 10 + icon_w + label_w + 4;
                w = close_x + close_w + 4 - x;
            },
        }
        try out.append(scratch, .{
            .index = i,
            .box = .{ .x = x, .y = strip.y, .w = w, .h = strip.h },
            .close = .{ .x = close_x, .y = strip.y, .w = close_w, .h = strip.h },
        });
        x += w + if (v.chrome == .widget) 2 else v.cell_w;
    }
    return out.toOwnedSlice(scratch);
}

/// Paint one tab. `close_hover` is the pointer on its close glyph. Under
/// `widget` the close glyph shows only on the active or hovered tab, as a
/// person expects of real tabs; its hit region is there either way, so a
/// click aimed at it always closes.
pub fn paintTab(s: Sink, state: State, content: Content, tab: region.Rect, close_box: ?region.Rect, close_hover: bool) !void {
    const v = s.v;
    const th = &v.theme;
    const fg = if (state.selected) th.foreground else th.status;
    const clip = tab;
    switch (v.chrome) {
        .text, .text_icons => {
            // Padded cells; the active tab is told apart by colour alone.
            const fill = if (state.selected) mix(th.background, th.selection, 0.62) else surfaceFill(v, state, 0.18);
            try s.fill(tab, fill);
            var x = tab.x + v.cell_w;
            if (v.chrome == .text_icons) if (content.icon) |name| {
                if (try s.icon(name, x + v.cell_w * 0.5 + 1, tab.y + v.line_h / 2, iconSide(v), fg)) x += 2 * v.cell_w;
            };
            try s.label(content.label, x, tab.y, fg, clip);
            if (close_box) |cb| {
                const close_fg = if (close_hover) th.diag_error else th.status;
                if (!(v.chrome == .text_icons and try s.icon("close", cb.x + cb.w / 2, cb.y + v.line_h / 2, iconSide(v) * 0.85, close_fg)))
                    try s.label(hud_mod.tab_close_glyph, cb.x, tab.y, close_fg, clip);
            }
        },
        .widget => {
            // A real tab: rounded on top, square where it meets the pane.
            const body: region.Rect = .{ .x = tab.x, .y = tab.y + 3, .w = tab.w, .h = @max(0, tab.h - 3) };
            const fill: ?[4]f32 = if (state.selected)
                mix(th.background, th.selection, 0.5)
            else if (state.hover)
                mix(th.background, th.selection, 0.28)
            else
                null;
            if (fill) |f| {
                try s.rounded(body, f, .{ .radius = 6 });
                try s.fill(.{ .x = body.x, .y = body.y + body.h / 2, .w = body.w, .h = body.h / 2 }, f);
            }
            if (state.selected) try s.fill(.{ .x = body.x, .y = body.y + body.h - 2, .w = body.w, .h = 2 }, th.accent);
            var x = tab.x + 10;
            if (content.icon) |name| {
                const side = iconSide(v);
                if (try s.icon(name, x + side / 2, tab.y + 1 + v.line_h / 2, side, fg)) x += side + 6;
            }
            try s.label(content.label, x, tab.y + 1, fg, clip);
            if (close_box) |cb| if (state.selected or state.hover) {
                const side = iconSide(v) * 0.8;
                const cx = cb.x + cb.w / 2;
                const cy = tab.y + 1 + v.line_h / 2;
                if (close_hover) try s.rounded(.{ .x = cx - side * 0.75, .y = cy - side * 0.75, .w = side * 1.5, .h = side * 1.5 }, mix(th.background, th.selection, 0.9), .{ .radius = 4 });
                if (!try s.icon("close", cx, cy, side, if (close_hover) th.foreground else th.status))
                    try s.label(hud_mod.tab_close_glyph, cb.x + (cb.w - v.cell_w) / 2, tab.y + 1, th.status, clip);
            };
        },
    }
}

// ── Panels: popup, menu and tooltip frames ──────────────────────────

pub const PanelKind = enum { popup, menu, tooltip };

/// A floating box's frame. The text styles keep the flat box with a 1px
/// outline every popup has always had (so a golden of one does not move);
/// `widget` rounds it, outlines it softly and, for a menu or a tooltip,
/// casts a shadow beneath it.
pub fn paintPanel(s: Sink, box: region.Rect, fill: [4]f32, border: [4]f32, kind: PanelKind) !void {
    switch (s.v.chrome) {
        .text, .text_icons => try popup.outlinedBox(s.scratch, s.rects, box.x, box.y, box.w, box.h, fill, border),
        .widget => {
            const radius: f32 = if (kind == .tooltip) 5 else 7;
            if (kind != .popup) try s.rounded(.{ .x = box.x, .y = box.y + 3, .w = box.w, .h = box.h }, .{ 0, 0, 0, 0.45 }, .{ .radius = radius, .blur = 5 });
            try s.rounded(.{ .x = box.x - 1, .y = box.y - 1, .w = box.w + 2, .h = box.h + 2 }, fill, .{ .radius = radius + 1 });
            try s.rounded(.{ .x = box.x - 0.5, .y = box.y - 0.5, .w = box.w + 1, .h = box.h + 1 }, withAlpha(mix(fill, border, 0.55), 1), .{ .radius = radius + 0.5, .stroke_width = 1 });
        },
    }
}

/// A popup's selected row: the full row under the text styles, an inset
/// rounded bar under `widget`.
pub fn paintSelected(s: Sink, row: region.Rect, color: [4]f32) !void {
    switch (s.v.chrome) {
        .text, .text_icons => try s.fill(row, color),
        .widget => try s.rounded(.{ .x = row.x + 3, .y = row.y, .w = @max(0, row.w - 6), .h = row.h }, color, .{ .radius = 4 }),
    }
}

/// What a tooltip says: a label, the keys that run it (its own, else the
/// frame's `KeyHint`), and why it cannot run, when it cannot.
pub const Tip = struct {
    label: []const u8,
    key_hint: []const u8 = "",
    reason: []const u8 = "",
    /// What the element runs, for the key hint to be looked up by.
    command: []const u8 = "",
};

/// Paint a tooltip below-right of the pointer, kept inside `bounds`.
pub fn paintTooltip(s: Sink, tip: Tip, at: [2]f32, bounds: region.Rect) !void {
    const v = s.v;
    const th = &v.theme;
    var first_cols = cols(tip.label);
    if (tip.key_hint.len != 0) first_cols += 2 + cols(tip.key_hint);
    const widest = @max(first_cols, cols(tip.reason));
    const rows: f32 = if (tip.reason.len != 0) 2 else 1;
    const pad = v.cell_w * 0.75;
    const w = @min(bounds.w, colsW(v, widest) + 2 * pad);
    const h = rows * v.line_h + 6;
    const x = std.math.clamp(at[0] + 4, bounds.x, @max(bounds.x, bounds.x + bounds.w - w));
    const below = at[1] + v.line_h;
    const y = std.math.clamp(if (below + h <= bounds.y + bounds.h) below else at[1] - h - 4, bounds.y, @max(bounds.y, bounds.y + bounds.h - h));
    const box: region.Rect = .{ .x = x, .y = y, .w = w, .h = h };
    try paintPanel(s, box, mix(th.background, th.selection, 0.35), th.status, .tooltip);
    const tx = x + pad;
    try s.label(tip.label, tx, y + 3, th.foreground, box);
    if (tip.key_hint.len != 0) try s.label(tip.key_hint, tx + colsW(v, cols(tip.label) + 2), y + 3, th.status, box);
    if (tip.reason.len != 0) try s.label(tip.reason, tx, y + 3 + v.line_h, th.diag_warn, box);
}

/// The key that runs the hovered element's command here — the tooltip's key
/// hint, as frame INPUT. The shell asks `keysFor` (doc/chrome.md §1.3) once,
/// when the pointer settles on the element, so the key shown is the one that
/// would work in the focused pane and a frame build asks nothing.
pub const KeyHint = struct {
    /// What the hint was found for.
    command: []const u8 = "",
    keys: []const u8 = "",

    /// The keys for `command`, or "" when the hint is for something else.
    pub fn of(self: KeyHint, command: []const u8) []const u8 {
        if (command.len == 0 or !std.mem.eql(u8, command, self.command)) return "";
        return self.keys;
    }
};

// ── Tests ──

const testing = std.testing;

test "chrome: every role renders under all three styles, switched live between frames" {
    const gpa = testing.allocator;
    const harness = @import("../harness.zig");
    const render = @import("render.zig");
    const font_provider = @import("weft_font_provider");
    var v = try View.init(gpa, font_provider.defaultMono(), 16);
    defer v.deinit();
    const w: u32 = 480;
    const h: u32 = 400;

    const Case = struct { role: Role, state: State, content: Content };
    const cases = [_]Case{
        .{ .role = .button, .state = .{}, .content = .{ .label = "Save", .icon = "save" } },
        .{ .role = .button, .state = .{ .hover = true }, .content = .{ .label = "Undo", .icon = "undo" } },
        .{ .role = .button, .state = .{ .disabled = true }, .content = .{ .label = "Redo", .icon = "redo" } },
        .{ .role = .menu_item, .state = .{ .hover = true }, .content = .{ .label = "Split Right", .icon = "split-right", .key_hint = "C-w v" } },
        .{ .role = .menu_item, .state = .{ .checked = true }, .content = .{ .label = "Sidebar" } },
        .{ .role = .menu_item, .state = .{ .focused = true }, .content = .{ .label = "Appearance", .submenu = true, .mnemonic = 0 } },
        .{ .role = .menu_title, .state = .{ .focused = true }, .content = .{ .label = "File", .mnemonic = 0 } },
        .{ .role = .status_segment, .state = .{ .hover = true }, .content = .{ .label = "" } },
        .{ .role = .chip, .state = .{}, .content = .{ .bg = v.theme.diag_error } },
        .{ .role = .row, .state = .{ .hover = true }, .content = .{ .label = "a.zig" } },
        .{ .role = .header, .state = .{}, .content = .{ .label = "Changes" } },
        .{ .role = .separator, .state = .{}, .content = .{} },
        .{ .role = .tab, .state = .{ .selected = true }, .content = .{ .label = "main.zig", .icon = "file" } },
    };
    var last: ?[]u8 = null;
    defer if (last) |p| gpa.free(p);
    for ([_]Style{ .text, .text_icons, .widget }) |style| {
        // Switched between frames, as `theme.set-chrome` does: the same
        // view, the next frame drawn in the new style.
        v.chrome = style;
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        var runs: std.ArrayList(Run) = .empty;
        var rects: std.ArrayList(Rect) = .empty;
        const s: Sink = .{ .v = &v, .scratch = arena.allocator(), .runs = &runs, .rects = &rects };
        var boxes: [cases.len + 2]region.Rect = undefined;
        for (cases, 0..) |c, i| {
            const y = 8 + @as(f32, @floatFromInt(i)) * (v.line_h + 6);
            boxes[i] = .{ .x = 8, .y = y, .w = if (c.role == .button) colsW(&v, buttonCols(&v, c.content)) else 220, .h = if (c.role == .separator) 3 else v.line_h };
            try paint(s, c.role, c.state, c.content, boxes[i]);
            // A segment's or chip's text is the status line's to place.
            if (c.role == .status_segment or c.role == .chip) try s.label("12:4", boxes[i].x, y, v.theme.foreground, null);
        }
        // A panel with a tooltip over it, beside the rows.
        boxes[cases.len] = .{ .x = 260, .y = 20, .w = 180, .h = 120 };
        try paintPanel(s, boxes[cases.len], v.theme.selection, v.theme.accent, .menu);
        try paintTooltip(s, .{ .label = "Close", .reason = "nothing to close" }, .{ 270, 150 }, .{ .x = 0, .y = 0, .w = @floatFromInt(w), .h = @floatFromInt(h) });
        boxes[cases.len + 1] = .{ .x = 270, .y = 150 + v.line_h, .w = 120, .h = v.line_h };
        var built = try render.render(&v, .identity, runs.items, rects.items, &.{});
        defer built.deinit(gpa);
        const pixels = try harness.rasterize(gpa, &v, &.{built.items}, w, h);
        for (boxes, 0..) |b, i| {
            errdefer std.debug.print("style {s}: box {d} empty\n", .{ style.name(), i });
            try testing.expect(harness.hasContent(pixels, w, @intFromFloat(b.x), @intFromFloat(b.y), @intFromFloat(b.x + b.w), @intFromFloat(b.y + @max(1, b.h))));
        }
        // Each style is its own look: no frame repeats the one before it.
        if (last) |prev| try testing.expect(!std.mem.eql(u8, prev, pixels));
        if (last) |prev| gpa.free(prev);
        last = pixels;
        // The widget style's shapes are the D2 primitives.
        var rounded = false;
        var paths = false;
        for (built.items) |item| switch (item) {
            .rrect => rounded = true,
            .path => paths = true,
            else => {},
        };
        try testing.expectEqual(style == .widget, rounded);
        try testing.expectEqual(style != .text, paths);
    }
}

test "chrome: a button's cells are the same in every style that draws the same parts" {
    const font_provider = @import("weft_font_provider");
    var v = try View.init(testing.allocator, font_provider.defaultMono(), 16);
    defer v.deinit();
    const save: Content = .{ .label = "Save", .icon = "save" };
    // The text style has no icons: the label and a cell either side, which
    // is what "[Save]" took, so a toolbar keeps its columns.
    v.chrome = .text;
    try testing.expectEqual(@as(usize, 6), buttonCols(&v, save));
    v.chrome = .text_icons;
    try testing.expectEqual(@as(usize, 8), buttonCols(&v, save));
    v.chrome = .widget;
    try testing.expectEqual(@as(usize, 8), buttonCols(&v, save));
    // No icon by that name: no icon cells.
    try testing.expectEqual(@as(usize, 6), buttonCols(&v, .{ .label = "Save", .icon = "no-such-icon" }));
    // `theme/icons none` turns every icon off.
    v.icons_on = false;
    try testing.expectEqual(@as(usize, 6), buttonCols(&v, save));
}

test "chrome: the style names are the theme slot's spelling, and cycle through all three" {
    try testing.expectEqual(Style.text_icons, Style.parse("text-icons").?);
    try testing.expect(Style.parse("text_icons") == null);
    var s: Style = .text;
    for (0..3) |_| {
        try testing.expectEqual(s, Style.parse(s.name()).?);
        s = s.next();
    }
    try testing.expectEqual(Style.text, s);
}
