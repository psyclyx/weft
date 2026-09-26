//! Hud — what a frame shows besides the buffer (plain data + small helpers).
//!
//! The caller assembles it; the view renders it. Split out of `view.zig`
//! together with the caret shape, the per-buffer markdown styling handle, the
//! tab-strip datum, and the pure tab-strip builder. Re-exported by `view.zig`
//! so `view_mod.Hud` / `.CursorStyle` / `.MdInline` / `.Tab` are unchanged.

const std = @import("std");

const stemma = @import("stemma");
const core = @import("weft_core");
const region = @import("../region.zig");
const ui_mesh = @import("ui_mesh.zig");
const semantic_data = @import("semantic_data.zig");

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
    highlight_layer: ?*const core.layers.Layer = null,
    /// The styles feed layer (plugin-published bulk paint over a tool buffer:
    /// class-per-byte StyleClass). Read the same way as `highlight_layer`;
    /// highlight wins where both exist (tool buffers have no grammar, so in
    /// practice they never collide).
    styles_layer: ?*const core.layers.Layer = null,
    /// The diagnostics feed layer (anchored spans, kind = severity).
    diag_layer: ?*const core.layers.Layer = null,
    /// Placed decorations (virtual_before text drawn beside the line, never in
    /// the document): files's metadata/arrow/mark, inlay hints, blame. Rendered
    /// as leading dimmed cells by the mono line layout.
    decorations_layer: ?*const core.layers.Layer = null,
    /// Third-party annotation feeds over this entry
    /// (doc/contextual-workspace-architecture.md §11.7), composited on top of
    /// the entry's own paint: `range` spans tint their bytes by role, placed
    /// spans draw beside the line. The presentation knows only the feed
    /// shape — never which plugin published one, or what it means.
    annotations: []const *const core.layers.Layer = &.{},
    /// Message of a diagnostic at the cursor, for the status line.
    cursor_diag: ?[]const u8 = null,
    /// Remote peers' cursors (replicated feed layer).
    presence_layer: ?*const core.layers.Layer = null,
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
    /// Which edges of this pane's frame are internal (shared with a
    /// neighbor) and get a 1px divider line. Empty for a single pane.
    pane_border: region.Edges = .{},

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
/// click on the tab can name it (`TabPart`) without the view knowing what a
/// buffer is.
pub const Tab = struct { name: []const u8, active: bool, id: u32 = 0 };

/// The glyph after each tab name that a click closes the tab through.
pub const tab_close_glyph = "×";

/// Where one clickable part of the tab strip sits, in columns of the strip
/// text: which tab (`index` into the `tabs` it was built from), and whether
/// it is the tab's body or its close glyph. The view turns these into hit
/// rects.
pub const TabPart = struct {
    index: usize,
    part: Part,
    col: usize,
    cols: usize,

    pub const Part = enum { body, close };
};

/// Build the tab strip text into `buf`: the active buffer bracketed, others
/// plain, each followed by the close glyph, separated by " │ ". Whole parts
/// only, so the result is always valid UTF-8 (the view truncates it to the
/// column width when it renders — `appendPlainRun` stops at `cols_visible`
/// codepoints). Pure; the geometry (which row) is the view's.
pub fn buildTabStrip(buf: []u8, tabs: []const Tab) []const u8 {
    return buildTabStripParts(buf, tabs, &.{}).text;
}

pub const TabStrip = struct { text: []const u8, parts: []const TabPart };

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
    part: TabPart.Part = .body,
    /// The entry a tab shows.
    entry: ?u32 = null,
    /// The command a status segment declared for a click, or "".
    command: []const u8 = "",

    pub const Kind = enum { tab, status };
};

/// `buildTabStrip`, also reporting where each tab's body and close glyph
/// landed (as many as fit in `parts`). A part is reported only once the
/// whole of it was written.
pub fn buildTabStripParts(buf: []u8, tabs: []const Tab, parts: []TabPart) TabStrip {
    var w: usize = 0;
    var col: usize = 0;
    var n: usize = 0;
    const put = struct {
        fn part(b: []u8, at: *usize, c: *usize, s: []const u8) bool {
            if (at.* + s.len > b.len) return false; // whole part or nothing
            @memcpy(b[at.* .. at.* + s.len], s);
            at.* += s.len;
            c.* += std.unicode.utf8CountCodepoints(s) catch s.len;
            return true;
        }
    }.part;
    for (tabs, 0..) |tabinfo, i| {
        if (!put(buf, &w, &col, if (i == 0) " " else " │ ")) break;
        const body_col = col;
        if (tabinfo.active and !put(buf, &w, &col, "[")) break;
        if (!put(buf, &w, &col, tabinfo.name)) break;
        if (tabinfo.active and !put(buf, &w, &col, "]")) break;
        if (n < parts.len) {
            parts[n] = .{ .index = i, .part = .body, .col = body_col, .cols = col - body_col };
            n += 1;
        }
        if (!put(buf, &w, &col, " ")) break;
        const close_col = col;
        if (!put(buf, &w, &col, tab_close_glyph)) break;
        if (n < parts.len) {
            parts[n] = .{ .index = i, .part = .close, .col = close_col, .cols = col - close_col };
            n += 1;
        }
    }
    return .{ .text = buf[0..w], .parts = parts[0..n] };
}

const testing = std.testing;

test "hud: the panel reserves exactly what it renders (no status overlap)" {
    // The bug this guards: `rows()` (body reservation) and the panel render
    // computed offsets independently and drifted, so which-key's last hint
    // landed on the status row. Both now derive from `panelRows()`.
    const hints = [_]core.Keymap.Binding{
        .{ .key = "f", .command = "find-file" },
        .{ .key = "c", .command = "collab" },
        .{ .key = "space", .command = "palette" },
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

test "buildTabStrip: active bracketed, a close glyph each, separated, truncated to width" {
    const tabs = [_]Tab{
        .{ .name = "a.zig", .active = false },
        .{ .name = "b.md", .active = true },
        .{ .name = "c.txt", .active = false },
    };
    var buf: [128]u8 = undefined;
    try testing.expectEqualStrings(" a.zig × │ [b.md] × │ c.txt ×", buildTabStrip(&buf, &tabs));
    // A tight buffer stops on whole parts — always valid UTF-8, never a
    // split codepoint (the two-byte glyph did not fit, so it is not there).
    var tiny: [8]u8 = undefined;
    const short = buildTabStrip(&tiny, &tabs);
    try testing.expectEqualStrings(" a.zig ", short);
    try testing.expect(std.unicode.utf8ValidateSlice(short));
}

test "buildTabStripParts: each tab's body and close glyph, in columns" {
    const tabs = [_]Tab{
        .{ .name = "a.zig", .active = false, .id = 4 },
        .{ .name = "b.md", .active = true, .id = 9 },
    };
    var buf: [128]u8 = undefined;
    var parts: [8]TabPart = undefined;
    const strip = buildTabStripParts(&buf, &tabs, &parts);
    try testing.expectEqualStrings(" a.zig × │ [b.md] ×", strip.text);
    try testing.expectEqual(@as(usize, 4), strip.parts.len);
    // " a.zig" — the body is columns 1..5, the glyph column 7.
    try testing.expectEqual(TabPart{ .index = 0, .part = .body, .col = 1, .cols = 5 }, strip.parts[0]);
    try testing.expectEqual(TabPart{ .index = 0, .part = .close, .col = 7, .cols = 1 }, strip.parts[1]);
    // " │ " is three columns, so the second body starts at 11; brackets count.
    try testing.expectEqual(TabPart{ .index = 1, .part = .body, .col = 11, .cols = 6 }, strip.parts[2]);
    try testing.expectEqual(TabPart{ .index = 1, .part = .close, .col = 18, .cols = 1 }, strip.parts[3]);
}
