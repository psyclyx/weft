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
    /// The run filling this buffer now; a new run kills it.
    run: ?weft.Process = null,
    /// Lines the run has said since the rows were last published (owned).
    pending: std.ArrayList([]u8) = .empty,
    /// Rows this run has published.
    rows: usize = 0,
};

/// The most rows one run publishes. A tool that never stops talking (`yes`)
/// must not grow a buffer without bound: past this its run is stopped, and
/// the buffer says so.
const max_rows = 200_000;

/// One per output buffer, minted on first use and kept for `visit` to read
/// after the command is long finished. As many as the plugin's buffers: a
/// fixed table here once meant a fifth conversation's reply went nowhere.
var slots: std.ArrayList(Slot) = .empty;

/// Install the navigation shape every output buffer shares: Return visits the
/// focused row through `visit_cmd`, j/k walk, q goes back. This mode is its
/// own key context: inheriting `normal` exposed editing and code commands on
/// generated output. Visiting a file switches to that file's resting mode.
pub fn installMode(mode: []const u8, visit_cmd: []const u8) void {
    weft.restingMode(mode);
    weft.bindKey(mode, "Return", visit_cmd);
    weft.bindKey(mode, "j", "cursor.down");
    weft.bindKey(mode, "k", "cursor.up");
    weft.bindKey(mode, "Down", "cursor.down");
    weft.bindKey(mode, "Up", "cursor.up");
    weft.bindKey(mode, "q", "buffer.back");
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
    /// The context key that says this run is going (`Running`), and the place
    /// it was said on, where it is retracted when the run lands.
    running_key: []const u8 = "",
    /// Told the exit code once the run is over and its rows are published.
    exit: ?*const fn (code: i32) void = null,
    place: [1100]u8 = undefined,
    place_len: usize = 0,
};

/// What a producer says while its command runs: `key` (its own,
/// `make.running`) is `what` (`build`) on the place the run started in, and
/// empty again when the output lands. A context key, so a predicate can read
/// it — and so the status line, whose answers are about the context, asks
/// the producer again the moment a run starts or ends.
pub const Running = struct { key: []const u8, what: []const u8 };

/// What `key` says is running in the primary context, or null for nothing —
/// what a producer's status segment shows.
pub fn runningHere(key: []const u8) ?[]const u8 {
    const what = weft.contextGet(key) orelse return null;
    return if (what.len == 0) null else what;
}

/// Focus the `name` tool buffer (reused across runs — `buffer.create` does NOT
/// dedupe by name, so re-creating would pile up duplicates), put it in `mode`,
/// and run `argv`, its output published as rows WHILE IT RUNS: each batch the
/// process writes is appended (`weft.projectAppendLines`), at the cost of the
/// batch. A run already filling this buffer is stopped first.
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
    running: ?Running = null,
    /// What the tool reads on stdin (a prompt), sent and then closed. Null:
    /// its stdin is the null device.
    input: ?[]const u8 = null,
    /// Told the exit code once the run is over and its rows are published —
    /// what a tool that says nothing on success needs to be heard succeeding.
    exit: ?*const fn (code: i32) void = null,
}) void {
    const slot = slotFor(name) orelse return;
    weft.focusOrCreateBuffer(name);
    weft.setMode(mode);
    stop(slot);
    var req: Request = .{
        .slot = slot,
        .row_style = opts.row_style,
        .want_err = opts.want_err,
        .exit = opts.exit,
    };
    // A fresh run starts from an empty buffer.
    slots.items[slot].table.clear(weft.allocator);
    slots.items[slot].rows = 0;
    _ = weft.projectLines(slots.items[slot].name, "", Request, req, emitRow);
    if (opts.running) |r| if (weft.placeDesignation(&req.place)) |place| {
        req.place_len = place.len;
        req.running_key = r.key;
        weft.contextSetAt(r.key, r.what, place) catch {};
    };
    // A build's errors are on stderr: they ARE its output, in the order written.
    slots.items[slot].run = weft.spawnWith(Request, req, .{ .argv = argv, .merge_stderr = opts.want_err, .duplex = opts.input != null }, Stream);
    const run = slots.items[slot].run orelse {
        settle(req);
        weft.echo("output: the command could not be started");
        return;
    };
    if (opts.input) |bytes| {
        run.send(bytes);
        run.closeInput();
    }
}

/// Stop the run filling `slot`, if any, dropping what it had not published.
fn stop(slot: usize) void {
    const s = &slots.items[slot];
    if (s.run) |proc| proc.kill();
    s.run = null;
    dropPending(s);
}

fn dropPending(s: *Slot) void {
    for (s.pending.items) |line| weft.allocator.free(line);
    s.pending.clearRetainingCapacity();
}

/// What the run says, as it says it.
const Stream = struct {
    pub fn line(req: Request, text: []const u8) void {
        const s = &slots.items[req.slot];
        if (s.rows + s.pending.items.len >= max_rows) return;
        const owned = weft.allocator.dupe(u8, text) catch return;
        s.pending.append(weft.allocator, owned) catch {
            weft.allocator.free(owned);
            return;
        };
        if (s.rows + s.pending.items.len < max_rows) return;
        // Full: publish, say so, and stop the run (no exit will follow a kill).
        publish(req);
        var note: [96]u8 = undefined;
        const said = std.fmt.bufPrint(&note, "… stopped after {d} lines", .{max_rows}) catch "… stopped";
        _ = weft.projectAppendLines(s.name, &.{said}, s.rows, Request, req, emitRow);
        s.rows += 1;
        settle(req);
        stop(req.slot);
    }

    /// Once per batch: publish what the batch said.
    pub fn drained(req: Request) void {
        publish(req);
    }

    pub fn exit(req: Request, code: i32, stderr: []const u8) void {
        _ = stderr;
        publish(req);
        settle(req);
        slots.items[req.slot].run = null;
        if (req.exit) |f| f(code);
    }
};

/// Append the lines said since the last publish as rows.
fn publish(req: Request) void {
    const s = &slots.items[req.slot];
    if (s.pending.items.len == 0) return;
    const lines: []const []const u8 = @ptrCast(s.pending.items);
    if (weft.projectAppendLines(s.name, lines, s.rows, Request, req, emitRow)) s.rows += lines.len;
    dropPending(s);
}

/// The run is over: say so where it was said to be going.
fn settle(req: Request) void {
    if (req.running_key.len == 0) return;
    weft.contextSetAt(req.running_key, "", req.place[0..req.place_len]) catch {};
}

// ── What an output entry IS (doc/model.md §2.1) ──────────────────────
//
// An output entry is a PROJECTION: a producer's run in a place, named
// `weft://here/<kind>/<place>[?params]`. Named that way, a jump back to a
// closed `*grep*`, or a viewport showing one again, re-runs the producer
// rather than remembering a buffer slot — and a producer can only re-run in
// the place it was run in, because where a spawn runs is the dispatch's
// place, never something a guest names.

var named_buf: [4096]u8 = undefined;

/// Declare the entry `show` just focused to be `kind` run in this place,
/// with `params` (already encoded — `encodeParam`). The producer must have
/// claimed `kind` (`weft.designationOpener`).
pub fn designate(kind: []const u8, params: []const u8) void {
    const text = weft.placeProjection(kind, params, &named_buf) orelse return;
    _ = weft.designate(text);
}

var reopen_buf: [4096]u8 = undefined;

/// For a producer's opener: the designation it was handed (arg 0), when it
/// names a run of `kind` in the place this dispatch is in. Anything else is
/// said and answered null — a run elsewhere cannot be repeated from here.
/// Borrows a buffer the next call reuses.
pub fn reopening(kind: []const u8) ?weft.semantic.durable.Designation {
    const arg = weft.argStr(0) orelse return null;
    const n = @min(arg.len, reopen_buf.len);
    @memcpy(reopen_buf[0..n], arg[0..n]);
    const d = weft.semantic.durable.parse(reopen_buf[0..n]) orelse {
        weft.echo("open: not a designation this producer answers");
        return null;
    };
    if (d.kind != .projection or !std.mem.eql(u8, d.kind.projection, kind)) {
        weft.echo("open: not a designation this producer answers");
        return null;
    }
    var place_buf: [4096]u8 = undefined;
    const place = weft.placeOf(d, &place_buf) orelse return null;
    if (!std.mem.eql(u8, place, weft.placeRoot())) {
        var msg: [4200]u8 = undefined;
        weft.echo(std.fmt.bufPrint(&msg, "{s}: that ran in {s} — open it from there", .{ kind, place }) catch "that ran in another place");
        return null;
    }
    return d;
}

/// `raw` as a view-parameter value: every byte but `[A-Za-z0-9._-]` as
/// `%XX`, so a pattern with `&`, `?` or a space cannot break the grammar.
pub fn encodeParam(raw: []const u8, out: []u8) ?[]const u8 {
    var w: usize = 0;
    for (raw) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '.' or c == '_' or c == '-') {
            if (w >= out.len) return null;
            out[w] = c;
            w += 1;
        } else {
            if (w + 3 > out.len) return null;
            _ = std.fmt.bufPrint(out[w..][0..3], "%{X:0>2}", .{c}) catch return null;
            w += 3;
        }
    }
    return out[0..w];
}

/// `encodeParam` undone. Null for a malformed escape.
pub fn decodeParam(enc: []const u8, out: []u8) ?[]const u8 {
    var w: usize = 0;
    var i: usize = 0;
    while (i < enc.len) : (w += 1) {
        if (w >= out.len) return null;
        if (enc[i] == '%') {
            if (i + 3 > enc.len) return null;
            out[w] = std.fmt.parseInt(u8, enc[i + 1 .. i + 3], 16) catch return null;
            i += 3;
        } else {
            out[w] = enc[i];
            i += 1;
        }
    }
    return out[0..w];
}

test "output: a view parameter round-trips any bytes" {
    var enc: [64]u8 = undefined;
    var dec: [64]u8 = undefined;
    const e = encodeParam("don't & ?x=1", &enc).?;
    try std.testing.expect(std.mem.indexOfAny(u8, e, "&?= '") == null);
    try std.testing.expectEqualStrings("don't & ?x=1", decodeParam(e, &dec).?);
}

const role_result = "output.result";
const role_note = "output.note";
/// The `path:line:col` stretch inside a result row.
const role_location = "output.location";

/// One row of output as a node, its location (if it names one) captured into
/// the table the row's key indexes. This is the ONE moment the text is
/// authoritative; from here on it is display — nothing downstream reads a
/// byte of it.
fn emitRow(b: weft.ProjectionBuilder, req: Request, ordinal: usize, line: []const u8) void {
    _ = ordinal;
    const slot = &slots.items[req.slot];
    const row_style = req.row_style;
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
    visitTarget(target);
}

/// Open the file `target` names, the caret on its line (and column).
pub fn visitTarget(target: Target) void {
    // The path is the caller's (a table's, an answer's); `open` reuses the
    // read scratch, not this. Relative to where the tool ran: this entry's
    // place (it inherited the place it was produced in, doc/place.md §2.1).
    weft.openTyped(target.path);
    var at = lineStartOffset(target.line);
    if (target.col > 1) at = @min(at + target.col - 1, weft.lineAt(at).end);
    weft.jump(at);
}

/// The location an output line names (`path:line[:col]`), if any.
pub const locate = targets.parse;

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
    for (slots.items, 0..) |*slot, i| {
        if (std.mem.eql(u8, slot.name, name)) return i;
    }
    const owned = weft.allocator.dupe(u8, name) catch return null;
    slots.append(weft.allocator, .{ .name = owned }) catch {
        weft.allocator.free(owned);
        return null;
    };
    return slots.items.len - 1;
}

fn find(name: []const u8) ?*Slot {
    for (slots.items) |*slot| {
        if (std.mem.eql(u8, slot.name, name)) return slot;
    }
    return null;
}
