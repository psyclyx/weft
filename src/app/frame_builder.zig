//! `FrameBuilder` owns the renderer-independent half of the render path: the
//! `View`, window-layout pane tree, per-frame draw items, and latency stats.
//! `buildFrame` gates on damage + partial-checkout realization, then runs a
//! frame in two halves (doc/model.md §2.7): `capture` takes the frame's input
//! — every pane's text and layers as snapshots, its HUD, and the plugin
//! answers it has — and `draw` builds each pane from that input alone into
//! its `built_panes` slot. No guest runs in either half: what a pane lacked
//! from a plugin is asked for after the frame (`answerRequests`), and lands
//! in the next one. None of this touches Vulkan or command submission. Unit
//! geometry tests may drive `view.build` directly; whole-app headless E2E
//! uses this same builder through Skia and Vulkan.

const std = @import("std");
const semantic = @import("weft_semantic");
const scene = @import("weft_scene");
const stemma = @import("stemma");
const view_mod = @import("weft_gfx").view;
const region = @import("weft_gfx").region;
const window_layout = @import("weft_gfx").window_layout;
const stats_mod = @import("weft_gfx").stats;
const core = @import("weft_core");
const cursor_config = @import("cursor_config.zig");
const providers = @import("providers.zig");
const collab = @import("collab.zig");
const answers_mod = @import("answers.zig");
const frame = @import("frame.zig");
const pointer_mod = @import("pointer.zig");
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
    const path = head.scene_selection.path() orelse return firstFocusableSemanticNode(root);
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
    /// Whatever third parties published about this entry (§11.7) — found by
    /// FEED CLASS, not by name, so a decorator the presentation has never
    /// heard of paints without anything here learning about it. Frame-lived.
    annotations: []const *const core.layers.Layer = &.{},

    fn of(arena: std.mem.Allocator, caps: *core.Caps, editor: ?*core.Editor) DocLayers {
        const ed = editor orelse return .{};
        return .{
            .highlight = caps.layers.find(&ed.doc, "highlight"),
            .styles = caps.layers.find(&ed.doc, "styles"),
            .diagnostics = caps.layers.find(&ed.doc, "diagnostics"),
            .decorations = caps.layers.find(&ed.doc, "decorations"),
            .presence = caps.layers.find(&ed.doc, "presence"),
            // Droppable by definition: a feed nobody could allocate a slot for
            // this frame simply doesn't paint this frame.
            .annotations = caps.layers.annotations(arena, &ed.doc) catch &.{},
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

/// A `weft.set(ns, key, "<ms>")` value in milliseconds, or null when unset
/// or not a number.
fn configMs(config: ?*const core.kv.Store, ns: []const u8, key: []const u8) ?u64 {
    const raw = (config orelse return null).get(ns, key) orelse return null;
    const s = core.framed.first(raw) orelse return null;
    return std.fmt.parseInt(u64, s, 10) catch null;
}

/// Whether a `weft.set(ns, key, "on")` switch is on.
fn configOn(config: ?*const core.kv.Store, ns: []const u8, key: []const u8) bool {
    const raw = (config orelse return false).get(ns, key) orelse return false;
    const s = core.framed.first(raw) orelse return false;
    return std.mem.eql(u8, s, "on") or std.mem.eql(u8, s, "true");
}

/// A pane's layers as its frame draws them: `DocLayers` snapshotted over the
/// pane's window (`layers.Snapshot`), so nothing that runs after the frame's
/// input is taken can move what the pane draws.
const PaneLayers = struct {
    highlight: ?*const core.layers.Snapshot = null,
    styles: ?*const core.layers.Snapshot = null,
    diagnostics: ?*const core.layers.Snapshot = null,
    decorations: ?*const core.layers.Snapshot = null,
    presence: ?*const core.layers.Snapshot = null,
    annotations: []const core.layers.Snapshot = &.{},

    fn take(arena: std.mem.Allocator, live: DocLayers, window: stemma.Range) !PaneLayers {
        const annotations = try arena.alloc(core.layers.Snapshot, live.annotations.len);
        for (live.annotations, annotations) |l, *s| s.* = try l.snapshot(arena, window);
        return .{
            .highlight = try one(arena, live.highlight, window),
            .styles = try one(arena, live.styles, window),
            .diagnostics = try one(arena, live.diagnostics, window),
            .decorations = try one(arena, live.decorations, window),
            .presence = try one(arena, live.presence, window),
            .annotations = annotations,
        };
    }

    fn one(arena: std.mem.Allocator, layer: ?*const core.layers.Layer, window: stemma.Range) !?*const core.layers.Snapshot {
        const l = layer orelse return null;
        const s = try arena.create(core.layers.Snapshot);
        s.* = try l.snapshot(arena, window);
        return s;
    }

    /// Onto `hud`, where the view reads them.
    fn apply(self: PaneLayers, hud: *view_mod.Hud) void {
        hud.highlight_layer = self.highlight;
        hud.styles_layer = self.styles;
        hud.diag_layer = self.diagnostics;
        hud.decorations_layer = self.decorations;
        hud.presence_layer = self.presence;
        hud.annotations = self.annotations;
    }
};

/// The facts a pane's chrome providers (status line, gutter) are asked
/// with: the one fact builder's (`intent.entryFacts`), in the pane's own
/// mode — the head's for the entry the head is on, the entry's resting mode
/// for any other pane, never the focused pane's mode stamped on every pane.
pub fn paneFacts(fx: *const FrameCtx, buffer: *core.Buffers.Buffer, pane: u32) core.facts.Facts {
    const head = fx.head;
    const open = core.context.openAt(fx.cmd_ctx.context, buffer);
    if (buffer == fx.buffers.active()) return core.intent.entryFacts(buffer, head.currentMode(), &head.scene_selection, pane, open);
    return core.intent.entryFacts(buffer, core.intent.restingModeOf(fx.buffers, buffer), &buffer.scene_selection, pane, open);
}

/// What an answer about `buffer` depends on besides the ask itself: which
/// entry, at which revision, under which facts. Every chrome key starts here.
/// The revision is the subject's (`Context.revisionOf`): its text AND its
/// tree, so an answer read from the outline before a parse landed (empty
/// breadcrumbs) is a different question once it has, and is asked again.
fn entryKey(tag: []const u8, fx: *const FrameCtx, buffer: *core.Buffers.Buffer, facts: core.facts.Facts) std.hash.Wyhash {
    var h = std.hash.Wyhash.init(0);
    h.update(tag);
    h.update(std.mem.asBytes(&buffer.id));
    h.update(std.mem.asBytes(&buffer.generation));
    const revision: u64 = if (fx.cmd_ctx.context) |c| c.revisionOf(buffer) else if (buffer.textEditor()) |ed| @intFromEnum(ed.doc.revision()) else 0;
    h.update(std.mem.asBytes(&revision));
    h.update(std.mem.asBytes(&facts.digest()));
    return h;
}

/// The question a pane's gutter asks this frame (`answers.Key`).
/// No caret in it: the gutter's question does not carry one (`core.gutter`),
/// so a caret move is not a new question — a column counted from the caret
/// is a formula the frame evaluates against its own snapshot.
fn gutterKey(fx: *const FrameCtx, buffer: *core.Buffers.Buffer, facts: core.facts.Facts, line_count: usize) answers_mod.Key {
    var h = entryKey("gutter", fx, buffer, facts);
    h.update(std.mem.asBytes(&line_count));
    return h.final();
}

/// The question a pane's status line asks this frame, and the ask that
/// carries it.
fn statusQuestion(fx: *const FrameCtx, buffer: *core.Buffers.Buffer, facts: core.facts.Facts, focused: bool) struct { key: answers_mod.Key, ask: ?core.status_segment.Ask } {
    const caret: usize = if (buffer.textEditor()) |ed| ed.cursorOffset() else 0;
    var h = entryKey("status", fx, buffer, facts);
    h.update(std.mem.asBytes(&caret));
    h.update(&.{@intFromBool(focused)});
    const c32 = std.math.cast(u32, caret) orelse return .{ .key = h.final(), .ask = null };
    return .{ .key = h.final(), .ask = .{ .caret = c32, .focused = focused } };
}

/// Resolve one pane's gutter for this frame: the eligible providers (one
/// Container scan) and, when a PLUGIN is among them, the answers it has —
/// from `answers`, never from the plugin: a frame asks no guest anything. The
/// pane's `facts` carry its tool and posture, so a provider bound to text
/// entries never answers for a git status or a file listing.
pub fn gutterFrame(
    arena: std.mem.Allocator,
    fx: *const FrameCtx,
    answers: *const answers_mod.Answers,
    pane: u32,
    buffer: *core.Buffers.Buffer,
    facts: core.facts.Facts,
    diag_layer: ?*const core.layers.Snapshot,
    bp_lines: []const u8,
) !view_mod.ui_mesh.GutterFrame {
    var gf: view_mod.ui_mesh.GutterFrame = .{
        .bindings = try view_mod.ui_mesh.gutterBindings(fx.ui_mesh, arena, facts),
        .diag_layer = diag_layer,
        .bp_lines = bp_lines,
    };
    if (buffer.textEditor()) |ed| {
        const rope = ed.text();
        gf.line_count = rope.lineCount();
        gf.caret_line = rope.offsetToPoint(@min(ed.cursorOffset(), rope.byteLen())).row;
    }
    for (gf.bindings) |b| {
        if (b.provider != .schema_provider) continue;
        const batch = try arena.create(view_mod.ui_mesh.GutterBatch);
        batch.* = .{
            .windows = try answers.gutterWindows(arena, pane, answers_mod.subjectOf(buffer)),
            .key = gutterKey(fx, buffer, facts, gf.line_count),
            .caret_line = gf.caret_line,
        };
        gf.batch = batch;
        break;
    }
    return gf;
}

/// Ask for this frame's status question after the frame, unless the answer
/// `pane` has is already to it.
fn wantStatus(fx: *const FrameCtx, answers: *answers_mod.Answers, pane: u32, subject: answers_mod.Subject, buffer: *core.Buffers.Buffer, facts: core.facts.Facts, focused: bool) void {
    const q = statusQuestion(fx, buffer, facts, focused);
    if (answers.status(pane, subject)) |e| if (e.key == q.key) return;
    const ask = q.ask orelse return;
    answers.want(.{ .pane = pane, .entry = buffer.ref(), .subject = subject, .key = q.key, .ask = .{ .status = ask } });
}

/// Ask every question the last frame had no answer to, and cache what the
/// providers say (doc/model.md §2.7). Runs after the frame, on the loop —
/// never during layout — so a provider answering may act like any other
/// code: an edit it makes is the next version, drawn by the next frame,
/// never torn into this one. True when anything was asked: the answers are
/// what the next frame should draw.
///
/// Each question is asked with facts built NOW, in the same wake as the frame
/// that asked it (nothing ran between them but other answers), and filed
/// under the key the frame asked with. A provider whose answer moved the
/// state it was asked about just leaves the next frame a new question.
pub fn answerRequestsFor(fx: *const FrameCtx, answers: *answers_mod.Answers) !bool {
    const pending = try answers.takePending();
    defer answers.gpa.free(pending);
    if (pending.len == 0) return false;
    const host = fx.cmd_ctx.slot_host orelse return false;
    for (pending) |req| {
        const buffer = fx.buffers.resolve(req.entry) orelse continue;
        const facts = paneFacts(fx, buffer, req.pane);
        const entry = try answers.begin(req);
        errdefer answers.discard(entry);
        const a = entry.arena.allocator();
        const slot: []const u8 = switch (req.ask) {
            .gutter => core.gutter.slot_name,
            .status => core.status_segment.slot_name,
        };
        const request: []const u8 = switch (req.ask) {
            .gutter => |ask| try core.gutter.encodeAsk(a, ask),
            .status => |ask| try core.status_segment.encodeAsk(a, ask),
        };
        // Nobody eligible is an answer too: the empty one, cached like any
        // other so the same question is not asked again next frame.
        if (try host.fire(slot, facts, "", .{ .request = request, .ctx = fx.cmd_ctx })) |id| {
            defer host.finish(id);
            const results = if (host.session(id)) |s| s.all() else &.{};
            switch (entry.answer) {
                .gutter => |*w| {
                    const out = try a.alloc(view_mod.ui_mesh.GutterBatch.Answer, results.len);
                    for (results, out) |r, *o| o.* = try view_mod.ui_mesh.decodeGutterAnswer(a, r.provider, r.payload);
                    w.answers = out;
                },
                .status => |*s| {
                    const out = try a.alloc(view_mod.ui_mesh.StatuslineAnswer, results.len);
                    for (results, out) |r, *o| o.* = try view_mod.ui_mesh.decodeStatuslineAnswer(a, r.provider, r.payload);
                    s.* = out;
                },
            }
        }
        try answers.store(entry);
    }
    return true;
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

/// Whether the entry's focus is a ROW of its text: a produced projection (a
/// status listing) whose point is on no editable span, under a grammar that
/// focuses rows (doc/chrome.md §5.2). Such a pane shows the row, not a caret.
fn rowFocused(fx: *const FrameCtx, buffer: *core.Buffers.Buffer) bool {
    if (fx.semantic.granularity != .row) return false;
    if (buffer.projection == null) return false;
    return buffer.posture(buffer.fieldAtPoint()) == .structural;
}

fn semanticDocumentFor(arena: std.mem.Allocator, fx: *const FrameCtx, buffer: *core.Buffers.Buffer, focus: *const core.Head.SceneSelection, active: bool) ?view_mod.semantic_data.Document {
    const path = focus.path() orelse return null;
    const instance = fx.semantic.views.get(path.view) orelse return null;
    return .{
        .view = path.view,
        .root = &instance.scene,
        .title = buffer.name,
        .focused = if (path.leaf()) |node| if (instance.node(node) != null) node else instance.reconcileFocus(null) else instance.reconcileFocus(null),
        .editing = focus.field,
        .selected = selectedRows(arena, instance, focus),
        .revealed = fx.semantic.views.revealed(path.view),
        .active = active,
        .fields = &fx.semantic.fields,
    };
}

/// Every row the scene's selection covers beyond the one focused row: the
/// primary extent's range, and each marked extent's — what the view washes
/// as selected. Empty for the one focused row alone.
fn selectedRows(arena: std.mem.Allocator, instance: anytype, focus: *const core.Head.SceneSelection) []const semantic.scene.NodeId {
    if (focus.extentCount() <= 1 and focus.anchor == null) return &.{};
    var out: std.ArrayList(semantic.scene.NodeId) = .empty;
    const order = instance.focus_order;
    const primary = focus.primaryRows() orelse return &.{};
    const extents = [_][]const core.Head.SceneSelection.Rows{ &.{primary}, focus.others.items };
    for (extents) |list| for (list) |r| {
        const a = std.mem.indexOfScalar(semantic.scene.NodeId, order, r.anchor) orelse continue;
        const b = std.mem.indexOfScalar(semantic.scene.NodeId, order, r.head) orelse continue;
        out.appendSlice(arena, order[@min(a, b) .. @max(a, b) + 1]) catch return out.items;
    };
    return out.items;
}

/// What the pointer rests on in `pane`, as this frame's input for the chrome
/// style (`Hud.pointer`): the target, whether a button is held on it, and
/// whether its tooltip is due. Nothing, for a pane the pointer is not over.
fn pointerIn(fx: *const FrameCtx, pane: u32) view_mod.Hover {
    const hover = fx.hover;
    if (hover.target.pane != pane) return .{};
    const g = &fx.head.pointer;
    const held = g.kind == .press or g.kind == .drag;
    return .{
        .at = hover.at,
        .chrome = if (hover.target.chrome) |c| .{
            .kind = switch (c.kind) {
                .tab => .tab,
                .status => .status,
            },
            .index = c.index,
            .part = switch (c.part) {
                .body => .body,
                .close => .close,
            },
        } else null,
        .node = if (hover.target.node) |n| .{ .view = n.view, .node = n.node } else null,
        .pressed = held and pointer_mod.Hover.Target.of(g.origin).eql(hover.target),
        .tooltip = hover.ripe,
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
            .editing = if (fx.head.scene_selection.path()) |path| if (path.view.eql(descriptor.view)) path.field else null else null,
            .fields = &fx.semantic.fields,
        },
        .presentation = descriptor.presentation,
        .pointer = if (fx.head.pointer.origin.pane != null) .{ fx.head.pointer.origin.x, fx.head.pointer.origin.y } else null,
    };
}

/// One pane of a frame's input: everything `View.build` reads for it, taken
/// before any pane is laid out (doc/model.md §2.7). The text is a
/// `core.TextSnapshot` and every layer on `hud` a `layers.Snapshot`; the rest
/// of `hud` is values, frame-arena copies, or host state (surfaces, semantic
/// scenes, strings) that nothing mutates between capture and draw — no guest
/// runs there, and neither does dispatch.
pub const PaneInput = struct {
    pane: u32,
    entry: core.Buffers.Ref,
    /// What the pane's answers are about (`answers.subjectOf(entry)`).
    subject: answers_mod.Subject,
    rect: region.Rect,
    /// The window-bottom dock (only the focused pane carries it).
    dock: region.Rect = .{},
    /// The scroll the pane draws at, already settled around its caret.
    top_row: usize,
    /// Where that scroll lives in the workspace: a semantic pane settles its
    /// own while drawing, and `buildFrame` writes the drawn value back here.
    top_row_at: *usize,
    text: ?core.TextSnapshot,
    hud: view_mod.Hud,
    focused: bool,
};

/// A frame's input: every pane's `PaneInput`, in draw order (the focused
/// pane last, so the view's geometry map ends on it). Owns its arena and the
/// panes' rope handles.
pub const FrameInput = struct {
    gpa: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    panes: std.ArrayList(PaneInput) = .empty,
    world_to_pixel: scene.Transform2D = undefined,
    /// Nanoseconds spent taking the text and layer snapshots, summed over the
    /// panes — the cost this frame paid to be a function of a version.
    snapshot_ns: u64 = 0,

    pub fn init(gpa: std.mem.Allocator) FrameInput {
        return .{ .gpa = gpa, .arena = .init(gpa) };
    }

    pub fn deinit(self: *FrameInput) void {
        for (self.panes.items) |*p| if (p.text) |*tx| tx.release(self.gpa);
        self.arena.deinit();
    }

    pub fn allocator(self: *FrameInput) std.mem.Allocator {
        return self.arena.allocator();
    }
};

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
    /// What plugins last said about each pane's chrome, and what the last
    /// frame asked them (`answers.zig`). A frame reads it; `answerRequests`,
    /// after the frame, fills it.
    answers: answers_mod.Answers,

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
        self.answers = .init(gpa);
    }

    pub fn deinit(self: *FrameBuilder) void {
        self.answers.deinit();
        self.win_layout.deinit();
        for (self.built_panes.items) |*b| b.deinit(self.gpa);
        self.built_panes.deinit(self.gpa);
        self.view.deinit();
    }

    /// Ask the plugins what the last frame had no answer to
    /// (`answerRequestsFor`). The loop calls this after every build; true
    /// means answers landed and the next frame should draw them.
    pub fn answerRequests(self: *FrameBuilder, fx: *const FrameCtx) !bool {
        return answerRequestsFor(fx, &self.answers);
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

    /// Reparse and publish the buffer's syntax highlight over `window`, the
    /// rows the pane is about to show. `Syntax.publishHighlight` paints from
    /// its per-(tree, window) cache, so a frame that changed nothing the text
    /// shows runs no query. Two panes on one buffer each publish their own
    /// window, and each takes its snapshot straight after, so neither reads
    /// the other's.
    fn publishHighlight(fx: *const FrameCtx, buf: *core.Buffers.Buffer, editor: *core.Editor, window: stemma.Range) !void {
        const syn = providers.resolveSyntax(buf) orelse return;
        _ = try syn.sync(fx.gpa, &editor.doc);
        const hl = fx.caps.layers.find(&editor.doc, "highlight") orelse return;
        try syn.publishHighlight(fx.gpa, &editor.doc, hl, window);
    }

    /// Per-byte markdown attributes for a `.md` buffer over that pane's
    /// window, into `arena` (the frame input's). Null for non-md.
    /// The status note for an entry in a remote place: where it is and how
    /// reachable (`shell:box connecting`, `peer 3f2a… offline`). Null for a
    /// place here, or with no locus registry to ask.
    pub fn remoteNote(arena: std.mem.Allocator, loci: ?*core.locus.Loci, place: core.Place) !?[]const u8 {
        const l = place.locus();
        if (l == .here) return null;
        const registry = loci orelse return null;
        const state = @tagName(registry.liveness(l));
        return switch (registry.authority(l)) {
            .here => null,
            .shell => |id| try std.fmt.allocPrint(arena, "shell:{s} {s}", .{ id, state }),
            .peer => |fp| try std.fmt.allocPrint(arena, "peer {s}… {s}", .{ fp[0..@min(fp.len, 8)], state }),
        };
    }

    fn mdInlineFor(arena: std.mem.Allocator, editor: *core.Editor, name: []const u8, window: stemma.Range) ?view_mod.MdInline {
        if (!cursor_config.isMarkdownPath(name)) return null;
        const attrs = core.markdown.analyze(arena, editor.text(), window) catch return null;
        return .{ .base = window.start, .attrs = attrs };
    }

    /// One pane to capture: its entry and place, and the HUD fields decided
    /// for it before its own chrome is (the whole-app fields for the focused
    /// pane; mode, border and flags for another).
    const PaneSpec = struct {
        buffer: *core.Buffers.Buffer,
        pane: u32,
        rect: region.Rect,
        dock: region.Rect = .{},
        top_row: *usize,
        hud: view_mod.Hud,
        focused: bool,
        facts: core.facts.Facts,
        /// The focused pane's extra status inputs.
        buffer_pos: ?[]const u8 = null,
        link: ?[]const u8 = null,
    };

    /// Take one pane's input: settle its scroll around its caret, prepare its
    /// per-byte inputs over the window that scroll shows, snapshot its text
    /// and layers, and compose its chrome from host providers and the plugin
    /// answers it has. No guest is called; a plugin answer this pane lacks is
    /// requested for after the frame.
    fn capturePane(self: *FrameBuilder, fx: *const FrameCtx, input: *FrameInput, spec: PaneSpec) !void {
        const arena = input.allocator();
        const ed = spec.buffer.textEditor();
        const name = if (ed) |e| e.backingPath() orelse spec.buffer.name else spec.buffer.name;
        const live = DocLayers.of(arena, fx.caps, ed);
        var hud = spec.hud;

        var text: ?core.TextSnapshot = null;
        errdefer if (text) |*tx| tx.release(fx.gpa);
        var window: stemma.Range = .{ .start = 0, .end = 0 };
        if (ed) |e| {
            e.fold_layer = fx.caps.layers.find(&e.doc, "folds");
            e.readonly_layer = fx.caps.layers.find(&e.doc, "readonly");
            const t0 = stats_mod.nowNs();
            text = try core.TextSnapshot.of(e, arena);
            input.snapshot_ns += stats_mod.nowNs() - t0;
            // The scroll FIRST (exactly what `View.build` does: keep the caret
            // in view), then everything sized by the rows it shows — so a jump
            // past the paint margin never draws a frame prepared around where
            // the pane used to be.
            if (hud.semantic_view == null) {
                self.view.settleScroll(&text.?, hud, spec.top_row, spec.rect);
                window = text.?.window(spec.top_row.*, self.view.bodyRowsIn(hud, spec.rect));
                hud.md_inline = mdInlineFor(arena, e, name, window);
                // A failed publish only costs this pane its colors.
                publishHighlight(fx, spec.buffer, e, window) catch |err| if (spec.focused) return err;
            }
        }
        const t0 = stats_mod.nowNs();
        const layers = try PaneLayers.take(arena, live, window);
        input.snapshot_ns += stats_mod.nowNs() - t0;
        layers.apply(&hud);
        hud.pointer = pointerIn(fx, spec.pane);

        // Every answer this pane draws or asks for is about its subject: a
        // pane that just moved to another entry draws none of the last one's.
        const subject = answers_mod.subjectOf(spec.buffer);
        var status_args: view_mod.ui_mesh.StatuslineArgs = .{
            .facts = spec.facts,
            .file = if (ed) |e| (if (e.backingPath()) |p| core.designation.placeRelative(spec.buffer, fx.cmd_ctx.realizer, p, try arena.alloc(u8, core.designation.max_len)) else name) else name,
            .buffer_pos = spec.buffer_pos,
            .diag_layer = live.diagnostics,
            .link = spec.link,
            .theme = &self.view.theme,
            .plugin_answers = if (self.answers.status(spec.pane, subject)) |e| e.answer.status else &.{},
        };
        hud.statusline_segs = try view_mod.ui_mesh.fireStatusline(fx.ui_mesh, arena, &status_args);
        if (status_args.plugin_reached) wantStatus(fx, &self.answers, spec.pane, subject, spec.buffer, spec.facts, spec.focused);
        hud.gutter = try gutterFrame(arena, fx, &self.answers, spec.pane, spec.buffer, spec.facts, layers.diagnostics, bpLines(arena, fx.caps, ed));

        try input.panes.append(arena, .{
            .pane = spec.pane,
            .entry = spec.buffer.ref(),
            .subject = subject,
            .rect = spec.rect,
            .dock = spec.dock,
            .top_row = spec.top_row.*,
            .top_row_at = spec.top_row,
            .text = text,
            .hud = hud,
            .focused = spec.focused,
        });
        text = null; // the input owns it now
    }

    /// Backend-independent frame BUILD: gate on damage + partial-checkout
    /// realization, take the frame's input (`capture`), draw it (`draw`), and
    /// leave behind what the frame learned: the settled scrolls, the visible
    /// range, and the plugin questions it had no answer to. NO swapchain,
    /// command-buffer, or GPU atlas work happens here — that is the backend
    /// `present`'s job, driven by the `rebuilt` signal this sets. A clean,
    /// unblocked frame keeps last frame's build and returns early (leaving
    /// `rebuilt` false, so `present` skips the re-upload/re-emit).
    pub fn buildFrame(self: *FrameBuilder, fx: *const FrameCtx, act: Active) !void {
        if (!(fx.view_dirty.* and !self.partialBlocked(fx))) return;
        fx.view_dirty.* = false;

        var input: FrameInput = .init(fx.gpa);
        defer input.deinit();
        try self.capture(fx, act, &input);
        self.stats.snapshot.push(input.snapshot_ns);

        var tops: [window_layout.max_panes]usize = undefined;
        try self.draw(&input, tops[0..input.panes.items.len]);

        // What the frame learned, written back after it was drawn.
        var live: [window_layout.max_panes]u32 = undefined;
        for (input.panes.items, tops[0..input.panes.items.len], 0..) |p, top, i| {
            p.top_row_at.* = top;
            live[i] = p.pane;
            const gf = p.hud.gutter orelse continue;
            const batch = gf.batch orelse continue;
            const first = batch.wanted orelse continue;
            self.answers.want(.{ .pane = p.pane, .entry = p.entry, .subject = p.subject, .key = batch.key, .ask = .{ .gutter = .{
                .first = std.math.cast(u32, first) orelse continue,
                .count = core.gutter.window,
                .lines = std.math.cast(u32, gf.line_count) orelse continue,
            } } });
        }
        self.answers.retainPanes(live[0..input.panes.items.len]);
        const focused = window_layout.headFocus(&self.win_layout, fx.head);
        focused.pane().top_row = self.view.top_row; // the focused pane's scroll lives on the view
        // What the focused pane SHOWS, for a guest acting on the visible
        // range (`wl_view_range`) — only the layout knows it, after
        // scrolling and folds.
        const shown = self.view.frame_layout.lines;
        fx.head.view_range = if (act.editor != null and shown.len > 0) .{
            .entry = act.abuf.ref(),
            .start = shown[0].src.start,
            .end = shown[shown.len - 1].src.end,
        } else null;
    }

    /// Take the frame's input (doc/model.md §2.7): assemble the whole-app
    /// `Hud`, tile the panes, and capture each (`capturePane`) — the
    /// non-focused panes first (their own scroll, no caret/dock), the focused
    /// pane last with the full HUD, caret and picker dock. Host-side
    /// housekeeping the frame has always done (flash timing, expiring a stale
    /// caret popup, the published highlight) happens here, BEFORE anything is
    /// drawn; nothing here calls a guest.
    pub fn capture(self: *FrameBuilder, fx: *const FrameCtx, act: Active, input: *FrameInput) !void {
        const gpa = fx.gpa;
        const editor = act.editor;
        const abuf = act.abuf;
        const fb = act.fb;
        const arena = input.allocator();

        // How chrome looks is read from its theme slot at the top of every
        // frame, so whatever last bound it — config, theme, the live switch —
        // is what this frame draws (doc/chrome.md §3.2).
        self.view.resolveChrome(fx.ui_mesh, fx.cmd_ctx.capturedCtx().mergedFacts());
        const projection = scene.Mat4.ortho(0, @floatFromInt(fb[0]), @floatFromInt(fb[1]), 0, -1, 1);
        input.world_to_pixel = scene.mvpToScenePixel(projection, @floatFromInt(fb[0]), @floatFromInt(fb[1])) orelse unreachable;

        const doc_layers = DocLayers.of(arena, fx.caps, editor);
        const doc_status = DocStatus.of(gpa, editor, doc_layers);

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
            .remote => |r| if (shared_here) try std.fmt.allocPrint(arena, "{s}+shared", .{r.remote.vtable.label}) else r.remote.vtable.label,
        };
        var listen_buf: [40]u8 = undefined;
        // An entry in a remote place says how that place is reachable (R5):
        // its locus's liveness, whichever tier it is on — a shell connecting,
        // a peer's tree gone offline — ahead of the connection's own note.
        const link_note: ?[]const u8 = if (try remoteNote(arena, fx.cmd_ctx.loci, abuf.place)) |note|
            note
        else if (fx.collab_session.*) |s|
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
        // into `Pick`'s fields. Arena-owned, so the pointer below stays valid
        // through this frame's draw.
        const pick_surface: ?*const core.surface.Surface = if (fx.head.pick.active) blk: {
            const s = try arena.create(core.surface.Surface);
            s.* = fx.head.pick.buildSurface(arena, view_mod.Hud.max_pick_rows) orelse break :blk null;
            break :blk s;
        } else null;

        // Rendering P2 fix (post-review): a retained GUEST `.caret` surface
        // (the `lsp` plugin's hover, today) auto-EXPIRES before it's
        // collected below — see `expireStaleCaretSurfaces`'s doc for the
        // close-vs-skip rationale. The picker's OWN `.caret` surface
        // (`pick_surface`, just above) is untouched by this — it isn't in
        // `fx.plugins`, and `Pick.buildSurface` rebuilds it fresh every frame
        // with the live anchor, so it can never go stale the same way
        // (verified: typing narrows completion with no flicker —
        // `authoring_test.zig`'s existing narrowing test stays green).
        if (editor) |ed| expireStaleCaretSurfaces(fx.plugins.items, ed.text(), ed.cursorOffset());

        // Collect the plugins' live overlays for this frame (which-key,
        // files, git … render through the retained surface door) plus the
        // picker's own scene, built just above.
        var surfaces: std.ArrayList(*const core.surface.Surface) = .empty;
        if (pick_surface) |ps| try surfaces.append(arena, ps);
        for (fx.plugins.items) |pl| {
            if (pl.surface.active and surfaces.items.len < 65) try surfaces.append(arena, &pl.surface);
        }
        // which-key: while a leader/chord prefix is active (a leaf menu
        // mode) and no picker is open, list that mode's bindings. This is
        // the host FALLBACK — if a which-key plugin is loaded it renders a
        // surface and the host render steps aside, so the menu is never
        // drawn twice. It also honors the idle delay (`menu_shown`): without
        // that, this fallback flashed in the panel during the delay window
        // BEFORE a plugin's (e.g. centered) surface appeared — the "corner
        // first, then middle" jump.
        var wk_hints: std.ArrayList(core.Keymap.Binding) = .empty;
        if (act.menu_shown and surfaces.items.len == 0 and !fx.head.pick.active and fx.head.interactions.active() == null and fx.keymap.modeHasTag(fx.head.currentMode(), "menu")) {
            fx.keymap.ownBindings(arena, fx.head.currentMode(), &wk_hints) catch {};
        }
        // Buffer tab strip (only with more than one buffer open). Name
        // slices borrow the buffers' own strings — valid this frame.
        var tab_list: std.ArrayList(view_mod.Tab) = .empty;
        if (fx.buffers.count() > 1) {
            var bit3 = fx.buffers.iterator();
            while (bit3.next()) |b| {
                // A docked companion's entry (the file tree, a panel, a
                // toolbar) is chrome, not a document: never a tab.
                var held_buf: [core.designation.max_len]u8 = undefined;
                if (core.designation.of(b, &held_buf)) |held| if (fx.viewports.holdsEntry(held)) continue;
                const nm = if (b.textEditor()) |ed| ed.backingPath() orelse b.name else b.name;
                tab_list.append(arena, .{ .name = std.fs.path.basename(nm), .active = b == abuf, .id = b.id, .path = nm }) catch {};
            }
        }
        // vim-goggles: an operation flashed a set of ranges on a document;
        // show them for the duration. The duration is re-read from the
        // configuration as each new flash starts, so a reload applies to the
        // next one; an undo's flash shows only where the configuration
        // turned it on (`editor/flash-undo`).
        // The undo set lives beside the edit set (`core/flash.zig`), so with
        // flash-undo off an undo is not even a new generation here: a fading
        // yank keeps fading. Every range of the set draws (frame arena).
        const flash_ranges: []const stemma.Range = fblk: {
            const fs = &fx.caps.flash;
            const which = fs.showing(configOn(fx.config, "editor", "flash-undo"));
            const gen = fs.genOf(which);
            if (gen != fx.flash_gen.*) {
                fx.flash_gen.* = gen;
                fx.flash_start_ns.* = act.frame_start;
                if (configMs(fx.config, "editor", "flash-ms")) |ms| fx.flash_duration_ns.* = ms * std.time.ns_per_ms;
            }
            const active = gen > 0 and (act.frame_start -| fx.flash_start_ns.*) < fx.flash_duration_ns.*;
            if (active or fx.flash_was_active.*) fx.view_dirty.* = true; // draw it, then clear it
            fx.flash_was_active.* = active;
            if (!active) break :fblk &.{};
            const ed = editor orelse break :fblk &.{};
            const buf = arena.alloc(stemma.Range, fs.countOf(which, &fx.caps.layers, &ed.doc)) catch break :fblk &.{};
            break :fblk fs.rangesOf(which, &fx.caps.layers, &ed.doc, buf);
        };
        const cursor_mode = fx.cursor_cfg.resolveMode(fx.keymap, fx.head, fx.head.currentMode());
        const hud: view_mod.Hud = .{
            .mode = fx.head.currentMode(),
            .which_key = if (wk_hints.items.len > 0) wk_hints.items else null,
            .surfaces = surfaces.items,
            .semantic_view = semanticDocumentFor(arena, fx, fx.buffers.active(), &fx.head.scene_selection, true),
            .semantic_overlay = semanticOverlay(fx),
            .flash = flash_ranges,
            // Rendering P2: hover is a LIVE producer now — the `lsp` guest
            // plugin emits its own `.caret` surface (`wl_surface_caret`)
            // straight into `hud.surfaces` above (via `fx.plugins`), same as
            // which-key/files/git. This field is dead in production; see
            // `View.build`'s doc for why it stays as a legacy/test-only path.
            .hover = null,
            .tabs = if (tab_list.items.len > 1) tab_list.items else null,
            .cursor_style = fx.cursor_cfg.styleFor(cursor_mode, fx.head.textCommitIn(fx.keymap, cursor_mode) != null),
            .caret_place = fx.cursor_cfg.placeFor(cursor_mode),
            .cursor_on = if (fx.cursor_cfg.blinkFor(cursor_mode)) act.blink_on else true,
            .row_focus = rowFocused(fx, abuf),
            .dirty = doc_status.dirty,
            .save_failed = doc_status.save_failed,
            .backing = backing_chip,
            .brand_mark = std.mem.eql(u8, abuf.tool, "dashboard"),
            .save_note = doc_status.save_note,
            .unfetched_pct = doc_status.unfetched_pct,
            .peers = doc_status.peers,
            .echo = if (fx.head.echo.items.len > 0) try arena.dupe(u8, fx.head.echo.items) else null,
            .plugin_status = if (fx.buffers.status.get()) |s| try arena.dupe(u8, s) else null,
            // Rendering P2: the picker's scene already went into
            // `hud.surfaces` (`pick_surface`, above) — this field is dead in
            // production; see `View.build`'s doc.
            .pick = null,
            .trust = if (fx.collab_session.* != null) blk: {
                const fp = fx.noted_host_fp.* orelse break :blk null;
                break :blk collab.hostTrustChip(fx.known_peers.trust(fp));
            } else null,
            .cursor_diag = doc_status.cursor_diag,
        };

        const window_rect: region.Rect = .{ .x = 0, .y = 0, .w = @floatFromInt(fb[0]), .h = @floatFromInt(fb[1]) };
        // Carve the window-bottom dock off the window FIRST, so the panes lay
        // out in what remains — the picker (or a plugin's `.bottom` surface,
        // a find bar) is a real region, not an overlay, and cannot overlap a
        // pane or status line (region.zig's contract). Zero-height when
        // neither is showing ⇒ panes fill the window.
        const dock_cut = window_rect.cutBottom(self.view.dockHeight(if (fx.head.pick.active) &fx.head.pick else null, hud.surfaces));
        const pick_dock = dock_cut.strip;
        const frame_rect = dock_cut.rest;
        fx.last_frame_rect.* = frame_rect;

        var slots: [window_layout.max_panes]window_layout.Slot = undefined;
        const focused = window_layout.headFocus(&self.win_layout, fx.head);
        // A row-sized dock is as tall as the rows the view draws NOW.
        self.win_layout.rows = .{ .line_h = self.view.line_h, .inset = 2 * view_mod.View.pane_margin };
        const nslots = self.win_layout.collect(focused, frame_rect, &slots);
        // The tab strip lists the documents, so it sits on a pane that shows
        // them: the focused one when it is an ordinary pane, else the first
        // primary pane (focus in a docked panel leaves it over the editor).
        const tabs_pane: ?u32 = if (focused.pane().attrs.isPrimary())
            focused.pane().id
        else if (self.win_layout.primaryPane()) |p| p.pane().id else null;

        var foc_rect = frame_rect;
        var foc_border: region.Edges = .{};
        for (slots[0..nslots]) |slot| {
            if (slot.focused) {
                foc_rect = slot.rect;
                foc_border = slot.border;
                continue; // the focused pane is captured last, below
            }
            const ob = fx.buffers.get(slot.pane.buffer_id) orelse continue;
            // A peeked pane: mode + file on its status line (no buffer
            // position/link — a peeked pane never showed those), its own
            // diagnostics count, gutter, syntax, markdown and tool colors.
            const other_facts = paneFacts(fx, ob, slot.pane.id);
            try self.capturePane(fx, input, .{
                .buffer = ob,
                .pane = slot.pane.id,
                .rect = slot.rect,
                .top_row = &slot.pane.top_row,
                .focused = false,
                .facts = other_facts,
                .hud = .{
                    .mode = other_facts.mode,
                    .tabs = if (tabs_pane == slot.pane.id) hud.tabs else null,
                    .status_line = slot.pane.attrs.status_line,
                    .brand_mark = std.mem.eql(u8, ob.tool, "dashboard"),
                    .semantic_view = semanticDocumentFor(arena, fx, ob, &ob.scene_selection, false),
                    .cursor_on = false, // the caret belongs to the focused pane
                    // The focused pane, built last, paints the tooltip.
                    .tooltips = false,
                    .pane_border = slot.border,
                },
            });
        }

        // The focused pane: active buffer, full HUD, caret, picker dock.
        var fhud = hud;
        fhud.pane_border = foc_border;
        fhud.float_bounds = frame_rect;
        if (tabs_pane != focused.pane().id) fhud.tabs = null;
        fhud.status_line = focused.pane().attrs.status_line;
        try self.capturePane(fx, input, .{
            .buffer = abuf,
            .pane = focused.pane().id,
            .rect = foc_rect,
            .dock = pick_dock,
            .top_row = &self.view.top_row,
            .focused = true,
            .facts = paneFacts(fx, abuf, fx.head.focused_pane),
            .hud = fhud,
            .buffer_pos = buffer_pos,
            .link = link_note,
        });
    }

    /// Draw a frame's input into `built_panes`: one `View.build` per pane, in
    /// the input's order, each into its own rect (identity transform). A pure
    /// function of `input` (and the view's fonts and theme): drawing the same
    /// input twice yields the same draw lists. `tops` receives each pane's
    /// drawn scroll. Backend-independent: it produces explicit draw items;
    /// the renderer consumes `built_panes`.
    pub fn draw(self: *FrameBuilder, input: *FrameInput, tops: []usize) !void {
        const gpa = self.gpa;
        self.view.resetFrame();
        // Free last frame's builds; each pane appends a fresh one below.
        for (self.built_panes.items) |*old| old.deinit(gpa);
        self.built_panes.clearRetainingCapacity();
        const arena = input.allocator();
        for (input.panes.items, tops) |*p, *top| {
            top.* = p.top_row;
            const text: ?*const core.TextSnapshot = if (p.text) |*tx| tx else null;
            const built = try self.view.build(arena, text, p.hud, top, p.rect, p.dock, input.world_to_pixel);
            self.view.recordPane(p.pane, p.rect);
            try self.built_panes.append(gpa, built);
        }
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
