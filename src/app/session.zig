//! `Session` — `main()`'s APP GLUE for the ONE hosted `core.System` the
//! desktop binary runs today (doc/cwa-prior-docs-audit.md §5,
//! "Session-on-System"): the one `Head` this process drives (its
//! mode/pending/pick/echo), the which-key menu-overlay
//! tracker beside it, the capability-consumer UIs (completion, definition,
//! symbols, hover), the caret config, and the self-referential `cmd_ctx`
//! dozens of `main.zig`/`app/*.zig` call sites hold a pointer to.
//!
//! **The bundle fields (buffers/commands/keymap/caps/actions/quit/
//! container/config_kv) live on `system` now, not on `Session` itself** —
//! see `core/System.zig`'s module doc for the full reasoning this
//! completes: `System.create` heap-pins the bundle (`*System`, never
//! relocated), so `cmd_ctx`'s system-scoped pointers can be REPOINTED in place
//! by `core.System.Host.swap` instead of dangling on a move. `host` hosts
//! every system this process knows about (today: "editor", and — if
//! `config/agent-ux.js` is present — "agent-ux"); `system` is a convenience
//! alias for whichever one `cmd_ctx` currently targets, kept in sync by
//! `rebindSystem` below. Reaching a bundle field is mechanical:
//! `session.buffers` (old) → `session.system.buffers` (now) — Zig has no
//! field aliasing, so every call site that used to read a `Session` bundle
//! field directly was updated to go through `.system.` (`main.zig`,
//! `e2e/harness.zig`, `e2e/teardown_test.zig` — the only three files that
//! ever did; see the borrow-audit table in the task report for the rest of
//! `main.zig`'s ~30 wired subsystems, which borrow SPECIFIC pointers taken
//! from those fields at wiring time, not `Session`/`System` itself).
//!
//! `init` builds `head`/`menu_overlay`/`cmd_ctx`/the capability-consumer UIs
//! IN PLACE (`self` already at its final address in `main()`'s frame), so
//! `cmd_ctx`'s `&self.field`/`&self.system.field` borrows never dangle.
//! `deinit` frees in the exact reverse order `main()`'s defers used to run.
//!
//! The grammar/LSP registries (`grammars`, `lsp_servers`) that the capability
//! consumers' `grammar-add`/`lsp-add` bind onto live in `Providers`; `init`
//! borrows them by pointer to wire those two commands. `which_key_now` (the
//! F1 flag the dispatch path reads) lives on `menu_overlay` below, not a
//! separate `main()` local — see `frame.MenuOverlay`'s field doc for why.

const std = @import("std");
const core = @import("../core/core.zig");
const cursor_config = @import("cursor_config.zig");
const providers = @import("providers.zig");
const setup = @import("setup.zig");
const frame = @import("frame.zig");
const ui_mesh = @import("../gfx/view.zig").ui_mesh;
const fs_platform = @import("weft_fs_platform");
const fs = @import("weft_fs");
const fs_runtime = @import("weft_fs_runtime");
const semantic = @import("weft_semantic");
const target_runtime = @import("weft_target_runtime");

pub const Session = struct {
    gpa: std.mem.Allocator,

    // ── The hosted System(s) (task #19 item 1) ──
    /// The container-level registry (section 2.7): every `core.System` this
    /// process hosts, owned here. `deinit` tears every one of them down
    /// (their buffers/commands/keymap/caps/actions/container/config_kv/
    /// plugins — see `System.destroy`'s doc for the exact per-system
    /// teardown order).
    host: core.System.Host,
    /// Whichever hosted system `cmd_ctx` currently targets — a convenience
    /// alias, NOT the source of truth (`host.systemOf(&self.cmd_ctx)` would
    /// answer the same question by address identity off `cmd_ctx` itself).
    /// Kept in sync by `rebindSystem` so app code that wants "the active
    /// system's X" reads naturally (`session.system.buffers`).
    system: *core.System,

    /// Concrete local filesystem mechanism selected by build.zig. The System
    /// owns only the generic router; this app-owned storage can be replaced by
    /// a Darwin provider without changing core or plugins.
    filesystem_provider: fs_platform.Provider,
    /// App-owned local directory roots and their trusted semantic
    /// publications. Core sees only ordinary targets and the generic
    /// filesystem router; the build-selected platform provider remains here.
    directory_targets: std.ArrayList(DirectoryTarget) = .empty,
    file_targets: std.ArrayList(FileTarget) = .empty,
    filesystem_system: *core.System,
    filesystem_owner: semantic.owner.Id,
    filesystem_relations: LocalDirectoryRelations,
    // ── This process's one head (doc/cwa-prior-docs-audit.md §5) — APP
    //    GLUE, not a System field: a head is a cursor INTO whichever system
    //    it's attached to, so it survives a swap unchanged (see
    //    `rebindSystem`).
    head: core.Head,
    /// This head's which-key menu-overlay edge tracker (open/shown/forced/
    /// open_ns) — app-layer state that can't live ON `core.Head` (see
    /// `frame.MenuOverlay`'s doc), but is exactly as per-head as `head`
    /// itself; `Session` is the nearest thing to a "per-head bundle" the app
    /// has today, so it lives here beside it (doc/cwa-prior-docs-audit.md §5
    /// W2a-2). A second head (the e2e two-head gate) pairs its own instance
    /// the same way, alongside its own ad hoc `Head`.
    menu_overlay: frame.MenuOverlay,
    /// Self-referential: `system.contextFor(&self.head)` at build time —
    /// repointed IN PLACE (not rebuilt) by `rebindSystem`/`Host.swap`, so
    /// every OTHER holder of `&self.cmd_ctx` sees the new system from its
    /// next read on, exactly like `core/System.zig`'s own gate tests.
    cmd_ctx: core.command.Context,

    // ── Capability-consumer UIs (written against capability names only) ──
    completion_ui: core.complete_ui.CompletionUi,

    // ── Caret / which-key config (set declaratively by config at load time) ──
    cursor_cfg: cursor_config.CursorConfig,

    /// Build the app glue IN PLACE (`self` is already at its final address in
    /// `main()`'s frame), so `cmd_ctx`'s borrows never dangle. Hosts a fresh
    /// "editor" `core.System` (buffers/commands/keymap/caps/actions/
    /// container/config_kv + the built-in command/keymap floor — see
    /// `System.create`), then binds the capability consumers (which also
    /// wire `grammar-add` onto the caller-owned `grammars` registry) and the
    /// caret/which-key commands — in registration order.
    pub fn init(
        self: *Session,
        gpa: std.mem.Allocator,
        pool: *core.task.Pool,
        user: []const u8,
        grammars: *core.syntax.Runtime,
    ) !void {
        self.gpa = gpa;
        self.filesystem_provider = fs_platform.Provider.init(gpa);
        self.directory_targets = .empty;
        self.file_targets = .empty;
        errdefer self.filesystem_provider.deinit();
        self.host = core.System.Host.init(gpa);
        errdefer self.host.deinit();
        const sys = try core.System.create(gpa, pool, "editor", user);
        errdefer sys.destroy();
        try self.host.hostSystem(sys);
        self.system = sys;
        self.filesystem_system = sys;
        try self.system.filesystems.register(.here, self.filesystem_provider.provider());
        self.filesystem_owner = try self.system.semantic.acquireOwner();
        errdefer _ = self.system.semantic.releaseOwner(gpa, self.filesystem_owner);
        self.filesystem_relations = .{ .session = self };
        _ = try self.system.semantic.registerTargetRelationProvider(
            gpa,
            self.filesystem_owner,
            "local-filesystem.relations",
            .init(&self.filesystem_relations),
        );
        self.head = .empty;
        // `System.create`'s `builtins.install` already set `sys.default_head`
        // into the modeless floor's "default" mode (the headless dispatch
        // target needs one immediately — see `System.create`'s doc); THIS
        // head is the one the desktop actually drives, so it starts there
        // too — mirroring exactly what the old direct
        // `core.builtins.install(..., &self.head, ...)` call used to do
        // before `System.create` took over installing the builtins.
        // mechanism-not-policy (task #19 item 3): session bootstrap, before
        // `self.cmd_ctx` (built two lines below) exists to capture a `Ctx`
        // from.
        try self.head.setModeRaw(gpa, self.system.default_head.currentMode());
        self.menu_overlay = .{};
        self.cmd_ctx = self.system.contextFor(&self.head);
        self.cmd_ctx.entries = .{ .context = self, .open = openWorkspaceEntryOpaque };
        // This session opened the roots, so it is the only party entitled to
        // say what they are called (`doc/place.md` §2.3).
        self.cmd_ctx.realizer = self.realizer();
        try ui_mesh.declareSlots(&self.system.container);
        try ui_mesh.bindDefaultStatusline(&self.system.container);
        // Capability consumers — written against capability names only.
        self.completion_ui = .empty;
        try setup.registerCapabilityConsumers(gpa, &self.system.commands, &self.completion_ui, grammars);
        // Caret config commands, registered before the config runs so it can
        // set per-mode styles at load time.
        self.cursor_cfg = .{ .gpa = gpa };
        try setup.registerCursorCommands(gpa, &self.system.commands, &self.cursor_cfg, &self.menu_overlay.which_key_now);
    }

    /// Free in the exact reverse order `main()`'s defers used to run:
    /// cursor_cfg, head (echo+pick), then every hosted system (`host.deinit`
    /// — buffers/caps/keymap/commands/plugins/..., per-system, in
    /// `System.destroy`'s documented order). (completion_ui owns no heap.)
    pub fn deinit(self: *Session, gpa: std.mem.Allocator) void {
        // Cancellation is plugin code and may dispatch through any registered
        // service. Terminate before releasing even the first callback-visible
        // target; layered owners may call this idempotently.
        self.head.pick.terminate(&self.cmd_ctx);
        while (self.directory_targets.items.len != 0)
            self.closeDirectoryTarget(self.directory_targets.items.len - 1);
        self.directory_targets.deinit(gpa);
        while (self.file_targets.items.len != 0)
            self.closeFileTarget(self.file_targets.items.len - 1);
        self.file_targets.deinit(gpa);
        _ = self.filesystem_system.semantic.releaseOwner(gpa, self.filesystem_owner);
        self.cursor_cfg.deinit();
        self.head.deinit(gpa);
        self.host.deinit();
        self.filesystem_provider.deinit();
    }

    /// Classify and open a local directory through the same semantic target
    /// resolver every other locus uses. `false` means the platform provider
    /// did not classify the path as a directory, so an app shell may continue
    /// with its ordinary file-opening behavior.
    /// Find-or-publish the directory container for `path`, optionally focusing
    /// it. Returns null when `path` is not an openable directory.
    ///
    /// The `focus` parameter exists because a PLACE needs this container
    /// without displaying it: opening a file has to resolve the project the
    /// file sits in (`doc/place.md`) and must not steal the view to do it. The
    /// publication transaction, including its rollback, is identical either
    /// way — which is why this is a parameter rather than a second copy of the
    /// dedupe logic that would be free to drift.
    fn ensureLocalDirectory(self: *Session, ctx: *core.command.Context, path: []const u8, focus: bool) anyerror!?semantic.target.Located {
        const system = self.filesystem_system;
        if (ctx.semantic != &system.semantic or ctx.filesystems != &system.filesystems)
            return error.SemanticUnavailable;

        const resolved_path = try std.fs.path.resolve(ctx.gpa, &.{path});
        defer ctx.gpa.free(resolved_path);

        // Resolve the path at the authority boundary before deduplication.
        // Reusing an old publication before this check would mistake a
        // replacement at a renamed path for the originally pinned object.
        const root = self.filesystem_provider.acquireRoot(resolved_path) catch |err| return switch (err) {
            error.NotFound, error.NotDirectory, error.Unsupported => null,
            else => err,
        };
        var root_owned = true;
        errdefer if (root_owned) self.filesystem_provider.releaseRoot(root);

        var index: usize = 0;
        while (index < self.directory_targets.items.len) : (index += 1) {
            const existing = &self.directory_targets.items[index];
            // Compare the provider-owned directory identities, not lexical
            // paths or opaque root slots. A path may have been renamed and
            // replaced between opens; only the same pinned object is eligible
            // for deduplication. This also naturally deduplicates a parent
            // first reached through `-` and later opened by path.
            const same_root = system.filesystems.sameRoot(existing.root, root) catch |err| switch (err) {
                error.Stale => false,
                else => return err,
            };
            if (!same_root) continue;
            const descriptor = system.semantic.targets.get(existing.publication.ref);
            if (descriptor == null or descriptor.?.revision != existing.publication.revision) {
                self.closeDirectoryTarget(index);
                break;
            }
            _ = system.filesystems.authorizedDirectory(existing.publication.ref, existing.publication.revision) catch {
                self.closeDirectoryTarget(index);
                break;
            };
            self.filesystem_provider.releaseRoot(root);
            root_owned = false;
            // Read the identity out before focusing: `existing` points into a
            // list focusing is entitled to append to.
            const located: semantic.target.Located = .{
                .target = existing.publication.ref,
                .revision = existing.publication.revision,
            };
            if (focus) try focusDirectoryTarget(ctx, located.target);
            return located;
        }

        try self.directory_targets.ensureUnusedCapacity(ctx.gpa, 1);
        const owned_path = try ctx.gpa.dupe(u8, resolved_path);
        var path_owned = true;
        errdefer if (path_owned) ctx.gpa.free(owned_path);
        var publication = try fs_runtime.publication.publish(
            ctx.gpa,
            &system.semantic.targets,
            &system.filesystems,
            self.filesystem_owner,
            .{ .display_name = resolved_path, .directory = .{ .root = root } },
        );
        var publication_owned = true;
        errdefer {
            if (publication_owned)
                _ = publication.close(ctx.gpa, &system.semantic.targets, &system.filesystems);
        }
        const first_new_target = self.directory_targets.items.len;
        self.directory_targets.appendAssumeCapacity(.{
            .path = owned_path,
            .root = root,
            .publication = publication,
        });
        root_owned = false;
        path_owned = false;
        publication_owned = false;
        // Opening the target may synchronously query its `container` relation,
        // which lazily appends pinned ancestors. Roll the whole publication
        // transaction back if handler admission or focus fails.
        errdefer while (self.directory_targets.items.len > first_new_target)
            self.closeDirectoryTarget(self.directory_targets.items.len - 1);
        if (focus) try focusDirectoryTarget(ctx, publication.ref);
        return .{ .target = publication.ref, .revision = publication.revision };
    }

    /// Open (and focus) a local directory. The shape `DirectoryOpener` expects.
    pub fn openLocalDirectory(self: *Session, ctx: *core.command.Context, path: []const u8) anyerror!bool {
        return (try self.ensureLocalDirectory(ctx, path, true)) != null;
    }

    // ── Places (doc/place.md) ────────────────────────────────────────

    /// Dominating markers that identify a project root — the VCS top. A
    /// worktree or submodule makes `.git` a FILE rather than a directory, so
    /// mere existence is the test, not "is a dir".
    const project_markers = [_][]const u8{ ".git", ".jj", ".hg", ".svn", ".bzr" };

    /// The nearest ancestor of `path` (a file) holding a project marker, as a
    /// borrowed subslice of `path`. Null when no ancestor has one — an
    /// unmarked file gets no project rather than a guessed one, because
    /// guessing here would silently place an effect in a directory the user
    /// never called a project.
    ///
    /// Blocking filesystem work, and deliberately so: this runs when a file is
    /// OPENED, never on the dispatch path. `Ctx.capture` is provably
    /// non-allocating and could not host this walk even if it wanted to.
    fn projectRootOf(gpa: std.mem.Allocator, path: []const u8) ?[]const u8 {
        var probe: [std.fs.max_path_bytes]u8 = undefined;
        var end = std.mem.lastIndexOfScalar(u8, path, '/') orelse return null;
        while (true) {
            const dir = if (end == 0) "/" else path[0..end];
            for (project_markers) |marker| {
                const base = if (std.mem.eql(u8, dir, "/")) "" else dir;
                const joined = std.fmt.bufPrint(&probe, "{s}/{s}", .{ base, marker }) catch continue;
                if (core.file.statKind(gpa, joined) != .none) return dir;
            }
            if (end == 0) return null;
            end = std.mem.lastIndexOfScalar(u8, path[0..end], '/') orelse 0;
        }
    }

    /// The place a local file at `path` belongs to: its project root published
    /// as a directory container. Null when the file has no project, leaving the
    /// entry on the degenerate `.process` place.
    pub fn placeForFile(self: *Session, ctx: *core.command.Context, path: []const u8) ?core.Place {
        const resolved = std.fs.path.resolve(ctx.gpa, &.{path}) catch return null;
        defer ctx.gpa.free(resolved);
        const root = projectRootOf(ctx.gpa, resolved) orelse return null;
        // Publish WITHOUT focus: resolving where a file lives must not move the
        // user's view to the directory it lives in.
        const located = (self.ensureLocalDirectory(ctx, root, false) catch return null) orelse return null;
        return .{
            .container = .{
                // `.here` while every locus is local. When a remote-attach head
                // carries a real one, this is the line that reads it.
                .locus = .here,
                .ref = located.target,
                .revision = located.revision,
            },
        };
    }

    /// The OS directory a place names, or null when this session is not the
    /// authority for it. The `place.Realizer` contract: bytes are BORROWED
    /// (they belong to the `directory_targets` entry) and the caller must not
    /// retain them.
    ///
    /// Validates the descriptor revision the same way every other consumer of
    /// these publications does, so a republished directory is not silently
    /// answered from a stale retained path.
    pub fn realizePlace(self: *Session, p: core.Place) ?[]const u8 {
        const container = switch (p) {
            .process => return null, // answered by construction, never asked
            .container => |c| c,
        };
        if (container.locus != .here) return null;
        for (self.directory_targets.items) |entry| {
            if (!entry.publication.ref.eql(container.ref)) continue;
            const descriptor = self.filesystem_system.semantic.targets.get(entry.publication.ref) orelse return null;
            if (descriptor.revision != entry.publication.revision) return null;
            return entry.path;
        }
        return null;
    }

    fn realizePlaceOpaque(raw: *anyopaque, p: core.Place) ?[]const u8 {
        const self: *Session = @ptrCast(@alignCast(raw));
        return self.realizePlace(p);
    }

    /// This session as the authority that turns its own places into paths.
    pub fn realizer(self: *Session) core.place.Realizer {
        return .{ .ctx = self, .realizeFn = Session.realizePlaceOpaque };
    }

    pub fn placeForFileOpaque(raw: *anyopaque, ctx: *core.command.Context, path: []const u8) ?core.Place {
        const self: *Session = @ptrCast(@alignCast(raw));
        return self.placeForFile(ctx, path);
    }

    fn ensureDirectoryParent(self: *Session, index: usize) !?semantic.target.Located {
        if (index >= self.directory_targets.items.len) return error.StaleTarget;
        const source = self.directory_targets.items[index];
        const descriptor = self.filesystem_system.semantic.targets.get(source.publication.ref) orelse
            return error.StaleTarget;
        if (descriptor.revision != source.publication.revision) return error.StaleTarget;
        if (source.parent_resolved) {
            const parent = source.parent orelse return null;
            const parent_descriptor = self.filesystem_system.semantic.targets.get(parent) orelse
                return error.StaleTarget;
            return .{ .target = parent, .revision = parent_descriptor.revision };
        }

        const parent_root = try self.filesystem_provider.acquireParent(source.root) orelse {
            self.directory_targets.items[index].parent_resolved = true;
            return null;
        };
        errdefer self.filesystem_provider.releaseRoot(parent_root);

        // A parent may already be retained because another directory was
        // opened through the same relation, or because the user opened its
        // path directly. Reuse that provider-owned identity rather than
        // creating a second target publication for the same object.
        for (self.directory_targets.items) |candidate| {
            const same_root = self.filesystem_system.filesystems.sameRoot(candidate.root, parent_root) catch |err| switch (err) {
                error.Stale => false,
                else => return err,
            };
            if (!same_root) continue;
            self.filesystem_provider.releaseRoot(parent_root);
            self.directory_targets.items[index].parent = candidate.publication.ref;
            self.directory_targets.items[index].parent_resolved = true;
            return candidate.publication.located();
        }

        try self.directory_targets.ensureUnusedCapacity(self.gpa, 1);
        const parent_path = try std.fs.path.resolve(self.gpa, &.{ source.path, ".." });
        errdefer self.gpa.free(parent_path);
        var publication = try fs_runtime.publication.publish(
            self.gpa,
            &self.filesystem_system.semantic.targets,
            &self.filesystem_system.filesystems,
            self.filesystem_owner,
            .{ .display_name = parent_path, .directory = .{ .root = parent_root } },
        );
        errdefer _ = publication.close(
            self.gpa,
            &self.filesystem_system.semantic.targets,
            &self.filesystem_system.filesystems,
        );
        self.directory_targets.appendAssumeCapacity(.{
            .path = parent_path,
            .root = parent_root,
            .publication = publication,
        });
        self.directory_targets.items[index].parent = publication.ref;
        self.directory_targets.items[index].parent_resolved = true;
        return publication.located();
    }

    /// Type-erased callback used by app command composition. The command
    /// layer depends on this behavior interface, not on Session or a concrete
    /// platform filesystem type.
    pub fn openLocalDirectoryOpaque(raw: *anyopaque, ctx: *core.command.Context, path: []const u8) anyerror!bool {
        const self: *Session = @ptrCast(@alignCast(raw));
        return self.openLocalDirectory(ctx, path);
    }

    /// This shell's placement policy (`core.command.EntryOpener`): a local
    /// file target no tool claimed becomes an ordinary editor entry, opened
    /// through the very same `open` a picker or `:e` runs. Activation grants
    /// nothing new — the router must still authorize the exact revision, and
    /// the path is reconstructed from a root this session itself opened, so a
    /// plugin's opaque target never becomes an arbitrary path.
    pub fn openWorkspaceEntry(
        self: *Session,
        ctx: *core.command.Context,
        located: semantic.target.Located,
    ) anyerror!bool {
        if (located.location != .whole) return false;
        const system = self.filesystem_system;
        const descriptor = system.semantic.targets.get(located.target) orelse return false;
        if (descriptor.revision != located.revision or descriptor.kind != .file) return false;
        const entry = system.filesystems.authorizedEntry(located.target, located.revision) catch return false;
        for (self.directory_targets.items) |directory| {
            const same_root = system.filesystems.sameRoot(directory.root, entry.root) catch continue;
            if (!same_root) continue;
            const path = try std.fs.path.join(ctx.gpa, &.{ directory.path, descriptor.display_name });
            defer ctx.gpa.free(path);
            _ = try core.command.run(ctx.commands, ctx, "open", &.{.{ .string = path }});
            return true;
        }
        return false;
    }

    pub fn openWorkspaceEntryOpaque(
        raw: *anyopaque,
        ctx: *core.command.Context,
        located: semantic.target.Located,
    ) anyerror!bool {
        const self: *Session = @ptrCast(@alignCast(raw));
        return self.openWorkspaceEntry(ctx, located);
    }

    fn closeDirectoryTarget(self: *Session, index: usize) void {
        var removed = self.directory_targets.swapRemove(index);
        _ = removed.publication.close(
            self.gpa,
            &self.filesystem_system.semantic.targets,
            &self.filesystem_system.filesystems,
        );
        self.gpa.free(removed.path);
        self.filesystem_provider.releaseRoot(removed.root);
    }

    fn closeFileTarget(self: *Session, index: usize) void {
        var removed = self.file_targets.swapRemove(index);
        _ = removed.publication.close(
            self.gpa,
            &self.filesystem_system.semantic.targets,
            &self.filesystem_system.filesystems,
        );
    }

    /// Delegating facade: the echo line lives on `head` now (doc/cwa-prior-docs-audit.md §5
    /// section 6 W2a-1 moved it out of `Session`'s own storage) — this is
    /// the one spot app-side code says `session.echo()` instead of reaching
    /// into `session.head.echo` directly.
    pub fn echo(self: *Session) *std.ArrayList(u8) {
        return &self.head.echo;
    }

    /// Re-bind `self.head` onto the hosted system named `target` — wraps
    /// `core.System.Host.swap` (which repoints `cmd_ctx`'s system-scoped
    /// table/service pointers in place) and keeps `self.system` in sync so subsequent
    /// `session.system.X` reads see the NEW system. This is the "extend
    /// `Host.swap`" half of task #19 item 1/2: everything `Host.swap`
    /// already refuses (`error.OpenTransient`) or cancels (an open pick) is
    /// unchanged; app-side callers that need to refuse on OTHER grounds
    /// (task #19 item 2's live-collab case) check BEFORE calling this — see
    /// `SwapCmdData`/`systemSwapHandler` below, which is how `main.zig`
    /// wires the actual `system-swap` command so the collab check runs at
    /// COMMAND time, not bind time.
    pub fn rebindSystem(self: *Session, target: []const u8) core.System.Host.SwapError!void {
        try self.host.swap(self.gpa, &self.cmd_ctx, &self.head, target);
        self.system = self.host.systemOf(&self.cmd_ctx) orelse self.system;
        // Dispatch (key -> command -> buffer edit, through `cmd_ctx`) now
        // genuinely targets `target`. The RENDER surface does not yet (task
        // #19's borrow audit — `main.zig`'s `fx`/`win_layout`/collab/
        // providers borrows are baked once at boot, W0b) — named loudly
        // here so a live user isn't silently confused by typing into a
        // buffer the screen isn't showing.
        std.log.info("system-swap: dispatch now targets '{s}' (render surface unchanged until the render membrane repoints it — W0b)", .{target});
    }

    /// `main.zig`'s `system-swap` command data: bundles `*Session` with an
    /// OPTIONAL app-level refusal predicate, checked at COMMAND time (not
    /// bind time) before `rebindSystem` runs. Generic (a function pointer +
    /// opaque ctx) rather than importing `app/collab.zig` directly, so
    /// `Session`'s own dependency surface doesn't grow to know about every
    /// main()-level subsystem that might want a say — `main.zig` wires
    /// `isBlocked`/`blocked_ctx` to `Collab.isLive` for the live-collab
    /// refusal (task #19 item 2: "collab sessions bound to a system's
    /// Document" — swapping out from under one is refused loudly, not
    /// forced, matching `Host.swap`'s own open-transient refusal in spirit).
    pub const SwapCmdData = struct {
        session: *Session,
        blocked_ctx: ?*anyopaque = null,
        isBlocked: ?*const fn (?*anyopaque) bool = null,
    };

    pub const SwapCmdError = core.System.Host.SwapError || error{SwapBlocked};

    /// The app-level `system-swap` command handler — the ONLY registered
    /// handler in the real editor (`main.zig` binds this directly onto every
    /// hosted system; `core.System.registerSwapCommand` exists for the
    /// synthetic gate fixtures and is not registered here, so there is
    /// nothing to shadow): identical `system-swap <name>` surface, but
    /// refuses loudly (logged, like `Host.swap`'s own transient refusal)
    /// when `data.isBlocked` says so, BEFORE touching the Host at all.
    pub fn systemSwapHandler(ctx: *core.command.Context, data: ?*anyopaque, args: []const core.command.Value) anyerror!core.command.Value {
        _ = ctx;
        const d: *SwapCmdData = @ptrCast(@alignCast(data.?));
        if (args.len == 0 or args[0] != .string) return .nil;
        if (d.isBlocked) |blocked| {
            if (blocked(d.blocked_ctx)) {
                std.log.warn("system-swap: refused — a live collab connection is bound to this system's document; disconnect before swapping systems", .{});
                return error.SwapBlocked;
            }
        }
        try d.session.rebindSystem(args[0].string);
        return .nil;
    }
};

const DirectoryTarget = struct {
    path: []u8,
    root: fs.contract.Root,
    publication: fs_runtime.publication.Registration,
    parent_resolved: bool = false,
    parent: ?semantic.target.Ref = null,
};

const FileTarget = struct {
    publication: fs_runtime.publication.Registration,
};

/// Local directory publication owns containment independently from whichever
/// plugin chooses to render a directory. Remote and synthetic publishers can
/// register the same relation name with entirely different mechanisms.
const LocalDirectoryRelations = struct {
    session: *Session,

    pub fn query(self: *LocalDirectoryRelations, request: target_runtime.relation.Query) target_runtime.relation.QueryError!?target_runtime.relation.Relation {
        if (std.mem.eql(u8, request.name, "container")) return self.queryContainer(request);
        if (!std.mem.eql(u8, request.name, target_runtime.relation.standard.child)) return null;
        const name = request.selector orelse return null;
        return self.queryChild(request, name);
    }

    fn queryContainer(self: *LocalDirectoryRelations, request: target_runtime.relation.Query) target_runtime.relation.QueryError!?target_runtime.relation.Relation {
        if (request.source.location != .whole) return error.InvalidRelation;
        for (self.session.directory_targets.items, 0..) |directory, index| {
            if (!directory.publication.ref.eql(request.source.target)) continue;
            if (directory.publication.revision != request.source.revision) return error.StaleTarget;
            const parent = (self.session.ensureDirectoryParent(index) catch |err| return switch (err) {
                error.Stale, error.StaleTarget => error.StaleTarget,
                error.Unsupported, error.NotFound, error.NotDirectory => error.Unavailable,
                else => error.Failed,
            }) orelse return null;
            return .{ .name = request.name, .target = parent };
        }
        return null;
    }

    /// Resolve a raw child name through the filesystem provider's listing and
    /// publish the resulting child target. This is intentionally a
    /// relation provider concern: no target handler or core path operation is
    /// involved, and raw names remain bytes all the way to the provider.
    fn queryChild(self: *LocalDirectoryRelations, request: target_runtime.relation.Query, name: []const u8) target_runtime.relation.QueryError!?target_runtime.relation.Relation {
        if (request.source.location != .whole or name.len == 0) return error.InvalidRelation;
        for (self.session.directory_targets.items) |directory| {
            if (!directory.publication.ref.eql(request.source.target)) continue;
            if (directory.publication.revision != request.source.revision) return error.StaleTarget;
            _ = self.session.filesystem_system.filesystems.authorizedDirectory(
                request.source.target,
                request.source.revision,
            ) catch |err| return switch (err) {
                error.StaleTarget, error.TargetUnbound, error.UnknownAuthority => error.StaleTarget,
                else => error.Failed,
            };
            const published = fs_runtime.publication.publishChildByName(
                self.session.gpa,
                &self.session.filesystem_system.semantic.targets,
                &self.session.filesystem_system.filesystems,
                self.session.filesystem_owner,
                request.source,
                name,
            ) catch |err| return switch (err) {
                error.Stale, error.StaleTarget, error.NotFound => error.StaleTarget,
                error.Unsupported, error.NotDirectory => error.Unavailable,
                else => error.Failed,
            };
            switch (published orelse return null) {
                .directory => |published_directory| {
                    var child = published_directory;
                    errdefer _ = child.close(
                        self.session.gpa,
                        &self.session.filesystem_system.semantic.targets,
                    );
                    // Provider identity, not the lexical child name, is
                    // the idempotence key. A replacement at the same name
                    // therefore gets a new target while repeated queries
                    // reuse this publication and root.
                    for (self.session.directory_targets.items) |existing| {
                        const same_root = self.session.filesystem_system.filesystems.sameRoot(
                            existing.root,
                            child.derived_root,
                        ) catch |err| switch (err) {
                            error.Stale => continue,
                            else => return error.Failed,
                        };
                        if (!same_root) continue;
                        const located = existing.publication.located();
                        _ = child.close(
                            self.session.gpa,
                            &self.session.filesystem_system.semantic.targets,
                        );
                        return .{ .name = request.name, .target = located };
                    }
                    const child_path = std.fs.path.join(self.session.gpa, &.{ directory.path, name }) catch return error.Failed;
                    errdefer self.session.gpa.free(child_path);
                    self.session.directory_targets.append(self.session.gpa, .{
                        .path = child_path,
                        .root = child.derived_root,
                        .publication = child.registration,
                    }) catch return error.Failed;
                    child.active = false;
                    return .{ .name = request.name, .target = child.registration.located() };
                },
                .file => |published_file| {
                    var child = published_file;
                    errdefer _ = child.close(
                        self.session.gpa,
                        &self.session.filesystem_system.semantic.targets,
                        &self.session.filesystem_system.filesystems,
                    );
                    const child_entry = self.session.filesystem_system.filesystems.authorizedEntry(
                        child.ref,
                        child.revision,
                    ) catch return error.Failed;
                    for (self.session.file_targets.items) |existing| {
                        const existing_entry = self.session.filesystem_system.filesystems.authorizedEntry(
                            existing.publication.ref,
                            existing.publication.revision,
                        ) catch continue;
                        if (existing_entry.root.eql(child_entry.root) and
                            existing_entry.ref.eql(child_entry.ref) and
                            std.mem.eql(u8, existing_entry.revision.token, child_entry.revision.token))
                        {
                            const located = existing.publication.located();
                            _ = child.close(
                                self.session.gpa,
                                &self.session.filesystem_system.semantic.targets,
                                &self.session.filesystem_system.filesystems,
                            );
                            return .{ .name = request.name, .target = located };
                        }
                    }
                    self.session.file_targets.append(self.session.gpa, .{ .publication = child }) catch return error.Failed;
                    return .{ .name = request.name, .target = child.located() };
                },
            }
        }
        return null;
    }
};

fn focusDirectoryTarget(ctx: *core.command.Context, target: semantic.target.Ref) anyerror!void {
    const services = ctx.semantic orelse return error.SemanticUnavailable;
    switch (try core.target_open.openAndFocus(services, ctx.head, ctx.gpa, target)) {
        .opened => {
            const descriptor = services.targets.get(target) orelse return error.StaleTarget;
            const base = std.fs.path.basename(descriptor.display_name);
            const name = try std.fmt.allocPrint(ctx.gpa, "files: {s}", .{if (base.len == 0) descriptor.display_name else base});
            defer ctx.gpa.free(name);
            _ = try ctx.buffers.attachFocusedSemanticView(ctx.gpa, ctx.head, ctx.keymap, name, "files");
        },
        .no_handler => return error.NoTargetHandler,
        .ambiguous => return error.AmbiguousTargetHandlers,
    }
}

// ── Tests: task #19 item 1/4's live gate, against the REAL production
//    Session (not `core/System.zig`'s synthetic fixtures) ──

const t = std.testing;

fn testGrammars(gpa: std.mem.Allocator) !core.syntax.Runtime {
    return core.syntax.Runtime.initBuiltins(gpa);
}

test "session: RUNS ON a System — init hosts \"editor\", cmd_ctx is wired to it, quit/mode match System.create's floor" {
    const gpa = t.allocator;
    const pool = try core.task.Pool.init(gpa, .{ .threads = 1 });
    defer pool.deinit();
    var grammars = try testGrammars(gpa);
    defer grammars.deinit(gpa);

    var sess: Session = undefined;
    try sess.init(gpa, pool, "user", &grammars);
    defer sess.deinit(gpa);

    try t.expectEqualStrings("editor", sess.system.name);
    try t.expect(sess.host.get("editor").? == sess.system);
    try t.expect(sess.cmd_ctx.buffers == &sess.system.buffers);
    try t.expect(sess.cmd_ctx.head == &sess.head);
    // The modeless floor's "default" mode, mirrored from `System.create`'s
    // `builtins.install` onto THIS head (not just `system.default_head`).
    try t.expectEqualStrings("default", sess.head.currentMode());

    // A real command through the real Session's cmd_ctx.
    try t.expect(!sess.system.quit);
    _ = try core.command.run(&sess.system.commands, &sess.cmd_ctx, "insert-text", &.{.{ .string = "hi" }});
    const got = try (try sess.cmd_ctx.textEditor()).text().toOwnedSlice(gpa);
    defer gpa.free(got);
    try t.expectEqualStrings("hi", got);
}

test "session: config manifest invokes the production grammar-add command with args" {
    const gpa = t.allocator;
    const pool = try core.task.Pool.init(gpa, .{ .threads = 1 });
    defer pool.deinit();
    var grammars = try testGrammars(gpa);
    defer grammars.deinit(gpa);

    var sess: Session = undefined;
    try sess.init(gpa, pool, "user", &grammars);
    defer sess.deinit(gpa);

    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(t.io, "grammar/queries");
    try tmp.dir.writeFile(t.io, .{ .sub_path = "grammar/queries/highlights.scm", .data = "" });
    const tmp_path = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/grammar", .{tmp.sub_path});
    defer gpa.free(tmp_path);
    const source = try std.fmt.allocPrint(gpa, "weft.run('grammar-add', '.fixture', '{s}', 'tree_sitter_fixture');", .{tmp_path});
    defer gpa.free(source);

    var engine = try core.wasm.Engine.init(gpa);
    defer engine.deinit();
    const manifest = try core.quickjs.evalToManifest(
        &engine,
        &sess.cmd_ctx,
        null,
        &sess.system.config_kv,
        null,
        source,
        .config,
        "config",
    );
    defer manifest.destroy();
    try t.expectEqual(@as(usize, 1), manifest.runs.items.len);
    try t.expectEqualStrings(tmp_path, manifest.runs.items[0].args[1].value);

    var actx: core.manifest.Manifest.ApplyCtx = .{ .ctx = &sess.cmd_ctx, .loader = null, .config = &sess.system.config_kv };
    try manifest.apply(gpa, &actx);
    try t.expect(grammars.forPath("fixture.fixture") != null);
}

test "session: local directories become deduplicated semantic targets while files fall through" {
    const gpa = t.allocator;
    const pool = try core.task.Pool.init(gpa, .{ .threads = 1 });
    defer pool.deinit();
    var grammars = try testGrammars(gpa);
    defer grammars.deinit(gpa);
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(t.io, "odd\n\xff");
    try tmp.dir.createDirPath(t.io, "odd\n\xff/child\n\xfe");
    try tmp.dir.writeFile(t.io, .{ .sub_path = "odd\n\xff/file\n\xfd", .data = "file contents" });
    const tmp_path = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer gpa.free(tmp_path);
    const directory_path = try std.fs.path.join(gpa, &.{ tmp_path, "odd\n\xff" });
    defer gpa.free(directory_path);
    try tmp.dir.writeFile(t.io, .{ .sub_path = "plain-file", .data = "contents" });
    const file_path = try std.fs.path.join(gpa, &.{ tmp_path, "plain-file" });
    defer gpa.free(file_path);

    var sess: Session = undefined;
    try sess.init(gpa, pool, "user", &grammars);
    defer sess.deinit(gpa);

    // Session publishes filesystem targets but owns no directory UI. Install
    // a tiny generic test handler to prove app composition is independent of
    // whichever plugin (the shipped sandboxed files, a remote browser, or a
    // synthetic tool) chooses to render them.
    const TestHandler = struct {
        gpa: std.mem.Allocator,
        services: *core.semantic.Services,
        owner: semantic.owner.Id,
        opened: std.ArrayList(struct {
            target: semantic.target.Located,
            view: semantic.view.Ref,
        }) = .empty,

        fn deinit(self: *@This()) void {
            self.opened.deinit(self.gpa);
        }

        pub fn probe(_: *@This(), descriptor: semantic.target.Descriptor) target_runtime.resolver.ProbeError!?semantic.target.Match {
            return if (descriptor.kind == .directory) .exact else null;
        }

        pub fn open(self: *@This(), located: semantic.target.Located) target_runtime.resolver.OpenError!semantic.view.Ref {
            const descriptor = self.services.targets.get(located.target) orelse return error.StaleTarget;
            if (descriptor.revision != located.revision or descriptor.kind != .directory) return error.StaleTarget;
            for (self.opened.items) |entry|
                if (entry.target.target.eql(located.target) and entry.target.revision == located.revision)
                    return entry.view;
            const view = self.services.views.publish(
                self.gpa,
                self.owner,
                .{ .ref = located.target, .revision = located.revision },
                1,
                .{ .id = @enumFromInt(1), .role = "directory-test", .focusable = true, .content = .{ .label = "directory" } },
            ) catch return error.Failed;
            self.opened.append(self.gpa, .{ .target = located, .view = view }) catch return error.Failed;
            return view;
        }
    };
    const handler_owner = try sess.system.semantic.acquireOwner();
    defer _ = sess.system.semantic.releaseOwner(gpa, handler_owner);
    var handler: TestHandler = .{ .gpa = gpa, .services = &sess.system.semantic, .owner = handler_owner };
    defer handler.deinit();
    _ = try sess.system.semantic.target_handlers.register(gpa, handler_owner, "test.directory", .init(&handler));
    defer _ = sess.system.semantic.target_handlers.unregisterOwner(gpa, handler_owner);

    try t.expect(try sess.openLocalDirectory(&sess.cmd_ctx, directory_path));
    try t.expectEqual(@as(usize, 1), sess.directory_targets.items.len);
    const first_target = sess.directory_targets.items[0].publication.ref;
    const first_view = sess.head.semantic_focus.view.?;
    try t.expectEqual(first_view, sess.head.semantic_focus.view.?);
    const scene = sess.system.semantic.views.get(first_view).?.scene;
    try t.expectEqualStrings("directory-test", scene.role);
    try t.expect(scene.focusable);
    try t.expect(std.mem.startsWith(u8, sess.system.buffers.active().name, "files: "));
    try t.expectEqualStrings("files", sess.system.buffers.active().tool);

    // Containment is publisher-owned and lazy. Resolving it pins the parent
    // independently of the generic handler's view state.
    var parent = try sess.system.semantic.resolveTargetRelation(gpa, .{
        .target = first_target,
        .revision = sess.directory_targets.items[0].publication.revision,
    }, "container");
    defer parent.deinit();
    try t.expectEqual(@as(usize, 2), sess.directory_targets.items.len);
    try t.expectEqual(
        sess.directory_targets.items[1].publication.ref,
        parent.value.resolved.target,
    );

    // The generic command path resolves a raw child selector through the
    // relation provider, then hands the resulting target to the independent
    // target handler. No process cwd or core-side path joining participates.
    sess.head.working_target = .{
        .target = first_target,
        .revision = sess.directory_targets[0].publication.revision,
    };
    _ = try core.command.run(&sess.system.commands, &sess.cmd_ctx, "open-relative", &.{.{ .string = "child\n\xfe" }});
    try t.expectEqual(@as(usize, 3), sess.directory_targets.items.len);
    const child_target = sess.directory_targets.items[2].publication.ref;
    const child_view = sess.head.semantic_focus.path().?.view;
    try t.expectEqual(child_target, sess.system.semantic.views.get(child_view).?.descriptor.target.?.ref);
    try t.expectEqualStrings("child\n\xfe", sess.system.semantic.targets.get(child_target).?.display_name);

    // A repeated query for a pinned child is identity-idempotent. The
    // provider may re-list and re-prove the entry, but it must return the
    // retained publication rather than growing the target table.
    var child_again = try sess.system.semantic.resolveTargetRelationWithSelector(gpa, .{
        .target = first_target,
        .revision = sess.directory_targets.items[0].publication.revision,
    }, target_runtime.relation.standard.child, "child\n\xfe");
    defer child_again.deinit();
    try t.expectEqual(child_target, child_again.value.resolved.target);
    try t.expectEqual(@as(usize, 3), sess.directory_targets.items.len);

    // Regular files use the same child relation and opaque raw selector. They
    // are separate semantic targets, while symlinks/non-regular entries are
    // deliberately not openable through this relation.
    var file_child = try sess.system.semantic.resolveTargetRelationWithSelector(gpa, .{
        .target = first_target,
        .revision = sess.directory_targets.items[0].publication.revision,
    }, target_runtime.relation.standard.child, "file\n\xfd");
    defer file_child.deinit();
    const file_target = file_child.value.resolved.target;
    try t.expectEqual(semantic.target.Kind.file, sess.system.semantic.targets.get(file_target).?.kind);
    try t.expectEqual(@as(usize, 1), sess.file_targets.items.len);
    var file_again = try sess.system.semantic.resolveTargetRelationWithSelector(gpa, .{
        .target = first_target,
        .revision = sess.directory_targets.items[0].publication.revision,
    }, target_runtime.relation.standard.child, "file\n\xfd");
    defer file_again.deinit();
    try t.expectEqual(file_target, file_again.value.resolved.target);
    try t.expectEqual(@as(usize, 1), sess.file_targets.items.len);

    // The parent first arrived as a pinned relation target. Opening its
    // lexical path later reacquires a fresh root handle, but provider identity
    // comparison must reuse the existing publication and session.
    try t.expect(try sess.openLocalDirectory(&sess.cmd_ctx, tmp_path));
    try t.expectEqual(@as(usize, 2), sess.directory_targets.items.len);

    // Reopening the same publication reuses the handler-owned retained view;
    // it does not create shared mutable draft state or a text-buffer twin.
    try t.expect(try sess.openLocalDirectory(&sess.cmd_ctx, directory_path));
    try t.expectEqual(first_target, sess.directory_targets.items[0].publication.ref);
    try t.expectEqual(first_view, sess.head.semantic_focus.view.?);
    try t.expectEqual(@as(usize, 2), sess.directory_targets.items.len);
    try t.expect(!try sess.openLocalDirectory(&sess.cmd_ctx, file_path));
    try t.expectEqual(@as(usize, 2), sess.directory_targets.items.len);

    // A directory can be renamed and replaced at its old path while its
    // original fd remains pinned. Opening that path must resolve the new
    // object, not reuse the old target merely because the display path is the
    // same. The replacement's parent is the already-retained root target.
    try tmp.dir.rename("odd\n\xff", tmp.dir, "moved\n\xff", t.io);
    try tmp.dir.createDirPath(t.io, "odd\n\xff");
    try t.expect(try sess.openLocalDirectory(&sess.cmd_ctx, directory_path));
    try t.expectEqual(@as(usize, 3), sess.directory_targets.items.len);
    try t.expect(!sess.directory_targets.items[2].publication.ref.eql(first_target));

    var replacement_parent = try sess.system.semantic.resolveTargetRelation(gpa, .{
        .target = sess.directory_targets.items[2].publication.ref,
        .revision = sess.directory_targets.items[2].publication.revision,
    }, "container");
    defer replacement_parent.deinit();
    try t.expectEqual(sess.directory_targets.items[1].publication.ref, replacement_parent.value.resolved.target);

    // A retained parent can observe a child being replaced at the same raw
    // name. The old child publication remains pinned, while the new lookup
    // must publish and return a distinct provider identity rather than
    // silently reusing the old target by display name.
    try tmp.dir.rename("moved\n\xff/child\n\xfe", tmp.dir, "moved\n\xff/replaced-child\n\xfe", t.io);
    try tmp.dir.createDirPath(t.io, "moved\n\xff/child\n\xfe");
    var replacement_child = try sess.system.semantic.resolveTargetRelationWithSelector(gpa, .{
        .target = first_target,
        .revision = sess.directory_targets.items[0].publication.revision,
    }, target_runtime.relation.standard.child, "child\n\xfe");
    defer replacement_child.deinit();
    const replacement_child_target = replacement_child.value.resolved.target;
    try t.expect(!replacement_child_target.eql(child_target));
    try t.expectEqual(@as(usize, 4), sess.directory_targets.items.len);
    try t.expect(!try sess.filesystem_system.filesystems.sameRoot(
        sess.directory_targets.items[2].root,
        sess.directory_targets.items[3].root,
    ));

    var replacement_child_again = try sess.system.semantic.resolveTargetRelationWithSelector(gpa, .{
        .target = first_target,
        .revision = sess.directory_targets.items[0].publication.revision,
    }, target_runtime.relation.standard.child, "child\n\xfe");
    defer replacement_child_again.deinit();
    try t.expectEqual(replacement_child_target, replacement_child_again.value.resolved.target);
    try t.expectEqual(@as(usize, 4), sess.directory_targets.items.len);
}

test "session: GATE — system-swap live-rebinds the REAL Session's head; buffers/commands/keymap switch, refuses on an open transient" {
    const gpa = t.allocator;
    const pool = try core.task.Pool.init(gpa, .{ .threads = 1 });
    defer pool.deinit();
    var grammars = try testGrammars(gpa);
    defer grammars.deinit(gpa);

    var sess: Session = undefined;
    try sess.init(gpa, pool, "user", &grammars);
    defer sess.deinit(gpa);
    const editor_sys = sess.system;

    // A second, minimal hosted system — exactly what `main.zig` hosts from
    // `config/agent-ux.js`, built directly here so this test needs no file
    // I/O.
    const agent_sys = try core.System.create(gpa, pool, "agent-ux", "user");
    try agent_sys.keymap.bind(gpa, "chat", "q", "agent-ux-quit-noop", core.Keymap.prio_plugin, "test");
    try sess.host.hostSystem(agent_sys);

    // Type into the editor system first — lands on ITS buffer.
    _ = try core.command.run(&editor_sys.commands, &sess.cmd_ctx, "insert-text", &.{.{ .string = "editor text" }});

    var swap_data: Session.SwapCmdData = .{ .session = &sess };
    try sess.system.commands.bind(gpa, "system-swap", .{
        .name = "system-swap",
        .summary = "test",
        .args = &.{.{ .name = "name", .type = .string }},
        .handler = Session.systemSwapHandler,
        .data = &swap_data,
    });

    // The swap runs through the ORDINARY command surface — proving this
    // isn't a special path, exactly like `core/System.zig`'s own "via the
    // system-swap COMMAND" gate test, but against `app.Session` this time.
    _ = try core.command.run(&editor_sys.commands, &sess.cmd_ctx, "system-swap", &.{.{ .string = "agent-ux" }});

    // Every table pointer repointed; `sess.system` (the convenience alias)
    // kept in sync.
    try t.expect(sess.cmd_ctx.buffers == &agent_sys.buffers);
    try t.expect(sess.cmd_ctx.keymap == &agent_sys.keymap);
    try t.expect(sess.cmd_ctx.commands == &agent_sys.commands);
    try t.expect(sess.system == agent_sys);

    // Editing now lands on the NEW system's buffer — the editor's own text
    // from before the swap is untouched.
    _ = try core.command.run(&agent_sys.commands, &sess.cmd_ctx, "insert-text", &.{.{ .string = "agent text" }});
    const agent_got = try agent_sys.buffers.active().textEditor().?.text().toOwnedSlice(gpa);
    defer gpa.free(agent_got);
    try t.expectEqualStrings("agent text", agent_got);
    const editor_got = try editor_sys.buffers.active().textEditor().?.text().toOwnedSlice(gpa);
    defer gpa.free(editor_got);
    try t.expectEqualStrings("editor text", editor_got);

    // Swap back.
    _ = try core.command.run(&agent_sys.commands, &sess.cmd_ctx, "system-swap", &.{.{ .string = "editor" }});
    try t.expect(sess.cmd_ctx.buffers == &editor_sys.buffers);
    try t.expect(sess.system == editor_sys);

    // F1 — an open transient refuses the swap, same as `Host.swap` alone.
    try editor_sys.keymap.markMenuMode(gpa, "leader");
    const cc = sess.cmd_ctx.capturedCtx();
    var handle = try cc.pushTransient(&editor_sys.keymap, "leader");
    defer handle.deinit();
    try t.expectError(error.OpenTransient, sess.rebindSystem("agent-ux"));
    try t.expect(sess.cmd_ctx.buffers == &editor_sys.buffers);
}

test "session: SwapCmdData.isBlocked refuses loudly BEFORE touching the Host — task #19 item 2's live-collab case" {
    const gpa = t.allocator;
    const pool = try core.task.Pool.init(gpa, .{ .threads = 1 });
    defer pool.deinit();
    var grammars = try testGrammars(gpa);
    defer grammars.deinit(gpa);

    var sess: Session = undefined;
    try sess.init(gpa, pool, "user", &grammars);
    defer sess.deinit(gpa);
    const editor_sys = sess.system;

    const agent_sys = try core.System.create(gpa, pool, "agent-ux", "user");
    try sess.host.hostSystem(agent_sys);

    const AlwaysBlocked = struct {
        fn blocked(_: ?*anyopaque) bool {
            return true;
        }
    };
    var swap_data: Session.SwapCmdData = .{ .session = &sess, .isBlocked = AlwaysBlocked.blocked };
    try sess.system.commands.bind(gpa, "system-swap", .{
        .name = "system-swap",
        .summary = "test",
        .args = &.{.{ .name = "name", .type = .string }},
        .handler = Session.systemSwapHandler,
        .data = &swap_data,
    });

    try t.expectError(error.SwapBlocked, core.command.run(&editor_sys.commands, &sess.cmd_ctx, "system-swap", &.{.{ .string = "agent-ux" }}));
    // Refused BEFORE the Host was touched: still targeting the editor.
    try t.expect(sess.cmd_ctx.buffers == &editor_sys.buffers);
    try t.expect(sess.system == editor_sys);
}

test {
    std.testing.refAllDecls(@This());
}
