//! The grammar's pending prefixes: a count (`3w`) and a register (`"a`).
//! Both are typed before the verb that consumes them, and both must die with
//! that verb — the `after` hook in `root.zig` clears them after every command
//! that does not preserve them, so a stray prefix cannot leak into a later,
//! unrelated key.

/// The typed count, 0 when none.
pub var count: u32 = 0;
/// The chosen register slot: 0 unnamed, 1..26 `a`..`z`, 27 `/` (core's
/// numbering).
pub var register: u8 = 0;
/// The character that chose it, for the registers core keys by character
/// (a macro's: `"aQ` records into `a`). 0 when none was typed.
pub var register_char: u8 = 0;

/// The count to repeat by: the typed one, else 1.
pub fn takeCount() u32 {
    const c = if (count == 0) 1 else count;
    count = 0;
    return c;
}

/// The typed count itself, or null when none was typed (`gg` vs `5gg`).
pub fn takeRawCount() ?u32 {
    const c = count;
    count = 0;
    return if (c == 0) null else c;
}

pub fn takeRegister() u8 {
    const r = register;
    register = 0;
    register_char = 0;
    return r;
}

/// The typed register's character, or `default` when none was typed.
pub fn takeRegisterChar(default: u8) u8 {
    const c = if (register_char == 0) default else register_char;
    register = 0;
    register_char = 0;
    return c;
}

pub fn digit(d: u32) void {
    count = count *| 10 +| d;
}

/// The register slot a typed character names: `a`..`z` (either case) are
/// the named slots, `/` the search register every grammar shares; anything
/// else is the unnamed one.
pub fn slotOf(c: u8) u8 {
    if (c == '/') return @import("weft").register_search;
    const lower = c | 0x20;
    if (lower >= 'a' and lower <= 'z') return lower - 'a' + 1;
    return 0;
}
