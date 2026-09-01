//! projection_gate (wasm) — the gate guest for the projection doors.
//!
//! It holds NO permissions at all, which is the first thing worth saying: a
//! tool projection is a plugin authoring its own buffer, and that never needed
//! authority beyond the edit door it already had.
//!
//! What it proves is the four properties a producer used to hand-roll, and the
//! one thing it can no longer express:
//!
//!   - a parent ENCLOSES its children, so the innermost row wins the hit-test,
//!     while the nearest FOCUSABLE ancestor is what a verb acts on — the
//!     section header here is structure, and affords nothing;
//!   - a FOLD survives a rebuild, keyed rather than positioned;
//!   - the CURSOR survives a rebuild onto the same KEY, even when rows are
//!     inserted above it and every offset below has shifted;
//!   - a SELECTION inside a row reads back as line ordinals.
//!
//! …and it never names an offset, because there is no door that takes one.

const std = @import("std");
const weft = @import("weft");

const cmds = [_]weft.CommandEntry{
    .{ .name = "proj-build", .call = build },
    .{ .name = "proj-rebuild", .call = rebuild },
    .{ .name = "proj-fold-b", .call = foldB },
    .{ .name = "proj-report", .call = report },
    .{ .name = "proj-plan", .call = plan },
    .{ .name = "proj-plan-report", .call = planReport },
};
comptime {
    weft.plugin(&cmds, .{}).exportAll();
}

const view = "*proj*";

/// Three files under a section, one of them with two hunk rows under it — the
/// shape every tool projection has, and the one that needs enclosure to work.
fn tree(b: weft.ProjectionBuilder, extra_first: bool) void {
    const sec = b.add(.{
        .key = "unstaged",
        .role = "git.section",
        .text = "Unstaged changes",
        .foldable = true,
    }) orelse return;
    if (extra_first) {
        // A row INSERTED ABOVE the others: every offset below it moves, which
        // is exactly what a positional memory of the cursor gets wrong.
        _ = b.add(.{ .key = "new", .role = "git.file", .text = "  new.zig", .parent = sec, .focusable = true });
    }
    _ = b.add(.{ .key = "a", .role = "git.file", .text = "  a.zig", .parent = sec, .focusable = true });
    const file_b = b.add(.{
        .key = "b",
        .role = "git.file",
        .text = "  b.zig",
        .parent = sec,
        .foldable = true,
        .focusable = true,
    }) orelse return;
    const hunk = b.add(.{
        .key = "b#0",
        .role = "git.hunk",
        .text = "@@ -1,2 +1,2 @@\n-old\n+new",
        .parent = file_b,
        .focusable = true,
    }) orelse return;
    // A body line: its own role for STYLING, not focusable, so a verb pressed
    // with point here acts on the hunk above it. The two questions the tree
    // answers separately — what is this, and what does it act on.
    _ = b.add(.{ .key = "b#0.2", .role = "git.diff.context", .text = " context", .parent = hunk });
}

fn build() void {
    weft.runStr("buffer-create", view);
    const b = weft.project(view) orelse return;
    tree(b, false);
    _ = b.commit();
}

fn rebuild() void {
    const b = weft.project(view) orelse return;
    tree(b, true);
    _ = b.commit();
}

fn foldB() void {
    _ = weft.projectionToggleFold("b");
}

var out: [1024]u8 = undefined;

/// Everything the host will be asked about, written into a buffer of its own —
/// a guest's only channel back.
fn report() void {
    const at = weft.projectionAtCursor() orelse "";
    var sel_lo: i64 = -1;
    var sel_hi: i64 = -1;
    if (weft.projectionSelectedLines("b#0")) |lines| {
        sel_lo = @intCast(lines.lo);
        sel_hi = @intCast(lines.hi);
    }
    const line = std.fmt.bufPrint(&out, "at={s} sel={d},{d}", .{ at, sel_lo, sel_hi }) catch return;
    weft.runStr("buffer-create", "*proj-report*");
    weft.edit(.{ .start = 0, .end = weft.byteLen() }, line);
}

// ── Editable rows: the plan a user types into ────────────────────────────
// A projection whose rows are EDITABLE — the shape a rebase plan or an
// in-place directory rename has. The guest publishes rows with keys; the user
// reorders, retypes and deletes lines like any other text; the guest asks what
// each row it published now says, addressed by its own key.
//
// This is doc/plugin-api.md §F2's fork closed from the text side: the row is
// text (searchable, yankable, selectable) AND has an identity, which is the
// combination the two planes used to make you choose between.

const plan_view = "*plan*";

fn plan() void {
    weft.focusOrCreateBuffer(plan_view);
    const b = weft.project(plan_view) orelse return;
    _ = b.add(.{ .key = "a", .role = "plan.step", .text = "pick aaa first", .focusable = true, .editable = true });
    _ = b.add(.{ .key = "b", .role = "plan.step", .text = "pick bbb second", .focusable = true, .editable = true });
    _ = b.add(.{ .key = "c", .role = "plan.step", .text = "pick ccc third", .focusable = true, .editable = true });
    // NOT editable: a comment is structure, and must not come back as a row.
    _ = b.add(.{ .key = "note", .role = "plan.note", .text = "# reorder me" });
    _ = b.commit();
}

var plan_out: [1024]u8 = undefined;

/// Every published row as it reads NOW, in the order it now appears, written
/// into a buffer of its own — a guest's only channel back.
fn planReport() void {
    var rows: [8]weft.ProjectionRow = undefined;
    const live = weft.projectionRows(&rows);
    var w: usize = 0;
    for (live) |row| {
        const seg = std.fmt.bufPrint(plan_out[w..], "{s}={s};", .{ row.key, row.text }) catch break;
        w += seg.len;
    }
    weft.focusOrCreateBuffer("*plan-report*");
    weft.edit(.{ .start = 0, .end = weft.byteLen() }, plan_out[0..w]);
}
