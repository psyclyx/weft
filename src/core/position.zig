//! Stamped positions — the only way an offset crosses a public
//! boundary. A `StampedOffset`/`StampedRange` pairs byte positions with
//! the version token they were computed against; the sole way back to a
//! usable offset is `rebase` (maps through the commit log's composed
//! patches) or null — rebase or discard, decided here, not in
//! consumers. The mapping kernel (`mapOffset`) moved out of undo.zig,
//! which now shares it.

const std = @import("std");
const Allocator = std.mem.Allocator;

const stemma = @import("stemma");
const Document = @import("Document.zig");
const patch = @import("patch.zig");
const Patch = patch.Patch;
pub const Bias = stemma.Bias;

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
    const idx = indexOfVersion(doc, version_token) orelse return null;
    return rebaseFrom(doc, idx + 1, offset, bias);
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
