//! grep — project search over the ripgrep subprocess (design §6.6), a `.wasm`
//! plugin. Each command creates+focuses the `*grep*` tool buffer and fills it
//! asynchronously with `rg`'s matches via the native `proc` surface — the
//! output lands authored as this plugin's peer, off the frame thread. perms
//! `{proc, timer}`; grant_max edit (it only writes its own tool buffer).
//! `grep` takes an explicit pattern arg; `grep-word` lifts the identifier under
//! the cursor and searches for that — search-for-the-thing-I'm-on.

const std = @import("std");
const weft = @import("weft.zig");

/// Scratch for the assembled shell command line (pattern + rg flags).
var cmd_buf: [1 << 12]u8 = undefined;

const Cmd = struct { name: []const u8, handler: *const fn () void };
const cmds = [_]Cmd{
    .{ .name = "grep", .handler = grep },
    .{ .name = "grep-word", .handler = grepWord },
};

export fn describe() void {
    for (cmds) |c| weft.declareCommand(c.name);
    weft.requestPerm(.proc);
    weft.requestPerm(.timer);
}
export fn init() void {
    for (cmds) |c| _ = weft.register(c.name);
}
export fn on_command(id: u32) void {
    if (id < cmds.len) cmds[id].handler();
}

/// An identifier byte — the run `grep-word` grows around the cursor.
fn isWord(ch: u8) bool {
    return ch == '_' or (ch >= '0' and ch <= '9') or
        (ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z');
}

/// Create+focus `*grep*`, then fill it with `rg`'s matches for `pattern` async.
/// The pattern is single-quoted so shell metacharacters in a simple pattern are
/// inert (embedded single quotes are the one gap left for a later version), and
/// `--` ends rg's options so a leading `-` in the pattern isn't read as a flag.
fn runGrep(pattern: []const u8) void {
    if (pattern.len == 0) return; // empty pattern → no-op
    const cmd = std.fmt.bufPrint(
        &cmd_buf,
        "rg --line-number --no-heading --color=never -- '{s}'",
        .{pattern},
    ) catch return;
    weft.runStr("buffer-create", "*grep*"); // creates + focuses an empty scratch
    weft.procToBuffer(cmd, "*grep*");
}

/// Search for the pattern passed as arg 0; a no-op when none was given.
fn grep() void {
    const pattern = weft.argStr(0) orelse return;
    runGrep(pattern);
}

/// Search for the identifier run surrounding the cursor.
fn grepWord() void {
    const cur = weft.cursor();
    const line = weft.lineAt(cur);
    const text = weft.slice(line.start, line.end); // borrows scratch
    if (text.len == 0) return;
    // The cursor's index within the line (clamped inside it).
    var i = cur - line.start;
    if (i >= text.len) i = text.len - 1;
    if (!isWord(text[i])) return; // not on a word → nothing to search
    // Grow left/right to the identifier's bounds.
    var lo = i;
    while (lo > 0 and isWord(text[lo - 1])) lo -= 1;
    var hi = i + 1;
    while (hi < text.len and isWord(text[hi])) hi += 1;
    runGrep(text[lo..hi]);
}
