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
/// (pixels of text, padding apart), its first `skip` visual lines scrolled
/// off the top (never past its last line). Scratch-owned.
pub fn layoutDoc(v: *View, scratch: Allocator, markdown: []const u8, max_w: f32, max_h: f32, skip: usize) !Doc {
    const text = try core.markdown.reflow(scratch, std.mem.trim(u8, markdown, "\n"));
    var rope = try stemma.Rope.fromSlice(scratch, text);
    defer rope.deinit(scratch);
    const whole: stemma.Range = .{ .start = 0, .end = rope.byteLen() };
    const attrs = try core.markdown.analyze(scratch, &rope, whole);
    const md: hud_mod.MdInline = .{ .base = 0, .attrs = attrs, .rendered = true };
    const styles = try codeStyles(v, scratch, text, attrs);

    // Laid out at the origin; `drawDoc` places it.
    const saved = v.origin_x;
    v.origin_x = 0;
    defer v.origin_x = saved;

    var runs: std.ArrayList(Run) = .empty;
    var lines: std.ArrayList(layout.VisualLine) = .empty;
    var y: f32 = 0;
    var cut = false;
    // The top of the first line shown: the `skip`th visual line's, once it
    // is laid out — a document scrolled by its owner's keys shows from
    // there. Rows keep coming until `max_h` of them stand below it.
    var top: ?f32 = if (skip == 0) 0 else null;
    const rows = rope.lineCount();
    for (0..rows) |row| {
        if (top) |t| if (y - t >= max_h) {
            cut = true;
            break;
        };
        const mark = lines.items.len;
        try linelayout.layoutRow(v, scratch, scratch, &runs, &rope, row, y, std.math.maxInt(u16), md, styles, &.{}, .{ .width = max_w, .y_limit = std.math.floatMax(f32) }, &lines);
        for (lines.items[mark..]) |l| y = l.baseline_y - l.ascent + l.height;
        if (top == null and lines.items.len > skip) {
            const l = lines.items[skip];
            top = l.baseline_y - l.ascent;
        }
    }
    // Scrolled past the end: the last line stays in view.
    const origin: f32 = top orelse if (lines.items.len > 0) blk: {
        const l = lines.items[lines.items.len - 1];
        break :blk l.baseline_y - l.ascent;
    } else 0;
    // Drop what scrolled off, and bring the rest to the origin.
    var kept_runs: std.ArrayList(Run) = .empty;
    for (runs.items) |r| {
        if (r.baseline_y < origin) continue;
        var placed = r;
        placed.baseline_y -= origin;
        try kept_runs.append(scratch, placed);
    }
    var w: f32 = 0;
    var shown: usize = 0;
    for (lines.items) |l| {
        if (l.baseline_y - l.ascent < origin) continue;
        shown += 1;
        w = @max(w, l.stops[l.stops.len - 1].x);
    }
    var h = y - origin;
    if (h > max_h) {
        cut = true;
        h = max_h;
    }
    return .{ .runs = kept_runs.items, .lines = shown, .w = @min(@ceil(w), max_w), .h = h, .cut = cut };
}

/// Syntax highlight for the document's fenced code, as `StyleInputs` the
/// line layout reads: each fence's body painted by the frame's highlighter
/// (`View.code_hl` — the pane's grammar, or the one the fence names) where
/// there is one. Markdown outside a fence carries no class and keeps its
/// own code colour.
fn codeStyles(v: *View, scratch: Allocator, text: []const u8, attrs: []const core.capability.InlineAttr) !linelayout.StyleInputs {
    const hl = v.code_hl orelse return .{};
    const classes = try scratch.alloc(core.capability.HighlightClass, text.len);
    @memset(classes, .none);
    var painted = false;
    var ls: usize = 0;
    while (ls < text.len) {
        const le = std.mem.indexOfScalarPos(u8, text, ls, '\n') orelse text.len;
        const line = text[ls..le];
        // A fence line: its info string names the language (` ```zig `).
        if (line.len > 0 and attrs[ls].role == .code and attrs[ls].marker and core.markdown.isFence(line)) {
            const lang = fenceLang(line);
            const body_start = le + 1;
            // The body runs to the closing fence (or the end).
            var be = body_start;
            while (be < text.len) {
                const e = std.mem.indexOfScalarPos(u8, text, be, '\n') orelse text.len;
                const l = text[be..e];
                if (attrs[be].role == .code and attrs[be].marker and core.markdown.isFence(l)) break;
                be = e + 1;
            }
            const body_end = @min(be, text.len);
            if (body_start < body_end) {
                if (hl.paint(hl.ctx, lang, text[body_start..body_end], classes[body_start..body_end])) painted = true;
            }
            ls = if (be < text.len) (std.mem.indexOfScalarPos(u8, text, be, '\n') orelse text.len) + 1 else text.len;
            continue;
        }
        ls = le + 1;
    }
    if (!painted) return .{};
    return .{ .hl = classes, .hl_base = 0 };
}

/// The language a fence names: the first word of its info string, or "".
fn fenceLang(line: []const u8) []const u8 {
    var i: usize = 0;
    while (i < line.len and (line[i] == ' ' or line[i] == '`' or line[i] == '~')) i += 1;
    const rest = std.mem.trim(u8, line[i..], " \t");
    const end = std.mem.indexOfAny(u8, rest, " \t{") orelse rest.len;
    return rest[0..end];
}

test "doc_popup: a fence's info string names its language" {
    try std.testing.expectEqualStrings("zig", fenceLang("```zig"));
    try std.testing.expectEqualStrings("rust", fenceLang("  ~~~ rust  "));
    try std.testing.expectEqualStrings("", fenceLang("```"));
    try std.testing.expectEqualStrings("js", fenceLang("```js {.x}"));
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
