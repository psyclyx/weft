//! `app` — the editor assembled: the layer that owns a running weft.
//!
//! Everything below is a mechanism — core is the kernel, gfx draws, platform
//! carries windows and input. This is where they are wired into a program that
//! starts, keeps a session, dispatches keypresses, drives frames, and talks to
//! peers. It is the only layer allowed to know all three, which is why it is
//! the top of the enforced graph: nothing here is importable by core, gfx or
//! platform, and the build makes that a compile error rather than a rule.
//!
//! `main.zig` (the desktop binary) and `weft.zig` (the same program exposed to
//! the e2e suite) both reach the app through this root.

/// The application lifecycle: the one owner of input-to-frame sequencing,
/// shared by the desktop shell and display-free heads.
pub const application = @import("application.zig");

/// Keypress → command. The general dispatch door every platform goes through.
pub const dispatch = @import("dispatch.zig");

/// The app-level session: the one system the desktop binary runs, plus the
/// per-head UI state that is not core's.
pub const session = @import("session.zig");

/// Frame driving and the prepared-frame builder.
pub const frame = @import("frame.zig");
pub const frame_builder = @import("frame_builder.zig");

/// Command surfaces the app installs.
pub const window_cmds = @import("window_cmds.zig");
pub const buffers_cmds = @import("buffers_cmds.zig");
pub const collab_cmds = @import("collab_cmds.zig");

/// Collaboration wiring and its preset grant bundles.
pub const collab = @import("collab.zig");
pub const collab_presets = @import("collab_presets.zig");

/// Capability/syntax/LSP providers attached to a running system.
pub const providers = @import("providers.zig");

/// Startup: argument parsing, config loading, and system assembly.
pub const args = @import("args.zig");
pub const config_load = @import("config_load.zig");
pub const setup = @import("setup.zig");

/// Render targets and the head bound to one.
pub const render = @import("render.zig");
pub const render_memory = @import("render_memory.zig");
pub const headless_vulkan = @import("headless_vulkan.zig");
pub const window_head = @import("window_head.zig");

/// Event-loop sources, scrolling, caret configuration, and the shared
/// command-result handler.
pub const loop_sources = @import("loop_sources.zig");
pub const scroll = @import("scroll.zig");
pub const cursor_config = @import("cursor_config.zig");
pub const handler = @import("handler.zig");

test {
    // A module owns its tests. These were listed in src/weft.zig's test block
    // while app was compiled into that module.
    const std = @import("std");
    std.testing.refAllDecls(@This());
    _ = frame; // which-key menu-overlay timing
    _ = frame_builder; // rendering P2: caret-surface auto-expiry
    _ = render_memory;
    _ = collab_presets; // §13.6: echo derives from bundle values only
    _ = config_load; // W4 slice 4: the production plugin/grant-table loader
    _ = providers; // `grammar-add` arity gate: DynLib.open stays guest-unreachable
}
