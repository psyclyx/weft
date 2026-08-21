//! Vulkan bootstrap: instance, surface, device, swapchain, render pass,
//! per-frame command buffers and synchronization. Platform-neutral; the
//! caller hands in the native window handles.

const std = @import("std");
const vkmod = @import("../vk.zig");
const vk = vkmod.c;
const build_options = @import("build_options");

pub const max_frames_in_flight = 2;

pub const SurfaceSource = struct {
    display: *anyopaque, // *wl_display
    surface: *anyopaque, // *wl_surface
};

fn check(result: vk.VkResult) !void {
    if (result != vk.VK_SUCCESS) {
        std.log.err("vulkan call failed: {d}", .{result});
        return error.VulkanFailed;
    }
}

pub const Context = struct {
    allocator: std.mem.Allocator,

    instance: vk.VkInstance = null,
    surface: vk.VkSurfaceKHR = null,
    physical_device: vk.VkPhysicalDevice = null,
    device: vk.VkDevice = null,
    queue: vk.VkQueue = null,
    queue_family: u32 = 0,
    /// Whether `pickDevice` found a real (non-software, non-CPU) GPU. The Skia
    /// backend consults this to choose Ganesh (GPU) vs its CPU raster path;
    /// snail ignores it. False ⇒ only lavapipe/llvmpipe/CPU was available.
    has_real_gpu: bool = false,

    surface_format: vk.VkSurfaceFormatKHR = undefined,
    swapchain: vk.VkSwapchainKHR = null,
    extent: vk.VkExtent2D = .{ .width = 0, .height = 0 },
    images: []vk.VkImage = &.{},
    views: []vk.VkImageView = &.{},
    framebuffers: []vk.VkFramebuffer = &.{},
    render_pass: vk.VkRenderPass = null,

    command_pool: vk.VkCommandPool = null,
    command_buffers: [max_frames_in_flight]vk.VkCommandBuffer = @splat(null),
    image_available: [max_frames_in_flight]vk.VkSemaphore = @splat(null),
    in_flight: [max_frames_in_flight]vk.VkFence = @splat(null),
    // One render-finished semaphore per swapchain image: a present may
    // still be reading the semaphore of an image while another frame
    // begins, so per-frame semaphores would alias.
    render_finished: []vk.VkSemaphore = &.{},

    current_frame: u32 = 0,
    image_index: u32 = 0,
    swapchain_stale: bool = false,

    pub fn init(
        allocator: std.mem.Allocator,
        source: SurfaceSource,
        fb_width: u32,
        fb_height: u32,
        app_name: [*:0]const u8,
    ) !*Context {
        const self = try allocator.create(Context);
        errdefer allocator.destroy(self);
        self.* = .{ .allocator = allocator };

        try self.createInstance(app_name);
        errdefer vk.vkDestroyInstance(self.instance, null);

        try self.createSurface(source);
        errdefer vk.vkDestroySurfaceKHR(self.instance, self.surface, null);

        try self.pickDevice();
        try self.createDevice();
        errdefer vk.vkDestroyDevice(self.device, null);

        try self.chooseSurfaceFormat();
        try self.createRenderPass();
        try self.createSwapchain(fb_width, fb_height);
        try self.createFrameState();

        return self;
    }

    pub fn deinit(self: *Context) void {
        _ = vk.vkDeviceWaitIdle(self.device);
        for (self.image_available) |sem| vk.vkDestroySemaphore(self.device, sem, null);
        for (self.in_flight) |fence| vk.vkDestroyFence(self.device, fence, null);
        vk.vkDestroyCommandPool(self.device, self.command_pool, null);
        self.destroySwapchain();
        vk.vkDestroyRenderPass(self.device, self.render_pass, null);
        vk.vkDestroyDevice(self.device, null);
        vk.vkDestroySurfaceKHR(self.instance, self.surface, null);
        vk.vkDestroyInstance(self.instance, null);
        self.allocator.destroy(self);
    }

    fn createInstance(self: *Context, app_name: [*:0]const u8) !void {
        const extensions = [_][*:0]const u8{ vk.VK_KHR_SURFACE_EXTENSION_NAME, vk.VK_KHR_WAYLAND_SURFACE_EXTENSION_NAME };

        const app_info = vk.VkApplicationInfo{
            .sType = vk.VK_STRUCTURE_TYPE_APPLICATION_INFO,
            .pApplicationName = app_name,
            .applicationVersion = vk.VK_MAKE_VERSION(0, 1, 0),
            .pEngineName = "weft",
            .engineVersion = vk.VK_MAKE_VERSION(0, 1, 0),
            // SPIR-V 1.3 (slangc -profile spirv_1_3) requires Vulkan 1.1.
            .apiVersion = vk.VK_API_VERSION_1_1,
        };
        const create_info = vk.VkInstanceCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
            .pApplicationInfo = &app_info,
            .enabledExtensionCount = extensions.len,
            .ppEnabledExtensionNames = @ptrCast(&extensions),
        };
        try check(vk.vkCreateInstance(&create_info, null, &self.instance));
    }

    fn createSurface(self: *Context, source: SurfaceSource) !void {
        const create_info = vk.VkWaylandSurfaceCreateInfoKHR{
            .sType = vk.VK_STRUCTURE_TYPE_WAYLAND_SURFACE_CREATE_INFO_KHR,
            .display = @ptrCast(source.display),
            .surface = @ptrCast(source.surface),
        };
        try check(vk.vkCreateWaylandSurfaceKHR(self.instance, &create_info, null, &self.surface));
    }

    fn pickDevice(self: *Context) !void {
        var count: u32 = 0;
        try check(vk.vkEnumeratePhysicalDevices(self.instance, &count, null));
        if (count == 0) return error.NoVulkanDevice;
        const devices = try self.allocator.alloc(vk.VkPhysicalDevice, count);
        defer self.allocator.free(devices);
        try check(vk.vkEnumeratePhysicalDevices(self.instance, &count, devices.ptr));

        // Prefer a dedicated GPU; treat software rasterizers (lavapipe/
        // llvmpipe) and CPU devices as last resort. A software device matches
        // either by VK_PHYSICAL_DEVICE_TYPE_CPU or by name, since Mesa reports
        // llvmpipe as a "CPU" type but lavapipe sometimes as other types.
        var best: ?vk.VkPhysicalDevice = null;
        var best_family: u32 = 0;
        var best_score: u32 = 0;
        for (devices[0..count]) |device| {
            const family = self.findQueueFamily(device) orelse continue;
            var props: vk.VkPhysicalDeviceProperties = undefined;
            vk.vkGetPhysicalDeviceProperties(device, &props);
            const name = std.mem.sliceTo(&props.deviceName, 0);
            const software = props.deviceType == vk.VK_PHYSICAL_DEVICE_TYPE_CPU or
                containsIgnoreCase(name, "llvmpipe") or containsIgnoreCase(name, "lavapipe") or
                containsIgnoreCase(name, "softpipe") or containsIgnoreCase(name, "swiftshader");
            // Real GPUs score above every software device (which floors at 1),
            // so a real GPU is always chosen when one is present.
            const score: u32 = if (software) 1 else switch (props.deviceType) {
                vk.VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU => 5,
                vk.VK_PHYSICAL_DEVICE_TYPE_INTEGRATED_GPU => 4,
                vk.VK_PHYSICAL_DEVICE_TYPE_VIRTUAL_GPU => 3,
                else => 2,
            };
            if (best == null or score > best_score) {
                best = device;
                best_family = family;
                best_score = score;
            }
        }
        self.physical_device = best orelse return error.NoSuitableDevice;
        self.queue_family = best_family;
        self.has_real_gpu = best_score >= 2; // >1 means not a software fallback
    }

    fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
        return std.ascii.indexOfIgnoreCase(haystack, needle) != null;
    }

    fn findQueueFamily(self: *Context, device: vk.VkPhysicalDevice) ?u32 {
        var count: u32 = 0;
        vk.vkGetPhysicalDeviceQueueFamilyProperties(device, &count, null);
        var families: [16]vk.VkQueueFamilyProperties = undefined;
        count = @min(count, families.len);
        vk.vkGetPhysicalDeviceQueueFamilyProperties(device, &count, &families);
        for (families[0..count], 0..) |family, index| {
            if ((family.queueFlags & vk.VK_QUEUE_GRAPHICS_BIT) == 0) continue;
            var present: vk.VkBool32 = vk.VK_FALSE;
            _ = vk.vkGetPhysicalDeviceSurfaceSupportKHR(device, @intCast(index), self.surface, &present);
            if (present == vk.VK_TRUE) return @intCast(index);
        }
        return null;
    }

    fn createDevice(self: *Context) !void {
        const priority: f32 = 1.0;
        const queue_info = vk.VkDeviceQueueCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
            .queueFamilyIndex = self.queue_family,
            .queueCount = 1,
            .pQueuePriorities = &priority,
        };
        const extensions = [_][*:0]const u8{vk.VK_KHR_SWAPCHAIN_EXTENSION_NAME};
        const create_info = vk.VkDeviceCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
            .queueCreateInfoCount = 1,
            .pQueueCreateInfos = &queue_info,
            .enabledExtensionCount = extensions.len,
            .ppEnabledExtensionNames = @ptrCast(&extensions),
        };
        try check(vk.vkCreateDevice(self.physical_device, &create_info, null, &self.device));
        vk.vkGetDeviceQueue(self.device, self.queue_family, 0, &self.queue);
    }

    fn chooseSurfaceFormat(self: *Context) !void {
        var count: u32 = 0;
        try check(vk.vkGetPhysicalDeviceSurfaceFormatsKHR(self.physical_device, self.surface, &count, null));
        const formats = try self.allocator.alloc(vk.VkSurfaceFormatKHR, count);
        defer self.allocator.free(formats);
        try check(vk.vkGetPhysicalDeviceSurfaceFormatsKHR(self.physical_device, self.surface, &count, formats.ptr));

        // Prefer an sRGB-encoded format: snail's stages output linear
        // premultiplied color and expect the attachment to encode.
        var chosen: ?vk.VkSurfaceFormatKHR = null;
        for (formats[0..count]) |format| {
            if (format.colorSpace != vk.VK_COLOR_SPACE_SRGB_NONLINEAR_KHR) continue;
            if (format.format == vk.VK_FORMAT_B8G8R8A8_SRGB or
                format.format == vk.VK_FORMAT_R8G8B8A8_SRGB)
            {
                chosen = format;
                break;
            }
        }
        if (chosen == null) {
            std.log.warn("no sRGB swapchain format; shader will encode sRGB", .{});
            chosen = formats[0];
        }
        self.surface_format = chosen.?;
    }

    /// True when the swapchain attachment hardware-encodes sRGB; if false
    /// the shader must encode (PushConstants.output_srgb = 1).
    pub fn surfaceEncodesSrgb(self: *const Context) bool {
        return self.surface_format.format == vk.VK_FORMAT_B8G8R8A8_SRGB or
            self.surface_format.format == vk.VK_FORMAT_R8G8B8A8_SRGB;
    }

    fn createRenderPass(self: *Context) !void {
        const attachment = vk.VkAttachmentDescription{
            .format = self.surface_format.format,
            .samples = vk.VK_SAMPLE_COUNT_1_BIT,
            .loadOp = vk.VK_ATTACHMENT_LOAD_OP_CLEAR,
            .storeOp = vk.VK_ATTACHMENT_STORE_OP_STORE,
            .stencilLoadOp = vk.VK_ATTACHMENT_LOAD_OP_DONT_CARE,
            .stencilStoreOp = vk.VK_ATTACHMENT_STORE_OP_DONT_CARE,
            .initialLayout = vk.VK_IMAGE_LAYOUT_UNDEFINED,
            .finalLayout = vk.VK_IMAGE_LAYOUT_PRESENT_SRC_KHR,
        };
        const color_ref = vk.VkAttachmentReference{
            .attachment = 0,
            .layout = vk.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
        };
        const subpass = vk.VkSubpassDescription{
            .pipelineBindPoint = vk.VK_PIPELINE_BIND_POINT_GRAPHICS,
            .colorAttachmentCount = 1,
            .pColorAttachments = &color_ref,
        };
        const dependency = vk.VkSubpassDependency{
            .srcSubpass = vk.VK_SUBPASS_EXTERNAL,
            .dstSubpass = 0,
            .srcStageMask = vk.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
            .srcAccessMask = 0,
            .dstStageMask = vk.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
            .dstAccessMask = vk.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
        };
        const create_info = vk.VkRenderPassCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO,
            .attachmentCount = 1,
            .pAttachments = &attachment,
            .subpassCount = 1,
            .pSubpasses = &subpass,
            .dependencyCount = 1,
            .pDependencies = &dependency,
        };
        try check(vk.vkCreateRenderPass(self.device, &create_info, null, &self.render_pass));
    }

    fn createSwapchain(self: *Context, fb_width: u32, fb_height: u32) !void {
        var caps: vk.VkSurfaceCapabilitiesKHR = undefined;
        try check(vk.vkGetPhysicalDeviceSurfaceCapabilitiesKHR(self.physical_device, self.surface, &caps));

        var extent = caps.currentExtent;
        if (extent.width == std.math.maxInt(u32)) {
            extent = .{
                .width = std.math.clamp(fb_width, caps.minImageExtent.width, caps.maxImageExtent.width),
                .height = std.math.clamp(fb_height, caps.minImageExtent.height, caps.maxImageExtent.height),
            };
        }
        if (extent.width == 0 or extent.height == 0) return error.ZeroExtent;

        var image_count: u32 = caps.minImageCount + 1;
        if (caps.maxImageCount > 0) image_count = @min(image_count, caps.maxImageCount);

        const create_info = vk.VkSwapchainCreateInfoKHR{
            .sType = vk.VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR,
            .surface = self.surface,
            .minImageCount = image_count,
            .imageFormat = self.surface_format.format,
            .imageColorSpace = self.surface_format.colorSpace,
            .imageExtent = extent,
            .imageArrayLayers = 1,
            // Skia rasterizes into its own surface and copies the result into
            // the swapchain image, so it needs TRANSFER_DST. snail draws
            // straight into it as a color attachment (unchanged).
            .imageUsage = vk.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT |
                (if (build_options.renderer == .skia) vk.VK_IMAGE_USAGE_TRANSFER_DST_BIT else 0),
            .imageSharingMode = vk.VK_SHARING_MODE_EXCLUSIVE,
            .preTransform = caps.currentTransform,
            .compositeAlpha = vk.VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR,
            .presentMode = vk.VK_PRESENT_MODE_FIFO_KHR,
            .clipped = vk.VK_TRUE,
        };
        try check(vk.vkCreateSwapchainKHR(self.device, &create_info, null, &self.swapchain));
        self.extent = extent;

        var actual: u32 = 0;
        try check(vk.vkGetSwapchainImagesKHR(self.device, self.swapchain, &actual, null));
        self.images = try self.allocator.alloc(vk.VkImage, actual);
        try check(vk.vkGetSwapchainImagesKHR(self.device, self.swapchain, &actual, self.images.ptr));

        self.views = try self.allocator.alloc(vk.VkImageView, actual);
        self.framebuffers = try self.allocator.alloc(vk.VkFramebuffer, actual);
        self.render_finished = try self.allocator.alloc(vk.VkSemaphore, actual);
        for (self.images, self.views, self.framebuffers, self.render_finished) |image, *view, *framebuffer, *sem| {
            const view_info = vk.VkImageViewCreateInfo{
                .sType = vk.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
                .image = image,
                .viewType = vk.VK_IMAGE_VIEW_TYPE_2D,
                .format = self.surface_format.format,
                .subresourceRange = .{
                    .aspectMask = vk.VK_IMAGE_ASPECT_COLOR_BIT,
                    .baseMipLevel = 0,
                    .levelCount = 1,
                    .baseArrayLayer = 0,
                    .layerCount = 1,
                },
            };
            try check(vk.vkCreateImageView(self.device, &view_info, null, view));

            const fb_info = vk.VkFramebufferCreateInfo{
                .sType = vk.VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO,
                .renderPass = self.render_pass,
                .attachmentCount = 1,
                .pAttachments = view,
                .width = extent.width,
                .height = extent.height,
                .layers = 1,
            };
            try check(vk.vkCreateFramebuffer(self.device, &fb_info, null, framebuffer));

            const sem_info = vk.VkSemaphoreCreateInfo{
                .sType = vk.VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO,
            };
            try check(vk.vkCreateSemaphore(self.device, &sem_info, null, sem));
        }
    }

    fn destroySwapchain(self: *Context) void {
        for (self.render_finished) |sem| vk.vkDestroySemaphore(self.device, sem, null);
        for (self.framebuffers) |framebuffer| vk.vkDestroyFramebuffer(self.device, framebuffer, null);
        for (self.views) |view| vk.vkDestroyImageView(self.device, view, null);
        self.allocator.free(self.render_finished);
        self.allocator.free(self.framebuffers);
        self.allocator.free(self.views);
        self.allocator.free(self.images);
        self.render_finished = &.{};
        self.framebuffers = &.{};
        self.views = &.{};
        self.images = &.{};
        vk.vkDestroySwapchainKHR(self.device, self.swapchain, null);
        self.swapchain = null;
    }

    pub fn recreateSwapchain(self: *Context, fb_width: u32, fb_height: u32) !void {
        try check(vk.vkDeviceWaitIdle(self.device));
        self.destroySwapchain();
        try self.createSwapchain(fb_width, fb_height);
        self.swapchain_stale = false;
    }

    fn createFrameState(self: *Context) !void {
        const pool_info = vk.VkCommandPoolCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
            .flags = vk.VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT,
            .queueFamilyIndex = self.queue_family,
        };
        try check(vk.vkCreateCommandPool(self.device, &pool_info, null, &self.command_pool));

        const alloc_info = vk.VkCommandBufferAllocateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
            .commandPool = self.command_pool,
            .level = vk.VK_COMMAND_BUFFER_LEVEL_PRIMARY,
            .commandBufferCount = max_frames_in_flight,
        };
        try check(vk.vkAllocateCommandBuffers(self.device, &alloc_info, &self.command_buffers));

        for (&self.image_available, &self.in_flight) |*sem, *fence| {
            const sem_info = vk.VkSemaphoreCreateInfo{
                .sType = vk.VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO,
            };
            try check(vk.vkCreateSemaphore(self.device, &sem_info, null, sem));
            const fence_info = vk.VkFenceCreateInfo{
                .sType = vk.VK_STRUCTURE_TYPE_FENCE_CREATE_INFO,
                .flags = vk.VK_FENCE_CREATE_SIGNALED_BIT,
            };
            try check(vk.vkCreateFence(self.device, &fence_info, null, fence));
        }
    }

    /// Wait for the frame slot, acquire an image, and begin recording.
    /// The render pass is NOT begun yet — record transfer work (texture
    /// uploads) first, then call `beginRenderPass`. Returns null when the
    /// swapchain needs recreation, OR when the previous frame's GPU work
    /// hasn't finished yet (north-star-plan §6 W2a-3 / §2.7: "the kernel
    /// must never block on a GPU fence") — the FENCE is polled with a ZERO
    /// timeout, never awaited, so THAT wait can never stall the scheduler
    /// thread. A caller that gets `null` for this reason should retry on
    /// the scheduler's next wake (see `app/loop_sources.zig`'s
    /// present-retry source): in the common case (idle, then one edit) the
    /// fence is already signaled and this returns a command buffer on the
    /// first try, so no latency is added to the input→present path; only a
    /// GPU that's still busy from the prior frame defers, exactly as FIFO
    /// present would have made the caller wait anyway.
    ///
    /// Scope note (review): the non-blocking guarantee covers the FENCE
    /// only. `vkAcquireNextImageKHR` below still passes an effectively
    /// unbounded timeout and, under FIFO, can genuinely block for up to
    /// ~1 vblank waiting for a presentable image to cycle back — a small,
    /// display-refresh-bounded wait, not the open-ended GPU-workload wait
    /// the fence change eliminates. Making the acquire non-blocking too
    /// would need a present-time image pool (`VK_KHR_present_wait` or a
    /// deeper swapchain queue) — out of scope here; the fence was the
    /// unbounded one (worst case: seconds, if the GPU is behind on other
    /// work), the acquire is bounded by the display's own refresh cadence.
    pub fn beginFrame(self: *Context) !?vk.VkCommandBuffer {
        const frame = self.current_frame;
        const wait = vk.vkWaitForFences(self.device, 1, &self.in_flight[frame], vk.VK_TRUE, 0);
        if (wait == vk.VK_TIMEOUT) return null;
        try check(wait);

        var image_index: u32 = 0;
        const acquire = vk.vkAcquireNextImageKHR(
            self.device,
            self.swapchain,
            std.math.maxInt(u64),
            self.image_available[frame],
            null,
            &image_index,
        );
        switch (acquire) {
            vk.VK_ERROR_OUT_OF_DATE_KHR => {
                self.swapchain_stale = true;
                return null;
            },
            vk.VK_SUCCESS, vk.VK_SUBOPTIMAL_KHR => {},
            else => return error.VulkanFailed,
        }
        self.image_index = image_index;

        try check(vk.vkResetFences(self.device, 1, &self.in_flight[frame]));
        const cmd = self.command_buffers[frame];
        try check(vk.vkResetCommandBuffer(cmd, 0));
        const begin_info = vk.VkCommandBufferBeginInfo{
            .sType = vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
            .flags = vk.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
        };
        try check(vk.vkBeginCommandBuffer(cmd, &begin_info));
        return cmd;
    }

    pub fn beginRenderPass(self: *Context, cmd: vk.VkCommandBuffer, clear_linear: [4]f32) void {
        const clear = vk.VkClearValue{ .color = .{ .float32 = clear_linear } };
        const pass_info = vk.VkRenderPassBeginInfo{
            .sType = vk.VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO,
            .renderPass = self.render_pass,
            .framebuffer = self.framebuffers[self.image_index],
            .renderArea = .{ .offset = .{ .x = 0, .y = 0 }, .extent = self.extent },
            .clearValueCount = 1,
            .pClearValues = &clear,
        };
        vk.vkCmdBeginRenderPass(cmd, &pass_info, vk.VK_SUBPASS_CONTENTS_INLINE);
    }

    pub fn endFrame(self: *Context) !void {
        const cmd = self.command_buffers[self.current_frame];
        vk.vkCmdEndRenderPass(cmd);
        try self.submitPresent(cmd);
    }

    /// Finish, submit and present a frame's command buffer WITHOUT ending a
    /// render pass — the path a renderer that records raw transfer/blit work
    /// (Skia copies its rasterized surface into the swapchain image) uses in
    /// place of `endFrame`. Waits on `image_available`, signals the image's
    /// `render_finished`, and advances the frame index exactly like `endFrame`.
    pub fn submitPresent(self: *Context, cmd: vk.VkCommandBuffer) !void {
        const frame = self.current_frame;
        try check(vk.vkEndCommandBuffer(cmd));

        const wait_stage: vk.VkPipelineStageFlags = vk.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
        const submit_info = vk.VkSubmitInfo{
            .sType = vk.VK_STRUCTURE_TYPE_SUBMIT_INFO,
            .waitSemaphoreCount = 1,
            .pWaitSemaphores = &self.image_available[frame],
            .pWaitDstStageMask = &wait_stage,
            .commandBufferCount = 1,
            .pCommandBuffers = &cmd,
            .signalSemaphoreCount = 1,
            .pSignalSemaphores = &self.render_finished[self.image_index],
        };
        try check(vk.vkQueueSubmit(self.queue, 1, &submit_info, self.in_flight[frame]));

        const present_info = vk.VkPresentInfoKHR{
            .sType = vk.VK_STRUCTURE_TYPE_PRESENT_INFO_KHR,
            .waitSemaphoreCount = 1,
            .pWaitSemaphores = &self.render_finished[self.image_index],
            .swapchainCount = 1,
            .pSwapchains = &self.swapchain,
            .pImageIndices = &self.image_index,
        };
        const present = vk.vkQueuePresentKHR(self.queue, &present_info);
        switch (present) {
            vk.VK_ERROR_OUT_OF_DATE_KHR, vk.VK_SUBOPTIMAL_KHR => self.swapchain_stale = true,
            vk.VK_SUCCESS => {},
            else => return error.VulkanFailed,
        }
        self.current_frame = (self.current_frame + 1) % max_frames_in_flight;
    }

    pub fn waitIdle(self: *Context) void {
        _ = vk.vkDeviceWaitIdle(self.device);
    }

    pub fn findMemoryType(self: *const Context, type_bits: u32, properties: vk.VkMemoryPropertyFlags) !u32 {
        var mem_props: vk.VkPhysicalDeviceMemoryProperties = undefined;
        vk.vkGetPhysicalDeviceMemoryProperties(self.physical_device, &mem_props);
        var index: u32 = 0;
        while (index < mem_props.memoryTypeCount) : (index += 1) {
            const type_ok = (type_bits & (@as(u32, 1) << @intCast(index))) != 0;
            const props_ok = (mem_props.memoryTypes[index].propertyFlags & properties) == properties;
            if (type_ok and props_ok) return index;
        }
        return error.NoSuitableMemoryType;
    }
};
