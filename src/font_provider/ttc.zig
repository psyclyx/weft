//! Which face of a font collection (`.ttc`/`.otc`) carries a PostScript name.
//!
//! A platform resolver names a face, not its position: CoreText hands back a
//! file and a PostScript name, while the text layer needs the face's index in
//! that file. macOS keeps many of its families in collections (Menlo,
//! Helvetica, Avenir), so the index is read from the file itself: the
//! collection header lists each face's table directory, and each face's
//! `name` table (name ID 6) holds its PostScript name.
//!
//! Pure byte parsing; anything malformed is simply "not found".

const std = @import("std");

/// The index of the face named `postscript` in `bytes`; 0 for a file that is
/// a single face; null when a collection holds no face by that name.
pub fn faceIndex(bytes: []const u8, postscript: []const u8) ?u32 {
    if (bytes.len < 12 or !std.mem.eql(u8, bytes[0..4], "ttcf")) return 0;
    const count = be(u32, bytes, 8) orelse return null;
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const offset = be(u32, bytes, 12 + @as(usize, i) * 4) orelse return null;
        if (namesFace(bytes, offset, postscript)) return i;
    }
    return null;
}

/// Does the face whose table directory starts at `dir` have PostScript name
/// `postscript`?
fn namesFace(bytes: []const u8, dir: usize, postscript: []const u8) bool {
    const tables = be(u16, bytes, dir + 4) orelse return false;
    var t: usize = 0;
    while (t < tables) : (t += 1) {
        const record = dir + 12 + t * 16;
        if (record + 16 > bytes.len) return false;
        if (!std.mem.eql(u8, bytes[record..][0..4], "name")) continue;
        const offset = be(u32, bytes, record + 8) orelse return false;
        return nameTableHas(bytes, offset, postscript);
    }
    return false;
}

fn nameTableHas(bytes: []const u8, table: usize, postscript: []const u8) bool {
    const count = be(u16, bytes, table + 2) orelse return false;
    const strings = table + (be(u16, bytes, table + 4) orelse return false);
    var r: usize = 0;
    while (r < count) : (r += 1) {
        const rec = table + 6 + r * 12;
        const platform = be(u16, bytes, rec) orelse return false;
        const name_id = be(u16, bytes, rec + 6) orelse return false;
        if (name_id != 6) continue;
        const len = be(u16, bytes, rec + 8) orelse return false;
        const at = strings + (be(u16, bytes, rec + 10) orelse return false);
        if (at + len > bytes.len) continue;
        const raw = bytes[at..][0..len];
        const matches = switch (platform) {
            // Windows and Unicode: UTF-16BE. PostScript names are ASCII.
            0, 3 => utf16AsciiEql(raw, postscript),
            // Macintosh: one byte per character.
            1 => std.mem.eql(u8, raw, postscript),
            else => false,
        };
        if (matches) return true;
    }
    return false;
}

fn utf16AsciiEql(raw: []const u8, ascii: []const u8) bool {
    if (raw.len != ascii.len * 2) return false;
    for (ascii, 0..) |ch, i| {
        if (raw[2 * i] != 0 or raw[2 * i + 1] != ch) return false;
    }
    return true;
}

fn be(comptime T: type, bytes: []const u8, at: usize) ?T {
    if (at + @sizeOf(T) > bytes.len) return null;
    return std.mem.readInt(T, bytes[at..][0..@sizeOf(T)], .big);
}

// ── Tests ───────────────────────────────────────────────────────────

/// A collection of faces, each nothing but a `name` table holding one
/// PostScript name — enough structure for `faceIndex` to walk.
fn testCollection(comptime names: []const []const u8, comptime mac: bool) []const u8 {
    comptime {
        var faces: []const u8 = &.{};
        var offsets: []const u8 = &.{};
        const header_len = 12 + 4 * names.len;
        for (names) |name| {
            const dir_at = header_len + faces.len;
            const table_at = dir_at + 12 + 16;
            const encoded: []const u8 = if (mac) name else blk: {
                var wide: []const u8 = &.{};
                for (name) |ch| wide = wide ++ [_]u8{ 0, ch };
                break :blk wide;
            };
            const platform: u16 = if (mac) 1 else 3;
            const name_table = u16be(0) ++ u16be(1) ++ u16be(6 + 12) ++
                u16be(platform) ++ u16be(if (mac) 0 else 1) ++ u16be(if (mac) 0 else 0x409) ++
                u16be(6) ++ u16be(encoded.len) ++ u16be(0) ++ encoded;
            const dir = u32be(0x00010000) ++ u16be(1) ++ u16be(16) ++ u16be(0) ++ u16be(0) ++
                "name" ++ u32be(0) ++ u32be(table_at) ++ u32be(name_table.len);
            offsets = offsets ++ u32be(dir_at);
            faces = faces ++ dir ++ name_table;
        }
        const out = "ttcf" ++ u32be(0x00010000) ++ u32be(names.len) ++ offsets ++ faces;
        const final = out[0..out.len].*;
        return &final;
    }
}

fn u16be(v: u16) [2]u8 {
    return .{ @intCast(v >> 8), @truncate(v) };
}

fn u32be(v: u32) [4]u8 {
    return .{ @intCast(v >> 24), @truncate(v >> 16), @truncate(v >> 8), @truncate(v) };
}

test "ttc: a collection's faces are found by PostScript name" {
    const ttc = comptime testCollection(&.{ "Menlo-Regular", "Menlo-Bold", "Menlo-Italic" }, false);
    try std.testing.expectEqual(@as(?u32, 0), faceIndex(ttc, "Menlo-Regular"));
    try std.testing.expectEqual(@as(?u32, 1), faceIndex(ttc, "Menlo-Bold"));
    try std.testing.expectEqual(@as(?u32, 2), faceIndex(ttc, "Menlo-Italic"));
    try std.testing.expectEqual(@as(?u32, null), faceIndex(ttc, "Menlo-BoldItalic"));

    const mac = comptime testCollection(&.{ "Avenir-Book", "Avenir-Heavy" }, true);
    try std.testing.expectEqual(@as(?u32, 1), faceIndex(mac, "Avenir-Heavy"));
}

test "ttc: a single face is index 0, and garbage is not a collection's face" {
    try std.testing.expectEqual(@as(?u32, 0), faceIndex("\x00\x01\x00\x00 plain sfnt", "Anything"));
    try std.testing.expectEqual(@as(?u32, null), faceIndex("ttcf\x00\x01\x00\x00\x00\x00\x00\x09", "X"));
}
