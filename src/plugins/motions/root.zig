//! motions — the motion domain (design §6.1), a `.wasm` plugin with NO core
//! privilege (perms `{}`, view). Each motion is PURE: it computes a target
//! offset from the current cursor + a read-only snapshot and RETURNS a borrowed
//! `range` ([cursor, target]) — it never moves a shared cursor an operator
//! races to read back ([FIX 3]). The caller decides: vim moves the cursor in
//! normal mode; an operator awaits the range and edits. Char/line steps use the
//! native `editor.step` primitive; word/WORD/line boundaries are policy, scanned
//! here over `slice`.

const std = @import("std");
const weft = @import("weft");

/// Registration order == the id the host hands `on_command`.
const cmds = [_]weft.CommandEntry{
    .{ .name = "motion.left", .call = left },
    .{ .name = "motion.right", .call = right },
    .{ .name = "motion.up", .call = up },
    .{ .name = "motion.down", .call = down },
    .{ .name = "motion.word-fwd", .call = wordFwd },
    .{ .name = "motion.word-back", .call = wordBack },
    .{ .name = "motion.word-end", .call = wordEnd },
    .{ .name = "motion.WORD-fwd", .call = wordFwdBig },
    .{ .name = "motion.WORD-back", .call = wordBackBig },
    .{ .name = "motion.WORD-end", .call = wordEndBig },
    .{ .name = "motion.line-start", .call = lineStart },
    .{ .name = "motion.line-end", .call = lineEnd },
    .{ .name = "motion.first-non-blank", .call = firstNonBlank },
    .{ .name = "motion.doc-start", .call = docStart },
    .{ .name = "motion.doc-end", .call = docEnd },
    .{ .name = "motion.match-pair", .call = matchPair },
};

/// Return the range `[cursor, target]` as this motion's result. The cursor is
/// always one endpoint, so the caller recovers the direction (target = the end
/// that isn't the cursor) while an operator gets the span to edit.
fn ret(target: usize) void {
    const cur = weft.cursor();
    if (weft.anchorRange(.{ .start = @min(cur, target), .end = @max(cur, target) })) |h|
        weft.setResultRange(h);
}

// ── char / line: the native step primitive ───────────────────────────
fn left() void {
    ret(weft.step(weft.cursor(), .back, .char));
}
fn right() void {
    ret(weft.step(weft.cursor(), .fwd, .char));
}
fn up() void {
    ret(weft.step(weft.cursor(), .back, .line));
}
fn down() void {
    ret(weft.step(weft.cursor(), .fwd, .line));
}

// ── line-relative ─────────────────────────────────────────────────────
fn lineStart() void {
    ret(weft.lineAt(weft.cursor()).start);
}
fn lineEnd() void {
    ret(weft.lineAt(weft.cursor()).end);
}
fn docStart() void {
    ret(0);
}
fn docEnd() void {
    ret(weft.byteLen());
}
fn firstNonBlank() void {
    const l = weft.lineAt(weft.cursor());
    const t = weft.slice(l.start, l.end);
    var i: usize = 0;
    while (i < t.len and (t[i] == ' ' or t[i] == '\t')) i += 1;
    ret(l.start + i);
}

// ── word classes (vim: word vs punct vs space are distinct runs) ──────
const Class = enum { space, word, punct };
fn classOf(b: u8) Class {
    if (b == ' ' or b == '\t' or b == '\n' or b == '\r') return .space;
    if (std.ascii.isAlphanumeric(b) or b == '_' or b >= 0x80) return .word;
    return .punct;
}
/// Whitespace-only class (for WORD motions: everything non-space is one run).
fn bigClass(b: u8) Class {
    return if (b == ' ' or b == '\t' or b == '\n' or b == '\r') .space else .word;
}

const chunk = 1 << 14;

/// Forward to the next word start. `big` folds punct into word (WORD/`W`).
fn fwdStart(big: bool) usize {
    const cur = weft.cursor();
    const len = weft.byteLen();
    if (cur >= len) return len;
    const t = weft.slice(cur, @min(len, cur + chunk));
    const cls: *const fn (u8) Class = if (big) bigClass else classOf;
    var i: usize = 0;
    const c0 = cls(t[0]);
    if (c0 != .space) while (i < t.len and cls(t[i]) == c0) {
        i += 1;
    };
    while (i < t.len and cls(t[i]) == .space) i += 1;
    return cur + i;
}
/// Backward to the previous word start.
fn backStart(big: bool) usize {
    const cur = weft.cursor();
    if (cur == 0) return 0;
    const from = cur -| chunk;
    const t = weft.slice(from, cur);
    const cls: *const fn (u8) Class = if (big) bigClass else classOf;
    var i: usize = t.len; // index within t, exclusive
    // step back over whitespace, then over the run we land in.
    while (i > 0 and cls(t[i - 1]) == .space) i -= 1;
    if (i == 0) return from;
    const c0 = cls(t[i - 1]);
    while (i > 0 and cls(t[i - 1]) == c0) i -= 1;
    return from + i;
}
/// Forward to the END of the current/next word (vim `e`).
fn endOf(big: bool) usize {
    const cur = weft.cursor();
    const len = weft.byteLen();
    if (cur >= len) return len;
    const t = weft.slice(cur, @min(len, cur + chunk));
    const cls: *const fn (u8) Class = if (big) bigClass else classOf;
    var i: usize = 1; // always advance at least one
    while (i < t.len and cls(t[i]) == .space) i += 1; // to a non-space
    if (i >= t.len) return cur + t.len;
    const c0 = cls(t[i]);
    while (i + 1 < t.len and cls(t[i + 1]) == c0) i += 1; // to its last byte
    return cur + i;
}
fn wordFwd() void {
    ret(fwdStart(false));
}
fn wordBack() void {
    ret(backStart(false));
}
fn wordEnd() void {
    ret(endOf(false));
}
fn wordFwdBig() void {
    ret(fwdStart(true));
}
fn wordBackBig() void {
    ret(backStart(true));
}
fn wordEndBig() void {
    ret(endOf(true));
}

// ── match a bracket pair (vim `%`) ────────────────────────────────────
fn matchPair() void {
    const cur = weft.cursor();
    const len = weft.byteLen();
    const here = weft.slice(cur, @min(len, cur + 1));
    if (here.len == 0) return ret(cur);
    const opens = "([{";
    const closes = ")]}";
    const c = here[0];
    if (std.mem.indexOfScalar(u8, opens, c)) |k| {
        // scan forward for the matching close, tracking nesting.
        const close = closes[k];
        const t = weft.slice(cur, len);
        var depth: usize = 0;
        for (t, 0..) |b, i| {
            if (b == c) depth += 1;
            if (b == close) {
                depth -= 1;
                if (depth == 0) return ret(cur + i);
            }
        }
    } else if (std.mem.indexOfScalar(u8, closes, c)) |k| {
        const open = opens[k];
        const t = weft.slice(0, cur + 1);
        var depth: usize = 0;
        var i: usize = t.len;
        while (i > 0) {
            i -= 1;
            if (t[i] == c) depth += 1;
            if (t[i] == open) {
                depth -= 1;
                if (depth == 0) return ret(i);
            }
        }
    }
    ret(cur);
}

comptime {
    weft.plugin(&cmds, .{}).exportAll();
}
