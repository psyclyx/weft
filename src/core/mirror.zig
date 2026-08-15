//! Mirror — a commit-log subscriber holding a shadow rope of the text
//! *as of its cursor*. Consumers that need old-coordinate context for
//! each change (tree-sitter's `ts_tree_edit`, LSP's `didChange` ranges)
//! drain commits through it: for every patch the callback sees the
//! pre-patch shadow (old coordinates are valid against it) plus the
//! patch and its inserted bytes; the mirror then applies the patch so
//! the next callback's old-space is right. Patches within one commit
//! are applied descending, so each one's old offsets hold.

const std = @import("std");
const Allocator = std.mem.Allocator;

const stemma = @import("stemma");
const Document = @import("Document.zig");

const Mirror = @This();

rope: stemma.Rope = .empty,
cursor: usize = 0,

pub const empty: Mirror = .{};

pub fn deinit(self: *Mirror, gpa: Allocator) void {
    self.rope.deinit(gpa);
    self.* = .{};
}

/// `cb(ctx, shadow_before, patch, inserted_bytes)` for every patch of
/// every undrained commit, in causal order. Returns how many commits
/// were drained.
pub fn drain(
    self: *Mirror,
    gpa: Allocator,
    doc: *const Document,
    ctx: anytype,
    comptime cb: fn (@TypeOf(ctx), *const stemma.Rope, Document.Patch, []const u8) anyerror!void,
) !usize {
    const commits = doc.commitsSince(self.cursor);
    for (commits) |*commit| {
        var i = commit.patches.len;
        while (i > 0) {
            i -= 1;
            const p = commit.patches[i];
            const inserted = commit.insertedBytes(i);
            try cb(ctx, &self.rope, p, inserted);
            if (p.removed > 0) {
                _ = try self.rope.delete(gpa, .{ .start = p.offset, .end = p.offset + p.removed });
            }
            if (inserted.len > 0) {
                _ = try self.rope.insert(gpa, p.offset, inserted);
            }
        }
    }
    self.cursor += commits.len;
    return commits.len;
}

// ── Tests ───────────────────────────────────────────────────────────

const t = std.testing;

test "mirror: shadow tracks the document through edits and peer merges" {
    const gpa = t.allocator;
    var doc = try Document.init(gpa, "user");
    defer doc.deinit(gpa);
    var m: Mirror = .empty;
    defer m.deinit(gpa);

    const Ctx = struct {
        fn cb(_: void, shadow: *const stemma.Rope, p: Document.Patch, ins: []const u8) anyerror!void {
            // Old offsets are always valid against the shadow.
            try t.expect(p.offset + p.removed <= shadow.byteLen());
            _ = ins;
        }
    };

    try doc.insert(gpa, 0, "one two three");
    const peer = try doc.addPeer(gpa, "p");
    var s = try doc.peerSnapshot(gpa, peer);
    s.deinit(gpa);
    try doc.delete(gpa, .{ .start = 0, .end = 4 });
    try doc.peerInsert(gpa, peer, 13, "!");
    _ = try doc.peerCommit(gpa, peer);
    _ = try m.drain(gpa, &doc, {}, Ctx.cb);

    const got = try m.rope.toOwnedSlice(gpa);
    defer gpa.free(got);
    const want = try doc.text().toOwnedSlice(gpa);
    defer gpa.free(want);
    try t.expectEqualStrings(want, got);
}
