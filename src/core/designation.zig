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
        // A remote file is named when it is opened (its tier knows the
        // authority; the backing does not), and declared then.
        .remote, .none => {},
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

/// The place a published directory IS (doc/place.md §2): the container, on
/// the locus its binder's designation names — `here`, a peer by its
/// fingerprint, a shell by its id (substrate §7, R1/R2). Read from the one
/// name a trusted publisher bound, so a container's locus cannot disagree
/// with what it is called: there is no second field to set wrong. Null when
/// the container is unnamed, stale, or on a locus this embedding cannot hold
/// (no `Loci`), since a place whose locus is unknown must not read as here.
pub fn placeOf(ctx: *command.Context, located: semantic_model.target.Located) Allocator.Error!?@import("place.zig").Place {
    const router = ctx.filesystems orelse return null;
    const text = router.designationOf(located.target, located.revision) orelse return null;
    const d = durable.parse(text) orelse return null;
    if (d.kind != .directory) return null;
    const locus: @import("locus.zig").Locus = if (d.authority == .here) .here else if (ctx.loci) |loci| try loci.of(d.authority) else return null;
    return .{ .container = .{ .locus = locus, .ref = located.target, .revision = located.revision } };
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
pub const refuse_producer_unloaded = "open: the plugin that produced that kind is no longer loaded";
pub const refuse_produced_nothing = "open: that projection produced nothing to show";

/// The view parameter that picks a projection (doc/model.md §2.4): a layout
/// the subject's own producer reads (`offers/primary?as=strip`), or another
/// producer's projection OF the subject (`…/main.zig?as=symbols`).
pub const as_param = "as";

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

/// Open what `d` designates, for the kinds core itself can answer: a live
/// entry already showing it (any kind), a document (live, or reopened by
/// `Buffers.revive` — parked, or restored from the document store, which
/// outlives the process), a process (only while its entry lives), a projection
/// (its producer re-run with `text`, the designation, as the one argument).
/// Paths and peers are the shell's — it owns the filesystems and the
/// connections — so for those this answers only the live-entry case and
/// null otherwise. Focuses what it opens.
pub fn openHeld(ctx: *command.Context, d: Designation, text: []const u8) anyerror!?Outcome {
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
            const opener = openers.find(kind) orelse
                return .{ .refused = if (openers.wasReleased(kind)) refuse_producer_unloaded else refuse_no_producer };
            const here = ctx.buffers.active().ref();
            return try produce(ctx, opener, text, d, here, here);
        },
        .file, .directory => unreachable,
    }
}

/// Run `opener`'s command for `text` and answer what it produced: the entry it
/// left active when that is not `before` — or is, and now shows `reuse` (a
/// producer that keeps one entry and re-designates it). Anything else made
/// nothing: refused, never reported as whatever happened to be active, and the
/// head is put back on `restore`, as it is for the producer's own refusal.
fn produce(ctx: *command.Context, opener: Openers.Opener, text: []const u8, reuse: ?Designation, before: Buffers.Ref, restore: Buffers.Ref) anyerror!Outcome {
    // Copied out: the producer runs arbitrary code, reloads included.
    var name_buf: [256]u8 = undefined;
    if (opener.command.len > name_buf.len) return .{ .refused = refuse_no_producer };
    @memcpy(name_buf[0..opener.command.len], opener.command);
    const result = try command.run(ctx.commands, ctx, name_buf[0..opener.command.len], &.{.{ .string = text }});
    const now = ctx.buffers.active();
    const made = !std.meta.eql(now.ref(), before) or if (reuse) |want| blk: {
        var buf: [max_len]u8 = undefined;
        const have = parsed(now, &buf) orelse break :blk false;
        break :blk have.designates(want);
    } else false;
    if (result != .string and made) return .{ .opened = now.id };
    if (ctx.buffers.resolve(restore)) |b| if (b.id != ctx.buffers.active_id) try ctx.buffers.switchTo(ctx.gpa, b.id, ctx.head, ctx.keymap);
    return .{ .refused = if (result == .string) result.string else refuse_produced_nothing };
}

pub const refuse_subject_unopened = "open: that projection's subject could not be opened";

/// `d?as=<kind>` where a producer claims `<kind>` and `d` is not already of
/// it: that producer's projection OF `d` — the symbols of an entry, the
/// diagnostics of a place. The producer is run with the whole designation,
/// and with `d`'s entry active while it runs — opened first when none shows
/// it, so the document doors it reads are always the subject's, never those
/// of whatever else was active; the entry it leaves active is the
/// projection. Null when `as` is no producer's kind: a layout `d`'s own
/// producer reads from the parameter, routed the ordinary way.
fn openAs(ctx: *command.Context, d: Designation, text: []const u8, as: []const u8) anyerror!?Outcome {
    const openers = ctx.designations orelse return null;
    const opener = openers.find(as) orelse return null;
    switch (d.kind) {
        .projection => |kind| if (std.mem.eql(u8, kind, as)) return null,
        else => {},
    }
    const restore = ctx.buffers.active().ref();
    // The subject is `d` as its own entry shows it: without the `as` that
    // asks for another producer's projection of it.
    var params_buf: [max_len]u8 = undefined;
    const subject_d = d.without(as_param, &params_buf) catch return .{ .refused = refuse_subject_unopened };
    const subject = find(ctx.buffers, subject_d) orelse blk: {
        // Not open: open it the way a person would (`open` routes every
        // kind, paths and peers included), then find it again.
        var subject_buf: [max_len]u8 = undefined;
        const subject_text = subject_d.render(&subject_buf) catch return .{ .refused = refuse_subject_unopened };
        const opened = try command.run(ctx.commands, ctx, "file.open", &.{.{ .string = subject_text }});
        const found = find(ctx.buffers, subject_d);
        if (opened == .string or found == null) {
            if (ctx.buffers.resolve(restore)) |b| if (b.id != ctx.buffers.active_id) try ctx.buffers.switchTo(ctx.gpa, b.id, ctx.head, ctx.keymap);
            return .{ .refused = if (opened == .string) opened.string else refuse_subject_unopened };
        }
        break :blk found.?;
    };
    if (subject.id != ctx.buffers.active_id) try ctx.buffers.switchTo(ctx.gpa, subject.id, ctx.head, ctx.keymap);
    // Still on the subject afterwards: the producer made nothing, and the
    // viewport must not be handed the subject instead of its projection.
    return try produce(ctx, opener, text, null, subject.ref(), restore);
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
        /// Its owner unloaded. Kept, so a designation of the kind is refused
        /// as having lost its producer rather than as never having had one,
        /// until a producer claims it again.
        released: bool = false,
    };

    pub const ClaimError = Allocator.Error || error{ NotAProjectionKind, ClaimedByAnother };

    /// Whether plugin `owner` may claim `kind` by its name alone: the kind is
    /// the plugin's name, or under it (`git` → `git.status`), or the process
    /// namespace of it (`repl` → `proc.repl`). A kind outside its name a
    /// plugin must DECLARE (`designation/<kind>` in its describe manifest), so
    /// what resolves where is read from the manifests, never from which
    /// plugin loaded first.
    pub fn inNamespace(owner: []const u8, kind: []const u8) bool {
        if (owner.len == 0) return false;
        if (std.mem.eql(u8, kind, owner)) return true;
        if (kind.len > owner.len and std.mem.startsWith(u8, kind, owner) and kind[owner.len] == '.') return true;
        const proc = "proc.";
        return kind.len == proc.len + owner.len and std.mem.startsWith(u8, kind, proc) and std.mem.eql(u8, kind[proc.len..], owner);
    }

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
            if (!o.released and !std.mem.eql(u8, o.owner, owner)) return error.ClaimedByAnother;
            free(gpa, o.*);
            o.* = next;
            return;
        }
        try self.list.append(gpa, next);
    }

    /// Release every kind `owner` claimed (the plugin unloaded): no command
    /// answers it any more, and `released` says so.
    pub fn release(self: *Openers, gpa: Allocator, owner: []const u8) void {
        _ = gpa;
        for (self.list.items) |*o| {
            if (std.mem.eql(u8, o.owner, owner)) o.released = true;
        }
    }

    /// The live producer of `kind`, if any.
    pub fn find(self: *const Openers, kind: []const u8) ?Opener {
        for (self.list.items) |o| if (!o.released and std.mem.eql(u8, o.kind, kind)) return o;
        return null;
    }

    /// Whether `kind` had a producer that has since unloaded.
    pub fn wasReleased(self: *const Openers, kind: []const u8) bool {
        for (self.list.items) |o| if (o.released and std.mem.eql(u8, o.kind, kind)) return true;
        return false;
    }
};

// ── Tests ───────────────────────────────────────────────────────────

const t = std.testing;
const task = @import("task.zig");
const TestHost = @import("TestHost.zig");

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
    try openers.claim(gpa, "git.status", "git.status-open", "git");
    try t.expectEqualStrings("git.status-open", openers.find("git.status").?.command);
    try t.expectError(error.ClaimedByAnother, openers.claim(gpa, "git.status", "mine", "other"));
    try openers.claim(gpa, "git.status", "git-status-again", "git");
    try t.expectEqualStrings("git-status-again", openers.find("git.status").?.command);
    for ([_][]const u8{ "file", "dir", "doc", "proc", "", "Git" }) |reserved|
        try t.expectError(error.NotAProjectionKind, openers.claim(gpa, reserved, "x", "git"));
    openers.release(gpa, "git");
    try t.expect(openers.find("git.status") == null);
    try t.expect(openers.wasReleased("git.status"));
    // A released kind is claimable again.
    try openers.claim(gpa, "git.status", "git.status-open", "git");
    try t.expect(openers.find("git.status") != null and !openers.wasReleased("git.status"));

    // A plugin's namespace is its name: the kind itself, under it, its
    // processes — and nothing that merely starts with the same letters.
    for ([_][]const u8{ "git", "git.status", "proc.git" }) |mine| try t.expect(Openers.inNamespace("git", mine));
    for ([_][]const u8{ "gitk", "gitx.status", "proc.gitk", "grep", "proc", "" }) |theirs| try t.expect(!Openers.inNamespace("git", theirs));
}

/// The producers the opening tests register: one that makes nothing, and one
/// that records which document was active when it ran and opens a view.
const TestProducers = struct {
    var saw: ?@import("Document.zig").Id = null;

    fn nothing(_: *command.Context, _: struct { d: []const u8 }) anyerror!command.Value {
        return .nil;
    }

    fn project(ctx: *command.Context, _: struct { d: []const u8 }) anyerror!command.Value {
        saw = if (ctx.buffers.active().textEditor()) |ed| ed.doc.id else null;
        const id = try ctx.buffers.create(ctx.gpa, "*projection*");
        try ctx.buffers.switchTo(ctx.gpa, id, ctx.head, ctx.keymap);
        return .nil;
    }

    /// The kernel's `open`, cut down to what core answers.
    fn open(ctx: *command.Context, args: struct { d: []const u8 }) anyerror!command.Value {
        const d = durable.parse(args.d) orelse return .{ .string = "malformed" };
        const outcome = (try openHeld(ctx, d, args.d)) orelse return .{ .string = "not core's" };
        return switch (outcome) {
            .opened => |id| .{ .integer = @intCast(id) },
            .refused => |why| .{ .string = why },
        };
    }
};

test "designation: a producer that produces nothing is refused, never reported as the entry it left active" {
    const gpa = t.allocator;
    var env: TestHost = undefined;
    try TestHost.init(gpa, &env);
    defer env.deinit(gpa);
    var openers: Openers = .empty;
    defer openers.deinit(gpa);
    env.ctx.designations = &openers;
    _ = try env.commands.bind(gpa, "t-nothing", command.define("t-nothing", "", TestProducers.nothing));
    try openers.claim(gpa, "t.none", "t-nothing", "t");

    const before = env.buffers.active_id;
    const text = "weft://here/t.none/x";
    const outcome = (try openHeld(&env.ctx, durable.parse(text).?, text)).?;
    try t.expect(outcome == .refused);
    try t.expectEqualStrings(refuse_produced_nothing, outcome.refused);
    try t.expectEqual(before, env.buffers.active_id);
}

test "designation: a projection OF a subject runs with the subject open, and a refusal restores what was active" {
    const gpa = t.allocator;
    var env: TestHost = undefined;
    try TestHost.init(gpa, &env);
    defer env.deinit(gpa);
    var openers: Openers = .empty;
    defer openers.deinit(gpa);
    env.ctx.designations = &openers;
    _ = try env.commands.bind(gpa, "file.open", command.define("file.open", "", TestProducers.open));
    _ = try env.commands.bind(gpa, "t-project", command.define("t-project", "", TestProducers.project));
    _ = try env.commands.bind(gpa, "t-nothing", command.define("t-nothing", "", TestProducers.nothing));
    try openers.claim(gpa, "t.proj", "t-project", "t");
    try openers.claim(gpa, "t.none", "t-nothing", "t");

    // A scratch document with text, closed: parked, so it can come back.
    const subject = try env.buffers.create(gpa, "subject");
    try env.buffers.get(subject).?.textEditor().?.insertText(gpa, "fn main() {}\n");
    const doc = env.buffers.get(subject).?.textEditor().?.doc.id;
    try env.buffers.close(gpa, subject, &env.head, &env.keymap);
    const start_id = env.buffers.active_id;

    // Its projection: the subject is opened first, and the producer reads IT,
    // not whatever happened to be active.
    var spelled = doc.text();
    var buf: [max_len]u8 = undefined;
    const as_proj = try std.fmt.bufPrint(&buf, "weft://here/doc/{s}?as=t.proj", .{&spelled});
    const opened = (try openHeld(&env.ctx, durable.parse(as_proj).?, as_proj)).?;
    try t.expect(opened == .opened);
    try t.expect(TestProducers.saw.?.eql(doc));

    // A projection that makes nothing: refused, and the head is back where it
    // was before the open began.
    try env.buffers.switchTo(gpa, start_id, &env.head, &env.keymap);
    var buf2: [max_len]u8 = undefined;
    const as_none = try std.fmt.bufPrint(&buf2, "weft://here/doc/{s}?as=t.none", .{&spelled});
    const refused = (try openHeld(&env.ctx, durable.parse(as_none).?, as_none)).?;
    try t.expectEqualStrings(refuse_produced_nothing, refused.refused);
    try t.expectEqual(start_id, env.buffers.active_id);
}

test "designation: a title is absolute, abbreviates home, and falls back only for what is not a designation" {
    var buf: [256]u8 = undefined;
    try t.expectEqualStrings("files: /srv/proj", title(&buf, "files", "weft://here/dir/srv/proj", ".", null));
    try t.expectEqualStrings("files: peer:/src", title(&buf, "files", "weft://ab-cd/dir/src", "", "peer"));
    try t.expectEqualStrings("files: .", title(&buf, "files", "", ".", null));
}
