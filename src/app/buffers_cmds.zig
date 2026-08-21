//! Buffer open/close/browse commands — the graphical shell's versions that
//! know about providers and remote shells (they shadow the core versions;
//! registry last-wins). `open` dedupes by path and opens `host:path` over a
//! persistent ssh shell; `browse-remote` lists a remote directory over that
//! shell; `buffer-close` unbinds shares and detaches providers before the
//! document dies.

const std = @import("std");
const core = @import("../core/core.zig");
const providers = @import("providers.zig");
const AttachDeps = providers.AttachDeps;
const attachProviders = providers.attachProviders;
const detachProviders = providers.detachProviders;

/// `open <path>` — dedupe by path; `host:path` opens over a persistent
/// ssh shell (the coreutils tier); providers attach either way.
pub fn openBufferHandler(ctx: *core.command.Context, data: ?*anyopaque, args: []const core.command.Value) anyerror!core.command.Value {
    const deps: *AttachDeps = @ptrCast(@alignCast(data.?));
    if (args.len != 1 or args[0] != .string) return error.TypeMismatch;
    const spec = args[0].string;
    if (ctx.buffers.findByPath(spec)) |id| {
        try ctx.buffers.switchTo(ctx.gpa, id, ctx.head, ctx.keymap);
        return .{ .integer = @intCast(id) };
    }

    // scp-style remote: host:path (no '/' before the first ':').
    const remote: ?struct { host: []const u8, path: []const u8 } = blk: {
        const colon = std.mem.indexOfScalar(u8, spec, ':') orelse break :blk null;
        if (std.mem.indexOfScalar(u8, spec[0..colon], '/') != null) break :blk null;
        if (colon == 0 or colon + 1 >= spec.len) break :blk null;
        break :blk .{ .host = spec[0..colon], .path = spec[colon + 1 ..] };
    };

    if (remote) |r| {
        // Dedupe remote opens by (shell, remote path).
        const fs0 = deps.shells.get(r.host);
        var rit = ctx.buffers.iterator();
        while (rit.next()) |b| {
            switch (b.editor.backing) {
                .shell => |s| if (s.fs == fs0 and std.mem.eql(u8, s.path, r.path)) {
                    try ctx.buffers.switchTo(ctx.gpa, b.id, ctx.head, ctx.keymap);
                    return .{ .integer = @intCast(b.id) };
                },
                else => {},
            }
        }
    }

    const id = try ctx.buffers.create(ctx.gpa, std.fs.path.basename(spec));
    errdefer ctx.buffers.close(ctx.gpa, id, ctx.head, ctx.keymap) catch {};
    const buf = ctx.buffers.get(id).?;
    if (remote) |r| {
        const fs = try deps.shellFor(r.host);
        try buf.editor.openShell(ctx.gpa, fs, r.path);
    } else {
        buf.editor.openFile(ctx.gpa, spec) catch |err| switch (err) {
            error.FileNotFound => try buf.editor.adoptPath(ctx.gpa, spec),
            else => |e| return e,
        };
    }
    try attachProviders(deps, buf);
    try ctx.buffers.switchTo(ctx.gpa, id, ctx.head, ctx.keymap);
    return .{ .integer = @intCast(id) };
}

// ── Remote directory browsing (fs_source over the host's shell) ─────

/// One remote-browse pick's navigation state: the host and the current
/// directory. Accepting descends (dir), ascends (`../`), or opens a
/// file — each re-runs `browse-remote` or `open` by name.
const RemoteBrowse = struct {
    host: []u8,
    path: []u8,
};

/// `browse-remote <host> <path>` — list a remote directory over the
/// persistent ssh shell and pick over it (streamed by fs_source).
pub fn browseRemoteHandler(ctx: *core.command.Context, data: ?*anyopaque, args: []const core.command.Value) anyerror!core.command.Value {
    const deps: *AttachDeps = @ptrCast(@alignCast(data.?));
    if (args.len != 2 or args[0] != .string or args[1] != .string) return error.TypeMismatch;
    const host = args[0].string;
    const path = args[1].string;
    const gpa = ctx.gpa;
    const fs = try deps.shellFor(host);

    const rb = try gpa.create(RemoteBrowse);
    errdefer gpa.destroy(rb);
    rb.host = try gpa.dupe(u8, host);
    errdefer gpa.free(rb.host);
    rb.path = try gpa.dupe(u8, path);
    errdefer gpa.free(rb.path);
    const prompt = try std.fmt.allocPrint(gpa, "dir {s}:{s}", .{ host, path });
    defer gpa.free(prompt);
    // Source built last: openWith closes it on failure, so the only
    // unwinding left is rb (its errdefers above).
    const rd = try core.fs_source.RemoteDir.create(gpa, ctx.buffers.pool, fs, path);
    try ctx.head.pick.openWith(ctx, prompt, &.{}, .{
        .handler = browseRemoteAccept,
        .cleanup = browseRemoteCleanup,
        .data = rb,
    }, .{ .allow_free_text = true, .source = rd.source() });
    return .nil;
}

fn browseRemoteAccept(ctx: *core.command.Context, data: ?*anyopaque, choice: []const u8) anyerror!void {
    const rb: *RemoteBrowse = @ptrCast(@alignCast(data.?));
    const gpa = ctx.gpa;
    if (std.mem.eql(u8, choice, "../")) {
        const up = parentPath(rb.path);
        _ = try core.command.run(ctx.commands, ctx, "browse-remote", &.{
            .{ .string = rb.host }, .{ .string = up },
        });
        return;
    }
    if (std.mem.endsWith(u8, choice, "/")) {
        const child = try joinPath(gpa, rb.path, choice[0 .. choice.len - 1]);
        defer gpa.free(child);
        _ = try core.command.run(ctx.commands, ctx, "browse-remote", &.{
            .{ .string = rb.host }, .{ .string = child },
        });
        return;
    }
    const child = try joinPath(gpa, rb.path, choice);
    defer gpa.free(child);
    const spec = try std.fmt.allocPrint(gpa, "{s}:{s}", .{ rb.host, child });
    defer gpa.free(spec);
    _ = try core.command.run(ctx.commands, ctx, "open", &.{.{ .string = spec }});
}

fn browseRemoteCleanup(data: ?*anyopaque, gpa: std.mem.Allocator) void {
    const rb: *RemoteBrowse = @ptrCast(@alignCast(data.?));
    gpa.free(rb.host);
    gpa.free(rb.path);
    gpa.destroy(rb);
}

/// Directory portion of `p` (trailing slashes stripped), or "." at the
/// root — a borrowed subslice, valid for `p`'s lifetime.
fn parentPath(p: []const u8) []const u8 {
    var end = p.len;
    while (end > 0 and p[end - 1] == '/') end -= 1;
    if (std.mem.lastIndexOfScalar(u8, p[0..end], '/')) |i| {
        return if (i == 0) "/" else p[0..i];
    }
    return ".";
}

fn joinPath(gpa: std.mem.Allocator, base: []const u8, name: []const u8) ![]u8 {
    if (std.mem.eql(u8, base, ".")) return gpa.dupe(u8, name);
    var b = base;
    while (b.len > 0 and b[b.len - 1] == '/') b = b[0 .. b.len - 1];
    return std.fmt.allocPrint(gpa, "{s}/{s}", .{ b, name });
}

pub fn closeBufferHandler(ctx: *core.command.Context, data: ?*anyopaque, args: []const core.command.Value) anyerror!core.command.Value {
    const deps: *AttachDeps = @ptrCast(@alignCast(data.?));
    if (args.len != 0) return error.ArityMismatch;
    const b = ctx.buffer();
    if (b.editor.isDirty(ctx.gpa) catch true) return .{ .string = "dirty" };
    // Order matters: shares reference the doc and its layers.
    if (deps.share) |sc| {
        if (sc.conn.*) |*c| c.unbindTag(b.id);
        if (sc.hub.*) |*h| for (h.clients.items) |peer| peer.conn.unbindTag(b.id);
        var i: usize = 0;
        while (i < sc.shared.items.len) {
            if (sc.shared.items[i].tag == b.id) {
                sc.gpa.free(sc.shared.items[i].name);
                _ = sc.shared.swapRemove(i);
            } else i += 1;
        }
    }
    detachProviders(deps, b);
    try ctx.buffers.close(ctx.gpa, b.id, ctx.head, ctx.keymap);
    return .nil;
}

/// Bind the graphical shell's open/close/browse commands onto `commands`,
/// all pointing at the caller-owned `attach_deps`. These shadow the core
/// versions (registry last-wins): they know about providers and remote
/// shells, so they must register AFTER `core.builtins.install`.
pub fn registerCommands(gpa: std.mem.Allocator, commands: *core.command.Commands, attach_deps: *AttachDeps) !void {
    _ = try commands.bind(gpa, "open", .{
        .name = "open",
        .summary = "Open a local file or host:path over a shell, with providers.",
        .args = &.{.{ .name = "path", .type = .string }},
        .handler = openBufferHandler,
        .data = attach_deps,
    });
    _ = try commands.bind(gpa, "buffer-close", .{
        .name = "buffer-close",
        .summary = "Close the active buffer (refuses when dirty), detaching providers.",
        .args = &.{},
        .handler = closeBufferHandler,
        .data = attach_deps,
    });
    _ = try commands.bind(gpa, "browse-remote", .{
        .name = "browse-remote",
        .summary = "Browse a remote directory (host, path) over the host's shell.",
        .args = &.{
            .{ .name = "host", .type = .string },
            .{ .name = "path", .type = .string },
        },
        .handler = browseRemoteHandler,
        .data = attach_deps,
    });
}
