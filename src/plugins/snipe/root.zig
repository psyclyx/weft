//! snipe — evil-snipe (github.com/hlissner/evil-snipe) for weft.
//!
//! `s`/`S` jump to the next/previous place two typed characters occur; in an
//! operator-pending mode `z`/`Z` do the same inclusively and `x`/`X`
//! exclusively (`d z a b` deletes through "ab", `d x a b` up to it); and the
//! override set `f`/`F`/`t`/`T` is the same machinery with ONE character. No
//! labels: a snipe lands on the COUNTth match (`3sab`), and the matches are
//! highlighted — incrementally while you type, then around where you landed
//! until your next key.
//!
//! Faithful to evil-snipe.el (v2.1.3) where it matters to the hands:
//!
//!   · SCOPE decides how far a snipe looks: `line` (rest of the line, the
//!     default), `buffer`, `visible` (the pane's shown range), or the
//!     `whole-*` forms, which search the same way but highlight both sides.
//!     `repeat-scope` applies to `;`/`,` (default: `scope`); a failed snipe
//!     tries `spillover-scope` if set, and so does any snipe with a count.
//!   · REPEAT: `;`/`,` repeat the last snipe in its direction / reversed, with
//!     the count it was made with times the one typed now. Right after a
//!     snipe (the very next key — `weft.keySerial`) the snipe's own keys
//!     repeat it: `s` as `;` and `S` as `,` (likewise `f`/`F`, `t`/`T`), so
//!     after `S` another `S` goes forward, exactly as in evil-snipe. RET at
//!     the prompt with nothing typed repeats the last snipe; with one
//!     character typed, it searches for that one.
//!   · SMART CASE (`smart-case`): case-insensitive unless a capital is typed.
//!     ALIASES map a typed character to a set (`"[", "[[{(]"`: `sa[` matches
//!     `a[`, `a{`, `a(`). SKIP-LEADING-WHITESPACE: a snipe for a blank that
//!     starts on a blank matches the LAST blank of a run, so `f SPC ;` walks
//!     from gap to gap rather than through indentation.
//!
//! **Operators.** The `snipe.operate-*` commands hand their range to the command
//! named by `weft.set("snipe", "operator", …)` — vim's `vim.operate` — and the
//! typed count comes from `weft.set("snipe", "count", …)` (vim's
//! `vim.count-take`). Snipe names no grammar; without those values an
//! operator-pending snipe just moves and a count is 1.
//!
//! **Several selections.** A snipe is a motion, so it maps like one: every
//! extent snipes from its own caret (`.each`), and under an operator every
//! extent hands its own range on through the same mapping. The commands that
//! only open the prompt are `.whole` — they read nothing per extent.
//!
//! Configuration (`weft.set("snipe", key, value)`): `scope`, `repeat-scope`,
//! `spillover-scope` (a scope name); `smart-case`, `highlight`,
//! `incremental-highlight`, `repeat-keys`, `skip-leading-whitespace`,
//! `show-prompt` ("on"/"off"); `aliases` (a flat list, char then set);
//! `operator`, `count` (command names).

const std = @import("std");
const weft = @import("weft");

const char_mode = "snipe-char";
const layer_name = "snipe";

// ── Settings ─────────────────────────────────────────────────────────

const Scope = enum { line, buffer, visible, whole_line, whole_buffer, whole_visible };

const scope_names = [_]struct { []const u8, Scope }{
    .{ "line", .line },                 .{ "buffer", .buffer },
    .{ "visible", .visible },           .{ "whole-line", .whole_line },
    .{ "whole-buffer", .whole_buffer }, .{ "whole-visible", .whole_visible },
};

fn scopeSetting(key: []const u8) ?Scope {
    const v = weft.config(key);
    for (scope_names) |n| if (std.mem.eql(u8, n[0], v)) return n[1];
    return null;
}

/// An "on"/"off" value, `default` when unset.
fn flag(key: []const u8, default: bool) bool {
    const v = weft.config(key);
    if (v.len == 0) return default;
    return std.mem.eql(u8, v, "on") or std.mem.eql(u8, v, "true") or std.mem.eql(u8, v, "yes");
}

// ── What a snipe is ──────────────────────────────────────────────────

/// The four families evil-snipe defines (`evil-snipe-def`): how many
/// characters they read, and whether they land ON the match or short of it.
const Kind = enum {
    s,
    x,
    f,
    t,

    fn chars(k: Kind) usize {
        return switch (k) {
            .s, .x => 2,
            .f, .t => 1,
        };
    }
    fn inclusive(k: Kind) bool {
        return k == .s or k == .f;
    }
};

/// What the landing is for: the caret, or a pending operator's range.
const Use = enum { move, operate };

/// One typed character, as UTF-8.
const Key = struct {
    buf: [4]u8 = undefined,
    len: u8 = 0,

    fn bytes(k: *const Key) []const u8 {
        return k.buf[0..k.len];
    }
    fn blank(k: *const Key) bool {
        return k.len == 1 and (k.buf[0] == ' ' or k.buf[0] == '\t');
    }
};

const max_keys = 2;
/// A count past this is a typo, not a request: `99999sab` looks as far as
/// this many matches.
const max_count = 10_000;

const Keys = struct {
    items: [max_keys]Key = undefined,
    n: usize = 0,

    fn slice(k: *const Keys) []const Key {
        return k.items[0..k.n];
    }
};

/// A snipe to perform: the keys, what they land like, how far and which way.
const Request = struct {
    keys: Keys,
    kind: Kind,
    /// Signed: the sign is the direction, the magnitude the match to land on.
    count: i32,
    scope: Scope,
    spillover: ?Scope,
    use: Use,
    repeating: bool,
};

// ── State ────────────────────────────────────────────────────────────

/// The prompt in flight.
var prompt: struct {
    kind: Kind = .s,
    forward: bool = true,
    use: Use = .move,
    count: ?u32 = null,
    keys: Keys = .{},
} = .{};

/// The mode the prompt was opened from, to go back to (`visual` keeps its
/// selection). Empty: the entry's resting mode.
var origin_buf: [64]u8 = undefined;
var origin_len: usize = 0;

/// The snipe `snipe.go` performs, once per extent.
var request: Request = undefined;

/// The last snipe made (not a repeat of one): what `;`/`,` repeat.
var last: ?struct { keys: Keys, kind: Kind, count: i32 } = null;

/// The key a snipe finished on — the NEXT key repeats it if it is the
/// snipe's own (evil-snipe's transient map).
var armed_serial: ?u32 = null;

/// The count read for the key being dispatched: read once, however many
/// extents the command then maps over.
var count_serial: ?u32 = null;
var count_cached: ?u32 = null;

/// The highlight layer on the focused entry, and the key its round is for.
var layer: ?weft.Annotations = null;
var layer_entry: ?u32 = null;
var paint_serial: ?u32 = null;

// ── Commands ─────────────────────────────────────────────────────────

const whole: weft.Arity = .whole;
const each = weft.Arity.each_extent;

/// A motion (`s`, `f`, …) reads its characters, then moves: a grammar key
/// which-key names. Its `operate-*` twin is an operator-pending continuation
/// a person never runs by name.
fn entry(comptime name: []const u8, comptime kind: Kind, comptime forward: bool, comptime use: Use, comptime label: []const u8, comptime summary: []const u8) weft.CommandEntry {
    return .{
        .name = name,
        .arity = whole,
        .call = start(kind, forward, use),
        .summary = summary,
        // An operate variant is a key pressed after an operator (`d s`), so it
        // is read in which-key like any other: labelled, never machinery.
        .label = label,
        .prompts = true,
    };
}

const cmds = [_]weft.CommandEntry{
    entry("snipe.pair-next", .s, true, .move, "Snipe Forward", "Snipe forward to the next two characters you type."),
    entry("snipe.pair-prev", .s, false, .move, "Snipe Backward", "Snipe backward to the previous two characters you type."),
    entry("snipe.till-pair-next", .x, true, .move, "Snipe Forward Till", "Snipe forward to just before the next two characters you type."),
    entry("snipe.till-pair-prev", .x, false, .move, "Snipe Backward Till", "Snipe backward to just after the previous two characters you type."),
    entry("snipe.char-next", .f, true, .move, "Find Character Forward", "Snipe forward to the next character you type."),
    entry("snipe.char-prev", .f, false, .move, "Find Character Backward", "Snipe backward to the previous character you type."),
    entry("snipe.till-char-next", .t, true, .move, "Till Character Forward", "Snipe forward to just before the next character you type."),
    entry("snipe.till-char-prev", .t, false, .move, "Till Character Backward", "Snipe backward to just after the previous character you type."),
    entry("snipe.operate-pair-next", .s, true, .operate, "To Snipe Forward", "Operate through the next two characters you type."),
    entry("snipe.operate-pair-prev", .s, false, .operate, "To Snipe Backward", "Operate back to the previous two characters you type."),
    entry("snipe.operate-till-pair-next", .x, true, .operate, "Till Snipe Forward", "Operate up to the next two characters you type."),
    entry("snipe.operate-till-pair-prev", .x, false, .operate, "Till Snipe Backward", "Operate back to just after the previous two characters you type."),
    entry("snipe.operate-char-next", .f, true, .operate, "To Character Forward", "Operate through the next character you type."),
    entry("snipe.operate-char-prev", .f, false, .operate, "To Character Backward", "Operate back to the previous character you type."),
    entry("snipe.operate-till-char-next", .t, true, .operate, "Till Character Forward", "Operate up to the next character you type."),
    entry("snipe.operate-till-char-prev", .t, false, .operate, "Till Character Backward", "Operate back to just after the previous character you type."),
    .{ .name = "snipe.read-char", .arity = whole, .call = weft.thunk(readChar), .summary = "Add a typed character to the snipe prompt.", .internal = true },
    .{ .name = "snipe.backspace", .arity = whole, .call = backspace, .summary = "Take the last character back from the snipe prompt.", .internal = true },
    .{ .name = "snipe.return", .arity = whole, .call = returnKey, .summary = "Search for what the snipe prompt holds, or repeat the last snipe.", .internal = true },
    .{ .name = "snipe.cancel", .arity = whole, .call = cancel, .summary = "Close the snipe prompt without moving.", .internal = true },
    .{ .name = "snipe.go", .arity = each, .call = go, .summary = "Perform the requested snipe at each selection.", .internal = true },
    .{ .name = "snipe.repeat", .arity = each, .call = repeat(false, .move), .summary = "Repeat the last snipe.", .label = "Repeat Snipe" },
    .{ .name = "snipe.repeat-reversed", .arity = each, .call = repeat(true, .move), .summary = "Repeat the last snipe in the other direction.", .label = "Repeat Snipe Reversed" },
    .{ .name = "snipe.operate-repeat", .arity = each, .call = repeat(false, .operate), .summary = "Operate over the last snipe, repeated.", .label = "To Last Snipe" },
    .{ .name = "snipe.operate-repeat-reversed", .arity = each, .call = repeat(true, .operate), .summary = "Operate over the last snipe, reversed.", .label = "To Last Snipe Reversed" },
};

comptime {
    weft.plugin(&cmds, .{ .init = init }).exportAll();
}

fn init() void {
    weft.textInput(char_mode, "snipe.read-char");
    weft.bindKey(char_mode, "Escape", "snipe.cancel");
    weft.bindKey(char_mode, "BackSpace", "snipe.backspace");
    weft.bindKey(char_mode, "Return", "snipe.return");
    weft.bindKey(char_mode, "KP_Enter", "snipe.return");
}

/// Open the prompt — unless this key is the one right after a snipe of the
/// same family, which repeats it instead (`s` as `;`, `S` as `,`).
fn start(comptime kind: Kind, comptime forward: bool, comptime use: Use) fn () void {
    return struct {
        fn h() void {
            if (use == .move and armed() and flag("repeat-keys", true)) {
                if (last) |l| {
                    if (l.kind == kind) return weft.run(if (forward) "snipe.repeat" else "snipe.repeat-reversed");
                }
            }
            prompt = .{ .kind = kind, .forward = forward, .use = use, .count = takeCount() };
            rememberOrigin();
            weft.setMode(char_mode);
            showPrompt();
        }
    }.h;
}

fn readChar(typed: []const u8) void {
    if (typed.len == 0) return;
    const n = std.unicode.utf8ByteSequenceLength(typed[0]) catch 1;
    const k = &prompt.keys;
    if (k.n == max_keys) return;
    var key: Key = .{ .len = @intCast(@min(n, typed.len, 4)) };
    @memcpy(key.buf[0..key.len], typed[0..key.len]);
    k.items[k.n] = key;
    k.n += 1;
    if (k.n < prompt.kind.chars()) {
        incremental();
        return showPrompt();
    }
    launch();
}

/// DEL takes the last character back; with one or none typed it leaves.
fn backspace() void {
    if (prompt.keys.n <= 1) return cancel();
    prompt.keys.n -= 1;
    incremental();
    showPrompt();
}

/// RET: with nothing typed, repeat the last snipe (the prompt's count times
/// its own — evil-snipe's `'repeat`); otherwise search for what is typed.
fn returnKey() void {
    if (prompt.keys.n > 0) return launch();
    leavePrompt();
    count_serial = weft.keySerial();
    count_cached = prompt.count;
    weft.run(if (prompt.use == .move) "snipe.repeat" else "snipe.operate-repeat");
}

fn cancel() void {
    if (flag("show-prompt", true)) weft.echo("");
    if (prompt.use == .operate) return weft.exitToResting(); // the operator goes too
    restoreOrigin();
}

/// The keys are in: remember the snipe and make it from every extent.
fn launch() void {
    leavePrompt();
    const n: i32 = @intCast(@min(prompt.count orelse 1, max_count));
    request = .{
        .keys = prompt.keys,
        .kind = prompt.kind,
        .count = if (prompt.forward) n else -n,
        .scope = scopeSetting("scope") orelse .line,
        .spillover = scopeSetting("spillover-scope"),
        .use = prompt.use,
        .repeating = false,
    };
    last = .{ .keys = request.keys, .kind = request.kind, .count = request.count };
    weft.run("snipe.go");
}

/// Out of the prompt. A move goes back where it came from; an operator's
/// consumer owns the mode from here.
fn leavePrompt() void {
    if (flag("show-prompt", true)) weft.echo("");
    if (prompt.use == .move) restoreOrigin();
}

fn go() void {
    seek(request);
}

fn repeat(comptime reverse: bool, comptime use: Use) fn () void {
    return struct {
        fn h() void {
            const l = last orelse {
                weft.echo("snipe: nothing to repeat");
                if (use == .operate) weft.exitToResting();
                return;
            };
            const n: i32 = @intCast(@min(takeCount() orelse 1, max_count));
            seek(.{
                .keys = l.keys,
                .kind = l.kind,
                .count = n *| l.count *| @as(i32, if (reverse) -1 else 1),
                .scope = scopeSetting("repeat-scope") orelse scopeSetting("scope") orelse .line,
                .spillover = scopeSetting("spillover-scope"),
                .use = use,
                .repeating = true,
            });
        }
    }.h;
}

// ── The snipe ────────────────────────────────────────────────────────

const Match = struct { beg: usize, end: usize };

/// A found snipe: the match (its end short of a skip-whitespace tail) and
/// where the snipe lands for it.
const Hit = struct { match: Match, land: usize };

/// Make `req` from the caret: land (or hand the range on), highlight, and
/// arm the repeat keys — or say it found nothing and stay put.
fn seek(req: Request) void {
    const origin = weft.cursor();
    const forward = req.count > 0;
    const n: usize = @abs(req.count);
    // A counted snipe reaches for the spillover scope first (`evil-snipe--bounds`).
    const first_scope = if (n > 1) (req.spillover orelse req.scope) else req.scope;
    var hit = find(req, first_scope, origin);
    if (hit == null) {
        if (req.spillover) |s| hit = find(req, s, origin);
    }

    var landed = origin;
    if (hit) |h| {
        landed = h.land;
        if (req.use == .operate) {
            // Highlight from where the motion lands, before the operator
            // edits: an edit drops the round (the paint is revision-stamped).
            highlightAll(h.land, forward, req.keys.slice(), req.scope, null);
            return operate(if (forward) .{ .start = origin, .end = h.land } else .{ .start = h.land, .end = origin });
        }
        if (!req.repeating) weft.jumpPush();
        weft.jump(h.land);
        armed_serial = weft.keySerial();
    } else {
        if (req.repeating and req.use == .move) armed_serial = weft.keySerial();
        notFound(req.keys.slice());
        if (req.use == .operate) weft.exitToResting();
    }
    highlightAll(landed, forward, req.keys.slice(), req.scope, if (hit) |h| h.match else null);
}

/// Hand `span` to the configured operator; with none, just move.
fn operate(span: weft.Range) void {
    const consumer = weft.config("operator");
    if (consumer.len > 0) {
        var name_buf: [64]u8 = undefined;
        const name = name_buf[0..@min(consumer.len, name_buf.len)];
        @memcpy(name, consumer[0..name.len]);
        if (weft.anchorRange(span)) |h| return weft.runRangeArg(name, h);
    }
    weft.jump(if (span.start == weft.cursor()) span.end else span.start);
    weft.exitToResting();
}

/// Where `req` lands from `point` searching `scope`, or null. The start is
/// evil-snipe's: one character past the caret forward (two for an exclusive
/// snipe, so a repeated `t` moves), the caret itself backward (one before it
/// for an exclusive one); a match must lie wholly inside the scope.
fn find(req: Request, scope: Scope, point: usize) ?Hit {
    const forward = req.count > 0;
    const n: usize = @abs(req.count);
    const inclusive = req.kind.inclusive();
    const len = weft.byteLen();
    var from = point;
    if (forward) {
        if (from >= len) return null;
        from = weft.step(from, .fwd, .char);
        if (!inclusive) {
            if (from >= len) return null;
            from = weft.step(from, .fwd, .char);
        }
    } else if (!inclusive) {
        if (from == 0) return null;
        from = weft.step(from, .back, .char);
    }
    const b = bounds(from, forward, scope);
    const lo = if (forward) from else b.start;
    const hi = if (forward) b.end else from;
    if (hi <= lo) return null;

    var pat = compile(req.keys.slice());
    // Skip-leading-whitespace: sniping for a blank FROM a blank matches the
    // blank just before the next non-blank, so a run is one stop, not many.
    const skip = flag("skip-leading-whitespace", true) and req.keys.n > 0 and
        req.keys.items[0].blank() and isBlankAt(from);
    if (skip) pat.push(.not_blank);

    var text = Text.read(lo, hi) orelse return null;
    defer text.deinit();
    const m = (if (forward) text.searchForward(&pat, from, hi, n) else text.searchBackward(&pat, from, lo, n)) orelse return null;
    const end = if (skip) weft.step(m.end, .back, .char) else m.end;
    // Backward: on the match, or just after it. Forward, the caret lands on
    // the match or just before it; an operator's (exclusive) range ends past
    // the match, or at it.
    const land = if (!forward)
        (if (inclusive) m.beg else end)
    else switch (req.use) {
        .operate => if (inclusive) end else m.beg,
        .move => if (inclusive) m.beg else weft.step(m.beg, .back, .char),
    };
    return .{ .match = .{ .beg = m.beg, .end = end }, .land = land };
}

fn notFound(keys: []const Key) void {
    var buf: [96]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    w.writeAll("snipe: can't find ") catch {};
    for (keys) |*k| {
        const shown = if (k.len == 1 and k.buf[0] == ' ') "<SPC>" else if (k.len == 1 and k.buf[0] == '\t') "<TAB>" else k.bytes();
        w.writeAll(shown) catch {};
    }
    weft.echo(w.buffered());
}

// ── Scope ────────────────────────────────────────────────────────────

/// `[lo, hi)` a scope covers from `point` (`evil-snipe--bounds`). The
/// forward forms start one character past the point; `visible` is what the
/// pane showed last frame, or the whole entry before there was one.
fn bounds(point: usize, forward: bool, scope: Scope) weft.Range {
    const len = weft.byteLen();
    const next = if (point >= len) len else weft.step(point, .fwd, .char);
    const shown = weft.viewRange() orelse weft.Range{ .start = 0, .end = len };
    const r: weft.Range = switch (scope) {
        .line => if (forward) .{ .start = next, .end = weft.lineAt(point).end } else .{ .start = weft.lineAt(point).start, .end = point },
        .visible => if (forward) .{ .start = next, .end = shown.end } else .{ .start = shown.start, .end = point },
        .buffer => if (forward) .{ .start = next, .end = len } else .{ .start = 0, .end = point },
        .whole_line => weft.lineAt(point),
        .whole_visible => shown,
        .whole_buffer => .{ .start = 0, .end = len },
    };
    return .{ .start = @min(r.start, r.end), .end = r.end };
}

fn isBlankAt(off: usize) bool {
    const s = weft.slice(off, off + 1);
    return s.len == 1 and (s[0] == ' ' or s[0] == '\t');
}

// ── Patterns ─────────────────────────────────────────────────────────

/// One position of a snipe: any of a set of characters (a typed key, or
/// the set `aliases` maps it to), or any one character but a blank.
const Atom = union(enum) {
    chars: []const u8,
    not_blank,
};

const Pattern = struct {
    atoms: [max_keys + 1]Atom = undefined,
    n: usize = 0,
    /// Compare ASCII letters without case (smart case, nothing capital typed).
    fold: bool = false,
    store: [max_keys][64]u8 = undefined,

    fn push(p: *Pattern, a: Atom) void {
        p.atoms[p.n] = a;
        p.n += 1;
    }

    /// Where a match starting at `i` ends, or null; it may not reach past
    /// `limit`.
    fn matchAt(p: *const Pattern, text: []const u8, i: usize, limit: usize) ?usize {
        var at = i;
        for (p.atoms[0..p.n]) |a| switch (a) {
            .chars => |alts| {
                var j: usize = 0;
                const width = while (j < alts.len) {
                    const w = std.unicode.utf8ByteSequenceLength(alts[j]) catch 1;
                    const alt = alts[j..@min(j + w, alts.len)];
                    j += w;
                    if (at + alt.len <= limit and same(text[at..][0..alt.len], alt, p.fold)) break alt.len;
                } else return null;
                at += width;
            },
            .not_blank => {
                if (at >= limit or text[at] == ' ' or text[at] == '\t') return null;
                at += @min(std.unicode.utf8ByteSequenceLength(text[at]) catch 1, limit - at);
            },
        };
        return if (at <= limit) at else null;
    }
};

fn same(a: []const u8, b: []const u8, fold: bool) bool {
    return if (fold) std.ascii.eqlIgnoreCase(a, b) else std.mem.eql(u8, a, b);
}

/// The pattern for `keys`: each key, or the set an alias maps it to; smart
/// case folds when nothing typed (or aliased) is a capital.
fn compile(keys: []const Key) Pattern {
    var p: Pattern = .{};
    var capital = false;
    for (keys, 0..) |*k, i| {
        const set = aliasFor(k.bytes(), &p.store[i]) orelse blk: {
            @memcpy(p.store[i][0..k.len], k.bytes());
            break :blk p.store[i][0..k.len];
        };
        for (set) |c| if (std.ascii.isUpper(c)) {
            capital = true;
        };
        p.push(.{ .chars = set });
    }
    p.fold = flag("smart-case", false) and !capital;
    return p;
}

/// The set `aliases` maps `key` to — a bracketed class (`[[{(]`) or a plain
/// run of characters — copied into `out`, or null.
fn aliasFor(key: []const u8, out: *[64]u8) ?[]const u8 {
    var it = weft.configList("aliases") orelse return null;
    while (it.next()) |from| {
        const to = it.next() orelse return null;
        if (!std.mem.eql(u8, from, key)) continue;
        const set = if (to.len >= 2 and to[0] == '[' and to[to.len - 1] == ']') to[1 .. to.len - 1] else to;
        if (set.len == 0) return null;
        const n = @min(set.len, out.len);
        @memcpy(out[0..n], set[0..n]);
        return out[0..n];
    }
    return null;
}

/// `[base, base + bytes.len)` of the focused entry, copied out of the read
/// scratch a slice at a time (a scope can be the whole buffer).
const Text = struct {
    base: usize,
    bytes: []u8,

    fn read(lo: usize, hi: usize) ?Text {
        const bytes = weft.allocator.alloc(u8, hi - lo) catch return null;
        var at: usize = 0;
        while (at < bytes.len) {
            const got = weft.slice(lo + at, hi);
            if (got.len == 0) break;
            @memcpy(bytes[at..][0..got.len], got);
            at += got.len;
        }
        return .{ .base = lo, .bytes = bytes[0..at] };
    }

    fn deinit(t: *Text) void {
        weft.allocator.free(t.bytes);
    }

    fn cont(t: *const Text, off: usize) bool {
        return t.bytes[off - t.base] & 0xC0 == 0x80;
    }

    /// The `n`th match at or after `from`, each search starting where the
    /// last match ended (`re-search-forward` with a count).
    fn searchForward(t: *const Text, p: *const Pattern, from: usize, bound: usize, n: usize) ?Match {
        const limit = @min(bound, t.base + t.bytes.len) - t.base;
        var pos = from;
        var m: ?Match = null;
        for (0..n) |_| {
            var i = pos;
            m = while (i < t.base + limit) : (i += 1) {
                if (t.cont(i)) continue;
                if (p.matchAt(t.bytes, i - t.base, limit)) |e| break Match{ .beg = i, .end = t.base + e };
            } else return null;
            pos = m.?.end;
        }
        return m;
    }

    /// The `n`th match ending at or before `from`, nearest first, each
    /// search ending where the last match began (`re-search-backward`).
    fn searchBackward(t: *const Text, p: *const Pattern, from: usize, bound: usize, n: usize) ?Match {
        var pos = @min(from, t.base + t.bytes.len);
        var m: ?Match = null;
        for (0..n) |_| {
            var i = pos;
            m = while (i > bound) {
                i -= 1;
                if (t.cont(i)) continue;
                if (p.matchAt(t.bytes, i - t.base, pos - t.base)) |e| break Match{ .beg = i, .end = t.base + e };
            } else return null;
            pos = m.?.beg;
        }
        return m;
    }
};

// ── Highlights ───────────────────────────────────────────────────────

/// Every match of `keys` in `scope` from `point` (`evil-snipe--highlight-all`),
/// `first` — the one landed on — in its own role. A `buffer` scope highlights
/// only what is visible. The round lasts until the next key.
fn highlightAll(point: usize, forward: bool, keys: []const Key, scope: Scope, first: ?Match) void {
    if (!flag("highlight", true)) return;
    paint(point, forward, keys, scope, first);
}

/// The same, while the keys are still being typed.
fn incremental() void {
    if (!flag("incremental-highlight", true)) return;
    paint(weft.cursor(), prompt.forward, prompt.keys.slice(), scopeSetting("scope") orelse .line, null);
}

const max_spans = 1024;

fn paint(point: usize, forward: bool, keys: []const Key, scope: Scope, first: ?Match) void {
    const anno = paintLayer() orelse return;
    if (first) |f| anno.span(f.beg, f.end, .location, .range, "");
    if (keys.len == 0) return;
    const shown: Scope = switch (scope) {
        .buffer => .visible,
        .whole_buffer => .whole_visible,
        else => scope,
    };
    const b = bounds(point, forward, shown);
    if (b.end <= b.start) return;
    const pat = compile(keys);
    // A run of blanks shows its last one only, as the snipe itself stops.
    const skip = flag("skip-leading-whitespace", true) and keys[0].blank();
    var text = Text.read(b.start, b.end) orelse return;
    defer text.deinit();
    var pos = b.start;
    var spans: usize = 0;
    while (pos < b.end and spans < max_spans) {
        const m = text.searchForward(&pat, pos, b.end, 1) orelse break;
        pos = m.end;
        if (skip and blankRun(&text, m.end) >= 2) {
            const back = pos + blankRun(&text, m.end) - (m.end - m.beg);
            pos = if (back > m.beg) back else m.end;
            continue;
        }
        if (first) |f| if (f.beg == m.beg) continue;
        anno.span(m.beg, m.end, .emphasis, .range, "");
        spans += 1;
    }
}

fn blankRun(t: *const Text, from: usize) usize {
    var n: usize = 0;
    while (from + n < t.base + t.bytes.len) : (n += 1) {
        const c = t.bytes[from + n - t.base];
        if (c != ' ' and c != '\t') break;
    }
    return n;
}

/// The focused entry's highlight layer, its round opened once per key: every
/// extent a mapping visits adds to the same round, and the next key ends it.
fn paintLayer() ?weft.Annotations {
    const id = activeEntry() orelse return null;
    if (layer_entry != id) {
        if (layer) |l| l.close();
        layer = weft.Annotations.open(id, layer_name);
        layer_entry = id;
        paint_serial = null;
    }
    const anno = layer orelse return null;
    const serial = weft.keySerial();
    if (paint_serial != serial) {
        if (!anno.beginUntilKey()) {
            anno.close();
            layer = null;
            layer_entry = null;
            return null;
        }
        paint_serial = serial;
    }
    return anno;
}

/// The focused entry's compact id (the handle an annotation layer opens on).
fn activeEntry() ?u32 {
    var i: usize = 0;
    while (i < weft.bufferCount()) : (i += 1) {
        if (!weft.bufferActive(i)) continue;
        const id = weft.bufferId(i) orelse return null;
        return @intCast(id);
    }
    return null;
}

// ── Plumbing ─────────────────────────────────────────────────────────

/// Is this key the one right after a snipe finished?
fn armed() bool {
    const a = armed_serial orelse return false;
    return a +% 1 == weft.keySerial();
}

/// The count typed before this key, from the command `count` names, read
/// once per key so every extent of a mapping sees the same one.
fn takeCount() ?u32 {
    const serial = weft.keySerial();
    if (count_serial == serial) return count_cached;
    count_serial = serial;
    count_cached = null;
    var name_buf: [64]u8 = undefined;
    const src = weft.config("count");
    if (src.len == 0 or src.len > name_buf.len) return null;
    @memcpy(name_buf[0..src.len], src);
    const typed = weft.callString(name_buf[0..src.len]) orelse return null;
    const n = std.fmt.parseInt(u32, typed, 10) catch return null;
    count_cached = if (n == 0) null else n;
    return count_cached;
}

fn showPrompt() void {
    if (!flag("show-prompt", true)) return;
    var buf: [32]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    w.print("{d}>", .{prompt.kind.chars() - prompt.keys.n}) catch {};
    for (prompt.keys.slice()) |*k| w.writeAll(k.bytes()) catch {};
    weft.echo(w.buffered());
}

fn rememberOrigin() void {
    const m = weft.contextGet("mode") orelse "";
    origin_len = if (m.len <= origin_buf.len and !std.mem.eql(u8, m, char_mode)) m.len else 0;
    @memcpy(origin_buf[0..origin_len], m[0..origin_len]);
}

fn restoreOrigin() void {
    if (origin_len > 0) weft.setMode(origin_buf[0..origin_len]) else weft.exitToResting();
}
