//! The selection set, and every verb that reshapes it without editing.
//!
//! Helix works on SEVERAL selections at once. Core holds them (doc/configs.md
//! §0.1) and answers one record of `{anchor, head}` pairs; every verb here
//! reads that set, computes the next one, and hands it back in one
//! `setSelections`. None of them loops over "the cursor": a verb that works on
//! one selection is the one-iteration case of the same loop.

const std = @import("std");
const weft = @import("weft");
const text = @import("text.zig");

pub const Sel = weft.Selection;
pub const max = weft.max_selections;

/// The set this command works on, copied out of the SDK's scratch (which
/// `addSelection` and friends reuse under us).
pub var items: [max]Sel = undefined;
pub var n: usize = 0;
pub var primary: usize = 0;

/// Read the current set. False for an entry with no text.
pub fn load() bool {
    const set = weft.selections();
    n = set.items.len;
    primary = set.primary;
    @memcpy(items[0..n], set.items);
    text.begin();
    return n > 0;
}

/// Hand the (edited) set back. Core sorts and merges it.
pub fn store() void {
    if (n == 0) return;
    _ = weft.setSelections(items[0..n], @min(primary, n - 1));
}

/// Helix's unit of action: the selection, or the one character under a caret
/// (a helix selection is never empty). The ONE place a verb reads what it
/// acts on.
pub fn span(s: Sel) weft.Range {
    const r = s.range();
    if (r.end > r.start) return r;
    return .{ .start = r.start, .end = @min(r.start + 1, text.len()) };
}

pub fn primarySpan() weft.Range {
    return span(items[@min(primary, n -| 1)]);
}

/// Whether `r` is whole lines: from a line start through a line's newline
/// (or the end of the buffer).
pub fn isLinewise(r: weft.Range) bool {
    if (r.end <= r.start) return false;
    if (weft.lineAt(r.start).start != r.start) return false;
    if (r.end == text.len()) return true;
    return weft.lineAt(r.end - 1).end + 1 == r.end;
}

pub fn caret(off: usize) Sel {
    return .{ .anchor = off, .head = off };
}

/// Briefly mark what an operation produced.
/// TODO(doc/configs.md §0.4): flash every selection once the flash is a set;
/// today it takes one range, so it marks the primary.
pub fn flashPrimary() void {
    if (n == 0) return;
    const r = primarySpan();
    weft.flash(r.start, r.end);
}

// ── Motions over every selection ────────────────────────────────────────

/// A motion: the next selection from this one, or null where it cannot move.
pub const Motion = *const fn (s: Sel) ?Sel;

/// Move (a fresh selection per motion) or extend (the anchor stays; only the
/// head follows the motion) — helix's normal and select modes.
pub const Mode = enum { move, extend };

/// Apply `m` to every selection, `count` times.
pub fn applyMotion(m: Motion, mode: Mode, count: u32) void {
    if (!load()) return;
    for (items[0..n]) |*s| {
        const anchor = s.anchor;
        var cur = s.*;
        var k = count;
        while (k > 0) : (k -= 1) {
            const next = m(cur) orelse break;
            cur = switch (mode) {
                .move => next,
                .extend => .{ .anchor = anchor, .head = next.head },
            };
        }
        s.* = cur;
    }
    store();
}

/// A point motion: a caret at `target(head)`.
pub fn point(comptime target: fn (usize) ?usize) Motion {
    return struct {
        fn m(s: Sel) ?Sel {
            return caret(target(s.head) orelse return null);
        }
    }.m;
}

/// Run a range-returning command once per selection (a motion, a text object,
/// a tree node) and set each selection to what it answered — `move` to the
/// range itself, `extend` to the old anchor and the range's far end. A
/// selection the command answered nothing for stays as it was.
pub fn applyRangeCommand(cmd: []const u8, mode: Mode) void {
    if (!load()) return;
    var handles: [max]?u32 = undefined;
    const hs = weft.runRangeEach(cmd, &handles);
    for (hs, 0..) |h, i| {
        if (i >= n) break;
        const r = weft.rangeEnds(h orelse continue) orelse continue;
        items[i] = switch (mode) {
            .move => .{ .anchor = r.start, .head = r.end },
            .extend => .{ .anchor = items[i].anchor, .head = if (r.end > items[i].anchor) r.end else r.start },
        };
    }
    store();
}

/// Run a cursor-anchored motion (`[cursor, target]`, the `motions` plugin's
/// shape) once per selection and move each head to its target.
pub fn applyCursorMotion(cmd: []const u8, mode: Mode) void {
    if (!load()) return;
    var handles: [max]?u32 = undefined;
    const hs = weft.runRangeEach(cmd, &handles);
    for (hs, 0..) |h, i| {
        if (i >= n) break;
        const r = weft.rangeEnds(h orelse continue) orelse continue;
        const target = if (r.start == items[i].head) r.end else r.start;
        items[i] = switch (mode) {
            .move => caret(target),
            .extend => .{ .anchor = items[i].anchor, .head = target },
        };
    }
    store();
}

// ── Reshaping the set ───────────────────────────────────────────────────

/// `x`: select each selection's lines, newline included; on a selection that
/// is already whole lines, take the next line too — so `x x d` takes two.
/// A count takes that many lines.
pub fn selectLines(count: u32) void {
    if (!load()) return;
    for (items[0..n]) |*s| {
        var k = count;
        while (k > 0) : (k -= 1) {
            const r = span(s.*);
            const grow = isLinewise(r) and r.end < text.len();
            const first = weft.lineAt(r.start).start;
            const last = weft.lineAt(if (grow) r.end else @max(r.start, r.end -| 1));
            s.* = .{ .anchor = first, .head = @min(last.end + 1, text.len()) };
        }
    }
    store();
}

/// `X`: stretch each selection to its line bounds, without growing past them.
pub fn toLineBounds() void {
    if (!load()) return;
    for (items[0..n]) |*s| {
        const r = span(s.*);
        const first = weft.lineAt(r.start).start;
        const last = weft.lineAt(@max(r.start, r.end -| 1));
        s.* = .{ .anchor = first, .head = @min(last.end + 1, text.len()) };
    }
    store();
}

/// `%`: one selection over the whole document.
pub fn selectAll() void {
    if (!load()) return;
    items[0] = .{ .anchor = 0, .head = text.len() };
    n = 1;
    primary = 0;
    store();
}

/// `;`: collapse every selection onto its head.
pub fn collapse() void {
    if (!load()) return;
    for (items[0..n]) |*s| s.* = caret(s.head);
    store();
}

/// `A-;`: swap each selection's anchor and head.
pub fn flip() void {
    if (!load()) return;
    for (items[0..n]) |*s| s.* = .{ .anchor = s.head, .head = s.anchor };
    store();
}

/// `A-:`: point every selection forward (head after anchor).
pub fn ensureForward() void {
    if (!load()) return;
    for (items[0..n]) |*s| if (s.head < s.anchor) {
        s.* = .{ .anchor = s.head, .head = s.anchor };
    };
    store();
}

/// `,`: keep only the primary.
pub fn keepPrimary() void {
    _ = weft.collapseSelections();
}

/// `A-,`: drop the primary (never the last selection).
pub fn removePrimary() void {
    if (!load()) return;
    _ = weft.removeSelection(primary);
}

/// `(` / `)`: make the previous / next selection the primary, cyclically.
pub fn rotate(forward: bool) void {
    if (!load()) return;
    primary = if (forward) (primary + 1) % n else (primary + n - 1) % n;
    store();
}

/// The column-preserving copy of `s` onto the line `delta` lines away, or
/// null where that line is too short (or not there).
fn onLine(s: Sel, delta: isize) ?Sel {
    const shift = struct {
        fn f(off: usize, d: isize) ?usize {
            const l = weft.lineAt(off);
            const col = off - l.start;
            var target = l;
            var k = d;
            while (k != 0) {
                if (k > 0) {
                    if (target.end >= text.len()) return null;
                    target = weft.lineAt(target.end + 1);
                    k -= 1;
                } else {
                    if (target.start == 0) return null;
                    target = weft.lineAt(target.start - 1);
                    k += 1;
                }
            }
            if (target.start + col > target.end) return null;
            return target.start + col;
        }
    }.f;
    return .{ .anchor = shift(s.anchor, delta) orelse return null, .head = shift(s.head, delta) orelse return null };
}

/// `C` / `A-C`: copy the primary selection onto the next (previous) line it
/// fits on, as the new primary — once per count. A selection spanning lines
/// copies by its own height.
pub fn copyToLine(forward: bool, count: u32) void {
    var k = count;
    while (k > 0) : (k -= 1) {
        if (!load()) return;
        const s = items[primary];
        const r = s.range();
        const first = weft.lineAt(r.start);
        var height: isize = 1;
        var l = first;
        while (l.end < r.end and l.end < text.len()) : (height += 1) l = weft.lineAt(l.end + 1);
        const step: isize = if (forward) 1 else -1;
        var delta: isize = height * step;
        const copy = while (lineExists(first.start, delta)) : (delta += step) {
            if (onLine(s, delta)) |c| break c;
        } else return;
        if (!weft.addSelection(copy)) return;
    }
}

fn lineExists(off: usize, delta: isize) bool {
    var l = weft.lineAt(off);
    var k = delta;
    while (k != 0) {
        if (k > 0) {
            if (l.end >= text.len()) return false;
            l = weft.lineAt(l.end + 1);
            k -= 1;
        } else {
            if (l.start == 0) return false;
            l = weft.lineAt(l.start - 1);
            k += 1;
        }
    }
    return true;
}

fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r';
}

/// `_`: trim blanks off both ends of every selection; a selection that is all
/// blanks goes away (unless it is the last one).
pub fn trim() void {
    if (!load()) return;
    var kept: usize = 0;
    var new_primary: usize = 0;
    for (items[0..n], 0..) |s, i| {
        const r = s.range();
        var a = r.start;
        var b = r.end;
        while (a < b and isSpace(text.at(a).?)) a += 1;
        while (b > a and isSpace(text.at(b - 1).?)) b -= 1;
        if (a == b and r.end > r.start) continue;
        if (i == primary) new_primary = kept;
        items[kept] = if (s.head >= s.anchor) .{ .anchor = a, .head = b } else .{ .anchor = b, .head = a };
        kept += 1;
    }
    if (kept == 0) return;
    n = kept;
    primary = new_primary;
    store();
}

/// `A-s`: split every selection into one selection per line it covers.
pub fn splitLines() void {
    if (!load()) return;
    var out: [max]Sel = undefined;
    var m: usize = 0;
    var new_primary: usize = 0;
    for (items[0..n], 0..) |s, i| {
        const r = s.range();
        if (i == primary) new_primary = m;
        var l = weft.lineAt(r.start);
        var from = r.start;
        while (m < max) {
            const to = @min(r.end, l.end);
            if (to > from or r.end == r.start) {
                out[m] = .{ .anchor = from, .head = to };
                m += 1;
            }
            if (l.end >= r.end or l.end >= text.len()) break;
            l = weft.lineAt(l.end + 1);
            from = l.start;
        }
    }
    if (m == 0) return;
    @memcpy(items[0..m], out[0..m]);
    n = m;
    primary = new_primary;
    store();
}

// ── Tree-sitter selection history ───────────────────────────────────────
// `A-o` grows every selection a node; `A-i` walks back down the way it came
// (the sets `A-o` replaced), and only once that trail is spent asks the tree
// for a child. The trail is only valid while the set is still exactly what
// the last `A-o` left: any other change breaks it.

const trail_depth = 8;
const Snapshot = struct { n: usize, primary: usize, items: [max]Sel };
var trail: [trail_depth]Snapshot = undefined;
var trail_len: usize = 0;
var trail_mark: u64 = 0;

fn fingerprint() u64 {
    var h = std.hash.Wyhash.init(0);
    h.update(std.mem.asBytes(&n));
    h.update(std.mem.sliceAsBytes(items[0..n]));
    return h.final();
}

/// `A-o` / `A-up`: expand every selection to its enclosing node.
pub fn expand() void {
    if (!load()) return;
    if (trail_len > 0 and fingerprint() != trail_mark) trail_len = 0;
    if (trail_len == trail_depth) {
        std.mem.copyForwards(Snapshot, trail[0 .. trail_depth - 1], trail[1..trail_depth]);
        trail_len -= 1;
    }
    const slot = &trail[trail_len];
    slot.n = n;
    slot.primary = primary;
    @memcpy(slot.items[0..n], items[0..n]);
    trail_len += 1;
    applyRangeCommand("ts.expand", .move);
    _ = load();
    trail_mark = fingerprint();
}

/// `A-i` / `A-down`: undo the last expand, else shrink to a child node.
pub fn shrink() void {
    if (!load()) return;
    if (trail_len > 0 and fingerprint() == trail_mark) {
        trail_len -= 1;
        const slot = &trail[trail_len];
        n = slot.n;
        primary = slot.primary;
        @memcpy(items[0..n], slot.items[0..n]);
        store();
        _ = load();
        trail_mark = fingerprint();
        return;
    }
    trail_len = 0;
    applyRangeCommand("ts.shrink", .move);
}
