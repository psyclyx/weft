//! vim — modal editing (design §6.1) as a `.wasm` plugin, perms `{}` grant_max
//! edit. PURE KEYMAP POLICY: it owns modes, registers, and chords, and composes
//! the `motions` and `operators` plugins BY LATE-BOUND NAME — it contains no
//! motion or edit logic of its own. A motion returns a stamped `range`; in
//! normal mode vim moves the cursor to the target, in operator-pending mode it
//! hands the range to `op.delete` ([FIX 3] — no shared-cursor side channel).
//! The core knows nothing of vim; delete it and weft is modeless.

const std = @import("std");
const weft = @import("weft.zig");

// ── Register (charwise/linewise), owned in guest memory ──────────────
var reg_buf: [1 << 16]u8 = undefined;
var reg_len: usize = 0;
var reg_line: bool = false;
var paste_buf: [(1 << 16) + 1]u8 = undefined;
fn setReg(bytes: []const u8, linewise: bool) void {
    reg_len = @min(bytes.len, reg_buf.len);
    @memcpy(reg_buf[0..reg_len], bytes[0..reg_len]);
    reg_line = linewise;
}
fn reg() []const u8 {
    return reg_buf[0..reg_len];
}

// ── Pending-operator state (set on d/c/y; consumed by the next motion) ─
var op_is_yank: bool = false;
var op_after: []const u8 = "normal"; // mode to enter after the operator

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

/// Normal-mode motion: run the motion, jump to its target (the range end that
/// isn't the current cursor — the motion is direction-carrying that way).
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
/// Operator-pending motion: run the motion, apply the pending operator over its
/// range.
fn opByMotion(comptime motion: []const u8) fn () void {
    return struct {
        fn h() void {
            const hnd = weft.runRange(motion) orelse return opCancel();
            applyOpRange(hnd);
        }
    }.h;
}

/// Apply the pending operator over a stamped range: d/c/y all yank into the
/// register; d/c additionally delete via `op.delete` (the operators plugin's
/// gated edit) and enter the after-mode (normal for d, insert for c).
fn applyOpRange(hnd: u32) void {
    const r = weft.rangeEnds(hnd) orelse return opCancel();
    setReg(weft.slice(r.start, r.end), false);
    if (op_is_yank) {
        weft.jump(r.start);
        weft.setMode("normal");
        return;
    }
    weft.runRangeArg("op.delete", hnd);
    weft.jump(r.start);
    weft.setMode(op_after);
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
    .{ .name = "op-cancel", .handler = opCancel },
    .{ .name = "op-line", .handler = opLine },
    .{ .name = "find-file", .handler = findFile },
    .{ .name = "leader", .handler = enterLeader },
    .{ .name = "leader-file", .handler = enterLeaderFile },
    .{ .name = "leader-collab", .handler = enterLeaderCollab },
    .{ .name = "leader-cancel", .handler = leaderCancel },
    .{ .name = "vim-find-file", .handler = vimFindFile },
    .{ .name = "vim-share", .handler = vimShare },
    .{ .name = "vim-palette", .handler = vimPalette },
    .{ .name = "window", .handler = enterWindow },
    .{ .name = "vim-split", .handler = vimSplit },
    .{ .name = "vim-vsplit", .handler = vimVsplit },
    .{ .name = "vim-focus-other", .handler = vimFocusOther },
    .{ .name = "vim-unsplit", .handler = vimUnsplit },
    .{ .name = "goto", .handler = enterGoto },
    .{ .name = "vim-goto-top", .handler = vimGotoTop },
    .{ .name = "zed", .handler = enterZed },
    .{ .name = "vim-center", .handler = vimCenter },
    .{ .name = "find-f", .handler = enterFindF },
    .{ .name = "find-F", .handler = enterFindBigF },
    .{ .name = "find-t", .handler = enterFindT },
    .{ .name = "find-T", .handler = enterFindBigT },
    .{ .name = "do-find-f", .handler = doFindF },
    .{ .name = "do-find-F", .handler = doFindBigF },
    .{ .name = "do-find-t", .handler = doFindT },
    .{ .name = "do-find-T", .handler = doFindBigT },
};

/// Generated normal- and op-mode motion commands (one `vim/n/*` per motion, plus
/// a `vim/o/*` for operator-valid motions). Names are only for key binding.
const n_gen = blk: {
    var n: usize = 0;
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
    break :blk arr;
};
const cmds = static_cmds ++ gen_cmds;

export fn describe() void {
    for (cmds) |c| weft.declareCommand(c.name);
}
export fn on_command(id: u32) void {
    if (id < cmds.len) cmds[id].handler();
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

    weft.bindKey("visual", "d", "vim-visual-delete");
    weft.bindKey("visual", "x", "vim-visual-delete");
    weft.bindKey("visual", "y", "vim-visual-yank");
    weft.bindKey("visual", "Escape", "vim-normal");
    weft.bindKey("insert", "Escape", "vim-normal");

    for ([_][]const u8{ "leader", "leader-file", "leader-collab", "window", "goto", "zed" }) |m| {
        weft.textInput(m, null);
        weft.menuMode(m);
        weft.bindKey(m, "Escape", "leader-cancel");
    }
    const finds = [_][2][]const u8{
        .{ "find-f", "do-find-f" }, .{ "find-F", "do-find-F" },
        .{ "find-t", "do-find-t" }, .{ "find-T", "do-find-T" },
    };
    for (finds) |f| {
        weft.textInput(f[0], f[1]);
        weft.bindKey(f[0], "Escape", "leader-cancel");
    }

    const np = [_][2][]const u8{
        .{ "colon", "pick-commands" }, .{ "space", "leader" },
        .{ "C-w", "window" },          .{ "g", "goto" },
        .{ "z", "zed" },               .{ "f", "find-f" },
        .{ "F", "find-F" },            .{ "t", "find-t" },
        .{ "T", "find-T" },            .{ "C-d", "scroll-half-down" },
        .{ "C-u", "scroll-half-up" },  .{ "C-f", "scroll-page-down" },
        .{ "C-b", "scroll-page-up" },  .{ "C-e", "scroll-line-down" },
        .{ "C-y", "scroll-line-up" },  .{ "C-bracketright", "goto-definition" },
    };
    for (np) |b| weft.bindKey("normal", b[0], b[1]);
    weft.bindKey("default", "C-g", "cancel");
    weft.bindKey("insert", "C-n", "complete");

    weft.bindKey("leader", "f", "leader-file");
    weft.bindKey("leader", "c", "leader-collab");
    weft.bindKey("leader", "space", "pick-commands");
    weft.bindKey("leader-file", "f", "vim-find-file");
    weft.bindKey("leader-collab", "s", "vim-share");
    weft.bindKey("leader-collab", "h", "vim-palette");
    const win = [_][2][]const u8{
        .{ "s", "vim-split" },         .{ "v", "vim-vsplit" },  .{ "w", "vim-focus-other" },
        .{ "C-w", "vim-focus-other" }, .{ "o", "vim-unsplit" }, .{ "q", "vim-unsplit" },
    };
    for (win) |b| weft.bindKey("window", b[0], b[1]);
    weft.bindKey("goto", "g", "vim-goto-top");
    weft.bindKey("zed", "z", "vim-center");
    weft.bindKey("pick", "M-n", "pick-narrow");
    weft.bindKey("pick", "M-u", "pick-widen");
    weft.bindKey("pick", "M-s", "pick-style-cycle");

    for ([_][]const u8{ "normal", "visual", "insert" }) |m|
        weft.runStr2("set-cursor", m, "bar");
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
fn visual() void {
    weft.run("set-mark");
    weft.setMode("visual");
}
fn visualDelete() void {
    if (weft.selection()) |s| {
        setReg(weft.slice(s.start, s.end), false);
        if (weft.stampRange(.{ .start = s.start, .end = s.end })) |h| weft.runRangeArg("op.delete", h);
    }
    weft.run("clear-selection");
    weft.setMode("normal");
}
fn visualYank() void {
    if (weft.selection()) |s| setReg(weft.slice(s.start, s.end), false);
    weft.run("clear-selection");
    weft.setMode("normal");
}
fn normal() void {
    weft.run("clear-selection");
    weft.setMode("normal");
}
fn deleteEol() void {
    const cur = weft.cursor();
    const e = lineEndOff();
    setReg(weft.slice(cur, e), false);
    weft.edit(.{ .start = cur, .end = e }, "");
}
fn changeEol() void {
    deleteEol();
    weft.setMode("insert");
}
fn changeLine() void {
    const l = weft.lineAt(weft.cursor());
    setReg(weft.slice(l.start, l.end), false);
    weft.edit(.{ .start = l.start, .end = l.end }, "");
    weft.jump(l.start);
    weft.setMode("insert");
}

// ── Register + paste ─────────────────────────────────────────────────
fn yankLine() void {
    const l = weft.lineAt(weft.cursor());
    setReg(weft.slice(l.start, l.end), true);
}
fn paste() void {
    if (reg_line) {
        const l = weft.lineAt(weft.cursor());
        const r = reg();
        paste_buf[0] = '\n';
        @memcpy(paste_buf[1 .. 1 + r.len], r);
        weft.edit(.{ .start = l.end, .end = l.end }, paste_buf[0 .. 1 + r.len]);
    } else {
        const off = weft.cursor();
        weft.edit(.{ .start = off, .end = off }, reg());
    }
}
fn pasteBefore() void {
    if (reg_line) {
        const l = weft.lineAt(weft.cursor());
        const r = reg();
        @memcpy(paste_buf[0..r.len], r);
        paste_buf[r.len] = '\n';
        weft.edit(.{ .start = l.start, .end = l.start }, paste_buf[0 .. r.len + 1]);
    } else {
        const off = weft.cursor();
        weft.edit(.{ .start = off, .end = off }, reg());
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
    op_is_yank = false;
    op_after = "normal";
    weft.setMode("op-pending");
}
fn enterOpChange() void {
    op_is_yank = false;
    op_after = "insert";
    weft.setMode("op-pending");
}
fn enterOpYank() void {
    op_is_yank = true;
    op_after = "normal";
    weft.setMode("op-pending");
}
fn opCancel() void {
    weft.setMode("normal");
}
/// dd / cc / yy — linewise. The operator char repeated (bound in op-pending).
fn opLine() void {
    const l = weft.lineAt(weft.cursor());
    setReg(weft.slice(l.start, l.end), true);
    if (op_is_yank) {
        weft.setMode("normal");
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

// ── Leader / prefix chords ───────────────────────────────────────────
fn enterLeader() void {
    weft.setMode("leader");
}
fn enterLeaderFile() void {
    weft.setMode("leader-file");
}
fn enterLeaderCollab() void {
    weft.setMode("leader-collab");
}
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
fn enterWindow() void {
    weft.setMode("window");
}
fn vimSplit() void {
    thenNormal("split");
}
fn vimVsplit() void {
    thenNormal("vsplit");
}
fn vimFocusOther() void {
    thenNormal("focus-other");
}
fn vimUnsplit() void {
    thenNormal("unsplit");
}
fn enterGoto() void {
    weft.setMode("goto");
}
fn vimGotoTop() void {
    weft.setMode("normal");
    weft.jump(0);
}
fn enterZed() void {
    weft.setMode("zed");
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
