//! P3 — the Platform seam (doc/rendering.md P3: "formalize the backend +
//! platform seams around skia/wayland (no behavior change).
//! Platform = window + input + present-surface + event-source. This file
//! names the contract `src/platform/wayland.zig`'s `Window` already
//! satisfies — extracted by AUDIT (grepping every `window.<decl>` call site
//! in `main.zig`/`app/dispatch.zig`/`app/loop_sources.zig`), not designed
//! from scratch — so a future X11/terminal/browser/macOS platform has a
//! fixed, comptime-checked target instead of a moving guess. `Window` stays
//! the ONE live implementation; nothing here changes what it does.
//!
//! ## comptime, not vtable
//! Exactly one Platform is compiled in, chosen at build time (there is no
//! `-Dplatform` flag today). A vtable buys runtime polymorphism nothing here
//! uses; `assertPlatform` is a duck-typed declaration set checked at compile
//! time. If runtime selection becomes useful later, this exact declaration
//! list is the vocabulary a small dispatch value must carry.
//!
//! ## the decl surface, enumerated by audit
//! - `init`/`deinit` — lifecycle. A Platform owns its own heap address:
//!   `Window.init` allocates and returns `!*Self`. This asymmetry is real,
//!   not an oversight — `main.zig` needs the window's address BEFORE it can
//!   build the Vulkan surface (`Context.init` takes `window.display`/
//!   `window.surface`), so the Platform can't be built in-place the way
//!   `render.init(gpa, ctx, …)` is (which needs `ctx` — i.e. the Platform's
//!   output — to already exist).
//! - `fd` — the scheduler's event-source registration (`sched.addFd`,
//!   `main.zig`).
//! - `pumpEvents` — drain the event queue; called unconditionally every
//!   scheduler wake (`main.zig`'s loop body), regardless of which source fired.
//! - `shouldClose` — the frame loop's exit condition.
//! - `framebufferSize` — feeds `Context.recreateSwapchain` on resize.
//! - `consumeResized` — edge-triggered resize flag, polled once per wake.
//! - `nextKeyEvent` — the ordered key queue `app/dispatch.zig:dispatchKey`
//!   drains, one `KeyEvent` per call until empty.
//! - `nextPointerEvent` — the ordered pointer queue (`PointerEvent`: press
//!   and release per button with modifiers and a click count, motion, wheel
//!   steps), drained by the shell into `app/pointer.zig` one event per call
//!   until empty. The gesture rules (click counting, wheel steps, motion
//!   coalescing) live in `pointer.zig`'s `Gestures`, which a platform feeds
//!   rather than re-derives.
//! - `repeatDueNs` — the key-repeat timer source's pure due-time query
//!   (`app/loop_sources.zig:keyRepeatDue`).
//! - `clipboardText`/`clipboardSet` — the system clipboard (doc/configs.md
//!   §3.3): the last-known selection text, and taking the selection. Reads
//!   never block; a platform with a desktop reads each offer as it is
//!   announced (`clipboard.zig`), one with none keeps a `clipboard.Store`.
//! - `clipboardFd` — readable when a clipboard transfer can make progress
//!   (-1 when a platform has none); registered once as a scheduler source,
//!   serviced inside `pumpEvents`.
//! Plus fields sampled directly (no method — they're read-mostly state, not
//! edge-triggered events): `display`/`surface` (raw native handles — see
//! "the SurfaceSource leak" below). `bufferScale()` is a method so accepted
//! scale and resize-pending state remain owned by the platform reducer.
//!
//! Pointer input used to be sampled here too (`mouse_x`/`mouse_y`/
//! `mouse_down`, an edge-triggered left click, and a dead `consumeWheel`):
//! only the left button was ever read, modifiers never reached it, and
//! nothing could tell a double click from two clicks. It is a queue of
//! events now, like keys.
//!
//! ## leaks found (wayland-specific surface reaching past the seam)
//!
//! 1. **`gfx/context.zig`'s `Context.SurfaceSource`** (`{ display: *anyopaque,
//!    surface: *anyopaque }`) is filled from `window.display`/`window.surface`
//!    in `main.zig` and fed straight to `vkCreateWaylandSurfaceKHR` inside
//!    `Context.createSurface`. This is a REAL, not incidental, coupling: Vulkan's
//!    WSI extension for surface creation is platform-specific by construction
//!    (`VK_KHR_wayland_surface` vs `VK_KHR_xcb_surface` vs `VK_KHR_win32_surface`
//!    — there is no backend-neutral "create a surface" call in Vulkan itself).
//!    `SurfaceSource`'s two `*anyopaque` fields already erase the WAYLAND
//!    TYPES (`*c.wl_display`/`*c.wl_surface`) down to opaque pointers, so
//!    `gfx/context.zig` itself doesn't `@cImport` wayland-client.h — but the
//!    SHAPE (exactly two pointers) is still wayland's shape; an X11 platform
//!    would need `{ display: *anyopaque, drawable: c_ulong }` (a `Display*` +
//!    an `xcb_window_t`/`Window`, not two pointers), which `SurfaceSource`
//!    cannot express without becoming a tagged union keyed by platform. NOT
//!    fixed here — doing it honestly needs a second platform to design
//!    against (guessing the shape now risks guessing wrong) — **W-later**,
//!    tracked for whichever of X/terminal/browser/macOS lands first (a
//!    terminal has no Vulkan surface at all, which is its own argument for a
//!    tagged union over a fixed struct).
//! 2. **`app/dispatch.zig:dispatchKey` reached into `wayland.c` directly**
//!    (`c.xkb_keysym_get_name`) to turn a `KeyEvent.keysym` into a name for
//!    `core.Keymap.keyspec` — a platform-neutral file (shared by the real
//!    compositor path AND, through `dispatchSpec`, every headless/e2e
//!    keypress) reaching past `Window`'s public surface into its raw C
//!    internals. FIXED (trivially — no behavior change): `Window` now
//!    exports `keysymName(buf, keysym) []const u8`, and `dispatchKey` calls
//!    that instead of importing `wayland.c`. See `wayland.zig`'s
//!    `keysymName` doc.
//! 3. **`KeyEvent`/`Mods` used to be DEFINED inside `wayland.zig`** — the
//!    "platform-neutral" key vocabulary `app/dispatch.zig` and every
//!    headless-suitable consumer names was nominally OWNED by the wayland
//!    module, so naming the type at all required importing wayland (and,
//!    transitively, its xkb/wayland-client `@cImport`). FIXED (trivially, a
//!    pure move + re-export, no behavior change): `KeyEvent`/`Mods` now live
//!    HERE (in the platform-seam file, dependency-free — no xkb, no C
//!    import), and `wayland.zig` re-exports them (`pub const KeyEvent =
//!    platform.KeyEvent;`) so every existing `wayland.KeyEvent`/`wayland.Mods`
//!    call site keeps compiling unchanged. `KeyEvent.keysym: u32` itself is
//!    STILL an xkb keysym numerically (X11/xkb's keysym space) — that is a
//!    real, un-fixed leak of platform vocabulary into what's meant to be the
//!    portable key-event shape (a terminal platform has no xkb keysyms to
//!    hand back). Fixing THAT needs a portable key-identity representation
//!    (a name/scancode enum every platform can produce) — genuinely not
//!    trivial, so it stays **W-later**, not patched here.

const std = @import("std");
pub const pointer = @import("pointer.zig");
pub const PointerEvent = pointer.PointerEvent;
pub const clipboard = @import("clipboard.zig");

/// One raw modifier state, sampled at key-event time. Portable in principle
/// (every platform this doc anticipates has some notion of ctrl/alt/shift/
/// super) — kept here, not in `wayland.zig`, so naming it needs no wayland
/// import (see leak #3 above).
pub const Mods = packed struct {
    ctrl: bool = false,
    alt: bool = false,
    shift: bool = false,
    logo: bool = false,
};

/// One translated keyboard event, in press order — the shape
/// `nextKeyEvent` returns and `app/dispatch.zig:dispatchKey` consumes.
/// `keysym` is STILL xkb-flavored (leak #3's un-fixed half): it is the raw
/// `xkb_keysym_t` `wayland.zig`'s keyboard listener produced, not yet a
/// platform-neutral key identity. `utf8`/`utf8_len`/`mods`/`pressed` are
/// portable as written.
pub const KeyEvent = struct {
    keysym: u32,
    utf8: [8]u8 = @splat(0),
    utf8_len: u8 = 0,
    mods: Mods = .{},
    pressed: bool,

    pub fn text(self: *const KeyEvent) []const u8 {
        return self.utf8[0..self.utf8_len];
    }
};

/// Verify `T` implements the Platform contract enumerated above: the
/// lifecycle/query/event methods, plus the two directly-sampled handles.
/// Deliberately duck-typed (decl-by-name + "is a function"/"field exists"),
/// not signature-exact — pinning exact parameter/field TYPES here would
/// falsely claim the seam already abstracts over e.g. the native
/// display/surface handle shape, which it does not yet (see leak #1).
pub fn assertPlatform(comptime T: type) void {
    if (@typeInfo(T) != .@"struct") @compileError(@typeName(T) ++ ": a Platform must be a struct");
    inline for (.{
        "init",
        "deinit",
        "fd",
        "pumpEvents",
        "shouldClose",
        "framebufferSize",
        "consumeResized",
        "bufferScale",
        "nextKeyEvent",
        "nextPointerEvent",
        "repeatDueNs",
        // keysymName: consumed by dispatch (which-key labels). A non-xkb
        // platform names its own key identities — entangled with the
        // W-later keysym-as-xkb-u32 leak (see KeyEvent.keysym's doc), but a
        // second impl must still provide SOME naming, so it's contract.
        "keysymName",
        "clipboardText",
        "clipboardSet",
        "clipboardFd",
    }) |name| {
        if (!@hasDecl(T, name)) @compileError(@typeName(T) ++ ": missing Platform method `" ++ name ++ "`");
        if (@typeInfo(@TypeOf(@field(T, name))) != .@"fn") @compileError(@typeName(T) ++ ": `" ++ name ++ "` must be a function");
    }
    inline for (.{
        "display",
        "surface",
    }) |name| {
        if (!@hasField(T, name)) @compileError(@typeName(T) ++ ": missing Platform field `" ++ name ++ "`");
    }
}

/// P3's closure proof (doc/rendering.md P3, item 3): a compile-time-only
/// second impl — never instantiated, never wired into any build option or
/// runtime path — that typechecks against `assertPlatform`. Its method
/// bodies are unreachable; the only claim it makes is that the contract
/// above is satisfiable by something that is NOT `wayland.Window` (zero
/// wayland-client/xkb dependency: it doesn't even import `wayland.zig`),
/// i.e. that nothing wayland-specific leaked into the contract itself. A
/// real headless/terminal platform is future work (doc/rendering.md P3 is
/// explicit: "Non-goals: actual... terminal... implementations") — this is
/// the seam test, not that work.
const HeadlessPlatformSkeleton = struct {
    fb_w: u32 = 0,
    fb_h: u32 = 0,
    display: usize = 0, // stand-in "native handle" — any type satisfies @hasField
    surface: usize = 0,
    gestures: pointer.Gestures = .{},
    /// No desktop: the clipboard is this store (see `clipboardSet`).
    clip: clipboard.Store = .{},

    fn init(width: u32, height: u32, title: [*:0]const u8, app_id: [*:0]const u8) !*HeadlessPlatformSkeleton {
        _ = .{ width, height, title, app_id };
        unreachable; // never called — typecheck-only, see module doc
    }
    fn deinit(self: *HeadlessPlatformSkeleton) void {
        _ = self;
    }
    fn fd(self: *const HeadlessPlatformSkeleton) i32 {
        _ = self;
        return -1;
    }
    fn pumpEvents(self: *HeadlessPlatformSkeleton) void {
        _ = self;
    }
    fn shouldClose(self: *const HeadlessPlatformSkeleton) bool {
        _ = self;
        return true;
    }
    fn framebufferSize(self: *const HeadlessPlatformSkeleton) [2]u32 {
        return .{ self.fb_w, self.fb_h };
    }
    fn consumeResized(self: *HeadlessPlatformSkeleton) bool {
        _ = self;
        return false;
    }
    fn bufferScale(self: *const HeadlessPlatformSkeleton) u32 {
        _ = self;
        return 1;
    }
    fn nextKeyEvent(self: *HeadlessPlatformSkeleton) ?KeyEvent {
        _ = self;
        return null;
    }
    fn nextPointerEvent(self: *HeadlessPlatformSkeleton) ?PointerEvent {
        return self.gestures.next();
    }
    fn keysymName(buf: []u8, keysym: u32) []const u8 {
        _ = buf;
        _ = keysym;
        return "";
    }
    fn clipboardText(self: *const HeadlessPlatformSkeleton) []const u8 {
        return self.clip.text();
    }
    fn clipboardSet(self: *HeadlessPlatformSkeleton, bytes: []const u8) void {
        self.clip.set(std.heap.c_allocator, bytes) catch {};
    }
    fn clipboardFd(self: *const HeadlessPlatformSkeleton) i32 {
        _ = self;
        return -1;
    }
    fn repeatDueNs(self: *const HeadlessPlatformSkeleton) ?u64 {
        _ = self;
        return null;
    }
};

comptime {
    assertPlatform(HeadlessPlatformSkeleton);
}

test "Platform seam: the skeleton typechecks (compile-time only)" {
    comptime assertPlatform(HeadlessPlatformSkeleton);
}

/// The ONE platform compiled in. Selecting a different one is a build-time
/// decision (there is no `-Dplatform` flag today); consumers reach it through
/// this module root rather than by relative path into the implementation, so
/// the contract above is the only thing between them and it.
pub const wayland = @import("wayland.zig");

test {
    // resize.zig is reached only THROUGH wayland.zig, and a file being
    // imported for its types does not put its tests in the binary — these
    // five configure-reducer tests had never run. A module owns its tests.
    _ = @import("resize.zig");
    _ = pointer;
    _ = clipboard;
    _ = wayland;
}
