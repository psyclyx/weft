//! Cocoa window: the macOS Platform. AppKit — the application, the window,
//! the view, text input, the pasteboard — is driven from Objective-C
//! (`cocoa/window.m`, behind the C ABI in `cocoa/window.h`), because that is
//! what AppKit is written for and what its headers check. Everything with a
//! rule in it lives here and in Zig modules the Linux suite runs: what a key
//! is called (`cocoa_keys.zig`, in xkb's vocabulary, `keysym.zig`), what a
//! gesture is (`pointer.zig`), what the clipboard holds (`clipboard.zig`).
//!
//! Differences from Wayland, each forced by the platform:
//! - Events arrive on a Mach port, not an fd: `fd` is -1 and the scheduler's
//!   sleep happens in AppKit's event queue instead (`wait`), with the
//!   scheduler's fds attached to the run loop.
//! - AppKit repeats held keys itself (`isARepeat` key-downs), so there is no
//!   repeat timer: `repeatDueNs` is always null.
//! - The pasteboard is read synchronously but only when it changed
//!   (`changeCount`), once per wake in `pumpEvents`; `clipboardText` is the
//!   last read, so a paste never waits on another process.
//! - Live resize runs inside AppKit's own tracking loop: the window keeps its
//!   last frame (stretched) until the drag ends, then redraws at the new size.

comptime {
    if (@import("builtin").os.tag != .macos) @compileError("platform/cocoa.zig is macOS-only");
}

const std = @import("std");
const platform = @import("root.zig");
const keys = @import("cocoa_keys.zig");
const keysym = @import("keysym.zig");
const KeyQueue = @import("key_queue.zig").KeyQueue;

const c = @cImport(@cInclude("window.h"));

pub const KeyEvent = platform.KeyEvent;
pub const Mods = platform.Mods;
pub const PointerEvent = platform.PointerEvent;

pub const Window = struct {
    cocoa: *c.WeftCocoa,
    /// The content view in points, and its backing scale (pixels per point).
    width: u32,
    height: u32,
    scale: u32,
    resized: bool = false,
    close_requested: bool = false,

    keys: KeyQueue = .{},
    /// Pointer input: AppKit's raw facts go into the platform-neutral gesture
    /// reducer, which owns click counting and wheel steps.
    gestures: platform.pointer.Gestures = .{},

    /// The pasteboard as last read, and the `changeCount` it was read at.
    clip: platform.clipboard.Store = .{},
    clip_seen: c_long = -1,

    pub fn init(width: u32, height: u32, title: [*:0]const u8, app_id: [*:0]const u8) !*Window {
        _ = app_id; // a bundle identifier comes from Info.plist, not the window
        const gpa = std.heap.c_allocator;
        const self = try gpa.create(Window);
        errdefer gpa.destroy(self);
        self.* = .{ .cocoa = undefined, .width = width, .height = height, .scale = 1 };
        const sink: c.WeftCocoaSink = .{
            .ctx = self,
            .key = onKey,
            .pointer = onPointer,
            .resized = onResized,
            .close_requested = onCloseRequested,
        };
        self.cocoa = c.weft_cocoa_create(width, height, title, &sink) orelse return error.CocoaWindowFailed;
        c.weft_cocoa_size(self.cocoa, &self.width, &self.height, &self.scale);
        self.refreshClipboard();
        return self;
    }

    pub fn deinit(self: *Window) void {
        c.weft_cocoa_destroy(self.cocoa);
        self.clip.deinit(std.heap.c_allocator);
        std.heap.c_allocator.destroy(self);
    }

    /// No fd: AppKit's events arrive on a Mach port. The scheduler sleeps in
    /// `wait` instead.
    pub fn fd(_: *const Window) i32 {
        return -1;
    }

    /// The scheduler's sleep, in AppKit's event queue with `fds` attached to
    /// the run loop: wakes for a window-server event, a ready fd, or the
    /// timeout, and reports the fds as `poll` would.
    pub fn wait(self: *Window, fds: []std.posix.pollfd, timeout_ms: i32) usize {
        return c.weft_cocoa_wait(self.cocoa, @ptrCast(fds.ptr), fds.len, timeout_ms);
    }

    /// The content view a GL context presents through.
    pub fn surfaceSource(self: *const Window) platform.SurfaceSource {
        return .{ .cocoa = .{ .view = c.weft_cocoa_view(self.cocoa).? } };
    }

    /// Dispatch every queued AppKit event (into this window's queues, through
    /// the sink) and pick up a pasteboard another application changed.
    pub fn pumpEvents(self: *Window) void {
        c.weft_cocoa_pump(self.cocoa);
        self.refreshClipboard();
    }

    pub fn shouldClose(self: *const Window) bool {
        return self.close_requested;
    }

    /// Take the close request (the close button, or Quit), if there is one:
    /// the app decides what it means (a quit that may refuse while work is
    /// unsaved).
    pub fn takeCloseRequest(self: *Window) bool {
        defer self.close_requested = false;
        return self.close_requested;
    }

    pub fn framebufferSize(self: *const Window) [2]u32 {
        return .{ self.width * self.scale, self.height * self.scale };
    }

    pub fn consumeResized(self: *Window) bool {
        defer self.resized = false;
        return self.resized;
    }

    pub fn bufferScale(self: *const Window) u32 {
        return self.scale;
    }

    pub fn nextKeyEvent(self: *Window) ?KeyEvent {
        return self.keys.next();
    }

    pub fn nextPointerEvent(self: *Window) ?PointerEvent {
        return self.gestures.next();
    }

    /// AppKit repeats held keys itself.
    pub fn repeatDueNs(_: *const Window) ?u64 {
        return null;
    }

    /// xkb's name for a keysym — the vocabulary every binding is written in
    /// (`keysym.zig`).
    pub fn keysymName(buf: []u8, sym: u32) []const u8 {
        return keysym.name(buf, sym);
    }

    pub fn clipboardText(self: *const Window) []const u8 {
        return self.clip.text();
    }

    /// Put `bytes` on the pasteboard and remember them.
    pub fn clipboardSet(self: *Window, bytes: []const u8) void {
        self.clip.set(std.heap.c_allocator, bytes) catch return;
        c.weft_cocoa_pasteboard_write(bytes.ptr, bytes.len);
        // Our own write is already in `clip`; don't read it back.
        self.clip_seen = c.weft_cocoa_pasteboard_change_count();
    }

    /// No fd: the pasteboard is read in `pumpEvents`.
    pub fn clipboardFd(_: *const Window) i32 {
        return -1;
    }

    fn refreshClipboard(self: *Window) void {
        const count = c.weft_cocoa_pasteboard_change_count();
        if (count == self.clip_seen) return;
        self.clip_seen = count;
        const Deliver = struct {
            fn deliver(ctx: ?*anyopaque, text: [*c]const u8, len: usize) callconv(.c) void {
                const w: *Window = @ptrCast(@alignCast(ctx.?));
                w.clip.set(std.heap.c_allocator, text[0..len]) catch {};
            }
        };
        c.weft_cocoa_pasteboard_read(self, Deliver.deliver);
    }
};

comptime {
    platform.assertPlatform(Window);
}

fn selfFrom(ctx: ?*anyopaque) *Window {
    return @ptrCast(@alignCast(ctx.?));
}

fn modsOf(bits: u32) Mods {
    return .{
        .shift = bits & c.WEFT_COCOA_MOD_SHIFT != 0,
        .ctrl = bits & c.WEFT_COCOA_MOD_CTRL != 0,
        .alt = bits & c.WEFT_COCOA_MOD_META != 0,
        .logo = bits & c.WEFT_COCOA_MOD_SUPER != 0,
    };
}

fn slice(ptr: [*c]const u8, len: usize) []const u8 {
    return if (len == 0) "" else ptr[0..len];
}

fn onKey(ctx: ?*anyopaque, key: [*c]const c.WeftCocoaKey) callconv(.c) void {
    const self = selfFrom(ctx);
    const k = key.*;
    const raw: keys.Raw = .{
        .keycode = k.keycode,
        .pressed = k.pressed != 0,
        .mods = modsOf(k.mods),
        .text = slice(k.text, k.text_len),
        .base = slice(k.base, k.base_len),
    };
    if (keys.translate(raw)) |ev| return self.keys.push(ev);
    // An input method can commit several characters at once ("日本"): each is
    // its own key, as if typed one by one.
    if (raw.text.len == 0) return;
    var it = (std.unicode.Utf8View.init(raw.text) catch return).iterator();
    while (it.nextCodepointSlice()) |one| {
        if (keys.translate(.{ .keycode = keys.vk.none, .pressed = true, .mods = .{}, .text = one, .base = "" })) |ev|
            self.keys.push(ev);
    }
}

fn onPointer(ctx: ?*anyopaque, ptr: [*c]const c.WeftCocoaPointer) callconv(.c) void {
    const self = selfFrom(ctx);
    const p = ptr.*;
    const mods = modsOf(p.mods);
    const g = &self.gestures;
    switch (p.kind) {
        c.WEFT_COCOA_POINTER_MOTION => g.motion(p.x, p.y, mods),
        c.WEFT_COCOA_POINTER_PRESS, c.WEFT_COCOA_POINTER_RELEASE => {
            // A press can be the first thing a window hears (the click that
            // focuses it): place the pointer before the button.
            g.warp(p.x, p.y);
            g.button(p.button, p.kind == c.WEFT_COCOA_POINTER_PRESS, p.time_ms, mods);
        },
        c.WEFT_COCOA_POINTER_SCROLL => {
            g.warp(p.x, p.y);
            // AppKit's deltas move the CONTENT (positive: toward the top/left
            // of the document); the reducer's move the VIEW, like wl_pointer's.
            // A trackpad reports points, which are wl_pointer units already; a
            // wheel reports lines, one per detent.
            const per = if (p.precise != 0) 1 else platform.pointer.wheel_units_per_step;
            if (p.dy != 0) g.axis(.vertical, -p.dy * per);
            if (p.dx != 0) g.axis(.horizontal, -p.dx * per);
            g.frame(mods);
            if (p.ended != 0) {
                g.axisStop(.vertical);
                g.axisStop(.horizontal);
            }
        },
        c.WEFT_COCOA_POINTER_ENTER => g.warp(p.x, p.y),
        c.WEFT_COCOA_POINTER_LEAVE => g.leave(mods),
        else => {},
    }
}

fn onResized(ctx: ?*anyopaque, width: u32, height: u32, scale: u32) callconv(.c) void {
    const self = selfFrom(ctx);
    const next_scale = @max(scale, 1);
    if (width == self.width and height == self.height and next_scale == self.scale) return;
    self.width = width;
    self.height = height;
    self.scale = next_scale;
    self.resized = true;
}

fn onCloseRequested(ctx: ?*anyopaque) callconv(.c) void {
    selfFrom(ctx).close_requested = true;
}
