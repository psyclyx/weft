//! The command-output surface shared by `run`, `make`, and `grep`: create the
//! tool buffer, capture each row's typed location when the output lands, and
//! visit the focused row from that table (architecture §14.6 — locations are
//! carried as values, never recovered by parsing rendered text). A consumer
//! plugin binds its own mode + visit command to these; nothing here reaches
//! into another plugin's state.
//!
//! The rows are a PROJECTION now, and that is what closes §14.6's last gap.
//! The table was already typed, but it was indexed by ROW NUMBER, so the
//! mapping from "where the cursor is" to "which location" ran through a count
//! of newlines before the caret (`cursorRow`) — position as identity, the exact
//! thing the rest of this file was written to avoid. A row is a node with a KEY
//! now; the cursor resolves to that key, and the key indexes the table.
//!
//! What went with it: `cursorRow`'s chunked scan, the `base + i` offset
//! arithmetic threading through the fill, and `weft.style` — a row's location
//! is painted by a SPAN over the node's own text (`Builder.span`), so this
//! library names no document offset at all. The one offset left is
//! `lineStartOffset`, which is about the FILE being visited, not about this
//! buffer: jumping to line 40 of a source file is an ordinary navigation.

const std = @import("std");
const weft = @import("weft");
const targets = @import("targets.zig");

pub const Target = targets.Target;

/// One output buffer's captured rows. A plugin owns a handful of output
/// buffers (`*output*`, `*build*`, `*test*`, `*grep*`), each with its own
/// table — a per-buffer value, not one singleton for whichever fill was last.
const Slot = struct {
    name: []u8,
    table: targets.Table = .{},
};

/// One per output buffer, minted on first use and kept for `visit` to read
/// after the command is long finished.
var slots: [4]Slot = undefined;
var slot_count: usize = 0;

/// Install the navigation shape every output buffer shares: Return visits the
/// focused row through `visit_cmd`, j/k walk, q goes back. The mode falls back
/// to `normal` (not LOCKED) so a visit leaves cleanly into the file's own mode,
/// and rests in itself so the shell never forces normal on a tool buffer.
pub fn installMode(mode: []const u8, visit_cmd: []const u8) void {
    weft.setFallback(mode, "normal");
    weft.restingMode(mode);
    weft.bindKey(mode, "Return", visit_cmd);
    weft.bindKey(mode, "j", "cursor-down");
    weft.bindKey(mode, "k", "cursor-up");
    weft.bindKey(mode, "Down", "cursor-down");
    weft.bindKey(mode, "Up", "cursor-up");
    weft.bindKey(mode, "q", "buffer-back");
}

/// What a producer may add to one row while the raw text is in hand: its own
/// spans, over the node it was just given. `grep` emphasises the match.
pub const RowStyle = *const fn (b: weft.ProjectionBuilder, node: u32, line: []const u8, at: ?Target) void;

/// One request, carried to its own continuation.
///
/// This replaced the FILL TOKEN, which was an integer the host handed back so a
/// landing fill could find its own table. It worked, and it was a demux: the
/// request and the thing it was for travelled separately, so the library kept a
/// slot table indexed by a number the host had to be trusted to return
/// unchanged. What the command was for now travels with the command.
const Request = struct {
    slot: usize,
    row_style: ?RowStyle,
    /// Whether stderr is worth showing. A build's errors are on stderr — which
    /// is exactly what `make` exists to let you navigate, and exactly what the
    /// stdout-only fill door silently dropped.
    want_err: bool,
};

/// Focus the `name` tool buffer (reused across runs — `buffer-create` does NOT
/// dedupe by name, so re-creating would pile up duplicates), put it in `mode`,
/// and run `argv`, publishing its output as a projection when it lands.
///
/// ARGV, not a shell line. `grep` used to build `rg … -- '{s}'` and say out
/// loud that a pattern containing a single quote was "the one gap left for a
/// later version"; there is no quoting here to have a gap in. A caller that
/// genuinely wants a shell — `run`, whose whole purpose is running a shell
/// command — spells it `&.{ "sh", "-c", line }`, which is one argument and one
/// deliberate decision rather than a string that happens to reach a shell.
pub fn show(argv: []const []const u8, name: []const u8, mode: []const u8, opts: struct {
    row_style: ?RowStyle = null,
    want_err: bool = false,
}) void {
    const slot = slotFor(name) orelse return;
    if (!focus(name)) weft.runStr("buffer-create", name);
    weft.setMode(mode);
    _ = weft.execWith(Request, .{
        .slot = slot,
        .row_style = opts.row_style,
        .want_err = opts.want_err,
    }, .{ .argv = argv }, landed);
}

/// The command finished: publish what it wrote as the buffer's projection.
/// Nothing is read back out of the buffer — the bytes are right here, which is
/// what the fill door could never say.
fn landed(r: weft.ExecDone, req: Request) void {
    var scratch: [1 << 16]u8 = undefined;
    const out = r.read(.out, 0, &scratch);
    if (out.len > 0 or !req.want_err) return fill(req, out);
    // A build that printed nothing to stdout said whatever it had to say on
    // stderr; showing an empty buffer instead is the failure mode this exists
    // to end.
    var err_scratch: [1 << 16]u8 = undefined;
    fill(req, r.read(.err, 0, &err_scratch));
}

/// A row that names a place, and one that does not. Roles rather than a boolean
/// because a role is what a THIRD PARTY binds a verb against — it `provide`s
/// against `.{ .role = "output.result" }` and reaches every result row without
/// knowing which of run/make/grep produced it, or that they exist. Neither role
/// styles as a whole row, so the location stays the only lit part.
const role_result = "output.result";
const role_note = "output.note";
/// The `path:line:col` stretch inside a result row.
const role_location = "output.location";

/// Publish `text` as the buffer's projection — one node per line, each carrying
/// its location in the table.
///
/// `text` is the command's own output, still in the continuation's hands. The
/// predecessor wrote it into the buffer first and then read it all back out in
/// scratch-sized chunks, re-splitting it into lines a second time, because the
/// fill door delivered "your output has landed somewhere" rather than the
/// output. This is the ONE moment the text is authoritative; from here on it is
/// display, and the projection is what makes that literally true — nothing
/// downstream reads a byte of it.
fn fill(req: Request, text: []const u8) void {
    const slot = &slots[req.slot];
    slot.table.clear(weft.allocator);
    const b = weft.project(slot.name) orelse return;
    var i: usize = 0;
    while (i < text.len) {
        var e = i;
        while (e < text.len and text[e] != '\n') e += 1;
        emitRow(slot, b, text[i..e], req.row_style);
        i = e + 1;
    }
    _ = b.commit();
}

/// One row: its location into the table, its text into the tree, and the key
/// that ties them. The key is the table INDEX — a handle into a table this
/// library owns, minted here and never parsed out of anything rendered.
fn emitRow(slot: *Slot, b: weft.ProjectionBuilder, line: []const u8, row_style: ?RowStyle) void {
    const index = slot.table.len();
    slot.table.push(weft.allocator, line) catch return;
    const at = slot.table.get(index);

    var key_buf: [24]u8 = undefined;
    const key = std.fmt.bufPrint(&key_buf, "r{d}", .{index}) catch return;
    const node = b.add(.{
        .key = key,
        .role = if (at != null) role_result else role_note,
        .text = line,
        // Only a row that names a place is somewhere a verb can act, so only
        // that kind is where a fresh render lands.
        .focusable = at != null,
    }) orelse return;

    if (at) |target| b.span(node, target.span_start, target.span_end, role_location);
    if (row_style) |paint| paint(b, node, line, at);
}

/// Return in an output buffer: open the location the FOCUSED ROW carries. The
/// rendered line is never re-read — a row restyled or reformatted after the
/// fill still visits where its output pointed.
///
/// A buffer this plugin never filled — or one past its table complement — says
/// so rather than falling back to reading the screen: a silent re-parse would
/// re-introduce exactly the coupling this table removes.
pub fn visit() void {
    const name = activeName() orelse return;
    defer weft.allocator.free(name);
    const slot = find(name) orelse {
        weft.echo("output: this fill landed without captured locations");
        return;
    };
    // The KEY under the cursor, not a count of the newlines above it. The host
    // hit-tests its own rendering; this library never learns where the caret is.
    const key = weft.projectionAtCursor() orelse return;
    const target = slot.table.get(indexOfKey(key) orelse return) orelse return;
    // The path is the table's; `open` reuses the read scratch, not this.
    weft.runStr("open", target.path);
    var at = lineStartOffset(target.line);
    if (target.col > 1) at = @min(at + target.col - 1, weft.lineAt(at).end);
    weft.jump(at);
}

/// `"r12"` → 12. The inverse of the key `emitRow` minted, and the only place
/// this format is read — a handle into our own table, not a parse of anything
/// the user can see or an external tool wrote.
fn indexOfKey(key: []const u8) ?usize {
    if (key.len < 2 or key[0] != 'r') return null;
    return std.fmt.parseInt(usize, key[1..], 10) catch null;
}

/// Byte offset of the start of 1-based line `n` in the active buffer (clamped
/// to EOF), scanning in scratch-sized chunks so a long file still resolves.
fn lineStartOffset(n: usize) usize {
    if (n <= 1) return 0;
    var line: usize = 1;
    var pos: usize = 0;
    const total = weft.byteLen();
    while (pos < total) {
        const chunk = weft.slice(pos, total);
        if (chunk.len == 0) break;
        for (chunk, 0..) |ch, k| {
            if (ch == '\n') {
                line += 1;
                if (line == n) return pos + k + 1;
            }
        }
        pos += chunk.len;
    }
    return pos;
}

/// The active buffer's name, copied out of the read scratch (a name outgrows
/// any fixed buffer). Caller frees.
fn activeName() ?[]u8 {
    const count = weft.bufferCount();
    var i: usize = 0;
    while (i < count) : (i += 1) {
        if (!weft.bufferActive(i)) continue;
        const name = weft.bufferName(i) orelse return null;
        return weft.allocator.dupe(u8, name) catch null;
    }
    return null;
}

/// `name`'s slot index, minting it on first use; null when this plugin already
/// tracks its full complement of output buffers.
fn slotFor(name: []const u8) ?usize {
    for (slots[0..slot_count], 0..) |*slot, i| {
        if (std.mem.eql(u8, slot.name, name)) return i;
    }
    if (slot_count == slots.len) return null;
    slots[slot_count] = .{ .name = weft.allocator.dupe(u8, name) catch return null };
    slot_count += 1;
    return slot_count - 1;
}

/// Focus the buffer named `name`, if one is open.
fn focus(name: []const u8) bool {
    const count = weft.bufferCount();
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const other = weft.bufferName(i) orelse continue;
        if (!std.mem.eql(u8, other, name)) continue;
        const id = weft.bufferId(i) orelse return false;
        weft.runInt("buffer-switch", id);
        return true;
    }
    return false;
}

fn find(name: []const u8) ?*Slot {
    for (slots[0..slot_count]) |*slot| {
        if (std.mem.eql(u8, slot.name, name)) return slot;
    }
    return null;
}
