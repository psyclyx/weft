//! `FrameBuilder` owns the renderer-independent half of the render path: the
//! `View`, window-layout pane tree, per-frame draw items, and latency stats.
//! `buildFrame`/`renderPanes` gate on damage +
//! partial-checkout realization, assemble the whole-app `Hud`, tile the panes,
//! and build each into its `built_panes` slot. None of this touches Vulkan or
//! command submission. Unit geometry tests may drive `view.build` directly;
//! whole-app headless E2E uses this same builder through Skia and Vulkan.

const std = @import("std");
const semantic = @import("weft_semantic");
const scene = @import("weft_scene");
const stemma = @import("stemma");
const view_mod = @import("../gfx/view.zig");
const region = @import("../gfx/region.zig");
const window_layout = @import("../gfx/window_layout.zig");
const stats_mod = @import("../gfx/stats.zig");
const core = @import("../core/core.zig");
const cursor_config = @import("cursor_config.zig");
const providers = @import("providers.zig");
const collab = @import("collab.zig");
const frame = @import("frame.zig");
const FrameCtx = frame.FrameCtx;
const Active = frame.Active;

/// Rendering P2 fix (post rendering-P2-review): a retained GUEST `.caret`
/// surface (the `lsp` plugin's hover, today — but the policy is general,
/// not hover-specific) auto-EXPIRES — CLOSED, not merely skipped — once the
/// focused head's cursor moves off the anchor's LINE. Unlike the echo line
/// hover replaced, a `.caret` popup paints OVER body text (`drawCaretSurface`
/// has no way to know it's stale), and a guest has no `on_move`/`on_edit`
/// export to dismiss it itself — that guest-driven generalization is
/// P4-era (see doc/rendering.md); this is core POLICY meanwhile, enforced
/// exactly where core already resolves every surface's anchor: once per
/// frame, right before `buildFrame` collects `hud.surfaces`.
///
/// CLOSE, not skip: the alternative (leave `active` true, just don't draw
/// it) would still satisfy "not painted over the buffer", but it leaves a
/// zombie Surface a later reader (another `hud.surfaces` consumer, a test)
/// could mistake for live, and buys nothing — a guest surface's own next
/// request rebuilds it from scratch anyway (hover is invoked per keypress/
/// idle-timer, never incrementally). `Surface.close` frees the retained
/// rows/spans, so this must run against the SAME allocator that built them
/// (`pl.gpa`, not `FrameBuilder`'s `gpa` — a `WasmPlugin`'s surface is
/// always built through its own `p.gpa`, see `wasm_host/surface.zig`).
///
/// An anchor past the current buffer's end (the buffer was switched since
/// the popup was built) also counts as stale: `Rope.offsetToPoint` asserts
/// in-range, so the length check guards the same class of crash
/// `popup.layoutCaretSurface`'s `lineForOffset` sidesteps by walking the
/// current frame's line map instead of dereferencing a raw offset.
///
/// The picker's OWN `.caret` surface is NEVER passed here — it isn't a
/// `WasmPlugin`, so it can't be in `plugins`; `Pick.buildSurface`
/// (core/pick/Pick.zig) rebuilds it fresh every frame from the LIVE
/// `caret_anchor`, so it is definitionally never stale the way a guest's
/// retained surface can be. That's what spares completion from flickering
/// while narrowing: this function structurally never sees it, not a
/// same-line coincidence.
///
/// Pure over the plugin list + the active rope/cursor (no `FrameBuilder`,
/// no `FrameCtx`) so the policy is unit-testable without standing up a
/// full render harness. The actual DECISION is factored one level further,
/// into `expireIfStale` below, which needs only a `core.surface.Surface` —
/// see this file's own tests.
pub fn expireStaleCaretSurfaces(plugins: []const *core.wasm_abi.WasmPlugin, rope: *const stemma.Rope, cursor_off: usize) void {
    for (plugins) |pl| expireIfStale(&pl.surface, pl.gpa, rope, cursor_off);
}

/// The per-surface staleness decision (see `expireStaleCaretSurfaces`'s doc
/// for the full policy rationale): a no-op unless `surf` is an ACTIVE
/// `.caret` surface with an anchor, in which case it closes `surf` (using
/// `gpa` — the SAME allocator that built it) when the anchor's line no
/// longer matches `cursor_off`'s, or the anchor now falls outside `rope`
/// entirely (a buffer switch since the surface was built). Split out from
/// `expireStaleCaretSurfaces` so a test can drive it against a hand-built
/// `core.surface.Surface` + `stemma.Rope`, with no `WasmPlugin` (a live
/// wasm instance) needed at all.
fn expireIfStale(surf: *core.surface.Surface, gpa: std.mem.Allocator, rope: *const stemma.Rope, cursor_off: usize) void {
    if (!surf.active or surf.placement != .caret) return;
    const a = surf.anchor orelse return;
    const cur_row = rope.offsetToPoint(cursor_off).row;
    const stale = a > rope.byteLen() or rope.offsetToPoint(a).row != cur_row;
    if (stale) surf.close(gpa);
}

fn containsSemanticNode(root: *const semantic.scene.Node, wanted: semantic.scene.NodeId) bool {
    if (root.id == wanted) return true;
    return switch (root.content) {
        .container => |container| blk: {
            for (container.children) |*child| if (containsSemanticNode(child, wanted)) break :blk true;
            break :blk false;
        },
        else => false,
    };
}

fn firstFocusableSemanticNode(root: *const semantic.scene.Node) ?semantic.scene.NodeId {
    if (root.focusable) return root.id;
    return switch (root.content) {
        .container => |container| blk: {
            for (container.children) |*child| if (firstFocusableSemanticNode(child)) |id| break :blk id;
            break :blk null;
        },
        else => null,
    };
}

fn focusedSemanticNode(head: *const core.Head, view_ref: semantic.view.Ref, root: *const semantic.scene.Node) ?semantic.scene.NodeId {
    const path = head.semantic_focus.path() orelse return firstFocusableSemanticNode(root);
    if (!path.view.eql(view_ref) or path.nodes.len == 0) return firstFocusableSemanticNode(root);
    const wanted = path.nodes[path.nodes.len - 1];
    return if (containsSemanticNode(root, wanted)) wanted else firstFocusableSemanticNode(root);
}

/// The layers a pane's body paints from. An entry that holds no text has no
/// document, and therefore none of them.
const DocLayers = struct {
    highlight: ?*const core.layers.Layer = null,
    styles: ?*const core.layers.Layer = null,
    diagnostics: ?*const core.layers.Layer = null,
    decorations: ?*const core.layers.Layer = null,
    presence: ?*const core.layers.Layer = null,

    fn of(caps: *core.Caps, editor: ?*core.Editor) DocLayers {
        const ed = editor orelse return .{};
        return .{
            .highlight = caps.layers.find(&ed.doc, "highlight"),
            .styles = caps.layers.find(&ed.doc, "styles"),
            .diagnostics = caps.layers.find(&ed.doc, "diagnostics"),
            .decorations = caps.layers.find(&ed.doc, "decorations"),
            .presence = caps.layers.find(&ed.doc, "presence"),
        };
    }
};

/// The gutter's breakpoint lines, DERIVED each frame from the document's
/// anchored marks — no line number is stored anywhere, so a mark that the text
/// moved is drawn where the text moved it. Arena-owned, frame-lived.
fn bpLines(arena: std.mem.Allocator, caps: *core.Caps, editor: ?*core.Editor) []const u8 {
    const ed = editor orelse return "";
    var buf: [1024]u8 = undefined;
    const csv = core.breakpoints.lineCsv(&caps.layers, &ed.doc, &buf);
    return arena.dupe(u8, csv) catch "";
}

/// What a TEXT entry reports on the status line. An entry that holds no text
/// has nothing to save, realize, or diagnose.
const DocStatus = struct {
    dirty: bool = false,
    save_failed: bool = false,
    save_note: ?[]const u8 = null,
    unfetched_pct: ?u8 = null,
    peers: usize = 0,
    cursor_diag: ?[]const u8 = null,

    fn of(gpa: std.mem.Allocator, editor: ?*core.Editor, doc_layers: DocLayers) DocStatus {
        const ed = editor orelse return .{};
        return .{
            .dirty = ed.isDirty(gpa) catch true,
            .save_failed = ed.save_state == .failed,
            .save_note = switch (ed.save_state) {
                .saving => "saving…",
                .stale => "save stale",
                else => null,
            },
            .unfetched_pct = unfetchedPct(ed),
            .peers = if (doc_layers.presence) |pl| pl.spanCount() else 0,
            .cursor_diag = cursorDiag(doc_layers.diagnostics, ed.cursorOffset()),
        };
    }
};

/// Share of a partial checkout still unfetched, for the realization chip.
fn unfetchedPct(editor: *core.Editor) ?u8 {
    var unfetched: usize = 0;
    for (editor.doc.unrealizedBase()) |h| unfetched += h.bytes;
    if (unfetched == 0) return null;
    const total_len = editor.text().byteLen();
    if (total_len == 0) return null;
    return @intCast(@min(99, unfetched * 100 / total_len));
}

/// The diagnostic message under the caret, if any.
fn cursorDiag(diag_layer: ?*const core.layers.Layer, cursor: usize) ?[]const u8 {
    const dl = diag_layer orelse return null;
    for (0..dl.spanCount()) |i| {
        const d = dl.resolvedSpan(i);
        if (cursor >= d.start and cursor <= d.end) return d.message;
    }
    return null;
}

fn semanticDocument(fx: *const FrameCtx) ?view_mod.semantic_data.Document {
    const path = fx.head.semantic_focus.path() orelse return null;
    const instance = fx.semantic.views.get(path.view) orelse return null;
    return .{
        .view = path.view,
        .root = &instance.scene,
        .title = fx.buffers.active().name,
        .focused = focusedSemanticNode(fx.head, path.view, &instance.scene),
        .fields = &fx.semantic.fields,
    };
}

fn semanticOverlay(fx: *const FrameCtx) ?view_mod.semantic_data.Overlay {
    const active = fx.head.interactions.active() orelse return null;
    const descriptor = active.descriptor;
    const instance = fx.semantic.views.get(descriptor.view) orelse return null;
    const root = instance.node(descriptor.root) orelse return null;
    return .{
        .document = .{
            .view = descriptor.view,
            .root = root,
            .focused = focusedSemanticNode(fx.head, descriptor.view, root),
            .fields = &fx.semantic.fields,
        },
        .presentation = descriptor.presentation,
    };
}

pub const FrameBuilder = struct {
    gpa: std.mem.Allocator,
    view: view_mod.View,
    stats: stats_mod.Stats,
    /// One `Built` per rendered pane, kept alive for the frame and freed at the
    /// top of the next build.
    built_panes: std.ArrayList(view_mod.Built),
    /// True when `buildFrame` rebuilt the panes this frame, so `present` knows
    /// to re-run its backend upload/emit. A clean frame leaves it false.
    rebuilt: bool,
    /// The recursive pane tree over the region geometry (a single leaf is the
    /// ordinary unsplit case). The focused pane is always the active buffer.
    win_layout: window_layout.Layout,

    pub fn init(
        self: *FrameBuilder,
        gpa: std.mem.Allocator,
        font_bytes: []const u8,
        em: f32,
        active_id: core.Buffers.Id,
    ) !void {
        self.gpa = gpa;
        self.view = try view_mod.View.init(gpa, font_bytes, em);
        errdefer self.view.deinit();
        self.stats = .{};
        self.built_panes = .empty;
        self.rebuilt = false;
        self.win_layout = try window_layout.Layout.init(gpa, active_id);
    }

    pub fn deinit(self: *FrameBuilder) void {
        self.win_layout.deinit();
        for (self.built_panes.items) |*b| b.deinit(self.gpa);
        self.built_panes.deinit(self.gpa);
        self.view.deinit();
    }

    /// True when a partial checkout can't be read yet: content rendering is
    /// deferred until the window around the cursor is realized (rope holes
    /// panic on content reads — the deterministic single choke point). The
    /// dirty flag stays set, so the frame after realization repaints. Gate on
    /// ALL rendered panes on the partial buffer, not just the focused one: any
    /// pane's visible window (its scroll .. a screenful) must be realized.
    fn partialBlocked(self: *FrameBuilder, fx: *const FrameCtx) bool {
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

    /// The byte range a pane scrolled to `top_row` paints from: the viewport
    /// plus a generous margin either side (a scroll can outrun a frame —
    /// `view.build` may move `top_row` itself), clamped to the document.
    /// Every per-byte analysis (syntax paint, markdown attributes) sizes
    /// itself from this, so their cost follows the VIEWPORT, not the file. The
    /// view reads only inside the published window: `resolveStyleInputs`
    /// resolves against `bulk.start` and bounds-checks each lookup, and a
    /// scroll damages the frame, which republishes around the new `top_row`.
    /// Measured on a 267KB zig buffer (Debug, `Syntax.paint`): whole document
    /// 41.0ms, this window 1.6ms — per damage frame.
    fn paintWindow(rope: *const stemma.Rope, top_row: usize) stemma.Range {
        const rows = rope.lineCount();
        if (rows == 0) return .{ .start = 0, .end = rope.byteLen() };
        const first = top_row -| 100;
        const last = @min(rows - 1, top_row + 200);
        return .{ .start = rope.lineRange(first).start, .end = rope.lineRange(last).end };
    }

    /// Reparse + publish a buffer's syntax highlight over that pane's paint
    /// window. Called once per rendered pane, immediately before that pane
    /// builds — two panes on one buffer at different scrolls each paint their
    /// own window, and the last publish is always the one the next build reads.
    fn publishHighlight(self: *FrameBuilder, gpa: std.mem.Allocator, editor: *core.Editor, syn: *core.syntax.Syntax, caps: *core.Caps, top_row: usize) !void {
        _ = self;
        _ = try syn.sync(gpa, &editor.doc);
        const hl = caps.layers.find(&editor.doc, "highlight") orelse return;
        try syn.publishHighlight(gpa, &editor.doc, hl, paintWindow(editor.text(), top_row));
    }

    /// Per-byte markdown attributes for a `.md` buffer over that pane's paint
    /// window, into `arena` (must outlive the pane build). Null for non-md.
    /// Shared by the focused pane and every peeked split.
    fn mdInlineFor(arena: std.mem.Allocator, editor: *core.Editor, name: []const u8, top_row: usize) ?view_mod.MdInline {
        if (!cursor_config.isMarkdownPath(name)) return null;
        const range = paintWindow(editor.text(), top_row);
        const attrs = core.markdown.analyze(arena, editor.text(), range) catch return null;
        return .{ .base = range.start, .attrs = attrs };
    }

    /// Backend-independent frame BUILD: gate on damage + partial-checkout
    /// realization, sync syntax highlight, assemble the whole-app `Hud`, then
    /// lay out and build every pane's shapes. NO swapchain, command-buffer, or
    /// GPU atlas work happens here — that is the backend `present`'s job, driven
    /// by the `rebuilt` signal this sets. A clean, unblocked
    /// frame keeps last frame's build and returns early (leaving `rebuilt`
    /// false, so `present` skips the re-upload/re-emit).
    pub fn buildFrame(self: *FrameBuilder, fx: *const FrameCtx, act: Active) !void {
        const gpa = fx.gpa;
        const editor = act.editor;
        const abuf = act.abuf;
        const fb = act.fb;

        if (!(fx.view_dirty.* and !self.partialBlocked(fx))) return;
        fx.view_dirty.* = false;

        const projection = scene.Mat4.ortho(0, @floatFromInt(fb[0]), @floatFromInt(fb[1]), 0, -1, 1);
        const world_to_pixel = scene.mvpToScenePixel(projection, @floatFromInt(fb[0]), @floatFromInt(fb[1])) orelse unreachable;

        // Markdown styling for .md buffers: analyze this pane's paint
        // window into per-byte attributes each damage frame — a
        // stale paint is slightly-old truth, like highlight bulk. Reused
        // below for the `ui/statusline-seg`/`ui/gutter-segment` mesh output
        // (segment text, the eligible-bindings slice) — both are per-frame
        // scratch, reclaimed by this same arena, no manual free needed.
        var md_arena = std.heap.ArenaAllocator.init(gpa);
        defer md_arena.deinit();
        const mesh_gpa = md_arena.allocator();
        const file_name = if (editor) |ed| ed.backingPath() orelse abuf.name else abuf.name;
        const md_inline = if (editor) |ed| mdInlineFor(mesh_gpa, ed, file_name, self.view.top_row) else null;
        const doc_layers = DocLayers.of(fx.caps, editor);
        const doc_status = DocStatus.of(gpa, editor, doc_layers);
        const diag_layer = doc_layers.diagnostics;

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
        const backing_chip: ?[]const u8 = if (abuf.tool.len > 0) "tool" else switch (if (editor) |ed| ed.backing else .none) {
            .none => if (shared_here) "@shared" else null,
            .file => if (shared_here) "file+shared" else "file",
            .shell => if (shared_here) "shell+shared" else "shell",
        };
        var listen_buf: [40]u8 = undefined;
        const link_note: ?[]const u8 = if (fx.collab_session.*) |s|
            @tagName(s.liveness())
        else if (fx.hub.*) |*h|
            (std.fmt.bufPrint(&listen_buf, "listening {d} ({s})", .{ h.clients.items.len, h.access.label() }) catch "listening")
        else
            null;
        // Rendering P2 (doc/rendering.md): the picker builds its OWN scene
        // (a caret-anchored completion list, or the window-bottom dock)
        // fresh this frame — the same `core.surface.Surface` shape a
        // plugin's retained overlay uses, built by `Pick.buildSurface`
        // (core/pick/Pick.zig) rather than this render-layer file reaching
        // into `Pick`'s fields. Arena-owned (`mesh_gpa`), so the pointer
        // below stays valid through this frame's `renderPanes`/`view.build`.
        var pick_surface_storage: ?core.surface.Surface = null;
        if (fx.head.pick.active) pick_surface_storage = fx.head.pick.buildSurface(mesh_gpa, view_mod.Hud.max_pick_rows);

        // Rendering P2 fix (post-review): a retained GUEST `.caret` surface
        // (the `lsp` plugin's hover, today) auto-EXPIRES before it's
        // collected below — see `expireStaleCaretSurfaces`'s doc for the
        // close-vs-skip rationale. The picker's OWN `.caret` surface
        // (`pick_surface_storage`, just above) is untouched by this — it
        // isn't in `fx.plugins`, and `Pick.buildSurface` rebuilds it fresh
        // every frame with the live anchor, so it can never go stale the
        // same way (verified: typing narrows completion with no flicker —
        // `authoring_test.zig`'s existing narrowing test stays green).
        if (editor) |ed| expireStaleCaretSurfaces(fx.plugins.items, ed.text(), ed.cursorOffset());

        // Collect the plugins' live overlays for this frame (which-key,
        // files, git … render through the retained surface door) plus the
        // picker's own scene, built just above.
        var surface_buf: [65]*const core.surface.Surface = undefined;
        var surface_n: usize = 0;
        if (pick_surface_storage) |*ps| {
            surface_buf[surface_n] = ps;
            surface_n += 1;
        }
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
        // menu is never drawn twice. It also honors the idle delay
        // (`menu_shown`): without that, this fallback flashed in the panel
        // during the delay window BEFORE a plugin's (e.g. centered) surface
        // appeared — the "corner first, then middle" jump.
        var wk_hints: std.ArrayList(core.Keymap.Binding) = .empty;
        defer wk_hints.deinit(gpa);
        if (act.menu_shown and surface_n == 0 and !fx.head.pick.active and fx.head.interactions.active() == null and fx.keymap.isMenuMode(fx.head.currentMode())) {
            fx.keymap.ownBindings(gpa, fx.head.currentMode(), &wk_hints) catch {};
        }
        // Buffer tab strip (only with more than one buffer open). Name
        // slices borrow the buffers' own strings — valid this frame.
        var tab_list: std.ArrayList(view_mod.Tab) = .empty;
        defer tab_list.deinit(gpa);
        if (fx.buffers.count() > 1) {
            var bit3 = fx.buffers.iterator();
            while (bit3.next()) |b| {
                const nm = if (b.textEditor()) |ed| ed.backingPath() orelse b.name else b.name;
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
            const len = (editor orelse break :fblk null).text().byteLen();
            break :fblk .{ .start = @min(fs.start, len), .end = @min(fs.end, len) };
        };
        // `ui/statusline-seg` (doc/contextual-workspace-architecture.md
        // §11): fire the mesh with this frame's
        // mode/file/position/diagnostics/link — the same values the
        // pre-mesh direct assembly used — and hand the composed segments
        // to the Hud. `ui/gutter-segment` resolves its eligible provider
        // list once too (empty by default: `Session.init` never binds the
        // default gutter providers, so this is one cheap linear scan over
        // a handful of bindings that always comes back empty in production
        // today — see `ui_mesh.zig`'s module doc).
        var statusline_args: view_mod.ui_mesh.StatuslineArgs = .{
            .facts = .{ .mode = fx.head.currentMode(), .path = file_name },
            .file = file_name,
            .buffer_pos = buffer_pos,
            .diag_layer = diag_layer,
            .link = link_note,
            .theme = &self.view.theme,
        };
        const statusline_segs = try view_mod.ui_mesh.fireStatusline(fx.ui_mesh, mesh_gpa, &statusline_args);
        const gutter_bindings = try view_mod.ui_mesh.gutterBindings(fx.ui_mesh, mesh_gpa, statusline_args.facts);
        const gutter_frame: view_mod.ui_mesh.GutterFrame = .{
            .bindings = gutter_bindings,
            .diag_layer = diag_layer,
            .bp_lines = bpLines(mesh_gpa, fx.caps, editor),
        };

        const hud: view_mod.Hud = .{
            .mode = fx.head.currentMode(),
            .which_key = if (wk_hints.items.len > 0) wk_hints.items else null,
            .surfaces = surface_buf[0..surface_n],
            .semantic_view = semanticDocument(fx),
            .semantic_overlay = semanticOverlay(fx),
            .flash = flash_range,
            // Rendering P2: hover is a LIVE producer now — the `lsp` guest
            // plugin emits its own `.caret` surface (`wl_surface_caret`)
            // straight into `hud.surfaces` above (via `fx.plugins`), same as
            // which-key/files/git. This field is dead in production; see
            // `View.build`'s doc for why it stays as a legacy/test-only path.
            .hover = null,
            .tabs = if (tab_list.items.len > 1) tab_list.items else null,
            .md_inline = md_inline,
            .cursor_style = fx.cursor_cfg.styleFor(fx.cursor_cfg.resolveMode(fx.keymap, fx.head, fx.head.currentMode())),
            .cursor_on = if (fx.cursor_cfg.blinkFor(fx.cursor_cfg.resolveMode(fx.keymap, fx.head, fx.head.currentMode()))) act.blink_on else true,
            .statusline_segs = statusline_segs,
            .gutter = gutter_frame,
            .dirty = doc_status.dirty,
            .save_failed = doc_status.save_failed,
            .backing = backing_chip,
            .save_note = doc_status.save_note,
            .unfetched_pct = doc_status.unfetched_pct,
            .peers = doc_status.peers,
            .echo = if (fx.head.echo.items.len > 0) fx.head.echo.items else null,
            .plugin_status = core.status_feed.get(),
            // Rendering P2: the picker's scene already went into
            // `hud.surfaces` (`pick_surface_storage`, above) — this field is
            // dead in production; see `View.build`'s doc.
            .pick = null,
            .highlight_layer = doc_layers.highlight,
            .styles_layer = doc_layers.styles,
            .diag_layer = diag_layer,
            .decorations_layer = doc_layers.decorations,
            .presence_layer = doc_layers.presence,
            .trust = if (fx.collab_session.* != null) blk: {
                const fp = fx.noted_host_fp.* orelse break :blk null;
                break :blk collab.hostTrustChip(fx.known_peers.trust(fp));
            } else null,
            .cursor_diag = doc_status.cursor_diag,
        };
        try self.renderPanes(fx, act, hud, world_to_pixel);
    }

    /// Tile the frame via the window layout and build every pane into
    /// `built_panes`. Non-focused panes build FIRST (their own scroll, no
    /// caret/dock); the focused pane builds LAST so `view.frame_layout` ends on
    /// it (caret + between-frame hit-testing) and carries the caret + picker
    /// dock. Each pane renders into its own rect (identity transform).
    /// Backend-independent: it produces explicit draw items; the renderer
    /// consumes `built_panes`.
    fn renderPanes(self: *FrameBuilder, fx: *const FrameCtx, act: Active, hud: view_mod.Hud, world_to_pixel: scene.Transform2D) !void {
        const gpa = fx.gpa;
        const editor = act.editor;
        const fb = act.fb;
        var arena_state = std.heap.ArenaAllocator.init(gpa);
        defer arena_state.deinit();
        self.view.resetFrame();
        const window_rect: region.Rect = .{ .x = 0, .y = 0, .w = @floatFromInt(fb[0]), .h = @floatFromInt(fb[1]) };
        // Carve the picker's window-bottom dock off the window FIRST, so the
        // panes lay out in what remains — the picker is a real region, not an
        // overlay, and cannot overlap a pane or status line (region.zig's
        // contract). Zero-height when no pick is open ⇒ panes fill the window.
        const dock_cut = window_rect.cutBottom(self.view.pickDockHeight(if (fx.head.pick.active) &fx.head.pick else null));
        const pick_dock = dock_cut.strip;
        const frame_rect = dock_cut.rest;
        fx.last_frame_rect.* = frame_rect;

        var slots: [window_layout.max_panes]window_layout.Slot = undefined;
        const focused = window_layout.headFocus(&self.win_layout, fx.head);
        const nslots = self.win_layout.collect(focused, frame_rect, &slots);

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
            const oed = ob.textEditor();
            if (oed) |e| {
                e.fold_layer = fx.caps.layers.find(&e.doc, "folds");
                e.readonly_layer = fx.caps.layers.find(&e.doc, "readonly");
                // Highlight this split too — reparse + publish its syntax (was
                // focused-pane-only, hence "one split at a time"). Its buffer is
                // attached by main's visible-pane loop, so resolveSyntax finds it.
                if (providers.resolveSyntax(ob)) |syn|
                    self.publishHighlight(gpa, e, syn, fx.caps, slot.pane.top_row) catch {};
            }
            const other_name = if (oed) |e| e.backingPath() orelse ob.name else ob.name;
            const other_layers = DocLayers.of(fx.caps, oed);
            const other_diag = other_layers.diagnostics;
            // A peeked pane's own `ui/statusline-seg` fire: mode + file only
            // (no buffer position/link — matches today's peeked-pane
            // rendering, which never showed those either) plus its own
            // diagnostics count and gutter context.
            var other_args: view_mod.ui_mesh.StatuslineArgs = .{
                .facts = .{ .mode = fx.head.currentMode(), .path = other_name },
                .file = other_name,
                .diag_layer = other_diag,
                .theme = &self.view.theme,
            };
            const other_segs = try view_mod.ui_mesh.fireStatusline(fx.ui_mesh, arena_state.allocator(), &other_args);
            const other_gutter: view_mod.ui_mesh.GutterFrame = .{
                .bindings = try view_mod.ui_mesh.gutterBindings(fx.ui_mesh, arena_state.allocator(), other_args.facts),
                .diag_layer = other_diag,
                .bp_lines = bpLines(arena_state.allocator(), fx.caps, oed),
            };
            const other_hud: view_mod.Hud = .{
                .mode = fx.head.currentMode(),
                .statusline_segs = other_segs,
                .gutter = other_gutter,
                .cursor_on = false, // the caret belongs to the focused pane
                .pane_border = slot.border,
                // A peeked pane keeps its syntax + markdown + tool colors + diagnostics.
                .highlight_layer = other_layers.highlight,
                .md_inline = if (oed) |e| mdInlineFor(arena_state.allocator(), e, other_name, slot.pane.top_row) else null,
                .styles_layer = other_layers.styles,
                .diag_layer = other_diag,
                .decorations_layer = other_layers.decorations,
            };
            const bo = try self.view.build(arena_state.allocator(), oed, other_hud, &slot.pane.top_row, slot.rect, .{}, world_to_pixel);
            try self.built_panes.append(gpa, bo);
        }

        // The focused pane: active buffer, full HUD, caret, picker dock.
        var fhud = hud;
        fhud.pane_border = foc_border;
        if (act.attach.syntax) |syn| if (editor) |ed| try self.publishHighlight(gpa, ed, syn, fx.caps, self.view.top_row);
        if (editor) |ed| {
            ed.fold_layer = fx.caps.layers.find(&ed.doc, "folds");
            ed.readonly_layer = fx.caps.layers.find(&ed.doc, "readonly");
        }
        const b = try self.view.build(arena_state.allocator(), editor, fhud, &self.view.top_row, foc_rect, pick_dock, world_to_pixel);
        try self.built_panes.append(gpa, b);
        focused.pane().top_row = self.view.top_row; // scrollToCursor may have moved it

        // Signal that the retained draw list changed. No GPU work happens here.
        self.rebuilt = true;
    }
};

// ── Tests: the hover-popup auto-expiry policy (rendering P2 review, F1) ──
// Deliberately over `expireIfStale` directly — no `WasmPlugin` (a live wasm
// instance) needed, just a hand-built `core.surface.Surface` and
// `stemma.Rope`, the same fixture-test idiom `core/surface.zig`'s own tests
// use. `expireStaleCaretSurfaces` (the `[]const *WasmPlugin` wrapper
// `buildFrame` actually calls) is a one-line loop over this — see its own
// doc for why testing the decision here covers it. A REAL, dispatch-driven
// integration test lives in `e2e/authoring_test.zig`
// ("hover popup auto-expires...", zls-backed): it drives a real cursor move
// through `ed.press` against the real `lsp` plugin's live surface, then
// calls this exact function (not a reimplementation) to prove the shipped
// policy closes a REAL popup, not just a fixture one.

const t = std.testing;

/// A `.caret` surface anchored at `off`, built + committed the same way
/// `Pick.buildCaretSurface`/the `lsp` guest's `presentHover` do (begin →
/// row → span → end, THEN set `anchor` — it's outside the double-buffered
/// build, see `core/surface.zig`'s own doc).
fn caretSurfaceAt(gpa: std.mem.Allocator, off: usize) core.surface.Surface {
    var surf: core.surface.Surface = .{};
    surf.begin(gpa, .caret);
    surf.addRow(gpa);
    surf.addSpan(gpa, "signature: fn add(a: i32, b: i32) i32", .normal);
    surf.end(gpa, null);
    surf.anchor = off;
    return surf;
}

test "expireIfStale: cursor still on the anchor's line — untouched" {
    const gpa = t.allocator;
    var rope = try stemma.Rope.fromSlice(gpa, "line zero\nline one\nline two\n");
    defer rope.deinit(gpa);
    const off = rope.lineRange(0).start + 2; // "li|ne zero" — the popup's anchor

    var surf = caretSurfaceAt(gpa, off);
    defer surf.deinit(gpa);

    expireIfStale(&surf, gpa, &rope, off); // cursor == anchor exactly
    try t.expect(surf.active);
    expireIfStale(&surf, gpa, &rope, rope.lineRange(0).start + 7); // same line, different column
    try t.expect(surf.active);
}

test "expireIfStale: cursor moves off the anchor's line — CLOSES it (fault-injectable)" {
    const gpa = t.allocator;
    var rope = try stemma.Rope.fromSlice(gpa, "line zero\nline one\nline two\n");
    defer rope.deinit(gpa);
    const anchor_off = rope.lineRange(0).start + 2;
    const moved_off = rope.lineRange(2).start + 1; // line 2 — far from the anchor's line 0

    var surf = caretSurfaceAt(gpa, anchor_off);
    defer surf.deinit(gpa); // a no-op once closed below; still safe either way
    try t.expect(surf.active); // sanity: built active, exactly like a real hover popup

    expireIfStale(&surf, gpa, &rope, moved_off);

    // The fault-injection this guards: comment out `expireIfStale`'s
    // `if (stale) surf.close(gpa);` (or its call site in
    // `expireStaleCaretSurfaces`) and this assertion fails — `surf.active`
    // stays true, reproducing F1 (the popup would keep painting over body
    // text after the cursor moved away). Verified by hand during review
    // remediation (temporarily no-op'd the close, confirmed THIS test
    // fails while the rest of the suite stays green, then restored it);
    // this is the permanent regression guard for that.
    try t.expect(!surf.active);
    try t.expectEqual(@as(usize, 0), surf.rows.items.len); // close() frees the rows too
}

test "expireIfStale: an anchor past the buffer's end (a buffer switch) also expires" {
    const gpa = t.allocator;
    var rope = try stemma.Rope.fromSlice(gpa, "short\n");
    defer rope.deinit(gpa);

    // An anchor from a since-closed, longer buffer — must not panic
    // `rope.offsetToPoint`'s in-range assert.
    var surf = caretSurfaceAt(gpa, 100);
    defer surf.deinit(gpa);

    expireIfStale(&surf, gpa, &rope, 2);
    try t.expect(!surf.active);
}

test "expireIfStale: spares a non-caret placement and a not-yet-active surface" {
    const gpa = t.allocator;
    var rope = try stemma.Rope.fromSlice(gpa, "line zero\nline one\n");
    defer rope.deinit(gpa);
    const far_off = rope.lineRange(1).start;

    // A `.bottom` surface (the picker dock's own shape, `Pick.buildSurface`'s
    // other branch) — this policy only ever names `.caret`, so a dock (or
    // any other placement) is untouched regardless of its anchor.
    var dock: core.surface.Surface = .{};
    dock.begin(gpa, .bottom);
    dock.addRow(gpa);
    dock.addSpan(gpa, "  query line", .normal);
    dock.end(gpa, null);
    dock.anchor = 0; // never read for a non-caret placement
    defer dock.deinit(gpa);
    expireIfStale(&dock, gpa, &rope, far_off);
    try t.expect(dock.active);

    // Nothing built yet (or already closed) — a no-op, not a crash on the
    // null anchor.
    var empty: core.surface.Surface = .{};
    defer empty.deinit(gpa);
    expireIfStale(&empty, gpa, &rope, far_off);
    try t.expect(!empty.active);
}
