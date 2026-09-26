//! `gw`: goto word. Every word in view gets a two-character label drawn over
//! its first two characters (the `labels` library, on the overlay and
//! view-range doors of doc/configs.md §0.3); typing a label selects that
//! word — or, in select mode, extends the primary to it — as the one
//! selection left.
//!
//! A word is a run of at least two word characters, as in helix: `=<` is no
//! word, and neither is a lone `a`. Labels go out nearest first, alternating
//! after and before the cursor, so the easy labels land close by.

const std = @import("std");
const weft = @import("weft");
const labels_mod = @import("weft_labels");
const sel = @import("selection.zig");
const text = @import("text.zig");

/// The mode that reads a label's keys.
pub const mode = "helix-goto-word";
const layer_name = "helix-goto-word";
/// Helix's `jump-label-alphabet`.
const default_alphabet = "abcdefghijklmnopqrstuvwxyz";

var shown: labels_mod.Set = .{};
var words: [labels_mod.max_targets]weft.Range = undefined;
var starts: [labels_mod.max_targets]usize = undefined;
var how: sel.Mode = .move;

fn isWord(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c >= 0x80;
}

/// The words of `r` (at least two word characters each), in document order.
fn scan(r: weft.Range, out: []weft.Range) usize {
    var k: usize = 0;
    var i = r.start;
    while (i < r.end and k < out.len) {
        const c = text.at(i) orelse break;
        if (!isWord(c)) {
            i += 1;
            continue;
        }
        const from = i;
        while (i < r.end and isWord(text.at(i) orelse ' ')) i += 1;
        if (i - from >= 2) {
            out[k] = .{ .start = from, .end = i };
            k += 1;
        }
    }
    return k;
}

/// Label the words in view; the next two keys pick one.
pub fn start(m: sel.Mode) void {
    if (!sel.load()) return;
    const view = weft.viewRange() orelse weft.lineAt(sel.items[sel.primary].head);
    var found: [labels_mod.max_targets]weft.Range = undefined;
    const total = scan(view, &found);
    if (total == 0) return weft.echo("no words in view");
    const configured = weft.config("jump-label-alphabet");
    const alphabet = if (configured.len > 0) configured else default_alphabet;
    const cap = labels_mod.Set.capacity(alphabet, 2);

    // Nearest first, alternating after and before the cursor.
    const cursor = sel.items[sel.primary].head;
    var after = for (found[0..total], 0..) |w, i| {
        if (w.start >= cursor) break i;
    } else total;
    var before = after;
    var n: usize = 0;
    while (n < cap and (after < total or before > 0)) {
        if (after < total) {
            words[n] = found[after];
            after += 1;
            n += 1;
        }
        if (n < cap and before > 0) {
            before -= 1;
            words[n] = found[before];
            n += 1;
        }
    }
    for (words[0..n], starts[0..n]) |w, *s| s.* = w.start;
    how = m;
    if (!shown.show(layer_name, starts[0..n], alphabet, 2)) return weft.echo("gw: cannot draw labels here");
    weft.setMode(mode);
}

/// A label key: narrow, pick, or give up.
pub fn key() void {
    const typed = weft.argStr(0) orelse return cancel();
    switch (shown.press(typed)) {
        .pending => {},
        .none => leave(),
        .chosen => |i| {
            leave();
            const w = words[i];
            if (!sel.load()) return;
            weft.jumpPush();
            // One selection afterwards, as in helix: the jump is the
            // primary's, and the others do not come along.
            const anchor = sel.items[sel.primary].anchor;
            sel.items[0] = switch (how) {
                .move => .{ .anchor = w.start, .head = w.end },
                .extend => .{ .anchor = anchor, .head = if (w.start >= anchor) w.end else w.start },
            };
            sel.n = 1;
            sel.primary = 0;
            sel.store();
        },
    }
}

pub fn cancel() void {
    shown.clear();
    leave();
}

fn leave() void {
    if (how == .extend) weft.setMode("helix-select") else weft.exitToResting();
}
