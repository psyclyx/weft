//! scion — the assembled editor: a Wayland window presenting a
//! `core.Editor` through snail's analytic glyph pipeline, all behavior
//! routed key → keymap → command ABI (built-ins and config/plugin
//! commands through the same door). The frame loop's only wait is the
//! swapchain (FIFO vsync); the input→commit→render path is bracketed by
//! the hot-section fence; frame + input latency percentiles log
//! continuously.
//!
//!   scion [file] [--font path.ttf] [--em N] [--config init.fnl]

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
    config: ?[]const u8 = null,
    em: f32 = 15,
};

fn parseArgs(process_args: std.process.Args) Args {
    var out: Args = .{};
    var it = std.process.Args.Iterator.init(process_args);
    _ = it.skip(); // argv0
    while (it.next()) |a| {
        if (std.mem.eql(u8, a, "--font")) {
            out.font = it.next() orelse out.font;
        } else if (std.mem.eql(u8, a, "--config")) {
            out.config = it.next() orelse out.config;
        } else if (std.mem.eql(u8, a, "--em")) {
            if (it.next()) |v| out.em = std.fmt.parseFloat(f32, v) catch out.em;
        } else {
            out.file = a;
        }
    }
    return out;
}

pub fn main(init: std.process.Init) !void {
    // Debug builds get leak checking; release builds get the lean
    // allocator (DebugAllocator's bookkeeping costs real RSS).
    const debug_alloc = @import("builtin").mode == .Debug;
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer if (debug_alloc) {
        _ = gpa_state.deinit();
    };
    const gpa = if (debug_alloc) gpa_state.allocator() else std.heap.c_allocator;

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

    // ── Command surface + config plugin ──
    var commands: core.command.Commands = .empty;
    defer commands.deinit(gpa);
    var keymap: core.Keymap = .empty;
    defer keymap.deinit(gpa);
    var pick_state: core.Pick = .empty;
    defer pick_state.deinit(gpa);
    var caps = core.Caps.init(gpa, core.task.nowNs);
    defer caps.deinit();
    var quit = false;
    var cmd_ctx: core.command.Context = .{
        .gpa = gpa,
        .editor = &editor,
        .commands = &commands,
        .keymap = &keymap,
        .pick = &pick_state,
        .caps = &caps,
        .quit = &quit,
    };
    try core.builtins.install(gpa, &commands, &keymap);
    // Completion is a capability consumer: race-and-refine over every
    // registered edit/completion provider.
    var completion_ui: core.complete_ui.CompletionUi = .empty;
    _ = try commands.bind(gpa, "complete", completion_ui.commandSpec());
    var syntax: ?*core.syntax.Syntax = null;
    defer if (syntax) |s| s.destroy();
    if (editor.path) |p| {
        if (core.syntax.forPath(p)) |spec| {
            syntax = core.syntax.Syntax.create(gpa, spec, &editor.doc) catch |err| blk: {
                std.log.warn("syntax {s} unavailable: {t}", .{ spec.name, err });
                break :blk null;
            };
        }
    }
    var lsp: ?*core.lsp.Lsp = null;
    defer if (lsp) |l| l.destroy();
    if (editor.path) |p| {
        if (std.mem.endsWith(u8, p, ".zig")) {
            lsp = core.lsp.Lsp.create(gpa, &.{"zls"}, p, &editor.doc, init.minimal.environ) catch |err| blk: {
                std.log.warn("lsp unavailable: {t}", .{err});
                break :blk null;
            };
            if (lsp) |l| {
                // Diagnostics flow through the capability feed layer
                // (host-scoped); the view reads the layer, not the plugin.
                const diag_layer = try caps.registerFeed(&editor.doc, "edit/diagnostics", "diagnostics", .host, "lsp.zls");
                l.attachDiagnostics(diag_layer);
                _ = try commands.bind(gpa, "goto-definition", core.lsp.definitionCommand(l));
            }
        }
    }
    const config_plugin = try core.Plugin.create(gpa, &cmd_ctx, "config");
    defer config_plugin.destroy();
    _ = try commands.bind(gpa, "eval", core.plugin.evalCommand(config_plugin));
    try loadConfig(gpa, config_plugin, args.config, init.minimal.environ);

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

    while (!window.shouldClose() and !quit) {
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
            try dispatchKey(&cmd_ctx, &view, ev, fb[1]);
        }
        core.task.endHotSection();
        if (window.shouldClose()) break;

        _ = editor.pollSave(gpa);
        if (lsp) |l| {
            if (try l.tick(&cmd_ctx)) view_dirty = true;
        }
        if (try completion_ui.tick(&cmd_ctx)) view_dirty = true;
        if (editor.doc.commitCount() != seen_commits) {
            seen_commits = editor.doc.commitCount();
            view_dirty = true;
        }
        if (had_input) view_dirty = true; // cursor moves damage the view

        // ── Rebuild + upload on damage ──
        if (view_dirty) {
            view_dirty = false;
            const projection = snail.Mat4.ortho(0, @floatFromInt(fb[0]), @floatFromInt(fb[1]), 0, -1, 1);
            const world_to_pixel = snail.mvpToScenePixel(projection, @floatFromInt(fb[0]), @floatFromInt(fb[1])) orelse unreachable;

            if (syntax) |syn| _ = try syn.sync(gpa, &editor.doc);
            const hud: view_mod.Hud = .{
                .mode = keymap.currentMode(),
                .file = editor.path,
                .dirty = editor.isDirty(gpa) catch true,
                .save_failed = editor.save_state == .failed,
                .pick = if (pick_state.active) &pick_state else null,
                .syntax = syntax,
                .diag_layer = caps.layers.find("diagnostics"),
                .cursor_diag = blk: {
                    const dl = caps.layers.find("diagnostics") orelse break :blk null;
                    const cur = editor.cursorOffset();
                    for (0..dl.spanCount()) |i| {
                        const d = dl.resolvedSpan(i);
                        if (cur >= d.start and cur <= d.end) break :blk d.message;
                    }
                    break :blk null;
                },
            };
            var arena_state = std.heap.ArenaAllocator.init(gpa);
            defer arena_state.deinit();
            const b = try view.build(arena_state.allocator(), &editor, hud, fb[0], fb[1], world_to_pixel);
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

/// One key event → keymap lookup → command. Runs inside the hot
/// section: dispatch is a table lookup plus the command itself,
/// allocation-only. Unbound printable input becomes `insert-text` —
/// itself a command; there is no editing path around the ABI.
fn dispatchKey(ctx: *core.command.Context, view: *view_mod.View, ev: wayland.KeyEvent, fb_h: u32) !void {
    const c = wayland.c;
    // Paging needs viewport geometry the core doesn't know; view-aware
    // dispatch stays here.
    if (ev.keysym == c.XKB_KEY_Page_Up or ev.keysym == c.XKB_KEY_Page_Down) {
        const rows = view.visibleRows(fb_h);
        for (0..rows) |_| {
            if (ev.keysym == c.XKB_KEY_Page_Up) ctx.editor.moveUp() else ctx.editor.moveDown();
        }
        return;
    }

    var name_buf: [64]u8 = undefined;
    const n = c.xkb_keysym_get_name(ev.keysym, &name_buf, name_buf.len);
    if (n > 0) {
        var spec_buf: [80]u8 = undefined;
        const spec = core.Keymap.keyspec(&spec_buf, ev.mods.ctrl, ev.mods.alt, name_buf[0..@intCast(n)]);
        if (ctx.keymap.lookup(spec)) |cmd_name| {
            _ = core.command.run(ctx.commands, ctx, cmd_name, &.{}) catch |err| {
                std.log.warn("command {s} failed: {t}", .{ cmd_name, err });
            };
            return;
        }
    }
    if (ev.mods.ctrl or ev.mods.alt) return;
    const text = ev.text();
    if (text.len > 0 and !(text.len == 1 and text[0] < 0x20)) {
        // Unbound printable input runs the mode's text command (the
        // modal posture: normal mode has none and swallows it).
        const tc = ctx.keymap.textCommand() orelse return;
        _ = core.command.run(ctx.commands, ctx, tc, &.{.{ .string = text }}) catch |err| {
            std.log.warn("{s} failed: {t}", .{ tc, err });
        };
    }
}

/// Resolve and evaluate the user config: `--config` wins, else
/// $XDG_CONFIG_HOME/scion/init.fnl, else ~/.config/scion/init.fnl.
/// Read-only; a missing default config means built-in defaults.
fn loadConfig(gpa: std.mem.Allocator, plugin: *core.Plugin, override: ?[]const u8, environ: std.process.Environ) !void {
    var buf: [512]u8 = undefined;
    const path = override orelse blk: {
        if (environ.getPosix("XDG_CONFIG_HOME")) |x| {
            break :blk std.fmt.bufPrint(&buf, "{s}/scion/init.fnl", .{x}) catch return;
        }
        if (environ.getPosix("HOME")) |h| {
            break :blk std.fmt.bufPrint(&buf, "{s}/.config/scion/init.fnl", .{h}) catch return;
        }
        return;
    };
    const src = core.file.readAlloc(gpa, path) catch |err| switch (err) {
        error.FileNotFound => {
            if (override != null) std.log.warn("config not found: {s}", .{path});
            return;
        },
        else => |e| return e,
    };
    defer gpa.free(src);
    const out = plugin.eval(gpa, src, "init.fnl") catch {
        std.log.err("config failed (see above): {s}", .{path});
        return;
    };
    gpa.free(out);
    std.log.info("config loaded: {s}", .{path});
}
