//! Per-buffer provider attachments. Syntax and LSP are per-buffer instances
//! hanging off `Buffer.frontend`; their capability providers decline foreign
//! documents, so per-buffer registrations race correctly. Highlight/diagnostic
//! layers key by (doc, name) in the shared store. Also the config-supplied
//! registries these attach from: grammars (`grammar-add`) and language servers
//! (`lsp-add`), and the pooled reconnect task.

const std = @import("std");
const core = @import("../core/core.zig");
const collab = @import("collab.zig");

/// `grammar-add <ext> <package-dir> <symbol>` — grammars as data.
pub fn grammarAddCommand(runtime: *core.syntax.Runtime) core.command.Command {
    return .{
        .name = "grammar-add",
        .summary = "Register a tree-sitter grammar package for an extension.",
        .args = &.{
            .{ .name = "ext", .type = .string },
            .{ .name = "dir", .type = .string },
            .{ .name = "symbol", .type = .string },
        },
        .handler = grammarAddHandler,
        .data = runtime,
    };
}

fn grammarAddHandler(ctx: *core.command.Context, data: ?*anyopaque, args: []const core.command.Value) anyerror!core.command.Value {
    const runtime: *core.syntax.Runtime = @ptrCast(@alignCast(data.?));
    if (args.len != 3) return error.ArityMismatch;
    for (args) |a| {
        if (a != .string) return error.TypeMismatch;
    }
    try runtime.add(ctx.gpa, args[0].string, args[1].string, args[2].string);
    return .nil;
}

/// Language-server registrations: (extension → argv), config-supplied.
pub const LspServers = struct {
    const Entry = struct {
        ext: []u8,
        argv: [][]u8,
        exts: [1][]const u8,

        fn extSlice(self: *Entry) []const []const u8 {
            self.exts[0] = self.ext;
            return &self.exts;
        }
    };

    list: std.ArrayList(*Entry) = .empty,

    pub const empty: LspServers = .{};

    pub fn deinit(self: *LspServers, gpa: std.mem.Allocator) void {
        for (self.list.items) |e| {
            gpa.free(e.ext);
            for (e.argv) |a| gpa.free(a);
            gpa.free(e.argv);
            gpa.destroy(e);
        }
        self.list.deinit(gpa);
    }

    fn match(self: *LspServers, path: []const u8) ?*Entry {
        var i = self.list.items.len;
        while (i > 0) {
            i -= 1;
            if (std.mem.endsWith(u8, path, self.list.items[i].ext)) return self.list.items[i];
        }
        return null;
    }
};

pub fn lspAddCommand(servers: *LspServers) core.command.Command {
    return .{
        .name = "lsp-add",
        .summary = "Register a language server command for an extension.",
        .args = &.{
            .{ .name = "ext", .type = .string },
            .{ .name = "cmd", .type = .string },
        },
        .handler = lspAddHandler,
        .data = servers,
    };
}

fn lspAddHandler(ctx: *core.command.Context, data: ?*anyopaque, args: []const core.command.Value) anyerror!core.command.Value {
    const servers: *LspServers = @ptrCast(@alignCast(data.?));
    if (args.len != 2 or args[0] != .string or args[1] != .string) return error.TypeMismatch;
    const gpa = ctx.gpa;
    var argv: std.ArrayList([]u8) = .empty;
    errdefer {
        for (argv.items) |a| gpa.free(a);
        argv.deinit(gpa);
    }
    var it = std.mem.tokenizeScalar(u8, args[1].string, ' ');
    while (it.next()) |word| try argv.append(gpa, try gpa.dupe(u8, word));
    if (argv.items.len == 0) return error.TypeMismatch;
    const e = try gpa.create(LspServers.Entry);
    errdefer gpa.destroy(e);
    e.* = .{
        .ext = try gpa.dupe(u8, args[0].string),
        .argv = try argv.toOwnedSlice(gpa),
        .exts = undefined,
    };
    try servers.list.append(gpa, e);
    return .nil;
}

pub fn reconnectTask(hostport: []const u8) anyerror!i32 {
    return core.session.tcpConnect(hostport);
}

// ── Per-buffer provider attachments ─────────────────────────────────
// Syntax and LSP are per-buffer instances hanging off Buffer.frontend;
// their capability providers decline foreign documents, so per-buffer
// registrations race correctly. Highlight/diagnostic layers key by
// (doc, name) in the shared store.

pub const Attach = struct {
    syntax: ?*core.syntax.Syntax = null,
    lsp: ?*core.lsp.Lsp = null,
    seen_commits: usize = 0,
};

/// The `abi.SyntaxResolver` the catalog uses: reach a buffer's live grammar
/// through the shell-owned frontend slot (core cannot; the host can).
pub fn resolveSyntax(buf: *core.Buffers.Buffer) ?*core.syntax.Syntax {
    const at: *Attach = @ptrCast(@alignCast(buf.frontend orelse return null));
    return at.syntax;
}

pub const AttachDeps = struct {
    gpa: std.mem.Allocator,
    grammars: *core.syntax.Runtime,
    lsp_servers: *LspServers,
    caps: *core.Caps,
    environ: std.process.Environ,
    local_lsp: bool,
    /// Set once the connection exists: buffer close unbinds shares
    /// before the document dies.
    share: ?*collab.ShareCtx = null,
    /// Persistent shells per remote host (ssh spawner), created on
    /// first `open host:path` and reused for every buffer on that host.
    shells: std.StringHashMapUnmanaged(*core.ShellFs) = .empty,

    pub fn deinitShells(self: *AttachDeps) void {
        var it = self.shells.iterator();
        while (it.next()) |e| {
            e.value_ptr.*.deinit();
            self.gpa.destroy(e.value_ptr.*);
            self.gpa.free(e.key_ptr.*);
        }
        self.shells.deinit(self.gpa);
    }

    pub fn shellFor(self: *AttachDeps, host: []const u8) !*core.ShellFs {
        if (self.shells.get(host)) |fs| return fs;
        const fs = try self.gpa.create(core.ShellFs);
        errdefer self.gpa.destroy(fs);
        // BatchMode=yes: never block on an interactive password prompt (a
        // classic hang); ConnectTimeout bounds an unreachable host. The
        // spawn is still synchronous on the frame thread, but now it fails
        // fast instead of wedging the editor.
        fs.* = try core.ShellFs.spawn(self.gpa, &.{
            "ssh", "-o",               "BatchMode=yes",
            "-o",  "ConnectTimeout=8", host,
            "sh",
        }, self.environ);
        errdefer fs.deinit();
        try self.shells.put(self.gpa, try self.gpa.dupe(u8, host), fs);
        return fs;
    }
};

/// Idempotent: give a buffer its provider bundle (syntax by extension,
/// LSP when locally placed). Buffers without a path get an empty
/// bundle (tool/scratch).
pub fn attachProviders(deps: *AttachDeps, buf: *core.Buffers.Buffer) !void {
    if (buf.frontend != null) return;
    const gpa = deps.gpa;
    const at = try gpa.create(Attach);
    at.* = .{};
    buf.frontend = at;
    const doc = &buf.editor.doc;

    // The buffer's *language* is identified by its name/path hint —
    // independent of where the bytes live. A shared (remote) buffer holds
    // its content in our replica, so tree-sitter highlights it locally
    // even with no local file backing. (Local) LSP is different: the
    // server needs the file on this machine, so it attaches only to a
    // locally-backed buffer, below.
    const lang_path = buf.editor.backingPath() orelse buf.name;

    if (deps.grammars.forPath(lang_path)) |spec| {
        at.syntax = core.syntax.Syntax.create(gpa, spec, doc) catch |err| blk: {
            std.log.warn("syntax {s} unavailable: {t}", .{ spec.name, err });
            break :blk null;
        };
    }
    if (at.syntax) |syn| {
        try core.syntax.registerProviders(deps.caps, syn);
        _ = try deps.caps.registerFeed(doc, "edit/highlight", "highlight", .local, "treesitter");
    }
    if (deps.local_lsp) {
        if (buf.editor.backingPath()) |p| {
            if (deps.lsp_servers.match(p)) |entry| {
                at.lsp = core.lsp.Lsp.create(gpa, entry.argv, p, doc, deps.environ) catch |err| blk: {
                    std.log.warn("lsp unavailable: {t}", .{err});
                    break :blk null;
                };
                if (at.lsp) |l| {
                    const diag_layer = try deps.caps.registerFeed(doc, "edit/diagnostics", "diagnostics", .host, "lsp/server");
                    l.attachDiagnostics(diag_layer);
                    l.attachCaps(deps.caps, entry.extSlice());
                }
            }
        }
    }
}

pub fn detachProviders(deps: *AttachDeps, buf: *core.Buffers.Buffer) void {
    const at: *Attach = @ptrCast(@alignCast(buf.frontend orelse return));
    if (at.lsp) |l| l.destroy();
    if (at.syntax) |s| s.destroy();
    deps.caps.layers.dropDoc(deps.gpa, &buf.editor.doc);
    deps.gpa.destroy(at);
    buf.frontend = null;
}

/// The provider cluster, owned as one unit: the config-extended registries
/// (`grammars`, `lsp_servers`) plus the per-buffer attach bundle (`attach_deps`).
/// It mirrors how `RenderState`/`Session` own their clusters — `main()` holds one
/// `providers` object instead of three loose provider locals.
///
/// Two-phase, because the pieces are born at different times: the registries
/// exist BEFORE the session (its capability consumers bind `grammar-add`/
/// `lsp-add` onto them), while `attach_deps` borrows the session's caps + the
/// connect placement, so it is built AFTER the session.
///
/// CRITICAL TEARDOWN ORDER — the whole reason this is a distinct cluster:
/// `attach_deps.deinitShells()` must run AFTER the buffers die (in-flight save
/// workers still use shell backings at shutdown) AND after the task pool joins
/// (a pool worker may still hold a shell). `main()` guarantees this by
/// registering `Providers.deinit` FIRST (so it runs LAST) — after both
/// `Session.deinit` and `pool.deinit`. Grammars/LSP are independent data, freed
/// here too (their syntax instances were already destroyed by `detachProviders`,
/// which `main()` runs before this).
pub const Providers = struct {
    grammars: core.syntax.Runtime,
    lsp_servers: LspServers,
    attach_deps: AttachDeps,
    /// `attach_deps` is filled in phase two; until then `deinit` must not touch
    /// it (an early error between the two phases would otherwise free garbage).
    attached: bool,

    /// Phase one: the config-extended registries, built before the session.
    pub fn initRegistries(self: *Providers, gpa: std.mem.Allocator) !void {
        self.grammars = try core.syntax.Runtime.initBuiltins(gpa);
        errdefer self.grammars.deinit(gpa);
        self.lsp_servers = .empty;
        self.attached = false;
    }

    /// Phase two: the per-buffer attach bundle, built once the session's caps
    /// and the connect placement are known. It borrows into `self` (grammars/
    /// lsp_servers), so it must run IN PLACE (self already at its final
    /// address). `share` is wired by `main()` once the collab state exists.
    pub fn initAttach(
        self: *Providers,
        gpa: std.mem.Allocator,
        caps: *core.Caps,
        environ: std.process.Environ,
        local_lsp: bool,
    ) void {
        self.attach_deps = .{
            .gpa = gpa,
            .grammars = &self.grammars,
            .lsp_servers = &self.lsp_servers,
            .caps = caps,
            .environ = environ,
            .local_lsp = local_lsp,
        };
        self.attached = true;
    }

    /// Free in the order `main()`'s defers used to run: lsp_servers, grammars,
    /// then the persistent remote shells LAST (they outlive buffers + pool).
    pub fn deinit(self: *Providers, gpa: std.mem.Allocator) void {
        self.lsp_servers.deinit(gpa);
        self.grammars.deinit(gpa);
        if (self.attached) self.attach_deps.deinitShells();
    }
};
