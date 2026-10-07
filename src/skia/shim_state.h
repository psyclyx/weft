// The renderer's state, shared by the translation units behind shim.h:
// shim.cpp draws on it, and each backend file (shim_vulkan.cpp, shim_gl.cpp)
// creates one with its GrDirectContext. C++ only; nothing here crosses to Zig.

#ifndef WEFT_SKIA_SHIM_STATE_H
#define WEFT_SKIA_SHIM_STATE_H

#include <cstdint>
#include <unordered_map>
#include <vector>

#include "core/SkCanvas.h"
#include "core/SkColor.h"
#include "core/SkFontMgr.h"
#include "core/SkFontTypes.h"
#include "core/SkSurface.h"
#include "core/SkTypeface.h"
#include "gpu/ganesh/GrDirectContext.h"

struct WeftSkia {
    bool gpu = false;
    SkColorType color_type = kBGRA_8888_SkColorType;

    sk_sp<GrDirectContext> gr;          // GPU only
    sk_sp<SkFontMgr> font_mgr;
    std::unordered_map<uint32_t, sk_sp<SkTypeface>> faces;

    // Frame target. `surface` is either internal (`weft_skia_begin`: sized
    // `width`x`height`, read back into `pixels` by `weft_skia_end`) or a
    // wrapped caller framebuffer (`weft_skia_begin_framebuffer`, which
    // re-wraps every frame and is finished by `weft_skia_flush`). `wrapped`
    // says which, so an internal begin after a wrapped frame reallocates.
    uint32_t width = 0, height = 0;
    std::vector<uint8_t> pixels;        // width*height*4, the readback buffer
    sk_sp<SkSurface> surface;
    bool wrapped = false;
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

// A renderer with no backend yet: the font manager and output byte order set,
// `gr` empty. Each create function starts here. NULL on allocation failure.
WeftSkia* weftSkiaNew(int bgra);

// Make `surface` the frame's target and start drawing on it: the common tail
// of both begin calls. Returns 0 on success.
int weftSkiaStartFrame(WeftSkia* s);

#endif  // WEFT_SKIA_SHIM_STATE_H
