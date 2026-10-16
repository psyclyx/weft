//! The OpenGL `RenderState` (`-Dgpu=opengl`; the only API on macOS). It embeds
//! the shared `FrameBuilder` (View + pane tree + built panes) and adds a Skia
//! renderer on Ganesh GL, over the target's context.
//!
//! Where the frame lands is the target's to say (its type's `reads_back`):
//! - a window (`gfx/gl_context.zig`): Skia draws straight into the window's
//!   default framebuffer and the target swaps it. Nothing is copied or read
//!   back — the GPU-side frame is the presented one.
//! - headless (`gfx/headless_gl.zig`): Skia draws into its own render target
//!   and reads the frame back into the target, which keeps it for the caller.
//!
//! Every present redraws the whole built frame: a swapped GL back buffer has
//! undefined contents, so there is no "re-present the last pixels" path to
//! keep, and the built panes are cheap to replay.

const std = @import("std");
const skia = @import("weft_skia");
const frame = @import("frame.zig");
const FrameCtx = frame.FrameCtx;
const Active = frame.Active;
const FrameBuilder = @import("frame_builder.zig").FrameBuilder;
const shared = @import("render_skia.zig");
const core = @import("weft_core");

pub const RenderState = struct {
    gpa: std.mem.Allocator,
    fb: FrameBuilder,
    skia: skia.Skia,
    /// The target's context, current for every use of `skia`: Skia's GPU
    /// objects belong to the context they were made in, and one process can
    /// hold several (the e2e spine renders two heads side by side).
    target: Target,
    /// One-shot: the WEFT_SKIA_DUMP debug dump has fired (headless frames
    /// only — a window's frame is never on the CPU to dump).
    dumped: bool,

    /// The target, type-erased to what teardown needs of it.
    const Target = struct {
        ctx: *anyopaque,
        make_current: *const fn (ctx: *anyopaque) anyerror!void,

        fn of(ctx: anytype) Target {
            const Ctx = @TypeOf(ctx);
            return .{ .ctx = ctx, .make_current = struct {
                fn makeCurrent(erased: *anyopaque) anyerror!void {
                    const typed: Ctx = @ptrCast(@alignCast(erased));
                    try typed.makeCurrent();
                }
            }.makeCurrent };
        }

        fn makeCurrent(self: Target) !void {
            try self.make_current(self.ctx);
        }
    };

    pub fn init(
        self: *RenderState,
        gpa: std.mem.Allocator,
        ctx: anytype,
        font_bytes: []const u8,
        em: f32,
        active_id: core.Buffers.Id,
    ) !void {
        self.gpa = gpa;
        try self.fb.init(gpa, font_bytes, em, active_id);
        errdefer self.fb.deinit();

        // Skia resolves GL in the target's context, and every later call on it
        // runs with that context current (`present` through `beginFrame`,
        // `deinit` through `target`).
        self.target = .of(ctx);
        try ctx.makeCurrent();
        const proc = ctx.proc();
        self.skia = try skia.Skia.initGl(proc.get, proc.ctx);
        errdefer self.skia.deinit();
        std.log.info("weft: skia renderer — ganesh/opengl backend", .{});

        shared.registerFaces(&self.skia, &self.fb);
        self.dumped = false;
    }

    pub fn deinit(self: *RenderState) void {
        // Skia's GPU objects belong to the target's context, which outlives
        // us; free them with it current, not whichever head drew last.
        self.target.makeCurrent() catch |err| std.log.warn("render: GL context lost before teardown ({t})", .{err});
        self.skia.deinit();
        self.fb.deinit();
    }

    /// Backend-independent build (delegates to the shared `FrameBuilder`).
    pub fn buildFrame(self: *RenderState, fx: *const FrameCtx, act: Active) !void {
        return self.fb.buildFrame(fx, act);
    }

    /// Ask the plugins what the last frame had no answer to (delegates to the
    /// shared `FrameBuilder`); true when answers landed for the next frame.
    pub fn answerRequests(self: *RenderState, fx: *const FrameCtx) !bool {
        return self.fb.answerRequests(fx);
    }

    /// Draw the built frame into the target and present it. False when the
    /// target has nothing to draw into yet (a zero-size window), so the caller
    /// retries on a later wake.
    pub fn present(self: *RenderState, ctx: anytype, fb: [2]u32, frame_start: u64, had_input: bool) !bool {
        _ = fb; // geometry follows ctx.extent (kept in sync by the caller)
        if (!try ctx.beginFrame()) return false;
        self.fb.rebuilt = false;
        const w = ctx.extent.width;
        const h = ctx.extent.height;
        const bg = self.fb.view.theme.background;

        if (@TypeOf(ctx.*).reads_back) {
            try self.skia.begin(w, h, bg);
            shared.drawPanes(&self.skia, &self.fb);
            const f = try self.skia.end(w, h);
            ctx.submitPixels(f.pixels, f.row_bytes);
            shared.maybeDump(self.gpa, &self.dumped, f, false);
        } else {
            try self.skia.beginFramebuffer(0, w, h, ctx.stencilBits(), bg);
            shared.drawPanes(&self.skia, &self.fb);
            try self.skia.flush();
            try ctx.submitFrame();
        }

        shared.recordPresent(&self.fb, frame_start, had_input);
        return true;
    }
};
