//! Test fixture ONLY (not installed — see build.zig's `guests` table): the
//! multiple-selection doors (doc/configs.md §0.1) driven across the real
//! membrane, the way a selection-first grammar (helix, ide's add-next-match)
//! will drive them. No permissions: selections and registers are editor
//! state and core mechanism, never an effect.
//!
//!   - `ms-add <anchor> <head>` / `ms-remove <i>` / `ms-collapse`: the SDK's
//!     add/remove/collapse, which are compositions over `selections_get`/
//!     `selections_set`, not doors of their own. Each answers the count.
//!   - `ms-motion`: a motion — the scalar after "the cursor". Run through
//!     `run_range_each`, "the cursor" is each selection's head in turn.
//!   - `ms-op-upcase`: an operator over its range arg that also seals the undo
//!     unit (`undo-barrier`), so the one-undo-unit claim of
//!     `run_range_arg_each` is tested against an operator that tries to break
//!     it.
//!   - `ms-upcase-each`: motion-then-operator at every selection.
//!   - `ms-yank` / `ms-paste`: one value per selection into the unnamed
//!     register, and a paste at every head under core's distribution rule.
//!   - `ms-unit-leak`: opens an undo unit (`undo_unit(1)`), edits, and never
//!     closes it — the unit must still end with the dispatch.
//!   - `ms-unit-close`: closes a unit it never opened; answers the door's -1.

const weft = @import("weft");

const Cmd = struct { name: []const u8, handler: *const fn () void };
const cmds = [_]Cmd{
    .{ .name = "ms-add", .handler = add },
    .{ .name = "ms-remove", .handler = remove },
    .{ .name = "ms-collapse", .handler = collapse },
    .{ .name = "ms-motion", .handler = motion },
    .{ .name = "ms-op-upcase", .handler = opUpcase },
    .{ .name = "ms-upcase-each", .handler = upcaseEach },
    .{ .name = "ms-yank", .handler = yank },
    .{ .name = "ms-paste", .handler = paste },
    .{ .name = "ms-unit-leak", .handler = unitLeak },
    .{ .name = "ms-unit-close", .handler = unitClose },
};

fn describe() callconv(.c) void {
    for (cmds) |c| weft.declareCommand(c.name);
}

fn init() callconv(.c) void {
    for (cmds) |c| _ = weft.register(c.name);
}

fn on_command(id: u32) callconv(.c) void {
    if (id < cmds.len) cmds[id].handler();
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
    // attempt `run_range_arg_each`'s one-unit bracket must hold shut.
    weft.run("undo-barrier");
}

fn upcaseEach() void {
    var handles: [weft.max_selections]?u32 = undefined;
    const hs = weft.runRangeEach("ms-motion", &handles);
    weft.runRangeArgEach("ms-op-upcase", hs);
}

fn yank() void {
    const set = weft.selections();
    var ranges: [weft.max_selections]weft.Range = undefined;
    for (set.items, ranges[0..set.items.len]) |s, *r| r.* = s.range();
    weft.yankEachIn(0, ranges[0..set.items.len], false);
}

/// Paste at every head, last first so each earlier head's offset still holds.
fn paste() void {
    const set = weft.selections();
    var heads: [weft.max_selections]usize = undefined;
    for (set.items, heads[0..set.items.len]) |s, *h| h.* = s.head;
    const n = set.items.len;
    var i = n;
    while (i > 0) {
        i -= 1;
        const v = weft.registerPasteValueIn(0, i, n);
        weft.edit(.{ .start = heads[i], .end = heads[i] }, v);
        weft.pasteValueAtIn(0, heads[i], i, n);
    }
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

comptime {
    weft.exportCallback("describe", &describe);
    weft.exportCallback("init", &init);
    weft.exportCallback("on_command", &on_command);
}
