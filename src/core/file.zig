//! Filesystem host operations. Every function here may block — none is
//! ever called on the hot path: reads happen at startup/open, writes run
//! on task-pool workers as fallible requests. Each call brings its own
//! `std.Io.Threaded` instance (0.16's blocking Io implementation); at a
//! few saves per minute that costs nothing and keeps the editor free of
//! a global Io singleton.

const std = @import("std");
const Allocator = std.mem.Allocator;

const stemma = @import("stemma");

pub const ReadError = std.Io.Dir.ReadFileAllocError;
pub const WriteError = std.Io.Dir.WriteFileError || std.Io.Dir.RenameError || Allocator.Error;

/// Read a whole file. Caller owns the bytes.
pub fn readAlloc(gpa: Allocator, path: []const u8) (ReadError || Allocator.Error)![]u8 {
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    return std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited);
}

/// Atomic save: write to a sibling temp file, then rename over the
/// target. Takes ownership of `path` (gpa-owned) and of the rope
/// snapshot — the shape a task-pool spawn needs (the caller's editor
/// state can move on while this runs).
pub fn writeRopeAtomic(gpa: Allocator, path: []u8, rope: stemma.Rope) WriteError!void {
    defer gpa.free(path);
    var snapshot = rope;
    defer snapshot.deinit(gpa);

    const bytes = try snapshot.toOwnedSlice(gpa);
    defer gpa.free(bytes);
    const tmp = try std.fmt.allocPrint(gpa, "{s}.scion-tmp", .{path});
    defer gpa.free(tmp);

    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const cwd = std.Io.Dir.cwd();
    try cwd.writeFile(io, .{ .sub_path = tmp, .data = bytes });
    try std.Io.Dir.rename(cwd, tmp, cwd, path, io);
}

// ── Tests ───────────────────────────────────────────────────────────

const t = std.testing;

test "read/write round trip through the atomic path" {
    const gpa = t.allocator;
    var tmp_dir = t.tmpDir(.{});
    defer tmp_dir.cleanup();
    // Work with absolute-ish subpaths under the tmp dir via realpath
    // conventions: simplest is to write via our API into the tmp dir's
    // path composed manually.
    const dir_path = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/roundtrip.txt", .{tmp_dir.sub_path});
    defer gpa.free(dir_path);

    var rope = try stemma.Rope.fromSlice(gpa, "saved by a worker, honestly");
    defer rope.deinit(gpa);
    try writeRopeAtomic(gpa, try gpa.dupe(u8, dir_path), rope.snapshot());

    const back = try readAlloc(gpa, dir_path);
    defer gpa.free(back);
    try t.expectEqualStrings("saved by a worker, honestly", back);
}
