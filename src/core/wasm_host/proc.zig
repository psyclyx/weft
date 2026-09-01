//! Perm-gated off-thread process effects (proc + timer): shell-insert at the
//! cursor, proc-to/append/spool-buffer (tool output → a scratch buffer), and
//! the in-place range filter (formatters). Each schedules on the async loop and
//! lands its result on the frame thread at CRDT identity anchors, authored as
//! the plugin peer.
//!
//! Two of these doors hand a child bytes ON DISK without the guest ever naming
//! a path: the filter (`{}` = a temp the range is written to and read back)
//! and the SPOOL (`{}` = a temp the guest's input payload is written to). Both
//! compose the path host-side and delete it on every terminal path, so
//! "a subprocess needs a real file" stops being a reason to grant `fs_write`
//! (`doc/place.md` §4.2).

const std = @import("std");
const Allocator = std.mem.Allocator;
const wasm = @import("../wasm.zig");
const command = @import("../command.zig");
const Buffers = @import("../Buffers.zig");
const proc = @import("../proc.zig");
const Document = @import("../Document.zig");
const file = @import("../file.zig");
const contract = @import("../membrane/contract.zig");
const place_mod = @import("../place.zig");
const rooted_fs = @import("../rooted_fs.zig");
const machinery = @import("../machinery.zig");

const shared = @import("plugin.zig");
const WasmPlugin = shared.WasmPlugin;
const requirePerm = shared.requirePerm;

/// A deferred shell insert, owned across the frame→pool→frame hop. Holds no
/// plugin pointer — it resolves the generation-checked buffer captured at
/// dispatch and the peer by name at delivery, so a focus change cannot redirect
/// the edit and a closed/reused buffer safely makes it stale. Freed in every
/// terminal case by the sink's deinit.
///
/// Deferred jobs retain only the session-owned allocator/registry they need,
/// never a head's dispatch `Context`. Context is ambient plumbing and its
/// `document()` intentionally means "whatever this call is about right now";
/// neither is a target token.
const ShellJob = struct {
    gpa: Allocator,
    buffers: *Buffers,
    buffer: Buffers.Ref,
    name: []u8,
    target: Document.EventAnchor,
    cmd: []u8, // the shell command line
    /// Where the child runs, captured at spawn (`doc/place.md`). Null is the
    /// `.process` place: inherit the editor's own directory. Owned; freed with
    /// the rest of the job.
    cwd: ?[]u8 = null,
    /// The environment the child runs with, captured at spawn. Null = the base
    /// process environment (no overlay for this place). OWNED; freed with the job.
    environ: ?std.process.Environ = null,
};

// ── Raw persistent proc (proc_spawn/send/read/close) ─────────────────
// A bidirectional stdio channel whose stdout comes BACK to the guest (unlike
// the buffer-streaming repl sessions), so an in-guest protocol client — the
// `lsp` plugin — can deframe Content-Length messages. Handles index the
// plugin's own stream list and stay stable (a closed slot is nulled, not
// removed).
//
// ONE DOOR, TWO TRANSPORTS (doc/place.md §4.1a). `quickjs.wasm` IS a wasm
// plugin, so a JS plugin is code running inside a wasm guest and must not be
// able to reach a proc door shaped differently from the one every other guest
// gets. It no longer can: the four bodies below are the WHOLE door, and both
// membranes are generated from the `doors` table at the bottom of this
// section — `membrane/contract.zig` binds them as `wl_proc_*`, `quickjs.zig`
// binds the SAME bodies as `qjs_proc_*`. The `cwd` argument `qjs_proc_spawn`
// once carried and `wl_proc_spawn` never had is not merely removed, it is
// unrepresentable: there is no second body to grow one in.
//
// Each body takes a `Door` — the plugin's `Resources` (its pool, the
// environment its children inherit, its handle-indexed streams) plus the
// DISPATCHING entry's `Context` (where the child runs and with what, via
// `resolveSpawnAtCtx`/`resolveSpawnEnvCtx`) — and nothing about which plane
// asked.
//
// These used to be reached through an `anytype` duck type — `procPool()`,
// `procStreams()`, `baseEnviron()`, declared under identical names on
// `WasmPlugin` and `JsPlugin`. That was never an abstraction, only the
// symptom of one kind of state living on two instance types; both embed the
// same `Resources` block now, so the bodies name it outright.
//
// What is genuinely per-transport stays in the trampoline generators
// (`wasmDoor` here, `jsDoor` in quickjs.zig): how `data` is cast, where the
// dispatching context comes from, and how a denial is spelled — a trap for a
// `.wasm` guest, a logged `qjs_contract.denied` for the RESIDENT JS runtime,
// which a trap would tear down.
const proc_stream = @import("../proc_stream.zig");
const plugin_resources = @import("../plugin_resources.zig");
const Resources = plugin_resources.Resources;
const Door = plugin_resources.Door;

const Perm = shared.Perm;

/// A handle's live stream, or null for a negative/out-of-range/closed slot.
/// The check itself lives in `handles.Slots.at`, shared with the repl and net
/// registries that get their handles from the same untrusted place.
fn streamAt(r: *Resources, h: i32) ?*proc_stream.ProcStream {
    return r.streams.at(h);
}

/// `procSpawn(cmd) -> handle` (or -1 if unavailable). Spawns a persistent
/// subprocess in the dispatching entry's PLACE, with that place's environment
/// (`resolveSpawnAtCtx`/`resolveSpawnEnvCtx`); its stdout is buffered for
/// `procRead`. Returns -1 when the place cannot host a local child, rather
/// than falling back to the editor's own directory — the whole point of
/// asking the place instead of taking a directory from the guest.
pub fn spawnBody(d: Door, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    const r = d.resources;
    const ctx = d.ctx;
    const gpa = r.gpa;
    const pool = r.pool orelse {
        results[0] = -1;
        return;
    };
    const cmd = caller.readMemory(gpa, @intCast(args[0]), @intCast(args[1])) catch {
        results[0] = -1;
        return;
    };
    defer gpa.free(cmd);
    // `ProcStream.start` dups the cwd it is given, so this one is ours to free.
    const at = shared.resolveSpawnAtCtx(ctx, gpa);
    defer switch (at) {
        .at => |dir| gpa.free(dir),
        else => {},
    };
    const cwd: ?[]const u8 = switch (at) {
        .inherit => null,
        .at => |dir| dir,
        .refused => |why| {
            shared.noteSpawnRefusal(r.name, why);
            results[0] = -1;
            return;
        },
    };
    const spawn_env = shared.resolveSpawnEnvCtx(ctx, gpa);
    var env_owned = true;
    defer if (env_owned) if (spawn_env) |owned_env| owned_env.block.deinit(gpa);
    const s = proc_stream.ProcStream.start(gpa, pool, cmd, cwd, spawn_env orelse r.environ) catch {
        results[0] = -1;
        return;
    };
    // A persistent child uses its environment for its whole life, so the stream
    // takes the merged one over from us.
    if (spawn_env != null) {
        s.adoptEnviron();
        env_owned = false;
    }
    const handle = r.streams.open(gpa, s) catch {
        s.deinit();
        results[0] = -1;
        return;
    };
    results[0] = @intCast(handle);
}

/// `procSend(handle, bytes)`: write to the subprocess's stdin.
pub fn sendBody(d: Door, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = results;
    // No `d.ctx`: addressing an already-started child resolves no place.
    const r = d.resources;
    const s = streamAt(r, args[0]) orelse return;
    const bytes = caller.readMemory(r.gpa, @intCast(args[1]), @intCast(args[2])) catch return;
    defer r.gpa.free(bytes);
    s.send(bytes);
}

/// `procRead(handle, out, cap) -> n`: drain up to `cap` buffered stdout bytes.
pub fn readBody(d: Door, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    // No `d.ctx`: draining an already-started child resolves no place.
    const r = d.resources;
    const s = streamAt(r, args[0]) orelse {
        results[0] = 0;
        return;
    };
    const cap: usize = @intCast(args[2]);
    const buf = r.gpa.alloc(u8, cap) catch {
        results[0] = 0;
        return;
    };
    defer r.gpa.free(buf);
    const n = s.read(buf);
    results[0] = @intCast(caller.writeMemory(@intCast(args[1]), @intCast(cap), buf[0..n]) catch 0);
}

/// `procClose(handle)`: kill the subprocess; the slot stays null for stability.
/// Deliberately ungated on BOTH planes: it only RELEASES authority, and
/// denying it would strand a live subprocess with no way to reap it.
pub fn closeBody(d: Door, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = caller;
    _ = results;
    // No `d.ctx`: releasing a child resolves no place.
    d.resources.streams.close(args[0]);
}

/// Bind one shared body onto the `.wasm` guest membrane. Re-exported from
/// `plugin.zig` rather than written here: the read doors need exactly the
/// same trampoline with `gate = null`, and two copies of it is how the two
/// families would drift. There is no other way to spell a `wl_proc_*`
/// handler, so a hand-written one fails the `doors` gate in
/// `e2e/demolition_test.zig`.
pub const wasmDoor = shared.wasmDoor;

pub const hProcSpawn = wasmDoor(spawnBody, .proc);
pub const hProcSend = wasmDoor(sendBody, null);
pub const hProcRead = wasmDoor(readBody, null);
pub const hProcClose = wasmDoor(closeBody, null);

/// The plugin-plane proc surface as DATA: per door, the ONE body both
/// membranes run, the handler `contract.zig` binds as `wl_<name>`, and the
/// possession check each transport wraps it in. Exported so a gate can assert
/// the two surfaces agree by comparing function POINTERS rather than by
/// trusting a comment (`e2e/demolition_test.zig`, doc/place.md §4.1a).
///
/// `wl_gate`/`qjs_gate` are separate fields for ONE honest reason, and the
/// gate records it as an exception rather than tolerating it silently:
/// `qjs_proc_send`/`qjs_proc_read` re-check `proc` possession on every call
/// (so revoking the grant stops an already-running agent on its next call,
/// not merely its next spawn) and their `wl_*` twins do not. Making the wasm
/// twins match means adding `.perm = .proc` to two `membrane/root.zig` rows
/// and two lines to `contract.zig`'s `perm_gated` list — that file is under
/// concurrent edit, so the remainder is NAMED here instead of forced. Every
/// other difference between the two planes is now unrepresentable: same body,
/// same table.
pub const doors = .{
    .{ .name = "proc_spawn", .body = spawnBody, .wl = hProcSpawn, .wl_gate = @as(?Perm, .proc), .qjs_gate = @as(?Perm, .proc) },
    .{ .name = "proc_send", .body = sendBody, .wl = hProcSend, .wl_gate = @as(?Perm, null), .qjs_gate = @as(?Perm, .proc) },
    .{ .name = "proc_read", .body = readBody, .wl = hProcRead, .wl_gate = @as(?Perm, null), .qjs_gate = @as(?Perm, .proc) },
    .{ .name = "proc_close", .body = closeBody, .wl = hProcClose, .wl_gate = @as(?Perm, null), .qjs_gate = @as(?Perm, null) },
};

/// `placeRoot(out, cap) -> n`: the absolute directory of the DISPATCHING PLACE
/// (`doc/place.md`), or ZERO BYTES when that place has no local directory.
///
/// The place-shaped replacement for the deleted process-directory door, and
/// strictly NARROWER than it: that one revealed the editor's launch directory
/// unconditionally, to every guest, regardless of what the dispatch was about.
/// This reveals only where the dispatch already runs — the same value
/// `resolveSpawnAt` chdir's this plugin's children into a few declarations
/// above — so it needs no permission of its own: a guest that can spawn here
/// already acts here.
///
/// The four answers are `place.Realized`'s four, unflattened:
///  - `.process` — the editor's own directory. The DEGENERATE INSTANCE, not a
///    fallback: that place IS the process's directory, so naming it is exactly
///    right.
///  - `.path` — the container's absolute directory, borrowed from the
///    authority that opened it (never retained; it is copied into guest memory
///    within this call).
///  - `.elsewhere`/`.unavailable` — no local directory exists to name. Zero
///    bytes, so a guest DECLINES rather than silently acting in the editor's
///    launch directory, which is the whole bug this door exists to retire.
/// `placeId() -> id`: a dense opaque id for the dispatching place.
///
/// What a session table keys on. Deliberately NOT the place's directory: a
/// plugin keeping sessions per project needs to tell two places apart, not to
/// know where either one is, and a path could not name a peer or synthetic
/// container anyway. Same contract `Locus` states for itself -- compare for
/// equality, never interpret.
pub fn hPlaceId(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = caller;
    _ = args;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    results[0] = @intCast(p.activeCtx().placeId());
}

pub fn hPlaceRoot(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const ctx = p.activeCtx();
    var buf: [4096]u8 = undefined;
    const dir = placeDirectory(ctx, &buf);
    if (dir.len == 0) {
        results[0] = 0;
        return;
    }
    results[0] = @intCast(caller.writeMemory(@intCast(args[0]), @intCast(args[1]), dir) catch 0);
}

/// The dispatching place's local directory — `shared.placeDirectory`, which
/// lives in the shared leaf precisely because `hPlaceRoot`, `hPlaceHas` AND
/// `wasm_host/fs.zig`'s `.place` confinement must not be able to disagree
/// about which directory a guest is asking about versus being held inside.
const placeDirectory = shared.placeDirectory;

/// `placeHas(rel) -> kind`: what `<the dispatching place>/<rel>` IS — 0 absent,
/// 1 file, 2 dir, 3 other, the same `file.Kind` ordinals `wl_fs_exists`
/// answers in (`doc/place.md` §4.2's "marker/ancestor query against a place").
///
/// **No permission, and the reason is containment rather than convenience.**
/// Three things have to hold for an ungated door, and each is structural here:
///
///  1. **It reveals strictly less than `wl_place_root`, right beside it.**
///     That door hands the guest the place's absolute directory outright. A
///     guest holding a directory and a guest able to ask "is `.git` in it"
///     are not different tiers of authority; the second is a projection of
///     the first onto a single bit.
///  2. **It reveals strictly less than `proc`.** Any holder of `proc` runs a
///     child AT this place already (`shared.resolveSpawnAtCtx`, above) and can
///     `test -e` anything it likes there. A door that answers one `statx`
///     cannot be the line where that becomes reachable.
///  3. **It cannot escape the place.** `placeKind` resolves through
///     `RootedFs` — `openat2(RESOLVE_BENEATH | RESOLVE_NO_SYMLINKS)` — so an
///     absolute `rel`, a `..` component, and a symlink planted inside the
///     place all fail IN THE KERNEL, atomically. There is no lexical check to
///     get wrong and no TOCTOU window to race.
///
/// So this is a question about the place a dispatch is already in, not
/// filesystem access, and it is the primitive that let `git` and `project`
/// hand back `fs_read` — a grant that reached the WHOLE filesystem so two
/// plugins could probe for `.git` inside their own project.
pub fn hPlaceHas(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    results[0] = @intFromEnum(file.Kind.none);
    const rel = caller.readMemory(p.gpa, @intCast(args[0]), @intCast(args[1])) catch return;
    defer p.gpa.free(rel);
    const ctx = p.activeCtx();
    var buf: [4096]u8 = undefined;
    results[0] = @intFromEnum(placeKind(p.gpa, placeDirectory(ctx, &buf), rel));
}

/// What `<dir>/<rel>` is, resolved CONFINED beneath `dir`. The semantic body
/// behind `hPlaceHas`, split out so the escape gates can be stated against it
/// directly (no wasm instance, no live place).
///
/// Every refusal answers `.none` — absent. That is deliberate for a door with
/// no permission behind it: `wl_fs_exists` distinguishes "refused" from
/// "absent" so a GRANTED plugin gets a loud message instead of a confusing
/// miss, but here there is no grant to diagnose, and a distinguishable refusal
/// would itself be a signal ("something is there, you may not see it"). Absent
/// is the answer that reveals nothing.
///
/// The machinery carve-out (`doc/place.md` §4.1) applies unconditionally, as
/// it does at every fs door: a place CAN be an ancestor of the editor's own
/// state — a version-controlled home directory is the case the design names —
/// and no door, gated or not, may confirm that the module cache or a keystore
/// is there.
pub fn placeKind(gpa: Allocator, dir: []const u8, rel: []const u8) file.Kind {
    // No local directory (a peer place, or a container that went away), or
    // nothing named inside it: nothing to answer about.
    if (dir.len == 0 or rel.len == 0) return .none;
    const joined = std.fmt.allocPrint(gpa, "{s}/{s}", .{ dir, rel }) catch return .none;
    defer gpa.free(joined);
    if (machinery.denies(joined)) return .none;

    const rootz = gpa.dupeZ(u8, dir) catch return .none;
    defer gpa.free(rootz);
    var rfs = rooted_fs.RootedFs.open(rootz.ptr) catch return .none;
    defer rfs.close();
    const relz = gpa.dupeZ(u8, rel) catch return .none;
    defer gpa.free(relz);
    return switch (rfs.kind(relz.ptr) catch return .none) {
        .file => .file,
        .dir => .dir,
        .other => .other,
    };
}

/// Perm-gated (proc + timer): run `<cmd>` off the frame thread and insert its
/// stdout at the cursor when it finishes — anchored if the buffer moved,
/// authored as this plugin's peer. The membrane form of shell.zig's
/// `editLater(runCmd, cmd)`: same async target + authority, but the proc
/// body runs host-side (the design's "route proc through the host import").
pub fn hShellInsert(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = results;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    // Trap on deny — no ghost second result if the plugin didn't request both.
    if (!requirePerm(p, caller, .proc)) return;
    if (!requirePerm(p, caller, .timer)) return;
    const loop = p.loop orelse return;
    const gpa = p.gpa;
    const cmd = caller.readMemory(gpa, @intCast(args[0]), @intCast(args[1])) catch return;
    var cmd_owned = true;
    defer if (cmd_owned) gpa.free(cmd);
    const active_ctx = p.activeCtx();
    const buffer = active_ctx.entry() orelse return;
    const editor = buffer.textEditor() orelse return;
    const doc = &editor.doc;
    const target = doc.exportAnchor(gpa, editor.cursorOffset(), .before) catch return;
    var target_owned = true;
    defer if (target_owned) gpa.free(target.agent);
    const at = shared.resolveSpawnAt(p, gpa);
    const cwd: ?[]u8 = switch (at) {
        .inherit => null,
        .at => |dir| dir,
        .refused => |why| {
            shared.noteSpawnRefusal(p.name, why);
            return;
        },
    };
    var cwd_owned = true;
    defer if (cwd_owned) if (cwd) |d| gpa.free(d);
    // Same place, same door: WHERE the child runs and WITH WHAT.
    const spawn_env = shared.resolveSpawnEnv(p, gpa);
    var env_owned = true;
    defer if (env_owned) if (spawn_env) |e| e.block.deinit(gpa);
    const job = gpa.create(ShellJob) catch {
        return;
    };
    var job_owned = true;
    defer if (job_owned) gpa.destroy(job);
    const name = gpa.dupe(u8, p.name) catch return;
    job.* = .{
        .gpa = gpa,
        .buffers = active_ctx.buffers,
        .buffer = buffer.ref(),
        .name = name,
        .target = target,
        .cmd = cmd,
        .cwd = cwd,
        .environ = spawn_env,
    };
    cwd_owned = false;
    env_owned = false;
    cmd_owned = false;
    target_owned = false;
    job_owned = false;
    _ = loop.spawn(shellWork, job, .{ .ctx = job, .call = shellDeliver, .deinit = shellFree }) catch {
        shellFree(job);
    };
}

/// Off-thread: run `/bin/sh -c <cmd>`, return stdout trimmed of a trailing
/// newline. Failure yields empty (nothing inserted). Runs on the async pool
/// worker — proc.run synchronous there, no frame block.
fn shellWork(gpa: Allocator, ctx: ?*anyopaque) anyerror![]u8 {
    const job: *ShellJob = @ptrCast(@alignCast(ctx.?));
    var res = proc.run(gpa, &.{ "/bin/sh", "-c", job.cmd }, .{ .environ = job.environ orelse shared.g_environ, .cwd = job.cwd }) catch return gpa.alloc(u8, 0);
    defer res.deinit(gpa);
    return gpa.dupe(u8, std.mem.trimEnd(u8, res.stdout, "\n"));
}

/// Frame-thread delivery: resolve the captured CRDT identity and insert as the
/// plugin peer (grade-gated). A foreign/compacted target or view grade drops.
fn shellDeliver(ctx: ?*anyopaque, result: ?[]const u8) void {
    const job: *ShellJob = @ptrCast(@alignCast(ctx.?));
    const bytes = result orelse return;
    const gpa = job.gpa;
    const buffer = job.buffers.resolve(job.buffer) orelse return;
    const doc = &(buffer.textEditor() orelse return).doc;
    var resolved: [1]usize = undefined;
    doc.resolveAnchors(gpa, &.{job.target}, &resolved) catch return;
    const at = resolved[0];
    command.renderInto(gpa, doc, .plugin, job.name, &.{.{ .range = .{ .start = at, .end = at }, .bytes = bytes }}) catch return;
}

fn shellFree(ctx: ?*anyopaque) void {
    const job: *ShellJob = @ptrCast(@alignCast(ctx.?));
    const gpa = job.gpa;
    gpa.free(job.name);
    if (job.cwd) |d| gpa.free(d);
    if (job.environ) |e| e.block.deinit(gpa);
    gpa.free(job.target.agent);
    gpa.free(job.cmd);
    gpa.destroy(job);
}

/// A deferred proc-to-buffer: run a command off-thread and fill the entry
/// CAPTURED AT SPAWN with its output. `entry` is a generation-checked
/// `Buffers.Ref`, not a name: nothing that happens while the command runs — a
/// focus change, a same-named buffer opened later, the entry being closed and
/// its slot reused — can redirect the result. A ref that no longer resolves
/// drops the output with a note; it is never delivered anywhere else.
/// `styler` fires the issuing plugin's `on_fill_token` with `token` once the
/// text has landed, so a guest learns WHICH of its fills completed. The plugin
/// pointer is safe to hold — plugins are resident for the app's life (the same
/// residency `notifyActivate` relies on); it is only ever called on the normal
/// delivery path, never at teardown.
const ProcJob = struct {
    gpa: Allocator,
    buffers: *Buffers,
    styler: *WasmPlugin, // fires on_fill_token after delivery (resident)
    plugin: []u8, // authors the buffer content
    entry: Buffers.Ref, // the target captured at spawn
    token: u32, // the guest's opaque fill tag
    cmd: []u8,
    append: bool = false, // append the output (a console) vs replace (a view)
    /// Where the child runs, captured at spawn. Null = the `.process` place.
    /// Owned; freed with the job.
    cwd: ?[]u8 = null,
    /// A spool's input payload — the bytes the child reads from `{}`. Null for
    /// the plain fill doors, which hand the child nothing. Owned.
    input: ?[]u8 = null,
    /// A spool's host-composed temp path. The guest never sees it, cannot name
    /// it, and cannot keep it: `spoolWork` deletes it before returning, on
    /// every path. Null for the plain fill doors. Owned.
    tmp: ?[]u8 = null,
    /// The environment the child runs with, captured at spawn. Null = the base
    /// process environment (no overlay for this place). OWNED; freed with the job.
    environ: ?std.process.Environ = null,
};

/// Which fill door a job came through. The three share one spawn body because
/// they differ only in what happens to the output (replace/append) and whether
/// the child is handed an input file.
const Fill = enum {
    /// `wl_proc_to_buffer`: stdout replaces the entry.
    replace,
    /// `wl_proc_append_buffer`: stdout is appended (a console log).
    append,
    /// `wl_proc_spool`: an input payload is written to a host-composed temp,
    /// substituted for `{}`, and deleted afterwards; stdout replaces the entry.
    spool,
};

/// Perm-gated (proc + timer): run `<cmd>` off the frame thread and replace the
/// scratch buffer named `<name>` with its stdout, authored as this plugin's
/// peer — the "tool output → a buffer" pattern (git status, grep, compile).
/// The name is resolved HERE, once; `args[4]` is the fill token echoed back.
pub fn hProcToBuffer(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = results;
    spawnFill(@ptrCast(@alignCast(data.?)), caller, args, .replace);
}

/// Like `wl_proc_to_buffer` but APPENDS the output (a console/comint log) rather
/// than replacing the buffer.
pub fn hProcAppendBuffer(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = results;
    spawnFill(@ptrCast(@alignCast(data.?)), caller, args, .append);
}

/// `wl_proc_spool(cmd, input, name, token)`: `wl_proc_to_buffer` plus an input
/// payload. The host writes `input` to a temp file IT names, substitutes that
/// path for `{}` in `cmd`, runs the command in the dispatching entry's place,
/// fills `<name>` with stdout, and deletes the temp — whether the command
/// succeeded or not.
///
/// This is the door a plugin uses when a subprocess needs its input as a real
/// file (`git apply {}`, `git commit -F {}`, `llm < {}`). Perms are `proc +
/// timer`, the same set the sibling fill doors take, and deliberately NOT
/// `fs_write`: the guest supplies bytes and a command, never a path, so it
/// gains no ability to write anywhere it chooses (`doc/place.md` §4.2).
pub fn hProcSpool(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = results;
    spawnFill(@ptrCast(@alignCast(data.?)), caller, args, .spool);
}

/// A monotonic tag so two spools in flight never share a path; the pid keeps
/// two editors on one machine apart.
var spool_counter: usize = 0;

/// The shared spawn for all three fill doors: gate, resolve the target ONCE,
/// and hand the job a ref plus the guest's token.
fn spawnFill(p: *WasmPlugin, caller: *wasm.Caller, args: []const i32, kind: Fill) void {
    if (!requirePerm(p, caller, .proc)) return;
    if (!requirePerm(p, caller, .timer)) return;
    const loop = p.loop orelse return;
    const gpa = p.gpa;
    const cmd = caller.readMemory(gpa, @intCast(args[0]), @intCast(args[1])) catch return;
    var cmd_owned = true;
    defer if (cmd_owned) gpa.free(cmd);
    // A spool's input payload sits between the command and the buffer name, so
    // the shared tail — `(name, name_len, token)` — starts one pair later.
    const input: ?[]u8 = if (kind == .spool)
        (caller.readMemory(gpa, @intCast(args[2]), @intCast(args[3])) catch return)
    else
        null;
    var input_owned = true;
    defer if (input_owned) if (input) |b| gpa.free(b);
    const tail: usize = if (kind == .spool) 4 else 2;
    const name = caller.readMemory(gpa, @intCast(args[tail]), @intCast(args[tail + 1])) catch return;
    defer gpa.free(name);
    // The guest names the COMMAND; the host names the FILE. Composed here, on
    // the frame thread, so the path exists nowhere the guest can reach it.
    const tmp: ?[]u8 = if (kind == .spool) blk: {
        spool_counter += 1;
        break :blk std.fmt.allocPrint(gpa, "/tmp/weft-spool-{d}-{d}", .{ std.os.linux.getpid(), spool_counter }) catch return;
    } else null;
    var tmp_owned = true;
    defer if (tmp_owned) if (tmp) |b| gpa.free(b);
    const buffers = p.activeCtx().buffers;
    // ONE reading of "where", used for two things that must not disagree: the
    // directory the child runs in, and the place the output entry is ABOUT.
    // Read before the target exists, so it is the DISPATCHING entry's place and
    // not the tool entry's own inherited copy.
    const spawn_place = p.activeCtx().place();
    const at = shared.resolveSpawnAt(p, gpa);
    const cwd: ?[]u8 = switch (at) {
        .inherit => null,
        .at => |dir| dir,
        .refused => |why| {
            shared.noteSpawnRefusal(p.name, why);
            return;
        },
    };
    var cwd_owned = true;
    defer if (cwd_owned) if (cwd) |d| gpa.free(d);
    // Same place, same door: WHERE the child runs and WITH WHAT.
    const spawn_env = shared.resolveSpawnEnv(p, gpa);
    var env_owned = true;
    defer if (env_owned) if (spawn_env) |e| e.block.deinit(gpa);
    const target = ensureFillTarget(gpa, buffers, name) orelse return;
    // Re-target a REUSED tool entry: running grep again from another project
    // makes `*grep*` about the new place from this moment on. A fresh entry
    // already inherited the same value; saying it explicitly covers both.
    buffers.setPlace(target.id, spawn_place);
    const plugin = gpa.dupe(u8, p.name) catch return;
    var plugin_owned = true;
    defer if (plugin_owned) gpa.free(plugin);
    const job = gpa.create(ProcJob) catch return;
    job.* = .{
        .gpa = gpa,
        .buffers = buffers,
        .styler = p,
        .plugin = plugin,
        .entry = target,
        .token = @bitCast(args[tail + 2]),
        .cmd = cmd,
        .append = kind == .append,
        .cwd = cwd,
        .environ = spawn_env,
        .input = input,
        .tmp = tmp,
    };
    cmd_owned = false;
    plugin_owned = false;
    cwd_owned = false;
    env_owned = false;
    input_owned = false;
    tmp_owned = false;
    _ = loop.spawn(procWork, job, .{ .ctx = job, .call = procDeliver, .deinit = procFree }) catch procFree(job);
}

/// Find-or-create the named entry and capture its identity. A buffer proc
/// CREATES is a plain tool sink (grep/make output) → read-only. A PRE-created
/// one keeps whatever the plugin declared (a projection marks itself read-only
/// via weft.readOnly; an editable one like *git-commit* stays writable) — so
/// create-branch marks, find-branch doesn't.
fn ensureFillTarget(gpa: Allocator, bufs: *Buffers, name: []const u8) ?Buffers.Ref {
    if (bufs.findByName(name)) |id| return (bufs.get(id) orelse return null).ref();
    const nb = bufs.get(bufs.create(gpa, name) catch return null) orelse return null;
    nb.read_only = true;
    return nb.ref();
}

fn procWork(gpa: Allocator, ctx: ?*anyopaque) anyerror![]u8 {
    const job: *ProcJob = @ptrCast(@alignCast(ctx.?));
    if (job.tmp) |tmp| return spoolWork(gpa, job, tmp);
    return runCapture(gpa, job.cmd, job.cwd, job.environ);
}

/// A spool's off-thread body: land the input in the host-composed temp, hand
/// the child its path through `{}`, and DELETE IT ON EVERY WAY OUT — the write
/// failing, the substitution failing, the spawn failing, the command exiting
/// non-zero, and the ordinary success. The `defer` is the whole point: there is
/// no early return that can leave the file behind, so a failed effect never
/// litters and never leaves stale bytes for the next run to pick up.
fn spoolWork(gpa: Allocator, job: *ProcJob, tmp: []const u8) anyerror![]u8 {
    defer file.deleteFile(gpa, tmp);
    file.writeBytes(gpa, tmp, job.input orelse &.{}) catch return gpa.alloc(u8, 0);
    const cmd = std.mem.replaceOwned(u8, gpa, job.cmd, "{}", tmp) catch return gpa.alloc(u8, 0);
    defer gpa.free(cmd);
    return runCapture(gpa, cmd, job.cwd, job.environ);
}

/// Run `cmd` through the shell in `cwd` and return its stdout, trimmed of a
/// trailing newline. A spawn failure yields empty rather than erroring — the
/// fill lands as "the command said nothing", which is what a missing tool is.
fn runCapture(gpa: Allocator, cmd: []const u8, cwd: ?[]const u8, environ: ?std.process.Environ) anyerror![]u8 {
    var res = proc.run(gpa, &.{ "/bin/sh", "-c", cmd }, .{ .environ = environ orelse shared.g_environ, .cwd = cwd }) catch return gpa.alloc(u8, 0);
    defer res.deinit(gpa);
    return gpa.dupe(u8, std.mem.trimEnd(u8, res.stdout, "\n"));
}

/// Frame-thread delivery: resolve the entry captured at spawn and fill it,
/// authored as the plugin peer (grade-gated). What is active or focused never
/// enters into it — an entry closed while the command ran drops its output.
fn procDeliver(ctx: ?*anyopaque, result: ?[]const u8) void {
    const job: *ProcJob = @ptrCast(@alignCast(ctx.?));
    const out = result orelse return;
    const gpa = job.gpa;
    const b = job.buffers.resolve(job.entry) orelse {
        std.log.info("proc: '{s}' output dropped — its target entry closed while the command ran", .{job.plugin});
        return;
    };
    const editor = b.textEditor() orelse return;
    const doc = &editor.doc;
    const end = editor.text().byteLen();
    if (job.append) {
        // Append below the existing content (a console log), separated by a
        // newline once there is prior output.
        if (end > 0) {
            const sep = std.fmt.allocPrint(gpa, "\n{s}", .{out}) catch return;
            defer gpa.free(sep);
            command.renderInto(gpa, doc, .plugin, job.plugin, &.{.{ .range = .{ .start = end, .end = end }, .bytes = sep }}) catch {};
        } else {
            command.renderInto(gpa, doc, .plugin, job.plugin, &.{.{ .range = .{ .start = end, .end = end }, .bytes = out }}) catch {};
        }
    } else {
        command.renderInto(gpa, doc, .plugin, job.plugin, &.{.{ .range = .{ .start = 0, .end = end }, .bytes = out }}) catch {};
    }

    // The text has landed: tell the issuing plugin WHICH fill it was, so it can
    // parse/paint it (git's model, grep's coloring). The entry is BOUND for the
    // call, so the guest's ambient read/edit/style doors mean this entry — the
    // guest never asks what is active, and a focus change cannot misdirect it.
    // A plugin without `on_fill_token` is a no-op.
    const ctx_bound = job.styler.activeCtx();
    const prev = ctx_bound.bindEntry(job.entry);
    defer _ = ctx_bound.bindEntry(prev);
    contract.callOptionalExport("on_fill_token", &job.styler.instance, .{@as(i32, @bitCast(job.token))}) catch {}; // MissingExport → skip
}

fn procFree(ctx: ?*anyopaque) void {
    const job: *ProcJob = @ptrCast(@alignCast(ctx.?));
    const gpa = job.gpa;
    gpa.free(job.plugin);
    if (job.cwd) |d| gpa.free(d);
    if (job.environ) |e| e.block.deinit(gpa);
    if (job.input) |b| gpa.free(b);
    // The FILE is `spoolWork`'s to remove; this frees only the path string.
    // A job torn down before it ever ran never created the file at all.
    if (job.tmp) |b| gpa.free(b);
    gpa.free(job.cmd);
    gpa.destroy(job);
}

// ── wl_exec — argv in, (status, stdout, stderr) out ───────────────────
//
// The fill doors above hand a guest a SHELL STRING and a buffer to put stdout
// in, and nothing else. Everything a plugin actually wanted from a subprocess
// had to be recovered from that: the exit status by making the command print
// its own (`printf '\036\036C%d' "$s"`) and scanning it back out of the output;
// stderr by folding it into stdout with `2>&1`; safety by hand-quoting every
// interpolated path with `'{s}'` and hoping none of them contains an
// apostrophe; and the output itself by reading a DOCUMENT the bytes were
// briefly rendered into, in 64 KiB windows, into a fixed guest array.
//
// `wl_exec` is the door that was missing. The guest hands an ARGV — a
// NUL-separated block, so there is no quoting layer to get wrong and no shell
// to interpret anything — and gets back the three facts a command produces.
// It grants nothing the fill doors did not: the same `.proc + .timer` gate,
// the same place, the same host-named spool for the one thing a child needs on
// disk.
//
// WHERE it runs is the dispatching entry's place, exactly as the fill doors
// choose it — with one addition: a guest may name a BUFFER it already owns and
// the child runs in THAT entry's place instead. This is not a cwd door. A
// buffer's place is the host's to assign (`spawnFill` sets it, `open` sets it);
// naming one can only reach somewhere the host already put this plugin, which
// is what lets a second repository's projection act on its own repository
// without the `cd '{s}'` prologue every git command carries today.

/// A deferred exec: run an argv off-thread, keep what it said, and hand the
/// three facts to the issuing plugin's `on_exec`. Like `ProcJob` it holds no
/// borrowed context — the plugin pointer is resident for the app's life, and
/// nothing else survives the hop.
const ExecJob = struct {
    gpa: Allocator,
    styler: *WasmPlugin,
    /// The child's argv. Owned: the block and the slice of slices into it.
    argv_block: []u8,
    argv: [][]const u8,
    token: u32,
    cwd: ?[]u8 = null,
    environ: ?std.process.Environ = null,
    /// Bytes the child needs as a FILE. The host writes them to a temp it
    /// names, substitutes that path for a bare `{}` ARGUMENT, and deletes it —
    /// the spool contract, argv-shaped. Null when the guest sent none.
    input: ?[]u8 = null,
    tmp: ?[]u8 = null,
};

var exec_counter: usize = 0;

/// `wl_exec(argv, argv_len, argc, input, input_len, at, at_len, token) -> i32`.
/// 0 accepted, -1 refused. `argv` is `argc` NUL-separated arguments.
pub fn hExec(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    results[0] = -1;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    if (!requirePerm(p, caller, .proc)) return;
    if (!requirePerm(p, caller, .timer)) return;
    const loop = p.loop orelse return;
    const gpa = p.gpa;

    const block = caller.readMemory(gpa, @intCast(args[0]), @intCast(args[1])) catch return;
    var block_owned = true;
    defer if (block_owned) gpa.free(block);
    const argc: usize = @intCast(@max(args[2], 0));
    if (argc == 0 or argc > 4096) return;
    const argv = splitArgv(gpa, block, argc) orelse return;
    var argv_owned = true;
    defer if (argv_owned) gpa.free(argv);
    if (argv[0].len == 0) return; // a nameless program is not a command

    const input: ?[]u8 = if (args[4] > 0)
        (caller.readMemory(gpa, @intCast(args[3]), @intCast(args[4])) catch return)
    else
        null;
    var input_owned = true;
    defer if (input_owned) if (input) |b| gpa.free(b);
    // The guest names the COMMAND; the host names the FILE (`doc/place.md`
    // §4.2). Composed here, on the frame thread, so it exists nowhere the
    // guest can reach it and nothing it sends can influence the path.
    const tmp: ?[]u8 = if (input != null) blk: {
        exec_counter += 1;
        break :blk std.fmt.allocPrint(gpa, "/tmp/weft-exec-{d}-{d}", .{ std.os.linux.getpid(), exec_counter }) catch return;
    } else null;
    var tmp_owned = true;
    defer if (tmp_owned) if (tmp) |b| gpa.free(b);

    // WHERE. A named buffer's place, else the dispatching entry's own.
    const at_name = caller.readMemory(gpa, @intCast(args[5]), @intCast(args[6])) catch return;
    defer gpa.free(at_name);
    const at = execSpawnAt(p, gpa, at_name);
    const cwd: ?[]u8 = switch (at) {
        .inherit => null,
        .at => |dir| dir,
        .refused => |why| {
            shared.noteSpawnRefusal(p.name, why);
            return;
        },
    };
    var cwd_owned = true;
    defer if (cwd_owned) if (cwd) |d| gpa.free(d);
    const spawn_env = shared.resolveSpawnEnv(p, gpa);
    var env_owned = true;
    defer if (env_owned) if (spawn_env) |env| env.block.deinit(gpa);

    const job = gpa.create(ExecJob) catch return;
    job.* = .{
        .gpa = gpa,
        .styler = p,
        .argv_block = block,
        .argv = argv,
        .token = @bitCast(args[7]),
        .cwd = cwd,
        .environ = spawn_env,
        .input = input,
        .tmp = tmp,
    };
    block_owned = false;
    argv_owned = false;
    cwd_owned = false;
    env_owned = false;
    input_owned = false;
    tmp_owned = false;
    _ = loop.spawn(execWork, job, .{ .ctx = job, .call = execDeliver, .deinit = execFree }) catch {
        execFree(job);
        return;
    };
    results[0] = 0;
}

/// Slice a NUL-separated block into `argc` arguments. Null when the block does
/// not hold that many — a truncated argv runs nothing rather than running a
/// prefix of what was meant.
fn splitArgv(gpa: Allocator, block: []const u8, argc: usize) ?[][]const u8 {
    const argv = gpa.alloc([]const u8, argc) catch return null;
    var i: usize = 0;
    var start: usize = 0;
    var n: usize = 0;
    while (i < block.len and n < argc) : (i += 1) {
        if (block[i] != 0) continue;
        argv[n] = block[start..i];
        n += 1;
        start = i + 1;
    }
    if (n < argc and start < block.len) {
        argv[n] = block[start..];
        n += 1;
    }
    if (n != argc) {
        gpa.free(argv);
        return null;
    }
    return argv;
}

/// The place the child runs in. `name` empty means the dispatching entry's,
/// which is what every other proc door does; a named entry means THAT entry's
/// place, which the host assigned and the guest cannot invent.
fn execSpawnAt(p: *WasmPlugin, gpa: Allocator, name: []const u8) shared.SpawnAt {
    if (name.len == 0) return shared.resolveSpawnAt(p, gpa);
    const ctx = p.activeCtx();
    const id = ctx.buffers.findByName(name) orelse return shared.resolveSpawnAt(p, gpa);
    const entry = ctx.buffers.get(id) orelse return shared.resolveSpawnAt(p, gpa);
    const prev = ctx.bindEntry(entry.ref());
    defer _ = ctx.bindEntry(prev);
    return shared.resolveSpawnAtCtx(ctx, gpa);
}

/// The off-thread body. Encodes the three facts into the one byte slice the
/// task pool's result contract carries: status, then the stdout length, then
/// the two streams back to back.
fn execWork(gpa: Allocator, ctx: ?*anyopaque) anyerror![]u8 {
    const job: *ExecJob = @ptrCast(@alignCast(ctx.?));
    // The spool half: land the bytes, point the `{}` argument at them, and
    // DELETE THE FILE ON EVERY WAY OUT — the same discipline `spoolWork` holds,
    // for the same reason (a failed effect must not litter).
    var argv = job.argv;
    var substituted: ?[][]const u8 = null;
    defer if (substituted) |owned| gpa.free(owned);
    if (job.tmp) |tmp| {
        file.writeBytes(gpa, tmp, job.input orelse &.{}) catch return encodeExec(gpa, -1, "", "");
        const owned = gpa.alloc([]const u8, job.argv.len) catch return encodeExec(gpa, -1, "", "");
        for (job.argv, 0..) |a, i| owned[i] = if (std.mem.eql(u8, a, "{}")) tmp else a;
        substituted = owned;
        argv = owned;
    }
    defer if (job.tmp) |tmp| file.deleteFile(gpa, tmp);

    var res = proc.run(gpa, argv, .{
        .environ = job.environ orelse shared.g_environ,
        .cwd = job.cwd,
    }) catch return encodeExec(gpa, -1, "", "");
    defer res.deinit(gpa);
    const status: i32 = if (res.exitCode()) |code| @intCast(code) else -1;
    return encodeExec(gpa, status, res.stdout, res.stderr);
}

fn encodeExec(gpa: Allocator, status: i32, out: []const u8, err: []const u8) anyerror![]u8 {
    const buf = try gpa.alloc(u8, 8 + out.len + err.len);
    std.mem.writeInt(i32, buf[0..4], status, .little);
    std.mem.writeInt(u32, buf[4..8], @intCast(out.len), .little);
    @memcpy(buf[8..][0..out.len], out);
    @memcpy(buf[8 + out.len ..][0..err.len], err);
    return buf;
}

/// Frame-thread delivery: publish the result where the read doors can see it,
/// call the guest, and take it away again. The guest's window on this command's
/// output is exactly its own `on_exec` call.
fn execDeliver(ctx: ?*anyopaque, result: ?[]const u8) void {
    const job: *ExecJob = @ptrCast(@alignCast(ctx.?));
    const raw = result orelse return;
    if (raw.len < 8) return;
    const gpa = job.gpa;
    const status = std.mem.readInt(i32, raw[0..4], .little);
    const out_len = @min(std.mem.readInt(u32, raw[4..8], .little), raw.len - 8);
    const out = gpa.dupe(u8, raw[8..][0..out_len]) catch return;
    const err = gpa.dupe(u8, raw[8 + out_len ..]) catch {
        gpa.free(out);
        return;
    };
    const resources = &job.styler.resources;
    if (resources.exec) |*stale| stale.deinit(gpa); // a guest that re-entered
    resources.exec = .{ .status = status, .stdout = out, .stderr = err };
    defer {
        if (resources.exec) |*done| done.deinit(gpa);
        resources.exec = null;
    }
    contract.callOptionalExport("on_exec", &job.styler.instance, .{@as(i32, @bitCast(job.token))}) catch {}; // MissingExport → skip
}

fn execFree(ctx: ?*anyopaque) void {
    const job: *ExecJob = @ptrCast(@alignCast(ctx.?));
    const gpa = job.gpa;
    gpa.free(job.argv);
    gpa.free(job.argv_block);
    if (job.cwd) |d| gpa.free(d);
    if (job.environ) |env| env.block.deinit(gpa);
    if (job.input) |b| gpa.free(b);
    // The FILE is `execWork`'s to remove; this frees only the path string.
    if (job.tmp) |b| gpa.free(b);
    gpa.destroy(job);
}

/// `wl_exec_status() -> i32`: how the delivered command ended, or -1 outside a
/// delivery (and for a child that died by signal — both mean "not a clean exit
/// code", which is the only distinction a caller acts on).
pub fn hExecStatus(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = caller;
    _ = args;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    results[0] = if (p.resources.exec) |e| e.status else -1;
}

/// `wl_exec_read(which, offset, out, cap) -> i32`: a window on the delivered
/// command's stdout (`which` 0) or stderr (1), from `offset`. Returns the byte
/// count written, or -1 outside a delivery. Paged, so a chatty command is
/// clamped by the guest's buffer rather than by a fixed host limit.
pub fn hExecRead(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const e = p.resources.exec orelse {
        results[0] = -1;
        return;
    };
    const stream = if (args[0] == 0) e.stdout else e.stderr;
    const offset: usize = @intCast(@max(args[1], 0));
    const from = if (offset >= stream.len) stream[0..0] else stream[offset..];
    shared.writeExact(caller, args[2..], results, from);
}

/// A deferred proc FILTER: run `[start,end)` through a command (which rewrites
/// a temp file in place, `{}` = its path) and replace the range with the
/// result. The range is captured as CRDT identities and lands as the plugin
/// peer, so it follows concurrent edits without a version clock.
const FilterJob = struct {
    gpa: Allocator,
    buffers: *Buffers,
    buffer: Buffers.Ref,
    plugin: []u8,
    start: Document.EventAnchor,
    end: Document.EventAnchor,
    cmd: []u8, // contains "{}" → the temp path
    content: []u8, // the captured input (owned)
    tmp: []u8,
    /// Where the filter command runs. A formatter finds its config by walking
    /// up from its working directory, so a filter run in the wrong project is
    /// formatted by the wrong rules. Null = the `.process` place. Owned.
    cwd: ?[]u8 = null,
    /// The environment the child runs with, captured at spawn. Null = the base
    /// process environment (no overlay for this place). OWNED; freed with the job.
    environ: ?std.process.Environ = null,
};

var filter_counter: usize = 0;

/// Perm-gated (proc + timer): filter `[start,end)` through `<cmd>` (a `{}`
/// placeholder receives a temp file the range is written to, transformed in
/// place, and read back). Formatters (`zig fmt {}`, `prettier --write {}`) and
/// `vim !`-style filters both fit.
pub fn hProcFilter(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = results;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    if (!requirePerm(p, caller, .proc)) return;
    if (!requirePerm(p, caller, .timer)) return;
    const loop = p.loop orelse return;
    const gpa = p.gpa;
    const cmd = caller.readMemory(gpa, @intCast(args[0]), @intCast(args[1])) catch return;
    var cmd_owned = true;
    defer if (cmd_owned) gpa.free(cmd);
    const active_ctx = p.activeCtx();
    const buffer = active_ctx.entry() orelse return;
    const editor = buffer.textEditor() orelse return;
    const rope = editor.text();
    const len = rope.byteLen();
    const s = @min(@as(usize, @intCast(args[2])), len);
    const e = @min(@as(usize, @intCast(args[3])), len);
    if (e < s) return;
    const content = gpa.alloc(u8, e - s) catch return;
    var content_owned = true;
    defer if (content_owned) gpa.free(content);
    if (e > s) {
        var sr = rope.streamReader(.{ .start = s, .end = e }, &.{});
        sr.interface.readSliceAll(content) catch return;
    }
    const start = editor.doc.exportAnchor(gpa, s, .before) catch return;
    var start_owned = true;
    defer if (start_owned) gpa.free(start.agent);
    const end = editor.doc.exportAnchor(gpa, e, .after) catch return;
    var end_owned = true;
    defer if (end_owned) gpa.free(end.agent);
    filter_counter += 1;
    const tmp = std.fmt.allocPrint(gpa, "/tmp/weft-filter-{d}-{d}", .{ filter_counter, s }) catch return;
    var tmp_owned = true;
    defer if (tmp_owned) gpa.free(tmp);
    const at = shared.resolveSpawnAt(p, gpa);
    const cwd: ?[]u8 = switch (at) {
        .inherit => null,
        .at => |dir| dir,
        .refused => |why| {
            shared.noteSpawnRefusal(p.name, why);
            return;
        },
    };
    var cwd_owned = true;
    defer if (cwd_owned) if (cwd) |d| gpa.free(d);
    // Same place, same door: WHERE the child runs and WITH WHAT.
    const spawn_env = shared.resolveSpawnEnv(p, gpa);
    var env_owned = true;
    defer if (env_owned) if (spawn_env) |owned_env| owned_env.block.deinit(gpa);
    const job = gpa.create(FilterJob) catch return;
    var job_owned = true;
    defer if (job_owned) gpa.destroy(job);
    const plugin = gpa.dupe(u8, p.name) catch return;
    job.* = .{
        .gpa = gpa,
        .buffers = active_ctx.buffers,
        .buffer = buffer.ref(),
        .plugin = plugin,
        .start = start,
        .end = end,
        .cmd = cmd,
        .content = content,
        .tmp = tmp,
        .cwd = cwd,
        .environ = spawn_env,
    };
    cwd_owned = false;
    env_owned = false;
    cmd_owned = false;
    content_owned = false;
    start_owned = false;
    end_owned = false;
    tmp_owned = false;
    job_owned = false;
    _ = loop.spawn(filterWork, job, .{ .ctx = job, .call = filterDeliver, .deinit = filterFree }) catch filterFree(job);
}

fn filterWork(gpa: Allocator, ctx: ?*anyopaque) anyerror![]u8 {
    const job: *FilterJob = @ptrCast(@alignCast(ctx.?));
    // Write the input, run the command over it, read the result back. On ANY
    // failure return the ORIGINAL content, so the range is replaced with an
    // identical copy — never corrupted or emptied.
    file.writeBytes(gpa, job.tmp, job.content) catch return gpa.dupe(u8, job.content);
    const cmd = std.mem.replaceOwned(u8, gpa, job.cmd, "{}", job.tmp) catch return gpa.dupe(u8, job.content);
    defer gpa.free(cmd);
    var res = proc.run(gpa, &.{ "/bin/sh", "-c", cmd }, .{ .environ = job.environ orelse shared.g_environ, .cwd = job.cwd }) catch {
        file.deleteFile(gpa, job.tmp);
        return gpa.dupe(u8, job.content);
    };
    res.deinit(gpa); // in-place transform: the result is the file, not stdout
    const out = file.readAlloc(gpa, job.tmp) catch gpa.dupe(u8, job.content);
    file.deleteFile(gpa, job.tmp);
    return out;
}

fn filterDeliver(ctx: ?*anyopaque, result: ?[]const u8) void {
    const job: *FilterJob = @ptrCast(@alignCast(ctx.?));
    const out = result orelse return;
    const gpa = job.gpa;
    const buffer = job.buffers.resolve(job.buffer) orelse return;
    const doc = &(buffer.textEditor() orelse return).doc;
    var resolved: [2]usize = undefined;
    doc.resolveAnchors(gpa, &.{ job.start, job.end }, &resolved) catch return;
    const rs = resolved[0];
    const re = resolved[1];
    command.renderInto(gpa, doc, .plugin, job.plugin, &.{.{ .range = .{ .start = @min(rs, re), .end = @max(rs, re) }, .bytes = out }}) catch return;
}

fn filterFree(ctx: ?*anyopaque) void {
    const job: *FilterJob = @ptrCast(@alignCast(ctx.?));
    const gpa = job.gpa;
    gpa.free(job.plugin);
    if (job.cwd) |d| gpa.free(d);
    if (job.environ) |e| e.block.deinit(gpa);
    gpa.free(job.start.agent);
    gpa.free(job.end.agent);
    gpa.free(job.cmd);
    gpa.free(job.content);
    gpa.free(job.tmp);
    gpa.destroy(job);
}

// ── tests ───────────────────────────────────────────────────────────

const t = std.testing;

/// `link_path` → `target`, best effort. False if the platform refused (nothing
/// here depends on symlinks being creatable).
fn makeSymlink(target: [*:0]const u8, link_path: [*:0]const u8) bool {
    return std.os.linux.errno(std.os.linux.symlinkat(target, std.os.linux.AT.FDCWD, link_path)) == .SUCCESS;
}

test "placeKind: a place-relative probe cannot escape the place" {
    const gpa = t.allocator;

    // <tmp>/place        — the place's directory
    // <tmp>/secret.txt   — outside it
    // <tmp>/place/leak   — a symlink inside the place, pointing out of it
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const place = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/place", .{tmp.sub_path});
    defer gpa.free(place);
    const inside = try std.fmt.allocPrint(gpa, "{s}/ok.txt", .{place});
    defer gpa.free(inside);
    const outside = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/secret.txt", .{tmp.sub_path});
    defer gpa.free(outside);
    try file.writeBytesMakingDirs(gpa, place, inside, "in place");
    try file.writeBytes(gpa, outside, "out of place");
    const marker = try std.fmt.allocPrint(gpa, "{s}/.git", .{place});
    defer gpa.free(marker);
    try file.writeBytes(gpa, marker, "gitdir: elsewhere\n"); // a worktree's `.git` is a FILE

    // The shape both migrated plugins actually ask: a marker INSIDE the place.
    // Any kind counts, which is why a worktree/submodule `.git` file answers.
    try t.expectEqual(file.Kind.file, placeKind(gpa, place, ".git"));
    try t.expectEqual(file.Kind.file, placeKind(gpa, place, "ok.txt"));
    try t.expectEqual(file.Kind.dir, placeKind(gpa, place, "."));
    try t.expectEqual(file.Kind.none, placeKind(gpa, place, "nope.txt"));
    // git's rebase probe: a path with a separator in it still resolves, and
    // still resolves only beneath the place.
    try t.expectEqual(file.Kind.none, placeKind(gpa, place, ".git/rebase-merge"));

    // ── The three escapes, each refused IN THE KERNEL (RESOLVE_BENEATH /
    // RESOLVE_NO_SYMLINKS), and each answering `.none` rather than describing
    // something the place does not contain. ──
    // 1. An absolute `rel` is not a path out: it is EXDEV under BENEATH.
    try t.expectEqual(file.Kind.none, placeKind(gpa, place, "/etc"));
    try t.expectEqual(file.Kind.none, placeKind(gpa, place, "/etc/hostname"));
    // 2. Traversal, at the front and buried mid-path.
    try t.expectEqual(file.Kind.none, placeKind(gpa, place, ".."));
    try t.expectEqual(file.Kind.none, placeKind(gpa, place, "../secret.txt"));
    try t.expectEqual(file.Kind.none, placeKind(gpa, place, "../../etc"));
    try t.expectEqual(file.Kind.none, placeKind(gpa, place, "sub/../../secret.txt"));
    // 3. A symlink planted INSIDE the place, pointing out of it — the hole a
    // realpath-then-compare check leaves open, and the one `fsExists` was
    // recently fixed for. The target exists; the answer is still `.none`.
    const leak = try std.fmt.allocPrintSentinel(gpa, "{s}/leak", .{place}, 0);
    defer gpa.free(leak);
    if (makeSymlink("../secret.txt", leak.ptr)) {
        try t.expect(file.statKind(gpa, leak) == .file); // a plain stat FOLLOWS it out
        try t.expectEqual(file.Kind.none, placeKind(gpa, place, "leak"));
    }

    // A place with no local directory answers about nothing at all — the
    // `.elsewhere`/`.unavailable` arms of `placeDirectory` (and a `.process`
    // place whose cwd was deleted) hand "" straight through.
    try t.expectEqual(file.Kind.none, placeKind(gpa, "", ".git"));
    try t.expectEqual(file.Kind.none, placeKind(gpa, place, ""));
}

test "placeKind: the machinery carve-out holds for an ungated door too" {
    // A place CAN be an ancestor of the editor's own state (doc/place.md §4.1
    // names the version-controlled home directory). `wl_place_has` carries no
    // permission, so it is precisely the door a plugin with NO capabilities
    // would reach for to confirm the module cache is there. It answers `.none`.
    const gpa = t.allocator;
    const cache = wasm.Engine.cacheDir(gpa) orelse return error.SkipZigTest;
    defer gpa.free(cache);
    if (file.statKind(gpa, cache) != .dir) return error.SkipZigTest;
    const slash = std.mem.lastIndexOfScalar(u8, cache, '/') orelse return error.SkipZigTest;
    if (slash == 0) return error.SkipZigTest;
    const parent = cache[0..slash];
    const leaf = cache[slash + 1 ..];
    // Not vacuous: the parent is an ordinary directory, the cache really is
    // inside it, and an unconfined stat says so.
    try t.expectEqual(file.Kind.dir, file.statKind(gpa, cache));
    try t.expect(machinery.denies(cache));
    try t.expectEqual(file.Kind.none, placeKind(gpa, parent, leaf));
}
