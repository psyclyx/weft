//! OpenGL on macOS: `Window` is an NSOpenGLContext on the window's content
//! view, `Offscreen` a CGL context with no drawable — both behind the C ABI
//! in `cocoa.h`, implemented in `cocoa.m` (AppKit is Objective-C, and its
//! headers check that file at compile time).

comptime {
    if (@import("builtin").os.tag != .macos) @compileError("gl/cocoa.zig is macOS-only");
}

const platform = @import("weft_platform");
const root = @import("root.zig");

const c = @cImport(@cInclude("cocoa.h"));

fn getProc(ctx: ?*anyopaque, name: [*:0]const u8) callconv(.c) ?*const fn () callconv(.c) void {
    return c.weft_gl_get_proc(ctx, name);
}

/// `glFinish` through the same lookup Skia uses; teardown and idle only.
fn glFinish() void {
    const finish: ?*const fn () callconv(.c) void = getProc(null, "glFinish");
    if (finish) |f| f();
}

/// A GL context presenting to a Cocoa window's content view.
pub const Window = struct {
    gl: *c.WeftGlView,
    stencil_bits: u32,

    pub fn init(source: platform.SurfaceSource, width: u32, height: u32) !Window {
        // The drawable is the view itself, sized by AppKit at the view's
        // backing resolution: the requested size is the view's already.
        _ = .{ width, height };
        const view = switch (source) {
            .cocoa => |cocoa| cocoa.view,
            else => return error.UnsupportedSurface,
        };
        var stencil_bits: u32 = 0;
        const gl = c.weft_gl_view_create(view, &stencil_bits) orelse return error.NsOpenGlContextFailed;
        return .{ .gl = gl, .stencil_bits = stencil_bits };
    }

    pub fn deinit(self: *Window) void {
        c.weft_gl_view_destroy(self.gl);
        self.* = undefined;
    }

    pub fn makeCurrent(self: *Window) !void {
        c.weft_gl_view_make_current(self.gl);
    }

    /// The view changed size or scale: re-fit the drawable to it.
    pub fn resize(self: *Window, width: u32, height: u32) void {
        _ = .{ width, height };
        c.weft_gl_view_update(self.gl);
    }

    pub fn swapBuffers(self: *Window) !void {
        c.weft_gl_view_swap(self.gl);
    }

    pub fn stencilBits(self: *const Window) u32 {
        return self.stencil_bits;
    }

    pub fn proc(_: *const Window) root.Proc {
        return .{ .get = getProc };
    }

    pub fn finish(self: *Window) void {
        self.makeCurrent() catch return;
        glFinish();
    }
};

/// A GL context with no drawable: Skia renders into its own targets.
pub const Offscreen = struct {
    gl: *c.WeftGlOffscreen,

    pub fn init() !Offscreen {
        return .{ .gl = c.weft_gl_offscreen_create() orelse return error.CglContextFailed };
    }

    pub fn deinit(self: *Offscreen) void {
        c.weft_gl_offscreen_destroy(self.gl);
        self.* = undefined;
    }

    pub fn makeCurrent(self: *Offscreen) !void {
        c.weft_gl_offscreen_make_current(self.gl);
    }

    pub fn proc(_: *const Offscreen) root.Proc {
        return .{ .get = getProc };
    }

    pub fn finish(self: *Offscreen) void {
        self.makeCurrent() catch return;
        glFinish();
    }
};

test "an offscreen context comes up and resolves GL" {
    var gl = try Offscreen.init();
    defer gl.deinit();
    const p = gl.proc();
    const std = @import("std");
    try std.testing.expect(p.get(p.ctx, "glGetString") != null);
    try std.testing.expect(p.get(p.ctx, "glFinish") != null);
    gl.finish();
}
