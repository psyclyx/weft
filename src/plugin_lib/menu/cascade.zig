//! A menu's behaviour as plain data (doc/chrome.md §2.1): entries, the open
//! cascade of panels, and what each key and pointer gesture does to it. No
//! `weft` import, so it runs natively under test; `root.zig` publishes it as a
//! scene and wires it to an interaction.
//!
//! The conventions are the desktop's: Up and Down move through what can be
//! chosen (never a rule, a heading or a disabled row), wrapping; Right opens
//! the lit row's submenu, Left closes one; Enter and Space choose; Escape
//! closes one level; a letter chooses the row it is the mnemonic of — or, when
//! several rows share it, steps through them — and otherwise jumps to the next
//! row whose label starts with it. Right and Left at the edge of the cascade
//! are the menubar's business (the next or previous menu), so they come back
//! as outcomes rather than being decided here.

const std = @import("std");

/// One row of a menu.
pub const Entry = struct {
    /// What a person reads. An `&` marks the mnemonic letter (`E&xit`), `&&`
    /// is a literal `&`; with no mark a letter is chosen (`mnemonics`).
    label: []const u8,
    /// What it runs — the owner's to interpret (a command, an intention).
    name: []const u8 = "",
    icon: []const u8 = "",
    /// Its key hint, as shown.
    keys: []const u8 = "",
    /// Why it cannot run; empty when it can.
    reason: []const u8 = "",
    checked: bool = false,
    /// One choice among several: a dot rather than a check.
    radio: bool = false,
    /// A rule above this row.
    rule: bool = false,
    /// A plain label: never lit, never chosen.
    heading: bool = false,
    /// Its submenu. A row with children opens; it runs nothing itself.
    children: []const Entry = &.{},
    /// The owner's own data (an index into its model).
    tag: u32 = 0,

    pub fn enabled(self: Entry) bool {
        return self.reason.len == 0 and !self.heading;
    }

    pub fn opens(self: Entry) bool {
        return self.children.len > 0;
    }
};

pub const max_depth = 6;
pub const max_entries = 1 << 15;

/// The open panels of one menu: level 0 is `root`, each deeper level the
/// lit row's submenu.
pub const Cascade = struct {
    root: []const Entry = &.{},
    /// How many panels are open (0: none — a menubar with only a title lit).
    depth: usize = 0,
    /// The lit row of each open panel.
    lit: [max_depth]?usize = @splat(null),
    /// The keyboard is driving: mnemonics are shown underlined. A menu a
    /// click opened shows them from its first key on — the desktop's
    /// convention, which keeps a pointer user's menu free of underlines.
    keyboard: bool = false,
    /// Each open panel's opening, stamped when it opened, and the wheel
    /// steps heard over it since (down positive). Where a panel taller than
    /// the frame is scrolled to is the widget's to keep — only it knows how
    /// many rows fit — so the cascade says only these two: the widget starts
    /// a new opening at its top, and moves the window by the steps it has
    /// not yet seen.
    opened: [max_depth]u32 = @splat(0),
    wheel: [max_depth]i32 = @splat(0),

    /// Open `root` as a fresh cascade: one panel, its first choosable row
    /// lit when the keyboard opened it (a click lights nothing).
    pub fn open(root: []const Entry, keyboard: bool) Cascade {
        var c: Cascade = .{ .root = root, .depth = 1, .keyboard = keyboard };
        c.opened[0] = stamp();
        if (keyboard) c.lit[0] = step(root, null, 1);
        return c;
    }

    /// The rows of panel `k`.
    pub fn level(self: *const Cascade, k: usize) []const Entry {
        var rows = self.root;
        var i: usize = 0;
        while (i < k) : (i += 1) {
            const at = self.lit[i] orelse return &.{};
            if (at >= rows.len) return &.{};
            rows = rows[at].children;
        }
        return rows;
    }

    /// The lit row of the deepest panel.
    pub fn current(self: *const Cascade) ?*const Entry {
        if (self.depth == 0) return null;
        const rows = self.level(self.depth - 1);
        const at = self.lit[self.depth - 1] orelse return null;
        return if (at < rows.len) &rows[at] else null;
    }

    fn deepest(self: *Cascade) ?struct { rows: []const Entry, lit: *?usize } {
        if (self.depth == 0) return null;
        return .{ .rows = self.level(self.depth - 1), .lit = &self.lit[self.depth - 1] };
    }

    /// Open the submenu of row `at` of panel `k` (closing anything deeper).
    fn openBelow(self: *Cascade, k: usize, at: usize, keyboard: bool) void {
        if (k + 1 >= max_depth) return;
        // The submenu already open there stays the same opening.
        const already = self.depth >= k + 2 and self.lit[k] == at;
        self.lit[k] = at;
        self.depth = k + 2;
        self.lit[k + 1] = if (keyboard) step(self.level(k + 1), null, 1) else null;
        if (already) return;
        self.opened[k + 1] = stamp();
        self.wheel[k + 1] = 0;
    }
};

var openings: u32 = 0;

/// A stamp no earlier opening of any panel carries.
fn stamp() u32 {
    openings +%= 1;
    return openings;
}

/// The next choosable row from `from` (exclusive) in direction `dir`,
/// wrapping; from nothing, the first (or, backwards, the last).
pub fn step(rows: []const Entry, from: ?usize, dir: i32) ?usize {
    if (rows.len == 0) return null;
    const n: i64 = @intCast(rows.len);
    var i: i64 = if (from) |f| @intCast(f) else if (dir > 0) -1 else n;
    var tries: usize = 0;
    while (tries < rows.len) : (tries += 1) {
        i = @mod(i + dir, n);
        if (rows[@intCast(i)].enabled()) return @intCast(i);
    }
    return null;
}

/// What a gesture did, for the owner to act on.
pub const Outcome = union(enum) {
    /// Nothing changed.
    none,
    /// The cascade changed: publish it again.
    redraw,
    /// Run this row; the menu is done.
    activate: *const Entry,
    /// Close the menu altogether.
    close,
    /// Escape out of the last panel: a menubar keeps its title lit, a
    /// context menu closes.
    close_panel,
    /// Right or Left past the cascade's edge: the next (+1) or previous (-1)
    /// menu of a menubar.
    bar: i32,
};

pub fn up(c: *Cascade) Outcome {
    const d = c.deepest() orelse return .none;
    d.lit.* = step(d.rows, d.lit.*, -1) orelse return .none;
    return .redraw;
}

pub fn down(c: *Cascade) Outcome {
    const d = c.deepest() orelse return .none;
    d.lit.* = step(d.rows, d.lit.*, 1) orelse return .none;
    return .redraw;
}

pub fn home(c: *Cascade) Outcome {
    const d = c.deepest() orelse return .none;
    d.lit.* = step(d.rows, null, 1) orelse return .none;
    return .redraw;
}

pub fn end(c: *Cascade) Outcome {
    const d = c.deepest() orelse return .none;
    d.lit.* = step(d.rows, null, -1) orelse return .none;
    return .redraw;
}

/// Right: into the lit row's submenu, else on to the next menu.
pub fn right(c: *Cascade) Outcome {
    if (c.current()) |row| if (row.opens() and row.enabled()) {
        c.openBelow(c.depth - 1, c.lit[c.depth - 1].?, true);
        return .redraw;
    };
    return .{ .bar = 1 };
}

/// Left: out of a submenu, else on to the previous menu.
pub fn left(c: *Cascade) Outcome {
    if (c.depth > 1) {
        c.depth -= 1;
        return .redraw;
    }
    return .{ .bar = -1 };
}

/// Enter or Space: run the lit row, or open its submenu.
pub fn choose(c: *Cascade) Outcome {
    const row = c.current() orelse return .none;
    if (!row.enabled()) return .none;
    if (row.opens()) {
        c.openBelow(c.depth - 1, c.lit[c.depth - 1].?, true);
        return .redraw;
    }
    return .{ .activate = row };
}

/// Escape: close one level.
pub fn escape(c: *Cascade) Outcome {
    if (c.depth > 1) {
        c.depth -= 1;
        return .redraw;
    }
    return .close_panel;
}

/// A letter: the row it is the mnemonic of — chosen when it is the only one,
/// stepped to when several share it — else the next row whose label starts
/// with it.
pub fn letter(c: *Cascade, ch: u8) Outcome {
    const d = c.deepest() orelse return .none;
    const want = std.ascii.toLower(ch);
    var marks: [max_panel_rows]?usize = undefined;
    const shown_marks = mnemonics(d.rows, &marks);
    var count: usize = 0;
    var only: usize = 0;
    for (d.rows, 0..) |row, i| {
        if (!row.enabled()) continue;
        const at = shown_marks[i] orelse continue;
        if (letterAt(row.label, at) == want) {
            count += 1;
            only = i;
        }
    }
    if (count == 1) {
        d.lit.* = only;
        return choose(c);
    }
    // Several (or none by mnemonic): step to the next that matches.
    const n = d.rows.len;
    const from = d.lit.* orelse n - 1;
    var k: usize = 1;
    while (k <= n) : (k += 1) {
        const i = (from + k) % n;
        const row = d.rows[i];
        if (!row.enabled()) continue;
        const hit = if (count > 1)
            (if (shown_marks[i]) |at| letterAt(row.label, at) == want else false)
        else
            firstLetter(row.label) == want;
        if (hit) {
            d.lit.* = i;
            return .redraw;
        }
    }
    return .none;
}

/// The pointer rests on row `at` of panel `k`: light it, close anything
/// deeper, and open its submenu when it has one.
pub fn hover(c: *Cascade, k: usize, at: usize) Outcome {
    if (k >= c.depth) return .none;
    const rows = c.level(k);
    if (at >= rows.len) return .none;
    const before = c.*;
    // Back on the row whose submenu is open: the same opening, still open.
    if (before.depth >= k + 2 and before.lit[k] == at) c.depth = k + 2 else c.depth = k + 1;
    if (rows[at].enabled()) {
        c.lit[k] = at;
        if (rows[at].opens()) c.openBelow(k, at, false);
    }
    return if (std.meta.eql(before.lit, c.lit) and before.depth == c.depth) .none else .redraw;
}

/// A wheel step over the menu (`dir` 1 down, -1 up): heard by the deepest
/// panel, the one under the pointer (hovering a shallower panel's other
/// rows closes the deeper ones). Nothing is lit or chosen; the widget
/// scrolls a panel taller than the frame, and a panel that fits ignores it.
pub fn scroll(c: *Cascade, dir: i32) Outcome {
    if (c.depth == 0) return .none;
    c.wheel[c.depth - 1] +%= dir;
    return .redraw;
}

/// A click on row `at` of panel `k`: run it, or open its submenu.
pub fn click(c: *Cascade, k: usize, at: usize) Outcome {
    if (k >= c.depth) return .none;
    const rows = c.level(k);
    if (at >= rows.len or !rows[at].enabled()) return .none;
    _ = hover(c, k, at);
    if (rows[at].opens()) return .redraw;
    return .{ .activate = &rows[at] };
}

// ── Mnemonics ───────────────────────────────────────────────────────

pub const max_panel_rows = 256;

/// `label` as shown — its `&` marks taken out — into `buf`, and the codepoint
/// index its mark named, if any.
pub fn shown(label: []const u8, buf: []u8) struct { text: []const u8, mark: ?usize } {
    if (std.mem.indexOfScalar(u8, label, '&') == null) return .{ .text = label, .mark = null };
    var n: usize = 0;
    var cp: usize = 0;
    var mark: ?usize = null;
    var i: usize = 0;
    while (i < label.len and n < buf.len) {
        // `&x` marks x; `&&` is one `&`; an `&` before anything else (`Save
        // & Commit`) is just an ampersand.
        if (label[i] == '&' and i + 1 < label.len and (label[i + 1] == '&' or std.ascii.isAlphanumeric(label[i + 1]))) {
            if (label[i + 1] != '&' and mark == null) mark = cp;
            i += 1;
            if (label[i] == '&') {
                buf[n] = '&';
                n += 1;
                cp += 1;
                i += 1;
                continue;
            }
        }
        const len = std.unicode.utf8ByteSequenceLength(label[i]) catch 1;
        const stop = @min(label.len, i + len);
        if (n + (stop - i) > buf.len) break;
        @memcpy(buf[n..][0 .. stop - i], label[i..stop]);
        n += stop - i;
        cp += 1;
        i = stop;
    }
    return .{ .text = buf[0..n], .mark = mark };
}

/// The lower-cased ASCII letter at codepoint `at` of the SHOWN label, or 0.
fn letterAt(label: []const u8, at: usize) u8 {
    var buf: [256]u8 = undefined;
    const s = shown(label, &buf).text;
    var cp: usize = 0;
    var i: usize = 0;
    while (i < s.len) : (cp += 1) {
        if (cp == at) return if (std.ascii.isAlphanumeric(s[i])) std.ascii.toLower(s[i]) else 0;
        i += std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
    }
    return 0;
}

fn firstLetter(label: []const u8) u8 {
    var buf: [256]u8 = undefined;
    const s = shown(label, &buf).text;
    for (s) |ch| if (std.ascii.isAlphanumeric(ch)) return std.ascii.toLower(ch);
    return 0;
}

/// Each row's mnemonic, as a codepoint index into its shown label: its `&`
/// mark where it has one, else the first letter of a word no row above has
/// taken, else any letter not taken. Distinct within the panel where the
/// letters allow; a heading has none. Into `out`, sliced to `rows`.
pub fn mnemonics(rows: []const Entry, out: []?usize) []?usize {
    const n = @min(rows.len, out.len);
    var taken: [36]bool = @splat(false);
    for (rows[0..n], 0..) |row, i| {
        var buf: [256]u8 = undefined;
        const s = shown(row.label, &buf);
        out[i] = s.mark;
        if (s.mark) |at| {
            if (slot(letterAt(row.label, at))) |k| taken[k] = true;
        }
    }
    for (rows[0..n], 0..) |row, i| {
        if (out[i] != null or row.heading) continue;
        var buf: [256]u8 = undefined;
        const s = shown(row.label, &buf).text;
        // Word starts first, then any letter.
        for ([_]bool{ true, false }) |word_starts| {
            var cp: usize = 0;
            var j: usize = 0;
            var prev_space = true;
            while (j < s.len) : (cp += 1) {
                const ch = s[j];
                const len = std.unicode.utf8ByteSequenceLength(ch) catch 1;
                defer j += len;
                const start = prev_space;
                prev_space = ch == ' ';
                if (word_starts and !start) continue;
                const k = slot(if (std.ascii.isAlphanumeric(ch)) std.ascii.toLower(ch) else 0) orelse continue;
                if (taken[k]) continue;
                taken[k] = true;
                out[i] = cp;
                break;
            }
            if (out[i] != null) break;
        }
    }
    return out[0..n];
}

fn slot(ch: u8) ?usize {
    if (ch >= 'a' and ch <= 'z') return ch - 'a';
    if (ch >= '0' and ch <= '9') return 26 + ch - '0';
    return null;
}

// ── Node identity ───────────────────────────────────────────────────

/// Scene node ids for a cascade under `base`: row `i` of panel `k`, the rule
/// above it, and panel `k` itself. Distinct from each other and from anything
/// below `base`.
pub fn rowId(base: u64, k: usize, i: usize) u64 {
    return base + (@as(u64, k) << 20) + i + 1;
}

pub fn ruleId(base: u64, k: usize, i: usize) u64 {
    return base + (1 << 28) + (@as(u64, k) << 20) + i + 1;
}

pub fn panelId(base: u64, k: usize) u64 {
    return base + (2 << 28) + k + 1;
}

/// The panel and row a node id under `base` names, if it is a row.
pub fn rowAt(base: u64, id: u64) ?struct { panel: usize, row: usize } {
    if (id <= base) return null;
    const off = id - base - 1;
    if (off >= (1 << 28)) return null;
    return .{ .panel = @intCast(off >> 20), .row = @intCast(off & ((1 << 20) - 1)) };
}

// ── Tests ───────────────────────────────────────────────────────────

const t = std.testing;

test "cascade: arrows skip rules, headings and disabled rows, and wrap" {
    const rows = [_]Entry{
        .{ .label = "New File" },
        .{ .label = "Open…", .rule = true },
        .{ .label = "Revert", .reason = "nothing to revert" },
        .{ .label = "Recent", .heading = true },
        .{ .label = "Save" },
    };
    var c = Cascade.open(&rows, true);
    try t.expectEqual(@as(?usize, 0), c.lit[0]);
    _ = down(&c);
    try t.expectEqual(@as(?usize, 1), c.lit[0]);
    _ = down(&c);
    try t.expectEqual(@as(?usize, 4), c.lit[0]);
    _ = down(&c);
    try t.expectEqual(@as(?usize, 0), c.lit[0]);
    _ = up(&c);
    try t.expectEqual(@as(?usize, 4), c.lit[0]);
    _ = home(&c);
    try t.expectEqual(@as(?usize, 0), c.lit[0]);
    // A click opened it: nothing lit until a key or the pointer says so.
    const clicked = Cascade.open(&rows, false);
    try t.expectEqual(@as(?usize, null), clicked.lit[0]);
}

test "cascade: right opens a submenu, left and escape close one level, and the edges belong to the menubar" {
    const styles = [_]Entry{ .{ .label = "Text", .radio = true }, .{ .label = "Widget", .radio = true, .checked = true } };
    const rows = [_]Entry{ .{ .label = "Command Palette" }, .{ .label = "Appearance", .children = &styles } };
    var c = Cascade.open(&rows, true);
    try t.expectEqual(Outcome{ .bar = 1 }, right(&c));
    _ = down(&c);
    try t.expectEqual(Outcome.redraw, right(&c));
    try t.expectEqual(@as(usize, 2), c.depth);
    try t.expectEqual(@as(?usize, 0), c.lit[1]);
    try t.expectEqualStrings("Text", c.current().?.label);
    try t.expectEqual(Outcome.redraw, left(&c));
    try t.expectEqual(@as(usize, 1), c.depth);
    try t.expectEqual(Outcome{ .bar = -1 }, left(&c));
    // Enter on a submenu row opens it; on a leaf it runs.
    try t.expectEqual(Outcome.redraw, choose(&c));
    _ = down(&c);
    const ran = choose(&c);
    try t.expectEqualStrings("Widget", ran.activate.label);
    try t.expectEqual(Outcome.redraw, escape(&c));
    try t.expectEqual(Outcome.close_panel, escape(&c));
}

test "cascade: a letter chooses its mnemonic's row, steps through a shared one, and jumps by first letter" {
    const rows = [_]Entry{
        .{ .label = "&Save" },
        .{ .label = "Save &As…" },
        .{ .label = "Close Editor" },
        .{ .label = "Close Without Saving" },
        .{ .label = "E&xit" },
    };
    var marks: [8]?usize = undefined;
    const m = mnemonics(&rows, &marks);
    try t.expectEqual(@as(?usize, 0), m[0]);
    try t.expectEqual(@as(?usize, 5), m[1]);
    try t.expectEqual(@as(?usize, 0), m[2]); // C
    try t.expectEqual(@as(?usize, 6), m[3]); // W, its next free word start
    try t.expectEqual(@as(?usize, 1), m[4]);
    var c = Cascade.open(&rows, true);
    try t.expectEqualStrings("E&xit", letter(&c, 'x').activate.label);
    try t.expectEqualStrings("&Save", letter(&c, 'S').activate.label);
    // Nothing's mnemonic: the next row starting with it.
    c = Cascade.open(&rows, true);
    try t.expectEqual(Outcome.none, letter(&c, 'q'));
    try t.expectEqual(Outcome.redraw, letter(&c, 'e'));
    try t.expectEqual(@as(?usize, 4), c.lit[0]);
}

test "cascade: the pointer lights a row, opens its submenu, and a click runs a leaf" {
    const sub = [_]Entry{.{ .label = "Host Session…" }};
    const rows = [_]Entry{ .{ .label = "Share", .children = &sub }, .{ .label = "Quit" }, .{ .label = "Revert", .reason = "no" } };
    var c = Cascade.open(&rows, false);
    try t.expectEqual(Outcome.redraw, hover(&c, 0, 0));
    try t.expectEqual(@as(usize, 2), c.depth);
    try t.expectEqual(@as(?usize, null), c.lit[1]);
    try t.expectEqual(Outcome.none, hover(&c, 0, 0));
    try t.expectEqual(Outcome.redraw, hover(&c, 0, 1));
    try t.expectEqual(@as(usize, 1), c.depth);
    try t.expectEqual(Outcome.none, click(&c, 0, 2));
    try t.expectEqualStrings("Quit", click(&c, 0, 1).activate.label);
}

test "cascade: the wheel is heard by the deepest panel; each opening is stamped anew, the pointer's return keeps it" {
    const sub = [_]Entry{ .{ .label = "A" }, .{ .label = "B" } };
    const rows = [_]Entry{ .{ .label = "Share", .children = &sub }, .{ .label = "More", .children = &sub }, .{ .label = "Quit" } };
    var c = Cascade.open(&rows, false);
    const first = c.opened[0];
    try t.expect(Cascade.open(&rows, false).opened[0] != first);
    try t.expectEqual(Outcome.redraw, scroll(&c, 1));
    try t.expectEqual(@as(i32, 1), c.wheel[0]);
    // A wheel step lights nothing and shows no underlines.
    try t.expectEqual(@as(?usize, null), c.lit[0]);
    try t.expect(!c.keyboard);
    _ = hover(&c, 0, 0);
    const share = c.opened[1];
    _ = scroll(&c, -1);
    try t.expectEqual(@as(i32, -1), c.wheel[1]);
    try t.expectEqual(@as(i32, 1), c.wheel[0]);
    // Back on Share: the same opening, its wheel kept.
    _ = hover(&c, 0, 0);
    try t.expectEqual(share, c.opened[1]);
    try t.expectEqual(@as(i32, -1), c.wheel[1]);
    // Another submenu at that depth: a new opening, from rest.
    _ = hover(&c, 0, 1);
    try t.expect(c.opened[1] != share);
    try t.expectEqual(@as(i32, 0), c.wheel[1]);
}

test "cascade: shown labels drop their marks, and node ids round-trip" {
    var buf: [64]u8 = undefined;
    const s = shown("Find && &Replace", &buf);
    try t.expectEqualStrings("Find & Replace", s.text);
    try t.expectEqual(@as(?usize, 7), s.mark);
    const plain = shown("Save & Commit", &buf);
    try t.expectEqualStrings("Save & Commit", plain.text);
    try t.expectEqual(@as(?usize, null), plain.mark);
    const base: u64 = 1 << 40;
    const at = rowAt(base, rowId(base, 2, 7)).?;
    try t.expectEqual(@as(usize, 2), at.panel);
    try t.expectEqual(@as(usize, 7), at.row);
    try t.expect(rowAt(base, ruleId(base, 0, 1)) == null);
    try t.expect(rowAt(base, 5) == null);
}
