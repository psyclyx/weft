//! Undo steps, DECLARED rather than incidental (doc/undo.md).
//!
//! An `UndoLog` coalesces the user's commits into one unit until something
//! cuts it. What cuts it is this file's one question, answered at the one
//! place a person's input turns into work: dispatch calls `begin` wherever a
//! keystroke (or a click) runs something, naming what it runs. Whether that
//! begins a new step is the GRAMMAR's declaration for the mode the head is in
//! (`Keymap.UndoStep`, `mode.set-undo-step`):
//!
//!   command   cut: every command is a step (vim's normal, every menu).
//!   continue  no cut: the step that entered the mode goes on (vim's insert —
//!             `cw…Esc` is the `c`'s step).
//!   run       cut unless this is the command the last step ran (ide typing —
//!             a word is a step, a caret move ends it).
//!
//! So nothing else cuts: a caret motion, a selection change, a mode change
//! are not undo boundaries — a command is, where the grammar says so. Core
//! names no mode and no grammar here; it reads a table the grammar wrote.
//!
//! A cut closes the open unit of EVERY text entry, not only the focused one:
//! a step that edits two entries (a rename across files) is one step in each,
//! and the next step in either starts fresh.

const std = @import("std");
const command = @import("command.zig");
const Buffers = @import("Buffers.zig");
const Keymap = @import("Keymap.zig");

/// A keystroke is about to run `name` (a command, an intention, the mode's
/// text commit). Cut the open undo units if the head's mode declares that
/// this begins a new step.
pub fn begin(ctx: *command.Context, name: []const u8) void {
    const mode = ctx.head.currentMode();
    const identity = identityOf(mode, name);
    const last = ctx.head.step_last;
    ctx.head.step_last = identity;
    switch (ctx.keymap.undoStepOf(mode)) {
        .@"continue" => return,
        .run => if (last == identity) return,
        .command => {},
    }
    cut(ctx.buffers, ctx.gpa);
}

/// Close every text entry's open undo unit: the next own commit in any of
/// them starts a new one. Commits not yet folded into a log are folded first,
/// so they stay with the step that made them.
pub fn cut(buffers: *const Buffers, gpa: std.mem.Allocator) void {
    var it = buffers.iterator();
    while (it.next()) |b| {
        const ed = b.textEditor() orelse continue;
        ed.history.ingest(gpa, &ed.doc) catch {};
        ed.history.barrier();
    }
}

fn identityOf(mode: []const u8, name: []const u8) u64 {
    var h = std.hash.Wyhash.init(0);
    h.update(mode);
    h.update(&.{0});
    h.update(name);
    // Zero is "no step yet"; a hash that lands on it is nudged off it.
    return h.final() | 1;
}

// ── Tests ───────────────────────────────────────────────────────────

const t = std.testing;

test "step: the declared rule, per mode — command cuts, continue never does, run cuts on another command" {
    const gpa = t.allocator;
    var km: Keymap = .empty;
    defer km.deinit(gpa);
    try km.setUndoStep(gpa, "insert", .@"continue");
    try km.setUndoStep(gpa, "typing", .run);
    try km.setFallback(gpa, "typing-source", "typing");
    try t.expectEqual(Keymap.UndoStep.command, km.undoStepOf("normal"));
    try t.expectEqual(Keymap.UndoStep.@"continue", km.undoStepOf("insert"));
    // Read down the fallback chain, as a mode's other declarations are.
    try t.expectEqual(Keymap.UndoStep.run, km.undoStepOf("typing-source"));
    try t.expectEqual(@as(?Keymap.UndoStep, .run), Keymap.UndoStep.parse("run"));
    try t.expectEqual(@as(?Keymap.UndoStep, null), Keymap.UndoStep.parse("sometimes"));
}
