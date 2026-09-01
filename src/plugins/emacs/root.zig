//! emacs — NON-MODAL editing as a `.wasm` plugin, perms `{}` grant_max edit. The
//! counterpart to vim.zig: where vim proves the modal path (postures as modes +
//! chord trees as sequences), emacs proves the MODELESS path. There is ONE
//! resting mode, `emacs`, that falls back to the core `default` floor for its
//! BINDINGS (arrows/Backspace) and declares that it commits typed text, so
//! printable keys self-insert — and every command is a CONTROL/META chord
//! layered on top. C-x / C-c are prefix key SEQUENCES (the same engine vim's
//! `SPC f f` uses), not modes: `C-x` holds pending, which-key shows its
//! completions, `C-x C-f` completes. The editor owns only intra-buffer
//! motion/kill/yank here; the C-x/C-c tree that reaches other plugins
//! (find-file, git, files) is config data (emacs.js).
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
    weft.pickCategory("file");
    weft.openFilePick("open", ".", file_pick);
}
fn openChosen(choice: []const u8) void {
    if (choice.len == 0) return;
    weft.runStr("open", choice);
}

// ── Command table (registration order == on_command id) ──
const cmds = [_]weft.CommandEntry{
    .{ .name = "find-file", .call = findFile },
    .{ .name = "beginning-of-line", .call = beginningOfLine },
    .{ .name = "end-of-line", .call = endOfLine },
    .{ .name = "beginning-of-buffer", .call = beginningOfBuffer },
    .{ .name = "end-of-buffer", .call = endOfBuffer },
    .{ .name = "forward-word", .call = moveByMotion("motion.word-fwd") },
    .{ .name = "backward-word", .call = moveByMotion("motion.word-back") },
    .{ .name = "kill-line", .call = killLine },
    .{ .name = "kill-region", .call = killRegion },
    .{ .name = "copy-region", .call = copyRegion },
    .{ .name = "yank", .call = yank },
};

export fn on_pick_accept(pick_id: u32) void {
    if (pick_id != file_pick) return;
    var outcome = (weft.pickOutcome(weft.allocator) catch return) orelse return;
    defer outcome.deinit(weft.allocator);
    const path = switch (outcome) {
        .candidate => |candidate| candidate.text,
        .input => |input| input,
        .cancelled => return,
    };
    openChosen(path);
}

fn initExtra() void {
    // The one resting mode: `emacs` inherits the `default` editing floor's
    // BINDINGS (arrows/Backspace/C-s) and layers the emacs chords over it, and
    // declares that it commits typed text — a declaration, never inherited.
    weft.setFallback("emacs", "default");
    weft.textInput("emacs", "insert-text");

    // §10.4: a MODELESS grammar's resting mode commits text, so "the entry
    // takes no text" cannot be a state emacs is already in — it needs a
    // second one. `emacs-structural` inherits every emacs chord by fallback
    // and declares NO commit command, so in a structural entry the letters
    // are free for what holds the focus and can never leak into a projection.
    // Nothing is inherited about committing (see `weft.textInput`), which is
    // why this needs no opt-out.
    weft.setFallback("emacs-structural", "emacs");
    weft.restingPosture(.text, "emacs");
    weft.restingPosture(.structural, "emacs-structural");
    // The break-out capture can never take away — retained in both resting
    // states (§10.4).
    for ([_][]const u8{ "emacs", "emacs-structural" }) |m|
        weft.bindKeys(m, "C-c C-backslash", &.{"std.input.break-out"});

    // Intra-buffer keys. Movement, kill/yank — the everyday editing chords. The
    // C-x/C-c prefix TREE (find-file, save, buffers, windows, git, files) is
    // config data (emacs.js) since it reaches other plugins; these are the
    // editor's own. C-space (set-mark), C-g (keyboard-quit → clear-selection),
    // C-s (save), Backspace, and the arrows come from the `default` fallback —
    // so std.persistence.save (emacs's own convention is C-x C-s) and Return's
    // std.editing.insert-line-break arm both already resolve there; this
    // plugin adds no binding for either. C-/ and C-_ are emacs's own undo
    // chords (bare `u` self-inserts in a modeless editor, unlike vim/helix, so
    // it stays untouched); there is no established emacs redo chord here, so
    // std.history.redo is left unbound rather than invented. Tab and `q` are
    // likewise skipped: Tab already means indent for every keystroke in a
    // modeless buffer (shadowing it with std.hierarchy.toggle-expanded would
    // break ordinary typing), and bare `q` is a self-insert letter here too.
    // std.hierarchy.step-out is skipped for the same reason: emacs spells it
    // `^`, a printable this editor must keep as text.
    const binds = [_][2][]const u8{
        .{ "C-f", "cursor-right" },        .{ "C-b", "cursor-left" },
        .{ "C-n", "cursor-down" },         .{ "C-p", "cursor-up" },
        .{ "C-a", "beginning-of-line" },   .{ "C-e", "end-of-line" },
        .{ "M-f", "forward-word" },        .{ "M-b", "backward-word" },
        .{ "M-<", "beginning-of-buffer" }, .{ "M->", "end-of-buffer" },
        .{ "C-v", "scroll-page-down" },    .{ "M-v", "scroll-page-up" },
        .{ "C-d", "delete-forward" },      .{ "C-k", "kill-line" },
        .{ "C-/", "std.history.undo" },    .{ "C-_", "std.history.undo" },
        .{ "C-space", "set-mark" },
    };
    for (binds) |b| weft.bindKey("emacs", b[0], b[1]);

    // Kill/copy/yank ARE the transfer words, so each leads with its standard
    // name and keeps the region command as its fallback arm: the same three
    // chords capture a structured row where one is focused and a region of
    // text everywhere else.
    weft.bindKeys("emacs", "M-w", &.{ "std.transfer.yank", "copy-region" });
    weft.bindKeys("emacs", "C-w", &.{ "std.transfer.delete-to-register", "kill-region" });
    weft.bindKeys("emacs", "C-y", &.{ "std.transfer.paste", "yank" });

    // A bar caret (you're always between cells in a modeless editor).
    weft.runStr2("set-cursor", "emacs", "bar");
    weft.runStr2("cursor-blink", "emacs", "on");

    weft.setMode("emacs");
}

comptime {
    weft.plugin(&cmds, .{ .init = initExtra }).exportAll();
}
