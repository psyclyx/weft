//! System-local identity for one provider instance.
//!
//! Names describe plugins to people; they are not authority and are not
//! unique across reloads. Runtime registries use this opaque value instead.

pub const Id = enum(u64) {
    invalid = 0,
    _,

    pub fn isValid(self: Id) bool {
        return self != .invalid;
    }
};
