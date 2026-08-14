//! scion — milestone 1: a Wayland window, a Vulkan swapchain, a cleared
//! frame, and xkb-translated key events on the log. The editor grows from
//! here; the frame loop's only wait is the swapchain (FIFO vsync).

const std = @import("std");
const wayland = @import("platform/wayland.zig");
const Context = @import("gfx/context.zig").Context;

// Dependency wiring proof: the core (milestone 2) builds Document on
// stemma and the renderer (milestone 3) on snail. Referenced here so the
// build graph exercises both path deps from day one.
const stemma = @import("stemma");
const snail = @import("snail");
comptime {
    _ = stemma.TextDoc;
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

    std.log.info("scion: window up ({d}x{d}), stemma + snail wired", .{ fb[0], fb[1] });

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
            std.log.info("key: sym=0x{x} text=\"{s}\" ctrl={} alt={}", .{
                ev.keysym, ev.text(), ev.mods.ctrl, ev.mods.alt,
            });
            if (ev.keysym == wayland.c.XKB_KEY_Escape) return;
        }

        const cmd = try ctx.beginFrame() orelse continue;
        // Linear premultiplied clear (snail's color space): a dark slate.
        ctx.beginRenderPass(cmd, .{ 0.016, 0.018, 0.022, 1.0 });
        try ctx.endFrame();
    }
}
