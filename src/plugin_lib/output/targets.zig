//! Typed locations for command-output buffers (architecture §14.6). A row's
//! `(path, line, col)` is captured from the raw output when the fill lands;
//! visiting a row reads the table, so the rendered text is display-only and
//! may be styled, folded, or reformatted without breaking navigation. Pure —
//! no wasm import environment — so the parse and the row mapping are testable
//! on their own (the `buffer_order.zig` posture).

const std = @import("std");

/// A location a row points at, plus the byte span of the location text inside
/// that row (what a renderer paints as a location).
pub const Target = struct {
    path: []const u8,
    line: usize,
    col: usize,
    span_start: usize,
    span_end: usize,
};

/// The first `<path>:<line>[:<col>]` in an output line, or null when the line
/// names no location. One shape serves every producer: rg's `path:line:text`
/// prefix and a compiler/runtime location anywhere in the line (zig
/// `src/foo.zig:10:5: error`, node `at f (/abs/app.js:4:13)`). A path must
/// look like a file (carry a `.` or `/`) so `12:34` — a time, a ratio — is not
/// a location, and it ends at a space/quote/paren/colon boundary.
pub fn parse(text: []const u8) ?Target {
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (text[i] != ':') continue;
        const line_digits = digitsAt(text, i + 1);
        if (line_digits == i + 1) continue; // no digits after the colon
        var start = i;
        while (start > 0 and !isBoundary(text[start - 1])) start -= 1;
        const path = text[start..i];
        if (path.len == 0) continue;
        if (std.mem.indexOfScalar(u8, path, '.') == null and
            std.mem.indexOfScalar(u8, path, '/') == null) continue;
        var end = line_digits;
        var col: usize = 0;
        if (end < text.len and text[end] == ':') {
            const col_digits = digitsAt(text, end + 1);
            if (col_digits > end + 1) {
                col = decimal(text[end + 1 .. col_digits]);
                end = col_digits;
            }
        }
        return .{
            .path = path,
            .line = decimal(text[i + 1 .. line_digits]),
            .col = col,
            .span_start = start,
            .span_end = end,
        };
    }
    return null;
}

/// The end of the digit run starting at `from`.
fn digitsAt(text: []const u8, from: usize) usize {
    var j = from;
    while (j < text.len and text[j] >= '0' and text[j] <= '9') j += 1;
    return j;
}

fn isBoundary(ch: u8) bool {
    return ch == ' ' or ch == '\t' or ch == '(' or ch == ')' or
        ch == '"' or ch == '\'' or ch == ':';
}

fn decimal(digits: []const u8) usize {
    var n: usize = 0;
    for (digits) |d| n = n * 10 + (d - '0');
    return n;
}

/// One output buffer's rows, in fill order. Paths are owned copies, so the
/// table outlives the text it was read from.
pub const Table = struct {
    rows: std.ArrayList(?Target) = .empty,

    pub fn deinit(self: *Table, gpa: std.mem.Allocator) void {
        self.clear(gpa);
        self.rows.deinit(gpa);
    }

    pub fn clear(self: *Table, gpa: std.mem.Allocator) void {
        for (self.rows.items) |row| if (row) |target| gpa.free(target.path);
        self.rows.clearRetainingCapacity();
    }

    /// Append the location `text` carries (or none) as the next row.
    pub fn push(self: *Table, gpa: std.mem.Allocator, text: []const u8) !void {
        const found = parse(text) orelse return self.rows.append(gpa, null);
        var owned = found;
        owned.path = try gpa.dupe(u8, found.path);
        errdefer gpa.free(owned.path);
        try self.rows.append(gpa, owned);
    }

    pub fn get(self: *const Table, row: usize) ?Target {
        if (row >= self.rows.items.len) return null;
        return self.rows.items[row];
    }

    pub fn len(self: *const Table) usize {
        return self.rows.items.len;
    }
};

test "output targets: rg's prefix and a mid-line location parse the same" {
    const prefix = parse("app.js:2:const target = 42;").?;
    try std.testing.expectEqualStrings("app.js", prefix.path);
    try std.testing.expectEqual(@as(usize, 2), prefix.line);
    try std.testing.expectEqual(@as(usize, 0), prefix.span_start);

    const mid = parse("trace: app.js:2:5 boom").?;
    try std.testing.expectEqualStrings("app.js", mid.path);
    try std.testing.expectEqual(@as(usize, 2), mid.line);
    try std.testing.expectEqual(@as(usize, 5), mid.col);
    try std.testing.expectEqualStrings("app.js:2:5", "trace: app.js:2:5 boom"[mid.span_start..mid.span_end]);

    const paren = parse("    at f (/abs/app.js:4:13)").?;
    try std.testing.expectEqualStrings("/abs/app.js", paren.path);
    try std.testing.expectEqual(@as(usize, 4), paren.line);
    try std.testing.expectEqual(@as(usize, 13), paren.col);
}

test "output targets: a line naming no file carries no location" {
    try std.testing.expect(parse("") == null);
    try std.testing.expect(parse("elapsed 12:34") == null); // a time, not a path
    try std.testing.expect(parse("all tests passed") == null);
    try std.testing.expect(parse("app.js:") == null); // no line number
}

test "output targets: rows keep their location after the text is gone" {
    const gpa = std.testing.allocator;
    var table: Table = .{};
    defer table.deinit(gpa);

    var scratch: [64]u8 = undefined;
    const rendered = try std.fmt.bufPrint(&scratch, "note\nsrc/a.zig:7:3: error\n", .{});
    var it = std.mem.splitScalar(u8, std.mem.trimEnd(u8, rendered, "\n"), '\n');
    while (it.next()) |line| try table.push(gpa, line);
    @memset(&scratch, 0); // the rendered text is gone; the table is not

    try std.testing.expectEqual(@as(usize, 2), table.len());
    try std.testing.expect(table.get(0) == null);
    const target = table.get(1).?;
    try std.testing.expectEqualStrings("src/a.zig", target.path);
    try std.testing.expectEqual(@as(usize, 7), target.line);
    try std.testing.expectEqual(@as(usize, 3), target.col);
    try std.testing.expect(table.get(2) == null); // past the end
}

test "output targets: a refill replaces the previous rows" {
    const gpa = std.testing.allocator;
    var table: Table = .{};
    defer table.deinit(gpa);

    try table.push(gpa, "old.zig:1:1: stale");
    table.clear(gpa);
    try table.push(gpa, "new.zig:9:2: fresh");
    try std.testing.expectEqual(@as(usize, 1), table.len());
    try std.testing.expectEqualStrings("new.zig", table.get(0).?.path);
}
