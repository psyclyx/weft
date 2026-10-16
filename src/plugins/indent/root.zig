//! indent — what one indent step is in each buffer, and everything that
//! uses it: the `>`/`<` operators, Return's auto-indent, a closer's electric
//! dedent, Tab and Backspace in a file's indentation, and the status line's
//! `Spaces: 4`. A `.wasm` plugin; core knows none of it.
//!
//! THE UNIT, per buffer, from the first of these that says it (each half —
//! tabs or spaces, and the width — on its own): an `.editorconfig` over the
//! file; the file's own lines (`indentation.Detector`); config for the
//! file's language, `weft.set("indent", "<lang>", "tabs")`, the language
//! keyed as everywhere in weft by its extension (`go`, `zig` — the `lang`
//! fact, and `weft.set("lsp", "<lang>", …)`); config's
//! `weft.set("indent", "default", "spaces:4")`; four spaces. `indent.set`,
//! `indent.toggle-tabs` and `indent.detect` change it for the buffer and
//! publish what they made it as the entry's `indent.unit` context value (`tabs`,
//! `spaces:4`). `.editorconfig` is read only inside the file's place, which
//! is all the `fs_read` this plugin asks for reaches without a grant.
//!
//! THE DOORS it rides, each generic: it PROVIDES core's three typing-key
//! actions — `edit.break-line` (Return, and every grammar's open-line),
//! `edit.tab`, `edit.backspace` — in text files, so wherever it is not
//! loaded or does not apply, the keys are the bare characters they were; it
//! hears TYPED closers through `input.on-typing`, which runs after the key
//! did whatever it does (autopair's type-over included) and never for pasted
//! or inserted text, and the end of typing (leaving insert) through
//! `input.on-typing-end`, asked for only while an auto-indent waits on a
//! blank line; and it reads the grammar's undo rule (`mode.undo-step`)
//! to make an adjustment its own undo step only where a grammar cuts steps
//! per run of a command (ide, emacs) — never inside a step a grammar
//! continues (vim's `o…Esc`, one `u`).
//!
//! THE ESCAPE HATCHES: undo right after an auto-indent or an electric
//! dedent takes back just the adjustment (in a modeless grammar); an
//! auto-indent left on a line you leave blank — Return again, or leaving
//! insert — is taken away; Backspace in a spaces file's indentation takes a
//! whole step; and `weft.set("indent", "auto" | "electric" | "backspace" |
//! "detect" | "editorconfig", "off")`, globally or per language as
//! `"<lang>.auto"` and so on, turns each off.

const std = @import("std");
const weft = @import("weft");
const statusline = @import("weft_statusline");
const indentation = @import("indentation.zig");
const editorconfig = @import("editorconfig.zig");

const Unit = indentation.Unit;
const Partial = indentation.Partial;

const each = weft.Arity.each_extent;

const cmds = [_]weft.CommandEntry{
    .{ .name = "indent.increase", .arity = each, .call = opIndent, .summary = "Indent the non-blank lines of the operator's range.", .internal = true },
    .{ .name = "indent.decrease", .arity = each, .call = opDedent, .summary = "Dedent the lines of the operator's range.", .internal = true },
    .{ .name = "indent.newline", .arity = each, .call = newline, .summary = "Break the line, carrying its indentation over and a step deeper after an opener.", .internal = true },
    .{ .name = "indent.tab", .arity = each, .call = tab, .summary = "Insert one indent step at the cursor: a tab, or spaces to the next stop.", .internal = true },
    .{ .name = "indent.backspace", .arity = each, .call = backspace, .summary = "Delete backward, a whole step at a time in a spaces file's indentation.", .internal = true },
    .{ .name = "indent.typed", .arity = each, .params = "text", .call = typed, .summary = "React to typed text: re-indent a closer that starts its line, or tidy a blank auto-indent when typing ends.", .internal = true },
    .{ .name = "indent.set", .arity = .whole, .params = "unit", .call = set, .summary = "Set this buffer's indent step: tabs, spaces, spaces:2, or a width.", .label = "Set Indentation", .prompts = true },
    .{ .name = "indent.toggle-tabs", .arity = .whole, .call = toggleTabs, .summary = "Switch this buffer between indenting with tabs and with spaces.", .label = "Toggle Tabs and Spaces" },
    .{ .name = "indent.detect", .arity = .whole, .call = redetect, .summary = "Work this buffer's indent step out again from its file and config.", .label = "Detect Indentation" },
};

// ── Where it applies ─────────────────────────────────────────────────

/// A text entry that is not a tool's projection: a file, a scratch. The
/// typing-key providers are scoped to it, so a listing, a field, a terminal
/// keep the keys exactly as core means them.
const not_tool: weft.Predicate = .{ .locus = .tool };
const text_files: weft.Predicate = .{ .all = &.{ .{ .posture = "text" }, .{ .not = &not_tool } } };

/// The same scope, asked from inside a typing hook (which runs wherever a
/// mode commits text): a text posture, and an entry that is a file or a
/// document — `weft://<locus>/file/…`, `…/doc/…`.
fn textFileHere() bool {
    if (weft.posture() != .text) return false;
    const d = weft.designation() orelse return weft.path() != null;
    const rest = if (std.mem.indexOf(u8, d, "://")) |i| d[i + 3 ..] else return false;
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return false;
    const kind = rest[slash + 1 ..];
    return std.mem.startsWith(u8, kind, "file/") or std.mem.startsWith(u8, kind, "doc/");
}

// ── Config ───────────────────────────────────────────────────────────

/// The active buffer's language key (`indentation.langOf` of its name),
/// copied out of the read scratch.
var lang_buf: [64]u8 = undefined;
fn langHere() []const u8 {
    const name = weft.path() orelse weft.designation() orelse return "";
    const plain = name[0 .. std.mem.indexOfScalar(u8, name, '?') orelse name.len];
    const lang = indentation.langOf(plain);
    if (lang.len > lang_buf.len) return "";
    @memcpy(lang_buf[0..lang.len], lang);
    return lang_buf[0..lang.len];
}

/// A switch: `<lang>.<name>` if config set it, else `<name>`, else on.
fn switchOn(comptime name: []const u8, lang: []const u8) bool {
    var key: [96]u8 = undefined;
    if (lang.len > 0) {
        if (std.fmt.bufPrint(&key, "{s}." ++ name, .{lang})) |k| {
            const v = weft.config(k);
            if (v.len > 0) return indentation.truthy(v);
        } else |_| {}
    }
    const v = weft.config(name);
    return v.len == 0 or indentation.truthy(v);
}

// ── The unit, per buffer ─────────────────────────────────────────────

/// Where the unit's style came from — what the status line's tooltip says.
const Source = enum {
    editorconfig,
    detected,
    language,
    default,
    builtin,
    set,

    fn describe(self: Source) []const u8 {
        return switch (self) {
            .editorconfig => "from .editorconfig",
            .detected => "detected from the file",
            .language => "the language's default",
            .default => "the configured default",
            .builtin => "the built-in default",
            .set => "set for this buffer",
        };
    }
};

const State = struct {
    key: u64 = 0,
    unit: Unit = Unit.builtin,
    source: Source = .builtin,
};

/// Per buffer, keyed by `entryKey`; reused round-robin, so a
/// buffer long out of use is worked out again when it comes back.
var states: [64]State = @splat(.{});
var next_state: usize = 0;

/// The active entry's key: its file's path, else its designation (a
/// document's id, a peer's file), so a file renamed is a new buffer to work
/// out. The path first: it reads the same from a command and from a status
/// line's ask. 0 for an entry with neither.
fn entryKey() u64 {
    const d = weft.path() orelse weft.designation() orelse return 0;
    return std.hash.Wyhash.hash(0x1d3a7, d) | 1;
}

/// The active buffer's unit, worked out the first time it is asked for. An
/// EMPTY buffer is not remembered: its file may still be loading, and a
/// fresh file says nothing until it has lines — so it is asked again.
fn unitHere() Unit {
    return (stateHere() orelse return compute(langHere()).unit).unit;
}

fn stateHere() ?*State {
    const key = entryKey();
    if (key == 0) return null;
    for (&states) |*s| if (s.key == key) return s;
    if (weft.byteLen() == 0) return null;
    const s = &states[next_state];
    next_state = (next_state + 1) % states.len;
    s.* = compute(langHere());
    s.key = key;
    return s;
}

fn compute(lang: []const u8) State {
    const from_ec = if (switchOn("editorconfig", lang)) editorconfigHere() else Partial{};
    const from_file = if (switchOn("detect", lang)) detectHere() else Partial{};
    const from_lang = if (lang.len > 0) indentation.parseSpec(weft.config(lang)) orelse Partial{} else Partial{};
    const from_default = indentation.parseSpec(weft.config("default")) orelse Partial{};
    const layers = [_]Partial{ from_ec, from_file, from_lang, from_default };
    const sources = [_]Source{ .editorconfig, .detected, .language, .default };
    var source: Source = .builtin;
    for (layers, sources) |l, s| if (l.tabs != null) {
        source = s;
        break;
    };
    return .{ .unit = indentation.resolve(&layers), .source = source };
}

/// The most of a file detection reads: indentation is decided in its first
/// few thousand lines or not at all.
const detect_limit = 1 << 18;

fn detectHere() Partial {
    var d: indentation.Detector = .{};
    const len = @min(weft.byteLen(), detect_limit);
    var pos: usize = 0;
    while (pos < len) {
        const chunk = weft.slice(pos, @min(len, pos + (1 << 16)));
        if (chunk.len == 0) break;
        // Whole lines only; the partial last one starts the next chunk. A
        // line longer than a chunk is skipped as a chunk of its own.
        const whole = if (pos + chunk.len >= len)
            chunk.len
        else if (std.mem.lastIndexOfScalar(u8, chunk, '\n')) |nl| nl + 1 else chunk.len;
        d.feed(chunk[0..whole]);
        pos += whole;
    }
    return d.result();
}

/// What the `.editorconfig` files over the active file say. Read only
/// inside the file's PLACE (its project), climbing from the file's directory
/// to the place's root or a `root = true`; each file is found by `placeHas`
/// first, so nothing outside the place — a symlink out of it included — is
/// ever asked for.
fn editorconfigHere() Partial {
    var path_buf: [1024]u8 = undefined;
    const path = copy(&path_buf, weft.path() orelse return .{}) orelse return .{};
    var root_buf: [1024]u8 = undefined;
    const root = copy(&root_buf, std.mem.trimEnd(u8, weft.placeRoot(), "/")) orelse return .{};
    if (root.len == 0 or path.len <= root.len + 1) return .{};
    if (!std.mem.startsWith(u8, path, root) or path[root.len] != '/') return .{};

    // Nearest first, to find where a `root = true` stops the climb: the
    // directories (prefixes of `path`, kept as lengths) holding one.
    const max_files = 16;
    var dirs: [max_files]usize = undefined;
    var n: usize = 0;
    var dir = path[0 .. std.mem.lastIndexOfScalar(u8, path, '/') orelse return .{}];
    while (n < max_files) {
        // `dir/.editorconfig`, relative to the place for the existence check.
        var rel_buf: [1024]u8 = undefined;
        const in_place = if (dir.len > root.len) dir[root.len + 1 ..] else "";
        const rel = (if (in_place.len > 0)
            std.fmt.bufPrint(&rel_buf, "{s}/.editorconfig", .{in_place})
        else
            std.fmt.bufPrint(&rel_buf, ".editorconfig", .{})) catch break;
        if (weft.placeHas(rel) == .file) {
            const text = readEditorconfig(dir) orelse break;
            dirs[n] = dir.len;
            n += 1;
            var preamble: editorconfig.Props = .{};
            if (editorconfig.apply(text, path[dir.len + 1 ..], &preamble)) break;
        }
        if (dir.len <= root.len) break;
        dir = dir[0 .. std.mem.lastIndexOfScalar(u8, dir, '/') orelse break];
    }
    // Then farthest first onto one set, so a nearer file overrides — its
    // `unset` included. Read again rather than held: each read borrows the
    // one read scratch, and a file is read once per buffer anyway.
    var props: editorconfig.Props = .{};
    var i = n;
    while (i > 0) {
        i -= 1;
        const d = path[0..dirs[i]];
        _ = editorconfig.apply(readEditorconfig(d) orelse continue, path[d.len + 1 ..], &props);
    }
    return props.partial();
}

fn readEditorconfig(dir: []const u8) ?[]const u8 {
    var abs_buf: [1024]u8 = undefined;
    const abs = std.fmt.bufPrint(&abs_buf, "{s}/.editorconfig", .{dir}) catch return null;
    return weft.fsRead(abs);
}

fn copy(buf: []u8, s: []const u8) ?[]const u8 {
    if (s.len > buf.len) return null;
    @memcpy(buf[0..s.len], s);
    return buf[0..s.len];
}

// ── The undo step an adjustment is ───────────────────────────────────

/// Whether an adjustment (the indent after a line break, an electric
/// dedent) may be its own undo step: where the grammar's mode makes a run of
/// one command a step (`run` — ide, emacs), so undo right after takes back
/// the adjustment and leaves the line break or the closer. Not where a mode
/// CONTINUES a step (vim's insert) or every command is one (`o` in vim's
/// normal, whose step goes on through the insert it opens), and not across
/// several carets, whose runs are one step by the mapping's own rule.
fn stepsApart() bool {
    if (weft.visitsLeft() != null) return false;
    const rule = weft.callString("mode.undo-step") orelse return false;
    return std.mem.eql(u8, rule, "run");
}

fn seal(apart: bool) void {
    if (apart) weft.run("edit.seal-undo");
}

// ── The auto-indent a blank line was left with ───────────────────────

/// The indent the last line break put on a line that holds nothing else —
/// anchored, so edits elsewhere carry it — and the buffer it is in. Taken
/// away again if the line is left blank (vim's `autoindent`): Return on it,
/// typing ending (leaving insert), or a line break made on another line.
const Pending = struct { key: u64, handle: u32 };
var pending: ?Pending = null;

/// While one is remembered, the typing hook also hears typing END (leaving
/// insert) — asked for here and withdrawn in `forget`, so leaving insert
/// costs nothing the rest of the time.
fn remember(at: usize, len: usize) void {
    forget();
    if (len == 0) return;
    const h = weft.anchorRange(.{ .start = at, .end = at + len }) orelse return;
    if (!weft.retainRange(h)) return weft.releaseRange(h);
    pending = .{ .key = entryKey(), .handle = h };
    weft.runStr2("input.on-typing-end", "indent.typed", "on");
}

fn forget() void {
    const p = pending orelse return;
    weft.releaseRange(p.handle);
    pending = null;
    weft.runStr2("input.on-typing-end", "indent.typed", "off");
}

/// Take a remembered auto-indent away if its line still holds nothing but
/// whitespace — unless the line is `keep` (the line a caller is about to act
/// on itself). Only in the buffer it was made in; elsewhere it waits.
fn tidy(keep: ?usize) void {
    const p = pending orelse return;
    if (p.key != entryKey()) return;
    const r = weft.rangeEnds(p.handle) orelse return forget();
    const l = weft.lineAt(r.start);
    if (keep) |k| if (l.start == k) return;
    forget();
    // Still the indent it was: at its line's start, not collapsed by the
    // line being deleted, and nothing else on the line.
    if (r.end <= r.start or l.start != r.start or l.end <= l.start) return;
    if (!indentation.allWs(weft.slice(l.start, l.end))) return;
    weft.edit(.{ .start = l.start, .end = l.end }, "");
}

// ── Return ───────────────────────────────────────────────────────────

var line_buf: [1 << 12]u8 = undefined;
var adjust_buf: [(1 << 12) * 2 + 2]u8 = undefined;
var opener_ws_buf: [1 << 12]u8 = undefined;

/// `edit.break-line` in a text file: the new line starts where it should.
/// Its indentation is the line's own, a step deeper after an opener (`{`,
/// `(`, `[` ending the text before the caret); a closer after the caret goes
/// to the indentation of the line that opened it — and between a pair
/// (`{|}`) the closer gets a line of its own and the caret an indented one
/// between. A blank line keeps its whitespace for the new line rather than
/// leaving it behind; a break inside the indentation opens a line above.
fn newline() void {
    const lang = langHere();
    if (!switchOn("auto", lang)) return weft.run("edit.insert-newline");
    tidy(weft.lineAt(weft.cursor()).start);

    const c = weft.cursor();
    const l = weft.lineAt(c);
    const line = copy(&line_buf, weft.slice(l.start, l.end)) orelse return weft.run("edit.insert-newline");
    const col = c - l.start;
    const before = line[0..col];
    const after = line[col..];
    const apart = stepsApart();

    if (indentation.allWs(before)) {
        if (indentation.allWs(after)) {
            // A blank line: it goes on blank (its whitespace leaves with the
            // break), and the new line takes the whitespace up.
            if (line.len == 0) return weft.run("edit.insert-newline");
            forget();
            weft.edit(.{ .start = l.start, .end = l.end }, "\n");
            seal(apart);
            weft.edit(.{ .start = l.start + 1, .end = l.start + 1 }, line);
            weft.jump(l.start + 1 + line.len);
            seal(apart);
            return remember(l.start + 1, line.len);
        }
        // Inside the indentation: a line opens above, the text keeps its place.
        weft.edit(.{ .start = l.start, .end = l.start }, "\n");
        return weft.jump(c + 1);
    }

    const unit = unitHere();
    const base = indentation.leadingWs(line);
    const skip = indentation.leadingWs(after).len; // the new indent stands in for it
    const rest = after[skip..];
    const opens = indentation.endsWithOpener(before);
    const closer: ?u8 = if (rest.len > 0 and indentation.isCloser(rest[0])) rest[0] else null;

    // The new line's indentation, built in `adjust_buf`.
    var len: usize = 0;
    if (opens) {
        len = append(&adjust_buf, len, base);
        var step: [indentation.max_width]u8 = undefined;
        len = append(&adjust_buf, len, unit.bytes(&step));
    } else if (closer) |cl| {
        len = append(&adjust_buf, len, openerIndent(c, cl) orelse base);
    } else {
        len = append(&adjust_buf, len, base);
    }
    const indent_len = len;
    // Between a pair, the closer's own line at the opener's indentation.
    if (opens and closer != null) {
        len = append(&adjust_buf, len, "\n");
        len = append(&adjust_buf, len, base);
    }

    weft.edit(.{ .start = c, .end = c + skip }, "\n");
    seal(apart);
    if (len > 0) weft.edit(.{ .start = c + 1, .end = c + 1 }, adjust_buf[0..len]);
    weft.jump(c + 1 + indent_len);
    seal(apart);
    if (rest.len == 0 or (opens and closer != null)) remember(c + 1, indent_len);
}

fn append(buf: []u8, at: usize, s: []const u8) usize {
    const n = @min(s.len, buf.len - at);
    @memcpy(buf[at..][0..n], s[0..n]);
    return at + n;
}

/// The indentation of the line holding the opener that a `closer` at
/// `offset` closes, or null when nothing open matches it.
fn openerIndent(offset: usize, closer: u8) ?[]const u8 {
    const from = offset -| (1 << 16);
    const at = from + (indentation.matchOpener(weft.slice(from, offset), closer) orelse return null);
    const ol = weft.lineAt(at);
    const ws = indentation.leadingWs(weft.slice(ol.start, ol.end));
    return copy(&opener_ws_buf, ws);
}

// ── Typing ───────────────────────────────────────────────────────────

/// The closers whose typing re-indents their line (`input.on-typing`'s
/// filter): the language-agnostic bracket set Return reads too.
const electric_chars = "})]";

/// The typing hook: a closer was typed — or typing ended (`""`).
fn typed() void {
    const text = weft.argStr(0) orelse return;
    if (text.len == 0) return tidy(null);
    if (!textFileHere()) return;
    if (text.len != 1 or !indentation.isCloser(text[0])) return;
    if (!switchOn("electric", langHere())) return;
    electric(text[0]);
}

/// Re-indent the line of a closer just typed (or stepped over) when it is
/// the first thing on the line: to the indentation of the line that opened
/// it.
fn electric(closer: u8) void {
    const pos = weft.cursor();
    if (pos == 0) return;
    const at = pos - 1;
    const here = weft.slice(at, pos);
    if (here.len != 1 or here[0] != closer) return;
    const l = weft.lineAt(at);
    if (!indentation.allWs(weft.slice(l.start, at))) return;
    const have = at - l.start;
    const want = openerIndent(at, closer) orelse return;
    if (have == want.len and std.mem.eql(u8, weft.slice(l.start, at), want)) return;
    forget();
    const apart = stepsApart();
    seal(apart);
    weft.edit(.{ .start = l.start, .end = at }, want);
    weft.jump(l.start + want.len + 1);
    seal(apart);
}

// ── Tab and Backspace ────────────────────────────────────────────────

fn hasSelection() bool {
    const r = weft.selection() orelse return false;
    return r.end > r.start;
}

/// `edit.tab` in a text file: one step — a tab, or spaces to the next stop.
fn tab() void {
    if (hasSelection()) return weft.run("edit.insert-tab");
    const unit = unitHere();
    const c = weft.cursor();
    if (unit.tabs) {
        weft.edit(.{ .start = c, .end = c }, "\t");
        return weft.jump(c + 1);
    }
    const l = weft.lineAt(c);
    const n = indentation.spacesToStop(indentation.column(weft.slice(l.start, c), unit.width), unit.width);
    const spaces = "                ";
    weft.edit(.{ .start = c, .end = c }, spaces[0..@min(n, spaces.len)]);
    weft.jump(c + @min(n, spaces.len));
}

/// `edit.backspace` in a text file: in a spaces file's indentation, back to
/// the previous stop — the step an auto-indent or a Tab put there, in one.
fn backspace() void {
    const c = weft.cursor();
    if (hasSelection() or !switchOn("backspace", langHere())) return weft.run("edit.delete-before");
    const unit = unitHere();
    if (unit.tabs) return weft.run("edit.delete-before");
    const l = weft.lineAt(c);
    const n = indentation.spacesToPrevStop(weft.slice(l.start, c), unit.width) orelse
        return weft.run("edit.delete-before");
    weft.edit(.{ .start = c - n, .end = c }, "");
    weft.jump(c - n);
}

// ── The operators ────────────────────────────────────────────────────

/// Line starts of the spanned lines; a fixed cap (huge spans truncate).
var starts: [1 << 12]usize = undefined;

/// Collect the start of each line `[start, end)` touches; returns the count.
fn collect(start: usize, end: usize) usize {
    var count: usize = 0;
    var off = start;
    while (count < starts.len) {
        const l = weft.lineAt(off);
        starts[count] = l.start;
        count += 1;
        const next = l.end + 1; // start of the following line (past the newline)
        if (next >= end or next <= off) break; // reached / passed the end, or EOF
        off = next;
    }
    return count;
}

/// Add or peel one step on every line the span touches. Bottom-up, so each
/// edit sits below the lines still to come and never shifts their starts.
fn indentSpan(start: usize, end: usize, dedent: bool) void {
    const unit = unitHere();
    var step_buf: [indentation.max_width]u8 = undefined;
    const step = unit.bytes(&step_buf);
    var k = collect(start, end);
    while (k > 0) {
        k -= 1;
        const l = weft.lineAt(starts[k]);
        const text = weft.slice(l.start, l.end); // borrows scratch; used before any next read
        if (dedent) {
            // Peel leading spaces up to a step's width, or one leading tab.
            var rl: usize = 0;
            while (rl < unit.width and rl < text.len and text[rl] == ' ') rl += 1;
            if (rl == 0 and text.len > 0 and text[0] == '\t') rl = 1;
            if (rl > 0) weft.edit(.{ .start = l.start, .end = l.start + rl }, "");
        } else {
            if (indentation.allWs(text)) continue; // vim's `>`: no indent left dangling on empty rows
            weft.edit(.{ .start = l.start, .end = l.start }, step);
        }
    }
}

/// The `>` operator: indent the awaited range's lines. Composes with every motion
/// and text object (`>ip`, `>j`) and — via vim.operate-line — `>>` on the current line.
fn opIndent() void {
    const h = weft.argRange(0) orelse return;
    const r = weft.rangeEnds(h) orelse return;
    indentSpan(r.start, r.end, false);
}
/// The `<` operator: dedent the awaited range's lines.
fn opDedent() void {
    const h = weft.argRange(0) orelse return;
    const r = weft.rangeEnds(h) orelse return;
    indentSpan(r.start, r.end, true);
}

// ── Changing it ──────────────────────────────────────────────────────

fn say(comptime fmt: []const u8, args: anytype) void {
    var buf: [128]u8 = undefined;
    weft.echo(std.fmt.bufPrint(&buf, fmt, args) catch return);
}

fn describe(u: Unit, out: []u8) []const u8 {
    return if (u.tabs)
        "tabs"
    else
        std.fmt.bufPrint(out, "{d} spaces", .{u.width}) catch "spaces";
}

/// The buffer's state, worked out now if it never was — even for an empty
/// buffer, since a person setting it means it.
fn stateForChange() ?*State {
    if (stateHere()) |s| return s;
    const key = entryKey();
    if (key == 0) return null;
    const s = &states[next_state];
    next_state = (next_state + 1) % states.len;
    s.* = compute(langHere());
    s.key = key;
    return s;
}

/// Say what changed: on the echo line, and as the entry's `indent.unit`
/// context value (`tabs`, `spaces:4`) — which is also what tells the status
/// line its answer is stale (a pane's segments are asked again when its
/// facts move), and what another plugin reads to indent as this buffer does.
fn changed(s: *const State) void {
    var buf: [24]u8 = undefined;
    say("indent: {s}, {s}", .{ describe(s.unit, &buf), s.source.describe() });
    var value: [16]u8 = undefined;
    const v = if (s.unit.tabs) "tabs" else std.fmt.bufPrint(&value, "spaces:{d}", .{s.unit.width}) catch return;
    weft.contextSet("indent.unit", v, .entry) catch {};
}

/// `indent.set <unit>`: `tabs`, `spaces`, `spaces:2`, `4`. A half left
/// unsaid keeps what the buffer had.
fn set() void {
    const spec = weft.argStr(0) orelse return weft.echo("indent: say tabs, spaces, spaces:2, or a width");
    const p = indentation.parseSpec(spec) orelse return say("indent: '{s}' is not tabs, spaces, spaces:N, or a width", .{spec});
    const s = stateForChange() orelse return weft.echo("indent: this entry holds no file");
    s.unit = indentation.resolve(&.{ p, .{ .tabs = s.unit.tabs, .width = s.unit.width } });
    s.source = .set;
    changed(s);
}

fn toggleTabs() void {
    const s = stateForChange() orelse return weft.echo("indent: this entry holds no file");
    s.unit.tabs = !s.unit.tabs;
    s.source = .set;
    changed(s);
}

fn redetect() void {
    const s = stateForChange() orelse return weft.echo("indent: this entry holds no file");
    const key = s.key;
    s.* = compute(langHere());
    s.key = key;
    changed(s);
}

// ── The status line (doc/chrome.md §4.3) ─────────────────────────────

fn init() void {
    // After the position and the selection count (45, 44), before the
    // language (40).
    statusline.bind(text_files, .core, 43);
    weft.provide("edit.break-line", text_files, "indent.newline", 0);
    weft.provide("edit.tab", text_files, "indent.tab", 0);
    weft.provide("edit.backspace", text_files, "indent.backspace", 0);
    weft.runStr2("input.on-typing", "indent.typed", electric_chars);
}

var full: [48]u8 = undefined;
var short: [8]u8 = undefined;
var tip: [96]u8 = undefined;

fn onSlotFire(session: i32) callconv(.c) void {
    const handle: u32 = @bitCast(session);
    const q = statusline.ask(handle) orelse return;
    // The document doors read the focused pane's entry, so only it is told.
    if (!q.focused) return statusline.tell(handle, &.{});
    const s = stateHere();
    const unit = if (s) |st| st.unit else compute(langHere()).unit;
    const source: Source = if (s) |st| st.source else .builtin;
    statusline.tell(handle, &.{.{
        .text = if (unit.tabs) "Tabs" else std.fmt.bufPrint(&full, "Spaces: {d}", .{unit.width}) catch "Spaces",
        .compact = if (unit.tabs) "tab" else std.fmt.bufPrint(&short, "sp{d}", .{unit.width}) catch "",
        .role = .muted,
        .right = true,
        .priority = 30,
        .command = "indent.toggle-tabs",
        .tooltip = std.fmt.bufPrint(&tip, "Indentation: {s}. Click to switch tabs and spaces.", .{source.describe()}) catch "Indentation",
    }});
}

comptime {
    weft.plugin(&cmds, .{ .init = init, .perms = &.{.fs_read} }).exportAll();
    weft.exportCallback("on_slot_fire", &onSlotFire);
}
