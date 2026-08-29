//! numbers — increment/decrement the integer under the cursor (vim CTRL-A /
//! CTRL-X), a `.wasm` plugin with NO core privilege beyond the edit door
//! (perms `{}`, edit). Each command finds the decimal run at or after the
//! cursor ON THE CURRENT LINE (weft.lineAt + weft.slice), parses it to i64,
//! adds ±1, and writes the new text back through the gated edit door, leaving
//! the cursor on the last digit. It is PURE policy over a read-only snapshot:
//! all scanning/formatting happens in fixed module scratch, no allocator.

const std = @import("std");
const weft = @import("weft");

/// Registration order == the id the host hands `on_command`.
const Cmd = struct { name: []const u8, handler: *const fn () void };
const cmds = [_]Cmd{
    .{ .name = "increment-number", .handler = increment },
    .{ .name = "decrement-number", .handler = decrement },
};

export fn describe() void {
    for (cmds) |c| weft.declareCommand(c.name);
}
export fn init() void {
    for (cmds) |c| _ = weft.register(c.name);
}
export fn on_command(id: u32) void {
    if (id < cmds.len) cmds[id].handler();
}

fn increment() void {
    bump(1);
}
fn decrement() void {
    bump(-1);
}

/// Fixed scratch for the formatted replacement. 24 bytes covers any i64
/// (`-9223372036854775808` is 20 chars) with room to spare.
var numbuf: [24]u8 = undefined;

/// Find the decimal run at/after the cursor on the current line, add `delta`,
/// and replace it — cursor on the last digit. No-op if the line has no run.
fn bump(delta: i64) void {
    const cur = weft.cursor();
    const line = weft.lineAt(cur);
    const t = weft.slice(line.start, line.end); // borrows shim scratch
    const ci = cur - line.start; // cursor index within the line

    // First digit at or after the cursor; nothing to do if the rest is digitless.
    var d = ci;
    while (d < t.len and !std.ascii.isDigit(t[d])) d += 1;
    if (d >= t.len) return;

    // Expand to the maximal digit run, then fold in a leading '-' (negatives).
    var s = d;
    while (s > 0 and std.ascii.isDigit(t[s - 1])) s -= 1;
    if (s > 0 and t[s - 1] == '-') s -= 1;
    var e = d;
    while (e < t.len and std.ascii.isDigit(t[e])) e += 1;

    // Parse (saturating, so a wildly long run clamps rather than wraps), step,
    // format. `t` is not read again before the edit, so it stays valid.
    const val = parse(t[s..e]);
    const next = if (delta >= 0) val +| delta else val -| (-delta);
    const out = format(next);

    weft.edit(.{ .start = line.start + s, .end = line.start + e }, out);
    // Last digit of the new text: run start + (length - 1), still a digit even
    // for a negative (the '-' leads).
    weft.jump(line.start + s + out.len - 1);
}

/// Parse an optional-sign decimal to i64, saturating on overflow.
fn parse(s: []const u8) i64 {
    var i: usize = 0;
    const neg = s.len > 0 and s[0] == '-';
    if (neg) i += 1;
    var v: i64 = 0;
    while (i < s.len) : (i += 1) v = v *| 10 +| @as(i64, s[i] - '0');
    return if (neg) 0 -| v else v;
}

/// Format `v` as decimal into `numbuf`, returning the written slice.
fn format(v: i64) []const u8 {
    // Magnitude via two's-complement negation in u64 (handles i64 min).
    const neg = v < 0;
    var m: u64 = if (neg) ~@as(u64, @bitCast(v)) + 1 else @intCast(v);
    var i: usize = numbuf.len;
    if (m == 0) {
        i -= 1;
        numbuf[i] = '0';
    } else while (m > 0) : (m /= 10) {
        i -= 1;
        numbuf[i] = '0' + @as(u8, @intCast(m % 10));
    }
    if (neg) {
        i -= 1;
        numbuf[i] = '-';
    }
    return numbuf[i..];
}
