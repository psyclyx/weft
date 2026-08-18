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
const weft = @import("weft.zig");

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

    // helix-normal: swallow text (modal), fall back to nothing of vim's.
    weft.textInput("helix-normal", null);
    weft.textInput("helix-insert", "insert-text");

    // Movement.
    const nb = [_][2][]const u8{
        .{ "h", "cursor-left" },       .{ "l", "cursor-right" },
        .{ "j", "cursor-down" },       .{ "k", "cursor-up" },
        .{ "Left", "cursor-left" },    .{ "Right", "cursor-right" },
        .{ "Up", "cursor-up" },        .{ "Down", "cursor-down" },
        .{ "i", "hx-insert" },         .{ "a", "hx-append" },
        .{ "o", "hx-open-below" },     .{ "x", "delete-forward" },
        .{ "d", "hx-delete-op" },      .{ "u", "undo" },
        .{ "C-r", "redo" },            .{ "p", "paste" },
        .{ "colon", "pick-commands" }, .{ "space", "helix-leader" },
        .{ "g", "helix-goto" },
    };
    for (nb) |b| weft.bindKey("helix-normal", b[0], b[1]);
    inline for (mtable) |m| weft.bindKey("helix-normal", m.key, "hx/n/" ++ m.motion);

    // helix `d` then a motion deletes over it (a tiny operator-pending mode).
    weft.textInput("helix-op", null);
    weft.menuMode("helix-op");
    weft.setFallback("helix-op", "helix-normal");
    weft.bindKey("helix-op", "Escape", "hx-normal");
    inline for (mtable) |m| weft.bindKey("helix-op", m.key, "hx/d/" ++ m.motion);
    weft.bindKey("helix-op", "d", "delete-line"); // dd

    // Insert mode: Escape back to normal.
    weft.bindKey("helix-insert", "Escape", "hx-normal");

    // Leader + goto menus (their own modes — which-key renders them).
    weft.textInput("helix-leader", null);
    weft.menuMode("helix-leader");
    weft.bindKey("helix-leader", "Escape", "hx-normal");
    weft.bindKey("helix-leader", "f", "vim-find-file"); // reuse if vim loaded, else a no-op

    weft.bindKey("helix-leader", "b", "buf-pick"); // if buffers loaded
    weft.bindKey("helix-leader", "slash", "grep-word"); // if grep loaded
    weft.bindKey("helix-leader", "g", "git-status"); // if git loaded

    weft.textInput("helix-goto", null);
    weft.menuMode("helix-goto");
    weft.bindKey("helix-goto", "Escape", "hx-normal");
    weft.bindKey("helix-goto", "g", "cursor-doc-start"); // core: moves to doc start
    weft.bindKey("helix-goto", "e", "cursor-doc-end");

    // Cursor: block in normal, bar in insert — helix's own config, by ITS mode
    // names (proving set-cursor doesn't assume vim's).
    weft.runStr2("set-cursor", "helix-normal", "block");
    weft.runStr2("set-cursor", "helix-insert", "bar");
    weft.runStr2("set-cursor", "helix-op", "underline");
    weft.runStr2("cursor-blink", "helix-insert", "on");

    weft.setMode("helix-normal");
}

export fn on_command(id: u32) void {
    if (id < cmds.len) cmds[id].handler();
}

fn enterHelix() void {
    weft.setMode("helix-normal");
}
fn hxNormal() void {
    weft.setMode("helix-normal");
}
fn hxInsert() void {
    weft.setMode("helix-insert");
}
fn hxAppend() void {
    weft.run("cursor-right");
    weft.setMode("helix-insert");
}
fn hxOpenBelow() void {
    // Jump to the end of the line (motion returns a range), then open a newline.
    const cur = weft.cursor();
    if (weft.runRange("motion.line-end")) |hnd| {
        if (weft.rangeEnds(hnd)) |r| weft.jump(if (r.end == cur) r.start else r.end);
    }
    weft.run("insert-newline");
    weft.setMode("helix-insert");
}
fn enterDeleteOp() void {
    weft.setMode("helix-op");
}
