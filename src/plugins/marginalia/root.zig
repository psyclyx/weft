//! marginalia — pick-row annotations, the way Emacs' marginalia annotates
//! completion candidates. A file row gains size and age, a buffer row gains
//! its language and whether it has unsaved edits, a command row gains the key
//! that runs it.
//!
//! It is an ordinary plugin with no core privilege: it binds the
//! `ui/pick-annotate` slot core declares (`core/pick/annotate.zig`), reads the
//! rows core offers, and answers with a note per row. Core knows the exchange
//! and nothing else — what a "file" is, what "2h" means, and whether a size
//! should be shown at all are all decided here.
//!
//! **What it can say is bounded by what it can READ**, which is the whole
//! reason doc/marginalia.md put the introspection doors first:
//!
//!   · `file`/`dir` → `fsStat` (kind, size, mtime). Needs an `fs_read` grant;
//!     without one every file row silently gets nothing, which is the correct
//!     degradation — an annotator that cannot read has nothing to say.
//!   · `buffer`    → `bufferLang`/`bufferDirty`/`bufferByteLen`/`bufferTool`,
//!     matched to the row by the KEY core supplies (the buffer's path or
//!     name), never by parsing the display label.
//!   · `command`   → the keymap tables (`modeNames`/`bindingTable`), reverse
//!     -indexed to answer "which key runs this".
//!
//! Anything else — consult's lines, lsp's references, the shared list — is
//! declined: those rows mean something only inside their producer's own
//! table, and no outsider can resolve them. Declining is the honest answer,
//! not a gap.

const std = @import("std");
const weft = @import("weft");
const annotate = @import("weft_annotate");

// ── Config (`weft.set("marginalia", …)`), read once at init ───────────
//
// Every category is switchable, because "what belongs beside a row" is taste
// and this plugin has no business deciding it for anyone. `off` means the
// category is declined entirely rather than answered with an empty note —
// nothing to render and nothing to pay for.

var show_file = true;
var show_buffer = true;
var show_command = true;

/// The note for one row, built into this. Bounded: a row's annotation is a
/// glance, never a paragraph.
var note_buf: [128]u8 = undefined;
/// Room for the whole answer set — `annotate.batch` rows of note.
var notes_storage: [256][]const u8 = undefined;
var note_bytes: [256 * 128]u8 = undefined;
var note_used: usize = 0;

/// The keymap reverse index, built lazily per `command` round: which key runs
/// a command, in the mode the pick was opened from. Rebuilt each round rather
/// than cached — bindings change when a plugin loads or a config reloads, and
/// a stale "press SPC g s" is worse than none.
var table_buf: [1 << 15]u8 = undefined;
var mode_buf: [1 << 12]u8 = undefined;

export fn describe() void {
    // No commands: this plugin has no verbs. It answers a question and
    // nothing else, which is also why it needs no permission of its own
    // beyond whatever `fs_read` the config chooses to grant it.
    weft.requestPerm(.fs_read);
}

export fn init() void {
    // BIND, never declare: core declares `ui/pick-annotate` because core has
    // to decode the answers. A second declaration would be ignored anyway
    // (`Container.declareSlot` keeps the first), so binding is the honest
    // spelling of "I answer this".
    annotate.bind();

    show_file = !std.mem.eql(u8, weft.config("file"), "off");
    show_buffer = !std.mem.eql(u8, weft.config("buffer"), "off");
    show_command = !std.mem.eql(u8, weft.config("command"), "off");
}

const Category = enum { file, dir, buffer, command, other };

fn categoryOf(name: []const u8) Category {
    if (std.mem.eql(u8, name, "file")) return .file;
    if (std.mem.eql(u8, name, "dir")) return .dir;
    if (std.mem.eql(u8, name, "buffer")) return .buffer;
    if (std.mem.eql(u8, name, "command")) return .command;
    return .other;
}

fn enabled(c: Category) bool {
    return switch (c) {
        .file, .dir => show_file,
        .buffer => show_buffer,
        .command => show_command,
        .other => false,
    };
}

export fn on_slot_fire(session: i32) void {
    var round = annotate.ask(@bitCast(session)) orelse return;
    const category = categoryOf(round.category);
    if (!enabled(category)) return; // declined — not "answered with blanks"

    // The command index is built ONCE per round, not once per row: it walks
    // every mode's whole table, so per-row would be O(rows × bindings).
    const index: ?[]const u8 = if (category == .command) commandIndex() else null;

    note_used = 0;
    var n: usize = 0;
    while (round.next()) |row| {
        if (n == notes_storage.len) break;
        notes_storage[n] = store(noteFor(category, row.key, index));
        n += 1;
    }
    annotate.tell(@bitCast(session), round.from, notes_storage[0..n]);
}

/// Copy a note into the round's own storage — `note_buf` is reused by the
/// next row, and the answer is not encoded until every row has been visited.
fn store(note: []const u8) []const u8 {
    if (note.len == 0) return "";
    if (note_used + note.len > note_bytes.len) return "";
    const dst = note_bytes[note_used..][0..note.len];
    @memcpy(dst, note);
    note_used += note.len;
    return dst;
}

fn noteFor(category: Category, key: []const u8, index: ?[]const u8) []const u8 {
    return switch (category) {
        .file, .dir => fileNote(key),
        .buffer => bufferNote(key),
        .command => commandNote(key, index orelse return ""),
        .other => "",
    };
}

// ── file ─────────────────────────────────────────────────────────────

/// `12.4K  2h` — size and age. A directory shows no size (its `st_size` is a
/// property of the directory entry, not of what is in it, and reporting it as
/// though it were a byte count is the kind of thing that reads as a bug).
///
/// Silent when the stat says absent: with no `fs_read` grant every path
/// answers absent, so an ungranted marginalia annotates nothing rather than
/// filling the column with a lie about a missing file.
fn fileNote(path: []const u8) []const u8 {
    const st = weft.fsStat(path);
    return switch (st.kind) {
        .none => "",
        .dir => "dir",
        .file, .other => std.fmt.bufPrint(&note_buf, "{s}  {s}", .{
            humanSize(st.size),
            humanAge(st.mtime_ns),
        }) catch "",
    };
}

var size_buf: [16]u8 = undefined;

fn humanSize(bytes: u64) []const u8 {
    const units = [_][]const u8{ "B", "K", "M", "G", "T" };
    var v: f64 = @floatFromInt(bytes);
    var u: usize = 0;
    while (v >= 1024 and u + 1 < units.len) : (u += 1) v /= 1024;
    // Whole numbers below the first divisor read better without a decimal:
    // "512B", not "512.0B".
    if (u == 0) return std.fmt.bufPrint(&size_buf, "{d}B", .{bytes}) catch "";
    return std.fmt.bufPrint(&size_buf, "{d:.1}{s}", .{ v, units[u] }) catch "";
}

var age_buf: [16]u8 = undefined;

/// A coarse age. Deliberately not a timestamp: the question a file row
/// answers is "recent or not", and a full date costs more columns than it
/// earns. Needs the wall clock, which a plugin has no door for — so it is
/// derived from the NEWEST mtime seen this round, making it relative rather
/// than absolute. Honest and useful: the newest file in a listing reads
/// "now" and everything else reads as older than it.
var newest_mtime: i64 = 0;

fn humanAge(mtime_ns: i64) []const u8 {
    if (mtime_ns > newest_mtime) newest_mtime = mtime_ns;
    const delta_s = @divTrunc(newest_mtime - mtime_ns, std.time.ns_per_s);
    if (delta_s < 60) return "now";
    if (delta_s < 3600) return std.fmt.bufPrint(&age_buf, "{d}m", .{@divTrunc(delta_s, 60)}) catch "";
    if (delta_s < 86400) return std.fmt.bufPrint(&age_buf, "{d}h", .{@divTrunc(delta_s, 3600)}) catch "";
    return std.fmt.bufPrint(&age_buf, "{d}d", .{@divTrunc(delta_s, 86400)}) catch "";
}

// ── buffer ───────────────────────────────────────────────────────────

/// `zig  1.2K  ●` — language, size, and a dot for unsaved edits.
///
/// Matched by the KEY core supplied (a path, or the display name for an
/// unbacked entry), never by parsing the label: `"3: foo.zig [ro] *"` is
/// display text and reverse-engineering an identity out of it is exactly the
/// class of bug the key exists to remove.
fn bufferNote(key: []const u8) []const u8 {
    const i = bufferIndexFor(key) orelse return "";
    const tool = weft.bufferTool(i) orelse "";
    // A projection is not a file: no language, no size, and never dirty
    // (core's `hasUnsavedFile` already refuses to call one dirty). Naming
    // the tool is the useful thing to say about it.
    if (tool.len > 0) return std.fmt.bufPrint(&note_buf, "{s}", .{tool}) catch "";

    const lang = weft.bufferLang(i) orelse "";
    const len = weft.bufferByteLen(i) orelse 0;
    const dirty = weft.bufferDirty(i) orelse false;
    const size = humanSize(len);
    return (if (lang.len > 0)
        std.fmt.bufPrint(&note_buf, "{s}  {s}{s}", .{ lang, size, if (dirty) "  ●" else "" })
    else
        std.fmt.bufPrint(&note_buf, "{s}{s}", .{ size, if (dirty) "  ●" else "" })) catch "";
}

/// The open-buffer index whose path (or name) is `key`. A linear walk, and
/// it stays one: a buffer list is tens of entries, and a cache would have to
/// be invalidated by every open and close.
fn bufferIndexFor(key: []const u8) ?usize {
    const n = weft.bufferCount();
    var i: usize = 0;
    while (i < n) : (i += 1) {
        if (weft.bufferPath(i)) |path| {
            if (std.mem.eql(u8, path, key)) return i;
        }
        // An unbacked entry (a scratch, a projection) is keyed by name —
        // the same fallback `wl_pick_add_buffer` used when it built the key.
        if (weft.bufferName(i)) |name| {
            if (std.mem.eql(u8, name, key)) return i;
        }
    }
    return null;
}

// ── command ──────────────────────────────────────────────────────────

/// Every mode's resolved bindings, concatenated into one `<key>\t<command>`
/// listing. `commandNote` scans it; building it once per round is what keeps
/// a palette over hundreds of commands from being quadratic in bindings.
///
/// Every mode, not just the current one, because a palette is opened FROM
/// somewhere and the pick's own mode is "pick" by then — so "the mode you
/// were in" is not readable here. Showing the key wherever it is bound is
/// more useful than showing none, and a command bound in exactly one mode
/// (the overwhelming case) is unambiguous either way.
fn commandIndex() ?[]const u8 {
    const modes = weft.modeNames(&mode_buf) orelse return null;
    var used: usize = 0;
    var it = std.mem.splitScalar(u8, modes, '\n');
    while (it.next()) |mode| {
        if (mode.len == 0) continue;
        const listing = weft.bindingTable(mode, table_buf[used..]) orelse continue;
        used += listing.len;
        if (used >= table_buf.len) break;
        table_buf[used] = '\n';
        used += 1;
    }
    return table_buf[0..used];
}

/// The first key bound to `command`, or "".
fn commandNote(command: []const u8, index: []const u8) []const u8 {
    var rows = weft.bindingRows(index);
    while (rows.next()) |row| {
        if (!std.mem.eql(u8, row.command, command)) continue;
        return std.fmt.bufPrint(&note_buf, "{s}", .{row.key}) catch "";
    }
    return "";
}
