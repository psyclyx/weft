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

/// How an entry RESTS under input (§10.4) — the DECLARED half of the pair
/// whose implicit version was the mode-leak class ("a tool entry left me in
/// an editing mode"). The presentation declares the posture; the grammar
/// reads it (`weft.posture()`) and interprets it in its own vocabulary. No
/// grammar asks what tool an entry is, and no entry names a mode.
///
/// - `text` — the full grammar applies, insert-like states included.
/// - `structural` — navigation and action states only; insert-like states do
///   not apply, so typing can never leak into a projection. Replaces locked
///   modes.
/// - `field` — structural, except that a focused editable field (§11.8)
///   takes commits through the grammar's insert-like states, scoped to the
///   field. It rests where `structural` rests.
/// - `capture` — physical input is delivered raw to the presentation's
///   endpoint (terminals, games). No capture consumer exists in-tree yet, so
///   nothing routes raw input today; what IS wired is the declaration, its
///   round trip, and the break-out that pairs with it. Capture is never a
///   one-way door: the grammar always retains a break-out chord
///   (`std.input.break-out` / the `posture-break-out` command), and breaking
///   out restores the declaration capture displaced.
///
/// DERIVED by default, from what the entry can do rather than from who owns
/// it: an entry that can take an interactive text edit is `text`; one that
/// cannot — a semantic view, a produced/read-only projection — is
/// `structural`, refined to `field` while an editable field holds focus. The
/// presentation owner may override the derivation (`weft.declarePosture`);
/// an EDITABLE projection needs no override, since it derives `text` already.
///
/// PRECEDENCE (the standing rule, enforced in `app/dispatch.zig`
/// `dispatchSpec`): while an interaction is on the head's stack, the
/// interaction's presenter owns input FIRST — `invokeInteractionInput` runs
/// before the grammar sees the key, under this same vocabulary — and
/// grammars see only what it declines. Escape never force-changes a resting
/// posture: it returns to the entry's declared resting state
/// (`weft.exitToResting`), it does not pick one.
pub const Posture = enum(u32) {
    text,
    structural,
    field,
    capture,

    /// The wire form (a `u32` across the membrane), and its inverse. An
    /// unknown value is not a posture — the caller keeps its own default
    /// rather than inventing one.
    pub fn fromWire(raw: u32) ?Posture {
        if (raw > @intFromEnum(Posture.capture)) return null;
        return @enumFromInt(raw);
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

test "posture: the wire form round-trips and refuses a value outside the vocabulary" {
    for ([_]Posture{ .text, .structural, .field, .capture }) |p|
        try t.expectEqual(p, Posture.fromWire(@intFromEnum(p)).?);
    try t.expectEqual(@as(?Posture, null), Posture.fromWire(4));
}
