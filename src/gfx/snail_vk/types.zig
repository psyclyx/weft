//! Shared Vulkan types for the snail render path. `vk` re-uses weft's
//! single program-wide @cImport (separate cImports of the same header
//! produce distinct opaque types).

pub const vk = @import("../../vk.zig").c;

/// Plain handle bundle the copied snail reference renderer consumes. It
/// owns no resources; weft's gfx.Context retains every referenced
/// object and all synchronization responsibility.
pub const VulkanContext = struct {
    physical_device: vk.VkPhysicalDevice,
    device: vk.VkDevice,
    graphics_queue: vk.VkQueue,
    queue_family_index: u32,
    render_pass: vk.VkRenderPass,
    supports_dual_source_blend: bool = false,
};
