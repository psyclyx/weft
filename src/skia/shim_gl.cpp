// Ganesh on OpenGL: a GrDirectContext over whichever GL context is current on
// the calling thread (EGL on Linux, NSOpenGLContext on macOS — the caller made
// it, the caller keeps it current). Every entry point is resolved through the
// caller's `get_proc`, so this file links no GL library of its own. Frames are
// drawn straight into the caller's framebuffer (`begin_framebuffer`/`flush`),
// or into shim.cpp's internal surface for a headless read back.

#include "shim.h"
#include "shim_state.h"

#include "core/SkColorSpace.h"
#include "core/SkSurfaceProps.h"
#include "gpu/ganesh/GrBackendSurface.h"
#include "gpu/ganesh/GrTypes.h"
#include "gpu/ganesh/SkSurfaceGanesh.h"
#include "gpu/ganesh/gl/GrGLAssembleInterface.h"
#include "gpu/ganesh/gl/GrGLBackendSurface.h"
#include "gpu/ganesh/gl/GrGLDirectContext.h"
#include "gpu/ganesh/gl/GrGLInterface.h"
#include "gpu/ganesh/gl/GrGLTypes.h"

// GL_RGBA8: the sized internal format of every framebuffer weft asks for.
static constexpr GrGLenum kGlRgba8 = 0x8058;

extern "C" WeftSkia* weft_skia_create_gl(WeftSkiaGlGetProc get_proc, void* ctx) {
    if (!get_proc) return nullptr;
    // Desktop GL or GLES, whichever the context reports: Skia reads
    // GL_VERSION through the same proc and assembles the matching interface.
    sk_sp<const GrGLInterface> gl =
        GrGLMakeAssembledInterface(ctx, reinterpret_cast<GrGLGetProc>(get_proc));
    if (!gl) return nullptr;
    sk_sp<GrDirectContext> gr = GrDirectContexts::MakeGL(std::move(gl));
    if (!gr) return nullptr;
    // RGBA: GL framebuffers and read backs are RGBA-ordered.
    WeftSkia* s = weftSkiaNew(0);
    if (!s) return nullptr;
    s->gr = std::move(gr);
    s->gpu = true;
    return s;
}

extern "C" int weft_skia_begin_framebuffer(WeftSkia* s, uint32_t fbo, uint32_t width,
                                           uint32_t height, uint32_t stencil_bits) {
    if (!s || !s->gpu || width == 0 || height == 0) return 1;
    // Re-wrapped every frame: the caller's framebuffer can change size (or,
    // for a window, identity) between frames, and wrapping is cheap — it
    // allocates nothing on the GPU.
    GrGLFramebufferInfo info{};
    info.fFBOID = fbo;
    info.fFormat = kGlRgba8;
    const GrBackendRenderTarget target = GrBackendRenderTargets::MakeGL(
        static_cast<int>(width), static_cast<int>(height), /*sampleCnt=*/0,
        static_cast<int>(stencil_bits), info);
    // GL's framebuffer origin is bottom-left; Skia flips for us. The null
    // color space matches the internal surface: straight sRGB bytes out.
    s->surface = SkSurfaces::WrapBackendRenderTarget(s->gr.get(), target,
                                                     kBottomLeft_GrSurfaceOrigin,
                                                     kRGBA_8888_SkColorType, nullptr, nullptr);
    s->width = width;
    s->height = height;
    s->wrapped = true;
    return weftSkiaStartFrame(s);
}
