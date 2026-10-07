// C ABI between AppKit (window.m) and weft's Cocoa platform
// (platform/cocoa.zig). AppKit is driven from Objective-C, because that is
// what it is written for and what its headers check; everything with a rule
// in it — what a key is called, what a gesture is — stays in Zig, where the
// Linux test suite runs it. So this file carries raw facts one way (events,
// as calls on a sink) and requests the other (pump, wait, pasteboard), and
// only C scalars and pointers cross.
//
// Single-threaded: every function here, and every sink call, happens on the
// main thread, inside `weft_cocoa_pump` or `weft_cocoa_wait`.

#ifndef WEFT_COCOA_WINDOW_H
#define WEFT_COCOA_WINDOW_H

#include <poll.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct WeftCocoa WeftCocoa;

// Modifier bits. META is the LEFT Option key only: the right one stays the
// macOS typing modifier (see platform/cocoa_keys.zig). An event with no
// left/right device bits at all (synthesized) counts as the left.
enum {
    WEFT_COCOA_MOD_SHIFT = 1u << 0,
    WEFT_COCOA_MOD_CTRL = 1u << 1,
    WEFT_COCOA_MOD_META = 1u << 2,
    WEFT_COCOA_MOD_SUPER = 1u << 3,  // Command
};

typedef struct {
    uint16_t keycode;  // kVK_*; 0xFFFF for text committed outside a key press
    uint8_t pressed;   // 1 key down (or auto-repeat), 0 key up
    uint32_t mods;     // WEFT_COCOA_MOD_*
    const char* text;  // UTF-8 the key committed through text input ("" if none)
    size_t text_len;
    const char* base;  // the key's character, no modifiers, current layout
    size_t base_len;
} WeftCocoaKey;

enum {
    WEFT_COCOA_POINTER_MOTION = 0,
    WEFT_COCOA_POINTER_PRESS = 1,
    WEFT_COCOA_POINTER_RELEASE = 2,
    WEFT_COCOA_POINTER_SCROLL = 3,
    WEFT_COCOA_POINTER_ENTER = 4,
    WEFT_COCOA_POINTER_LEAVE = 5,
};

typedef struct {
    uint8_t kind;          // WEFT_COCOA_POINTER_*
    uint8_t button;        // press/release: 1 primary, 2 middle, 3 secondary, 8 back, 9 forward
    uint8_t precise;       // scroll: deltas are points (trackpad), not lines (wheel)
    uint8_t ended;         // scroll: the gesture (or its momentum) just ended
    uint32_t mods;         // WEFT_COCOA_MOD_*
    double x, y;           // view points, origin top-left
    double dx, dy;         // scroll: AppKit's scrolling deltas, sign as AppKit reports
    uint32_t time_ms;      // event time, for click counting
} WeftCocoaPointer;

// Where events go: called synchronously while AppKit dispatches.
typedef struct {
    void* ctx;
    void (*key)(void* ctx, const WeftCocoaKey* key);
    void (*pointer)(void* ctx, const WeftCocoaPointer* pointer);
    // The view's size in points, and its backing scale (pixels per point).
    void (*resized)(void* ctx, uint32_t width, uint32_t height, uint32_t scale);
    void (*close_requested)(void* ctx);
} WeftCocoaSink;

// Bring up the application (once per process) and one window with a
// `width`x`height`-point content view, shown and focused. NULL on failure.
WeftCocoa* weft_cocoa_create(uint32_t width, uint32_t height, const char* title,
                             const WeftCocoaSink* sink);
void weft_cocoa_destroy(WeftCocoa*);

// Dispatch every event already queued, without blocking.
void weft_cocoa_pump(WeftCocoa*);

// Block until one of `fds` is ready, an event is queued, or `timeout_ms`
// passes (-1: no timeout). Fills `revents` and returns the ready count
// exactly as poll(2) does; 0 for an event or a timeout.
size_t weft_cocoa_wait(WeftCocoa*, struct pollfd* fds, size_t nfds, int timeout_ms);

// The content view (NSView *) a GL context presents through.
void* weft_cocoa_view(WeftCocoa*);

// The content view's current size in points and backing scale.
void weft_cocoa_size(WeftCocoa*, uint32_t* width, uint32_t* height, uint32_t* scale);

// The general pasteboard. `change_count` moves whenever any application
// writes it; `read` hands its plain text (if any) to `deliver`.
long weft_cocoa_pasteboard_change_count(void);
void weft_cocoa_pasteboard_read(void* ctx, void (*deliver)(void* ctx, const char* text, size_t len));
void weft_cocoa_pasteboard_write(const char* text, size_t len);

#ifdef __cplusplus
}
#endif

#endif  // WEFT_COCOA_WINDOW_H
