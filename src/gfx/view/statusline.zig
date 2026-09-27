//! Status line + which-key panel — HUD text assembly (always mono).
//!
//! Free functions over `*View`: they read the view's metrics/theme/faces and
//! append runs + rects into the frame's builders. Split out of `view.zig`;
//! `build` calls `buildHud`. Each segment is drawn as a chrome role
//! (`chrome.zig`); the columns are this file's.

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

/// Where `buildHud` files the status segments' hit regions: the pane's
/// chrome list, in the view's frame arena.
pub const ChromeSink = struct {
    list: *std.ArrayList(ChromeHit),
    gpa: Allocator,

    fn segment(self: ChromeSink, v: *const View, y: f32, index: usize, from: usize, to: usize, command: []const u8) !void {
        if (to <= from) return;
        try self.list.append(self.gpa, .{
            .rect = v.cellsRect(y, from, to - from),
            .kind = .status,
            .index = index,
            // Copied into the frame arena with the hit: the segment's command
            // is borrowed from a plugin answer the loop may replace before a
            // click reads this.
            .command = if (command.len == 0) "" else try self.gpa.dupe(u8, command),
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
    // rows_total-N arithmetic allowed. Segments are color-coded and chain
    // left-to-right from `segRun`; a right-anchored cluster (peers, diag
    // count) is measured backwards from the right edge.
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

    var col: usize = 0;
    // `ui/statusline-seg` mesh (doc/contextual-workspace-architecture.md
    // §11): mode chip, buffer position, file/path, collab liveness —
    // composed by `frame_builder` in Container total order and rendered here
    // as plain segments. The diagnostics count rides the SAME mesh call but
    // is `align_right`, so it joins the right-anchored cluster below instead
    // of this loop.
    //
    // Every segment is drawn as a chrome ROLE: a plain `status_segment`, or a
    // `chip` when it carries its own background (the mode chip, a save
    // warning). The layout — columns, sides, gaps — stays this file's; the
    // look is the chrome style's (doc/chrome.md §3, §4).
    const row_y = base_y - v.ascent;
    for (hud.statusline_segs, 0..) |seg, index| {
        if (seg.align_right) continue;
        const color = seg.fg_override orelse v.theme.roleColor(seg.role);
        const from = col;
        col = try segRun(v, scratch, runs, rects, seg.text, col, base_y, cols_visible, color, lookOf(v, hud, seg, index));
        try chrome.segment(v, row_y, index, from, col, seg.command);
        col += seg.gap_after; // spacing is the PREDECESSOR's data — see Seg.gap_after's doc
    }
    if (hud.dirty) col = try segRun(v, scratch, runs, rects, " ●", col, base_y, cols_visible, v.theme.diag_warn, .{ .icon = "dot" });
    if (hud.backing) |b| {
        const bk = try std.fmt.allocPrint(scratch, " ({s})", .{b});
        col = try segRun(v, scratch, runs, rects, bk, col, base_y, cols_visible, v.theme.status, .{});
    }
    // Warnings about the save and the checkout are chips — a label on its
    // own colour, never a bracketed word. Each keeps the columns the
    // bracketed form had: one gap, then the chip's own padding.
    if (hud.save_note) |s| col = try chipRun(v, scratch, runs, rects, s, col, base_y, cols_visible, v.theme.diag_warn);
    if (hud.save_failed) col = try chipRun(v, scratch, runs, rects, "save failed", col, base_y, cols_visible, v.theme.diag_error);
    if (hud.unfetched_pct) |pct| {
        if (pct > 0) {
            const fetched = try std.fmt.allocPrint(scratch, "{d}% fetched", .{100 - @as(u32, pct)});
            col = try chipRun(v, scratch, runs, rects, fetched, col, base_y, cols_visible, v.theme.diag_warn);
        }
    }
    if (hud.trust) |tr| {
        const tt = try std.fmt.allocPrint(scratch, "  {s}", .{tr});
        col = try segRun(v, scratch, runs, rects, tt, col, base_y, cols_visible, v.theme.status, .{});
    }
    if (hud.echo orelse hud.cursor_diag) |msg| {
        const em = try std.fmt.allocPrint(scratch, "  ·  {s}", .{msg});
        col = try segRun(v, scratch, runs, rects, em, col, base_y, cols_visible, v.theme.foreground, .{});
    }

    // Right-anchored cluster: peers, then the mesh's right-anchored segments
    // (today: the diagnostics count), measured backward.
    // `index` is a segment's place in the mesh output; null for the chips the
    // mesh does not compose, which are not clickable.
    var right_segs: std.ArrayList(struct { text: []const u8, color: [4]f32, index: ?usize = null, command: []const u8 = "", look: Look = .{} }) = .empty;
    if (hud.plugin_status) |st|
        try right_segs.append(scratch, .{ .text = try std.fmt.allocPrint(scratch, "{s}  ", .{st}), .color = v.theme.accent });
    if (hud.peers > 0)
        try right_segs.append(scratch, .{ .text = try std.fmt.allocPrint(scratch, "✦{d} ", .{hud.peers}), .color = v.theme.accent, .look = .{ .icon = "users" } });
    for (hud.statusline_segs, 0..) |seg, index| {
        if (!seg.align_right) continue;
        try right_segs.append(scratch, .{ .text = seg.text, .color = seg.fg_override orelse v.theme.roleColor(seg.role), .index = index, .command = seg.command, .look = lookOf(v, hud, seg, index) });
    }
    var right_w: usize = 0;
    for (right_segs.items) |seg| right_w += std.unicode.utf8CountCodepoints(seg.text) catch seg.text.len;
    if (right_w > 0 and right_w < cols_visible) {
        var rcol = cols_visible - right_w;
        if (rcol > col) { // only if it doesn't collide with the left cluster
            for (right_segs.items) |seg| {
                const from = rcol;
                rcol = try segRun(v, scratch, runs, rects, seg.text, rcol, base_y, cols_visible, seg.color, seg.look);
                if (seg.index) |index| try chrome.segment(v, row_y, index, from, rcol, seg.command);
            }
        }
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

/// How one segment is drawn: its chrome role and state, and an icon that
/// stands in for its first glyph when the style draws icons (`✦` → the
/// `users` icon), in the same cell, so no column moves.
const Look = struct {
    role: chrome_mod.Role = .status_segment,
    bg: ?[4]f32 = null,
    icon: ?[]const u8 = null,
    hover: bool = false,
};

/// A mesh segment's look: a chip when it brings its own background, lit
/// when the pointer rests on it and a click would run something.
fn lookOf(v: *View, hud: Hud, seg: ui_mesh.Seg, index: usize) Look {
    const hover = seg.command.len != 0 and hud.pointer.onChrome(.status, index, .body);
    if (hover and hud.pointer.tooltip) v.build_tip = .{ .label = if (seg.tooltip.len != 0) seg.tooltip else seg.command, .command = seg.command };
    return .{
        .role = if (seg.bg_override != null) .chip else .status_segment,
        .bg = seg.bg_override,
        .icon = if (seg.icon.len != 0) seg.icon else null,
        .hover = hover,
    };
}

/// A chip after a one-column gap: ` label ` on `bg`, dark text.
fn chipRun(v: *View, scratch: Allocator, runs: *std.ArrayList(Run), rects: *std.ArrayList(Rect), label: []const u8, start_col: usize, baseline_y: f32, cols_visible: usize, bg: [4]f32) !usize {
    const padded = try std.fmt.allocPrint(scratch, " {s} ", .{label});
    return segRun(v, scratch, runs, rects, padded, start_col + 1, baseline_y, cols_visible, v.theme.background, .{ .role = .chip, .bg = bg });
}

/// Render one status segment as colored mono cells starting at column
/// `start_col` (from `origin_x`), its role's look (a chip's background, a
/// hover wash) under exactly the segment's width. Returns the column just
/// past it, so segments chain left-to-right. Clips at `cols_visible`.
fn segRun(
    v: *View,
    scratch: Allocator,
    runs: *std.ArrayList(Run),
    rects: *std.ArrayList(Rect),
    text_in: []const u8,
    start_col: usize,
    baseline_y: f32,
    cols_visible: usize,
    color: [4]f32,
    look: Look,
) !usize {
    if (start_col >= cols_visible or text_in.len == 0) return start_col;
    var text = text_in;
    const w_cols = std.unicode.utf8CountCodepoints(text) catch text.len;
    const draw_cols = @min(w_cols, cols_visible - start_col);
    const box: region.Rect = .{
        .x = v.origin_x + @as(f32, @floatFromInt(start_col)) * v.cell_w,
        .y = baseline_y - v.ascent,
        .w = @as(f32, @floatFromInt(draw_cols)) * v.cell_w,
        .h = v.line_h,
    };
    const sink: chrome_mod.Sink = .{ .v = v, .scratch = scratch, .runs = runs, .rects = rects };
    try chrome_mod.paint(sink, look.role, .{ .hover = look.hover }, .{ .bg = look.bg }, box);
    // An icon for the first visible glyph: drawn in its cell, and the glyph
    // blanked (a space keeps the cell, so every later column holds).
    if (look.icon) |name| if (v.icon(name) != null) {
        const lead = std.mem.indexOfNone(u8, text, " ") orelse text.len;
        if (lead < text.len and lead < draw_cols) {
            const len = std.unicode.utf8ByteSequenceLength(text[lead]) catch 1;
            const cx = box.x + (@as(f32, @floatFromInt(lead)) + 0.5) * v.cell_w;
            _ = try chrome_mod.drawIcon(sink, name, cx, box.y + v.line_h / 2, chrome_mod.iconSide(v), color);
            text = try std.mem.concat(scratch, u8, &.{ text[0..lead], " ", text[@min(text.len, lead + len)..] });
        }
    };
    var cells: std.ArrayList(text_engine.Cell) = .empty;
    var it = (std.unicode.Utf8View.init(text) catch return start_col).iterator();
    var col = start_col;
    var byte: usize = 0;
    var last_byte: usize = 0;
    while (it.nextCodepointSlice()) |s| : (col += 1) {
        if (col >= cols_visible) break;
        try cells.append(scratch, .{
            .source = .{ .start = @intCast(byte), .end = @intCast(byte + s.len) },
            .column = @intCast(col),
            .color = color,
        });
        byte += s.len;
        last_byte = byte;
    }
    if (cells.items.len == 0) return start_col;
    const shaped = try text_engine.shape(scratch, &v.face_set.mono, text[0..last_byte], .{});
    try runs.append(scratch, .{ .shaped = shaped, .baseline_y = baseline_y, .place = .{ .cell = cells.items } });
    return col;
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
