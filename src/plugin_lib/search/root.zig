//! search — a typed query and its options → a regex, the match list over a
//! document, and the planning a search does over that list (the nearest
//! match, a step with wrap, the replace-all edit list). Two grammars of
//! search share it: the `find` bar (doc/configs.md §3.4) and helix's
//! `/ ? n N * s S K` (§2 phase 4), so smart case, whole word and the
//! prefilter below mean the same thing under both. No `weft` import, so it
//! is tested natively (build.zig wires it as a host test module) as well as
//! compiled into every guest that declares the `search` library.
//!
//! WHY A PREFILTER. The regex library is a Pike VM: linear, never
//! pathological, and slow per byte next to a substring search, because it
//! steps a thread set across every byte whether or not a match could start
//! there. A find bar re-runs its search on every keystroke over the whole
//! document (the "n/m" count needs every match), so that per-byte cost is
//! the keystroke latency. Most queries are literal, and most regexes begin
//! with a literal run (`foo\d+`, `fn \w+`): every match starts with that
//! run, so a substring search finds the only places a match can start and
//! the VM is asked about those alone (`Regex.matchAt`, anchored). A pattern
//! with no literal lead (`\d+`, `a|b`) falls back to the VM's own scan.

const std = @import("std");
const regex = @import("weft_regex");
const Allocator = std.mem.Allocator;

pub const Span = struct { start: usize, end: usize };

/// How letter case is compared. `smart` folds unless the query itself has
/// an uppercase letter — the grep/vim/helix rule, and the default here.
pub const Case = enum {
    smart,
    sensitive,
    insensitive,

    pub fn next(c: Case) Case {
        return switch (c) {
            .smart => .sensitive,
            .sensitive => .insensitive,
            .insensitive => .smart,
        };
    }

    pub fn label(c: Case) []const u8 {
        return switch (c) {
            .smart => "smart",
            .sensitive => "on",
            .insensitive => "off",
        };
    }
};

pub const Options = struct {
    /// The query is a regex; off, every byte of it is literal.
    regex: bool = false,
    case: Case = .smart,
    /// Only matches with a word boundary on both sides.
    whole_word: bool = false,
};

/// Does `pattern` fold case under `opts`? In a regex, the letter after a
/// backslash is syntax (`\D`, `\W`, `\S`, `\B`), not text the user typed in
/// upper case.
pub fn folds(pattern: []const u8, opts: Options) bool {
    return switch (opts.case) {
        .sensitive => false,
        .insensitive => true,
        .smart => !hasUpper(pattern, opts.regex),
    };
}

fn hasUpper(pattern: []const u8, is_regex: bool) bool {
    var i: usize = 0;
    while (i < pattern.len) : (i += 1) {
        const c = pattern[i];
        if (is_regex and c == '\\') {
            i += 1;
            continue;
        }
        if (std.ascii.isUpper(c)) return true;
    }
    return false;
}

/// Bytes the regex syntax gives a meaning. A backslash before any of them is
/// the literal byte (the library reserves backslash-letter, never
/// backslash-punctuation).
const meta = "\\.^$|?*+()[]{}";

/// The regex source for `pattern` under `opts`: a literal query escaped
/// byte by byte, and whole-word wrapped in `\b(?:…)\b`.
pub fn source(gpa: Allocator, pattern: []const u8, opts: Options) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    if (opts.whole_word) try out.appendSlice(gpa, "\\b(?:");
    if (opts.regex) {
        try out.appendSlice(gpa, pattern);
    } else for (pattern) |c| {
        if (std.mem.indexOfScalar(u8, meta, c) != null) try out.append(gpa, '\\');
        try out.append(gpa, c);
    }
    if (opts.whole_word) try out.appendSlice(gpa, ")\\b");
    return out.toOwnedSlice(gpa);
}

/// The literal every match of `pattern` begins with — as much of it as can
/// be read off the front of the pattern, and empty when nothing can (see the
/// module doc). Conservative by construction: it stops at the first byte
/// whose meaning it would have to think about, and a character a quantifier
/// makes optional is left out.
pub fn requiredPrefix(gpa: Allocator, pattern: []const u8, is_regex: bool) Allocator.Error![]u8 {
    if (!is_regex) return gpa.dupe(u8, pattern);
    // An alternation anywhere means no single lead is required.
    if (std.mem.indexOfScalar(u8, pattern, '|') != null) return gpa.dupe(u8, "");
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var i: usize = 0;
    while (i < pattern.len) {
        var lit: []const u8 = undefined;
        var width: usize = undefined;
        const c = pattern[i];
        if (c == '\\') {
            // `\.` is a literal dot; `\d`, `\b`, `\n` … are classes and
            // assertions, where the lead ends.
            if (i + 1 >= pattern.len or std.ascii.isAlphanumeric(pattern[i + 1])) break;
            lit = pattern[i + 1 .. i + 2];
            width = 2;
        } else if (std.mem.indexOfScalar(u8, meta, c) != null) {
            break;
        } else {
            // A whole codepoint, so a quantifier after it covers all of it.
            const n = @min(std.unicode.utf8ByteSequenceLength(c) catch 1, pattern.len - i);
            lit = pattern[i .. i + n];
            width = n;
        }
        if (i + width < pattern.len) switch (pattern[i + width]) {
            // Optional (or zero-count) — this character is not required.
            '*', '?', '{' => break,
            // At least one copy is required, and nothing after it is fixed.
            '+' => {
                try out.appendSlice(gpa, lit);
                break;
            },
            else => {},
        };
        try out.appendSlice(gpa, lit);
        i += width;
    }
    return out.toOwnedSlice(gpa);
}

/// Why a query cannot be searched, in words for the bar.
pub fn describe(err: anyerror) []const u8 {
    return switch (err) {
        error.UnbalancedParen => "unbalanced ( )",
        error.UnbalancedBracket => "unbalanced [ ]",
        error.EmptyClass => "empty [ ]",
        error.BadClassRange => "bad range in [ ]",
        error.DanglingQuantifier => "nothing to repeat",
        error.NestedQuantifier => "nested quantifier",
        error.BadQuantifierRange => "bad { } range",
        error.BadEscape => "unknown escape",
        error.UnsupportedGroup => "unsupported group",
        error.TooManyCaptures => "too many groups",
        error.ProgramTooLarge => "pattern too large",
        error.OutOfMemory => "out of memory",
        else => "bad pattern",
    };
}

/// One compiled query: the regex, the literal lead it prefilters on, and
/// whether a replacement template expands `$n`.
pub const Matcher = struct {
    gpa: Allocator,
    re: regex.Regex,
    prefix: []u8,
    fold: bool,
    expands: bool,

    pub fn init(gpa: Allocator, pattern_in: []const u8, opts: Options) (regex.CompileError || error{EmptyPattern})!Matcher {
        var pattern = pattern_in;
        // `(?i)` forces folding, and is stripped so a whole-word wrap never
        // buries it inside a group the library would refuse.
        var forced = false;
        if (opts.regex and std.mem.startsWith(u8, pattern, "(?i)")) {
            forced = true;
            pattern = pattern[4..];
        }
        if (pattern.len == 0) return error.EmptyPattern;
        const fold = forced or folds(pattern, opts);
        const src = try source(gpa, pattern, opts);
        defer gpa.free(src);
        // Multiline: `^`/`$` are line edges in a document, not its ends.
        var re = try regex.Regex.compile(gpa, src, .{ .case_insensitive = fold, .multiline = true });
        errdefer re.deinit();
        return .{
            .gpa = gpa,
            .re = re,
            .prefix = try requiredPrefix(gpa, pattern, opts.regex),
            .fold = fold,
            .expands = opts.regex,
        };
    }

    pub fn deinit(self: *Matcher) void {
        self.re.deinit();
        self.gpa.free(self.prefix);
        self.* = undefined;
    }

    /// The leftmost NON-EMPTY match starting at or after `from`. An empty
    /// match (`^`, `x*`) has nothing to select or replace, so the bar skips
    /// it rather than parking on a zero-width hit.
    pub fn next(self: *Matcher, hay: []const u8, from: usize) ?regex.Match {
        var at = from;
        while (at <= hay.len) {
            const m = if (self.prefix.len == 0)
                self.re.find(hay, at) orelse return null
            else blk: {
                const cand = (if (self.fold)
                    indexOfFold(hay, at, self.prefix)
                else
                    std.mem.indexOfPos(u8, hay, at, self.prefix)) orelse return null;
                break :blk self.re.matchAt(hay, cand) orelse {
                    at = cand + 1;
                    continue;
                };
            };
            if (m.end > m.start) return m;
            at = m.start + (std.unicode.utf8ByteSequenceLength(if (m.start < hay.len) hay[m.start] else 0) catch 1);
        }
        return null;
    }

    /// Every match in `hay`, in order, into `out` (cleared first). True when
    /// it stopped at `cap` with more to find.
    pub fn collect(self: *Matcher, gpa: Allocator, hay: []const u8, out: *std.ArrayList(Span), cap: usize) Allocator.Error!bool {
        out.clearRetainingCapacity();
        var at: usize = 0;
        while (self.next(hay, at)) |m| {
            if (out.items.len == cap) return true;
            try out.append(gpa, .{ .start = m.start, .end = m.end });
            at = m.end;
        }
        return false;
    }

    /// What `span` (a match of this query in `hay`) is replaced with: the
    /// template with `$0`–`$9` expanded against the match's own groups in a
    /// regex query, the template verbatim in a literal one (a `$` typed
    /// into a literal search's replacement is a dollar sign). Null when
    /// `span` is no longer a match — the document moved under it.
    pub fn replacement(self: *Matcher, gpa: Allocator, hay: []const u8, span: Span, template: []const u8) Allocator.Error!?[]u8 {
        const m = self.re.matchAt(hay, span.start) orelse return null;
        if (m.end != span.end) return null;
        if (!self.expands) return try gpa.dupe(u8, template);
        return try regex.expandReplacement(gpa, hay, m, template);
    }
};

/// `needle` in `hay` at or after `from`, ASCII letters compared without
/// case — the library's own folding rule, so the prefilter never skips a
/// place the regex would match. Scans for the lead byte in either case,
/// then compares the rest.
fn indexOfFold(hay: []const u8, from: usize, needle: []const u8) ?usize {
    if (needle.len == 0) return from;
    const lead = [2]u8{ std.ascii.toLower(needle[0]), std.ascii.toUpper(needle[0]) };
    var at = from;
    while (at + needle.len <= hay.len) {
        const i = std.mem.indexOfAnyPos(u8, hay, at, &lead) orelse return null;
        if (i + needle.len > hay.len) return null;
        if (std.ascii.eqlIgnoreCase(hay[i .. i + needle.len], needle)) return i;
        at = i + 1;
    }
    return null;
}

// ── Planning over the match list ─────────────────────────────────────

/// A chosen match, and whether reaching it went past an end of the document.
pub const Pick = struct { index: usize, wrapped: bool };

/// The first match starting at or after `origin`, wrapping to the first
/// match of the document when there is none after it.
pub fn nearest(matches: []const Span, origin: usize) ?Pick {
    if (matches.len == 0) return null;
    const i = std.sort.lowerBound(Span, matches, origin, struct {
        fn order(at: usize, s: Span) std.math.Order {
            return std.math.order(at, s.start);
        }
    }.order);
    return if (i < matches.len) .{ .index = i, .wrapped = false } else .{ .index = 0, .wrapped = true };
}

/// The last match starting before `pos`, wrapping to the document's last
/// match when there is none before it — the backward twin of `nearest`.
pub fn before(matches: []const Span, pos: usize) ?Pick {
    if (matches.len == 0) return null;
    const pick = nearest(matches, pos).?;
    if (pick.wrapped) return .{ .index = matches.len - 1, .wrapped = false };
    return if (pick.index > 0) .{ .index = pick.index - 1, .wrapped = false } else .{ .index = matches.len - 1, .wrapped = true };
}

/// The index of the match exactly covering `span`, if one does.
pub fn indexOf(matches: []const Span, span: Span) ?usize {
    const pick = nearest(matches, span.start) orelse return null;
    if (pick.wrapped) return null;
    const m = matches[pick.index];
    return if (m.start == span.start and m.end == span.end) pick.index else null;
}

/// The index range `[start, end)` of at most `cap` matches centred on
/// `index` — what the bar paints, rather than every match of a large file.
pub fn window(n: usize, index: usize, cap: usize) Span {
    if (n <= cap) return .{ .start = 0, .end = n };
    const half = cap / 2;
    const start = @min(index -| half, n - cap);
    return .{ .start = start, .end = start + cap };
}

/// One replacement: the match it replaces and the bytes that go there.
pub const Edit = struct { span: Span, bytes: []u8 };

/// Replace-all, planned before anything is applied: an edit per match, in
/// document order. Apply them LAST FIRST, so no edit shifts the bytes an
/// earlier one names.
pub const Plan = struct {
    edits: []Edit,

    pub fn deinit(self: *Plan, gpa: Allocator) void {
        for (self.edits) |e| gpa.free(e.bytes);
        gpa.free(self.edits);
        self.* = undefined;
    }

    /// Where replacement `i` sits once every edit has landed: its start
    /// shifted by what the edits before it grew or shrank the document.
    pub fn landed(self: Plan, i: usize) Span {
        var delta: isize = 0;
        for (self.edits[0..i]) |e| delta += @as(isize, @intCast(e.bytes.len)) - @as(isize, @intCast(e.span.end - e.span.start));
        const start: usize = @intCast(@as(isize, @intCast(self.edits[i].span.start)) + delta);
        return .{ .start = start, .end = start + self.edits[i].bytes.len };
    }
};

/// Plan replacing every one of `matches` (this query's matches in `hay`).
/// A match that no longer matches is left out rather than failing the rest.
pub fn planAll(gpa: Allocator, m: *Matcher, hay: []const u8, matches: []const Span, template: []const u8) Allocator.Error!Plan {
    var edits: std.ArrayList(Edit) = .empty;
    errdefer {
        for (edits.items) |e| gpa.free(e.bytes);
        edits.deinit(gpa);
    }
    try edits.ensureTotalCapacity(gpa, matches.len);
    for (matches) |span| {
        const bytes = (try m.replacement(gpa, hay, span, template)) orelse continue;
        edits.appendAssumeCapacity(.{ .span = span, .bytes = bytes });
    }
    return .{ .edits = try edits.toOwnedSlice(gpa) };
}

// ── Tests ────────────────────────────────────────────────────────────

const t = std.testing;

fn expectMatches(hay: []const u8, pattern: []const u8, opts: Options, want: []const Span) !void {
    var m = try Matcher.init(t.allocator, pattern, opts);
    defer m.deinit();
    var got: std.ArrayList(Span) = .empty;
    defer got.deinit(t.allocator);
    _ = try m.collect(t.allocator, hay, &got, 1000);
    try t.expectEqualSlices(Span, want, got.items);
}

test "a literal query is literal: regex bytes match themselves" {
    try expectMatches("a.b axb a.b", "a.b", .{}, &.{ .{ .start = 0, .end = 3 }, .{ .start = 8, .end = 11 } });
    try expectMatches("f(x) f(y)", "f(", .{}, &.{ .{ .start = 0, .end = 2 }, .{ .start = 5, .end = 7 } });
    try expectMatches("$1 [a] {2}", "[a] {2}", .{}, &.{.{ .start = 3, .end = 10 }});
}

test "regex mode: classes, anchors per line, and a prefixless pattern" {
    try expectMatches("x1 y22 z", "\\d+", .{ .regex = true }, &.{ .{ .start = 1, .end = 2 }, .{ .start = 4, .end = 6 } });
    try expectMatches("ab\nab", "^ab", .{ .regex = true }, &.{ .{ .start = 0, .end = 2 }, .{ .start = 3, .end = 5 } });
    try expectMatches("foo1 foo foo22", "foo\\d+", .{ .regex = true }, &.{ .{ .start = 0, .end = 4 }, .{ .start = 9, .end = 14 } });
    try expectMatches("cat dog", "cat|dog", .{ .regex = true }, &.{ .{ .start = 0, .end = 3 }, .{ .start = 4, .end = 7 } });
}

test "smart case folds a lowercase query and not one with a capital" {
    try expectMatches("Foo foo", "foo", .{}, &.{ .{ .start = 0, .end = 3 }, .{ .start = 4, .end = 7 } });
    try expectMatches("Foo foo", "Foo", .{}, &.{.{ .start = 0, .end = 3 }});
    try expectMatches("Foo foo", "foo", .{ .case = .sensitive }, &.{.{ .start = 4, .end = 7 }});
    try expectMatches("Foo foo", "FOO", .{ .case = .insensitive }, &.{ .{ .start = 0, .end = 3 }, .{ .start = 4, .end = 7 } });
    // `\D` is syntax, not a capital: the query still folds.
    try t.expect(folds("a\\D", .{ .regex = true }));
    try t.expect(!folds("a\\D", .{}));
}

test "whole word needs a boundary on both sides" {
    try expectMatches("cat catalog bobcat cat", "cat", .{ .whole_word = true }, &.{ .{ .start = 0, .end = 3 }, .{ .start = 19, .end = 22 } });
    try expectMatches("a1 a12", "a\\d", .{ .regex = true, .whole_word = true }, &.{.{ .start = 0, .end = 2 }});
}

test "empty matches are skipped, never parked on" {
    try expectMatches("baab", "a*", .{ .regex = true }, &.{.{ .start = 1, .end = 3 }});
}

test "a bad regex is refused with a reason, an empty one is refused outright" {
    try t.expectError(error.UnbalancedParen, Matcher.init(t.allocator, "(a", .{ .regex = true }));
    try t.expectError(error.EmptyPattern, Matcher.init(t.allocator, "", .{}));
    try t.expectEqualStrings("unbalanced ( )", describe(error.UnbalancedParen));
}

test "the required prefix never claims an optional character" {
    const cases = [_]struct { pattern: []const u8, want: []const u8 }{
        .{ .pattern = "foo\\d+", .want = "foo" },
        .{ .pattern = "fooo*", .want = "foo" },
        .{ .pattern = "ab+c", .want = "ab" },
        .{ .pattern = "a\\.b", .want = "a.b" },
        .{ .pattern = "x?y", .want = "" },
        .{ .pattern = "a|b", .want = "" },
        .{ .pattern = "\\bfn", .want = "" },
        .{ .pattern = "é*x", .want = "" },
        .{ .pattern = "(ab)", .want = "" },
    };
    for (cases) |c| {
        const got = try requiredPrefix(t.allocator, c.pattern, true);
        defer t.allocator.free(got);
        try t.expectEqualStrings(c.want, got);
    }
}

test "nearest and before wrap past either end; indexOf finds an exact match" {
    const ms = [_]Span{ .{ .start = 2, .end = 3 }, .{ .start = 5, .end = 6 }, .{ .start = 9, .end = 10 } };
    try t.expectEqual(Pick{ .index = 0, .wrapped = false }, nearest(&ms, 0).?);
    try t.expectEqual(Pick{ .index = 1, .wrapped = false }, nearest(&ms, 5).?);
    try t.expectEqual(Pick{ .index = 2, .wrapped = false }, nearest(&ms, 6).?);
    try t.expectEqual(Pick{ .index = 0, .wrapped = true }, nearest(&ms, 10).?);
    try t.expectEqual(@as(?Pick, null), nearest(&.{}, 0));
    try t.expectEqual(Pick{ .index = 2, .wrapped = true }, before(&ms, 2).?);
    try t.expectEqual(Pick{ .index = 1, .wrapped = false }, before(&ms, 9).?);
    try t.expectEqual(Pick{ .index = 2, .wrapped = false }, before(&ms, 50).?);
    try t.expectEqual(@as(?usize, 1), indexOf(&ms, .{ .start = 5, .end = 6 }));
    try t.expectEqual(@as(?usize, null), indexOf(&ms, .{ .start = 5, .end = 7 }));
}

test "the paint window centres on the current match and stays in bounds" {
    try t.expectEqual(Span{ .start = 0, .end = 5 }, window(5, 3, 10));
    try t.expectEqual(Span{ .start = 45, .end = 55 }, window(100, 50, 10));
    try t.expectEqual(Span{ .start = 0, .end = 10 }, window(100, 2, 10));
    try t.expectEqual(Span{ .start = 90, .end = 100 }, window(100, 99, 10));
}

test "replace-all plans captures per match and knows where each lands" {
    const gpa = t.allocator;
    const hay = "k1=v1; key2=value2";
    var m = try Matcher.init(gpa, "(\\w+)=(\\w+)", .{ .regex = true });
    defer m.deinit();
    var ms: std.ArrayList(Span) = .empty;
    defer ms.deinit(gpa);
    _ = try m.collect(gpa, hay, &ms, 100);
    var plan = try planAll(gpa, &m, hay, ms.items, "$2:$1");
    defer plan.deinit(gpa);
    try t.expectEqual(@as(usize, 2), plan.edits.len);
    try t.expectEqualStrings("v1:k1", plan.edits[0].bytes);
    try t.expectEqualStrings("value2:key2", plan.edits[1].bytes);
    // Apply last-first, as the plugin does, and check `landed` agrees.
    var doc: std.ArrayList(u8) = .empty;
    defer doc.deinit(gpa);
    try doc.appendSlice(gpa, hay);
    var i = plan.edits.len;
    while (i > 0) {
        i -= 1;
        const e = plan.edits[i];
        try doc.replaceRange(gpa, e.span.start, e.span.end - e.span.start, e.bytes);
    }
    try t.expectEqualStrings("v1:k1; value2:key2", doc.items);
    for (plan.edits, 0..) |e, k| {
        const at = plan.landed(k);
        try t.expectEqualStrings(e.bytes, doc.items[at.start..at.end]);
    }
}

test "a literal query's replacement is verbatim; a moved match is refused" {
    const gpa = t.allocator;
    var m = try Matcher.init(gpa, "a", .{});
    defer m.deinit();
    const r = (try m.replacement(gpa, "xa", .{ .start = 1, .end = 2 }, "$0$")).?;
    defer gpa.free(r);
    try t.expectEqualStrings("$0$", r);
    try t.expectEqual(@as(?[]u8, null), try m.replacement(gpa, "xa", .{ .start = 0, .end = 1 }, "b"));
}
