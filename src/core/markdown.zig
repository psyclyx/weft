//! Markdown inline analysis: source bytes → per-byte `InlineAttr`.
//!
//! A stateless window re-scan (no shadow rope): cheap enough to redo over
//! the visible range each damage frame, so a stale paint is just
//! slightly-old truth — the same discipline as tree-sitter highlight bulk.
//! Every byte gets an attr (default `normal`) and syntax markers stay
//! rendered-but-dimmed, so the source-offset→geometry map is total.
//!
//! v1 inline coverage: ATX headings (`#`..`######`), `` `code` ``,
//! `[text](url)` links, `**bold**`, `*italic*`. Block structure (lists,
//! quotes, tables, images) is a later layer.

const std = @import("std");
const Allocator = std.mem.Allocator;

const stemma = @import("stemma");
const capability = @import("capability.zig");

pub const InlineAttr = capability.InlineAttr;
pub const InlineRole = capability.InlineRole;

/// One `InlineAttr` per byte of `range`. Caller owns the slice.
pub fn analyze(gpa: Allocator, rope: *const stemma.Rope, range: stemma.Range) ![]InlineAttr {
    const len = range.len();
    const attrs = try gpa.alloc(InlineAttr, len);
    errdefer gpa.free(attrs);
    @memset(attrs, .{});
    if (len == 0) return attrs;

    const text = try gpa.alloc(u8, len);
    defer gpa.free(text);
    var sr = rope.streamReader(range, &.{});
    sr.interface.readSliceAll(text) catch unreachable;

    // A byte is "consumed" once a delimiter/code/link claims it, so later
    // passes don't re-interpret it (e.g. italic `*` inside a `**` run).
    const consumed = try gpa.alloc(bool, len);
    defer gpa.free(consumed);
    @memset(consumed, false);

    var in_fence = false;
    var ls: usize = 0;
    while (ls <= len) {
        var le = ls;
        while (le < len and text[le] != '\n') le += 1;
        if (le > ls) {
            const line = text[ls..le];
            const la = attrs[ls..le];
            const lc = consumed[ls..le];
            if (isFence(line)) {
                for (la) |*a| {
                    a.role = .code;
                    a.marker = true;
                }
                in_fence = !in_fence;
            } else if (in_fence) {
                for (la) |*a| a.role = .code;
            } else {
                analyzeLine(line, la, lc);
            }
        }
        ls = le + 1;
    }
    return attrs;
}

/// A fenced-code delimiter: 3+ backticks or tildes after optional spaces.
pub fn isFence(line: []const u8) bool {
    var i: usize = 0;
    while (i < line.len and line[i] == ' ') i += 1;
    if (i >= line.len or (line[i] != '`' and line[i] != '~')) return false;
    const ch = line[i];
    var n: usize = 0;
    while (i < line.len and line[i] == ch) : (i += 1) n += 1;
    return n >= 3;
}

fn analyzeLine(line: []const u8, attrs: []InlineAttr, consumed: []bool) void {
    // Thematic break: a line of only 3+ of the same -, *, or _.
    if (isThematicBreak(line)) {
        for (attrs) |*a| a.marker = true;
        return;
    }
    // Block prefixes (blockquote `>`, list markers) — dim/accent the
    // marker and its trailing space, then style the remainder inline.
    markBlockPrefix(line, attrs, consumed);

    // ATX heading: 1‑6 leading '#', then a space or end of line.
    var h: usize = 0;
    while (h < line.len and h < 6 and line[h] == '#') h += 1;
    var role: InlineRole = .normal;
    if (h >= 1 and (h == line.len or line[h] == ' ')) {
        role = switch (h) {
            1 => .h1,
            2 => .h2,
            3 => .h3,
            4 => .h4,
            5 => .h5,
            else => .h6,
        };
        for (0..h) |i| {
            attrs[i].marker = true;
            consumed[i] = true;
        }
        if (h < line.len and line[h] == ' ') {
            attrs[h].marker = true;
            consumed[h] = true;
        }
    }
    for (attrs) |*a| a.role = role; // base size/family for the whole line

    inlineCode(line, attrs, consumed);
    escapes(line, attrs, consumed);
    inlineLinks(line, attrs, consumed);
    applyDouble(line, attrs, consumed, '*'); // **bold**
    applySingle(line, attrs, consumed, '*'); // *italic*
}

/// `` `code` `` spans: inner bytes become the code role (mono), the
/// backticks are dimmed markers. No markup is interpreted inside.
fn inlineCode(line: []const u8, attrs: []InlineAttr, consumed: []bool) void {
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        if (consumed[i] or line[i] != '`') continue;
        var j = i + 1;
        while (j < line.len and line[j] != '`') j += 1;
        if (j >= line.len) break; // unterminated: leave the rest plain
        mark(attrs, consumed, i);
        mark(attrs, consumed, j);
        for (i + 1..j) |k| {
            attrs[k].role = .code;
            consumed[k] = true;
        }
        i = j;
    }
}

/// A backslash before ASCII punctuation escapes it (`\*`, `\<`): the
/// backslash is a marker, and the character is literal — no later pass reads
/// markup into it. Inside a code span there is nothing to escape.
fn escapes(line: []const u8, attrs: []InlineAttr, consumed: []bool) void {
    var i: usize = 0;
    while (i + 1 < line.len) : (i += 1) {
        if (consumed[i] or line[i] != '\\' or !std.ascii.isPunctuation(line[i + 1])) continue;
        mark(attrs, consumed, i);
        consumed[i + 1] = true;
        i += 1;
    }
}

/// `[text](url)`: the text keeps its role but recolors as a link; the
/// brackets, parens, and url are dimmed markers. The text may hold code.
fn inlineLinks(line: []const u8, attrs: []InlineAttr, consumed: []bool) void {
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        if (consumed[i] or line[i] != '[') continue;
        var j = i + 1;
        while (j < line.len and !(line[j] == ']' and !consumed[j])) j += 1;
        if (j >= line.len or line[j] != ']') continue;
        if (j + 1 >= line.len or line[j + 1] != '(') continue;
        var k = j + 2;
        while (k < line.len and line[k] != ')') k += 1;
        if (k >= line.len) continue;
        mark(attrs, consumed, i);
        for (i + 1..j) |t| attrs[t].link = true;
        mark(attrs, consumed, j);
        for (j + 1..k + 1) |m| mark(attrs, consumed, m);
        i = k;
    }
}

/// Paired double delimiters (`**bold**`): inner gets `bold`, the two
/// delimiter pairs are dimmed markers.
fn applyDouble(line: []const u8, attrs: []InlineAttr, consumed: []bool, ch: u8) void {
    var i: usize = 0;
    while (i + 1 < line.len) {
        if (consumed[i] or consumed[i + 1] or line[i] != ch or line[i + 1] != ch) {
            i += 1;
            continue;
        }
        var j = i + 2;
        while (j + 1 < line.len and
            !(line[j] == ch and line[j + 1] == ch and !consumed[j] and !consumed[j + 1])) : (j += 1)
        {}
        if (j + 1 >= line.len) {
            i += 1;
            continue;
        }
        mark(attrs, consumed, i);
        mark(attrs, consumed, i + 1);
        for (i + 2..j) |k| attrs[k].bold = true;
        mark(attrs, consumed, j);
        mark(attrs, consumed, j + 1);
        i = j + 2;
    }
}

/// Paired single delimiters (`*italic*`): inner gets `italic`.
fn applySingle(line: []const u8, attrs: []InlineAttr, consumed: []bool, ch: u8) void {
    var i: usize = 0;
    while (i < line.len) {
        if (consumed[i] or line[i] != ch) {
            i += 1;
            continue;
        }
        var j = i + 1;
        while (j < line.len and !(line[j] == ch and !consumed[j])) j += 1;
        if (j >= line.len) {
            i += 1;
            continue;
        }
        mark(attrs, consumed, i);
        for (i + 1..j) |k| attrs[k].italic = true;
        mark(attrs, consumed, j);
        i = j + 1;
    }
}

fn mark(attrs: []InlineAttr, consumed: []bool, i: usize) void {
    attrs[i].marker = true;
    consumed[i] = true;
}

/// A thematic break: after optional spaces, 3+ of one of -, *, _ and
/// nothing else but spaces.
fn isThematicBreak(line: []const u8) bool {
    var ch: u8 = 0;
    var n: usize = 0;
    for (line) |b| {
        if (b == ' ') continue;
        if (b != '-' and b != '*' and b != '_') return false;
        if (ch == 0) ch = b else if (b != ch) return false;
        n += 1;
    }
    return n >= 3;
}

/// Blockquote `>` and list markers (`-`/`*`/`+` or `N.`/`N)`), after
/// optional indent: mark the marker + its trailing space so the inline
/// passes skip them and they render dimmed.
fn markBlockPrefix(line: []const u8, attrs: []InlineAttr, consumed: []bool) void {
    var i: usize = 0;
    while (i < line.len and line[i] == ' ') i += 1;
    if (i >= line.len) return;
    if (line[i] == '>') {
        markBlock(attrs, consumed, i);
        if (i + 1 < line.len and line[i + 1] == ' ') markBlock(attrs, consumed, i + 1);
        return;
    }
    if ((line[i] == '-' or line[i] == '*' or line[i] == '+') and
        i + 1 < line.len and line[i + 1] == ' ')
    {
        markBlock(attrs, consumed, i);
        markBlock(attrs, consumed, i + 1);
        return;
    }
    var j = i;
    while (j < line.len and std.ascii.isDigit(line[j])) j += 1;
    if (j > i and j < line.len and (line[j] == '.' or line[j] == ')') and
        j + 1 < line.len and line[j + 1] == ' ')
    {
        for (i..j + 1) |k| markBlock(attrs, consumed, k);
        markBlock(attrs, consumed, j + 1);
    }
}

fn markBlock(attrs: []InlineAttr, consumed: []bool, i: usize) void {
    mark(attrs, consumed, i);
    attrs[i].block = true;
}

/// `text` as markdown READS it, for a document that is read rather than
/// edited (a popup's): the lines of a paragraph — or of a list item —
/// joined into one, since a single newline inside one is a space. Blank
/// lines, headings, fences and what is inside them, quotes, rules,
/// indented code, a new list item and a line ending in a hard break (two
/// spaces, or `\`) stay where they are. `gpa`-owned.
pub fn reflow(gpa: Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var in_fence = false;
    // Whether the last line written may take the next one on its end.
    var open = false;
    var prev_blank = true;
    var it = std.mem.splitScalar(u8, text, '\n');
    var first = true;
    while (it.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        const trimmed = std.mem.trimStart(u8, line, " \t");
        const blank = trimmed.len == 0;
        const fence = isFence(line);
        const starts_block = blank or fence or in_fence or isThematicBreak(line) or
            trimmed[0] == '#' or trimmed[0] == '>' or listItem(trimmed) or
            (prev_blank and (std.mem.startsWith(u8, line, "    ") or std.mem.startsWith(u8, line, "\t")));
        if (open and !starts_block) {
            try out.append(gpa, ' ');
            try out.appendSlice(gpa, trimmed);
        } else {
            if (!first) try out.append(gpa, '\n');
            try out.appendSlice(gpa, line);
        }
        first = false;
        if (fence) in_fence = !in_fence;
        const hard = std.mem.endsWith(u8, line, "  ") or std.mem.endsWith(u8, line, "\\");
        open = !blank and !fence and !in_fence and !hard and trimmed[0] != '#' and !isThematicBreak(line) and
            !(prev_blank and (std.mem.startsWith(u8, line, "    ") or std.mem.startsWith(u8, line, "\t")));
        prev_blank = blank;
    }
    return out.toOwnedSlice(gpa);
}

/// A list item's opening: `-`, `*` or `+` and a space, or `N.`/`N)` and a
/// space.
fn listItem(trimmed: []const u8) bool {
    if (trimmed.len >= 2 and (trimmed[0] == '-' or trimmed[0] == '*' or trimmed[0] == '+') and trimmed[1] == ' ') return true;
    var j: usize = 0;
    while (j < trimmed.len and std.ascii.isDigit(trimmed[j])) j += 1;
    return j > 0 and j + 1 < trimmed.len and (trimmed[j] == '.' or trimmed[j] == ')') and trimmed[j + 1] == ' ';
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn analyzeSlice(gpa: Allocator, s: []const u8) ![]InlineAttr {
    var rope = try stemma.Rope.fromSlice(gpa, s);
    defer rope.deinit(gpa);
    return analyze(gpa, &rope, .{ .start = 0, .end = rope.byteLen() });
}

test "every byte gets an attr (total map)" {
    const gpa = testing.allocator;
    const s = "# Hi\n\n*a* **b** `c` [d](e)\nplain";
    const attrs = try analyzeSlice(gpa, s);
    defer gpa.free(attrs);
    try testing.expectEqual(s.len, attrs.len);
}

test "ATX heading role + hash markers" {
    const gpa = testing.allocator;
    const attrs = try analyzeSlice(gpa, "## Title");
    defer gpa.free(attrs);
    try testing.expect(attrs[0].marker and attrs[1].marker); // ##
    try testing.expect(attrs[2].marker); // space
    try testing.expectEqual(InlineRole.h2, attrs[3].role); // 'T'
    try testing.expect(!attrs[3].marker);
}

test "bold, italic, code, link flags" {
    const gpa = testing.allocator;
    //             0123456789...
    const s = "a **b** *c* `d` [e](f)";
    const attrs = try analyzeSlice(gpa, s);
    defer gpa.free(attrs);
    // "**b**": markers at 2,3 and 6,7; 'b' at 4 is bold.
    try testing.expect(attrs[2].marker and attrs[4].bold and !attrs[4].marker);
    // "*c*": 'c' at 9 is italic.
    try testing.expect(attrs[9].italic);
    // "`d`": 'd' at 13 is code role.
    try testing.expectEqual(InlineRole.code, attrs[13].role);
    // "[e](f)": 'e' at 17 is a link; '(' and 'f' and ')' are markers.
    try testing.expect(attrs[17].link and !attrs[17].marker);
    try testing.expect(attrs[19].marker and attrs[20].marker);
}

test "block elements: fence, list, quote, thematic break" {
    const gpa = testing.allocator;
    const s = "```zig\nlet x = 1;\n```\n- item\n> quote\n---";
    const attrs = try analyzeSlice(gpa, s);
    defer gpa.free(attrs);
    // The fenced body ("let x = 1;") is code role.
    const body = std.mem.indexOf(u8, s, "let").?;
    try testing.expectEqual(InlineRole.code, attrs[body].role);
    // List marker "-" is a dimmed marker; the item text is not.
    const dash = std.mem.indexOf(u8, s, "- item").?;
    try testing.expect(attrs[dash].marker and !attrs[dash + 2].marker);
    // Blockquote ">" is a marker.
    const gt = std.mem.indexOf(u8, s, "> quote").?;
    try testing.expect(attrs[gt].marker);
    // Thematic break: every byte a marker.
    const rule = std.mem.lastIndexOf(u8, s, "---").?;
    try testing.expect(attrs[rule].marker and attrs[rule + 2].marker);
}

test "unterminated delimiters stay plain" {
    const gpa = testing.allocator;
    const attrs = try analyzeSlice(gpa, "a * b ` c");
    defer gpa.free(attrs);
    for (attrs) |a| {
        try testing.expect(!a.bold and !a.italic and !a.marker);
        try testing.expectEqual(InlineRole.normal, a.role);
    }
}

test "reflow joins a paragraph's lines and a list item's, and leaves block structure where it is" {
    const gpa = testing.allocator;
    const got = try reflow(gpa,
        \\TrimSpace returns a slice
        \\with all leading space removed.
        \\
        \\```go
        \\func A()
        \\func B()
        \\```
        \\- one item
        \\  goes on
        \\- two
        \\# Heading
        \\hard break  
        \\next
    );
    defer gpa.free(got);
    try testing.expectEqualStrings(
        \\TrimSpace returns a slice with all leading space removed.
        \\
        \\```go
        \\func A()
        \\func B()
        \\```
        \\- one item goes on
        \\- two
        \\# Heading
        \\hard break  
        \\next
    , got);
}

test "a list bullet is block structure; a code span's backticks are not" {
    const gpa = testing.allocator;
    const attrs = try analyzeSlice(gpa, "- `x`");
    defer gpa.free(attrs);
    try testing.expect(attrs[0].marker and attrs[0].block);
    try testing.expect(attrs[2].marker and !attrs[2].block);
}

test "a backslash escapes punctuation, and a link's text may hold code" {
    const gpa = testing.allocator;
    const esc = try analyzeSlice(gpa, "a \\* b \\< c");
    defer gpa.free(esc);
    try testing.expect(esc[2].marker); // the backslash
    try testing.expect(!esc[3].marker and !esc[3].italic); // `*`, literal
    const link = try analyzeSlice(gpa, "[`x` doc](https://e)");
    defer gpa.free(link);
    try testing.expect(link[0].marker); // `[`
    try testing.expect(link[2].link and link[2].role == .code); // x
    try testing.expect(link[11].marker); // inside the url
}
