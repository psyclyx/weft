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
//! The caret draws ON the last selected character (`cursor.set-place inside`),
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
const ex = ex_mod.Ex("helix-normal", "helix-ex", "helix.ex");

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
/// `what` finishes the sentence "Move each selection …" for its summary; `to`
/// is what a person reads for its target (`Goto Line Start` moving, `Extend
/// to Line Start` extending) — `g h`, `] p` are chord leaves which-key lists,
/// not machinery.
const MotionDef = struct { name: []const u8, what: []const u8, to: []const u8, motion: sel.Motion, jump: bool = false };
const motion_defs = [_]MotionDef{
    .{ .name = "left", .what = "one character left", .to = "Character Left", .motion = sel.point(left) },
    .{ .name = "right", .what = "one character right", .to = "Character Right", .motion = sel.point(right) },
    .{ .name = "down", .what = "one line down", .to = "Line Below", .motion = sel.point(down) },
    .{ .name = "up", .what = "one line up", .to = "Line Above", .motion = sel.point(up) },
    .{ .name = "word-next", .what = "to the start of the next word", .to = "Next Word Start", .motion = word(text.nextWordStart, false) },
    .{ .name = "word-prev", .what = "to the start of the previous word", .to = "Previous Word Start", .motion = word(text.prevWordStart, false) },
    .{ .name = "word-end", .what = "to the end of the next word", .to = "Next Word End", .motion = word(text.nextWordEnd, false) },
    .{ .name = "big-word-next", .what = "to the start of the next whitespace-delimited word", .to = "Next WORD Start", .motion = word(text.nextWordStart, true) },
    .{ .name = "big-word-prev", .what = "to the start of the previous whitespace-delimited word", .to = "Previous WORD Start", .motion = word(text.prevWordStart, true) },
    .{ .name = "big-word-end", .what = "to the end of the next whitespace-delimited word", .to = "Next WORD End", .motion = word(text.nextWordEnd, true) },
    .{ .name = "line-start", .what = "to the start of its line", .to = "Line Start", .motion = sel.point(lineStart) },
    .{ .name = "line-end", .what = "to the end of its line", .to = "Line End", .motion = sel.point(lineEnd) },
    .{ .name = "first-non-blank", .what = "to the first non-blank character of its line", .to = "First Non-Blank", .motion = sel.point(firstNonBlank) },
    .{ .name = "last-line", .what = "to the last line", .to = "Last Line", .motion = sel.point(lastLine), .jump = true },
    .{ .name = "paragraph-next", .what = "to the next paragraph", .to = "Next Paragraph", .motion = text.nextParagraph },
    .{ .name = "paragraph-prev", .what = "to the previous paragraph", .to = "Previous Paragraph", .motion = text.prevParagraph },
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
    .{ .key = "b", .motion = "word-prev", .intention = "std.navigation.word-prev" },
    .{ .key = "e", .motion = "word-end", .intention = "std.navigation.word-end" },
    .{ .key = "W", .motion = "big-word-next", .intention = "std.navigation.big-word-next" },
    .{ .key = "B", .motion = "big-word-prev", .intention = "std.navigation.big-word-prev" },
    .{ .key = "E", .motion = "big-word-end", .intention = "std.navigation.big-word-end" },
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
            if (jump and (weft.visitsLeft() orelse 0) == 0) weft.jumpPush();
            sel.applyMotion(m, mode, state.takeCount());
        }
    }.h;
}

/// `helix.move-<motion>` and `helix.extend-<motion>` for every motion.
const motion_cmds = blk: {
    var arr: [motion_defs.len * 2]weft.CommandEntry = undefined;
    for (motion_defs, 0..) |d, i| {
        arr[2 * i] = .{ .name = "helix.move-" ++ d.name, .call = motionCmd(d.motion, .move, d.jump), .arity = each, .summary = "Move each selection " ++ d.what ++ ".", .label = "Goto " ++ d.to };
        arr[2 * i + 1] = .{ .name = "helix.extend-" ++ d.name, .call = motionCmd(d.motion, .extend, d.jump), .arity = each, .summary = "Extend each selection " ++ d.what ++ ".", .label = "Extend to " ++ d.to };
    }
    break :blk arr;
};

/// `gg` / `<n>gg`: the first line, or line n.
fn gotoLine(comptime mode: sel.Mode) fn () void {
    return struct {
        fn h() void {
            if ((weft.visitsLeft() orelse 0) == 0) weft.jumpPush();
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
            sel.applyCursorMotion("motions.match-pair", mode);
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
    .{ .name = "helix.move-find-next-char", .call = findEnter(.to, .move), .arity = .whole, .summary = "Select up to and including the next occurrence of the next key typed.", .label = "Find Next Char", .prompts = true },
    .{ .name = "helix.move-till-next-char", .call = findEnter(.till, .move), .arity = .whole, .summary = "Select up to the next occurrence of the next key typed.", .label = "Till Next Char", .prompts = true },
    .{ .name = "helix.move-find-prev-char", .call = findEnter(.back_to, .move), .arity = .whole, .summary = "Select back to and including the previous occurrence of the next key typed.", .label = "Find Previous Char", .prompts = true },
    .{ .name = "helix.move-till-prev-char", .call = findEnter(.back_till, .move), .arity = .whole, .summary = "Select back to just after the previous occurrence of the next key typed.", .label = "Till Previous Char", .prompts = true },
    .{ .name = "helix.extend-find-next-char", .call = findEnter(.to, .extend), .arity = .whole, .summary = "Extend each selection through the next occurrence of the next key typed.", .label = "Extend Find Next Char", .prompts = true },
    .{ .name = "helix.extend-till-next-char", .call = findEnter(.till, .extend), .arity = .whole, .summary = "Extend each selection up to the next occurrence of the next key typed.", .label = "Extend Till Next Char", .prompts = true },
    .{ .name = "helix.extend-find-prev-char", .call = findEnter(.back_to, .extend), .arity = .whole, .summary = "Extend each selection back through the previous occurrence of the next key typed.", .label = "Extend Find Previous Char", .prompts = true },
    .{ .name = "helix.extend-till-prev-char", .call = findEnter(.back_till, .extend), .arity = .whole, .summary = "Extend each selection back to just after the previous occurrence of the next key typed.", .label = "Extend Till Previous Char", .prompts = true },
    .{ .name = "helix.find-char", .call = findChar, .arity = each, .summary = "Find the typed character for the pending find.", .internal = true },
    .{ .name = "helix.move-goto-line", .call = gotoLine(.move), .arity = each, .summary = "Go to the first line, or to the line the count names.", .label = "Goto Line" },
    .{ .name = "helix.extend-goto-line", .call = gotoLine(.extend), .arity = each, .summary = "Extend each selection to the first line, or to the line the count names.", .label = "Extend to Line" },
    .{ .name = "helix.move-match", .call = matchPair(.move), .arity = each, .summary = "Move each selection to its matching bracket.", .label = "Goto Matching Bracket" },
    .{ .name = "helix.extend-match", .call = matchPair(.extend), .arity = each, .summary = "Extend each selection to its matching bracket.", .label = "Extend to Matching Bracket" },
};

// ── `mi` / `ma`: text objects, per selection ────────────────────────────

/// Helix's object keys → the `textobjects` plugin's object names.
/// `label` is what which-key shows under "Select inside/around"; `noun` names
/// the object in the summary.
const Obj = struct { keys: []const []const u8, obj: []const u8, label: []const u8, noun: []const u8 };
const objects = [_]Obj{
    .{ .keys = &.{"w"}, .obj = "word", .label = "Word", .noun = "word" },
    .{ .keys = &.{"W"}, .obj = "big-word", .label = "Big Word", .noun = "whitespace-delimited word" },
    .{ .keys = &.{"p"}, .obj = "paragraph", .label = "Paragraph", .noun = "paragraph" },
    .{ .keys = &.{ "parenleft", "parenright" }, .obj = "paren", .label = "Paren", .noun = "parentheses" },
    .{ .keys = &.{ "bracketleft", "bracketright" }, .obj = "bracket", .label = "Bracket", .noun = "square brackets" },
    .{ .keys = &.{ "braceleft", "braceright" }, .obj = "brace", .label = "Brace", .noun = "braces" },
    .{ .keys = &.{"quotedbl"}, .obj = "quote-double", .label = "Double Quote", .noun = "double quotes" },
    .{ .keys = &.{"apostrophe"}, .obj = "quote-single", .label = "Single Quote", .noun = "single quotes" },
    .{ .keys = &.{"grave"}, .obj = "quote-back", .label = "Backtick", .noun = "backticks" },
    .{ .keys = &.{ "less", "greater" }, .obj = "angle", .label = "Angle Bracket", .noun = "angle brackets" },
    .{ .keys = &.{"f"}, .obj = "function", .label = "Function", .noun = "function" },
    .{ .keys = &.{"t"}, .obj = "class", .label = "Type", .noun = "type or class" },
    .{ .keys = &.{"a"}, .obj = "argument", .label = "Argument", .noun = "argument" },
    .{ .keys = &.{"c"}, .obj = "comment", .label = "Comment", .noun = "comment" },
    .{ .keys = &.{"T"}, .obj = "test", .label = "Test", .noun = "test" },
    .{ .keys = &.{"m"}, .obj = "pair", .label = "Closest Pair", .noun = "closest surrounding pair" },
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
        arr[2 * i] = .{ .name = "helix.select-inner-" ++ o.obj, .call = rangeCmd("textobjects.inner-" ++ o.obj), .arity = each, .summary = "Select inside the " ++ o.noun ++ " around each selection.", .label = o.label };
        arr[2 * i + 1] = .{ .name = "helix.select-around-" ++ o.obj, .call = rangeCmd("textobjects.around-" ++ o.obj), .arity = each, .summary = "Select the whole " ++ o.noun ++ " around each selection, delimiters included.", .label = o.label };
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
    .{ "helix-replace", "helix.replace-with" },
    .{ "helix-find", "helix.find-char" },
    .{ "helix-register", "helix.register-char" },
    .{ "helix-surround-add", "helix.surround-add-char" },
    .{ "helix-surround-delete", "helix.surround-delete-char" },
    .{ "helix-surround-from", "helix.surround-from-char" },
    .{ "helix-surround-to", "helix.surround-to-char" },
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

const pattern_cmds = [_]weft.CommandEntry{
    .{ .name = "helix.select-regex", .call = regexOp(.select, .move), .arity = .whole, .summary = "Select every match of a regex inside the selections.", .label = "Select Regex Matches", .prompts = true },
    .{ .name = "helix.split-regex", .call = regexOp(.split, .move), .arity = .whole, .summary = "Split the selections on every match of a regex.", .label = "Split Selection", .prompts = true },
    .{ .name = "helix.keep-regex", .call = regexOp(.keep, .move), .arity = .whole, .summary = "Keep only the selections that match a regex.", .label = "Keep Selections", .prompts = true },
    .{ .name = "helix.remove-regex", .call = regexOp(.remove, .move), .arity = .whole, .summary = "Remove the selections that match a regex.", .label = "Remove Selections", .prompts = true },
    .{ .name = "helix.move-search", .call = regexOp(.search_forward, .move), .arity = .whole, .summary = "Search forward for a regex and select the match.", .label = "Search", .icon = "search", .prompts = true },
    .{ .name = "helix.extend-search", .call = regexOp(.search_forward, .extend), .arity = .whole, .summary = "Search forward for a regex and add the match as a new selection.", .label = "Extend Search", .prompts = true },
    .{ .name = "helix.move-search-reverse", .call = regexOp(.search_backward, .move), .arity = .whole, .summary = "Search backward for a regex and select the match.", .label = "Reverse Search", .prompts = true },
    .{ .name = "helix.extend-search-reverse", .call = regexOp(.search_backward, .extend), .arity = .whole, .summary = "Search backward for a regex and add the match as a new selection.", .label = "Extend Reverse Search", .prompts = true },
    .{ .name = "helix.move-search-next", .call = searchAgain(true, .move), .arity = .whole, .summary = "Select the next match of the last search.", .label = "Search Next" },
    .{ .name = "helix.extend-search-next", .call = searchAgain(true, .extend), .arity = .whole, .summary = "Add the next match of the last search as a new selection.", .label = "Extend Search Next" },
    .{ .name = "helix.move-search-prev", .call = searchAgain(false, .move), .arity = .whole, .summary = "Select the previous match of the last search.", .label = "Search Previous" },
    .{ .name = "helix.extend-search-prev", .call = searchAgain(false, .extend), .arity = .whole, .summary = "Add the previous match of the last search as a new selection.", .label = "Extend Search Previous" },
    .{ .name = "helix.search-selection", .call = searchSelection(true), .arity = .whole, .summary = "Use the selections' text, bounded at word edges, as the search pattern.", .label = "Search Selection" },
    .{ .name = "helix.search-selection-raw", .call = searchSelection(false), .arity = .whole, .summary = "Use the selections' text as the search pattern, without word bounds.", .label = "Search Selection Without Bounds" },
    .{ .name = "helix.move-goto-word", .call = gotoWord(.move), .arity = .whole, .summary = "Label the words in view and jump to the one whose label is typed.", .label = "Goto Word", .prompts = true },
    .{ .name = "helix.extend-goto-word", .call = gotoWord(.extend), .arity = .whole, .summary = "Label the words in view and extend the selection to the one whose label is typed.", .label = "Extend Goto Word", .prompts = true },
    .{ .name = "helix.goto-word-key", .call = goto_word.key, .arity = .whole, .summary = "Narrow or pick a word label with the typed key.", .internal = true },
    .{ .name = "helix.goto-word-cancel", .call = goto_word.cancel, .arity = .whole, .summary = "Cancel goto word and clear its labels.", .internal = true },
};

/// The regex prompt's five editing commands, from the shared `prompt`
/// library, in helix's own table.
const regex_prompt_cmds: [pattern.prompt.commands.len]weft.CommandEntry = blk: {
    var arr: [pattern.prompt.commands.len]weft.CommandEntry = undefined;
    for (pattern.prompt.commands, 0..) |c, i| arr[i] = .{ .name = c.name, .call = c.handler, .arity = .whole, .summary = c.summary, .internal = true };
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
    weft.runStr("macro.record-toggle", &reg);
}

/// `q`: play the typed register (`@` by default), count times.
fn macroPlay() void {
    const reg = [_]u8{state.takeRegisterChar('@')};
    var buf: [12]u8 = undefined;
    const count = std.fmt.bufPrint(&buf, "{d}", .{state.takeCount()}) catch "1";
    weft.runStr2("macro.play", &reg, count);
}

const history_cmds = [_]weft.CommandEntry{
    .{ .name = "helix.jump-back", .call = jumpWalk("jump.back"), .arity = .whole, .summary = "Jump back through the jumplist, as many jumps as the count.", .label = "Jump Backward" },
    .{ .name = "helix.jump-forward", .call = jumpWalk("jump.forward"), .arity = .whole, .summary = "Jump forward through the jumplist, as many jumps as the count.", .label = "Jump Forward" },
    .{ .name = "helix.macro-record", .call = macroRecord, .arity = .whole, .summary = "Start or stop recording a macro into the chosen register.", .label = "Record Macro" },
    .{ .name = "helix.macro-play", .call = macroPlay, .arity = .whole, .summary = "Replay the macro in the chosen register, count times.", .label = "Replay Macro" },
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
    for (0..10) |d| arr[d] = .{
        .name = std.fmt.comptimePrint("helix.count-{d}", .{d}),
        .call = countDigit(d),
        .arity = .whole,
        .summary = std.fmt.comptimePrint("Add the digit {d} to the pending count.", .{d}),
        .internal = true,
    };
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

/// A verb that runs once per selection (a one-selection program).
const each = weft.Arity.each_extent;
/// A verb that runs once per TARGET `over` finds for each selection,
/// overlapping targets merged — the line verbs, so two selections on one
/// line edit it once.
fn eachOver(comptime over: []const u8) weft.Arity {
    return .{ .each = .{ .over = over, .merge = true } };
}

// Every verb says how it maps over the selections: per selection (`each`),
// per line block (`eachOver`), once over the whole set (`.whole`: what
// reshapes the set, or never reads it), or refused on several (`.one`: a
// goto from the primary's word, which has no per-selection reading).
const base_cmds = [_]weft.CommandEntry{
    .{ .name = "helix.enter", .call = enterHelix, .arity = .whole, .summary = "Switch the buffer to Helix's normal mode.", .label = "Helix Mode" },
    .{ .name = "helix.normal", .call = hxNormal, .arity = .whole, .summary = "Return to normal mode, sealing the current undo step.", .label = "Normal Mode" },
    .{ .name = "helix.insert-exit", .call = hxInsertExit, .arity = .whole, .summary = "Leave insert mode, remembering where the typing ended.", .label = "Exit Insert Mode" },
    .{ .name = "helix.select", .call = enter("helix-select"), .arity = .whole, .summary = "Enter select mode, where motions extend the selections.", .label = "Select Mode" },
    .{ .name = "helix.insert", .call = thunk(edit.insertAt, .before), .arity = each, .summary = "Start typing before each selection.", .label = "Insert Mode" },
    .{ .name = "helix.append", .call = thunk(edit.insertAt, .after), .arity = each, .summary = "Start typing after each selection.", .label = "Append Mode" },
    .{ .name = "helix.insert-line-start", .call = thunk(edit.insertAt, .line_start), .arity = each, .summary = "Start typing at the start of each selection's line.", .label = "Insert at Line Start" },
    .{ .name = "helix.append-line-end", .call = thunk(edit.insertAt, .line_end), .arity = each, .summary = "Start typing at the end of each selection's line.", .label = "Insert at Line End" },
    .{ .name = "helix.open-below", .call = thunk(edit.openLine, true), .arity = each, .summary = "Open a new line below each selection and start typing there.", .label = "Open Below" },
    .{ .name = "helix.open-above", .call = thunk(edit.openLine, false), .arity = each, .summary = "Open a new line above each selection and start typing there.", .label = "Open Above" },
    // Reshaping the selections.
    .{ .name = "helix.select-line", .call = selectLines, .arity = each, .summary = "Select the lines of each selection, taking the next line too when they are already whole.", .label = "Select Line" },
    .{ .name = "helix.line-bounds", .call = sel.toLineBounds, .arity = each, .summary = "Stretch each selection to the bounds of its lines.", .label = "Extend to Line Bounds" },
    .{ .name = "helix.select-all", .call = sel.selectAll, .arity = .whole, .summary = "Select the whole buffer.", .label = "Select All" },
    .{ .name = "helix.collapse", .call = sel.collapse, .arity = each, .summary = "Collapse each selection onto its cursor.", .label = "Collapse Selection" },
    .{ .name = "helix.flip", .call = sel.flip, .arity = each, .summary = "Swap the anchor and cursor of each selection.", .label = "Flip Selection" },
    .{ .name = "helix.head-at-end", .call = sel.ensureForward, .arity = each, .summary = "Turn each selection so its cursor is at the end.", .label = "Ensure Selection Forward" },
    .{ .name = "helix.keep-primary", .call = sel.keepPrimary, .arity = .whole, .summary = "Drop every selection except the primary one.", .label = "Keep Primary Selection" },
    .{ .name = "helix.remove-primary", .call = sel.removePrimary, .arity = .whole, .summary = "Drop the primary selection, keeping the others.", .label = "Remove Primary Selection" },
    .{ .name = "helix.rotate-next", .call = thunk(sel.rotate, true), .arity = .whole, .summary = "Make the next selection the primary one.", .label = "Rotate Selections Forward" },
    .{ .name = "helix.rotate-prev", .call = thunk(sel.rotate, false), .arity = .whole, .summary = "Make the previous selection the primary one.", .label = "Rotate Selections Backward" },
    .{ .name = "helix.copy-next-line", .call = withCount(sel.copyToLine, true), .arity = .whole, .summary = "Copy the primary selection onto the next line it fits on.", .label = "Copy Selection on Next Line" },
    .{ .name = "helix.copy-prev-line", .call = withCount(sel.copyToLine, false), .arity = .whole, .summary = "Copy the primary selection onto the previous line it fits on.", .label = "Copy Selection on Previous Line" },
    .{ .name = "helix.trim", .call = sel.trim, .arity = each, .summary = "Trim the whitespace off both ends of each selection.", .label = "Trim Selections" },
    .{ .name = "helix.split-lines", .call = sel.splitLines, .arity = each, .summary = "Split each selection into one selection per line.", .label = "Split Selection on Newlines" },
    .{ .name = "helix.expand", .call = sel.expand, .arity = .whole, .summary = "Expand every selection to its enclosing syntax node.", .label = "Expand Selection" },
    .{ .name = "helix.shrink", .call = sel.shrink, .arity = .whole, .summary = "Undo the last expansion, or shrink every selection to a child syntax node.", .label = "Shrink Selection" },
    .{ .name = "helix.ts-expand", .call = sel.tsExpand, .arity = each, .summary = "Expand each selection one syntax node outward.", .label = "Expand to Parent Node" },
    .{ .name = "helix.ts-shrink", .call = sel.tsShrink, .arity = each, .summary = "Shrink each selection one syntax node inward.", .label = "Shrink to Child Node" },
    .{ .name = "helix.sibling-next", .call = rangeCmd("ts.sibling-next"), .arity = each, .summary = "Select the next sibling syntax node of each selection.", .label = "Select Next Sibling" },
    .{ .name = "helix.sibling-prev", .call = rangeCmd("ts.sibling-prev"), .arity = each, .summary = "Select the previous sibling syntax node of each selection.", .label = "Select Previous Sibling" },
    .{ .name = "helix.function-next", .call = rangeCmd("ts.function-next"), .arity = each, .summary = "Select the next function after each selection.", .label = "Goto Next Function" },
    .{ .name = "helix.function-prev", .call = rangeCmd("ts.function-prev"), .arity = each, .summary = "Select the previous function before each selection.", .label = "Goto Previous Function" },
    // Editing the selections.
    .{ .name = "helix.delete", .call = thunk(edit.delete, false), .arity = each, .summary = "Delete each selection, yanking it into the register.", .label = "Delete Selection" },
    .{ .name = "helix.delete-keep", .call = thunk(edit.delete, true), .arity = each, .summary = "Delete each selection without yanking it.", .label = "Delete Selection Without Yank" },
    .{ .name = "helix.change", .call = thunk(edit.change, false), .arity = each, .summary = "Delete each selection, yanking it, and start typing in its place.", .label = "Change Selection" },
    .{ .name = "helix.change-keep", .call = thunk(edit.change, true), .arity = each, .summary = "Delete each selection without yanking it and start typing in its place.", .label = "Change Selection Without Yank" },
    .{ .name = "helix.yank", .call = edit.yank, .arity = each, .summary = "Yank each selection into the register.", .label = "Yank" },
    .{ .name = "helix.paste", .call = thunk(edit.paste, true), .arity = each, .summary = "Paste the register after each selection.", .label = "Paste After" },
    .{ .name = "helix.paste-before", .call = thunk(edit.paste, false), .arity = each, .summary = "Paste the register before each selection.", .label = "Paste Before" },
    .{ .name = "helix.paste-text", .call = weft.thunk(edit.pasteClipboardText), .arity = each, .params = "where text", .summary = "Paste the given text after or before each selection.", .internal = true },
    .{ .name = "helix.replace-register", .call = edit.replaceWithRegister, .arity = each, .summary = "Replace each selection with the register's contents.", .label = "Replace with Yanked" },
    .{ .name = "helix.replace-text", .call = weft.thunk(edit.replaceText), .arity = each, .params = "text", .summary = "Replace each selection with the given text.", .internal = true },
    .{ .name = "helix.replace", .call = enter("helix-replace"), .arity = .whole, .summary = "Replace every character of each selection with the next key typed.", .label = "Replace", .prompts = true },
    .{ .name = "helix.replace-with", .call = replaceChar, .arity = each, .summary = "Replace every character of each selection with the typed character.", .internal = true },
    .{ .name = "helix.case-toggle", .call = thunk(edit.setCase, .toggle), .arity = each, .summary = "Toggle the case of each selection.", .label = "Switch Case" },
    .{ .name = "helix.case-lower", .call = thunk(edit.setCase, .lower), .arity = each, .summary = "Lowercase each selection.", .label = "Switch to Lowercase" },
    .{ .name = "helix.case-upper", .call = thunk(edit.setCase, .upper), .arity = each, .summary = "Uppercase each selection.", .label = "Switch to Uppercase" },
    .{ .name = "helix.join", .call = edit.join, .arity = eachOver("helix.join-target"), .summary = "Join the lines of each selection into one, separated by spaces.", .label = "Join Selections" },
    .{ .name = "helix.indent", .call = thunk(edit.onLines, "indent.increase"), .arity = eachOver("helix.line-block"), .summary = "Indent the lines of each selection.", .label = "Indent" },
    .{ .name = "helix.dedent", .call = thunk(edit.onLines, "indent.decrease"), .arity = eachOver("helix.line-block"), .summary = "Unindent the lines of each selection.", .label = "Unindent" },
    .{ .name = "helix.comment", .call = thunk(edit.onLines, "comment.toggle"), .arity = eachOver("helix.line-block"), .summary = "Toggle comments on the lines of each selection.", .label = "Toggle Comments" },
    .{ .name = "helix.add-line-below", .call = edit.addBlankLine, .arity = eachOver("helix.blank-below"), .summary = "Add a blank line below each selection.", .label = "Add Newline Below" },
    .{ .name = "helix.add-line-above", .call = edit.addBlankLine, .arity = eachOver("helix.blank-above"), .summary = "Add a blank line above each selection.", .label = "Add Newline Above" },
    .{ .name = "helix.goto-last-edit", .call = edit.gotoLastEdit, .arity = .whole, .summary = "Go back to the last place edited.", .label = "Goto Last Modification" },
    .{ .name = "helix.goto-last-modified", .call = edit.gotoLastModified, .arity = .whole, .summary = "Switch to the buffer edited most recently before this one.", .label = "Goto Last Modified File" },
    .{ .name = "helix.align", .call = edit.alignSelections, .arity = .whole, .summary = "Pad the selections with spaces so they line up in columns.", .label = "Align Selections" },
    .{ .name = "helix.yank-clipboard", .call = edit.yankToClipboard, .arity = .whole, .summary = "Yank the selections to the system clipboard.", .label = "Yank to Clipboard" },
    .{ .name = "helix.paste-clipboard", .call = thunk(edit.pasteClipboard, true), .arity = .whole, .summary = "Paste the system clipboard after each selection.", .label = "Paste Clipboard After" },
    .{ .name = "helix.paste-clipboard-before", .call = thunk(edit.pasteClipboard, false), .arity = .whole, .summary = "Paste the system clipboard before each selection.", .label = "Paste Clipboard Before" },
    .{ .name = "helix.replace-clipboard", .call = edit.replaceWithClipboard, .arity = .whole, .summary = "Replace each selection with the system clipboard.", .label = "Replace with Clipboard" },
    .{ .name = "helix.goto-file", .arity = .one, .call = gotoFile, .summary = "Open the file the primary selection names.", .label = "Goto File" },
    .{ .name = "helix.view-sticky", .call = enter("helix-view"), .arity = .whole, .summary = "Enter the sticky view mode, which scrolls until Escape.", .label = "View Mode" },
    // Captures.
    .{ .name = "helix.register", .call = enter("helix-register"), .arity = .whole, .summary = "Choose the register the next command uses from the next key typed.", .label = "Select Register", .prompts = true },
    .{ .name = "helix.register-char", .call = registerChar, .arity = .whole, .summary = "Use the typed character's register for the next command.", .internal = true },
    .{ .name = "helix.surround-add", .call = enter("helix-surround-add"), .arity = .whole, .summary = "Surround each selection with the pair of the next key typed.", .label = "Surround Add", .prompts = true },
    .{ .name = "helix.surround-add-char", .call = surroundAdd, .arity = .whole, .summary = "Surround each selection with the typed character's pair.", .internal = true },
    .{ .name = "helix.surround-delete", .call = enter("helix-surround-delete"), .arity = .whole, .summary = "Delete the surrounding pair of the next key typed.", .label = "Surround Delete", .prompts = true },
    .{ .name = "helix.surround-delete-char", .call = surroundDelete, .arity = .whole, .summary = "Delete the surrounding pair of the typed character.", .internal = true },
    .{ .name = "helix.surround-replace", .call = enter("helix-surround-from"), .arity = .whole, .summary = "Replace one surrounding pair with another, both chosen by the next two keys.", .label = "Surround Replace", .prompts = true },
    .{ .name = "helix.surround-from-char", .call = surroundFrom, .arity = .whole, .summary = "Choose the surrounding pair to replace from the typed character.", .internal = true },
    .{ .name = "helix.surround-to-char", .call = surroundTo, .arity = .whole, .summary = "Replace the chosen surrounding pair with the typed character's pair.", .internal = true },
    .{ .name = "helix.surround-wrap", .call = edit.surroundWrap, .arity = each, .summary = "Wrap the selection in the pair chosen for surround.", .internal = true },
    // The targets the line verbs map over (range commands, not for binding).
    .{ .name = "helix.line-block", .call = edit.lineBlock, .arity = each, .summary = "Return the whole lines of the selection for the line verbs to map over.", .internal = true },
    .{ .name = "helix.join-target", .call = edit.joinTarget, .arity = each, .summary = "Return the lines a join takes from the selection.", .internal = true },
    .{ .name = "helix.blank-below", .call = thunk(edit.blankPoint, true), .arity = each, .summary = "Return where a blank line below the selection goes.", .internal = true },
    .{ .name = "helix.blank-above", .call = thunk(edit.blankPoint, false), .arity = each, .summary = "Return where a blank line above the selection goes.", .internal = true },
    // The `:` ex command line — the key that OPENS it (shared engine; helix
    // mode namespace). Its five editing commands come from the shared
    // prompt, spliced in as `ex_cmds` below.
    .{ .name = "helix.ex", .call = ex.enter, .arity = .whole, .summary = "Open the command line to run a command by name.", .label = "Command Line", .icon = "command", .prompts = true },
};

/// The `:` line's editing commands, from the shared `prompt` library, mapped
/// into helix's `weft.CommandEntry` so `on_command`'s id indexing stays one flat table.
const ex_cmds: [ex.commands.len]weft.CommandEntry = blk: {
    var arr: [ex.commands.len]weft.CommandEntry = undefined;
    for (ex.commands, 0..) |c, i| arr[i] = .{ .name = c.name, .call = c.handler, .arity = .whole, .summary = c.summary, .internal = true };
    break :blk arr;
};

const cmds = base_cmds ++ ex_cmds ++ motion_cmds ++ find_cmds ++ object_cmds ++ count_cmds ++
    pattern_cmds ++ regex_prompt_cmds ++ history_cmds;

/// Commands that keep a pending count or register instead of clearing it:
/// the prefixes themselves (a digit, `"` and its key). Every other command
/// clears both once it ENDS (`settle`) — after the last of the runs dispatch
/// maps it into, never between them.
const preserves = blk: {
    @setEvalBranchQuota(20000);
    var arr: [cmds.len]bool = @splat(false);
    for (cmds, 0..) |c, i| {
        arr[i] = std.mem.startsWith(u8, c.name, "helix.count-") or
            std.mem.startsWith(u8, c.name, "helix.register");
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
    // core `default` floor for its BINDINGS (Return -> edit.insert-newline, the
    // std.editing.insert-line-break arm; Backspace, Tab-as-indent) the same
    // way vim's `insert` mode does. Typing inserts at every caret (core's
    // `editEach`), so `i` after `C` types on both lines.
    weft.setFallback("helix-insert", "default");
    weft.textInput("helix-insert", "edit.insert-text");
    // One undo step, in helix's terms: a normal-mode command, and
    // `helix-insert` CONTINUES the step that entered it (`c`, `o`, `i` and the
    // typing after them are one `u`).
    weft.runStr2("mode.set-undo-step", "helix-insert", "continue");

    // Select mode: helix-normal with motions that EXTEND. Everything else
    // falls through to helix-normal.
    weft.setFallback("helix-select", "helix-normal");

    // Motions: move in normal, extend in select.
    inline for (motion_keys) |m| {
        bindMotion("helix-normal", m.key, m.intention, "helix.move-" ++ m.motion);
        bindMotion("helix-select", m.key, m.intention, "helix.extend-" ++ m.motion);
    }
    const finds = [_][2][]const u8{ .{ "f", "find-next-char" }, .{ "t", "till-next-char" }, .{ "F", "find-prev-char" }, .{ "T", "till-prev-char" } };
    for (finds) |f| {
        var nb: [32]u8 = undefined;
        var xb: [32]u8 = undefined;
        weft.bindKey("helix-normal", f[0], std.fmt.bufPrint(&nb, "helix.move-{s}", .{f[1]}) catch continue);
        weft.bindKey("helix-select", f[0], std.fmt.bufPrint(&xb, "helix.extend-{s}", .{f[1]}) catch continue);
    }
    weft.bindKey("helix-normal", "g g", "helix.move-goto-line");
    weft.bindKey("helix-select", "g g", "helix.extend-goto-line");
    weft.bindKey("helix-normal", "m m", "helix.move-match");
    weft.bindKey("helix-select", "m m", "helix.extend-match");

    // Search and goto-word: a move in normal, an extend (a new selection,
    // for a search) in select.
    const searches = [_][2][]const u8{
        .{ "slash", "search" },  .{ "question", "search-reverse" },
        .{ "n", "search-next" }, .{ "N", "search-prev" },
        .{ "g w", "goto-word" },
    };
    for (searches) |b| {
        var nb: [32]u8 = undefined;
        var xb: [32]u8 = undefined;
        weft.bindKey("helix-normal", b[0], std.fmt.bufPrint(&nb, "helix.move-{s}", .{b[1]}) catch continue);
        weft.bindKey("helix-select", b[0], std.fmt.bufPrint(&xb, "helix.extend-{s}", .{b[1]}) catch continue);
    }

    // Counts: digits accumulate, the next verb or motion repeats.
    for (0..10) |d| {
        var kb: [2]u8 = .{ '0' + @as(u8, @intCast(d)), 0 };
        var cb: [16]u8 = undefined;
        weft.bindKey("helix-normal", kb[0..1], std.fmt.bufPrint(&cb, "helix.count-{d}", .{d}) catch continue);
    }

    // Shared intentions (doc/contextual-workspace-architecture.md §10.2), same
    // shapes vim uses. `u`/`U` undo and redo, with the core commands as their
    // text arm; `C-r` stays a redo too. `Tab`, `Return` and `-` have no helix
    // meaning over text, so the intention IS the whole binding: an unoffered
    // intention does nothing, which is what helix does with those keys. (The
    // line-break arm of Return lives in `helix-insert`, via `default`.) `q`
    // keeps NO binding: real Helix records macros there (phase 5).
    const intended = [_][3][]const u8{
        .{ "u", "std.history.undo", "edit.undo" },
        .{ "U", "std.history.redo", "edit.redo" },
        .{ "C-r", "std.history.redo", "edit.redo" },
    };
    for (intended) |b| weft.bindKeys("helix-normal", b[0], &.{ b[1], b[2] });
    weft.bindKeys("helix-normal", "Tab", &.{"std.hierarchy.toggle-expanded"});
    weft.bindKeys("helix-normal", "Return", &.{"std.target.activate"});
    weft.bindKeys("helix-normal", "KP_Enter", &.{"std.target.activate"});
    weft.bindKeys("helix-normal", "minus", &.{"std.hierarchy.step-out"});

    // Transfer: `y` captures, `p` places, and `d` takes the selection WITH it.
    // Each leads with the standard word and keeps its text behaviour as the
    // fallback arm.
    weft.bindKeys("helix-normal", "y", &.{ "std.transfer.yank", "helix.yank" });
    weft.bindKeys("helix-normal", "p", &.{ "std.transfer.paste", "helix.paste" });
    weft.bindKeys("helix-normal", "d", &.{ "std.transfer.delete-to-register", "helix.delete" });

    const normal = [_][2][]const u8{
        .{ "i", "helix.insert" },                  .{ "a", "helix.append" },
        .{ "I", "helix.insert-line-start" },       .{ "A", "helix.append-line-end" },
        .{ "o", "helix.open-below" },              .{ "O", "helix.open-above" },
        .{ "v", "helix.select" },                  .{ "colon", "helix.ex" },
        .{ "x", "helix.select-line" },             .{ "X", "helix.line-bounds" },
        .{ "percent", "helix.select-all" },        .{ "semicolon", "helix.collapse" },
        .{ "M-semicolon", "helix.flip" },          .{ "M-colon", "helix.head-at-end" },
        .{ "comma", "helix.keep-primary" },        .{ "M-comma", "helix.remove-primary" },
        .{ "parenright", "helix.rotate-next" },    .{ "parenleft", "helix.rotate-prev" },
        .{ "C", "helix.copy-next-line" },          .{ "M-C", "helix.copy-prev-line" },
        .{ "underscore", "helix.trim" },           .{ "M-s", "helix.split-lines" },
        .{ "M-d", "helix.delete-keep" },           .{ "c", "helix.change" },
        .{ "M-c", "helix.change-keep" },           .{ "P", "helix.paste-before" },
        .{ "R", "helix.replace-register" },        .{ "r", "helix.replace" },
        .{ "asciitilde", "helix.case-toggle" },    .{ "grave", "helix.case-lower" },
        .{ "M-grave", "helix.case-upper" },        .{ "J", "helix.join" },
        .{ "greater", "helix.indent" },            .{ "less", "helix.dedent" },
        .{ "quotedbl", "helix.register" },         .{ "Z", "helix.view-sticky" },
        // Tree-sitter selection (phase 6), per selection over the `ts` plugin.
        .{ "M-o", "helix.expand" },                .{ "M-Up", "helix.expand" },
        .{ "M-i", "helix.shrink" },                .{ "M-Down", "helix.shrink" },
        .{ "M-n", "helix.sibling-next" },          .{ "M-Right", "helix.sibling-next" },
        .{ "M-p", "helix.sibling-prev" },          .{ "M-Left", "helix.sibling-prev" },
        // Scrolling, straight to core's viewport commands.
        .{ "C-d", "scroll.half-page-down" },       .{ "C-u", "scroll.half-page-up" },
        .{ "C-f", "scroll.page-down" },            .{ "C-b", "scroll.page-up" },
        // Regex over the selections, and the search pattern.
        .{ "s", "helix.select-regex" },            .{ "S", "helix.split-regex" },
        .{ "K", "helix.keep-regex" },              .{ "M-K", "helix.remove-regex" },
        .{ "asterisk", "helix.search-selection" }, .{ "M-asterisk", "helix.search-selection-raw" },
        .{ "ampersand", "helix.align" },
        // The jumplist and macros.
                  .{ "C-i", "helix.jump-forward" },
        .{ "C-s", "jump.push" },                   .{ "Q", "helix.macro-record" },
        .{ "q", "helix.macro-play" },
    };
    for (normal) |b| weft.bindKey("helix-normal", b[0], b[1]);
    // In a terminal you broke out of, `i`/`a` take you back in; the resume
    // offer is absent everywhere else, so insert runs.
    weft.bindKeys("helix-normal", "i", &.{ "std.input.resume", "helix.insert" });
    weft.bindKeys("helix-normal", "a", &.{ "std.input.resume", "helix.append" });
    // `C-o` asks the focused view for its own history first (a listing's
    // back), then walks the jumplist.
    weft.bindKeys("helix-normal", "C-o", &.{ "std.navigation.back", "helix.jump-back" });
    weft.bindKey("helix-select", "v", "helix.normal");
    weft.bindKey("helix-select", "Escape", "helix.normal");
    weft.bindKey("helix-insert", "Escape", "helix.insert-exit");

    // `g` goto: the motions above, plus the places that are not motions.
    const goto = [_][2][]const u8{
        .{ "g f", "helix.goto-file" },          .{ "g period", "helix.goto-last-edit" },
        .{ "g t", "scroll.cursor-to-top" },     .{ "g c", "scroll.cursor-to-middle" },
        .{ "g b", "scroll.cursor-to-bottom" },  .{ "g d", "lsp.goto-definition" },
        .{ "g y", "lsp.goto-type-definition" }, .{ "g r", "lsp.references" },
        .{ "g i", "lsp.goto-implementation" },  .{ "g a", "buffer.back" },
        .{ "g n", "buffer.next" },              .{ "g p", "buffer.prev" },
        .{ "g m", "helix.goto-last-modified" },
    };
    for (goto) |b| weft.bindKey("helix-normal", b[0], b[1]);

    // `m` match: `mm` above; `mi`/`ma` + an object over `textobjects`; and
    // `ms`/`md`/`mr` + characters over the `surround` plugin.
    inline for (objects) |o| inline for (o.keys) |k| {
        weft.bindKey("helix-normal", "m i " ++ k, "helix.select-inner-" ++ o.obj);
        weft.bindKey("helix-normal", "m a " ++ k, "helix.select-around-" ++ o.obj);
    };
    weft.bindKey("helix-normal", "m s", "helix.surround-add");
    weft.bindKey("helix-normal", "m d", "helix.surround-delete");
    weft.bindKey("helix-normal", "m r", "helix.surround-replace");

    // Single-key captures: the next key is the argument, whatever it is.
    for (captures) |c| {
        weft.textInput(c[0], c[1]);
        weft.bindKey(c[0], "Escape", "helix.normal");
    }

    // `[` / `]` pairs (paragraph motions are in the motion table).
    const pairs = [_][2][]const u8{
        .{ "bracketright d", "lsp.next-diagnostic" },      .{ "bracketleft d", "lsp.prev-diagnostic" },
        .{ "bracketright f", "helix.function-next" },      .{ "bracketleft f", "helix.function-prev" },
        .{ "bracketright space", "helix.add-line-below" }, .{ "bracketleft space", "helix.add-line-above" },
    };
    for (pairs) |b| weft.bindKey("helix-normal", b[0], b[1]);

    // `z` view (one key, then back) and `Z` (sticky: stays until Escape).
    weft.stickyMenu("helix-view");
    const view = [_][2][]const u8{
        .{ "z", "scroll.center-line" },       .{ "c", "scroll.center-line" },
        .{ "t", "scroll.line-to-top" },       .{ "b", "scroll.line-to-bottom" },
        .{ "j", "scroll.line-down" },         .{ "k", "scroll.line-up" },
        .{ "Down", "scroll.line-down" },      .{ "Up", "scroll.line-up" },
        .{ "C-f", "scroll.page-down" },       .{ "C-b", "scroll.page-up" },
        .{ "Page_Down", "scroll.page-down" }, .{ "Page_Up", "scroll.page-up" },
        .{ "C-d", "scroll.half-page-down" },  .{ "C-u", "scroll.half-page-up" },
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
        .{ "space f", "files.find" },              .{ "space F", "files.find" },
        .{ "space b", "buffer.pick" },             .{ "space e", "files.browse" },
        .{ "space k", "lsp.hover" },               .{ "space s", "lsp.pick-symbol" },
        .{ "space a", "lsp.code-actions" },        .{ "space r", "lsp.rename" },
        .{ "space h", "lsp.references" },          .{ "space c", "helix.comment" },
        .{ "space g", "git.status" },              .{ "space slash", "grep.search" },
        .{ "space question", "palette.open" },     .{ "space y", "helix.yank-clipboard" },
        .{ "space p", "helix.paste-clipboard" },   .{ "space P", "helix.paste-clipboard-before" },
        .{ "space R", "helix.replace-clipboard" }, .{ "space j", "jump.pick" },
        .{ "space d", "lsp.pick-diagnostic" },
    };
    for (space) |b| weft.bindKey("helix-normal", b[0], b[1]);

    // The `:` command line (helix mode namespace). Same shape as vim's `ex`:
    // printable → hx-ex-type, Backspace/Enter/Escape edit/run/cancel.
    ex.install();
    // The regex prompt of `s S K A-K / ?`, and `gw`'s label keys.
    pattern.prompt.install();
    weft.textInput(goto_word.mode, "helix.goto-word-key");
    weft.bindKey(goto_word.mode, "Escape", "helix.goto-word-cancel");

    // Cursor: block in normal and select, bar in insert — helix's own config,
    // by ITS mode names (proving cursor.set-style doesn't assume vim's).
    weft.runStr2("cursor.set-style", "helix-normal", "block");
    weft.runStr2("cursor.set-style", "helix-select", "block");
    weft.runStr2("cursor.set-style", "helix-insert", "bar");
    weft.runStr2("cursor.set-blink", "helix-insert", "on");
    for (captures) |c| weft.runStr2("cursor.set-style", c[0], "underline");
    // …and where it draws: ON the last selected character, as helix's does,
    // wherever a selection is what the keys act on. Insert types at the head,
    // so its bar stays there.
    for ([_][]const u8{ "helix-normal", "helix-select", "helix-regex", goto_word.mode }) |m|
        weft.runStr2("cursor.set-place", m, "inside");
    for (captures) |c| weft.runStr2("cursor.set-place", c[0], "inside");

    // §10.4: helix's answer for each posture (and, implicitly, that
    // `helix-normal` is a mode a buffer rests in). Like vim's `normal`,
    // `helix-normal` commits nothing, so it serves both; what a structural
    // entry changes is that helix declines to ENTER `helix-insert` there
    // (`enterInsert`), rather than resting somewhere its keys are dead.
    weft.restingPosture(.text, "helix-normal");
    weft.restingPosture(.structural, "helix-normal");
    // Over text, THESE are what the transfer words mean — `d`, `y` and `p`
    // over the selections, through helix's registers: core offers
    // std.transfer.* where a grammar provides the matching action, so the
    // context menu over text has Cut, Copy and Paste, and they do what the
    // keys do.
    weft.provide("selection.cut", .{ .posture = "text" }, "helix.delete", 0);
    weft.provide("selection.copy", .{ .posture = "text" }, "helix.yank", 0);
    weft.provide("selection.paste-after", .{ .posture = "text" }, "helix.paste", 0);
    // Helix's own status-line names. A mode left unnamed (goto, match, a
    // count) shows the mode the entry rests in.
    weft.modeDisplay("helix-normal", "NOR", .normal);
    weft.modeDisplay("helix-insert", "INS", .insert);
    weft.modeDisplay("helix-select", "SEL", .select);
    // A listing row IS its name to a modal grammar: focusing it edits the
    // name, and `helix-normal` keeps every key (doc/chrome.md §5.2).
    weft.runStr2("mode.set-structural-focus", "helix-normal", "text");
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
    weft.openTyped(buf[0..name.len]);
}

comptime {
    weft.plugin(&cmds, .{ .init = initExtra, .after = settle }).exportAll();
}
