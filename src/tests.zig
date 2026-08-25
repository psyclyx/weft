//! Display-free tests: dependency wiring smoke (the path deps must build
//! and function) and platform-free logic. Window/Vulkan paths need a
//! compositor and are exercised by running the binary, not here.

const std = @import("std");
const t = std.testing;

const stemma = @import("stemma");

// The core/gfx/app unit tests now live in the `weft` module (src/weft.zig),
// which OWNS those files — build.zig runs that module's test binary too. This
// module carries the dependency-wiring smoke tests plus the driven e2e suite
// (src/e2e), which reaches the app through the `weft` module, not `../` paths.
test {
    _ = @import("e2e/e2e.zig");
}

test "stemma path dep: rope round-trips" {
    const gpa = t.allocator;
    var r = try stemma.Rope.fromSlice(gpa, "weft weaves through stemma");
    defer r.deinit(gpa);
    try t.expectEqual(@as(usize, 26), r.byteLen());
    _ = try r.insert(gpa, 0, "» ");
    const got = try r.toOwnedSlice(gpa);
    defer gpa.free(got);
    try t.expectEqualStrings("» weft weaves through stemma", got);
}

test "stemma path dep: a document with history" {
    const gpa = t.allocator;
    var doc: stemma.TextDoc = .empty;
    defer doc.deinit(gpa);
    try doc.setAgent(gpa, "weft-test");
    _ = try doc.insert(gpa, 0, "peer zero");
    try t.expectEqual(@as(usize, 9), doc.text().byteLen());
}
