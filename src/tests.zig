//! Display-free tests: dependency wiring smoke (the path deps must build
//! and function) and platform-free logic. Window/Vulkan paths need a
//! compositor and are exercised by running the binary, not here.

const std = @import("std");
const t = std.testing;

const stemma = @import("stemma");
const snail = @import("snail");

test {
    // The core ABI (milestone 2) and its property tests.
    t.refAllDecls(@import("core/core.zig"));
    _ = @import("core/tests.zig");
}

test "stemma path dep: rope round-trips" {
    const gpa = t.allocator;
    var r = try stemma.Rope.fromSlice(gpa, "scion grafts onto stemma");
    defer r.deinit(gpa);
    try t.expectEqual(@as(usize, 24), r.byteLen());
    _ = try r.insert(gpa, 0, "» ");
    const got = try r.toOwnedSlice(gpa);
    defer gpa.free(got);
    try t.expectEqualStrings("» scion grafts onto stemma", got);
}

test "stemma path dep: a document with history" {
    const gpa = t.allocator;
    var doc: stemma.TextDoc = .empty;
    defer doc.deinit(gpa);
    try doc.setAgent(gpa, "scion-test");
    _ = try doc.insert(gpa, 0, "peer zero");
    try t.expectEqual(@as(usize, 9), doc.text().byteLen());
}

test "snail path dep: module reachable" {
    // Compile-time reachability is the wiring proof; snail's own suite
    // covers behavior. Keep one runtime touch so the linker is exercised.
    comptime {
        _ = snail;
    }
}
