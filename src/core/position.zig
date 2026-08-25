//! Position boundary types. Synchronous command composition carries borrowed
//! document-owned `LiveOffset`/`LiveRange` anchors. The older
//! `StampedOffset`/`StampedRange` adapters remain only for asynchronous
//! snapshot consumers which receive arbitrary offsets computed against an
//! immutable capability request; those map through the commit log or fail
//! closed. New live interaction state must use anchors, never these adapters.
//! The mapping kernel (`mapOffset`) is also shared by undo.

const std = @import("std");
const Allocator = std.mem.Allocator;

const stemma = @import("stemma");
const Document = @import("Document.zig");
const patch = @import("patch.zig");
const Patch = patch.Patch;
pub const Bias = stemma.Bias;

/// A borrowed live position. The owner of `handle` keeps it registered in
/// `document` for this value's lifetime; crossing to another document fails
/// closed. This is the synchronous command ABI's position type—not a snapshot
/// coordinate and therefore not stamped with a causal frontier.
pub const LiveOffset = struct {
    document: *const Document,
    handle: Document.AnchorHandle,

    pub fn resolve(self: LiveOffset, document: *const Document) ?usize {
        if (self.document != document) return null;
        return document.anchorOffset(self.handle);
    }
};

/// A borrowed pair of document-owned live anchors. Anchor ownership remains
/// with the producer; command values are valid only for the synchronous call
/// chain, just like borrowed strings.
pub const LiveRange = struct {
    document: *const Document,
    start: Document.AnchorHandle,
    end: Document.AnchorHandle,

    pub fn resolve(self: LiveRange, document: *const Document) ?stemma.Range {
        if (self.document != document) return null;
        const start = document.anchorOffset(self.start);
        const end = document.anchorOffset(self.end);
        return .{ .start = @min(start, end), .end = @max(start, end) };
    }
};

/// Map an offset through one commit's composed patches (old-space →
/// new-space). `bias` resolves positions at insertion boundaries
/// (`.left` stays before text inserted at the position, `.right` goes
/// after); positions in a removed range collapse to its replacement
/// start.
pub fn mapOffset(patches: []const Patch, x: usize, bias: Bias) usize {
    var delta: isize = 0;
    for (patches) |p| {
        if (x < p.offset) break;
        if (x == p.offset) {
            if (p.removed > 0) return @intCast(@as(isize, @intCast(p.offset)) + delta);
            if (bias == .left) break;
            delta += @as(isize, @intCast(p.inserted));
            continue;
        }
        if (x < p.offset + p.removed) {
            return @intCast(@as(isize, @intCast(p.offset)) + delta);
        }
        delta += @as(isize, @intCast(p.inserted)) - @as(isize, @intCast(p.removed));
    }
    return @intCast(@as(isize, @intCast(x)) + delta);
}

/// The log index of the commit whose post-state is `version_token`, or
/// null when unknown (foreign token, trimmed history).
fn indexOfVersion(doc: *const Document, version_token: []const u8) ?usize {
    // Newest first: stamps are usually near the head.
    var i = doc.commitCount();
    while (i > 0) {
        i -= 1;
        if (std.mem.eql(u8, doc.commitAt(i).version, version_token)) return i;
    }
    return null;
}

/// Map `offset` (valid at `version_token`) to the current head, or
/// null when the version is unknown — the discard arm.
pub fn rebaseOffset(doc: *const Document, version_token: []const u8, offset: usize, bias: Bias) ?usize {
    if (indexOfVersion(doc, version_token)) |idx| return rebaseFrom(doc, idx + 1, offset, bias);
    // The version is in no commit. When the log is EMPTY (a stamp taken on a
    // document with no history — an empty buffer), nothing has moved, so the
    // offset is still valid. Otherwise it is a foreign/trimmed token → discard.
    if (doc.commitCount() == 0) return offset;
    return null;
}

/// Map through commits `[first_index..head]`.
pub fn rebaseFrom(doc: *const Document, first_index: usize, offset: usize, bias: Bias) usize {
    var x = offset;
    for (first_index..doc.commitCount()) |j| {
        x = mapOffset(doc.commitAt(j).patches, x, bias);
    }
    return x;
}

/// A version-stamped offset. The fields are underscore-prefixed on
/// purpose: touch them outside adapters and the module-boundary check
/// flags you — `rebase`/`ifCurrent` are the API.
pub const StampedOffset = struct {
    _version: []const u8,
    _offset: usize,

    pub fn at(version_token: []const u8, offset: usize) StampedOffset {
        return .{ ._version = version_token, ._offset = offset };
    }

    pub fn rebase(self: StampedOffset, doc: *const Document, bias: Bias) ?usize {
        return rebaseOffset(doc, self._version, self._offset, bias);
    }

    /// The offset only if the document has not moved past the stamp.
    pub fn ifCurrent(self: StampedOffset, doc: *const Document) ?usize {
        if (doc.commitCount() == 0) return self._offset;
        const head = doc.commitAt(doc.commitCount() - 1).version;
        return if (std.mem.eql(u8, head, self._version)) self._offset else null;
    }
};

pub const StampedRange = struct {
    _version: []const u8,
    _start: usize,
    _end: usize,

    pub fn at(version_token: []const u8, start: usize, end: usize) StampedRange {
        return .{ ._version = version_token, ._start = start, ._end = end };
    }

    /// Rebase both ends (start rides right, end rides left — foreign
    /// insertions at the boundary stay outside); null when unknown or
    /// fully collapsed away is NOT null — a collapsed range comes back
    /// empty, which is the honest answer.
    pub fn rebase(self: StampedRange, doc: *const Document) ?stemma.Range {
        const idx = indexOfVersion(doc, self._version) orelse return null;
        const s = rebaseFrom(doc, idx + 1, self._start, .right);
        const e = rebaseFrom(doc, idx + 1, self._end, .left);
        return .{ .start = @min(s, e), .end = @max(s, e) };
    }
};

test {
    std.testing.refAllDecls(@This());
}
