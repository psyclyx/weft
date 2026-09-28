//! libghostty-vt's C API — the one import of it, so the terminal's files
//! share its types. The archive is linked into this plugin's own module
//! (build.zig `ghostty_vt`), so every call here stays inside the sandbox.

pub const c = @cImport(@cInclude("ghostty/vt.h"));

/// The archive's freestanding logger calls this (nix/libghostty-vt-wasm.nix
/// renames upstream's `env.log` import to it): a guest may import nothing
/// outside `weft:abi`. The emulator's log lines are dropped — what goes wrong
/// in a terminal shows on its screen.
fn log(ptr: [*]const u8, len: usize) callconv(.c) void {
    _ = ptr;
    _ = len;
}

comptime {
    @export(&log, .{ .name = "ghostty_wasm_log", .visibility = .hidden });
}
