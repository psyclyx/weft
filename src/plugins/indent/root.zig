//! indent — line indent/dedent operators, a `.wasm` plugin with NO core
//! privilege beyond the edit door (perms `{}`, grant_max edit). `indent.increase` adds
//! one indent unit at the START of each line a range spans; `indent.decrease` peels one
//! off. They ride vim's operator-pending machinery exactly like comment.toggle, so
//! `>ip`, `>j`, `>>`, `<<` and visual `>`/`<` all compose. The unit is two spaces,
//! hardcoded for now (a shiftwidth/expandtab config comes with the same work that
//! makes comment's token language-aware).

const std = @import("std");
const weft = @import("weft");
const statusline = @import("weft_statusline");

/// One indent level. Two spaces — the web/JS default and what the harness fixtures
/// use. Dedent peels leading spaces up to this width, or a single leading tab.
const unit = "  ";

const cmds = [_]weft.CommandEntry{
    .{ .name = "indent.increase", .arity = weft.Arity.each_extent, .call = opIndent, .summary = "Indent the non-blank lines of the operator's range.", .internal = true },
    .{ .name = "indent.decrease", .arity = weft.Arity.each_extent, .call = opDedent, .summary = "Dedent the lines of the operator's range.", .internal = true },
};

/// Whether the line has no non-whitespace content (indent skips blank lines, as
/// vim's `>` does — no trailing indent left dangling on empty rows).
fn isBlank(text: []const u8) bool {
    for (text) |ch| {
        if (ch != ' ' and ch != '\t') return false;
    }
    return true;
}

/// Line starts of the spanned lines; a fixed cap (huge spans truncate).
var starts: [1 << 12]usize = undefined;

/// Collect the start of each line `[start, end)` touches; returns the count.
fn collect(start: usize, end: usize) usize {
    var count: usize = 0;
    var off = start;
    while (count < starts.len) {
        const l = weft.lineAt(off);
        starts[count] = l.start;
        count += 1;
        const next = l.end + 1; // start of the following line (past the newline)
        if (next >= end or next <= off) break; // reached / passed the end, or EOF
        off = next;
    }
    return count;
}

/// Add or peel one indent unit on every line the span touches. Bottom-up, so
/// each edit sits below the lines still to come and never shifts their starts.
fn indentSpan(start: usize, end: usize, dedent: bool) void {
    var k = collect(start, end);
    while (k > 0) {
        k -= 1;
        const l = weft.lineAt(starts[k]);
        const text = weft.slice(l.start, l.end); // borrows scratch; used before any next read
        if (dedent) {
            // Peel leading spaces up to a unit's width, or one leading tab.
            var rl: usize = 0;
            while (rl < unit.len and rl < text.len and text[rl] == ' ') rl += 1;
            if (rl == 0 and text.len > 0 and text[0] == '\t') rl = 1;
            if (rl > 0) weft.edit(.{ .start = l.start, .end = l.start + rl }, "");
        } else {
            if (isBlank(text)) continue; // don't indent empty rows
            weft.edit(.{ .start = l.start, .end = l.start }, unit); // static literal — scratch intact
        }
    }
}

/// The `>` operator: indent the awaited range's lines. Composes with every motion
/// and text object (`>ip`, `>j`) and — via vim.operate-line — `>>` on the current line.
fn opIndent() void {
    const h = weft.argRange(0) orelse return;
    const r = weft.rangeEnds(h) orelse return;
    indentSpan(r.start, r.end, false);
}
/// The `<` operator: dedent the awaited range's lines.
fn opDedent() void {
    const h = weft.argRange(0) orelse return;
    const r = weft.rangeEnds(h) orelse return;
    indentSpan(r.start, r.end, true);
}

// ── The indentation, on the status line (doc/chrome.md §4.3) ─────────────────
//
// What one indent step here is — this plugin's unit, the only indentation
// weft knows — among the right-hand facts of a text entry.

fn init() void {
    // After the position and the selection count (45, 44), before the
    // language (40).
    statusline.bind(.{ .all = &.{.{ .posture = "text" }} }, .core, 43);
}

fn onSlotFire(session: i32) callconv(.c) void {
    const handle: u32 = @bitCast(session);
    _ = statusline.ask(handle) orelse return;
    const tabs = std.mem.indexOfScalar(u8, unit, '\t') != null;
    var full: [24]u8 = undefined;
    var short: [8]u8 = undefined;
    statusline.tell(handle, &.{.{
        .text = if (tabs) "Tabs" else std.fmt.bufPrint(&full, "Spaces: {d}", .{unit.len}) catch "Spaces",
        .compact = if (tabs) "" else std.fmt.bufPrint(&short, "sp{d}", .{unit.len}) catch "",
        .role = .muted,
        .right = true,
        .priority = 30,
        .tooltip = "Indentation",
    }});
}

comptime {
    weft.plugin(&cmds, .{ .init = init }).exportAll();
    weft.exportCallback("on_slot_fire", &onSlotFire);
}
