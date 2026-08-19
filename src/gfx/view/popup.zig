//! Floating overlays — the picker dock/popup, hover box, and plugin surfaces.
//!
//! Free functions over `*View`: each measures a box, clamps it inside the
//! region it was handed, and appends the outline + rows into the frame
//! builders. Split out of `view.zig`; `build` calls them after the body and
//! HUD so they float above everything. `outlinedBox` is the shared frame.

const std = @import("std");
const Allocator = std.mem.Allocator;

const snail = @import("snail");
const core = @import("../../core/core.zig");
const region = @import("../region.zig");
const view = @import("../view.zig");

const View = view.View;
const Run = view.Run;
const Rect = view.Rect;
const Hud = view.Hud;

/// Draw the picker INTO its carved `dock` region (a window-bottom strip cut
/// off the frame with `cutBottom`, so it never overlaps the panes or a
/// status line — the region system's whole point). Every position is
/// relative to `dock`, whose height is exactly `pickDockHeight`, so nothing
/// spills. It receives its OWN rect, never the whole window.
pub fn drawPickInto(
    v: *View,
    scratch: Allocator,
    runs: *std.ArrayList(Run),
    rects: *std.ArrayList(Rect),
    p: *const core.Pick,
    dock: region.Rect,
) !void {
    if (dock.h <= 0) return;
    const total = p.filtered.items.len;
    const shown = @min(total, Hud.max_pick_rows);
    // A thin top rule sets the picker dock off from the panes above it.
    try rects.append(scratch, .{ .x = dock.x, .y = dock.y, .w = dock.w, .h = dock.h, .color = v.theme.selection });
    try rects.append(scratch, .{ .x = dock.x, .y = dock.y, .w = dock.w, .h = 1, .color = v.theme.accent });

    const narrow_chip = if (p.narrow.items.len > 0)
        try std.fmt.allocPrint(scratch, "[{s}]", .{p.narrow.items})
    else
        "";
    const query = try std.fmt.allocPrint(scratch, "  {s}{s}> {s}_   [{d}/{d}] ·{s}", .{
        p.prompt,                              narrow_chip, p.query.items,
        if (total == 0) 0 else p.selected + 1, total,       @tagName(p.style),
    });
    try propLine(v, scratch, runs, query, dock.x, dock.y + v.ascent, v.theme.foreground);

    const start = if (p.selected >= shown) p.selected + 1 - shown else 0;
    for (0..shown) |i| {
        const fi = start + i;
        const item = p.items.items[p.filtered.items[fi]];
        const doc = p.docOf(fi);
        const l = if (doc.len > 0)
            try std.fmt.allocPrint(scratch, "  {s}  · {s}", .{ item, doc })
        else
            try std.fmt.allocPrint(scratch, "  {s}", .{item});
        const row_y = dock.y + @as(f32, @floatFromInt(1 + i)) * v.line_h;
        const selected = fi == p.selected;
        if (selected) try rects.append(scratch, .{ .x = dock.x, .y = row_y, .w = dock.w, .h = v.line_h, .color = v.theme.accent });
        try propLine(v, scratch, runs, l, dock.x, row_y + v.ascent, if (selected) v.theme.background else v.theme.status);
    }
}

/// Draw a completion pick as a popup anchored at the caret (byte offset
/// `off`): a small outlined box of candidates just below the caret line
/// (flipped above if it would overflow the body), the selected row
/// highlighted. No query line — the query is what you're typing in the
/// buffer. Skips if the anchor line is off-screen or there are no rows.
pub fn drawPickAtCaret(
    v: *View,
    scratch: Allocator,
    runs: *std.ArrayList(Run),
    rects: *std.ArrayList(Rect),
    p: *const core.Pick,
    off: usize,
    body: region.Rect,
) !void {
    const total = p.filtered.items.len;
    if (total == 0) return;
    const li = v.frame_layout.lineForOffset(off) orelse return; // off-screen
    const c = v.frame_layout.lines[li].caretAt(off);

    const shown = @min(total, Hud.max_pick_rows);
    const start = if (p.selected >= shown) p.selected + 1 - shown else 0;
    var max_cols: usize = 8;
    for (0..shown) |i| {
        const item = p.items.items[p.filtered.items[start + i]];
        max_cols = @max(max_cols, std.unicode.utf8CountCodepoints(item) catch item.len);
    }
    const box_w = @as(f32, @floatFromInt(max_cols + 2)) * v.cell_w;
    const box_h = @as(f32, @floatFromInt(shown)) * v.line_h;
    const box_x = std.math.clamp(c.x, body.x, @max(body.x, body.x + body.w - box_w));
    var box_y = c.y_top + c.height; // just below the caret line
    if (box_y + box_h > body.y + body.h) box_y = c.y_top - box_h; // flip above
    box_y = std.math.clamp(box_y, body.y, @max(body.y, body.y + body.h - box_h));
    try outlinedBox(scratch, rects, box_x, box_y, box_w, box_h, v.theme.selection, v.theme.accent);

    for (0..shown) |i| {
        const fi = start + i;
        const item = p.items.items[p.filtered.items[fi]];
        const row_y = box_y + @as(f32, @floatFromInt(i)) * v.line_h;
        const selected = fi == p.selected;
        if (selected) try rects.append(scratch, .{ .x = box_x, .y = row_y, .w = box_w, .h = v.line_h, .color = v.theme.accent });
        try propLine(v, scratch, runs, item, box_x + v.cell_w, row_y + v.ascent, if (selected) v.theme.background else v.theme.foreground);
    }
}

/// Draw hover text (LSP) as an outlined box anchored below the caret at
/// `off` (flipping above when it would overflow the body). Multi-line: the
/// text is split on '\n', capped to `max_hover_rows`, each line rendered as
/// a mono run. Off-screen caret ⇒ nothing (same rule as the caret popup).
pub fn drawHoverAtCaret(
    v: *View,
    scratch: Allocator,
    runs: *std.ArrayList(Run),
    rects: *std.ArrayList(Rect),
    text: []const u8,
    off: usize,
    body: region.Rect,
) !void {
    if (text.len == 0) return;
    const li = v.frame_layout.lineForOffset(off) orelse return; // off-screen
    const c = v.frame_layout.lines[li].caretAt(off);

    var rows: usize = 0;
    var max_cols: usize = 8;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| : (rows += 1) {
        if (rows >= Hud.max_hover_rows) break;
        max_cols = @max(max_cols, std.unicode.utf8CountCodepoints(line) catch line.len);
    }
    if (rows == 0) return;

    const box_w = @as(f32, @floatFromInt(max_cols + 2)) * v.cell_w;
    const box_h = @as(f32, @floatFromInt(rows)) * v.line_h;
    const box_x = std.math.clamp(c.x, body.x, @max(body.x, body.x + body.w - box_w));
    var box_y = c.y_top + c.height; // just below the caret line
    if (box_y + box_h > body.y + body.h) box_y = c.y_top - box_h; // flip above
    box_y = std.math.clamp(box_y, body.y, @max(body.y, body.y + body.h - box_h));
    try outlinedBox(scratch, rects, box_x, box_y, box_w, box_h, v.theme.selection, v.theme.accent);

    var line_it = std.mem.splitScalar(u8, text, '\n');
    var i: usize = 0;
    while (line_it.next()) |line| : (i += 1) {
        if (i >= rows) break;
        const row_y = box_y + @as(f32, @floatFromInt(i)) * v.line_h;
        try propLine(v, scratch, runs, line, box_x + v.cell_w, row_y + v.ascent, v.theme.foreground);
    }
}

/// A filled box with a 1px outline: the border rect (1px larger all round)
/// drawn first, the fill on top, so the border reads as a thin frame.
pub fn outlinedBox(scratch: Allocator, rects: *std.ArrayList(Rect), x: f32, y: f32, w: f32, h: f32, fill: [4]f32, border: [4]f32) !void {
    try rects.append(scratch, .{ .x = x - 1, .y = y - 1, .w = w + 2, .h = h + 2, .color = border });
    try rects.append(scratch, .{ .x = x, .y = y, .w = w, .h = h, .color = fill });
}

/// Shape `text` as one mono run at an explicit world x/baseline + color (a
/// `.prop` placement — independent of the pane's content origin).
pub fn propLine(v: *View, scratch: Allocator, runs: *std.ArrayList(Run), text: []const u8, x: f32, baseline_y: f32, color: [4]f32) !void {
    const shaped = try snail.shape(scratch, &v.face_set.mono, text, .{});
    try runs.append(scratch, .{ .shaped = shaped, .baseline_y = baseline_y, .place = .{ .prop = .{ .x = x, .em = v.em, .color = color } } });
}

/// Draw retained plugin overlays (surfaces) as floating boxes. corner docks
/// top-right of the pane, center is centered; bottom is left to the dock
/// (buildHud) and skipped here. Each row's spans render at their own color
/// (by Role), and a `selected` row gets a highlight behind it. Overlays are
/// drawn last, so they sit above the body — and, being boxes with their own
/// background, they don't reflow it.
pub fn drawSurfaces(
    v: *View,
    scratch: Allocator,
    runs: *std.ArrayList(Run),
    rects: *std.ArrayList(Rect),
    hud: Hud,
    body: region.Rect,
    caret_y: ?f32,
) !void {
    // A surface floats within `body`; cap the row count to what fits, so a
    // popup can never extend past the region it was handed.
    const max_rows = @max(1, @as(usize, @intFromFloat(@max(0, body.h) / v.line_h)) -| 1);
    for (hud.surfaces) |surf| {
        if (!surf.active or surf.rows.items.len == 0) continue;
        if (surf.placement == .bottom) continue; // dock handled by buildHud

        const nrows = @min(surf.rows.items.len, max_rows);
        // Width = widest row, in cells (one space between spans).
        var max_cols: usize = 0;
        for (surf.rows.items[0..nrows]) |row| {
            var cols: usize = 0;
            for (row.spans.items, 0..) |sp, si| {
                if (si != 0) cols += 1;
                cols += std.unicode.utf8CountCodepoints(sp.text) catch sp.text.len;
            }
            max_cols = @max(max_cols, cols);
        }
        const pad_x: f32 = v.cell_w;
        const pad_y: f32 = v.line_h * 0.25;
        const box_w = @as(f32, @floatFromInt(max_cols)) * v.cell_w + 2 * pad_x;
        const box_h = @as(f32, @floatFromInt(nrows)) * v.line_h + 2 * pad_y;
        // Positioned within `body`, then clamped so the box stays inside it
        // (its own background reads as a popup over the text, never over the
        // status/tab strips, which live outside `body`).
        // A corner surface docks top-right by default, but gets out of the
        // way of the caret: if the caret sits in the top half of the body
        // (where the box would land), it flips to the bottom-right instead,
        // so a which-key popup never covers the line you're editing.
        const corner_top = if (caret_y) |cy|
            cy > body.y + body.h / 2
        else
            true;
        const raw_x, const raw_y = switch (surf.placement) {
            .corner => .{
                body.x + body.w - box_w - pad_x,
                if (corner_top) body.y + pad_x else body.y + body.h - box_h - pad_x,
            },
            .center => .{ body.x + (body.w - box_w) / 2, body.y + (body.h - box_h) / 2 },
            .bottom => unreachable,
        };
        const box_x = std.math.clamp(raw_x, body.x, @max(body.x, body.x + body.w - box_w));
        const box_y = std.math.clamp(raw_y, body.y, @max(body.y, body.y + body.h - box_h));
        // Panel background with a thin accent outline, so the popup reads
        // as a distinct floating box (not text bleeding over the buffer).
        try outlinedBox(scratch, rects, box_x, box_y, box_w, box_h, v.theme.selection, v.theme.accent);

        for (surf.rows.items[0..nrows], 0..) |row, i| {
            const row_y = box_y + pad_y + @as(f32, @floatFromInt(i)) * v.line_h;
            if (surf.selected != null and surf.selected.? == i) {
                try rects.append(scratch, .{ .x = box_x, .y = row_y, .w = box_w, .h = v.line_h, .color = v.theme.accent });
            }
            var x = box_x + pad_x;
            const baseline = row_y + v.ascent;
            for (row.spans.items, 0..) |sp, si| {
                if (si != 0) x += v.cell_w; // gap between spans
                const shaped = try snail.shape(scratch, &v.face_set.mono, sp.text, .{});
                try runs.append(scratch, .{
                    .shaped = shaped,
                    .baseline_y = baseline,
                    .place = .{ .prop = .{ .x = x, .em = v.em, .color = v.theme.roleColor(sp.role) } },
                });
                x += shaped.advanceX() * v.em;
            }
        }
    }
}
