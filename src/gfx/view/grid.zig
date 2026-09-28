//! Grid drawing — a cell grid (`core.grid`, a terminal's screen) into the
//! pane's body: each row's backgrounds as merged rects, its glyphs as one
//! mono cell run per face (regular, bold, italic, both), its underlines and
//! strikes as thin rects, and the grid's own cursor in the shape it asked
//! for. The same mono cell geometry text rows use (`linelayout`), so a
//! terminal lines up with every other pane.
//!
//! Colours are the grid's: a cell's RGB, or — for `default` — the theme's
//! foreground and the pane's own background, so plain terminal output looks
//! like the rest of the editor.

const std = @import("std");
const Allocator = std.mem.Allocator;

const text_engine = @import("weft_text");
const core = @import("weft_core");
const region = @import("../region.zig");
const layout = @import("../layout.zig");
const View = @import("View.zig");

const Run = View.Run;
const Rect = View.Rect;
const Cell = core.grid.Cell;

fn color(rgb: [3]u8) [4]f32 {
    return .{ @as(f32, @floatFromInt(rgb[0])) / 255, @as(f32, @floatFromInt(rgb[1])) / 255, @as(f32, @floatFromInt(rgb[2])) / 255, 1 };
}

/// A cell colour as drawn: its RGB, or the theme colour it names.
fn resolve(v: *const View, c: u32) [4]f32 {
    if (Cell.rgb(c)) |rgb| return color(rgb);
    return if (c == Cell.theme_bg) v.theme.background else v.theme.foreground;
}

fn mix(a: [4]f32, b: [4]f32, t: f32) [4]f32 {
    return .{ a[0] * (1 - t) + b[0] * t, a[1] * (1 - t) + b[1] * t, a[2] * (1 - t) + b[2] * t, 1 };
}

/// The four faces a row's glyphs are shaped in.
const Face = enum(u2) {
    regular,
    bold,
    italic,
    bold_italic,

    fn of(a: core.grid.Cell) Face {
        const bits = @as(u2, @intFromBool(a.attrs.bold)) | (@as(u2, @intFromBool(a.attrs.italic)) << 1);
        return @enumFromInt(bits);
    }

    fn style(self: Face) text_engine.FontStyle {
        return switch (self) {
            .regular => .{},
            .bold => .{ .weight = .bold },
            .italic => .{ .italic = true },
            .bold_italic => .{ .weight = .bold, .italic = true },
        };
    }
};

/// Draw `g` into `body`, from its top-left cell. `cursor_on` is the blink
/// phase: an off phase draws no cursor. `washes` (a selection, a flash) go
/// over each row's backgrounds and under its cursor and glyphs.
pub fn draw(
    v: *View,
    scratch: Allocator,
    runs: *std.ArrayList(Run),
    rects: *std.ArrayList(Rect),
    g: *const core.grid.Snapshot,
    body: region.Rect,
    cursor_on: bool,
    washes: []const Rect,
) !void {
    const x0 = v.origin_x;
    const rows_fit: usize = @intFromFloat(@max(0, @floor(body.h / v.line_h)));
    const cols_fit: usize = @intFromFloat(@max(0, @floor((body.x + body.w - x0) / v.cell_w)));
    const rows = @min(g.rows, rows_fit);
    const cols = @min(g.cols, cols_fit);
    const cursor = g.cursor;
    const show_cursor = cursor_on and cursor.visible and cursor.y < rows and cursor.x < cols;

    var bytes: [4]std.ArrayList(u8) = @splat(.empty);
    var cells: [4]std.ArrayList(text_engine.Cell) = @splat(.empty);
    for (0..rows) |r| {
        const row = g.row(r);
        const y = body.y + @as(f32, @floatFromInt(r)) * v.line_h;
        const baseline = y + v.ascent;
        for (&bytes) |*b| b.* = .empty;
        for (&cells) |*c| c.* = .empty;

        // Backgrounds: one rect per run of cells sharing a colour.
        var c: usize = 0;
        while (c < cols) {
            const bg = row[c].bg;
            var end = c + 1;
            while (end < cols and row[end].bg == bg) end += 1;
            // The theme's background is the pane's own: nothing to paint.
            if (bg != Cell.theme_bg) try rects.append(scratch, .{
                .x = x0 + @as(f32, @floatFromInt(c)) * v.cell_w,
                .y = y,
                .w = @as(f32, @floatFromInt(end - c)) * v.cell_w,
                .h = v.line_h,
                .color = resolve(v, bg),
            });
            c = end;
        }
        for (washes) |w| if (@abs(w.y - y) < 0.5) try rects.append(scratch, w);

        // The cursor's block goes under the glyph it covers, which then draws
        // in the cursor's text colour.
        const block_here = show_cursor and cursor.y == r and cursor.shape == .block;
        if (block_here) try rects.append(scratch, .{
            .x = x0 + @as(f32, @floatFromInt(cursor.x)) * v.cell_w,
            .y = y,
            .w = v.cell_w * @as(f32, @floatFromInt(@max(1, row[cursor.x].width))),
            .h = v.line_h,
            .color = v.theme.cursor,
        });

        for (row[0..cols], 0..) |cell, col| {
            if (cell.width == 0 or cell.attrs.invisible) continue;
            const bg = resolve(v, cell.bg);
            var fg = resolve(v, cell.fg);
            if (cell.attrs.faint) fg = mix(fg, bg, 0.5);
            if (block_here and col == cursor.x) fg = v.theme.cursor_text;
            const cx = x0 + @as(f32, @floatFromInt(col)) * v.cell_w;
            const w = v.cell_w * @as(f32, @floatFromInt(@max(1, cell.width)));
            // Lines the glyph does not draw: under, through, over.
            switch (cell.attrs.underline) {
                .none => {},
                .double => {
                    try rects.append(scratch, .{ .x = cx, .y = baseline + 1, .w = w, .h = 1, .color = fg });
                    try rects.append(scratch, .{ .x = cx, .y = baseline + 3, .w = w, .h = 1, .color = fg });
                },
                else => try rects.append(scratch, .{ .x = cx, .y = baseline + 1, .w = w, .h = 1, .color = fg }),
            }
            if (cell.attrs.strikethrough) try rects.append(scratch, .{ .x = cx, .y = baseline - v.ascent * 0.35, .w = w, .h = 1, .color = fg });
            if (cell.attrs.overline) try rects.append(scratch, .{ .x = cx, .y = y, .w = w, .h = 1, .color = fg });
            if (cell.cp == 0 or cell.cp == ' ') continue;
            var utf8: [4]u8 = undefined;
            const cp: u21 = std.math.cast(u21, cell.cp) orelse continue;
            const n = std.unicode.utf8Encode(cp, &utf8) catch continue;
            const face = @intFromEnum(Face.of(cell));
            const b0 = bytes[face].items.len;
            try bytes[face].appendSlice(scratch, utf8[0..n]);
            try cells[face].append(scratch, .{
                .source = .{ .start = @intCast(b0), .end = @intCast(b0 + n) },
                .column = @intCast(col),
                .color = fg,
            });
        }
        for (bytes, cells, 0..) |b, cs, face| {
            if (cs.items.len == 0) continue;
            const shaped = try text_engine.shape(scratch, &v.face_set.mono, b.items, .{ .style = @as(Face, @enumFromInt(face)).style() });
            try runs.append(scratch, .{ .shaped = shaped, .baseline_y = baseline, .place = .{ .cell = cs.items } });
        }
    }

    // The other shapes sit beside or under the glyph and never recolour it.
    if (show_cursor and cursor.shape != .block) {
        const cx = x0 + @as(f32, @floatFromInt(cursor.x)) * v.cell_w;
        const cy = body.y + @as(f32, @floatFromInt(cursor.y)) * v.line_h;
        const col = v.theme.cursor;
        switch (cursor.shape) {
            .block => unreachable,
            .bar => try rects.append(scratch, .{ .x = cx, .y = cy, .w = 2, .h = v.line_h, .color = col }),
            .underline => try rects.append(scratch, .{ .x = cx, .y = cy + v.line_h - 2, .w = v.cell_w, .h = 2, .color = col }),
            .hollow => {
                try rects.append(scratch, .{ .x = cx, .y = cy, .w = v.cell_w, .h = 1, .color = col });
                try rects.append(scratch, .{ .x = cx, .y = cy + v.line_h - 1, .w = v.cell_w, .h = 1, .color = col });
                try rects.append(scratch, .{ .x = cx, .y = cy, .w = 1, .h = v.line_h, .color = col });
                try rects.append(scratch, .{ .x = cx + v.cell_w - 1, .y = cy, .w = 1, .h = v.line_h, .color = col });
            },
        }
    }
}
/// The geometry of a grid READ as text (`Snapshot.reading`): for each row
/// drawn, the part of the entry's document on it (`Snapshot.spans` — a
/// logical line that wraps is one document line over several rows, a
/// command line is its buffer flowed over its rows), with a caret stop at
/// every scalar at the x of its cell (`core.grid.RowWalk`). So the
/// document's caret, selections and flashes land ON the cells, and a click
/// or a drag resolves to the offset under it (the view's geometry map).
pub fn layoutRows(
    v: *const View,
    la: Allocator,
    g: *const core.grid.Snapshot,
    body: region.Rect,
) ![]layout.VisualLine {
    const x0 = v.origin_x;
    const rows_fit: usize = @intFromFloat(@max(0, @floor(body.h / v.line_h)));
    const rows = @min(@min(g.rows, rows_fit), g.spans.len);
    var lines: std.ArrayList(layout.VisualLine) = .empty;
    for (0..rows) |r| {
        const span = g.spans[r];
        const y = body.y + @as(f32, @floatFromInt(r)) * v.line_h;
        var stops: std.ArrayList(layout.Stop) = .empty;
        var walk = core.grid.RowWalk.init(g.row(r), span, g.flows[r]);
        while (walk.next()) |s| {
            if (s.off >= span.end) break;
            try stops.append(la, .{ .off = @intCast(s.off), .x = x0 + @as(f32, @floatFromInt(s.col)) * v.cell_w });
        }
        try stops.append(la, .{ .off = @intCast(span.end), .x = x0 + @as(f32, @floatFromInt(walk.endCol())) * v.cell_w });
        try lines.append(la, .{
            .src = .{ .start = span.start, .end = span.end },
            .row = g.first_row + r,
            .baseline_y = y + v.ascent,
            .ascent = v.ascent,
            .descent = v.line_h - v.ascent,
            .height = v.line_h,
            .x0 = x0,
            .stops = try stops.toOwnedSlice(la),
        });
    }
    return lines.toOwnedSlice(la);
}
