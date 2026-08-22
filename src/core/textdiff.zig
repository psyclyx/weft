//! textdiff — the minimal single-window diff between two byte strings,
//! scalar-boundary-snapped. Shared by every place that must turn "the
//! authority now says X" into a MINIMAL CRDT text op instead of a
//! wholesale delete+reinsert (which would mint fresh identity for every
//! byte and defeat anchors/subbuffers spanning the edited region):
//! `backing.zig`'s external-file-merge (`Sync.mergeExternal`) and
//! `transcript.zig`'s `on_save` row reconciliation both need exactly this
//! "old vs new → one replaced window" primitive, so it lives once, here,
//! instead of twice (extracted from `backing.zig`, which had the only copy
//! until `transcript.zig` needed the identical shape).
//!
//! The diff is prefix/suffix trimming — one replaced window. Correct
//! always (both sides converge on `new`); coarser than a structural diff
//! when the two byte strings differ in two distant regions (the window
//! spans both, so anchors inside it collapse to its edge). A refinement
//! ladder (line-based Myers inside the window) exists if that coarseness
//! ever bites.

const std = @import("std");

/// `old[start..old_end)` became `new[start..new_end)`.
pub const Window = struct { start: usize, old_end: usize, new_end: usize };

/// The single replaced window between two byte strings, snapped to UTF-8
/// scalar boundaries. Null when equal.
pub fn diffWindow(old: []const u8, new: []const u8) ?Window {
    if (std.mem.eql(u8, old, new)) return null;
    const max_prefix = @min(old.len, new.len);
    var p: usize = 0;
    while (p < max_prefix and old[p] == new[p]) p += 1;
    while (p > 0 and p < old.len and old[p] & 0xC0 == 0x80) p -= 1;
    var s: usize = 0;
    const max_suffix = @min(old.len, new.len) - p;
    while (s < max_suffix and old[old.len - 1 - s] == new[new.len - 1 - s]) s += 1;
    while (s > 0 and old[old.len - s] & 0xC0 == 0x80) s -= 1;
    return .{ .start = p, .old_end = old.len - s, .new_end = new.len - s };
}

// ── Tests ───────────────────────────────────────────────────────────

const t = std.testing;

test "diffWindow: trims, snaps to scalar boundaries" {
    try t.expectEqual(@as(?Window, null), diffWindow("abc", "abc"));
    const w = diffWindow("hello world", "hello brave world").?;
    try t.expectEqual(@as(usize, 6), w.start);
    try t.expectEqual(@as(usize, 6), w.old_end);
    try t.expectEqual(@as(usize, 12), w.new_end);
    // Multi-byte: the changed byte sits inside a codepoint; the window
    // must widen to whole scalars.
    const w2 = diffWindow("aàb", "aèb").?; // à=0xC3A0 è=0xC3A8 share 0xC3
    try t.expectEqual(@as(usize, 1), w2.start);
    try t.expectEqual(@as(usize, 3), w2.old_end);
    try t.expectEqual(@as(usize, 3), w2.new_end);
}

test {
    std.testing.refAllDecls(@This());
}
