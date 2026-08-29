//! git — the PROJECTION: model to pretty, foldable text, plus the
//! reverse mapping a rendered offset needs to name the row it lands in.
//!
//! This file is the ONLY place a rendered byte range is written or read.
//! That was already the rule (§14.3 — a verb names a row by identity,
//! never by scraping the projection) enforced by a marker comment and a
//! source-scanning gate; now it is a file boundary, and the gate checks
//! the boundary instead of a comment.

const std = @import("std");
const weft = @import("weft");
const model = @import("model.zig");
const Section = model.Section;
const MAX_COLLAPSED = model.MAX_COLLAPSED;
const render_order = model.render_order;
const File = model.File;
const Kind = model.Kind;
const Target = model.Target;
const Lines = model.Lines;
const Node = model.Node;
const cur = model.cur;

// ── Persisted file-fold set (collapsed paths survive a re-gather) ───────────
pub fn collapsedIndex(pth: []const u8) ?usize {
    var i: usize = 0;
    while (i < cur().collapsed_count) : (i += 1) {
        if (std.mem.eql(u8, cur().collapsed_paths[i][0..cur().collapsed_plen[i]], pth)) return i;
    }
    return null;
}
pub fn isCollapsed(pth: []const u8) bool {
    return collapsedIndex(pth) != null;
}
/// Remember (or forget) a file's collapsed state. Bounded — a full set echoes
/// and refuses the new entry rather than dropping silently.
pub fn setCollapsed(pth: []const u8, on: bool) void {
    if (on) {
        if (collapsedIndex(pth) != null) return;
        if (cur().collapsed_count >= MAX_COLLAPSED) {
            weft.echo("git: >64 folded files — this fold won't persist");
            return;
        }
        const n = @min(pth.len, cur().collapsed_paths[cur().collapsed_count].len);
        @memcpy(cur().collapsed_paths[cur().collapsed_count][0..n], pth[0..n]);
        cur().collapsed_plen[cur().collapsed_count] = n;
        cur().collapsed_count += 1;
    } else if (collapsedIndex(pth)) |i| {
        // swap-remove (order doesn't matter).
        cur().collapsed_count -= 1;
        cur().collapsed_paths[i] = cur().collapsed_paths[cur().collapsed_count];
        cur().collapsed_plen[i] = cur().collapsed_plen[cur().collapsed_count];
    }
}

pub fn findFile(sec: Section, pth: []const u8) ?usize {
    if (pth.len == 0) return null;
    var i: usize = 0;
    while (i < cur().file_count) : (i += 1) {
        if (cur().files[i].section == sec and std.mem.eql(u8, cur().files[i].path_(), pth)) return i;
    }
    return null;
}

pub fn countLines(s: usize, e: usize) usize {
    var n: usize = 0;
    var i = s;
    while (i < e) {
        var le = i;
        while (le < e and cur().raw[le] != '\n') le += 1;
        if (le > i) n += 1;
        i = le + 1;
    }
    return n;
}

// ── Render: the model → pretty, foldable text (offsets recorded into nodes) ──
pub fn put(bytes: []const u8) void {
    const n = @min(bytes.len, cur().render_buf.len - cur().out);
    @memcpy(cur().render_buf[cur().out .. cur().out + n], bytes[0..n]);
    cur().out += n;
}
pub fn putNum(n: usize) void {
    var b: [20]u8 = undefined;
    put(std.fmt.bufPrint(&b, "{d}", .{n}) catch return);
}

pub fn secTitle(sec: Section) []const u8 {
    return switch (sec) {
        .untracked => "Untracked files",
        .unstaged => "Unstaged changes",
        .staged => "Staged changes",
        .recent => "Recent commits",
    };
}

pub fn statusLabel(f: *const File) []const u8 {
    // The relevant column: index for a staged node, worktree otherwise.
    const c = if (f.section == .staged) f.idx_ch else f.wt_ch;
    return switch (c) {
        'M' => "modified  ",
        'A' => "new file  ",
        'D' => "deleted   ",
        'R' => "renamed   ",
        'C' => "copied    ",
        else => "",
    };
}

pub fn render() void {
    cur().out = 0;
    cur().home_off = 0;
    // Not in a repo: say so plainly rather than a fake `Branch: (no branch)`.
    // `SPC g i` (git-init) is the natural next move from here.
    if (!cur().in_repo) {
        put("Not a git repository.\n\nRun git-init (SPC g i) to start one.\n");
        return;
    }
    // Branch header.
    put("Branch: ");
    if (cur().branch_len > 0) put(cur().branch[0..cur().branch_len]) else put("(no branch)");
    put("\n\n");

    for (render_order) |sec| {
        const idx = @intFromEnum(sec);
        if (!cur().sec_present[idx]) continue;
        cur().sec_rstart[idx] = cur().out;
        put(if (cur().sec_folded[idx]) "\xe2\x96\xb8 " else "\xe2\x96\xbe "); // ▸ / ▾
        put(secTitle(sec));
        put(" (");
        putNum(cur().sec_count[idx]);
        put(")\n");
        cur().sec_body[idx] = cur().out; // fold start: header stays visible
        if (sec == .recent) {
            renderRecent();
        } else {
            var fi: usize = 0;
            while (fi < cur().file_count) : (fi += 1) {
                if (cur().files[fi].section != sec) continue;
                renderFile(fi);
                if (cur().home_off == 0) cur().home_off = cur().files[fi].r_start;
            }
        }
        cur().sec_rend[idx] = cur().out;
        put("\n"); // separator, outside the fold
    }
    if (cur().home_off == 0) {
        // No files: land on the first present section header, else the top.
        for (render_order) |sec| {
            if (cur().sec_present[@intFromEnum(sec)]) {
                cur().home_off = cur().sec_rstart[@intFromEnum(sec)];
                break;
            }
        }
    }
}

pub fn renderFile(fi: usize) void {
    var f = &cur().files[fi];
    f.r_start = cur().out;
    put("  ");
    if (f.n_hunks > 0) put(if (f.folded) "\xe2\x96\xb8 " else "\xe2\x96\xbe ");
    put(statusLabel(f));
    put(f.path_());
    put("\n");
    f.body = cur().out;
    var h = f.first_hunk;
    while (h < f.first_hunk + f.n_hunks) : (h += 1) {
        cur().hunks[h].r_start = cur().out;
        put(cur().raw[cur().hunks[h].at .. cur().hunks[h].at + cur().hunks[h].len]); // verbatim
        cur().hunks[h].r_end = cur().out;
    }
    f.r_end = cur().out;
}

pub fn renderRecent() void {
    var i = cur().recent_start;
    while (i < cur().recent_end) {
        var le = i;
        while (le < cur().recent_end and cur().raw[le] != '\n') le += 1;
        if (le > i) {
            put("  ");
            put(cur().raw[i..le]);
            put("\n");
        }
        i = le + 1;
    }
}

// ── Publish styles + folds over the freshly-authored buffer ─────────────────
pub fn publishStyles() void {
    weft.styleClear();
    // Branch header line.
    weft.style(0, lineEnd(0), .header);
    for (render_order) |sec| {
        const idx = @intFromEnum(sec);
        if (!cur().sec_present[idx]) continue;
        weft.style(cur().sec_rstart[idx], lineEnd(cur().sec_rstart[idx]), .emphasis);
    }
    var fi: usize = 0;
    while (fi < cur().file_count) : (fi += 1) {
        weft.style(cur().files[fi].r_start, lineEnd(cur().files[fi].r_start), .location);
        var h = cur().files[fi].first_hunk;
        while (h < cur().files[fi].first_hunk + cur().files[fi].n_hunks) : (h += 1) styleHunk(h);
    }
    styleRecent();
}

/// Classify a hunk's rendered lines by their leading diff marker (rendered
/// verbatim, so `render_buf[ls]` IS the diff column).
pub fn styleHunk(h: usize) void {
    var i = cur().hunks[h].r_start;
    const e = cur().hunks[h].r_end;
    while (i < e) {
        var le = i;
        while (le < e and cur().render_buf[le] != '\n') le += 1;
        if (le > i) {
            const cls: weft.StyleClass = if (std.mem.startsWith(u8, cur().render_buf[i..le], "@@"))
                .muted
            else switch (cur().render_buf[i]) {
                '+' => .added,
                '-' => .removed,
                else => .normal,
            };
            if (cls != .normal) weft.style(i, le, cls);
        }
        i = le + 1;
    }
}

pub fn styleRecent() void {
    const idx = @intFromEnum(Section.recent);
    if (!cur().sec_present[idx]) return;
    var i = cur().sec_body[idx];
    const e = cur().sec_rend[idx];
    while (i < e) {
        var le = i;
        while (le < e and cur().render_buf[le] != '\n') le += 1;
        // "  <hash> <subject>" — dim the whole line, hash as a location.
        const hs = i + 2;
        var he = hs;
        while (he < le and cur().render_buf[he] != ' ') he += 1;
        if (he > hs) weft.style(hs, he, .location);
        if (le > he) weft.style(he, le, .muted);
        i = le + 1;
    }
}

pub fn publishFolds() void {
    weft.foldClear();
    for (render_order) |sec| {
        const idx = @intFromEnum(sec);
        if (cur().sec_present[idx] and cur().sec_folded[idx]) weft.fold(cur().sec_body[idx], cur().sec_rend[idx]);
    }
    var fi: usize = 0;
    while (fi < cur().file_count) : (fi += 1) {
        const f = &cur().files[fi];
        if (f.folded and f.n_hunks > 0) weft.fold(f.body, f.r_end);
    }
}

pub fn lineEnd(off: usize) usize {
    var e = off;
    while (e < cur().out and cur().render_buf[e] != '\n') e += 1;
    return e;
}

// ── Display mapping: a rendered offset → the row it lands in ────────────────
// The `r_start`/`r_end`/`sec_r*` tables are a DISPLAY table and nothing else:
// they hit-test the cursor to a row. What that row NAMES is its `Target`.
pub fn nodeAt(off: usize) Node {
    var i: usize = 0;
    while (i < cur().hunk_count) : (i += 1) {
        if (off >= cur().hunks[i].r_start and off < cur().hunks[i].r_end) return .{ .kind = .hunk, .idx = i };
    }
    i = 0;
    while (i < cur().file_count) : (i += 1) {
        if (off >= cur().files[i].r_start and off < cur().files[i].r_end) return .{ .kind = .file, .idx = i };
    }
    const rec = @intFromEnum(Section.recent);
    if (cur().sec_present[rec] and off >= cur().sec_body[rec] and off < cur().sec_rend[rec]) return .{ .kind = .commit, .idx = rec };
    for (render_order) |sec| {
        const idx = @intFromEnum(sec);
        if (cur().sec_present[idx] and off >= cur().sec_rstart[idx] and off < cur().sec_rend[idx]) return .{ .kind = .section, .idx = idx };
    }
    return .{ .kind = .none, .idx = 0 };
}

// ── Reading the projection: selection, hash lift, target → offset ──────────
// The last four readers of a rendered byte range, and the reason this file
// exists as a boundary rather than a comment. Each answers a question ONLY
// the display table can answer; every verb asks through them and never
// touches an offset itself.

/// The body lines of hunk `hi` a selection covers, as ordinals. This is the
/// last place a selection's rendered range is read — past here a partial hunk
/// is named by line ordinals, which the snapshot check governs.
pub fn selectedLines(hi: usize) ?Lines {
    const sel = weft.selection() orelse return null;
    const h = &cur().hunks[hi];
    var lo: usize = 0;
    var hi_ord: usize = 0;
    var seen = false;
    var ord: usize = 0;
    var i = h.r_start;
    while (i < h.r_end and cur().render_buf[i] != '\n') i += 1; // skip the `@@` line
    i += 1;
    while (i < h.r_end) : (ord += 1) {
        var le = i;
        while (le < h.r_end and cur().render_buf[le] != '\n') le += 1;
        if (sel.start < le and sel.end > i) {
            if (!seen) {
                lo = ord;
                seen = true;
            }
            hi_ord = ord + 1;
        }
        i = le + 1;
    }
    return if (seen) .{ .lo = lo, .hi = hi_ord } else null;
}

/// The commit-hash token on the rendered line at `off`, copied into `dst`.
pub fn hashTokenAt(off: usize, dst: []u8) ?usize {
    const ln = weft.lineAt(off);
    var s = ln.start;
    while (s < ln.end and s < cur().out and cur().render_buf[s] == ' ') s += 1;
    var e = s;
    while (e < ln.end and e < cur().out and cur().render_buf[e] != ' ') e += 1;
    if (e == s) return null;
    const n = @min(e - s, dst.len);
    @memcpy(dst[0..n], cur().render_buf[s .. s + n]);
    return n;
}

/// Where a target's row starts in the CURRENT render — cursor placement only,
/// never authority, so it is lenient by design: a vanished hunk lands on its
/// file's header.
pub fn offsetOf(t: Target) ?usize {
    switch (t.kind) {
        .none => return null,
        .section => {
            const idx = @intFromEnum(t.section);
            return if (cur().sec_present[idx]) cur().sec_rstart[idx] else null;
        },
        .file => {
            const fi = findFile(t.section, t.path_()) orelse return null;
            return cur().files[fi].r_start;
        },
        .hunk => {
            const fi = findFile(t.section, t.path_()) orelse return null;
            const f = &cur().files[fi];
            if (f.n_hunks == 0) return f.r_start;
            return cur().hunks[f.first_hunk + @min(t.ord, f.n_hunks - 1)].r_start;
        },
        .commit => return commitRow(t.hash_()),
    }
}

/// The rendered start of the recent-commits line naming `want`.
pub fn commitRow(want: []const u8) ?usize {
    const idx = @intFromEnum(Section.recent);
    if (!cur().sec_present[idx]) return null;
    var i = cur().sec_body[idx];
    const e = cur().sec_rend[idx];
    while (i < e) {
        var le = i;
        while (le < e and cur().render_buf[le] != '\n') le += 1;
        const hs = @min(i + 2, le); // skip the "  " indent
        var he = hs;
        while (he < le and cur().render_buf[he] != ' ') he += 1;
        if (he > hs and std.mem.eql(u8, cur().render_buf[hs..he], want)) return i;
        i = le + 1;
    }
    return null;
}

/// Author the projection over this session's buffer, then index the new
/// bytes with styles and folds. The one write of `render_buf` to a document.
pub fn repaint() void {
    render();
    weft.edit(.{ .start = 0, .end = weft.byteLen() }, cur().render_buf[0..cur().out]);
    publishStyles();
    publishFolds();
}

// ── The one door into targeting ─────────────────────────────────────────
// Hit-test the cursor through the display table, then read the identity
// the row carries. It lives HERE, with the table it reads, so a verb can
// only ever ask for a Target — never for an offset.

/// The ONE door into targeting: hit-test the cursor through the display table,
/// then read the identity the row carries. Every verb goes through here; no
/// verb ever sees a rendered offset.
pub fn nodeAtCursor() Target {
    const off = weft.cursor();
    const n = nodeAt(off);
    var t: Target = .{ .kind = n.kind, .snap = cur().snapshot };
    switch (n.kind) {
        .none => {},
        .section => t.section = @enumFromInt(n.idx),
        .file => nameFile(&t, n.idx),
        .hunk => {
            const h = &cur().hunks[n.idx];
            nameFile(&t, h.file);
            t.ord = n.idx - cur().files[h.file].first_hunk;
            t.sel = selectedLines(n.idx);
        },
        .commit => t.hlen = hashTokenAt(off, &t.hash) orelse return .{ .snap = cur().snapshot },
    }
    return t;
}

pub fn nameFile(t: *Target, fi: usize) void {
    const f = &cur().files[fi];
    t.section = f.section;
    t.plen = @min(f.plen, t.path.len);
    @memcpy(t.path[0..t.plen], f.path[0..t.plen]);
}

/// A file target for `fi` in the CURRENT snapshot.
pub fn fileTarget(fi: usize) Target {
    var t: Target = .{ .kind = .file, .snap = cur().snapshot };
    nameFile(&t, fi);
    return t;
}
