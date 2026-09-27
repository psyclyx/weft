//! Test fixture ONLY (not installed — see build.zig's `guests` table): the
//! selection doors and declared mapping (doc/model.md §2.6) driven across the
//! real membrane, the way a selection-first grammar (helix, ide) drives them.
//! No permissions: selections and registers are editor state and core
//! mechanism, never an effect.
//!
//!   - `ms-add <anchor> <head>` / `ms-remove <i>` / `ms.collapse`: the SDK's
//!     add/remove/collapse, which are compositions over `selections_get`/
//!     `selections_set`, not doors of their own. `.whole`; each answers the
//!     count.
//!   - `ms.motion`: a motion — the scalar after "the cursor", which in a run
//!     dispatch maps is that run's selection.
//!   - `ms.upcase-each`: an operator declared `.each` over `ms.motion`, which
//!     also seals the undo unit (`edit.seal-undo`), so the one-undo-unit claim
//!     of the mapping is tested against an operator that tries to break it.
//!   - `ms.yank` / `ms.paste`: `.each` — one register value per selection,
//!     and a paste at every head under core's distribution rule, with no
//!     index in sight.
//!   - `ms.undeclared`: says nothing about its mapping — refused on several
//!     selections.
//!   - `ms.unit-leak`: opens an undo unit (`undo_unit(1)`), edits, and never
//!     closes it — the unit must still end with the dispatch.
//!   - `ms.unit-close`: closes a unit it never opened; answers the door's -1.
//!   - `ms.line` (`.each`: select the caret's line, so two carets on one line
//!     merge), `ms.op-none` (`.each` over `ms.none`, which finds no target),
//!     and `ms.epilogues` (how many times the table's `after` hook ran): a
//!     mapping's epilogue runs exactly once, however many runs it had.

const weft = @import("weft");

const each = weft.Arity.each_extent;

const cmds = [_]weft.CommandEntry{
    .{ .name = "ms.add", .call = add, .arity = .whole, .summary = "Exercise the ms.add fixture command.", .internal = true },
    .{ .name = "ms.remove", .call = remove, .arity = .whole, .summary = "Exercise the ms.remove fixture command.", .internal = true },
    .{ .name = "ms.collapse", .call = collapse, .arity = .whole, .summary = "Exercise the ms.collapse fixture command.", .internal = true },
    .{ .name = "ms.motion", .call = motion, .arity = each, .summary = "Exercise the ms.motion fixture command.", .internal = true },
    .{ .name = "ms.upcase-each", .call = opUpcase, .arity = .{ .each = .{ .over = "ms.motion" } }, .summary = "Exercise the ms.upcase-each fixture command.", .internal = true },
    .{ .name = "ms.yank", .call = yank, .arity = each, .summary = "Exercise the ms.yank fixture command.", .internal = true },
    .{ .name = "ms.paste", .call = paste, .arity = each, .summary = "Exercise the ms.paste fixture command.", .internal = true },
    .{ .name = "ms.undeclared", .arity = .one, .call = undeclared, .summary = "Exercise the ms.undeclared fixture command.", .internal = true },
    .{ .name = "ms.unit-leak", .call = unitLeak, .arity = .whole, .summary = "Exercise the ms.unit-leak fixture command.", .internal = true },
    .{ .name = "ms.unit-close", .call = unitClose, .arity = .whole, .summary = "Exercise the ms.unit-close fixture command.", .internal = true },
    .{ .name = "ms.line", .call = line, .arity = each, .summary = "Exercise the ms.line fixture command.", .internal = true },
    .{ .name = "ms.none", .call = none, .arity = each, .summary = "Exercise the ms.none fixture command.", .internal = true },
    .{ .name = "ms.op-none", .call = opUpcase, .arity = .{ .each = .{ .over = "ms.none" } }, .summary = "Exercise the ms.op-none fixture command.", .internal = true },
    .{ .name = "ms.epilogues", .call = epilogueCount, .arity = .whole, .summary = "Exercise the ms.epilogues fixture command.", .internal = true },
};

comptime {
    weft.plugin(&cmds, .{ .after = epilogue }).exportAll();
}

fn line() void {
    weft.setSelection(weft.lineAt(weft.cursor()));
}

/// A target finder with nothing to find.
fn none() void {}

/// The epilogue, counted: a test reads how often it ran.
var epilogues: i32 = 0;

fn epilogue(_: usize) void {
    epilogues += 1;
}

fn epilogueCount() void {
    weft.setResultInt(epilogues);
}

fn count() void {
    weft.setResultInt(@intCast(weft.selectionCount()));
}

fn add() void {
    _ = weft.addSelection(.{ .anchor = @intCast(weft.argInt(0)), .head = @intCast(weft.argInt(1)) });
    count();
}

fn remove() void {
    _ = weft.removeSelection(@intCast(weft.argInt(0)));
    count();
}

fn collapse() void {
    _ = weft.collapseSelections();
    count();
}

fn motion() void {
    const at = weft.cursor();
    const h = weft.anchorRange(.{ .start = at, .end = weft.step(at, .fwd, .char) }) orelse return;
    weft.setResultRange(h);
}

fn opUpcase() void {
    const h = weft.argRange(0) orelse return;
    const r = weft.rangeEnds(h) orelse return;
    var buf: [64]u8 = undefined;
    const src = weft.slice(r.start, r.end);
    const n = @min(src.len, buf.len);
    for (buf[0..n], src[0..n]) |*d, c| d.* = if (c >= 'a' and c <= 'z') c - 32 else c;
    weft.editRange(h, buf[0..n]);
    // Seal the undo unit, as a modal grammar does on its boundaries — the
    // attempt the mapping's one-unit bracket must hold shut.
    weft.run("edit.seal-undo");
}

fn yank() void {
    const r = weft.selection() orelse return;
    weft.yankRange(r.start, r.end, false);
}

/// Paste this selection's value at its head.
fn paste() void {
    const at = weft.cursor();
    const v = weft.registerText();
    weft.edit(.{ .start = at, .end = at }, v);
    weft.pasteAt(at);
}

fn undeclared() void {
    weft.edit(.{ .start = 0, .end = 0 }, "?");
}

// The raw door: the SDK's `undoUnit` always closes what it opens, and this
// fixture exists to prove the host closes what a guest does not.
extern "weft:abi/1" fn wl_undo_unit(open: u32) i32;

fn unitLeak() void {
    _ = wl_undo_unit(1);
    weft.edit(.{ .start = 0, .end = 0 }, "X");
}

fn unitClose() void {
    weft.setResultInt(wl_undo_unit(0));
}
