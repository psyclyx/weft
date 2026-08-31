//! `gfx` — the editor's VIEW layer: the code that turns editor state into
//! drawable items, plus the window geometry, frame accounting and offscreen
//! targets around it.
//!
//! This sits ABOVE core, not beside it. The genuinely platform-independent
//! graphics pieces — the scene vocabulary, text shaping, font resolution and
//! the Skia binding — are their own modules (`weft_scene`, `weft_text`,
//! `weft_font_provider`, `weft_skia`) precisely because they know nothing about
//! an editor; everything left here does. `View` reads buffers, `window_layout`
//! knows panes and heads, `stats` measures keystroke latency.
//!
//! The public surface is deliberately small: eight names, which is what app/
//! and main.zig actually reach for. Everything under `view/` is reached through
//! `view`, whose own root curates it.

/// Editor state to draw items — the dominant type, and its satellites
/// (`Hud`, `Theme`, `Built`, `Run`, `Rect`). See `view.zig`.
pub const view = @import("view.zig");

/// Panes, heads, and the slot table a window is split into.
pub const window_layout = @import("window_layout.zig");

/// Rectangles and the damage geometry shared across the frame path.
pub const region = @import("region.zig");

/// Frame and keystroke-latency accounting — the rings the 60fps gate reads.
pub const stats = @import("stats.zig");

/// Text block layout used by the view's line building.
pub const layout = @import("layout.zig");

/// The display-free rendering harness the e2e suite and offscreen heads drive.
pub const harness = @import("harness.zig");

/// Offscreen Vulkan target: ordinary images, no WSI or compositor.
pub const headless_vulkan = @import("headless_vulkan.zig");

/// The on-screen Vulkan context bound to a platform surface.
pub const context = @import("context.zig");

test {
    // A module owns its tests. These were listed in src/weft.zig's test block
    // while gfx was compiled into that module; `refAllDecls` does not reach a
    // file's tests, so each one that has them is named.
    const std = @import("std");
    std.testing.refAllDecls(@This());
    _ = @import("stats.zig");
    _ = @import("layout.zig");
    _ = view;
    _ = harness;
    _ = region;
    _ = window_layout;
}
