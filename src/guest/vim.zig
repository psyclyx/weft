//! vim — modal editing (design §6.1) as a `.wasm` plugin, perms `{}` grant_max
//! edit. PURE KEYMAP POLICY: it owns modes, registers, and chords, and composes
//! the `motions` and `operators` plugins BY LATE-BOUND NAME — it contains no
//! motion or edit logic of its own. A motion returns a stamped `range`; in
//! normal mode vim moves the cursor to the target, in operator-pending mode it
//! hands the range to `op.delete` ([FIX 3] — no shared-cursor side channel).
//! The core knows nothing of vim; delete it and weft is modeless.

const std = @import("std");
const weft = @import("weft.zig");
const ex_mod = @import("ex.zig");

/// The `:` command line: vim's resting mode is `normal`, its command-line
/// keymap mode is `ex`. Owns the classic abbreviated ex commands (w/q/s/…) and
/// falls everything else through to the weft command registry (see ex.zig).
const ex = ex_mod.Ex("normal", "ex");

// ── Register (charwise/linewise) — now the CORE register (weft.zig), shared
// with helix and any editor, so `dd`→`p` ferries a projection row's hidden id
// (a move) across editors and buffers. `yankRange` snapshots text + overlapping
// subbuffer facts; `pasteAt` re-stamps them over the inserted text. A scratch
// for assembling the linewise paste (register text plus a synthesized newline).
var paste_buf: [(1 << 16) + 1]u8 = undefined;

// ── Pending-operator state (set on d/c/y/gc; consumed by the next motion) ─
// `op_edit_cmd` is the range-arg operator to apply (null = pure yank); `op_copies`
// is whether to first yank the range into the register (d/c/y do, gc doesn't);
// `op_after` is the mode to enter after. This trio lets ANY range-arg operator —
// op.delete, op.comment, a plugin's own — ride the operator-pending machinery.
var op_edit_cmd: ?[]const u8 = "op.delete";
var op_copies: bool = true;
var op_after: []const u8 = "normal"; // mode to enter after the operator

// ── Count prefix (3dw, 5j, 2x): digits accumulate, the next motion/operator
// repeats. Preserved through operator entry (3dw and d3w both delete 3 words),
// cleared after any other command (see `on_command`). `consumeCount` reads and
// resets it; 0 means "no count" → 1.
var pending_count: u32 = 0;
fn consumeCount() u32 {
    const c = if (pending_count == 0) 1 else pending_count;
    pending_count = 0;
    return c;
}

const file_pick = 0;

fn lineStartOff() usize {
    return weft.lineAt(weft.cursor()).start;
}
fn lineEndOff() usize {
    return weft.lineAt(weft.cursor()).end;
}

// ── Motion keys: each drives the `motions` plugin by name. `in_op` keys are
// also valid after an operator (dw, de, d$, …). ──
const MB = struct { key: []const u8, motion: []const u8, in_op: bool };
const mtable = [_]MB{
    .{ .key = "h", .motion = "motion.left", .in_op = false },
    .{ .key = "l", .motion = "motion.right", .in_op = false },
    .{ .key = "j", .motion = "motion.down", .in_op = false },
    .{ .key = "k", .motion = "motion.up", .in_op = false },
    .{ .key = "w", .motion = "motion.word-fwd", .in_op = true },
    .{ .key = "b", .motion = "motion.word-back", .in_op = true },
    .{ .key = "e", .motion = "motion.word-end", .in_op = true },
    .{ .key = "W", .motion = "motion.WORD-fwd", .in_op = true },
    .{ .key = "B", .motion = "motion.WORD-back", .in_op = true },
    .{ .key = "E", .motion = "motion.WORD-end", .in_op = true },
    .{ .key = "0", .motion = "motion.line-start", .in_op = true },
    .{ .key = "dollar", .motion = "motion.line-end", .in_op = true },
    .{ .key = "asciicircum", .motion = "motion.first-non-blank", .in_op = true },
    .{ .key = "G", .motion = "motion.doc-end", .in_op = true },
    .{ .key = "percent", .motion = "motion.match-pair", .in_op = true },
};

/// Normal-mode motion: run the motion `count` times, jumping to each target (the
/// range end that isn't the current cursor — the motion is direction-carrying).
fn moveByMotion(comptime motion: []const u8) fn () void {
    return struct {
        fn h() void {
            var n = consumeCount();
            while (n > 0) : (n -= 1) {
                const cur = weft.cursor();
                const hnd = weft.runRange(motion) orelse return;
                const r = weft.rangeEnds(hnd) orelse return;
                weft.jump(if (r.end == cur) r.start else r.end);
            }
        }
    }.h;
}

/// Count-aware digit key: accumulate a decimal count (saturating).
fn countDigit(comptime d: u32) fn () void {
    return struct {
        fn h() void {
            pending_count = pending_count *| 10 +| d;
        }
    }.h;
}

/// `0`: the digit 0 when a count is being typed (so `10`, `20` work), else the
/// line-start motion (vim's overload of the key).
fn zeroKey() void {
    if (pending_count > 0) {
        pending_count = pending_count *| 10;
        return;
    }
    const cur = weft.cursor();
    const hnd = weft.runRange("motion.line-start") orelse return;
    const r = weft.rangeEnds(hnd) orelse return;
    weft.jump(if (r.end == cur) r.start else r.end);
}

/// `x` with a count: delete `count` characters forward.
fn deleteCharFwd() void {
    var n = consumeCount();
    while (n > 0) : (n -= 1) weft.run("delete-forward");
}
/// The pending operator is a CHANGE (`c`) — its after-mode is insert. vim's
/// `cw`/`cW` special-case keys off this.
fn isChangeOp() bool {
    return std.mem.eql(u8, op_after, "insert");
}

fn isWordByte(ch: u8) bool {
    return (ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z') or
        (ch >= '0' and ch <= '9') or ch == '_';
}

/// Is the cursor sitting ON a word character? (vim's `cw`→`ce` rule only
/// applies when in a word — on whitespace, `cw` stays `cw`.)
fn cursorOnWord() bool {
    const cur = weft.cursor();
    const s = weft.slice(cur, cur + 1);
    return s.len == 1 and isWordByte(s[0]);
}

/// The word-END motion `cw`/`cW` should use in place of word-FORWARD, or "" if
/// `motion` isn't a plain word-forward motion.
fn changeWordEnd(comptime motion: []const u8) []const u8 {
    if (std.mem.eql(u8, motion, "motion.word-fwd")) return "motion.word-end";
    if (std.mem.eql(u8, motion, "motion.WORD-fwd")) return "motion.WORD-end";
    return "";
}

/// An INCLUSIVE motion covers the endpoint CHARACTER (vim `e`/`E`): the motion's
/// range end is the last byte of the word, so as an operator target it must be
/// extended one byte — otherwise `de`/`ce` stop one char short (delete "cns" of
/// "cnst"). Exclusive motions (`w`, `b`, `0`, `$`) already land past their span.
fn isInclusiveMotion(m: []const u8) bool {
    return std.mem.eql(u8, m, "motion.word-end") or std.mem.eql(u8, m, "motion.WORD-end");
}

/// Extend a stamped range's end by one byte (clamped to the buffer) — the
/// inclusive-motion fixup, so the operator covers the endpoint character.
fn inclusiveEnd(hnd: u32) u32 {
    const r = weft.rangeEnds(hnd) orelse return hnd;
    const end2 = @min(r.end + 1, weft.byteLen());
    if (end2 == r.end) return hnd;
    return weft.stampRange(.{ .start = r.start, .end = end2 }) orelse hnd;
}

/// Operator-pending motion: run the motion, apply the pending operator over its
/// range. Two vim fidelity rules live here:
///  · `cw`/`cW` special case — changing a word with the cursor IN a word acts
///    like `ce`/`cE` (to the word END), so the trailing whitespace `dw` eats is
///    preserved (`cw` on "cnst " → change "cnst", keep the space).
///  · inclusive motions (`e`/`E`, and `cw`/`cW` which route to them) cover the
///    endpoint char, so the operator range is extended one byte.
fn opByMotion(comptime motion: []const u8) fn () void {
    return struct {
        fn h() void {
            const n = consumeCount();
            const eff = comptime changeWordEnd(motion);
            const use = if (eff.len > 0 and isChangeOp() and cursorOnWord()) eff else motion;
            // Advance a scratch cursor by the motion `n` times to find the target,
            // so `d3w` deletes over three words; then apply the operator over
            // [start, target]. For n==1 this reduces to a single motion range.
            const start = weft.cursor();
            var i: u32 = 0;
            while (i < n) : (i += 1) {
                const cur = weft.cursor();
                const hnd = weft.runRange(use) orelse return opCancel();
                const r = weft.rangeEnds(hnd) orelse return opCancel();
                weft.jump(if (r.end == cur) r.start else r.end);
            }
            const target = weft.cursor();
            weft.jump(start);
            const lo = @min(start, target);
            var hi = @max(start, target);
            if (isInclusiveMotion(use)) hi = @min(hi + 1, weft.byteLen());
            const hnd = weft.stampRange(.{ .start = lo, .end = hi }) orelse return opCancel();
            applyOpRange(hnd);
        }
    }.h;
}

/// Apply the pending operator over a stamped range. `op_copies` yanks the range
/// into the register first (d/c/y); `op_edit_cmd` then runs the gated edit
/// (op.delete for d/c, op.comment for gc, …) and enters the after-mode. A pure
/// yank (no edit command) flashes and returns to normal.
fn applyOpRange(hnd: u32) void {
    const r = weft.rangeEnds(hnd) orelse return opCancel();
    if (op_copies) weft.yankRange(r.start, r.end, false);
    if (op_edit_cmd) |cmd| {
        weft.runRangeArg(cmd, hnd);
        weft.jump(r.start);
        weft.setMode(op_after);
    } else {
        weft.flash(r.start, r.end); // vim-goggles: flash the yanked region
        weft.jump(r.start);
        weft.setMode("normal");
    }
}

// ── Text objects: `i`/`a` in operator-pending enter a text-object mode with a
// pending inner/a variant; the object key drives the `textobjects` plugin. ──
var to_variant: []const u8 = "inner";
const OB = struct { key: []const u8, obj: []const u8 };
const otable = [_]OB{
    .{ .key = "w", .obj = "word" },                .{ .key = "W", .obj = "WORD" },
    .{ .key = "quotedbl", .obj = "quote-double" }, .{ .key = "apostrophe", .obj = "quote-single" },
    .{ .key = "grave", .obj = "quote-back" },      .{ .key = "parenleft", .obj = "paren" },
    .{ .key = "parenright", .obj = "paren" },      .{ .key = "b", .obj = "paren" },
    .{ .key = "bracketleft", .obj = "bracket" },   .{ .key = "bracketright", .obj = "bracket" },
    .{ .key = "braceleft", .obj = "brace" },       .{ .key = "braceright", .obj = "brace" },
    .{ .key = "B", .obj = "brace" },               .{ .key = "p", .obj = "paragraph" },
    .{ .key = "f", .obj = "function" },            .{ .key = "c", .obj = "class" },
    .{ .key = "m", .obj = "call" },
};
const to_objs = [_][]const u8{ "word", "WORD", "quote-double", "quote-single", "quote-back", "paren", "bracket", "brace", "paragraph", "function", "class", "call" };

/// Run textobj.<variant>-<obj> (variant chosen by i/a) and apply the pending
/// operator over its range — the same path motions take.
fn objWrap(comptime obj: []const u8) fn () void {
    return struct {
        fn h() void {
            var buf: [64]u8 = undefined;
            const name = std.fmt.bufPrint(&buf, "textobj.{s}-{s}", .{ to_variant, obj }) catch return opCancel();
            const hnd = weft.runRange(name) orelse return opCancel();
            applyOpRange(hnd);
        }
    }.h;
}
fn enterOpInner() void {
    to_variant = "inner";
    weft.setMode("op-to");
}
fn enterOpAround() void {
    to_variant = "a";
    weft.setMode("op-to");
}

// ── The static command table (registration order == on_command id) ────
const Cmd = struct { name: []const u8, handler: *const fn () void };
const static_cmds = [_]Cmd{
    .{ .name = "vim-insert", .handler = insert },
    .{ .name = "vim-append", .handler = append },
    .{ .name = "vim-open-below", .handler = openBelow },
    .{ .name = "vim-open-above", .handler = openAbove },
    .{ .name = "vim-visual", .handler = visual },
    .{ .name = "vim-visual-delete", .handler = visualDelete },
    .{ .name = "vim-visual-yank", .handler = visualYank },
    .{ .name = "vim-visual-change", .handler = visualChange },
    .{ .name = "vim-visual-comment", .handler = visualComment },
    .{ .name = "vim-visual-line", .handler = visualLine },
    .{ .name = "vim-normal", .handler = normal },
    .{ .name = "vim-append-line", .handler = appendLine },
    .{ .name = "vim-insert-line", .handler = insertLine },
    .{ .name = "vim-delete-eol", .handler = deleteEol },
    .{ .name = "vim-change-eol", .handler = changeEol },
    .{ .name = "vim-change-line", .handler = changeLine },
    .{ .name = "yank-line", .handler = yankLine },
    .{ .name = "paste", .handler = paste },
    .{ .name = "paste-before", .handler = pasteBefore },
    .{ .name = "join-lines", .handler = joinLines },
    .{ .name = "enter-op-delete", .handler = enterOpDelete },
    .{ .name = "enter-op-change", .handler = enterOpChange },
    .{ .name = "enter-op-yank", .handler = enterOpYank },
    .{ .name = "enter-op-comment", .handler = enterOpComment },
    .{ .name = "op-cancel", .handler = opCancel },
    .{ .name = "op-line", .handler = opLine },
    .{ .name = "enter-op-inner", .handler = enterOpInner },
    .{ .name = "enter-op-around", .handler = enterOpAround },
    .{ .name = "find-file", .handler = findFile },
    // `leader-cancel` stays: the f/F/t/T char-capture modes bind Escape to it.
    // The leader/window/goto/zed MENU MODES are gone — those trees are now key
    // SEQUENCES bound in normal/global (see install), so there's no mode to enter.
    .{ .name = "leader-cancel", .handler = leaderCancel },
    .{ .name = "vim-find-file", .handler = vimFindFile },
    .{ .name = "vim-share", .handler = vimShare },
    .{ .name = "vim-palette", .handler = vimPalette },
    .{ .name = "vim-split", .handler = vimSplit },
    .{ .name = "vim-vsplit", .handler = vimVsplit },
    .{ .name = "vim-focus-other", .handler = vimFocusOther },
    .{ .name = "vim-unsplit", .handler = vimUnsplit },
    .{ .name = "vim-win-left", .handler = vimWinLeft },
    .{ .name = "vim-win-right", .handler = vimWinRight },
    .{ .name = "vim-win-up", .handler = vimWinUp },
    .{ .name = "vim-win-down", .handler = vimWinDown },
    .{ .name = "vim-win-move-left", .handler = vimWinMoveLeft },
    .{ .name = "vim-win-move-right", .handler = vimWinMoveRight },
    .{ .name = "vim-win-move-up", .handler = vimWinMoveUp },
    .{ .name = "vim-win-move-down", .handler = vimWinMoveDown },
    .{ .name = "vim-goto-top", .handler = vimGotoTop },
    .{ .name = "vim-center", .handler = vimCenter },
    .{ .name = "find-f", .handler = enterFindF },
    .{ .name = "find-F", .handler = enterFindBigF },
    .{ .name = "find-t", .handler = enterFindT },
    .{ .name = "find-T", .handler = enterFindBigT },
    .{ .name = "do-find-f", .handler = doFindF },
    .{ .name = "do-find-F", .handler = doFindBigF },
    .{ .name = "do-find-t", .handler = doFindT },
    .{ .name = "do-find-T", .handler = doFindBigT },
    // Count-prefix keys: `0` (digit-or-line-start) and count-aware `x`.
    .{ .name = "vim-zero", .handler = zeroKey },
    .{ .name = "vim-delete-char", .handler = deleteCharFwd },
    // The `:` ex command line (see ex.zig).
    .{ .name = "vim-ex", .handler = ex.enter },
    .{ .name = "ex-type", .handler = ex.onType },
    .{ .name = "ex-backspace", .handler = ex.onBackspace },
    .{ .name = "ex-clear", .handler = ex.onClear },
    .{ .name = "ex-run", .handler = ex.onRun },
    .{ .name = "ex-cancel", .handler = ex.onCancel },
};

/// Generated normal- and op-mode motion commands (one `vim/n/*` per motion, plus
/// a `vim/o/*` for operator-valid motions). Names are only for key binding.
const n_gen = blk: {
    var n: usize = to_objs.len; // one text-object wrapper per unique object
    for (mtable) |m| {
        n += 1;
        if (m.in_op) n += 1;
    }
    break :blk n;
};
const gen_cmds: [n_gen]Cmd = blk: {
    var arr: [n_gen]Cmd = undefined;
    var i: usize = 0;
    for (mtable) |m| {
        arr[i] = .{ .name = "vim/n/" ++ m.motion, .handler = moveByMotion(m.motion) };
        i += 1;
        if (m.in_op) {
            arr[i] = .{ .name = "vim/o/" ++ m.motion, .handler = opByMotion(m.motion) };
            i += 1;
        }
    }
    for (to_objs) |obj| {
        arr[i] = .{ .name = "vim/to/" ++ obj, .handler = objWrap(obj) };
        i += 1;
    }
    break :blk arr;
};
/// One command per count digit 1–9 (`vim-count-N`), bound to the digit keys.
const count_cmds: [9]Cmd = blk: {
    var arr: [9]Cmd = undefined;
    for (0..9) |i| arr[i] = .{
        .name = std.fmt.comptimePrint("vim-count-{d}", .{i + 1}),
        .handler = countDigit(@intCast(i + 1)),
    };
    break :blk arr;
};
const cmds = static_cmds ++ gen_cmds ++ count_cmds;

/// Commands that PRESERVE a pending count instead of clearing it: the digit keys
/// themselves, `0` (which may be a digit), and the operator entries (so `3dw`
/// keeps the 3 through the `d`). Every other command clears the count in
/// `on_command`, so a stray count can't leak into an unrelated later command.
const preserve_count = blk: {
    var arr: [cmds.len]bool = .{false} ** cmds.len;
    for (cmds, 0..) |c, i| {
        if (std.mem.startsWith(u8, c.name, "vim-count-") or
            std.mem.eql(u8, c.name, "vim-zero") or
            std.mem.startsWith(u8, c.name, "enter-op-")) arr[i] = true;
    }
    break :blk arr;
};

export fn describe() void {
    for (cmds) |c| weft.declareCommand(c.name);
}
export fn on_command(id: u32) void {
    if (id >= cmds.len) return;
    cmds[id].handler();
    if (!preserve_count[id]) pending_count = 0;
}
export fn on_pick_accept(pick_id: u32) void {
    if (pick_id == file_pick) openChosen(weft.pickChoice());
}

export fn init() void {
    weft.setFallback("normal", "default");
    weft.setFallback("visual", "normal");
    weft.setFallback("insert", "default");
    weft.textInput("normal", null);
    weft.textInput("visual", null);

    for (cmds) |c| _ = weft.register(c.name);

    // Normal-mode motion keys → the generated wrappers (drive `motions`).
    inline for (mtable) |m| weft.bindKey("normal", m.key, "vim/n/" ++ m.motion);

    // Normal-mode non-motion keys (edit primitives + vim compounds).
    const nb = [_][2][]const u8{
        .{ "i", "vim-insert" },      .{ "a", "vim-append" },
        .{ "o", "vim-open-below" },  .{ "O", "vim-open-above" },
        .{ "x", "delete-forward" },  .{ "X", "delete-backward" },
        .{ "A", "vim-append-line" }, .{ "I", "vim-insert-line" },
        .{ "D", "vim-delete-eol" },  .{ "C", "vim-change-eol" },
        .{ "S", "vim-change-line" }, .{ "J", "join-lines" },
        .{ "u", "undo" },            .{ "C-r", "redo" },
        .{ "v", "vim-visual" },      .{ "Y", "yank-line" },
        .{ "p", "paste" },           .{ "P", "paste-before" },
        .{ "d", "enter-op-delete" }, .{ "c", "enter-op-change" },
        .{ "y", "enter-op-yank" },
    };
    for (nb) |b| weft.bindKey("normal", b[0], b[1]);

    // One operator-pending mode; d/c/y set the pending operator + enter it.
    weft.textInput("op-pending", null);
    weft.menuMode("op-pending");
    weft.setFallback("op-pending", "default");
    weft.bindKey("op-pending", "Escape", "op-cancel");
    inline for (mtable) |m| if (m.in_op) weft.bindKey("op-pending", m.key, "vim/o/" ++ m.motion);
    for ([_][]const u8{ "d", "c", "y" }) |k| weft.bindKey("op-pending", k, "op-line");
    // i/a in operator-pending select a text object (di", ca(, yiw, …).
    weft.bindKey("op-pending", "i", "enter-op-inner");
    weft.bindKey("op-pending", "a", "enter-op-around");
    weft.textInput("op-to", null);
    weft.menuMode("op-to");
    weft.setFallback("op-to", "default");
    weft.bindKey("op-to", "Escape", "op-cancel");
    inline for (otable) |o| weft.bindKey("op-to", o.key, "vim/to/" ++ o.obj);

    // Count prefix: digits 1-9 accumulate in normal AND operator-pending (so both
    // `3dw` and `d3w` work). `0` becomes digit-or-line-start; `x` becomes
    // count-aware. These override the plain bindings above (last-wins).
    inline for (1..10) |d| {
        const key = std.fmt.comptimePrint("{d}", .{d});
        const cmd = std.fmt.comptimePrint("vim-count-{d}", .{d});
        weft.bindKey("normal", key, cmd);
        weft.bindKey("op-pending", key, cmd);
    }
    weft.bindKey("normal", "0", "vim-zero");
    weft.bindKey("normal", "x", "vim-delete-char");
    weft.bindKey("normal", "V", "vim-visual-line"); // linewise visual

    weft.bindKey("visual", "d", "vim-visual-delete");
    weft.bindKey("visual", "x", "vim-visual-delete");
    weft.bindKey("visual", "y", "vim-visual-yank");
    weft.bindKey("visual", "c", "vim-visual-change");
    weft.bindKey("visual", "s", "vim-visual-change"); // `s` in visual = change too
    weft.bindKey("visual", "Escape", "vim-normal");
    weft.bindKey("insert", "Escape", "vim-normal");

    // No leader/window/goto/zed MODES: those trees are key sequences now (below).
    // Only the f/F/t/T single-char capture modes remain — genuinely dynamic (the
    // next key is arbitrary text), so they stay modes, not a static chord trie.
    const finds = [_][2][]const u8{
        .{ "find-f", "do-find-f" }, .{ "find-F", "do-find-F" },
        .{ "find-t", "do-find-t" }, .{ "find-T", "do-find-T" },
    };
    for (finds) |f| {
        weft.textInput(f[0], f[1]);
        weft.bindKey(f[0], "Escape", "leader-cancel");
    }

    // The `:` command line. `ex` is a text-input mode: unbound printable keys
    // route to `ex-type` (accumulate into the line buffer, re-echoed as ":…");
    // Backspace edits, Enter executes, Escape/C-c cancel, C-u clears. No
    // fallback, so stray control keys are swallowed (a real command line).
    weft.textInput("ex", "ex-type");
    weft.bindKey("ex", "Return", "ex-run");
    weft.bindKey("ex", "KP_Enter", "ex-run");
    weft.bindKey("ex", "BackSpace", "ex-backspace");
    weft.bindKey("ex", "Escape", "ex-cancel");
    weft.bindKey("ex", "C-c", "ex-cancel");
    weft.bindKey("ex", "C-u", "ex-clear");

    const np = [_][2][]const u8{
        .{ "colon", "vim-ex" },
        .{ "f", "find-f" },
        .{ "F", "find-F" },
        .{ "t", "find-t" },
        .{ "T", "find-T" },
        .{ "C-d", "scroll-half-down" },
        .{ "C-u", "scroll-half-up" },
        .{ "C-f", "scroll-page-down" },
        .{ "C-b", "scroll-page-up" },
        .{ "C-e", "scroll-line-down" },
        .{ "C-y", "scroll-line-up" },
        .{ "C-bracketright", "goto-definition" },
    };
    for (np) |b| weft.bindKey("normal", b[0], b[1]);
    weft.bindKey("default", "C-g", "cancel");
    weft.bindKey("insert", "C-n", "complete");

    // The leader tree, as SEQUENCES rooted at `space` — `space` is just the first
    // key of a chord (isPrefix holds it pending; which-key shows the next keys),
    // NOT a mode you enter. A user config (config.js) layers a fuller tree over
    // this minimal default at prio_config.
    weft.bindKey("normal", "space space", "pick-commands"); // SPC SPC — M-x
    weft.bindKey("normal", "space f f", "vim-find-file"); // SPC f f — find file
    weft.bindKey("normal", "space c s", "vim-share"); // SPC c s — collab share
    weft.bindKey("normal", "space c h", "vim-palette"); // SPC c h — palette
    // gg / zz as two-key sequences (goto-top / center).
    weft.bindKey("normal", "g g", "vim-goto-top");
    weft.bindKey("normal", "z z", "vim-center");
    // `gc` — the comment operator (vim-commentary idiom): `gc{motion}`, `gcip`,
    // `gcc` (line, via the doubled-operator path), and `gc` over a visual span.
    // Bound in the guest so EVERY vim-based config gets it out of the box.
    weft.bindKey("normal", "g c", "enter-op-comment");
    weft.bindKey("visual", "g c", "vim-visual-comment");
    // C-w …: split/close, focus (h/j/k/l or arrows), move/swap (H/J/K/L or
    // shifted arrows). Shift lives in the letter keysym (H), not `S-h`;
    // arrows have no shifted keysym so they take an explicit `S-`.
    const win = [_][2][]const u8{
        .{ "s", "vim-split" },                .{ "v", "vim-vsplit" },
        .{ "c", "vim-unsplit" },              .{ "q", "vim-unsplit" },
        .{ "o", "vim-unsplit" },              .{ "w", "vim-focus-other" },
        .{ "C-w", "vim-focus-other" },        .{ "h", "vim-win-left" },
        .{ "j", "vim-win-down" },             .{ "k", "vim-win-up" },
        .{ "l", "vim-win-right" },            .{ "Left", "vim-win-left" },
        .{ "Down", "vim-win-down" },          .{ "Up", "vim-win-up" },
        .{ "Right", "vim-win-right" },        .{ "H", "vim-win-move-left" },
        .{ "J", "vim-win-move-down" },        .{ "K", "vim-win-move-up" },
        .{ "L", "vim-win-move-right" },       .{ "S-Left", "vim-win-move-left" },
        .{ "S-Down", "vim-win-move-down" },   .{ "S-Up", "vim-win-move-up" },
        .{ "S-Right", "vim-win-move-right" },
    };
    // Bound in `global` as `C-w <key>` SEQUENCES, so the window prefix works
    // from EVERY mode (insert, dired, magit, mid-editing) — the same universal
    // reach the old single global `C-w` menu key had, now a real chord. `C-w`
    // alone holds pending; which-key lists these as its completions. `space C-w`
    // is still inert (a distinct chord), never this — global matches only at a
    // sequence's head.
    for (win) |b| {
        var buf: [16]u8 = undefined;
        const seq = std.fmt.bufPrint(&buf, "C-w {s}", .{b[0]}) catch continue;
        weft.bindKey("global", seq, b[1]);
    }
    weft.bindKey("pick", "M-n", "pick-narrow");
    weft.bindKey("pick", "M-u", "pick-widen");
    weft.bindKey("pick", "M-s", "pick-style-cycle");

    // Block caret in normal/visual (where the cursor sits ON a cell), bar in
    // insert (between cells) — the vim convention.
    weft.runStr2("set-cursor", "normal", "block");
    weft.runStr2("set-cursor", "visual", "block");
    weft.runStr2("set-cursor", "insert", "bar");
    weft.runStr2("cursor-blink", "insert", "on");
    weft.runStr2("lsp-add", ".zig", "zls");

    weft.setMode("normal");
}

// ── Mode-entry compounds ─────────────────────────────────────────────
fn insert() void {
    weft.setMode("insert");
}
fn append() void {
    weft.run("cursor-right");
    weft.setMode("insert");
}
fn openBelow() void {
    weft.jump(lineEndOff());
    weft.run("insert-newline");
    weft.setMode("insert");
}
fn openAbove() void {
    weft.jump(lineStartOff());
    weft.run("insert-newline");
    weft.run("cursor-up");
    weft.setMode("insert");
}
fn appendLine() void {
    weft.jump(lineEndOff());
    weft.setMode("insert");
}
fn insertLine() void {
    weft.jump(lineStartOff());
    weft.setMode("insert");
}
/// LINEWISE visual (`V`): the operators snap the selection to whole lines.
var visual_linewise: bool = false;

/// The effective operated range for the current selection: verbatim charwise,
/// or expanded to whole lines (incl. the trailing newline) when linewise.
fn visualSpan(s: weft.Range) weft.Range {
    if (!visual_linewise) return s;
    const first = weft.lineAt(s.start);
    const last = weft.lineAt(s.end);
    return .{ .start = first.start, .end = @min(last.end + 1, weft.byteLen()) };
}

fn visual() void { // v — charwise
    visual_linewise = false;
    weft.run("set-mark");
    weft.setMode("visual");
}
fn visualLine() void { // V — linewise
    visual_linewise = true;
    weft.run("set-mark");
    weft.setMode("visual");
}
fn visualDelete() void {
    if (weft.selection()) |s0| {
        const s = visualSpan(s0);
        weft.yankRange(s.start, s.end, visual_linewise);
        if (weft.stampRange(.{ .start = s.start, .end = s.end })) |h| weft.runRangeArg("op.delete", h);
        weft.jump(s.start);
    }
    weft.run("clear-selection");
    visual_linewise = false;
    weft.setMode("normal");
}
fn visualYank() void {
    if (weft.selection()) |s0| {
        const s = visualSpan(s0);
        weft.yankRange(s.start, s.end, visual_linewise);
        weft.flash(s.start, s.end); // vim-goggles
    }
    weft.run("clear-selection");
    visual_linewise = false;
    weft.setMode("normal");
}

/// `c` in visual: change the selection — delete it and drop into insert (like
/// `d` but landing in insert). Was UNBOUND, so `c` fell through to normal's
/// operator-pending — a vim user selecting then `c` got nothing useful.
fn visualChange() void {
    if (weft.selection()) |s0| {
        const s = visualSpan(s0);
        weft.yankRange(s.start, s.end, visual_linewise);
        if (weft.stampRange(.{ .start = s.start, .end = s.end })) |h| weft.runRangeArg("op.delete", h);
        weft.jump(s.start);
    }
    weft.run("clear-selection");
    visual_linewise = false;
    weft.setMode("insert");
}
/// `gc` in visual mode: toggle comments over the selected lines, then return to
/// normal — the same op.comment operator the motion path uses.
fn visualComment() void {
    if (weft.selection()) |s0| {
        const s = visualSpan(s0);
        if (weft.stampRange(.{ .start = s.start, .end = s.end })) |h| weft.runRangeArg("op.comment", h);
        weft.jump(s.start);
    }
    weft.run("clear-selection");
    visual_linewise = false;
    weft.setMode("normal");
}
fn normal() void {
    // Leaving insert/visual SEALS the undo unit: `i…Esc` is one unit, so the
    // next normal-mode command (dd, x, …) is its own — `Esc` then `dd` then `u`
    // undoes just the delete, not the typing too. (Cursor motions already
    // barrier; this covers the mode-change boundary a motion doesn't.)
    weft.run("undo-barrier");
    weft.run("clear-selection");
    weft.setMode("normal");
}
fn deleteEol() void {
    const cur = weft.cursor();
    const e = lineEndOff();
    weft.yankRange(cur, e, false);
    weft.edit(.{ .start = cur, .end = e }, "");
}
fn changeEol() void {
    deleteEol();
    weft.setMode("insert");
}
fn changeLine() void {
    const l = weft.lineAt(weft.cursor());
    weft.yankRange(l.start, l.end, false);
    weft.edit(.{ .start = l.start, .end = l.end }, "");
    weft.jump(l.start);
    weft.setMode("insert");
}

// ── Register + paste ─────────────────────────────────────────────────
fn yankLine() void {
    const l = weft.lineAt(weft.cursor());
    weft.yankRange(l.start, l.end, true);
    weft.flash(l.start, l.end); // vim-goggles
}
fn paste() void {
    if (weft.registerLinewise()) {
        const l = weft.lineAt(weft.cursor());
        const r = weft.registerText();
        paste_buf[0] = '\n';
        @memcpy(paste_buf[1 .. 1 + r.len], r);
        weft.edit(.{ .start = l.end, .end = l.end }, paste_buf[0 .. 1 + r.len]);
        // The register text lands after the synthesized newline; re-stamp any
        // ferried id-span there so `dd`→`p` is a move, not a delete+create.
        weft.pasteAt(l.end + 1);
    } else {
        const off = weft.cursor();
        const r = weft.registerText();
        weft.edit(.{ .start = off, .end = off }, r);
        weft.pasteAt(off);
    }
}
fn pasteBefore() void {
    if (weft.registerLinewise()) {
        const l = weft.lineAt(weft.cursor());
        const r = weft.registerText();
        @memcpy(paste_buf[0..r.len], r);
        paste_buf[r.len] = '\n';
        weft.edit(.{ .start = l.start, .end = l.start }, paste_buf[0 .. r.len + 1]);
        weft.pasteAt(l.start); // text lands at l.start (the '\n' trails it)
    } else {
        const off = weft.cursor();
        const r = weft.registerText();
        weft.edit(.{ .start = off, .end = off }, r);
        weft.pasteAt(off);
    }
}
fn joinLines() void {
    const l = weft.lineAt(weft.cursor());
    const nxt = weft.lineAt(l.end + 1);
    if (nxt.start <= l.start) return;
    const ntext = weft.slice(nxt.start, nxt.end);
    var drop: usize = 0;
    while (drop < ntext.len and (ntext[drop] == ' ' or ntext[drop] == '\t')) drop += 1;
    weft.edit(.{ .start = l.end, .end = nxt.start + drop }, " ");
    weft.jump(l.end);
}

// ── Operators ─────────────────────────────────────────────────────────
fn enterOpDelete() void {
    op_edit_cmd = "op.delete";
    op_copies = true;
    op_after = "normal";
    weft.setMode("op-pending");
}
fn enterOpChange() void {
    op_edit_cmd = "op.delete";
    op_copies = true;
    op_after = "insert";
    weft.setMode("op-pending");
}
fn enterOpYank() void {
    op_edit_cmd = null; // pure yank, no edit
    op_copies = true;
    op_after = "normal";
    weft.setMode("op-pending");
}
/// `gc` — the comment operator. Toggles line comments over the next motion /
/// text object (or the current line, doubled as `gcc`). Doesn't touch the
/// register (op_copies=false); composes with every motion like d/c/y.
fn enterOpComment() void {
    op_edit_cmd = "op.comment";
    op_copies = false;
    op_after = "normal";
    weft.setMode("op-pending");
}
fn opCancel() void {
    weft.setMode("normal");
}
/// dd / cc / yy — linewise. The operator char repeated (bound in op-pending).
fn opLine() void {
    const l = weft.lineAt(weft.cursor());
    if (op_copies) weft.yankRange(l.start, l.end, true);
    const edit = op_edit_cmd orelse {
        weft.setMode("normal"); // yy: yank the line, nothing to edit
        return;
    };
    // A non-delete line operator (gcc) toggles over the line's content in place.
    if (!std.mem.eql(u8, edit, "op.delete")) {
        if (weft.stampRange(.{ .start = l.start, .end = l.end })) |h| weft.runRangeArg(edit, h);
        weft.jump(l.start);
        weft.setMode(op_after);
        return;
    }
    if (std.mem.eql(u8, op_after, "insert")) {
        // cc: clear the line's text, keep the line, enter insert at its start.
        if (weft.stampRange(.{ .start = l.start, .end = l.end })) |h| weft.runRangeArg("op.delete", h);
        weft.jump(l.start);
        weft.setMode("insert");
    } else {
        // dd: delete the line and its trailing newline.
        const end = @min(l.end + 1, weft.byteLen());
        if (weft.stampRange(.{ .start = l.start, .end = end })) |h| weft.runRangeArg("op.delete", h);
        weft.jump(l.start);
        weft.setMode("normal");
    }
}

// ── Files ──────────────────────────────────────────────────────────────
fn findFile() void {
    weft.openFilePick("open", ".", file_pick);
}
fn openChosen(choice: []const u8) void {
    if (choice.len == 0) return;
    weft.runStr("open", choice);
}

// ── Leader / prefix chords (bound as SEQUENCES; the leaves run from normal) ──
/// Escape out of the f/F/t/T char-capture modes (their only menu-ish remnant).
fn leaderCancel() void {
    weft.setMode("normal");
}
fn thenNormal(cmd: []const u8) void {
    weft.setMode("normal");
    weft.run(cmd);
}
fn vimFindFile() void {
    thenNormal("find-file");
}
fn vimShare() void {
    thenNormal("share");
}
fn vimPalette() void {
    thenNormal("pick-commands");
}
fn vimSplit() void {
    thenNormal("window-split");
}
fn vimVsplit() void {
    thenNormal("window-vsplit");
}
fn vimFocusOther() void {
    thenNormal("focus-other"); // cycle to the next window
}
fn vimUnsplit() void {
    thenNormal("window-close");
}
// Directional focus (C-w h/j/k/l or the arrows) and move/swap (C-w H/J/K/L
// or shifted arrows), each a one-shot out of the `window` menu mode.
fn vimWinLeft() void {
    thenNormal("window-focus-left");
}
fn vimWinRight() void {
    thenNormal("window-focus-right");
}
fn vimWinUp() void {
    thenNormal("window-focus-up");
}
fn vimWinDown() void {
    thenNormal("window-focus-down");
}
fn vimWinMoveLeft() void {
    thenNormal("window-move-left");
}
fn vimWinMoveRight() void {
    thenNormal("window-move-right");
}
fn vimWinMoveUp() void {
    thenNormal("window-move-up");
}
fn vimWinMoveDown() void {
    thenNormal("window-move-down");
}
fn vimGotoTop() void {
    weft.setMode("normal");
    weft.jump(0);
}
fn vimCenter() void {
    thenNormal("center-line");
}

// ── f/F/t/T target search ────────────────────────────────────────────
fn enterFindF() void {
    weft.setMode("find-f");
}
fn enterFindBigF() void {
    weft.setMode("find-F");
}
fn enterFindT() void {
    weft.setMode("find-t");
}
fn enterFindBigT() void {
    weft.setMode("find-T");
}
fn doFindF() void {
    doFind('f');
}
fn doFindBigF() void {
    doFind('F');
}
fn doFindT() void {
    doFind('t');
}
fn doFindBigT() void {
    doFind('T');
}
fn doFind(dir: u8) void {
    weft.setMode("normal");
    if (weft.argStr(0)) |ch| findCharImpl(dir, ch);
}
fn findCharImpl(dir: u8, ch_s: []const u8) void {
    if (ch_s.len == 0) return;
    const ch = ch_s[0];
    const cur = weft.cursor();
    const l = weft.lineAt(cur);
    const text = weft.slice(l.start, l.end);
    const rel = cur - l.start;
    const till = dir == 't' or dir == 'T';
    if (dir == 'f' or dir == 't') {
        var i = rel + 1;
        while (i < text.len) : (i += 1) if (text[i] == ch) {
            weft.jump(l.start + i - @as(usize, if (till) 1 else 0));
            return;
        };
    } else {
        var k = rel;
        while (k > 0) {
            k -= 1;
            if (text[k] == ch) {
                weft.jump(l.start + k + @as(usize, if (till) 1 else 0));
                return;
            }
        }
    }
}
