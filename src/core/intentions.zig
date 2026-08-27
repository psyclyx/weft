//! The standard intention vocabulary (doc/contextual-workspace-architecture.md
//! §10.2, §14.2) as data: a table, not an ontology. Each entry names a
//! `std.<package>.<operation>` protocol intention (doc/configuration.md §5.1)
//! that input grammars bind to and domain plugins resolve — never a concrete
//! plugin command. Adding a shape beyond identity (a payload schema, an
//! effect grade) is future work; for now the catalog needs only the name and
//! its one-line meaning.

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
            if (@import("std").mem.eql(u8, a.name, b.name)) {
                @compileError("duplicate std intention name: " ++ a.name);
            }
        }
    }
}

/// True when `segment` is a non-empty run of lowercase ascii letters, digits,
/// and internal hyphens (no leading/trailing/doubled hyphen).
fn isValidSegment(segment: []const u8) bool {
    if (segment.len == 0) return false;
    if (segment[0] == '-' or segment[segment.len - 1] == '-') return false;
    var prev_hyphen = false;
    for (segment) |c| {
        switch (c) {
            'a'...'z', '0'...'9' => prev_hyphen = false,
            '-' => {
                if (prev_hyphen) return false;
                prev_hyphen = true;
            },
            else => return false,
        }
    }
    return true;
}

/// True when `name` is `std.<package>.<operation>` — lowercase dotted
/// segments, `std.` prefix, at least three segments (doc/configuration.md
/// §5.1).
pub fn isValidStdName(name: []const u8) bool {
    const std_lib = @import("std");
    var it = std_lib.mem.splitScalar(u8, name, '.');
    var count: usize = 0;
    while (it.next()) |segment| {
        if (!isValidSegment(segment)) return false;
        count += 1;
    }
    if (count < 3) return false;
    var first = std_lib.mem.splitScalar(u8, name, '.');
    return std_lib.mem.eql(u8, first.next().?, "std");
}

const t = @import("std").testing;

test "every std intention name parses under the naming grammar" {
    for (std_intentions) |intention| {
        try t.expect(isValidStdName(intention.name));
    }
}

test "isValidStdName rejects malformed names" {
    try t.expect(!isValidStdName("target.activate")); // missing std. prefix
    try t.expect(!isValidStdName("std.Target.Activate")); // uppercase
    try t.expect(!isValidStdName("std.target")); // too few segments
    try t.expect(!isValidStdName("std..activate")); // empty segment
    try t.expect(!isValidStdName("std.target.-activate")); // leading hyphen
    try t.expect(!isValidStdName("std.target.activate_now")); // underscore
}
