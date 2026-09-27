//! A GENERIC plugin-published status chip for the status line — the persistent
//! sibling of `echo`. The core knows nothing of what it says: a task's progress,
//! a repl's state, an agent's "waiting". Any plugin publishes via `weft.status`.
//! One `Feed` per system, held by its `Buffers` (which every producer, a
//! background job included, already reaches); the frame builder reads it into
//! the `Hud` each frame. Empty = no chip.
//!
//! It was a process-wide slot once, to spare threading a field through every
//! Context construction site. A second system in the same process (a test
//! binary booting one editor after another, a collab host) then showed the
//! first one's chip: a debug session that ended in one editor said "done" in
//! the status line of the next editor to start.
//!
//! W2a-2 note (doc/cwa-prior-docs-audit.md §5): this is a plugin→user BROADCAST (a
//! system-scoped event — one plugin publishing "building…" means it for
//! every head looking at this system), not per-head interaction state like
//! `echo`/`pick`/dot-repeat — there is no per-head cursor into it here to
//! move (just one `set`/`get` slot, no per-reader position). It stays
//! system-scoped. If two heads ever want to independently DISMISS/ack the
//! chip (rather than just both displaying whatever's currently published),
//! that's a per-head READ CURSOR over this feed — a W2b concern, not a
//! reason to fragment the broadcast itself.

const std = @import("std");

pub const Feed = struct {
    buf: [160]u8 = undefined,
    len: usize = 0,

    /// Set the status chip text (truncated to the slot). Empty clears it.
    pub fn set(self: *Feed, text: []const u8) void {
        self.len = @min(text.len, self.buf.len);
        @memcpy(self.buf[0..self.len], text[0..self.len]);
    }

    /// The current chip, or null when empty.
    pub fn get(self: *const Feed) ?[]const u8 {
        return if (self.len == 0) null else self.buf[0..self.len];
    }
};

test "two feeds do not share a chip" {
    var a: Feed = .{};
    var b: Feed = .{};
    a.set("○ *debug* · done");
    try std.testing.expectEqualStrings("○ *debug* · done", a.get().?);
    try std.testing.expect(b.get() == null);
    b.set("x");
    a.set("");
    try std.testing.expect(a.get() == null);
    try std.testing.expectEqualStrings("x", b.get().?);
}
