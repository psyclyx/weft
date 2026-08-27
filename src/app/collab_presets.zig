//! Preset share bundles (doc/contextual-workspace-architecture.md §13.6:
//! "Presets compile to atomic grant bundles"). A `Preset` is DATA — a fixed
//! set of `Toggle`s — never a free-text string a plugin or config author
//! supplies. `echo` renders the share preview from a bundle's toggles alone,
//! so the text a human approves and the authority actually granted can never
//! diverge (the confused-deputy rule §13.6 states explicitly). Sibling
//! `uc/export-grants` was expected to own the wire `Grant` shape this
//! compiles into; it does not exist yet, so this module stays a minimal,
//! self-contained seam — `GrantBundle` is a value a future export-grant
//! minter can consume, not a stand-in for the wire type itself.

const std = @import("std");

/// One toggle line in a share preview (§13.6's checkbox list). `surface` is
/// the fixed, code-owned label for a toggle — a preset selects WHICH toggles
/// apply, it never supplies its own label text. Ordered as declared; `echo`
/// walks this order so preview text is deterministic.
pub const Toggle = enum {
    edit,
    presence,
    code_intel,
    project_read,
    project_write,
    git_status,
    git_mutate,
    process,

    pub fn surface(self: Toggle) []const u8 {
        return switch (self) {
            .edit => "Edit this document",
            .presence => "See my cursor",
            .code_intel => "Code intelligence for this document",
            .project_read => "Read the rest of the project",
            .project_write => "Modify project files",
            .git_status => "Git status and diffs",
            .git_mutate => "Stage, commit, or push",
            .process => "Run processes or debugger",
        };
    }
};

/// A grant bundle: the set of toggles a share turns on. Deliberately has no
/// free-text field — a preset CANNOT inject arbitrary preview text because
/// the type gives it nowhere to put any.
pub const GrantBundle = struct {
    toggles: []const Toggle,

    pub fn has(self: GrantBundle, toggle: Toggle) bool {
        for (self.toggles) |x| if (x == toggle) return true;
        return false;
    }
};

/// §13.6: "selected resources read-only, optional presence." v1 keeps
/// presence on by default — the person sharing sees the selection (§13.1).
pub const look_together: GrantBundle = .{ .toggles = &.{.presence} };

/// §13.6: "selected document edit, presence, document-scoped language
/// service."
pub const pair: GrantBundle = .{ .toggles = &.{ .edit, .presence, .code_intel } };

/// §13.6: "repository status/diff and shared review artifacts, no
/// mutation."
pub const review: GrantBundle = .{ .toggles = &.{.git_status} };

/// Look up a preset by its config/command-line name. `null` for an unknown
/// name — callers must not guess a default bundle for a typo.
pub fn find(name: []const u8) ?GrantBundle {
    if (std.mem.eql(u8, name, "look_together") or std.mem.eql(u8, name, "look-together")) return look_together;
    if (std.mem.eql(u8, name, "pair")) return pair;
    if (std.mem.eql(u8, name, "review")) return review;
    return null;
}

/// Derive the share preview/echo text from `bundle`'s toggles alone, never
/// from preset- or provider-supplied free text (§13.6, the demolition
/// checklist's "approval dialogs rendering provider-supplied labels for
/// grants"). Truncates into `buf` rather than allocating; returns the
/// written slice.
pub fn echo(buf: []u8, resource_name: []const u8, bundle: GrantBundle) []const u8 {
    var w: std.Io.Writer = .fixed(buf);
    w.print("share {s}:", .{resource_name}) catch {};
    inline for (std.meta.fields(Toggle)) |f| {
        const toggle: Toggle = @enumFromInt(f.value);
        if (bundle.has(toggle)) w.print(" [x] {s};", .{toggle.surface()}) catch {};
    }
    return w.buffered();
}

// ── Tests ───────────────────────────────────────────────────────────

const t = std.testing;

test "presets: find resolves the three named bundles, rejects a typo" {
    try t.expectEqualSlices(Toggle, look_together.toggles, find("look_together").?.toggles);
    try t.expectEqualSlices(Toggle, pair.toggles, find("pair").?.toggles);
    try t.expectEqualSlices(Toggle, review.toggles, find("review").?.toggles);
    try t.expectEqual(@as(?GrantBundle, null), find("look-together-please"));
}

test "presets: echo round-trips from the bundle values, in declared order, nothing else" {
    var buf: [256]u8 = undefined;
    const got = echo(&buf, "parser.zig", pair);
    try t.expectEqualStrings(
        "share parser.zig: [x] Edit this document; [x] See my cursor; [x] Code intelligence for this document;",
        got,
    );

    // Every toggle the bundle carries appears; nothing outside it does.
    inline for (std.meta.fields(Toggle)) |f| {
        const tok: Toggle = @enumFromInt(f.value);
        const present = std.mem.indexOf(u8, got, tok.surface()) != null;
        try t.expectEqual(pair.has(tok), present);
    }
}

test "presets: a GrantBundle has no free-text field — a preset cannot inject arbitrary preview text" {
    // Structural guarantee, not a runtime check: `GrantBundle`'s only field is
    // `toggles: []const Toggle`, a closed enum set. There is no string field
    // a preset (or config, or a remote peer) could populate to make `echo`
    // print anything other than the fixed `Toggle.surface()` labels.
    const fields = std.meta.fields(GrantBundle);
    try t.expectEqual(@as(usize, 1), fields.len);
    try t.expectEqualStrings("toggles", fields[0].name);
    try t.expectEqual([]const Toggle, fields[0].type);
}

test {
    std.testing.refAllDecls(@This());
}
