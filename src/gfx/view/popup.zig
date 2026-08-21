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
//! `hoverSurface` from the live `Pick`/hover text, LAID OUT by
//! `layoutCaretSurface` (the introspection seam — geometry + content as
//! data, asserted by the popup-layout e2e gate instead of raw pixels), and
//! drawn by the thin `drawCaretSurface`. `drawPick`/`drawHover` are the
//! thin per-caller entry points `View.build` calls.

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
/// it. Null when there's nothing to show (no filtered candidates). `pub`
/// so the popup-layout e2e gate (src/e2e/popup_layout_test.zig) can drive
/// the real `pickSurface` → `layoutCaretSurface` path from a live `Pick`,
/// instead of hand-building a `Surface`.
pub fn pickSurface(scratch: Allocator, p: *const core.Pick, off: usize) ?core.surface.Surface {
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
/// empty text. `pub` — see `pickSurface`'s doc for why.
pub fn hoverSurface(scratch: Allocator, text: []const u8, off: usize) ?core.surface.Surface {
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

/// An exhaustive mirror of `core.surface.Role`'s named tags — the wire
/// membrane's `Role` is deliberately non-exhaustive (an `_` catch-all for
/// forward compatibility across the guest ABI), and `std.zon` refuses to
/// (de)serialize non-exhaustive enums. `layoutCaretSurface`'s output feeds
/// the popup-layout e2e gate's committed golden files, so its column-0 color
/// identity is this small, exhaustive, ZON-friendly copy instead.
pub const SpanRole = enum { normal, accent, group, leaf, effect, muted };

fn fromRole(r: core.surface.Role) SpanRole {
    return switch (r) {
        .accent => .accent,
        .group => .group,
        .leaf => .leaf,
        .effect => .effect,
        .muted => .muted,
        else => .normal, // .normal, and any future/unknown tag
    };
}

/// Mirrors `Theme.roleColor` over `SpanRole` instead of `core.surface.Role` —
/// same table, kept beside its source so a future role/color addition is one
/// two-switch edit, not a silent drift.
fn spanRoleColor(v: *const View, role: SpanRole) [4]f32 {
    return switch (role) {
        .accent => v.theme.accent,
        .group => v.theme.heading,
        .effect => v.theme.md_link,
        .muted => v.theme.status,
        .normal, .leaf => v.theme.foreground,
    };
}

/// One positioned span in a laid-out caret row: WHERE it draws (world x)
/// and its resolved color IDENTITY (never a raw RGB — see `SpanRole`).
pub const SpanLayout = struct {
    text: []const u8,
    column: u8,
    x: f32,
    role: SpanRole,
};

/// One positioned row: its top y, whether it's the selected (accent-filled)
/// row, and its positioned spans.
pub const RowLayout = struct {
    y: f32,
    selected: bool,
    spans: []const SpanLayout,
};

/// The linked info panel's box + its line-split text, already placed
/// (right of the list, or flipped left when that would overflow `body`).
pub const InfoLayout = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    flipped_left: bool,
    lines: []const []const u8,
};

/// A `caret`-placed `Surface`'s full LAYOUT DECISION: the box rect, whether
/// it flipped above the caret line, every column's x-offset (in cells) and
/// width, every row positioned + colored, and the linked info panel if any.
/// This is the introspection seam the popup-layout e2e gate asserts against
/// (golden ZON, `src/e2e/popup_layout_test.zig`) instead of raw pixels —
/// pixel snapshots are brittle to font hinting/HiDPI, but this is pure
/// arithmetic over fixed metrics, so it's exactly reproducible run to run.
/// Every field here is ZON-serializable by construction (no non-exhaustive
/// enums, no pointers besides plain slices) — see `SpanRole`.
pub const CaretLayout = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    flipped_above: bool,
    /// Column x-offsets/widths, in CELLS (not pixels) — stable across `em`,
    /// so a theme/font-size change doesn't false-positive the golden.
    col_x: []const usize,
    col_w: []const usize,
    rows: []const RowLayout,
    info: ?InfoLayout,
};

/// Compute a `caret`-placed `Surface`'s layout — resolve the anchor's caret
/// geometry, flip the box above the line (else clamp into `body`) when it
/// would overflow, align every row's spans into their declared COLUMNS (0 =
/// main content — an 8-cell floor so a short list never looks cramped; 1+ =
/// a dimmed annotation, sized to whichever rows carry one), mark the
/// selected row, and — if the surface carries `info` — place a linked side
/// panel beside it (right, else left), multi-line and capped. Null under
/// the same conditions `drawCaretSurface` draws nothing: an empty surface,
/// a missing anchor, or an anchor whose line is off-screen. `scratch`-owned
/// (arena) — never retained past the frame/test that built it.
pub fn layoutCaretSurface(
    v: *View,
    scratch: Allocator,
    surf: *const core.surface.Surface,
    body: region.Rect,
) !?CaretLayout {
    const nrows = surf.rows.items.len;
    if (nrows == 0) return null;
    const off = surf.anchor orelse return null;
    const li = v.frame_layout.lineForOffset(off) orelse return null; // off-screen
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
    var flipped_above = false;
    if (box_y + box_h > body.y + body.h) {
        box_y = c.y_top - box_h; // flip above
        flipped_above = true;
    }
    box_y = std.math.clamp(box_y, body.y, @max(body.y, body.y + body.h - box_h));

    const rows = try scratch.alloc(RowLayout, nrows);
    for (surf.rows.items, 0..) |row, i| {
        const row_y = box_y + @as(f32, @floatFromInt(i)) * v.line_h;
        const selected = surf.selected != null and surf.selected.? == i;
        const spans = try scratch.alloc(SpanLayout, row.spans.items.len);
        for (row.spans.items, 0..) |sp, si| {
            const x = box_x + @as(f32, @floatFromInt(col_x[sp.column])) * v.cell_w;
            spans[si] = .{ .text = sp.text, .column = sp.column, .x = x, .role = fromRole(sp.role) };
        }
        rows[i] = .{ .y = row_y, .selected = selected, .spans = spans };
    }

    // The linked side panel (e.g. the selected row's full docs): beside the
    // box (right, else left if it would overflow the body). Multi-line, capped.
    var info: ?InfoLayout = null;
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
            var flipped_left = false;
            if (ix + iw > body.x + body.w) {
                ix = @max(body.x, box_x - iw - v.cell_w); // flip left
                flipped_left = true;
            }
            const iy = std.math.clamp(box_y, body.y, @max(body.y, body.y + body.h - ih));
            const lines = try scratch.alloc([]const u8, irows);
            var lit = std.mem.splitScalar(u8, surf.info, '\n');
            var k: usize = 0;
            while (lit.next()) |line| : (k += 1) {
                if (k >= irows) break;
                lines[k] = line;
            }
            info = .{ .x = ix, .y = iy, .w = iw, .h = ih, .flipped_left = flipped_left, .lines = lines };
        }
    }

    return .{
        .x = box_x,
        .y = box_y,
        .w = box_w,
        .h = box_h,
        .flipped_above = flipped_above,
        .col_x = col_x,
        .col_w = col_w,
        .rows = rows,
        .info = info,
    };
}

/// Draw a `caret`-placed `Surface` — the ONE generic renderer `drawPickAtCaret`
/// and `drawHoverAtCaret` used to hardcode separately. A thin consumer of
/// `layoutCaretSurface`'s decision: turns positioned rows/spans/info into
/// rects + runs. Column 0 reads through the span's semantic role; column 1+
/// is a dimmed ANNOTATION by construction (the completion note) — comment
/// gray, unless the selected row's accent fill forces every column to the
/// box background instead, for legibility. A missing/off-screen anchor or
/// an empty surface draws nothing.
pub fn drawCaretSurface(
    v: *View,
    scratch: Allocator,
    runs: *std.ArrayList(Run),
    rects: *std.ArrayList(Rect),
    surf: *const core.surface.Surface,
    body: region.Rect,
) !void {
    const cl = (try layoutCaretSurface(v, scratch, surf, body)) orelse return;
    try outlinedBox(scratch, rects, cl.x, cl.y, cl.w, cl.h, v.theme.selection, v.theme.accent);

    for (cl.rows) |row| {
        if (row.selected) try rects.append(scratch, .{ .x = cl.x, .y = row.y, .w = cl.w, .h = v.line_h, .color = v.theme.accent });
        for (row.spans) |sp| {
            const color = if (row.selected)
                v.theme.background
            else if (sp.column == 0)
                spanRoleColor(v, sp.role)
            else
                v.theme.syn_comment;
            try propLine(v, scratch, runs, sp.text, sp.x, row.y + v.ascent, color);
        }
    }

    if (cl.info) |info| {
        try outlinedBox(scratch, rects, info.x, info.y, info.w, info.h, v.theme.selection, v.theme.accent);
        for (info.lines, 0..) |line, k| {
            const ly = info.y + @as(f32, @floatFromInt(k)) * v.line_h + v.ascent;
            try propLine(v, scratch, runs, line, info.x + v.cell_w, ly, v.theme.foreground);
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
