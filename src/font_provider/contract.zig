//! Platform-neutral font-provider request vocabulary.

pub const Request = struct {
    family: [:0]const u8,
    bold: bool = false,
    italic: bool = false,
};

/// One resolved face in a font file. Collection files (TTC/OTC) can contain
/// several faces, so the provider carries the platform-selected index rather
/// than making the text layer guess face zero.
pub const LoadedFace = struct {
    bytes: []u8,
    face_index: u32 = 0,
};
