//! Regex over the selections, and search (doc/configs.md §2 phase 4).
//!
//! `s S K A-K` reshape the selection set by a pattern: select every match
//! inside each selection, split each on the matches, keep or drop each
//! selection by whether it matches. `/ ? n N` search the document and put
//! the match in place of the primary selection — or, in select mode, add it
//! beside the others. `*` and `A-*` make the primary's text the pattern.
//!
//! The query language is the `search` library's, the same one the find bar
//! speaks: a regex, smart case (a capital in the pattern makes it case
//! sensitive), `^`/`$` at line edges. The prompt previews as you type — the
//! selections ARE the preview — and Escape puts back the set it started from.
//!
//! The last pattern lives in core's `/` register (`weft.register_search`),
//! not here: `n` reads it back, and so can any other grammar (vim's `"/p`).

const std = @import("std");
const weft = @import("weft");
const search = @import("weft_search");
const prompt_mod = @import("weft_prompt");
const sel = @import("selection.zig");
const text = @import("text.zig");
const state = @import("state.zig");

const gpa = weft.allocator;
const max = sel.max;
const Sel = sel.Sel;

/// Helix's search is a regex with smart case, always.
const options: search.Options = .{ .regex = true, .case = .smart };

/// What the open prompt does with its pattern.
pub const Op = enum {
    /// `s`: select the matches inside each selection.
    select,
    /// `S`: split each selection on the matches.
    split,
    /// `K`: keep the selections that match.
    keep,
    /// `A-K`: drop the selections that match.
    remove,
    /// `/`: the next match after the primary.
    search_forward,
    /// `?`: the match before the primary.
    search_backward,

    fn label(self: Op) []const u8 {
        return switch (self) {
            .select => "select: ",
            .split => "split: ",
            .keep => "keep: ",
            .remove => "remove: ",
            .search_forward => "search: ",
            .search_backward => "rsearch: ",
        };
    }
};

/// The one prompt every op shares; `op` says what it is for.
pub const prompt = prompt_mod.Prompt(.{
    .name = "helix-regex",
    .on_accept = accept,
    .on_cancel = cancel,
    .on_change = preview,
    // A pattern's blanks are pattern: `S` then a space splits on spaces.
    .trim = false,
});

var op: Op = .select;
/// Search mode: `extend` adds the match as a new selection (select mode).
var how: sel.Mode = .move;
/// The set the prompt opened on — what every preview starts from, and what
/// Escape restores.
var base: [max]Sel = undefined;
var base_n: usize = 0;
var base_primary: usize = 0;

// ── The document, read once per operation ───────────────────────────────

var doc: std.ArrayList(u8) = .empty;

/// The whole document, for a search (the match list spans all of it). A
/// prompt reads it once when it opens: typing into the prompt edits nothing.
fn readDoc() []const u8 {
    doc.clearRetainingCapacity();
    const len = weft.byteLen();
    doc.ensureTotalCapacity(gpa, len) catch return doc.items;
    var at: usize = 0;
    while (at < len) {
        const bytes = weft.slice(at, @min(len, at + (1 << 16)));
        if (bytes.len == 0) break;
        doc.appendSliceAssumeCapacity(bytes);
        at += bytes.len;
    }
    return doc.items;
}

fn compile(pattern: []const u8) ?search.Matcher {
    return search.Matcher.init(gpa, pattern, options) catch null;
}

/// Say why `pattern` does not compile (an empty one says nothing).
fn complain(pattern: []const u8) void {
    var m = search.Matcher.init(gpa, pattern, options) catch |err| {
        if (err == error.EmptyPattern) return;
        var buf: [96]u8 = undefined;
        return weft.echo(std.fmt.bufPrint(&buf, "invalid regex: {s}", .{search.describe(err)}) catch "invalid regex");
    };
    m.deinit();
}

// ── The prompt ──────────────────────────────────────────────────────────

/// Open the prompt for `o`, remembering the set it starts from.
pub fn open(o: Op, mode: sel.Mode) void {
    if (!sel.load()) return;
    op = o;
    how = mode;
    base_n = sel.n;
    base_primary = sel.primary;
    @memcpy(base[0..base_n], sel.items[0..sel.n]);
    _ = readDoc();
    prompt.open(o.label());
}

fn restore() void {
    if (base_n == 0) return;
    _ = weft.setSelections(base[0..base_n], base_primary);
}

/// Every keystroke: recompute from the base set. A pattern that does not
/// compile (yet — `(` on its way to `(a)`) shows the base set.
fn preview(line: []const u8) void {
    var m = compile(line) orelse return restore();
    defer m.deinit();
    if (!apply(&m, false)) restore();
}

fn accept(line: []const u8) void {
    if (how == .extend) weft.setMode("helix-select");
    var m = compile(line) orelse {
        restore();
        return complain(line);
    };
    defer m.deinit();
    if (op == .search_forward or op == .search_backward) weft.registerSet(weft.register_search, line);
    if (!apply(&m, true)) restore();
}

fn cancel() void {
    if (how == .extend) weft.setMode("helix-select");
    restore();
}

/// Run the open op over the base set. False when it came to nothing — the
/// caller shows the base set instead (a final run also says why).
fn apply(m: *search.Matcher, final: bool) bool {
    return switch (op) {
        .select, .split => reshape(m, op == .split, final),
        .keep, .remove => filter(m, op == .keep, final),
        .search_forward, .search_backward => step(m, doc.items, op == .search_forward, base[0..base_n], base_primary, final),
    };
}

// ── s / S ───────────────────────────────────────────────────────────────

var out: [max]Sel = undefined;

/// `s`: every match inside each selection becomes a selection. `S`: the
/// pieces between the matches do (an empty piece is dropped — it covers
/// nothing). The first selection a base selection yields inherits its
/// primacy.
fn reshape(m: *search.Matcher, split: bool, final: bool) bool {
    var k: usize = 0;
    var new_primary: usize = 0;
    for (base[0..base_n], 0..) |s, i| {
        const r = sel.span(s);
        if (r.end > doc.items.len) continue;
        const frag = doc.items[r.start..r.end];
        if (i == base_primary) new_primary = k;
        var at: usize = 0;
        var from = r.start;
        while (k < max) {
            const hit = m.next(frag, at) orelse break;
            if (split) {
                if (r.start + hit.start > from) {
                    out[k] = .{ .anchor = from, .head = r.start + hit.start };
                    k += 1;
                }
                from = r.start + hit.end;
            } else {
                out[k] = .{ .anchor = r.start + hit.start, .head = r.start + hit.end };
                k += 1;
            }
            at = hit.end;
        }
        if (split and from < r.end and k < max) {
            out[k] = .{ .anchor = from, .head = r.end };
            k += 1;
        }
    }
    if (k == 0) {
        if (final) weft.echo("nothing selected");
        return false;
    }
    _ = weft.setSelections(out[0..k], @min(new_primary, k - 1));
    return true;
}

// ── K / A-K ─────────────────────────────────────────────────────────────

/// Keep (or drop) each selection whose text matches anywhere — an empty
/// match counts, so `K` with `^` keeps everything.
fn filter(m: *search.Matcher, keep: bool, final: bool) bool {
    var k: usize = 0;
    var new_primary: usize = 0;
    for (base[0..base_n], 0..) |s, i| {
        const r = sel.span(s);
        if (r.end > doc.items.len) continue;
        const matched = m.re.find(doc.items[r.start..r.end], 0) != null;
        if (matched != keep) continue;
        if (i <= base_primary) new_primary = k;
        out[k] = s;
        k += 1;
    }
    if (k == 0) {
        if (final) weft.echo("no selections remaining");
        return false;
    }
    _ = weft.setSelections(out[0..k], new_primary);
    return true;
}

// ── / ? n N ─────────────────────────────────────────────────────────────

var matches: std.ArrayList(search.Span) = .empty;

/// One search step from `set`'s primary over `hay`: the first match past its
/// end (forward) or the last before its start (backward), wrapping around
/// the document. `move` puts the match in place of the primary; `extend`
/// adds it as a new selection — both make it the primary.
fn step(m: *search.Matcher, hay: []const u8, forward: bool, set: []const Sel, primary: usize, final: bool) bool {
    _ = m.collect(gpa, hay, &matches, 1 << 18) catch return false;
    if (matches.items.len == 0) {
        if (final) weft.echo("no match");
        return false;
    }
    const r = sel.span(set[primary]);
    const pick = (if (forward) search.nearest(matches.items, r.end) else search.before(matches.items, r.start)).?;
    const hit = matches.items[pick.index];
    if (final and pick.wrapped) weft.echo("Wrapped around document");
    const match: Sel = .{ .anchor = hit.start, .head = hit.end };
    var k: usize = 0;
    for (set, 0..) |s, i| {
        if (how == .move and i == primary) continue;
        if (k == max - 1) break;
        out[k] = s;
        k += 1;
    }
    out[k] = match;
    _ = weft.setSelections(out[0 .. k + 1], k);
    return true;
}

/// `n` / `N`: step again with the pattern in the `/` register — the last
/// one any grammar searched for.
pub fn again(forward: bool, mode: sel.Mode) void {
    const pattern_ref = weft.registerTextIn(weft.register_search);
    if (pattern_ref.len == 0) return weft.echo("no search pattern");
    var pattern_buf: [1024]u8 = undefined;
    const n = @min(pattern_ref.len, pattern_buf.len);
    @memcpy(pattern_buf[0..n], pattern_ref[0..n]);
    var m = compile(pattern_buf[0..n]) orelse return complain(pattern_buf[0..n]);
    defer m.deinit();
    const hay = readDoc();
    how = mode;
    var k = state.takeCount();
    while (k > 0) : (k -= 1) {
        if (!sel.load()) return;
        @memcpy(base[0..sel.n], sel.items[0..sel.n]);
        if (!step(&m, hay, forward, base[0..sel.n], sel.primary, true)) return;
    }
}

// ── * / A-* ─────────────────────────────────────────────────────────────

fn isWord(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c >= 0x80;
}

/// `*` (`A-*` without `bounds`): the selections' text, escaped, becomes the
/// search pattern — alternatives joined by `|`, each once. With `bounds`, a
/// selection that starts (ends) at a word edge gets a `\b` there, so `*` on
/// `foo` does not find `foobar`.
pub fn fromSelections(bounds: bool) void {
    if (!sel.load()) return;
    var pat: std.ArrayList(u8) = .empty;
    defer pat.deinit(gpa);
    var seen: std.ArrayList([]const u8) = .empty;
    defer {
        for (seen.items) |s| gpa.free(s);
        seen.deinit(gpa);
    }
    for (sel.items[0..sel.n]) |s| {
        const r = sel.span(s);
        const body = gpa.dupe(u8, weft.slice(r.start, r.end)) catch return;
        const dup = for (seen.items) |prev| {
            if (std.mem.eql(u8, prev, body)) break true;
        } else false;
        if (dup or body.len == 0) {
            gpa.free(body);
            continue;
        }
        seen.append(gpa, body) catch {
            gpa.free(body);
            return;
        };
        const escaped = search.source(gpa, body, .{}) catch return;
        defer gpa.free(escaped);
        if (pat.items.len > 0) pat.append(gpa, '|') catch return;
        const before: u8 = if (r.start == 0) ' ' else text.at(r.start - 1) orelse ' ';
        const after: u8 = text.at(r.end) orelse ' ';
        const start_edge = bounds and isWord(body[0]) and !isWord(before);
        const end_edge = bounds and isWord(body[body.len - 1]) and !isWord(after);
        if (start_edge) pat.appendSlice(gpa, "\\b") catch return;
        pat.appendSlice(gpa, escaped) catch return;
        if (end_edge) pat.appendSlice(gpa, "\\b") catch return;
    }
    if (pat.items.len == 0) return;
    weft.registerSet(weft.register_search, pat.items);
    var buf: [160]u8 = undefined;
    weft.echo(std.fmt.bufPrint(&buf, "register '/' set to '{s}'", .{pat.items[0..@min(pat.items.len, 120)]}) catch "register '/' set");
}
