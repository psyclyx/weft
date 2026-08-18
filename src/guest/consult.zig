//! consult — navigation sources over the pick seam (design §6.4), a `.wasm`
//! plugin with perms `{}` (view). A source gathers candidates, opens a pick,
//! and on accept resolves the CHOSEN ROW (by its add-order index, not its
//! text) to a position it recorded at add time — so jumping to a line is
//! unambiguous even when two lines read identically. `consult-line` is the
//! first source; grep/imenu/mark join as their inputs (proc, symbols) land.

const std = @import("std");
const weft = @import("weft.zig");

const line_pick = 0;

/// Per-row line-start offsets, parallel to the pickAdd order. The accepted
/// index maps straight into this — the robustness the string alone can't give.
var starts: [1 << 15]usize = undefined;
var n_rows: usize = 0;

const Cmd = struct { name: []const u8, handler: *const fn () void };
const cmds = [_]Cmd{
    .{ .name = "consult-line", .handler = consultLine },
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
export fn on_pick_accept(pick_id: u32) void {
    if (pick_id != line_pick) return;
    const i = weft.pickChoiceIndex() orelse return; // free text → ignore
    if (i < n_rows) weft.jump(starts[i]);
}

/// Fuzzy-pick a line in the current buffer and jump to its start.
fn consultLine() void {
    n_rows = 0;
    weft.pickBegin("line", line_pick);
    const len = weft.byteLen();
    // Walk the buffer line by line (bounded by the row table + read scratch).
    var line_start: usize = 0;
    var row: usize = 1;
    while (line_start <= len and n_rows < starts.len) : (row += 1) {
        const l = weft.lineAt(line_start);
        const text = weft.slice(l.start, l.end); // borrows scratch
        // A short "N: " docstring is display-only; the match text is the line.
        var doc: [16]u8 = undefined;
        const ds = std.fmt.bufPrint(&doc, "L{d}", .{row}) catch "";
        weft.pickAdd(text, ds);
        starts[n_rows] = l.start;
        n_rows += 1;
        if (l.end + 1 > len) break; // last line
        line_start = l.end + 1; // past the newline
    }
    weft.pickEnd();
}
