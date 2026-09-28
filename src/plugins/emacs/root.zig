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
//! (files.find, git, files) is the loading config's to bind — none of the
//! configs shipped in `config/` loads this plugin today.
//! Delete this plugin and weft is still modeless — `default` is the floor.

const std = @import("std");
const weft = @import("weft");

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
    weft.run("selection.clear"); // emacs deactivates the mark after M-w
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

// ── Command table (registration order == on_command id) ──
const cmds = [_]weft.CommandEntry{
    .{ .name = "emacs.line-start", .arity = weft.Arity.each_extent, .call = beginningOfLine, .summary = "Move to the beginning of the line.", .label = "Beginning of Line" },
    .{ .name = "emacs.line-end", .arity = weft.Arity.each_extent, .call = endOfLine, .summary = "Move to the end of the line.", .label = "End of Line" },
    .{ .name = "emacs.doc-start", .arity = weft.Arity.each_extent, .call = beginningOfBuffer, .summary = "Move to the beginning of the buffer.", .label = "Beginning of Buffer" },
    .{ .name = "emacs.doc-end", .arity = weft.Arity.each_extent, .call = endOfBuffer, .summary = "Move to the end of the buffer.", .label = "End of Buffer" },
    .{ .name = "emacs.word-next", .arity = weft.Arity.each_extent, .call = moveByMotion("motions.word-next"), .summary = "Move forward a word.", .label = "Forward Word" },
    .{ .name = "emacs.word-prev", .arity = weft.Arity.each_extent, .call = moveByMotion("motions.word-prev"), .summary = "Move backward a word.", .label = "Backward Word" },
    .{ .name = "emacs.kill-line", .arity = weft.Arity.each_extent, .call = killLine, .summary = "Kill from the cursor to the end of the line.", .label = "Kill Line" },
    .{ .name = "emacs.kill-region", .arity = weft.Arity.each_extent, .call = killRegion, .summary = "Kill the region between the mark and the cursor.", .label = "Kill Region" },
    .{ .name = "emacs.copy-region", .arity = weft.Arity.each_extent, .call = copyRegion, .summary = "Copy the region between the mark and the cursor without deleting it.", .label = "Copy Region" },
    .{ .name = "emacs.yank", .arity = weft.Arity.each_extent, .call = yank, .summary = "Paste the most recently killed text at the cursor.", .label = "Yank" },
};

fn initExtra() void {
    // The one resting mode: `emacs` inherits the `default` editing floor's
    // BINDINGS (arrows/Backspace/C-s) and layers the emacs chords over it, and
    // declares that it commits typed text — a declaration, never inherited.
    weft.setFallback("emacs", "default");
    weft.textInput("emacs", "edit.insert-text");
    // One undo step is a RUN of one command, as emacs amalgamates
    // self-insertion: typing is one step until something else runs.
    weft.runStr2("mode.set-undo-step", "emacs", "run");

    // §10.4: a MODELESS grammar's resting mode commits text, so "the entry
    // takes no text" cannot be a state emacs is already in — it needs a
    // second one. `emacs-structural` inherits every emacs chord by fallback
    // and declares NO commit command, so in a structural entry the letters
    // are free for what holds the focus and can never leak into a projection.
    // Nothing is inherited about committing (see `weft.textInput`), which is
    // why this needs no opt-out.
    weft.setFallback("emacs-structural", "emacs");
    weft.setFallback("emacs-source", "emacs");
    // A document's code chords layer over `emacs` by declaration. The
    // structural layer needs none: emacs RESTS in `emacs-structural` there.
    weft.bindingVariant(.source, "emacs", "emacs-source");
    weft.restingPosture(.text, "emacs");
    weft.restingPosture(.structural, "emacs-structural");
    // Editable listings: focusing a row edits its name (doc/chrome.md §5.2).
    weft.runStr2("mode.set-structural-focus", "emacs", "text");
    // The break-out capture can never take away — retained in both resting
    // states (§10.4).
    for ([_][]const u8{ "emacs", "emacs-structural" }) |m|
        weft.bindKeys(m, "C-c C-backslash", &.{"std.input.break-out"});
    // A program's landmarks (a shell's prompts in a terminal read as text)
    // are comint's: C-c C-p / C-c C-n between prompts, C-c C-o the output.
    weft.bindKeys("emacs", "C-c C-p", &.{"std.navigation.landmark-prev"});
    weft.bindKeys("emacs", "C-c C-n", &.{"std.navigation.landmark-next"});
    weft.bindKeys("emacs", "C-c C-o", &.{"std.selection.landmark-body"});

    // Intra-buffer keys. Movement, kill/yank — the everyday editing chords. The
    // C-x/C-c prefix TREE (files.find, save, buffers, windows, git, files) is
    // the loading config's data since it reaches other plugins; these are the
    // editor's own. C-space (set-mark), C-g (keyboard-quit → selection.clear),
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
        .{ "C-f", "cursor.right" },        .{ "C-b", "cursor.left" },
        .{ "C-n", "cursor.down" },         .{ "C-p", "cursor.up" },
        .{ "C-a", "emacs.line-start" },    .{ "C-e", "emacs.line-end" },
        .{ "M-f", "emacs.word-next" },     .{ "M-b", "emacs.word-prev" },
        .{ "M-<", "emacs.doc-start" },     .{ "M->", "emacs.doc-end" },
        .{ "C-v", "scroll.page-down" },    .{ "M-v", "scroll.page-up" },
        .{ "C-d", "edit.delete-after" },   .{ "C-k", "emacs.kill-line" },
        .{ "C-/", "std.history.undo" },    .{ "C-_", "std.history.undo" },
        .{ "C-space", "selection.start" },
    };
    for (binds) |b| weft.bindKey("emacs", b[0], b[1]);

    // Kill/copy/yank ARE the transfer words, so each leads with its standard
    // name and keeps the region command as its fallback arm: the same three
    // chords capture a structured row where one is focused and a region of
    // text everywhere else.
    weft.bindKeys("emacs", "M-w", &.{ "std.transfer.yank", "emacs.copy-region" });
    weft.bindKeys("emacs", "C-w", &.{ "std.transfer.delete-to-register", "emacs.kill-region" });
    weft.bindKeys("emacs", "C-y", &.{ "std.transfer.paste", "emacs.yank" });
    // …and over text the transfer words MEAN those region commands: core
    // offers std.transfer.* where a grammar provides the matching action, so
    // the context menu over text has Cut, Copy and Paste — kill-region,
    // kill-ring-save and yank, through the kill ring.
    weft.provide("selection.cut", .{ .posture = "text" }, "emacs.kill-region", 0);
    weft.provide("selection.copy", .{ .posture = "text" }, "emacs.copy-region", 0);
    weft.provide("selection.paste-after", .{ .posture = "text" }, "emacs.yank", 0);

    // A bar caret (you're always between cells in a modeless editor).
    weft.runStr2("cursor.set-style", "emacs", "bar");
    weft.runStr2("cursor.set-blink", "emacs", "on");

    weft.setMode("emacs");
}

comptime {
    // Every emacs verb is a one-point program (the point, the region); each
    // runs once per selection. `files.find` alone never reads one.
    weft.plugin(&cmds, .{ .init = initExtra }).exportAll();
}
