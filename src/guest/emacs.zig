//! emacs — NON-MODAL editing as a `.wasm` plugin, perms `{}` grant_max edit. The
//! counterpart to vim.zig: where vim proves the modal path (postures as modes +
//! chord trees as sequences), emacs proves the MODELESS path. There is ONE
//! resting mode, `emacs`, that falls back to the core `default` floor — so
//! printable keys self-insert (default's text command) and the arrows/Backspace
//! work — and every command is a CONTROL/META chord layered on top. C-x / C-c are
//! prefix key SEQUENCES (the same engine vim's `SPC f f` uses), not modes: `C-x`
//! holds pending, which-key shows its completions, `C-x C-f` completes. The
//! editor owns only intra-buffer motion/kill/yank here; the C-x/C-c tree that
//! reaches other plugins (find-file, magit, dired) is config data (emacs.js).
//! Delete this plugin and weft is still modeless — `default` is the floor.

const std = @import("std");
const weft = @import("weft");

const file_pick = 0;

// ── Intra-buffer motion (drives core cursor + the `motions` plugin by name) ──

/// Move to the start / end of the current line (C-a / C-e).
fn beginningOfLine() void {
    weft.jump(weft.lineAt(weft.cursor()).start);
}
fn endOfLine() void {
    weft.jump(weft.lineAt(weft.cursor()).end);
}
/// Move to the start / end of the buffer (M-< / M->).
fn beginningOfBuffer() void {
    weft.jump(0);
}
fn endOfBuffer() void {
    weft.jump(weft.byteLen());
}

/// Word motion via the shared `motions` plugin: run the range, jump to the end
/// that isn't the cursor (the motion carries direction). Same shape vim uses.
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

// ── Kill / yank (the kill-ring is the shared core register — the same one vim's
// dd/p uses, so a kill in emacs pastes in vim and vice versa) ──

/// C-k: kill from point to end of line; at end-of-line, kill the newline (pull
/// the next line up). The killed text goes to the register (charwise).
fn killLine() void {
    const cur = weft.cursor();
    const l = weft.lineAt(cur);
    const end = if (cur < l.end) l.end else if (l.end < weft.byteLen()) l.end + 1 else return;
    weft.yankRange(cur, end, false);
    weft.edit(.{ .start = cur, .end = end }, "");
}

/// C-w: kill the region (mark…point); M-w: copy it (no delete). Both use the
/// active selection set by C-space (set-mark) + motion.
fn killRegion() void {
    const s = weft.selection() orelse return;
    weft.yankRange(s.start, s.end, false);
    weft.edit(.{ .start = s.start, .end = s.end }, "");
}
fn copyRegion() void {
    const s = weft.selection() orelse return;
    weft.yankRange(s.start, s.end, false);
    weft.flash(s.start, s.end); // confirm what was copied
    weft.run("clear-selection"); // emacs deactivates the mark after M-w
}

/// C-y: yank (paste) the register at point, re-stamping any ferried id-spans so
/// a killed projection row moves rather than copies.
fn yank() void {
    const cur = weft.cursor();
    const txt = weft.registerText();
    if (txt.len == 0) return;
    const n = txt.len;
    weft.edit(.{ .start = cur, .end = cur }, txt);
    weft.pasteAt(cur);
    weft.jump(cur + n);
}

// ── find-file (like vim's: this editor owns the file picker) ──
fn findFile() void {
    weft.openFilePick("open", ".", file_pick);
}
fn openChosen(choice: []const u8) void {
    if (choice.len == 0) return;
    weft.runStr("open", choice);
}

// ── Command table (registration order == on_command id) ──
const Cmd = struct { name: []const u8, handler: *const fn () void };
const cmds = [_]Cmd{
    .{ .name = "find-file", .handler = findFile },
    .{ .name = "beginning-of-line", .handler = beginningOfLine },
    .{ .name = "end-of-line", .handler = endOfLine },
    .{ .name = "beginning-of-buffer", .handler = beginningOfBuffer },
    .{ .name = "end-of-buffer", .handler = endOfBuffer },
    .{ .name = "forward-word", .handler = moveByMotion("motion.word-fwd") },
    .{ .name = "backward-word", .handler = moveByMotion("motion.word-back") },
    .{ .name = "kill-line", .handler = killLine },
    .{ .name = "kill-region", .handler = killRegion },
    .{ .name = "copy-region", .handler = copyRegion },
    .{ .name = "yank", .handler = yank },
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
    // The one resting mode: `emacs` inherits the `default` editing floor, so
    // printable keys self-insert and arrows/Backspace/C-s work; the binds below
    // layer the emacs chords over it. No textInput override — text falls through
    // to default's insert-text (modeless).
    weft.setFallback("emacs", "default");
    weft.restingMode("emacs"); // the base a file buffer rests in

    for (cmds) |c| _ = weft.register(c.name);

    // Intra-buffer keys. Movement, kill/yank — the everyday editing chords. The
    // C-x/C-c prefix TREE (find-file, save, buffers, windows, magit, dired) is
    // config data (emacs.js) since it reaches other plugins; these are the
    // editor's own. C-space (set-mark), C-g (keyboard-quit → clear-selection),
    // C-s (save), Backspace, and the arrows come from the `default` fallback.
    const binds = [_][2][]const u8{
        .{ "C-f", "cursor-right" },        .{ "C-b", "cursor-left" },
        .{ "C-n", "cursor-down" },         .{ "C-p", "cursor-up" },
        .{ "C-a", "beginning-of-line" },   .{ "C-e", "end-of-line" },
        .{ "M-f", "forward-word" },        .{ "M-b", "backward-word" },
        .{ "M-<", "beginning-of-buffer" }, .{ "M->", "end-of-buffer" },
        .{ "C-v", "scroll-page-down" },    .{ "M-v", "scroll-page-up" },
        .{ "C-d", "delete-forward" },      .{ "C-k", "kill-line" },
        .{ "C-w", "kill-region" },         .{ "M-w", "copy-region" },
        .{ "C-y", "yank" },                .{ "C-/", "undo" },
        .{ "C-_", "undo" },                .{ "C-space", "set-mark" },
    };
    for (binds) |b| weft.bindKey("emacs", b[0], b[1]);

    // A bar caret (you're always between cells in a modeless editor).
    weft.runStr2("set-cursor", "emacs", "bar");
    weft.runStr2("cursor-blink", "emacs", "on");

    weft.setMode("emacs");
}
