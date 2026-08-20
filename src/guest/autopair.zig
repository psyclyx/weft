//! autopair — a `.wasm` plugin with NO core privilege beyond the edit door
//! (perms `{}`, grant_max edit). Each command inserts a matched delimiter pair
//! at the cursor and leaves the cursor BETWEEN the two bytes: insert the two
//! byte runs as an empty-range edit at the cursor, then jump forward past the
//! open. The edit crosses the gated door, authored as this plugin's peer, so a
//! `view` doc refuses it with zero permission logic here. Meant for insert mode.
//!
//! The pair set is DATA, not hardcode: it ships defaults (the four below) but a
//! config `weft.set("autopair", "pairs", ["name\topen\tclose", …])` overrides
//! the whole set — so a lisp config can make `'` a quote-pair, a language its
//! own delimiters, etc., without touching this plugin (Carve 2).

const std = @import("std");
const weft = @import("weft.zig");

const Pair = struct { name: []const u8, open: []const u8, close: []const u8 };

/// Shipped defaults, used when config sets no `pairs`.
const defaults = [_]Pair{
    .{ .name = "pair-paren", .open = "(", .close = ")" },
    .{ .name = "pair-brace", .open = "{", .close = "}" },
    .{ .name = "pair-bracket", .open = "[", .close = "]" },
    .{ .name = "pair-quote", .open = "\"", .close = "\"" },
    .{ .name = "pair-quote-single", .open = "'", .close = "'" },
};

/// Extensions where `'` (a quote pair — open==close) is a QUOTE, not an
/// auto-pair: the lisps. This is the answer to "how do we handle `'`" — a quote
/// pair auto-closes everywhere EXCEPT these languages, where it inserts a single
/// character. Overridable via config `weft.set("autopair","quote-langs",[…])`.
const default_quote_langs = [_][]const u8{ ".el", ".lisp", ".cl", ".clj", ".cljs", ".cljc", ".scm", ".rkt", ".fnl" };
var quote_langs: [64][]const u8 = undefined;
var quote_langs_n: usize = 0;
/// The active buffer's extension (tracked on focus, for the quote-lang check).
var cur_ext: [24]u8 = undefined;
var cur_ext_len: usize = 0;

fn loadQuoteLangs() void {
    if (quote_langs_n != 0) return;
    if (weft.configList("quote-langs")) |list| {
        var it = list;
        while (it.next()) |rec| {
            if (quote_langs_n >= quote_langs.len) break;
            quote_langs[quote_langs_n] = dup(rec); // dup shares the pair arena
            quote_langs_n += 1;
        }
    }
    if (quote_langs_n == 0) for (default_quote_langs) |e| {
        quote_langs[quote_langs_n] = e;
        quote_langs_n += 1;
    };
}

fn inQuoteLang() bool {
    if (cur_ext_len == 0) return false;
    for (quote_langs[0..quote_langs_n]) |e| if (std.mem.eql(u8, e, cur_ext[0..cur_ext_len])) return true;
    return false;
}

/// The resolved pair set (defaults ⊕ config), parsed once. `on_command`'s id is
/// this array's index, matching declare/register order.
var pairs: [64]Pair = undefined;
var pairs_len: usize = 0;
/// Backing storage for config-provided name/open/close byte runs.
var arena: [4096]u8 = undefined;
var arena_used: usize = 0;

fn dup(s: []const u8) []const u8 {
    const n = @min(s.len, arena.len - arena_used);
    @memcpy(arena[arena_used..][0..n], s[0..n]);
    defer arena_used += n;
    return arena[arena_used..][0..n];
}

/// Parse the config `pairs` list (records "name\topen\tclose") over the shipped
/// defaults; idempotent (both describe and init call it). Falls back to
/// `defaults` when config sets nothing or every record is malformed.
fn loadPairs() void {
    if (pairs_len != 0) return;
    if (weft.configList("pairs")) |list| {
        var it = list;
        while (it.next()) |rec| {
            if (pairs_len >= pairs.len) break;
            const t1 = std.mem.indexOfScalar(u8, rec, '\t') orelse continue;
            const rest = rec[t1 + 1 ..];
            const t2 = std.mem.indexOfScalar(u8, rest, '\t') orelse continue;
            const name = rec[0..t1];
            const open = rest[0..t2];
            const close = rest[t2 + 1 ..];
            if (name.len == 0 or open.len == 0 or close.len == 0) continue;
            pairs[pairs_len] = .{ .name = dup(name), .open = dup(open), .close = dup(close) };
            pairs_len += 1;
        }
    }
    if (pairs_len == 0) for (defaults) |d| {
        pairs[pairs_len] = d;
        pairs_len += 1;
    };
}

/// Type-over commands for the closing delimiters: typing `)`/`}`/`]` when that
/// exact char is already under the cursor (the pair auto-inserted it) SKIPS over
/// it instead of inserting a duplicate. Without this, typing balanced code
/// `f(x)` produces `f(x))` — every opener orphans its auto-closer.
const Closer = struct { name: []const u8, ch: u8 };
const closers = [_]Closer{
    .{ .name = "pair-close-paren", .ch = ')' },
    .{ .name = "pair-close-brace", .ch = '}' },
    .{ .name = "pair-close-bracket", .ch = ']' },
};

export fn describe() void {
    loadPairs();
    loadQuoteLangs();
    for (pairs[0..pairs_len]) |pr| weft.declareCommand(pr.name);
    for (closers) |c| weft.declareCommand(c.name);
}
export fn init() void {
    loadPairs();
    loadQuoteLangs();
    for (pairs[0..pairs_len]) |pr| _ = weft.register(pr.name);
    for (closers) |c| _ = weft.register(c.name);
}
export fn on_command(id: u32) void {
    if (id < pairs_len) {
        insertPair(pairs[id]);
    } else if (id - pairs_len < closers.len) {
        skipClose(closers[id - pairs_len].ch);
    }
}

/// Typing a closing delimiter: if it's already the next byte (an auto-inserted
/// closer), step over it; otherwise insert it literally.
fn skipClose(ch: u8) void {
    const off = weft.cursor();
    const nxt = weft.slice(off, off + 1);
    if (nxt.len == 1 and nxt[0] == ch) {
        weft.jump(off + 1);
    } else {
        const one = [_]u8{ch};
        weft.edit(.{ .start = off, .end = off }, &one);
        weft.jump(off + 1);
    }
}
/// Track the focused buffer's extension, for the quote-language check.
export fn on_activate() void {
    const path = weft.activatePath();
    if (std.mem.lastIndexOfScalar(u8, path, '.')) |i| {
        cur_ext_len = @min(path.len - i, cur_ext.len);
        @memcpy(cur_ext[0..cur_ext_len], path[i..][0..cur_ext_len]);
    } else cur_ext_len = 0;
}

/// Insert the delimiter pair at the cursor and place the cursor after the open
/// run. A quote pair (open==close) in a lisp is a QUOTE, not a pair — insert the
/// open char alone and leave the cursor after it (no auto-close to delete).
fn insertPair(pr: Pair) void {
    const off = weft.cursor();
    // Quote type-over: a quote pair (open==close) typed over its own auto-inserted
    // close quote steps past it, so `"x"` doesn't become `"x""`.
    if (std.mem.eql(u8, pr.open, pr.close)) {
        const nxt = weft.slice(off, off + pr.close.len);
        if (std.mem.eql(u8, nxt, pr.close)) {
            weft.jump(off + pr.close.len);
            return;
        }
    }
    if (std.mem.eql(u8, pr.open, pr.close) and inQuoteLang()) {
        weft.edit(.{ .start = off, .end = off }, pr.open);
        weft.jump(off + pr.open.len);
        return;
    }
    var buf: [32]u8 = undefined;
    const n = pr.open.len + pr.close.len;
    if (n > buf.len) return;
    @memcpy(buf[0..pr.open.len], pr.open);
    @memcpy(buf[pr.open.len..][0..pr.close.len], pr.close);
    weft.edit(.{ .start = off, .end = off }, buf[0..n]);
    weft.jump(off + pr.open.len);
}
