//! Renderer dispatch. `main()` holds one `RenderState`; which backend it is
//! (the snail_vk analytic-glyph GPU renderer, or Skia) is chosen at build time
//! by `-Drenderer` and resolved here as a comptime switch. Only the selected
//! backend's file is imported, so the other is never analyzed — the mutual
//! exclusivity requirement 1 asks for (a snail build pulls no Skia, and a Skia
//! build pulls no snail_vk pipeline/shaders).
//!
//! Both backends expose the same surface `main()` drives — `init(gpa, ctx,
//! font_bytes, em, active_id)`, `buildFrame(fx, act)`, `present(ctx, fb,
//! frame_start, had_input)`, `deinit()` — and embed the shared, backend-neutral
//! `FrameBuilder` as `.fb` (its `.view` / `.win_layout` are what `main()`
//! aliases). The seam between them is the per-pane draw content: the snail
//! backend feeds `built_panes[*].shapes` to its own pipeline, the Skia backend
//! decodes those same shapes into SkCanvas glyph/rect draws.

const build_options = @import("build_options");
const rasterizer = @import("rasterizer.zig");

pub const RenderState = switch (build_options.renderer) {
    .snail => @import("render_snail.zig").RenderState,
    .skia => @import("render_skia.zig").RenderState,
};

// P3 (doc/rendering.md): whichever backend the switch above selected is
// checked against the Rasterizer contract HERE, at the seam — see
// `rasterizer.zig`'s module doc for the full contract + the comptime-vs-
// vtable rationale. Asserting only the selected type (not both
// unconditionally) preserves the mutual-exclusivity this file's own doc
// comment requires: a snail build must never analyze skia, and vice versa.
comptime {
    rasterizer.assertRasterizer(RenderState);
}
