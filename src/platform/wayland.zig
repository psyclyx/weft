//! Wayland window: registry, xdg-shell toplevel, xkbcommon keyboard, hidpi
//! scale. Adapted from phasekeep's platform layer with one editor-shaped
//! change: input is an ordered event QUEUE of xkb-translated key events
//! (keysym + UTF-8 + modifiers), not polled key-state — an editor consumes
//! keystrokes, it does not sample buttons.
//!
//! The event pump never blocks; the frame loop's real wait is the
//! swapchain. Key repeat is the consumer's concern (repeat rate/delay are
//! surfaced from the compositor for milestone 4's input layer).

const std = @import("std");
const linux = std.os.linux;

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

/// One translated keyboard event, in press order.
pub const KeyEvent = struct {
    /// xkb keysym (layout-resolved, e.g. XKB_KEY_a, XKB_KEY_Escape).
    keysym: u32,
    /// UTF-8 text this key produces under current modifiers ("" if none).
    utf8: [8]u8 = @splat(0),
    utf8_len: u8 = 0,
    mods: Mods = .{},
    pressed: bool,

    pub fn text(self: *const KeyEvent) []const u8 {
        return self.utf8[0..self.utf8_len];
    }
};

pub const Mods = packed struct {
    ctrl: bool = false,
    alt: bool = false,
    shift: bool = false,
    logo: bool = false,
};

pub const Window = struct {
    const max_outputs = 8;
    const key_queue_len = 128;
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

    width: u32,
    height: u32,
    buffer_scale: u32 = 1,
    outputs: [max_outputs]OutputInfo = [_]OutputInfo{.{}} ** max_outputs,
    pending_geometry_commit: bool = true,
    resized: bool = false,
    close_requested: bool = false,
    focused: bool = true,

    /// Ordered key events since last drain; overflow drops oldest (and
    /// counts, loudly, in debug).
    key_events: [key_queue_len]KeyEvent = undefined,
    key_head: usize = 0,
    key_tail: usize = 0,
    key_dropped: usize = 0,

    // Key repeat: Wayland delivers only down/up, so the client synthesizes
    // repeats for the most-recently-held key that the xkb keymap marks
    // repeatable. Reuses the press-time event (mods + utf8).
    repeat_ev: ?KeyEvent = null,
    repeat_code: u32 = 0,
    repeat_next_ns: u64 = 0,

    // Pointer state (sampled; fine for scroll/click).
    mouse_x: f64 = 0,
    mouse_y: f64 = 0,
    mouse_down: [3]bool = @splat(false),
    mouse_pressed: [3]bool = @splat(false),
    wheel_accum: f64 = 0,

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
            .width = width,
            .height = height,
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
        return self;
    }

    pub fn deinit(self: *Window) void {
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
        self.emitKeyRepeats();
        self.refreshBufferScale();
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
            self.pushKeyEvent(rk);
            self.repeat_next_ns += interval;
        }
        // Resync after a long stall instead of catching up all at once.
        if (now > self.repeat_next_ns + interval * 8) self.repeat_next_ns = now + interval;
    }

    pub fn shouldClose(self: *const Window) bool {
        return self.close_requested;
    }

    pub fn framebufferSize(self: *const Window) [2]u32 {
        const scale = @max(self.buffer_scale, 1);
        return .{ self.width * scale, self.height * scale };
    }

    pub fn consumeResized(self: *Window) bool {
        const changed = self.resized;
        self.resized = false;
        return changed;
    }

    /// Next key event in press order, or null.
    pub fn nextKeyEvent(self: *Window) ?KeyEvent {
        if (self.key_head == self.key_tail) return null;
        const ev = self.key_events[self.key_head % key_queue_len];
        self.key_head += 1;
        return ev;
    }

    fn pushKeyEvent(self: *Window, ev: KeyEvent) void {
        if (self.key_tail - self.key_head >= key_queue_len) {
            self.key_head += 1; // drop oldest
            self.key_dropped += 1;
            if (std.debug.runtime_safety) {
                std.log.warn("key event queue overflow ({d} dropped)", .{self.key_dropped});
            }
        }
        self.key_events[self.key_tail % key_queue_len] = ev;
        self.key_tail += 1;
    }

    pub fn consumeMousePressed(self: *Window, button: usize) bool {
        const pressed = self.mouse_pressed[button];
        self.mouse_pressed[button] = false;
        return pressed;
    }

    pub fn consumeWheel(self: *Window) f64 {
        const w = self.wheel_accum;
        self.wheel_accum = 0;
        return w;
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
        if (next == self.buffer_scale) return;
        self.buffer_scale = next;
        self.resized = true;
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

fn selfFrom(data: ?*anyopaque) *Window {
    return @ptrCast(@alignCast(data.?));
}

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
        self.seat = @ptrCast(c.wl_registry_bind(reg, name, &c.wl_seat_interface, @min(version, 5)));
        if (self.seat) |seat| {
            _ = c.wl_seat_add_listener(seat, &seat_listener, self);
        }
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
    c.xdg_surface_ack_configure(xdg_surface.?, serial);
    if (self.pending_geometry_commit and self.width > 0 and self.height > 0) {
        c.xdg_surface_set_window_geometry(
            xdg_surface.?,
            0,
            0,
            @intCast(self.width),
            @intCast(self.height),
        );
        c.wl_surface_commit(self.surface);
        self.pending_geometry_commit = false;
    }
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
    self.pending_geometry_commit = true;
    if (width > 0 and height > 0) {
        const w: u32 = @intCast(width);
        const h: u32 = @intCast(height);
        if (w != self.width or h != self.height) {
            self.width = w;
            self.height = h;
            self.resized = true;
        }
    }
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

fn pointerEnter(data: ?*anyopaque, _: ?*c.wl_pointer, _: u32, _: ?*c.wl_surface, sx: c.wl_fixed_t, sy: c.wl_fixed_t) callconv(.c) void {
    const self = selfFrom(data);
    self.mouse_x = c.wl_fixed_to_double(sx);
    self.mouse_y = c.wl_fixed_to_double(sy);
}

fn pointerLeave(_: ?*anyopaque, _: ?*c.wl_pointer, _: u32, _: ?*c.wl_surface) callconv(.c) void {}

fn pointerMotion(data: ?*anyopaque, _: ?*c.wl_pointer, _: u32, sx: c.wl_fixed_t, sy: c.wl_fixed_t) callconv(.c) void {
    const self = selfFrom(data);
    self.mouse_x = c.wl_fixed_to_double(sx);
    self.mouse_y = c.wl_fixed_to_double(sy);
}

fn pointerButton(data: ?*anyopaque, _: ?*c.wl_pointer, _: u32, _: u32, button: u32, state: u32) callconv(.c) void {
    const self = selfFrom(data);
    // linux/input-event-codes.h values; avoid the header for just three.
    const BTN_LEFT: u32 = 0x110;
    const BTN_RIGHT: u32 = 0x111;
    const BTN_MIDDLE: u32 = 0x112;
    const slot: ?usize = switch (button) {
        BTN_LEFT => 0,
        BTN_RIGHT => 1,
        BTN_MIDDLE => 2,
        else => null,
    };
    if (slot) |s| {
        const down = state == c.WL_POINTER_BUTTON_STATE_PRESSED;
        self.mouse_down[s] = down;
        if (down) self.mouse_pressed[s] = true;
    }
}

fn pointerAxis(data: ?*anyopaque, _: ?*c.wl_pointer, _: u32, axis: u32, value: c.wl_fixed_t) callconv(.c) void {
    const self = selfFrom(data);
    if (axis == c.WL_POINTER_AXIS_VERTICAL_SCROLL) {
        self.wheel_accum -= c.wl_fixed_to_double(value) / 10.0;
    }
}

fn pointerFrame(_: ?*anyopaque, _: ?*c.wl_pointer) callconv(.c) void {}
fn pointerAxisSource(_: ?*anyopaque, _: ?*c.wl_pointer, _: u32) callconv(.c) void {}
fn pointerAxisStop(_: ?*anyopaque, _: ?*c.wl_pointer, _: u32, _: u32) callconv(.c) void {}
fn pointerAxisDiscrete(_: ?*anyopaque, _: ?*c.wl_pointer, _: u32, _: i32) callconv(.c) void {}

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

fn keyboardEnter(data: ?*anyopaque, _: ?*c.wl_keyboard, _: u32, _: ?*c.wl_surface, _: ?*c.wl_array) callconv(.c) void {
    selfFrom(data).focused = true;
}

fn keyboardLeave(data: ?*anyopaque, _: ?*c.wl_keyboard, _: u32, _: ?*c.wl_surface) callconv(.c) void {
    const self = selfFrom(data);
    self.focused = false;
    self.repeat_ev = null; // no stuck repeat when focus leaves
}

fn keyboardKey(
    data: ?*anyopaque,
    _: ?*c.wl_keyboard,
    _: u32,
    _: u32,
    key: u32,
    state: u32,
) callconv(.c) void {
    const self = selfFrom(data);
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
    const chorded = mods.ctrl or mods.alt;
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
    self.pushKeyEvent(ev);

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
