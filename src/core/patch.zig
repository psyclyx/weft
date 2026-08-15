//! Edit-stream composition. `TextDoc.merge` (and local editing) yields a
//! *sequential* `[]Edit` stream: each edit's offsets are valid against the
//! text produced by the previous one, and a later edit may overlap an
//! earlier edit's insertion. Subscribers want the opposite shape — a set
//! of non-overlapping patches in *original* coordinates whose inserted
//! content is a contiguous range of the *final* text, so a commit can be
//! described (and its bytes sliced from the post-commit rope) without
//! replaying intermediate states.
//!
//! `Composer` folds a sequential stream into that canonical form. The
//! invariants it maintains (checked by the oracle test):
//! - patches are ascending and non-overlapping in old-space;
//! - each patch's inserted bytes are one contiguous new-space range, so
//!   `newOffsetOf` + `inserted` slices its content from the final text.

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const stemma = @import("stemma");
const Edit = stemma.Edit;

/// One composed replacement: `removed` bytes at old-space `offset` became
/// `inserted` bytes (content lives in the final text; see `newOffsetOf`).
pub const Patch = struct {
    offset: usize,
    removed: usize,
    inserted: usize,
};

/// New-space (final-text) offset of `patches[index]`'s inserted range.
/// `patches` must be the composed ascending set.
pub fn newOffsetOf(patches: []const Patch, index: usize) usize {
    var delta: isize = 0;
    for (patches[0..index]) |p| {
        delta += @as(isize, @intCast(p.inserted)) - @as(isize, @intCast(p.removed));
    }
    const off: isize = @as(isize, @intCast(patches[index].offset)) + delta;
    return @intCast(off);
}

pub const Composer = struct {
    patches: std.ArrayList(Patch) = .empty,

    pub const empty: Composer = .{};

    pub fn deinit(self: *Composer, gpa: Allocator) void {
        self.patches.deinit(gpa);
    }

    /// Fold one more sequential edit (offsets in the space produced by
    /// all previously pushed edits) into the composed set.
    pub fn push(self: *Composer, gpa: Allocator, edit: Edit) Allocator.Error!void {
        if (edit.removed == 0 and edit.inserted == 0) return;
        const off = edit.offset;
        const end = edit.offset + edit.removed;

        // Locate the contiguous run of existing patches whose new-space
        // ranges touch [off, end], tracking old-space deltas as we go.
        var delta: isize = 0; // new - old, before the current patch
        var first: usize = 0; // first touched index
        var delta_first: isize = 0; // delta before `first`
        var i: usize = 0;
        var touched: usize = 0;
        while (i < self.patches.items.len) : (i += 1) {
            const p = self.patches.items[i];
            const new_start: usize = @intCast(@as(isize, @intCast(p.offset)) + delta);
            const new_end = new_start + p.inserted;
            if (new_end < off) {
                delta += @as(isize, @intCast(p.inserted)) - @as(isize, @intCast(p.removed));
                continue;
            }
            if (new_start > end) break;
            if (touched == 0) {
                first = i;
                delta_first = delta;
            }
            touched += 1;
            delta += @as(isize, @intCast(p.inserted)) - @as(isize, @intCast(p.removed));
        }

        if (touched == 0) {
            // Entirely inside one unmodified gap: map 1:1 into old space.
            // `delta_at_gap` is the delta accumulated before insertion
            // point `first` (which is where the scan stopped or skipped
            // past); recompute for the insertion index.
            var d: isize = 0;
            var at: usize = 0;
            for (self.patches.items) |p| {
                const new_start: usize = @intCast(@as(isize, @intCast(p.offset)) + d);
                if (new_start > end) break;
                d += @as(isize, @intCast(p.inserted)) - @as(isize, @intCast(p.removed));
                at += 1;
            }
            const old_off: usize = @intCast(@as(isize, @intCast(off)) - d);
            try self.patches.insert(gpa, at, .{
                .offset = old_off,
                .removed = edit.removed,
                .inserted = edit.inserted,
            });
            return;
        }

        const first_p = self.patches.items[first];
        const last_p = self.patches.items[first + touched - 1];
        const first_new_start: usize =
            @intCast(@as(isize, @intCast(first_p.offset)) + delta_first);
        var delta_last = delta_first;
        var removed_sum: usize = 0;
        for (self.patches.items[first .. first + touched], 0..) |p, k| {
            removed_sum += p.removed;
            // Interior gaps between touched patches are fully consumed.
            if (k + 1 < touched) {
                const next = self.patches.items[first + k + 1];
                removed_sum += next.offset - (p.offset + p.removed);
            }
            if (k + 1 < touched) {
                delta_last += @as(isize, @intCast(p.inserted)) - @as(isize, @intCast(p.removed));
            }
        }
        const last_new_start: usize =
            @intCast(@as(isize, @intCast(last_p.offset)) + delta_last);
        const last_new_end = last_new_start + last_p.inserted;

        const head_old = if (off < first_new_start) first_new_start - off else 0;
        const tail_old = if (end > last_new_end) end - last_new_end else 0;
        const keep_left = if (off > first_new_start)
            @min(off - first_new_start, first_p.inserted)
        else
            0;
        const keep_right = if (last_new_end > end)
            @min(last_new_end - end, last_p.inserted)
        else
            0;

        const merged: Patch = .{
            .offset = first_p.offset - head_old,
            .removed = head_old + removed_sum + tail_old,
            .inserted = keep_left + edit.inserted + keep_right,
        };
        self.patches.items[first] = merged;
        self.patches.replaceRangeAssumeCapacity(first + 1, touched - 1, &.{});
        if (merged.removed == 0 and merged.inserted == 0) {
            _ = self.patches.orderedRemove(first);
        }
    }

    /// The composed set, ascending and non-overlapping in old-space.
    pub fn items(self: *const Composer) []const Patch {
        return self.patches.items;
    }
};

// ── Tests ───────────────────────────────────────────────────────────

const t = std.testing;

/// Oracle: apply a random sequential edit stream to a byte string, feed
/// the offset-only edits to the Composer, then reconstruct the final
/// string from the ORIGINAL string + patches (content sliced from the
/// final string at each patch's new-space range). Any composition bug
/// breaks the round trip.
fn oracleRound(gpa: Allocator, prng: *std.Random.DefaultPrng, initial_len: usize, ops: usize) !void {
    const rand = prng.random();

    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(gpa);
    for (0..initial_len) |_| try text.append(gpa, 'a' + rand.uintLessThan(u8, 26));
    const original = try gpa.dupe(u8, text.items);
    defer gpa.free(original);

    var comp: Composer = .empty;
    defer comp.deinit(gpa);

    for (0..ops) |_| {
        const len = text.items.len;
        const off = rand.uintAtMost(usize, len);
        const removed = rand.uintAtMost(usize, @min(len - off, 8));
        const inserted = rand.uintAtMost(usize, 8);
        var buf: [8]u8 = undefined;
        for (buf[0..inserted]) |*b| b.* = 'A' + rand.uintLessThan(u8, 26);
        try text.replaceRange(gpa, off, removed, buf[0..inserted]);
        try comp.push(gpa, .{ .offset = off, .removed = removed, .inserted = inserted });
    }

    // Invariants: ascending, non-overlapping.
    const ps = comp.items();
    for (ps, 0..) |p, i| {
        if (i > 0) try t.expect(p.offset >= ps[i - 1].offset + ps[i - 1].removed);
        try t.expect(p.offset + p.removed <= original.len);
    }

    // Reconstruct: replace in reverse order so earlier offsets hold.
    var rebuilt: std.ArrayList(u8) = .empty;
    defer rebuilt.deinit(gpa);
    try rebuilt.appendSlice(gpa, original);
    var i = ps.len;
    while (i > 0) {
        i -= 1;
        const new_off = newOffsetOf(ps, i);
        const content = text.items[new_off .. new_off + ps[i].inserted];
        try rebuilt.replaceRange(gpa, ps[i].offset, ps[i].removed, content);
    }
    try t.expectEqualStrings(text.items, rebuilt.items);
}

test "composer: oracle round trips over random edit streams" {
    const gpa = t.allocator;
    var prng = std.Random.DefaultPrng.init(0x5c10_2e01);
    for (0..200) |round| {
        try oracleRound(gpa, &prng, round % 40, 1 + round % 25);
    }
}

test "composer: overlap of a later delete with an earlier insert" {
    const gpa = t.allocator;
    var comp: Composer = .empty;
    defer comp.deinit(gpa);
    // "hello" → insert "XYZ" at 2 → "heXYZllo" → delete [1,6) → "hlo".
    try comp.push(gpa, .{ .offset = 2, .removed = 0, .inserted = 3 });
    try comp.push(gpa, .{ .offset = 1, .removed = 5, .inserted = 0 });
    // Old space: "hello" lost [1,3) ("el" — the delete consumed the
    // whole insertion plus those two originals), gained nothing.
    try t.expectEqual(@as(usize, 1), comp.items().len);
    try t.expectEqual(Patch{ .offset = 1, .removed = 2, .inserted = 0 }, comp.items()[0]);
}

test "composer: insert-then-fully-delete cancels out" {
    const gpa = t.allocator;
    var comp: Composer = .empty;
    defer comp.deinit(gpa);
    try comp.push(gpa, .{ .offset = 4, .removed = 0, .inserted = 5 });
    try comp.push(gpa, .{ .offset = 4, .removed = 5, .inserted = 0 });
    try t.expectEqual(@as(usize, 0), comp.items().len);
}
