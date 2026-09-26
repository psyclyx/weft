//! helix — a SECOND modal editor, as a plugin, to stress-test the plugin ABI's
//! decoupling. It uses its OWN mode namespace (`helix-normal`/`helix-insert`/…),
//! its own cursor config, and composes the SAME shared `motions`/`operators`/
//! core commands vim does. If core (or any plugin) assumed vim's `normal` mode,
//! helix would break — it doesn't, which is the point: modal editing is not
//! privileged, it's a plugin over data.
//!
//! Load it INSTEAD of vim for a whole editor (config/helix.js), or alongside
//! vim and switch a buffer between `normal` and `helix-normal` — the keymap
//! mode is per-buffer, so they coexist.
//!
//! SELECTION-FIRST, on one selection. Helix acts on selections: `x` selects
//! the line, then `d`/`c`/`y` act on it. Core holds one cursor and one mark
//! today, so the selection here is that pair — `span()` is "the selection,
//! else the character under the cursor", which is exactly helix's rule that a
//! selection covers at least one character. Every verb reads `span()` and
//! nothing else, so running them once per selection is the whole change when
//! core grows several (doc/configs.md §2 phase 2). Motions collapse the
//! selection and move; they do not select yet (phase 2 too).
//!
//! Where a standard intention names what a key does, the key binds it FIRST
//! with helix's text behaviour as the fallback arm — so in a files listing or
//! a git buffer `j`/`k`/`y`/`p`/`d`/`Return`/`-` do the structural thing, and
//! helix carries no files- or git-specific code at all.

const std = @import("std");
const weft = @import("weft");
const ex_mod = @import("weft_ex");
const semantic_action = weft.semantic.action.standard;

/// The `:` command line, in helix's own mode namespace (`helix-normal` resting,
/// `helix-ex` the command line). Same shared engine vim uses: helix gets the
/// classic builtins (write/quit/open/vsplit/hsplit + w/q/wq/s abbrevs) and the
/// SAME fall-through to the weft registry (`:name arg…`).
const ex = ex_mod.Ex("helix-normal", "helix-ex");

const file_pick = 0;

/// Motion keys shared with the `motions` plugin. Each binds the standard
/// navigation intention where one names it (a listing answers `j` with its
/// next row), with helix's own move as the fallback. `op` motions also get a
/// delete form (`d<key>`) in `helix-op`.
const Motion = struct {
    key: []const u8,
    motion: []const u8,
    intention: ?[]const u8 = null,
    op: bool = false,
};
const mtable = [_]Motion{
    .{ .key = "h", .motion = "motion.left", .intention = "std.navigation.left" },
    .{ .key = "l", .motion = "motion.right", .intention = "std.navigation.right" },
    .{ .key = "j", .motion = "motion.down", .intention = "std.navigation.down" },
    .{ .key = "k", .motion = "motion.up", .intention = "std.navigation.up" },
    .{ .key = "Left", .motion = "motion.left", .intention = "std.navigation.left" },
    .{ .key = "Right", .motion = "motion.right", .intention = "std.navigation.right" },
    .{ .key = "Down", .motion = "motion.down", .intention = "std.navigation.down" },
    .{ .key = "Up", .motion = "motion.up", .intention = "std.navigation.up" },
    .{ .key = "w", .motion = "motion.word-fwd", .intention = "std.navigation.word-next", .op = true },
    .{ .key = "b", .motion = "motion.word-back", .intention = "std.navigation.word-previous", .op = true },
    .{ .key = "e", .motion = "motion.word-end", .intention = "std.navigation.word-end", .op = true },
    .{ .key = "W", .motion = "motion.WORD-fwd", .intention = "std.navigation.big-word-next", .op = true },
    .{ .key = "B", .motion = "motion.WORD-back", .intention = "std.navigation.big-word-previous", .op = true },
    .{ .key = "E", .motion = "motion.WORD-end", .intention = "std.navigation.big-word-end", .op = true },
    .{ .key = "0", .motion = "motion.line-start", .intention = "std.navigation.line-start", .op = true },
    .{ .key = "dollar", .motion = "motion.line-end", .intention = "std.navigation.line-end", .op = true },
    // Helix's goto-mode spellings of the same three line motions.
    .{ .key = "Home", .motion = "motion.line-start", .intention = "std.navigation.line-start" },
    .{ .key = "End", .motion = "motion.line-end", .intention = "std.navigation.line-end" },
    .{ .key = "g h", .motion = "motion.line-start", .intention = "std.navigation.line-start" },
    .{ .key = "g l", .motion = "motion.line-end", .intention = "std.navigation.line-end" },
    .{ .key = "g s", .motion = "motion.first-non-blank", .intention = "std.navigation.first-non-blank" },
};

/// One generated command per distinct motion (several keys share one).
const motions = blk: {
    var names: [mtable.len][]const u8 = undefined;
    var n: usize = 0;
    for (mtable) |m| {
        for (names[0..n]) |seen| {
            if (std.mem.eql(u8, seen, m.motion)) break;
        } else {
            names[n] = m.motion;
            n += 1;
        }
    }
    const out = names[0..n].*;
    break :blk out;
};

/// Run a motion and jump to its far end (direction-carrying). A motion in
/// normal mode REPLACES the selection in helix; with one selection that is
/// collapse-then-move.
fn moveByMotion(comptime motion: []const u8) fn () void {
    return struct {
        fn h() void {
            weft.run("clear-selection");
            const cur = weft.cursor();
            const hnd = weft.runRange(motion) orelse return;
            const r = weft.rangeEnds(hnd) orelse return;
            weft.jump(if (r.end == cur) r.start else r.end);
        }
    }.h;
}

/// Delete over a motion's range (`d` then a motion, with nothing selected),
/// via the operators plugin's gated edit, then land at the range start.
fn deleteByMotion(comptime motion: []const u8) fn () void {
    return struct {
        fn h() void {
            const hnd = weft.runRange(motion) orelse return;
            const r = weft.rangeEnds(hnd) orelse return;
            weft.yankRange(r.start, r.end, false);
            weft.runRangeArg("op.delete", hnd);
            weft.jump(r.start);
            weft.exitToResting();
        }
    }.h;
}

const base_cmds = [_]weft.CommandEntry{
    .{ .name = "helix-mode", .call = enterHelix },
    .{ .name = "hx-insert", .call = hxInsert },
    .{ .name = "hx-append", .call = hxAppend },
    .{ .name = "hx-insert-line-start", .call = hxInsertLineStart },
    .{ .name = "hx-append-line-end", .call = hxAppendLineEnd },
    .{ .name = "hx-open-below", .call = hxOpenBelow },
    .{ .name = "hx-open-above", .call = hxOpenAbove },
    .{ .name = "hx-normal", .call = hxNormal },
    .{ .name = "hx-delete-op", .call = enterDeleteOp },
    .{ .name = "hx-select-line", .call = hxSelectLine },
    .{ .name = "hx-collapse", .call = hxCollapse },
    .{ .name = "hx-delete", .call = hxDelete },
    .{ .name = "hx-change", .call = hxChange },
    .{ .name = "hx-yank", .call = hxYank },
    .{ .name = "hx-paste", .call = hxPaste },
    .{ .name = "hx-paste-before", .call = hxPasteBefore },
    .{ .name = "hx-delete-line", .call = hxDeleteLine },
    .{ .name = "hx-goto-start", .call = hxGotoStart },
    .{ .name = "hx-goto-end", .call = hxGotoEnd },
    // The same file picker vim and emacs register under this name, so a
    // config's `find-file` bind means the same thing under every grammar.
    .{ .name = "find-file", .call = findFile },
    // The `:` ex command line — the key that OPENS it (shared engine; helix
    // mode namespace). Its five editing commands come from the shared
    // prompt, spliced in as `ex_cmds` below.
    .{ .name = "helix-ex", .call = ex.enter },
};

/// The `:` line's editing commands, from the shared `prompt` library, mapped
/// into helix's `weft.CommandEntry` so `on_command`'s id indexing stays one flat table.
const ex_cmds: [ex.commands.len]weft.CommandEntry = blk: {
    var arr: [ex.commands.len]weft.CommandEntry = undefined;
    for (ex.commands, 0..) |c, i| arr[i] = .{ .name = c.name, .call = c.handler };
    break :blk arr;
};

/// Generated: `hx/n/<motion>` (move) for every motion, `hx/d/<motion>` (delete)
/// for the `op` ones. Names exist only for key binding.
const gen_cmds = blk: {
    var n: usize = motions.len;
    for (motions) |name| {
        for (mtable) |m| {
            if (m.op and std.mem.eql(u8, m.motion, name)) {
                n += 1;
                break;
            }
        }
    }
    var arr: [n]weft.CommandEntry = undefined;
    var i: usize = 0;
    for (motions) |name| {
        arr[i] = .{ .name = "hx/n/" ++ name, .call = moveByMotion(name) };
        i += 1;
        for (mtable) |m| {
            if (m.op and std.mem.eql(u8, m.motion, name)) {
                arr[i] = .{ .name = "hx/d/" ++ name, .call = deleteByMotion(name) };
                i += 1;
                break;
            }
        }
    }
    break :blk arr;
};

const cmds = base_cmds ++ ex_cmds ++ gen_cmds;

fn initExtra() void {

    // Only insert commits typed text; helix-normal is modal and declares
    // nothing, so nothing can leak into it. `helix-insert` falls back to the
    // core `default` floor for its BINDINGS (Return -> insert-newline, the
    // std.editing.insert-line-break arm; Backspace, Tab-as-indent) the same
    // way vim's `insert` mode does.
    weft.setFallback("helix-insert", "default");
    weft.textInput("helix-insert", "insert-text");

    // Movement: every motion key leads with its navigation intention.
    inline for (mtable) |m| {
        if (m.intention) |intent| {
            weft.bindKeys("helix-normal", m.key, &.{ intent, "hx/n/" ++ m.motion });
        } else weft.bindKey("helix-normal", m.key, "hx/n/" ++ m.motion);
    }

    // Shared intentions (doc/contextual-workspace-architecture.md §10.2), same
    // shapes vim uses. `u`/`U` undo and redo, with the core commands as their
    // text arm; `C-r` stays a redo too. `Tab`, `Return` and `-` have no helix
    // meaning over text, so the intention IS the whole binding: an unoffered
    // intention does nothing, which is what helix does with those keys. (The
    // line-break arm of Return lives in `helix-insert`, via `default`.) `q`
    // keeps NO binding: real Helix records macros there, and binding vim's
    // back semantics onto it would misrepresent helix's own feel.
    const intended = [_][3][]const u8{
        .{ "u", "std.history.undo", "undo" },
        .{ "U", "std.history.redo", "redo" },
        .{ "C-r", "std.history.redo", "redo" },
    };
    for (intended) |b| weft.bindKeys("helix-normal", b[0], &.{ b[1], b[2] });
    weft.bindKeys("helix-normal", "Tab", &.{"std.hierarchy.toggle-expanded"});
    weft.bindKeys("helix-normal", "Return", &.{"std.target.activate"});
    weft.bindKeys("helix-normal", "KP_Enter", &.{"std.target.activate"});
    weft.bindKeys("helix-normal", "minus", &.{"std.hierarchy.step-out"});

    const nb = [_][2][]const u8{
        .{ "i", "hx-insert" },            .{ "a", "hx-append" },
        .{ "I", "hx-insert-line-start" }, .{ "A", "hx-append-line-end" },
        .{ "o", "hx-open-below" },        .{ "O", "hx-open-above" },
        .{ "x", "hx-select-line" },       .{ "semicolon", "hx-collapse" },
        .{ "c", "hx-change" },            .{ "P", "hx-paste-before" },
        .{ "colon", "helix-ex" },
    };
    for (nb) |b| weft.bindKey("helix-normal", b[0], b[1]);

    // Transfer: `y` captures, `p` places, and `d` takes the selection WITH it.
    // Each leads with the standard word and keeps its text behaviour as the
    // fallback arm.
    weft.bindKeys("helix-normal", "y", &.{ "std.transfer.yank", "hx-yank" });
    weft.bindKeys("helix-normal", "p", &.{ "std.transfer.paste", "hx-paste" });
    weft.bindKeys("helix-normal", "d", &.{ "std.transfer.delete-to-register", "hx-delete" });

    // `d` with nothing selected waits for what to delete (a tiny
    // operator-pending mode): a motion, or `d` again for the line. The
    // one-selection stand-in for select-then-act, until motions select.
    weft.menuMode("helix-op");
    weft.setFallback("helix-op", "helix-normal");
    weft.bindKey("helix-op", "Escape", "hx-normal");
    inline for (mtable) |m| if (m.op) weft.bindKey("helix-op", m.key, "hx/d/" ++ m.motion);
    weft.bindKey("helix-op", "d", "hx-delete-line"); // dd

    // Insert mode: Escape back to normal.
    weft.bindKey("helix-insert", "Escape", "hx-normal");

    // Leader + goto as key SEQUENCES in helix-normal (no menu modes): `space` /
    // `g` are just the first key of chords which-key completes. A config
    // (helix.js) layers a fuller `space …` tree at prio_config.
    weft.bindKey("helix-normal", "space space", "pick-commands"); // SPC SPC — M-x
    weft.bindKey("helix-normal", "space f f", "find-file");
    weft.bindKey("helix-normal", "space b b", "buf-pick"); // if buffers loaded
    weft.bindKey("helix-normal", "space g g", "git-status"); // if git loaded
    weft.bindKey("helix-normal", "g g", "hx-goto-start");
    weft.bindKey("helix-normal", "g e", "hx-goto-end");

    // The `:` command line (helix mode namespace). Same shape as vim's `ex`:
    // printable → hx-ex-type, Backspace/Enter/Escape edit/run/cancel.
    ex.install();

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
    // The key layers over `helix-normal`, declared rather than named in core:
    // a document's code chords, and a listing's structured-view group. The
    // head stays in `helix-normal` either way.
    weft.setFallback("helix-source", "helix-normal");
    weft.setFallback("helix-structural", "helix-normal");
    weft.bindingVariant(.source, "helix-normal", "helix-source");
    weft.bindingVariant(.structural, "helix-normal", "helix-structural");
    for ([_][]const u8{ "helix-normal", "helix-insert" }) |m|
        weft.bindKeys(m, "C-backslash", &.{"std.input.break-out"});
    weft.setMode("helix-normal");
}

// ── The selection ───────────────────────────────────────────────────────

/// Helix's unit of action: the selection, or the one character under the
/// cursor when nothing is selected (a helix selection is never empty). The
/// ONE place the verbs read what they act on — one selection now, each of
/// several once core holds them.
fn span() weft.Range {
    if (weft.selection()) |s| if (s.end > s.start) return s;
    const cur = weft.cursor();
    return .{ .start = cur, .end = @min(cur + 1, weft.byteLen()) };
}

/// Whether `r` is whole lines: from a line start through a line's newline
/// (or the end of the buffer). A yank of one pastes linewise.
fn isLinewise(r: weft.Range) bool {
    if (r.end <= r.start) return false;
    if (weft.lineAt(r.start).start != r.start) return false;
    if (r.end == weft.byteLen()) return true;
    return weft.lineAt(r.end - 1).end + 1 == r.end;
}

fn hasSelection() bool {
    const s = weft.selection() orelse return false;
    return s.end > s.start;
}

/// `x`: select the cursor's line, newline included. On a selection that is
/// already whole lines, extend it by the next line — so `x x d` takes two.
fn hxSelectLine() void {
    const len = weft.byteLen();
    if (weft.selection()) |s| {
        if (isLinewise(s) and s.end < len) {
            const next = weft.lineAt(s.end);
            weft.setSelection(.{ .start = s.start, .end = @min(next.end + 1, len) });
            return;
        }
    }
    const l = weft.lineAt(weft.cursor());
    weft.setSelection(.{ .start = l.start, .end = @min(l.end + 1, len) });
}

/// `;`: collapse the selection onto the cursor.
fn hxCollapse() void {
    weft.run("clear-selection");
}

/// `d`'s text arm: take the selection into the register and delete it. With
/// nothing selected, wait for a motion (`helix-op`).
fn hxDelete() void {
    if (!hasSelection()) return enterDeleteOp();
    const s = span();
    weft.yankRange(s.start, s.end, isLinewise(s));
    weft.run("clear-selection");
    weft.edit(s, "");
    weft.jump(s.start);
}

/// `c`: delete the selection (or the character under the cursor) into the
/// register, then insert where it was.
fn hxChange() void {
    const s = span();
    if (onText() and s.end > s.start) {
        weft.yankRange(s.start, s.end, false);
        weft.run("clear-selection");
        weft.edit(s, "");
        weft.jump(s.start);
    }
    enterInsert();
}

/// `y`'s text arm: capture the selection (or the character under the
/// cursor). The selection stays, as in helix.
fn hxYank() void {
    const s = span();
    if (s.end <= s.start) return;
    weft.yankRange(s.start, s.end, isLinewise(s));
    weft.flash(s.start, s.end);
}

var paste_buf: [(1 << 16) + 1]u8 = undefined;

/// `p`'s text arm: place the register AFTER the selection. A linewise
/// register lands on the line after it.
fn hxPaste() void {
    const s = span();
    const r = weft.registerText();
    if (weft.registerLinewiseIn(0)) {
        const l = weft.lineAt(if (s.end > s.start) s.end - 1 else s.start);
        if (l.end >= weft.byteLen()) {
            // The last line has no newline to land after: synthesize one.
            if (r.len + 1 > paste_buf.len) return;
            paste_buf[0] = '\n';
            @memcpy(paste_buf[1 .. 1 + r.len], r);
            weft.edit(.{ .start = l.end, .end = l.end }, paste_buf[0 .. 1 + r.len]);
            weft.pasteAt(l.end + 1);
            return;
        }
        return placeAt(l.end + 1, r);
    }
    placeAt(s.end, r);
}

/// `P`: place the register BEFORE the selection — the focused view's own
/// paste-before where one answers, since no standard word names placement.
fn hxPasteBefore() void {
    switch (weft.semanticAction(semantic_action.paste_before)) {
        .handled, .transfer_stored, .interaction_opened, .target_opened, .focus_changed, .relation_opened, .working_target_changed => return,
        .unavailable, .failed, _ => {},
    }
    const s = span();
    const r = weft.registerText();
    placeAt(if (weft.registerLinewiseIn(0)) weft.lineAt(s.start).start else s.start, r);
}

/// Insert register text at `off` and re-stamp any ferried identity over it,
/// so a `d` then `p` of a projection row is a move.
fn placeAt(off: usize, r: []const u8) void {
    if (r.len == 0) return;
    weft.run("clear-selection");
    weft.edit(.{ .start = off, .end = off }, r);
    weft.pasteAt(off);
    weft.flash(off, off + r.len);
}

/// `dd` (from `helix-op`): delete the line and its newline, linewise.
fn hxDeleteLine() void {
    const len = weft.byteLen();
    const l = weft.lineAt(weft.cursor());
    const end = @min(l.end + 1, len);
    weft.yankRange(l.start, end, true);
    if (weft.anchorRange(.{ .start = l.start, .end = end })) |h| weft.runRangeArg("op.delete", h);
    weft.jump(l.start);
    weft.exitToResting();
}

/// `gg` / `ge`: the first line, the last line.
fn hxGotoStart() void {
    weft.run("clear-selection");
    weft.jump(0);
}
fn hxGotoEnd() void {
    weft.run("clear-selection");
    weft.jump(weft.lineAt(weft.byteLen()).start);
}

// ── Modes ───────────────────────────────────────────────────────────────

fn enterHelix() void {
    weft.setMode("helix-normal");
}
/// Escape RETURNS to the entry's declared resting state (§10.4) — it never
/// picks one, so a projection's own resting mode survives an edit + Escape.
fn hxNormal() void {
    weft.run("undo-barrier");
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
/// Whether the entry's own text is what the keys edit. A focused field or a
/// listing owns its caret; helix moves only a caret it holds.
fn onText() bool {
    return weft.posture() == .text;
}
/// Collapse the selection to one place, then type there: `i` before it, `a`
/// after it, `I`/`A` at the line's ends.
fn insertAt(offset: usize) void {
    if (onText()) {
        weft.run("clear-selection");
        weft.jump(offset);
    }
    enterInsert();
}
fn hxInsert() void {
    insertAt(span().start);
}
fn hxAppend() void {
    insertAt(span().end);
}
fn hxInsertLineStart() void {
    insertAt(weft.lineAt(weft.cursor()).start);
}
fn hxAppendLineEnd() void {
    insertAt(weft.lineAt(weft.cursor()).end);
}
/// `o`/`O`: a structured view answers the insertion intention (a new row);
/// text opens a line.
fn hxOpenBelow() void {
    if (weft.invokeIntention("std.editing.insert-after") == .invoked) return enterInsert();
    if (!onText()) return enterInsert();
    weft.run("clear-selection");
    weft.jump(weft.lineAt(weft.cursor()).end);
    weft.run("insert-newline");
    enterInsert();
}
fn hxOpenAbove() void {
    if (weft.invokeIntention("std.editing.insert-before") == .invoked) return enterInsert();
    if (!onText()) return enterInsert();
    weft.run("clear-selection");
    weft.jump(weft.lineAt(weft.cursor()).start);
    weft.run("insert-newline");
    weft.run("cursor-up");
    enterInsert();
}
fn enterDeleteOp() void {
    weft.setMode("helix-op");
}

// ── Files ───────────────────────────────────────────────────────────────

fn findFile() void {
    weft.pickCategory("file");
    weft.openFilePick("open", ".", file_pick);
}
fn onPickAccept(pick_id: u32) void {
    if (pick_id != file_pick) return;
    var outcome = (weft.pickOutcome(weft.allocator) catch return) orelse return;
    defer outcome.deinit(weft.allocator);
    const chosen = switch (outcome) {
        .candidate => |candidate| candidate.text,
        .input => |input| input,
        .cancelled => return,
    };
    if (chosen.len > 0) weft.runStr("open", chosen);
}

comptime {
    weft.plugin(&cmds, .{ .init = initExtra, .pick = onPickAccept }).exportAll();
}
