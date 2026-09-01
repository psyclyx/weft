//! git — the PROJECTION: model to a published node tree.
//!
//! This file used to be 425 lines, and not one of them was about git. It
//! emitted text while tracking its own output offset, recorded an
//! `[start,end)` per node into a parallel table, published styles by offset,
//! published folds by offset, linear-scanned that table to hit-test the cursor
//! back to a row, found where a node had MOVED so the cursor could be restored
//! after a rebuild, and remembered which paths were collapsed in a fixed table
//! of 64 — apologising out loud past 64.
//!
//! All of that is `core/projection.zig`'s now, once, for every producer. What
//! is left here is the part that IS about git: which rows exist, what each one
//! is called, and what kind of thing it is.
//!
//! IDENTITY, not position. A row carries a KEY this file mints and parses
//! (`keyOf`/`targetOf`); the host keys fold state and cursor restoration by it,
//! and hands it back when a verb asks what the cursor is on. No offset crosses
//! the membrane in either direction — the projection doors take none and
//! return none — so "acted on whatever row a stale offset now covers" stopped
//! being a bug this plugin can contain, rather than one it had to be careful
//! about. The file boundary and the source-scanning gate that used to enforce
//! that by hand are no longer load-bearing.

const std = @import("std");
const weft = @import("weft");
const model = @import("model.zig");
const Section = model.Section;
const render_order = model.render_order;
const File = model.File;
const Kind = model.Kind;
const Target = model.Target;
const Lines = model.Lines;
const cur = model.cur;

/// Roles. The producer says what a row IS; how that reads is the host's
/// (`projection.styleFor`), which is what will let a theme restyle a diff
/// without this file changing.
const role_section = "git.section";
const role_file = "git.file";
const role_hunk = "git.hunk";
const role_added = "git.diff.added";
const role_removed = "git.diff.removed";
const role_context = "git.diff.context";
const role_commit = "git.commit";
const role_header = "git.header";

// ── Keys: a row's identity, minted here and parsed back here ──────────
// One grammar, one place. `s:<section>` / `f:<section>:<path>` /
// `h:<section>:<path>:<ord>` / `c:<hash>`. The path goes LAST in the file and
// hunk forms so a path containing a colon cannot be confused for a separator —
// everything before it is fixed-arity.

var key_buf: [512]u8 = undefined;

pub fn keyOf(t: Target) []const u8 {
    return switch (t.kind) {
        .none => "",
        .section => std.fmt.bufPrint(&key_buf, "s:{s}", .{@tagName(t.section)}) catch "",
        .file => std.fmt.bufPrint(&key_buf, "f:{s}:{s}", .{ @tagName(t.section), t.path_() }) catch "",
        .hunk => std.fmt.bufPrint(&key_buf, "h:{s}:{d}:{s}", .{ @tagName(t.section), t.ord, t.path_() }) catch "",
        .commit => std.fmt.bufPrint(&key_buf, "c:{s}", .{t.hash_()}) catch "",
    };
}

/// A key back into the identity it names. Returns `.none` for a key this
/// plugin did not mint, or one whose section no longer parses — a row it
/// cannot name is a row it must not act on.
pub fn targetOf(key: []const u8) Target {
    var t: Target = .{ .snap = cur().snapshot };
    if (key.len < 2 or key[1] != ':') return t;
    const body = key[2..];
    switch (key[0]) {
        's' => {
            t.section = sectionNamed(body) orelse return .{ .snap = t.snap };
            t.kind = .section;
        },
        'f' => {
            const sep = std.mem.indexOfScalar(u8, body, ':') orelse return t;
            t.section = sectionNamed(body[0..sep]) orelse return .{ .snap = t.snap };
            setPath(&t, body[sep + 1 ..]);
            t.kind = .file;
        },
        'h' => {
            const sep = std.mem.indexOfScalar(u8, body, ':') orelse return t;
            t.section = sectionNamed(body[0..sep]) orelse return .{ .snap = t.snap };
            const rest = body[sep + 1 ..];
            const sep2 = std.mem.indexOfScalar(u8, rest, ':') orelse return t;
            t.ord = std.fmt.parseInt(usize, rest[0..sep2], 10) catch return t;
            setPath(&t, rest[sep2 + 1 ..]);
            t.kind = .hunk;
        },
        'c' => {
            t.hlen = @min(body.len, t.hash.len);
            @memcpy(t.hash[0..t.hlen], body[0..t.hlen]);
            t.kind = .commit;
        },
        else => {},
    }
    return t;
}

fn sectionNamed(name: []const u8) ?Section {
    inline for (@typeInfo(Section).@"enum".fields) |f| {
        if (std.mem.eql(u8, f.name, name)) return @enumFromInt(f.value);
    }
    return null;
}

fn setPath(t: *Target, p: []const u8) void {
    t.plen = @min(p.len, t.path.len);
    @memcpy(t.path[0..t.plen], p[0..t.plen]);
}

// ── The projection ────────────────────────────────────────────────────

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

pub fn secTitle(sec: Section) []const u8 {
    return switch (sec) {
        .untracked => "Untracked files",
        .unstaged => "Unstaged changes",
        .staged => "Staged changes",
        .recent => "Recent commits",
    };
}

pub fn statusLabel(f: *const File) []const u8 {
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

/// Publish the model as a node tree over this session's entry.
///
/// This is the whole of what `render` + `repaint` + `publishStyles` +
/// `publishFolds` were. There is no output buffer, no offset arithmetic, and
/// no second table to keep in step with the text — the host lays the tree out
/// and everything downstream (folding, hit-testing, where the cursor lands)
/// follows from the keys rather than from where the bytes ended up.
pub fn repaint() void {
    const b = weft.project(cur().name()) orelse return;

    if (!cur().in_repo) {
        _ = b.add(.{
            .key = "s:none",
            .role = role_header,
            .text = "Not a git repository.\n\nRun git-init (SPC g i) to start one.",
        });
        _ = b.commit();
        return;
    }

    _ = b.addFmt(.{ .key = "s:branch", .role = role_header }, "Branch: {s}", .{
        if (cur().branch_len > 0) cur().branch[0..cur().branch_len] else "(no branch)",
    });

    for (render_order) |sec| {
        const idx = @intFromEnum(sec);
        if (!cur().sec_present[idx]) continue;
        const head = b.addFmt(.{
            .key = keyOf(.{ .kind = .section, .section = sec }),
            .role = role_section,
            .foldable = true,
            // NOT focusable: a section header is structure. A fresh render
            // lands on the first row a verb can act on, which is what the
            // `home_off` this replaced computed by hand.
        }, "{s} ({d})", .{ secTitle(sec), cur().sec_count[idx] }) orelse continue;
        if (sec == .recent) {
            addRecent(b, head);
        } else {
            var fi: usize = 0;
            while (fi < cur().file_count) : (fi += 1) {
                if (cur().files[fi].section != sec) continue;
                addFile(b, head, fi);
            }
        }
    }
    _ = b.commit();
}

fn addFile(b: weft.ProjectionBuilder, parent: u32, fi: usize) void {
    const f = &cur().files[fi];
    const file_node = b.addFmt(.{
        .key = keyOf(.{ .kind = .file, .section = f.section, .path = f.path, .plen = f.plen }),
        .role = role_file,
        .parent = parent,
        .foldable = f.n_hunks > 0,
        .focusable = true,
    }, "  {s}{s}", .{ statusLabel(f), f.path_() }) orelse return;

    var h = f.first_hunk;
    while (h < f.first_hunk + f.n_hunks) : (h += 1) {
        addHunk(b, file_node, fi, h - f.first_hunk, h);
    }
}

/// A hunk is its `@@` line, with ONE NODE PER BODY LINE beneath it.
///
/// Per-line nodes rather than one blob of hunk text, because a diff line's
/// colour is a property OF THE LINE — added, removed, context — and the host
/// styles by role. Publishing the body as a single node would mean one role
/// for the whole hunk, which is the thing the old per-line `styleHunk` scan
/// existed to avoid. The rows are also what a partial-hunk selection is about.
fn addHunk(b: weft.ProjectionBuilder, parent: u32, fi: usize, ord: usize, hi: usize) void {
    const f = &cur().files[fi];
    const key = keyOf(.{ .kind = .hunk, .section = f.section, .path = f.path, .plen = f.plen, .ord = ord });
    var key_owned: [512]u8 = undefined;
    const owned = key_owned[0..@min(key.len, key_owned.len)];
    @memcpy(owned, key[0..owned.len]);

    const h = &cur().hunks[hi];
    const body = cur().raw[h.at .. h.at + h.len];
    var it = std.mem.splitScalar(u8, body, '\n');
    const header = it.first();
    const hunk_node = b.add(.{
        .key = owned,
        .role = role_hunk,
        .text = header,
        .parent = parent,
        .focusable = true,
    }) orelse return;

    var line_ord: usize = 0;
    while (it.next()) |line| : (line_ord += 1) {
        if (line.len == 0 and it.rest().len == 0) break; // trailing newline
        var line_key: [544]u8 = undefined;
        const lk = std.fmt.bufPrint(&line_key, "{s}#{d}", .{ owned, line_ord }) catch continue;
        _ = b.add(.{
            .key = lk,
            .role = switch (if (line.len == 0) @as(u8, ' ') else line[0]) {
                '+' => role_added,
                '-' => role_removed,
                else => role_context,
            },
            .text = line,
            .parent = hunk_node,
        });
    }
}

fn addRecent(b: weft.ProjectionBuilder, parent: u32) void {
    var i = cur().recent_start;
    while (i < cur().recent_end) {
        var le = i;
        while (le < cur().recent_end and cur().raw[le] != '\n') le += 1;
        if (le > i) {
            const line = cur().raw[i..le];
            // The hash is the first token; it IS the row's durable identity,
            // which is why a commit row survives a re-gather where a working
            // path may not.
            const hash_end = std.mem.indexOfScalar(u8, line, ' ') orelse line.len;
            var t: Target = .{ .kind = .commit };
            t.hlen = @min(hash_end, t.hash.len);
            @memcpy(t.hash[0..t.hlen], line[0..t.hlen]);
            _ = b.addFmt(.{ .key = keyOf(t), .role = role_commit, .parent = parent, .focusable = true }, "  {s}", .{line});
        }
        i = le + 1;
    }
}

// ── The one door into targeting ───────────────────────────────────────

/// What the cursor is on, as an identity. The host hit-tests; this file only
/// reads the key back into the shape the verbs use.
///
/// A selection inside a hunk comes back as LINE ORDINALS of that row, which is
/// what a partial-hunk patch is named by. Ordinal 0 is the `@@` line itself
/// (it is the hunk node's own text), so the body ordinals `buildPatch` wants
/// are one lower.
pub fn nodeAtCursor() Target {
    const key = weft.projectionAtCursor() orelse return .{ .snap = cur().snapshot };
    // A body-line row belongs to its hunk: strip the `#<line>` suffix so a
    // verb pressed anywhere in a hunk acts on the hunk.
    const hunk_key = if (std.mem.lastIndexOfScalar(u8, key, '#')) |at| key[0..at] else key;
    var t = targetOf(hunk_key);
    if (t.kind == .hunk) t.sel = selectedLines(hunk_key);
    return t;
}

pub fn selectedLines(hunk_key: []const u8) ?Lines {
    const lines = weft.projectionSelectedLines(hunk_key) orelse return null;
    if (lines.hi <= 1) return null; // the `@@` line alone selects no body
    return .{ .lo = lines.lo -| 1, .hi = lines.hi - 1 };
}

/// A file target for `fi` in the CURRENT snapshot.
pub fn fileTarget(fi: usize) Target {
    const f = &cur().files[fi];
    return .{
        .kind = .file,
        .snap = cur().snapshot,
        .section = f.section,
        .path = f.path,
        .plen = f.plen,
    };
}

pub fn nameFile(t: *Target, fi: usize) void {
    const f = &cur().files[fi];
    t.section = f.section;
    t.plen = @min(f.plen, t.path.len);
    @memcpy(t.path[0..t.plen], f.path[0..t.plen]);
}

/// Flip a row's fold. The host owns the collapsed set — keyed, unbounded, and
/// surviving a rebuild — where this file kept 64 paths in a fixed table and
/// echoed an apology past that.
pub fn toggleFold(key: []const u8) void {
    _ = weft.projectionToggleFold(key);
}

/// Colour a read-only view's text (`git show`, `git log`, a blame). These own
/// their own buffers and are NOT projections: they are one command's output
/// shown verbatim, so they still paint spans by offset. The distinction is
/// real — there is no model behind them and no row to name.
pub fn styleView(style: model.ViewStyle) void {
    switch (style) {
        .none, .rebase_todo => {},
        .diff => classify(styleDiffLine),
        .log => classify(styleLogLine),
    }
}

fn classify(line_fn: *const fn (base: usize, line: []const u8) void) void {
    weft.styleClear();
    const text = weft.slice(0, weft.byteLen());
    var i: usize = 0;
    while (i < text.len) {
        var e = i;
        while (e < text.len and text[e] != '\n') e += 1;
        line_fn(i, text[i..e]);
        i = e + 1;
    }
}

fn styleDiffLine(base: usize, line: []const u8) void {
    if (line.len == 0) return;
    const cls: weft.StyleClass = if (std.mem.startsWith(u8, line, "diff --git") or
        std.mem.startsWith(u8, line, "index "))
        .muted
    else if (std.mem.startsWith(u8, line, "+++ ") or std.mem.startsWith(u8, line, "--- "))
        .muted
    else if (std.mem.startsWith(u8, line, "@@"))
        .header
    else switch (line[0]) {
        '+' => .added,
        '-' => .removed,
        else => .normal,
    };
    if (cls != .normal) weft.style(base, base + line.len, cls);
}

fn styleLogLine(base: usize, line: []const u8) void {
    var i: usize = 0;
    while (i < line.len and isGraph(line[i])) i += 1;
    var h = i;
    while (h < line.len and isHex(line[h])) h += 1;
    if (h == i) return;
    weft.style(base + i, base + h, .location);
    var j = h;
    while (j < line.len and line[j] == ' ') j += 1;
    if (j < line.len and line[j] == '(') {
        var k = j;
        while (k < line.len and line[k] != ')') k += 1;
        if (k < line.len) k += 1;
        weft.style(base + j, base + k, .header);
    }
}

fn isGraph(c: u8) bool {
    return c == '*' or c == '|' or c == '/' or c == '\\' or c == ' ' or c == '_' or c == '.';
}
fn isHex(c: u8) bool {
    return (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f');
}
