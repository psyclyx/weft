//! files — a draft row as a LINE, and back.
//!
//! One implementation, two placements. A directory listing and a docked sidebar
//! were never two things: a sidebar is a VIEWPORT (`weft.viewport`) and
//! presenting a resource in one is an ordinary operation (`weft.present`), so
//! what a directory looks like should not depend on where it is shown.
//!
//! It did, because the listing was a SCENE and a scene is not a buffer, so
//! `presentIn` — which runs `open` and puts the resulting buffer in the pane —
//! had nothing to put there. Everything that made a scene worth choosing (row
//! identity, roles, affordances, folding, editable rows) is on the text
//! projection now, and a buffer goes in any viewport.
//!
//! This file is the PURE half: a row's line, its role, its key, and the reverse
//! reading of a line the user edited. No SDK, so it is tested natively like the
//! rest of the portable files library — `adapter.zig` does the publishing,
//! which is the only part that needs a host.

const std = @import("std");
const model = @import("weft_files_model");

/// Roles. What a row IS, in the one vocabulary every projection shares — so a
/// theme styles a directory listing and a repository the same way, and a third
/// party can `provide` a verb against `.{ .role = "fs.file" }` without knowing
/// this plugin exists.
pub const role_directory = "fs.directory";
pub const role_file = "fs.file";
pub const role_symlink = "fs.symlink";
pub const role_other = "fs.other";
/// The stretch of a row that is its NAME — what an edit is about, and the only
/// part a rename may change.
pub const role_name = "fs.name";
/// A row whose draft differs from what the filesystem last said.
pub const role_dirty = "fs.dirty";

/// Two cells per level, the same as the scene's `indent_cells`, so the listing
/// reads identically wherever it is shown.
pub const indent_cells = 2;

const indent_spaces = " " ** 128;

pub fn roleOf(row: model.Row) []const u8 {
    if (row.name_dirty or row.mode_dirty) return role_dirty;
    return switch (row.draft.kind) {
        .regular => role_file,
        .directory => role_directory,
        .symlink => role_symlink,
        .other => role_other,
    };
}

/// A directory's glyph carries its fold state, which is the one place display
/// and model genuinely touch.
pub fn glyphOf(row: model.Row) []const u8 {
    return switch (row.draft.kind) {
        .regular => "·",
        .directory => if (row.expanded) "▾" else "▸",
        .symlink => "↗",
        .other => "?",
    };
}

/// Depth of `row` in the draft, by walking parents. Bounded by the row count,
/// so a malformed parent chain terminates rather than hanging.
pub fn depthOf(rows: []const model.Row, row: model.Row) usize {
    var depth: usize = 0;
    var parent = row.parent;
    while (parent) |id| {
        if (depth > rows.len) return depth;
        depth += 1;
        parent = for (rows) |r| {
            if (r.id == id) break r.parent;
        } else null;
    }
    return depth;
}

/// One row as a line, and where its NAME starts within it.
pub const Line = struct {
    text: []const u8,
    name_at: usize,

    pub fn nameEnd(self: Line) usize {
        return self.text.len;
    }
};

/// Render `row` into `out`. The shape is `<indent><glyph> <name>` — the name
/// LAST, so everything before it is fixed-width per row and a name containing
/// anything at all cannot be confused for structure.
pub fn lineOf(rows: []const model.Row, row: model.Row, out: []u8) ?Line {
    const depth = @min(depthOf(rows, row) * indent_cells, indent_spaces.len);
    const glyph = glyphOf(row);
    const text = std.fmt.bufPrint(out, "{s}{s} {s}", .{
        indent_spaces[0..depth],
        glyph,
        row.draft.name,
    }) catch return null;
    return .{ .text = text, .name_at = depth + glyph.len + 1 };
}

/// A row's key: its model id, which is the identity the draft already uses.
/// Minted here and parsed back here, and never anything a person sees — the
/// display name is the row's TEXT, which is free to change under a rename
/// precisely BECAUSE it is not the identity.
pub fn keyOf(id: model.NodeId, out: []u8) []const u8 {
    return std.fmt.bufPrint(out, "{d}", .{id}) catch "";
}

pub fn idOf(key: []const u8) ?model.NodeId {
    if (key.len == 0) return null;
    return std.fmt.parseInt(model.NodeId, key, 10) catch null;
}

/// What the user's edit says this row's name is now.
///
/// Structure first, name last: skip the indent, skip the glyph, skip one
/// separator, and everything left is the name — including spaces, because a
/// file may have them and a rename that silently stopped at the first one would
/// be a rename to something else.
///
/// A row the user blanked reads as an empty name. The caller treats that as a
/// deletion rather than as a rename to "", which is why this returns the empty
/// string rather than refusing.
pub fn nameIn(row_text: []const u8) []const u8 {
    var i: usize = 0;
    while (i < row_text.len and row_text[i] == ' ') i += 1;
    if (i >= row_text.len) return "";
    // The glyph is one codepoint, however many bytes that is.
    const glyph_len = std.unicode.utf8ByteSequenceLength(row_text[i]) catch 1;
    i = @min(i + glyph_len, row_text.len);
    while (i < row_text.len and row_text[i] == ' ') i += 1;
    return std.mem.trimEnd(u8, row_text[i..], " \t\r");
}

const t = std.testing;

fn mkRow(id: model.NodeId, parent: ?model.NodeId, name: []u8, kind: @TypeOf(@as(model.Row, undefined).draft.kind)) model.Row {
    return .{
        .id = id,
        .parent = parent,
        .base = null,
        .current = null,
        .draft = .{ .name = name, .kind = kind, .mode = null, .contents = &.{}, .link_target = &.{} },
        .pending = .observed,
    };
}

test "files rows: a line is indent, glyph, name — and the name reads back whole" {
    var alpha = "alpha.txt".*;
    var src = "src".*;
    var deep = "a name with spaces.txt".*;
    const rows = [_]model.Row{
        mkRow(1, null, &src, .directory),
        mkRow(2, 1, &alpha, .regular),
        mkRow(3, 1, &deep, .regular),
    };

    var buf: [256]u8 = undefined;
    const top = lineOf(&rows, rows[0], &buf).?;
    try t.expectEqualStrings("▸ src", top.text);
    try t.expectEqualStrings("src", nameIn(top.text));

    const child = lineOf(&rows, rows[1], &buf).?;
    try t.expectEqualStrings("  · alpha.txt", child.text);
    // The indent is structure, not part of the name — the bug a naive
    // "everything after the first space" reading has.
    try t.expectEqualStrings("alpha.txt", nameIn(child.text));
    try t.expectEqualStrings("alpha.txt", child.text[child.name_at..]);

    // A name with spaces survives whole; a rename that stopped at the first
    // space would be a rename to something else.
    const spaced = lineOf(&rows, rows[2], &buf).?;
    try t.expectEqualStrings("a name with spaces.txt", nameIn(spaced.text));
}

test "files rows: what the user typed is what the name becomes" {
    // The edits a person actually makes to a listing.
    try t.expectEqualStrings("renamed.txt", nameIn("  · renamed.txt"));
    try t.expectEqualStrings("renamed.txt", nameIn("  · renamed.txt   ")); // trailing space
    try t.expectEqualStrings("nested", nameIn("    ▾ nested"));
    // Blanked outright: a deletion, not a rename to nothing.
    try t.expectEqualStrings("", nameIn(""));
    try t.expectEqualStrings("", nameIn("     "));
}

test "files rows: a key round-trips, and a name never parses as one" {
    var buf: [24]u8 = undefined;
    try t.expectEqualStrings("42", keyOf(42, &buf));
    try t.expectEqual(@as(?model.NodeId, 42), idOf("42"));
    try t.expectEqual(@as(?model.NodeId, null), idOf("alpha.txt"));
    try t.expectEqual(@as(?model.NodeId, null), idOf(""));
}

test "files rows: a role says what a row is, and dirt outranks kind" {
    var name = "f".*;
    var r = mkRow(1, null, &name, .regular);
    try t.expectEqualStrings(role_file, roleOf(r));
    r.draft.kind = .directory;
    try t.expectEqualStrings(role_directory, roleOf(r));
    // A renamed row reads as dirty whatever it is, because that is the fact a
    // person needs from the listing.
    r.name_dirty = true;
    try t.expectEqualStrings(role_dirty, roleOf(r));
}
