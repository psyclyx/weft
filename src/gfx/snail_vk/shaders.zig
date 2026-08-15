//! SPIR-V for the snail render path, sourced from the public
//! `snail-shaders-vk` module (compiled by snail's build via slangc)
//! instead of the demo's anonymous build imports. Fragment families are
//! the flat typed-buffer variants (the descriptor layout binds curve and
//! band data as uniform texel buffers); vertex stages don't touch
//! curve/band storage, so the ordinary stage modules pair with them.
//! Flat blobs are comptime-copied to the 4-byte alignment
//! VkShaderModuleCreateInfo.pCode requires.

const snail_shaders = @import("snail_shaders");

fn AlignedFlat(comptime family: snail_shaders.FlatFamily) type {
    return struct {
        const raw = snail_shaders.flatFragSpvRaw(family);
        const data: [raw.len]u8 align(4) = raw[0..raw.len].*;
    };
}

fn alignedFlat(comptime family: snail_shaders.FlatFamily) []align(4) const u8 {
    return &AlignedFlat(family).data;
}

pub const vert_text_native_spv: []align(4) const u8 = snail_shaders.textSpv(.vertex);
pub const vert_autohint_native_spv: []align(4) const u8 = snail_shaders.autohintSpv(.vertex);
pub const frag_text_native_spv = alignedFlat(.text);
pub const frag_colr_native_spv = alignedFlat(.colr);
pub const frag_path_quadratic_native_spv = alignedFlat(.path_quadratic);
pub const frag_path_conic_native_spv = alignedFlat(.path_conic);
pub const frag_path_native_spv = alignedFlat(.path);
pub const frag_tt_hinted_native_spv = alignedFlat(.tt_hinted_text);
pub const frag_autohint_native_spv = alignedFlat(.autohint);
pub const frag_subpixel_native_spv = alignedFlat(.text_subpixel);
pub const frag_tt_hinted_subpixel_native_spv = alignedFlat(.tt_hinted_text_subpixel);
pub const frag_autohint_subpixel_native_spv = alignedFlat(.autohint_subpixel);
