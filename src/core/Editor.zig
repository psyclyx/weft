//! Editor — the interactive shell around one Document: its selections
//! (one or many; each a head and an optional anchor in the Document's
//! auto-shifted AnchorSet, never bare offsets — the cursor/mark API reads the
//! primary one and collapses the set to it on write), movement over the rope's line/scalar queries, undo
//! delegation with vim-flavored unit barriers, dirty tracking by
//! version comparison, and saving as a *fallible request* on the task
//! pool — never an op, never a wait.
//!
//! Movement steps are Unicode scalars (grapheme clustering is a caller
//! concern in stemma's model and a later refinement here); vertical
//! movement keeps a goal column in bytes, clamped per line.

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const stemma = @import("stemma");
const Document = @import("Document.zig");
const layers = @import("layers.zig");
const undo_mod = @import("undo.zig");
const task = @import("task.zig");
const file = @import("file.zig");
const backing_mod = @import("backing.zig");
const ShellFs = @import("ShellFs.zig");
const Range = stemma.Range;

const Editor = @This();

doc: Document,
history: undo_mod.UndoLog = .empty,
/// Every selection this editor holds, in document order (`normalize` keeps
/// them sorted and disjoint). NEVER empty: one selection is the degenerate
/// case every single-cursor grammar lives in, and there is no second
/// representation beside it — the cursor/mark API below (`cursorOffset`,
/// `moveTo`, `selectedRange`, …) READS `selections[primary]`, and every write
/// through it collapses the set to that one selection first, so a grammar
/// that knows nothing about multiple selections cannot strand secondaries a
/// click or a jump left behind (doc/configs.md §0.1).
///
/// Local view state: the handles live in the Document's AnchorSet (so every
/// edit, local or merged, shifts them), but nothing here is serialized or
/// broadcast. Presence publishes the primary caret only (app/collab.zig).
selections: std.ArrayList(Selection) = .empty,
/// Index into `selections` of the selection the cursor/mark view reads —
/// the one motions, the view's scroll-follow, and presence track.
primary: usize = 0,
/// Nonzero while a per-selection runner is VISITING the set (`beginVisit`/
/// `visit`/`endVisit`): the selection being visited is then "the" selection,
/// and a single-selection write addresses it alone instead of collapsing the
/// set onto it. Outside a visit every single-selection write collapses first
/// (`solo`), so no path can move one caret and leave the others behind.
visiting: u32 = 0,
/// Byte column the *headless/fallback* vertical motion aims for (sticky
/// across short lines). Used when there is no view to consult — see
/// `moveVertical`. The interactive path uses `goal_x` instead.
goal_col: ?usize = null,
/// Pixel-x the *interactive* vertical motion aims for (world px, sticky
/// across short lines). The view computes it from rendered geometry, so
/// j/k track visual columns even on proportional text — not scalar
/// columns (that column assumption was the monospace tech debt). Both
/// goals reset together on any horizontal/edit motion.
goal_x: ?f32 = null,
/// Where the bytes live (design rev 4): the authority for save/load
/// and the peer that merges external writes.
backing: backing_mod.Backing = .none,
/// Version token of the last content known to be on disk.
saved_version: ?[]u8 = null,
pool: *task.Pool,
save_state: SaveState = .idle,
poll_state: PollState = .idle,
/// The buffer's fold feed (invisible spans), or null. A stable pointer into
/// the session's `Layers` (which outlives frames), set by the app each frame
/// from `caps.layers.find(doc, "folds")`. The view elides rows whose line-start
/// falls inside an invisible span; vertical motion skips them. Null in headless
/// use, so folding is inert unless the app wires it.
fold_layer: ?*const layers.Layer = null,
/// The read-only SPAN layer (if any): ranges an interactive edit is refused in
/// (a comint's produced output vs its editable input line). Set per frame like
/// `fold_layer`; consulted at the edit door.
readonly_layer: ?*const layers.Layer = null,

pub const SaveError = file.GuardedWriteError || backing_mod.RemoteError;
pub const PollError = file.ReadError || backing_mod.RemoteError || Allocator.Error;

/// Work whose result folds in later: on a pool worker, or — for a tier whose
/// calls run on the thread that asked (`Remote.Affinity.caller`) — already
/// done. One shape, so every fold reads both the same way.
pub fn Pending(comptime T: type) type {
    return union(enum) {
        task: task.Handle(T),
        done: T,

        /// The result if it is in (consumes it), else null.
        pub fn poll(self: *@This()) ?T {
            return switch (self.*) {
                .task => |*h| h.poll(),
                .done => |value| value,
            };
        }
    };
}

pub const SaveState = union(enum) {
    idle,
    /// A save is in flight; the version it snapshots. The worker
    /// returns the written content's token.
    saving: struct { pending: Pending(SaveError![]u8), version: []u8 },
    /// The disk moved under us — poll the backing (merges the external
    /// write), then request again. Cleared by `pollBacking`.
    stale,
    /// Terminal state of the last save attempt, until the next request.
    failed: SaveError,
};

pub const PollState = union(enum) {
    idle,
    polling: Pending(PollError!?file.Fetched),
};

/// One selection: a `head` (the caret — where typing lands and motion acts)
/// and, when one has been dropped, an `anchor` (the end that stays put).
///
/// The anchor is OPTIONAL, not merely allowed to equal the head, because the
/// two states behave differently under motion: with no anchor, moving the head
/// moves a caret; with one, it grows a selection (emacs's active mark, vim's
/// visual mode). `anchor == head` is an empty selection — a caret — too; core
/// never demands a selection cover a character (that is helix's grammar rule,
/// not an editor rule).
///
/// Biases are fixed by role: the head is `.right` (text typed at it pushes it
/// forward, as do other peers' inserts there), the anchor `.left`.
///
/// An INCLUSIVE selection (vim's charwise visual) has its caret ON a
/// character, not between two, and covers from the anchor's character
/// through the caret's, both included. It is stored as the range it covers:
/// `anchor` and `head` are that range's ends, the head the end the caret is
/// at. So every reader of what a selection covers — the highlight, an
/// operator, cut and copy, a search seeded from it — reads the range and
/// cannot be one character short; only WHERE THE CARET IS differs (`Ends.
/// caretIn`: on a forward selection, the character before the head), and the
/// cursor API translates both ways (`cursorOffset`, `moveTo`).
pub const Selection = struct {
    head: stemma.AnchorSet.Handle,
    anchor: ?stemma.AnchorSet.Handle = null,
    inclusive: bool = false,
};

/// A selection's endpoints as offsets — what crosses the ABI and what
/// `setSelections` takes. `anchor == head` asks for a caret (no anchor),
/// unless the selection is `inclusive` (then it keeps its anchor: it grows
/// from there).
pub const Ends = struct {
    anchor: usize,
    head: usize,
    inclusive: bool = false,

    /// Where the caret is: the head, or on a forward inclusive selection the
    /// last character it covers.
    pub fn caretIn(self: Ends, rope: *const stemma.Rope) usize {
        if (!self.inclusive or self.head <= self.anchor) return self.head;
        return rope.scalarToOffset(rope.offsetToScalar(self.head) - 1);
    }

    /// The character the anchor holds on to, on an inclusive selection: the
    /// anchor, or on a backward one the character before it.
    fn pinnedIn(self: Ends, rope: *const stemma.Rope) usize {
        if (!self.inclusive or self.head >= self.anchor) return self.anchor;
        return rope.scalarToOffset(rope.offsetToScalar(self.anchor) - 1);
    }
};

pub fn init(gpa: Allocator, pool: *task.Pool, user_agent: []const u8) Allocator.Error!Editor {
    var doc = try Document.init(gpa, user_agent);
    errdefer doc.deinit(gpa);
    return around(gpa, pool, &doc);
}

/// An editor around a document that already exists — one restored from the
/// document store (`Document.restore`). MOVES `doc` in on success (leaving
/// it empty, so the caller's cleanup of it is a no-op); on failure the
/// caller still owns it, unchanged. The caret starts at the top, and there
/// is no backing and nothing saved: the editor is new even though the
/// document is not.
pub fn around(gpa: Allocator, pool: *task.Pool, doc: *Document) Allocator.Error!Editor {
    const cursor = try doc.addAnchor(gpa, 0, .right);
    errdefer doc.removeAnchor(cursor);
    var selections: std.ArrayList(Selection) = .empty;
    try selections.append(gpa, .{ .head = cursor });
    const moved = doc.*;
    doc.* = .{};
    return .{ .doc = moved, .selections = selections, .pool = pool };
}

pub fn deinit(self: *Editor, gpa: Allocator) void {
    // Work in flight owns snapshots and returns gpa-owned tokens; wait
    // it out (shutdown path, blocking allowed) so nothing leaks.
    switch (self.save_state) {
        .saving => |*s| {
            while (true) {
                if (s.pending.poll()) |result| {
                    if (result) |token| gpa.free(token) else |_| {}
                    break;
                }
                std.Thread.yield() catch {};
            }
            gpa.free(s.version);
        },
        else => {},
    }
    switch (self.poll_state) {
        .polling => |*pending| {
            while (true) {
                if (pending.poll()) |result| {
                    if (result) |maybe| {
                        if (maybe) |f| {
                            gpa.free(f.bytes);
                            gpa.free(f.token);
                        }
                    } else |_| {}
                    break;
                }
                std.Thread.yield() catch {};
            }
        },
        else => {},
    }
    switch (self.backing) {
        .none => {},
        .file => |*f| {
            f.sync.deinit(gpa, &self.doc);
            gpa.free(f.path);
        },
        .remote => |*r| {
            r.sync.deinit(gpa, &self.doc);
            r.remote.deinit(gpa);
        },
    }
    self.history.deinit(gpa);
    // The selection handles die with the Document's AnchorSet; only the
    // list itself is ours.
    self.selections.deinit(gpa);
    self.doc.deinit(gpa);
    if (self.saved_version) |v| gpa.free(v);
    self.* = undefined;
}

pub fn text(self: *const Editor) *const stemma.Rope {
    return self.doc.text();
}

/// The primary selection's head — "the cursor" of every single-cursor API.
pub fn cursorOffset(self: *const Editor) usize {
    return self.selectionEndsOf(self.primarySelection()).caretIn(self.text());
}

fn primarySelection(self: *const Editor) Selection {
    assert(self.selections.items.len > 0 and self.primary < self.selections.items.len);
    return self.selections.items[self.primary];
}

// ── Files & backings ────────────────────────────────────────────────

/// The display/save path, when the backing has one.
/// The path of the LOCAL file backing this entry, or null — for a scratch,
/// a projection, and a remote file, whose path names a file on another
/// locus. Whatever will act on a path here (reopen it, dedupe an open by
/// it, hand it to a local tool or server) reads this, never `backingPath`:
/// a far-side `/etc/hosts` taken for this machine's is a different file.
/// A remote entry is named by its designation.
pub fn localPath(self: *const Editor) ?[]const u8 {
    return switch (self.backing) {
        .file => |f| f.path,
        else => null,
    };
}

/// The backing's path on whichever locus holds it — for DISPLAY and for
/// what a path's spelling says (a language by its extension), never for
/// acting on here (`localPath`).
pub fn backingPath(self: *const Editor) ?[]const u8 {
    return switch (self.backing) {
        .file => |f| f.path,
        .remote => |r| r.remote.path(),
        else => null,
    };
}

fn setBackingLoaded(self: *Editor, gpa: Allocator) Allocator.Error!void {
    if (self.saved_version) |v| gpa.free(v);
    self.saved_version = try self.doc.version(gpa);
    // The load is not part of undo history, and the cursor starts at
    // the top (the mirror's insert at 0 pushed the bias-right anchor
    // to the end).
    try self.history.ingest(gpa, &self.doc);
    self.history.barrier();
    self.doc.anchors.set(self.primarySelection().head, .{ .offset = 0, .bias = .right });
}

/// Open a local file as this buffer's backing: the content BECOMES the
/// document's base — one event, whatever the file's size — rather than
/// one event per scalar. Startup path, allowed to block. The document
/// must not already have a backing.
///
/// There is deliberately no size threshold here. Loading per-scalar used
/// to buy identity anchors into the content, which a base could not offer;
/// stemma 0.7 anchors base scalars as (creating event, offset), so the
/// bulk path lost its only drawback and a small file has no reason to pay
/// millions of events for what one event expresses.
pub fn openFile(self: *Editor, gpa: Allocator, path: []const u8) (Allocator.Error || file.ReadError || Document.AddPeerError)!void {
    task.assertMayBlock();
    assert(self.backing == .none);
    const bytes = try file.readAlloc(gpa, path);
    defer gpa.free(bytes);
    try self.openFileContent(gpa, path, bytes);
}

/// `openFile` with the file's bytes already read — by a caller that read them
/// through something stronger than the path (a filesystem provider, relative
/// to a directory handle it checked), so what the entry shows is exactly
/// what was authorized, and the path is only where a save goes.
pub fn openFileContent(self: *Editor, gpa: Allocator, path: []const u8, bytes: []const u8) (Allocator.Error || Document.AddPeerError)!void {
    assert(self.backing == .none);
    const token = backing_mod.localToken(bytes);
    try self.doc.adoptContent(gpa, bytes);
    var sync = try backing_mod.Sync.init(gpa, &self.doc);
    errdefer sync.deinit(gpa, &self.doc);
    try sync.loadBased(gpa, &self.doc, &token);
    self.backing = .{ .file = .{ .path = try gpa.dupe(u8, path), .sync = sync } };
    try self.setBackingLoaded(gpa);
}

/// Open a remote file over a persistent shell (coreutils tier). Blocks
/// (two shell round-trips); startup/open path.
pub fn openShell(self: *Editor, gpa: Allocator, fs: *ShellFs, path: []const u8) (backing_mod.RemoteError || Document.AddPeerError)!void {
    task.assertMayBlock();
    const remote = try backing_mod.ShellRemote.create(gpa, fs, path);
    return self.openRemote(gpa, remote);
}

/// Open a file on another tier as this buffer's backing (`backing.Remote`),
/// which the backing takes over — freed with it, or here on failure. Blocks
/// for the tier's fetch; the open path.
pub fn openRemote(self: *Editor, gpa: Allocator, remote: backing_mod.Remote) (backing_mod.RemoteError || Document.AddPeerError)!void {
    assert(self.backing == .none);
    var owned = true;
    errdefer if (owned) remote.deinit(gpa);
    try remote.prepare();
    const fetched = (try remote.fetch(gpa, null)) orelse return error.Failed;
    defer gpa.free(fetched.bytes);
    defer gpa.free(fetched.token);
    var sync = try backing_mod.Sync.init(gpa, &self.doc);
    errdefer if (owned) sync.deinit(gpa, &self.doc);
    try sync.load(gpa, &self.doc, fetched.bytes, fetched.token);
    self.backing = .{ .remote = .{ .remote = remote, .sync = sync } };
    owned = false;
    try self.setBackingLoaded(gpa);
}

/// Point a fresh buffer at a path that need not exist yet (save
/// creates it, guarded on non-existence).
pub fn adoptPath(self: *Editor, gpa: Allocator, path: []const u8) (Allocator.Error || Document.AddPeerError)!void {
    assert(self.backing == .none);
    const sync = try backing_mod.Sync.init(gpa, &self.doc);
    self.backing = .{ .file = .{ .path = try gpa.dupe(u8, path), .sync = sync } };
}

/// Event count (since the last compaction) past which a clean save
/// triggers another compaction — bounds walker replay cost for
/// long-lived sessions without compacting away undo-adjacent history
/// on every trivial save (undo is unaffected either way: it replays
/// the commit log, not the stemma graph).
const compact_event_threshold = 4096;

/// Compact all history at the current head (must be clean: content ==
/// disk) and rebuild the backing mirror on the new base — the two move
/// together; compacting a document out from under its mirror strands
/// the mirror behind the compaction horizon.
pub fn compactNow(self: *Editor, gpa: Allocator) !void {
    assert(!(self.isDirty(gpa) catch true));
    const stable = try self.doc.version(gpa);
    defer gpa.free(stable);
    try self.doc.compact(gpa, stable);
    if (self.backingSync()) |sync| {
        // Same content, fresh replica bootstrapped from the compacted
        // base; the disk token is unchanged (content is unchanged).
        self.doc.removePeer(gpa, sync.peer);
        sync.peer = try self.doc.addPeer(gpa, backing_mod.Sync.peer_name);
    }
    // The frontier token changed shape (compacted history leaves it
    // empty); re-stamp the clean point so dirtiness stays truthful.
    if (self.saved_version != null) {
        gpa.free(self.saved_version.?);
        self.saved_version = try self.doc.version(gpa);
    }
}

/// Compact once history has grown past `compact_event_threshold` since
/// the last compaction, called right after a save lands (the one point
/// a normal edit session is guaranteed momentarily clean). Best-effort:
/// a race with fresh typing (still dirty by the time the async save
/// resolves) or a transient compact failure just defers to the next
/// save — never surfaced, never fatal.
fn compactIfGrown(self: *Editor, gpa: Allocator) void {
    if (self.doc.eventCount() < compact_event_threshold) return;
    const dirty = self.isDirty(gpa) catch return;
    if (dirty) return;
    self.compactNow(gpa) catch {};
}

fn backingSync(self: *Editor) ?*backing_mod.Sync {
    return switch (self.backing) {
        .file => |*f| &f.sync,
        .remote => |*r| &r.sync,
        else => null,
    };
}

fn fileSaveWorker(gpa: Allocator, path: []u8, rope: stemma.Rope, expected: ?[]u8) SaveError![]u8 {
    return file.writeRopeGuarded(gpa, path, rope, expected);
}

fn filePollWorker(gpa: Allocator, path: []u8, expected: []u8) PollError!?file.Fetched {
    return file.pollFile(gpa, path, expected);
}

fn remoteSaveWorker(gpa: Allocator, remote: backing_mod.Remote, bytes: []u8, expected: ?[]u8) SaveError![]u8 {
    defer gpa.free(bytes);
    defer if (expected) |e| gpa.free(e);
    return remote.write(gpa, bytes, expected);
}

fn remotePollWorker(gpa: Allocator, remote: backing_mod.Remote, expected: []u8) PollError!?file.Fetched {
    defer gpa.free(expected);
    return remote.fetch(gpa, expected);
}

/// Run `f` where `remote`'s calls may run: on a pool worker, or right here.
/// The caller has prepared the tier (`Remote.prepare`) on this thread.
fn onTier(self: *Editor, remote: backing_mod.Remote, comptime f: anytype, args: std.meta.ArgsTuple(@TypeOf(f))) Allocator.Error!Pending(@typeInfo(@TypeOf(f)).@"fn".return_type.?) {
    return switch (remote.vtable.affinity) {
        .worker => .{ .task = try self.pool.spawn(f, args) },
        .caller => .{ .done = @call(.auto, f, args) },
    };
}

/// Request a guarded save: O(1) rope snapshot + version token, written
/// by a pool worker (upload/temp + test-and-set rename). Never blocks;
/// fold with `pollSave`. A request while one is in flight is dropped
/// (poll first; the editor loop does). `.stale` means the disk moved —
/// poll the backing (which merges), then request again.
pub fn requestSave(self: *Editor, gpa: Allocator) Allocator.Error!void {
    if (self.save_state == .saving) return;
    if (self.backing == .remote) self.backing.remote.remote.prepare() catch |err| {
        self.save_state = if (err == error.Stale) .stale else .{ .failed = err };
        return;
    };
    const version = try self.doc.version(gpa);
    errdefer gpa.free(version);
    const pending: Pending(SaveError![]u8) = switch (self.backing) {
        .none => {
            gpa.free(version);
            return;
        },
        .file => |f| .{ .task = try self.pool.spawn(fileSaveWorker, .{
            gpa,
            try gpa.dupe(u8, f.path),
            self.doc.text().snapshot(),
            if (f.sync.token) |tk| try gpa.dupe(u8, tk) else null,
        }) },
        .remote => |r| blk: {
            var snap = self.doc.text().snapshot();
            defer snap.deinit(gpa);
            const bytes = try snap.toOwnedSlice(gpa);
            errdefer gpa.free(bytes);
            const expected = if (r.sync.token) |tk| try gpa.dupe(u8, tk) else null;
            errdefer if (expected) |e| gpa.free(e);
            break :blk try self.onTier(r.remote, remoteSaveWorker, .{ gpa, r.remote, bytes, expected });
        },
    };
    self.save_state = .{ .saving = .{ .pending = pending, .version = version } };
}

/// Non-blocking: fold a finished save into state. Returns true when a
/// save completed successfully since the last poll. On success the
/// backing mirror advances to exactly the saved version.
pub fn pollSave(self: *Editor, gpa: Allocator) bool {
    switch (self.save_state) {
        .saving => |*s| {
            const result = s.pending.poll() orelse return false;
            const version = s.version;
            if (result) |token| {
                defer gpa.free(token);
                if (self.backingSync()) |sync| {
                    sync.markSaved(gpa, &self.doc, version, token) catch {};
                }
                if (self.saved_version) |v| gpa.free(v);
                self.saved_version = version;
                self.save_state = .idle;
                self.compactIfGrown(gpa);
                return true;
            } else |err| {
                gpa.free(version);
                self.save_state = if (err == error.Stale) .stale else .{ .failed = err };
                return false;
            }
        },
        else => return false,
    }
}

/// Request an external-change poll of the backing (cheap: one hash
/// round-trip when unchanged). Never blocks; fold with `pollBacking`.
pub fn requestBackingPoll(self: *Editor, gpa: Allocator) Allocator.Error!void {
    if (self.poll_state == .polling or self.save_state == .saving) return;
    switch (self.backing) {
        .none => {},
        .file => |f| {
            const tk = f.sync.token orelse return;
            self.poll_state = .{ .polling = .{ .task = try self.pool.spawn(filePollWorker, .{
                gpa, try gpa.dupe(u8, f.path), try gpa.dupe(u8, tk),
            }) } };
        },
        .remote => |r| {
            const tk = r.sync.token orelse return;
            r.remote.prepare() catch return; // transient; the next poll retries
            self.poll_state = .{ .polling = try self.onTier(r.remote, remotePollWorker, .{ gpa, r.remote, try gpa.dupe(u8, tk) }) };
        },
    }
}

/// Non-blocking: fold a finished backing poll. When the disk changed,
/// the external write is committed by the backing peer (merges with
/// unsaved local work — rev 4) and a stalled `.stale` save is cleared
/// for retry. Returns true when the buffer changed.
pub fn pollBacking(self: *Editor, gpa: Allocator) Allocator.Error!bool {
    switch (self.poll_state) {
        .polling => |*pending| {
            const result = pending.poll() orelse return false;
            self.poll_state = .idle;
            const fetched = result catch return false; // transient; next poll retries
            const f = fetched orelse {
                if (self.save_state == .stale) self.save_state = .idle;
                return false;
            };
            defer gpa.free(f.bytes);
            defer gpa.free(f.token);
            const sync = self.backingSync().?;
            const changed = try sync.mergeExternal(gpa, &self.doc, f.bytes, f.token);
            if (changed) try self.history.ingest(gpa, &self.doc);
            if (self.save_state == .stale) self.save_state = .idle;
            return changed;
        },
        else => return false,
    }
}

/// Does the document differ from what was last saved? (Version
/// comparison — content-identical-but-diverged counts as dirty, which
/// is the honest answer under concurrency.)
pub fn isDirty(self: *const Editor, gpa: Allocator) Allocator.Error!bool {
    const saved = self.saved_version orelse return self.doc.commitCount() > 0;
    const head = try self.doc.version(gpa);
    defer gpa.free(head);
    // Identical tokens are equal without causal comparison — which also
    // stays correct when the saved point sits below a compaction
    // horizon (causal comparison would refuse to look there).
    if (std.mem.eql(u8, saved, head)) return false;
    const order = self.doc.compareVersions(gpa, saved, head) catch return true;
    return order != .equal;
}

// ── Editing ─────────────────────────────────────────────────────────

/// The user peer's single mutation seam: delete `r` and insert `bytes` as
/// one commit, drop the selection and vertical goal, ingest into undo
/// history. Every interactive edit — typing, backspace, motion-operators —
/// funnels here, and so does `command.Context.edit`'s user fast-path, so
/// the two can never diverge on undo/goal/selection semantics. Peer edits
/// (plugins/agents) do NOT come here — they are that peer's own undo unit,
/// applied through the Document's peer API.
pub fn applyUserEdit(self: *Editor, gpa: Allocator, r: Range, bytes: []const u8) Allocator.Error!void {
    try self.applyUserEdits(gpa, &.{.{ .range = r, .bytes = bytes }});
}

/// The same seam for an edit at SEVERAL places — typing with N selections.
/// `items` must be ascending and non-overlapping (what `editRanges` returns);
/// `Document.replaceAll` applies them in reverse offset order as ONE commit,
/// so the whole multi-selection edit is one undo unit by construction rather
/// than by grouping several commits. One item is exactly the single-cursor
/// edit, byte for byte.
pub fn applyUserEdits(self: *Editor, gpa: Allocator, items: []const Document.Replacement) Allocator.Error!void {
    // A selection the edit REPLACES (typing or pasting over it) is spent: it
    // becomes a caret after what was written. A selection an edit merely
    // touches (an indent at its first line's start, a pair wrapped around
    // it) keeps its range, carried by its anchors.
    const replaced = try gpa.alloc(bool, self.selections.items.len);
    defer gpa.free(replaced);
    for (self.selections.items, replaced) |sel, *r| {
        const span = self.spanOf(sel);
        r.* = false;
        if (sel.anchor == null or span.isEmpty()) continue;
        for (items) |it| if (it.range.start == span.start and it.range.end == span.end) {
            r.* = true;
        };
    }
    try self.doc.replaceAll(gpa, items);
    for (self.selections.items, replaced) |*sel, r| {
        const a = sel.anchor orelse continue;
        // A selection an edit emptied is a caret, not an anchor waiting to
        // grow one on the next motion.
        if (r or self.doc.anchorOffset(a) == self.doc.anchorOffset(sel.head)) {
            self.doc.removeAnchor(a);
            sel.anchor = null;
        }
    }
    self.clearGoal();
    try self.history.ingest(gpa, &self.doc);
    // Two carets can land on one offset (backspace from both sides of a
    // character): fold them, as `setSelections` would have.
    self.normalize();
}

// ── Edit ranges (pure: compute where an edit lands, mutate nothing) ──
// The command builtins share these with the Editor methods below so the
// boundary logic (what "the scalar before the cursor" means) has one home,
// whether the edit is routed as the user (here) or a plugin peer (via
// command.Context.edit).

/// Which range an edit takes from each selection: typing replaces the
/// selection (or lands at the caret), backspace/delete remove it (or the
/// scalar before/after the caret).
pub const EditTarget = enum { insert, backward, forward };

/// `target`'s range for one selection, or null when it has nothing to act on
/// (backspace at the document start, delete at its end).
pub fn editRangeOf(self: *const Editor, sel: Selection, target: EditTarget) ?Range {
    if (self.rangeOf(sel)) |r| return r;
    const off = self.doc.anchorOffset(sel.head);
    return switch (target) {
        .insert => .{ .start = off, .end = off },
        .backward => if (off == 0) null else .{ .start = self.prevBoundary(off), .end = off },
        .forward => if (off == self.text().byteLen()) null else .{ .start = off, .end = self.nextBoundary(off) },
    };
}

/// `target`'s range for EVERY selection, ascending and disjoint — the shape
/// `applyUserEdits`/`Document.replaceAll` require. Ranges that would overlap
/// (two carets backspacing into one character) are unioned so a character is
/// removed once; coincident empty ranges collapse to one insertion point.
/// With one selection this is `[editRangeOf(primary)]` (or empty). Caller
/// frees.
pub fn editRanges(self: *const Editor, gpa: Allocator, target: EditTarget) Allocator.Error![]Range {
    var out: std.ArrayList(Range) = .empty;
    errdefer out.deinit(gpa);
    // Inside a visit the visited selection is the only one: a mapping runs
    // the edit once per selection itself.
    const all = self.selections.items;
    for (if (self.visiting > 0) all[self.primary..][0..1] else all) |sel| {
        if (self.editRangeOf(sel, target)) |r| try out.append(gpa, r);
    }
    sortRanges(out.items);
    var n: usize = 0;
    for (out.items) |r| {
        if (n > 0) {
            const prev = &out.items[n - 1];
            const touching_empty = r.start == prev.start and (r.isEmpty() or prev.isEmpty());
            if (r.start < prev.end or touching_empty) {
                prev.end = @max(prev.end, r.end);
                continue;
            }
        }
        out.items[n] = r;
        n += 1;
    }
    out.shrinkRetainingCapacity(n);
    return out.toOwnedSlice(gpa);
}

fn sortRanges(rs: []Range) void {
    std.mem.sort(Range, rs, {}, struct {
        fn lt(_: void, a: Range, b: Range) bool {
            return a.start < b.start or (a.start == b.start and a.end < b.end);
        }
    }.lt);
}

/// Where typed text lands: the selection it replaces, or an empty range
/// at the cursor.
pub fn insertRange(self: *const Editor) Range {
    return self.editRangeOf(self.primarySelection(), .insert).?;
}

/// What a backspace removes: the selection, or the scalar before the
/// cursor. Null when there is nothing to delete (cursor at start).
pub fn backspaceRange(self: *const Editor) ?Range {
    return self.editRangeOf(self.primarySelection(), .backward);
}

/// What a forward-delete removes: the selection, or the scalar after the
/// cursor. Null when the cursor is at the document end.
pub fn forwardRange(self: *const Editor) ?Range {
    return self.editRangeOf(self.primarySelection(), .forward);
}

/// Apply `bytes` over `target`'s range at every selection as one edit.
fn editAtSelections(self: *Editor, gpa: Allocator, target: EditTarget, bytes: []const u8) Allocator.Error!void {
    const ranges = try self.editRanges(gpa, target);
    defer gpa.free(ranges);
    if (ranges.len == 0) return;
    const items = try gpa.alloc(Document.Replacement, ranges.len);
    defer gpa.free(items);
    for (ranges, items) |r, *it| it.* = .{ .range = r, .bytes = bytes };
    try self.applyUserEdits(gpa, items);
}

/// Type at every selection (replacing each selection that is non-empty).
pub fn insertText(self: *Editor, gpa: Allocator, bytes: []const u8) Allocator.Error!void {
    try self.editAtSelections(gpa, .insert, bytes);
}

/// Backspace at every selection: its text, or the scalar before its caret.
pub fn deleteBackward(self: *Editor, gpa: Allocator) Allocator.Error!void {
    try self.editAtSelections(gpa, .backward, "");
}

/// Delete at every selection: its text, or the scalar after its caret.
pub fn deleteForward(self: *Editor, gpa: Allocator) Allocator.Error!void {
    try self.editAtSelections(gpa, .forward, "");
}

/// Delete an arbitrary range as one undoable unit (motions, operators).
pub fn deleteRange(self: *Editor, gpa: Allocator, r: Range) Allocator.Error!void {
    if (r.isEmpty()) return;
    try self.applyUserEdit(gpa, r, "");
}

/// `gate` is the invoking principal's authority over the inverse edit —
/// `command.Context.undoGate` on the dispatch path, `.user_driven` where a
/// human's keypress is the only possible source.
pub fn undo(self: *Editor, gpa: Allocator, gate: undo_mod.Gate) undo_mod.Error!bool {
    const did = try self.history.undo(gpa, &self.doc, gate);
    self.clearGoal();
    return did;
}

pub fn redo(self: *Editor, gpa: Allocator, gate: undo_mod.Gate) undo_mod.Error!bool {
    const did = try self.history.redo(gpa, &self.doc, gate);
    self.clearGoal();
    return did;
}

/// Whether `undo`/`redo` would find a unit right now — the availability the
/// history offers publish, read without touching the log.
pub fn canUndo(self: *const Editor) bool {
    return self.history.hasUndo(&self.doc);
}

pub fn canRedo(self: *const Editor) bool {
    return self.history.hasRedo(&self.doc);
}

// ── Selection ───────────────────────────────────────────────────────

// The single-selection API MEANS one selection. Every write through it —
// `moveTo` and the motions over it, `placeCursor`, `selectRange`, `setMark`,
// `clearSelection` — first collapses the set to its primary (`solo`), so a
// caret placed by a click, a jump, or a grammar that knows nothing of
// multiple selections never leaves stray secondaries behind to be typed
// into. Several selections are written only through `setSelections`/
// `addSelection`, and acted on one at a time only inside a visit.

/// Collapse the set to its primary, unless a per-selection runner is visiting
/// it (then the visited selection is the one selection, and its siblings are
/// the runner's to keep). Free for one selection.
fn solo(self: *Editor) void {
    if (self.visiting > 0 or self.selections.items.len == 1) return;
    self.dropSecondaries();
}

/// Drop an anchor at the head (replacing any it had): the selection starts
/// here and grows with the next motion.
pub fn setMark(self: *Editor, gpa: Allocator) Allocator.Error!void {
    self.solo();
    const sel = &self.selections.items[self.primary];
    const at = self.selectionEndsOf(sel.*).caretIn(self.text());
    const a = try self.doc.addAnchor(gpa, at, .left);
    if (sel.anchor) |m| self.doc.removeAnchor(m);
    sel.anchor = a;
    sel.inclusive = false;
    self.doc.anchors.set(sel.head, .{ .offset = at, .bias = .right });
}

/// Start an INCLUSIVE selection at the caret (vim's `v`): it covers the
/// character the caret is on at once, and grows through every character the
/// caret moves onto.
pub fn setInclusiveMark(self: *Editor, gpa: Allocator) Allocator.Error!void {
    const at = self.cursorOffset();
    try self.setMark(gpa);
    const sel = &self.selections.items[self.primary];
    sel.inclusive = true;
    self.doc.anchors.set(sel.anchor.?, .{ .offset = at, .bias = .left });
    self.doc.anchors.set(sel.head, .{ .offset = self.stepOffset(at, .fwd, .char), .bias = .right });
    self.normalize();
}

/// Lift the anchor, leaving one caret where the caret was (on an inclusive
/// selection, the character it was on — not the covered range's end).
pub fn clearSelection(self: *Editor) void {
    self.solo();
    const sel = &self.selections.items[self.primary];
    if (sel.inclusive) {
        self.doc.anchors.set(sel.head, .{ .offset = self.selectionEndsOf(sel.*).caretIn(self.text()), .bias = .right });
        sel.inclusive = false;
    }
    if (sel.anchor) |m| {
        self.doc.removeAnchor(m);
        sel.anchor = null;
    }
}

/// Select from `anchor` to `head` as THE selection: the anchor stays put, the
/// caret lands on the head (a drag, a grammar's "select this node").
pub fn selectRange(self: *Editor, gpa: Allocator, anchor: usize, head: usize) Allocator.Error!void {
    self.placeCursor(anchor);
    try self.setMark(gpa);
    self.placeCursor(head);
}

/// The primary selection's text range, or null when it is a caret.
pub fn selectedRange(self: *const Editor) ?Range {
    return self.rangeOf(self.primarySelection());
}

/// One selection's text range, or null when it is a caret (no anchor, or
/// an anchor at the head).
pub fn rangeOf(self: *const Editor, sel: Selection) ?Range {
    const m = sel.anchor orelse return null;
    const a = self.doc.anchorOffset(m);
    const b = self.doc.anchorOffset(sel.head);
    if (a == b) return null;
    return .{ .start = @min(a, b), .end = @max(a, b) };
}

// ── Visiting: the selection mapping's primitive ─────────────────────
// A selection mapping (`selection.zig`) runs a command once per
// selection, and that command speaks the single-selection API. Inside a visit
// that API addresses the visited selection alone: the one context where "the
// selection" is one of several on purpose.

/// Open a visit (they nest). Pair with `endVisit`.
pub fn beginVisit(self: *Editor) void {
    self.visiting += 1;
}

pub fn endVisit(self: *Editor) void {
    assert(self.visiting > 0);
    self.visiting -= 1;
}

/// Make selection `i` the one the single-selection API addresses. Only a
/// visit may: outside one, the next write would collapse the set onto it.
pub fn visit(self: *Editor, i: usize) void {
    assert(self.visiting > 0 and i < self.selections.items.len);
    self.primary = i;
}

// ── Multiple selections ─────────────────────────────────────────────
// The general case. A single-cursor grammar never calls these; one that does
// (helix, ide's add-next-match) replaces the set wholesale with
// `setSelections` and reads it back with `selectionEnds`.

pub fn selectionCount(self: *const Editor) usize {
    return self.selections.items.len;
}

/// Selection `i`'s endpoints (document order). A caret with no anchor reports
/// `anchor == head`.
pub fn selectionEnds(self: *const Editor, i: usize) Ends {
    return self.selectionEndsOf(self.selections.items[i]);
}

/// Replace every selection with `ends` (at least one), `primary` indexing
/// into it. Offsets are clamped to the document; `anchor == head` becomes a
/// caret. The result is normalized — sorted, overlaps merged — so the primary
/// index afterwards names wherever the requested primary landed. Allocates
/// the new handles before releasing the old ones: on failure the old set is
/// untouched.
pub fn setSelections(self: *Editor, gpa: Allocator, ends: []const Ends, primary: usize) Allocator.Error!void {
    assert(ends.len > 0);
    const len = self.text().byteLen();
    var next: std.ArrayList(Selection) = .empty;
    errdefer {
        for (next.items) |sel| self.releaseSelection(sel);
        next.deinit(gpa);
    }
    try next.ensureTotalCapacity(gpa, ends.len);
    for (ends) |e| {
        const head_off = @min(e.head, len);
        const anchor_off = @min(e.anchor, len);
        const head = try self.doc.addAnchor(gpa, head_off, .right);
        errdefer self.doc.removeAnchor(head);
        const anchor = if (anchor_off == head_off and !e.inclusive) null else try self.doc.addAnchor(gpa, anchor_off, .left);
        next.appendAssumeCapacity(.{ .head = head, .anchor = anchor, .inclusive = e.inclusive });
    }
    for (self.selections.items) |sel| self.releaseSelection(sel);
    self.selections.deinit(gpa);
    self.selections = next;
    self.primary = @min(primary, ends.len - 1);
    self.normalize();
    self.clearGoal();
    self.history.barrier(); // a selection change is a motion
}

/// Inside a visit: replace the VISITED selection with `ends` (at least one),
/// the first of them becoming the one the visit addresses; its siblings stay.
/// How a run splits its extent (`s`), or reshapes it. The visited selection
/// keeps its head HANDLE — re-pointed, not replaced — because a mapping names
/// its extents by those handles while it runs. Allocates first: on failure
/// the set is untouched.
pub fn replaceVisited(self: *Editor, gpa: Allocator, ends: []const Ends) Allocator.Error!void {
    assert(self.visiting > 0 and ends.len > 0);
    const len = self.text().byteLen();
    try self.selections.ensureUnusedCapacity(gpa, ends.len - 1);
    const fresh = try gpa.alloc(Selection, ends.len - 1);
    defer gpa.free(fresh);
    var made: usize = 0;
    errdefer for (fresh[0..made]) |sel| self.releaseSelection(sel);
    for (ends[1..], fresh) |e, *slot| {
        const head_off = @min(e.head, len);
        const anchor_off = @min(e.anchor, len);
        const head = try self.doc.addAnchor(gpa, head_off, .right);
        errdefer self.doc.removeAnchor(head);
        const anchor = if (anchor_off == head_off and !e.inclusive) null else try self.doc.addAnchor(gpa, anchor_off, .left);
        slot.* = .{ .head = head, .anchor = anchor, .inclusive = e.inclusive };
        made += 1;
    }
    const first = ends[0];
    const head_off = @min(first.head, len);
    const anchor_off = @min(first.anchor, len);
    const visited = &self.selections.items[self.primary];
    if ((anchor_off != head_off or first.inclusive) and visited.anchor == null)
        visited.anchor = try self.doc.addAnchor(gpa, anchor_off, .left);
    self.doc.anchors.set(visited.head, .{ .offset = head_off, .bias = .right });
    if (visited.anchor) |a| {
        if (anchor_off == head_off and !first.inclusive) {
            self.doc.removeAnchor(a);
            visited.anchor = null;
        } else self.doc.anchors.set(a, .{ .offset = anchor_off, .bias = .left });
    }
    visited.inclusive = first.inclusive;
    self.selections.appendSliceAssumeCapacity(fresh);
    self.normalize(); // the visited one stays primary wherever it lands
    self.clearGoal();
    self.history.barrier();
}

/// Add one selection and make it primary (helix `C`, ide's add-next-match).
pub fn addSelection(self: *Editor, gpa: Allocator, e: Ends) Allocator.Error!void {
    const len = self.text().byteLen();
    try self.selections.ensureUnusedCapacity(gpa, 1);
    const head = try self.doc.addAnchor(gpa, @min(e.head, len), .right);
    errdefer self.doc.removeAnchor(head);
    const anchor = if (@min(e.anchor, len) == @min(e.head, len) and !e.inclusive) null else try self.doc.addAnchor(gpa, @min(e.anchor, len), .left);
    self.selections.appendAssumeCapacity(.{ .head = head, .anchor = anchor, .inclusive = e.inclusive });
    self.primary = self.selections.items.len - 1;
    self.normalize();
    self.history.barrier();
}

/// Drop selection `i`. The last selection cannot be removed — an editor
/// always has a caret — so this is a no-op then. The primary stays on the
/// same selection, or moves to the one before a removed primary.
pub fn removeSelection(self: *Editor, i: usize) void {
    if (self.selections.items.len <= 1 or i >= self.selections.items.len) return;
    self.releaseSelection(self.selections.orderedRemove(i));
    if (self.primary > i or (self.primary == i and i > 0)) self.primary -= 1;
    self.history.barrier();
}

/// Keep only the primary selection (helix `,`, ide's Escape).
pub fn collapseToPrimary(self: *Editor) void {
    self.dropSecondaries();
    self.history.barrier();
}

fn dropSecondaries(self: *Editor) void {
    const keep = self.primarySelection();
    for (self.selections.items, 0..) |sel, i| {
        if (i != self.primary) self.releaseSelection(sel);
    }
    self.selections.items[0] = keep;
    self.selections.shrinkRetainingCapacity(1);
    self.primary = 0;
}

fn releaseSelection(self: *Editor, sel: Selection) void {
    self.doc.removeAnchor(sel.head);
    if (sel.anchor) |a| self.doc.removeAnchor(a);
}

/// Restore the selection invariant: document order by start, and no two
/// selections overlapping or sharing a caret. Merging is a union; the merged
/// selection keeps the earlier one's direction, and is primary if either half
/// was. A no-op for one selection, so the single-cursor case never pays for
/// it or observes it.
pub fn normalize(self: *Editor) void {
    const items = self.selections.items;
    if (items.len < 2) return;
    const primary_head = items[self.primary].head;
    std.mem.sort(Selection, items, @as(*const Editor, self), struct {
        fn lt(ed: *const Editor, a: Selection, b: Selection) bool {
            const ra = ed.spanOf(a);
            const rb = ed.spanOf(b);
            return ra.start < rb.start or (ra.start == rb.start and ra.end < rb.end);
        }
    }.lt);
    var primary: usize = 0;
    var n: usize = 0;
    for (items) |sel| {
        const is_primary = sel.head == primary_head;
        if (n > 0) {
            const prev = &items[n - 1];
            const pr = self.spanOf(prev.*);
            const r = self.spanOf(sel);
            const touching_empty = r.start == pr.start and (r.isEmpty() or pr.isEmpty());
            if (r.start < pr.end or touching_empty) {
                self.mergeInto(prev, sel, .{ .start = pr.start, .end = @max(pr.end, r.end) });
                if (is_primary) primary = n - 1;
                continue;
            }
        }
        items[n] = sel;
        if (is_primary) primary = n;
        n += 1;
    }
    self.selections.shrinkRetainingCapacity(n);
    self.primary = primary;
}

/// A selection's span, caret or not (`rangeOf` answers null for a caret).
fn spanOf(self: *const Editor, sel: Selection) Range {
    const e = self.selectionEndsOf(sel);
    return .{ .start = @min(e.anchor, e.head), .end = @max(e.anchor, e.head) };
}

fn selectionEndsOf(self: *const Editor, sel: Selection) Ends {
    const head = self.doc.anchorOffset(sel.head);
    return .{ .anchor = if (sel.anchor) |a| self.doc.anchorOffset(a) else head, .head = head, .inclusive = sel.inclusive };
}

/// Fold `other` into `into`, spanning `span`. Reuses handles rather than
/// allocating (a merge cannot fail): the union needs at most the two handles
/// `into` may already own plus `other`'s, re-pointed by `AnchorSet.set` with
/// the bias of the role each now plays.
fn mergeInto(self: *Editor, into: *Selection, other: Selection, span: Range) void {
    const e = self.selectionEndsOf(into.*);
    const forward = e.head >= e.anchor;
    const head_off = if (forward) span.end else span.start;
    const anchor_off = if (forward) span.start else span.end;
    self.doc.anchors.set(into.head, .{ .offset = head_off, .bias = .right });
    if (span.isEmpty()) {
        if (into.anchor) |a| self.doc.removeAnchor(a);
        into.anchor = null;
        self.releaseSelection(other);
        return;
    }
    // Need an anchor: keep ours, else adopt one of `other`'s handles.
    var spare_head: ?stemma.AnchorSet.Handle = other.head;
    var spare_anchor = other.anchor;
    const anchor = into.anchor orelse blk: {
        if (spare_anchor) |a| {
            spare_anchor = null;
            break :blk a;
        }
        spare_head = null;
        break :blk other.head;
    };
    self.doc.anchors.set(anchor, .{ .offset = anchor_off, .bias = .left });
    into.anchor = anchor;
    if (spare_head) |h| self.doc.removeAnchor(h);
    if (spare_anchor) |a| self.doc.removeAnchor(a);
}

// ── Movement ────────────────────────────────────────────────────────
// Every motion is an undo barrier: typing after moving starts a new
// undo unit (the vim-flavored grouping). A motion is a single-selection write:
// it collapses the set to the primary and moves that (inside a visit, the
// visited selection alone). A grammar that moves every selection computes the
// targets itself and hands them to `setSelections`.

pub fn moveTo(self: *Editor, offset: usize) void {
    self.solo();
    const sel = self.primarySelection();
    if (sel.inclusive) if (sel.anchor) |a| {
        // The caret goes onto `offset`'s character; the range still covers
        // the anchor's, whichever side of it the caret now is.
        const pinned = self.selectionEndsOf(sel).pinnedIn(self.text());
        const forward = offset >= pinned;
        self.doc.anchors.set(a, .{ .offset = if (forward) pinned else self.stepOffset(pinned, .fwd, .char), .bias = .left });
        self.doc.anchors.set(sel.head, .{ .offset = if (forward) self.stepOffset(offset, .fwd, .char) else offset, .bias = .right });
        self.normalize();
        self.history.barrier();
        return;
    };
    self.doc.anchors.set(sel.head, .{ .offset = offset, .bias = .right });
    // Moving one head can carry it onto or past another selection; keep the
    // set sorted and disjoint (free for a single selection).
    self.normalize();
    self.history.barrier();
}

/// Both vertical goals reset together: any horizontal or edit motion
/// abandons the column/x the user was aiming for.
pub fn clearGoal(self: *Editor) void {
    self.goal_col = null;
    self.goal_x = null;
}

// ── Geometry seam ────────────────────────────────────────────────────
// The view owns rendered geometry (which pixel a source offset lands on);
// the Editor stays geometry-free and is the sole writer of cursor state.
// The view computes a target offset + goal-x and hands them here.

/// Place the cursor at an absolute offset (a click, or any geometry-free
/// jump). Clears both vertical goals — a click is a fresh aim point.
pub fn placeCursor(self: *Editor, offset: usize) void {
    self.moveTo(offset);
    self.clearGoal();
}

/// Vertical motion resolved by the view: move to `offset` while keeping
/// `goal_x` (world px) sticky for the next up/down. The view found
/// `offset` as the nearest caret to `goal_x` on the target row.
pub fn moveToVisual(self: *Editor, offset: usize, goal_x: f32) void {
    self.moveTo(offset);
    self.goal_x = goal_x; // survives the motion (moveTo clears nothing)
}

pub fn goalX(self: *const Editor) ?f32 {
    return self.goal_x;
}

pub fn setGoalX(self: *Editor, x: f32) void {
    self.goal_x = x;
}

fn prevBoundary(self: *const Editor, off: usize) usize {
    const rope = self.text();
    const s = rope.offsetToScalar(off);
    return rope.scalarToOffset(s - 1);
}

fn nextBoundary(self: *const Editor, off: usize) usize {
    const rope = self.text();
    const s = rope.offsetToScalar(off);
    return rope.scalarToOffset(s + 1);
}

pub const StepDir = enum(u32) { back = 0, fwd = 1 };
pub const StepKind = enum(u32) { char = 0, line = 1 };

/// The native `editor.step` primitive (design §6.1, carve rule b): the target
/// offset one grapheme/scalar (char) or one line (byte-column) from `from`, in
/// `dir`, WITHOUT moving the live cursor. Pure — a plugin motion composes it and
/// returns a range; the Editor's stateful cursor motions (`moveLeft` etc.) are
/// thin wrappers left for the core key path. Line motion is byte-column here
/// (headless-correct); layout goal-x vertical motion lives in the view.
pub fn stepOffset(self: *const Editor, from: usize, dir: StepDir, kind: StepKind) usize {
    const rope = self.text();
    const len = rope.byteLen();
    const f = @min(from, len);
    switch (kind) {
        .char => return switch (dir) {
            .back => if (f == 0) 0 else self.prevBoundary(f),
            .fwd => if (f >= len) len else self.nextBoundary(f),
        },
        .line => {
            const pt = rope.offsetToPoint(f);
            const rows = rope.lineCount();
            const target_row = self.nextVisibleRow(pt.row, if (dir == .back) -1 else 1, rows) orelse return f;
            const line = rope.lineRange(target_row);
            const col = @min(pt.col, line.len());
            return snapBoundary(rope, line.start + col);
        },
    }
}

pub fn moveLeft(self: *Editor) void {
    const off = self.cursorOffset();
    if (off > 0) self.moveTo(self.prevBoundary(off));
    self.clearGoal();
}

pub fn moveRight(self: *Editor) void {
    const off = self.cursorOffset();
    if (off < self.text().byteLen()) self.moveTo(self.nextBoundary(off));
    self.clearGoal();
}

pub fn moveUp(self: *Editor) void {
    self.moveVertical(-1);
}

pub fn moveDown(self: *Editor) void {
    self.moveVertical(1);
}

fn moveVertical(self: *Editor, dir: i2) void {
    const rope = self.text();
    const p = rope.offsetToPoint(self.cursorOffset());
    const goal = self.goal_col orelse p.col;
    const rows = rope.lineCount();
    const target_row = self.nextVisibleRow(p.row, dir, rows) orelse return;
    const line = rope.lineRange(target_row);
    const col = @min(goal, line.len());
    self.moveTo(snapBoundary(rope, line.start + col));
    self.goal_col = goal; // survives the motion (moveTo clears nothing)
}

/// Is document `row` hidden by a fold (its line-start inside an invisible
/// span)? Resolves the fold layer on demand — cheap: folds are few and this
/// is called per visible row + per vertical step.
pub fn rowHidden(self: *const Editor, row: usize) bool {
    const layer = self.fold_layer orelse return false;
    const n = layer.spanCount();
    if (n == 0) return false;
    const line = self.text().lineRange(row);
    for (0..n) |i| {
        const s = layer.resolvedSpan(i);
        if (s.face.invisible and line.start >= s.start and line.start < s.end) return true;
    }
    return false;
}

/// The next VISIBLE row from `row` stepping by `dir` (±1), skipping folded
/// rows, or null at the document edge. The single fold-aware successor the
/// motion + render paths share (see design: no per-call row math elsewhere).
pub fn nextVisibleRow(self: *const Editor, row: usize, dir: i2, rows: usize) ?usize {
    var r = row;
    while (true) {
        if (dir < 0) {
            if (r == 0) return null;
            r -= 1;
        } else {
            if (r + 1 >= rows) return null;
            r += 1;
        }
        if (!self.rowHidden(r)) return r;
    }
}

// Word/WORD/line/doc motions and match-bracket moved to the `motions` plugin
// (design §6.1). Core keeps only the grapheme/line step primitive (`stepOffset`
// above) and the small scan helpers the completion prefix still needs.

fn wordChar(b: u8) bool {
    return std.ascii.isAlphanumeric(b) or b == '_' or b >= 0x80;
}

/// Snap a byte offset to the scalar boundary at or before it (byte
/// windows and byte columns can land inside a UTF-8 sequence; rope
/// coordinate APIs assert boundaries).
fn snapBoundary(rope: *const stemma.Rope, off: usize) usize {
    var o = @min(off, rope.byteLen());
    while (o > 0 and o < rope.byteLen()) {
        var b: [1]u8 = undefined;
        var sr = rope.streamReader(.{ .start = o, .end = o + 1 }, &.{});
        sr.interface.readSliceAll(&b) catch unreachable;
        if ((b[0] & 0xC0) != 0x80) break;
        o -= 1;
    }
    return o;
}

fn readRange(gpa: Allocator, rope: *const stemma.Rope, r: Range) Allocator.Error![]u8 {
    const buf = try gpa.alloc(u8, r.len());
    errdefer gpa.free(buf);
    var sr = rope.streamReader(r, &.{});
    sr.interface.readSliceAll(buf) catch unreachable;
    return buf;
}

test {
    std.testing.refAllDecls(@This());
}

/// The word fragment immediately before the cursor (completion prefix);
/// caller frees. Empty when the cursor doesn't follow a word char.
pub fn wordPrefix(self: *const Editor, gpa: Allocator) Allocator.Error![]u8 {
    const off = self.cursorOffset();
    const start = off -| 128;
    const buf = try readRange(gpa, self.text(), .{ .start = start, .end = off });
    defer gpa.free(buf);
    var i = buf.len;
    while (i > 0 and wordChar(buf[i - 1])) i -= 1;
    return gpa.dupe(u8, buf[i..]);
}
