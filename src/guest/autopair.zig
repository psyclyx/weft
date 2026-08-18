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
};

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

export fn describe() void {
    loadPairs();
    for (pairs[0..pairs_len]) |pr| weft.declareCommand(pr.name);
}
export fn init() void {
    loadPairs();
    for (pairs[0..pairs_len]) |pr| _ = weft.register(pr.name);
}
export fn on_command(id: u32) void {
    if (id < pairs_len) insertPair(pairs[id]);
}

/// Insert the delimiter pair at the cursor and place the cursor after the open
/// run (between the two runs).
fn insertPair(pr: Pair) void {
    const off = weft.cursor();
    var buf: [32]u8 = undefined;
    const n = pr.open.len + pr.close.len;
    if (n > buf.len) return;
    @memcpy(buf[0..pr.open.len], pr.open);
    @memcpy(buf[pr.open.len..][0..pr.close.len], pr.close);
    weft.edit(.{ .start = off, .end = off }, buf[0..n]);
    weft.jump(off + pr.open.len);
}
