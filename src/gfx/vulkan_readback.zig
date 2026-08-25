//! Host-visible terminal sink for a Vulkan RGBA8 image.
//!
//! This module has no editor, scene, window, or presentation knowledge. The
//! owning target records one whole-image copy after rendering and waits its
//! own submission fence before asking this buffer for normalized RGBA bytes.

const std = @import("std");
const vk = @import("../vk.zig").c;

pub const Buffer = struct {
    device: vk.VkDevice,
    buffer: vk.VkBuffer,
    memory: vk.VkDeviceMemory,
    mapped: [*]u8,
    coherent: bool,
    byte_len: usize,

    pub fn init(physical_device: vk.VkPhysicalDevice, device: vk.VkDevice, byte_len: usize) !Buffer {
        var self: Buffer = .{
            .device = device,
            .buffer = null,
            .memory = null,
            .mapped = undefined,
            .coherent = false,
            .byte_len = byte_len,
        };
        errdefer self.deinit();

        const info = vk.VkBufferCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
            .size = byte_len,
            .usage = vk.VK_BUFFER_USAGE_TRANSFER_DST_BIT,
            .sharingMode = vk.VK_SHARING_MODE_EXCLUSIVE,
        };
        try check(vk.vkCreateBuffer(device, &info, null, &self.buffer));
        var requirements: vk.VkMemoryRequirements = undefined;
        vk.vkGetBufferMemoryRequirements(device, self.buffer, &requirements);
        const memory_type = try hostVisibleMemoryType(physical_device, requirements.memoryTypeBits);
        const allocation = vk.VkMemoryAllocateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
            .allocationSize = requirements.size,
            .memoryTypeIndex = memory_type.index,
        };
        try check(vk.vkAllocateMemory(device, &allocation, null, &self.memory));
        try check(vk.vkBindBufferMemory(device, self.buffer, self.memory, 0));
        var mapped: ?*anyopaque = null;
        try check(vk.vkMapMemory(device, self.memory, 0, vk.VK_WHOLE_SIZE, 0, &mapped));
        self.mapped = @ptrCast(mapped.?);
        self.coherent = memory_type.coherent;
        return self;
    }

    pub fn deinit(self: *Buffer) void {
        if (self.memory != null) {
            vk.vkUnmapMemory(self.device, self.memory);
            vk.vkFreeMemory(self.device, self.memory, null);
        }
        if (self.buffer != null) vk.vkDestroyBuffer(self.device, self.buffer, null);
        self.buffer = null;
        self.memory = null;
    }

    pub fn recordCopy(self: *const Buffer, cmd: vk.VkCommandBuffer, image: vk.VkImage, width: u32, height: u32) void {
        const region = vk.VkBufferImageCopy{
            .bufferOffset = 0,
            .bufferRowLength = 0,
            .bufferImageHeight = 0,
            .imageSubresource = .{
                .aspectMask = vk.VK_IMAGE_ASPECT_COLOR_BIT,
                .mipLevel = 0,
                .baseArrayLayer = 0,
                .layerCount = 1,
            },
            .imageOffset = .{ .x = 0, .y = 0, .z = 0 },
            .imageExtent = .{ .width = width, .height = height, .depth = 1 },
        };
        vk.vkCmdCopyImageToBuffer(cmd, image, vk.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, self.buffer, 1, &region);
    }

    pub fn readRgba(self: *const Buffer, gpa: std.mem.Allocator, bgra: bool) ![]u8 {
        if (!self.coherent) {
            const range = vk.VkMappedMemoryRange{
                .sType = vk.VK_STRUCTURE_TYPE_MAPPED_MEMORY_RANGE,
                .memory = self.memory,
                .offset = 0,
                .size = vk.VK_WHOLE_SIZE,
            };
            try check(vk.vkInvalidateMappedMemoryRanges(self.device, 1, &range));
        }
        const pixels = try gpa.alloc(u8, self.byte_len);
        if (!bgra) {
            @memcpy(pixels, self.mapped[0..self.byte_len]);
            return pixels;
        }
        var i: usize = 0;
        while (i < self.byte_len) : (i += 4) {
            pixels[i] = self.mapped[i + 2];
            pixels[i + 1] = self.mapped[i + 1];
            pixels[i + 2] = self.mapped[i];
            pixels[i + 3] = self.mapped[i + 3];
        }
        return pixels;
    }
};

const MemoryType = struct { index: u32, coherent: bool };

fn hostVisibleMemoryType(physical_device: vk.VkPhysicalDevice, bits: u32) !MemoryType {
    var props: vk.VkPhysicalDeviceMemoryProperties = undefined;
    vk.vkGetPhysicalDeviceMemoryProperties(physical_device, &props);
    var fallback: ?MemoryType = null;
    var index: u32 = 0;
    while (index < props.memoryTypeCount) : (index += 1) {
        if ((bits & (@as(u32, 1) << @intCast(index))) == 0) continue;
        const flags = props.memoryTypes[index].propertyFlags;
        if ((flags & vk.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT) == 0) continue;
        const coherent = (flags & vk.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT) != 0;
        if (coherent) return .{ .index = index, .coherent = true };
        if (fallback == null) fallback = .{ .index = index, .coherent = false };
    }
    return fallback orelse error.NoHostVisibleMemory;
}

fn check(result: vk.VkResult) !void {
    if (result != vk.VK_SUCCESS) return error.VulkanFailed;
}
