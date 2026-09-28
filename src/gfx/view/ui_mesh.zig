//! ui_mesh — the UI mesh's first two ordered-union slots, `ui/statusline-seg`
//! and `ui/gutter-segment` (doc/contextual-workspace-architecture.md §11;
//! doc/rendering.md "The UI as a mesh of narrow capabilities"). Host-side
//! PROVIDERS re-express today's statusline chips (and, inertly until bound,
//! gutter marks) as `core.container.Container` bindings instead of code baked
//! directly into `statusline.zig`/`frame_builder.zig` — proving the mesh's
//! composition machinery (declare/bind/eligible/unbind, strict-weak-order
//! priority, swap-one-piece) on real UI before P2 opens any slot to a guest.
//!
//! **Two interfaces settled here** (reported in the W3-1 writeup):
//!
//!   - `ui/statusline-seg`: `(Facts, StatuslineArgs) -> a Seg`, fired ONCE
//!     per HUD build (`fireStatusline`) — cheap (a handful of providers),
//!     matches doc/rendering.md's `(editor state) -> a span group`.
//!   - `ui/gutter-segment`: `(line, Facts) -> zero-or-more Segs`, fired in
//!     TWO steps per frame: `gutterBindings` resolves the eligible,
//!     priority-sorted provider list ONCE (an ordinary `Container.eligible`
//!     call — O(bound bindings), empty and therefore ~free while nothing is
//!     bound), then `gutterCellsForLine` re-walks that ALREADY-SORTED list
//!     once per VISIBLE row. This is the "fire once per frame for the
//!     visible range, return per-line cells" shape doc/rendering.md's
//!     `(line, facts) -> gutter cells` implies is a hot path: no repeated
//!     Container scan per line, only a (cheap) fn-pointer call per
//!     (visible line × eligible provider) pair — see the W3-1 report for
//!     the full per-frame cost reasoning.
//!
//! `Seg` is the shared "narrow waist" output BOTH slots emit (reusing
//! `core.surface.Role`, per doc/rendering.md's scene-vocabulary argument),
//! plus two small, NAMED escape hatches (`fg_override`/`bg_override`)
//! documented on the type itself: a chip's background (the mode chip's
//! colour is its declared TONE's, `Theme.modeChipColor`; a save warning's is
//! a diagnostic colour) and the gutter's marks. The status line's third user
//! of the diagnostic colours — the problems counts a plugin publishes — is
//! what taught `Role` them for real (`warning`, `danger`).
//!
//! **Provider shape.** Every default provider here is a plain Zig function
//! wrapped as a `container.ProviderRef.ui_provider` — the in-process
//! transport's PREVIEW of D2's future schema-directed guest payloads (see
//! that variant's doc in `container.zig`). `declareSlots` declares both
//! slots; `bindDefaultStatusline` binds the five statusline providers at
//! `.core` tier (always present, lowest tier, so a config/plugin binding at
//! `.plugin`/`.config` tier outranks it for free); `bindDefaultGutter` binds
//! the three gutter providers the SAME way but is NOT called by
//! `Session.init` — the gutter slot is declared but left unbound in the
//! live app, because there is no existing gutter rendering to reproduce
//! (nothing regresses by construction) — see the W3-1 report for why this
//! is the honest, minimal-risk shape for a first slice.
//!
//! **Plugins bind the gutter too.** `ui/gutter-segment` is declared with a
//! schema (`core.gutter`), so a guest binds it with `wl_slot_bind` like any
//! slot. Its binding is a `.schema_provider`, and `gutterCellsForLine` reads
//! its cell from a `GutterBatch`: one answer covers a WINDOW of lines, asked
//! for between frames (`app/answers.zig`, doc/model.md §2.7) — one membrane
//! crossing per window, never one per row, and never one during layout. The
//! `linenumbers` plugin is the live provider. A plugin's status segments are
//! read the same way (`StatuslineArgs.plugin_answers`).

const std = @import("std");
const Allocator = std.mem.Allocator;
const stemma = @import("stemma");
const core = @import("weft_core");
const container = core.container;
const Facts = container.Facts;
const Theme = @import("Theme.zig");
const status_layout = @import("status_layout.zig");

/// A composed segment — the shared output vocabulary for both slots.
pub const Seg = struct {
    /// Owned by whatever allocator the firing call was given (a per-frame
    /// arena in production; the caller's `gpa` in a test — see `freeSegs`).
    text: []const u8,
    /// The short form the status line falls back to when the row is short
    /// (`Ln 12, Col 4` → `12:4`), or "" for none. Owned like `text`.
    compact: []const u8 = "",
    role: core.surface.Role = .normal,
    /// Escape hatch: a colour with no `Role` — the dirty mark's, a gutter
    /// mark's (`diag_error`/`diag_warn`).
    fg_override: ?[4]f32 = null,
    /// A chip: the segment is a label on its own background (the mode chip,
    /// a save warning) — `Theme.modeChipColor` and the diagnostic colours
    /// have no `Role` analogue.
    bg_override: ?[4]f32 = null,
    /// The right-hand cluster (measured back from the row's end) vs the
    /// left-hand one. Mirrors `core.surface.Span.column`'s alignment-tag
    /// convention (0 = main, 1 = other) rather than inventing a new one.
    align_right: bool = false,
    /// Who keeps its room when the row is short (`status_layout`): a lower
    /// priority shrinks to `compact`, then goes, first. Not the binding's
    /// priority, which only ORDERS segments along the row.
    priority: i32 = default_priority,
    /// Whether text too long for the room is cut short with `…`, and at
    /// which end, instead of the segment going whole.
    elide: status_layout.Elide = .none,
    /// The command a click on the segment runs, or "" (not clickable).
    /// BORROWED — a manifest decl's, or a plugin answer's in the frame
    /// arena — so `freeSegs` leaves it alone.
    command: []const u8 = "",
    /// An icon name (the theme's set) a chrome style that shows icons
    /// draws: in place of the text's leading glyph when that glyph stands
    /// alone (`● `, `✦ 2`), else before the text. BORROWED, like `command`.
    icon: []const u8 = "",
    /// What the segment's tooltip says; its command when empty. BORROWED.
    tooltip: []const u8 = "",
    /// A fact about ONE pane's entry among its neighbours — where it stands
    /// in the open list, what backs it — that reads on that pane's own line,
    /// never on a bar presenting a context to the whole window.
    pane_only: bool = false,

    /// A segment that says nothing of its importance sits in the middle.
    pub const default_priority = 50;
};

pub fn freeSegs(gpa: Allocator, segs: []const Seg) void {
    for (segs) |s| {
        gpa.free(s.text);
        gpa.free(s.compact);
    }
    gpa.free(segs);
}

// ── ui/statusline-seg ──────────────────────────────────────────────

/// Per-HUD-build input a statusline provider reads: the facts of the pane's
/// context and what the frame knows about its entry. `frame_builder` fills
/// it; a field left at its default is a segment that opts out.
pub const StatuslineArgs = struct {
    facts: Facts,
    theme: *const Theme,
    /// The pane's mode as its grammar names it (`Keymap.modeDisplay`), or
    /// null: no chip — a modeless grammar names none.
    mode: ?core.Keymap.ModeDisplay = null,
    /// The place the entry is in, by name.
    place: ?Place = null,
    /// The entry's path (place-relative) or name.
    file: []const u8 = "",
    doc: Doc = .{},
    /// The caret, for a text entry.
    caret: ?Caret = null,
    /// What the HEAD says, not the entry — its messages, its connection.
    /// Only the status line the head is looking at carries them: the
    /// focused pane's, and a bar presenting the primary context's.
    head: ?Head = null,
    /// What the PLUGIN providers last said for this pane
    /// (`app/answers.zig`), possibly to an older question: a frame never asks
    /// a guest itself. Empty means a `.schema_provider` binding contributes
    /// nothing this frame.
    plugin_answers: []const StatuslineAnswer = &.{},
    /// The line is a BAR — a row presenting a context (`status_projection`),
    /// not a pane's own line: `pane_only` segments stay off it.
    bar: bool = false,
    /// Set by `fireStatusline` when an eligible binding is a plugin's — the
    /// caller then knows this pane's status is a question worth asking.
    plugin_reached: bool = false,
    /// Set by `fireStatusline` itself before invoking providers — a caller
    /// building `StatuslineArgs` need not (and should not) set this.
    out: *std.ArrayList(Seg) = undefined,

    pub const Place = struct {
        name: []const u8,
        /// `folder` for a project here, `users` for a peer's, `terminal` for
        /// a shell's.
        icon: []const u8,
    };

    /// What the entry's text is doing.
    pub const Doc = struct {
        dirty: bool = false,
        save_failed: bool = false,
        /// "saving…" | "save stale" | null.
        save_note: ?[]const u8 = null,
        /// A partial checkout's share NOT yet fetched.
        unfetched_pct: ?u8 = null,
        /// Remote peers with presence in the entry.
        peers: usize = 0,
    };

    /// 1-based line and column (in characters), and how many selections.
    pub const Caret = struct { line: usize, col: usize, selections: usize = 1 };

    pub const Head = struct {
        /// "3/7": the entry's place among the open ones.
        buffer_pos: ?[]const u8 = null,
        /// Backing kind: "file" | "tool" | "@shared" | a remote's label.
        backing: ?[]const u8 = null,
        /// How the entry's place, or the connection, is reachable.
        link: ?[]const u8 = null,
        /// The transient echo, else the diagnostic under the caret.
        echo: ?[]const u8 = null,
        /// The persistent plugin-published chip (`core.status_feed`).
        feed: ?[]const u8 = null,
        /// The system's last notice, while it is brief (`status_feed.Notices`).
        notice: ?[]const u8 = null,
        /// The trust chip for the host we connected out to.
        trust: ?[]const u8 = null,
    };
};

/// One plugin provider's segments, by the binding owner the slot host names
/// it by: a decoded `core.status_segment` answer.
pub const StatuslineAnswer = struct { owner: []const u8, segs: []const Seg };

/// Decode one provider's `core.status_segment` answer into `Seg`s owned by
/// `gpa` (every string). A malformed answer says nothing.
pub fn decodeStatuslineAnswer(gpa: Allocator, owner: []const u8, payload: []const u8) !StatuslineAnswer {
    var segs: std.ArrayList(Seg) = .empty;
    if (core.status_segment.decodeTell(payload)) |told| {
        var tell = told;
        while (tell.next()) |s| {
            if (segs.items.len >= core.status_segment.max_segments) break;
            if (s.text.len == 0) continue;
            try segs.append(gpa, .{
                .text = try gpa.dupe(u8, s.text),
                .compact = try gpa.dupe(u8, s.compact),
                .role = core.surface.Role.fromInt(s.role),
                .align_right = s.right,
                .priority = std.math.cast(i32, s.priority) orelse Seg.default_priority,
                .command = try gpa.dupe(u8, s.command),
                .icon = try gpa.dupe(u8, s.icon),
                .tooltip = try gpa.dupe(u8, s.tooltip),
            });
        }
    }
    return .{ .owner = try gpa.dupe(u8, owner), .segs = segs.items };
}

fn argsOf(raw: *anyopaque) *StatuslineArgs {
    return @ptrCast(@alignCast(raw));
}

fn modeChipProvider(_: ?*anyopaque, gpa: Allocator, raw: *anyopaque) anyerror!bool {
    const a = argsOf(raw);
    const mode = a.mode orelse return false;
    try a.out.append(gpa, .{
        .text = try gpa.dupe(u8, mode.name),
        .fg_override = a.theme.background,
        .bg_override = a.theme.modeChipColor(mode.tone),
        .priority = 100,
    });
    return true;
}

fn placeProvider(_: ?*anyopaque, gpa: Allocator, raw: *anyopaque) anyerror!bool {
    const a = argsOf(raw);
    const place = a.place orelse return false;
    try a.out.append(gpa, .{ .text = try gpa.dupe(u8, place.name), .role = .muted, .priority = 40, .icon = place.icon });
    return true;
}

fn filePathProvider(_: ?*anyopaque, gpa: Allocator, raw: *anyopaque) anyerror!bool {
    const a = argsOf(raw);
    const file = if (a.file.len > 0) a.file else "[scratch]";
    // The path, cut from its start when the room is short (its tail names
    // it); its compact form is the file's own name.
    const base = std.fs.path.basename(file);
    try a.out.append(gpa, .{
        .text = try gpa.dupe(u8, file),
        .compact = if (base.len < file.len) try gpa.dupe(u8, base) else "",
        .priority = 80,
        .elide = .start,
    });
    // Modified: its own mark, right after the name it is about.
    if (a.doc.dirty) try a.out.append(gpa, .{ .text = try gpa.dupe(u8, "●"), .role = .warning, .priority = 92, .icon = "dot", .tooltip = "Modified" });
    return true;
}

/// The save and the checkout, when either needs saying: chips, a label on its
/// own colour.
fn docStateProvider(_: ?*anyopaque, gpa: Allocator, raw: *anyopaque) anyerror!bool {
    const a = argsOf(raw);
    const d = a.doc;
    var any = false;
    if (d.save_note) |note| {
        try a.out.append(gpa, .{ .text = try gpa.dupe(u8, note), .fg_override = a.theme.background, .bg_override = a.theme.diag_warn, .priority = 94 });
        any = true;
    }
    if (d.save_failed) {
        try a.out.append(gpa, .{ .text = try gpa.dupe(u8, "save failed"), .fg_override = a.theme.background, .bg_override = a.theme.diag_error, .priority = 96 });
        any = true;
    }
    if (d.unfetched_pct) |pct| if (pct > 0) {
        try a.out.append(gpa, .{
            .text = try std.fmt.allocPrint(gpa, "{d}% fetched", .{100 - @as(u32, pct)}),
            .compact = try std.fmt.allocPrint(gpa, "{d}%", .{100 - @as(u32, pct)}),
            .fg_override = a.theme.background,
            .bg_override = a.theme.diag_warn,
            .priority = 60,
        });
        any = true;
    };
    return any;
}

fn bufferPosProvider(_: ?*anyopaque, gpa: Allocator, raw: *anyopaque) anyerror!bool {
    const a = argsOf(raw);
    const bp = (a.head orelse return false).buffer_pos orelse return false;
    try a.out.append(gpa, .{ .text = try gpa.dupe(u8, bp), .role = .muted, .priority = 15, .tooltip = "Open entries", .pane_only = true });
    return true;
}

fn backingProvider(_: ?*anyopaque, gpa: Allocator, raw: *anyopaque) anyerror!bool {
    const a = argsOf(raw);
    const b = (a.head orelse return false).backing orelse return false;
    try a.out.append(gpa, .{ .text = try std.fmt.allocPrint(gpa, "({s})", .{b}), .role = .muted, .priority = 10, .pane_only = true });
    return true;
}

fn trustProvider(_: ?*anyopaque, gpa: Allocator, raw: *anyopaque) anyerror!bool {
    const a = argsOf(raw);
    const tr = (a.head orelse return false).trust orelse return false;
    try a.out.append(gpa, .{ .text = try gpa.dupe(u8, tr), .role = .muted, .priority = 55, .icon = "shield-check" });
    return true;
}

/// The head's message: the echo, else the diagnostic under the caret. Worth
/// a lot of room, and cut short rather than lost.
fn echoProvider(_: ?*anyopaque, gpa: Allocator, raw: *anyopaque) anyerror!bool {
    const a = argsOf(raw);
    const msg = (a.head orelse return false).echo orelse return false;
    if (msg.len == 0) return false;
    try a.out.append(gpa, .{ .text = try gpa.dupe(u8, msg), .priority = 88, .elide = .end });
    return true;
}

/// What no head asked to hear — a background echo, a refusal — while it is
/// brief. A message of its own, beside the head's and the plugin chip.
fn noticeProvider(_: ?*anyopaque, gpa: Allocator, raw: *anyopaque) anyerror!bool {
    const a = argsOf(raw);
    const msg = (a.head orelse return false).notice orelse return false;
    if (msg.len == 0) return false;
    try a.out.append(gpa, .{ .text = try gpa.dupe(u8, msg), .role = .muted, .priority = 58, .elide = .end });
    return true;
}

/// Where the caret is: `Ln 12, Col 4`. A click goes to a line.
fn positionProvider(_: ?*anyopaque, gpa: Allocator, raw: *anyopaque) anyerror!bool {
    const a = argsOf(raw);
    const c = a.caret orelse return false;
    try a.out.append(gpa, .{
        .text = try std.fmt.allocPrint(gpa, "Ln {d}, Col {d}", .{ c.line, c.col }),
        .compact = try std.fmt.allocPrint(gpa, "{d}:{d}", .{ c.line, c.col }),
        .align_right = true,
        .priority = 85,
        .command = go_to_line,
        .tooltip = "Go to Line",
    });
    return true;
}

/// The command a click on the position runs (core's, so every grammar has it).
pub const go_to_line = "jump.line";

fn selectionsProvider(_: ?*anyopaque, gpa: Allocator, raw: *anyopaque) anyerror!bool {
    const a = argsOf(raw);
    const c = a.caret orelse return false;
    if (c.selections < 2) return false;
    try a.out.append(gpa, .{
        .text = try std.fmt.allocPrint(gpa, "{d} selections", .{c.selections}),
        .compact = try std.fmt.allocPrint(gpa, "{d} sel", .{c.selections}),
        .role = .accent,
        .align_right = true,
        .priority = 45,
    });
    return true;
}

/// The entry's language, as the `lang` fact names it.
fn languageProvider(_: ?*anyopaque, gpa: Allocator, raw: *anyopaque) anyerror!bool {
    const a = argsOf(raw);
    if (a.facts.lang.len == 0 or a.caret == null) return false;
    try a.out.append(gpa, .{ .text = try gpa.dupe(u8, a.facts.lang), .role = .muted, .align_right = true, .priority = 35, .tooltip = "Language" });
    return true;
}

/// How the entry's place, or the collaboration connection, is reachable.
fn linkProvider(_: ?*anyopaque, gpa: Allocator, raw: *anyopaque) anyerror!bool {
    const a = argsOf(raw);
    const l = (a.head orelse return false).link orelse return false;
    try a.out.append(gpa, .{ .text = try gpa.dupe(u8, l), .role = .effect, .align_right = true, .priority = 70, .icon = "network", .elide = .end });
    return true;
}

fn peersProvider(_: ?*anyopaque, gpa: Allocator, raw: *anyopaque) anyerror!bool {
    const a = argsOf(raw);
    if (a.doc.peers == 0) return false;
    try a.out.append(gpa, .{ .text = try std.fmt.allocPrint(gpa, "✦ {d}", .{a.doc.peers}), .role = .accent, .align_right = true, .priority = 50, .icon = "users", .tooltip = "Peers here" });
    return true;
}

/// A plugin's persistent chip (`weft.status`): a task's progress, an agent
/// waiting.
fn feedProvider(_: ?*anyopaque, gpa: Allocator, raw: *anyopaque) anyerror!bool {
    const a = argsOf(raw);
    const st = (a.head orelse return false).feed orelse return false;
    try a.out.append(gpa, .{ .text = try gpa.dupe(u8, st), .role = .accent, .align_right = true, .priority = 60, .icon = "bell", .elide = .end });
    return true;
}

/// Fire `ui/statusline-seg`: resolve the eligible, priority-sorted provider
/// list against `args.facts` and invoke each in order, collecting whatever
/// segments they contribute (a provider that opts out — e.g. no caret —
/// contributes nothing, not an empty segment). Caller owns the returned
/// slice AND every segment's `text` and `compact` (`freeSegs`, or let a
/// per-frame arena reclaim them).
pub fn fireStatusline(c: *const container.Container, gpa: Allocator, args: *StatuslineArgs) ![]Seg {
    const bindings = try c.eligible(gpa, "ui/statusline-seg", args.facts);
    defer gpa.free(bindings);
    var out: std.ArrayList(Seg) = .empty;
    args.out = &out;
    for (bindings) |b| {
        switch (b.provider) {
            .ui_provider => |up| _ = up.call(up.ctx, gpa, @ptrCast(args)) catch |err| {
                std.log.warn("ui_mesh: statusline provider '{s}' failed: {s}", .{ b.owner, @errorName(err) });
                continue;
            },
            // A plugin: its segments are its last answer, in the priority
            // position its binding holds (text copied like every segment's,
            // the rest borrowed like every segment's).
            .schema_provider => |ref| {
                args.plugin_reached = true;
                for (args.plugin_answers) |ans| {
                    if (!std.mem.eql(u8, ans.owner, ref.owner)) continue;
                    for (ans.segs) |s| {
                        var copy = s;
                        copy.text = try gpa.dupe(u8, s.text);
                        copy.compact = try gpa.dupe(u8, s.compact);
                        try out.append(gpa, copy);
                    }
                    break;
                }
            },
            else => {},
        }
    }
    // Where the line is placed decides what reads on it, by each segment's
    // own say — never by which config drew the bar.
    if (args.bar) {
        var kept: usize = 0;
        for (out.items) |s| {
            if (s.pane_only) {
                gpa.free(s.text);
                gpa.free(s.compact);
                continue;
            }
            out.items[kept] = s;
            kept += 1;
        }
        out.items.len = kept;
    }
    return out.toOwnedSlice(gpa);
}
// ── ui/gutter-segment ──────────────────────────────────────────────

/// Per-visible-ROW input a gutter provider reads. `row` is this line's byte
/// range (`rope.lineRange(line)`); `diag_layer`/`bp_lines`/`caret_line`/
/// `line_count` are the SAME per-buffer values across every row this frame
/// (resolved once by the caller, not re-fetched per line). `line_count` is
/// what a fixed-width column pads to; `caret_line` is what a column relative
/// to the caret counts from.
pub const GutterLineArgs = struct {
    line: usize,
    row: stemma.Range,
    caret_line: usize = 0,
    line_count: usize = 0,
    diag_layer: ?*const core.layers.Snapshot = null,
    /// `breakpoints.get(path)`'s "l1,l2,…" CSV, or "" for none.
    bp_lines: []const u8 = "",
    theme: *const Theme,
    /// The PLUGIN providers' answers (`GutterFrame.batch`), a window at a
    /// time; null when the frame has none to offer.
    batch: ?*GutterBatch = null,
    /// Set by `gutterCellsForLine` itself before invoking providers.
    out: *std.ArrayList(Seg) = undefined,
};

/// Decimal digits in `n` (at least 1) — the width a numbered column pads to.
pub fn digits(n: usize) usize {
    var d: usize = 1;
    var v = n;
    while (v >= 10) : (v /= 10) d += 1;
    return d;
}

fn lineNumberProvider(_: ?*anyopaque, gpa: Allocator, raw: *anyopaque) anyerror!bool {
    const a: *GutterLineArgs = @ptrCast(@alignCast(raw));
    // Padded to the widest number in the entry, so every row's text starts in
    // the same column.
    const width = digits(@max(a.line_count, a.line + 1));
    const text = try std.fmt.allocPrint(gpa, "{d: >[1]} ", .{ a.line + 1, width });
    try a.out.append(gpa, .{ .text = text, .role = .muted });
    return true;
}

/// The worst (lowest `kind` — severity 1 = error per `layers.zig`'s
/// diagnostics convention) span overlapping this row, or none.
fn diagMarksProvider(_: ?*anyopaque, gpa: Allocator, raw: *anyopaque) anyerror!bool {
    const a: *GutterLineArgs = @ptrCast(@alignCast(raw));
    const dl = a.diag_layer orelse return false;
    var worst: ?u32 = null;
    for (0..dl.spanCount()) |i| {
        const s = dl.resolvedSpan(i);
        if (s.start >= a.row.end or s.end <= a.row.start) continue; // no overlap with this row
        if (worst == null or s.kind < worst.?) worst = s.kind;
    }
    const kind = worst orelse return false;
    const color = if (kind == 1) a.theme.diag_error else a.theme.diag_warn;
    try a.out.append(gpa, .{ .text = try gpa.dupe(u8, "\u{25B2} "), .fg_override = color });
    return true;
}

fn breakpointMarksProvider(_: ?*anyopaque, gpa: Allocator, raw: *anyopaque) anyerror!bool {
    const a: *GutterLineArgs = @ptrCast(@alignCast(raw));
    if (a.bp_lines.len == 0) return false;
    const target = a.line + 1; // breakpoints.zig lines are 1-based
    var it = std.mem.splitScalar(u8, a.bp_lines, ',');
    while (it.next()) |tok| {
        const trimmed = std.mem.trim(u8, tok, " ");
        const n = std.fmt.parseInt(usize, trimmed, 10) catch continue;
        if (n == target) {
            try a.out.append(gpa, .{ .text = try gpa.dupe(u8, "\u{25CF} "), .fg_override = a.theme.diag_error });
            return true;
        }
    }
    return false;
}

/// The per-frame result of resolving `ui/gutter-segment` once — what `Hud`
/// carries and `linelayout.zig` consumes per visible row. `bindings` is the
/// already-sorted eligible list (`gutterBindings`'s result); `diag_layer`/
/// `bp_lines` are this pane's buffer-scoped context, constant across every
/// row this frame.
pub const GutterFrame = struct {
    bindings: []const *const container.Binding,
    diag_layer: ?*const core.layers.Snapshot = null,
    bp_lines: []const u8 = "",
    caret_line: usize = 0,
    line_count: usize = 0,
    /// Where a PLUGIN provider's cells come from (`GutterBatch`). Null means
    /// only in-process providers answer — a `.schema_provider` binding is
    /// then skipped, exactly as before plugins could bind the slot.
    batch: ?*GutterBatch = null,
};

/// The plugin half of the gutter: what the pane's plugin providers last said,
/// a WINDOW of lines per answer (`core.gutter`), so a question crosses the
/// membrane once per window, never once per row — and never during layout:
/// the answers were asked for between frames (`app/answers.zig`), and the
/// layout only reads them.
///
/// Which lines are visible is still only known to the layout (it scrolls to
/// the caret and skips folded rows), so the layout is what notices a missing
/// answer: the first row with no answer to THIS frame's question is `wanted`,
/// the line the next question's window starts at. Until that answer lands,
/// the row shows the newest answer covering it, if any — at most a frame old.
pub const GutterBatch = struct {
    /// Every window the pane has an answer for, newest first.
    windows: []const Window,
    /// This frame's question (`app/answers.zig`'s `Key`): a window answered
    /// for another key is drawn but is not an answer to this frame.
    key: u64,
    /// The first line the layout reached without an answer to `key`, or null
    /// when every row it drew had one. Written while the layout reads, and
    /// read by the frame after it — the batch's one output.
    wanted: ?usize = null,
    /// The caret line of the snapshot this frame draws — what an answer that
    /// is a formula (`core.gutter.Rule`) is evaluated against, so a column
    /// counted from the caret is right on the frame the caret moved.
    caret_line: usize = 0,

    /// One answered window: lines `[first, first + core.gutter.window)` as of
    /// the question `key`.
    pub const Window = struct {
        key: u64,
        first: usize,
        answers: []const Answer,

        fn covers(self: Window, line: usize) bool {
            return line >= self.first and line - self.first < core.gutter.window;
        }
    };

    /// One provider's cells, by the binding owner the slot host names it by
    /// — or its formula, when it answered with one (`cells` is then empty).
    pub const Answer = struct {
        owner: []const u8,
        first: usize,
        cells: []const Seg,
        rule: ?core.gutter.Rule = null,
    };

    /// The window `line` reads from: the one answering this frame's question,
    /// else the newest covering it. Notes `line` as wanted when the first is
    /// missing.
    fn windowFor(self: *GutterBatch, line: usize) ?Window {
        var stale: ?Window = null;
        for (self.windows) |w| {
            if (!w.covers(line)) continue;
            if (w.key == self.key) return w;
            if (stale == null) stale = w;
        }
        if (self.wanted == null) self.wanted = line;
        return stale;
    }

    /// `owner`'s cell for `line`, or null when it said nothing there. A
    /// formula is evaluated here, against this frame's caret, into `gpa`.
    fn cell(self: *GutterBatch, gpa: Allocator, owner: []const u8, line: usize) !?Seg {
        const w = self.windowFor(line) orelse return null;
        for (w.answers) |ans| {
            if (!std.mem.eql(u8, ans.owner, owner)) continue;
            if (ans.rule) |rule| {
                const width: usize = @min(@max(rule.width, 1), 20);
                const on_caret = line == self.caret_line;
                return .{
                    .text = try std.fmt.allocPrint(gpa, "{d: >[1]} ", .{ rule.number(line, self.caret_line), width }),
                    .role = core.surface.Role.fromInt(if (on_caret) rule.caret_role else rule.role),
                };
            }
            if (line < ans.first or line - ans.first >= ans.cells.len) return null;
            const c = ans.cells[line - ans.first];
            return if (c.text.len == 0) null else .{ .text = try gpa.dupe(u8, c.text), .role = c.role };
        }
        return null;
    }
};

/// Decode one provider's `core.gutter` answer into `Seg`s owned by `gpa`. A
/// malformed answer says nothing.
pub fn decodeGutterAnswer(gpa: Allocator, owner: []const u8, payload: []const u8) !GutterBatch.Answer {
    if (core.gutter.decodeRule(payload)) |rule|
        return .{ .owner = try gpa.dupe(u8, owner), .first = 0, .cells = &.{}, .rule = rule };
    var cells: std.ArrayList(Seg) = .empty;
    var first: usize = 0;
    if (core.gutter.decodeTell(payload)) |told| {
        var tell = told;
        first = tell.first;
        while (tell.next()) |c| {
            if (cells.items.len >= core.gutter.window) break;
            try cells.append(gpa, .{ .text = try gpa.dupe(u8, c.text), .role = core.surface.Role.fromInt(c.role) });
        }
    }
    return .{ .owner = try gpa.dupe(u8, owner), .first = first, .cells = cells.items };
}

/// Resolve `ui/gutter-segment`'s eligible, priority-sorted provider list
/// against `facts` — the ONE Container scan per frame; caller reuses the
/// result across every visible row (and, in `frame_builder`, across every
/// pane) via `gutterCellsForLine`. `gpa.free` the result when done (a
/// per-frame arena needs no explicit free).
pub fn gutterBindings(c: *const container.Container, gpa: Allocator, facts: Facts) ![]const *const container.Binding {
    return c.eligible(gpa, "ui/gutter-segment", facts);
}

/// Invoke the ALREADY-RESOLVED `bindings` (from `gutterBindings`) for one
/// visible row — no Container scan here, just a fn-pointer call per eligible
/// provider. Empty `bindings` (nothing bound — today's default) returns an
/// empty slice immediately without a single provider call.
pub fn gutterCellsForLine(bindings: []const *const container.Binding, gpa: Allocator, args: *GutterLineArgs) ![]Seg {
    var out: std.ArrayList(Seg) = .empty;
    args.out = &out;
    if (bindings.len == 0) return out.toOwnedSlice(gpa);
    for (bindings) |b| {
        switch (b.provider) {
            .ui_provider => |up| _ = up.call(up.ctx, gpa, @ptrCast(args)) catch |err| {
                std.log.warn("ui_mesh: gutter provider '{s}' failed on line {d}: {s}", .{ b.owner, args.line, @errorName(err) });
                continue;
            },
            // A plugin: its cell comes from the window it last answered, in
            // the same priority position its binding holds.
            .schema_provider => |ref| {
                const batch = args.batch orelse continue;
                if (try batch.cell(gpa, ref.owner, args.line)) |c| try out.append(gpa, c);
            },
            else => {},
        }
    }
    return out.toOwnedSlice(gpa);
}

// ── Wiring + defaults (doc/rendering.md "Wiring + defaults") ──────────

pub fn declareSlots(c: *container.Container) !void {
    // Both declared WITH their schemas (`core.status_segment`, `core.gutter`),
    // so a plugin can bind either.
    try core.status_segment.declare(c);
    try core.gutter.declare(c);
}

/// Core's own status segments — what core KNOWS about a pane's context — at
/// `.core` tier (lowest), so a higher-tier binding on the same slot outranks
/// them (proven by the mesh test). The binding priorities are the order along
/// the row, and the gaps between them are where a plugin that binds `.core`
/// falls in among them: git's branch and the problems counts after the place
/// (96, 95), a running task (94), the breadcrumbs after the path (75), the
/// indentation among the right-hand facts (43).
///
///   left:  mode 100 · place 97 · path + modified 80 · save/fetch 74 ·
///          entry position 71 · backing 70 · trust 69 · message 60
///   right: Ln/Col 45 · selections 44 · language 40 · link 35 · peers 34 ·
///          plugin chip 30
///
/// What each segment shows when the row is short is its own `Seg.priority`
/// (`status_layout`), not this order.
///
/// **Reachability (doc/cwa-prior-docs-audit.md §5):** two paths reach this
/// Container now. (1) The shared-Container fold-in: `action.zig`'s
/// `Actions` and `capability.zig`'s `Caps` bind into the SAME instance
/// `declareSlots`/`bindDefaultStatusline` target (one `container.Container`
/// per System/Session — see `System.zig`'s `container` field doc) — action
/// names, `edit/*` capability names, and `ui/*` mesh names are one flat,
/// non-colliding slot namespace. (2) A manifest verb: `weft.statusSegment`
/// (config plane) stages a `manifest.StatusSegmentDecl`; `Manifest.
/// applyDecls` binds it through `bindManifestSegment` below, when an
/// embedder wires a `manifest.StatusSegBinder` (`main.zig` does, against
/// `&session.container`). Static text only — a command-BACKED dynamic
/// segment is a later step (see `manifest.StatusSegmentDecl`'s doc).
pub fn bindDefaultStatusline(c: *container.Container) !void {
    const all: container.Predicate = .{ .all = &.{} };
    const owner = "core:statusline";
    const Provider = *const fn (?*anyopaque, Allocator, *anyopaque) anyerror!bool;
    const defaults = [_]struct { call: Provider, priority: i32 }{
        .{ .call = modeChipProvider, .priority = 100 },
        .{ .call = placeProvider, .priority = 97 },
        .{ .call = filePathProvider, .priority = 80 },
        .{ .call = docStateProvider, .priority = 74 },
        .{ .call = bufferPosProvider, .priority = 71 },
        .{ .call = backingProvider, .priority = 70 },
        .{ .call = trustProvider, .priority = 69 },
        .{ .call = echoProvider, .priority = 60 },
        .{ .call = noticeProvider, .priority = 59 },
        .{ .call = positionProvider, .priority = 45 },
        .{ .call = selectionsProvider, .priority = 44 },
        .{ .call = languageProvider, .priority = 40 },
        .{ .call = linkProvider, .priority = 35 },
        .{ .call = peersProvider, .priority = 34 },
        .{ .call = feedProvider, .priority = 30 },
    };
    for (defaults, 0..) |d, i| try c.bind(.{
        .slot = "ui/statusline-seg",
        .provider = .{ .ui_provider = .{ .call = d.call } },
        .predicate = all,
        .tier = .core,
        .priority = d.priority,
        .owner = owner,
        .domain = .ui,
        .decl_index = @intCast(i),
    });
}

/// The three default gutter segments — real, fireable, tested, but NOT
/// bound by `Session.init` (see this file's module doc: no live gutter
/// exists today, so nothing binds them by default — a config/test opts in
/// explicitly, exactly like any other mesh slot).
pub fn bindDefaultGutter(c: *container.Container) !void {
    const all: container.Predicate = .{ .all = &.{} };
    const owner = "core:gutter";
    try c.bind(.{ .slot = "ui/gutter-segment", .provider = .{ .ui_provider = .{ .call = lineNumberProvider } }, .predicate = all, .tier = .core, .priority = 100, .owner = owner, .domain = .ui, .decl_index = 0 });
    try c.bind(.{ .slot = "ui/gutter-segment", .provider = .{ .ui_provider = .{ .call = diagMarksProvider } }, .predicate = all, .tier = .core, .priority = 90, .owner = owner, .domain = .ui, .decl_index = 1 });
    try c.bind(.{ .slot = "ui/gutter-segment", .provider = .{ .ui_provider = .{ .call = breakpointMarksProvider } }, .predicate = all, .tier = .core, .priority = 80, .owner = owner, .domain = .ui, .decl_index = 2 });
}

/// `weft.statusSegment`'s mesh-reachability seam (doc/cwa-prior-docs-audit.md §5
/// item 3) — matches `core.manifest.StatusSegBinder.bind`'s signature
/// exactly, so an embedder wires `.{ .ctx = &session.container, .bind =
/// bindManifestSegment }` directly (`main.zig` does). Binds `decl` — BORROWED
/// (see `core.manifest.StatusSegmentDecl`'s and `StatusSegBinder`'s docs for
/// the lifetime contract: it points into a `Manifest`'s own decl list,
/// unbound by `teardownOwned`/`unbindOwnerExact` before that manifest is
/// destroyed) — as an ordinary `ui/statusline-seg` `ui_provider`, at
/// `tier`/`owner`/`decl.priority`, domain `.ui` (task #19 review send-back:
/// the Container's cross-domain unbind hazard fix — see `container.zig`'s
/// `Domain` doc). Composes alongside `bindDefaultStatusline`'s `.core`-tier
/// defaults exactly like the "MESH TEST" below proves for a host-bound
/// extra provider: a `.config`-tier binding here always outranks `.core`
/// regardless of priority.
///
/// **Role resolution happens HERE, at bind time** (review send-back nit —
/// moved off the fire path): `decl.role` is parsed ONCE against
/// `core.surface.Role` and cached into `decl.resolved_role` (mutating the
/// BORROWED `decl` is the documented contract — see `StatusSegBinder.bind`'s
/// doc for why it's sound); an unrecognized/empty name warns AND echoes
/// (the `weft.set`/`echoValueDropped` precedent — a config typo should
/// degrade the segment's color, not break config loading, but the author
/// should still see it) exactly ONCE, only for a decl that's actually going
/// to render — never for one staged but dropped (no binder wired).
/// `manifestSegProvider` (the fire path) just reads the cached enum: no
/// string parsing, no possible warning, every HUD build.
pub fn bindManifestSegment(ctx_ptr: *anyopaque, apply_ctx: *core.command.Context, owner: []const u8, tier: container.Tier, decl: *core.manifest.StatusSegmentDecl) !void {
    const c: *container.Container = @ptrCast(@alignCast(ctx_ptr));
    decl.resolved_role = std.meta.stringToEnum(core.surface.Role, decl.role) orelse blk: {
        const gpa = apply_ctx.gpa;
        std.log.warn("weft.statusSegment('{s}'): unrecognized role '{s}' — falling back to 'normal'", .{ decl.text, decl.role });
        const msg = std.fmt.allocPrint(gpa, "weft.statusSegment('{s}'): unrecognized role '{s}' — using 'normal'", .{ decl.text, decl.role }) catch break :blk .normal;
        defer gpa.free(msg);
        apply_ctx.head.echo.say(gpa, msg) catch {};
        break :blk .normal;
    };
    try c.bind(.{
        .slot = "ui/statusline-seg",
        .provider = .{ .ui_provider = .{ .call = manifestSegProvider, .ctx = decl } },
        .predicate = .{ .all = &.{} },
        .tier = tier,
        .priority = decl.priority,
        .owner = owner,
        .domain = .ui,
    });
}

/// `manifest.StatusSegmentDecl`'s `text` + already-BOUND-TIME-resolved
/// `resolved_role` rendered as a static `Seg` — no string parsing here (see
/// `bindManifestSegment`'s doc for why that moved to bind time): this path
/// stays silent and cheap on every HUD build.
fn manifestSegProvider(ctx: ?*anyopaque, gpa: Allocator, raw: *anyopaque) anyerror!bool {
    const decl: *const core.manifest.StatusSegmentDecl = @ptrCast(@alignCast(ctx.?));
    const a: *StatuslineArgs = @ptrCast(@alignCast(raw));
    const text = try gpa.dupe(u8, decl.text);
    try a.out.append(gpa, .{ .text = text, .role = decl.resolved_role, .command = decl.command });
    return true;
}

// ── Tests ───────────────────────────────────────────────────────────

const t = std.testing;

test "ui_mesh: statusline defaults — the grammar's mode chip, the path, and the caret's facts on the right" {
    const gpa = t.allocator;
    var c = container.Container.init(gpa);
    defer c.deinit();
    try declareSlots(&c);
    try bindDefaultStatusline(&c);

    const theme: Theme = .{};
    var args: StatuslineArgs = .{
        .facts = .{ .mode = "normal", .lang = "zig" },
        .mode = .{ .name = "NORMAL", .tone = .normal },
        .file = "src/main.zig",
        .caret = .{ .line = 12, .col = 4 },
        .theme = &theme,
    };
    const segs = try fireStatusline(&c, gpa, &args);
    defer freeSegs(gpa, segs);

    // mode, path; then the right cluster: position, language. Nothing that
    // opted out (no place, no head, one selection) left an empty segment.
    try t.expectEqual(@as(usize, 4), segs.len);
    try t.expectEqualStrings("NORMAL", segs[0].text);
    try t.expectEqual(theme.modeChipColor(.normal), segs[0].bg_override.?);
    try t.expectEqualStrings("src/main.zig", segs[1].text);
    try t.expectEqualStrings("main.zig", segs[1].compact);
    try t.expectEqual(status_layout.Elide.start, segs[1].elide);
    try t.expect(!segs[1].align_right);
    try t.expectEqualStrings("Ln 12, Col 4", segs[2].text);
    try t.expectEqualStrings("12:4", segs[2].compact);
    try t.expect(segs[2].align_right);
    try t.expectEqualStrings(go_to_line, segs[2].command);
    try t.expectEqualStrings("zig", segs[3].text);
    try t.expect(segs[3].align_right);
    // The chip outlives the position, which outlives the path — which
    // yields gracefully, cut from its start down to its tail.
    try t.expect(segs[0].priority > segs[2].priority and segs[2].priority > segs[1].priority);
}

test "ui_mesh: a mode no grammar named shows no chip; the head's extras show only where the head looks" {
    const gpa = t.allocator;
    var c = container.Container.init(gpa);
    defer c.deinit();
    try declareSlots(&c);
    try bindDefaultStatusline(&c);
    const theme: Theme = .{};

    // A modeless grammar: no chip at all — never the mode's id.
    var bare: StatuslineArgs = .{ .facts = .{ .mode = "ide-structural" }, .file = "a.zig", .theme = &theme };
    const plain = try fireStatusline(&c, gpa, &bare);
    defer freeSegs(gpa, plain);
    for (plain) |s| try t.expect(std.mem.indexOf(u8, s.text, "ide") == null);
    try t.expectEqualStrings("a.zig", plain[0].text);

    // Modified, several selections, and the head's message and chip.
    var full: StatuslineArgs = .{
        .facts = .{ .mode = "insert" },
        .mode = .{ .name = "INSERT", .tone = .insert },
        .file = "a.zig",
        .doc = .{ .dirty = true, .peers = 2 },
        .caret = .{ .line = 1, .col = 1, .selections = 3 },
        .head = .{ .echo = "written", .feed = "building…", .link = "shell:box connecting" },
        .theme = &theme,
    };
    const segs = try fireStatusline(&c, gpa, &full);
    defer freeSegs(gpa, segs);
    var texts: [16][]const u8 = undefined;
    for (segs, 0..) |s, i| texts[i] = s.text;
    const want = [_][]const u8{ "INSERT", "a.zig", "●", "written", "Ln 1, Col 1", "3 selections", "shell:box connecting", "✦ 2", "building…" };
    try t.expectEqual(want.len, segs.len);
    for (want, texts[0..segs.len]) |w, got| try t.expectEqualStrings(w, got);
    try t.expectEqual(theme.modeChipColor(.insert), segs[0].bg_override.?);
    // The message is cut short rather than lost; the chips carry icons.
    try t.expectEqual(status_layout.Elide.end, segs[3].elide);
    try t.expectEqualStrings("dot", segs[2].icon);
    try t.expectEqualStrings("users", segs[7].icon);
}

test "ui_mesh: MESH TEST — an extra statusline provider inserts at its priority position; unbind removes it" {
    // Proves the actual point of the mesh (doc/rendering.md "Wiring +
    // defaults"): swapping/adding a piece is literal and local — bind a new
    // provider on the SAME slot and it composes in; unbind and it's gone,
    // with zero change to the other providers.
    const gpa = t.allocator;
    var c = container.Container.init(gpa);
    defer c.deinit();
    try declareSlots(&c);
    try bindDefaultStatusline(&c);

    const theme: Theme = .{};
    const Extra = struct {
        fn call(_: ?*anyopaque, gpa2: Allocator, raw: *anyopaque) anyerror!bool {
            const a: *StatuslineArgs = @ptrCast(@alignCast(raw));
            try a.out.append(gpa2, .{ .text = try gpa2.dupe(u8, "[extra]"), .role = .accent });
            return true;
        }
    };
    // Config tier outranks `.core` regardless of priority — the extra
    // segment sorts FIRST, ahead of the mode chip, proving real ordering
    // (tier-then-priority) rather than a hardcoded slot.
    try c.bind(.{ .slot = "ui/statusline-seg", .provider = .{ .ui_provider = .{ .call = Extra.call } }, .predicate = .{ .all = &.{} }, .tier = .config, .priority = 0, .owner = "test-plugin", .domain = .ui });

    const mode: core.Keymap.ModeDisplay = .{ .name = "NORMAL" };
    var args: StatuslineArgs = .{ .facts = .{ .mode = "normal" }, .mode = mode, .file = "a.zig", .theme = &theme };
    const with_extra = try fireStatusline(&c, gpa, &args);
    defer freeSegs(gpa, with_extra);
    try t.expectEqual(@as(usize, 3), with_extra.len); // extra, mode, file
    try t.expectEqualStrings("[extra]", with_extra[0].text);
    try t.expectEqualStrings("NORMAL", with_extra[1].text);
    try t.expectEqualStrings("a.zig", with_extra[2].text);

    c.unbindOwnerExact(.ui, "test-plugin");
    var args2: StatuslineArgs = .{ .facts = .{ .mode = "normal" }, .mode = mode, .file = "a.zig", .theme = &theme };
    const after = try fireStatusline(&c, gpa, &args2);
    defer freeSegs(gpa, after);
    try t.expectEqual(@as(usize, 2), after.len); // back to mode, file only
    try t.expectEqualStrings("NORMAL", after[0].text);
}

test "ui_mesh: a plugin's segment keeps its compact form, priority, icon and tooltip through the wire" {
    const gpa = t.allocator;
    var c = container.Container.init(gpa);
    defer c.deinit();
    try declareSlots(&c);
    try bindDefaultStatusline(&c);
    // What `wl_slot_bind` at the core tier, priority 96, makes.
    try c.bind(.{
        .slot = core.status_segment.slot_name,
        .provider = .{ .schema_provider = .{ .owner = "git", .seq = 0 } },
        .predicate = .{ .all = &.{} },
        .tier = .core,
        .priority = 96,
        .owner = "git",
        .domain = .slot,
    });
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const payload = try core.status_segment.encodeTell(a, &.{.{ .text = "feature/long-name", .compact = "feature…", .priority = 60, .command = "git.status", .icon = "git-branch", .tooltip = "Branch" }});
    const answers = [_]StatuslineAnswer{try decodeStatuslineAnswer(a, "git", payload)};

    const theme: Theme = .{};
    var args: StatuslineArgs = .{ .facts = .{ .mode = "normal" }, .mode = .{ .name = "NORMAL" }, .place = .{ .name = "weft", .icon = "folder" }, .file = "a.zig", .theme = &theme, .plugin_answers = &answers };
    const segs = try fireStatusline(&c, a, &args);
    try t.expect(args.plugin_reached);
    // mode (100), place (97), the branch (96), the path (80).
    try t.expectEqual(@as(usize, 4), segs.len);
    try t.expectEqualStrings("weft", segs[1].text);
    const branch = segs[2];
    try t.expectEqualStrings("feature/long-name", branch.text);
    try t.expectEqualStrings("feature…", branch.compact);
    try t.expectEqual(@as(i32, 60), branch.priority);
    try t.expectEqualStrings("git.status", branch.command);
    try t.expectEqualStrings("git-branch", branch.icon);
    try t.expectEqualStrings("Branch", branch.tooltip);
}
test "ui_mesh: gutter — unbound is a zero-cost no-op; bound, line numbers + diag + breakpoint marks compose per line" {
    const gpa = t.allocator;
    var c = container.Container.init(gpa);
    defer c.deinit();
    try declareSlots(&c);

    var doc = try core.Document.init(gpa, "user");
    defer doc.deinit(gpa);
    try doc.insert(gpa, 0, "one\ntwo\nthree\n");
    var store: core.layers.Layers = .empty;
    defer store.deinit(gpa);
    const live = try store.claim(gpa, &doc, "diagnostics", .local, "test");
    // A diagnostic on line 2 ("two", byte range [4,7)).
    try live.publishSpans(gpa, &.{.{ .start = 4, .end = 5, .kind = 1, .message = "bad" }});
    var snap_arena = std.heap.ArenaAllocator.init(gpa);
    defer snap_arena.deinit();
    const snap = try live.snapshot(snap_arena.allocator(), .{ .start = 0, .end = doc.text().byteLen() });
    const dl = &snap;

    const theme: Theme = .{};

    // Unbound: eligible() returns nothing, gutterCellsForLine never calls a
    // provider — the honest "nothing renders" default.
    {
        const bindings = try gutterBindings(&c, gpa, .{});
        defer gpa.free(bindings);
        try t.expectEqual(@as(usize, 0), bindings.len);
        var args: GutterLineArgs = .{ .line = 1, .row = doc.text().lineRange(1), .diag_layer = dl, .theme = &theme };
        const cells = try gutterCellsForLine(bindings, gpa, &args);
        defer freeSegs(gpa, cells);
        try t.expectEqual(@as(usize, 0), cells.len);
    }

    // Bound: fire once for the frame, then per line.
    try bindDefaultGutter(&c);
    const bindings = try gutterBindings(&c, gpa, .{});
    defer gpa.free(bindings);
    try t.expectEqual(@as(usize, 3), bindings.len);

    // Line 0 ("one"): line number only, no diagnostic, no breakpoint.
    {
        var args: GutterLineArgs = .{ .line = 0, .row = doc.text().lineRange(0), .diag_layer = dl, .bp_lines = "3", .theme = &theme };
        const cells = try gutterCellsForLine(bindings, gpa, &args);
        defer freeSegs(gpa, cells);
        try t.expectEqual(@as(usize, 1), cells.len);
        try t.expectEqualStrings("1 ", cells[0].text);
    }

    // Line 1 ("two"): line number + a diagnostic mark (the span overlaps).
    {
        var args: GutterLineArgs = .{ .line = 1, .row = doc.text().lineRange(1), .diag_layer = dl, .bp_lines = "3", .theme = &theme };
        const cells = try gutterCellsForLine(bindings, gpa, &args);
        defer freeSegs(gpa, cells);
        try t.expectEqual(@as(usize, 2), cells.len);
        try t.expectEqualStrings("2 ", cells[0].text);
        try t.expectEqualStrings("\u{25B2} ", cells[1].text);
        try t.expectEqual(theme.diag_error, cells[1].fg_override.?);
    }

    // Line 2 ("three", 1-based line 3): line number + a breakpoint mark.
    {
        var args: GutterLineArgs = .{ .line = 2, .row = doc.text().lineRange(2), .diag_layer = dl, .bp_lines = "3", .theme = &theme };
        const cells = try gutterCellsForLine(bindings, gpa, &args);
        defer freeSegs(gpa, cells);
        try t.expectEqual(@as(usize, 2), cells.len);
        try t.expectEqualStrings("3 ", cells[0].text);
        try t.expectEqualStrings("\u{25CF} ", cells[1].text);
    }
}

test "ui_mesh: a PLUGIN gutter provider's window answers every row in it, only where its predicate holds" {
    const gpa = t.allocator;
    var c = container.Container.init(gpa);
    defer c.deinit();
    try declareSlots(&c);
    // What `wl_slot_bind` makes: a schema provider, narrowed to text entries.
    try c.bind(.{
        .slot = core.gutter.slot_name,
        .provider = .{ .schema_provider = .{ .owner = "numbers", .seq = 0 } },
        .predicate = .{ .posture = "text" },
        .tier = .plugin,
        .priority = 100,
        .owner = "numbers",
        .domain = .slot,
    });

    // A structural entry (a git status, a listing) never asks it.
    const none = try gutterBindings(&c, gpa, .{ .posture = "structural", .tool = "git" });
    defer gpa.free(none);
    try t.expectEqual(@as(usize, 0), none.len);

    const bindings = try gutterBindings(&c, gpa, .{ .posture = "text" });
    defer gpa.free(bindings);
    try t.expectEqual(@as(usize, 1), bindings.len);

    // An answer, as the app caches it — "L<n>" for each line of the asked
    // window, through the real `core.gutter` encode/decode.
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const answer = struct {
        fn of(al: Allocator, key: u64, first: usize, tag: []const u8) !GutterBatch.Window {
            var cells: [core.gutter.window]core.gutter.Cell = undefined;
            for (&cells, 0..) |*cell, i| cell.* = .{ .text = try std.fmt.allocPrint(al, "{s}{d}", .{ tag, first + i }), .role = 5 };
            const payload = try core.gutter.encodeTell(al, @intCast(first), &cells);
            const answers = try al.alloc(GutterBatch.Answer, 1);
            answers[0] = try decodeGutterAnswer(al, "numbers", payload);
            return .{ .key = key, .first = first, .answers = answers };
        }
    }.of;
    const theme: Theme = .{};

    // One window answers every row inside it, and nothing is wanted.
    var batch: GutterBatch = .{ .windows = &.{try answer(a, 1, 0, "L")}, .key = 1 };
    for ([_]usize{ 0, 7, 255 }) |line| {
        var args: GutterLineArgs = .{ .line = line, .row = .{ .start = 0, .end = 0 }, .theme = &theme, .batch = &batch };
        const cells = try gutterCellsForLine(bindings, a, &args);
        try t.expectEqual(@as(usize, 1), cells.len);
        try t.expectEqualStrings(try std.fmt.allocPrint(a, "L{d}", .{line}), cells[0].text);
        try t.expectEqual(core.surface.Role.muted, cells[0].role);
    }
    try t.expect(batch.wanted == null);

    // A row past every window draws nothing and is what the pane asks for next.
    var args: GutterLineArgs = .{ .line = 300, .row = .{ .start = 0, .end = 0 }, .theme = &theme, .batch = &batch };
    try t.expectEqual(@as(usize, 0), (try gutterCellsForLine(bindings, a, &args)).len);
    try t.expectEqual(@as(?usize, 300), batch.wanted);

    // A window answered for an older question still draws — at most a frame
    // late — but the row is wanted again; the current answer wins once it is in.
    var stale: GutterBatch = .{ .windows = &.{try answer(a, 1, 0, "old")}, .key = 2 };
    args = .{ .line = 3, .row = .{ .start = 0, .end = 0 }, .theme = &theme, .batch = &stale };
    try t.expectEqualStrings("old3", (try gutterCellsForLine(bindings, a, &args))[0].text);
    try t.expectEqual(@as(?usize, 3), stale.wanted);
    var fresh: GutterBatch = .{ .windows = &.{ try answer(a, 2, 0, "new"), try answer(a, 1, 0, "old") }, .key = 2 };
    args = .{ .line = 3, .row = .{ .start = 0, .end = 0 }, .theme = &theme, .batch = &fresh };
    try t.expectEqualStrings("new3", (try gutterCellsForLine(bindings, a, &args))[0].text);
    try t.expect(fresh.wanted == null);
}

test "ui_mesh: MESH REACHABILITY — weft.statusSegment reaches ui/statusline-seg through the REAL sealed-eval manifest path (task #19)" {
    // Proves the whole chain end to end, through the ACTUAL config surface
    // (not a Zig stand-in for it): config JS source -> quickjs sealed eval
    // -> Manifest -> Manifest.apply -> StatusSegBinder -> a real Container
    // bind -> fireStatusline composes it into the statusline. Uses a real
    // `core.System` (task #19's shared-Container fold-in: `sys.container`
    // is the SAME instance `sys.caps`/`sys.actions` bind into) as the host,
    // mirroring `System.zig`'s own "a second manifest hosts a SECOND
    // system end-to-end" test.
    const gpa = t.allocator;
    const pool = try core.task.Pool.init(gpa, .{ .threads = 1 });
    defer pool.deinit();
    const sys = try core.System.create(gpa, pool, "editor", "user");
    defer sys.destroy();

    try declareSlots(&sys.container);
    try bindDefaultStatusline(&sys.container);

    var engine = try core.wasm.Engine.init(gpa);
    defer engine.deinit();
    var c = sys.contextFor(&sys.default_head);
    const src = "weft.statusSegment(\"BUILD OK\", \"accent\", 500);";
    const m = try core.quickjs.evalToManifest(&engine, &c, null, null, null, src, .config, "config");
    defer m.destroy();

    var actx: core.manifest.Manifest.ApplyCtx = .{
        .ctx = &c,
        .loader = null,
        .config = null,
        .ui_bind = .{ .ctx = &sys.container, .bind = bindManifestSegment },
    };
    try m.apply(gpa, &actx);

    const theme: Theme = .{};
    var args: StatuslineArgs = .{ .facts = .{ .mode = "normal" }, .file = "a.zig", .theme = &theme };
    const segs = try fireStatusline(&sys.container, gpa, &args);
    defer freeSegs(gpa, segs);

    // `weft.statusSegment`'s priority (500) is irrelevant here — TIER
    // decides first in the strict weak order (container.zig's `betterThan`)
    // and `.config` (this manifest's tier) always outranks `bindDefault
    // Statusline`'s `.core` — so the staged segment sorts before the mode
    // chip regardless of the chip's own higher raw priority (100).
    try t.expect(segs.len >= 1);
    try t.expectEqualStrings("BUILD OK", segs[0].text);
    try t.expectEqual(core.surface.Role.accent, segs[0].role);
}

test "ui_mesh: weft.statusSegment with NO binder wired is a logged no-op, not a crash" {
    // The honest fallback `ApplyCtx.ui_bind == null` documents: a manifest
    // can stage the decl (config eval never fails), but applying it against
    // a host that never wired a `StatusSegBinder` drops it — proven here by
    // asserting the statusline composes EXACTLY the defaults, nothing more.
    const gpa = t.allocator;
    const pool = try core.task.Pool.init(gpa, .{ .threads = 1 });
    defer pool.deinit();
    const sys = try core.System.create(gpa, pool, "editor", "user");
    defer sys.destroy();

    try declareSlots(&sys.container);
    try bindDefaultStatusline(&sys.container);

    var engine = try core.wasm.Engine.init(gpa);
    defer engine.deinit();
    var c = sys.contextFor(&sys.default_head);
    const src = "weft.statusSegment(\"unreachable\", \"accent\", 500);";
    const m = try core.quickjs.evalToManifest(&engine, &c, null, null, null, src, .config, "config");
    defer m.destroy();

    var actx: core.manifest.Manifest.ApplyCtx = .{ .ctx = &c, .loader = null, .config = null }; // ui_bind left null
    try m.apply(gpa, &actx);

    const theme: Theme = .{};
    var args: StatuslineArgs = .{ .facts = .{ .mode = "normal" }, .file = "a.zig", .theme = &theme };
    const segs = try fireStatusline(&sys.container, gpa, &args);
    defer freeSegs(gpa, segs);

    for (segs) |s| try t.expect(!std.mem.eql(u8, s.text, "unreachable"));
    try t.expectEqualStrings("a.zig", segs[0].text); // just the ordinary defaults
}

test {
    std.testing.refAllDecls(@This());
}
