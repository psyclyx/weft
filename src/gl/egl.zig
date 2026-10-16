//! EGL: OpenGL contexts on Linux. A window context presents to a Wayland
//! surface through `wl_egl_window`; an offscreen one has no surface at all
//! (Mesa's surfaceless platform, an EGL device, or the default display — the
//! first a driver offers).

comptime {
    if (@import("builtin").os.tag != .linux) @compileError("gl/egl.zig is Linux-only");
}

const std = @import("std");
const platform = @import("weft_platform");
const root = @import("root.zig");

pub const c = @cImport({
    // No Xlib: weft's only Linux window system is Wayland, so the native
    // display/window types are the opaque pointers EGL falls back to.
    @cDefine("EGL_NO_X11", "1");
    @cInclude("EGL/egl.h");
    @cInclude("EGL/eglext.h");
    @cInclude("wayland-egl.h");
});

const log = std.log.scoped(.gl);

fn eglError(comptime what: []const u8) error{EglFailed} {
    log.err(what ++ " failed: EGL error 0x{x}", .{c.eglGetError()});
    return error.EglFailed;
}

/// Desktop GL 3.2 core (see root.zig for why every platform asks for this).
/// Requires EGL 1.5 or EGL_KHR_create_context; `createContext` falls back to
/// whatever the driver's default context is if refused.
const core_context = [_]c.EGLint{
    c.EGL_CONTEXT_MAJOR_VERSION,       3,
    c.EGL_CONTEXT_MINOR_VERSION,       2,
    c.EGL_CONTEXT_OPENGL_PROFILE_MASK, c.EGL_CONTEXT_OPENGL_CORE_PROFILE_BIT,
    c.EGL_NONE,
};

/// EGL hands out ONE display per native display per process, and its
/// `eglInitialize`/`eglTerminate` do not count: a second context on the same
/// display (two headless heads on Mesa's surfaceless platform get the same
/// one) would have the display terminated out from under it by the first's
/// teardown. So initialization is counted here and the last close
/// terminates. GL contexts in weft live on one thread — Skia requires its
/// context current on the calling thread — so the count needs no lock.
const initialized = struct {
    var displays: [8]c.EGLDisplay = @splat(c.EGL_NO_DISPLAY);
    var refs: [8]usize = @splat(0);

    fn acquire(display: c.EGLDisplay) !struct { major: c.EGLint, minor: c.EGLint } {
        var major: c.EGLint = 0;
        var minor: c.EGLint = 0;
        // Initializing an initialized display is a no-op that reports its version.
        if (c.eglInitialize(display, &major, &minor) != c.EGL_TRUE) return eglError("eglInitialize");
        const slot = for (&displays, 0..) |*d, i| {
            if (d.* == display) break i;
        } else for (&displays, 0..) |*d, i| {
            if (d.* == c.EGL_NO_DISPLAY) {
                d.* = display;
                break i;
            }
        } else return error.EglTooManyDisplays;
        refs[slot] += 1;
        return .{ .major = major, .minor = minor };
    }

    fn release(display: c.EGLDisplay) void {
        for (&displays, &refs) |*d, *n| {
            if (d.* != display) continue;
            n.* -= 1;
            if (n.* == 0) {
                d.* = c.EGL_NO_DISPLAY;
                _ = c.eglTerminate(display);
            }
            return;
        }
    }
};

/// An initialized display with desktop GL bound and one chosen config.
const Display = struct {
    display: c.EGLDisplay,
    config: c.EGLConfig,

    fn open(native: c.EGLDisplay, surface_type: c.EGLint) !Display {
        if (native == c.EGL_NO_DISPLAY) return error.EglNoDisplay;
        const version = try initialized.acquire(native);
        errdefer initialized.release(native);
        if (c.eglBindAPI(c.EGL_OPENGL_API) != c.EGL_TRUE) return eglError("eglBindAPI(OpenGL)");

        // RGBA8, no depth (Skia keeps none for 2D), 8 bits of stencil: Skia
        // fills paths through the stencil buffer when it has one.
        const attribs = [_]c.EGLint{
            c.EGL_SURFACE_TYPE,    surface_type,
            c.EGL_RENDERABLE_TYPE, c.EGL_OPENGL_BIT,
            c.EGL_RED_SIZE,        8,
            c.EGL_GREEN_SIZE,      8,
            c.EGL_BLUE_SIZE,       8,
            c.EGL_ALPHA_SIZE,      8,
            c.EGL_STENCIL_SIZE,    8,
            c.EGL_NONE,
        };
        var config: c.EGLConfig = null;
        var count: c.EGLint = 0;
        if (c.eglChooseConfig(native, &attribs, &config, 1, &count) != c.EGL_TRUE) return eglError("eglChooseConfig");
        if (count < 1) return error.EglNoConfig;
        log.info("EGL {d}.{d}: {s}", .{ version.major, version.minor, if (c.eglQueryString(native, c.EGL_VENDOR)) |v| std.mem.span(v) else "?" });
        return .{ .display = native, .config = config };
    }

    fn close(self: Display) void {
        initialized.release(self.display);
    }

    fn createContext(self: Display) !c.EGLContext {
        const context = c.eglCreateContext(self.display, self.config, c.EGL_NO_CONTEXT, &core_context);
        if (context != c.EGL_NO_CONTEXT) return context;
        log.warn("no GL 3.2 core context (EGL error 0x{x}); using the driver's default", .{c.eglGetError()});
        const fallback = c.eglCreateContext(self.display, self.config, c.EGL_NO_CONTEXT, null);
        if (fallback == c.EGL_NO_CONTEXT) return eglError("eglCreateContext");
        return fallback;
    }

    fn stencilBits(self: Display) u32 {
        var bits: c.EGLint = 0;
        _ = c.eglGetConfigAttrib(self.display, self.config, c.EGL_STENCIL_SIZE, &bits);
        return @intCast(@max(bits, 0));
    }

    fn hasExtension(display: c.EGLDisplay, name: []const u8) bool {
        const list = c.eglQueryString(display, c.EGL_EXTENSIONS);
        if (list == null) return false;
        var it = std.mem.tokenizeScalar(u8, std.mem.span(list), ' ');
        while (it.next()) |ext| if (std.mem.eql(u8, ext, name)) return true;
        return false;
    }
};

fn getProc(_: ?*anyopaque, name: [*:0]const u8) callconv(.c) ?*const fn () callconv(.c) void {
    return @ptrCast(c.eglGetProcAddress(name));
}

/// Leave no context current if `context` is — but never release ANOTHER
/// context (a second head's) that happens to be current instead.
fn releaseIfCurrent(display: c.EGLDisplay, context: c.EGLContext) void {
    if (c.eglGetCurrentContext() == context)
        _ = c.eglMakeCurrent(display, c.EGL_NO_SURFACE, c.EGL_NO_SURFACE, c.EGL_NO_CONTEXT);
}

/// `glFinish`, resolved once per call site; teardown and idle paths only.
fn glFinish() void {
    const finish: ?*const fn () callconv(.c) void = getProc(null, "glFinish");
    if (finish) |f| f();
}

/// A GL context presenting to a Wayland surface.
pub const Window = struct {
    egl: Display,
    context: c.EGLContext,
    native: *c.struct_wl_egl_window,
    surface: c.EGLSurface,

    pub fn init(source: platform.SurfaceSource, width: u32, height: u32) !Window {
        const wl = switch (source) {
            .wayland => |wl| wl,
            else => return error.UnsupportedSurface,
        };
        const egl = try Display.open(c.eglGetPlatformDisplay(c.EGL_PLATFORM_WAYLAND_KHR, wl.display, null), c.EGL_WINDOW_BIT);
        errdefer egl.close();
        const context = try egl.createContext();
        errdefer _ = c.eglDestroyContext(egl.display, context);

        const native = c.wl_egl_window_create(@ptrCast(wl.surface), @intCast(@max(width, 1)), @intCast(@max(height, 1))) orelse
            return error.WaylandEglWindowFailed;
        errdefer c.wl_egl_window_destroy(native);
        const surface = c.eglCreatePlatformWindowSurface(egl.display, egl.config, native, null);
        if (surface == c.EGL_NO_SURFACE) return eglError("eglCreatePlatformWindowSurface");
        errdefer _ = c.eglDestroySurface(egl.display, surface);

        var self: Window = .{ .egl = egl, .context = context, .native = native, .surface = surface };
        try self.makeCurrent();
        // Never wait for the compositor's frame callback inside a swap: an
        // occluded surface gets none, and the frame loop would hang on it.
        if (c.eglSwapInterval(egl.display, 0) != c.EGL_TRUE) log.warn("eglSwapInterval(0) refused", .{});
        return self;
    }

    pub fn deinit(self: *Window) void {
        releaseIfCurrent(self.egl.display, self.context);
        _ = c.eglDestroySurface(self.egl.display, self.surface);
        c.wl_egl_window_destroy(self.native);
        _ = c.eglDestroyContext(self.egl.display, self.context);
        self.egl.close();
        self.* = undefined;
    }

    pub fn makeCurrent(self: *Window) !void {
        if (c.eglGetCurrentContext() == self.context and c.eglGetCurrentSurface(c.EGL_DRAW) == self.surface) return;
        if (c.eglMakeCurrent(self.egl.display, self.surface, self.surface, self.context) != c.EGL_TRUE)
            return eglError("eglMakeCurrent");
    }

    /// Size the drawable to the window's framebuffer. Takes effect at the next
    /// swap, which is the next frame drawn at this size.
    pub fn resize(self: *Window, width: u32, height: u32) void {
        c.wl_egl_window_resize(self.native, @intCast(width), @intCast(height), 0, 0);
    }

    pub fn swapBuffers(self: *Window) !void {
        if (c.eglSwapBuffers(self.egl.display, self.surface) != c.EGL_TRUE) return eglError("eglSwapBuffers");
    }

    pub fn stencilBits(self: *const Window) u32 {
        return self.egl.stencilBits();
    }

    pub fn proc(_: *const Window) root.Proc {
        return .{ .get = getProc };
    }

    /// Block until the GL pipeline drains (teardown, idle).
    pub fn finish(self: *Window) void {
        self.makeCurrent() catch return;
        glFinish();
    }
};

/// A GL context with no window: Skia renders into its own targets.
pub const Offscreen = struct {
    egl: Display,
    context: c.EGLContext,
    /// A 1x1 pbuffer when the display cannot make a context current without
    /// any surface (EGL_KHR_surfaceless_context); never drawn to.
    pbuffer: c.EGLSurface = c.EGL_NO_SURFACE,

    pub fn init() !Offscreen {
        const egl = try Display.open(offscreenDisplay(), c.EGL_PBUFFER_BIT);
        errdefer egl.close();
        const context = try egl.createContext();
        errdefer _ = c.eglDestroyContext(egl.display, context);
        var self: Offscreen = .{ .egl = egl, .context = context };
        if (!Display.hasExtension(egl.display, "EGL_KHR_surfaceless_context")) {
            const one = [_]c.EGLint{ c.EGL_WIDTH, 1, c.EGL_HEIGHT, 1, c.EGL_NONE };
            self.pbuffer = c.eglCreatePbufferSurface(egl.display, egl.config, &one);
            if (self.pbuffer == c.EGL_NO_SURFACE) return eglError("eglCreatePbufferSurface");
        }
        try self.makeCurrent();
        return self;
    }

    pub fn deinit(self: *Offscreen) void {
        releaseIfCurrent(self.egl.display, self.context);
        if (self.pbuffer != c.EGL_NO_SURFACE) _ = c.eglDestroySurface(self.egl.display, self.pbuffer);
        _ = c.eglDestroyContext(self.egl.display, self.context);
        self.egl.close();
        self.* = undefined;
    }

    pub fn makeCurrent(self: *Offscreen) !void {
        if (c.eglGetCurrentContext() == self.context) return;
        if (c.eglMakeCurrent(self.egl.display, self.pbuffer, self.pbuffer, self.context) != c.EGL_TRUE)
            return eglError("eglMakeCurrent");
    }

    pub fn proc(_: *const Offscreen) root.Proc {
        return .{ .get = getProc };
    }

    pub fn finish(self: *Offscreen) void {
        self.makeCurrent() catch return;
        glFinish();
    }

    /// The first display that needs no window system: Mesa's surfaceless
    /// platform, then the first EGL device (NVIDIA's path), then whatever the
    /// default display is.
    fn offscreenDisplay() c.EGLDisplay {
        const client = c.EGL_NO_DISPLAY; // client extensions are queried on no display
        if (Display.hasExtension(client, "EGL_MESA_platform_surfaceless")) {
            const d = c.eglGetPlatformDisplay(c.EGL_PLATFORM_SURFACELESS_MESA, c.EGL_DEFAULT_DISPLAY, null);
            if (d != c.EGL_NO_DISPLAY) return d;
        }
        if (Display.hasExtension(client, "EGL_EXT_platform_device")) {
            const QueryDevices = *const fn (c.EGLint, [*]c.EGLDeviceEXT, *c.EGLint) callconv(.c) c.EGLBoolean;
            if (getProc(null, "eglQueryDevicesEXT")) |raw| {
                const query: QueryDevices = @ptrCast(raw);
                var devices: [4]c.EGLDeviceEXT = undefined;
                var n: c.EGLint = 0;
                if (query(devices.len, &devices, &n) == c.EGL_TRUE and n > 0) {
                    const d = c.eglGetPlatformDisplay(c.EGL_PLATFORM_DEVICE_EXT, devices[0], null);
                    if (d != c.EGL_NO_DISPLAY) return d;
                }
            }
        }
        return c.eglGetDisplay(c.EGL_DEFAULT_DISPLAY);
    }
};

test "an offscreen context comes up and resolves GL" {
    var gl = Offscreen.init() catch |err| {
        // A box with no GL driver at all cannot run this; everything else must.
        log.warn("no offscreen GL here ({s}); skipping", .{@errorName(err)});
        return error.SkipZigTest;
    };
    defer gl.deinit();
    const p = gl.proc();
    try std.testing.expect(p.get(p.ctx, "glGetString") != null);
    try std.testing.expect(p.get(p.ctx, "glFinish") != null);
    gl.finish();
}
