//! Typed attachment of semantic filesystem targets to provider nodes.
//!
//! Core target dispatch remains unaware of filesystems. A filesystem target
//! publisher places this canonical value in an ordinary target fact; a tool
//! such as files opts into the `weft_fs` vocabulary and decodes it. Local,
//! remote, and synthetic providers all use the same opaque authority/handles.

const std = @import("std");
const contract = @import("contract.zig");

pub const fact_name = "weft.fs.directory.v1";
pub const entry_fact_name = "weft.fs.entry.v1";

pub const Directory = struct {
    root: contract.Root,
    node: contract.NodeRef = .root,
};

/// An ordinary-file target is an observed entry in a provider-owned root.
/// The revision is part of the attachment rather than descriptive metadata:
/// a handler must prove it is opening the exact observation that was
/// published.  The entry handle remains opaque to this module and to core.
pub const Entry = struct {
    root: contract.Root,
    ref: contract.EntryRef,
    revision: contract.Revision,
};

pub const Error = std.mem.Allocator.Error || error{ InvalidDirectoryTarget, InvalidEntryTarget };

const version: u8 = 1;
const root_tag: u8 = 0;
const entry_tag: u8 = 1;
const root_bytes = 1 + 3 * @sizeOf(u32) + 1;
const entry_bytes = root_bytes + 3 * @sizeOf(u32);

const entry_version: u8 = 1;
const entry_fixed_bytes = 1 + 3 * @sizeOf(u32) + 3 * @sizeOf(u32) + @sizeOf(u32);

pub fn encode(gpa: std.mem.Allocator, directory: Directory) Error![]u8 {
    try validate(directory);
    const len: usize = switch (directory.node) {
        .root => root_bytes,
        .entry => entry_bytes,
    };
    const bytes = try gpa.alloc(u8, len);
    bytes[0] = version;
    writeHandle(bytes[1..13], directory.root.toWire());
    switch (directory.node) {
        .root => bytes[13] = root_tag,
        .entry => |entry| {
            bytes[13] = entry_tag;
            writeHandle(bytes[14..26], entry.toWire());
        },
    }
    return bytes;
}

pub fn decode(bytes: []const u8) Error!Directory {
    if (bytes.len != root_bytes and bytes.len != entry_bytes) return error.InvalidDirectoryTarget;
    if (bytes[0] != version) return error.InvalidDirectoryTarget;
    const root = contract.Root.fromWire(readHandle(bytes[1..13]));
    const node: contract.NodeRef = switch (bytes[13]) {
        root_tag => if (bytes.len == root_bytes) .root else return error.InvalidDirectoryTarget,
        entry_tag => if (bytes.len == entry_bytes)
            .{ .entry = contract.EntryRef.fromWire(readHandle(bytes[14..26])) }
        else
            return error.InvalidDirectoryTarget,
        else => return error.InvalidDirectoryTarget,
    };
    const directory: Directory = .{ .root = root, .node = node };
    try validate(directory);
    return directory;
}

pub fn find(facts: []const @import("weft_semantic").target.Fact) Error!?Directory {
    for (facts) |fact| {
        if (std.mem.eql(u8, fact.name, fact_name)) return try decode(fact.value);
    }
    return null;
}

/// Encode the provider-owned address and observed revision of one ordinary
/// entry.  Revision bytes are length-prefixed and may contain arbitrary
/// provider data; no path or URI vocabulary is introduced here.
pub fn encodeEntry(gpa: std.mem.Allocator, entry: Entry) Error![]u8 {
    try validateEntry(entry);
    if (entry.revision.token.len > std.math.maxInt(u32)) return error.InvalidEntryTarget;
    const bytes = try gpa.alloc(u8, entry_fixed_bytes + entry.revision.token.len);
    bytes[0] = entry_version;
    writeHandle(bytes[1..13], entry.root.toWire());
    writeHandle(bytes[13..25], entry.ref.toWire());
    std.mem.writeInt(u32, bytes[25..29], @intCast(entry.revision.token.len), .little);
    @memcpy(bytes[29..], entry.revision.token);
    return bytes;
}

pub fn decodeEntry(bytes: []const u8) Error!Entry {
    if (bytes.len < entry_fixed_bytes or bytes[0] != entry_version) return error.InvalidEntryTarget;
    const token_len = std.mem.readInt(u32, bytes[25..29], .little);
    if (bytes.len != entry_fixed_bytes + @as(usize, token_len)) return error.InvalidEntryTarget;
    const value: Entry = .{
        .root = contract.Root.fromWire(readHandle(bytes[1..13])),
        .ref = contract.EntryRef.fromWire(readHandle(bytes[13..25])),
        .revision = .{ .token = bytes[29..] },
    };
    try validateEntry(value);
    return value;
}

pub fn findEntry(facts: []const @import("weft_semantic").target.Fact) Error!?Entry {
    for (facts) |fact| {
        if (std.mem.eql(u8, fact.name, entry_fact_name)) return try decodeEntry(fact.value);
    }
    return null;
}

pub fn validate(directory: Directory) error{InvalidDirectoryTarget}!void {
    if (directory.root.generation == 0) return error.InvalidDirectoryTarget;
    switch (directory.node) {
        .root => {},
        .entry => |entry| if (entry.generation == 0 or entry.authority != directory.root.authority)
            return error.InvalidDirectoryTarget,
    }
}

pub fn validateEntry(entry: Entry) error{InvalidEntryTarget}!void {
    if (entry.root.generation == 0 or entry.ref.generation == 0 or
        entry.ref.authority != entry.root.authority)
        return error.InvalidEntryTarget;
}

fn writeHandle(destination: []u8, wire: @import("weft_semantic").handle.Wire) void {
    std.mem.writeInt(u32, destination[0..4], wire.authority, .little);
    std.mem.writeInt(u32, destination[4..8], wire.slot, .little);
    std.mem.writeInt(u32, destination[8..12], wire.generation, .little);
}

fn readHandle(source: []const u8) @import("weft_semantic").handle.Wire {
    return .{
        .authority = std.mem.readInt(u32, source[0..4], .little),
        .slot = std.mem.readInt(u32, source[4..8], .little),
        .generation = std.mem.readInt(u32, source[8..12], .little),
    };
}

test "directory target attachment is canonical across authorities and nodes" {
    const cases = [_]Directory{
        .{ .root = .{ .authority = .here, .slot = 3, .generation = 4 } },
        .{
            .root = .{ .authority = @enumFromInt(91), .slot = 7, .generation = 8 },
            .node = .{ .entry = .{ .authority = @enumFromInt(91), .slot = 11, .generation = 12 } },
        },
    };
    for (cases) |expected| {
        const encoded = try encode(std.testing.allocator, expected);
        defer std.testing.allocator.free(encoded);
        const actual = try decode(encoded);
        try std.testing.expectEqual(expected.root, actual.root);
        try std.testing.expectEqualDeep(expected.node, actual.node);
    }
}

test "directory target attachment rejects mixed authorities and trailing data" {
    try std.testing.expectError(error.InvalidDirectoryTarget, encode(std.testing.allocator, .{
        .root = .{ .authority = .here, .slot = 1, .generation = 1 },
        .node = .{ .entry = .{ .authority = @enumFromInt(2), .slot = 1, .generation = 1 } },
    }));
    var encoded = try encode(std.testing.allocator, .{ .root = .{ .authority = .here, .slot = 1, .generation = 1 } });
    defer std.testing.allocator.free(encoded);
    encoded[0] = 2;
    try std.testing.expectError(error.InvalidDirectoryTarget, decode(encoded));
}

test "ordinary entry target attachment preserves opaque revision bytes" {
    const expected: Entry = .{
        .root = .{ .authority = @enumFromInt(9), .slot = 3, .generation = 4 },
        .ref = .{ .authority = @enumFromInt(9), .slot = 8, .generation = 2 },
        .revision = .{ .token = "inode\x00revision" },
    };
    const encoded = try encodeEntry(std.testing.allocator, expected);
    defer std.testing.allocator.free(encoded);
    const actual = try decodeEntry(encoded);
    try std.testing.expectEqual(expected.root, actual.root);
    try std.testing.expectEqual(expected.ref, actual.ref);
    try std.testing.expectEqualSlices(u8, expected.revision.token, actual.revision.token);
    var facts = [_]@import("weft_semantic").target.Fact{.{ .name = entry_fact_name, .value = encoded }};
    try std.testing.expectEqualDeep(expected, (try findEntry(&facts)).?);
}

test "ordinary entry target attachment rejects invalid authority and truncated bytes" {
    try std.testing.expectError(error.InvalidEntryTarget, encodeEntry(std.testing.allocator, .{
        .root = .{ .authority = .here, .slot = 1, .generation = 1 },
        .ref = .{ .authority = @enumFromInt(2), .slot = 1, .generation = 1 },
        .revision = .{ .token = "r" },
    }));
    try std.testing.expectError(error.InvalidEntryTarget, decodeEntry(&[_]u8{1}));
}
