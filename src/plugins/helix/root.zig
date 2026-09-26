//! helix — a SECOND modal editor, as a plugin, to stress-test the plugin ABI's
//! decoupling. It uses its OWN mode namespace (`helix-normal`/`helix-insert`/…),
//! its own cursor config, and composes the SAME shared `textobjects`/`ts`/
//! `surround`/`lsp` commands and core scroll/buffer commands vim does. If core
//! (or any plugin) assumed vim's `normal` mode, helix would break — it doesn't,
//! which is the point: modal editing is not privileged, it's a plugin over data.
//!
//! Load it INSTEAD of vim for a whole editor (config/helix.js), or alongside
//! vim and switch a buffer between `normal` and `helix-normal` — the keymap
//! mode is per-buffer, so they coexist.
//!
//! SELECTION-FIRST, on every selection (doc/configs.md §2). A motion selects
//! (`w` selects the word ahead) in `helix-normal` and extends in
//! `helix-select` (`v`); `x`, `%`, `C`, `A-o` and friends reshape the set; the
//! verbs `d c y p P R r ~ J > <` act on every selection as one undo unit.
//! `selection.zig` holds the set and what reshapes it, `edit.zig` what edits
//! it, `text.zig` the pure motions. There is no operator-pending mode: a verb
//! acts on what is selected, which is the whole of helix's grammar.
//!
//! The minor modes are key SEQUENCES in `helix-normal` — `g` goto, `m` match,
//! `z` view, `[`/`]` pairs, `space` — completed by which-key; `Z` is the one
//! sticky view mode. Keys whose next key is arbitrary text (`r` `f` `t` `"`
//! `ms` `md` `mr`) are single-key capture modes. Counts (`3w`, `5gg`) and
//! registers (`"a`) are the grammar's own prefixes (`state.zig`).
//!
//! Where a standard intention names what a key does, the key binds it FIRST
//! with helix's text behaviour as the fallback arm — so in a files listing or
//! a git buffer `j`/`k`/`y`/`p`/`d`/`Return`/`-` do the structural thing, and
//! helix carries no files- or git-specific code at all.
//!
//! Regex selection and search (`s S K A-K / ? n N *`) are `pattern.zig`, on
//! the `search` library the find bar shares; the last pattern is core's `/`
//! register, so vim reads what helix searched for. `gw` labels the words in
//! view (`goto_word.zig`, on the `labels` library). The jumplist, macros and
//! the clipboard are core's doors; helix only says which keys drive them and
//! what counts as a jump (a search, a goto, `gg`/`ge`).
//!
//! The caret draws ON the last selected character (`cursor-place inside`),
//! as helix's does, rather than one past it.

const std = @import("std");
const weft = @import("weft");
const ex_mod = @import("weft_ex");
const text = @import("text.zig");
const sel = @import("selection.zig");
const edit = @import("edit.zig");
const state = @import("state.zig");
const pattern = @import("pattern.zig");
const goto_word = @import("goto_word.zig");

/// The `:` command line, in helix's own mode namespace (`helix-normal` resting,
/// `helix-ex` the command line). Same shared engine vim uses: helix gets the
/// classic builtins (write/quit/open/vsplit/hsplit + w/q/wq/s abbrevs) and the
/// SAME fall-through to the weft registry (`:name arg…`).
const ex = ex_mod.Ex("helix-normal", "helix-ex");

const file_pick = 0;

// ── Motions ─────────────────────────────────────────────────────────────

fn left(h: usize) ?usize {
    return weft.step(h, .back, .char);
}
fn right(h: usize) ?usize {
    return weft.step(h, .fwd, .char);
}
fn down(h: usize) ?usize {
    return weft.step(h, .fwd, .line);
}
fn up(h: usize) ?usize {
    return weft.step(h, .back, .line);
}
fn lineStart(h: usize) ?usize {
    return weft.lineAt(h).start;
}
fn lineEnd(h: usize) ?usize {
    return weft.lineAt(h).end;
}
fn firstNonBlank(h: usize) ?usize {
    return text.firstNonBlank(h);
}
/// `ge`: the last line — the one before a final newline, not the empty
/// line after it.
fn lastLine(_: usize) ?usize {
    const n = text.len();
    const last = if (n > 0 and text.at(n - 1) == '\n') n - 1 else n;
    return weft.lineAt(last).start;
}

fn word(comptime f: fn (weft.Selection, bool) ?weft.Selection, comptime big: bool) sel.Motion {
    return struct {
        fn m(s: weft.Selection) ?weft.Selection {
            return f(s, big);
        }
    }.m;
}

/// One motion, named once; every key that runs it lists it by name. A `jump`
/// leaves the old place on the jumplist first, so `C-o` comes back.
const MotionDef = struct { name: []const u8, motion: sel.Motion, jump: bool = false };
const motion_defs = [_]MotionDef{
    .{ .name = "left", .motion = sel.point(left) },
    .{ .name = "right", .motion = sel.point(right) },
    .{ .name = "down", .motion = sel.point(down) },
    .{ .name = "up", .motion = sel.point(up) },
    .{ .name = "word-next", .motion = word(text.nextWordStart, false) },
    .{ .name = "word-prev", .motion = word(text.prevWordStart, false) },
    .{ .name = "word-end", .motion = word(text.nextWordEnd, false) },
    .{ .name = "WORD-next", .motion = word(text.nextWordStart, true) },
    .{ .name = "WORD-prev", .motion = word(text.prevWordStart, true) },
    .{ .name = "WORD-end", .motion = word(text.nextWordEnd, true) },
    .{ .name = "line-start", .motion = sel.point(lineStart) },
    .{ .name = "line-end", .motion = sel.point(lineEnd) },
    .{ .name = "first-non-blank", .motion = sel.point(firstNonBlank) },
    .{ .name = "last-line", .motion = sel.point(lastLine), .jump = true },
    .{ .name = "paragraph-next", .motion = text.nextParagraph },
    .{ .name = "paragraph-prev", .motion = text.prevParagraph },
};

/// Motion keys. Each binds the standard navigation intention where one names
/// it (a listing answers `j` with its next row), with helix's own motion as
/// the fallback arm — in `helix-normal` a move, in `helix-select` an extend.
const MotionKey = struct { key: []const u8, motion: []const u8, intention: ?[]const u8 = null };
const motion_keys = [_]MotionKey{
    .{ .key = "h", .motion = "left", .intention = "std.navigation.left" },
    .{ .key = "l", .motion = "right", .intention = "std.navigation.right" },
    .{ .key = "j", .motion = "down", .intention = "std.navigation.down" },
    .{ .key = "k", .motion = "up", .intention = "std.navigation.up" },
    .{ .key = "Left", .motion = "left", .intention = "std.navigation.left" },
    .{ .key = "Right", .motion = "right", .intention = "std.navigation.right" },
    .{ .key = "Down", .motion = "down", .intention = "std.navigation.down" },
    .{ .key = "Up", .motion = "up", .intention = "std.navigation.up" },
    .{ .key = "w", .motion = "word-next", .intention = "std.navigation.word-next" },
    .{ .key = "b", .motion = "word-prev", .intention = "std.navigation.word-previous" },
    .{ .key = "e", .motion = "word-end", .intention = "std.navigation.word-end" },
    .{ .key = "W", .motion = "WORD-next", .intention = "std.navigation.big-word-next" },
    .{ .key = "B", .motion = "WORD-prev", .intention = "std.navigation.big-word-previous" },
    .{ .key = "E", .motion = "WORD-end", .intention = "std.navigation.big-word-end" },
    .{ .key = "Home", .motion = "line-start", .intention = "std.navigation.line-start" },
    .{ .key = "End", .motion = "line-end", .intention = "std.navigation.line-end" },
    .{ .key = "g h", .motion = "line-start", .intention = "std.navigation.line-start" },
    .{ .key = "g l", .motion = "line-end", .intention = "std.navigation.line-end" },
    .{ .key = "g s", .motion = "first-non-blank", .intention = "std.navigation.first-non-blank" },
    .{ .key = "g j", .motion = "down" },
    .{ .key = "g k", .motion = "up" },
    .{ .key = "g e", .motion = "last-line" },
    .{ .key = "bracketright p", .motion = "paragraph-next" },
    .{ .key = "bracketleft p", .motion = "paragraph-prev" },
};

fn motionCmd(comptime m: sel.Motion, comptime mode: sel.Mode, comptime jump: bool) fn () void {
    return struct {
        fn h() void {
            if (jump) weft.jumpPush();
            sel.applyMotion(m, mode, state.takeCount());
        }
    }.h;
}

/// `hx/n/<motion>` (move) and `hx/x/<motion>` (extend) for every motion.
const motion_cmds = blk: {
    var arr: [motion_defs.len * 2]weft.CommandEntry = undefined;
    for (motion_defs, 0..) |d, i| {
        arr[2 * i] = .{ .name = "hx/n/" ++ d.name, .call = motionCmd(d.motion, .move, d.jump) };
        arr[2 * i + 1] = .{ .name = "hx/x/" ++ d.name, .call = motionCmd(d.motion, .extend, d.jump) };
    }
    break :blk arr;
};

/// `gg` / `<n>gg`: the first line, or line n.
fn gotoLine(comptime mode: sel.Mode) fn () void {
    return struct {
        fn h() void {
            weft.jumpPush();
            const line = state.takeRawCount() orelse 1;
            const target = struct {
                var n: u32 = 1;
                fn f(_: usize) ?usize {
                    return weft.lineStart(n);
                }
            };
            target.n = line;
            sel.applyMotion(sel.point(target.f), mode, 1);
        }
    }.h;
}

/// `mm`: the matching bracket, per selection (the `motions` plugin's pair
/// scan, run at each head).
fn matchPair(comptime mode: sel.Mode) fn () void {
    return struct {
        fn h() void {
            sel.applyCursorMotion("motion.match-pair", mode);
        }
    }.h;
}

// ── f / t / F / T ───────────────────────────────────────────────────────

var find_how: text.Find = .to;
var find_mode: sel.Mode = .move;
var find_count: u32 = 1;

fn findEnter(comptime how: text.Find, comptime mode: sel.Mode) fn () void {
    return struct {
        fn h() void {
            find_how = how;
            find_mode = mode;
            find_count = state.takeCount();
            weft.setMode("helix-find");
        }
    }.h;
}

fn findChar() void {
    const ch = weft.argStr(0) orelse "";
    if (find_mode == .extend) weft.setMode("helix-select") else weft.exitToResting();
    if (ch.len != 1) return;
    // A count finds the nth occurrence: the selection runs from the cursor to
    // it, not from the one before.
    const target = struct {
        var c: u8 = 0;
        var n: u32 = 1;
        fn f(s: weft.Selection) ?weft.Selection {
            const first = text.findChar(s, c, find_how) orelse return null;
            var cur = first;
            var k = n;
            while (k > 1) : (k -= 1) cur = text.findChar(cur, c, find_how) orelse break;
            return .{ .anchor = first.anchor, .head = cur.head };
        }
    };
    target.c = ch[0];
    target.n = find_count;
    sel.applyMotion(target.f, find_mode, 1);
}

const find_cmds = [_]weft.CommandEntry{
    .{ .name = "hx/n/find-to", .call = findEnter(.to, .move) },
    .{ .name = "hx/n/find-till", .call = findEnter(.till, .move) },
    .{ .name = "hx/n/find-back-to", .call = findEnter(.back_to, .move) },
    .{ .name = "hx/n/find-back-till", .call = findEnter(.back_till, .move) },
    .{ .name = "hx/x/find-to", .call = findEnter(.to, .extend) },
    .{ .name = "hx/x/find-till", .call = findEnter(.till, .extend) },
    .{ .name = "hx/x/find-back-to", .call = findEnter(.back_to, .extend) },
    .{ .name = "hx/x/find-back-till", .call = findEnter(.back_till, .extend) },
    .{ .name = "hx-find-char", .call = findChar },
    .{ .name = "hx/n/goto-line", .call = gotoLine(.move) },
    .{ .name = "hx/x/goto-line", .call = gotoLine(.extend) },
    .{ .name = "hx/n/match", .call = matchPair(.move) },
    .{ .name = "hx/x/match", .call = matchPair(.extend) },
};

// ── `mi` / `ma`: text objects, per selection ────────────────────────────

/// Helix's object keys → the `textobjects` plugin's object names.
const Obj = struct { keys: []const []const u8, obj: []const u8 };
const objects = [_]Obj{
    .{ .keys = &.{"w"}, .obj = "word" },
    .{ .keys = &.{"W"}, .obj = "WORD" },
    .{ .keys = &.{"p"}, .obj = "paragraph" },
    .{ .keys = &.{ "parenleft", "parenright" }, .obj = "paren" },
    .{ .keys = &.{ "bracketleft", "bracketright" }, .obj = "bracket" },
    .{ .keys = &.{ "braceleft", "braceright" }, .obj = "brace" },
    .{ .keys = &.{"quotedbl"}, .obj = "quote-double" },
    .{ .keys = &.{"apostrophe"}, .obj = "quote-single" },
    .{ .keys = &.{"grave"}, .obj = "quote-back" },
    .{ .keys = &.{ "less", "greater" }, .obj = "angle" },
    .{ .keys = &.{"f"}, .obj = "function" },
    .{ .keys = &.{"t"}, .obj = "class" },
    .{ .keys = &.{"a"}, .obj = "argument" },
    .{ .keys = &.{"c"}, .obj = "comment" },
    .{ .keys = &.{"T"}, .obj = "test" },
    .{ .keys = &.{"m"}, .obj = "pair" },
};

fn rangeCmd(comptime cmd: []const u8) fn () void {
    return struct {
        fn h() void {
            sel.applyRangeCommand(cmd, .move);
        }
    }.h;
}

const object_cmds = blk: {
    var arr: [objects.len * 2]weft.CommandEntry = undefined;
    for (objects, 0..) |o, i| {
        arr[2 * i] = .{ .name = "hx/mi/" ++ o.obj, .call = rangeCmd("textobj.inner-" ++ o.obj) };
        arr[2 * i + 1] = .{ .name = "hx/ma/" ++ o.obj, .call = rangeCmd("textobj.a-" ++ o.obj) };
    }
    break :blk arr;
};

// ── Captures: the key after `r`, `"`, `ms`, `md`, `mr` ──────────────────

fn enter(comptime mode: []const u8) fn () void {
    return struct {
        fn h() void {
            weft.setMode(mode);
        }
    }.h;
}

/// A capture's typed character, copied out of the arg scratch.
var captured: [4]u8 = undefined;
fn capture() ?[]const u8 {
    const ch = weft.argStr(0) orelse return null;
    if (ch.len == 0 or ch.len > captured.len) return null;
    @memcpy(captured[0..ch.len], ch);
    return captured[0..ch.len];
}

fn replaceChar() void {
    weft.exitToResting();
    edit.replaceWith(capture() orelse return);
}

fn registerChar() void {
    weft.exitToResting();
    const ch = capture() orelse return;
    state.register = state.slotOf(ch[0]);
    state.register_char = ch[0];
}

fn surroundAdd() void {
    weft.exitToResting();
    edit.surround(.add, capture() orelse return, null);
}
fn surroundDelete() void {
    weft.exitToResting();
    edit.surround(.delete, capture() orelse return, null);
}
/// `mr<a><b>`: the first key names the pair to find, the second its
/// replacement.
var surround_from: [4]u8 = undefined;
var surround_from_len: usize = 0;
fn surroundFrom() void {
    const ch = capture() orelse return weft.exitToResting();
    @memcpy(surround_from[0..ch.len], ch);
    surround_from_len = ch.len;
    weft.setMode("helix-surround-to");
}
fn surroundTo() void {
    weft.exitToResting();
    const ch = capture() orelse return;
    edit.surround(.replace, surround_from[0..surround_from_len], ch);
}

const captures = [_][2][]const u8{
    .{ "helix-replace", "hx-replace-with" },
    .{ "helix-find", "hx-find-char" },
    .{ "helix-register", "hx-register-char" },
    .{ "helix-surround-add", "hx-surround-add-char" },
    .{ "helix-surround-delete", "hx-surround-delete-char" },
    .{ "helix-surround-from", "hx-surround-from-char" },
    .{ "helix-surround-to", "hx-surround-to-char" },
};

// ── Regex, search, goto word ────────────────────────────────────────────

fn regexOp(comptime op: pattern.Op, comptime mode: sel.Mode) fn () void {
    return struct {
        fn h() void {
            if (op == .search_forward or op == .search_backward) weft.jumpPush();
            pattern.open(op, mode);
        }
    }.h;
}

fn searchAgain(comptime forward: bool, comptime mode: sel.Mode) fn () void {
    return struct {
        fn h() void {
            weft.jumpPush();
            pattern.again(forward, mode);
        }
    }.h;
}

fn searchSelection(comptime bounds: bool) fn () void {
    return struct {
        fn h() void {
            weft.jumpPush();
            pattern.fromSelections(bounds);
        }
    }.h;
}

fn gotoWord(comptime mode: sel.Mode) fn () void {
    return struct {
        fn h() void {
            goto_word.start(mode);
        }
    }.h;
}

/// A goto some other plugin answers (`gd` through LSP): the old place goes
/// on the jumplist first.
fn jumpThen(comptime cmd: []const u8) fn () void {
    return struct {
        fn h() void {
            weft.jumpPush();
            weft.run(cmd);
        }
    }.h;
}

const pattern_cmds = [_]weft.CommandEntry{
    .{ .name = "hx-select-regex", .call = regexOp(.select, .move) },
    .{ .name = "hx-split-regex", .call = regexOp(.split, .move) },
    .{ .name = "hx-keep-regex", .call = regexOp(.keep, .move) },
    .{ .name = "hx-remove-regex", .call = regexOp(.remove, .move) },
    .{ .name = "hx/n/search", .call = regexOp(.search_forward, .move) },
    .{ .name = "hx/x/search", .call = regexOp(.search_forward, .extend) },
    .{ .name = "hx/n/rsearch", .call = regexOp(.search_backward, .move) },
    .{ .name = "hx/x/rsearch", .call = regexOp(.search_backward, .extend) },
    .{ .name = "hx/n/search-next", .call = searchAgain(true, .move) },
    .{ .name = "hx/x/search-next", .call = searchAgain(true, .extend) },
    .{ .name = "hx/n/search-prev", .call = searchAgain(false, .move) },
    .{ .name = "hx/x/search-prev", .call = searchAgain(false, .extend) },
    .{ .name = "hx-search-selection", .call = searchSelection(true) },
    .{ .name = "hx-search-selection-raw", .call = searchSelection(false) },
    .{ .name = "hx/n/goto-word", .call = gotoWord(.move) },
    .{ .name = "hx/x/goto-word", .call = gotoWord(.extend) },
    .{ .name = "hx-goto-word-key", .call = goto_word.key },
    .{ .name = "hx-goto-word-cancel", .call = goto_word.cancel },
    .{ .name = "hx-goto-definition", .call = jumpThen("goto-definition") },
    .{ .name = "hx-goto-type-definition", .call = jumpThen("goto-type-definition") },
    .{ .name = "hx-goto-references", .call = jumpThen("references") },
    .{ .name = "hx-goto-implementation", .call = jumpThen("goto-implementation") },
};

/// The regex prompt's five editing commands, from the shared `prompt`
/// library, in helix's own table.
const regex_prompt_cmds: [pattern.prompt.commands.len]weft.CommandEntry = blk: {
    var arr: [pattern.prompt.commands.len]weft.CommandEntry = undefined;
    for (pattern.prompt.commands, 0..) |c, i| arr[i] = .{ .name = c.name, .call = c.handler };
    break :blk arr;
};

// ── The jumplist and macros (core's; helix names the keys) ──────────────

/// `C-o` / `C-i`, a count walking that many jumps.
fn jumpWalk(comptime cmd: []const u8) fn () void {
    return struct {
        fn h() void {
            var buf: [12]u8 = undefined;
            weft.runStr(cmd, std.fmt.bufPrint(&buf, "{d}", .{state.takeCount()}) catch "1");
        }
    }.h;
}

/// `Q`: start (or stop) recording into the typed register, `@` by default.
fn macroRecord() void {
    const reg = [_]u8{state.takeRegisterChar('@')};
    weft.runStr("macro-record-toggle", &reg);
}

/// `q`: play the typed register (`@` by default), count times.
fn macroPlay() void {
    const reg = [_]u8{state.takeRegisterChar('@')};
    var buf: [12]u8 = undefined;
    const count = std.fmt.bufPrint(&buf, "{d}", .{state.takeCount()}) catch "1";
    weft.runStr2("macro-play", &reg, count);
}

const history_cmds = [_]weft.CommandEntry{
    .{ .name = "hx-jump-back", .call = jumpWalk("jump-back") },
    .{ .name = "hx-jump-forward", .call = jumpWalk("jump-forward") },
    .{ .name = "hx-jump-save", .call = weft.jumpPush },
    .{ .name = "hx-macro-record", .call = macroRecord },
    .{ .name = "hx-macro-play", .call = macroPlay },
};

// ── Counts ──────────────────────────────────────────────────────────────

fn countDigit(comptime d: u32) fn () void {
    return struct {
        fn h() void {
            state.digit(d);
        }
    }.h;
}

const count_cmds = blk: {
    var arr: [10]weft.CommandEntry = undefined;
    for (0..10) |d| arr[d] = .{ .name = std.fmt.comptimePrint("hx-count-{d}", .{d}), .call = countDigit(d) };
    break :blk arr;
};

// ── The command table ───────────────────────────────────────────────────

fn thunk(comptime f: anytype, comptime arg: anytype) fn () void {
    return struct {
        fn h() void {
            f(arg);
        }
    }.h;
}

fn withCount(comptime f: fn (bool, u32) void, comptime arg: bool) fn () void {
    return struct {
        fn h() void {
            f(arg, state.takeCount());
        }
    }.h;
}

fn selectLines() void {
    sel.selectLines(state.takeCount());
}

const base_cmds = [_]weft.CommandEntry{
    .{ .name = "helix-mode", .call = enterHelix },
    .{ .name = "hx-normal", .call = hxNormal },
    .{ .name = "hx-insert-exit", .call = hxInsertExit },
    .{ .name = "hx-select", .call = enter("helix-select") },
    .{ .name = "hx-insert", .call = thunk(edit.insertAt, .before) },
    .{ .name = "hx-append", .call = thunk(edit.insertAt, .after) },
    .{ .name = "hx-insert-line-start", .call = thunk(edit.insertAt, .line_start) },
    .{ .name = "hx-append-line-end", .call = thunk(edit.insertAt, .line_end) },
    .{ .name = "hx-open-below", .call = thunk(edit.openLine, true) },
    .{ .name = "hx-open-above", .call = thunk(edit.openLine, false) },
    // Reshaping the selections.
    .{ .name = "hx-select-line", .call = selectLines },
    .{ .name = "hx-line-bounds", .call = sel.toLineBounds },
    .{ .name = "hx-select-all", .call = sel.selectAll },
    .{ .name = "hx-collapse", .call = sel.collapse },
    .{ .name = "hx-flip", .call = sel.flip },
    .{ .name = "hx-forward", .call = sel.ensureForward },
    .{ .name = "hx-keep-primary", .call = sel.keepPrimary },
    .{ .name = "hx-remove-primary", .call = sel.removePrimary },
    .{ .name = "hx-rotate-next", .call = thunk(sel.rotate, true) },
    .{ .name = "hx-rotate-prev", .call = thunk(sel.rotate, false) },
    .{ .name = "hx-copy-next-line", .call = withCount(sel.copyToLine, true) },
    .{ .name = "hx-copy-prev-line", .call = withCount(sel.copyToLine, false) },
    .{ .name = "hx-trim", .call = sel.trim },
    .{ .name = "hx-split-lines", .call = sel.splitLines },
    .{ .name = "hx-expand", .call = sel.expand },
    .{ .name = "hx-shrink", .call = sel.shrink },
    .{ .name = "hx-sibling-next", .call = rangeCmd("ts.sibling-next") },
    .{ .name = "hx-sibling-prev", .call = rangeCmd("ts.sibling-prev") },
    .{ .name = "hx-function-next", .call = rangeCmd("ts.function-next") },
    .{ .name = "hx-function-prev", .call = rangeCmd("ts.function-prev") },
    // Editing the selections.
    .{ .name = "hx-delete", .call = thunk(edit.delete, false) },
    .{ .name = "hx-delete-keep", .call = thunk(edit.delete, true) },
    .{ .name = "hx-change", .call = thunk(edit.change, false) },
    .{ .name = "hx-change-keep", .call = thunk(edit.change, true) },
    .{ .name = "hx-yank", .call = edit.yank },
    .{ .name = "hx-paste", .call = thunk(edit.paste, true) },
    .{ .name = "hx-paste-before", .call = thunk(edit.paste, false) },
    .{ .name = "hx-replace-register", .call = edit.replaceWithRegister },
    .{ .name = "hx-replace", .call = enter("helix-replace") },
    .{ .name = "hx-replace-with", .call = replaceChar },
    .{ .name = "hx-case-toggle", .call = thunk(edit.setCase, .toggle) },
    .{ .name = "hx-case-lower", .call = thunk(edit.setCase, .lower) },
    .{ .name = "hx-case-upper", .call = thunk(edit.setCase, .upper) },
    .{ .name = "hx-join", .call = edit.join },
    .{ .name = "hx-indent", .call = thunk(edit.onLines, "op.indent") },
    .{ .name = "hx-dedent", .call = thunk(edit.onLines, "op.dedent") },
    .{ .name = "hx-comment", .call = thunk(edit.onLines, "op.comment") },
    .{ .name = "hx-add-line-below", .call = thunk(edit.addBlankLine, true) },
    .{ .name = "hx-add-line-above", .call = thunk(edit.addBlankLine, false) },
    .{ .name = "hx-goto-last-edit", .call = edit.gotoLastEdit },
    .{ .name = "hx-goto-last-modified", .call = edit.gotoLastModified },
    .{ .name = "hx-align", .call = edit.alignSelections },
    .{ .name = "hx-yank-clipboard", .call = edit.yankToClipboard },
    .{ .name = "hx-paste-clipboard", .call = thunk(edit.pasteClipboard, true) },
    .{ .name = "hx-paste-clipboard-before", .call = thunk(edit.pasteClipboard, false) },
    .{ .name = "hx-replace-clipboard", .call = edit.replaceWithClipboard },
    .{ .name = "hx-goto-file", .call = gotoFile },
    .{ .name = "hx-view-sticky", .call = enter("helix-view") },
    // Captures.
    .{ .name = "hx-register", .call = enter("helix-register") },
    .{ .name = "hx-register-char", .call = registerChar },
    .{ .name = "hx-surround-add", .call = enter("helix-surround-add") },
    .{ .name = "hx-surround-add-char", .call = surroundAdd },
    .{ .name = "hx-surround-delete", .call = enter("helix-surround-delete") },
    .{ .name = "hx-surround-delete-char", .call = surroundDelete },
    .{ .name = "hx-surround-replace", .call = enter("helix-surround-from") },
    .{ .name = "hx-surround-from-char", .call = surroundFrom },
    .{ .name = "hx-surround-to-char", .call = surroundTo },
    // The operators the verbs run per selection (not for binding).
    .{ .name = "hx-op-put", .call = edit.opPut },
    .{ .name = "hx-op-join", .call = edit.opJoin },
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

const cmds = base_cmds ++ ex_cmds ++ motion_cmds ++ find_cmds ++ object_cmds ++ count_cmds ++
    pattern_cmds ++ regex_prompt_cmds ++ history_cmds;

/// Commands that keep a pending count or register instead of clearing it:
/// the prefixes themselves (a digit, `"` and its key) and the operators a
/// verb runs per selection, which dispatch while that verb is still running.
/// Every other command clears both after it runs (`settle`).
const preserves = blk: {
    @setEvalBranchQuota(20000);
    var arr: [cmds.len]bool = @splat(false);
    for (cmds, 0..) |c, i| {
        arr[i] = std.mem.startsWith(u8, c.name, "hx-count-") or
            std.mem.startsWith(u8, c.name, "hx-register") or
            std.mem.startsWith(u8, c.name, "hx-op-");
    }
    break :blk arr;
};

fn settle(index: usize) void {
    if (preserves[index]) return;
    state.count = 0;
    state.register = 0;
    state.register_char = 0;
}

// ── Keys ────────────────────────────────────────────────────────────────

fn bindMotion(mode: []const u8, key: []const u8, intention: ?[]const u8, cmd: []const u8) void {
    if (intention) |i| weft.bindKeys(mode, key, &.{ i, cmd }) else weft.bindKey(mode, key, cmd);
}

fn initExtra() void {

    // Only insert commits typed text; helix-normal is modal and declares
    // nothing, so nothing can leak into it. `helix-insert` falls back to the
    // core `default` floor for its BINDINGS (Return -> insert-newline, the
    // std.editing.insert-line-break arm; Backspace, Tab-as-indent) the same
    // way vim's `insert` mode does. Typing inserts at every caret (core's
    // `editEach`), so `i` after `C` types on both lines.
    weft.setFallback("helix-insert", "default");
    weft.textInput("helix-insert", "insert-text");

    // Select mode: helix-normal with motions that EXTEND. Everything else
    // falls through to helix-normal.
    weft.setFallback("helix-select", "helix-normal");

    // Motions: move in normal, extend in select.
    inline for (motion_keys) |m| {
        bindMotion("helix-normal", m.key, m.intention, "hx/n/" ++ m.motion);
        bindMotion("helix-select", m.key, m.intention, "hx/x/" ++ m.motion);
    }
    const finds = [_][2][]const u8{ .{ "f", "find-to" }, .{ "t", "find-till" }, .{ "F", "find-back-to" }, .{ "T", "find-back-till" } };
    for (finds) |f| {
        var nb: [32]u8 = undefined;
        var xb: [32]u8 = undefined;
        weft.bindKey("helix-normal", f[0], std.fmt.bufPrint(&nb, "hx/n/{s}", .{f[1]}) catch continue);
        weft.bindKey("helix-select", f[0], std.fmt.bufPrint(&xb, "hx/x/{s}", .{f[1]}) catch continue);
    }
    weft.bindKey("helix-normal", "g g", "hx/n/goto-line");
    weft.bindKey("helix-select", "g g", "hx/x/goto-line");
    weft.bindKey("helix-normal", "m m", "hx/n/match");
    weft.bindKey("helix-select", "m m", "hx/x/match");

    // Search and goto-word: a move in normal, an extend (a new selection,
    // for a search) in select.
    const searches = [_][2][]const u8{
        .{ "slash", "search" },  .{ "question", "rsearch" },
        .{ "n", "search-next" }, .{ "N", "search-prev" },
        .{ "g w", "goto-word" },
    };
    for (searches) |b| {
        var nb: [32]u8 = undefined;
        var xb: [32]u8 = undefined;
        weft.bindKey("helix-normal", b[0], std.fmt.bufPrint(&nb, "hx/n/{s}", .{b[1]}) catch continue);
        weft.bindKey("helix-select", b[0], std.fmt.bufPrint(&xb, "hx/x/{s}", .{b[1]}) catch continue);
    }

    // Counts: digits accumulate, the next verb or motion repeats.
    for (0..10) |d| {
        var kb: [2]u8 = .{ '0' + @as(u8, @intCast(d)), 0 };
        var cb: [16]u8 = undefined;
        weft.bindKey("helix-normal", kb[0..1], std.fmt.bufPrint(&cb, "hx-count-{d}", .{d}) catch continue);
    }

    // Shared intentions (doc/contextual-workspace-architecture.md §10.2), same
    // shapes vim uses. `u`/`U` undo and redo, with the core commands as their
    // text arm; `C-r` stays a redo too. `Tab`, `Return` and `-` have no helix
    // meaning over text, so the intention IS the whole binding: an unoffered
    // intention does nothing, which is what helix does with those keys. (The
    // line-break arm of Return lives in `helix-insert`, via `default`.) `q`
    // keeps NO binding: real Helix records macros there (phase 5).
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

    // Transfer: `y` captures, `p` places, and `d` takes the selection WITH it.
    // Each leads with the standard word and keeps its text behaviour as the
    // fallback arm.
    weft.bindKeys("helix-normal", "y", &.{ "std.transfer.yank", "hx-yank" });
    weft.bindKeys("helix-normal", "p", &.{ "std.transfer.paste", "hx-paste" });
    weft.bindKeys("helix-normal", "d", &.{ "std.transfer.delete-to-register", "hx-delete" });

    const normal = [_][2][]const u8{
        .{ "i", "hx-insert" },                  .{ "a", "hx-append" },
        .{ "I", "hx-insert-line-start" },       .{ "A", "hx-append-line-end" },
        .{ "o", "hx-open-below" },              .{ "O", "hx-open-above" },
        .{ "v", "hx-select" },                  .{ "colon", "helix-ex" },
        .{ "x", "hx-select-line" },             .{ "X", "hx-line-bounds" },
        .{ "percent", "hx-select-all" },        .{ "semicolon", "hx-collapse" },
        .{ "M-semicolon", "hx-flip" },          .{ "M-colon", "hx-forward" },
        .{ "comma", "hx-keep-primary" },        .{ "M-comma", "hx-remove-primary" },
        .{ "parenright", "hx-rotate-next" },    .{ "parenleft", "hx-rotate-prev" },
        .{ "C", "hx-copy-next-line" },          .{ "M-C", "hx-copy-prev-line" },
        .{ "underscore", "hx-trim" },           .{ "M-s", "hx-split-lines" },
        .{ "M-d", "hx-delete-keep" },           .{ "c", "hx-change" },
        .{ "M-c", "hx-change-keep" },           .{ "P", "hx-paste-before" },
        .{ "R", "hx-replace-register" },        .{ "r", "hx-replace" },
        .{ "asciitilde", "hx-case-toggle" },    .{ "grave", "hx-case-lower" },
        .{ "M-grave", "hx-case-upper" },        .{ "J", "hx-join" },
        .{ "greater", "hx-indent" },            .{ "less", "hx-dedent" },
        .{ "quotedbl", "hx-register" },         .{ "Z", "hx-view-sticky" },
        // Tree-sitter selection (phase 6), per selection over the `ts` plugin.
        .{ "M-o", "hx-expand" },                .{ "M-Up", "hx-expand" },
        .{ "M-i", "hx-shrink" },                .{ "M-Down", "hx-shrink" },
        .{ "M-n", "hx-sibling-next" },          .{ "M-Right", "hx-sibling-next" },
        .{ "M-p", "hx-sibling-prev" },          .{ "M-Left", "hx-sibling-prev" },
        // Scrolling, straight to core's viewport commands.
        .{ "C-d", "scroll-half-down" },         .{ "C-u", "scroll-half-up" },
        .{ "C-f", "scroll-page-down" },         .{ "C-b", "scroll-page-up" },
        // Regex over the selections, and the search pattern.
        .{ "s", "hx-select-regex" },            .{ "S", "hx-split-regex" },
        .{ "K", "hx-keep-regex" },              .{ "M-K", "hx-remove-regex" },
        .{ "asterisk", "hx-search-selection" }, .{ "M-asterisk", "hx-search-selection-raw" },
        .{ "ampersand", "hx-align" },
        // The jumplist and macros.
                  .{ "C-i", "hx-jump-forward" },
        .{ "C-s", "hx-jump-save" },             .{ "Q", "hx-macro-record" },
        .{ "q", "hx-macro-play" },
    };
    for (normal) |b| weft.bindKey("helix-normal", b[0], b[1]);
    // `C-o` asks the focused view for its own history first (a listing's
    // back), then walks the jumplist.
    weft.bindKeys("helix-normal", "C-o", &.{ "std.navigation.back", "hx-jump-back" });
    weft.bindKey("helix-select", "v", "hx-normal");
    weft.bindKey("helix-select", "Escape", "hx-normal");
    weft.bindKey("helix-insert", "Escape", "hx-insert-exit");

    // `g` goto: the motions above, plus the places that are not motions.
    const goto = [_][2][]const u8{
        .{ "g f", "hx-goto-file" },            .{ "g period", "hx-goto-last-edit" },
        .{ "g t", "scroll-goto-view-top" },    .{ "g c", "scroll-goto-view-middle" },
        .{ "g b", "scroll-goto-view-bottom" }, .{ "g d", "hx-goto-definition" },
        .{ "g y", "hx-goto-type-definition" }, .{ "g r", "hx-goto-references" },
        .{ "g i", "hx-goto-implementation" },  .{ "g a", "buffer-back" },
        .{ "g n", "buffer-next" },             .{ "g p", "buffer-previous" },
        .{ "g m", "hx-goto-last-modified" },
    };
    for (goto) |b| weft.bindKey("helix-normal", b[0], b[1]);

    // `m` match: `mm` above; `mi`/`ma` + an object over `textobjects`; and
    // `ms`/`md`/`mr` + characters over the `surround` plugin.
    inline for (objects) |o| inline for (o.keys) |k| {
        weft.bindKey("helix-normal", "m i " ++ k, "hx/mi/" ++ o.obj);
        weft.bindKey("helix-normal", "m a " ++ k, "hx/ma/" ++ o.obj);
    };
    weft.bindKey("helix-normal", "m s", "hx-surround-add");
    weft.bindKey("helix-normal", "m d", "hx-surround-delete");
    weft.bindKey("helix-normal", "m r", "hx-surround-replace");

    // Single-key captures: the next key is the argument, whatever it is.
    for (captures) |c| {
        weft.textInput(c[0], c[1]);
        weft.bindKey(c[0], "Escape", "hx-normal");
    }

    // `[` / `]` pairs (paragraph motions are in the motion table).
    const pairs = [_][2][]const u8{
        .{ "bracketright d", "next-diagnostic" },       .{ "bracketleft d", "prev-diagnostic" },
        .{ "bracketright f", "hx-function-next" },      .{ "bracketleft f", "hx-function-prev" },
        .{ "bracketright space", "hx-add-line-below" }, .{ "bracketleft space", "hx-add-line-above" },
    };
    for (pairs) |b| weft.bindKey("helix-normal", b[0], b[1]);

    // `z` view (one key, then back) and `Z` (sticky: stays until Escape).
    weft.stickyMenu("helix-view");
    const view = [_][2][]const u8{
        .{ "z", "center-line" },              .{ "c", "center-line" },
        .{ "t", "scroll-line-to-top" },       .{ "b", "scroll-line-to-bottom" },
        .{ "j", "scroll-line-down" },         .{ "k", "scroll-line-up" },
        .{ "Down", "scroll-line-down" },      .{ "Up", "scroll-line-up" },
        .{ "C-f", "scroll-page-down" },       .{ "C-b", "scroll-page-up" },
        .{ "Page_Down", "scroll-page-down" }, .{ "Page_Up", "scroll-page-up" },
        .{ "C-d", "scroll-half-down" },       .{ "C-u", "scroll-half-up" },
    };
    for (view) |b| {
        var kb: [32]u8 = undefined;
        weft.bindKey("helix-normal", std.fmt.bufPrint(&kb, "z {s}", .{b[0]}) catch continue, b[1]);
        weft.bindKey("helix-view", b[0], b[1]);
    }

    // Space mode, laid out as Helix's own. A config (helix.js) layers the
    // rest of its leader over it at prio_config. `SPC y p P R` are the system
    // clipboard, mirrored by the unnamed register (`edit.zig`).
    const space = [_][2][]const u8{
        .{ "space f", "find-file" },            .{ "space F", "find-file" },
        .{ "space b", "buf-pick" },             .{ "space e", "files" },
        .{ "space k", "hover" },                .{ "space s", "symbols" },
        .{ "space a", "code-actions" },         .{ "space r", "rename" },
        .{ "space h", "references" },           .{ "space c", "hx-comment" },
        .{ "space g", "git-status" },           .{ "space slash", "grep" },
        .{ "space question", "pick-commands" }, .{ "space y", "hx-yank-clipboard" },
        .{ "space p", "hx-paste-clipboard" },   .{ "space P", "hx-paste-clipboard-before" },
        .{ "space R", "hx-replace-clipboard" }, .{ "space j", "jumplist-pick" },
        .{ "space d", "diagnostics" },
    };
    for (space) |b| weft.bindKey("helix-normal", b[0], b[1]);

    // The `:` command line (helix mode namespace). Same shape as vim's `ex`:
    // printable → hx-ex-type, Backspace/Enter/Escape edit/run/cancel.
    ex.install();
    // The regex prompt of `s S K A-K / ?`, and `gw`'s label keys.
    pattern.prompt.install();
    weft.textInput(goto_word.mode, "hx-goto-word-key");
    weft.bindKey(goto_word.mode, "Escape", "hx-goto-word-cancel");

    // Cursor: block in normal and select, bar in insert — helix's own config,
    // by ITS mode names (proving set-cursor doesn't assume vim's).
    weft.runStr2("set-cursor", "helix-normal", "block");
    weft.runStr2("set-cursor", "helix-select", "block");
    weft.runStr2("set-cursor", "helix-insert", "bar");
    weft.runStr2("cursor-blink", "helix-insert", "on");
    for (captures) |c| weft.runStr2("set-cursor", c[0], "underline");
    // …and where it draws: ON the last selected character, as helix's does,
    // wherever a selection is what the keys act on. Insert types at the head,
    // so its bar stays there.
    for ([_][]const u8{ "helix-normal", "helix-select", "helix-regex", goto_word.mode }) |m|
        weft.runStr2("cursor-place", m, "inside");
    for (captures) |c| weft.runStr2("cursor-place", c[0], "inside");

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

/// Leaving insert: the same, and mark where the typing ended (`g.`).
fn hxInsertExit() void {
    edit.noteEdit();
    hxNormal();
}

// ── Files ───────────────────────────────────────────────────────────────

/// `gf`: open the file the primary selection names (or, with a caret, the
/// path-like run around it).
fn gotoFile() void {
    if (!sel.load()) return;
    const s = sel.items[sel.primary];
    var r = s.range();
    if (r.end == r.start) {
        const isPath = struct {
            fn f(c: u8) bool {
                return !(c == ' ' or c == '\t' or c == '\n' or c == '"' or c == '\'' or c == '(' or c == ')' or c == '<' or c == '>');
            }
        }.f;
        while (r.start > 0 and isPath(text.at(r.start - 1) orelse ' ')) r.start -= 1;
        while (isPath(text.at(r.end) orelse ' ')) r.end += 1;
    }
    if (r.end == r.start) return;
    var buf: [1024]u8 = undefined;
    const name = weft.slice(r.start, @min(r.end, r.start + buf.len));
    @memcpy(buf[0..name.len], name);
    weft.runStr("open", buf[0..name.len]);
}

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
    weft.plugin(&cmds, .{ .init = initExtra, .after = settle, .pick = onPickAccept }).exportAll();
}
