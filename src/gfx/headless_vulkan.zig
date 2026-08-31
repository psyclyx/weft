//! Standard headless Vulkan target: device + offscreen color image + readback.
//!
//! There is deliberately no surface, swapchain, WSI extension, compositor, or
//! platform input here. The target acquires an offscreen image, submits Skia's
//! transfer commands, and exposes only the completed RGBA frame.

const std = @import("std");
const vk = @import("weft_vk").c;
const readback_mod = @import("vulkan_readback.zig");

pub const Context = struct {
    allocator: std.mem.Allocator,
    instance: vk.VkInstance = null,
    physical_device: vk.VkPhysicalDevice = null,
    device: vk.VkDevice = null,
    queue: vk.VkQueue = null,
    queue_family: u32 = 0,
    has_real_gpu: bool = false,

    format: vk.VkFormat = vk.VK_FORMAT_UNDEFINED,
    extent: vk.VkExtent2D,
    images: [1]vk.VkImage = .{null},
    image_memory: vk.VkDeviceMemory = null,

    command_pool: vk.VkCommandPool = null,
    command_buffers: [1]vk.VkCommandBuffer = .{null},
    in_flight: [1]vk.VkFence = .{null},
    image_index: u32 = 0,
    submitted: bool = false,
    readback: ?readback_mod.Buffer = null,

    pub fn init(allocator: std.mem.Allocator, width: u32, height: u32, app_name: [*:0]const u8) !*Context {
        if (width == 0 or height == 0) return error.ZeroExtent;
        const self = try allocator.create(Context);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .extent = .{ .width = width, .height = height },
        };
        errdefer self.deinitResources();

        try self.createInstance(app_name);
        try self.pickDevice();
        try self.createDevice();
        try self.chooseFormat();
        try self.createImage();
        try self.createFrameState();
        const pixels = try std.math.mul(usize, width, height);
        const byte_len = try std.math.mul(usize, pixels, 4);
        self.readback = try readback_mod.Buffer.init(self.physical_device, self.device, byte_len);
        return self;
    }

    pub fn deinit(self: *Context) void {
        self.deinitResources();
        self.allocator.destroy(self);
    }

    fn deinitResources(self: *Context) void {
        if (self.device != null) _ = vk.vkDeviceWaitIdle(self.device);
        if (self.readback) |*buffer| buffer.deinit();
        self.readback = null;
        if (self.device != null) {
            if (self.in_flight[0] != null) vk.vkDestroyFence(self.device, self.in_flight[0], null);
            if (self.command_pool != null) vk.vkDestroyCommandPool(self.device, self.command_pool, null);
            if (self.images[0] != null) vk.vkDestroyImage(self.device, self.images[0], null);
            if (self.image_memory != null) vk.vkFreeMemory(self.device, self.image_memory, null);
            vk.vkDestroyDevice(self.device, null);
        }
        if (self.instance != null) vk.vkDestroyInstance(self.instance, null);
    }

    fn createInstance(self: *Context, app_name: [*:0]const u8) !void {
        const app = vk.VkApplicationInfo{
            .sType = vk.VK_STRUCTURE_TYPE_APPLICATION_INFO,
            .pApplicationName = app_name,
            .applicationVersion = vk.VK_MAKE_VERSION(0, 1, 0),
            .pEngineName = "weft-headless",
            .engineVersion = vk.VK_MAKE_VERSION(0, 1, 0),
            .apiVersion = vk.VK_API_VERSION_1_1,
        };
        const info = vk.VkInstanceCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
            .pApplicationInfo = &app,
            .enabledExtensionCount = 0,
            .ppEnabledExtensionNames = null,
        };
        try check(vk.vkCreateInstance(&info, null, &self.instance));
    }

    fn pickDevice(self: *Context) !void {
        var count: u32 = 0;
        try check(vk.vkEnumeratePhysicalDevices(self.instance, &count, null));
        if (count == 0) return error.NoVulkanDevice;
        const devices = try self.allocator.alloc(vk.VkPhysicalDevice, count);
        defer self.allocator.free(devices);
        try check(vk.vkEnumeratePhysicalDevices(self.instance, &count, devices.ptr));
        var best_score: u32 = 0;
        for (devices[0..count]) |device| {
            const family = graphicsQueueFamily(device) orelse continue;
            var properties: vk.VkPhysicalDeviceProperties = undefined;
            vk.vkGetPhysicalDeviceProperties(device, &properties);
            const software = properties.deviceType == vk.VK_PHYSICAL_DEVICE_TYPE_CPU;
            const score: u32 = if (software) 1 else switch (properties.deviceType) {
                vk.VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU => 5,
                vk.VK_PHYSICAL_DEVICE_TYPE_INTEGRATED_GPU => 4,
                vk.VK_PHYSICAL_DEVICE_TYPE_VIRTUAL_GPU => 3,
                else => 2,
            };
            if (self.physical_device == null or score > best_score) {
                self.physical_device = device;
                self.queue_family = family;
                self.has_real_gpu = !software;
                best_score = score;
            }
        }
        if (self.physical_device == null) return error.NoSuitableDevice;
    }

    fn createDevice(self: *Context) !void {
        const priority: f32 = 1;
        const queue_info = vk.VkDeviceQueueCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
            .queueFamilyIndex = self.queue_family,
            .queueCount = 1,
            .pQueuePriorities = &priority,
        };
        const info = vk.VkDeviceCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
            .queueCreateInfoCount = 1,
            .pQueueCreateInfos = &queue_info,
            .enabledExtensionCount = 0,
            .ppEnabledExtensionNames = null,
        };
        try check(vk.vkCreateDevice(self.physical_device, &info, null, &self.device));
        vk.vkGetDeviceQueue(self.device, self.queue_family, 0, &self.queue);
    }

    fn chooseFormat(self: *Context) !void {
        const candidates = [_]vk.VkFormat{
            vk.VK_FORMAT_R8G8B8A8_SRGB,
            vk.VK_FORMAT_B8G8R8A8_SRGB,
            vk.VK_FORMAT_R8G8B8A8_UNORM,
            vk.VK_FORMAT_B8G8R8A8_UNORM,
        };
        const need = vk.VK_FORMAT_FEATURE_TRANSFER_SRC_BIT |
            vk.VK_FORMAT_FEATURE_TRANSFER_DST_BIT;
        for (candidates) |format| {
            var properties: vk.VkFormatProperties = undefined;
            vk.vkGetPhysicalDeviceFormatProperties(self.physical_device, format, &properties);
            if ((properties.optimalTilingFeatures & need) == need) {
                self.format = format;
                return;
            }
        }
        return error.NoCaptureFormat;
    }

    fn createImage(self: *Context) !void {
        const image_info = vk.VkImageCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
            .imageType = vk.VK_IMAGE_TYPE_2D,
            .format = self.format,
            .extent = .{ .width = self.extent.width, .height = self.extent.height, .depth = 1 },
            .mipLevels = 1,
            .arrayLayers = 1,
            .samples = vk.VK_SAMPLE_COUNT_1_BIT,
            .tiling = vk.VK_IMAGE_TILING_OPTIMAL,
            .usage = vk.VK_IMAGE_USAGE_TRANSFER_SRC_BIT | vk.VK_IMAGE_USAGE_TRANSFER_DST_BIT,
            .sharingMode = vk.VK_SHARING_MODE_EXCLUSIVE,
            .initialLayout = vk.VK_IMAGE_LAYOUT_UNDEFINED,
        };
        try check(vk.vkCreateImage(self.device, &image_info, null, &self.images[0]));
        var requirements: vk.VkMemoryRequirements = undefined;
        vk.vkGetImageMemoryRequirements(self.device, self.images[0], &requirements);
        const allocation = vk.VkMemoryAllocateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
            .allocationSize = requirements.size,
            .memoryTypeIndex = try self.findMemoryType(requirements.memoryTypeBits, vk.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT),
        };
        try check(vk.vkAllocateMemory(self.device, &allocation, null, &self.image_memory));
        try check(vk.vkBindImageMemory(self.device, self.images[0], self.image_memory, 0));
    }

    fn createFrameState(self: *Context) !void {
        const pool_info = vk.VkCommandPoolCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
            .flags = vk.VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT,
            .queueFamilyIndex = self.queue_family,
        };
        try check(vk.vkCreateCommandPool(self.device, &pool_info, null, &self.command_pool));
        const command_info = vk.VkCommandBufferAllocateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
            .commandPool = self.command_pool,
            .level = vk.VK_COMMAND_BUFFER_LEVEL_PRIMARY,
            .commandBufferCount = 1,
        };
        try check(vk.vkAllocateCommandBuffers(self.device, &command_info, &self.command_buffers));
        const fence_info = vk.VkFenceCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_FENCE_CREATE_INFO,
            .flags = vk.VK_FENCE_CREATE_SIGNALED_BIT,
        };
        try check(vk.vkCreateFence(self.device, &fence_info, null, &self.in_flight[0]));
    }

    pub fn beginFrame(self: *Context) !?vk.VkCommandBuffer {
        if (self.submitted) return null;
        const fence = self.in_flight[0];
        const ready = vk.vkWaitForFences(self.device, 1, &fence, vk.VK_TRUE, 0);
        if (ready == vk.VK_TIMEOUT) return null;
        try check(ready);
        try check(vk.vkResetFences(self.device, 1, &fence));
        const cmd = self.command_buffers[0];
        try check(vk.vkResetCommandBuffer(cmd, 0));
        const begin = vk.VkCommandBufferBeginInfo{
            .sType = vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
            .flags = vk.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
        };
        try check(vk.vkBeginCommandBuffer(cmd, &begin));
        return cmd;
    }

    /// Finish the final image-to-buffer copy and submit it. Nothing is
    /// presented: the completed offscreen image is the frame product.
    pub fn submitFrame(self: *Context, cmd: vk.VkCommandBuffer) !void {
        // The renderer has already transitioned the target to TRANSFER_SRC
        // with transfer-read visibility before handing the command buffer
        // back. The target only appends its terminal image-to-buffer copy.
        self.readback.?.recordCopy(cmd, self.images[0], self.extent.width, self.extent.height);
        try check(vk.vkEndCommandBuffer(cmd));
        const submit = vk.VkSubmitInfo{
            .sType = vk.VK_STRUCTURE_TYPE_SUBMIT_INFO,
            .commandBufferCount = 1,
            .pCommandBuffers = &cmd,
        };
        try check(vk.vkQueueSubmit(self.queue, 1, &submit, self.in_flight[0]));
        self.submitted = true;
    }

    pub fn readFrame(self: *Context, gpa: std.mem.Allocator) ![]u8 {
        if (!self.submitted) return error.FrameNotSubmitted;
        const fence = self.in_flight[0];
        try check(vk.vkWaitForFences(self.device, 1, &fence, vk.VK_TRUE, std.math.maxInt(u64)));
        const pixels = try self.readback.?.readRgba(gpa, isBgra(self.format));
        self.submitted = false;
        return pixels;
    }

    pub fn colorFormat(self: *const Context) vk.VkFormat {
        return self.format;
    }

    pub fn vulkanExtensions(_: *const Context) struct {
        instance: []const [*:0]const u8,
        device: []const [*:0]const u8,
    } {
        return .{ .instance = &.{}, .device = &.{} };
    }

    pub fn targetFinalLayout(_: *const Context) vk.VkImageLayout {
        return vk.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL;
    }

    pub fn waitIdle(self: *Context) void {
        _ = vk.vkDeviceWaitIdle(self.device);
    }

    pub fn findMemoryType(self: *const Context, bits: u32, properties: vk.VkMemoryPropertyFlags) !u32 {
        var memory: vk.VkPhysicalDeviceMemoryProperties = undefined;
        vk.vkGetPhysicalDeviceMemoryProperties(self.physical_device, &memory);
        var index: u32 = 0;
        while (index < memory.memoryTypeCount) : (index += 1) {
            const supported = (bits & (@as(u32, 1) << @intCast(index))) != 0;
            const flags = memory.memoryTypes[index].propertyFlags;
            if (supported and (flags & properties) == properties) return index;
        }
        return error.NoSuitableMemoryType;
    }
};

fn graphicsQueueFamily(device: vk.VkPhysicalDevice) ?u32 {
    var count: u32 = 0;
    vk.vkGetPhysicalDeviceQueueFamilyProperties(device, &count, null);
    var families: [32]vk.VkQueueFamilyProperties = undefined;
    count = @min(count, families.len);
    vk.vkGetPhysicalDeviceQueueFamilyProperties(device, &count, &families);
    for (families[0..count], 0..) |family, index| {
        if ((family.queueFlags & vk.VK_QUEUE_GRAPHICS_BIT) != 0) return @intCast(index);
    }
    return null;
}

fn isBgra(format: vk.VkFormat) bool {
    return format == vk.VK_FORMAT_B8G8R8A8_SRGB or format == vk.VK_FORMAT_B8G8R8A8_UNORM;
}

fn check(result: vk.VkResult) !void {
    if (result != vk.VK_SUCCESS) return error.VulkanFailed;
}
