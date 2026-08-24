//! weft — internal barrel module. Re-exports the app's core + gfx + app trees as
//! ONE named module so a consumer in a subdirectory (the e2e harness under
//! src/e2e/) imports `@import("weft")` instead of reaching up across the tree
//! with `../core/...`. Living at `src/` means these imports carry no `../`
//! themselves, and everything routed through this one module shares a single
//! `core` instance (no cross-module type duplication). Wired in build.zig.

pub const core = @import("core/core.zig");
pub const view = @import("gfx/view.zig");
pub const gfx_harness = @import("gfx/harness.zig");
pub const region = @import("gfx/region.zig");
pub const window_layout = @import("gfx/window_layout.zig");
pub const window_cmds = @import("app/window_cmds.zig");
pub const dispatch = @import("app/dispatch.zig"); // the general keypress interface
pub const app_session = @import("app/session.zig");
pub const app_providers = @import("app/providers.zig");
pub const app_buffers_cmds = @import("app/buffers_cmds.zig");
pub const app_collab = @import("app/collab.zig");
pub const app_frame_builder = @import("app/frame_builder.zig");

// This module OWNS the core/gfx/app tree, so it also runs their display-free
// unit tests (moved here from src/tests.zig — those files can only belong to one
// module, and this is it). The e2e module imports this one and adds the driven
// end-to-end tests on top.
const std = @import("std");
test {
    std.testing.refAllDecls(core); // the core ABI + its property tests
    _ = @import("core/target_open.zig");
    _ = @import("core/tests.zig");
    _ = @import("core/markdown.zig");
    _ = @import("core/identity.zig");
    _ = @import("core/facts.zig");
    _ = @import("core/container.zig");
    _ = @import("gfx/stats.zig");
    _ = @import("gfx/layout.zig");
    _ = view;
    _ = gfx_harness;
    _ = region;
    _ = window_layout;
    _ = @import("app/frame.zig"); // which-key menu-overlay timing
    _ = @import("app/frame_builder.zig"); // rendering P2: caret-surface auto-expiry
    _ = @import("app/config_load.zig"); // W4 slice 4: the production plugin/grant-table loader
    // P3 (doc/rendering.md): the Rasterizer/Platform seam contracts + their
    // compile-time-only skeleton proofs. Neither needs Vulkan/wayland to
    // typecheck (see each file's module doc), so they run under the
    // display-free `test` step too, not only the windowed exe build.
    _ = @import("app/rasterizer.zig");
    _ = @import("platform/platform.zig");
}
