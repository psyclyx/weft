//! Zig binding for the Skia C++ shim and the renderer-neutral scene decoder.
//! The view emits explicit rectangles, positioned glyphs, and vector paths;
//! this module translates them to SkCanvas calls and owns no editor or
//! platform policy.

const std = @import("std");
const scene = @import("weft_scene");

pub const VulkanInfo = extern struct {
    instance: ?*anyopaque,
    physical_device: ?*anyopaque,
    device: ?*anyopaque,
    queue: ?*anyopaque,
    queue_family: u32,
    get_instance_proc_addr: ?*const anyopaque,
    api_version: u32,
    instance_extensions: ?[*]const [*:0]const u8,
    instance_extension_count: u32,
    device_extensions: ?[*]const [*:0]const u8,
    device_extension_count: u32,
};

const Shim = opaque {};

extern fn weft_skia_create(vk: ?*const VulkanInfo, want_gpu: c_int, bgra: c_int) ?*Shim;
extern fn weft_skia_destroy(s: ?*Shim) void;
extern fn weft_skia_is_gpu(s: ?*const Shim) c_int;
extern fn weft_skia_register_font(s: ?*Shim, font_id: u32, bytes: [*]const u8, len: usize) void;
extern fn weft_skia_begin(s: ?*Shim, width: u32, height: u32) c_int;
extern fn weft_skia_clear(s: ?*Shim, r: f32, g: f32, b: f32, a: f32) void;
extern fn weft_skia_draw_rect(s: ?*Shim, x: f32, y: f32, w: f32, h: f32, r: f32, g: f32, b: f32, a: f32) void;
extern fn weft_skia_draw_glyph(s: ?*Shim, font_id: u32, glyph_id: u32, x: f32, y: f32, size: f32, r: f32, g: f32, b: f32, a: f32) void;
const PathStyle = extern struct {
    x: f32,
    y: f32,
    scale: f32,
    stroke_width: f32,
    r: f32,
    g: f32,
    b: f32,
    a: f32,
    cap: u32,
    join: u32,
};
comptime {
    std.debug.assert(@sizeOf(scene.PathCommand) == 28);
    std.debug.assert(@sizeOf(PathStyle) == 40);
}
extern fn weft_skia_draw_path(s: ?*Shim, commands: [*]const scene.PathCommand, command_count: usize, style: *const PathStyle) void;
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
    /// target format). `want_gpu` requests Ganesh; on failure it silently
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
        const c = scene.linearToSrgbColor(bg);
        weft_skia_clear(self.shim, c[0], c[1], c[2], c[3]);
    }

    /// Draw one pane's explicit scene in view order.
    ///
    /// `linearToSrgbColor` is three `pow` calls, and a frame's items run to
    /// thousands while using on the order of twenty distinct colors — a syntax
    /// palette, reused down every row. Consecutive items almost always share
    /// one, so a single-entry memo removes nearly all of the conversion work
    /// without a hash or an allocation. It is a pure function, so the memo can
    /// only ever return what a recomputation would.
    pub fn drawItems(self: *Skia, items: []const scene.DrawItem) void {
        var last_in: scene.Color = .{ -1, -1, -1, -1 }; // outside the domain
        var last_out: scene.Color = .{ 0, 0, 0, 0 };
        for (items) |item| {
            if (item == .path) {
                const path = item.path;
                const color = scene.linearToSrgbColor(path.color);
                const style: PathStyle = .{
                    .x = path.x,
                    .y = path.y,
                    .scale = path.scale,
                    .stroke_width = path.stroke_width,
                    .r = color[0],
                    .g = color[1],
                    .b = color[2],
                    .a = color[3],
                    .cap = @intFromEnum(path.cap),
                    .join = @intFromEnum(path.join),
                };
                weft_skia_draw_path(self.shim, path.commands.ptr, path.commands.len, &style);
                continue;
            }
            const in = switch (item) {
                .rect => |rect| rect.color,
                .glyph => |glyph| glyph.color,
                .path => unreachable,
            };
            if (!std.mem.eql(f32, &in, &last_in)) {
                last_in = in;
                last_out = scene.linearToSrgbColor(in);
            }
            const c = last_out;
            switch (item) {
                .rect => |rect| weft_skia_draw_rect(self.shim, rect.x, rect.y, rect.w, rect.h, c[0], c[1], c[2], c[3]),
                .glyph => |glyph| weft_skia_draw_glyph(self.shim, glyph.font_id, glyph.glyph_id, glyph.x, glyph.y, glyph.size, c[0], c[1], c[2], c[3]),
                .path => unreachable,
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
