//! surround — add, delete and replace the pair of delimiters around a range,
//! a `.wasm` plugin with no core privilege beyond the edit door (perms `{}`).
//!
//! `surround.add` is an OPERATOR in the `operators` sense: it awaits a live
//! range (its single arg) and wraps it, so a grammar composes it the way it
//! composes `operators.delete` — helix hands it each selection (`ms`), vim could
//! hand it a motion's range (`ys`).
//!
//! `surround.delete` and `surround.replace` map over PAIRS: each declares
//! `surround.find` as its target (doc/model.md §2.6), so dispatch finds the
//! pair around every selection on the untouched text and runs once per
//! distinct pair — two selections inside one pair edit it once, nested pairs
//! each get theirs, innermost first. A grammar just runs the command.
//!
//! Which delimiters is a separate, earlier call: `surround-pair <c> [r]`. The
//! character is the grammar's to read (its own capture mode); this plugin
//! never takes a key. `c` names the pair — an opening or closing bracket
//! names both of its brackets, any other character is its own close — and
//! `r` names the pair `surround.replace` writes in its place.
//!
//! The enclosing pair around a range is found by scanning outwards: brackets
//! by nesting depth, quotes by parity on the range's line (an odd number of
//! quotes before the range means it sits inside one).

const std = @import("std");
const weft = @import("weft");

/// Delete and replace run once per distinct pair the selections sit in.
const each_pair: weft.Arity = .{ .each = .{ .over = "surround.find" } };

const cmds = [_]weft.CommandEntry{
    .{ .name = "surround.choose-pair", .call = setPair, .arity = .whole, .params = "char [replacement]", .summary = "Choose the delimiters the next surround operator uses.", .label = "Choose Surround Pair", .prompts = true },
    .{ .name = "surround.add", .call = opAdd, .arity = weft.Arity.each_extent, .summary = "Wrap the operator's range in the chosen pair.", .internal = true },
    .{ .name = "surround.delete", .call = opDelete, .arity = each_pair, .summary = "Delete the chosen pair around each selection.", .internal = true },
    .{ .name = "surround.replace", .call = opReplace, .arity = each_pair, .summary = "Replace the chosen pair around each selection.", .internal = true },
    .{ .name = "surround.find", .call = find, .arity = weft.Arity.each_extent, .summary = "Return the chosen pair around the selection, delimiters included.", .internal = true },
};

comptime {
    weft.plugin(&cmds, .{}).exportAll();
}

// ── The pair ─────────────────────────────────────────────────────────

/// One delimiter pair, as bytes (a delimiter is one UTF-8 character).
const Pair = struct {
    open_buf: [4]u8 = undefined,
    open_len: usize = 0,
    close_buf: [4]u8 = undefined,
    close_len: usize = 0,

    fn open(self: *const Pair) []const u8 {
        return self.open_buf[0..self.open_len];
    }
    fn close(self: *const Pair) []const u8 {
        return self.close_buf[0..self.close_len];
    }
    fn valid(self: *const Pair) bool {
        return self.open_len > 0 and self.close_len > 0;
    }

    /// The pair a typed character names.
    fn of(c: []const u8) Pair {
        const brackets = [_][2]u8{ .{ '(', ')' }, .{ '[', ']' }, .{ '{', '}' }, .{ '<', '>' } };
        var p: Pair = .{};
        if (c.len == 0) return p;
        const n = @min(c.len, std.unicode.utf8ByteSequenceLength(c[0]) catch 1, 4);
        for (brackets) |b| {
            if (n == 1 and (c[0] == b[0] or c[0] == b[1])) {
                p.open_buf[0] = b[0];
                p.close_buf[0] = b[1];
                p.open_len = 1;
                p.close_len = 1;
                return p;
            }
        }
        @memcpy(p.open_buf[0..n], c[0..n]);
        @memcpy(p.close_buf[0..n], c[0..n]);
        p.open_len = n;
        p.close_len = n;
        return p;
    }
};

var pair: Pair = .{};
var replacement: Pair = .{};

/// `surround-pair <c> [r]`: remember the pair (and the replacement pair) the
/// operators below read.
fn setPair() void {
    pair = Pair.of(weft.argStr(0) orelse "");
    replacement = Pair.of(weft.argStr(1) orelse "");
}

// ── Finding the pair around a range ───────────────────────────────────

/// Where the pair around a range sits: the offsets of its open and close
/// delimiters.
const Found = struct { open: usize, close: usize };

const chunk = 1024;

/// The first offset in `[from, to)` where `needle` starts, scanning forward.
fn indexFwd(from: usize, to: usize, needle: []const u8) ?usize {
    var at = from;
    while (at < to) {
        const t = weft.slice(at, @min(to, at + chunk));
        if (t.len == 0) return null;
        if (std.mem.indexOf(u8, t, needle)) |i| return at + i;
        at += t.len -| (needle.len - 1);
        if (t.len < needle.len) return null;
    }
    return null;
}

/// Bracket pairs: nest outwards from the range. The open is searched from the
/// range start INCLUSIVE, so a caret on an opening bracket names its own pair;
/// the close from the range's last byte, or just past the open.
fn findBracket(r: weft.Range, o: u8, c: u8) ?Found {
    const len = weft.byteLen();
    var open: ?usize = null;
    var depth: usize = 0;
    var hi = @min(r.start + 1, len);
    outer: while (hi > 0) {
        const lo = hi -| chunk;
        const t = weft.slice(lo, hi);
        var i = t.len;
        while (i > 0) {
            i -= 1;
            const at = lo + i;
            if (t[i] == c and at != r.start) {
                depth += 1;
            } else if (t[i] == o) {
                if (depth == 0) {
                    open = at;
                    break :outer;
                }
                depth -= 1;
            }
        }
        hi = lo;
    }
    const start = open orelse return null;
    depth = 0;
    var at = @max(start + 1, r.end -| 1);
    while (at < len) {
        const t = weft.slice(at, @min(len, at + chunk));
        if (t.len == 0) break;
        for (t, 0..) |b, i| {
            if (b == o) {
                depth += 1;
            } else if (b == c) {
                if (depth == 0) return .{ .open = start, .close = at + i };
                depth -= 1;
            }
        }
        at += t.len;
    }
    return null;
}

/// Quote pairs (open == close): parity on the range's line decides whether
/// the range sits inside a quote or before an opening one.
fn findQuote(r: weft.Range, q: []const u8) ?Found {
    const l = weft.lineAt(r.start);
    var before: usize = 0;
    var last: ?usize = null;
    var at = l.start;
    while (indexFwd(at, r.start, q)) |i| {
        before += 1;
        last = i;
        at = i + q.len;
    }
    if (before % 2 == 1) {
        const close = indexFwd(@max(r.start, r.end -| q.len), l.end, q) orelse return null;
        return .{ .open = last.?, .close = close };
    }
    const open = indexFwd(r.start, l.end, q) orelse return null;
    const close = indexFwd(open + q.len, l.end, q) orelse return null;
    return .{ .open = open, .close = close };
}

fn findAround(r: weft.Range) ?Found {
    if (!pair.valid()) return null;
    if (std.mem.eql(u8, pair.open(), pair.close())) return findQuote(r, pair.open());
    return findBracket(r, pair.open()[0], pair.close()[0]);
}

// ── The operators ─────────────────────────────────────────────────────

/// The awaited range, resolved.
fn argSpan() ?weft.Range {
    const h = weft.argRange(0) orelse return null;
    return weft.rangeEnds(h);
}

/// `surround.add`: the close after the range, then the open before it — the
/// later offset first, so the earlier one still holds.
fn opAdd() void {
    if (!pair.valid()) return;
    const r = argSpan() orelse return;
    weft.edit(.{ .start = r.end, .end = r.end }, pair.close());
    weft.edit(.{ .start = r.start, .end = r.start }, pair.open());
}

// ── Delete and replace: over each selection's pair ───────────────────
// `surround.delete` and `.replace` map over the PAIR each selection sits in
// (`surround.find`, their declared target): dispatch finds every selection's
// pair on the untouched text, runs a pair two selections share once, and
// edits the rest last first as one undo unit. So `md(` with carets on `a`
// and `b` in `f((a b))` gives `f(a b)` — per-selection deletes, one after
// another, would have found the NEXT pair out once the first had gone.

/// Delete or replace the pair spanning `r` (its range runs from the open
/// delimiter to past the close): the close first, so the open's offset
/// still holds. Edits inside a pair never move its ends, so a pair inside it
/// edited first leaves it whole.
fn strip(r: weft.Range, change_to: ?Pair) void {
    if (r.end - r.start < pair.open().len + pair.close().len) return;
    const new: Pair = change_to orelse .{};
    weft.edit(.{ .start = r.end - pair.close().len, .end = r.end }, new.close());
    weft.edit(.{ .start = r.start, .end = r.start + pair.open().len }, new.open());
}

/// `surround.delete`: drop both delimiters of the pair it was handed.
fn opDelete() void {
    strip(argSpan() orelse return, null);
}

/// `surround.replace`: swap the pair it was handed for the replacement.
fn opReplace() void {
    if (!replacement.valid()) return;
    strip(argSpan() orelse return, replacement);
}

/// `surround.find`: a range motion — the pair around the selection (or the
/// character under the cursor), delimiters included.
fn find() void {
    const cur = weft.cursor();
    const r = weft.selection() orelse weft.Range{ .start = cur, .end = @min(cur + 1, weft.byteLen()) };
    const f = findAround(r) orelse return;
    if (weft.anchorRange(.{ .start = f.open, .end = f.close + pair.close().len })) |h| weft.setResultRange(h);
}
