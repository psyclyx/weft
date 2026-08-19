//! A GENERIC plugin-published status chip for the status line — the persistent
//! sibling of `echo`. The core knows nothing of what it says: a task's progress,
//! a repl's state, an agent's "waiting". Any plugin publishes via `weft.status`.
//! A process-wide slot (not a `Context`/`FrameCtx` field) so the membrane can
//! set it without threading a new field through every Context construction site;
//! the frame builder reads it into the `Hud` each frame. Empty = no chip.

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
