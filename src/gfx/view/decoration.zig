//! Decorations — selection washes, carets, and peer-color derivation.
//!
//! Free functions over `*View` that read the frame's geometry map and append
//! solid rects. Split out of `view.zig`; `build` derives selection → caret →
//! peer decorations from the same stops the picture is shaped from.

const std = @import("std");
const Allocator = std.mem.Allocator;

const snail = @import("snail");
const stemma = @import("stemma");
const layout = @import("../layout.zig");
const view = @import("../view.zig");

const View = view.View;
const Rect = view.Rect;
const CursorStyle = view.CursorStyle;

pub fn selectionRects(v: *View, scratch: Allocator, rects: *std.ArrayList(Rect), sel: stemma.Range, color: [4]f32) !void {
    for (v.frame_layout.lines) |*vl| {
        const s = @max(sel.start, vl.src.start);
        const e = @min(sel.end, vl.src.end);
        if (s >= e) continue;
        const x0 = vl.xAt(s);
        const x1 = vl.xAt(e);
        try rects.append(scratch, .{
            .x = x0,
            .y = vl.baseline_y - vl.ascent,
            .w = @max(1, x1 - x0),
            .h = vl.height,
            .color = color,
        });
    }
}

/// A peer's caret/selection color from its identity hue (fixed
/// saturation, caller-chosen lightness/alpha so a caret reads solid and
/// a selection reads as a translucent wash). Authored in sRGB, returned
/// linear like the rest of the theme.
pub fn peerColor(hue: f32, light: f32, alpha: f32) [4]f32 {
    return snail.color.srgbToLinearColor(hslToSrgb(hue, 0.65, light, alpha));
}

fn hslToSrgb(h: f32, s: f32, l: f32, a: f32) [4]f32 {
    const c = (1 - @abs(2 * l - 1)) * s;
    const hp = h * 6;
    const x = c * (1 - @abs(@mod(hp, 2) - 1));
    var r: f32 = 0;
    var g: f32 = 0;
    var b: f32 = 0;
    if (hp < 1) {
        r = c;
        g = x;
    } else if (hp < 2) {
        r = x;
        g = c;
    } else if (hp < 3) {
        g = c;
        b = x;
    } else if (hp < 4) {
        g = x;
        b = c;
    } else if (hp < 5) {
        r = x;
        b = c;
    } else {
        r = c;
        b = x;
    }
    const m = l - c / 2;
    return .{ r + m, g + m, b + m, a };
}

pub fn caretRect(v: *View, scratch: Allocator, rects: *std.ArrayList(Rect), off: usize, style: CursorStyle, color: [4]f32) !void {
    const li = v.frame_layout.lineForOffset(off) orelse return;
    const vl = &v.frame_layout.lines[li];
    const c = vl.caretAt(off);
    const w = caretWidth(v, vl, off);
    const rect: Rect = switch (style) {
        .block => .{ .x = c.x, .y = c.y_top, .w = w, .h = c.height, .color = color },
        .bar => .{ .x = c.x - 1, .y = c.y_top, .w = 2, .h = c.height, .color = color },
        .underline => .{ .x = c.x, .y = c.y_top + c.height - 2, .w = w, .h = 2, .color = color },
    };
    try rects.append(scratch, rect);
}

/// Caret cell width: to the next caret stop, or one em-ish at line end.
fn caretWidth(v: *const View, vl: *const layout.VisualLine, off: usize) f32 {
    const x0 = vl.xAt(off);
    for (vl.stops) |s| {
        if (s.off > off and s.x > x0) return s.x - x0;
    }
    return v.cell_w;
}
