//! grep — project search over the ripgrep subprocess (design §6.6), a `.wasm`
//! plugin. Each command creates+focuses the `*grep*` tool buffer and fills it
//! asynchronously with `rg`'s matches via the native `proc` surface — the
//! output lands authored as this plugin's peer, off the frame thread. perms
//! `{proc, timer}`; grant_max edit (it only writes its own tool buffer).
//! `grep` takes an explicit pattern arg; `grep-word` lifts the identifier under
//! the cursor and searches for that — search-for-the-thing-I'm-on.

const std = @import("std");
const weft = @import("weft");
const output = @import("weft_output");

/// Scratch for the assembled shell command line (pattern + rg flags).
var cmd_buf: [1 << 12]u8 = undefined;
/// The last pattern searched, kept so the fill can emphasize its literal
/// occurrences in each result line (regex patterns simply won't match — a
/// graceful no-op, still colored file:line locations).
var pattern_buf: [1 << 10]u8 = undefined;
var pattern_len: usize = 0;

/// `params` is the command's argument shape, written the way a person reads
/// it back (`describeCommand`): the palette shows it beside the row, the `:`
/// line hints it while you type, and it is what gets ASKED for when a call
/// arrives short.
const Cmd = struct {
    name: []const u8,
    handler: *const fn () void,
    params: []const u8 = "",
    summary: []const u8 = "",
};
const cmds = [_]weft.CommandEntry{
    .{ .name = "grep", .call = grep, .params = "pattern", .summary = "Search the project for a pattern, into *grep*." },
    .{ .name = "grep-word", .call = grepWord, .summary = "Search the project for the word under the cursor." },
    .{ .name = "grep-visit", .call = output.visit, .summary = "Open the location the focused result row names." },
};

fn describeExtra() void {
    weft.requestPerm(.proc);
    weft.requestPerm(.timer);
}
fn initExtra() void {
    // `*grep*` is a results list you navigate: Return visits the location the
    // focused row carries, j/k walk the matches, q goes back.
    output.installMode("grep", "grep-visit");
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
    output.show(cmd, "*grep*", "grep");
}

/// Search for the pattern passed as arg 0; a no-op when none was given.
fn grep() void {
    const pattern = weft.argStr(0) orelse return;
    runGrep(pattern);
}

// ── Fill: capture each row's location, then color the results ──────────────
// The host fires `on_fill_token` once rg's async output has landed, bound to
// the entry that fill captured. `output.fill` records the row → location table
// (what Return navigates by) and paints the locations; grep adds what only it
// knows — a literal match of the pattern.
export fn on_fill_token(token: u32) void {
    output.fill(token, styleMatch);
}

/// Emphasize a literal occurrence of the searched pattern in a result row.
/// A regex pattern simply won't match — a graceful no-op, locations still lit.
///
/// The offsets are into the ROW, which is the line we were just handed — no
/// document position is involved, and none is available. This used to read
/// `weft.style(base + content_start + off, …)`: three numbers added up, one of
/// them (`base`) threaded down from a chunked scan of the whole buffer.
fn styleMatch(b: weft.ProjectionBuilder, node: u32, line: []const u8, at: ?output.Target) void {
    if (pattern_len == 0) return;
    const content_start = if (at) |target| target.span_end else 0;
    if (content_start >= line.len) return;
    const content = line[content_start..];
    const off = std.mem.indexOf(u8, content, pattern_buf[0..pattern_len]) orelse return;
    b.span(node, content_start + off, content_start + off + pattern_len, "output.emphasis");
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

comptime {
    weft.plugin(&cmds, .{ .describe = describeExtra, .init = initExtra }).exportAll();
}
