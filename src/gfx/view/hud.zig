//! Hud — what a frame shows besides the buffer (plain data + small helpers).
//!
//! The caller assembles it; the view renders it. Split out of `view.zig`
//! together with the caret shape, the per-buffer markdown styling handle, the
//! tab-strip datum, and the pure tab-strip builder. Re-exported by `view.zig`
//! so `view_mod.Hud` / `.CursorStyle` / `.MdInline` / `.Tab` are unchanged.

const std = @import("std");

const stemma = @import("stemma");
const core = @import("../../core/core.zig");
const region = @import("../region.zig");
const ui_mesh = @import("ui_mesh.zig");
const semantic_data = @import("semantic_data.zig");

const InlineAttr = core.capability.InlineAttr;

/// Caret shape. Configurable per mode by the host (vim: block in normal,
/// bar in insert). `block` covers the glyph (which flips to `cursor_text`);
/// `bar`/`underline` sit beside/under it and never recolor the glyph.
pub const CursorStyle = enum { block, bar, underline };

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
    dirty: bool = false,
    save_failed: bool = false,
    /// Backing kind chip: "file" | "shell" | "tool" | "@shared" | null.
    backing: ?[]const u8 = null,
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
    /// vim-goggles: a byte range to flash this frame (e.g. a yanked region),
    /// drawn as a transient highlight. Null when nothing is flashing.
    flash: ?stemma.Range = null,
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
    pub const max_wk_rows = 10;

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

/// One entry in the top buffer-tab strip.
pub const Tab = struct { name: []const u8, active: bool };

/// Build the tab strip text into `buf`: the active buffer bracketed,
/// others plain, separated by " │ ". Whole parts only, so the result is
/// always valid UTF-8 (the view truncates it to the column width when it
/// renders — `appendPlainRun` stops at `cols_visible` codepoints). Pure;
/// the geometry (which row) is the view's.
pub fn buildTabStrip(buf: []u8, tabs: []const Tab) []const u8 {
    var w: usize = 0;
    const put = struct {
        fn part(b: []u8, at: usize, s: []const u8) ?usize {
            if (at + s.len > b.len) return null; // whole part or nothing
            @memcpy(b[at .. at + s.len], s);
            return at + s.len;
        }
    }.part;
    var first = true;
    for (tabs) |tabinfo| {
        w = put(buf, w, if (first) " " else " │ ") orelse return buf[0..w];
        first = false;
        if (tabinfo.active) w = put(buf, w, "[") orelse return buf[0..w];
        w = put(buf, w, tabinfo.name) orelse return buf[0..w];
        if (tabinfo.active) w = put(buf, w, "]") orelse return buf[0..w];
    }
    return buf[0..w];
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

test "buildTabStrip: active bracketed, separated, truncated to width" {
    const tabs = [_]Tab{
        .{ .name = "a.zig", .active = false },
        .{ .name = "b.md", .active = true },
        .{ .name = "c.txt", .active = false },
    };
    var buf: [128]u8 = undefined;
    try testing.expectEqualStrings(" a.zig │ [b.md] │ c.txt", buildTabStrip(&buf, &tabs));
    // A tight buffer stops on whole parts — always valid UTF-8, never a
    // split codepoint.
    var tiny: [7]u8 = undefined;
    const short = buildTabStrip(&tiny, &tabs);
    try testing.expectEqualStrings(" a.zig", short);
    try testing.expect(std.unicode.utf8ValidateSlice(short));
}
