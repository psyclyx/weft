//! Pure ordering for the guest buffer picker. Kept independent of `weft.zig`
//! so the active-last policy and choice-index mapping can be tested without a
//! wasm import environment.

const std = @import("std");

pub const Candidate = struct {
    buffer_index: usize,
    id: i32,
    active: bool,
};

/// Stable-partition candidates so the active buffer is last. The source order
/// remains the tie-breaker within each partition.
pub fn activeLastOrder(input: []const Candidate, output: []usize) usize {
    var n: usize = 0;
    for ([_]bool{ false, true }) |want_active| {
        for (input, 0..) |candidate, i| {
            if (candidate.active != want_active) continue;
            output[n] = i;
            n += 1;
        }
    }
    return n;
}

test "buffer order: empty and singleton inputs" {
    var output: [4]usize = undefined;
    try std.testing.expectEqual(@as(usize, 0), activeLastOrder(&.{}, &output));

    const inactive = [_]Candidate{.{ .buffer_index = 0, .id = 10, .active = false }};
    try std.testing.expectEqual(@as(usize, 1), activeLastOrder(&inactive, &output));
    try std.testing.expectEqual(@as(usize, 0), output[0]);

    const active = [_]Candidate{.{ .buffer_index = 0, .id = 10, .active = true }};
    try std.testing.expectEqual(@as(usize, 1), activeLastOrder(&active, &output));
    try std.testing.expectEqual(@as(usize, 0), output[0]);
}

test "buffer order: active-last is stable and preserves accepted-ID mapping" {
    const input = [_]Candidate{
        .{ .buffer_index = 0, .id = 41, .active = false },
        .{ .buffer_index = 1, .id = 7, .active = true },
        .{ .buffer_index = 2, .id = 99, .active = false },
        .{ .buffer_index = 3, .id = 12, .active = true },
    };
    var output: [4]usize = undefined;
    const n = activeLastOrder(&input, &output);
    try std.testing.expectEqual(@as(usize, 4), n);
    try std.testing.expectEqualSlices(usize, &.{ 0, 2, 1, 3 }, output[0..n]);

    var row_ids: [4]i32 = undefined;
    for (output[0..n], 0..) |candidate_index, row| row_ids[row] = input[candidate_index].id;
    try std.testing.expectEqual(@as(i32, 41), row_ids[0]);
    try std.testing.expectEqual(@as(i32, 99), row_ids[1]);
    try std.testing.expectEqual(@as(i32, 7), row_ids[2]);
    try std.testing.expectEqual(@as(i32, 12), row_ids[3]);
}
