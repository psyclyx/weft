//! Vulkan bootstrap: instance, surface, device, swapchain, per-frame command
//! buffers, and synchronization. Platform-neutral; the caller hands in the
//! native window handles. Skia owns rasterization; this target only acquires,
//! copies, submits, and presents swapchain images.

const std = @import("std");
const vkmod = @import("../vk.zig");
const vk = vkmod.c;
const swapchain_state = @import("swapchain_state.zig");

pub const max_frames_in_flight = 2;

const instance_extensions = [_][*:0]const u8{
    vk.VK_KHR_SURFACE_EXTENSION_NAME,
    vk.VK_KHR_WAYLAND_SURFACE_EXTENSION_NAME,
};
const device_extensions = [_][*:0]const u8{vk.VK_KHR_SWAPCHAIN_EXTENSION_NAME};

// W-later: platform-specific WSI shape (vkCreateWaylandSurfaceKHR has no
// backend-neutral form) — see platform.zig's leak #1 for the seam note; the
// right shape (a tagged union per platform) waits on a second platform.
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

const SwapchainResources = struct {
    swapchain: vk.VkSwapchainKHR = null,
    extent: vk.VkExtent2D = .{ .width = 0, .height = 0 },
    images: []vk.VkImage = &.{},
    render_finished: []vk.VkSemaphore = &.{},
};

pub const Context = struct {
    allocator: std.mem.Allocator,

    instance: vk.VkInstance = null,
    surface: vk.VkSurfaceKHR = null,
    physical_device: vk.VkPhysicalDevice = null,
    device: vk.VkDevice = null,
    queue: vk.VkQueue = null,
    queue_family: u32 = 0,
    /// Whether `pickDevice` found a real (non-software, non-CPU) GPU. The Skia
    /// backend consults this to choose Ganesh (GPU) vs its CPU raster path.
    /// False means only lavapipe/llvmpipe/CPU was available.
    has_real_gpu: bool = false,

    surface_format: vk.VkSurfaceFormatKHR = undefined,
    swapchain: vk.VkSwapchainKHR = null,
    extent: vk.VkExtent2D = .{ .width = 0, .height = 0 },
    images: []vk.VkImage = &.{},

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
        vk.vkDestroyDevice(self.device, null);
        vk.vkDestroySurfaceKHR(self.instance, self.surface, null);
        vk.vkDestroyInstance(self.instance, null);
        self.allocator.destroy(self);
    }

    fn createInstance(self: *Context, app_name: [*:0]const u8) !void {
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
            .enabledExtensionCount = instance_extensions.len,
            .ppEnabledExtensionNames = @ptrCast(&instance_extensions),
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
        const create_info = vk.VkDeviceCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
            .queueCreateInfoCount = 1,
            .pQueueCreateInfos = &queue_info,
            .enabledExtensionCount = device_extensions.len,
            .ppEnabledExtensionNames = @ptrCast(&device_extensions),
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

        // Prefer an sRGB-encoded format so the target attachment performs the
        // final color encoding for Skia's linear output.
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
    pub fn colorFormat(self: *const Context) vk.VkFormat {
        return self.surface_format.format;
    }

    pub fn vulkanExtensions(_: *const Context) struct {
        instance: []const [*:0]const u8,
        device: []const [*:0]const u8,
    } {
        return .{ .instance = &instance_extensions, .device = &device_extensions };
    }

    /// Layout required by this target after a renderer has populated the full
    /// color image. The WSI target presents; the standard headless target uses
    /// TRANSFER_SRC and implements the same structural renderer surface.
    pub fn targetFinalLayout(_: *const Context) vk.VkImageLayout {
        return vk.VK_IMAGE_LAYOUT_PRESENT_SRC_KHR;
    }

    fn buildSwapchain(self: *Context, fb_width: u32, fb_height: u32, old_swapchain: vk.VkSwapchainKHR) !SwapchainResources {
        var resources: SwapchainResources = .{};
        errdefer self.destroySwapchainResources(&resources);

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
            // the swapchain image.
            .imageUsage = vk.VK_IMAGE_USAGE_TRANSFER_DST_BIT,
            .imageSharingMode = vk.VK_SHARING_MODE_EXCLUSIVE,
            .preTransform = caps.currentTransform,
            .compositeAlpha = vk.VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR,
            .presentMode = vk.VK_PRESENT_MODE_FIFO_KHR,
            .clipped = vk.VK_TRUE,
            .oldSwapchain = old_swapchain,
        };
        try check(vk.vkCreateSwapchainKHR(self.device, &create_info, null, &resources.swapchain));
        resources.extent = extent;

        var actual: u32 = 0;
        try check(vk.vkGetSwapchainImagesKHR(self.device, resources.swapchain, &actual, null));
        resources.images = try self.allocator.alloc(vk.VkImage, actual);
        try check(vk.vkGetSwapchainImagesKHR(self.device, resources.swapchain, &actual, resources.images.ptr));

        resources.render_finished = try self.allocator.alloc(vk.VkSemaphore, actual);
        for (resources.render_finished) |*sem| {
            sem.* = null;
            const sem_info = vk.VkSemaphoreCreateInfo{
                .sType = vk.VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO,
            };
            try check(vk.vkCreateSemaphore(self.device, &sem_info, null, sem));
        }
        return resources;
    }

    fn destroySwapchainResources(self: *Context, resources: *SwapchainResources) void {
        for (resources.render_finished) |sem| if (sem != null) vk.vkDestroySemaphore(self.device, sem, null);
        self.allocator.free(resources.render_finished);
        self.allocator.free(resources.images);
        if (resources.swapchain != null) vk.vkDestroySwapchainKHR(self.device, resources.swapchain, null);
        resources.* = .{};
    }

    fn installSwapchain(self: *Context, resources: *SwapchainResources) void {
        self.swapchain = resources.swapchain;
        self.extent = resources.extent;
        self.images = resources.images;
        self.render_finished = resources.render_finished;
        resources.* = .{};
    }

    fn createSwapchain(self: *Context, fb_width: u32, fb_height: u32) !void {
        var resources = try self.buildSwapchain(fb_width, fb_height, null);
        self.installSwapchain(&resources);
    }

    fn destroySwapchain(self: *Context) void {
        var resources: SwapchainResources = .{
            .swapchain = self.swapchain,
            .extent = self.extent,
            .images = self.images,
            .render_finished = self.render_finished,
        };
        self.swapchain = null;
        self.images = &.{};
        self.render_finished = &.{};
        self.destroySwapchainResources(&resources);
        self.extent = .{ .width = 0, .height = 0 };
    }

    /// Drop a swapchain after a recreation path has made the old handle
    /// unusable. The queue wait is best-effort here: on a device-loss/error
    /// path no future acquire is permitted, and an explicit null handle is
    /// safer than retaining a retired chain.
    fn abandonSwapchain(self: *Context) void {
        _ = vk.vkQueueWaitIdle(self.queue);
        self.destroySwapchain();
        self.swapchain_stale = true;
    }

    pub fn recreateSwapchain(self: *Context, fb_width: u32, fb_height: u32) !void {
        // Defensively handle a zero surface extent without attempting to
        // create a non-presentable swapchain; another platform may still
        // report a usable extent on a later resize.
        if (fb_width == 0 or fb_height == 0) {
            if (vk.vkQueueWaitIdle(self.queue) != vk.VK_SUCCESS) {
                self.abandonSwapchain();
                return error.VulkanFailed;
            }
            self.destroySwapchain();
            _ = swapchain_state.recreated(&self.swapchain_stale, fb_width, fb_height);
            return error.ZeroExtent;
        }

        // Keep the old handle/resources alive while creating its successor,
        // as required by VK_KHR_swapchain's oldSwapchain contract. Queue-idle
        // is the narrowly-scoped retirement barrier: it proves old images and
        // present semaphores are no longer in use
        // without vkDeviceWaitIdle on every configure.
        const old_swapchain = self.swapchain;
        var next = self.buildSwapchain(fb_width, fb_height, old_swapchain) catch |err| {
            if (old_swapchain != null) {
                // Once vkCreateSwapchainKHR accepted oldSwapchain, the old
                // chain is retired even if later resource setup fails.  Do
                // not leave that handle installed: retire the queue and put
                // Context in an explicit stale/no-swapchain state.
                self.abandonSwapchain();
            }
            return err;
        };
        errdefer self.destroySwapchainResources(&next);
        if (vk.vkQueueWaitIdle(self.queue) != vk.VK_SUCCESS) {
            self.abandonSwapchain();
            return error.VulkanFailed;
        }
        self.destroySwapchain();
        self.installSwapchain(&next);
        std.debug.assert(swapchain_state.recreated(&self.swapchain_stale, fb_width, fb_height));
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

    /// Wait for the frame slot, acquire an image, and begin recording transfer
    /// work. Returns null when the
    /// swapchain needs recreation, OR when the previous frame's GPU work
    /// hasn't finished yet (doc/contextual-workspace-architecture.md §7: "the kernel
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
        // The platform loop normally rebuilds before reaching this method.
        // Keep the boundary defensive: an out-of-date acquire or a zero-size
        // configure must never turn into an acquire on a retired/null chain.
        if (self.swapchain_stale or self.swapchain == null) return null;
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
                _ = swapchain_state.acquired(&self.swapchain_stale, .out_of_date);
                return null;
            },
            vk.VK_SUCCESS => {},
            vk.VK_SUBOPTIMAL_KHR => {
                _ = swapchain_state.acquired(&self.swapchain_stale, .suboptimal);
            },
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

    /// Finish, submit, and present a frame's transfer command buffer. Waits
    /// on `image_available`, signals the image's `render_finished`, and
    /// advances the frame index.
    pub fn submitFrame(self: *Context, cmd: vk.VkCommandBuffer) !void {
        const frame = self.current_frame;
        try check(vk.vkEndCommandBuffer(cmd));

        const wait_stage: vk.VkPipelineStageFlags = vk.VK_PIPELINE_STAGE_TRANSFER_BIT;
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
            vk.VK_ERROR_OUT_OF_DATE_KHR => {
                _ = swapchain_state.presented(&self.swapchain_stale, .out_of_date);
            },
            vk.VK_SUBOPTIMAL_KHR => {
                _ = swapchain_state.presented(&self.swapchain_stale, .suboptimal);
            },
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
