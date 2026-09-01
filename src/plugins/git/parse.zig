//! git — the PARSER: one gather's raw bytes into the model.
//!
//! It reads `session.raw` (porcelain status, the two diffs, recent
//! commits, split on the RS sentinels) and fills `files`/`hunks`. It
//! writes no buffer, publishes no style, and knows no command — the
//! whole file is bytes in, model out, which is why it can be read
//! without holding the rest of the plugin in your head.

const std = @import("std");
const model = @import("model.zig");
const Section = model.Section;
const RepoSession = model.RepoSession;
const cur = model.cur;
const MAX_FILES = model.MAX_FILES;
const MAX_HUNKS = model.MAX_HUNKS;
const render_order = model.render_order;
const countLines = @import("render.zig").countLines;
/// The parser needs to find an already-recorded file to attach a hunk to.
/// `findFile` lives with the display tables it also serves.
const findFile = @import("render.zig").findFile;
const isCollapsed = @import("render.zig").isCollapsed;

// ── Parse ──────────────────────────────────────────────────────────────────
pub fn parse() void {
    cur().file_count = 0;
    cur().hunk_count = 0;
    cur().branch_len = 0;
    cur().in_repo = false;
    cur().recent_start = 0;
    cur().recent_end = 0;
    cur().dropped_files = false;
    cur().dropped_hunks = false;
    for (0..4) |i| {
        cur().sec_present[i] = false;
        cur().sec_count[i] = 0;
    }
    // Region boundaries, RECORDED by the assembler as it appended each
    // command's stdout — not recovered by scanning for a sentinel. A part
    // whose command produced nothing is an empty region, which reads the same
    // as the old "marker missing ⇒ the command failed" case without needing a
    // byte sequence chosen to never occur in a filename.
    const b = cur().bounds;
    parsePorcelain(0, b[@intFromEnum(model.Part.status)]);
    parseDiff(b[@intFromEnum(model.Part.status)], b[@intFromEnum(model.Part.unstaged)], .unstaged);
    parseDiff(b[@intFromEnum(model.Part.unstaged)], b[@intFromEnum(model.Part.staged)], .staged);
    cur().recent_start = b[@intFromEnum(model.Part.staged)];
    cur().recent_end = b[@intFromEnum(model.Part.recent)];
    // Re-apply the remembered file-fold state (files rebuilt default-expanded).
    for (cur().files[0..cur().file_count]) |*f| f.folded = isCollapsed(f.path_());
    // Present iff non-empty (recent by commit lines).
    for (render_order) |sec| {
        const idx = @intFromEnum(sec);
        if (sec == .recent) {
            cur().sec_count[idx] = countLines(cur().recent_start, cur().recent_end);
        } else {
            var c: usize = 0;
            for (cur().files[0..cur().file_count]) |f| if (f.section == sec) {
                c += 1;
            };
            cur().sec_count[idx] = c;
        }
        cur().sec_present[idx] = cur().sec_count[idx] > 0;
    }
}

pub fn parsePorcelain(s: usize, e: usize) void {
    var i = s;
    while (i < e) {
        const ls = i;
        var le = i;
        while (le < e and cur().raw[le] != '\n') le += 1;
        i = le + 1;
        const line = cur().raw[ls..le];
        if (line.len == 0) continue;
        if (std.mem.startsWith(u8, line, "## ")) {
            cur().in_repo = true;
            const b = std.mem.trim(u8, line[3..], " \t\r");
            cur().branch_len = @min(b.len, cur().branch.len);
            @memcpy(cur().branch[0..cur().branch_len], b[0..cur().branch_len]);
            continue;
        }
        if (line.len < 3) continue;
        const x = line[0];
        const y = line[1];
        var pth = std.mem.trim(u8, line[3..], " \t\r");
        // Rename: "old -> new" — track the new path (what the diff names).
        if (std.mem.indexOf(u8, pth, " -> ")) |ai| pth = pth[ai + 4 ..];
        pth = dequote(pth);
        if (x == '?' and y == '?') {
            addFile(.untracked, pth, x, y);
            continue;
        }
        if (x != ' ' and x != '?') addFile(.staged, pth, x, y);
        if (y != ' ' and y != '?') addFile(.unstaged, pth, x, y);
    }
}

/// Best-effort unquote of a porcelain C-quoted path (spaces/specials). We drop
/// the surrounding quotes but don't unescape — a corner enough case to note, not
/// solve, in 2a.
pub fn dequote(pth: []const u8) []const u8 {
    if (pth.len >= 2 and pth[0] == '"' and pth[pth.len - 1] == '"') return pth[1 .. pth.len - 1];
    return pth;
}

pub fn addFile(section: Section, pth: []const u8, x: u8, y: u8) void {
    if (cur().file_count >= MAX_FILES) {
        cur().dropped_files = true;
        return;
    }
    var f = &cur().files[cur().file_count];
    f.* = .{ .section = section, .idx_ch = x, .wt_ch = y };
    f.plen = @min(pth.len, f.path.len);
    @memcpy(f.path[0..f.plen], pth[0..f.plen]);
    cur().file_count += 1;
}

pub fn parseDiff(ds: usize, de: usize, sec: Section) void {
    var i = ds;
    var cur_file: ?usize = null;
    var hstart: ?usize = null;
    while (i < de) {
        const ls = i;
        var le = i;
        while (le < de and cur().raw[le] != '\n') le += 1;
        i = le + 1;
        const line = cur().raw[ls..le];
        if (std.mem.startsWith(u8, line, "diff --git ")) {
            closeHunk(&hstart, cur_file, ls);
            cur_file = findFile(sec, pathFromDiffGit(line));
            if (cur_file) |fi| {
                cur().files[fi].header_off = ls;
                cur().files[fi].header_len = 0; // set at the first @@
                cur().files[fi].first_hunk = cur().hunk_count;
                cur().files[fi].n_hunks = 0;
            }
        } else if (std.mem.startsWith(u8, line, "@@")) {
            if (cur_file) |fi| {
                if (cur().files[fi].header_len == 0) cur().files[fi].header_len = ls - cur().files[fi].header_off;
            }
            closeHunk(&hstart, cur_file, ls);
            hstart = ls;
        }
    }
    closeHunk(&hstart, cur_file, de);
}

pub fn closeHunk(hstart: *?usize, file: ?usize, end: usize) void {
    const s = hstart.* orelse return;
    hstart.* = null;
    const fi = file orelse return;
    if (cur().hunk_count >= MAX_HUNKS) {
        cur().dropped_hunks = true;
        return;
    }
    cur().hunks[cur().hunk_count] = .{ .file = fi, .at = s, .len = end - s };
    cur().hunk_count += 1;
    cur().files[fi].n_hunks += 1;
}

pub fn pathFromDiffGit(line: []const u8) []const u8 {
    if (std.mem.indexOf(u8, line, " b/")) |bi| return std.mem.trimEnd(u8, line[bi + 3 ..], " \t\r");
    return "";
}
