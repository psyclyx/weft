//! The xkb keysym vocabulary, for a platform that has no xkb.
//!
//! `KeyEvent.keysym` is an xkb keysym (root.zig, leak #3) and every binding is
//! written in xkb's keysym NAMES (`Return`, `colon`, `F5`), so a platform that
//! is not xkb (Cocoa) must hand dispatch the same numbers and names xkb would
//! for the same key. This is that subset — what a keyboard can actually
//! produce:
//!
//! - Latin-1, where a keysym IS the code point (`a` = 0x61, `eacute` = 0xe9);
//! - the function, editing, navigation and keypad keys (0xff00 page);
//! - every other character as `0x01000000 + code point`, named `U<hex>` —
//!   xkb's own encoding for Unicode beyond Latin-1.
//!
//! The names are xkb's canonical ones (`xkb_keysym_get_name`), and the test at
//! the bottom checks every entry against libxkbcommon itself on Linux, so the
//! Cocoa platform and the Wayland one cannot disagree about what a key is
//! called.

const std = @import("std");
const builtin = @import("builtin");

pub const BackSpace: u32 = 0xff08;
pub const Tab: u32 = 0xff09;
pub const Clear: u32 = 0xff0b;
pub const Return: u32 = 0xff0d;
pub const Escape: u32 = 0xff1b;
pub const Home: u32 = 0xff50;
pub const Left: u32 = 0xff51;
pub const Up: u32 = 0xff52;
pub const Right: u32 = 0xff53;
pub const Down: u32 = 0xff54;
pub const Prior: u32 = 0xff55; // Page Up
pub const Next: u32 = 0xff56; // Page Down
pub const End: u32 = 0xff57;
pub const Insert: u32 = 0xff63;
pub const Menu: u32 = 0xff67;
pub const Help: u32 = 0xff6a;
pub const KP_Enter: u32 = 0xff8d;
pub const KP_Multiply: u32 = 0xffaa;
pub const KP_Add: u32 = 0xffab;
pub const KP_Subtract: u32 = 0xffad;
pub const KP_Decimal: u32 = 0xffae;
pub const KP_Divide: u32 = 0xffaf;
pub const KP_0: u32 = 0xffb0; // KP_0 .. KP_9 are consecutive
pub const KP_Equal: u32 = 0xffbd;
pub const F1: u32 = 0xffbe; // F1 .. F35 are consecutive
pub const Delete: u32 = 0xffff;
/// Shift+Tab: xkb's standard layouts put this on Tab's shifted level, so it
/// arrives with Shift already consumed.
pub const ISO_Left_Tab: u32 = 0xfe20;

/// The keysym for a character a key produced: its code point in Latin-1,
/// xkb's Unicode encoding beyond it. Control characters have no character
/// keysym (the keys that produce them are named by `special`).
pub fn fromCodepoint(cp: u21) ?u32 {
    if (cp < 0x20 or cp == 0x7f or (cp >= 0x80 and cp < 0xa0)) return null;
    if (cp < 0x100) return cp;
    return 0x0100_0000 + @as(u32, cp);
}

/// xkb's name for `keysym` into `buf`, or "" for a keysym outside this
/// vocabulary.
pub fn name(buf: []u8, keysym: u32) []const u8 {
    if (keysym >= 0x20 and keysym < 0x100) {
        if (latin1Name(@intCast(keysym))) |n| return n;
        return "";
    }
    if (keysym > 0x0100_0000 and keysym <= 0x0110_ffff) {
        // xkb spells these `U` + at least four upper-case hex digits.
        return std.fmt.bufPrint(buf, "U{X:0>4}", .{keysym - 0x0100_0000}) catch "";
    }
    if (keysym >= KP_0 and keysym <= KP_0 + 9) {
        return std.fmt.bufPrint(buf, "KP_{d}", .{keysym - KP_0}) catch "";
    }
    if (keysym >= F1 and keysym < F1 + 35) {
        return std.fmt.bufPrint(buf, "F{d}", .{keysym - F1 + 1}) catch "";
    }
    return switch (keysym) {
        BackSpace => "BackSpace",
        Tab => "Tab",
        Clear => "Clear",
        Return => "Return",
        Escape => "Escape",
        Home => "Home",
        Left => "Left",
        Up => "Up",
        Right => "Right",
        Down => "Down",
        Prior => "Prior",
        Next => "Next",
        End => "End",
        Insert => "Insert",
        Menu => "Menu",
        Help => "Help",
        KP_Enter => "KP_Enter",
        KP_Multiply => "KP_Multiply",
        KP_Add => "KP_Add",
        KP_Subtract => "KP_Subtract",
        KP_Decimal => "KP_Decimal",
        KP_Divide => "KP_Divide",
        KP_Equal => "KP_Equal",
        Delete => "Delete",
        ISO_Left_Tab => "ISO_Left_Tab",
        else => "",
    };
}

/// The Latin-1 keysym names, indexed from 0x20 (space) — X11's keysymdef.h.
/// Letters and digits are themselves; everything else has a word.
fn latin1Name(cp: u8) ?[]const u8 {
    if ((cp >= 'a' and cp <= 'z') or (cp >= 'A' and cp <= 'Z') or (cp >= '0' and cp <= '9'))
        return latin1_alnum[cp .. cp + 1];
    if (cp >= 0x20 and cp < 0x7f) return ascii_punct[cp - 0x20];
    if (cp >= 0xa0) return latin1_upper[cp - 0xa0];
    return null;
}

/// Every byte, so a letter or digit can be sliced as its own one-byte name.
const latin1_alnum: [256]u8 = blk: {
    var bytes: [256]u8 = undefined;
    for (&bytes, 0..) |*b, i| b.* = @intCast(i);
    break :blk bytes;
};

/// 0x20..0x7e; letters and digits are named by `latin1_alnum` (left null).
const ascii_punct = [_]?[]const u8{
    "space",     "exclam",     "quotedbl", "numbersign",  "dollar",    "percent",      "ampersand",   "apostrophe",
    "parenleft", "parenright", "asterisk", "plus",        "comma",     "minus",        "period",      "slash",
    null,        null,         null,       null,          null,        null,           null,          null,
    null,        null,         "colon",    "semicolon",   "less",      "equal",        "greater",     "question",
    "at",        null,         null,       null,          null,        null,           null,          null,
    null,        null,         null,       null,          null,        null,           null,          null,
    null,        null,         null,       null,          null,        null,           null,          null,
    null,        null,         null,       "bracketleft", "backslash", "bracketright", "asciicircum", "underscore",
    "grave",     null,         null,       null,          null,        null,           null,          null,
    null,        null,         null,       null,          null,        null,           null,          null,
    null,        null,         null,       null,          null,        null,           null,          null,
    null,        null,         null,       "braceleft",   "bar",       "braceright",   "asciitilde",
};

/// 0xa0..0xff.
const latin1_upper = [_][]const u8{
    "nobreakspace", "exclamdown",  "cent",        "sterling",       "currency",    "yen",     "brokenbar",     "section",
    "diaeresis",    "copyright",   "ordfeminine", "guillemotleft",  "notsign",     "hyphen",  "registered",    "macron",
    "degree",       "plusminus",   "twosuperior", "threesuperior",  "acute",       "mu",      "paragraph",     "periodcentered",
    "cedilla",      "onesuperior", "masculine",   "guillemotright", "onequarter",  "onehalf", "threequarters", "questiondown",
    "Agrave",       "Aacute",      "Acircumflex", "Atilde",         "Adiaeresis",  "Aring",   "AE",            "Ccedilla",
    "Egrave",       "Eacute",      "Ecircumflex", "Ediaeresis",     "Igrave",      "Iacute",  "Icircumflex",   "Idiaeresis",
    "ETH",          "Ntilde",      "Ograve",      "Oacute",         "Ocircumflex", "Otilde",  "Odiaeresis",    "multiply",
    "Oslash",       "Ugrave",      "Uacute",      "Ucircumflex",    "Udiaeresis",  "Yacute",  "THORN",         "ssharp",
    "agrave",       "aacute",      "acircumflex", "atilde",         "adiaeresis",  "aring",   "ae",            "ccedilla",
    "egrave",       "eacute",      "ecircumflex", "ediaeresis",     "igrave",      "iacute",  "icircumflex",   "idiaeresis",
    "eth",          "ntilde",      "ograve",      "oacute",         "ocircumflex", "otilde",  "odiaeresis",    "division",
    "oslash",       "ugrave",      "uacute",      "ucircumflex",    "udiaeresis",  "yacute",  "thorn",         "ydiaeresis",
};

comptime {
    std.debug.assert(ascii_punct.len == 0x7f - 0x20);
    std.debug.assert(latin1_upper.len == 0x100 - 0xa0);
}

test "keysym: characters map to xkb's encoding" {
    try std.testing.expectEqual(@as(?u32, 'a'), fromCodepoint('a'));
    try std.testing.expectEqual(@as(?u32, 0xe9), fromCodepoint(0xe9)); // é
    try std.testing.expectEqual(@as(?u32, 0x0100_20ac), fromCodepoint(0x20ac)); // €
    try std.testing.expectEqual(@as(?u32, null), fromCodepoint('\r'));
    try std.testing.expectEqual(@as(?u32, null), fromCodepoint(0x7f));
    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("U20AC", name(&buf, 0x0100_20ac));
    try std.testing.expectEqualStrings("colon", name(&buf, ':'));
    try std.testing.expectEqualStrings("F12", name(&buf, F1 + 11));
    try std.testing.expectEqualStrings("KP_7", name(&buf, KP_0 + 7));
}

test "keysym: every name agrees with libxkbcommon" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const xkb = @import("wayland.zig").c;
    var ours: [32]u8 = undefined;
    var theirs: [64]u8 = undefined;
    var checked: usize = 0;
    var mismatches: usize = 0;
    var sym: u32 = 0x20;
    while (sym < 0x1_0000) : (sym += 1) {
        const n = name(&ours, sym);
        if (n.len == 0) continue;
        const len = xkb.xkb_keysym_get_name(sym, &theirs, theirs.len);
        try std.testing.expect(len > 0);
        if (!std.mem.eql(u8, theirs[0..@intCast(len)], n)) {
            std.debug.print("keysym 0x{x}: xkb calls it {s}, we call it {s}\n", .{ sym, theirs[0..@intCast(len)], n });
            mismatches += 1;
        }
        checked += 1;
    }
    // Unicode keysyms with no legacy keysym of their own.
    for ([_]u21{ 0x20ac, 0x3b1, 0x4e2d, 0x1f600 }) |cp| {
        const sym_u = fromCodepoint(cp).?;
        const len = xkb.xkb_keysym_get_name(sym_u, &theirs, theirs.len);
        try std.testing.expectEqualStrings(theirs[0..@intCast(len)], name(&ours, sym_u));
        checked += 1;
    }
    try std.testing.expectEqual(@as(usize, 0), mismatches);
    try std.testing.expect(checked > 230);
}
