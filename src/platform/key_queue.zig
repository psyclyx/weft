//! The ordered key-event queue every platform window keeps: filled from its
//! input callbacks, drained by `nextKeyEvent` in press order. Bounded — an
//! overflow drops the OLDEST event, and says so in debug builds, so a stalled
//! frame cannot grow it without limit.

const std = @import("std");
const KeyEvent = @import("root.zig").KeyEvent;

pub const KeyQueue = struct {
    const len = 128;

    events: [len]KeyEvent = undefined,
    head: usize = 0,
    tail: usize = 0,
    dropped: usize = 0,

    pub fn push(self: *KeyQueue, ev: KeyEvent) void {
        if (self.tail - self.head >= len) {
            self.head += 1; // drop oldest
            self.dropped += 1;
            if (std.debug.runtime_safety) {
                std.log.warn("key event queue overflow ({d} dropped)", .{self.dropped});
            }
        }
        self.events[self.tail % len] = ev;
        self.tail += 1;
    }

    pub fn next(self: *KeyQueue) ?KeyEvent {
        if (self.head == self.tail) return null;
        const ev = self.events[self.head % len];
        self.head += 1;
        return ev;
    }
};

test "key queue: press order, and overflow drops the oldest" {
    var q: KeyQueue = .{};
    try std.testing.expectEqual(@as(?KeyEvent, null), q.next());
    for (0..KeyQueue.len + 2) |i| q.push(.{ .keysym = @intCast(i), .pressed = true });
    try std.testing.expectEqual(@as(usize, 2), q.dropped);
    try std.testing.expectEqual(@as(u32, 2), q.next().?.keysym);
}
