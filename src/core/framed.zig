//! The framed list both membranes carry a string list over: uvarint(count)
//! then count×(uvarint(len) ++ bytes). The config shim (`weft.bind`'s
//! fallback list, `weft.set`'s values) and the guest ABI (`weft.bindKeys`)
//! encode it; ONE decoder reads it, so a second copy cannot drift from them.

const std = @import("std");

/// Walks a framed blob. `next` yields null on a short or malformed buffer, so
/// a truncated blob reads as fewer records, never as garbage bytes.
pub const Records = struct {
    cur: []const u8,
    left: u64,

    pub fn init(blob: []const u8) ?Records {
        var cur = blob;
        const count = uvarint(&cur) orelse return null;
        return .{ .cur = cur, .left = count };
    }

    pub fn next(self: *Records) ?[]const u8 {
        if (self.left == 0) return null;
        const n = uvarint(&self.cur) orelse return null;
        if (n > self.cur.len) return null;
        const rec = self.cur[0..@intCast(n)];
        self.cur = self.cur[@intCast(n)..];
        self.left -= 1;
        return rec;
    }
};

/// The first record of a framed blob — a single-valued list's only value.
pub fn first(blob: []const u8) ?[]const u8 {
    var it = Records.init(blob) orelse return null;
    return it.next();
}

fn uvarint(cur: *[]const u8) ?u64 {
    var shift: u6 = 0;
    var v: u64 = 0;
    while (cur.len > 0) {
        const b = cur.*[0];
        cur.* = cur.*[1..];
        v |= @as(u64, b & 0x7f) << shift;
        if (b & 0x80 == 0) return v;
        if (shift >= 57) return null;
        shift += 7;
    }
    return null;
}

const t = std.testing;

test "framed: a two-record blob reads back whole; a truncated one stops short" {
    const blob = [_]u8{ 2, 3, 'a', 'b', 'c', 1, 'd' };
    var it = Records.init(&blob).?;
    try t.expectEqualStrings("abc", it.next().?);
    try t.expectEqualStrings("d", it.next().?);
    try t.expectEqual(@as(?[]const u8, null), it.next());

    var short = Records.init(blob[0..4]).?;
    try t.expectEqual(@as(?[]const u8, null), short.next());
    try t.expectEqualStrings("abc", first(&blob).?);
}
