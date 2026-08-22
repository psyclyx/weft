//! P3 — the Rasterizer seam (doc/rendering.md P3: "formalize the backend +
//! platform seams... around snail_vk/skia/wayland (no behavior change)").
//! Rasterizer = consumes a laid-out scene (the positioned glyph runs/rects
//! the backend-independent `FrameBuilder` already produces — `gfx/view.Built`,
//! a `[]snail.Shape` per pane) and draws/presents it. This file names the
//! contract `render_snail.RenderState` and `render_skia.RenderState` ALREADY
//! share — `render.zig`'s own module doc has described this shape since the
//! renderer split; this pass makes it a checked contract instead of prose.
//!
//! ## comptime, not vtable
//! `app/render.zig`'s `RenderState` is a `switch (build_options.renderer)`
//! resolved at COMPILE time: a snail build never imports skia (or its C++
//! shim, SPIR-V, Ganesh), and vice versa — the module doc calls this out as
//! "requirement 1" (mutual exclusivity). Exactly one Rasterizer is ever
//! compiled in; `main.zig` never chooses between two live instances at
//! runtime, and there is no plan to (doc/rendering.md's phases add backends
//! one at a time, still selected at build time — webgpu enters the SAME
//! switch, not a runtime registry). A vtable buys indirection (a fn-pointer
//! call per method, one dynamic dispatch per frame at minimum) for
//! polymorphism nothing here exercises — paying it now would be "honest"
//! about a future that isn't the plan yet, and P3's own charter is "no
//! behavior change". `assertRasterizer` below gives the comptime interface
//! everything a vtable-based one would need to check STRUCTURALLY (the same
//! decl set, checked the same way) — so if a later phase genuinely needs two
//! LIVE backends in one binary (P3's doc: "needed only when two backends
//! live in one binary" — not proposed anywhere in doc/rendering.md today),
//! upgrading is mechanical: wrap `assertRasterizer`'s decl list in a
//! `fn table(comptime T: type) VTable` builder and store `*anyopaque` + that
//! table instead of a comptime type. The interface shape doesn't change,
//! only how it's dispatched.
//!
//! ## the decl surface, shared since the renderer split
//! - `init(self, gpa, ctx, font_bytes, em, active_id) !void` — builds every
//!   render resource IN PLACE (`self` already at its final address in
//!   `main()`'s frame — see `render_snail.RenderState.init`'s own doc). Takes
//!   a `*gfx.context.Context` (see "the Context leak", below).
//! - `buildFrame(self, fx, act) !void` — backend-independent; both backends'
//!   implementations are a ONE-LINE delegate to `self.fb.buildFrame(fx, act)`
//!   (`FrameBuilder`, `app/frame_builder.zig`) — this method exists on the
//!   Rasterizer at all only so `main.zig` has one call site regardless of
//!   backend, not because either backend does per-backend build work here.
//! - `present(self, ctx, fb, frame_start, had_input) !bool` — the ONLY
//!   method that touches the GPU/swapchain. Returns whether a frame was
//!   actually submitted (`false` ⇒ deferred, the scheduler's present-retry
//!   source tries again — see `app/loop_sources.zig`'s `PresentRetryCtx`).
//! - `deinit(self) void`.
//! - field `fb: FrameBuilder` — the backend-independent build every caller
//!   reaches through (`main.zig` aliases `render.fb.view`/`render.fb.win_layout`
//!   as `view`/`win_layout` locals it uses unchanged regardless of backend).
//!
//! `assertRasterizer` checks all four methods exist (by name + "is a
//! function") and that `fb`'s type is EXACTLY `FrameBuilder` — the one part
//! of the shape worth pinning precisely, since a Rasterizer that embedded
//! its own divergent build state would silently reintroduce the
//! per-backend-duplicated-layout bug the `FrameBuilder` extraction (predates
//! P3) fixed. Method PARAMETER types are deliberately left unchecked (decl-
//! by-name + arity-agnostic "is a fn") — see "the Context leak" below for why
//! pinning `present`'s second parameter to `*gfx.context.Context` here would
//! overclaim.
//!
//! ## the Context leak (not fixed — documented, W-later)
//! `present`'s second parameter is `*gfx.context.Context` — Vulkan-specific
//! (swapchain, command buffers, device/queue). That's fine for wayland+vulkan
//! as the one live impl, but it means the Rasterizer interface as it exists
//! TODAY bakes in "there is a Vulkan device to present through" — a
//! hypothetical terminal Rasterizer (doc/rendering.md: "a cell rasterizer:
//! boxes → box-drawing chars... lossy by nature") has no Vulkan context at
//! all and couldn't satisfy this literal signature. Genuinely fixing this
//! needs the "present surface" itself to become backend-neutral (an opaque
//! handle each Rasterizer downcasts, or `present` split into `draw(scene) →
//! framebuffer` + a separate platform-owned `presentFramebuffer` step) —
//! that's real design work doc/rendering.md explicitly defers ("Non-goals:
//! actual webgpu/X/terminal/browser/macOS implementations. This doc only
//! fixes the SEAM so they are additive."). Recorded here as the seam's one
//! open edge, not silently papered over by `assertRasterizer` pretending to
//! check a parameter type it doesn't.
//!
//! ## the CPU-raster harness — a rasterizer in disguise, at a NARROWER grain
//! `gfx/harness.zig` (test-only: "Display-free render harness — rasterizes a
//! `View` frame to an RGBA8 pixel buffer on the CPU (snail-raster)") turns
//! out to be a genuine THIRD "scene → pixels" implementation, structurally:
//! its `rasterize()` does exactly what `render_snail.RenderState.present`'s
//! GPU half does — accumulate every pane's `[]snail.Shape` into ONE
//! `records.Instance`/`records.DrawBatch` stream via `snail.emit.emit` (the
//! identical call `render_snail.emitBuiltPanes` makes), then hand that
//! stream to a `Renderer.draw` — except its `Renderer` is `snail-raster`'s
//! CPU rasterizer instead of `snail`'s Vulkan pipeline. Three independent
//! consumers (the Vulkan GPU pipeline, Skia's SkCanvas decode, and this CPU
//! rasterizer) all consume the IDENTICAL per-pane `[]snail.Shape` scene with
//! zero producer-side change — that's the seam (`FrameBuilder`/`view.build`)
//! proven three ways, not just asserted.
//!
//! It does NOT, however, satisfy `assertRasterizer` as a NAMED
//! `RenderState`-shaped impl, and forcing it to would be dishonest, not
//! illuminating: it has no `init`/`buildFrame`/`deinit` (tests call
//! `view.build` directly, then hand the built shapes to `rasterize()` — the
//! FrameBuilder step is the CALLER's job here, not this module's), and
//! critically it takes NO `Context` — that absence is exactly WHY it's
//! headless-capable (no Vulkan device, no Wayland surface, no compositor
//! needed to run `zig build test`). Its function-based shape is doing real
//! work: it satisfies the NARROWER, more honest job description in
//! doc/rendering.md's own words ("consumes a laid-out scene... and draws
//! it") while declining the WIDER `RenderState` contract's extra
//! responsibility (own a presentable surface + swapchain + present timing —
//! see "the Context leak" above). That the current interface conflates
//! those two jobs into one struct is itself the finding: a future
//! `draw(scene) → framebuffer` / `presentFramebuffer(ctx)` split (noted
//! above) would let `gfx/harness.zig`'s `rasterize()` become a literal,
//! named `draw` impl with no further change — not attempted here, since
//! P3's charter is extraction with no behavior change, not a redesign.

const std = @import("std");
const FrameBuilder = @import("frame_builder.zig").FrameBuilder;

/// Verify `T` implements the Rasterizer contract `render_snail.RenderState`/
/// `render_skia.RenderState` already share (see this file's module doc for
/// the full decl-by-decl rationale): the four lifecycle methods, plus the
/// one embedded field that MUST be exactly `FrameBuilder` — not merely
/// present, since a Rasterizer that grew its own divergent build state would
/// reintroduce the bug `FrameBuilder` exists to prevent.
pub fn assertRasterizer(comptime T: type) void {
    if (@typeInfo(T) != .@"struct") @compileError(@typeName(T) ++ ": a Rasterizer must be a struct");
    inline for (.{ "init", "buildFrame", "present", "deinit" }) |name| {
        if (!@hasDecl(T, name)) @compileError(@typeName(T) ++ ": missing Rasterizer method `" ++ name ++ "`");
        if (@typeInfo(@TypeOf(@field(T, name))) != .@"fn") @compileError(@typeName(T) ++ ": `" ++ name ++ "` must be a function");
    }
    if (!@hasField(T, "fb")) @compileError(@typeName(T) ++ ": a Rasterizer must embed the backend-independent build as field `fb`");
    if (@FieldType(T, "fb") != FrameBuilder) @compileError(@typeName(T) ++ ": field `fb` must be exactly `frame_builder.FrameBuilder` — the one backend-independent build every Rasterizer shares");
}

/// P3's closure proof (doc/rendering.md P3, item 3): a compile-time-only
/// second impl — never instantiated, never wired into `-Drenderer` or any
/// runtime path — that typechecks against `assertRasterizer`. Its method
/// bodies are unreachable; the only claim it makes is that the contract is
/// satisfiable by something that is NOT `render_snail.RenderState`/
/// `render_skia.RenderState` (no Vulkan, no Skia, no snail_vk pipeline
/// import at all), i.e. nothing backend-specific leaked into the contract
/// itself except the one open edge named above (the Context leak — this
/// skeleton sidesteps it by taking `*anyopaque`, which is legal precisely
/// BECAUSE `assertRasterizer` doesn't pin that parameter's type). A real
/// second backend (webgpu, a terminal cell rasterizer) is future work
/// (doc/rendering.md P3's non-goals); this is the seam test, not that work.
const NullRasterizer = struct {
    fb: FrameBuilder = undefined,

    fn init(self: *NullRasterizer, gpa: std.mem.Allocator, ctx: *anyopaque, font_bytes: []const u8, em: f32, active_id: u32) !void {
        _ = .{ self, gpa, ctx, font_bytes, em, active_id };
        unreachable; // never called — typecheck-only, see doc above
    }
    fn deinit(self: *NullRasterizer) void {
        _ = self;
    }
    fn buildFrame(self: *NullRasterizer, fx: *const anyopaque, act: u8) !void {
        _ = .{ self, fx, act };
        unreachable;
    }
    fn present(self: *NullRasterizer, ctx: *anyopaque, fb: [2]u32, frame_start: u64, had_input: bool) !bool {
        _ = .{ self, ctx, fb, frame_start, had_input };
        unreachable;
    }
};

comptime {
    assertRasterizer(NullRasterizer);
}

test "Rasterizer seam: the skeleton typechecks (compile-time only)" {
    comptime assertRasterizer(NullRasterizer);
}
