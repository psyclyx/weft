//! scion — milestone 2: the core ABI under a milestone-1 shell. Typing
//! edits a real `core.Document` (the user is a peer committing ops);
//! rendering is still a cleared frame until milestone 3. The frame
//! loop's only wait is the swapchain (FIFO vsync).

const std = @import("std");
const wayland = @import("platform/wayland.zig");
const Context = @import("gfx/context.zig").Context;
const core = @import("core/core.zig");

// The renderer (milestone 3) builds on snail; referenced so the build
// graph keeps exercising the path dep.
const snail = @import("snail");
comptime {
    _ = snail;
}

pub fn main() !void {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    const window = try wayland.Window.init(1280, 800, "scion", "dev.psyclyx.scion");
    defer window.deinit();

    const fb = window.framebufferSize();
    const ctx = try Context.init(gpa, .{
        .display = window.display,
        .surface = window.surface,
    }, fb[0], fb[1], "scion");
    defer ctx.deinit();

    var doc = try core.Document.init(gpa, "user");
    defer doc.deinit(gpa);

    std.log.info("scion: window up ({d}x{d}), core ABI live — type to edit", .{ fb[0], fb[1] });

    while (!window.shouldClose()) {
        window.pumpEvents();

        if (window.consumeResized() or ctx.swapchain_stale) {
            const size = window.framebufferSize();
            ctx.recreateSwapchain(size[0], size[1]) catch |err| {
                std.log.err("swapchain recreation failed: {t}", .{err});
                return err;
            };
        }

        while (window.nextKeyEvent()) |ev| {
            if (!ev.pressed) continue;
            if (ev.keysym == wayland.c.XKB_KEY_Escape) return;
            // The user peer's hot path: translate the key, commit the op.
            // Allocation is the only system interaction on this path.
            if (ev.keysym == wayland.c.XKB_KEY_BackSpace) {
                const rope = doc.text();
                const len = rope.byteLen();
                if (len > 0) {
                    const start = rope.scalarToOffset(rope.scalarLen() - 1);
                    try doc.delete(gpa, .{ .start = start, .end = len });
                }
            } else if (ev.text().len > 0) {
                try doc.insert(gpa, doc.text().byteLen(), ev.text());
            } else {
                continue;
            }
            std.log.info("doc: {d} bytes, {d} commits", .{
                doc.text().byteLen(), doc.commitCount(),
            });
        }

        const cmd = try ctx.beginFrame() orelse continue;
        // Linear premultiplied clear (snail's color space): a dark slate.
        ctx.beginRenderPass(cmd, .{ 0.016, 0.018, 0.022, 1.0 });
        try ctx.endFrame();
    }
}
