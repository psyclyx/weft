//! `RenderState` — the cohesive owner of the snail/Vulkan render path and the
//! window-layout pane tree. `main()` holds ONE `render` object instead of a
//! dozen loose render locals; its `init` builds every resource in place (no
//! self-referential move hazard) and its `deinit` frees them in the exact
//! reverse order `main()` used to, so the shutdown sequence is unchanged.
//!
//! The seam this sets up: `buildFrame` is backend-independent (per-pane
//! `view.build` → shapes + the HUD assembly), while `present` is the only
//! method that touches the swapchain/command-buffer. A headless harness can
//! drive `buildFrame` and skip `present`. NOTE: the atlas-delta GPU uploads
//! (`uploadDeltaAndWait`) still ride inside the per-pane build loop — that is
//! the one place Vulkan leaks into the build, and the seam to lift later.

const std = @import("std");
const snail = @import("snail");
const snail_vk = @import("../gfx/snail_vk/root.zig");
const view_mod = @import("../gfx/view.zig");
const window_layout = @import("../gfx/window_layout.zig");
const stats_mod = @import("../gfx/stats.zig");
const context = @import("../gfx/context.zig");

pub const RenderState = struct {
    gpa: std.mem.Allocator,
    /// The device/queue/render-pass handles (a value bundle) needed by the
    /// per-frame uploads and by `present`.
    vctx: snail_vk.VulkanContext,
    view: view_mod.View,
    layout: snail_vk.VulkanResourceLayout,
    /// A value copy of the layout's samplers/desc-set handle — self-contained,
    /// so it survives independently of `layout`'s address.
    resources: snail_vk.ResourceContext,
    cache: snail_vk.VulkanDeviceAtlas,
    renderer: snail_vk.Renderer,
    /// The live atlas binding, re-established by each delta upload.
    binding: [1]snail.render.records.Binding,
    stats: stats_mod.Stats,
    /// One `Built` per rendered pane, kept alive for the frame (its shapes feed
    /// the instance stream) and freed at the top of the next build.
    built_panes: std.ArrayList(view_mod.Built),
    instances: std.ArrayList(snail.render.records.Instance),
    batches: std.ArrayList(snail.render.records.DrawBatch),
    /// The recursive pane tree over the region geometry (a single leaf is the
    /// ordinary unsplit case). The focused pane is always the active buffer.
    win_layout: window_layout.Layout,

    /// Build every render resource IN PLACE (`self` is already at its final
    /// address in `main()`'s frame), so no captured `&self.field` can dangle
    /// after a move. `active_id` seeds the initial single-pane layout.
    pub fn init(
        self: *RenderState,
        gpa: std.mem.Allocator,
        vctx: snail_vk.VulkanContext,
        command_pool: @import("../vk.zig").c.VkCommandPool,
        font_bytes: []const u8,
        em: f32,
        active_id: @import("../core/core.zig").Buffers.Id,
    ) !void {
        self.gpa = gpa;
        self.vctx = vctx;
        self.view = try view_mod.View.init(gpa, font_bytes, em);
        errdefer self.view.deinit();
        try self.layout.init(vctx);
        errdefer self.layout.deinit();
        self.resources = snail_vk.cacheResourceContext(vctx, &self.layout);
        self.cache = try snail_vk.VulkanDeviceAtlas.init(gpa, self.view.pool, self.resources, .{});
        errdefer self.cache.deinit();
        self.renderer = try snail_vk.Renderer.init(vctx, self.layout.desc_set_layout, 2 << 20, context.max_frames_in_flight, .disabled);
        errdefer self.renderer.deinit();
        // Initial (empty) upload establishes the live binding.
        try snail_vk.uploadAndWait(gpa, vctx, self.resources, command_pool, &self.cache, &.{&self.view.atlas}, &self.binding);
        self.stats = .{};
        self.built_panes = .empty;
        self.instances = .empty;
        self.batches = .empty;
        self.win_layout = try window_layout.Layout.init(gpa, active_id);
    }

    /// Free in the exact reverse order `main()`'s defers used to run:
    /// win_layout, batches, instances, built_panes, renderer, cache, layout,
    /// view.
    pub fn deinit(self: *RenderState) void {
        self.win_layout.deinit();
        self.batches.deinit(self.gpa);
        self.instances.deinit(self.gpa);
        for (self.built_panes.items) |*b| b.deinit(self.gpa);
        self.built_panes.deinit(self.gpa);
        self.renderer.deinit();
        self.cache.deinit();
        self.layout.deinit();
        self.view.deinit();
    }
};
