//! In-memory render target for a complete Weft editor frame.
//!
//! This is a real render backend, not a screenshot assembler. It owns the
//! same `FrameBuilder` as the window backends and rasterizes every pane and
//! every piece of chrome produced by that builder into one framebuffer. A
//! consumer can only observe the completed pixels; it cannot ask this target
//! to omit syntax, semantic tools, popups, presence, or any other layer.
//!
//! The module is linked only into display-free/test applications today. Its
//! boundary is intentionally useful outside tests too: a future remote UI or
//! platform backend can consume the same complete frame without learning the
//! editor's internal layer model.

const std = @import("std");
const core = @import("../core/core.zig");
const frame = @import("frame.zig");
const FrameBuilder = @import("frame_builder.zig").FrameBuilder;
const cpu = @import("../gfx/harness.zig");

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
            self.fb.records_added = 0;
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
