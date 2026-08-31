//! weft — internal barrel module. Names the app's subsystems as ONE module so
//! the e2e suite under src/e2e/ imports `@import("weft")` rather than reaching
//! across the tree with `../core/...`. Living at `src/` means these imports
//! carry no `../` themselves, and everything routed through here shares one
//! instance of each module (no cross-module type duplication). Wired in
//! build.zig.
//!
//! Every name below is now a real module edge. This file used to flatten twelve
//! app files into `app_`-prefixed decls, because src/app/ was the one subsystem
//! with no root of its own — the prefix WAS the missing facade. It has one now.

pub const core = @import("weft_core");
pub const app = @import("weft_app");
pub const gfx = @import("weft_gfx");
pub const platform = @import("weft_platform");
pub const semantic_model = @import("weft_semantic");
pub const view_runtime = @import("weft_view_runtime");
pub const target_runtime = @import("weft_target_runtime");
pub const fs = @import("weft_fs");
pub const font_provider = @import("weft_font_provider");
pub const scene = @import("weft_scene");
pub const text_engine = @import("weft_text");

// Frequently-named leaves, kept as direct aliases so the e2e call sites that
// use them most read `view.X` rather than `gfx.view.X`.
pub const view = gfx.view;
pub const gfx_harness = gfx.harness;
pub const region = gfx.region;
pub const window_layout = gfx.window_layout;
pub const dispatch = app.dispatch; // the general keypress interface
pub const window_cmds = app.window_cmds;

pub const dap_js = @embedFile("dap_js");
pub const acp_js = @embedFile("acp_js");

// core, gfx, scene, text, platform and app each run their own tests in their
// own binary now (build.zig): a module's tests do not ride along in a
// dependent's, so listing them here would be decoration, not coverage. This
// module owns no source of its own — the e2e suite imports it and adds the
// driven end-to-end tests on top.
