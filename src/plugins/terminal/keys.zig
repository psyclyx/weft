//! Keys — a weft keystroke (its canonical spec, `C-c` / `S-Tab` / `M-x` /
//! `Prior`, and the text it committed) as the key event libghostty-vt's
//! encoder takes: a physical key, modifiers, and the unmodified text. The
//! ENCODER decides the bytes — legacy control codes, application cursor
//! keys, the kitty keyboard protocol — from the terminal's modes; this only
//! says which key it was.
//!
//! Specs name xkb keysyms, so a shifted character arrives as its shifted
//! keysym (`S-exclam`, `S-A`); the physical key it came from is the US
//! layout's, which only matters to a program that asked for key codes (the
//! kitty protocol) — the text it carries is the text typed.

const std = @import("std");
const c = @import("c.zig").c;

const shift: c.GhosttyMods = c.GHOSTTY_MODS_SHIFT;

pub const Key = struct {
    key: c.GhosttyKey,
    mods: c.GhosttyMods = 0,
    /// Modifiers the text already reflects (shift, for `A`): the encoder
    /// must not apply them twice.
    consumed: c.GhosttyMods = 0,
    /// The text the key produced, before ctrl/alt; empty for none.
    text: []const u8 = "",
    unshifted: u32 = 0,
};

/// `spec` + `commit` as a key event; null for a spec that names no key a
/// terminal knows (a pointer gesture, a bare modifier).
pub fn parse(spec: []const u8, commit: []const u8, buf: *[8]u8) ?Key {
    var mods: c.GhosttyMods = 0;
    var base = spec;
    while (base.len > 2 and base[1] == '-') {
        switch (base[0]) {
            'C' => mods |= c.GHOSTTY_MODS_CTRL,
            'M' => mods |= c.GHOSTTY_MODS_ALT,
            'S' => mods |= c.GHOSTTY_MODS_SHIFT,
            's' => mods |= c.GHOSTTY_MODS_SUPER,
            else => break,
        }
        base = base[2..];
    }
    if (named(base)) |n| {
        var k: Key = .{ .key = n.key, .mods = mods | n.mods };
        // Keypad digits and operators type text too (with Num Lock on).
        if (commit.len > 0) k.text = commit;
        return k;
    }
    // A character key: the letter or digit itself, or a punctuation keysym.
    const ch: Char = if (base.len == 1) charOf(base[0]) orelse return textOnly(commit, mods) else punct(base) orelse return textOnly(commit, mods);
    var k: Key = .{ .key = ch.key, .mods = mods, .unshifted = ch.unshifted };
    if (commit.len > 0) {
        k.text = commit;
    } else {
        // A ctrl/alt chord committed nothing: the encoder still wants the
        // character the key makes.
        buf[0] = ch.char;
        k.text = buf[0..1];
    }
    // The shifted character IS the shift.
    if (ch.char != ch.unshifted) k.consumed = mods & shift;
    return k;
}

/// Text from a key the table does not name (a composed character, a
/// layout's own letters): what it typed, and nothing else.
fn textOnly(commit: []const u8, mods: c.GhosttyMods) ?Key {
    if (commit.len == 0) return null;
    return .{ .key = c.GHOSTTY_KEY_UNIDENTIFIED, .mods = mods, .consumed = mods & shift, .text = commit };
}

const Char = struct { key: c.GhosttyKey, char: u8, unshifted: u8 };

fn charOf(b: u8) ?Char {
    return switch (b) {
        'a'...'z' => .{ .key = @intCast(c.GHOSTTY_KEY_A + (b - 'a')), .char = b, .unshifted = b },
        'A'...'Z' => .{ .key = @intCast(c.GHOSTTY_KEY_A + (b - 'A')), .char = b, .unshifted = b + ('a' - 'A') },
        '0'...'9' => .{ .key = @intCast(c.GHOSTTY_KEY_DIGIT_0 + (b - '0')), .char = b, .unshifted = b },
        else => null,
    };
}

/// A punctuation keysym, as the US-layout key it sits on.
fn punct(name: []const u8) ?Char {
    const table = [_]struct { []const u8, c.GhosttyKey, u8, u8 }{
        .{ "space", c.GHOSTTY_KEY_SPACE, ' ', ' ' },
        .{ "minus", c.GHOSTTY_KEY_MINUS, '-', '-' },
        .{ "underscore", c.GHOSTTY_KEY_MINUS, '_', '-' },
        .{ "equal", c.GHOSTTY_KEY_EQUAL, '=', '=' },
        .{ "plus", c.GHOSTTY_KEY_EQUAL, '+', '=' },
        .{ "bracketleft", c.GHOSTTY_KEY_BRACKET_LEFT, '[', '[' },
        .{ "braceleft", c.GHOSTTY_KEY_BRACKET_LEFT, '{', '[' },
        .{ "bracketright", c.GHOSTTY_KEY_BRACKET_RIGHT, ']', ']' },
        .{ "braceright", c.GHOSTTY_KEY_BRACKET_RIGHT, '}', ']' },
        .{ "backslash", c.GHOSTTY_KEY_BACKSLASH, '\\', '\\' },
        .{ "bar", c.GHOSTTY_KEY_BACKSLASH, '|', '\\' },
        .{ "semicolon", c.GHOSTTY_KEY_SEMICOLON, ';', ';' },
        .{ "colon", c.GHOSTTY_KEY_SEMICOLON, ':', ';' },
        .{ "apostrophe", c.GHOSTTY_KEY_QUOTE, '\'', '\'' },
        .{ "quotedbl", c.GHOSTTY_KEY_QUOTE, '"', '\'' },
        .{ "grave", c.GHOSTTY_KEY_BACKQUOTE, '`', '`' },
        .{ "asciitilde", c.GHOSTTY_KEY_BACKQUOTE, '~', '`' },
        .{ "comma", c.GHOSTTY_KEY_COMMA, ',', ',' },
        .{ "less", c.GHOSTTY_KEY_COMMA, '<', ',' },
        .{ "period", c.GHOSTTY_KEY_PERIOD, '.', '.' },
        .{ "greater", c.GHOSTTY_KEY_PERIOD, '>', '.' },
        .{ "slash", c.GHOSTTY_KEY_SLASH, '/', '/' },
        .{ "question", c.GHOSTTY_KEY_SLASH, '?', '/' },
        .{ "exclam", c.GHOSTTY_KEY_DIGIT_1, '!', '1' },
        .{ "at", c.GHOSTTY_KEY_DIGIT_2, '@', '2' },
        .{ "numbersign", c.GHOSTTY_KEY_DIGIT_3, '#', '3' },
        .{ "dollar", c.GHOSTTY_KEY_DIGIT_4, '$', '4' },
        .{ "percent", c.GHOSTTY_KEY_DIGIT_5, '%', '5' },
        .{ "asciicircum", c.GHOSTTY_KEY_DIGIT_6, '^', '6' },
        .{ "ampersand", c.GHOSTTY_KEY_DIGIT_7, '&', '7' },
        .{ "asterisk", c.GHOSTTY_KEY_DIGIT_8, '*', '8' },
        .{ "parenleft", c.GHOSTTY_KEY_DIGIT_9, '(', '9' },
        .{ "parenright", c.GHOSTTY_KEY_DIGIT_0, ')', '0' },
    };
    for (table) |row| if (std.mem.eql(u8, row[0], name)) return .{ .key = row[1], .char = row[2], .unshifted = row[3] };
    return null;
}

const Named = struct { key: c.GhosttyKey, mods: c.GhosttyMods = 0 };

/// The keys that are not characters, by keysym.
fn named(name: []const u8) ?Named {
    if (name.len >= 2 and name[0] == 'F') {
        const n = std.fmt.parseInt(u8, name[1..], 10) catch 0;
        if (n >= 1 and n <= 25) return .{ .key = @intCast(c.GHOSTTY_KEY_F1 + (n - 1)) };
    }
    if (name.len == 4 and std.mem.startsWith(u8, name, "KP_") and name[3] >= '0' and name[3] <= '9')
        return .{ .key = @intCast(c.GHOSTTY_KEY_NUMPAD_0 + (name[3] - '0')) };
    const table = [_]struct { []const u8, c.GhosttyKey }{
        .{ "Return", c.GHOSTTY_KEY_ENTER },
        .{ "Tab", c.GHOSTTY_KEY_TAB },
        .{ "BackSpace", c.GHOSTTY_KEY_BACKSPACE },
        .{ "Escape", c.GHOSTTY_KEY_ESCAPE },
        .{ "Delete", c.GHOSTTY_KEY_DELETE },
        .{ "Insert", c.GHOSTTY_KEY_INSERT },
        .{ "Home", c.GHOSTTY_KEY_HOME },
        .{ "End", c.GHOSTTY_KEY_END },
        .{ "Prior", c.GHOSTTY_KEY_PAGE_UP },
        .{ "Page_Up", c.GHOSTTY_KEY_PAGE_UP },
        .{ "Next", c.GHOSTTY_KEY_PAGE_DOWN },
        .{ "Page_Down", c.GHOSTTY_KEY_PAGE_DOWN },
        .{ "Up", c.GHOSTTY_KEY_ARROW_UP },
        .{ "Down", c.GHOSTTY_KEY_ARROW_DOWN },
        .{ "Left", c.GHOSTTY_KEY_ARROW_LEFT },
        .{ "Right", c.GHOSTTY_KEY_ARROW_RIGHT },
        .{ "Menu", c.GHOSTTY_KEY_CONTEXT_MENU },
        .{ "KP_Enter", c.GHOSTTY_KEY_NUMPAD_ENTER },
        .{ "KP_Add", c.GHOSTTY_KEY_NUMPAD_ADD },
        .{ "KP_Subtract", c.GHOSTTY_KEY_NUMPAD_SUBTRACT },
        .{ "KP_Multiply", c.GHOSTTY_KEY_NUMPAD_MULTIPLY },
        .{ "KP_Divide", c.GHOSTTY_KEY_NUMPAD_DIVIDE },
        .{ "KP_Decimal", c.GHOSTTY_KEY_NUMPAD_DECIMAL },
        .{ "KP_Separator", c.GHOSTTY_KEY_NUMPAD_SEPARATOR },
        .{ "KP_Equal", c.GHOSTTY_KEY_NUMPAD_EQUAL },
        .{ "KP_Home", c.GHOSTTY_KEY_NUMPAD_HOME },
        .{ "KP_End", c.GHOSTTY_KEY_NUMPAD_END },
        .{ "KP_Up", c.GHOSTTY_KEY_NUMPAD_UP },
        .{ "KP_Down", c.GHOSTTY_KEY_NUMPAD_DOWN },
        .{ "KP_Left", c.GHOSTTY_KEY_NUMPAD_LEFT },
        .{ "KP_Right", c.GHOSTTY_KEY_NUMPAD_RIGHT },
        .{ "KP_Prior", c.GHOSTTY_KEY_NUMPAD_PAGE_UP },
        .{ "KP_Next", c.GHOSTTY_KEY_NUMPAD_PAGE_DOWN },
        .{ "KP_Insert", c.GHOSTTY_KEY_NUMPAD_INSERT },
        .{ "KP_Delete", c.GHOSTTY_KEY_NUMPAD_DELETE },
        .{ "KP_Begin", c.GHOSTTY_KEY_NUMPAD_BEGIN },
    };
    for (table) |row| if (std.mem.eql(u8, row[0], name)) return .{ .key = row[1] };
    // xkb spells Shift+Tab as its own keysym.
    if (std.mem.eql(u8, name, "ISO_Left_Tab")) return .{ .key = c.GHOSTTY_KEY_TAB, .mods = c.GHOSTTY_MODS_SHIFT };
    return null;
}
