//! View — editor state to renderer-neutral draw items.
//!
//! One layout model, two placements. Every visible line is laid out into
//! `Run`s and caret `Stop`s by a single primitive; the *same* stops feed
//! both the rendered picture and the source-offset ↔ geometry map (motion,
//! hit-testing, caret, selection). Plain buffers place each line on the
//! monospace cell grid (uniform advances — the degenerate case, pixel-crisp
//! via `CellSnap.grid`); markdown buffers place proportional runs at varying
//! faces and sizes. Caret and selection are explicit solid rectangles in the
//! same scene list as glyphs — no extra pipeline.
//!
//! The view is a pure subscriber: it reads the rope and the editor's
//! cursor/selection plus published style feeds (highlight, diagnostics, and
//! markdown), and owns only presentation state (scroll and metrics). Damage is
//! the caller's concern.
//!
//! The struct's satellites (Theme, Hud, CursorStyle, …) live in sibling
//! files and are re-exported by the package root `view.zig`; the extracted
//! render routines (statusline/popup/decoration/linelayout/render) are
//! free-function namespaces over `*View`.

const std = @import("std");
const Allocator = std.mem.Allocator;

const text_engine = @import("weft_text");
const font_provider = @import("weft_font_provider");
const scene = @import("weft_scene");
const stemma = @import("stemma");
const core = @import("weft_core");
const layout = @import("../layout.zig");
const region = @import("../region.zig");
const fonts = @import("../fonts.zig");
const icons = @import("../icons.zig");
const chrome_mod = @import("chrome.zig");
const statusline = @import("statusline.zig");
const popup = @import("popup.zig");
const semantic = @import("semantic.zig");
const decoration = @import("decoration.zig");
const linelayout = @import("linelayout.zig");
const grid_draw = @import("grid.zig");
const render = @import("render.zig");

const Theme = @import("Theme.zig");
const hud_mod = @import("hud.zig");
const Hud = hud_mod.Hud;

const font_id_mono = fonts.font_id_mono;
const margin: f32 = 8;
/// A pane's frame is its body inset by this on every side — what a row-sized
/// dock adds to its rows (`window_layout.Rows.inset` is twice it).
pub const pane_margin = margin;

const View = @This();

/// The finished frame: explicit draw items plus its body geometry.
pub const Built = struct {
    items: []scene.DrawItem,
    /// This build's BODY region (the frame after the tab/status/panel chrome
    /// is carved off) — the same rect `drawPick`/`drawHover` passed to
    /// `popup.drawCaretSurface`. Exposed so a caller (the popup-layout e2e
    /// gate) can re-derive a caret popup's layout from the SAME `body` the
    /// real frame used, instead of recomputing the chrome-carve formula and
    /// risking it drift out of step with `build`'s.
    body: region.Rect = .{},

    pub fn deinit(self: *Built, gpa: Allocator) void {
        gpa.free(self.items);
        self.* = undefined;
    }
};

/// A shaped glyph run to render, placed either on the mono cell grid
/// (uniform advances) or proportionally at a pen origin (markdown).
/// `pub` only so the extracted render/layout submodules can name it — it is
/// not part of the module's public surface (view.zig re-exports none of it).
pub const Run = struct {
    shaped: text_engine.ShapedText,
    baseline_y: f32,
    place: union(enum) {
        cell: []text_engine.Cell,
        prop: struct { x: f32, em: f32, color: [4]f32 },
    },
    /// Glyphs outside this box are not drawn — a chrome label that must not
    /// spill past its tab or menu. Null: unclipped, as every text run is.
    clip: ?region.Rect = null,
};

/// A box-shaped paint, in paint order with the other rects of its layer:
/// selection backgrounds, caret, peer carets, HUD row highlights — a sharp
/// filled rect, the default — and, for chrome (`chrome.zig`), a rounded or
/// outlined or blurred box, or a vector icon drawn into the box and tinted
/// `color`. One list, so a chrome style's pill, its icon and a highlight
/// over it keep the order they were appended in. `pub` for the extracted
/// submodules only (see `Run`).
pub const Rect = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    color: [4]f32,
    shape: Shape = .fill,

    pub const Shape = union(enum) {
        /// A sharp, pixel-crisp fill.
        fill,
        rounded: Rounded,
        /// The icon scaled into the box (its viewBox is square; the box
        /// should be too).
        icon: *const icons.Icon,
    };

    /// `scene.RRectItem`'s knobs: radius, an outline instead of a fill when
    /// `stroke_width > 0`, a soft edge when `blur > 0`.
    pub const Rounded = struct { radius: f32, stroke_width: f32 = 0, blur: f32 = 0 };
};

/// Where selection `i`'s caret draws under `place` (`hud.CaretPlace`): its
/// head, or — `inside`, on a forward selection — the start of the last
/// character it covers. An inclusive selection's caret is on that character
/// whatever the place (`Editor.Ends.caretIn`).
pub fn caretDrawOffset(ed: *const core.TextSnapshot, i: usize, place: hud_mod.CaretPlace) usize {
    const ends = ed.selectionEnds(i);
    if (ends.inclusive) return ends.caretIn(ed.text());
    if (place == .head or ends.head <= ends.anchor) return ends.head;
    const rope = ed.text();
    var off = ends.head - 1;
    while (off > ends.anchor and rope.byteAt(off) & 0xc0 == 0x80) off -= 1;
    return off;
}

gpa: Allocator,
face_set: fonts.FaceSet,
theme: Theme,
/// How chrome looks (`theme/chrome`, doc/chrome.md §3.2). Resolved from the
/// theme slot each frame (`resolveChrome`), so a rebind is the next frame's.
chrome: chrome_mod.Style = .text,
/// The bundled icon set, parsed once at init.
icon_set: icons.Set,
/// Whether the theme's icon set is the bundled one (`theme/icons`); `none`
/// turns every icon off, whatever the chrome style.
icons_on: bool = true,
/// The tooltip the current build's hovered element offers — due or not, so
/// what the pointer rests on is known before the frame that shows it.
build_tip: ?chrome_mod.Tip = null,
/// The frame's tooltip, whichever pane's element offered it, until the pane
/// that paints tooltips (`Hud.tooltips`) draws it — when it is `due`. Reset
/// with the frame; between frames, what the last one's pointer rested on
/// (`hoveredCommand`).
frame_tip: ?struct { tip: chrome_mod.Tip, at: [2]f32, due: bool } = null,
/// What the last frame's hovered element runs, owned past the frame's
/// arenas — `hoveredCommand`.
hovered_buf: [128]u8 = undefined,
hovered_len: usize = 0,

em: f32,
cell_w: f32,
line_h: f32,
ascent: f32,
top_row: usize = 0,

/// The most recent frame's source-offset ↔ geometry map, for
/// hit-testing, caret, selection, and vertical motion. Its `lines`
/// and stops live in `layout_arena`, rebuilt each `build()`; a click
/// between frames reads last frame's map (one-frame latency, unseen).
layout_arena: std.heap.ArenaAllocator,
frame_layout: layout.Layout = .{ .lines = &.{} },
/// Hit regions for the focused pane's semantic body or active interaction.
/// Like `frame_layout`, these live in `layout_arena` until the next frame.
semantic_hits: []const semantic.Hit = &.{},
semantic_active: bool = false,
/// The last `build`'s scene hit regions, active or not: an unfocused pane's
/// rows are clickable too. `recordPane` files them with the pane.
build_hits: []const semantic.Hit = &.{},
/// The last `build`'s CHROME hit regions — tab parts and status segments —
/// filed with the pane by `recordPane` like `build_hits`. Arena-backed.
build_chrome: []const hud_mod.ChromeHit = &.{},
/// The box the last `build`'s floating overlay drew in, which may reach past
/// the pane's own rect; `recordPane` files it with the pane.
build_float: ?region.Rect = null,
/// Every pane's hit geometry from the last frame, so the pointer can ask
/// what is under it in ANY pane, not only the focused one — a click in an
/// unfocused pane must land where it points. Arena-backed like
/// `frame_layout`; reset with it.
pane_maps: [max_pane_maps]PaneMap = undefined,
pane_map_count: usize = 0,
semantic_last_view: ?@import("weft_semantic").view.Ref = null,
semantic_last_node: ?@import("weft_semantic").scene.NodeId = null,
/// Where each open menu panel taller than the frame is scrolled to — a
/// pane's `top_row`, for the floating menu (`menu.Scroll`).
menu_scroll: @import("menu.zig").Scroll = .{},
/// The current build's content origin (its frame inset by `margin`) — a
/// pane renders into its own region, so layout and HUD baselines derive
/// from here rather than the whole framebuffer. Defaults to the
/// single-pane, frame-at-origin case.
origin_x: f32 = margin,
origin_y: f32 = margin,
/// The last build's body region height, for scroll commands (`bodyRows`).
body_h: f32 = 0,
/// Whether the active buffer is markdown (from the last build). Off-screen
/// vertical-motion goal-x uses this to shape rows with the proportional body
/// face at their heading scale, instead of the mono approximation.
md_active: bool = false,

pub fn init(gpa: Allocator, font_bytes: []const u8, em: f32) !View {
    var face_set = try fonts.FaceSet.init(gpa, font_bytes);
    errdefer face_set.deinit();
    const font = face_set.monoFont();

    const upem: f32 = @floatFromInt(font.unitsPerEm());
    const lm = try font.lineMetrics();
    const advance = try font.advanceWidth(try font.glyphIndex('M'));
    const ascent: f32 = @floatFromInt(lm.ascent);
    const descent: f32 = @floatFromInt(lm.descent);
    const gap: f32 = @floatFromInt(lm.line_gap);
    var icon_set = try icons.Set.parse(gpa, "lucide", &icons.lucide);
    errdefer icon_set.deinit();

    return .{
        .gpa = gpa,
        .face_set = face_set,
        .theme = (Theme{}).linearized(),
        .icon_set = icon_set,
        .em = em,
        .cell_w = em * @as(f32, @floatFromInt(advance)) / upem,
        .line_h = em * (ascent - descent + gap) / upem,
        .ascent = em * ascent / upem,
        .layout_arena = std.heap.ArenaAllocator.init(gpa),
    };
}

pub fn deinit(self: *View) void {
    self.layout_arena.deinit();
    self.icon_set.deinit();
    self.face_set.deinit();
    self.* = undefined;
}

/// The icon `name`, when the chrome style draws icons and the theme's set
/// has one by that name; null otherwise, and the style draws text alone.
pub fn icon(self: *const View, name: []const u8) ?*const icons.Icon {
    if (!self.icons_on or !self.chrome.showsIcons()) return null;
    return self.icon_set.get(name);
}

/// The slots a chrome style and icon set are chosen through: `theme/chrome`
/// (`text`, `text-icons`, `widget`) and `theme/icons` (`lucide`, `none`).
/// Value-shaped and first-wins, like every `theme/<leaf>`; the view declares
/// them because the view is what reads them.
pub const chrome_slot = "theme/chrome";
pub const icons_slot = "theme/icons";

pub fn declareChromeSlots(container: *core.container.Container) !void {
    try container.declareSlot(.{ .name = chrome_slot, .shape = .value, .composition = .first_wins });
    try container.declareSlot(.{ .name = icons_slot, .shape = .value, .composition = .first_wins });
}

/// Read the chrome style and icon set from their slots. Called at the top of
/// every frame, so whatever last bound `theme/chrome` — a config, a theme,
/// `theme.set-chrome` — is what the frame draws. An unbound or misspelt
/// value leaves the style as it was: a typo must not restyle the editor.
pub fn resolveChrome(self: *View, container: *const core.container.Container, facts: core.facts.Facts) void {
    if (slotValue(container, facts, chrome_slot)) |name| {
        if (chrome_mod.Style.parse(name)) |style| self.chrome = style;
    }
    if (slotValue(container, facts, icons_slot)) |name| self.icons_on = !std.mem.eql(u8, name, "none");
}

fn slotValue(container: *const core.container.Container, facts: core.facts.Facts, slot: []const u8) ?[]const u8 {
    const winner = container.resolveOne(slot, facts) orelse return null;
    return switch (winner.provider) {
        .value => |v| v,
        else => null,
    };
}

/// Change the text scale and every metric derived from it together. The next
/// frame rebuilds the geometry map used for drawing and hit testing.
pub fn setEm(self: *View, em: f32) void {
    const scale = em / self.em;
    self.em = em;
    self.cell_w *= scale;
    self.line_h *= scale;
    self.ascent *= scale;
}

/// Rows that fit in a rect of pixel height `h` (its usable body height).
pub fn rowsIn(self: *const View, h: f32) usize {
    return @intFromFloat(@max(1, @floor((h - 2 * margin) / self.line_h)));
}

/// What the element the pointer rested on in the last frame runs ("" for
/// nothing, or an element that runs nothing) — what the shell looks a
/// tooltip's key hint up by when the pointer settles, before the frame
/// that shows the tooltip is built (doc/model.md §2.7).
pub fn hoveredCommand(self: *const View) []const u8 {
    return self.hovered_buf[0..self.hovered_len];
}

pub fn colsIn(self: *const View, w: f32) usize {
    return @intFromFloat(@max(1, @floor((w - 2 * margin) / self.cell_w)));
}

/// Rows in the focused pane's body (for the scroll commands, which run
/// between frames and read the last build's body region).
pub fn bodyRows(self: *const View) usize {
    return @intFromFloat(@max(1, @floor(self.body_h / self.line_h)));
}

fn rowMetrics(self: *const View, baseline_y: f32) layout.RowMetrics {
    return self.rowMetricsEm(self.em, baseline_y);
}
fn rowMetricsEm(self: *const View, em: f32, baseline_y: f32) layout.RowMetrics {
    return .{
        .em = em,
        .margin = self.origin_x,
        .baseline_y = baseline_y,
        .ascent = self.ascent,
        .descent = self.line_h - self.ascent,
        .height = self.line_h,
    };
}

/// The heading em-scale of a row, from its leading `#`s (matching
/// `inlineStyle`), or 1.0 for a non-heading. Used to shape an OFF-SCREEN
/// markdown row at the right size without the published per-byte styling.
fn headingScale(self: *const View, rope: *const stemma.Rope, row: usize) f32 {
    _ = self;
    const line = rope.lineRange(row);
    var buf: [8]u8 = undefined;
    const n = @min(line.len(), buf.len);
    if (n == 0) return 1.0;
    var sr = rope.streamReader(.{ .start = line.start, .end = line.start + n }, &.{});
    sr.interface.readSliceAll(buf[0..n]) catch return 1.0;
    var h: usize = 0;
    while (h < n and buf[h] == '#') h += 1;
    if (h == 0 or h > 6) return 1.0;
    if (h < n and buf[h] != ' ') return 1.0; // `#foo` is not a heading
    return switch (h) {
        1 => 2.0,
        2 => 1.6,
        3 => 1.3,
        4 => 1.15,
        else => 1.05,
    };
}

/// Build stops for an OFF-SCREEN row (not in the frame map). For markdown,
/// shape with the proportional body face at the row's heading scale — so
/// vertical motion into an off-screen heading/paragraph lands at the right
/// column, not the mono approximation. Plain buffers use the mono grid.
fn offRowStops(self: *View, la: Allocator, rope: *const stemma.Rope, row: usize) !layout.VisualLine {
    if (self.md_active) {
        const em = self.em * self.headingScale(rope, row);
        return layout.buildRowStops(la, &self.face_set.body, rope, row, self.rowMetricsEm(em, 0));
    }
    return layout.buildRowStops(la, &self.face_set.mono, rope, row, self.rowMetrics(0));
}

/// World-x of the caret at `off`. Prefers the frame's real geometry
/// (markdown-aware) when the row is visible; else re-shapes it as mono.
/// The goal-x seam for interactive vertical motion.
pub fn xOfOffsetOnRow(self: *View, rope: *const stemma.Rope, off: usize) !f32 {
    const row = rope.offsetToPoint(off).row;
    for (self.frame_layout.lines) |*l| if (l.row == row) return l.xAt(off);
    var arena = std.heap.ArenaAllocator.init(self.gpa);
    defer arena.deinit();
    const line = try self.offRowStops(arena.allocator(), rope, row);
    return line.xAt(off);
}

/// Source offset nearest world-x `goal_x` on `row` — the target of a
/// visual up/down step. Uses the frame map when the row is visible.
pub fn xToOffsetOnRow(self: *View, rope: *const stemma.Rope, row: usize, goal_x: f32) !usize {
    for (self.frame_layout.lines) |*l| if (l.row == row) return l.offsetAt(goal_x);
    var arena = std.heap.ArenaAllocator.init(self.gpa);
    defer arena.deinit();
    const line = try self.offRowStops(arena.allocator(), rope, row);
    return line.offsetAt(goal_x);
}

/// Source offset under a framebuffer-space point (a click). Reads the
/// last frame's map — the geometry seam for click-to-place.
pub fn offsetAtPoint(self: *const View, x: f32, y: f32) usize {
    return self.frame_layout.offsetAtPoint(x, y);
}

/// Scroll a pane by whole rows (wheel). Clamped to the document next
/// `build()`.
pub fn scrollBy(top_row: *usize, delta_rows: i32) void {
    if (delta_rows < 0)
        top_row.* -|= @intCast(-delta_rows)
    else
        top_row.* += @intCast(delta_rows);
}

/// Reset the per-frame layout arena. With split panes the caller resets
/// once, then builds each pane (their geometry maps coexist in it).
pub fn resetFrame(self: *View) void {
    _ = self.layout_arena.reset(.retain_capacity);
    self.semantic_hits = &.{};
    self.semantic_active = false;
    self.build_hits = &.{};
    self.build_chrome = &.{};
    self.frame_tip = null;
    self.hovered_len = 0;
    self.pane_map_count = 0;
}

pub const max_pane_maps = 64;

/// One pane's hit geometry as last built: its rect, its text layout (empty
/// for a scene), and its scene hit regions (empty for text).
pub const PaneMap = struct {
    pane: u32,
    rect: region.Rect,
    lines: layout.Layout,
    hits: []const semantic.Hit,
    /// The pane's chrome regions (tab parts, status segments). A point on
    /// one of these is on the chrome, not on the text or scene beneath.
    chrome: []const hud_mod.ChromeHit = &.{},
    /// The pane's floating overlay box (a menu), wherever it lies in the
    /// frame. A point inside it is the pane's, whichever pane is beneath.
    float: ?region.Rect = null,

    /// The chrome region (a tab part, a status segment) under (x, y).
    pub fn chromeAt(self: *const PaneMap, x: f32, y: f32) ?hud_mod.ChromeHit {
        for (self.chrome) |c| if (c.rect.contains(x, y)) return c;
        return null;
    }

    /// The byte offset under (x, y), or null when the pane shows no text.
    pub fn offsetAt(self: *const PaneMap, x: f32, y: f32) ?usize {
        if (self.lines.lines.len == 0 or self.hits.len != 0) return null;
        return self.lines.offsetAtPoint(x, y);
    }

    /// The topmost scene hit region under (x, y).
    pub fn hitAt(self: *const PaneMap, x: f32, y: f32) ?semantic.Hit {
        var index = self.hits.len;
        while (index > 0) {
            index -= 1;
            if (self.hits[index].rect.contains(x, y)) return self.hits[index];
        }
        return null;
    }
};

/// File the geometry the last `build` produced under `pane`, drawn into
/// `rect`. Called once per pane per frame, right after its build.
pub fn recordPane(self: *View, pane: u32, rect: region.Rect) void {
    if (self.pane_map_count >= max_pane_maps) return;
    self.pane_maps[self.pane_map_count] = .{
        .pane = pane,
        .rect = rect,
        .lines = self.frame_layout,
        .hits = self.build_hits,
        .chrome = self.build_chrome,
        .float = self.build_float,
    };
    self.pane_map_count += 1;
}

/// `cols` cells starting at column `col` of the row whose top is `y`.
pub fn cellsRect(self: *const View, y: f32, col: usize, cols: usize) region.Rect {
    return .{
        .x = self.origin_x + @as(f32, @floatFromInt(col)) * self.cell_w,
        .y = y,
        .w = @as(f32, @floatFromInt(cols)) * self.cell_w,
        .h = self.line_h,
    };
}

/// `r` cut to what lies inside `bounds` (empty, at `r`'s corner, when they
/// do not meet).
fn clipTo(r: region.Rect, bounds: region.Rect) region.Rect {
    const x0 = @max(r.x, bounds.x);
    const y0 = @max(r.y, bounds.y);
    const x1 = @min(r.x + r.w, bounds.x + bounds.w);
    const y1 = @min(r.y + r.h, bounds.y + bounds.h);
    return .{ .x = x0, .y = y0, .w = @max(0, x1 - x0), .h = @max(0, y1 - y0) };
}

/// The pane under (x, y): the one whose floating overlay covers the point
/// (it paints on top), else the one whose last-built rect contains it.
pub fn paneAtPoint(self: *const View, x: f32, y: f32) ?*const PaneMap {
    for (self.pane_maps[0..self.pane_map_count]) |*m| if (m.float) |f| if (f.contains(x, y)) return m;
    for (self.pane_maps[0..self.pane_map_count]) |*m| if (m.rect.contains(x, y)) return m;
    return null;
}

pub fn semanticHitAtPoint(self: *const View, x: f32, y: f32) ?semantic.Hit {
    var index = self.semantic_hits.len;
    while (index > 0) {
        index -= 1;
        const hit = self.semantic_hits[index];
        if (hit.rect.contains(x, y)) return hit;
    }
    return null;
}

pub fn hasSemanticInput(self: *const View) bool {
    return self.semantic_active;
}

/// Keep the cursor's row inside a pane's body viewport.
fn scrollToCursor(editor: *const core.TextSnapshot, top_row: *usize, body_rows: usize) void {
    const cur = editor.text().offsetToPoint(editor.cursorOffset()).row;
    if (cur < top_row.*) top_row.* = cur;
    if (cur >= top_row.* + body_rows) top_row.* = cur + 1 - body_rows;
}

/// The scroll a text body settles on: the caret kept in view, the top row
/// clamped to the document. The one place `build` moves `top_row`.
fn settleRows(editor: *const core.TextSnapshot, top_row: *usize, body_rows: usize) void {
    scrollToCursor(editor, top_row, body_rows);
    const total_rows = editor.text().lineCount();
    if (top_row.* >= total_rows) top_row.* = total_rows -| 1;
}

/// A pane's frame carved into regions (no element computes an offset against
/// another). The status line is cut off the FRAME, edge to edge, before any
/// inset: it is the pane's own bottom row, flush with its sides, never a bar
/// floating inside the margin (doc/chrome.md §4.2). Content is what remains,
/// inset by `margin`; a top tab strip and the panel above the status line
/// are cut off it, and the body is the rest.
const Regions = struct {
    content: region.Rect,
    tab: ?region.Rect,
    status: region.Rect,
    panel: region.Rect,
    body: region.Rect,
};

fn carve(self: *const View, frame: region.Rect, hud: Hud) Regions {
    // A pane that declares no status line (a one-row strip) gives the row
    // to its body.
    const status_cut = frame.cutBottom(if (hud.status_line) self.line_h else 0);
    const rest = status_cut.rest;
    // A pane that is only its status line has no body to inset: its content
    // is empty, never negative.
    const content: region.Rect = .{
        .x = rest.x + margin,
        .y = rest.y + margin,
        .w = @max(0, rest.w - 2 * margin),
        .h = @max(0, rest.h - 2 * margin),
    };
    var stack = content;
    var tab: ?region.Rect = null;
    if (hud.tabs != null) {
        const c = stack.cutTop(self.line_h);
        tab = c.strip;
        stack = c.rest;
    }
    const panel_cut = stack.cutBottom(@as(f32, @floatFromInt(hud.panelRows())) * self.line_h);
    return .{ .content = content, .tab = tab, .status = status_cut.strip, .panel = panel_cut.strip, .body = panel_cut.rest };
}

fn bodyRowsOf(self: *const View, body: region.Rect) usize {
    return @intFromFloat(@max(1, @floor(body.h / self.line_h)));
}

/// Move `top_row` to where `build` will put it for `editor` in `frame` under
/// `hud` — before any row is laid out. `build` runs exactly this itself, so
/// calling it first changes nothing about the frame; what it buys a caller is
/// knowing the scroll BEFORE the build, which is when per-row inputs (the
/// highlight paint window, markdown attributes) have to be prepared. Preparing
/// them around the pre-scroll `top_row` instead is how a jump used to draw
/// its first frame at the destination with no highlighting at all.
pub fn settleScroll(self: *const View, editor: *const core.TextSnapshot, hud: Hud, top_row: *usize, frame: region.Rect) void {
    if (hud.semantic_view != null) return;
    settleRows(editor, top_row, self.bodyRowsIn(hud, frame));
}

/// How many text rows a pane's body shows in `frame` under `hud` — what its
/// per-byte inputs have to cover (`core.TextSnapshot.window`).
pub fn bodyRowsIn(self: *const View, hud: Hud, frame: region.Rect) usize {
    return self.bodyRowsOf(self.carve(frame, hud).body);
}

/// The room a pane's body has in `frame` under `hud`, in whole cells, and
/// the cell's size in pixels — what an entry sized to its pane (a
/// terminal's grid) is told (`Buffer.extent`).
pub fn extentIn(self: *const View, hud: Hud, frame: region.Rect) core.grid.Extent {
    const body = self.carve(frame, hud).body;
    const cols: usize = @intFromFloat(@max(1, @floor(body.w / self.cell_w)));
    return .{
        .cols = @intCast(@min(cols, std.math.maxInt(u16))),
        .rows = @intCast(@min(self.bodyRowsOf(body), std.math.maxInt(u16))),
        .cell_w = @intFromFloat(@min(@round(self.cell_w), std.math.maxInt(u16))),
        .cell_h = @intFromFloat(@min(@round(self.line_h), std.math.maxInt(u16))),
    };
}

// ── Frame assembly ───────────────────────────────────────────────

/// Build the visible picture: lay out each body row into runs + the
/// geometry map, derive decoration rects (selection, caret, peers)
/// from that map, add the HUD, then place everything into shapes.
/// A null `editor` is an entry that holds no text: the body is the HUD's
/// semantic view (or nothing), with no rope and no caret.
///
/// Everything this reads is the frame's input (doc/model.md §2.7): the text
/// is a `core.TextSnapshot` and every layer on `hud` a `layers.Snapshot`,
/// never a live `Editor` or `Layer`. So building twice from the same input
/// draws the same picture, and nothing that edits while — or after — this
/// runs can put one version's carets on another version's text.
pub fn build(
    self: *View,
    scratch: Allocator,
    editor: ?*const core.TextSnapshot,
    hud: Hud,
    top_row: *usize,
    frame: region.Rect,
    pick_dock: region.Rect,
    world_to_pixel: scene.Transform2D,
) !Built {
    self.build_hits = &.{};
    self.build_chrome = &.{};
    self.build_tip = null;
    const regions = self.carve(frame, hud);
    const content = regions.content;
    self.origin_x = content.x;
    self.origin_y = content.y;
    const cols_visible: usize = @intFromFloat(@max(1, @floor(content.w / self.cell_w)));
    const tab_rect = regions.tab;
    const status_rect = regions.status;
    const panel_rect = regions.panel;
    const body_rect = regions.body;
    self.body_h = body_rect.h;
    self.md_active = hud.semantic_view == null and hud.md_inline != null;

    const rows_visible = self.bodyRowsOf(body_rect);
    const cursor_off = if (editor) |ed| caretDrawOffset(ed, ed.primary, hud.caret_place) else 0;

    var runs: std.ArrayList(Run) = .empty;
    defer {
        for (runs.items) |*r| r.shaped.deinit();
        runs.deinit(scratch);
    }
    var rects: std.ArrayList(Rect) = .empty;
    defer rects.deinit(scratch);

    if (hud.semantic_view) |document| {
        // Tool views subscribe to semantic nodes directly. Clearing the text
        // geometry map prevents stale document hit-testing from leaking into
        // a pane whose visible identity/focus is node-based.
        self.frame_layout = .{ .lines = &.{} };
        var document_body = body_rect;
        if (hud.brand_mark) {
            if (dashboardMarkSize(self, body_rect)) |size| {
                const reserved = size + self.line_h;
                document_body.y += reserved;
                document_body.h = @max(0, document_body.h - reserved);
            }
            // Keep the dashboard at a readable measure in characters. A
            // fixed pixel cap made the viewport progressively narrower as
            // the user increased the font size, truncating ordinary paths.
            const width = @min(document_body.w, self.cell_w * 72);
            document_body.x += (document_body.w - width) / 2;
            document_body.w = width;
        }
        const hits = try semantic.drawDocument(self, scratch, self.layout_arena.allocator(), &runs, &rects, document, hud, document_body, top_row);
        self.build_hits = hits;
        if (document.active) {
            self.semantic_active = true;
            self.semantic_hits = hits;
        }
    } else if (hud.grid) |*g| {
        if (g.reading and editor != null) {
            // A grid READ as text: its cells drawn as ever, over the rows its
            // document's scroll shows, with the document's geometry — so the
            // caret, the selections and a flash are drawn on the cells, and
            // a click or a drag lands on the cell under it.
            const ed = editor.?;
            settleRows(ed, top_row, rows_visible);
            const la = self.layout_arena.allocator();
            self.frame_layout = .{ .lines = try grid_draw.layoutRows(self, la, ed.text(), g, body_rect) };
            var washes: std.ArrayList(Rect) = .empty;
            defer washes.deinit(scratch);
            for (0..ed.selectionCount()) |i| {
                if (ed.selectionRange(i)) |r| try decoration.selectionRects(self, scratch, &washes, r, self.theme.selection);
            }
            for (hud.flash) |fl| try decoration.selectionRects(self, scratch, &washes, fl, self.theme.accent);
            // The document's caret is the cursor drawn: at its cell, in the
            // shape the grammar's mode asks for.
            var shown = g.*;
            if (!hud.row_focus) if (self.frame_layout.pointAtOffset(cursor_off)) |c| {
                const row = self.frame_layout.lineForOffset(cursor_off).?;
                shown.cursor = .{
                    .x = @intFromFloat(@max(0, @round((c.x - self.origin_x) / self.cell_w))),
                    .y = @intCast(row),
                    .shape = switch (hud.cursor_style) {
                        .block => .block,
                        .bar => .bar,
                        .underline => .underline,
                    },
                    .visible = true,
                };
            };
            try grid_draw.draw(self, scratch, &runs, &rects, &shown, body_rect, hud.cursor_on, washes.items);
        } else {
            // A grid entry (a terminal) taking its input: the live screen —
            // no geometry map, and the cursor is the grid's own.
            self.frame_layout = .{ .lines = &.{} };
            try grid_draw.draw(self, scratch, &runs, &rects, g, body_rect, hud.cursor_on, &.{});
        }
    } else if (editor) |ed| {
        const rope = ed.text();
        const total_rows = rope.lineCount();
        settleRows(ed, top_row, rows_visible);
        const styles = try linelayout.resolveStyleInputs(scratch, hud, rope, top_row.*, rows_visible, total_rows);
        // Every block caret flips the glyph it covers, not only the primary's.
        var flips: std.ArrayList(usize) = .empty;
        if (hud.cursor_on and hud.cursor_style == .block and !hud.row_focus) for (0..ed.selectionCount()) |i|
            try flips.append(scratch, caretDrawOffset(ed, i, hud.caret_place));

        // Lay out the body's visible rows into the frame arena (the geometry
        // map outlives the frame for hit-testing). The caller resets the
        // arena once per frame (resetFrame) so split panes' maps coexist.
        const la = self.layout_arena.allocator();
        var lines: std.ArrayList(layout.VisualLine) = .empty;
        var y_top: f32 = body_rect.y;
        const body_limit_y = body_rect.y + body_rect.h;
        var row = top_row.*;
        var shown: usize = 0;
        while (row < total_rows and shown < rows_visible and y_top < body_limit_y) : (row += 1) {
            if (ed.rowHidden(row)) continue;
            const runs_mark = runs.items.len;
            const vl = try linelayout.layoutLine(self, scratch, la, &runs, rope, row, y_top, cols_visible, hud.md_inline, styles, flips.items);
            if (shown != 0 and y_top + vl.height > body_limit_y) {
                runs.items.len = runs_mark;
                break;
            }
            try lines.append(la, vl);
            y_top += vl.height;
            shown += 1;
        }
        self.frame_layout = .{ .lines = try lines.toOwnedSlice(la) };

        // A focus that is a ROW (doc/chrome.md §5.2) wears the wash a scene's
        // focused row does, beneath any selection, and draws no caret.
        if (hud.row_focus) {
            var wash = self.theme.background;
            for (0..3) |i| wash[i] = wash[i] * 0.8 + self.theme.selection[i] * 0.2;
            try decoration.rowRect(self, scratch, &rects, cursor_off, body_rect.x, body_rect.w, wash);
        }
        // Every selection draws, the primary like any other: one wash per
        // selection and one caret per head (the single-selection case is the
        // one-iteration loop of what this always drew).
        for (0..ed.selectionCount()) |i| {
            if (ed.selectionRange(i)) |r| try decoration.selectionRects(self, scratch, &rects, r, self.theme.selection);
        }
        for (hud.flash) |fl| try decoration.selectionRects(self, scratch, &rects, fl, self.theme.accent);
        if (hud.cursor_on and !hud.row_focus) {
            try decoration.caretRect(self, scratch, &rects, cursor_off, hud.cursor_style, self.theme.cursor);
            for (0..ed.selectionCount()) |i| {
                if (i == ed.primary) continue;
                try decoration.caretRect(self, scratch, &rects, caretDrawOffset(ed, i, hud.caret_place), hud.cursor_style, self.theme.cursor);
            }
        }
        if (hud.presence_layer) |pl| {
            for (0..pl.spanCount()) |i| {
                const span = pl.resolvedSpan(i);
                const hue = @as(f32, @floatFromInt(span.kind & 0xffff)) / 65535.0;
                if (span.end > span.start) {
                    try decoration.selectionRects(self, scratch, &rects, .{ .start = span.start, .end = span.end }, decoration.peerColor(hue, 0.55, 0.28));
                }
                const head = if (span.kind & 0x10000 == 0) span.start else span.end;
                try decoration.caretRect(self, scratch, &rects, head, .bar, decoration.peerColor(hue, 0.62, 1.0));
            }
        }
    } else {
        // Neither text nor a view to present: an empty body. Clear the
        // geometry map rather than leave last frame's lines pointing into the
        // arena `resetFrame` just reclaimed.
        self.frame_layout = .{ .lines = &.{} };
    }

    // Chrome hit regions, filed with the pane (`recordPane`) so a click on
    // a tab or a status segment resolves to WHAT it is on, not to the text
    // under the strip. Arena-backed like the geometry map.
    var chrome: std.ArrayList(hud_mod.ChromeHit) = .empty;
    const chrome_gpa = self.layout_arena.allocator();

    const sink: chrome_mod.Sink = .{ .v = self, .scratch = scratch, .runs = &runs, .rects = &rects };

    // Top buffer-tab strip, into its own region: each tab a `tab` role,
    // laid out and painted by the chrome style.
    if (hud.tabs) |tabs| {
        const strip = tab_rect.?;
        for (try chrome_mod.layoutTabs(self, scratch, tabs, strip)) |tb| {
            const tab = tabs[tb.index];
            const box = clipTo(tb.box, strip);
            const close = clipTo(tb.close, strip);
            const on_close = hud.pointer.onChrome(.tab, tb.index, .close);
            const state: chrome_mod.State = .{
                .selected = tab.active,
                .hover = on_close or hud.pointer.onChrome(.tab, tb.index, .body),
                .pressed = hud.pointer.pressed and hud.pointer.onChrome(.tab, tb.index, .body),
            };
            try chrome_mod.paintTab(sink, state, .{ .label = tab.name, .icon = chrome_mod.tabIconName(tab) }, box, if (close.w > 0) close else null, on_close);
            if (state.hover) self.build_tip = .{ .label = if (on_close) "Close" else if (tab.path.len > 0) tab.path else tab.name };
            if (box.w <= 0) continue;
            // The body is the tab less its close glyph, so the two parts'
            // hit regions never overlap. A COMMAND tab carries its command
            // here, the same door a status segment's click runs through
            // (`core.pointer.clickChrome`); it has no close sub-region (see
            // `layoutTabs`), so only the body hit is ever recorded for one.
            try chrome.append(chrome_gpa, .{ .rect = .{ .x = box.x, .y = box.y, .w = @max(0, @min(box.w, close.x - box.x)), .h = box.h }, .kind = .tab, .index = tb.index, .part = .body, .entry = tab.id, .command = tab.command, .shows_here = tab.shows_here });
            if (close.w > 0) try chrome.append(chrome_gpa, .{ .rect = close, .kind = .tab, .index = tb.index, .part = .close, .entry = tab.id });
        }
    }

    if (hud.status_line) try statusline.buildHud(self, scratch, &runs, &rects, hud, status_rect, panel_rect, cols_visible, .{ .list = &chrome, .gpa = chrome_gpa, .of = hud.status_of });
    self.build_chrome = chrome.items;
    self.build_float = null;

    // Thin pane dividers: a 1px line on each internal (shared) edge of
    // the pane's frame. Drawn on the frame boundary — outside the
    // `content` inset — so it never touches a glyph. A `separator`: the
    // chrome style picks its colour (the dim status grey under the text
    // styles, like the very slight lines between vim splits).
    {
        const bd = hud.pane_border;
        const th: f32 = 1;
        if (bd.left) try chrome_mod.paintSeparator(sink, .{ .x = frame.x, .y = frame.y, .w = th, .h = frame.h }, .vertical);
        if (bd.right) try chrome_mod.paintSeparator(sink, .{ .x = frame.x + frame.w - th, .y = frame.y, .w = th, .h = frame.h }, .vertical);
        if (bd.top) try chrome_mod.paintSeparator(sink, .{ .x = frame.x, .y = frame.y, .w = frame.w, .h = th }, .horizontal);
        if (bd.bottom) try chrome_mod.paintSeparator(sink, .{ .x = frame.x, .y = frame.y + frame.h - th, .w = frame.w, .h = th }, .horizontal);
    }

    // Everything from here on floats: it paints after the pane's text, so
    // a popup's own fill hides what is beneath it.
    const float: render.Layers = .{ .rects = rects.items.len, .runs = runs.items.len };
    // Floating surfaces (which-key popup, files/git, a guest's caret
    // popup like the `lsp` plugin's hover) float within the BODY region —
    // never over the status/tab/panel rects, which are carved out. Hand the
    // caret's y so a corner surface can flip away from it, and the carved
    // window-bottom `pick_dock` for any `.bottom`-placed surface.
    const caret_y: ?f32 = if (self.frame_layout.lineForOffset(cursor_off)) |li|
        self.frame_layout.lines[li].caretAt(cursor_off).y_top
    else
        null;
    try popup.drawSurfaces(self, scratch, &runs, &rects, hud, body_rect, pick_dock, caret_y);
    // Rendering P2 (doc/rendering.md): in PRODUCTION `hud.pick`/`hud.hover`
    // are null — `frame_builder.zig` builds the picker's own `.caret`/
    // `.bottom` Surface and hands it through `hud.surfaces` above instead
    // (the same door a plugin's surface uses), and the live hover popup is
    // the `lsp` plugin's own surface (also through `hud.surfaces`). These
    // two fields stay as a LEGACY/test-only path for callers that still
    // build a `Hud` by hand without going through `frame_builder`
    // (`gfx/harness.zig`, the e2e harness's best-effort `.snapshot`, and the
    // popup-layout gate's own scenarios) — this view never special-cases
    // "completion" or "hover" itself, only "a caret/dock surface".
    if (hud.pick) |p| {
        if (p.buildSurface(scratch, Hud.max_pick_rows, .dock)) |surf| {
            if (surf.placement == .caret)
                try popup.drawCaretSurface(self, scratch, &runs, &rects, &surf, body_rect)
            else
                try popup.drawDockSurface(self, scratch, &runs, &rects, &surf, pick_dock);
        }
    }
    if (hud.hover) |hv| {
        if (popup.textCaretSurface(scratch, hv.text, hv.offset, Hud.max_hover_rows)) |surf|
            try popup.drawCaretSurface(self, scratch, &runs, &rects, &surf, body_rect);
    }
    // A dialog is the active head-local interaction and therefore paints
    // above passive/legacy surfaces. Its keys still route through the
    // interaction stack, not through an editor mode or which-key. One hung
    // at a point floats in `float_bounds` (the frame), over other panes; the
    // pane is built last, so it paints over them too.
    if (hud.semantic_overlay) |overlay| {
        self.semantic_active = true;
        const caret_at: ?[2]f32 = if (self.frame_layout.lineForOffset(cursor_off)) |li| blk: {
            const c = self.frame_layout.lines[li].caretAt(cursor_off);
            break :blk .{ c.x, c.y_top + c.height };
        } else null;
        const drawn = try semantic.drawOverlay(self, scratch, self.layout_arena.allocator(), &runs, &rects, overlay, hud, body_rect, hud.float_bounds orelse body_rect, caret_at);
        self.semantic_hits = drawn.hits;
        self.build_float = drawn.box;
        // The dialog is on top: it is what a click on this pane reaches.
        self.build_hits = self.semantic_hits;
    }

    // A tooltip is the topmost thing a FRAME draws — its own layer, so no
    // popup's text beneath it shows through its box, painted by the pane that
    // paints last (`Hud.tooltips`), so a toolbar button's tooltip hangs over
    // the editor below it instead of being clipped to the strip. Only the
    // element the pointer rests on offers one, once the delay has passed
    // (`Hud.pointer`). Its key hint is frame input (`Hud.key_hint`), found by
    // the shell when the pointer settled — a build asks nothing.
    if (self.build_tip) |tip| if (hud.pointer.at) |at| {
        self.frame_tip = .{ .tip = tip, .at = at, .due = hud.pointer.tooltip };
        const n = @min(tip.command.len, self.hovered_buf.len);
        @memcpy(self.hovered_buf[0..n], tip.command[0..n]);
        self.hovered_len = if (n == tip.command.len) n else 0;
    };
    const top: render.Layers = .{ .rects = rects.items.len, .runs = runs.items.len };
    if (hud.tooltips) if (self.frame_tip) |ft| if (ft.due) {
        var shown = ft.tip;
        if (shown.key_hint.len == 0) shown.key_hint = hud.key_hint.of(shown.command);
        try chrome_mod.paintTooltip(sink, shown, ft.at, hud.float_bounds orelse frame);
    };

    var built = try render.render(self, world_to_pixel, runs.items, rects.items, &.{ float, top });
    if (hud.brand_mark) if (dashboardMarkSize(self, body_rect)) |size| {
        const first = built.items.len;
        built.items = try self.gpa.realloc(built.items, first + 2);
        const x = body_rect.x + (body_rect.w - size) / 2;
        const y = body_rect.y + 12;
        const scale = size / 256;
        built.items[first] = .{ .path = .{
            .commands = &dashboard_line,
            .x = x,
            .y = y,
            .scale = scale,
            .stroke_width = 13,
            .color = self.theme.foreground,
            .cap = .square,
            .join = .round,
        } };
        built.items[first + 1] = .{ .path = .{
            .commands = &dashboard_caret,
            .x = body_rect.x + (body_rect.w - size) / 2,
            .y = body_rect.y + 12,
            .scale = scale,
            .stroke_width = 8,
            .color = self.theme.diag_error,
            .cap = .square,
        } };
    };
    built.body = body_rect;
    return built;
}

fn dashboardMarkSize(self: *const View, body: region.Rect) ?f32 {
    if (body.w < 260 or body.h < 220) return null;
    return @min(210, @min(body.w * 0.42, @min(body.h * 0.45, self.line_h * 11)));
}

const dashboard_line = [_]scene.PathCommand{
    pathMove(46, 68),
    pathLine(175, 68),
    pathCubic(198, 68, 209, 79, 209, 101),
    pathCubic(209, 123, 198, 134, 175, 134),
    pathLine(80, 134),
    pathCubic(57, 134, 46, 145, 46, 166),
    pathCubic(46, 187, 57, 198, 80, 198),
    pathLine(152, 198),
};

const dashboard_caret = [_]scene.PathCommand{
    pathMove(176, 163), pathLine(176, 223),
    pathMove(164, 163), pathLine(188, 163),
    pathMove(164, 223), pathLine(188, 223),
};

fn pathMove(x: f32, y: f32) scene.PathCommand {
    return .{ .verb = .move, .points = .{ x, y, 0, 0, 0, 0 } };
}

fn pathLine(x: f32, y: f32) scene.PathCommand {
    return .{ .verb = .line, .points = .{ x, y, 0, 0, 0, 0 } };
}

fn pathCubic(x1: f32, y1: f32, x2: f32, y2: f32, x3: f32, y3: f32) scene.PathCommand {
    return .{ .verb = .cubic, .points = .{ x1, y1, x2, y2, x3, y3 } };
}

// ── HUD (status line + picker; always mono) ──────────────────────

/// Pixel height the picker dock needs: the query line + one row per shown
/// result. The SINGLE source of truth for both the dock carve (main cuts
/// exactly this off the window) and the render, so they cannot drift — the
/// same discipline `panelRows` uses. Zero when no pick is open.
pub fn pickDockHeight(self: *const View, pick: ?*const core.Pick) f32 {
    const p = pick orelse return 0;
    if (p.caret_anchor != null) return 0; // a caret popup (completion), not a dock
    const shown = @min(p.filtered.items.len, Hud.max_pick_rows);
    return @as(f32, @floatFromInt(1 + shown)) * self.line_h;
}

/// Pixel height the window-bottom dock needs: the picker's (`pickDockHeight`)
/// or the tallest active `.bottom`-placed surface a plugin published (a find
/// bar), whichever is taller. Both draw into the one dock, so both size it —
/// counting only the picker left a plugin's bottom surface drawing into a
/// zero-height strip, which is to say not at all.
pub fn dockHeight(self: *const View, pick: ?*const core.Pick, surfaces: []const *const core.surface.Surface) f32 {
    var rows: usize = 0;
    for (surfaces) |surf| {
        if (surf.active and surf.placement == .bottom) rows = @max(rows, surf.rows.items.len);
    }
    const surface_h = @as(f32, @floatFromInt(@min(rows, Hud.max_pick_rows + 1))) * self.line_h;
    return @max(self.pickDockHeight(pick), surface_h);
}

// ── Tests ──

const testing = std.testing;

test "literal tabs: a tab advances to the next tab stop; offsets stay exact" {
    const gpa = testing.allocator;
    var view = try View.init(gpa, font_provider.defaultMono(), 16);
    defer view.deinit();
    // "a\tb": 'a' at col 0, the tab starts at col 1 and advances 'b' to the
    // next tab stop (col 4). Empty frame_layout → the motion path
    // (buildRowStops) computes x; the on-screen mono builder mirrors it.
    var rope = try stemma.Rope.fromSlice(gpa, "a\tb");
    defer rope.deinit(gpa);
    const cw = view.cell_w;
    try testing.expectApproxEqAbs(margin, try view.xOfOffsetOnRow(&rope, 0), 0.5);
    try testing.expectApproxEqAbs(margin + cw, try view.xOfOffsetOnRow(&rope, 1), 0.5);
    try testing.expectApproxEqAbs(margin + 4 * cw, try view.xOfOffsetOnRow(&rope, 2), 0.5);
    // Two leading tabs → 8 columns of indent before the text.
    var rope2 = try stemma.Rope.fromSlice(gpa, "\t\tx");
    defer rope2.deinit(gpa);
    try testing.expectApproxEqAbs(margin + 8 * cw, try view.xOfOffsetOnRow(&rope2, 2), 0.5);
}

test "dock: a plugin's bottom surface sizes the dock with no pick open" {
    const gpa = testing.allocator;
    var view = try View.init(gpa, font_provider.defaultMono(), 16);
    defer view.deinit();
    var bar: core.surface.Surface = .{};
    defer bar.deinit(gpa);
    bar.begin(gpa, .bottom);
    bar.addRow(gpa);
    bar.addSpan(gpa, "Find: x", .normal);
    bar.addRow(gpa);
    bar.addSpan(gpa, "Replace: y", .normal);
    bar.end(gpa, null);
    const surfaces = [_]*const core.surface.Surface{&bar};
    try testing.expectApproxEqAbs(2 * view.line_h, view.dockHeight(null, &surfaces), 0.01);
    // A corner surface floats over the body; it carves nothing.
    bar.placement = .corner;
    try testing.expectApproxEqAbs(@as(f32, 0), view.dockHeight(null, &surfaces), 0.01);
}

test "monospace parity gate: view-computed vertical target == old column target" {
    // The column-debt fix must not change plain-code editing. For a mono
    // font, the goal-x vertical step (xOfOffsetOnRow -> xToOffsetOnRow)
    // must land on exactly the offset the old scalar-column moveVertical
    // did: line.start + min(goal_col, line.len()). ASCII only, so every
    // byte is a scalar boundary and snapBoundary is the identity.
    const gpa = testing.allocator;
    var view = try View.init(gpa, font_provider.defaultMono(), 16);
    defer view.deinit();

    var rope = try stemma.Rope.fromSlice(gpa, "hello world\nhi\n\nwide load here\nx");
    defer rope.deinit(gpa);
    const rows = rope.lineCount();

    // From every offset, stepping to every other row, the two models agree.
    // (Empty frame_layout → both use the mono re-shape path.)
    var cur: usize = 0;
    while (cur <= rope.byteLen()) : (cur += 1) {
        const p = rope.offsetToPoint(cur);
        const gx = try view.xOfOffsetOnRow(&rope, cur);
        for (0..rows) |target_row| {
            const line = rope.lineRange(target_row);
            const old_target = line.start + @min(p.col, line.len());
            const new_target = try view.xToOffsetOnRow(&rope, target_row, gx);
            testing.expectEqual(old_target, new_target) catch |e| {
                std.debug.print(
                    "mismatch: cur={d} (row {d} col {d}) -> row {d}: old={d} new={d}\n",
                    .{ cur, p.row, p.col, target_row, old_target, new_target },
                );
                return e;
            };
        }
    }
}
