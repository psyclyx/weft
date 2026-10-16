//! The chrome's own text (doc/chrome.md §3.4): what size and face every
//! chrome label — a menubar title, a button, a menu row, a tab, a status
//! segment, a tooltip — is set in, and how wide a label is.
//!
//! Under `widget` the chrome speaks a desktop's UI font: the sans face at
//! `theme/ui-scale` of the editor's size, measured in pixels. Under the text
//! styles it is the editor's mono cells, exactly — a label is as wide as its
//! codepoints, so those styles stay on the cell grid and nothing about them
//! moves. Every chrome measure goes through `width`, so a style that sets
//! chrome in another face changes no layout code.

const std = @import("std");
const text_engine = @import("weft_text");
const fonts = @import("../fonts.zig");

/// The chrome's metrics, refreshed whenever the editor's size, the chrome
/// style or `theme/ui-scale` changes (`View.refreshUi`).
pub const Metrics = struct {
    em: f32 = 16,
    line_h: f32 = 16,
    ascent: f32 = 12,
    /// Set in the sans face, measured by shaping; else mono cells.
    sans: bool = false,
    /// The mono cell, the unit the text styles measure in.
    cell_w: f32 = 8,
};

/// The sans face's line metrics per em, read once from the font.
pub const Face = struct {
    ascent: f32,
    height: f32,

    pub fn of(set: *const fonts.FaceSet) Face {
        const font = set.fonts[1];
        const upem: f32 = @floatFromInt(font.unitsPerEm());
        const lm = font.lineMetrics() catch return .{ .ascent = 0.8, .height = 1.2 };
        const ascent: f32 = @floatFromInt(lm.ascent);
        const descent: f32 = @floatFromInt(lm.descent);
        const gap: f32 = @floatFromInt(lm.line_gap);
        return .{ .ascent = ascent / upem, .height = (ascent - descent + gap) / upem };
    }
};

/// The default `theme/ui-scale`: chrome a little smaller than the text it
/// frames, as a desktop's UI font is beside an editor's.
pub const default_scale: f32 = 0.85;

/// A chrome text line, per em.
pub const line_scale: f32 = 1.3;

/// The metrics for an editor at `em` with `cell_w`/`line_h`/`ascent`, under
/// a style that does (`sans`) or does not set chrome in the sans face.
pub fn metrics(face: Face, sans: bool, scale: f32, editor: Metrics) Metrics {
    if (!sans) return .{ .em = editor.em, .line_h = editor.line_h, .ascent = editor.ascent, .sans = false, .cell_w = editor.cell_w };
    const em = @round(editor.em * scale);
    // A UI line is the size's own, not the face's (a sans face's line can be
    // far looser than a mono one's): the glyphs centred in it.
    const line_h = @round(em * line_scale);
    return .{
        .em = em,
        .line_h = line_h,
        .ascent = @round((line_h - em * face.height) / 2 + em * face.ascent),
        .sans = true,
        .cell_w = editor.cell_w,
    };
}

/// Measured widths of sans labels at one em, so a label shaped to be
/// measured this frame is not shaped again to be measured the next. Direct
/// mapped: a collision costs one more shaping, never a wrong width (the key
/// is the text's full hash and the em).
pub const Widths = struct {
    const slots = 512;
    keys: [slots]u64 = @splat(0),
    widths: [slots]f32 = @splat(0),

    fn key(label: []const u8, em: f32) u64 {
        var h = std.hash.Wyhash.init(@as(u32, @bitCast(em)));
        h.update(label);
        return h.final() | 1; // never 0, the empty slot
    }

    /// `label`'s advance in the sans face at `em`, in pixels.
    pub fn of(self: *Widths, set: *const fonts.FaceSet, label: []const u8, em: f32) f32 {
        if (label.len == 0) return 0;
        const k = key(label, em);
        const slot: usize = @intCast(k % slots);
        if (self.keys[slot] == k) return self.widths[slot];
        var buf: [16 * 1024]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&buf);
        const shaped = text_engine.shape(fba.allocator(), &set.body, label, .{}) catch
            return @as(f32, @floatFromInt(std.unicode.utf8CountCodepoints(label) catch label.len)) * em * 0.55;
        const w = shaped.advanceX() * em;
        self.keys[slot] = k;
        self.widths[slot] = w;
        return w;
    }
};
