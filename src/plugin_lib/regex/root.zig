//! A guest-side regex engine (doc/configs.md §0.2): a Thompson/Pike NFA
//! simulation over UTF-8, no backtracking, worst-case linear in the input
//! for a fixed pattern. Helix's `s S K A-K / ? n N *` and ide's find/replace
//! bar link this. Core never parses a pattern — regex is a plugin's problem,
//! never core's, so this file has no `weft` import and no ABI calls at all.
//!
//! WHY a Pike VM and not backtracking: a backtracking engine (what a naive
//! `s/pattern/repl/` reaches for first) can blow up exponentially on inputs
//! like `(a*)*b` against a long run of `a`s with no trailing `b` — exactly
//! the shape an interactive find bar cannot refuse to typeahead. Simulating
//! the NFA breadth-first (at most one thread per reachable program counter,
//! so never more than `program.len` threads alive at once) is worst-case
//! O(pattern_size * text_len): slower per byte than backtracking on the
//! common case, with no pathological case at all.
//!
//! WHY bounded memory: `compile` sizes the thread lists to the COMPILED
//! PROGRAM LENGTH once, and `find`/`findAll` reuse those buffers for the
//! life of the `Regex` — never resized, never allocated per byte stepped. A
//! thread's capture history is a fixed `2*MAX_CAPTURES`-wide array embedded
//! in the thread value itself, so forking a thread at a `split` is a
//! `memcpy`-sized struct copy, never a heap allocation.
//!
//! Pure — no wasm import environment — so it is tested natively (the
//! `output/targets.zig` posture) as well as compiled into any guest that
//! declares the `regex` plugin library.
//!
//! Scope: this covers what helix's substitute/search and ide's find bar
//! need, not PCRE. No lookaround, no named groups, no inline modifier
//! groups (only a whole-pattern `(?i)`), no full Unicode case folding or
//! `\w`/`\b` beyond ASCII. Each of those is a real feature some caller will
//! eventually want; none of them changes the shape of the VM above, so they
//! are deliberately left for whoever needs them first rather than guessed
//! at here.

const std = @import("std");
const Allocator = std.mem.Allocator;

// ── Compile-time knobs (bounded, not tuned) ─────────────────────────────────

/// Capture groups 0..MAX_CAPTURES-1 (group 0 is the whole match). Sixteen
/// user groups is generous for a hand-written substitute or find pattern;
/// this is what sizes every `Thread`'s capture array, so it is a real memory
/// knob, not a decorative one — see the module doc's bounded-memory note.
pub const MAX_CAPTURES: usize = 16;

/// A sanity cap on `{n}`/`{n,m}` bounds and on the compiled program itself.
/// `{50000}` is not a typo an editor's find bar should have to compile
/// before discovering it is nonsense; `ProgramTooLarge` is the same
/// complaint at the instruction-count level for patterns that get there by
/// nesting rather than by one big brace.
const MAX_REPEAT: u32 = 1000;
const MAX_PROGRAM: usize = 8192;

pub const Options = struct {
    /// `(?i)` at the start of the pattern text does the same thing; either
    /// is enough. Smart-case (only fold when the pattern itself has no
    /// uppercase) is a caller policy — grep, vim's `/` and helix's `/` each
    /// want a different rule, so it does not belong here.
    case_insensitive: bool = false,
    /// `^`/`$` also match right after/before a `\n`, not only at the very
    /// start/end of the haystack. Off is the "one paragraph" default the
    /// helix/vim substitute range wants; a multi-line search turns it on.
    multiline: bool = false,
};

pub const Span = struct { start: usize, end: usize };

/// One match: the whole span (`start`/`end`, mirroring `groups[0]`) plus up
/// to `MAX_CAPTURES` capture spans. `groups[g]` is `null` when group `g`
/// exists in the pattern but did not participate in this particular match
/// (an alternative that was not taken), and always `null` past `ngroups`.
pub const Match = struct {
    start: usize,
    end: usize,
    groups: [MAX_CAPTURES]?Span = [_]?Span{null} ** MAX_CAPTURES,
    /// `1 + ` the number of user capture groups in the pattern that produced
    /// this match (group 0 is always present).
    ngroups: usize,

    pub fn group(self: Match, i: usize) ?Span {
        if (i >= self.ngroups) return null;
        return self.groups[i];
    }
};

pub const CompileError = error{
    UnbalancedParen,
    UnbalancedBracket,
    EmptyClass,
    BadClassRange,
    DanglingQuantifier,
    NestedQuantifier,
    BadQuantifierRange,
    BadEscape,
    UnsupportedGroup,
    TooManyCaptures,
    ProgramTooLarge,
} || Allocator.Error;

// ── Character classes ────────────────────────────────────────────────────

const Range = struct { lo: u21, hi: u21 };

const ClassSet = struct {
    ranges: []const Range,
    /// Applied ONCE, after the ranges are unioned. A user's `[^...]`
    /// negates the whole bracket; `\D`/`\W`/`\S` are pre-complemented range
    /// tables instead of `negate = true` sets, precisely so they compose
    /// with the rest of a bracket (`[^\D]`, `[\d\s]`, ...) by plain union —
    /// see the shorthand tables below for why that is sound.
    negate: bool,
};

const MAX_CP: u21 = 0x10FFFF;

const DIGIT_RANGES = [_]Range{.{ .lo = '0', .hi = '9' }};
const NOT_DIGIT_RANGES = [_]Range{
    .{ .lo = 0, .hi = '0' - 1 },
    .{ .lo = '9' + 1, .hi = MAX_CP },
};
const WORD_RANGES = [_]Range{
    .{ .lo = 'a', .hi = 'z' },
    .{ .lo = 'A', .hi = 'Z' },
    .{ .lo = '0', .hi = '9' },
    .{ .lo = '_', .hi = '_' },
};
const NOT_WORD_RANGES = [_]Range{
    .{ .lo = 0, .hi = '0' - 1 },
    .{ .lo = '9' + 1, .hi = 'A' - 1 },
    .{ .lo = 'Z' + 1, .hi = '_' - 1 },
    .{ .lo = '_' + 1, .hi = 'a' - 1 },
    .{ .lo = 'z' + 1, .hi = MAX_CP },
};
// \t \n \v \f \r are the contiguous run 9..13; ' ' (32) is separate.
const SPACE_RANGES = [_]Range{
    .{ .lo = 9, .hi = 13 },
    .{ .lo = 32, .hi = 32 },
};
const NOT_SPACE_RANGES = [_]Range{
    .{ .lo = 0, .hi = 8 },
    .{ .lo = 14, .hi = 31 },
    .{ .lo = 33, .hi = MAX_CP },
};

fn isAsciiAlnum(b: u8) bool {
    return (b >= 'a' and b <= 'z') or (b >= 'A' and b <= 'Z') or (b >= '0' and b <= '9');
}
fn isAsciiUpper(cp: u21) bool {
    return cp >= 'A' and cp <= 'Z';
}
fn isAsciiLower(cp: u21) bool {
    return cp >= 'a' and cp <= 'z';
}
fn toLowerAscii(cp: u21) u21 {
    return if (isAsciiUpper(cp)) cp + 32 else cp;
}
/// Case folding is ASCII-only by design (module doc's scope note): outside
/// ASCII, `(?i)` is a no-op rather than a half-correct guess at Unicode
/// case tables.
fn foldEq(ci: bool, want: u21, got: u21) bool {
    if (want == got) return true;
    if (!ci) return false;
    return toLowerAscii(want) == toLowerAscii(got);
}

fn rangesContain(ranges: []const Range, cp: u21) bool {
    for (ranges) |r| {
        if (cp >= r.lo and cp <= r.hi) return true;
    }
    return false;
}

fn classMatches(set: ClassSet, ci: bool, cp: u21) bool {
    var hit = rangesContain(set.ranges, cp);
    if (!hit and ci) {
        const folded = if (isAsciiUpper(cp)) cp + 32 else if (isAsciiLower(cp)) cp - 32 else cp;
        if (folded != cp) hit = rangesContain(set.ranges, folded);
    }
    return hit != set.negate;
}

fn isWordByte(b: u8) bool {
    return (b >= 'a' and b <= 'z') or (b >= 'A' and b <= 'Z') or (b >= '0' and b <= '9') or b == '_';
}
fn wordBefore(haystack: []const u8, pos: usize) bool {
    return pos > 0 and haystack[pos - 1] < 0x80 and isWordByte(haystack[pos - 1]);
}
fn wordAfter(haystack: []const u8, pos: usize) bool {
    return pos < haystack.len and haystack[pos] < 0x80 and isWordByte(haystack[pos]);
}
fn atWordBoundary(haystack: []const u8, pos: usize) bool {
    return wordBefore(haystack, pos) != wordAfter(haystack, pos);
}
fn atLineStart(options: Options, haystack: []const u8, pos: usize) bool {
    if (pos == 0) return true;
    return options.multiline and haystack[pos - 1] == '\n';
}
fn atLineEnd(options: Options, haystack: []const u8, pos: usize) bool {
    if (pos == haystack.len) return true;
    return options.multiline and haystack[pos] == '\n';
}

const Decoded = struct { cp: u21, len: usize };

/// One codepoint at `pos`, or `null` at end of string. Invalid UTF-8 (a
/// truncated or malformed sequence) decodes as its lead byte, one byte at a
/// time, rather than failing the whole search — a regex over a text buffer
/// should degrade on bad bytes, not refuse to run.
fn decodeUtf8At(s: []const u8, pos: usize) ?Decoded {
    if (pos >= s.len) return null;
    const b0 = s[pos];
    if (b0 < 0x80) return .{ .cp = b0, .len = 1 };
    const seqlen = std.unicode.utf8ByteSequenceLength(b0) catch return .{ .cp = b0, .len = 1 };
    const avail = s.len - pos;
    if (seqlen > avail) return .{ .cp = b0, .len = 1 };
    const cp = std.unicode.utf8Decode(s[pos .. pos + seqlen]) catch return .{ .cp = b0, .len = 1 };
    return .{ .cp = cp, .len = seqlen };
}

// ── AST ──────────────────────────────────────────────────────────────────

const RepeatNode = struct { child: *const Node, min: u32, max: ?u32, greedy: bool };
const GroupNode = struct { child: *const Node, capture: ?u32 };

const Node = union(enum) {
    empty,
    char: u21,
    any,
    class: ClassSet,
    concat: []const Node,
    alt: []const Node,
    repeat: RepeatNode,
    group: GroupNode,
    anchor_start,
    anchor_end,
    /// `true` = `\b`, `false` = `\B`.
    word_boundary: bool,
};

const ClassEscapeResult = union(enum) { ranges: []const Range, char: u21 };

/// `null` for a shorthand/assertion letter (`d D w W s S b B`) the caller
/// must handle itself; an error for any other unrecognized letter/digit
/// escape (reserved, so a typo like `\p` fails loudly instead of matching a
/// literal `p`).
fn simpleEscapeChar(e: u8) CompileError!?u21 {
    return switch (e) {
        'n' => '\n',
        't' => '\t',
        'r' => '\r',
        'f' => 0x0C,
        'v' => 0x0B,
        '0' => 0,
        'd', 'D', 'w', 'W', 's', 'S', 'b', 'B' => null,
        else => if (isAsciiAlnum(e)) error.BadEscape else e,
    };
}

const Parser = struct {
    arena: Allocator,
    pattern: []const u8,
    i: usize = 0,
    /// Capturing groups seen so far; group numbers are 1-based and assigned
    /// left-to-right by opening paren, the same order every other engine
    /// uses.
    ngroups: u32 = 0,

    fn peekByte(self: *Parser) ?u8 {
        return if (self.i < self.pattern.len) self.pattern[self.i] else null;
    }

    fn parseTop(self: *Parser) CompileError!Node {
        const node = try self.parseAlt();
        // `parseConcat` only stops at `|`, `)`, or end of input, and
        // `parseAlt` consumes every `|`. Anything left over is therefore an
        // unmatched `)`.
        if (self.i != self.pattern.len) return error.UnbalancedParen;
        return node;
    }

    fn parseAlt(self: *Parser) CompileError!Node {
        var list: std.ArrayList(Node) = .empty;
        try list.append(self.arena, try self.parseConcat());
        while (self.peekByte() == '|') {
            self.i += 1;
            try list.append(self.arena, try self.parseConcat());
        }
        if (list.items.len == 1) return list.items[0];
        return Node{ .alt = try list.toOwnedSlice(self.arena) };
    }

    fn parseConcat(self: *Parser) CompileError!Node {
        var list: std.ArrayList(Node) = .empty;
        while (true) {
            const c = self.peekByte() orelse break;
            if (c == '|' or c == ')') break;
            try list.append(self.arena, try self.parseRepeat());
        }
        if (list.items.len == 0) return .empty;
        if (list.items.len == 1) return list.items[0];
        return Node{ .concat = try list.toOwnedSlice(self.arena) };
    }

    fn parseRepeat(self: *Parser) CompileError!Node {
        var atom = try self.parseAtom();
        while (true) {
            const c = self.peekByte() orelse break;
            var min: u32 = 0;
            var max: ?u32 = null;
            if (c == '*') {
                self.i += 1;
            } else if (c == '+') {
                min = 1;
                self.i += 1;
            } else if (c == '?') {
                max = 1;
                self.i += 1;
            } else if (c == '{') {
                const mm = self.tryParseBrace() orelse break;
                min = mm.min;
                max = mm.max;
            } else break;

            switch (atom) {
                // "a**", "a*+", "a*{2}": a quantifier with no atom of its
                // own between it and the previous one.
                .repeat => return error.NestedQuantifier,
                else => {},
            }
            if (min > MAX_REPEAT or (max != null and max.? > MAX_REPEAT)) return error.BadQuantifierRange;
            if (max) |mx| {
                if (mx < min) return error.BadQuantifierRange;
            }

            var greedy = true;
            if (self.peekByte() == '?') {
                greedy = false;
                self.i += 1;
            }

            const child = try self.arena.create(Node);
            child.* = atom;
            atom = Node{ .repeat = .{ .child = child, .min = min, .max = max, .greedy = greedy } };
        }
        return atom;
    }

    /// `{n}` / `{n,}` / `{n,m}` starting at the current `{`. Consumes and
    /// returns the bounds on success; leaves `i` untouched and returns
    /// `null` when what follows `{` is not that shape at all (a bare `{`
    /// is a literal character, the same convention every other engine's
    /// "not actually a quantifier" fallback uses).
    fn tryParseBrace(self: *Parser) ?struct { min: u32, max: ?u32 } {
        const saved = self.i;
        if (self.peekByte() != '{') return null;
        var j = self.i + 1;
        var min_digits: u32 = 0;
        var has_min = false;
        while (j < self.pattern.len and self.pattern[j] >= '0' and self.pattern[j] <= '9') : (j += 1) {
            has_min = true;
            min_digits = min_digits *% 10 +% (self.pattern[j] - '0');
        }
        if (!has_min) {
            self.i = saved;
            return null;
        }
        var max_val: ?u32 = min_digits;
        if (j < self.pattern.len and self.pattern[j] == ',') {
            j += 1;
            var max_digits: u32 = 0;
            var has_max = false;
            while (j < self.pattern.len and self.pattern[j] >= '0' and self.pattern[j] <= '9') : (j += 1) {
                has_max = true;
                max_digits = max_digits *% 10 +% (self.pattern[j] - '0');
            }
            max_val = if (has_max) max_digits else null;
        }
        if (j >= self.pattern.len or self.pattern[j] != '}') {
            self.i = saved;
            return null;
        }
        self.i = j + 1;
        return .{ .min = min_digits, .max = max_val };
    }

    fn parseAtom(self: *Parser) CompileError!Node {
        const c = self.peekByte() orelse return error.DanglingQuantifier;
        switch (c) {
            '*', '+', '?' => return error.DanglingQuantifier,
            '{' => {
                const saved = self.i;
                if (self.tryParseBrace() != null) {
                    self.i = saved;
                    return error.DanglingQuantifier;
                }
                self.i += 1;
                return Node{ .char = '{' };
            },
            '.' => {
                self.i += 1;
                return .any;
            },
            '^' => {
                self.i += 1;
                return .anchor_start;
            },
            '$' => {
                self.i += 1;
                return .anchor_end;
            },
            '(' => return self.parseGroup(),
            '[' => return self.parseClass(),
            '\\' => return self.parseEscapeAtom(),
            ')' => return error.UnbalancedParen,
            else => {
                const d = decodeUtf8At(self.pattern, self.i).?;
                self.i += d.len;
                return Node{ .char = d.cp };
            },
        }
    }

    fn parseGroup(self: *Parser) CompileError!Node {
        self.i += 1; // '('
        var capture: ?u32 = null;
        if (self.i + 1 < self.pattern.len and self.pattern[self.i] == '?' and self.pattern[self.i + 1] == ':') {
            self.i += 2;
        } else if (self.peekByte() == '?') {
            // `(?i)` is a whole-pattern prefix stripped before the parser
            // ever runs; lookaround, named groups, and inline modifier
            // scopes are out of scope (module doc).
            return error.UnsupportedGroup;
        } else {
            self.ngroups += 1;
            capture = self.ngroups;
        }
        const inner = try self.parseAlt();
        if (self.peekByte() != ')') return error.UnbalancedParen;
        self.i += 1;
        const child = try self.arena.create(Node);
        child.* = inner;
        return Node{ .group = .{ .child = child, .capture = capture } };
    }

    fn parseEscapeAtom(self: *Parser) CompileError!Node {
        if (self.i + 1 >= self.pattern.len) return error.BadEscape;
        const e = self.pattern[self.i + 1];
        switch (e) {
            'd' => {
                self.i += 2;
                return Node{ .class = .{ .ranges = &DIGIT_RANGES, .negate = false } };
            },
            'D' => {
                self.i += 2;
                return Node{ .class = .{ .ranges = &NOT_DIGIT_RANGES, .negate = false } };
            },
            'w' => {
                self.i += 2;
                return Node{ .class = .{ .ranges = &WORD_RANGES, .negate = false } };
            },
            'W' => {
                self.i += 2;
                return Node{ .class = .{ .ranges = &NOT_WORD_RANGES, .negate = false } };
            },
            's' => {
                self.i += 2;
                return Node{ .class = .{ .ranges = &SPACE_RANGES, .negate = false } };
            },
            'S' => {
                self.i += 2;
                return Node{ .class = .{ .ranges = &NOT_SPACE_RANGES, .negate = false } };
            },
            'b' => {
                self.i += 2;
                return Node{ .word_boundary = true };
            },
            'B' => {
                self.i += 2;
                return Node{ .word_boundary = false };
            },
            else => {
                const ch = (try simpleEscapeChar(e)) orelse return error.BadEscape;
                self.i += 2;
                return Node{ .char = ch };
            },
        }
    }

    fn parseClass(self: *Parser) CompileError!Node {
        self.i += 1; // '['
        var negate = false;
        if (self.peekByte() == '^') {
            negate = true;
            self.i += 1;
        }
        var ranges: std.ArrayList(Range) = .empty;
        while (true) {
            const c = self.peekByte() orelse return error.UnbalancedBracket;
            if (c == ']') {
                self.i += 1;
                break;
            }
            // No POSIX "`]` right after `[`/`[^` is a literal member"
            // special case: `]` always closes the class here, so `[]` is
            // `EmptyClass` rather than an unterminated class, and a literal
            // `]` inside a class is always written `\]` — one rule, no
            // "except at the start."
            if (c == '\\') {
                switch (try self.parseClassEscape()) {
                    .ranges => |rs| try ranges.appendSlice(self.arena, rs),
                    .char => |cp| try self.appendClassMember(&ranges, cp),
                }
                continue;
            }
            const d = decodeUtf8At(self.pattern, self.i) orelse return error.UnbalancedBracket;
            self.i += d.len;
            try self.appendClassMember(&ranges, d.cp);
        }
        if (ranges.items.len == 0) return error.EmptyClass;
        return Node{ .class = .{ .ranges = try ranges.toOwnedSlice(self.arena), .negate = negate } };
    }

    /// `lo_cp` plus, when followed by `-<char>` (and that is not `-]`, the
    /// literal-hyphen-at-the-end convention), the range it opens.
    fn appendClassMember(self: *Parser, ranges: *std.ArrayList(Range), lo_cp: u21) CompileError!void {
        if (self.peekByte() == '-' and self.i + 1 < self.pattern.len and self.pattern[self.i + 1] != ']') {
            self.i += 1; // '-'
            const c2 = self.peekByte() orelse return error.UnbalancedBracket;
            const hi_cp: u21 = if (c2 == '\\')
                try self.parseClassEscapeSingleChar()
            else hi: {
                const d = decodeUtf8At(self.pattern, self.i) orelse return error.UnbalancedBracket;
                self.i += d.len;
                break :hi d.cp;
            };
            if (hi_cp < lo_cp) return error.BadClassRange;
            try ranges.append(self.arena, .{ .lo = lo_cp, .hi = hi_cp });
        } else {
            try ranges.append(self.arena, .{ .lo = lo_cp, .hi = lo_cp });
        }
    }

    fn parseClassEscape(self: *Parser) CompileError!ClassEscapeResult {
        if (self.i + 1 >= self.pattern.len) return error.BadEscape;
        const e = self.pattern[self.i + 1];
        switch (e) {
            'd' => {
                self.i += 2;
                return .{ .ranges = &DIGIT_RANGES };
            },
            'D' => {
                self.i += 2;
                return .{ .ranges = &NOT_DIGIT_RANGES };
            },
            'w' => {
                self.i += 2;
                return .{ .ranges = &WORD_RANGES };
            },
            'W' => {
                self.i += 2;
                return .{ .ranges = &NOT_WORD_RANGES };
            },
            's' => {
                self.i += 2;
                return .{ .ranges = &SPACE_RANGES };
            },
            'S' => {
                self.i += 2;
                return .{ .ranges = &NOT_SPACE_RANGES };
            },
            'b', 'B' => return error.BadEscape, // no zero-width assertions inside a class
            else => {
                const ch = (try simpleEscapeChar(e)) orelse return error.BadEscape;
                self.i += 2;
                return .{ .char = ch };
            },
        }
    }

    /// A range endpoint after `\`: a plain escaped char only — `[a-\d]`
    /// (a shorthand class as a range boundary) is nonsense in every engine
    /// that has an opinion, so it is `BadEscape` here too.
    fn parseClassEscapeSingleChar(self: *Parser) CompileError!u21 {
        if (self.i + 1 >= self.pattern.len) return error.BadEscape;
        const e = self.pattern[self.i + 1];
        const ch = (try simpleEscapeChar(e)) orelse return error.BadEscape;
        self.i += 2;
        return ch;
    }
};

// ── Bytecode ─────────────────────────────────────────────────────────────

const Op = enum { char, any, class, match, jmp, split, save, assert_bol, assert_eol, assert_wb, assert_nwb };

const Inst = struct {
    op: Op,
    x: usize = 0,
    y: usize = 0,
    ch: u21 = 0,
    class_idx: usize = 0,
    slot: usize = 0,
};

/// AST → bytecode. Every forward jump target that is not simply "the next
/// instruction" is patched AFTER compiling what comes between (the classic
/// Thompson-construction technique), using the Zig call stack itself to
/// remember which instruction to patch — `compileAlt`/`compileOptionalChain`
/// recurse before patching their own split, so nesting of any depth needs no
/// separate patch-list data structure.
const Compiler = struct {
    gpa: Allocator,
    prog: std.ArrayList(Inst) = .empty,
    classes: std.ArrayList(ClassSet) = .empty,

    fn progLen(self: *Compiler) usize {
        return self.prog.items.len;
    }

    fn emit(self: *Compiler, inst: Inst) CompileError!usize {
        if (self.prog.items.len >= MAX_PROGRAM) return error.ProgramTooLarge;
        try self.prog.append(self.gpa, inst);
        return self.prog.items.len - 1;
    }

    /// Ranges are copied out of the parser's arena into `gpa` — the arena is
    /// freed when `compileDiag` returns, but a compiled `Regex` outlives it.
    fn addClass(self: *Compiler, set: ClassSet) CompileError!usize {
        const copy = try self.gpa.dupe(Range, set.ranges);
        errdefer self.gpa.free(copy);
        try self.classes.append(self.gpa, .{ .ranges = copy, .negate = set.negate });
        return self.classes.items.len - 1;
    }

    fn compileNode(self: *Compiler, node: Node) CompileError!void {
        switch (node) {
            .empty => {},
            .char => |ch| _ = try self.emit(.{ .op = .char, .ch = ch }),
            .any => _ = try self.emit(.{ .op = .any }),
            .class => |set| {
                const idx = try self.addClass(set);
                _ = try self.emit(.{ .op = .class, .class_idx = idx });
            },
            .concat => |list| for (list) |child| try self.compileNode(child),
            .alt => |list| try self.compileAlt(list),
            .repeat => |r| try self.compileRepeat(r.child.*, r.min, r.max, r.greedy),
            .group => |g| {
                if (g.capture) |n| {
                    _ = try self.emit(.{ .op = .save, .slot = n * 2 });
                    try self.compileNode(g.child.*);
                    _ = try self.emit(.{ .op = .save, .slot = n * 2 + 1 });
                } else {
                    try self.compileNode(g.child.*);
                }
            },
            .anchor_start => _ = try self.emit(.{ .op = .assert_bol }),
            .anchor_end => _ = try self.emit(.{ .op = .assert_eol }),
            .word_boundary => |is_b| _ = try self.emit(.{ .op = if (is_b) .assert_wb else .assert_nwb }),
        }
    }

    /// `a1|a2|...|an`, left to right, highest priority first (Perl/PCRE
    /// "first alternative that matches wins", not POSIX longest-match).
    fn compileAlt(self: *Compiler, list: []const Node) CompileError!void {
        if (list.len == 1) return self.compileNode(list[0]);
        const split_idx = try self.emit(.{ .op = .split });
        const first_addr = self.progLen();
        try self.compileNode(list[0]);
        const jmp_idx = try self.emit(.{ .op = .jmp });
        const second_addr = self.progLen();
        self.prog.items[split_idx].x = first_addr;
        self.prog.items[split_idx].y = second_addr;
        try self.compileAlt(list[1..]);
        self.prog.items[jmp_idx].x = self.progLen();
    }

    /// `child*`. The loop-back address is known immediately (it is the
    /// split we are about to emit); the exit address is not known until
    /// after `child` and the loop-back jump are both emitted, so it is the
    /// one deferred patch here.
    fn compileStar(self: *Compiler, child: Node, greedy: bool) CompileError!void {
        const split_idx = try self.emit(.{ .op = .split });
        const continue_addr = self.progLen();
        try self.compileNode(child);
        const jmp_idx = try self.emit(.{ .op = .jmp });
        self.prog.items[jmp_idx].x = split_idx;
        const exit_addr = self.progLen();
        if (greedy) {
            self.prog.items[split_idx].x = continue_addr;
            self.prog.items[split_idx].y = exit_addr;
        } else {
            self.prog.items[split_idx].x = exit_addr;
            self.prog.items[split_idx].y = continue_addr;
        }
    }

    /// `remaining` nested `child?`s: `(child(child(child)?)?)?`, the
    /// desugaring `{n,m}` uses for its `m - n` optional tail so a match can
    /// stop after any of them without the later copies needing to run.
    fn compileOptionalChain(self: *Compiler, child: Node, remaining: u32, greedy: bool) CompileError!void {
        if (remaining == 0) return;
        const split_idx = try self.emit(.{ .op = .split });
        const continue_addr = self.progLen();
        try self.compileNode(child);
        try self.compileOptionalChain(child, remaining - 1, greedy);
        const exit_addr = self.progLen();
        if (greedy) {
            self.prog.items[split_idx].x = continue_addr;
            self.prog.items[split_idx].y = exit_addr;
        } else {
            self.prog.items[split_idx].x = exit_addr;
            self.prog.items[split_idx].y = continue_addr;
        }
    }

    /// `{n,m}` (and `* + ?`, which are just `{0,}` `{1,}` `{0,1}`): `min`
    /// mandatory copies — each one a fresh `compileNode` call over the same
    /// AST node, so a capture group inside a repeated atom writes its slot
    /// once per iteration and the LAST iteration's span is what survives,
    /// same as every other engine — then either an unbounded `*` tail or a
    /// bounded optional chain.
    fn compileRepeat(self: *Compiler, child: Node, min: u32, max: ?u32, greedy: bool) CompileError!void {
        var i: u32 = 0;
        while (i < min) : (i += 1) try self.compileNode(child);
        if (max) |mx| {
            if (mx > min) try self.compileOptionalChain(child, mx - min, greedy);
        } else {
            try self.compileStar(child, greedy);
        }
    }
};

// ── The Pike VM ──────────────────────────────────────────────────────────

const UNSET: usize = std.math.maxInt(usize);

const Thread = struct {
    pc: usize,
    caps: [2 * MAX_CAPTURES]usize,
};

const ThreadList = struct {
    threads: []Thread,
    len: usize = 0,

    fn clear(self: *ThreadList) void {
        self.len = 0;
    }
    fn push(self: *ThreadList, th: Thread) void {
        self.threads[self.len] = th;
        self.len += 1;
    }
};

/// A set of byte values — the bytes a match can begin with (`Regex.first`).
const ByteSet = struct {
    bits: std.StaticBitSet(256) = .initEmpty(),
    /// The set's one member when it has exactly one, so `next` is a plain
    /// scalar search (the common literal-lead case) instead of a set probe
    /// per byte.
    only: ?u8 = null,

    fn has(self: *const ByteSet, b: u8) bool {
        return self.bits.isSet(b);
    }

    fn add(self: *ByteSet, b: u8) void {
        self.bits.set(b);
    }

    fn addRange(self: *ByteSet, lo: u8, hi: u8) void {
        var b: usize = lo;
        while (b <= hi) : (b += 1) self.add(@intCast(b));
    }

    /// Every byte codepoint `cp` can begin with in a haystack, as
    /// `decodeUtf8At` reads one: its UTF-8 lead byte, and for 0x80..0xFF the
    /// raw byte too (an invalid byte decodes as itself). ASCII letters add
    /// their other case when folding.
    fn addCp(self: *ByteSet, cp: u21, ci: bool) void {
        if (cp < 0x80) {
            self.add(@intCast(cp));
            if (ci and isAsciiUpper(cp)) self.add(@intCast(cp + 32));
            if (ci and isAsciiLower(cp)) self.add(@intCast(cp - 32));
            return;
        }
        if (cp <= 0xff) self.add(@intCast(cp));
        var buf: [4]u8 = undefined;
        _ = std.unicode.utf8Encode(cp, &buf) catch return; // a surrogate never decodes
        self.add(buf[0]);
    }

    fn seal(self: *ByteSet) void {
        if (self.bits.count() == 1) self.only = @intCast(self.bits.findFirstSet().?);
    }

    /// The first position at or after `from` holding a member.
    fn next(self: *const ByteSet, haystack: []const u8, from: usize) ?usize {
        if (self.only) |b| return std.mem.indexOfScalarPos(u8, haystack, from, b);
        var i = from;
        while (i < haystack.len) : (i += 1) {
            if (self.bits.isSet(haystack[i])) return i;
        }
        return null;
    }
};

/// The bytes a match of `prog` can begin with, or null when a match can
/// begin with (nearly) anything or with nothing at all: `.` and a negated
/// class, or a `match` reachable without consuming — an empty match, which
/// needs no byte to begin with. Assertions are passed through (they only
/// ever narrow where a match starts, so ignoring them over-approximates,
/// which is the safe direction).
fn firstBytes(gpa: Allocator, prog: []const Inst, classes: []const ClassSet, ci: bool) Allocator.Error!?ByteSet {
    const seen = try gpa.alloc(bool, prog.len);
    defer gpa.free(seen);
    @memset(seen, false);
    var stack: std.ArrayList(usize) = .empty;
    defer stack.deinit(gpa);
    try stack.append(gpa, 0);
    var set: ByteSet = .{};
    while (stack.pop()) |pc| {
        if (seen[pc]) continue;
        seen[pc] = true;
        const inst = prog[pc];
        switch (inst.op) {
            .jmp => try stack.append(gpa, inst.x),
            .split => {
                try stack.append(gpa, inst.x);
                try stack.append(gpa, inst.y);
            },
            .save, .assert_bol, .assert_eol, .assert_wb, .assert_nwb => try stack.append(gpa, pc + 1),
            .match, .any => return null,
            .char => set.addCp(inst.ch, ci),
            .class => {
                const cls = classes[inst.class_idx];
                if (cls.negate) return null;
                for (cls.ranges) |r| {
                    if (r.lo < 0x80) {
                        var cp = r.lo;
                        while (cp <= @min(r.hi, 0x7f)) : (cp += 1) set.addCp(cp, ci);
                    }
                    // Past ASCII: every lead byte and every raw high byte.
                    if (r.hi >= 0x80) set.addRange(0x80, 0xff);
                }
            },
        }
    }
    set.seal();
    return set;
}

pub const Regex = struct {
    gpa: Allocator,
    prog: []const Inst,
    classes: []const ClassSet,
    ncaps: usize,
    options: Options,
    /// Sized to `prog.len` once at compile time and reused by every `find`
    /// call after that (module doc, "bounded memory").
    clist: ThreadList,
    nlist: ThreadList,
    gen: []usize,
    gen_cur: usize,
    /// The bytes a match can begin with, or null when that is "any" (a
    /// pattern that can match empty, or opens with `.` or a negated class).
    /// While no thread is alive, the unanchored scan jumps straight to the
    /// next such byte instead of seeding and stepping a thread per byte in
    /// between — the difference between walking the VM across a whole
    /// document and walking it across the places a match could be.
    first: ?ByteSet,

    /// See `compile`; this variant additionally reports the byte offset
    /// into `pattern` a `CompileError` points at (`err_pos.*` is
    /// meaningless on success). `TooManyCaptures` and `ProgramTooLarge` are
    /// whole-pattern complaints, not a single-position one, so they leave
    /// `err_pos` at 0.
    pub fn compileDiag(gpa: Allocator, pattern_in: []const u8, options: Options, err_pos: *usize) CompileError!Regex {
        err_pos.* = 0;
        var pattern = pattern_in;
        var ci = options.case_insensitive;
        if (std.mem.startsWith(u8, pattern, "(?i)")) {
            ci = true;
            pattern = pattern[4..];
        }

        var arena_state = std.heap.ArenaAllocator.init(gpa);
        defer arena_state.deinit();
        var parser = Parser{ .arena = arena_state.allocator(), .pattern = pattern };
        const ast = parser.parseTop() catch |err| {
            err_pos.* = parser.i;
            return err;
        };
        const ncaps: usize = parser.ngroups + 1;
        if (ncaps > MAX_CAPTURES) return error.TooManyCaptures;

        var compiler = Compiler{ .gpa = gpa };
        errdefer {
            compiler.prog.deinit(gpa);
            for (compiler.classes.items) |cls| gpa.free(cls.ranges);
            compiler.classes.deinit(gpa);
        }
        _ = try compiler.emit(.{ .op = .save, .slot = 0 });
        try compiler.compileNode(ast);
        _ = try compiler.emit(.{ .op = .save, .slot = 1 });
        _ = try compiler.emit(.{ .op = .match });

        const prog = try compiler.prog.toOwnedSlice(gpa);
        errdefer gpa.free(prog);
        const classes = try compiler.classes.toOwnedSlice(gpa);
        errdefer {
            for (classes) |cls| gpa.free(cls.ranges);
            gpa.free(classes);
        }

        const clist_buf = try gpa.alloc(Thread, prog.len);
        errdefer gpa.free(clist_buf);
        const nlist_buf = try gpa.alloc(Thread, prog.len);
        errdefer gpa.free(nlist_buf);
        const first = try firstBytes(gpa, prog, classes, ci);
        const gen_buf = try gpa.alloc(usize, prog.len);
        @memset(gen_buf, 0);

        return Regex{
            .first = first,
            .gpa = gpa,
            .prog = prog,
            .classes = classes,
            .ncaps = ncaps,
            .options = .{ .case_insensitive = ci, .multiline = options.multiline },
            .clist = .{ .threads = clist_buf, .len = 0 },
            .nlist = .{ .threads = nlist_buf, .len = 0 },
            .gen = gen_buf,
            .gen_cur = 0,
        };
    }

    pub fn compile(gpa: Allocator, pattern: []const u8, options: Options) CompileError!Regex {
        var pos: usize = 0;
        return compileDiag(gpa, pattern, options, &pos);
    }

    pub fn deinit(self: *Regex) void {
        self.gpa.free(self.prog);
        for (self.classes) |cls| self.gpa.free(cls.ranges);
        self.gpa.free(self.classes);
        self.gpa.free(self.clist.threads);
        self.gpa.free(self.nlist.threads);
        self.gpa.free(self.gen);
        self.* = undefined;
    }

    /// The leftmost match starting at or after `start`, or `null`. Perl/PCRE
    /// priority order, not POSIX longest-match: among several ways to match
    /// at the same start, the one the pattern text prefers (earlier
    /// alternative, greedy-vs-lazy) wins, exactly as a backtracking engine
    /// would return, just without backtracking to get there.
    pub fn find(self: *Regex, haystack: []const u8, start: usize) ?Match {
        if (start > haystack.len) return null;
        return self.run(haystack, start, false);
    }

    /// The match starting EXACTLY at `pos`, or `null` — `find` without the
    /// per-position re-seeding that makes it unanchored. A caller that
    /// already knows where a match can start (a find bar's literal
    /// prefilter, which skips to each occurrence of a required prefix with a
    /// plain substring search) tries only those positions instead of
    /// stepping every thread across the bytes between them. Assertions still
    /// see the whole haystack, so `\b` and `^` at `pos` look behind it
    /// exactly as they would inside `find`.
    pub fn matchAt(self: *Regex, haystack: []const u8, pos: usize) ?Match {
        if (pos > haystack.len) return null;
        return self.run(haystack, pos, true);
    }

    pub const Iterator = struct {
        re: *Regex,
        haystack: []const u8,
        pos: usize,
        done: bool = false,

        /// An empty match advances by one codepoint so `findAll` over `a*`
        /// against `"bbb"` yields four empty matches (one per gap and the
        /// end) instead of looping forever on the first one.
        pub fn next(self: *Iterator) ?Match {
            if (self.done) return null;
            const m = self.re.find(self.haystack, self.pos) orelse {
                self.done = true;
                return null;
            };
            if (m.end == m.start) {
                self.pos = if (decodeUtf8At(self.haystack, m.end)) |d| m.end + d.len else m.end + 1;
            } else {
                self.pos = m.end;
            }
            if (self.pos > self.haystack.len) self.done = true;
            return m;
        }
    };

    pub fn findAll(self: *Regex, haystack: []const u8) Iterator {
        return .{ .re = self, .haystack = haystack, .pos = 0 };
    }

    /// The last match whose end is at or before `offset` — what `?`/`N`
    /// (search backward) need. Implemented as a forward scan of every match
    /// up to `offset`, kept for simplicity and because match ends are
    /// monotonic across `findAll`: correctness over a clever reverse
    /// window. An interactive backward search over a merely buffer-sized
    /// haystack does not need better than O(n) here; if it ever does, that
    /// is a caching problem for the caller, not a reason to complicate this
    /// engine.
    pub fn findBefore(self: *Regex, haystack: []const u8, offset: usize) ?Match {
        var it = self.findAll(haystack);
        var last: ?Match = null;
        while (it.next()) |m| {
            if (m.end > offset) break;
            last = m;
        }
        return last;
    }

    fn buildMatch(self: *const Regex, caps: [2 * MAX_CAPTURES]usize) Match {
        var m = Match{ .start = caps[0], .end = caps[1], .ngroups = self.ncaps };
        var g: usize = 0;
        while (g < self.ncaps) : (g += 1) {
            const s = caps[2 * g];
            const e = caps[2 * g + 1];
            m.groups[g] = if (s != UNSET and e != UNSET) Span{ .start = s, .end = e } else null;
        }
        return m;
    }

    /// Epsilon-closure from `pc`: follows `jmp`/`split`/`save` and resolves
    /// zero-width assertions immediately, only ever pushing a thread onto
    /// `list` when it reaches a byte-consuming instruction or `match`. The
    /// `gen` check is both the dedup ("at most one thread per pc") and the
    /// cycle guard — without it `(a*)*` would recurse forever through its
    /// own empty-body loop.
    fn addThread(self: *Regex, list: *ThreadList, pc: usize, pos: usize, caps: [2 * MAX_CAPTURES]usize, haystack: []const u8) void {
        if (self.gen[pc] == self.gen_cur) return;
        self.gen[pc] = self.gen_cur;
        const inst = self.prog[pc];
        switch (inst.op) {
            .jmp => self.addThread(list, inst.x, pos, caps, haystack),
            .split => {
                self.addThread(list, inst.x, pos, caps, haystack);
                self.addThread(list, inst.y, pos, caps, haystack);
            },
            .save => {
                var next_caps = caps;
                if (inst.slot < next_caps.len) next_caps[inst.slot] = pos;
                self.addThread(list, pc + 1, pos, next_caps, haystack);
            },
            .assert_bol => if (atLineStart(self.options, haystack, pos)) self.addThread(list, pc + 1, pos, caps, haystack),
            .assert_eol => if (atLineEnd(self.options, haystack, pos)) self.addThread(list, pc + 1, pos, caps, haystack),
            .assert_wb => if (atWordBoundary(haystack, pos)) self.addThread(list, pc + 1, pos, caps, haystack),
            .assert_nwb => if (!atWordBoundary(haystack, pos)) self.addThread(list, pc + 1, pos, caps, haystack),
            .char, .any, .class, .match => list.push(.{ .pc = pc, .caps = caps }),
        }
    }

    /// The step loop proper. `clist` holds the threads alive AT `pos`
    /// (already closed); each step decodes the codepoint at `pos` (if any),
    /// advances every consuming thread into `nlist`, and — unless a match
    /// has already been found — seeds one more lowest-priority thread at
    /// `pos` so the search keeps trying later starting points (this is what
    /// makes `find` unanchored without a separate ".*?" prefix in every
    /// compiled program). Reaching `match` kills the remaining
    /// LOWER-priority threads for this step only; higher-priority threads
    /// already advanced into `nlist` keep racing, which is exactly what
    /// gives greedy quantifiers first refusal on a longer match.
    fn run(self: *Regex, haystack: []const u8, start: usize, anchored: bool) ?Match {
        var zero_caps: [2 * MAX_CAPTURES]usize = undefined;
        @memset(&zero_caps, UNSET);

        self.clist.clear();
        self.nlist.clear();
        self.gen_cur += 1;
        self.addThread(&self.clist, 0, start, zero_caps, haystack);

        var pos = start;
        var matched: ?Match = null;
        while (true) {
            // Nothing alive and nothing found: jump to the next byte a match
            // can begin with and seed there, rather than seeding one doomed
            // thread per byte on the way (`first`).
            if (self.clist.len == 0 and matched == null and !anchored) {
                if (self.first) |set| {
                    pos = set.next(haystack, pos) orelse break;
                    self.gen_cur += 1;
                    self.addThread(&self.clist, 0, pos, zero_caps, haystack);
                }
            }
            const decoded = decodeUtf8At(haystack, pos);
            if (self.clist.len == 0 and (matched != null or decoded == null or anchored)) break;

            self.gen_cur += 1;
            self.nlist.clear();
            step: for (self.clist.threads[0..self.clist.len]) |th| {
                switch (self.prog[th.pc].op) {
                    .match => {
                        matched = self.buildMatch(th.caps);
                        break :step;
                    },
                    .char => if (decoded) |d| {
                        if (foldEq(self.options.case_insensitive, self.prog[th.pc].ch, d.cp))
                            self.addThread(&self.nlist, th.pc + 1, pos + d.len, th.caps, haystack);
                    },
                    .any => if (decoded) |d| {
                        if (d.cp != '\n')
                            self.addThread(&self.nlist, th.pc + 1, pos + d.len, th.caps, haystack);
                    },
                    .class => if (decoded) |d| {
                        if (classMatches(self.classes[self.prog[th.pc].class_idx], self.options.case_insensitive, d.cp))
                            self.addThread(&self.nlist, th.pc + 1, pos + d.len, th.caps, haystack);
                    },
                    else => unreachable, // addThread's closure never leaves an epsilon op in a list
                }
            }
            // Anchored: no later starting point is tried — the threads
            // seeded at `start` are the only ones that ever run.
            if (matched == null and !anchored) {
                if (decoded) |d| {
                    const at = pos + d.len;
                    const can_start = if (self.first) |set| at < haystack.len and set.has(haystack[at]) else true;
                    if (can_start) self.addThread(&self.nlist, 0, at, zero_caps, haystack);
                }
            }
            std.mem.swap(ThreadList, &self.clist, &self.nlist);
            const d = decoded orelse break;
            pos += d.len;
        }
        return matched;
    }
};

/// `$0`..`$9` become the corresponding capture's text (empty when that
/// group did not participate or does not exist), `$$` a literal `$`; any
/// other `$x` (including `$` at the very end) is copied through literally.
/// Named groups aren't supported (module doc), so there is no `${name}` to
/// expand.
pub fn expandReplacement(gpa: Allocator, haystack: []const u8, m: Match, template: []const u8) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var i: usize = 0;
    while (i < template.len) {
        const c = template[i];
        if (c == '$' and i + 1 < template.len) {
            const n = template[i + 1];
            if (n == '$') {
                try out.append(gpa, '$');
                i += 2;
                continue;
            }
            if (n >= '0' and n <= '9') {
                if (m.group(n - '0')) |span| try out.appendSlice(gpa, haystack[span.start..span.end]);
                i += 2;
                continue;
            }
        }
        try out.append(gpa, c);
        i += 1;
    }
    return out.toOwnedSlice(gpa);
}

// ── Tests ────────────────────────────────────────────────────────────────

const t = std.testing;

fn expectFind(pattern: []const u8, haystack: []const u8, start: usize, options: Options, want: ?Span) !void {
    var re = try Regex.compile(t.allocator, pattern, options);
    defer re.deinit();
    const got = re.find(haystack, start);
    if (want) |w| {
        try t.expect(got != null);
        try t.expectEqual(w.start, got.?.start);
        try t.expectEqual(w.end, got.?.end);
    } else {
        try t.expectEqual(@as(?Match, null), got);
    }
}

test "literal and concatenation" {
    try expectFind("abc", "xxabcxx", 0, .{}, .{ .start = 2, .end = 5 });
    try expectFind("abc", "xxabxx", 0, .{}, null);
}

test "matchAt is anchored: it never tries a later start" {
    var re = try Regex.compile(t.allocator, "b+c", .{});
    defer re.deinit();
    try t.expectEqual(@as(?Match, null), re.matchAt("abbc", 0));
    const m = re.matchAt("abbc", 1).?;
    try t.expectEqual(@as(usize, 1), m.start);
    try t.expectEqual(@as(usize, 4), m.end);
    // Assertions still look behind `pos`: `\b` at 1 of "ab" is no boundary.
    var wb = try Regex.compile(t.allocator, "\\bb", .{});
    defer wb.deinit();
    try t.expectEqual(@as(?Match, null), wb.matchAt("ab", 1));
    try t.expect(wb.matchAt("a b", 2) != null);
}

test "the first-byte skip lands on every place a match can begin" {
    try expectFind("\\d+", "abc123", 0, .{}, .{ .start = 3, .end = 6 });
    try expectFind("[b-c]x", "aaCX", 0, .{ .case_insensitive = true }, .{ .start = 2, .end = 4 });
    try expectFind("é", "xyé", 0, .{}, .{ .start = 2, .end = 4 });
    try expectFind("\\bab", "cab ab", 0, .{}, .{ .start = 4, .end = 6 });
    try expectFind("(?:ab|cd)e", "abxcde", 0, .{}, .{ .start = 3, .end = 6 });
    // A pattern that can match empty has no first byte: no skip, same answer.
    try expectFind("x*", "abc", 1, .{}, .{ .start = 1, .end = 1 });
    var re = try Regex.compile(t.allocator, "q", .{});
    defer re.deinit();
    try t.expectEqual(@as(?u8, 'q'), re.first.?.only);
    var any = try Regex.compile(t.allocator, "a|.", .{});
    defer any.deinit();
    try t.expect(any.first == null);
}

test "dot matches any byte but newline" {
    try expectFind("a.c", "xa\ncx", 0, .{}, null);
    try expectFind("a.c", "xazcx", 0, .{}, .{ .start = 1, .end = 4 });
}

test "alternation prefers the first matching branch" {
    try expectFind("cat|category", "categoryzz", 0, .{}, .{ .start = 0, .end = 3 });
    try expectFind("category|cat", "categoryzz", 0, .{}, .{ .start = 0, .end = 8 });
}

test "greedy vs lazy star" {
    try expectFind("a.*b", "a123b456b", 0, .{}, .{ .start = 0, .end = 9 });
    try expectFind("a.*?b", "a123b456b", 0, .{}, .{ .start = 0, .end = 5 });
}

test "plus requires at least one" {
    try expectFind("a+", "b", 0, .{}, null);
    try expectFind("a+", "baaab", 0, .{}, .{ .start = 1, .end = 4 });
}

test "question mark is zero or one, greedy by default" {
    try expectFind("colou?r", "color", 0, .{}, .{ .start = 0, .end = 5 });
    try expectFind("colou?r", "colour", 0, .{}, .{ .start = 0, .end = 6 });
    try expectFind("colou?r", "colouur", 0, .{}, null);
}

test "exact and bounded counted repetition" {
    try expectFind("a{3}", "aa", 0, .{}, null);
    try expectFind("a{3}", "aaaa", 0, .{}, .{ .start = 0, .end = 3 });
    try expectFind("a{2,3}", "aaaa", 0, .{}, .{ .start = 0, .end = 3 });
    try expectFind("a{2,3}?", "aaaa", 0, .{}, .{ .start = 0, .end = 2 });
    try expectFind("a{2,}", "aaaa", 0, .{}, .{ .start = 0, .end = 4 });
}

test "character classes: ranges, negation, literal ] and -" {
    try expectFind("[a-c]+", "xxabccbaxx", 0, .{}, .{ .start = 2, .end = 8 });
    try expectFind("[^a-c]+", "abcxyzabc", 0, .{}, .{ .start = 3, .end = 6 });
    try expectFind("[\\]a]+", "x]a]x", 0, .{}, .{ .start = 1, .end = 4 });
    try expectFind("[a-]+", "x-a-x", 0, .{}, .{ .start = 1, .end = 4 });
}

test "shorthand classes and their negations, standalone and nested" {
    try expectFind("\\d+", "ab123cd", 0, .{}, .{ .start = 2, .end = 5 });
    try expectFind("\\D+", "12ab34", 0, .{}, .{ .start = 2, .end = 4 });
    try expectFind("\\w+", " -foo_9-", 0, .{}, .{ .start = 2, .end = 7 });
    try expectFind("\\W+", "foo   bar", 0, .{}, .{ .start = 3, .end = 6 });
    try expectFind("\\s+", "a\t\n b", 0, .{}, .{ .start = 1, .end = 4 });
    try expectFind("\\S+", "  foo  ", 0, .{}, .{ .start = 2, .end = 5 });
    try expectFind("[\\d\\s]+", "ab1 2cd", 0, .{}, .{ .start = 2, .end = 5 });
    try expectFind("[^\\D]+", "ab123cd", 0, .{}, .{ .start = 2, .end = 5 });
}

test "word boundaries" {
    try expectFind("\\bcat\\b", "concatenate cat scatter", 0, .{}, .{ .start = 12, .end = 15 });
    try expectFind("\\Bcat", "concatenate cat", 0, .{}, .{ .start = 3, .end = 6 });
}

test "anchors: default is whole-haystack, multiline is per-line" {
    try expectFind("^abc$", "abc", 0, .{}, .{ .start = 0, .end = 3 });
    try expectFind("^abc$", "xabc", 0, .{}, null);
    try expectFind("^abc$", "line1\nabc\nline3", 0, .{}, null);
    try expectFind("^abc$", "line1\nabc\nline3", 0, .{ .multiline = true }, .{ .start = 6, .end = 9 });
}

test "capture groups report submatch spans, non-capturing groups do not" {
    var re = try Regex.compile(t.allocator, "(a+)(b+)", .{});
    defer re.deinit();
    const m = re.find("xxaaabbx", 0).?;
    try t.expectEqual(@as(usize, 2), m.start);
    try t.expectEqual(@as(usize, 7), m.end);
    try t.expectEqual(@as(usize, 2), m.group(1).?.start);
    try t.expectEqual(@as(usize, 5), m.group(1).?.end);
    try t.expectEqual(@as(usize, 5), m.group(2).?.start);
    try t.expectEqual(@as(usize, 7), m.group(2).?.end);

    var re2 = try Regex.compile(t.allocator, "(?:a+)(b+)", .{});
    defer re2.deinit();
    const m2 = re2.find("aaabb", 0).?;
    try t.expectEqual(@as(usize, 2), m2.ngroups); // group 0 + one capturing group
    try t.expectEqual(@as(usize, 3), m2.group(1).?.start);
}

test "a repeated capture group keeps the last iteration's span" {
    var re = try Regex.compile(t.allocator, "(a)+", .{});
    defer re.deinit();
    const m = re.find("aaa", 0).?;
    try t.expectEqual(@as(usize, 2), m.group(1).?.start);
    try t.expectEqual(@as(usize, 3), m.group(1).?.end);
}

test "an unparticipated group in an untaken alternative reports null" {
    var re = try Regex.compile(t.allocator, "(a)|(b)", .{});
    defer re.deinit();
    const m = re.find("b", 0).?;
    try t.expectEqual(@as(?Span, null), m.group(1));
    try t.expectEqual(Span{ .start = 0, .end = 1 }, m.group(2).?);
}

test "case-insensitive: option and inline (?i) flag" {
    try expectFind("HELLO", "say hello now", 0, .{ .case_insensitive = true }, .{ .start = 4, .end = 9 });
    try expectFind("(?i)HELLO", "say hello now", 0, .{}, .{ .start = 4, .end = 9 });
    try expectFind("[a-z]+", "ABCabc", 0, .{ .case_insensitive = true }, .{ .start = 0, .end = 6 });
}

test "UTF-8 multibyte literals and classes report byte spans" {
    // "café " — é is 2 bytes, so "café" spans bytes [0,5).
    try expectFind("café", "café rules", 0, .{}, .{ .start = 0, .end = 5 });
    try expectFind(".+", "日本語", 0, .{}, .{ .start = 0, .end = 9 });
    try expectFind("[日本]+", "日本語", 0, .{}, .{ .start = 0, .end = 6 });
}

test "findAll advances past empty matches without looping forever" {
    var re = try Regex.compile(t.allocator, "a*", .{});
    defer re.deinit();
    var it = re.findAll("bab");
    const m0 = it.next().?; // empty match before 'b'
    try t.expectEqual(Span{ .start = 0, .end = 0 }, Span{ .start = m0.start, .end = m0.end });
    const m1 = it.next().?; // "a"
    try t.expectEqual(Span{ .start = 1, .end = 2 }, Span{ .start = m1.start, .end = m1.end });
    const m2 = it.next().?; // empty match before final 'b'
    try t.expectEqual(Span{ .start = 2, .end = 2 }, Span{ .start = m2.start, .end = m2.end });
    const m3 = it.next().?; // empty match at end of string
    try t.expectEqual(Span{ .start = 3, .end = 3 }, Span{ .start = m3.start, .end = m3.end });
    try t.expectEqual(@as(?Match, null), it.next());
}

test "findAll over a non-empty pattern yields every non-overlapping match" {
    var re = try Regex.compile(t.allocator, "\\d+", .{});
    defer re.deinit();
    var it = re.findAll("a12b345c6");
    var spans = std.ArrayList(Span).empty;
    defer spans.deinit(t.allocator);
    while (it.next()) |m| try spans.append(t.allocator, .{ .start = m.start, .end = m.end });
    try t.expectEqual(@as(usize, 3), spans.items.len);
    try t.expectEqual(Span{ .start = 1, .end = 3 }, spans.items[0]);
    try t.expectEqual(Span{ .start = 4, .end = 7 }, spans.items[1]);
    try t.expectEqual(Span{ .start = 8, .end = 9 }, spans.items[2]);
}

test "findBefore returns the last match ending at or before the offset" {
    var re = try Regex.compile(t.allocator, "\\d+", .{});
    defer re.deinit();
    try t.expectEqual(Span{ .start = 1, .end = 3 }, blk: {
        const m = re.findBefore("a12b345c6", 3).?;
        break :blk Span{ .start = m.start, .end = m.end };
    });
    try t.expectEqual(Span{ .start = 4, .end = 7 }, blk: {
        const m = re.findBefore("a12b345c6", 7).?;
        break :blk Span{ .start = m.start, .end = m.end };
    });
    try t.expectEqual(@as(?Match, null), re.findBefore("a12b345c6", 0));
}

test "replace template: $0 $1..$9 and $$" {
    var re = try Regex.compile(t.allocator, "(\\w+)@(\\w+)", .{});
    defer re.deinit();
    const haystack = "user@host";
    const m = re.find(haystack, 0).?;
    const out = try expandReplacement(t.allocator, haystack, m, "$2!$1 (was $0) $$");
    defer t.allocator.free(out);
    try t.expectEqualStrings("host!user (was user@host) $", out);
}

test "compile errors report a byte position" {
    var pos: usize = 0;
    // Reports where the closing `)` was expected but the pattern ran out
    // (end of text), not the position of the opening `(` — the parser does
    // not track a stack of open-paren positions, only "what did I want next
    // and where did I stop looking."
    try t.expectError(error.UnbalancedParen, Regex.compileDiag(t.allocator, "a(b", .{}, &pos));
    try t.expectEqual(@as(usize, 3), pos);

    try t.expectError(error.UnbalancedParen, Regex.compileDiag(t.allocator, "a)b", .{}, &pos));
    try t.expectEqual(@as(usize, 1), pos);

    // Same "ran out of input looking for X" convention as UnbalancedParen.
    try t.expectError(error.UnbalancedBracket, Regex.compileDiag(t.allocator, "a[bc", .{}, &pos));
    try t.expectEqual(@as(usize, 4), pos);

    try t.expectError(error.DanglingQuantifier, Regex.compileDiag(t.allocator, "*abc", .{}, &pos));
    try t.expectEqual(@as(usize, 0), pos);

    try t.expectError(error.DanglingQuantifier, Regex.compileDiag(t.allocator, "a|*b", .{}, &pos));
    try t.expectEqual(@as(usize, 2), pos);

    try t.expectError(error.NestedQuantifier, Regex.compileDiag(t.allocator, "a**", .{}, &pos));

    try t.expectError(error.BadQuantifierRange, Regex.compileDiag(t.allocator, "a{3,1}", .{}, &pos));

    try t.expectError(error.BadEscape, Regex.compileDiag(t.allocator, "\\p", .{}, &pos));

    try t.expectError(error.UnsupportedGroup, Regex.compileDiag(t.allocator, "(?=x)", .{}, &pos));

    try t.expectError(error.EmptyClass, Regex.compileDiag(t.allocator, "[]", .{}, &pos));
}

test "too many capture groups is rejected at compile time" {
    var buf: [MAX_CAPTURES + 1][]const u8 = undefined;
    for (&buf) |*s| s.* = "(a)";
    var pattern: std.ArrayList(u8) = .empty;
    defer pattern.deinit(t.allocator);
    for (buf) |s| try pattern.appendSlice(t.allocator, s);
    var pos: usize = 0;
    try t.expectError(error.TooManyCaptures, Regex.compileDiag(t.allocator, pattern.items, .{}, &pos));
}

// ── Property test: cross-check against a naive backtracking reference ──────
//
// A deliberately tiny engine over a RESTRICTED syntax (literals, `.`, `* + ?`,
// top-level `|`, concatenation — no groups, no anchors, no classes) that a
// backtracking implementation gets right by construction. Random patterns and
// haystacks are checked for FULL-STRING match agreement (the Pike VM is
// wrapped in `^...$` so "does it match at all" and "does it match the whole
// string" coincide), which exercises the VM's quantifier and alternation
// logic without needing the reference to understand unanchored search.

fn naiveMatch(pattern: []const u8, text: []const u8) bool {
    var start: usize = 0;
    var i: usize = 0;
    while (i <= pattern.len) : (i += 1) {
        if (i == pattern.len or pattern[i] == '|') {
            if (naiveHere(pattern[start..i], 0, text, 0)) return true;
            start = i + 1;
        }
    }
    return false;
}

fn naiveHere(seq: []const u8, si: usize, text: []const u8, ti: usize) bool {
    if (si >= seq.len) return ti == text.len;
    const c = seq[si];
    var next_si = si + 1;
    var quant: u8 = 0;
    if (next_si < seq.len and (seq[next_si] == '*' or seq[next_si] == '+' or seq[next_si] == '?')) {
        quant = seq[next_si];
        next_si += 1;
    }
    const matches_one = ti < text.len and (c == '.' or text[ti] == c);
    switch (quant) {
        0 => return matches_one and naiveHere(seq, next_si, text, ti + 1),
        '?' => {
            if (matches_one and naiveHere(seq, next_si, text, ti + 1)) return true;
            return naiveHere(seq, next_si, text, ti);
        },
        '*' => {
            var count: usize = 0;
            while (ti + count < text.len and (c == '.' or text[ti + count] == c)) count += 1;
            while (true) {
                if (naiveHere(seq, next_si, text, ti + count)) return true;
                if (count == 0) return false;
                count -= 1;
            }
        },
        '+' => {
            if (!matches_one) return false;
            var count: usize = 1;
            while (ti + count < text.len and (c == '.' or text[ti + count] == c)) count += 1;
            while (count >= 1) {
                if (naiveHere(seq, next_si, text, ti + count)) return true;
                count -= 1;
            }
            return false;
        },
        else => unreachable,
    }
}

fn randomPattern(buf: []u8, rng: std.Random) []const u8 {
    const alphabet = "ab";
    const quants = [_]u8{ 0, '*', '+', '?' };
    var len: usize = 0;
    const branches = 1 + rng.uintLessThan(u8, 2);
    var branch: u8 = 0;
    while (branch < branches) : (branch += 1) {
        if (branch > 0) {
            buf[len] = '|';
            len += 1;
        }
        const tokens = 1 + rng.uintLessThan(u8, 3);
        var tok: u8 = 0;
        while (tok < tokens) : (tok += 1) {
            buf[len] = if (rng.boolean()) '.' else alphabet[rng.uintLessThan(u8, alphabet.len)];
            len += 1;
            const q = quants[rng.uintLessThan(u8, quants.len)];
            if (q != 0) {
                buf[len] = q;
                len += 1;
            }
        }
    }
    return buf[0..len];
}

test "property: Pike VM agrees with a naive backtracking reference" {
    var prng = std.Random.DefaultPrng.init(0xC0FFEE);
    const rng = prng.random();
    var pat_buf: [64]u8 = undefined;
    var full_buf: [70]u8 = undefined;
    const haystacks = [_][]const u8{ "", "a", "b", "aa", "ab", "ba", "bb", "aaa", "aab", "aba", "abb", "bbb", "abab" };

    var trial: usize = 0;
    while (trial < 500) : (trial += 1) {
        const pattern = randomPattern(&pat_buf, rng);
        // `^` and `$` bind to the outermost `|` just like anywhere else in
        // this grammar, so "^a|b$" is "(^a)|(b$)", not the whole-pattern
        // anchor intended here — a non-capturing group is what actually
        // scopes them over the whole (possibly-alternated) pattern.
        const prefix = "^(?:";
        @memcpy(full_buf[0..prefix.len], prefix);
        @memcpy(full_buf[prefix.len .. prefix.len + pattern.len], pattern);
        full_buf[prefix.len + pattern.len] = ')';
        full_buf[prefix.len + pattern.len + 1] = '$';
        const anchored = full_buf[0 .. prefix.len + pattern.len + 2];

        var pos: usize = 0;
        var re = Regex.compileDiag(t.allocator, anchored, .{}, &pos) catch continue; // dangling/nested from random text is expected sometimes
        defer re.deinit();

        for (haystacks) |h| {
            const want = naiveMatch(pattern, h);
            const got = re.find(h, 0) != null;
            if (want != got) {
                std.debug.print("mismatch pattern={s} haystack={s} want={} got={}\n", .{ pattern, h, want, got });
            }
            try t.expect(want == got);
        }
    }
}
