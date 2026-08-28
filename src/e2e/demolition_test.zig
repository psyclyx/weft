//! §19's demolition checklist (doc/contextual-workspace-architecture.md) made
//! EXECUTABLE: absence assertions over the real source tree, not aspiration in
//! a doc comment. Walks `src/` by absolute path — `demolition_options.repo_root`
//! is threaded in from build.zig, since the test binary's cwd is not
//! guaranteed to be the repo root — and grep-equivalent scans every file for
//! the patterns doc §19 wants gone. Each failure names its own file/line, so a
//! regression is self-diagnosing, not a mystery the next reader has to grep
//! for by hand. Kept to plain substring/line scans (fast, no AST) — matching
//! the treefmt-hook precedent of a lint gate that is cheap enough to run on
//! every `zig build test`.
//!
//! Gated here, one bullet each: `semanticActive` branches; domain keymaps or
//! locked tool modes (the `lockedMode` machinery); async routing by buffer
//! name; unhandled keys becoming text (`Feed.text`); compulsory editor
//! storage; cross-plugin private command dependencies; persisted
//! `dired`/`magit` terminology.
//!
//! STANDING, with what each awaits: provider-authored literal keys and domain
//! keymaps (git still binds its own `git` mode — awaits git's move to
//! intentions and postures); core-owned Vim dot-repeat (`Head.DotRepeat` —
//! awaits a grammar-owned recorder, since core dispatch is what sees the
//! rest points it records); semantic-action-to-string-command trampolines
//! (ten action names have no standard intention yet); read-only-as-type
//! compensation (`Buffers.Buffer.read_only` survives as an operation
//! distinction, not a type — awaits the posture work that would carry it);
//! view-owner-exclusive dispatch, row-index identity, silent fixed caps,
//! authority divergence, unselected presence/diagnostics, opaque tunnels, and
//! provider-supplied grant labels — all BEHAVIOURAL, gated by their own e2e
//! tests rather than by a source scan, and named here so the split is
//! deliberate rather than forgotten.

const std = @import("std");
const t = std.testing;
const demolition_options = @import("demolition_options");
const h = @import("harness.zig");
const Keymap = h.core.Keymap;
const Buffers = h.core.Buffers;

/// Whole-line, case-insensitive substrings that must never appear in `src/`
/// (doc §19: "persisted `dired` or `magit` terminology" — the plugin rename
/// and the illustrative-comment rename both landed, so this is now a durable
/// gate, not a one-time sweep).
const banned_terms = [_][]const u8{ "dired", "magit" };

const Violation = struct {
    path: []const u8,
    line: usize,
    reason: []const u8,
};

const Scan = struct {
    gpa: std.mem.Allocator,
    violations: std.ArrayList(Violation) = .empty,
    /// Every `fn semanticActive` DEFINITION site found (not call sites —
    /// `weft.semanticActive()` callers are fine; a second, unauthorized
    /// definition duplicating the guest ABI shim's is not).
    semantic_active_defs: std.ArrayList(Violation) = .empty,

    fn record(self: *Scan, path: []const u8, line: usize, reason: []const u8) !void {
        try self.violations.append(self.gpa, .{
            .path = try self.gpa.dupe(u8, path),
            .line = line,
            .reason = reason,
        });
    }
};

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0 or haystack.len < needle.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

/// Best-effort function name a `fn` declaration line introduces — enough for
/// the `findByName` async-delivery check below (this codebase's functions are
/// not nested, so a linear "last fn seen" tracker is grep-equivalent, not an
/// approximation of one).
fn fnNameOf(line: []const u8) ?[]const u8 {
    const idx = std.mem.indexOf(u8, line, "fn ") orelse return null;
    // Reject matches that are part of a longer identifier ("anyfn ").
    if (idx > 0) {
        const prev = line[idx - 1];
        if (std.ascii.isAlphanumeric(prev) or prev == '_') return null;
    }
    var start = idx + 3;
    while (start < line.len and line[start] == ' ') start += 1;
    var end = start;
    while (end < line.len and line[end] != '(' and line[end] != ' ') end += 1;
    if (end == start) return null;
    return line[start..end];
}

/// The plugin id a source file may speak for: `src/guest/git.zig` is `git`,
/// anything under `src/plugins/files/` is `files`. Null for host code, which
/// is not a plugin and may name any of them.
fn pluginIdOf(rel_path: []const u8) ?[]const u8 {
    if (std.mem.startsWith(u8, rel_path, "src/plugins/")) {
        const rest = rel_path["src/plugins/".len..];
        const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return null;
        return rest[0..slash];
    }
    if (std.mem.startsWith(u8, rel_path, "src/guest/")) {
        const rest = rel_path["src/guest/".len..];
        return rest[0 .. std.mem.lastIndexOfScalar(u8, rest, '.') orelse return null];
    }
    return null;
}

/// The `plugin.<id>.` name a line depends on, if any — the §5.1 grammar's
/// own marker for another provider's private surface.
fn pluginNameIn(line: []const u8) ?[]const u8 {
    const marker = "\"plugin.";
    const at = std.mem.indexOf(u8, line, marker) orelse return null;
    const rest = line[at + marker.len ..];
    const dot = std.mem.indexOfScalar(u8, rest, '.') orelse return null;
    return rest[0..dot];
}

fn scanFile(scan: *Scan, rel_path: []const u8, contents: []const u8) !void {
    var current_fn: []const u8 = "";
    var line_no: usize = 0;
    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |line| {
        line_no += 1;

        if (fnNameOf(line)) |name| current_fn = name;

        for (banned_terms) |term| {
            if (containsIgnoreCase(line, term))
                try scan.record(rel_path, line_no, "persisted dired/magit terminology (doc §19)");
        }

        if (std.mem.indexOf(u8, line, "fn semanticActive") != null) {
            try scan.semantic_active_defs.append(scan.gpa, .{
                .path = try scan.gpa.dupe(u8, rel_path),
                .line = line_no,
                .reason = "semanticActive definition",
            });
        }

        if (containsIgnoreCase(line, "lockedmode"))
            try scan.record(rel_path, line_no, "lockedMode call site (the Keymap machinery is deleted — doc §19 'locked tool modes')");

        if (std.mem.indexOf(u8, line, "findByName(") != null and containsIgnoreCase(current_fn, "deliver"))
            try scan.record(rel_path, line_no, "findByName on an async delivery path (resolve the captured ref instead)");

        // Doc §19 "cross-plugin private command dependencies": a plugin may
        // name its OWN `plugin.<id>.*` surface and no one else's.
        if (pluginNameIn(line)) |named| {
            if (pluginIdOf(rel_path)) |owner| {
                if (!std.mem.eql(u8, named, owner))
                    try scan.record(rel_path, line_no, "depends on another plugin's private command name (doc §19)");
            }
        }
    }
}

test "demolition: §19 checklist absences hold over src/" {
    const gpa = t.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const src_path = try std.fs.path.join(gpa, &.{ demolition_options.repo_root, "src" });
    defer gpa.free(src_path);
    var src_dir = try std.Io.Dir.openDirAbsolute(io, src_path, .{ .iterate = true });
    defer src_dir.close(io);

    var scan: Scan = .{ .gpa = gpa };
    defer {
        for (scan.violations.items) |v| gpa.free(v.path);
        scan.violations.deinit(gpa);
        for (scan.semantic_active_defs.items) |v| gpa.free(v.path);
        scan.semantic_active_defs.deinit(gpa);
    }

    var walker = try src_dir.walk(gpa);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        // This file itself names every banned pattern as a string literal —
        // it is the checker, not checked content.
        if (std.mem.eql(u8, entry.path, "e2e/demolition_test.zig")) continue;
        const contents = entry.dir.readFileAlloc(io, entry.basename, gpa, .limited(4 << 20)) catch |err| switch (err) {
            error.IsDir => continue,
            else => return err,
        };
        defer gpa.free(contents);
        const rel_path = try std.fmt.allocPrint(gpa, "src/{s}", .{entry.path});
        defer gpa.free(rel_path);
        try scanFile(&scan, rel_path, contents);
    }

    // `semanticActive` (doc §19: "`semanticActive` branches") has exactly one
    // definition site left: the guest ABI shim (src/guest/weft.zig). Anything
    // else means a second implementation snuck back in, bypassing the shim.
    if (scan.semantic_active_defs.items.len != 1 or
        !std.mem.eql(u8, scan.semantic_active_defs.items[0].path, "src/guest/weft.zig"))
    {
        for (scan.semantic_active_defs.items) |v|
            std.debug.print("demolition: unexpected semanticActive definition at {s}:{d}\n", .{ v.path, v.line });
        try t.expect(false);
    }

    for (scan.violations.items) |v|
        std.debug.print("demolition: {s}:{d}: {s}\n", .{ v.path, v.line, v.reason });
    try t.expectEqual(@as(usize, 0), scan.violations.items.len);

    // The `.text` self-insert branch `Keymap.Feed` used to carry is already
    // dead — assert it STAYS dead at the type level (doc §19), not merely
    // absent from a switch someone could silently reintroduce.
    inline for (@typeInfo(Keymap.Feed).@"union".fields) |field| {
        try t.expect(!std.mem.eql(u8, field.name, "text"));
    }

    // Doc §19 "compulsory editor storage in workspace entries": an entry's
    // editor is OPTIONAL at the type level, so an entry that holds no text
    // cannot be made to carry a dummy one to satisfy the field.
    inline for (@typeInfo(Buffers.Buffer).@"struct".fields) |field| {
        if (std.mem.eql(u8, field.name, "editor"))
            try t.expect(@typeInfo(field.type) == .optional);
    }
}
