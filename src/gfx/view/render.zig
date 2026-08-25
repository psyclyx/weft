//! Lower laid-out text runs and rectangles into explicit scene draw items.
//!
//! This is the only placement step between view layout and a renderer. It has
//! no glyph cache, atlas, backend record, or GPU dependency.

const std = @import("std");

const text_engine = @import("weft_text");
const scene = @import("weft_scene");
const view = @import("../view.zig");

const View = view.View;
const Run = view.Run;
const Rect = view.Rect;
const Built = view.Built;

pub fn render(v: *View, world_to_pixel: scene.Transform2D, runs: []Run, rects: []const Rect) !Built {
    var count = rects.len;
    for (runs) |run| count += run.shaped.glyphs.len;
    const items = try v.gpa.alloc(scene.DrawItem, count);
    errdefer v.gpa.free(items);

    var at: usize = 0;
    for (rects) |rect| {
        items[at] = .{ .rect = .{
            .x = rect.x,
            .y = rect.y,
            .w = rect.w,
            .h = rect.h,
            .color = rect.color,
        } };
        at += 1;
    }
    for (runs) |*run| {
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
    std.debug.assert(at == items.len);
    return .{ .items = items };
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
    const device_cell_width = @round(placement.world_to_pixel.xx * placement.cell_width);
    if (!std.math.isFinite(device_cell_width) or device_cell_width == 0)
        return error.InvalidTransform;

    for (shaped.glyphs, 0..) |glyph, index| {
        const cell = cellForSource(cells, glyph.source_start) orelse return error.NoCellForGlyph;
        const cluster_pen = clusterPen(shaped.glyphs, glyph.source_start);
        const device_origin = scene.Vec2{
            .x = @round(base_device.x) + @as(f32, @floatFromInt(cell.column)) * device_cell_width,
            .y = @round(base_device.y),
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
