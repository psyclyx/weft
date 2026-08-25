//! consult — navigation sources over the pick seam (design §6.4), a `.wasm`
//! plugin with perms `{}` (view). A source gathers candidates, opens a pick,
//! and on accept resolves the CHOSEN ROW (by its add-order index, not its
//! text) to a position it recorded at add time — so jumping to a line is
//! unambiguous even when two lines read identically. `consult-line` is the
//! first source; grep/imenu/mark join as their inputs (proc, symbols) land.

const std = @import("std");
const weft = @import("weft");

const line_pick = 0;
const sym_pick = 1;

/// Per-row target offsets, parallel to the pickAdd order. The accepted index
/// maps straight into this — the robustness the string alone can't give.
var starts: [1 << 15]usize = undefined;
var n_rows: usize = 0;

const Cmd = struct { name: []const u8, handler: *const fn () void };
const cmds = [_]Cmd{
    .{ .name = "consult-line", .handler = consultLine },
    .{ .name = "consult-imenu", .handler = consultImenu },
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
    if (pick_id != line_pick and pick_id != sym_pick) return;
    const i = weft.pickChoiceIndex() orelse return; // free text → ignore
    if (i < n_rows) {
        // A line candidate is presentation-sized, but the pick owns the
        // actual match location. Resolve that location at the accept boundary
        // so `/query` lands on the matched bytes (including after indentation)
        // rather than on the line's display anchor.
        // `consult-line`'s candidate text is the whole line, so its match
        // starts relative to the line anchor. Other sources (notably imenu)
        // record a semantic target directly; their display text is not the
        // target's coordinate system and must not inherit this adjustment.
        const match_start = if (pick_id == line_pick)
            (weft.pickChoiceMatchStart() orelse 0)
        else
            0;
        weft.jump(starts[i] + match_start);
    }
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

/// Common definition node types across languages. A query for a type the
/// grammar doesn't have simply returns no captures, so trying many is
/// grammar-agnostic (precise per-language sets come with modes later).
const def_types = [_][]const u8{
    "function_declaration",  "function_definition", "function_item",
    "method_declaration",    "method_definition",   "class_declaration",
    "class_definition",      "struct_declaration",  "struct_item",
    "enum_declaration",      "type_declaration",    "type_definition",
    "interface_declaration", "trait_item",          "const_declaration",
    "variable_declaration",
};

/// Fuzzy-pick a definition (function/type/…) in the buffer and jump to it.
/// Grammar-driven via `syntax.query`; degrades to empty without a grammar.
fn consultImenu() void {
    n_rows = 0;
    weft.pickBegin("symbol", sym_pick);
    for (def_types) |ty| {
        var scm_buf: [96]u8 = undefined;
        const scm = std.fmt.bufPrint(&scm_buf, "({s}) @d", .{ty}) catch continue;
        const count = weft.query(scm, .{ .start = 0, .end = weft.byteLen() });
        var i: usize = 0;
        while (i < count and n_rows < starts.len) : (i += 1) {
            const c = weft.queryCapture(i) orelse continue;
            // Display the definition's first line (its signature).
            const line_end = weft.lineAt(c.start).end;
            const text = weft.slice(c.start, line_end); // borrows scratch
            weft.pickAdd(text, ty);
            starts[n_rows] = c.start;
            n_rows += 1;
        }
    }
    weft.pickEnd();
}
