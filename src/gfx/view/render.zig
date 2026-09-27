//! Lower laid-out text runs and rectangles into explicit scene draw items.
//!
//! This is the only placement step between view layout and a renderer. It has
//! no glyph cache, atlas, backend record, or GPU dependency.

const std = @import("std");

const text_engine = @import("weft_text");
const scene = @import("weft_scene");
const view = @import("../view.zig");
const region = @import("../region.zig");

const View = view.View;
const Run = view.Run;
const Rect = view.Rect;
const Built = view.Built;

/// Where the floating layer starts in each list: everything a build appended
/// from these indices on (a popup, a menu) paints after the whole base layer,
/// so a popup's fill covers the text beneath it instead of the text showing
/// through (rects all paint before glyphs within one layer).
pub const Layers = struct { rects: usize, runs: usize };

pub fn render(v: *View, world_to_pixel: scene.Transform2D, runs: []Run, rects: []const Rect, float: Layers) !Built {
    // At most: every rect, every glyph, a clip before each run and one lift
    // after each layer.
    var count = rects.len + runs.len + 2;
    for (runs) |run| count += run.shaped.glyphs.len;
    var items = try v.gpa.alloc(scene.DrawItem, count);
    errdefer v.gpa.free(items);

    var at: usize = 0;
    at += try place(v, world_to_pixel, items[at..], runs[0..float.runs], rects[0..float.rects]);
    at += try place(v, world_to_pixel, items[at..], runs[float.runs..], rects[float.rects..]);
    std.debug.assert(at <= items.len);
    if (at < items.len) items = try v.gpa.realloc(items, at);
    return .{ .items = items };
}

/// One layer: its rects (in append order, whatever their shape), then its
/// glyphs, each run under its own clip.
fn place(v: *View, world_to_pixel: scene.Transform2D, items: []scene.DrawItem, runs: []Run, rects: []const Rect) !usize {
    var at: usize = 0;
    for (rects) |rect| {
        items[at] = switch (rect.shape) {
            .fill => .{ .rect = .{
                .x = rect.x,
                .y = rect.y,
                .w = rect.w,
                .h = rect.h,
                .color = rect.color,
            } },
            .rounded => |r| .{ .rrect = .{
                .x = rect.x,
                .y = rect.y,
                .w = rect.w,
                .h = rect.h,
                .radius = r.radius,
                .color = rect.color,
                .stroke_width = r.stroke_width,
                .blur = r.blur,
            } },
            .icon => |icon| .{ .path = .{
                .commands = icon.commands,
                .x = rect.x,
                .y = rect.y,
                .scale = rect.w / icon.size,
                .stroke_width = icon.stroke_width,
                .color = rect.color,
                .cap = .round,
                .join = .round,
            } },
        };
        at += 1;
    }
    var clip: ?region.Rect = null;
    for (runs) |*run| {
        if (!sameClip(clip, run.clip)) {
            clip = run.clip;
            items[at] = .{ .clip = if (clip) |c| .{ .x = c.x, .y = c.y, .w = c.w, .h = c.h } else null };
            at += 1;
        }
        at += switch (run.place) {
            .cell => |cells| try placeCells(items[at..], &run.shaped, cells, .{
                .baseline = .{ .x = v.origin_x, .y = run.baseline_y },
                .cell_width = v.cell_w,
                .em = v.em,
                .world_to_pixel = world_to_pixel,
            }),
            .prop => |prop| placeProportional(items[at..], &run.shaped, .{
                .baseline = .{ .x = prop.x, .y = run.baseline_y },
                .em = prop.em,
                .color = prop.color,
            }),
        };
    }
    if (clip != null) {
        items[at] = .{ .clip = null };
        at += 1;
    }
    return at;
}

fn sameClip(a: ?region.Rect, b: ?region.Rect) bool {
    if (a == null or b == null) return a == null and b == null;
    return std.meta.eql(a.?, b.?);
}

const CellPlacement = struct {
    baseline: scene.Vec2,
    cell_width: f32,
    em: f32,
    world_to_pixel: scene.Transform2D,
};

fn placeCells(
    out: []scene.DrawItem,
    shaped: *const text_engine.ShapedText,
    cells: []const text_engine.Cell,
    placement: CellPlacement,
) !usize {
    if (out.len < shaped.glyphs.len) return error.BufferTooSmall;
    const inverse = placement.world_to_pixel.inverse() orelse return error.InvalidTransform;
    const base_device = placement.world_to_pixel.applyPoint(placement.baseline);
    const device_cell_step = scene.Vec2{
        .x = placement.world_to_pixel.xx * placement.cell_width,
        .y = placement.world_to_pixel.yx * placement.cell_width,
    };
    if (!std.math.isFinite(device_cell_step.x) or !std.math.isFinite(device_cell_step.y))
        return error.InvalidTransform;

    for (shaped.glyphs, 0..) |glyph, index| {
        const cell = cellForSource(cells, glyph.source_start) orelse return error.NoCellForGlyph;
        const cluster_pen = clusterPen(shaped.glyphs, glyph.source_start);
        const column: f32 = @floatFromInt(cell.column);
        // Snap each logical cell origin, not the cell advance. Rounding the
        // advance once and multiplying it by `column` makes glyphs drift from
        // the layout stops (and therefore the caret) by the rounding error on
        // every column.
        const device_origin = scene.Vec2{
            .x = @round(base_device.x + column * device_cell_step.x),
            .y = @round(base_device.y + column * device_cell_step.y),
        };
        const cell_origin = inverse.applyPoint(device_origin);
        out[index] = .{ .glyph = .{
            .font_id = glyph.font_id,
            .glyph_id = glyph.glyph_id,
            .x = cell_origin.x + placement.em * (glyph.x_offset - cluster_pen.x),
            .y = cell_origin.y + placement.em * (glyph.y_offset - cluster_pen.y),
            .size = placement.em,
            .color = cell.color,
        } };
    }
    return shaped.glyphs.len;
}

const ProportionalPlacement = struct {
    baseline: scene.Vec2,
    em: f32,
    color: scene.Color,
};

fn placeProportional(out: []scene.DrawItem, shaped: *const text_engine.ShapedText, placement: ProportionalPlacement) usize {
    std.debug.assert(out.len >= shaped.glyphs.len);
    for (shaped.glyphs, 0..) |glyph, index| {
        out[index] = .{ .glyph = .{
            .font_id = glyph.font_id,
            .glyph_id = glyph.glyph_id,
            .x = placement.baseline.x + placement.em * glyph.x_offset,
            .y = placement.baseline.y + placement.em * glyph.y_offset,
            .size = placement.em,
            .color = placement.color,
        } };
    }
    return shaped.glyphs.len;
}

fn cellForSource(cells: []const text_engine.Cell, source_start: u32) ?text_engine.Cell {
    var low: usize = 0;
    var high = cells.len;
    while (low < high) {
        const mid = low + (high - low) / 2;
        if (cells[mid].source.start <= source_start)
            low = mid + 1
        else
            high = mid;
    }
    if (low == 0) return null;
    const cell = cells[low - 1];
    return if (source_start < cell.source.end) cell else null;
}

fn clusterPen(glyphs: []const text_engine.ShapedText.Glyph, source_start: u32) scene.Vec2 {
    for (glyphs) |glyph| {
        if (glyph.source_start == source_start)
            return .{ .x = glyph.x_offset, .y = glyph.y_offset };
    }
    unreachable;
}

test "cell snapping does not accumulate pitch rounding ahead of the caret" {
    const glyphs = [_]text_engine.ShapedText.Glyph{.{
        .font_id = 1,
        .glyph_id = 2,
        .x_offset = 0,
        .y_offset = 0,
        .x_advance = 0.6,
        .y_advance = 0,
        .source_start = 0,
        .source_end = 1,
    }};
    const shaped: text_engine.ShapedText = .{
        .allocator = std.testing.allocator,
        .glyphs = @constCast(&glyphs),
    };
    const cells = [_]text_engine.Cell{.{
        .source = .{ .start = 0, .end = 1 },
        .column = 20,
    }};
    var items: [1]scene.DrawItem = undefined;

    _ = try placeCells(&items, &shaped, &cells, .{
        .baseline = .{ .x = 8.25, .y = 20.25 },
        .cell_width = 9.6,
        .em = 16,
        .world_to_pixel = .identity,
    });

    const glyph = items[0].glyph;
    // round(8.25 + 20 * 9.6) = 200. Rounding the 9.6px pitch first would
    // incorrectly put this glyph at x=208, eight pixels ahead of its caret.
    try std.testing.expectEqual(@as(f32, 200), glyph.x);
    try std.testing.expectEqual(@as(f32, 20), glyph.y);
}
