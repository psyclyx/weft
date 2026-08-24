//! Locus-aware targets. Visible names and paths are descriptive; `Ref` is the
//! canonical identity used for dispatch and buffer deduplication.

const handle = @import("handle.zig");

pub const Tag = struct {};
pub const Ref = handle.Handle(Tag);

pub const Kind = union(enum) {
    unknown,
    file,
    directory,
    synthetic: []const u8,
};

pub const Fact = struct {
    name: []const u8,
    value: []const u8,
};

pub const Descriptor = struct {
    ref: Ref,
    kind: Kind,
    display_name: []const u8,
    facts: []const Fact = &.{},
};

pub const Location = union(enum) {
    whole,
    text: struct { start: u64, end: u64 },
    node: []const u8,
    provider: struct { schema: []const u8, payload: []const u8 },
};

pub const Located = struct {
    target: Ref,
    location: Location = .whole,
};

test "target handles retain their typed wire identity" {
    const testing = @import("std").testing;
    const ref: Ref = .{ .authority = .here, .slot = 3, .generation = 8 };
    try testing.expectEqual(ref, Ref.fromWire(ref.toWire()));
}
