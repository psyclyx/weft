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

const records = snail.render.records;

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
    var built = try view.build(arena.allocator(), editor, hud, w, h, w2p);
    defer built.deinit(gpa);

    return try rasterize(gpa, view, &.{built.shapes}, w, h);
}

/// Rasterize already-built shape lists (one per pane) into one buffer.
/// `view.atlas` holds the glyph records from the preceding build() calls.
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

    for (shape_lists) |shapes| {
        if (shapes.len == 0) continue;
        const inst = try gpa.alloc(records.Instance, shapes.len);
        defer gpa.free(inst);
        const bat = try gpa.alloc(records.DrawBatch, shapes.len);
        defer gpa.free(bat);
        var ilen: usize = 0;
        var blen: usize = 0;
        _ = try snail.emit.emit(inst, bat, &ilen, &blen, bindings[0], &view.atlas, shapes, .identity, .{ 1, 1, 1, 1 });
        try raster.draw(&renderer, ds, .{ .instances = inst[0..ilen], .batches = bat[0..blen] }, &.{&cache}, null);
    }
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
