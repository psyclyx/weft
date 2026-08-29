//! A wasm GUEST plugin (wasm32-freestanding), compiled by build.zig and run
//! under wasmtime by the host (see src/core/wasm_abi.zig). It is exactly what
//! a third-party plugin will be: it holds no host pointer and reaches the
//! editor ONLY through the `weft.*` host functions the host imports for it.
//! Edits it makes author as its own peer and pass the grade gate, on the same
//! authority path every other plugin's do.

/// Host imports — the grants. The host defines these (wasm_abi.zig); an
/// undefined one would make the module fail to instantiate.
extern "weft" fn cursor() u32;
extern "weft" fn edit(start: u32, end: u32, bytes_ptr: u32, bytes_len: u32) void;

var scratch: [64]u8 = undefined;

/// The plugin's command: insert "wasm!" at the cursor, through the host edit
/// gate (which authors it as this plugin's peer and checks its grade).
export fn run() void {
    const msg = "wasm!";
    for (msg, 0..) |ch, i| scratch[i] = ch;
    const off = cursor();
    edit(off, off, @intFromPtr(&scratch[0]), msg.len);
}
