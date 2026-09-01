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
const Pool = @import("task.zig").Pool;

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

    /// The finished `wl_exec` a delivery is currently handing back. Set just
    /// before the guest's `on_exec` runs and torn down the moment it returns,
    /// so the read doors answer only inside the callback that owns them and a
    /// guest cannot hold one command's output into the next one's.
    ///
    /// It lives here rather than as a job field because the READ DOORS need it
    /// and a door is only ever given the plugin's resources — which is exactly
    /// the shape that stops "the result of whose exec?" from being a question.
    exec: ?Exec = null,

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
        if (self.exec) |*e| e.deinit(self.gpa); // an unload mid-callback
    }

    /// Whether anything here still has buffered output or a live reader — the
    /// frame loop's "is this plugin worth waking for" question, asked the same
    /// way of both planes.
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
