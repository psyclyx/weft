//! `.editorconfig` (editorconfig.org), the part indentation reads:
//! `indent_style`, `indent_size`, `tab_width`. Pure — the plugin finds the
//! files and reads them through its fs door; this parses one file's text and
//! applies the sections that match a path.
//!
//! The spec's rules, as kept here: files apply from the one nearest the root
//! (`root = true` in a file's preamble stops the climb) to the one nearest
//! the file, and later sections and nearer files override; a section glob
//! with no `/` matches the file's name in any directory below, one with a `/`
//! matches the path from the `.editorconfig`'s directory (a leading `/`
//! anchors it there, as it does anyway). Globs: `*` (not across `/`), `**`,
//! `?`, `[abc]`, `[!abc]`, `[a-z]`, `{a,b}` (nesting), `\` escapes. Not kept:
//! `{1..9}` numeric ranges — they match nothing.

const std = @import("std");
const indentation = @import("indentation.zig");

pub const Size = union(enum) { columns: u8, tab };

/// What the matching sections said so far; a property set to `unset` is
/// null again, which is how a nearer file takes back what a farther one set.
pub const Props = struct {
    tabs: ?bool = null,
    size: ?Size = null,
    tab_width: ?u8 = null,

    /// What a nearer file's `p` says, over this.
    pub fn overlay(self: *Props, p: Props) void {
        if (p.tabs) |v| self.tabs = v;
        if (p.size) |v| self.size = v;
        if (p.tab_width) |v| self.tab_width = v;
    }

    /// As an indent unit: the style, and the width it implies — `indent_size`
    /// in columns, or `tab_width` where the size is `tab` or the style is
    /// tabs and no size was given.
    pub fn partial(self: Props) indentation.Partial {
        const width: ?u8 = if (self.size) |s| switch (s) {
            .columns => |c| c,
            .tab => self.tab_width,
        } else if (self.tabs orelse false) self.tab_width else null;
        return .{ .tabs = self.tabs, .width = width };
    }
};

/// Apply the sections of one `.editorconfig`'s `text` that match `rel` — the
/// file's path relative to that `.editorconfig`'s directory — onto `props`.
/// Returns whether the file's preamble says `root = true`.
pub fn apply(text: []const u8, rel: []const u8, props: *Props) bool {
    var root = false;
    var in_preamble = true;
    var matching = false;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#' or line[0] == ';') continue;
        if (line[0] == '[') {
            const close = std.mem.lastIndexOfScalar(u8, line, ']') orelse continue;
            in_preamble = false;
            matching = sectionMatches(line[1..close], rel);
            continue;
        }
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const value = std.mem.trim(u8, line[eq + 1 ..], " \t");
        if (in_preamble) {
            if (std.ascii.eqlIgnoreCase(key, "root")) root = std.ascii.eqlIgnoreCase(value, "true");
            continue;
        }
        if (!matching) continue;
        const unset = std.ascii.eqlIgnoreCase(value, "unset");
        if (std.ascii.eqlIgnoreCase(key, "indent_style")) {
            props.tabs = if (unset) null else if (std.ascii.eqlIgnoreCase(value, "tab")) true else if (std.ascii.eqlIgnoreCase(value, "space")) false else props.tabs;
        } else if (std.ascii.eqlIgnoreCase(key, "indent_size")) {
            props.size = if (unset) null else if (std.ascii.eqlIgnoreCase(value, "tab")) .tab else if (indentation.parseWidth(value)) |w| .{ .columns = w } else props.size;
        } else if (std.ascii.eqlIgnoreCase(key, "tab_width")) {
            props.tab_width = if (unset) null else indentation.parseWidth(value) orelse props.tab_width;
        }
    }
    return root;
}

/// Whether a section's glob covers `rel`.
pub fn sectionMatches(glob: []const u8, rel: []const u8) bool {
    // No `/`: the name, in this directory or any below it.
    if (std.mem.indexOfScalar(u8, glob, '/') == null) return match(glob, rel) or m("**/", &.{glob}, rel, 0);
    return match(if (glob[0] == '/') glob[1..] else glob, rel);
}

pub fn match(glob: []const u8, path: []const u8) bool {
    return m(glob, &.{}, path, 0);
}

/// Match `path` against `head` followed by the pieces of `more` — how a
/// `{a,b}` alternative goes on with the rest of the glob without the glob
/// being rebuilt. `level` is the brace nesting, which picks the stack a
/// continuation is built in (`push`).
fn m(head_in: []const u8, more: []const []const u8, path_in: []const u8, level: usize) bool {
    var head = head_in;
    var path = path_in;
    while (true) {
        if (head.len == 0) {
            if (more.len == 0) return path.len == 0;
            return m(more[0], more[1..], path, level);
        }
        switch (head[0]) {
            '*' => {
                const double = head.len > 1 and head[1] == '*';
                const after = head[if (double) 2 else 1..];
                var i: usize = 0;
                while (true) : (i += 1) {
                    if (m(after, more, path[i..], level)) return true;
                    if (i >= path.len) return false;
                    if (!double and path[i] == '/') return false;
                }
            },
            '?' => {
                if (path.len == 0 or path[0] == '/') return false;
                head = head[1..];
                path = path[1..];
            },
            '[' => {
                const close = std.mem.indexOfScalarPos(u8, head, 1, ']') orelse return literal(head, more, path, level);
                if (path.len == 0 or path[0] == '/' or !classMatches(head[1..close], path[0])) return false;
                head = head[close + 1 ..];
                path = path[1..];
            },
            '{' => {
                const close = braceEnd(head) orelse return literal(head, more, path, level);
                const body = head[1..close];
                const rest = head[close + 1 ..];
                const cont = push(level, rest, more) orelse return false;
                var depth: usize = 0;
                var from: usize = 0;
                for (body, 0..) |c, i| switch (c) {
                    '{' => depth += 1,
                    '}' => depth -|= 1,
                    ',' => if (depth == 0) {
                        if (m(body[from..i], cont, path, level + 1)) return true;
                        from = i + 1;
                    },
                    else => {},
                };
                // `{a}` with no comma is a literal brace pair, as the spec says.
                if (from == 0) return literal(head, more, path, level);
                return m(body[from..], cont, path, level + 1);
            },
            '\\' => {
                if (head.len < 2) return literal(head, more, path, level);
                if (path.len == 0 or path[0] != head[1]) return false;
                head = head[2..];
                path = path[1..];
            },
            else => {
                if (path.len == 0 or path[0] != head[0]) return false;
                head = head[1..];
                path = path[1..];
            },
        }
    }
}

/// `head[0]` taken as itself (an unclosed `[` or `{`, a trailing `\`).
fn literal(head: []const u8, more: []const []const u8, path: []const u8, level: usize) bool {
    return path.len > 0 and path[0] == head[0] and m(head[1..], more, path[1..], level);
}

/// The index of the `}` closing the `{` at `g[0]`, nesting counted.
fn braceEnd(g: []const u8) ?usize {
    var depth: usize = 0;
    for (g, 0..) |c, i| switch (c) {
        '{' => depth += 1,
        '}' => {
            depth -= 1;
            if (depth == 0) return i;
        },
        else => {},
    };
    return null;
}

fn classMatches(class: []const u8, c: u8) bool {
    const negate = class.len > 0 and (class[0] == '!' or class[0] == '^');
    const set = if (negate) class[1..] else class;
    var hit = false;
    var i: usize = 0;
    while (i < set.len) : (i += 1) {
        if (i + 2 < set.len and set[i + 1] == '-') {
            if (c >= set[i] and c <= set[i + 2]) hit = true;
            i += 2;
        } else if (set[i] == c) hit = true;
    }
    return hit != negate;
}

// The continuations `{…}` builds, one stack per brace level: a call at level
// L reads its continuation from level L-1's and builds its own in level L's,
// so an alternative tried later never overwrites one still being matched. A
// glob nests braces a few deep at most; past these bounds it matches nothing.
const max_levels = 8;
const max_parts = 16;
var stacks: [max_levels][max_parts][]const u8 = undefined;

fn push(level: usize, head: []const u8, more: []const []const u8) ?[]const []const u8 {
    if (level >= max_levels or more.len + 1 > max_parts) return null;
    const slot = &stacks[level];
    slot[0] = head;
    @memcpy(slot[1..][0..more.len], more);
    return slot[0 .. more.len + 1];
}

// ── Tests ───────────────────────────────────────────────────────────

const t = std.testing;

test "editorconfig glob: stars, classes, braces, escapes" {
    try t.expect(match("*.go", "main.go"));
    try t.expect(!match("*.go", "cmd/main.go"));
    try t.expect(match("**.go", "cmd/main.go"));
    try t.expect(match("src/**/*.zig", "src/a/b/c.zig"));
    try t.expect(match("*.{js,ts}", "x.ts"));
    try t.expect(!match("*.{js,ts}", "x.rs"));
    try t.expect(match("{lib/**,src/*}.c", "lib/x/y.c"));
    try t.expect(match("file?.txt", "file1.txt"));
    try t.expect(match("[Mm]akefile", "makefile"));
    try t.expect(!match("[!M]akefile", "Makefile"));
    try t.expect(match("[a-c]x", "bx"));
    try t.expect(match("\\*lit", "*lit"));
    try t.expect(match("{single}", "{single}"));
}

test "editorconfig section: a name matches in any directory, a path from the file's" {
    try t.expect(sectionMatches("*.go", "pkg/x/main.go"));
    try t.expect(sectionMatches("Makefile", "sub/Makefile"));
    try t.expect(sectionMatches("/src/*.c", "src/a.c"));
    try t.expect(!sectionMatches("src/*.c", "other/src/a.c"));
    try t.expect(sectionMatches("*", "a/b/c"));
}

test "editorconfig: later sections override, unset takes back, root stops the climb" {
    var p: Props = .{};
    const root = apply(
        \\# top of the project
        \\root = true
        \\
        \\[*]
        \\indent_style = space
        \\indent_size = 4
        \\
        \\[*.go]
        \\indent_style = tab
        \\indent_size = unset
        \\tab_width = 8
        \\
        \\[Makefile]
        \\indent_style = tab
    , "cmd/main.go", &p);
    try t.expect(root);
    try t.expectEqual(indentation.Partial{ .tabs = true, .width = 8 }, p.partial());

    var q: Props = .{};
    try t.expect(!apply("[*.js]\nindent_size = 2\n", "a.js", &q));
    try t.expectEqual(indentation.Partial{ .tabs = null, .width = 2 }, q.partial());

    // A nearer file overrides a farther one, property by property.
    var far: Props = .{};
    _ = apply("[*]\nindent_style = space\nindent_size = 2\n", "x.zig", &far);
    var near: Props = .{};
    _ = apply("[*.zig]\nindent_size = 4\n", "x.zig", &near);
    far.overlay(near);
    try t.expectEqual(indentation.Partial{ .tabs = false, .width = 4 }, far.partial());

    // `indent_size = tab` reads the tab width.
    var s: Props = .{};
    _ = apply("[*]\nindent_style = tab\nindent_size = tab\ntab_width = 3\n", "f", &s);
    try t.expectEqual(indentation.Partial{ .tabs = true, .width = 3 }, s.partial());
}
