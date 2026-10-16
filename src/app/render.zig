//! Production renderer facade: the shared `FrameBuilder` + Skia on the GPU
//! API this build targets (`-Dgpu`). Both serve the desktop window and the
//! standard offscreen target through the same `init`/`buildFrame`/`present`.
pub const RenderState = switch (@import("weft_gfx").gpu) {
    .vulkan => @import("render_vulkan.zig").RenderState,
    .opengl => @import("render_gl.zig").RenderState,
};
