//! WindowHead — the first-party in-process client that owns the window
//! (Platform: `platform/wayland.zig`'s `Window`), the GPU device + swapchain
//! (`gfx/context.zig`'s `Context`), and the renderer (`app/render.zig`'s
//! `RenderState`) — W0b's "window-head" (doc/north-star-plan.md §2.5/§2.7):
//! rendering.md P5's "bundled scene client" lineage, generalized to own the
//! platform attachment itself rather than just drawing into one.
//!
//! P3's Platform and render-target seams landed first specifically so this
//! struct could exist: `window`/`ctx`/`render` below are exactly the three
//! pieces that boundary separated — WindowHead is
//! the first thing that owns all three together as one addressable unit
//! instead of three separate `main()` locals wired by hand.
//!
//! `client` is this window-head's `core.InProcClient` identity (W0b items
//! 2/3): first-party, every perm self-granted at construction — named in the
//! diff (§2.4's "no UNNAMED authority": the window-head's power is visible
//! here, not implicit from being first-party). A REAL capture-time
//! `head/attach` grant (resolved against a manifest's `GrantDecl`s) is W4;
//! this is the identity SHAPE W4 will populate, not a stand-in
//! implementation of the grant machinery itself.
//!
//! `dispatchKey` brackets `app/dispatch.zig:dispatchKey` with `client.
//! beginDispatch`/`endDispatch` — mirroring `wasm_abi/runtime.zig`'s
//! `wpCmdTrampoline`/`wpPickAccept` bracketing a guest's `on_command`/
//! `on_pick_accept` exactly (W0b item 3's concrete "input injection into
//! dispatch through the same guard"). Nothing reads `client.in_dispatch`
//! today (no semantic body the window-head calls is `requireDispatch`-gated
//! yet) — this is deliberately structural, forward-looking plumbing: it is
//! what makes a FUTURE in-process call through this identity (opening a file
//! via the shared `wasm_host/fs.zig` semantic body instead of a raw
//! `std.fs` call, say) correct by construction instead of a retrofit.
//!
//! **Deliberately NOT done here** (the W2a-3 review's relabeling caution,
//! doc/north-star-plan.md §6, applies verbatim): this struct does NOT own
//! the frame LOOP. `main()` still drives it — `pumpEvents`, the
//! input→commit→build→present sequence, and the scheduler sources for
//! timers/fd unrelated to the window itself (blink/key-repeat/which-key/
//! backing-poll/flash/reconnect/pick-debounce/plugin-loop/plugin-stream/
//! present-retry — see `main.zig`). Forcing that extraction now would be
//! exactly the "a struct that owns fields but not behavior, dressed up as an
//! extraction" risk the review flagged. What's real: the window-head EXISTS
//! as an addressable unit (construct/destroy, one identity, one perm set),
//! `main()` drives it, and `headless.zig`'s composition shares the SAME
//! `core.System` construction WITHOUT ever building one of these —
//! headed-vs-headless is exactly the presence/absence of this struct's
//! binding (see `headless.zig`'s module doc for the other half of that gate).

const std = @import("std");
const Allocator = std.mem.Allocator;
const wayland = @import("../platform/wayland.zig");
const Context = @import("../gfx/context.zig").Context;
const render_mod = @import("render.zig");
const dispatch = @import("dispatch.zig");
const core = @import("../core/core.zig");
const command = core.command;

pub const WindowHead = struct {
    window: *wayland.Window,
    ctx: *Context,
    render: render_mod.RenderState,
    /// This window-head's in-process client identity — named "window-head"
    /// (not "main"/anonymous), so a future trap/log/attribution line names
    /// exactly this attachment. See this file's module doc.
    client: core.InProcClient,

    /// Build every render resource IN PLACE (`self` already at its final
    /// address in `main()`'s frame — mirrors `render_mod.RenderState.init`'s
    /// own in-place convention one level up), in the SAME order `main()`
    /// used to construct these three by hand: window → its actual
    /// framebuffer size → the GPU context sized to it → the renderer.
    /// `active_ctx` is the `command.Context` this window-head dispatches
    /// through (ordinarily `&session.cmd_ctx`) — stored on `client` so a
    /// future in-process semantic-body call (see module doc) has a `Ctx` to
    /// route through without main() threading it separately.
    pub fn init(
        self: *WindowHead,
        gpa: Allocator,
        active_ctx: *command.Context,
        width: u32,
        height: u32,
        font_bytes: []const u8,
        em: f32,
        active_id: core.Buffers.Id,
    ) !void {
        self.window = try wayland.Window.init(width, height, "weft", "dev.psyclyx.weft");
        errdefer self.window.deinit();
        const fb = self.window.framebufferSize();
        self.ctx = try Context.init(gpa, .{
            .display = self.window.display,
            .surface = self.window.surface,
        }, fb[0], fb[1], "weft");
        errdefer self.ctx.deinit();
        try self.render.init(gpa, self.ctx, font_bytes, em, active_id);
        // First-party: self-grants every perm at construction — see module
        // doc's "no UNNAMED authority" note on why this is named, not
        // ambient, and the standing W4 gap (no manifest-resolved grant yet).
        self.client = .{
            .name = "window-head",
            .perms = @splat(true),
            .active_ctx = active_ctx,
        };
    }

    /// Reverse order: renderer resources, then the GPU device/swapchain,
    /// then the window — matches `main()`'s old `defer` unwind exactly.
    pub fn deinit(self: *WindowHead) void {
        self.render.deinit();
        self.ctx.deinit();
        self.window.deinit();
    }

    /// Inject one translated key event through the SAME dispatch entry
    /// every keypress uses (`app/dispatch.zig:dispatchKey`), bracketed by
    /// this window-head's `in_dispatch` — see module doc. `ctx` is the LIVE
    /// `command.Context` to dispatch through (passed explicitly rather than
    /// always reading `self.client.active_ctx`, since a `system-swap` may
    /// have repointed which system `main()`'s `cmd_ctx` targets by the time
    /// this runs — see `core/System.zig`'s `Host.swap`).
    pub fn dispatchKey(self: *WindowHead, ctx: *command.Context, ev: wayland.KeyEvent) !void {
        const prior = self.client.beginDispatch();
        defer self.client.endDispatch(prior);
        return dispatch.dispatchKey(ctx, ev);
    }
};
