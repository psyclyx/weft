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
const Range = stemma.Range;

const Editor = @This();

doc: Document,
history: undo_mod.UndoLog = .empty,
/// Insertion point; bias .right so text typed at the cursor pushes it
/// forward, and other peers' inserts at the cursor do the same.
cursor: stemma.AnchorSet.Handle,
/// Selection = mark..cursor (either order), when a mark is set.
mark: ?stemma.AnchorSet.Handle = null,
/// Byte column vertical movement aims for (sticky across short lines).
goal_col: ?usize = null,
path: ?[]u8 = null,
/// Version token of the last content known to be on disk.
saved_version: ?[]u8 = null,
pool: *task.Pool,
save_state: SaveState = .idle,

pub const SaveState = union(enum) {
    idle,
    /// A save is in flight; the version it snapshots.
    saving: struct { handle: task.Handle(file.WriteError!void), version: []u8 },
    /// Terminal state of the last save attempt, until the next request.
    failed: file.WriteError,
};

pub fn init(gpa: Allocator, pool: *task.Pool, user_agent: []const u8) Allocator.Error!Editor {
    var doc = try Document.init(gpa, user_agent);
    errdefer doc.deinit(gpa);
    const cursor = try doc.addAnchor(gpa, 0, .right);
    return .{ .doc = doc, .cursor = cursor, .pool = pool };
}

pub fn deinit(self: *Editor, gpa: Allocator) void {
    // A save in flight owns its snapshot; let it finish (pool deinit
    // completes queued work) — here we only detach bookkeeping.
    switch (self.save_state) {
        .saving => |*s| {
            var h = s.handle;
            h.detach();
            gpa.free(s.version);
        },
        else => {},
    }
    self.history.deinit(gpa);
    self.doc.deinit(gpa);
    if (self.path) |p| gpa.free(p);
    if (self.saved_version) |v| gpa.free(v);
    self.* = undefined;
}

pub fn text(self: *const Editor) *const stemma.Rope {
    return self.doc.text();
}

pub fn cursorOffset(self: *const Editor) usize {
    return self.doc.anchorOffset(self.cursor);
}

// ── Files ───────────────────────────────────────────────────────────

/// Load a file's content into the document, delivered by the `host.fs`
/// peer (loading is a mutation by the filesystem host, not by the
/// user — it is not undoable). Startup path, allowed to block.
pub fn openFile(self: *Editor, gpa: Allocator, path: []const u8) (Allocator.Error || file.ReadError || Document.AddPeerError)!void {
    task.assertMayBlock();
    const bytes = try file.readAlloc(gpa, path);
    defer gpa.free(bytes);
    const host = try self.doc.addPeer(gpa, "host.fs");
    defer self.doc.removePeer(gpa, host);
    try self.doc.peerInsert(gpa, host, 0, bytes);
    _ = try self.doc.peerCommit(gpa, host);
    // Freshly loaded == on disk.
    if (self.path) |p| gpa.free(p);
    self.path = try gpa.dupe(u8, path);
    if (self.saved_version) |v| gpa.free(v);
    self.saved_version = try self.doc.version(gpa);
    // The load is not part of undo history, and the cursor starts at
    // the top (the host's insert at 0 pushed the bias-right anchor to
    // the end).
    try self.history.ingest(gpa, &self.doc);
    self.history.barrier();
    self.doc.anchors.set(self.cursor, .{ .offset = 0, .bias = .right });
}

/// Request a save: O(1) rope snapshot + version token, written by a
/// pool worker (temp file + rename). Never blocks; poll `saveState`
/// via `pollSave`. A request while one is in flight is dropped (poll
/// first; the editor loop does).
pub fn requestSave(self: *Editor, gpa: Allocator) Allocator.Error!void {
    if (self.save_state == .saving) return;
    const path = self.path orelse return; // nothing to save to
    const version = try self.doc.version(gpa);
    errdefer gpa.free(version);
    const handle = try self.pool.spawn(file.writeRopeAtomic, .{
        gpa, try gpa.dupe(u8, path), self.doc.text().snapshot(),
    });
    self.save_state = .{ .saving = .{ .handle = handle, .version = version } };
}

/// Non-blocking: fold a finished save into state. Returns true when a
/// save completed successfully since the last poll.
pub fn pollSave(self: *Editor, gpa: Allocator) bool {
    switch (self.save_state) {
        .saving => |*s| {
            var h = s.handle;
            const result = h.poll() orelse return false;
            const version = s.version;
            if (result) |_| {
                if (self.saved_version) |v| gpa.free(v);
                self.saved_version = version;
                self.save_state = .idle;
                return true;
            } else |err| {
                gpa.free(version);
                self.save_state = .{ .failed = err };
                return false;
            }
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
    self.goal_col = null;
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
    self.goal_col = null;
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
    self.goal_col = null;
    try self.history.ingest(gpa, &self.doc);
}

/// Delete an arbitrary range as one undoable unit (motions, operators).
pub fn deleteRange(self: *Editor, gpa: Allocator, r: Range) Allocator.Error!void {
    if (r.isEmpty()) return;
    try self.doc.delete(gpa, r);
    self.clearSelection();
    self.goal_col = null;
    try self.history.ingest(gpa, &self.doc);
}

pub fn undo(self: *Editor, gpa: Allocator) Allocator.Error!bool {
    const did = try self.history.undo(gpa, &self.doc);
    self.goal_col = null;
    return did;
}

pub fn redo(self: *Editor, gpa: Allocator) Allocator.Error!bool {
    const did = try self.history.redo(gpa, &self.doc);
    self.goal_col = null;
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
    self.goal_col = null;
}

pub fn moveRight(self: *Editor) void {
    const off = self.cursorOffset();
    if (off < self.text().byteLen()) self.moveTo(self.nextBoundary(off));
    self.goal_col = null;
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
    self.goal_col = null;
}

pub fn moveLineEnd(self: *Editor) void {
    const rope = self.text();
    const p = rope.offsetToPoint(self.cursorOffset());
    self.moveTo(rope.lineRange(p.row).end);
    self.goal_col = null;
}

pub fn moveDocStart(self: *Editor) void {
    self.moveTo(0);
    self.goal_col = null;
}

pub fn moveDocEnd(self: *Editor) void {
    self.moveTo(self.text().byteLen());
    self.goal_col = null;
}

fn wordChar(b: u8) bool {
    return std.ascii.isAlphanumeric(b) or b == '_' or b >= 0x80;
}

/// Forward to the start of the next word (ASCII-classed; non-ASCII
/// counts as word bytes).
pub fn moveWordForward(self: *Editor, gpa: Allocator) Allocator.Error!void {
    const off = try self.scanWord(gpa, self.cursorOffset(), .forward);
    self.moveTo(off);
    self.goal_col = null;
}

/// Backward to the start of the previous word.
pub fn moveWordBackward(self: *Editor, gpa: Allocator) Allocator.Error!void {
    const off = try self.scanWord(gpa, self.cursorOffset(), .backward);
    self.moveTo(off);
    self.goal_col = null;
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
