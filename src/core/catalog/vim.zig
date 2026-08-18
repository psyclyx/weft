//! vim — modal editing as a catalog plugin (the edit domain's keymap
//! policy), porting `config/init.fnl` to Zig for plan 06 (Lua removal). The
//! core knows nothing of vim: modes are keymap tables, motions are built-in
//! commands, operators are scripted compounds — exactly as the Fennel does,
//! through the same ABI. Delete this plugin and weft is a plain modeless
//! editor again.
//!
//! Two things Fennel closures gave for free that Zig fn-pointers cannot,
//! solved here without capture:
//!  - the yank REGISTER is module state (single instance, frame thread);
//!  - an OPERATOR (d/c/y) records its finish+after in module state on enter,
//!    so one generic command per MOTION applies whichever operator is
//!    pending — 3 operators × N motions collapse to N handlers.

const std = @import("std");
const abi = @import("../abi.zig");
const command = @import("../command.zig");
const V = command.Value;

// ── Module state ─────────────────────────────────────────────────────
var reg_buf: [1 << 16]u8 = undefined;
var reg_len: usize = 0;
var reg_line: bool = false;
/// The pending operator (set on d/c/y enter; consumed by a motion).
var op_finish: []const u8 = "";
var op_after: []const u8 = "";

fn setReg(bytes: []const u8, linewise: bool) void {
    reg_len = @min(bytes.len, reg_buf.len);
    @memcpy(reg_buf[0..reg_len], bytes[0..reg_len]);
    reg_line = linewise;
}
fn reg() []const u8 {
    return reg_buf[0..reg_len];
}

pub fn plugin() abi.Plugin {
    return .{ .describe = describe, .init = init };
}

fn describe() abi.Manifest {
    return .{ .name = "vim", .commands = &cmd_names };
}

// Every command this plugin registers (the manifest cross-check needs them
// all declared). Kept next to `install` so the two never drift.
const cmd_names = blk: {
    var names: [defs.len]abi.CommandDecl = undefined;
    for (defs, &names) |d, *n| n.* = .{ .name = d.name };
    break :blk names;
};

const Def = struct { name: []const u8, handler: abi.Handler };
const defs = [_]Def{
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
    // Operator enters + their per-motion appliers (generic over the pending
    // operator). `op-motion-<m>` runs motion <m>, applies, leaves.
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
    // Files.
    .{ .name = "find-file", .handler = findFile },
    // Leader / prefix chords (each just switches to a menu mode, or runs a
    // command then returns to normal).
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
    // f/F/t/T target-character search (one-shot capture modes).
    .{ .name = "find-f", .handler = enterFindF },
    .{ .name = "find-F", .handler = enterFindBigF },
    .{ .name = "find-t", .handler = enterFindT },
    .{ .name = "find-T", .handler = enterFindBigT },
    .{ .name = "do-find-f", .handler = doFindF },
    .{ .name = "do-find-F", .handler = doFindBigF },
    .{ .name = "do-find-t", .handler = doFindT },
    .{ .name = "do-find-T", .handler = doFindBigT },
};

fn init(a: *abi.Abi) anyerror!void {
    // Modes: normal/visual swallow unbound text; insert keeps text input.
    try a.setFallback("normal", "default");
    try a.setFallback("visual", "normal");
    try a.setFallback("insert", "default");
    try a.textInput("normal", null);
    try a.textInput("visual", null);

    for (defs) |d| try a.registerCommand(d.name, d.handler);

    // Normal-mode motions + insert entries (late-bound; targets are core
    // built-ins). h/j/k/l, words, line/doc, i/a/o/O/x, undo/redo, v.
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
    for (nb) |b| try a.bindKey("normal", b[0], b[1]);

    // Operator modes: which-key menus that swallow text; each motion key
    // applies the pending operator, the doubled key is linewise, Escape
    // cancels.
    for ([_][]const u8{ "op-delete", "op-change", "op-yank" }) |m| {
        try a.textInput(m, null);
        try a.menuMode(m);
        try a.setFallback(m, "default");
        try a.bindKey(m, "Escape", "op-cancel");
        const om = [_][2][]const u8{
            .{ "w", "op-motion-word-forward" }, .{ "b", "op-motion-word-backward" },
            .{ "e", "op-motion-word-end" },     .{ "dollar", "op-motion-line-end" },
            .{ "0", "op-motion-line-start" },   .{ "asciicircum", "op-motion-line-start" },
            .{ "G", "op-motion-doc-end" },      .{ "percent", "op-motion-match-bracket" },
        };
        for (om) |b| try a.bindKey(m, b[0], b[1]);
    }
    // The doubled operator key (dd/cc/yy) is the linewise whole-line form.
    try a.bindKey("op-delete", "d", "op-line");
    try a.bindKey("op-change", "c", "op-line");
    try a.bindKey("op-yank", "y", "op-line");

    // Visual mode.
    try a.bindKey("visual", "d", "vim-visual-delete");
    try a.bindKey("visual", "x", "vim-visual-delete");
    try a.bindKey("visual", "y", "vim-visual-yank");
    try a.bindKey("visual", "Escape", "vim-normal");
    // Insert mode: Escape → normal.
    try a.bindKey("insert", "Escape", "vim-normal");

    // Prefix / menu modes: swallow text, which-key on, no fallback (movement
    // keys must not leak through a pending chord). Escape returns to normal.
    for ([_][]const u8{ "leader", "leader-file", "leader-collab", "window", "goto", "zed" }) |m| {
        try a.textInput(m, null);
        try a.menuMode(m);
        try a.bindKey(m, "Escape", "leader-cancel");
    }
    // f/F/t/T capture modes: the next printable char is the target.
    const finds = [_][2][]const u8{
        .{ "find-f", "do-find-f" }, .{ "find-F", "do-find-F" },
        .{ "find-t", "do-find-t" }, .{ "find-T", "do-find-T" },
    };
    for (finds) |f| {
        try a.textInput(f[0], f[1]);
        try a.bindKey(f[0], "Escape", "leader-cancel");
    }

    // Normal-mode prefix keys.
    const np = [_][2][]const u8{
        .{ "colon", "pick-commands" }, .{ "space", "leader" },
        .{ "C-w", "window" },          .{ "g", "goto" },
        .{ "z", "zed" },               .{ "f", "find-f" },
        .{ "F", "find-F" },            .{ "t", "find-t" },
        .{ "T", "find-T" },
        // Scrolling (app commands).
                   .{ "C-d", "scroll-half-down" },
        .{ "C-u", "scroll-half-up" },  .{ "C-f", "scroll-page-down" },
        .{ "C-b", "scroll-page-up" },  .{ "C-e", "scroll-line-down" },
        .{ "C-y", "scroll-line-up" },  .{ "C-bracketright", "goto-definition" },
    };
    for (np) |b| try a.bindKey("normal", b[0], b[1]);
    try a.bindKey("default", "C-g", "cancel");
    try a.bindKey("insert", "C-n", "complete");

    // Leader chords.
    try a.bindKey("leader", "f", "leader-file");
    try a.bindKey("leader", "c", "leader-collab");
    try a.bindKey("leader", "space", "pick-commands");
    try a.bindKey("leader-file", "f", "vim-find-file");
    try a.bindKey("leader-collab", "s", "vim-share");
    try a.bindKey("leader-collab", "h", "vim-palette");
    // Window chords.
    const win = [_][2][]const u8{
        .{ "s", "vim-split" },         .{ "v", "vim-vsplit" },  .{ "w", "vim-focus-other" },
        .{ "C-w", "vim-focus-other" }, .{ "o", "vim-unsplit" }, .{ "q", "vim-unsplit" },
    };
    for (win) |b| try a.bindKey("window", b[0], b[1]);
    try a.bindKey("goto", "g", "vim-goto-top");
    try a.bindKey("zed", "z", "vim-center");
    // Picker chords (Alt keys — space is an orderless separator).
    try a.bindKey("pick", "M-n", "pick-narrow");
    try a.bindKey("pick", "M-u", "pick-widen");
    try a.bindKey("pick", "M-s", "pick-style-cycle");

    // Environment setup that only exists in the full app — tolerate absence
    // (tests load the keymap without the shell's cursor/lsp commands).
    for ([_][]const u8{ "normal", "visual", "insert" }) |m|
        runQuiet(a, "set-cursor", &.{ .{ .string = m }, .{ .string = "bar" } });
    runQuiet(a, "cursor-blink", &.{ .{ .string = "insert" }, .{ .string = "on" } });
    runQuiet(a, "lsp-add", &.{ .{ .string = ".zig" }, .{ .string = "zls" } });

    // Boot into normal.
    try a.setMode("normal");
}

// ── Mode-entry compounds ─────────────────────────────────────────────
fn insert(a: *abi.Abi, _: []const V) anyerror!V {
    try a.setMode("insert");
    return .nil;
}
fn append(a: *abi.Abi, _: []const V) anyerror!V {
    _ = try a.run("cursor-right", &.{});
    try a.setMode("insert");
    return .nil;
}
fn openBelow(a: *abi.Abi, _: []const V) anyerror!V {
    _ = try a.run("line-end", &.{});
    _ = try a.run("insert-newline", &.{});
    try a.setMode("insert");
    return .nil;
}
fn openAbove(a: *abi.Abi, _: []const V) anyerror!V {
    _ = try a.run("line-start", &.{});
    _ = try a.run("insert-newline", &.{});
    _ = try a.run("cursor-up", &.{});
    try a.setMode("insert");
    return .nil;
}
fn appendLine(a: *abi.Abi, _: []const V) anyerror!V {
    _ = try a.run("line-end", &.{});
    try a.setMode("insert");
    return .nil;
}
fn insertLine(a: *abi.Abi, _: []const V) anyerror!V {
    _ = try a.run("line-start", &.{});
    try a.setMode("insert");
    return .nil;
}
fn visual(a: *abi.Abi, _: []const V) anyerror!V {
    _ = try a.run("set-mark", &.{});
    try a.setMode("visual");
    return .nil;
}
fn visualDelete(a: *abi.Abi, _: []const V) anyerror!V {
    _ = try a.run("delete-selection", &.{});
    try a.setMode("normal");
    return .nil;
}
fn visualYank(a: *abi.Abi, _: []const V) anyerror!V {
    _ = try yankSelection(a, &.{});
    try a.setMode("normal");
    return .nil;
}
fn normal(a: *abi.Abi, _: []const V) anyerror!V {
    _ = try a.run("clear-selection", &.{});
    try a.setMode("normal");
    return .nil;
}
fn deleteEol(a: *abi.Abi, _: []const V) anyerror!V {
    _ = try a.run("set-mark", &.{});
    _ = try a.run("line-end", &.{});
    _ = try a.run("delete-selection", &.{});
    return .nil;
}
fn changeEol(a: *abi.Abi, _: []const V) anyerror!V {
    _ = try deleteEol(a, &.{});
    try a.setMode("insert");
    return .nil;
}
fn changeLine(a: *abi.Abi, _: []const V) anyerror!V {
    _ = try a.run("line-start", &.{});
    _ = try a.run("set-mark", &.{});
    _ = try a.run("line-end", &.{});
    _ = try a.run("delete-selection", &.{});
    try a.setMode("insert");
    return .nil;
}

// ── Register + paste ─────────────────────────────────────────────────
fn captureSel(a: *abi.Abi) !void {
    if (a.selection()) |s| {
        const gpa = a.host.ctx.gpa;
        const bytes = try a.slice(gpa, s.start, s.end);
        defer gpa.free(bytes);
        setReg(bytes, false);
    }
}
fn yankSelection(a: *abi.Abi, _: []const V) anyerror!V {
    try captureSel(a);
    _ = try a.run("clear-selection", &.{});
    return .nil;
}
fn cutSelection(a: *abi.Abi, _: []const V) anyerror!V {
    try captureSel(a);
    _ = try a.run("delete-selection", &.{});
    return .nil;
}
fn yankLine(a: *abi.Abi, _: []const V) anyerror!V {
    const l = a.lineAt(a.cursor());
    const gpa = a.host.ctx.gpa;
    const bytes = try a.slice(gpa, l.start, l.end);
    defer gpa.free(bytes);
    setReg(bytes, true);
    return .nil;
}
fn deleteLine(a: *abi.Abi, _: []const V) anyerror!V {
    const l = a.lineAt(a.cursor());
    const gpa = a.host.ctx.gpa;
    const bytes = try a.slice(gpa, l.start, l.end);
    defer gpa.free(bytes);
    setReg(bytes, true);
    // Delete the line plus its trailing newline (clamped at EOF).
    const end = @min(l.end + 1, a.byteLen());
    try a.edit(.{ .start = l.start, .end = end }, "");
    return .nil;
}
fn paste(a: *abi.Abi, _: []const V) anyerror!V {
    if (reg_line) {
        const l = a.lineAt(a.cursor());
        const gpa = a.host.ctx.gpa;
        const text = try std.fmt.allocPrint(gpa, "\n{s}", .{reg()});
        defer gpa.free(text);
        try a.edit(.{ .start = l.end, .end = l.end }, text);
    } else {
        const off = a.cursor();
        try a.edit(.{ .start = off, .end = off }, reg());
    }
    return .nil;
}
fn pasteBefore(a: *abi.Abi, _: []const V) anyerror!V {
    if (reg_line) {
        const l = a.lineAt(a.cursor());
        const gpa = a.host.ctx.gpa;
        const text = try std.fmt.allocPrint(gpa, "{s}\n", .{reg()});
        defer gpa.free(text);
        try a.edit(.{ .start = l.start, .end = l.start }, text);
    } else {
        const off = a.cursor();
        try a.edit(.{ .start = off, .end = off }, reg());
    }
    return .nil;
}
fn firstNonBlank(a: *abi.Abi, _: []const V) anyerror!V {
    const l = a.lineAt(a.cursor());
    const gpa = a.host.ctx.gpa;
    const text = try a.slice(gpa, l.start, l.end);
    defer gpa.free(text);
    var i: usize = 0;
    while (i < text.len and (text[i] == ' ' or text[i] == '\t')) i += 1;
    a.jump(l.start + i);
    return .nil;
}
fn joinLines(a: *abi.Abi, _: []const V) anyerror!V {
    const l = a.lineAt(a.cursor());
    const nxt = a.lineAt(l.end + 1);
    if (nxt.start <= l.start) return .nil; // no next line
    const gpa = a.host.ctx.gpa;
    const ntext = try a.slice(gpa, nxt.start, nxt.end);
    defer gpa.free(ntext);
    var drop: usize = 0;
    while (drop < ntext.len and (ntext[drop] == ' ' or ntext[drop] == '\t')) drop += 1;
    // Replace [line-end, next-start+drop) with a single space.
    try a.edit(.{ .start = l.end, .end = nxt.start + drop }, " ");
    a.jump(l.end);
    return .nil;
}

// ── Operators (generic over the pending finish/after) ────────────────
fn enterOp(a: *abi.Abi, finish: []const u8, after: []const u8) anyerror!V {
    _ = try a.run("set-mark", &.{});
    op_finish = finish;
    op_after = after;
    try a.setMode(if (std.mem.eql(u8, finish, "cut-selection") and std.mem.eql(u8, after, "normal"))
        "op-delete"
    else if (std.mem.eql(u8, after, "insert"))
        "op-change"
    else
        "op-yank");
    return .nil;
}
fn enterOpDelete(a: *abi.Abi, _: []const V) anyerror!V {
    return enterOp(a, "cut-selection", "normal");
}
fn enterOpChange(a: *abi.Abi, _: []const V) anyerror!V {
    return enterOp(a, "cut-selection", "insert");
}
fn enterOpYank(a: *abi.Abi, _: []const V) anyerror!V {
    return enterOp(a, "yank-selection", "normal");
}
fn opCancel(a: *abi.Abi, _: []const V) anyerror!V {
    _ = try a.run("clear-selection", &.{});
    try a.setMode("normal");
    return .nil;
}
/// Apply the pending operator after running `motion`.
fn applyOp(a: *abi.Abi, motion: []const u8) anyerror!V {
    _ = try a.run(motion, &.{});
    _ = try a.run(op_finish, &.{});
    try a.setMode(op_after);
    return .nil;
}
fn opLine(a: *abi.Abi, _: []const V) anyerror!V {
    // Linewise dd/cc/yy: select the whole line then apply.
    _ = try a.run("clear-selection", &.{});
    if (std.mem.eql(u8, op_after, "insert")) {
        _ = try changeLine(a, &.{});
    } else if (std.mem.eql(u8, op_finish, "yank-selection")) {
        _ = try yankLine(a, &.{});
        try a.setMode("normal");
    } else {
        _ = try deleteLine(a, &.{});
        try a.setMode("normal");
    }
    return .nil;
}
fn opWordForward(a: *abi.Abi, _: []const V) anyerror!V {
    return applyOp(a, "word-forward");
}
fn opWordBackward(a: *abi.Abi, _: []const V) anyerror!V {
    return applyOp(a, "word-backward");
}
fn opWordEnd(a: *abi.Abi, _: []const V) anyerror!V {
    return applyOp(a, "word-end");
}
fn opLineEnd(a: *abi.Abi, _: []const V) anyerror!V {
    return applyOp(a, "line-end");
}
fn opLineStart(a: *abi.Abi, _: []const V) anyerror!V {
    return applyOp(a, "line-start");
}
fn opDocEnd(a: *abi.Abi, _: []const V) anyerror!V {
    return applyOp(a, "doc-end");
}
fn opMatchBracket(a: *abi.Abi, _: []const V) anyerror!V {
    return applyOp(a, "match-bracket");
}

// ── Files ────────────────────────────────────────────────────────────
fn findFile(a: *abi.Abi, _: []const V) anyerror!V {
    try a.openFilePick("open", ".", openChosen);
    return .nil;
}
fn openChosen(a: *abi.Abi, choice: []const u8) anyerror!void {
    if (choice.len == 0) return;
    _ = try a.run("open", &.{.{ .string = choice }});
}

// ── Leader / prefix chords (mode switches + one-shot compounds) ───────
fn enterLeader(a: *abi.Abi, _: []const V) anyerror!V {
    try a.setMode("leader");
    return .nil;
}
fn enterLeaderFile(a: *abi.Abi, _: []const V) anyerror!V {
    try a.setMode("leader-file");
    return .nil;
}
fn enterLeaderCollab(a: *abi.Abi, _: []const V) anyerror!V {
    try a.setMode("leader-collab");
    return .nil;
}
fn leaderCancel(a: *abi.Abi, _: []const V) anyerror!V {
    try a.setMode("normal");
    return .nil;
}
fn thenNormal(a: *abi.Abi, cmd: []const u8) anyerror!V {
    try a.setMode("normal");
    _ = try a.run(cmd, &.{});
    return .nil;
}
fn vimFindFile(a: *abi.Abi, _: []const V) anyerror!V {
    return thenNormal(a, "find-file");
}
fn vimShare(a: *abi.Abi, _: []const V) anyerror!V {
    return thenNormal(a, "share");
}
fn vimPalette(a: *abi.Abi, _: []const V) anyerror!V {
    return thenNormal(a, "pick-commands");
}
fn enterWindow(a: *abi.Abi, _: []const V) anyerror!V {
    try a.setMode("window");
    return .nil;
}
fn vimSplit(a: *abi.Abi, _: []const V) anyerror!V {
    return thenNormal(a, "split");
}
fn vimVsplit(a: *abi.Abi, _: []const V) anyerror!V {
    return thenNormal(a, "vsplit");
}
fn vimFocusOther(a: *abi.Abi, _: []const V) anyerror!V {
    return thenNormal(a, "focus-other");
}
fn vimUnsplit(a: *abi.Abi, _: []const V) anyerror!V {
    return thenNormal(a, "unsplit");
}
fn enterGoto(a: *abi.Abi, _: []const V) anyerror!V {
    try a.setMode("goto");
    return .nil;
}
fn vimGotoTop(a: *abi.Abi, _: []const V) anyerror!V {
    return thenNormal(a, "doc-start");
}
fn enterZed(a: *abi.Abi, _: []const V) anyerror!V {
    try a.setMode("zed");
    return .nil;
}
fn vimCenter(a: *abi.Abi, _: []const V) anyerror!V {
    return thenNormal(a, "center-line");
}

// ── f/F/t/T target search ────────────────────────────────────────────
fn enterFindF(a: *abi.Abi, _: []const V) anyerror!V {
    try a.setMode("find-f");
    return .nil;
}
fn enterFindBigF(a: *abi.Abi, _: []const V) anyerror!V {
    try a.setMode("find-F");
    return .nil;
}
fn enterFindT(a: *abi.Abi, _: []const V) anyerror!V {
    try a.setMode("find-t");
    return .nil;
}
fn enterFindBigT(a: *abi.Abi, _: []const V) anyerror!V {
    try a.setMode("find-T");
    return .nil;
}
fn doFindF(a: *abi.Abi, args: []const V) anyerror!V {
    return doFind(a, 'f', args);
}
fn doFindBigF(a: *abi.Abi, args: []const V) anyerror!V {
    return doFind(a, 'F', args);
}
fn doFindT(a: *abi.Abi, args: []const V) anyerror!V {
    return doFind(a, 't', args);
}
fn doFindBigT(a: *abi.Abi, args: []const V) anyerror!V {
    return doFind(a, 'T', args);
}
fn doFind(a: *abi.Abi, dir: u8, args: []const V) anyerror!V {
    try a.setMode("normal");
    if (args.len >= 1 and args[0] == .string) try findCharImpl(a, dir, args[0].string);
    return .nil;
}
/// Jump to the target char on the current line — f/t forward, F/T backward,
/// t/T stop one short of the target (vim `till`).
fn findCharImpl(a: *abi.Abi, dir: u8, ch_s: []const u8) !void {
    if (ch_s.len == 0) return;
    const ch = ch_s[0];
    const cur = a.cursor();
    const l = a.lineAt(cur);
    const gpa = a.host.ctx.gpa;
    const text = try a.slice(gpa, l.start, l.end);
    defer gpa.free(text);
    const rel = cur - l.start;
    const till = dir == 't' or dir == 'T';
    if (dir == 'f' or dir == 't') {
        var i = rel + 1;
        while (i < text.len) : (i += 1) if (text[i] == ch) {
            a.jump(l.start + i - @as(usize, if (till) 1 else 0));
            return;
        };
    } else {
        var k = rel;
        while (k > 0) {
            k -= 1;
            if (text[k] == ch) {
                a.jump(l.start + k + @as(usize, if (till) 1 else 0));
                return;
            }
        }
    }
}

fn runQuiet(a: *abi.Abi, name: []const u8, args: []const V) void {
    _ = a.run(name, args) catch {};
}
