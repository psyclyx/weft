//! Renderer-independent scene values.
//!
//! This is the vocabulary produced by the view and consumed by a renderer.
//! It deliberately contains no atlas key, GPU handle, surface, or platform
//! policy: a frame is a sequence of explicit filled rectangles and glyphs.
//!
//! Colors in this module are straight-alpha linear-light RGBA. The view may
//! author colors in sRGB and convert them once at its boundary; a renderer
//! converts to its target encoding when required.

const std = @import("std");

pub const Color = [4]f32;

pub const Vec2 = struct {
    x: f32 = 0,
    y: f32 = 0,
};

/// A two-dimensional affine transform in column-vector notation.
pub const Transform2D = struct {
    xx: f32 = 1,
    xy: f32 = 0,
    tx: f32 = 0,
    yx: f32 = 0,
    yy: f32 = 1,
    ty: f32 = 0,

    pub const identity = Transform2D{};

    pub fn translate(x: f32, y: f32) Transform2D {
        return .{ .tx = x, .ty = y };
    }

    pub fn scale(x: f32, y: f32) Transform2D {
        return .{ .xx = x, .yy = y };
    }

    pub fn multiply(a: Transform2D, b: Transform2D) Transform2D {
        return .{
            .xx = a.xx * b.xx + a.xy * b.yx,
            .xy = a.xx * b.xy + a.xy * b.yy,
            .tx = a.xx * b.tx + a.xy * b.ty + a.tx,
            .yx = a.yx * b.xx + a.yy * b.yx,
            .yy = a.yx * b.xy + a.yy * b.yy,
            .ty = a.yx * b.tx + a.yy * b.ty + a.ty,
        };
    }

    pub fn inverse(self: Transform2D) ?Transform2D {
        const values = [_]f32{ self.xx, self.xy, self.tx, self.yx, self.yy, self.ty };
        for (values) |value| {
            if (!std.math.isFinite(value)) return null;
        }

        // Do the determinant and inverse in f64. This avoids rejecting small
        // but valid transforms through f32 underflow and avoids overflowing
        // intermediate products for large, finite transforms.
        const xx: f64 = self.xx;
        const xy: f64 = self.xy;
        const tx: f64 = self.tx;
        const yx: f64 = self.yx;
        const yy: f64 = self.yy;
        const ty: f64 = self.ty;
        const det = xx * yy - xy * yx;
        if (!std.math.isFinite(det) or det == 0) return null;
        const inv_det = 1.0 / det;
        const result_values = [_]f64{
            yy * inv_det,
            -xy * inv_det,
            -(yy * inv_det * tx - xy * inv_det * ty),
            -yx * inv_det,
            xx * inv_det,
            -(-yx * inv_det * tx + xx * inv_det * ty),
        };
        for (result_values) |value| {
            if (!std.math.isFinite(value) or @abs(value) > std.math.floatMax(f32)) return null;
        }
        return .{
            .xx = @floatCast(result_values[0]),
            .xy = @floatCast(result_values[1]),
            .tx = @floatCast(result_values[2]),
            .yx = @floatCast(result_values[3]),
            .yy = @floatCast(result_values[4]),
            .ty = @floatCast(result_values[5]),
        };
    }

    pub fn applyPoint(self: Transform2D, point: Vec2) Vec2 {
        return .{
            .x = self.xx * point.x + self.xy * point.y + self.tx,
            .y = self.yx * point.x + self.yy * point.y + self.ty,
        };
    }
};

/// A column-major 4×4 transform. The scene currently needs orthographic
/// projection and composition; the representation remains general so callers
/// can validate the projection before deriving a 2D scene-to-pixel transform.
pub const Mat4 = struct {
    data: [16]f32,

    pub const identity = Mat4{ .data = .{
        1, 0, 0, 0,
        0, 1, 0, 0,
        0, 0, 1, 0,
        0, 0, 0, 1,
    } };

    pub fn multiply(a: Mat4, b: Mat4) Mat4 {
        var result: [16]f32 = undefined;
        inline for (0..4) |col| {
            inline for (0..4) |row| {
                var sum: f32 = 0;
                inline for (0..4) |k| {
                    sum += a.data[k * 4 + row] * b.data[col * 4 + k];
                }
                result[col * 4 + row] = sum;
            }
        }
        return .{ .data = result };
    }

    pub fn ortho(left: f32, right: f32, bottom: f32, top: f32, near: f32, far: f32) Mat4 {
        var m = Mat4{ .data = .{0} ** 16 };
        m.data[0] = 2.0 / (right - left);
        m.data[5] = 2.0 / (top - bottom);
        m.data[10] = -2.0 / (far - near);
        m.data[12] = -(right + left) / (right - left);
        m.data[13] = -(top + bottom) / (top - bottom);
        m.data[14] = -(far + near) / (far - near);
        m.data[15] = 1.0;
        return m;
    }
};

/// Project the z=0 plane of an affine MVP into top-left-origin pixel space.
/// Perspective projections are rejected rather than silently approximated.
pub fn mvpToScenePixel(mvp: Mat4, viewport_w: f32, viewport_h: f32) ?Transform2D {
    const m = mvp.data;
    if (!std.math.isFinite(viewport_w) or
        !std.math.isFinite(viewport_h) or
        viewport_w <= 0 or
        viewport_h <= 0)
    {
        return null;
    }
    for (m) |value| {
        if (!std.math.isFinite(value)) return null;
    }

    const o_clip = [3]f32{ m[12], m[13], m[15] };
    const x_clip = [3]f32{ m[0] + m[12], m[1] + m[13], m[3] + m[15] };
    const y_clip = [3]f32{ m[4] + m[12], m[5] + m[13], m[7] + m[15] };

    if (m[3] != 0 or m[7] != 0 or o_clip[2] == 0) return null;

    const inv_w = 1.0 / o_clip[2];
    const half_w = viewport_w * 0.5;
    const half_h = viewport_h * 0.5;
    const o_x = (o_clip[0] * inv_w + 1.0) * half_w;
    const o_y = (1.0 - o_clip[1] * inv_w) * half_h;
    const x_x = (x_clip[0] * inv_w + 1.0) * half_w;
    const x_y = (1.0 - x_clip[1] * inv_w) * half_h;
    const y_x = (y_clip[0] * inv_w + 1.0) * half_w;
    const y_y = (1.0 - y_clip[1] * inv_w) * half_h;

    const result = Transform2D{
        .xx = x_x - o_x,
        .yx = x_y - o_y,
        .xy = y_x - o_x,
        .yy = y_y - o_y,
        .tx = o_x,
        .ty = o_y,
    };
    return if (result.inverse() != null) result else null;
}

/// One explicit axis-aligned filled-rectangle draw item. Keeping the geometry
/// axis-aligned is intentional: every renderer currently honors rectangles as
/// pixel-space bounds, not arbitrary affine paths.
pub const RectItem = struct {
    x: f32 = 0,
    y: f32 = 0,
    w: f32 = 0,
    h: f32 = 0,
    color: Color = .{ 1, 1, 1, 1 },
};

/// One explicit glyph draw item. `glyph_id` is the face-local OpenType glyph
/// id returned by the text shaper; it is not a renderer or atlas key.
pub const GlyphItem = struct {
    font_id: u32,
    glyph_id: u32,
    x: f32,
    y: f32,
    size: f32,
    color: Color,
};

/// The complete renderer-neutral scene vocabulary currently needed by the UI.
pub const DrawItem = union(enum) {
    rect: RectItem,
    glyph: GlyphItem,
};

/// One channel, sRGB-encoded → linear light.
pub fn srgbToLinear(v: f32) f32 {
    if (v <= 0.04045) return v / 12.92;
    return std.math.pow(f32, (v + 0.055) / 1.055, 2.4);
}

/// One channel, linear light → sRGB-encoded.
pub fn linearToSrgb(v: f32) f32 {
    if (v <= 0.0031308) return v * 12.92;
    return 1.055 * std.math.pow(f32, v, 1.0 / 2.4) - 0.055;
}

pub fn srgbToLinearColor(color: Color) Color {
    return .{ srgbToLinear(color[0]), srgbToLinear(color[1]), srgbToLinear(color[2]), color[3] };
}

pub fn linearToSrgbColor(color: Color) Color {
    return .{
        linearToSrgb(std.math.clamp(color[0], 0, 1)),
        linearToSrgb(std.math.clamp(color[1], 0, 1)),
        linearToSrgb(std.math.clamp(color[2], 0, 1)),
        std.math.clamp(color[3], 0, 1),
    };
}

test "scene: orthographic projection maps the framebuffer corners" {
    const projection = Mat4.ortho(0, 100, 50, 0, -1, 1);
    const transform = mvpToScenePixel(projection, 200, 100) orelse return error.TestExpectedTransform;
    const origin = transform.applyPoint(.{});
    const corner = transform.applyPoint(.{ .x = 100, .y = 50 });
    try std.testing.expectApproxEqAbs(@as(f32, 0), origin.x, 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 0), origin.y, 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 200), corner.x, 1e-3);
    try std.testing.expectApproxEqAbs(@as(f32, 100), corner.y, 1e-3);
}

test "scene: perspective and invalid viewports are rejected" {
    var perspective = Mat4.identity;
    perspective.data[3] = 1.0e-7;
    try std.testing.expectEqual(@as(?Transform2D, null), mvpToScenePixel(perspective, 100, 100));
    try std.testing.expectEqual(@as(?Transform2D, null), mvpToScenePixel(Mat4.identity, 0, 100));
    try std.testing.expectEqual(@as(?Transform2D, null), mvpToScenePixel(Mat4.identity, 100, std.math.nan(f32)));
}

test "scene: affine transforms compose and invert" {
    const transform = Transform2D.multiply(Transform2D.translate(10, -5), Transform2D.scale(2, 3));
    const point = transform.applyPoint(.{ .x = 4, .y = 2 });
    try std.testing.expectApproxEqAbs(@as(f32, 18), point.x, 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 1), point.y, 1e-5);
    const inverse = transform.inverse() orelse return error.TestExpectedInverse;
    const round_trip = inverse.applyPoint(point);
    try std.testing.expectApproxEqAbs(@as(f32, 4), round_trip.x, 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 2), round_trip.y, 1e-5);
}

test "scene: color transfer round-trips" {
    try std.testing.expectEqual(@as(f32, 0), srgbToLinear(0));
    try std.testing.expectApproxEqAbs(@as(f32, 1), srgbToLinear(1), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1), linearToSrgb(1), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.2140), srgbToLinear(0.5), 1e-3);
    const source: Color = .{ 0.05, 0.5, 0.95, 0.37 };
    const round_trip = linearToSrgbColor(srgbToLinearColor(source));
    for (source, round_trip) |expected, actual| {
        try std.testing.expectApproxEqAbs(expected, actual, 1e-5);
    }
}

test "scene: target colors are clamped at the renderer boundary" {
    const converted = linearToSrgbColor(.{ -0.5, 0.25, 2, 1.5 });
    try std.testing.expectEqual(@as(f32, 0), converted[0]);
    try std.testing.expect(converted[1] > 0 and converted[1] < 1);
    try std.testing.expectEqual(@as(f32, 1), converted[2]);
    try std.testing.expectEqual(@as(f32, 1), converted[3]);
}

test "scene: draw items carry explicit rect and glyph data" {
    const rect: DrawItem = .{ .rect = .{ .x = 4, .y = 8, .w = 10, .h = 12, .color = .{ 1, 0, 0, 1 } } };
    const glyph: DrawItem = .{ .glyph = .{ .font_id = 3, .glyph_id = 42, .x = 12, .y = 20, .size = 16, .color = .{ 0, 1, 0, 1 } } };
    try std.testing.expectEqual(@as(f32, 4), rect.rect.x);
    try std.testing.expectEqual(@as(f32, 12), rect.rect.h);
    try std.testing.expectEqual(@as(u32, 42), glyph.glyph.glyph_id);
}
