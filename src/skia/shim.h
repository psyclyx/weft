// C ABI membrane between Zig and Skia (C++). Only C scalar/pointer types
// cross here; the Zig side (skia/root.zig) declares these `extern "C"`.
// The renderer draws editor content — explicit text glyphs and filled rects
// decoded on the Zig side — onto an SkCanvas.
//
// One drawing surface, three ways to back it, each a separate translation
// unit so a build links only the GPU API it targets:
//   - shim.cpp         the canvas, the frame, and the CPU raster backend;
//   - shim_vulkan.cpp  Ganesh on weft's VkDevice (GrDirectContexts::MakeVulkan);
//   - shim_gl.cpp      Ganesh on the caller's current OpenGL context.
// Two kinds of frame target, same draw calls: an internal surface the caller
// reads back (`begin`/`end` — the Vulkan copy and every headless capture), or
// the caller's own OpenGL framebuffer drawn in place (`begin_framebuffer`/
// `flush` — a GL window, no readback).

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

// Resolves one OpenGL entry point by name in the caller's current context
// (eglGetProcAddress, CGL's dlsym, ...). `ctx` is passed back verbatim.
typedef void (*(*WeftSkiaGlGetProc)(void* ctx, const char* name))(void);

// Create a renderer. Each returns NULL when its backend cannot be brought up;
// the caller decides what to fall back to. `bgra` picks the byte order of a
// read-back frame (1 => BGRA8888 to match VK_FORMAT_B8G8R8A8, 0 => RGBA8888).
WeftSkia* weft_skia_create_raster(int bgra);
WeftSkia* weft_skia_create_vulkan(const WeftSkiaVulkan* vk, int bgra);
// The GL context must be current on the calling thread, here and for every
// later call on the returned renderer.
WeftSkia* weft_skia_create_gl(WeftSkiaGlGetProc get_proc, void* ctx);
void weft_skia_destroy(WeftSkia*);

// 1 when running on a Ganesh GPU backend, 0 on the CPU raster backend.
int weft_skia_is_gpu(const WeftSkia*);

// Register a typeface for `font_id` (bytes copied). Call once per face.
void weft_skia_register_font(WeftSkia*, uint32_t font_id, const uint8_t* bytes, size_t len);

// Begin a frame on an internal `width`x`height` surface (allocated/resized as
// needed), finished by `weft_skia_end`. Returns 0 on success. Colors below are
// straight sRGB in [0,1] (the Zig side converts the scene's linear theme
// colors to sRGB before calling).
int weft_skia_begin(WeftSkia*, uint32_t width, uint32_t height);
// Begin a frame drawn straight into OpenGL framebuffer `fbo` (0 is a window's
// default framebuffer) of `width`x`height`, RGBA8 with `stencil_bits` of
// stencil, finished by `weft_skia_flush`. GL renderers only. Returns 0 on
// success.
int weft_skia_begin_framebuffer(WeftSkia*, uint32_t fbo, uint32_t width, uint32_t height,
                                uint32_t stencil_bits);
void weft_skia_clear(WeftSkia*, float r, float g, float b, float a);
void weft_skia_draw_rect(WeftSkia*, float x, float y, float w, float h,
                         float r, float g, float b, float a);
// One glyph by index (the HarfBuzz glyph id for the same face),
// baseline origin (x,y), pixel size, straight sRGB color.
void weft_skia_draw_glyph(WeftSkia*, uint32_t font_id, uint32_t glyph_id,
                          float x, float y, float size,
                          float r, float g, float b, float a);
typedef struct {
    uint32_t verb;  // 0 move, 1 line, 2 cubic, 3 close
    float points[6];
} WeftSkiaPathCommand;
typedef struct {
    float x, y, scale, stroke_width;
    float r, g, b, a;
    uint32_t cap;   // 0 butt, 1 round, 2 square
    uint32_t join;  // 0 miter, 1 round, 2 bevel
} WeftSkiaPathStyle;
void weft_skia_draw_path(WeftSkia*, const WeftSkiaPathCommand*, size_t command_count,
                         const WeftSkiaPathStyle*);
// A rounded rect (core chrome only): uniform corner radius, filled when
// stroke_width is 0 and outlined otherwise; blur > 0 softens the edge by a
// Gaussian of that sigma (a drop shadow).
typedef struct {
    float x, y, w, h, radius;
    float r, g, b, a;
    float stroke_width, blur;
} WeftSkiaRRect;
void weft_skia_draw_rrect(WeftSkia*, const WeftSkiaRRect*);
// Replace the clip for what follows: on=1 clips to the rect, on=0 lifts it.
// Clips do not nest; end() lifts one left in place.
void weft_skia_clip(WeftSkia*, int on, float x, float y, float w, float h);

// Flush + read back a `weft_skia_begin` frame. Returns a pointer to
// `height`*`*row_bytes` bytes (the pixel format chosen at create), valid until
// the next begin/destroy, or NULL on failure.
const uint8_t* weft_skia_end(WeftSkia*, size_t* row_bytes);
// Flush and submit a `weft_skia_begin_framebuffer` frame to the GL context;
// the caller presents it (swaps buffers). Returns 0 on success.
int weft_skia_flush(WeftSkia*);

#ifdef __cplusplus
}
#endif

#endif  // WEFT_SKIA_SHIM_H
