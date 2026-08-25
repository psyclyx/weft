//! Skia backend `RenderState` (the default renderer). It embeds the shared
//! `FrameBuilder` (View + pane tree + built panes) and adds the Skia renderer +
//! the Vulkan glue that lands its output in the target image. Skia rasterizes the frame
//! into its own surface (Ganesh Vulkan when a real GPU exists, else CPU raster);
//! `present` copies those pixels into the acquired Vulkan image via a
//! host-visible staging buffer and the target's render-pass-free terminal submit
//! — so Vulkan still owns device/queue/output, only Skia's
//! rasterization moves (and, on CPU fallback, off the GPU entirely).
//!
//! The content boundary is Weft's renderer-neutral draw list: `buildFrame`
//! lowers each pane to explicit glyphs and fill rects, which Skia decodes into
//! SkCanvas calls.

const std = @import("std");
const vk = @import("../vk.zig").c;
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
    /// target image each submit. Resized with the framebuffer.
    staging: Staging,
    /// A frame has been rasterized and is ready to copy (guards the first
    /// present before any build has run).
    have_frame: bool,
    /// Output byte order (true = BGRA to match a B8G8R8A8 target).
    bgra: bool,
    /// One-shot: the WEFT_SKIA_DUMP debug dump has fired.
    dumped: bool,

    pub fn init(
        self: *RenderState,
        gpa: std.mem.Allocator,
        ctx: anytype,
        font_bytes: []const u8,
        em: f32,
        active_id: core.Buffers.Id,
    ) !void {
        self.gpa = gpa;
        try self.fb.init(gpa, font_bytes, em, active_id);
        errdefer self.fb.deinit();

        // Match the shim's byte order to the target format so the copy is a
        // straight blit.
        const fmt = ctx.colorFormat();
        const bgra = fmt == vk.VK_FORMAT_B8G8R8A8_SRGB or fmt == vk.VK_FORMAT_B8G8R8A8_UNORM;

        // CPU raster when there is no real GPU, or when WEFT_SKIA_CPU is set.
        const force_cpu = std.c.getenv(cpu_env) != null;
        const want_gpu = ctx.has_real_gpu and !force_cpu;
        const extensions = ctx.vulkanExtensions();
        var vkinfo: skia.VulkanInfo = .{
            .instance = ctx.instance,
            .physical_device = ctx.physical_device,
            .device = ctx.device,
            .queue = ctx.queue,
            .queue_family = ctx.queue_family,
            .get_instance_proc_addr = @ptrCast(&vk.vkGetInstanceProcAddr),
            .api_version = vk.VK_API_VERSION_1_1,
            .instance_extensions = if (extensions.instance.len == 0) null else extensions.instance.ptr,
            .instance_extension_count = @intCast(extensions.instance.len),
            .device_extensions = if (extensions.device.len == 0) null else extensions.device.ptr,
            .device_extension_count = @intCast(extensions.device.len),
        };
        self.skia = try skia.Skia.init(&vkinfo, want_gpu, bgra);
        errdefer self.skia.deinit();
        std.log.info("weft: skia renderer — {s} backend{s}", .{
            if (self.skia.gpu) "ganesh/vulkan" else "cpu-raster",
            if (!ctx.has_real_gpu) " (no dedicated GPU)" else if (force_cpu) " (WEFT_SKIA_CPU)" else "",
        });

        // Register every owned face by its stable font_id (1..5) so shaped
        // glyph ids resolve against the same font bytes.
        const face_set = &self.fb.view.face_set;
        for (0..face_set.bytes.len) |i| self.skia.registerFont(@intCast(i + 1), face_set.bytes[i]);

        self.staging = .{};
        self.have_frame = false;
        self.bgra = bgra;
        self.dumped = false;
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
    fn rasterize(self: *RenderState, ctx: anytype) !void {
        const w = ctx.extent.width;
        const h = ctx.extent.height;
        try self.skia.begin(w, h, self.fb.view.theme.background);
        for (self.fb.built_panes.items) |bp| self.skia.drawItems(bp.items);
        const f = try self.skia.end(w, h);

        const total = @as(usize, f.height) * f.row_bytes;
        try self.staging.ensure(ctx, total);
        @memcpy(self.staging.mapped[0..total], f.pixels[0..total]);
        self.have_frame = true;

        // Debug: WEFT_SKIA_DUMP=<path> writes the first rasterized frame to a
        // PPM so the shape→Skia decode can be eyeballed without a screenshot.
        if (!self.dumped) {
            self.dumped = true;
            if (std.c.getenv("WEFT_SKIA_DUMP")) |path| dumpPpm(self.gpa, std.mem.sliceTo(path, 0), f, self.bgra) catch {};
        }
    }

    /// Terminal render: (re)rasterize on damage, acquire the target image, copy
    /// the staged pixels into it, and submit. The boolean reports whether a
    /// frame was submitted, so the caller can retry a deferred target frame on
    /// the next scheduler wake.
    pub fn present(self: *RenderState, ctx: anytype, fb: [2]u32, frame_start: u64, had_input: bool) !bool {
        _ = fb; // geometry follows ctx.extent (kept in sync by main)
        if (self.fb.rebuilt) {
            self.fb.rebuilt = false;
            try self.rasterize(ctx);
        }
        if (!self.have_frame) return false;

        const cmd = try ctx.beginFrame() orelse return false;
        self.copyToTarget(ctx, cmd);
        try ctx.submitFrame(cmd);

        const frame_ns = stats_mod.nowNs() - frame_start;
        self.fb.stats.recordFrame(frame_ns);
        if (had_input) self.fb.stats.recordInput(frame_ns);
        _ = self.fb.stats.maybeLog(600);
        return true;
    }

    /// Record staged pixels → acquired target image: transition to
    /// TRANSFER_DST, copy the full extent, then enter the target's final layout
    /// (PRESENT for WSI, TRANSFER_SRC for headless readback). The whole frame is
    /// overwritten, so UNDEFINED is the correct old layout.
    fn copyToTarget(self: *RenderState, ctx: anytype, cmd: vk.VkCommandBuffer) void {
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

        const final_layout = ctx.targetFinalLayout();
        barrier(cmd, image, range, .{
            .old_layout = vk.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
            .new_layout = final_layout,
            .src_access = vk.VK_ACCESS_TRANSFER_WRITE_BIT,
            .dst_access = if (final_layout == vk.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL) vk.VK_ACCESS_TRANSFER_READ_BIT else 0,
            .src_stage = vk.VK_PIPELINE_STAGE_TRANSFER_BIT,
            .dst_stage = if (final_layout == vk.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL) vk.VK_PIPELINE_STAGE_TRANSFER_BIT else vk.VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT,
        });
    }
};

/// Write a rasterized Skia frame to a binary P6 PPM (debug aid; best-effort).
fn dumpPpm(gpa: std.mem.Allocator, path: []const u8, f: skia.Frame, bgra: bool) !void {
    const header = try std.fmt.allocPrint(gpa, "P6\n{d} {d}\n255\n", .{ f.width, f.height });
    defer gpa.free(header);
    const out = try gpa.alloc(u8, header.len + @as(usize, f.width) * f.height * 3);
    defer gpa.free(out);
    @memcpy(out[0..header.len], header);
    var di = header.len;
    var row: usize = 0;
    while (row < f.height) : (row += 1) {
        const base = row * f.row_bytes;
        var x: usize = 0;
        while (x < f.width) : (x += 1) {
            const p = base + x * 4;
            out[di] = if (bgra) f.pixels[p + 2] else f.pixels[p]; // R
            out[di + 1] = f.pixels[p + 1]; // G
            out[di + 2] = if (bgra) f.pixels[p] else f.pixels[p + 2]; // B
            di += 3;
        }
    }
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    try std.Io.Dir.cwd().writeFile(threaded.io(), .{ .sub_path = path, .data = out[0..di] });
}

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
/// target image. It borrows the device from the target passed to `ensure`.
const Staging = struct {
    buffer: vk.VkBuffer = null,
    memory: vk.VkDeviceMemory = null,
    mapped: [*]u8 = undefined,
    is_mapped: bool = false,
    size: usize = 0,
    device: vk.VkDevice = null,

    fn ensure(self: *Staging, ctx: anytype, need: usize) !void {
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
        self.is_mapped = true;
        self.size = need;
    }

    fn free(self: *Staging) void {
        if (self.device == null) return;
        if (self.memory != null) {
            if (self.is_mapped) vk.vkUnmapMemory(self.device, self.memory);
            vk.vkFreeMemory(self.device, self.memory, null);
            self.memory = null;
        }
        if (self.buffer != null) {
            vk.vkDestroyBuffer(self.device, self.buffer, null);
            self.buffer = null;
        }
        self.is_mapped = false;
        self.size = 0;
    }

    fn deinit(self: *Staging) void {
        if (self.device != null) _ = vk.vkDeviceWaitIdle(self.device);
        self.free();
    }
};
