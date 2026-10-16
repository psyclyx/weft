// SVG through Skia's SVG module (modules/svg): a document parsed by SkSVGDOM
// and drawn on a CPU raster canvas. Linked into every build, whichever GPU
// backend: it touches no GPU and no renderer state.

#include "shim.h"

#include "include/core/SkCanvas.h"
#include "include/core/SkImageInfo.h"
#include "include/core/SkSize.h"
#include "include/core/SkStream.h"
#include "modules/skshaper/include/SkShaper_factory.h"
#include "modules/svg/include/SkSVGDOM.h"

extern "C" int weft_skia_svg_render(const uint8_t* svg, size_t len, uint32_t width,
                                    uint32_t height, uint8_t* rgba, size_t row_bytes) {
    if (!svg || !rgba || width == 0 || height == 0) return 1;
    SkMemoryStream stream(svg, len, /*copyData=*/false);
    // No font manager: an SVG's <text> draws nothing (shim.h says so).
    // The primitive shaper is the one this Skia is built with.
    const sk_sp<SkSVGDOM> dom =
        SkSVGDOM::Builder().setTextShapingFactory(SkShapers::Primitive::Factory()).make(stream);
    if (!dom) return 1;
    dom->setContainerSize(SkSize::Make(width, height));
    const SkImageInfo info =
        SkImageInfo::Make(width, height, kRGBA_8888_SkColorType, kPremul_SkAlphaType);
    const std::unique_ptr<SkCanvas> canvas = SkCanvas::MakeRasterDirect(info, rgba, row_bytes);
    if (!canvas) return 1;
    canvas->clear(SK_ColorTRANSPARENT);
    dom->render(canvas.get());
    return 0;
}
