//! comment — a line-comment toggler, a `.wasm` plugin with NO core privilege
//! beyond the edit door (perms `{}`, grant_max edit). It reads a read-only
//! snapshot of the active line(s) via `lineAt`/`slice` and toggles a leading
//! `// ` through the gated `edit` door, authored as this plugin's peer.
//! Indentation is preserved: the token goes at (or comes off) the FIRST
//! non-blank column, never column zero. The comment token is hardcoded for now
//! (language-aware tokens come later).

const weft = @import("weft.zig");

/// The line-comment token. Add inserts the full `// `; remove peels `// ` when
/// present, else the bare `//`.
const token = "// ";

/// Registration order == the id the host hands `on_command`.
const Cmd = struct { name: []const u8, handler: *const fn () void };
const cmds = [_]Cmd{
    .{ .name = "comment-line", .handler = commentLine },
    .{ .name = "comment-selection", .handler = commentSelection },
    .{ .name = "op.comment", .handler = opComment },
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

// ── Line inspection (over a read-only `slice` snapshot) ───────────────
/// Index of the first non-blank byte in `text` (its length if all blank).
fn firstNonBlank(text: []const u8) usize {
    var i: usize = 0;
    while (i < text.len and (text[i] == ' ' or text[i] == '\t')) i += 1;
    return i;
}
/// Whether the line has no non-whitespace content.
fn isBlank(text: []const u8) bool {
    return firstNonBlank(text) == text.len;
}
/// Whether the line's first non-blank run starts with `//`.
fn isCommented(text: []const u8) bool {
    const i = firstNonBlank(text);
    return i + 1 < text.len and text[i] == '/' and text[i + 1] == '/';
}

// ── The toggle, one line at a time ────────────────────────────────────
/// What to do to a line: `.toggle` decides per-line (add if not commented,
/// else remove); `.add`/`.remove` are forced (the uniform bulk decision).
const Action = enum { toggle, add, remove };

/// Apply `action` to the line whose start is `ls`. Reads the current line fresh
/// (so callers can process bottom-up, edits below not shifting this line), then
/// edits at the first non-blank column. Blank lines are skipped when adding in
/// bulk (`skip_blank`), which keeps "// " off empty rows of a selection.
fn applyLine(ls: usize, action: Action, skip_blank: bool) void {
    const l = weft.lineAt(ls);
    const text = weft.slice(l.start, l.end); // borrows shim scratch; used before any next read
    const i = firstNonBlank(text);
    const commented = isCommented(text);

    var act = action;
    if (act == .toggle) act = if (commented) .remove else .add;

    switch (act) {
        .add => {
            if (skip_blank and isBlank(text)) return;
            // Insert the token at the first non-blank column (bytes are a static
            // literal, so no read-scratch is disturbed before the edit).
            weft.edit(.{ .start = l.start + i, .end = l.start + i }, token);
        },
        .remove => {
            if (!commented) return;
            // Peel `// ` when the space is present, else the bare `//`.
            var rl: usize = 2;
            if (i + 2 < text.len and text[i + 2] == ' ') rl = 3;
            weft.edit(.{ .start = l.start + i, .end = l.start + i + rl }, "");
        },
        .toggle => unreachable,
    }
}

/// Toggle a leading `// ` on the line under the cursor.
fn commentLine() void {
    applyLine(weft.lineAt(weft.cursor()).start, .toggle, false);
}

// ── Selection (every overlapping line, one uniform decision) ──────────
/// Line starts of the selected span; a fixed cap (huge selections truncate).
var starts: [1 << 12]usize = undefined;

/// Toggle every line overlapping `[start, end)` with one uniform decision:
/// remove iff EVERY non-blank line in the span is already commented, else add.
/// The shared core of `comment-selection` and the `gc` operator `op.comment`.
fn commentSpan(start: usize, end: usize) void {
    // Collect the start of each line the span touches.
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

    // Pass 1: is every non-blank line in the span already commented?
    var all_commented = true;
    for (starts[0..count]) |ls| {
        const l = weft.lineAt(ls);
        const text = weft.slice(l.start, l.end);
        if (isBlank(text)) continue;
        if (!isCommented(text)) all_commented = false;
    }
    const action: Action = if (all_commented) .remove else .add;

    // Pass 2: apply bottom-up, so each edit sits below the lines still to come
    // and never shifts their recorded starts.
    var k = count;
    while (k > 0) {
        k -= 1;
        applyLine(starts[k], action, true);
    }
}

/// Toggle every line overlapping the selection. With no selection this falls
/// back to the current line.
fn commentSelection() void {
    const sel = weft.selection() orelse {
        commentLine();
        return;
    };
    commentSpan(sel.start, sel.end);
}

/// The `gc` operator: toggle comments over the awaited range's lines. Composes
/// with every vim motion and text object (`gcap`, `gcip`, `gc3j`) and — via the
/// doubled-operator path (op-line) — `gcc` on the current line.
fn opComment() void {
    const h = weft.argRange(0) orelse return;
    const r = weft.rangeEnds(h) orelse return;
    commentSpan(r.start, r.end);
}
