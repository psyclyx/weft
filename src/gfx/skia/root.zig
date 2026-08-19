//! Zig binding for the Skia C++ shim (shim.h / shim.cpp) plus the snail-Shape
//! decode. The renderer-neutral draw list weft feeds Skia is snail's own
//! `[]Shape`: `view.build` already lowers every pane to affine-placed glyph
//! records (keyed by font_id/glyph_id) and unit-square fill rects, geometry
//! that carries no snail-pipeline state. `drawShapes` decodes each Shape — a
//! `key.a == 0` (font_id 0) unit square is a fill rect, everything else is a
//! glyph at `key.a`/`key.b` — and issues SkCanvas calls, converting snail's
//! linear straight-alpha colors to the sRGB the shim's legacy surface expects.

const std = @import("std");
const snail = @import("snail");

pub const VulkanInfo = extern struct {
    instance: ?*anyopaque,
    physical_device: ?*anyopaque,
    device: ?*anyopaque,
    queue: ?*anyopaque,
    queue_family: u32,
    get_instance_proc_addr: ?*const anyopaque,
    api_version: u32,
};

const Shim = opaque {};

extern fn weft_skia_create(vk: ?*const VulkanInfo, want_gpu: c_int, bgra: c_int) ?*Shim;
extern fn weft_skia_destroy(s: ?*Shim) void;
extern fn weft_skia_is_gpu(s: ?*const Shim) c_int;
extern fn weft_skia_register_font(s: ?*Shim, font_id: u32, bytes: [*]const u8, len: usize) void;
extern fn weft_skia_begin(s: ?*Shim, width: u32, height: u32) c_int;
extern fn weft_skia_clear(s: ?*Shim, r: f32, g: f32, b: f32, a: f32) void;
extern fn weft_skia_draw_rect(s: ?*Shim, x: f32, y: f32, w: f32, h: f32, r: f32, g: f32, b: f32, a: f32) void;
extern fn weft_skia_draw_glyph(s: ?*Shim, font_id: u32, glyph_id: u16, x: f32, y: f32, size: f32, r: f32, g: f32, b: f32, a: f32) void;
extern fn weft_skia_end(s: ?*Shim, row_bytes: *usize) ?[*]const u8;

/// A rasterized frame: pointer into the shim's buffer (valid until the next
/// `begin`/`deinit`) plus its dimensions and stride.
pub const Frame = struct {
    pixels: [*]const u8,
    width: u32,
    height: u32,
    row_bytes: usize,
};

pub const Skia = struct {
    shim: *Shim,
    gpu: bool,

    /// Create the renderer. `bgra` selects the output byte order (match the
    /// swapchain format). `want_gpu` requests Ganesh; on failure it silently
    /// falls back to the CPU raster path (query `.gpu` after).
    pub fn init(vk: ?*const VulkanInfo, want_gpu: bool, bgra: bool) !Skia {
        const shim = weft_skia_create(vk, @intFromBool(want_gpu), @intFromBool(bgra)) orelse
            return error.SkiaInitFailed;
        return .{ .shim = shim, .gpu = weft_skia_is_gpu(shim) != 0 };
    }

    pub fn deinit(self: *Skia) void {
        weft_skia_destroy(self.shim);
        self.* = undefined;
    }

    pub fn registerFont(self: *Skia, font_id: u32, bytes: []const u8) void {
        weft_skia_register_font(self.shim, font_id, bytes.ptr, bytes.len);
    }

    /// Begin a frame and clear to `bg` (a linear color, converted to sRGB).
    pub fn begin(self: *Skia, width: u32, height: u32, bg: [4]f32) !void {
        if (weft_skia_begin(self.shim, width, height) != 0) return error.SkiaBeginFailed;
        const c = linearToSrgb(bg);
        weft_skia_clear(self.shim, c[0], c[1], c[2], c[3]);
    }

    /// Decode one pane's snail Shapes into SkCanvas draws (rects behind glyphs,
    /// exactly the order `view.build` emits them).
    pub fn drawShapes(self: *Skia, shapes: []const snail.Shape) void {
        for (shapes) |shape| {
            const t = shape.local_transform;
            const c = linearToSrgb(shape.local_color);
            if (shape.key.a == 0) {
                // The unit-square fill record (font_id 0): a solid rect. Recover
                // it from the centered affine (see view/render.zig rectShape).
                const w = 2 * t.xx;
                const h = 2 * t.yy;
                weft_skia_draw_rect(self.shim, t.tx - t.xx, t.ty - t.yy, w, h, c[0], c[1], c[2], c[3]);
            } else {
                // A glyph: font_id = key.a, glyph_id = key.b, baseline origin
                // (tx,ty), pixel size = the local scale (|xx|).
                weft_skia_draw_glyph(self.shim, shape.key.a, @intCast(shape.key.b), t.tx, t.ty, @abs(t.xx), c[0], c[1], c[2], c[3]);
            }
        }
    }

    /// Flush + read back. The returned pixels live until the next `begin`.
    pub fn end(self: *Skia, width: u32, height: u32) !Frame {
        var row_bytes: usize = 0;
        const px = weft_skia_end(self.shim, &row_bytes) orelse return error.SkiaEndFailed;
        return .{ .pixels = px, .width = width, .height = height, .row_bytes = row_bytes };
    }
};

/// Linear straight-alpha → sRGB straight-alpha (rgb encoded, alpha unchanged).
/// snail colors are linear light; the shim's legacy (unmanaged) surface writes
/// bytes as-is, so we encode here to land correct in the _SRGB swapchain image.
fn linearToSrgb(c: [4]f32) [4]f32 {
    return .{ encode(c[0]), encode(c[1]), encode(c[2]), std.math.clamp(c[3], 0, 1) };
}

fn encode(x: f32) f32 {
    const v = std.math.clamp(x, 0, 1);
    return if (v <= 0.0031308) v * 12.92 else 1.055 * std.math.pow(f32, v, 1.0 / 2.4) - 0.055;
}
