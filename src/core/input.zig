//! The input boundary (doc/contextual-workspace-architecture.md §10.1): a
//! PHYSICAL key and a TEXT COMMIT are different values and never convert into
//! one another.
//!
//! Physical input — a key symbol plus modifiers, spelled as a `Keymap` keyspec
//! — feeds the binding grammar. `TextCommit` is committed Unicode/IME text,
//! produced only by a keystroke that actually commits characters and consumed
//! only by an editable endpoint. Unhandled physical input stays unhandled: no
//! layer here synthesizes text out of a key nobody bound.

const std = @import("std");

/// Committed text. `from` is the only door that inspects bytes, so a control
/// byte cannot be laundered into a commit further downstream — a mode that
/// commits text still cannot commit Tab, Escape, or a line break.
pub const TextCommit = struct {
    bytes: []const u8 = "",

    /// A keystroke that commits nothing (a chord, a bare motion key).
    pub const none: TextCommit = .{};

    /// The commit `bytes` carry, if any. Control bytes are physical keys with
    /// a legacy ASCII spelling (Tab → `\t`, Escape → `\x1b`, Return → `\r`),
    /// not text a user typed: they commit nothing.
    pub fn from(bytes: []const u8) TextCommit {
        if (bytes.len == 0) return .none;
        for (bytes) |b| if (b < 0x20 or b == 0x7f) return .none;
        return .{ .bytes = bytes };
    }

    pub fn isEmpty(self: TextCommit) bool {
        return self.bytes.len == 0;
    }
};

// ── Tests ───────────────────────────────────────────────────────────

const t = std.testing;

test "text commit: printable text commits, control bytes do not" {
    try t.expectEqualStrings("a", TextCommit.from("a").bytes);
    try t.expectEqualStrings("é", TextCommit.from("é").bytes); // multi-byte UTF-8
    try t.expectEqualStrings("日本", TextCommit.from("日本").bytes); // an IME commit
    try t.expect(TextCommit.from("").isEmpty());
    try t.expect(TextCommit.from("\t").isEmpty());
    try t.expect(TextCommit.from("\n").isEmpty());
    try t.expect(TextCommit.from("\x1b").isEmpty());
    try t.expect(TextCommit.from("\x7f").isEmpty());
    try t.expect(TextCommit.none.isEmpty());
}
