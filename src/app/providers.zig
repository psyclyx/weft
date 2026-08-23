//! Per-buffer provider attachments. Syntax is a per-buffer instance hanging off
//! `Buffer.frontend`; its capability providers decline foreign documents, so
//! per-buffer registrations race correctly. Highlight layers key by (doc, name)
//! in the shared store. Also the config-supplied grammar registry these attach
//! from (`grammar-add`) and the pooled reconnect task. LSP is no longer here at
//! all — it's an async wasm plugin (`src/guest/lsp.zig`) that talks to servers
//! over the streaming membrane and provides every capability, completion
//! included, as a caps provider; server commands come from config, not a
//! registry. See [[lsp-plugin-migration]].

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

pub fn reconnectTask(hostport: []const u8) anyerror!i32 {
    return core.session.tcpConnect(hostport);
}

// ── Per-buffer provider attachments ─────────────────────────────────
// Syntax is a per-buffer instance hanging off Buffer.frontend; its
// capability providers decline foreign documents, so per-buffer
// registrations race correctly. Highlight layers key by (doc, name) in
// the shared store.

pub const Attach = struct {
    syntax: ?*core.syntax.Syntax = null,
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
    caps: *core.Caps,
    environ: std.process.Environ,
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
        // `createAsync`, not `create`: the initial full parse costs the
        // whole file (an incremental reparse after only costs the edit —
        // tree-sitter does that part for free), so it runs on the
        // buffer's own pool worker instead of blocking `open`. See
        // src/core/syntax.zig's module doc for how the tree lands.
        at.syntax = core.syntax.Syntax.createAsync(gpa, buf.editor.pool, spec, doc) catch |err| blk: {
            std.log.warn("syntax {s} unavailable: {t}", .{ spec.name, err });
            break :blk null;
        };
    }
    if (at.syntax) |syn| {
        try core.syntax.registerProviders(deps.caps, syn);
        _ = try deps.caps.registerFeed(doc, "edit/highlight", "highlight", .local, "treesitter");
    }
    // LSP (all capabilities, completion included) is the `lsp` wasm plugin now,
    // attaching via its own on_activate — nothing to wire per-buffer here.
}

pub fn detachProviders(deps: *AttachDeps, buf: *core.Buffers.Buffer) void {
    const at: *Attach = @ptrCast(@alignCast(buf.frontend orelse return));
    if (at.syntax) |s| s.destroy();
    deps.caps.layers.dropDoc(deps.gpa, &buf.editor.doc);
    deps.gpa.destroy(at);
    buf.frontend = null;
}

/// The provider cluster, owned as one unit: the config-extended grammar registry
/// (`grammars`) plus the per-buffer attach bundle (`attach_deps`). It mirrors how
/// `RenderState`/`Session` own their clusters — `main()` holds one `providers`
/// object instead of loose provider locals.
///
/// Two-phase, because the pieces are born at different times: the registry exists
/// BEFORE the session (its capability consumers bind `grammar-add` onto it),
/// while `attach_deps` borrows the session's caps, so it is built AFTER.
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
    attach_deps: AttachDeps,
    /// `attach_deps` is filled in phase two; until then `deinit` must not touch
    /// it (an early error between the two phases would otherwise free garbage).
    attached: bool,

    /// Phase one: the config-extended registries, built before the session.
    pub fn initRegistries(self: *Providers, gpa: std.mem.Allocator) !void {
        self.grammars = try core.syntax.Runtime.initBuiltins(gpa);
        errdefer self.grammars.deinit(gpa);
        self.attached = false;
    }

    /// Phase two: the per-buffer attach bundle, built once the session's caps are
    /// known. It borrows into `self` (grammars), so it must run IN PLACE (self
    /// already at its final address). `share` is wired by `main()` once the collab
    /// state exists.
    pub fn initAttach(
        self: *Providers,
        gpa: std.mem.Allocator,
        caps: *core.Caps,
        environ: std.process.Environ,
    ) void {
        self.attach_deps = .{
            .gpa = gpa,
            .grammars = &self.grammars,
            .caps = caps,
            .environ = environ,
        };
        self.attached = true;
    }

    /// Free in the order `main()`'s defers used to run: grammars, then the
    /// persistent remote shells LAST (they outlive buffers + pool).
    pub fn deinit(self: *Providers, gpa: std.mem.Allocator) void {
        self.grammars.deinit(gpa);
        if (self.attached) self.attach_deps.deinitShells();
    }
};
