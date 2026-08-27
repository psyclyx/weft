//! The standard intention vocabulary (doc/contextual-workspace-architecture.md
//! §10.2, §14.2) as data: a table, not an ontology. Each entry names a
//! `std.<package>.<operation>` protocol intention (doc/configuration.md §5.1)
//! that input grammars bind to and domain plugins resolve — never a concrete
//! plugin command. Adding a shape beyond identity (a payload schema, an
//! effect grade) is future work; for now the catalog needs only the name and
//! its one-line meaning.
//!
//! The §5.1 grammar itself lives in `catalog.zig`, which validates at its
//! interner; this table is checked against that one validator rather than
//! carrying a second copy free to disagree with it.

const std = @import("std");

/// One standard intention: its dotted `std.*` name and a one-line meaning.
/// No behavior lives here — resolution is each domain's, per protocol.
pub const Intention = struct {
    name: []const u8,
    doc: []const u8,
};

pub const std_intentions = [_]Intention{
    .{ .name = "std.hierarchy.toggle-expanded", .doc = "Open or close the target's children in place." },
    .{ .name = "std.target.activate", .doc = "Act on the target the way its kind defines as primary." },
    .{ .name = "std.editing.insert-line-break", .doc = "Commit a line break at the editing point." },
    .{ .name = "std.navigation.back", .doc = "Return to the previous workspace location." },
    // Directional movement shares `navigation`'s package: one package per
    // concept, so `back` and the four moves cannot drift apart.
    .{ .name = "std.navigation.up", .doc = "Move to the neighbour above on the vertical axis." },
    .{ .name = "std.navigation.down", .doc = "Move to the neighbour below on the vertical axis." },
    .{ .name = "std.navigation.left", .doc = "Move to the neighbour left on the horizontal axis." },
    .{ .name = "std.navigation.right", .doc = "Move to the neighbour right on the horizontal axis." },
    .{ .name = "std.history.undo", .doc = "Reverse the most recent reversible change." },
    .{ .name = "std.history.redo", .doc = "Reapply the most recently undone change." },
    .{ .name = "std.persistence.save", .doc = "Commit pending changes to durable storage." },

    // Abstract gesture roles (§10.2): input grammars may bind these directly
    // where no domain-specific intention applies.
    .{ .name = "std.gesture.activate", .doc = "The generic primary-action gesture." },
    .{ .name = "std.gesture.expand", .doc = "The generic reveal-more gesture." },
    .{ .name = "std.gesture.promote", .doc = "The generic raise-in-order gesture." },
    .{ .name = "std.gesture.demote", .doc = "The generic lower-in-order gesture." },
    .{ .name = "std.gesture.discard", .doc = "The generic remove-without-confirmation gesture." },
    .{ .name = "std.gesture.confirm", .doc = "The generic accept-pending-choice gesture." },
    .{ .name = "std.gesture.cancel", .doc = "The generic reject-pending-choice gesture." },
};

comptime {
    for (std_intentions, 0..) |a, i| {
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
