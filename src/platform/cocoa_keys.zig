//! Cocoa key events → weft `KeyEvent`s: the pure half of the macOS keyboard.
//!
//! AppKit reports a key as a virtual key code (`kVK_*`, a physical position)
//! plus text: what the key committed through the text-input system (dead keys
//! and input methods compose there), or — for a chord — the key's character on
//! the current layout with no modifiers. weft's key vocabulary is xkb's
//! (`keysym.zig`), and its rules are the Wayland platform's, so a binding
//! means the same key on both:
//!
//! - A character key with no chord is named by the character it typed, with
//!   Shift consumed (`A`, `dollar`, `eacute`) and the text committed.
//! - A chord (Control, Meta, or Command held) names the key's UNSHIFTED
//!   character and carries Shift explicitly (`C-S-a`, never `C-A`), and
//!   commits nothing — exactly xkb's `baseKeysym` rule.
//! - A key that types no character (Return, arrows, F-keys, the keypad) is
//!   named by its key code, with Shift explicit (`S-Return`) — except
//!   Shift+Tab, which xkb's layouts name `ISO_Left_Tab` with Shift consumed.
//!
//! Only the LEFT Option key is Meta. The right one stays the macOS typing
//! modifier, so a layout that puts `@`, `[` or `|` on Option (German, French,
//! ...) can still type them; `cocoa/window.m` makes that split before any
//! text input runs.
//!
//! Pure (no AppKit), so the Linux suite runs these rules; the key codes are
//! checked against the SDK's own `kVK_*` constants in `cocoa/window.m`.

const std = @import("std");
const platform = @import("root.zig");
const keysym = @import("keysym.zig");
const KeyEvent = platform.KeyEvent;
const Mods = platform.Mods;

/// The `kVK_*` codes of keys that type no character (HIToolbox/Events.h).
pub const vk = struct {
    pub const Return = 0x24;
    pub const Tab = 0x30;
    pub const Delete = 0x33; // Backspace
    pub const Escape = 0x35;
    pub const Help = 0x72;
    pub const Home = 0x73;
    pub const PageUp = 0x74;
    pub const ForwardDelete = 0x75;
    pub const End = 0x77;
    pub const PageDown = 0x79;
    pub const LeftArrow = 0x7B;
    pub const RightArrow = 0x7C;
    pub const DownArrow = 0x7D;
    pub const UpArrow = 0x7E;
    pub const ContextualMenu = 0x6E;
    pub const F1 = 0x7A;
    pub const F2 = 0x78;
    pub const F3 = 0x63;
    pub const F4 = 0x76;
    pub const F5 = 0x60;
    pub const F6 = 0x61;
    pub const F7 = 0x62;
    pub const F8 = 0x64;
    pub const F9 = 0x65;
    pub const F10 = 0x6D;
    pub const F11 = 0x67;
    pub const F12 = 0x6F;
    pub const F13 = 0x69;
    pub const F14 = 0x6B;
    pub const F15 = 0x71;
    pub const F16 = 0x6A;
    pub const F17 = 0x40;
    pub const F18 = 0x4F;
    pub const F19 = 0x50;
    pub const F20 = 0x5A;
    pub const KeypadDecimal = 0x41;
    pub const KeypadMultiply = 0x43;
    pub const KeypadPlus = 0x45;
    pub const KeypadClear = 0x47;
    pub const KeypadDivide = 0x4B;
    pub const KeypadEnter = 0x4C;
    pub const KeypadMinus = 0x4E;
    pub const KeypadEquals = 0x51;
    pub const Keypad0 = 0x52;
    pub const Keypad1 = 0x53;
    pub const Keypad2 = 0x54;
    pub const Keypad3 = 0x55;
    pub const Keypad4 = 0x56;
    pub const Keypad5 = 0x57;
    pub const Keypad6 = 0x58;
    pub const Keypad7 = 0x59;
    pub const Keypad8 = 0x5B;
    pub const Keypad9 = 0x5C;
    /// Not a key: text an input method committed outside any key press
    /// (a candidate picked with the mouse).
    pub const none = 0xFFFF;
};

/// The keysym of a key that types no character, by key code; null for a
/// character key (named by its text instead).
pub fn specialKeysym(keycode: u16) ?u32 {
    return switch (keycode) {
        vk.Return => keysym.Return,
        vk.Tab => keysym.Tab,
        vk.Delete => keysym.BackSpace,
        vk.Escape => keysym.Escape,
        // A PC keyboard's Insert key reports as Help on a Mac; xkb calls it Insert.
        vk.Help => keysym.Insert,
        vk.Home => keysym.Home,
        vk.PageUp => keysym.Prior,
        vk.ForwardDelete => keysym.Delete,
        vk.End => keysym.End,
        vk.PageDown => keysym.Next,
        vk.LeftArrow => keysym.Left,
        vk.RightArrow => keysym.Right,
        vk.DownArrow => keysym.Down,
        vk.UpArrow => keysym.Up,
        vk.ContextualMenu => keysym.Menu,
        vk.F1 => keysym.F1,
        vk.F2 => keysym.F1 + 1,
        vk.F3 => keysym.F1 + 2,
        vk.F4 => keysym.F1 + 3,
        vk.F5 => keysym.F1 + 4,
        vk.F6 => keysym.F1 + 5,
        vk.F7 => keysym.F1 + 6,
        vk.F8 => keysym.F1 + 7,
        vk.F9 => keysym.F1 + 8,
        vk.F10 => keysym.F1 + 9,
        vk.F11 => keysym.F1 + 10,
        vk.F12 => keysym.F1 + 11,
        vk.F13 => keysym.F1 + 12,
        vk.F14 => keysym.F1 + 13,
        vk.F15 => keysym.F1 + 14,
        vk.F16 => keysym.F1 + 15,
        vk.F17 => keysym.F1 + 16,
        vk.F18 => keysym.F1 + 17,
        vk.F19 => keysym.F1 + 18,
        vk.F20 => keysym.F1 + 19,
        vk.KeypadDecimal => keysym.KP_Decimal,
        vk.KeypadMultiply => keysym.KP_Multiply,
        vk.KeypadPlus => keysym.KP_Add,
        vk.KeypadClear => keysym.Clear,
        vk.KeypadDivide => keysym.KP_Divide,
        vk.KeypadEnter => keysym.KP_Enter,
        vk.KeypadMinus => keysym.KP_Subtract,
        vk.KeypadEquals => keysym.KP_Equal,
        vk.Keypad0 => keysym.KP_0,
        vk.Keypad1 => keysym.KP_0 + 1,
        vk.Keypad2 => keysym.KP_0 + 2,
        vk.Keypad3 => keysym.KP_0 + 3,
        vk.Keypad4 => keysym.KP_0 + 4,
        vk.Keypad5 => keysym.KP_0 + 5,
        vk.Keypad6 => keysym.KP_0 + 6,
        vk.Keypad7 => keysym.KP_0 + 7,
        vk.Keypad8 => keysym.KP_0 + 8,
        vk.Keypad9 => keysym.KP_0 + 9,
        else => null,
    };
}

/// One key as AppKit reported it.
pub const Raw = struct {
    keycode: u16,
    pressed: bool,
    /// Modifiers in force, with `alt` meaning Meta (the left Option key).
    mods: Mods,
    /// What the key committed through text input; empty for a chord, a
    /// release, or a key that typed nothing.
    text: []const u8,
    /// The key's character on the current layout with no modifiers (AppKit's
    /// `charactersByApplyingModifiers:0`); names a chord.
    base: []const u8,
};

/// The weft key event for `raw`, or null when it names no key (a modifier
/// press, a private-use function-key character AppKit invents, an empty
/// commit).
pub fn translate(raw: Raw) ?KeyEvent {
    const chord = raw.mods.ctrl or raw.mods.alt or raw.mods.logo;
    var ev: KeyEvent = .{ .keysym = 0, .mods = raw.mods, .pressed = raw.pressed };

    if (specialKeysym(raw.keycode)) |sym| {
        ev.keysym = sym;
        // xkb's layouts put ISO_Left_Tab on Tab's shifted level, consuming Shift.
        if (sym == keysym.Tab and raw.mods.shift and !chord) {
            ev.keysym = keysym.ISO_Left_Tab;
            ev.mods.shift = false;
        }
        // Keypad digits and operators still type their character.
        if (!chord) setText(&ev, raw.text);
        return ev;
    }

    if (chord) {
        ev.keysym = characterKeysym(raw.base) orelse return null;
        return ev; // a chord commits nothing; Shift stays explicit
    }

    // A character key with no chord: named by the character it typed. Shift
    // is consumed when it changed that character (`A`, `dollar`) and explicit
    // when it did not (`S-space`) — xkb's consumed-modifier rule. A release
    // carries no text, so it is named by the unmodified character instead.
    const named_by = if (raw.text.len > 0) raw.text else raw.base;
    ev.keysym = characterKeysym(named_by) orelse return null;
    ev.mods.shift = raw.mods.shift and std.mem.eql(u8, named_by, raw.base);
    setText(&ev, raw.text);
    return ev;
}

/// The keysym of a one-character string; null when it is empty, more than
/// one character, a control character, or one of the private-use code points
/// AppKit gives function keys (U+F700..U+F8FF).
fn characterKeysym(s: []const u8) ?u32 {
    if (s.len == 0) return null;
    const len = std.unicode.utf8ByteSequenceLength(s[0]) catch return null;
    if (len != s.len) return null;
    const cp = std.unicode.utf8Decode(s) catch return null;
    if (cp >= 0xF700 and cp <= 0xF8FF) return null;
    return keysym.fromCodepoint(cp);
}

/// Commit `text` with the key — only if it is one real character: never a
/// control byte or the private-use code point AppKit gives a function key.
fn setText(ev: *KeyEvent, text: []const u8) void {
    if (characterKeysym(text) == null or text.len > ev.utf8.len) return;
    @memcpy(ev.utf8[0..text.len], text);
    ev.utf8_len = @intCast(text.len);
}

// ── Tests ───────────────────────────────────────────────────────────

const t = std.testing;

fn name(ev: KeyEvent) []const u8 {
    const S = struct {
        var buf: [32]u8 = undefined;
    };
    return keysym.name(&S.buf, ev.keysym);
}

test "cocoa keys: typed characters are named by what they typed, Shift consumed" {
    const a = translate(.{ .keycode = 0x00, .pressed = true, .mods = .{}, .text = "a", .base = "a" }).?;
    try t.expectEqualStrings("a", name(a));
    try t.expectEqualStrings("a", a.text());

    const big_a = translate(.{ .keycode = 0x00, .pressed = true, .mods = .{ .shift = true }, .text = "A", .base = "a" }).?;
    try t.expectEqualStrings("A", name(big_a));
    try t.expect(!big_a.mods.shift);

    const dollar = translate(.{ .keycode = 0x15, .pressed = true, .mods = .{ .shift = true }, .text = "$", .base = "4" }).?;
    try t.expectEqualStrings("dollar", name(dollar));

    // A composed character (dead key, input method, right Option) is one key.
    const e_acute = translate(.{ .keycode = 0x0E, .pressed = true, .mods = .{}, .text = "é", .base = "e" }).?;
    try t.expectEqualStrings("eacute", name(e_acute));
    try t.expectEqualStrings("é", e_acute.text());

    const euro = translate(.{ .keycode = 0x13, .pressed = true, .mods = .{}, .text = "€", .base = "2" }).?;
    try t.expectEqualStrings("U20AC", name(euro));
}

test "cocoa keys: chords name the unshifted key, keep Shift, commit nothing" {
    const c_a = translate(.{ .keycode = 0x00, .pressed = true, .mods = .{ .ctrl = true }, .text = "", .base = "a" }).?;
    try t.expectEqualStrings("a", name(c_a));
    try t.expectEqual(@as(u8, 0), c_a.utf8_len);

    const c_s_a = translate(.{ .keycode = 0x00, .pressed = true, .mods = .{ .ctrl = true, .shift = true }, .text = "", .base = "a" }).?;
    try t.expectEqualStrings("a", name(c_s_a));
    try t.expect(c_s_a.mods.shift);

    const super_c = translate(.{ .keycode = 0x08, .pressed = true, .mods = .{ .logo = true }, .text = "", .base = "c" }).?;
    try t.expectEqualStrings("c", name(super_c));
    try t.expect(super_c.mods.logo);

    const meta_x = translate(.{ .keycode = 0x07, .pressed = true, .mods = .{ .alt = true }, .text = "", .base = "x" }).?;
    try t.expectEqualStrings("x", name(meta_x));

    const c_minus = translate(.{ .keycode = 0x1B, .pressed = true, .mods = .{ .ctrl = true }, .text = "", .base = "-" }).?;
    try t.expectEqualStrings("minus", name(c_minus));
}

test "cocoa keys: non-character keys are named by key code, Shift explicit" {
    const ret = translate(.{ .keycode = vk.Return, .pressed = true, .mods = .{ .shift = true }, .text = "", .base = "\r" }).?;
    try t.expectEqualStrings("Return", name(ret));
    try t.expect(ret.mods.shift);

    const back_tab = translate(.{ .keycode = vk.Tab, .pressed = true, .mods = .{ .shift = true }, .text = "", .base = "\t" }).?;
    try t.expectEqualStrings("ISO_Left_Tab", name(back_tab));
    try t.expect(!back_tab.mods.shift);

    const c_s_tab = translate(.{ .keycode = vk.Tab, .pressed = true, .mods = .{ .ctrl = true, .shift = true }, .text = "", .base = "\t" }).?;
    try t.expectEqualStrings("Tab", name(c_s_tab));
    try t.expect(c_s_tab.mods.shift);

    const left = translate(.{ .keycode = vk.LeftArrow, .pressed = true, .mods = .{ .ctrl = true }, .text = "", .base = "\u{F702}" }).?;
    try t.expectEqualStrings("Left", name(left));

    const f5 = translate(.{ .keycode = vk.F5, .pressed = true, .mods = .{}, .text = "", .base = "\u{F708}" }).?;
    try t.expectEqualStrings("F5", name(f5));

    const page_up = translate(.{ .keycode = vk.PageUp, .pressed = true, .mods = .{}, .text = "", .base = "" }).?;
    try t.expectEqualStrings("Prior", name(page_up));

    // A PC keyboard's Insert reports as Help; it is Insert, as xkb names it.
    const insert = translate(.{ .keycode = vk.Help, .pressed = true, .mods = .{}, .text = "", .base = "\u{F746}" }).?;
    try t.expectEqualStrings("Insert", name(insert));

    const kp_7 = translate(.{ .keycode = vk.Keypad7, .pressed = true, .mods = .{}, .text = "7", .base = "7" }).?;
    try t.expectEqualStrings("KP_7", name(kp_7));
    try t.expectEqualStrings("7", kp_7.text());

    const backspace = translate(.{ .keycode = vk.Delete, .pressed = true, .mods = .{}, .text = "", .base = "\x7f" }).?;
    try t.expectEqualStrings("BackSpace", name(backspace));
    const delete = translate(.{ .keycode = vk.ForwardDelete, .pressed = true, .mods = .{}, .text = "", .base = "\u{F728}" }).?;
    try t.expectEqualStrings("Delete", name(delete));
}

test "cocoa keys: what names no key is dropped" {
    // A private-use function-key character AppKit invents for an unknown key.
    try t.expectEqual(@as(?KeyEvent, null), translate(.{ .keycode = 0x3F, .pressed = true, .mods = .{ .ctrl = true }, .text = "", .base = "\u{F746}" }));
    // A chord on a key with no character on this layout.
    try t.expectEqual(@as(?KeyEvent, null), translate(.{ .keycode = 0x3F, .pressed = true, .mods = .{ .ctrl = true }, .text = "", .base = "" }));
    // Several characters committed at once are not one key (the platform
    // splits an input method's commit into one key per character).
    try t.expectEqual(@as(?KeyEvent, null), translate(.{ .keycode = vk.none, .pressed = true, .mods = .{}, .text = "日本", .base = "" }));
}

test "cocoa keys: a release is named like its press" {
    const up = translate(.{ .keycode = 0x00, .pressed = false, .mods = .{}, .text = "", .base = "a" }).?;
    try t.expectEqualStrings("a", name(up));
    try t.expect(!up.pressed);
}

test "cocoa keys: Shift is explicit when it changed nothing, and junk is never committed" {
    const s_space = translate(.{ .keycode = 0x31, .pressed = true, .mods = .{ .shift = true }, .text = " ", .base = " " }).?;
    try t.expectEqualStrings("space", name(s_space));
    try t.expect(s_space.mods.shift);
    try t.expectEqualStrings(" ", s_space.text());

    // An F-key whose private-use character came through text input.
    const f5 = translate(.{ .keycode = vk.F5, .pressed = true, .mods = .{}, .text = "\u{F708}", .base = "\u{F708}" }).?;
    try t.expectEqualStrings("F5", name(f5));
    try t.expectEqual(@as(u8, 0), f5.utf8_len);
}
