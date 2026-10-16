//! Wayland window: registry, xdg-shell toplevel, xkbcommon keyboard, hidpi
//! scale. Adapted from phasekeep's platform layer with one editor-shaped
//! change: input is an ordered event QUEUE of xkb-translated key events
//! (keysym + UTF-8 + modifiers), not polled key-state — an editor consumes
//! keystrokes, it does not sample buttons.
//!
//! The event pump never blocks; the frame loop's real wait is the
//! swapchain. Key repeat is the consumer's concern (repeat rate/delay are
//! surfaced from the compositor for milestone 4's input layer).

comptime {
    if (@import("builtin").os.tag != .linux) @compileError("platform/wayland.zig is Linux-only");
}

const std = @import("std");
const linux = std.os.linux;
const platform = @import("root.zig");
const resize = @import("resize.zig");
const clipboard_pipes = @import("clipboard_pipes.zig");
const KeyQueue = @import("key_queue.zig").KeyQueue;

/// Monotonic clock in nanoseconds (raw syscall; matches core/task.zig).
fn nowNs() u64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

pub const c = @cImport({
    @cInclude("wayland-client.h");
    @cInclude("xkbcommon/xkbcommon.h");
    @cInclude("xdg-shell-client-protocol.h");
});

/// P3 (doc/rendering.md): `KeyEvent`/`Mods` now live in `platform.zig` — the
/// platform-SEAM file, not this one concrete implementation — so naming the
/// portable key-event shape needs no wayland/xkb dependency (see
/// `platform.zig`'s module doc, "leaks found" #3). Re-exported here so every
/// existing `wayland.KeyEvent`/`wayland.Mods` call site (`app/dispatch.zig`,
/// `main.zig`) keeps compiling unchanged — a pure move, no behavior change.
pub const KeyEvent = platform.KeyEvent;
pub const Mods = platform.Mods;
pub const PointerEvent = platform.PointerEvent;

pub const Window = struct {
    const max_outputs = 8;
    const OutputInfo = struct {
        wl_output: ?*c.wl_output = null,
        registry_name: u32 = 0,
        scale: u32 = 1,
        entered: bool = false,
    };

    display: *c.wl_display,
    registry: *c.wl_registry,
    compositor: ?*c.wl_compositor = null,
    wm_base: ?*c.xdg_wm_base = null,
    surface: *c.wl_surface,
    xdg_surface: *c.xdg_surface,
    toplevel: *c.xdg_toplevel,
    seat: ?*c.wl_seat = null,
    keyboard: ?*c.wl_keyboard = null,
    pointer: ?*c.wl_pointer = null,

    // xkbcommon keyboard state (populated from the compositor's keymap).
    xkb_context: ?*c.xkb_context = null,
    xkb_keymap: ?*c.xkb_keymap = null,
    xkb_state: ?*c.xkb_state = null,
    /// Compositor-provided key repeat (chars/sec, initial delay ms);
    /// consumed by the input layer, not applied here.
    repeat_rate: i32 = 25,
    repeat_delay_ms: i32 = 400,

    // Single source of truth for accepted logical extent, buffer scale, and
    // pending resize edges; no mirrored width/height/scale flags live here.
    resize_state: resize.State,
    outputs: [max_outputs]OutputInfo = [_]OutputInfo{.{}} ** max_outputs,
    close_requested: bool = false,
    focused: bool = true,

    /// Ordered key events since last drain.
    keys: KeyQueue = .{},

    // Key repeat: Wayland delivers only down/up, so the client synthesizes
    // repeats for the most-recently-held key that the xkb keymap marks
    // repeatable. Reuses the press-time event (mods + utf8).
    repeat_ev: ?KeyEvent = null,
    repeat_code: u32 = 0,
    repeat_next_ns: u64 = 0,

    /// Pointer input: the protocol's raw facts go into the platform-neutral
    /// gesture reducer, which owns click counting and wheel steps.
    gestures: platform.pointer.Gestures = .{},
    /// The bound wl_seat version. Below 5 there is no `wl_pointer.frame`, so
    /// each axis event is its own frame.
    seat_version: u32 = 0,

    // The clipboard (`wl_data_device`, doc/configs.md §3.3). `clip` is the
    // last-known selection text; `xfers` moves it through pipes without
    // blocking (`clipboard_pipes.zig`). With no data-device manager (a compositor
    // without one) the clipboard is `clip` alone — in memory, like headless.
    // Primary selection (`zwp_primary_selection_v1`, middle-click paste) is
    // not bound: it needs a generated protocol header this build does not
    // carry, and vim's `"*` maps onto the one clipboard instead.
    data_device_manager: ?*c.wl_data_device_manager = null,
    data_device: ?*c.wl_data_device = null,
    /// Our current selection source, while we own the clipboard.
    data_source: ?*c.wl_data_source = null,
    /// The offer the desktop's current selection arrived as.
    selection_offer: ?*Offer = null,
    /// A drag-and-drop offer over the window — never accepted, only released.
    dnd_offer: ?*Offer = null,
    clip: platform.clipboard.Store = .{},
    xfers: ?clipboard_pipes.Transfers = null,
    /// The serial of the newest input event: `set_selection` must name one,
    /// so a compositor can refuse a client that grabs the clipboard unasked.
    input_serial: u32 = 0,

    pub fn init(width: u32, height: u32, title: [*:0]const u8, app_id: [*:0]const u8) !*Window {
        const display = c.wl_display_connect(null) orelse return error.WaylandConnectFailed;
        errdefer c.wl_display_disconnect(display);

        const registry = c.wl_display_get_registry(display) orelse return error.RegistryInitFailed;
        errdefer c.wl_registry_destroy(registry);

        const self = try std.heap.c_allocator.create(Window);
        errdefer std.heap.c_allocator.destroy(self);

        self.* = .{
            .display = display,
            .registry = registry,
            .surface = undefined,
            .xdg_surface = undefined,
            .toplevel = undefined,
            .resize_state = resize.State.init(width, height),
        };

        self.xkb_context = c.xkb_context_new(c.XKB_CONTEXT_NO_FLAGS);
        if (self.xkb_context == null) return error.XkbInitFailed;
        errdefer c.xkb_context_unref(self.xkb_context);

        _ = c.wl_registry_add_listener(registry, &registry_listener, self);
        if (c.wl_display_roundtrip(display) < 0) return error.WaylandRoundtripFailed;
        if (self.compositor == null or self.wm_base == null) return error.MissingWaylandGlobals;

        _ = c.xdg_wm_base_add_listener(self.wm_base.?, &wm_base_listener, self);

        self.surface = c.wl_compositor_create_surface(self.compositor.?) orelse return error.SurfaceCreateFailed;
        errdefer c.wl_surface_destroy(self.surface);
        _ = c.wl_surface_add_listener(self.surface, &surface_listener, self);

        self.xdg_surface = c.xdg_wm_base_get_xdg_surface(self.wm_base.?, self.surface) orelse return error.SurfaceCreateFailed;
        errdefer c.xdg_surface_destroy(self.xdg_surface);
        _ = c.xdg_surface_add_listener(self.xdg_surface, &xdg_surface_listener, self);

        self.toplevel = c.xdg_surface_get_toplevel(self.xdg_surface) orelse return error.SurfaceCreateFailed;
        errdefer c.xdg_toplevel_destroy(self.toplevel);
        _ = c.xdg_toplevel_add_listener(self.toplevel, &xdg_toplevel_listener, self);
        c.xdg_toplevel_set_title(self.toplevel, title);
        c.xdg_toplevel_set_app_id(self.toplevel, app_id);
        c.wl_surface_commit(self.surface);

        // Wait for the initial configure so the first frame renders at the
        // size the compositor actually granted.
        if (c.wl_display_roundtrip(display) < 0) return error.WaylandRoundtripFailed;
        self.refreshBufferScale();
        self.xfers = clipboard_pipes.Transfers.init() catch null;
        if (self.data_device_manager) |mgr| if (self.seat) |seat| {
            self.data_device = c.wl_data_device_manager_get_data_device(mgr, seat);
            if (self.data_device) |dev| _ = c.wl_data_device_add_listener(dev, &data_device_listener, self);
        };
        return self;
    }

    pub fn deinit(self: *Window) void {
        const gpa = std.heap.c_allocator;
        if (self.data_source) |src| c.wl_data_source_destroy(src);
        if (self.selection_offer) |o| o.destroy();
        if (self.dnd_offer) |o| o.destroy();
        if (self.data_device) |dev| c.wl_data_device_destroy(dev);
        if (self.data_device_manager) |mgr| c.wl_data_device_manager_destroy(mgr);
        if (self.xfers) |*x| x.deinit(gpa);
        self.clip.deinit(gpa);
        if (self.xkb_state) |s| c.xkb_state_unref(s);
        if (self.xkb_keymap) |k| c.xkb_keymap_unref(k);
        if (self.xkb_context) |ctx| c.xkb_context_unref(ctx);
        if (self.keyboard) |keyboard| c.wl_keyboard_destroy(keyboard);
        if (self.pointer) |pointer| c.wl_pointer_destroy(pointer);
        if (self.seat) |seat| c.wl_seat_destroy(seat);
        for (&self.outputs) |*info| {
            if (info.wl_output) |output| c.wl_output_destroy(output);
            info.* = .{};
        }
        c.xdg_toplevel_destroy(self.toplevel);
        c.xdg_surface_destroy(self.xdg_surface);
        c.wl_surface_destroy(self.surface);
        if (self.wm_base) |wm_base| c.xdg_wm_base_destroy(wm_base);
        if (self.compositor) |compositor| c.wl_compositor_destroy(compositor);
        c.wl_registry_destroy(self.registry);
        c.wl_display_disconnect(self.display);
        std.heap.c_allocator.destroy(self);
    }

    /// Non-blocking pump: dispatch queued events, flush requests, and read
    /// from the socket only if data is ready.
    pub fn pumpEvents(self: *Window) void {
        _ = c.wl_display_dispatch_pending(self.display);

        while (c.wl_display_prepare_read(self.display) != 0) {
            _ = c.wl_display_dispatch_pending(self.display);
        }

        _ = c.wl_display_flush(self.display);

        var fds = [_]std.posix.pollfd{.{
            .fd = c.wl_display_get_fd(self.display),
            .events = std.posix.POLL.IN,
            .revents = 0,
        }};
        const ready = std.posix.poll(&fds, 0) catch 0;
        if (ready > 0 and (fds[0].revents & std.posix.POLL.IN) != 0) {
            _ = c.wl_display_read_events(self.display);
        } else {
            _ = c.wl_display_cancel_read(self.display);
        }
        _ = c.wl_display_dispatch_pending(self.display);
        if (self.xfers) |*x| _ = x.service(std.heap.c_allocator, &self.clip);
        self.emitKeyRepeats();
        self.refreshBufferScale();
    }

    // ── The clipboard (Platform contract: clipboardText/Set/Fd) ────────

    /// The clipboard's last-known text: ours while we own the selection,
    /// else the newest offer as far as it has been read.
    pub fn clipboardText(self: *const Window) []const u8 {
        return self.clip.text();
    }

    /// Take the selection with `bytes`: remember them, then offer them to the
    /// desktop as text. Other clients read them through `sourceSend`, one
    /// non-blocking pipe each.
    pub fn clipboardSet(self: *Window, bytes: []const u8) void {
        self.clip.set(std.heap.c_allocator, bytes) catch return;
        const mgr = self.data_device_manager orelse return;
        const dev = self.data_device orelse return;
        const src = c.wl_data_device_manager_create_data_source(mgr) orelse return;
        _ = c.wl_data_source_add_listener(src, &data_source_listener, self);
        for (text_mimes) |mime| c.wl_data_source_offer(src, mime);
        c.wl_data_source_offer(src, own_mime);
        c.wl_data_device_set_selection(dev, src, self.input_serial);
        if (self.data_source) |old| c.wl_data_source_destroy(old);
        self.data_source = src;
        _ = c.wl_display_flush(self.display);
    }

    /// Readable when a clipboard pipe can make progress; -1 without one.
    pub fn clipboardFd(self: *const Window) i32 {
        const x = self.xfers orelse return -1;
        return x.fd();
    }

    /// Start reading the desktop's new selection. Our own offer (marked with
    /// `own_mime`) is not read back — we already hold its text.
    fn takeSelection(self: *Window, offer: ?*Offer) void {
        if (self.selection_offer) |old| if (old != offer) old.destroy();
        self.selection_offer = offer;
        const o = offer orelse {
            // No selection at all: the owner went away with it.
            if (self.data_source == null) self.clip.set(std.heap.c_allocator, "") catch {};
            return;
        };
        if (o.ours) return;
        const mime = o.bestMime() orelse return;
        if (self.xfers == null) return;
        const fds = clipboard_pipes.pipe() orelse return;
        c.wl_data_offer_receive(o.offer, mime, fds[1]);
        _ = std.c.close(fds[1]);
        self.xfers.?.receive(std.heap.c_allocator, &self.clip, fds[0]);
        _ = c.wl_display_flush(self.display);
    }

    /// Synthesize repeat events for a held key, paced by the compositor's
    /// rate/delay. Bounded per frame so a stall can't dump a burst.
    fn emitKeyRepeats(self: *Window) void {
        const rk = self.repeat_ev orelse return;
        if (self.repeat_rate <= 0 or !self.focused) return;
        const interval: u64 = std.time.ns_per_s / @as(u64, @intCast(self.repeat_rate));
        const now = nowNs();
        var guard: u32 = 0;
        while (now >= self.repeat_next_ns and guard < 8) : (guard += 1) {
            self.keys.push(rk);
            self.repeat_next_ns += interval;
        }
        // Resync after a long stall instead of catching up all at once.
        if (now > self.repeat_next_ns + interval * 8) self.repeat_next_ns = now + interval;
    }

    /// The Wayland display's fd — non-blocking, readable when the
    /// compositor has queued protocol data. The scheduler source
    /// (`app/loop_sources.zig`) registers this directly; `pumpEvents`
    /// (called unconditionally on every scheduler wake, fd or timer) does
    /// the actual `prepare_read`/`flush`/`read_events` dance.
    pub fn fd(self: *const Window) i32 {
        return c.wl_display_get_fd(self.display);
    }

    /// The scheduler's wait: the display socket is one of `fds`, so a plain
    /// `poll` already wakes for compositor events.
    pub fn wait(_: *Window, fds: []std.posix.pollfd, timeout_ms: i32) usize {
        return std.posix.poll(fds, timeout_ms) catch 0;
    }

    /// The display and surface a GPU context presents through.
    pub fn surfaceSource(self: *const Window) platform.SurfaceSource {
        return .{ .wayland = .{ .display = self.display, .surface = self.surface } };
    }

    /// Next due time for synthesized key-repeat, or null when no key is
    /// currently held repeatable — a pure query (doc/cwa-prior-docs-audit.md §5
    /// W2a-3): the scheduler sleeps until this instant instead of
    /// relying on vsync to happen to service `emitKeyRepeats` in time.
    /// The synthesis itself still runs inside `pumpEvents` (called on
    /// every wake regardless of which source fired), so this reports
    /// timing only and mutates nothing.
    pub fn repeatDueNs(self: *const Window) ?u64 {
        if (self.repeat_ev == null or self.repeat_rate <= 0 or !self.focused) return null;
        return self.repeat_next_ns;
    }

    pub fn shouldClose(self: *const Window) bool {
        return self.close_requested;
    }

    /// Take the compositor's close request, if there is one: the app decides
    /// what it means (a quit that may refuse while work is unsaved).
    pub fn takeCloseRequest(self: *Window) bool {
        defer self.close_requested = false;
        return self.close_requested;
    }

    /// The xkb name for a keysym (e.g. "a", "Escape", "F1") — `""` if xkb
    /// can't name it. `app/dispatch.zig:dispatchKey` calls this to turn a
    /// `KeyEvent.keysym` into the string `core.Keymap.keyspec` builds a
    /// canonical binding name from. Stateless (xkb keysym names don't
    /// depend on the live keymap), so this takes a bare keysym, not `self`.
    /// P3 (doc/rendering.md): wraps `xkb_keysym_get_name` so `wayland.c`
    /// stays INSIDE this file — `dispatchKey` used to import `wayland.c`
    /// directly for this one call, reaching past `Window`'s public surface
    /// into xkb's raw C API from a platform-neutral file. See
    /// `platform.zig`'s module doc, "leaks found" #2.
    pub fn keysymName(buf: []u8, keysym: u32) []const u8 {
        const n = c.xkb_keysym_get_name(keysym, buf.ptr, buf.len);
        if (n <= 0) return "";
        return buf[0..@intCast(n)];
    }

    pub fn framebufferSize(self: *const Window) [2]u32 {
        const extent = self.resize_state.framebufferExtent();
        return .{ extent.width, extent.height };
    }

    pub fn consumeResized(self: *Window) bool {
        return self.resize_state.consumeResized();
    }

    pub fn bufferScale(self: *const Window) u32 {
        return self.resize_state.bufferScale();
    }

    /// Next key event in press order, or null.
    pub fn nextKeyEvent(self: *Window) ?KeyEvent {
        return self.keys.next();
    }

    /// Next pointer event in arrival order, or null.
    pub fn nextPointerEvent(self: *Window) ?PointerEvent {
        return self.gestures.next();
    }

    fn currentMods(self: *const Window) Mods {
        const state = self.xkb_state orelse return .{};
        const active = struct {
            fn active(s: *c.xkb_state, name: [*:0]const u8) bool {
                return c.xkb_state_mod_name_is_active(s, name, c.XKB_STATE_MODS_EFFECTIVE) == 1;
            }
        }.active;
        return .{
            .ctrl = active(state, c.XKB_MOD_NAME_CTRL),
            .alt = active(state, c.XKB_MOD_NAME_ALT),
            .shift = active(state, c.XKB_MOD_NAME_SHIFT),
            .logo = active(state, c.XKB_MOD_NAME_LOGO),
        };
    }

    fn currentBufferScale(self: *const Window) u32 {
        var scale: u32 = 1;
        var have_entered = false;
        for (self.outputs) |info| {
            if (info.wl_output != null and info.entered) {
                have_entered = true;
                scale = @max(scale, info.scale);
            }
        }
        if (have_entered) return scale;
        for (self.outputs) |info| {
            if (info.wl_output != null) scale = @max(scale, info.scale);
        }
        return scale;
    }

    fn refreshBufferScale(self: *Window) void {
        const next = self.currentBufferScale();
        if (!self.resize_state.setScale(next)) return;
        c.wl_surface_set_buffer_scale(self.surface, @intCast(next));
    }

    fn allocOutputInfo(self: *Window) ?*OutputInfo {
        for (&self.outputs) |*info| {
            if (info.wl_output == null) return info;
        }
        return null;
    }

    fn findOutputInfo(self: *Window, output: *c.wl_output) ?*OutputInfo {
        for (&self.outputs) |*info| {
            if (info.wl_output == output) return info;
        }
        return null;
    }
};

// P3 (doc/rendering.md): `Window` is the Platform seam's one live
// implementation — checked here, at the definition site, against the
// contract `platform.zig` names (see that file's module doc for the full
// decl-by-decl audit this was extracted from).
comptime {
    platform.assertPlatform(Window);
}

fn selfFrom(data: ?*anyopaque) *Window {
    return @ptrCast(@alignCast(data.?));
}

// ── Clipboard protocol glue (wl_data_device / wl_data_offer / wl_data_source)

/// The text types we offer, best first; also what we look for in an offer.
const text_mimes = [_][*:0]const u8{ "text/plain;charset=utf-8", "UTF8_STRING", "text/plain", "TEXT", "STRING" };
/// Marks a selection as ours, so the offer the compositor echoes back to us
/// for our own copy is not read through a pipe to ourselves.
const own_mime: [*:0]const u8 = "application/x-weft-selection";

/// One `wl_data_offer` and the text types it announced (they arrive one
/// `offer` event at a time, before the `selection`/`enter` that uses it).
const Offer = struct {
    offer: *c.wl_data_offer,
    /// Index into `text_mimes` of the best type offered so far.
    best: ?usize = null,
    ours: bool = false,

    fn create(offer: *c.wl_data_offer) ?*Offer {
        const o = std.heap.c_allocator.create(Offer) catch {
            c.wl_data_offer_destroy(offer);
            return null;
        };
        o.* = .{ .offer = offer };
        _ = c.wl_data_offer_add_listener(offer, &data_offer_listener, o);
        return o;
    }

    fn destroy(self: *Offer) void {
        c.wl_data_offer_destroy(self.offer);
        std.heap.c_allocator.destroy(self);
    }

    fn bestMime(self: *const Offer) ?[*:0]const u8 {
        return text_mimes[self.best orelse return null];
    }
};

fn offerFrom(data: ?*anyopaque) *Offer {
    return @ptrCast(@alignCast(data.?));
}

fn offerMime(data: ?*anyopaque, _: ?*c.wl_data_offer, mime_type: [*c]const u8) callconv(.c) void {
    const o = offerFrom(data);
    const mime = std.mem.span(mime_type);
    if (std.mem.eql(u8, mime, std.mem.span(own_mime))) o.ours = true;
    for (text_mimes, 0..) |m, i| {
        if (!std.mem.eql(u8, mime, std.mem.span(m))) continue;
        if (o.best == null or i < o.best.?) o.best = i;
    }
}

fn offerSourceActions(_: ?*anyopaque, _: ?*c.wl_data_offer, _: u32) callconv(.c) void {}
fn offerAction(_: ?*anyopaque, _: ?*c.wl_data_offer, _: u32) callconv(.c) void {}

const data_offer_listener = c.wl_data_offer_listener{
    .offer = offerMime,
    .source_actions = offerSourceActions,
    .action = offerAction,
};

/// A new offer is being introduced; its user data is the `Offer` that
/// collects its types until `selection` or `enter` says what it is for.
fn deviceDataOffer(_: ?*anyopaque, _: ?*c.wl_data_device, offer: ?*c.wl_data_offer) callconv(.c) void {
    _ = Offer.create(offer orelse return);
}

fn offerOf(offer: ?*c.wl_data_offer) ?*Offer {
    const o = offer orelse return null;
    return @ptrCast(@alignCast(c.wl_data_offer_get_user_data(o)));
}

fn deviceEnter(data: ?*anyopaque, _: ?*c.wl_data_device, _: u32, _: ?*c.wl_surface, _: c.wl_fixed_t, _: c.wl_fixed_t, offer: ?*c.wl_data_offer) callconv(.c) void {
    const self = selfFrom(data);
    if (self.dnd_offer) |old| old.destroy();
    self.dnd_offer = offerOf(offer);
}

fn deviceLeave(data: ?*anyopaque, _: ?*c.wl_data_device) callconv(.c) void {
    const self = selfFrom(data);
    if (self.dnd_offer) |old| old.destroy();
    self.dnd_offer = null;
}

fn deviceMotion(_: ?*anyopaque, _: ?*c.wl_data_device, _: u32, _: c.wl_fixed_t, _: c.wl_fixed_t) callconv(.c) void {}

fn deviceDrop(data: ?*anyopaque, dev: ?*c.wl_data_device) callconv(.c) void {
    deviceLeave(data, dev); // drops are not accepted; release the offer
}

fn deviceSelection(data: ?*anyopaque, _: ?*c.wl_data_device, offer: ?*c.wl_data_offer) callconv(.c) void {
    selfFrom(data).takeSelection(offerOf(offer));
}

const data_device_listener = c.wl_data_device_listener{
    .data_offer = deviceDataOffer,
    .enter = deviceEnter,
    .leave = deviceLeave,
    .motion = deviceMotion,
    .drop = deviceDrop,
    .selection = deviceSelection,
};

fn sourceTarget(_: ?*anyopaque, _: ?*c.wl_data_source, _: [*c]const u8) callconv(.c) void {}

/// Another client pastes from us: hand our text to its pipe, non-blocking.
fn sourceSend(data: ?*anyopaque, src: ?*c.wl_data_source, _: [*c]const u8, fd: i32) callconv(.c) void {
    const self = selfFrom(data);
    if (src != self.data_source or self.xfers == null) {
        _ = std.c.close(fd);
        return;
    }
    self.xfers.?.send(std.heap.c_allocator, fd, self.clip.text());
}

/// Someone else took the clipboard. Our text stays the last-known one until
/// their offer has been read (`takeSelection`).
fn sourceCancelled(data: ?*anyopaque, src: ?*c.wl_data_source) callconv(.c) void {
    const self = selfFrom(data);
    const s = src orelse return;
    if (self.data_source == s) self.data_source = null;
    c.wl_data_source_destroy(s);
}

fn sourceDndDropPerformed(_: ?*anyopaque, _: ?*c.wl_data_source) callconv(.c) void {}
fn sourceDndFinished(_: ?*anyopaque, _: ?*c.wl_data_source) callconv(.c) void {}
fn sourceAction(_: ?*anyopaque, _: ?*c.wl_data_source, _: u32) callconv(.c) void {}

const data_source_listener = c.wl_data_source_listener{
    .target = sourceTarget,
    .send = sourceSend,
    .cancelled = sourceCancelled,
    .dnd_drop_performed = sourceDndDropPerformed,
    .dnd_finished = sourceDndFinished,
    .action = sourceAction,
};

fn registryGlobal(
    data: ?*anyopaque,
    registry: ?*c.wl_registry,
    name: u32,
    interface: [*c]const u8,
    version: u32,
) callconv(.c) void {
    const self = selfFrom(data);
    const iface = std.mem.span(interface);
    const reg = registry.?;

    if (std.mem.eql(u8, iface, "wl_compositor")) {
        self.compositor = @ptrCast(c.wl_registry_bind(reg, name, &c.wl_compositor_interface, @min(version, 4)));
    } else if (std.mem.eql(u8, iface, "xdg_wm_base")) {
        self.wm_base = @ptrCast(c.wl_registry_bind(reg, name, &c.xdg_wm_base_interface, 1));
    } else if (std.mem.eql(u8, iface, "wl_seat")) {
        self.seat_version = @min(version, 5);
        self.seat = @ptrCast(c.wl_registry_bind(reg, name, &c.wl_seat_interface, self.seat_version));
        if (self.seat) |seat| {
            _ = c.wl_seat_add_listener(seat, &seat_listener, self);
        }
    } else if (std.mem.eql(u8, iface, "wl_data_device_manager")) {
        // v3 is what the listeners below implement (dnd actions); the device
        // itself is made in `init`, once the seat is known too.
        self.data_device_manager = @ptrCast(c.wl_registry_bind(reg, name, &c.wl_data_device_manager_interface, @min(version, 3)));
    } else if (std.mem.eql(u8, iface, "wl_output")) {
        const slot = self.allocOutputInfo() orelse return;
        slot.* = .{
            .wl_output = @ptrCast(c.wl_registry_bind(reg, name, &c.wl_output_interface, @min(version, 2))),
            .registry_name = name,
        };
        if (slot.wl_output) |output| {
            _ = c.wl_output_add_listener(output, &output_listener, self);
        }
    }
}

fn registryGlobalRemove(data: ?*anyopaque, _: ?*c.wl_registry, name: u32) callconv(.c) void {
    const self = selfFrom(data);
    for (&self.outputs) |*info| {
        if (info.wl_output != null and info.registry_name == name) {
            c.wl_output_destroy(info.wl_output.?);
            info.* = .{};
            return;
        }
    }
}

const registry_listener = c.wl_registry_listener{
    .global = registryGlobal,
    .global_remove = registryGlobalRemove,
};

fn wmBasePing(_: ?*anyopaque, wm_base: ?*c.xdg_wm_base, serial: u32) callconv(.c) void {
    c.xdg_wm_base_pong(wm_base.?, serial);
}

const wm_base_listener = c.xdg_wm_base_listener{
    .ping = wmBasePing,
};

fn xdgSurfaceConfigure(data: ?*anyopaque, xdg_surface: ?*c.xdg_surface, serial: u32) callconv(.c) void {
    const self = selfFrom(data);
    // Acknowledge first, then stage the newest coalesced geometry.  Do not
    // commit an empty surface here: the next rendered buffer is the commit
    // that must carry this configure's geometry and resize.
    c.xdg_surface_ack_configure(xdg_surface.?, serial);
    const decision = self.resize_state.surfaceConfigure();
    c.xdg_surface_set_window_geometry(
        xdg_surface.?,
        0,
        0,
        @intCast(decision.extent.width),
        @intCast(decision.extent.height),
    );
}

const xdg_surface_listener = c.xdg_surface_listener{
    .configure = xdgSurfaceConfigure,
};

fn xdgToplevelConfigure(
    data: ?*anyopaque,
    _: ?*c.xdg_toplevel,
    width: i32,
    height: i32,
    _: ?*c.wl_array,
) callconv(.c) void {
    const self = selfFrom(data);
    // xdg-shell's non-positive dimensions mean that the client chooses that
    // dimension; the reducer retains its last accepted value per axis.
    self.resize_state.toplevelConfigure(.{ .width = width, .height = height });
}

fn xdgToplevelClose(data: ?*anyopaque, _: ?*c.xdg_toplevel) callconv(.c) void {
    selfFrom(data).close_requested = true;
}

fn xdgToplevelBounds(_: ?*anyopaque, _: ?*c.xdg_toplevel, _: i32, _: i32) callconv(.c) void {}

fn xdgToplevelWmCapabilities(_: ?*anyopaque, _: ?*c.xdg_toplevel, _: ?*c.wl_array) callconv(.c) void {}

const xdg_toplevel_listener = c.xdg_toplevel_listener{
    .configure = xdgToplevelConfigure,
    .close = xdgToplevelClose,
    .configure_bounds = xdgToplevelBounds,
    .wm_capabilities = xdgToplevelWmCapabilities,
};

fn seatCapabilities(data: ?*anyopaque, seat: ?*c.wl_seat, capabilities: u32) callconv(.c) void {
    const self = selfFrom(data);
    if ((capabilities & c.WL_SEAT_CAPABILITY_KEYBOARD) != 0) {
        if (self.keyboard == null) {
            self.keyboard = c.wl_seat_get_keyboard(seat.?) orelse return;
            _ = c.wl_keyboard_add_listener(self.keyboard, &keyboard_listener, self);
        }
    } else if (self.keyboard) |keyboard| {
        c.wl_keyboard_destroy(keyboard);
        self.keyboard = null;
    }
    if ((capabilities & c.WL_SEAT_CAPABILITY_POINTER) != 0) {
        if (self.pointer == null) {
            self.pointer = c.wl_seat_get_pointer(seat.?) orelse return;
            _ = c.wl_pointer_add_listener(self.pointer, &pointer_listener, self);
        }
    } else if (self.pointer) |pointer| {
        c.wl_pointer_destroy(pointer);
        self.pointer = null;
    }
}

fn pointerEnter(data: ?*anyopaque, _: ?*c.wl_pointer, serial: u32, _: ?*c.wl_surface, sx: c.wl_fixed_t, sy: c.wl_fixed_t) callconv(.c) void {
    const self = selfFrom(data);
    self.input_serial = serial;
    self.gestures.warp(c.wl_fixed_to_double(sx), c.wl_fixed_to_double(sy));
}

fn pointerLeave(data: ?*anyopaque, _: ?*c.wl_pointer, _: u32, _: ?*c.wl_surface) callconv(.c) void {
    const self = selfFrom(data);
    self.gestures.leave(self.currentMods());
}

fn pointerMotion(data: ?*anyopaque, _: ?*c.wl_pointer, _: u32, sx: c.wl_fixed_t, sy: c.wl_fixed_t) callconv(.c) void {
    const self = selfFrom(data);
    self.gestures.motion(c.wl_fixed_to_double(sx), c.wl_fixed_to_double(sy), self.currentMods());
}

/// A linux/input-event-codes.h button code as the keymap numbers it: 1 is
/// the primary button, 2 the middle, 3 the secondary, then side/extra.
fn buttonNumber(code: u32) ?u8 {
    return switch (code) {
        0x110 => 1, // BTN_LEFT
        0x112 => 2, // BTN_MIDDLE
        0x111 => 3, // BTN_RIGHT
        0x113 => 8, // BTN_SIDE (back)
        0x114 => 9, // BTN_EXTRA (forward)
        else => null,
    };
}

fn pointerButton(data: ?*anyopaque, _: ?*c.wl_pointer, serial: u32, time: u32, button: u32, state: u32) callconv(.c) void {
    const self = selfFrom(data);
    self.input_serial = serial;
    const b = buttonNumber(button) orelse return;
    self.gestures.button(b, state == c.WL_POINTER_BUTTON_STATE_PRESSED, time, self.currentMods());
}

fn axisOf(axis: u32) ?platform.pointer.Axis {
    return switch (axis) {
        c.WL_POINTER_AXIS_VERTICAL_SCROLL => .vertical,
        c.WL_POINTER_AXIS_HORIZONTAL_SCROLL => .horizontal,
        else => null,
    };
}

fn pointerAxis(data: ?*anyopaque, _: ?*c.wl_pointer, _: u32, axis: u32, value: c.wl_fixed_t) callconv(.c) void {
    const self = selfFrom(data);
    self.gestures.axis(axisOf(axis) orelse return, c.wl_fixed_to_double(value));
    // Before seat v5 nothing groups axis events, so each one ends its frame.
    if (self.seat_version < 5) self.gestures.frame(self.currentMods());
}

fn pointerFrame(data: ?*anyopaque, _: ?*c.wl_pointer) callconv(.c) void {
    const self = selfFrom(data);
    self.gestures.frame(self.currentMods());
}

fn pointerAxisSource(_: ?*anyopaque, _: ?*c.wl_pointer, _: u32) callconv(.c) void {}

fn pointerAxisStop(data: ?*anyopaque, _: ?*c.wl_pointer, _: u32, axis: u32) callconv(.c) void {
    const self = selfFrom(data);
    self.gestures.axisStop(axisOf(axis) orelse return);
}

fn pointerAxisDiscrete(data: ?*anyopaque, _: ?*c.wl_pointer, axis: u32, discrete: i32) callconv(.c) void {
    const self = selfFrom(data);
    self.gestures.axisDiscrete(axisOf(axis) orelse return, discrete);
}

const pointer_listener = c.wl_pointer_listener{
    .enter = pointerEnter,
    .leave = pointerLeave,
    .motion = pointerMotion,
    .button = pointerButton,
    .axis = pointerAxis,
    .frame = pointerFrame,
    .axis_source = pointerAxisSource,
    .axis_stop = pointerAxisStop,
    .axis_discrete = pointerAxisDiscrete,
};

fn seatName(_: ?*anyopaque, _: ?*c.wl_seat, _: [*c]const u8) callconv(.c) void {}

const seat_listener = c.wl_seat_listener{
    .capabilities = seatCapabilities,
    .name = seatName,
};

fn keyboardKeymap(data: ?*anyopaque, _: ?*c.wl_keyboard, format: u32, fd: i32, size: u32) callconv(.c) void {
    const self = selfFrom(data);
    defer if (fd >= 0) {
        _ = std.c.close(fd);
    };
    if (format != c.WL_KEYBOARD_KEYMAP_FORMAT_XKB_V1) return;
    const ctx = self.xkb_context orelse return;

    const mapped = std.posix.mmap(null, size, .{ .READ = true }, .{ .TYPE = .PRIVATE }, fd, 0) catch return;
    defer std.posix.munmap(mapped);

    const keymap = c.xkb_keymap_new_from_buffer(
        ctx,
        @ptrCast(mapped.ptr),
        // The buffer is NUL-terminated per protocol; exclude it.
        if (size > 0) size - 1 else 0,
        c.XKB_KEYMAP_FORMAT_TEXT_V1,
        c.XKB_KEYMAP_COMPILE_NO_FLAGS,
    ) orelse return;
    const state = c.xkb_state_new(keymap) orelse {
        c.xkb_keymap_unref(keymap);
        return;
    };
    if (self.xkb_state) |old| c.xkb_state_unref(old);
    if (self.xkb_keymap) |old| c.xkb_keymap_unref(old);
    self.xkb_keymap = keymap;
    self.xkb_state = state;
}

fn keyboardEnter(data: ?*anyopaque, _: ?*c.wl_keyboard, serial: u32, _: ?*c.wl_surface, _: ?*c.wl_array) callconv(.c) void {
    const self = selfFrom(data);
    self.focused = true;
    self.input_serial = serial;
}

fn keyboardLeave(data: ?*anyopaque, _: ?*c.wl_keyboard, _: u32, _: ?*c.wl_surface) callconv(.c) void {
    const self = selfFrom(data);
    self.focused = false;
    self.repeat_ev = null; // no stuck repeat when focus leaves
}

fn keyboardKey(
    data: ?*anyopaque,
    _: ?*c.wl_keyboard,
    serial: u32,
    _: u32,
    key: u32,
    state: u32,
) callconv(.c) void {
    const self = selfFrom(data);
    self.input_serial = serial;
    const xkb_state = self.xkb_state orelse return;
    // Wayland delivers evdev codes; xkb keycodes are offset by 8.
    const keycode: c.xkb_keycode_t = key + 8;
    const pressed = state == c.WL_KEYBOARD_KEY_STATE_PRESSED;

    const mods = self.currentMods();
    // Keyspec consistency: under Ctrl/Alt, name the BASE (unshifted) key
    // and carry shift explicitly (`C-S-b`, never `C-B`) — a chord is a
    // physical key plus modifiers. Without Ctrl/Alt, keep the shifted
    // keysym so typing bindings read naturally (`G`, `dollar`), and only
    // an UNCONSUMED shift (a key with no shifted level, e.g. Return/Tab)
    // becomes an explicit `S-`.
    const chorded = mods.ctrl or mods.alt or mods.logo;
    var ev = KeyEvent{
        .keysym = if (chorded)
            baseKeysym(xkb_state, keycode)
        else
            c.xkb_state_key_get_one_sym(xkb_state, keycode),
        .mods = mods,
        .pressed = pressed,
    };
    ev.mods.shift = mods.shift and (chorded or !shiftConsumed(xkb_state, keycode));
    if (pressed) {
        const n = c.xkb_state_key_get_utf8(xkb_state, keycode, @ptrCast(&ev.utf8), ev.utf8.len);
        if (n > 0 and n < ev.utf8.len) ev.utf8_len = @intCast(n);
    }
    self.keys.push(ev);

    // Arm/disarm key repeat. A new repeatable press becomes the target
    // (holding a second key takes over); releasing the held key stops it.
    if (pressed) {
        const keymap = c.xkb_state_get_keymap(xkb_state);
        if (self.repeat_rate > 0 and keymap != null and
            c.xkb_keymap_key_repeats(keymap, keycode) == 1)
        {
            self.repeat_ev = ev;
            self.repeat_code = key;
            self.repeat_next_ns = nowNs() + @as(u64, @intCast(self.repeat_delay_ms)) * std.time.ns_per_ms;
        }
    } else if (key == self.repeat_code) {
        self.repeat_ev = null;
    }
}

/// The keysym at the unshifted level of the current layout — the
/// physical key's identity, for naming Ctrl/Alt chords.
fn baseKeysym(state: *c.xkb_state, keycode: c.xkb_keycode_t) c.xkb_keysym_t {
    const keymap = c.xkb_state_get_keymap(state) orelse return c.xkb_state_key_get_one_sym(state, keycode);
    const layout = c.xkb_state_key_get_layout(state, keycode);
    var syms: [*c]const c.xkb_keysym_t = undefined;
    const n = c.xkb_keymap_key_get_syms_by_level(keymap, keycode, layout, 0, &syms);
    if (n >= 1) return syms[0];
    return c.xkb_state_key_get_one_sym(state, keycode);
}

/// Was Shift used to pick this key's level (a→A)? If so it is already in
/// the keysym and not a binding modifier; if not (Return, Tab), it is.
fn shiftConsumed(state: *c.xkb_state, keycode: c.xkb_keycode_t) bool {
    const keymap = c.xkb_state_get_keymap(state) orelse return false;
    const idx = c.xkb_keymap_mod_get_index(keymap, c.XKB_MOD_NAME_SHIFT);
    if (idx == c.XKB_MOD_INVALID) return false;
    const consumed = c.xkb_state_key_get_consumed_mods2(state, keycode, c.XKB_CONSUMED_MODE_XKB);
    return (consumed & (@as(c.xkb_mod_mask_t, 1) << @intCast(idx))) != 0;
}

fn keyboardModifiers(
    data: ?*anyopaque,
    _: ?*c.wl_keyboard,
    _: u32,
    depressed: u32,
    latched: u32,
    locked: u32,
    group: u32,
) callconv(.c) void {
    const self = selfFrom(data);
    if (self.xkb_state) |state| {
        _ = c.xkb_state_update_mask(state, depressed, latched, locked, 0, 0, group);
    }
}

fn keyboardRepeatInfo(data: ?*anyopaque, _: ?*c.wl_keyboard, rate: i32, delay: i32) callconv(.c) void {
    const self = selfFrom(data);
    self.repeat_rate = rate;
    self.repeat_delay_ms = delay;
}

const keyboard_listener = c.wl_keyboard_listener{
    .keymap = keyboardKeymap,
    .enter = keyboardEnter,
    .leave = keyboardLeave,
    .key = keyboardKey,
    .modifiers = keyboardModifiers,
    .repeat_info = keyboardRepeatInfo,
};

fn outputGeometry(
    _: ?*anyopaque,
    _: ?*c.wl_output,
    _: i32,
    _: i32,
    _: i32,
    _: i32,
    _: c_int,
    _: [*c]const u8,
    _: [*c]const u8,
    _: c_int,
) callconv(.c) void {}

fn outputMode(_: ?*anyopaque, _: ?*c.wl_output, _: u32, _: i32, _: i32, _: i32) callconv(.c) void {}

fn outputDone(_: ?*anyopaque, _: ?*c.wl_output) callconv(.c) void {}

fn outputScale(data: ?*anyopaque, output: ?*c.wl_output, scale: i32) callconv(.c) void {
    const self = selfFrom(data);
    const wl_output = output orelse return;
    if (self.findOutputInfo(wl_output)) |info| {
        info.scale = if (scale > 0) @intCast(scale) else 1;
    }
}

const output_listener = c.wl_output_listener{
    .geometry = outputGeometry,
    .mode = outputMode,
    .done = outputDone,
    .scale = outputScale,
};

fn surfaceEnter(data: ?*anyopaque, _: ?*c.wl_surface, output: ?*c.wl_output) callconv(.c) void {
    const self = selfFrom(data);
    const wl_output = output orelse return;
    if (self.findOutputInfo(wl_output)) |info| info.entered = true;
}

fn surfaceLeave(data: ?*anyopaque, _: ?*c.wl_surface, output: ?*c.wl_output) callconv(.c) void {
    const self = selfFrom(data);
    const wl_output = output orelse return;
    if (self.findOutputInfo(wl_output)) |info| info.entered = false;
}

const surface_listener = c.wl_surface_listener{
    .enter = surfaceEnter,
    .leave = surfaceLeave,
};
