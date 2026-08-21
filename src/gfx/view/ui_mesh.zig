//! ui_mesh — the UI mesh's first two ordered-union slots, `ui/statusline-seg`
//! and `ui/gutter-segment` (north-star-plan §6 W3-1; doc/rendering.md "The UI
//! as a mesh of narrow capabilities"). Host-side PROVIDERS re-express today's
//! statusline chips (and, inertly until bound, gutter marks) as
//! `core.container.Container` bindings instead of code baked directly into
//! `statusline.zig`/`frame_builder.zig` — proving the mesh's composition
//! machinery (declare/bind/eligible/unbind, strict-weak-order priority,
//! swap-one-piece) on real UI before P2 opens any slot to a guest.
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

const std = @import("std");
const Allocator = std.mem.Allocator;
const stemma = @import("stemma");
const core = @import("../../core/core.zig");
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
    /// Set by `fireStatusline` itself before invoking providers — a caller
    /// building `StatuslineArgs` need not (and should not) set this.
    out: *std.ArrayList(Seg) = undefined,
};

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
            else => {},
        }
    }
    return out.toOwnedSlice(gpa);
}

// ── ui/gutter-segment ──────────────────────────────────────────────

/// Per-visible-ROW input a gutter provider reads. `row` is this line's byte
/// range (`rope.lineRange(line)`); `diag_layer`/`bp_lines` are the SAME
/// per-buffer values across every row this frame (resolved once by the
/// caller, not re-fetched per line).
pub const GutterLineArgs = struct {
    line: usize,
    row: stemma.Range,
    diag_layer: ?*const core.layers.Layer = null,
    /// `breakpoints.get(path)`'s "l1,l2,…" CSV, or "" for none.
    bp_lines: []const u8 = "",
    theme: *const Theme,
    /// Set by `gutterCellsForLine` itself before invoking providers.
    out: *std.ArrayList(Seg) = undefined,
};

fn lineNumberProvider(_: ?*anyopaque, gpa: Allocator, raw: *anyopaque) anyerror!bool {
    const a: *GutterLineArgs = @ptrCast(@alignCast(raw));
    const text = try std.fmt.allocPrint(gpa, "{d} ", .{a.line + 1});
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
    diag_layer: ?*const core.layers.Layer = null,
    bp_lines: []const u8 = "",
};

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
            else => {},
        }
    }
    return out.toOwnedSlice(gpa);
}

// ── Wiring + defaults (doc/rendering.md "Wiring + defaults") ──────────

pub fn declareSlots(c: *container.Container) !void {
    try c.declareSlot(.{ .name = "ui/statusline-seg", .shape = .query, .composition = .ordered_union });
    try c.declareSlot(.{ .name = "ui/gutter-segment", .shape = .query, .composition = .ordered_union });
}

/// The five default statusline segments, at `.core` tier (lowest). The TIER
/// mechanism means a higher-tier binding on the same slot outranks these —
/// proven by the mesh test — but NOTE: no config/plugin path REACHES this
/// Container yet (manifest `provide` routes to Actions only; the guest
/// membrane routes to caps). Reachability arrives with the shared-Container
/// fold-in or a manifest verb (north-star-plan task #19); until then only
/// host code binds here. Priorities reproduce today's left-to-right
/// order: mode, position, file, collab-liveness (left cluster); diagnostics
/// count (right-anchored, `align_right`).
pub fn bindDefaultStatusline(c: *container.Container) !void {
    const all: container.Predicate = .{ .all = &.{} };
    const owner = "core:statusline";
    try c.bind(.{ .slot = "ui/statusline-seg", .provider = .{ .ui_provider = .{ .call = modeChipProvider } }, .predicate = all, .tier = .core, .priority = 100, .owner = owner, .decl_index = 0 });
    try c.bind(.{ .slot = "ui/statusline-seg", .provider = .{ .ui_provider = .{ .call = bufferPosProvider } }, .predicate = all, .tier = .core, .priority = 90, .owner = owner, .decl_index = 1 });
    try c.bind(.{ .slot = "ui/statusline-seg", .provider = .{ .ui_provider = .{ .call = filePathProvider } }, .predicate = all, .tier = .core, .priority = 80, .owner = owner, .decl_index = 2 });
    try c.bind(.{ .slot = "ui/statusline-seg", .provider = .{ .ui_provider = .{ .call = collabLivenessProvider } }, .predicate = all, .tier = .core, .priority = 70, .owner = owner, .decl_index = 3 });
    try c.bind(.{ .slot = "ui/statusline-seg", .provider = .{ .ui_provider = .{ .call = diagCountProvider } }, .predicate = all, .tier = .core, .priority = 10, .owner = owner, .decl_index = 4 });
}

/// The three default gutter segments — real, fireable, tested, but NOT
/// bound by `Session.init` (see this file's module doc: no live gutter
/// exists today, so nothing binds them by default — a config/test opts in
/// explicitly, exactly like any other mesh slot).
pub fn bindDefaultGutter(c: *container.Container) !void {
    const all: container.Predicate = .{ .all = &.{} };
    const owner = "core:gutter";
    try c.bind(.{ .slot = "ui/gutter-segment", .provider = .{ .ui_provider = .{ .call = lineNumberProvider } }, .predicate = all, .tier = .core, .priority = 100, .owner = owner, .decl_index = 0 });
    try c.bind(.{ .slot = "ui/gutter-segment", .provider = .{ .ui_provider = .{ .call = diagMarksProvider } }, .predicate = all, .tier = .core, .priority = 90, .owner = owner, .decl_index = 1 });
    try c.bind(.{ .slot = "ui/gutter-segment", .provider = .{ .ui_provider = .{ .call = breakpointMarksProvider } }, .predicate = all, .tier = .core, .priority = 80, .owner = owner, .decl_index = 2 });
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
    try c.bind(.{ .slot = "ui/statusline-seg", .provider = .{ .ui_provider = .{ .call = Extra.call } }, .predicate = .{ .all = &.{} }, .tier = .config, .priority = 0, .owner = "test-plugin" });

    var args: StatuslineArgs = .{ .facts = .{ .mode = "normal" }, .file = "a.zig", .theme = &theme };
    const with_extra = try fireStatusline(&c, gpa, &args);
    defer freeSegs(gpa, with_extra);
    try t.expectEqual(@as(usize, 3), with_extra.len); // extra, mode, file
    try t.expectEqualStrings("[extra]", with_extra[0].text);
    try t.expectEqualStrings(" normal ", with_extra[1].text);
    try t.expectEqualStrings("a.zig", with_extra[2].text);

    c.unbindOwnerExact("test-plugin");
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
    const dl = try store.claim(gpa, &doc, "diagnostics", .local, "test");
    // A diagnostic on line 2 ("two", byte range [4,7)).
    try dl.publishSpans(gpa, &.{.{ .start = 4, .end = 5, .kind = 1, .message = "bad" }});

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

test {
    std.testing.refAllDecls(@This());
}
