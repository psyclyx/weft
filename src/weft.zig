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
pub const app_collab = @import("app/collab.zig");

// This module OWNS the core/gfx/app tree, so it also runs their display-free
// unit tests (moved here from src/tests.zig — those files can only belong to one
// module, and this is it). The e2e module imports this one and adds the driven
// end-to-end tests on top.
const std = @import("std");
test {
    std.testing.refAllDecls(core); // the core ABI + its property tests
    _ = @import("core/tests.zig");
    _ = @import("core/markdown.zig");
    _ = @import("core/identity.zig");
    _ = @import("gfx/stats.zig");
    _ = @import("gfx/layout.zig");
    _ = view;
    _ = gfx_harness;
    _ = region;
    _ = window_layout;
    _ = @import("app/frame.zig"); // which-key menu-overlay timing
}
