//! What a person reads about a command (doc/chrome.md §1.2): the half of a
//! command's identity that is for people, beside the id that is for machines.
//! One value, and one text form of it, shared by the host and every guest —
//! the wire crosses as the text below in both directions (a plugin declaring
//! its commands, a UI reading them back), so the two ends cannot parse it
//! differently.
//!
//! The text form is one `key<TAB>value` line per field that is set, in any
//! order; a line with an unknown key is skipped, so a field added here does
//! not break an older reader. A value never holds a tab or a newline.

const std = @import("std");

pub const Presentation = struct {
    /// What a person reads, Title Case (`Split Editor Right`). Never ends in
    /// `…`: that mark is `prompts`', added where the label is shown.
    label: []const u8 = "",
    /// One sentence, capitalised, ending in a full stop. A registered
    /// command's own summary travels beside its declaration
    /// (`declare_command_doc`); this field is how a READER receives it, and
    /// how the config tier rewrites it.
    summary: []const u8 = "",
    /// Where it lives in the menubar, `/`-separated (`View/Editor Layout`).
    /// Empty: in no menu.
    menu: []const u8 = "",
    /// The separator group within its menu (`layout`).
    group: []const u8 = "",
    /// Position within the group; lower sorts first.
    order: ?i32 = null,
    /// An icon name from the theme's set (`split-right`).
    icon: []const u8 = "",
    /// It asks for more input before it acts, so its label reads `Open File…`.
    prompts: bool = false,
    /// A context key whose truthy value shows a check mark beside it
    /// (`viewport.sidebar.shown`) — or `key=value`, one choice among several,
    /// shown with a dot while the key holds that value
    /// (`theme.chrome=widget`).
    toggle: []const u8 = "",
    /// Keymap machinery, never listed in the palette, a menu or which-key.
    internal: bool = false,

    pub fn isEmpty(self: Presentation) bool {
        return self.label.len == 0 and self.summary.len == 0 and self.menu.len == 0 and self.group.len == 0 and
            self.order == null and self.icon.len == 0 and !self.prompts and
            self.toggle.len == 0 and !self.internal;
    }

    /// `over`'s fields where it sets them, this one's elsewhere: the config
    /// tier describing a command a plugin already described.
    pub fn overlaid(self: Presentation, over: Presentation) Presentation {
        return .{
            .label = if (over.label.len > 0) over.label else self.label,
            .summary = if (over.summary.len > 0) over.summary else self.summary,
            .menu = if (over.menu.len > 0) over.menu else self.menu,
            .group = if (over.group.len > 0) over.group else self.group,
            .order = over.order orelse self.order,
            .icon = if (over.icon.len > 0) over.icon else self.icon,
            .prompts = over.prompts or self.prompts,
            .toggle = if (over.toggle.len > 0) over.toggle else self.toggle,
            .internal = over.internal or self.internal,
        };
    }

    /// The label as shown: `label`, then `…` when the command prompts.
    /// Falls back to `fallback` (the id, say) when there is no label.
    pub fn shown(self: Presentation, buf: []u8, fallback: []const u8) []const u8 {
        const base = if (self.label.len > 0) self.label else fallback;
        if (!self.prompts) return base;
        return std.fmt.bufPrint(buf, "{s}…", .{base}) catch base;
    }
};

const Field = enum { label, summary, menu, group, order, icon, prompts, toggle, internal };

/// Why a presentation cannot be written down.
pub const Error = error{
    /// A value holds a tab or newline, which the text form cannot carry.
    InvalidCharacter,
    NoSpaceLeft,
};

/// `p` in its text form, into `buf`.
pub fn encode(buf: []u8, p: Presentation) Error![]const u8 {
    var w: std.Io.Writer = .fixed(buf);
    inline for (std.meta.fields(Field)) |f| {
        const field: Field = @enumFromInt(f.value);
        switch (field) {
            .order => if (p.order) |o| w.print("order\t{d}\n", .{o}) catch return error.NoSpaceLeft,
            .prompts, .internal => if (@field(p, f.name)) w.writeAll(f.name ++ "\ton\n") catch return error.NoSpaceLeft,
            else => {
                const v: []const u8 = @field(p, f.name);
                if (v.len > 0) {
                    if (std.mem.indexOfAny(u8, v, "\t\n") != null) return error.InvalidCharacter;
                    w.print("{s}\t{s}\n", .{ f.name, v }) catch return error.NoSpaceLeft;
                }
            },
        }
    }
    return w.buffered();
}

/// The presentation `text` spells. Strings BORROW `text`. Malformed lines and
/// unknown keys are skipped rather than failing the whole description.
pub fn decode(text: []const u8) Presentation {
    var p: Presentation = .{};
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const tab = std.mem.indexOfScalar(u8, line, '\t') orelse continue;
        const key = line[0..tab];
        const value = line[tab + 1 ..];
        const field = std.meta.stringToEnum(Field, key) orelse continue;
        switch (field) {
            .label => p.label = value,
            .summary => p.summary = value,
            .menu => p.menu = value,
            .group => p.group = value,
            .order => p.order = std.fmt.parseInt(i32, value, 10) catch null,
            .icon => p.icon = value,
            .prompts => p.prompts = std.mem.eql(u8, value, "on"),
            .toggle => p.toggle = value,
            .internal => p.internal = std.mem.eql(u8, value, "on"),
        }
    }
    return p;
}

// ── Tests ───────────────────────────────────────────────────────────

const t = std.testing;

test "presentation: the text form round-trips every field, and an empty one is empty" {
    var buf: [256]u8 = undefined;
    const p: Presentation = .{
        .label = "Split Editor Right",
        .summary = "Split the focused editor, opening the same file to the right.",
        .menu = "View/Editor Layout",
        .group = "layout",
        .order = -3,
        .icon = "split-right",
        .prompts = true,
        .toggle = "viewport.sidebar.shown",
        .internal = true,
    };
    const back = decode(try encode(&buf, p));
    try t.expectEqualDeep(p, back);
    try t.expectEqualStrings("", try encode(&buf, .{}));
    try t.expect(decode("").isEmpty());
}

test "presentation: unknown keys and malformed lines are skipped, a tab in a value is refused" {
    const p = decode("colour\tred\nlabel\tSave\nnot a field line\norder\tlots\n");
    try t.expectEqualStrings("Save", p.label);
    try t.expectEqual(@as(?i32, null), p.order);
    var buf: [64]u8 = undefined;
    try t.expectError(error.InvalidCharacter, encode(&buf, .{ .label = "a\tb" }));
    try t.expectError(error.NoSpaceLeft, encode(buf[0..4], .{ .label = "Save" }));
}

test "presentation: a label shows its prompt mark, and the config tier overlays field by field" {
    var buf: [64]u8 = undefined;
    try t.expectEqualStrings("Open File…", (Presentation{ .label = "Open File", .prompts = true }).shown(&buf, "files.find"));
    try t.expectEqualStrings("files.find", (Presentation{}).shown(&buf, "files.find"));
    const plugin: Presentation = .{ .label = "Find File", .menu = "File", .icon = "file" };
    const config: Presentation = .{ .label = "Datei öffnen", .order = 2 };
    const both = plugin.overlaid(config);
    try t.expectEqualStrings("Datei öffnen", both.label);
    try t.expectEqualStrings("File", both.menu);
    try t.expectEqual(@as(?i32, 2), both.order);
}
