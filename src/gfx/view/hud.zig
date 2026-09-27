//! Hud — what a frame shows besides the buffer (plain data + small helpers).
//!
//! The caller assembles it; the view renders it. Split out of `view.zig`
//! together with the caret shape, the per-buffer markdown styling handle, the
//! tab-strip datum, and the hover frame input. Re-exported by `view.zig`
//! so `view_mod.Hud` / `.CursorStyle` / `.MdInline` / `.Tab` are unchanged.

const std = @import("std");

const stemma = @import("stemma");
const core = @import("weft_core");
const region = @import("../region.zig");
const ui_mesh = @import("ui_mesh.zig");
const semantic_data = @import("semantic_data.zig");
const semantic_model = @import("weft_semantic");
const chrome = @import("chrome.zig");

const InlineAttr = core.capability.InlineAttr;

/// Caret shape. Configurable per mode by the host (vim: block in normal,
/// bar in insert). `block` covers the glyph (which flips to `cursor_text`);
/// `bar`/`underline` sit beside/under it and never recolor the glyph.
pub const CursorStyle = enum { block, bar, underline };

/// Where the caret draws relative to its selection, declared per mode like
/// the style. `head` (the default) draws at the head offset — one past the
/// last selected character of a forward selection, which is where typing
/// lands. `inside` draws ON that last character instead, so the caret never
/// leaves the selection: helix's cursor, where a selection always covers the
/// character under it. A caret, or a backward selection, draws at its head
/// either way.
pub const CaretPlace = enum { head, inside };

/// Per-byte markdown styling over a source window, published by the
/// markdown runtime and consumed here. `attrs[i]` styles byte `base + i`.
pub const MdInline = struct {
    base: usize,
    attrs: []const InlineAttr,

    pub fn at(self: MdInline, off: usize) InlineAttr {
        if (off < self.base or off - self.base >= self.attrs.len) return .{};
        return self.attrs[off - self.base];
    }
};

/// What the frame shows besides the buffer: mode, dirtiness, the composed
/// `ui/statusline-seg`/`ui/gutter-segment` mesh output, and the picker when
/// one is open. Plain data — the caller assembles it, the view renders it.
///
/// Every layer here is a `layers.Snapshot` taken when the frame's input was
/// (doc/model.md §2.7), never a live `Layer`: a span's offsets are the ones
/// that matched the snapshot's text, whatever the document did since.
pub const Hud = struct {
    mode: []const u8,
    /// Draw the pane's status line (the viewport's `status_line` attribute).
    status_line: bool = true,
    dirty: bool = false,
    save_failed: bool = false,
    /// Backing kind chip: "file" | "shell" | "tool" | "@shared" | null.
    backing: ?[]const u8 = null,
    /// Paint the shipped mark above a dashboard tool's projection.
    brand_mark: bool = false,
    /// Save progress chip: "saving…" | "save stale" | null.
    save_note: ?[]const u8 = null,
    /// Partial checkout: percent NOT yet fetched (0 = complete).
    unfetched_pct: ?u8 = null,
    /// Remote peers with presence in this buffer.
    peers: usize = 0,
    /// Transient `echo` message (wins the right-hand slot).
    echo: ?[]const u8 = null,
    /// A generic plugin-published status chip, PERSISTENT (unlike `echo`) —
    /// the same kind of slot as `echo`, one tier up in lifetime. The core knows
    /// nothing of what it says; a plugin publishes via `weft.status` (a task
    /// progress, a repl state, an agent's "waiting"). Null = no chip.
    plugin_status: ?[]const u8 = null,
    /// Rendering P2 (doc/rendering.md): a LEGACY/test-only path — production
    /// (`frame_builder.zig`) leaves this null and instead hands the picker's
    /// own `core.pick.Pick.buildSurface` scene through `surfaces` below, the
    /// same door a plugin's retained overlay uses. `View.build` still honors
    /// a non-null `pick` (building + drawing its surface itself) so a caller
    /// that constructs a `Hud` directly — `gfx/harness.zig`, the e2e
    /// harness's best-effort `.snapshot`, the popup-layout gate's own
    /// scenarios — doesn't have to route through `frame_builder` to render
    /// a pick.
    pick: ?*const core.Pick = null,
    /// The highlight feed layer (stamped bulk paint).
    highlight_layer: ?*const core.layers.Snapshot = null,
    /// The styles feed layer (plugin-published bulk paint over a tool buffer:
    /// class-per-byte StyleClass). Read the same way as `highlight_layer`;
    /// highlight wins where both exist (tool buffers have no grammar, so in
    /// practice they never collide).
    styles_layer: ?*const core.layers.Snapshot = null,
    /// The diagnostics feed layer (anchored spans, kind = severity).
    diag_layer: ?*const core.layers.Snapshot = null,
    /// Placed decorations (virtual_before text drawn beside the line, never in
    /// the document): files's metadata/arrow/mark, inlay hints, blame. Rendered
    /// as leading dimmed cells by the mono line layout.
    decorations_layer: ?*const core.layers.Snapshot = null,
    /// Third-party annotation feeds over this entry
    /// (doc/contextual-workspace-architecture.md §11.7), composited on top of
    /// the entry's own paint: `range` spans tint their bytes by role, placed
    /// spans draw beside the line. The presentation knows only the feed
    /// shape — never which plugin published one, or what it means.
    annotations: []const core.layers.Snapshot = &.{},
    /// Message of a diagnostic at the cursor, for the status line.
    cursor_diag: ?[]const u8 = null,
    /// Remote peers' cursors (replicated feed layer).
    presence_layer: ?*const core.layers.Snapshot = null,
    /// Peer trust chip: "✓ verified" | "⚠ unverified" | null (the host we
    /// connected out to; see known_peers / the SAS).
    trust: ?[]const u8 = null,
    /// The `ui/statusline-seg` mesh's composed output (doc/cwa-prior-docs-audit.md §5
    /// W3-1) — mode chip, buffer position, file/path, collab liveness (left
    /// cluster) and the diagnostics count (right-anchored) all come from
    /// here now; `statusline.zig` renders this list, it no longer formats
    /// those chips itself. Empty when the caller never fired the mesh (every
    /// pre-W3 test/harness call site) — those chips simply don't render,
    /// same as any other omitted Hud field.
    statusline_segs: []const ui_mesh.Seg = &.{},
    /// The `ui/gutter-segment` mesh, resolved ONCE for this frame (north-
    /// star-plan §6 W3-1) — null when nothing is bound (today's default: no
    /// visual gutter, unchanged). See `ui_mesh.zig`'s module doc for the
    /// "fire once per frame, invoke per visible row" shape.
    gutter: ?ui_mesh.GutterFrame = null,
    /// which-key: the current prefix mode's bindings, shown as a panel
    /// while a chord is pending (null when not in a menu mode).
    which_key: ?[]const core.Keymap.Binding = null,
    /// Open buffers for the top tab strip (null → no strip, one buffer).
    tabs: ?[]const Tab = null,
    /// Per-byte markdown styling for the active buffer (null = not md).
    md_inline: ?MdInline = null,
    /// vim-goggles: the byte ranges to flash this frame (a yanked region, every
    /// range one operation touched), drawn as a transient highlight. Empty
    /// when nothing is flashing.
    flash: []const stemma.Range = &.{},
    /// Rendering P2 (doc/rendering.md): LEGACY/test-only, like `pick` above
    /// — production hover is the `lsp` guest plugin's OWN `.caret` surface
    /// (through `wl_surface_caret`, landing in `surfaces` below via
    /// `frame_builder.zig`'s plugin-surface collection), so this field is
    /// always null there. `View.build` still turns a non-null value into a
    /// one-column caret surface (`popup.textCaretSurface`) for a caller
    /// that hands plain hover text straight to `Hud` without a live plugin.
    hover: ?struct { text: []const u8, offset: usize } = null,
    /// Caret shape and blink phase (false = hidden this frame).
    cursor_style: CursorStyle = .block,
    caret_place: CaretPlace = .head,
    cursor_on: bool = true,
    /// The focus is a ROW of a text projection, not a position in its text
    /// (`row` granularity, doc/chrome.md §5.2): the caret's line is washed
    /// as the focused row, and no caret is drawn — typing inserts nothing
    /// there, and a caret would say it does.
    row_focus: bool = false,
    /// Retained plugin overlays (which-key/files/git) to draw this frame.
    /// corner/center placements overlay the body; bottom is reserved for the
    /// dock (the picker/which-key path).
    surfaces: []const *const core.surface.Surface = &.{},
    /// A semantic tool document replaces the text projection in this pane.
    /// The renderer consumes nodes and generic fields; it does not know which
    /// plugin authored them or whether the interaction style is modal.
    semantic_view: ?semantic_data.Document = null,
    /// The active head-local interaction, rendered above the document. Local
    /// bindings are resolved by the interaction stack, not global which-key.
    semantic_overlay: ?semantic_data.Overlay = null,
    /// Where an overlay hung at a point (`pointer`, `caret`) may float: the
    /// whole frame, not this pane's body, so a menu opened over a narrow
    /// sidebar is not clipped to it. Null = the body.
    float_bounds: ?region.Rect = null,
    /// Which edges of this pane's frame are internal (shared with a
    /// neighbor) and get a 1px divider line. Empty for a single pane.
    pane_border: region.Edges = .{},
    /// What the pointer rests on in this pane (frame input; see `Hover`).
    pointer: Hover = .{},
    /// This build paints the frame's tooltip, whichever pane offered it —
    /// the pane built last, so the tooltip is above every pane. A caller
    /// building one pane leaves it on.
    tooltips: bool = true,
    /// Where a tooltip's key hint comes from — the shell's `keysFor`
    /// (doc/chrome.md §1.3). Null in a frame built without one: no hints.
    key_hints: ?chrome.KeyHints = null,

    pub const max_pick_rows = 8;
    pub const max_hover_rows = 16;
    /// The fallback panel should use a useful portion of a tall display;
    /// drawing code still clips it to the actual pane height.
    pub const max_wk_rows = 24;

    /// Rows the bottom panel (the host which-key fallback) needs ABOVE the
    /// status line — the single source of truth both the body reservation
    /// (`rows`) and the render use, so they cannot drift out of step. The picker
    /// no longer reserves: it is a window-bottom OVERLAY (vertico-style), drawn
    /// full-width over the panes so splits never shrink it.
    pub fn panelRows(self: *const Hud) usize {
        if (self.which_key) |wk| return 1 + @min(wk.len, max_wk_rows); // header + hints
        return 0;
    }

    /// Total bottom chrome rows the body must leave free: the status line
    /// plus any panel above it.
    pub fn rows(self: *const Hud) usize {
        return 1 + self.panelRows();
    }
};

/// One entry in the top buffer-tab strip. `id` is the entry it shows, so a
/// click on the tab can name it (`ChromeHit.entry`) without the view knowing
/// what a buffer is.
pub const Tab = struct {
    name: []const u8,
    active: bool,
    id: u32 = 0,
    /// What the tab's tooltip names: the entry's full path, where the tab
    /// shows only its base name.
    path: []const u8 = "",
};

/// The glyph a text-style tab closes through (a style that draws icons draws
/// the `close` icon instead).
pub const tab_close_glyph = "×";

/// Which part of a tab a point is on: its body, or its close glyph.
pub const TabPart = enum { body, close };

/// One clickable region of a pane's chrome, as last built: a tab's body or
/// close glyph, or a status segment. What a pointer on it resolves to
/// (`core.pointer.Chrome`); the view records these and knows nothing of what
/// a click on one does.
pub const ChromeHit = struct {
    rect: region.Rect,
    kind: Kind,
    /// Which tab (into `Hud.tabs`) or which segment (into
    /// `Hud.statusline_segs`).
    index: usize,
    part: TabPart = .body,
    /// The entry a tab shows.
    entry: ?u32 = null,
    /// The command a status segment declared for a click, or "".
    command: []const u8 = "",

    pub const Kind = enum { tab, status };
};

/// What the pointer rests on in this pane, as the frame's INPUT (doc/model.md
/// §2.7): hover is not a command and dispatches nothing — the frame reads it,
/// as it reads the caret. The app layer derives it from the last frame's hit
/// geometry (`app/pointer.zig`) and marks the frame dirty only when the
/// TARGET changes, so moving the pointer within a button costs no frame.
pub const Hover = struct {
    /// The pointer in framebuffer pixels; null when it is not over this pane.
    at: ?[2]f32 = null,
    /// The chrome part under it.
    chrome: ?struct { kind: ChromeHit.Kind, index: usize, part: TabPart } = null,
    /// The scene node under it.
    node: ?struct { view: semantic_model.view.Ref, node: semantic_model.scene.NodeId } = null,
    /// A button is held down on this same target: it reads as pressed.
    pressed: bool = false,
    /// The pointer has rested on the target past the tooltip delay.
    tooltip: bool = false,

    pub fn onChrome(self: Hover, kind: ChromeHit.Kind, index: usize, part: TabPart) bool {
        const c = self.chrome orelse return false;
        return c.kind == kind and c.index == index and c.part == part;
    }

    pub fn onNode(self: Hover, view: semantic_model.view.Ref, node: semantic_model.scene.NodeId) bool {
        const n = self.node orelse return false;
        return n.node == node and n.view.eql(view);
    }
};

const testing = std.testing;

test "hud: the panel reserves exactly what it renders (no status overlap)" {
    // The bug this guards: `rows()` (body reservation) and the panel render
    // computed offsets independently and drifted, so which-key's last hint
    // landed on the status row. Both now derive from `panelRows()`.
    const hints = [_]core.Keymap.Binding{
        .{ .key = "f", .command = "files.find" },
        .{ .key = "c", .command = "collab" },
        .{ .key = "space", .command = "palette.open" },
    };
    const hud: Hud = .{ .mode = "leader", .which_key = &hints };
    try testing.expectEqual(@as(usize, 4), hud.panelRows()); // header + 3 hints
    try testing.expectEqual(@as(usize, 5), hud.rows()); // + the status line

    // For any frame tall enough, the panel's last row is strictly above the
    // status row — the render places header at panel_top and hints below it.
    const rows_total: usize = 20;
    const panel_top = rows_total - 1 - hud.panelRows();
    const last_panel_row = panel_top + hud.panelRows() - 1; // header + hints
    try testing.expect(last_panel_row < rows_total - 1); // never the status row
    // And the body reservation leaves the panel_top clear of the body.
    try testing.expectEqual(panel_top, rows_total - hud.rows());
}
