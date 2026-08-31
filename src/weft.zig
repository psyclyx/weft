//! weft — internal barrel module. Re-exports the app's core + gfx + app trees as
//! ONE named module so a consumer in a subdirectory (the e2e harness under
//! src/e2e/) imports `@import("weft")` instead of reaching up across the tree
//! with `../core/...`. Living at `src/` means these imports carry no `../`
//! themselves, and everything routed through this one module shares a single
//! `core` instance (no cross-module type duplication). Wired in build.zig.

pub const core = @import("weft_core");
pub const semantic_model = @import("weft_semantic");
pub const view_runtime = @import("weft_view_runtime");
pub const target_runtime = @import("weft_target_runtime");
pub const fs = @import("weft_fs");
pub const font_provider = @import("weft_font_provider");
pub const scene = @import("weft_scene");
pub const text_engine = @import("weft_text");
pub const view = @import("weft_gfx").view;
pub const gfx_harness = @import("weft_gfx").harness;
pub const region = @import("weft_gfx").region;
pub const window_layout = @import("weft_gfx").window_layout;
pub const window_cmds = @import("app/window_cmds.zig");
pub const dispatch = @import("app/dispatch.zig"); // the general keypress interface
pub const app_session = @import("app/session.zig");
pub const app_providers = @import("app/providers.zig");
pub const app_buffers_cmds = @import("app/buffers_cmds.zig");
pub const app_collab = @import("app/collab.zig");
pub const app_collab_cmds = @import("app/collab_cmds.zig");
pub const app_collab_presets = @import("app/collab_presets.zig");
pub const app_application = @import("app/application.zig");
pub const app_frame = @import("app/frame.zig");
pub const app_frame_builder = @import("app/frame_builder.zig");
pub const app_render_memory = @import("app/render_memory.zig");
pub const app_headless_vulkan = @import("app/headless_vulkan.zig");
pub const dap_js = @embedFile("dap_js");
pub const acp_js = @embedFile("acp_js");

// This module OWNS the core/gfx/app tree, so it also runs their display-free
// unit tests (moved here from src/tests.zig — those files can only belong to one
// module, and this is it). The e2e module imports this one and adds the driven
// end-to-end tests on top.
const std = @import("std");
test {
    // core, gfx, scene, text and platform each run their own tests in their own
    // binary now (build.zig) — a module's tests do not ride along in a
    // dependent's, so listing them here would be decoration, not coverage.
    // What remains is what this module still OWNS: the app tree.
    _ = @import("app/frame.zig"); // which-key menu-overlay timing
    _ = @import("app/frame_builder.zig"); // rendering P2: caret-surface auto-expiry
    _ = app_render_memory;
    _ = app_collab_presets; // §13.6 preset grant bundles: echo derives from bundle values only
    _ = @import("app/config_load.zig"); // W4 slice 4: the production plugin/grant-table loader
    _ = app_providers; // the `grammar-add` arity gate (its DynLib.open must stay guest-unreachable)
    // Platform seam contract tests remain display-free.
    _ = @import("weft_platform");
}
