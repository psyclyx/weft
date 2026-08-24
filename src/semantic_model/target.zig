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

/// A handler's data-dependent claim on one immutable target descriptor.
/// Equal strongest claims remain ambiguous; registration order is not policy.
pub const Match = enum(u8) {
    fallback,
    compatible,
    preferred,
    exact,
};

pub const Fact = struct {
    name: []const u8,
    value: []const u8,
};

pub const Definition = struct {
    kind: Kind,
    display_name: []const u8,
    facts: []const Fact = &.{},
};

pub const Descriptor = struct {
    ref: Ref,
    revision: u64 = 1,
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
    /// Descriptor revision selected during handler resolution. Opening after
    /// replacement is stale even though the target handle generation is live.
    revision: u64,
    location: Location = .whole,
};

/// A named edge from one target publisher's view of the world to another
/// revision-stamped target.  The source is carried by the query, while this
/// value deliberately contains only the edge name and destination.  Keeping
/// the destination as `Located` means relations cannot silently drop target
/// authority, descriptor revision, or a provider-specific location.
pub const Relation = struct {
    name: []const u8,
    target: Located,
};

test "target handles retain their typed wire identity" {
    const testing = @import("std").testing;
    const ref: Ref = .{ .authority = .here, .slot = 3, .generation = 8 };
    try testing.expectEqual(ref, Ref.fromWire(ref.toWire()));
}
