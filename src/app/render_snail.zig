//! snail_vk backend `RenderState`: the analytic-glyph GPU renderer. It embeds
//! the shared, backend-independent `FrameBuilder` (View + pane tree + built
//! panes) and adds only the snail/Vulkan machinery — the atlas cache, resource
//! layout, the reference `Renderer` and the per-frame instance/batch stream.
//!
//! The seam is `FrameBuilder`: `buildFrame` (backend-free) produces the frame's
//! `built_panes` shapes; `present` is the ONLY method that touches the GPU — it
//! uploads the atlas delta, emits the built panes into the instance stream, and
//! records the render pass. This keeps the snail path byte-for-byte identical to
//! before the renderer split; the Skia backend mirrors this shape.

const std = @import("std");
const snail = @import("snail");
const snail_vk = @import("../gfx/snail_vk/root.zig");
const view_mod = @import("../gfx/view.zig");
const context = @import("../gfx/context.zig");
const Context = context.Context;
const frame = @import("frame.zig");
const FrameCtx = frame.FrameCtx;
const Active = frame.Active;
const stats_mod = @import("../gfx/stats.zig");
const FrameBuilder = @import("frame_builder.zig").FrameBuilder;

pub const RenderState = struct {
    gpa: std.mem.Allocator,
    /// Backend-independent frame state (View, window layout, built panes,
    /// stats, the `records_added`/`rebuilt` signals).
    fb: FrameBuilder,
    /// The device/queue/render-pass handles the per-frame uploads + `present`
    /// need (a value bundle derived from the Context).
    vctx: snail_vk.VulkanContext,
    layout: snail_vk.VulkanResourceLayout,
    /// A value copy of the layout's samplers/desc-set handle — self-contained,
    /// so it survives independently of `layout`'s address.
    resources: snail_vk.ResourceContext,
    cache: snail_vk.VulkanDeviceAtlas,
    renderer: snail_vk.Renderer,
    /// The live atlas binding, re-established by each delta upload.
    binding: [1]snail.render.records.Binding,
    instances: std.ArrayList(snail.render.records.Instance),
    batches: std.ArrayList(snail.render.records.DrawBatch),

    /// Build every render resource IN PLACE (`self` is already at its final
    /// address in `main()`'s frame). `active_id` seeds the single-pane layout.
    pub fn init(
        self: *RenderState,
        gpa: std.mem.Allocator,
        ctx: *Context,
        font_bytes: []const u8,
        em: f32,
        active_id: @import("../core/core.zig").Buffers.Id,
    ) !void {
        self.gpa = gpa;
        self.vctx = .{
            .physical_device = ctx.physical_device,
            .device = ctx.device,
            .graphics_queue = ctx.queue,
            .queue_family_index = ctx.queue_family,
            .render_pass = ctx.render_pass,
        };
        try self.fb.init(gpa, font_bytes, em, active_id);
        errdefer self.fb.deinit();
        try self.layout.init(self.vctx);
        errdefer self.layout.deinit();
        self.resources = snail_vk.cacheResourceContext(self.vctx, &self.layout);
        self.cache = try snail_vk.VulkanDeviceAtlas.init(gpa, self.fb.view.pool, self.resources, .{});
        errdefer self.cache.deinit();
        self.renderer = try snail_vk.Renderer.init(self.vctx, self.layout.desc_set_layout, 2 << 20, context.max_frames_in_flight, .disabled);
        errdefer self.renderer.deinit();
        // Initial (empty) upload establishes the live binding.
        try snail_vk.uploadAndWait(gpa, self.vctx, self.resources, ctx.command_pool, &self.cache, &.{&self.fb.view.atlas}, &self.binding);
        self.instances = .empty;
        self.batches = .empty;
    }

    /// Backend-independent build (delegates to the shared `FrameBuilder`).
    pub fn buildFrame(self: *RenderState, fx: *const FrameCtx, act: Active) !void {
        return self.fb.buildFrame(fx, act);
    }

    /// Emit every built pane into ONE instance/batch stream (carried emit
    /// cursors + the identity transform, since each pane built into its own
    /// absolute rect). The focused pane is last in `built_panes`, so its caret
    /// draws on top. It stamps instances with the live atlas `binding`, so it
    /// must run AFTER the atlas upload — hence it lives on the backend path.
    fn emitBuiltPanes(self: *RenderState) !void {
        const gpa = self.gpa;
        self.instances.clearRetainingCapacity();
        self.batches.clearRetainingCapacity();
        var total_shapes: usize = 0;
        for (self.fb.built_panes.items) |bp| total_shapes += bp.shapes.len;
        try self.instances.resize(gpa, @max(total_shapes, 1));
        try self.batches.resize(gpa, @max(total_shapes, 1));
        var ilen: usize = 0;
        var blen: usize = 0;
        for (self.fb.built_panes.items) |bp| {
            _ = try snail.emit.emit(self.instances.items, self.batches.items, &ilen, &blen, self.binding[0], &self.fb.view.atlas, bp.shapes, .identity, .{ 1, 1, 1, 1 });
        }
        self.instances.items.len = ilen;
        self.batches.items.len = blen;
    }

    /// The GPU present: upload the frame's atlas delta, emit the built panes
    /// into the instance stream, then acquire a swapchain image, record the
    /// stream into the render pass, submit, present, and record latency
    /// stats. The ONLY method that touches the swapchain/command buffer or
    /// GPU atlas. Returns whether a frame was actually submitted — `false`
    /// means `beginFrame` deferred (the prior frame's fence isn't signaled
    /// yet, or the swapchain needs recreation); the caller (main()'s
    /// present-retry source, north-star-plan §6 W2a-3) tries again on the
    /// next scheduler wake. The upload/emit above already ran and is NOT
    /// redone on a retry (`fb.rebuilt` is cleared up front — a retry finds
    /// it already false and reuses `self.instances`/`self.batches`).
    pub fn present(self: *RenderState, ctx: *Context, fb: [2]u32, frame_start: u64, had_input: bool) !bool {
        // Backend-only atlas upload + instance emit, driven by the build's
        // `records_added`/`rebuilt` signals. Runs on every rebuilt frame
        // regardless of swapchain availability; a clean frame reuses last
        // frame's stream. Upload before emit → instances stamp the fresh binding.
        if (self.fb.rebuilt) {
            self.fb.rebuilt = false;
            if (self.fb.records_added != 0) {
                self.fb.records_added = 0;
                self.binding[0] = try snail_vk.uploadDeltaAndWait(self.gpa, self.vctx, self.resources, ctx.command_pool, &self.cache, self.binding[0], &self.fb.view.atlas);
            }
            try self.emitBuiltPanes();
        }
        const cmd = try ctx.beginFrame() orelse return false;
        ctx.beginRenderPass(cmd, self.fb.view.theme.background);
        self.renderer.beginFrame(ctx.current_frame);
        const draw_state: snail.render.target.DrawState = .{
            .mvp = snail.Mat4.ortho(0, @floatFromInt(fb[0]), @floatFromInt(fb[1]), 0, -1, 1),
            .surface = .{
                .pixel_width = fb[0],
                .pixel_height = fb[1],
                .encoding = if (ctx.surfaceEncodesSrgb()) .srgb else .linear,
            },
        };
        try self.renderer.render(cmd, &self.cache, draw_state, self.instances.items, self.batches.items);
        try ctx.endFrame();

        const frame_ns = stats_mod.nowNs() - frame_start;
        self.fb.stats.recordFrame(frame_ns);
        if (had_input) self.fb.stats.recordInput(frame_ns);
        _ = self.fb.stats.maybeLog(600);
        return true;
    }

    pub fn deinit(self: *RenderState) void {
        self.batches.deinit(self.gpa);
        self.instances.deinit(self.gpa);
        self.renderer.deinit();
        self.cache.deinit();
        self.layout.deinit();
        self.fb.deinit();
    }
};
