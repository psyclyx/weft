//! grep — project search over the ripgrep subprocess (design §6.6), a `.wasm`
//! plugin. Each command creates+focuses the `*grep*` tool buffer and fills it
//! asynchronously with `rg`'s matches via the native `proc` surface — the
//! output lands authored as this plugin's peer, off the frame thread. perms
//! `{proc, timer}`; grant_max edit (it only writes its own tool buffer).
//! `grep` takes an explicit pattern arg; `grep-word` lifts the identifier under
//! the cursor and searches for that — search-for-the-thing-I'm-on.

const std = @import("std");
const weft = @import("weft");

/// Scratch for the assembled shell command line (pattern + rg flags).
var cmd_buf: [1 << 12]u8 = undefined;
/// The last pattern searched, kept so `on_fill_token` can emphasize its literal
/// occurrences in each result line (regex patterns simply won't match — a
/// graceful no-op, still colored file:line locations).
var pattern_buf: [1 << 10]u8 = undefined;
var pattern_len: usize = 0;

/// The one fill this plugin issues; the host hands it back at delivery.
const fill_results: u32 = 1;

const Cmd = struct { name: []const u8, handler: *const fn () void };
const cmds = [_]Cmd{
    .{ .name = "grep", .handler = grep },
    .{ .name = "grep-word", .handler = grepWord },
    .{ .name = "grep-visit", .handler = grepVisit },
};

export fn describe() void {
    for (cmds) |c| weft.declareCommand(c.name);
    weft.requestPerm(.proc);
    weft.requestPerm(.timer);
}
export fn init() void {
    for (cmds) |c| _ = weft.register(c.name);
    // `*grep*` is a results list you navigate: Return visits the `path:line`
    // under the cursor, j/k walk the matches, q goes back. Fallback to `normal`
    // (not a LOCKED mode) — like dired — so visiting a result leaves cleanly into
    // the file's normal mode (a locked mode refuses to switch out; see
    // Keymap.mayLeaveLocked).
    weft.setFallback("grep", "normal");
    weft.restingMode("grep"); // *grep* rests in grep, not the normal it falls back to
    weft.bindKey("grep", "Return", "grep-visit");
    weft.bindKey("grep", "j", "cursor-down");
    weft.bindKey("grep", "k", "cursor-up");
    weft.bindKey("grep", "Down", "cursor-down");
    weft.bindKey("grep", "Up", "cursor-up");
    weft.bindKey("grep", "q", "buffer-back");
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
    weft.setMode("grep"); // navigable results list (Return visits, j/k walk)
    weft.procToBuffer(cmd, "*grep*", fill_results);
}

/// Return in `*grep*`: open the file at the `path:line` under the cursor. rg
/// emits `path:line:content`; we reuse that shape (the same prefix on_fill
/// colors as a location) to navigate — grep results you can actually jump to.
fn grepVisit() void {
    const l = weft.lineAt(weft.cursor());
    const text = weft.slice(l.start, l.end); // borrows the read scratch
    const c1 = std.mem.indexOfScalar(u8, text, ':') orelse return;
    var j = c1 + 1;
    const ds = j;
    while (j < text.len and text[j] >= '0' and text[j] <= '9') j += 1;
    if (j == ds) return; // no line number → not a result line
    // Parse the line number and copy the path OUT of the scratch before opening
    // (open reuses the read scratch, which would clobber `text`).
    var line_no: usize = 0;
    for (text[ds..j]) |d| line_no = line_no * 10 + (d - '0');
    const path = text[0..c1];
    const path_copy = weft.allocator.dupe(u8, path) catch {
        weft.echo("grep: out of memory copying path");
        return;
    };
    defer weft.allocator.free(path_copy);
    weft.runStr("open", path_copy);
    weft.jump(lineStartOffset(line_no));
}

/// Byte offset of the start of 1-based line `n` in the active buffer (clamped to
/// EOF), scanning in scratch-sized chunks so a long file still resolves.
fn lineStartOffset(n: usize) usize {
    if (n <= 1) return 0;
    var line: usize = 1;
    var pos: usize = 0;
    const total = weft.byteLen();
    while (pos < total) {
        const s = weft.slice(pos, total);
        if (s.len == 0) break;
        for (s, 0..) |ch, k| {
            if (ch == '\n') {
                line += 1;
                if (line == n) return pos + k + 1;
            }
        }
        pos += s.len;
    }
    return pos;
}

/// Search for the pattern passed as arg 0; a no-op when none was given.
fn grep() void {
    const pattern = weft.argStr(0) orelse return;
    runGrep(pattern);
}

// ── Styling: color the `*grep*` results (file:line locations + match) ───────
// The host fires `on_fill_token` once rg's async output has landed, bound to
// the entry the fill captured — so we read + paint THAT entry whatever is
// focused. Each `rg --no-heading --line-number` line is `path:line:content`;
// color the `path:line:` prefix as a location and a literal match of the
// pattern in the content as emphasis.
export fn on_fill_token(token: u32) void {
    if (token != fill_results) return;
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
