//! The system clipboard as a head sees it (doc/configs.md §3.3).
//!
//! A clipboard belongs to a PLATFORM ATTACHMENT, not to a system: two heads on
//! two machines editing one system each copy into their own desktop, which is
//! why this lives on `Head` (contextual-workspace-architecture.md §13.1 classes
//! the clipboard as private, never exported). Core owns the door and nothing else:
//! which register mirrors the clipboard is the grammar's choice — ide mirrors
//! the unnamed register, vim keeps `"+`.
//!
//! Mechanism: a head always has a clipboard. With no backend installed (every
//! headless head, every test) it is an in-memory store, so a round trip works
//! and a grammar needs no "is there a clipboard" branch. The desktop shell
//! installs a `Backend` over its platform window; reads then answer the text
//! the platform last RECEIVED — offers are read asynchronously off the frame
//! loop (`platform/wayland.zig`), so a read never blocks on another client,
//! and a paste right after a foreign copy sees the new text once the pipe has
//! drained (normally the same wake).

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Clipboard = @This();

/// A platform's clipboard, erased. `text` answers the last-known selection
/// (owned by the platform, valid until the next `set` or the next event
/// pump); `set` takes the selection, copying `bytes`.
pub const Backend = struct {
    context: *anyopaque,
    text: *const fn (context: *anyopaque) []const u8,
    set: *const fn (context: *anyopaque, bytes: []const u8) void,
};

/// The in-memory store — the whole clipboard when no backend is installed.
memory: std.ArrayList(u8) = .empty,
backend: ?Backend = null,

pub const empty: Clipboard = .{};

pub fn deinit(self: *Clipboard, gpa: Allocator) void {
    self.memory.deinit(gpa);
    self.* = .{};
}

/// The clipboard's current text ("" when empty). Borrowed: valid until the
/// next `set` or platform event pump.
pub fn text(self: *const Clipboard) []const u8 {
    if (self.backend) |b| return b.text(b.context);
    return self.memory.items;
}

/// Take the clipboard with `bytes`.
pub fn set(self: *Clipboard, gpa: Allocator, bytes: []const u8) Allocator.Error!void {
    if (self.backend) |b| return b.set(b.context, bytes);
    self.memory.clearRetainingCapacity();
    try self.memory.appendSlice(gpa, bytes);
}

const t = std.testing;

test "clipboard: a head with no platform round-trips in memory" {
    var clip: Clipboard = .empty;
    defer clip.deinit(t.allocator);
    try t.expectEqualStrings("", clip.text());
    try clip.set(t.allocator, "hello");
    try t.expectEqualStrings("hello", clip.text());
    try clip.set(t.allocator, "");
    try t.expectEqualStrings("", clip.text());
}

test "clipboard: an installed backend answers instead of memory" {
    const Fake = struct {
        buf: [16]u8 = undefined,
        len: usize = 0,
        fn get(c: *anyopaque) []const u8 {
            const f: *@This() = @ptrCast(@alignCast(c));
            return f.buf[0..f.len];
        }
        fn put(c: *anyopaque, bytes: []const u8) void {
            const f: *@This() = @ptrCast(@alignCast(c));
            f.len = @min(bytes.len, f.buf.len);
            @memcpy(f.buf[0..f.len], bytes[0..f.len]);
        }
    };
    var fake: Fake = .{};
    var clip: Clipboard = .{ .backend = .{ .context = &fake, .text = Fake.get, .set = Fake.put } };
    defer clip.deinit(t.allocator);
    try clip.set(t.allocator, "platform");
    try t.expectEqualStrings("platform", fake.buf[0..fake.len]);
    try t.expectEqualStrings("platform", clip.text());
    try t.expectEqual(@as(usize, 0), clip.memory.items.len);
}
