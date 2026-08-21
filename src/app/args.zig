//! Command-line parsing for the editor entrypoint.
//!
//!   weft [file] [--font path.ttf] [--em N] [--plugin p.wasm]... [--config config.js]
//!
//! POSIX argv is static, so the parsed slices stay valid for the run.

const std = @import("std");
const core = @import("../core/core.zig");

pub const Args = struct {
    file: ?[]const u8 = null,
    font: ?[]const u8 = null,
    config: ?[]const u8 = null,
    /// `.wasm` plugin paths to load at startup, in order (repeatable
    /// `--plugin`). weft ships modeless; a plugin is loaded only when named.
    /// argv is static, so these slices stay valid for the run.
    plugins: [32][]const u8 = undefined,
    plugin_count: usize = 0,
    em: f32 = 15,
    listen: ?u16 = null,
    /// Access granted to peers on --listen (safe default: view). Peers
    /// cannot write unless the host explicitly grants edit/own.
    access: core.session.Access = .view,
    connect: ?[]const u8 = null, // host:port
    token: []const u8 = "weft-dev",
    user: []const u8 = "user",
    headless: bool = false,
    /// With --connect: open the host's document as an editable partial
    /// checkout (content follows the cursor; huge files open instantly).
    partial: bool = false,
    /// --share-root <dir>: opt in to serving a filesystem root to peers over
    /// collab (dired-on-a-peer, remote fs). Null = don't serve any fs — the
    /// SAFE default (a peer gets nothing). fs access is separate from --access
    /// (that gates the document).
    share_root: ?[]const u8 = null,
    /// --share-fs <none|read|rw>: the access peers get to --share-root. Default
    /// none (deny) even when a root is set, so sharing is a deliberate choice.
    share_fs: core.peer_fs.Access = .none,
};

pub fn parseArgs(process_args: std.process.Args) Args {
    var out: Args = .{};
    var it = std.process.Args.Iterator.init(process_args);
    _ = it.skip(); // argv0
    while (it.next()) |a| {
        if (std.mem.eql(u8, a, "--font")) {
            out.font = it.next() orelse out.font;
        } else if (std.mem.eql(u8, a, "--config")) {
            out.config = it.next() orelse out.config;
        } else if (std.mem.eql(u8, a, "--plugin")) {
            if (it.next()) |v| if (out.plugin_count < out.plugins.len) {
                out.plugins[out.plugin_count] = v;
                out.plugin_count += 1;
            };
        } else if (std.mem.eql(u8, a, "--em")) {
            if (it.next()) |v| out.em = std.fmt.parseFloat(f32, v) catch out.em;
        } else if (std.mem.eql(u8, a, "--listen")) {
            if (it.next()) |v| out.listen = std.fmt.parseInt(u16, v, 10) catch null;
        } else if (std.mem.eql(u8, a, "--access")) {
            if (it.next()) |v| out.access = core.session.Access.parse(v) orelse out.access;
        } else if (std.mem.eql(u8, a, "--share-root")) {
            out.share_root = it.next() orelse out.share_root;
        } else if (std.mem.eql(u8, a, "--share-fs")) {
            if (it.next()) |v| out.share_fs = if (std.mem.eql(u8, v, "read"))
                .read
            else if (std.mem.eql(u8, v, "rw") or std.mem.eql(u8, v, "read_write"))
                .read_write
            else
                .none;
        } else if (std.mem.eql(u8, a, "--connect")) {
            out.connect = it.next() orelse out.connect;
        } else if (std.mem.eql(u8, a, "--token")) {
            out.token = it.next() orelse out.token;
        } else if (std.mem.eql(u8, a, "--user")) {
            out.user = it.next() orelse out.user;
        } else if (std.mem.eql(u8, a, "--headless")) {
            out.headless = true;
        } else if (std.mem.eql(u8, a, "--partial")) {
            out.partial = true;
        } else {
            out.file = a;
        }
    }
    return out;
}
