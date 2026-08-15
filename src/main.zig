//! scion — milestone 3: the editor rendered. A Wayland window presents
//! a real `core.Editor` through snail's analytic glyph pipeline (curve/
//! band flat buffers, one pipeline per shape family); the frame loop's
//! only wait is the swapchain (FIFO vsync), and the input→commit→render
//! path is bracketed by the hot-section fence. Frame + input latency
//! percentiles log continuously.
//!
//!   scion [file] [--font path.ttf] [--em N]

const std = @import("std");
const wayland = @import("platform/wayland.zig");
const Context = @import("gfx/context.zig").Context;
const core = @import("core/core.zig");
const view_mod = @import("gfx/view.zig");
const stats_mod = @import("gfx/stats.zig");
const snail = @import("snail");
const snail_vk = @import("gfx/snail_vk/root.zig");
const vk = @import("vk.zig").c;

const embedded_font = @embedFile("font_mono");

const Args = struct {
    file: ?[]const u8 = null,
    font: ?[]const u8 = null,
    em: f32 = 15,
};

fn parseArgs(process_args: std.process.Args) Args {
    var out: Args = .{};
    var it = std.process.Args.Iterator.init(process_args);
    _ = it.skip(); // argv0
    while (it.next()) |a| {
        if (std.mem.eql(u8, a, "--font")) {
            out.font = it.next() orelse out.font;
        } else if (std.mem.eql(u8, a, "--em")) {
            if (it.next()) |v| out.em = std.fmt.parseFloat(f32, v) catch out.em;
        } else {
            out.file = a;
        }
    }
    return out;
}

pub fn main(init: std.process.Init) !void {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    // POSIX argv is static; the parsed slices stay valid for the run.
    const args = parseArgs(init.minimal.args);

    // ── Core ──
    var pool = try core.task.Pool.init(gpa, .{});
    defer pool.deinit();
    var editor = try core.Editor.init(gpa, pool, "user");
    defer editor.deinit(gpa);
    if (args.file) |path| {
        editor.openFile(gpa, path) catch |err| switch (err) {
            error.FileNotFound => {
                // New file: adopt the path, save creates it.
                editor.path = try gpa.dupe(u8, path);
            },
            else => |e| return e,
        };
    }

    // ── Window + Vulkan ──
    const window = try wayland.Window.init(1280, 800, "scion", "dev.psyclyx.scion");
    defer window.deinit();
    var fb = window.framebufferSize();
    const ctx = try Context.init(gpa, .{
        .display = window.display,
        .surface = window.surface,
    }, fb[0], fb[1], "scion");
    defer ctx.deinit();

    const vctx: snail_vk.VulkanContext = .{
        .physical_device = ctx.physical_device,
        .device = ctx.device,
        .graphics_queue = ctx.queue,
        .queue_family_index = ctx.queue_family,
        .render_pass = ctx.render_pass,
    };

    // ── Snail render path ──
    const font_bytes: []const u8 = if (args.font) |p| try core.file.readAlloc(gpa, p) else embedded_font;
    defer if (args.font != null) gpa.free(@constCast(font_bytes));
    var view = try view_mod.View.init(gpa, font_bytes, args.em);
    defer view.deinit();

    var layout: snail_vk.VulkanResourceLayout = undefined;
    try layout.init(vctx);
    defer layout.deinit();
    const resources = snail_vk.cacheResourceContext(vctx, &layout);
    var cache = try snail_vk.VulkanDeviceAtlas.init(gpa, view.pool, resources, .{});
    defer cache.deinit();
    var renderer = try snail_vk.Renderer.init(vctx, layout.desc_set_layout, 2 << 20, @import("gfx/context.zig").max_frames_in_flight, .disabled);
    defer renderer.deinit();

    // Initial (empty) upload establishes the live binding.
    var binding: [1]snail.render.records.Binding = undefined;
    try snail_vk.uploadAndWait(gpa, vctx, resources, ctx.command_pool, &cache, &.{&view.atlas}, &binding);

    var stats: stats_mod.Stats = .{};
    var seen_commits: usize = 0;
    var built: ?view_mod.Built = null;
    defer if (built) |*b| b.deinit(gpa);
    var instances: std.ArrayList(snail.render.records.Instance) = .empty;
    defer instances.deinit(gpa);
    var batches: std.ArrayList(snail.render.records.DrawBatch) = .empty;
    defer batches.deinit(gpa);
    var view_dirty = true;

    std.log.info("scion: rendering — {d} bytes open, em {d}", .{ editor.text().byteLen(), args.em });

    while (!window.shouldClose()) {
        const frame_start = stats_mod.nowNs();
        window.pumpEvents();

        if (window.consumeResized() or ctx.swapchain_stale) {
            fb = window.framebufferSize();
            try ctx.recreateSwapchain(fb[0], fb[1]);
            view_dirty = true;
        }

        // ── Input → commit (hot section: no blocking API compiles in) ──
        var had_input = false;
        core.task.beginHotSection();
        while (window.nextKeyEvent()) |ev| {
            if (!ev.pressed) continue;
            had_input = true;
            try handleKey(gpa, &editor, &view, ev, fb[1]);
        }
        core.task.endHotSection();
        if (window.shouldClose()) break;

        _ = editor.pollSave(gpa);
        if (editor.doc.commitCount() != seen_commits) {
            seen_commits = editor.doc.commitCount();
            view_dirty = true;
        }
        if (had_input) view_dirty = true; // cursor moves damage the view

        // ── Rebuild + upload on damage ──
        if (view_dirty) {
            view_dirty = false;
            view.scrollToCursor(&editor, fb[1]);
            const projection = snail.Mat4.ortho(0, @floatFromInt(fb[0]), @floatFromInt(fb[1]), 0, -1, 1);
            const world_to_pixel = snail.mvpToScenePixel(projection, @floatFromInt(fb[0]), @floatFromInt(fb[1])) orelse unreachable;

            var arena_state = std.heap.ArenaAllocator.init(gpa);
            defer arena_state.deinit();
            const b = try view.build(arena_state.allocator(), &editor, fb[0], fb[1], world_to_pixel);
            if (built) |*old| old.deinit(gpa);
            built = b;
            if (b.records_added != 0) {
                binding[0] = try snail_vk.uploadDeltaAndWait(gpa, vctx, resources, ctx.command_pool, &cache, binding[0], &view.atlas);
            }

            // Emit the instance/batch stream for the new picture.
            instances.clearRetainingCapacity();
            batches.clearRetainingCapacity();
            try instances.resize(gpa, b.shapes.len);
            try batches.resize(gpa, b.shapes.len);
            var ilen: usize = 0;
            var blen: usize = 0;
            _ = try snail.emit.emit(
                instances.items,
                batches.items,
                &ilen,
                &blen,
                binding[0],
                &view.atlas,
                b.shapes,
                .identity,
                .{ 1, 1, 1, 1 },
            );
            instances.items.len = ilen;
            batches.items.len = blen;
        }

        // ── Draw ──
        const cmd = try ctx.beginFrame() orelse continue;
        ctx.beginRenderPass(cmd, view.theme.background);
        renderer.beginFrame(ctx.current_frame);
        const draw_state: snail.render.target.DrawState = .{
            .mvp = snail.Mat4.ortho(0, @floatFromInt(fb[0]), @floatFromInt(fb[1]), 0, -1, 1),
            .surface = .{
                .pixel_width = fb[0],
                .pixel_height = fb[1],
                .encoding = if (ctx.surfaceEncodesSrgb()) .srgb else .linear,
            },
        };
        try renderer.render(cmd, &cache, draw_state, instances.items, batches.items);
        try ctx.endFrame();

        const frame_ns = stats_mod.nowNs() - frame_start;
        stats.recordFrame(frame_ns);
        if (had_input) stats.recordInput(frame_ns);
        _ = stats.maybeLog(600);
    }
    ctx.waitIdle();
}

/// Translate one key event into editor ops. Runs inside the hot
/// section: everything here is allocation-only.
fn handleKey(gpa: std.mem.Allocator, editor: *core.Editor, view: *view_mod.View, ev: wayland.KeyEvent, fb_h: u32) !void {
    const c = wayland.c;
    if (ev.mods.ctrl) {
        switch (ev.keysym) {
            c.XKB_KEY_s => try editor.requestSave(gpa),
            c.XKB_KEY_z => _ = try editor.undo(gpa),
            c.XKB_KEY_y => _ = try editor.redo(gpa),
            c.XKB_KEY_a => editor.moveLineStart(),
            c.XKB_KEY_e => editor.moveLineEnd(),
            c.XKB_KEY_space => try editor.setMark(gpa),
            c.XKB_KEY_g => editor.clearSelection(),
            else => {},
        }
        return;
    }
    switch (ev.keysym) {
        c.XKB_KEY_BackSpace => try editor.deleteBackward(gpa),
        c.XKB_KEY_Delete => try editor.deleteForward(gpa),
        c.XKB_KEY_Return => try editor.insertText(gpa, "\n"),
        c.XKB_KEY_Tab => try editor.insertText(gpa, "\t"),
        c.XKB_KEY_Left => editor.moveLeft(),
        c.XKB_KEY_Right => editor.moveRight(),
        c.XKB_KEY_Up => editor.moveUp(),
        c.XKB_KEY_Down => editor.moveDown(),
        c.XKB_KEY_Home => editor.moveLineStart(),
        c.XKB_KEY_End => editor.moveLineEnd(),
        c.XKB_KEY_Page_Up => {
            const rows = view.visibleRows(fb_h);
            for (0..rows) |_| editor.moveUp();
        },
        c.XKB_KEY_Page_Down => {
            const rows = view.visibleRows(fb_h);
            for (0..rows) |_| editor.moveDown();
        },
        else => {
            const text = ev.text();
            if (text.len > 0 and !(text.len == 1 and text[0] < 0x20)) {
                try editor.insertText(gpa, text);
            }
        },
    }
}
