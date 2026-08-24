//! Directory-tool launcher.
//!
//! The directory editor itself is a semantic target handler composed over
//! the public view, action, field, and filesystem contracts. This sandboxed
//! catalog plugin contributes only the user-facing command that publishes an
//! ordinary local target through the app's generic `open` seam. It owns no
//! text projection, editor mode, keymap, shell command, or filesystem policy.

const weft = @import("weft");

const command_name = "dired";

export fn describe() void {
    weft.declareCommand(command_name);
}

export fn init() void {
    _ = weft.register(command_name);
}

export fn on_command(id: u32) void {
    if (id != 0) return;
    const directory = weft.cwd();
    if (directory.len == 0) {
        weft.echo("dired: current directory unavailable");
        return;
    }
    weft.runStr("open", directory);
}
