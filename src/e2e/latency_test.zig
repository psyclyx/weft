//! e2e/latency — the keystroke-to-dispatch latency instrument
//! (doc/cwa-prior-docs-audit.md §5): times `dispatchSpec` —
//! key event in, command executed / edit committed out — for a few
//! representative categories, against a realistically-sized buffer. Two
//! modes, selected by the `-Drecord-latency` build option (see build.zig's
//! `e2e-latency` step — the flag has no effect on the plain `test` step,
//! deliberately: see build.zig's `instrument_mod`):
//!
//!   compare (default, what `zig build test` runs): measure, load the
//!   committed baseline (`latency_baseline.zon`), and fail on a >2x median (or
//!   >2.5x p95) regression — generous factors (plus a floor, since this box's
//!   fastest categories are single-digit-microsecond and a pure multiplier
//!   can't absorb a couple microseconds of scheduler noise on those) because
//!   this box's ordinary jitter runs 10-20%; a flake in this suite is treated
//!   as a real (timing) bug to isolate, not a tune-the-test shrug. The
//!   comparison HARD-FAILS on a build-mode mismatch (a Debug run against a
//!   ReleaseFast baseline isn't a measurement of the same program) and SKIPS
//!   on a hostname mismatch (different hardware, not a regression). The
//!   thresholds below assume this binary has the box to itself; build.zig's
//!   `runAlone` is what makes that true under `zig build test`, which is
//!   otherwise free to run sibling suites alongside it.
//!
//!   record (`zig build e2e-latency -Drecord-latency=true`): measure and
//!   overwrite the baseline file, stamped with this build's mode + host.
//!   Re-record whenever a real, EXPLAINED latency shift lands (e.g. W1's
//!   Container swap-in) — never to silence a regression that hasn't been
//!   understood. A re-record earns its honesty by ALSO measuring the
//!   pre-change commit on the same box in the same session: a number that is
//!   at-or-better than that is a shift, a number worse than it is a
//!   regression wearing a new baseline.
//!
//! The measurement mechanism (`Editor.pressTimed`, `core.task.nowNs()`
//! bracketing `dispatchSpec` from the CALLER side) lives in harness.zig; the
//! statistics + baseline (de)serialization + provenance live in latency.zig;
//! this file is only the POLICY — which categories, how many keystrokes, what
//! threshold. `app/dispatch.zig` itself carries no timing and is otherwise
//! untouched.
//!
//! Five categories. The first four resolve through the compiled KEYMAP
//! straight to a plain command — none of them touch `action.resolve`
//! (`command.actionTrampoline`, command.zig:258), the resolution path W1's
//! Container replaces. `action` exists because nothing else in this suite
//! reaches it: `loadVim` (edit/motions/textobjects/operators/vim) registers
//! zero action providers, so without a fixture action this instrument would
//! gate four keymap-only paths and miss the one it was built for. Its fixture
//! (`registerActionFixture`) registers ~32 providers — a realistic-sized
//! population, not a token 2-3 — so resolution is a measurable fraction of
//! the sample and a Container regression that scales with provider count
//! (or starts allocating per resolve) actually trips the gate, not just a
//! swap of one cheap lookup for another equally cheap one.
//!
//! Honesty note (this is a keystroke-level instrument, not a profiler): the
//! gate catches a resolution engine that gets measurably slower — scales
//! worse with provider count, allocates where it didn't, adds a syscall —
//! not a constant-factor regression smaller than this box's sample noise
//! (tens to low hundreds of ns), and it says nothing about correctness.
//!
//! What it does NOT measure, and must not be sized by: the application WAKE
//! each keystroke triggers (`Editor.pressTimed` advances one, outside the
//! timed window, so the state a keystroke lands in stays realistic). That
//! wake is the production frame BUILD — `Application.advance` →
//! `FrameBuilder.buildFrame`, the same path the desktop runs, minus
//! rasterization. Profiled per phase on this box (Debug, 267KB zig buffer),
//! it is ~4ms: an incremental tree-sitter reparse ~2.4ms, `Syntax.paint`
//! ~1.7ms, `Editor.isDirty` ~0.1ms rising past 1.5ms as unsaved commits pile
//! up (it is O(history since save) — a per-frame causal comparison for a
//! status-line chip), and the pane build ~0.8ms. Nothing here needs the wake
//! to be slow; where the fixture could pick a cheap realistic state over an
//! expensive pathological one, it does — see `scratch_line`.

const std = @import("std");
const t = std.testing;
const h = @import("harness.zig");
const latency = @import("latency.zig");
const instrument = @import("instrument.zig");
const latency_options = @import("latency_options");
const log = std.log.scoped(.@"e2e-latency");

const core = h.core;
const Editor = h.Editor;
const loadVim = h.loadVim;
const tmpPath = h.tmpPath;

const baseline_path = "src/e2e/latency_baseline.zon";

/// Robustness knobs (see latency.zig's `measure` doc for why runs-of-medians
/// beats one big pooled sample). `warmup` presses settle caches/branch
/// predictors before any timed sample; `runs` * `iters` are the timed
/// keystrokes proper. Across all five categories this totals a few thousand
/// keystrokes, per the brief.
const warmup = 200;
const runs = 5;
const iters = 400;

/// Regression gate: `baseline * num/den + floor`. Integer ratios (not a
/// float factor) so the threshold math stays exact. This box's ordinary
/// jitter run-to-run is ~10-20%; these leave real headroom above that
/// without being so loose a genuine regression sails through (the original
/// 3x+20us draft did: a category with a 50us median tolerated 170us, which
/// is not "unchanged latency" by any reading). p95 gets a looser ratio and a
/// bigger floor — tails are noisier than medians by nature.
const median_factor_num = 2;
const median_factor_den = 1;
const median_floor_ns = 4_000; // 4us
const p95_factor_num = 5;
const p95_factor_den = 2; // 2.5x
const p95_floor_ns = 8_000; // 8us

/// `action`'s baseline sits at a few microseconds (host-side resolution over
/// a no-op tail-call, no wasm round-trip) — the generic floors above are most
/// of ITS gate, not headroom on top of one. Tighter floors here, still well
/// above this box's observed jitter on that category.
const action_median_floor_ns = 2_000; // 2us
const action_p95_floor_ns = 4_000; // 4us

fn medianFloorFor(name: []const u8) u64 {
    return if (std.mem.eql(u8, name, "action")) action_median_floor_ns else median_floor_ns;
}
fn p95FloorFor(name: []const u8) u64 {
    return if (std.mem.eql(u8, name, "action")) action_p95_floor_ns else p95_floor_ns;
}

fn regressionThreshold(baseline_ns: u64, num: u64, den: u64, floor_ns: u64) u64 {
    return baseline_ns * num / den + floor_ns;
}

// ── Per-category drivers — each `step` is one measured dispatch (or, for
// `chord`, the pair of presses that resolves it) ──────────────────────────

/// Plain printable inserts — the hot typing→commit path (`dispatchSpec`'s
/// text-command fallthrough).
const InsertDriver = struct {
    ed: *Editor,
    i: usize = 0,
    const chars = "the quick brown fox jumps over the lazy dog ";
    fn step(self: *@This()) u64 {
        const c = chars[self.i % chars.len];
        self.i += 1;
        const s = [1]u8{c};
        return self.ed.pressTimed(&s, &s);
    }
};

/// `j`/`k` — a bound single-key motion (`vim/n/motion.down`/`.up`), alternated
/// so the cursor stays put (no risk of running off either end of the fixture).
const MotionDriver = struct {
    ed: *Editor,
    i: usize = 0,
    fn step(self: *@This()) u64 {
        const key = if (self.i % 2 == 0) "j" else "k";
        self.i += 1;
        return self.ed.pressTimed(key, "");
    }
};

/// `g g` — a bound two-key SEQUENCE (goto-top): the first press holds pending
/// (which-key territory — `Keymap.feed` returns `.pending`), the second
/// resolves and runs the command. Timed as ONE sample (the sum of both
/// dispatch calls) — what a user experiences as "the chord fired".
/// Idempotent (always lands at buffer start), so it composes cleanly with
/// itself across thousands of reps.
const ChordDriver = struct {
    ed: *Editor,
    fn step(self: *@This()) u64 {
        const a = self.ed.pressTimed("g", "");
        const b = self.ed.pressTimed("g", "");
        return a + b;
    }
};

/// `i` / `Escape` alternated — the mode-switch path (keymap mode transition,
/// no text and no command args).
const ModeSwitchDriver = struct {
    ed: *Editor,
    i: usize = 0,
    fn step(self: *@This()) u64 {
        const key = if (self.i % 2 == 0) "i" else "Escape";
        self.i += 1;
        return self.ed.pressTimed(key, "");
    }
};

/// `F2` — a bound ACTION. See the file doc for why this fixture exists at
/// all: no shipped plugin the harness loads registers one.
const ActionDriver = struct {
    ed: *Editor,
    fn step(self: *@This()) u64 {
        return self.ed.pressTimed("F2", "");
    }
};

fn sampleInsert(d: *InsertDriver) u64 {
    return d.step();
}
fn sampleMotion(d: *MotionDriver) u64 {
    return d.step();
}
fn sampleChord(d: *ChordDriver) u64 {
    return d.step();
}
fn sampleModeSwitch(d: *ModeSwitchDriver) u64 {
    return d.step();
}
fn sampleAction(d: *ActionDriver) u64 {
    return d.step();
}

/// The terminal command every fixture action provider below routes to. It
/// does nothing — what's being measured is action RESOLUTION (predicate +
/// specificity + priority), not whatever command it happens to land on.
fn noopCommand(ctx: *core.command.Context, data: ?*anyopaque, args: []const core.command.Value) anyerror!core.command.Value {
    _ = ctx;
    _ = data;
    _ = args;
    return .nil;
}

/// Register a fixture ACTION (`latency-action`, bound to `F2` in `normal`)
/// with a REALISTIC-SIZED provider population — ~32, not a token 2-3 — so
/// `Actions.resolve` (action.zig:247) does work proportional to what a
/// well-used action (`eval`, `save`, a project-wide `run`) would actually
/// carry, and a Container regression that SCALES with provider count (an
/// O(n log n) sort where the current code is O(n), an allocation per
/// candidate, …) shows up in the sample instead of hiding inside 3 items'
/// worth of noise:
///
///   - 25 DECOYS, spread across all three `When` axes (lang/mode/tool) and a
///     range of priorities, whose predicate never holds against the fixture
///     buffer's context (`mode: normal, lang: zig, tool: ""`) — `resolve`
///     must evaluate each one for real, not skip past a short list.
///   - 7 CONTENDERS that DO hold, at a mix of priorities and specificities,
///     so the priority+specificity tie-break also runs across a real field
///     instead of a trivial two-way comparison.
///
/// All 32 route to the same no-op command, so which one ultimately wins is
/// irrelevant to the measured EFFECT — only to whether `resolve` did the
/// work of getting there.
fn registerActionFixture(gpa: std.mem.Allocator, ed: *Editor) !void {
    _ = try ed.commands.bind(gpa, "latency-noop", .{
        .name = "latency-noop",
        .summary = "e2e/latency fixture: does nothing",
        .args = &.{},
        .handler = noopCommand,
    });
    try core.command.registerAction(gpa, ed.commands, ed.ctx.actions, "latency-action", .pick);

    var buf: [64]u8 = undefined;
    // 10 decoys: `lang` mismatch only.
    for (0..10) |i| {
        const lang = std.fmt.bufPrint(&buf, "decoy-lang-{d}", .{i}) catch unreachable;
        try ed.ctx.actions.provide(.{
            .action = "latency-action",
            .when = .{ .lang = lang },
            .command = "latency-noop",
            .priority = @intCast(i % 5),
            .owner = "latency-test",
        });
    }
    // 8 decoys: `mode` mismatch only.
    for (0..8) |i| {
        const mode = std.fmt.bufPrint(&buf, "decoy-mode-{d}", .{i}) catch unreachable;
        try ed.ctx.actions.provide(.{
            .action = "latency-action",
            .when = .{ .mode = mode },
            .command = "latency-noop",
            .priority = @intCast(i % 5),
            .owner = "latency-test",
        });
    }
    // 7 decoys: `tool` mismatch, PAIRED with a `lang` that alone would match
    // (so the predicate does a real two-field check before failing on tool).
    for (0..7) |i| {
        const tool = std.fmt.bufPrint(&buf, "decoy-tool-{d}", .{i}) catch unreachable;
        try ed.ctx.actions.provide(.{
            .action = "latency-action",
            .when = .{ .tool = tool, .lang = "zig" },
            .command = "latency-noop",
            .priority = @intCast(i % 5),
            .owner = "latency-test",
        });
    }
    // 25 decoys total. 7 contenders, mixed priority/specificity:
    try ed.ctx.actions.provide(.{ .action = "latency-action", .command = "latency-noop", .owner = "latency-test" }); // specificity 0
    try ed.ctx.actions.provide(.{ .action = "latency-action", .when = .{ .mode = "normal" }, .command = "latency-noop", .owner = "latency-test" }); // specificity 1
    try ed.ctx.actions.provide(.{ .action = "latency-action", .when = .{ .lang = "zig" }, .command = "latency-noop", .owner = "latency-test" }); // specificity 1
    try ed.ctx.actions.provide(.{ .action = "latency-action", .when = .{ .mode = "normal", .lang = "zig" }, .command = "latency-noop", .owner = "latency-test" }); // specificity 2
    try ed.ctx.actions.provide(.{ .action = "latency-action", .when = .{ .mode = "normal" }, .priority = 10, .command = "latency-noop", .owner = "latency-test" }); // higher priority
    try ed.ctx.actions.provide(.{ .action = "latency-action", .command = "latency-noop", .priority = -5, .owner = "latency-test" }); // lower priority
    try ed.ctx.actions.provide(.{ .action = "latency-action", .when = .{ .mode = "normal", .lang = "zig" }, .priority = 10, .command = "latency-noop", .owner = "latency-test" }); // ties the top priority+specificity — wins overall

    try ed.keymap.bind(gpa, "normal", "F2", "latency-action", core.Keymap.prio_config, "latency-test");
}

/// ~5000 lines of zig-shaped filler (~260KB) — a realistically-sized source
/// buffer, big enough that an accidental O(n) table scan on the dispatch path
/// would show up in the numbers, small enough the e2e suite doesn't notice
/// generating it. The trailing comment is where `insert` types (see
/// `scratch_line` and this file's module doc).
fn writeFixture(gpa: std.mem.Allocator, path: []const u8) !void {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    var i: usize = 0;
    while (i < 5000) : (i += 1) {
        try buf.print(gpa, "fn f{d}(a: i32, b: i32) i32 {{ return a + b + {d}; }}\n", .{ i, i });
    }
    try buf.appendSlice(gpa, scratch_line);
    try core.file.writeBytes(gpa, path, buf.items);
}

/// The fixture's last line: an ordinary comment the `insert` category appends
/// to, reached with `G` (doc-end) then `A` (append at end of line). Left
/// unterminated so `G` lands on the comment itself, not an empty line past it.
///
/// Why not just type where the buffer opens: prose at offset 0 of a `.zig`
/// file makes the whole document unparseable, and tree-sitter answers a broken
/// document by re-reading and re-parsing ALL of it every keystroke — measured
/// at 277ms per wake, against 2.4ms once the file is valid again. That was
/// ~130s of this instrument's ~180s wall, none of it inside the timed window
/// (`dispatchSpec` alone). Appending to a comment commits through the same
/// dispatch path — same keymap, same rope, same commit and undo machinery —
/// and leaves the wake realistic instead of pathological. The reparse cost is
/// a real product finding, not something this instrument is here to measure.
const scratch_line = "// scratch";

/// The insert category's premise, asserted rather than assumed: the warmup
/// keystrokes landed at the END of the trailing comment, so the fixture is
/// still valid zig. Rebinding `G`/`A` (or dropping the comment) fails HERE
/// instead of quietly restoring the whole-document reparse.
fn expectTypingInScratchComment(gpa: std.mem.Allocator, ed: *Editor) !void {
    const text = try ed.textAlloc();
    defer gpa.free(text);
    const last = text[(std.mem.lastIndexOfScalar(u8, text, '\n') orelse 0) + 1 ..];
    try t.expect(std.mem.startsWith(u8, last, scratch_line));
    try t.expect(last.len > scratch_line.len); // the warmup went in here
}

test "e2e/latency: dispatch keystroke latency vs baseline" {
    if (!instrument.selected("latency")) return error.SkipZigTest;
    const gpa = t.allocator;

    // Compare mode: check the baseline's provenance BEFORE spending time on
    // the measurement loop below — a build-mode mismatch fails regardless,
    // and a foreign-host baseline skips regardless, so there's nothing to
    // gate on either way.
    // Taken HERE, before either branch and before any measurement, so record
    // and compare probe the machine in the SAME state. Recording it after the
    // measurement loops — which is where it naturally wanted to go, next to the
    // numbers it ships with — read a box whose caches those loops had just
    // dirtied: 2.16ms recorded against 1.10ms compared, on an idle machine, for
    // no reason but call position. A yardstick measured differently in the two
    // modes silently biases every comparison it is used for.
    const calibration_ns = latency.calibrate();

    var loaded: ?latency.Baseline = null;
    defer if (loaded) |b| std.zon.parse.free(gpa, b);
    if (!latency_options.record) {
        // Same doctrine as the host and build-mode checks below: a measurement
        // taken under conditions the baseline was not recorded under is not a
        // regression, and reporting it as one trains everyone to ignore this
        // gate.
        //
        // The `test` step runs this instrument in a process that has already
        // executed ~159 other e2e tests; the baseline is recorded by the
        // FILTERED `e2e-latency` binary, which runs this test and nothing else
        // in a fresh process. That difference is not small and it is not
        // scheduling noise: the same code measures ~37us of thread CPU alone
        // and ~176us after the suite has run, because it is then measuring that
        // process's accumulated allocator and cache state. `zig build test`
        // depends on the isolated step, so the gate still runs on every `test`
        // — it just runs where its numbers mean something.
        if (!latency_options.isolated) {
            log.info("measured, not gated: this binary ran the whole e2e suite first, and the baseline is recorded by the isolated `e2e-latency` binary — `zig build test` gates it there", .{});
            return error.SkipZigTest;
        }
        const baseline = latency.loadBaseline(gpa, baseline_path) catch |err| {
            log.warn("no baseline at {s} ({t}) — run `zig build e2e-latency -Drecord-latency=true` to record one", .{ baseline_path, err });
            return error.SkipZigTest;
        };
        const my_mode = latency.buildModeName();
        if (!std.mem.eql(u8, baseline.build_mode, my_mode)) {
            log.err("baseline was recorded in '{s}' mode, this run is '{s}' — different programs, not a regression; re-record for this mode", .{ baseline.build_mode, my_mode });
            std.zon.parse.free(gpa, baseline);
            return error.LatencyBaselineModeMismatch;
        }
        var host_buf: [std.posix.HOST_NAME_MAX]u8 = undefined;
        const my_host = latency.hostName(&host_buf);
        if (!std.mem.eql(u8, baseline.host, my_host)) {
            log.warn("baseline recorded on '{s}', running on '{s}' — skipping (different hardware, not a regression); re-record on this host for a real gate here", .{ baseline.host, my_host });
            std.zon.parse.free(gpa, baseline);
            return error.SkipZigTest;
        }
        // The same host, in a different STATE, is not the same measurement
        // either — see `Baseline.calibration_ns`. A developer box shares cores
        // with a browser; CI shares them with whatever else the runner packed
        // on. Skip rather than report someone else's load as this code's
        // regression, which is the failure that teaches people to ignore a gate.
        if (baseline.calibration_ns != 0) {
            const now = calibration_ns;
            log.warn("calibration: {d}ns now vs {d}ns at record time", .{ now, baseline.calibration_ns });
            // 1.2x, not something looser: this gate errs toward SKIPPING. A skip
            // says "not measured here" and costs nothing; a false failure costs
            // the gate its credibility, which is the only thing it has.
            if (now > baseline.calibration_ns * 6 / 5) {
                log.warn(
                    "this box is currently {d}% of the speed it was when the baseline was recorded ({d}ns vs {d}ns on a fixed CPU loop) — skipping; that is load, not a regression",
                    .{ baseline.calibration_ns * 100 / @max(now, 1), baseline.calibration_ns, now },
                );
                std.zon.parse.free(gpa, baseline);
                return error.SkipZigTest;
            }
        }
        loaded = baseline;
    }

    var td = t.tmpDir(.{});
    defer td.cleanup();
    const path = try tmpPath(gpa, &td.sub_path, "fixture.zig");
    defer gpa.free(path);
    try writeFixture(gpa, path);

    var ed: Editor = undefined;
    try Editor.init(gpa, &ed);
    defer ed.deinit();
    try loadVim(&ed);
    ed.runStr("open", path);
    try t.expectEqualStrings("normal", ed.mode());
    try registerActionFixture(gpa, &ed);

    const scratch = try gpa.alloc(u64, iters);
    defer gpa.free(scratch);

    const Result = struct { name: []const u8, samples: usize, stats: latency.Stats };
    var results: [5]Result = undefined;

    // insert — into the fixture's trailing comment (`scratch_line`)
    {
        var d: InsertDriver = .{ .ed = &ed };
        ed.chord("G A");
        try t.expectEqualStrings("insert", ed.mode());
        for (0..warmup) |_| _ = d.step();
        try expectTypingInScratchComment(gpa, &ed);
        results[0] = .{ .name = "insert", .samples = runs * iters, .stats = try latency.measure(gpa, scratch, runs, iters, &d, sampleInsert) };
        ed.press("Escape", "");
    }
    // motion
    {
        var d: MotionDriver = .{ .ed = &ed };
        for (0..warmup) |_| _ = d.step();
        results[1] = .{ .name = "motion", .samples = runs * iters, .stats = try latency.measure(gpa, scratch, runs, iters, &d, sampleMotion) };
    }
    // chord — half the iteration budget (each sample is 2 keystrokes)
    const chord_iters = iters / 2;
    {
        var d: ChordDriver = .{ .ed = &ed };
        for (0..warmup / 2) |_| _ = d.step();
        results[2] = .{ .name = "chord", .samples = runs * chord_iters, .stats = try latency.measure(gpa, scratch[0..chord_iters], runs, chord_iters, &d, sampleChord) };
    }
    // mode_switch
    {
        var d: ModeSwitchDriver = .{ .ed = &ed };
        for (0..warmup) |_| _ = d.step();
        results[3] = .{ .name = "mode_switch", .samples = runs * iters, .stats = try latency.measure(gpa, scratch, runs, iters, &d, sampleModeSwitch) };
        ed.press("Escape", "");
    }
    // action
    {
        var d: ActionDriver = .{ .ed = &ed };
        for (0..warmup) |_| _ = d.step();
        results[4] = .{ .name = "action", .samples = runs * iters, .stats = try latency.measure(gpa, scratch, runs, iters, &d, sampleAction) };
    }

    if (latency_options.record) {
        var categories: [results.len]latency.CategoryBaseline = undefined;
        for (results, 0..) |r, idx| {
            categories[idx] = .{ .name = r.name, .median_ns = r.stats.median_ns, .p95_ns = r.stats.p95_ns, .samples = r.samples };
        }
        var host_buf: [std.posix.HOST_NAME_MAX]u8 = undefined;
        var note_buf: [160]u8 = undefined;
        const note = std.fmt.bufPrint(&note_buf, "recorded at epoch {d}s via `zig build e2e-latency -Drecord-latency=true`", .{latency.epochSeconds()}) catch "recorded via `zig build e2e-latency -Drecord-latency=true`";
        try latency.saveBaseline(gpa, baseline_path, .{
            .build_mode = latency.buildModeName(),
            .host = latency.hostName(&host_buf),
            .note = note,
            .calibration_ns = calibration_ns,
            .categories = &categories,
        });
        log.info("recorded {s}", .{baseline_path});
        for (results) |r| log.info("  {s}: median={d}ns p95={d}ns (n={d})", .{ r.name, r.stats.median_ns, r.stats.p95_ns, r.samples });
        return;
    }

    const baseline = loaded.?;
    var regressed = false;
    for (results) |r| {
        const base = latency.find(baseline, r.name) orelse {
            log.warn("{s} has no baseline entry — re-record", .{r.name});
            continue;
        };
        const median_floor = medianFloorFor(r.name);
        const p95_floor = p95FloorFor(r.name);
        const median_limit = regressionThreshold(base.median_ns, median_factor_num, median_factor_den, median_floor);
        const p95_limit = regressionThreshold(base.p95_ns, p95_factor_num, p95_factor_den, p95_floor);
        log.info("{s} median={d}ns (baseline {d}ns, limit {d}ns) p95={d}ns (baseline {d}ns, limit {d}ns)", .{
            r.name, r.stats.median_ns, base.median_ns, median_limit, r.stats.p95_ns, base.p95_ns, p95_limit,
        });
        if (r.stats.median_ns > median_limit) {
            log.err("{s} median regressed: {d}ns > {d}ns ({d}x baseline {d}ns + {d}ns floor)", .{ r.name, r.stats.median_ns, median_limit, median_factor_num, base.median_ns, median_floor });
            regressed = true;
        }
        if (r.stats.p95_ns > p95_limit) {
            log.err("{s} p95 regressed: {d}ns > {d}ns ({d}/{d}x baseline {d}ns + {d}ns floor)", .{ r.name, r.stats.p95_ns, p95_limit, p95_factor_num, p95_factor_den, base.p95_ns, p95_floor });
            regressed = true;
        }
    }
    try t.expect(!regressed);
}
