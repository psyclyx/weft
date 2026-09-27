// Skia C++ shim behind the C ABI in shim.h. Compiled with g++ (see build.zig
// addSkia) and linked into the Zig exe. Renders the editor's per-pane content
// (filled rects + positioned glyphs + stroked paths, and for chrome rounded
// rects and clips — all decoded on the Zig side) onto
// an SkCanvas, then reads the pixels back for the Vulkan backend to copy into
// its target image. Backends: Ganesh Vulkan (sharing weft's VkDevice) or,
// when there is no real GPU / WEFT_SKIA_CPU is set, the CPU raster path.

#include "shim.h"

#include <algorithm>
#include <unordered_map>
#include <vector>

#include "core/SkCanvas.h"
#include "core/SkColor.h"
#include "core/SkColorSpace.h"
#include "core/SkData.h"
#include "core/SkFont.h"
#include "core/SkFontMgr.h"
#include "core/SkFontTypes.h"
#include "core/SkImageInfo.h"
#include "core/SkBlurTypes.h"
#include "core/SkMaskFilter.h"
#include "core/SkPaint.h"
#include "core/SkPathBuilder.h"
#include "core/SkRRect.h"
#include "core/SkSurface.h"
#include "core/SkTypeface.h"
#include "ports/SkFontMgr_empty.h"

#include "gpu/GpuTypes.h"
#include "gpu/ganesh/GrDirectContext.h"
#include "gpu/ganesh/GrTypes.h"
#include "gpu/ganesh/SkSurfaceGanesh.h"
#include "gpu/ganesh/vk/GrVkDirectContext.h"
#include "gpu/vk/VulkanBackendContext.h"
#include "gpu/vk/VulkanExtensions.h"
#include "third_party/vulkan/vulkan/vulkan_core.h"

static_assert(sizeof(WeftSkiaPathCommand) == 28);
static_assert(sizeof(WeftSkiaPathStyle) == 40);
static_assert(sizeof(WeftSkiaRRect) == 44);

struct WeftSkia {
    bool gpu = false;
    SkColorType color_type = kBGRA_8888_SkColorType;

    sk_sp<GrDirectContext> gr;          // GPU only
    sk_sp<SkFontMgr> font_mgr;
    std::unordered_map<uint32_t, sk_sp<SkTypeface>> faces;

    // Frame target.
    uint32_t width = 0, height = 0;
    std::vector<uint8_t> pixels;        // width*height*4, the readback buffer
    sk_sp<SkSurface> surface;
    SkCanvas* canvas = nullptr;
    // A clip in force (one save() deep); `weft_skia_clip` replaces it.
    bool clipped = false;

    // Glyph run accumulator. The view emits glyphs in reading order, so a text
    // row is a long stretch sharing one (face, size, color) — drawing them one
    // at a time rebuilt an SkFont and SkPaint per glyph and gave Skia no run to
    // batch. We coalesce the stretch and flush it when any of those three
    // change, or when a rect/clear/end has to observe the accumulated output.
    // Flushing on rect is what preserves z-order: the view's item sequence is
    // the paint order, so a pending run must land before a rect drawn after it.
    std::vector<SkGlyphID> run_gids;
    std::vector<SkPoint> run_pos;
    uint32_t run_font_id = 0;
    float run_size = 0;
    SkColor4f run_color{0, 0, 0, 0};
};

static void weftFlushGlyphs(WeftSkia* s) {
    if (!s || !s->canvas || s->run_gids.empty()) return;

    auto it = s->faces.find(s->run_font_id);
    if (it != s->faces.end()) {
        SkFont font(it->second, s->run_size);
        font.setEdging(SkFont::Edging::kAntiAlias);
        font.setSubpixel(true);
        font.setHinting(SkFontHinting::kNone);  // positions come from HarfBuzz

        SkPaint paint;
        paint.setColor4f(s->run_color, nullptr);
        paint.setAntiAlias(true);

        // Positions are absolute, so the origin stays at zero — identical
        // geometry to the per-glyph path, which passed the position as the
        // origin and the point as (0,0).
        s->canvas->drawGlyphs(SkSpan<const SkGlyphID>(s->run_gids.data(), s->run_gids.size()),
                              SkSpan<const SkPoint>(s->run_pos.data(), s->run_pos.size()),
                              SkPoint::Make(0, 0), font, paint);
    }
    s->run_gids.clear();
    s->run_pos.clear();
}

static SkImageInfo frameInfo(const WeftSkia* s) {
    // Legacy (null) color space: the Zig side hands us straight sRGB colors, so
    // no color management is wanted — bytes go out exactly as drawn, matching
    // the _SRGB swapchain format the copy targets.
    return SkImageInfo::Make(s->width, s->height, s->color_type,
                             kPremul_SkAlphaType, nullptr);
}

extern "C" WeftSkia* weft_skia_create(const WeftSkiaVulkan* vk, int want_gpu, int bgra) {
    WeftSkia* s = new (std::nothrow) WeftSkia();
    if (!s) return nullptr;
    s->color_type = bgra ? kBGRA_8888_SkColorType : kRGBA_8888_SkColorType;
    s->font_mgr = SkFontMgr_New_Custom_Empty();

    if (want_gpu && vk && vk->get_instance_proc_addr) {
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

        s->gr = GrDirectContexts::MakeVulkan(bc);
        s->gpu = (s->gr != nullptr);
    }
    return s;
}

extern "C" void weft_skia_destroy(WeftSkia* s) {
    if (!s) return;
    s->canvas = nullptr;
    s->surface.reset();
    s->gr.reset();
    delete s;
}

extern "C" int weft_skia_is_gpu(const WeftSkia* s) { return s && s->gpu ? 1 : 0; }

extern "C" void weft_skia_register_font(WeftSkia* s, uint32_t font_id,
                                        const uint8_t* bytes, size_t len) {
    if (!s || !bytes || !len) return;
    sk_sp<SkData> data = SkData::MakeWithCopy(bytes, len);
    sk_sp<SkTypeface> tf = s->font_mgr->makeFromData(std::move(data));
    if (tf) s->faces[font_id] = std::move(tf);
}

extern "C" int weft_skia_begin(WeftSkia* s, uint32_t width, uint32_t height) {
    if (!s || width == 0 || height == 0) return 1;
    if (width != s->width || height != s->height || !s->surface) {
        s->width = width;
        s->height = height;
        s->pixels.assign(static_cast<size_t>(width) * height * 4, 0);
        if (s->gpu) {
            s->surface = SkSurfaces::RenderTarget(s->gr.get(), skgpu::Budgeted::kYes, frameInfo(s));
            if (!s->surface) {  // GPU surface alloc failed — drop to raster for good.
                s->gpu = false;
            }
        }
        if (!s->gpu) {
            s->surface = SkSurfaces::WrapPixels(frameInfo(s), s->pixels.data(),
                                                static_cast<size_t>(width) * 4);
        }
        if (!s->surface) return 1;
    }
    s->canvas = s->surface->getCanvas();
    s->clipped = false;
    // A frame always ends with a flush, so this is belt-and-braces: never carry
    // a partial run across a frame boundary or a surface recreation.
    s->run_gids.clear();
    s->run_pos.clear();
    return s->canvas ? 0 : 1;
}

extern "C" void weft_skia_clear(WeftSkia* s, float r, float g, float b, float a) {
    if (!s || !s->canvas) return;
    weftFlushGlyphs(s);
    s->canvas->clear(SkColor4f{r, g, b, a}.toSkColor());
}

extern "C" void weft_skia_draw_rect(WeftSkia* s, float x, float y, float w, float h,
                                    float r, float g, float b, float a) {
    if (!s || !s->canvas) return;
    weftFlushGlyphs(s);  // z-order: a pending run was emitted before this rect
    SkPaint paint;
    paint.setColor4f(SkColor4f{r, g, b, a}, nullptr);
    paint.setAntiAlias(false);  // crisp cell-aligned selection/caret rects
    s->canvas->drawRect(SkRect::MakeXYWH(x, y, w, h), paint);
}

extern "C" void weft_skia_draw_glyph(WeftSkia* s, uint32_t font_id, uint32_t glyph_id,
                                     float x, float y, float size,
                                     float r, float g, float b, float a) {
    if (!s || !s->canvas) return;

    const SkColor4f color{r, g, b, a};
    const bool same_run = !s->run_gids.empty() && s->run_font_id == font_id &&
                          s->run_size == size && s->run_color == color;
    if (!same_run) {
        weftFlushGlyphs(s);
        s->run_font_id = font_id;
        s->run_size = size;
        s->run_color = color;
    }
    s->run_gids.push_back(static_cast<SkGlyphID>(glyph_id));
    s->run_pos.push_back(SkPoint::Make(x, y));
}

extern "C" void weft_skia_draw_path(WeftSkia* s, const WeftSkiaPathCommand* commands,
                                      size_t command_count, const WeftSkiaPathStyle* style) {
    if (!s || !s->canvas || !commands || !style) return;
    weftFlushGlyphs(s);
    const auto px = [style](float value) { return style->x + value * style->scale; };
    const auto py = [style](float value) { return style->y + value * style->scale; };
    SkPathBuilder path;
    for (size_t i = 0; i < command_count; ++i) {
        const WeftSkiaPathCommand& command = commands[i];
        switch (command.verb) {
            case 0: path.moveTo(px(command.points[0]), py(command.points[1])); break;
            case 1: path.lineTo(px(command.points[0]), py(command.points[1])); break;
            case 2:
                path.cubicTo(px(command.points[0]), py(command.points[1]),
                             px(command.points[2]), py(command.points[3]),
                             px(command.points[4]), py(command.points[5]));
                break;
            case 3: path.close(); break;
            default: return;
        }
    }
    SkPaint paint;
    paint.setColor4f(SkColor4f{style->r, style->g, style->b, style->a}, nullptr);
    paint.setStyle(SkPaint::kStroke_Style);
    paint.setStrokeWidth(style->stroke_width * style->scale);
    paint.setStrokeCap(style->cap == 1 ? SkPaint::kRound_Cap :
                       style->cap == 2 ? SkPaint::kSquare_Cap : SkPaint::kButt_Cap);
    paint.setStrokeJoin(style->join == 1 ? SkPaint::kRound_Join :
                        style->join == 2 ? SkPaint::kBevel_Join : SkPaint::kMiter_Join);
    paint.setAntiAlias(true);
    s->canvas->drawPath(path.detach(), paint);
}

extern "C" void weft_skia_draw_rrect(WeftSkia* s, const WeftSkiaRRect* rr) {
    if (!s || !s->canvas || !rr || rr->w <= 0 || rr->h <= 0) return;
    weftFlushGlyphs(s);  // z-order, as for a rect
    const float radius = std::max(0.0f, std::min(rr->radius, std::min(rr->w, rr->h) / 2));
    SkPaint paint;
    paint.setColor4f(SkColor4f{rr->r, rr->g, rr->b, rr->a}, nullptr);
    paint.setAntiAlias(true);  // a curve needs coverage; a flat rect stays crisp
    if (rr->stroke_width > 0) {
        paint.setStyle(SkPaint::kStroke_Style);
        paint.setStrokeWidth(rr->stroke_width);
    }
    if (rr->blur > 0) paint.setMaskFilter(SkMaskFilter::MakeBlur(kNormal_SkBlurStyle, rr->blur));
    s->canvas->drawRRect(SkRRect::MakeRectXY(SkRect::MakeXYWH(rr->x, rr->y, rr->w, rr->h), radius, radius), paint);
}

extern "C" void weft_skia_clip(WeftSkia* s, int on, float x, float y, float w, float h) {
    if (!s || !s->canvas) return;
    weftFlushGlyphs(s);  // a pending run was emitted under the old clip
    if (s->clipped) {
        s->canvas->restore();
        s->clipped = false;
    }
    if (!on) return;
    s->canvas->save();
    s->canvas->clipRect(SkRect::MakeXYWH(x, y, w, h), false);
    s->clipped = true;
}

extern "C" const uint8_t* weft_skia_end(WeftSkia* s, size_t* row_bytes) {
    if (!s || !s->surface) return nullptr;
    weftFlushGlyphs(s);
    if (s->clipped && s->canvas) {
        s->canvas->restore();
        s->clipped = false;
    }
    const size_t rb = static_cast<size_t>(s->width) * 4;
    if (row_bytes) *row_bytes = rb;

    if (s->gpu) {
        s->gr->flushAndSubmit(s->surface.get(), GrSyncCpu::kYes);
        if (!s->surface->readPixels(frameInfo(s), s->pixels.data(), rb, 0, 0))
            return nullptr;
    }
    // Raster path drew straight into s->pixels via WrapPixels — nothing to do.
    s->canvas = nullptr;
    return s->pixels.data();
}
