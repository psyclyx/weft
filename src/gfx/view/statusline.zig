//! Status line + which-key panel — HUD text assembly (always mono).
//!
//! Free functions over `*View`: they read the view's metrics/theme/faces and
//! append runs + rects into the frame's builders. Split out of `view.zig`;
//! `build` calls `buildHud`. The line is the pane's composed segments
//! (`Hud.statusline_segs`), placed by `status_layout` — which of them fit,
//! in which form — and each drawn as a chrome role (`chrome.zig`).

const std = @import("std");
const Allocator = std.mem.Allocator;

const text_engine = @import("weft_text");
const region = @import("../region.zig");
const view = @import("../view.zig");

const View = view.View;
const Run = view.Run;
const Rect = view.Rect;
const Hud = view.Hud;
const ChromeHit = @import("hud.zig").ChromeHit;
const chrome_mod = @import("chrome.zig");
const ui_mesh = @import("ui_mesh.zig");
const status_layout = @import("status_layout.zig");

/// Where `buildHud` files the status segments' hit regions: the pane's
/// chrome list, in the view's frame arena.
pub const ChromeSink = struct {
    list: *std.ArrayList(ChromeHit),
    gpa: Allocator,
    /// The pane whose context the segments describe, when it is not the one
    /// they are drawn in (`Hud.status_of`): a click acts there.
    of: ?u32 = null,

    fn segment(self: ChromeSink, v: *const View, y: f32, index: usize, from: usize, to: usize, command: []const u8, label: []const u8) !void {
        if (to <= from) return;
        try self.list.append(self.gpa, .{
            .rect = v.cellsRect(y, from, to - from),
            .kind = .status,
            .index = index,
            // Copied into the frame arena with the hit: the segment's command
            // is borrowed from a plugin answer the loop may replace before a
            // click reads this.
            .command = if (command.len == 0) "" else try self.gpa.dupe(u8, command),
            .pane = self.of,
            .label = try self.gpa.dupe(u8, label),
        });
    }
};

/// Baseline for local row `i` within a region whose top is `rect_y`.
fn baseIn(v: *const View, rect_y: f32, i: usize) f32 {
    return rect_y + v.ascent + @as(f32, @floatFromInt(i)) * v.line_h;
}

pub fn buildHud(
    v: *View,
    scratch: Allocator,
    runs: *std.ArrayList(Run),
    rects: *std.ArrayList(Rect),
    hud: Hud,
    status_rect: region.Rect,
    panel_rect: region.Rect,
    cols_visible: usize,
    chrome: ChromeSink,
) !void {
    // The status line owns `status_rect`; the panel (pick or which-key)
    // owns `panel_rect` directly above it. Both rects were cut from the
    // frame by one carving (build), so a panel physically cannot land on
    // the status line or the body — the class of bug the old
    // rows_total-N arithmetic allowed.
    const base_y = baseIn(v, status_rect.y, 0);
    // The bar is the whole row, edge to edge across the pane: the text sits
    // on the body's columns inside it, the background does not.
    try rects.append(scratch, .{
        .x = status_rect.x,
        .y = status_rect.y,
        .w = status_rect.w,
        .h = status_rect.h,
        .color = v.theme.selection,
    });

    // Every segment, left and right, is measured in the style this frame
    // draws — a chip's padding, an icon's cells — and placed in ONE pass:
    // what does not fit shrinks, then goes, lowest priority first
    // (`status_layout`). So a segment is either drawn whole, drawn short
    // with its `…`, or not drawn; nothing is clipped at the pane's edge.
    const segs = hud.statusline_segs;
    const items = try scratch.alloc(status_layout.Item, segs.len);
    for (segs, items) |seg, *it| it.* = .{
        .side = if (seg.align_right) .right else .left,
        .priority = seg.priority,
        .full = cellsOf(v, seg, seg.text),
        .compact = if (seg.compact.len > 0) cellsOf(v, seg, seg.compact) else null,
        .elide = seg.elide,
    };
    const placed = try scratch.alloc(status_layout.Placed, segs.len);
    status_layout.layout(items, cols_visible, placed);

    const row_y = status_rect.y;
    for (segs, placed, 0..) |seg, p, index| {
        if (p.form == .dropped) continue;
        const drawn = try drawSegment(v, scratch, runs, rects, seg, p, base_y, lookOf(v, hud, seg, index));
        try chrome.segment(v, row_y, index, p.col, p.col + p.cols, seg.command, drawn);
    }

    // which-key host fallback: a chord is pending and no pick is open — list
    // the prefix mode's bindings in the reserved panel region. (The picker is
    // drawn separately as a window-bottom overlay, so it isn't here.)
    if (hud.which_key) |wk| {
        const shown = @min(wk.len, Hud.max_wk_rows);
        const header = try std.fmt.allocPrint(scratch, "  {s} —", .{hud.mode});
        try appendPlainRun(v, scratch, runs, rects, header, baseIn(v, panel_rect.y, 0), cols_visible, v.theme.accent, null);
        for (0..shown) |i| {
            const l = try std.fmt.allocPrint(scratch, "  {s}  {s}", .{ wk[i].key, wk[i].command });
            try appendPlainRun(v, scratch, runs, rects, l, baseIn(v, panel_rect.y, 1 + i), cols_visible, v.theme.status, null);
        }
    }
}

/// How one segment is drawn: its chrome role and state, and its icon.
const Look = struct {
    role: chrome_mod.Role = .status_segment,
    bg: ?[4]f32 = null,
    hover: bool = false,
};

/// A mesh segment's look: a chip when it brings its own background, lit
/// when the pointer rests on it and a click would run something.
fn lookOf(v: *View, hud: Hud, seg: ui_mesh.Seg, index: usize) Look {
    const hover = seg.command.len != 0 and hud.pointer.onChrome(.status, index, .body);
    if (hud.pointer.onChrome(.status, index, .body) and hud.pointer.tooltip and (seg.tooltip.len != 0 or seg.command.len != 0))
        v.build_tip = .{ .label = if (seg.tooltip.len != 0) seg.tooltip else seg.command, .command = seg.command };
    return .{
        .role = if (seg.bg_override != null) .chip else .status_segment,
        .bg = seg.bg_override,
        .hover = hover,
    };
}

/// Where a segment's icon goes under the view's style: nowhere (a style that
/// draws none, a set without it), in place of the text's leading glyph when
/// that glyph stands alone (`● `, `✦ 2`) — the same cells either way — or in
/// two cells of its own before the text.
const IconPlace = enum { none, stands_in, before };

fn iconPlace(v: *const View, seg: ui_mesh.Seg, text: []const u8) IconPlace {
    if (seg.icon.len == 0 or v.icon(seg.icon) == null) return .none;
    const lead = std.unicode.utf8ByteSequenceLength(if (text.len > 0) text[0] else ' ') catch return .before;
    if (text.len > 0 and text[0] != ' ' and (lead == text.len or (lead < text.len and text[lead] == ' '))) return .stands_in;
    return .before;
}

/// The cells `text` takes as `seg` under the view's style: a chip's padding
/// cell either side, and an icon's two when it stands before the text.
fn cellsOf(v: *const View, seg: ui_mesh.Seg, text: []const u8) usize {
    const pad: usize = if (seg.bg_override != null) 2 else 0;
    const icon: usize = if (iconPlace(v, seg, text) == .before) 2 else 0;
    return status_layout.cells(text) + pad + icon;
}

/// Draw one placed segment: its role's look (a chip's background, a hover
/// wash) under exactly its cells, its icon, and its text — the form the
/// layout chose, cut to its `…` when it was elided. Returns that text.
fn drawSegment(
    v: *View,
    scratch: Allocator,
    runs: *std.ArrayList(Run),
    rects: *std.ArrayList(Rect),
    seg: ui_mesh.Seg,
    p: status_layout.Placed,
    baseline_y: f32,
    look: Look,
) ![]const u8 {
    const form_text = if (p.compact) seg.compact else seg.text;
    const pad: usize = if (seg.bg_override != null) 1 else 0;
    const icon = iconPlace(v, seg, form_text);
    const icon_cells: usize = if (icon == .before) 2 else 0;
    const room = p.cols -| (2 * pad + icon_cells);
    const cut_buf = try scratch.alloc(u8, form_text.len + status_layout.ellipsis.len);
    const shown = status_layout.cut(cut_buf, form_text, room, if (p.form == .elided) seg.elide else .none);
    var text = shown;

    const box = v.cellsRect(baseline_y - v.ascent, p.col, p.cols);
    const sink: chrome_mod.Sink = .{ .v = v, .scratch = scratch, .runs = runs, .rects = rects };
    try chrome_mod.paint(sink, look.role, .{ .hover = look.hover }, .{ .bg = look.bg }, box);

    const color = seg.fg_override orelse v.theme.roleColor(seg.role);
    var col = p.col + pad;
    const cy = box.y + v.line_h / 2;
    switch (icon) {
        .none => {},
        .before => {
            _ = try chrome_mod.drawIcon(sink, seg.icon, v.origin_x + (@as(f32, @floatFromInt(col)) + 0.5) * v.cell_w, cy, chrome_mod.iconSide(v), color);
            col += icon_cells;
        },
        // In the glyph's own cell, the glyph blanked (a space keeps the cell,
        // so every later column holds).
        .stands_in => if (text.len > 0) {
            _ = try chrome_mod.drawIcon(sink, seg.icon, v.origin_x + (@as(f32, @floatFromInt(col)) + 0.5) * v.cell_w, cy, chrome_mod.iconSide(v), color);
            const len = std.unicode.utf8ByteSequenceLength(text[0]) catch 1;
            text = try std.mem.concat(scratch, u8, &.{ " ", text[@min(text.len, len)..] });
        },
    }
    try cellRun(v, scratch, runs, text, col, baseline_y, color);
    return shown;
}

/// `text` as mono cells from column `start_col` (from `origin_x`), one cell
/// per codepoint.
fn cellRun(v: *View, scratch: Allocator, runs: *std.ArrayList(Run), text: []const u8, start_col: usize, baseline_y: f32, color: [4]f32) !void {
    if (text.len == 0) return;
    var cells: std.ArrayList(text_engine.Cell) = .empty;
    var it = (std.unicode.Utf8View.init(text) catch return).iterator();
    var col = start_col;
    var byte: usize = 0;
    while (it.nextCodepointSlice()) |s| : (col += 1) {
        try cells.append(scratch, .{
            .source = .{ .start = @intCast(byte), .end = @intCast(byte + s.len) },
            .column = @intCast(col),
            .color = color,
        });
        byte += s.len;
    }
    if (cells.items.len == 0) return;
    const shaped = try text_engine.shape(scratch, &v.face_set.mono, text[0..byte], .{});
    try runs.append(scratch, .{ .shaped = shaped, .baseline_y = baseline_y, .place = .{ .cell = cells.items } });
}

/// A HUD text run: mono cells truncated at the viewport, optionally over
/// a full-width background rect.
pub fn appendPlainRun(
    v: *View,
    scratch: Allocator,
    runs: *std.ArrayList(Run),
    rects: *std.ArrayList(Rect),
    text: []const u8,
    baseline_y: f32,
    cols_visible: usize,
    color: [4]f32,
    bg: ?[4]f32,
) !void {
    if (bg) |bgc| {
        try rects.append(scratch, .{
            .x = v.origin_x,
            .y = baseline_y - v.ascent,
            .w = @as(f32, @floatFromInt(cols_visible)) * v.cell_w,
            .h = v.line_h,
            .color = bgc,
        });
    }
    var cells: std.ArrayList(text_engine.Cell) = .empty;
    var it = (std.unicode.Utf8View.init(text) catch return error.InvalidUtf8).iterator();
    var col: usize = 0;
    var byte: usize = 0;
    while (it.nextCodepointSlice()) |s| : (col += 1) {
        if (col >= cols_visible) break;
        try cells.append(scratch, .{
            .source = .{ .start = @intCast(byte), .end = @intCast(byte + s.len) },
            .column = @intCast(col),
            .color = color,
        });
        byte += s.len;
    }
    if (cells.items.len == 0) return;
    const shaped = try text_engine.shape(scratch, &v.face_set.mono, text[0..byte], .{});
    try runs.append(scratch, .{ .shaped = shaped, .baseline_y = baseline_y, .place = .{ .cell = cells.items } });
}
