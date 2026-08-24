//! Compile-only portability gate for the platform-free architecture.
//!
//! This is an object root rather than a test executable: the aarch64-macos
//! artifact is compiled but never run on the host. Named imports ensure a
//! hidden Linux-provider or relative reach-around cannot satisfy the gate.

const std = @import("std");

const wire = @import("weft_wire");
const schema = @import("weft_schema");
const semantic = @import("weft_semantic");
const scene_codec = @import("weft_scene_codec");
const fs = @import("weft_fs");
const fs_codec = @import("weft_fs_codec");
const fs_runtime = @import("weft_fs_runtime");
const view_runtime = @import("weft_view_runtime");
const target_runtime = @import("weft_target_runtime");
const plugin_semantic = @import("weft_plugin_semantic");

comptime {
    std.testing.refAllDecls(wire);
    std.testing.refAllDecls(schema);
    std.testing.refAllDecls(semantic);
    std.testing.refAllDecls(scene_codec);
    std.testing.refAllDecls(fs);
    std.testing.refAllDecls(fs_codec);
    std.testing.refAllDecls(fs_runtime);
    std.testing.refAllDecls(view_runtime);
    std.testing.refAllDecls(target_runtime);
    std.testing.refAllDecls(plugin_semantic);
}

pub fn darwinArchitectureGate() void {}
