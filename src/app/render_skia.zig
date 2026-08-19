//! Skia backend `RenderState` (the default renderer). It embeds the shared
//! `FrameBuilder` (View + pane tree + built panes) and adds the Skia renderer +
//! the Vulkan glue that lands its output on screen. Skia rasterizes the frame
//! into its own surface (Ganesh Vulkan when a real GPU exists, else CPU raster);
//! `present` copies those pixels into the acquired swapchain image via a
//! host-visible staging buffer and the Context's render-pass-free `submitPresent`
//! — so Vulkan still owns device/queue/swapchain/present, only Skia's
//! rasterization moves (and, on CPU fallback, off the GPU entirely).
//!
//! The content boundary is snail's `[]Shape`: `buildFrame` (shared) lowers each
//! pane to affine-placed glyph records + fill rects; `skia.drawShapes` decodes
//! those to SkCanvas calls. No snail Vulkan pipeline or SPIR-V is pulled in.

const std = @import("std");
const vk = @import("../vk.zig").c;
const context = @import("../gfx/context.zig");
const Context = context.Context;
const skia = @import("../gfx/skia/root.zig");
const stats_mod = @import("../gfx/stats.zig");
const frame = @import("frame.zig");
const FrameCtx = frame.FrameCtx;
const Active = frame.Active;
const FrameBuilder = @import("frame_builder.zig").FrameBuilder;
const core = @import("../core/core.zig");

/// Env var (any non-empty value) forcing Skia's CPU raster backend even when a
/// real GPU is present — the same path taken automatically when there is no
/// dedicated GPU (`ctx.has_real_gpu == false`).
const cpu_env: [:0]const u8 = "WEFT_SKIA_CPU";

pub const RenderState = struct {
    gpa: std.mem.Allocator,
    fb: FrameBuilder,
    skia: skia.Skia,
    /// Host-visible buffer holding the last rasterized frame, copied into the
    /// swapchain image each present. Resized on framebuffer resize.
    staging: Staging,
    /// A frame has been rasterized and is ready to copy (guards the first
    /// present before any build has run).
    have_frame: bool,

    pub fn init(
        self: *RenderState,
        gpa: std.mem.Allocator,
        ctx: *Context,
        font_bytes: []const u8,
        em: f32,
        active_id: core.Buffers.Id,
    ) !void {
        self.gpa = gpa;
        try self.fb.init(gpa, font_bytes, em, active_id);
        errdefer self.fb.deinit();

        // Match the shim's byte order to the swapchain format so the copy is a
        // straight blit; both common formats are sRGB-encoded (see context.zig).
        const fmt = ctx.surface_format.format;
        const bgra = fmt == vk.VK_FORMAT_B8G8R8A8_SRGB or fmt == vk.VK_FORMAT_B8G8R8A8_UNORM;

        // CPU raster when there is no real GPU, or when WEFT_SKIA_CPU is set.
        const force_cpu = std.c.getenv(cpu_env) != null;
        const want_gpu = ctx.has_real_gpu and !force_cpu;
        var vkinfo: skia.VulkanInfo = .{
            .instance = ctx.instance,
            .physical_device = ctx.physical_device,
            .device = ctx.device,
            .queue = ctx.queue,
            .queue_family = ctx.queue_family,
            .get_instance_proc_addr = @ptrCast(&vk.vkGetInstanceProcAddr),
            .api_version = vk.VK_API_VERSION_1_1,
        };
        self.skia = try skia.Skia.init(&vkinfo, want_gpu, bgra);
        errdefer self.skia.deinit();
        std.log.info("weft: skia renderer — {s} backend{s}", .{
            if (self.skia.gpu) "ganesh/vulkan" else "cpu-raster",
            if (!ctx.has_real_gpu) " (no dedicated GPU)" else if (force_cpu) " (WEFT_SKIA_CPU)" else "",
        });

        // Register every owned face by its stable font_id (1..5) so glyph ids
        // in the shapes resolve to the same outlines snail shaped from.
        const face_set = &self.fb.view.face_set;
        for (0..face_set.bytes.len) |i| self.skia.registerFont(@intCast(i + 1), face_set.bytes[i]);

        self.staging = .{};
        self.have_frame = false;
    }

    pub fn deinit(self: *RenderState) void {
        // The device is still alive (Context outlives us); free the staging
        // buffer against it before tearing down Skia + the frame builder.
        self.staging.deinit();
        self.skia.deinit();
        self.fb.deinit();
    }

    /// Backend-independent build (delegates to the shared `FrameBuilder`).
    pub fn buildFrame(self: *RenderState, fx: *const FrameCtx, act: Active) !void {
        return self.fb.buildFrame(fx, act);
    }

    /// Rasterize the built panes with Skia into the staging buffer. Runs only on
    /// rebuilt frames; the buffer persists so clean frames re-present it.
    fn rasterize(self: *RenderState, ctx: *Context) !void {
        const w = ctx.extent.width;
        const h = ctx.extent.height;
        try self.skia.begin(w, h, self.fb.view.theme.background);
        for (self.fb.built_panes.items) |bp| self.skia.drawShapes(bp.shapes);
        const f = try self.skia.end(w, h);

        const total = @as(usize, f.height) * f.row_bytes;
        try self.staging.ensure(ctx, total);
        @memcpy(self.staging.mapped[0..total], f.pixels[0..total]);
        self.have_frame = true;
    }

    /// Present: (re)rasterize on damage, then acquire a swapchain image, copy the
    /// staged pixels into it, and submit/present. The only method touching the
    /// swapchain — mirrors the snail backend's `present` seam.
    pub fn present(self: *RenderState, ctx: *Context, fb: [2]u32, frame_start: u64, had_input: bool) !void {
        _ = fb; // geometry follows ctx.extent (kept in sync by main)
        if (self.fb.rebuilt) {
            self.fb.rebuilt = false;
            self.fb.records_added = 0;
            try self.rasterize(ctx);
        }
        if (!self.have_frame) return;

        const cmd = try ctx.beginFrame() orelse return;
        self.copyToSwapchain(ctx, cmd);
        try ctx.submitPresent(cmd);

        const frame_ns = stats_mod.nowNs() - frame_start;
        self.fb.stats.recordFrame(frame_ns);
        if (had_input) self.fb.stats.recordInput(frame_ns);
        _ = self.fb.stats.maybeLog(600);
    }

    /// Record the staged pixels → acquired swapchain image copy: transition to
    /// TRANSFER_DST, copy the full extent, transition to PRESENT_SRC. Contents
    /// are not preserved (UNDEFINED old layout), which is correct — the whole
    /// frame is overwritten.
    fn copyToSwapchain(self: *RenderState, ctx: *Context, cmd: vk.VkCommandBuffer) void {
        const image = ctx.images[ctx.image_index];
        const range = vk.VkImageSubresourceRange{
            .aspectMask = vk.VK_IMAGE_ASPECT_COLOR_BIT,
            .baseMipLevel = 0,
            .levelCount = 1,
            .baseArrayLayer = 0,
            .layerCount = 1,
        };

        barrier(cmd, image, range, .{
            .old_layout = vk.VK_IMAGE_LAYOUT_UNDEFINED,
            .new_layout = vk.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
            .src_access = 0,
            .dst_access = vk.VK_ACCESS_TRANSFER_WRITE_BIT,
            .src_stage = vk.VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT,
            .dst_stage = vk.VK_PIPELINE_STAGE_TRANSFER_BIT,
        });

        const region = vk.VkBufferImageCopy{
            .bufferOffset = 0,
            .bufferRowLength = 0, // tightly packed (= image width)
            .bufferImageHeight = 0,
            .imageSubresource = .{
                .aspectMask = vk.VK_IMAGE_ASPECT_COLOR_BIT,
                .mipLevel = 0,
                .baseArrayLayer = 0,
                .layerCount = 1,
            },
            .imageOffset = .{ .x = 0, .y = 0, .z = 0 },
            .imageExtent = .{ .width = ctx.extent.width, .height = ctx.extent.height, .depth = 1 },
        };
        vk.vkCmdCopyBufferToImage(cmd, self.staging.buffer, image, vk.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &region);

        barrier(cmd, image, range, .{
            .old_layout = vk.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
            .new_layout = vk.VK_IMAGE_LAYOUT_PRESENT_SRC_KHR,
            .src_access = vk.VK_ACCESS_TRANSFER_WRITE_BIT,
            .dst_access = 0,
            .src_stage = vk.VK_PIPELINE_STAGE_TRANSFER_BIT,
            .dst_stage = vk.VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT,
        });
    }
};

const BarrierSpec = struct {
    old_layout: vk.VkImageLayout,
    new_layout: vk.VkImageLayout,
    src_access: vk.VkAccessFlags,
    dst_access: vk.VkAccessFlags,
    src_stage: vk.VkPipelineStageFlags,
    dst_stage: vk.VkPipelineStageFlags,
};

fn barrier(cmd: vk.VkCommandBuffer, image: vk.VkImage, range: vk.VkImageSubresourceRange, spec: BarrierSpec) void {
    const b = vk.VkImageMemoryBarrier{
        .sType = vk.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
        .srcAccessMask = spec.src_access,
        .dstAccessMask = spec.dst_access,
        .oldLayout = spec.old_layout,
        .newLayout = spec.new_layout,
        .srcQueueFamilyIndex = vk.VK_QUEUE_FAMILY_IGNORED,
        .dstQueueFamilyIndex = vk.VK_QUEUE_FAMILY_IGNORED,
        .image = image,
        .subresourceRange = range,
    };
    vk.vkCmdPipelineBarrier(cmd, spec.src_stage, spec.dst_stage, 0, 0, null, 0, null, 1, &b);
}

/// A host-visible, coherent buffer for streaming Skia's rasterized frame to the
/// swapchain image. It borrows the device from the Context passed to `ensure`.
const Staging = struct {
    buffer: vk.VkBuffer = null,
    memory: vk.VkDeviceMemory = null,
    mapped: [*]u8 = undefined,
    size: usize = 0,
    device: vk.VkDevice = null,

    fn ensure(self: *Staging, ctx: *Context, need: usize) !void {
        if (self.buffer != null and self.size >= need) return;
        self.free();
        self.device = ctx.device;

        const bi = vk.VkBufferCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
            .size = need,
            .usage = vk.VK_BUFFER_USAGE_TRANSFER_SRC_BIT,
            .sharingMode = vk.VK_SHARING_MODE_EXCLUSIVE,
        };
        if (vk.vkCreateBuffer(ctx.device, &bi, null, &self.buffer) != vk.VK_SUCCESS) return error.VulkanFailed;
        errdefer self.free();

        var req: vk.VkMemoryRequirements = undefined;
        vk.vkGetBufferMemoryRequirements(ctx.device, self.buffer, &req);
        const mem_type = try ctx.findMemoryType(req.memoryTypeBits, vk.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | vk.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);
        const ai = vk.VkMemoryAllocateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
            .allocationSize = req.size,
            .memoryTypeIndex = mem_type,
        };
        if (vk.vkAllocateMemory(ctx.device, &ai, null, &self.memory) != vk.VK_SUCCESS) return error.VulkanFailed;
        if (vk.vkBindBufferMemory(ctx.device, self.buffer, self.memory, 0) != vk.VK_SUCCESS) return error.VulkanFailed;

        var ptr: ?*anyopaque = null;
        if (vk.vkMapMemory(ctx.device, self.memory, 0, need, 0, &ptr) != vk.VK_SUCCESS) return error.VulkanFailed;
        self.mapped = @ptrCast(ptr.?);
        self.size = need;
    }

    fn free(self: *Staging) void {
        if (self.device == null) return;
        if (self.memory != null) {
            vk.vkUnmapMemory(self.device, self.memory);
            vk.vkFreeMemory(self.device, self.memory, null);
            self.memory = null;
        }
        if (self.buffer != null) {
            vk.vkDestroyBuffer(self.device, self.buffer, null);
            self.buffer = null;
        }
        self.size = 0;
    }

    fn deinit(self: *Staging) void {
        if (self.device != null) _ = vk.vkDeviceWaitIdle(self.device);
        self.free();
    }
};
