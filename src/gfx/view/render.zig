//! Rendering — prepare every run's records, then place runs + rects as shapes.
//!
//! Free functions over `*View`. `render` is the tail of `build`: it prepares
//! the atlas records (reporting growth), counts the shapes, then emits rects
//! first (they draw behind the text — a block caret sits behind its recolored
//! glyph) and each run in its placement. Split out of `view.zig`.

const std = @import("std");

const snail = @import("snail");
const prepare = @import("../prepare.zig");
const view = @import("../view.zig");

const View = view.View;
const Run = view.Run;
const Rect = view.Rect;
const Built = view.Built;

pub fn render(v: *View, world_to_pixel: snail.Transform2D, runs: []Run, rects: []const Rect) !Built {
    // Prepare every glyph run's records (idempotent for resident ones).
    const run_ptrs = try v.gpa.alloc(*const snail.ShapedText, runs.len);
    defer v.gpa.free(run_ptrs);
    for (runs, run_ptrs) |*r, *out| out.* = &r.shaped;
    const sources = v.face_set.sources();
    const before = v.atlas.recordCount();
    try prepare.run(v.gpa, &v.atlas, &sources, run_ptrs, .{ .unhinted = .{ .colr = .layers } });
    const after = v.atlas.recordCount();

    var count: usize = rects.len;
    for (runs) |*r| count += try runShapeCount(v, r, world_to_pixel);
    const shapes = try v.gpa.alloc(snail.Shape, count);
    errdefer v.gpa.free(shapes);

    var at: usize = 0;
    // Rects first — they draw behind the text (a block caret sits
    // behind its recolored glyph).
    for (rects) |rc| {
        shapes[at] = rectShape(v, rc);
        at += 1;
    }
    for (runs) |*r| {
        const placed = try placeRunInto(v, shapes[at..], r, world_to_pixel);
        at += placed.len;
    }
    std.debug.assert(at == shapes.len);
    return .{ .shapes = shapes, .records_added = after - before };
}

fn runShapeCount(v: *View, r: *const Run, w2p: snail.Transform2D) !usize {
    return switch (r.place) {
        .cell => |cells| try snail.placedCellRunShapeCount(&r.shaped, &v.face_set.mono, cells, cellPlacement(v, r.baseline_y, w2p)),
        .prop => try snail.placedRunShapeCount(&r.shaped, null, propPlacement(r, w2p)),
    };
}

fn placeRunInto(v: *View, out: []snail.Shape, r: *const Run, w2p: snail.Transform2D) ![]snail.Shape {
    return switch (r.place) {
        .cell => |cells| try snail.placeCellRun(out, &r.shaped, &v.face_set.mono, cells, cellPlacement(v, r.baseline_y, w2p)),
        .prop => try snail.placeRun(out, &r.shaped, null, propPlacement(r, w2p)),
    };
}

fn cellPlacement(v: *const View, baseline_y: f32, world_to_pixel: snail.Transform2D) snail.CellRunPlacement {
    return .{
        .baseline = .{ .x = v.origin_x, .y = baseline_y },
        .cell_width = v.cell_w,
        .em = v.em,
        .snap = .grid,
        .y_axis = .down,
        .world_to_pixel = world_to_pixel,
    };
}

fn propPlacement(r: *const Run, world_to_pixel: snail.Transform2D) snail.RunPlacement {
    const p = r.place.prop;
    return .{
        .baseline = .{ .x = p.x, .y = r.baseline_y },
        .em = p.em,
        .color = p.color,
        .mode = .unhinted,
        .snap = .origins,
        .y_axis = .down,
        .world_to_pixel = world_to_pixel,
    };
}

fn rectShape(v: *const View, r: Rect) snail.Shape {
    // The unit-square record spans [-1, 1]² (centered), so the affine
    // maps its center to the rect's center with half-extent scales.
    return .{
        .key = v.rect_key,
        .local_transform = .{
            .xx = r.w / 2,
            .xy = 0,
            .tx = r.x + r.w / 2,
            .yx = 0,
            .yy = r.h / 2,
            .ty = r.y + r.h / 2,
        },
        .local_color = r.color,
    };
}
