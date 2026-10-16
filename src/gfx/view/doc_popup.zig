//! A markdown document in a popup — whatever a plugin hands a caret surface
//! as its body (`Surface.info`): a hover's text, a completion item's docs, a
//! signature's help. Core knows none of those; it knows a document.
//!
//! Nothing here parses or draws markdown of its own: the text is read the
//! way markdown reads (`core.markdown.reflow` joins a paragraph's lines), the
//! inline analysis is the one every markdown entry gets
//! (`core.markdown.analyze`), and the rows are laid out by the same
//! `linelayout.layoutRow` a markdown pane uses — rendered rather than edited
//! (`MdInline.rendered`: syntax markers drop out) and soft-wrapped to the
//! popup's width.

const std = @import("std");
const Allocator = std.mem.Allocator;

const core = @import("weft_core");
const stemma = @import("stemma");
const region = @import("../region.zig");
const layout = @import("../layout.zig");
const View = @import("View.zig");
const linelayout = @import("linelayout.zig");
const hud_mod = @import("hud.zig");

const Run = View.Run;

/// A document laid out from (0, 0): its runs, and the room it took.
pub const Doc = struct {
    runs: []const Run,
    lines: usize,
    w: f32,
    h: f32,
    /// More of it than `max_h` let show.
    cut: bool,
};

/// The room between a popup's edge and its document.
pub fn padX(v: *const View) f32 {
    return v.cell_w;
}
pub fn padY(v: *const View) f32 {
    return @round(v.line_h * 0.3);
}

/// Lay `markdown` out no wider than `max_w` and no taller than `max_h`
/// (pixels of text, padding apart). Scratch-owned.
pub fn layoutDoc(v: *View, scratch: Allocator, markdown: []const u8, max_w: f32, max_h: f32) !Doc {
    const text = try core.markdown.reflow(scratch, std.mem.trim(u8, markdown, "\n"));
    var rope = try stemma.Rope.fromSlice(scratch, text);
    defer rope.deinit(scratch);
    const whole: stemma.Range = .{ .start = 0, .end = rope.byteLen() };
    const attrs = try core.markdown.analyze(scratch, &rope, whole);
    const md: hud_mod.MdInline = .{ .base = 0, .attrs = attrs, .rendered = true };

    // Laid out at the origin; `drawDoc` places it.
    const saved = v.origin_x;
    v.origin_x = 0;
    defer v.origin_x = saved;

    var runs: std.ArrayList(Run) = .empty;
    var lines: std.ArrayList(layout.VisualLine) = .empty;
    var y: f32 = 0;
    var cut = false;
    const rows = rope.lineCount();
    for (0..rows) |row| {
        if (y >= max_h) {
            cut = true;
            break;
        }
        const mark = lines.items.len;
        try linelayout.layoutRow(v, scratch, scratch, &runs, &rope, row, y, std.math.maxInt(u16), md, .{}, &.{}, .{ .width = max_w, .y_limit = max_h }, &lines);
        for (lines.items[mark..]) |l| y = l.baseline_y - l.ascent + l.height;
    }
    var w: f32 = 0;
    for (lines.items) |l| w = @max(w, l.stops[l.stops.len - 1].x);
    if (y > max_h) {
        cut = true;
        y = max_h;
    }
    return .{ .runs = runs.items, .lines = lines.items.len, .w = @min(@ceil(w), max_w), .h = y, .cut = cut };
}

/// Draw `doc` with its top-left at (x, y), clipped to `clip`.
pub fn drawDoc(scratch: Allocator, runs: *std.ArrayList(Run), doc: Doc, x: f32, y: f32, clip: region.Rect) !void {
    for (doc.runs) |r| {
        var placed = r;
        placed.baseline_y += y;
        switch (placed.place) {
            .prop => |*p| p.x += x,
            // A mono run's cells sit on the pane's grid, not the popup's: a
            // rendered document is proportional through and through.
            .cell => continue,
        }
        placed.clip = clip;
        try runs.append(scratch, placed);
    }
}
