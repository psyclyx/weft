//! weft-scene-codec: portable scene, interaction, and target values.
//!
//! This is a real module root. Consumers import it as `weft_scene_codec` and
//! cannot reach the implementation through a relative path. The codec itself
//! only depends on the named `weft_semantic` and `weft_schema` modules (plus Zig
//! std), so it is suitable for the platform-free contract gate and wasm guests.

pub const codec = @import("codec.zig");

/// Small facades keep the wire families discoverable without creating
/// parallel implementations (and preserve one shared limit/error vocabulary).
pub const scene = struct {
    pub const encode = codec.encodeScene;
    pub const decode = codec.decodeScene;
    pub const Owned = codec.OwnedScene;
};
pub const interaction = struct {
    pub const encode = codec.encodeInteraction;
    pub const decode = codec.decodeInteraction;
    pub const Owned = codec.OwnedInteraction;
};
pub const target = struct {
    pub const encode = codec.encodeTarget;
    pub const decode = codec.decodeTarget;
    pub const Owned = codec.OwnedTarget;
    pub const encodeDescriptor = codec.encodeTargetDescriptor;
    pub const decodeDescriptor = codec.decodeTargetDescriptor;
    pub const OwnedDescriptor = codec.OwnedTargetDescriptor;
    pub const encodeLocated = codec.encodeLocatedTarget;
    pub const decodeLocated = codec.decodeLocatedTarget;
    pub const OwnedLocated = codec.OwnedLocatedTarget;
};
pub const transfer = struct {
    pub const encode = codec.encodeTransfer;
    pub const decode = codec.decodeTransfer;
    pub const Owned = codec.OwnedTransfer;
};
pub const action = struct {
    pub const encodeRequest = codec.encodeActionRequest;
    pub const decodeRequest = codec.decodeActionRequest;
    pub const OwnedRequest = codec.OwnedActionRequest;
};

pub const Limits = codec.Limits;
pub const Error = codec.Error;
pub const encodeScene = codec.encodeScene;
pub const decodeScene = codec.decodeScene;
pub const encodeInteraction = codec.encodeInteraction;
pub const decodeInteraction = codec.decodeInteraction;
pub const encodeTarget = codec.encodeTarget;
pub const decodeTarget = codec.decodeTarget;
pub const encodeTargetDescriptor = codec.encodeTargetDescriptor;
pub const decodeTargetDescriptor = codec.decodeTargetDescriptor;
pub const encodeLocatedTarget = codec.encodeLocatedTarget;
pub const decodeLocatedTarget = codec.decodeLocatedTarget;
pub const encodeTransfer = codec.encodeTransfer;
pub const decodeTransfer = codec.decodeTransfer;
pub const encodeActionRequest = codec.encodeActionRequest;
pub const decodeActionRequest = codec.decodeActionRequest;

test {
    @import("std").testing.refAllDecls(@This());
}
