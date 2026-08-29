//! helix — a SECOND modal editor, as a plugin, to stress-test the plugin ABI's
//! decoupling. It uses its OWN mode namespace (`helix-normal`/`helix-insert`/…),
//! its own cursor config, and composes the SAME shared `motions`/`operators`/
//! core commands vim does. If core (or any plugin) assumed vim's `normal` mode,
//! helix would break — it doesn't, which is the point: modal editing is not
//! privileged, it's a plugin over data.
//!
//! Pass 1: load this INSTEAD of vim for a functioning editor. Pass 2: load it
//! alongside vim and switch a buffer between `normal` and `helix-normal` — the
//! keymap mode is per-buffer, so they coexist. helix's verbs are motion-first
//! (Helix's selection-then-action feel): a word motion moves, and the delete/
//! change verbs act over a motion's range via the operators plugin.

const std = @import("std");
const weft = @import("weft");
const ex_mod = @import("weft_ex");

/// The `:` command line, in helix's own mode namespace (`helix-normal` resting,
/// `helix-ex` the command line). Same shared engine vim uses: helix gets the
/// classic builtins (write/quit/open/vsplit/hsplit + w/q/wq/s abbrevs) and the
/// SAME fall-through to the weft registry (`:name arg…`).
const ex = ex_mod.Ex("helix-normal", "helix-ex");

/// Motion keys shared with the `motions` plugin. `sel` motions also get a
/// delete-verb form (d<key>/c<key>) via the operator wrappers.
const Motion = struct { key: []const u8, motion: []const u8 };
const mtable = [_]Motion{
    .{ .key = "w", .motion = "motion.word-fwd" },
    .{ .key = "b", .motion = "motion.word-back" },
    .{ .key = "e", .motion = "motion.word-end" },
    .{ .key = "0", .motion = "motion.line-start" },
    .{ .key = "dollar", .motion = "motion.line-end" },
};

/// Run a motion and jump to its far end (direction-carrying), like vim's
/// normal-mode movement — but under helix's own command names.
fn moveByMotion(comptime motion: []const u8) fn () void {
    return struct {
        fn h() void {
            const cur = weft.cursor();
            const hnd = weft.runRange(motion) orelse return;
            const r = weft.rangeEnds(hnd) orelse return;
            weft.jump(if (r.end == cur) r.start else r.end);
        }
    }.h;
}

/// Delete over a motion's range (helix `d`+motion), via the operators plugin's
/// gated edit, then land at the range start.
fn deleteByMotion(comptime motion: []const u8) fn () void {
    return struct {
        fn h() void {
            const hnd = weft.runRange(motion) orelse return;
            const r = weft.rangeEnds(hnd) orelse return;
            weft.runRangeArg("op.delete", hnd);
            weft.jump(r.start);
            weft.setMode("helix-normal");
        }
    }.h;
}

const Cmd = struct { name: []const u8, handler: *const fn () void };

const base_cmds = [_]Cmd{
    .{ .name = "helix-mode", .handler = enterHelix },
    .{ .name = "hx-insert", .handler = hxInsert },
    .{ .name = "hx-append", .handler = hxAppend },
    .{ .name = "hx-open-below", .handler = hxOpenBelow },
    .{ .name = "hx-normal", .handler = hxNormal },
    .{ .name = "hx-delete-op", .handler = enterDeleteOp },
    // The `:` ex command line (shared engine; helix mode namespace).
    .{ .name = "helix-ex", .handler = ex.enter },
    .{ .name = "hx-ex-type", .handler = ex.onType },
    .{ .name = "hx-ex-backspace", .handler = ex.onBackspace },
    .{ .name = "hx-ex-clear", .handler = ex.onClear },
    .{ .name = "hx-ex-run", .handler = ex.onRun },
    .{ .name = "hx-ex-cancel", .handler = ex.onCancel },
};

/// Generated: `hx/n/<motion>` (move) for every motion, `hx/d/<motion>` (delete)
/// for the word motions. Names exist only for key binding.
const gen_cmds = blk: {
    var arr: [mtable.len * 2]Cmd = undefined;
    var i: usize = 0;
    for (mtable) |m| {
        arr[i] = .{ .name = "hx/n/" ++ m.motion, .handler = moveByMotion(m.motion) };
        arr[i + 1] = .{ .name = "hx/d/" ++ m.motion, .handler = deleteByMotion(m.motion) };
        i += 2;
    }
    break :blk arr;
};

const cmds = base_cmds ++ gen_cmds;

export fn describe() void {
    for (cmds) |c| weft.declareCommand(c.name);
}
export fn init() void {
    for (cmds) |c| _ = weft.register(c.name);

    // Only insert commits typed text; helix-normal is modal and declares
    // nothing, so nothing can leak into it. `helix-insert` falls back to the
    // core `default` floor for its BINDINGS (Return -> insert-newline, the
    // std.editing.insert-line-break arm; Backspace, Tab-as-indent) the same
    // way vim's `insert` mode does — Return's other arm, std.target.activate,
    // is bound in `helix-normal` above.
    weft.setFallback("helix-insert", "default");
    weft.textInput("helix-insert", "insert-text");

    // Movement. `u`/`C-r` and `Tab`/`Return` bind the shared std intentions
    // (doc/contextual-workspace-architecture.md §10.2), same shapes vim uses:
    // undo/redo are grammar-agnostic history operations, Tab reveals a
    // structured target's children, and Return activates the nearest typed
    // target (the insert-line-break arm lives in `helix-insert`, which falls
    // back to `default` below — the two-arm shape lives in the mode chain,
    // not a single binding). `q` keeps NO binding here: real Helix uses it
    // for macro record/replay, not back-navigation, and this plugin has no
    // macro command to give it — binding vim's back semantics onto it would
    // misrepresent helix's own feel.
    const nb = [_][2][]const u8{
        .{ "h", "cursor-left" },              .{ "l", "cursor-right" },
        .{ "j", "cursor-down" },              .{ "k", "cursor-up" },
        .{ "Left", "cursor-left" },           .{ "Right", "cursor-right" },
        .{ "Up", "cursor-up" },               .{ "Down", "cursor-down" },
        .{ "i", "hx-insert" },                .{ "a", "hx-append" },
        .{ "o", "hx-open-below" },            .{ "x", "delete-forward" },
        .{ "u", "std.history.undo" },         .{ "C-r", "std.history.redo" },
        .{ "colon", "helix-ex" },             .{ "Tab", "std.hierarchy.toggle-expanded" },
        .{ "Return", "std.target.activate" },
    };
    for (nb) |b| weft.bindKey("helix-normal", b[0], b[1]);

    // Transfer, where helix's own keys already mean it: `y` captures, `p`
    // places, and `d` takes the selection WITH it. Each leads with the
    // standard word and keeps its text behaviour as the fallback arm.
    weft.bindKeys("helix-normal", "y", &.{"std.transfer.yank"});
    weft.bindKeys("helix-normal", "p", &.{ "std.transfer.paste", "paste" });
    weft.bindKeys("helix-normal", "d", &.{ "std.transfer.delete-to-register", "hx-delete-op" });
    // `-` has no helix meaning at all, so stepping out is its whole binding.
    weft.bindKeys("helix-normal", "minus", &.{"std.hierarchy.step-out"});
    inline for (mtable) |m| weft.bindKey("helix-normal", m.key, "hx/n/" ++ m.motion);

    // helix `d` then a motion deletes over it (a tiny operator-pending mode).
    weft.menuMode("helix-op");
    weft.setFallback("helix-op", "helix-normal");
    weft.bindKey("helix-op", "Escape", "hx-normal");
    inline for (mtable) |m| weft.bindKey("helix-op", m.key, "hx/d/" ++ m.motion);
    weft.bindKey("helix-op", "d", "delete-line"); // dd

    // Insert mode: Escape back to normal.
    weft.bindKey("helix-insert", "Escape", "hx-normal");

    // Leader + goto as key SEQUENCES in helix-normal (no menu modes): `space` /
    // `g` are just the first key of chords which-key completes. A config
    // (helix.js) layers a fuller `space …` tree at prio_config; these stay at the
    // same depth so a config leaf never collides with a bare-helix prefix.
    weft.bindKey("helix-normal", "space space", "pick-commands"); // SPC SPC — M-x
    weft.bindKey("helix-normal", "space f f", "find-file"); // the flat command helix.js already binds; config's own bind wins anyway
    weft.bindKey("helix-normal", "space b b", "buf-pick"); // if buffers loaded
    weft.bindKey("helix-normal", "space g g", "git-status"); // if git loaded
    // gg / ge (goto top / end of doc), two-key sequences.
    weft.bindKey("helix-normal", "g g", "cursor-doc-start"); // core: moves to doc start
    weft.bindKey("helix-normal", "g e", "cursor-doc-end");

    // The `:` command line (helix mode namespace). Same shape as vim's `ex`:
    // printable → hx-ex-type, Backspace/Enter/Escape edit/run/cancel.
    weft.textInput("helix-ex", "hx-ex-type");
    weft.bindKey("helix-ex", "Return", "hx-ex-run");
    weft.bindKey("helix-ex", "KP_Enter", "hx-ex-run");
    weft.bindKey("helix-ex", "BackSpace", "hx-ex-backspace");
    weft.bindKey("helix-ex", "Escape", "hx-ex-cancel");
    weft.bindKey("helix-ex", "C-c", "hx-ex-cancel");
    weft.bindKey("helix-ex", "C-u", "hx-ex-clear");

    // Cursor: block in normal, bar in insert — helix's own config, by ITS mode
    // names (proving set-cursor doesn't assume vim's).
    weft.runStr2("set-cursor", "helix-normal", "block");
    weft.runStr2("set-cursor", "helix-insert", "bar");
    weft.runStr2("set-cursor", "helix-op", "underline");
    weft.runStr2("cursor-blink", "helix-insert", "on");

    // §10.4: helix's answer for each posture (and, implicitly, that
    // `helix-normal` is a mode a buffer rests in). Like vim's `normal`,
    // `helix-normal` commits nothing, so it serves both; what a structural
    // entry changes is that helix declines to ENTER `helix-insert` there
    // (`enterInsert`), rather than resting somewhere its keys are dead.
    weft.restingPosture(.text, "helix-normal");
    weft.restingPosture(.structural, "helix-normal");
    for ([_][]const u8{ "helix-normal", "helix-insert" }) |m|
        weft.bindKeys(m, "C-backslash", &.{"std.input.break-out"});
    weft.setMode("helix-normal");
}

export fn on_command(id: u32) void {
    if (id < cmds.len) cmds[id].handler();
}

fn enterHelix() void {
    weft.setMode("helix-normal");
}
/// Escape RETURNS to the entry's declared resting state (§10.4) — it never
/// picks one, so a projection's own resting mode survives an edit + Escape.
fn hxNormal() void {
    weft.exitToResting();
}

/// The ONE door into helix's insert-like state. An entry that declared a
/// non-`text` posture does not take it: the grammar declines instead of
/// parking the user where every key would be refused (§10.4).
fn enterInsert() void {
    switch (weft.posture()) {
        .text, .field => weft.setMode("helix-insert"),
        .structural, .capture => weft.echo("this entry takes no text"),
    }
}
fn hxInsert() void {
    enterInsert();
}
fn hxAppend() void {
    weft.run("cursor-right");
    enterInsert();
}
fn hxOpenBelow() void {
    // Jump to the end of the line (motion returns a range), then open a newline.
    const cur = weft.cursor();
    if (weft.runRange("motion.line-end")) |hnd| {
        if (weft.rangeEnds(hnd)) |r| weft.jump(if (r.end == cur) r.start else r.end);
    }
    weft.run("insert-newline");
    enterInsert();
}
fn enterDeleteOp() void {
    weft.setMode("helix-op");
}
