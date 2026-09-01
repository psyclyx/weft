//! consult — navigation sources over the pick seam (design §6.4), a `.wasm`
//! plugin with perms `{}` (view). A source gathers candidates, opens a pick,
//! and on accept resolves the CHOSEN ROW (by its add-order index, not its
//! text) through a CRDT-anchored source range. Presentation match offsets are
//! used only after the anchored row is verified unchanged, so edits above it
//! move the target while edits to/deletion of the target make it stale rather
//! than silently redirecting the jump. `consult-line` is the first source;
//! grep/imenu/mark join as their inputs (proc, symbols) land.

const std = @import("std");
const weft = @import("weft");

const line_pick = 0;
const sym_pick = 1;

const Target = struct {
    range: u32,
    digest: [32]u8,
    /// `consult-line` anchors the terminating newline too, when present. It
    /// gives an otherwise-empty row a real identity and lets deletion collapse
    /// to a state we can reject. Imenu targets leave this false.
    has_terminator: bool = false,
};

/// Per-row opaque CRDT targets, parallel to pickAdd order. The guest neither
/// sees nor reconstructs document versions or CRDT event identities.
var targets: [1 << 15]Target = undefined;
var n_rows: usize = 0;

fn releaseTargets() void {
    for (targets[0..n_rows]) |target| weft.releaseRange(target.range);
    n_rows = 0;
}

fn digestRange(start: usize, end: usize) ?[32]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var at = start;
    while (at < end) {
        const next = @min(end, at + 64 * 1024);
        const bytes = weft.slice(at, next);
        if (bytes.len != next - at) return null;
        hasher.update(bytes);
        at = next;
    }
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    return digest;
}

/// A Head owns one picker. End the previous interaction while its guest state
/// is still intact, then release any orphaned targets before constructing the
/// replacement. `pickEnd` may otherwise cancel the old picker only after this
/// plugin has overwritten its target table.
fn beginTargets() void {
    weft.run("pick-cancel");
    releaseTargets();
}

const cmds = [_]weft.CommandEntry{
    .{ .name = "consult-line", .call = consultLine },
    .{ .name = "consult-imenu", .call = consultImenu },
};

export fn on_pick_accept(pick_id: u32) void {
    if (pick_id != line_pick and pick_id != sym_pick) return;
    defer releaseTargets();
    var outcome = (weft.pickOutcome(weft.allocator) catch return) orelse return;
    defer outcome.deinit(weft.allocator);
    const candidate = switch (outcome) {
        .candidate => |candidate| candidate,
        .input, .cancelled => return,
    };
    const i = candidate.index;
    if (i < n_rows) {
        const target = targets[i];
        const current = weft.rangeEnds(target.range) orelse return;
        var content_end = current.end;
        if (target.has_terminator) {
            if (content_end <= current.start or
                !std.mem.eql(u8, weft.slice(content_end - 1, content_end), "\n")) return;
            content_end -= 1;
        }
        const current_digest = digestRange(current.start, content_end) orelse return;
        if (!std.mem.eql(u8, &current_digest, &target.digest)) return;
        // Match evidence belongs to the candidate snapshot. Reuse it only if
        // the CRDT-anchored source text still agrees; otherwise the safe result
        // is stale/no-op, never a jump into whichever bytes inherited an old
        // coordinate. `slice` and the original candidate share the same 64-KiB
        // guest read bound, including for unusually long lines.
        if (candidate.text.len > content_end - current.start) return;
        const text_end = current.start + candidate.text.len;
        const text = weft.slice(current.start, text_end);
        if (!std.mem.eql(u8, text, candidate.text)) return;
        const relative = if (pick_id == line_pick) candidate.match.start else 0;
        if (relative > text.len) return;
        weft.jump(current.start + relative);
    }
}

/// Fuzzy-pick a line in the current buffer and jump to the accepted match.
fn consultLine() void {
    beginTargets();
    weft.pickBegin("line", line_pick);
    const len = weft.byteLen();
    // Walk the buffer line by line (bounded by the row table + read scratch).
    var line_start: usize = 0;
    var row: usize = 1;
    var truncated = false;
    while (line_start <= len) : (row += 1) {
        if (n_rows >= targets.len) {
            truncated = true;
            break;
        }
        const l = weft.lineAt(line_start);
        const has_terminator = l.end < len;
        // EOF itself carries no identity. In an empty document, or after a
        // trailing newline, there is no row target Stemma can distinguish
        // from deletion of the preceding separator.
        if (l.start == l.end and !has_terminator) break;
        const target_end = l.end + @intFromBool(has_terminator);
        const digest = digestRange(l.start, l.end) orelse break;
        const text = weft.slice(l.start, l.end); // borrows scratch
        const target = weft.anchorRange(.{ .start = l.start, .end = target_end }) orelse break;
        if (!weft.retainRange(target)) {
            weft.releaseRange(target);
            break;
        }
        // A short "N: " docstring is display-only; the match text is the line.
        var doc: [16]u8 = undefined;
        const ds = std.fmt.bufPrint(&doc, "L{d}", .{row}) catch "";
        weft.pickAdd(text, ds);
        targets[n_rows] = .{ .range = target, .digest = digest, .has_terminator = has_terminator };
        n_rows += 1;
        if (l.end + 1 > len) break; // last line
        line_start = l.end + 1; // past the newline
    }
    weft.pickEnd();
    if (truncated) weft.echo(std.fmt.comptimePrint("consult: >{d} lines — some omitted", .{targets.len}));
}

/// Common definition node types across languages. A query for a type the
/// grammar doesn't have simply returns no captures, so trying many is
/// grammar-agnostic (precise per-language sets come with modes later).
const def_types = [_][]const u8{
    "function_declaration",  "function_definition", "function_item",
    "method_declaration",    "method_definition",   "class_declaration",
    "class_definition",      "struct_declaration",  "struct_item",
    "enum_declaration",      "type_declaration",    "type_definition",
    "interface_declaration", "trait_item",          "const_declaration",
    "variable_declaration",
};

/// Fuzzy-pick a definition (function/type/…) in the buffer and jump to it.
/// Grammar-driven via `syntax.query`; degrades to empty without a grammar.
fn consultImenu() void {
    beginTargets();
    weft.pickBegin("symbol", sym_pick);
    var truncated = false;
    outer: for (def_types) |ty| {
        var scm_buf: [96]u8 = undefined;
        const scm = std.fmt.bufPrint(&scm_buf, "({s}) @d", .{ty}) catch continue;
        const count = weft.query(scm, .{ .start = 0, .end = weft.byteLen() });
        var i: usize = 0;
        while (i < count) : (i += 1) {
            if (n_rows >= targets.len) {
                truncated = true;
                break :outer;
            }
            const c = weft.queryCapture(i) orelse continue;
            // Display the definition's first line (its signature).
            const line_end = weft.lineAt(c.start).end;
            const digest = digestRange(c.start, line_end) orelse continue;
            const text = weft.slice(c.start, line_end); // borrows scratch
            const target = weft.anchorRange(.{ .start = c.start, .end = line_end }) orelse continue;
            if (!weft.retainRange(target)) {
                weft.releaseRange(target);
                continue;
            }
            weft.pickAdd(text, ty);
            targets[n_rows] = .{ .range = target, .digest = digest };
            n_rows += 1;
        }
    }
    weft.pickEnd();
    if (truncated) weft.echo(std.fmt.comptimePrint("consult: >{d} symbols — some omitted", .{targets.len}));
}

comptime {
    weft.plugin(&cmds, .{}).exportAll();
}
