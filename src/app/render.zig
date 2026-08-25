//! Production renderer facade. Skia consumes the renderer-neutral
//! `FrameBuilder` output for both desktop and standard offscreen Vulkan.
pub const RenderState = @import("render_skia.zig").RenderState;
