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
const projection = @import("weft_files_projection");

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

/// Is `row` under a COLLAPSED ancestor?
///
/// The model keeps a collapsed directory.s children rather than discarding them
/// — a draft made below one survives the round trip — so "collapsed" is a
/// question about ancestry, not about whether the rows exist. A listing that
/// published them all would fold nothing.
pub fn hidden(rows: []const model.Row, row: model.Row) bool {
    var parent = row.parent;
    var hops: usize = 0;
    while (parent) |id| {
        if (hops > rows.len) return false;
        hops += 1;
        const p = for (rows) |r| {
            if (r.id == id) break r;
        } else return false;
        if (!p.expanded) return true;
        parent = p.parent;
    }
    return false;
}

/// One row as a line, and where each of its PARTS is within it.
pub const Line = struct {
    text: []const u8,
    mode_at: usize,
    name_at: usize,

    pub fn modeEnd(self: Line) usize {
        return self.mode_at + mode_width;
    }

    pub fn nameEnd(self: Line) usize {
        return self.text.len;
    }
};

/// The permissions column, fixed-width so the names line up. Octal, as the
/// scene's `files.mode` field was — this is the same field, in the same
/// vocabulary, reached by putting point on it instead of by focusing a node.
pub const mode_width = 4;
const mode_absent = "-" ** mode_width;

/// The stretch of a row that is its MODE.
pub const role_mode = "fs.mode";

fn writeMode(mode: ?u32, out: *[mode_width]u8) []const u8 {
    const value = mode orelse {
        @memcpy(out, mode_absent);
        return out;
    };
    return std.fmt.bufPrint(out, "{o:0>4}", .{value & 0o7777}) catch blk: {
        @memcpy(out, mode_absent);
        break :blk out;
    };
}

/// WHAT THE USER TYPED, read back. One parser, because there is one thing to
/// read: the row's EDITABLE REGION, `<mode> <name>`, which is exactly the
/// stretch the host's row ferry hands back (it brackets that span and nothing
/// else). `nameIn`/`modeIn` are this same read, offered a whole row.
pub const Fields = struct {
    mode: ?u32,
    name: []const u8,
};

pub fn fieldsIn(edited: []const u8) Fields {
    var i: usize = 0;
    while (i < edited.len and edited[i] == ' ') i += 1;
    var mode: ?u32 = null;
    // The MODE COLUMN is consumed only while it still looks like one. A user
    // who blanked it has not renamed the file to its own first word — the
    // token stops parsing as a mode and the name reads from where it always
    // did. A lone token is a NAME: there is no name left for it to be the
    // column of.
    var j = i;
    while (j < edited.len and edited[j] != ' ') j += 1;
    if (j > i and j < edited.len) {
        const token = edited[i..j];
        if (std.mem.eql(u8, token, mode_absent)) {
            i = j;
        } else if (std.fmt.parseInt(u32, token, 8)) |value| {
            mode = value;
            i = j;
        } else |_| {}
    }
    while (i < edited.len and edited[i] == ' ') i += 1;
    return .{ .mode = mode, .name = std.mem.trimEnd(u8, edited[i..], " \t\r") };
}

/// The mode a whole ROW now says. Null is not a refusal: it is how a row whose
/// column the user blanked (or one that never had a mode) stays a rename
/// rather than becoming a chmod to zero.
pub fn modeIn(row_text: []const u8) ?u32 {
    return fieldsIn(row_text[afterGlyph(row_text)..]).mode;
}

/// Past the indent and the glyph — where a row's columns begin.
fn afterGlyph(row_text: []const u8) usize {
    var i: usize = 0;
    while (i < row_text.len and row_text[i] == ' ') i += 1;
    if (i >= row_text.len) return row_text.len;
    const glyph_len = std.unicode.utf8ByteSequenceLength(row_text[i]) catch 1;
    return @min(i + glyph_len, row_text.len);
}

/// A FILENAME IS BYTES; a text buffer is UTF-8. The scene plane could hold a
/// raw-byte name in a field, and a document cannot — so a listing that simply
/// wrote the name would either produce an invalid document or, worse, skip the
/// row and HIDE a file from a file manager.
///
/// Invalid bytes are shown as U+FFFD. The row is still there, still keyed by
/// its id, and still navigable; what it cannot do is be RENAMED by typing,
/// because what the user sees is not what the name is — `renamable` says so and
/// `applyEdits` refuses out loud rather than renaming to the replacement
/// character.
pub fn renamable(row: model.Row) bool {
    return std.unicode.utf8ValidateSlice(row.draft.name);
}

fn writeName(name: []const u8, out: []u8) usize {
    var w: usize = 0;
    var i: usize = 0;
    while (i < name.len) {
        const len = std.unicode.utf8ByteSequenceLength(name[i]) catch {
            if (w + 3 > out.len) return w;
            @memcpy(out[w..][0..3], "\u{FFFD}");
            w += 3;
            i += 1;
            continue;
        };
        if (i + len > name.len or !std.unicode.utf8ValidateSlice(name[i..][0..len])) {
            if (w + 3 > out.len) return w;
            @memcpy(out[w..][0..3], "\u{FFFD}");
            w += 3;
            i += 1;
            continue;
        }
        if (w + len > out.len) return w;
        @memcpy(out[w..][0..len], name[i..][0..len]);
        w += len;
        i += len;
    }
    return w;
}

/// Render `row` into `out`. The shape is `<indent><glyph> <mode> <name>` — the
/// name LAST, so everything before it is fixed-width per row and a name
/// containing anything at all cannot be confused for structure.
pub fn lineOf(rows: []const model.Row, row: model.Row, out: []u8) ?Line {
    const depth = @min(depthOf(rows, row) * indent_cells, indent_spaces.len);
    const glyph = glyphOf(row);
    var mode_buf: [mode_width]u8 = undefined;
    const head = std.fmt.bufPrint(out, "{s}{s} {s} ", .{
        indent_spaces[0..depth],
        glyph,
        writeMode(row.draft.mode, &mode_buf),
    }) catch return null;
    const w = head.len + writeName(row.draft.name, out[head.len..]);
    return .{
        .text = out[0..w],
        .mode_at = head.len - (mode_width + 1),
        .name_at = head.len,
    };
}

/// A row.s key IS its scene NODE ID, in decimal.
///
/// The key is the producer.s to choose, and choosing this one makes the bridge
/// trivial: core can answer an action on "the row under point" by reading the
/// key and handing it to the same `invokeAction` a scene-backed view goes
/// through — with the system transfer, the selected register, and the
/// interaction stack all filled in on the host side, where they live.
///
/// It is never anything a person sees. The display name is the row.s TEXT,
/// which is free to change under a rename precisely BECAUSE it is not the
/// identity.
pub fn keyOf(id: model.NodeId, out: []u8) []const u8 {
    const node = projection.rowNodeId(id) catch return "";
    return std.fmt.bufPrint(out, "{d}", .{@intFromEnum(node)}) catch "";
}

/// The key of a row's NAME part, and of its MODE part — the scene nodes the
/// columns already were. A part key IS a subject core can hand to
/// `invokeAction`, so `SPC v m`'s field focus lands point in the mode column
/// with no second vocabulary for "which part of a row".
pub fn nameKeyOf(id: model.NodeId, out: []u8) []const u8 {
    const node = projection.nameNodeId(id) catch return "";
    return std.fmt.bufPrint(out, "{d}", .{@intFromEnum(node)}) catch "";
}

pub fn modeKeyOf(id: model.NodeId, out: []u8) []const u8 {
    const node = projection.modeNodeId(id) catch return "";
    return std.fmt.bufPrint(out, "{d}", .{@intFromEnum(node)}) catch "";
}

pub fn idOf(key: []const u8) ?model.NodeId {
    if (key.len == 0) return null;
    const raw = std.fmt.parseInt(u64, key, 10) catch return null;
    return projection.modelRowId(@enumFromInt(raw)) catch null;
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
    return fieldsIn(row_text[afterGlyph(row_text)..]).name;
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

test "files rows: a line is indent, glyph, mode, name — and each part reads back whole" {
    var alpha = "alpha.txt".*;
    var src = "src".*;
    var deep = "a name with spaces.txt".*;
    var rows = [_]model.Row{
        mkRow(1, null, &src, .directory),
        mkRow(2, 1, &alpha, .regular),
        mkRow(3, 1, &deep, .regular),
    };
    rows[1].draft.mode = 0o644;

    var buf: [256]u8 = undefined;
    // No mode reported: the column is still there, so the names line up and
    // the parse never has to guess which token it is looking at.
    const top = lineOf(&rows, rows[0], &buf).?;
    try t.expectEqualStrings("▸ ---- src", top.text);
    try t.expectEqualStrings("src", nameIn(top.text));
    try t.expectEqual(@as(?u32, null), modeIn(top.text));

    const child = lineOf(&rows, rows[1], &buf).?;
    try t.expectEqualStrings("  · 0644 alpha.txt", child.text);
    // The indent and the mode are structure, not part of the name — the bug a
    // naive "everything after the first space" reading has.
    try t.expectEqualStrings("alpha.txt", nameIn(child.text));
    try t.expectEqualStrings("alpha.txt", child.text[child.name_at..]);
    try t.expectEqualStrings("0644", child.text[child.mode_at..child.modeEnd()]);
    try t.expectEqual(@as(?u32, 0o644), modeIn(child.text));

    // A name with spaces survives whole; a rename that stopped at the first
    // space would be a rename to something else.
    const spaced = lineOf(&rows, rows[2], &buf).?;
    try t.expectEqualStrings("a name with spaces.txt", nameIn(spaced.text));
}

test "files rows: what the user typed is what the name becomes" {
    // The edits a person actually makes to a listing.
    try t.expectEqualStrings("renamed.txt", nameIn("  · 0644 renamed.txt"));
    try t.expectEqualStrings("renamed.txt", nameIn("  · 0644 renamed.txt   ")); // trailing space
    try t.expectEqualStrings("nested", nameIn("    ▾ ---- nested"));
    // Blanked outright: a deletion, not a rename to nothing.
    try t.expectEqualStrings("", nameIn(""));
    try t.expectEqualStrings("", nameIn("     "));
}

test "files rows: a mangled mode column costs the mode, never the name" {
    // BLANKING THE COLUMN MUST NOT EAT A WORD. Positional parsing would read
    // `renamed.txt` as the mode and `here` as the whole name; token parsing
    // sees something that is not a mode and stops treating it as a column.
    try t.expectEqualStrings("renamed.txt here", nameIn("  · renamed.txt here"));
    try t.expectEqual(@as(?u32, null), modeIn("  · renamed.txt here"));
    // A row whose NAME is itself octal still reads as a name, because the
    // column before it is what is being skipped.
    try t.expectEqualStrings("0644", nameIn("  · 0755 0644"));
    try t.expectEqual(@as(?u32, 0o755), modeIn("  · 0755 0644"));
    // A lone octal token with nothing after it is a NAME: there is no name
    // left for it to be the column of.
    try t.expectEqualStrings("0644", nameIn("  · 0644"));
    // What the user typed in the column is what the mode becomes.
    try t.expectEqual(@as(?u32, 0o600), modeIn("  · 0600 alpha.txt"));
}

test "files rows: a key round-trips through the SCENE node id, and a name never parses as one" {
    // The key is the row.s scene node id, so core can hand it straight to the
    // same `invokeAction` a scene-backed view goes through. What matters is
    // that it round-trips and that nothing a person types looks like one.
    var buf: [24]u8 = undefined;
    const key = keyOf(42, &buf);
    try t.expect(key.len > 0);
    try t.expectEqual(@as(?model.NodeId, 42), idOf(key));
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

test "files rows: a raw-byte filename is SHOWN, not hidden, and not renamable" {
    // A filename is bytes; a document is UTF-8. The scene plane could hold a
    // raw name in a field and a buffer cannot, so this is the one place the
    // text projection genuinely gives something up — and what it must NOT do
    // is drop the row, because a file manager that hides a file is worse than
    // one that cannot rename it.
    var raw = [_]u8{ 'b', 'a', 'd', 0xff, 0xfe, '.', 't', 'x', 't' };
    const rows = [_]model.Row{mkRow(1, null, &raw, .regular)};

    var buf: [256]u8 = undefined;
    const line = lineOf(&rows, rows[0], &buf).?;
    // Valid UTF-8, so it can go in a document at all.
    try t.expect(std.unicode.utf8ValidateSlice(line.text));
    // The row is THERE, and the parts that were readable still read.
    try t.expect(std.mem.indexOf(u8, line.text, "bad") != null);
    try t.expect(std.mem.indexOf(u8, line.text, ".txt") != null);
    // Two bad bytes, two replacement characters — not one, and not a run.
    try t.expectEqual(@as(usize, 2), std.mem.count(u8, line.text, "\u{FFFD}"));

    // And it says so: what is displayed is not what the name IS, so a rename
    // typed here would rename to the replacement character.
    try t.expect(!renamable(rows[0]));
    var ok = "fine.txt".*;
    const good = [_]model.Row{mkRow(1, null, &ok, .regular)};
    try t.expect(renamable(good[0]));
}

test "files rows: a collapsed directory's children are hidden, not discarded" {
    // The model KEEPS a collapsed row's children — a draft made below one has
    // to survive the round trip — so "collapsed" is a question about ancestry.
    // A listing that published every row would fold nothing.
    var dir = "src".*;
    var inner = "inner.txt".*;
    var deep = "deep.txt".*;
    var top = "top.txt".*;
    var rows = [_]model.Row{
        mkRow(1, null, &dir, .directory),
        mkRow(2, 1, &inner, .regular),
        mkRow(3, 2, &deep, .regular),
        mkRow(4, null, &top, .regular),
    };

    rows[0].expanded = true;
    rows[1].expanded = true;
    for (rows) |r| try t.expect(!hidden(&rows, r));

    // Collapsing the TOP one hides everything beneath it, however deep.
    rows[0].expanded = false;
    try t.expect(!hidden(&rows, rows[0]));
    try t.expect(hidden(&rows, rows[1]));
    try t.expect(hidden(&rows, rows[2]));
    // …and nothing outside it.
    try t.expect(!hidden(&rows, rows[3]));
}
