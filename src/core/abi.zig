//! abi.zig — the single door a plugin sees (design §4, plan 03). The
//! primitives from milestones 01/02, grouped by permission, behind one Zig
//! facade: the trusted in-process mirror of the legacy Lua `weft.*` surface,
//! minus the footgun list. Built Zig-first so the wasm membrane (plan 05)
//! changes only the transport, never the ABI shape — every call already
//! crosses as the portable Value ABI (+ stamped positions), carries its
//! locus inside a handle, keeps grade implicit in the invoking Principal,
//! and never leaks a host pointer to the guest.
//!
//! The permission groups (design §4): **A core** (log/now — ungated), **B
//! read-only** (document/cursor/slice/capability-fire), **C write**
//! (`edit` via the grade gate, command/provider/layer registration), **D
//! effects** (async/proc/net — gated caps), **E admin** (kv). A plugin
//! declares what it will register in its `Manifest`; the host CROSS-CHECKS
//! every runtime registration against that declaration, so a plugin that
//! registers something it did not declare — or uses a perm it did not
//! request — fails to load. That is the perm model's *shape*, validated in
//! process even before the sandbox enforces it in 05.

const std = @import("std");
const Allocator = std.mem.Allocator;

const command = @import("command.zig");
const authority = @import("authority.zig");
const Document = @import("Document.zig");
const layers = @import("layers.zig");
const capability = @import("capability.zig");
const kv = @import("kv.zig");
const async_loop = @import("async.zig");
const mode = @import("mode.zig");
const proc = @import("proc.zig");
const net = @import("net.zig");
const subbuffer = @import("subbuffer.zig");
const position = @import("position.zig");
const syntax = @import("syntax.zig");
const Buffers = @import("Buffers.zig");
const pick = @import("pick.zig");
const fs_source = @import("fs_source.zig");

pub const Value = command.Value;
pub const Grade = authority.Grade;

/// A host capability a plugin requests up front. Granted after the user
/// approves `describe()`; using an ungranted one traps.
pub const Perm = enum { fs_read, fs_write, net, proc, timer };

pub const Level = enum { debug, info, warn, err };

pub const CommandDecl = struct { name: []const u8 };
pub const ProviderDecl = struct { capability: []const u8 };

/// A predicate→contribution declaration (design §7). The engine (mode.zig)
/// activates it exactly on the buffers whose facts the predicate matches,
/// and reverses it when they no longer do — order-independent, retroactive
/// on late load. `tag` is the plugin's own handle for the contribution, so
/// when reconcile says "activation X is on", the plugin knows what to apply.
pub const ActivationDecl = struct {
    predicate: mode.Predicate,
    kind: mode.Kind = .capability,
    priority: i32 = 0,
    tag: u32 = 0,
};

/// A plugin's up-front declaration (design §1). `describe()` returns it with
/// ALL caps gated off; the host reads it, the user approves, grants flip on,
/// then `init()` runs. Runtime registrations are checked against it.
pub const Manifest = struct {
    name: []const u8,
    perms: []const Perm = &.{},
    /// The most authority it will ever want on a document.
    grant_max: Grade = .edit,
    commands: []const CommandDecl = &.{},
    capabilities: []const ProviderDecl = &.{},
    activations: []const ActivationDecl = &.{},
};

/// A command implemented in a plugin: sees the ABI + the portable args.
pub const Handler = *const fn (abi: *Abi, args: []const Value) anyerror!Value;

/// A completion provider: given the word `prefix`, append candidate strings
/// (OWNED — the ABI frees them after the host deep-copies) to `out`.
pub const CompletionHandler = *const fn (abi: *Abi, prefix: []const u8, out: *std.ArrayList([]const u8)) anyerror!void;

/// A pick item: `text` matches/accepts, `doc` is display-only (borrowed for
/// the `openPick` call; the picker copies).
pub const PickItem = struct { text: []const u8, doc: []const u8 = "" };
/// Called with the accepted choice when a pick the plugin opened resolves.
pub const PickAccept = *const fn (abi: *Abi, choice: []const u8) anyerror!void;

/// The in-process plugin trait. `describe` runs with no authority; `init`
/// runs after approval, handed the granted `*Abi`; `deinit` is optional
/// cleanup (registrations are torn down automatically by the host).
pub const Plugin = struct {
    describe: *const fn () Manifest,
    init: *const fn (abi: *Abi) anyerror!void,
    deinit: ?*const fn (abi: *Abi) void = null,
};

/// Optional host effect services, wired by the host as it owns them. A
/// plugin reaching an unwired one traps (`error.Unavailable`) rather than
/// silently no-oping — the same honesty the whole surface keeps.
/// Resolves a buffer's live tree-sitter `Syntax` (which the shell keeps in
/// the opaque `Buffer.frontend`, out of core's reach) — the host, which
/// owns that slot, provides this so the ABI can expose structural queries
/// without core learning the frontend's shape.
pub const SyntaxResolver = *const fn (buf: *Buffers.Buffer) ?*syntax.Syntax;

pub const Services = struct {
    kv: ?*kv.Store = null,
    loop: ?*async_loop.Loop = null,
    subbuffers: ?*subbuffer.SubBuffers = null,
    syntax_of: ?SyntaxResolver = null,
};

pub const EffectError = error{ PermissionDenied, Unavailable } || Allocator.Error;

pub const LoadError = error{
    UndeclaredCommand,
    UndeclaredCapability,
    DuplicatePlugin,
} || Allocator.Error || Document.AddPeerError;

/// One loaded plugin instance: its manifest, the principal it authors as,
/// and the registrations to tear down. Heap-owned by the host (stable
/// address — the command trampolines close over it).
const ActivationBinding = struct { engine_id: u32, tag: u32 };

/// A plugin's open pick: its accept action + owning plugin. Freed by the
/// pick's cleanup when it closes (accept or cancel).
const BoundPick = struct {
    loaded: *Loaded,
    accept: PickAccept,
};

/// A plugin capability provider bound into the caps registry.
const BoundProvider = struct {
    loaded: *Loaded,
    completion: CompletionHandler,
    id: []u8,
};

const Loaded = struct {
    host: *Host,
    manifest: Manifest,
    commands: std.ArrayList(*Bound) = .empty,
    activations: std.ArrayList(ActivationBinding) = .empty,
    providers: std.ArrayList(*BoundProvider) = .empty,

    /// This plugin as an edit principal: authors as its own peer on
    /// whatever document is active at edit time (resolved, never captured).
    fn principal(self: *Loaded) authority.Principal {
        return .{ .role = .plugin, .name = self.manifest.name, .ctx = self, .resolve = resolvePeer };
    }

    fn resolvePeer(ctx: *anyopaque, doc: *Document) Document.AddPeerError!Document.PeerId {
        const self: *Loaded = @ptrCast(@alignCast(ctx));
        return doc.peerNamed(self.host.ctx.gpa, self.manifest.name);
    }

    fn declaresCommand(self: *Loaded, name: []const u8) bool {
        for (self.manifest.commands) |d| if (std.mem.eql(u8, d.name, name)) return true;
        return false;
    }

    fn declaresCapability(self: *Loaded, cap: []const u8) bool {
        for (self.manifest.capabilities) |d| if (std.mem.eql(u8, d.capability, cap)) return true;
        return false;
    }

    fn hasPerm(self: *Loaded, perm: Perm) bool {
        for (self.manifest.perms) |p| if (p == perm) return true;
        return false;
    }
};

/// A plugin command bound into the shared registry: the trampoline data.
const Bound = struct {
    loaded: *Loaded,
    handler: Handler,
    name: []u8,
};

/// The loader/registry. Owns every loaded plugin, cross-checks their
/// registrations against their manifests, and tears them down cleanly.
pub const Host = struct {
    ctx: *command.Context,
    services: Services = .{},
    plugins: std.ArrayList(*Loaded) = .empty,
    /// The mode reconcile engine (mode.zig): every plugin's activation
    /// declarations register here, so activation is one order-independent
    /// diff, retroactive to open buffers on late plugin load.
    modes: mode.Engine = .empty,

    pub fn init(ctx: *command.Context, services: Services) Host {
        return .{ .ctx = ctx, .services = services };
    }

    pub fn deinit(self: *Host) void {
        // Teardown newest-first (a later shadow unbinds before the shadowed).
        while (self.plugins.items.len > 0) {
            self.unloadAt(self.plugins.items.len - 1);
        }
        self.plugins.deinit(self.ctx.gpa);
        self.modes.deinit(self.ctx.gpa);
    }

    /// Reconcile a buffer's mode contributions against its facts: appends
    /// the newly-active and newly-inactive activation ids to the caller's
    /// lists (resolve each with `activationOf` to the plugin + its tag, then
    /// apply/revert the real contribution). A pure diff — see mode.zig.
    pub fn reconcile(
        self: *Host,
        buf_key: usize,
        resource: mode.Resource,
        activated: *std.ArrayList(u32),
        deactivated: *std.ArrayList(u32),
    ) mode.Error!void {
        return self.modes.reconcile(self.ctx.gpa, buf_key, resource, activated, deactivated);
    }

    /// Resolve an engine activation id back to the plugin that declared it
    /// and that plugin's own contribution tag.
    pub fn activationOf(self: *Host, engine_id: u32) ?struct { name: []const u8, tag: u32 } {
        for (self.plugins.items) |p| {
            for (p.activations.items) |a| {
                if (a.engine_id == engine_id) return .{ .name = p.manifest.name, .tag = a.tag };
            }
        }
        return null;
    }

    /// The handshake: `describe()` (no authority) → [host would prompt the
    /// user here] → grants flip on → `init(abi)`. Registrations during
    /// `init` are cross-checked; an undeclared one fails the load and the
    /// partial plugin is rolled back.
    pub fn load(self: *Host, plugin: Plugin) anyerror!void {
        const gpa = self.ctx.gpa;
        const manifest = plugin.describe();
        for (self.plugins.items) |p| {
            if (std.mem.eql(u8, p.manifest.name, manifest.name)) return error.DuplicatePlugin;
        }
        const loaded = try gpa.create(Loaded);
        loaded.* = .{ .host = self, .manifest = manifest };
        self.plugins.append(gpa, loaded) catch |e| {
            gpa.destroy(loaded);
            return e;
        };

        // Register the declared mode contributions (static data — no
        // dependency on init; teardown reverses them on any failure below).
        for (manifest.activations) |decl| {
            const eid = self.modes.activate(gpa, .{
                .id = 0,
                .predicate = decl.predicate,
                .kind = decl.kind,
                .priority = decl.priority,
                .owner = ownerFingerprint(manifest.name),
            }) catch |e| {
                _ = self.plugins.pop();
                self.teardown(loaded);
                return e;
            };
            loaded.activations.append(gpa, .{ .engine_id = eid, .tag = decl.tag }) catch |e| {
                self.modes.deactivate(eid);
                _ = self.plugins.pop();
                self.teardown(loaded);
                return e;
            };
        }

        var abi: Abi = .{ .host = self, .loaded = loaded };
        plugin.init(&abi) catch |e| {
            // Roll back: drop from the set first, then unbind + free. No
            // errdefer on `loaded` — teardown is the single owner of its
            // cleanup, so there is no double free.
            _ = self.plugins.pop(); // `loaded` is the last appended
            self.teardown(loaded);
            return e;
        };
    }

    /// Tear down and free the plugin at `i`.
    fn unloadAt(self: *Host, i: usize) void {
        const loaded = self.plugins.orderedRemove(i);
        self.teardown(loaded);
    }

    fn teardown(self: *Host, loaded: *Loaded) void {
        const gpa = self.ctx.gpa;
        // Capability providers this plugin registered die with it (by id
        // prefix, mirroring the Lua Plugin.destroy teardown).
        var prefix_buf: [128]u8 = undefined;
        if (std.fmt.bufPrint(&prefix_buf, "plugin.{s}/", .{loaded.manifest.name})) |prefix| {
            self.ctx.caps.unregisterByIdPrefix(prefix);
        } else |_| {}
        for (loaded.providers.items) |bp| {
            gpa.free(bp.id);
            gpa.destroy(bp);
        }
        loaded.providers.deinit(gpa);
        for (loaded.activations.items) |a| self.modes.deactivate(a.engine_id);
        loaded.activations.deinit(gpa);
        for (loaded.commands.items) |b| {
            // Only unbind if WE are still the bound handler (a later shadow
            // may own the name now — don't clobber it).
            if (self.ctx.commands.find(b.name)) |n| {
                if (self.ctx.commands.lookup(n)) |cmd| {
                    if (cmd.data == @as(?*anyopaque, b)) self.ctx.commands.unbind(n);
                }
            }
            gpa.free(b.name);
            gpa.destroy(b);
        }
        loaded.commands.deinit(gpa);
        gpa.destroy(loaded);
    }
};

/// The per-plugin facade handed to `init` and to every command handler.
/// Thin: it routes into the host, tagging each call with the plugin's
/// principal and cross-checking its manifest.
pub const Abi = struct {
    host: *Host,
    loaded: *Loaded,

    // ── Config surface (local plane) — the seam a Zig config plugin uses
    // to wire keys/commands, exactly as init.fnl does through `weft.*`
    // (plan 06A: config is a plugin with no special powers). ──

    /// Invoke a command by name (late-bound; resolves at call time). The
    /// same door keymaps and other commands use.
    pub fn run(self: *Abi, name: []const u8, args: []const Value) command.RunError!Value {
        return command.run(self.host.ctx.commands, self.host.ctx, name, args);
    }

    /// Bind `key` in the keymap `mode_name` to a command (config setup).
    pub fn bindKey(self: *Abi, mode_name: []const u8, key: []const u8, cmd: []const u8) !void {
        return self.host.ctx.keymap.bind(self.host.ctx.gpa, mode_name, key, cmd);
    }

    /// `mode_name` falls back to `parent` for unbound keys (mode inheritance).
    pub fn setFallback(self: *Abi, mode_name: []const u8, parent: []const u8) !void {
        return self.host.ctx.keymap.setFallback(self.host.ctx.gpa, mode_name, parent);
    }

    /// Set (or clear, with null) the command that unbound printable input
    /// runs in `mode_name` — the modal posture (normal mode swallows text).
    pub fn textInput(self: *Abi, mode_name: []const u8, cmd: ?[]const u8) !void {
        return self.host.ctx.keymap.setTextCommand(self.host.ctx.gpa, mode_name, cmd);
    }

    /// Declare `mode_name` a menu/prefix mode (which-key shows its bindings
    /// while the chord is pending).
    pub fn menuMode(self: *Abi, mode_name: []const u8) !void {
        return self.host.ctx.keymap.markMenuMode(self.host.ctx.gpa, mode_name);
    }

    /// Switch the active keymap mode.
    pub fn setMode(self: *Abi, mode_name: []const u8) !void {
        return self.host.ctx.keymap.setMode(self.host.ctx.gpa, mode_name);
    }

    /// Place the live cursor at a byte offset (clamped) — the motion write.
    pub fn jump(self: *Abi, offset: usize) void {
        const ed = self.host.ctx.editor();
        ed.placeCursor(@min(offset, ed.text().byteLen()));
    }

    /// The current selection range, or null.
    pub fn selection(self: *Abi) ?Document.Range {
        return self.host.ctx.editor().selectedRange();
    }

    /// Number of registered commands (introspection for palettes/help).
    pub fn commandCount(self: *Abi) usize {
        return self.host.ctx.commands.count();
    }

    /// The `i`-th command's name + summary, or null for an empty slot.
    pub fn commandAt(self: *Abi, i: usize) ?struct { name: []const u8, summary: []const u8 } {
        const n: command.Commands.Name = @enumFromInt(i);
        const cmd = self.host.ctx.commands.lookup(n) orelse return null;
        return .{ .name = self.host.ctx.commands.nameOf(n), .summary = cmd.summary };
    }

    pub const BufferInfo = struct {
        id: u32,
        name: []const u8,
        active: bool,
        read_only: bool,
    };

    /// Open-buffer count (introspection for the buffers picker / status).
    pub fn bufferCount(self: *Abi) usize {
        return self.host.ctx.buffers.count();
    }

    /// The `i`-th live buffer's info (id/name/active/read-only), or null.
    pub fn bufferAt(self: *Abi, i: usize) ?BufferInfo {
        var it = self.host.ctx.buffers.iterator();
        var j: usize = 0;
        while (it.next()) |b| : (j += 1) {
            if (j == i) return .{
                .id = b.id,
                .name = b.name,
                .active = b == self.host.ctx.buffers.active(),
                .read_only = b.read_only,
            };
        }
        return null;
    }

    /// Show a transient status-line message.
    pub fn echo(self: *Abi, msg: []const u8) !void {
        self.host.ctx.echo.clearRetainingCapacity();
        try self.host.ctx.echo.appendSlice(self.host.ctx.gpa, msg);
    }

    /// Open a fuzzy pick over `items`; `on_accept(abi, choice)` fires when a
    /// choice resolves. The vertico/consult substrate — pick loop stays
    /// native; the plugin supplies items + the accept action.
    pub fn openPick(self: *Abi, prompt: []const u8, items: []const PickItem, on_accept: PickAccept) !void {
        const gpa = self.host.ctx.gpa;
        const bp = try gpa.create(BoundPick);
        errdefer gpa.destroy(bp);
        bp.* = .{ .loaded = self.loaded, .accept = on_accept };
        const entries = try gpa.alloc(pick.Entry, items.len);
        defer gpa.free(entries);
        for (items, entries) |it, *e| e.* = .{ .text = it.text, .doc = it.doc };
        self.host.ctx.pick.open(self.host.ctx, prompt, entries, .{
            .handler = pickAccept,
            .cleanup = pickCleanup,
            .data = bp,
        }) catch |e| {
            gpa.destroy(bp);
            return e;
        };
    }

    /// Open a fuzzy FILE picker rooted at `root` (a native recursive finder
    /// streams candidates on the pool); accept opens the chosen path, or the
    /// typed text (free-text) as a new file. The find-file substrate.
    pub fn openFilePick(self: *Abi, prompt: []const u8, root: []const u8, on_accept: PickAccept) !void {
        const gpa = self.host.ctx.gpa;
        const bp = try gpa.create(BoundPick);
        errdefer gpa.destroy(bp);
        bp.* = .{ .loaded = self.loaded, .accept = on_accept };
        const finder = try fs_source.LocalFinder.create(gpa, self.host.ctx.buffers.pool, root);
        // openWith closes the source on failure; only the BoundPick is ours.
        self.host.ctx.pick.openWith(self.host.ctx, prompt, &.{}, .{
            .handler = pickAccept,
            .cleanup = pickCleanup,
            .data = bp,
        }, .{ .source = finder.source(), .allow_free_text = true }) catch |e| {
            gpa.destroy(bp);
            return e;
        };
    }

    // ── Group A: core (ungated) ──────────────────────────────────
    pub fn log(self: *Abi, level: Level, msg: []const u8) void {
        _ = self;
        switch (level) {
            .debug, .info => std.log.info("{s}", .{msg}),
            .warn => std.log.warn("{s}", .{msg}),
            .err => std.log.err("{s}", .{msg}),
        }
    }

    pub fn now(self: *Abi) u64 {
        _ = self;
        return @import("task.zig").nowNs();
    }

    // ── Group B: read-only ───────────────────────────────────────
    pub fn cursor(self: *Abi) usize {
        return self.host.ctx.editor().cursorOffset();
    }

    /// The active buffer's backing path, if any (⌖ carries its locus).
    pub fn path(self: *Abi) ?[]const u8 {
        return self.host.ctx.editor().backingPath();
    }

    /// Byte length of the active document.
    pub fn byteLen(self: *Abi) usize {
        return self.host.ctx.editor().text().byteLen();
    }

    /// The smallest named tree-sitter node covering `offset` (kind + byte
    /// span), or null when the active buffer has no grammar attached. The
    /// structural read primitive (textobjects, folding, node-delete).
    pub fn nodeAt(self: *Abi, offset: usize) ?syntax.Syntax.Node {
        const resolve = self.host.services.syntax_of orelse return null;
        const syn = resolve(self.host.ctx.buffer()) orelse return null;
        return syn.nodeAt(offset);
    }

    /// Named ancestors of the node at `offset`, outermost-first. Caller frees.
    pub fn ancestorsAt(self: *Abi, gpa: Allocator, offset: usize) Allocator.Error![]syntax.Syntax.Node {
        const resolve = self.host.services.syntax_of orelse return gpa.alloc(syntax.Syntax.Node, 0);
        const syn = resolve(self.host.ctx.buffer()) orelse return gpa.alloc(syntax.Syntax.Node, 0);
        return syn.ancestorsAt(gpa, offset);
    }

    /// The `[start, end)` of the line containing `offset` (end is before the
    /// newline). The line-motion read primitive.
    pub fn lineAt(self: *Abi, offset: usize) Document.Range {
        const rope = self.host.ctx.editor().text();
        const row = rope.offsetToPoint(@min(offset, rope.byteLen())).row;
        const line = rope.lineRange(row);
        return .{ .start = line.start, .end = line.end };
    }

    /// Read a byte range of the active document (clamped). Caller frees.
    pub fn slice(self: *Abi, gpa: Allocator, start: usize, end: usize) Allocator.Error![]u8 {
        const rope = self.host.ctx.editor().text();
        const len = rope.byteLen();
        const s = @min(start, len);
        const e = @min(end, len);
        if (e <= s) return gpa.alloc(u8, 0);
        const buf = try gpa.alloc(u8, e - s);
        errdefer gpa.free(buf);
        var sr = rope.streamReader(.{ .start = s, .end = e }, &.{});
        sr.interface.readSliceAll(buf) catch unreachable;
        return buf;
    }

    /// Fire a capability session (read-only — no grant needed to fire).
    pub fn fire(self: *Abi, kind: capability.Kind, opts: capability.Caps.FireOptions) !?u64 {
        const ed = self.host.ctx.editor();
        return self.host.ctx.caps.fire(kind, &ed.doc, ed.backingPath(), opts);
    }

    // ── Group C: write (grade-gated via the principal) ───────────
    /// THE text-mutation door: authored by this plugin's peer, grade-gated.
    pub fn edit(self: *Abi, r: Document.Range, bytes: []const u8) command.Context.EditError!void {
        const saved = self.host.ctx.principal;
        self.host.ctx.principal = self.loaded.principal();
        defer self.host.ctx.principal = saved;
        return self.host.ctx.edit(r, bytes);
    }

    /// Register a command (cross-checked: must be declared in the manifest).
    /// Late-bound + namespaced by the registry; the newest binding shadows.
    pub fn registerCommand(self: *Abi, name: []const u8, handler: Handler) LoadError!void {
        if (!self.loaded.declaresCommand(name)) return error.UndeclaredCommand;
        const gpa = self.host.ctx.gpa;
        const b = try gpa.create(Bound);
        errdefer gpa.destroy(b);
        b.* = .{ .loaded = self.loaded, .handler = handler, .name = try gpa.dupe(u8, name) };
        errdefer gpa.free(b.name);
        try self.loaded.commands.append(gpa, b);
        errdefer _ = self.loaded.commands.pop();
        _ = try self.host.ctx.commands.bind(gpa, b.name, .{
            .name = b.name,
            .summary = "",
            .args = &.{},
            .handler = trampoline,
            .data = b,
        });
    }

    /// Register an `edit/completion` provider (cross-checked: must be
    /// declared in the manifest's capabilities). Read-only — no grant to
    /// register a query provider; results merge-rank with everyone else's in
    /// the race the completion UI fires. Namespaced + torn down by prefix.
    pub fn provideCompletion(self: *Abi, handler: CompletionHandler) LoadError!void {
        if (!self.loaded.declaresCapability("edit/completion")) return error.UndeclaredCapability;
        const gpa = self.host.ctx.gpa;
        const bp = try gpa.create(BoundProvider);
        errdefer gpa.destroy(bp);
        bp.* = .{
            .loaded = self.loaded,
            .completion = handler,
            .id = try std.fmt.allocPrint(gpa, "plugin.{s}/edit/completion", .{self.loaded.manifest.name}),
        };
        errdefer gpa.free(bp.id);
        try self.loaded.providers.append(gpa, bp);
        errdefer _ = self.loaded.providers.pop();
        try self.host.ctx.caps.register(.{
            .capability = "edit/completion",
            .id = bp.id,
            .latency = .instant,
            .data = bp,
            .handler = completionProvider,
        });
    }

    /// Claim a layer to publish annotations into (plane is the `scope`
    /// param; `replicated` traps unless it is the presence layer).
    pub fn claimLayer(self: *Abi, name: []const u8, scope: layers.Scope) !*layers.Layer {
        const ed = self.host.ctx.editor();
        return self.host.ctx.caps.layers.claim(self.host.ctx.gpa, &ed.doc, name, scope, self.loaded.manifest.name);
    }

    // ── Group E: admin (kv) ──────────────────────────────────────
    /// This plugin's kv value for `key`, namespaced by plugin name.
    pub fn kvGet(self: *Abi, key: []const u8) ?[]const u8 {
        const store = self.host.services.kv orelse return null;
        return store.get(self.loaded.manifest.name, key);
    }

    pub fn kvPut(self: *Abi, key: []const u8, value: []const u8) !void {
        const store = self.host.services.kv orelse return error.Unavailable;
        return store.put(self.host.ctx.gpa, self.loaded.manifest.name, key, value);
    }

    // ── Group D: effects (gated by DECLARED perms) ───────────────
    // Each checks the plugin declared the perm in its manifest — the perm
    // model enforced in process, before the sandbox enforces it in 05.

    /// Fire `sink` after `delay_ns` (0 interval = one-shot). Perm: timer.
    pub fn timer(self: *Abi, delay_ns: u64, interval_ns: u64, sink: async_loop.Sink) EffectError!async_loop.Id {
        if (!self.loaded.hasPerm(.timer)) return error.PermissionDenied;
        const loop = self.host.services.loop orelse return error.Unavailable;
        return loop.timer(delay_ns, interval_ns, sink);
    }

    /// Run `work` off-thread; deliver its bytes to `sink` on a later tick.
    /// Perm: timer (the async loop is the same gated capability).
    pub fn asyncSpawn(self: *Abi, work: async_loop.Work, work_ctx: ?*anyopaque, sink: async_loop.Sink) EffectError!async_loop.Id {
        if (!self.loaded.hasPerm(.timer)) return error.PermissionDenied;
        const loop = self.host.services.loop orelse return error.Unavailable;
        return loop.spawn(work, work_ctx, sink);
    }

    pub fn cancel(self: *Abi, id: async_loop.Id) void {
        if (self.host.services.loop) |loop| loop.cancel(id);
    }

    /// Spawn a subprocess (here tier), poll-only. Perm: proc.
    pub fn spawnProc(self: *Abi, argv: []const []const u8, opts: proc.Options) (proc.SpawnError || error{PermissionDenied})!proc.Proc {
        if (!self.loaded.hasPerm(.proc)) return error.PermissionDenied;
        return proc.Proc.spawn(self.host.ctx.gpa, self.host.ctx.buffers.pool, argv, opts);
    }

    /// Open a TCP socket. Perm: net. (TLS via `net.TlsSock` over the Sock.)
    pub fn connect(self: *Abi, hostport: []const u8) !net.Sock {
        if (!self.loaded.hasPerm(.net)) return error.PermissionDenied;
        return net.Sock.connect(self.host.ctx.gpa, hostport);
    }

    /// Claim a subbuffer (an anchored range with its own facts) on the
    /// active document. Admin — no perm; it is local, reversible bookkeeping.
    pub fn claimSubbuffer(self: *Abi, range: Document.Range) EffectError!*subbuffer.SubBuffer {
        const subs = self.host.services.subbuffers orelse return error.Unavailable;
        const ed = self.host.ctx.editor();
        return subs.claim(self.host.ctx.gpa, &ed.doc, range);
    }

    /// Run `work(gpa, input)` off-thread; when it returns bytes, insert them
    /// on the FRAME thread at the cursor position captured now — REBASED
    /// through whatever landed meanwhile (or discarded if that version is
    /// gone), authored as this plugin's peer and grade-gated. The clean
    /// pattern for every subprocess/network plugin: compute off-frame, edit
    /// on-frame, no blocking poll. `input` is copied (owned for the task's
    /// life). Perm: timer (the async loop). Returns the task id (cancelable).
    pub fn editLater(self: *Abi, work: DeferredWork, input: []const u8) EffectError!async_loop.Id {
        if (!self.loaded.hasPerm(.timer)) return error.PermissionDenied;
        const loop = self.host.services.loop orelse return error.Unavailable;
        const gpa = self.host.ctx.gpa;
        const doc = self.host.ctx.document();
        const d = try gpa.create(DeferredEdit);
        errdefer gpa.destroy(d);
        d.* = .{
            .host = self.host,
            .name = try gpa.dupe(u8, self.loaded.manifest.name),
            .version = try doc.version(gpa),
            .offset = self.host.ctx.editor().cursorOffset(),
            .input = try gpa.dupe(u8, input),
            .work = work,
        };
        errdefer {
            gpa.free(d.name);
            gpa.free(d.version);
            gpa.free(d.input);
        }
        return loop.spawn(deferredWork, d, .{ .ctx = d, .call = deliverEdit, .deinit = freeDeferred });
    }
};

/// Off-thread work for `editLater`: `input` in, owned output bytes out.
pub const DeferredWork = *const fn (gpa: Allocator, input: []const u8) anyerror![]u8;

/// A deferred edit's captured target, owned across the frame→pool→frame
/// hop. Freed in every terminal case by the sink's `deinit`.
const DeferredEdit = struct {
    host: *Host,
    name: []u8,
    version: []u8, // the version `offset` is stamped against
    offset: usize,
    input: []u8,
    work: DeferredWork,
};

/// Caps trampoline for a plugin completion provider: build candidates via
/// the plugin's handler, push them (the host deep-copies + re-stamps), then
/// free the plugin's owned strings.
fn completionProvider(data: ?*anyopaque, caps: *capability.Caps, req: *const capability.Request) anyerror!void {
    const bp: *BoundProvider = @ptrCast(@alignCast(data.?));
    if (req.kind != .completion) {
        caps.decline(req.session);
        return;
    }
    const gpa = bp.loaded.host.ctx.gpa;
    var abi: Abi = .{ .host = bp.loaded.host, .loaded = bp.loaded };
    var out: std.ArrayList([]const u8) = .empty;
    defer {
        for (out.items) |s| gpa.free(s);
        out.deinit(gpa);
    }
    bp.completion(&abi, req.text, &out) catch {
        caps.decline(req.session);
        return;
    };
    var items: std.ArrayList(capability.CompletionItem) = .empty;
    defer items.deinit(gpa);
    for (out.items, 0..) |txt, i| {
        try items.append(gpa, .{ .text = @constCast(txt), .rank = @intCast(i) });
    }
    try caps.push(req.session, .{ .id = bp.id, .latency = .instant }, .{ .completion = items.items });
}

fn deferredWork(gpa: Allocator, ctx: ?*anyopaque) anyerror![]u8 {
    const d: *DeferredEdit = @ptrCast(@alignCast(ctx.?));
    return d.work(gpa, d.input);
}

/// Frame-thread delivery: rebase the captured position and insert as the
/// plugin peer (grade-gated). A dead version or a view grade drops silently
/// — the honest degrade, never a ghost.
fn deliverEdit(ctx: ?*anyopaque, result: ?[]const u8) void {
    const d: *DeferredEdit = @ptrCast(@alignCast(ctx.?));
    const bytes = result orelse return;
    const gpa = d.host.ctx.gpa;
    const doc = d.host.ctx.document();
    if (!authority.gradeMin(doc.my_grant, .edit).canEdit()) return;
    const at = position.rebaseOffset(doc, d.version, d.offset, .right) orelse return;
    const pid = doc.peerNamed(gpa, d.name) catch return;
    doc.peerReplaceAll(gpa, pid, &.{.{ .range = .{ .start = at, .end = at }, .bytes = bytes }}) catch {};
}

fn freeDeferred(ctx: ?*anyopaque) void {
    const d: *DeferredEdit = @ptrCast(@alignCast(ctx.?));
    const gpa = d.host.ctx.gpa;
    gpa.free(d.name);
    gpa.free(d.version);
    gpa.free(d.input);
    gpa.destroy(d);
}

/// A stable owner fingerprint from a plugin name — the total-ordering
/// tie-breaker for equal-priority contributions (in-process stand-in for
/// the real 24-byte identity fingerprint the wasm loader will carry).
fn ownerFingerprint(name: []const u8) [24]u8 {
    var out: [24]u8 = @splat(0);
    var h = std.hash.Fnv1a_64.hash(name);
    for (0..8) |i| {
        out[i] = @truncate(h);
        h >>= 8;
    }
    return out;
}

fn pickAccept(ctx: *command.Context, data: ?*anyopaque, choice: []const u8) anyerror!void {
    _ = ctx;
    const bp: *BoundPick = @ptrCast(@alignCast(data.?));
    var abi: Abi = .{ .host = bp.loaded.host, .loaded = bp.loaded };
    return bp.accept(&abi, choice);
}

fn pickCleanup(data: ?*anyopaque, gpa: Allocator) void {
    const bp: *BoundPick = @ptrCast(@alignCast(data.?));
    gpa.destroy(bp);
}

/// The registry trampoline: recover the bound plugin, install its principal,
/// run its handler under the ABI facade.
fn trampoline(ctx: *command.Context, data: ?*anyopaque, args: []const Value) anyerror!Value {
    _ = ctx;
    const b: *Bound = @ptrCast(@alignCast(data.?));
    var abi: Abi = .{ .host = b.loaded.host, .loaded = b.loaded };
    return b.handler(&abi, args);
}

// ── Tests ───────────────────────────────────────────────────────────

const t = std.testing;

const TestCtx = struct {
    gpa: Allocator,
    pool: *@import("task.zig").Pool,
    buffers: @import("Buffers.zig"),
    commands: command.Commands,
    keymap: @import("Keymap.zig"),
    pick: @import("pick.zig").Pick,
    caps: capability.Caps,
    quit: bool,
    echo: std.ArrayList(u8),
    ctx: command.Context,

    fn init(gpa: Allocator, self: *TestCtx) !void {
        self.pool = try @import("task.zig").Pool.init(gpa, .{ .threads = 1 });
        self.buffers = try @import("Buffers.zig").init(gpa, self.pool, "user");
        self.commands = .empty;
        self.keymap = .empty;
        self.pick = .empty;
        self.caps = capability.Caps.init(gpa, @import("task.zig").nowNs);
        self.quit = false;
        self.echo = .empty;
        self.ctx = .{
            .gpa = gpa,
            .buffers = &self.buffers,
            .commands = &self.commands,
            .keymap = &self.keymap,
            .pick = &self.pick,
            .caps = &self.caps,
            .quit = &self.quit,
            .echo = &self.echo,
        };
    }
    fn deinit(self: *TestCtx, gpa: Allocator) void {
        self.caps.deinit();
        self.pick.deinit(gpa);
        self.keymap.deinit(gpa);
        self.commands.deinit(gpa);
        self.echo.deinit(gpa);
        self.buffers.deinit(gpa);
        self.pool.deinit();
    }
};

// Two plugins. `alpha` provides "greet" and edits; `beta` also provides
// "greet" (a late-bound shadow) plus "bye".
fn alphaDescribe() Manifest {
    return .{ .name = "alpha", .commands = &.{.{ .name = "greet" }} };
}
fn alphaInit(abi: *Abi) anyerror!void {
    try abi.registerCommand("greet", alphaGreet);
}
fn alphaGreet(abi: *Abi, args: []const Value) anyerror!Value {
    _ = args;
    // Author an edit as the plugin peer (proves the write door + principal).
    try abi.edit(.{ .start = 0, .end = 0 }, "A");
    return .{ .string = "alpha" };
}

fn betaDescribe() Manifest {
    return .{ .name = "beta", .commands = &.{ .{ .name = "greet" }, .{ .name = "bye" } } };
}
fn betaInit(abi: *Abi) anyerror!void {
    try abi.registerCommand("greet", betaGreet);
    try abi.registerCommand("bye", betaGreet);
}
fn betaGreet(abi: *Abi, args: []const Value) anyerror!Value {
    _ = abi;
    _ = args;
    return .{ .string = "beta" };
}

// A plugin that registers a command it did not declare — must fail to load.
fn roeDescribe() Manifest {
    return .{ .name = "rogue", .commands = &.{.{ .name = "declared" }} };
}
fn rogueInit(abi: *Abi) anyerror!void {
    try abi.registerCommand("undeclared", betaGreet); // not in the manifest
}

test "abi: two plugins register; a late-bound name shadows; teardown is clean" {
    const gpa = t.allocator;
    var env: TestCtx = undefined;
    try TestCtx.init(gpa, &env);
    defer env.deinit(gpa);

    var host = Host.init(&env.ctx, .{});
    defer host.deinit();

    try host.load(.{ .describe = alphaDescribe, .init = alphaInit });
    // alpha's "greet" resolves and authors as alpha's peer.
    const r1 = try command.run(&env.commands, &env.ctx, "greet", &.{});
    try t.expectEqualStrings("alpha", r1.string);
    try t.expect(env.buffers.active().editor.text().byteLen() == 1);

    // beta shadows "greet" (late binding — newest wins) and adds "bye".
    try host.load(.{ .describe = betaDescribe, .init = betaInit });
    const r2 = try command.run(&env.commands, &env.ctx, "greet", &.{});
    try t.expectEqualStrings("beta", r2.string);
    const r3 = try command.run(&env.commands, &env.ctx, "bye", &.{});
    try t.expectEqualStrings("beta", r3.string);

    // Teardown is clean (newest-first): every binding this host made is
    // unbound, and a torn-down shadow never clobbers a still-live owner.
    host.deinit();
    host = Host.init(&env.ctx, .{});
    // Fresh load of alpha rebinds "greet"; beta's "bye" stayed gone.
    try host.load(.{ .describe = alphaDescribe, .init = alphaInit });
    const r4 = try command.run(&env.commands, &env.ctx, "greet", &.{});
    try t.expectEqualStrings("alpha", r4.string);
    // beta's "bye" is unbound (resolve is null; the interned name may linger).
    try t.expect(env.commands.resolve("bye") == null);
}

test "abi: a plugin registering an undeclared command fails to load" {
    const gpa = t.allocator;
    var env: TestCtx = undefined;
    try TestCtx.init(gpa, &env);
    defer env.deinit(gpa);

    var host = Host.init(&env.ctx, .{});
    defer host.deinit();

    try t.expectError(error.UndeclaredCommand, host.load(.{ .describe = roeDescribe, .init = rogueInit }));
    // The failed load left nothing behind: no plugin, no "undeclared" command.
    try t.expectEqual(@as(usize, 0), host.plugins.items.len);
    try t.expect(env.commands.resolve("undeclared") == null);
}

test "abi: kv service round-trips, namespaced by plugin" {
    const gpa = t.allocator;
    var env: TestCtx = undefined;
    try TestCtx.init(gpa, &env);
    defer env.deinit(gpa);
    var store: kv.Store = .empty;
    defer store.deinit(gpa);

    var host = Host.init(&env.ctx, .{ .kv = &store });
    defer host.deinit();
    try host.load(.{ .describe = alphaDescribe, .init = alphaInit });

    var abi: Abi = .{ .host = &host, .loaded = host.plugins.items[0] };
    try abi.kvPut("k", "v");
    try t.expectEqualStrings("v", abi.kvGet("k").?);
    // Namespaced: another plugin's store sees nothing under "alpha".
    try t.expectEqual(@as(?[]const u8, null), store.get("other", "k"));
}

fn langDescribe() Manifest {
    return .{
        .name = "lang.rust",
        .activations = &.{.{ .predicate = .{ .ext = ".rs" }, .kind = .keymap_layer, .tag = 7 }},
    };
}
fn langInit(abi: *Abi) anyerror!void {
    _ = abi; // a real plugin would bind its keymap layer here, keyed by tag
}

test "abi: a declared activation reconciles by predicate and reverses on unload" {
    const gpa = t.allocator;
    var env: TestCtx = undefined;
    try TestCtx.init(gpa, &env);
    defer env.deinit(gpa);

    var host = Host.init(&env.ctx, .{});
    defer host.deinit();
    try host.load(.{ .describe = langDescribe, .init = langInit });

    var act: std.ArrayList(u32) = .empty;
    defer act.deinit(gpa);
    var deact: std.ArrayList(u32) = .empty;
    defer deact.deinit(gpa);

    // A .rs buffer activates the contribution; activationOf maps it back to
    // the plugin + its tag so the host knows what to apply.
    try host.reconcile(1, .{ .locality = .local, .path = "main.rs" }, &act, &deact);
    try t.expectEqual(@as(usize, 1), act.items.len);
    const who = host.activationOf(act.items[0]).?;
    try t.expectEqualStrings("lang.rust", who.name);
    try t.expectEqual(@as(u32, 7), who.tag);

    // Retag the buffer to .zig: the contribution deactivates (reversible).
    act.clearRetainingCapacity();
    deact.clearRetainingCapacity();
    try host.reconcile(1, .{ .locality = .local, .path = "main.zig" }, &act, &deact);
    try t.expectEqual(@as(usize, 0), act.items.len);
    try t.expectEqual(@as(usize, 1), deact.items.len);
}

// A realistic catalog-shaped plugin (design §6): declares a command + an
// activation, and on invocation authors an edit (Group C), publishes an
// annotation into its own layer (Group C), and persists state (Group E) —
// exercising the whole ABI the way a real plugin does.
fn noteDescribe() Manifest {
    return .{
        .name = "project.notes",
        .commands = &.{.{ .name = "note-here" }},
        .activations = &.{.{ .predicate = .{ .any = &.{ .{ .ext = ".zig" }, .{ .ext = ".rs" } } }, .kind = .capability, .tag = 1 }},
    };
}
fn noteInit(abi: *Abi) anyerror!void {
    try abi.registerCommand("note-here", noteHere);
}
fn noteHere(abi: *Abi, args: []const Value) anyerror!Value {
    _ = args;
    const off = abi.cursor();
    try abi.edit(.{ .start = off, .end = off }, "// NOTE\n"); // author as the plugin peer
    const layer = try abi.claimLayer("notes", .local);
    try layer.publishSpans(abi.host.ctx.gpa, &.{.{ .start = off, .end = off, .kind = 1, .message = "note", .placement = .gutter }});
    try abi.kvPut("last", "note-here");
    return .{ .integer = @intCast(layer.spanCount()) };
}

test "abi: a catalog-shaped plugin drives edit + layer + kv through one door" {
    const gpa = t.allocator;
    var env: TestCtx = undefined;
    try TestCtx.init(gpa, &env);
    defer env.deinit(gpa);
    var store: kv.Store = .empty;
    defer store.deinit(gpa);

    var host = Host.init(&env.ctx, .{ .kv = &store });
    defer host.deinit();
    try host.load(.{ .describe = noteDescribe, .init = noteInit });

    const r = try command.run(&env.commands, &env.ctx, "note-here", &.{});
    try t.expectEqual(Value{ .integer = 1 }, r); // one gutter span published
    // The edit landed, authored by the plugin peer (not the user).
    const doc = &env.buffers.active().editor.doc;
    try t.expect(doc.text().byteLen() == "// NOTE\n".len);
    try t.expect(doc.commitAt(doc.commitCount() - 1).author != .user);
    // State persisted, namespaced to the plugin.
    try t.expectEqualStrings("note-here", store.get("project.notes", "last").?);
    // The activation matches .zig buffers.
    var act: std.ArrayList(u32) = .empty;
    defer act.deinit(gpa);
    var deact: std.ArrayList(u32) = .empty;
    defer deact.deinit(gpa);
    try host.reconcile(1, .{ .path = "x.zig" }, &act, &deact);
    try t.expectEqual(@as(usize, 1), act.items.len);
}

fn procDescribe() Manifest {
    return .{ .name = "runner", .perms = &.{.proc}, .commands = &.{.{ .name = "run" }} };
}
fn noPermDescribe() Manifest {
    return .{ .name = "noperm", .commands = &.{.{ .name = "run" }} }; // no .proc
}
fn procInit(abi: *Abi) anyerror!void {
    try abi.registerCommand("run", procRun);
}
fn procRun(abi: *Abi, args: []const Value) anyerror!Value {
    _ = args;
    var p = try abi.spawnProc(&.{ "/bin/sh", "-c", "printf ok" }, .{});
    defer p.deinit();
    var rounds: usize = 0;
    while (rounds < 5_000_000) : (rounds += 1) {
        if (p.poll()) |outcome| {
            var res = try outcome;
            defer res.deinit(abi.host.ctx.gpa);
            return .{ .string = if (res.succeeded()) "ok" else "fail" };
        }
        std.Thread.yield() catch {};
    }
    return .{ .string = "timeout" };
}

test "abi: Group D effects are gated by declared perms" {
    const gpa = t.allocator;
    var env: TestCtx = undefined;
    try TestCtx.init(gpa, &env);
    defer env.deinit(gpa);

    var host = Host.init(&env.ctx, .{});
    defer host.deinit();

    // With the .proc perm declared, spawnProc runs a real child.
    try host.load(.{ .describe = procDescribe, .init = procInit });
    const r = try command.run(&env.commands, &env.ctx, "run", &.{});
    try t.expectEqualStrings("ok", r.string);

    // A plugin that did NOT declare .proc is refused at the ABI door — the
    // perm model enforced in process. Use it directly to check the gate.
    try host.load(.{ .describe = noPermDescribe, .init = procInit });
    var abi: Abi = .{ .host = &host, .loaded = host.plugins.items[1] };
    try t.expectError(error.PermissionDenied, abi.spawnProc(&.{"/bin/true"}, .{}));
}

fn deferDescribe() Manifest {
    return .{ .name = "defer", .perms = &.{.timer}, .commands = &.{.{ .name = "stamp" }} };
}
fn deferInit(abi: *Abi) anyerror!void {
    try abi.registerCommand("stamp", stampCmd);
}
fn stampCmd(abi: *Abi, args: []const Value) anyerror!Value {
    _ = args;
    const gpa = abi.host.ctx.gpa;
    const text = try abi.slice(gpa, 0, abi.byteLen());
    defer gpa.free(text);
    _ = try abi.editLater(upcaseWork, text);
    return .nil;
}
fn upcaseWork(gpa: Allocator, input: []const u8) anyerror![]u8 {
    const out = try gpa.alloc(u8, input.len);
    for (input, out) |c, *o| o.* = std.ascii.toUpper(c);
    return out;
}

test "abi: editLater computes off-thread and edits on-frame, rebased" {
    const gpa = t.allocator;
    var env: TestCtx = undefined;
    try TestCtx.init(gpa, &env);
    defer env.deinit(gpa);
    var loop = async_loop.Loop.init(gpa, env.pool, @import("task.zig").nowNs);
    defer loop.deinit();

    var host = Host.init(&env.ctx, .{ .loop = &loop });
    defer host.deinit();
    try host.load(.{ .describe = deferDescribe, .init = deferInit });

    const ed = &env.buffers.active().editor;
    try ed.insertText(gpa, "abc");
    ed.placeCursor(3); // capture the stamp at offset 3 (end of "abc")
    _ = try command.run(&env.commands, &env.ctx, "stamp", &.{});

    // Concurrently insert "XX" at the head: the deferred edit's stamped
    // offset (3) must rebase to 5 before its output lands.
    ed.placeCursor(0);
    try ed.insertText(gpa, "XX"); // doc → "XXabc"

    // Drive the loop until the deferred edit delivers (bounded).
    var rounds: usize = 0;
    while (ed.text().byteLen() < 8 and rounds < 5_000_000) : (rounds += 1) {
        _ = loop.tick();
        std.Thread.yield() catch {};
    }
    const s = try ed.text().toOwnedSlice(gpa);
    defer gpa.free(s);
    // "ABC" (async-upcased "abc") landed at the REBASED offset 5, not 3.
    try t.expectEqualStrings("XXabcABC", s);
    const doc = &ed.doc;
    try t.expect(doc.commitAt(doc.commitCount() - 1).author != .user); // the plugin peer
}

// Authority invariants (plan 01), now proven through the Zig ABI instead of
// the removed Lua bridge: a plugin's edits author as ITS peer (not the
// user), survive the user's selective undo, are refused on a view-grade doc,
// and re-resolve the peer against the ACTIVE document after a buffer switch.
fn authDescribe() Manifest {
    return .{ .name = "auth", .commands = &.{.{ .name = "ins" }} };
}
fn authInit(abi: *Abi) anyerror!void {
    try abi.registerCommand("ins", authIns);
}
fn authIns(abi: *Abi, args: []const Value) anyerror!Value {
    if (args.len >= 1 and args[0] == .string) {
        const off = abi.cursor();
        abi.edit(.{ .start = off, .end = off }, args[0].string) catch |e| {
            if (e == error.Unauthorized) return .nil; // view grade: no ghost
            return e;
        };
    }
    return .nil;
}

test "abi authority: plugin edits author as its peer; user undo spares them; view refuses" {
    const gpa = t.allocator;
    var env: TestCtx = undefined;
    try TestCtx.init(gpa, &env);
    defer env.deinit(gpa);
    var host = Host.init(&env.ctx, .{});
    defer host.deinit();
    try host.load(.{ .describe = authDescribe, .init = authInit });

    _ = try command.run(&env.commands, &env.ctx, "ins", &.{.{ .string = "hi" }});
    const ed = &env.buffers.active().editor;
    try t.expect(ed.doc.commitAt(ed.doc.commitCount() - 1).author != .user); // the plugin peer
    try t.expect(!try ed.undo(gpa)); // the user's undo does not touch it
    try t.expect(ed.text().byteLen() == 2);

    // A view-grade document refuses the plugin's edit — no ghost, no error.
    ed.doc.my_grant = .view;
    _ = try command.run(&env.commands, &env.ctx, "ins", &.{.{ .string = "X" }});
    try t.expect(ed.text().byteLen() == 2);
}

test "abi authority: a plugin editing after a buffer switch attributes to the active doc" {
    const gpa = t.allocator;
    var env: TestCtx = undefined;
    try TestCtx.init(gpa, &env);
    defer env.deinit(gpa);
    try @import("builtins.zig").install(gpa, &env.commands, &env.keymap); // buffer-create
    var host = Host.init(&env.ctx, .{});
    defer host.deinit();
    try host.load(.{ .describe = authDescribe, .init = authInit });

    _ = try command.run(&env.commands, &env.ctx, "buffer-create", &.{.{ .string = "b" }});
    _ = try command.run(&env.commands, &env.ctx, "ins", &.{.{ .string = "hi" }});
    const doc = env.ctx.document();
    const s = try doc.text().toOwnedSlice(gpa);
    defer gpa.free(s);
    try t.expectEqualStrings("hi", s);
    try t.expect(doc.commitAt(doc.commitCount() - 1).author != .user);
    try t.expectEqual(@as(usize, 0), env.buffers.get(0).?.editor.text().byteLen());
}

test {
    std.testing.refAllDecls(@This());
}
