//! `Session` — the cohesive owner of weft's core editing state: the buffer set,
//! the command/keymap/pick surfaces, the capability store, the transient echo
//! line, the quit flag, and the capability-consumer UIs (completion, definition,
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
//! borrows them by pointer to wire those two commands, and `which_key_now` (the
//! F1 flag the dispatch path reads) stays a `main()` local, borrowed likewise.

const std = @import("std");
const core = @import("../core/core.zig");
const cursor_config = @import("cursor_config.zig");
const providers = @import("providers.zig");
const setup = @import("setup.zig");

pub const Session = struct {
    gpa: std.mem.Allocator,

    // ── Editor core ──
    buffers: core.Buffers,
    commands: core.command.Commands,
    keymap: core.Keymap,
    pick: core.Pick,
    caps: core.Caps,
    quit: bool,
    echo: std.ArrayList(u8),
    /// Self-referential: points at the fields above — built in place.
    cmd_ctx: core.command.Context,

    // ── Capability-consumer UIs (written against capability names only) ──
    completion_ui: core.complete_ui.CompletionUi,
    def_ui: core.nav_ui.DefinitionUi,
    sym_ui: core.nav_ui.SymbolsUi,
    hover_ui: core.nav_ui.HoverUi,

    // ── Caret / which-key config (set declaratively by config at load time) ──
    cursor_cfg: cursor_config.CursorConfig,

    /// Build the editing state IN PLACE (`self` is already at its final address
    /// in `main()`'s frame), so `cmd_ctx`'s `&self.field` borrows never dangle.
    /// Installs the built-ins, then binds the capability consumers (which also
    /// wire `grammar-add`/`lsp-add` onto the caller-owned `grammars`/`lsp_servers`
    /// registries) and the caret/which-key commands — in registration order.
    pub fn init(
        self: *Session,
        gpa: std.mem.Allocator,
        pool: *core.task.Pool,
        user: []const u8,
        grammars: *core.syntax.Runtime,
        lsp_servers: *providers.LspServers,
        which_key_now: *bool,
    ) !void {
        self.gpa = gpa;
        self.buffers = try core.Buffers.init(gpa, pool, user);
        errdefer self.buffers.deinit(gpa);
        self.commands = .empty;
        self.keymap = .empty;
        self.pick = .empty;
        self.caps = core.Caps.init(gpa, core.task.nowNs);
        self.quit = false;
        self.echo = .empty;
        self.cmd_ctx = .{
            .gpa = gpa,
            .buffers = &self.buffers,
            .commands = &self.commands,
            .keymap = &self.keymap,
            .pick = &self.pick,
            .caps = &self.caps,
            .quit = &self.quit,
            .echo = &self.echo,
        };
        try core.builtins.install(gpa, &self.commands, &self.keymap);
        // Capability consumers — written against capability names only.
        self.completion_ui = .empty;
        self.def_ui = .empty;
        self.sym_ui = .empty;
        self.hover_ui = .empty;
        try setup.registerCapabilityConsumers(gpa, &self.commands, &self.completion_ui, &self.def_ui, &self.sym_ui, &self.hover_ui, grammars, lsp_servers);
        // Caret config commands, registered before the config runs so it can
        // set per-mode styles at load time.
        self.cursor_cfg = .{ .gpa = gpa };
        try setup.registerCursorCommands(gpa, &self.commands, &self.cursor_cfg, which_key_now);
    }

    /// Free in the exact reverse order `main()`'s defers used to run:
    /// cursor_cfg, hover_ui, sym_ui, echo, caps, pick, keymap, commands,
    /// buffers. (completion_ui/def_ui own no heap and had no defer — omitted, to
    /// match `main()` exactly.)
    pub fn deinit(self: *Session, gpa: std.mem.Allocator) void {
        self.cursor_cfg.deinit();
        self.hover_ui.deinit(gpa);
        self.sym_ui.deinit(gpa);
        self.echo.deinit(gpa);
        self.caps.deinit();
        self.pick.deinit(gpa);
        self.keymap.deinit(gpa);
        self.commands.deinit(gpa);
        self.buffers.deinit(gpa);
    }
};
