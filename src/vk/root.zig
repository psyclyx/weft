//! Single Vulkan C import for the whole program. Every module must use
//! these types: separate @cImport blocks of the same header produce
//! distinct opaque Zig types.

pub const c = @cImport({
    @cDefine("VK_USE_PLATFORM_WAYLAND_KHR", "1");
    @cInclude("vulkan/vulkan.h");
});
