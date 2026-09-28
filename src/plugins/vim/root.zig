//! vim — modal editing (design §6.1) as a `.wasm` plugin, perms `{clipboard}`
//! (config-granted only, for `"+`/`"*`) grant_max edit. PURE KEYMAP POLICY: it owns modes, registers, and chords, and composes
//! the `motions` and `operators` plugins BY LATE-BOUND NAME — it contains no
//! motion or edit logic of its own. A motion returns a borrowed live `range`; in
//! normal mode vim moves the cursor to the target, in operator-pending mode it
//! hands the range to `operators.delete` ([FIX 3] — no shared-cursor side channel).
//! The core knows nothing of vim; delete it and weft is modeless.

const std = @import("std");
const weft = @import("weft");
const ex_mod = @import("weft_ex");
const regex = @import("weft_regex");
const semantic_action = weft.semantic.action.standard;

/// The `:` command line: vim's resting mode is `normal`, its command-line
/// keymap mode is `ex`. Owns the classic abbreviated ex commands (w/q/s/…) and
/// falls everything else through to the weft command registry (see ex.zig).
const ex = ex_mod.Ex("normal", "ex", "vim.ex");

// ── Register (charwise/linewise) — now the CORE register (weft.zig), shared
// with helix and any editor, so `dd`→`p` ferries a projection row's hidden id
// (a move) across editors and buffers. `yankRange` snapshots text + overlapping
// subbuffer facts; `pasteAt` re-stamps them over the inserted text. A scratch
// for assembling the linewise paste (register text plus a synthesized newline).
var paste_buf: [(1 << 16) + 1]u8 = undefined;
// Vim owns the register-prefix grammar; core only receives this transient
// generic selection and providers never learn which editor chose it.
var selected_register: u8 = 0;
/// `"+`/`"*` is pending: the system clipboard, which is not a core register
/// slot but a door (`weft.clipboardSet`/`clipboardGet`, config-granted). A
/// yank lands in the unnamed slot AND the clipboard; a paste reads the
/// clipboard. Cleared with `selected_register`.
var clip_register: bool = false;

// The standard transfer words `Y`/`p`/`P`/`yy`/`dd` lead with. Placement is
// the focused view's business, so one paste word serves `p` and `P`.
const std_yank = "std.transfer.yank";
const std_paste = "std.transfer.paste";

// ── Pending-operator state (set on d/c/y/gc; consumed by the next motion) ─
// `op_edit_cmd` is the range-arg operator to apply (null = pure yank); `op_copies`
// is whether to first yank the range into the register (d/c/y do, gc doesn't);
// `op_after` is the mode to enter after. This trio lets ANY range-arg operator —
// op.delete, op.comment, a plugin's own — ride the operator-pending machinery.
var op_edit_cmd: ?[]const u8 = "operators.delete";
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

/// `vim.count-take`: hand the typed count to ANOTHER plugin's motion and
/// spend it — "" when none was typed. A motion that is not vim's (snipe's
/// `3sab`) names this through its own config value, as it names
/// `vim.operate` for the pending operator, so neither side names the other.
fn countTake() void {
    var buf: [12]u8 = undefined;
    const n = pending_count;
    pending_count = 0;
    weft.setResultStr(if (n == 0) "" else std.fmt.bufPrint(&buf, "{d}", .{n}) catch "");
}

fn lineStartOff() usize {
    return weft.lineAt(weft.cursor()).start;
}
fn lineEndOff() usize {
    return weft.lineAt(weft.cursor()).end;
}

// ── Motion keys: each drives the `motions` plugin by name. `in_op` keys are
// also valid after an operator (dw, de, d$, …). ──
const MB = struct {
    key: []const u8,
    motion: []const u8,
    in_op: bool,
    /// The standard intention this key prefers (architecture §10.2). Bound
    /// AHEAD of the motion: where the focus offers row/column navigation the
    /// domain answers, everywhere else vim's own motion runs. Vim names no
    /// view, no provider, and asks nothing about either.
    intention: ?[]const u8 = null,
    /// A JUMP in vim's sense (`:help jump-motions`): the position it leaves
    /// goes on the jumplist, so C-o comes back.
    jump: bool = false,
};
const mtable = [_]MB{
    .{ .key = "h", .motion = "motions.left", .in_op = false, .intention = "std.navigation.left" },
    .{ .key = "l", .motion = "motions.right", .in_op = false, .intention = "std.navigation.right" },
    .{ .key = "j", .motion = "motions.down", .in_op = false, .intention = "std.navigation.down" },
    .{ .key = "k", .motion = "motions.up", .in_op = false, .intention = "std.navigation.up" },
    .{ .key = "w", .motion = "motions.word-next", .in_op = true, .intention = "std.navigation.word-next" },
    .{ .key = "b", .motion = "motions.word-prev", .in_op = true, .intention = "std.navigation.word-prev" },
    .{ .key = "e", .motion = "motions.word-end", .in_op = true, .intention = "std.navigation.word-end" },
    .{ .key = "W", .motion = "motions.big-word-next", .in_op = true, .intention = "std.navigation.big-word-next" },
    .{ .key = "B", .motion = "motions.big-word-prev", .in_op = true, .intention = "std.navigation.big-word-prev" },
    .{ .key = "E", .motion = "motions.big-word-end", .in_op = true, .intention = "std.navigation.big-word-end" },
    .{ .key = "0", .motion = "motions.line-start", .in_op = true, .intention = "std.navigation.line-start" },
    .{ .key = "dollar", .motion = "motions.line-end", .in_op = true, .intention = "std.navigation.line-end" },
    .{ .key = "asciicircum", .motion = "motions.first-non-blank", .in_op = true, .intention = "std.navigation.first-non-blank" },
    .{ .key = "G", .motion = "motions.doc-end", .in_op = true, .jump = true },
    .{ .key = "percent", .motion = "motions.match-pair", .in_op = true, .jump = true },
};

/// Normal-mode motion: run the motion `count` times, jumping to each target (the
/// range end that isn't the current cursor — the motion is direction-carrying).
fn moveByMotion(comptime motion: []const u8, comptime jump: bool) fn () void {
    return struct {
        fn h() void {
            if (jump) weft.jumpPush();
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
    if (weft.invokeIntention("std.navigation.line-start") == .invoked) return;
    const cur = weft.cursor();
    const hnd = weft.runRange("motions.line-start") orelse return;
    const r = weft.rangeEnds(hnd) orelse return;
    weft.jump(if (r.end == cur) r.start else r.end);
}

/// `x` with a count: delete `count` characters forward.
fn deleteCharFwd() void {
    var n = consumeCount();
    while (n > 0) : (n -= 1) weft.run("edit.delete-after");
}
/// The pending operator is a CHANGE (`c`) — its after-mode is insert. vim's
/// `cw`/`cW` special-case keys off this.
fn isChangeOp() bool {
    return std.mem.eql(u8, op_after, "insert");
}

/// The word rule the `motions` plugin's `w`/`e` split on, and `\b` too.
const isWordByte = regex.isWordByte;

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
    if (std.mem.eql(u8, motion, "motions.word-next")) return "motions.word-end";
    if (std.mem.eql(u8, motion, "motions.big-word-next")) return "motions.big-word-end";
    return "";
}

/// An INCLUSIVE motion covers the endpoint CHARACTER (vim `e`/`E`): the motion's
/// range end is the last byte of the word, so as an operator target it must be
/// extended one byte — otherwise `de`/`ce` stop one char short (delete "cns" of
/// "cnst"). Exclusive motions (`w`, `b`, `0`, `$`) already land past their span.
fn isInclusiveMotion(m: []const u8) bool {
    return std.mem.eql(u8, m, "motions.word-end") or std.mem.eql(u8, m, "motions.big-word-end");
}

/// Extend an anchored range's end by one byte (clamped to the buffer) — the
/// inclusive-motion fixup, so the operator covers the endpoint character.
fn inclusiveEnd(hnd: u32) u32 {
    const r = weft.rangeEnds(hnd) orelse return hnd;
    const end2 = @min(r.end + 1, weft.byteLen());
    if (end2 == r.end) return hnd;
    return weft.anchorRange(.{ .start = r.start, .end = end2 }) orelse hnd;
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
            const hnd = weft.anchorRange(.{ .start = lo, .end = hi }) orelse return opCancel();
            applyOpRange(hnd);
        }
    }.h;
}

/// Apply the pending operator over an anchored range. `op_copies` yanks it
/// into the register first (d/c/y); `op_edit_cmd` then runs the gated edit
/// (op.delete for d/c, op.comment for gc, …) and enters the after-mode. A pure
/// yank (no edit command) flashes and returns to normal.
fn applyOpRange(hnd: u32) void {
    const r = weft.rangeEnds(hnd) orelse return opCancel();
    if (op_copies) yankCurrent(r.start, r.end, false);
    if (op_edit_cmd) |cmd| {
        weft.runRangeArg(cmd, hnd);
        flashAfter(hnd);
        weft.jump(r.start);
        enterAfterOp();
    } else {
        weft.flash(r.start, r.end); // vim-goggles: flash the yanked region
        weft.jump(r.start);
        weft.exitToResting();
    }
}

/// vim-goggles for an EDIT operator: flash what the operator left in the
/// anchored range, re-read after the edit — an indent, a case change, or a
/// comment toggle keeps a span to show; a delete collapses it to nothing,
/// and nothing is flashed.
fn flashAfter(hnd: u32) void {
    const after = weft.rangeEnds(hnd) orelse return;
    if (after.end > after.start) weft.flash(after.start, after.end);
}

/// `vim-operate <range>`: apply the pending operator over a range ANOTHER
/// plugin computed. This is the door a motion that has to read keys before
/// it knows its target (snipe's `d z a b`) composes through: it cannot be
/// a synchronous range command like `motions`' — its answer arrives a key
/// or two later — so it hands the range back here, and `d`/`c`/`y`/`gc`
/// apply exactly as they do over `w` or `iw`.
fn operate() void {
    const hnd = weft.argRange(0) orelse return opCancel();
    applyOpRange(hnd);
}

// ── Text objects: `i`/`a` in operator-pending enter the inner or around
// text-object mode; the object key drives the `textobjects` plugin. ──
const OB = struct { key: []const u8, obj: []const u8 };
const otable = [_]OB{
    .{ .key = "w", .obj = "word" },                .{ .key = "W", .obj = "big-word" },
    .{ .key = "quotedbl", .obj = "quote-double" }, .{ .key = "apostrophe", .obj = "quote-single" },
    .{ .key = "grave", .obj = "quote-back" },      .{ .key = "parenleft", .obj = "paren" },
    .{ .key = "parenright", .obj = "paren" },      .{ .key = "b", .obj = "paren" },
    .{ .key = "bracketleft", .obj = "bracket" },   .{ .key = "bracketright", .obj = "bracket" },
    .{ .key = "braceleft", .obj = "brace" },       .{ .key = "braceright", .obj = "brace" },
    .{ .key = "B", .obj = "brace" },               .{ .key = "p", .obj = "paragraph" },
    .{ .key = "f", .obj = "function" },            .{ .key = "c", .obj = "class" },
    .{ .key = "m", .obj = "call" },
};
const to_objs = [_][]const u8{ "word", "big-word", "quote-double", "quote-single", "quote-back", "paren", "bracket", "brace", "paragraph", "function", "class", "call" };

/// Run textobjects.<variant>-<obj> and apply the pending operator over its
/// range — the same path motions take. The variant is the command's own, not
/// state `i`/`a` left behind: `d i w` runs `vim.operate-inner-word`, so which-key
/// in `d i` reads `Inner Word` and in `d a` reads `A Word`.
fn objWrap(comptime variant: []const u8, comptime obj: []const u8) fn () void {
    return struct {
        fn h() void {
            const hnd = weft.runRange("textobjects." ++ variant ++ "-" ++ obj) orelse return opCancel();
            applyOpRange(hnd);
        }
    }.h;
}
fn enterOpInner() void {
    weft.setMode("op-inner");
}
fn enterOpAround() void {
    weft.setMode("op-around");
}

fn enterRegister() void {
    selected_register = 0;
    clip_register = false;
    weft.setMode("register-pending");
}

/// `"+` / `"*`: the next yank also takes the system clipboard, the next paste
/// reads from it. There is one desktop clipboard here — primary selection is
/// not bound — so `*` names the same one `+` does.
fn chooseClipboard() void {
    selected_register = 0;
    clip_register = true;
    weft.exitToResting();
}

// ── Macros: `q<reg>` records, `q` stops, `@<reg>` plays, `@@` replays ─────
// The recorder and the registers are core's (`macro-*` commands); vim only
// says which keys drive them. `q` in a tool entry is still workspace-back —
// that arm runs first, and nothing in a text buffer offers it.

fn macroQ() void {
    if (weft.macroRecording() != null) {
        weft.run("macro.record-stop");
        return;
    }
    weft.setMode("macro-record-pending");
}
fn macroRecordInto(comptime reg: u8) fn () void {
    return struct {
        fn h() void {
            weft.exitToResting();
            const name = [_]u8{reg};
            weft.runStr("macro.record-start", &name);
        }
    }.h;
}
fn macroAt() void {
    weft.setMode("macro-play-pending"); // keeps a typed count for `3@a`
}
/// Play `reg` (0 = the last one played) `count` times. Back at rest first:
/// the keys replay from normal, the way they were typed.
fn macroPlay(comptime reg: u8) fn () void {
    return struct {
        fn h() void {
            const n = consumeCount();
            weft.exitToResting();
            var buf: [12]u8 = undefined;
            const count = std.fmt.bufPrint(&buf, "{d}", .{n}) catch "1";
            const name = [_]u8{reg};
            weft.runStr2("macro.play", if (reg == 0) "" else &name, count);
        }
    }.h;
}

fn chooseRegister(comptime index: u8) fn () void {
    return struct {
        fn h() void {
            selected_register = index;
            weft.exitToResting();
        }
    }.h;
}

// ── The static command table (registration order == on_command id) ────
/// A vim verb is a one-cursor program: dispatch runs it once per selection.
const each = weft.Arity.each_extent;
const static_cmds = [_]weft.CommandEntry{
    .{ .name = "vim.insert", .call = insert, .arity = each, .summary = "Enter insert mode before the cursor.", .label = "Insert" },
    .{ .name = "vim.append", .call = append, .arity = each, .summary = "Enter insert mode after the cursor.", .label = "Append" },
    .{ .name = "vim.open-below", .call = openBelow, .arity = each, .summary = "Open a new line below the cursor's line and start inserting on it.", .label = "Open Line Below" },
    .{ .name = "vim.open-above", .call = openAbove, .arity = each, .summary = "Open a new line above the cursor's line and start inserting on it.", .label = "Open Line Above" },
    .{ .name = "vim.visual", .call = visual, .arity = each, .summary = "Start a characterwise visual selection at the cursor.", .label = "Visual Mode" },
    .{ .name = "vim.visual-delete", .call = visualDelete, .arity = .whole, .summary = "Delete the visual selection into the register.", .label = "Delete Selection" },
    .{ .name = "vim.visual-delete-text", .call = visualDeleteText, .arity = each, .summary = "Delete the visual selection's text into the register, one caret at a time.", .internal = true },
    .{ .name = "vim.visual-yank", .call = visualYank, .arity = .whole, .summary = "Copy the visual selection into the register.", .label = "Yank Selection", .icon = "copy" },
    .{ .name = "vim.visual-yank-text", .call = visualYankText, .arity = each, .summary = "Copy the visual selection's text into the register, one caret at a time.", .internal = true },
    .{ .name = "vim.visual-paste", .call = visualPaste(true), .arity = .whole, .summary = "Paste the register after the visual selection.", .label = "Paste After Selection", .icon = "clipboard-paste" },
    .{ .name = "vim.visual-paste-before", .call = visualPaste(false), .arity = .whole, .summary = "Paste the register before the visual selection.", .label = "Paste Before Selection", .icon = "clipboard-paste" },
    .{ .name = "vim.visual-change", .call = visualChange, .arity = each, .summary = "Delete the visual selection into the register and start inserting in its place.", .label = "Change Selection" },
    .{ .name = "vim.visual-comment", .call = visualOp("comment.toggle"), .arity = each, .summary = "Toggle comments over the visual selection.", .label = "Comment Selection" },
    .{ .name = "vim.visual-upcase", .call = visualOp("operators.upcase"), .arity = each, .summary = "Uppercase the visual selection.", .label = "Uppercase Selection", .icon = "case-upper" },
    .{ .name = "vim.visual-lowercase", .call = visualOp("operators.lowercase"), .arity = each, .summary = "Lowercase the visual selection.", .label = "Lowercase Selection", .icon = "case-lower" },
    .{ .name = "vim.visual-indent", .call = visualOp("indent.increase"), .arity = each, .summary = "Indent the lines of the visual selection one level.", .label = "Indent Selection", .icon = "indent-increase" },
    .{ .name = "vim.visual-dedent", .call = visualOp("indent.decrease"), .arity = each, .summary = "Dedent the lines of the visual selection one level.", .label = "Dedent Selection", .icon = "indent-decrease" },
    .{ .name = "vim.upcase", .call = enterOpUpcase, .arity = .whole, .summary = "Uppercase the text the next motion or text object covers.", .label = "Uppercase", .icon = "case-upper" },
    .{ .name = "vim.lowercase", .call = enterOpLowercase, .arity = .whole, .summary = "Lowercase the text the next motion or text object covers.", .label = "Lowercase", .icon = "case-lower" },
    .{ .name = "vim.indent", .call = enterOpIndent, .arity = .whole, .summary = "Indent the lines the next motion or text object covers.", .label = "Indent", .icon = "indent-increase" },
    .{ .name = "vim.dedent", .call = enterOpDedent, .arity = .whole, .summary = "Dedent the lines the next motion or text object covers.", .label = "Dedent", .icon = "indent-decrease" },
    .{ .name = "vim.visual-line", .call = visualLine, .arity = each, .summary = "Start a linewise visual selection at the cursor's line.", .label = "Visual Line Mode" },
    .{ .name = "vim.visual-as-char", .call = visualSwitch(.char), .arity = .whole, .summary = "In visual mode: make the selection charwise where it stands, or leave visual mode when it already is.", .label = "Charwise Selection" },
    .{ .name = "vim.visual-as-line", .call = visualSwitch(.line), .arity = .whole, .summary = "In visual mode: make the selection linewise where it stands, or leave visual mode when it already is.", .label = "Linewise Selection" },
    .{ .name = "vim.visual-swap-ends", .call = visualSwapEnds, .arity = .whole, .summary = "Move to the other end of the visual selection.", .label = "Other End of Selection" },
    .{ .name = "vim.visual-reselect", .call = visualReselect, .arity = .whole, .summary = "Select the last visual selection again, charwise or linewise as it was.", .label = "Reselect Last Visual" },
    .{ .name = "vim.visual-leave", .call = leaveVisual, .arity = .whole, .summary = "Leave visual mode, remembering the selection for gv.", .label = "Leave Visual Mode" },
    .{ .name = "vim.normal", .call = normal, .arity = .whole, .summary = "Return to normal mode, clearing the selection and sealing the undo step.", .label = "Normal Mode" },
    .{ .name = "vim.append-line-end", .call = appendLine, .arity = each, .summary = "Start inserting at the end of the cursor's line.", .label = "Append at Line End" },
    .{ .name = "vim.insert-line-start", .call = insertLine, .arity = each, .summary = "Start inserting at the start of the cursor's line.", .label = "Insert at Line Start" },
    .{ .name = "vim.delete-line-end", .call = deleteEol, .arity = each, .summary = "Delete from the cursor to the end of the line into the register.", .label = "Delete to Line End" },
    .{ .name = "vim.change-line-end", .call = changeEol, .arity = each, .summary = "Delete from the cursor to the end of the line and start inserting.", .label = "Change to Line End" },
    .{ .name = "vim.change-line", .call = changeLine, .arity = each, .summary = "Clear the cursor's line into the register and start inserting on it.", .label = "Change Line" },
    .{ .name = "vim.yank-line", .call = yankLine, .arity = .whole, .summary = "Copy the cursor's line, or the selected rows, into the register.", .label = "Yank Line", .icon = "copy" },
    .{ .name = "vim.yank-line-text", .call = yankLineText, .arity = each, .summary = "Copy the cursor's line of text into the register, one caret at a time.", .internal = true },
    .{ .name = "vim.paste", .call = paste, .arity = .whole, .summary = "Paste the register after the cursor.", .label = "Paste", .icon = "clipboard-paste" },
    .{ .name = "vim.paste-text", .call = pasteText(true), .arity = each, .summary = "Paste the register's text after each caret.", .internal = true },
    .{ .name = "vim.paste-before", .call = pasteBefore, .arity = .whole, .summary = "Paste the register before the cursor.", .label = "Paste Before", .icon = "clipboard-paste" },
    .{ .name = "vim.paste-before-text", .call = pasteText(false), .arity = each, .summary = "Paste the register's text before each caret.", .internal = true },
    .{ .name = "vim.transfer-cut", .call = transferCut, .arity = .whole, .summary = "Delete the visual selection into the register: what Cut means over text in vim.", .internal = true },
    .{ .name = "vim.transfer-copy", .call = transferCopy, .arity = .whole, .summary = "Yank the visual selection into the register: what Copy means over text in vim.", .internal = true },
    .{ .name = "vim.transfer-paste", .call = transferPaste, .arity = .whole, .summary = "Put the register after the caret: what Paste means over text in vim.", .internal = true },
    .{ .name = "vim.next-line", .call = openFocused, .arity = .whole, .summary = "Move to the first non-blank character of the next line.", .label = "Next Line" },
    .{ .name = "vim.prev-line", .call = openContainer, .arity = .whole, .summary = "Move to the first non-blank character of the previous line.", .label = "Previous Line" },
    .{ .name = "vim.join-lines", .call = joinLines, .arity = each, .summary = "Join the next line onto the cursor's line with a single space.", .label = "Join Lines" },
    .{ .name = "vim.delete", .call = enterOpDelete, .arity = .whole, .summary = "Delete the text the next motion or text object covers into the register.", .label = "Delete" },
    .{ .name = "vim.change", .call = enterOpChange, .arity = .whole, .summary = "Delete the text the next motion or text object covers and start inserting.", .label = "Change" },
    .{ .name = "vim.yank", .call = enterOpYank, .arity = .whole, .summary = "Copy the text the next motion or text object covers into the register.", .label = "Yank", .icon = "copy" },
    .{ .name = "vim.comment", .call = enterOpComment, .arity = .whole, .summary = "Toggle comments over the lines the next motion or text object covers.", .label = "Comment" },
    .{ .name = "vim.cancel-operator", .call = opCancel, .arity = .whole, .summary = "Cancel the pending operator and return to the resting mode.", .internal = true },
    .{ .name = "vim.operate", .call = operate, .arity = each, .summary = "Apply the pending operator over a range another plugin computed.", .internal = true },
    .{ .name = "vim.operate-line", .call = opLine, .arity = .whole, .summary = "Apply the pending operator to the whole line, or to the selected rows.", .label = "Whole Line" },
    .{ .name = "vim.operate-line-text", .call = opLineText, .arity = each, .summary = "Apply the pending operator to the cursor's line of text, one caret at a time.", .internal = true },
    .{ .name = "vim.object-inner", .call = enterOpInner, .arity = .whole, .summary = "Choose the inner variant of the next text object.", .label = "Inner Object", .prompts = true },
    .{ .name = "vim.object-around", .call = enterOpAround, .arity = .whole, .summary = "Choose the around variant of the next text object.", .label = "Around Object", .prompts = true },
    .{ .name = "vim.select-register", .call = enterRegister, .arity = .whole, .summary = "Name the register the next yank, delete or paste uses.", .label = "Select Register", .prompts = true },
    .{ .name = "vim.register-plus", .call = chooseClipboard, .arity = .whole, .summary = "Use the system clipboard for the next yank or paste.", .internal = true },
    .{ .name = "vim.register-star", .call = chooseClipboard, .arity = .whole, .summary = "Use the system clipboard for the next yank or paste.", .internal = true },
    .{ .name = "vim.macro-record", .call = macroQ, .arity = .whole, .summary = "Start recording a macro into a register, or stop the recording in progress.", .label = "Record Macro", .prompts = true },
    .{ .name = "vim.macro-play", .call = macroAt, .arity = .whole, .summary = "Play the macro in a register, a count's times.", .label = "Play Macro", .prompts = true, .icon = "play" },
    .{ .name = "vim.macro-play-last", .call = macroPlay(0), .arity = .whole, .summary = "Replay the macro played last, a count's times.", .label = "Replay Last Macro" },
    // `"/`: the search register, the last pattern any grammar searched for.
    .{ .name = "vim.register-search", .call = chooseRegister(weft.register_search), .arity = .whole, .summary = "Use the search register, holding the last searched pattern, for the next paste.", .internal = true },
    // `vim.cancel-pending` stays: the f/F/t/T char-capture modes bind Escape to it.
    // The leader/window/goto/zed MENU MODES are gone — those trees are now key
    // SEQUENCES bound in normal/global (see install), so there's no mode to enter.
    .{ .name = "vim.cancel-pending", .call = leaderCancel, .arity = .whole, .summary = "Cancel the pending character read and return to the resting mode.", .internal = true },
    .{ .name = "vim.goto-top", .call = vimGotoTop, .arity = each, .summary = "Jump to the start of the buffer, remembering where the cursor was.", .label = "Go to Top" },
    .{ .name = "vim.find-next-char", .call = enterFindF, .arity = .whole, .summary = "Move onto the next occurrence of a typed character on the line.", .label = "Find Next Char", .prompts = true },
    .{ .name = "vim.find-prev-char", .call = enterFindBigF, .arity = .whole, .summary = "Move onto the previous occurrence of a typed character on the line.", .label = "Find Previous Char", .prompts = true },
    .{ .name = "vim.till-next-char", .call = enterFindT, .arity = .whole, .summary = "Move up to just before the next occurrence of a typed character on the line.", .label = "Till Next Char", .prompts = true },
    .{ .name = "vim.till-prev-char", .call = enterFindBigT, .arity = .whole, .summary = "Move back to just after the previous occurrence of a typed character on the line.", .label = "Till Previous Char", .prompts = true },
    .{ .name = "vim.repeat-find", .call = repeatFind, .arity = each, .summary = "Repeat the last character find in its original direction.", .label = "Repeat Find" },
    .{ .name = "vim.repeat-find-reversed", .call = repeatFindRev, .arity = each, .summary = "Repeat the last character find in the opposite direction.", .label = "Repeat Find Reversed" },
    .{ .name = "vim.replace-char", .call = enterReplaceChar, .arity = .whole, .summary = "Replace the character under the cursor with a typed one.", .label = "Replace Char", .prompts = true },
    .{ .name = "vim.do-replace-char", .call = doReplaceChar, .arity = each, .summary = "Replace the character under the cursor with the character just typed.", .internal = true },
    .{ .name = "vim.toggle-case", .call = tildeCase, .arity = each, .summary = "Toggle the case of the character under the cursor and move past it, a count's times.", .label = "Toggle Case" },
    .{ .name = "vim.do-find-next-char", .call = doFindF, .arity = each, .summary = "Move onto the next occurrence of the character just typed.", .internal = true },
    .{ .name = "vim.do-find-prev-char", .call = doFindBigF, .arity = each, .summary = "Move onto the previous occurrence of the character just typed.", .internal = true },
    .{ .name = "vim.do-till-next-char", .call = doFindT, .arity = each, .summary = "Move up to just before the next occurrence of the character just typed.", .internal = true },
    .{ .name = "vim.do-till-prev-char", .call = doFindBigT, .arity = each, .summary = "Move back to just after the previous occurrence of the character just typed.", .internal = true },
    // Count-prefix keys: `0` (digit-or-line-start) and count-aware `x`.
    .{ .name = "vim.zero", .call = zeroKey, .arity = each, .summary = "Add a zero to the count being typed, or else move to the start of the line.", .internal = true },
    .{ .name = "vim.delete-char", .call = deleteCharFwd, .arity = each, .summary = "Delete the character under the cursor, a count's times.", .label = "Delete Char" },
    .{ .name = "vim.count-take", .call = countTake, .arity = .whole, .summary = "Hand the typed count to another plugin's motion and clear it.", .internal = true },
    // The `:` ex command line — the key that OPENS it. Its five editing
    // commands come from the shared prompt, spliced in as `ex_cmds` below.
    .{ .name = "vim.ex", .call = ex.enter, .arity = .whole, .summary = "Open the command line to run an ex command.", .label = "Command Line", .prompts = true },
};

/// The `:` line's own editing commands, from the shared `prompt` library —
/// the same five every other prompt in the editor registers, mapped into
/// vim's `Cmd` so `on_command`'s id indexing stays one flat table.
const ex_cmds: [ex.commands.len]weft.CommandEntry = blk: {
    var arr: [ex.commands.len]weft.CommandEntry = undefined;
    for (ex.commands, 0..) |c, i| arr[i] = .{ .name = c.name, .call = c.handler, .arity = .whole, .summary = c.summary, .internal = true };
    break :blk arr;
};

/// Generated normal- and op-mode motion commands (one `vim.move-*` per motion,
/// plus a `vim.operate-to-*` for operator-valid motions, and a
/// `vim.operate-inner-*` and `vim.operate-around-*` per text object). Every one
/// is a key a person presses — `w`, `d $`, `d i w` — so each has a label
/// which-key reads in its chord; none is machinery.
const n_gen = blk: {
    var n: usize = 2 * to_objs.len; // an inner and an around wrapper per object
    for (mtable) |m| {
        n += 1;
        if (m.in_op) n += 1;
    }
    break :blk n;
};
const gen_cmds: [n_gen]weft.CommandEntry = blk: {
    @setEvalBranchQuota(20000); // matching each motion and object to its prose
    var arr: [n_gen]weft.CommandEntry = undefined;
    var i: usize = 0;
    for (mtable) |m| {
        arr[i] = .{
            .name = "vim.move-" ++ motionWord(m.motion),
            .call = moveByMotion(m.motion, m.jump),
            .arity = each,
            .summary = "Move the cursor " ++ motionProse(motionWord(m.motion)) ++ ", once per count.",
            .label = motionLabel(motionWord(m.motion)),
        };
        i += 1;
        if (m.in_op) {
            arr[i] = .{
                .name = "vim.operate-to-" ++ motionWord(m.motion),
                .call = opByMotion(m.motion),
                .arity = each,
                .summary = "Apply the pending operator from the cursor " ++ motionProse(motionWord(m.motion)) ++ ".",
                .label = "To " ++ motionLabel(motionWord(m.motion)),
            };
            i += 1;
        }
    }
    for (to_objs) |obj| {
        arr[i] = .{
            .name = "vim.operate-inner-" ++ obj,
            .call = objWrap("inner", obj),
            .arity = each,
            .summary = "Apply the pending operator over the inside of the " ++ objectProse(obj) ++ " around the cursor.",
            .label = "Inner " ++ objectLabel(obj),
        };
        arr[i + 1] = .{
            .name = "vim.operate-around-" ++ obj,
            .call = objWrap("around", obj),
            .arity = each,
            .summary = "Apply the pending operator over the " ++ objectProse(obj) ++ " around the cursor, its delimiters or surrounding space included.",
            .label = "A " ++ objectLabel(obj),
        };
        i += 2;
    }
    break :blk arr;
};

/// `big-word-next` → `Next WORD`: a generated motion as a person reads it.
fn motionLabel(comptime word: []const u8) []const u8 {
    const pairs = .{
        .{ "left", "Character Left" },
        .{ "right", "Character Right" },
        .{ "down", "Line Below" },
        .{ "up", "Line Above" },
        .{ "word-next", "Next Word" },
        .{ "word-prev", "Previous Word" },
        .{ "word-end", "End of Word" },
        .{ "big-word-next", "Next WORD" },
        .{ "big-word-prev", "Previous WORD" },
        .{ "big-word-end", "End of WORD" },
        .{ "line-start", "Start of Line" },
        .{ "line-end", "End of Line" },
        .{ "first-non-blank", "First Non-Blank" },
        .{ "doc-end", "End of Buffer" },
        .{ "match-pair", "Matching Bracket" },
    };
    inline for (pairs) |p| {
        if (std.mem.eql(u8, p[0], word)) return p[1];
    }
    @compileError("vim: no label for the motion " ++ word);
}

/// `quote-double` → `Double-Quoted String`: a text object as a label reads it.
fn objectLabel(comptime obj: []const u8) []const u8 {
    const pairs = .{
        .{ "word", "Word" },
        .{ "big-word", "WORD" },
        .{ "quote-double", "Double-Quoted String" },
        .{ "quote-single", "Single-Quoted String" },
        .{ "quote-back", "Backtick-Quoted String" },
        .{ "paren", "Parenthesised Block" },
        .{ "bracket", "Bracketed Block" },
        .{ "brace", "Braced Block" },
        .{ "paragraph", "Paragraph" },
        .{ "function", "Function" },
        .{ "class", "Class" },
        .{ "call", "Function Call" },
    };
    inline for (pairs) |p| {
        if (std.mem.eql(u8, p[0], obj)) return p[1];
    }
    @compileError("vim: no label for the text object " ++ obj);
}

/// `big-word-next` → `to the start of the next WORD`: a generated motion
/// command's target, as the phrase its summary reads.
fn motionProse(comptime word: []const u8) []const u8 {
    const pairs = .{
        .{ "left", "one character left" },
        .{ "right", "one character right" },
        .{ "down", "one line down" },
        .{ "up", "one line up" },
        .{ "word-next", "to the start of the next word" },
        .{ "word-prev", "to the start of the previous word" },
        .{ "word-end", "to the end of the word" },
        .{ "big-word-next", "to the start of the next WORD" },
        .{ "big-word-prev", "to the start of the previous WORD" },
        .{ "big-word-end", "to the end of the WORD" },
        .{ "line-start", "to the start of the line" },
        .{ "line-end", "to the end of the line" },
        .{ "first-non-blank", "to the line's first non-blank character" },
        .{ "doc-end", "to the end of the buffer" },
        .{ "match-pair", "to the matching bracket" },
    };
    inline for (pairs) |p| {
        if (std.mem.eql(u8, p[0], word)) return p[1];
    }
    return "to where " ++ word ++ " lands";
}

/// `quote-double` → `double-quoted string`: a text object, as its summary reads.
fn objectProse(comptime obj: []const u8) []const u8 {
    const pairs = .{
        .{ "big-word", "WORD" },
        .{ "quote-double", "double-quoted string" },
        .{ "quote-single", "single-quoted string" },
        .{ "quote-back", "backtick-quoted string" },
        .{ "paren", "parenthesised block" },
        .{ "bracket", "bracketed block" },
        .{ "brace", "braced block" },
        .{ "call", "function call" },
    };
    inline for (pairs) |p| {
        if (std.mem.eql(u8, p[0], obj)) return p[1];
    }
    return obj; // word, paragraph, function, class
}

const register_cmds: [26]weft.CommandEntry = blk: {
    @setEvalBranchQuota(20000); // two comptimePrints per register
    var arr: [26]weft.CommandEntry = undefined;
    for (0..26) |i| {
        const c: u8 = 'a' + @as(u8, @intCast(i));
        arr[i] = .{
            .name = std.fmt.comptimePrint("vim.register-{c}", .{c}),
            .call = chooseRegister(@intCast(i + 1)),
            .arity = .whole,
            .summary = std.fmt.comptimePrint("Use register {c} for the next yank, delete or paste.", .{c}),
            .internal = true,
        };
    }
    break :blk arr;
};
/// One command per count digit 1–9 (`vim.count-N`), bound to the digit keys.
const count_cmds: [9]weft.CommandEntry = blk: {
    @setEvalBranchQuota(10000); // two comptimePrints per digit
    var arr: [9]weft.CommandEntry = undefined;
    for (0..9) |i| arr[i] = .{
        .name = std.fmt.comptimePrint("vim.count-{d}", .{i + 1}),
        .call = countDigit(@intCast(i + 1)),
        .arity = .whole,
        .summary = std.fmt.comptimePrint("Add the digit {d} to the count being typed.", .{i + 1}),
        .internal = true,
    };
    break :blk arr;
};
/// `q<a-z>` records into, and `@<a-z>` plays, one macro register each.
const macro_cmds: [52]weft.CommandEntry = blk: {
    @setEvalBranchQuota(40000); // four comptimePrints per register
    var arr: [52]weft.CommandEntry = undefined;
    for (0..26) |i| {
        const c: u8 = 'a' + @as(u8, @intCast(i));
        arr[i] = .{
            .name = std.fmt.comptimePrint("vim.macro-record-{c}", .{c}),
            .call = macroRecordInto(c),
            .arity = .whole,
            .summary = std.fmt.comptimePrint("Start recording a macro into register {c}.", .{c}),
            .internal = true,
        };
        arr[26 + i] = .{
            .name = std.fmt.comptimePrint("vim.macro-play-{c}", .{c}),
            .call = macroPlay(c),
            .arity = .whole,
            .summary = std.fmt.comptimePrint("Play the macro in register {c}, a count's times.", .{c}),
            .internal = true,
        };
    }
    break :blk arr;
};
const cmds = static_cmds ++ ex_cmds ++ register_cmds ++ gen_cmds ++ count_cmds ++ macro_cmds;

/// The keys that ENTER operator-pending (`d`, `c`, `y`, `g c`, …) and pick a
/// text object's extent (`i`, `a`): what a count and a register survive.
const operator_entries = [_][]const u8{
    "vim.change",    "vim.comment", "vim.dedent", "vim.delete",       "vim.indent",
    "vim.lowercase", "vim.upcase",  "vim.yank",   "vim.object-inner", "vim.object-around",
};
fn isOperatorEntry(comptime name: []const u8) bool {
    for (operator_entries) |e| if (std.mem.eql(u8, e, name)) return true;
    return false;
}

/// `motions.big-word-next` → `big-word-next`: the motion a generated key
/// command is named for.
fn motionWord(comptime motion: []const u8) []const u8 {
    const prefix = "motions.";
    if (!std.mem.startsWith(u8, motion, prefix)) @compileError("not a motions command: " ++ motion);
    return motion[prefix.len..];
}

/// Commands that PRESERVE a pending count instead of clearing it: the digit keys
/// themselves, `0` (which may be a digit), and the operator entries (so `3dw`
/// keeps the 3 through the `d`). Every other command clears the count in
/// `on_command`, so a stray count can't leak into an unrelated later command.
const preserve_count = blk: {
    @setEvalBranchQuota(40000); // scanning every command name at comptime
    var arr: [cmds.len]bool = .{false} ** cmds.len;
    for (cmds, 0..) |c, i| {
        if (std.mem.startsWith(u8, c.name, "vim.count-") or
            std.mem.eql(u8, c.name, "vim.zero") or
            std.mem.eql(u8, c.name, "vim.macro-play") or
            isOperatorEntry(c.name)) arr[i] = true;
    }
    break :blk arr;
};
/// A named slot survives only across the immediate operation that consumes it:
/// the selector itself and an operator entry preserve it; ordinary motion or
/// unrelated commands clear it, preventing a stale `"a` from leaking.
const preserve_register = blk: {
    @setEvalBranchQuota(40000);
    var arr: [cmds.len]bool = .{false} ** cmds.len;
    for (cmds, 0..) |c, i| {
        // `vim.count-take` too: another plugin's motion reads the count
        // mid-operator (`"a d 3 z a b`), and the slot is the operator's.
        if (std.mem.startsWith(u8, c.name, "vim.register-") or
            isOperatorEntry(c.name) or
            std.mem.eql(u8, c.name, "vim.count-take")) arr[i] = true;
    }
    break :blk arr;
};

comptime {
    // `.clipboard` is declared for the approval surface to show; it confers
    // nothing — only the config's `weft.grant("vim", "clipboard")` does.
    // Every entry says its arity: a verb is `each`; what only enters a mode,
    // picks a register or opens a window says `.whole`.
    weft.plugin(&cmds, .{ .init = initExtra, .after = settle, .perms = &.{.clipboard} }).exportAll();
}

/// The dispatch epilogue: a stray count or a named slot must not leak into an
/// unrelated later command. It is the manifest's `after` hook rather than a tail
/// pasted onto `on_command`, so the index it indexes is the TABLE's — not
/// whatever id the host happened to assign.
fn settle(index: usize) void {
    if (!preserve_count[index]) pending_count = 0;
    if (!preserve_register[index]) {
        selected_register = 0;
        clip_register = false;
    }
}
fn initExtra() void {
    weft.setFallback("normal", "default");
    // Source bindings layer over normal editing without changing the head's
    // actual mode or its insert/visual transitions.
    weft.setFallback("normal-source", "normal");
    weft.setFallback("normal-structural", "normal");
    // Which layer is which is vim's to say: core pairs the entry's facet
    // with this declaration and knows neither mode name.
    weft.bindingVariant(.source, "normal", "normal-source");
    weft.bindingVariant(.structural, "normal", "normal-structural");
    weft.setFallback("visual", "normal");
    weft.setFallback("insert", "default");
    // Only insert commits typed text. `normal`/`visual` need no opt-out:
    // a mode commits text ONLY where it says so (architecture §10.1).
    weft.textInput("insert", "edit.insert-text");

    // §10.4: what each POSTURE means in vim's own vocabulary (and, implicitly,
    // that `normal` is a mode a buffer rests in — not visual/insert). Vim's
    // answer to both is `normal`: it already commits nothing, so vim needs no
    // second mode; what a structural entry changes is that vim declines to
    // ENTER an insert-like state at all (`enterInsert`). Declared explicitly
    // all the same — core reads the answer on entry switch, and a default
    // nobody wrote down is one nobody can change.
    weft.restingPosture(.text, "normal");
    weft.restingPosture(.structural, "normal");
    // What the transfer words mean over text (`transferCut`/…): Cut and Copy
    // over a visual selection, Paste anywhere text is.
    const visual_text = &[_]weft.Predicate{ .{ .posture = "text" }, .{ .mode = "visual" } };
    weft.provide("selection.cut", .{ .all = visual_text }, "vim.transfer-cut", 0);
    weft.provide("selection.copy", .{ .all = visual_text }, "vim.transfer-copy", 0);
    weft.provide("selection.paste-after", .{ .posture = "text" }, "vim.transfer-paste", 0);
    // What each mode is called on the status line, as vim's own mode line
    // says it. A mode left unnamed (a count, a register, a menu) shows the
    // mode the entry rests in; `visual` is renamed V-LINE while it is
    // linewise (`visualLine`).
    weft.modeDisplay("normal", "NORMAL", .normal);
    weft.modeDisplay("insert", "INSERT", .insert);
    weft.modeDisplay("visual", "VISUAL", .select);
    weft.modeDisplay("op-pending", "O-PENDING", .pending);
    weft.modeDisplay("op-to", "O-PENDING", .pending);
    weft.modeDisplay("replace-char", "REPLACE", .replace);
    // Editable listings: focusing a row edits its name (doc/chrome.md §5.2).
    weft.runStr2("mode.set-structural-focus", "normal", "text");
    // The break-out chord capture can never take away (§10.4), retained in
    // both the state vim rests in and the one it types in.
    for ([_][]const u8{ "normal", "insert" }) |m|
        weft.bindKeys(m, "C-backslash", &.{"std.input.break-out"});

    // Normal-mode motion keys → the generated wrappers (drive `motions`). A
    // motion with a standard intention binds the LIST: the intention first,
    // the motion as its fallback (architecture §10.2).
    inline for (mtable) |m| {
        if (m.intention) |intent| {
            weft.bindKeys("normal", m.key, &.{ intent, "vim.move-" ++ comptime motionWord(m.motion) });
        } else weft.bindKey("normal", m.key, "vim.move-" ++ comptime motionWord(m.motion));
    }
    // The arrows carry the same row/column intentions as h/j/k/l; their text
    // fallbacks are the modeless floor's own cursor commands.
    const arrows = [_][3][]const u8{
        .{ "Left", "std.navigation.left", "cursor.left" },
        .{ "Right", "std.navigation.right", "cursor.right" },
        .{ "Up", "std.navigation.up", "cursor.up" },
        .{ "Down", "std.navigation.down", "cursor.down" },
    };
    for (arrows) |a| weft.bindKeys("normal", a[0], &.{ a[1], a[2] });

    // Shared intentions with a vim fallback. `Return` activates the focused
    // target where the focus offers one and is vim's `+` (down, first
    // non-blank) in text; `Tab` opens or closes children and is the modeless
    // floor's tab elsewhere; `q` is workspace-back and nothing in a text
    // buffer. Vim asks no view what it is — an unoffered intention simply
    // yields to the next entry.
    const intended = [_][3][]const u8{
        .{ "Return", "std.target.activate", "vim.next-line" },
        .{ "KP_Enter", "std.target.activate", "vim.next-line" },
        .{ "u", "std.history.undo", "edit.undo" },
        .{ "C-r", "std.history.redo", "edit.redo" },
    };
    for (intended) |b| weft.bindKeys("normal", b[0], &.{ b[1], b[2] });
    // Normal-mode Tab folds or nothing — it never inserts.
    weft.bindKeys("normal", "Tab", &.{"std.hierarchy.toggle-expanded"});
    // …and `q` then records a macro, where nothing offered workspace-back.
    weft.bindKeys("normal", "q", &.{ "std.navigation.back", "vim.macro-record" });
    // The line break is the other half of §10.2's `Return` list — vim commits
    // one from insert, never from normal, so the two entries live in the two
    // postures rather than in one list a mode would have to disambiguate.
    weft.bindKeys("insert", "Return", &.{ "std.editing.insert-line-break", "edit.insert-newline" });
    weft.bindKeys("insert", "KP_Enter", &.{ "std.editing.insert-line-break", "edit.insert-newline" });

    // Normal-mode non-motion keys (edit primitives + vim compounds).
    const nb = [_][2][]const u8{
        .{ "i", "vim.insert" },          .{ "a", "vim.append" },
        .{ "o", "vim.open-below" },      .{ "O", "vim.open-above" },
        .{ "x", "edit.delete-after" },   .{ "X", "edit.delete-before" },
        .{ "A", "vim.append-line-end" }, .{ "I", "vim.insert-line-start" },
        .{ "D", "vim.delete-line-end" }, .{ "C", "vim.change-line-end" },
        .{ "S", "vim.change-line" },     .{ "J", "vim.join-lines" },
        .{ "v", "vim.visual" },          .{ "Y", "vim.yank-line" },
        .{ "p", "vim.paste" },           .{ "P", "vim.paste-before" },
        .{ "d", "vim.delete" },          .{ "c", "vim.change" },
        .{ "y", "vim.yank" },            .{ "quotedbl", "vim.select-register" },
    };
    for (nb) |b| weft.bindKey("normal", b[0], b[1]);
    // `-` steps OUT of the focused container where something encloses it, and
    // is vim's previous-line/first-non-blank everywhere else.
    weft.bindKeys("normal", "minus", &.{ "std.hierarchy.step-out", "vim.prev-line" });

    // One operator-pending mode; d/c/y set the pending operator + enter it.
    weft.menuMode("op-pending");
    weft.setFallback("op-pending", "default");
    weft.bindKey("op-pending", "Escape", "vim.cancel-operator");
    inline for (mtable) |m| if (m.in_op) weft.bindKey("op-pending", m.key, "vim.operate-to-" ++ comptime motionWord(m.motion));
    // The doubled operator is linewise (dd, yy, cc, gUU, guu; gcc's second key
    // `c` is already here). Each maps to op-line, which applies whatever operator
    // is pending to the current line.
    for ([_][]const u8{ "d", "c", "y", "u", "U", "greater", "less" }) |k| weft.bindKey("op-pending", k, "vim.operate-line");
    // i/a in operator-pending select a text object (di", ca(, yiw, …).
    weft.bindKey("op-pending", "i", "vim.object-inner");
    weft.bindKey("op-pending", "a", "vim.object-around");
    inline for (.{ "inner", "around" }) |variant| {
        const mode = "op-" ++ variant;
        weft.menuMode(mode);
        weft.setFallback(mode, "default");
        weft.bindKey(mode, "Escape", "vim.cancel-operator");
        inline for (otable) |o| weft.bindKey(mode, o.key, "vim.operate-" ++ variant ++ "-" ++ o.obj);
    }

    // A register prefix is a generic input mode, not a files/editor special
    // case. The selected slot is consumed by the next semantic action.
    weft.menuMode("register-pending");
    weft.setFallback("register-pending", "default");
    weft.bindKey("register-pending", "Escape", "vim.cancel-operator");
    inline for (0..26) |i| weft.bindKey(
        "register-pending",
        std.fmt.comptimePrint("{c}", .{@as(u8, 'a') + @as(u8, @intCast(i))}),
        std.fmt.comptimePrint("vim.register-{c}", .{@as(u8, 'a') + @as(u8, @intCast(i))}),
    );
    weft.bindKey("register-pending", "plus", "vim.register-plus");
    weft.bindKey("register-pending", "asterisk", "vim.register-star");
    weft.bindKey("register-pending", "slash", "vim.register-search");

    // Macros: `q` then a letter records, `@` then a letter plays, `@@` plays
    // the last one again. Both prompts are menus, like the register prefix.
    weft.bindKey("normal", "at", "vim.macro-play");
    for ([_][]const u8{ "macro-record-pending", "macro-play-pending" }) |m| {
        weft.menuMode(m);
        weft.setFallback(m, "default");
        weft.bindKey(m, "Escape", "vim.cancel-operator");
    }
    for (0..26) |i| {
        const key = [_]u8{'a' + @as(u8, @intCast(i))};
        weft.bindKey("macro-record-pending", &key, macro_cmds[i].name);
        weft.bindKey("macro-play-pending", &key, macro_cmds[26 + i].name);
    }
    weft.bindKey("macro-play-pending", "at", "vim.macro-play-last");

    // Count prefix: digits 1-9 accumulate in normal AND operator-pending (so both
    // `3dw` and `d3w` work). `0` becomes digit-or-line-start; `x` becomes
    // count-aware. These override the plain bindings above (last-wins).
    inline for (1..10) |d| {
        const key = std.fmt.comptimePrint("{d}", .{d});
        const cmd = std.fmt.comptimePrint("vim.count-{d}", .{d});
        weft.bindKey("normal", key, cmd);
        weft.bindKey("op-pending", key, cmd);
    }
    weft.bindKey("normal", "0", "vim.zero");
    weft.bindKey("normal", "x", "vim.delete-char");
    weft.bindKey("normal", "V", "vim.visual-line"); // linewise visual

    weft.bindKey("visual", "d", "vim.visual-delete");
    weft.bindKey("visual", "x", "vim.visual-delete");
    weft.bindKey("visual", "y", "vim.visual-yank");
    weft.bindKey("visual", "p", "vim.visual-paste");
    weft.bindKey("visual", "P", "vim.visual-paste-before");
    weft.bindKey("visual", "c", "vim.visual-change");
    weft.bindKey("visual", "s", "vim.visual-change"); // `s` in visual = change too
    weft.bindKey("visual", "Escape", "vim.visual-leave");
    // Inside visual, v and V switch kind where the selection stands (the
    // same kind leaves); o moves to its other end. gv selects the last one
    // again, of its kind.
    weft.bindKey("visual", "v", "vim.visual-as-char");
    weft.bindKey("visual", "V", "vim.visual-as-line");
    weft.bindKey("visual", "o", "vim.visual-swap-ends");
    weft.bindKey("visual", "O", "vim.visual-swap-ends");
    weft.bindKey("normal", "g v", "vim.visual-reselect");
    weft.bindKey("insert", "Escape", "vim.normal");

    // No leader/window/goto/zed MODES: those trees are key sequences now (below).
    // Only the f/F/t/T single-char capture modes remain — genuinely dynamic (the
    // next key is arbitrary text), so they stay modes, not a static chord trie.
    const finds = [_][2][]const u8{
        .{ "find-f", "vim.do-find-next-char" }, .{ "find-F", "vim.do-find-prev-char" },
        .{ "find-t", "vim.do-till-next-char" }, .{ "find-T", "vim.do-till-prev-char" },
    };
    for (finds) |f| {
        weft.textInput(f[0], f[1]);
        weft.bindKey(f[0], "Escape", "vim.cancel-pending");
    }
    // `r<char>` — same single-key capture shape as f/t (the next key is arbitrary).
    weft.textInput("replace-char", "vim.do-replace-char");
    weft.bindKey("replace-char", "Escape", "vim.cancel-pending");

    // The `:` command line. Its mode and keys are the shared prompt's — the
    // same Escape/C-c/C-u/Backspace that back out of git's branch name and
    // lsp's rename, because there is one implementation of "a line of text"
    // and it is not vim's private one.
    ex.install();

    const np = [_][2][]const u8{
        .{ "colon", "vim.ex" },
        .{ "f", "vim.find-next-char" },
        .{ "F", "vim.find-prev-char" },
        .{ "t", "vim.till-next-char" },
        .{ "T", "vim.till-prev-char" },
        .{ "semicolon", "vim.repeat-find" }, // ; repeat last f/t
        .{ "comma", "vim.repeat-find-reversed" }, //  , repeat reversed
        .{ "r", "vim.replace-char" }, // r<char> replace under cursor
        .{ "asciitilde", "vim.toggle-case" }, // ~ toggle case under cursor
        .{ "C-d", "scroll.half-page-down" },
        .{ "C-u", "scroll.half-page-up" },
        .{ "C-f", "scroll.page-down" },
        .{ "C-b", "scroll.page-up" },
        .{ "C-e", "scroll.line-down" },
        .{ "C-y", "scroll.line-up" },
    };
    for (np) |b| weft.bindKey("normal", b[0], b[1]);
    weft.bindKey("normal-source", "C-bracketright", "lsp.goto-definition");
    weft.bindKey("default", "C-g", "collab.cancel");
    weft.bindKey("insert", "C-n", "complete.show");

    // The leader tree, as SEQUENCES rooted at `space` — `space` is just the first
    // key of a chord (isPrefix holds it pending; which-key shows the next keys),
    // NOT a mode you enter. A user config (config.js) layers a fuller tree over
    // this minimal default at prio_config.
    weft.bindKey("normal", "space space", "palette.open"); // SPC SPC — M-x
    weft.bindKey("normal", "space f f", "files.find"); // SPC f f — find file
    // gg / zz as two-key sequences (goto-top / center).
    weft.bindKey("normal", "g g", "vim.goto-top");
    weft.bindKey("normal", "z z", "scroll.center-line");
    // `gc` — the comment operator (vim-commentary idiom): `gc{motion}`, `gcip`,
    // `gcc` (line, via the doubled-operator path), and `gc` over a visual span.
    // Bound in the guest so EVERY vim-based config gets it out of the box.
    weft.bindKey("normal", "g c", "vim.comment");
    weft.bindKey("visual", "g c", "vim.visual-comment");
    // `gU`/`gu` case operators (guu/gUU for the line; charwise over a motion).
    weft.bindKey("normal", "g U", "vim.upcase");
    weft.bindKey("normal", "g u", "vim.lowercase");
    weft.bindKey("visual", "U", "vim.visual-upcase"); // vim: U/u case a selection
    weft.bindKey("visual", "u", "vim.visual-lowercase");
    // `>`/`<` indent operators (>> / << for the line; >ip / <j over a motion).
    weft.bindKey("normal", "greater", "vim.indent");
    weft.bindKey("normal", "less", "vim.dedent");
    weft.bindKey("visual", "greater", "vim.visual-indent"); // > / < on a selection
    weft.bindKey("visual", "less", "vim.visual-dedent");
    // C-w …: split/close, focus (h/j/k/l or arrows), move/swap (H/J/K/L or
    // shifted arrows). Shift lives in the letter keysym (H), not `S-h`;
    // arrows have no shifted keysym so they take an explicit `S-`.
    const win = [_][2][]const u8{
        .{ "s", "window.split-below" },      .{ "v", "window.split-right" },
        .{ "c", "window.close" },            .{ "q", "window.close" },
        .{ "o", "window.close" },            .{ "w", "window.focus-next" },
        .{ "C-w", "window.focus-next" },     .{ "h", "window.focus-left" },
        .{ "j", "window.focus-down" },       .{ "k", "window.focus-up" },
        .{ "l", "window.focus-right" },      .{ "Left", "window.focus-left" },
        .{ "Down", "window.focus-down" },    .{ "Up", "window.focus-up" },
        .{ "Right", "window.focus-right" },  .{ "H", "window.move-left" },
        .{ "J", "window.move-down" },        .{ "K", "window.move-up" },
        .{ "L", "window.move-right" },       .{ "S-Left", "window.move-left" },
        .{ "S-Down", "window.move-down" },   .{ "S-Up", "window.move-up" },
        .{ "S-Right", "window.move-right" },
    };
    // Bound in `global` as `C-w <key>` SEQUENCES, so the window prefix works
    // from EVERY mode (insert, structured views, mid-editing) — the same universal
    // reach the old single global `C-w` menu key had, now a real chord. `C-w`
    // alone holds pending; which-key lists these as its completions. `space C-w`
    // is still inert (a distinct chord), never this — global matches only at a
    // sequence's head.
    for (win) |b| {
        var buf: [16]u8 = undefined;
        const seq = std.fmt.bufPrint(&buf, "C-w {s}", .{b[0]}) catch continue;
        weft.bindKey("global", seq, b[1]);
    }
    weft.bindKey("pick", "M-n", "pick.narrow");
    weft.bindKey("pick", "M-u", "pick.widen");
    weft.bindKey("pick", "M-s", "pick.cycle-style");

    // Block caret in normal/visual (where the cursor sits ON a cell), bar in
    // insert (between cells) — the vim convention.
    weft.runStr2("cursor.set-style", "normal", "block");
    weft.runStr2("cursor.set-style", "visual", "block");
    weft.runStr2("cursor.set-style", "insert", "bar");
    weft.runStr2("cursor.set-blink", "insert", "on");
    // Language servers come from config now (weft.set("lsp","<lang>","<cmd>")),
    // read by the `lsp` plugin — no lsp-add registry.

    weft.setMode("normal");
}

// ── Mode-entry compounds ─────────────────────────────────────────────
/// Enter vim's insert-like state — the ONE door every `i`/`a`/`o`/`c`/`R`
/// path takes. §10.4: the entry DECLARES how it rests, and an entry that is
/// not `text` (or a `field`, which scopes commits to the field) does not take
/// insert-like states at all. Vim declines here rather than parking the user
/// in a mode whose every keystroke the edit door would refuse — the mode-leak
/// class, read off the declaration instead of asked of a tool.
fn enterInsert() void {
    switch (weft.posture()) {
        .text, .field => weft.setMode("insert"),
        .structural, .capture => weft.echo("this entry takes no text"),
    }
}

/// The after-mode a finished operator lands in (`c` → insert, everything else
/// → normal), through the same posture door.
fn enterAfterOp() void {
    if (std.mem.eql(u8, op_after, "insert")) enterInsert() else weft.setMode(op_after);
}

fn insert() void {
    enterInsert();
}
fn append() void {
    weft.run("cursor.right");
    enterInsert();
}
fn openBelow() void {
    if (weft.invokeIntention("std.editing.insert-after") == .invoked) {
        enterInsert();
        return;
    }
    weft.jump(lineEndOff());
    weft.run("edit.insert-newline");
    enterInsert();
}
fn openAbove() void {
    if (weft.invokeIntention("std.editing.insert-before") == .invoked) {
        enterInsert();
        return;
    }
    weft.jump(lineStartOff());
    weft.run("edit.insert-newline");
    weft.run("cursor.up");
    enterInsert();
}
fn appendLine() void {
    weft.jump(lineEndOff());
    enterInsert();
}
fn insertLine() void {
    weft.jump(lineStartOff());
    enterInsert();
}
/// LINEWISE visual (`V`): the operators snap the selection to whole lines.
///
/// Written ONLY where visual mode is entered (`v` false, `V` true) — the one
/// way into it — and never cleared on the way out. A visual verb over several
/// carets is one run per extent, and every run must read the visual state the
/// user chose: when each run cleared it on leaving, the first run (the last
/// caret) was linewise and every later one charwise. Nothing reads it outside
/// visual mode, so there is nothing a stale value could reach.
var visual_linewise: bool = false;

/// The range a visual verb operates on: the selection verbatim when
/// charwise; when linewise, every line from the selection's anchor to its
/// head, the trailing newline included. Linewise reads the ENDS, never the
/// selected text: `V` covers its line before anything moves, when anchor and
/// head still sit on one offset and `weft.selection()` (text, or nothing) has
/// nothing to say — so `V d` deleted nothing.
fn visualRange() ?weft.Range {
    rememberVisual();
    if (!visual_linewise) return weft.selection();
    const sel = weft.selections();
    if (sel.items.len == 0) return null;
    const x = sel.items[sel.primary];
    if (x.kind != .text) return null;
    const first = weft.lineAt(@min(x.anchor, x.head));
    const last = weft.lineAt(@max(x.anchor, x.head));
    const r: weft.Range = .{ .start = first.start, .end = @min(last.end + 1, weft.byteLen()) };
    return if (r.end > r.start) r else null;
}

/// Yank a visual range. A linewise register holds its lines without the
/// last line break — `yy`'s form, which `put` completes with one of its own —
/// so `V y p` lands the line once, not followed by an empty one.
fn yankVisual(s: weft.Range) void {
    var end = s.end;
    if (visual_linewise and end > s.start and weft.slice(end - 1, end)[0] == '\n') end -= 1;
    yankCurrent(s.start, end, visual_linewise);
}

const VisualKind = enum { char, line };

/// THE one writer of visual's kind. One `visual` mode, linewise by this
/// plugin's own flag, and its name on the status line follows the flag as
/// vim's `-- VISUAL LINE --` does — so both are written here, together, from
/// one value. Written apart (`v`'s and `V`'s own lines), a way in that set
/// one and not the other showed a chip naming the kind the operators were
/// not acting on.
fn setVisualKind(kind: VisualKind) void {
    visual_linewise = kind == .line;
    weft.modeDisplay("visual", switch (kind) {
        .char => "VISUAL",
        .line => "V-LINE",
    }, .select);
}

fn visual() void { // v — charwise
    setVisualKind(.char);
    weft.run("selection.start");
    weft.setMode("visual");
}
fn visualLine() void { // V — linewise
    setVisualKind(.line);
    // Over a listing's rows a line IS a row: the range is rows, whatever
    // part of the row is focused.
    weft.run(if (weft.posture() == .text) "selection.start" else "selection.start-rows");
    weft.setMode("visual");
}

/// `v` / `V` inside visual, as vim has them: the other kind switches where
/// the selection stands; the same kind leaves. Over a listing's rows the
/// selection is rows or a field's text, not both, so switching starts it
/// again from the focus.
fn visualSwitch(comptime kind: VisualKind) fn () void {
    return struct {
        fn h() void {
            const now: VisualKind = if (visual_linewise) .line else .char;
            if (now == kind) return leaveVisual();
            if (weft.posture() != .text) return if (kind == .line) visualLine() else visual();
            setVisualKind(kind);
        }
    }.h;
}

/// `o` in visual: the selection's other end becomes the one that moves.
fn visualSwapEnds() void {
    const set = weft.selections();
    for (set.items) |*s| std.mem.swap(usize, &s.anchor, &s.head);
    _ = weft.setSelections(set.items, set.primary);
}

/// The last visual selection of each entry, as it stood when visual was
/// left, and its kind: what `gv` brings back (vim's `'<` and `'>`). Each is
/// held as a live range anchored in its own document — an edit elsewhere in
/// the entry carries it along, and it resolves in that entry alone
/// (`rangeEnds` refuses another), so `gv` in a file never selected in finds
/// nothing. Oldest first; the oldest gives way when the table is full.
const LastVisual = struct { range: u32, reversed: bool, kind: VisualKind };
var last_visual: [16]LastVisual = undefined;
var last_visual_n: usize = 0;

/// Where this entry's record is in `last_visual`, if one resolves here.
fn lastVisualHere() ?usize {
    for (last_visual[0..last_visual_n], 0..) |lv, i| {
        if (weft.rangeEnds(lv.range) != null) return i;
    }
    return null;
}

/// Drop record `i`, releasing its anchors.
fn forgetVisual(i: usize) void {
    weft.releaseRange(last_visual[i].range);
    std.mem.copyForwards(LastVisual, last_visual[i .. last_visual_n - 1], last_visual[i + 1 .. last_visual_n]);
    last_visual_n -= 1;
}

/// Remember the visual selection as it stands, for `gv`: read by every
/// visual verb before it acts (`visualRange`) and by Escape.
fn rememberVisual() void {
    const set = weft.selections();
    if (set.items.len == 0 or set.items[set.primary].kind != .text) return;
    const s = set.items[set.primary];
    const range = weft.anchorRange(.{ .start = @min(s.anchor, s.head), .end = @max(s.anchor, s.head) }) orelse return;
    if (!weft.retainRange(range)) return weft.releaseRange(range);
    if (lastVisualHere()) |i| forgetVisual(i);
    if (last_visual_n == last_visual.len) forgetVisual(0);
    last_visual[last_visual_n] = .{ .range = range, .reversed = s.head < s.anchor, .kind = if (visual_linewise) .line else .char };
    last_visual_n += 1;
}

/// `gv`: this entry's last visual selection again, of its kind — V-LINE
/// after a `V` — where its anchors stand now.
fn visualReselect() void {
    const last = last_visual[lastVisualHere() orelse return];
    const r = weft.rangeEnds(last.range) orelse return;
    setVisualKind(last.kind);
    const again = [_]weft.Selection{if (last.reversed) .{ .anchor = r.end, .head = r.start } else .{ .anchor = r.start, .head = r.end }};
    if (!weft.setSelections(&again, 0)) return;
    weft.setMode("visual");
}

/// Escape in visual.
fn leaveVisual() void {
    rememberVisual();
    normal();
}

/// Leave visual mode: the selection is spent.
fn endVisual() void {
    weft.run("selection.clear");
    weft.exitToResting();
}

// Visual `y`/`d`/`p` are transfer keys, routed as `yy`/`dd`/`p` are (see
// `yankLine`): over `V`'s rows the view's transfer takes every selected row
// as ONE request, else the text half maps per caret.
fn visualDelete() void {
    if (visual_linewise and yankRows(true)) return endVisual();
    weft.run("vim.visual-delete-text");
}
fn visualYank() void {
    if (visual_linewise and yankRows(false)) return endVisual();
    weft.run("vim.visual-yank-text");
}
fn visualPaste(comptime after: bool) fn () void {
    return struct {
        fn h() void {
            if (pastedRows(after)) return endVisual();
            weft.run(if (after) "vim.paste-text" else "vim.paste-before-text");
        }
    }.h;
}

fn visualDeleteText() void {
    if (weft.posture() == .field) {
        const slot = consumeRegister();
        if (semanticDid(semantic_action.copy, slot)) {
            if (semanticDid(semantic_action.delete, 0)) {
                weft.run("selection.clear");
                weft.exitToResting();
                return;
            }
        }
        selected_register = slot;
    }
    if (visualRange()) |s| {
        yankVisual(s);
        if (weft.anchorRange(.{ .start = s.start, .end = s.end })) |h| weft.runRangeArg("operators.delete", h);
        weft.jump(s.start);
    }
    weft.run("selection.clear");
    weft.exitToResting();
}
fn visualYankText() void {
    if (weft.posture() == .field) {
        const slot = consumeRegister();
        if (semanticDid(semantic_action.copy, slot)) {
            weft.run("selection.clear");
            weft.exitToResting();
            return;
        }
        selected_register = slot;
    }
    if (visualRange()) |s| {
        yankVisual(s);
        weft.flash(s.start, s.end); // vim-goggles
    }
    weft.run("selection.clear");
    weft.exitToResting();
}

/// `c` in visual: change the selection — delete it and drop into insert (like
/// `d` but landing in insert). Was UNBOUND, so `c` fell through to normal's
/// operator-pending — a vim user selecting then `c` got nothing useful.
fn visualChange() void {
    if (weft.posture() == .field) {
        const slot = consumeRegister();
        if (semanticDid(semantic_action.copy, slot) and semanticDid(semantic_action.delete, 0)) {
            weft.run("selection.clear");
            enterInsert();
            return;
        }
        selected_register = slot;
    }
    if (visualRange()) |s| {
        yankVisual(s);
        if (weft.anchorRange(.{ .start = s.start, .end = s.end })) |h| weft.runRangeArg("operators.delete", h);
        weft.jump(s.start);
    }
    weft.run("selection.clear");
    enterInsert();
}
/// A visual-mode operator: run a range-arg `cmd` (op.comment, op.upcase, …) over
/// the selection, then clear it and return to normal. `gc`/`U`/`u` in visual all
/// ride this — the same operators the motion path uses, no register touched.
fn visualOp(comptime cmd: []const u8) fn () void {
    return struct {
        fn h() void {
            if (visualRange()) |s| {
                if (weft.anchorRange(.{ .start = s.start, .end = s.end })) |hnd| {
                    weft.runRangeArg(cmd, hnd);
                    flashAfter(hnd);
                }
                weft.jump(s.start);
            }
            weft.run("selection.clear");
            weft.exitToResting();
        }
    }.h;
}
fn normal() void {
    // Leaving insert/visual SEALS the undo unit: `i…Esc` is one unit, so the
    // next normal-mode command (dd, x, …) is its own — `Esc` then `dd` then `u`
    // undoes just the delete, not the typing too. (Cursor motions already
    // barrier; this covers the mode-change boundary a motion doesn't.)
    weft.run("edit.seal-undo");
    weft.run("selection.clear");
    // §10.4: Escape RETURNS to the entry's declared resting state — it never
    // picks one. Where that is comes from the posture pairing (vim declared
    // its answer for each posture in `init`), so this asks nothing about
    // views, tools, or modes: one door, every entry.
    weft.exitToResting();
}
fn deleteEol() void {
    const cur = weft.cursor();
    const e = lineEndOff();
    yankCurrent(cur, e, false);
    weft.edit(.{ .start = cur, .end = e }, "");
}
fn changeEol() void {
    deleteEol();
    enterInsert();
}
fn changeLine() void {
    const l = weft.lineAt(weft.cursor());
    yankCurrent(l.start, l.end, false);
    weft.edit(.{ .start = l.start, .end = l.end }, "");
    weft.jump(l.start);
    enterInsert();
}

// ── Register + paste ─────────────────────────────────────────────────
fn consumeRegister() u8 {
    const value = selected_register;
    selected_register = 0;
    return value;
}
fn yankCurrent(start: usize, end: usize, linewise: bool) void {
    const slot = consumeRegister();
    weft.yankRangeIn(slot, start, end, linewise);
    if (clip_register) {
        clip_register = false;
        // A linewise yank carries its line break to the desktop, which is how
        // `"+p` (and every other editor) tells a line from a fragment.
        const text = weft.registerTextIn(slot);
        if (linewise and (text.len == 0 or text[text.len - 1] != '\n')) {
            var buf = std.ArrayList(u8).initCapacity(weft.allocator, text.len + 1) catch return;
            defer buf.deinit(weft.allocator);
            buf.appendSliceAssumeCapacity(text);
            buf.appendAssumeCapacity('\n');
            _ = weft.clipboardSet(buf.items);
        } else _ = weft.clipboardSet(text);
    }
}

/// Ask the focused view for `action` in an EXPLICIT register slot. Only the
/// `"x` prefix path needs this: the slot is part of the request, and a
/// catalog route carries no arguments.
fn semanticDid(action: []const u8, register: u8) bool {
    return switch (weft.semanticActionIn(action, register)) {
        .handled, .transfer_stored, .interaction_opened, .target_opened, .focus_changed, .relation_opened, .working_target_changed => true,
        .unavailable, .failed, _ => false,
    };
}

/// The transfer half of a compound key (`Y`, `p`, `P`, a doubled operator).
/// It asks WHO OFFERS the standard word rather than what kind of buffer this
/// is: nothing offers it over text, so the caller's own text path runs. A
/// pending `"x` names its slot explicitly, which a catalog route cannot
/// carry, so that one case goes straight to the focused view's action door —
/// and the prefix survives a refusal, for the text path to spend on the same
/// slot the user named.
fn transferred(intention: []const u8, action: []const u8) bool {
    if (selected_register == 0) {
        // Over text the word is core's, offered because vim provides what it
        // means there (`transferCut`/…): that answer is vim's own text half
        // coming back, never a view's transfer, so it does not count.
        routing = true;
        routed_back = false;
        defer routing = false;
        return weft.invokeIntention(intention) == .invoked and !routed_back;
    }
    if (!semanticDid(action, selected_register)) return false;
    selected_register = 0;
    return true;
}

/// A transfer key is asking the word whether a VIEW takes it (`transferred`).
var routing: bool = false;
/// …and the word came back to vim's own provider instead.
var routed_back: bool = false;

/// True, noting it, when the word reached vim's provider from vim's own
/// routing: the key's text half runs instead, as it always did.
fn routedBack() bool {
    if (!routing) return false;
    routed_back = true;
    return true;
}

// What the transfer words MEAN over text in vim, for a context menu's Cut,
// Copy and Paste (core offers std.transfer.* where a grammar provides the
// matching action): visual `d` and `y` over the visual selection, and `p`.
// Cut and Copy are provided in visual alone — in normal mode nothing is
// selected, so neither is offered.
fn transferCut() void {
    if (routedBack()) return;
    weft.run("vim.visual-delete-text");
}
fn transferCopy() void {
    if (routedBack()) return;
    weft.run("vim.visual-yank-text");
}
fn transferPaste() void {
    if (routedBack()) return;
    weft.run("vim.paste-text");
}

/// `Return`'s fallback: vim's ordinary `+` — next line, first non-blank. The
/// activation half is the `std.target.activate` entry bound ahead of it.
fn openFocused() void {
    const down = weft.runRange("motions.down") orelse return;
    const down_range = weft.rangeEnds(down) orelse return;
    const current = weft.cursor();
    weft.jump(if (down_range.end == current) down_range.start else down_range.end);
    const first = weft.runRange("motions.first-non-blank") orelse return;
    const first_range = weft.rangeEnds(first) orelse return;
    const after_down = weft.cursor();
    weft.jump(if (first_range.end == after_down) first_range.start else first_range.end);
}

/// `-`'s fallback: vim's previous line, first non-blank. Stepping out of a
/// container is the `std.hierarchy.step-out` arm bound ahead of it.
fn openContainer() void {
    const up = weft.runRange("motions.up") orelse return;
    const up_range = weft.rangeEnds(up) orelse return;
    const current = weft.cursor();
    weft.jump(if (up_range.end == current) up_range.start else up_range.end);
    const first = weft.runRange("motions.first-non-blank") orelse return;
    const first_range = weft.rangeEnds(first) orelse return;
    const after_up = weft.cursor();
    weft.jump(if (first_range.end == after_up) first_range.start else first_range.end);
}

// A transfer key is two verbs with two mappings. Over rows the view's
// transfer is ONE request for every selected row — run per row, each run
// would replace the one captured value. Over text it is one yank or put per
// caret. So the key's command is `.whole` and only ROUTES: to the view's
// transfer when something offers it, else to its text half, a command of
// its own that maps `each`.
fn yankLine() void {
    if (yankRows(false)) return;
    weft.run("vim.yank-line-text");
}
fn yankLineText() void {
    const l = weft.lineAt(weft.cursor());
    yankCurrent(l.start, l.end, true);
    weft.flash(l.start, l.end); // vim-goggles
}
fn paste() void {
    if (pastedRows(true)) return;
    weft.run("vim.paste-text");
}
fn pasteBefore() void {
    if (pastedRows(false)) return;
    weft.run("vim.paste-before-text");
}
/// The row half of a yank or a delete (`yy`/`dd`/`cc`, visual `y`/`d`): ONE
/// copy of every selected row, then for a delete the view's own
/// `selection.delete` — the files view FLAGS the rows, a retained delete, not
/// a removal of the register's content — reached by the name a key would
/// reach it by. False when nothing offers the transfer word: the caller's
/// text half runs.
fn yankRows(delete: bool) bool {
    if (!transferred(std_yank, semantic_action.copy)) return false;
    if (delete) weft.run("selection.delete");
    return true;
}
/// The row half of a put (`p`/`P`, visual too). `"+` names the desktop
/// clipboard, which only the text half reads.
fn pastedRows(after: bool) bool {
    return !clip_register and transferred(std_paste, if (after) semantic_action.paste_after else semantic_action.paste_before);
}
fn pasteText(comptime after: bool) fn () void {
    return struct {
        fn h() void {
            if (clip_register) return pasteClipboard(after);
            const slot = consumeRegister();
            put(weft.registerTextIn(slot), weft.registerLinewiseIn(slot), after, slot);
        }
    }.h;
}

/// `"+p`/`"+P`: paste the desktop clipboard. When it still holds what vim
/// last yanked into the unnamed slot (the SDK's `clipboardPasteSource`, the
/// rule ide and helix paste by too), paste THAT slot — the same text, plus
/// the linewise flag and any identity it ferries (`dd` then `"+p` in a files
/// listing stays a move). Otherwise it is foreign text: linewise when it
/// ends in a line break, the convention every editor copies lines with.
fn pasteClipboard(after: bool) void {
    clip_register = false;
    selected_register = 0;
    switch (weft.clipboardPasteSource()) {
        .unavailable, .empty => {},
        .register => put(weft.registerTextIn(0), weft.registerLinewiseIn(0), after, 0),
        .foreign => |text| {
            const linewise = text[text.len - 1] == '\n';
            put(if (linewise) text[0 .. text.len - 1] else text, linewise, after, null);
        },
    }
}

/// Put `r` at the caret (charwise) or on its own line below/above the caret
/// line (linewise), flash what landed, and — for a register paste — re-stamp
/// the ferried id-spans over it so `dd`→`p` is a move, not a delete+create.
fn put(r: []const u8, linewise: bool, after: bool, slot: ?u8) void {
    if (!linewise) {
        const off = weft.cursor();
        weft.edit(.{ .start = off, .end = off }, r);
        if (slot) |s| weft.pasteAtIn(s, off);
        weft.flash(off, off + r.len);
        return;
    }
    // The text plus a synthesized line break, assembled in `paste_buf` (a
    // clipboard too big for it is refused rather than truncated).
    if (r.len + 1 > paste_buf.len) return;
    const l = weft.lineAt(weft.cursor());
    if (after) {
        paste_buf[0] = '\n';
        @memcpy(paste_buf[1 .. 1 + r.len], r);
        weft.edit(.{ .start = l.end, .end = l.end }, paste_buf[0 .. 1 + r.len]);
        // The text lands after the synthesized newline.
        if (slot) |s| weft.pasteAtIn(s, l.end + 1);
        weft.flash(l.end + 1, l.end + 1 + r.len); // vim-goggles: what landed
    } else {
        @memcpy(paste_buf[0..r.len], r);
        paste_buf[r.len] = '\n';
        weft.edit(.{ .start = l.start, .end = l.start }, paste_buf[0 .. r.len + 1]);
        if (slot) |s| weft.pasteAtIn(s, l.start); // lands at l.start; the '\n' trails it
        weft.flash(l.start, l.start + r.len);
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
    weft.flash(l.end, l.end + 1); // vim-goggles: the seam the join made
    weft.jump(l.end);
}

// ── Operators ─────────────────────────────────────────────────────────
fn enterOpDelete() void {
    op_edit_cmd = "operators.delete";
    op_copies = true;
    op_after = "normal";
    weft.setMode("op-pending");
}
fn enterOpChange() void {
    op_edit_cmd = "operators.delete";
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
    op_edit_cmd = "comment.toggle";
    op_copies = false;
    op_after = "normal";
    weft.setMode("op-pending");
}
/// `gU` / `gu` — the case operators (uppercase / lowercase over a motion or text
/// object; `gUU`/`guu` for the line). Charwise like vim; no register.
fn enterOpUpcase() void {
    op_edit_cmd = "operators.upcase";
    op_copies = false;
    op_after = "normal";
    weft.setMode("op-pending");
}
fn enterOpLowercase() void {
    op_edit_cmd = "operators.lowercase";
    op_copies = false;
    op_after = "normal";
    weft.setMode("op-pending");
}
/// `>` / `<` — the indent operators (indent / dedent over a motion or text
/// object; `>>`/`<<` for the line). Linewise; no register.
fn enterOpIndent() void {
    op_edit_cmd = "indent.increase";
    op_copies = false;
    op_after = "normal";
    weft.setMode("op-pending");
}
fn enterOpDedent() void {
    op_edit_cmd = "indent.decrease";
    op_copies = false;
    op_after = "normal";
    weft.setMode("op-pending");
}
fn opCancel() void {
    selected_register = 0;
    weft.exitToResting();
}
/// dd / cc / yy — linewise. The operator char repeated (bound in op-pending).
fn opLine() void {
    // `yy`/`dd`/`cc` on a row that offers the transfer word (see `yankRows`).
    if (op_copies) {
        const edit = op_edit_cmd;
        if (yankRows(if (edit) |e| std.mem.eql(u8, e, "operators.delete") else false)) {
            if (edit == null) weft.exitToResting() else enterAfterOp();
            return;
        }
    }
    // The text half, per caret (see `yankLine`).
    weft.run("vim.operate-line-text");
}
fn opLineText() void {
    const l = weft.lineAt(weft.cursor());
    if (op_copies) yankCurrent(l.start, l.end, true);
    const edit = op_edit_cmd orelse {
        weft.exitToResting(); // yy: yank the line, nothing to edit
        return;
    };
    // A non-delete line operator (gcc) toggles over the line's content in place.
    if (!std.mem.eql(u8, edit, "operators.delete")) {
        if (weft.anchorRange(.{ .start = l.start, .end = l.end })) |h| {
            weft.runRangeArg(edit, h);
            flashAfter(h);
        }
        weft.jump(l.start);
        enterAfterOp();
        return;
    }
    if (std.mem.eql(u8, op_after, "insert")) {
        // cc: clear the line's text, keep the line, enter insert at its start.
        if (weft.anchorRange(.{ .start = l.start, .end = l.end })) |h| weft.runRangeArg("operators.delete", h);
        weft.jump(l.start);
        enterInsert();
    } else {
        // dd: delete the line and its trailing newline.
        const end = @min(l.end + 1, weft.byteLen());
        if (weft.anchorRange(.{ .start = l.start, .end = end })) |h| weft.runRangeArg("operators.delete", h);
        weft.jump(l.start);
        weft.exitToResting();
    }
}

// ── Leader / prefix chords (bound as mode-preserving SEQUENCES) ──
/// Escape out of the f/F/t/T char-capture modes (their only menu-ish remnant).
fn leaderCancel() void {
    weft.exitToResting();
}
fn vimGotoTop() void {
    weft.jumpPush();
    weft.jump(0);
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
// The last f/F/t/T target, so `;` repeats it and `,` repeats it reversed.
var last_find_dir: u8 = 0;
var last_find_char: u8 = 0;

fn doFind(dir: u8) void {
    weft.exitToResting();
    if (weft.argStr(0)) |ch| {
        if (ch.len > 0) {
            last_find_dir = dir;
            last_find_char = ch[0];
        }
        findCharImpl(dir, ch);
    }
}
/// `;` — repeat the last f/F/t/T in its original direction.
fn repeatFind() void {
    if (last_find_dir == 0) return;
    var buf = [1]u8{last_find_char};
    findCharImpl(last_find_dir, buf[0..]);
}
/// `,` — repeat the last f/F/t/T in the OPPOSITE direction.
fn repeatFindRev() void {
    const rev: u8 = switch (last_find_dir) {
        'f' => 'F',
        'F' => 'f',
        't' => 'T',
        'T' => 't',
        else => return,
    };
    var buf = [1]u8{last_find_char};
    findCharImpl(rev, buf[0..]);
}

/// `~` — toggle the case of the char(s) under the cursor and advance past them
/// (count-aware: `3~`), bounded to the line. Non-letters just advance, no edit.
fn tildeCase() void {
    var n = consumeCount();
    const l = weft.lineAt(weft.cursor());
    const start = weft.cursor();
    var pos = start;
    while (n > 0 and pos < l.end) : (n -= 1) {
        const s = weft.slice(pos, pos + 1);
        if (s.len == 0) break;
        const c = s[0];
        const flipped: u8 = if (c >= 'a' and c <= 'z') c - 32 else if (c >= 'A' and c <= 'Z') c + 32 else c;
        if (flipped != c) {
            var buf = [1]u8{flipped};
            weft.edit(.{ .start = pos, .end = pos + 1 }, buf[0..]);
        }
        pos += 1;
    }
    if (pos > start) weft.flash(start, pos); // vim-goggles
    weft.jump(pos);
}

// ── r: replace the char(s) under the cursor with the next key ─────────
var replace_count: u32 = 1;
fn enterReplaceChar() void {
    replace_count = consumeCount(); // `3rx` replaces three
    weft.setMode("replace-char");
}
/// Replace `replace_count` chars from the cursor with the typed char, bounded to
/// the current line (vim's `r` never crosses the newline). ASCII replacement for
/// now — a multibyte target/replacement is the same corner comment.zig's token
/// carries. Cursor lands on the last replaced char, as in vim.
fn doReplaceChar() void {
    weft.exitToResting();
    const ch = weft.argStr(0) orelse return;
    if (ch.len == 0) return;
    const cur = weft.cursor();
    const l = weft.lineAt(cur);
    var n = replace_count;
    var pos = cur;
    while (n > 0 and pos < l.end) : (n -= 1) {
        weft.edit(.{ .start = pos, .end = pos + 1 }, ch);
        pos += ch.len;
    }
    if (pos > cur) weft.flash(cur, pos); // vim-goggles
    weft.jump(if (pos > cur) pos - ch.len else cur);
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
