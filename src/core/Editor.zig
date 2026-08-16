//! Editor — the interactive shell around one Document: cursor and
//! selection (anchors in the Document's auto-shifted AnchorSet, never
//! bare offsets), movement over the rope's line/scalar queries, undo
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
const undo_mod = @import("undo.zig");
const task = @import("task.zig");
const file = @import("file.zig");
const backing_mod = @import("backing.zig");
const ShellFs = @import("ShellFs.zig");
const Range = stemma.Range;

const Editor = @This();

doc: Document,
history: undo_mod.UndoLog = .empty,
/// Insertion point; bias .right so text typed at the cursor pushes it
/// forward, and other peers' inserts at the cursor do the same.
cursor: stemma.AnchorSet.Handle,
/// Selection = mark..cursor (either order), when a mark is set.
mark: ?stemma.AnchorSet.Handle = null,
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

pub const SaveError = file.GuardedWriteError || ShellFs.WriteError;
pub const PollError = file.ReadError || ShellFs.Error || Allocator.Error;

pub const SaveState = union(enum) {
    idle,
    /// A save is in flight; the version it snapshots. The worker
    /// returns the written content's token.
    saving: struct { handle: task.Handle(SaveError![]u8), version: []u8 },
    /// The disk moved under us — poll the backing (merges the external
    /// write), then request again. Cleared by `pollBacking`.
    stale,
    /// Terminal state of the last save attempt, until the next request.
    failed: SaveError,
};

pub const PollState = union(enum) {
    idle,
    polling: task.Handle(PollError!?file.Fetched),
};

pub fn init(gpa: Allocator, pool: *task.Pool, user_agent: []const u8) Allocator.Error!Editor {
    var doc = try Document.init(gpa, user_agent);
    errdefer doc.deinit(gpa);
    const cursor = try doc.addAnchor(gpa, 0, .right);
    return .{ .doc = doc, .cursor = cursor, .pool = pool };
}

pub fn deinit(self: *Editor, gpa: Allocator) void {
    // Work in flight owns snapshots and returns gpa-owned tokens; wait
    // it out (shutdown path, blocking allowed) so nothing leaks.
    switch (self.save_state) {
        .saving => |*s| {
            var h = s.handle;
            while (true) {
                if (h.poll()) |result| {
                    if (result) |token| gpa.free(token) else |_| {}
                    break;
                }
                std.atomic.spinLoopHint();
            }
            gpa.free(s.version);
        },
        else => {},
    }
    switch (self.poll_state) {
        .polling => |*h| {
            var handle = h.*;
            while (true) {
                if (handle.poll()) |result| {
                    if (result) |maybe| {
                        if (maybe) |f| {
                            gpa.free(f.bytes);
                            gpa.free(f.token);
                        }
                    } else |_| {}
                    break;
                }
                std.atomic.spinLoopHint();
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
        .shell => |*s| {
            s.sync.deinit(gpa, &self.doc);
            gpa.free(s.path);
        },
        .tool => |t_| gpa.free(t_.name),
    }
    self.history.deinit(gpa);
    self.doc.deinit(gpa);
    if (self.saved_version) |v| gpa.free(v);
    self.* = undefined;
}

pub fn text(self: *const Editor) *const stemma.Rope {
    return self.doc.text();
}

pub fn cursorOffset(self: *const Editor) usize {
    return self.doc.anchorOffset(self.cursor);
}

// ── Files & backings ────────────────────────────────────────────────

/// The display/save path, when the backing has one.
pub fn backingPath(self: *const Editor) ?[]const u8 {
    return switch (self.backing) {
        .file => |f| f.path,
        .shell => |s| s.path,
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
    self.doc.anchors.set(self.cursor, .{ .offset = 0, .bias = .right });
}

/// Above this, loads go through the bulk path (content becomes the
/// compacted base, zero events) instead of per-scalar events. The
/// trade: identity anchors into the loaded content report Compacted.
pub const bulk_load_bytes = 1 << 20;

/// Open a local file as this buffer's backing: content arrives as the
/// backing peer's commit (not undoable) — or, for large files, as a
/// compacted base. Startup path, allowed to block. The document must
/// not already have a backing.
pub fn openFile(self: *Editor, gpa: Allocator, path: []const u8) (Allocator.Error || file.ReadError || Document.AddPeerError)!void {
    task.assertMayBlock();
    assert(self.backing == .none);
    const bytes = try file.readAlloc(gpa, path);
    defer gpa.free(bytes);
    const token = backing_mod.localToken(bytes);
    var sync = if (bytes.len >= bulk_load_bytes) blk: {
        try self.doc.adoptContent(gpa, bytes);
        var sync = try backing_mod.Sync.init(gpa, &self.doc);
        errdefer sync.deinit(gpa, &self.doc);
        try sync.loadBased(gpa, &self.doc, &token);
        break :blk sync;
    } else blk: {
        var sync = try backing_mod.Sync.init(gpa, &self.doc);
        errdefer sync.deinit(gpa, &self.doc);
        try sync.load(gpa, &self.doc, bytes, &token);
        break :blk sync;
    };
    errdefer sync.deinit(gpa, &self.doc);
    self.backing = .{ .file = .{ .path = try gpa.dupe(u8, path), .sync = sync } };
    try self.setBackingLoaded(gpa);
}

/// Open a remote file over a persistent shell (coreutils tier). Blocks
/// (two shell round-trips); startup/open path.
pub fn openShell(self: *Editor, gpa: Allocator, fs: *ShellFs, path: []const u8) (Allocator.Error || ShellFs.Error || Document.AddPeerError)!void {
    task.assertMayBlock();
    assert(self.backing == .none);
    const bytes = try fs.readAll(gpa, path);
    defer gpa.free(bytes);
    const token = try fs.hashToken(gpa, path);
    defer gpa.free(token);
    var sync = try backing_mod.Sync.init(gpa, &self.doc);
    errdefer sync.deinit(gpa, &self.doc);
    try sync.load(gpa, &self.doc, bytes, token);
    self.backing = .{ .shell = .{ .fs = fs, .path = try gpa.dupe(u8, path), .sync = sync } };
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
        .shell => |*s| &s.sync,
        else => null,
    };
}

fn fileSaveWorker(gpa: Allocator, path: []u8, rope: stemma.Rope, expected: ?[]u8) SaveError![]u8 {
    return file.writeRopeGuarded(gpa, path, rope, expected);
}

fn filePollWorker(gpa: Allocator, path: []u8, expected: []u8) PollError!?file.Fetched {
    return file.pollFile(gpa, path, expected);
}

fn shellSaveWorker(gpa: Allocator, fs: *ShellFs, path: []u8, bytes: []u8, expected: ?[]u8) SaveError![]u8 {
    defer gpa.free(path);
    defer gpa.free(bytes);
    defer if (expected) |e| gpa.free(e);
    return fs.writeGuarded(gpa, path, bytes, expected);
}

fn shellPollWorker(gpa: Allocator, fs: *ShellFs, path: []u8, expected: []u8) PollError!?file.Fetched {
    defer gpa.free(path);
    defer gpa.free(expected);
    const token = try fs.hashToken(gpa, path);
    if (std.mem.eql(u8, token, expected)) {
        gpa.free(token);
        return null;
    }
    errdefer gpa.free(token);
    const bytes = try fs.readAll(gpa, path);
    return .{ .bytes = bytes, .token = token };
}

/// Request a guarded save: O(1) rope snapshot + version token, written
/// by a pool worker (upload/temp + test-and-set rename). Never blocks;
/// fold with `pollSave`. A request while one is in flight is dropped
/// (poll first; the editor loop does). `.stale` means the disk moved —
/// poll the backing (which merges), then request again.
pub fn requestSave(self: *Editor, gpa: Allocator) Allocator.Error!void {
    if (self.save_state == .saving) return;
    const version = try self.doc.version(gpa);
    errdefer gpa.free(version);
    const handle: task.Handle(SaveError![]u8) = switch (self.backing) {
        .none, .tool => {
            gpa.free(version);
            return;
        },
        .file => |f| try self.pool.spawn(fileSaveWorker, .{
            gpa,
            try gpa.dupe(u8, f.path),
            self.doc.text().snapshot(),
            if (f.sync.token) |tk| try gpa.dupe(u8, tk) else null,
        }),
        .shell => |s| blk: {
            var snap = self.doc.text().snapshot();
            defer snap.deinit(gpa);
            const bytes = try snap.toOwnedSlice(gpa);
            errdefer gpa.free(bytes);
            break :blk try self.pool.spawn(shellSaveWorker, .{
                gpa,
                s.fs,
                try gpa.dupe(u8, s.path),
                bytes,
                if (s.sync.token) |tk| try gpa.dupe(u8, tk) else null,
            });
        },
    };
    self.save_state = .{ .saving = .{ .handle = handle, .version = version } };
}

/// Non-blocking: fold a finished save into state. Returns true when a
/// save completed successfully since the last poll. On success the
/// backing mirror advances to exactly the saved version.
pub fn pollSave(self: *Editor, gpa: Allocator) bool {
    switch (self.save_state) {
        .saving => |*s| {
            var h = s.handle;
            const result = h.poll() orelse return false;
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
        .none, .tool => {},
        .file => |f| {
            const tk = f.sync.token orelse return;
            self.poll_state = .{ .polling = try self.pool.spawn(filePollWorker, .{
                gpa, try gpa.dupe(u8, f.path), try gpa.dupe(u8, tk),
            }) };
        },
        .shell => |s| {
            const tk = s.sync.token orelse return;
            self.poll_state = .{ .polling = try self.pool.spawn(shellPollWorker, .{
                gpa, s.fs, try gpa.dupe(u8, s.path), try gpa.dupe(u8, tk),
            }) };
        },
    }
}

/// Non-blocking: fold a finished backing poll. When the disk changed,
/// the external write is committed by the backing peer (merges with
/// unsaved local work — rev 4) and a stalled `.stale` save is cleared
/// for retry. Returns true when the buffer changed.
pub fn pollBacking(self: *Editor, gpa: Allocator) Allocator.Error!bool {
    switch (self.poll_state) {
        .polling => |*h| {
            var handle = h.*;
            const result = handle.poll() orelse return false;
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

/// Type at the cursor (replacing the selection if one is active).
pub fn insertText(self: *Editor, gpa: Allocator, bytes: []const u8) Allocator.Error!void {
    if (self.selectedRange()) |r| {
        try self.doc.replaceAll(gpa, &.{.{ .range = r, .bytes = bytes }});
        self.clearSelection();
    } else {
        try self.doc.insert(gpa, self.cursorOffset(), bytes);
    }
    self.clearGoal();
    try self.history.ingest(gpa, &self.doc);
}

/// Backspace: delete the selection, or the scalar before the cursor.
pub fn deleteBackward(self: *Editor, gpa: Allocator) Allocator.Error!void {
    const r = self.selectedRange() orelse blk: {
        const off = self.cursorOffset();
        if (off == 0) return;
        break :blk Range{ .start = self.prevBoundary(off), .end = off };
    };
    try self.doc.delete(gpa, r);
    self.clearSelection();
    self.clearGoal();
    try self.history.ingest(gpa, &self.doc);
}

/// Delete: the selection, or the scalar after the cursor.
pub fn deleteForward(self: *Editor, gpa: Allocator) Allocator.Error!void {
    const r = self.selectedRange() orelse blk: {
        const off = self.cursorOffset();
        if (off == self.text().byteLen()) return;
        break :blk Range{ .start = off, .end = self.nextBoundary(off) };
    };
    try self.doc.delete(gpa, r);
    self.clearSelection();
    self.clearGoal();
    try self.history.ingest(gpa, &self.doc);
}

/// Delete an arbitrary range as one undoable unit (motions, operators).
pub fn deleteRange(self: *Editor, gpa: Allocator, r: Range) Allocator.Error!void {
    if (r.isEmpty()) return;
    try self.doc.delete(gpa, r);
    self.clearSelection();
    self.clearGoal();
    try self.history.ingest(gpa, &self.doc);
}

pub fn undo(self: *Editor, gpa: Allocator) Allocator.Error!bool {
    const did = try self.history.undo(gpa, &self.doc);
    self.clearGoal();
    return did;
}

pub fn redo(self: *Editor, gpa: Allocator) Allocator.Error!bool {
    const did = try self.history.redo(gpa, &self.doc);
    self.clearGoal();
    return did;
}

// ── Selection ───────────────────────────────────────────────────────

pub fn setMark(self: *Editor, gpa: Allocator) Allocator.Error!void {
    self.clearSelection();
    self.mark = try self.doc.addAnchor(gpa, self.cursorOffset(), .left);
}

pub fn clearSelection(self: *Editor) void {
    if (self.mark) |m| {
        self.doc.removeAnchor(m);
        self.mark = null;
    }
}

pub fn selectedRange(self: *const Editor) ?Range {
    const m = self.mark orelse return null;
    const a = self.doc.anchorOffset(m);
    const b = self.cursorOffset();
    if (a == b) return null;
    return .{ .start = @min(a, b), .end = @max(a, b) };
}

// ── Movement ────────────────────────────────────────────────────────
// Every motion is an undo barrier: typing after moving starts a new
// undo unit (the vim-flavored grouping).

fn moveTo(self: *Editor, offset: usize) void {
    self.doc.anchors.set(self.cursor, .{ .offset = offset, .bias = .right });
    self.history.barrier();
}

/// Both vertical goals reset together: any horizontal or edit motion
/// abandons the column/x the user was aiming for.
fn clearGoal(self: *Editor) void {
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
    const target_row = if (dir < 0)
        (if (p.row == 0) return else p.row - 1)
    else
        (if (p.row + 1 >= rows) return else p.row + 1);
    const line = rope.lineRange(target_row);
    const col = @min(goal, line.len());
    self.moveTo(snapBoundary(rope, line.start + col));
    self.goal_col = goal; // survives the motion (moveTo clears nothing)
}

pub fn moveLineStart(self: *Editor) void {
    const rope = self.text();
    const p = rope.offsetToPoint(self.cursorOffset());
    self.moveTo(rope.lineRange(p.row).start);
    self.clearGoal();
}

pub fn moveLineEnd(self: *Editor) void {
    const rope = self.text();
    const p = rope.offsetToPoint(self.cursorOffset());
    self.moveTo(rope.lineRange(p.row).end);
    self.clearGoal();
}

pub fn moveDocStart(self: *Editor) void {
    self.moveTo(0);
    self.clearGoal();
}

pub fn moveDocEnd(self: *Editor) void {
    self.moveTo(self.text().byteLen());
    self.clearGoal();
}

fn wordChar(b: u8) bool {
    return std.ascii.isAlphanumeric(b) or b == '_' or b >= 0x80;
}

/// Forward to the start of the next word (ASCII-classed; non-ASCII
/// counts as word bytes).
pub fn moveWordForward(self: *Editor, gpa: Allocator) Allocator.Error!void {
    const off = try self.scanWord(gpa, self.cursorOffset(), .forward);
    self.moveTo(off);
    self.clearGoal();
}

/// Backward to the start of the previous word.
pub fn moveWordBackward(self: *Editor, gpa: Allocator) Allocator.Error!void {
    const off = try self.scanWord(gpa, self.cursorOffset(), .backward);
    self.moveTo(off);
    self.clearGoal();
}

/// Forward to the END of the current/next word (vim `e`): the last word
/// byte of the next word run.
pub fn moveWordEnd(self: *Editor, gpa: Allocator) Allocator.Error!void {
    const rope = self.text();
    const len = rope.byteLen();
    const off = self.cursorOffset();
    if (off >= len) return;
    const end = @min(len, off + 4096);
    const buf = try readRange(gpa, rope, .{ .start = off, .end = end });
    defer gpa.free(buf);
    var i: usize = 1; // always advance at least one
    while (i < buf.len and !wordChar(buf[i])) i += 1; // skip to a word
    while (i + 1 < buf.len and wordChar(buf[i + 1])) i += 1; // to its last byte
    self.moveTo(snapBoundary(rope, off + @min(i, buf.len -| 1)));
    self.clearGoal();
}

fn isSpaceByte(b: u8) bool {
    return b == ' ' or b == '\t' or b == '\n' or b == '\r';
}

/// Forward to the next WORD start — whitespace-delimited (vim `W`).
pub fn moveWORDForward(self: *Editor, gpa: Allocator) Allocator.Error!void {
    const rope = self.text();
    const len = rope.byteLen();
    const off = self.cursorOffset();
    if (off >= len) return;
    const buf = try readRange(gpa, rope, .{ .start = off, .end = @min(len, off + 4096) });
    defer gpa.free(buf);
    var i: usize = 0;
    while (i < buf.len and !isSpaceByte(buf[i])) i += 1; // over this WORD
    while (i < buf.len and isSpaceByte(buf[i])) i += 1; // over the gap
    self.moveTo(snapBoundary(rope, off + i));
    self.clearGoal();
}

/// Backward to the previous WORD start — whitespace-delimited (vim `B`).
pub fn moveWORDBackward(self: *Editor, gpa: Allocator) Allocator.Error!void {
    const rope = self.text();
    const off = self.cursorOffset();
    if (off == 0) return;
    const start = off -| 4096;
    const buf = try readRange(gpa, rope, .{ .start = start, .end = off });
    defer gpa.free(buf);
    var i: usize = buf.len;
    while (i > 0 and isSpaceByte(buf[i - 1])) i -= 1; // over the gap
    while (i > 0 and !isSpaceByte(buf[i - 1])) i -= 1; // over the WORD
    self.moveTo(snapBoundary(rope, start + i));
    self.clearGoal();
}

/// Forward to the end of the next WORD — whitespace-delimited (vim `E`).
pub fn moveWORDEnd(self: *Editor, gpa: Allocator) Allocator.Error!void {
    const rope = self.text();
    const len = rope.byteLen();
    const off = self.cursorOffset();
    if (off >= len) return;
    const buf = try readRange(gpa, rope, .{ .start = off, .end = @min(len, off + 4096) });
    defer gpa.free(buf);
    var i: usize = 1;
    while (i < buf.len and isSpaceByte(buf[i])) i += 1; // to a WORD
    while (i + 1 < buf.len and !isSpaceByte(buf[i + 1])) i += 1; // to its last byte
    self.moveTo(snapBoundary(rope, off + @min(i, buf.len -| 1)));
    self.clearGoal();
}

/// Jump to the bracket matching the first bracket at/after the cursor on
/// the line, honoring nesting (bounded scan). No-op if none is found.
pub fn matchBracket(self: *Editor, gpa: Allocator) Allocator.Error!void {
    const rope = self.text();
    const len = rope.byteLen();
    const start = self.cursorOffset();
    // Find the first bracket from the cursor to the line end.
    const line_end = rope.lineRange(rope.offsetToPoint(start).row).end;
    const head = try readRange(gpa, rope, .{ .start = start, .end = line_end });
    defer gpa.free(head);
    var bi: usize = 0;
    while (bi < head.len and bracketOf(head[bi]) == null) bi += 1;
    if (bi >= head.len) return;
    const open = head[bi];
    const bpos = start + bi;
    const b = bracketOf(open).?;
    const window = 1 << 16;
    if (b.forward) {
        const scan_end = @min(len, bpos + window);
        const buf = try readRange(gpa, rope, .{ .start = bpos, .end = scan_end });
        defer gpa.free(buf);
        var depth: i32 = 0;
        for (buf, 0..) |c, k| {
            if (c == open) depth += 1 else if (c == b.match) {
                depth -= 1;
                if (depth == 0) {
                    self.moveTo(snapBoundary(rope, bpos + k));
                    self.clearGoal();
                    return;
                }
            }
        }
    } else {
        const scan_start = bpos + 1 -| window;
        const buf = try readRange(gpa, rope, .{ .start = scan_start, .end = bpos + 1 });
        defer gpa.free(buf);
        var depth: i32 = 0;
        var k: usize = buf.len;
        while (k > 0) {
            k -= 1;
            const c = buf[k];
            if (c == open) depth += 1 else if (c == b.match) {
                depth -= 1;
                if (depth == 0) {
                    self.moveTo(snapBoundary(rope, scan_start + k));
                    self.clearGoal();
                    return;
                }
            }
        }
    }
}

const Bracket = struct { match: u8, forward: bool };

fn bracketOf(c: u8) ?Bracket {
    return switch (c) {
        '(' => .{ .match = ')', .forward = true },
        '[' => .{ .match = ']', .forward = true },
        '{' => .{ .match = '}', .forward = true },
        ')' => .{ .match = '(', .forward = false },
        ']' => .{ .match = '[', .forward = false },
        '}' => .{ .match = '{', .forward = false },
        else => null,
    };
}

const WordDir = enum { forward, backward };

/// Word scan over a bounded window around the cursor (a line-ish span
/// read out of the rope; words longer than the window degrade to
/// window-hop, which is fine).
fn scanWord(self: *const Editor, gpa: Allocator, off: usize, dir: WordDir) Allocator.Error!usize {
    const rope = self.text();
    const len = rope.byteLen();
    const window = 4096;
    switch (dir) {
        .forward => {
            if (off >= len) return len;
            const end = @min(len, off + window);
            const buf = try readRange(gpa, rope, .{ .start = off, .end = end });
            defer gpa.free(buf);
            var i: usize = 0;
            while (i < buf.len and wordChar(buf[i])) i += 1;
            while (i < buf.len and !wordChar(buf[i])) i += 1;
            return snapBoundary(rope, off + i);
        },
        .backward => {
            if (off == 0) return 0;
            const start = off -| window;
            const buf = try readRange(gpa, rope, .{ .start = start, .end = off });
            defer gpa.free(buf);
            var i: usize = buf.len;
            while (i > 0 and !wordChar(buf[i - 1])) i -= 1;
            while (i > 0 and wordChar(buf[i - 1])) i -= 1;
            return snapBoundary(rope, start + i);
        },
    }
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

test "editor motion primitives: word-end, %, and WORD vs word" {
    // Only the structural text-scan motions live in core; the vim policy
    // (^, f/t, J, the register, paste) is composed in config from the
    // cursor/jump/selection/slice/line ABI primitives.
    const gpa = std.testing.allocator;
    const pool = try task.Pool.init(gpa, .{ .threads = 1 });
    defer pool.deinit();
    var ed = try Editor.init(gpa, pool, "t");
    defer ed.deinit(gpa);
    try ed.insertText(gpa, "ab (c)"); // a b sp ( c )

    // e → end of "ab" (index 1, 'b').
    ed.placeCursor(0);
    try ed.moveWordEnd(gpa);
    try std.testing.expectEqual(@as(usize, 1), ed.cursorOffset());
    // % → the matching ')' at index 5 from the '(' at 3.
    ed.placeCursor(3);
    try ed.matchBracket(gpa);
    try std.testing.expectEqual(@as(usize, 5), ed.cursorOffset());

    // WORD vs word: on "foo.bar baz", W skips the dot to the next WORD.
    var ed2 = try Editor.init(gpa, pool, "t");
    defer ed2.deinit(gpa);
    try ed2.insertText(gpa, "foo.bar baz");
    ed2.placeCursor(0);
    try ed2.moveWordForward(gpa); // w stops at 'bar' (past the dot)
    try std.testing.expectEqual(@as(usize, 4), ed2.cursorOffset());
    ed2.placeCursor(0);
    try ed2.moveWORDForward(gpa); // W skips "foo.bar" entirely → 'baz'
    try std.testing.expectEqual(@as(usize, 8), ed2.cursorOffset());
    try ed2.moveWORDEnd(gpa); // E → last byte of "baz"
    try std.testing.expectEqual(@as(usize, 10), ed2.cursorOffset());
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
