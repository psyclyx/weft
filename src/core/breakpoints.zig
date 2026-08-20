//! breakpoints — a tiny process-global registry bridging the two halves of the
//! debugger: the `debug` wasm plugin (which owns the visual gutter markers, but
//! can't speak DAP's JSON) PUBLISHES its per-file breakpoint lines here, and the
//! `dap.js` client (which speaks DAP, but has no decorate/cursor membrane) READS
//! them to fill a `setBreakpoints` request. So the session stops where you
//! marked. Lines are carried as a plain "l1,l2,…" string — trivial to build in
//! wasm and to split in JS — keyed by the buffer path.
//!
//! Fixed storage (no allocator, no lifetime coupling to any editor), like the
//! other membrane globals (g_environ, flashState). Overwrite-by-path; a file's
//! whole set republishes each toggle.

const std = @import("std");

const MAX_FILES = 64;
const PATHLEN = 512;
const LINELEN = 1024;

var paths: [MAX_FILES][PATHLEN]u8 = undefined;
var plens: [MAX_FILES]usize = undefined;
var lines: [MAX_FILES][LINELEN]u8 = undefined;
var llens: [MAX_FILES]usize = undefined;
var n: usize = 0;

fn find(path: []const u8) ?usize {
    var i: usize = 0;
    while (i < n) : (i += 1) {
        if (plens[i] == path.len and std.mem.eql(u8, paths[i][0..plens[i]], path)) return i;
    }
    return null;
}

/// Replace `path`'s breakpoint set with `line_csv` (e.g. "7,12,20"). Empty CSV
/// keeps the entry (an empty set) so a cleared file reads as no breakpoints.
pub fn publish(path: []const u8, line_csv: []const u8) void {
    if (path.len > PATHLEN or line_csv.len > LINELEN) return;
    const i = find(path) orelse blk: {
        if (n >= MAX_FILES) return;
        @memcpy(paths[n][0..path.len], path);
        plens[n] = path.len;
        n += 1;
        break :blk n - 1;
    };
    @memcpy(lines[i][0..line_csv.len], line_csv);
    llens[i] = line_csv.len;
}

/// The breakpoint lines for `path` as a "l1,l2,…" CSV, or "" if none.
pub fn get(path: []const u8) []const u8 {
    const i = find(path) orelse return "";
    return lines[i][0..llens[i]];
}

test "breakpoints: publish then get, overwrite by path" {
    n = 0;
    publish("a.py", "7,12");
    publish("b.py", "3");
    try std.testing.expectEqualStrings("7,12", get("a.py"));
    try std.testing.expectEqualStrings("3", get("b.py"));
    publish("a.py", "20"); // overwrite
    try std.testing.expectEqualStrings("20", get("a.py"));
    try std.testing.expectEqualStrings("", get("missing.py"));
    n = 0;
}
