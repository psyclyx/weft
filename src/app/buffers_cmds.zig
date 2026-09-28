//! The graphical shell's half of opening and closing entries — what knows
//! about providers, remote shells and peers — as core's `EntryShell` door
//! (`entryShell`), so `file.open` and `buffer.close-*` stay core's one
//! registration each. An open takes a designation (doc/model.md §2.1) — or an
//! absolute path standing in for one, or `host:path` over a persistent ssh
//! shell — and routes it by kind and authority; a close unbinds shares and
//! detaches providers before the document dies. `file.browse-remote`, which
//! lists a remote directory over that shell, is the shell's own command.

const std = @import("std");
const core = @import("weft_core");
const providers = @import("providers.zig");
const AttachDeps = providers.AttachDeps;
const durable = core.designation.durable;

/// Optional target-producing behavior supplied by the app shell. This is a
/// generic composition point: buffer commands do not know which tool, if any,
/// will claim the resulting target.
pub const DirectoryOpener = struct {
    context: *anyopaque,
    open: *const fn (*anyopaque, *core.command.Context, []const u8) anyerror!bool,
    /// WHERE a local file at this path belongs (`doc/place.md`) — its project
    /// root, published as a container. Null when the file has no project, and
    /// the entry keeps the degenerate place.
    ///
    /// On this seam rather than in core because only the session that opened a
    /// root may say what it is: core inventing the walk would put it back in
    /// the business of joining paths.
    place_for: *const fn (*anyopaque, *core.command.Context, []const u8) ?core.Place,
};

/// Opens what a PEER authority designates — its shared tree (`dir`), a
/// document it shares (`doc`). Supplied by the collaboration shell, which
/// holds the connections; absent, a peer designation is refused by name.
/// Answers the command's result: an entry opened, or a refusal in words.
pub const PeerOpener = struct {
    context: *anyopaque,
    open: *const fn (*anyopaque, *core.command.Context, durable.Designation) anyerror!core.command.Value,
};

pub const Context = struct {
    attachments: *AttachDeps,
    directories: ?DirectoryOpener = null,
    peers: ?PeerOpener = null,

    /// This shell's way to open a file from bytes already read (`FileOpener`).
    pub fn fileOpener(self: *Context) FileOpener {
        return .{ .context = self };
    }

    /// Core's door for opening and retiring entries, answered here.
    pub fn entryShell(self: *Context) core.command.EntryShell {
        return .{ .context = self, .open = openThroughShell, .retire = retireThroughShell };
    }
};
const attachProviders = providers.attachProviders;
const detachProviders = providers.detachProviders;

/// `open <designation>` — the one door content is opened through, routed by
/// what the designation names:
///
/// - `weft://here/file|dir/<path>` (or the bare absolute path): the local
///   file, deduped by path, or the directory's listing;
/// - `weft://shell:<host>/file/<path>` (or `host:path`): over that shell;
/// - `weft://<peer>/…`: to the peer (its shared tree, a document it shares);
/// - a document, a process, a projection: as core answers them
///   (`designation.openHeld`) — a live entry, a kept document, a producer
///   re-run.
///
/// A relative path is resolved once, here, against the place the command runs
/// in (`designation.resolveRelative`) — never against the directory the
/// process was launched in — and refused where that place has no local
/// directory. A position locator (`?at=`) lands the caret.
pub fn openBufferHandler(ctx: *core.command.Context, data: ?*anyopaque, args: []const core.command.Value) anyerror!core.command.Value {
    const command_context: *Context = @ptrCast(@alignCast(data.?));
    if (args.len != 1 or args[0] != .string) return error.TypeMismatch;
    const spec = args[0].string;
    // AN OPEN FROM A TOOL ENTRY IS AN ACTIVATION (§9.4).
    //
    // A listing, a grep result, a build log: opening something FROM one means
    // "show me that", and where it goes is the placement policy.s answer — from
    // an ordinary pane "here", from a docked companion "the editing pane". That
    // is the whole of "Return in the sidebar opens in the editor", and it
    // belongs here rather than in every tool: each of them opening by hand and
    // guessing at placement is how a sidebar becomes special-cased.
    //
    // Only when nothing has already asked: a caller that stated its own
    // placement means it.
    if (ctx.head.placement == null and ctx.buffers.active().tool.len > 0)
        ctx.head.placement = .{ .hint = .primary, .kind = .unknown };

    return switch (durable.Spec.of(spec)) {
        .path => |path| openLocal(ctx, command_context, path),
        .designation => |d| openDesignation(ctx, command_context, d, spec),
        .malformed => .{ .string = "open: " ++ durable.Spec.malformed_refusal },
        // `host:path` names its locus, so it is not relative to anything
        // here. Any other bare name is relative to the place the command runs
        // in, and is made absolute once, here.
        .relative => if (scpSpec(spec)) |r|
            openShell(ctx, command_context, r.host, r.path)
        else if (try core.designation.resolveRelative(ctx, ctx.gpa, spec)) |abs| blk: {
            defer ctx.gpa.free(abs);
            break :blk openLocal(ctx, command_context, abs);
        } else .{ .string = "open: " ++ core.designation.refuse_relative_elsewhere },
    };
}

fn openDesignation(ctx: *core.command.Context, command_context: *Context, d: durable.Designation, text: []const u8) anyerror!core.command.Value {
    const opened: core.command.Value = if (try core.designation.openHeld(ctx, d, text)) |outcome| switch (outcome) {
        .opened => |id| blk: {
            // A kept document reopened (parked, or from the store) comes without
            // the providers its close detached.
            if (ctx.buffers.get(id)) |b| try attachProviders(command_context.attachments, b);
            break :blk .{ .integer = @intCast(id) };
        },
        .refused => |why| return .{ .string = why },
    } else switch (d.authority) {
        .here => switch (d.kind) {
            .file => try openLocal(ctx, command_context, d.ref),
            .directory => blk: {
                const directories = command_context.directories orelse
                    return .{ .string = "open: this shell lists no directories" };
                if (!try directories.open(directories.context, ctx, d.ref))
                    return .{ .string = "open: no such directory here" };
                break :blk .nil;
            },
            else => unreachable, // `openHeld` answers every other kind here
        },
        .shell => |host| switch (d.kind) {
            .file => try openShell(ctx, command_context, host, d.ref),
            .directory => try openShellDirectory(ctx, command_context, host, d.ref, text),
            else => return .{ .string = "open: a shell locus holds files and directories" },
        },
        .peer => blk: {
            const peers = command_context.peers orelse return .{ .string = core.designation.refuse_unreachable };
            const result = try peers.open(peers.context, ctx, d);
            if (result == .string) return result;
            break :blk result;
        },
    };
    core.designation.applyPosition(ctx, d);
    return opened;
}

/// A local path — absolute by the time it gets here — as a file entry, or as
/// the directory's listing.
fn openLocal(ctx: *core.command.Context, command_context: *Context, raw: []const u8) anyerror!core.command.Value {
    return openLocalWith(ctx, command_context, raw, null);
}

/// How a caller that has READ a local file through something stronger than
/// its path opens it: the same entry `open` makes (deduped, placed, with its
/// providers), showing those bytes (`Editor.openFileContent`). The session
/// opens a listing's file row this way, from bytes read relative to the
/// directory handle it checked, so no swap of the path between the check
/// and the read can change what opens.
pub const FileOpener = struct {
    context: *Context,

    pub fn open(self: FileOpener, ctx: *core.command.Context, path: []const u8, bytes: []const u8) anyerror!void {
        _ = try openLocalWith(ctx, self.context, path, bytes);
    }
};

/// `openLocal`, with the file's bytes when the caller already has them.
fn openLocalWith(ctx: *core.command.Context, command_context: *Context, raw: []const u8, content: ?[]const u8) anyerror!core.command.Value {
    const deps = command_context.attachments;
    // One spelling per file: `a/../b` and `b` are one entry.
    const spec = try std.fs.path.resolve(ctx.gpa, &.{raw});
    defer ctx.gpa.free(spec);
    if (ctx.buffers.findByPath(spec)) |id| {
        try ctx.buffers.switchTo(ctx.gpa, id, ctx.head, ctx.keymap);
        return .{ .integer = @intCast(id) };
    }
    if (content == null) if (command_context.directories) |directories|
        if (try directories.open(directories.context, ctx, spec)) return .nil;

    const id = try ctx.buffers.create(ctx.gpa, std.fs.path.basename(spec));
    errdefer ctx.buffers.close(ctx.gpa, id, ctx.head, ctx.keymap) catch {};
    const buf = ctx.buffers.get(id).?;
    const editor = buf.textEditor().?;
    if (content) |bytes| try editor.openFileContent(ctx.gpa, spec, bytes) else editor.openFile(ctx.gpa, spec) catch |err| switch (err) {
        error.FileNotFound => try editor.adoptPath(ctx.gpa, spec),
        else => |e| return e,
    };
    // A file's place comes from its OWN path, never from whatever was
    // focused when it was opened (`doc/place.md` §2.1). This is where the
    // creation-time inheritance every entry starts with is replaced by the
    // real answer — and why opening a file from project A's tool buffer
    // still lands the file in project B if that is where it lives.
    if (command_context.directories) |directories| {
        if (directories.place_for(directories.context, ctx, spec)) |p|
            ctx.buffers.setPlace(id, p);
    }
    try attachProviders(deps, buf);
    try ctx.buffers.switchTo(ctx.gpa, id, ctx.head, ctx.keymap);
    return .{ .integer = @intCast(id) };
}

/// scp-style `host:path` — no `/` before the first `:`.
fn scpSpec(spec: []const u8) ?struct { host: []const u8, path: []const u8 } {
    const colon = std.mem.indexOfScalar(u8, spec, ':') orelse return null;
    if (std.mem.indexOfScalar(u8, spec[0..colon], '/') != null) return null;
    if (colon == 0 or colon + 1 >= spec.len) return null;
    return .{ .host = spec[0..colon], .path = spec[colon + 1 ..] };
}

/// A file over `host`'s persistent shell, deduped by (shell, remote path).
/// The entry is named `weft://shell:<host>/file/<path>` when the path is
/// absolute; a home-relative one names nothing durable, and the entry is its
/// document.
fn openShell(ctx: *core.command.Context, command_context: *Context, host: []const u8, path: []const u8) anyerror!core.command.Value {
    const deps = command_context.attachments;
    const fs0: ?*core.ShellFs = if (deps.shells.get(host)) |sh| &sh.channel else null;
    var rit = ctx.buffers.iterator();
    while (rit.next()) |b| {
        switch ((b.textEditor() orelse continue).backing) {
            .remote => |r| if (core.backing.ShellRemote.of(r.remote)) |s| if (s.fs == fs0 and std.mem.eql(u8, s.path, path)) {
                try ctx.buffers.switchTo(ctx.gpa, b.id, ctx.head, ctx.keymap);
                return .{ .integer = @intCast(b.id) };
            },
            else => {},
        }
    }
    const id = try ctx.buffers.create(ctx.gpa, std.fs.path.basename(path));
    errdefer ctx.buffers.close(ctx.gpa, id, ctx.head, ctx.keymap) catch {};
    const buf = ctx.buffers.get(id).?;
    const fs = try deps.shellFor(host);
    try buf.textEditor().?.openShell(ctx.gpa, fs, path);
    if (std.fs.path.isAbsolutePosix(path)) {
        var named: [core.designation.max_len]u8 = undefined;
        const d: durable.Designation = .{ .authority = .{ .shell = host }, .kind = .file, .ref = path };
        if (d.render(&named)) |text| try buf.setDesignation(ctx.gpa, text) else |_| {}
        // Its place is the directory it is in, on the shell's locus — so it
        // reads `remote`, a sidebar following the place lists that
        // directory, and the file's row is revealed there.
        const parent = try deps.shellDirectory(ctx, host, std.fs.path.dirnamePosix(path) orelse "/");
        if (try core.designation.placeOf(ctx, parent)) |p| ctx.buffers.setPlace(id, p);
    }
    try attachProviders(deps, buf);
    try ctx.buffers.switchTo(ctx.gpa, id, ctx.head, ctx.keymap);
    return .{ .integer = @intCast(id) };
}

/// A directory over `host`'s shell, presented as a listing like every other
/// directory (`session.presentDirectory`) — through the shell's filesystem
/// provider, so it lists, descends, reveals and opens its files the way a
/// local or a peer's directory does — and in its own place, on the shell's
/// locus. A listing already showing it is focused instead.
fn openShellDirectory(ctx: *core.command.Context, command_context: *Context, host: []const u8, path: []const u8, text: []const u8) anyerror!core.command.Value {
    if (core.designation.findText(ctx.buffers, text)) |live| {
        try ctx.buffers.switchTo(ctx.gpa, live.id, ctx.head, ctx.keymap);
        return .{ .integer = @intCast(live.id) };
    }
    const at = command_context.attachments.shellDirectory(ctx, host, path) catch |err| return switch (err) {
        error.NotFound, error.NotDirectory => .{ .string = "open: the shell has no such directory" },
        error.Io => .{ .string = "open: the shell is not answering" },
        else => |e| e,
    };
    try @import("session.zig").presentDirectory(ctx, at);
    if (try core.designation.placeOf(ctx, at)) |p| ctx.buffers.setPlace(ctx.buffers.active_id, p);
    return .nil;
}

// ── Remote directory browsing (fs_source over the host's shell) ─────

/// One remote-browse pick's navigation state: the host and the current
/// directory. Accepting descends (dir), ascends (`../`), or opens a
/// file — each re-runs `file.browse-remote` or `open` by name.
const RemoteBrowse = struct {
    host: []u8,
    path: []u8,
};

/// `file.browse-remote <host> <path>` — list a remote directory over the
/// persistent ssh shell and pick over it (streamed by fs_source).
pub fn browseRemoteHandler(ctx: *core.command.Context, data: ?*anyopaque, args: []const core.command.Value) anyerror!core.command.Value {
    const command_context: *Context = @ptrCast(@alignCast(data.?));
    const deps = command_context.attachments;
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
    }, .{ .allow_free_text = true, .source = rd.source(), .category = "dir" });
    return .nil;
}

fn browseRemoteAccept(ctx: *core.command.Context, data: ?*anyopaque, outcome: core.pick.Outcome) anyerror!void {
    const rb: *RemoteBrowse = @ptrCast(@alignCast(data.?));
    const choice = outcome.text() orelse return;
    const gpa = ctx.gpa;
    if (std.mem.eql(u8, choice, "../")) {
        const up = parentPath(rb.path);
        _ = try core.command.run(ctx.commands, ctx, "file.browse-remote", &.{
            .{ .string = rb.host }, .{ .string = up },
        });
        return;
    }
    if (std.mem.endsWith(u8, choice, "/")) {
        const child = try joinPath(gpa, rb.path, choice[0 .. choice.len - 1]);
        defer gpa.free(child);
        _ = try core.command.run(ctx.commands, ctx, "file.browse-remote", &.{
            .{ .string = rb.host }, .{ .string = child },
        });
        return;
    }
    const child = try joinPath(gpa, rb.path, choice);
    defer gpa.free(child);
    const spec = try std.fmt.allocPrint(gpa, "{s}:{s}", .{ rb.host, child });
    defer gpa.free(spec);
    _ = try core.command.run(ctx.commands, ctx, "file.open", &.{.{ .string = spec }});
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

/// `EntryShell.open`: `file.open`, where the shell is.
fn openThroughShell(raw: *anyopaque, ctx: *core.command.Context, spec: []const u8) anyerror!core.command.Value {
    return openBufferHandler(ctx, raw, &.{.{ .string = spec }});
}

/// `EntryShell.retire`: `entry` is closing. Core's close alone leaked its
/// syntax instance (tree, parser, mirror rope) and its feed layers, and left
/// peers bound to a document about to die. Order matters: shares reference
/// the doc and its layers.
fn retireThroughShell(raw: *anyopaque, ctx: *core.command.Context, entry: *core.Buffers.Buffer) void {
    _ = ctx;
    const command_context: *Context = @ptrCast(@alignCast(raw));
    const deps = command_context.attachments;
    if (deps.share) |sc| {
        if (sc.conn.*) |*c| c.unbindTag(entry.id);
        if (sc.hub.*) |*h| for (h.clients.items) |peer| peer.conn.unbindTag(entry.id);
        var i: usize = 0;
        while (i < sc.shared.items.len) {
            if (sc.shared.items[i].tag == entry.id) {
                sc.gpa.free(sc.shared.items[i].name);
                _ = sc.shared.swapRemove(i);
            } else i += 1;
        }
    }
    detachProviders(deps, entry);
}

/// Bind the shell's own command, `file.browse-remote`, onto `commands`,
/// pointing at the caller-owned `context`. Opening and closing are core's
/// commands; the shell answers them through `Context.entryShell`.
pub fn registerCommands(gpa: std.mem.Allocator, commands: *core.command.Commands, context: *Context) !void {
    _ = try commands.bind(gpa, "file.browse-remote", .{
        .name = "file.browse-remote",
        .summary = "Browse a directory on a remote host over its shell.",
        .args = &.{
            .{ .name = "host", .type = .string },
            .{ .name = "path", .type = .string },
        },
        .handler = browseRemoteHandler,
        .data = context,
        .meta = .{ .label = "Browse Remote Files", .icon = "globe", .prompts = true },
    });
}
