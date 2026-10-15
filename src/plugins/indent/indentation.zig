//! The pure half of the `indent` plugin: what one indent step is, how a
//! file's own lines say which one it uses, and the bracket reading auto-indent
//! and electric dedent stand on. No `weft` import, so all of it is tested
//! natively (build.zig wires this file's tests into `zig build test`).
//!
//! DETECTION is vim-sleuth's and VS Code's `detectIndentation` idea, kept
//! small: a line indented with a tab votes tabs, a line indented with two or
//! more spaces votes spaces, and the step is the commonest change in indent
//! between neighbouring non-blank lines (2–8 columns — a one-column change is
//! alignment, not a level). Blank lines and the ` * ` continuation lines of a
//! block comment vote nothing. A file with no indented line says nothing, and
//! the caller falls back to what config says.

const std = @import("std");

/// One indent step: a tab, or `width` spaces. `width` is also the tab stop
/// the Tab key steps to and Backspace steps back to in a spaces file.
pub const Unit = struct {
    tabs: bool,
    width: u8,

    /// What a buffer gets when neither the file nor config says anything.
    pub const builtin: Unit = .{ .tabs = false, .width = 4 };

    /// The step's bytes, into `buf` (at least `max_width` long).
    pub fn bytes(self: Unit, buf: []u8) []const u8 {
        if (self.tabs) {
            buf[0] = '\t';
            return buf[0..1];
        }
        const n = @min(self.width, buf.len);
        @memset(buf[0..n], ' ');
        return buf[0..n];
    }
};

/// The widest step a spec or a file may name.
pub const max_width = 16;

/// What one source says about the unit — either half may be unsaid, and the
/// first source that says it wins (`resolve`).
pub const Partial = struct {
    tabs: ?bool = null,
    width: ?u8 = null,

    pub fn isEmpty(self: Partial) bool {
        return self.tabs == null and self.width == null;
    }
};

/// The unit `layers` say, nearest first: each half from the first layer that
/// says it, else `Unit.builtin`'s.
pub fn resolve(layers: []const Partial) Unit {
    var u: Partial = .{};
    for (layers) |l| {
        if (u.tabs == null) u.tabs = l.tabs;
        if (u.width == null) u.width = l.width;
    }
    return .{ .tabs = u.tabs orelse Unit.builtin.tabs, .width = u.width orelse Unit.builtin.width };
}

/// Parse a unit spec as config and `indent.set` spell it: `tabs`, `tab`,
/// `tabs:8` (the tab stop), `spaces`, `spaces:2`, `spaces 2`, or a bare `2`.
/// Null for anything else, or a width outside 1–16.
pub fn parseSpec(spec_in: []const u8) ?Partial {
    const spec = std.mem.trim(u8, spec_in, " \t");
    if (spec.len == 0) return null;
    const sep = std.mem.indexOfAny(u8, spec, ": ");
    const word = if (sep) |i| spec[0..i] else spec;
    const rest = if (sep) |i| std.mem.trim(u8, spec[i + 1 ..], " :") else "";
    if (std.ascii.isDigit(word[0])) {
        if (sep != null) return null;
        return .{ .tabs = false, .width = parseWidth(word) orelse return null };
    }
    const tabs = if (eqlAny(word, &.{ "tabs", "tab" }))
        true
    else if (eqlAny(word, &.{ "spaces", "space" }))
        false
    else
        return null;
    if (rest.len == 0) return .{ .tabs = tabs };
    return .{ .tabs = tabs, .width = parseWidth(rest) orelse return null };
}

pub fn parseWidth(text: []const u8) ?u8 {
    const n = std.fmt.parseInt(u8, std.mem.trim(u8, text, " "), 10) catch return null;
    return if (n >= 1 and n <= max_width) n else null;
}

fn eqlAny(a: []const u8, options: []const []const u8) bool {
    for (options) |o| if (std.ascii.eqlIgnoreCase(a, o)) return true;
    return false;
}

/// Whether `on`/`off`-style config `value` says yes (`off`, `false`, `no`,
/// `0` say no; anything else, yes).
pub fn truthy(value: []const u8) bool {
    return !eqlAny(std.mem.trim(u8, value, " "), &.{ "off", "false", "no", "0" });
}

// ── Detection ───────────────────────────────────────────────────────

pub const Detector = struct {
    tab_lines: u32 = 0,
    space_lines: u32 = 0,
    /// How often each change of indent (index = columns, 2..8) was seen
    /// between neighbouring space-indented (or unindented) lines.
    deltas: [9]u32 = @splat(0),
    /// The previous counted line's indent in spaces; null after a line
    /// indented with a tab (a change from a tab-indented line measures
    /// nothing).
    prev: ?usize = 0,

    /// Count one line (no line break).
    pub fn line(self: *Detector, text: []const u8) void {
        const ws = leadingWs(text);
        if (ws.len == text.len) return; // blank: votes nothing, breaks nothing
        const first = text[ws.len];
        // ` * foo` / ` */`: a block comment's continuation, aligned under its
        // opening `/*` — alignment, not a level.
        if (first == '*' and (ws.len + 1 == text.len or text[ws.len + 1] == ' ' or text[ws.len + 1] == '/')) return;
        if (std.mem.indexOfScalar(u8, ws, '\t')) |at| {
            // A tab first is a tab-indented line (spaces after it are
            // alignment); spaces then a tab is a mixed line that says neither.
            if (at == 0) self.tab_lines += 1;
            self.prev = null;
            return;
        }
        const n = ws.len;
        if (n >= 2) self.space_lines += 1;
        if (self.prev) |p| {
            const d = if (n > p) n - p else p - n;
            if (d >= 2 and d < self.deltas.len) self.deltas[d] += 1;
        }
        self.prev = n;
    }

    /// Count every line of `text` (a complete run of lines; a final line
    /// without a line break counts too).
    pub fn feed(self: *Detector, text: []const u8) void {
        var it = std.mem.splitScalar(u8, text, '\n');
        while (it.next()) |l| self.line(std.mem.trimEnd(u8, l, "\r"));
    }

    /// What the lines counted say: tabs or spaces by majority (a tie says
    /// neither), and for spaces the commonest step, ties to the smaller.
    pub fn result(self: *const Detector) Partial {
        if (self.tab_lines > self.space_lines) return .{ .tabs = true };
        if (self.space_lines == 0 or self.space_lines == self.tab_lines) return .{};
        var best: ?u8 = null;
        var best_n: u32 = 0;
        for (self.deltas, 0..) |n, d| if (n > best_n) {
            best = @intCast(d);
            best_n = n;
        };
        return .{ .tabs = false, .width = best };
    }
};

pub fn detect(text: []const u8) Partial {
    var d: Detector = .{};
    d.feed(text);
    return d.result();
}

// ── Lines and brackets ──────────────────────────────────────────────

pub fn isWs(c: u8) bool {
    return c == ' ' or c == '\t';
}

/// The run of spaces and tabs `line` starts with.
pub fn leadingWs(line: []const u8) []const u8 {
    var i: usize = 0;
    while (i < line.len and isWs(line[i])) i += 1;
    return line[0..i];
}

pub fn allWs(text: []const u8) bool {
    return leadingWs(text).len == text.len;
}

pub fn isOpener(c: u8) bool {
    return c == '{' or c == '(' or c == '[';
}

pub fn isCloser(c: u8) bool {
    return c == '}' or c == ')' or c == ']';
}

pub fn openerOf(closer: u8) u8 {
    return switch (closer) {
        '}' => '{',
        ')' => '(',
        ']' => '[',
        else => 0,
    };
}

/// Whether the text before a line break ends with an opener (trailing
/// spaces aside) — the line the break leaves opens a level.
pub fn endsWithOpener(before: []const u8) bool {
    const trimmed = std.mem.trimEnd(u8, before, " \t");
    return trimmed.len > 0 and isOpener(trimmed[trimmed.len - 1]);
}

/// Where in `text` the opener sits that a `closer` placed right after `text`
/// closes: brackets nest across kinds, and a bracket inside a `"…"` string
/// on its line is text, not structure. Null when nothing is open, or when
/// what is open is another kind (the closer is unbalanced; nothing to align
/// it with).
pub fn matchOpener(text: []const u8, closer: u8) ?usize {
    var depth: usize = 0;
    var end = text.len;
    while (true) {
        const start = if (std.mem.lastIndexOfScalar(u8, text[0..end], '\n')) |nl| nl + 1 else 0;
        const line = text[start..end];
        // This line's brackets outside strings, in order; then walked backward.
        var marks: [256]u16 = undefined;
        var n: usize = 0;
        var in_string = false;
        var i: usize = 0;
        while (i < line.len) : (i += 1) {
            const c = line[i];
            if (in_string) {
                if (c == '\\') i += 1 else if (c == '"') in_string = false;
            } else if (c == '"') {
                in_string = true;
            } else if ((isOpener(c) or isCloser(c)) and n < marks.len and i <= std.math.maxInt(u16)) {
                marks[n] = @intCast(i);
                n += 1;
            }
        }
        while (n > 0) {
            n -= 1;
            const at = start + marks[n];
            const c = text[at];
            if (isCloser(c)) {
                depth += 1;
            } else if (depth > 0) {
                depth -= 1;
            } else {
                return if (c == openerOf(closer)) at else null;
            }
        }
        if (start == 0) return null;
        end = start - 1;
    }
}

/// The display column of the end of `before` (a line's text up to a
/// caret), a tab advancing to the next multiple of `tab_width`.
pub fn column(before: []const u8, tab_width: u8) usize {
    const w: usize = @max(tab_width, 1);
    var col: usize = 0;
    for (before) |c| col = if (c == '\t') (col / w + 1) * w else col + 1;
    return col;
}

/// How many spaces Tab inserts at display column `col`: to the next stop.
pub fn spacesToStop(col: usize, width: u8) usize {
    const w: usize = @max(width, 1);
    return w - col % w;
}

/// How many spaces Backspace takes back at the end of `before`, when
/// `before` is nothing but spaces: back to the previous stop (a whole step
/// at a stop). Null when it is not all spaces — then Backspace is one
/// character, as anywhere else.
pub fn spacesToPrevStop(before: []const u8, width: u8) ?usize {
    if (before.len == 0) return null;
    for (before) |c| if (c != ' ') return null;
    const w: usize = @max(width, 1);
    const r = before.len % w;
    return if (r == 0) w else r;
}

/// A file's language as weft keys it everywhere — the `lang` fact, the
/// `lsp` plugin's `weft.set("lsp", "<lang>", …)`: its extension without the
/// dot (`go`, `zig`). A name with no extension (`Makefile`) is its own key,
/// so a config can still say something about it.
pub fn langOf(path: []const u8) []const u8 {
    const base = if (std.mem.lastIndexOfScalar(u8, path, '/')) |i| path[i + 1 ..] else path;
    const dot = std.mem.lastIndexOfScalar(u8, base, '.') orelse return base;
    if (dot == 0 or dot + 1 >= base.len) return base;
    return base[dot + 1 ..];
}

// ── Tests ───────────────────────────────────────────────────────────

const t = std.testing;

test "indent spec: tabs, spaces, widths, and refusals" {
    try t.expectEqual(Partial{ .tabs = true }, parseSpec("tabs").?);
    try t.expectEqual(Partial{ .tabs = true, .width = 8 }, parseSpec("tab:8").?);
    try t.expectEqual(Partial{ .tabs = false }, parseSpec(" spaces ").?);
    try t.expectEqual(Partial{ .tabs = false, .width = 2 }, parseSpec("spaces:2").?);
    try t.expectEqual(Partial{ .tabs = false, .width = 3 }, parseSpec("spaces 3").?);
    try t.expectEqual(Partial{ .tabs = false, .width = 4 }, parseSpec("4").?);
    try t.expect(parseSpec("") == null);
    try t.expect(parseSpec("wide") == null);
    try t.expect(parseSpec("spaces:0") == null);
    try t.expect(parseSpec("spaces:99") == null);
    try t.expect(parseSpec("4 2") == null);
}

test "indent resolve: each half from the nearest layer that says it" {
    const u = resolve(&.{ .{}, .{ .tabs = true }, .{ .tabs = false, .width = 2 } });
    try t.expectEqual(Unit{ .tabs = true, .width = 2 }, u);
    try t.expectEqual(Unit.builtin, resolve(&.{}));
    var buf: [max_width]u8 = undefined;
    try t.expectEqualStrings("\t", (Unit{ .tabs = true, .width = 8 }).bytes(&buf));
    try t.expectEqualStrings("  ", (Unit{ .tabs = false, .width = 2 }).bytes(&buf));
}

test "detect: a four-space zig file" {
    try t.expectEqual(Partial{ .tabs = false, .width = 4 }, detect(
        \\const std = @import("std");
        \\
        \\pub fn main() void {
        \\    const x = 1;
        \\    if (x > 0) {
        \\        std.debug.print("{d}\n", .{x});
        \\    }
        \\}
        \\
    ));
}

test "detect: a gofmt file is tabs, alignment spaces after the tab aside" {
    try t.expectEqual(Partial{ .tabs = true }, detect(
        "package main\n\nfunc main() {\n\tx := []int{\n\t\t1,\n\t}\n\t_ = x // aligned\n\t  // continuation\n}\n",
    ));
}

test "detect: a two-space js file, dedents of two levels included" {
    try t.expectEqual(Partial{ .tabs = false, .width = 2 }, detect(
        \\function f(a) {
        \\  if (a) {
        \\    return {
        \\      ok: true,
        \\    };
        \\  }
        \\  return null;
        \\}
        \\const g = () => {
        \\  for (const x of y) {
        \\    z(x);
        \\  }
        \\};
        \\
    ));
}

test "detect: a nix file indented by two" {
    try t.expectEqual(Partial{ .tabs = false, .width = 2 }, detect(
        \\{ pkgs ? import <nixpkgs> { } }:
        \\pkgs.mkShell {
        \\  packages = [
        \\    pkgs.zig
        \\    pkgs.zls
        \\  ];
        \\  shellHook = ''
        \\    echo hi
        \\  '';
        \\}
        \\
    ));
}

test "detect: block-comment continuations and one-column alignment are not indentation" {
    try t.expectEqual(Partial{ .tabs = true }, detect(
        "/**\n * A doc comment, its stars aligned by one space.\n * More.\n */\nint f(void) {\n\treturn 1;\n}\n",
    ));
    // Only one-column steps: spaces, but no step worth naming.
    try t.expectEqual(Partial{ .tabs = false, .width = null }, detect("a\n b\n  c\n   d\n"));
}

test "detect: no indented line says nothing; a tie says nothing" {
    try t.expect(detect("").isEmpty());
    try t.expect(detect("one\ntwo\n\nthree\n").isEmpty());
    try t.expect(detect("a {\n\tb\n}\nc {\n    d\n}\n").isEmpty());
}

test "matchOpener: nesting across kinds, strings skipped, kinds checked" {
    const text = "fn f() {\n    const s = \"}\";\n    g(.{ 1, [2] }";
    try t.expectEqual(@as(?usize, 33), matchOpener(text, ')'));
    try t.expectEqual(@as(?usize, 7), matchOpener("fn f() {\n    x();\n    ", '}'));
    // What is open is a `(`, so a `]` closes nothing.
    try t.expect(matchOpener("f(a, ", ']') == null);
    try t.expect(matchOpener("nothing open", '}') == null);
}

test "tab stops: Tab steps to the next, Backspace back to the previous, over spaces only" {
    try t.expectEqual(@as(usize, 6), column("\t  ", 4));
    try t.expectEqual(@as(usize, 4), spacesToStop(0, 4));
    try t.expectEqual(@as(usize, 1), spacesToStop(3, 4));
    try t.expectEqual(@as(?usize, 4), spacesToPrevStop("        ", 4));
    try t.expectEqual(@as(?usize, 2), spacesToPrevStop("      ", 4));
    try t.expect(spacesToPrevStop("  x ", 4) == null);
    try t.expect(spacesToPrevStop("\t", 4) == null);
    try t.expect(spacesToPrevStop("", 4) == null);
}

test "langOf: the extension, else the name" {
    try t.expectEqualStrings("go", langOf("/src/x/main.go"));
    try t.expectEqualStrings("zig", langOf("build.zig"));
    try t.expectEqualStrings("Makefile", langOf("/p/Makefile"));
    try t.expectEqualStrings(".envrc", langOf("/p/.envrc"));
}

test "truthy: off and its spellings say no" {
    try t.expect(!truthy("off"));
    try t.expect(!truthy("FALSE"));
    try t.expect(!truthy("0"));
    try t.expect(truthy("on"));
    try t.expect(truthy("yes"));
}
