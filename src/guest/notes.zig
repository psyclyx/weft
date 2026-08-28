//! notes — capture + review over plain files (design §6.6, org-lite), a `.wasm`
//! plugin. `notes-capture` appends a line to a notes file via `fs.append`;
//! `notes-open` opens it through the ordinary `open` path — a real,
//! path-backed buffer (dedupes, editable, adopts the path if the file is new)
//! — not a copy into an unrelated scratch buffer. perms `{fs_read, fs_write}`;
//! `open` is a host command, not an `fs.read` import, so no read grant is
//! needed for that. Agenda/backlinks (grep over the notes) compose the consult
//! + proc plugins; capture into a shared vault is inherently multiplayer once
//! the file is a CRDT document.
//!
//! EMBEDS (architecture §11.8 depth 1, doc/cwa-config-decisions.md stress-test
//! 2). A note may point at a live thing with an embed line — the `@embed`
//! marker plus one durable `weft://` designation (`weft.semantic.durable`).
//! The line IS the storage form and the fallback form: this plugin never
//! rewrites the note. It claims an ANNOTATION layer on the note entry
//! (§11.7 — a referenced entry it does not own), resolves each designation,
//! and publishes one decoration per embed. An embed that cannot resolve
//! publishes its reason instead, beside the line that still reads as itself;
//! an embed never errors its host, and resolution never runs on the typing
//! path — the round fires on entry activation and on `notes-embeds`, and the
//! §11.7 revision stamp drops the whole set the moment the note is edited,
//! until the next round.
//!
//! v1 resolves `here` file and directory designations through the ordinary
//! `fs` doors. Any other kind (a `commit` OID, a peer, a shell) parses,
//! serializes, and degrades to its textual form plus a reason — the git
//! plugin's commit surface is async proc output with no synchronous
//! description door to ask, so notes states that rather than guessing.
//!
//! Two limits are the membrane's, not this plugin's, and are stated rather
//! than worked around: a guest has no viewport door, so a round resolves the
//! whole scanned note instead of only what is on screen (§11.6 windowing is
//! the missing half of "lazily"); and a pushed offer table is scoped by
//! ENTRY, not by cursor line, so `std.target.activate` is offered while a
//! note holding embeds is focused and `notes-embed-activate` says so when the
//! cursor is elsewhere in it.

const std = @import("std");
const weft = @import("weft");

const durable = weft.semantic.durable;

const default_file = "weft-notes.md";
const layer_name = "notes.embeds";
/// How much of a note one round reads. A larger note is reported partial at
/// the boundary rather than silently half-decorated (§15.14).
const scan_window = 1 << 16;
/// Notes decorated at once. Bounded on purpose: a decorator holds a fixed
/// number of targets and refuses past it.
const max_notes = 4;
const max_embeds = 32;

var line_buf: [1 << 12]u8 = undefined;
var note_buf: [scan_window]u8 = undefined;
var body_buf: [512]u8 = undefined;

const Note = struct { entry: u32, anno: weft.Annotations };
var notes: [max_notes]?Note = @splat(null);
/// Bumped per published round so a decision resolved against an older model
/// dies at the effect door.
var round: u32 = 0;
var offering = false;

const Cmd = struct { name: []const u8, handler: *const fn () void };
const cmds = [_]Cmd{
    .{ .name = "notes-capture", .handler = capture },
    .{ .name = "notes-open", .handler = open },
    .{ .name = "notes-capture-here", .handler = captureHere },
    .{ .name = "notes-embeds", .handler = embedsRefresh },
    .{ .name = "notes-embeds-off", .handler = embedsOff },
    .{ .name = "notes-embed-activate", .handler = embedActivate },
};

export fn describe() void {
    for (cmds) |c| weft.declareCommand(c.name);
    weft.requestPerm(.fs_read);
    weft.requestPerm(.fs_write);
}
export fn init() void {
    for (cmds) |c| _ = weft.register(c.name);
}
export fn on_command(id: u32) void {
    if (id < cmds.len) cmds[id].handler();
}

/// A note takes focus: publish its embeds, and offer activation exactly while
/// an entry that HAS embeds is focused. Buffer-granular eligibility is as fine
/// as a pushed offer table gets today — there is no cursor-motion feed to
/// republish against, so `notes-embed-activate` says so when the cursor is not
/// on an embed line rather than guessing another arm's meaning.
export fn on_activate() void {
    const entry = activeEntry() orelse return offerActivate(false);
    offerActivate(refresh(entry) > 0);
}

/// Append arg0 (the entry) + newline to the notes file (arg1, or the default).
/// arg0 is copied out first — a second `argStr` reuses the shared arg scratch.
fn capture() void {
    const text = weft.argStr(0) orelse return;
    const n = @min(text.len, line_buf.len - 1);
    @memcpy(line_buf[0..n], text[0..n]);
    line_buf[n] = '\n';
    const path = weft.argStr(1) orelse default_file;
    _ = weft.fsAppend(path, line_buf[0 .. n + 1]);
}

/// Open the notes file (arg0, or the default) as the note target itself —
/// the real file, not a copy.
fn open() void {
    const path = weft.argStr(0) orelse default_file;
    weft.runStr("open", path);
}

// ── Capture: where I am, as a durable embed ─────────────────────────

/// Append an embed line naming the focused entry and the cursor position to
/// the notes file (arg0, or the default). What is stored is a designation, not
/// a copy: reopening the note and activating the line lands back here.
fn captureHere() void {
    const path = weft.path() orelse return weft.echo("notes: this entry has no durable target");
    const n = @min(path.len, line_buf.len);
    @memcpy(line_buf[0..n], path[0..n]);
    var params: [32]u8 = undefined;
    const at = std.fmt.bufPrint(&params, "at={d}", .{weft.cursor()}) catch return;
    var out: [1 << 10]u8 = undefined;
    const line = durable.renderEmbed(.{
        .kind = .file,
        .ref = line_buf[0..n],
        .params = at,
    }, out[0 .. out.len - 1]) catch return weft.echo("notes: that target does not fit one line");
    out[line.len] = '\n';
    const file = weft.argStr(0) orelse default_file;
    if (!weft.fsAppend(file, out[0 .. line.len + 1])) return weft.echo("notes: could not append");
    weft.echo("notes: captured");
}

// ── Activation: an embed line is a target ───────────────────────────

/// Open what the embed line under the cursor designates, at the position it
/// captured. The `std.target.activate` answer for a note.
fn embedActivate() void {
    const line = weft.lineAt(weft.cursor());
    const text = weft.slice(line.start, line.end);
    const n = @min(text.len, line_buf.len);
    @memcpy(line_buf[0..n], text[0..n]);
    const d = durable.embedOf(line_buf[0..n]) orelse
        return weft.echo("notes: no embed on this line");
    if (d.authority != .here) return weft.echo("notes: that locus is not reachable from here");
    switch (d.kind) {
        .file, .directory => {
            weft.runStr("open", d.ref);
            if (d.param("at")) |raw| {
                const at = std.fmt.parseUnsigned(usize, raw, 10) catch return;
                weft.jump(@min(at, weft.byteLen()));
            }
        },
        else => weft.echo("notes: nothing here opens that kind"),
    }
}

/// Publish or withdraw this plugin's `std.target.activate` answer. Absence is
/// nonapplicable, so a note without embeds leaves `Return` to whatever the
/// grammar bound after it (§9.3).
fn offerActivate(wanted: bool) void {
    if (!wanted) {
        if (offering) weft.offersRetract();
        offering = false;
        return;
    }
    // Republished per round, stamped with the round it describes: a decision
    // resolved against a superseded scan dies at the effect door.
    weft.offersBegin("", round);
    weft.offer("std.target.activate", "notes-embed-activate", "");
    weft.offersCommit();
    offering = true;
}

// ── Embeds: resolve, publish, degrade ───────────────────────────────

fn embedsRefresh() void {
    const entry = activeEntry() orelse return weft.echo("notes: no entry here");
    const found = refresh(entry);
    offerActivate(found > 0);
    if (found == 0) weft.echo("notes: no embeds in this entry");
}

fn embedsOff() void {
    const entry = activeEntry() orelse return;
    release(slot(entry) orelse return);
    offerActivate(false);
}

/// One publish round over `entry`: every embed line gets a decoration, either
/// its resolved body or its reason. Returns how many embeds the note holds.
fn refresh(entry: u32) usize {
    const held = slot(entry) orelse freeSlot() orelse {
        weft.log(.warn, "notes: too many decorated entries; this one shows no embeds");
        return 0;
    };
    if (held.* == null) {
        const anno = weft.Annotations.open(entry, layer_name) orelse return 0;
        held.* = .{ .entry = entry, .anno = anno };
    }
    const anno = held.*.?.anno;
    if (!anno.begin()) {
        held.* = null;
        return 0;
    }
    round +%= 1;
    const len = anno.byteLen();
    const scanned = @min(len, note_buf.len);
    const text = anno.read(0, scanned, &note_buf);
    var found: usize = 0;
    var at: usize = 0;
    while (at < text.len) {
        const nl = std.mem.indexOfScalarPos(u8, text, at, '\n') orelse text.len;
        if (durable.embedOf(text[at..nl])) |d| {
            if (found == max_embeds) {
                mark(anno, at, "[embeds: past this line the note holds more than this round shows] ");
                break;
            }
            found += 1;
            mark(anno, at, render(d));
        }
        at = nl + 1;
    }
    if (scanned < len)
        mark(anno, scanned, "[embeds: the note is longer than one scan window] ");
    if (found == 0) release(held);
    return found;
}

/// One decoration anchored at the embed line's start. `virtual_before` is the
/// placement the text presentation lays out today; the body reads beside the
/// line whose designation produced it.
fn mark(anno: weft.Annotations, at: usize, body: []const u8) void {
    anno.span(at, at, .muted, .virtual_before, body);
}

/// Resolve one designation into a display body, or into its reason. Both are
/// the same kind of answer: an embed never fails its host (§15.19).
fn render(d: durable.Designation) []const u8 {
    if (d.authority != .here) return reason("that locus is not reachable from here");
    return switch (d.kind) {
        .directory => renderDirectory(d),
        .file => renderFile(d),
        .synthetic => |kind| reasonOf("no provider resolves ", kind),
        .unknown => reason("that designation names no kind"),
    };
}

fn renderDirectory(d: durable.Designation) []const u8 {
    const listing = weft.fsList("here", d.ref) orelse return reason("no such directory here");
    const want = d.count("rows", 3);
    var w: usize = 0;
    w += write(w, "[");
    w += write(w, d.ref);
    w += write(w, ":");
    var shown: usize = 0;
    var total: usize = 0;
    var it = std.mem.tokenizeScalar(u8, listing, '\n');
    while (it.next()) |name| : (total += 1) {
        if (shown >= want) continue;
        w += write(w, " ");
        w += write(w, name);
        shown += 1;
    }
    if (total == 0) w += write(w, " empty");
    if (total > shown) {
        var more: [32]u8 = undefined;
        w += write(w, std.fmt.bufPrint(&more, " (+{d})", .{total - shown}) catch "");
    }
    w += write(w, "] ");
    return body_buf[0..w];
}

fn renderFile(d: durable.Designation) []const u8 {
    const bytes = weft.fsRead(d.ref) orelse return reason("no such file here");
    const want = d.count("lines", 2);
    var w: usize = 0;
    w += write(w, "[");
    w += write(w, d.ref);
    w += write(w, ":");
    var shown: usize = 0;
    var it = std.mem.splitScalar(u8, bytes, '\n');
    while (it.next()) |line| {
        if (shown >= want) break;
        if (line.len == 0) continue;
        w += write(w, if (shown == 0) " " else " / ");
        w += write(w, std.mem.trimEnd(u8, line, "\r"));
        shown += 1;
    }
    if (shown == 0) w += write(w, " empty");
    w += write(w, "] ");
    return body_buf[0..w];
}

/// The fallback body: the note's own line still reads as itself, so what a
/// reader is missing is only WHY (§11.8, §15.19).
fn reason(why: []const u8) []const u8 {
    return reasonOf(why, "");
}

fn reasonOf(why: []const u8, detail: []const u8) []const u8 {
    var w: usize = 0;
    w += write(w, "[unresolved: ");
    w += write(w, why);
    w += write(w, detail);
    w += write(w, "] ");
    return body_buf[0..w];
}

/// Append into the shared body, clamped. Returns bytes written.
fn write(at: usize, s: []const u8) usize {
    const n = @min(s.len, body_buf.len -| at);
    @memcpy(body_buf[at..][0..n], s[0..n]);
    return n;
}

// ── The decorated-entry table ───────────────────────────────────────

fn activeEntry() ?u32 {
    var i: usize = 0;
    while (i < weft.bufferCount()) : (i += 1) {
        if (!weft.bufferActive(i)) continue;
        const id = weft.bufferId(i) orelse return null;
        return @intCast(id);
    }
    return null;
}

fn slot(entry: u32) ?*?Note {
    for (&notes) |*n| {
        if (n.*) |held| if (held.entry == entry) return n;
    }
    return null;
}

fn freeSlot() ?*?Note {
    for (&notes) |*n| {
        if (n.* == null) return n;
    }
    return null;
}

fn release(held: *?Note) void {
    if (held.*) |n| n.anno.close();
    held.* = null;
}
