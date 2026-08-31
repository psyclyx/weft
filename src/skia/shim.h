// C ABI membrane between Zig and Skia (C++). Only C scalar/pointer types
// cross here; the Zig side (skia/root.zig) declares these `extern "C"`.
// The renderer draws editor content — explicit text glyphs and filled rects
// decoded on the Zig side — onto an
// SkCanvas, then hands back the rasterized pixels for the Vulkan backend to
// copy into its target image. Two backing paths, same draw calls: Ganesh
// (GrDirectContexts::MakeVulkan, sharing weft's VkDevice) or SkSurfaces raster.

#ifndef WEFT_SKIA_SHIM_H
#define WEFT_SKIA_SHIM_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct WeftSkia WeftSkia;

// The shared Vulkan handles for the Ganesh backend (opaque here; the real
// Vulkan handle types live on the Zig side). `get_instance_proc_addr` is
// PFN_vkGetInstanceProcAddr, from which Skia loads every other proc.
typedef struct {
    void* instance;                // VkInstance
    void* physical_device;         // VkPhysicalDevice
    void* device;                  // VkDevice
    void* queue;                   // VkQueue (graphics)
    uint32_t queue_family;
    void* get_instance_proc_addr;  // PFN_vkGetInstanceProcAddr
    uint32_t api_version;          // e.g. VK_API_VERSION_1_1
    const char* const* instance_extensions;
    uint32_t instance_extension_count;
    const char* const* device_extensions;
    uint32_t device_extension_count;
} WeftSkiaVulkan;

// Create the renderer. `want_gpu` selects the Ganesh Vulkan backend; if 0 (or
// Ganesh init fails) it falls back to the CPU raster backend. `bgra` picks the
// output byte order (1 => BGRA8888 to match VK_FORMAT_B8G8R8A8, 0 => RGBA8888).
// Returns NULL only on hard failure. `vk` may be NULL when `want_gpu` is 0.
WeftSkia* weft_skia_create(const WeftSkiaVulkan* vk, int want_gpu, int bgra);
void weft_skia_destroy(WeftSkia*);

// 1 when running on the Ganesh GPU backend, 0 on the CPU raster fallback.
int weft_skia_is_gpu(const WeftSkia*);

// Register a typeface for `font_id` (bytes copied). Call once per face.
void weft_skia_register_font(WeftSkia*, uint32_t font_id, const uint8_t* bytes, size_t len);

// Begin a frame at `width`x`height` (allocates/resizes the target). Returns 0
// on success. Colors below are straight sRGB in [0,1] (the Zig side converts
// the scene's linear theme colors to sRGB before calling).
int weft_skia_begin(WeftSkia*, uint32_t width, uint32_t height);
void weft_skia_clear(WeftSkia*, float r, float g, float b, float a);
void weft_skia_draw_rect(WeftSkia*, float x, float y, float w, float h,
                         float r, float g, float b, float a);
// One glyph by index (the HarfBuzz glyph id for the same face),
// baseline origin (x,y), pixel size, straight sRGB color.
void weft_skia_draw_glyph(WeftSkia*, uint32_t font_id, uint32_t glyph_id,
                          float x, float y, float size,
                          float r, float g, float b, float a);

// Flush + read back the frame. Returns a pointer to `height`*`*row_bytes` bytes
// (the pixel format chosen at create), valid until the next begin/destroy, or
// NULL on failure.
const uint8_t* weft_skia_end(WeftSkia*, size_t* row_bytes);

#ifdef __cplusplus
}
#endif

#endif  // WEFT_SKIA_SHIM_H
