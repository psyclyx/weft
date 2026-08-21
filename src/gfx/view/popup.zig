//! Floating overlays — the picker dock/popup, hover box, and plugin surfaces.
//!
//! Free functions over `*View`: each measures a box, clamps it inside the
//! region it was handed, and appends the outline + rows into the frame
//! builders. Split out of `view.zig`; `build` calls them after the body and
//! HUD so they float above everything. `outlinedBox` is the shared frame.
//!
//! Two anchoring styles, ONE layout primitive each: `drawSurfaces` lays out
//! the corner/center plugin overlays (which-key, dired, magit); the caret
//! popups (completion + its docs box, hover) are `core.surface.Surface`s
//! with `.caret` placement — built fresh every frame by `pickSurface`/
//! `hoverSurface` from the live `Pick`/hover text — laid out and drawn by
//! the ONE generic `drawCaretSurface` (flip-above/clamp, column alignment,
//! selected-row styling, the linked info panel). `drawPick`/`drawHover` are
//! the thin per-caller entry points `View.build` calls.

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

/// Build a caret-anchored completion `Surface` from a live `Pick`'s current
/// scroll window: column 0 = the candidate text, column 1 = its dimmed
/// kind/detail note (when present, empty rows skip it — matching notes
/// still align because the renderer sizes column 1 from whichever rows DO
/// carry one). The selected row's full doc becomes the linked `info` panel.
/// Scratch-owned (arena) — rebuilt fresh every frame, never retained past
/// it. Null when there's nothing to show (no filtered candidates).
fn pickSurface(scratch: Allocator, p: *const core.Pick, off: usize) ?core.surface.Surface {
    const total = p.filtered.items.len;
    if (total == 0) return null;
    const shown = @min(total, Hud.max_pick_rows);
    const start = if (p.selected >= shown) p.selected + 1 - shown else 0;

    var surf: core.surface.Surface = .{};
    surf.begin(scratch, .caret);
    for (0..shown) |i| {
        const idx = p.filtered.items[start + i];
        surf.addRow(scratch);
        surf.addSpanCol(scratch, p.items.items[idx], .normal, 0);
        if (idx < p.docs.items.len) {
            const note = p.docs.items[idx];
            if (note.len > 0) surf.addSpanCol(scratch, note, .normal, 1);
        }
    }
    surf.end(scratch, p.selected - start);
    surf.anchor = off;
    surf.setInfo(scratch, p.selectedInfo());
    return surf;
}

/// Build a caret-anchored hover `Surface` from plain (LSP) text: one row per
/// line (capped to `max_hover_rows`), column 0 only, no selection. Null for
/// empty text.
fn hoverSurface(scratch: Allocator, text: []const u8, off: usize) ?core.surface.Surface {
    if (text.len == 0) return null;
    var surf: core.surface.Surface = .{};
    surf.begin(scratch, .caret);
    var rows: usize = 0;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| : (rows += 1) {
        if (rows >= Hud.max_hover_rows) break;
        surf.addRow(scratch);
        surf.addSpanCol(scratch, line, .normal, 0);
    }
    if (rows == 0) return null;
    surf.end(scratch, null);
    surf.anchor = off;
    return surf;
}

/// Build + draw the completion popup at `p`'s caret anchor, if it has one
/// and there's anything to show. The single entry point `View.build` calls;
/// the completion docs box is part of the same surface (its `info` panel).
pub fn drawPick(v: *View, scratch: Allocator, runs: *std.ArrayList(Run), rects: *std.ArrayList(Rect), p: *const core.Pick, off: usize, body: region.Rect) !void {
    if (pickSurface(scratch, p, off)) |surf| try drawCaretSurface(v, scratch, runs, rects, &surf, body);
}

/// Build + draw the hover box at `off`, if `text` is non-empty.
pub fn drawHover(v: *View, scratch: Allocator, runs: *std.ArrayList(Run), rects: *std.ArrayList(Rect), text: []const u8, off: usize, body: region.Rect) !void {
    if (hoverSurface(scratch, text, off)) |surf| try drawCaretSurface(v, scratch, runs, rects, &surf, body);
}

/// Draw a `caret`-placed `Surface` — the ONE generic layout `drawPickAtCaret`
/// and `drawHoverAtCaret` used to hardcode separately: resolve the anchor's
/// caret geometry, flip the box above the line (else clamp into `body`) when
/// it would overflow, align every row's spans into their declared COLUMNS
/// (0 = main content — an 8-cell floor so a short list never looks cramped;
/// 1+ = a dimmed annotation, sized to whichever rows carry one), highlight
/// the selected row (forcing its text to the box background for legibility
/// against the accent fill), and — if the surface carries `info` — place a
/// linked side panel beside it (right, else left), multi-line and capped.
/// A missing/off-screen anchor or an empty surface draws nothing.
pub fn drawCaretSurface(
    v: *View,
    scratch: Allocator,
    runs: *std.ArrayList(Run),
    rects: *std.ArrayList(Rect),
    surf: *const core.surface.Surface,
    body: region.Rect,
) !void {
    const nrows = surf.rows.items.len;
    if (nrows == 0) return;
    const off = surf.anchor orelse return;
    const li = v.frame_layout.lineForOffset(off) orelse return; // off-screen
    const c = v.frame_layout.lines[li].caretAt(off);

    // Column widths in codepoints, across every row. Column 0 floors at 8
    // (matches the old hardcoded `max_item`/`max_cols` floor); other columns
    // size purely to their content, so an all-empty note column costs nothing.
    var ncols: usize = 1;
    for (surf.rows.items) |row| for (row.spans.items) |sp| {
        ncols = @max(ncols, @as(usize, sp.column) + 1);
    };
    const col_w = try scratch.alloc(usize, ncols);
    @memset(col_w, 0);
    col_w[0] = 8;
    for (surf.rows.items) |row| for (row.spans.items) |sp| {
        const w = std.unicode.utf8CountCodepoints(sp.text) catch sp.text.len;
        col_w[sp.column] = @max(col_w[sp.column], w);
    };
    // Lay columns left→right: 1-cell pad, a 2-cell gap before each column
    // that actually has content, 1-cell pad on the right.
    const col_x = try scratch.alloc(usize, ncols);
    var cursor: usize = 1;
    for (0..ncols) |ci| {
        if (ci > 0 and col_w[ci] > 0) cursor += 2;
        col_x[ci] = cursor;
        cursor += col_w[ci];
    }
    cursor += 1;

    const box_w = @as(f32, @floatFromInt(cursor)) * v.cell_w;
    const box_h = @as(f32, @floatFromInt(nrows)) * v.line_h;
    const box_x = std.math.clamp(c.x, body.x, @max(body.x, body.x + body.w - box_w));
    var box_y = c.y_top + c.height; // just below the caret line
    if (box_y + box_h > body.y + body.h) box_y = c.y_top - box_h; // flip above
    box_y = std.math.clamp(box_y, body.y, @max(body.y, body.y + body.h - box_h));
    try outlinedBox(scratch, rects, box_x, box_y, box_w, box_h, v.theme.selection, v.theme.accent);

    for (surf.rows.items, 0..) |row, i| {
        const row_y = box_y + @as(f32, @floatFromInt(i)) * v.line_h;
        const selected = surf.selected != null and surf.selected.? == i;
        if (selected) try rects.append(scratch, .{ .x = box_x, .y = row_y, .w = box_w, .h = v.line_h, .color = v.theme.accent });
        for (row.spans.items) |sp| {
            const x = box_x + @as(f32, @floatFromInt(col_x[sp.column])) * v.cell_w;
            // Column 0 reads through the span's semantic role; column 1+ is
            // a dimmed ANNOTATION by construction (the completion note) —
            // comment gray, unless the selected row's accent fill forces
            // every column to the box background instead, for legibility.
            const color = if (selected)
                v.theme.background
            else if (sp.column == 0)
                v.theme.roleColor(sp.role)
            else
                v.theme.syn_comment;
            try propLine(v, scratch, runs, sp.text, x, row_y + v.ascent, color);
        }
    }

    // The linked side panel (e.g. the selected row's full docs): beside the
    // box (right, else left if it would overflow the body). Multi-line, capped.
    if (surf.info.len > 0) {
        var irows: usize = 0;
        var icols: usize = 8;
        var it = std.mem.splitScalar(u8, surf.info, '\n');
        while (it.next()) |line| : (irows += 1) {
            if (irows >= Hud.max_hover_rows) break;
            icols = @max(icols, @min(64, std.unicode.utf8CountCodepoints(line) catch line.len));
        }
        if (irows > 0) {
            const iw = @as(f32, @floatFromInt(icols + 2)) * v.cell_w;
            const ih = @as(f32, @floatFromInt(irows)) * v.line_h;
            var ix = box_x + box_w + v.cell_w; // to the right of the list
            if (ix + iw > body.x + body.w) ix = @max(body.x, box_x - iw - v.cell_w); // flip left
            const iy = std.math.clamp(box_y, body.y, @max(body.y, body.y + body.h - ih));
            try outlinedBox(scratch, rects, ix, iy, iw, ih, v.theme.selection, v.theme.accent);
            var lit = std.mem.splitScalar(u8, surf.info, '\n');
            var k: usize = 0;
            while (lit.next()) |line| : (k += 1) {
                if (k >= irows) break;
                const ly = iy + @as(f32, @floatFromInt(k)) * v.line_h + v.ascent;
                try propLine(v, scratch, runs, line, ix + v.cell_w, ly, v.theme.foreground);
            }
        }
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
        // `bottom` is the dock (buildHud); `caret` surfaces (completion,
        // hover) float at a doc offset through `drawCaretSurface` instead —
        // this loop only lays out the corner/center overlays. NOTE (P2): a
        // GUEST-emitted `.caret` surface in `hud.surfaces` is silently skipped
        // here today — no such producer exists yet; when P2 opens the caret
        // door to plugins, route these through `drawCaretSurface` instead of
        // letting this skip drop them.
        if (surf.placement == .bottom or surf.placement == .caret) continue;

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
            .bottom, .caret => unreachable, // skipped above
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
