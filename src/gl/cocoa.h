// C ABI for OpenGL on macOS (gl/cocoa.m), wrapped by gl/cocoa.zig: an
// NSOpenGLContext presenting to a window's content view, and a CGL context
// with no drawable. Main thread only, like the window it draws into.

#ifndef WEFT_GL_COCOA_H
#define WEFT_GL_COCOA_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct WeftGlView WeftGlView;
typedef struct WeftGlOffscreen WeftGlOffscreen;

// A double-buffered GL 3.2+ core context drawing into `view` (an NSView *) at
// its full backing resolution, never waiting for vertical sync, and current
// on return. `stencil_bits` receives the default framebuffer's stencil depth.
// NULL when no pixel format or context can be had.
WeftGlView* weft_gl_view_create(void* view, uint32_t* stencil_bits);
void weft_gl_view_destroy(WeftGlView*);
void weft_gl_view_make_current(WeftGlView*);
// The view changed size or moved between displays: re-fit the drawable.
void weft_gl_view_update(WeftGlView*);
void weft_gl_view_swap(WeftGlView*);

// A GL 3.2+ core context with no drawable, current on return. NULL on failure.
WeftGlOffscreen* weft_gl_offscreen_create(void);
void weft_gl_offscreen_destroy(WeftGlOffscreen*);
void weft_gl_offscreen_make_current(WeftGlOffscreen*);

// One GL entry point by name (Skia's GrGLGetProc shape; `ctx` unused).
void (*weft_gl_get_proc(void* ctx, const char* name))(void);

#ifdef __cplusplus
}
#endif

#endif  // WEFT_GL_COCOA_H
