//! Byte-oriented field navigation, independent of input grammar and provider.
const std = @import("std");
pub const Movement = enum { word_previous, word_next, word_end, WORD_previous, WORD_next, WORD_end, line_start, line_end, first_non_blank };
const Class = enum { space, word, punct };
fn class(byte: u8, big: bool) Class {
    if (std.ascii.isWhitespace(byte)) return .space;
    if (big or std.ascii.isAlphanumeric(byte) or byte == '_' or byte >= 0x80) return .word;
    return .punct;
}
pub fn destination(bytes: []const u8, position: usize, movement: Movement) usize {
    var i = @min(position, bytes.len);
    const big = movement == .WORD_previous or movement == .WORD_next or movement == .WORD_end;
    switch (movement) {
        .line_start, .first_non_blank => {
            while (i > 0 and bytes[i - 1] != '\n') i -= 1;
            if (movement == .first_non_blank) while (i < bytes.len and (bytes[i] == ' ' or bytes[i] == '\t')) {
                i += 1;
            };
        },
        .line_end => while (i < bytes.len and bytes[i] != '\n') {
            i += 1;
        },
        .word_previous, .WORD_previous => {
            while (i > 0 and class(bytes[i - 1], big) == .space) i -= 1;
            if (i > 0) {
                const kind = class(bytes[i - 1], big);
                while (i > 0 and class(bytes[i - 1], big) == kind) i -= 1;
            }
        },
        .word_next, .WORD_next => {
            if (i < bytes.len) {
                const kind = class(bytes[i], big);
                while (i < bytes.len and class(bytes[i], big) == kind) i += 1;
            }
            while (i < bytes.len and class(bytes[i], big) == .space) i += 1;
        },
        .word_end, .WORD_end => {
            if (i < bytes.len) {
                const size = std.unicode.utf8ByteSequenceLength(bytes[i]) catch 1;
                i += if (i + size <= bytes.len and std.unicode.utf8ValidateSlice(bytes[i .. i + size])) size else 1;
            }
            while (i < bytes.len and class(bytes[i], big) == .space) i += 1;
            if (i < bytes.len) {
                const kind = class(bytes[i], big);
                while (i + 1 < bytes.len and class(bytes[i + 1], big) == kind) i += 1;
            }
            if (i < bytes.len) {
                var start = i;
                while (start > 0 and bytes[start] & 0xc0 == 0x80) start -= 1;
                if (std.unicode.utf8ValidateSlice(bytes[start .. i + 1])) i = start;
            }
        },
    }
    return @min(i, bytes.len);
}
test "field word boundaries distinguish punctuation and preserve UTF-8" {
    const t = std.testing;
    try t.expectEqual(@as(usize, 5), destination("some-name.txt", 9, .word_previous));
    try t.expectEqual(@as(usize, 0), destination("some-name.txt", 9, .WORD_previous));
    try t.expectEqual(@as(usize, 4), destination("some-name.txt", 0, .word_next));
    try t.expectEqual(@as(usize, 13), destination("some-name.txt", 0, .WORD_next));
    try t.expectEqual(@as(usize, 1), destination("aé x", 0, .word_end));
    try t.expectEqual(@as(usize, 1), destination("a\x80 x", 0, .word_end));
    try t.expectEqual(@as(usize, 2), destination("\xe2 x", 0, .word_end));
}
