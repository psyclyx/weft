//! The standard intention vocabulary (doc/contextual-workspace-architecture.md
//! §10.2, §14.2) as data: a table, not an ontology. Each entry names a
//! `std.<package>.<operation>` protocol intention (doc/configuration.md §5.1)
//! that input grammars bind to and domain plugins resolve — never a concrete
//! plugin command. Adding a shape beyond identity (a payload schema, an
//! effect grade) is future work; for now the catalog needs the name, its
//! one-line meaning, and the label a UI shows for it.
//!
//! The §5.1 grammar itself lives in `catalog.zig`, which validates at its
//! interner; this table is checked against that one validator rather than
//! carrying a second copy free to disagree with it.

const std = @import("std");

/// One standard intention: its dotted `std.*` name, a one-line meaning, and
/// the short human label a toolbar, menu or palette shows for it — the
/// FALLBACK presentation (§9.1 `ActionPresentation`), which a provider may
/// override for its own offer. No behavior lives here — resolution is each
/// domain's, per protocol.
pub const Intention = struct {
    name: []const u8,
    doc: []const u8,
    label: []const u8,
};

pub const std_intentions = [_]Intention{
    .{ .name = "std.hierarchy.toggle-expanded", .doc = "Open or close the target's children in place.", .label = "Expand/Collapse" },
    // The other half of hierarchy movement: expansion splices children into
    // the view that already shows the target; this LEAVES it for the locus
    // that holds it. One package, so the pair cannot drift apart.
    .{ .name = "std.hierarchy.step-out", .doc = "Leave the focused target for the container that holds it.", .label = "Up to Parent" },
    .{ .name = "std.target.activate", .doc = "Act on the target the way its kind defines as primary.", .label = "Open" },
    // Transfer: capture into the shared register, and place what it holds.
    // Placement (before/after/into) is the domain's, not the grammar's — one
    // word, so a grammar cannot claim ordering a view may not have.
    .{ .name = "std.transfer.yank", .doc = "Capture the target into the transfer register.", .label = "Copy" },
    .{ .name = "std.transfer.paste", .doc = "Place the transfer register's content at the target.", .label = "Paste" },
    .{ .name = "std.transfer.delete-to-register", .doc = "Capture the target into the transfer register and remove it.", .label = "Cut" },
    .{ .name = "std.editing.insert-line-break", .doc = "Commit a line break at the editing point.", .label = "New Line" },
    .{ .name = "std.navigation.word-prev", .doc = "Move the editing point to the word-previous boundary.", .label = "Previous Word" },
    .{ .name = "std.navigation.word-next", .doc = "Move the editing point to the word-next boundary.", .label = "Next Word" },
    .{ .name = "std.navigation.word-end", .doc = "Move the editing point to the word-end boundary.", .label = "Word End" },
    .{ .name = "std.navigation.big-word-prev", .doc = "Move the editing point to the WORD-previous boundary.", .label = "Previous WORD" },
    .{ .name = "std.navigation.big-word-next", .doc = "Move the editing point to the WORD-next boundary.", .label = "Next WORD" },
    .{ .name = "std.navigation.big-word-end", .doc = "Move the editing point to the WORD-end boundary.", .label = "WORD End" },
    .{ .name = "std.navigation.line-start", .doc = "Move the editing point to the line-start boundary.", .label = "Line Start" },
    .{ .name = "std.navigation.line-end", .doc = "Move the editing point to the line-end boundary.", .label = "Line End" },
    .{ .name = "std.navigation.first-non-blank", .doc = "Move the editing point to the first-non-blank boundary.", .label = "First Non-Blank" },
    .{ .name = "std.navigation.back", .doc = "Return to the previous workspace location.", .label = "Back" },
    // Directional movement shares `navigation`'s package: one package per
    // concept, so `back` and the four moves cannot drift apart.
    .{ .name = "std.navigation.up", .doc = "Move to the neighbour above on the vertical axis.", .label = "Up" },
    .{ .name = "std.navigation.down", .doc = "Move to the neighbour below on the vertical axis.", .label = "Down" },
    .{ .name = "std.navigation.left", .doc = "Move to the neighbour left on the horizontal axis.", .label = "Left" },
    .{ .name = "std.navigation.right", .doc = "Move to the neighbour right on the horizontal axis.", .label = "Right" },
    .{ .name = "std.editing.insert-before", .doc = "Insert an editable item before the focused item.", .label = "Insert Before" },
    .{ .name = "std.editing.insert-after", .doc = "Insert an editable item after the focused item.", .label = "Insert After" },
    // Focusing a row and editing its text are different states (doc/chrome.md
    // §5.2): this is the step from one to the other. Committed by activating
    // the edit, cancelled by `std.gesture.cancel`.
    .{ .name = "std.editing.begin", .doc = "Start editing the focused item's text in place.", .label = "Edit" },
    .{ .name = "std.history.undo", .doc = "Reverse the most recent reversible change.", .label = "Undo" },
    .{ .name = "std.history.redo", .doc = "Reapply the most recently undone change.", .label = "Redo" },
    .{ .name = "std.persistence.save", .doc = "Commit pending changes to durable storage.", .label = "Save" },
    // The one intention a grammar must keep bound in EVERY state (§10.4): a
    // `capture` presentation takes raw input, so the way back cannot be the
    // presentation's to grant.
    .{ .name = "std.input.break-out", .doc = "Leave a capture posture for the one it displaced.", .label = "Break Out" },
    .{ .name = "std.input.resume", .doc = "Take raw input again after breaking out of a capture.", .label = "Resume Input" },

    // Abstract gesture roles (§10.2): input grammars may bind these directly
    // where no domain-specific intention applies.
    .{ .name = "std.gesture.activate", .doc = "The generic primary-action gesture.", .label = "Activate" },
    .{ .name = "std.gesture.expand", .doc = "The generic reveal-more gesture.", .label = "Expand" },
    .{ .name = "std.gesture.promote", .doc = "The generic raise-in-order gesture.", .label = "Promote" },
    .{ .name = "std.gesture.demote", .doc = "The generic lower-in-order gesture.", .label = "Demote" },
    .{ .name = "std.gesture.discard", .doc = "The generic remove-without-confirmation gesture.", .label = "Discard" },
    .{ .name = "std.gesture.confirm", .doc = "The generic accept-pending-choice gesture.", .label = "Confirm" },
    .{ .name = "std.gesture.cancel", .doc = "The generic reject-pending-choice gesture.", .label = "Cancel" },
};

/// The table entry for `name`, or null for any intention outside the
/// standard vocabulary (a `plugin.*` one, or a misspelling).
pub fn find(name: []const u8) ?struct { index: usize, intention: Intention } {
    for (std_intentions, 0..) |i, index| {
        if (std.mem.eql(u8, i.name, name)) return .{ .index = index, .intention = i };
    }
    return null;
}

comptime {
    @setEvalBranchQuota(10000);
    for (std_intentions, 0..) |a, i| {
        if (a.label.len == 0) @compileError("std intention without a label: " ++ a.name);
        for (std_intentions[i + 1 ..]) |b| {
            if (std.mem.eql(u8, a.name, b.name)) {
                @compileError("duplicate std intention name: " ++ a.name);
            }
        }
    }
}

const t = std.testing;

test "every std intention name parses under the catalog's §5.1 grammar" {
    const catalog = @import("catalog.zig");
    for (std_intentions) |intention| {
        try catalog.validateIntentionName(intention.name);
    }
}

test "find: a std name answers its label, a plugin name answers nothing" {
    try t.expectEqualStrings("Undo", find("std.history.undo").?.intention.label);
    try t.expect(find("plugin.git.stage") == null);
}
