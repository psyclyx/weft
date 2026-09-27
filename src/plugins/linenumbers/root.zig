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
//! **The answer is a formula, not cells.** Provider answers are asked between
//! frames (doc/model.md §2.7), so cells numbered from the caret this plugin
//! was asked with would lag a moving caret by a frame. Instead it answers
//! the gutter's `rule` — "the caret distance (or the line's number), this
//! wide" — and the renderer evaluates it against the snapshot it draws: the
//! column is right on the frame the caret moves, and a caret move asks this
//! plugin nothing at all. The caret line reads in the normal color, the rest
//! as annotation, in both styles.
//!
//! **Width** is fixed per entry: every cell is padded to the digits of the
//! entry's line count, plus one blank column, so the text never shifts as
//! the caret moves or as a number crosses a power of ten on screen.

const std = @import("std");
const weft = @import("weft");
const gutter = @import("weft_gutter");

fn formula() gutter.Formula {
    const s = weft.config("style");
    if (std.mem.eql(u8, s, "relative") or std.mem.eql(u8, s, "hybrid")) return .caret_distance;
    return .number;
}

fn describe() callconv(.c) void {}

fn init() callconv(.c) void {
    // Priority 100: numbers first, then any lower-priority marks column a
    // later provider adds to the same gutter. Text posture AND no tool: an
    // editable projection (a git status you can type into) rests as text
    // too, but its lines are rows of a view, not lines of a file.
    gutter.bind(.{ .all = &.{ .{ .posture = "text" }, .{ .tool = "" } } }, 100);
}

fn digits(n: usize) u32 {
    var d: u32 = 1;
    var v = n;
    while (v >= 10) : (v /= 10) d += 1;
    return d;
}

fn on_slot_fire(session: i32) callconv(.c) void {
    const q = gutter.ask(@bitCast(session)) orelse return;
    gutter.rule(@bitCast(session), .{ .formula = formula(), .width = digits(@max(q.lines, 1)) });
}

comptime {
    weft.exportCallback("describe", &describe);
    weft.exportCallback("init", &init);
    weft.exportCallback("on_slot_fire", &on_slot_fire);
}
