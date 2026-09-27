//! e2e/bench-syntax — the syntax-highlight timing instrument.
//!
//! `bench-raster` times drawing a frame that is already built and carries no
//! highlight at all; `e2e-latency` times dispatch and deliberately excludes the
//! wake that follows. Neither can see the question this answers: once a
//! JavaScript buffer is open in the REAL app (full config, real providers, the
//! same `Application.advance` the desktop runs), how long until the frame on
//! screen is highlighted — after opening it, after paging, after jumping to the
//! bottom and back, after typing at the bottom?
//!
//! "Highlighted" is judged on the frame the app actually SHOWS: the rows the
//! last build laid out must lie inside the published highlight window, and that
//! window must carry classes there. A frame that was built from a window around
//! some other scroll position counts as unhighlighted, however fast it was.
//! Every scenario reports the wall time of the wake(s) it took and how many
//! wakes passed before the shown frame was highlighted; "never" means no amount
//! of further wakes without input would have highlighted it.
//!
//! Also reported: the costs underneath, measured directly on core — highlight
//! query compile, full parse, the per-window query, and the whole-document
//! query — so a scenario number can be attributed to a stage.
//!
//! Run: `zig build bench-syntax -Doptimize=ReleaseFast` (set WEFT_BENCH_JS to a
//! real .js file to use it instead of the generated one). The plain `test` step
//! runs this with one iteration as a smoke check of the path, never as a gate.

const std = @import("std");
const t = std.testing;
const h = @import("harness.zig");
const lang = @import("language_support.zig");
const core = h.core;
const stemma = @import("stemma");
const latency_options = @import("latency_options");

const nowNs = core.task.nowNs;

/// A deterministic ~8000-line JavaScript module: classes, functions, template
/// strings, regexes, comments — the shapes the highlight query spends its time
/// on, in the proportions of ordinary hand-written code.
fn generateJs(gpa: std.mem.Allocator) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, "// Generated benchmark module.\n'use strict';\n\nimport { readFile } from 'node:fs/promises';\n\n");
    var i: usize = 0;
    while (i < 400) : (i += 1) {
        try out.print(gpa,
            \\/**
            \\ * Widget number {d}: holds a value and knows how to render it.
            \\ */
            \\export class Widget{d} extends Base {{
            \\  constructor(name, count = {d}) {{
            \\    super(name);
            \\    this.count = count;
            \\    this.pattern = /^w{d}-[a-z]+$/i;
            \\  }}
            \\
            \\  render(target) {{
            \\    const label = `widget ${{this.name}} #{d}: ${{this.count * 2}}`;
            \\    if (this.pattern.test(label) && target !== null) {{
            \\      return target.append(label, {{ id: {d}, visible: true }});
            \\    }}
            \\    return undefined; // nothing to draw
            \\  }}
            \\}}
            \\
            \\async function load{d}(path) {{
            \\  try {{
            \\    const text = await readFile(path, 'utf8');
            \\    return text.split('\n').map((line, n) => line.trim() + n);
            \\  }} catch (err) {{
            \\    console.error("load{d} failed", err);
            \\    return [];
            \\  }}
            \\}}
            \\
            \\
        , .{ i, i, i, i, i, i, i, i });
    }
    return out.toOwnedSlice(gpa);
}

const shownHighlighted = lang.shownHighlighted;

const Sample = struct {
    /// Wall time from the input to the first highlighted frame (or to the
    /// give-up point).
    ns: u64,
    /// Wall time of the input plus the one wake it causes — the frame a person
    /// sees first, highlighted or not.
    first_ns: u64,
    /// Wakes it took; 0 = never highlighted within the budget.
    wakes: usize,
};

/// Note the input the way a key press does, then advance wakes with no further
/// input until the shown frame is highlighted. The first wake is the one the
/// input itself causes. Bounded by `budget_ns` of spinning: the desktop loop
/// would be asleep with nothing to wake it but the pool's completion fd, so
/// running out of budget means "stays unhighlighted until the next key".
fn wakeUntilHighlighted(ed: *h.Editor, t0: u64, budget_ns: u64) Sample {
    ed.application.noteInput();
    var wakes: usize = 0;
    var first_ns: u64 = 0;
    while (true) {
        ed.applyWindow(); // one ordinary application wake
        wakes += 1;
        if (wakes == 1) first_ns = nowNs() - t0;
        if (shownHighlighted(ed)) return .{ .ns = nowNs() - t0, .first_ns = first_ns, .wakes = wakes };
        if (nowNs() - t0 > budget_ns) return .{ .ns = nowNs() - t0, .first_ns = first_ns, .wakes = 0 };
    }
}

/// Run a command the way a bound key does, without the harness's own wake
/// (the scenario counts wakes itself).
fn command(ed: *h.Editor, name: []const u8, args: []const core.command.Value) void {
    _ = core.command.run(ed.commands, ed.ctx, name, args) catch {};
}

fn median(xs: []u64) u64 {
    std.mem.sort(u64, xs, {}, std.sort.asc(u64));
    return xs[xs.len / 2];
}

fn ms(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / 1e6;
}

const Scenario = enum { open, page_down, jump_bottom, jump_top, type_bottom, redraw };

fn report(name: []const u8, samples: []Sample) void {
    var ns_buf: [64]u64 = undefined;
    var first_buf: [64]u64 = undefined;
    var never: usize = 0;
    var max_wakes: usize = 0;
    for (samples, 0..) |s, i| {
        ns_buf[i] = s.ns;
        first_buf[i] = s.first_ns;
        if (s.wakes == 0) never += 1;
        max_wakes = @max(max_wakes, s.wakes);
    }
    const n = samples.len;
    const med = median(ns_buf[0..n]);
    const first = median(first_buf[0..n]);
    std.debug.print("  {s:<12} highlighted: median {d:>9.3} ms best {d:>9.3} ms | first frame: median {d:>7.3} ms best {d:>7.3} ms | wakes<={d} never {d}/{d}\n", .{
        name, ms(med), ms(ns_buf[0]), ms(first), ms(first_buf[0]), max_wakes, never, n,
    });
}

test "e2e/bench-syntax: time to a highlighted frame on a large javascript buffer" {
    // The allocator a release build of the app runs on (main.zig): the testing
    // allocator captures a stack trace per allocation, which profiling showed
    // is most of what a wake costs under it — timing it would time the unwinder.
    // The smoke run in `test` keeps the leak-checking one.
    const gpa = if (latency_options.isolated) std.heap.c_allocator else t.allocator;
    const iters: usize = if (latency_options.isolated) 15 else 1;

    var app: h.App = undefined;
    try app.init(gpa);
    defer app.deinit();
    const ed = &app.ed;

    // The workload: a real file when one is named, else the generated module.
    const text = blk: {
        if (std.c.getenv("WEFT_BENCH_JS")) |p| {
            const path = std.mem.sliceTo(p, 0);
            if (path.len != 0) break :blk try core.file.readAlloc(gpa, path);
        }
        break :blk try generateJs(gpa);
    };
    defer gpa.free(text);
    try core.file.writeBytesMakingDirs(gpa, app.proj.root, "bench.js", text);
    const lines = std.mem.count(u8, text, "\n");
    std.debug.print("\nsyntax bench — {d} lines, {d} bytes, {d} iterations, wall time\n", .{ lines, text.len, iters });

    // ── Stage costs, measured directly on core ──
    {
        var rt: core.syntax.Runtime = .empty;
        defer rt.deinit(gpa);
        try rt.setSearchPath(gpa, @import("build_options").grammar_path);
        try rt.add(gpa, .{ .extensions = ".js", .grammar = "javascript", .symbol = "tree_sitter_javascript", .outline = @import("build_options").query_root ++ "/javascript-outline.scm" });
        const spec = rt.forPath("bench.js").?;
        var t0 = nowNs();
        _ = try rt.compiledFor(gpa, spec);
        const compile_ns = nowNs() - t0;

        var doc = try core.Document.init(gpa, "bench");
        defer doc.deinit(gpa);
        try doc.insert(gpa, 0, text);
        var parse_ns: [64]u64 = undefined;
        for (0..iters) |i| {
            t0 = nowNs();
            const syn = try core.syntax.Syntax.create(gpa, &rt, spec, &doc);
            parse_ns[i] = nowNs() - t0;
            syn.destroy();
        }
        const syn = try core.syntax.Syntax.create(gpa, &rt, spec, &doc);
        defer syn.destroy();
        const rope = doc.text();
        const rows = rope.lineCount();
        const Window = struct { name: []const u8, range: stemma.Range };
        const windows = [_]Window{
            .{ .name = "window@top", .range = .{ .start = 0, .end = rope.lineRange(@min(rows - 1, 200)).end } },
            .{ .name = "window@bottom", .range = .{ .start = rope.lineRange(rows -| 301).start, .end = rope.byteLen() } },
            .{ .name = "one screen@bot", .range = .{ .start = rope.lineRange(rows -| 60).start, .end = rope.byteLen() } },
            .{ .name = "whole document", .range = .{ .start = 0, .end = rope.byteLen() } },
        };
        std.debug.print("stages (core, direct):\n  query compile  {d:>9.3} ms (once per grammar)\n  full parse     {d:>9.3} ms (median)\n", .{ ms(compile_ns), ms(median(parse_ns[0..iters])) });
        for (windows) |w| {
            var paint_ns: [64]u64 = undefined;
            for (0..iters) |i| {
                t0 = nowNs();
                const classes = try syn.paint(gpa, w.range);
                paint_ns[i] = nowNs() - t0;
                gpa.free(classes);
            }
            std.debug.print("  paint {s:<14} {d:>9.3} ms (median, {d} bytes)\n", .{ w.name, ms(median(paint_ns[0..iters])), w.range.len() });
        }
        // The outline: what the breadcrumbs read — the whole file, or only
        // what overlaps the caret's byte (here, near the end of the file).
        const caret = rope.lineRange(rows -| 10).start + 4;
        const outlines = [_]Window{
            .{ .name = "whole document", .range = .{ .start = 0, .end = rope.byteLen() } },
            .{ .name = "caret byte", .range = .{ .start = caret, .end = caret + 1 } },
        };
        for (outlines) |w| {
            var out_ns: [64]u64 = undefined;
            var count: usize = 0;
            for (0..iters) |i| {
                var syms: std.ArrayList(core.syntax.Syntax.Sym) = .empty;
                t0 = nowNs();
                try syn.collectSymbols(gpa, &doc, w.range, &syms);
                out_ns[i] = nowNs() - t0;
                count = syms.items.len;
                for (syms.items) |s| gpa.free(s.name);
                syms.deinit(gpa);
            }
            std.debug.print("  outline {s:<14} {d:>7.3} ms (median, {d} symbols)\n", .{ w.name, ms(median(out_ns[0..iters])), count });
        }
    }

    // ── Scenarios, through the real app ──
    var results: [@typeInfo(Scenario).@"enum".fields.len][64]Sample = undefined;
    // How long to keep waking before calling a frame "never highlighted". The
    // initial parse is the slowest honest wait (tens of ms); this is well past it.
    // WEFT_BENCH_BUDGET_MS shortens it, so a profile of the bench is a profile
    // of the work rather than of the spin.
    const budget_ms: u64 = if (std.c.getenv("WEFT_BENCH_BUDGET_MS")) |v|
        std.fmt.parseInt(u64, std.mem.sliceTo(v, 0), 10) catch 2000
    else if (latency_options.isolated) 2000 else 300;
    const budget_ns: u64 = budget_ms * std.time.ns_per_ms;
    for (0..iters) |i| {
        // Open: a fresh buffer each time, so the initial parse is paid again.
        var t0 = nowNs();
        var bench_at: [std.fs.max_path_bytes]u8 = undefined;
        command(ed, "open", &.{.{ .string = h.Editor.asTyped("bench.js", &bench_at) }});
        results[@intFromEnum(Scenario.open)][i] = wakeUntilHighlighted(ed, t0, budget_ns);
        const syn = lang.attachedSyntax(ed) orelse return error.SyntaxDidNotAttach;
        const te = ed.buffers.active().textEditor().?;
        // The rest need a tree; the open scenario above already measured the
        // wait. Spin (no sleep) until the worker's tree has been adopted.
        const deadline = nowNs() + 5 * std.time.ns_per_s;
        while (syn.tree == null or syn.pending_initial != null) {
            _ = try syn.sync(gpa, &te.doc);
            if (nowNs() > deadline) return error.TreeNeverLanded;
        }
        ed.application.noteInput();
        ed.applyWindow();

        t0 = nowNs();
        command(ed, "scroll-page-down", &.{});
        results[@intFromEnum(Scenario.page_down)][i] = wakeUntilHighlighted(ed, t0, budget_ns);

        t0 = nowNs();
        te.moveTo(te.text().byteLen());
        results[@intFromEnum(Scenario.jump_bottom)][i] = wakeUntilHighlighted(ed, t0, budget_ns);

        t0 = nowNs();
        te.moveTo(0);
        results[@intFromEnum(Scenario.jump_top)][i] = wakeUntilHighlighted(ed, t0, budget_ns);

        // Park at the bottom with a frame drawn there, then type.
        te.moveTo(te.text().byteLen());
        ed.application.noteInput();
        ed.applyWindow();
        t0 = nowNs();
        try te.insertText(gpa, "x");
        results[@intFromEnum(Scenario.type_bottom)][i] = wakeUntilHighlighted(ed, t0, budget_ns);

        // A frame that changes nothing the text shows (a caret blink, a chip):
        // the tree, the scroll and the window are as the last frame left them,
        // so whatever it recomputes is pure overhead.
        ed.applyWindow();
        t0 = nowNs();
        results[@intFromEnum(Scenario.redraw)][i] = wakeUntilHighlighted(ed, t0, budget_ns);

        command(ed, "buffer-close-force", &.{});
        ed.application.noteInput();
        ed.applyWindow();
    }
    std.debug.print("scenarios (real app wake; input -> first highlighted frame | input -> first frame):\n", .{});
    inline for (@typeInfo(Scenario).@"enum".fields) |f| report(f.name, results[f.value][0..iters]);
    // What every frame above paid to be a function of a version: the text
    // and layer snapshots its panes drew from (doc/model.md §2.7).
    const snaps = &ed.render.fb.stats.snapshot;
    std.debug.print("frame input snapshot (every pane, text + layers): p50 {d:.4} ms p99 {d:.4} ms over {d} frames\n", .{
        ms(snaps.percentileNs(50)), ms(snaps.percentileNs(99)), snaps.len,
    });
}
