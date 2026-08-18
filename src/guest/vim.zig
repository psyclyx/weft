//! vim (wasm twin) — modal editing (src/core/catalog/vim.zig) recompiled as
//! `.wasm`. The whole keymap policy — modes, motions, operators, registers,
//! leader/window/goto chords, f/F/t/T search — expressed against the guest
//! shim. The core knows nothing of vim; this is exactly the surface a user's
//! config.js reaches, one tier down. Delete it and weft is modeless again.
//!
//! Commands register in the SAME order as `cmds`, so the per-plugin id the
//! host hands back to `on_command` indexes straight into the handler table.

const std = @import("std");
const weft = @import("weft.zig");

// ── Module state (single instance, frame thread) ─────────────────────
var reg_buf: [1 << 16]u8 = undefined;
var reg_len: usize = 0;
var reg_line: bool = false;
var paste_buf: [(1 << 16) + 1]u8 = undefined;
/// The pending operator (set on d/c/y enter; consumed by a motion).
var op_finish: []const u8 = "";
var op_after: []const u8 = "";

const file_pick = 0;

fn setReg(bytes: []const u8, linewise: bool) void {
    reg_len = @min(bytes.len, reg_buf.len);
    @memcpy(reg_buf[0..reg_len], bytes[0..reg_len]);
    reg_line = linewise;
}
fn reg() []const u8 {
    return reg_buf[0..reg_len];
}

// ── Command table (registration order == on_command id) ──────────────
const Handler = *const fn () void;
const Cmd = struct { name: []const u8, handler: Handler };
const cmds = [_]Cmd{
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
    .{ .name = "yank-selection", .handler = yankSelection },
    .{ .name = "cut-selection", .handler = cutSelection },
    .{ .name = "yank-line", .handler = yankLine },
    .{ .name = "delete-line", .handler = deleteLine },
    .{ .name = "paste", .handler = paste },
    .{ .name = "paste-before", .handler = pasteBefore },
    .{ .name = "first-non-blank", .handler = firstNonBlank },
    .{ .name = "join-lines", .handler = joinLines },
    .{ .name = "enter-op-delete", .handler = enterOpDelete },
    .{ .name = "enter-op-change", .handler = enterOpChange },
    .{ .name = "enter-op-yank", .handler = enterOpYank },
    .{ .name = "op-cancel", .handler = opCancel },
    .{ .name = "op-line", .handler = opLine },
    .{ .name = "op-motion-word-forward", .handler = opWordForward },
    .{ .name = "op-motion-word-backward", .handler = opWordBackward },
    .{ .name = "op-motion-word-end", .handler = opWordEnd },
    .{ .name = "op-motion-line-end", .handler = opLineEnd },
    .{ .name = "op-motion-line-start", .handler = opLineStart },
    .{ .name = "op-motion-doc-end", .handler = opDocEnd },
    .{ .name = "op-motion-match-bracket", .handler = opMatchBracket },
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
    // Modes: normal/visual swallow unbound text; insert keeps text input.
    weft.setFallback("normal", "default");
    weft.setFallback("visual", "normal");
    weft.setFallback("insert", "default");
    weft.textInput("normal", null);
    weft.textInput("visual", null);

    for (cmds) |c| _ = weft.register(c.name);

    const nb = [_][2][]const u8{
        .{ "h", "cursor-left" },         .{ "j", "cursor-down" },
        .{ "k", "cursor-up" },           .{ "l", "cursor-right" },
        .{ "w", "word-forward" },        .{ "b", "word-backward" },
        .{ "e", "word-end" },            .{ "W", "WORD-forward" },
        .{ "B", "WORD-backward" },       .{ "E", "WORD-end" },
        .{ "0", "line-start" },          .{ "dollar", "line-end" },
        .{ "G", "doc-end" },             .{ "asciicircum", "first-non-blank" },
        .{ "percent", "match-bracket" }, .{ "i", "vim-insert" },
        .{ "a", "vim-append" },          .{ "o", "vim-open-below" },
        .{ "O", "vim-open-above" },      .{ "x", "delete-forward" },
        .{ "X", "delete-backward" },     .{ "A", "vim-append-line" },
        .{ "I", "vim-insert-line" },     .{ "D", "vim-delete-eol" },
        .{ "C", "vim-change-eol" },      .{ "S", "vim-change-line" },
        .{ "J", "join-lines" },          .{ "u", "undo" },
        .{ "C-r", "redo" },              .{ "v", "vim-visual" },
        .{ "Y", "yank-line" },           .{ "p", "paste" },
        .{ "P", "paste-before" },        .{ "d", "enter-op-delete" },
        .{ "c", "enter-op-change" },     .{ "y", "enter-op-yank" },
    };
    for (nb) |b| weft.bindKey("normal", b[0], b[1]);

    for ([_][]const u8{ "op-delete", "op-change", "op-yank" }) |m| {
        weft.textInput(m, null);
        weft.menuMode(m);
        weft.setFallback(m, "default");
        weft.bindKey(m, "Escape", "op-cancel");
        const om = [_][2][]const u8{
            .{ "w", "op-motion-word-forward" }, .{ "b", "op-motion-word-backward" },
            .{ "e", "op-motion-word-end" },     .{ "dollar", "op-motion-line-end" },
            .{ "0", "op-motion-line-start" },   .{ "asciicircum", "op-motion-line-start" },
            .{ "G", "op-motion-doc-end" },      .{ "percent", "op-motion-match-bracket" },
        };
        for (om) |b| weft.bindKey(m, b[0], b[1]);
    }
    weft.bindKey("op-delete", "d", "op-line");
    weft.bindKey("op-change", "c", "op-line");
    weft.bindKey("op-yank", "y", "op-line");

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

    // App-only environment setup (best-effort; absent in tests).
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
    weft.run("line-end");
    weft.run("insert-newline");
    weft.setMode("insert");
}
fn openAbove() void {
    weft.run("line-start");
    weft.run("insert-newline");
    weft.run("cursor-up");
    weft.setMode("insert");
}
fn appendLine() void {
    weft.run("line-end");
    weft.setMode("insert");
}
fn insertLine() void {
    weft.run("line-start");
    weft.setMode("insert");
}
fn visual() void {
    weft.run("set-mark");
    weft.setMode("visual");
}
fn visualDelete() void {
    weft.run("delete-selection");
    weft.setMode("normal");
}
fn visualYank() void {
    yankSelection();
    weft.setMode("normal");
}
fn normal() void {
    weft.run("clear-selection");
    weft.setMode("normal");
}
fn deleteEol() void {
    weft.run("set-mark");
    weft.run("line-end");
    weft.run("delete-selection");
}
fn changeEol() void {
    deleteEol();
    weft.setMode("insert");
}
fn changeLine() void {
    weft.run("line-start");
    weft.run("set-mark");
    weft.run("line-end");
    weft.run("delete-selection");
    weft.setMode("insert");
}

// ── Register + paste ─────────────────────────────────────────────────
fn captureSel() void {
    if (weft.selection()) |s| setReg(weft.slice(s.start, s.end), false);
}
fn yankSelection() void {
    captureSel();
    weft.run("clear-selection");
}
fn cutSelection() void {
    captureSel();
    weft.run("delete-selection");
}
fn yankLine() void {
    const l = weft.lineAt(weft.cursor());
    setReg(weft.slice(l.start, l.end), true);
}
fn deleteLine() void {
    const l = weft.lineAt(weft.cursor());
    setReg(weft.slice(l.start, l.end), true);
    const end = @min(l.end + 1, weft.byteLen()); // line + trailing newline
    weft.edit(.{ .start = l.start, .end = end }, "");
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
fn firstNonBlank() void {
    const l = weft.lineAt(weft.cursor());
    const text = weft.slice(l.start, l.end);
    var i: usize = 0;
    while (i < text.len and (text[i] == ' ' or text[i] == '\t')) i += 1;
    weft.jump(l.start + i);
}
fn joinLines() void {
    const l = weft.lineAt(weft.cursor());
    const nxt = weft.lineAt(l.end + 1);
    if (nxt.start <= l.start) return; // no next line
    const ntext = weft.slice(nxt.start, nxt.end);
    var drop: usize = 0;
    while (drop < ntext.len and (ntext[drop] == ' ' or ntext[drop] == '\t')) drop += 1;
    weft.edit(.{ .start = l.end, .end = nxt.start + drop }, " ");
    weft.jump(l.end);
}

// ── Operators (generic over the pending finish/after) ────────────────
fn enterOp(finish: []const u8, after: []const u8) void {
    weft.run("set-mark");
    op_finish = finish;
    op_after = after;
    weft.setMode(if (std.mem.eql(u8, finish, "cut-selection") and std.mem.eql(u8, after, "normal"))
        "op-delete"
    else if (std.mem.eql(u8, after, "insert"))
        "op-change"
    else
        "op-yank");
}
fn enterOpDelete() void {
    enterOp("cut-selection", "normal");
}
fn enterOpChange() void {
    enterOp("cut-selection", "insert");
}
fn enterOpYank() void {
    enterOp("yank-selection", "normal");
}
fn opCancel() void {
    weft.run("clear-selection");
    weft.setMode("normal");
}
fn applyOp(motion: []const u8) void {
    weft.run(motion);
    weft.run(op_finish);
    weft.setMode(op_after);
}
fn opLine() void {
    weft.run("clear-selection");
    if (std.mem.eql(u8, op_after, "insert")) {
        changeLine();
    } else if (std.mem.eql(u8, op_finish, "yank-selection")) {
        yankLine();
        weft.setMode("normal");
    } else {
        deleteLine();
        weft.setMode("normal");
    }
}
fn opWordForward() void {
    applyOp("word-forward");
}
fn opWordBackward() void {
    applyOp("word-backward");
}
fn opWordEnd() void {
    applyOp("word-end");
}
fn opLineEnd() void {
    applyOp("line-end");
}
fn opLineStart() void {
    applyOp("line-start");
}
fn opDocEnd() void {
    applyOp("doc-end");
}
fn opMatchBracket() void {
    applyOp("match-bracket");
}

// ── Files ────────────────────────────────────────────────────────────
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
    thenNormal("doc-start");
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
/// Jump to the target char on the current line — f/t forward, F/T backward,
/// t/T stop one short (vim `till`).
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
