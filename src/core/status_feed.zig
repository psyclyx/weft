//! A GENERIC plugin-published status chip for the status line — the persistent
//! sibling of `echo`. The core knows nothing of what it says: a task's progress,
//! a repl's state, an agent's "waiting". Any plugin publishes via `weft.status`.
//! A process-wide slot (not a `Context`/`FrameCtx` field) so the membrane can
//! set it without threading a new field through every Context construction site;
//! the frame builder reads it into the `Hud` each frame. Empty = no chip.
//!
//! W2a-2 note (north-star-plan §6): this is a plugin→user BROADCAST (a
//! system-scoped event — one plugin publishing "building…" means it for
//! every head looking at this system), not per-head interaction state like
//! `echo`/`pick`/dot-repeat — there is no per-head cursor into it here to
//! move (just one `set`/`get` slot, no per-reader position). It stays
//! system-scoped. If two heads ever want to independently DISMISS/ack the
//! chip (rather than just both displaying whatever's currently published),
//! that's a per-head READ CURSOR over this feed — a W2b concern, not a
//! reason to fragment the broadcast itself.

const std = @import("std");

var buf: [160]u8 = undefined;
var len: usize = 0;

/// Set the status chip text (truncated to the slot). Empty clears it.
pub fn set(text: []const u8) void {
    len = @min(text.len, buf.len);
    @memcpy(buf[0..len], text[0..len]);
}

/// The current chip, or null when empty.
pub fn get() ?[]const u8 {
    return if (len == 0) null else buf[0..len];
}
