//! Test-only guest proving that an untrusted tool can derive and own a child
//! directory target without receiving a raw filesystem root or host pointer.

const std = @import("std");
const weft = @import("weft");

const semantic = weft.semantic;

var child: semantic.target.Located = undefined;

export fn describe() void {
    weft.requestPerm(.fs_read);
    weft.declareCommand("fixture-close-child-directory");
}

export fn init() void {
    _ = weft.register("fixture-close-child-directory");
    const parent: semantic.target.Located = .{
        .target = .{ .authority = .here, .slot = 0, .generation = 1 },
        .revision = 1,
    };
    var listing = weft.semanticFsList(weft.allocator, parent.target, parent.revision) catch unreachable;
    defer listing.deinit();
    if (listing.value.entries.len != 1) unreachable;
    const entry = listing.value.entries[0];
    if (entry.observation.kind != .directory) unreachable;
    const entry_ref = switch (entry.observation.node) {
        .root => unreachable,
        .entry => |ref| ref,
    };
    child = weft.semanticFsPublishChildDirectory(
        weft.allocator,
        parent,
        entry_ref,
        entry.observation.revision,
    ) catch unreachable;
    var descriptor = weft.semanticTargetDescribe(child.target, weft.allocator) catch unreachable;
    defer descriptor.deinit();
    if (child.revision != descriptor.value.revision or
        !std.mem.eql(u8, entry.name.bytes, descriptor.value.display_name)) unreachable;
}

export fn on_command(id: u32) void {
    if (id != 0) return;
    weft.setResultInt(if (weft.semanticTargetClose(child.target)) 1 else 0);
}
