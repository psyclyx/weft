//! `weft_gl` — OpenGL contexts: the one place weft talks to a platform's GL
//! binding (EGL on Linux, NSOpenGL/CGL on macOS), the way `weft_vk` is the
//! one place it imports Vulkan.
//!
//! weft never calls GL itself. Skia's Ganesh backend does all the drawing,
//! through entry points it resolves with `Proc` — so what a platform owes this
//! module is a context, a way to make it current, a drawable that follows the
//! window's size, a buffer swap, and proc lookup. Exactly that is what both
//! context types expose:
//!
//! - `Window`: a context presenting to a platform window, created from the
//!   window's `platform.SurfaceSource`. Its default framebuffer (0) is the
//!   window's back buffer: Skia draws straight into it and `swapBuffers`
//!   presents it.
//! - `Offscreen`: a context with no drawable at all — headless rendering,
//!   where Skia draws into its own render target and the caller reads it
//!   back.
//!
//! Both contexts are desktop OpenGL 3.2+ core profile, on every platform:
//! macOS offers nothing else, and asking Linux for the same profile keeps the
//! Linux test suite exercising the GL path a Mac runs.
//!
//! Presentation is never throttled by the driver (swap interval 0). weft draws
//! only when something changed and its frame loop must never block on the GPU
//! (doc/contextual-workspace-architecture.md §7); the compositor — Wayland's,
//! or the macOS window server — already composites without tearing.

const builtin = @import("builtin");

/// One GL entry point by name, resolved in the current context: the shape
/// Skia's `GrGLGetProc` takes (`ctx` is passed back verbatim).
pub const GetProc = *const fn (ctx: ?*anyopaque, name: [*:0]const u8) callconv(.c) ?*const fn () callconv(.c) void;

/// What Skia needs to resolve GL: the lookup and its context argument.
pub const Proc = struct {
    get: GetProc,
    ctx: ?*anyopaque = null,
};

const native = switch (builtin.os.tag) {
    .linux => @import("egl.zig"),
    .macos => @import("cocoa.zig"),
    else => @compileError("weft_gl: no OpenGL binding for " ++ @tagName(builtin.os.tag)),
};

pub const Window = native.Window;
pub const Offscreen = native.Offscreen;

/// The contract both implementations meet, checked where they are chosen.
fn assertContext(comptime T: type, comptime methods: []const []const u8) void {
    inline for (methods) |name| {
        if (!@hasDecl(T, name)) @compileError(@typeName(T) ++ ": missing GL context method `" ++ name ++ "`");
    }
}

comptime {
    const common = .{ "deinit", "makeCurrent", "proc", "finish" };
    assertContext(Window, &(common ++ .{ "init", "resize", "swapBuffers", "stencilBits" }));
    assertContext(Offscreen, &(common ++ .{"init"}));
}

test {
    _ = native;
}
