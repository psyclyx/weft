//! git — a magit-lite over the git subprocess (design §6.6), a `.wasm` plugin.
//! Read verbs (status/log/diff/blame) create+focus a tool buffer and fill it
//! asynchronously with a git invocation via the native `proc` surface — the
//! output lands authored as this plugin's peer, off the frame thread. The
//! *git-status* buffer runs its own `magit` keymap mode: navigation-only, plus
//! the interactive verbs (stage/unstage/commit/push/pull/…). Each index-mutating
//! verb chains its git call with a status re-read in ONE shell command, so the
//! buffer always reflects the post-mutation index (no async read/write race).
//! perms `{proc, timer, fs_write}` — fs_write only to drop the commit message in
//! a temp file for `git commit -F`. grant_max edit (it authors its own buffers).

const std = @import("std");
const weft = @import("weft.zig");

var cmd_buf: [1 << 12]u8 = undefined;
/// Copy target for the commit message read out of the *git-commit* buffer,
/// before the temp-file write (keeps the bytes out of the shared read scratch).
var msg_buf: [1 << 16]u8 = undefined;

/// The temp file the commit message lands in for `git commit -F` — cwd-relative,
/// the same locus the shell command runs in. Removed right after the commit.
const commit_tmp = ".weft-commit-msg";

const status_cmd = "git status --short --branch";

const Cmd = struct { name: []const u8, handler: *const fn () void };
const cmds = [_]Cmd{
    .{ .name = "git-status", .handler = gitStatus },
    .{ .name = "git-log", .handler = gitLog },
    .{ .name = "git-diff", .handler = gitDiff },
    .{ .name = "git-diff-staged", .handler = gitDiffStaged },
    .{ .name = "git-blame", .handler = gitBlame },
    // magit-style verbs, live in the *git-status* buffer's own mode.
    .{ .name = "git-stage", .handler = gitStage },
    .{ .name = "git-unstage", .handler = gitUnstage },
    .{ .name = "git-stage-all", .handler = gitStageAll },
    .{ .name = "git-unstage-all", .handler = gitUnstageAll },
    .{ .name = "git-refresh", .handler = gitStatus },
    .{ .name = "git-open", .handler = gitOpen },
    .{ .name = "git-diff-file", .handler = gitDiffFile },
    // sync verbs → *git-output* (async; stderr folded in so progress shows).
    .{ .name = "git-push", .handler = gitPush },
    .{ .name = "git-pull", .handler = gitPull },
    .{ .name = "git-fetch", .handler = gitFetch },
    // commit: an editable *git-commit* buffer + a C-c prefix to finish/abort.
    .{ .name = "git-commit", .handler = gitCommit },
    .{ .name = "git-commit-finish", .handler = gitCommitFinish },
    .{ .name = "git-commit-abort", .handler = gitCommitAbort },
    .{ .name = "git-commit-resume", .handler = gitCommitResume },
};

export fn describe() void {
    for (cmds) |c| weft.declareCommand(c.name);
    weft.requestPerm(.proc);
    weft.requestPerm(.timer);
    weft.requestPerm(.fs_write); // only to stage the commit message for `-F`
}
export fn init() void {
    for (cmds) |c| _ = weft.register(c.name);
    // The magit-style keymap is navigation-only: it swallows typing (the status
    // list isn't editable) and binds movement + its verbs — no fallback to
    // normal, so there's no insert leak into the tool buffer.
    weft.textInput("magit", null);
    weft.bindKey("magit", "j", "cursor-down");
    weft.bindKey("magit", "k", "cursor-up");
    weft.bindKey("magit", "Down", "cursor-down");
    weft.bindKey("magit", "Up", "cursor-up");
    weft.bindKey("magit", "s", "git-stage");
    weft.bindKey("magit", "u", "git-unstage");
    weft.bindKey("magit", "S", "git-stage-all");
    weft.bindKey("magit", "U", "git-unstage-all");
    weft.bindKey("magit", "c", "git-commit");
    weft.bindKey("magit", "d", "git-diff-file");
    weft.bindKey("magit", "P", "git-push");
    weft.bindKey("magit", "F", "git-pull");
    weft.bindKey("magit", "f", "git-fetch");
    weft.bindKey("magit", "g", "git-refresh");
    weft.bindKey("magit", "Return", "git-open");
    weft.bindKey("magit", "q", "buf-scratch");

    // The commit message buffer is an EDITABLE mode: fall back to `default` so
    // it inherits the core text command (insert-text) + editing keys, then layer
    // a C-c prefix on top. The keymap is single-keyspec, so the C-c C-c / C-c C-k
    // chords are a one-shot prefix menu-mode: C-c enters `git-commit-menu`
    // (recording git-commit as its return target), and its keys finish/abort/
    // resume. finish/abort switch the mode themselves, so the menu's auto-return
    // stays out of the way.
    weft.setFallback("git-commit", "default");
    weft.bindKey("git-commit", "C-c", "git-commit-menu");
    weft.menuMode("git-commit-menu"); // C-c prefix: swallows stray text
    weft.bindKey("git-commit-menu", "C-c", "git-commit-finish");
    weft.bindKey("git-commit-menu", "C-k", "git-commit-abort");
    weft.bindKey("git-commit-menu", "Escape", "git-commit-resume");
    weft.bindKey("git-commit-menu", "C-g", "git-commit-resume");
}
export fn on_command(id: u32) void {
    if (id < cmds.len) cmds[id].handler();
}

// ── Styling: color the tool buffers like magit ──────────────────────────
// The host fires `on_fill` once a tool buffer's async output has landed, with
// that buffer active — so we read + paint the ACTIVE buffer (byteLen/slice/
// style all target it, like edit does). We classify line by line into
// StyleClass spans; the view renders them through the theme.
var name_buf: [256]u8 = undefined;

/// The active buffer's name, copied out of the shared read scratch (so it
/// survives the `slice` reads below), or "" if none.
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

export fn on_fill() void {
    const name = activeName();
    if (std.mem.eql(u8, name, "*git-diff*") or std.mem.eql(u8, name, "*git-diff-staged*")) {
        classify(styleDiffLine);
    } else if (std.mem.eql(u8, name, "*git-status*")) {
        classify(styleStatusLine);
    } else if (std.mem.eql(u8, name, "*git-log*")) {
        classify(styleLogLine);
    }
}

/// Drive a per-line classifier over the (scratch-clamped) buffer text: baseline
/// with `styleClear`, then hand each line its absolute start + bytes. Offsets
/// index the slice from 0, so a slice index IS the absolute document offset.
fn classify(line_fn: *const fn (base: usize, line: []const u8) void) void {
    weft.styleClear();
    const text = weft.slice(0, weft.byteLen()); // clamped to the read scratch
    var i: usize = 0;
    while (i < text.len) {
        var e = i;
        while (e < text.len and text[e] != '\n') e += 1;
        line_fn(i, text[i..e]);
        i = e + 1;
    }
}

/// A unified-diff line: hunk headers, +/- content, and the file/index preamble.
fn styleDiffLine(base: usize, line: []const u8) void {
    if (line.len == 0) return;
    const cls: weft.StyleClass = if (std.mem.startsWith(u8, line, "diff --git") or
        std.mem.startsWith(u8, line, "index "))
        .muted
    else if (std.mem.startsWith(u8, line, "+++ ") or std.mem.startsWith(u8, line, "--- "))
        .muted // the file markers, not content adds/removes
    else if (std.mem.startsWith(u8, line, "@@"))
        .header
    else switch (line[0]) {
        '+' => .added,
        '-' => .removed,
        else => .normal,
    };
    if (cls != .normal) weft.style(base, base + line.len, cls);
}

/// A `git status --short --branch` line: the `##` branch header, staged (index
/// column set) vs unstaged (worktree column) vs untracked (`??`).
fn styleStatusLine(base: usize, line: []const u8) void {
    if (line.len < 2) return;
    const cls: weft.StyleClass = if (line[0] == '#' and line[1] == '#')
        .header
    else if (line[0] == '?' and line[1] == '?')
        .muted // untracked
    else if (line[0] != ' ')
        .added // staged: the index column carries a change
    else
        .removed; // unstaged worktree change
    weft.style(base, base + line.len, cls);
}

/// A `git log --oneline --graph` line: skip the graph gutter, color the short
/// hash as a location and any `(refs)` decoration as a header.
fn styleLogLine(base: usize, line: []const u8) void {
    var i: usize = 0;
    while (i < line.len and isGraph(line[i])) i += 1;
    var h = i;
    while (h < line.len and isHex(line[h])) h += 1;
    if (h == i) return; // no hash on this line (a pure graph connector)
    weft.style(base + i, base + h, .location);
    var j = h;
    while (j < line.len and line[j] == ' ') j += 1;
    if (j < line.len and line[j] == '(') {
        var k = j;
        while (k < line.len and line[k] != ')') k += 1;
        if (k < line.len) k += 1; // include the ')'
        weft.style(base + j, base + k, .header);
    }
}

fn isGraph(c: u8) bool {
    return c == '*' or c == '|' or c == '/' or c == '\\' or c == ' ' or c == '_' or c == '.';
}
fn isHex(c: u8) bool {
    return (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f');
}

/// The path on the current *git-status* line: `git status --short` prints
/// "XY path" (status in cols 0-1, path from col 3), so drop the leading status
/// field. Returns "" for a header line (e.g. the `## branch` line). Copied out
/// of the shared scratch into `path_buf` before any further membrane call.
var path_buf: [512]u8 = undefined;
fn currentPath() []const u8 {
    const line = weft.lineAt(weft.cursor());
    const raw = weft.slice(line.start, line.end);
    if (raw.len < 4 or (raw[0] == '#' and raw[1] == '#')) return "";
    const rel = std.mem.trim(u8, raw[3..], " \t\r\n");
    const n = @min(rel.len, path_buf.len);
    @memcpy(path_buf[0..n], rel[0..n]);
    return path_buf[0..n];
}

/// Run `idx_cmd` (a git index mutation) then re-read the status into the
/// *git-status* buffer — one shell command so the status reflects the mutation
/// (no async race) — and stay in the magit mode.
fn stageThenRefresh(idx_cmd: []const u8) void {
    const cmd = std.fmt.bufPrint(&cmd_buf, "{s} && " ++ status_cmd, .{idx_cmd}) catch return;
    show(cmd, "*git-status*");
    weft.setMode("magit");
}

/// Stage / unstage the file under the cursor, then refresh.
fn gitStage() void {
    const path = currentPath();
    if (path.len == 0) return;
    const cmd = std.fmt.bufPrint(&cmd_buf, "git add -- '{s}' && " ++ status_cmd, .{path}) catch return;
    show(cmd, "*git-status*");
    weft.setMode("magit");
}
fn gitUnstage() void {
    const path = currentPath();
    if (path.len == 0) return;
    const cmd = std.fmt.bufPrint(&cmd_buf, "git reset -q HEAD -- '{s}' && " ++ status_cmd, .{path}) catch return;
    show(cmd, "*git-status*");
    weft.setMode("magit");
}
fn gitStageAll() void {
    stageThenRefresh("git add -A");
}
fn gitUnstageAll() void {
    stageThenRefresh("git reset -q HEAD");
}
fn gitOpen() void {
    const path = currentPath();
    if (path.len == 0) return;
    weft.runStr("open", path);
}
/// Diff the file under the cursor into *git-diff*.
fn gitDiffFile() void {
    const path = currentPath();
    if (path.len == 0) return;
    const cmd = std.fmt.bufPrint(&cmd_buf, "git diff -- '{s}'", .{path}) catch return;
    show(cmd, "*git-diff*");
}

// ── sync verbs: async into *git-output* (2>&1 so git's stderr progress shows) ──
fn gitPush() void {
    show("git push 2>&1", "*git-output*");
}
fn gitPull() void {
    show("git pull 2>&1", "*git-output*");
}
fn gitFetch() void {
    show("git fetch 2>&1", "*git-output*");
}

// ── commit ────────────────────────────────────────────────────────────
/// Focus the existing buffer named `name`, if any (avoids piling up duplicate
/// *git-commit* buffers across commits). Returns whether one was found.
fn focusBuffer(name: []const u8) bool {
    const count = weft.bufferCount();
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const bn = weft.bufferName(i) orelse continue;
        if (std.mem.eql(u8, bn, name)) {
            const id = weft.bufferId(i) orelse return false;
            weft.runInt("buffer-switch", id);
            return true;
        }
    }
    return false;
}

/// Open an editable *git-commit* buffer for the message. C-c C-c commits,
/// C-c C-k aborts.
fn gitCommit() void {
    if (!focusBuffer("*git-commit*")) weft.runStr("buffer-create", "*git-commit*");
    weft.edit(.{ .start = 0, .end = weft.byteLen() }, ""); // start from a blank message
    weft.jump(0);
    weft.setMode("git-commit");
    weft.echo("commit: C-c C-c to commit, C-c C-k to abort");
}
/// Write the message buffer to a temp file, `git commit -F` it, then refresh the
/// status. Uses `-F <file>` (not `-m`) so multi-line messages and quotes need no
/// escaping. Commit stdout/stderr is discarded so the *git-status* buffer stays
/// a clean, parseable status; the branch header reflects the new HEAD.
fn gitCommitFinish() void {
    const text = weft.slice(0, weft.byteLen());
    const n = @min(text.len, msg_buf.len);
    @memcpy(msg_buf[0..n], text[0..n]);
    _ = weft.fsWrite(commit_tmp, msg_buf[0..n]);
    const cmd = std.fmt.bufPrint(
        &cmd_buf,
        "git commit -F {s} >/dev/null 2>&1; rm -f {s}; " ++ status_cmd,
        .{ commit_tmp, commit_tmp },
    ) catch return;
    show(cmd, "*git-status*");
    weft.setMode("magit");
}
/// Cancel the commit: drop the message, back to a fresh status view.
fn gitCommitAbort() void {
    show(status_cmd, "*git-status*");
    weft.setMode("magit");
}
/// Leave the C-c prefix, back to editing the commit message.
fn gitCommitResume() void {
    weft.setMode("git-commit");
}

/// Create+focus the tool buffer, then fill it with `cmd`'s output async.
fn show(cmd: []const u8, name: []const u8) void {
    weft.runStr("buffer-create", name); // creates + focuses an empty scratch
    weft.procToBuffer(cmd, name);
}
fn gitStatus() void {
    show(status_cmd, "*git-status*");
    weft.setMode("magit"); // rich status buffer: s stage, u unstage, g refresh
}
fn gitLog() void {
    show("git log --oneline --graph -30", "*git-log*");
}
fn gitDiff() void {
    show("git diff", "*git-diff*");
}
fn gitDiffStaged() void {
    show("git diff --staged", "*git-diff-staged*");
}
fn gitBlame() void {
    const path = weft.path() orelse return;
    const cmd = std.fmt.bufPrint(&cmd_buf, "git blame -- {s}", .{path}) catch return;
    show(cmd, "*git-blame*");
}
