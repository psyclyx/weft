//! git — PATCH SYNTHESIS: a one-file, one-hunk patch for `git apply`.
//!
//! Pure text arithmetic over what the parser found: the file's kept diff
//! header plus one hunk, and — for a selection inside that hunk — git's
//! own partial algorithm (unselected `+` dropped, unselected `-` demoted
//! to context, `@@` counts recomputed). It runs no command and touches no
//! buffer; the caller hands the bytes to `git apply`.

const std = @import("std");
const model = @import("model.zig");
const Lines = model.Lines;
const cur = model.cur;

/// A synthesized patch. Static rather than stack: a wasm guest's stack is
/// small and a hunk is not.
pub var patch_buf: [model.PATCH_CAP]u8 = undefined;
/// Scratch for a partial hunk's transformed body.
pub var body_out: [model.PATCH_CAP]u8 = undefined;

/// Build a one-file/one-hunk patch: the file's kept diff header + the hunk. With
/// `sel` (body-line ordinals), transform the hunk to only the selected +/- lines
/// (git's algorithm: unselected `+` dropped, unselected `-` demoted to context)
/// and recompute the `@@` counts. Returns null if it won't fit.
pub fn buildPatch(hi: usize, sel: ?Lines) ?[]const u8 {
    const h = &cur().hunks[hi];
    const f = &cur().files[h.file];
    if (f.header_len == 0) return null;
    var w: usize = 0;
    const hdr = cur().raw[f.header_off .. f.header_off + f.header_len];
    if (hdr.len > patch_buf.len) return null;
    @memcpy(patch_buf[0..hdr.len], hdr);
    w = hdr.len;

    const hunk = cur().raw[h.at .. h.at + h.len];
    if (sel) |s| return buildPartial(hunk, s, &w);
    if (w + hunk.len > patch_buf.len) return null;
    @memcpy(patch_buf[w .. w + hunk.len], hunk);
    w += hunk.len;
    return ensureNl(patch_buf[0..w]);
}

pub fn buildPartial(hunk: []const u8, sel: Lines, w: *usize) ?[]const u8 {
    // Split the @@ header line from the body.
    var hl: usize = 0;
    while (hl < hunk.len and hunk[hl] != '\n') hl += 1;
    const starts = parseHunkStarts(hunk[0..hl]);
    // One pass over the body: transform lines, counting old/new. Body lines are
    // numbered from 0; `sel` names them by ordinal, never by byte.
    var bw: usize = 0;
    var old_count: usize = 0;
    var new_count: usize = 0;
    var ord: usize = 0;
    var i: usize = hl + 1;
    while (i < hunk.len) : (ord += 1) {
        var le = i;
        while (le < hunk.len and hunk[le] != '\n') le += 1;
        const has_nl = le < hunk.len;
        const line = hunk[i..le];
        const selected = ord >= sel.lo and ord < sel.hi;
        if (line.len == 0) {
            i = le + 1;
            continue;
        }
        const c = line[0];
        var keep = true;
        var demote = false;
        switch (c) {
            '\\' => {}, // "\ No newline at end of file" — carry as-is
            ' ' => {
                old_count += 1;
                new_count += 1;
            },
            '+' => {
                if (selected) {
                    new_count += 1;
                } else keep = false; // an addition we're not taking: drop it
            },
            '-' => {
                if (selected) {
                    old_count += 1;
                } else {
                    demote = true; // keep the line as context, both sides
                    old_count += 1;
                    new_count += 1;
                }
            },
            else => {},
        }
        if (keep) {
            if (bw + line.len + 1 > body_out.len) return null;
            if (demote) body_out[bw] = ' ' else body_out[bw] = c;
            bw += 1;
            @memcpy(body_out[bw .. bw + line.len - 1], line[1..]);
            bw += line.len - 1;
            if (has_nl) {
                body_out[bw] = '\n';
                bw += 1;
            }
        }
        i = le + 1;
    }
    // Emit the recomputed header + transformed body after the file header.
    const hh = std.fmt.bufPrint(patch_buf[w.*..], "@@ -{d},{d} +{d},{d} @@\n", .{ starts.old, old_count, starts.new, new_count }) catch return null;
    w.* += hh.len;
    if (w.* + bw > patch_buf.len) return null;
    @memcpy(patch_buf[w.* .. w.* + bw], body_out[0..bw]);
    w.* += bw;
    return ensureNl(patch_buf[0..w.*]);
}

pub const Starts = struct { old: usize, new: usize };
pub fn parseHunkStarts(line: []const u8) Starts {
    var old: usize = 0;
    var new: usize = 0;
    if (std.mem.indexOfScalar(u8, line, '-')) |mi| old = parseUint(line[mi + 1 ..]);
    if (std.mem.indexOfScalar(u8, line, '+')) |pi| new = parseUint(line[pi + 1 ..]);
    return .{ .old = old, .new = new };
}
pub fn parseUint(s: []const u8) usize {
    var v: usize = 0;
    for (s) |c| {
        if (c < '0' or c > '9') break;
        v = v * 10 + (c - '0');
    }
    return v;
}

pub fn ensureNl(patch: []const u8) []const u8 {
    if (patch.len > 0 and patch[patch.len - 1] == '\n') return patch;
    if (patch.len >= patch_buf.len) return patch;
    patch_buf[patch.len] = '\n';
    return patch_buf[0 .. patch.len + 1];
}
