//! Standard headless OpenGL target: an offscreen context + the last completed
//! frame. The OpenGL sibling of `headless_vulkan.zig`, with the same surface
//! the e2e harness drives (`extent`, `readFrame`, `waitIdle`).
//!
//! There is no window, drawable or platform input here. Skia renders each
//! frame into its own render target on this context and reads it back
//! (`app/render_gl.zig`); the target keeps that frame until the caller reads
//! it, so a frame can be submitted now and collected later, as with Vulkan.

const std = @import("std");
const gl = @import("weft_gl");

pub const Extent = struct { width: u32, height: u32 };

pub const Context = struct {
    allocator: std.mem.Allocator,
    offscreen: gl.Offscreen,
    extent: Extent,
    /// The last frame, tightly packed RGBA8, top row first.
    frame: []u8,
    submitted: bool = false,

    /// What `app/render_gl.zig` asks of a target: render into Skia's own
    /// surface and hand the read-back pixels to `submitPixels`.
    pub const reads_back = true;

    pub fn init(allocator: std.mem.Allocator, width: u32, height: u32, app_name: [*:0]const u8) !*Context {
        _ = app_name;
        const self = try allocator.create(Context);
        errdefer allocator.destroy(self);
        const frame = try allocator.alloc(u8, @as(usize, width) * height * 4);
        errdefer allocator.free(frame);
        self.* = .{
            .allocator = allocator,
            .offscreen = try gl.Offscreen.init(),
            .extent = .{ .width = width, .height = height },
            .frame = frame,
        };
        return self;
    }

    pub fn deinit(self: *Context) void {
        self.offscreen.finish();
        self.offscreen.deinit();
        self.allocator.free(self.frame);
        self.allocator.destroy(self);
    }

    pub fn beginFrame(self: *Context) !bool {
        try self.offscreen.makeCurrent();
        return true;
    }

    /// Keep a rendered frame (`row_bytes` per row, RGBA8) until `readFrame`.
    pub fn submitPixels(self: *Context, pixels: [*]const u8, row_bytes: usize) void {
        const row = @as(usize, self.extent.width) * 4;
        for (0..self.extent.height) |y| {
            @memcpy(self.frame[y * row ..][0..row], pixels[y * row_bytes ..][0..row]);
        }
        self.submitted = true;
    }

    /// The last submitted frame as RGBA8, owned by the caller.
    pub fn readFrame(self: *Context, gpa: std.mem.Allocator) ![]u8 {
        if (!self.submitted) return error.FrameNotSubmitted;
        self.submitted = false;
        return gpa.dupe(u8, self.frame);
    }

    pub fn makeCurrent(self: *Context) !void {
        try self.offscreen.makeCurrent();
    }

    pub fn proc(self: *const Context) gl.Proc {
        return self.offscreen.proc();
    }

    pub fn waitIdle(self: *Context) void {
        self.offscreen.finish();
    }
};
