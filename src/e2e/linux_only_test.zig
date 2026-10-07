//! The Linux wall, made executable: host code may name `std.os.linux` only
//! in a file that REFUSES to compile anywhere else. `std.os.linux` is raw
//! syscalls by Linux's numbers, and it cross-compiles silently — an
//! aarch64-macos build of a file that calls `linux.futex_4arg` succeeds and
//! fails only when it runs on a Mac. So "it builds for darwin" proves
//! nothing about a file that names it; the guard makes the build the proof:
//!
//!     comptime {
//!         if (@import("builtin").os.tag != .linux) @compileError("<file> is Linux-only");
//!     }
//!
//! placed before the first use. A portable file reaches the OS through
//! `std.c` (libc is linked wherever core is) or `std.posix`; a mechanism
//! that only Linux has lives in a guarded `*_linux.zig` beside a portable
//! counterpart (`core/futex.zig` → `core/futex_linux.zig`).
//!
//! Walks `src/` by absolute path (`demolition_options.repo_root`, as
//! `demolition_test.zig` does), skipping the wasm GUESTS (`plugins/`,
//! `plugin_fixtures/`, `plugin_lib/`), which never run on the host OS.
//! Comments do not count — only code that names the namespace. Any spelling
//! that reaches it counts (`std.os.linux`, `@import("std").os.linux`, an
//! `os.linux` through a local alias).
//!
//! `awaiting` names the files still to be made compliant by other lanes of
//! the macOS port, each with its owner. It is a RATCHET in both directions: a
//! new offender fails, and so does a listed file that has become compliant —
//! delete its line in the same change that fixed it.

const std = @import("std");
const t = std.testing;
const demolition_options = @import("demolition_options");

/// Offenders known and owned elsewhere, by repo-relative path.
const awaiting = [_]struct { path: []const u8, owner: []const u8 }{
    .{ .path = "src/core/Document.zig", .owner = "macOS port, filesystem lane" },
    .{ .path = "src/core/file.zig", .owner = "macOS port, filesystem lane" },
    .{ .path = "src/core/identity.zig", .owner = "macOS port, filesystem lane" },
    .{ .path = "src/core/known_peers.zig", .owner = "macOS port, filesystem lane" },
    .{ .path = "src/core/kv_file.zig", .owner = "macOS port, filesystem lane" },
    .{ .path = "src/core/peer_fs.zig", .owner = "macOS port, filesystem lane" },
    .{ .path = "src/core/rooted_fs.zig", .owner = "macOS port, filesystem lane" },
    .{ .path = "src/core/session/remote_fs.zig", .owner = "macOS port, filesystem lane" },
    .{ .path = "src/core/wasm_host/fs.zig", .owner = "macOS port, filesystem lane" },
    .{ .path = "src/core/watch.zig", .owner = "macOS port, filesystem lane" },
    .{ .path = "src/fs_linux/provider.zig", .owner = "macOS port, filesystem lane" },
};

/// Directories under `src/` holding wasm guests, not host code.
const guest_dirs = [_][]const u8{ "plugins/", "plugin_fixtures/", "plugin_lib/" };

const Verdict = union(enum) {
    /// Names no Linux interface.
    portable,
    /// Names one, behind the guard.
    guarded,
    /// Names one with no guard before it, first at this line.
    unguarded: usize,
};

/// The code on `line`: nothing for a multiline-string line, and nothing
/// from a `//` outside a string literal onward.
fn codeOf(line: []const u8) []const u8 {
    const trimmed = std.mem.trimStart(u8, line, " \t");
    if (std.mem.startsWith(u8, trimmed, "\\\\")) return "";
    var in_string = false;
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        const ch = line[i];
        if (in_string) {
            if (ch == '\\') i += 1 else if (ch == '"') in_string = false;
        } else if (ch == '"') {
            in_string = true;
        } else if (ch == '\'' and i + 2 < line.len) {
            // A character literal: '"' and '\'' must not open a string.
            if (line[i + 1] == '\\') i += 3 else i += 2;
        } else if (ch == '/' and i + 1 < line.len and line[i + 1] == '/') {
            return line[0..i];
        }
    }
    return line;
}

fn classify(contents: []const u8) Verdict {
    var guarded = false;
    var line_no: usize = 0;
    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |line| {
        line_no += 1;
        const code = codeOf(line);
        if (std.mem.indexOf(u8, code, "os.tag != .linux") != null and
            std.mem.indexOf(u8, code, "@compileError(") != null) guarded = true;
        if (std.mem.indexOf(u8, code, "os.linux") != null)
            return if (guarded) .guarded else .{ .unguarded = line_no };
    }
    return .portable;
}

test "linux-only: the checker reads guards, uses, comments and strings" {
    try t.expectEqual(Verdict.portable, classify("const c = std.c;\n// std.os.linux is not used here\n"));
    try t.expectEqual(Verdict.portable, classify("const s = \"// \"; // os.linux\n"));
    try t.expectEqual(Verdict.portable, classify("    \\\\ std.os.linux in a multiline string\n"));
    try t.expectEqual(Verdict{ .unguarded = 2 }, classify("const std = @import(\"std\");\nconst linux = std.os.linux;\n"));
    try t.expectEqual(Verdict{ .unguarded = 1 }, classify("const x = @import(\"std\").os.linux.getpid();\n"));
    try t.expectEqual(Verdict{ .unguarded = 1 }, classify("const q = '\"'; const l = std.os.linux;\n"));
    try t.expectEqual(Verdict.guarded, classify(
        \\comptime {
        \\    if (@import("builtin").os.tag != .linux) @compileError("x.zig is Linux-only");
        \\}
        \\const linux = std.os.linux;
        \\
    ));
    // A guard AFTER the first use does not count: it belongs at the top,
    // where a reader meets it before any Linux call.
    try t.expectEqual(Verdict{ .unguarded = 1 }, classify(
        \\const linux = std.os.linux;
        \\comptime {
        \\    if (@import("builtin").os.tag != .linux) @compileError("x.zig is Linux-only");
        \\}
        \\
    ));
}

test "linux-only: no host file names std.os.linux without the Linux-only guard" {
    const gpa = t.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const src_path = try std.fs.path.join(gpa, &.{ demolition_options.repo_root, "src" });
    defer gpa.free(src_path);
    var src_dir = try std.Io.Dir.openDirAbsolute(io, src_path, .{ .iterate = true });
    defer src_dir.close(io);

    var offenders: std.ArrayList([]u8) = .empty;
    defer {
        for (offenders.items) |o| gpa.free(o);
        offenders.deinit(gpa);
    }
    var seen_awaiting: [awaiting.len]bool = @splat(false);

    var walker = try src_dir.walk(gpa);
    defer walker.deinit();
    walk: while (try walker.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".zig")) continue;
        for (guest_dirs) |dir| if (std.mem.startsWith(u8, entry.path, dir)) continue :walk;
        // The checker names the namespace in its own docs and fixtures.
        if (std.mem.eql(u8, entry.path, "e2e/linux_only_test.zig")) continue;
        const contents = try entry.dir.readFileAlloc(io, entry.basename, gpa, .limited(8 << 20));
        defer gpa.free(contents);
        const rel_path = try std.fmt.allocPrint(gpa, "src/{s}", .{entry.path});
        defer gpa.free(rel_path);

        const verdict = classify(contents);
        const listed = for (awaiting, 0..) |a, i| {
            if (std.mem.eql(u8, a.path, rel_path)) break i;
        } else null;
        if (listed) |i| {
            seen_awaiting[i] = true;
            if (verdict != .unguarded) try offenders.append(gpa, try std.fmt.allocPrint(
                gpa,
                "{s}: compliant now — delete its `awaiting` line",
                .{rel_path},
            ));
            continue;
        }
        switch (verdict) {
            .portable, .guarded => {},
            .unguarded => |line| try offenders.append(gpa, try std.fmt.allocPrint(
                gpa,
                "{s}:{d}: names std.os.linux without the Linux-only guard — use std.c/std.posix, or move it to a guarded *_linux.zig",
                .{ rel_path, line },
            )),
        }
    }
    for (awaiting, seen_awaiting) |a, seen| if (!seen) try offenders.append(gpa, try std.fmt.allocPrint(
        gpa,
        "{s}: listed in `awaiting` but gone — delete its line",
        .{a.path},
    ));

    for (offenders.items) |o| std.debug.print("linux-only: {s}\n", .{o});
    try t.expectEqual(@as(usize, 0), offenders.items.len);
}
