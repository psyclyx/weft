//! Pure xdg-shell configure state.  Wayland may send several toplevel
//! configures before their xdg_surface configure/ack boundary; this reducer
//! keeps only the newest extent and makes the ack/geometry decision explicit.

const std = @import("std");

pub const Extent = struct {
    width: u32,
    height: u32,

    pub fn eql(a: Extent, b: Extent) bool {
        return a.width == b.width and a.height == b.height;
    }

    pub fn nonZero(self: Extent) bool {
        return self.width != 0 and self.height != 0;
    }
};

pub const ToplevelConfigure = struct {
    /// xdg-shell uses a non-positive dimension to mean that the client
    /// chooses that dimension.  Keep the last accepted value independently
    /// for width and height.
    width: i32,
    height: i32,
};

pub const SurfaceConfigure = struct {
    /// Geometry is sent only for a usable extent. The caller must send it
    /// after acknowledging the configure and commit before attempting a
    /// present.
    geometry: ?Extent = null,
    extent: Extent,
    extent_changed: bool,
};

pub const State = struct {
    extent: Extent,
    pending_extent: ?Extent = null,
    scale: u32 = 1,
    resize_pending: bool = false,

    pub fn init(width: u32, height: u32) State {
        return .{ .extent = .{ .width = width, .height = height } };
    }

    /// Coalesce all superseded toplevel extents until the next surface
    /// configure, retaining each non-positive dimension independently.
    pub fn toplevelConfigure(self: *State, configure: ToplevelConfigure) void {
        const base = self.pending_extent orelse self.extent;
        self.pending_extent = .{
            .width = if (configure.width > 0) @intCast(configure.width) else base.width,
            .height = if (configure.height > 0) @intCast(configure.height) else base.height,
        };
    }

    /// Consume the newest toplevel configure at the protocol's ack boundary.
    /// The caller performs the actual ack first, then applies `geometry` and
    /// commits (if non-null), preserving Wayland's required ordering.
    pub fn surfaceConfigure(self: *State) SurfaceConfigure {
        const next = self.pending_extent orelse self.extent;
        self.pending_extent = null;
        const changed = !next.eql(self.extent);
        self.extent = next;
        if (changed) self.resize_pending = true;
        return .{
            .geometry = if (next.nonZero()) next else null,
            .extent = next,
            .extent_changed = changed,
        };
    }

    /// Output enter/leave can change the buffer scale without changing
    /// logical toplevel geometry.  It is still a framebuffer resize.
    pub fn setScale(self: *State, scale: u32) bool {
        const next = @max(scale, 1);
        if (next == self.scale) return false;
        self.scale = next;
        self.resize_pending = true;
        return true;
    }

    pub fn framebufferExtent(self: *const State) Extent {
        return .{ .width = self.extent.width * @max(self.scale, 1), .height = self.extent.height * @max(self.scale, 1) };
    }

    pub fn bufferScale(self: *const State) u32 {
        return @max(self.scale, 1);
    }

    pub fn consumeResized(self: *State) bool {
        const changed = self.resize_pending;
        self.resize_pending = false;
        return changed;
    }
};

test "configure reducer coalesces superseded extents at the ack boundary" {
    var state = State.init(800, 600);
    state.toplevelConfigure(.{ .width = 1024, .height = 768 });
    state.toplevelConfigure(.{ .width = 1280, .height = 720 });
    const result = state.surfaceConfigure();
    try std.testing.expect(result.extent_changed);
    try std.testing.expectEqual(@as(u32, 1280), result.extent.width);
    try std.testing.expectEqual(@as(u32, 720), result.extent.height);
    try std.testing.expectEqual(@as(u32, 1280), result.geometry.?.width);
    try std.testing.expect(state.consumeResized());
    try std.testing.expect(!state.consumeResized());
}

test "configure reducer retains unspecified dimensions" {
    var state = State.init(800, 600);
    state.toplevelConfigure(.{ .width = 1024, .height = 0 });
    const width_only = state.surfaceConfigure();
    try std.testing.expect(width_only.extent_changed);
    try std.testing.expectEqual(@as(u32, 1024), width_only.extent.width);
    try std.testing.expectEqual(@as(u32, 600), width_only.extent.height);
    try std.testing.expect(state.consumeResized());

    state.toplevelConfigure(.{ .width = 0, .height = 480 });
    const height_only = state.surfaceConfigure();
    try std.testing.expectEqual(@as(u32, 1024), height_only.extent.width);
    try std.testing.expectEqual(@as(u32, 480), height_only.extent.height);
    try std.testing.expect(state.consumeResized());
}

test "configure reducer handles scale and state-only configures" {
    var state = State.init(800, 600);
    state.toplevelConfigure(.{ .width = 0, .height = 0 });
    const state_only = state.surfaceConfigure();
    try std.testing.expect(!state_only.extent_changed);
    try std.testing.expect(!state.consumeResized());

    try std.testing.expect(state.setScale(2));
    try std.testing.expectEqual(@as(u32, 1600), state.framebufferExtent().width);
    try std.testing.expect(state.consumeResized());
    try std.testing.expect(!state.setScale(2));
    try std.testing.expect(state.setScale(0));
    try std.testing.expectEqual(@as(u32, 800), state.framebufferExtent().width);
}
