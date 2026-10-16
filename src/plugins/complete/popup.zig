//! The completion popup — what used to be `core/complete_ui.zig`, as policy
//! a plugin holds over doors core keeps (doc/docs-popups.md, phase 4):
//!
//!   - `capsFire`/`capsPoll`/`capsMerged`/`capsFinish` race the
//!     `edit/completion` providers and read their merged ranking as answers
//!     land (instant ones during the fire, slower ones off `on_poll`);
//!   - a caret surface draws the list — label, detail, kind — and the chosen
//!     item's documentation beside it, a markdown document
//!     (`surfaceDoc`: its detail as code, then its docs);
//!   - `keyLayers` lends the popup a few keys while it shows rows — the
//!     `complete` layer (Tab, the arrows), and `complete-chosen` (Return)
//!     once a row is chosen — and every other key stays the grammar's, so
//!     typing goes on into the buffer;
//!   - `input.typed`/`input.caret` narrow it to the word being typed, read
//!     back off the buffer; it closes once it describes nothing being typed
//!     (the caret left the word, the mode changed, nothing matches, or the
//!     one match is what is already there).
//!
//! Accepting replaces the word with the item's text, as the person's edit.

const std = @import("std");
const weft = @import("weft");

const max_items = 200;
/// Rows shown at once; the list scrolls to keep the chosen one in them.
const max_rows = 10;
/// A detail longer than this is cut, with `…`: the list stays a list.
const max_detail = 40;

const Item = struct {
    text: []u8,
    label: []u8,
    detail: []u8,
    doc: []u8,
    kind: u8,

    fn free(self: Item) void {
        const a = weft.allocator;
        a.free(self.text);
        a.free(self.label);
        a.free(self.detail);
        a.free(self.doc);
    }

    /// What the list shows and narrows on: the label, else the text.
    fn name(self: Item) []const u8 {
        return if (self.label.len > 0) self.label else self.text;
    }
};

var items: std.ArrayList(Item) = .empty;
/// Indices into `items` the typed word matches, best first.
var shown: std.ArrayList(usize) = .empty;
var session: ?u32 = null;
var merged: usize = 0;
var open = false;
/// Where the word being completed begins.
var word_start: usize = 0;
/// The row moved to (an index into `shown`), or null until one is.
var chosen: ?usize = null;
/// The first row on screen.
var top: usize = 0;
/// Opened on purpose (`complete.show`): the first row is chosen from the
/// start, so Return accepts it. Opened by itself while typing, nothing is
/// chosen until a row is moved to, and Return stays the grammar's.
var preselect = false;

pub fn isOpen() bool {
    return open;
}

/// A word byte, as the editor reads a completion prefix.
pub fn wordByte(b: u8) bool {
    return std.ascii.isAlphanumeric(b) or b == '_' or b >= 0x80;
}

/// The word before the caret, and where it starts.
fn wordBefore(cur: usize) struct { start: usize, word: []const u8 } {
    const from = cur -| 128;
    const before = weft.slice(from, cur);
    var n: usize = 0;
    while (n < before.len and wordByte(before[before.len - 1 - n])) n += 1;
    return .{ .start = cur - n, .word = before[before.len - n ..] };
}

/// Open the popup, asked for: the first row chosen.
pub fn showChosen() void {
    open_(true);
}

/// Open the popup by itself, as typing pauses: nothing chosen.
pub fn show() void {
    open_(false);
}

/// Open the popup at the word before the caret and race the providers.
fn open_(chosen_first: bool) void {
    close();
    preselect = chosen_first;
    const cur = weft.cursor();
    const w = wordBefore(cur);
    var prefix_buf: [128]u8 = undefined;
    const prefix = prefix_buf[0..w.word.len];
    @memcpy(prefix, w.word);
    session = weft.capsFire(cur, prefix) orelse return;
    open = true;
    word_start = w.start;
    merged = 0;
    // Instant providers answered during the fire.
    _ = poll();
    if (!open) return;
    narrow(prefix);
    redraw();
}

/// Fold in what has landed: true when the items changed.
pub fn poll() bool {
    const s = session orelse return false;
    const r = weft.capsPoll(s) orelse {
        session = null;
        return false;
    };
    var changed = false;
    if (r.count != merged) {
        clearItems();
        const n = @min(r.count, max_items);
        for (0..n) |i| {
            const a = weft.allocator;
            const item: Item = .{
                .text = weft.capsMerged(a, s, i, .text) catch continue,
                .label = weft.capsMerged(a, s, i, .label) catch &.{},
                .detail = weft.capsMerged(a, s, i, .detail) catch &.{},
                .doc = weft.capsMerged(a, s, i, .documentation) catch &.{},
                .kind = weft.capsMergedKind(s, i),
            };
            items.append(a, item) catch {
                item.free();
                break;
            };
        }
        merged = r.count;
        changed = true;
    }
    if (r.done) {
        // Everything is copied: the race can go.
        weft.capsFinish(s);
        session = null;
    }
    return changed;
}

/// Whether a loop's tick has anything to do: a race still running under a
/// list no row of which was chosen (a chosen list holds still).
pub fn racing() bool {
    return open and session != null and chosen == null;
}

/// Each loop: a race still running may have new answers.
pub fn tick() void {
    if (!racing()) return;
    if (!poll()) return;
    follow();
}

/// The caret moved or text was typed: narrow to the word, or close.
pub fn follow() void {
    if (!open) return;
    const cur = weft.cursor();
    if (cur < word_start) return close();
    const typed = weft.slice(word_start, cur);
    for (typed) |b| if (!wordByte(b)) return close();
    var buf: [128]u8 = undefined;
    if (typed.len > buf.len) return close();
    const word = buf[0..typed.len];
    @memcpy(word, typed);
    narrow(word);
    if (nothingToOffer(word)) return close();
    redraw();
}

/// Close rather than hang about: every provider answered and nothing
/// matches — or the one match is what is already typed.
fn nothingToOffer(word: []const u8) bool {
    if (shown.items.len == 0) return session == null;
    return shown.items.len == 1 and std.mem.eql(u8, items.items[shown.items[0]].text, word);
}

/// The items the typed word matches: those it begins first, then those it
/// runs through in order (`fb` for `fooBar`), each in the merged ranking.
fn narrow(word: []const u8) void {
    const a = weft.allocator;
    shown.clearRetainingCapacity();
    top = 0;
    defer chosen = if (preselect and shown.items.len > 0) 0 else null;
    for (items.items, 0..) |it, i| {
        if (startsWithFold(it.name(), word)) shown.append(a, i) catch return;
    }
    for (items.items, 0..) |it, i| {
        if (!startsWithFold(it.name(), word) and subsequenceFold(it.name(), word)) shown.append(a, i) catch return;
    }
}

fn startsWithFold(s: []const u8, prefix: []const u8) bool {
    return s.len >= prefix.len and std.ascii.eqlIgnoreCase(s[0..prefix.len], prefix);
}

fn subsequenceFold(s: []const u8, q: []const u8) bool {
    var j: usize = 0;
    for (s) |c| {
        if (j < q.len and std.ascii.toLower(c) == std.ascii.toLower(q[j])) j += 1;
    }
    return j == q.len;
}

/// Move the chosen row by `delta`, wrapping; the first move from none
/// lands on the first (or last) row.
pub fn move(delta: i32) void {
    if (!open or shown.items.len == 0) return;
    const n: i32 = @intCast(shown.items.len);
    const next: i32 = if (chosen) |c| @mod(@as(i32, @intCast(c)) + delta, n) else if (delta > 0) 0 else n - 1;
    chosen = @intCast(next);
    const c = chosen.?;
    if (c < top) top = c;
    if (c >= top + max_rows) top = c + 1 - max_rows;
    redraw();
}

/// Put the chosen item in place of the word, and close.
pub fn accept() void {
    if (!open) return;
    const c = chosen orelse return;
    if (c >= shown.items.len) return;
    const it = items.items[shown.items[c]];
    const cur = weft.cursor();
    const text = weft.allocator.dupe(u8, it.text) catch return;
    defer weft.allocator.free(text);
    const start = word_start;
    close();
    weft.edit(.{ .start = start, .end = cur }, text);
    weft.jump(start + text.len);
}

pub fn close() void {
    if (session) |s| weft.capsFinish(s);
    session = null;
    if (open) {
        weft.surfaceClose();
        weft.keyLayers(&.{});
    }
    open = false;
    clearItems();
    shown.clearRetainingCapacity();
    chosen = null;
    merged = 0;
}

fn clearItems() void {
    for (items.items) |it| it.free();
    items.clearRetainingCapacity();
}

/// Draw the list at the word's start, the chosen item's docs beside it, and
/// lend the popup its keys — only while it shows rows.
fn redraw() void {
    if (shown.items.len == 0) {
        weft.surfaceClose();
        weft.keyLayers(&.{});
        return;
    }
    weft.surfaceCaret(word_start);
    const end = @min(shown.items.len, top + max_rows);
    var detail_buf: [max_detail * 4 + 4]u8 = undefined;
    for (shown.items[top..end]) |i| {
        const it = items.items[i];
        weft.surfaceRow();
        weft.surfaceSpanAt(it.name(), .normal, 0);
        if (it.detail.len > 0) weft.surfaceSpanAt(cut(&detail_buf, firstLine(it.detail)), .annotation, 1);
        const tag = kindTag(it.kind);
        if (tag.len > 0) weft.surfaceSpanAt(tag, .annotation, 2);
    }
    if (chosen) |c| docsOf(items.items[shown.items[c]]);
    weft.surfaceEnd(if (chosen) |c| @intCast(c - top) else -1);
    if (chosen != null)
        weft.keyLayers(&.{ "complete-chosen", "complete" })
    else
        weft.keyLayers(&.{"complete"});
}

/// The chosen item's documentation, as markdown: its detail (a signature, a
/// type) as code, then its docs.
fn docsOf(it: Item) void {
    if (it.detail.len == 0 and it.doc.len == 0) return;
    var md: std.ArrayList(u8) = .empty;
    defer md.deinit(weft.allocator);
    const a = weft.allocator;
    if (it.detail.len > 0) {
        md.appendSlice(a, "```\n") catch return;
        md.appendSlice(a, it.detail) catch return;
        md.appendSlice(a, "\n```\n") catch return;
    }
    if (it.doc.len > 0) {
        if (md.items.len > 0) md.append(a, '\n') catch return;
        md.appendSlice(a, it.doc) catch return;
    }
    weft.surfaceDoc(md.items, .{});
}

fn firstLine(s: []const u8) []const u8 {
    return s[0 .. std.mem.indexOfScalar(u8, s, '\n') orelse s.len];
}

/// `s` cut to `max_detail` codepoints, the cut marked `…`.
fn cut(buf: []u8, s: []const u8) []const u8 {
    var it = (std.unicode.Utf8View.init(s) catch return s).iterator();
    var n: usize = 0;
    var at: usize = 0;
    while (it.nextCodepointSlice()) |cp| : (n += 1) {
        if (n == max_detail - 1) {
            if (at + cp.len >= s.len) return s;
            @memcpy(buf[0..at], s[0..at]);
            @memcpy(buf[at..][0.."…".len], "…");
            return buf[0 .. at + "…".len];
        }
        at += cp.len;
    }
    return s;
}

/// What a `CompletionItemKind` (LSP's numbering, the caps contract's) is
/// called in the list.
fn kindTag(kind: u8) []const u8 {
    return switch (kind) {
        2, 3 => "fn", // Method, Function
        4 => "new", // Constructor
        5, 10 => "field", // Field, Property
        6 => "var", // Variable
        7, 22 => "type", // Class, Struct
        8 => "iface", // Interface
        9 => "mod", // Module
        13, 20 => "enum", // Enum, EnumMember
        14 => "kw", // Keyword
        15 => "snip", // Snippet
        21, 12 => "const", // Constant, Value
        25 => "typaram", // TypeParameter
        else => "", // Text/unknown → no tag
    };
}
