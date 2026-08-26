//! Which recordable instrument this run was asked for.
//!
//! The dispatch-latency baseline and the popup-layout goldens share one
//! compiled binary (build.zig's `instrument_mod`): a record flag has to be
//! comptime, and one module is one compilation instead of two. Sharing a binary
//! must not mean sharing a RUN — iterating on the goldens should not pay three
//! minutes of keystroke timing — so each step names its instrument in the
//! environment and the instruments this run wasn't asked for skip.
//!
//! Unset means "run everything", which is what the `test` step's own binary
//! gets: there, both instruments belong to the suite.

const std = @import("std");

pub fn selected(name: []const u8) bool {
    const want = std.c.getenv("WEFT_INSTRUMENT") orelse return true;
    return std.mem.eql(u8, std.mem.span(want), name);
}
