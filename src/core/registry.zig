//! Late-binding names. A `Name` is an interned handle you may hold
//! forever; what it resolves to is decided at *call* time, not at bind
//! time. Referencing a name before anything is bound to it is fine (it
//! resolves to null until someone binds it), and rebinding is visible
//! through every previously interned handle — the property that lets
//! config reference commands that plugins provide later, and lets a
//! plugin shadow a built-in by rebinding its name.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub fn Registry(comptime T: type) type {
    return struct {
        const Self = @This();

        /// Interned name → current binding. Array-hash-map indices are
        /// stable and never removed, so a `Name` (an index) stays valid
        /// for the registry's lifetime; only the *binding* changes.
        map: std.StringArrayHashMapUnmanaged(?T) = .empty,

        pub const Name = enum(u32) { _ };

        pub const empty: Self = .{};

        pub fn deinit(self: *Self, gpa: Allocator) void {
            for (self.map.keys()) |key| gpa.free(key);
            self.map.deinit(gpa);
            self.* = .{};
        }

        /// Get-or-create the handle for `name` (no binding implied).
        pub fn intern(self: *Self, gpa: Allocator, name: []const u8) Allocator.Error!Name {
            const gop = try self.map.getOrPut(gpa, name);
            if (!gop.found_existing) {
                errdefer _ = self.map.pop();
                gop.key_ptr.* = try gpa.dupe(u8, name);
                gop.value_ptr.* = null;
            }
            return @enumFromInt(gop.index);
        }

        /// The handle for `name` if it was ever interned.
        pub fn find(self: *const Self, name: []const u8) ?Name {
            const i = self.map.getIndex(name) orelse return null;
            return @enumFromInt(i);
        }

        pub fn nameOf(self: *const Self, name: Name) []const u8 {
            return self.map.keys()[@intFromEnum(name)];
        }

        /// Bind (or rebind) `name` to `value`; visible immediately
        /// through every held handle.
        pub fn bind(self: *Self, gpa: Allocator, name: []const u8, value: T) Allocator.Error!Name {
            const n = try self.intern(gpa, name);
            self.map.values()[@intFromEnum(n)] = value;
            return n;
        }

        pub fn bindName(self: *Self, name: Name, value: T) void {
            self.map.values()[@intFromEnum(name)] = value;
        }

        pub fn unbind(self: *Self, name: Name) void {
            self.map.values()[@intFromEnum(name)] = null;
        }

        /// The binding *right now* — late binding is exactly this lookup
        /// happening at invocation.
        pub fn lookup(self: *const Self, name: Name) ?T {
            return self.map.values()[@intFromEnum(name)];
        }

        /// Lookup by string without interning.
        pub fn resolve(self: *const Self, name: []const u8) ?T {
            const n = self.find(name) orelse return null;
            return self.lookup(n);
        }

        /// Number of interned names (bound or not).
        pub fn count(self: *const Self) usize {
            return self.map.count();
        }
    };
}

// ── Tests ───────────────────────────────────────────────────────────

const t = std.testing;

test "registry: late binding — intern before bind, rebind through held handles" {
    const gpa = t.allocator;
    var reg: Registry(u32) = .empty;
    defer reg.deinit(gpa);

    // A handle taken before anything exists under the name.
    const early = try reg.intern(gpa, "editor.save");
    try t.expectEqual(@as(?u32, null), reg.lookup(early));

    // Late binding: the same handle now resolves.
    _ = try reg.bind(gpa, "editor.save", 7);
    try t.expectEqual(@as(?u32, 7), reg.lookup(early));

    // Rebinding (a plugin shadowing a built-in) is visible through it too.
    _ = try reg.bind(gpa, "editor.save", 42);
    try t.expectEqual(@as(?u32, 42), reg.lookup(early));
    try t.expectEqual(@as(?u32, 42), reg.resolve("editor.save"));

    reg.unbind(early);
    try t.expectEqual(@as(?u32, null), reg.lookup(early));
    try t.expectEqualStrings("editor.save", reg.nameOf(early));
    try t.expectEqual(@as(usize, 1), reg.count());
}
