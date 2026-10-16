//! The on-screen OpenGL target: a `weft_gl.Window` context presenting to the
//! platform window, in the same shape as the Vulkan `context.zig` target so
//! the frame loop drives either without knowing which (`extent`,
//! `swapchain_stale`, `recreateSwapchain`, `waitIdle`).
//!
//! Skia draws each frame straight into the window's default framebuffer and
//! `submitFrame` swaps it — no staging copy, no readback. There is no
//! swapchain object in GL; "the swapchain" here is the window's drawable,
//! which follows the framebuffer size through `recreateSwapchain` exactly as a
//! Vulkan swapchain is rebuilt, including the zero-extent rule
//! (`swapchain_state.recreated`).

const std = @import("std");
const gl = @import("weft_gl");
const platform = @import("weft_platform");
const swapchain_state = @import("swapchain_state.zig");

pub const Extent = struct { width: u32, height: u32 };

pub const Context = struct {
    allocator: std.mem.Allocator,
    window: gl.Window,
    extent: Extent,
    /// The drawable needs resizing before it can be drawn again (a zero-size
    /// configure). Same meaning as the Vulkan target's flag.
    swapchain_stale: bool = false,

    /// What `app/render_gl.zig` asks of a target: draw into framebuffer 0 and
    /// present it, rather than read the frame back.
    pub const reads_back = false;

    pub fn init(
        allocator: std.mem.Allocator,
        source: platform.SurfaceSource,
        fb_width: u32,
        fb_height: u32,
        app_name: [*:0]const u8,
    ) !*Context {
        _ = app_name; // GL has no application identity to register
        const self = try allocator.create(Context);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .window = try gl.Window.init(source, fb_width, fb_height),
            .extent = .{ .width = fb_width, .height = fb_height },
            .swapchain_stale = fb_width == 0 or fb_height == 0,
        };
        return self;
    }

    pub fn deinit(self: *Context) void {
        self.window.finish();
        self.window.deinit();
        self.allocator.destroy(self);
    }

    pub fn recreateSwapchain(self: *Context, fb_width: u32, fb_height: u32) !void {
        if (!swapchain_state.recreated(&self.swapchain_stale, fb_width, fb_height)) return error.ZeroExtent;
        self.window.resize(fb_width, fb_height);
        self.extent = .{ .width = fb_width, .height = fb_height };
    }

    /// Make the context current for a frame; false when there is nothing to
    /// draw into (a zero-size window).
    pub fn beginFrame(self: *Context) !bool {
        if (self.swapchain_stale) return false;
        try self.window.makeCurrent();
        return true;
    }

    pub fn submitFrame(self: *Context) !void {
        try self.window.swapBuffers();
    }

    pub fn stencilBits(self: *const Context) u32 {
        return self.window.stencilBits();
    }

    pub fn makeCurrent(self: *Context) !void {
        try self.window.makeCurrent();
    }

    pub fn proc(self: *const Context) gl.Proc {
        return self.window.proc();
    }

    pub fn waitIdle(self: *Context) void {
        self.window.finish();
    }
};
