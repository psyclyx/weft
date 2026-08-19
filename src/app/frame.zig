//! `FrameCtx` — the read/borrow surface the frame BUILD phase needs. The HUD
//! aggregates the whole application (mode, tabs, peers, diagnostics, flash,
//! save state…), so `buildFrame` genuinely reads from every corner of the app;
//! this bundle names those borrows in one place instead of a long parameter
//! list. It OWNS nothing — every field is a pointer into a `main()` local (or a
//! small config value), so there is no init/deinit and no lifetime of its own.
//!
//! It is assembled once, before the loop, from the stable `main()` addresses;
//! the per-frame-varying handles (the active editor/buffer/attach, blink, the
//! frame clock, the framebuffer size) are passed to `buildFrame` per call.
//!
//! When the session/collab/providers clusters later become cohesive owned
//! structs, this bundle collapses into `&session, &collab, &providers` — it is
//! the seam that grouping will replace.

const std = @import("std");
const core = @import("../core/core.zig");
const region = @import("../gfx/region.zig");
const Context = @import("../gfx/context.zig").Context;
const cursor_config = @import("cursor_config.zig");
const providers = @import("providers.zig");

pub const FrameCtx = struct {
    gpa: std.mem.Allocator,
    /// Only `command_pool` is read here — the atlas-delta uploads during the
    /// per-pane build submit one-shots on it (the noted GPU-in-build seam).
    ctx: *Context,

    // ── Editor/session core ──
    buffers: *core.Buffers,
    caps: *core.Caps,
    keymap: *core.Keymap,
    pick: *core.Pick,
    echo: *std.ArrayList(u8),

    // ── Capability UI + config read by the HUD ──
    hover_ui: *core.nav_ui.HoverUi,
    cursor_cfg: *cursor_config.CursorConfig,

    // ── Plugins (live surfaces + menu overlays) ──
    plugins: *std.ArrayList(*core.wasm_abi.WasmPlugin),

    // ── Collab/net state (all pointers to `main()`'s optionals) ──
    conn: *?core.session.Conn,
    hub: *?core.hub.Hub,
    collab_session: *?*core.session.Session,
    partial_state: *?core.session.PartialDoc,
    /// Buffer 0's editor (wire v1) — the partial-checkout gate reads it.
    ed0: *core.Editor,
    known_peers: *core.known_peers.KnownPeers,
    /// The outbound host fingerprint last noted (the trust chip reads it).
    noted_host_fp: *?[24]u8,

    // ── Cross-phase signals the build both reads and writes ──
    /// Damage flag: the build gates on it (skips a clean frame) and re-arms it
    /// for the frame after a flash so the flash is drawn then cleared.
    view_dirty: *bool,
    /// Last render's pane frame, for click routing next frame.
    last_frame_rect: *region.Rect,

    // ── vim-goggles flash timing ──
    flash_gen: *u64,
    flash_start_ns: *u64,
    flash_was_active: *bool,
    flash_duration_ns: u64,
};

/// The per-frame-varying handles passed to `buildFrame` (the active buffer's
/// editor/buffer/provider attachment plus the frame's clock/geometry), kept
/// distinct from the stable `FrameCtx` borrows.
pub const Active = struct {
    editor: *core.Editor,
    abuf: *core.Buffers.Buffer,
    attach: *providers.Attach,
    frame_start: u64,
    fb: [2]u32,
    blink_on: bool,
};
