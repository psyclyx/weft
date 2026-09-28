//! The pure fuzzy matcher: the completion `Style`s and the scoring
//! functions (flex / substring / prefix / orderless). No state, no
//! allocation — `[]const u8` in, a `Match` (or null) out. Ranking policy
//! lives with the caller; this file only decides IF and HOW TIGHTLY a
//! query hits an item.

const std = @import("std");

/// How the query filters candidates.
pub const Style = enum {
    /// Space-split tokens, each a case-insensitive subsequence, matched in
    /// ANY order (Emacs "orderless"). The default — "open file" finds
    /// "file-open" and "open-file" alike.
    orderless,
    /// One case-insensitive subsequence over the whole query.
    flex,
    /// One contiguous case-insensitive run.
    substring,
    /// The item begins with the query (case-insensitive).
    prefix,

    pub fn parse(s: []const u8) ?Style {
        return std.meta.stringToEnum(Style, s);
    }
};

/// A match: byte span (tightness), first-match index, how many matched
/// characters landed on a word boundary (start-of-word bonus), and whether
/// each query run was matched as one unbroken run starting a word (`main`
/// in `main.zig`, not spelled across a path's directories, nor `of` inside
/// `profile`) — the strongest hit there is.
pub const Match = struct { span: usize, start: usize, boundaries: usize, word: bool = false };

fn isSep(c: u8) bool {
    return switch (c) {
        ' ', '-', '_', '/', '.', ':', '\\' => true,
        else => false,
    };
}

fn ciEql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (std.ascii.toLower(x) != std.ascii.toLower(y)) return false;
    return true;
}

/// The empty query matches everything at the top.
const empty_match: Match = .{ .span = 0, .start = 0, .boundaries = 0 };

/// Greedy case-insensitive subsequence, scoring word-boundary hits.
/// The BEST occurrence scores — in the ranking's order (`better`) — not the
/// leftmost: a path's directories can spell a query its file name matches
/// whole, and the leftmost reading scored every file under them alike, so
/// the picker's order among them fell to frecency (and, under a random
/// temporary directory, to chance).
fn flexMatch(query: []const u8, item: []const u8) ?Match {
    if (query.len == 0) return empty_match;
    var best: ?Match = null;
    for (item, 0..) |ch, from| {
        if (std.ascii.toLower(ch) != std.ascii.toLower(query[0])) continue;
        // Greedy from here ends as early as any reading that starts here.
        const m = flexFrom(query, item, from) orelse break; // no later start completes either
        if (best == null or better(m, best.?)) best = m;
    }
    return best;
}

fn flexFrom(query: []const u8, item: []const u8, from: usize) ?Match {
    var qi: usize = 0;
    var boundaries: usize = 0;
    for (item[from..], from..) |ch, i| {
        if (std.ascii.toLower(ch) != std.ascii.toLower(query[qi])) continue;
        if (i == 0 or isSep(item[i - 1])) boundaries += 1;
        qi += 1;
        if (qi == query.len) return .{ .span = i - from + 1, .start = from, .boundaries = boundaries, .word = i - from + 1 == query.len and (from == 0 or isSep(item[from - 1])) };
    }
    return null;
}

/// Whether `a` is the stronger hit — the order the picker ranks items by
/// (`Pick.refilter`): a word-start run, then the most word-boundary hits,
/// then the tightest span. Ties go to the earlier.
pub fn better(a: Match, b: Match) bool {
    if (a.word != b.word) return a.word;
    if (a.boundaries != b.boundaries) return a.boundaries > b.boundaries;
    return a.span < b.span;
}

fn substringMatch(query: []const u8, item: []const u8) ?Match {
    if (query.len == 0) return empty_match;
    if (item.len < query.len) return null;
    var i: usize = 0;
    while (i + query.len <= item.len) : (i += 1) {
        if (ciEql(item[i .. i + query.len], query)) {
            const at_boundary = i == 0 or isSep(item[i - 1]);
            return .{ .span = query.len, .start = i, .boundaries = @intFromBool(at_boundary), .word = at_boundary };
        }
    }
    return null;
}

fn prefixMatch(query: []const u8, item: []const u8) ?Match {
    if (query.len == 0) return empty_match;
    if (item.len < query.len or !ciEql(item[0..query.len], query)) return null;
    return .{ .span = query.len, .start = 0, .boundaries = 1, .word = true };
}

/// Space-split tokens, each a flex match, matched in any order; scores
/// combine (summed spans/boundaries, earliest start).
pub fn orderlessMatch(query: []const u8, item: []const u8) ?Match {
    var toks = std.mem.tokenizeScalar(u8, query, ' ');
    var span: usize = 0;
    var start: usize = std.math.maxInt(usize);
    var boundaries: usize = 0;
    var word = true;
    var any = false;
    while (toks.next()) |tok| {
        any = true;
        const m = flexMatch(tok, item) orelse return null;
        span += m.span;
        start = @min(start, m.start);
        boundaries += m.boundaries;
        word = word and m.word;
    }
    if (!any) return empty_match; // whitespace-only query
    return .{ .span = span, .start = start, .boundaries = boundaries, .word = word };
}

pub fn matchScore(style: Style, query: []const u8, item: []const u8) ?Match {
    return switch (style) {
        .orderless => orderlessMatch(query, item),
        .flex => flexMatch(query, item),
        .substring => substringMatch(query, item),
        .prefix => prefixMatch(query, item),
    };
}

/// Back-compat thin wrapper (flex span) for the tightness test.
fn matchSpan(query: []const u8, item: []const u8) ?usize {
    return if (flexMatch(query, item)) |m| m.span else null;
}

// ── Tests ───────────────────────────────────────────────────────────

const t = std.testing;

test "flexMatch: the best occurrence scores, not the leftmost — a shared prefix that happens to spell the query ties nothing" {
    // Both paths spell m…a…i…n across the shared directory (`/tmp`, `nix-
    // shell-…`); only one names it. Leftmost-greedy scored the two alike, so
    // frecency chose the wrong one.
    const dir = "/tmp/nix-shell-a8i/weft-e2e-n2/";
    const hit = flexMatch("main", dir ++ "main.zig").?;
    const miss = flexMatch("main", dir ++ "other.zig").?;
    try t.expectEqual(@as(usize, 4), hit.span);
    try t.expectEqual(dir.len, hit.start);
    try t.expect(hit.word and !miss.word);
    try t.expect(better(hit, miss));
}

test "matchSpan: subsequence with tightness" {
    try t.expectEqual(@as(?usize, 0), matchSpan("", "anything"));
    try t.expectEqual(@as(?usize, null), matchSpan("xyz", "cursor.left"));
    try t.expectEqual(@as(?usize, 4), matchSpan("save", "save"));
    try t.expect(matchSpan("cl", "cursor.left") != null);
    try t.expect(matchSpan("CL", "cursor.left") != null);
}

test "flex: the tightest alignment wins, not the first — a query spelled whole in a name beats the same letters strewn along a shared prefix" {
    // Two recent files under one directory whose name happens to hold m…a…i…n
    // (a random temp directory did, and Open Recent opened the wrong file).
    const dir = "/tmp/nix-shell-27507snaqjb/build-top/weft-e2e-van4MU/";
    const main = flexMatch("main", dir ++ "main.zig").?;
    const other = flexMatch("main", dir ++ "other.zig").?;
    try t.expectEqual(@as(usize, 4), main.span);
    try t.expect(main.boundaries > other.boundaries or (main.boundaries == other.boundaries and main.span < other.span));
    // Greedy leftmost would also have scattered "ab" over "a-xb-ab".
    try t.expectEqual(@as(usize, 2), flexMatch("ab", "a-xb-ab").?.span);
}

test "match styles: orderless, prefix, substring, boundary bonus" {
    // orderless — tokens in any order, each a subsequence.
    try t.expect(orderlessMatch("file open", "open-file") != null);
    try t.expect(orderlessMatch("open file", "open-file") != null);
    try t.expect(orderlessMatch("file open", "file-open") != null);
    try t.expect(orderlessMatch("open", "profile") == null); // no "open"

    // prefix — anchored at the start.
    try t.expect(prefixMatch("open", "open-file") != null);
    try t.expect(prefixMatch("open", "file-open") == null);

    // substring — one contiguous run.
    try t.expect(substringMatch("en-f", "open-file") != null);
    try t.expect(substringMatch("enf", "open-file") == null);

    // boundary bonus: "of" hits two word-starts in open-file, none in profile.
    try t.expect(flexMatch("of", "open-file").?.boundaries > flexMatch("of", "profile").?.boundaries);
}
