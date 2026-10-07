// OpenGL on macOS behind gl/cocoa.h. A window context is an NSOpenGLContext
// attached to the window's content view — Apple's supported (if deprecated
// since 10.14) way to present GL in a view; an offscreen one is a bare CGL
// context. Both are desktop GL core profile: macOS has nothing else, and the
// Linux build asks EGL for the same so its tests run the GL path a Mac runs.

#import <Cocoa/Cocoa.h>
#import <OpenGL/OpenGL.h>

// NSOpenGL is deprecated (since macOS 10.14, in favour of Metal) and still
// supported; it is the API this file exists to use. Every use here would
// warn, so the warning is off for this file alone.
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

#include <dlfcn.h>
#include <stdlib.h>

#include "cocoa.h"

@interface WeftGlViewHandle : NSObject
@property(nonatomic, strong) NSOpenGLContext* context;
@property(nonatomic, weak) NSView* view;
@end

@implementation WeftGlViewHandle
- (void)viewFrameChanged:(NSNotification*)notification {
    // NSOpenGLView's own rule: a moved or resized view needs `update`. Not
    // during a live resize, though: weft cannot draw until AppKit's tracking
    // loop ends, and a surface re-fitted with nothing drawn into it shows
    // garbage, where the old one shows its last frame stretched. The frame
    // loop updates (`weft_gl_view_update`) once the size settles.
    if (self.view.inLiveResize) return;
    [self.context update];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}
@end

static NSOpenGLPixelFormat* windowPixelFormat(BOOL accelerated) {
    // 3.2 core asks for "a core profile": macOS answers with the newest it
    // has (4.1). RGBA8 with 8 bits of stencil, which Skia uses for paths.
    NSOpenGLPixelFormatAttribute attributes[16];
    int n = 0;
    attributes[n++] = NSOpenGLPFAOpenGLProfile;
    attributes[n++] = NSOpenGLProfileVersion3_2Core;
    attributes[n++] = NSOpenGLPFAColorSize;
    attributes[n++] = 24;
    attributes[n++] = NSOpenGLPFAAlphaSize;
    attributes[n++] = 8;
    attributes[n++] = NSOpenGLPFAStencilSize;
    attributes[n++] = 8;
    attributes[n++] = NSOpenGLPFADoubleBuffer;
    // Let a dual-GPU Mac keep the integrated GPU for an editor.
    attributes[n++] = NSOpenGLPFAAllowOfflineRenderers;
    if (accelerated) attributes[n++] = NSOpenGLPFAAccelerated;
    attributes[n++] = 0;
    return [[NSOpenGLPixelFormat alloc] initWithAttributes:attributes];
}

WeftGlView* weft_gl_view_create(void* view_ptr, uint32_t* stencil_bits) {
    @autoreleasepool {
        NSView* view = (__bridge NSView*)view_ptr;
        // A hardware renderer if there is one; Apple's software renderer
        // (a VM, a headless CI Mac) otherwise.
        NSOpenGLPixelFormat* format = windowPixelFormat(YES) ?: windowPixelFormat(NO);
        if (!format) return NULL;
        NSOpenGLContext* context = [[NSOpenGLContext alloc] initWithFormat:format shareContext:nil];
        if (!context) return NULL;

        GLint stencil = 0;
        [format getValues:&stencil forAttribute:NSOpenGLPFAStencilSize forVirtualScreen:0];
        *stencil_bits = stencil > 0 ? (uint32_t)stencil : 0;

        // Draw at the display's real resolution, not in points scaled up.
        view.wantsBestResolutionOpenGLSurface = YES;
        context.view = view;
        // Never wait for vertical sync inside a swap: weft draws only when
        // something changed and must not block its frame loop on the display;
        // the window server composites without tearing.
        const GLint interval = 0;
        [context setValues:&interval forParameter:NSOpenGLContextParameterSwapInterval];
        [context makeCurrentContext];
        [context update];

        WeftGlViewHandle* handle = [[WeftGlViewHandle alloc] init];
        handle.context = context;
        handle.view = view;
        view.postsFrameChangedNotifications = YES;
        [[NSNotificationCenter defaultCenter] addObserver:handle
                                                 selector:@selector(viewFrameChanged:)
                                                     name:NSViewGlobalFrameDidChangeNotification
                                                   object:view];
        return (__bridge_retained WeftGlView*)handle;
    }
}

void weft_gl_view_destroy(WeftGlView* gl) {
    @autoreleasepool {
        WeftGlViewHandle* handle = (__bridge_transfer WeftGlViewHandle*)gl;
        if (CGLGetCurrentContext() == handle.context.CGLContextObj) [NSOpenGLContext clearCurrentContext];
        [handle.context clearDrawable];
    }
}

// The per-frame calls run outside any AppKit loop, so each drains its own
// autorelease pool.
void weft_gl_view_make_current(WeftGlView* gl) {
    @autoreleasepool {
        WeftGlViewHandle* handle = (__bridge WeftGlViewHandle*)gl;
        // Compared at the CGL level: the offscreen context switches through
        // CGL, which NSOpenGLContext's own notion of "current" does not see.
        if (CGLGetCurrentContext() != handle.context.CGLContextObj) [handle.context makeCurrentContext];
    }
}

void weft_gl_view_update(WeftGlView* gl) {
    @autoreleasepool {
        WeftGlViewHandle* handle = (__bridge WeftGlViewHandle*)gl;
        [handle.context update];
    }
}

void weft_gl_view_swap(WeftGlView* gl) {
    @autoreleasepool {
        WeftGlViewHandle* handle = (__bridge WeftGlViewHandle*)gl;
        [handle.context flushBuffer];
    }
}

struct WeftGlOffscreen {
    CGLContextObj context;
};

WeftGlOffscreen* weft_gl_offscreen_create(void) {
    // No kCGLPFAAccelerated: a Mac with no usable GPU (a VM, CI) still gets
    // Apple's software renderer, which is all a headless read back needs.
    const CGLPixelFormatAttribute attributes[] = {
        kCGLPFAOpenGLProfile, (CGLPixelFormatAttribute)kCGLOGLPVersion_3_2_Core,
        kCGLPFAColorSize,     (CGLPixelFormatAttribute)24,
        kCGLPFAAlphaSize,     (CGLPixelFormatAttribute)8,
        kCGLPFAAllowOfflineRenderers,
        (CGLPixelFormatAttribute)0,
    };
    CGLPixelFormatObj format = NULL;
    GLint count = 0;
    if (CGLChoosePixelFormat(attributes, &format, &count) != kCGLNoError || !format) return NULL;
    CGLContextObj context = NULL;
    const CGLError created = CGLCreateContext(format, NULL, &context);
    CGLReleasePixelFormat(format);
    if (created != kCGLNoError || !context) return NULL;
    WeftGlOffscreen* gl = calloc(1, sizeof *gl);
    if (!gl) {
        CGLReleaseContext(context);
        return NULL;
    }
    gl->context = context;
    CGLSetCurrentContext(context);
    return gl;
}

void weft_gl_offscreen_destroy(WeftGlOffscreen* gl) {
    if (CGLGetCurrentContext() == gl->context) CGLSetCurrentContext(NULL);
    CGLReleaseContext(gl->context);
    free(gl);
}

void weft_gl_offscreen_make_current(WeftGlOffscreen* gl) {
    if (CGLGetCurrentContext() != gl->context) CGLSetCurrentContext(gl->context);
}

// GL's entry points are the OpenGL framework's exported symbols, the same
// for every context on macOS — which is how Skia's own Mac interface finds
// them.
void (*weft_gl_get_proc(void* ctx, const char* name))(void) {
    (void)ctx;
    static void* framework;
    if (!framework) framework = dlopen("/System/Library/Frameworks/OpenGL.framework/OpenGL", RTLD_LAZY | RTLD_LOCAL);
    if (!framework) return NULL;
    return (void (*)(void))dlsym(framework, name);
}
