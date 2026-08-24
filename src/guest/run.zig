//! run — run an arbitrary shell command into a tool buffer (design §6.6), a
//! `.wasm` plugin cut from the same cloth as `git`. Each command creates+focuses
//! an `*output*` buffer and fills it asynchronously with the command's stdout via
//! the native `proc` surface — the output lands authored as this plugin's peer,
//! off the frame thread. perms `{proc, timer}`; grant_max edit (it only writes
//! its own tool buffer). The command line comes either as an arg (`run-command`)
//! or from the current buffer line (`run-line`, for scratch/command notes).

const std = @import("std");
const weft = @import("weft");

/// Scratch for the shell command line built from a buffer slice (`run-line`),
/// which borrows `weft`'s read scratch and so must be copied before use.
var cmd_buf: [1 << 12]u8 = undefined;

const out_name = "*output*";

const Cmd = struct { name: []const u8, handler: *const fn () void };
const cmds = [_]Cmd{
    .{ .name = "run-command", .handler = runCommand },
    .{ .name = "run-line", .handler = runLine },
    .{ .name = "output-visit", .handler = outputVisit },
};

export fn describe() void {
    for (cmds) |c| weft.declareCommand(c.name);
    weft.requestPerm(.proc);
    weft.requestPerm(.timer);
}
export fn init() void {
    for (cmds) |c| _ = weft.register(c.name);
    // `*output*` is navigable: Return jumps to the `file:line` under the cursor —
    // the stack frame or compile error you're looking at — j/k walk, q goes back.
    // Fallback to normal (not locked) so the visit leaves cleanly into the file.
    weft.setFallback("output", "normal");
    weft.restingMode("output"); // *output* rests in output, not the normal it falls back to
    weft.bindKey("output", "Return", "output-visit");
    weft.bindKey("output", "q", "buffer-back");
}
export fn on_command(id: u32) void {
    if (id < cmds.len) cmds[id].handler();
}

/// Create+focus the `*output*` tool buffer, then fill it with `cmd`'s output async.
fn show(cmd: []const u8) void {
    weft.runStr("buffer-create", out_name); // creates + focuses an empty scratch
    weft.setMode("output"); // navigable: Return visits a file:line under the cursor
    weft.procToBuffer(cmd, out_name);
}

/// Return in `*output*`: jump to the `file:line` under the cursor. Unlike grep's
/// fixed `path:line:` prefix, a compiler/runtime line carries the location
/// anywhere — zig `src/foo.zig:10:5: error`, node `at f (/abs/app.js:4:13)` — so
/// we scan the line for the first `<path>:<digits>` whose path looks like a file
/// (has a `.` or `/`), stopping the path at a space/quote/paren boundary.
var path_buf: [1024]u8 = undefined;
fn outputVisit() void {
    const l = weft.lineAt(weft.cursor());
    const text = weft.slice(l.start, l.end); // borrows the read scratch
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (text[i] != ':') continue;
        var j = i + 1;
        const ds = j;
        while (j < text.len and text[j] >= '0' and text[j] <= '9') j += 1;
        if (j == ds) continue; // no digits after the colon → not a location
        // Walk back to the path start (stop at a separator).
        var s = i;
        while (s > 0) : (s -= 1) {
            const c = text[s - 1];
            if (c == ' ' or c == '\t' or c == '(' or c == ')' or c == '"' or c == '\'' or c == ':') break;
        }
        const path = text[s..i];
        // Require it to look like a file, so "12:34" (a time, a ratio) is ignored.
        if (path.len == 0) continue;
        if (std.mem.indexOfScalar(u8, path, '.') == null and std.mem.indexOfScalar(u8, path, '/') == null) continue;
        var line_no: usize = 0;
        for (text[ds..j]) |d| line_no = line_no * 10 + (d - '0');
        const pn = @min(path.len, path_buf.len);
        @memcpy(path_buf[0..pn], path[0..pn]); // copy out of scratch before open reuses it
        weft.runStr("open", path_buf[0..pn]);
        weft.jump(lineStartOffset(line_no));
        return;
    }
}

/// Byte offset of the start of 1-based line `n` in the active buffer (clamped to
/// EOF), scanning in scratch-sized chunks so a long file still resolves.
fn lineStartOffset(n: usize) usize {
    if (n <= 1) return 0;
    var line: usize = 1;
    var pos: usize = 0;
    const total = weft.byteLen();
    while (pos < total) {
        const chunk = weft.slice(pos, total);
        if (chunk.len == 0) break;
        for (chunk, 0..) |ch, k| {
            if (ch == '\n') {
                line += 1;
                if (line == n) return pos + k + 1;
            }
        }
        pos += chunk.len;
    }
    return pos;
}
/// Run the command line passed as arg 0; no-op if none was given.
fn runCommand() void {
    const cmd = weft.argStr(0) orelse return;
    show(cmd);
}
/// Run the current line of the buffer as a shell command.
fn runLine() void {
    const l = weft.lineAt(weft.cursor());
    const line = weft.slice(l.start, l.end); // borrows read scratch
    // Copy out of the read scratch — `procToBuffer`/`runStr` need it stable.
    const cmd = std.fmt.bufPrint(&cmd_buf, "{s}", .{line}) catch return;
    show(cmd);
}
