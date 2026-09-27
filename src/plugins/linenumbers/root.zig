//! linenumbers — a line-number column, as an ordinary gutter provider.
//!
//! It binds `ui/gutter-segment` (the slot core declares, `core/gutter.zig`)
//! for TEXT entries only — the predicate is `posture == text` with no `tool`,
//! evaluated by the host against the pane's entry, so a git status, a file
//! listing, or a dashboard never asks this plugin anything. Core knows none of what
//! follows: what a line number is, where it counts from, or how wide it is.
//!
//! **Styles** (`weft.set("linenumbers", "style", …)`), read every round so a
//! config reload applies on the next frame:
//!
//!   · `absolute` (the default): every line shows its own number.
//!   · `relative`: every line shows its distance from the caret line, and
//!     the caret line shows its OWN absolute number — vim's
//!     `number relativenumber`, which is the useful form of relative numbers
//!     (a bare 0 on the caret line says nothing).
//!   · `hybrid` is accepted as a synonym for `relative`, the name some
//!     editors give that same combination.
//!
//! **Width** is fixed per entry: every cell is padded to the digits of the
//! entry's line count, plus one blank column, so the text never shifts as
//! the caret moves or as a number crosses a power of ten on screen.

const std = @import("std");
const weft = @import("weft");
const gutter = @import("weft_gutter");

const Style = enum { absolute, relative };

fn style() Style {
    const s = weft.config("style");
    if (std.mem.eql(u8, s, "relative") or std.mem.eql(u8, s, "hybrid")) return .relative;
    return .absolute;
}

fn describe() callconv(.c) void {}

fn init() callconv(.c) void {
    // Priority 100: numbers first, then any lower-priority marks column a
    // later provider adds to the same gutter. Text posture AND no tool: an
    // editable projection (a git status you can type into) rests as text
    // too, but its lines are rows of a view, not lines of a file.
    gutter.bind(.{ .all = &.{ .{ .posture = "text" }, .{ .tool = "" } } }, 100);
}

fn digits(n: usize) usize {
    var d: usize = 1;
    var v = n;
    while (v >= 10) : (v /= 10) d += 1;
    return d;
}

/// One window's text, all cells packed into this — each cell is at most
/// `max_width` bytes, so a full window always fits.
const max_width = 12;
var text_buf: [gutter_window * max_width]u8 = undefined;
var cells: [gutter_window]gutter.Cell = undefined;
/// The host's window size (`core.gutter.window`); a larger ask is answered
/// up to this many lines, and the host asks again past them.
const gutter_window = 256;

/// The cell for `line` (0-based), right-aligned in `width` digits and
/// followed by one blank column.
fn cellText(buf: []u8, line: usize, caret: usize, width: usize, s: Style) []const u8 {
    const n = switch (s) {
        .absolute => line + 1,
        .relative => if (line == caret) line + 1 else if (line > caret) line - caret else caret - line,
    };
    return std.fmt.bufPrint(buf, "{d: >[1]} ", .{ n, width }) catch "";
}

fn on_slot_fire(session: i32) callconv(.c) void {
    const q = gutter.ask(@bitCast(session)) orelse return;
    const s = style();
    const width = @min(digits(@max(q.lines, 1)), max_width - 1);
    const count = @min(q.count, gutter_window);
    var used: usize = 0;
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const line = q.first + i;
        if (line >= q.lines) break;
        const text = cellText(text_buf[used..][0..max_width], line, q.caret, width, s);
        used += text.len;
        cells[i] = .{ .text = text, .role = if (line == q.caret) .normal else .annotation };
    }
    gutter.tell(@bitCast(session), q.first, cells[0..i]);
}

comptime {
    weft.exportCallback("describe", &describe);
    weft.exportCallback("init", &init);
    weft.exportCallback("on_slot_fire", &on_slot_fire);
}
