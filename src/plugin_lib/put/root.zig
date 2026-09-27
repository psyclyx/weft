//! put — write over one range per selection, as ONE undo unit. The edit
//! mechanism helix's verbs and ide's transfer and line keys share.
//!
//! `each` anchors the ranges and runs the grammar's own put OPERATOR over
//! them through `runRangeArgEach`: reverse offset order (a later write never
//! shifts an earlier range) inside one undo unit. The operator is handed only
//! its range, so what to write there is a PLAN set up before the run — the
//! job whose start offset the range still has (earlier jobs have not moved
//! yet) and the `Source` that says what that job writes. Each job leaves a
//! live range over what it wrote; `wrote` reads it back so the grammar can
//! place its selections afterwards.
//!
//! The operator has to be a command of the GRAMMAR's (a range arg reaches
//! only a command): register `run` under a name and hand that name to
//! `each`. One plan at a time, per plugin instance — `each` is synchronous.

const std = @import("std");
const weft = @import("weft");

pub const max = weft.max_selections;

/// What each job writes over its range.
pub const Source = union(enum) {
    /// The same bytes everywhere (`""` deletes).
    literal: []const u8,
    /// Register `slot`'s value for this job, under core's distribution rule
    /// (`count` selections share it) — its ferried identity re-stamped where
    /// it lands. `line` ends a value that lacks one with a line break (a
    /// linewise value taken from a last line with none of its own).
    register: struct { slot: u8, count: usize, line: bool = false },
    /// The grammar computes job `i`'s bytes over `r` (null skips the job).
    derive: *const fn (i: usize, r: weft.Range) ?[]const u8,
};

var source: Source = .{ .literal = "" };
var jobs: usize = 0;
var job_at: [max]usize = undefined;
var job_used: [max]bool = undefined;
/// A job that first writes a line break (a linewise paste after a last line
/// with none to land after): what it wrote starts past it.
var job_newline: [max]bool = undefined;
var job_result: [max]?u32 = undefined;

var buf: [(1 << 16) + 8]u8 = undefined;

/// Write `src` over each of `ranges` (document order, one per selection) by
/// running operator `op` (a command whose body is `run`), as one undo unit.
/// `newline[i]` prefixes job `i`'s bytes with a line break.
pub fn each(op: []const u8, ranges: []const weft.Range, src: Source, newline: ?[]const bool) void {
    const n = @min(ranges.len, max);
    source = src;
    jobs = n;
    var handles: [max]?u32 = undefined;
    for (ranges[0..n], 0..) |r, i| {
        job_at[i] = r.start;
        job_used[i] = false;
        job_newline[i] = if (newline) |nl| nl[i] else false;
        job_result[i] = null;
        handles[i] = weft.anchorRange(r);
    }
    weft.runRangeArgEach(op, handles[0..n]);
}

/// Which job a range is. Jobs run from the last offset back, so the latest
/// unused job starting here is the one.
fn claim(start: usize) ?usize {
    var i = jobs;
    while (i > 0) {
        i -= 1;
        if (!job_used[i] and job_at[i] == start) {
            job_used[i] = true;
            return i;
        }
    }
    return null;
}

/// The body of the grammar's put operator: one job's write.
pub fn run() void {
    const h = weft.argRange(0) orelse return;
    const r = weft.rangeEnds(h) orelse return;
    const i = claim(r.start) orelse return;
    var bytes: []const u8 = switch (source) {
        .literal => |l| l,
        .register => |reg| weft.registerPasteValueIn(reg.slot, i, reg.count),
        .derive => |f| f(i, r) orelse return,
    };
    const lead: usize = @intFromBool(job_newline[i]);
    const trail = switch (source) {
        .register => |reg| reg.line and (bytes.len == 0 or bytes[bytes.len - 1] != '\n'),
        else => false,
    };
    if (lead == 1 or trail) {
        if (bytes.len + 2 > buf.len) return;
        // `bytes` may already live in `buf` (a derived job): move, not copy.
        std.mem.copyBackwards(u8, buf[lead..][0..bytes.len], bytes);
        if (lead == 1) buf[0] = '\n';
        if (trail) buf[lead + bytes.len] = '\n';
        bytes = buf[0 .. lead + bytes.len + @intFromBool(trail)];
    }
    weft.editRange(h, bytes);
    const base = r.start + lead;
    switch (source) {
        .register => |reg| weft.pasteValueAtIn(reg.slot, base, i, reg.count),
        else => {},
    }
    job_result[i] = weft.anchorRange(.{ .start = base, .end = r.start + bytes.len });
}

/// A scratch a `derive` callback may build its bytes in.
pub fn scratch() []u8 {
    return buf[0 .. buf.len - 8];
}

/// What opening a line at `at` writes, in `scratch`: a line break then the
/// indentation of the line `at` is on (`below`), or that indentation then a
/// line break (above) — so the new line starts where its neighbour does.
/// Null when the indentation does not fit.
pub fn lineOpening(at: usize, below: bool) ?[]const u8 {
    const out = scratch();
    const l = weft.lineAt(at);
    const line = weft.slice(l.start, l.end);
    var indent: usize = 0;
    while (indent < line.len and (line[indent] == ' ' or line[indent] == '\t')) indent += 1;
    if (indent + 1 > out.len) return null;
    if (below) {
        out[0] = '\n';
        @memcpy(out[1..][0..indent], line[0..indent]);
    } else {
        @memcpy(out[0..indent], line[0..indent]);
        out[indent] = '\n';
    }
    return out[0 .. indent + 1];
}

/// What job `i` of the last `each` wrote, where it is now.
pub fn wrote(i: usize) ?weft.Range {
    if (i >= jobs) return null;
    return weft.rangeEnds(job_result[i] orelse return null);
}
