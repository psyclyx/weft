//! Bundled presenter for provider-authored semantic scenes.
//!
//! This is deliberately downstream of the semantic and view runtime: plugins
//! publish stable nodes, facts, actions, and generic editable fields; this
//! renderer chooses rows, colors, and popup geometry. A radically different
//! presenter can consume the same scene without changing files, vim, or core.

const std = @import("std");
const Allocator = std.mem.Allocator;
const semantic = @import("weft_semantic");

const region = @import("../region.zig");
const view = @import("../view.zig");
const data = @import("semantic_data.zig");
const popup = @import("popup.zig");
const chrome_mod = @import("chrome.zig");
const menu_mod = @import("menu.zig");
const status_layout = @import("status_layout.zig");

const View = view.View;
const Run = view.Run;
const Rect = view.Rect;

pub const max_rows = 4096;
pub const max_spans = 16384;
pub const max_depth = 128;
pub const max_visual_bytes = 1 << 16;

pub const Tone = enum { normal, muted, accent, positive, negative, warning, conflict };

pub const Span = struct {
    node: semantic.scene.NodeId,
    text: []const u8,
    column: u16,
    tone: Tone,
    focusable: bool,
    /// An `action` node: a click reaches it whether or not it is in the
    /// keyboard's focus order — it IS its action reference.
    activatable: bool = false,
    compact_column: ?u16 = null,
    compact_below: u16 = 0,
    hide_below: u16 = 0,
    selection: ?struct { anchor: usize, caret: usize } = null,
    /// The chrome role this span is drawn as: an action node is a button
    /// (a menubar's title when its role says `menubar-item`), a node whose
    /// role is `separator` a divider. Null: plain text, as every label and
    /// field is. A menu's own rows are the menu widget's (`menu.zig`).
    chrome: ?chrome_mod.Role = null,
    /// A menubar title's underlined letter (its `mnemonic` fact), and
    /// whether its menu is open (`lit`).
    mnemonic: ?usize = null,
    lit: bool = false,
    /// The node's `icon` fact — an icon name in the theme's set.
    icon: ?[]const u8 = null,
    /// Why the action cannot run (its `reason` fact): the button reads
    /// disabled and its tooltip says why.
    reason: []const u8 = "",
    /// The action's `name` fact, which a key hint is looked up by.
    name: []const u8 = "",
    /// Its column is where nesting put it (the scene declared none), and it
    /// starts its row.
    natural: bool = false,

    /// Cells the span occupies on the row before its style is known — a
    /// button's label and a cell of padding either side. A style that draws
    /// an icon widens it at draw time (`chrome.buttonCols`).
    fn cells(self: Span) usize {
        return visualWidth(self.text) + @as(usize, if (self.chrome == .button or self.chrome == .menu_title) 2 else 0);
    }

    /// Cells under `v`'s chrome style.
    fn cellsIn(self: Span, v: *const View) usize {
        if (self.chrome == .button) return chrome_mod.buttonCols(v, self.content());
        if (self.chrome == .menu_title) return chrome_mod.titleCols(self.content());
        return visualWidth(self.text);
    }

    fn content(self: Span) chrome_mod.Content {
        return .{ .label = self.text, .icon = self.icon, .mnemonic = self.mnemonic };
    }
};

pub const Row = struct {
    spans: []const Span,
    focused: bool,
    /// Inside the scene's selection (a range, a marked row).
    selected: bool = false,
    /// Holds the node the view reveals: marked on its own, whatever the
    /// selection is.
    revealed: bool = false,
    /// Cells of its columns that are indentation — its depth in a tree. A
    /// producer that places its own columns says so with the row's `indent`
    /// fact; a row laid out by nesting is indented by its first span's
    /// column. What a narrow pane may take back (`indentScale`).
    indent: u16 = 0,
};

pub const Hit = struct {
    view: semantic.view.Ref,
    node: semantic.scene.NodeId,
    rect: region.Rect,
};

/// Arena-owned projection used by both the renderer and layout tests. Field
/// providers are sampled once per call; the resulting rows retain semantic
/// node identity, and visible row indexes are never behavior.
pub fn rowsFor(arena: Allocator, document: data.Document) Allocator.Error![]const Row {
    var builder: Builder = .{ .arena = arena, .document = document };
    try builder.appendNode(document.root, 0, null);
    return builder.rows.toOwnedSlice(arena);
}

const Builder = struct {
    arena: Allocator,
    document: data.Document,
    rows: std.ArrayList(Row) = .empty,
    span_count: usize = 0,

    fn appendNode(self: *Builder, node: *const semantic.scene.Node, depth: usize, row: ?*std.ArrayList(Span)) Allocator.Error!void {
        if (depth > max_depth or self.rows.items.len >= max_rows) return;
        switch (node.content) {
            .container => |container| switch (container.axis) {
                .horizontal => {
                    var spans: std.ArrayList(Span) = .empty;
                    for (container.children) |*child| try self.appendNode(child, depth + 1, &spans);
                    if (spans.items.len != 0) try self.finishRow(&spans, numberFact(node, "indent"));
                },
                .vertical, .overlay => for (container.children) |*child|
                    try self.appendNode(child, depth + 1, null),
            },
            else => {
                if (self.span_count >= max_spans) return;
                if (row) |spans| {
                    try spans.append(self.arena, try self.spanFor(node, depth, spans.items));
                } else {
                    var spans: std.ArrayList(Span) = .empty;
                    try spans.append(self.arena, try self.spanFor(node, depth, spans.items));
                    try self.finishRow(&spans, numberFact(node, "indent"));
                }
                self.span_count += 1;
            },
        }
    }

    fn finishRow(self: *Builder, spans: *std.ArrayList(Span), indent: ?u16) Allocator.Error!void {
        const owned = try spans.toOwnedSlice(self.arena);
        var focused = false;
        if (self.document.focused) |wanted| for (owned) |span| {
            if (span.node == wanted) {
                focused = true;
                break;
            }
        };
        var selected = false;
        var revealed = false;
        for (owned) |span| {
            if (std.mem.indexOfScalar(semantic.scene.NodeId, self.document.selected, span.node) != null) selected = true;
            if (self.document.revealed == span.node) revealed = true;
        }
        // A row laid out by nesting is indented by where nesting put it.
        const natural = if (owned[0].natural) owned[0].column else 0;
        try self.rows.append(self.arena, .{ .spans = owned, .focused = focused, .selected = selected, .revealed = revealed, .indent = indent orelse natural });
    }

    fn spanFor(self: *Builder, node: *const semantic.scene.Node, depth: usize, preceding: []const Span) Allocator.Error!Span {
        var selection: ?struct { anchor: usize, caret: usize } = null;
        const text = switch (node.content) {
            .label => |label| try displayBytes(self.arena, label),
            // The label alone: that it is a button is the chrome style's to
            // show, not brackets in its text.
            .action => |action| try displayBytes(self.arena, if (action.label.len != 0) action.label else action.action),
            .field => |field| blk: {
                const provider = self.document.fields.get(field.ref) orelse
                    break :blk try displayBytes(self.arena, field.placeholder);
                var snapshot = provider.snapshot(self.arena) catch
                    break :blk try self.arena.dupe(u8, "<field unavailable>");
                defer snapshot.deinit();
                const bytes = snapshot.value.bytes;
                // Only the field being EDITED shows its text raw and wears a
                // caret; a field that is merely on the focused row reads like
                // every other row (doc/chrome.md §5.2).
                const edited = if (self.document.editing) |ref| ref.eql(field.ref) else false;
                if (!edited) {
                    for (node.facts) |fact| if (std.mem.eql(u8, fact.name, "display"))
                        break :blk try displayBytes(self.arena, fact.value);
                }
                if (self.document.active and edited) {
                    const anchor = try displayBytes(self.arena, bytes[0..@min(bytes.len, snapshot.value.selection.anchor)]);
                    const caret = try displayBytes(self.arena, bytes[0..@min(bytes.len, snapshot.value.selection.caret)]);
                    selection = .{ .anchor = visualWidth(anchor), .caret = visualWidth(caret) };
                }
                const displayed = try displayBytes(self.arena, if (bytes.len == 0) field.placeholder else bytes);
                for (node.facts) |fact| if (std.mem.eql(u8, fact.name, "suffix"))
                    break :blk try std.fmt.allocPrint(self.arena, "{s}{s}", .{ displayed, fact.value });
                break :blk displayed;
            },
            .container => unreachable,
        };
        const natural_column: usize = if (preceding.len == 0)
            depth * 2
        else blk: {
            const prior = preceding[preceding.len - 1];
            break :blk @as(usize, prior.column) + prior.cells() + 2;
        };
        const role: ?chrome_mod.Role = switch (node.content) {
            .action => if (std.mem.eql(u8, leafOf(node.role), menu_mod.role_title)) .menu_title else .button,
            .label => if (std.mem.eql(u8, leafOf(node.role), "separator")) .separator else null,
            else => null,
        };
        return .{
            .chrome = role,
            .mnemonic = menu_mod.mnemonicOf(node),
            .lit = if (factValue(node, "lit")) |v| std.mem.eql(u8, v, "on") else false,
            .icon = factValue(node, "icon"),
            .reason = factValue(node, "reason") orelse "",
            .name = factValue(node, "name") orelse "",
            .node = node.id,
            .text = text,
            .column = node.layout.column orelse @intCast(@min(natural_column, std.math.maxInt(u16))),
            .natural = node.layout.column == null and preceding.len == 0,
            .tone = toneFor(node),
            .focusable = node.focusable,
            .activatable = node.content == .action,
            .compact_column = numberFact(node, "compact-column"),
            .compact_below = numberFact(node, "compact-below") orelse 0,
            .hide_below = numberFact(node, "hide-below") orelse 0,
            .selection = if (selection) |sel| .{ .anchor = sel.anchor, .caret = sel.caret } else null,
        };
    }
};

/// Render a semantic tool view in the pane body. Text editing, modal state,
/// and filesystem meaning are absent here; fields and stable focus are the
/// only behavior-facing inputs.
pub fn drawDocument(v: *View, scratch: Allocator, hit_arena: Allocator, runs: *std.ArrayList(Run), rects: *std.ArrayList(Rect), document: data.Document, hud: view.Hud, body: region.Rect, top_row: *usize) ![]const Hit {
    const rows = try rowsFor(scratch, document);
    var hits: std.ArrayList(Hit) = .empty;
    var content = body;
    if (!hud.brand_mark and document.title.len != 0 and body.h >= 2 * v.line_h) {
        // Every scene's title, fitted by the status line's rules (doc/chrome.md
        // §4.2): a path keeps its leaf behind `…`, nothing is cut mid-glyph.
        const title_buf = try scratch.alloc(u8, document.title.len + status_layout.ellipsis.len);
        const cols: usize = @intFromFloat(@max(0, body.w - v.cell_w) / v.cell_w);
        try popup.propLine(v, scratch, runs, status_layout.fitTitle(title_buf, document.title, cols), body.x + v.cell_w, body.y + v.ascent, v.theme.status);
        content.y += v.line_h;
        content.h -= v.line_h;
    }
    content.x += v.cell_w;
    content.w = @max(0, content.w - v.cell_w);
    const visible = @max(1, @as(usize, @intFromFloat(@max(0, content.h) / v.line_h)));
    top_row.* = @min(top_row.*, rows.len -| visible);
    const reveal = document.active and (v.semantic_last_view == null or !v.semantic_last_view.?.eql(document.view) or v.semantic_last_node != document.focused);
    if (document.active) {
        v.semantic_last_view = document.view;
        v.semantic_last_node = document.focused;
    }
    if (reveal) for (rows, 0..) |row, index| {
        if (!row.focused) continue;
        if (index < top_row.*) top_row.* = index;
        if (index >= top_row.* + visible) top_row.* = index + 1 - visible;
        break;
    };
    // One indentation scale over every row, not only the visible ones, so the
    // tree does not re-indent as it scrolls.
    const scale = indentScale(rows, @intFromFloat(@max(0, content.w) / v.cell_w));
    try drawRows(v, scratch, hit_arena, runs, rects, &hits, document.view, rows[top_row.*..], content, hud, true, scale);
    return hits.toOwnedSlice(hit_arena);
}

/// What `drawOverlay` drew: its scene hit regions and the box they sit in.
pub const Drawn = struct { hits: []const Hit, box: ?region.Rect = null };

/// Render the active head-local interaction above its underlying view. A
/// MENU (a root whose role is `menu`) is the menu widget's (`menu.zig`),
/// hung below the node its anchor facts name, else at the presentation's
/// point — `pointer` or `caret` — and floated in `bounds` (the frame: a menu
/// floats over every pane, not only the one it opened over). Anything else is
/// a dialog in the body, placed by the presentation string, an open hint
/// consumed only by this presenter: `bottom`, `corner`, else centred.
/// `caret_at` is the focused pane's caret, bottom-left, when the body shows
/// text.
pub fn drawOverlay(v: *View, scratch: Allocator, hit_arena: Allocator, runs: *std.ArrayList(Run), rects: *std.ArrayList(Rect), overlay: data.Overlay, hud: view.Hud, body: region.Rect, bounds: region.Rect, caret_at: ?[2]f32) !Drawn {
    if (menu_mod.isMenu(overlay.document.root)) return drawMenu(v, scratch, hit_arena, runs, rects, overlay, hud, body, bounds, caret_at);
    const rows = try rowsFor(scratch, overlay.document);
    if (rows.len == 0) return .{ .hits = &.{} };
    var widest: usize = 1;
    for (rows) |row| {
        var occupied: usize = 0;
        for (row.spans, 0..) |span, index| {
            const column = @max(occupied, @as(usize, span.column));
            occupied = column + span.cellsIn(v) + @as(usize, @intFromBool(index + 1 < row.spans.len));
        }
        widest = @max(widest, occupied);
    }
    const area = body;
    const visible_rows = @min(rows.len, @max(1, @as(usize, @intFromFloat(@max(0, area.h) / v.line_h)) -| 1));
    const pad_x = v.cell_w;
    const pad_y = v.line_h * 0.5;
    const box_w = @min(area.w, @as(f32, @floatFromInt(widest + 2)) * v.cell_w);
    const box_h = @min(area.h, @as(f32, @floatFromInt(visible_rows)) * v.line_h + 2 * pad_y);
    const x = std.math.clamp(area.x + (area.w - box_w) / 2, area.x, @max(area.x, area.x + area.w - box_w));
    const bottom = std.mem.eql(u8, overlay.presentation, "bottom") or
        std.mem.eql(u8, overlay.presentation, "which-key-like");
    const corner = std.mem.eql(u8, overlay.presentation, "corner");
    const raw_y = if (bottom)
        area.y + area.h - box_h
    else if (corner)
        area.y
    else
        area.y + (area.h - box_h) / 2;
    const y = std.math.clamp(raw_y, area.y, @max(area.y, area.y + area.h - box_h));
    const sink: chrome_mod.Sink = .{ .v = v, .scratch = scratch, .runs = runs, .rects = rects };
    try chrome_mod.paintPanel(sink, .{ .x = x, .y = y, .w = box_w, .h = box_h }, v.theme.background, v.theme.accent, .popup);
    const inner: region.Rect = .{ .x = x + pad_x, .y = y + pad_y, .w = @max(0, box_w - 2 * pad_x), .h = @max(0, box_h - 2 * pad_y) };
    var hits: std.ArrayList(Hit) = .empty;
    try drawRows(v, scratch, hit_arena, runs, rects, &hits, overlay.document.view, rows[0..visible_rows], inner, hud, true, 1);
    return .{ .hits = try hits.toOwnedSlice(hit_arena), .box = .{ .x = x, .y = y, .w = box_w, .h = box_h } };
}

/// A menu overlay through the menu widget: its anchor, the row under the
/// pointer, and its hit regions in this view.
fn drawMenu(v: *View, scratch: Allocator, hit_arena: Allocator, runs: *std.ArrayList(Run), rects: *std.ArrayList(Rect), overlay: data.Overlay, hud: view.Hud, body: region.Rect, bounds: region.Rect, caret_at: ?[2]f32) !Drawn {
    const root = overlay.document.root;
    const centre: [2]f32 = .{ body.x + body.w / 3, body.y + body.h / 4 };
    const anchor: menu_mod.Anchor = if (menu_mod.anchorBox(v, root)) |box|
        .{ .below = box }
    else if (std.mem.eql(u8, overlay.presentation, "caret"))
        .{ .point = caret_at orelse overlay.pointer orelse centre }
    else
        .{ .point = overlay.pointer orelse caret_at orelse centre };
    const hovered: ?semantic.scene.NodeId = if (hud.pointer.node) |n| (if (n.view.eql(overlay.document.view)) n.node else null) else null;
    const drawn = try menu_mod.draw(v, scratch, hit_arena, runs, rects, root, anchor, bounds, hovered, hud.pointer.pressed, hud.pointer.tooltip);
    const hits = try hit_arena.alloc(Hit, drawn.hits.len);
    for (drawn.hits, hits) |h, *out| out.* = .{ .view = overlay.document.view, .node = h.node, .rect = h.rect };
    return .{ .hits = hits, .box = drawn.box };
}

/// A scene's rows in `body`: each span in its column, a chrome node painted
/// by its role in the cells it measures, and every focusable or activatable
/// span's box filed as a hit.
fn drawRows(v: *View, scratch: Allocator, hit_arena: Allocator, runs: *std.ArrayList(Run), rects: *std.ArrayList(Rect), hits: *std.ArrayList(Hit), view_ref: semantic.view.Ref, rows: []const Row, body: region.Rect, hud: view.Hud, clip_width: bool, scale: f32) !void {
    const count = @min(rows.len, @as(usize, @intFromFloat(@max(0, body.h) / v.line_h)));
    for (rows[0..count], 0..) |row, index| {
        const y = body.y + @as(f32, @floatFromInt(index)) * v.line_h;
        if (row.selected) {
            // A selected row wears the selection's wash, as selected text does.
            try rects.append(scratch, .{ .x = body.x, .y = y, .w = body.w, .h = v.line_h, .color = v.theme.selection });
        } else if (row.focused) {
            var color = v.theme.background;
            for (0..3) |i| color[i] = color[i] * 0.8 + v.theme.selection[i] * 0.2;
            try rects.append(scratch, .{ .x = body.x, .y = y, .w = body.w, .h = v.line_h, .color = color });
        }
        // The revealed row wears its own mark — an accent bar at the gutter
        // edge — so it reads beside the selection's wash, never as it.
        if (row.revealed) try rects.append(scratch, .{ .x = body.x - v.cell_w, .y = y, .w = @max(1, v.cell_w / 4), .h = v.line_h, .color = v.theme.accent });
        const editing_metadata = editingMetadata(row);
        const cells: usize = @intFromFloat(@max(0, body.w) / v.cell_w);
        const shift = indentShift(row, scale);
        var occupied: usize = 0;
        for (row.spans) |span| {
            const declared_column = declaredColumn(span, cells, editing_metadata) orelse continue;
            const column = @max(occupied, declared_column -| shift);
            const x = body.x + @as(f32, @floatFromInt(column)) * v.cell_w;
            if (clip_width and x >= body.x + body.w) continue;
            const available_cells: usize = @intFromFloat(@max(0, body.x + body.w - x) / v.cell_w);
            if (span.selection) |sel| {
                const start = @min(@min(sel.anchor, sel.caret), available_cells);
                const end = @min(@max(sel.anchor, sel.caret), available_cells);
                if (end > start) try rects.append(scratch, .{ .x = x + @as(f32, @floatFromInt(start)) * v.cell_w, .y = y, .w = @as(f32, @floatFromInt(end - start)) * v.cell_w, .h = v.line_h, .color = v.theme.selection });
                if (hud.cursor_on and sel.caret < available_cells) try rects.append(scratch, fieldCaretRect(x + @as(f32, @floatFromInt(sel.caret)) * v.cell_w, y, v.cell_w, v.line_h, hud.cursor_style, v.theme.cursor));
            }
            if (span.chrome) |role| {
                // A chrome node: its style draws it, in the cells (or, in a
                // menu, the row) it is given, and that box is what a click
                // reaches.
                const sink: chrome_mod.Sink = .{ .v = v, .scratch = scratch, .runs = runs, .rects = rects };
                const hovered = hud.pointer.onNode(view_ref, span.node);
                const state: chrome_mod.State = .{
                    .hover = hovered,
                    .pressed = hovered and hud.pointer.pressed,
                    .disabled = span.reason.len != 0,
                    // A menubar title is lit while its menu is open.
                    .focused = row.focused or span.lit,
                };
                var content = span.content();
                content.fg = colorFor(v, span.tone);
                const box: region.Rect = .{ .x = x, .y = y, .w = @min(@as(f32, @floatFromInt(span.cellsIn(v))) * v.cell_w, @max(0, body.x + body.w - x)), .h = v.line_h };
                switch (role) {
                    .separator => {
                        if (row.spans.len == 1)
                            try chrome_mod.paintSeparator(sink, .{ .x = body.x, .y = y, .w = body.w, .h = v.line_h }, .horizontal)
                        else
                            try chrome_mod.paintSeparator(sink, .{ .x = x, .y = y + 3, .w = v.cell_w, .h = @max(0, v.line_h - 6) }, .vertical);
                        occupied = column + visualWidth(span.text) + 1;
                        continue;
                    },
                    else => try chrome_mod.paint(sink, role, state, content, box),
                }
                if (hovered) v.build_tip = .{ .label = span.text, .reason = span.reason, .command = span.name };
                occupied = column + span.cellsIn(v) + 1;
                if (!span.focusable and !span.activatable) continue;
                try hits.append(hit_arena, .{ .view = view_ref, .node = span.node, .rect = box });
                continue;
            }
            const text = if (clip_width) try fitLabel(scratch, span, available_cells) else span.text;
            try popup.propLine(v, scratch, runs, text, x, y + v.ascent, colorFor(v, span.tone));
            if (hud.cursor_on and hud.cursor_style == .block) if (span.selection) |sel| {
                const prefix = firstCells(text, sel.caret);
                if (prefix.len < text.len) try popup.propLine(v, scratch, runs, firstCells(text[prefix.len..], 1), x + @as(f32, @floatFromInt(sel.caret)) * v.cell_w, y + v.ascent, v.theme.cursor_text);
            };
            occupied = column + visualWidth(span.text) + 1;
            if (!span.focusable and !span.activatable) continue;
            const available = @max(0, body.x + body.w - x);
            const width = @min(available, @max(v.cell_w, @as(f32, @floatFromInt(visualWidth(span.text))) * v.cell_w));
            try hits.append(hit_arena, .{ .view = view_ref, .node = span.node, .rect = .{ .x = x, .y = y, .w = width, .h = v.line_h } });
        }
    }
}

/// The fewest cells a row keeps for its label before its indentation gives
/// way: a tree nested deeper than a narrow pane is wide still shows each
/// row's name, not a margin running into the edge.
pub const min_label_cells = 12;

/// A row whose field is being edited shows its hidden metadata too.
fn editingMetadata(row: Row) bool {
    return for (row.spans) |span| {
        if (span.selection != null and span.hide_below != 0) break true;
    } else false;
}

/// Where `span` asks to sit in a pane `cells` wide: its compact column when
/// the pane is narrower than it wants, else its column. Null when it hides at
/// this width — though a field being edited stays reachable, and focusing one
/// reveals its row's metadata.
fn declaredColumn(span: Span, cells: usize, editing_metadata: bool) ?usize {
    if (cells < span.hide_below and span.selection == null) return null;
    return if (!editing_metadata and cells < span.compact_below) span.compact_column orelse span.column else span.column;
}

/// The column `row`'s label starts at in a pane `cells` wide: its first
/// focusable span's, else its first shown span's.
fn labelColumn(row: Row, cells: usize) ?usize {
    const editing_metadata = editingMetadata(row);
    var first: ?usize = null;
    for (row.spans) |span| {
        const column = declaredColumn(span, cells, editing_metadata) orelse continue;
        if (span.focusable) return column;
        if (first == null) first = column;
    }
    return first;
}

/// How much of every row's indentation a pane `cells` wide keeps, in [0, 1]:
/// all of it when each label has `min_label_cells` to its right, else the
/// most that lets the most squeezed row have them — down to none, a flat
/// list, when even that is not enough (its long labels then end in `…`).
/// One scale for all rows rather than a cap on each, so the indent step
/// shrinks evenly and a deeper row never reads shallower than its parent.
pub fn indentScale(rows: []const Row, cells: usize) f32 {
    var scale: f32 = 1;
    for (rows) |row| {
        if (row.indent == 0) continue;
        const column = labelColumn(row, cells) orelse continue;
        const over = (column + min_label_cells) -| cells;
        if (over == 0) continue;
        const kept = row.indent -| @as(u16, @intCast(@min(over, row.indent)));
        scale = @min(scale, @as(f32, @floatFromInt(kept)) / @as(f32, @floatFromInt(row.indent)));
    }
    return scale;
}

/// Cells `row` moves left when its indentation is kept at `scale`.
pub fn indentShift(row: Row, scale: f32) usize {
    const kept: usize = @intFromFloat(@floor(@as(f32, @floatFromInt(row.indent)) * scale));
    return row.indent -| kept;
}

/// `span`'s text in the `cells` left to it: whole when it fits, else cut at
/// its end with `…`, as the status line cuts prose (a field being edited is
/// clipped instead, so its caret stays where its text is).
fn fitLabel(scratch: Allocator, span: Span, cells: usize) Allocator.Error![]const u8 {
    if (span.selection != null or visualWidth(span.text) <= cells) return firstCells(span.text, cells);
    const buf = try scratch.alloc(u8, span.text.len + status_layout.ellipsis.len);
    return status_layout.cut(buf, span.text, cells, .end);
}

test "a label in a pane's last partial cell draws nothing, never its whole text over the next pane" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const span: Span = .{ .node = @enumFromInt(1), .text = "main.zig", .column = 0, .tone = .normal, .focusable = true };
    try std.testing.expectEqualStrings("", try fitLabel(arena.allocator(), span, 0));
    try std.testing.expectEqualStrings("…", try fitLabel(arena.allocator(), span, 1));
    try std.testing.expectEqualStrings("main.zig", try fitLabel(arena.allocator(), span, 8));
}

test "a deep tree in a narrow pane gives back indentation evenly, and every label keeps its room" {
    const Node = semantic.scene.NodeId;
    // A tree as a producer lays one out: each row indented two cells a
    // level, its name at the indent plus two.
    var rows: [10]Row = undefined;
    var spans: [10][1]Span = undefined;
    for (0..10) |depth| {
        const indent: u16 = @intCast(depth * 2);
        spans[depth][0] = .{ .node = @as(Node, @enumFromInt(depth + 1)), .text = "name", .column = indent + 2, .tone = .normal, .focusable = true };
        rows[depth] = .{ .spans = &spans[depth], .focused = false, .indent = indent };
    }
    // Wide: nothing moves.
    try std.testing.expectEqual(@as(f32, 1), indentScale(&rows, 80));
    for (rows) |row| try std.testing.expectEqual(@as(usize, 0), indentShift(row, 1));
    // Narrow (24 cells; the deepest name wants column 20): every label keeps
    // its room, and depth still reads as depth — each row at or right of its
    // parent, the deepest strictly right of the shallowest.
    const cells = 24;
    const scale = indentScale(&rows, cells);
    try std.testing.expect(scale < 1);
    var previous: usize = 0;
    for (rows) |row| {
        const column = labelColumn(row, cells).? - indentShift(row, scale);
        try std.testing.expect(column + min_label_cells <= cells);
        try std.testing.expect(column >= previous);
        previous = column;
    }
    try std.testing.expect(previous > labelColumn(rows[0], cells).?);
    // Narrower than a label: flat, and a long label ends in `…` in its room.
    try std.testing.expectEqual(@as(f32, 0), indentScale(&rows, 8));
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const long: Span = .{ .node = @enumFromInt(99), .text = "a-long-directory-name", .column = 2, .tone = .normal, .focusable = true };
    try std.testing.expectEqualStrings("a-long-dir…", try fitLabel(arena.allocator(), long, 11));
    try std.testing.expectEqualStrings("a-long-directory-name", try fitLabel(arena.allocator(), long, 40));

    // A row's indent is what its producer says it is, else where nesting
    // put it.
    const cell = [_]semantic.scene.Node{.{ .id = @enumFromInt(3), .layout = .{ .column = 8 }, .content = .{ .label = "deep" } }};
    const lines = [_]semantic.scene.Node{
        .{ .id = @enumFromInt(2), .facts = &.{.{ .name = "indent", .value = "6" }}, .content = .{ .container = .{ .axis = .horizontal, .children = &cell } } },
        .{ .id = @enumFromInt(4), .content = .{ .label = "nested" } },
    };
    const root: semantic.scene.Node = .{ .id = @enumFromInt(1), .content = .{ .container = .{ .children = &lines } } };
    var fields = @import("weft_view_runtime").field.Registry.init(.here);
    defer fields.deinit(std.testing.allocator);
    const built = try rowsFor(arena.allocator(), .{ .view = .{ .authority = .here, .slot = 0, .generation = 1 }, .root = &root, .fields = &fields });
    try std.testing.expectEqual(@as(u16, 6), built[0].indent);
    try std.testing.expectEqual(built[1].spans[0].column, built[1].indent);
}

fn fieldCaretRect(x: f32, y: f32, cell_w: f32, line_h: f32, style: view.CursorStyle, color: [4]f32) Rect {
    return .{ .x = x, .y = if (style == .underline) y + line_h - 2 else y, .w = if (style == .bar) 2 else cell_w, .h = if (style == .underline) 2 else line_h, .color = color };
}

test "semantic field caret follows shared cursor style" {
    const color = [4]f32{ 1, 1, 1, 1 };
    const block = fieldCaretRect(10, 20, 8, 16, .block, color);
    try std.testing.expectEqual(@as(f32, 8), block.w);
    try std.testing.expectEqual(@as(f32, 16), block.h);
    try std.testing.expectEqual(@as(f32, 2), fieldCaretRect(10, 20, 8, 16, .bar, color).w);
    const underline = fieldCaretRect(10, 20, 8, 16, .underline, color);
    try std.testing.expectEqual(@as(f32, 34), underline.y);
    try std.testing.expectEqual(@as(f32, 2), underline.h);
}

fn colorFor(v: *const View, tone: Tone) [4]f32 {
    return switch (tone) {
        .normal => v.theme.foreground,
        .muted => v.theme.status,
        .accent => v.theme.md_link,
        .positive => v.theme.syn_string,
        .negative => v.theme.diag_error,
        .warning => v.theme.diag_warn,
        .conflict => v.theme.syn_keyword,
    };
}

fn toneFor(node: *const semantic.scene.Node) Tone {
    var value = node.role;
    for (node.facts) |fact| if (std.mem.eql(u8, fact.name, "tone")) {
        value = fact.value;
        break;
    };
    if (std.mem.eql(u8, value, "muted")) return .muted;
    if (std.mem.eql(u8, value, "accent") or std.mem.eql(u8, value, "action")) return .accent;
    if (std.mem.eql(u8, value, "positive") or std.mem.eql(u8, value, "added")) return .positive;
    if (std.mem.eql(u8, value, "negative") or std.mem.eql(u8, value, "deleted")) return .negative;
    if (std.mem.eql(u8, value, "warning") or std.mem.eql(u8, value, "changed")) return .warning;
    if (std.mem.eql(u8, value, "conflict")) return .conflict;
    if (std.mem.eql(u8, node.role, "files.metadata") or
        std.mem.eql(u8, node.role, "files.mode") or
        std.mem.eql(u8, node.role, "files.original-name")) return .muted;
    if (std.mem.eql(u8, node.role, "files.name")) for (node.facts) |fact| {
        if (!std.mem.eql(u8, fact.name, "kind")) continue;
        if (std.mem.eql(u8, fact.value, "directory")) return .accent;
        if (std.mem.eql(u8, fact.value, "symlink")) return .warning;
    };
    return .normal;
}

fn factValue(node: *const semantic.scene.Node, name: []const u8) ?[]const u8 {
    for (node.facts) |fact| if (std.mem.eql(u8, fact.name, name)) return fact.value;
    return null;
}

/// A role's last dotted segment: `offers.separator` and `separator` alike.
fn leafOf(role: []const u8) []const u8 {
    return if (std.mem.lastIndexOfScalar(u8, role, '.')) |dot| role[dot + 1 ..] else role;
}

fn numberFact(node: *const semantic.scene.Node, name: []const u8) ?u16 {
    for (node.facts) |fact| if (std.mem.eql(u8, fact.name, name))
        return std.fmt.parseInt(u16, fact.value, 10) catch null;
    return null;
}

fn firstCells(text: []const u8, count: usize) []const u8 {
    var end: usize = 0;
    var cells: usize = 0;
    while (end < text.len and cells < count) : (cells += 1)
        end += std.unicode.utf8ByteSequenceLength(text[end]) catch 1;
    return text[0..@min(end, text.len)];
}

fn visualWidth(text: []const u8) usize {
    return std.unicode.utf8CountCodepoints(text) catch text.len;
}

/// Font shaping consumes UTF-8, while filesystem-backed fields may retain raw
/// names. Escape only bytes that cannot be displayed safely; semantic values
/// and effect plans retain the original bytes in their providers.
pub fn displayBytes(arena: Allocator, raw: []const u8) Allocator.Error![]const u8 {
    const input = raw[0..@min(raw.len, max_visual_bytes)];
    var out: std.ArrayList(u8) = .empty;
    var index: usize = 0;
    while (index < input.len) {
        const byte = input[index];
        if (byte >= 0x20 and byte < 0x7f) {
            try out.append(arena, byte);
            index += 1;
            continue;
        }
        if (byte >= 0x80) {
            const sequence_len = std.unicode.utf8ByteSequenceLength(byte) catch 0;
            if (sequence_len != 0 and index + sequence_len <= input.len and std.unicode.utf8ValidateSlice(input[index .. index + sequence_len])) {
                try out.appendSlice(arena, input[index .. index + sequence_len]);
                index += sequence_len;
                continue;
            }
        }
        switch (byte) {
            '\n' => try out.appendSlice(arena, "\\n"),
            '\r' => try out.appendSlice(arena, "\\r"),
            '\t' => try out.appendSlice(arena, "\\t"),
            else => {
                const escaped = try std.fmt.allocPrint(arena, "\\x{X:0>2}", .{byte});
                try out.appendSlice(arena, escaped);
            },
        }
        index += 1;
    }
    if (raw.len > input.len) try out.appendSlice(arena, "…");
    return out.toOwnedSlice(arena);
}

test "semantic rows preserve stable focus and field columns" {
    const view_runtime = @import("weft_view_runtime");
    const Memory = struct {
        pub fn snapshot(_: *@This(), gpa: Allocator) view_runtime.field.Error!view_runtime.field.OwnedSnapshot {
            var result = view_runtime.field.OwnedSnapshot.init(gpa);
            const alloc = result.allocator();
            result.value = .{ .revision = try alloc.dupe(u8, "1"), .bytes = try alloc.dupe(u8, "name"), .selection = .{ .anchor = 0, .caret = 0 } };
            return result;
        }
        pub fn edit(_: *@This(), _: []const u8, _: view_runtime.field.Edit) view_runtime.field.Error!void {}
    };
    var memory: Memory = .{};
    var fields = view_runtime.field.Registry.init(.here);
    defer fields.deinit(std.testing.allocator);
    const field_ref = try fields.insert(std.testing.allocator, @enumFromInt(1), .init(&memory));
    const children = [_]semantic.scene.Node{
        .{ .id = @enumFromInt(2), .layout = .{ .column = 0 }, .content = .{ .label = "0644" } },
        .{ .id = @enumFromInt(3), .layout = .{ .column = 8 }, .focusable = true, .content = .{ .field = .{ .ref = field_ref } } },
    };
    const root: semantic.scene.Node = .{ .id = @enumFromInt(1), .content = .{ .container = .{ .axis = .horizontal, .children = &children } } };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const rows = try rowsFor(arena.allocator(), .{ .view = .{ .authority = .here, .slot = 0, .generation = 1 }, .root = &root, .focused = @enumFromInt(3), .fields = &fields });
    try std.testing.expectEqual(@as(usize, 1), rows.len);
    try std.testing.expect(rows[0].focused);
    try std.testing.expectEqual(@as(u16, 8), rows[0].spans[1].column);
    try std.testing.expectEqualStrings("name", rows[0].spans[1].text);
}

test "semantic display escapes hostile raw bytes without changing identity" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings("a\\n\\xFFé", try displayBytes(arena.allocator(), "a\n\xffé"));
}

test "field presentation preserves kind styling, suffix, and escaped selection positions" {
    const view_runtime = @import("weft_view_runtime");
    const Memory = struct {
        pub fn snapshot(_: *@This(), gpa: Allocator) view_runtime.field.Error!view_runtime.field.OwnedSnapshot {
            var result = view_runtime.field.OwnedSnapshot.init(gpa);
            result.value = .{ .revision = "1", .bytes = "a\né", .selection = .{ .anchor = 1, .caret = 4 } };
            return result;
        }
        pub fn edit(_: *@This(), _: []const u8, _: view_runtime.field.Edit) view_runtime.field.Error!void {}
    };
    var memory: Memory = .{};
    var fields = view_runtime.field.Registry.init(.here);
    defer fields.deinit(std.testing.allocator);
    const field = try fields.insert(std.testing.allocator, @enumFromInt(1), .init(&memory));
    const root: semantic.scene.Node = .{
        .id = @enumFromInt(2),
        .facts = &.{ .{ .name = "tone", .value = "accent" }, .{ .name = "suffix", .value = "/" }, .{ .name = "compact-column", .value = "2" }, .{ .name = "compact-below", .value = "60" } },
        .layout = .{ .column = 23 },
        .focusable = true,
        .content = .{ .field = .{ .ref = field } },
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // Focused as a ROW, the field is not being edited: no caret, and no
    // selection to draw one from (doc/chrome.md §5.2).
    const row_focus: data.Document = .{ .view = .{ .authority = .here, .slot = 0, .generation = 1 }, .root = &root, .focused = root.id, .fields = &fields };
    try std.testing.expect((try rowsFor(arena.allocator(), row_focus))[0].spans[0].selection == null);
    var doc = row_focus;
    doc.editing = field;
    const rows = try rowsFor(arena.allocator(), doc);
    const span = rows[0].spans[0];
    try std.testing.expectEqualStrings("a\\né/", span.text);
    try std.testing.expectEqual(Tone.accent, span.tone);
    try std.testing.expectEqual(@as(usize, 1), span.selection.?.anchor);
    try std.testing.expectEqual(@as(usize, 4), span.selection.?.caret);
    try std.testing.expectEqual(@as(u16, 23), span.column);
    try std.testing.expectEqual(@as(?u16, 2), span.compact_column);
    var inactive = doc;
    inactive.active = false;
    const background = try rowsFor(arena.allocator(), inactive);
    try std.testing.expectEqualStrings(span.text, background[0].spans[0].text);
    try std.testing.expect(background[0].spans[0].selection == null);
}
