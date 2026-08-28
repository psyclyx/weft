//! weft-fs-codec: bounded, platform-free wire values for filesystem tools.
//!
//! The codec is deliberately separate from both providers and files.  It
//! carries observations and effect plans between plugin instances without
//! making an OS descriptor, a filename encoding, or a modal editor part of
//! the protocol.

pub const codec = @import("codec.zig");

pub const Limits = codec.Limits;
pub const Error = codec.Error;
pub const OwnedListing = codec.OwnedListing;
pub const OwnedObservation = codec.OwnedObservation;
pub const OwnedReadResult = codec.OwnedReadResult;
pub const OwnedPlan = codec.OwnedPlan;
pub const OwnedApplyReport = codec.OwnedApplyReport;
pub const ChildDirectory = codec.ChildDirectory;
pub const OwnedChildDirectory = codec.OwnedChildDirectory;
pub const Capabilities = codec.Capabilities;
pub const listing = struct {
    pub const encode = codec.encodeListing;
    pub const decode = codec.decodeListing;
    pub const Owned = codec.OwnedListing;
};
pub const observation = struct {
    pub const encode = codec.encodeObservation;
    pub const decode = codec.decodeObservation;
    pub const Owned = codec.OwnedObservation;
};
pub const read_result = struct {
    pub const encode = codec.encodeReadResult;
    pub const decode = codec.decodeReadResult;
    pub const Owned = codec.OwnedReadResult;
};
pub const plan = struct {
    pub const encode = codec.encodePlan;
    pub const decode = codec.decodePlan;
    pub const Owned = codec.OwnedPlan;
};
pub const apply_report = struct {
    pub const encode = codec.encodeApplyReport;
    pub const decode = codec.decodeApplyReport;
    pub const Owned = codec.OwnedApplyReport;
};
pub const child_directory = struct {
    pub const Request = codec.ChildDirectory;
    pub const encode = codec.encodeChildDirectory;
    pub const decode = codec.decodeChildDirectory;
    pub const Owned = codec.OwnedChildDirectory;
};
pub const capabilities = struct {
    pub const encode = codec.encodeCapabilities;
    pub const decode = codec.decodeCapabilities;
};

pub const encodeListing = codec.encodeListing;
pub const decodeListing = codec.decodeListing;
pub const encodeObservation = codec.encodeObservation;
pub const decodeObservation = codec.decodeObservation;
pub const encodeReadResult = codec.encodeReadResult;
pub const decodeReadResult = codec.decodeReadResult;
pub const encodePlan = codec.encodePlan;
pub const decodePlan = codec.decodePlan;
pub const encodeApplyReport = codec.encodeApplyReport;
pub const decodeApplyReport = codec.decodeApplyReport;
pub const encodeChildDirectory = codec.encodeChildDirectory;
pub const decodeChildDirectory = codec.decodeChildDirectory;
pub const encodeCapabilities = codec.encodeCapabilities;
pub const decodeCapabilities = codec.decodeCapabilities;

test {
    @import("std").testing.refAllDecls(@This());
}
