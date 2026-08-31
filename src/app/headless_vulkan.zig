//! App-owned standard headless Vulkan render head.
//!
//! This is the presentation-free sibling of `WindowHead`: it owns the same
//! selected production `RenderState`, but binds it to an offscreen Vulkan
//! target. Input is intentionally absent; callers inject platform-neutral
//! editor actions through the ordinary dispatch layer.

const std = @import("std");
const core = @import("weft_core");
const Target = @import("weft_gfx").headless_vulkan.Context;
const render_mod = @import("render.zig");

pub const Head = struct {
    ctx: *Target,
    render: render_mod.RenderState,

    pub fn init(
        self: *Head,
        gpa: std.mem.Allocator,
        width: u32,
        height: u32,
        font_bytes: []const u8,
        em: f32,
        active_id: core.Buffers.Id,
    ) !void {
        self.ctx = try Target.init(gpa, width, height, "weft-e2e");
        errdefer self.ctx.deinit();
        try self.render.init(gpa, self.ctx, font_bytes, em, active_id);
    }

    pub fn deinit(self: *Head) void {
        self.render.deinit();
        self.ctx.deinit();
    }
};
