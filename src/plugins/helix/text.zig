//! What helix reads of the document: a windowed byte reader, the character
//! classes its word motions split on, and the motions themselves as PURE
//! functions from one selection to the next. Nothing here edits or moves;
//! `selection.zig` applies these to every selection at once.
//!
//! A selection is `{anchor, head}` with the head where the caret draws, and
//! "the cursor" a motion starts from is that head. Helix's own rule — a
//! selection covers at least one character — is `span` in `selection.zig`,
//! not a core rule, so a caret here is `anchor == head`.

const std = @import("std");
const weft = @import("weft");
const regex = @import("weft_regex");

/// A word character: the regex library's rule, so the word `w` walks over is
/// the word `*`'s `\b` bounds and `gw` labels.
pub const isWord = regex.isWordByte;

pub const Sel = weft.Selection;

// ── Reading ─────────────────────────────────────────────────────────────

/// A window over the document, refilled on a miss. One per command: `begin`
/// re-reads the length and drops the window, so a reader never serves bytes
/// from before an edit.
const Reader = struct {
    buf: [4096]u8 = undefined,
    lo: usize = 0,
    n: usize = 0,
    len: usize = 0,

    fn load(self: *Reader, off: usize) void {
        const lo = off -| self.buf.len / 2;
        const t = weft.slice(lo, @min(self.len, lo + self.buf.len));
        @memcpy(self.buf[0..t.len], t);
        self.lo = lo;
        self.n = t.len;
    }
};

var reader: Reader = .{};

/// Start reading the document as it is now.
pub fn begin() void {
    reader.len = weft.byteLen();
    reader.n = 0;
}

pub fn len() usize {
    return reader.len;
}

/// The byte at `off`, or null past the end.
pub fn at(off: usize) ?u8 {
    if (off >= reader.len) return null;
    if (off < reader.lo or off >= reader.lo + reader.n) reader.load(off);
    if (off >= reader.lo + reader.n) return null;
    return reader.buf[off - reader.lo];
}

// ── Character classes ───────────────────────────────────────────────────

/// What a word motion splits on. A line end is its own class, so `w` stops
/// at the end of a line instead of running on into the next one.
pub const Class = enum { space, eol, word, punct };

pub fn classOf(c: u8, big: bool) Class {
    if (c == '\n') return .eol;
    if (c == ' ' or c == '\t' or c == '\r') return .space;
    if (big) return .word;
    if (isWord(c)) return .word;
    return .punct;
}

fn classAt(off: usize, big: bool) ?Class {
    return classOf(at(off) orelse return null, big);
}

fn blank(c: Class) bool {
    return c == .space or c == .eol;
}

// ── Word motions ────────────────────────────────────────────────────────
// Each is helix's own shape: the selection starts where the cursor is (or
// one past it, when the cursor sits on the last character of a run) and
// covers what the motion crossed. `big` is the WORD form.

/// `w`: from the cursor to the start of the next word, trailing blanks
/// included — the word ahead, selected.
pub fn nextWordStart(s: Sel, big: bool) ?Sel {
    const c = s.head;
    const k0 = classAt(c, big) orelse return null;
    var start = c;
    if (classAt(c + 1, big)) |k1| if (k1 != k0) {
        start = c + 1;
    };
    var p = start;
    const k = classAt(p, big) orelse return .{ .anchor = start, .head = p };
    while (classAt(p, big) == k) p += 1;
    while (classAt(p, big) == .space) p += 1;
    return .{ .anchor = start, .head = p };
}

/// `e`: from the cursor to the end of the next word, leading blanks included.
pub fn nextWordEnd(s: Sel, big: bool) ?Sel {
    const c = s.head;
    const k0 = classAt(c, big) orelse return null;
    var start = c;
    if (!blank(k0)) if (classAt(c + 1, big)) |k1| if (k1 != k0) {
        start = c + 1;
    };
    var p = start;
    while (classAt(p, big)) |k| {
        if (!blank(k)) break;
        p += 1;
    }
    const k = classAt(p, big) orelse return .{ .anchor = start, .head = p };
    while (classAt(p, big) == k) p += 1;
    return .{ .anchor = start, .head = p };
}

/// `b`: from the cursor (included, unless it starts a run) back to the start
/// of the previous word. The head lands on the word's first character.
pub fn prevWordStart(s: Sel, big: bool) ?Sel {
    const c = s.head;
    if (c == 0) return null;
    const here = classAt(c, big);
    const anchor = if (here == null or here.? != classAt(c - 1, big).?) c else c + 1;
    var p = anchor;
    while (p > 0 and blank(classAt(p - 1, big).?)) p -= 1;
    if (p == 0) return .{ .anchor = anchor, .head = 0 };
    const k = classAt(p - 1, big).?;
    while (p > 0 and classAt(p - 1, big).? == k) p -= 1;
    return .{ .anchor = anchor, .head = p };
}

// ── Lines and paragraphs ────────────────────────────────────────────────

pub fn isBlankLine(l: weft.Range) bool {
    var i = l.start;
    while (i < l.end) : (i += 1) {
        const c = at(i) orelse return true;
        if (c != ' ' and c != '\t' and c != '\r') return false;
    }
    return true;
}

/// The first non-blank offset of the line holding `off` (its end if blank).
pub fn firstNonBlank(off: usize) usize {
    const l = weft.lineAt(off);
    var i = l.start;
    while (i < l.end) : (i += 1) {
        const c = at(i) orelse break;
        if (c != ' ' and c != '\t') break;
    }
    return i;
}

/// `]p`: from the cursor to the start of the next paragraph — past the rest
/// of this one, then past the blank lines after it.
pub fn nextParagraph(s: Sel) ?Sel {
    const n = len();
    var l = weft.lineAt(s.head);
    if (l.end >= n) return null;
    while (!isBlankLine(l) and l.end < n) l = weft.lineAt(l.end + 1);
    while (isBlankLine(l) and l.end < n) l = weft.lineAt(l.end + 1);
    const target = if (isBlankLine(l)) n else l.start;
    return .{ .anchor = s.head, .head = target };
}

/// `[p`: from the cursor back to the start of this paragraph, or of the one
/// before when the cursor already opens one.
pub fn prevParagraph(s: Sel) ?Sel {
    var l = weft.lineAt(s.head);
    if (l.start == 0) return null;
    if (s.head == l.start) l = weft.lineAt(l.start - 1);
    while (isBlankLine(l) and l.start > 0) l = weft.lineAt(l.start - 1);
    while (l.start > 0) {
        const up = weft.lineAt(l.start - 1);
        if (isBlankLine(up)) break;
        l = up;
    }
    return .{ .anchor = s.head, .head = l.start };
}

// ── Find a character on the line ────────────────────────────────────────

pub const Find = enum { to, till, back_to, back_till };

/// `f`/`t`/`F`/`T` <c>: select from the cursor to (or up to) the next or
/// previous `ch` on the cursor's line. Forward selections take the found
/// character in (`f`) or stop before it (`t`); backward ones keep the cursor's
/// own character, as helix does.
pub fn findChar(s: Sel, ch: u8, how: Find) ?Sel {
    const c = s.head;
    const l = weft.lineAt(c);
    switch (how) {
        .to, .till => {
            var i = c + 1;
            if (how == .till) i += 1;
            while (i < l.end) : (i += 1) {
                if (at(i) == ch) return .{ .anchor = c, .head = if (how == .to) i + 1 else i };
            }
        },
        .back_to, .back_till => {
            var i = c;
            if (how == .back_till and i > l.start) i -= 1;
            while (i > l.start) {
                i -= 1;
                if (at(i) == ch) return .{ .anchor = @min(c + 1, l.end), .head = if (how == .back_to) i else i + 1 };
            }
        },
    }
    return null;
}
