//! The jumplist — a head's position history (vim's C-o/C-i, helix's C-o/C-i).
//!
//! One entry is a DESIGNATION plus a position (doc/model.md §2.2): what was
//! open, never which slot it was open in. A jump therefore outlives the entry
//! it was taken in — travelling to one whose entry has closed opens its
//! designation again (a file from disk, a scratch document from where closed
//! documents are kept) — and a closed entry's reused slot can never be
//! mistaken for it, because nothing here names a slot.
//!
//! The position is an ANCHOR in the document that was open, while that
//! document lives: the offset rides every edit (`Document.addAnchor`), so an
//! insert above a remembered spot does not send the jump back to the wrong
//! line. The anchor is only ever read against the document it was taken in —
//! the jump keeps that document's minted id — and when that document dies
//! with its entry, the anchor settles into a plain offset (`settle`) that a
//! reopened document is entered at.
//!
//! Who decides what is a jump: the grammar, for anything inside one entry (a
//! search, a goto, a big motion — `wl_jump_push`); core, for moving between
//! entries, because only core sees every such move (`Buffers.switchTo` pushes
//! the position being left). Moving along the list is not itself a jump.
//!
//! Browser semantics rather than vim's keep-everything list: pushing while
//! part-way back drops the forward half (helix does the same). The first
//! `back` from the tip records where you are, so `forward` can return there.
//!
//! **Not `buffer.back`.** `buffer.back` (a tool's `q`, `std.navigation.back`'s
//! core route) LEAVES the current entry for the one before it, always — that is
//! what closing a tool means. The jumplist's previous position is often in the
//! same entry (the search you ran in the git status buffer), which would make
//! `q` a no-op there. Two verbs, then, over two facts: "the entry I came from"
//! (`Buffers.prev_id`, a slot, not a history) and "where I have been" (this).

const std = @import("std");
const Allocator = std.mem.Allocator;

const Buffers = @import("Buffers.zig");
const Head = @import("Head.zig");
const Keymap = @import("Keymap.zig");
const Document = @import("Document.zig");
const designation = @import("designation.zig");

/// Oldest entries fall off past this — a history, not a log.
pub const cap = 100;

pub const Jump = struct {
    /// What was open: the entry's designation with every view parameter but
    /// the position (a query is part of WHICH view), owned by the list.
    designation: []u8,
    /// The document `anchor` lives in — the one that was open when the jump
    /// was taken. An anchor is meaningless in any other document, so it is
    /// read only while a document with this id is held.
    doc: ?Document.Id = null,
    /// Which in-memory instance of `doc` the anchor was taken in
    /// (`Document.incarnation`). A document kept in the store and restored
    /// comes back with the same id and a fresh anchor set, so the id alone
    /// cannot say whether `anchor` still indexes anything.
    incarnation: u64 = 0,
    anchor: ?Document.AnchorHandle = null,
    /// The position as last known: where the jump was taken, or where its
    /// anchor had moved to when its document died. What a freshly opened
    /// document is entered at. Null for an entry that holds no text.
    offset: ?usize = null,
};

pub const JumpList = struct {
    items: std.ArrayList(Jump) = .empty,
    /// The entry `back` steps from: `items.len` at the tip, else the index of
    /// the position the last `back`/`forward` landed on.
    pos: usize = 0,
    /// Nonzero while the head moves in a way that is not navigation — the
    /// list's own travel, or a borrow (`Buffers.withEntry`, `quietly`) — so
    /// the entry switches it causes are not recorded as jumps.
    muted: u32 = 0,

    pub const empty: JumpList = .{};

    /// Frees the list. Anchors stay in their documents, which own them and
    /// free them with the document; a head outliving its buffers has none left
    /// to release.
    pub fn deinit(self: *JumpList, gpa: Allocator) void {
        for (self.items.items) |j| gpa.free(j.designation);
        self.items.deinit(gpa);
        self.* = .{};
    }
};

/// Where `buffers`' active entry is right now, as a position to remember.
/// `designation` borrows the caller's storage.
pub const Here = struct { designation: []const u8, doc: ?Document.Id, offset: ?usize };

/// Where the active entry is, or null when it has no designation to be
/// returned to (nothing could ever travel back there).
pub fn here(buffers: *Buffers, out: *[designation.max_len]u8) ?Here {
    const b = buffers.active();
    var full: [designation.max_len]u8 = undefined;
    const d = designation.parsed(b, &full) orelse return null;
    const ed = b.textEditor();
    // The view the entry shows, all of it but the position: the jump keeps
    // its own position, and a query or a layout is part of WHICH view.
    var params: [designation.max_len]u8 = undefined;
    const view = d.without(designation.durable.Designation.at_param, &params) catch return null;
    return .{
        .designation = view.render(out) catch return null,
        .doc = if (ed) |e| e.doc.id else null,
        .offset = if (ed) |e| e.cursorOffset() else null,
    };
}

/// Where `jump` is now: its live entry (null when none is open) and offset.
const Resolved = struct { buffer: ?*Buffers.Buffer, offset: ?usize };

fn resolve(buffers: *Buffers, jump: Jump) Resolved {
    const b = designation.findText(buffers, jump.designation) orelse return .{ .buffer = null, .offset = jump.offset };
    return .{ .buffer = b, .offset = offsetIn(b, jump) };
}

/// `jump`'s offset in the live entry `b`: its anchor when `b` holds the very
/// document the anchor is in, else the offset it last knew, clamped.
fn offsetIn(b: *Buffers.Buffer, jump: Jump) ?usize {
    const ed = b.textEditor() orelse return null;
    if (jump.anchor) |a| if (jump.doc) |doc| if (ed.doc.id.eql(doc) and ed.doc.incarnation == jump.incarnation) return ed.doc.anchorOffset(a);
    const off = jump.offset orelse return null;
    return @min(off, ed.text().byteLen());
}

fn release(buffers: *Buffers, gpa: Allocator, jump: Jump) void {
    gpa.free(jump.designation);
    const a = jump.anchor orelse return;
    const doc = buffers.documentById(jump.doc orelse return) orelse return;
    if (doc.incarnation != jump.incarnation) return; // restored since: not its anchor set
    doc.removeAnchor(a);
}

fn same(buffers: *Buffers, jump: Jump, at: Here) bool {
    const a = designation.durable.parse(jump.designation) orelse return false;
    const b = designation.durable.parse(at.designation) orelse return false;
    if (!a.sameView(b)) return false;
    const r = resolve(buffers, jump);
    return std.meta.eql(r.offset, at.offset);
}

/// `doc` is about to be destroyed with its entry: every jump anchored in it
/// keeps the offset its anchor had reached, and lets go of the anchor, so a
/// later travel enters the reopened document there instead of reading a
/// handle into a document that no longer exists.
pub fn settle(list: *JumpList, doc: *Document) void {
    for (list.items.items) |*j| {
        const in = j.doc orelse continue;
        if (!in.eql(doc.id) or j.incarnation != doc.incarnation) continue;
        if (j.anchor) |a| j.offset = doc.anchorOffset(a);
        j.anchor = null;
        j.doc = null;
    }
}

/// Record `at` as a jump. Drops any forward half first; a push equal to the
/// newest entry is a no-op, so pressing `n` on the only match does not fill
/// the list with one position.
pub fn push(list: *JumpList, gpa: Allocator, buffers: *Buffers, at: Here) Allocator.Error!void {
    if (list.muted > 0) return;
    // Part-way back, the entry the head stands on stays; what is after it goes.
    const keep = @min(list.pos + 1, list.items.items.len);
    while (list.items.items.len > keep) release(buffers, gpa, list.items.pop().?);
    _ = try append(list, gpa, buffers, at);
    list.pos = list.items.items.len;
}

/// `push` of wherever the active entry is, if it can be returned to.
pub fn pushHere(list: *JumpList, gpa: Allocator, buffers: *Buffers) Allocator.Error!void {
    if (list.muted > 0) return;
    var buf: [designation.max_len]u8 = undefined;
    const at = here(buffers, &buf) orelse return;
    try push(list, gpa, buffers, at);
}

/// Append `at` (unless it is the newest entry already). Answers how many
/// entries fell off the front to keep the list at `cap`: every index a caller
/// holds into the list moves down by that much.
fn append(list: *JumpList, gpa: Allocator, buffers: *Buffers, at: Here) Allocator.Error!usize {
    if (list.items.getLastOrNull()) |last| if (same(buffers, last, at)) return 0;
    const owned = try gpa.dupe(u8, at.designation);
    errdefer gpa.free(owned);
    var jump: Jump = .{ .designation = owned, .offset = at.offset };
    if (at.offset) |off| if (at.doc) |doc_id| if (buffers.documentById(doc_id)) |doc| {
        jump.anchor = try doc.addAnchor(gpa, @min(off, doc.text().byteLen()), .left);
        jump.doc = doc_id;
        jump.incarnation = doc.incarnation;
    };
    errdefer if (jump.anchor) |a| buffers.documentById(jump.doc.?).?.removeAnchor(a);
    try list.items.append(gpa, jump);
    if (list.items.items.len <= cap) return 0;
    release(buffers, gpa, list.items.orderedRemove(0));
    if (list.pos > 0) list.pos -= 1;
    return 1;
}

/// Opens a designation whose entry is no longer live — the `open` command,
/// for a caller that has a `Context`. A jump to a closed entry is refused
/// (and stepped over) when there is no opener, or when opening fails: a
/// process that has exited, a document released past the kept bounds (`Buffers.documents`).
pub const Reopen = struct {
    context: ?*anyopaque = null,
    open: ?*const fn (context: ?*anyopaque, designation: []const u8) bool = null,

    pub const none: Reopen = .{};

    fn call(self: Reopen, text: []const u8) bool {
        const f = self.open orelse return false;
        return f(self.context, text);
    }
};

pub const Direction = enum { back, forward };

/// Move `count` entries along the list and put the head there, reopening a
/// designation whose entry has closed. Entries equal to where the head
/// already is are stepped over without counting, and so is one that cannot
/// be opened again. Returns false, moving nothing, when there is no such
/// entry.
pub fn travel(
    list: *JumpList,
    gpa: Allocator,
    buffers: *Buffers,
    head: *Head,
    keymap: *const Keymap,
    reopen: Reopen,
    dir: Direction,
    count: usize,
) !bool {
    var now_buf: [designation.max_len]u8 = undefined;
    const now = here(buffers, &now_buf);
    if (dir == .back and list.pos >= list.items.items.len) {
        // Leaving the tip: remember it, so `forward` can come back.
        if (now) |at| _ = try append(list, gpa, buffers, at); // pos is re-read from the length below
        list.pos = list.items.items.len -| 1;
    }
    var i = list.pos;
    var left = @max(count, 1);
    while (true) {
        const next = switch (dir) {
            .back => if (i == 0) return false else i - 1,
            .forward => if (i + 1 >= list.items.items.len) return false else i + 1,
        };
        i = next;
        const jump = list.items.items[i];
        if (now) |at| if (same(buffers, jump, at)) continue;
        if (left > 1) {
            left -= 1;
            continue;
        }
        if (!try goTo(list, gpa, buffers, head, keymap, reopen, i)) continue;
        list.pos = i;
        return true;
    }
}

/// Land on entry `index` (a picker's choice). False when it cannot be opened.
pub fn travelTo(list: *JumpList, gpa: Allocator, buffers: *Buffers, head: *Head, keymap: *const Keymap, reopen: Reopen, index: usize) !bool {
    if (index >= list.items.items.len) return false;
    var at = index;
    if (list.pos >= list.items.items.len) {
        // Leaving the tip records it; at the cap that evicts the oldest entry,
        // and the chosen one moves down with the rest.
        var buf: [designation.max_len]u8 = undefined;
        const shifted = if (here(buffers, &buf)) |now| try append(list, gpa, buffers, now) else 0;
        if (at < shifted) return false; // the choice itself fell off
        at -= shifted;
    }
    if (!try goTo(list, gpa, buffers, head, keymap, reopen, at)) return false;
    list.pos = at;
    return true;
}

/// Put the head on jump `index`, opening its designation when no entry
/// shows it. False, moving nothing it can help, when it cannot be opened.
fn goTo(list: *JumpList, gpa: Allocator, buffers: *Buffers, head: *Head, keymap: *const Keymap, reopen: Reopen, index: usize) !bool {
    list.muted += 1;
    defer list.muted -= 1;
    var b = designation.findText(buffers, list.items.items[index].designation);
    if (b == null) {
        // Owned across the open: opening may push nothing (muted) but the
        // list must not be read through a slice the open could invalidate.
        const text = try gpa.dupe(u8, list.items.items[index].designation);
        defer gpa.free(text);
        if (!reopen.call(text)) return false;
        b = designation.findText(buffers, text);
    }
    const entry = b orelse return false;
    if (entry.id != buffers.active_id) try buffers.switchTo(gpa, entry.id, head, keymap);
    if (offsetIn(entry, list.items.items[index])) |off| if (entry.textEditor()) |ed| ed.placeCursor(off);
    return true;
}

/// One row of `describe`: what the entry is called, the 1-based line, and
/// whether it is where the list currently stands.
pub const Row = struct {
    index: usize,
    name: []const u8,
    line: ?usize,
    offset: ?usize,
    current: bool,
};

/// Every entry, newest first — what a picker lists. An entry whose entry is
/// closed is listed by its designation, since travelling there reopens it.
/// `out` is caller-owned scratch; `name` borrows the list or a live entry.
pub fn describe(list: *const JumpList, gpa: Allocator, buffers: *Buffers, out: *std.ArrayList(Row)) Allocator.Error!void {
    var i = list.items.items.len;
    while (i > 0) {
        i -= 1;
        const jump = list.items.items[i];
        const r = resolve(buffers, jump);
        var line: ?usize = null;
        if (r.buffer) |b| if (r.offset) |off| if (b.textEditor()) |ed| {
            line = ed.text().offsetToPoint(off).row + 1;
        };
        try out.append(gpa, .{
            .index = i,
            .name = if (r.buffer) |b| b.name else jump.designation,
            .line = line,
            .offset = r.offset,
            .current = i == list.pos,
        });
    }
}

// ── Commands ─────────────────────────────────────────────────────────
//
// `jump.back`/`jump.forward` take an optional count, as an integer or as the
// digits a grammar accumulated (`runStr`), so a count prefix reaches them from
// either plane. `jump.push` is the door a grammar with no guest code (a
// config's bound key) reaches `wl_jump_push` through.

const command = @import("command.zig");
const Context = command.Context;
const Value = command.Value;
const pick_types = @import("pick/types.zig");

/// A count argument: absent, an integer, or decimal digits. Anything else is
/// the caller's mistake, said out loud.
pub fn countArg(args: []const Value, i: usize) error{TypeMismatch}!usize {
    if (args.len <= i) return 1;
    return switch (args[i]) {
        .nil => 1,
        .integer => |n| if (n < 1) 1 else @intCast(n),
        .string => |s| if (s.len == 0) 1 else std.fmt.parseInt(usize, s, 10) catch return error.TypeMismatch,
        else => error.TypeMismatch,
    };
}

fn say(ctx: *Context, msg: []const u8) void {
    ctx.head.echo.say(ctx.gpa, msg) catch {};
}

/// Reopen through the ordinary `open`: whatever it does for a designation
/// typed by hand — a file from disk, a parked document, a producer re-run, a
/// refusal for a process that is gone — it does for a jump.
pub fn reopenWith(ctx: *Context) Reopen {
    return .{ .context = ctx, .open = openThroughCommand };
}

fn openThroughCommand(raw: ?*anyopaque, text: []const u8) bool {
    const ctx: *Context = @ptrCast(@alignCast(raw.?));
    const result = command.run(ctx.commands, ctx, "file.open", &.{.{ .string = text }}) catch return false;
    return switch (result) {
        .string => false, // a refusal, said in words
        else => true,
    };
}

fn travelCmd(comptime dir: Direction) fn (*Context, ?*anyopaque, []const Value) anyerror!Value {
    return struct {
        fn f(ctx: *Context, data: ?*anyopaque, args: []const Value) anyerror!Value {
            _ = data;
            const n = try countArg(args, 0);
            if (!try travel(&ctx.head.jumps, ctx.gpa, ctx.buffers, ctx.head, ctx.keymap, reopenWith(ctx), dir, n))
                say(ctx, if (dir == .back) "jumplist: nothing older" else "jumplist: nothing newer");
            return .nil;
        }
    }.f;
}

fn cJumpPush(ctx: *Context, data: ?*anyopaque, args: []const Value) anyerror!Value {
    _ = data;
    _ = args;
    try pushHere(&ctx.head.jumps, ctx.gpa, ctx.buffers);
    return .nil;
}

/// `jump.pick`: every entry, newest first, through the head's picker.
/// A row's key is its list index, so accepting lands on exactly that entry
/// even when two rows read alike.
fn cJumplistPick(ctx: *Context, data: ?*anyopaque, args: []const Value) anyerror!Value {
    _ = data;
    _ = args;
    const gpa = ctx.gpa;
    var rows: std.ArrayList(Row) = .empty;
    defer rows.deinit(gpa);
    try describe(&ctx.head.jumps, gpa, ctx.buffers, &rows);
    if (rows.items.len == 0) {
        say(ctx, "jumplist: empty");
        return .nil;
    }
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const entries = try a.alloc(pick_types.Entry, rows.items.len);
    for (rows.items, entries) |r, *e| {
        e.* = .{
            .text = if (r.line) |line|
                try std.fmt.allocPrint(a, "{s}:{d}", .{ r.name, line })
            else
                try a.dupe(u8, r.name),
            .doc = if (r.current) "current" else "",
            .key = try std.fmt.allocPrint(a, "{d}", .{r.index}),
        };
    }
    const keys = try gpa.alloc(usize, rows.items.len);
    errdefer gpa.free(keys);
    for (rows.items, keys) |r, *k| k.* = r.index;
    const held = try gpa.create([]usize);
    errdefer gpa.destroy(held);
    held.* = keys;
    try ctx.head.pick.openWith(ctx, "jumps", entries, .{
        .handler = pickAccept,
        .cleanup = pickCleanup,
        .data = @ptrCast(held),
    }, .{ .category = "jump" });
    return .nil;
}

fn pickAccept(ctx: *Context, data: ?*anyopaque, outcome: pick_types.Outcome) anyerror!void {
    const keys: *[]usize = @ptrCast(@alignCast(data.?));
    const chosen = switch (outcome) {
        .candidate => |c| c.index,
        else => return,
    };
    if (chosen >= keys.len) return;
    if (!try travelTo(&ctx.head.jumps, ctx.gpa, ctx.buffers, ctx.head, ctx.keymap, reopenWith(ctx), keys.*[chosen]))
        say(ctx, "jumplist: that entry cannot be opened again");
}

fn pickCleanup(data: ?*anyopaque, gpa: Allocator) void {
    const keys: *[]usize = @ptrCast(@alignCast(data.?));
    gpa.free(keys.*);
    gpa.destroy(keys);
}

/// `jump.line [n]`: the caret to the start of line `n` (1-based, held to
/// the last line), leaving a jump where it was; with no `n`, ask for one.
/// Core's, so every grammar has it — it is what a click on the status
/// line's position runs.
fn cJumpLine(ctx: *Context, data: ?*anyopaque, args: []const Value) anyerror!Value {
    _ = data;
    const ed = (ctx.entry() orelse return .nil).textEditor() orelse {
        say(ctx, "go to line: this entry holds no text");
        return .nil;
    };
    if (args.len > 0 and args[0] != .nil) {
        const n = countArg(args, 0) catch {
            say(ctx, "go to line: a line number");
            return .nil;
        };
        try goToLine(ctx, ed, n);
        return .nil;
    }
    try ctx.head.pick.openWith(ctx, "go to line", &.{}, .{ .handler = lineAccept }, .{ .allow_free_text = true });
    return .nil;
}

fn lineAccept(ctx: *Context, data: ?*anyopaque, outcome: pick_types.Outcome) anyerror!void {
    _ = data;
    const text = std.mem.trim(u8, outcome.text() orelse return, " \t");
    const n = std.fmt.parseInt(usize, text, 10) catch return say(ctx, "go to line: a line number");
    const ed = (ctx.entry() orelse return).textEditor() orelse return;
    try goToLine(ctx, ed, n);
}

fn goToLine(ctx: *Context, ed: *@import("Editor.zig"), n: usize) !void {
    try pushHere(&ctx.head.jumps, ctx.gpa, ctx.buffers);
    const rope = ed.text();
    const row = @min(n -| 1, rope.lineCount() -| 1);
    ed.clearSelection();
    ed.placeCursor(rope.lineRange(row).start);
}

const count_arg: []const command.ArgSpec = &.{.{ .name = "count", .type = .nil, .optional = true }};

const table = [_]command.Command{
    .{ .name = "jump.back", .summary = "Go back to where you were before the last jump.", .args = count_arg, .handler = travelCmd(.back), .meta = .{ .label = "Back", .icon = "arrow-left" } },
    .{ .name = "jump.forward", .summary = "Go forward again along the jumps you went back through.", .args = count_arg, .handler = travelCmd(.forward), .meta = .{ .label = "Forward", .icon = "arrow-right" } },
    .{ .name = "jump.push", .summary = "Remember the caret's position as a jump.", .args = &.{}, .handler = cJumpPush, .meta = .{ .label = "Remember Position" } },
    .{ .name = "jump.pick", .summary = "Pick a position from the jumplist and go there.", .args = &.{}, .handler = cJumplistPick, .meta = .{ .label = "Jump to Position", .icon = "history", .prompts = true } },
    .{ .name = "jump.line", .summary = "Go to a line by its number.", .args = &.{.{ .name = "line", .type = .nil, .optional = true }}, .handler = cJumpLine, .meta = .{ .label = "Go to Line", .prompts = true } },
};

pub fn install(gpa: Allocator, commands: *command.Commands) !void {
    for (table) |cmd| _ = try commands.bind(gpa, cmd.name, cmd);
}

const t = std.testing;
const task = @import("task.zig");

const Fixture = struct {
    pool: *task.Pool,
    bufs: Buffers,
    km: Keymap = .empty,
    head: Head = .empty,

    fn init(self: *Fixture) !void {
        self.pool = try task.Pool.init(t.allocator, .{ .threads = 1 });
        self.bufs = try Buffers.init(t.allocator, self.pool, "user");
        self.km = .empty;
        self.head = .empty;
    }
    fn deinit(self: *Fixture) void {
        self.head.deinit(t.allocator);
        self.km.deinit(t.allocator);
        self.bufs.deinit(t.allocator);
        self.pool.deinit();
    }
    fn fill(self: *Fixture, id: Buffers.Id, text: []const u8) !void {
        const ed = self.bufs.get(id).?.textEditor().?;
        ed.placeCursor(0);
        try ed.insertText(t.allocator, text);
    }
    fn at(self: *Fixture, off: usize) void {
        self.bufs.active().textEditor().?.placeCursor(off);
    }
    fn cursor(self: *Fixture) usize {
        return self.bufs.active().textEditor().?.cursorOffset();
    }
    /// The reopener a `Context` would hand over, cut down to what these
    /// tests need: a parked document comes back, anything else is refused.
    fn reopen(self: *Fixture) Reopen {
        return .{ .context = self, .open = revive };
    }
    fn revive(raw: ?*anyopaque, text: []const u8) bool {
        const self: *Fixture = @ptrCast(@alignCast(raw.?));
        const d = designation.durable.parse(text) orelse return false;
        const doc = d.docId() orelse return false;
        const id = (self.bufs.revive(t.allocator, doc) catch return false) orelse return false;
        self.bufs.switchTo(t.allocator, id, &self.head, &self.km) catch return false;
        return true;
    }
    fn back(self: *Fixture) !bool {
        return travel(&self.head.jumps, t.allocator, &self.bufs, &self.head, &self.km, self.reopen(), .back, 1);
    }
    fn forward(self: *Fixture) !bool {
        return travel(&self.head.jumps, t.allocator, &self.bufs, &self.head, &self.km, self.reopen(), .forward, 1);
    }
    fn remember(self: *Fixture) !void {
        try pushHere(&self.head.jumps, t.allocator, &self.bufs);
    }
};

test "jumplist: push, back and forward within one entry" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.fill(0, "one\ntwo\nthree\nfour\n");
    f.at(0);
    try f.remember();
    f.at(8);
    try f.remember();
    f.at(14);
    try t.expect(try f.back()); // tip recorded, back to 8
    try t.expectEqual(@as(usize, 8), f.cursor());
    try t.expect(try f.back());
    try t.expectEqual(@as(usize, 0), f.cursor());
    try t.expect(!try f.back()); // nothing older
    try t.expect(try f.forward());
    try t.expectEqual(@as(usize, 8), f.cursor());
    try t.expect(try f.forward());
    try t.expectEqual(@as(usize, 14), f.cursor()); // the tip it remembered
    try t.expect(!try f.forward());
}

test "jumplist: choosing an entry from the tip of a full list lands on that entry, not the one after" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    var text: [2 * (cap + 2)]u8 = undefined;
    for (0..cap + 2) |i| {
        text[2 * i] = 'x';
        text[2 * i + 1] = '\n';
    }
    try f.fill(0, &text);
    // A full list: line i's start remembered as entry i.
    for (0..cap) |i| {
        f.at(2 * i);
        try f.remember();
    }
    try t.expectEqual(@as(usize, cap), f.head.jumps.items.items.len);
    // From one line further on (the tip, not yet an entry), choose entry 50:
    // recording the tip evicts entry 0, and entry 50 must still be line 50.
    f.at(2 * cap);
    const want = 2 * 50;
    try t.expect(try travelTo(&f.head.jumps, t.allocator, &f.bufs, &f.head, &f.km, f.reopen(), 50));
    try t.expectEqual(@as(usize, want), f.cursor());
    // Choosing the oldest one, which the tip's record pushed out, is refused.
    f.head.jumps.pos = f.head.jumps.items.items.len;
    f.at(2 * cap + 2);
    try t.expect(!try travelTo(&f.head.jumps, t.allocator, &f.bufs, &f.head, &f.km, f.reopen(), 0));
}

test "jumplist: an edit above a remembered spot moves the spot with it" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.fill(0, "alpha\nbeta\n");
    f.at(6); // "beta"
    try f.remember();
    f.at(0);
    try f.bufs.active().textEditor().?.insertText(t.allocator, "new line\n");
    try t.expect(try f.back());
    try t.expectEqual(@as(usize, 15), f.cursor());
    try t.expectEqual(@as(u8, 'b'), f.bufs.active().textEditor().?.text().byteAt(15));
}

test "jumplist: switching entries records where you were; a closed scratch document is reopened, anchor and all" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.fill(0, "scratch text\n");
    const a = try f.bufs.create(t.allocator, "a");
    const b = try f.bufs.create(t.allocator, "b");
    try f.fill(a, "in a\nsecond line\n");
    try f.fill(b, "in b\n");
    f.at(3);
    try f.bufs.switchTo(t.allocator, a, &f.head, &f.km); // pushes scratch@3
    f.at(5);
    try f.bufs.switchTo(t.allocator, b, &f.head, &f.km); // pushes a@5
    try t.expectEqual(@as(usize, 2), f.head.jumps.items.items.len);
    // A jump names what was open, never the slot it was open in.
    try t.expect(std.mem.startsWith(u8, f.head.jumps.items.items[1].designation, "weft://here/doc/"));

    try t.expect(try f.back()); // b → a
    try t.expectEqual(a, f.bufs.active_id);
    try t.expectEqual(@as(usize, 5), f.cursor());
    try t.expect(try f.back()); // a → scratch@3
    try t.expectEqual(@as(Buffers.Id, 0), f.bufs.active_id);
    try t.expectEqual(@as(usize, 3), f.cursor());

    // Close `a` (a scratch document with text in it): its entry is gone, and
    // a new entry takes its slot — which the jump must not land on.
    const a_doc = f.bufs.get(a).?.textEditor().?.doc.id;
    try f.bufs.close(t.allocator, a, &f.head, &f.km);
    const squatter = try f.bufs.create(t.allocator, "squatter");
    try t.expectEqual(a, squatter);
    try t.expect(try f.forward());
    // Travel reopened the document itself, under a fresh entry, at the spot.
    const reopened = f.bufs.active();
    try t.expect(reopened.textEditor().?.doc.id.eql(a_doc));
    try t.expect(reopened.id != squatter);
    try t.expectEqual(@as(usize, 5), f.cursor());
    try t.expect(try f.forward());
    try t.expectEqual(b, f.bufs.active_id);
}

test "jumplist: a jump into a document that is gone for good is stepped over" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.fill(0, "scratch text\n");
    const empty = try f.bufs.create(t.allocator, "empty"); // nothing in it: not kept
    const b = try f.bufs.create(t.allocator, "b");
    try f.bufs.switchTo(t.allocator, empty, &f.head, &f.km);
    try f.bufs.switchTo(t.allocator, b, &f.head, &f.km);
    try f.bufs.close(t.allocator, empty, &f.head, &f.km);
    // b → (empty, gone) → scratch
    try t.expect(try f.back());
    try t.expectEqual(@as(Buffers.Id, 0), f.bufs.active_id);
}

test "jumplist: a borrow (withEntry) goes and comes back without recording a jump" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.fill(0, "scratch text\n");
    const a = try f.bufs.create(t.allocator, "a.zig");
    const b = try f.bufs.create(t.allocator, "b.zig");
    try f.bufs.switchTo(t.allocator, a, &f.head, &f.km); // one real jump
    const jumps = f.head.jumps.items.items.len;
    const prev = f.bufs.prev_id;

    const Probe = struct {
        fn activeIs(bufs: *Buffers, want: Buffers.Id) bool {
            return bufs.active_id == want;
        }
    };
    try t.expect(try f.bufs.withEntry(t.allocator, b, &f.head, &f.km, Probe.activeIs, .{ &f.bufs, b }));
    try t.expectEqual(a, f.bufs.active_id);
    try t.expectEqual(jumps, f.head.jumps.items.items.len);
    try t.expectEqual(prev, f.bufs.prev_id);

    // Closing the borrowed entry still comes home.
    const Close = struct {
        fn run(bufs: *Buffers, id: Buffers.Id, head: *Head, km: *const Keymap) !void {
            try bufs.close(t.allocator, id, head, km);
        }
    };
    try (try f.bufs.withEntry(t.allocator, b, &f.head, &f.km, Close.run, .{ &f.bufs, b, &f.head, &f.km }));
    try t.expectEqual(a, f.bufs.active_id);
    try t.expectEqual(jumps, f.head.jumps.items.items.len);
}

test "jumplist: two views of one projection are two places — a jump keeps its view parameters" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    // `grep bar` is live beside `grep foo`: one kind, one place, two queries.
    const bar = try f.bufs.create(t.allocator, "*grep*");
    try f.bufs.get(bar).?.setDesignation(t.allocator, "weft://here/grep/srv/p?q=bar");
    try f.fill(bar, "bar hits\n");
    const foo = try f.bufs.create(t.allocator, "*grep*");
    try f.bufs.get(foo).?.setDesignation(t.allocator, "weft://here/grep/srv/p?q=foo");
    try f.fill(foo, "foo hits\nmore foo\n");
    try f.bufs.switchTo(t.allocator, foo, &f.head, &f.km);
    f.at(11);
    try f.bufs.switchTo(t.allocator, bar, &f.head, &f.km); // pushes foo@11
    try t.expectEqualStrings("weft://here/grep/srv/p?q=foo", f.head.jumps.items.items[f.head.jumps.items.items.len - 1].designation);
    try t.expect(try f.back());
    try t.expectEqual(foo, f.bufs.active_id);
    try t.expectEqual(@as(usize, 11), f.cursor());
}

test "jumplist: a push part-way back drops the forward half" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.fill(0, "0123456789\n");
    for ([_]usize{ 1, 2, 3 }) |off| {
        f.at(off);
        try f.remember();
    }
    f.at(4);
    try t.expect(try f.back()); // at 3
    try t.expect(try f.back()); // at 2
    f.at(7);
    try f.remember(); // 1, 2, 7
    try t.expectEqual(@as(usize, 3), f.head.jumps.items.items.len);
    try t.expect(!try f.forward());
    try t.expect(try f.back());
    try t.expectEqual(@as(usize, 2), f.cursor());
}
