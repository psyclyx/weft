// Ganesh on Vulkan: a GrDirectContext sharing weft's VkDevice. Frames go
// through shim.cpp's internal surface and are read back for the Vulkan target
// to copy into its image. Linked only into builds that target Vulkan.

#include "shim.h"
#include "shim_state.h"

#include "gpu/ganesh/vk/GrVkDirectContext.h"
#include "gpu/vk/VulkanBackendContext.h"
#include "gpu/vk/VulkanExtensions.h"
#include "third_party/vulkan/vulkan/vulkan_core.h"

extern "C" WeftSkia* weft_skia_create_vulkan(const WeftSkiaVulkan* vk, int bgra) {
    if (!vk || !vk->get_instance_proc_addr) return nullptr;
    auto gipa = reinterpret_cast<PFN_vkGetInstanceProcAddr>(vk->get_instance_proc_addr);
    auto instance = reinterpret_cast<VkInstance>(vk->instance);
    auto gdpa = reinterpret_cast<PFN_vkGetDeviceProcAddr>(
        gipa(instance, "vkGetDeviceProcAddr"));

    skgpu::VulkanGetProc getProc =
        [gipa, gdpa](const char* name, VkInstance inst, VkDevice dev) -> PFN_vkVoidFunction {
            if (dev != VK_NULL_HANDLE && gdpa) return gdpa(dev, name);
            return gipa(inst, name);
        };

    // Advertise exactly the extensions enabled by this Vulkan target.
    // The offscreen target supplies empty lists; a desktop target supplies
    // its WSI extensions. Skia must never infer platform capabilities.
    skgpu::VulkanExtensions ext;
    ext.init(getProc, instance, reinterpret_cast<VkPhysicalDevice>(vk->physical_device),
             vk->instance_extension_count, vk->instance_extensions,
             vk->device_extension_count, vk->device_extensions);

    skgpu::VulkanBackendContext bc{};
    bc.fInstance = instance;
    bc.fPhysicalDevice = reinterpret_cast<VkPhysicalDevice>(vk->physical_device);
    bc.fDevice = reinterpret_cast<VkDevice>(vk->device);
    bc.fQueue = reinterpret_cast<VkQueue>(vk->queue);
    bc.fGraphicsQueueIndex = vk->queue_family;
    bc.fMaxAPIVersion = vk->api_version;
    bc.fVkExtensions = &ext;
    bc.fGetProc = getProc;

    sk_sp<GrDirectContext> gr = GrDirectContexts::MakeVulkan(bc);
    if (!gr) return nullptr;
    WeftSkia* s = weftSkiaNew(bgra);
    if (!s) return nullptr;
    s->gr = std::move(gr);
    s->gpu = true;
    return s;
}
