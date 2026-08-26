//! e2e/popup-layout — rendering P2's guard (north-star-plan rendering P1/P2):
//! P1 (commit 2088854) re-expressed the completion popup + hover box through
//! one generic `popup.drawCaretSurface`, and in doing so found
//! `doc/rendering.md`'s "the snapshot tests are the guard" claim was
//! ASPIRATIONAL — `ed.snapshot`/`.snapshotPanes` write best-effort `.ppm`
//! artifacts that are never asserted, and the LSP e2e tests assert `Pick`
//! state + echo text, never rendered output. P2 (consumer-emits-scene) moved
//! the picker's scene-building into `core.pick.Pick.buildSurface` and the
//! picker dock onto the same generic `core.surface.Surface` vocabulary
//! (`popup.drawDockSurface`) — this file is the real gate for both.
//!
//! DESIGN CHOICE, made deliberately: pixel snapshots are brittle (font
//! rasterization, hinting, HiDPI) — the guard needs to be LAYOUT-level:
//! assert the GEOMETRY + CONTENT of the laid-out popup (box rect, flip
//! direction, per-row text + column x-positions, selected-row index + fill,
//! info-panel rect + text, colors as theme-role IDENTITIES rather than raw
//! RGB) instead of raw pixels. `popup.layoutCaretSurface`/`layoutDockSurface`
//! (src/gfx/view/popup.zig) are the introspection seam this needed: they
//! split `drawCaretSurface`/`drawDockSurface`'s geometry DECISION from the
//! rects/runs they used to emit directly, so the decision is data a test
//! can assert on. That's the PRIMARY gate here (every scenario below). One
//! scenario ALSO rasterizes and hashes the popup's own bounding-box pixels
//! as a coarse SMOKE check — belt and braces, not the primary signal (a hash
//! tells you SOMETHING changed, never what — that's what the layout
//! assertion is for).
//!
//! Every scenario drives the REAL pipeline: a headless `Editor` (the real
//! `app_session.Session` — builtins, buffer commands, the completion caps
//! consumer, pick commands — everything `Session.init` wires unconditionally,
//! deliberately WITHOUT loading a config/plugin catalog: the shipped
//! buffer-word completion plugin (`src/guest/complete.zig`) is a SYNCHRONOUS
//! source ("it answers before returning" — see its own doc comment), so if
//! it were loaded it would race the fixture provider below and contaminate
//! the golden with real buffer words), a synthetic `edit/completion` caps
//! PROVIDER (`fireCompletion` below) registered the same way
//! `core/tests.zig`'s `instantWords` fixture is (an `.instant`-latency
//! handler that `push`es straight into the session — no LSP/zls dependency,
//! so this gate stays fast and deterministic), and the real
//! `Pick`/`caret_anchor` it produces. `ed.pick.buildSurface` builds the
//! `Surface` from that live state — never a hand-built `Surface` literal —
//! and `layoutCaretSurface`/`layoutDockSurface` lay it out exactly as
//! `View.build` (via `popup.drawSurfaces`) would. The hover scenario is the
//! one exception: driving the REAL `lsp` guest plugin against a live
//! language server is out of scope for a fast, deterministic gate (same
//! reasoning `fireCompletion`'s fixture exists for completion), so it builds
//! a `Surface` directly with `popup.textCaretSurface` — a plain "lines of
//! text anchored at an offset" builder, the same shape the `lsp` plugin's
//! own `wl_surface_caret`/`wl_surface_row`/`wl_surface_span` calls produce
//! on the other side of the membrane (see `src/guest/lsp.zig`'s
//! `presentHover`) — the same way `gfx/harness.zig`'s own tests hand a `Hud`
//! straight to `View.build`.
//!
//! RECORD FLAG: mirrors `latency_test.zig`/build.zig's `-Drecord-latency`
//! idiom exactly — see build.zig's `popup_layout_mod` for why record mode is
//! a SEPARATE module object (a comptime `popup_layout_options.record_popup_layout`, not a
//! runtime flag) scoped to its OWN `e2e-popup-layout` step, so a plain `zig
//! build test -Drecord-popup-layout=true` cannot silently overwrite the
//! committed goldens as a side effect of an ordinary test run:
//!   zig build e2e-popup-layout                                # compare
//!   zig build e2e-popup-layout -Drecord-popup-layout=true      # re-record

const std = @import("std");
const t = std.testing;
const h = @import("harness.zig");
const popup_golden = @import("popup_golden.zig");
const popup_layout_options = @import("popup_layout_options");
const log = std.log.scoped(.@"e2e-popup-layout");

const core = h.core;
const view = h.view;
const region = h.region;
const scene = h.scene;
const gfx_harness = h.gfx_harness;
const Editor = h.Editor;
const capability = core.capability;
const popup = view.popup;

const baseline_path = "src/e2e/popup_layout_baseline.zon";

/// Open a new (empty) file and seed it with `text` directly through the real
/// `core.Editor` insert path — the same data-level seeding
/// `gfx/harness.zig`'s own fixtures use. What's under guard here is the
/// pick/hover → Surface → layout path, not vim motion fidelity (already
/// covered elsewhere in this suite), so scenarios don't need to type every
/// character through the keymap.
fn openFixtureBuffer(gpa: std.mem.Allocator, ed: *Editor, name: []const u8, text: []const u8) !void {
    ed.runStr("open", name);
    try ed.buffers.active().textEditor().?.insertText(gpa, text);
}

/// A synthetic `edit/completion` provider: pushes whatever `data` points at,
/// synchronously, ignoring the request entirely — deterministic, and (being
/// `.instant`) answered inline during `fire()`, before `complete`'s handler
/// even returns (see `core/complete_ui.zig`'s `fireHandler`, which polls
/// once right after firing). No settle() loop needed, and no real
/// buffer-word/LSP provider races it (those are async plugins, so they
/// haven't answered yet by the time this test inspects the pick).
fn fixtureCompletionHandler(data: ?*anyopaque, caps: *core.Caps, req: *const capability.Request) anyerror!void {
    const items: *[]capability.CompletionItem = @ptrCast(@alignCast(data.?));
    caps.push(req.session, .{ .id = "fixture.popup-layout", .latency = .instant }, .{ .completion = items.* }) catch {};
}

/// Place the cursor at `cursor_off`, register the fixture provider (`items`
/// must outlive this call — a stack local in the caller is fine, since the
/// handler above runs SYNCHRONOUSLY inside `run("complete")`), and fire the
/// real `complete` command — the same command `C-n`/LSP completion binds to.
fn fireCompletion(ed: *Editor, items: *[]capability.CompletionItem, cursor_off: usize) !void {
    ed.buffers.active().textEditor().?.placeCursor(cursor_off);
    try ed.caps.register(.{
        .capability = "edit/completion",
        .id = "fixture.popup-layout",
        .latency = .instant,
        .handler = fixtureCompletionHandler,
        .data = @ptrCast(items),
    });
    ed.run("complete");
}

const Frame = struct { v: *view.View, built: view.Built };

/// Build ONE frame at a DELIBERATELY chosen size (the geometry knob every
/// flip/clamp scenario below needs — same idiom `gfx/harness.zig`'s own
/// tests use, picking `w`/`h` per scenario). Real `View.build`, over the
/// real buffer/HUD; `Built.body` is the exact rect `drawPick`/`drawHover`
/// hand `drawCaretSurface` — see `View.zig`'s `Built.body` doc for why it's
/// exposed instead of a test recomputing the chrome-carve formula.
fn buildFrame(ed: *Editor, gpa: std.mem.Allocator, hud: view.Hud, fw: u32, fh: u32) !Frame {
    const v = try ed.ensureView();
    const frame: region.Rect = .{ .x = 0, .y = 0, .w = @floatFromInt(fw), .h = @floatFromInt(fh) };
    const projection = scene.Mat4.ortho(0, @floatFromInt(fw), @floatFromInt(fh), 0, -1, 1);
    const w2p = scene.mvpToScenePixel(projection, @floatFromInt(fw), @floatFromInt(fh)) orelse unreachable;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    v.resetFrame();
    var top_row: usize = 0;
    const built = try v.build(arena.allocator(), ed.buffers.active().textEditor().?, hud, &top_row, frame, .{}, w2p);
    return .{ .v = v, .built = built };
}

/// FNV/Wyhash of a pixel sub-rect's raw RGBA bytes — the coarse pixel-smoke
/// check (belt-and-braces on ONE scenario; see this file's doc comment).
fn hashBox(gpa: std.mem.Allocator, pixels: []const u8, fw: u32, x0: u32, y0: u32, x1: u32, y1: u32) !u64 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    var y = y0;
    while (y < y1) : (y += 1) {
        const row_start = (@as(usize, y) * fw + x0) * 4;
        const row_end = (@as(usize, y) * fw + x1) * 4;
        try buf.appendSlice(gpa, pixels[row_start..row_end]);
    }
    return std.hash.Wyhash.hash(0, buf.items);
}

/// Record mode: stash `(name, cl, pixel_hash)` for the final `saveGoldens`.
/// Compare mode: diff `cl`'s canonical ZON text against the loaded golden's
/// (see `popup_golden.layoutText`'s doc for why text-equality, not a
/// hand-rolled structural comparator) and flip `any_mismatch` on a miss —
/// the mismatch is logged with BOTH texts, so a failure names the case and
/// shows exactly what moved.
fn checkOrRecord(
    gpa: std.mem.Allocator,
    record_cases: *std.ArrayList(popup_golden.Golden),
    loaded: ?popup_golden.GoldenFile,
    any_mismatch: *bool,
    name: []const u8,
    cl: popup.CaretLayout,
    pixel_hash: u64,
) !void {
    if (popup_layout_options.record_popup_layout) {
        try record_cases.append(gpa, .{ .name = name, .layout = cl, .pixel_hash = pixel_hash });
        return;
    }
    const golden = popup_golden.find(loaded.?, name) orelse {
        log.err("{s}: no golden entry — run `zig build e2e-popup-layout -Drecord-popup-layout=true` to record it", .{name});
        any_mismatch.* = true;
        return;
    };
    const got_text = try popup_golden.layoutText(gpa, cl);
    defer gpa.free(got_text);
    const want_text = try popup_golden.layoutText(gpa, golden.layout);
    defer gpa.free(want_text);
    if (!std.mem.eql(u8, got_text, want_text)) {
        log.err("{s}: layout mismatch\n--- got ---\n{s}\n--- want ---\n{s}\n", .{ name, got_text, want_text });
        any_mismatch.* = true;
    }
    if (golden.pixel_hash != 0 and golden.pixel_hash != pixel_hash) {
        log.err("{s}: pixel-smoke hash mismatch: got {d}, want {d}", .{ name, pixel_hash, golden.pixel_hash });
        any_mismatch.* = true;
    }
}

/// `checkOrRecord`'s counterpart for a picker-DOCK layout (`popup.DockLayout`
/// — no pixel-smoke hash; the caret scenario above already covers that belt-
/// and-braces check).
fn checkOrRecordDock(
    gpa: std.mem.Allocator,
    record_cases: *std.ArrayList(popup_golden.DockGolden),
    loaded: ?popup_golden.GoldenFile,
    any_mismatch: *bool,
    name: []const u8,
    dl: popup.DockLayout,
) !void {
    if (popup_layout_options.record_popup_layout) {
        try record_cases.append(gpa, .{ .name = name, .layout = dl });
        return;
    }
    const golden = popup_golden.findDock(loaded.?, name) orelse {
        log.err("{s}: no dock golden entry — run `zig build e2e-popup-layout -Drecord-popup-layout=true` to record it", .{name});
        any_mismatch.* = true;
        return;
    };
    const got_text = try popup_golden.dockLayoutText(gpa, dl);
    defer gpa.free(got_text);
    const want_text = try popup_golden.dockLayoutText(gpa, golden.layout);
    defer gpa.free(want_text);
    if (!std.mem.eql(u8, got_text, want_text)) {
        log.err("{s}: dock layout mismatch\n--- got ---\n{s}\n--- want ---\n{s}\n", .{ name, got_text, want_text });
        any_mismatch.* = true;
    }
}

test "e2e/popup-layout: caret-popup layout goldens" {
    const gpa = t.allocator;

    var loaded: ?popup_golden.GoldenFile = null;
    defer if (loaded) |f| std.zon.parse.free(gpa, f);
    if (!popup_layout_options.record_popup_layout) {
        loaded = popup_golden.loadGoldens(gpa, baseline_path) catch |err| {
            log.warn("no goldens at {s} ({t}) — run `zig build e2e-popup-layout -Drecord-popup-layout=true` to record them", .{ baseline_path, err });
            return error.SkipZigTest;
        };
    }

    var record_cases: std.ArrayList(popup_golden.Golden) = .empty;
    defer record_cases.deinit(gpa);
    var record_dock_cases: std.ArrayList(popup_golden.DockGolden) = .empty;
    defer record_dock_cases.deinit(gpa);
    var any_mismatch = false;

    // Every scenario's `Surface`/`CaretLayout` is built into THIS ONE arena,
    // shared across scenarios and freed only at the test's end — so the
    // slices stashed into `record_cases` (record mode) or diffed inline
    // (compare mode) stay valid regardless of which scenario's `Editor` has
    // since been torn down.
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const scratch = arena.allocator();

    // ── 1. Below-caret, annotation column, selected row mid-list ──────
    // Also carries the belt-and-braces pixel-smoke hash (see this file's
    // doc comment for why it's exactly ONE scenario, not every one).
    {
        var ed_storage: Editor = undefined;
        try Editor.init(gpa, &ed_storage);
        defer ed_storage.deinit();
        const ed = &ed_storage;
        try openFixtureBuffer(gpa, ed, "below.txt", "line zero\nline one\nline two\nline three\nline four\nline five\n");
        const rope = ed.buffers.active().textEditor().?.text();
        const cur_off = rope.lineRange(2).start;

        var items = [_]capability.CompletionItem{
            .{ .text = @constCast("alpha"), .detail = @constCast("i32"), .kind = 6, .rank = 0 },
            .{ .text = @constCast("bravo"), .detail = @constCast("i32"), .kind = 6, .rank = 1 },
            .{ .text = @constCast("charlie"), .detail = @constCast("i32"), .kind = 6, .rank = 2 },
            .{ .text = @constCast("delta"), .detail = @constCast("i32"), .kind = 6, .rank = 3 },
            .{ .text = @constCast("echo"), .detail = @constCast("i32"), .kind = 6, .rank = 4 },
            .{ .text = @constCast("foxtrot"), .detail = @constCast("i32"), .kind = 6, .rank = 5 },
        };
        var items_slice: []capability.CompletionItem = &items;
        try fireCompletion(ed, &items_slice, cur_off);
        try t.expect(ed.pick.active);
        try t.expect(ed.pick.caret_anchor != null);
        ed.run("pick-next");
        ed.run("pick-next"); // selected = 2, mid-list

        const fw: u32 = 800;
        const fh: u32 = 600;
        var fr = try buildFrame(ed, gpa, .{ .mode = ed.mode(), .pick = ed.pick }, fw, fh);
        defer fr.built.deinit(gpa);

        const surf = ed.pick.buildSurface(scratch, view.Hud.max_pick_rows) orelse return error.NoSurface;
        const cl = (try popup.layoutCaretSurface(fr.v, scratch, &surf, fr.built.body)) orelse return error.NoLayout;

        try t.expect(!cl.flipped_above);
        try t.expectEqual(@as(usize, 6), cl.rows.len);
        try t.expectEqual(@as(usize, 2), cl.col_x.len); // the annotation column is present
        try t.expect(cl.rows[2].selected);

        const pixels = try gfx_harness.rasterize(gpa, fr.v, &.{fr.built.items}, fw, fh);
        defer gpa.free(pixels);
        const x0: u32 = @intFromFloat(@floor(cl.x));
        const y0: u32 = @intFromFloat(@floor(cl.y));
        const x1: u32 = @min(fw, @as(u32, @intFromFloat(@ceil(cl.x + cl.w))));
        const y1: u32 = @min(fh, @as(u32, @intFromFloat(@ceil(cl.y + cl.h))));
        const phash = try hashBox(gpa, pixels, fw, x0, y0, x1, y1);

        try checkOrRecord(gpa, &record_cases, loaded, &any_mismatch, "below_caret_annotated_selected_mid", cl, phash);
    }

    // ── 2. Flip-above when the box would overflow the body's bottom ───
    {
        var ed_storage: Editor = undefined;
        try Editor.init(gpa, &ed_storage);
        defer ed_storage.deinit();
        const ed = &ed_storage;
        try openFixtureBuffer(gpa, ed, "flip.txt", "l0\nl1\nl2\nl3\nl4");
        const v0 = try ed.ensureView();
        const margin: f32 = 8; // View.zig's private frame-inset constant (also hardcoded by gfx/harness.zig's own tests)
        const rows_visible: f32 = 5; // == the buffer's line count, so the last line sits at the body's bottom
        const fw: u32 = 800;
        const fh: u32 = @intFromFloat(2 * margin + v0.line_h * (1 + rows_visible)); // +1 row for the status line
        const rope = ed.buffers.active().textEditor().?.text();
        const cur_off = rope.lineRange(4).start; // the last (bottom) line

        var items = [_]capability.CompletionItem{
            .{ .text = @constCast("i0"), .rank = 0 },
            .{ .text = @constCast("i1"), .rank = 1 },
            .{ .text = @constCast("i2"), .rank = 2 },
            .{ .text = @constCast("i3"), .rank = 3 },
        };
        var items_slice: []capability.CompletionItem = &items;
        try fireCompletion(ed, &items_slice, cur_off);
        try t.expect(ed.pick.active);

        var fr = try buildFrame(ed, gpa, .{ .mode = ed.mode(), .pick = ed.pick }, fw, fh);
        defer fr.built.deinit(gpa);
        const surf = ed.pick.buildSurface(scratch, view.Hud.max_pick_rows) orelse return error.NoSurface;
        const cl = (try popup.layoutCaretSurface(fr.v, scratch, &surf, fr.built.body)) orelse return error.NoLayout;

        try t.expect(cl.flipped_above);
        try checkOrRecord(gpa, &record_cases, loaded, &any_mismatch, "flip_above_near_bottom", cl, 0);
    }

    // ── 3. Clamp at the right edge ─────────────────────────────────────
    {
        var ed_storage: Editor = undefined;
        try Editor.init(gpa, &ed_storage);
        defer ed_storage.deinit();
        const ed = &ed_storage;
        try openFixtureBuffer(gpa, ed, "clamp.txt", "abcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyz");
        const v0 = try ed.ensureView();
        const margin: f32 = 8;
        const body_cols: f32 = 20; // narrow body — the popup (10 cols wide) doesn't fit past column 10
        const fw: u32 = @intFromFloat(2 * margin + v0.cell_w * body_cols);
        const fh: u32 = 600;
        const rope = ed.buffers.active().textEditor().?.text();
        const cur_off = rope.lineRange(0).start + 25; // column 25 — well past body_cols - box_w

        var items = [_]capability.CompletionItem{.{ .text = @constCast("ok"), .rank = 0 }};
        var items_slice: []capability.CompletionItem = &items;
        try fireCompletion(ed, &items_slice, cur_off);

        var fr = try buildFrame(ed, gpa, .{ .mode = ed.mode(), .pick = ed.pick }, fw, fh);
        defer fr.built.deinit(gpa);
        const surf = ed.pick.buildSurface(scratch, view.Hud.max_pick_rows) orelse return error.NoSurface;
        const cl = (try popup.layoutCaretSurface(fr.v, scratch, &surf, fr.built.body)) orelse return error.NoLayout;

        // Clamped flush to the body's right edge, never past it.
        try t.expectApproxEqAbs(fr.built.body.x + fr.built.body.w, cl.x + cl.w, 0.5);
        try checkOrRecord(gpa, &record_cases, loaded, &any_mismatch, "clamp_right_edge", cl, 0);
    }

    // ── 4a. Info panel right-of-box (room to spare) ────────────────────
    {
        var ed_storage: Editor = undefined;
        try Editor.init(gpa, &ed_storage);
        defer ed_storage.deinit();
        const ed = &ed_storage;
        try openFixtureBuffer(gpa, ed, "inforight.txt", "line zero\nline one\nline two\n");
        const rope = ed.buffers.active().textEditor().?.text();
        const cur_off = rope.lineRange(1).start;

        var items = [_]capability.CompletionItem{
            .{ .text = @constCast("alpha"), .documentation = @constCast("First line of docs.\nSecond, longer line of docs."), .rank = 0 },
            .{ .text = @constCast("bravo"), .rank = 1 },
        };
        var items_slice: []capability.CompletionItem = &items;
        try fireCompletion(ed, &items_slice, cur_off); // selected = 0 (has documentation)

        var fr = try buildFrame(ed, gpa, .{ .mode = ed.mode(), .pick = ed.pick }, 800, 600);
        defer fr.built.deinit(gpa);
        const surf = ed.pick.buildSurface(scratch, view.Hud.max_pick_rows) orelse return error.NoSurface;
        const cl = (try popup.layoutCaretSurface(fr.v, scratch, &surf, fr.built.body)) orelse return error.NoLayout;

        const info = cl.info orelse return error.NoInfoPanel;
        try t.expect(!info.flipped_left);
        try t.expect(info.x > cl.x + cl.w);
        try t.expectEqual(@as(usize, 2), info.lines.len);
        try checkOrRecord(gpa, &record_cases, loaded, &any_mismatch, "info_panel_right", cl, 0);
    }

    // ── 4b. Info panel's LEFT fallback, when the box hugs the right edge ──
    {
        var ed_storage: Editor = undefined;
        try Editor.init(gpa, &ed_storage);
        defer ed_storage.deinit();
        const ed = &ed_storage;
        try openFixtureBuffer(gpa, ed, "infoleft.txt", "abcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyz");
        const v0 = try ed.ensureView();
        const margin: f32 = 8;
        const body_cols: f32 = 20;
        const fw: u32 = @intFromFloat(2 * margin + v0.cell_w * body_cols);
        const fh: u32 = 600;
        const rope = ed.buffers.active().textEditor().?.text();
        const cur_off = rope.lineRange(0).start + 25;

        var items = [_]capability.CompletionItem{
            .{ .text = @constCast("ok"), .documentation = @constCast("Docs here.\nMore docs."), .rank = 0 },
        };
        var items_slice: []capability.CompletionItem = &items;
        try fireCompletion(ed, &items_slice, cur_off);

        var fr = try buildFrame(ed, gpa, .{ .mode = ed.mode(), .pick = ed.pick }, fw, fh);
        defer fr.built.deinit(gpa);
        const surf = ed.pick.buildSurface(scratch, view.Hud.max_pick_rows) orelse return error.NoSurface;
        const cl = (try popup.layoutCaretSurface(fr.v, scratch, &surf, fr.built.body)) orelse return error.NoLayout;

        const info = cl.info orelse return error.NoInfoPanel;
        try t.expect(info.flipped_left);
        try checkOrRecord(gpa, &record_cases, loaded, &any_mismatch, "info_panel_left_fallback", cl, 0);
    }

    // ── 5. Hover box, multi-line ────────────────────────────────────────
    // `Hud.hover` has no live producer today (see this file's doc comment):
    // built directly, the same way `gfx/harness.zig`'s own tests hand a
    // `Hud` straight to `View.build`.
    {
        var ed_storage: Editor = undefined;
        try Editor.init(gpa, &ed_storage);
        defer ed_storage.deinit();
        const ed = &ed_storage;
        try openFixtureBuffer(gpa, ed, "hover.txt", "target line for hover\nsecond line\n");
        const rope = ed.buffers.active().textEditor().?.text();
        const cur_off = rope.lineRange(0).start + 3;
        ed.buffers.active().textEditor().?.placeCursor(cur_off);

        const hover_text = "signature: fn example(x: i32) i32\nReturns x, unmodified.\nSee also: identity.";
        var fr = try buildFrame(ed, gpa, .{ .mode = ed.mode(), .hover = .{ .text = hover_text, .offset = cur_off } }, 800, 600);
        defer fr.built.deinit(gpa);

        const surf = popup.textCaretSurface(scratch, hover_text, cur_off, view.Hud.max_hover_rows) orelse return error.NoSurface;
        const cl = (try popup.layoutCaretSurface(fr.v, scratch, &surf, fr.built.body)) orelse return error.NoLayout;

        try t.expectEqual(@as(usize, 3), cl.rows.len);
        try t.expectEqual(@as(usize, 1), cl.col_x.len); // one column only, no annotation
        for (cl.rows) |row| try t.expect(!row.selected);

        try checkOrRecord(gpa, &record_cases, loaded, &any_mismatch, "hover_multiline", cl, 0);
    }

    // ── 6. Empty-note rows: no annotation column at all ─────────────────
    {
        var ed_storage: Editor = undefined;
        try Editor.init(gpa, &ed_storage);
        defer ed_storage.deinit();
        const ed = &ed_storage;
        try openFixtureBuffer(gpa, ed, "nonotes.txt", "line zero\nline one\n");
        const rope = ed.buffers.active().textEditor().?.text();
        const cur_off = rope.lineRange(1).start;

        // Default `.kind`/`.detail` (0/"") → `complete_ui.annotate` returns ""
        // → `pickSurface` never adds a column-1 span for ANY row.
        var items = [_]capability.CompletionItem{
            .{ .text = @constCast("plain1"), .rank = 0 },
            .{ .text = @constCast("plain2"), .rank = 1 },
            .{ .text = @constCast("plain3"), .rank = 2 },
        };
        var items_slice: []capability.CompletionItem = &items;
        try fireCompletion(ed, &items_slice, cur_off);

        var fr = try buildFrame(ed, gpa, .{ .mode = ed.mode(), .pick = ed.pick }, 800, 600);
        defer fr.built.deinit(gpa);
        const surf = ed.pick.buildSurface(scratch, view.Hud.max_pick_rows) orelse return error.NoSurface;
        const cl = (try popup.layoutCaretSurface(fr.v, scratch, &surf, fr.built.body)) orelse return error.NoLayout;

        try t.expectEqual(@as(usize, 1), cl.col_x.len);
        try checkOrRecord(gpa, &record_cases, loaded, &any_mismatch, "empty_note_rows", cl, 0);
    }

    // ── 7. The scroll window: selected beyond max_rows ──────────────────
    {
        var ed_storage: Editor = undefined;
        try Editor.init(gpa, &ed_storage);
        defer ed_storage.deinit();
        const ed = &ed_storage;
        try openFixtureBuffer(gpa, ed, "scroll.txt", "line zero\nline one\n");
        const rope = ed.buffers.active().textEditor().?.text();
        const cur_off = rope.lineRange(1).start;

        var items: [12]capability.CompletionItem = undefined;
        inline for (0..12) |i| {
            items[i] = .{ .text = @constCast(std.fmt.comptimePrint("item{d:0>2}", .{i})), .rank = i };
        }
        var items_slice: []capability.CompletionItem = &items;
        try fireCompletion(ed, &items_slice, cur_off);
        for (0..10) |_| ed.run("pick-next"); // 0 -> 10
        try t.expectEqual(@as(usize, 10), ed.pick.selected);

        var fr = try buildFrame(ed, gpa, .{ .mode = ed.mode(), .pick = ed.pick }, 800, 600);
        defer fr.built.deinit(gpa);
        const surf = ed.pick.buildSurface(scratch, view.Hud.max_pick_rows) orelse return error.NoSurface;
        const cl = (try popup.layoutCaretSurface(fr.v, scratch, &surf, fr.built.body)) orelse return error.NoLayout;

        try t.expectEqual(@as(usize, view.Hud.max_pick_rows), cl.rows.len);
        try t.expectEqualStrings("item03", cl.rows[0].spans[0].text);
        try t.expectEqualStrings("item10", cl.rows[cl.rows.len - 1].spans[0].text);
        try t.expect(cl.rows[cl.rows.len - 1].selected);
        try checkOrRecord(gpa, &record_cases, loaded, &any_mismatch, "scroll_window_beyond_max_rows", cl, 0);
    }

    // ── 8. The picker DOCK: header row + item rows, selected mid-list ───
    // A plain (non-caret) pick — `Pick.open`, the same door `find-file`/
    // `buffer-switch`/the command palette use — has no `caret_anchor`, so
    // `Pick.buildSurface` takes the `.bottom` branch: the dock. Unlike the
    // caret popup's completion list, the dock never went through a caps
    // fixture (no LSP/completion involved), so this is `Pick.open` driven
    // directly, exactly the pattern `core/System.zig`'s own pick tests use.
    {
        var ed_storage: Editor = undefined;
        try Editor.init(gpa, &ed_storage);
        defer ed_storage.deinit();
        const ed = &ed_storage;

        const entries = [_]core.pick.Entry{
            .{ .text = "alpha", .doc = "first" },
            .{ .text = "bravo", .doc = "second" },
            .{ .text = "charlie", .doc = "third" },
            .{ .text = "delta", .doc = "" },
            .{ .text = "echo", .doc = "fifth" },
        };
        try ed.pick.open(ed.ctx, "find", &entries, .{ .handler = noopAccept });
        ed.run("pick-next");
        ed.run("pick-next"); // selected = 2 ("charlie")
        try t.expect(ed.pick.active);
        try t.expect(ed.pick.caret_anchor == null); // the dock, not a caret popup

        const v = try ed.ensureView();
        const dock_h = v.pickDockHeight(ed.pick);
        const dock: region.Rect = .{ .x = 0, .y = 600 - dock_h, .w = 800, .h = dock_h };
        const surf = ed.pick.buildSurface(scratch, view.Hud.max_pick_rows) orelse return error.NoSurface;
        try t.expectEqual(core.surface.Placement.bottom, surf.placement);
        const dl = (try popup.layoutDockSurface(v, scratch, &surf, dock)) orelse return error.NoLayout;

        try t.expectEqual(@as(usize, 6), dl.rows.len); // header + 5 items
        try t.expect(!dl.rows[0].selected);
        try t.expectEqual(popup.SpanRole.normal, dl.rows[0].role); // the query line
        try t.expect(std.mem.indexOf(u8, dl.rows[0].text, "find") != null);
        try t.expect(std.mem.indexOf(u8, dl.rows[0].text, "[3/5]") != null);
        try t.expect(dl.rows[3].selected); // header(0) + charlie's item index (2) = 3
        try t.expectEqual(popup.SpanRole.muted, dl.rows[1].role);
        try checkOrRecordDock(gpa, &record_dock_cases, loaded, &any_mismatch, "dock_selected_mid", dl);
    }

    // ── 9. The picker DOCK with zero matches: header only, still shows ──
    {
        var ed_storage: Editor = undefined;
        try Editor.init(gpa, &ed_storage);
        defer ed_storage.deinit();
        const ed = &ed_storage;

        try ed.pick.open(ed.ctx, "empty", &.{}, .{ .handler = noopAccept });
        try t.expect(ed.pick.active);

        const v = try ed.ensureView();
        const dock_h = v.pickDockHeight(ed.pick);
        const dock: region.Rect = .{ .x = 0, .y = 600 - dock_h, .w = 800, .h = dock_h };
        const surf = ed.pick.buildSurface(scratch, view.Hud.max_pick_rows) orelse return error.NoSurface;
        const dl = (try popup.layoutDockSurface(v, scratch, &surf, dock)) orelse return error.NoLayout;

        try t.expectEqual(@as(usize, 1), dl.rows.len); // header only, no item rows
        try t.expect(!dl.rows[0].selected);
        try t.expect(std.mem.indexOf(u8, dl.rows[0].text, "[0/0]") != null);
        try checkOrRecordDock(gpa, &record_dock_cases, loaded, &any_mismatch, "dock_no_matches", dl);
    }

    if (popup_layout_options.record_popup_layout) {
        try popup_golden.saveGoldens(gpa, baseline_path, .{
            .note = "recorded via `zig build e2e-popup-layout -Drecord-popup-layout=true`",
            .cases = record_cases.items,
            .dock_cases = record_dock_cases.items,
        });
        log.info("recorded {d} case(s), {d} dock case(s) to {s}", .{ record_cases.items.len, record_dock_cases.items.len, baseline_path });
        return;
    }

    try t.expect(!any_mismatch);
}

fn noopAccept(ctx: *core.command.Context, data: ?*anyopaque, outcome: core.pick.Outcome) anyerror!void {
    _ = ctx;
    _ = data;
    _ = outcome;
}
