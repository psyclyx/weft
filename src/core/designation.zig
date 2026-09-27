//! What an entry opens (doc/model.md §2.1–2.2): the designation every
//! workspace entry represents, the way back from a designation to the live
//! entry opening it, and the registry of producers that re-run a projection
//! kind.
//!
//! An ENTRY is a local opening; a DESIGNATION is what it opens, and the only
//! thing state that outlives the entry may hold. A jumplist entry, a
//! viewport's remembered subject, an embed: each keeps the designation and
//! finds the live entry again through `find`, or opens a new one, so a closed
//! entry's reused slot can never be mistaken for it.
//!
//! An entry's designation, first answer wins:
//!
//!  1. what was DECLARED for it (`Buffer.designation`) — by its producer
//!     through the guest door (a projection kind and its arguments, a live
//!     process), or by the shell for what only the shell knows (a peer's
//!     document, a remote shell's file, the directory a listing shows);
//!  2. a text entry's own backing: a local file is named by its absolute
//!     path, and text with no file by its document's minted id.
//!
//! An entry with neither has no designation. That is an honest answer — a
//! transient surface nobody declared — and everything that holds designations
//! simply does not hold one for it.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Buffers = @import("Buffers.zig");
pub const durable = @import("weft_semantic").durable;
pub const Designation = durable.Designation;

/// Room for any designation this editor renders: a path at the OS limit plus
/// scheme, authority and kind.
pub const max_len = Buffers.designation_cap;

/// Render `entry`'s designation into `out`, or null when it has none.
pub fn of(entry: *Buffers.Buffer, out: []u8) ?[]const u8 {
    if (entry.designation.len != 0) {
        if (entry.designation.len > out.len) return null;
        @memcpy(out[0..entry.designation.len], entry.designation);
        return out[0..entry.designation.len];
    }
    const ed = entry.textEditor() orelse return null;
    switch (ed.backing) {
        .file => |f| {
            // A relative backing path names nothing; the document id is then
            // the only honest name the entry has.
            if (Designation.ofPath(.file, f.path)) |d| return d.render(out) catch null;
        },
        // A remote shell's file is named when it is opened (the shell knows
        // its host; the backing does not), and declared then.
        .shell, .none => {},
    }
    const id = ed.doc.id.text();
    return Designation.ofDoc(.here, &id).render(out) catch null;
}

/// `of`, parsed: the entry's designation borrowing `out`.
pub fn parsed(entry: *Buffers.Buffer, out: []u8) ?Designation {
    return durable.parse(of(entry, out) orelse return null);
}

/// The live entry showing the VIEW `want` asks for (`Designation.sameView`:
/// the same thing, the same view parameters but the position), if any. One
/// comparison for everything that holds a designation and looks for its
/// entry — a jump, a viewport, an `open` — so two queries of one projection
/// are never mistaken for each other by one holder and kept apart by another.
pub fn find(buffers: *const Buffers, want: Designation) ?*Buffers.Buffer {
    // The common case asks by path; answer it without rendering every entry.
    if (want.authority == .here and want.kind == .file) {
        if (buffers.findByPath(want.ref)) |id| {
            const b = buffers.get(id).?;
            if (b.designation.len == 0 and want.sameView(want.bare())) return b;
        }
    }
    var buf: [max_len]u8 = undefined;
    var it = buffers.iterator();
    while (it.next()) |b| {
        const have = parsed(b, &buf) orelse continue;
        if (have.sameView(want)) return b;
    }
    return null;
}

/// `find` by text. Null for text that is not a designation.
pub fn findText(buffers: *const Buffers, text: []const u8) ?*Buffers.Buffer {
    return find(buffers, durable.parse(text) orelse return null);
}

/// How a title reads a designation: `<tool>: <display form>`, the display
/// form absolute with `$HOME` shown as `~` and a peer shown by its name.
/// One formula for every listing, so a title never reads relative in one
/// place and absolute in another. Falls back to `fallback` when `text` is
/// not a designation.
pub fn title(out: []u8, tool: []const u8, text: []const u8, fallback: []const u8, peer_name: ?[]const u8) []const u8 {
    var shown: [max_len]u8 = undefined;
    const display = if (durable.parse(text)) |d|
        d.display(&shown, home(), peer_name) catch fallback
    else
        fallback;
    if (tool.len == 0) return std.fmt.bufPrint(out, "{s}", .{display}) catch display;
    return std.fmt.bufPrint(out, "{s}: {s}", .{ tool, display }) catch display;
}

/// How a file-backed entry reads where there is little room (the status
/// line): relative to the entry's own PLACE when the file is inside it — "this
/// project's src/main.zig" — and otherwise its absolute display form, `$HOME`
/// as `~`. One rule for every entry, so a file never reads relative because of
/// how it happened to be opened and absolute because of how another was.
/// Display only; `path` is the entry's absolute backing path.
pub fn placeRelative(entry: *const Buffers.Buffer, realizer: ?@import("place.zig").Realizer, path: []const u8, out: []u8) []const u8 {
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir: []const u8 = switch (@import("place.zig").realize(entry.place, realizer)) {
        .process => @import("file.zig").processDirectory(&dir_buf) orelse "",
        .path => |abs| abs,
        .elsewhere, .unavailable => "",
    };
    if (dir.len > 1 and std.mem.startsWith(u8, path, dir) and path.len > dir.len + 1 and path[dir.len] == '/')
        return path[dir.len + 1 ..];
    const d = Designation.ofPath(.file, path) orelse return path;
    return d.display(out, home(), null) catch path;
}

/// `$HOME`, for display only (a designation never holds `~`). Empty when
/// unset, which abbreviates nothing.
pub fn home() []const u8 {
    const raw = std.c.getenv("HOME") orelse return "";
    return std.mem.sliceTo(raw, 0);
}

/// Who turns a peer authority into a name a person reads. Installed by the
/// shell, which knows who it connected to; absent, a peer shows by its
/// fingerprint.
pub const PeerNames = struct {
    context: *anyopaque,
    name: *const fn (*anyopaque, fingerprint: []const u8) ?[]const u8,

    pub fn of(self: ?PeerNames, text: []const u8) ?[]const u8 {
        const names = self orelse return null;
        const d = durable.parse(text) orelse return null;
        return switch (d.authority) {
            .peer => |fp| names.name(names.context, fp),
            else => null,
        };
    }
};

// ── Opening ─────────────────────────────────────────────────────────

const command = @import("command.zig");
const semantic_model = @import("weft_semantic");

/// `entry` now presents `located` — the shell attached a listing to it, or
/// navigation inside it moved on. It represents that target's designation,
/// as the target's binder named it (`Router.designationOf`), and its title
/// reads that designation's display form: the files listing is the `dir` it
/// lists, wherever navigation has taken it, and reads as absolute after a
/// descent as it did on the first open.
pub fn presentTarget(ctx: *command.Context, entry: *Buffers.Buffer, located: semantic_model.target.Located) !void {
    const services = ctx.semantic orelse return;
    const target = services.targets.get(located.target) orelse return;
    const named: []const u8 = if (ctx.filesystems) |router| router.designationOf(located.target, located.revision) orelse "" else "";
    try entry.setDesignation(ctx.gpa, named);
    var buf: [max_len]u8 = undefined;
    const shown = title(&buf, entry.tool, named, target.display_name, PeerNames.of(ctx.peer_names, named));
    const name = try ctx.gpa.dupe(u8, shown);
    ctx.gpa.free(entry.name);
    entry.name = name;
}

/// What an open came to: the entry now showing the designation, or why
/// nothing does, in words fit for the status line.
pub const Outcome = union(enum) {
    opened: Buffers.Id,
    refused: []const u8,
};

pub const refuse_unreachable = "open: that designation's authority is not reachable from here";
pub const refuse_doc_gone = "open: that document is gone — closed, and no longer kept";
pub const refuse_proc_gone = "open: that process is gone — a live resource lasts only as long as it runs";
pub const refuse_no_producer = "open: nothing here produces that kind";
pub const refuse_produced_nothing = "open: that projection produced nothing to show";

/// The view parameter that picks a projection (doc/model.md §2.4): a layout
/// the subject's own producer reads (`offers/primary?as=strip`), or another
/// producer's projection OF the subject (`…/main.zig?as=symbols`).
pub const as_param = "as";

/// Open what `d` designates, for the kinds core itself can answer: a live
/// entry already showing it (any kind), a document (live, or reopened from
/// the parked store), a process (only while its entry lives), a projection
/// (its producer re-run with `text`, the designation, as the one argument).
/// Paths and peers are the shell's — it owns the filesystems and the
/// connections — so for those this answers only the live-entry case and
/// null otherwise. Focuses what it opens.
/// Resolve a relative path someone TYPED (or a stored name that predates
/// designations) against the place the command runs in: the dispatching
/// entry's place directory, or the process directory for the degenerate place.
/// Relative names never get past a user-facing door — they are made absolute
/// here, once — so nothing downstream ever holds one (substrate §7, R1: a path
/// means something only paired with the place that hosts it, and the dispatch
/// always has one). Null when that place has no local directory (a peer's
/// tree): a bare name there has nothing honest to resolve against.
pub fn resolveRelative(ctx: *command.Context, gpa: Allocator, rel: []const u8) !?[]u8 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const place = @import("place.zig");
    const base: []const u8 = switch (place.realize(ctx.place(), ctx.realizer)) {
        .process => @import("file.zig").processDirectory(&buf) orelse return null,
        .path => |abs| abs,
        .elsewhere, .unavailable => return null,
    };
    return try std.fs.path.resolve(gpa, &.{ base, rel });
}

/// The words for a relative name in a place that has no local directory.
pub const refuse_relative_elsewhere = "this place has no local directory to resolve a relative name against: give an absolute path or a weft:// designation";

pub fn openHeld(ctx: *command.Context, d: Designation, text: []const u8) !?Outcome {
    if (d.param(as_param)) |as| if (try openAs(ctx, d, text, as)) |outcome| return outcome;
    if (find(ctx.buffers, d)) |b| {
        try ctx.buffers.switchTo(ctx.gpa, b.id, ctx.head, ctx.keymap);
        return .{ .opened = b.id };
    }
    if (d.kind.isPath()) return null;
    if (d.authority != .here) return if (d.kind == .doc) null else .{ .refused = refuse_unreachable };
    switch (d.kind) {
        .doc => {
            const doc = d.docId() orelse return .{ .refused = refuse_doc_gone };
            const id = (try ctx.buffers.revive(ctx.gpa, doc)) orelse return .{ .refused = refuse_doc_gone };
            try ctx.buffers.switchTo(ctx.gpa, id, ctx.head, ctx.keymap);
            return .{ .opened = id };
        },
        .proc => {
            // Reattach if it is alive: the producer of the process's
            // namespace (`procKind`) answers, and refuses when it has exited.
            // No producer, or none that brings an entry back, and the
            // process is gone as far as this workspace can tell.
            const openers = ctx.designations orelse return .{ .refused = refuse_proc_gone };
            var kind_buf: [64]u8 = undefined;
            const kind = procKind(d.ref, &kind_buf) orelse return .{ .refused = refuse_proc_gone };
            const opener = openers.find(kind) orelse return .{ .refused = refuse_proc_gone };
            var name_buf: [256]u8 = undefined;
            if (opener.command.len > name_buf.len) return .{ .refused = refuse_proc_gone };
            @memcpy(name_buf[0..opener.command.len], opener.command);
            const result = try command.run(ctx.commands, ctx, name_buf[0..opener.command.len], &.{.{ .string = text }});
            if (result == .string) return .{ .refused = result.string };
            const b = find(ctx.buffers, d) orelse return .{ .refused = refuse_proc_gone };
            if (b.id != ctx.buffers.active_id) try ctx.buffers.switchTo(ctx.gpa, b.id, ctx.head, ctx.keymap);
            return .{ .opened = b.id };
        },
        .projection => |kind| {
            const openers = ctx.designations orelse return .{ .refused = refuse_no_producer };
            const opener = openers.find(kind) orelse return .{ .refused = refuse_no_producer };
            // Copied out: the producer runs arbitrary code, reloads included.
            var name_buf: [256]u8 = undefined;
            if (opener.command.len > name_buf.len) return .{ .refused = refuse_no_producer };
            @memcpy(name_buf[0..opener.command.len], opener.command);
            const result = try command.run(ctx.commands, ctx, name_buf[0..opener.command.len], &.{.{ .string = text }});
            return switch (result) {
                .string => |why| .{ .refused = why },
                else => .{ .opened = ctx.buffers.active_id },
            };
        },
        .file, .directory => unreachable,
    }
}

/// `d?as=<kind>` where a producer claims `<kind>` and `d` is not already of
/// it: that producer's projection OF `d` — the symbols of an entry, the
/// diagnostics of a place. The producer is run with the whole designation,
/// and with `d`'s live entry active while it runs, so the document doors it
/// reads are the subject's; the entry it leaves active is the projection.
/// Null when `as` is no producer's kind: a layout `d`'s own producer reads
/// from the parameter, routed the ordinary way.
fn openAs(ctx: *command.Context, d: Designation, text: []const u8, as: []const u8) !?Outcome {
    const openers = ctx.designations orelse return null;
    const opener = openers.find(as) orelse return null;
    switch (d.kind) {
        .projection => |kind| if (std.mem.eql(u8, kind, as)) return null,
        else => {},
    }
    // The subject is `d` as its own entry shows it: without the `as` that
    // asks for another producer's projection of it.
    var params_buf: [max_len]u8 = undefined;
    const subject = find(ctx.buffers, d.without(as_param, &params_buf) catch d);
    if (subject) |b| if (b.id != ctx.buffers.active_id) try ctx.buffers.switchTo(ctx.gpa, b.id, ctx.head, ctx.keymap);
    const before = ctx.buffers.active_id;
    var name_buf: [256]u8 = undefined;
    if (opener.command.len > name_buf.len) return .{ .refused = refuse_no_producer };
    @memcpy(name_buf[0..opener.command.len], opener.command);
    const result = try command.run(ctx.commands, ctx, name_buf[0..opener.command.len], &.{.{ .string = text }});
    if (result == .string) return .{ .refused = result.string };
    // Still on the subject: the producer made nothing, and the viewport must
    // not be handed the subject itself instead of its projection.
    if (subject != null and ctx.buffers.active_id == before) return .{ .refused = refuse_produced_nothing };
    return .{ .opened = ctx.buffers.active_id };
}

/// The opener kind that answers a process `ref` — `proc.<namespace>`, the
/// namespace being the ref up to its first `.` (`repl.2` → `proc.repl`). A
/// producer claims it to reattach its live processes; the same claim keeps
/// every other plugin from declaring processes in that namespace.
pub fn procKind(ref: []const u8, out: []u8) ?[]const u8 {
    const ns = ref[0 .. std.mem.indexOfScalar(u8, ref, '.') orelse ref.len];
    if (ns.len == 0) return null;
    const kind = std.fmt.bufPrint(out, "proc.{s}", .{ns}) catch return null;
    return if (durable.Kind.isProjectionName(kind)) kind else null;
}

/// Put the caret where `d`'s position locator (`?at=`) says, in the entry
/// now active, clamped to its text. What makes a position part of the name.
pub fn applyPosition(ctx: *command.Context, d: Designation) void {
    const at = d.at() orelse return;
    const ed = ctx.buffers.active().textEditor() orelse return;
    ed.placeCursor(@min(at, ed.text().byteLen()));
}

// ── Producers of projection kinds ───────────────────────────────────

/// Who re-runs each projection kind (doc/model.md §2.1, "re-run on present").
/// A producer claims its kind and names the command that answers a
/// designation of it; `open` of a `weft://here/<kind>/…` with no live entry
/// runs that command with the designation as its one argument. A kind has
/// one producer: a second claimant is refused rather than silently winning,
/// and the grammar's own kinds (`file`, `dir`, `doc`, `proc`) cannot be
/// claimed at all.
pub const Openers = struct {
    list: std.ArrayList(Opener) = .empty,

    pub const empty: Openers = .{};

    pub const Opener = struct {
        kind: []u8,
        command: []u8,
        /// Who claimed it — the plugin's name. Compared, never interpreted.
        owner: []u8,
    };

    pub const ClaimError = Allocator.Error || error{ NotAProjectionKind, ClaimedByAnother };

    pub fn deinit(self: *Openers, gpa: Allocator) void {
        for (self.list.items) |o| free(gpa, o);
        self.list.deinit(gpa);
        self.* = undefined;
    }

    fn free(gpa: Allocator, o: Opener) void {
        gpa.free(o.kind);
        gpa.free(o.command);
        gpa.free(o.owner);
    }

    /// Claim `kind` for `owner`, answered by `command`. Re-claiming one's own
    /// kind replaces the command (a plugin reload).
    pub fn claim(self: *Openers, gpa: Allocator, kind: []const u8, command_name: []const u8, owner: []const u8) ClaimError!void {
        if (!durable.Kind.isProjectionName(kind)) return error.NotAProjectionKind;
        const owned_kind = try gpa.dupe(u8, kind);
        errdefer gpa.free(owned_kind);
        const owned_command = try gpa.dupe(u8, command_name);
        errdefer gpa.free(owned_command);
        const next: Opener = .{ .kind = owned_kind, .command = owned_command, .owner = try gpa.dupe(u8, owner) };
        errdefer gpa.free(next.owner);
        for (self.list.items) |*o| {
            if (!std.mem.eql(u8, o.kind, kind)) continue;
            if (!std.mem.eql(u8, o.owner, owner)) return error.ClaimedByAnother;
            free(gpa, o.*);
            o.* = next;
            return;
        }
        try self.list.append(gpa, next);
    }

    /// Drop every kind `owner` claimed (the plugin unloaded).
    pub fn release(self: *Openers, gpa: Allocator, owner: []const u8) void {
        var i: usize = 0;
        while (i < self.list.items.len) {
            if (std.mem.eql(u8, self.list.items[i].owner, owner)) {
                free(gpa, self.list.swapRemove(i));
            } else i += 1;
        }
    }

    pub fn find(self: *const Openers, kind: []const u8) ?Opener {
        for (self.list.items) |o| if (std.mem.eql(u8, o.kind, kind)) return o;
        return null;
    }
};

// ── Tests ───────────────────────────────────────────────────────────

const t = std.testing;
const task = @import("task.zig");

test "designation: a scratch entry is its document, a file entry its absolute path, a declared entry what was declared" {
    const gpa = t.allocator;
    var pool = try task.Pool.init(gpa, .{ .threads = 1 });
    defer pool.deinit();
    var bufs = try Buffers.init(gpa, pool, "user");
    defer bufs.deinit(gpa);
    var buf: [max_len]u8 = undefined;

    const scratch = bufs.get(0).?;
    const d = parsed(scratch, &buf).?;
    try t.expect(d.kind == .doc);
    try t.expect(d.docId().?.eql(scratch.textEditor().?.doc.id));
    try t.expect(find(&bufs, d).? == scratch);

    const file = bufs.get(try bufs.create(gpa, "a.zig")).?;
    try file.textEditor().?.adoptPath(gpa, "/srv/proj/a.zig");
    try t.expectEqualStrings("weft://here/file/srv/proj/a.zig", of(file, &buf).?);
    try t.expect(findText(&bufs, "weft://here/file/srv/proj/a.zig?at=3").? == file);

    const tool = bufs.get(try bufs.createView(gpa, "*status*", "git")).?;
    try t.expect(of(tool, &buf) == null);
    try tool.setDesignation(gpa, "weft://here/git.status/srv/proj");
    try t.expectEqualStrings("weft://here/git.status/srv/proj", of(tool, &buf).?);
    try t.expect(findText(&bufs, "weft://here/git.status/srv/proj").? == tool);
    try t.expect(findText(&bufs, "weft://here/git.status/elsewhere") == null);
}

test "designation: a producer owns its kind, and the grammar's kinds are nobody's" {
    const gpa = t.allocator;
    var openers: Openers = .empty;
    defer openers.deinit(gpa);
    try openers.claim(gpa, "git.status", "git-status-open", "git");
    try t.expectEqualStrings("git-status-open", openers.find("git.status").?.command);
    try t.expectError(error.ClaimedByAnother, openers.claim(gpa, "git.status", "mine", "other"));
    try openers.claim(gpa, "git.status", "git-status-again", "git");
    try t.expectEqualStrings("git-status-again", openers.find("git.status").?.command);
    for ([_][]const u8{ "file", "dir", "doc", "proc", "", "Git" }) |reserved|
        try t.expectError(error.NotAProjectionKind, openers.claim(gpa, reserved, "x", "git"));
    openers.release(gpa, "git");
    try t.expect(openers.find("git.status") == null);
}

test "designation: a title is absolute, abbreviates home, and falls back only for what is not a designation" {
    var buf: [256]u8 = undefined;
    try t.expectEqualStrings("files: /srv/proj", title(&buf, "files", "weft://here/dir/srv/proj", ".", null));
    try t.expectEqualStrings("files: peer:/src", title(&buf, "files", "weft://ab-cd/dir/src", "", "peer"));
    try t.expectEqualStrings("files: .", title(&buf, "files", "", ".", null));
}
