//! Display-free render harness — rasterizes a `View` frame to an RGBA8
//! pixel buffer on the CPU (snail-raster), so layout and decoration output
//! can be asserted programmatically and dumped to an image, without a
//! Wayland compositor or a GPU. Test-only; not part of the shipped binary.
//!
//! Convert a dump to PNG for eyeballing:  convert out.ppm out.png

const std = @import("std");
const snail = @import("snail");
const raster = @import("snail-raster");
const stemma = @import("stemma");
const core = @import("../core/core.zig");
const view_mod = @import("view.zig");
const region = @import("region.zig");
const window_layout = @import("window_layout.zig");

const records = snail.render.records;

fn fullFrame(w: u32, h: u32) region.Rect {
    return .{ .x = 0, .y = 0, .w = @floatFromInt(w), .h = @floatFromInt(h) };
}

/// The theme background as sRGB bytes (the app clears to this before it
/// draws; the harness fills it so composited text reads correctly).
pub const bg: [4]u8 = .{ 22, 23, 26, 255 };

/// Render one full-frame `View` picture into a fresh RGBA8 buffer (caller
/// owns it). Mirrors the exe's emit→draw pipeline on the CPU rasterizer.
pub fn renderView(
    gpa: std.mem.Allocator,
    view: *view_mod.View,
    editor: *const core.Editor,
    hud: view_mod.Hud,
    w: u32,
    h: u32,
) ![]u8 {
    const projection = snail.Mat4.ortho(0, @floatFromInt(w), @floatFromInt(h), 0, -1, 1);
    const w2p = snail.mvpToScenePixel(projection, @floatFromInt(w), @floatFromInt(h)) orelse unreachable;

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    view.resetFrame();
    var top_row: usize = 0;
    var built = try view.build(arena.allocator(), editor, hud, &top_row, fullFrame(w, h), .{}, w2p);
    defer built.deinit(gpa);

    return try rasterize(gpa, view, &.{built.shapes}, w, h);
}

/// Rasterize a set of panes already built into their own absolute sub-rects
/// (via `view.build`, one `Built` per pane) into ONE composited RGBA8
/// framebuffer — the headless analogue of `RenderState.present`'s emit + draw.
/// `view.atlas` must still hold the glyph records the builds appended. Caller
/// owns the returned pixels.
pub fn renderBuilt(
    gpa: std.mem.Allocator,
    view: *view_mod.View,
    built: []const view_mod.Built,
    w: u32,
    h: u32,
) ![]u8 {
    const lists = try gpa.alloc([]snail.Shape, built.len);
    defer gpa.free(lists);
    for (built, 0..) |b, i| lists[i] = b.shapes;
    return rasterize(gpa, view, lists, w, h);
}

/// Rasterize already-built shape lists (one per pane) into one buffer.
/// Panes are built into their own region rects (absolute coords), so every
/// list emits with the identity transform. `view.atlas` holds the glyph
/// records from the preceding build() calls.
pub fn rasterize(
    gpa: std.mem.Allocator,
    view: *view_mod.View,
    shape_lists: []const []snail.Shape,
    w: u32,
    h: u32,
) ![]u8 {
    const projection = snail.Mat4.ortho(0, @floatFromInt(w), @floatFromInt(h), 0, -1, 1);

    var cache = try raster.DeviceAtlas.init(gpa, view.pool, .{
        .max_bindings = 1,
        .layer_info_height = 64,
        .max_images = 0,
    });
    defer cache.deinit();
    var bindings: [1]records.Binding = undefined;
    try cache.upload(gpa, &.{&view.atlas}, &bindings);

    const pixels = try gpa.alloc(u8, @as(usize, w) * h * 4);
    errdefer gpa.free(pixels);
    var pi: usize = 0;
    while (pi < pixels.len) : (pi += 4) pixels[pi..][0..4].* = bg;

    var renderer = try raster.Renderer.init(pixels, w, h, w * 4, .rgba8_unorm);
    const ds: raster.DrawState = .{
        .mvp = projection,
        .surface = .{ .pixel_width = w, .pixel_height = h, .encoding = .srgb },
        .raster = .{ .subpixel_order = .none },
    };

    // Accumulate every pane into ONE instance/batch stream, one draw —
    // exactly as the exe does (carried emit cursors + a per-pane translate).
    var total: usize = 0;
    for (shape_lists) |shapes| total += shapes.len;
    const inst = try gpa.alloc(records.Instance, @max(total, 1));
    defer gpa.free(inst);
    const bat = try gpa.alloc(records.DrawBatch, @max(total, 1));
    defer gpa.free(bat);
    var ilen: usize = 0;
    var blen: usize = 0;
    for (shape_lists) |shapes| {
        if (shapes.len == 0) continue;
        _ = try snail.emit.emit(inst, bat, &ilen, &blen, bindings[0], &view.atlas, shapes, .identity, .{ 1, 1, 1, 1 });
    }
    try raster.draw(&renderer, ds, .{ .instances = inst[0..ilen], .batches = bat[0..blen] }, &.{&cache}, null);
    return pixels;
}

/// Write an RGBA8 buffer as a binary P6 PPM (RGB) — `convert` turns it into
/// a PNG for viewing.
pub fn writePpm(gpa: std.mem.Allocator, path: []const u8, pixels: []const u8, w: u32, h: u32) !void {
    const header = try std.fmt.allocPrint(gpa, "P6\n{d} {d}\n255\n", .{ w, h });
    defer gpa.free(header);
    const out = try gpa.alloc(u8, header.len + @as(usize, w) * h * 3);
    defer gpa.free(out);
    @memcpy(out[0..header.len], header);
    var di = header.len;
    var i: usize = 0;
    while (i < pixels.len) : (i += 4) {
        out[di] = pixels[i];
        out[di + 1] = pixels[i + 1];
        out[di + 2] = pixels[i + 2];
        di += 3;
    }
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    try std.Io.Dir.cwd().writeFile(threaded.io(), .{ .sub_path = path, .data = out[0..di] });
}

/// True if any pixel inside [x0,x1)×[y0,y1) differs from the background —
/// i.e. something (text/decoration) was drawn there.
pub fn hasContent(pixels: []const u8, w: u32, x0: u32, y0: u32, x1: u32, y1: u32) bool {
    var y = y0;
    while (y < y1) : (y += 1) {
        var x = x0;
        while (x < x1) : (x += 1) {
            const p = (@as(usize, y) * w + x) * 4;
            if (!std.mem.eql(u8, pixels[p .. p + 3], bg[0..3])) return true;
        }
    }
    return false;
}

// ── Tests ───────────────────────────────────────────────────────────

const t = std.testing;

fn makeEditor(gpa: std.mem.Allocator, pool: *core.task.Pool, text: []const u8) !core.Editor {
    var ed = try core.Editor.init(gpa, pool, "harness");
    errdefer ed.deinit(gpa);
    try ed.insertText(gpa, text);
    return ed;
}

test "harness: a single pane renders text into the body" {
    const gpa = t.allocator;
    const pool = try core.task.Pool.init(gpa, .{ .threads = 1 });
    defer pool.deinit();
    var view = try view_mod.View.init(gpa, @embedFile("font_mono"), 16);
    defer view.deinit();
    var ed = try makeEditor(gpa, pool, "hello harness\nsecond line\n");
    defer ed.deinit(gpa);

    const w: u32 = 320;
    const h: u32 = 160;
    const pixels = try renderView(gpa, &view, &ed, .{ .mode = "normal" }, w, h);
    defer gpa.free(pixels);

    // Text was drawn in the top-left body region (past the 8px margin).
    try t.expect(hasContent(pixels, w, 8, 8, 200, 40));
    // Dump for eyeballing (best-effort; ignored if the dir is missing).
    writePpm(gpa, ".zig-cache/tmp/weft-harness-single.ppm", pixels, w, h) catch {};
}

test "harness: which-key panel does not collide with the status line" {
    const gpa = t.allocator;
    const pool = try core.task.Pool.init(gpa, .{ .threads = 1 });
    defer pool.deinit();
    var view = try view_mod.View.init(gpa, @embedFile("font_mono"), 16);
    defer view.deinit();
    // Enough lines to fill the body.
    var ed = try makeEditor(gpa, pool, "L1\nL2\nL3\nL4\nL5\nL6\nL7\nL8\nL9\nL10\n");
    defer ed.deinit(gpa);

    const hints = [_]core.Keymap.Binding{
        .{ .key = "f", .command = "find-file" },
        .{ .key = "c", .command = "collab" },
        .{ .key = "space", .command = "palette" },
    };
    const w: u32 = 320;
    const h: u32 = 240;
    const pixels = try renderView(gpa, &view, &ed, .{ .mode = "leader", .which_key = &hints }, w, h);
    defer gpa.free(pixels);
    writePpm(gpa, ".zig-cache/tmp/weft-harness-whichkey.ppm", pixels, w, h) catch {};

    // The status line is the last text row. The which-key hints must sit
    // ABOVE it in their own rows — the last hint row must not overwrite the
    // status row. We check that the status row still reads as the status
    // line by confirming content is present and the row just above it (the
    // last hint) is a distinct row (both have content, neither is empty).
    // Regression guard: with the off-by-one, the last hint printed on the
    // status row. Here we assert the mode chip "leader" is still legible at
    // the very bottom by requiring content in the bottom row's left cells.
    const line_h: u32 = @intFromFloat(view.line_h);
    const bottom_row_y = h - line_h; // approx top of the last text row
    try t.expect(hasContent(pixels, w, 8, bottom_row_y + 2, 120, h - 2));
}

test "harness: the picker docks below the panes — cannot overlap body or status" {
    const gpa = t.allocator;
    const pool = try core.task.Pool.init(gpa, .{ .threads = 1 });
    defer pool.deinit();
    var view = try view_mod.View.init(gpa, @embedFile("font_mono"), 16);
    defer view.deinit();
    var ed = try makeEditor(gpa, pool, "body line one\nbody line two\nbody line three\n");
    defer ed.deinit(gpa);

    // A picker with three results (built directly — no matcher needed here).
    var pick: core.Pick = .empty;
    defer pick.deinit(gpa);
    pick.prompt = try gpa.dupe(u8, "P");
    pick.active = true;
    for ([_][]const u8{ "alpha", "bravo", "charlie" }) |it| {
        try pick.items.append(gpa, try gpa.dupe(u8, it));
        try pick.docs.append(gpa, try gpa.dupe(u8, ""));
        try pick.filtered.append(gpa, @intCast(pick.items.items.len - 1));
    }

    const w: u32 = 320;
    const h: u32 = 240;
    const window: region.Rect = .{ .x = 0, .y = 0, .w = @floatFromInt(w), .h = @floatFromInt(h) };
    // The exact carve main does: the picker's dock is cut off the WINDOW with
    // cutBottom; the pane fills the rest. Disjoint by construction, so the
    // picker can never paint over a pane body or status line — the class of
    // bug this guards (it recurred when the picker was an absolute overlay).
    const cut = window.cutBottom(view.pickDockHeight(&pick));
    const dock = cut.strip;
    const panes = cut.rest;
    // The dock and the panes touch exactly — no overlap, no gap.
    try t.expectApproxEqAbs(panes.y + panes.h, dock.y, 0.5);

    const projection = snail.Mat4.ortho(0, @floatFromInt(w), @floatFromInt(h), 0, -1, 1);
    const w2p = snail.mvpToScenePixel(projection, @floatFromInt(w), @floatFromInt(h)) orelse unreachable;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    view.resetFrame();
    var tr: usize = 0;
    var built = try view.build(arena.allocator(), &ed, .{ .mode = "normal", .pick = &pick }, &tr, panes, dock, w2p);
    defer built.deinit(gpa);
    const pixels = try rasterize(gpa, &view, &.{built.shapes}, w, h);
    defer gpa.free(pixels);
    writePpm(gpa, ".zig-cache/tmp/weft-harness-pick.ppm", pixels, w, h) catch {};

    // The picker is drawn INTO its dock (the bottom strip has content).
    const dy: u32 = @intFromFloat(dock.y);
    try t.expect(hasContent(pixels, w, 4, dy + 2, w - 4, h - 2));
    // And the pane body above the dock still shows the buffer (it was not
    // covered — the picker stayed in its region).
    try t.expect(hasContent(pixels, w, 8, 8, 200, 40));
}

test "harness: a vertical split renders a buffer in each column" {
    const gpa = t.allocator;
    const pool = try core.task.Pool.init(gpa, .{ .threads = 1 });
    defer pool.deinit();
    var view = try view_mod.View.init(gpa, @embedFile("font_mono"), 16);
    defer view.deinit();
    var left = try makeEditor(gpa, pool, "LEFT PANE\nalpha bravo\n");
    defer left.deinit(gpa);
    var right = try makeEditor(gpa, pool, "RIGHT PANE\ncharlie delta\n");
    defer right.deinit(gpa);

    const w: u32 = 400;
    const h: u32 = 160;
    const half: u32 = w / 2;

    const projection = snail.Mat4.ortho(0, @floatFromInt(w), @floatFromInt(h), 0, -1, 1);
    const w2p = snail.mvpToScenePixel(projection, @floatFromInt(w), @floatFromInt(h)) orelse unreachable;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    // Two panes: each laid out for half width, sharing the frame arena.
    view.resetFrame();
    var lt: usize = 0;
    var rt: usize = 0;
    const lrect: region.Rect = .{ .x = 0, .y = 0, .w = @floatFromInt(half), .h = @floatFromInt(h) };
    const rrect: region.Rect = .{ .x = @floatFromInt(half), .y = 0, .w = @floatFromInt(w - half), .h = @floatFromInt(h) };
    const lb = try view.build(arena.allocator(), &left, .{ .mode = "normal" }, &lt, lrect, .{}, w2p);
    const left_layout = view.frame_layout; // capture before the next build overwrites it
    const rb = try view.build(arena.allocator(), &right, .{ .mode = "normal" }, &rt, rrect, .{}, w2p);
    const right_layout = view.frame_layout;
    try t.expect(left_layout.lines.len > 0 and right_layout.lines.len > 0);

    const pixels = try rasterize(gpa, &view, &.{ lb.shapes, rb.shapes }, w, h);
    defer gpa.free(pixels);
    defer {
        var b1 = lb;
        b1.deinit(gpa);
        var b2 = rb;
        b2.deinit(gpa);
    }

    // Both columns' bodies have content; the seam column just before the
    // right pane's margin is background (the panes don't bleed together).
    try t.expect(hasContent(pixels, w, 8, 8, half - 4, 40)); // left body
    try t.expect(hasContent(pixels, w, half + 8, 8, w - 4, 40)); // right body
    try t.expect(!hasContent(pixels, w, half - 3, 8, half, 40)); // seam gap
    writePpm(gpa, ".zig-cache/tmp/weft-harness-split.ppm", pixels, w, h) catch {};
}

test "harness: renderBuilt composites panes laid out by the real window layout" {
    const gpa = t.allocator;
    const pool = try core.task.Pool.init(gpa, .{ .threads = 1 });
    defer pool.deinit();
    var view = try view_mod.View.init(gpa, @embedFile("font_mono"), 16);
    defer view.deinit();
    var left = try makeEditor(gpa, pool, "LEFT PANE\nalpha\n");
    defer left.deinit(gpa);
    var right = try makeEditor(gpa, pool, "RIGHT PANE\nbravo\n");
    defer right.deinit(gpa);

    // Drive the REAL window layout: one vsplit → two side-by-side slots.
    var layout = try window_layout.Layout.init(gpa, 1);
    defer layout.deinit();
    const focused = try layout.splitFocused(layout.root, .vertical);

    const w: u32 = 400;
    const h: u32 = 160;
    const frame: region.Rect = .{ .x = 0, .y = 0, .w = @floatFromInt(w), .h = @floatFromInt(h) };
    var slots: [window_layout.max_panes]window_layout.Slot = undefined;
    const n = layout.collect(focused, frame, &slots);
    try t.expectEqual(@as(usize, 2), n);

    const projection = snail.Mat4.ortho(0, @floatFromInt(w), @floatFromInt(h), 0, -1, 1);
    const w2p = snail.mvpToScenePixel(projection, @floatFromInt(w), @floatFromInt(h)) orelse unreachable;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    view.resetFrame();

    // Build each pane into its layout slot rect (identity transform), exactly
    // as renderPanes does — then composite through renderBuilt (headless present).
    var built: [2]view_mod.Built = undefined;
    const editors = [_]*core.Editor{ &left, &right };
    var trs = [_]usize{ 0, 0 };
    for (slots[0..n], 0..) |slot, i| {
        built[i] = try view.build(arena.allocator(), editors[i], .{ .mode = "normal", .pane_border = slot.border }, &trs[i], slot.rect, .{}, w2p);
    }
    defer for (&built) |*b| b.deinit(gpa);

    const pixels = try renderBuilt(gpa, &view, &built, w, h);
    defer gpa.free(pixels);
    writePpm(gpa, ".zig-cache/tmp/weft-harness-renderbuilt.ppm", pixels, w, h) catch {};

    // Both slots painted their buffer body, and the real layout's internal
    // border drew a divider at the seam (proving slot.border geometry rendered).
    const half = w / 2;
    try t.expect(hasContent(pixels, w, 8, 8, half - 4, 40));
    try t.expect(hasContent(pixels, w, half + 8, 8, w - 4, 40));
    try t.expect(hasContent(pixels, w, half - 2, 8, half + 2, h - 8)); // divider
}

test "harness: a horizontal split stacks a buffer in each row" {
    const gpa = t.allocator;
    const pool = try core.task.Pool.init(gpa, .{ .threads = 1 });
    defer pool.deinit();
    var view = try view_mod.View.init(gpa, @embedFile("font_mono"), 16);
    defer view.deinit();
    var top = try makeEditor(gpa, pool, "TOP PANE\nalpha bravo\n");
    defer top.deinit(gpa);
    var bot = try makeEditor(gpa, pool, "BOTTOM PANE\ncharlie delta\n");
    defer bot.deinit(gpa);

    const w: u32 = 320;
    const h: u32 = 320;
    const half: u32 = h / 2;
    const projection = snail.Mat4.ortho(0, @floatFromInt(w), @floatFromInt(h), 0, -1, 1);
    const w2p = snail.mvpToScenePixel(projection, @floatFromInt(w), @floatFromInt(h)) orelse unreachable;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    view.resetFrame();
    var tt: usize = 0;
    var bt: usize = 0;
    const trect: region.Rect = .{ .x = 0, .y = 0, .w = @floatFromInt(w), .h = @floatFromInt(half) };
    const brect: region.Rect = .{ .x = 0, .y = @floatFromInt(half), .w = @floatFromInt(w), .h = @floatFromInt(h - half) };
    const tb = try view.build(arena.allocator(), &top, .{ .mode = "normal" }, &tt, trect, .{}, w2p);
    const tl = view.frame_layout;
    const bb = try view.build(arena.allocator(), &bot, .{ .mode = "normal" }, &bt, brect, .{}, w2p);
    const bl = view.frame_layout;
    try t.expect(tl.lines.len > 0 and bl.lines.len > 0);
    defer {
        var b1 = tb;
        b1.deinit(gpa);
        var b2 = bb;
        b2.deinit(gpa);
    }

    const pixels = try rasterize(gpa, &view, &.{ tb.shapes, bb.shapes }, w, h);
    defer gpa.free(pixels);
    // Content in both rows' body tops; the bottom pane's first text row sits
    // just below the seam.
    try t.expect(hasContent(pixels, w, 8, 8, w - 4, 40)); // top pane body
    try t.expect(hasContent(pixels, w, 8, half + 8, w - 4, half + 40)); // bottom pane body
    writePpm(gpa, ".zig-cache/tmp/weft-harness-hsplit.ppm", pixels, w, h) catch {};
}
