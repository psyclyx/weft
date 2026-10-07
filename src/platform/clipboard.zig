//! The platform half of the system clipboard (doc/configs.md §3.3): the text
//! the desktop last put on the clipboard.
//!
//! `Store` is the whole clipboard for a platform with no desktop (headless),
//! and the cache a desktop platform keeps of it: Wayland fills it through the
//! pipe transfers in `clipboard_pipes.zig`; Cocoa reads and writes
//! `NSPasteboard` directly and keeps what it last saw here, so a paste never
//! waits on another process.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// The clipboard's last-known text: what this client set, or what it last
/// received from another. The whole clipboard for a platform with no desktop.
pub const Store = struct {
    bytes: std.ArrayList(u8) = .empty,
    /// Bumped by every `set`. A receive remembers the value it started at
    /// and lands only if nothing set the store since: a copy made here while
    /// an older foreign offer was still being read is newer than that offer,
    /// whichever finishes first (`clipboard_pipes.zig`'s `Transfers.receive`).
    gen: u64 = 0,

    pub fn deinit(self: *Store, gpa: Allocator) void {
        self.bytes.deinit(gpa);
        self.* = .{};
    }

    pub fn text(self: *const Store) []const u8 {
        return self.bytes.items;
    }

    pub fn set(self: *Store, gpa: Allocator, bytes: []const u8) Allocator.Error!void {
        self.gen += 1;
        self.bytes.clearRetainingCapacity();
        try self.bytes.appendSlice(gpa, bytes);
    }
};

const t = std.testing;

test "clipboard: the store round-trips (the headless clipboard)" {
    var store: Store = .{};
    defer store.deinit(t.allocator);
    try t.expectEqualStrings("", store.text());
    try store.set(t.allocator, "copied");
    try t.expectEqualStrings("copied", store.text());
    try store.set(t.allocator, "again");
    try t.expectEqualStrings("again", store.text());
}
