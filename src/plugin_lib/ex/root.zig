//! ex — a real vim/helix `:` command line. What is left here after the
//! minibuffer moved out is the PART THAT IS ABOUT EX: the parser, with the
//! composition design — vim OWNS the classic abbreviated commands (w/q/wq/x/e/s
//! + ranges + `!`, :N goto, :noh) with vim semantics; EVERYTHING ELSE falls
//! THROUGH to the weft command registry, so `:name arg…` runs the command
//! `name`. Any plugin command (`:git-status`, `:grep foo`, `:sort`) is
//! ex-callable with zero integration: plugins compose by registering ordinary
//! commands.
//!
//! The line EDITING is `weft_prompt` — the same minibuffer git's branch names
//! and lsp's renames go through, so "how do I get out of this" has one answer
//! everywhere. This module used to own a private copy of it; that copy is why
//! there were three.
//!
//! The fall-through half is `weft_invoke` for the same reason. It used to
//! split a line into "first token, then the rest" and hope that matched the
//! command's arity — so `:listen 7777` (a two-argument command given one) did
//! nothing at all, silently, and `:listen` with nothing did the same. Asking
//! the registry what a command TAKES answers both: the split follows the
//! declared arity, and what is still missing is asked for. That is also where
//! the `:` line's signature help comes from — `cfg.hint` below trails the
//! typed line with the parameters it has not supplied yet.
//!
//! Instantiated per editor with its own mode names (`Ex("normal","ex")` for vim,
//! `Ex("helix-normal","helix-ex")` for helix). Each guest is a separate wasm
//! module, so the module-level scratch below never crosses editors.

const std = @import("std");
const weft = @import("weft");
const prompt = @import("weft_prompt");
const invoke = @import("weft_invoke");

// ── Caps (bounded; degrade + echo on overflow, never overrun) ──────────────
const LINE_CAP = 1024; // the typed command line
const SUB_CAP = 1 << 17; // 128 KiB per side of a substitute region
const PAT_CAP = 1024; // a substitute pattern / replacement

var sub_in: [SUB_CAP]u8 = undefined; // the region text, paged in via `slice`
var sub_out: [SUB_CAP]u8 = undefined; // the transformed region
var pat_buf: [PAT_CAP]u8 = undefined;
var rep_buf: [PAT_CAP]u8 = undefined;
var msg_buf: [256]u8 = undefined;

fn echoFmt(comptime fmt: []const u8, args: anytype) void {
    weft.echo(std.fmt.bufPrint(&msg_buf, fmt, args) catch return);
}

// ── The command line: a prompt, plus what to do with the line ──────────────
/// A `:` command line for an editor whose resting mode is `normal_mode` and
/// whose command-line keymap mode is `ex_mode`.
///
/// The whole minibuffer half is `prompt.Prompt` now — `:` is a prompt whose
/// label is ":" and whose accept handler is `exec`. Every key that gets you
/// out of it is the one that gets you out of any other prompt in the editor,
/// because there is only one implementation left to disagree with.
pub fn Ex(comptime normal_mode: []const u8, comptime ex_mode: []const u8) type {
    return struct {
        const Self = @This();

        /// Arguments a typed line left out are asked for here, one question
        /// per parameter, in the same minibuffer. `:listen` is therefore a
        /// legal thing to type — it becomes "port?", "access?", run — rather
        /// than a silent arity refusal.
        pub const asker = invoke.Invoker(.{
            .name = ex_mode ++ "-arg",
            .resting = normal_mode,
        });

        pub const line = prompt.Prompt(.{
            .name = ex_mode,
            .resting = normal_mode,
            .capacity = LINE_CAP,
            .on_accept = struct {
                fn accept(text: []const u8) void {
                    if (text.len > 0) exec(text);
                }
            }.accept,
            // Signature help, straight off the registry: what the command
            // being typed still wants. Words ex OWNS (`w`, `q`, `s/…/…/`, a
            // bare line number) are not registered command names, so the
            // registry simply has nothing to say about them — no keyword list
            // to keep in step with `builtin` below.
            .hint = struct {
                fn f(text: []const u8) []const u8 {
                    return asker.hint(text);
                }
            }.f,
        });

        /// The commands this command line answers to, for a guest's table:
        /// the line's own five, then the argument prompt's five.
        pub const commands = line.commands ++ asker.commands;

        /// `:` in normal — open the command line, empty.
        pub fn enter() void {
            line.open(":");
        }

        /// Dispatch a trimmed, non-empty ex line (see `execWith`).
        pub fn exec(text: []const u8) void {
            execWith(asker, text);
        }

        pub fn declare() void {
            line.declare();
            asker.declare();
        }
        pub fn install() void {
            line.install();
            asker.install();
        }
    };
}

// ── The parser: builtin ex table first, else fall through to the registry ──
const LineRange = struct { lo: usize, hi: usize };

/// Dispatch a trimmed, non-empty ex line. Parse order (the composition):
/// range → bare goto → substitute → builtin keyword → fall-through to the
/// registry, through `Asker` (which knows how to ask for what is missing).
fn execWith(comptime Asker: type, line: []const u8) void {
    var rest = line;
    const range = parseRange(&rest);
    rest = trimLeft(rest);

    // A range (or bare number) with no command ⇒ goto that line (:42, :$).
    if (rest.len == 0) {
        if (range) |rg| gotoLine(rg.hi);
        return;
    }

    // The leading alpha run is the candidate builtin keyword (`s`, `wq`, `noh`…).
    // A command NAME can contain hyphens (`git-status`), so the keyword only
    // matches a builtin when it is the WHOLE first token; otherwise fall through.
    const al = alphaLen(rest);
    const kw = rest[0..al];
    const tail = rest[al..];

    // Substitute owns the rest of the line (patterns may contain spaces): the
    // char right after `s`/`su`/`substitute` is the delimiter.
    if (tail.len > 0 and isDelim(tail[0]) and eqAny(kw, &.{ "s", "su", "sub", "subs", "substitute" })) {
        substitute(range, tail);
        return;
    }

    // A trailing `!` is vim's "force"; args are whatever follows.
    var a = tail;
    const bang = a.len > 0 and a[0] == '!';
    if (bang) a = a[1..];
    const args = trimLeft(a);

    // Builtins only when the keyword IS the first token (next is end/!/space).
    const kw_is_token = tail.len == 0 or tail[0] == '!' or isSpace(tail[0]);
    if (kw_is_token and builtin(kw, bang, args)) return;

    // Fall-through: `:name arg…` → the weft command `name`, split against
    // what it declares and asked for where it is short.
    Asker.invokeLine(rest);
}

/// The vim-owned classic commands. Returns true if `kw` matched (and ran).
fn builtin(kw: []const u8, bang: bool, args: []const u8) bool {
    if (eqAny(kw, &.{ "w", "wr", "write" })) {
        if (args.len > 0) weft.runStr("save-as", args) else weft.run("save");
        return true;
    }
    // wa/wall save the buffer (weft's save is the active buffer only — see note).
    if (eqAny(kw, &.{ "wa", "wall" })) {
        weft.run("save");
        return true;
    }
    if (eqAny(kw, &.{ "wq", "x", "xit", "wqa", "wqall", "xa", "xall" })) {
        if (args.len > 0) weft.runStr("save-as", args) else weft.run("save");
        weft.run("quit");
        return true;
    }
    if (eqAny(kw, &.{ "q", "quit", "qa", "qall", "quita", "quitall" })) {
        weft.run("quit");
        return true;
    }
    if (eqAny(kw, &.{ "e", "ed", "edit", "o", "op", "open" })) {
        _ = bang;
        if (args.len > 0) {
            weft.runStr("open", args);
            return true;
        }
        // Revert is ASKED FOR, never tested for: whatever holds the focus
        // owns its own revert semantics and answers `unavailable` when it
        // has none, so ex needs no notion of entry kinds at all.
        switch (weft.semanticAction(weft.semantic.action.standard.revert)) {
            .handled, .transfer_stored, .interaction_opened, .target_opened, .focus_changed, .relation_opened, .working_target_changed => {},
            .unavailable => weft.echo("e: nothing here reverts"),
            .failed, _ => weft.echo("e: revert refused"),
        }
        return true;
    }
    if (eqAny(kw, &.{ "clo", "close" })) {
        weft.run("window-close");
        return true;
    }
    if (eqAny(kw, &.{ "bd", "bdel", "bdelete" })) {
        weft.run("buffer-close");
        return true;
    }
    if (eqAny(kw, &.{ "sp", "spl", "split", "new", "hsp", "hsplit" })) {
        weft.run("window-split");
        return true;
    }
    if (eqAny(kw, &.{ "vs", "vsp", "vsplit", "vnew" })) {
        weft.run("window-vsplit");
        return true;
    }
    // No hlsearch in core: clear the selection (the nearest visual analogue).
    if (eqAny(kw, &.{ "noh", "nohl", "nohlsearch" })) {
        weft.run("clear-selection");
        weft.echo("noh");
        return true;
    }
    return false;
}

// ── Ranges + line arithmetic (a full buffer scan; a user-initiated action) ──
/// Parse an optional leading range, consuming it from `rest`. `%` = whole file;
/// an address (`.`/`$`/N with ±N) optionally `,`/`;` a second address.
fn parseRange(rest: *[]const u8) ?LineRange {
    var s = rest.*;
    if (s.len > 0 and s[0] == '%') {
        rest.* = s[1..];
        return .{ .lo = 1, .hi = lastLine() };
    }
    const lo = parseAddr(&s) orelse return null;
    var hi = lo;
    if (s.len > 0 and (s[0] == ',' or s[0] == ';')) {
        s = s[1..];
        hi = parseAddr(&s) orelse lo;
    }
    rest.* = s;
    return .{ .lo = lo, .hi = hi };
}

/// One address: `.` (current), `$` (last), or a 1-based number, each with an
/// optional `+N`/`-N` tail. Null when `s` doesn't start with an address.
fn parseAddr(s: *[]const u8) ?usize {
    var v = s.*;
    if (v.len == 0) return null;
    var line: usize = undefined;
    switch (v[0]) {
        '.' => {
            line = currentLine();
            v = v[1..];
        },
        '$' => {
            line = lastLine();
            v = v[1..];
        },
        '0'...'9' => {
            var n: usize = 0;
            while (v.len > 0 and isDigit(v[0])) : (v = v[1..]) n = n * 10 + (v[0] - '0');
            line = n;
        },
        else => return null,
    }
    while (v.len > 0 and (v[0] == '+' or v[0] == '-')) {
        const neg = v[0] == '-';
        v = v[1..];
        var m: usize = 0;
        var got = false;
        while (v.len > 0 and isDigit(v[0])) : (v = v[1..]) {
            m = m * 10 + (v[0] - '0');
            got = true;
        }
        if (!got) m = 1;
        line = if (neg) (if (line > m) line - m else 1) else line + m;
    }
    s.* = v;
    return line;
}

fn newlinesIn(from: usize, to: usize) usize {
    var count: usize = 0;
    var pos = from;
    while (pos < to) {
        const chunk = weft.slice(pos, to); // ≤ 64 KiB into shared scratch
        if (chunk.len == 0) break;
        for (chunk) |c| {
            if (c == '\n') count += 1;
        }
        pos += chunk.len;
    }
    return count;
}
fn currentLine() usize {
    return newlinesIn(0, weft.cursor()) + 1;
}
fn lastLine() usize {
    return newlinesIn(0, weft.byteLen()) + 1;
}

/// Byte offset of the start of 1-based line `n` (clamped to EOF).
fn lineStartOffset(n: usize) usize {
    if (n <= 1) return 0;
    var need = n - 1; // newlines to pass
    const total = weft.byteLen();
    var pos: usize = 0;
    while (pos < total) {
        const chunk = weft.slice(pos, total);
        if (chunk.len == 0) break;
        for (chunk, 0..) |c, k| {
            if (c == '\n') {
                need -= 1;
                if (need == 0) return pos + k + 1;
            }
        }
        pos += chunk.len;
    }
    return total;
}
fn lineEndOffset(n: usize) usize {
    return weft.lineAt(lineStartOffset(n)).end;
}

/// `:N` — place the cursor at the start of line N.
fn gotoLine(n: usize) void {
    weft.jump(lineStartOffset(n));
}

// ── Substitute: `:[range]s/pat/rep/flags` (literal patterns) ───────────────
/// `spec` starts with the delimiter. Read pat/rep (respecting `\<delim>`), the
/// flags (`g` = every match per line vs the first), then transform the line
/// region and land it as ONE user edit (single undo unit).
fn substitute(range: ?LineRange, spec: []const u8) void {
    const delim = spec[0];
    var i: usize = 1;
    const pat = readField(spec, &i, delim, &pat_buf);
    const rep = readField(spec, &i, delim, &rep_buf);
    const flags = spec[i..];
    const global = std.mem.indexOfScalar(u8, flags, 'g') != null;

    if (pat.len == 0) {
        weft.echo("substitute: empty pattern");
        return;
    }

    const last = lastLine();
    var lo = if (range) |rg| rg.lo else currentLine();
    var hi = if (range) |rg| rg.hi else currentLine();
    if (lo < 1) lo = 1;
    if (hi > last) hi = last;
    if (lo > hi) {
        weft.echo("substitute: empty range");
        return;
    }

    const region_start = lineStartOffset(lo);
    const region_end = lineEndOffset(hi);
    const region = loadRegion(region_start, region_end) orelse return;

    // Transform line-by-line into sub_out (verbatim newlines between lines).
    var ow: usize = 0;
    var subs: usize = 0;
    var li: usize = 0;
    while (li < region.len) {
        var le = li;
        while (le < region.len and region[le] != '\n') le += 1;
        if (!subLine(region[li..le], pat, rep, global, &ow, &subs)) return; // overflow
        if (le < region.len) {
            if (ow >= sub_out.len) return overflow();
            sub_out[ow] = '\n';
            ow += 1;
        }
        li = le + 1;
    }

    if (subs == 0) {
        echoFmt("pattern not found: {s}", .{pat});
        return;
    }
    weft.edit(.{ .start = region_start, .end = region_end }, sub_out[0..ow]);
    echoFmt("{d} substitution(s)", .{subs});
}

/// Replace matches of `pat` in one `line` into `sub_out`. Returns false (and
/// echoes) on output overflow — the caller then abandons the edit untouched.
fn subLine(line: []const u8, pat: []const u8, rep: []const u8, global: bool, ow: *usize, subs: *usize) bool {
    var li: usize = 0;
    while (li < line.len) {
        if (std.mem.startsWith(u8, line[li..], pat)) {
            if (!appendRep(rep, pat, ow)) return false;
            li += pat.len;
            subs.* += 1;
            if (!global) {
                // Copy the rest of the line verbatim and stop (first-match only).
                if (ow.* + (line.len - li) > sub_out.len) return overflowFalse();
                @memcpy(sub_out[ow.* .. ow.* + (line.len - li)], line[li..]);
                ow.* += line.len - li;
                return true;
            }
        } else {
            if (ow.* >= sub_out.len) return overflowFalse();
            sub_out[ow.*] = line[li];
            ow.* += 1;
            li += 1;
        }
    }
    return true;
}

/// Emit the replacement, expanding `&` → the matched text (== pat, literal) and
/// `\&` → a literal `&`. Other backslashes pass through (no regex backrefs).
fn appendRep(rep: []const u8, matched: []const u8, ow: *usize) bool {
    var i: usize = 0;
    while (i < rep.len) {
        if (rep[i] == '&') {
            if (ow.* + matched.len > sub_out.len) return overflowFalse();
            @memcpy(sub_out[ow.* .. ow.* + matched.len], matched);
            ow.* += matched.len;
            i += 1;
        } else if (rep[i] == '\\' and i + 1 < rep.len and rep[i + 1] == '&') {
            if (ow.* >= sub_out.len) return overflowFalse();
            sub_out[ow.*] = '&';
            ow.* += 1;
            i += 2;
        } else {
            if (ow.* >= sub_out.len) return overflowFalse();
            sub_out[ow.*] = rep[i];
            ow.* += 1;
            i += 1;
        }
    }
    return true;
}

fn overflow() void {
    weft.echo("substitute: result too large (>128 KiB) — aborted");
}
fn overflowFalse() bool {
    overflow();
    return false;
}

/// Page `[start,end)` of the buffer into `sub_in`. Null (with an echo) if the
/// region is larger than the cap.
fn loadRegion(start: usize, end: usize) ?[]const u8 {
    if (end <= start) return sub_in[0..0];
    if (end - start > SUB_CAP) {
        weft.echo("substitute: region too large (>128 KiB)");
        return null;
    }
    var got: usize = 0;
    var pos = start;
    while (pos < end and got < SUB_CAP) {
        const chunk = weft.slice(pos, end);
        if (chunk.len == 0) break;
        const m = @min(chunk.len, SUB_CAP - got);
        @memcpy(sub_in[got .. got + m], chunk[0..m]);
        got += m;
        pos += m;
        if (m < chunk.len) break;
    }
    return sub_in[0..got];
}

/// Read one delimiter-terminated field into `out`, unescaping `\<delim>` to a
/// literal delimiter. Advances `i` past the closing delimiter (or to the end).
fn readField(spec: []const u8, i: *usize, delim: u8, out: *[PAT_CAP]u8) []const u8 {
    var w: usize = 0;
    while (i.* < spec.len) {
        const c = spec[i.*];
        if (c == '\\' and i.* + 1 < spec.len and spec[i.* + 1] == delim) {
            if (w < out.len) out[w] = delim;
            w += 1;
            i.* += 2;
            continue;
        }
        if (c == delim) {
            i.* += 1;
            break;
        }
        if (w < out.len) out[w] = c;
        w += 1;
        i.* += 1;
    }
    return out[0..@min(w, out.len)];
}

// ── Small char/string helpers ──────────────────────────────────────────────
fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}
fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t';
}
fn isAlpha(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z');
}
/// A substitute delimiter: any printable that isn't alphanumeric, space, or `\`.
fn isDelim(c: u8) bool {
    return c > 0x20 and !isAlpha(c) and !isDigit(c) and c != '\\';
}
fn alphaLen(s: []const u8) usize {
    var i: usize = 0;
    while (i < s.len and isAlpha(s[i])) i += 1;
    return i;
}
fn trimLeft(s: []const u8) []const u8 {
    var i: usize = 0;
    while (i < s.len and isSpace(s[i])) i += 1;
    return s[i..];
}
fn eqAny(kw: []const u8, comptime list: []const []const u8) bool {
    inline for (list) |w| {
        if (std.mem.eql(u8, kw, w)) return true;
    }
    return false;
}
