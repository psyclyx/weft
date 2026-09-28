//! `plugin_resources` — the live external resources a plugin holds, named
//! once for both transports.
//!
//! A plugin that spawns a subprocess or dials a socket holds something the
//! HOST owns and the guest addresses by handle. Which guest runtime asked for
//! it — a `.wasm` module, or JS running inside `quickjs.wasm`, which is
//! itself a `.wasm` module — has nothing to do with what the resource IS, how
//! it is addressed, or how it dies. This block is where that stops being
//! restated once per plane.
//!
//! **What it replaced.** `WasmPlugin` and `JsPlugin` each carried their own
//! `pool`, `environ` and stream registry, and `wasm_host/proc.zig`'s four
//! shared bodies reached them through an `anytype` duck type: `procPool()`,
//! `procStreams()`, `baseEnviron()`, declared under identical names on both
//! types so that neither had to be spelled into the other's layout. That duck
//! type was never the abstraction — it was the SYMPTOM of one kind of state
//! living on two instance types. The bodies take `*Resources` outright now,
//! the accessor trio is gone from both planes, and a door that wants a fifth
//! resource adds a field here rather than a method in two files.
//!
//! It also settles a difference the two planes had drifted into without
//! anyone choosing it: the wasm plane read the base environment lazily from
//! a host global at every spawn, while the JS plane snapshotted it at load
//! (`config_load.zig` hands `wasm_host.hostEnviron()` to `JsPlugin.load`).
//! Both snapshot now. The value is the environment weft itself started with
//! and does not change during a run, so this is one behaviour instead of two
//! that only ever agreed by luck.
//!
//! **What is deliberately NOT here: authority.** `perms`, `grant_table` and
//! `grant_handles` stay on the plugin instance. A grant is minted against the
//! code that ran `describe()` (doc/contextual-workspace-architecture.md
//! §13.5), so moving it into a block designed to be shared — or one day to
//! outlive a single load — is exactly how a reload of DIFFERENT code under
//! the same name would inherit the old code's permissions. Resources are what
//! a plugin HAS; authority is what it may DO, and the second one must die
//! with the instance that was granted it.

const std = @import("std");
const Allocator = std.mem.Allocator;

const handles = @import("handles.zig");
const proc_stream = @import("proc_stream.zig");
const repl_session = @import("repl_session.zig");
const net_session = @import("net_session.zig");
const pty_mod = @import("pty.zig");
const Pool = @import("task.zig").Pool;
const command_mod = @import("command.zig");

/// What a SHARED plugin-plane body receives, whichever transport called it:
/// the calling plugin's resources, and the context of the entry that
/// dispatched into it.
///
/// One shape for every shared body — the read doors (`wasm_host/edit.zig`'s
/// `read_doors`) use only `ctx`, the proc doors use both — so a door family
/// cannot quietly acquire a different calling convention from its neighbour,
/// and a body that later needs the other half needs no signature change on
/// two planes to get it. Everything genuinely per-transport (how `data` is
/// cast, where `ctx` comes from, how a denial is spelled — a trap for a
/// `.wasm` guest, `qjs_contract.denied` for the resident JS runtime a trap
/// would tear down) stays in the generator that builds this.
pub const Door = struct {
    resources: *Resources,
    ctx: *@import("command.zig").Context,
};

/// The host-owned resources one loaded plugin holds by handle. Embedded BY
/// VALUE in the plugin instance that owns it, on either plane.
pub const Resources = struct {
    gpa: Allocator,
    /// The principal, used for a refusal message when a spawn is denied its
    /// place. BORROWED from the owning plugin's `name`, which embeds this
    /// block and therefore outlives it by construction.
    name: []const u8,
    /// The task pool a stream's or session's reader thread runs on. Null on a
    /// bare unit-test fixture built without one; the doors answer -1 rather
    /// than pretending to start something.
    pool: ?*Pool,
    /// What a spawned child inherits when its place supplies no overlay.
    environ: std.process.Environ,

    /// Raw duplex subprocesses (`wl_proc_spawn`): stdout comes BACK to the
    /// guest, which deframes it (the `lsp` plugin's transport).
    streams: handles.Slots(proc_stream.ProcStream) = .empty,
    /// Interactive REPL subprocesses (design §6.3): output streams into a
    /// comint buffer instead of back to the guest.
    sessions: handles.Slots(repl_session.Session) = .empty,
    /// Network connections (design §6.5) — the socket mirror of `sessions`.
    net_sessions: handles.Slots(net_session.Session) = .empty,
    /// Children on pseudo-terminals (`wl_pty_spawn`, doc/terminal.md §1): raw
    /// output back to the guest, which emulates the terminal itself.
    ptys: handles.Slots(pty_mod.Pty) = .empty,

    /// WHAT THIS GUEST'S COMMANDS SAY ABOUT THEMSELVES — name, one-line
    /// summary, argument shape. Owned.
    ///
    /// It lives HERE, in the block both planes embed, because it is the thing
    /// the two planes must never describe differently. They did: a `.wasm`
    /// plugin declared a summary and an argument shape through
    /// `declare_command_doc`, and a `.js` one had no such door at all — so
    /// every JS command was registered with the literal string "js" in the
    /// summary field, which is not a summary, and with no arguments, so the
    /// palette could not ask for them. That is not a missing feature on one
    /// side; it is one concept with two definitions, and the second one drifted
    /// because there was a second one to drift.
    ///
    /// One store, one declare body, one lookup. A field added here reaches both
    /// planes or neither.
    declared: std.ArrayList(DeclaredCommand) = .empty,

    /// Whether declarations are being ACCEPTED right now. Closed by default:
    /// a store that took anything at any time would let a plugin rewrite its
    /// own summary after the palette had read it.
    ///
    /// The wasm plane opens this only for `describe()`, which is what makes an
    /// undeclared command fail its load; the JS plane, which has no describe
    /// handshake, opens it for init and closes it after. The RULE each plane
    /// enforces is its own — what a declaration IS is not.
    accepting_declarations: bool = false,

    /// The finished `wl_exec` a delivery is currently handing back. Set just
    /// before the guest's `on_exec` runs and torn down the moment it returns,
    /// so the read doors answer only inside the callback that owns them and a
    /// guest cannot hold one command's output into the next one's.
    ///
    /// It lives here rather than as a job field because the READ DOORS need it
    /// and a door is only ever given the plugin's resources — which is exactly
    /// the shape that stops "the result of whose exec?" from being a question.
    exec: ?Exec = null,

    /// Capability names the guest declared (`declare_capability`, owned) —
    /// what a designation claim outside the plugin's own name is checked
    /// against (`designation/<kind>`). Here, not on a plane, because the
    /// shared claim body reads it: a `.wasm` plugin fills it in `describe()`;
    /// a `.js` one has no describe handshake, so it declares none and may
    /// claim only in its own namespace.
    declared_capabilities: std.ArrayList([]u8) = .empty,

    /// A refusal a door met that a LOAD must not survive — a projection kind
    /// the plugin may not claim (`wasm_host/tool.zig`), which would otherwise
    /// load a producer that silently answers nothing. Both loaders read it
    /// when init returns and fail the load; after the load it is the
    /// caller's refused answer that matters, and nothing reads this.
    load_refusal: ?anyerror = null,

    /// A completed child: what it said on both streams, and how it ended.
    pub const Exec = struct {
        /// The exit code, or -1 for a child that died by signal or never ran.
        /// A guest gets ONE number for "did this work", where the old sentinel
        /// protocol had it print its own status into stdout for the plugin to
        /// scan back out.
        status: i32,
        stdout: []u8,
        stderr: []u8,

        pub fn deinit(self: *Exec, gpa: Allocator) void {
            gpa.free(self.stdout);
            gpa.free(self.stderr);
            self.* = undefined;
        }
    };

    /// What a guest said one of its commands is. Moved here from
    /// `WasmPlugin` — see `declared` for why it cannot live on one plane.
    pub const DeclaredCommand = struct {
        name: []u8,
        summary: []u8 = &.{},
        /// The declared parameter list, as written: space-separated names, each
        /// bare (required) or bracketed (`[preset]`, optional). Owned; the
        /// `ArgSpec` names below borrow slices of it.
        params: []u8 = &.{},
        args: []command_mod.ArgSpec = &.{},
        /// How it maps over several extents (`declare_arity`), null undeclared;
        /// an `over` target command borrows `over`, which this owns.
        arity: ?@import("selection.zig").Arity = null,
        over: []u8 = &.{},
        /// How it is presented to people (`declare_command_meta`): the text
        /// form as declared, owned, and the value decoded from it, borrowing it.
        meta_text: []u8 = &.{},
        meta: command_mod.Presentation = .{},

        /// Parse a declared parameter list into `ArgSpec`s. Every guest argument
        /// crosses as a string (the membrane carries nothing else), so the only
        /// thing to read out of a token is its NAME and whether it is optional.
        /// Malformed input degrades to fewer arguments, never to a wrong shape.
        pub fn parseParams(gpa: Allocator, params: []const u8) Allocator.Error!struct { []u8, []command_mod.ArgSpec } {
            const owned = try gpa.dupe(u8, params);
            errdefer gpa.free(owned);
            var count: usize = 0;
            var counter = std.mem.tokenizeAny(u8, owned, " \t");
            while (counter.next()) |_| count += 1;
            const specs = try gpa.alloc(command_mod.ArgSpec, count);
            errdefer gpa.free(specs);
            var it = std.mem.tokenizeAny(u8, owned, " \t");
            var i: usize = 0;
            while (it.next()) |tok| : (i += 1) {
                const optional = tok.len >= 2 and tok[0] == '[' and tok[tok.len - 1] == ']';
                specs[i] = .{
                    .name = if (optional) tok[1 .. tok.len - 1] else tok,
                    .type = .string,
                    .optional = optional,
                };
            }
            return .{ owned, specs };
        }

        pub fn deinit(self: *DeclaredCommand, gpa: Allocator) void {
            gpa.free(self.name);
            gpa.free(self.summary);
            gpa.free(self.params);
            gpa.free(self.args);
            gpa.free(self.over);
            gpa.free(self.meta_text);
        }
    };

    /// What this guest said about `name`, or null. The ONE lookup both planes'
    /// register doors go through, so a command's summary and argument shape
    /// have a single origin.
    pub fn declaration(self: *const Resources, name: []const u8) ?*const DeclaredCommand {
        for (self.declared.items) |*d| if (std.mem.eql(u8, d.name, name)) return d;
        return null;
    }

    /// The same lookup, for the describe-phase door that adds to a
    /// declaration (`declare_arity`).
    pub fn declarationMut(self: *Resources, name: []const u8) ?*DeclaredCommand {
        for (self.declared.items) |*d| if (std.mem.eql(u8, d.name, name)) return d;
        return null;
    }

    pub fn init(gpa: Allocator, name: []const u8, pool: ?*Pool, environ: std.process.Environ) Resources {
        return .{ .gpa = gpa, .name = name, .pool = pool, .environ = environ };
    }

    /// Stop every live resource, then free the registries. Each registry's
    /// own `deinit` does the killing and joining — `handles.Slots` can own
    /// release because everything in it knows how to die.
    pub fn deinit(self: *Resources) void {
        self.streams.deinit(self.gpa); // kill + join each
        self.sessions.deinit(self.gpa); // kill + join each
        self.net_sessions.deinit(self.gpa); // shut + join each
        self.ptys.deinit(self.gpa); // hang up + join each
        if (self.exec) |*e| e.deinit(self.gpa); // an unload mid-callback
        for (self.declared.items) |*d| d.deinit(self.gpa);
        self.declared.deinit(self.gpa);
        for (self.declared_capabilities.items) |c| self.gpa.free(c);
        self.declared_capabilities.deinit(self.gpa);
    }

    /// Whether the guest declared capability `name`.
    pub fn declaresCapability(self: *const Resources, name: []const u8) bool {
        for (self.declared_capabilities.items) |c| if (std.mem.eql(u8, c, name)) return true;
        return false;
    }

    /// Whether anything here still has buffered output or a live reader — the
    /// frame loop's "is this plugin worth waking for" question, asked the same
    /// way of both planes. A pty is not asked: it rings the frame loop itself
    /// (the pool's notify fd) when output lands or its child ends, so a shell
    /// idling in a panel costs no poll.
    pub fn hasLiveStream(self: *const Resources) bool {
        return anyLive(proc_stream.ProcStream, self.streams.slice()) or
            anyLive(repl_session.Session, self.sessions.slice()) or
            anyLive(net_session.Session, self.net_sessions.slice());
    }

    fn anyLive(comptime T: type, slots: []const ?*T) bool {
        for (slots) |maybe| if (maybe) |_| return true;
        return false;
    }
};
