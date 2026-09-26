//! snipe — f/F/t/T over what you can SEE, with jump labels.
//!
//! Vim's `f<c>` searches the current line and lands on the first hit, so a
//! target two lines down, or the fourth `(` on this one, costs a count or a
//! string of `;`. Snipe reads the character the same way (a `textInput`
//! capture), searches the pane's VISIBLE range (`weft.viewRange`), and:
//!
//!   · one hit → jumps there, exactly as `f` would;
//!   · several → labels each with a letter from a home-row alphabet (an
//!     `overlay` annotation drawn over the hit's own cell, so no text moves),
//!     then a second capture reads the label and jumps to that hit.
//!
//! `;` and `,` repeat the last search to the nearest hit forward/backward in
//! the same direction or reversed — snipe keeps its own repeat state rather
//! than borrowing a grammar's.
//!
//! **Operators.** The `snipe-op-*` commands are the same search for an
//! operator-pending mode: the chosen hit becomes a RANGE (vim's rules: `f`
//! covers the hit, `t` stops before it), handed to the command named by
//! `weft.set("snipe", "operator", …)` — for vim, `vim-operate`, which applies
//! whatever operator is pending, so `d`/`c`/`y` + a label works across lines.
//! Snipe names no grammar: without that setting an operator-pending snipe
//! just moves.
//!
//! Configuration (`weft.set("snipe", …)`):
//!   · `labels`   — the label alphabet, nearest hit first (default
//!                  `asdfghjklqwertyuiopzxcvbnm`);
//!   · `operator` — the range consumer for the `snipe-op-*` commands.

const std = @import("std");
const weft = @import("weft");

const Dir = enum {
    f,
    F,
    t,
    T,

    fn forward(d: Dir) bool {
        return d == .f or d == .t;
    }
    fn till(d: Dir) bool {
        return d == .t or d == .T;
    }
    fn reversed(d: Dir) Dir {
        return switch (d) {
            .f => .F,
            .F => .f,
            .t => .T,
            .T => .t,
        };
    }
};

/// The mode that reads the target character, and the one that reads a label.
const char_mode = "snipe-char";
const label_mode = "snipe-label";
const layer_name = "snipe";
const default_labels = "asdfghjklqwertyuiopzxcvbnm";

// ── The search in flight ─────────────────────────────────────────────
var dir: Dir = .f;
/// Entered from an operator-pending mode: the hit becomes a range for
/// `operator`, not a jump.
var operating = false;
/// The search's hits, nearest first; at most one per label.
var hits: [64]usize = undefined;
var n_hits: usize = 0;
/// The label alphabet in force for the labels on screen.
var label_buf: [64]u8 = undefined;
var labels: []const u8 = default_labels;
/// The typed target, copied out of the arg scratch.
var char_buf: [8]u8 = undefined;
var char_len: usize = 0;
/// The overlay the labels are drawn on, while they are up.
var overlay: ?weft.Annotations = null;

/// `;`/`,` state: the last completed search.
var last_dir: ?Dir = null;
var last_char: [8]u8 = undefined;
var last_len: usize = 0;

const cmds = [_]weft.CommandEntry{
    .{ .name = "snipe-f", .call = start(.f, false), .summary = "jump to a visible character (labelled when ambiguous)" },
    .{ .name = "snipe-F", .call = start(.F, false), .summary = "jump back to a visible character" },
    .{ .name = "snipe-t", .call = start(.t, false), .summary = "jump to just before a visible character" },
    .{ .name = "snipe-T", .call = start(.T, false), .summary = "jump back to just after a visible character" },
    .{ .name = "snipe-op-f", .call = start(.f, true), .summary = "operate through a visible character" },
    .{ .name = "snipe-op-F", .call = start(.F, true), .summary = "operate back to a visible character" },
    .{ .name = "snipe-op-t", .call = start(.t, true), .summary = "operate up to a visible character" },
    .{ .name = "snipe-op-T", .call = start(.T, true), .summary = "operate back to just after a visible character" },
    .{ .name = "snipe-read-char", .call = readChar },
    .{ .name = "snipe-read-label", .call = readLabel },
    .{ .name = "snipe-cancel", .call = cancel },
    .{ .name = "snipe-repeat", .call = repeatSame, .summary = "repeat the last snipe to the nearest hit" },
    .{ .name = "snipe-repeat-rev", .call = repeatReversed, .summary = "repeat the last snipe in the other direction" },
};

comptime {
    weft.plugin(&cmds, .{ .init = init }).exportAll();
}

fn init() void {
    weft.textInput(char_mode, "snipe-read-char");
    weft.textInput(label_mode, "snipe-read-label");
    weft.bindKey(char_mode, "Escape", "snipe-cancel");
    weft.bindKey(label_mode, "Escape", "snipe-cancel");
}

fn start(comptime d: Dir, comptime op: bool) fn () void {
    return struct {
        fn h() void {
            dir = d;
            operating = op;
            weft.setMode(char_mode);
        }
    }.h;
}

fn readChar() void {
    const ch = weft.argStr(0) orelse return cancel();
    if (ch.len == 0 or ch.len > char_buf.len) return cancel();
    @memcpy(char_buf[0..ch.len], ch);
    char_len = ch.len;
    const needle = char_buf[0..char_len];
    search(dir, needle);
    switch (n_hits) {
        0 => {
            weft.echo("snipe: no match in view");
            done();
        },
        1 => finish(hits[0]),
        else => showLabels(),
    }
}

fn readLabel() void {
    const typed = weft.argStr(0) orelse return cancel();
    clearLabels();
    if (typed.len != 1) return cancel();
    const i = std.mem.indexOfScalar(u8, labels[0..n_hits], typed[0]) orelse {
        weft.echo("snipe: no such label");
        return done();
    };
    finish(hits[i]);
}

fn cancel() void {
    clearLabels();
    done();
}

/// Leave snipe's capture modes for wherever the entry rests. An operator
/// that never got its range is abandoned with it.
fn done() void {
    weft.exitToResting();
}

// ── Search ───────────────────────────────────────────────────────────

/// Where to look: the range the pane SHOWS, or the cursor's line when the
/// view has not reported one (no frame yet, a headless caller).
fn region() weft.Range {
    return weft.viewRange() orelse weft.lineAt(weft.cursor());
}

/// Fill `hits` with the offsets of `needle` in the visible range, in `d`'s
/// direction from the cursor, nearest first, capped at the label count. A
/// till search skips the hit adjacent to the cursor — landing next to it
/// would not move, which is what makes `;` after `t` advance.
fn search(d: Dir, needle: []const u8) void {
    n_hits = 0;
    const cur = weft.cursor();
    const r = region();
    const cap = @min(hits.len, loadLabels().len);
    // `slice` borrows the shim's scratch; the offsets are all this keeps.
    const text = weft.slice(r.start, r.end);
    if (d.forward()) {
        var i: usize = 0;
        while (std.mem.indexOfPos(u8, text, i, needle)) |at| : (i = at + 1) {
            const off = r.start + at;
            if (off <= cur or (d.till() and weft.step(off, .back, .char) <= cur)) continue;
            hits[n_hits] = off;
            n_hits += 1;
            if (n_hits == cap) return;
        }
    } else {
        var end = text.len;
        while (std.mem.lastIndexOf(u8, text[0..end], needle)) |at| : (end = at) {
            const off = r.start + at;
            if (off >= cur or (d.till() and weft.step(off, .fwd, .char) >= cur)) continue;
            hits[n_hits] = off;
            n_hits += 1;
            if (n_hits == cap) return;
        }
    }
}

/// The label alphabet, read once per search so a reload applies to the next.
fn loadLabels() []const u8 {
    const configured = weft.config("labels");
    const src = if (configured.len > 0) configured else default_labels;
    const n = @min(src.len, label_buf.len);
    @memcpy(label_buf[0..n], src[0..n]);
    labels = label_buf[0..n];
    return labels;
}

// ── Labels ───────────────────────────────────────────────────────────

/// Draw one label over each hit's own cell and wait for the label key.
fn showLabels() void {
    const entry = activeEntry() orelse return finish(hits[0]);
    const anno = weft.Annotations.open(entry, layer_name) orelse return finish(hits[0]);
    if (!anno.begin()) {
        anno.close();
        return finish(hits[0]);
    }
    for (hits[0..n_hits], 0..) |off, i| anno.span(off, off, .removed, .overlay, labels[i .. i + 1]);
    overlay = anno;
    weft.setMode(label_mode);
}

fn clearLabels() void {
    if (overlay) |anno| anno.close();
    overlay = null;
}

/// The focused entry's id, the handle an annotation layer is opened on.
fn activeEntry() ?u32 {
    var i: usize = 0;
    while (i < weft.bufferCount()) : (i += 1) {
        if (!weft.bufferActive(i)) continue;
        const id = weft.bufferId(i) orelse return null;
        return @intCast(id);
    }
    return null;
}

// ── Landing ──────────────────────────────────────────────────────────

/// Where `d` lands for a hit: on it (f/F), or beside it (t/T).
fn target(d: Dir, hit: usize) usize {
    return switch (d) {
        .f, .F => hit,
        .t => weft.step(hit, .back, .char),
        .T => weft.step(hit, .fwd, .char),
    };
}

/// Jump to (or operate through) the chosen hit, and remember the search for
/// `;`/`,`.
fn finish(hit: usize) void {
    last_dir = dir;
    @memcpy(last_char[0..char_len], char_buf[0..char_len]);
    last_len = char_len;

    const cur = weft.cursor();
    if (operating) {
        const consumer = weft.config("operator");
        if (consumer.len > 0) {
            // vim's rules: `f` covers the hit, `t` stops before it; the
            // backward pair never covers the cursor's own character.
            const span: weft.Range = switch (dir) {
                .f => .{ .start = cur, .end = weft.step(hit, .fwd, .char) },
                .t => .{ .start = cur, .end = hit },
                .F => .{ .start = hit, .end = cur },
                .T => .{ .start = weft.step(hit, .fwd, .char), .end = cur },
            };
            // The consumer owns the mode from here (an operator enters its
            // after-mode); snipe only hands it the range.
            if (weft.anchorRange(span)) |h| return weft.runRangeArg(consumer, h);
        }
    }
    weft.jump(target(dir, hit));
    done();
}

fn repeat(d: Dir) void {
    const needle = last_char[0..last_len];
    search(d, needle);
    if (n_hits == 0) return;
    weft.jump(target(d, hits[0]));
}

fn repeatSame() void {
    repeat(last_dir orelse return);
}

fn repeatReversed() void {
    repeat((last_dir orelse return).reversed());
}
