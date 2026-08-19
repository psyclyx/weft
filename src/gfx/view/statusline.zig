//! Status line + which-key panel — HUD text assembly (always mono).
//!
//! Free functions over `*View`: they read the view's metrics/theme/faces and
//! append runs + rects into the frame's builders. Split out of `view.zig`;
//! `build` calls `buildHud`, and the tab strip reuses `appendPlainRun`.

const std = @import("std");
const Allocator = std.mem.Allocator;

const snail = @import("snail");
const region = @import("../region.zig");
const view = @import("../view.zig");

const View = view.View;
const Run = view.Run;
const Rect = view.Rect;
const Hud = view.Hud;

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
) !void {
    // The status line owns `status_rect`; the panel (pick or which-key)
    // owns `panel_rect` directly above it. Both rects were cut from the
    // frame by one carving (build), so a panel physically cannot land on
    // the status line or the body — the class of bug the old
    // rows_total-N arithmetic allowed. Segments are color-coded and chain
    // left-to-right from `segRun`; a right-anchored cluster (peers, diag
    // count) is measured backwards from the right edge.
    const base_y = baseIn(v, status_rect.y, 0);
    // Full-width status background so the chips read as one bar.
    try rects.append(scratch, .{
        .x = v.origin_x,
        .y = base_y - v.ascent,
        .w = @as(f32, @floatFromInt(cols_visible)) * v.cell_w,
        .h = v.line_h,
        .color = v.theme.selection,
    });

    var col: usize = 0;
    // Mode chip: colored background, dark text — the loudest indicator.
    const chip = try std.fmt.allocPrint(scratch, " {s} ", .{hud.mode});
    col = try segRun(v, scratch, runs, rects, chip, col, base_y, cols_visible, v.theme.background, v.theme.modeChipColor(hud.mode));
    col += 1;
    if (hud.buffer_pos) |bp| {
        col = try segRun(v, scratch, runs, rects, bp, col, base_y, cols_visible, v.theme.status, null);
        col += 1;
    }
    col = try segRun(v, scratch, runs, rects, hud.file orelse "[scratch]", col, base_y, cols_visible, v.theme.foreground, null);
    if (hud.dirty) col = try segRun(v, scratch, runs, rects, " ●", col, base_y, cols_visible, v.theme.diag_warn, null);
    if (hud.backing) |b| {
        const bk = try std.fmt.allocPrint(scratch, " ({s})", .{b});
        col = try segRun(v, scratch, runs, rects, bk, col, base_y, cols_visible, v.theme.status, null);
    }
    if (hud.save_note) |s| {
        const sn = try std.fmt.allocPrint(scratch, " [{s}]", .{s});
        col = try segRun(v, scratch, runs, rects, sn, col, base_y, cols_visible, v.theme.diag_warn, null);
    }
    if (hud.save_failed) col = try segRun(v, scratch, runs, rects, " [save failed]", col, base_y, cols_visible, v.theme.diag_error, null);
    if (hud.unfetched_pct) |pct| {
        if (pct > 0) {
            const fetched = try std.fmt.allocPrint(scratch, " [{d}% fetched]", .{100 - @as(u32, pct)});
            col = try segRun(v, scratch, runs, rects, fetched, col, base_y, cols_visible, v.theme.diag_warn, null);
        }
    }
    if (hud.link) |l| {
        const lk = try std.fmt.allocPrint(scratch, "  link:{s}", .{l});
        col = try segRun(v, scratch, runs, rects, lk, col, base_y, cols_visible, v.theme.md_link, null);
    }
    if (hud.trust) |tr| {
        const tt = try std.fmt.allocPrint(scratch, "  {s}", .{tr});
        col = try segRun(v, scratch, runs, rects, tt, col, base_y, cols_visible, v.theme.status, null);
    }
    if (hud.echo orelse hud.cursor_diag) |msg| {
        const em = try std.fmt.allocPrint(scratch, "  ·  {s}", .{msg});
        col = try segRun(v, scratch, runs, rects, em, col, base_y, cols_visible, v.theme.foreground, null);
    }

    // Right-anchored cluster: peers then diagnostics, measured backward.
    const status_diag_count = if (hud.diag_layer) |dl| dl.spanCount() else 0;
    var right_segs: std.ArrayList(struct { text: []const u8, color: [4]f32 }) = .empty;
    if (hud.peers > 0)
        try right_segs.append(scratch, .{ .text = try std.fmt.allocPrint(scratch, "✦{d} ", .{hud.peers}), .color = v.theme.accent });
    if (status_diag_count > 0)
        try right_segs.append(scratch, .{ .text = try std.fmt.allocPrint(scratch, "!{d} ", .{status_diag_count}), .color = v.theme.diag_error });
    var right_w: usize = 0;
    for (right_segs.items) |seg| right_w += std.unicode.utf8CountCodepoints(seg.text) catch seg.text.len;
    if (right_w > 0 and right_w < cols_visible) {
        var rcol = cols_visible - right_w;
        if (rcol > col) { // only if it doesn't collide with the left cluster
            for (right_segs.items) |seg|
                rcol = try segRun(v, scratch, runs, rects, seg.text, rcol, base_y, cols_visible, seg.color, null);
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

/// Render one status segment as colored mono cells starting at column
/// `start_col` (from `origin_x`), optionally over a background chip that
/// spans exactly the segment's width. Returns the column just past it, so
/// segments chain left-to-right. Clips at `cols_visible`.
fn segRun(
    v: *View,
    scratch: Allocator,
    runs: *std.ArrayList(Run),
    rects: *std.ArrayList(Rect),
    text: []const u8,
    start_col: usize,
    baseline_y: f32,
    cols_visible: usize,
    color: [4]f32,
    bg: ?[4]f32,
) !usize {
    if (start_col >= cols_visible or text.len == 0) return start_col;
    const w_cols = std.unicode.utf8CountCodepoints(text) catch text.len;
    if (bg) |bgc| {
        const draw_cols = @min(w_cols, cols_visible - start_col);
        try rects.append(scratch, .{
            .x = v.origin_x + @as(f32, @floatFromInt(start_col)) * v.cell_w,
            .y = baseline_y - v.ascent,
            .w = @as(f32, @floatFromInt(draw_cols)) * v.cell_w,
            .h = v.line_h,
            .color = bgc,
        });
    }
    var cells: std.ArrayList(snail.Cell) = .empty;
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
    const shaped = try snail.shape(scratch, &v.face_set.mono, text[0..last_byte], .{});
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
    var cells: std.ArrayList(snail.Cell) = .empty;
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
    const shaped = try snail.shape(scratch, &v.face_set.mono, text[0..byte], .{});
    try runs.append(scratch, .{ .shaped = shaped, .baseline_y = baseline_y, .place = .{ .cell = cells.items } });
}
