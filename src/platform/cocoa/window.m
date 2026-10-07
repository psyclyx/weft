// AppKit half of weft's Cocoa platform: the application, one window, its
// content view, and the pasteboard, behind the C ABI in window.h. Rules live
// in Zig (platform/cocoa.zig, platform/cocoa_keys.zig); this file reports what
// AppKit says, as it says it.
//
// weft runs its own loop rather than [NSApp run]: the scheduler owns the wait
// (`weft_cocoa_wait`) and the frame loop pumps (`weft_cocoa_pump`). The wait
// sleeps in AppKit's event queue with every scheduler fd attached to the main
// run loop as a CFFileDescriptor, so window-server events and fd readiness
// wake the same sleep — neither can starve the other, and nothing polls.

#import <Cocoa/Cocoa.h>
#import <Carbon/Carbon.h>  // kVK_* — only to check platform/cocoa_keys.zig's codes
#import <IOKit/hidsystem/IOLLEvent.h>  // NX_DEVICELALTKEYMASK

#include <string.h>
#include <sys/stat.h>

#include "window.h"

// platform/cocoa_keys.zig names keys by these codes; hold it to the SDK.
_Static_assert(kVK_Return == 0x24, "cocoa_keys.zig vk.Return");
_Static_assert(kVK_Tab == 0x30, "cocoa_keys.zig vk.Tab");
_Static_assert(kVK_Delete == 0x33, "cocoa_keys.zig vk.Delete");
_Static_assert(kVK_Escape == 0x35, "cocoa_keys.zig vk.Escape");
_Static_assert(kVK_Help == 0x72, "cocoa_keys.zig vk.Help");
_Static_assert(kVK_Home == 0x73, "cocoa_keys.zig vk.Home");
_Static_assert(kVK_PageUp == 0x74, "cocoa_keys.zig vk.PageUp");
_Static_assert(kVK_ForwardDelete == 0x75, "cocoa_keys.zig vk.ForwardDelete");
_Static_assert(kVK_End == 0x77, "cocoa_keys.zig vk.End");
_Static_assert(kVK_PageDown == 0x79, "cocoa_keys.zig vk.PageDown");
_Static_assert(kVK_LeftArrow == 0x7B, "cocoa_keys.zig vk.LeftArrow");
_Static_assert(kVK_RightArrow == 0x7C, "cocoa_keys.zig vk.RightArrow");
_Static_assert(kVK_DownArrow == 0x7D, "cocoa_keys.zig vk.DownArrow");
_Static_assert(kVK_UpArrow == 0x7E, "cocoa_keys.zig vk.UpArrow");
_Static_assert(kVK_F1 == 0x7A && kVK_F2 == 0x78 && kVK_F3 == 0x63 && kVK_F4 == 0x76, "cocoa_keys.zig vk.F1-F4");
_Static_assert(kVK_F5 == 0x60 && kVK_F6 == 0x61 && kVK_F7 == 0x62 && kVK_F8 == 0x64, "cocoa_keys.zig vk.F5-F8");
_Static_assert(kVK_F9 == 0x65 && kVK_F10 == 0x6D && kVK_F11 == 0x67 && kVK_F12 == 0x6F, "cocoa_keys.zig vk.F9-F12");
_Static_assert(kVK_F13 == 0x69 && kVK_F14 == 0x6B && kVK_F15 == 0x71 && kVK_F16 == 0x6A, "cocoa_keys.zig vk.F13-F16");
_Static_assert(kVK_F17 == 0x40 && kVK_F18 == 0x4F && kVK_F19 == 0x50 && kVK_F20 == 0x5A, "cocoa_keys.zig vk.F17-F20");
_Static_assert(kVK_ANSI_KeypadDecimal == 0x41 && kVK_ANSI_KeypadMultiply == 0x43, "cocoa_keys.zig keypad");
_Static_assert(kVK_ANSI_KeypadPlus == 0x45 && kVK_ANSI_KeypadClear == 0x47, "cocoa_keys.zig keypad");
_Static_assert(kVK_ANSI_KeypadDivide == 0x4B && kVK_ANSI_KeypadEnter == 0x4C, "cocoa_keys.zig keypad");
_Static_assert(kVK_ANSI_KeypadMinus == 0x4E && kVK_ANSI_KeypadEquals == 0x51, "cocoa_keys.zig keypad");
_Static_assert(kVK_ANSI_Keypad0 == 0x52 && kVK_ANSI_Keypad1 == 0x53 && kVK_ANSI_Keypad2 == 0x54, "cocoa_keys.zig keypad");
_Static_assert(kVK_ANSI_Keypad3 == 0x55 && kVK_ANSI_Keypad4 == 0x56 && kVK_ANSI_Keypad5 == 0x57, "cocoa_keys.zig keypad");
_Static_assert(kVK_ANSI_Keypad6 == 0x58 && kVK_ANSI_Keypad7 == 0x59 && kVK_ANSI_Keypad8 == 0x5B, "cocoa_keys.zig keypad");
_Static_assert(kVK_ANSI_Keypad9 == 0x5C, "cocoa_keys.zig keypad");

static const uint16_t kNoKey = 0xFFFF;

// ── Modifiers ────────────────────────────────────────────────────────

static uint32_t translateFlags(NSEventModifierFlags flags) {
    uint32_t mods = 0;
    if (flags & NSEventModifierFlagShift) mods |= WEFT_COCOA_MOD_SHIFT;
    if (flags & NSEventModifierFlagControl) mods |= WEFT_COCOA_MOD_CTRL;
    if (flags & NSEventModifierFlagCommand) mods |= WEFT_COCOA_MOD_SUPER;
    // Only the LEFT Option key is Meta; the right one keeps typing the
    // characters a layout puts on Option. The device-dependent low bits of
    // the flags say which side is down — when they are there: an event that
    // carries neither (synthesized by a remapper or a remote-control tool)
    // counts as the left.
    if (flags & NSEventModifierFlagOption) {
        const BOOL right_only = (flags & NX_DEVICERALTKEYMASK) && !(flags & NX_DEVICELALTKEYMASK);
        if (!right_only) mods |= WEFT_COCOA_MOD_META;
    }
    return mods;
}

// ── Waking the event wait ────────────────────────────────────────────

// An event that means nothing but "stop waiting": posted when a scheduler fd
// becomes ready (or launch finishes), dispatched to NSApp as a no-op.
static void postWakeEvent(void) {
    NSEvent* wake = [NSEvent otherEventWithType:NSEventTypeApplicationDefined
                                       location:NSZeroPoint
                                  modifierFlags:0
                                      timestamp:0
                                   windowNumber:0
                                        context:nil
                                        subtype:0
                                          data1:0
                                          data2:0];
    [NSApp postEvent:wake atStart:YES];
}

static void fdReady(CFFileDescriptorRef fd, CFOptionFlags types, void* info) {
    (void)fd;
    (void)types;
    (void)info;
    postWakeEvent();
}

// One scheduler fd attached to the main run loop. CFFileDescriptor callbacks
// are one-shot: armed before each wait, disarmed after.
@interface WeftFdWatch : NSObject
@property(nonatomic, readonly) int fd;
- (instancetype)initWithFd:(int)fd;
// Is `fd` still the file this watch was made for? A closed fd's number is
// reused, and a CFFileDescriptor made for the old file must not stand in for
// the new one.
- (BOOL)watches:(int)fd;
- (void)arm:(short)events;
- (void)disarm;
// Detach from the run loop now, not whenever ARC gets to `dealloc`.
- (void)invalidate;
@end

@implementation WeftFdWatch {
    CFFileDescriptorRef _ref;
    CFRunLoopSourceRef _source;
    dev_t _dev;
    ino_t _ino;
}

- (instancetype)initWithFd:(int)fd {
    if (!(self = [super init])) return nil;
    _fd = fd;
    struct stat st;
    if (fstat(fd, &st) != 0) return nil;
    _dev = st.st_dev;
    _ino = st.st_ino;
    // closeOnInvalidate=false: the fd belongs to whoever registered it.
    _ref = CFFileDescriptorCreate(kCFAllocatorDefault, fd, false, fdReady, NULL);
    if (!_ref) return nil;
    _source = CFFileDescriptorCreateRunLoopSource(kCFAllocatorDefault, _ref, 0);
    if (!_source) return nil;
    CFRunLoopAddSource(CFRunLoopGetMain(), _source, kCFRunLoopDefaultMode);
    return self;
}

- (BOOL)watches:(int)fd {
    struct stat st;
    return fd == _fd && fstat(fd, &st) == 0 && st.st_dev == _dev && st.st_ino == _ino;
}

- (void)arm:(short)events {
    if (!_ref) return;
    CFOptionFlags types = 0;
    if (events & POLLIN) types |= kCFFileDescriptorReadCallBack;
    if (events & POLLOUT) types |= kCFFileDescriptorWriteCallBack;
    if (types) CFFileDescriptorEnableCallBacks(_ref, types);
}

- (void)disarm {
    if (!_ref) return;
    CFFileDescriptorDisableCallBacks(_ref, kCFFileDescriptorReadCallBack | kCFFileDescriptorWriteCallBack);
}

- (void)invalidate {
    if (_source) {
        CFRunLoopRemoveSource(CFRunLoopGetMain(), _source, kCFRunLoopDefaultMode);
        CFRelease(_source);
        _source = NULL;
    }
    if (_ref) {
        CFFileDescriptorInvalidate(_ref);
        CFRelease(_ref);
        _ref = NULL;
    }
}

- (void)dealloc {
    [self invalidate];
}
@end

// ── The window ───────────────────────────────────────────────────────

@class WeftView;

@interface WeftWindowHandle : NSObject <NSWindowDelegate>
@property(nonatomic, readonly) WeftCocoaSink sink;
@property(nonatomic, strong) NSWindow* window;
@property(nonatomic, strong) WeftView* view;
@property(nonatomic, strong) NSMutableArray<WeftFdWatch*>* watches;
- (instancetype)initWithSink:(const WeftCocoaSink*)sink;
- (void)reportSize;
- (void)requestClose;
@end

// The handle whose window a Quit (⌘Q, the Dock, logout) asks to close.
static __weak WeftWindowHandle* g_current;

@interface WeftView : NSView <NSTextInputClient>
- (instancetype)initWithFrame:(NSRect)frame handle:(WeftWindowHandle*)handle;
@end

@implementation WeftView {
    __weak WeftWindowHandle* _handle;
    NSTrackingArea* _tracking;
    NSMutableAttributedString* _marked;
    // The key press being interpreted, while `interpretKeyEvents:` runs: what
    // `insertText:`/`doCommandBySelector:` report against.
    NSEvent* _pending;
}

- (instancetype)initWithFrame:(NSRect)frame handle:(WeftWindowHandle*)handle {
    if (!(self = [super initWithFrame:frame])) return nil;
    _handle = handle;
    _marked = [[NSMutableAttributedString alloc] init];
    [self updateTrackingAreas];
    return self;
}

// Top-left origin, like every other surface weft draws on.
- (BOOL)isFlipped {
    return YES;
}
- (BOOL)acceptsFirstResponder {
    return YES;
}
- (BOOL)canBecomeKeyView {
    return YES;
}
// A click that activates the window is also a click.
- (BOOL)acceptsFirstMouse:(NSEvent*)event {
    return YES;
}

- (void)updateTrackingAreas {
    if (_tracking) [self removeTrackingArea:_tracking];
    _tracking = [[NSTrackingArea alloc]
        initWithRect:NSZeroRect
             options:NSTrackingMouseEnteredAndExited | NSTrackingActiveInKeyWindow | NSTrackingInVisibleRect
               owner:self
            userInfo:nil];
    [self addTrackingArea:_tracking];
    [super updateTrackingAreas];
}

- (void)viewDidChangeBackingProperties {
    [super viewDidChangeBackingProperties];
    [_handle reportSize];
}

// ── Keys ──

- (void)sendKey:(NSEvent*)event pressed:(BOOL)pressed text:(NSString*)text {
    WeftWindowHandle* handle = _handle;
    if (!handle || !handle.sink.key) return;
    NSString* base = @"";
    if (event) base = [event charactersByApplyingModifiers:0] ?: @"";
    WeftCocoaKey key = {
        .keycode = event ? event.keyCode : kNoKey,
        .pressed = pressed ? 1 : 0,
        .mods = event ? translateFlags(event.modifierFlags) : 0,
        .text = text.UTF8String,
        .text_len = [text lengthOfBytesUsingEncoding:NSUTF8StringEncoding],
        .base = base.UTF8String,
        .base_len = [base lengthOfBytesUsingEncoding:NSUTF8StringEncoding],
    };
    handle.sink.key(handle.sink.ctx, &key);
}

- (void)keyDown:(NSEvent*)event {
    // A chord is a binding, never text: it skips the text-input system, so
    // Control, Meta and Command keys can't be eaten by a dead key or an
    // input method, or turned into Cocoa's own editing commands.
    if (translateFlags(event.modifierFlags) & (WEFT_COCOA_MOD_CTRL | WEFT_COCOA_MOD_META | WEFT_COCOA_MOD_SUPER)) {
        [self sendKey:event pressed:YES text:@""];
        return;
    }
    // Everything else goes through text input, which composes dead keys and
    // input methods and answers with insertText: (a character) or
    // doCommandBySelector: (a key that types nothing) — or neither, while a
    // composition is still open.
    _pending = event;
    [self interpretKeyEvents:@[ event ]];
    _pending = nil;
}

- (void)keyUp:(NSEvent*)event {
    [self sendKey:event pressed:NO text:@""];
}

// AppKit offers a Control chord to the view hierarchy as a key equivalent
// first, and spends some (⌃Tab, ⌃⇧Tab) on keyboard navigation before keyDown:
// ever sees them. Here they are bindings: take them all while this view has
// the keyboard. ⌘ chords stay the menu's.
- (BOOL)performKeyEquivalent:(NSEvent*)event {
    const NSEventModifierFlags flags = event.modifierFlags;
    if (event.type == NSEventTypeKeyDown && (flags & NSEventModifierFlagControl) &&
        !(flags & NSEventModifierFlagCommand) && self.window.firstResponder == self) {
        [self keyDown:event];
        return YES;
    }
    return [super performKeyEquivalent:event];
}

// ── NSTextInputClient ──

- (void)insertText:(id)string replacementRange:(NSRange)replacementRange {
    NSString* text = [string isKindOfClass:[NSAttributedString class]] ? [string string] : string;
    [[_marked mutableString] setString:@""];
    if (text.length == 0) return;
    // The key being interpreted typed this text only if it is the key's own
    // character (a dead key's second press already reads "é"). Otherwise an
    // input method is committing a composition — on Return, Tab, an arrow,
    // or a candidate picked with the mouse (`_pending` nil) — and the text is
    // text with no key: naming it after Return would type a newline instead.
    NSEvent* key = (_pending && [text isEqualToString:_pending.characters]) ? _pending : nil;
    [self sendKey:key pressed:YES text:text];
}

- (void)doCommandBySelector:(SEL)selector {
    // Return, Tab, arrows, Escape, Backspace...: the key itself, by its code.
    if (_pending) [self sendKey:_pending pressed:YES text:@""];
}

- (void)setMarkedText:(id)string selectedRange:(NSRange)selectedRange replacementRange:(NSRange)replacementRange {
    if ([string isKindOfClass:[NSAttributedString class]])
        _marked = [[NSMutableAttributedString alloc] initWithAttributedString:string];
    else
        _marked = [[NSMutableAttributedString alloc] initWithString:string];
}

- (void)unmarkText {
    [[_marked mutableString] setString:@""];
}

- (BOOL)hasMarkedText {
    return _marked.length > 0;
}

- (NSRange)markedRange {
    return _marked.length > 0 ? NSMakeRange(0, _marked.length) : NSMakeRange(NSNotFound, 0);
}

- (NSRange)selectedRange {
    return NSMakeRange(NSNotFound, 0);
}

- (NSArray<NSAttributedStringKey>*)validAttributesForMarkedText {
    return @[];
}

- (NSAttributedString*)attributedSubstringForProposedRange:(NSRange)range actualRange:(NSRangePointer)actualRange {
    return nil;
}

- (NSUInteger)characterIndexForPoint:(NSPoint)point {
    return NSNotFound;
}

// Where an input method's candidate window goes: weft draws its own caret,
// so all AppKit can be told is the view's corner.
- (NSRect)firstRectForCharacterRange:(NSRange)range actualRange:(NSRangePointer)actualRange {
    const NSRect frame = [self.window convertRectToScreen:[self convertRect:self.bounds toView:nil]];
    return NSMakeRect(NSMinX(frame), NSMinY(frame), 0, 0);
}

// ── Pointer ──

- (void)sendPointer:(uint8_t)kind button:(uint8_t)button event:(NSEvent*)event {
    WeftWindowHandle* handle = _handle;
    if (!handle || !handle.sink.pointer) return;
    const NSPoint at = [self convertPoint:event.locationInWindow fromView:nil];
    WeftCocoaPointer pointer = {
        .kind = kind,
        .button = button,
        .mods = translateFlags(event.modifierFlags),
        .x = at.x,
        .y = at.y,
        // Through 64 bits, so the millisecond clock WRAPS past 2^32 (the
        // reducer handles that) instead of saturating, which a direct cast does.
        .time_ms = (uint32_t)(uint64_t)(event.timestamp * 1000.0),
    };
    if (kind == WEFT_COCOA_POINTER_SCROLL) {
        pointer.dx = event.scrollingDeltaX;
        pointer.dy = event.scrollingDeltaY;
        pointer.precise = event.hasPreciseScrollingDeltas ? 1 : 0;
        const NSEventPhase over = NSEventPhaseEnded | NSEventPhaseCancelled;
        pointer.ended = ((event.phase & over) || (event.momentumPhase & over)) ? 1 : 0;
    }
    handle.sink.pointer(handle.sink.ctx, &pointer);
}

// AppKit's other-button numbers: 2 is the middle button, 3 and 4 back and
// forward. weft numbers buttons the way its keymap names them.
static uint8_t otherButton(NSInteger number) {
    switch (number) {
        case 2: return 2;
        case 3: return 8;
        case 4: return 9;
        default: return 0;
    }
}

- (void)mouseDown:(NSEvent*)event {
    [self sendPointer:WEFT_COCOA_POINTER_PRESS button:1 event:event];
}
- (void)mouseUp:(NSEvent*)event {
    [self sendPointer:WEFT_COCOA_POINTER_RELEASE button:1 event:event];
}
- (void)rightMouseDown:(NSEvent*)event {
    [self sendPointer:WEFT_COCOA_POINTER_PRESS button:3 event:event];
}
- (void)rightMouseUp:(NSEvent*)event {
    [self sendPointer:WEFT_COCOA_POINTER_RELEASE button:3 event:event];
}
- (void)otherMouseDown:(NSEvent*)event {
    const uint8_t button = otherButton(event.buttonNumber);
    if (button) [self sendPointer:WEFT_COCOA_POINTER_PRESS button:button event:event];
}
- (void)otherMouseUp:(NSEvent*)event {
    const uint8_t button = otherButton(event.buttonNumber);
    if (button) [self sendPointer:WEFT_COCOA_POINTER_RELEASE button:button event:event];
}
- (void)mouseMoved:(NSEvent*)event {
    [self sendPointer:WEFT_COCOA_POINTER_MOTION button:0 event:event];
}
- (void)mouseDragged:(NSEvent*)event {
    [self sendPointer:WEFT_COCOA_POINTER_MOTION button:0 event:event];
}
- (void)rightMouseDragged:(NSEvent*)event {
    [self sendPointer:WEFT_COCOA_POINTER_MOTION button:0 event:event];
}
- (void)otherMouseDragged:(NSEvent*)event {
    [self sendPointer:WEFT_COCOA_POINTER_MOTION button:0 event:event];
}
- (void)mouseEntered:(NSEvent*)event {
    [self sendPointer:WEFT_COCOA_POINTER_ENTER button:0 event:event];
}
- (void)mouseExited:(NSEvent*)event {
    [self sendPointer:WEFT_COCOA_POINTER_LEAVE button:0 event:event];
}
- (void)scrollWheel:(NSEvent*)event {
    [self sendPointer:WEFT_COCOA_POINTER_SCROLL button:0 event:event];
}
@end

@implementation WeftWindowHandle

- (instancetype)initWithSink:(const WeftCocoaSink*)sink {
    if (!(self = [super init])) return nil;
    _sink = *sink;
    _watches = [NSMutableArray array];
    return self;
}

// AppKit calls the delegate from inside its own run loop — a tiling or display
// change resizes the window, a Dock Quit arrives as an Apple Event — possibly
// while `weft_cocoa_wait` sleeps, and queues no event for it. Whatever such a
// callback tells the sink must also end that sleep.
- (void)reportSize {
    if (!_sink.resized || !_view) return;
    uint32_t width = 0, height = 0, scale = 1;
    weft_cocoa_size((__bridge WeftCocoa*)self, &width, &height, &scale);
    _sink.resized(_sink.ctx, width, height, scale);
    postWakeEvent();
}

- (void)requestClose {
    if (_sink.close_requested) _sink.close_requested(_sink.ctx);
    postWakeEvent();
}

// The window's close button asks; weft decides (it may refuse while work is
// unsaved), so the window never closes itself.
- (BOOL)windowShouldClose:(NSWindow*)sender {
    [self requestClose];
    return NO;
}

- (void)windowDidResize:(NSNotification*)notification {
    [self reportSize];
}

- (void)windowDidChangeBackingProperties:(NSNotification*)notification {
    [self reportSize];
}
@end

// ── The application ──────────────────────────────────────────────────

static void createMenuBar(void);

@interface WeftAppDelegate : NSObject <NSApplicationDelegate>
@end

@implementation WeftAppDelegate
// Quit — ⌘Q, the Dock, logout — is the window's close request: weft decides,
// and exits its own loop if it agrees. AppKit never terminates the process
// under it.
- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication*)sender {
    [g_current requestClose];
    return NSTerminateCancel;
}

// The menu bar is built between `sharedApplication` and launching, as
// NSApplicationMain would build it from a nib.
- (void)applicationWillFinishLaunching:(NSNotification*)notification {
    createMenuBar();
}

// The launch `initApplication` runs [NSApp run] for ends here: AppKit has
// finished launching (menu bar, activation), and the loop is weft's again.
- (void)applicationDidFinishLaunching:(NSNotification*)notification {
    [NSApp stop:nil];
    postWakeEvent();  // `stop:` takes effect after the next event
}

// weft restores nothing through AppKit; saying so (securely) keeps macOS 14+
// from warning at every launch.
- (BOOL)applicationSupportsSecureRestorableState:(NSApplication*)app {
    return YES;
}
@end

static void addMenuItem(NSMenu* menu, NSString* title, SEL action, NSString* key, NSEventModifierFlags mods) {
    NSMenuItem* item = [menu addItemWithTitle:title action:action keyEquivalent:key];
    if (mods) item.keyEquivalentModifierMask = mods;
}

// The standard application and Window menus. Only the system's own
// shortcuts are claimed (⌘Q, ⌘H, ⌥⌘H, ⌘M, ⌃⌘F); every other ⌘ chord reaches
// weft's keymap as `s-<key>`.
static void createMenuBar(void) {
    NSString* name = @"weft";
    NSMenu* bar = [[NSMenu alloc] init];
    NSApp.mainMenu = bar;

    NSMenu* app = [[NSMenu alloc] init];
    [bar addItemWithTitle:@"" action:NULL keyEquivalent:@""].submenu = app;
    addMenuItem(app, [@"About " stringByAppendingString:name], @selector(orderFrontStandardAboutPanel:), @"", 0);
    [app addItem:[NSMenuItem separatorItem]];
    NSMenu* services = [[NSMenu alloc] init];
    [app addItemWithTitle:@"Services" action:NULL keyEquivalent:@""].submenu = services;
    NSApp.servicesMenu = services;
    [app addItem:[NSMenuItem separatorItem]];
    addMenuItem(app, [@"Hide " stringByAppendingString:name], @selector(hide:), @"h", 0);
    addMenuItem(app, @"Hide Others", @selector(hideOtherApplications:), @"h",
                NSEventModifierFlagOption | NSEventModifierFlagCommand);
    addMenuItem(app, @"Show All", @selector(unhideAllApplications:), @"", 0);
    [app addItem:[NSMenuItem separatorItem]];
    addMenuItem(app, [@"Quit " stringByAppendingString:name], @selector(terminate:), @"q", 0);

    NSMenu* window = [[NSMenu alloc] initWithTitle:@"Window"];
    [bar addItemWithTitle:@"" action:NULL keyEquivalent:@""].submenu = window;
    NSApp.windowsMenu = window;
    addMenuItem(window, @"Minimize", @selector(performMiniaturize:), @"m", 0);
    addMenuItem(window, @"Zoom", @selector(performZoom:), @"", 0);
    [window addItem:[NSMenuItem separatorItem]];
    addMenuItem(window, @"Bring All to Front", @selector(arrangeInFront:), @"", 0);
    [window addItem:[NSMenuItem separatorItem]];
    addMenuItem(window, @"Enter Full Screen", @selector(toggleFullScreen:), @"f",
                NSEventModifierFlagControl | NSEventModifierFlagCommand);
}

static void initApplication(void) {
    static WeftAppDelegate* delegate;
    if (delegate) return;
    [NSApplication sharedApplication];
    delegate = [[WeftAppDelegate alloc] init];
    NSApp.delegate = delegate;
    // Holding a letter opens the accent picker instead of repeating it — wrong
    // for an editor whose keys are commands (hold `l`, hold `x`). Accents stay
    // a dead key or an input method away.
    [[NSUserDefaults standardUserDefaults] registerDefaults:@{@"ApplePressAndHoldEnabled" : @NO}];
    // Let AppKit finish launching once, inside its own loop; the delegate
    // stops it as soon as it has.
    if (![[NSRunningApplication currentApplication] isFinishedLaunching]) [NSApp run];
    // A plain executable (no bundle) is a background process unless it asks:
    // a Dock icon, a menu bar, keyboard focus.
    [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
}

// ── C ABI ────────────────────────────────────────────────────────────

WeftCocoa* weft_cocoa_create(uint32_t width, uint32_t height, const char* title, const WeftCocoaSink* sink) {
    @autoreleasepool {
        initApplication();
        WeftWindowHandle* handle = [[WeftWindowHandle alloc] initWithSink:sink];
        const NSRect frame = NSMakeRect(0, 0, width, height);
        NSWindow* window = [[NSWindow alloc]
            initWithContentRect:frame
                      styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                                NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable
                        backing:NSBackingStoreBuffered
                          defer:NO];
        if (!window) return NULL;
        window.releasedWhenClosed = NO;
        window.title = [NSString stringWithUTF8String:title] ?: @"weft";
        window.delegate = handle;
        window.acceptsMouseMovedEvents = YES;
        window.restorable = NO;
        window.tabbingMode = NSWindowTabbingModeDisallowed;
        window.collectionBehavior = NSWindowCollectionBehaviorFullScreenPrimary;
        // weft draws sRGB bytes; tag the window so a wide-gamut (P3) display
        // shows them as sRGB rather than stretching them across its gamut.
        window.colorSpace = [NSColorSpace sRGBColorSpace];

        WeftView* view = [[WeftView alloc] initWithFrame:frame handle:handle];
        window.contentView = view;
        [window makeFirstResponder:view];
        handle.window = window;
        handle.view = view;

        [window center];
        // Take focus from whatever launched us. `activate` (macOS 14) is only a
        // request the active application — the terminal weft was started from —
        // need not grant; an editor that opens without the keyboard is broken.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        [NSApp activateIgnoringOtherApps:YES];
#pragma clang diagnostic pop
        [window makeKeyAndOrderFront:nil];
        g_current = handle;
        return (__bridge_retained WeftCocoa*)handle;
    }
}

void weft_cocoa_destroy(WeftCocoa* cocoa) {
    @autoreleasepool {
        WeftWindowHandle* handle = (__bridge_transfer WeftWindowHandle*)cocoa;
        for (WeftFdWatch* watch in handle.watches) [watch invalidate];
        handle.watches = nil;
        handle.window.delegate = nil;
        [handle.window orderOut:nil];
        [handle.window close];
        if (g_current == handle) g_current = nil;
    }
}

void weft_cocoa_pump(WeftCocoa* cocoa) {
    (void)cocoa;
    @autoreleasepool {
        for (;;) {
            NSEvent* event = [NSApp nextEventMatchingMask:NSEventMaskAny
                                                untilDate:[NSDate distantPast]
                                                   inMode:NSDefaultRunLoopMode
                                                  dequeue:YES];
            if (!event) break;
            [NSApp sendEvent:event];
        }
    }
}

// Attach exactly `fds` to the run loop: keep the watch of an fd still in the
// set and still the same file, create one for anything else, drop the rest.
// Dropping comes first: CoreFoundation keys every CFFileDescriptor by fd
// number in one kqueue, so a stale watch released AFTER a fresh one for the
// same number was armed would take the fresh one's registration with it. The
// scheduler's set is small (a handful of wake fds) and changes rarely.
static void syncWatches(WeftWindowHandle* handle, struct pollfd* fds, size_t nfds) {
    NSMutableArray<WeftFdWatch*>* kept = [NSMutableArray arrayWithCapacity:nfds];
    for (WeftFdWatch* watch in handle.watches) {
        BOOL wanted = NO;
        for (size_t i = 0; i < nfds && !wanted; i++) wanted = [watch watches:fds[i].fd];
        if (wanted)
            [kept addObject:watch];
        else
            [watch invalidate];
    }

    NSMutableArray<WeftFdWatch*>* next = [NSMutableArray arrayWithCapacity:nfds];
    for (size_t i = 0; i < nfds; i++) {
        if (fds[i].fd < 0) continue;
        WeftFdWatch* found = nil;
        for (WeftFdWatch* watch in kept) {
            if (watch.fd == fds[i].fd) {
                found = watch;
                break;
            }
        }
        if (!found) found = [[WeftFdWatch alloc] initWithFd:fds[i].fd];
        if (!found) continue;
        [found arm:fds[i].events];
        [next addObject:found];
    }
    handle.watches = next;
}

size_t weft_cocoa_wait(WeftCocoa* cocoa, struct pollfd* fds, size_t nfds, int timeout_ms) {
    @autoreleasepool {
        WeftWindowHandle* handle = (__bridge WeftWindowHandle*)cocoa;
        int ready = poll(fds, (nfds_t)nfds, 0);
        if (ready > 0) return (size_t)ready;
        if (timeout_ms == 0) return 0;
        // Something already queued: no sleep at all.
        if ([NSApp nextEventMatchingMask:NSEventMaskAny
                               untilDate:[NSDate distantPast]
                                  inMode:NSDefaultRunLoopMode
                                 dequeue:NO])
            return 0;

        syncWatches(handle, fds, nfds);
        NSDate* until = timeout_ms < 0 ? [NSDate distantFuture]
                                       : [NSDate dateWithTimeIntervalSinceNow:timeout_ms / 1000.0];
        // Sleep in AppKit's queue; an fd turning ready posts a wake event.
        // dequeue:NO leaves whatever arrived for the pump.
        [NSApp nextEventMatchingMask:NSEventMaskAny untilDate:until inMode:NSDefaultRunLoopMode dequeue:NO];
        for (WeftFdWatch* watch in handle.watches) [watch disarm];

        ready = poll(fds, (nfds_t)nfds, 0);
        return ready > 0 ? (size_t)ready : 0;
    }
}

void* weft_cocoa_view(WeftCocoa* cocoa) {
    @autoreleasepool {
        WeftWindowHandle* handle = (__bridge WeftWindowHandle*)cocoa;
        return (__bridge void*)handle.view;
    }
}

void weft_cocoa_size(WeftCocoa* cocoa, uint32_t* width, uint32_t* height, uint32_t* scale) {
    @autoreleasepool {
        WeftWindowHandle* handle = (__bridge WeftWindowHandle*)cocoa;
        const NSRect bounds = handle.view.bounds;
        const NSRect backing = [handle.view convertRectToBacking:bounds];
        *width = (uint32_t)NSWidth(bounds);
        *height = (uint32_t)NSHeight(bounds);
        // Pixels per point. macOS's backing scales are whole (1 or 2).
        const CGFloat factor = NSWidth(bounds) > 0 ? NSWidth(backing) / NSWidth(bounds) : handle.window.backingScaleFactor;
        *scale = factor >= 1 ? (uint32_t)(factor + 0.5) : 1;
    }
}

long weft_cocoa_pasteboard_change_count(void) {
    @autoreleasepool {
        return [NSPasteboard generalPasteboard].changeCount;
    }
}

void weft_cocoa_pasteboard_read(void* ctx, void (*deliver)(void* ctx, const char* text, size_t len)) {
    @autoreleasepool {
        NSString* text = [[NSPasteboard generalPasteboard] stringForType:NSPasteboardTypeString];
        if (!text) return;
        deliver(ctx, text.UTF8String, [text lengthOfBytesUsingEncoding:NSUTF8StringEncoding]);
    }
}

void weft_cocoa_pasteboard_write(const char* text, size_t len) {
    @autoreleasepool {
        NSString* string = [[NSString alloc] initWithBytes:text length:len encoding:NSUTF8StringEncoding];
        if (!string) return;
        NSPasteboard* pasteboard = [NSPasteboard generalPasteboard];
        [pasteboard clearContents];
        [pasteboard setString:string forType:NSPasteboardTypeString];
    }
}
