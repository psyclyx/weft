//! `Session` — the cohesive owner of weft's core editing state: the buffer set,
//! the command/keymap surfaces, the one `Head` this process runs today (its
//! mode/pending/pick/echo — north-star-plan §6 W2a-1), the capability store,
//! the quit flag, and the capability-consumer UIs (completion, definition,
//! symbols, hover) plus the caret config. `main()` holds ONE `session` object
//! instead of ~a dozen loose editing locals.
//!
//! `cmd_ctx` holds pointers to sibling fields (`&self.buffers`, `&self.commands`
//! …), so — exactly like `RenderState` — `init` runs IN PLACE (`self` already at
//! its final address in `main()`'s frame): no captured `&self.field` can dangle
//! after a move. `init` also installs the built-ins and binds the capability +
//! caret/which-key commands, in the same registration order `main()` used
//! inline (registration is last-wins — order is load-bearing). `deinit` frees in
//! the exact reverse order `main()`'s defers used to run.
//!
//! The grammar/LSP registries (`grammars`, `lsp_servers`) that the capability
//! consumers' `grammar-add`/`lsp-add` bind onto live in `Providers`; `init`
//! borrows them by pointer to wire those two commands. `which_key_now` (the
//! F1 flag the dispatch path reads) lives on `menu_overlay` below, not as a
//! separate `main()` local — see `frame.MenuOverlay`'s field doc for why.

const std = @import("std");
const core = @import("../core/core.zig");
const cursor_config = @import("cursor_config.zig");
const providers = @import("providers.zig");
const setup = @import("setup.zig");
const frame = @import("frame.zig");
const ui_mesh = @import("../gfx/view.zig").ui_mesh;

pub const Session = struct {
    gpa: std.mem.Allocator,

    // ── Editor core ──
    buffers: core.Buffers,
    commands: core.command.Commands,
    /// System-scoped keymap TABLES — shared by every head (see
    /// `core.Keymap`'s module doc). `head` below is `main()`'s ONE per-head
    /// cursor into them; a second head (proven live by the e2e two-head
    /// gate, `e2e/two_head_test.zig`) is a second `core.Head` + a second
    /// `command.Context` pointed at it, borrowing these tables — `main()`
    /// itself still drives exactly one (a second RENDERED head is a bigger,
    /// later change — see `window_layout.zig`'s module doc for the boundary).
    keymap: core.Keymap,
    /// This session's one head's interaction state: current mode, pending
    /// chord, pick session, echo line, dot-repeat register (north-star-plan
    /// §6 W2a).
    head: core.Head,
    /// This head's which-key menu-overlay edge tracker (open/shown/forced/
    /// open_ns) — app-layer state that can't live ON `core.Head` (see
    /// `frame.MenuOverlay`'s doc), but is exactly as per-head as `head`
    /// itself; `Session` is the nearest thing to a "per-head bundle" the app
    /// has today, so it lives here beside it (north-star-plan §6 W2a-2). A
    /// second head (the e2e two-head gate) pairs its own instance the same
    /// way, alongside its own ad hoc `Head`.
    menu_overlay: frame.MenuOverlay,
    /// The ONE `container.Container` this session's `caps`/`actions` AND the
    /// UI mesh's `ui/statusline-seg` + `ui/gutter-segment` slots (north-
    /// star-plan §6 W3-1) all bind into (task #19's shared-Container
    /// fold-in — `System.zig`'s `container` field doc has the full
    /// reasoning, identical here: action names/`edit/*` capability names/
    /// `ui/*` mesh names are one flat, non-colliding slot namespace).
    /// `ui_mesh.declareSlots`/`bindDefaultStatusline` run against this same
    /// instance below; the three default gutter providers are NOT bound
    /// (see `ui_mesh.zig`'s module doc: no live gutter exists today, so
    /// nothing regresses by construction). REACHABLE from config now:
    /// `main.zig` wires a `manifest.StatusSegBinder` onto its
    /// `ConfigSession` pointed at `&self.container`, so `weft.statusSegment`
    /// in `config.js` binds a real `ui/statusline-seg` provider here (see
    /// `ui_mesh.zig`'s `bindManifestSegment`).
    container: core.container.Container,
    caps: core.Caps,
    actions: core.Actions,
    quit: bool,
    /// Self-referential: points at the fields above — built in place.
    cmd_ctx: core.command.Context,

    // ── Capability-consumer UIs (written against capability names only) ──
    completion_ui: core.complete_ui.CompletionUi,

    // ── Caret / which-key config (set declaratively by config at load time) ──
    cursor_cfg: cursor_config.CursorConfig,

    /// Build the editing state IN PLACE (`self` is already at its final address
    /// in `main()`'s frame), so `cmd_ctx`'s `&self.field` borrows never dangle.
    /// Installs the built-ins, then binds the capability consumers (which also
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
        self.buffers = try core.Buffers.init(gpa, pool, user);
        errdefer self.buffers.deinit(gpa);
        self.commands = .empty;
        self.keymap = .empty;
        self.head = .empty;
        self.menu_overlay = .{};
        // The ONE shared Container (task #19) — built before `caps`/
        // `actions`, which borrow a pointer into it.
        self.container = core.container.Container.init(gpa);
        errdefer self.container.deinit();
        self.caps = core.Caps.init(gpa, core.task.nowNs, &self.container);
        self.actions = core.Actions.init(gpa, &self.container);
        self.quit = false;
        self.cmd_ctx = .{
            .gpa = gpa,
            .buffers = &self.buffers,
            .commands = &self.commands,
            .keymap = &self.keymap,
            .actions = &self.actions,
            .caps = &self.caps,
            .quit = &self.quit,
            .head = &self.head,
        };
        try core.builtins.install(gpa, &self.commands, &self.keymap, &self.head, &self.actions);
        try ui_mesh.declareSlots(&self.container);
        try ui_mesh.bindDefaultStatusline(&self.container);
        // Capability consumers — written against capability names only.
        self.completion_ui = .empty;
        try setup.registerCapabilityConsumers(gpa, &self.commands, &self.completion_ui, grammars);
        // Caret config commands, registered before the config runs so it can
        // set per-mode styles at load time.
        self.cursor_cfg = .{ .gpa = gpa };
        try setup.registerCursorCommands(gpa, &self.commands, &self.cursor_cfg, &self.menu_overlay.which_key_now);
    }

    /// Free in the exact reverse order `main()`'s defers used to run: cursor_cfg,
    /// head (echo+pick), caps, keymap, commands, buffers. (completion_ui owns
    /// no heap.)
    pub fn deinit(self: *Session, gpa: std.mem.Allocator) void {
        self.cursor_cfg.deinit();
        self.head.deinit(gpa);
        self.actions.deinit();
        self.caps.deinit();
        // The shared Container outlives both borrowers above (neither
        // `deinit` touches it) — torn down here, once, by its owner.
        self.container.deinit();
        self.keymap.deinit(gpa);
        self.commands.deinit(gpa);
        self.buffers.deinit(gpa);
    }

    /// Delegating facade: the echo line lives on `head` now (north-star-plan
    /// §6 W2a-1 moved it out of `Session`'s own storage) — this is the one
    /// spot app-side code says `session.echo()` instead of reaching into
    /// `session.head.echo` directly.
    pub fn echo(self: *Session) *std.ArrayList(u8) {
        return &self.head.echo;
    }
};
