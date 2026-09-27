//! The one grammar a command id is spelled in (doc/chrome.md §1.1):
//!
//!     <namespace>.<verb>[-<object>]
//!
//! lowercase words joined by `-`, one `.` between the namespace (the owning
//! plugin, or a core domain) and the rest: `buffer.next`, `window.split-right`,
//! `lsp.goto-definition`. An action a config names as an intention
//! (`plugin.code.format`) is spelled in the intention grammar instead, which
//! is the other grammar a bound name may take.
//!
//! Direction words are fixed — `next`/`prev`, `left`/`right`/`up`/`down`,
//! `start`/`end`, and `forward`/`back` for history only — so the words a
//! synonym family grew (`fwd`, `previous`, `backward`) are refused by name.
//!
//! Shared by the host (the registry gate) and every guest (`weft.plugin`
//! checks its table at comptime), so a plugin cannot ship an id the gate
//! would refuse: the bad spelling fails its BUILD.

const std = @import("std");

pub const Violation = enum {
    /// No `.`: a bare word names nothing's namespace.
    no_namespace,
    /// More than one `.`, outside the intention grammar.
    too_many_dots,
    /// An empty namespace, verb or `-`-separated word.
    empty_word,
    /// A byte outside `[a-z0-9-]` — an uppercase letter, a `/`, a `_`.
    invalid_character,
    /// A word the direction vocabulary replaced (`fwd`, `previous`, …).
    banned_word,

    pub fn describe(self: Violation) []const u8 {
        return switch (self) {
            .no_namespace => "has no namespace (expected <namespace>.<verb>)",
            .too_many_dots => "has more than one '.' (expected <namespace>.<verb>)",
            .empty_word => "has an empty word",
            .invalid_character => "has a character outside [a-z0-9-]",
            .banned_word => "uses a word the direction vocabulary replaced (next/prev, left/right, forward/back for history)",
        };
    }
};

/// Words the fixed direction vocabulary replaced, and what with.
pub const banned_words = [_][]const u8{ "fwd", "bwd", "previous", "backward", "backwards", "forwards", "rev" };

/// Why `name` is not a command id in the grammar, or null when it is.
pub fn check(name: []const u8) ?Violation {
    if (isIntentionShaped(name)) return null;
    const dot = std.mem.indexOfScalar(u8, name, '.') orelse return .no_namespace;
    if (std.mem.indexOfScalarPos(u8, name, dot + 1, '.') != null) return .too_many_dots;
    if (checkPart(name[0..dot])) |v| return v;
    return checkPart(name[dot + 1 ..]);
}

fn checkPart(part: []const u8) ?Violation {
    if (part.len == 0) return .empty_word;
    var words = std.mem.splitScalar(u8, part, '-');
    while (words.next()) |word| {
        if (word.len == 0) return .empty_word;
        for (word) |c| switch (c) {
            'a'...'z', '0'...'9' => {},
            else => return .invalid_character,
        };
        for (banned_words) |banned| if (std.mem.eql(u8, word, banned)) return .banned_word;
    }
    return null;
}

/// `std.<package>.<operation>` or `plugin.<id>.<…>`, every segment a
/// lowercase `-` word: the intention grammar (doc/configuration.md §5.1),
/// which an action a config declares as an offer is named in.
pub fn isIntentionShaped(name: []const u8) bool {
    const root_end = std.mem.indexOfScalar(u8, name, '.') orelse return false;
    const root = name[0..root_end];
    const is_std = std.mem.eql(u8, root, "std");
    if (!is_std and !std.mem.eql(u8, root, "plugin")) return false;
    var segments: usize = 0;
    var it = std.mem.splitScalar(u8, name, '.');
    while (it.next()) |segment| {
        if (checkPart(segment)) |_| return false;
        segments += 1;
    }
    return if (is_std) segments == 3 else segments >= 3;
}

// ── Tests ───────────────────────────────────────────────────────────

const t = std.testing;

test "command id: the grammar admits namespace.verb-object, and intention-shaped action names" {
    for ([_][]const u8{ "buffer.next", "window.split-right", "lsp.goto-definition", "vim.count-9", "helix.select-inner-big-word", "plugin.code.format", "std.persistence.save" }) |ok|
        try t.expectEqual(@as(?Violation, null), check(ok));
}

test "command id: every spelling the old families used is refused, and says why" {
    const cases = [_]struct { []const u8, Violation }{
        .{ "buffer-next", .no_namespace },
        .{ "save", .no_namespace },
        .{ "fs.entry.create-file", .too_many_dots },
        .{ "vim/n/w", .no_namespace },
        .{ "motions.WORD-end", .invalid_character },
        .{ "motions.word-fwd", .banned_word },
        .{ "buffer.previous", .banned_word },
        .{ "snipe.repeat-rev", .banned_word },
        .{ "buffer.", .empty_word },
        .{ "git.push--force", .empty_word },
    };
    for (cases) |c| try t.expectEqual(@as(?Violation, c[1]), check(c[0]));
}
