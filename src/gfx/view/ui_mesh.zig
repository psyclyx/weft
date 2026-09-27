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
//! documented on the type itself: today's mode chip (a per-MODE, not
//! per-Role, background) and the diagnostics count / diagnostic gutter mark
//! (`diag_error`/`diag_warn` — colors with no existing `Role`) predate the
//! Role vocabulary and don't fit it losslessly. One or two users each, not
//! generalized into a raw-color hole — a THIRD user is the forcing function
//! for teaching `Role` these colors for real.
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

/// A composed segment — the shared output vocabulary for both slots.
pub const Seg = struct {
    /// Owned by whatever allocator the firing call was given (a per-frame
    /// arena in production; the caller's `gpa` in a test — see `freeSegs`).
    text: []const u8,
    role: core.surface.Role = .normal,
    /// Escape hatch: the mode chip's per-MODE (not per-Role) background text
    /// color — `Theme.modeChipColor` has no `Role` analogue.
    fg_override: ?[4]f32 = null,
    /// Escape hatch: the mode chip's per-MODE background rect.
    bg_override: ?[4]f32 = null,
    /// Right-anchored cluster (today's peers/diag-count/status group,
    /// measured backward from the right edge) vs the ordinary left-to-right
    /// cluster. Mirrors `core.surface.Span.column`'s alignment-tag
    /// convention (0 = main, 1 = other) rather than inventing a new one.
    align_right: bool = false,
    /// Blank columns to insert AFTER this segment, in the LEFT cluster's
    /// render loop only — spacing is DATA the predecessor declares, not text
    /// baked into a neighbor. This is what makes today's legacy gap rule
    /// (an UNCONDITIONAL blank column after the mode chip; yet ANOTHER,
    /// but only when buffer_pos actually rendered) reproduce correctly in
    /// BOTH cases a mesh composition can hit: buffer_pos present (its own
    /// `gap_after` supplies the second gap) and buffer_pos ABSENT — e.g. a
    /// peeked pane, which never fires it (opts out, contributes nothing) —
    /// where baking the gap into buffer_pos's own leading whitespace would
    /// have silently dropped the chip's gap too. See `git show 8cb6244`'s
    /// `statusline.zig` (`col += 1` after the chip, unconditional; a SECOND
    /// `col += 1` only inside the `if (hud.buffer_pos)` block) for the
    /// legacy rule this reproduces exactly in both cases.
    gap_after: u8 = 0,
    /// The command a click on the segment runs, or "" (not clickable).
    /// BORROWED — a manifest decl's, or a plugin answer's in the frame
    /// arena — so `freeSegs` leaves it alone.
    command: []const u8 = "",
    /// An icon name (the theme's set) drawn in place of the segment's first
    /// glyph by a chrome style that shows icons. BORROWED, like `command`.
    icon: []const u8 = "",
    /// What the segment's tooltip says; its command when empty. BORROWED.
    tooltip: []const u8 = "",
};

pub fn freeSegs(gpa: Allocator, segs: []const Seg) void {
    for (segs) |s| gpa.free(s.text);
    gpa.free(segs);
}

// ── ui/statusline-seg ──────────────────────────────────────────────

/// Per-HUD-build input a statusline provider reads. Frame-varying fields
/// (`file`/`buffer_pos`/`diag_layer`/`link`) are filled by `frame_builder`
/// from the SAME sources that fed the pre-mesh direct assembly; `facts` is
/// the Container-matched context (today just `.mode`, room to grow).
pub const StatuslineArgs = struct {
    facts: Facts,
    file: []const u8 = "",
    buffer_pos: ?[]const u8 = null,
    diag_layer: ?*const core.layers.Layer = null,
    link: ?[]const u8 = null,
    theme: *const Theme,
    /// What the PLUGIN providers last said for this pane
    /// (`app/answers.zig`), possibly to an older question: a frame never asks
    /// a guest itself. Empty means a `.schema_provider` binding contributes
    /// nothing this frame.
    plugin_answers: []const StatuslineAnswer = &.{},
    /// Set by `fireStatusline` when an eligible binding is a plugin's — the
    /// caller then knows this pane's status is a question worth asking.
    plugin_reached: bool = false,
    /// Set by `fireStatusline` itself before invoking providers — a caller
    /// building `StatuslineArgs` need not (and should not) set this.
    out: *std.ArrayList(Seg) = undefined,
};

/// One plugin provider's segments, by the binding owner the slot host names
/// it by: a decoded `core.status_segment` answer.
pub const StatuslineAnswer = struct { owner: []const u8, segs: []const Seg };

/// Decode one provider's `core.status_segment` answer into `Seg`s owned by
/// `gpa` (text and command both). A malformed answer says nothing.
pub fn decodeStatuslineAnswer(gpa: Allocator, owner: []const u8, payload: []const u8) !StatuslineAnswer {
    var segs: std.ArrayList(Seg) = .empty;
    if (core.status_segment.decodeTell(payload)) |told| {
        var tell = told;
        while (tell.next()) |s| {
            if (segs.items.len >= core.status_segment.max_segments) break;
            if (s.text.len == 0) continue;
            try segs.append(gpa, .{
                .text = try gpa.dupe(u8, s.text),
                .role = core.surface.Role.fromInt(s.role),
                .align_right = s.right,
                .command = try gpa.dupe(u8, s.command),
            });
        }
    }
    return .{ .owner = try gpa.dupe(u8, owner), .segs = segs.items };
}

fn modeChipProvider(_: ?*anyopaque, gpa: Allocator, raw: *anyopaque) anyerror!bool {
    const a: *StatuslineArgs = @ptrCast(@alignCast(raw));
    const text = try std.fmt.allocPrint(gpa, " {s} ", .{a.facts.mode});
    // `gap_after = 1` reproduces the legacy UNCONDITIONAL `col += 1` right
    // after the chip (git show 8cb6244) — it fires whether or not
    // buffer_pos follows, so it lives on the chip, not on buffer_pos.
    try a.out.append(gpa, .{ .text = text, .fg_override = a.theme.background, .bg_override = a.theme.modeChipColor(a.facts.mode), .gap_after = 1 });
    return true;
}

fn bufferPosProvider(_: ?*anyopaque, gpa: Allocator, raw: *anyopaque) anyerror!bool {
    const a: *StatuslineArgs = @ptrCast(@alignCast(raw));
    const bp = a.buffer_pos orelse return false;
    const text = try gpa.dupe(u8, bp);
    // `gap_after = 1` reproduces the legacy SECOND `col += 1`, INSIDE the
    // `if (hud.buffer_pos)` block — conditional on this segment actually
    // firing, which "opt out, contribute nothing" already gives us for
    // free (the gap simply never gets added when this provider returns
    // `false`, e.g. a peeked pane).
    try a.out.append(gpa, .{ .text = text, .role = .muted, .gap_after = 1 });
    return true;
}

fn filePathProvider(_: ?*anyopaque, gpa: Allocator, raw: *anyopaque) anyerror!bool {
    const a: *StatuslineArgs = @ptrCast(@alignCast(raw));
    const text = try gpa.dupe(u8, if (a.file.len > 0) a.file else "[scratch]");
    try a.out.append(gpa, .{ .text = text, .role = .normal });
    return true;
}

fn collabLivenessProvider(_: ?*anyopaque, gpa: Allocator, raw: *anyopaque) anyerror!bool {
    const a: *StatuslineArgs = @ptrCast(@alignCast(raw));
    const l = a.link orelse return false;
    const text = try std.fmt.allocPrint(gpa, "  link:{s}", .{l});
    try a.out.append(gpa, .{ .text = text, .role = .effect });
    return true;
}

fn diagCountProvider(_: ?*anyopaque, gpa: Allocator, raw: *anyopaque) anyerror!bool {
    const a: *StatuslineArgs = @ptrCast(@alignCast(raw));
    const dl = a.diag_layer orelse return false;
    const n = dl.spanCount();
    if (n == 0) return false;
    const text = try std.fmt.allocPrint(gpa, "!{d} ", .{n});
    try a.out.append(gpa, .{ .text = text, .fg_override = a.theme.diag_error, .align_right = true });
    return true;
}

/// Fire `ui/statusline-seg`: resolve the eligible, priority-sorted provider
/// list against `args.facts` and invoke each in order, collecting whatever
/// segments they contribute (a provider that opts out — e.g. no
/// `buffer_pos` — contributes nothing, not an empty segment). Caller owns
/// the returned slice AND every segment's `text` (`freeSegs`, or let a
/// per-frame arena reclaim both).
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
            // the command borrowed like every segment's).
            .schema_provider => |ref| {
                args.plugin_reached = true;
                for (args.plugin_answers) |ans| {
                    if (!std.mem.eql(u8, ans.owner, ref.owner)) continue;
                    for (ans.segs) |s| try out.append(gpa, .{ .text = try gpa.dupe(u8, s.text), .role = s.role, .align_right = s.align_right, .command = s.command });
                    break;
                }
            },
            else => {},
        }
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

/// The five default statusline segments, at `.core` tier (lowest). The TIER
/// mechanism means a higher-tier binding on the same slot outranks these —
/// proven by the mesh test. Priorities reproduce today's left-to-right
/// order: mode, position, file, collab-liveness (left cluster); diagnostics
/// count (right-anchored, `align_right`).
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
    try c.bind(.{ .slot = "ui/statusline-seg", .provider = .{ .ui_provider = .{ .call = modeChipProvider } }, .predicate = all, .tier = .core, .priority = 100, .owner = owner, .domain = .ui, .decl_index = 0 });
    try c.bind(.{ .slot = "ui/statusline-seg", .provider = .{ .ui_provider = .{ .call = bufferPosProvider } }, .predicate = all, .tier = .core, .priority = 90, .owner = owner, .domain = .ui, .decl_index = 1 });
    try c.bind(.{ .slot = "ui/statusline-seg", .provider = .{ .ui_provider = .{ .call = filePathProvider } }, .predicate = all, .tier = .core, .priority = 80, .owner = owner, .domain = .ui, .decl_index = 2 });
    try c.bind(.{ .slot = "ui/statusline-seg", .provider = .{ .ui_provider = .{ .call = collabLivenessProvider } }, .predicate = all, .tier = .core, .priority = 70, .owner = owner, .domain = .ui, .decl_index = 3 });
    try c.bind(.{ .slot = "ui/statusline-seg", .provider = .{ .ui_provider = .{ .call = diagCountProvider } }, .predicate = all, .tier = .core, .priority = 10, .owner = owner, .domain = .ui, .decl_index = 4 });
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
        apply_ctx.head.echo.clearRetainingCapacity();
        apply_ctx.head.echo.appendSlice(gpa, msg) catch {};
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

test "ui_mesh: statusline defaults reproduce today's chip set + order" {
    const gpa = t.allocator;
    var c = container.Container.init(gpa);
    defer c.deinit();
    try declareSlots(&c);
    try bindDefaultStatusline(&c);

    const theme: Theme = .{};
    var args: StatuslineArgs = .{
        .facts = .{ .mode = "normal" },
        .file = "main.zig",
        .buffer_pos = "1/2",
        .theme = &theme,
    };
    const segs = try fireStatusline(&c, gpa, &args);
    defer freeSegs(gpa, segs);

    // No link, no diagnostics bound this call — three segments: mode,
    // position, file, in that order (link/diag opted out — null/absent).
    try t.expectEqual(@as(usize, 3), segs.len);
    try t.expectEqualStrings(" normal ", segs[0].text);
    try t.expectEqual(theme.modeChipColor("normal"), segs[0].bg_override.?);
    try t.expectEqual(@as(u8, 1), segs[0].gap_after); // the legacy unconditional post-chip gap
    try t.expectEqualStrings("1/2", segs[1].text);
    try t.expectEqual(@as(u8, 1), segs[1].gap_after); // the legacy conditional post-position gap
    try t.expectEqualStrings("main.zig", segs[2].text);
    try t.expect(!segs[2].align_right);

    // Column-accurate trace against `git show 8cb6244`'s statusline.zig:
    // chip(8) + gap(1) + "1/2"(3) + gap(1) + file starts at col 13.
    var col: usize = 0;
    for (segs) |seg| {
        col += std.unicode.utf8CountCodepoints(seg.text) catch seg.text.len;
        col += seg.gap_after;
    }
    // (file itself contributes no trailing gap — the next legacy chip,
    // `dirty`, supplies its OWN leading space, unchanged/hardcoded.)
    try t.expectEqual(@as(usize, 8 + 1 + 3 + 1 + 8), col); // + "main.zig".len
}

test "ui_mesh: statusline — buffer_pos ABSENT (a peeked pane) still gets the chip's unconditional gap" {
    // The regression a review caught: baking the post-chip gap into
    // buffer_pos's own leading whitespace works when buffer_pos fires, but
    // silently drops the gap when it opts out (a peeked pane never sets
    // it) — `file` would start 1 column too early. `gap_after` lives on the
    // CHIP (fires unconditionally) instead, so this case is right too.
    const gpa = t.allocator;
    var c = container.Container.init(gpa);
    defer c.deinit();
    try declareSlots(&c);
    try bindDefaultStatusline(&c);

    const theme: Theme = .{};
    var args: StatuslineArgs = .{ .facts = .{ .mode = "normal" }, .file = "main.zig", .theme = &theme }; // no buffer_pos
    const segs = try fireStatusline(&c, gpa, &args);
    defer freeSegs(gpa, segs);

    try t.expectEqual(@as(usize, 2), segs.len); // mode, file — position opted out
    try t.expectEqualStrings(" normal ", segs[0].text);
    try t.expectEqual(@as(u8, 1), segs[0].gap_after);
    try t.expectEqualStrings("main.zig", segs[1].text);

    // Column-accurate trace: chip(8) + gap(1) + file starts at col 9 —
    // matching `git show 8cb6244`'s peeked-pane path (`other_hud` never set
    // `.buffer_pos`, so only the chip's unconditional `col += 1` applied).
    var col: usize = 0;
    for (segs) |seg| {
        col += std.unicode.utf8CountCodepoints(seg.text) catch seg.text.len;
        col += seg.gap_after;
    }
    try t.expectEqual(@as(usize, 8 + 1 + 8), col); // + "main.zig".len
}

test "ui_mesh: MESH TEST — an extra statusline provider inserts at its priority position; unbind removes it" {
    // Proves the actual point of the mesh (doc/rendering.md "Wiring +
    // defaults"): swapping/adding a piece is literal and local — bind a new
    // provider on the SAME slot and it composes in; unbind and it's gone,
    // with zero change to the other four providers.
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

    var args: StatuslineArgs = .{ .facts = .{ .mode = "normal" }, .file = "a.zig", .theme = &theme };
    const with_extra = try fireStatusline(&c, gpa, &args);
    defer freeSegs(gpa, with_extra);
    try t.expectEqual(@as(usize, 3), with_extra.len); // extra, mode, file
    try t.expectEqualStrings("[extra]", with_extra[0].text);
    try t.expectEqualStrings(" normal ", with_extra[1].text);
    try t.expectEqualStrings("a.zig", with_extra[2].text);

    c.unbindOwnerExact(.ui, "test-plugin");
    var args2: StatuslineArgs = .{ .facts = .{ .mode = "normal" }, .file = "a.zig", .theme = &theme };
    const after = try fireStatusline(&c, gpa, &args2);
    defer freeSegs(gpa, after);
    try t.expectEqual(@as(usize, 2), after.len); // back to mode, file only
    try t.expectEqualStrings(" normal ", after[0].text);
}

test "ui_mesh: diagnostics count is right-anchored and colored diag_error, opts out at zero" {
    const gpa = t.allocator;
    var c = container.Container.init(gpa);
    defer c.deinit();
    try declareSlots(&c);
    try bindDefaultStatusline(&c);

    var doc = try core.Document.init(gpa, "user");
    defer doc.deinit(gpa);
    try doc.insert(gpa, 0, "one\ntwo\n");
    var store: core.layers.Layers = .empty;
    defer store.deinit(gpa);
    const dl = try store.claim(gpa, &doc, "diagnostics", .local, "test");
    try dl.publishSpans(gpa, &.{.{ .start = 0, .end = 1, .kind = 1, .message = "bad" }});

    const theme: Theme = .{};
    var args: StatuslineArgs = .{ .facts = .{ .mode = "normal" }, .file = "a.zig", .diag_layer = dl, .theme = &theme };
    const segs = try fireStatusline(&c, gpa, &args);
    defer freeSegs(gpa, segs);
    try t.expectEqual(@as(usize, 3), segs.len); // mode, file, diag count
    const diag = segs[2];
    try t.expect(diag.align_right);
    try t.expectEqualStrings("!1 ", diag.text);
    try t.expectEqual(theme.diag_error, diag.fg_override.?);

    // Clear the layer: the segment disappears (opt-out), not an empty one.
    try dl.publishSpans(gpa, &.{});
    var args2: StatuslineArgs = .{ .facts = .{ .mode = "normal" }, .file = "a.zig", .diag_layer = dl, .theme = &theme };
    const segs2 = try fireStatusline(&c, gpa, &args2);
    defer freeSegs(gpa, segs2);
    try t.expectEqual(@as(usize, 2), segs2.len);
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
    try t.expectEqualStrings(" normal ", segs[0].text); // just the ordinary defaults
}

test {
    std.testing.refAllDecls(@This());
}
