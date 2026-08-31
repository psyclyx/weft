//! CPU render target for display-free unit and geometry tests.
//!
//! This exercises the shared `FrameBuilder` without Vulkan and is useful for
//! small tests that deliberately inspect geometry. It is not the authoritative
//! E2E screenshot/video path: that binds the selected production renderer to
//! `gfx/headless_vulkan.zig` and reads the completed offscreen GPU image.

const std = @import("std");
const core = @import("weft_core");
const frame = @import("frame.zig");
const FrameBuilder = @import("frame_builder.zig").FrameBuilder;
const cpu = @import("weft_gfx").harness;

pub const Frame = struct {
    pixels: []const u8,
    width: u32,
    height: u32,
    sequence: u64,
};

pub const RenderState = struct {
    gpa: std.mem.Allocator,
    fb: FrameBuilder,
    pixels: ?[]u8 = null,
    extent: [2]u32 = .{ 0, 0 },
    sequence: u64 = 0,

    pub fn init(
        self: *RenderState,
        gpa: std.mem.Allocator,
        font_bytes: []const u8,
        em: f32,
        active_id: core.Buffers.Id,
    ) !void {
        self.* = .{
            .gpa = gpa,
            .fb = undefined,
        };
        try self.fb.init(gpa, font_bytes, em, active_id);
    }

    pub fn deinit(self: *RenderState) void {
        if (self.pixels) |pixels| self.gpa.free(pixels);
        self.fb.deinit();
        self.* = undefined;
    }

    pub fn buildFrame(self: *RenderState, fx: *const frame.FrameCtx, active: frame.Active) !void {
        try self.fb.buildFrame(fx, active);
    }

    /// Materialize the last production build as one complete RGBA8 frame.
    /// A clean editor reuses its previous pixels, exactly as a window backend
    /// re-presents its previous swapchain/staging contents.
    pub fn present(self: *RenderState, extent: [2]u32) !Frame {
        if (self.fb.rebuilt or self.pixels == null or !std.mem.eql(u32, &self.extent, &extent)) {
            const next = try cpu.renderBuilt(
                self.gpa,
                &self.fb.view,
                self.fb.built_panes.items,
                extent[0],
                extent[1],
            );
            if (self.pixels) |old| self.gpa.free(old);
            self.pixels = next;
            self.extent = extent;
            self.sequence +%= 1;
            self.fb.rebuilt = false;
        }
        const pixels = self.pixels orelse return error.NoFrame;
        return .{
            .pixels = pixels,
            .width = self.extent[0],
            .height = self.extent[1],
            .sequence = self.sequence,
        };
    }
};
