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
/// The last pattern searched, kept so `on_fill` can emphasize its literal
/// occurrences in each result line (regex patterns simply won't match — a
/// graceful no-op, still colored file:line locations).
var pattern_buf: [1 << 10]u8 = undefined;
var pattern_len: usize = 0;

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
    pattern_len = @min(pattern.len, pattern_buf.len);
    @memcpy(pattern_buf[0..pattern_len], pattern[0..pattern_len]);
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

// ── Styling: color the `*grep*` results (file:line locations + match) ───────
// The host fires `on_fill` once rg's async output has landed, with `*grep*`
// active, so we read + paint the active buffer. Each `rg --no-heading
// --line-number` line is `path:line:content`; color the `path:line:` prefix as
// a location and a literal match of the pattern in the content as emphasis.
export fn on_fill() void {
    const name = activeName();
    if (!std.mem.eql(u8, name, "*grep*")) return;
    weft.styleClear();
    const text = weft.slice(0, weft.byteLen()); // clamped to the read scratch
    var i: usize = 0;
    while (i < text.len) {
        var e = i;
        while (e < text.len and text[e] != '\n') e += 1;
        styleGrepLine(i, text[i..e]);
        i = e + 1;
    }
}

var name_buf: [256]u8 = undefined;
/// The active buffer's name, copied out of the shared read scratch.
fn activeName() []const u8 {
    const count = weft.bufferCount();
    var i: usize = 0;
    while (i < count) : (i += 1) {
        if (!weft.bufferActive(i)) continue;
        const bn = weft.bufferName(i) orelse return "";
        const n = @min(bn.len, name_buf.len);
        @memcpy(name_buf[0..n], bn[0..n]);
        return name_buf[0..n];
    }
    return "";
}

fn styleGrepLine(base: usize, line: []const u8) void {
    const c1 = std.mem.indexOfScalar(u8, line, ':') orelse return;
    var j = c1 + 1;
    const ds = j;
    while (j < line.len and line[j] >= '0' and line[j] <= '9') j += 1;
    if (j == ds or j >= line.len or line[j] != ':') return; // not path:line:
    const prefix_end = j + 1;
    weft.style(base, base + prefix_end, .location);
    if (pattern_len > 0) {
        const content = line[prefix_end..];
        if (std.mem.indexOf(u8, content, pattern_buf[0..pattern_len])) |off|
            weft.style(base + prefix_end + off, base + prefix_end + off + pattern_len, .emphasis);
    }
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
