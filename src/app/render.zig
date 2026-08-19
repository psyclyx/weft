//! `RenderState` — the cohesive owner of the snail/Vulkan render path and the
//! window-layout pane tree. `main()` holds ONE `render` object instead of a
//! dozen loose render locals; its `init` builds every resource in place (no
//! self-referential move hazard) and its `deinit` frees them in the exact
//! reverse order `main()` used to, so the shutdown sequence is unchanged.
//!
//! The seam: `buildFrame`/`renderPanes` are backend-independent (per-pane
//! `view.build` → shapes + the HUD assembly), touching NO `vk`/`snail_vk`/
//! swapchain. `present` is the only method that touches the GPU: it uploads the
//! frame's atlas delta, emits the built panes into the instance stream, and
//! records the render pass. The build reports a `records_added` signal + a
//! `rebuilt` flag; `present` consumes them. A headless harness drives
//! `buildFrame` and skips `present`, rasterizing the built shapes on the CPU
//! instead (see `gfx/harness.zig`).

const std = @import("std");
const snail = @import("snail");
const stemma = @import("stemma");
const snail_vk = @import("../gfx/snail_vk/root.zig");
const view_mod = @import("../gfx/view.zig");
const region = @import("../gfx/region.zig");
const window_layout = @import("../gfx/window_layout.zig");
const stats_mod = @import("../gfx/stats.zig");
const context = @import("../gfx/context.zig");
const Context = context.Context;
const core = @import("../core/core.zig");
const cursor_config = @import("cursor_config.zig");
const collab = @import("collab.zig");
const frame = @import("frame.zig");
const FrameCtx = frame.FrameCtx;
const Active = frame.Active;

pub const RenderState = struct {
    gpa: std.mem.Allocator,
    /// The device/queue/render-pass handles (a value bundle) needed by the
    /// per-frame uploads and by `present`.
    vctx: snail_vk.VulkanContext,
    view: view_mod.View,
    layout: snail_vk.VulkanResourceLayout,
    /// A value copy of the layout's samplers/desc-set handle — self-contained,
    /// so it survives independently of `layout`'s address.
    resources: snail_vk.ResourceContext,
    cache: snail_vk.VulkanDeviceAtlas,
    renderer: snail_vk.Renderer,
    /// The live atlas binding, re-established by each delta upload.
    binding: [1]snail.render.records.Binding,
    stats: stats_mod.Stats,
    /// One `Built` per rendered pane, kept alive for the frame (its shapes feed
    /// the instance stream) and freed at the top of the next build.
    built_panes: std.ArrayList(view_mod.Built),
    instances: std.ArrayList(snail.render.records.Instance),
    batches: std.ArrayList(snail.render.records.DrawBatch),
    /// Total glyph records the last build appended to `view.atlas`. Drives the
    /// backend atlas upload in `present` (0 ⇒ nothing new to upload). Set by the
    /// backend-independent `renderPanes`; consumed by the backend-only `present`.
    records_added: u32,
    /// True when `buildFrame` rebuilt the panes this frame, so `present` knows to
    /// re-run the backend atlas upload + instance emit. A clean (undamaged) frame
    /// leaves it false and `present` reuses last frame's instance stream.
    rebuilt: bool,
    /// The recursive pane tree over the region geometry (a single leaf is the
    /// ordinary unsplit case). The focused pane is always the active buffer.
    win_layout: window_layout.Layout,

    /// Build every render resource IN PLACE (`self` is already at its final
    /// address in `main()`'s frame), so no captured `&self.field` can dangle
    /// after a move. `active_id` seeds the initial single-pane layout.
    pub fn init(
        self: *RenderState,
        gpa: std.mem.Allocator,
        vctx: snail_vk.VulkanContext,
        command_pool: @import("../vk.zig").c.VkCommandPool,
        font_bytes: []const u8,
        em: f32,
        active_id: @import("../core/core.zig").Buffers.Id,
    ) !void {
        self.gpa = gpa;
        self.vctx = vctx;
        self.view = try view_mod.View.init(gpa, font_bytes, em);
        errdefer self.view.deinit();
        try self.layout.init(vctx);
        errdefer self.layout.deinit();
        self.resources = snail_vk.cacheResourceContext(vctx, &self.layout);
        self.cache = try snail_vk.VulkanDeviceAtlas.init(gpa, self.view.pool, self.resources, .{});
        errdefer self.cache.deinit();
        self.renderer = try snail_vk.Renderer.init(vctx, self.layout.desc_set_layout, 2 << 20, context.max_frames_in_flight, .disabled);
        errdefer self.renderer.deinit();
        // Initial (empty) upload establishes the live binding.
        try snail_vk.uploadAndWait(gpa, vctx, self.resources, command_pool, &self.cache, &.{&self.view.atlas}, &self.binding);
        self.stats = .{};
        self.built_panes = .empty;
        self.instances = .empty;
        self.batches = .empty;
        self.records_added = 0;
        self.rebuilt = false;
        self.win_layout = try window_layout.Layout.init(gpa, active_id);
    }

    /// True when a partial checkout can't be read yet: content rendering is
    /// deferred until the window around the cursor is realized (rope holes
    /// panic on content reads — the deterministic single choke point). The
    /// dirty flag stays set, so the frame after realization repaints. Gate on
    /// ALL rendered panes on the partial buffer, not just the focused one: any
    /// pane's visible window (its scroll .. a screenful) must be realized.
    fn partialBlocked(self: *RenderState, fx: *const FrameCtx) bool {
        if (fx.partial_state.*) |*p| {
            if (p.state != .open) return false; // virgin/empty doc renders fine
            const cur = fx.ed0.cursorOffset();
            const end = @min(fx.ed0.text().byteLen(), cur + (64 << 10));
            if (!fx.ed0.text().isRealized(.{ .start = cur -| (64 << 10), .end = end })) return true;
            const CheckCtx = struct { ed0: *core.Editor, blocked: bool = false };
            var cc = CheckCtx{ .ed0 = fx.ed0 };
            self.win_layout.eachPane(&cc, struct {
                fn visit(c: *CheckCtx, pane: *window_layout.Pane) void {
                    if (pane.buffer_id != 0) return; // only the partial doc holes
                    const rope = c.ed0.text();
                    const rows = rope.lineCount();
                    if (rows == 0) return;
                    const start = rope.lineRange(@min(pane.top_row, rows - 1)).start;
                    const e = @min(rope.byteLen(), start + (48 << 10));
                    if (!rope.isRealized(.{ .start = start, .end = e })) c.blocked = true;
                }
            }.visit);
            return cc.blocked;
        }
        return false;
    }

    /// Backend-independent frame BUILD: gate on damage + partial-checkout
    /// realization, sync syntax highlight, assemble the whole-app `Hud`, then
    /// lay out and build every pane's shapes. NO swapchain, command-buffer, or
    /// GPU atlas work happens here — that is `present`'s job, driven by the
    /// `records_added`/`rebuilt` signals this sets. A clean, unblocked frame
    /// keeps last frame's instance stream and returns early (leaving `rebuilt`
    /// false, so `present` skips the re-upload/re-emit).
    pub fn buildFrame(self: *RenderState, fx: *const FrameCtx, act: Active) !void {
        const gpa = fx.gpa;
        const editor = act.editor;
        const abuf = act.abuf;
        const attach = act.attach;
        const fb = act.fb;

        if (!(fx.view_dirty.* and !self.partialBlocked(fx))) return;
        fx.view_dirty.* = false;

        const projection = snail.Mat4.ortho(0, @floatFromInt(fb[0]), @floatFromInt(fb[1]), 0, -1, 1);
        const world_to_pixel = snail.mvpToScenePixel(projection, @floatFromInt(fb[0]), @floatFromInt(fb[1])) orelse unreachable;

        if (attach.syntax) |syn| {
            _ = try syn.sync(gpa, &editor.doc);
            if (fx.caps.layers.find(&editor.doc, "highlight")) |hl| {
                // Whole doc when small; a generous window around the
                // viewport otherwise (republshed every damage frame).
                const rope = editor.text();
                const total = rope.byteLen();
                const range = stemma_range: {
                    if (total <= 256 * 1024) break :stemma_range stemma.Range{ .start = 0, .end = total };
                    const rows = rope.lineCount();
                    const first = self.view.top_row -| 100;
                    const last = @min(rows - 1, self.view.top_row + 200);
                    break :stemma_range stemma.Range{ .start = rope.lineRange(first).start, .end = rope.lineRange(last).end };
                };
                try syn.publishHighlight(gpa, &editor.doc, hl, range);
            }
        }

        // Markdown styling for .md buffers: analyze a window (whole doc
        // when small) into per-byte attributes each damage frame — a
        // stale paint is slightly-old truth, like highlight bulk.
        var md_arena = std.heap.ArenaAllocator.init(gpa);
        defer md_arena.deinit();
        const md_inline: ?view_mod.MdInline = blk: {
            const path = editor.backingPath() orelse abuf.name;
            if (!cursor_config.isMarkdownPath(path)) break :blk null;
            const rope = editor.text();
            const total = rope.byteLen();
            const range = if (total <= 256 * 1024)
                stemma.Range{ .start = 0, .end = total }
            else rng: {
                const rows = rope.lineCount();
                const first = self.view.top_row -| 100;
                const last = @min(rows -| 1, self.view.top_row + 200);
                break :rng stemma.Range{ .start = rope.lineRange(first).start, .end = rope.lineRange(last).end };
            };
            const attrs = core.markdown.analyze(md_arena.allocator(), rope, range) catch break :blk null;
            break :blk .{ .base = range.start, .attrs = attrs };
        };

        var pos_buf: [24]u8 = undefined;
        const buffer_pos = blk: {
            var index: usize = 0;
            var nth: usize = 0;
            var bit2 = fx.buffers.iterator();
            while (bit2.next()) |b| {
                nth += 1;
                if (b == abuf) index = nth;
            }
            break :blk std.fmt.bufPrint(&pos_buf, "{d}/{d}", .{ index, fx.buffers.count() }) catch null;
        };
        const shared_here = blk: {
            if (fx.conn.*) |*c| {
                for (c.collabs.items) |col| if (col.tag == abuf.id) break :blk true;
            }
            if (fx.hub.*) |*h| {
                for (h.clients.items) |peer| {
                    for (peer.conn.collabs.items) |col| if (col.tag == abuf.id) break :blk true;
                }
            }
            break :blk false;
        };
        const backing_chip: ?[]const u8 = switch (editor.backing) {
            .none => if (shared_here) "@shared" else null,
            .file => if (shared_here) "file+shared" else "file",
            .shell => if (shared_here) "shell+shared" else "shell",
            .tool => "tool",
        };
        const unfetched_pct: ?u8 = blk: {
            var unfetched: usize = 0;
            for (editor.doc.unrealizedBase()) |h| unfetched += h.bytes;
            if (unfetched == 0) break :blk null;
            const total_len = editor.text().byteLen();
            if (total_len == 0) break :blk null;
            break :blk @intCast(@min(99, unfetched * 100 / total_len));
        };
        var listen_buf: [40]u8 = undefined;
        const link_note: ?[]const u8 = if (fx.collab_session.*) |s|
            @tagName(s.liveness())
        else if (fx.hub.*) |*h|
            (std.fmt.bufPrint(&listen_buf, "listening {d} ({s})", .{ h.clients.items.len, h.access.label() }) catch "listening")
        else
            null;
        // Collect the plugins' live overlays for this frame (which-key,
        // dired, magit … render through the retained surface door).
        var surface_buf: [64]*const core.surface.Surface = undefined;
        var surface_n: usize = 0;
        for (fx.plugins.items) |pl| {
            if (pl.surface.active and surface_n < surface_buf.len) {
                surface_buf[surface_n] = &pl.surface;
                surface_n += 1;
            }
        }
        // which-key: while a leader/chord prefix is active (a leaf menu
        // mode) and no picker is open, list that mode's bindings. This is
        // the host FALLBACK — if a which-key plugin is loaded it renders a
        // surface (surface_n > 0) and the host render steps aside, so the
        // menu is never drawn twice.
        var wk_hints: std.ArrayList(core.Keymap.Binding) = .empty;
        defer wk_hints.deinit(gpa);
        if (surface_n == 0 and !fx.pick.active and fx.keymap.isMenuMode(fx.keymap.currentMode())) {
            fx.keymap.ownBindings(gpa, fx.keymap.currentMode(), &wk_hints) catch {};
        }
        // Buffer tab strip (only with more than one buffer open). Name
        // slices borrow the buffers' own strings — valid this frame.
        var tab_list: std.ArrayList(view_mod.Tab) = .empty;
        defer tab_list.deinit(gpa);
        if (fx.buffers.count() > 1) {
            var bit3 = fx.buffers.iterator();
            while (bit3.next()) |b| {
                const nm = b.editor.backingPath() orelse b.name;
                tab_list.append(gpa, .{ .name = std.fs.path.basename(nm), .active = b == abuf }) catch {};
            }
        }
        // vim-goggles: a guest set a flash range; show it for the duration.
        const flash_range: ?stemma.Range = fblk: {
            const fs = core.wasm_host.flashState();
            if (fs.gen != fx.flash_gen.*) {
                fx.flash_gen.* = fs.gen;
                fx.flash_start_ns.* = act.frame_start;
            }
            const active = fs.gen > 0 and (act.frame_start -| fx.flash_start_ns.*) < fx.flash_duration_ns;
            if (active or fx.flash_was_active.*) fx.view_dirty.* = true; // draw it, then clear it
            fx.flash_was_active.* = active;
            if (!active) break :fblk null;
            const len = editor.text().byteLen();
            break :fblk .{ .start = @min(fs.start, len), .end = @min(fs.end, len) };
        };
        const hud: view_mod.Hud = .{
            .mode = fx.keymap.currentMode(),
            .which_key = if (wk_hints.items.len > 0) wk_hints.items else null,
            .surfaces = surface_buf[0..surface_n],
            .flash = flash_range,
            .hover = if (fx.hover_ui.active) .{ .text = fx.hover_ui.text.items, .offset = fx.hover_ui.offset } else null,
            .tabs = if (tab_list.items.len > 1) tab_list.items else null,
            .md_inline = md_inline,
            .cursor_style = fx.cursor_cfg.styleFor(fx.cursor_cfg.resolveMode(fx.keymap, fx.keymap.currentMode())),
            .cursor_on = if (fx.cursor_cfg.blinkFor(fx.cursor_cfg.resolveMode(fx.keymap, fx.keymap.currentMode()))) act.blink_on else true,
            .file = editor.backingPath() orelse abuf.name,
            .dirty = editor.isDirty(gpa) catch true,
            .save_failed = editor.save_state == .failed,
            .buffer_pos = buffer_pos,
            .backing = backing_chip,
            .save_note = switch (editor.save_state) {
                .saving => "saving…",
                .stale => "save stale",
                else => null,
            },
            .unfetched_pct = unfetched_pct,
            .peers = if (fx.caps.layers.find(&editor.doc, "presence")) |pl| pl.spanCount() else 0,
            .echo = if (fx.echo.items.len > 0) fx.echo.items else null,
            .pick = if (fx.pick.active) fx.pick else null,
            .highlight_layer = fx.caps.layers.find(&editor.doc, "highlight"),
            .styles_layer = fx.caps.layers.find(&editor.doc, "styles"),
            .diag_layer = fx.caps.layers.find(&editor.doc, "diagnostics"),
            .presence_layer = fx.caps.layers.find(&editor.doc, "presence"),
            .link = link_note,
            .trust = if (fx.collab_session.* != null) blk: {
                const fp = fx.noted_host_fp.* orelse break :blk null;
                break :blk collab.hostTrustChip(fx.known_peers.trust(fp));
            } else null,
            .cursor_diag = blk: {
                const dl = fx.caps.layers.find(&editor.doc, "diagnostics") orelse break :blk null;
                const cur = editor.cursorOffset();
                for (0..dl.spanCount()) |i| {
                    const d = dl.resolvedSpan(i);
                    if (cur >= d.start and cur <= d.end) break :blk d.message;
                }
                break :blk null;
            },
        };
        try self.renderPanes(fx, act, hud, world_to_pixel);
    }

    /// Tile the frame via the window layout and build every pane into the
    /// instance stream. Non-focused panes build FIRST (their own scroll, no
    /// caret/dock); the focused pane builds LAST so `view.frame_layout` ends on
    /// it (caret + between-frame hit-testing) and carries the caret + picker
    /// dock. Each pane renders into its own rect (identity transform), so all
    /// panes accumulate into one instance stream, one draw. Backend-independent:
    /// it builds shapes and reports how many atlas records the builds added
    /// (`records_added`); the GPU atlas upload and the instance emit now live in
    /// the backend-only `present`.
    fn renderPanes(self: *RenderState, fx: *const FrameCtx, act: Active, hud: view_mod.Hud, world_to_pixel: snail.Transform2D) !void {
        const gpa = fx.gpa;
        const editor = act.editor;
        const fb = act.fb;
        var records: u32 = 0;
        var arena_state = std.heap.ArenaAllocator.init(gpa);
        defer arena_state.deinit();
        self.view.resetFrame();
        const window_rect: region.Rect = .{ .x = 0, .y = 0, .w = @floatFromInt(fb[0]), .h = @floatFromInt(fb[1]) };
        // Carve the picker's window-bottom dock off the window FIRST, so the
        // panes lay out in what remains — the picker is a real region, not an
        // overlay, and cannot overlap a pane or status line (region.zig's
        // contract). Zero-height when no pick is open ⇒ panes fill the window.
        const dock_cut = window_rect.cutBottom(self.view.pickDockHeight(if (fx.pick.active) fx.pick else null));
        const pick_dock = dock_cut.strip;
        const frame_rect = dock_cut.rest;
        fx.last_frame_rect.* = frame_rect;

        var slots: [window_layout.max_panes]window_layout.Slot = undefined;
        const nslots = self.win_layout.collect(frame_rect, &slots);

        // Free last frame's builds; each pane appends a fresh one below.
        for (self.built_panes.items) |*old| old.deinit(gpa);
        self.built_panes.clearRetainingCapacity();

        var foc_rect = frame_rect;
        var foc_border: region.Edges = .{};
        for (slots[0..nslots]) |slot| {
            if (slot.focused) {
                foc_rect = slot.rect;
                foc_border = slot.border;
                continue; // the focused pane builds last, below
            }
            const ob = fx.buffers.get(slot.pane.buffer_id) orelse continue;
            ob.editor.fold_layer = fx.caps.layers.find(&ob.editor.doc, "folds");
            const other_hud: view_mod.Hud = .{
                .mode = fx.keymap.currentMode(),
                .file = ob.editor.backingPath() orelse ob.name,
                .cursor_on = false, // the caret belongs to the focused pane
                .pane_border = slot.border,
                // A peeked tool buffer keeps its colors: thread its styles feed too.
                .styles_layer = fx.caps.layers.find(&ob.editor.doc, "styles"),
            };
            const bo = try self.view.build(arena_state.allocator(), &ob.editor, other_hud, &slot.pane.top_row, slot.rect, .{}, world_to_pixel);
            try self.built_panes.append(gpa, bo);
            records += bo.records_added;
        }

        // The focused pane: active buffer, full HUD, caret, picker dock.
        var fhud = hud;
        fhud.pane_border = foc_border;
        editor.fold_layer = fx.caps.layers.find(&editor.doc, "folds");
        const b = try self.view.build(arena_state.allocator(), editor, fhud, &self.view.top_row, foc_rect, pick_dock, world_to_pixel);
        try self.built_panes.append(gpa, b);
        records += b.records_added;
        self.win_layout.focusedPane().top_row = self.view.top_row; // scrollToCursor may have moved it

        // Signal the backend path: how many glyph records the builds added (so
        // `present` uploads the atlas delta) and that the panes were rebuilt (so
        // `present` re-emits the instance stream). No GPU work happens here.
        self.records_added = records;
        self.rebuilt = true;
    }

    /// Emit every built pane into ONE instance/batch stream (carried emit
    /// cursors + the identity transform, since each pane built into its own
    /// absolute rect). The focused pane is last in `built_panes`, so its caret
    /// draws on top. Pure CPU (no vk), but it stamps instances with the live
    /// atlas `binding`, so it must run AFTER the atlas upload — hence it lives on
    /// the backend path, called only by `present`.
    fn emitBuiltPanes(self: *RenderState) !void {
        const gpa = self.gpa;
        self.instances.clearRetainingCapacity();
        self.batches.clearRetainingCapacity();
        var total_shapes: usize = 0;
        for (self.built_panes.items) |bp| total_shapes += bp.shapes.len;
        try self.instances.resize(gpa, @max(total_shapes, 1));
        try self.batches.resize(gpa, @max(total_shapes, 1));
        var ilen: usize = 0;
        var blen: usize = 0;
        for (self.built_panes.items) |bp| {
            _ = try snail.emit.emit(self.instances.items, self.batches.items, &ilen, &blen, self.binding[0], &self.view.atlas, bp.shapes, .identity, .{ 1, 1, 1, 1 });
        }
        self.instances.items.len = ilen;
        self.batches.items.len = blen;
    }

    /// The GPU present: upload the frame's atlas delta, emit the built panes into
    /// the instance stream, then acquire a swapchain image, record the stream
    /// into the render pass, submit, and present — then record the frame's
    /// latency stats. This is the ONLY method that touches the swapchain/command
    /// buffer or the GPU atlas; a headless harness skips it. A stale/zero
    /// swapchain (`beginFrame` returns null) drops the DRAW, but the atlas upload
    /// + emit still ran (as they did when they lived inside the build), so the
    /// next frame draws the up-to-date stream.
    pub fn present(self: *RenderState, ctx: *Context, fb: [2]u32, frame_start: u64, had_input: bool) !void {
        // Backend-only atlas upload + instance emit, lifted out of the
        // backend-independent build. Runs on every rebuilt frame regardless of
        // swapchain availability; a clean frame reuses last frame's stream. The
        // per-frame atlas delta upload preserves the exact ordering the build
        // used (upload before emit → instances stamp the fresh binding).
        if (self.rebuilt) {
            self.rebuilt = false;
            if (self.records_added != 0) {
                self.records_added = 0;
                self.binding[0] = try snail_vk.uploadDeltaAndWait(self.gpa, self.vctx, self.resources, ctx.command_pool, &self.cache, self.binding[0], &self.view.atlas);
            }
            try self.emitBuiltPanes();
        }
        const cmd = try ctx.beginFrame() orelse return;
        ctx.beginRenderPass(cmd, self.view.theme.background);
        self.renderer.beginFrame(ctx.current_frame);
        const draw_state: snail.render.target.DrawState = .{
            .mvp = snail.Mat4.ortho(0, @floatFromInt(fb[0]), @floatFromInt(fb[1]), 0, -1, 1),
            .surface = .{
                .pixel_width = fb[0],
                .pixel_height = fb[1],
                .encoding = if (ctx.surfaceEncodesSrgb()) .srgb else .linear,
            },
        };
        try self.renderer.render(cmd, &self.cache, draw_state, self.instances.items, self.batches.items);
        try ctx.endFrame();

        const frame_ns = stats_mod.nowNs() - frame_start;
        self.stats.recordFrame(frame_ns);
        if (had_input) self.stats.recordInput(frame_ns);
        _ = self.stats.maybeLog(600);
    }

    /// Free in the exact reverse order `main()`'s defers used to run:
    /// win_layout, batches, instances, built_panes, renderer, cache, layout,
    /// view.
    pub fn deinit(self: *RenderState) void {
        self.win_layout.deinit();
        self.batches.deinit(self.gpa);
        self.instances.deinit(self.gpa);
        for (self.built_panes.items) |*b| b.deinit(self.gpa);
        self.built_panes.deinit(self.gpa);
        self.renderer.deinit();
        self.cache.deinit();
        self.layout.deinit();
        self.view.deinit();
    }
};
